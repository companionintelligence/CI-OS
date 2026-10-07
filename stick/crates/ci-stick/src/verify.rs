//! Bundle verification: signature first, then every artifact.
//!
//! Order matters. The signature is checked over the raw bytes of `bundle.json` *before*
//! the manifest is trusted for anything; if it fails, verification stops (fail closed) and
//! no artifact is hashed on the say-so of an untrusted manifest.
//!
//! Artifact checks, per entry: the path is a plain relative path; no component on the way
//! to it is a symlink (exFAT cannot hold symlinks, so one is a red flag and is never
//! followed); the canonical target is still inside the root; it is a regular file; the size
//! matches; and (in [`HashMode::Full`]) the streamed SHA-256 matches. Files on the stick
//! that the manifest does not mention are reported as warnings.

use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context as _};
use ed25519_dalek::VerifyingKey;
use serde::Serialize;

use crate::hashing::hash_file;
use crate::manifest::{Artifact, BootChain, Bundle, BUNDLE_FILE, SIGNATURE_FILE};
use crate::paths::{to_manifest_path, validate_rel_path};
use crate::progress::Progress;
use crate::signing::{fingerprint, parse_signature, verify_detached};
use crate::size::fmt_binary;

/// How to treat `bundle.json.sig`.
pub enum SignaturePolicy {
    /// Production: a valid signature by this key is mandatory.
    Require(VerifyingKey),
    /// `--allow-unsigned`: a missing signature is a warning; a *present* signature is still
    /// checked when a key is available, and a bad one is still fatal.
    AllowUnsigned(Option<VerifyingKey>),
    /// Diagnostics only (`doctor` without `--pubkey`): report, never trust.
    NotChecked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum HashMode {
    Full,
    SizesOnly,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case", tag = "status")]
pub enum SignatureStatus {
    Valid { key_fingerprint: String },
    Invalid { reason: String },
    Missing,
    UnsignedAllowed,
    PresentNotChecked,
    NotChecked,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Finding {
    pub code: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub message: String,
}

impl Finding {
    fn new(code: &'static str, path: Option<&str>, message: impl Into<String>) -> Self {
        Self {
            code,
            path: path.map(str::to_string),
            message: message.into(),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct VerifyReport {
    pub ok: bool,
    pub root: String,
    pub bundle_id: Option<String>,
    pub bundle_version: Option<String>,
    pub signature: SignatureStatus,
    pub hash_mode: HashMode,
    /// The boot chain the (trusted) manifest carries; `None` when it has no bootloader,
    /// an invalid set of them, or was not trusted.
    pub boot_chain: Option<BootChain>,
    pub artifacts_total: usize,
    pub artifacts_ok: usize,
    pub bytes_checked: u64,
    pub errors: Vec<Finding>,
    pub warnings: Vec<Finding>,
}

/// Verify the bundle at `root`.
///
/// `Err` means the check could not be carried out at all (not a directory, no
/// `bundle.json`, unreadable signature file) — the CLI maps that to exit code 2. Integrity
/// problems are returned as findings in an `Ok` report with `ok == false` (exit code 1).
pub fn verify(
    root: &Path,
    policy: &SignaturePolicy,
    mode: HashMode,
    progress: &mut Progress,
) -> anyhow::Result<VerifyReport> {
    let root = fs::canonicalize(root)
        .with_context(|| format!("bundle root {} is not accessible", root.display()))?;
    if !root.is_dir() {
        bail!("bundle root {} is not a directory", root.display());
    }
    let manifest_path = root.join(BUNDLE_FILE);
    let manifest_bytes = fs::read(&manifest_path).with_context(|| {
        format!(
            "reading {} — is this a Companion Stick bundle root?",
            manifest_path.display()
        )
    })?;

    let mut report = VerifyReport {
        ok: false,
        root: root.display().to_string(),
        bundle_id: None,
        bundle_version: None,
        signature: SignatureStatus::NotChecked,
        hash_mode: mode,
        boot_chain: None,
        artifacts_total: 0,
        artifacts_ok: 0,
        bytes_checked: 0,
        errors: Vec::new(),
        warnings: Vec::new(),
    };

    // 1. Signature — before anything in the manifest is believed.
    report.signature = check_signature(&root, &manifest_bytes, policy, &mut report)?;
    if !report.errors.is_empty() {
        return Ok(report);
    }

    // 2. Manifest structure.
    let bundle = match Bundle::parse(&manifest_bytes) {
        Ok(b) => b,
        Err(e) => {
            report.errors.push(Finding::new(
                "manifest-invalid",
                Some(BUNDLE_FILE),
                format!("{e:#}"),
            ));
            return Ok(report);
        }
    };
    report.bundle_id = Some(bundle.id.clone());
    report.bundle_version = Some(bundle.version.clone());
    // An invalid set of bootloaders is reported by validate() below.
    report.boot_chain = bundle.boot_chain().ok().flatten();
    for problem in bundle.validate() {
        report
            .errors
            .push(Finding::new("manifest-invalid", Some(BUNDLE_FILE), problem));
    }

    // 3. Artifacts.
    report.artifacts_total = bundle.artifacts.len();
    progress.set_total(bundle.artifacts.len());
    for (i, artifact) in bundle.artifacts.iter().enumerate() {
        match check_artifact(&root, artifact, mode, i + 1, progress) {
            Ok(bytes) => {
                report.artifacts_ok += 1;
                report.bytes_checked += bytes;
            }
            Err(f) => report.errors.push(f),
        }
    }
    progress.finish();

    // 4. Untracked files.
    let tracked: BTreeSet<&str> = bundle.artifacts.iter().map(|a| a.path.as_str()).collect();
    scan_untracked(&root, &root, &tracked, &mut report.warnings);

    report.ok = report.errors.is_empty();
    Ok(report)
}

fn check_signature(
    root: &Path,
    manifest: &[u8],
    policy: &SignaturePolicy,
    report: &mut VerifyReport,
) -> anyhow::Result<SignatureStatus> {
    let sig_path = root.join(SIGNATURE_FILE);
    let sig_bytes = match fs::symlink_metadata(&sig_path) {
        Ok(meta) if meta.is_file() => {
            Some(fs::read(&sig_path).with_context(|| format!("reading {}", sig_path.display()))?)
        }
        Ok(_) => {
            report.errors.push(Finding::new(
                "signature-invalid",
                Some(SIGNATURE_FILE),
                "bundle.json.sig is not a regular file",
            ));
            return Ok(SignatureStatus::Invalid {
                reason: "not a regular file".into(),
            });
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(e).with_context(|| format!("inspecting {}", sig_path.display())),
    };

    let key = match policy {
        SignaturePolicy::Require(k) => Some(k),
        SignaturePolicy::AllowUnsigned(k) => k.as_ref(),
        SignaturePolicy::NotChecked => None,
    };

    let Some(sig_bytes) = sig_bytes else {
        return Ok(match policy {
            SignaturePolicy::Require(_) => {
                report.errors.push(Finding::new(
                    "signature-missing",
                    Some(SIGNATURE_FILE),
                    "bundle.json.sig not found — refusing to trust an unsigned bundle \
                     (development only: --allow-unsigned)",
                ));
                SignatureStatus::Missing
            }
            SignaturePolicy::AllowUnsigned(_) => {
                report.warnings.push(Finding::new(
                    "unsigned",
                    Some(SIGNATURE_FILE),
                    "bundle is UNSIGNED and was accepted only because --allow-unsigned was given",
                ));
                SignatureStatus::UnsignedAllowed
            }
            SignaturePolicy::NotChecked => SignatureStatus::NotChecked,
        });
    };

    let Some(key) = key else {
        report.warnings.push(Finding::new(
            "signature-not-checked",
            Some(SIGNATURE_FILE),
            "a signature is present but no trusted public key was given (--pubkey), so it was not checked",
        ));
        return Ok(SignatureStatus::PresentNotChecked);
    };

    let result = parse_signature(&sig_bytes).and_then(|sig| verify_detached(key, manifest, &sig));
    Ok(match result {
        Ok(()) => SignatureStatus::Valid {
            key_fingerprint: fingerprint(key),
        },
        Err(e) => {
            report.errors.push(Finding::new(
                "signature-invalid",
                Some(SIGNATURE_FILE),
                e.to_string(),
            ));
            SignatureStatus::Invalid {
                reason: e.to_string(),
            }
        }
    })
}

/// Returns the number of bytes checked, or the first problem found.
fn check_artifact(
    root: &Path,
    artifact: &Artifact,
    mode: HashMode,
    index: usize,
    progress: &mut Progress,
) -> Result<u64, Finding> {
    let p = artifact.path.as_str();
    if let Err(e) = validate_rel_path(p) {
        return Err(Finding::new("path-escape", Some(p), e.to_string()));
    }

    // Walk component by component so no symlink anywhere on the path is followed.
    let comps: Vec<&str> = p.split('/').collect();
    let mut cur = root.to_path_buf();
    let mut meta = None;
    for (i, comp) in comps.iter().enumerate() {
        cur.push(comp);
        let m = match fs::symlink_metadata(&cur) {
            Ok(m) => m,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                return Err(Finding::new("missing", Some(p), "artifact is missing"));
            }
            Err(e) => return Err(Finding::new("io-error", Some(p), e.to_string())),
        };
        if m.file_type().is_symlink() {
            return Err(Finding::new(
                "symlink",
                Some(p),
                format!(
                    "{} is a symlink; bundles never contain symlinks, refusing to follow",
                    comps[..=i].join("/")
                ),
            ));
        }
        if i + 1 < comps.len() && !m.is_dir() {
            return Err(Finding::new(
                "missing",
                Some(p),
                format!("{} is not a directory", comps[..=i].join("/")),
            ));
        }
        meta = Some(m);
    }
    let Some(meta) = meta else {
        return Err(Finding::new("path-escape", Some(p), "empty path"));
    };
    if !meta.is_file() {
        return Err(Finding::new(
            "not-a-file",
            Some(p),
            "artifact is not a regular file",
        ));
    }
    // Belt and braces: the resolved path must still live under the root.
    match fs::canonicalize(&cur) {
        Ok(real) if real.starts_with(root) => {}
        Ok(real) => {
            return Err(Finding::new(
                "path-escape",
                Some(p),
                format!("resolves outside the bundle root to {}", real.display()),
            ))
        }
        Err(e) => return Err(Finding::new("io-error", Some(p), e.to_string())),
    }
    if meta.len() != artifact.size {
        return Err(Finding::new(
            "size-mismatch",
            Some(p),
            format!(
                "size is {} bytes, manifest says {}",
                meta.len(),
                artifact.size
            ),
        ));
    }
    if mode == HashMode::SizesOnly {
        return Ok(meta.len());
    }
    let size = artifact.size;
    let digest = hash_file(&cur, |done| progress.update(index, p, done, size))
        .map_err(|e| Finding::new("io-error", Some(p), format!("reading: {e}")))?;
    if digest.size != artifact.size {
        return Err(Finding::new(
            "size-mismatch",
            Some(p),
            format!(
                "read {} bytes, manifest says {} (file changed while hashing?)",
                digest.size, artifact.size
            ),
        ));
    }
    if digest.sha256 != artifact.sha256 {
        return Err(Finding::new(
            "sha256-mismatch",
            Some(p),
            format!(
                "sha256 is {}, manifest says {}",
                digest.sha256, artifact.sha256
            ),
        ));
    }
    Ok(digest.size)
}

fn scan_untracked(root: &Path, dir: &Path, tracked: &BTreeSet<&str>, warnings: &mut Vec<Finding>) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) => {
            warnings.push(Finding::new(
                "unreadable-dir",
                None,
                format!("{}: {e}", dir.display()),
            ));
            return;
        }
    };
    let mut paths: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
    paths.sort();
    for path in paths {
        let rel = path.strip_prefix(root).unwrap_or(&path);
        let display = to_manifest_path(rel).unwrap_or_else(|_| rel.to_string_lossy().into_owned());
        if dir == root && (display == BUNDLE_FILE || display == SIGNATURE_FILE) {
            continue;
        }
        let Ok(meta) = fs::symlink_metadata(&path) else {
            continue;
        };
        if meta.file_type().is_symlink() {
            warnings.push(Finding::new(
                "untracked-symlink",
                Some(&display),
                "symlink not listed in the manifest (not followed)",
            ));
        } else if meta.is_dir() {
            scan_untracked(root, &path, tracked, warnings);
        } else if !tracked.contains(display.as_str()) {
            warnings.push(Finding::new(
                "untracked",
                Some(&display),
                "file is not listed in bundle.json",
            ));
        }
    }
}

/// Human-readable rendering of a report.
pub fn render_human(r: &VerifyReport) -> String {
    let mut out = String::new();
    let id = match (&r.bundle_id, &r.bundle_version) {
        (Some(id), Some(v)) => format!("{id} {v}"),
        _ => "(manifest not trusted)".into(),
    };
    out.push_str(&format!("Bundle    {id}\nRoot      {}\n", r.root));
    let sig = match &r.signature {
        SignatureStatus::Valid { key_fingerprint } => format!("valid (key {key_fingerprint})"),
        SignatureStatus::Invalid { reason } => format!("INVALID — {reason}"),
        SignatureStatus::Missing => "MISSING".into(),
        SignatureStatus::UnsignedAllowed => "none (accepted: --allow-unsigned)".into(),
        SignatureStatus::PresentNotChecked => "present, not checked (no --pubkey)".into(),
        SignatureStatus::NotChecked => "not checked".into(),
    };
    out.push_str(&format!("Signature {sig}\n"));
    let mode = match r.hash_mode {
        HashMode::Full => "sha256 + size",
        HashMode::SizesOnly => "size only",
    };
    if r.bundle_id.is_some() {
        let boot = match r.boot_chain {
            Some(c) => c.secure_boot_line(),
            None => "no bootloader in this bundle (it cannot be flashed)",
        };
        out.push_str(&format!("Boot      {boot}\n"));
        out.push_str(&format!(
            "Artifacts {}/{} ok ({mode}, {} checked)\n",
            r.artifacts_ok,
            r.artifacts_total,
            fmt_binary(r.bytes_checked)
        ));
    } else {
        out.push_str("Artifacts not checked — the manifest was not trusted\n");
    }
    for f in &r.errors {
        out.push_str(&format!(
            "  ✖ [{}] {}{}\n",
            f.code,
            f.path
                .as_deref()
                .map(|p| format!("{p}: "))
                .unwrap_or_default(),
            f.message
        ));
    }
    for f in &r.warnings {
        out.push_str(&format!(
            "  ! [{}] {}{}\n",
            f.code,
            f.path
                .as_deref()
                .map(|p| format!("{p}: "))
                .unwrap_or_default(),
            f.message
        ));
    }
    out.push_str(if r.ok {
        "Result    OK\n"
    } else {
        "Result    FAILED\n"
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lock::{lock, LockOptions};
    use crate::signing::sign_to_hex;
    use ed25519_dalek::SigningKey;

    struct Fixture {
        dir: tempfile::TempDir,
        key: SigningKey,
    }

    impl Fixture {
        fn new() -> Self {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path();
            for (p, data) in [
                ("boot/ci-os-ubuntu-x86_64.img", &b"boot image"[..]),
                ("installers/macos-arm64/ci-hub.pkg", b"pkg"),
                ("models/blobs/sha256-aa", b"model weights"),
                ("docs/README.txt", b"hello"),
            ] {
                let full = root.join(p);
                fs::create_dir_all(full.parent().unwrap()).unwrap();
                fs::write(full, data).unwrap();
            }
            let opts = LockOptions {
                id: Some("test-bundle".into()),
                version: Some("0.0.1".into()),
                packs: None,
                device_bytes: Some(128_000_000_000),
                created_at: Some("2026-09-28T00:00:00Z".into()),
            };
            lock(root, &opts, &mut Progress::disabled()).unwrap();
            let key = SigningKey::from_bytes(&[42u8; 32]);
            let fx = Self { dir, key };
            fx.sign();
            fx
        }
        fn root(&self) -> &Path {
            self.dir.path()
        }
        fn sign(&self) {
            let bytes = fs::read(self.root().join(BUNDLE_FILE)).unwrap();
            fs::write(
                self.root().join(SIGNATURE_FILE),
                sign_to_hex(&self.key, &bytes),
            )
            .unwrap();
        }
        fn run(&self) -> VerifyReport {
            let policy = SignaturePolicy::Require(self.key.verifying_key());
            verify(
                self.root(),
                &policy,
                HashMode::Full,
                &mut Progress::disabled(),
            )
            .unwrap()
        }
        fn codes(&self) -> Vec<&'static str> {
            self.run().errors.iter().map(|f| f.code).collect()
        }
    }

    #[test]
    fn clean_bundle_verifies() {
        let fx = Fixture::new();
        let r = fx.run();
        assert!(r.ok, "{}", render_human(&r));
        assert_eq!(r.artifacts_ok, 4);
        assert!(matches!(r.signature, SignatureStatus::Valid { .. }));
        assert!(r.warnings.is_empty());
    }

    #[test]
    fn reports_the_boot_chain() {
        let fx = Fixture::new();
        let r = fx.run();
        assert_eq!(r.boot_chain, None);
        assert!(render_human(&r).contains("Boot      no bootloader"));

        fs::create_dir_all(fx.root().join("efi")).unwrap();
        for f in ["shimx64.efi", "grubx64.efi", "mmx64.efi"] {
            fs::write(fx.root().join("efi").join(f), b"MZ").unwrap();
        }
        lock(
            fx.root(),
            &LockOptions::default(),
            &mut Progress::disabled(),
        )
        .unwrap();
        fx.sign();
        let r = fx.run();
        assert!(r.ok, "{}", render_human(&r));
        assert_eq!(r.boot_chain, Some(BootChain::Secure));
        assert!(
            render_human(&r).contains("Boot      Secure Boot: supported (shim → Canonical GRUB)")
        );

        for f in ["shimx64.efi", "grubx64.efi", "mmx64.efi"] {
            fs::remove_file(fx.root().join("efi").join(f)).unwrap();
        }
        fs::write(fx.root().join("efi/BOOTX64.EFI"), b"MZ").unwrap();
        lock(
            fx.root(),
            &LockOptions::default(),
            &mut Progress::disabled(),
        )
        .unwrap();
        fx.sign();
        let r = fx.run();
        assert_eq!(r.boot_chain, Some(BootChain::Development));
        assert!(render_human(&r).contains("Secure Boot: NOT supported"));
    }

    #[test]
    fn tampered_content_same_size_is_caught() {
        let fx = Fixture::new();
        fs::write(fx.root().join("docs/README.txt"), b"HELLO").unwrap();
        assert_eq!(fx.codes(), vec!["sha256-mismatch"]);
        // Size-only mode cannot see same-size tampering — that's why it's "quick".
        let r = verify(
            fx.root(),
            &SignaturePolicy::NotChecked,
            HashMode::SizesOnly,
            &mut Progress::disabled(),
        )
        .unwrap();
        assert!(r.ok);
    }

    #[test]
    fn size_change_and_missing_files_are_caught() {
        let fx = Fixture::new();
        fs::write(fx.root().join("docs/README.txt"), b"hello!").unwrap();
        fs::remove_file(fx.root().join("models/blobs/sha256-aa")).unwrap();
        let mut codes = fx.codes();
        codes.sort_unstable();
        assert_eq!(codes, vec!["missing", "size-mismatch"]);
    }

    #[test]
    fn untracked_files_are_warnings_not_errors() {
        let fx = Fixture::new();
        fs::write(fx.root().join("docs/extra.txt"), b"x").unwrap();
        let r = fx.run();
        assert!(r.ok);
        assert_eq!(r.warnings.len(), 1);
        assert_eq!(r.warnings[0].path.as_deref(), Some("docs/extra.txt"));
    }

    #[test]
    fn manifest_tampering_breaks_the_signature_and_stops_early() {
        let fx = Fixture::new();
        let path = fx.root().join(BUNDLE_FILE);
        let text = fs::read_to_string(&path).unwrap().replace("0.0.1", "0.0.2");
        fs::write(&path, text).unwrap();
        let r = fx.run();
        assert!(!r.ok);
        assert_eq!(r.errors.len(), 1);
        assert_eq!(r.errors[0].code, "signature-invalid");
        assert_eq!(
            r.bundle_id, None,
            "an unverified manifest must not be reported as trusted"
        );
    }

    #[test]
    fn missing_or_garbage_signature_fails_closed() {
        let fx = Fixture::new();
        fs::remove_file(fx.root().join(SIGNATURE_FILE)).unwrap();
        assert_eq!(fx.codes(), vec!["signature-missing"]);
        fs::write(fx.root().join(SIGNATURE_FILE), "not a signature").unwrap();
        assert_eq!(fx.codes(), vec!["signature-invalid"]);
    }

    #[test]
    fn wrong_key_fails() {
        let fx = Fixture::new();
        let other = SigningKey::from_bytes(&[1u8; 32]).verifying_key();
        let r = verify(
            fx.root(),
            &SignaturePolicy::Require(other),
            HashMode::Full,
            &mut Progress::disabled(),
        )
        .unwrap();
        assert_eq!(r.errors[0].code, "signature-invalid");
    }

    #[test]
    fn allow_unsigned_warns_but_still_rejects_bad_signatures() {
        let fx = Fixture::new();
        fs::remove_file(fx.root().join(SIGNATURE_FILE)).unwrap();
        let policy = SignaturePolicy::AllowUnsigned(None);
        let r = verify(
            fx.root(),
            &policy,
            HashMode::Full,
            &mut Progress::disabled(),
        )
        .unwrap();
        assert!(r.ok);
        assert_eq!(r.signature, SignatureStatus::UnsignedAllowed);
        assert_eq!(r.warnings[0].code, "unsigned");

        fs::write(fx.root().join(SIGNATURE_FILE), "00".repeat(64)).unwrap();
        let policy = SignaturePolicy::AllowUnsigned(Some(fx.key.verifying_key()));
        let r = verify(
            fx.root(),
            &policy,
            HashMode::Full,
            &mut Progress::disabled(),
        )
        .unwrap();
        assert!(
            !r.ok,
            "a present-but-bad signature is fatal even with --allow-unsigned"
        );
    }

    fn rewrite_first_path(fx: &Fixture, new_path: &str) {
        let path = fx.root().join(BUNDLE_FILE);
        let mut b = Bundle::load(&path).unwrap();
        b.artifacts[0].path = new_path.into();
        fs::write(&path, b.to_canonical_json()).unwrap();
        fx.sign();
    }

    #[test]
    fn escaping_paths_are_rejected_even_when_signed() {
        for bad in ["../outside", "/etc/passwd", "boot/../../outside"] {
            let fx = Fixture::new();
            rewrite_first_path(&fx, bad);
            let codes = fx.codes();
            assert!(codes.contains(&"path-escape"), "{bad}: {codes:?}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn symlink_escapes_are_rejected() {
        let fx = Fixture::new();
        let outside = tempfile::tempdir().unwrap();
        fs::write(outside.path().join("img"), b"boot image").unwrap();
        // Replace the boot directory with a symlink pointing outside the root.
        fs::remove_dir_all(fx.root().join("boot")).unwrap();
        std::os::unix::fs::symlink(outside.path(), fx.root().join("boot")).unwrap();
        let codes = fx.codes();
        assert!(codes.contains(&"symlink"), "{codes:?}");

        // A symlinked file (even pointing inside the root) is also refused.
        let fx = Fixture::new();
        let f = fx.root().join("docs/README.txt");
        fs::remove_file(&f).unwrap();
        std::os::unix::fs::symlink(fx.root().join("models/blobs/sha256-aa"), &f).unwrap();
        assert_eq!(fx.codes(), vec!["symlink"]);
    }

    #[test]
    fn not_a_bundle_is_an_io_error() {
        let dir = tempfile::tempdir().unwrap();
        let r = verify(
            dir.path(),
            &SignaturePolicy::NotChecked,
            HashMode::Full,
            &mut Progress::disabled(),
        );
        assert!(r.is_err());
    }
}
