//! Trust anchors: the release keys compiled into this build, and the key fingerprints that
//! are revoked.
//!
//! Two committed files hold them, read with `include_str!` so a build carries exactly what the
//! repository said when it was built:
//!
//! * `stick/trust/pinned-keys.json`: `[{"id": "<16 hex>", "key": "<64 hex>"}, ...]`. `key` is
//!   an ed25519 public key; `id` is its fingerprint ([`crate::signing::fingerprint`]).
//! * `stick/trust/revoked.json`: `["<16 hex>", ...]`, fingerprints that must never be
//!   trusted again.
//!
//! **Both are empty today.** No release key, key custody or signing pipeline exists
//! (KI-23), so this build pins nothing and `--pubkey` stays the only key source. Pinning a
//! key, or revoking one, is a change to those two files and ships in a new binary; it needs
//! the owner's explicit approval and a second reviewer.
//!
//! A revocation can reach a user before a new binary does: every fingerprint in the optional
//! `revoked.txt` of the state directory ([`crate::state`]) is refused as well. That file can
//! only add refusals; nothing in it can make a key more trusted.

use std::collections::BTreeSet;

use anyhow::{bail, ensure, Context as _};
use ed25519_dalek::VerifyingKey;
use serde::Deserialize;

use crate::signing::fingerprint;

/// The committed list of pinned release keys.
pub const PINNED_JSON: &str = include_str!("../../../trust/pinned-keys.json");
/// The committed list of revoked fingerprints.
pub const REVOKED_JSON: &str = include_str!("../../../trust/revoked.json");

/// One release key: its fingerprint and the key itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PinnedKey {
    /// 16 lowercase hex characters: the first 8 bytes of SHA-256 of the key.
    pub id: String,
    pub key: VerifyingKey,
}

impl PinnedKey {
    pub fn from_key(key: VerifyingKey) -> Self {
        Self {
            id: fingerprint(&key),
            key,
        }
    }
}

/// The pinned keys and the revoked fingerprints a verification works with.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TrustAnchors {
    pinned: Vec<PinnedKey>,
    revoked: BTreeSet<String>,
}

impl TrustAnchors {
    /// Build anchors from parts, without checking them. [`Self::from_json`] is the checked
    /// way in for the committed files; this is for tests and for adding per-user revocations.
    pub fn new(pinned: Vec<PinnedKey>, revoked: Vec<String>) -> Self {
        Self {
            pinned,
            revoked: revoked
                .into_iter()
                .map(|r| r.to_ascii_lowercase())
                .collect(),
        }
    }

    /// The lists compiled into this build. An error means the committed files are malformed;
    /// callers must refuse to verify anything then.
    pub fn builtin() -> anyhow::Result<Self> {
        Self::from_json(PINNED_JSON, REVOKED_JSON).context(
            "the trust lists compiled into this ci-stick (stick/trust/*.json) are malformed",
        )
    }

    /// Parse and check the two files: every `key` is a valid, non-weak ed25519 key in
    /// lowercase hex, every `id` is that key's fingerprint, no key and no fingerprint is
    /// listed twice, every revoked entry is a fingerprint, and no pinned key is also revoked
    /// (a revoked key is removed from the pinned list in the same change).
    pub fn from_json(pinned: &str, revoked: &str) -> anyhow::Result<Self> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Entry {
            id: String,
            key: String,
        }
        let entries: Vec<Entry> = serde_json::from_str(pinned)
            .context("pinned-keys.json is not a JSON array of {\"id\", \"key\"} objects")?;
        let mut keys: Vec<PinnedKey> = Vec::new();
        for e in entries {
            ensure!(
                is_lower_hex(&e.key, 64),
                "pinned key {:?}: key must be 64 lowercase hex characters",
                e.id
            );
            let mut bytes = [0u8; 32];
            hex::decode_to_slice(&e.key, &mut bytes)
                .with_context(|| format!("pinned key {:?}: key is not hex", e.id))?;
            let key = VerifyingKey::from_bytes(&bytes)
                .with_context(|| format!("pinned key {:?}: not a valid ed25519 point", e.id))?;
            ensure!(
                !key.is_weak(),
                "pinned key {:?}: a small-order key can sign nothing worth trusting",
                e.id
            );
            let actual = fingerprint(&key);
            ensure!(
                e.id == actual,
                "pinned key {:?}: the id is not the key's fingerprint (that is {actual})",
                e.id
            );
            ensure!(
                !keys.iter().any(|k| k.id == actual),
                "pinned key {actual} is listed twice"
            );
            keys.push(PinnedKey { id: actual, key });
        }

