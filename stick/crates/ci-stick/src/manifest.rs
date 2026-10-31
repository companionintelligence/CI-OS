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
//!
//! Two schema versions exist. Version 1 is the original format. Version 2 adds `sequence`
//! and `expires_at` (right after `created_at`) so that an old or expired bundle can be
//! refused (see [`crate::verify`] and [`crate::state`]); both fields are absent from version
//! 1 and the version 1 bytes are unchanged, so signed version 1 bundles stay valid.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::Path;

use anyhow::Context as _;
use serde::{Deserialize, Serialize};

use crate::hashing::is_sha256_hex;
use crate::layout::LayoutPlan;
use crate::paths::validate_rel_path;
use crate::timefmt::{is_rfc3339_utc, parse_rfc3339_utc};

/// The original format: no `sequence`, no `expires_at`.
pub const SCHEMA_V1: u32 = 1;
/// Adds `sequence` and `expires_at`, both required.
pub const SCHEMA_V2: u32 = 2;
/// Every `schema_version` this ci-stick reads; `bundle.schema.json` lists the same values.
pub const SUPPORTED_SCHEMA_VERSIONS: [u32; 2] = [SCHEMA_V1, SCHEMA_V2];
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
    /// Schema 2 only (required there, forbidden in schema 1): the release counter of this
    /// bundle `id`, 1 or more, increasing with every release. The release pipeline assigns it.
    /// A machine that has accepted sequence N refuses a lower one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sequence: Option<u64>,
    /// Schema 2 only (required there, forbidden in schema 1): RFC 3339 UTC, second precision,
    /// after `created_at`. From this instant on the bundle is refused.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
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
    /// Bootloader artifacts only (required there): which link of the boot chain this is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bootloader_role: Option<BootloaderRole>,
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
    /// A UEFI bootloader binary (`efi/shimx64.efi`, `efi/BOOTX64.EFI`, ...) that `flash`
    /// installs into the ESP. Its [`BootloaderRole`] says which link of which chain it is.
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

/// One link of a boot chain. The staging file name under `efi/` decides it (see
/// [`BootloaderRole::from_file_name`]); `flash` decides where on the ESP it goes
/// ([`crate::bootcfg::esp_binaries`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum BootloaderRole {
    /// `shimx64.efi`: Microsoft-signed shim (Ubuntu `shim-signed`). Secure chain.
    Shim,
    /// `grubx64.efi`: Canonical-signed monolithic GRUB (`grub-efi-amd64-signed`). Secure chain.
    Grub,
    /// `mmx64.efi`: MokManager, Canonical-signed, shipped for recovery. Secure chain.
    MokManager,
    /// `BOOTX64.EFI`: unsigned standalone GRUB from `stick/scripts/build-grub-efi.sh`.
    /// Development chain: firmware with Secure Boot enabled refuses it.
    StandaloneGrub,
}

impl BootloaderRole {
    pub const ALL: [BootloaderRole; 4] = [
        Self::Shim,
        Self::Grub,
        Self::MokManager,
        Self::StandaloneGrub,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Shim => "shim",
            Self::Grub => "grub",
            Self::MokManager => "mok-manager",
            Self::StandaloneGrub => "standalone-grub",
        }
    }

    /// The (case-sensitive) staging file name under `efi/`.
    pub fn file_name(self) -> &'static str {
        match self {
            Self::Shim => "shimx64.efi",
            Self::Grub => "grubx64.efi",
            Self::MokManager => "mmx64.efi",
            Self::StandaloneGrub => "BOOTX64.EFI",
        }
    }

    pub fn from_file_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|r| r.file_name() == name)
    }

    /// Every role is an x86_64 UEFI binary today.
    pub fn platform(self) -> Platform {
        Platform::X86_64Uefi
    }

    pub fn chain(self) -> BootChain {
        match self {
            Self::Shim | Self::Grub | Self::MokManager => BootChain::Secure,
            Self::StandaloneGrub => BootChain::Development,
        }
    }
}

