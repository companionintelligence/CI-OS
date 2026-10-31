//! Bundle verification: signature first, then freshness, then every artifact.
//!
//! Order matters. The signature is checked over the raw bytes of `bundle.json` *before*
//! the manifest is trusted for anything; if it fails, verification stops (fail closed) and
//! no artifact is hashed on the say-so of an untrusted manifest.
//!
//! Next, and still before any artifact is hashed, a bundle whose signature held is checked
//! for freshness: a schema 2 bundle past its `expires_at` is refused (`bundle-expired`), and
//! so is one whose `sequence` is below the floor this machine has stored for the bundle `id`
//! (`bundle-rollback`), or equal to it with different `bundle.json` bytes
//! (`bundle-sequence-conflict`). Re-verifying the very same bytes is fine. A key that is
//! revoked is refused whatever the policy (`signature-key-revoked`). Only a manifest the
//! signature vouched for says anything about its own age: an unsigned one is never used to
//! move a floor.
//!
//! The floor advances only when the whole verification succeeded, and only when the caller
//! asked for it ([`FloorMode::Store`] with `record`): `verify` does, `doctor` and `flash
//! --dry-run` never do, and `flash` records after the stick was written.
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

use anyhow::{bail, ensure, Context as _};
use ed25519_dalek::VerifyingKey;
use serde::Serialize;

use crate::hashing::{hash_file, sha256_hex};
use crate::manifest::{Artifact, BootChain, Bundle, BUNDLE_FILE, SCHEMA_V1, SIGNATURE_FILE};
use crate::paths::{to_manifest_path, validate_rel_path};
use crate::progress::Progress;
use crate::signing::{fingerprint, parse_signature, verify_detached};
use crate::size::fmt_binary;
use crate::state::{Floor, FloorStore, FloorUpdate, StateError};
use crate::timefmt::{format_unix, parse_rfc3339_utc};
use crate::trust::TrustAnchors;

/// How to treat `bundle.json.sig`.
pub enum SignaturePolicy {
    /// Production: a valid signature by this key is mandatory.
    Require(VerifyingKey),
    /// `--allow-unsigned`: a missing signature is a warning; a *present* signature is still
    /// checked when a key is available, and a bad one is still fatal.
    AllowUnsigned(Option<VerifyingKey>),
    /// Diagnostics only (`doctor` without `--pubkey`): report, never trust.
    NotChecked,
    /// Production once a release key is compiled in: a valid signature by one of these
    /// pinned keys is mandatory, and a bundle that carries no sequence and expiry (schema 1)
    /// is refused. A key that verifies but is revoked gives `signature-key-revoked`.
    Pinned(TrustAnchors),
}

/// Everything besides the signature policy that decides whether a correctly signed bundle
/// is still acceptable: the clock, revoked keys, and where the sequence floors live.
pub struct Freshness {
    /// Unix seconds, injected so that tests need no clock.
    pub now: u64,
    /// Key fingerprints refused whatever the policy says: the revocations compiled into this
    /// build plus the state directory's `revoked.txt`. A [`SignaturePolicy::Pinned`] also
    /// honours the revocations it carries.
    pub revoked: Vec<String>,
    pub floors: FloorMode,
}

/// What to do about the sequence floors.
pub enum FloorMode {
    /// Floors are neither read nor written. Expiry is still enforced. For tests, and for
    /// callers that have no state directory and do not write.
    Off,
    /// No state directory could be determined. With `required` that refuses a schema 2
    /// bundle (an error, exit 2); otherwise it is a warning.
    Unavailable { reason: String, required: bool },
    /// Read the floors in `store`. `required` (pinned and `--device` flows): an unusable
    /// store refuses; otherwise it only warns. `record`: after a fully successful
    /// verification, raise the floor.
    Store {
        store: FloorStore,
        required: bool,
        record: bool,
    },
}

impl Freshness {
    /// Expiry only: no floors, no extra revocations.
    pub fn without_floors(now: u64) -> Self {
        Self {
            now,
            revoked: Vec::new(),
            floors: FloorMode::Off,
        }
    }

    /// Must the sequence floor be usable for this verification to count?
    pub fn floors_required(&self) -> bool {
        match &self.floors {
            FloorMode::Off => false,
            FloorMode::Unavailable { required, .. } | FloorMode::Store { required, .. } => {
                *required
            }
        }
    }
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
    Valid {
        key_fingerprint: String,
        /// Schema 2: the bundle's release counter.
        #[serde(skip_serializing_if = "Option::is_none")]
        sequence: Option<u64>,
        /// Schema 2: from this instant on the bundle is refused.
        #[serde(skip_serializing_if = "Option::is_none")]
        expires_at: Option<String>,
    },
    Invalid {
        reason: String,
    },
    Missing,
    UnsignedAllowed,
    PresentNotChecked,
    NotChecked,
}

impl SignatureStatus {
    fn valid(key_fingerprint: String) -> Self {
        Self::Valid {
            key_fingerprint,
            sequence: None,
            expires_at: None,
        }
    }
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
    /// What accepting this bundle would record as its floor: set for a schema 2 bundle whose
    /// signature held and whose expiry and floor checks passed.
    #[serde(skip)]
    pub floor_update: Option<FloorUpdate>,
}

