//! Write targets and the device safety model.
//!
//! A target is either an image file (`--image`, created or overwritten, sparse) or a
//! block device (`--device`, Linux only in this release). Before anything touches a
//! device, [`assess`] must come back empty. It is a pure function over facts gathered
//! from `lsblk`, sysfs, `/proc/self/mountinfo` and `/proc/swaps`, so every refusal rule
//! is unit-tested against fixtures:
//!
//! * the disk is one of `devices`' removable/USB candidates (never the system disk, never
//!   a loop, zram, device-mapper, md, nbd or optical device);
//! * none of it is mounted: compared by `major:minor` of the disk and every partition,
//!   not by name strings;
//! * none of it holds swap, and nothing (dm, md, LVM) is stacked on it;
//! * it is at least the layout minimum.
//!
//! Then the writer opens the node with `O_EXCL` (the kernel refuses if anything has it
//! mounted or claimed) and, immediately before the first write, re-reads size, model and
//! serial from sysfs; if anything differs from the plan the user was shown ([`Identity`]),
//! it aborts. A `/dev/disk/by-*` symlink is resolved and the real node is always shown.

use std::fs;
use std::path::Path;

use anyhow::{bail, Context as _};
use serde::Serialize;

use crate::devices::BlockDevice;
use crate::layout::MIN_DEVICE_BYTES;
use crate::size::{fmt_binary, fmt_decimal};

/// `major:minor` of a block device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
pub struct DevNum {
    pub major: u32,
    pub minor: u32,
}

impl DevNum {
    /// Decode a Linux `dev_t` (glibc encoding).
    pub fn from_dev_t(dev: u64) -> Self {
        Self {
            major: (((dev >> 8) & 0xfff) | ((dev >> 32) & !0xfff)) as u32,
            minor: ((dev & 0xff) | ((dev >> 12) & !0xff)) as u32,
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        let (a, b) = s.trim().split_once(':')?;
        Some(Self {
            major: a.parse().ok()?,
            minor: b.parse().ok()?,
        })
    }
}

impl std::fmt::Display for DevNum {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}", self.major, self.minor)
    }
}

/// One line of `/proc/self/mountinfo`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MountEntry {
    pub devnum: DevNum,
    pub mount_point: String,
    pub source: String,
}

/// Parse `/proc/self/mountinfo` (see proc(5)): field 3 is `major:minor`, field 5 the mount
/// point, and after the ` - ` separator come fstype and source.
pub fn parse_mountinfo(text: &str) -> Vec<MountEntry> {
    text.lines()
        .filter_map(|line| {
            let (pre, post) = line.split_once(" - ")?;
            let fields: Vec<&str> = pre.split(' ').collect();
            let devnum = DevNum::parse(fields.get(2)?)?;
            let mount_point = unescape_octal(fields.get(4)?);
            let source = post.split(' ').nth(1).unwrap_or_default().to_string();
            Some(MountEntry {
                devnum,
                mount_point,
                source,
            })
        })
        .collect()
}

/// `/proc` escapes space, tab, newline and backslash as `\ooo`.
fn unescape_octal(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\'
            && i + 3 < b.len()
            && b[i + 1..i + 4].iter().all(|c| (b'0'..=b'7').contains(c))
        {
            let v = (b[i + 1] - b'0') * 64 + (b[i + 2] - b'0') * 8 + (b[i + 3] - b'0');
            out.push(v);
            i += 4;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Paths listed in `/proc/swaps` (header skipped).
pub fn parse_swaps(text: &str) -> Vec<String> {
    text.lines()
        .skip(1)
        .filter_map(|l| l.split_whitespace().next())
        .map(unescape_octal)
        .collect()
}

/// What sysfs says about a whole disk.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DiskInfo {
    /// Kernel name, e.g. `sdb`.
    pub name: String,
    /// Device node, e.g. `/dev/sdb`.
    pub node: String,
    pub devnum: DevNum,
    pub size_bytes: u64,
    pub removable: bool,
    pub model: Option<String>,
    pub serial: Option<String>,
    pub logical_sector: u64,
    /// `(name, devnum)` of each partition.
    pub partitions: Vec<(String, DevNum)>,
    /// Devices stacked on the disk or its partitions (dm-*, md*).
    pub holders: Vec<String>,
}

impl DiskInfo {
    pub fn identity(&self) -> Identity {
        Identity {
            node: self.node.clone(),
            devnum: self.devnum,
            size_bytes: self.size_bytes,
            model: self.model.clone(),
            serial: self.serial.clone(),
        }
    }
}

/// The facts the user is shown and that must not change before the first write.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Identity {
    pub node: String,
    pub devnum: DevNum,
    pub size_bytes: u64,
    pub model: Option<String>,
    pub serial: Option<String>,
}

