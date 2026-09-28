//! `bundle.json` — the versioned description of a Companion Stick image's contents.
//!
//! These Rust types are the source of truth for the format; `stick/schema/bundle.schema.json`
//! is the published mirror for non-Rust consumers and is kept in step by tests. Every struct
//! uses `deny_unknown_fields`: a manifest from a newer schema is rejected rather than half
//! understood.
//!
//! The file is signed as raw bytes (see [`crate::signing`]), so the serialisation must be
//! stable: [`Bundle::to_canonical_json`] emits fields in declaration order, 2-space indented,
//! with a trailing newline, and `lock` sorts `artifacts` by path.

use std::collections::BTreeSet;
use std::fmt;
use std::path::Path;

use anyhow::Context as _;
use serde::{Deserialize, Serialize};

use crate::hashing::is_sha256_hex;
use crate::layout::LayoutPlan;
use crate::paths::validate_rel_path;
use crate::timefmt::is_rfc3339_utc;

pub const SCHEMA_VERSION: u32 = 1;
pub const BUNDLE_FILE: &str = "bundle.json";
pub const SIGNATURE_FILE: &str = "bundle.json.sig";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Bundle {
    pub schema_version: u32,
    /// Stable identifier of the bundle line, e.g. `companion-stick-ubuntu`.
    pub id: String,
    /// Release version of this bundle, e.g. `2026.09.0`.
    pub version: String,
    /// RFC 3339 UTC, second precision.
    pub created_at: String,
    pub artifacts: Vec<Artifact>,
    pub model_packs: Vec<ModelPack>,
    /// The partition plan this bundle was built for.
    pub layout: LayoutPlan,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Artifact {
    /// `/`-separated, relative to the bundle root.
    pub path: String,
    pub kind: ArtifactKind,
    /// Lowercase hex SHA-256 of the file contents.
    pub sha256: String,
    pub size: u64,
    /// Host platforms this artifact is for; absent means platform-independent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platforms: Option<Vec<Platform>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ArtifactKind {
    BootImage,
    Installer,
    OciImage,
    ModelBlob,
    Doc,
    Tool,
    /// A UEFI bootloader binary (e.g. `efi/BOOTX64.EFI`) that `flash` installs into the ESP.
    Bootloader,
}

impl ArtifactKind {
    pub const ALL: [ArtifactKind; 7] = [
        Self::BootImage,
        Self::Installer,
        Self::OciImage,
        Self::ModelBlob,
        Self::Doc,
        Self::Tool,
        Self::Bootloader,
    ];

    /// Top-level staging directory that `lock` maps to this kind.
    pub fn staging_dir(self) -> &'static str {
        match self {
            Self::BootImage => "boot",
            Self::Installer => "installers",
            Self::OciImage => "oci",
            Self::ModelBlob => "models",
            Self::Doc => "docs",
            Self::Tool => "tools",
            Self::Bootloader => "efi",
        }
    }

    pub fn from_staging_dir(dir: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.staging_dir() == dir)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::BootImage => "boot-image",
            Self::Installer => "installer",
            Self::OciImage => "oci-image",
            Self::ModelBlob => "model-blob",
            Self::Doc => "doc",
            Self::Tool => "tool",
            Self::Bootloader => "bootloader",
        }
    }
}

/// Platform identifiers: host platforms (`<os>-<arch>`) for installers, tools and models,
/// and firmware platforms (`<arch>-<firmware>`) for bootloaders.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum Platform {
    #[serde(rename = "linux-x86_64")]
    LinuxX86_64,
    #[serde(rename = "linux-arm64")]
    LinuxArm64,
    #[serde(rename = "macos-arm64")]
    MacosArm64,
    #[serde(rename = "macos-x86_64")]
    MacosX86_64,
    #[serde(rename = "windows-x86_64")]
    WindowsX86_64,
    /// x86_64 UEFI firmware (a `BOOTX64.EFI` bootloader).
    #[serde(rename = "x86_64-uefi")]
    X86_64Uefi,
}

