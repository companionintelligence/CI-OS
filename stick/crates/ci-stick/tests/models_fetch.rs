//! The fetch engine against a mock registry and CDN: resumable ranged downloads, redirects,
//! fault injection, integrity, licence gating, disk-full, cancellation. Library API; the CLI
//! has its own end-to-end tests in `models_cli.rs`.

mod models_support;

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use ci_stick::cache::layout::CacheLayout;
use ci_stick::cache::partial::{read_journal, write_journal, Journal};
use ci_stick::cache::sink::{FileSinkFactory, SinkFactory};
use ci_stick::events::{EventSink, Reporter};
use ci_stick::fetch::plan::{build_plan, Selection};
use ci_stick::fetch::{self, exit, ChunkPolicy, FetchOptions, FetchOutcome, TransferOptions};
use ci_stick::lockfile::ModelLock;
use ci_stick::net::{Fetcher, RetryPolicy, Url};
use ci_stick::registry::RegistryClient;
use models_support::*;
use serde_json::Value;

const KIB: usize = 1024;

struct Env {
    reg: MockRegistry,
    dir: tempfile::TempDir,
    lock: ModelLock,
    synths: Vec<Synth>,
}

struct Run {
    outcome: FetchOutcome,
    events: Vec<Value>,
    event_text: String,
    status: Option<Value>,
}

fn small_transfer() -> TransferOptions {
    TransferOptions {
        retry: RetryPolicy::immediate(4),
        chunk: ChunkPolicy {
            initial: 64 * KIB as u64,
            max: 64 * KIB as u64,
            target: Duration::from_secs(1),
        },
        stall_timeout: Duration::from_secs(5),
        journal_every: 128 * KIB as u64,
        buffer: 16 * KIB,
    }
}