impl Identity {
    pub fn describe(&self) -> String {
        format!(
            "{}  [{}]  {} ({})  model: {}  serial: {}",
            self.node,
            self.devnum,
            fmt_decimal(self.size_bytes),
            fmt_binary(self.size_bytes),
            self.model.as_deref().unwrap_or("(unknown)"),
            self.serial.as_deref().unwrap_or("(none reported)")
        )
    }
}

/// `Some(reason)` if the device is no longer the one in the plan (re-enumeration, a
/// different stick plugged into the same node, a size change).
pub fn identity_changed(planned: &Identity, now: &Identity) -> Option<String> {
    let mut diffs = Vec::new();
    if planned.node != now.node {
        diffs.push(format!("node {} -> {}", planned.node, now.node));
    }
    if planned.devnum != now.devnum {
        diffs.push(format!("major:minor {} -> {}", planned.devnum, now.devnum));
    }
    if planned.size_bytes != now.size_bytes {
        diffs.push(format!(
            "size {} -> {} bytes",
            planned.size_bytes, now.size_bytes
        ));
    }
    if planned.model != now.model {
        diffs.push(format!("model {:?} -> {:?}", planned.model, now.model));
    }
    if planned.serial != now.serial {
        diffs.push(format!("serial {:?} -> {:?}", planned.serial, now.serial));
    }
    (!diffs.is_empty()).then(|| {
        format!(
            "the device changed since the plan was shown ({}); nothing was written — re-run the dry run",
            diffs.join(", ")
        )
    })
}

/// Facts for [`assess`].
pub struct SafetyFacts<'a> {
    pub disk: &'a DiskInfo,
    /// The `lsblk` entry for this disk, if `lsblk` listed it as a disk.
    pub listed: Option<&'a BlockDevice>,
    pub mounts: &'a [MountEntry],
    /// Devices holding active swap (block devices, or the device a swap file lives on).
    pub swap_devnums: &'a [DevNum],
}

const NEVER_TARGETS: [&str; 8] = [
    "loop",
    "zram",
    "ram",
    "dm-",
    "md",
    "nbd",
    "sr",
    "mmcblk0boot",
];

/// Every reason to refuse writing to this disk. Empty means it is safe to proceed to the
/// `O_EXCL` open.
pub fn assess(f: &SafetyFacts<'_>) -> Vec<String> {
    let d = f.disk;
    let mut refusals = Vec::new();
    if let Some(prefix) = NEVER_TARGETS.iter().find(|p| d.name.starts_with(**p)) {
        refusals.push(format!("{} is a {prefix}* device, never a stick", d.node));
    }
    match f.listed {
        None => refusals.push(format!(
            "{} is not listed by lsblk as a whole disk",
            d.node
        )),
        Some(b) if b.is_system => refusals.push(format!(
            "{} holds the running system ({})",
            d.node,
            b.mountpoints.join(", ")
        )),
        Some(b) if !b.is_candidate() => refusals.push(format!(
            "{} is not removable or USB-attached (transport {}); ci-stick only writes removable/USB disks",
            d.node,
            b.transport.as_deref().unwrap_or("unknown")
        )),
        Some(_) => {}
    }
    let mut ours: Vec<(String, DevNum)> = vec![(d.name.clone(), d.devnum)];
    ours.extend(d.partitions.iter().cloned());
    for m in f.mounts {
        if let Some((name, _)) = ours.iter().find(|(_, n)| *n == m.devnum) {
            refusals.push(format!(
                "{name} ({}) is mounted at {} — unmount it first",
                m.devnum, m.mount_point
            ));
        }
    }
    for s in f.swap_devnums {
        if let Some((name, _)) = ours.iter().find(|(_, n)| n == s) {
            refusals.push(format!("{name} ({s}) is in use as swap"));
        }
    }
    if !d.holders.is_empty() {
        refusals.push(format!(
            "{} is in use by {} (device-mapper/RAID/LVM)",
            d.node,
            d.holders.join(", ")
        ));
    }
    if d.size_bytes < MIN_DEVICE_BYTES {
        refusals.push(format!(
            "{} is {} — smaller than the {} minimum",
            d.node,
            fmt_binary(d.size_bytes),
            fmt_binary(MIN_DEVICE_BYTES)
        ));
    }
    refusals
}