impl fmt::Display for BootloaderRole {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Which boot chain a bundle carries: exactly one, or none (a bundle without a bootloader
/// can be verified but not flashed).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum BootChain {
    /// Firmware db (Microsoft UEFI CA) -> shim -> Canonical GRUB -> Canonical-signed kernel.
    Secure,
    /// Unsigned standalone GRUB: boots only with Secure Boot disabled.
    Development,
}

impl BootChain {
    pub fn roles(self) -> &'static [BootloaderRole] {
        match self {
            Self::Secure => &[
                BootloaderRole::Shim,
                BootloaderRole::Grub,
                BootloaderRole::MokManager,
            ],
            Self::Development => &[BootloaderRole::StandaloneGrub],
        }
    }

    /// The one-line Secure Boot statement shown by `flash` (plan), `verify` and `doctor`.
    pub fn secure_boot_line(self) -> &'static str {
        match self {
            Self::Secure => "Secure Boot: supported (shim → Canonical GRUB)",
            Self::Development => {
                "Secure Boot: NOT supported (unsigned development GRUB) — disable Secure Boot \
                 to boot this stick"
            }
        }
    }

    /// The staging files that make up this chain, e.g. `efi/shimx64.efi + ...`.
    pub fn staged_files(self) -> String {
        self.roles()
            .iter()
            .map(|r| format!("efi/{}", r.file_name()))
            .collect::<Vec<_>>()
            .join(" + ")
    }
}