impl Env {
    fn new(synths: Vec<Synth>) -> Env {
        let reg = MockRegistry::start();
        for s in &synths {
            reg.add_model(s);
        }
        let refs: Vec<&Synth> = synths.iter().collect();
        let names: Vec<&str> = synths.iter().map(|s| s.reference.as_str()).collect();
        let lock = lock_for(&refs, &[("p", &names)]);
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("cache")).unwrap();
        Env {
            reg,
            dir,
            lock,
            synths,
        }
    }

    fn cache(&self) -> PathBuf {
        self.dir.path().join("cache")
    }

    fn layout(&self) -> CacheLayout {
        CacheLayout::new(self.cache())
    }

    fn client(&self, cancel: Arc<AtomicBool>) -> RegistryClient {
        let url = Url::parse(&self.reg.url()).unwrap();
        RegistryClient::new(Fetcher::for_registry(&url), url)
            .with_retry(RetryPolicy::immediate(4))
            .with_cancel(cancel)
    }

    fn opts(&self) -> FetchOptions {
        let mut o = FetchOptions::new(self.cache());
        o.transfer = small_transfer();
        o
    }

    fn fetch(&self, sel: &Selection) -> Run {
        self.fetch_with(
            sel,
            &self.opts(),
            &FileSinkFactory,
            Arc::new(AtomicBool::new(false)),
        )
    }

    fn fetch_with(
        &self,
        sel: &Selection,
        opts: &FetchOptions,
        sinks: &dyn SinkFactory,
        cancel: Arc<AtomicBool>,
    ) -> Run {
        let cap = Capture::default();
        let reporter = Reporter::new(
            EventSink::writer(Box::new(cap.clone())),
            Some(self.layout().status_file()),
            Some("p".into()),
        )
        .with_intervals(Duration::from_millis(1), Duration::from_millis(1));
        let outcome = fetch::run(
            &self.lock,
            sel,
            opts,
            &self.client(cancel),
            sinks,
            &reporter,
        )
        .expect("plan is valid");
        let status = fs::read(self.layout().status_file())
            .ok()
            .map(|b| serde_json::from_slice(&b).expect("status.json is JSON"));
        Run {
            outcome,
            events: cap.lines(),
            event_text: cap.text(),
            status,
        }
    }

    fn pack(&self) -> Selection {
        Selection::Pack("p".into())
    }

    fn blob_ok(&self, s: &Synth) {
        for (_, _, bytes) in &s.layers {
            let path = self.layout().blob_path(&hex_of(bytes)).unwrap();
            assert_eq!(
                fs::read(&path).unwrap_or_default(),
                *bytes,
                "blob {}",
                path.display()
            );
        }
        let m = self
            .layout()
            .manifest_path(&["registry.ollama.ai", "library", &s.name, &s.tag])
            .unwrap();
        assert_eq!(
            fs::read(&m).unwrap(),
            s.manifest,
            "manifest of {} is not verbatim",
            s.reference
        );
    }

    fn no_manifest(&self, s: &Synth) {
        let m = self
            .layout()
            .manifest_path(&["registry.ollama.ai", "library", &s.name, &s.tag])
            .unwrap();
        assert!(!m.exists(), "{} must not have a manifest yet", s.reference);
    }

    fn partial_files(&self) -> Vec<String> {
        let mut v: Vec<String> = fs::read_dir(self.layout().partial_dir())
            .map(|rd| {
                rd.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        v.sort();
        v
    }
}

fn kinds(events: &[Value]) -> Vec<&str> {
    events
        .iter()
        .map(|e| e["event"].as_str().unwrap())
        .collect()
}

// ---------------------------------------------------------------------------------------

#[test]
fn fetches_two_models_that_share_a_licence_blob() {
    let a = synth("alpha", "1b", 300 * KIB + 17, "Apache-2.0", 1);
    let b = synth("beta", "2b", 200 * KIB, "Apache-2.0", 2);
    let env = Env::new(vec![a.clone(), b.clone()]);
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    assert_eq!(run.outcome.status, "ok");
    assert_eq!(run.outcome.models_ok, 2);
    assert_eq!(
        run.outcome.blobs_downloaded, 2,
        "only the two model layers need the network"
    );
    assert_eq!(
        run.outcome.bytes_downloaded as usize,
        300 * KIB + 17 + 200 * KIB
    );
    env.blob_ok(&a);
    env.blob_ok(&b);
    // the licence text is one file for both models
    let blobs = fs::read_dir(env.layout().blobs_dir()).unwrap().count();
    // two model layers, two configs (their seeds differ), ONE shared licence, ONE shared params
    assert_eq!(
        blobs,
        2 + 2 + 1 + 1,
        "shared blobs are stored once, got {blobs}"
    );
    // an empty manifests-v2/, a VERSION file, nothing left in partial/
    let v2 = env.layout().manifests_v2_dir();
    assert!(v2.is_dir() && fs::read_dir(&v2).unwrap().count() == 0);
    assert!(env.layout().version_file().exists());
    assert!(env.partial_files().is_empty(), "{:?}", env.partial_files());

    // events: the stable keys everywhere, manifests only after the model's blobs
    for e in &run.events {
        for k in [
            "event", "model", "blob", "bytes", "total", "rate_bps", "eta_s", "ts",
        ] {
            assert!(e.get(k).is_some(), "{k} missing in {e}");
        }
    }
    let k = kinds(&run.events);
    assert_eq!(k.first(), Some(&"start"));
    assert_eq!(k.last(), Some(&"done"));
    let done_at = |m: &str| {
        run.events
            .iter()
            .position(|e| e["event"] == "model_done" && e["model"] == m)
            .unwrap()
    };
    let last_blob_at = |m: &str| {
        run.events
            .iter()
            .rposition(|e| e["event"] == "blob_done" && e["model"] == m)
            .unwrap()
    };
    assert!(last_blob_at("alpha:1b") < done_at("alpha:1b"));
    assert!(last_blob_at("beta:2b") < done_at("beta:2b"));
    let last = run.events.last().unwrap();
    assert_eq!(last["status"], "ok");
    assert_eq!(last["exit"], 0);
    assert_eq!(last["models_ok"], 2);

    // status.json
    let st = run.status.unwrap();
    assert_eq!(st["state"], "done");
    assert_eq!(st["pack"], "p");
    assert_eq!(st["models"].as_array().unwrap().len(), 2);
    assert!(st["models"]
        .as_array()
        .unwrap()
        .iter()
        .all(|m| m["state"] == "done"));

    // the presigned query string never leaves the process
    let all = format!(
        "{}{}",
        run.event_text,
        fs::read_to_string(env.layout().status_file()).unwrap()
    );
    assert!(
        !all.contains("SECRETSIG") && !all.contains("X-Amz"),
        "{all}"
    );
    // the registry redirected to the CDN, which was asked in ranges of 64 KiB
    let ranges = env.reg.cdn_ranges(&a.model_hex());
    assert!(ranges.len() >= 5, "{ranges:?}");
    assert_eq!(ranges[0], "bytes=0-65535");
}

#[test]
fn a_second_run_does_nothing() {
    let a = synth("alpha", "1b", 100 * KIB, "Apache-2.0", 1);
    let env = Env::new(vec![a.clone()]);
    assert_eq!(env.fetch(&env.pack()).outcome.exit, 0);
    env.reg.clear_hits();
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0);
    assert_eq!(run.outcome.bytes_downloaded, 0);
    assert!(
        env.reg.hits().is_empty(),
        "nothing complete needs the network: {:?}",
        env.reg.hits()
    );
    assert!(run
        .events
        .iter()
        .any(|e| e["event"] == "model_done" && e["skipped"] == true));
    env.blob_ok(&a);
    // a damaged manifest is rewritten even though every blob is there
    let m = env
        .layout()
        .manifest_path(&["registry.ollama.ai", "library", "alpha", "1b"])
        .unwrap();
    fs::write(&m, b"damaged").unwrap();
    assert_eq!(env.fetch(&env.pack()).outcome.exit, 0);
    env.blob_ok(&a);
}

