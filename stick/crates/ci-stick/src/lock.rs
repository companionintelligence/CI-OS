//! `ci-stick lock`: staging directory -> deterministic `bundle.json`.
//!
//! The staging directory mirrors what will be written to the stick. The first path
//! component decides an artifact's kind:
//!
//! | directory     | kind         |
//! |---------------|--------------|
//! | `boot/`       | `boot-image` |
//! | `installers/` | `installer`  |
//! | `oci/`        | `oci-image`  |
//! | `models/`     | `model-blob` |
//! | `docs/`       | `doc`        |
//! | `tools/`      | `tool`       |
//! | `efi/`        | `bootloader` |
//!
//! Anything else (including loose files at the root, other than `bundle.json` and its
//! signature) is an error rather than a guess. A path component equal to a platform id
//! (e.g. `installers/macos-arm64/…`) sets the artifact's `platforms`. A bootloader's
//! file name sets its `bootloader_role` and firmware platform (`x86_64-uefi`):
//!
//! | file under `efi/` | role              | chain                                      |
//! |-------------------|-------------------|--------------------------------------------|
//! | `shimx64.efi`     | `shim`            | Secure Boot (`stick/scripts/fetch-signed-boot.sh`) |
//! | `grubx64.efi`     | `grub`            | Secure Boot                                |
//! | `mmx64.efi`       | `mok-manager`     | Secure Boot                                |
//! | `BOOTX64.EFI`     | `standalone-grub` | development (`stick/scripts/build-grub-efi.sh`) |
//!
//! Other names under `efi/` are refused, and so is a staging tree holding both chains or
//! only part of the Secure Boot one ([`crate::manifest::detect_boot_chain`]). Symlinks are
//! refused: the stick's data partitions are exFAT, which cannot represent them.
//!
//! Determinism: artifacts are sorted by path, the JSON serialisation is canonical, and
//! `created_at` is taken from `--created-at`/`SOURCE_DATE_EPOCH` when given, otherwise
//! carried over from the existing `bundle.json` when nothing else changed. Re-running
//! `lock` on an unchanged tree therefore rewrites byte-identical output.
//!
//! Schema 2 (`sequence` and `expires_at`) is opt-in: `--sequence` or `--valid-days` asks for
//! it, and a `bundle.json` that is already schema 2 stays schema 2. Without either option a
//! new bundle is schema 1, exactly as before. For schema 2 the same rule holds: nothing is
//! read from the wall clock except the default `created_at` of a bundle that changed, and
//! `expires_at` is `created_at` plus `--valid-days` (default 365), so the same inputs give
//! the same bytes. A bundle that changed gets the previous `sequence` plus one unless
//! `--sequence` says otherwise; the release pipeline is the one that assigns real numbers.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context as _};

use crate::hashing::hash_file;
use crate::layout::{self, LayoutPlan};
use crate::manifest::{
    Artifact, ArtifactKind, BootChain, BootloaderRole, Bundle, ModelPack, Platform, BUNDLE_FILE,
    SCHEMA_V1, SCHEMA_V2, SIGNATURE_FILE,
};
use crate::packs::unique_models_bytes;
use crate::paths::to_manifest_path;
use crate::progress::Progress;
use crate::timefmt::{now_rfc3339, parse_rfc3339_utc, plus_days_rfc3339};

/// How long a schema 2 bundle is valid when `--valid-days` is not given.
pub const DEFAULT_VALID_DAYS: u32 = 365;

#[derive(Debug, Default, Clone)]
pub struct LockOptions {
    pub id: Option<String>,
    pub version: Option<String>,
    /// Model packs to record (already loaded from the catalog). `None` keeps the existing ones.
    pub packs: Option<Vec<ModelPack>>,
    /// Device size the bundle targets. `None` keeps the existing layout.
    pub device_bytes: Option<u64>,
    /// Fixed timestamp (e.g. from `SOURCE_DATE_EPOCH`).
    pub created_at: Option<String>,
    /// `--sequence`: write schema 2 with this release counter. Without it a changed schema 2
    /// bundle gets the previous sequence plus one (1 for a new one).
    pub sequence: Option<u64>,
    /// `--valid-days`: write schema 2 whose `expires_at` is `created_at` plus this many days
    /// (default [`DEFAULT_VALID_DAYS`]).
    pub valid_days: Option<u32>,
}

