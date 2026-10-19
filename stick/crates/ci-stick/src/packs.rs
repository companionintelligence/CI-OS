//! Model-pack catalog (`core/manifest/model-packs.yaml`) and fit logic.
//!
//! "All models" is unbounded, so a stick carries curated, named packs. The catalog is
//! provisional until it is generated from CI Hub's curated model catalog; its model
//! entries use exactly the [`Model`](crate::manifest::Model) type recorded in
//! `bundle.json`, so a pack moves from catalog to bundle unchanged.
//!
//! Three more files sit next to the catalog, and this module reads all of them:
//!
//! - `core/manifest/model-packs.lock.json`, the generated lock (`ci-stick models lock`):
//!   what the registries said. [`LockView`] reads the few facts the catalog is checked
//!   against, [`lock_drift`] compares, [`resolve_packs`] lets the lock's sizes and digests win.
//! - `core/manifest/licenses.yaml`: [`LicenseTable`], which says how the tooling treats each
//!   licence a pack names, and which `license` strings block a release ([`release_blockers`]).
//! - `core/manifest/ecosystem.yaml`: only its `llm.models` list, which the `appliance-core`
//!   pack must equal.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context as _};
use serde::{Deserialize, Serialize};

use crate::manifest::{
    is_model_digest, model_ref_problems, validate_packs, Model, ModelPack, Platform,
};
use crate::size::{fmt_binary, fmt_decimal};

pub const CATALOG_SCHEMA_VERSION: u32 = 1;
/// Repository-relative location of the catalog.
pub const CATALOG_REL_PATH: &str = "core/manifest/model-packs.yaml";
/// Repository-relative location of the generated lock file (written by `ci-stick models lock`).
pub const LOCK_REL_PATH: &str = "core/manifest/model-packs.lock.json";
/// Repository-relative location of the licence table.
pub const LICENSES_REL_PATH: &str = "core/manifest/licenses.yaml";
/// Repository-relative location of the ecosystem manifest (read for `llm.models`).
pub const ECOSYSTEM_REL_PATH: &str = "core/manifest/ecosystem.yaml";
pub const LICENSES_SCHEMA_VERSION: u32 = 1;
/// The lock schema this module can read.
pub const LOCK_SCHEMA_VERSION: u32 = 1;
/// The pack that is the pack-shaped form of `ecosystem.yaml`'s `llm.models`.
pub const APPLIANCE_CORE_PACK: &str = "appliance-core";

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PackCatalog {
    pub schema_version: u32,
    /// `provisional` until derived from Hub's curated catalog.
    pub status: String,
    /// Named platform lists, referenced from the packs via YAML anchors.
    #[serde(rename = "x-platforms", default)]
    pub platform_sets: BTreeMap<String, Vec<Platform>>,
    pub packs: Vec<ModelPack>,
}

impl PackCatalog {
    pub fn parse(text: &str) -> anyhow::Result<Self> {
        let cat: Self =
            serde_yaml::from_str(text).context("model-pack catalog does not match its schema")?;
        if cat.schema_version != CATALOG_SCHEMA_VERSION {
            bail!(
                "unsupported model-pack catalog schema_version {} (expected {CATALOG_SCHEMA_VERSION})",
                cat.schema_version
            );
        }
        let mut problems = validate_packs(&cat.packs);
        problems.extend(model_ref_problems(&cat.packs));
        problems.extend(catalog_consistency_problems(&cat.packs));
        if !problems.is_empty() {
            bail!("invalid model-pack catalog:\n  {}", problems.join("\n  "));
        }
        Ok(cat)
    }

    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        Self::parse(&text).with_context(|| format!("loading {}", path.display()))
    }
}

/// Find a repository file (`rel`, e.g. [`CATALOG_REL_PATH`]) by walking up from `start`.
pub fn find_in_ancestors(start: &Path, rel: &str) -> Option<PathBuf> {
    start
        .ancestors()
        .map(|dir| dir.join(rel))
        .find(|p| p.is_file())
}

/// Find `core/manifest/model-packs.yaml` by walking up from `start`.
pub fn find_catalog(start: &Path) -> Option<PathBuf> {
    find_in_ancestors(start, CATALOG_REL_PATH)
}

/// Find `core/manifest/model-packs.lock.json` by walking up from `start`. `None` until
/// `ci-stick models lock` has written it.
pub fn find_lock(start: &Path) -> Option<PathBuf> {
    find_in_ancestors(start, LOCK_REL_PATH)
}

/// Find `core/manifest/licenses.yaml` by walking up from `start`.
pub fn find_licenses(start: &Path) -> Option<PathBuf> {
    find_in_ancestors(start, LICENSES_REL_PATH)
}