#[test]
fn single_model_selection_accepts_a_bare_name_and_refuses_unknown_refs() {
    let a = synth("alpha", "latest", 50 * KIB, "Apache-2.0", 1);
    let env = Env::new(vec![a.clone()]);
    let run = env.fetch(&Selection::Model("alpha".into()));
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    env.blob_ok(&a);
    let err = fetch::run(
        &env.lock,
        &Selection::Model("not-in-the-lock".into()),
        &env.opts(),
        &env.client(Arc::new(AtomicBool::new(false))),
        &FileSinkFactory,
        &Reporter::new(EventSink::none(), None, None),
    )
    .unwrap_err();
    assert!(err.to_string().contains("not in the lock"), "{err}");
    let err = build_plan(&env.lock, &Selection::Pack("nope".into()), None, true).unwrap_err();
    assert!(err.to_string().contains("known packs: p"), "{err}");
}

// ---- resume ---------------------------------------------------------------------------

fn seed_partial(env: &Env, s: &Synth, data_len: usize, committed: u64) {
    let hex = s.model_hex();
    let layout = env.layout();
    fs::create_dir_all(layout.partial_dir()).unwrap();
    fs::write(
        layout.partial_path(&hex).unwrap(),
        &s.model_bytes()[..data_len],
    )
    .unwrap();
    let j = Journal::new(&hex, s.model_bytes().len() as u64, committed, "http://x/y");
    write_journal(&layout.journal_path(&hex).unwrap(), &j).unwrap();
}

#[test]
fn resumes_from_the_journal_with_a_range_request() {
    let a = synth("alpha", "1b", 400 * KIB, "Apache-2.0", 3);
    let env = Env::new(vec![a.clone()]);
    seed_partial(&env, &a, 150 * KIB, 150 * KIB as u64);
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    assert_eq!(
        run.outcome.bytes_downloaded as usize,
        250 * KIB,
        "only the missing part crossed the network"
    );
    let ranges = env.reg.cdn_ranges(&a.model_hex());
    assert_eq!(
        ranges[0],
        format!("bytes={}-{}", 150 * KIB, 150 * KIB + 65535),
        "{ranges:?}"
    );
    env.blob_ok(&a);
    assert!(env.partial_files().is_empty());
}

#[test]
fn journal_and_data_that_disagree_are_reconciled_safely() {
    let a = synth("alpha", "1b", 300 * KIB, "Apache-2.0", 4);
    let hex = a.model_hex();
    // (1) the data file is longer than the journal says: the unvouched bytes are cut off
    {
        let env = Env::new(vec![a.clone()]);
        seed_partial(&env, &a, 200 * KIB, 100 * KIB as u64);
        assert_eq!(env.fetch(&env.pack()).outcome.exit, 0);
        assert_eq!(
            env.reg.cdn_ranges(&hex)[0],
            format!("bytes={}-{}", 100 * KIB, 100 * KIB + 65535)
        );
        env.blob_ok(&a);
    }
    // (2) the journal vouches for more than the file holds (power cut): start over
    {
        let env = Env::new(vec![a.clone()]);
        seed_partial(&env, &a, 50 * KIB, 100 * KIB as u64);
        assert_eq!(env.fetch(&env.pack()).outcome.exit, 0);
        assert_eq!(env.reg.cdn_ranges(&hex)[0], "bytes=0-65535");
        env.blob_ok(&a);
    }
    // (3) a journal for another blob, or a size that does not match, is ignored
    {
        let env = Env::new(vec![a.clone()]);
        seed_partial(&env, &a, 100 * KIB, 100 * KIB as u64);
        let jp = env.layout().journal_path(&hex).unwrap();
        let mut j = read_journal(&jp).unwrap();
        j.size += 1;
        write_journal(&jp, &j).unwrap();
        assert_eq!(env.fetch(&env.pack()).outcome.exit, 0);
        assert_eq!(env.reg.cdn_ranges(&hex)[0], "bytes=0-65535");
        env.blob_ok(&a);
    }
    // (4) garbage journal
    {
        let env = Env::new(vec![a.clone()]);
        seed_partial(&env, &a, 100 * KIB, 100 * KIB as u64);
        fs::write(env.layout().journal_path(&hex).unwrap(), b"\0\0not json").unwrap();
        assert_eq!(env.fetch(&env.pack()).outcome.exit, 0);
        env.blob_ok(&a);
    }
}

