//! What a `plan` or `fetch` run would do: which blobs a selection needs, what is already in
//! the cache, whether it fits.
//!
//! Space accounting is by digest, not by model: blobs shared between models (the Apache
//! licence text, for one) count once. "Fits" is two questions, both asked in bytes rounded up
//! to the file system's cluster size:
//!
//! * **capacity**: is the whole selection at most 97 % of the volume's capacity? This is the
//!   3 % rule of `packs.rs` (a pack must leave 3 % of the cache free for exFAT overhead and
//!   temporary files), so a pack that could never be comfortable on this volume says so.
//! * **free space**: are the bytes still to be written (partials already count) within the
//!   free space, less a small fixed reserve? This is what decides whether `fetch` starts.
//!
//! `fits` is both together.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Serialize;

use crate::cache::partial::{read_journal, Journal};
use crate::cache::store::{ManifestState, Store};
use crate::cache::{fs_stats, FsStats};
use crate::lockfile::{LockedModel, ModelLock};
use crate::registry::ollama::{digest_hex, ModelRef};

/// exFAT cluster size `mkfs.exfat` picks above 32 GiB (every file occupies at least one).
pub const CLUSTER_BYTES: u64 = 128 * 1024;
/// Kept free for temporary files, journals and the status file while fetching.
pub const RESERVE_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Selection {
    Pack(String),
    Model(String),
}

/// Licences that need a human decision before their model is downloaded. Only
/// `unverified` is gated today; extend here when `licenses.yaml` exists.
pub fn license_needs_acceptance(license: &str) -> bool {
    let l = license.trim();
    l.is_empty() || l.eq_ignore_ascii_case("unverified")
}