        let listed: Vec<String> = serde_json::from_str(revoked)
            .context("revoked.json is not a JSON array of fingerprint strings")?;
        let mut revoked_set = BTreeSet::new();
        for r in listed {
            ensure!(
                is_fingerprint(&r),
                "revoked entry {r:?} is not a fingerprint (16 lowercase hex characters)"
            );
            ensure!(
                revoked_set.insert(r.clone()),
                "revoked entry {r} is listed twice"
            );
        }
        for k in &keys {
            ensure!(
                !revoked_set.contains(&k.id),
                "key {} is both pinned and revoked; remove it from pinned-keys.json",
                k.id
            );
        }
        Ok(Self {
            pinned: keys,
            revoked: revoked_set,
        })
    }

    /// These anchors plus more revoked fingerprints (the state directory's `revoked.txt`).
    pub fn with_revoked(mut self, more: impl IntoIterator<Item = String>) -> Self {
        self.revoked
            .extend(more.into_iter().map(|r| r.to_ascii_lowercase()));
        self
    }

    pub fn pinned(&self) -> &[PinnedKey] {
        &self.pinned
    }

    /// Every revoked fingerprint, sorted.
    pub fn revoked(&self) -> impl Iterator<Item = &str> {
        self.revoked.iter().map(String::as_str)
    }

    /// Does this build pin at least one release key? While it does not (today), `--pubkey` is
    /// the only way to name a key.
    pub fn has_pinned_keys(&self) -> bool {
        !self.pinned.is_empty()
    }

    pub fn is_revoked(&self, id: &str) -> bool {
        self.revoked.contains(&id.to_ascii_lowercase())
    }
}

/// 16 lowercase hex characters.
pub fn is_fingerprint(s: &str) -> bool {
    is_lower_hex(s, 16)
}