#[test]
fn a_corrupt_resumed_prefix_is_caught_and_the_blob_is_downloaded_clean() {
    let a = synth("alpha", "1b", 300 * KIB, "Apache-2.0", 5);
    let env = Env::new(vec![a.clone()]);
    // the first 100 KiB on disk are wrong, but the journal vouches for them
    seed_partial(&env, &a, 100 * KIB, 100 * KIB as u64);
    let pp = env.layout().partial_path(&a.model_hex()).unwrap();
    let mut data = fs::read(&pp).unwrap();
    data[500] ^= 0xFF;
    fs::write(&pp, data).unwrap();
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    let ranges = env.reg.cdn_ranges(&a.model_hex());
    assert_eq!(
        ranges[0],
        format!("bytes={}-{}", 100 * KIB, 100 * KIB + 65535),
        "first the resume ..."
    );
    assert!(
        ranges.iter().filter(|r| *r == "bytes=0-65535").count() == 1,
        "... then one clean restart: {ranges:?}"
    );
    env.blob_ok(&a);
}

// ---- transport faults ----------------------------------------------------------------

#[test]
fn recovers_from_a_body_cut_short() {
    let a = synth("alpha", "1b", 200 * KIB, "Apache-2.0", 6);
    let hex = a.model_hex();
    let env = Env::new(vec![a.clone()]);
    env.reg.fault(Some(&hex), Fault::TruncateAfter(10_000));
    env.reg.fault(Some(&hex), Fault::TruncateAfter(1));
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    env.blob_ok(&a);
    let ranges = env.reg.cdn_ranges(&hex);
    assert_eq!(ranges[0], "bytes=0-65535");
    assert_eq!(
        ranges[1], "bytes=10000-75535",
        "resumed exactly where the cut happened: {ranges:?}"
    );
    assert_eq!(ranges[2], "bytes=10001-75536");
}

#[test]
fn survives_5xx_and_429_with_retry_after() {
    let a = synth("alpha", "1b", 100 * KIB, "Apache-2.0", 7);
    let hex = a.model_hex();
    let env = Env::new(vec![a.clone()]);
    env.reg.fault(
        Some(&hex),
        Fault::Status {
            code: 503,
            retry_after: None,
        },
    );
    env.reg.fault(
        Some(&hex),
        Fault::Status {
            code: 429,
            retry_after: Some(0),
        },
    );
    env.reg.fault(
        Some(&hex),
        Fault::Status {
            code: 500,
            retry_after: None,
        },
    );
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    env.blob_ok(&a);
}

#[test]
fn a_network_that_stays_down_ends_the_job_resumably() {
    let a = synth("alpha", "1b", 200 * KIB, "Apache-2.0", 8);
    let b = synth("beta", "1b", 100 * KIB, "Apache-2.0", 9);
    let env = Env::new(vec![a.clone(), b.clone()]);
    for _ in 0..40 {
        env.reg.fault(
            None,
            Fault::Status {
                code: 503,
                retry_after: None,
            },
        );
    }
    let run = env.fetch(&env.pack());
    assert_eq!(
        run.outcome.exit,
        exit::INTERRUPTED,
        "{:?}",
        run.outcome.errors
    );
    assert_eq!(run.outcome.status, "interrupted");
    assert_eq!(
        run.events
            .iter()
            .filter(|e| e["event"] == "error" && e["fatal"] == true)
            .count(),
        1,
        "the job stops at the first blob that gives up"
    );
    env.no_manifest(&a);
    env.no_manifest(&b);
    // the server recovers: the same command completes
    env.reg.state.cdn_faults.lock().unwrap().clear();
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    env.blob_ok(&a);
    env.blob_ok(&b);
}

#[test]
fn a_blob_the_registry_does_not_have_fails_only_its_models() {
    let a = synth("alpha", "1b", 100 * KIB, "Apache-2.0", 10);
    let b = synth("beta", "1b", 100 * KIB, "Apache-2.0", 11);
    let env = Env::new(vec![a.clone(), b.clone()]);
    env.reg.state.blobs.lock().unwrap().remove(&a.model_hex());
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, exit::ERROR, "{:?}", run.outcome.errors);
    assert_eq!(run.outcome.models_failed, 1);
    assert_eq!(run.outcome.models_ok, 1);
    env.blob_ok(&b);
    env.no_manifest(&a);
}

#[test]
fn an_expired_presigned_url_is_resolved_again() {
    let a = synth("alpha", "1b", 300 * KIB, "Apache-2.0", 12);
    let hex = a.model_hex();
    let env = Env::new(vec![a.clone()]);
    // 1st CDN request fine, 2nd comes back 403 as an expired signature would
    env.reg.fault(Some(&hex), Fault::Longer(0));
    env.reg.fault(Some(&hex), Fault::Expire);
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    env.blob_ok(&a);
    let resolutions = env
        .reg
        .hits()
        .iter()
        .filter(|h| h.server == "registry" && h.method == "GET" && h.path.ends_with(&hex))
        .count();
    assert_eq!(
        resolutions, 2,
        "the registry was asked for a fresh URL once"
    );
    let all = format!("{}{:?}", run.event_text, run.outcome.errors);
    assert!(!all.contains("SECRETSIG"));
}

