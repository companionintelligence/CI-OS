//! Sparse copy of a filesystem image into a target at an offset.
//!
//! `flash` builds each filesystem in a sparse temporary file (so a 300 GiB exFAT cache
//! costs a few MiB), then copies only the *data extents* into the stick at the partition
//! offset. Holes are skipped. That is safe on a device with old contents because the
//! filesystems are created by `mkfs` tools that do not discard (`mkfs.ext4` is run with
//! `-E nodiscard`): anything a filesystem relies on being zero, `mkfs` wrote explicitly,
//! so it is data here, not a hole.
//!
//! Extents come from `lseek(SEEK_DATA/SEEK_HOLE)` on Linux; where that is unavailable the
//! whole file is treated as data. In addition, when the destination is known to read as
//! zero (a freshly created image file), all-zero blocks inside data extents are skipped
//! too, which keeps the image sparse. On a device every data byte is written.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};

use anyhow::Context as _;

const BUF: usize = 1 << 20;

/// A `[start, end)` byte range of data in the source.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Extent {
    pub start: u64,
    pub end: u64,
}

/// Data extents of `file` (all of it when the platform cannot tell).
pub fn data_extents(file: &File) -> io::Result<Vec<Extent>> {
    let len = file.metadata()?.len();
    #[cfg(target_os = "linux")]
    {
        if let Some(extents) = linux::extents(file, len)? {
            return Ok(extents);
        }
    }
    Ok(if len == 0 {
        Vec::new()
    } else {
        vec![Extent { start: 0, end: len }]
    })
}

#[cfg(target_os = "linux")]
mod linux {
    use super::Extent;
    use std::fs::File;
    use std::io;
    use std::os::unix::io::AsRawFd;

    /// `None` when the filesystem does not support SEEK_DATA.
    pub fn extents(file: &File, len: u64) -> io::Result<Option<Vec<Extent>>> {
        let fd = file.as_raw_fd();
        let mut out = Vec::new();
        let mut pos: u64 = 0;
        while pos < len {
            // SAFETY: lseek on a valid fd owned by `file` for the duration of the call.
            let data = unsafe { libc::lseek(fd, pos as libc::off_t, libc::SEEK_DATA) };
            if data < 0 {
                let err = io::Error::last_os_error();
                return match err.raw_os_error() {
                    Some(libc::ENXIO) => Ok(Some(out)), // no more data
                    Some(libc::EINVAL) | Some(libc::EOPNOTSUPP) if out.is_empty() && pos == 0 => {
                        Ok(None)
                    }
                    _ => Err(err),
                };
            }
            // SAFETY: as above.
            let hole = unsafe { libc::lseek(fd, data, libc::SEEK_HOLE) };
            if hole < 0 {
                return Err(io::Error::last_os_error());
            }
            let (data, hole) = (data as u64, (hole as u64).min(len));
            if hole > data {
                out.push(Extent {
                    start: data,
                    end: hole,
                });
            }
            pos = hole.max(data + 1);
        }
        Ok(Some(out))
    }
}

/// Totals from a copy.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CopyStats {
    pub bytes_written: u64,
    pub extents: usize,
}

/// Write `src`'s data extents into `dst` at `dst_offset`. `dst_known_zero` allows zero
/// blocks to be skipped (see the module docs).
pub fn copy_sparse(
    src: &mut File,
    dst: &mut File,
    dst_offset: u64,
    dst_known_zero: bool,
    mut on_progress: impl FnMut(u64),
) -> anyhow::Result<CopyStats> {
    let extents = data_extents(src).context("finding data extents")?;
    let skip_zero = dst_known_zero;
    let mut stats = CopyStats::default();
    let mut buf = vec![0u8; BUF];
    for ext in &extents {
        stats.extents += 1;
        let mut pos = ext.start;
        src.seek(SeekFrom::Start(pos))?;
        while pos < ext.end {
            let n = ((ext.end - pos) as usize).min(BUF);
            src.read_exact(&mut buf[..n])
                .with_context(|| format!("reading source at {pos}"))?;
            if !(skip_zero && buf[..n].iter().all(|&b| b == 0)) {
                dst.seek(SeekFrom::Start(dst_offset + pos))?;
                write_all(dst, &buf[..n]).with_context(|| {
                    format!("writing {n} bytes at target offset {}", dst_offset + pos)
                })?;
                stats.bytes_written += n as u64;
                on_progress(stats.bytes_written);
            }
            pos += n as u64;
        }
    }
    Ok(stats)
}

