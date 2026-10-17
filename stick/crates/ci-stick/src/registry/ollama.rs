//! Ollama registry formats: model references, manifests, manifest lists.
//!
//! Protocol facts this module encodes (verified live 2026-10-17, report 03 section 3.1):
//!
//! * `GET /v2/<ns>/<name>/manifests/<tag>` is anonymous. The body is byte-identical to the
//!   file Ollama stores. There is no digest header on GET; `HEAD` adds
//!   `ollama-content-digest` (lowercase hex, no `sha256:` prefix) and `ollama-push-time`.
//! * With Ollama's own `Accept` header ([`ACCEPT`]) a tag may be served as a **manifest
//!   list** (`application/vnd.ollama.manifest.list.v2+json`) whose children carry
//!   `runner`/`format` (`mlx`/`safetensors`, `llamacpp`/`gguf`). With the plain docker
//!   `Accept` the same tag returns the llama.cpp child directly.
//! * `GET /manifests/sha256:<digest>` is a 404 for every manifest: tags cannot be pinned by
//!   digest, which is why the lock carries the manifest bytes inline.
//! * A list's children ARE fetchable, as blobs: `GET /v2/<repo>/blobs/<child digest>`.
//! * Blob storage is global and content-addressed; a blob's bytes are a plain GGUF (model
//!   layer) or small JSON/text.

use std::fmt;

use serde::Deserialize;
use serde_json::Value;
use thiserror::Error;

use crate::cache::layout::{validate_component, DEFAULT_REGISTRY_HOST};
use crate::hashing::is_sha256_hex;

/// What Ollama 0.40 sends when it pulls a manifest.
pub const ACCEPT: &str =
    "application/vnd.ollama.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json";
pub const MT_MANIFEST: &str = "application/vnd.docker.distribution.manifest.v2+json";
pub const MT_MANIFEST_LIST: &str = "application/vnd.ollama.manifest.list.v2+json";
pub const MT_CONFIG: &str = "application/vnd.docker.container.image.v1+json";

pub const MAX_MANIFEST_BYTES: u64 = 1 << 20;
/// Blobs up to this size (config, params, template, system, licence) are stored in the lock.
pub const MAX_INLINE_BLOB_BYTES: u64 = 64 << 10;
pub const MAX_LAYERS: usize = 64;
/// Sanity cap on one model: nothing on a stick is larger than this.
pub const MAX_MODEL_BYTES: u64 = 2 << 40;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum RefError {
    #[error("model reference {0:?} is not valid (use name[:tag] or namespace/name[:tag])")]
    Invalid(String),
    #[error("Hugging Face references ({0:?}) are not supported by this release: it handles Ollama registry models only")]
    HuggingFace(String),
    #[error("model reference {0:?} names a registry host other than {DEFAULT_REGISTRY_HOST}; use --registry-url to choose a registry")]
    OtherHost(String),
}

/// `[namespace/]name[:tag]` on the Ollama registry.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ModelRef {
    pub namespace: String,
    pub name: String,
    pub tag: String,
}

#[derive(Clone, Copy)]
enum Part {
    Namespace,
    Name,
    Tag,
}

/// Ollama's `isValidPart` (types/model/name.go): first character alphanumeric or `_`, then
/// alphanumerics, `_`, `-`, and `.` (not in a namespace); 1 to 80 characters.
fn valid_part(kind: Part, s: &str) -> bool {
    if s.is_empty() || s.len() > 80 {
        return false;
    }
    s.bytes().enumerate().all(|(i, b)| {
        let alnum = b.is_ascii_alphanumeric() || b == b'_';
        if i == 0 {
            return alnum;
        }
        match b {
            b'_' | b'-' => true,
            b'.' => !matches!(kind, Part::Namespace),
            _ => alnum,
        }
    })
}