#[test]
fn a_server_that_ignores_range_is_handled() {
    let a = synth("alpha", "1b", 150 * KIB, "Apache-2.0", 13);
    let hex = a.model_hex();
    // from the start: the 200 body is taken whole
    let env = Env::new(vec![a.clone()]);
    env.reg.fault(Some(&hex), Fault::IgnoreRange);
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    assert_eq!(
        run.outcome.bytes_downloaded as usize,
        150 * KIB,
        "one request, no wasted bytes"
    );
    assert_eq!(env.reg.cdn_ranges(&hex).len(), 1);
    env.blob_ok(&a);
    // mid-file: the transfer restarts from zero
    let env = Env::new(vec![a.clone()]);
    seed_partial(&env, &a, 70 * KIB, 70 * KIB as u64);
    env.reg.fault(Some(&hex), Fault::IgnoreRange);
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    env.blob_ok(&a);
    // a wrong Content-Range is retried
    let env = Env::new(vec![a.clone()]);
    env.reg.fault(Some(&hex), Fault::BadContentRange);
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    env.blob_ok(&a);
}

#[test]
fn a_stalled_connection_times_out_and_resumes() {
    let a = synth("alpha", "1b", 64 * KIB, "Apache-2.0", 14);
    let hex = a.model_hex();
    let env = Env::new(vec![a.clone()]);
    env.reg.fault(
        Some(&hex),
        Fault::StallAfter {
            bytes: 100,
            secs: 6,
        },
    );
    let mut opts = env.opts();
    opts.transfer.stall_timeout = Duration::from_secs(1);
    opts.transfer.chunk.initial = 16 * KIB as u64;
    opts.transfer.chunk.max = 16 * KIB as u64;
    let started = Instant::now();
    let run = env.fetch_with(
        &env.pack(),
        &opts,
        &FileSinkFactory,
        Arc::new(AtomicBool::new(false)),
    );
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "{:?}: the stall must not last the server's 6 s",
        started.elapsed()
    );
    env.blob_ok(&a);
    assert_eq!(
        env.reg.cdn_ranges(&hex)[1],
        format!("bytes=100-{}", 100 + 16 * KIB - 1),
        "resumed after the 100 bytes that arrived"
    );
}

// ---- integrity -----------------------------------------------------------------------

#[test]
fn wrong_bytes_are_exit_7_and_never_enter_the_store() {
    let a = synth("alpha", "1b", 200 * KIB, "Apache-2.0", 15);
    let b = synth("beta", "1b", 100 * KIB, "Apache-2.0", 16);
    let env = Env::new(vec![a.clone(), b.clone()]);
    *env.reg.state.corrupt_offset.lock().unwrap() = Some(123_456);
    let run = env.fetch(&env.pack());
    assert_eq!(
        run.outcome.exit,
        exit::INTEGRITY,
        "{:?}",
        run.outcome.errors
    );
    assert_eq!(
        run.outcome.models_failed, 1,
        "the other model (whose bytes are fine) completes"
    );
    assert!(!env.layout().blob_path(&a.model_hex()).unwrap().exists());
    assert!(
        !env.partial_files()
            .iter()
            .any(|f| f.starts_with(&a.model_hex())),
        "the bad partial is removed: {:?}",
        env.partial_files()
    );
    env.no_manifest(&a);
    env.blob_ok(&b);
    let err = run
        .events
        .iter()
        .find(|e| e["event"] == "error" && e["code"] == "integrity")
        .expect("an integrity error event");
    assert_eq!(err["exit"], 7);
}

#[test]
fn a_server_whose_file_is_not_the_locked_size_is_refused_at_once() {
    let a = synth("alpha", "1b", 100 * KIB, "Apache-2.0", 17);
    let hex = a.model_hex();
    // shorter on the server than in the lock
    let env = Env::new(vec![a.clone()]);
    let shorter = a.model_bytes()[..100 * KIB - 10].to_vec();
    env.reg
        .state
        .blobs
        .lock()
        .unwrap()
        .insert(hex.clone(), Arc::new(shorter));
    let run = env.fetch(&env.pack());
    assert_eq!(
        run.outcome.exit,
        exit::INTEGRITY,
        "{:?}",
        run.outcome.errors
    );
    assert!(
        run.outcome.errors.iter().any(|e| e.contains("lock says")),
        "{:?}",
        run.outcome.errors
    );
    // longer
    let env = Env::new(vec![a.clone()]);
    let mut longer = a.model_bytes().to_vec();
    longer.extend_from_slice(&[1; 10]);
    env.reg
        .state
        .blobs
        .lock()
        .unwrap()
        .insert(hex.clone(), Arc::new(longer));
    let run = env.fetch(&env.pack());
    assert_eq!(
        run.outcome.exit,
        exit::INTEGRITY,
        "{:?}",
        run.outcome.errors
    );
    // a 200 body longer than the locked size
    let env = Env::new(vec![a.clone()]);
    env.reg.fault(Some(&hex), Fault::IgnoreRange);
    let mut longer = a.model_bytes().to_vec();
    longer.extend_from_slice(&[1; 10]);
    env.reg
        .state
        .blobs
        .lock()
        .unwrap()
        .insert(hex.clone(), Arc::new(longer));
    let run = env.fetch(&env.pack());
    assert_eq!(
        run.outcome.exit,
        exit::INTEGRITY,
        "{:?}",
        run.outcome.errors
    );
    assert!(!env.layout().blob_path(&hex).unwrap().exists());
}

