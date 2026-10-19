//! Tag -> lock entry: the network half of `ci-stick models lock`.
//!
//! For each reference (report 03 section 4.3):
//!
//! 1. `GET .../manifests/<tag>` with Ollama's own `Accept` header; hash the body.
//! 2. If it is a manifest list, pick the llama.cpp/GGUF child and fetch it **as a blob**
//!    (children are 404 under `/manifests/sha256:...`), verifying its digest.
//! 3. Validate the manifest (GGUF only, bounded sizes, known media types).
//! 4. `HEAD` the tag and require `ollama-content-digest` to equal the digest of what step 1
//!    returned: a mismatch means the tag moved while we were looking.
//! 5. Fetch every small blob (config, params, template, system, licence) and keep it inline,
//!    verified against its digest. The config supplies `requires` and the quantisation.

use std::collections::BTreeMap;

use thiserror::Error;

use crate::hashing::sha256_hex;
use crate::lockfile::{b64_encode, LockedLayer, LockedManifest, LockedModel, SOURCE_OLLAMA};
use crate::registry::ollama::{
    self, digest_hex, ModelRef, Parsed, ACCEPT, MAX_INLINE_BLOB_BYTES, MAX_MANIFEST_BYTES,
};
use crate::registry::{HeadInfo, RegistryClient, RegistryError};

#[derive(Debug, Error)]
pub enum ResolveError {
    #[error("{reference}: {source}")]
    Registry {
        reference: String,
        #[source]
        source: RegistryError,
    },
    /// The registry's bytes do not match its own digests, or the tag moved mid-lock.
    #[error("{reference}: {message}")]
    Integrity { reference: String, message: String },
    /// Valid answer, but not something a GGUF stick can carry.
    #[error("{reference}: {message}")]
    Unsupported { reference: String, message: String },
}

impl ResolveError {
    /// `true` for network trouble (retry later), `false` for a definite answer.
    pub fn is_transient(&self) -> bool {
        matches!(self, ResolveError::Registry { source, .. } if source.is_transient())
    }
}

#[derive(Debug)]
pub struct Resolved {
    pub model: LockedModel,
    /// Digest (`sha256:<hex>`) -> bytes of every inline blob this model needs.
    pub inline: BTreeMap<String, Vec<u8>>,
    /// Things worth a maintainer's eye that did not stop the lock (a declared size that the
    /// registry's blob contradicts).
    pub warnings: Vec<String>,
}

/// Roles whose blobs are small text/JSON and live inline in the lock.
fn inlinable(role: &str, size: u64) -> bool {
    size <= MAX_INLINE_BLOB_BYTES
        && matches!(
            role,
            "config" | "params" | "template" | "system" | "license" | "messages"
        )
}