impl ModelRef {
    pub fn parse(input: &str) -> Result<Self, RefError> {
        let invalid = || RefError::Invalid(input.to_string());
        let s = input.trim();
        if s.is_empty() || s.len() > 300 {
            return Err(invalid());
        }
        // The tag is what follows the last ':' of the last path segment.
        let last_slash = s.rfind('/').map_or(0, |i| i + 1);
        let (path, tag) = match s[last_slash..].rfind(':') {
            Some(i) => (&s[..last_slash + i], &s[last_slash + i + 1..]),
            None => (s, "latest"),
        };
        let mut parts: Vec<&str> = path.split('/').collect();
        if parts.len() > 3 || parts.iter().any(|p| p.is_empty()) {
            return Err(invalid());
        }
        if parts.len() >= 2 {
            let first = parts[0].to_ascii_lowercase();
            if first == "hf.co" || first == "huggingface.co" {
                return Err(RefError::HuggingFace(input.to_string()));
            }
        }
        if parts.len() == 3 {
            if !parts[0].eq_ignore_ascii_case(DEFAULT_REGISTRY_HOST) {
                return Err(RefError::OtherHost(input.to_string()));
            }
            parts.remove(0);
        }
        let (namespace, name) = match parts.as_slice() {
            [name] => ("library", *name),
            [ns, name] => (*ns, *name),
            _ => return Err(invalid()),
        };
        if !valid_part(Part::Namespace, namespace)
            || !valid_part(Part::Name, name)
            || !valid_part(Part::Tag, tag)
        {
            return Err(invalid());
        }
        let r = ModelRef {
            namespace: namespace.to_string(),
            name: name.to_string(),
            tag: tag.to_string(),
        };
        // The pieces become directory names on exFAT: refuse what it cannot hold.
        for c in r.manifest_components() {
            validate_component(c).map_err(|_| invalid())?;
        }
        Ok(r)
    }

    /// `name:tag` for library models, `namespace/name:tag` otherwise (the `Model::reference()`
    /// spelling used in the pack catalog).
    pub fn reference(&self) -> String {
        if self.namespace == "library" {
            format!("{}:{}", self.name, self.tag)
        } else {
            format!("{}/{}:{}", self.namespace, self.name, self.tag)
        }
    }

    /// `library/gemma3`: the repository part of registry URLs.
    pub fn repo(&self) -> String {
        format!("{}/{}", self.namespace, self.name)
    }

    /// Directory components under `models/manifests/` where the daemon looks for this model.
    pub fn manifest_components(&self) -> [&str; 4] {
        [
            DEFAULT_REGISTRY_HOST,
            &self.namespace,
            &self.name,
            &self.tag,
        ]
    }
}

impl fmt::Display for ModelRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.reference())
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ManifestError {
    #[error("manifest is not valid JSON: {0}")]
    Json(String),
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Unsupported(String),
}

/// `sha256:<64 lowercase hex>`
pub fn is_digest(s: &str) -> bool {
    s.strip_prefix("sha256:").is_some_and(is_sha256_hex)
}