// ---- policy --------------------------------------------------------------------------

#[test]
fn a_hostile_redirect_is_refused_without_following_it() {
    let a = synth("alpha", "1b", 100 * KIB, "Apache-2.0", 18);
    for target in [
        "http://169.254.169.254/latest/meta-data/?X-Amz-Signature=SECRETSIG",
        "http://10.0.0.1/blob",
        "ftp://example.com/x",
    ] {
        let env = Env::new(vec![a.clone()]);
        *env.reg.state.redirect_override.lock().unwrap() = Some(target.to_string());
        let run = env.fetch(&env.pack());
        assert_eq!(
            run.outcome.exit,
            exit::ERROR,
            "{target}: {:?}",
            run.outcome.errors
        );
        let text = format!("{:?}{}", run.outcome.errors, run.event_text);
        assert!(
            text.contains("network policy")
                || text.contains("refusing")
                || text.contains("bad URL"),
            "{target}: {text}"
        );
        assert!(
            !text.contains("SECRETSIG"),
            "{target}: query string leaked: {text}"
        );
        assert!(env.reg.cdn_ranges(&a.model_hex()).is_empty());
    }
    // a redirect loop
    let env = Env::new(vec![a.clone()]);
    *env.reg.state.redirect_override.lock().unwrap() = Some(format!(
        "{}/v2/library/alpha/blobs/sha256:{}",
        env.reg.url(),
        a.model_hex()
    ));
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, exit::ERROR);
    assert!(
        run.outcome.errors.iter().any(|e| e.contains("redirects")),
        "{:?}",
        run.outcome.errors
    );
}

// ---- licences, offline, throttling, concurrency -----------------------------------------

#[test]
fn unverified_licences_are_gated_unless_accepted() {
    let ok = synth("good", "1b", 80 * KIB, "Apache-2.0", 19);
    let gated = synth("gated", "1b", 80 * KIB, "unverified", 20);
    let env = Env::new(vec![ok.clone(), gated.clone()]);
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, exit::LICENSE, "{:?}", run.outcome.errors);
    assert_eq!(run.outcome.models_ok, 1);
    assert_eq!(run.outcome.models_gated, 1);
    env.blob_ok(&ok);
    env.no_manifest(&gated);
    assert!(
        !env.layout().blob_path(&gated.model_hex()).unwrap().exists(),
        "nothing of a gated model is downloaded"
    );
    let e = run
        .events
        .iter()
        .find(|e| e["code"] == "license")
        .expect("a licence event");
    assert_eq!(e["model"], "gated:1b");
    assert_eq!(e["exit"], 5);
    assert_eq!(run.status.unwrap()["models"][1]["state"], "gated");

    let mut opts = env.opts();
    opts.accept_licenses = true;
    let run = env.fetch_with(
        &env.pack(),
        &opts,
        &FileSinkFactory,
        Arc::new(AtomicBool::new(false)),
    );
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    env.blob_ok(&gated);
}

#[test]
fn offline_succeeds_only_from_the_cache() {
    let a = synth("alpha", "1b", 80 * KIB, "Apache-2.0", 21);
    let env = Env::new(vec![a.clone()]);
    let mut opts = env.opts();
    opts.offline = true;
    let run = env.fetch_with(
        &env.pack(),
        &opts,
        &FileSinkFactory,
        Arc::new(AtomicBool::new(false)),
    );
    assert_eq!(
        run.outcome.exit,
        exit::INTERRUPTED,
        "{:?}",
        run.outcome.errors
    );
    assert!(env.reg.hits().is_empty(), "offline must not open a socket");
    assert_eq!(env.fetch(&env.pack()).outcome.exit, 0);
    env.reg.clear_hits();
    let run = env.fetch_with(
        &env.pack(),
        &opts,
        &FileSinkFactory,
        Arc::new(AtomicBool::new(false)),
    );
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    assert!(env.reg.hits().is_empty());
}