/// How a user-given `--device` path resolved.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Resolved {
    pub given: String,
    pub node: String,
}

impl Resolved {
    pub fn via_symlink(&self) -> bool {
        self.given != self.node
    }

    pub fn describe(&self) -> String {
        if self.via_symlink() {
            format!("{} -> {} (symlink resolved)", self.given, self.node)
        } else {
            self.node.clone()
        }
    }
}

/// Resolve `--device` to a real block-device node.
pub fn resolve_device(given: &Path) -> anyhow::Result<Resolved> {
    let node =
        fs::canonicalize(given).with_context(|| format!("{} does not exist", given.display()))?;
    let meta = fs::metadata(&node).with_context(|| format!("inspecting {}", node.display()))?;
    if !is_block_device(&meta) {
        bail!(
            "{} is not a block device — refusing (to write an image file, use --image <file> --size <size>)",
            node.display()
        );
    }
    Ok(Resolved {
        given: given.display().to_string(),
        node: node.display().to_string(),
    })
}

#[cfg(unix)]
fn is_block_device(meta: &fs::Metadata) -> bool {
    use std::os::unix::fs::FileTypeExt as _;
    meta.file_type().is_block_device()
}

#[cfg(not(unix))]
fn is_block_device(_meta: &fs::Metadata) -> bool {
    false
}

/// `--image` must be a new path or an existing regular file, never a symlink or device.
pub fn check_image_path(path: &Path) -> anyhow::Result<()> {
    match fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e).with_context(|| format!("inspecting {}", path.display())),
        Ok(m) if m.file_type().is_symlink() => bail!(
            "{} is a symlink — refusing to follow it; pass the real path",
            path.display()
        ),
        Ok(m) if m.is_file() => Ok(()),
        Ok(_) => bail!(
            "{} exists and is not a regular file — use --device for block devices",
            path.display()
        ),
    }
}