impl Platform {
    pub const ALL: [Platform; 6] = [
        Self::LinuxX86_64,
        Self::LinuxArm64,
        Self::MacosArm64,
        Self::MacosX86_64,
        Self::WindowsX86_64,
        Self::X86_64Uefi,
    ];

    /// Host operating-system platforms (valid for models, installers and tools).
    pub const HOST: [Platform; 5] = [
        Self::LinuxX86_64,
        Self::LinuxArm64,
        Self::MacosArm64,
        Self::MacosX86_64,
        Self::WindowsX86_64,
    ];

    /// Firmware platforms (valid for bootloaders only).
    pub fn is_firmware(self) -> bool {
        matches!(self, Self::X86_64Uefi)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::LinuxX86_64 => "linux-x86_64",
            Self::LinuxArm64 => "linux-arm64",
            Self::MacosArm64 => "macos-arm64",
            Self::MacosX86_64 => "macos-x86_64",
            Self::WindowsX86_64 => "windows-x86_64",
            Self::X86_64Uefi => "x86_64-uefi",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.as_str() == s)
    }
}

impl fmt::Display for Platform {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelPack {
    pub name: String,
    pub description: String,
    pub models: Vec<Model>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Model {
    /// Registry name, e.g. `qwen3`.
    pub name: String,
    /// Registry tag, e.g. `8b`.
    pub tag: String,
    /// `sha256:<hex>` of the resolved manifest/blob; `null` until `models lock` resolves it.
    pub digest: Option<String>,
    pub quantization: String,
    /// SPDX id or the licence's published name.
    pub license: String,
    pub size_bytes: u64,
    pub min_ram_gb: u32,
    /// `null` when the model runs acceptably on CPU / unified memory.
    pub min_vram_gb: Option<u32>,
    pub platforms: Vec<Platform>,
}

impl Model {
    /// `name:tag`, the identity used for de-duplication across packs.
    pub fn reference(&self) -> String {
        format!("{}:{}", self.name, self.tag)
    }
}

impl ModelPack {
    pub fn size_bytes(&self) -> u64 {
        self.models.iter().map(|m| m.size_bytes).sum()
    }
}

/// `true` for a well-formed `sha256:<64 lowercase hex>` model digest.
pub fn is_model_digest(s: &str) -> bool {
    s.strip_prefix("sha256:").is_some_and(is_sha256_hex)
}

fn is_identifier(s: &str) -> bool {
    let mut chars = s.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_lowercase() || c.is_ascii_digit())
        && chars
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '-'))
}

/// Semantic checks on model packs, shared by `bundle.json` and the pack catalog.
pub fn validate_packs(packs: &[ModelPack]) -> Vec<String> {
    let mut problems = Vec::new();
    let mut names = BTreeSet::new();
    for pack in packs {
        if !is_identifier(&pack.name) {
            problems.push(format!(
                "model pack name {:?} is not a lowercase identifier",
                pack.name
            ));
        }
        if !names.insert(pack.name.as_str()) {
            problems.push(format!("duplicate model pack {:?}", pack.name));
        }
        if pack.models.is_empty() {
            problems.push(format!("model pack {:?} has no models", pack.name));
        }
        let mut refs = BTreeSet::new();
        for m in &pack.models {
            let r = m.reference();
            if m.name.is_empty() || m.tag.is_empty() {
                problems.push(format!(
                    "pack {:?}: model with empty name or tag",
                    pack.name
                ));
            }
            if !refs.insert(r.clone()) {
                problems.push(format!("pack {:?}: duplicate model {r}", pack.name));
            }
            if let Some(d) = &m.digest {
                if !is_model_digest(d) {
                    problems.push(format!(
                        "pack {:?}: model {r} digest {d:?} is not sha256:<hex>",
                        pack.name
                    ));
                }
            }
            if m.size_bytes == 0 {
                problems.push(format!("pack {:?}: model {r} has size_bytes 0", pack.name));
            }
            if m.platforms.is_empty() {
                problems.push(format!(
                    "pack {:?}: model {r} lists no platforms",
                    pack.name
                ));
            }
            if let Some(p) = m.platforms.iter().find(|p| p.is_firmware()) {
                problems.push(format!(
                    "pack {:?}: model {r} lists firmware platform {p}; models run on host platforms",
                    pack.name
                ));
            }
        }
    }
    problems
}