/// Work out which boot chain `artifacts` carry. `Err` explains why they are not exactly one
/// complete chain (both chains, an incomplete secure chain, a duplicated role).
pub fn detect_boot_chain(artifacts: &[Artifact]) -> Result<Option<BootChain>, String> {
    let mut seen: Vec<BootloaderRole> = Vec::new();
    for a in artifacts
        .iter()
        .filter(|a| a.kind == ArtifactKind::Bootloader)
    {
        let Some(role) = a.bootloader_role else {
            return Err(format!("bootloader {:?} has no bootloader_role", a.path));
        };
        if seen.contains(&role) {
            return Err(format!(
                "more than one {role} bootloader (another besides {:?}); a bundle carries one boot chain",
                a.path
            ));
        }
        seen.push(role);
    }
    let has = |c: BootChain| seen.iter().any(|r| r.chain() == c);
    match (has(BootChain::Secure), has(BootChain::Development)) {
        (false, false) => Ok(None),
        (true, true) => Err(format!(
            "the bundle carries both the Secure Boot chain ({}) and the development chain ({}); \
             stage exactly one",
            BootChain::Secure.staged_files(),
            BootChain::Development.staged_files()
        )),
        (true, false) => {
            let missing: Vec<String> = BootChain::Secure
                .roles()
                .iter()
                .filter(|r| !seen.contains(r))
                .map(|r| format!("efi/{}", r.file_name()))
                .collect();
            if missing.is_empty() {
                Ok(Some(BootChain::Secure))
            } else {
                Err(format!(
                    "incomplete Secure Boot chain: missing {} (the chain is {})",
                    missing.join(", "),
                    BootChain::Secure.staged_files()
                ))
            }
        }
        (false, true) => Ok(Some(BootChain::Development)),
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

/// Where a model's bytes come from. It is decided by how [`Model::name`] is spelled, never by
/// an extra field: the `Model` record and `schema_version` stay as they are (decision D2 in
/// `docs/architecture/models-tooling.md`), and a Hugging Face model is spelled the way CI Hub's
/// curated catalog and Ollama itself spell it, `hf.co/<org>/<repo>` with the quantization label
/// (or file name) as `tag`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ModelSource {
    /// `registry.ollama.ai`: `name` is `<model>` or `<namespace>/<model>`.
    Ollama,
    /// `huggingface.co` through its Ollama-compatible registry endpoint: `name` is
    /// `hf.co/<org>/<repo>`.
    HuggingFace,
}

/// Name prefix that marks a Hugging Face model.
pub const HF_NAME_PREFIX: &str = "hf.co/";

impl Model {
    /// `name:tag`, the identity used for de-duplication across packs. For a Hugging Face model
    /// this is exactly the Ollama reference `hf.co/<org>/<repo>:<quant>`.
    pub fn reference(&self) -> String {
        format!("{}:{}", self.name, self.tag)
    }

    pub fn source(&self) -> ModelSource {
        if self.name.starts_with(HF_NAME_PREFIX) {
            ModelSource::HuggingFace
        } else {
            ModelSource::Ollama
        }
    }

    /// `(org, repo)` for a Hugging Face model whose name has the exact shape
    /// `hf.co/<org>/<repo>`.
    pub fn hf_repo(&self) -> Option<(&str, &str)> {
        let rest = self.name.strip_prefix(HF_NAME_PREFIX)?;
        let (org, repo) = rest.split_once('/')?;
        (!repo.contains('/')).then_some((org, repo))
    }

    /// Why `name` and `tag` are not an acceptable model reference, if they are not. This is the
    /// catalog grammar, stricter than the bundle schema (which only demands a non-empty string,
    /// and stays that way until the next `schema_version`): the strings become file names on an
    /// exFAT volume (`models/manifests/<host>/<namespace>/<name>/<tag>`), so they must be
    /// portable, and a tag that names a cloud-only model has no weights to download.
    pub fn ref_problem(&self) -> Option<String> {
        let r = self.reference();
        let problem = match self.source() {
            ModelSource::HuggingFace => match self.hf_repo() {
                Some((org, repo)) => hf_id_problem(org)
                    .map(|p| format!("organisation {org:?}: {p}"))
                    .or_else(|| hf_id_problem(repo).map(|p| format!("repository {repo:?}: {p}"))),
                None => Some("a Hugging Face name must be exactly hf.co/<org>/<repo>".to_string()),
            },
            ModelSource::Ollama => {
                let parts: Vec<&str> = self.name.split('/').collect();
                if parts.len() > 2 {
                    Some(
                        "an Ollama name is <model> or <namespace>/<model> (a registry host \
                         is not allowed; Hugging Face models are spelled hf.co/<org>/<repo>)"
                            .to_string(),
                    )
                } else {
                    parts
                        .iter()
                        .find_map(|p| part_problem(p).map(|e| format!("{p:?}: {e}")))
                }
            }
        };
        let problem = problem.or_else(|| part_problem(&self.tag).map(|e| format!("tag: {e}")));
        let problem = problem.or_else(|| {
            (self.source() == ModelSource::Ollama && is_cloud_tag(&self.tag))
                .then(|| "a :cloud tag has no weights to carry".to_string())
        });
        problem.map(|p| format!("model reference {r:?}: {p}"))
    }
}

fn is_cloud_tag(tag: &str) -> bool {
    tag == "cloud" || tag.ends_with("-cloud")
}

/// Windows device names, which exFAT can hold but Windows cannot open (with or without an
/// extension), so a model or tag spelled like one would be unreadable on a Windows host.
fn is_windows_reserved(part: &str) -> bool {
    let stem = part.split('.').next().unwrap_or(part).to_ascii_uppercase();
    matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && matches!(stem.as_bytes()[3], b'1'..=b'9'))
}

