//! `ci-stick models plan | lock | fetch | cache-info`: the model download and cache tooling.
//!
//! This header is the CLI contract that the OS-side shell adapter (`core/lib`) calls; the
//! same text, in prose, is in `stick/README.md`. `models list` (pack fit table) is older and
//! lives in `main.rs`.
//!
//! ```text
//! ci-stick models plan  --pack NAME [--cache DIR] [--lock FILE] [--accept-licenses] [--json]
//! ci-stick models lock  [--packs FILE] [--out FILE] [--check] [--registry-url URL] [--json]
//! ci-stick models fetch (--pack NAME | --model REF) [--cache DIR] [--lock FILE] [--offline]
//!                       [--accept-licenses] [--max-bytes-per-sec N] [--concurrency N]
//!                       [--registry-url URL] [--events FILE|-] [--json]
//! ci-stick models cache-info [--cache DIR] [--lock FILE] [--json]
//! ```
//!
//! * `plan`: what `fetch` would do for a pack: models, bytes, bytes already present or in
//!   resumable partials, bytes still to download, what that occupies on disk, free space and
//!   whether it fits: the whole selection must be at most 97 % of the volume's capacity (the
//!   3 % rule of `packs.rs`) and the bytes still to write must be within the free space.
//!   Needs no network and no cache directory (without one, everything counts as missing).
//!   Exit 4 when it does not fit.
//! * `lock`: resolve every Ollama model of the pack catalog (default
//!   `core/manifest/model-packs.yaml`, found from the current directory) against the
//!   registry and write `core/manifest/model-packs.lock.json` (or `--out`): manifest bytes
//!   and digest, layer digests and sizes, the llama.cpp/GGUF child of a manifest list.
//!   Digests are never typed by hand. A re-run that finds nothing new leaves the file
//!   byte-identical. It prints where the catalog's `size_bytes` differs from the registry.
//!   `--check` writes nothing: exit 3 when the registry drifted (one `HEAD` per model,
//!   comparing `ollama-content-digest`) or the catalog and the lock disagree.
//! * `fetch`: download the blobs the lock names into `<cache>/models/blobs/sha256-<hex>`,
//!   resumably, verify SHA-256, then write the manifests verbatim (and an empty
//!   `manifests-v2/`). Only references that are in the lock can be fetched.
//! * `cache-info`: size, blobs, partials, free space, and which pack models are complete.
//!
//! The cache directory defaults to `$CI_STICK_CACHE`; the registry to `$CI_OS_REGISTRY_URL`,
//! else `https://registry.ollama.ai`; `HTTPS_PROXY`/`ALL_PROXY` and `NO_PROXY` are honoured.
//!
//! # Exit codes
//!
//! | code | meaning |
//! |---|---|
//! | 0 | ok |
//! | 1 | error (not resumable: a 404 for a blob, a read-only cache, a disk error) |
//! | 2 | usage error, unreadable or malformed input |
//! | 3 | `lock --check`: drift |
//! | 4 | not enough space (preflight or while writing) |
//! | 5 | a licence was not accepted (the other models were still fetched) |
//! | 6 | interrupted, or the network stayed down after the retry budget, or `--offline` with work left: partials are kept and a rerun resumes |
//! | 7 | integrity failure: a hash or size did not match |
//!
//! # `--events` and `status.json`
//!
//! `fetch --events FILE` appends JSON lines (`-` writes them to stdout and then nothing
//! else goes to stdout); `<cache>/ci-models/status.json` is rewritten atomically about once
//! a second. Both are specified in [`crate::events`].
//!
//! # Tuning knobs (diagnostics and tests)
//!
//! `CI_STICK_RETRY_BASE_MS` (first back-off delay, default 1000), `CI_STICK_STALL_TIMEOUT_S`
//! (default 30), `CI_STICK_CHUNK_BYTES` (initial and maximum request size) and
//! `CI_STICK_JOURNAL_BYTES` (bytes between two `fsync`s of a partial and its journal, default
//! 64 MiB: a killed process loses at most that much progress) change how patiently and in what
//! pieces `fetch` talks to the registry. They never weaken any check.

use std::collections::BTreeMap;
use std::io::{IsTerminal, Write as _};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, bail, Context as _};
use clap::{ArgGroup, Args};
use serde::Serialize;

use crate::cache::layout::CacheLayout;
use crate::cache::sink::FileSinkFactory;
use crate::cache::store::write_atomic;
use crate::cache::{self, fs_stats};
use crate::events::{EventSink, Reporter};
use crate::fetch::plan::{build_plan, Selection};
use crate::fetch::{self, exit, FetchOptions};
use crate::lockfile::{self, LockError, ModelLock, LOCK_REL_PATH};
use crate::net::{Fetcher, RetryPolicy, Url};
use crate::packs::{self, PackCatalog};
use crate::registry::ollama::ModelRef;
use crate::registry::resolve::{current_tag, resolve_model, ResolveError};
use crate::registry::{registry_url, RegistryClient, DEFAULT_REGISTRY_URL};
use crate::size::{fmt_binary, fmt_decimal, parse_size};
use crate::timefmt;

