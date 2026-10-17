//! Reading and writing the content-addressed store. Everything here is crash-safe in the
//! sense that a file under its final name is always complete: data is written under a
//! temporary name, `fsync`'d, and renamed into place.
//!
//! No symlink is ever created or followed: `blob_len` uses `symlink_metadata` and counts
//! only regular files, because exFAT has no symlinks and a cache copied from ext4 might.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use sha2::{Digest as _, Sha256};

use crate::cache::layout::{CacheLayout, LayoutError, VERSION_CONTENT};

static TMP_COUNTER: AtomicU64 = AtomicU64::new(0);
static FSYNC_ENABLED: AtomicBool = AtomicBool::new(true);

/// Turn the `fsync` calls of [`write_atomic`] and of the store's renames off or on.
///
/// For tests only: a property test that creates hundreds of caches would otherwise spend its
/// time in `fcntl(F_FULLFSYNC)`. The `ci-stick` binary never calls this, so every file it
/// publishes is synced before its rename.
#[doc(hidden)]
pub fn set_fsync_enabled(on: bool) {
    FSYNC_ENABLED.store(on, Ordering::Relaxed);
}

fn fsync_enabled() -> bool {
    FSYNC_ENABLED.load(Ordering::Relaxed)
}

fn tmp_name(stem: &str) -> String {
    format!(
        ".{stem}.tmp-{}-{}",
        std::process::id(),
        TMP_COUNTER.fetch_add(1, Ordering::Relaxed)
    )
}

/// Best effort: make a rename durable. Directories cannot be opened on Windows.
fn sync_dir(dir: &Path) {
    if !fsync_enabled() {
        return;
    }
    #[cfg(unix)]
    if let Ok(d) = fs::File::open(dir) {
        let _ = d.sync_all();
    }
    #[cfg(not(unix))]
    let _ = dir;
}