fn read_trim(p: &Path) -> Option<String> {
    fs::read_to_string(p)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// The serial number: udev's `ID_SERIAL_SHORT`, else the nearest `serial` attribute up the
/// sysfs device chain (the USB device carries it for USB sticks).
fn find_serial(sys_block: &Path, devnum: DevNum) -> Option<String> {
    if let Ok(db) = fs::read_to_string(format!("/run/udev/data/b{devnum}")) {
        if let Some(v) = db
            .lines()
            .find_map(|l| l.strip_prefix("E:ID_SERIAL_SHORT="))
        {
            let v = v.trim();
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    let mut dir = fs::canonicalize(sys_block.join("device")).ok()?;
    for _ in 0..8 {
        if let Some(s) = read_trim(&dir.join("serial")) {
            return Some(s);
        }
        if !dir.pop() {
            break;
        }
    }
    None
}

/// Read a whole disk's facts from sysfs (Linux).
pub fn read_disk_info(node: &str) -> anyhow::Result<DiskInfo> {
    let meta = fs::metadata(node).with_context(|| format!("inspecting {node}"))?;
    let devnum = devnum_of(&meta)?;
    let sys = fs::canonicalize(format!("/sys/dev/block/{devnum}"))
        .with_context(|| format!("{node} ({devnum}) has no sysfs entry"))?;
    if sys.join("partition").exists() {
        let parent = sys
            .parent()
            .and_then(Path::file_name)
            .map(|n| format!("/dev/{}", n.to_string_lossy()))
            .unwrap_or_else(|| "the whole disk".into());
        bail!("{node} is a partition — pass the whole disk ({parent})");
    }
    let name = sys
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .context("sysfs path has no name")?;
    let sectors: u64 = read_trim(&sys.join("size"))
        .and_then(|s| s.parse().ok())
        .context("reading disk size from sysfs")?;
    let mut partitions = Vec::new();
    let mut holders = list_dir(&sys.join("holders"));
    if let Ok(entries) = fs::read_dir(&sys) {
        for e in entries.flatten() {
            let p = e.path();
            if p.join("partition").exists() {
                if let Some(n) = read_trim(&p.join("dev")).and_then(|s| DevNum::parse(&s)) {
                    partitions.push((e.file_name().to_string_lossy().into_owned(), n));
                }
                holders.extend(list_dir(&p.join("holders")));
            }
        }
    }
    partitions.sort();
    Ok(DiskInfo {
        node: node.to_string(),
        devnum,
        size_bytes: sectors * 512,
        removable: read_trim(&sys.join("removable")).as_deref() == Some("1"),
        model: read_trim(&sys.join("device/model")),
        serial: find_serial(&sys, devnum),
        logical_sector: read_trim(&sys.join("queue/logical_block_size"))
            .and_then(|s| s.parse().ok())
            .unwrap_or(512),
        partitions,
        holders,
        name,
    })
}

fn list_dir(p: &Path) -> Vec<String> {
    fs::read_dir(p)
        .map(|it| {
            it.flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(unix)]
pub fn devnum_of(meta: &fs::Metadata) -> anyhow::Result<DevNum> {
    use std::os::unix::fs::MetadataExt as _;
    Ok(DevNum::from_dev_t(meta.rdev()))
}

#[cfg(not(unix))]
pub fn devnum_of(_meta: &fs::Metadata) -> anyhow::Result<DevNum> {
    bail!("device numbers are only available on Unix")
}

/// Devices holding swap: each block device listed, and the device holding each swap file.
pub fn swap_devnums(swaps: &[String]) -> Vec<DevNum> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        swaps
            .iter()
            .filter_map(|p| fs::metadata(p).ok())
            .map(|m| {
                if is_block_device(&m) {
                    DevNum::from_dev_t(m.rdev())
                } else {
                    DevNum::from_dev_t(m.dev())
                }
            })
            .collect()
    }
    #[cfg(not(unix))]
    {
        let _ = swaps;
        Vec::new()
    }
}

/// Everything needed to decide about a device, gathered from the live system.
pub struct LiveFacts {
    pub disk: DiskInfo,
    pub listed: Option<BlockDevice>,
    pub mounts: Vec<MountEntry>,
    pub swap_devnums: Vec<DevNum>,
}

impl LiveFacts {
    pub fn gather(resolved: &Resolved) -> anyhow::Result<Self> {
        if std::env::consts::OS != "linux" {
            bail!(
                "writing to devices on {} is not supported yet — write an image with --image and flash it with your OS's tools",
                std::env::consts::OS
            );
        }
        let disk = read_disk_info(&resolved.node)?;
        let listed = match crate::devices::discover() {
            crate::devices::Discovery::Listed { devices, .. } => {
                devices.into_iter().find(|d| d.name == disk.name)
            }
            crate::devices::Discovery::Unsupported { reason } => bail!("{reason}"),
            crate::devices::Discovery::Failed { error, .. } => {
                bail!("cannot list block devices: {error}")
            }
        };
        let mounts = parse_mountinfo(
            &fs::read_to_string("/proc/self/mountinfo").context("reading /proc/self/mountinfo")?,
        );
        let swaps = parse_swaps(&fs::read_to_string("/proc/swaps").unwrap_or_default());
        Ok(Self {
            swap_devnums: swap_devnums(&swaps),
            disk,
            listed,
            mounts,
        })
    }

    pub fn assess(&self) -> Vec<String> {
        assess(&SafetyFacts {
            disk: &self.disk,
            listed: self.listed.as_ref(),
            mounts: &self.mounts,
            swap_devnums: &self.swap_devnums,
        })
    }
}

/// Check `--confirm` / `--expect-serial` against what the plan showed.
pub fn check_confirmation(
    identity: &Identity,
    confirm: Option<&str>,
    expect_serial: Option<&str>,
) -> anyhow::Result<()> {
    let hint = match &identity.serial {
        Some(s) => format!("--confirm {} --expect-serial '{s}'", identity.node),
        None => format!("--confirm {}", identity.node),
    };
    match confirm {
        None => bail!(
            "writing to a device requires explicit confirmation: re-run with {hint} \
             after checking the plan above (or use --dry-run to just see it)"
        ),
        Some(c) if c != identity.node => bail!(
            "--confirm {c:?} does not match the target device {} — refusing; to erase it, pass {hint}",
            identity.node
        ),
        Some(_) => {}
    }
    match (&identity.serial, expect_serial) {
        (Some(s), Some(e)) if s == e => Ok(()),
        (Some(s), Some(e)) => {
            bail!("--expect-serial {e:?} does not match the device's serial {s:?} — refusing")
        }
        (Some(_), None) => bail!("this device reports a serial number; confirm it too: {hint}"),
        (None, Some(e)) => {
            bail!("--expect-serial {e:?} given but the device reports no serial — refusing")
        }
        (None, None) => Ok(()),
    }
}

/// Open a device for writing with `O_EXCL`: the kernel refuses if it (or a partition) is
/// mounted or otherwise claimed, which closes the gap between [`assess`] and the write.
#[cfg(target_os = "linux")]
pub fn open_exclusive(node: &str) -> anyhow::Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt as _;
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_EXCL | libc::O_CLOEXEC)
        .open(node)
        .with_context(|| {
            format!("opening {node} exclusively (is it mounted or in use by another program?)")
        })
}

#[cfg(not(target_os = "linux"))]
pub fn open_exclusive(node: &str) -> anyhow::Result<fs::File> {
    bail!("writing to {node}: device writes are Linux-only in this release")
}

/// Drop cached pages for `file` so a read-back comes from the device, not memory.
pub fn drop_cache(file: &fs::File) {
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::io::AsRawFd as _;
        // SAFETY: advisory call on a valid fd; failure only means the cache stays.
        unsafe {
            libc::posix_fadvise(file.as_raw_fd(), 0, 0, libc::POSIX_FADV_DONTNEED);
        }
    }
    #[cfg(not(target_os = "linux"))]
    let _ = file;
}