pub fn resolve_model(
    client: &RegistryClient,
    reference: &str,
    license: &str,
) -> Result<Resolved, ResolveError> {
    let mref = ModelRef::parse(reference).map_err(|e| ResolveError::Unsupported {
        reference: reference.to_string(),
        message: e.to_string(),
    })?;
    let canonical = mref.reference();
    let reg = |source: RegistryError| ResolveError::Registry {
        reference: canonical.clone(),
        source,
    };
    let integ = |message: String| ResolveError::Integrity {
        reference: canonical.clone(),
        message,
    };
    let unsupported = |message: String| ResolveError::Unsupported {
        reference: canonical.clone(),
        message,
    };
    let repo = mref.repo();

    // 1. the tag, exactly as Ollama would ask for it
    let tag_url = client.manifest_url(&repo, &mref.tag);
    let (top_bytes, _) = client
        .get_bytes(&tag_url, Some(ACCEPT), MAX_MANIFEST_BYTES)
        .map_err(reg)?;
    let top_digest = format!("sha256:{}", sha256_hex(&top_bytes));
    let top = ollama::parse(&top_bytes).map_err(|e| unsupported(e.to_string()))?;

    // 2. a list: fetch the llama.cpp child as a blob
    let (manifest_bytes, list_digest) = match top {
        Parsed::Manifest(_) => (top_bytes, None),
        Parsed::List(entries) => {
            let child = ollama::select_child(&entries).ok_or_else(|| {
                unsupported("the tag is a manifest list without a llama.cpp/GGUF variant".into())
            })?;
            let (child_bytes, _) = client
                .get_bytes(
                    &client.blob_url(&repo, &child.digest),
                    None,
                    MAX_MANIFEST_BYTES,
                )
                .map_err(reg)?;
            let got = format!("sha256:{}", sha256_hex(&child_bytes));
            if got != child.digest {
                return Err(integ(format!(
                    "the variant manifest hashes to {got}, the list promised {}",
                    child.digest
                )));
            }
            (child_bytes, Some(top_digest.clone()))
        }
    };

    // 3. validate
    let manifest = match ollama::parse(&manifest_bytes).map_err(|e| unsupported(e.to_string()))? {
        Parsed::Manifest(m) => m,
        Parsed::List(_) => {
            return Err(unsupported(
                "nested manifest lists are not supported".into(),
            ))
        }
    };
    let manifest_digest = format!("sha256:{}", sha256_hex(&manifest_bytes));

    // 4. the tag must not have moved while we looked
    let HeadInfo { digest, push_time } = client.head(&tag_url, Some(ACCEPT)).map_err(reg)?;
    if let Some(d) = &digest {
        if *d != top_digest {
            return Err(integ(format!(
                "the tag moved while locking: GET returned {top_digest}, HEAD reports {d}"
            )));
        }
    }

    // 5. small blobs, inline and verified. The digest is the authority: some registry
    // manifests declare a size that is a few bytes off (qwen3-coder:30b's config), so the
    // body is read up to the inline limit and its real length recorded when it differs.
    let mut inline: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut actual: BTreeMap<String, u64> = BTreeMap::new();
    let mut warnings = Vec::new();
    for layer in &manifest.layers {
        if !inlinable(&layer.role, layer.size) || inline.contains_key(&layer.digest) {
            continue;
        }
        let (bytes, _) = client
            .get_bytes(
                &client.blob_url(&repo, &layer.digest),
                None,
                MAX_INLINE_BLOB_BYTES,
            )
            .map_err(reg)?;
        let got = format!("sha256:{}", sha256_hex(&bytes));
        if got != layer.digest {
            return Err(integ(format!("blob {} hashes to {got}", layer.digest)));
        }
        if bytes.len() as u64 != layer.size {
            warnings.push(format!(
                "{canonical}: the manifest declares {} bytes for {} ({}) but the blob is {} bytes; its digest is right, so the real length is recorded",
                layer.size, layer.digest, layer.role, bytes.len()
            ));
            actual.insert(layer.digest.clone(), bytes.len() as u64);
        }
        inline.insert(layer.digest.clone(), bytes);
    }
    // The big layers: a HEAD on the registry's blob URL gives the real length without a
    // redirect or a body. A registry that disagrees with its own manifest is recorded, and
    // a missing blob is caught here instead of at download time.
    for layer in &manifest.layers {
        if inline.contains_key(&layer.digest) || actual.contains_key(&layer.digest) {
            continue;
        }
        let url = client.blob_url(&repo, &layer.digest);
        match client.blob_length(&url) {
            Ok(Some(n)) if n != layer.size => {
                warnings.push(format!(
                    "{canonical}: the manifest declares {} bytes for {} ({}) but the registry serves {n}",
                    layer.size, layer.digest, layer.role
                ));
                actual.insert(layer.digest.clone(), n);
            }
            Ok(_) => {}
            Err(RegistryError::NotFound { .. }) => {
                return Err(integ(format!(
                    "the registry has no blob {} ({})",
                    layer.digest, layer.role
                )));
            }
            Err(e) => return Err(reg(e)),
        }
    }

    // The config blob tells which Ollama version is needed and the quantisation.
    let (requires_ollama, quant) = manifest
        .layers
        .iter()
        .find(|l| l.role == "config")
        .and_then(|l| inline.get(&l.digest))
        .map(|bytes| config_facts(bytes))
        .unwrap_or((None, None));

    let model = LockedModel {
        reference: canonical.clone(),
        source: SOURCE_OLLAMA.to_string(),
        license: license.to_string(),
        manifest: LockedManifest {
            digest: manifest_digest,
            size: manifest_bytes.len() as u64,
            runner: manifest.runner.clone(),
            format: manifest.format.clone(),
            b64: b64_encode(&manifest_bytes),
        },
        list_digest,
        layers: manifest
            .layers
            .iter()
            .map(|l| LockedLayer {
                role: l.role.clone(),
                media_type: l.media_type.clone(),
                digest: l.digest.clone(),
                size: l.size,
                actual: actual.get(&l.digest).copied(),
            })
            .collect(),
        size_bytes: manifest.size_bytes,
        requires_ollama,
        quant,
        push_time,
    };
    debug_assert!(model.layers.iter().all(|l| digest_hex(&l.digest).is_some()));
    Ok(Resolved {
        model,
        inline,
        warnings,
    })
}