/// Total bytes of the distinct models (`name:tag`) across `packs` — packs share models
/// (e.g. the embedding model), and the content-addressed cache stores each blob once.
pub fn unique_models_bytes(packs: &[ModelPack]) -> u64 {
    let mut uniq: BTreeMap<String, u64> = BTreeMap::new();
    for m in packs.iter().flat_map(|p| &p.models) {
        uniq.insert(m.reference(), m.size_bytes);
    }
    uniq.values().sum()
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct PackFit {
    pub name: String,
    pub description: String,
    pub models: usize,
    pub size_bytes: u64,
    pub min_ram_gb: u32,
    pub min_vram_gb: Option<u32>,
    pub unresolved_digests: usize,
    /// `None` when no capacity was given.
    pub fits: Option<bool>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct FitReport {
    pub capacity_bytes: Option<u64>,
    pub packs: Vec<PackFit>,
    /// All packs together, shared models counted once.
    pub all_packs_bytes: u64,
    pub all_fit: Option<bool>,
}

pub fn fit_report(packs: &[ModelPack], capacity: Option<u64>) -> FitReport {
    let rows = packs
        .iter()
        .map(|p| {
            let size = p.size_bytes();
            PackFit {
                name: p.name.clone(),
                description: p.description.clone(),
                models: p.models.len(),
                size_bytes: size,
                min_ram_gb: p.models.iter().map(|m| m.min_ram_gb).max().unwrap_or(0),
                min_vram_gb: p.models.iter().filter_map(|m| m.min_vram_gb).max(),
                unresolved_digests: p.models.iter().filter(|m| m.digest.is_none()).count(),
                fits: capacity.map(|c| size <= c),
            }
        })
        .collect();
    let all = unique_models_bytes(packs);
    FitReport {
        capacity_bytes: capacity,
        packs: rows,
        all_packs_bytes: all,
        all_fit: capacity.map(|c| all <= c),
    }
}

pub fn render_table(r: &FitReport) -> String {
    let mut out = String::new();
    if let Some(c) = r.capacity_bytes {
        out.push_str(&format!(
            "Model cache capacity: {} ({})\n\n",
            fmt_binary(c),
            fmt_decimal(c)
        ));
    }
    out.push_str(&format!(
        "{:<9} {:>6} {:>10} {:>7} {:>8}  {:<4}  {}\n",
        "PACK", "MODELS", "SIZE", "MIN RAM", "MIN VRAM", "FITS", "DESCRIPTION"
    ));
    for p in &r.packs {
        let fits = match p.fits {
            Some(true) => "yes",
            Some(false) => "NO",
            None => "-",
        };
        let vram = p.min_vram_gb.map_or("-".to_string(), |v| format!("{v} GB"));
        out.push_str(&format!(
            "{:<9} {:>6} {:>10} {:>7} {:>8}  {:<4}  {}\n",
            p.name,
            p.models,
            fmt_decimal(p.size_bytes),
            format!("{} GB", p.min_ram_gb),
            vram,
            fits,
            p.description
        ));
    }
    let all = match r.all_fit {
        Some(true) => " — fits",
        Some(false) => " — does NOT fit",
        None => "",
    };
    out.push_str(&format!(
        "\nAll packs together (shared models counted once): {}{all}\n",
        fmt_decimal(r.all_packs_bytes)
    ));
    let unresolved: usize = r.packs.iter().map(|p| p.unresolved_digests).sum();
    if unresolved > 0 {
        out.push_str(&format!(
            "Note: {unresolved} model entries have no resolved digest yet — sizes are approximate until `models lock`.\n"
        ));
    }
    out
}

// ---------------------------------------------------------------------------------------
// Same model, same facts, in every pack
// ---------------------------------------------------------------------------------------

fn differing_fields(a: &Model, b: &Model) -> Vec<&'static str> {
    let mut fields = Vec::new();
    macro_rules! cmp {
        ($($f:ident),*) => { $(if a.$f != b.$f { fields.push(stringify!($f)); })* };
    }
    cmp!(
        digest,
        quantization,
        license,
        size_bytes,
        min_ram_gb,
        min_vram_gb,
        platforms
    );
    fields
}

/// The catalog rule "keep the same model ref at one size across packs", extended to every
/// field: a reference that appears in two packs must describe the same model in both
/// (`unique_models_bytes` would otherwise silently count the last one).
pub fn catalog_consistency_problems(packs: &[ModelPack]) -> Vec<String> {
    let mut first: BTreeMap<String, (&str, &Model)> = BTreeMap::new();
    let mut problems = Vec::new();
    for pack in packs {
        for m in &pack.models {
            let r = m.reference();
            match first.get(&r) {
                None => {
                    first.insert(r, (pack.name.as_str(), m));
                }
                Some((other, base)) => {
                    let fields = differing_fields(base, m);
                    if !fields.is_empty() {
                        problems.push(format!(
                            "model {r} differs between packs {other:?} and {:?} in {}",
                            pack.name,
                            fields.join(", ")
                        ));
                    }
                }
            }
        }
    }
    problems
}

// ---------------------------------------------------------------------------------------
// The lock file
// ---------------------------------------------------------------------------------------

/// What the lock file says about one model: the facts the catalog is checked against.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LockedModel {
    /// `name:tag`, as in [`Model::reference`].
    pub reference: String,
    /// Config plus layers, as the registry listed them when the lock was written.
    pub size_bytes: u64,
    /// `sha256:<hex>` of the pinned manifest: the value `bundle.json` gets as `Model.digest`.
    pub digest: Option<String>,
}

/// A read-only view of `core/manifest/model-packs.lock.json`. The writer (`ci-stick models lock`)
/// owns the full format, and it carries much more (layers, inline blobs, Hugging Face revisions).
/// This reader takes exactly three facts per model, from these keys of the version-1 lock:
/// `models[].ref`, `models[].size_bytes` and `models[].manifest.digest`. Everything else is
/// ignored, so the lock can grow without breaking the catalog checks.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LockView {
    models: BTreeMap<String, LockedModel>,
}

impl LockView {
    pub fn parse(bytes: &[u8]) -> anyhow::Result<Self> {
        let doc: serde_json::Value =
            serde_json::from_slice(bytes).context("the model lock is not JSON")?;
        let version = doc.get("schema_version").and_then(|v| v.as_u64());
        if version != Some(u64::from(LOCK_SCHEMA_VERSION)) {
            bail!(
                "unsupported model lock schema_version {} (this ci-stick reads {LOCK_SCHEMA_VERSION})",
                version.map_or("(missing)".to_string(), |v| v.to_string())
            );
        }
        let entries = doc
            .get("models")
            .and_then(|v| v.as_array())
            .context("the model lock has no `models` array")?;
        let mut models = BTreeMap::new();
        for (i, e) in entries.iter().enumerate() {
            let reference = e
                .get("ref")
                .and_then(|v| v.as_str())
                .with_context(|| format!("model lock entry {i} has no string `ref`"))?;
            let size_bytes = e
                .get("size_bytes")
                .and_then(|v| v.as_u64())
                .with_context(|| format!("model lock entry {reference} has no `size_bytes`"))?;
            let digest = match e.pointer("/manifest/digest").and_then(|v| v.as_str()) {
                Some(d) if is_model_digest(d) => Some(d.to_string()),
                Some(d) => bail!("model lock entry {reference}: digest {d:?} is not sha256:<hex>"),
                None => None,
            };
            let locked = LockedModel {
                reference: reference.to_string(),
                size_bytes,
                digest,
            };
            if models.insert(reference.to_string(), locked).is_some() {
                bail!("model lock lists {reference} twice");
            }
        }
        Ok(LockView { models })
    }

    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let bytes = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
        Self::parse(&bytes).with_context(|| format!("loading {}", path.display()))
    }

    pub fn get(&self, reference: &str) -> Option<&LockedModel> {
        self.models.get(reference)
    }

    pub fn len(&self) -> usize {
        self.models.len()
    }

    pub fn is_empty(&self) -> bool {
        self.models.is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = &LockedModel> {
        self.models.values()
    }
}

/// One way the catalog disagrees with the lock.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Drift {
    /// A model the packs list that the lock has never resolved.
    MissingFromLock { reference: String },
    /// `size_bytes` differs by at least one byte.
    Size {
        reference: String,
        catalog: u64,
        lock: u64,
    },
    /// The catalog carries a digest and the lock pins another one (or none).
    Digest {
        reference: String,
        catalog: String,
        lock: Option<String>,
    },
}

impl Drift {
    pub fn reference(&self) -> &str {
        match self {
            Drift::MissingFromLock { reference }
            | Drift::Size { reference, .. }
            | Drift::Digest { reference, .. } => reference,
        }
    }
}

impl fmt::Display for Drift {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Drift::MissingFromLock { reference } => {
                write!(f, "{reference}: not in the lock (run `ci-stick models lock`)")
            }
            Drift::Size {
                reference,
                catalog,
                lock,
            } => write!(
                f,
                "{reference}: size_bytes is {catalog} in the catalog but {lock} in the lock ({:+} B)",
                i128::from(*lock) - i128::from(*catalog)
            ),
            Drift::Digest {
                reference,
                catalog,
                lock,
            } => write!(
                f,
                "{reference}: the catalog carries digest {catalog} but the lock pins {}",
                lock.as_deref().unwrap_or("none")
            ),
        }
    }
}

