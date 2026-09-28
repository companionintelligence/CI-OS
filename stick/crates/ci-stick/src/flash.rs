//! `ci-stick flash`: write a verified bundle onto a stick (or a stick image) using the
//! layout plan.
//!
//! Order of operations, each step refusing before anything is written if it fails:
//!
//! 1. **Verify** the bundle with [`crate::verify`] (signature required unless
//!    `--allow-unsigned`, which is only accepted for `--image` targets).
//! 2. **Plan**: resolve the target, compute the layout for its size, pick the boot image
//!    and the bootloader from the manifest, check everything fits. `--dry-run` stops here.
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
use crate::manifest::{Artifact, ArtifactKind, Bundle, Platform, BUNDLE_FILE};
use crate::progress::Progress;
use crate::size::{fmt_binary, fmt_decimal, MIB};
use crate::sparse;
use crate::target::{self, DeviceTarget, Identity};
use crate::tools;
use crate::verify::{self, SignaturePolicy, SignatureStatus, VerifyReport};

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
    pub bootloader: SourceFile,
    pub slot_b: Option<SourceFile>,
    pub grubenv: Vec<(String, String)>,
    pub notes: Vec<String>,
    #[serde(skip)]
    device: Option<DeviceTarget>,
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
    let report = verify::verify(
        &req.bundle_root,
        &req.policy,
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
    let loader = pick_one(
        &bundle,
        "x86_64 UEFI bootloader (efi/BOOTX64.EFI)",
        |a| {
            a.kind == ArtifactKind::Bootloader
                && a.platforms
                    .as_deref()
                    .is_some_and(|p| p.contains(&Platform::X86_64Uefi))
        },
        None,
    )?;
    ensure!(
        loader.size <= MAX_BOOTLOADER_BYTES,
        "bootloader {} is {} — larger than any plausible BOOTX64.EFI",
        loader.path,
        fmt_binary(loader.size)
    );

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
    let loader_src = source(&root, loader);

    let partitions = layout
        .partitions
        .iter()
        .map(|p| {
            let (fs_label, contents) = match p.role {
                PartitionRole::Esp => (
                    Some(p.label.clone()),
                    vec![
                        format!(
                            "{} <- {} ({}, sha256 {})",
                            bootcfg::ESP_BOOTLOADER,
                            loader_src.path,
                            fmt_binary(loader_src.size),
                            short(&loader_src.sha256)
                        ),
                        format!(
                            "{} (slot A = gpt{}, slot B = gpt{})",
                            bootcfg::ESP_GRUB_CFG,
                            parts.slot_a,
                            parts.slot_b
                        ),
                        format!(
                            "{} ({})",
                            bootcfg::ESP_GRUBENV,
                            env.vars()
                                .iter()
                                .map(|(k, v)| format!("{k}={v}"))
                                .collect::<Vec<_>>()
                                .join(" ")
                        ),
                    ],
                ),
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

    let mut notes = vec![
        "BOOTX64.EFI is a standalone GRUB that is NOT Secure Boot signed: disable Secure Boot \
         to boot this stick (shim signing is a planned follow-up)."
            .to_string(),
    ];
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

    Ok(Ok(FlashPlan {
        bundle_id: bundle.id,
        bundle_version: bundle.version,
        signature: report.signature,
        target: planned_target,
        layout,
        partitions,
        boot_image: boot_src,
        bootloader: loader_src,
        slot_b: slot_b_src,
        grubenv: env.vars().to_vec(),
        notes,
        device,
    }))
}

fn short(sha: &str) -> &str {
    &sha[..sha.len().min(12)]
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
        SignatureStatus::Valid { key_fingerprint } => {
            format!("signature valid (key {key_fingerprint})")
        }
        SignatureStatus::UnsignedAllowed => "UNSIGNED (--allow-unsigned)".into(),
        other => format!("{other:?}"),
    };
    out.push_str(&format!(
        "Bundle   {} {} — {sig}\n",
        p.bundle_id, p.bundle_version
    ));
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
    // Bootloader: read once, check against the (verified) manifest, then copy that buffer.
    let bytes = fs::read(&p.bootloader.local)
        .with_context(|| format!("reading {}", p.bootloader.local.display()))?;
    ensure!(
        crate::hashing::sha256_hex(&bytes) == p.bootloader.sha256,
        "{} changed since it was verified — refusing",
        p.bootloader.path
    );
    let efi = work.join("BOOTX64.EFI");
    fs::write(&efi, &bytes)?;
    let cfg = work.join("grub.cfg");
    fs::write(&cfg, bootcfg::render_grub_cfg(&p.layout)?)?;
    let mut env = GrubEnv::new();
    for (k, v) in &p.grubenv {
        env.set(k, v)?;
    }
    let envf = work.join("grubenv");
    fs::write(&envf, env.encode()?)?;

    let i = esp.as_os_str();
    tools::run(
        "mmd",
        [
            "-i".as_ref(),
            i,
            "::/EFI".as_ref(),
            "::/EFI/BOOT".as_ref(),
            "::/ci-stick".as_ref(),
        ],
    )?;
    for (src, dst) in [
        (&efi, bootcfg::ESP_BOOTLOADER),
        (&cfg, bootcfg::ESP_GRUB_CFG),
        (&envf, bootcfg::ESP_GRUBENV),
    ] {
        let dst = format!("::/{dst}");
        tools::run("mcopy", ["-i".as_ref(), i, src.as_os_str(), dst.as_ref()])?;
    }
    step("populated CI-EFI: EFI/BOOT/BOOTX64.EFI, ci-stick/grub.cfg, ci-stick/grubenv");
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
        }
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
}