pub fn round_up_to_cluster(bytes: u64) -> u64 {
    bytes
        .max(1)
        .div_ceil(CLUSTER_BYTES)
        .saturating_mul(CLUSTER_BYTES)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BlobState {
    Present,
    Partial { committed: u64 },
    Missing,
}

#[derive(Debug, Clone)]
pub struct PlanBlob {
    pub hex: String,
    pub digest: String,
    pub size: u64,
    /// Models (references) that need this blob, in plan order.
    pub models: Vec<String>,
    /// Repository path for the registry URL (the first model's).
    pub repo: String,
    /// Bytes from the lock, for blobs that need no network.
    pub inline: Option<Vec<u8>>,
    pub state: BlobState,
}

impl PlanBlob {
    /// Bytes still to be written.
    pub fn missing_bytes(&self) -> u64 {
        match self.state {
            BlobState::Present => 0,
            BlobState::Partial { committed } => self.size.saturating_sub(committed),
            BlobState::Missing => self.size,
        }
    }
    /// Bytes this blob holds in the cache right now.
    pub fn present_bytes(&self) -> u64 {
        match self.state {
            BlobState::Present => self.size,
            _ => 0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct PlanModel {
    pub reference: String,
    pub size_bytes: u64,
    pub license: String,
    pub gated: bool,
    /// Unique blob hexes in manifest order.
    pub blobs: Vec<String>,
    pub manifest: ManifestState,
    /// Bytes of this model's blobs already present as complete files.
    pub present_bytes: u64,
    pub complete: bool,
}

#[derive(Debug, Clone)]
pub struct Plan {
    pub pack: Option<String>,
    pub models: Vec<PlanModel>,
    /// Unique blobs of the models that will be fetched (gated ones excluded).
    pub blobs: Vec<PlanBlob>,
    pub fs: FsStats,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct PlanTotals {
    /// Unique blobs of the models that would be fetched.
    pub total_bytes: u64,
    /// Already present as complete blobs.
    pub present_bytes: u64,
    /// Held in resumable partials.
    pub partial_bytes: u64,
    /// Still to be downloaded or written.
    pub missing_bytes: u64,
    /// What the bytes still to be written occupy on disk (cluster rounding, manifest files).
    pub need_on_disk_bytes: u64,
    /// What the whole selection occupies on disk, present or not.
    pub total_on_disk_bytes: u64,
    /// Models the licence rule keeps out of this run.
    pub gated_models: usize,
    pub gated_bytes: u64,
    pub free_bytes: Option<u64>,
    pub capacity_bytes: Option<u64>,
    /// The whole selection is at most 97 % of the capacity (the 3 % rule of `packs.rs`).
    pub fits_capacity: Option<bool>,
    /// The bytes still to write, plus a small reserve, are within the free space.
    pub fits_free: Option<bool>,
    /// Both of the above; `None` when the volume is unknown.
    pub fits: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ModelReport {
    pub model: String,
    pub size_bytes: u64,
    pub license: String,
    pub gated: bool,
    pub bytes_present: u64,
    pub complete: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlanReport {
    pub pack: Option<String>,
    pub models: Vec<ModelReport>,
    #[serde(flatten)]
    pub totals: PlanTotals,
    pub fs_type: Option<String>,
    pub ram_backed: Option<bool>,
}

#[derive(Debug, thiserror::Error)]
pub enum PlanError {
    #[error("pack {name:?} is not in the lock (known packs: {known})")]
    UnknownPack { name: String, known: String },
    #[error("{0:?} is not in the lock: fetch only downloads reviewed references (see `ci-stick models lock`)")]
    UnknownModel(String),
    #[error("{0}")]
    Invalid(String),
}

/// Build the plan. `cache` is optional so `plan` can run without one (everything missing).
pub fn build_plan(
    lock: &ModelLock,
    selection: &Selection,
    cache: Option<&Path>,
    accept_licenses: bool,
) -> Result<Plan, PlanError> {
    let (pack_name, selected): (Option<String>, Vec<&LockedModel>) = match selection {
        Selection::Pack(name) => {
            let models = lock.pack(name).ok_or_else(|| PlanError::UnknownPack {
                name: name.clone(),
                known: lock.packs.keys().cloned().collect::<Vec<_>>().join(", "),
            })?;
            (Some(name.clone()), models)
        }
        Selection::Model(r) => {
            let m = lock
                .find_model(r)
                .ok_or_else(|| PlanError::UnknownModel(r.clone()))?;
            (None, vec![m])
        }
    };
    let store = cache.map(Store::new);
    let mut models = Vec::new();
    let mut blobs: BTreeMap<String, PlanBlob> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();
    for m in selected {
        let mref = ModelRef::parse(&m.reference).map_err(|e| PlanError::Invalid(e.to_string()))?;
        let gated = !accept_licenses && license_needs_acceptance(&m.license);
        let mut hexes: Vec<String> = Vec::new();
        for l in &m.layers {
            let hex = digest_hex(&l.digest)
                .ok_or_else(|| {
                    PlanError::Invalid(format!("{}: malformed digest {}", m.reference, l.digest))
                })?
                .to_string();
            if !hexes.contains(&hex) {
                hexes.push(hex.clone());
            }
            if gated {
                continue;
            }
            match blobs.get_mut(&hex) {
                Some(b) => {
                    if b.size != l.real_size() {
                        return Err(PlanError::Invalid(format!(
                            "{}: blob {} is {} bytes here but {} in another model",
                            m.reference,
                            l.digest,
                            l.real_size(),
                            b.size
                        )));
                    }
                    if !b.models.contains(&m.reference) {
                        b.models.push(m.reference.clone());
                    }
                }
                None => {
                    let state = blob_state(store.as_ref(), &hex, l.real_size());
                    blobs.insert(
                        hex.clone(),
                        PlanBlob {
                            hex: hex.clone(),
                            digest: l.digest.clone(),
                            size: l.real_size(),
                            models: vec![m.reference.clone()],
                            repo: mref.repo(),
                            inline: lock.inline_blob(&l.digest),
                            state,
                        },
                    );
                    order.push(hex);
                }
            }
        }
        let manifest = match &store {
            Some(s) => s
                .manifest_state(
                    &mref.manifest_components(),
                    digest_hex(&m.manifest.digest).unwrap_or(""),
                )
                .unwrap_or(ManifestState::Missing),
            None => ManifestState::Missing,
        };
        models.push(PlanModel {
            reference: m.reference.clone(),
            size_bytes: m.size_bytes,
            license: m.license.clone(),
            gated,
            blobs: hexes,
            manifest,
            present_bytes: 0,
            complete: false,
        });
    }
    // completeness needs the final blob states
    for m in &mut models {
        m.present_bytes = m
            .blobs
            .iter()
            .filter_map(|h| blobs.get(h))
            .map(PlanBlob::present_bytes)
            .sum();
        m.complete = !m.gated
            && m.manifest == ManifestState::Matches
            && m.blobs
                .iter()
                .all(|h| blobs.get(h).is_some_and(|b| b.state == BlobState::Present));
    }
    let fs = cache.map(fs_stats).unwrap_or_default();
    Ok(Plan {
        pack: pack_name,
        models,
        blobs: order.iter().filter_map(|h| blobs.remove(h)).collect(),
        fs,
    })
}

fn blob_state(store: Option<&Store>, hex: &str, size: u64) -> BlobState {
    let Some(store) = store else {
        return BlobState::Missing;
    };
    if store.has_blob(hex, size) {
        return BlobState::Present;
    }
    let journal_path = store.layout().journal_path(hex);
    let data_path = store.layout().partial_path(hex);
    if let (Ok(jp), Ok(dp)) = (journal_path, data_path) {
        if let Some(Journal { committed, .. }) = read_journal(&jp).filter(|j| j.matches(hex, size))
        {
            let on_disk = std::fs::metadata(&dp).map_or(0, |m| m.len());
            let committed = committed.min(on_disk);
            if committed > 0 {
                return BlobState::Partial { committed };
            }
        }
    }
    BlobState::Missing
}

impl Plan {
    pub fn totals(&self) -> PlanTotals {
        let total_bytes: u64 = self.blobs.iter().map(|b| b.size).sum();
        let present_bytes: u64 = self.blobs.iter().map(PlanBlob::present_bytes).sum();
        let partial_bytes: u64 = self
            .blobs
            .iter()
            .map(|b| match b.state {
                BlobState::Partial { committed } => committed,
                _ => 0,
            })
            .sum();
        let missing_bytes: u64 = self.blobs.iter().map(PlanBlob::missing_bytes).sum();
        // On disk: every missing file occupies whole clusters; a partial already holds some.
        let mut need = 0u64;
        for b in &self.blobs {
            match b.state {
                BlobState::Present => {}
                BlobState::Missing => need = need.saturating_add(round_up_to_cluster(b.size)),
                BlobState::Partial { committed } => {
                    need = need.saturating_add(
                        round_up_to_cluster(b.size).saturating_sub(round_up_to_cluster(committed)),
                    );
                }
            }
        }
        for m in self.models.iter().filter(|m| !m.gated) {
            if m.manifest != ManifestState::Matches {
                need = need.saturating_add(CLUSTER_BYTES);
            }
        }
        let manifest_files = self.models.iter().filter(|m| !m.gated).count() as u64;
        let total_on_disk = self
            .blobs
            .iter()
            .fold(manifest_files * CLUSTER_BYTES, |acc, b| {
                acc.saturating_add(round_up_to_cluster(b.size))
            });
        let gated: Vec<&PlanModel> = self.models.iter().filter(|m| m.gated).collect();
        let free = self.fs.free_bytes;
        let capacity = self.fs.total_bytes;
        let fits_capacity = capacity.map(|c| u128::from(total_on_disk) * 100 <= u128::from(c) * 97);
        let fits_free = free.map(|f| need.saturating_add(RESERVE_BYTES) <= f);
        let fits = match (fits_capacity, fits_free) {
            (Some(false), _) | (_, Some(false)) => Some(false),
            (Some(true), Some(true)) => Some(true),
            (Some(true), None) | (None, Some(true)) => Some(true),
            (None, None) => None,
        };
        PlanTotals {
            total_bytes,
            present_bytes,
            partial_bytes,
            missing_bytes,
            need_on_disk_bytes: need,
            total_on_disk_bytes: total_on_disk,
            gated_models: gated.len(),
            gated_bytes: gated.iter().map(|m| m.size_bytes).sum(),
            free_bytes: free,
            capacity_bytes: capacity,
            fits_capacity,
            fits_free,
            fits,
        }
    }

    pub fn report(&self) -> PlanReport {
        PlanReport {
            pack: self.pack.clone(),
            models: self
                .models
                .iter()
                .map(|m| ModelReport {
                    model: m.reference.clone(),
                    size_bytes: m.size_bytes,
                    license: m.license.clone(),
                    gated: m.gated,
                    bytes_present: m.present_bytes,
                    complete: m.complete,
                })
                .collect(),
            totals: self.totals(),
            fs_type: self.fs.fs_type.clone(),
            ram_backed: self.fs.ram_backed,
        }
    }

    /// `true` if running this plan would write nothing.
    pub fn nothing_to_do(&self) -> bool {
        self.models.iter().all(|m| m.gated || m.complete)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounding_and_licence_rule() {
        assert_eq!(round_up_to_cluster(0), CLUSTER_BYTES);
        assert_eq!(round_up_to_cluster(1), CLUSTER_BYTES);
        assert_eq!(round_up_to_cluster(CLUSTER_BYTES), CLUSTER_BYTES);
        assert_eq!(round_up_to_cluster(CLUSTER_BYTES + 1), 2 * CLUSTER_BYTES);
        assert!(license_needs_acceptance("unverified"));
        assert!(license_needs_acceptance(" Unverified "));
        assert!(license_needs_acceptance(""));
        assert!(!license_needs_acceptance("Apache-2.0"));
        assert!(!license_needs_acceptance("Gemma Terms of Use"));
    }
}
