//! Detached ed25519 signatures over the exact bytes of `bundle.json`.
//!
//! * `bundle.json.sig` holds the 64-byte signature as lowercase hex (a trailing newline is
//!   fine). Raw 64-byte files are also accepted.
//! * Public keys are 32 bytes, given as 64 hex characters inline or in a file (hex text or
//!   raw bytes).
//! * Verification uses `verify_strict`, which rejects small-order keys and non-canonical
//!   signatures.
//!
//! Key generation and signing exist for development and tests only (`ci-stick dev ...`).
//! Release bundles are signed by the release pipeline with keys that never touch a
//! developer machine; `ci-stick` will ship those public keys pinned.

use std::fs;
use std::path::Path;

use anyhow::{bail, Context as _};
use ed25519_dalek::{Signature, Signer as _, SigningKey, VerifyingKey};
use thiserror::Error;

use crate::hashing::sha256_hex;

#[derive(Debug, Error)]
pub enum SignatureError {
    #[error("signature file is malformed: {0}")]
    Malformed(String),
    #[error("signature does not verify against the trusted public key")]
    Mismatch,
}

fn decode_hex_exact<const N: usize>(text: &str) -> Option<[u8; N]> {
    let t = text.trim();
    if t.len() != N * 2 {
        return None;
    }
    let mut out = [0u8; N];
    hex::decode_to_slice(t, &mut out).ok()?;
    Some(out)
}

fn decode_bytes<const N: usize>(bytes: &[u8]) -> Option<[u8; N]> {
    if bytes.len() == N {
        let mut out = [0u8; N];
        out.copy_from_slice(bytes);
        return Some(out);
    }
    std::str::from_utf8(bytes)
        .ok()
        .and_then(decode_hex_exact::<N>)
}

/// Parse `--pubkey`: 64 hex characters inline, or a path to a file holding hex or raw bytes.
pub fn parse_public_key(arg: &str) -> anyhow::Result<VerifyingKey> {
    let path = Path::new(arg);
    let bytes: [u8; 32] = if let Some(b) = decode_hex_exact::<32>(arg).filter(|_| !path.exists()) {
        b
    } else if path.exists() {
        let data = fs::read(path).with_context(|| format!("reading public key {arg}"))?;
        decode_bytes::<32>(&data).with_context(|| {
            format!("{arg}: expected a 32-byte ed25519 public key (64 hex chars or raw bytes)")
        })?
    } else {
        bail!("--pubkey {arg:?} is neither 64 hex characters nor an existing key file");
    };
    VerifyingKey::from_bytes(&bytes).context("public key is not a valid ed25519 point")
}

/// Short, human-comparable key fingerprint: first 16 hex chars of SHA-256(pubkey).
pub fn fingerprint(key: &VerifyingKey) -> String {
    sha256_hex(key.as_bytes())[..16].to_string()
}

pub fn parse_signature(bytes: &[u8]) -> Result<Signature, SignatureError> {
    decode_bytes::<64>(bytes)
        .map(|b| Signature::from_bytes(&b))
        .ok_or_else(|| {
            SignatureError::Malformed(format!(
                "expected 64 bytes or 128 hex characters, got {} bytes",
                bytes.len()
            ))
        })
}

pub fn verify_detached(
    key: &VerifyingKey,
    message: &[u8],
    signature: &Signature,
) -> Result<(), SignatureError> {
    key.verify_strict(message, signature)
        .map_err(|_| SignatureError::Mismatch)
}

// ---- development helpers -------------------------------------------------------------

pub fn generate_signing_key() -> anyhow::Result<SigningKey> {
    let mut seed = [0u8; 32];
    getrandom::getrandom(&mut seed).map_err(|e| anyhow::anyhow!("OS RNG unavailable: {e}"))?;
    Ok(SigningKey::from_bytes(&seed))
}

pub fn load_signing_key(path: &Path) -> anyhow::Result<SigningKey> {
    let data = fs::read(path).with_context(|| format!("reading signing key {}", path.display()))?;
    let seed = decode_bytes::<32>(&data).with_context(|| {
        format!(
            "{}: expected a 32-byte ed25519 secret seed (hex or raw)",
            path.display()
        )
    })?;
    Ok(SigningKey::from_bytes(&seed))
}

/// Hex text for a `.sig` file (with trailing newline).
pub fn sign_to_hex(key: &SigningKey, message: &[u8]) -> String {
    format!("{}\n", hex::encode(key.sign(message).to_bytes()))
}

/// Write `contents` to a new file readable only by the owner (on Unix).
pub fn write_secret_file(path: &Path, contents: &str) -> anyhow::Result<()> {
    let mut opts = fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        opts.mode(0o600);
    }
    let mut f = opts.open(path).with_context(|| {
        format!(
            "creating {} (refusing to overwrite an existing key)",
            path.display()
        )
    })?;
    std::io::Write::write_all(&mut f, contents.as_bytes())
        .with_context(|| format!("writing {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_and_verify_round_trip() {
        let sk = SigningKey::from_bytes(&[7u8; 32]);
        let pk = sk.verifying_key();
        let msg = b"{\"schema_version\":1}\n";
        let sig = parse_signature(sign_to_hex(&sk, msg).as_bytes()).unwrap();
        verify_detached(&pk, msg, &sig).unwrap();
        assert!(matches!(
            verify_detached(&pk, b"tampered", &sig),
            Err(SignatureError::Mismatch)
        ));
        let other = SigningKey::from_bytes(&[8u8; 32]).verifying_key();
        assert!(verify_detached(&other, msg, &sig).is_err());
    }

    #[test]
    fn parses_keys_inline_and_from_files() {
        let pk = SigningKey::from_bytes(&[9u8; 32]).verifying_key();
        let hexkey = hex::encode(pk.as_bytes());
        assert_eq!(parse_public_key(&hexkey).unwrap(), pk);
        let dir = tempfile::tempdir().unwrap();
        let hex_file = dir.path().join("k.pub");
        fs::write(&hex_file, format!("{hexkey}\n")).unwrap();
        assert_eq!(parse_public_key(hex_file.to_str().unwrap()).unwrap(), pk);
        let raw_file = dir.path().join("k.raw");
        fs::write(&raw_file, pk.as_bytes()).unwrap();
        assert_eq!(parse_public_key(raw_file.to_str().unwrap()).unwrap(), pk);
        assert!(parse_public_key("not-a-key").is_err());
        assert!(parse_public_key(&"zz".repeat(32)).is_err());
    }

    #[test]
    fn malformed_signatures_are_rejected() {
        assert!(parse_signature(b"").is_err());
        assert!(parse_signature(b"abcd").is_err());
        assert!(parse_signature("g".repeat(128).as_bytes()).is_err());
        assert!(
            parse_signature(&[0u8; 64]).is_ok(),
            "raw 64 bytes parse (and then fail verify)"
        );
    }

    #[test]
    fn secret_files_are_not_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("k");
        write_secret_file(&p, "a").unwrap();
        assert!(write_secret_file(&p, "b").is_err());
        assert_eq!(fs::read_to_string(&p).unwrap(), "a");
    }
}