/// Environment variable naming the default cache directory.
pub const CACHE_ENV: &str = "CI_STICK_CACHE";

// ---------------------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------------------

#[derive(Args)]
pub struct PlanArgs {
    /// Pack to plan (a name from the lock's `packs`).
    #[arg(long)]
    pub pack: String,
    /// Cache directory (default: $CI_STICK_CACHE). Without one, nothing counts as present.
    #[arg(long)]
    pub cache: Option<PathBuf>,
    /// Lock file (default: core/manifest/model-packs.lock.json found from the current directory).
    #[arg(long)]
    pub lock: Option<PathBuf>,
    /// Plan as if the licences were accepted (models with an "unverified" licence are
    /// otherwise left out).
    #[arg(long)]
    pub accept_licenses: bool,
    /// Machine-readable output.
    #[arg(long)]
    pub json: bool,
}

#[derive(Args)]
pub struct LockArgs {
    /// Pack catalog (default: core/manifest/model-packs.yaml found from the current directory).
    #[arg(long)]
    pub packs: Option<PathBuf>,
    /// Lock file to write (default: model-packs.lock.json next to the catalog).
    #[arg(long)]
    pub out: Option<PathBuf>,
    /// Write nothing; exit 3 if the registry or the catalog drifted from the lock.
    #[arg(long)]
    pub check: bool,
    /// Registry base URL (default: $CI_OS_REGISTRY_URL, else https://registry.ollama.ai).
    #[arg(long)]
    pub registry_url: Option<String>,
    /// Machine-readable output.
    #[arg(long)]
    pub json: bool,
}

#[derive(Args)]
#[command(group(ArgGroup::new("what").required(true).args(["pack", "model"])))]
pub struct FetchArgs {
    /// Fetch every model of this pack.
    #[arg(long)]
    pub pack: Option<String>,
    /// Fetch one model from the lock, e.g. nomic-embed-text or gemma3:1b.
    #[arg(long)]
    pub model: Option<String>,
    /// Cache directory (default: $CI_STICK_CACHE).
    #[arg(long)]
    pub cache: Option<PathBuf>,
    /// Lock file (default: core/manifest/model-packs.lock.json found from the current directory).
    #[arg(long)]
    pub lock: Option<PathBuf>,
    /// Never open a network connection; succeed only if everything is already cached.
    #[arg(long)]
    pub offline: bool,
    /// Accept the licences that need a decision ("unverified"); you have read them.
    #[arg(long)]
    pub accept_licenses: bool,
    /// Limit the whole job to this many bytes per second (plain number or e.g. 5MiB).
    #[arg(long)]
    pub max_bytes_per_sec: Option<String>,
    /// Blobs to download at the same time (default 1: one stream is kind to a USB stick).
    #[arg(long, default_value_t = 1)]
    pub concurrency: usize,
    /// Registry base URL (default: $CI_OS_REGISTRY_URL, else https://registry.ollama.ai).
    #[arg(long)]
    pub registry_url: Option<String>,
    /// Write JSON-lines progress events to this file, or to stdout with "-".
    #[arg(long)]
    pub events: Option<String>,
    /// Machine-readable result on stdout.
    #[arg(long)]
    pub json: bool,
}

#[derive(Args)]
pub struct CacheInfoArgs {
    /// Cache directory (default: $CI_STICK_CACHE).
    #[arg(long)]
    pub cache: Option<PathBuf>,
    /// Lock file, to tell which pack models are complete (default: found from the current directory).
    #[arg(long)]
    pub lock: Option<PathBuf>,
    /// Machine-readable output.
    #[arg(long)]
    pub json: bool,
}

// ---------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------

fn print_json<T: Serialize>(value: &T) -> anyhow::Result<()> {
    let mut out = std::io::stdout().lock();
    match serde_json::to_writer_pretty(&mut out, value)
        .map_err(std::io::Error::from)
        .and_then(|()| writeln!(out))
    {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => Ok(()),
        Err(e) => Err(e).context("writing JSON"),
    }
}

fn resolve_cache(arg: Option<PathBuf>) -> anyhow::Result<PathBuf> {
    arg.or_else(|| {
        std::env::var_os(CACHE_ENV)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
    })
    .ok_or_else(|| anyhow!("no cache directory: pass --cache <dir> or set ${CACHE_ENV}"))
}

fn resolve_lock_path(arg: Option<PathBuf>) -> anyhow::Result<PathBuf> {
    if let Some(p) = arg {
        return Ok(p);
    }
    let cwd = std::env::current_dir().context("reading the current directory")?;
    lockfile::find_lock(&cwd).ok_or_else(|| {
        anyhow!(
            "no {LOCK_REL_PATH} found above {}; pass --lock <file>",
            cwd.display()
        )
    })
}