/// Verify the bundle at `root`.
///
/// `Err` means the check could not be carried out at all (not a directory, no
/// `bundle.json`, unreadable signature file, a damaged floor file, a required state directory
/// that cannot be used): the CLI maps that to exit code 2. Integrity problems are returned
/// as findings in an `Ok` report with `ok == false` (exit code 1).
pub fn verify_at(
    root: &Path,
    policy: &SignaturePolicy,
    fresh: &Freshness,
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
        floor_update: None,
    };

    // 1. Signature — before anything in the manifest is believed.
    report.signature = check_signature(&root, &manifest_bytes, policy, fresh, &mut report)?;
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
    // The signature vouched for these bytes, so what they say about their age belongs next to it.
    if let SignatureStatus::Valid {
        sequence,
        expires_at,
        ..
    } = &mut report.signature
    {
        *sequence = bundle.sequence;
        *expires_at = bundle.expires_at.clone();
    }
    // An invalid set of bootloaders is reported by validate() below.
    report.boot_chain = bundle.boot_chain().ok().flatten();
    for problem in bundle.validate() {
        report
            .errors
            .push(Finding::new("manifest-invalid", Some(BUNDLE_FILE), problem));
    }

    // 3. Freshness, still before any artifact is hashed.
    let errors_before = report.errors.len();
    let pending = check_freshness(policy, fresh, &bundle, &manifest_bytes, &mut report)?;
    if report.errors.len() > errors_before {
        return Ok(report);
    }

    // 4. Artifacts.
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

    // 5. Untracked files.
    let tracked: BTreeSet<&str> = bundle.artifacts.iter().map(|a| a.path.as_str()).collect();
    scan_untracked(&root, &root, &tracked, &mut report.warnings);

    report.ok = report.errors.is_empty();

    // 6. Only now, with every check passed, does the floor move.
    if report.ok {
        if let Some(pending) = pending {
            match pending.store.record(&pending.update) {
                Ok(_) => {}
                Err(e) if pending.required => return Err(e.into()),
                Err(e) => report.warnings.push(Finding::new(
                    "floor-not-recorded",
                    None,
                    format!("the sequence floor was not recorded: {e}"),
                )),
            }
        }
    }
    Ok(report)
}