impl Bundle {
    pub fn parse(bytes: &[u8]) -> anyhow::Result<Self> {
        serde_json::from_slice(bytes).context("bundle.json does not match the bundle schema")
    }

    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let bytes = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
        Self::parse(&bytes).with_context(|| format!("parsing {}", path.display()))
    }

    /// Stable serialisation: the exact bytes that get signed.
    pub fn to_canonical_json(&self) -> Vec<u8> {
        // Invariant, not a user-reachable failure: these types contain only strings,
        // integers, enums and vectors, which serde_json always serialises.
        let mut out = serde_json::to_vec_pretty(self).expect("bundle types always serialise");
        out.push(b'\n');
        out
    }

    /// Semantic validation beyond what serde enforces. Returns every problem found.
    pub fn validate(&self) -> Vec<String> {
        let mut problems = Vec::new();
        if self.schema_version != SCHEMA_VERSION {
            problems.push(format!(
                "unsupported schema_version {} (this ci-stick understands {SCHEMA_VERSION})",
                self.schema_version
            ));
        }
        if !is_identifier(&self.id) {
            problems.push(format!(
                "bundle id {:?} is not a lowercase identifier",
                self.id
            ));
        }
        if self.version.trim().is_empty() {
            problems.push("bundle version is empty".into());
        }
        if !is_rfc3339_utc(&self.created_at) {
            problems.push(format!(
                "created_at {:?} is not RFC 3339 UTC (YYYY-MM-DDTHH:MM:SSZ)",
                self.created_at
            ));
        }
        let mut seen = BTreeSet::new();
        for a in &self.artifacts {
            if let Err(e) = validate_rel_path(&a.path) {
                problems.push(format!("artifact path: {e}"));
            }
            if !seen.insert(a.path.as_str()) {
                problems.push(format!("duplicate artifact path {:?}", a.path));
            }
            if !is_sha256_hex(&a.sha256) {
                problems.push(format!(
                    "artifact {:?}: sha256 is not 64 lowercase hex",
                    a.path
                ));
            }
            if matches!(&a.platforms, Some(p) if p.is_empty()) {
                problems.push(format!(
                    "artifact {:?}: platforms is present but empty",
                    a.path
                ));
            }
            let platforms = a.platforms.as_deref().unwrap_or_default();
            let firmware = platforms.iter().filter(|p| p.is_firmware()).count();
            if a.kind == ArtifactKind::Bootloader {
                if firmware == 0 || firmware != platforms.len() {
                    problems.push(format!(
                        "artifact {:?}: a bootloader must list only firmware platforms (e.g. x86_64-uefi)",
                        a.path
                    ));
                }
            } else if firmware > 0 {
                problems.push(format!(
                    "artifact {:?}: firmware platforms are only valid on bootloader artifacts",
                    a.path
                ));
            }
        }
        problems.extend(validate_packs(&self.model_packs));
        if let Err(e) = self.layout.check_consistency() {
            problems.push(format!("layout: {e}"));
        }
        problems
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout;

    fn sample() -> Bundle {
        Bundle {
            schema_version: SCHEMA_VERSION,
            id: "companion-stick-ubuntu".into(),
            version: "2026.09.0".into(),
            created_at: "2026-09-28T12:00:00Z".into(),
            artifacts: vec![Artifact {
                path: "boot/ci-os.img".into(),
                kind: ArtifactKind::BootImage,
                sha256: crate::hashing::sha256_hex(b"x"),
                size: 1,
                platforms: Some(vec![Platform::LinuxX86_64]),
            }],
            model_packs: vec![ModelPack {
                name: "starter".into(),
                description: "d".into(),
                models: vec![Model {
                    name: "gemma3".into(),
                    tag: "1b".into(),
                    digest: None,
                    quantization: "Q4_K_M".into(),
                    license: "Gemma".into(),
                    size_bytes: 815_000_000,
                    min_ram_gb: 4,
                    min_vram_gb: None,
                    platforms: Platform::HOST.to_vec(),
                }],
            }],
            layout: layout::plan(512_000_000_000).unwrap(),
        }
    }

    #[test]
    fn round_trips_through_canonical_json() {
        let b = sample();
        assert!(b.validate().is_empty(), "{:?}", b.validate());
        let bytes = b.to_canonical_json();
        let back = Bundle::parse(&bytes).unwrap();
        assert_eq!(back, b);
        assert_eq!(
            back.to_canonical_json(),
            bytes,
            "serialisation must be stable"
        );
        let text = String::from_utf8(bytes).unwrap();
        assert!(
            text.contains("\"digest\": null"),
            "nullable digest must be explicit"
        );
        assert!(text.contains("\"kind\": \"boot-image\""));
        assert!(text.ends_with("}\n"));
    }

    #[test]
    fn rejects_unknown_fields() {
        let mut v: serde_json::Value =
            serde_json::from_slice(&sample().to_canonical_json()).unwrap();
        v["surprise"] = serde_json::json!(1);
        assert!(Bundle::parse(v.to_string().as_bytes()).is_err());
    }

    #[test]
    fn validation_catches_bad_fields() {
        let mut b = sample();
        b.schema_version = 99;
        b.artifacts[0].path = "../escape".into();
        b.artifacts[0].sha256 = "nope".into();
        b.model_packs[0].models[0].digest = Some("md5:abc".into());
        b.created_at = "yesterday".into();
        let problems = b.validate().join("\n");
        for needle in [
            "schema_version",
            "'..'",
            "sha256 is not",
            "digest",
            "created_at",
        ] {
            assert!(
                problems.contains(needle),
                "missing {needle:?} in:\n{problems}"
            );
        }
    }

    #[test]
    fn firmware_platforms_only_on_bootloaders() {
        let mut b = sample();
        b.artifacts.push(Artifact {
            path: "efi/BOOTX64.EFI".into(),
            kind: ArtifactKind::Bootloader,
            sha256: crate::hashing::sha256_hex(b"efi"),
            size: 3,
            platforms: Some(vec![Platform::X86_64Uefi]),
        });
        assert!(b.validate().is_empty(), "{:?}", b.validate());
        b.artifacts[1].platforms = Some(vec![Platform::LinuxX86_64]);
        assert!(b.validate().join("\n").contains("only firmware platforms"));
        b.artifacts[1].platforms = Some(vec![Platform::X86_64Uefi]);
        b.artifacts[0].platforms = Some(vec![Platform::X86_64Uefi]);
        assert!(b.validate().join("\n").contains("only valid on bootloader"));
        b.artifacts[0].platforms = None;
        b.model_packs[0].models[0].platforms = vec![Platform::X86_64Uefi];
        assert!(b.validate().join("\n").contains("firmware platform"));
    }

    #[test]
    fn kinds_and_platforms_have_stable_names() {
        for k in ArtifactKind::ALL {
            assert_eq!(ArtifactKind::from_staging_dir(k.staging_dir()), Some(k));
            let json = serde_json::to_string(&k).unwrap();
            assert_eq!(json, format!("\"{}\"", k.as_str()));
        }
        for p in Platform::ALL {
            assert_eq!(Platform::parse(p.as_str()), Some(p));
            assert_eq!(serde_json::to_string(&p).unwrap(), format!("\"{p}\""));
        }
    }
}
