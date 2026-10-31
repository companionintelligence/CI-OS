//! `ci-stick flash`: write a verified bundle onto a stick (or a stick image) using the
//! layout plan.
//!
//! Order of operations, each step refusing before anything is written if it fails:
//!
//! 1. **Verify** the bundle with [`crate::verify`] (signature required unless
//!    `--allow-unsigned`, which is only accepted for `--image` targets; a schema 2 bundle must
//!    also be unexpired and not below the sequence floor).
//! 2. **Plan**: resolve the target, compute the layout for its size, pick the boot image
//!    and the boot chain from the manifest ([`BootChain`]: shim → Canonical GRUB, or the
//!    unsigned development GRUB), apply the bootloader policy (an unsigned chain on a
//!    `--device` needs `--allow-unsigned-bootloader`), check everything fits. `--dry-run`
//!    stops here.
//! 3. **Device checks** ([`crate::target`]): removable/USB candidate, nothing mounted, no
//!    swap, no holders, `--confirm` equal to the node shown (and `--expect-serial` when
//!    the device reports one).
//! 4. **Build** every filesystem in sparse temporary files, without root or loop devices:
//!    `mkfs.vfat` + `mmd`/`mcopy` for the ESP, `mkfs.exfat` for CI-SHARED/CI-CACHE,
//!    `mkfs.ext4 -L writable` for CI-PERSIST.
//! 5. **Write**: open the target (`O_EXCL` for devices), re-check the device identity,
//!    zero the first and last MiB, `sgdisk --zap-all`, then `sgdisk` with the exact plan;
//!    copy each filesystem's data extents to its partition offset; stream the boot image
//!    raw into CI-BOOT-A (hashing as it goes); leave CI-BOOT-B with a zeroed header.
//! 6. **Read back** after `fsync`: the GPT must parse, pass both CRCs and match the plan;
//!    each slot's bytes must hash to the manifest digest; each filesystem's data extents
//!    must compare equal.
//! 7. **Record the sequence floor** of the bundle that was just written. Only a completed,
//!    read-back write moves it: a refused bundle, `--dry-run` and a failed write leave it
//!    where it was.

use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use anyhow::{bail, ensure, Context as _};
use serde::Serialize;
use sha2::{Digest as _, Sha256};

use crate::bootcfg::{self, BootPartitions};
use crate::gpt;
use crate::grubenv::{self, GrubEnv, Slot};
use crate::hashing::hash_file;
use crate::layout::{self, Filesystem, LayoutPlan, Partition, PartitionRole};
use crate::manifest::{Artifact, ArtifactKind, BootChain, BootloaderRole, Bundle, BUNDLE_FILE};
use crate::progress::Progress;
use crate::size::{fmt_binary, fmt_decimal, MIB};
use crate::sparse;
use crate::state::FloorUpdate;
use crate::target::{self, DeviceTarget, Identity};
use crate::tools;
use crate::verify::{self, FloorMode, Freshness, SignaturePolicy, SignatureStatus, VerifyReport};

/// Filesystem label casper looks for to find its persistence partition.
pub const PERSIST_FS_LABEL: &str = "writable";

/// Largest bootloader we will load into memory.
const MAX_BOOTLOADER_BYTES: u64 = 64 * MIB;

/// Where to write.
#[derive(Debug, Clone)]
pub enum TargetSpec {
    /// Create or overwrite a sparse image file of `size_bytes`.
    Image { path: PathBuf, size_bytes: u64 },
    /// A whole block device (Linux only).
    Device { path: PathBuf },
}

impl TargetSpec {
    pub fn is_device(&self) -> bool {
        matches!(self, Self::Device { .. })
    }

    /// What a verification for this target is for: a physical stick makes the sequence floor
    /// mandatory ([`verify::floor_rules`]).
    pub fn purpose(&self) -> verify::Purpose {
        if self.is_device() {
            verify::Purpose::FlashDevice
        } else {
            verify::Purpose::FlashImage
        }
    }
}

pub struct FlashRequest {
    pub bundle_root: PathBuf,
    pub policy: SignaturePolicy,
    pub target: TargetSpec,
    /// Manifest path of the boot image when the bundle has more than one.
    pub boot_image: Option<String>,
    /// Test/development only (`--image` targets): write this ISO into slot B.
    pub slot_b_from: Option<PathBuf>,
    /// Stored in grubenv as `extra_cmdline`.
    pub extra_cmdline: Option<String>,
    pub dry_run: bool,
    pub confirm: Option<String>,
    pub expect_serial: Option<String>,
    /// Where the sparse filesystem images are built (default: the system temp dir).
    pub work_dir: Option<PathBuf>,
    /// `--allow-unsigned-bootloader`: accept the development (unsigned) boot chain for a
    /// `--device` write. Image targets never need it.
    pub allow_unsigned_bootloader: bool,
    /// The clock, the revoked keys and the sequence floors the verification works with. A
    /// device write needs the floors to be required.
    pub freshness: Freshness,
}

/// What the bootloader policy decided for a (chain, target) pair.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BootloaderPolicy {
    /// Secure chain: nothing to say.
    Signed,
    /// Development chain on an image file (tests, development): allowed, noted in the plan.
    UnsignedImage,
    /// Development chain on a real stick, explicitly allowed: loud warning.
    UnsignedDeviceAllowed,
}

/// The bootloader policy. Pure, so it is unit-tested without a device.
///
/// A physical stick normally gets the Secure Boot chain. Writing the unsigned development
/// GRUB to one produces a stick that boots only with Secure Boot disabled, so it takes an
/// explicit `--allow-unsigned-bootloader`; image files (QEMU tests) are always allowed.
pub fn bootloader_policy(
    chain: BootChain,
    is_device: bool,
    allow_unsigned_bootloader: bool,
) -> anyhow::Result<BootloaderPolicy> {
    Ok(match (chain, is_device) {
        (BootChain::Secure, _) => BootloaderPolicy::Signed,
        (BootChain::Development, false) => BootloaderPolicy::UnsignedImage,
        (BootChain::Development, true) if allow_unsigned_bootloader => {
            BootloaderPolicy::UnsignedDeviceAllowed
        }
        (BootChain::Development, true) => bail!(
            "this bundle carries the UNSIGNED development bootloader ({}), which boots only \
             with Secure Boot disabled. Stage the Secure Boot chain ({}; see \
             stick/scripts/fetch-signed-boot.sh) or, for a development stick, pass \
             --allow-unsigned-bootloader",
            BootChain::Development.staged_files(),
            BootChain::Secure.staged_files()
        ),
    })
}