/// One path-safe component of a model reference (an Ollama name part or a tag): 1 to 80 characters
/// of `[A-Za-z0-9_.-]`, starting with a letter, digit or `_` and not ending in `.` (the rule
/// Ollama applies to its parts, plus Windows' no-trailing-dot and device-name rules).
fn part_problem(p: &str) -> Option<String> {
    let Some(first) = p.chars().next() else {
        return Some("is empty".into());
    };
    if p.chars().count() > 80 {
        return Some("is longer than 80 characters".into());
    }
    if !(first.is_ascii_alphanumeric() || first == '_') {
        return Some("must start with a letter, digit or '_'".into());
    }
    if let Some(bad) = p
        .chars()
        .find(|c| !(c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-')))
    {
        return Some(format!("contains {bad:?}; only [A-Za-z0-9_.-] is allowed"));
    }
    if p.ends_with('.') {
        return Some("must not end with '.' (Windows cannot open such a file)".into());
    }
    if is_windows_reserved(p) {
        return Some("is a Windows device name".into());
    }
    None
}

/// A Hugging Face organisation or repository id: Hugging Face's own rule (1 to 96 characters of
/// `[A-Za-z0-9_.-]`, starting and ending with a word character, no `--` and no `..`), plus the
/// Windows device-name rule.
fn hf_id_problem(id: &str) -> Option<String> {
    let is_word = |c: char| c.is_ascii_alphanumeric() || c == '_';
    if id.is_empty() || id.chars().count() > 96 {
        return Some("must be 1 to 96 characters".into());
    }
    if let Some(bad) = id
        .chars()
        .find(|&c| !(is_word(c) || matches!(c, '.' | '-')))
    {
        return Some(format!("contains {bad:?}; only [A-Za-z0-9_.-] is allowed"));
    }
    if !id.starts_with(is_word) || !id.ends_with(is_word) {
        return Some("must start and end with a letter, digit or '_'".into());
    }
    if id.contains("--") || id.contains("..") {
        return Some("must not contain '--' or '..'".into());
    }
    if is_windows_reserved(id) {
        return Some("is a Windows device name".into());
    }
    None
}

/// Problems with the *spelling* of every model reference in `packs`: each [`Model::ref_problem`],
/// plus two references that differ only by case (exFAT is case-insensitive: they would be one
/// file). Used by the pack catalog loader. Deliberately not part of [`validate_packs`], which
/// also runs on signed `bundle.json` files whose schema this release does not tighten.
pub fn model_ref_problems(packs: &[ModelPack]) -> Vec<String> {
    let mut problems = Vec::new();
    let mut seen = BTreeSet::new();
    let mut folded: BTreeMap<String, String> = BTreeMap::new();
    for m in packs.iter().flat_map(|p| &p.models) {
        let r = m.reference();
        // Packs share models (YAML aliases), so judge each distinct reference once.
        if !seen.insert(r.clone()) {
            continue;
        }
        if let Some(p) = m.ref_problem() {
            problems.push(p);
            continue;
        }
        match folded.get(&r.to_ascii_lowercase()) {
            Some(first) => problems.push(format!(
                "model references {first:?} and {r:?} differ only by case (exFAT would treat them as one file)"
            )),
            None => {
                folded.insert(r.to_ascii_lowercase(), r);
            }
        }
    }
    problems
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

    /// `created_at` as Unix seconds, if it is a real instant.
    pub fn created_unix(&self) -> Option<u64> {
        parse_rfc3339_utc(&self.created_at)
    }

    /// `expires_at` as Unix seconds, if present and a real instant.
    pub fn expires_unix(&self) -> Option<u64> {
        self.expires_at.as_deref().and_then(parse_rfc3339_utc)
    }

    /// The schema 2 rules: both fields present, `sequence` 1 or more, `expires_at` a real
    /// instant after `created_at`.
    fn validate_freshness(&self, problems: &mut Vec<String>) {
        match self.sequence {
            None => problems.push("schema_version 2 requires sequence".into()),
            Some(0) => problems.push("sequence must be 1 or more".into()),
            Some(_) => {}
        }
        let Some(expires_at) = &self.expires_at else {
            problems.push("schema_version 2 requires expires_at".into());
            return;
        };
        let Some(expires) = parse_rfc3339_utc(expires_at) else {
            problems.push(format!(
                "expires_at {expires_at:?} is not an RFC 3339 UTC instant (YYYY-MM-DDTHH:MM:SSZ)"
            ));
            return;
        };
        match self.created_unix() {
            None => problems.push(format!(
                "created_at {:?} is not a real RFC 3339 UTC instant, so expires_at cannot be \
                 compared with it",
                self.created_at
            )),
            Some(created) if expires <= created => problems.push(format!(
                "expires_at {expires_at} is not after created_at {}",
                self.created_at
            )),
            Some(_) => {}
        }
    }

    /// The boot chain this bundle carries (see [`detect_boot_chain`]).
    pub fn boot_chain(&self) -> Result<Option<BootChain>, String> {
        detect_boot_chain(&self.artifacts)
    }

    /// The bootloader artifact playing `role`, if any.
    pub fn bootloader(&self, role: BootloaderRole) -> Option<&Artifact> {
        self.artifacts
            .iter()
            .find(|a| a.kind == ArtifactKind::Bootloader && a.bootloader_role == Some(role))
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
        match self.schema_version {
            SCHEMA_V1 => {
                if self.sequence.is_some() || self.expires_at.is_some() {
                    problems.push(
                        "sequence and expires_at belong to schema_version 2; schema_version 1 \
                         does not have them"
                            .into(),
                    );
                }
            }
            SCHEMA_V2 => self.validate_freshness(&mut problems),
            other => problems.push(format!(
                "unsupported schema_version {other} (this ci-stick understands 1 and 2)"
            )),
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
                if a.bootloader_role.is_none() {
                    problems.push(format!(
                        "artifact {:?}: a bootloader must have a bootloader_role",
                        a.path
                    ));
                }
            } else {
                if firmware > 0 {
                    problems.push(format!(
                        "artifact {:?}: firmware platforms are only valid on bootloader artifacts",
                        a.path
                    ));
                }
                if a.bootloader_role.is_some() {
                    problems.push(format!(
                        "artifact {:?}: bootloader_role is only valid on bootloader artifacts",
                        a.path
                    ));
                }
            }
        }
        if let Err(e) = detect_boot_chain(&self.artifacts) {
            problems.push(e);
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
            schema_version: SCHEMA_V1,
            id: "companion-stick-ubuntu".into(),
            version: "2026.09.0".into(),
            created_at: "2026-09-28T12:00:00Z".into(),
            sequence: None,
            expires_at: None,
            artifacts: vec![Artifact {
                path: "boot/ci-os.img".into(),
                kind: ArtifactKind::BootImage,
                sha256: crate::hashing::sha256_hex(b"x"),
                size: 1,
                platforms: Some(vec![Platform::LinuxX86_64]),
                bootloader_role: None,
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

    fn sample_v2() -> Bundle {
        Bundle {
            schema_version: SCHEMA_V2,
            sequence: Some(3),
            expires_at: Some("2027-09-28T12:00:00Z".into()),
            ..sample()
        }
    }

    #[test]
    fn schema_1_bytes_carry_neither_new_key() {
        // The two keys are skipped when absent, so a signed schema 1 bundle stays valid and a
        // re-lock of one rewrites the same bytes.
        let text = String::from_utf8(sample().to_canonical_json()).unwrap();
        assert!(!text.contains("sequence"), "{text}");
        assert!(!text.contains("expires_at"), "{text}");
    }

    #[test]
    fn schema_2_round_trips_with_the_new_keys_after_created_at() {
        let b = sample_v2();
        assert!(b.validate().is_empty(), "{:?}", b.validate());
        let bytes = b.to_canonical_json();
        assert_eq!(Bundle::parse(&bytes).unwrap(), b);
        let text = String::from_utf8(bytes).unwrap();
        let at = |key: &str| {
            text.find(key)
                .unwrap_or_else(|| panic!("{key} missing:\n{text}"))
        };
        assert!(at("\"created_at\"") < at("\"sequence\""));
        assert!(at("\"sequence\"") < at("\"expires_at\""));
        assert!(at("\"expires_at\"") < at("\"artifacts\""));
        assert!(text.contains("\"sequence\": 3,"), "{text}");
        assert_eq!(b.expires_unix(), Some(1_822_132_800));
        assert_eq!(b.created_unix(), Some(1_790_596_800));
    }

    #[test]
    fn schema_2_rules_and_schema_1_exclusions() {
        type Mutation = (&'static str, fn(&mut Bundle), &'static str);
        let cases: Vec<Mutation> = vec![
            ("no sequence", |b| b.sequence = None, "requires sequence"),
            (
                "no expires_at",
                |b| b.expires_at = None,
                "requires expires_at",
            ),
            ("sequence 0", |b| b.sequence = Some(0), "1 or more"),
            (
                "expires_at equal to created_at",
                |b| b.expires_at = Some(b.created_at.clone()),
                "is not after created_at",
            ),
            (
                "expires_at before created_at",
                |b| b.expires_at = Some("2026-09-28T11:59:59Z".into()),
                "is not after created_at",
            ),
            (
                "expires_at not a timestamp",
                |b| b.expires_at = Some("next year".into()),
                "not an RFC 3339 UTC instant",
            ),
            (
                "expires_at on a day that does not exist",
                |b| b.expires_at = Some("2027-02-30T00:00:00Z".into()),
                "not an RFC 3339 UTC instant",
            ),
            (
                "created_at on a day that does not exist",
                |b| b.created_at = "2026-02-30T00:00:00Z".into(),
                "not a real RFC 3339 UTC instant",
            ),
            (
                "schema 1 with a sequence",
                |b| {
                    b.schema_version = SCHEMA_V1;
                    b.expires_at = None;
                },
                "belong to schema_version 2",
            ),
            (
                "schema 1 with an expires_at",
                |b| {
                    b.schema_version = SCHEMA_V1;
                    b.sequence = None;
                },
                "belong to schema_version 2",
            ),
            (
                "schema 3",
                |b| b.schema_version = 3,
                "unsupported schema_version 3",
            ),
        ];
        for (what, mutate, needle) in cases {
            let mut b = sample_v2();
            mutate(&mut b);
            let problems = b.validate().join("\n");
            assert!(problems.contains(needle), "{what}: {problems}");
        }
        // A schema 1 bundle with neither key and a schema 2 bundle with both are the valid shapes.
        assert!(sample().validate().is_empty());
        assert!(sample_v2().validate().is_empty());
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
            bootloader_role: Some(BootloaderRole::StandaloneGrub),
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

    fn loader(role: BootloaderRole) -> Artifact {
        Artifact {
            path: format!("efi/{}", role.file_name()),
            kind: ArtifactKind::Bootloader,
            sha256: crate::hashing::sha256_hex(role.file_name().as_bytes()),
            size: 3,
            platforms: Some(vec![Platform::X86_64Uefi]),
            bootloader_role: Some(role),
        }
    }

    #[test]
    fn detects_the_boot_chain() {
        use BootloaderRole::*;
        let chain = |roles: &[BootloaderRole]| {
            detect_boot_chain(&roles.iter().map(|r| loader(*r)).collect::<Vec<_>>())
        };
        assert_eq!(chain(&[]), Ok(None));
        assert_eq!(chain(&[StandaloneGrub]), Ok(Some(BootChain::Development)));
        assert_eq!(
            chain(&[Shim, Grub, MokManager]),
            Ok(Some(BootChain::Secure))
        );
        assert_eq!(
            chain(&[MokManager, Shim, Grub]),
            Ok(Some(BootChain::Secure)),
            "order does not matter"
        );
        let both = chain(&[Shim, Grub, MokManager, StandaloneGrub]).unwrap_err();
        assert!(both.contains("both the Secure Boot chain"), "{both}");
        let partial = chain(&[Shim, Grub]).unwrap_err();
        assert!(partial.contains("missing efi/mmx64.efi"), "{partial}");
        let partial = chain(&[Grub]).unwrap_err();
        assert!(
            partial.contains("efi/shimx64.efi, efi/mmx64.efi"),
            "{partial}"
        );
        assert!(chain(&[StandaloneGrub, StandaloneGrub])
            .unwrap_err()
            .contains("more than one standalone-grub"));

        // Bundle::validate reports the same problems, and role and kind must agree.
        let mut b = sample();
        b.artifacts
            .extend([loader(Shim), loader(Grub), loader(MokManager)]);
        assert!(b.validate().is_empty(), "{:?}", b.validate());
        assert_eq!(b.boot_chain(), Ok(Some(BootChain::Secure)));
        assert_eq!(b.bootloader(Grub).unwrap().path, "efi/grubx64.efi");
        b.artifacts.push(loader(StandaloneGrub));
        assert!(b
            .validate()
            .join("\n")
            .contains("both the Secure Boot chain"));
        b.artifacts.pop();
        b.artifacts[1].bootloader_role = None;
        assert!(b
            .validate()
            .join("\n")
            .contains("must have a bootloader_role"));
        b.artifacts[1].bootloader_role = Some(Shim);
        b.artifacts[0].bootloader_role = Some(Grub);
        assert!(b
            .validate()
            .join("\n")
            .contains("bootloader_role is only valid on bootloader artifacts"));
    }

    #[test]
    fn roles_map_to_file_names_and_chains() {
        for r in BootloaderRole::ALL {
            assert_eq!(BootloaderRole::from_file_name(r.file_name()), Some(r));
            assert_eq!(
                serde_json::to_string(&r).unwrap(),
                format!("\"{}\"", r.as_str())
            );
            assert!(r.chain().roles().contains(&r));
            assert_eq!(r.platform(), Platform::X86_64Uefi);
        }
        assert_eq!(BootloaderRole::from_file_name("bootx64.efi"), None);
        assert_eq!(BootloaderRole::from_file_name("fbx64.efi"), None);
        assert!(BootChain::Secure
            .secure_boot_line()
            .starts_with("Secure Boot: supported"));
        assert!(BootChain::Development
            .secure_boot_line()
            .contains("NOT supported"));
    }

    fn model_named(name: &str, tag: &str) -> Model {
        Model {
            name: name.into(),
            tag: tag.into(),
            digest: None,
            quantization: "Q4_K_M".into(),
            license: "Apache-2.0".into(),
            size_bytes: 1,
            min_ram_gb: 1,
            min_vram_gb: None,
            platforms: vec![Platform::LinuxX86_64],
        }
    }

    #[test]
    fn ollama_and_hugging_face_references_are_accepted() {
        for (name, tag) in [
            ("qwen3.6", "27b"),
            ("nomic-embed-text", "latest"),
            ("gpt-oss", "120b"),
            ("granite4.1", "3b"),
            ("someone/their_model", "Q4_K_M"),
            ("hf.co/unsloth/gemma-3-270m-it-GGUF", "Q4_K_M"),
            ("hf.co/unsloth/GLM-5.2-GGUF", "UD-Q4_K_XL"),
            ("hf.co/ggml-org/gemma-3-270m-GGUF", "gemma-3-270m-Q8_0.gguf"),
            ("hf.co/_org/a.b_c-d", "BF16"),
        ] {
            let m = model_named(name, tag);
            assert_eq!(m.ref_problem(), None, "{name}:{tag}");
        }
    }

    #[test]
    fn hugging_face_models_use_the_ollama_spelling_without_a_new_field() {
        let m = model_named("hf.co/unsloth/gemma-3-270m-it-GGUF", "Q4_K_M");
        assert_eq!(m.source(), ModelSource::HuggingFace);
        assert_eq!(m.hf_repo(), Some(("unsloth", "gemma-3-270m-it-GGUF")));
        // The identity is the reference CI Hub stores as `backendModelId`.
        assert_eq!(m.reference(), "hf.co/unsloth/gemma-3-270m-it-GGUF:Q4_K_M");
        assert_eq!(model_named("gemma3", "1b").source(), ModelSource::Ollama);
        assert_eq!(model_named("gemma3", "1b").hf_repo(), None);
        assert_eq!(model_named("hf.co/unsloth", "Q4").hf_repo(), None);
        assert_eq!(model_named("hf.co/a/b/c", "Q4").hf_repo(), None);
        // The plain record validates; nothing about it is special to the bundle format.
        assert!(validate_packs(&[ModelPack {
            name: "p".into(),
            description: "d".into(),
            models: vec![m],
        }])
        .is_empty());
    }

    #[test]
    fn unportable_or_ambiguous_references_are_rejected() {
        let cases = [
            ("", "latest", "is empty"),
            ("gemma3", "", "tag: is empty"),
            ("-gemma", "1b", "must start with"),
            ("gemma 3", "1b", "only [A-Za-z0-9_.-]"),
            ("gemma3", "1b:q4", "only [A-Za-z0-9_.-]"),
            ("gemma:3", "1b", "only [A-Za-z0-9_.-]"),
            ("gemma3.", "1b", "must not end with '.'"),
            ("gemma3", "q4.", "must not end with '.'"),
            ("a/b/c", "latest", "<namespace>/<model>"),
            ("registry.example.com/ns/model", "1b", "<namespace>/<model>"),
            ("gemma3/", "1b", "is empty"),
            ("gemma\\3", "1b", "only [A-Za-z0-9_.-]"),
            ("..", "1b", "must start with"),
            ("con", "latest", "Windows device name"),
            ("model", "nul.gguf", "Windows device name"),
            ("model", "COM3", "Windows device name"),
            ("kimi-k3", "cloud", "no weights"),
            ("gpt-oss", "120b-cloud", "no weights"),
            ("hf.co/org", "Q4", "exactly hf.co/<org>/<repo>"),
            ("hf.co/org/repo/extra", "Q4", "exactly hf.co/<org>/<repo>"),
            ("hf.co//repo", "Q4", "must be 1 to 96"),
            ("hf.co/-org/repo", "Q4", "must start and end"),
            ("hf.co/org/repo-", "Q4", "must start and end"),
            ("hf.co/org/re..po", "Q4", "'--' or '..'"),
            ("hf.co/org/re--po", "Q4", "'--' or '..'"),
            ("hf.co/org/re po", "Q4", "only [A-Za-z0-9_.-]"),
            ("hf.co/org/nul", "Q4", "Windows device name"),
        ];
        for (name, tag, why) in cases {
            let problem = model_named(name, tag)
                .ref_problem()
                .unwrap_or_else(|| panic!("{name}:{tag} should be rejected"));
            assert!(problem.contains(why), "{name}:{tag}: {problem}");
        }
        let long = "a".repeat(81);
        assert!(model_named(&long, "1b")
            .ref_problem()
            .unwrap()
            .contains("80"));
        let long_id = "a".repeat(97);
        assert!(model_named(&format!("hf.co/org/{long_id}"), "Q4")
            .ref_problem()
            .unwrap()
            .contains("96"));
        // A :cloud *tag* is only a problem for Ollama; Hugging Face quant labels are free text.
        assert_eq!(model_named("hf.co/org/repo", "cloud").ref_problem(), None);
    }

    #[test]
    fn references_that_differ_only_by_case_collide_on_exfat() {
        let pack = |models: Vec<Model>| {
            vec![ModelPack {
                name: "p".into(),
                description: "d".into(),
                models,
            }]
        };
        let ok = pack(vec![
            model_named("hf.co/unsloth/Gemma-GGUF", "Q4_K_M"),
            model_named("hf.co/unsloth/Gemma-GGUF", "Q4_K_M"),
            model_named("gemma3", "1b"),
        ]);
        assert!(model_ref_problems(&ok).is_empty());
        let clash = pack(vec![
            model_named("hf.co/unsloth/Gemma-GGUF", "Q4_K_M"),
            model_named("hf.co/unsloth/gemma-gguf", "q4_k_m"),
        ]);
        let problems = model_ref_problems(&clash);
        assert_eq!(problems.len(), 1, "{problems:?}");
        assert!(problems[0].contains("differ only by case"), "{problems:?}");
        // One bad reference shared by two packs is reported once.
        let shared = vec![
            ModelPack {
                name: "a".into(),
                description: "d".into(),
                models: vec![model_named("bad name", "1b")],
            },
            ModelPack {
                name: "b".into(),
                description: "d".into(),
                models: vec![model_named("bad name", "1b")],
            },
        ];
        assert_eq!(model_ref_problems(&shared).len(), 1);
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
