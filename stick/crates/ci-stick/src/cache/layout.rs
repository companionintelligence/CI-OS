//! On-disk layout of the model cache and the name rules for it.
//!
//! ```text
//! <cache>/
//!   models/                       what Ollama sees (OLLAMA_MODELS)
//!     blobs/sha256-<hex>          config, model, projector, licence ... (content addressed)
//!     manifests/registry.ollama.ai/library/<name>/<tag>   the registry's manifest, verbatim
//!     manifests-v2/               EMPTY directory (Ollama 0.40 MkdirAll's it on every access,
//!                                 which fails on a read-only seeded stick if it is absent)
//!   ci-models/                    ci-stick's private state, a sibling of models/, never inside it
//!     VERSION                     "ci-models-cache/1"
//!     blobs/<hh>/<hex>            content-addressed files Ollama must not see
//!     partial/<hex>-partial       resumable downloads
//!     partial/<hex>-partial.journal
//!     status.json                 progress for the setup portal
//! ```
//!
//! Partials live OUTSIDE `models/blobs` on purpose: at start-up Ollama deletes every file in
//! `blobs/` that is not a valid digest name or not referenced by a manifest (unless
//! `OLLAMA_NOPRUNE` is set), and its own downloader uses `<digest>-partial` files there in a
//! different format.
//!
//! The cache is meant for exFAT: no symlinks, no hard links, no reliance on `chmod`, names
//! compared case-insensitively, `._*` AppleDouble files from macOS may appear next to ours.

use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::hashing::is_sha256_hex;

pub const MODELS_DIR: &str = "models";
pub const PRIVATE_DIR: &str = "ci-models";
pub const VERSION_FILE: &str = "VERSION";
pub const VERSION_CONTENT: &str = "ci-models-cache/1\n";
/// Host directory the Ollama daemon uses for its default registry.
pub const DEFAULT_REGISTRY_HOST: &str = "registry.ollama.ai";

#[derive(Debug, Error, PartialEq, Eq)]
pub enum LayoutError {
    #[error("name {0:?} is not usable as a file name (empty, too long, or contains a path separator, control or reserved character)")]
    BadName(String),
    #[error("name {0:?} ends with a dot or a space, which exFAT/Windows cannot hold")]
    TrailingDotOrSpace(String),
    #[error("name {0:?} is a reserved device name on Windows")]
    ReservedName(String),
    #[error("name {0:?} starts with \"._\" (macOS AppleDouble metadata)")]
    AppleDouble(String),
    #[error("digest {0:?} is not 64 lowercase hex digits")]
    BadDigest(String),
}

/// Reject names a cache on exFAT (or a Windows or macOS host reading it) cannot hold.
pub fn validate_component(name: &str) -> Result<(), LayoutError> {
    let bad = || LayoutError::BadName(name.to_string());
    if name.is_empty() || name == "." || name == ".." {
        return Err(bad());
    }
    if name.encode_utf16().count() > 255 {
        return Err(bad());
    }
    if name.chars().any(|c| {
        c.is_control() || matches!(c, '/' | '\\' | ':' | '<' | '>' | '"' | '|' | '?' | '*')
    }) {
        return Err(bad());
    }
    if name.ends_with('.') || name.ends_with(' ') {
        return Err(LayoutError::TrailingDotOrSpace(name.to_string()));
    }
    if name.starts_with("._") {
        return Err(LayoutError::AppleDouble(name.to_string()));
    }
    let stem = name.split('.').next().unwrap_or(name).to_ascii_uppercase();
    let reserved = matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || ((stem.starts_with("COM") || stem.starts_with("LPT"))
            && stem.len() == 4
            && stem.as_bytes()[3].is_ascii_digit()
            && stem.as_bytes()[3] != b'0');
    if reserved {
        return Err(LayoutError::ReservedName(name.to_string()));
    }
    Ok(())
}

