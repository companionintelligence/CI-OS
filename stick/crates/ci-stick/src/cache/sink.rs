//! Where downloaded bytes go: the [`BlobSink`] seam.
//!
//! The download engine never touches a `File` directly. It appends to a [`BlobSink`] opened
//! by a [`SinkFactory`], which lets tests inject a full disk (`ENOSPC`) after exactly N bytes
//! and assert that the partial and its journal stay consistent.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::Path;

/// The writable half of a resumable download.
pub trait BlobSink: Send {
    /// Current length of the data in bytes.
    fn size(&mut self) -> io::Result<u64>;
    /// Cut the data back to `len` bytes; the next append continues from there.
    fn truncate(&mut self, len: u64) -> io::Result<()>;
    /// Hand the first `len` bytes to `f` in chunks (re-verification of a resumed prefix).
    fn read_prefix(&mut self, len: u64, f: &mut dyn FnMut(&[u8])) -> io::Result<()>;
    /// Append at the end.
    fn append(&mut self, data: &[u8]) -> io::Result<()>;
    /// Make everything appended so far durable (`sync_data`).
    fn sync(&mut self) -> io::Result<()>;
}

/// Opens (creating if needed) the partial file at a path.
pub trait SinkFactory: Send + Sync {
    fn open(&self, partial: &Path) -> io::Result<Box<dyn BlobSink>>;
}

/// The real thing: a plain file.
#[derive(Debug, Default, Clone, Copy)]
pub struct FileSinkFactory;

impl SinkFactory for FileSinkFactory {
    fn open(&self, partial: &Path) -> io::Result<Box<dyn BlobSink>> {
        if let Some(parent) = partial.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(partial)?;
        file.seek(SeekFrom::End(0))?;
        Ok(Box::new(FileSink { file }))
    }
}

pub struct FileSink {
    file: File,
}

impl BlobSink for FileSink {
    fn size(&mut self) -> io::Result<u64> {
        Ok(self.file.metadata()?.len())
    }

    fn truncate(&mut self, len: u64) -> io::Result<()> {
        self.file.set_len(len)?;
        self.file.seek(SeekFrom::Start(len))?;
        Ok(())
    }

    fn read_prefix(&mut self, len: u64, f: &mut dyn FnMut(&[u8])) -> io::Result<()> {
        self.file.seek(SeekFrom::Start(0))?;
        let mut buf = vec![0u8; 1 << 20];
        let mut left = len;
        while left > 0 {
            let want = usize::try_from(left.min(buf.len() as u64)).unwrap_or(buf.len());
            match self.file.read(&mut buf[..want]) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "partial file is shorter than its journal claims",
                    ))
                }
                Ok(n) => {
                    f(&buf[..n]);
                    left -= n as u64;
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        self.file.seek(SeekFrom::End(0))?;
        Ok(())
    }

    fn append(&mut self, data: &[u8]) -> io::Result<()> {
        self.file.write_all(data)
    }

    fn sync(&mut self) -> io::Result<()> {
        self.file.sync_data()
    }
}

/// `true` for "no space left on device" and "quota exceeded".
///
/// (`io::ErrorKind::StorageFull` is newer than this crate's MSRV, so the raw OS code is used.)
pub fn is_no_space(e: &io::Error) -> bool {
    match e.raw_os_error() {
        #[cfg(unix)]
        Some(code) => code == 28 /* ENOSPC */ || code == 122 /* EDQUOT on Linux */ || code == 69, /* EDQUOT on macOS */
        #[cfg(windows)]
        Some(code) => {
            code == 112 /* ERROR_DISK_FULL */ || code == 39 /* ERROR_HANDLE_DISK_FULL */ || code == 1450
        }
        #[cfg(not(any(unix, windows)))]
        Some(_) => false,
        None => false,
    }
}

/// An "out of space" error carrying the OS code of this platform.
pub fn no_space_error() -> io::Error {
    #[cfg(windows)]
    {
        io::Error::from_raw_os_error(112)
    }
    #[cfg(not(windows))]
    {
        io::Error::from_raw_os_error(28)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn append_truncate_and_read_back() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("x-partial");
        let mut s = FileSinkFactory.open(&p).unwrap();
        assert_eq!(s.size().unwrap(), 0);
        s.append(b"hello ").unwrap();
        s.append(b"world").unwrap();
        s.sync().unwrap();
        assert_eq!(s.size().unwrap(), 11);
        let mut got = Vec::new();
        s.read_prefix(11, &mut |c| got.extend_from_slice(c))
            .unwrap();
        assert_eq!(got, b"hello world");
        s.truncate(5).unwrap();
        s.append(b"!").unwrap();
        assert_eq!(std::fs::read(&p).unwrap(), b"hello!");
        // reopening continues at the end, as a resumed download does
        drop(s);
        let mut s = FileSinkFactory.open(&p).unwrap();
        s.append(b"?").unwrap();
        assert_eq!(std::fs::read(&p).unwrap(), b"hello!?");
        let mut got = Vec::new();
        let err = s
            .read_prefix(100, &mut |c| got.extend_from_slice(c))
            .unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);
    }

    #[test]
    fn recognises_a_full_disk() {
        assert!(is_no_space(&no_space_error()));
        assert!(!is_no_space(&io::Error::other("x")));
        assert!(!is_no_space(&io::Error::from(
            io::ErrorKind::PermissionDenied
        )));
    }
}
