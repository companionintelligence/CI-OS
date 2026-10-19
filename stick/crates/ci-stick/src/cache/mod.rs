//! The model cache on the stick's `CI-CACHE` partition (exFAT) or any directory.
//!
//! * [`layout`]: paths and file-name rules (pure)
//! * [`store`]: crash-safe reads and writes of blobs and manifests
//! * [`partial`]: the resume journal
//! * [`sink`]: the `BlobSink` seam between the downloader and the disk
//! * this module: file system facts (free space, type) and the `cache-info` scan

pub mod layout;
pub mod partial;
pub mod sink;
pub mod store;

use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::cache::layout::{is_junk_name, parse_blob_file_name, CacheLayout};

/// Facts about the file system holding a path. Any field may be unknown.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct FsStats {
    /// Capacity in bytes.
    pub total_bytes: Option<u64>,
    /// Bytes available to an unprivileged writer.
    pub free_bytes: Option<u64>,
    pub read_only: Option<bool>,
    /// `exfat`, `ext4`, `tmpfs`, ... (Linux only).
    pub fs_type: Option<String>,
    /// tmpfs/ramfs: writing a model here consumes RAM, not storage.
    pub ram_backed: Option<bool>,
}

/// The nearest existing ancestor of `path` (the path itself when it exists).
fn existing_ancestor(path: &Path) -> Option<PathBuf> {
    path.ancestors()
        .find(|p| !p.as_os_str().is_empty() && p.exists())
        .map(Path::to_path_buf)
}

/// Free-space and file-system facts for `path` (or its nearest existing ancestor).
///
/// Unix only (`statvfs`, without `unsafe`); on other platforms every field is `None` and
/// callers fall back to handling `ENOSPC` when it happens.
pub fn fs_stats(path: &Path) -> FsStats {
    let Some(anchor) = existing_ancestor(path) else {
        return FsStats::default();
    };
    stats_for(&anchor)
}

#[cfg(unix)]
fn stats_for(anchor: &Path) -> FsStats {
    let mut stats = FsStats::default();
    if let Ok(v) = rustix::fs::statvfs(anchor) {
        let frsize = if v.f_frsize > 0 {
            v.f_frsize
        } else {
            v.f_bsize
        };
        stats.total_bytes = Some(v.f_blocks.saturating_mul(frsize));
        stats.free_bytes = Some(v.f_bavail.saturating_mul(frsize));
        stats.read_only = Some(v.f_flag.contains(rustix::fs::StatVfsMountFlags::RDONLY));
    }
    stats.fs_type = linux_fs_type(anchor);
    stats.ram_backed = stats
        .fs_type
        .as_deref()
        .map(|t| matches!(t, "tmpfs" | "ramfs"));
    stats
}

#[cfg(not(unix))]
fn stats_for(_anchor: &Path) -> FsStats {
    FsStats::default()
}

/// The file system type of the mount holding `path`, from `/proc/self/mountinfo`.
#[cfg(unix)]
fn linux_fs_type(path: &Path) -> Option<String> {
    let canon = fs::canonicalize(path).ok()?;
    let info = fs::read_to_string("/proc/self/mountinfo").ok()?;
    parse_mountinfo_type(&info, &canon)
}

/// Pure half of [`linux_fs_type`]: the type of the longest mount point containing `path`.
pub fn parse_mountinfo_type(mountinfo: &str, path: &Path) -> Option<String> {
    let mut best: Option<(usize, String)> = None;
    for line in mountinfo.lines() {
        let (left, right) = line.split_once(" - ")?;
        let fields: Vec<&str> = left.split(' ').collect();
        let mount_point = unescape_mountinfo(fields.get(4)?);
        let fs_type = right.split(' ').next()?.to_string();
        let mp = Path::new(&mount_point);
        if path.starts_with(mp) {
            let depth = mp.components().count();
            if best.as_ref().map_or(true, |(d, _)| depth >= *d) {
                best = Some((depth, fs_type));
            }
        }
    }
    best.map(|(_, t)| t)
}

