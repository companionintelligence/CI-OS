//! The journal that makes a partial download resumable.
//!
//! A partial is `<hex>-partial` (data) plus `<hex>-partial.journal` (JSON). The journal is
//! written only after the data it covers was `fsync`'d, so it never claims bytes that a
//! power cut could have lost; the data file may be longer than the journal says (bytes written
//! since the last sync) and is cut back on resume. On resume the claimed prefix is read back
//! from disk and re-hashed, so a bad prefix is caught by the final SHA-256 even if the
//! storage lied.

use std::io;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::cache::store::write_atomic;

pub const JOURNAL_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Journal {
    pub v: u32,
    /// Expected SHA-256 (lowercase hex) of the finished blob.
    pub sha256: String,
    /// Expected size of the finished blob.
    pub size: u64,
    /// Bytes of the data file that are durable and verified-in-order.
    pub committed: u64,
    /// Where the bytes come from, with the query string removed (never a presigned URL).
    pub source: String,
    pub tool: String,
}

impl Journal {
    pub fn new(sha256: &str, size: u64, committed: u64, source: &str) -> Self {
        Self {
            v: JOURNAL_VERSION,
            sha256: sha256.to_string(),
            size,
            committed,
            source: source.to_string(),
            tool: concat!("ci-stick ", env!("CARGO_PKG_VERSION")).to_string(),
        }
    }

    /// `true` if this journal describes a download of exactly this blob.
    pub fn matches(&self, sha256: &str, size: u64) -> bool {
        self.v == JOURNAL_VERSION
            && self.sha256 == sha256
            && self.size == size
            && self.committed <= size
    }
}

/// Read a journal; `None` if it is missing, unreadable or malformed (all mean "start over").
pub fn read_journal(path: &Path) -> Option<Journal> {
    let bytes = std::fs::read(path).ok()?;
    if bytes.len() > 16 * 1024 {
        return None;
    }
    serde_json::from_slice(&bytes).ok()
}

/// Durably replace the journal (temp file, `fsync`, rename).
pub fn write_journal(path: &Path, journal: &Journal) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(journal).map_err(io::Error::other)?;
    bytes.push(b'\n');
    write_atomic(path, &bytes)
}

/// Remove a partial and its journal; missing files are fine.
pub fn remove_partial(data: &Path, journal: &Path) {
    let _ = std::fs::remove_file(data);
    let _ = std::fs::remove_file(journal);
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEX: &str = "970aa74c0a90ef7482477cf803618e776e173c007bf957f635f1015bfcfef0e6";

    #[test]
    fn round_trip_and_rejects_garbage() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("j");
        assert!(read_journal(&p).is_none());
        let j = Journal::new(
            HEX,
            1000,
            400,
            "https://registry.example/v2/library/m/blobs/sha256:abc",
        );
        write_journal(&p, &j).unwrap();
        assert_eq!(read_journal(&p).unwrap(), j);
        assert!(j.matches(HEX, 1000));
        assert!(!j.matches(HEX, 999));
        assert!(!j.matches(&HEX.replace('9', "8"), 1000));
        std::fs::write(&p, b"{not json").unwrap();
        assert!(read_journal(&p).is_none());
        std::fs::write(
            &p,
            br#"{"v":1,"sha256":"x","size":1,"committed":0,"source":"","tool":"","extra":1}"#,
        )
        .unwrap();
        assert!(read_journal(&p).is_none(), "unknown fields are refused");
        let over = Journal {
            committed: 2000,
            ..j
        };
        assert!(
            !over.matches(HEX, 1000),
            "committed beyond the size is invalid"
        );
    }
}
