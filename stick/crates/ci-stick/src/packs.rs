//! Model-pack catalog (`core/manifest/model-packs.yaml`) and fit logic.
//!
//! "All models" is unbounded, so a stick carries curated, named packs. The catalog is
//! provisional until it is generated from CI Hub's curated model catalog; its model
//! entries use exactly the [`Model`](crate::manifest::Model) type recorded in
//! `bundle.json`, so a pack moves from catalog to bundle unchanged.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context as _};
use serde::{Deserialize, Serialize};

use crate::manifest::{validate_packs, ModelPack, Platform};
use crate::size::{fmt_binary, fmt_decimal};

pub const CATALOG_SCHEMA_VERSION: u32 = 1;
/// Repository-relative location of the catalog.
pub const CATALOG_REL_PATH: &str = "core/manifest/model-packs.yaml";

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
        let problems = validate_packs(&cat.packs);
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

/// Find `core/manifest/model-packs.yaml` by walking up from `start`.
pub fn find_catalog(start: &Path) -> Option<PathBuf> {
    start
        .ancestors()
        .map(|dir| dir.join(CATALOG_REL_PATH))
        .find(|p| p.is_file())
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
        let path = find_catalog(Path::new(env!("CARGO_MANIFEST_DIR"))).expect("catalog in repo");
        let cat = PackCatalog::load(&path).unwrap();
        let names: Vec<&str> = cat.packs.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["starter", "balanced", "coding", "vision", "large"]);
        assert_eq!(cat.status, "provisional");
        // Digests are resolved by a later `models lock` step, never invented by hand.
        assert!(cat
            .packs
            .iter()
            .flat_map(|p| &p.models)
            .all(|m| m.digest.is_none()));
        // Every model the ecosystem manifest pre-pulls is in some pack.
        for wanted in ["nomic-embed-text:latest", "gemma3:1b", "qwen3.6:27b"] {
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
    }

    #[test]
    fn rejects_bad_catalogs() {
        assert!(PackCatalog::parse("schema_version: 2\nstatus: x\npacks: []\n").is_err());
        let bad_digest = r#"
schema_version: 1
status: provisional
packs:
  - name: p
    description: d
    models:
      - {name: m, tag: t, digest: "abc", quantization: q, license: l,
         size_bytes: 1, min_ram_gb: 1, min_vram_gb: null, platforms: [linux-x86_64]}
"#;
        let err = PackCatalog::parse(bad_digest).unwrap_err();
        assert!(format!("{err:#}").contains("digest"));
    }
}