fn write_via(tmp_dir: &Path, path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no parent"))?;
    fs::create_dir_all(parent)?;
    fs::create_dir_all(tmp_dir)?;
    let stem = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("file")
        .chars()
        .take(40)
        .collect::<String>();
    let tmp = tmp_dir.join(tmp_name(&stem));
    let result = (|| {
        let mut f = OpenOptions::new().write(true).create_new(true).open(&tmp)?;
        f.write_all(bytes)?;
        if fsync_enabled() {
            f.sync_all()?;
        }
        drop(f);
        fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    } else {
        sync_dir(parent);
    }
    result
}

/// Atomically replace `path` with `bytes` (temporary file next to it, `fsync`, rename).
pub fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no parent"))?;
    write_via(parent, path, bytes)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ManifestState {
    Missing,
    /// Present with exactly the expected bytes.
    Matches,
    /// Present but different (a different tag revision, or damaged).
    Differs,
}

#[derive(Debug, Clone)]
pub struct Store {
    layout: CacheLayout,
}

impl Store {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            layout: CacheLayout::new(root),
        }
    }

    pub fn layout(&self) -> &CacheLayout {
        &self.layout
    }

    /// Create the directories a seeded store needs, including the EMPTY `manifests-v2/`
    /// (a read-only stick must already have it: Ollama `MkdirAll`s it on every access).
    pub fn ensure_layout(&self) -> io::Result<()> {
        for d in [
            self.layout.blobs_dir(),
            self.layout.manifests_dir(),
            self.layout.manifests_v2_dir(),
            self.layout.partial_dir(),
        ] {
            fs::create_dir_all(d)?;
        }
        let version = self.layout.version_file();
        if !version.exists() {
            write_atomic(&version, VERSION_CONTENT.as_bytes())?;
        }
        Ok(())
    }

    /// Size of the blob if it is present as a regular file.
    pub fn blob_len(&self, hex: &str) -> io::Result<Option<u64>> {
        let path = self.layout.blob_path(hex).map_err(layout_err)?;
        match fs::symlink_metadata(&path) {
            Ok(m) if m.is_file() => Ok(Some(m.len())),
            Ok(_) => Ok(None),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Is the blob present with exactly the expected size?
    pub fn has_blob(&self, hex: &str, size: u64) -> bool {
        matches!(self.blob_len(hex), Ok(Some(n)) if n == size)
    }

    /// Move a finished, verified partial into `models/blobs/`.
    pub fn commit_blob(&self, partial: &Path, hex: &str) -> io::Result<()> {
        let dest = self.layout.blob_path(hex).map_err(layout_err)?;
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::rename(partial, &dest)?;
        sync_dir(dest.parent().unwrap_or(Path::new(".")));
        Ok(())
    }

    /// Write a small blob whose content the caller has already verified against `hex`.
    pub fn write_blob_bytes(&self, hex: &str, bytes: &[u8]) -> io::Result<()> {
        let dest = self.layout.blob_path(hex).map_err(layout_err)?;
        write_via(&self.layout.partial_dir(), &dest, bytes)
    }

    fn manifest_file(&self, components: &[&str]) -> io::Result<PathBuf> {
        self.layout.manifest_path(components).map_err(layout_err)
    }

    /// Compare the stored manifest with the expected SHA-256.
    pub fn manifest_state(
        &self,
        components: &[&str],
        expect_sha256: &str,
    ) -> io::Result<ManifestState> {
        let path = self.manifest_file(components)?;
        match fs::symlink_metadata(&path) {
            Ok(m) if m.is_file() && m.len() <= (1 << 20) => {
                let bytes = fs::read(&path)?;
                if hex::encode(Sha256::digest(&bytes)) == expect_sha256 {
                    Ok(ManifestState::Matches)
                } else {
                    Ok(ManifestState::Differs)
                }
            }
            Ok(_) => Ok(ManifestState::Differs),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(ManifestState::Missing),
            Err(e) => Err(e),
        }
    }

    /// Write the registry's manifest bytes verbatim, atomically. Call only after every blob
    /// of the model is in place: a daemon scanning the store must never see a manifest whose
    /// blobs are missing.
    pub fn write_manifest(&self, components: &[&str], bytes: &[u8]) -> io::Result<()> {
        let path = self.manifest_file(components)?;
        write_via(&self.layout.partial_dir(), &path, bytes)
    }
}

fn layout_err(e: LayoutError) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEX: &str = "970aa74c0a90ef7482477cf803618e776e173c007bf957f635f1015bfcfef0e6";

    #[test]
    fn layout_is_created_with_an_empty_manifests_v2() {
        let dir = tempfile::tempdir().unwrap();
        let s = Store::new(dir.path());
        s.ensure_layout().unwrap();
        s.ensure_layout().unwrap(); // idempotent
        let v2 = s.layout().manifests_v2_dir();
        assert!(v2.is_dir());
        assert_eq!(
            fs::read_dir(&v2).unwrap().count(),
            0,
            "manifests-v2 must stay empty"
        );
        assert!(s.layout().blobs_dir().is_dir());
        assert_eq!(
            fs::read_to_string(s.layout().version_file()).unwrap(),
            VERSION_CONTENT
        );
    }

    #[test]
    fn blobs_commit_by_rename_and_count_only_regular_files() {
        let dir = tempfile::tempdir().unwrap();
        let s = Store::new(dir.path());
        s.ensure_layout().unwrap();
        assert_eq!(s.blob_len(HEX).unwrap(), None);
        let part = s.layout().partial_path(HEX).unwrap();
        fs::write(&part, b"12345").unwrap();
        s.commit_blob(&part, HEX).unwrap();
        assert!(!part.exists());
        assert_eq!(s.blob_len(HEX).unwrap(), Some(5));
        assert!(s.has_blob(HEX, 5));
        assert!(!s.has_blob(HEX, 6));
        // a directory under the blob name is not a blob
        let other = "a".repeat(64);
        fs::create_dir(s.layout().blob_path(&other).unwrap()).unwrap();
        assert_eq!(s.blob_len(&other).unwrap(), None);
        assert!(s.blob_len("../x").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_are_never_followed() {
        let dir = tempfile::tempdir().unwrap();
        let s = Store::new(dir.path());
        s.ensure_layout().unwrap();
        let target = dir.path().join("elsewhere");
        fs::write(&target, b"abcdef").unwrap();
        std::os::unix::fs::symlink(&target, s.layout().blob_path(HEX).unwrap()).unwrap();
        assert_eq!(
            s.blob_len(HEX).unwrap(),
            None,
            "a symlink is not a present blob"
        );
    }

    #[test]
    fn manifests_are_written_verbatim_and_compared_by_hash() {
        let dir = tempfile::tempdir().unwrap();
        let s = Store::new(dir.path());
        s.ensure_layout().unwrap();
        let comps = ["registry.ollama.ai", "library", "gemma3", "1b"];
        let body = b"{\"schemaVersion\":2}";
        let sha = hex::encode(Sha256::digest(body));
        assert_eq!(
            s.manifest_state(&comps, &sha).unwrap(),
            ManifestState::Missing
        );
        s.write_manifest(&comps, body).unwrap();
        assert_eq!(
            s.manifest_state(&comps, &sha).unwrap(),
            ManifestState::Matches
        );
        assert_eq!(
            fs::read(
                dir.path()
                    .join("models/manifests/registry.ollama.ai/library/gemma3/1b")
            )
            .unwrap(),
            body
        );
        s.write_manifest(&comps, b"changed").unwrap();
        assert_eq!(
            s.manifest_state(&comps, &sha).unwrap(),
            ManifestState::Differs
        );
        assert!(s.write_manifest(&["..", "x"], b"x").is_err());
        // no temporary files are left inside models/
        for e in walk(&dir.path().join("models")) {
            assert!(!e.to_string_lossy().contains(".tmp-"), "{e:?}");
        }
    }

    fn walk(p: &Path) -> Vec<PathBuf> {
        let mut out = Vec::new();
        if let Ok(rd) = fs::read_dir(p) {
            for e in rd.flatten() {
                out.push(e.path());
                if e.path().is_dir() {
                    out.extend(walk(&e.path()));
                }
            }
        }
        out
    }

    #[test]
    fn atomic_write_replaces_and_cleans_up() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("sub").join("status.json");
        write_atomic(&p, b"one").unwrap();
        write_atomic(&p, b"two").unwrap();
        assert_eq!(fs::read(&p).unwrap(), b"two");
        let names: Vec<_> = fs::read_dir(p.parent().unwrap())
            .unwrap()
            .flatten()
            .collect();
        assert_eq!(names.len(), 1, "no temp file left behind");
    }
}