/// A user-facing failure with the exit code it maps to.
struct Failure {
    code: u8,
    message: String,
}

fn load_lock(path: &Path) -> Result<ModelLock, Failure> {
    let bytes = std::fs::read(path).map_err(|e| Failure {
        code: exit::USAGE,
        message: format!("reading {}: {e}", path.display()),
    })?;
    ModelLock::parse(&bytes).map_err(|e| Failure {
        code: match e {
            LockError::Integrity(_) => exit::INTEGRITY,
            LockError::Format(_) => exit::USAGE,
        },
        message: format!("{}: {e}", path.display()),
    })
}

fn fail(f: Failure) -> anyhow::Result<ExitCode> {
    eprintln!("error: {}", f.message);
    Ok(ExitCode::from(f.code))
}

fn env_u64(name: &str) -> Option<u64> {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok())
}

fn new_client(registry: &Url, cancel: Arc<AtomicBool>) -> RegistryClient {
    let mut retry = RetryPolicy::default();
    if let Some(ms) = env_u64("CI_STICK_RETRY_BASE_MS") {
        retry.base = Duration::from_millis(ms);
        retry.max_delay = retry.max_delay.max(retry.base);
    }
    RegistryClient::new(Fetcher::for_registry(registry), registry.clone())
        .with_retry(retry)
        .with_cancel(cancel)
}

fn origin_string(url: &Url) -> String {
    url.redacted().trim_end_matches('/').to_string()
}

// ---------------------------------------------------------------------------------------
// plan
// ---------------------------------------------------------------------------------------

pub fn cmd_plan(a: PlanArgs) -> anyhow::Result<ExitCode> {
    let lock_path = resolve_lock_path(a.lock)?;
    let lock = match load_lock(&lock_path) {
        Ok(l) => l,
        Err(f) => return fail(f),
    };
    let cache = a.cache.or_else(|| {
        std::env::var_os(CACHE_ENV)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
    });
    let plan = match build_plan(
        &lock,
        &Selection::Pack(a.pack),
        cache.as_deref(),
        a.accept_licenses,
    ) {
        Ok(p) => p,
        Err(e) => bail!("{e}"),
    };
    let report = plan.report();
    if a.json {
        print_json(&report)?;
    } else {
        print!("{}", render_plan(&report, cache.as_deref()));
    }
    Ok(if report.totals.fits == Some(false) {
        ExitCode::from(exit::NO_SPACE)
    } else {
        ExitCode::SUCCESS
    })
}

fn render_plan(r: &fetch::plan::PlanReport, cache: Option<&Path>) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "Pack {} — {} models{}\n\n",
        r.pack.as_deref().unwrap_or("(single model)"),
        r.models.len(),
        cache.map_or(String::new(), |c| format!(", cache {}", c.display()))
    ));
    out.push_str(&format!(
        "{:<34} {:>10} {:>10}  {}\n",
        "MODEL", "SIZE", "PRESENT", "STATE"
    ));
    for m in &r.models {
        let state = if m.gated {
            format!("needs --accept-licenses (licence: {})", m.license)
        } else if m.complete {
            "complete".to_string()
        } else {
            "to fetch".to_string()
        };
        out.push_str(&format!(
            "{:<34} {:>10} {:>10}  {}\n",
            m.model,
            fmt_decimal(m.size_bytes),
            fmt_decimal(m.bytes_present),
            state
        ));
    }
    let t = &r.totals;
    out.push_str(&format!(
        "\nBlobs (shared ones counted once): {} total, {} present, {} in partials, {} still to download\n",
        fmt_decimal(t.total_bytes),
        fmt_decimal(t.present_bytes),
        fmt_decimal(t.partial_bytes),
        fmt_decimal(t.missing_bytes)
    ));
    out.push_str(&format!(
        "On disk after cluster rounding: {}\n",
        fmt_binary(t.need_on_disk_bytes)
    ));
    match (t.free_bytes, t.capacity_bytes) {
        (Some(f), Some(c)) => out.push_str(&format!(
            "Volume: {} free of {} ({})\n",
            fmt_binary(f),
            fmt_binary(c),
            r.fs_type.as_deref().unwrap_or("file system unknown")
        )),
        _ => out.push_str("Volume: free space unknown\n"),
    }
    if t.gated_models > 0 {
        out.push_str(&format!(
            "{} models ({}) are left out until their licence is accepted.\n",
            t.gated_models,
            fmt_decimal(t.gated_bytes)
        ));
    }
    let word = |v: Option<bool>| match v {
        Some(true) => "yes",
        Some(false) => "NO",
        None => "unknown",
    };
    out.push_str(&format!(
        "Fits: {} (capacity rule, whole selection <= 97 % of the volume: {}; free space, bytes to write <= free: {})\n",
        word(t.fits),
        word(t.fits_capacity),
        word(t.fits_free)
    ));
    out
}

// ---------------------------------------------------------------------------------------
// lock
// ---------------------------------------------------------------------------------------