#[derive(Debug)]
pub struct LockOutcome {
    pub bundle: Bundle,
    /// `false` when the existing `bundle.json` was already byte-identical.
    pub changed: bool,
    /// A `bundle.json.sig` exists that no longer matches the new manifest.
    pub stale_signature: bool,
    pub warnings: Vec<String>,
}

/// What `lock` records about a staging path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Classified {
    pub kind: ArtifactKind,
    pub platforms: Option<Vec<Platform>>,
    pub bootloader_role: Option<BootloaderRole>,
}

/// Classify a manifest path by its first component.
pub fn classify(path: &str) -> anyhow::Result<Classified> {
    let mut comps = path.split('/');
    let top = comps.next().unwrap_or_default();
    let Some(kind) = ArtifactKind::from_staging_dir(top) else {
        let known: Vec<&str> = ArtifactKind::ALL.iter().map(|k| k.staging_dir()).collect();
        bail!(
            "{path}: cannot classify — staging files must live under one of {}/",
            known.join("/, ")
        );
    };
    if !path.contains('/') {
        bail!("{path}: is a directory name, not a file");
    }
    let mut platforms: Vec<Platform> = path.split('/').filter_map(Platform::parse).collect();
    let mut bootloader_role = None;
    if kind == ArtifactKind::Bootloader {
        let file = path.rsplit('/').next().unwrap_or_default();
        match BootloaderRole::from_file_name(file) {
            Some(role) => {
                platforms.push(role.platform());
                bootloader_role = Some(role);
            }
            None => bail!(
                "{path}: not a known bootloader file — stage either the Secure Boot chain \
                 ({}) or the development chain ({})",
                BootChain::Secure.staged_files(),
                BootChain::Development.staged_files()
            ),
        }
    }
    platforms.sort();
    platforms.dedup();
    Ok(Classified {
        kind,
        platforms: (!platforms.is_empty()).then_some(platforms),
        bootloader_role,
    })
}

fn collect_files(root: &Path, dir: &Path, out: &mut Vec<(String, PathBuf)>) -> anyhow::Result<()> {
    let mut entries: Vec<PathBuf> = fs::read_dir(dir)
        .with_context(|| format!("listing {}", dir.display()))?
        .map(|e| e.map(|e| e.path()))
        .collect::<io::Result<_>>()
        .with_context(|| format!("listing {}", dir.display()))?;
    entries.sort();
    for path in entries {
        let meta = fs::symlink_metadata(&path)
            .with_context(|| format!("inspecting {}", path.display()))?;
        let rel = path.strip_prefix(root).unwrap_or(&path);
        if meta.file_type().is_symlink() {
            bail!(
                "{} is a symlink — bundles are written to exFAT, which cannot hold symlinks; copy the file instead",
                rel.display()
            );
        }
        if meta.is_dir() {
            collect_files(root, &path, out)?;
            continue;
        }
        if !meta.is_file() {
            bail!("{} is not a regular file", rel.display());
        }
        let manifest_path = match to_manifest_path(rel) {
            Ok(p) => p,
            Err(crate::paths::PathError::Reserved(_)) if dir == root => continue,
            Err(e) => return Err(e).context("unsupported file name in staging directory"),
        };
        out.push((manifest_path, path));
    }
    Ok(())
}