/// A `--device` target after resolution and checks, ready for [`open_exclusive`].
#[derive(Debug, Clone, Serialize)]
pub struct DeviceTarget {
    pub resolved: Resolved,
    pub disk: DiskInfo,
    pub transport: Option<String>,
}

/// Resolve, gather facts and refuse on any safety problem.
pub fn prepare_device(given: &Path) -> anyhow::Result<DeviceTarget> {
    let resolved = resolve_device(given)?;
    let facts = LiveFacts::gather(&resolved)?;
    let refusals = facts.assess();
    if !refusals.is_empty() {
        bail!(
            "refusing to write to {}:\n  - {}",
            resolved.describe(),
            refusals.join("\n  - ")
        );
    }
    Ok(DeviceTarget {
        transport: facts.listed.as_ref().and_then(|b| b.transport.clone()),
        resolved,
        disk: facts.disk,
    })
}

/// Immediately before the first write: the device must still be what the plan showed.
pub fn recheck_identity(planned: &Identity, file: &mut fs::File) -> anyhow::Result<()> {
    use std::io::{Seek, SeekFrom};
    let now = read_disk_info(&planned.node)?.identity();
    if let Some(reason) = identity_changed(planned, &now) {
        bail!("{reason}");
    }
    let fd_size = file
        .seek(SeekFrom::End(0))
        .context("reading the device size")?;
    if fd_size != planned.size_bytes {
        bail!(
            "the open device reports {fd_size} bytes, the plan was for {} — nothing was written",
            planned.size_bytes
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::devices::parse_lsblk;

    const LSBLK: &str = r#"{"blockdevices":[
      {"name":"nvme0n1","path":"/dev/nvme0n1","size":1000204886016,"rm":false,"tran":"nvme","type":"disk","mountpoints":[null],"model":"SSD",
        "children":[{"name":"nvme0n1p2","path":"/dev/nvme0n1p2","size":999666221056,"rm":false,"tran":null,"type":"part","mountpoints":["/"],"model":null}]},
      {"name":"sdb","path":"/dev/sdb","size":61918000000,"rm":true,"tran":"usb","type":"disk","mountpoints":[null],"model":"Cruzer"},
      {"name":"vdb","path":"/dev/vdb","size":68719476736,"rm":false,"tran":"virtio","type":"disk","mountpoints":[null],"model":null},
      {"name":"zram0","path":"/dev/zram0","size":68719476736,"rm":false,"tran":null,"type":"disk","mountpoints":["[SWAP]"],"model":null}
    ]}"#;

    const MOUNTINFO: &str = "\
23 28 0:22 / /proc rw,relatime - proc proc rw
29 1 259:2 / / rw,relatime - ext4 /dev/nvme0n1p2 rw
40 29 8:17 / /media/u/CI\\040SHARED rw,relatime - exfat /dev/sdb1 rw
";

    fn sdb() -> DiskInfo {
        DiskInfo {
            name: "sdb".into(),
            node: "/dev/sdb".into(),
            devnum: DevNum {
                major: 8,
                minor: 16,
            },
            size_bytes: 61_918_000_000,
            removable: true,
            model: Some("Cruzer".into()),
            serial: Some("4C530001".into()),
            logical_sector: 512,
            partitions: vec![
                (
                    "sdb1".into(),
                    DevNum {
                        major: 8,
                        minor: 17,
                    },
                ),
                (
                    "sdb2".into(),
                    DevNum {
                        major: 8,
                        minor: 18,
                    },
                ),
            ],
            holders: vec![],
        }
    }

    fn run(disk: &DiskInfo, mounts: &str, swaps: &[DevNum]) -> Vec<String> {
        let listed = parse_lsblk(LSBLK).unwrap();
        let mounts = parse_mountinfo(mounts);
        assess(&SafetyFacts {
            disk,
            listed: listed.iter().find(|b| b.name == disk.name),
            mounts: &mounts,
            swap_devnums: swaps,
        })
    }

    #[test]
    fn parses_mountinfo_by_devnum_and_unescapes() {
        let m = parse_mountinfo(MOUNTINFO);
        assert_eq!(m.len(), 3);
        assert_eq!(
            m[2].devnum,
            DevNum {
                major: 8,
                minor: 17
            }
        );
        assert_eq!(m[2].mount_point, "/media/u/CI SHARED");
        assert_eq!(m[2].source, "/dev/sdb1");
        assert_eq!(
            parse_swaps("Filename Type Size Used Priority\n/dev/zram0 partition 1 0 100\n/swap\\040file file 1 0 -2\n"),
            ["/dev/zram0", "/swap file"]
        );
        assert_eq!(
            DevNum::from_dev_t(0x0811),
            DevNum {
                major: 8,
                minor: 17
            }
        );
        assert_eq!(
            DevNum::from_dev_t((259 << 8) | 2),
            DevNum {
                major: 259,
                minor: 2
            }
        );
    }

    #[test]
    fn removable_unmounted_is_ok() {
        let only_proc = "23 28 0:22 / /proc rw - proc proc rw\n";
        assert!(run(&sdb(), only_proc, &[]).is_empty());
    }

    #[test]
    fn mounted_partition_is_refused_by_devnum_not_name() {
        let r = run(&sdb(), MOUNTINFO, &[]);
        assert_eq!(r.len(), 1, "{r:?}");
        assert!(
            r[0].contains("sdb1 (8:17) is mounted at /media/u/CI SHARED"),
            "{r:?}"
        );
        // Same mount, but reported under a misleading source name: still refused.
        let tricky = "40 29 8:18 / /mnt rw - ext4 /dev/mapper/nothing-to-see rw\n";
        assert!(run(&sdb(), tricky, &[])[0].contains("sdb2"));
        // A mount whose *source name* looks like ours but is another device: not refused.
        let other = "40 29 8:33 / /mnt rw - ext4 /dev/sdb1 rw\n";
        assert!(run(&sdb(), other, &[]).is_empty());
    }

    #[test]
    fn system_and_non_removable_disks_are_refused() {
        let mut nvme = sdb();
        nvme.name = "nvme0n1".into();
        nvme.node = "/dev/nvme0n1".into();
        nvme.devnum = DevNum {
            major: 259,
            minor: 0,
        };
        nvme.partitions = vec![(
            "nvme0n1p2".into(),
            DevNum {
                major: 259,
                minor: 2,
            },
        )];
        let r = run(&nvme, MOUNTINFO, &[]);
        assert!(
            r.iter().any(|x| x.contains("holds the running system")),
            "{r:?}"
        );
        assert!(r.iter().any(|x| x.contains("mounted at /")), "{r:?}");

        let mut vdb = sdb();
        vdb.name = "vdb".into();
        vdb.node = "/dev/vdb".into();
        vdb.devnum = DevNum {
            major: 254,
            minor: 16,
        };
        vdb.partitions.clear();
        let r = run(&vdb, "", &[]);
        assert!(
            r[0].contains("not removable or USB-attached (transport virtio)"),
            "{r:?}"
        );

        let mut zram = vdb.clone();
        zram.name = "zram0".into();
        zram.node = "/dev/zram0".into();
        zram.devnum = DevNum {
            major: 253,
            minor: 0,
        };
        let r = run(&zram, "", &[zram.devnum]);
        assert!(r.iter().any(|x| x.contains("zram* device")), "{r:?}");
        assert!(r.iter().any(|x| x.contains("in use as swap")), "{r:?}");

        let mut unlisted = sdb();
        unlisted.name = "sdz".into();
        assert!(run(&unlisted, "", &[])[0].contains("not listed by lsblk"));
    }

    #[test]
    fn swap_holders_and_size_are_refused() {
        let r = run(
            &sdb(),
            "",
            &[DevNum {
                major: 8,
                minor: 18,
            }],
        );
        assert!(r[0].contains("sdb2 (8:18) is in use as swap"), "{r:?}");
        let mut held = sdb();
        held.holders = vec!["dm-3".into()];
        assert!(run(&held, "", &[])[0].contains("dm-3"));
        let mut small = sdb();
        small.size_bytes = 32_000_000_000;
        assert!(run(&small, "", &[])[0].contains("smaller than"));
    }

    #[test]
    fn identity_change_between_plan_and_write_is_refused() {
        let planned = sdb().identity();
        assert_eq!(identity_changed(&planned, &planned.clone()), None);
        let mut resized = planned.clone();
        resized.size_bytes -= 512;
        assert!(identity_changed(&planned, &resized)
            .unwrap()
            .contains("size"));
        let mut swapped = planned.clone();
        swapped.serial = Some("OTHER".into());
        swapped.devnum = DevNum {
            major: 8,
            minor: 32,
        };
        let why = identity_changed(&planned, &swapped).unwrap();
        assert!(
            why.contains("serial") && why.contains("major:minor"),
            "{why}"
        );
    }

    #[test]
    fn confirmation_must_match_what_was_shown() {
        let id = sdb().identity();
        assert!(check_confirmation(&id, None, None).is_err());
        let e = check_confirmation(&id, Some("/dev/sdc"), Some("4C530001")).unwrap_err();
        assert!(format!("{e}").contains("does not match"));
        let e = check_confirmation(&id, Some("/dev/sdb"), None).unwrap_err();
        assert!(format!("{e}").contains("--expect-serial '4C530001'"), "{e}");
        assert!(check_confirmation(&id, Some("/dev/sdb"), Some("nope")).is_err());
        check_confirmation(&id, Some("/dev/sdb"), Some("4C530001")).unwrap();
        let mut no_serial = id.clone();
        no_serial.serial = None;
        check_confirmation(&no_serial, Some("/dev/sdb"), None).unwrap();
    }

    #[test]
    fn by_id_symlink_resolution_is_shown() {
        let r = Resolved {
            given: "/dev/disk/by-id/usb-SanDisk_Cruzer_4C530001-0:0".into(),
            node: "/dev/sdb".into(),
        };
        assert!(r.via_symlink());
        assert_eq!(
            r.describe(),
            "/dev/disk/by-id/usb-SanDisk_Cruzer_4C530001-0:0 -> /dev/sdb (symlink resolved)"
        );
        #[cfg(unix)]
        {
            // A symlink to a regular file resolves, then is refused as not a block device.
            let dir = tempfile::tempdir().unwrap();
            let file = dir.path().join("disk.img");
            std::fs::write(&file, b"x").unwrap();
            let link = dir.path().join("by-id-link");
            std::os::unix::fs::symlink(&file, &link).unwrap();
            let e = resolve_device(&link).unwrap_err();
            assert!(format!("{e}").contains("not a block device"), "{e}");
            // --image never follows symlinks.
            assert!(check_image_path(&link).is_err());
            assert!(check_image_path(&file).is_ok());
            assert!(check_image_path(&dir.path().join("new.img")).is_ok());
            assert!(check_image_path(dir.path()).is_err());
        }
    }
}
