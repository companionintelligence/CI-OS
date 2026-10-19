//! `core/manifest/model-packs.lock.json`: the facts behind the model-pack catalog.
//!
//! The catalog (`model-packs.yaml`) says *what we intend to ship* (`gemma3:1b`, a licence, a
//! rough size). The lock records *what the registry served* when someone last ran
//! `ci-stick models lock`: manifest digests and bytes, layer digests and sizes. Nothing in it
//! is typed by hand.
//!
//! * The registry cannot serve an old manifest by digest (404), so the manifest **bytes** are
//!   stored inline (base64); `fetch` writes them verbatim and never asks the registry for them.
//! * Blobs of at most 64 KiB (config, params, template, system, licence) are stored inline too,
//!   de-duplicated by digest, so a seeded store needs the network only for the big layers.
//! * A tag served as a manifest list is pinned twice: `list_digest` (detects the tag moving)
//!   and the llama.cpp child's own `manifest.digest` (the reproducible content). The named
//!   manifest written to a store is the child, so a daemon never wants the MLX variant.
//! * `packs` maps each pack name to its model references in catalog order, so `plan`/`fetch`
//!   work from the lock alone, without the repository.
//!
//! The file is canonical JSON (sorted keys, two-space indent, trailing newline), stable
//! under re-generation, and `schema_version` is this file's own (the bundle's is untouched).

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use anyhow::Context as _;
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

use crate::cache::layout::casefold_collisions;
use crate::hashing::sha256_hex;
use crate::registry::ollama::{
    self, digest_hex, is_digest, ModelRef, Parsed, MAX_INLINE_BLOB_BYTES,
};

pub const LOCK_SCHEMA_VERSION: u32 = 1;
/// Repository-relative location of the lock.
pub const LOCK_REL_PATH: &str = "core/manifest/model-packs.lock.json";
pub const SOURCE_OLLAMA: &str = "ollama";