/// Compare the catalog with the lock, model by model (each distinct reference once). The
/// tolerance is zero bytes: the lock is what the registry said, the catalog is a copy of it.
/// Models only the lock knows are not drift (a lock may carry more than the packs list).
pub fn lock_drift(packs: &[ModelPack], lock: &LockView) -> Vec<Drift> {
    let mut seen = BTreeSet::new();
    let mut drift = Vec::new();
    for m in packs.iter().flat_map(|p| &p.models) {
        let reference = m.reference();
        if !seen.insert(reference.clone()) {
            continue;
        }
        let Some(locked) = lock.get(&reference) else {
            drift.push(Drift::MissingFromLock { reference });
            continue;
        };
        if locked.size_bytes != m.size_bytes {
            drift.push(Drift::Size {
                reference: reference.clone(),
                catalog: m.size_bytes,
                lock: locked.size_bytes,
            });
        }
        if let Some(d) = &m.digest {
            if locked.digest.as_ref() != Some(d) {
                drift.push(Drift::Digest {
                    reference,
                    catalog: d.clone(),
                    lock: locked.digest.clone(),
                });
            }
        }
    }
    drift
}

/// Where a value came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Provenance {
    /// `core/manifest/model-packs.yaml`: a hand-maintained snapshot.
    Catalog,
    /// `core/manifest/model-packs.lock.json`: what the registry said when the lock was made.
    Lock,
}

/// A model with the lock's facts applied where the lock has them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResolvedModel {
    pub reference: String,
    pub size_bytes: u64,
    pub size_from: Provenance,
    pub digest: Option<String>,
    /// `None` when neither the lock nor the catalog has a digest yet.
    pub digest_from: Option<Provenance>,
}

/// The size and digest to use for `m`: the lock's when it knows the model, the catalog's
/// otherwise. A digest typed into the catalog never beats the lock's (and [`lock_drift`]
/// reports the mismatch).
pub fn resolve_model(m: &Model, lock: Option<&LockView>) -> ResolvedModel {
    let reference = m.reference();
    let locked = lock.and_then(|l| l.get(&reference));
    let (size_bytes, size_from) = match locked {
        Some(l) => (l.size_bytes, Provenance::Lock),
        None => (m.size_bytes, Provenance::Catalog),
    };
    let (digest, digest_from) = match (locked.and_then(|l| l.digest.clone()), &m.digest) {
        (Some(d), _) => (Some(d), Some(Provenance::Lock)),
        (None, Some(d)) => (Some(d.clone()), Some(Provenance::Catalog)),
        (None, None) => (None, None),
    };
    ResolvedModel {
        reference,
        size_bytes,
        size_from,
        digest,
        digest_from,
    }
}

/// `packs` with every model's `size_bytes` and `digest` replaced by [`resolve_model`]'s. Feed the
/// result to [`fit_report`] to size a cache from the lock instead of the YAML snapshot.
pub fn resolve_packs(packs: &[ModelPack], lock: Option<&LockView>) -> Vec<ModelPack> {
    packs
        .iter()
        .map(|p| ModelPack {
            models: p
                .models
                .iter()
                .map(|m| {
                    let r = resolve_model(m, lock);
                    Model {
                        size_bytes: r.size_bytes,
                        digest: r.digest,
                        ..m.clone()
                    }
                })
                .collect(),
            ..p.clone()
        })
        .collect()
}

// ---------------------------------------------------------------------------------------
// Licences
// ---------------------------------------------------------------------------------------

/// What the tooling does about a licence before it copies a model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
pub enum LicenseGate {
    /// Nothing: the licence text travels with the model blob.
    #[serde(rename = "none")]
    NoGate,
    /// Show the name and URL; no recorded acceptance.
    #[serde(rename = "notice")]
    Notice,
    /// Refuse until the person accepts the licence by name.
    #[serde(rename = "accept")]
    Accept,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct License {
    /// The string packs use in `license:`.
    pub name: String,
    /// SPDX id, or a `LicenseRef-...` id where SPDX lists none.
    pub spdx: String,
    pub spdx_listed: bool,
    pub url: String,
    pub gate: LicenseGate,
    /// Other spellings (Hugging Face `cardData.license` ids, registry short names).
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default)]
    pub notes: Option<String>,
}

impl License {
    pub fn acceptance_required(&self) -> bool {
        self.gate == LicenseGate::Accept
    }

    fn answers_to(&self, name: &str) -> bool {
        let name = name.trim();
        self.name.eq_ignore_ascii_case(name)
            || self.aliases.iter().any(|a| a.eq_ignore_ascii_case(name))
    }
}

/// `core/manifest/licenses.yaml`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LicenseTable {
    pub schema_version: u32,
    pub status: String,
    /// The explicit list of `license` strings that block a release bundle.
    pub release_blocking: Vec<String>,
    pub licenses: Vec<License>,
}

impl LicenseTable {
    pub fn parse(text: &str) -> anyhow::Result<Self> {
        let table: Self =
            serde_yaml::from_str(text).context("licence table does not match its schema")?;
        let problems = table.problems();
        if !problems.is_empty() {
            bail!("invalid licence table:\n  {}", problems.join("\n  "));
        }
        Ok(table)
    }

    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        Self::parse(&text).with_context(|| format!("loading {}", path.display()))
    }

    fn problems(&self) -> Vec<String> {
        let mut p = Vec::new();
        if self.schema_version != LICENSES_SCHEMA_VERSION {
            p.push(format!(
                "unsupported schema_version {} (expected {LICENSES_SCHEMA_VERSION})",
                self.schema_version
            ));
        }
        if self.licenses.is_empty() {
            p.push("no licences".into());
        }
        if self.release_blocking.is_empty() {
            p.push(
                "release_blocking is empty; list the licence strings that block a release".into(),
            );
        }
        // Every spelling (names, aliases and blocking strings) must be unique, ignoring case,
        // or a lookup could answer for two licences.
        let mut spellings: BTreeMap<String, String> = BTreeMap::new();
        let mut claim = |spelling: &str, owner: &str, p: &mut Vec<String>| {
            if spelling.trim().is_empty() {
                p.push(format!("{owner}: empty name or alias"));
            } else if let Some(other) =
                spellings.insert(spelling.to_ascii_lowercase(), owner.into())
            {
                p.push(format!(
                    "{spelling:?} belongs to both {other:?} and {owner:?}"
                ));
            }
        };
        for l in &self.licenses {
            claim(&l.name, &l.name, &mut p);
            for a in &l.aliases {
                claim(a, &l.name, &mut p);
            }
            if !l.url.starts_with("https://") {
                p.push(format!("{}: url must be https", l.name));
            }
            if l.spdx.trim().is_empty() {
                p.push(format!("{}: spdx is empty", l.name));
            }
            if l.spdx_listed == l.spdx.starts_with("LicenseRef-") {
                p.push(format!(
                    "{}: spdx {:?} must be a LicenseRef-... id exactly when spdx_listed is false",
                    l.name, l.spdx
                ));
            }
        }
        for b in &self.release_blocking {
            claim(b, "release_blocking", &mut p);
        }
        p
    }

    /// The row a pack's `license:` string refers to (name or alias, case-insensitive).
    pub fn lookup(&self, name: &str) -> Option<&License> {
        self.licenses.iter().find(|l| l.answers_to(name))
    }

    pub fn is_release_blocking(&self, name: &str) -> bool {
        self.release_blocking
            .iter()
            .any(|b| b.eq_ignore_ascii_case(name.trim()))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum BlockReason {
    /// The licence string is in `release_blocking` (`unverified`).
    Unverified,
    /// The licence string is in neither list: nobody has reviewed it.
    NotInTable,
}

/// A model that stops a release bundle.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ReleaseBlocker {
    pub pack: String,
    pub reference: String,
    pub license: String,
    pub reason: BlockReason,
}