/// `requires` and `file_type` from the config blob; anything unexpected is simply absent.
fn config_facts(bytes: &[u8]) -> (Option<String>, Option<String>) {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(bytes) else {
        return (None, None);
    };
    let text = |k: &str| {
        v.get(k)
            .and_then(|x| x.as_str())
            .filter(|s| !s.is_empty() && s.len() <= 64 && s.chars().all(|c| !c.is_control()))
            .map(str::to_string)
    };
    (text("requires"), text("file_type"))
}

/// What `--check` asks the registry: the digest and push time of the tag, with Ollama's
/// `Accept` header (so a list-served tag reports the list digest). If the registry sends no
/// `ollama-content-digest`, the manifest is fetched and hashed instead.
pub fn current_tag(client: &RegistryClient, reference: &str) -> Result<HeadInfo, ResolveError> {
    let mref = ModelRef::parse(reference).map_err(|e| ResolveError::Unsupported {
        reference: reference.to_string(),
        message: e.to_string(),
    })?;
    let url = client.manifest_url(&mref.repo(), &mref.tag);
    let wrap = |source| ResolveError::Registry {
        reference: mref.reference(),
        source,
    };
    let mut head = client.head(&url, Some(ACCEPT)).map_err(wrap)?;
    if head.digest.is_none() {
        let (bytes, _) = client
            .get_bytes(&url, Some(ACCEPT), MAX_MANIFEST_BYTES)
            .map_err(wrap)?;
        head.digest = Some(format!("sha256:{}", sha256_hex(&bytes)));
    }
    Ok(head)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_facts_are_read_defensively() {
        let cfg = include_bytes!("../../tests/fixtures/models/blobs/370b24c023f51e75e7f3b70e1b89d59a38ec2fb5af3289fcf92ff78b3fadd619");
        assert_eq!(
            config_facts(cfg),
            (Some("0.30.0".into()), Some("Q4_K_M".into()))
        );
        let nomic = include_bytes!("../../tests/fixtures/models/blobs/31df23ea7daa448f9ccdbbcecce6c14689c8552222b80defd3830707c0139d4f");
        let (req, quant) = config_facts(nomic);
        assert_eq!(req, None);
        assert_eq!(quant.as_deref(), Some("F16"));
        assert_eq!(config_facts(b"not json"), (None, None));
        assert_eq!(
            config_facts(br#"{"requires":"\u0007bad","file_type":""}"#),
            (None, None)
        );
        assert_eq!(config_facts(&[0xff, 0xfe]), (None, None));
    }
}