fn write_all(dst: &mut File, data: &[u8]) -> io::Result<()> {
    use std::io::Write as _;
    dst.write_all(data)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    /// Fixture: 8 MiB sparse file with data at 1 MiB and at 5 MiB + 100.
    fn fixture(dir: &std::path::Path) -> File {
        let path = dir.join("src.img");
        let mut f = File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)
            .unwrap();
        f.set_len(8 << 20).unwrap();
        f.seek(SeekFrom::Start(1 << 20)).unwrap();
        f.write_all(&[0xAA; 4096]).unwrap();
        f.seek(SeekFrom::Start((5 << 20) + 100)).unwrap();
        f.write_all(b"hello").unwrap();
        f.sync_all().unwrap();
        f
    }

    #[test]
    fn copies_data_at_offset_and_preserves_holes() {
        let dir = tempfile::tempdir().unwrap();
        let mut src = fixture(dir.path());
        let exts = data_extents(&src).unwrap();
        assert!(!exts.is_empty());
        // Extents cover the data we wrote, in order, within the file.
        assert!(exts.windows(2).all(|w| w[0].end <= w[1].start));
        assert!(exts
            .iter()
            .any(|e| e.start <= 1 << 20 && e.end >= (1 << 20) + 4096));

        let mut dst = File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(dir.path().join("dst.img"))
            .unwrap();
        let offset = 3 << 20;
        dst.set_len(offset + (8 << 20) + (1 << 20)).unwrap();
        // Pre-existing junk inside the target region that a hole must NOT overwrite
        // (holes are "don't care" regions), and a canary after the copy region.
        dst.seek(SeekFrom::Start(offset + (3 << 20))).unwrap();
        dst.write_all(b"junk").unwrap();
        let stats = copy_sparse(&mut src, &mut dst, offset, true, |_| {}).unwrap();
        assert!(stats.bytes_written >= 4096 + 5);

        let mut all = Vec::new();
        dst.seek(SeekFrom::Start(0)).unwrap();
        dst.read_to_end(&mut all).unwrap();
        let o = offset as usize;
        assert!(
            all[..o].iter().all(|&b| b == 0),
            "nothing before the offset"
        );
        assert_eq!(&all[o + (1 << 20)..o + (1 << 20) + 4096], &[0xAA; 4096][..]);
        assert_eq!(&all[o + (5 << 20) + 100..o + (5 << 20) + 105], b"hello");

        #[cfg(target_os = "linux")]
        {
            // On filesystems with SEEK_DATA the copy is sparse: only data extents written.
            if exts.len() > 1 {
                assert!(stats.bytes_written < 8 << 20, "{stats:?}");
                assert_eq!(&all[o + (3 << 20)..o + (3 << 20) + 4], b"junk");
            }
        }
    }

    #[test]
    fn device_targets_get_explicit_zeros_written() {
        // mkfs writes zeros it relies on (e.g. an empty bitmap). Those are data, and on a
        // device with old contents they must be written, not skipped.
        let dir = tempfile::tempdir().unwrap();
        let mut src = fixture(dir.path());
        src.seek(SeekFrom::Start(2 << 20)).unwrap();
        src.write_all(&[0u8; 8192]).unwrap();
        src.sync_all().unwrap();
        let mut dst = File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(dir.path().join("dev.img"))
            .unwrap();
        dst.write_all(&vec![0xEE; 8 << 20]).unwrap(); // "old stick contents"
        let as_device = copy_sparse(&mut src, &mut dst, 0, false, |_| {}).unwrap();
        let mut got = vec![0u8; 8192];
        dst.seek(SeekFrom::Start(2 << 20)).unwrap();
        dst.read_exact(&mut got).unwrap();
        assert!(
            got.iter().all(|&b| b == 0),
            "explicit zeros must reach a device"
        );

        // Into a fresh (zero) image, zero blocks may be skipped: fewer bytes written.
        let mut img = File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(dir.path().join("fresh.img"))
            .unwrap();
        img.set_len(8 << 20).unwrap();
        let as_image = copy_sparse(&mut src, &mut img, 0, true, |_| {}).unwrap();
        assert!(as_image.bytes_written < as_device.bytes_written);
    }

    #[test]
    fn empty_source_writes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        File::create(dir.path().join("e")).unwrap();
        let mut src = File::open(dir.path().join("e")).unwrap();
        let mut dst = File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(dir.path().join("d"))
            .unwrap();
        let stats = copy_sparse(&mut src, &mut dst, 0, true, |_| {}).unwrap();
        assert_eq!(stats.bytes_written, 0);
    }
}