/// Every (pack, model) whose licence is `unverified` or unknown. A release bundle needs this to
/// be empty; a development bundle may carry blockers.
pub fn release_blockers(packs: &[ModelPack], table: &LicenseTable) -> Vec<ReleaseBlocker> {
    let mut out = Vec::new();
    for pack in packs {
        for m in &pack.models {
            let reason = if table.is_release_blocking(&m.license) {
                BlockReason::Unverified
            } else if table.lookup(&m.license).is_none() {
                BlockReason::NotInTable
            } else {
                continue;
            };
            out.push(ReleaseBlocker {
                pack: pack.name.clone(),
                reference: m.reference(),
                license: m.license.clone(),
                reason,
            });
        }
    }
    out
}

/// The licences that need a recorded acceptance before `packs` can be copied, by the table's
/// canonical name, each with the (sorted, distinct) model references it covers.
pub fn acceptance_required(
    packs: &[ModelPack],
    table: &LicenseTable,
) -> BTreeMap<String, Vec<String>> {
    let mut out: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for m in packs.iter().flat_map(|p| &p.models) {
        if let Some(l) = table.lookup(&m.license).filter(|l| l.acceptance_required()) {
            out.entry(l.name.clone()).or_default().insert(m.reference());
        }
    }
    out.into_iter()
        .map(|(k, v)| (k, v.into_iter().collect()))
        .collect()
}

// ---------------------------------------------------------------------------------------
// ecosystem.yaml
// ---------------------------------------------------------------------------------------