/// Lock the staging directory at `root`, writing `root/bundle.json`.
pub fn lock(
    root: &Path,
    opts: &LockOptions,
    progress: &mut Progress,
) -> anyhow::Result<LockOutcome> {
    if !root.is_dir() {
        bail!(
            "staging directory {} does not exist or is not a directory",
            root.display()
        );
    }
    let manifest_path = root.join(BUNDLE_FILE);
    let existing_bytes = match fs::read(&manifest_path) {
        Ok(b) => Some(b),
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(e).with_context(|| format!("reading {}", manifest_path.display())),
    };
    let existing = match &existing_bytes {
        Some(b) => Some(Bundle::parse(b).with_context(|| {
            format!(
                "existing {} is not a valid bundle manifest; fix or remove it",
                manifest_path.display()
            )
        })?),
        None => None,
    };

    let id = opts
        .id
        .clone()
        .or_else(|| existing.as_ref().map(|b| b.id.clone()))
        .context("--id is required when creating a new bundle")?;
    let version = opts
        .version
        .clone()
        .or_else(|| existing.as_ref().map(|b| b.version.clone()))
        .context("--version is required when creating a new bundle")?;
    let layout: LayoutPlan = match opts.device_bytes {
        Some(bytes) => layout::plan(bytes)?,
        None => existing.as_ref().map(|b| b.layout.clone()).context(
            "--size is required when creating a new bundle (the device size it targets)",
        )?,
    };
    let model_packs = match &opts.packs {
        Some(p) => p.clone(),
        None => existing
            .as_ref()
            .map(|b| b.model_packs.clone())
            .unwrap_or_default(),
    };

    let mut files = Vec::new();
    collect_files(root, root, &mut files)?;
    files.sort_by(|a, b| a.0.cmp(&b.0));

    progress.set_total(files.len());
    let mut artifacts = Vec::with_capacity(files.len());
    for (i, (manifest_path, full)) in files.iter().enumerate() {
        let Classified {
            kind,
            platforms,
            bootloader_role,
        } = classify(manifest_path)?;
        let expected = fs::metadata(full).map(|m| m.len()).unwrap_or(0);
        let digest = hash_file(full, |done| {
            progress.update(i + 1, manifest_path, done, expected)
        })
        .with_context(|| format!("hashing {manifest_path}"))?;
        artifacts.push(Artifact {
            path: manifest_path.clone(),
            kind,
            sha256: digest.sha256,
            size: digest.size,
            platforms,
            bootloader_role,
        });
    }
    progress.finish();

    let schema_2 = opts.sequence.is_some()
        || opts.valid_days.is_some()
        || existing
            .as_ref()
            .is_some_and(|b| b.schema_version == SCHEMA_V2);
    let mut bundle = Bundle {
        schema_version: if schema_2 { SCHEMA_V2 } else { SCHEMA_V1 },
        id,
        version,
        created_at: String::new(),
        sequence: None,
        expires_at: None,
        artifacts,
        model_packs,
        layout,
    };
    let mut warnings = Vec::new();
    stamp(&mut bundle, opts, existing.as_ref(), &mut warnings)?;

    let problems = bundle.validate();
    if !problems.is_empty() {
        bail!(
            "refusing to write an invalid bundle.json:\n  {}",
            problems.join("\n  ")
        );
    }

    let packs_bytes = unique_models_bytes(&bundle.model_packs);
    if packs_bytes > bundle.layout.cache_bytes() {
        warnings.push(format!(
            "model packs need {} but the layout's cache partition holds {}",
            crate::size::fmt_binary(packs_bytes),
            crate::size::fmt_binary(bundle.layout.cache_bytes())
        ));
    }

    let bytes = bundle.to_canonical_json();
    let changed = existing_bytes.as_deref() != Some(bytes.as_slice());
    if changed {
        write_atomically(&manifest_path, &bytes)?;
    }
    let stale_signature = changed && root.join(SIGNATURE_FILE).exists();
    if stale_signature {
        warnings.push(format!(
            "{SIGNATURE_FILE} was made for the previous bundle.json and is now stale — re-sign"
        ));
    }
    Ok(LockOutcome {
        bundle,
        changed,
        stale_signature,
        warnings,
    })
}

/// `created_at` plus `days`, as `expires_at`.
fn expires_at_for(created_at: &str, days: u32) -> anyhow::Result<String> {
    if parse_rfc3339_utc(created_at).is_none() {
        bail!("created_at {created_at:?} is not a real RFC 3339 UTC instant, so expires_at cannot be derived from it");
    }
    plus_days_rfc3339(created_at, days)
        .with_context(|| format!("created_at {created_at} plus {days} days is past the year 9999"))
}