fn is_lower_hex(s: &str, len: usize) -> bool {
    s.len() == len
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Parse a `revoked.txt`: one fingerprint per line, any case; blank lines and lines starting
/// with `#` are ignored. A line that is anything else is an error naming it, because a
/// revocation that silently did not apply is worse than a refusal.
pub fn parse_revoked_txt(text: &str) -> anyhow::Result<Vec<String>> {
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let fp = line.to_ascii_lowercase();
        if !is_fingerprint(&fp) {
            bail!(
                "line {}: {line:?} is not a key fingerprint (16 hex characters; \
                 `ci-stick trust show` and `dev keygen` print them)",
                i + 1
            );
        }
        out.push(fp);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::SigningKey;

    fn key(seed: u8) -> VerifyingKey {
        SigningKey::from_bytes(&[seed; 32]).verifying_key()
    }

    fn entry(k: &VerifyingKey) -> String {
        format!(
            "{{\"id\": \"{}\", \"key\": \"{}\"}}",
            fingerprint(k),
            hex::encode(k.as_bytes())
        )
    }

    #[test]
    fn the_committed_lists_are_well_formed() {
        let anchors = TrustAnchors::builtin().unwrap();
        // The invariants the loader enforces, stated again from the outside.
        for (i, p) in anchors.pinned().iter().enumerate() {
            assert_eq!(p.id, fingerprint(&p.key), "id is the hash of the key");
            assert!(
                anchors.pinned()[..i].iter().all(|q| q.id != p.id),
                "{} is listed twice",
                p.id
            );
            assert!(!anchors.is_revoked(&p.id), "{} is pinned and revoked", p.id);
        }
        assert!(anchors.revoked().all(is_fingerprint));
    }

    #[test]
    fn no_release_key_is_pinned_until_the_owner_chooses_one() {
        // KI-23. Pinning a key is a change to stick/trust/pinned-keys.json that needs the
        // owner's explicit approval and a second reviewer; this test is the reminder.
        let anchors = TrustAnchors::builtin().unwrap();
        assert!(!anchors.has_pinned_keys());
        assert_eq!(anchors.revoked().count(), 0);
        assert_eq!(PINNED_JSON.trim(), "[]");
        assert_eq!(REVOKED_JSON.trim(), "[]");
    }

    #[test]
    fn a_well_formed_list_loads() {
        let (a, b) = (key(1), key(2));
        let pinned = format!("[{}, {}]", entry(&a), entry(&b));
        let revoked = format!("[\"{}\"]", "0123456789abcdef");
        let anchors = TrustAnchors::from_json(&pinned, &revoked).unwrap();
        assert!(anchors.has_pinned_keys());
        assert_eq!(anchors.pinned().len(), 2);
        assert_eq!(anchors.pinned()[0], PinnedKey::from_key(a));
        assert!(anchors.is_revoked("0123456789abcdef"));
        assert!(anchors.is_revoked("0123456789ABCDEF"));
        assert!(!anchors.is_revoked(&fingerprint(&a)));
    }

    #[test]
    fn a_hand_edit_of_one_hex_digit_is_refused() {
        let a = key(1);
        let good = format!("[{}]", entry(&a));
        TrustAnchors::from_json(&good, "[]").unwrap();

        let flip = |text: &str, from: &str| -> String {
            // Change the last hex digit of the quoted value that follows `from`.
            let at = text.find(from).unwrap() + from.len();
            let end = at + text[at..].find('"').unwrap();
            let mut bytes = text.as_bytes().to_vec();
            bytes[end - 1] = if bytes[end - 1] == b'0' { b'1' } else { b'0' };
            String::from_utf8(bytes).unwrap()
        };
        let bad_id = flip(&good, "\"id\": \"");
        let e = TrustAnchors::from_json(&bad_id, "[]").unwrap_err();
        assert!(
            format!("{e:#}").contains("not the key's fingerprint"),
            "{e:#}"
        );
        let bad_key = flip(&good, "\"key\": \"");
        let e = TrustAnchors::from_json(&bad_key, "[]").unwrap_err();
        let msg = format!("{e:#}");
        assert!(
            msg.contains("not the key's fingerprint") || msg.contains("valid ed25519 point"),
            "{msg}"
        );
    }

    #[test]
    fn malformed_lists_are_refused() {
        let a = key(1);
        let b = key(2);
        let cases: Vec<(String, String, &str)> = vec![
            (
                format!("[{0}, {0}]", entry(&a)),
                "[]".into(),
                "listed twice",
            ),
            (
                format!("[{}]", entry(&a)),
                format!("[\"{}\"]", fingerprint(&a)),
                "both pinned and revoked",
            ),
            (
                format!("[{}]", entry(&a)),
                "[\"abc\"]".into(),
                "is not a fingerprint",
            ),
            (
                format!("[{}]", entry(&a)),
                "[\"0123456789ABCDEF\"]".into(),
                "is not a fingerprint",
            ),
            (
                "[]".into(),
                "[\"0123456789abcdef\", \"0123456789abcdef\"]".into(),
                "listed twice",
            ),
            (
                format!(
                    "[{{\"id\": \"{}\", \"key\": \"{}\"}}]",
                    fingerprint(&b),
                    hex::encode(b.as_bytes()).to_uppercase()
                ),
                "[]".into(),
                "64 lowercase hex",
            ),
            (
                "[{\"id\": \"x\", \"key\": \"y\", \"note\": \"z\"}]".into(),
                "[]".into(),
                "array of",
            ),
            ("{}".into(), "[]".into(), "array of"),
            ("[]".into(), "{}".into(), "array of fingerprint"),
            (
                // The identity point has small order: it verifies nothing worth trusting.
                format!(
                    "[{{\"id\": \"0000000000000000\", \"key\": \"01{}\"}}]",
                    "00".repeat(31)
                ),
                "[]".into(),
                "small-order",
            ),
        ];
        for (pinned, revoked, needle) in cases {
            let e = TrustAnchors::from_json(&pinned, &revoked).unwrap_err();
            assert!(
                format!("{e:#}").contains(needle),
                "wanted {needle:?} for {pinned} / {revoked}: {e:#}"
            );
        }
    }

    #[test]
    fn extra_revocations_only_add() {
        let a = key(3);
        let anchors = TrustAnchors::new(vec![PinnedKey::from_key(a)], vec![]);
        assert!(!anchors.is_revoked(&fingerprint(&a)));
        let anchors = anchors.with_revoked(vec![fingerprint(&a).to_uppercase()]);
        assert!(anchors.is_revoked(&fingerprint(&a)));
        assert_eq!(anchors.pinned().len(), 1, "pinning is untouched");
        assert_eq!(anchors.revoked().count(), 1);
    }

    #[test]
    fn revoked_txt_parses_comments_blank_lines_and_any_case() {
        let text = "# revoked on 2026-11-01\n\n0123456789ABCDEF\n  fedcba9876543210  \n";
        assert_eq!(
            parse_revoked_txt(text).unwrap(),
            vec!["0123456789abcdef", "fedcba9876543210"]
        );
        assert!(parse_revoked_txt("").unwrap().is_empty());
        for bad in [
            "nonsense\n",
            "0123456789abcde\n",
            "0123456789abcdef0\n",
            "0123456789abcdeg\n",
        ] {
            let e = parse_revoked_txt(bad).unwrap_err();
            assert!(format!("{e}").contains("line 1"), "{bad:?}: {e}");
        }
        let e = parse_revoked_txt("0123456789abcdef\noops\n").unwrap_err();
        assert!(format!("{e}").contains("line 2"), "{e}");
    }
}