/// `llm.models` of `core/manifest/ecosystem.yaml` as model references: a bare name means the
/// registry's default tag (`nomic-embed-text` is `nomic-embed-text:latest`). The
/// `appliance-core` pack must list exactly these.
pub fn ecosystem_llm_refs(ecosystem_yaml: &str) -> anyhow::Result<Vec<String>> {
    let doc: serde_yaml::Value =
        serde_yaml::from_str(ecosystem_yaml).context("ecosystem manifest is not YAML")?;
    let models = doc
        .get("llm")
        .and_then(|v| v.get("models"))
        .and_then(|v| v.as_sequence())
        .context("ecosystem manifest has no llm.models list")?;
    models
        .iter()
        .map(|m| {
            let s = m.as_str().context("llm.models entries must be strings")?;
            Ok(if s.contains(':') {
                s.to_string()
            } else {
                format!("{s}:latest")
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{Model, Platform};

    fn model(name: &str, tag: &str, size: u64) -> Model {
        Model {
            name: name.into(),
            tag: tag.into(),
            digest: None,
            quantization: "Q4_K_M".into(),
            license: "Apache-2.0".into(),
            size_bytes: size,
            min_ram_gb: 8,
            min_vram_gb: None,
            platforms: vec![Platform::LinuxX86_64],
        }
    }

    fn packs() -> Vec<ModelPack> {
        vec![
            ModelPack {
                name: "small".into(),
                description: "s".into(),
                models: vec![model("embed", "v1", 100), model("a", "1b", 900)],
            },
            ModelPack {
                name: "big".into(),
                description: "b".into(),
                models: vec![model("embed", "v1", 100), model("b", "70b", 5000)],
            },
        ]
    }

    fn repo_file(rel: &str) -> PathBuf {
        find_in_ancestors(Path::new(env!("CARGO_MANIFEST_DIR")), rel)
            .unwrap_or_else(|| panic!("{rel} not found above the crate"))
    }

    fn repo_catalog() -> PackCatalog {
        PackCatalog::load(&repo_file(CATALOG_REL_PATH)).unwrap()
    }

    fn repo_licenses() -> LicenseTable {
        LicenseTable::load(&repo_file(LICENSES_REL_PATH)).unwrap()
    }

    /// A test that cannot run says so on stderr even without `--nocapture`: libtest captures the
    /// print macros, not a direct write to the handle. A skip is never silent.
    fn skip_visibly(why: &str) {
        use std::io::Write as _;
        let _ = writeln!(std::io::stderr(), "\nSKIPPED (this is not a pass): {why}");
    }

    #[test]
    fn fit_logic() {
        let r = fit_report(&packs(), Some(1000));
        assert_eq!(r.packs[0].fits, Some(true), "exactly at capacity fits");
        assert_eq!(r.packs[1].fits, Some(false));
        assert_eq!(
            r.all_packs_bytes, 6000,
            "shared embedding model counted once"
        );
        assert_eq!(r.all_fit, Some(false));
        assert_eq!(fit_report(&packs(), Some(6000)).all_fit, Some(true));
        let none = fit_report(&packs(), None);
        assert_eq!(none.packs[0].fits, None);
        assert_eq!(none.all_fit, None);
        assert_eq!(r.packs[0].unresolved_digests, 2);
    }

    #[test]
    fn repository_catalog_is_valid() {
        let cat = repo_catalog();
        let names: Vec<&str> = cat.packs.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "starter",
                "balanced",
                "coding",
                "vision",
                "large",
                "stick-128",
                "stick-128-oci",
                "appliance-core"
            ]
        );
        assert_eq!(cat.status, "provisional");
        // Digests are resolved by a later `models lock` step, never invented by hand.
        assert!(cat
            .packs
            .iter()
            .flat_map(|p| &p.models)
            .all(|m| m.digest.is_none()));
        // Every model the ecosystem manifest pre-pulls is in some pack.
        let ecosystem = std::fs::read_to_string(repo_file(ECOSYSTEM_REL_PATH)).unwrap();
        for wanted in ecosystem_llm_refs(&ecosystem).unwrap() {
            assert!(
                cat.packs
                    .iter()
                    .flat_map(|p| &p.models)
                    .any(|m| m.reference() == wanted),
                "{wanted} missing from catalog"
            );
        }
        // The whole catalog fits the 512 GB layout's cache.
        let cache = crate::layout::plan(512_000_000_000).unwrap().cache_bytes();
        assert!(unique_models_bytes(&cat.packs) <= cache);
        // Spelling and cross-pack consistency are enforced when the catalog loads; assert the
        // functions directly too so a regression in `parse` cannot hide them.
        assert_eq!(model_ref_problems(&cat.packs), Vec::<String>::new());
        assert_eq!(
            catalog_consistency_problems(&cat.packs),
            Vec::<String>::new()
        );
    }

    /// `appliance-core` is the pack-shaped form of `ecosystem.yaml`'s `llm.models`: what a
    /// provisioned machine pre-pulls, and what a background prefetch (default off) would fetch.
    /// It must not drift from that list in either direction, and it reuses the `stick-128`
    /// entries so one model has one set of facts.
    #[test]
    fn appliance_core_is_exactly_what_the_ecosystem_manifest_prepulls() {
        let cat = repo_catalog();
        let core = cat
            .packs
            .iter()
            .find(|p| p.name == APPLIANCE_CORE_PACK)
            .expect("appliance-core pack");
        let ecosystem = std::fs::read_to_string(repo_file(ECOSYSTEM_REL_PATH)).unwrap();
        let wanted = ecosystem_llm_refs(&ecosystem).unwrap();
        let have: Vec<String> = core.models.iter().map(|m| m.reference()).collect();
        assert_eq!(
            have, wanted,
            "appliance-core must equal ecosystem.yaml llm.models"
        );
        let full = cat.packs.iter().find(|p| p.name == "stick-128").unwrap();
        for m in &core.models {
            assert!(
                full.models.contains(m),
                "{} differs from, or is missing in, stick-128",
                m.reference()
            );
        }
        // 18.8 GB: it fits the cache of the smallest supported stick (57 GiB), so any stick can
        // carry it.
        let smallest = crate::layout::plan(crate::layout::MIN_DEVICE_BYTES)
            .unwrap()
            .cache_bytes();
        assert!(core.size_bytes() <= smallest, "{}", core.size_bytes());
    }

    /// The 128 GB stick packs are sized for the sticks that are actually on the desk: a "128 GB" stick
    /// reports 123,942,731,776 bytes (115.4 GiB), which gets a 73 GiB cache, not the 77 GiB that a stick
    /// of exactly 128e9 bytes would. Both packs must leave headroom for exFAT overhead, tmp files and
    /// (for `stick-128-oci`) 15 GiB of OCI images.
    #[test]
    fn stick_128_packs_fit_the_real_128gb_stick_with_headroom() {
        const REAL_128GB_STICK: u64 = 123_942_731_776;
        const GIB: u64 = 1 << 30;
        let cat = repo_catalog();
        let cache = crate::layout::plan(REAL_128GB_STICK).unwrap().cache_bytes();
        assert_eq!(
            cache,
            73 * GIB,
            "layout policy changed: re-size the stick packs"
        );
        let by_name = |n: &str| cat.packs.iter().find(|p| p.name == n).unwrap();
        let full = by_name("stick-128");
        let oci = by_name("stick-128-oci");
        // 3 % headroom on the raw model bytes (exFAT cluster rounding adds ~9 MB for these packs).
        assert!(
            full.size_bytes() * 100 <= cache * 97,
            "stick-128 leaves less than 3 % free: {} of {cache}",
            full.size_bytes()
        );
        assert!(
            (oci.size_bytes() + 15 * GIB) * 100 <= cache * 97,
            "stick-128-oci plus 15 GiB of OCI images leaves less than 3 % free"
        );
        // stick-128-oci is stick-128 minus its lowest-ranked models, never a different set.
        for m in &oci.models {
            assert!(
                full.models.iter().any(|f| f.reference() == m.reference()),
                "{} is in stick-128-oci but not in stick-128",
                m.reference()
            );
        }
        // The three models the ecosystem manifest pre-pulls are the first three ranks of stick-128.
        let first: Vec<String> = full.models.iter().take(3).map(|m| m.reference()).collect();
        assert_eq!(
            first,
            ["nomic-embed-text:latest", "gemma3:1b", "qwen3.6:27b"]
        );
        // `cargo test` must not silently accept an unlicensed or cloud-only entry.
        for m in full.models.iter() {
            assert_ne!(m.license, "unverified", "{}", m.reference());
            assert!(
                !m.tag.contains("cloud"),
                "{} is a cloud-only tag",
                m.reference()
            );
        }
    }

    #[test]
    fn rejects_bad_catalogs() {
        assert!(PackCatalog::parse("schema_version: 2\nstatus: x\npacks: []\n").is_err());
        let one = |extra: &str| {
            format!(
                "schema_version: 1\nstatus: provisional\npacks:\n  - name: p\n    description: d\n    models:\n{extra}"
            )
        };
        let entry = |name: &str, tag: &str, digest: &str, size: u64| {
            format!(
                "      - {{name: {name}, tag: {tag}, digest: {digest}, quantization: q, license: l,\n         size_bytes: {size}, min_ram_gb: 1, min_vram_gb: null, platforms: [linux-x86_64]}}\n"
            )
        };
        let err = PackCatalog::parse(&one(&entry("m", "t", "\"abc\"", 1))).unwrap_err();
        assert!(format!("{err:#}").contains("digest"));

        // Spelling is enforced when the catalog loads.
        let err = PackCatalog::parse(&one(&entry("\"bad name\"", "t", "null", 1))).unwrap_err();
        assert!(
            format!("{err:#}").contains("only [A-Za-z0-9_.-]"),
            "{err:#}"
        );
        let err = PackCatalog::parse(&one(&entry("gpt-oss", "120b-cloud", "null", 1))).unwrap_err();
        assert!(format!("{err:#}").contains("no weights"), "{err:#}");
        // A Hugging Face model is a plain `Model` with the hf.co spelling.
        let ok = PackCatalog::parse(&one(&entry(
            "hf.co/unsloth/gemma-3-270m-it-GGUF",
            "Q4_K_M",
            "null",
            253_116_654,
        )))
        .unwrap();
        assert_eq!(
            ok.packs[0].models[0].reference(),
            "hf.co/unsloth/gemma-3-270m-it-GGUF:Q4_K_M"
        );

        // One model, two descriptions in two packs: refused.
        let two = format!(
            "{}  - name: q\n    description: d\n    models:\n{}",
            one(&entry("m", "t", "null", 1)),
            entry("m", "t", "null", 2)
        );
        let err = PackCatalog::parse(&two).unwrap_err();
        let text = format!("{err:#}");
        assert!(
            text.contains("m:t differs between packs") && text.contains("size_bytes"),
            "{text}"
        );
    }

    // ---- the lock ----

    const DIGEST_A: &str =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const DIGEST_B: &str =
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn lock_with(entries: &str) -> LockView {
        let text = format!(
            "{{\"schema_version\": 1, \"generated_at\": \"2026-10-17T00:00:00Z\", \"models\": [{entries}]}}"
        );
        LockView::parse(text.as_bytes()).unwrap()
    }

    #[test]
    fn the_lock_view_reads_only_what_the_catalog_needs() {
        let lock = lock_with(&format!(
            r#"{{"ref": "embed:v1", "size_bytes": 100, "extra": [1, 2], "manifest": {{"digest": "{DIGEST_A}", "inline_b64": "e30="}}}},
               {{"ref": "a:1b", "size_bytes": 900}}"#
        ));
        assert_eq!(lock.len(), 2);
        assert!(!lock.is_empty());
        let e = lock.get("embed:v1").unwrap();
        assert_eq!((e.size_bytes, e.digest.as_deref()), (100, Some(DIGEST_A)));
        assert_eq!(lock.get("a:1b").unwrap().digest, None);
        assert!(lock.get("nope:1").is_none());
        assert_eq!(lock.iter().count(), 2);
    }

    #[test]
    fn the_lock_view_rejects_what_it_cannot_trust() {
        let bad = |json: &str| format!("{:#}", LockView::parse(json.as_bytes()).unwrap_err());
        assert!(bad("not json").contains("not JSON"));
        assert!(bad(r#"{"models": []}"#).contains("(missing)"));
        assert!(bad(r#"{"schema_version": 2, "models": []}"#).contains("schema_version 2"));
        assert!(bad(r#"{"schema_version": 1}"#).contains("no `models`"));
        assert!(
            bad(r#"{"schema_version": 1, "models": [{"size_bytes": 1}]}"#)
                .contains("no string `ref`")
        );
        assert!(
            bad(r#"{"schema_version": 1, "models": [{"ref": "a:1"}]}"#).contains("no `size_bytes`")
        );
        assert!(bad(
            r#"{"schema_version": 1, "models": [{"ref": "a:1", "size_bytes": 1, "manifest": {"digest": "md5:x"}}]}"#
        )
        .contains("not sha256"));
        assert!(bad(
            r#"{"schema_version": 1, "models": [{"ref": "a:1", "size_bytes": 1}, {"ref": "a:1", "size_bytes": 1}]}"#
        )
        .contains("twice"));
    }

    #[test]
    fn drift_is_any_difference_in_bytes() {
        let lock = lock_with(
            r#"{"ref": "embed:v1", "size_bytes": 100}, {"ref": "a:1b", "size_bytes": 900}, {"ref": "b:70b", "size_bytes": 5000}, {"ref": "only-in-lock:1", "size_bytes": 7}"#,
        );
        assert_eq!(lock_drift(&packs(), &lock), Vec::<Drift>::new());
        for delta in [-1i64, 1] {
            let size = 900u64.checked_add_signed(delta).unwrap();
            let lock = lock_with(&format!(
                r#"{{"ref": "embed:v1", "size_bytes": 100}}, {{"ref": "a:1b", "size_bytes": {size}}}, {{"ref": "b:70b", "size_bytes": 5000}}"#
            ));
            let drift = lock_drift(&packs(), &lock);
            assert_eq!(
                drift,
                [Drift::Size {
                    reference: "a:1b".into(),
                    catalog: 900,
                    lock: size
                }]
            );
            let text = drift[0].to_string();
            assert!(
                text.contains("900") && text.contains(&format!("{delta:+} B")),
                "{text}"
            );
        }
        // A model the lock never resolved, and the same model in two packs reported once.
        let lock = lock_with(
            r#"{"ref": "a:1b", "size_bytes": 900}, {"ref": "b:70b", "size_bytes": 5000}"#,
        );
        let drift = lock_drift(&packs(), &lock);
        assert_eq!(
            drift,
            [Drift::MissingFromLock {
                reference: "embed:v1".into()
            }]
        );
        assert_eq!(drift[0].reference(), "embed:v1");
        assert!(drift[0].to_string().contains("models lock"));
    }

    #[test]
    fn a_digest_in_the_catalog_must_be_the_one_the_lock_pins() {
        let mut p = packs();
        p[0].models[0].digest = Some(DIGEST_A.into());
        p[1].models[0].digest = Some(DIGEST_A.into());
        let entries = |digest: &str| {
            format!(
                r#"{{"ref": "embed:v1", "size_bytes": 100, "manifest": {{"digest": "{digest}"}}}}, {{"ref": "a:1b", "size_bytes": 900}}, {{"ref": "b:70b", "size_bytes": 5000}}"#
            )
        };
        assert_eq!(
            lock_drift(&p, &lock_with(&entries(DIGEST_A))),
            Vec::<Drift>::new()
        );
        let drift = lock_drift(&p, &lock_with(&entries(DIGEST_B)));
        assert_eq!(
            drift,
            [Drift::Digest {
                reference: "embed:v1".into(),
                catalog: DIGEST_A.into(),
                lock: Some(DIGEST_B.into())
            }]
        );
        assert!(drift[0].to_string().contains(DIGEST_B));
        // The catalog carries a digest but the lock pins none.
        let lock = lock_with(
            r#"{"ref": "embed:v1", "size_bytes": 100}, {"ref": "a:1b", "size_bytes": 900}, {"ref": "b:70b", "size_bytes": 5000}"#,
        );
        assert!(lock_drift(&p, &lock)[0].to_string().contains("pins none"));
    }

    #[test]
    fn resolved_values_prefer_the_lock() {
        let mut p = packs();
        p[0].models[1].digest = Some(DIGEST_A.into());
        let lock = lock_with(&format!(
            r#"{{"ref": "embed:v1", "size_bytes": 111, "manifest": {{"digest": "{DIGEST_B}"}}}}, {{"ref": "a:1b", "size_bytes": 900}}"#
        ));
        let embed = resolve_model(&p[0].models[0], Some(&lock));
        assert_eq!(embed.size_bytes, 111);
        assert_eq!(embed.size_from, Provenance::Lock);
        assert_eq!(embed.digest.as_deref(), Some(DIGEST_B));
        assert_eq!(embed.digest_from, Some(Provenance::Lock));
        // The lock knows the model but pins no digest: the catalog's stays, as the catalog's.
        let a = resolve_model(&p[0].models[1], Some(&lock));
        assert_eq!((a.size_bytes, a.size_from), (900, Provenance::Lock));
        assert_eq!(
            (a.digest.as_deref(), a.digest_from),
            (Some(DIGEST_A), Some(Provenance::Catalog))
        );
        // Unknown to the lock, or no lock at all: the catalog's snapshot.
        let big = resolve_model(&p[1].models[1], Some(&lock));
        assert_eq!(
            (big.size_bytes, big.size_from, big.digest_from),
            (5000, Provenance::Catalog, None)
        );
        assert_eq!(resolve_model(&p[0].models[0], None).size_bytes, 100);

        // Resolved packs feed the fit logic, so a cache is sized from the lock.
        let resolved = resolve_packs(&p, Some(&lock));
        assert_eq!(resolved[0].models[0].size_bytes, 111);
        assert_eq!(resolved[0].models[0].digest.as_deref(), Some(DIGEST_B));
        assert_eq!(resolved[0].models[1].name, "a", "every other field is kept");
        assert_eq!(resolved[0].size_bytes(), 1011);
        assert_eq!(resolve_packs(&p, None), p);
        assert_eq!(fit_report(&resolved, Some(1000)).packs[0].fits, Some(false));
        assert_eq!(fit_report(&p, Some(1000)).packs[0].fits, Some(true));
    }

    /// A lock written from the real catalog agrees with it; moving any one model by a single byte
    /// is reported as exactly that model. (The repository lock does not exist yet, so this is the
    /// stand-in that exercises the comparison on the real catalog's shape and size.)
    #[test]
    fn a_one_byte_change_to_any_catalog_model_is_flagged() {
        let cat = repo_catalog();
        let mut refs: Vec<(String, u64)> = cat
            .packs
            .iter()
            .flat_map(|p| &p.models)
            .map(|m| (m.reference(), m.size_bytes))
            .collect();
        refs.sort();
        refs.dedup();
        assert!(refs.len() >= 30, "{} distinct models", refs.len());
        let lock_of = |sizes: &[(String, u64)]| {
            lock_with(
                &sizes
                    .iter()
                    .map(|(r, n)| format!("{{\"ref\": \"{r}\", \"size_bytes\": {n}}}"))
                    .collect::<Vec<_>>()
                    .join(","),
            )
        };
        assert_eq!(lock_drift(&cat.packs, &lock_of(&refs)), Vec::<Drift>::new());
        for i in 0..refs.len() {
            for delta in [-1i64, 1] {
                let mut moved = refs.clone();
                moved[i].1 = moved[i].1.checked_add_signed(delta).unwrap();
                let drift = lock_drift(&cat.packs, &lock_of(&moved));
                assert_eq!(drift.len(), 1, "{} {delta:+}: {drift:?}", refs[i].0);
                assert_eq!(drift[0].reference(), refs[i].0);
            }
        }
        // Dropping a model from the lock is a different finding.
        let drift = lock_drift(&cat.packs, &lock_of(&refs[1..]));
        assert_eq!(
            drift,
            [Drift::MissingFromLock {
                reference: refs[0].0.clone()
            }]
        );
    }

    #[test]
    fn repository_files_are_found_from_any_directory_below_the_root() {
        let tmp = tempfile::tempdir().unwrap();
        let deep = tmp.path().join("stick/crates/x");
        std::fs::create_dir_all(&deep).unwrap();
        assert_eq!(find_lock(&deep), None, "no lock yet");
        let manifest = tmp.path().join("core/manifest");
        std::fs::create_dir_all(&manifest).unwrap();
        for rel in [LOCK_REL_PATH, LICENSES_REL_PATH, CATALOG_REL_PATH] {
            std::fs::write(tmp.path().join(rel), b"x").unwrap();
        }
        assert_eq!(find_lock(&deep), Some(tmp.path().join(LOCK_REL_PATH)));
        assert_eq!(
            find_licenses(&deep),
            Some(tmp.path().join(LICENSES_REL_PATH))
        );
        assert_eq!(find_catalog(&deep), Some(tmp.path().join(CATALOG_REL_PATH)));
    }

    /// The catalog's `size_bytes` are a copy of the lock's. Once `ci-stick models lock` has
    /// written `core/manifest/model-packs.lock.json`, a catalog that is off by one byte fails.
    /// Before that the test says it did nothing.
    #[test]
    fn catalog_sizes_match_the_lock_when_it_exists() {
        let Some(lock_path) = find_lock(Path::new(env!("CARGO_MANIFEST_DIR"))) else {
            skip_visibly(&format!(
                "{LOCK_REL_PATH} does not exist yet (`ci-stick models lock` writes it); the \
                 catalog sizes were NOT compared with a lock. Known drift until then: \
                 glm-ocr:latest is 2,655,025,740 B at the registry (2026-10-17), 2,219,299,168 B here."
            ));
            return;
        };
        let lock = LockView::load(&lock_path).unwrap();
        let cat = repo_catalog();
        let drift = lock_drift(&cat.packs, &lock);
        assert!(
            drift.is_empty(),
            "core/manifest/model-packs.yaml drifted from {}; update the YAML from the lock \
             (the lock is what the registry said):\n  {}",
            lock_path.display(),
            drift
                .iter()
                .map(Drift::to_string)
                .collect::<Vec<_>>()
                .join("\n  ")
        );
    }

    // ---- agreement with the download code ----

    /// The catalog's spelling rules and the downloader's reference parser are two
    /// implementations of one grammar. Every Ollama model of the real catalog parses and comes
    /// back spelled the same; a Hugging Face model is recognised as one (and refused by the
    /// Ollama-only first release).
    #[test]
    fn the_catalog_and_the_downloader_read_every_reference_alike() {
        use crate::manifest::ModelSource;
        use crate::registry::ollama::{ModelRef, RefError};
        let cat = repo_catalog();
        for m in cat.packs.iter().flat_map(|p| &p.models) {
            let r = m.reference();
            match m.source() {
                ModelSource::Ollama => {
                    let parsed = ModelRef::parse(&r).unwrap_or_else(|e| panic!("{r}: {e}"));
                    assert_eq!(parsed.reference(), r);
                }
                ModelSource::HuggingFace => {
                    assert!(
                        matches!(ModelRef::parse(&r), Err(RefError::HuggingFace(_))),
                        "{r}"
                    );
                }
            }
        }
        // And where the catalog refuses a spelling, so does the downloader (a model the catalog
        // would never list cannot be fetched by hand-editing a lock either). The one rule only
        // the catalog applies is the `:cloud` tag.
        for (name, tag) in [
            ("gemma 3", "1b"),
            ("-gemma", "1b"),
            ("gemma3.", "1b"),
            ("gemma3", "q4."),
            ("gemma3", "1b:q4"),
            ("a/b/c", "latest"),
            ("registry.example.com/ns/model", "1b"),
            ("con", "latest"),
            ("model", "nul.gguf"),
            ("model", "COM3"),
            ("gemma\\3", "1b"),
            ("..", "1b"),
        ] {
            let m = model(name, tag, 1);
            assert!(
                m.ref_problem().is_some(),
                "{name}:{tag} should be refused by the catalog"
            );
            assert!(
                ModelRef::parse(&m.reference()).is_err(),
                "{name}:{tag} is refused by the catalog but accepted by the downloader"
            );
        }
        assert!(model("gpt-oss", "120b-cloud", 1).ref_problem().is_some());
        assert!(
            ModelRef::parse("gpt-oss:120b-cloud").is_ok(),
            "cloud tags are a catalog rule"
        );
    }

    /// Both readers of the lock file see the same facts, and name the same file.
    #[test]
    fn the_lock_view_and_the_lock_writer_agree() {
        use crate::lockfile::{self, ModelLock};
        assert_eq!(LOCK_REL_PATH, lockfile::LOCK_REL_PATH);
        assert_eq!(LOCK_SCHEMA_VERSION, lockfile::LOCK_SCHEMA_VERSION);
        let Some(path) = find_lock(Path::new(env!("CARGO_MANIFEST_DIR"))) else {
            skip_visibly(&format!(
                "{LOCK_REL_PATH} does not exist yet; LockView was not compared with ModelLock."
            ));
            return;
        };
        let full = ModelLock::load(&path).unwrap();
        let view = LockView::load(&path).unwrap();
        assert_eq!(view.len(), full.models.len());
        for m in &full.models {
            let v = view
                .get(&m.reference)
                .unwrap_or_else(|| panic!("{} missing", m.reference));
            assert_eq!(v.size_bytes, m.size_bytes, "{}", m.reference);
            assert_eq!(
                v.digest.as_deref(),
                Some(m.manifest.digest.as_str()),
                "{}",
                m.reference
            );
        }
    }

    // ---- licences ----

    #[test]
    fn every_pack_license_is_listed() {
        let cat = repo_catalog();
        let table = repo_licenses();
        let mut unlisted = BTreeSet::new();
        for m in cat.packs.iter().flat_map(|p| &p.models) {
            if table.lookup(&m.license).is_none() && !table.is_release_blocking(&m.license) {
                unlisted.insert(format!("{} ({})", m.license, m.reference()));
            }
        }
        assert!(
            unlisted.is_empty(),
            "licences missing from core/manifest/licenses.yaml: {unlisted:?}"
        );
    }

    #[test]
    fn the_release_gate_list_is_explicit_and_the_shipping_packs_pass_it() {
        let table = repo_licenses();
        // The list is pinned: widening or emptying it is a reviewed change to this test.
        assert_eq!(table.release_blocking, ["unverified"]);
        assert!(table.is_release_blocking("unverified"));
        assert!(table.is_release_blocking(" Unverified "));
        assert!(
            table.lookup("unverified").is_none(),
            "unverified is not a licence"
        );
        assert!(!table.is_release_blocking("Apache-2.0"));

        // What the gate does: both an `unverified` entry and a licence nobody listed block.
        let mut p = packs();
        p[0].models[0].license = "unverified".into();
        p[1].models[1].license = "Totally New License 1.0".into();
        p[1].models[0].license = "Gemma Terms of Use".into();
        let blockers = release_blockers(&p, &table);
        assert_eq!(
            blockers,
            [
                ReleaseBlocker {
                    pack: "small".into(),
                    reference: "embed:v1".into(),
                    license: "unverified".into(),
                    reason: BlockReason::Unverified
                },
                ReleaseBlocker {
                    pack: "big".into(),
                    reference: "b:70b".into(),
                    license: "Totally New License 1.0".into(),
                    reason: BlockReason::NotInTable
                }
            ]
        );

        // The packs that ship on a stick carry no blocker today.
        let cat = repo_catalog();
        for name in ["stick-128", "stick-128-oci", APPLIANCE_CORE_PACK] {
            let pack: Vec<ModelPack> = cat
                .packs
                .iter()
                .filter(|p| p.name == name)
                .cloned()
                .collect();
            assert_eq!(pack.len(), 1, "{name}");
            assert_eq!(
                release_blockers(&pack, &table),
                Vec::<ReleaseBlocker>::new(),
                "{name}"
            );
        }
    }

    #[test]
    fn gemma_and_llama_need_acceptance_and_apache_and_mit_do_not() {
        let table = repo_licenses();
        for (name, accept) in [
            ("Gemma Terms of Use", true),
            ("Llama 3.1 Community License", true),
            ("Llama 3.2 Community License", true),
            ("Llama 3.3 Community License", true),
            ("Apache-2.0", false),
            ("MIT", false),
        ] {
            let l = table
                .lookup(name)
                .unwrap_or_else(|| panic!("{name} missing"));
            assert_eq!(l.acceptance_required(), accept, "{name}");
            assert_eq!(l.gate == LicenseGate::Accept, accept, "{name}");
        }
        // Hugging Face `cardData.license` ids and registry short names resolve to the same rows.
        assert_eq!(table.lookup("gemma").unwrap().name, "Gemma Terms of Use");
        assert_eq!(
            table.lookup("LLAMA3.2").unwrap().name,
            "Llama 3.2 Community License"
        );
        assert_eq!(table.lookup(" apache-2.0 ").unwrap().name, "Apache-2.0");
        assert_eq!(table.lookup("mit").unwrap().spdx, "MIT");
        assert!(table.lookup("llama4").is_none());

        // The models that would need a recorded acceptance, by licence.
        let need = acceptance_required(&repo_catalog().packs, &table);
        assert!(need["Gemma Terms of Use"].contains(&"gemma3:1b".to_string()));
        assert!(need["Llama 3.2 Community License"].contains(&"llama3.2:3b".to_string()));
        assert!(!need.contains_key("Apache-2.0") && !need.contains_key("MIT"));
        let covered: BTreeSet<&String> = need.values().flatten().collect();
        assert!(
            !covered.contains(&"qwen3.6:27b".to_string()),
            "Apache-2.0 needs no acceptance"
        );
        for refs in need.values() {
            let mut sorted = refs.clone();
            sorted.sort();
            sorted.dedup();
            assert_eq!(*refs, sorted, "sorted and distinct");
        }
    }

    #[test]
    fn the_license_table_validates_itself() {
        let table = |licenses: &str, blocking: &str| {
            format!(
                "schema_version: 1\nstatus: provisional\nrelease_blocking: {blocking}\nlicenses:\n{licenses}"
            )
        };
        let row = |name: &str, extra: &str| {
            format!(
                "  - {{name: {name}, spdx: MIT, spdx_listed: true, url: \"https://example.com/l\", gate: none{extra}}}\n"
            )
        };
        let err = |text: String| format!("{:#}", LicenseTable::parse(&text).unwrap_err());

        assert!(LicenseTable::parse(&table(&row("A", ""), "[unverified]")).is_ok());
        assert!(err(table(&row("A", ""), "[]")).contains("release_blocking is empty"));
        assert!(err("schema_version: 1\nstatus: provisional\nrelease_blocking: [unverified]\nlicenses: []\n".to_string())
            .contains("no licences"));
        assert!(err(table(
            &format!("{}{}", row("A", ""), row("a", "")),
            "[unverified]"
        ))
        .contains("belongs to both"));
        assert!(
            err(table(&row("A", ", aliases: [unverified]"), "[unverified]"))
                .contains("belongs to both"),
            "an alias cannot also be a blocking string"
        );
        assert!(err(table(&row("A", ", aliases: [\"\"]"), "[unverified]"))
            .contains("empty name or alias"));
        assert!(err(table(
            &row("A", "").replace("https://", "http://"),
            "[unverified]"
        ))
        .contains("url must be https"));
        assert!(err(table(
            &row("A", "").replace("MIT, spdx_listed: true", "LicenseRef-X, spdx_listed: true"),
            "[unverified]"
        ))
        .contains("exactly when spdx_listed is false"));
        assert!(err(table(
            &row("A", "").replace("spdx_listed: true", "spdx_listed: false"),
            "[unverified]"
        ))
        .contains("exactly when spdx_listed is false"));
        assert!(err(table(
            &row("A", "").replace("gate: none", "gate: maybe"),
            "[unverified]"
        ))
        .contains("does not match its schema"));
        assert!(err(table(&row("A", ", nonsense: 1"), "[unverified]"))
            .contains("does not match its schema"));
        assert!(err(
            table(&row("A", ""), "[unverified]").replace("schema_version: 1", "schema_version: 2")
        )
        .contains("unsupported schema_version 2"));
    }

    #[test]
    fn ecosystem_models_become_references() {
        let yaml = "llm:\n  provider: ollama\n  models: [nomic-embed-text, \"gemma3:1b\", \"qwen3.6:27b\"]\n";
        assert_eq!(
            ecosystem_llm_refs(yaml).unwrap(),
            ["nomic-embed-text:latest", "gemma3:1b", "qwen3.6:27b"]
        );
        assert!(ecosystem_llm_refs("llm: {}\n").is_err());
        assert!(ecosystem_llm_refs("llm: {models: [1]}\n").is_err());
        assert!(ecosystem_llm_refs("- not a mapping\n").is_err());
    }
}