/// `\040` style octal escapes in mountinfo paths.
fn unescape_mountinfo(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\'
            && i + 3 < b.len()
            && b[i + 1..i + 4].iter().all(|c| (b'0'..=b'7').contains(c))
        {
            let v = u32::from(b[i + 1] - b'0') * 64
                + u32::from(b[i + 2] - b'0') * 8
                + u32::from(b[i + 3] - b'0');
            if let Ok(byte) = u8::try_from(v) {
                out.push(byte);
                i += 4;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// What is in a cache directory (counts only; junk files are counted apart and ignored).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct CacheScan {
    pub blobs: usize,
    pub blob_bytes: u64,
    /// Files in `models/blobs` that are not `sha256-<hex>` (stray or foreign partials).
    pub foreign_blob_files: usize,
    pub manifests: usize,
    pub partials: usize,
    /// Bytes the journals claim as committed.
    pub partial_committed_bytes: u64,
    /// AppleDouble, `.DS_Store`, Spotlight and friends.
    pub junk_files: usize,
}

/// Scan a cache directory. Missing directories count as empty.
pub fn scan(layout: &CacheLayout) -> CacheScan {
    let mut s = CacheScan::default();
    if let Ok(rd) = fs::read_dir(layout.blobs_dir()) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if is_junk_name(&name) {
                s.junk_files += 1;
                continue;
            }
            let Ok(meta) = fs::symlink_metadata(e.path()) else {
                continue;
            };
            if !meta.is_file() {
                continue;
            }
            if parse_blob_file_name(&name).is_some() {
                s.blobs += 1;
                s.blob_bytes += meta.len();
            } else {
                s.foreign_blob_files += 1;
            }
        }
    }
    s.manifests = count_files(&layout.manifests_dir(), &mut s.junk_files);
    if let Ok(rd) = fs::read_dir(layout.partial_dir()) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if is_junk_name(&name) {
                s.junk_files += 1;
                continue;
            }
            if let Some(hex) = name.strip_suffix("-partial.journal") {
                if crate::hashing::is_sha256_hex(hex) {
                    s.partials += 1;
                    if let Some(j) = partial::read_journal(&e.path()) {
                        s.partial_committed_bytes += j.committed;
                    }
                }
            }
        }
    }
    s
}

fn count_files(dir: &Path, junk: &mut usize) -> usize {
    let mut n = 0;
    let Ok(rd) = fs::read_dir(dir) else { return 0 };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if is_junk_name(&name) {
            *junk += 1;
            continue;
        }
        let Ok(meta) = fs::symlink_metadata(e.path()) else {
            continue;
        };
        if meta.is_dir() {
            n += count_files(&e.path(), junk);
        } else if meta.is_file() {
            n += 1;
        }
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;

    const MOUNTINFO: &str = "\
22 1 8:2 / / rw,relatime shared:1 - ext4 /dev/sda2 rw
30 22 0:25 / /tmp rw,nosuid shared:5 - tmpfs tmpfs rw
41 22 8:17 / /media/liam/CI-CACHE rw,nosuid,nodev,noexec,relatime shared:9 - exfat /dev/sdb2 rw,uid=1000
42 22 8:18 / /media/liam/My\\040Stick rw shared:10 - vfat /dev/sdc1 rw
";

    #[test]
    fn mountinfo_picks_the_longest_mount() {
        let t = |p: &str| parse_mountinfo_type(MOUNTINFO, Path::new(p));
        assert_eq!(
            t("/media/liam/CI-CACHE/models/blobs").as_deref(),
            Some("exfat")
        );
        assert_eq!(t("/media/liam/My Stick/x").as_deref(), Some("vfat"));
        assert_eq!(t("/tmp/x").as_deref(), Some("tmpfs"));
        assert_eq!(t("/home/liam").as_deref(), Some("ext4"));
        assert_eq!(parse_mountinfo_type("garbage", Path::new("/x")), None);
    }

    #[cfg(unix)]
    #[test]
    fn free_space_of_a_temp_dir_is_known() {
        let dir = tempfile::tempdir().unwrap();
        let st = fs_stats(&dir.path().join("not/yet/created"));
        assert!(st.total_bytes.unwrap() >= st.free_bytes.unwrap());
        assert!(st.free_bytes.unwrap() > 0);
        assert_eq!(st.read_only, Some(false));
    }

    #[test]
    fn scan_ignores_junk_and_counts_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let s = store::Store::new(dir.path());
        s.ensure_layout().unwrap();
        let hex = "a".repeat(64);
        fs::write(s.layout().blob_path(&hex).unwrap(), b"12345").unwrap();
        fs::write(s.layout().blobs_dir().join(format!("._sha256-{hex}")), b"x").unwrap();
        fs::write(s.layout().blobs_dir().join(".DS_Store"), b"x").unwrap();
        fs::write(
            s.layout().blobs_dir().join(format!("sha256-{hex}-partial")),
            b"x",
        )
        .unwrap();
        s.write_manifest(&["registry.ollama.ai", "library", "m", "latest"], b"{}")
            .unwrap();
        let j = partial::Journal::new(&"b".repeat(64), 100, 40, "http://x/y");
        partial::write_journal(&s.layout().journal_path(&"b".repeat(64)).unwrap(), &j).unwrap();
        let sc = scan(s.layout());
        assert_eq!(sc.blobs, 1);
        assert_eq!(sc.blob_bytes, 5);
        assert_eq!(sc.foreign_blob_files, 1);
        assert_eq!(sc.junk_files, 2);
        assert_eq!(sc.manifests, 1);
        assert_eq!(sc.partials, 1);
        assert_eq!(sc.partial_committed_bytes, 40);
    }
}