#[test]
fn the_rate_limit_applies_to_the_whole_job_and_workers_run_in_parallel() {
    let models: Vec<Synth> = (0..3)
        .map(|i| synth(&format!("m{i}"), "1b", 200 * KIB, "Apache-2.0", 30 + i))
        .collect();
    let env = Env::new(models.clone());
    let mut opts = env.opts();
    opts.concurrency = 3;
    opts.max_bytes_per_sec = Some(400 * KIB as u64);
    let started = Instant::now();
    let run = env.fetch_with(
        &env.pack(),
        &opts,
        &FileSinkFactory,
        Arc::new(AtomicBool::new(false)),
    );
    let took = started.elapsed();
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    for m in &models {
        env.blob_ok(m);
    }
    // 600 KiB at 400 KiB/s is 1.5 s; per-connection limiting would have taken 0.5 s
    assert!(
        took >= Duration::from_millis(1100),
        "{took:?}: the limit must be shared by all workers"
    );
    assert!(took < Duration::from_secs(8), "{took:?}");
    // fully parallel without a limit
    let env = Env::new(models.clone());
    let mut opts = env.opts();
    opts.concurrency = 3;
    let run = env.fetch_with(
        &env.pack(),
        &opts,
        &FileSinkFactory,
        Arc::new(AtomicBool::new(false)),
    );
    assert_eq!(run.outcome.exit, 0);
    for m in &models {
        env.blob_ok(m);
    }
}

// ---- disk full, cancel ----------------------------------------------------------------

#[test]
fn a_full_disk_stops_with_exit_4_and_a_consistent_partial() {
    let a = synth("alpha", "1b", 400 * KIB, "Apache-2.0", 40);
    let hex = a.model_hex();
    let env = Env::new(vec![a.clone()]);
    let disk = FullDisk::after(180 * KIB as u64 + 7);
    let run = env.fetch_with(
        &env.pack(),
        &env.opts(),
        &disk,
        Arc::new(AtomicBool::new(false)),
    );
    assert_eq!(run.outcome.exit, exit::NO_SPACE, "{:?}", run.outcome.errors);
    assert_eq!(run.outcome.status, "failed");
    assert_eq!(run.status.as_ref().unwrap()["state"], "failed");
    assert_eq!(run.status.as_ref().unwrap()["last_error"]["exit"], 4);
    env.no_manifest(&a);
    assert!(!env.layout().blob_path(&hex).unwrap().exists());
    // the partial and its journal agree: the journal never claims more than is on disk, and
    // what it claims is a true prefix of the blob
    let j = read_journal(&env.layout().journal_path(&hex).unwrap())
        .expect("a journal was written before giving up");
    assert!(j.matches(&hex, a.model_bytes().len() as u64));
    let data = fs::read(env.layout().partial_path(&hex).unwrap()).unwrap();
    assert!(
        j.committed as usize <= data.len(),
        "journal {} > data {}",
        j.committed,
        data.len()
    );
    assert_eq!(
        &data[..j.committed as usize],
        &a.model_bytes()[..j.committed as usize]
    );
    assert!(
        j.committed >= 128 * KIB as u64,
        "progress up to the last sync is kept: {}",
        j.committed
    );
    // with space again the same command resumes exactly there and finishes
    env.reg.clear_hits();
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    assert_eq!(
        env.reg.cdn_ranges(&hex)[0],
        format!("bytes={}-{}", j.committed, j.committed + 65535)
    );
    env.blob_ok(&a);
}

#[test]
fn cancelling_midway_keeps_a_resumable_state() {
    let a = synth("alpha", "1b", 600 * KIB, "Apache-2.0", 41);
    let hex = a.model_hex();
    let env = Env::new(vec![a.clone()]);
    env.reg
        .state
        .cdn_bps
        .store(300 * KIB as u64, Ordering::Relaxed);
    let cancel = Arc::new(AtomicBool::new(false));
    let c2 = cancel.clone();
    let layout = env.layout();
    let pp = layout.partial_path(&hex).unwrap();
    let watcher = std::thread::spawn(move || {
        wait_for(20, "some bytes", || {
            fs::metadata(&pp).is_ok_and(|m| m.len() > 100 * KIB as u64)
        });
        c2.store(true, Ordering::Relaxed);
    });
    let run = env.fetch_with(&env.pack(), &env.opts(), &FileSinkFactory, cancel);
    watcher.join().unwrap();
    assert_eq!(
        run.outcome.exit,
        exit::INTERRUPTED,
        "{:?}",
        run.outcome.errors
    );
    assert_eq!(run.outcome.status, "interrupted");
    let j =
        read_journal(&env.layout().journal_path(&hex).unwrap()).expect("journal flushed on cancel");
    assert!(j.committed > 0);
    let data = fs::read(env.layout().partial_path(&hex).unwrap()).unwrap();
    assert_eq!(
        &data[..j.committed as usize],
        &a.model_bytes()[..j.committed as usize]
    );
    // resume at full speed
    env.reg.state.cdn_bps.store(0, Ordering::Relaxed);
    env.reg.clear_hits();
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0, "{:?}", run.outcome.errors);
    assert!(env.reg.cdn_ranges(&hex)[0].starts_with(&format!("bytes={}-", j.committed)));
    env.blob_ok(&a);
}