struct Wanted {
    reference: String,
    license: String,
    catalog_size: u64,
}

/// What the catalog asks for: the distinct references, the pack membership, and warnings.
struct Wanted3 {
    wanted: Vec<Wanted>,
    packs: BTreeMap<String, Vec<String>>,
    warnings: Vec<String>,
}

fn collect_wanted(packs: &[crate::manifest::ModelPack]) -> anyhow::Result<Wanted3> {
    let mut wanted: Vec<Wanted> = Vec::new();
    let mut map: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut warnings = Vec::new();
    let mut skipped_hf: Vec<String> = Vec::new();
    for pack in packs {
        for m in &pack.models {
            let canonical = match ModelRef::parse(&m.reference()) {
                Ok(r) => r.reference(),
                Err(crate::registry::ollama::RefError::HuggingFace(r)) => {
                    // Hugging Face models are a later phase: leave them out, loudly.
                    if !skipped_hf.contains(&r) {
                        skipped_hf.push(r);
                    }
                    continue;
                }
                Err(e) => return Err(anyhow!("pack {:?}: {e}", pack.name)),
            };
            map.entry(pack.name.clone())
                .or_default()
                .push(canonical.clone());
            match wanted.iter().find(|w| w.reference == canonical) {
                Some(w) => {
                    if w.license != m.license {
                        bail!(
                            "{canonical} has licence {:?} in one pack and {:?} in another; make the catalog consistent",
                            w.license,
                            m.license
                        );
                    }
                    if w.catalog_size != m.size_bytes {
                        warnings.push(format!(
                            "{canonical} is listed with different size_bytes in different packs ({} and {})",
                            w.catalog_size, m.size_bytes
                        ));
                    }
                }
                None => wanted.push(Wanted {
                    reference: canonical,
                    license: m.license.clone(),
                    catalog_size: m.size_bytes,
                }),
            }
        }
    }
    if !skipped_hf.is_empty() {
        warnings.push(format!(
            "{} Hugging Face models are not locked or fetched by this release (Ollama registry models only): {}",
            skipped_hf.len(),
            skipped_hf.join(", ")
        ));
    }
    Ok(Wanted3 {
        wanted,
        packs: map,
        warnings,
    })
}

#[derive(Serialize)]
struct SizeDrift {
    model: String,
    catalog_bytes: u64,
    registry_bytes: u64,
    delta: i128,
}

#[derive(Serialize)]
struct LockJson<'a> {
    lock_file: String,
    changed: bool,
    registry: &'a str,
    models: usize,
    packs: usize,
    inline_blobs: usize,
    size_drift: &'a [SizeDrift],
    warnings: &'a [String],
}

#[derive(Serialize, Clone)]
struct Drift {
    model: String,
    kind: &'static str,
    detail: String,
}

#[derive(Serialize)]
struct CheckJson<'a> {
    ok: bool,
    lock_file: String,
    models_checked: usize,
    drift: &'a [Drift],
}

fn generated_at() -> anyhow::Result<String> {
    match std::env::var("SOURCE_DATE_EPOCH") {
        Ok(v) => {
            let secs: u64 = v
                .trim()
                .parse()
                .with_context(|| format!("SOURCE_DATE_EPOCH={v:?} is not a Unix timestamp"))?;
            Ok(timefmt::format_unix(secs))
        }
        Err(_) => Ok(timefmt::now_rfc3339()),
    }
}

fn same_content(a: &ModelLock, b: &ModelLock) -> bool {
    a.registry == b.registry
        && a.packs == b.packs
        && a.models == b.models
        && a.blobs_inline == b.blobs_inline
}