/// Pairs of distinct names that the same case-insensitive file system would treat as one.
pub fn casefold_collisions<'a>(names: impl IntoIterator<Item = &'a str>) -> Vec<(String, String)> {
    let mut seen: std::collections::BTreeMap<String, &str> = std::collections::BTreeMap::new();
    let mut out = Vec::new();
    for n in names {
        let key = n.to_lowercase();
        match seen.get(&key) {
            Some(prev) if *prev != n => out.push(((*prev).to_string(), n.to_string())),
            Some(_) => {}
            None => {
                seen.insert(key, n);
            }
        }
    }
    out
}

/// Files that Finder, Spotlight, Windows or a thumbnailer drop on a volume. Ignored when
/// counting and never created by `ci-stick`.
pub fn is_junk_name(name: &str) -> bool {
    name.starts_with("._")
        || matches!(
            name.to_ascii_lowercase().as_str(),
            ".ds_store"
                | ".spotlight-v100"
                | ".fseventsd"
                | ".trashes"
                | ".temporaryitems"
                | ".documentrevisions-v100"
                | "thumbs.db"
                | "desktop.ini"
                | "system volume information"
                | "$recycle.bin"
        )
}

/// `sha256-<hex>`
pub fn blob_file_name(hex: &str) -> String {
    format!("sha256-{hex}")
}

/// The inverse of [`blob_file_name`]: `Some(hex)` for a valid blob file name.
pub fn parse_blob_file_name(name: &str) -> Option<&str> {
    name.strip_prefix("sha256-").filter(|h| is_sha256_hex(h))
}

/// Paths inside one cache directory. Pure: nothing here touches the disk.
#[derive(Debug, Clone)]
pub struct CacheLayout {
    root: PathBuf,
}

impl CacheLayout {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn models_dir(&self) -> PathBuf {
        self.root.join(MODELS_DIR)
    }
    pub fn blobs_dir(&self) -> PathBuf {
        self.models_dir().join("blobs")
    }
    pub fn manifests_dir(&self) -> PathBuf {
        self.models_dir().join("manifests")
    }
    pub fn manifests_v2_dir(&self) -> PathBuf {
        self.models_dir().join("manifests-v2")
    }
    pub fn private_dir(&self) -> PathBuf {
        self.root.join(PRIVATE_DIR)
    }
    pub fn partial_dir(&self) -> PathBuf {
        self.private_dir().join("partial")
    }
    pub fn private_blobs_dir(&self) -> PathBuf {
        self.private_dir().join("blobs")
    }
    pub fn status_file(&self) -> PathBuf {
        self.private_dir().join("status.json")
    }
    pub fn version_file(&self) -> PathBuf {
        self.private_dir().join(VERSION_FILE)
    }

    /// `models/blobs/sha256-<hex>`
    pub fn blob_path(&self, hex: &str) -> Result<PathBuf, LayoutError> {
        check_hex(hex)?;
        Ok(self.blobs_dir().join(blob_file_name(hex)))
    }

    /// `ci-models/blobs/<first two hex digits>/<hex>`: a file Ollama must not see.
    pub fn private_blob_path(&self, hex: &str) -> Result<PathBuf, LayoutError> {
        check_hex(hex)?;
        Ok(self.private_blobs_dir().join(&hex[..2]).join(hex))
    }

    /// `ci-models/partial/<hex>-partial`
    pub fn partial_path(&self, hex: &str) -> Result<PathBuf, LayoutError> {
        check_hex(hex)?;
        Ok(self.partial_dir().join(format!("{hex}-partial")))
    }

    /// `ci-models/partial/<hex>-partial.journal`
    pub fn journal_path(&self, hex: &str) -> Result<PathBuf, LayoutError> {
        check_hex(hex)?;
        Ok(self.partial_dir().join(format!("{hex}-partial.journal")))
    }

    /// `models/manifests/<components...>`; every component is validated.
    pub fn manifest_path(&self, components: &[&str]) -> Result<PathBuf, LayoutError> {
        let mut p = self.manifests_dir();
        for c in components {
            validate_component(c)?;
            p.push(c);
        }
        Ok(p)
    }
}