/// Banner printed (plan and stderr) when an unsigned bootloader goes onto a real stick.
pub const UNSIGNED_DEVICE_WARNING: &str = "\
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!  WARNING: --allow-unsigned-bootloader — this stick gets the UNSIGNED         !!
!!  development GRUB. It will NOT boot with Secure Boot enabled, and nothing    !!
!!  verifies the boot chain. Use it for development sticks only.                !!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
";

/// Printed in the plan when a schema 1 bundle (no sequence, no expiry) goes onto a real stick
/// because this build has no pinned release key to refuse it.
pub const UNPROTECTED_DEVICE_WARNING: &str = "WARNING: no release key is pinned in this build and \
    this bundle has no sequence or expiry: nothing protects against an old bundle.";

/// The plan note for a schema 1 bundle (no sequence, no expiry) going onto a real stick. A
/// build that pins a key refuses such a bundle in `verify`, so this appears only while no key
/// is pinned; an image file is a development flow and gets no note.
fn unprotected_note(
    device: bool,
    policy: &SignaturePolicy,
    signature: &SignatureStatus,
) -> Option<&'static str> {
    (device
        && !matches!(policy, SignaturePolicy::Pinned(_))
        && matches!(signature, SignatureStatus::Valid { sequence: None, .. }))
    .then_some(UNPROTECTED_DEVICE_WARNING)
}

/// Request-level rules that don't need to look at anything.
pub fn validate_request(r: &FlashRequest) -> anyhow::Result<()> {
    if r.target.is_device() {
        if matches!(r.policy, SignaturePolicy::AllowUnsigned(_)) {
            bail!(
                "--allow-unsigned is refused with --device: a physical stick is only ever \
                 written from a signed bundle (it is accepted with --image for development)"
            );
        }
        if matches!(r.policy, SignaturePolicy::NotChecked) {
            bail!("a device write requires a verified signature (--pubkey)");
        }
        if r.slot_b_from.is_some() {
            bail!(
                "--slot-b-from writes unsigned content into a boot slot and is only accepted \
                 with --image (tests and development)"
            );
        }
        if !r.freshness.floors_required() {
            bail!("internal: a device write must require the sequence floor (see Freshness)");
        }
    } else if r.confirm.is_some() || r.expect_serial.is_some() {
        bail!("--confirm/--expect-serial apply to --device targets only");
    }
    if let Some(x) = &r.extra_cmdline {
        grubenv::validate_extra_cmdline(x)?;
    }
    Ok(())
}

/// A file going onto the stick.
#[derive(Debug, Clone, Serialize)]
pub struct SourceFile {
    /// Manifest path (bundle artifacts) or local path (`--slot-b-from`).
    pub path: String,
    pub size: u64,
    pub sha256: String,
    #[serde(skip)]
    pub local: PathBuf,
}

/// A bootloader binary from the bundle and its ESP destination.
#[derive(Debug, Clone, Serialize)]
pub struct EspBinary {
    pub role: BootloaderRole,
    pub esp_path: String,
    pub source: SourceFile,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "kebab-case", tag = "kind")]
pub enum PlannedTarget {
    Image {
        path: String,
        size_bytes: u64,
        overwrites_existing: bool,
    },
    Device {
        given: String,
        identity: Identity,
        transport: Option<String>,
        removable: bool,
        logical_sector: u64,
    },
}