/// The hex part of a `sha256:` digest.
pub fn digest_hex(digest: &str) -> Option<&str> {
    digest.strip_prefix("sha256:").filter(|h| is_sha256_hex(h))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Layer {
    /// `config`, `model`, `projector`, `adapter`, `template`, `system`, `params`,
    /// `messages`, `license`, `embed` or `draft`.
    pub role: String,
    pub media_type: String,
    pub digest: String,
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    /// Config first, then the layers in manifest order.
    pub layers: Vec<Layer>,
    pub runner: Option<String>,
    pub format: Option<String>,
    /// Sum of all sizes (what the pack catalog calls `size_bytes`).
    pub size_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListEntry {
    pub digest: String,
    pub runner: Option<String>,
    pub format: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Parsed {
    Manifest(Manifest),
    List(Vec<ListEntry>),
}

#[derive(Deserialize)]
struct RawDescriptor {
    #[serde(rename = "mediaType")]
    media_type: String,
    digest: String,
    size: u64,
}

#[derive(Deserialize)]
struct RawManifest {
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
    config: RawDescriptor,
    layers: Vec<RawDescriptor>,
    runner: Option<String>,
    format: Option<String>,
}

#[derive(Deserialize)]
struct RawListEntry {
    digest: String,
    runner: Option<String>,
    format: Option<String>,
}

#[derive(Deserialize)]
struct RawList {
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
    manifests: Vec<RawListEntry>,
}

/// Layer media types a stick can use. `image.tensor`/`image.json` (safetensors models) and
/// anything unknown are refused: this tool carries GGUF models only.
fn role_for(media_type: &str) -> Option<&'static str> {
    Some(match media_type {
        "application/vnd.ollama.image.model" => "model",
        "application/vnd.ollama.image.projector" => "projector",
        "application/vnd.ollama.image.adapter" => "adapter",
        "application/vnd.ollama.image.template" => "template",
        "application/vnd.ollama.image.system" => "system",
        "application/vnd.ollama.image.params" => "params",
        "application/vnd.ollama.image.messages" => "messages",
        "application/vnd.ollama.image.license" => "license",
        "application/vnd.ollama.image.embed" => "embed",
        "application/vnd.ollama.image.draft" => "draft",
        _ => return None,
    })
}

/// Parse and validate a manifest or manifest list. Never panics on remote data.
pub fn parse(bytes: &[u8]) -> Result<Parsed, ManifestError> {
    if bytes.len() as u64 > MAX_MANIFEST_BYTES {
        return Err(ManifestError::Invalid(format!(
            "manifest is {} bytes; the limit is {MAX_MANIFEST_BYTES}",
            bytes.len()
        )));
    }
    let value: Value =
        serde_json::from_slice(bytes).map_err(|e| ManifestError::Json(e.to_string()))?;
    let media_type = value.get("mediaType").and_then(Value::as_str).unwrap_or("");
    if media_type == MT_MANIFEST_LIST || value.get("manifests").is_some() {
        let raw: RawList =
            serde_json::from_value(value).map_err(|e| ManifestError::Json(e.to_string()))?;
        if raw.schema_version != 2 {
            return Err(ManifestError::Unsupported(format!(
                "manifest list schemaVersion {} is not supported",
                raw.schema_version
            )));
        }
        if raw.manifests.is_empty() || raw.manifests.len() > 16 {
            return Err(ManifestError::Invalid(
                "manifest list has no entries or too many".into(),
            ));
        }
        let mut out = Vec::new();
        for m in raw.manifests {
            if !is_digest(&m.digest) {
                return Err(ManifestError::Invalid(format!(
                    "list entry digest {:?} is not sha256:<hex>",
                    m.digest
                )));
            }
            out.push(ListEntry {
                digest: m.digest,
                runner: m.runner,
                format: m.format,
            });
        }
        return Ok(Parsed::List(out));
    }
    let raw: RawManifest =
        serde_json::from_value(value).map_err(|e| ManifestError::Json(e.to_string()))?;
    if raw.schema_version != 2 {
        return Err(ManifestError::Unsupported(format!(
            "manifest schemaVersion {} is not supported",
            raw.schema_version
        )));
    }
    if let Some(r) = &raw.runner {
        if !matches!(r.as_str(), "llamacpp" | "ggml") {
            return Err(ManifestError::Unsupported(format!(
                "manifest is for runner {r:?}; only llama.cpp (GGUF) models are carried"
            )));
        }
    }
    if let Some(f) = &raw.format {
        if f != "gguf" {
            return Err(ManifestError::Unsupported(format!(
                "manifest format is {f:?}; only GGUF models are carried"
            )));
        }
    }
    if raw.config.media_type != MT_CONFIG {
        return Err(ManifestError::Invalid(format!(
            "config media type {:?} is not {MT_CONFIG}",
            raw.config.media_type
        )));
    }
    if raw.layers.is_empty() || raw.layers.len() > MAX_LAYERS {
        return Err(ManifestError::Invalid(format!(
            "manifest has {} layers; 1 to {MAX_LAYERS} are accepted",
            raw.layers.len()
        )));
    }
    let mut layers = Vec::with_capacity(raw.layers.len() + 1);
    let mut total: u64 = 0;
    let mut add =
        |role: &str, d: RawDescriptor, layers: &mut Vec<Layer>| -> Result<(), ManifestError> {
            if !is_digest(&d.digest) {
                return Err(ManifestError::Invalid(format!(
                    "digest {:?} is not sha256:<hex>",
                    d.digest
                )));
            }
            if d.size > MAX_MODEL_BYTES {
                return Err(ManifestError::Invalid(format!(
                    "layer size {} is implausible",
                    d.size
                )));
            }
            total = total
                .checked_add(d.size)
                .filter(|t| *t <= MAX_MODEL_BYTES)
                .ok_or_else(|| ManifestError::Invalid("model size is implausible".into()))?;
            layers.push(Layer {
                role: role.to_string(),
                media_type: d.media_type,
                digest: d.digest,
                size: d.size,
            });
            Ok(())
        };
    add("config", raw.config, &mut layers)?;
    for l in raw.layers {
        let Some(role) = role_for(&l.media_type) else {
            return Err(ManifestError::Unsupported(format!(
                "layer media type {:?} is not carried (GGUF models only; safetensors/tensor layers are refused)",
                l.media_type
            )));
        };
        add(role, l, &mut layers)?;
    }
    if !layers.iter().any(|l| l.role == "model") {
        return Err(ManifestError::Invalid("manifest has no model layer".into()));
    }
    Ok(Parsed::Manifest(Manifest {
        layers,
        runner: raw.runner,
        format: raw.format,
        size_bytes: total,
    }))
}

/// Choose the child a GGUF stick wants: llama.cpp/GGUF first, then the older `ggml` runner.
pub fn select_child(entries: &[ListEntry]) -> Option<&ListEntry> {
    let pick = |runner: &str| {
        entries
            .iter()
            .find(|e| e.runner.as_deref() == Some(runner) && e.format.as_deref() == Some("gguf"))
    };
    pick("llamacpp").or_else(|| pick("ggml"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn references() {
        let r = ModelRef::parse("gemma3:1b").unwrap();
        assert_eq!(
            (r.namespace.as_str(), r.name.as_str(), r.tag.as_str()),
            ("library", "gemma3", "1b")
        );
        assert_eq!(r.reference(), "gemma3:1b");
        assert_eq!(r.repo(), "library/gemma3");
        assert_eq!(
            r.manifest_components(),
            ["registry.ollama.ai", "library", "gemma3", "1b"]
        );
        assert_eq!(
            ModelRef::parse("nomic-embed-text").unwrap().reference(),
            "nomic-embed-text:latest"
        );
        assert_eq!(ModelRef::parse("qwen3.5:0.8b").unwrap().tag, "0.8b");
        let ns = ModelRef::parse("huihui_ai/qwen3:8b-q4_K_M").unwrap();
        assert_eq!(ns.reference(), "huihui_ai/qwen3:8b-q4_K_M");
        assert_eq!(ns.repo(), "huihui_ai/qwen3");
        let host = ModelRef::parse("registry.ollama.ai/library/gemma3:1b").unwrap();
        assert_eq!(host.reference(), "gemma3:1b");
        assert!(matches!(
            ModelRef::parse("hf.co/unsloth/x-GGUF:Q4_K_M"),
            Err(RefError::HuggingFace(_))
        ));
        assert!(matches!(
            ModelRef::parse("example.com/a/b:c"),
            Err(RefError::OtherHost(_))
        ));
        for bad in [
            "",
            ":",
            "a:",
            ":b",
            "a/b/c/d",
            "../x",
            "a/../b",
            "a b",
            "a:b:c",
            "-x",
            ".x",
            "x.",
            "a/.b",
            "con",
            "name:con",
            "x:tag.",
            "_ok_:fine/",
            "ns.dot/name",
        ] {
            assert!(ModelRef::parse(bad).is_err(), "{bad:?} must be refused");
        }
        assert!(ModelRef::parse(&format!("{}:1", "a".repeat(81))).is_err());
    }

    const NOMIC: &str =
        include_str!("../../tests/fixtures/models/manifests/nomic-embed-text.latest.v2.json");

    #[test]
    fn parses_a_real_manifest() {
        let Parsed::Manifest(m) = parse(NOMIC.as_bytes()).unwrap() else {
            panic!("not a manifest")
        };
        assert_eq!(m.size_bytes, 274_302_450, "same figure as model-packs.yaml");
        let roles: Vec<&str> = m.layers.iter().map(|l| l.role.as_str()).collect();
        assert_eq!(roles, ["config", "model", "license", "params"]);
        assert_eq!(m.layers[1].size, 274_290_656);
        assert!(m.runner.is_none());
    }

    #[test]
    fn parses_a_list_and_picks_the_gguf_child() {
        let list =
            include_str!("../../tests/fixtures/models/manifests/qwen3.6.27b.list-accept.json");
        let Parsed::List(entries) = parse(list.as_bytes()).unwrap() else {
            panic!("not a list")
        };
        assert_eq!(entries.len(), 2);
        assert_eq!(
            entries[0].runner.as_deref(),
            Some("mlx"),
            "mlx is listed first on purpose"
        );
        let child = select_child(&entries).unwrap();
        assert_eq!(child.runner.as_deref(), Some("llamacpp"));
        assert_eq!(
            child.digest,
            "sha256:bcbdbd4bcf86f2c4a56cd1698fb31f9434f7dd99752f71b636c750aaa67a49a5"
        );
        let only_mlx = &entries[..1];
        assert!(select_child(only_mlx).is_none());
        let child =
            include_str!("../../tests/fixtures/models/manifests/qwen3.6.27b.child-llamacpp.json");
        let Parsed::Manifest(m) = parse(child.as_bytes()).unwrap() else {
            panic!()
        };
        assert_eq!(m.runner.as_deref(), Some("llamacpp"));
        assert_eq!(m.size_bytes, 17_769_076_933);
        assert_eq!(m.layers.iter().filter(|l| l.role == "projector").count(), 1);
    }

    fn digest(c: char) -> String {
        format!("sha256:{}", c.to_string().repeat(64))
    }

    fn manifest_json(layer_type: &str, extra: &str) -> String {
        format!(
            r#"{{"schemaVersion":2,"mediaType":"{MT_MANIFEST}","config":{{"mediaType":"{MT_CONFIG}","digest":"{}","size":10}},"layers":[{{"mediaType":"{layer_type}","digest":"{}","size":20}}]{extra}}}"#,
            digest('a'),
            digest('b')
        )
    }

    #[test]
    fn refuses_what_a_gguf_stick_cannot_use() {
        let model = "application/vnd.ollama.image.model";
        assert!(parse(manifest_json(model, "").as_bytes()).is_ok());
        for (mt, extra) in [
            ("application/vnd.ollama.image.tensor", ""),
            ("application/vnd.ollama.image.json", ""),
            ("application/x-unknown", ""),
            (model, r#","runner":"mlx""#),
            (model, r#","format":"safetensors""#),
        ] {
            let err = parse(manifest_json(mt, extra).as_bytes()).unwrap_err();
            assert!(
                matches!(err, ManifestError::Unsupported(_)),
                "{mt} {extra}: {err}"
            );
        }
        // structural problems
        let bad_digest = manifest_json(model, "").replace(&digest('b'), "sha256:XYZ");
        assert!(matches!(
            parse(bad_digest.as_bytes()),
            Err(ManifestError::Invalid(_))
        ));
        let upper =
            manifest_json(model, "").replace(&digest('b'), &format!("sha256:{}", "B".repeat(64)));
        assert!(
            parse(upper.as_bytes()).is_err(),
            "digests are lowercase only"
        );
        let no_model = manifest_json("application/vnd.ollama.image.license", "");
        assert!(
            parse(no_model.as_bytes()).is_err(),
            "a model layer is required"
        );
        let v1 = manifest_json(model, "").replace("\"schemaVersion\":2", "\"schemaVersion\":1");
        assert!(parse(v1.as_bytes()).is_err());
        assert!(parse(b"not json").is_err());
        assert!(parse(b"{}").is_err());
        assert!(parse(b"[]").is_err());
        assert!(parse(&vec![b' '; (MAX_MANIFEST_BYTES + 1) as usize]).is_err());
        let wrong_config = manifest_json(model, "").replace(MT_CONFIG, "application/json");
        assert!(parse(wrong_config.as_bytes()).is_err());
        // sizes that overflow or are absurd
        let huge = manifest_json(model, "").replace("\"size\":20", "\"size\":18446744073709551615");
        assert!(parse(huge.as_bytes()).is_err());
        // too many layers
        let layer = format!(
            r#"{{"mediaType":"{model}","digest":"{}","size":1}}"#,
            digest('c')
        );
        let many = format!(
            r#"{{"schemaVersion":2,"config":{{"mediaType":"{MT_CONFIG}","digest":"{}","size":1}},"layers":[{}]}}"#,
            digest('a'),
            vec![layer; MAX_LAYERS + 1].join(",")
        );
        assert!(parse(many.as_bytes()).is_err());
        // empty or bad lists
        assert!(parse(br#"{"schemaVersion":2,"mediaType":"application/vnd.ollama.manifest.list.v2+json","manifests":[]}"#).is_err());
        let bad_list = r#"{"schemaVersion":2,"manifests":[{"digest":"sha256:zz","runner":"llamacpp","format":"gguf"}]}"#;
        assert!(parse(bad_list.as_bytes()).is_err());
    }
}
