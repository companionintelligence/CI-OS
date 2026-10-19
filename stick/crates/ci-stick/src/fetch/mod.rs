//! `ci-stick models fetch`: seed a model cache from the registry, from a reviewed lock.
//!
//! * [`plan`]: what a selection needs and what is already there
//! * [`download`]: one blob, resumable and verified
//! * [`throttle`]: the shared `--max-bytes-per-sec` limiter
//! * this module: the job (licence gating, space check, workers, manifests, exit codes)
//!
//! The cache root must already exist; `fetch` creates everything below it but never the
//! directory itself.
//!
//! Order of work (report 03 section 4.3): the small blobs from the lock are written first
//! (no network), the big blobs are downloaded by `concurrency` workers, and a model's
//! manifest is written only after every one of its blobs verified, so a daemon scanning the
//! store never meets a manifest whose blobs are missing. After a hard failure of one blob
//! (integrity, 404) the other models carry on; running out of space, a network that stays
//! down after the retry budget, or an interrupt stop the whole job, leaving resumable
//! partials behind.

pub mod download;
pub mod plan;
pub mod throttle;

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;

use crate::cache::sink::{is_no_space, SinkFactory};
use crate::cache::store::{ManifestState, Store};
use crate::events::{ModelStatus, Reporter};
use crate::hashing::sha256_hex;
use crate::lockfile::ModelLock;
use crate::registry::ollama::{digest_hex, ModelRef};
use crate::registry::RegistryClient;

use download::{download_blob, BlobJob, BlobResult, DownloadCtx, Obs};
pub use download::{ChunkPolicy, TransferOptions};
pub use plan::{build_plan, Plan, PlanError, Selection};
use plan::{BlobState, PlanBlob};
use throttle::Throttle;

/// Process exit codes of the `models` commands.
pub mod exit {
    pub const OK: u8 = 0;
    /// A non-resumable error.
    pub const ERROR: u8 = 1;
    pub const USAGE: u8 = 2;
    /// `lock --check` found drift.
    pub const DRIFT: u8 = 3;
    pub const NO_SPACE: u8 = 4;
    pub const LICENSE: u8 = 5;
    /// Interrupted, or the network was lost: partials are kept and a rerun resumes.
    pub const INTERRUPTED: u8 = 6;
    pub const INTEGRITY: u8 = 7;
}

#[derive(Debug, Clone)]
pub struct FetchOptions {
    pub cache: PathBuf,
    pub offline: bool,
    pub accept_licenses: bool,
    pub max_bytes_per_sec: Option<u64>,
    /// Blobs downloaded at the same time (one connection each).
    pub concurrency: usize,
    pub transfer: TransferOptions,
}