pub fn cmd_lock(a: LockArgs) -> anyhow::Result<ExitCode> {
    let catalog_path = match &a.packs {
        Some(p) => p.clone(),
        None => {
            let cwd = std::env::current_dir().context("reading the current directory")?;
            packs::find_catalog(&cwd).with_context(|| {
                format!(
                    "no {} found above {}; pass --packs <file>",
                    packs::CATALOG_REL_PATH,
                    cwd.display()
                )
            })?
        }
    };
    let catalog = PackCatalog::load(&catalog_path)?;
    let out_path = a.out.clone().unwrap_or_else(|| {
        catalog_path
            .parent()
            .unwrap_or(Path::new("."))
            .join("model-packs.lock.json")
    });
    let Wanted3 {
        wanted,
        packs: pack_map,
        mut warnings,
    } = collect_wanted(&catalog.packs)?;
    let registry = registry_url(a.registry_url.as_deref()).map_err(|e| anyhow!("{e}"))?;
    let cancel = Arc::new(AtomicBool::new(false));
    let client = new_client(&registry, cancel);
    if origin_string(&registry) != DEFAULT_REGISTRY_URL {
        warnings.push(format!(
            "locking from {} instead of {DEFAULT_REGISTRY_URL}: metadata from a mirror is unauthenticated, review the result before committing",
            origin_string(&registry)
        ));
    }

    if a.check {
        return lock_check(&a, &out_path, &wanted, &pack_map, &client, &warnings);
    }

    // Four lookups at a time: each model is about ten small requests and the registry is far away.
    let results = resolve_all(&client, &wanted, !a.json);
    let mut models = Vec::new();
    let mut inline = BTreeMap::new();
    for (w, result) in wanted.iter().zip(results) {
        match result {
            Some(Ok(r)) => {
                inline.extend(r.inline);
                warnings.extend(r.warnings);
                models.push(r.model);
            }
            Some(Err(e)) => {
                eprintln!("error: {e}");
                return Ok(ExitCode::from(match e {
                    ResolveError::Integrity { .. } => exit::INTEGRITY,
                    _ => exit::ERROR,
                }));
            }
            None => {
                eprintln!(
                    "error: {}: not resolved because an earlier lookup failed",
                    w.reference
                );
                return Ok(ExitCode::from(exit::ERROR));
            }
        }
    }
    models.sort_by(|x, y| x.reference.cmp(&y.reference));
    let mut lock = ModelLock::new(&origin_string(&registry), &generated_at()?);
    lock.packs = pack_map;
    lock.models = models;
    lock.blobs_inline = inline
        .into_iter()
        .map(|(d, b)| (d, lockfile::b64_encode(&b)))
        .collect();
    lock.validate()
        .map_err(|e| anyhow!("internal error, the produced lock is inconsistent: {e}"))?;

    if let Ok(old) = std::fs::read(&out_path)
        .map_err(|_| ())
        .and_then(|b| ModelLock::parse(&b).map_err(|_| ()))
    {
        if same_content(&old, &lock) {
            lock.generated_at = old.generated_at;
            lock.tool = old.tool;
        }
    }
    let new_bytes = lock.to_canonical_json();
    let changed = std::fs::read(&out_path).map_or(true, |old| old != new_bytes);
    if changed {
        write_atomic(&out_path, &new_bytes)
            .with_context(|| format!("writing {}", out_path.display()))?;
    }

    let drift: Vec<SizeDrift> = wanted
        .iter()
        .filter_map(|w| {
            let m = lock.model(&w.reference)?;
            (m.size_bytes != w.catalog_size).then(|| SizeDrift {
                model: w.reference.clone(),
                catalog_bytes: w.catalog_size,
                registry_bytes: m.size_bytes,
                delta: i128::from(m.size_bytes) - i128::from(w.catalog_size),
            })
        })
        .collect();
    if a.json {
        print_json(&LockJson {
            lock_file: out_path.display().to_string(),
            changed,
            registry: &lock.registry,
            models: lock.models.len(),
            packs: lock.packs.len(),
            inline_blobs: lock.blobs_inline.len(),
            size_drift: &drift,
            warnings: &warnings,
        })?;
    } else {
        println!(
            "{} {} ({} models, {} packs, {} inline blobs)",
            if changed { "wrote" } else { "unchanged" },
            out_path.display(),
            lock.models.len(),
            lock.packs.len(),
            lock.blobs_inline.len()
        );
        for w in &warnings {
            eprintln!("warning: {w}");
        }
        if drift.is_empty() {
            println!("Catalog sizes match the registry.");
        } else {
            println!(
                "The catalog's size_bytes differ from the registry for {} models:",
                drift.len()
            );
            for d in &drift {
                println!(
                    "  {:<34} catalog {:>14}  registry {:>14}  ({:+})",
                    d.model, d.catalog_bytes, d.registry_bytes, d.delta
                );
            }
        }
    }
    Ok(ExitCode::SUCCESS)
}

/// Resolve every wanted model, `LOOKUPS` at a time, keeping the catalog's order. After the first
/// failure the remaining models are skipped (`None`).
fn resolve_all(
    client: &RegistryClient,
    wanted: &[Wanted],
    progress: bool,
) -> Vec<Option<Result<crate::registry::resolve::Resolved, ResolveError>>> {
    const LOOKUPS: usize = 4;
    let slots: Vec<std::sync::Mutex<Option<Result<_, _>>>> =
        wanted.iter().map(|_| std::sync::Mutex::new(None)).collect();
    let next = std::sync::atomic::AtomicUsize::new(0);
    let failed = AtomicBool::new(false);
    std::thread::scope(|s| {
        for _ in 0..LOOKUPS.min(wanted.len().max(1)) {
            s.spawn(|| loop {
                let i = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let Some(w) = wanted.get(i) else { return };
                if failed.load(std::sync::atomic::Ordering::Relaxed) {
                    return;
                }
                let r = resolve_model(client, &w.reference, &w.license);
                if progress {
                    match &r {
                        Ok(ok) => eprintln!(
                            "[{:>2}/{}] {:<30} {}{}",
                            i + 1,
                            wanted.len(),
                            w.reference,
                            fmt_decimal(ok.model.size_bytes),
                            if ok.model.list_digest.is_some() {
                                "  (manifest list -> llama.cpp/GGUF)"
                            } else {
                                ""
                            }
                        ),
                        Err(_) => {
                            eprintln!("[{:>2}/{}] {:<30} FAILED", i + 1, wanted.len(), w.reference)
                        }
                    }
                }
                if r.is_err() {
                    failed.store(true, std::sync::atomic::Ordering::Relaxed);
                }
                *slots[i].lock().unwrap_or_else(|e| e.into_inner()) = Some(r);
            });
        }
    });
    slots
        .into_iter()
        .map(|m| m.into_inner().unwrap_or_else(|e| e.into_inner()))
        .collect()
}