fn check_signature(
    root: &Path,
    manifest: &[u8],
    policy: &SignaturePolicy,
    fresh: &Freshness,
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

    let Some(sig_bytes) = sig_bytes else {
        return Ok(match policy {
            SignaturePolicy::Require(_) | SignaturePolicy::Pinned(_) => {
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

    // Which key may vouch for this bundle.
    let key = match policy {
        SignaturePolicy::Require(k) | SignaturePolicy::AllowUnsigned(Some(k)) => k,
        SignaturePolicy::AllowUnsigned(None) | SignaturePolicy::NotChecked => {
            report.warnings.push(Finding::new(
                "signature-not-checked",
                Some(SIGNATURE_FILE),
                "a signature is present but no trusted public key was given (--pubkey), so it was not checked",
            ));
            return Ok(SignatureStatus::PresentNotChecked);
        }
        SignaturePolicy::Pinned(anchors) => {
            return check_pinned(anchors, manifest, &sig_bytes, fresh, report);
        }
    };

    let verdict = parse_signature(&sig_bytes).and_then(|sig| verify_detached(key, manifest, &sig));
    Ok(match verdict {
        Ok(()) => {
            let fp = fingerprint(key);
            if is_revoked(fresh, None, &fp) {
                refuse_revoked(report, &fp)
            } else {
                SignatureStatus::valid(fp)
            }
        }
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

/// Is `fp` refused, by the context or by the anchors of a `Pinned` policy?
fn is_revoked(fresh: &Freshness, anchors: Option<&TrustAnchors>, fp: &str) -> bool {
    fresh.revoked.iter().any(|r| r.eq_ignore_ascii_case(fp))
        || anchors.is_some_and(|a| a.is_revoked(fp))
}

fn refuse_revoked(report: &mut VerifyReport, fp: &str) -> SignatureStatus {
    report.errors.push(Finding::new(
        "signature-key-revoked",
        Some(SIGNATURE_FILE),
        format!("the key {fp} that signed this bundle has been revoked; a bundle signed by a current key is needed"),
    ));
    SignatureStatus::Invalid {
        reason: format!("key {fp} is revoked"),
    }
}

/// The `Pinned` policy: some non-revoked pinned key must verify the signature.
fn check_pinned(
    anchors: &TrustAnchors,
    manifest: &[u8],
    sig_bytes: &[u8],
    fresh: &Freshness,
    report: &mut VerifyReport,
) -> anyhow::Result<SignatureStatus> {
    if !anchors.has_pinned_keys() {
        let reason = "no release key is pinned in this build (KI-23), so nothing here can vouch \
                      for this bundle";
        report.errors.push(Finding::new(
            "signature-key-unknown",
            Some(SIGNATURE_FILE),
            reason,
        ));
        return Ok(SignatureStatus::Invalid {
            reason: reason.into(),
        });
    }
    let sig = match parse_signature(sig_bytes) {
        Ok(s) => s,
        Err(e) => {
            report.errors.push(Finding::new(
                "signature-invalid",
                Some(SIGNATURE_FILE),
                e.to_string(),
            ));
            return Ok(SignatureStatus::Invalid {
                reason: e.to_string(),
            });
        }
    };
    let mut revoked_signer: Option<&str> = None;
    for pinned in anchors.pinned() {
        if verify_detached(&pinned.key, manifest, &sig).is_err() {
            continue;
        }
        if is_revoked(fresh, Some(anchors), &pinned.id) {
            // Keep looking: another, current key might be the one that signed.
            revoked_signer.get_or_insert(&pinned.id);
            continue;
        }
        return Ok(SignatureStatus::valid(pinned.id.clone()));
    }
    if let Some(fp) = revoked_signer {
        return Ok(refuse_revoked(report, fp));
    }
    let reason = "signature does not verify against any pinned release key";
    report.errors.push(Finding::new(
        "signature-invalid",
        Some(SIGNATURE_FILE),
        reason,
    ));
    Ok(SignatureStatus::Invalid {
        reason: reason.into(),
    })
}

/// A floor that [`verify_at`] records once everything else has passed.
struct PendingFloor {
    store: FloorStore,
    update: FloorUpdate,
    required: bool,
}

/// Expiry and sequence floor of a bundle whose signature held. Findings go into `report`;
/// the return value is the floor to record after a fully successful verification, if the
/// caller asked for that. `Err` for what cannot be judged at all: a damaged floor file, or
/// a state directory that is required and unusable.
fn check_freshness(
    policy: &SignaturePolicy,
    fresh: &Freshness,
    bundle: &Bundle,
    manifest: &[u8],
    report: &mut VerifyReport,
) -> anyhow::Result<Option<PendingFloor>> {
    // An unverified manifest says nothing about its own age.
    let SignatureStatus::Valid {
        key_fingerprint: signer,
        ..
    } = &report.signature
    else {
        return Ok(None);
    };
    let signer = signer.clone();

    let (Some(sequence), Some(expires_text)) = (bundle.sequence, bundle.expires_at.as_deref())
    else {
        if matches!(policy, SignaturePolicy::Pinned(_)) && bundle.schema_version == SCHEMA_V1 {
            report.errors.push(Finding::new(
                "bundle-freshness-missing",
                Some(BUNDLE_FILE),
                "this bundle has no sequence and no expiry (schema_version 1), so nothing \
                 protects against an old bundle; a build with a pinned release key accepts \
                 only schema_version 2",
            ));
        }
        // A schema 2 bundle missing them was already reported by validate().
        return Ok(None);
    };
    let Some(expires) = parse_rfc3339_utc(expires_text) else {
        return Ok(None); // validate() has said so
    };
    let before = report.errors.len();

    if fresh.now >= expires {
        report.errors.push(Finding::new(
            "bundle-expired",
            Some(BUNDLE_FILE),
            format!(
                "the bundle expired at {expires_text} (this machine's clock reads {}); a newer \
                 release is needed, or the clock is wrong",
                format_unix(fresh.now)
            ),
        ));
    }

    let (store, required, record) = match &fresh.floors {
        FloorMode::Off => return Ok(None),
        FloorMode::Unavailable { reason, required } => {
            ensure!(
                !*required,
                "the sequence floor cannot be checked, and this verification needs it: {reason}"
            );
            report.warnings.push(Finding::new(
                "floor-not-checked",
                None,
                format!("the sequence floor was not checked: {reason}"),
            ));
            return Ok(None);
        }
        FloorMode::Store {
            store,
            required,
            record,
        } => (store, *required, *record),
    };

    let floor: Option<Floor> = match store.floor(&bundle.id) {
        Ok(f) => f,
        // A damaged file is never guessed around, in any flow.
        Err(e @ StateError::Damaged(_)) => return Err(e.into()),
        Err(e) if required => return Err(e.into()),
        Err(e) => {
            report.warnings.push(Finding::new(
                "floor-not-checked",
                None,
                format!("the sequence floor was not checked: {e}"),
            ));
            return Ok(None);
        }
    };
    let digest = sha256_hex(manifest);
    if let Some(f) = &floor {
        if sequence < f.sequence {
            report.errors.push(Finding::new(
                "bundle-rollback",
                Some(BUNDLE_FILE),
                format!(
                    "sequence {sequence} is below {}, the highest this machine has accepted for \
                     {}: an older release is refused",
                    f.sequence, bundle.id
                ),
            ));
        } else if sequence == f.sequence && digest != f.bundle_sha256 {
            report.errors.push(Finding::new(
                "bundle-sequence-conflict",
                Some(BUNDLE_FILE),
                format!(
                    "sequence {sequence} of {} was accepted here with different bundle.json \
                     bytes (sha256 {}); two different bundles must not share a sequence",
                    bundle.id,
                    &f.bundle_sha256[..12]
                ),
            ));
        }
    }
    if report.errors.len() > before {
        return Ok(None);
    }

    let update = FloorUpdate {
        bundle_id: bundle.id.clone(),
        floor: Floor {
            sequence,
            bundle_sha256: digest,
            signer,
        },
    };
    report.floor_update = Some(update.clone());
    if !(record || required) {
        return Ok(None);
    }
    // Prove now, before a single artifact is hashed, that the floor can be written later.
    if let Err(e) = store.ensure_writable() {
        if required {
            return Err(e.into());
        }
        report.warnings.push(Finding::new(
            "floor-not-recorded",
            None,
            format!("the sequence floor will not be recorded: {e}"),
        ));
        return Ok(None);
    }
    Ok(record.then(|| PendingFloor {
        store: store.clone(),
        update,
        required,
    }))
}

/// The command line's wishes about keys, before the build's trust anchors have their say.
pub struct PolicyRequest {
    /// `--pubkey`
    pub pubkey: Option<VerifyingKey>,
    /// `--development-key`: the key from `--pubkey` is a development key, accepted even
    /// though this build pins release keys.
    pub development_key: bool,
    /// `--allow-unsigned`
    pub allow_unsigned: bool,
    /// The target is a physical device (`flash --device`).
    pub device: bool,
}

pub struct ChosenPolicy {
    pub policy: SignaturePolicy,
    /// Lines for stderr: warnings the user must see, and the note about the missing key.
    pub notes: Vec<String>,
}

pub const UNSIGNED_WARNING: &str = "WARNING: --allow-unsigned given. An unsigned bundle proves \
    NOTHING about who built it. Use this only for local development bundles, never for a \
    stick you will hand to someone.";
pub const DEVELOPMENT_KEY_WARNING: &str = "WARNING: --development-key given. The key came from \
    the command line, not from the release keys pinned in this build, so this checks a \
    development bundle only. Never use it for a stick you will hand to someone.";
pub const NO_PINNED_KEY_NOTE: &str = "note: no release key is pinned in this build (KI-23); \
    the bundle is trusted only as far as the key given with --pubkey.";

/// Turn the command line plus the build's trust anchors into a signature policy.
///
/// While the build pins no key (today) `--pubkey` is the only key source and nothing changes
/// but a note. Once it pins one, the default is [`SignaturePolicy::Pinned`], `--pubkey` is
/// accepted only together with `--development-key` (with a loud warning), and never with a
/// device.
pub fn choose_policy(anchors: &TrustAnchors, req: PolicyRequest) -> anyhow::Result<ChosenPolicy> {
    let pinned = anchors.has_pinned_keys();
    let mut notes = Vec::new();
    if req.allow_unsigned {
        notes.push(UNSIGNED_WARNING.to_string());
    }
    let policy = match req.pubkey {
        Some(key) => {
            if pinned {
                ensure!(
                    req.development_key,
                    "this build pins release keys, so --pubkey is accepted only with \
                     --development-key, for a development bundle"
                );
                ensure!(
                    !req.device,
                    "--pubkey and --development-key are refused with --device: a physical stick \
                     is only ever written from a bundle signed by a pinned release key"
                );
                notes.push(DEVELOPMENT_KEY_WARNING.to_string());
            } else {
                notes.push(NO_PINNED_KEY_NOTE.to_string());
            }
            if req.allow_unsigned {
                SignaturePolicy::AllowUnsigned(Some(key))
            } else {
                SignaturePolicy::Require(key)
            }
        }
        None if req.allow_unsigned => SignaturePolicy::AllowUnsigned(None),
        None if pinned => SignaturePolicy::Pinned(anchors.clone()),
        None => bail!(
            "a trusted public key is required: --pubkey <hex|file> \
             (or --allow-unsigned for development bundles). No release key is pinned in this \
             build (KI-23), so there is no default"
        ),
    };
    Ok(ChosenPolicy { policy, notes })
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
        SignatureStatus::Valid {
            key_fingerprint, ..
        } => format!("valid (key {key_fingerprint})"),
        SignatureStatus::Invalid { reason } => format!("INVALID — {reason}"),
        SignatureStatus::Missing => "MISSING".into(),
        SignatureStatus::UnsignedAllowed => "none (accepted: --allow-unsigned)".into(),
        SignatureStatus::PresentNotChecked => "present, not checked (no --pubkey)".into(),
        SignatureStatus::NotChecked => "not checked".into(),
    };
    out.push_str(&format!("Signature {sig}\n"));
    if let SignatureStatus::Valid {
        sequence: Some(n),
        expires_at: Some(until),
        ..
    } = &r.signature
    {
        out.push_str(&format!("Sequence  {n}, expires {until}\n"));
    }
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

    /// The clock of the unit tests: 2026-09-21T14:13:20Z.
    const NOW: u64 = 1_790_000_000;

    fn fresh() -> Freshness {
        Freshness::without_floors(NOW)
    }

    /// Verify with the fixed clock and no floors.
    fn check(
        root: &Path,
        policy: &SignaturePolicy,
        mode: HashMode,
    ) -> anyhow::Result<VerifyReport> {
        verify_at(root, policy, &fresh(), mode, &mut Progress::disabled())
    }

    struct Fixture {
        dir: tempfile::TempDir,
        key: SigningKey,
    }

    impl Fixture {
        fn new() -> Self {
            Self::build(None, None)
        }

        /// A schema 2 bundle created 2026-09-28 (a week after the unit tests' clock).
        fn v2(sequence: u64, valid_days: u32) -> Self {
            Self::build(Some(sequence), Some(valid_days))
        }

        fn build(sequence: Option<u64>, valid_days: Option<u32>) -> Self {
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
                sequence,
                valid_days,
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
            check(self.root(), &policy, HashMode::Full).unwrap()
        }

        fn manifest_sha256(&self) -> String {
            sha256_hex(&fs::read(self.root().join(BUNDLE_FILE)).unwrap())
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
        let r = check(fx.root(), &SignaturePolicy::NotChecked, HashMode::SizesOnly).unwrap();
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
        let r = check(fx.root(), &SignaturePolicy::Require(other), HashMode::Full).unwrap();
        assert_eq!(r.errors[0].code, "signature-invalid");
    }

    #[test]
    fn allow_unsigned_warns_but_still_rejects_bad_signatures() {
        let fx = Fixture::new();
        fs::remove_file(fx.root().join(SIGNATURE_FILE)).unwrap();
        let policy = SignaturePolicy::AllowUnsigned(None);
        let r = check(fx.root(), &policy, HashMode::Full).unwrap();
        assert!(r.ok);
        assert_eq!(r.signature, SignatureStatus::UnsignedAllowed);
        assert_eq!(r.warnings[0].code, "unsigned");

        fs::write(fx.root().join(SIGNATURE_FILE), "00".repeat(64)).unwrap();
        let policy = SignaturePolicy::AllowUnsigned(Some(fx.key.verifying_key()));
        let r = check(fx.root(), &policy, HashMode::Full).unwrap();
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
        let r = check(dir.path(), &SignaturePolicy::NotChecked, HashMode::Full);
        assert!(r.is_err());
    }

    // ---- freshness: expiry, sequence floor, revocation, pinned keys -------------------------

    fn store_in(t: &tempfile::TempDir) -> FloorStore {
        FloorStore::new(t.path().join("state"))
    }

    fn floors(store: &FloorStore, required: bool, record: bool) -> Freshness {
        Freshness {
            now: NOW,
            revoked: Vec::new(),
            floors: FloorMode::Store {
                store: store.clone(),
                required,
                record,
            },
        }
    }

    fn run_with(fx: &Fixture, fresh: &Freshness) -> anyhow::Result<VerifyReport> {
        let policy = SignaturePolicy::Require(fx.key.verifying_key());
        verify_at(
            fx.root(),
            &policy,
            fresh,
            HashMode::Full,
            &mut Progress::disabled(),
        )
    }

    fn codes_of(r: &VerifyReport) -> Vec<&'static str> {
        r.errors.iter().map(|f| f.code).collect()
    }

    fn accepted(id: &str, sequence: u64, sha: &str) -> FloorUpdate {
        FloorUpdate {
            bundle_id: id.into(),
            floor: Floor {
                sequence,
                bundle_sha256: sha.into(),
                signer: "0123456789abcdef".into(),
            },
        }
    }

    #[test]
    fn a_bundle_expires_at_the_instant_it_says_and_not_a_second_before() {
        let fx = Fixture::v2(1, 30); // created 2026-09-28T00:00:00Z
        let expires = parse_rfc3339_utc("2026-10-28T00:00:00Z").unwrap();
        let at = |now: u64| run_with(&fx, &Freshness::without_floors(now)).unwrap();
        let r = at(expires - 1);
        assert!(r.ok, "{}", render_human(&r));
        assert_eq!(r.artifacts_ok, 4);
        for now in [expires, expires + 1, expires + 86_400 * 400] {
            let r = at(now);
            assert!(!r.ok);
            assert_eq!(codes_of(&r), ["bundle-expired"], "now = {now}");
            assert_eq!(r.artifacts_total, 0, "an expired bundle is not even hashed");
        }
        let msg = &at(expires).errors[0].message;
        assert!(
            msg.contains("2026-10-28T00:00:00Z") && msg.contains("clock"),
            "{msg}"
        );
    }

    #[test]
    fn a_sequence_below_the_floor_is_a_rollback_and_equal_needs_the_same_bytes() {
        let t = tempfile::tempdir().unwrap();
        let store = store_in(&t);
        store
            .record(&accepted("test-bundle", 2, &"ab".repeat(32)))
            .unwrap();
        let fresh = floors(&store, false, false);

        let r = run_with(&Fixture::v2(1, 365), &fresh).unwrap();
        assert_eq!(codes_of(&r), ["bundle-rollback"]);
        assert!(r.errors[0].message.contains("below 2"), "{:?}", r.errors);
        assert_eq!(
            r.artifacts_total, 0,
            "refused before any artifact is hashed"
        );

        // The floor itself, but other bytes: two different bundles must not share a sequence.
        let r = run_with(&Fixture::v2(2, 365), &fresh).unwrap();
        assert_eq!(codes_of(&r), ["bundle-sequence-conflict"]);
        assert_eq!(r.artifacts_total, 0);

        // The floor itself with the very same bytes: a re-flash is fine.
        let same = Fixture::v2(2, 365);
        store
            .record(&accepted("test-bundle", 2, &same.manifest_sha256()))
            .unwrap_err(); // refused: the stored floor has other bytes at sequence 2
        let other_store_dir = tempfile::tempdir().unwrap();
        let other = FloorStore::new(other_store_dir.path().join("state"));
        other
            .record(&accepted("test-bundle", 2, &same.manifest_sha256()))
            .unwrap();
        let r = run_with(&same, &floors(&other, false, false)).unwrap();
        assert!(r.ok, "{}", render_human(&r));

        // Above the floor: accepted.
        let r = run_with(&Fixture::v2(3, 365), &fresh).unwrap();
        assert!(r.ok, "{}", render_human(&r));
    }

    #[test]
    fn another_bundle_id_has_its_own_floor() {
        let t = tempfile::tempdir().unwrap();
        let store = store_in(&t);
        store
            .record(&accepted("some-other-bundle", 9, &"ab".repeat(32)))
            .unwrap();
        let r = run_with(&Fixture::v2(1, 365), &floors(&store, false, false)).unwrap();
        assert!(r.ok, "{}", render_human(&r));
    }

    #[test]
    fn rotating_the_signing_key_does_not_reset_the_floor() {
        let t = tempfile::tempdir().unwrap();
        let store = store_in(&t);
        store
            .record(&accepted("test-bundle", 5, &"ab".repeat(32)))
            .unwrap();
        // The floor was recorded for another signer; this bundle is signed by a key that was
        // never seen. The floor belongs to the bundle id, not to the key.
        let mut fx = Fixture::v2(4, 365);
        fx.key = SigningKey::from_bytes(&[99u8; 32]);
        fx.sign();
        let r = run_with(&fx, &floors(&store, false, false)).unwrap();
        assert_eq!(codes_of(&r), ["bundle-rollback"]);
    }

    #[test]
    fn the_floor_moves_only_after_everything_checked_out() {
        let floor_of = |store: &FloorStore| store.floor("test-bundle").unwrap();

        // Not asked to record (--dry-run, doctor): the report knows the floor, the store does not.
        let t = tempfile::tempdir().unwrap();
        let store = store_in(&t);
        let fx = Fixture::v2(3, 365);
        let r = run_with(&fx, &floors(&store, false, false)).unwrap();
        assert!(r.ok);
        let update = r.floor_update.clone().expect("a good schema 2 bundle");
        assert_eq!(update.floor.sequence, 3);
        assert_eq!(update.floor.bundle_sha256, fx.manifest_sha256());
        assert_eq!(floor_of(&store), None);
        assert!(!store.dir().exists(), "a dry run writes nothing at all");

        // Asked to record, and everything passed: the floor is raised.
        let r = run_with(&fx, &floors(&store, false, true)).unwrap();
        assert!(r.ok);
        let f = floor_of(&store).unwrap();
        assert_eq!(f.sequence, 3);
        assert_eq!(f.bundle_sha256, fx.manifest_sha256());
        assert_eq!(f.signer, fingerprint(&fx.key.verifying_key()));

        // Asked to record, but something is wrong: nothing moves.
        type Wreck = (&'static str, fn(&Fixture));
        let wrecks: [Wreck; 4] = [
            ("an artifact with the right size and wrong bytes", |fx| {
                fs::write(fx.root().join("docs/README.txt"), b"HELLO").unwrap()
            }),
            ("a missing artifact", |fx| {
                fs::remove_file(fx.root().join("models/blobs/sha256-aa")).unwrap()
            }),
            ("a missing signature", |fx| {
                fs::remove_file(fx.root().join(SIGNATURE_FILE)).unwrap()
            }),
            ("a garbage signature", |fx| {
                fs::write(fx.root().join(SIGNATURE_FILE), "00".repeat(64)).unwrap()
            }),
        ];
        for (what, wreck) in wrecks {
            let t = tempfile::tempdir().unwrap();
            let store = store_in(&t);
            let fx = Fixture::v2(7, 365);
            wreck(&fx);
            let r = run_with(&fx, &floors(&store, false, true)).unwrap();
            assert!(!r.ok, "{what}");
            assert_eq!(floor_of(&store), None, "{what}: the floor must not move");
            // The directory may exist (it was proved writable before anything was hashed), but
            // no floor was written to it.
            assert!(
                !store.floors_path().exists(),
                "{what}: no floor may be written"
            );
        }

        // Expired: refused, nothing moves.
        let t = tempfile::tempdir().unwrap();
        let store = store_in(&t);
        let r = run_with(
            &Fixture::v2(7, 1),
            &Freshness {
                now: NOW + 86_400 * 365,
                ..floors(&store, false, true)
            },
        )
        .unwrap();
        assert_eq!(codes_of(&r), ["bundle-expired"]);
        assert_eq!(floor_of(&store), None);
    }

    #[test]
    fn a_damaged_floor_file_stops_the_check_and_is_left_alone() {
        for record in [false, true] {
            let t = tempfile::tempdir().unwrap();
            let store = store_in(&t);
            fs::create_dir_all(store.dir()).unwrap();
            fs::write(store.floors_path(), "this is not floor data").unwrap();
            let e = run_with(&Fixture::v2(1, 365), &floors(&store, false, record)).unwrap_err();
            assert!(format!("{e:#}").contains("floors.json"), "{e:#}");
            assert!(format!("{e:#}").contains("untouched"), "{e:#}");
            assert_eq!(
                fs::read_to_string(store.floors_path()).unwrap(),
                "this is not floor data",
                "a damaged floor file must never be reset"
            );
        }
    }

    #[test]
    fn an_unusable_state_directory_refuses_when_required_and_warns_otherwise() {
        let t = tempfile::tempdir().unwrap();
        let blocker = t.path().join("blocker");
        fs::write(&blocker, b"x").unwrap();
        let store = FloorStore::new(blocker.join("state"));
        for record in [false, true] {
            let e = run_with(&Fixture::v2(1, 365), &floors(&store, true, record)).unwrap_err();
            assert!(format!("{e:#}").contains("state directory"), "{e:#}");
            let r = run_with(&Fixture::v2(1, 365), &floors(&store, false, record)).unwrap();
            assert!(r.ok, "{}", render_human(&r));
            assert!(
                r.warnings.iter().any(|w| w.code == "floor-not-checked"),
                "{:?}",
                r.warnings
            );
        }
        for (required, refused) in [(true, true), (false, false)] {
            let fresh = Freshness {
                now: NOW,
                revoked: Vec::new(),
                floors: FloorMode::Unavailable {
                    reason: "HOME is not set".into(),
                    required,
                },
            };
            let r = run_with(&Fixture::v2(1, 365), &fresh);
            if refused {
                assert!(format!("{:#}", r.unwrap_err()).contains("HOME is not set"));
            } else {
                let r = r.unwrap();
                assert!(r.ok && r.warnings.iter().any(|w| w.code == "floor-not-checked"));
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_state_directory_that_cannot_be_written_is_found_before_anything_is_hashed() {
        use std::os::unix::fs::PermissionsExt as _;
        let t = tempfile::tempdir().unwrap();
        let parent = t.path().join("ro");
        fs::create_dir(&parent).unwrap();
        fs::set_permissions(&parent, fs::Permissions::from_mode(0o500)).unwrap();
        // A superuser writes anywhere: nothing to prove then.
        if fs::File::create(parent.join("probe")).is_ok() {
            return;
        }
        let store = FloorStore::new(parent.join("state"));
        let fx = Fixture::v2(1, 365);
        let e = run_with(&fx, &floors(&store, true, false)).unwrap_err();
        assert!(format!("{e:#}").contains("state directory"), "{e:#}");
        let r = run_with(&fx, &floors(&store, false, true)).unwrap();
        assert!(r.ok, "an image flow carries on");
        assert!(
            r.warnings.iter().any(|w| w.code == "floor-not-recorded"),
            "{:?}",
            r.warnings
        );
        fs::set_permissions(&parent, fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn an_unsigned_manifest_never_moves_a_floor() {
        // Nothing vouches for the numbers in an unsigned manifest, so they must not be able to
        // raise (and so lock out) the floor of a real bundle line.
        let t = tempfile::tempdir().unwrap();
        let store = store_in(&t);
        let fx = Fixture::v2(999, 365);
        fs::remove_file(fx.root().join(SIGNATURE_FILE)).unwrap();
        let r = verify_at(
            fx.root(),
            &SignaturePolicy::AllowUnsigned(None),
            &floors(&store, false, true),
            HashMode::Full,
            &mut Progress::disabled(),
        )
        .unwrap();
        assert!(r.ok);
        assert_eq!(r.signature, SignatureStatus::UnsignedAllowed);
        assert!(r.floor_update.is_none());
        assert!(!store.dir().exists());

        // A signature that was present but not checked (no key) is no better.
        let fx = Fixture::v2(999, 365);
        let r = verify_at(
            fx.root(),
            &SignaturePolicy::NotChecked,
            &floors(&store, false, true),
            HashMode::Full,
            &mut Progress::disabled(),
        )
        .unwrap();
        assert_eq!(r.signature, SignatureStatus::PresentNotChecked);
        assert!(r.floor_update.is_none());
        assert!(!store.dir().exists());
    }

    #[test]
    fn a_schema_1_bundle_never_touches_the_state_directory() {
        let t = tempfile::tempdir().unwrap();
        let store = store_in(&t);
        let r = run_with(&Fixture::new(), &floors(&store, true, true)).unwrap();
        assert!(r.ok, "{}", render_human(&r));
        assert!(r.warnings.is_empty(), "{:?}", r.warnings);
        assert!(r.floor_update.is_none());
        assert!(!store.dir().exists());
    }

    #[test]
    fn the_report_carries_the_sequence_and_the_expiry() {
        let r = run_with(&Fixture::v2(3, 30), &Freshness::without_floors(NOW)).unwrap();
        let sig = serde_json::to_value(&r.signature).unwrap();
        assert_eq!(sig["status"], "valid");
        assert_eq!(sig["sequence"], 3);
        assert_eq!(sig["expires_at"], "2026-10-28T00:00:00Z");
        assert!(render_human(&r).contains("Sequence  3, expires 2026-10-28T00:00:00Z"));
        // Schema 1 has neither.
        let r = Fixture::new().run();
        let sig = serde_json::to_value(&r.signature).unwrap();
        assert!(
            sig.get("sequence").is_none() && sig.get("expires_at").is_none(),
            "{sig}"
        );
        assert!(!render_human(&r).contains("Sequence"));
    }

    #[test]
    fn a_revoked_key_is_refused_under_every_policy_that_checks_signatures() {
        let fx = Fixture::new();
        let key = fx.key.verifying_key();
        let fp = fingerprint(&key);
        for listed in [fp.clone(), fp.to_uppercase()] {
            let fresh = Freshness {
                revoked: vec![listed],
                ..fresh()
            };
            for policy in [
                SignaturePolicy::Require(key),
                SignaturePolicy::AllowUnsigned(Some(key)),
            ] {
                let r = verify_at(
                    fx.root(),
                    &policy,
                    &fresh,
                    HashMode::Full,
                    &mut Progress::disabled(),
                )
                .unwrap();
                assert_eq!(codes_of(&r), ["signature-key-revoked"]);
                assert!(matches!(r.signature, SignatureStatus::Invalid { .. }));
                assert_eq!(
                    r.bundle_id, None,
                    "a revoked signer's manifest is not trusted"
                );
                assert!(r.errors[0].message.contains(&fp));
            }
        }
        // Another key's fingerprint changes nothing.
        let fresh = Freshness {
            revoked: vec!["0123456789abcdef".into()],
            ..fresh()
        };
        let r = verify_at(
            fx.root(),
            &SignaturePolicy::Require(key),
            &fresh,
            HashMode::Full,
            &mut Progress::disabled(),
        )
        .unwrap();
        assert!(r.ok);
    }

    fn pinned_policy(keys: &[&SigningKey], revoked: &[String]) -> SignaturePolicy {
        SignaturePolicy::Pinned(TrustAnchors::new(
            keys.iter()
                .map(|k| crate::trust::PinnedKey::from_key(k.verifying_key()))
                .collect(),
            revoked.to_vec(),
        ))
    }

    fn run_pinned(fx: &Fixture, policy: &SignaturePolicy) -> VerifyReport {
        verify_at(
            fx.root(),
            policy,
            &fresh(),
            HashMode::Full,
            &mut Progress::disabled(),
        )
        .unwrap()
    }

    #[test]
    fn pinned_policy_accepts_a_pinned_key_and_no_other() {
        let fx = Fixture::v2(1, 365);
        let other = SigningKey::from_bytes(&[1u8; 32]);
        let fp = fingerprint(&fx.key.verifying_key());

        let r = run_pinned(&fx, &pinned_policy(&[&fx.key], &[]));
        assert!(r.ok, "{}", render_human(&r));
        assert!(matches!(
            &r.signature,
            SignatureStatus::Valid { key_fingerprint, .. } if *key_fingerprint == fp
        ));
        // Each pinned key is tried.
        let r = run_pinned(&fx, &pinned_policy(&[&other, &fx.key], &[]));
        assert!(r.ok, "{}", render_human(&r));

        // A key that is not pinned is not trusted, however good its signature is.
        let r = run_pinned(&fx, &pinned_policy(&[&other], &[]));
        assert_eq!(codes_of(&r), ["signature-invalid"]);
        assert_eq!(r.bundle_id, None);
        // And with nothing pinned there is nobody to vouch for it.
        let r = run_pinned(&fx, &SignaturePolicy::Pinned(TrustAnchors::default()));
        assert_eq!(codes_of(&r), ["signature-key-unknown"]);
        // A missing signature is missing, not unknown.
        fs::remove_file(fx.root().join(SIGNATURE_FILE)).unwrap();
        let r = run_pinned(&fx, &pinned_policy(&[&fx.key], &[]));
        assert_eq!(codes_of(&r), ["signature-missing"]);
    }

    #[test]
    fn a_signature_that_verifies_only_under_a_revoked_pinned_key_says_so() {
        let fx = Fixture::v2(1, 365);
        let other = SigningKey::from_bytes(&[1u8; 32]);
        let fp = fingerprint(&fx.key.verifying_key());

        let r = run_pinned(&fx, &pinned_policy(&[&fx.key], std::slice::from_ref(&fp)));
        assert_eq!(codes_of(&r), ["signature-key-revoked"]);
        assert!(r.errors[0].message.contains(&fp));
        assert_eq!(r.artifacts_total, 0);
        // Revoking a key that did not sign changes nothing.
        let r = run_pinned(
            &fx,
            &pinned_policy(&[&fx.key, &other], &[fingerprint(&other.verifying_key())]),
        );
        assert!(r.ok, "{}", render_human(&r));
    }

    #[test]
    fn a_pinned_key_requires_a_bundle_with_a_sequence_and_an_expiry() {
        let fx = Fixture::new(); // schema 1, correctly signed
        let r = run_pinned(&fx, &pinned_policy(&[&fx.key], &[]));
        assert_eq!(codes_of(&r), ["bundle-freshness-missing"]);
        assert_eq!(r.artifacts_total, 0);
        // The same bundle is fine for the development policy that is used without a pinned key.
        let r = fx.run();
        assert!(r.ok, "{}", render_human(&r));
        assert!(r.warnings.is_empty());
    }

    // ---- choosing the policy ---------------------------------------------------------------

    fn request(
        pubkey: Option<&SigningKey>,
        dev: bool,
        unsigned: bool,
        device: bool,
    ) -> PolicyRequest {
        PolicyRequest {
            pubkey: pubkey.map(SigningKey::verifying_key),
            development_key: dev,
            allow_unsigned: unsigned,
            device,
        }
    }

    #[test]
    fn without_a_pinned_key_the_command_line_decides_as_before() {
        let k = SigningKey::from_bytes(&[5u8; 32]);
        let none = TrustAnchors::default();

        let e = choose_policy(&none, request(None, false, false, false))
            .err()
            .unwrap();
        assert!(
            format!("{e}").contains("--pubkey") && format!("{e}").contains("KI-23"),
            "{e}"
        );
        for device in [false, true] {
            let c = choose_policy(&none, request(Some(&k), false, false, device)).unwrap();
            assert!(matches!(c.policy, SignaturePolicy::Require(_)));
            assert_eq!(c.notes, [NO_PINNED_KEY_NOTE]);
        }
        // --development-key has nothing to qualify yet.
        let c = choose_policy(&none, request(Some(&k), true, false, false)).unwrap();
        assert!(matches!(c.policy, SignaturePolicy::Require(_)));
        let c = choose_policy(&none, request(None, false, true, false)).unwrap();
        assert!(matches!(c.policy, SignaturePolicy::AllowUnsigned(None)));
        assert_eq!(c.notes, [UNSIGNED_WARNING]);
    }

    #[test]
    fn with_a_pinned_key_the_default_is_pinned_and_pubkey_is_for_development_only() {
        let k = SigningKey::from_bytes(&[5u8; 32]);
        let dev = SigningKey::from_bytes(&[6u8; 32]);
        let pinned = TrustAnchors::new(
            vec![crate::trust::PinnedKey::from_key(k.verifying_key())],
            vec![],
        );

        let c = choose_policy(&pinned, request(None, false, false, true)).unwrap();
        assert!(matches!(&c.policy, SignaturePolicy::Pinned(a) if a.has_pinned_keys()));
        assert!(c.notes.is_empty());

        // --pubkey needs --development-key ...
        let e = choose_policy(&pinned, request(Some(&dev), false, false, false))
            .err()
            .unwrap();
        assert!(format!("{e}").contains("--development-key"), "{e}");
        // ... which is loud ...
        let c = choose_policy(&pinned, request(Some(&dev), true, false, false)).unwrap();
        assert!(matches!(c.policy, SignaturePolicy::Require(_)));
        assert_eq!(c.notes, [DEVELOPMENT_KEY_WARNING]);
        // ... and never reaches a physical stick.
        let e = choose_policy(&pinned, request(Some(&dev), true, false, true))
            .err()
            .unwrap();
        assert!(format!("{e}").contains("--device"), "{e}");
        // --allow-unsigned is still the image-only development escape.
        let c = choose_policy(&pinned, request(None, false, true, false)).unwrap();
        assert!(matches!(c.policy, SignaturePolicy::AllowUnsigned(None)));
    }
}