/// Fill in `created_at` and, for schema 2, `sequence` and `expires_at`.
///
/// If the existing `bundle.json` would come out byte for byte (everything carried over, the
/// options agreeing with it), it is kept as it is. Otherwise this is a new release: a fresh
/// `created_at`, the next sequence, and an expiry counted from that `created_at`.
fn stamp(
    bundle: &mut Bundle,
    opts: &LockOptions,
    existing: Option<&Bundle>,
    warnings: &mut Vec<String>,
) -> anyhow::Result<()> {
    let schema_2 = bundle.schema_version == SCHEMA_V2;
    let days = opts.valid_days.unwrap_or(DEFAULT_VALID_DAYS);

    if let Some(old) = existing {
        let mut same = bundle.clone();
        same.created_at = opts
            .created_at
            .clone()
            .unwrap_or_else(|| old.created_at.clone());
        if schema_2 {
            same.sequence = opts.sequence.or(old.sequence);
            same.expires_at = match &old.expires_at {
                Some(e) if opts.valid_days.is_none() && same.created_at == old.created_at => {
                    Some(e.clone())
                }
                _ => Some(expires_at_for(&same.created_at, days)?),
            };
        }
        if same == *old {
            *bundle = same;
            return Ok(());
        }
    }

    bundle.created_at = opts.created_at.clone().unwrap_or_else(now_rfc3339);
    if schema_2 {
        let previous = existing.and_then(|old| old.sequence);
        let sequence = match (opts.sequence, previous) {
            (Some(n), Some(p)) => {
                if n <= p {
                    warnings.push(format!(
                        "--sequence {n} is not greater than the previous bundle.json's {p}: a \
                         machine that already accepted sequence {p} will refuse this bundle"
                    ));
                }
                n
            }
            (Some(n), None) => n,
            (None, Some(p)) => p
                .checked_add(1)
                .context("the previous sequence cannot be increased")?,
            (None, None) => 1,
        };
        bundle.sequence = Some(sequence);
        bundle.expires_at = Some(expires_at_for(&bundle.created_at, days)?);
    }
    Ok(())
}