fn lock_check(
    a: &LockArgs,
    out_path: &Path,
    wanted: &[Wanted],
    pack_map: &BTreeMap<String, Vec<String>>,
    client: &RegistryClient,
    warnings: &[String],
) -> anyhow::Result<ExitCode> {
    let lock = match load_lock(out_path) {
        Ok(l) => l,
        Err(f) => return fail(f),
    };
    let mut drift: Vec<Drift> = Vec::new();
    // 1. catalog vs lock (offline)
    for w in wanted {
        match lock.model(&w.reference) {
            None => drift.push(Drift {
                model: w.reference.clone(),
                kind: "missing_in_lock",
                detail: "the catalog lists it but the lock has no entry".into(),
            }),
            Some(m) => {
                if m.size_bytes != w.catalog_size {
                    drift.push(Drift {
                        model: w.reference.clone(),
                        kind: "size_mismatch",
                        detail: format!(
                            "catalog size_bytes {} but the lock records {}",
                            w.catalog_size, m.size_bytes
                        ),
                    });
                }
                if m.license != w.license {
                    drift.push(Drift {
                        model: w.reference.clone(),
                        kind: "license_mismatch",
                        detail: format!(
                            "catalog licence {:?} but the lock records {:?}",
                            w.license, m.license
                        ),
                    });
                }
            }
        }
    }
    for m in &lock.models {
        if !wanted.iter().any(|w| w.reference == m.reference) {
            drift.push(Drift {
                model: m.reference.clone(),
                kind: "stale_in_lock",
                detail: "the lock has an entry no pack lists any more".into(),
            });
        }
    }
    if &lock.packs != pack_map {
        drift.push(Drift {
            model: String::new(),
            kind: "packs_mismatch",
            detail: "the pack membership in the lock differs from the catalog".into(),
        });
    }
    // 2. registry vs lock (one HEAD per model)
    for m in &lock.models {
        if !a.json {
            eprint!("checking {} ... ", m.reference);
        }
        match current_tag(client, &m.reference) {
            Ok(h) => {
                let observed = h.digest.unwrap_or_default();
                if observed != m.tag_digest() {
                    let pushed = h
                        .push_time
                        .map(timefmt::format_unix)
                        .unwrap_or_else(|| "unknown".into());
                    drift.push(Drift {
                        model: m.reference.clone(),
                        kind: "registry_changed",
                        detail: format!(
                            "the tag now has digest {observed} (pushed {pushed}); the lock pins {}",
                            m.tag_digest()
                        ),
                    });
                    if !a.json {
                        eprintln!("DRIFT");
                    }
                } else if !a.json {
                    eprintln!("ok");
                }
            }
            Err(e) => {
                if !a.json {
                    eprintln!("FAILED");
                }
                eprintln!("error: cannot check {}: {e}", m.reference);
                return Ok(ExitCode::from(exit::ERROR));
            }
        }
    }
    if a.json {
        print_json(&CheckJson {
            ok: drift.is_empty(),
            lock_file: out_path.display().to_string(),
            models_checked: lock.models.len(),
            drift: &drift,
        })?;
    } else {
        for w in warnings {
            eprintln!("warning: {w}");
        }
        if drift.is_empty() {
            println!(
                "No drift: {} models match the registry and the catalog.",
                lock.models.len()
            );
        } else {
            println!("DRIFT in {} places:", drift.len());
            for d in &drift {
                println!("  {} [{}] {}", d.model, d.kind, d.detail);
            }
            println!("Run `ci-stick models lock` and review the diff.");
        }
    }
    Ok(if drift.is_empty() {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(exit::DRIFT)
    })
}

// ---------------------------------------------------------------------------------------
// fetch
// ---------------------------------------------------------------------------------------

/// Turn SIGINT/SIGTERM/SIGHUP into "stop after flushing the journal" (a second SIGINT or
/// SIGTERM ends the process at once with status 130/143). No-op on Windows, where the
/// process just ends and the partial still resumes because the journal is only ever behind.
#[cfg(unix)]
pub fn install_signal_handlers(cancel: &Arc<AtomicBool>) {
    use signal_hook::consts::signal::{SIGHUP, SIGINT, SIGTERM};
    for (sig, code) in [(SIGINT, 130), (SIGTERM, 143), (SIGHUP, 129)] {
        // Registered first, so the second delivery (flag already set) terminates the process.
        let _ = signal_hook::flag::register_conditional_shutdown(sig, code, Arc::clone(cancel));
        let _ = signal_hook::flag::register(sig, Arc::clone(cancel));
    }
}