impl FetchOptions {
    pub fn new(cache: impl Into<PathBuf>) -> Self {
        Self {
            cache: cache.into(),
            offline: false,
            accept_licenses: false,
            max_bytes_per_sec: None,
            concurrency: 1,
            transfer: TransferOptions::default(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchOutcome {
    pub exit: u8,
    /// `ok`, `failed` or `interrupted`.
    pub status: &'static str,
    pub models_ok: usize,
    pub models_failed: usize,
    pub models_gated: usize,
    pub bytes_downloaded: u64,
    pub blobs_downloaded: usize,
    pub blobs_skipped: usize,
    pub errors: Vec<String>,
}

/// More urgent exit codes win when several things went wrong.
fn severity(code: u8) -> u8 {
    match code {
        exit::INTEGRITY => 5,
        exit::NO_SPACE => 4,
        exit::ERROR => 3,
        exit::INTERRUPTED => 2,
        exit::LICENSE => 1,
        _ => 0,
    }
}

struct Tracker {
    /// Per model: blob hexes not yet in the store.
    remaining: BTreeMap<String, Vec<String>>,
    failed: BTreeMap<String, String>,
    done: Vec<String>,
}

struct Shared<'a> {
    opts: &'a FetchOptions,
    lock: &'a ModelLock,
    store: &'a Store,
    client: &'a RegistryClient,
    sinks: &'a dyn SinkFactory,
    throttle: Throttle,
    reporter: &'a Reporter,
    tracker: Mutex<Tracker>,
    next: AtomicUsize,
    stop: AtomicBool,
    exit: Mutex<u8>,
    errors: Mutex<Vec<String>>,
    fetched: Mutex<(u64, usize, usize)>,
}

impl Shared<'_> {
    fn note_exit(&self, code: u8) {
        let mut e = self.exit.lock().unwrap_or_else(|e| e.into_inner());
        if severity(code) > severity(*e) {
            *e = code;
        }
    }

    fn note_error(&self, msg: String) {
        self.errors
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(msg);
    }

    /// A blob is in the store: complete any model that was waiting only for it.
    fn blob_available(&self, hex: &str) {
        let ready: Vec<String> = {
            let mut t = self.tracker.lock().unwrap_or_else(|e| e.into_inner());
            let mut ready = Vec::new();
            for (model, rem) in t.remaining.iter_mut() {
                if let Some(i) = rem.iter().position(|h| h == hex) {
                    rem.swap_remove(i);
                    if rem.is_empty() {
                        ready.push(model.clone());
                    }
                }
            }
            ready.retain(|m| !t.failed.contains_key(m));
            ready
        };
        for m in ready {
            self.finish_model(&m, false);
        }
    }

    /// Every blob of `reference` is present: write its manifest and report it done.
    fn finish_model(&self, reference: &str, skipped: bool) {
        let Some(model) = self.lock.model(reference) else {
            return;
        };
        let result = (|| -> Result<(), String> {
            let mref = ModelRef::parse(reference).map_err(|e| e.to_string())?;
            let bytes = self.lock.manifest_bytes(model).map_err(|e| e.to_string())?;
            let expect = digest_hex(&model.manifest.digest).unwrap_or("");
            let comps = mref.manifest_components();
            match self.store.manifest_state(&comps, expect) {
                Ok(ManifestState::Matches) => Ok(()),
                Ok(_) => self.store.write_manifest(&comps, &bytes).map_err(|e| {
                    if is_no_space(&e) {
                        format!("no space left on the cache volume while writing the manifest: {e}")
                    } else {
                        format!("writing the manifest: {e}")
                    }
                }),
                Err(e) => Err(format!("checking the manifest: {e}")),
            }
        })();
        match result {
            Ok(()) => {
                self.tracker
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .done
                    .push(reference.to_string());
                self.reporter
                    .model_done(reference, model.size_bytes, skipped);
            }
            Err(msg) => self.fail_model(reference, None, "io", &msg, exit::ERROR),
        }
    }

    fn fail_model(
        &self,
        reference: &str,
        blob: Option<&str>,
        code: &str,
        msg: &str,
        exit_code: u8,
    ) {
        let first = {
            let mut t = self.tracker.lock().unwrap_or_else(|e| e.into_inner());
            t.failed
                .insert(reference.to_string(), msg.to_string())
                .is_none()
        };
        if first {
            self.reporter
                .error(Some(reference), blob, code, msg, exit_code, false);
        }
        self.note_exit(exit_code);
        self.note_error(format!("{reference}: {msg}"));
    }

    fn worker(&self, queue: &[&PlanBlob]) {
        loop {
            if self.stop.load(Ordering::Relaxed)
                || self.client.cancel_flag().load(Ordering::Relaxed)
            {
                return;
            }
            let i = self.next.fetch_add(1, Ordering::Relaxed);
            let Some(blob) = queue.get(i) else { return };
            self.run_blob(blob);
        }
    }

    fn run_blob(&self, blob: &PlanBlob) {
        let model = blob.models.first().cloned().unwrap_or_default();
        let digest = blob.digest.as_str();
        let ctx = DownloadCtx {
            client: self.client,
            store: self.store,
            sinks: self.sinks,
            throttle: &self.throttle,
            opts: &self.opts.transfer,
        };
        let job = BlobJob {
            hex: &blob.hex,
            digest,
            size: blob.size,
            repo: &blob.repo,
        };
        let mut obs = |o: Obs| match o {
            Obs::Resumed(c) => self.reporter.credit(&model, c),
            Obs::Restarted => {}
            Obs::Progress { done, delta } => self
                .reporter
                .progress(&model, digest, done, blob.size, delta),
            Obs::Retry { in_s, reason } => self.reporter.retrying("net", &reason, in_s),
        };
        match download_blob(&ctx, job, &mut obs) {
            Ok(result) => {
                let skipped = result == BlobResult::Skipped;
                {
                    let mut f = self.fetched.lock().unwrap_or_else(|e| e.into_inner());
                    match result {
                        BlobResult::Downloaded { fetched } => {
                            f.0 += fetched;
                            f.1 += 1;
                        }
                        BlobResult::Skipped => f.2 += 1,
                    }
                }
                self.reporter.blob_done(&model, digest, blob.size, skipped);
                self.blob_available(&blob.hex);
            }
            Err(e) => {
                let code = e.exit_code();
                let msg = e.to_string();
                if e.stops_the_job() {
                    self.stop.store(true, Ordering::Relaxed);
                    self.reporter
                        .error(Some(&model), Some(digest), e.code(), &msg, code, true);
                    self.note_exit(code);
                    self.note_error(format!("{model}: {msg}"));
                } else {
                    // this blob is lost for good: every model that needs it fails
                    for m in &blob.models {
                        self.fail_model(m, Some(digest), e.code(), &msg, code);
                    }
                }
            }
        }
    }
}

/// Run a fetch. Returns an outcome even when things fail; `Err` is only for a selection
/// the lock cannot satisfy.
pub fn run(
    lock: &ModelLock,
    selection: &Selection,
    opts: &FetchOptions,
    client: &RegistryClient,
    sinks: &dyn SinkFactory,
    reporter: &Reporter,
) -> Result<FetchOutcome, PlanError> {
    // Never create the cache root: a stick that is not mounted leaves an empty mount point
    // behind (or nothing), and a download would silently fill the machine's own disk.
    if !opts.cache.is_dir() {
        return Err(PlanError::Invalid(format!(
            "the cache directory {} does not exist (is the stick mounted?); create it first if you want a new cache there",
            opts.cache.display()
        )));
    }
    let plan = build_plan(lock, selection, Some(&opts.cache), opts.accept_licenses)?;
    let totals = plan.totals();
    let gated: Vec<&plan::PlanModel> = plan.models.iter().filter(|m| m.gated).collect();
    let models_status: Vec<ModelStatus> = plan
        .models
        .iter()
        .map(|m| ModelStatus {
            model: m.reference.clone(),
            state: if m.gated {
                "gated".into()
            } else if m.complete {
                "done".into()
            } else {
                "queued".into()
            },
            bytes_done: if m.complete {
                m.size_bytes
            } else {
                m.present_bytes.min(m.size_bytes)
            },
            bytes_total: m.size_bytes,
        })
        .collect();
    let to_download = totals.missing_bytes;
    reporter.start(
        models_status,
        to_download,
        totals.total_bytes,
        totals.present_bytes,
    );

    let store = Store::new(&opts.cache);
    let mut outcome = FetchOutcome {
        exit: exit::OK,
        status: "ok",
        models_ok: 0,
        models_failed: 0,
        models_gated: gated.len(),
        bytes_downloaded: 0,
        blobs_downloaded: 0,
        blobs_skipped: 0,
        errors: Vec::new(),
    };
    for g in &gated {
        let msg = format!(
            "licence \"{}\" of {} needs an explicit decision: rerun with --accept-licenses once you have read it",
            g.license, g.reference
        );
        reporter.error(
            Some(&g.reference),
            None,
            "license",
            &msg,
            exit::LICENSE,
            false,
        );
        outcome.errors.push(msg);
    }
    let finish = |mut o: FetchOutcome, exit_code: u8| -> FetchOutcome {
        o.exit = exit_code;
        o.status = match exit_code {
            exit::OK => "ok",
            exit::INTERRUPTED => "interrupted",
            _ => "failed",
        };
        reporter.done(
            o.status,
            exit_code,
            o.bytes_downloaded,
            (o.models_ok, o.models_failed, o.models_gated),
        );
        o
    };

    // Preflight: nothing is written if the volume cannot take the pack or is read-only.
    let work_needed = !plan.nothing_to_do();
    if work_needed {
        if plan.fs.read_only == Some(true) {
            let msg = "the cache volume is mounted read-only".to_string();
            reporter.error(None, None, "read-only", &msg, exit::ERROR, true);
            outcome.errors.push(msg);
            return Ok(finish(outcome, exit::ERROR));
        }
        if totals.fits_free == Some(false) {
            let msg = format!(
                "not enough space: {} bytes still to write (plus a {} byte reserve), {} bytes free",
                totals.need_on_disk_bytes,
                plan::RESERVE_BYTES,
                totals.free_bytes.unwrap_or(0)
            );
            reporter.error(None, None, "space", &msg, exit::NO_SPACE, true);
            outcome.errors.push(msg);
            return Ok(finish(outcome, exit::NO_SPACE));
        }
        if let Err(e) = store.ensure_layout() {
            let (code, kind) = if is_no_space(&e) {
                (exit::NO_SPACE, "space")
            } else {
                (exit::ERROR, "io")
            };
            let msg = format!(
                "cannot prepare the cache directory {}: {e}",
                opts.cache.display()
            );
            reporter.error(None, None, kind, &msg, code, true);
            outcome.errors.push(msg);
            return Ok(finish(outcome, code));
        }
    }

    let tracker = Tracker {
        remaining: plan
            .models
            .iter()
            .filter(|m| !m.gated)
            .map(|m| {
                let rem: Vec<String> = m
                    .blobs
                    .iter()
                    .filter(|h| {
                        plan.blobs
                            .iter()
                            .any(|b| &b.hex == *h && b.state != BlobState::Present)
                    })
                    .cloned()
                    .collect();
                (m.reference.clone(), rem)
            })
            .collect(),
        failed: BTreeMap::new(),
        done: Vec::new(),
    };
    let shared = Shared {
        opts,
        lock,
        store: &store,
        client,
        sinks,
        throttle: Throttle::new(opts.max_bytes_per_sec),
        reporter,
        tracker: Mutex::new(tracker),
        next: AtomicUsize::new(0),
        stop: AtomicBool::new(false),
        exit: Mutex::new(exit::OK),
        errors: Mutex::new(Vec::new()),
        fetched: Mutex::new((0, 0, 0)),
    };

    // 1. models whose blobs are all in place already: make sure the manifest is right
    let ready: Vec<(String, bool)> = {
        let t = shared.tracker.lock().unwrap_or_else(|e| e.into_inner());
        plan.models
            .iter()
            .filter(|m| !m.gated && t.remaining.get(&m.reference).is_some_and(Vec::is_empty))
            .map(|m| (m.reference.clone(), m.complete))
            .collect()
    };
    for (reference, was_complete) in ready {
        shared.finish_model(&reference, was_complete);
    }

    // 2. small blobs from the lock: no network
    for b in &plan.blobs {
        if b.state == BlobState::Present {
            continue;
        }
        let Some(bytes) = &b.inline else { continue };
        if sha256_hex(bytes) != b.hex {
            let msg = format!(
                "inline blob sha256:{} in the lock does not hash to its digest",
                b.hex
            );
            for m in &b.models {
                shared.fail_model(m, Some(&b.digest), "integrity", &msg, exit::INTEGRITY);
            }
            continue;
        }
        match store.write_blob_bytes(&b.hex, bytes) {
            Ok(()) => {
                reporter.blob_done(
                    b.models.first().map_or("", String::as_str),
                    &b.digest,
                    b.size,
                    false,
                );
                shared.blob_available(&b.hex);
            }
            Err(e) => {
                let (code, kind) = if is_no_space(&e) {
                    (exit::NO_SPACE, "space")
                } else {
                    (exit::ERROR, "io")
                };
                let msg = format!("writing sha256:{}: {e}", b.hex);
                reporter.error(None, Some(&b.digest), kind, &msg, code, true);
                shared.note_exit(code);
                shared.note_error(msg);
                shared.stop.store(true, Ordering::Relaxed);
                break;
            }
        }
    }

    // 3. the big blobs
    let queue: Vec<&PlanBlob> = plan
        .blobs
        .iter()
        .filter(|b| b.state != BlobState::Present && b.inline.is_none())
        .collect();
    if opts.offline && !queue.is_empty() && !shared.stop.load(Ordering::Relaxed) {
        let msg = format!(
            "offline mode: {} blobs ({} bytes) are missing and cannot be downloaded",
            queue.len(),
            queue.iter().map(|b| b.missing_bytes()).sum::<u64>()
        );
        reporter.error(None, None, "offline", &msg, exit::INTERRUPTED, true);
        shared.note_exit(exit::INTERRUPTED);
        shared.note_error(msg);
    } else if !shared.stop.load(Ordering::Relaxed) {
        let workers = opts.concurrency.clamp(1, 16).min(queue.len().max(1));
        std::thread::scope(|s| {
            for _ in 0..workers {
                s.spawn(|| shared.worker(&queue));
            }
        });
    }

    // 4. outcome
    let cancelled = client.cancel_flag().load(Ordering::Relaxed);
    let t = shared.tracker.lock().unwrap_or_else(|e| e.into_inner());
    outcome.models_ok = t.done.len();
    outcome.models_failed = t.failed.len();
    drop(t);
    let (bytes, downloaded, skipped) = *shared.fetched.lock().unwrap_or_else(|e| e.into_inner());
    outcome.bytes_downloaded = bytes;
    outcome.blobs_downloaded = downloaded;
    outcome.blobs_skipped = skipped;
    outcome.errors.extend(
        shared
            .errors
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .cloned(),
    );
    let mut code = *shared.exit.lock().unwrap_or_else(|e| e.into_inner());
    if cancelled && severity(code) < severity(exit::INTERRUPTED) {
        code = exit::INTERRUPTED;
    }
    if code == exit::OK && !gated.is_empty() {
        code = exit::LICENSE;
    }
    // A model that neither finished nor failed was cut short.
    if code == exit::OK && outcome.models_ok + outcome.models_gated < plan.models.len() {
        code = exit::INTERRUPTED;
    }
    Ok(finish(outcome, code))
}