/// Write via a temp file + rename so a crash never leaves a half-written manifest.
fn write_atomically(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, bytes).with_context(|| format!("writing {}", tmp.display()))?;
    fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn staging() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        for (p, data) in [
            ("tools/linux-x86_64/ci-stick", &b"bin"[..]),
            ("boot/ci-os.img", b"img"),
            ("docs/a.txt", b"a"),
            ("installers/windows-x86_64/setup.exe", b"exe"),
            ("oci/ci-hub/index.json", b"{}"),
            ("efi/BOOTX64.EFI", b"MZ"),
        ] {
            let full = dir.path().join(p);
            fs::create_dir_all(full.parent().unwrap()).unwrap();
            fs::write(full, data).unwrap();
        }
        dir
    }

    fn opts() -> LockOptions {
        LockOptions {
            id: Some("t".into()),
            version: Some("1".into()),
            packs: None,
            device_bytes: Some(256_000_000_000),
            created_at: None,
            sequence: None,
            valid_days: None,
        }
    }

    #[test]
    fn lock_is_deterministic_and_sorted() {
        let dir = staging();
        let first = lock(dir.path(), &opts(), &mut Progress::disabled()).unwrap();
        assert!(first.changed);
        let bytes1 = fs::read(dir.path().join(BUNDLE_FILE)).unwrap();
        // Second run without --id/--version: carried over, and output is byte-identical,
        // including created_at.
        let again = lock(
            dir.path(),
            &LockOptions::default(),
            &mut Progress::disabled(),
        )
        .unwrap();
        assert!(!again.changed);
        assert_eq!(fs::read(dir.path().join(BUNDLE_FILE)).unwrap(), bytes1);

        let paths: Vec<&str> = first
            .bundle
            .artifacts
            .iter()
            .map(|a| a.path.as_str())
            .collect();
        let mut sorted = paths.clone();
        sorted.sort_unstable();
        assert_eq!(paths, sorted);
        assert!(!paths.contains(&BUNDLE_FILE));

        // Two independent staging trees with the same content and timestamp are identical.
        let other = staging();
        let fixed = LockOptions {
            created_at: Some("2026-01-01T00:00:00Z".into()),
            ..opts()
        };
        lock(dir.path(), &fixed, &mut Progress::disabled()).unwrap();
        lock(other.path(), &fixed, &mut Progress::disabled()).unwrap();
        assert_eq!(
            fs::read(dir.path().join(BUNDLE_FILE)).unwrap(),
            fs::read(other.path().join(BUNDLE_FILE)).unwrap()
        );
    }

    #[test]
    fn classifies_kinds_and_platforms() {
        let dir = staging();
        let out = lock(dir.path(), &opts(), &mut Progress::disabled()).unwrap();
        let find = |p: &str| {
            out.bundle
                .artifacts
                .iter()
                .find(|a| a.path == p)
                .unwrap()
                .clone()
        };
        assert_eq!(find("boot/ci-os.img").kind, ArtifactKind::BootImage);
        assert_eq!(find("boot/ci-os.img").platforms, None);
        let exe = find("installers/windows-x86_64/setup.exe");
        assert_eq!(exe.kind, ArtifactKind::Installer);
        assert_eq!(exe.platforms, Some(vec![Platform::WindowsX86_64]));
        assert_eq!(find("oci/ci-hub/index.json").kind, ArtifactKind::OciImage);
        let efi = find("efi/BOOTX64.EFI");
        assert_eq!(efi.kind, ArtifactKind::Bootloader);
        assert_eq!(efi.platforms, Some(vec![Platform::X86_64Uefi]));
        assert!(
            out.bundle.validate().is_empty(),
            "{:?}",
            out.bundle.validate()
        );
    }

    #[test]
    fn classifies_bootloader_roles_and_refuses_unknown_names() {
        for (path, role) in [
            ("efi/BOOTX64.EFI", BootloaderRole::StandaloneGrub),
            ("efi/shimx64.efi", BootloaderRole::Shim),
            ("efi/grubx64.efi", BootloaderRole::Grub),
            ("efi/mmx64.efi", BootloaderRole::MokManager),
        ] {
            let c = classify(path).unwrap();
            assert_eq!(c.kind, ArtifactKind::Bootloader);
            assert_eq!(c.bootloader_role, Some(role), "{path}");
            assert_eq!(c.platforms, Some(vec![Platform::X86_64Uefi]));
        }
        for bad in ["efi/fbx64.efi", "efi/bootx64.efi", "efi/grubx64.efi.signed"] {
            let e = classify(bad).unwrap_err();
            assert!(format!("{e}").contains("not a known bootloader"), "{e}");
        }
        assert!(classify("efi/linux-x86_64/BOOTX64.EFI").is_ok());
        assert_eq!(classify("docs/a.txt").unwrap().bootloader_role, None);
    }

    fn with_efi(files: &[&str]) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("efi")).unwrap();
        fs::create_dir_all(dir.path().join("boot")).unwrap();
        fs::write(dir.path().join("boot/x.iso"), b"iso").unwrap();
        for f in files {
            fs::write(dir.path().join("efi").join(f), b"MZ").unwrap();
        }
        dir
    }

    #[test]
    fn lock_detects_the_boot_chain() {
        let secure = with_efi(&["shimx64.efi", "grubx64.efi", "mmx64.efi"]);
        let out = lock(secure.path(), &opts(), &mut Progress::disabled()).unwrap();
        assert_eq!(out.bundle.boot_chain(), Ok(Some(BootChain::Secure)));

        let dev = with_efi(&["BOOTX64.EFI"]);
        let out = lock(dev.path(), &opts(), &mut Progress::disabled()).unwrap();
        assert_eq!(out.bundle.boot_chain(), Ok(Some(BootChain::Development)));

        let both = with_efi(&["shimx64.efi", "grubx64.efi", "mmx64.efi", "BOOTX64.EFI"]);
        let e = lock(both.path(), &opts(), &mut Progress::disabled()).unwrap_err();
        assert!(
            format!("{e:#}").contains("both the Secure Boot chain"),
            "{e:#}"
        );
        assert!(!both.path().join(BUNDLE_FILE).exists());

        let partial = with_efi(&["shimx64.efi", "grubx64.efi"]);
        let e = lock(partial.path(), &opts(), &mut Progress::disabled()).unwrap_err();
        assert!(format!("{e:#}").contains("missing efi/mmx64.efi"), "{e:#}");
    }

    #[test]
    fn content_change_updates_manifest_and_flags_stale_signature() {
        let dir = staging();
        lock(dir.path(), &opts(), &mut Progress::disabled()).unwrap();
        fs::write(dir.path().join(SIGNATURE_FILE), "00").unwrap();
        fs::write(dir.path().join("docs/a.txt"), b"changed").unwrap();
        let out = lock(
            dir.path(),
            &LockOptions::default(),
            &mut Progress::disabled(),
        )
        .unwrap();
        assert!(out.changed && out.stale_signature);
    }

    #[test]
    fn rejects_unclassifiable_and_missing_options() {
        let dir = staging();
        fs::write(dir.path().join("loose.txt"), b"x").unwrap();
        let err = lock(dir.path(), &opts(), &mut Progress::disabled()).unwrap_err();
        assert!(format!("{err:#}").contains("cannot classify"), "{err:#}");

        let dir = staging();
        let err = lock(
            dir.path(),
            &LockOptions::default(),
            &mut Progress::disabled(),
        )
        .unwrap_err();
        assert!(format!("{err:#}").contains("--id"), "{err:#}");
    }

    fn at(created: &str) -> Option<String> {
        Some(created.to_string())
    }

    #[test]
    fn schema_2_is_opt_in() {
        let dir = staging();
        let out = lock(dir.path(), &opts(), &mut Progress::disabled()).unwrap();
        assert_eq!(out.bundle.schema_version, SCHEMA_V1);
        assert_eq!((out.bundle.sequence, out.bundle.expires_at), (None, None));
        let text = fs::read_to_string(dir.path().join(BUNDLE_FILE)).unwrap();
        assert!(
            !text.contains("sequence") && !text.contains("expires_at"),
            "{text}"
        );

        for ask in [
            LockOptions {
                sequence: Some(4),
                ..opts()
            },
            LockOptions {
                valid_days: Some(30),
                ..opts()
            },
        ] {
            let other = staging();
            let out = lock(other.path(), &ask, &mut Progress::disabled()).unwrap();
            assert_eq!(out.bundle.schema_version, SCHEMA_V2);
            assert!(
                out.bundle.validate().is_empty(),
                "{:?}",
                out.bundle.validate()
            );
        }
    }

    #[test]
    fn expiry_counts_from_created_at_and_never_from_the_clock() {
        // The wall clock is years away from 2020, so a derivation that read it could not give
        // these exact strings. 2020 is a leap year.
        let dir = staging();
        let out = lock(
            dir.path(),
            &LockOptions {
                sequence: Some(2),
                valid_days: Some(30),
                created_at: at("2020-01-01T00:00:00Z"),
                ..opts()
            },
            &mut Progress::disabled(),
        )
        .unwrap();
        assert_eq!(out.bundle.created_at, "2020-01-01T00:00:00Z");
        assert_eq!(out.bundle.sequence, Some(2));
        assert_eq!(
            out.bundle.expires_at.as_deref(),
            Some("2020-01-31T00:00:00Z")
        );

        let default_window = staging();
        let out = lock(
            default_window.path(),
            &LockOptions {
                sequence: Some(1),
                created_at: at("2020-01-01T00:00:00Z"),
                ..opts()
            },
            &mut Progress::disabled(),
        )
        .unwrap();
        assert_eq!(DEFAULT_VALID_DAYS, 365);
        assert_eq!(
            out.bundle.expires_at.as_deref(),
            Some("2020-12-31T00:00:00Z")
        );
    }

    #[test]
    fn schema_2_output_is_reproducible() {
        let a = staging();
        let b = staging();
        let fixed = LockOptions {
            sequence: Some(7),
            valid_days: Some(90),
            created_at: at("2026-01-01T00:00:00Z"),
            ..opts()
        };
        lock(a.path(), &fixed, &mut Progress::disabled()).unwrap();
        lock(b.path(), &fixed, &mut Progress::disabled()).unwrap();
        let bytes = fs::read(a.path().join(BUNDLE_FILE)).unwrap();
        assert_eq!(bytes, fs::read(b.path().join(BUNDLE_FILE)).unwrap());

        // The same inputs again, and no inputs at all, rewrite nothing.
        for again in [fixed.clone(), LockOptions::default()] {
            let out = lock(a.path(), &again, &mut Progress::disabled()).unwrap();
            assert!(!out.changed, "{again:?}");
            assert_eq!(fs::read(a.path().join(BUNDLE_FILE)).unwrap(), bytes);
            assert_eq!(out.bundle.sequence, Some(7));
        }
    }

    #[test]
    fn a_changed_schema_2_bundle_gets_the_next_sequence() {
        let dir = staging();
        lock(
            dir.path(),
            &LockOptions {
                sequence: Some(1),
                created_at: at("2026-01-01T00:00:00Z"),
                ..opts()
            },
            &mut Progress::disabled(),
        )
        .unwrap();
        fs::write(dir.path().join("docs/a.txt"), b"changed").unwrap();
        let out = lock(
            dir.path(),
            &LockOptions {
                created_at: at("2026-02-01T00:00:00Z"),
                ..LockOptions::default()
            },
            &mut Progress::disabled(),
        )
        .unwrap();
        assert!(out.changed);
        assert_eq!(out.bundle.schema_version, SCHEMA_V2);
        assert_eq!(out.bundle.sequence, Some(2));
        assert_eq!(out.bundle.created_at, "2026-02-01T00:00:00Z");
        assert_eq!(
            out.bundle.expires_at.as_deref(),
            Some("2027-02-01T00:00:00Z")
        );
        assert!(out.warnings.is_empty(), "{:?}", out.warnings);
    }

    #[test]
    fn a_sequence_that_does_not_increase_is_written_with_a_warning() {
        let dir = staging();
        let first = LockOptions {
            sequence: Some(2),
            created_at: at("2026-01-01T00:00:00Z"),
            ..opts()
        };
        lock(dir.path(), &first, &mut Progress::disabled()).unwrap();
        let out = lock(
            dir.path(),
            &LockOptions {
                sequence: Some(1),
                created_at: at("2026-01-02T00:00:00Z"),
                ..LockOptions::default()
            },
            &mut Progress::disabled(),
        )
        .unwrap();
        assert_eq!(out.bundle.sequence, Some(1));
        assert!(
            out.warnings.iter().any(|w| w.contains("not greater than")),
            "{:?}",
            out.warnings
        );

        // The same sequence again, for a changed bundle, is no better: a machine that accepted
        // the first one refuses the second as a conflict, so the warning must not wait for a
        // strictly lower number.
        let out = lock(
            dir.path(),
            &LockOptions {
                sequence: Some(1),
                created_at: at("2026-01-03T00:00:00Z"),
                ..LockOptions::default()
            },
            &mut Progress::disabled(),
        )
        .unwrap();
        assert_eq!(out.bundle.sequence, Some(1));
        assert!(
            out.warnings.iter().any(|w| w.contains("not greater than")),
            "{:?}",
            out.warnings
        );

        // A higher one is quiet.
        let out = lock(
            dir.path(),
            &LockOptions {
                sequence: Some(2),
                created_at: at("2026-01-04T00:00:00Z"),
                ..LockOptions::default()
            },
            &mut Progress::disabled(),
        )
        .unwrap();
        assert_eq!(out.bundle.sequence, Some(2));
        assert!(out.warnings.is_empty(), "{:?}", out.warnings);
    }

    #[test]
    fn schema_1_becomes_schema_2_only_when_asked() {
        let dir = staging();
        lock(dir.path(), &opts(), &mut Progress::disabled()).unwrap();
        let out = lock(
            dir.path(),
            &LockOptions {
                sequence: Some(1),
                created_at: at("2026-03-01T00:00:00Z"),
                ..LockOptions::default()
            },
            &mut Progress::disabled(),
        )
        .unwrap();
        assert!(out.changed);
        assert_eq!(out.bundle.schema_version, SCHEMA_V2);
        assert_eq!(out.bundle.sequence, Some(1));
    }

    #[test]
    fn an_empty_or_out_of_range_window_is_refused() {
        for (created, days) in [
            ("2026-01-01T00:00:00Z", 0),
            ("9999-12-31T00:00:00Z", 1),
            ("2026-13-01T00:00:00Z", 30),
        ] {
            let dir = staging();
            let err = lock(
                dir.path(),
                &LockOptions {
                    sequence: Some(1),
                    valid_days: Some(days),
                    created_at: at(created),
                    ..opts()
                },
                &mut Progress::disabled(),
            )
            .unwrap_err();
            assert!(
                !dir.path().join(BUNDLE_FILE).exists(),
                "{created} + {days}: {err:#}"
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlinks() {
        let dir = staging();
        std::os::unix::fs::symlink("/etc/hostname", dir.path().join("docs/link")).unwrap();
        let err = lock(dir.path(), &opts(), &mut Progress::disabled()).unwrap_err();
        assert!(format!("{err:#}").contains("symlink"));
    }
}