#[derive(Debug, Clone, Serialize)]
pub struct PartitionContents {
    pub index: u32,
    pub label: String,
    pub filesystem: String,
    pub fs_label: Option<String>,
    pub start_bytes: u64,
    pub size_bytes: u64,
    pub contents: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct FlashPlan {
    pub bundle_id: String,
    pub bundle_version: String,
    pub signature: SignatureStatus,
    pub target: PlannedTarget,
    pub layout: LayoutPlan,
    pub partitions: Vec<PartitionContents>,
    pub boot_image: SourceFile,
    pub boot_chain: BootChain,
    /// [`BootChain::secure_boot_line`], for humans and JSON consumers alike.
    pub secure_boot: String,
    /// `--allow-unsigned-bootloader` on a real stick: the plan carries a loud warning.
    pub unsigned_bootloader_on_device: bool,
    /// Bootloader binaries and where each goes on the ESP.
    pub bootloaders: Vec<EspBinary>,
    /// ESP paths that receive the rendered grub.cfg.
    pub grub_cfg: Vec<String>,
    pub slot_b: Option<SourceFile>,
    pub grubenv: Vec<(String, String)>,
    pub notes: Vec<String>,
    #[serde(skip)]
    device: Option<DeviceTarget>,
    /// The floor to record once the write completed (schema 2 bundles only).
    #[serde(skip)]
    floor_update: Option<FloorUpdate>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct WriteReport {
    pub bytes_written: u64,
    pub checks: Vec<String>,
}

pub enum FlashOutcome {
    /// The bundle failed verification; nothing was planned or written.
    VerifyFailed(Box<VerifyReport>),
    DryRun(Box<FlashPlan>),
    Written(Box<FlashPlan>, WriteReport),
}

fn pick_one<'a>(
    bundle: &'a Bundle,
    what: &str,
    filter: impl Fn(&Artifact) -> bool,
    chosen: Option<&str>,
) -> anyhow::Result<&'a Artifact> {
    let found: Vec<&Artifact> = bundle.artifacts.iter().filter(|a| filter(a)).collect();
    if let Some(c) = chosen {
        return found
            .into_iter()
            .find(|a| a.path == c)
            .with_context(|| format!("the bundle has no {what} at {c:?}"));
    }
    match found.as_slice() {
        [one] => Ok(one),
        [] => bail!("the bundle has no {what}"),
        many => bail!(
            "the bundle has {} {what}s ({}); choose one with --boot-image <path>",
            many.len(),
            many.iter()
                .map(|a| a.path.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

fn source(root: &Path, a: &Artifact) -> SourceFile {
    SourceFile {
        path: a.path.clone(),
        size: a.size,
        sha256: a.sha256.clone(),
        local: crate::paths::join_manifest_path(root, &a.path),
    }
}

fn partition(plan: &LayoutPlan, role: PartitionRole) -> anyhow::Result<&Partition> {
    plan.partition(role)
        .with_context(|| format!("layout has no {role:?} partition"))
}

/// Verify the bundle and work out everything `flash` would do. Writes nothing.
pub fn plan(
    req: &FlashRequest,
    progress: &mut Progress,
) -> anyhow::Result<Result<FlashPlan, VerifyReport>> {
    validate_request(req)?;
    let report = verify::verify_at(
        &req.bundle_root,
        &req.policy,
        &req.freshness,
        verify::HashMode::Full,
        progress,
    )?;
    if !report.ok {
        return Ok(Err(report));
    }
    let root = fs::canonicalize(&req.bundle_root)?;
    let bundle = Bundle::load(&root.join(BUNDLE_FILE))?;
    ensure!(
        bundle.layout.policy == layout::LAYOUT_POLICY,
        "bundle was built for layout policy {}, this ci-stick writes {}",
        bundle.layout.policy,
        layout::LAYOUT_POLICY
    );

    let boot = pick_one(
        &bundle,
        "boot image",
        |a| a.kind == ArtifactKind::BootImage,
        req.boot_image.as_deref(),
    )?;
    let chain = bundle
        .boot_chain()
        .map_err(anyhow::Error::msg)?
        .with_context(|| {
            format!(
                "the bundle has no bootloader: stage the Secure Boot chain ({}, from \
                 stick/scripts/fetch-signed-boot.sh) or the development chain ({}, from \
                 stick/scripts/build-grub-efi.sh)",
                BootChain::Secure.staged_files(),
                BootChain::Development.staged_files()
            )
        })?;
    let mut bootloaders = Vec::new();
    for (role, esp_path) in bootcfg::esp_binaries(chain) {
        let a = bundle
            .bootloader(*role)
            .with_context(|| format!("internal: {chain:?} chain without its {role}"))?;
        ensure!(
            a.size <= MAX_BOOTLOADER_BYTES,
            "bootloader {} is {} — larger than any plausible EFI binary",
            a.path,
            fmt_binary(a.size)
        );
        bootloaders.push(EspBinary {
            role: *role,
            esp_path: (*esp_path).to_string(),
            source: source(&root, a),
        });
    }

    let (planned_target, size_bytes, device) = match &req.target {
        TargetSpec::Image { path, size_bytes } => {
            target::check_image_path(path)?;
            (
                PlannedTarget::Image {
                    path: path.display().to_string(),
                    size_bytes: *size_bytes,
                    overwrites_existing: path.exists(),
                },
                *size_bytes,
                None,
            )
        }
        TargetSpec::Device { path } => {
            let dev = target::prepare_device(path)?;
            let size = dev.disk.size_bytes;
            (
                PlannedTarget::Device {
                    given: dev.resolved.describe(),
                    identity: dev.disk.identity(),
                    transport: dev.transport.clone(),
                    removable: dev.disk.removable,
                    logical_sector: dev.disk.logical_sector,
                },
                size,
                Some(dev),
            )
        }
    };
    // After the target checks, so a refused device is reported as such first.
    let policy = bootloader_policy(chain, req.target.is_device(), req.allow_unsigned_bootloader)?;
    let layout = layout::plan(size_bytes)?;
    let slot_a = partition(&layout, PartitionRole::BootA)?;
    let slot_b = partition(&layout, PartitionRole::BootB)?;
    ensure!(
        boot.size <= slot_a.size_bytes,
        "boot image {} ({}) does not fit {} ({})",
        boot.path,
        fmt_binary(boot.size),
        slot_a.label,
        fmt_binary(slot_a.size_bytes)
    );
    let slot_b_src = match &req.slot_b_from {
        Some(p) => {
            let meta = fs::symlink_metadata(p).with_context(|| format!("{}", p.display()))?;
            ensure!(
                meta.is_file(),
                "--slot-b-from {} is not a regular file",
                p.display()
            );
            ensure!(
                meta.len() <= slot_b.size_bytes,
                "--slot-b-from {} ({}) does not fit {} ({})",
                p.display(),
                fmt_binary(meta.len()),
                slot_b.label,
                fmt_binary(slot_b.size_bytes)
            );
            let d = hash_file(p, |_| {}).with_context(|| format!("hashing {}", p.display()))?;
            Some(SourceFile {
                path: p.display().to_string(),
                size: d.size,
                sha256: d.sha256,
                local: p.clone(),
            })
        }
        None => None,
    };

    let mut env = GrubEnv::new();
    env.set(grubenv::VAR_ACTIVE_SLOT, Slot::A.as_str())?;
    if let Some(x) = &req.extra_cmdline {
        env.set(grubenv::VAR_EXTRA_CMDLINE, x)?;
    }
    let parts = BootPartitions::from_layout(&layout)?;
    let boot_src = source(&root, boot);
    let grub_cfg: Vec<String> = bootcfg::grub_cfg_paths(chain)
        .iter()
        .map(|s| s.to_string())
        .collect();
    let esp_contents = esp_contents(&bootloaders, &grub_cfg, parts, &env);

    let partitions = layout
        .partitions
        .iter()
        .map(|p| {
            let (fs_label, contents) = match p.role {
                PartitionRole::Esp => (Some(p.label.clone()), esp_contents.clone()),
                PartitionRole::Shared | PartitionRole::Cache => (
                    Some(p.label.clone()),
                    vec![
                        "formatted empty (launchers, docs and the model cache arrive in slice 4)"
                            .into(),
                    ],
                ),
                PartitionRole::BootA => (
                    None,
                    vec![format!(
                        "raw image <- {} ({}, sha256 {})",
                        boot_src.path,
                        fmt_binary(boot_src.size),
                        short(&boot_src.sha256)
                    )],
                ),
                PartitionRole::BootB => (
                    None,
                    vec![match &slot_b_src {
                        Some(s) => format!(
                            "raw image <- {} ({}, sha256 {}) [--slot-b-from, development only]",
                            s.path,
                            fmt_binary(s.size),
                            short(&s.sha256)
                        ),
                        None => "empty (first MiB zeroed) until an update writes it".into(),
                    }],
                ),
                PartitionRole::Persist => (
                    Some(PERSIST_FS_LABEL.into()),
                    vec![format!(
                        "empty ext4, filesystem label \"{PERSIST_FS_LABEL}\" (casper persistence)"
                    )],
                ),
            };
            PartitionContents {
                index: p.index,
                label: p.label.clone(),
                filesystem: p.filesystem.as_str().into(),
                fs_label,
                start_bytes: p.start_bytes,
                size_bytes: p.size_bytes,
                contents,
            }
        })
        .collect();

    let mut notes = Vec::new();
    match policy {
        BootloaderPolicy::Signed if req.allow_unsigned_bootloader => notes.push(
            "--allow-unsigned-bootloader has no effect: the bundle carries the signed chain."
                .to_string(),
        ),
        BootloaderPolicy::Signed => {}
        BootloaderPolicy::UnsignedImage => notes.push(
            "development boot chain (unsigned standalone GRUB) on an image file: fine for \
             tests; a --device write would need --allow-unsigned-bootloader."
                .to_string(),
        ),
        BootloaderPolicy::UnsignedDeviceAllowed => notes.push(
            "UNSIGNED development bootloader written to a real stick (--allow-unsigned-bootloader)."
                .to_string(),
        ),
    }
    if bundle.layout.device_bytes != size_bytes {
        notes.push(format!(
            "the bundle's recorded layout is for {}; this target is {}, so the plan above is \
             recomputed for the target (same policy {})",
            fmt_decimal(bundle.layout.device_bytes),
            fmt_decimal(size_bytes),
            layout::LAYOUT_POLICY
        ));
    }
    if matches!(req.policy, SignaturePolicy::AllowUnsigned(_)) {
        notes.push(
            "UNSIGNED bundle accepted with --allow-unsigned (development image only).".into(),
        );
    }
    if let Some(warning) = unprotected_note(req.target.is_device(), &req.policy, &report.signature)
    {
        notes.push(warning.to_string());
    }

    Ok(Ok(FlashPlan {
        bundle_id: bundle.id,
        bundle_version: bundle.version,
        signature: report.signature,
        target: planned_target,
        layout,
        partitions,
        boot_image: boot_src,
        boot_chain: chain,
        secure_boot: chain.secure_boot_line().to_string(),
        unsigned_bootloader_on_device: policy == BootloaderPolicy::UnsignedDeviceAllowed,
        bootloaders,
        grub_cfg,
        slot_b: slot_b_src,
        grubenv: env.vars().to_vec(),
        notes,
        device,
        floor_update: report.floor_update,
    }))
}

fn short(sha: &str) -> &str {
    &sha[..sha.len().min(12)]
}

/// The ESP's "Contents" lines in the plan.
fn esp_contents(
    bootloaders: &[EspBinary],
    grub_cfg: &[String],
    parts: BootPartitions,
    env: &GrubEnv,
) -> Vec<String> {
    let mut out: Vec<String> = bootloaders
        .iter()
        .map(|b| {
            format!(
                "{} <- {} [{}] ({}, sha256 {})",
                b.esp_path,
                b.source.path,
                b.role,
                fmt_binary(b.source.size),
                short(&b.source.sha256)
            )
        })
        .collect();
    for cfg in grub_cfg {
        out.push(format!(
            "{cfg} (slot A = gpt{}, slot B = gpt{})",
            parts.slot_a, parts.slot_b
        ));
    }
    out.push(format!(
        "{} ({})",
        bootcfg::ESP_GRUBENV,
        env.vars()
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join(" ")
    ));
    out
}

/// Human-readable plan.
pub fn render_plan(p: &FlashPlan, dry_run: bool) -> String {
    let mut out = String::new();
    out.push_str(if dry_run {
        "Companion Stick flash plan (DRY RUN — nothing will be written)\n\n"
    } else {
        "Companion Stick flash plan\n\n"
    });
    let sig = match &p.signature {
        SignatureStatus::Valid {
            key_fingerprint,
            sequence: Some(n),
            expires_at: Some(until),
        } => format!("signature valid (key {key_fingerprint}), sequence {n}, expires {until}"),
        SignatureStatus::Valid {
            key_fingerprint, ..
        } => format!("signature valid (key {key_fingerprint})"),
        SignatureStatus::UnsignedAllowed => "UNSIGNED (--allow-unsigned)".into(),
        other => format!("{other:?}"),
    };
    out.push_str(&format!(
        "Bundle   {} {} — {sig}\n",
        p.bundle_id, p.bundle_version
    ));
    out.push_str(&format!("Boot     {}\n", p.secure_boot));
    if p.unsigned_bootloader_on_device {
        out.push_str(UNSIGNED_DEVICE_WARNING);
    }
    match &p.target {
        PlannedTarget::Image {
            path,
            size_bytes,
            overwrites_existing,
        } => out.push_str(&format!(
            "Target   IMAGE FILE {path} — {} ({}), sparse{}\n",
            fmt_decimal(*size_bytes),
            fmt_binary(*size_bytes),
            if *overwrites_existing {
                ", OVERWRITES the existing file"
            } else {
                ", new file"
            }
        )),
        PlannedTarget::Device {
            given,
            identity,
            transport,
            removable,
            logical_sector,
        } => {
            out.push_str(&format!(
                "Target   DEVICE {given}\n\
                 \x20        ******************************************************************\n\
                 \x20        *  EVERYTHING ON THIS DEVICE WILL BE ERASED                      *\n\
                 \x20        ******************************************************************\n\
                 \x20        model:  {}\n\
                 \x20        serial: {}\n\
                 \x20        size:   {} ({}), {logical_sector}-byte sectors\n\
                 \x20        bus:    {}{}\n",
                identity.model.as_deref().unwrap_or("(unknown)"),
                identity.serial.as_deref().unwrap_or("(none reported)"),
                fmt_decimal(identity.size_bytes),
                fmt_binary(identity.size_bytes),
                transport.as_deref().unwrap_or("unknown"),
                if *removable { ", removable" } else { "" }
            ));
        }
    }
    out.push('\n');
    out.push_str(&layout::render_table(&p.layout));
    out.push_str("\nContents\n");
    for c in &p.partitions {
        let fs = match &c.fs_label {
            Some(l) => format!("{} \"{l}\"", c.filesystem),
            None => c.filesystem.clone(),
        };
        out.push_str(&format!("{:>2}  {:<11} {}\n", c.index, c.label, fs));
        for line in &c.contents {
            out.push_str(&format!("      {line}\n"));
        }
    }
    if !p.notes.is_empty() {
        out.push_str("\nNotes\n");
        for n in &p.notes {
            out.push_str(&format!("  - {n}\n"));
        }
    }
    if dry_run {
        if let PlannedTarget::Device { identity, .. } = &p.target {
            let serial = identity
                .serial
                .as_ref()
                .map(|s| format!(" --expect-serial '{s}'"))
                .unwrap_or_default();
            out.push_str(&format!(
                "\nTo write it, re-run without --dry-run and with: --confirm {}{serial}\n",
                identity.node
            ));
        }
    }
    out
}

fn step(msg: &str) {
    eprintln!("==> {msg}");
}

/// Build the four filesystem images (ESP, shared, cache, persist) in `work`.
fn build_images(p: &FlashPlan, work: &Path) -> anyhow::Result<Vec<(u32, PathBuf)>> {
    let mut out = Vec::new();
    for part in &p.layout.partitions {
        let img = work.join(format!("p{}-{}.img", part.index, part.label));
        match part.filesystem {
            Filesystem::RawImage => continue,
            Filesystem::Vfat => {
                sparse_file(&img, part.size_bytes)?;
                step(&format!(
                    "mkfs.vfat {} ({})",
                    part.label,
                    fmt_binary(part.size_bytes)
                ));
                tools::run(
                    "mkfs.vfat",
                    [
                        "-F".as_ref(),
                        "32".as_ref(),
                        "-n".as_ref(),
                        part.label.as_ref(),
                        img.as_os_str(),
                    ],
                )?;
                populate_esp(p, &img, work)?;
            }
            Filesystem::Exfat => {
                sparse_file(&img, part.size_bytes)?;
                step(&format!(
                    "mkfs.exfat {} ({})",
                    part.label,
                    fmt_binary(part.size_bytes)
                ));
                tools::run(
                    "mkfs.exfat",
                    ["-L".as_ref(), part.label.as_ref(), img.as_os_str()],
                )?;
            }
            Filesystem::Ext4 => {
                sparse_file(&img, part.size_bytes)?;
                step(&format!(
                    "mkfs.ext4 {} ({}), filesystem label \"{PERSIST_FS_LABEL}\"",
                    part.label,
                    fmt_binary(part.size_bytes)
                ));
                // nodiscard: never rely on holes reading as zero (see sparse.rs);
                // lazy_itable_init: the kernel initialises inode tables on first mount.
                tools::run(
                    "mkfs.ext4",
                    [
                        "-F".as_ref(),
                        "-q".as_ref(),
                        "-L".as_ref(),
                        PERSIST_FS_LABEL.as_ref(),
                        "-E".as_ref(),
                        "nodiscard,lazy_itable_init=1".as_ref(),
                        img.as_os_str(),
                    ],
                )?;
            }
        }
        out.push((part.index, img));
    }
    Ok(out)
}

fn sparse_file(path: &Path, size: u64) -> anyhow::Result<()> {
    let f = File::create(path).with_context(|| format!("creating {}", path.display()))?;
    f.set_len(size)
        .with_context(|| format!("sizing {} to {size} bytes (sparse)", path.display()))?;
    Ok(())
}

fn populate_esp(p: &FlashPlan, esp: &Path, work: &Path) -> anyhow::Result<()> {
    // (local file, ESP path) pairs to copy.
    let mut files: Vec<(PathBuf, String)> = Vec::new();
    // Bootloaders: read once, check against the (verified) manifest, then copy that buffer.
    for (i, b) in p.bootloaders.iter().enumerate() {
        let bytes = fs::read(&b.source.local)
            .with_context(|| format!("reading {}", b.source.local.display()))?;
        ensure!(
            crate::hashing::sha256_hex(&bytes) == b.source.sha256,
            "{} changed since it was verified — refusing",
            b.source.path
        );
        let local = work.join(format!("bootloader-{i}.efi"));
        fs::write(&local, &bytes)?;
        files.push((local, b.esp_path.clone()));
    }
    let cfg = work.join("grub.cfg");
    fs::write(&cfg, bootcfg::render_grub_cfg(&p.layout)?)?;
    for dst in &p.grub_cfg {
        files.push((cfg.clone(), dst.clone()));
    }
    let mut env = GrubEnv::new();
    for (k, v) in &p.grubenv {
        env.set(k, v)?;
    }
    let envf = work.join("grubenv");
    fs::write(&envf, env.encode()?)?;
    files.push((envf, bootcfg::ESP_GRUBENV.to_string()));

    let i = esp.as_os_str();
    let mut mmd: Vec<std::ffi::OsString> = vec!["-i".into(), i.into()];
    mmd.extend(
        bootcfg::esp_dirs(p.boot_chain)
            .into_iter()
            .map(|d| format!("::/{d}").into()),
    );
    tools::run("mmd", &mmd)?;
    for (src, dst) in &files {
        let dst = format!("::/{dst}");
        tools::run("mcopy", ["-i".as_ref(), i, src.as_os_str(), dst.as_ref()])?;
    }
    step(&format!(
        "populated CI-EFI ({:?} boot chain): {}",
        p.boot_chain,
        files
            .iter()
            .map(|(_, d)| d.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    ));
    Ok(())
}

/// Stream `src` raw into `dst` at `offset`, hashing as it goes; fails if the bytes are not
/// the ones expected (the file changed after verification).
fn stream_raw(src: &SourceFile, dst: &mut File, offset: u64) -> anyhow::Result<u64> {
    let mut f =
        File::open(&src.local).with_context(|| format!("opening {}", src.local.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 4 * MIB as usize];
    let mut done: u64 = 0;
    dst.seek(SeekFrom::Start(offset))?;
    let mut progress = Progress::auto(1);
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        ensure!(
            done + n as u64 <= src.size,
            "{} grew since it was verified",
            src.path
        );
        hasher.update(&buf[..n]);
        dst.write_all(&buf[..n])
            .with_context(|| format!("writing at offset {}", offset + done))?;
        done += n as u64;
        progress.update(1, &src.path, done, src.size);
    }
    progress.finish();
    ensure!(
        done == src.size && hex::encode(hasher.finalize()) == src.sha256,
        "{} changed since it was verified — the slot contents are NOT trustworthy; re-run flash",
        src.path
    );
    Ok(done)
}

fn hash_region(f: &mut File, offset: u64, len: u64) -> anyhow::Result<String> {
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 4 * MIB as usize];
    f.seek(SeekFrom::Start(offset))?;
    let mut left = len;
    while left > 0 {
        let n = (left as usize).min(buf.len());
        f.read_exact(&mut buf[..n])?;
        hasher.update(&buf[..n]);
        left -= n as u64;
    }
    Ok(hex::encode(hasher.finalize()))
}

/// Compare every data extent of `src` with `dst` at `offset`.
fn verify_extents(src: &mut File, dst: &mut File, offset: u64) -> anyhow::Result<u64> {
    let mut a = vec![0u8; MIB as usize];
    let mut b = vec![0u8; MIB as usize];
    let mut compared = 0;
    for e in sparse::data_extents(src)? {
        let mut pos = e.start;
        while pos < e.end {
            let n = ((e.end - pos) as usize).min(a.len());
            src.seek(SeekFrom::Start(pos))?;
            src.read_exact(&mut a[..n])?;
            dst.seek(SeekFrom::Start(offset + pos))?;
            dst.read_exact(&mut b[..n])?;
            ensure!(
                a[..n] == b[..n],
                "read-back mismatch at target offset {}",
                offset + pos
            );
            pos += n as u64;
            compared += n as u64;
        }
    }
    Ok(compared)
}

fn target_path(p: &FlashPlan) -> PathBuf {
    match &p.target {
        PlannedTarget::Image { path, .. } => PathBuf::from(path),
        PlannedTarget::Device { identity, .. } => PathBuf::from(&identity.node),
    }
}

/// Write a plan produced by [`plan`]. For devices, `confirm`/`expect_serial` must match.
pub fn execute(p: &FlashPlan, req: &FlashRequest) -> anyhow::Result<WriteReport> {
    // Confirmation first: nothing below runs without it.
    if let Some(dev) = &p.device {
        target::check_confirmation(
            &dev.disk.identity(),
            req.confirm.as_deref(),
            req.expect_serial.as_deref(),
        )?;
    }
    tools::require(&tools::FLASH_TOOLS)?;

    // Build all filesystems before touching the target.
    let base = match &req.work_dir {
        Some(d) => d.clone(),
        None => std::env::temp_dir(),
    };
    let work = tempfile::Builder::new()
        .prefix("ci-stick-flash-")
        .tempdir_in(&base)
        .with_context(|| format!("creating a work directory in {}", base.display()))?;
    let images = build_images(p, work.path())?;

    let path = target_path(p);
    let (mut dst, sector, known_zero) = match (&p.target, &p.device) {
        (PlannedTarget::Image { size_bytes, .. }, _) => {
            target::check_image_path(&path)?;
            let f = File::options()
                .read(true)
                .write(true)
                .create(true)
                .truncate(true)
                .open(&path)
                .with_context(|| format!("creating {}", path.display()))?;
            f.set_len(*size_bytes)?;
            (f, 512, true)
        }
        (PlannedTarget::Device { identity, .. }, Some(dev)) => {
            let mut f = target::open_exclusive(&identity.node)?;
            target::recheck_identity(identity, &mut f)?;
            (f, dev.disk.logical_sector, false)
        }
        (PlannedTarget::Device { .. }, None) => bail!("internal: device plan without device facts"),
    };
    let size = p.layout.device_bytes;
    let mut report = WriteReport::default();

    // 1. Wipe old signatures, then the partition table.
    step("zeroing the first and last MiB, clearing old partition tables");
    let zeros = vec![0u8; MIB as usize];
    for off in [0, size - MIB] {
        dst.seek(SeekFrom::Start(off))?;
        dst.write_all(&zeros)?;
    }
    dst.sync_all()?;
    tools::run("sgdisk", ["--zap-all".as_ref(), path.as_os_str()])?;
    let mut args: Vec<std::ffi::OsString> = gpt::sgdisk_args(&p.layout, sector)?
        .into_iter()
        .map(Into::into)
        .collect();
    args.push(path.clone().into_os_string());
    step("writing the GPT (sgdisk)");
    tools::run("sgdisk", &args)?;
    target::drop_cache(&dst);
    let written_gpt = gpt::read(&mut dst, Some(sector))?;
    gpt::check_matches_plan(&written_gpt, &p.layout)?;

    // 2. Filesystems, sparsely.
    for (index, img) in &images {
        let part = &p.layout.partitions[*index as usize - 1];
        let mut src = File::open(img)?;
        let stats = sparse::copy_sparse(&mut src, &mut dst, part.start_bytes, known_zero, |_| {})?;
        step(&format!(
            "{}: wrote {} in {} extents",
            part.label,
            fmt_binary(stats.bytes_written),
            stats.extents
        ));
        report.bytes_written += stats.bytes_written;
    }

    // 3. Boot slots.
    let slot_a = partition(&p.layout, PartitionRole::BootA)?.clone();
    let slot_b = partition(&p.layout, PartitionRole::BootB)?.clone();
    step(&format!(
        "{}: writing {} ({})",
        slot_a.label,
        p.boot_image.path,
        fmt_binary(p.boot_image.size)
    ));
    report.bytes_written += stream_raw(&p.boot_image, &mut dst, slot_a.start_bytes)?;
    match &p.slot_b {
        Some(src) => {
            step(&format!(
                "{}: writing {} ({})",
                slot_b.label,
                src.path,
                fmt_binary(src.size)
            ));
            report.bytes_written += stream_raw(src, &mut dst, slot_b.start_bytes)?;
        }
        None if !known_zero => {
            dst.seek(SeekFrom::Start(slot_b.start_bytes))?;
            dst.write_all(&zeros)?;
            report.bytes_written += MIB;
        }
        None => {}
    }

    // 4. Flush and read back.
    step("syncing");
    dst.sync_all().context("fsync")?;
    target::drop_cache(&dst);
    step("reading back");
    let again = gpt::read(&mut dst, Some(sector))?;
    ensure!(
        again.raw == written_gpt.raw,
        "the GPT changed while writing partitions"
    );
    gpt::check_matches_plan(&again, &p.layout)?;
    report.checks.push(format!(
        "GPT: {} partitions match the plan, header and entry CRCs valid",
        again.entries.len()
    ));
    for (part, src) in [(&slot_a, Some(&p.boot_image)), (&slot_b, p.slot_b.as_ref())] {
        match src {
            Some(src) => {
                let got = hash_region(&mut dst, part.start_bytes, src.size)?;
                ensure!(
                    got == src.sha256,
                    "{}: read-back sha256 {got} != expected {}",
                    part.label,
                    src.sha256
                );
                report.checks.push(format!(
                    "{}: sha256 {} matches {}",
                    part.label,
                    short(&got),
                    src.path
                ));
            }
            None => {
                let got = hash_region(&mut dst, part.start_bytes, MIB)?;
                ensure!(
                    got == crate::hashing::sha256_hex(&zeros),
                    "{}: header is not zeroed",
                    part.label
                );
                report
                    .checks
                    .push(format!("{}: empty (header zeroed)", part.label));
            }
        }
    }
    for (index, img) in &images {
        let part = &p.layout.partitions[*index as usize - 1];
        let mut src = File::open(img)?;
        let n = verify_extents(&mut src, &mut dst, part.start_bytes)?;
        report.checks.push(format!(
            "{}: {} of filesystem data read back identical",
            part.label,
            fmt_binary(n)
        ));
    }
    drop(dst);
    Ok(report)
}

/// Record the floor of the bundle that was just written (a schema 2 bundle, with floors on).
///
/// Failing here does not undo the write, so the message says that. A required floor (device
/// and pinned flows) makes it an error; a development image flow only warns.
fn commit_floor(p: &FlashPlan, req: &FlashRequest) -> anyhow::Result<()> {
    let (
        Some(update),
        FloorMode::Store {
            store, required, ..
        },
    ) = (&p.floor_update, &req.freshness.floors)
    else {
        return Ok(());
    };
    match store.record(update) {
        Ok(_) => Ok(()),
        Err(e) if *required => Err(anyhow::Error::new(e)
            .context("the stick was written, but the sequence floor could not be recorded")),
        Err(e) => {
            eprintln!(
                "warning: the stick was written, but the sequence floor was not recorded: {e}"
            );
            Ok(())
        }
    }
}

/// Plan, and unless it is a dry run, write.
pub fn flash(req: &FlashRequest, progress: &mut Progress) -> anyhow::Result<FlashOutcome> {
    let p = match plan(req, progress)? {
        Ok(p) => p,
        Err(report) => return Ok(FlashOutcome::VerifyFailed(Box::new(report))),
    };
    if req.dry_run {
        return Ok(FlashOutcome::DryRun(Box::new(p)));
    }
    eprint!("{}", render_plan(&p, false));
    let report = execute(&p, req)?;
    commit_floor(&p, req)?;
    Ok(FlashOutcome::Written(Box::new(p), report))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(target: TargetSpec, policy: SignaturePolicy) -> FlashRequest {
        FlashRequest {
            bundle_root: "/nonexistent".into(),
            policy,
            target,
            boot_image: None,
            slot_b_from: None,
            extra_cmdline: None,
            dry_run: true,
            confirm: None,
            expect_serial: None,
            work_dir: None,
            allow_unsigned_bootloader: false,
            freshness: Freshness::without_floors(0),
        }
    }

    #[test]
    fn bootloader_policy_per_chain_and_target() {
        use BootloaderPolicy::*;
        for allow in [false, true] {
            for dev in [false, true] {
                assert_eq!(
                    bootloader_policy(BootChain::Secure, dev, allow).unwrap(),
                    Signed
                );
            }
            assert_eq!(
                bootloader_policy(BootChain::Development, false, allow).unwrap(),
                UnsignedImage
            );
        }
        let e = bootloader_policy(BootChain::Development, true, false).unwrap_err();
        let msg = format!("{e}");
        assert!(msg.contains("--allow-unsigned-bootloader"), "{msg}");
        assert!(msg.contains("fetch-signed-boot.sh"), "{msg}");
        assert_eq!(
            bootloader_policy(BootChain::Development, true, true).unwrap(),
            UnsignedDeviceAllowed
        );
    }

    fn fake_plan(chain: BootChain, on_device: bool) -> FlashPlan {
        let layout = layout::plan(64_000_000_000).unwrap();
        let src = |p: &str| SourceFile {
            path: p.into(),
            size: 1024,
            sha256: "ab".repeat(32),
            local: p.into(),
        };
        let bootloaders: Vec<EspBinary> = bootcfg::esp_binaries(chain)
            .iter()
            .map(|(role, esp)| EspBinary {
                role: *role,
                esp_path: (*esp).into(),
                source: src(&format!("efi/{}", role.file_name())),
            })
            .collect();
        let grub_cfg: Vec<String> = bootcfg::grub_cfg_paths(chain)
            .iter()
            .map(|s| s.to_string())
            .collect();
        let mut env = GrubEnv::new();
        env.set(grubenv::VAR_ACTIVE_SLOT, "A").unwrap();
        let parts = BootPartitions::from_layout(&layout).unwrap();
        let esp = esp_contents(&bootloaders, &grub_cfg, parts, &env);
        FlashPlan {
            bundle_id: "t".into(),
            bundle_version: "1".into(),
            signature: SignatureStatus::UnsignedAllowed,
            target: PlannedTarget::Image {
                path: "/tmp/x.img".into(),
                size_bytes: 64_000_000_000,
                overwrites_existing: false,
            },
            partitions: vec![PartitionContents {
                index: 1,
                label: "CI-EFI".into(),
                filesystem: "vfat".into(),
                fs_label: Some("CI-EFI".into()),
                start_bytes: 0,
                size_bytes: 1,
                contents: esp,
            }],
            layout,
            boot_image: src("boot/x.iso"),
            boot_chain: chain,
            secure_boot: chain.secure_boot_line().into(),
            unsigned_bootloader_on_device: on_device,
            bootloaders,
            grub_cfg,
            slot_b: None,
            grubenv: env.vars().to_vec(),
            notes: vec![],
            device: None,
            floor_update: None,
        }
    }

    #[test]
    fn plan_text_states_secure_boot_support_and_esp_files() {
        let secure = render_plan(&fake_plan(BootChain::Secure, false), true);
        assert!(
            secure.contains("Boot     Secure Boot: supported (shim → Canonical GRUB)"),
            "{secure}"
        );
        for line in [
            "EFI/BOOT/BOOTX64.EFI <- efi/shimx64.efi [shim]",
            "EFI/BOOT/grubx64.efi <- efi/grubx64.efi [grub]",
            "EFI/BOOT/mmx64.efi <- efi/mmx64.efi [mok-manager]",
            "EFI/BOOT/grub.cfg (slot A = gpt3, slot B = gpt4)",
            "EFI/ubuntu/grub.cfg (slot A = gpt3",
            "ci-stick/grubenv (active_slot=A)",
        ] {
            assert!(secure.contains(line), "{line:?} missing:\n{secure}");
        }
        assert!(!secure.contains("ci-stick/grub.cfg"));
        assert!(!secure.contains("WARNING"));

        let dev = render_plan(&fake_plan(BootChain::Development, false), true);
        assert!(dev.contains(
            "Boot     Secure Boot: NOT supported (unsigned development GRUB) — disable Secure \
             Boot to boot this stick"
        ));
        assert!(dev.contains("EFI/BOOT/BOOTX64.EFI <- efi/BOOTX64.EFI [standalone-grub]"));
        assert!(dev.contains("ci-stick/grub.cfg (slot A"));
        assert!(!dev.contains("EFI/ubuntu"));
        assert!(!dev.contains("WARNING"));

        let loud = render_plan(&fake_plan(BootChain::Development, true), true);
        assert!(
            loud.contains("WARNING: --allow-unsigned-bootloader"),
            "{loud}"
        );
    }

    #[test]
    fn warning_banner_is_rectangular() {
        let widths: Vec<usize> = UNSIGNED_DEVICE_WARNING
            .lines()
            .map(|l| l.chars().count())
            .collect();
        assert!(widths.windows(2).all(|w| w[0] == w[1]), "{widths:?}");
    }

    #[test]
    fn allow_unsigned_is_rejected_for_devices() {
        let dev = TargetSpec::Device {
            path: "/dev/sdz".into(),
        };
        let e =
            validate_request(&req(dev.clone(), SignaturePolicy::AllowUnsigned(None))).unwrap_err();
        assert!(
            format!("{e}").contains("--allow-unsigned is refused with --device"),
            "{e}"
        );
        assert!(validate_request(&req(dev.clone(), SignaturePolicy::NotChecked)).is_err());
        let mut r = req(
            dev,
            SignaturePolicy::Require(
                crate::signing::generate_signing_key()
                    .unwrap()
                    .verifying_key(),
            ),
        );
        r.slot_b_from = Some("/tmp/x.iso".into());
        assert!(format!("{}", validate_request(&r).unwrap_err()).contains("--slot-b-from"));

        let img = TargetSpec::Image {
            path: "/tmp/x.img".into(),
            size_bytes: 64_000_000_000,
        };
        validate_request(&req(img.clone(), SignaturePolicy::AllowUnsigned(None))).unwrap();
        let mut r = req(img, SignaturePolicy::AllowUnsigned(None));
        r.confirm = Some("/dev/sdb".into());
        assert!(validate_request(&r).is_err(), "--confirm is for devices");
        r.confirm = None;
        r.extra_cmdline = Some("a;b".into());
        assert!(validate_request(&r).is_err());
    }

    fn key() -> SignaturePolicy {
        SignaturePolicy::Require(
            crate::signing::generate_signing_key()
                .unwrap()
                .verifying_key(),
        )
    }

    #[test]
    fn a_device_write_needs_required_floors() {
        let dev = || TargetSpec::Device {
            path: "/dev/sdz".into(),
        };
        let img = TargetSpec::Image {
            path: "/tmp/x.img".into(),
            size_bytes: 64_000_000_000,
        };
        let with = |target: TargetSpec, floors: FloorMode| {
            let mut r = req(target, key());
            r.freshness.floors = floors;
            validate_request(&r)
        };
        // No floors at all, or floors that are only advisory: refused for a device.
        let e = with(dev(), FloorMode::Off).unwrap_err();
        assert!(format!("{e}").contains("sequence floor"), "{e}");
        for floors in [
            FloorMode::Unavailable {
                reason: "x".into(),
                required: false,
            },
            FloorMode::Store {
                store: crate::state::FloorStore::new("/nonexistent/state".into()),
                required: false,
                record: false,
            },
        ] {
            assert!(with(dev(), floors).is_err());
        }
        // Required floors, unavailable or not, are accepted; an image never needs them.
        with(
            dev(),
            FloorMode::Unavailable {
                reason: "x".into(),
                required: true,
            },
        )
        .unwrap();
        with(
            dev(),
            FloorMode::Store {
                store: crate::state::FloorStore::new("/nonexistent/state".into()),
                required: true,
                record: false,
            },
        )
        .unwrap();
        with(img, FloorMode::Off).unwrap();
    }

    fn written_plan(sequence: Option<u64>) -> FlashPlan {
        let mut p = fake_plan(BootChain::Secure, false);
        p.floor_update = sequence.map(|n| FloorUpdate {
            bundle_id: "flash-test".into(),
            floor: crate::state::Floor {
                sequence: n,
                bundle_sha256: "ab".repeat(32),
                signer: "0123456789abcdef".into(),
            },
        });
        p
    }

    fn with_store(dir: &Path, required: bool) -> FlashRequest {
        let mut r = req(
            TargetSpec::Image {
                path: "/tmp/x.img".into(),
                size_bytes: 64_000_000_000,
            },
            key(),
        );
        r.freshness.floors = FloorMode::Store {
            store: crate::state::FloorStore::new(dir.to_path_buf()),
            required,
            record: false,
        };
        r
    }

    #[test]
    fn the_floor_is_recorded_only_for_a_schema_2_plan_and_only_by_commit() {
        let t = tempfile::tempdir().unwrap();
        let dir = t.path().join("state");
        let r = with_store(&dir, true);

        // A plan without a floor (schema 1) records nothing and does not even create the directory.
        commit_floor(&written_plan(None), &r).unwrap();
        assert!(!dir.exists());
        // Planning alone (what --dry-run does) never writes: only commit_floor does.
        let p = written_plan(Some(4));
        assert!(!dir.exists());
        commit_floor(&p, &r).unwrap();
        let store = crate::state::FloorStore::new(dir.clone());
        assert_eq!(store.floor("flash-test").unwrap().unwrap().sequence, 4);
        // Floors that are off record nothing.
        let off = req(
            TargetSpec::Image {
                path: "/tmp/x.img".into(),
                size_bytes: 64_000_000_000,
            },
            key(),
        );
        let t2 = tempfile::tempdir().unwrap();
        commit_floor(&written_plan(Some(9)), &off).unwrap();
        assert_eq!(fs::read_dir(t2.path()).unwrap().count(), 0);
    }

    #[test]
    fn a_floor_that_cannot_be_recorded_after_the_write_is_said_aloud() {
        let t = tempfile::tempdir().unwrap();
        let blocker = t.path().join("blocker");
        fs::write(&blocker, b"x").unwrap();
        let p = written_plan(Some(2));
        let e = commit_floor(&p, &with_store(&blocker.join("state"), true)).unwrap_err();
        assert!(format!("{e:#}").contains("the stick was written"), "{e:#}");
        // A development image flow only warns.
        commit_floor(&p, &with_store(&blocker.join("state"), false)).unwrap();
    }

    #[test]
    fn only_a_schema_1_bundle_on_a_device_is_flagged_in_the_plan() {
        let valid = |sequence: Option<u64>| SignatureStatus::Valid {
            key_fingerprint: "0123456789abcdef".into(),
            sequence,
            expires_at: sequence.map(|_| "2099-01-01T00:00:00Z".to_string()),
        };
        let dev_key = key();
        assert_eq!(
            unprotected_note(true, &dev_key, &valid(None)),
            Some(UNPROTECTED_DEVICE_WARNING)
        );
        assert_eq!(
            unprotected_note(true, &dev_key, &valid(Some(3))),
            None,
            "a schema 2 bundle is protected"
        );
        assert_eq!(
            unprotected_note(false, &dev_key, &valid(None)),
            None,
            "an image file is a development flow"
        );
        assert_eq!(
            unprotected_note(true, &dev_key, &SignatureStatus::UnsignedAllowed),
            None
        );
        assert!(UNPROTECTED_DEVICE_WARNING.contains("no release key is pinned in this build"));
        assert!(UNPROTECTED_DEVICE_WARNING.contains("nothing protects against an old bundle"));
        // And the plan prints it.
        let mut p = fake_plan(BootChain::Secure, false);
        p.notes.push(UNPROTECTED_DEVICE_WARNING.to_string());
        assert!(render_plan(&p, true).contains("nothing protects against an old bundle"));
    }
}
