//! Bundle-relative path rules.
//!
//! Artifact paths in `bundle.json` are always `/`-separated, relative to the bundle root,
//! and made only of ordinary components. They must be representable on exFAT (the shared
//! and cache partitions) and must not be able to name anything outside the root, so we
//! reject rather than normalise: `..`, `.`, empty components, absolute paths, backslashes,
//! drive/stream colons and control characters are all errors.

use std::path::{Component, Path, PathBuf};

use thiserror::Error;

use crate::manifest::{BUNDLE_FILE, SIGNATURE_FILE};

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PathError {
    #[error("path is empty")]
    Empty,
    #[error("path {0:?} is absolute")]
    Absolute(String),
    #[error("path {0:?} contains a '..' or '.' component")]
    DotComponent(String),
    #[error("path {0:?} contains an empty component")]
    EmptyComponent(String),
    #[error("path {0:?} contains a backslash, colon or control character")]
    BadCharacter(String),
    #[error("path {0:?} is reserved for the bundle manifest/signature")]
    Reserved(String),
    #[error("path {0:?} is not valid UTF-8")]
    NotUtf8(String),
}

/// Validate a manifest path string.
pub fn validate_rel_path(p: &str) -> Result<(), PathError> {
    if p.is_empty() {
        return Err(PathError::Empty);
    }
    if p.starts_with('/') {
        return Err(PathError::Absolute(p.to_string()));
    }
    if p.chars().any(|c| c == '\\' || c == ':' || c.is_control()) {
        return Err(PathError::BadCharacter(p.to_string()));
    }
    for comp in p.split('/') {
        match comp {
            "" => return Err(PathError::EmptyComponent(p.to_string())),
            "." | ".." => return Err(PathError::DotComponent(p.to_string())),
            _ => {}
        }
    }
    if p == BUNDLE_FILE || p == SIGNATURE_FILE {
        return Err(PathError::Reserved(p.to_string()));
    }
    Ok(())
}

/// Convert an on-disk path relative to the root into its manifest form (`a/b/c`).
pub fn to_manifest_path(rel: &Path) -> Result<String, PathError> {
    let mut parts = Vec::new();
    for comp in rel.components() {
        match comp {
            Component::Normal(os) => match os.to_str() {
                Some(s) => parts.push(s.to_string()),
                None => return Err(PathError::NotUtf8(rel.to_string_lossy().into_owned())),
            },
            Component::CurDir | Component::ParentDir => {
                return Err(PathError::DotComponent(rel.to_string_lossy().into_owned()))
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err(PathError::Absolute(rel.to_string_lossy().into_owned()))
            }
        }
    }
    let joined = parts.join("/");
    validate_rel_path(&joined)?;
    Ok(joined)
}

/// Join a validated manifest path onto a root using native separators.
pub fn join_manifest_path(root: &Path, manifest_path: &str) -> PathBuf {
    let mut out = root.to_path_buf();
    for comp in manifest_path.split('/') {
        out.push(comp);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_normal_paths() {
        for p in [
            "a",
            "boot/ci-os-ubuntu.img",
            "models/blobs/sha256-ab",
            "x/.hidden",
        ] {
            validate_rel_path(p).unwrap();
        }
    }

    #[test]
    fn rejects_escapes_and_oddities() {
        let cases = [
            ("", PathError::Empty),
            ("/etc/passwd", PathError::Absolute("/etc/passwd".into())),
            ("../x", PathError::DotComponent("../x".into())),
            ("a/../../x", PathError::DotComponent("a/../../x".into())),
            ("a/./b", PathError::DotComponent("a/./b".into())),
            ("a//b", PathError::EmptyComponent("a//b".into())),
            ("a/", PathError::EmptyComponent("a/".into())),
            ("a\\..\\b", PathError::BadCharacter("a\\..\\b".into())),
            ("C:/x", PathError::BadCharacter("C:/x".into())),
            ("a\nb", PathError::BadCharacter("a\nb".into())),
            ("bundle.json", PathError::Reserved("bundle.json".into())),
            (
                "bundle.json.sig",
                PathError::Reserved("bundle.json.sig".into()),
            ),
        ];
        for (input, want) in cases {
            assert_eq!(validate_rel_path(input), Err(want), "{input:?}");
        }
    }

    #[test]
    fn manifest_path_round_trip() {
        let p = Path::new("models").join("blobs").join("sha256-x");
        let m = to_manifest_path(&p).unwrap();
        assert_eq!(m, "models/blobs/sha256-x");
        assert_eq!(
            join_manifest_path(Path::new("root"), &m),
            Path::new("root").join(&p)
        );
        assert!(to_manifest_path(Path::new("../x")).is_err());
    }
}