fn check_hex(hex: &str) -> Result<(), LayoutError> {
    if is_sha256_hex(hex) {
        Ok(())
    } else {
        Err(LayoutError::BadDigest(hex.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEX: &str = "970aa74c0a90ef7482477cf803618e776e173c007bf957f635f1015bfcfef0e6";

    #[test]
    fn paths_follow_the_documented_layout() {
        let l = CacheLayout::new("/c");
        assert_eq!(
            l.blob_path(HEX).unwrap(),
            Path::new("/c/models/blobs").join(format!("sha256-{HEX}"))
        );
        assert_eq!(
            l.partial_path(HEX).unwrap(),
            Path::new("/c/ci-models/partial").join(format!("{HEX}-partial"))
        );
        assert_eq!(
            l.private_blob_path(HEX).unwrap(),
            Path::new("/c/ci-models/blobs/97").join(HEX)
        );
        assert_eq!(
            l.manifest_path(&["registry.ollama.ai", "library", "gemma3", "1b"])
                .unwrap(),
            Path::new("/c/models/manifests/registry.ollama.ai/library/gemma3/1b")
        );
        assert_eq!(l.status_file(), Path::new("/c/ci-models/status.json"));
        // partials must never be inside the directory Ollama prunes
        assert!(!l.partial_dir().starts_with(l.models_dir()));
        assert!(!l.private_dir().starts_with(l.models_dir()));
    }

    #[test]
    fn digests_are_checked_before_they_become_paths() {
        let l = CacheLayout::new("/c");
        for bad in [
            "",
            "../etc/passwd",
            &HEX.to_uppercase(),
            &HEX[1..],
            "sha256-ab",
        ] {
            assert!(l.blob_path(bad).is_err(), "{bad}");
            assert!(l.partial_path(bad).is_err(), "{bad}");
            assert!(l.private_blob_path(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn component_rules() {
        for ok in [
            "latest", "1b", "q4_K_M", "qwen3.5", "gemma3", "a-b_c.d", "ünï",
        ] {
            validate_component(ok).unwrap_or_else(|e| panic!("{ok}: {e}"));
        }
        for bad in [
            "", ".", "..", "a/b", "a\\b", "a:b", "x*y", "q?", "a<b", "a|b", "a\"b", "a\nb",
            "trail.", "trail ", "._hidden", "CON", "con", "nul.txt", "Com1", "LPT9.x", "aux",
        ] {
            assert!(validate_component(bad).is_err(), "{bad:?} must be refused");
        }
        assert!(validate_component("com0").is_ok(), "COM0 is not reserved");
        assert!(validate_component("console").is_ok());
        assert!(validate_component(&"a".repeat(256)).is_err());
        assert!(validate_component(&"a".repeat(255)).is_ok());
        let l = CacheLayout::new("/c");
        assert!(l.manifest_path(&["..", "x"]).is_err());
        assert!(l
            .manifest_path(&["registry.ollama.ai", "library", "a/b", "t"])
            .is_err());
    }

    #[test]
    fn case_folding_collisions() {
        let c = casefold_collisions(["q4_K_M", "q4_k_m", "latest", "latest", "1b"]);
        assert_eq!(c, vec![("q4_K_M".to_string(), "q4_k_m".to_string())]);
        assert!(casefold_collisions(["a", "b"]).is_empty());
    }

    #[test]
    fn junk_and_blob_names() {
        for j in [
            "._sha256-abc",
            ".DS_Store",
            ".Spotlight-V100",
            ".fseventsd",
            ".Trashes",
            "Thumbs.db",
        ] {
            assert!(is_junk_name(j), "{j}");
        }
        assert!(!is_junk_name(&blob_file_name(HEX)));
        assert_eq!(parse_blob_file_name(&blob_file_name(HEX)), Some(HEX));
        assert_eq!(parse_blob_file_name(&format!("sha256-{HEX}-partial")), None);
        assert_eq!(parse_blob_file_name("sha256-XYZ"), None);
    }
}