#[cfg(not(unix))]
pub fn install_signal_handlers(_cancel: &Arc<AtomicBool>) {}

#[derive(Serialize)]
struct FetchJson {
    status: &'static str,
    exit: u8,
    models_ok: usize,
    models_failed: usize,
    models_gated: usize,
    bytes_downloaded: u64,
    blobs_downloaded: usize,
    blobs_skipped: usize,
    errors: Vec<String>,
}

pub fn cmd_fetch(a: FetchArgs) -> anyhow::Result<ExitCode> {
    if a.concurrency == 0 || a.concurrency > 16 {
        bail!("--concurrency must be between 1 and 16");
    }
    let max_rate = match a.max_bytes_per_sec.as_deref() {
        Some(s) => {
            let n = parse_size(s).context("--max-bytes-per-sec")?;
            if n == 0 {
                bail!("--max-bytes-per-sec must be greater than 0 (omit it for no limit)");
            }
            Some(n)
        }
        None => None,
    };
    let cache = resolve_cache(a.cache.clone())?;
    let lock_path = resolve_lock_path(a.lock.clone())?;
    let lock = match load_lock(&lock_path) {
        Ok(l) => l,
        Err(f) => return fail(f),
    };
    let selection = match (&a.pack, &a.model) {
        (Some(p), None) => Selection::Pack(p.clone()),
        (None, Some(m)) => Selection::Model(m.clone()),
        _ => bail!("give exactly one of --pack or --model"),
    };
    let registry = registry_url(a.registry_url.as_deref()).map_err(|e| anyhow!("{e}"))?;
    let cancel = Arc::new(AtomicBool::new(false));
    install_signal_handlers(&cancel);
    let client = new_client(&registry, cancel);

    let events = match a.events.as_deref() {
        Some(arg) => {
            EventSink::from_arg(arg).with_context(|| format!("opening the event stream {arg:?}"))?
        }
        None => EventSink::none(),
    };
    let owns_stdout = events.owns_stdout();
    let layout = CacheLayout::new(&cache);
    let mut reporter = Reporter::new(events, Some(layout.status_file()), a.pack.clone());
    if !owns_stdout && !a.json && std::io::stderr().is_terminal() {
        reporter = reporter.with_tty_progress();
    }

    let mut opts = FetchOptions::new(&cache);
    opts.offline = a.offline;
    opts.accept_licenses = a.accept_licenses;
    opts.max_bytes_per_sec = max_rate;
    opts.concurrency = a.concurrency;
    if let Some(ms) = env_u64("CI_STICK_STALL_TIMEOUT_S") {
        opts.transfer.stall_timeout = Duration::from_secs(ms);
    }
    if let Some(b) = env_u64("CI_STICK_CHUNK_BYTES").filter(|b| *b > 0) {
        opts.transfer.chunk.initial = b;
        opts.transfer.chunk.max = b;
    }
    if let Some(b) = env_u64("CI_STICK_JOURNAL_BYTES").filter(|b| *b > 0) {
        opts.transfer.journal_every = b;
    }

    let outcome = match fetch::run(
        &lock,
        &selection,
        &opts,
        &client,
        &FileSinkFactory,
        &reporter,
    ) {
        Ok(o) => o,
        Err(e) => bail!("{e}"),
    };
    let summary = FetchJson {
        status: outcome.status,
        exit: outcome.exit,
        models_ok: outcome.models_ok,
        models_failed: outcome.models_failed,
        models_gated: outcome.models_gated,
        bytes_downloaded: outcome.bytes_downloaded,
        blobs_downloaded: outcome.blobs_downloaded,
        blobs_skipped: outcome.blobs_skipped,
        errors: outcome.errors.clone(),
    };
    if owns_stdout {
        // stdout belongs to the event stream; its last line is the `done` event
    } else if a.json {
        print_json(&summary)?;
    } else {
        println!(
            "{}: {} models complete, {} failed, {} left out for their licence; {} downloaded in {} blobs ({} already there)",
            outcome.status,
            outcome.models_ok,
            outcome.models_failed,
            outcome.models_gated,
            fmt_decimal(outcome.bytes_downloaded),
            outcome.blobs_downloaded,
            outcome.blobs_skipped
        );
    }
    if !a.json && !outcome.errors.is_empty() {
        for e in &outcome.errors {
            eprintln!("error: {e}");
        }
        if outcome.exit == exit::INTERRUPTED {
            eprintln!("Partial downloads are kept; run the same command again to resume.");
        }
    }
    Ok(ExitCode::from(outcome.exit))
}

// ---------------------------------------------------------------------------------------
// cache-info
// ---------------------------------------------------------------------------------------