#[derive(Debug, Error)]
pub enum LockError {
    /// Malformed or inconsistent lock (exit 2).
    #[error("{0}")]
    Format(String),
    /// A hash or size inside the lock does not match its content (exit 7).
    #[error("{0}")]
    Integrity(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LockedLayer {
    /// `config`, `model`, `projector`, `license`, `params`, ...
    pub role: String,
    pub media_type: String,
    pub digest: String,
    /// The size the manifest declares.
    pub size: u64,
    /// The blob's real length when the registry's manifest declares a different one (seen on
    /// the config blob of `qwen3-coder:30b`: declared 539, real 542, digest correct). Absent
    /// when the declaration is right, which is the normal case. Everything that allocates,
    /// requests or checks bytes uses [`LockedLayer::real_size`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actual: Option<u64>,
}

impl LockedLayer {
    /// The number of bytes the blob really has.
    pub fn real_size(&self) -> u64 {
        self.actual.unwrap_or(self.size)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LockedManifest {
    /// `sha256:` of the manifest bytes that get written into the store.
    pub digest: String,
    pub size: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runner: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub format: Option<String>,
    /// The manifest, verbatim, base64.
    pub b64: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LockedModel {
    /// `name:tag` or `namespace/name:tag`, as the pack catalog spells it.
    #[serde(rename = "ref")]
    pub reference: String,
    pub source: String,
    /// The catalog's licence string; `unverified` blocks `fetch` unless `--accept-licenses`.
    pub license: String,
    pub manifest: LockedManifest,
    /// Digest of the manifest list the tag resolved to, when it was a list.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub list_digest: Option<String>,
    /// Config first, then the layers in manifest order.
    pub layers: Vec<LockedLayer>,
    /// Sum of all layer sizes: the catalog's `size_bytes`.
    pub size_bytes: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requires_ollama: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quant: Option<String>,
    /// `ollama-push-time` (Unix seconds) observed at lock time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub push_time: Option<u64>,
}

impl LockedModel {
    /// The digest `HEAD` reports for this tag with Ollama's `Accept` header.
    pub fn tag_digest(&self) -> &str {
        self.list_digest.as_deref().unwrap_or(&self.manifest.digest)
    }

    pub fn model_ref(&self) -> Result<ModelRef, ollama::RefError> {
        ModelRef::parse(&self.reference)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelLock {
    pub schema_version: u32,
    /// RFC 3339 UTC; carried over unchanged when a re-lock finds nothing new.
    pub generated_at: String,
    pub tool: String,
    /// The registry the facts came from (scheme and host only).
    pub registry: String,
    /// Pack name -> model references, in catalog (rank) order.
    pub packs: BTreeMap<String, Vec<String>>,
    /// Sorted by `ref`.
    pub models: Vec<LockedModel>,
    /// `sha256:<hex>` -> base64 of every blob of at most 64 KiB.
    pub blobs_inline: BTreeMap<String, String>,
}

/// Sorted keys, two-space indent, trailing newline. Independent of serde_json's feature set.
pub fn canonical_json(value: &Value) -> String {
    let mut out = String::new();
    write_value(value, 0, &mut out);
    out.push('\n');
    out
}

fn indent(out: &mut String, level: usize) {
    for _ in 0..level {
        out.push_str("  ");
    }
}

fn write_value(v: &Value, level: usize, out: &mut String) {
    match v {
        Value::Object(map) if !map.is_empty() => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push_str("{\n");
            for (i, k) in keys.iter().enumerate() {
                indent(out, level + 1);
                out.push_str(&Value::String((*k).clone()).to_string());
                out.push_str(": ");
                write_value(&map[*k], level + 1, out);
                if i + 1 < keys.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            indent(out, level);
            out.push('}');
        }
        Value::Array(items) if !items.is_empty() => {
            out.push_str("[\n");
            for (i, item) in items.iter().enumerate() {
                indent(out, level + 1);
                write_value(item, level + 1, out);
                if i + 1 < items.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            indent(out, level);
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

impl ModelLock {
    pub fn new(registry: &str, generated_at: &str) -> Self {
        Self {
            schema_version: LOCK_SCHEMA_VERSION,
            generated_at: generated_at.to_string(),
            tool: concat!("ci-stick ", env!("CARGO_PKG_VERSION")).to_string(),
            registry: registry.to_string(),
            packs: BTreeMap::new(),
            models: Vec::new(),
            blobs_inline: BTreeMap::new(),
        }
    }

    /// Canonical bytes (what gets committed, and what a signature would cover).
    pub fn to_canonical_json(&self) -> Vec<u8> {
        // Invariant, not a user-reachable failure: the lock types are strings, integers,
        // maps and vectors, which serde_json always converts.
        let value = serde_json::to_value(self).expect("lock types always serialise");
        canonical_json(&value).into_bytes()
    }

    /// Parse and validate. Hash/size mismatches are [`LockError::Integrity`].
    pub fn parse(bytes: &[u8]) -> Result<Self, LockError> {
        let lock: ModelLock = serde_json::from_slice(bytes)
            .map_err(|e| LockError::Format(format!("model lock does not match its schema: {e}")))?;
        lock.validate()?;
        Ok(lock)
    }

    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let bytes = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
        Self::parse(&bytes).with_context(|| format!("loading {}", path.display()))
    }

    /// Everything that must hold for the lock to be trusted. Never trusts a stored figure
    /// that can be recomputed from the manifest bytes.
    pub fn validate(&self) -> Result<(), LockError> {
        let fmt = |s: String| LockError::Format(s);
        let integ = |s: String| LockError::Integrity(s);
        if self.schema_version != LOCK_SCHEMA_VERSION {
            return Err(fmt(format!(
                "unsupported model lock schema_version {} (this ci-stick reads {LOCK_SCHEMA_VERSION})",
                self.schema_version
            )));
        }
        let mut refs = BTreeSet::new();
        let mut prev: Option<&str> = None;
        let mut referenced_inline: BTreeSet<&str> = BTreeSet::new();
        for m in &self.models {
            let r = &m.reference;
            let canonical = ModelRef::parse(r)
                .map_err(|e| fmt(format!("lock model {r:?}: {e}")))?
                .reference();
            if &canonical != r {
                return Err(fmt(format!(
                    "lock model ref {r:?} is not canonical (expected {canonical:?})"
                )));
            }
            if prev.is_some_and(|p| p >= r.as_str()) {
                return Err(fmt(format!(
                    "lock models are not sorted and unique at {r:?}"
                )));
            }
            prev = Some(r);
            refs.insert(r.as_str());
            if m.source != SOURCE_OLLAMA {
                return Err(fmt(format!(
                    "lock model {r}: source {:?} is not supported",
                    m.source
                )));
            }
            if !is_digest(&m.manifest.digest) {
                return Err(fmt(format!(
                    "lock model {r}: manifest digest {:?} is malformed",
                    m.manifest.digest
                )));
            }
            if let Some(ld) = &m.list_digest {
                if !is_digest(ld) {
                    return Err(fmt(format!(
                        "lock model {r}: list digest {ld:?} is malformed"
                    )));
                }
            }
            let manifest_bytes = B64
                .decode(m.manifest.b64.as_bytes())
                .map_err(|e| fmt(format!("lock model {r}: manifest is not valid base64: {e}")))?;
            if manifest_bytes.len() as u64 != m.manifest.size {
                return Err(integ(format!(
                    "lock model {r}: manifest size does not match its bytes"
                )));
            }
            if format!("sha256:{}", sha256_hex(&manifest_bytes)) != m.manifest.digest {
                return Err(integ(format!(
                    "lock model {r}: manifest bytes do not hash to {}",
                    m.manifest.digest
                )));
            }
            let parsed =
                ollama::parse(&manifest_bytes).map_err(|e| fmt(format!("lock model {r}: {e}")))?;
            let Parsed::Manifest(parsed) = parsed else {
                return Err(fmt(format!(
                    "lock model {r}: the stored manifest is a list, not a manifest"
                )));
            };
            let same_layers = parsed.layers.len() == m.layers.len()
                && parsed.layers.iter().zip(&m.layers).all(|(d, l)| {
                    d.role == l.role
                        && d.media_type == l.media_type
                        && d.digest == l.digest
                        && d.size == l.size
                });
            if !same_layers {
                return Err(integ(format!(
                    "lock model {r}: layers differ from the stored manifest bytes"
                )));
            }
            if m.layers.iter().any(|l| l.actual == Some(l.size)) {
                return Err(fmt(format!(
                    "lock model {r}: a layer records an `actual` size equal to the declared one"
                )));
            }
            if parsed.size_bytes != m.size_bytes {
                return Err(integ(format!(
                    "lock model {r}: size_bytes differs from the manifest's layers"
                )));
            }
            if parsed.runner != m.manifest.runner || parsed.format != m.manifest.format {
                return Err(integ(format!(
                    "lock model {r}: runner/format differ from the stored manifest"
                )));
            }
            for l in &m.layers {
                if self.blobs_inline.contains_key(&l.digest) {
                    referenced_inline.insert(l.digest.as_str());
                }
            }
        }
        let folded = casefold_collisions(self.models.iter().map(|m| m.reference.as_str()));
        if let Some((a, b)) = folded.first() {
            return Err(fmt(format!(
                "lock refs {a:?} and {b:?} differ only in case; exFAT would merge them"
            )));
        }
        for (name, list) in &self.packs {
            for r in list {
                if !refs.contains(r.as_str()) {
                    return Err(fmt(format!(
                        "pack {name:?} lists {r:?}, which has no model entry"
                    )));
                }
            }
        }
        for (digest, b64) in &self.blobs_inline {
            if !is_digest(digest) {
                return Err(fmt(format!("inline blob key {digest:?} is malformed")));
            }
            let bytes = B64
                .decode(b64.as_bytes())
                .map_err(|e| fmt(format!("inline blob {digest} is not valid base64: {e}")))?;
            if bytes.len() as u64 > MAX_INLINE_BLOB_BYTES {
                return Err(fmt(format!(
                    "inline blob {digest} is larger than {MAX_INLINE_BLOB_BYTES} bytes"
                )));
            }
            if format!("sha256:{}", sha256_hex(&bytes)) != *digest {
                return Err(integ(format!(
                    "inline blob {digest} does not hash to its key"
                )));
            }
            if !referenced_inline.contains(digest.as_str()) {
                return Err(fmt(format!(
                    "inline blob {digest} is not used by any model"
                )));
            }
            // a layer of the right digest must also agree on size
            for m in &self.models {
                for l in m.layers.iter().filter(|l| &l.digest == digest) {
                    if l.real_size() != bytes.len() as u64 {
                        return Err(integ(format!(
                            "lock model {}: layer {digest} size differs from its inline bytes",
                            m.reference
                        )));
                    }
                }
            }
        }
        Ok(())
    }

    pub fn model(&self, reference: &str) -> Option<&LockedModel> {
        self.models.iter().find(|m| m.reference == reference)
    }

    /// Look up a model by any spelling `ModelRef` accepts (`nomic-embed-text` finds `...:latest`).
    pub fn find_model(&self, reference: &str) -> Option<&LockedModel> {
        let canonical = ModelRef::parse(reference).ok()?.reference();
        self.model(&canonical)
    }

    /// The digest a `HEAD` on the tag reports (list digest for list-served tags).
    /// Empty if the model is not in the lock.
    pub fn tag_digest_of(&self, reference: &str) -> &str {
        self.find_model(reference)
            .map_or("", LockedModel::tag_digest)
    }

    pub fn pack(&self, name: &str) -> Option<Vec<&LockedModel>> {
        let refs = self.packs.get(name)?;
        refs.iter().map(|r| self.model(r)).collect()
    }

    /// The manifest bytes of a model, decoded (validated at load time).
    pub fn manifest_bytes(&self, model: &LockedModel) -> Result<Vec<u8>, LockError> {
        B64.decode(model.manifest.b64.as_bytes())
            .map_err(|e| LockError::Format(format!("manifest of {}: {e}", model.reference)))
    }

    /// An inline blob's bytes, decoded.
    pub fn inline_blob(&self, digest: &str) -> Option<Vec<u8>> {
        self.blobs_inline
            .get(digest)
            .and_then(|b| B64.decode(b.as_bytes()).ok())
    }

    /// Hex of a blob digest (`sha256:<hex>`), or an error naming the model.
    pub fn layer_hex<'a>(&self, layer: &'a LockedLayer) -> Result<&'a str, LockError> {
        digest_hex(&layer.digest).ok_or_else(|| {
            LockError::Format(format!("layer digest {:?} is malformed", layer.digest))
        })
    }
}

/// Encode bytes the way the lock stores them.
pub fn b64_encode(bytes: &[u8]) -> String {
    B64.encode(bytes)
}

/// Find `core/manifest/model-packs.lock.json` by walking up from `start`.
pub fn find_lock(start: &Path) -> Option<PathBuf> {
    start
        .ancestors()
        .map(|dir| dir.join(LOCK_REL_PATH))
        .find(|p| p.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn canonical_json_sorts_keys_and_is_stable() {
        let v = json!({"b": [1, {"z": null, "a": "x\"y"}], "a": {}, "c": [], "d": true});
        let s = canonical_json(&v);
        assert_eq!(
            s,
            "{\n  \"a\": {},\n  \"b\": [\n    1,\n    {\n      \"a\": \"x\\\"y\",\n      \"z\": null\n    }\n  ],\n  \"c\": [],\n  \"d\": true\n}\n"
        );
        let again: Value = serde_json::from_str(&s).unwrap();
        assert_eq!(canonical_json(&again), s);
    }

    fn sample_lock() -> ModelLock {
        // Build a real lock from the nomic-embed-text fixtures without a network.
        let manifest =
            include_bytes!("../tests/fixtures/models/manifests/nomic-embed-text.latest.v2.json");
        let blobs: [(&str, &[u8]); 3] = [
            (
                "sha256:31df23ea7daa448f9ccdbbcecce6c14689c8552222b80defd3830707c0139d4f",
                include_bytes!("../tests/fixtures/models/blobs/31df23ea7daa448f9ccdbbcecce6c14689c8552222b80defd3830707c0139d4f"),
            ),
            (
                "sha256:c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
                include_bytes!("../tests/fixtures/models/blobs/c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4"),
            ),
            (
                "sha256:ce4a164fc04605703b485251fe9f1a181688ba0eb6badb80cc6335c0de17ca0d",
                include_bytes!("../tests/fixtures/models/blobs/ce4a164fc04605703b485251fe9f1a181688ba0eb6badb80cc6335c0de17ca0d"),
            ),
        ];
        let Parsed::Manifest(m) = ollama::parse(manifest).unwrap() else {
            panic!()
        };
        let mut lock = ModelLock::new("https://registry.ollama.ai", "2026-10-17T00:00:00Z");
        lock.models.push(LockedModel {
            reference: "nomic-embed-text:latest".into(),
            source: SOURCE_OLLAMA.into(),
            license: "Apache-2.0".into(),
            manifest: LockedManifest {
                digest: format!("sha256:{}", sha256_hex(manifest)),
                size: manifest.len() as u64,
                runner: None,
                format: None,
                b64: b64_encode(manifest),
            },
            list_digest: None,
            layers: m
                .layers
                .iter()
                .map(|l| LockedLayer {
                    role: l.role.clone(),
                    media_type: l.media_type.clone(),
                    digest: l.digest.clone(),
                    size: l.size,
                    actual: None,
                })
                .collect(),
            size_bytes: m.size_bytes,
            requires_ollama: None,
            quant: Some("F16".into()),
            push_time: Some(1_790_000_000),
        });
        for (d, b) in blobs {
            lock.blobs_inline.insert(d.to_string(), b64_encode(b));
        }
        lock.packs
            .insert("starter".into(), vec!["nomic-embed-text:latest".into()]);
        lock
    }

    #[test]
    fn round_trips_and_validates() {
        let lock = sample_lock();
        let bytes = lock.to_canonical_json();
        let back = ModelLock::parse(&bytes).unwrap();
        assert_eq!(back, lock);
        assert_eq!(
            back.to_canonical_json(),
            bytes,
            "canonical output is a fixed point"
        );
        assert!(bytes.ends_with(b"\n"));
        assert!(back.find_model("nomic-embed-text").is_some());
        assert_eq!(back.pack("starter").unwrap().len(), 1);
        assert!(back.pack("missing").is_none());
        assert_eq!(back.models[0].size_bytes, 274_302_450);
        assert_eq!(back.models[0].tag_digest(), back.models[0].manifest.digest);
    }

    fn corrupt(f: impl FnOnce(&mut ModelLock)) -> LockError {
        let mut l = sample_lock();
        f(&mut l);
        ModelLock::parse(&l.to_canonical_json()).unwrap_err()
    }

    #[test]
    fn rejects_inconsistent_locks() {
        // tampered manifest bytes: hash no longer matches
        let err = corrupt(|l| {
            let mut b = B64.decode(&l.models[0].manifest.b64).unwrap();
            b[10] ^= 1;
            l.models[0].manifest.b64 = b64_encode(&b);
        });
        assert!(matches!(err, LockError::Integrity(_)), "{err}");
        // a lying size figure
        let err = corrupt(|l| l.models[0].size_bytes += 1);
        assert!(matches!(err, LockError::Integrity(_)), "{err}");
        // a lying layer
        let err = corrupt(|l| l.models[0].layers[1].size += 1);
        assert!(matches!(err, LockError::Integrity(_)), "{err}");
        // an inline blob whose length contradicts the layer (declared or real)
        let err = corrupt(|l| l.models[0].layers[0].actual = Some(l.models[0].layers[0].size + 3));
        assert!(matches!(err, LockError::Integrity(_)), "{err}");
        // a pointless `actual`
        let err = corrupt(|l| l.models[0].layers[1].actual = Some(l.models[0].layers[1].size));
        assert!(matches!(err, LockError::Format(_)), "{err}");
        // inline blob that does not hash to its key
        let err = corrupt(|l| {
            let k = l.blobs_inline.keys().next().unwrap().clone();
            l.blobs_inline.insert(k, b64_encode(b"tampered"));
        });
        assert!(matches!(err, LockError::Integrity(_)), "{err}");
        // structural problems
        assert!(matches!(
            corrupt(|l| l.schema_version = 2),
            LockError::Format(_)
        ));
        assert!(matches!(
            corrupt(|l| l.models[0].source = "huggingface".into()),
            LockError::Format(_)
        ));
        assert!(matches!(
            corrupt(|l| {
                l.packs.insert("p".into(), vec!["ghost:1".into()]);
            }),
            LockError::Format(_)
        ));
        assert!(matches!(
            corrupt(|l| l.models[0].reference = "Nomic-Embed-Text:latest".into()),
            LockError::Format(_) | LockError::Integrity(_)
        ));
        assert!(
            matches!(
                corrupt(|l| {
                    l.blobs_inline.insert(
                        format!("sha256:{}", sha256_hex(b"orphan")),
                        b64_encode(b"orphan"),
                    );
                }),
                LockError::Format(_)
            ),
            "an inline blob nobody references is refused"
        );
        assert!(matches!(
            corrupt(|l| l.models[0].list_digest = Some("sha256:x".into())),
            LockError::Format(_)
        ));
        // names that would climb out of the manifests directory, or that exFAT cannot hold
        for evil in [
            "../evil:latest",
            "a/../b:c",
            "ns/..:x",
            "con:latest",
            "m:tag.",
            "x:._hidden",
            "/abs:1",
            "a\\b:1",
        ] {
            let err = corrupt(|l| l.models[0].reference = evil.into());
            assert!(matches!(err, LockError::Format(_)), "{evil}: {err}");
        }
        assert!(ModelLock::parse(b"{}").is_err());
        assert!(ModelLock::parse(b"not json").is_err());
        let mut extra: Value = serde_json::from_slice(&sample_lock().to_canonical_json()).unwrap();
        extra["surprise"] = json!(1);
        assert!(
            ModelLock::parse(extra.to_string().as_bytes()).is_err(),
            "unknown fields are refused"
        );
    }
}
