//! Streaming SHA-256. Artifacts can be tens of GiB, so nothing here reads a whole file
//! into memory: data flows through a fixed 1 MiB buffer.

use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

use sha2::{Digest as _, Sha256};

const BUF_SIZE: usize = 1 << 20;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileDigest {
    /// Lowercase hex SHA-256.
    pub sha256: String,
    pub size: u64,
}

/// Hash everything `reader` yields. `on_progress` receives the running byte count after
/// every chunk.
pub fn hash_reader<R: Read>(
    mut reader: R,
    mut on_progress: impl FnMut(u64),
) -> io::Result<FileDigest> {
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; BUF_SIZE];
    let mut total: u64 = 0;
    loop {
        let n = match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        hasher.update(&buf[..n]);
        total += n as u64;
        on_progress(total);
    }
    Ok(FileDigest {
        sha256: hex::encode(hasher.finalize()),
        size: total,
    })
}

pub fn hash_file(path: &Path, on_progress: impl FnMut(u64)) -> io::Result<FileDigest> {
    hash_reader(File::open(path)?, on_progress)
}

/// SHA-256 of an in-memory buffer (small things only: keys, manifests).
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// `true` if `s` looks like a lowercase hex SHA-256.
pub fn is_sha256_hex(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_vectors() {
        let d = hash_reader(&b""[..], |_| {}).unwrap();
        assert_eq!(
            d.sha256,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(d.size, 0);
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn streams_across_buffer_boundaries() {
        let data = vec![7u8; BUF_SIZE * 2 + 3];
        let mut seen = Vec::new();
        let d = hash_reader(&data[..], |n| seen.push(n)).unwrap();
        assert_eq!(d.size, data.len() as u64);
        assert_eq!(d.sha256, sha256_hex(&data));
        assert_eq!(seen.last().copied(), Some(data.len() as u64));
    }

    #[test]
    fn hex_check() {
        assert!(is_sha256_hex(&sha256_hex(b"x")));
        assert!(!is_sha256_hex("ABC"));
        assert!(!is_sha256_hex(&"A".repeat(64)));
    }
}