// ---- plan ------------------------------------------------------------------------------

#[test]
fn plan_counts_shared_blobs_once_and_applies_the_three_percent_rule() {
    let a = synth("alpha", "1b", 300 * KIB, "Apache-2.0", 50);
    let b = synth("beta", "1b", 200 * KIB, "Apache-2.0", 51);
    let env = Env::new(vec![a.clone(), b.clone()]);
    let cache = env.cache();
    let plan = build_plan(&env.lock, &env.pack(), Some(&cache), false).unwrap();
    let t = plan.totals();
    let unique: usize = {
        let mut seen = std::collections::BTreeSet::new();
        env.synths
            .iter()
            .flat_map(|s| s.layers.iter())
            .filter(|l| seen.insert(hex_of(&l.2)))
            .map(|l| l.2.len())
            .sum()
    };
    assert_eq!(
        t.total_bytes as usize, unique,
        "the licence text is counted once"
    );
    assert_eq!(t.present_bytes, 0);
    assert_eq!(t.missing_bytes, t.total_bytes);
    assert!(
        t.need_on_disk_bytes >= t.total_bytes,
        "cluster rounding only adds"
    );
    // the 3 % rule: a selection that is 96 % of the volume fits, one that is 98 % does not
    let mut plan = plan;
    let total = t.total_on_disk_bytes;
    let at = |pct: u64| total * 100 / pct;
    plan.fs.free_bytes = Some(u64::MAX / 4);
    plan.fs.total_bytes = Some(at(96));
    assert_eq!(plan.totals().fits_capacity, Some(true));
    assert_eq!(plan.totals().fits, Some(true));
    plan.fs.total_bytes = Some(at(98));
    assert_eq!(
        plan.totals().fits_capacity,
        Some(false),
        "98 % of the volume leaves less than 3 % free"
    );
    assert_eq!(plan.totals().fits, Some(false));
    // the free-space rule: a big volume that is nearly full
    plan.fs.total_bytes = Some(total * 1000);
    plan.fs.free_bytes = Some(plan.totals().need_on_disk_bytes - 1);
    assert_eq!(plan.totals().fits_capacity, Some(true));
    assert_eq!(plan.totals().fits_free, Some(false));
    assert_eq!(plan.totals().fits, Some(false));
    plan.fs.free_bytes =
        Some(plan.totals().need_on_disk_bytes + ci_stick::fetch::plan::RESERVE_BYTES);
    assert_eq!(plan.totals().fits_free, Some(true));
    plan.fs.free_bytes = None;
    plan.fs.total_bytes = None;
    assert_eq!(plan.totals().fits, None);

    // after a fetch everything is present; a partial counts as such
    assert_eq!(env.fetch(&env.pack()).outcome.exit, 0);
    let t = build_plan(&env.lock, &env.pack(), Some(&cache), false)
        .unwrap()
        .totals();
    assert_eq!(t.missing_bytes, 0);
    assert_eq!(t.present_bytes, t.total_bytes);
    let env2 = Env::new(vec![a.clone(), b.clone()]);
    seed_partial(&env2, &a, 100 * KIB, 100 * KIB as u64);
    let t = build_plan(&env2.lock, &env2.pack(), Some(&env2.cache()), false)
        .unwrap()
        .totals();
    assert_eq!(t.partial_bytes as usize, 100 * KIB);
    assert_eq!(t.missing_bytes + t.partial_bytes, t.total_bytes);
}

#[test]
fn macos_and_windows_litter_in_the_cache_is_ignored() {
    let a = synth("alpha", "1b", 100 * KIB, "Apache-2.0", 52);
    let env = Env::new(vec![a.clone()]);
    assert_eq!(env.fetch(&env.pack()).outcome.exit, 0);
    let blobs = env.layout().blobs_dir();
    fs::write(
        blobs.join(format!("._sha256-{}", a.model_hex())),
        b"appledouble",
    )
    .unwrap();
    fs::write(blobs.join(".DS_Store"), b"x").unwrap();
    fs::write(env.cache().join("models").join("._manifests"), b"x").unwrap();
    let run = env.fetch(&env.pack());
    assert_eq!(run.outcome.exit, 0);
    assert!(
        env.reg.hits().len() < 10,
        "litter must not make a complete model look incomplete"
    );
    let scan = ci_stick::cache::scan(&env.layout());
    assert_eq!(scan.junk_files, 2);
    assert_eq!(scan.foreign_blob_files, 0);
    env.blob_ok(&a);
}