#[derive(Serialize)]
struct PackStatus {
    name: String,
    models: usize,
    complete_models: usize,
    complete: bool,
    bytes_total: u64,
    bytes_present: u64,
    incomplete: Vec<String>,
}

#[derive(Serialize)]
struct CacheInfo {
    cache: String,
    exists: bool,
    seeded: bool,
    total_bytes: Option<u64>,
    free_bytes: Option<u64>,
    fs_type: Option<String>,
    read_only: Option<bool>,
    ram_backed: Option<bool>,
    #[serde(flatten)]
    scan: cache::CacheScan,
    lock_file: Option<String>,
    packs: Option<Vec<PackStatus>>,
}

pub fn cmd_cache_info(a: CacheInfoArgs) -> anyhow::Result<ExitCode> {
    let cache = resolve_cache(a.cache)?;
    let layout = CacheLayout::new(&cache);
    let fs = fs_stats(&cache);
    let scan = cache::scan(&layout);
    let lock_path = match a.lock {
        Some(p) => Some(p),
        None => std::env::current_dir()
            .ok()
            .and_then(|c| lockfile::find_lock(&c)),
    };
    let mut lock_file = None;
    let mut packs = None;
    if let Some(p) = &lock_path {
        match load_lock(p) {
            Ok(lock) => {
                lock_file = Some(p.display().to_string());
                let mut rows = Vec::new();
                for (name, refs) in &lock.packs {
                    let plan =
                        build_plan(&lock, &Selection::Pack(name.clone()), Some(&cache), true)
                            .map_err(|e| anyhow!("{e}"))?;
                    let incomplete: Vec<String> = plan
                        .models
                        .iter()
                        .filter(|m| !m.complete)
                        .map(|m| m.reference.clone())
                        .collect();
                    let t = plan.totals();
                    rows.push(PackStatus {
                        name: name.clone(),
                        models: refs.len(),
                        complete_models: refs.len() - incomplete.len(),
                        complete: incomplete.is_empty(),
                        bytes_total: t.total_bytes,
                        bytes_present: t.present_bytes,
                        incomplete,
                    });
                }
                packs = Some(rows);
            }
            Err(f) if a.json => {
                eprintln!("warning: {}", f.message);
            }
            Err(f) => eprintln!("warning: {}", f.message),
        }
    }
    let info = CacheInfo {
        cache: cache.display().to_string(),
        exists: cache.is_dir(),
        seeded: layout.blobs_dir().is_dir() && layout.manifests_v2_dir().is_dir(),
        total_bytes: fs.total_bytes,
        free_bytes: fs.free_bytes,
        fs_type: fs.fs_type.clone(),
        read_only: fs.read_only,
        ram_backed: fs.ram_backed,
        scan,
        lock_file,
        packs,
    };
    if a.json {
        print_json(&info)?;
    } else {
        print!("{}", render_cache_info(&info));
    }
    Ok(ExitCode::SUCCESS)
}

fn render_cache_info(i: &CacheInfo) -> String {
    let mut out = format!(
        "Cache {}{}\n",
        i.cache,
        if i.exists {
            ""
        } else {
            " (does not exist yet)"
        }
    );
    match (i.free_bytes, i.total_bytes) {
        (Some(f), Some(t)) => out.push_str(&format!(
            "  volume: {} free of {}{}{}\n",
            fmt_binary(f),
            fmt_binary(t),
            i.fs_type
                .as_deref()
                .map_or(String::new(), |t| format!(", {t}")),
            if i.read_only == Some(true) {
                ", READ-ONLY"
            } else {
                ""
            }
        )),
        _ => out.push_str("  volume: free space unknown\n"),
    }
    if i.ram_backed == Some(true) {
        out.push_str(
            "  WARNING: this is RAM-backed storage (tmpfs); models written here use memory\n",
        );
    }
    out.push_str(&format!(
        "  blobs: {} ({}), manifests: {}, partial downloads: {} ({} committed)\n",
        i.scan.blobs,
        fmt_binary(i.scan.blob_bytes),
        i.scan.manifests,
        i.scan.partials,
        fmt_binary(i.scan.partial_committed_bytes)
    ));
    if i.scan.junk_files > 0 || i.scan.foreign_blob_files > 0 {
        out.push_str(&format!(
            "  ignored: {} Finder/Spotlight/AppleDouble files, {} unrecognised files in models/blobs\n",
            i.scan.junk_files, i.scan.foreign_blob_files
        ));
    }
    match &i.packs {
        Some(packs) => {
            for p in packs {
                out.push_str(&format!(
                    "  pack {:<14} {}/{} models complete ({} of {}){}\n",
                    p.name,
                    p.complete_models,
                    p.models,
                    fmt_decimal(p.bytes_present),
                    fmt_decimal(p.bytes_total),
                    if p.complete { "  COMPLETE" } else { "" }
                ));
            }
        }
        None => {
            out.push_str("  packs: no lock file found (pass --lock) so completeness is unknown\n")
        }
    }
    out
}
