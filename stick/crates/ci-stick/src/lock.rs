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

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context as _};

use crate::hashing::hash_file;
use crate::layout::{self, LayoutPlan};
use crate::manifest::{
    Artifact, ArtifactKind, BootChain, BootloaderRole, Bundle, ModelPack, Platform, BUNDLE_FILE,
    SCHEMA_VERSION, SIGNATURE_FILE,
};
use crate::packs::unique_models_bytes;
use crate::paths::to_manifest_path;
use crate::progress::Progress;
use crate::timefmt::now_rfc3339;

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

    let mut bundle = Bundle {
        schema_version: SCHEMA_VERSION,
        id,
        version,
        created_at: String::new(),
        artifacts,
        model_packs,
        layout,
    };
    bundle.created_at = match (&opts.created_at, &existing) {
        (Some(ts), _) => ts.clone(),
        (None, Some(old))
            if Bundle {
                created_at: old.created_at.clone(),
                ..bundle.clone()
            } == *old =>
        {
            old.created_at.clone()
        }
        _ => now_rfc3339(),
    };

    let problems = bundle.validate();
    if !problems.is_empty() {
        bail!(
            "refusing to write an invalid bundle.json:\n  {}",
            problems.join("\n  ")
        );
    }

    let mut warnings = Vec::new();
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

    #[cfg(unix)]
    #[test]
    fn rejects_symlinks() {
        let dir = staging();
        std::os::unix::fs::symlink("/etc/hostname", dir.path().join("docs/link")).unwrap();
        let err = lock(dir.path(), &opts(), &mut Progress::disabled()).unwrap_err();
        assert!(format!("{err:#}").contains("symlink"));
    }
}
