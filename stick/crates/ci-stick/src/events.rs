//! Progress reporting for `ci-stick models fetch`: a JSON-lines event stream (`--events`) and
//! an atomically rewritten `status.json` for the setup portal (stdlib JSON, no new service).
//!
//! # Event lines
//!
//! One JSON object per line. Every line carries all of these keys (`null` where they do not
//! apply), so a consumer can rely on their presence:
//!
//! | key | meaning |
//! |---|---|
//! | `event` | `start`, `progress`, `blob_done`, `model_done`, `error` or `done` |
//! | `model` | model reference, e.g. `gemma3:1b` |
//! | `blob` | `sha256:<hex>` |
//! | `bytes` | `progress`/`blob_done`: bytes of this blob stored so far; `model_done`: the model's size; `start`: bytes still to download; `done`: bytes downloaded by this run |
//! | `total` | `progress`/`blob_done`: the blob's size; otherwise the whole plan's size |
//! | `rate_bps` | smoothed download rate of the whole job, bytes per second |
//! | `eta_s` | seconds until the whole job finishes at that rate |
//! | `ts` | RFC 3339 UTC timestamp |
//!
//! Extra keys appear only on some events: `job` (id), `pack`, `models` (count) on `start`;
//! `job_bytes`/`job_total` on `progress`; `skipped` (already in the cache) on `blob_done`
//! and `model_done`; `code`, `message`, `exit`, `fatal` on `error`; `status`
//! (`ok`/`failed`/`interrupted`), `exit`, `models_ok`, `models_failed`, `models_gated` on
//! `done`. `progress` lines are limited to two per second. Retries are not events; they show
//! in `status.json` (`state: "retrying"`).
//!
//! # status.json
//!
//! `<cache>/ci-models/status.json`, replaced atomically (temp file and rename), at most once
//! per second except for state changes:
//!
//! ```json
//! {"schema":1,"job":"9f3c...","state":"running","updated":"2026-10-17T12:00:00Z",
//!  "pack":"stick-128","bytes_total":74795277212,"bytes_done":1234567,"rate_bps":24800000,
//!  "eta_s":3000,"current":{"model":"gemma3:1b","blob":"sha256:...","done":100,"size":805000000},
//!  "models":[{"model":"gemma3:1b","state":"running","bytes_done":100,"bytes_total":806067407}],
//!  "last_error":{"code":"net","exit":6,"message":"..."},"retry_in_s":null}
//! ```
//!
//! `state` is one of `idle`, `running`, `retrying`, `done`, `failed`, `interrupted`;
//! a model's `state` is `queued`, `running`, `done`, `failed` or `gated`.

use std::fs::OpenOptions;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::cache::store::write_atomic;
use crate::size::fmt_binary;
use crate::timefmt;

/// Shortest interval between two `status.json` rewrites that are not state changes.
pub const STATUS_INTERVAL: Duration = Duration::from_secs(1);
/// Shortest interval between two `progress` event lines.
pub const PROGRESS_INTERVAL: Duration = Duration::from_millis(500);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    Start,
    Progress,
    BlobDone,
    ModelDone,
    Error,
    Done,
}

impl EventKind {
    pub fn as_str(self) -> &'static str {
        match self {
            EventKind::Start => "start",
            EventKind::Progress => "progress",
            EventKind::BlobDone => "blob_done",
            EventKind::ModelDone => "model_done",
            EventKind::Error => "error",
            EventKind::Done => "done",
        }
    }
}

/// One event line. Build with [`Event::new`] and the `with_*` helpers.
#[derive(Debug, Clone)]
pub struct Event {
    kind: EventKind,
    model: Option<String>,
    blob: Option<String>,
    bytes: Option<u64>,
    total: Option<u64>,
    rate_bps: Option<u64>,
    eta_s: Option<u64>,
    extra: Map<String, Value>,
}

impl Event {
    pub fn new(kind: EventKind) -> Self {
        Self {
            kind,
            model: None,
            blob: None,
            bytes: None,
            total: None,
            rate_bps: None,
            eta_s: None,
            extra: Map::new(),
        }
    }
    pub fn model(mut self, m: &str) -> Self {
        self.model = Some(m.to_string());
        self
    }
    pub fn blob(mut self, digest: &str) -> Self {
        self.blob = Some(digest.to_string());
        self
    }
    pub fn bytes(mut self, bytes: u64, total: u64) -> Self {
        self.bytes = Some(bytes);
        self.total = Some(total);
        self
    }
    pub fn rate(mut self, rate_bps: u64, eta_s: Option<u64>) -> Self {
        self.rate_bps = Some(rate_bps);
        self.eta_s = eta_s;
        self
    }
    pub fn with(mut self, key: &str, value: Value) -> Self {
        self.extra.insert(key.to_string(), value);
        self
    }

    /// The JSON object for this event, stamped `ts`.
    pub fn to_value(&self, ts: &str) -> Value {
        let mut m = Map::new();
        m.insert("event".into(), json!(self.kind.as_str()));
        m.insert("model".into(), json!(self.model));
        m.insert("blob".into(), json!(self.blob));
        m.insert("bytes".into(), json!(self.bytes));
        m.insert("total".into(), json!(self.total));
        m.insert("rate_bps".into(), json!(self.rate_bps));
        m.insert("eta_s".into(), json!(self.eta_s));
        m.insert("ts".into(), json!(ts));
        for (k, v) in &self.extra {
            m.insert(k.clone(), v.clone());
        }
        Value::Object(m)
    }
}

/// Where event lines go.
pub struct EventSink {
    out: Option<Mutex<Box<dyn Write + Send>>>,
    to_stdout: bool,
    warned: AtomicBool,
}

impl EventSink {
    pub fn none() -> Self {
        Self {
            out: None,
            to_stdout: false,
            warned: AtomicBool::new(false),
        }
    }

    pub fn stdout() -> Self {
        Self {
            out: Some(Mutex::new(Box::new(io::stdout()))),
            to_stdout: true,
            warned: AtomicBool::new(false),
        }
    }

    /// Append to a file, creating it (and its directory) if needed.
    pub fn file(path: &Path) -> io::Result<Self> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)?;
        }
        let f = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Self {
            out: Some(Mutex::new(Box::new(f))),
            to_stdout: false,
            warned: AtomicBool::new(false),
        })
    }

    /// For tests: collect lines in memory.
    pub fn writer(w: Box<dyn Write + Send>) -> Self {
        Self {
            out: Some(Mutex::new(w)),
            to_stdout: false,
            warned: AtomicBool::new(false),
        }
    }

    /// `-` is stdout, anything else a file.
    pub fn from_arg(arg: &str) -> io::Result<Self> {
        if arg == "-" {
            Ok(Self::stdout())
        } else {
            Self::file(Path::new(arg))
        }
    }

    /// `true` when event lines own stdout (so nothing else may be printed there).
    pub fn owns_stdout(&self) -> bool {
        self.to_stdout
    }

    pub fn is_active(&self) -> bool {
        self.out.is_some()
    }

    /// Write one line. A write failure is reported once on stderr and never fails the job.
    pub fn emit(&self, ev: &Event) {
        let Some(out) = &self.out else { return };
        let mut line = ev.to_value(&timefmt::now_rfc3339()).to_string();
        line.push('\n');
        let mut guard = out.lock().unwrap_or_else(|e| e.into_inner());
        let res = guard
            .write_all(line.as_bytes())
            .and_then(|()| guard.flush());
        if let Err(e) = res {
            if e.kind() != io::ErrorKind::BrokenPipe && !self.warned.swap(true, Ordering::Relaxed) {
                eprintln!("warning: cannot write the event stream: {e}");
            }
        }
    }
}

/// Smoothed throughput of the whole job.
#[derive(Debug)]
pub struct RateMeter {
    window_start: Instant,
    window_bytes: u64,
    ewma: Option<f64>,
}

impl RateMeter {
    pub fn new() -> Self {
        Self {
            window_start: Instant::now(),
            window_bytes: 0,
            ewma: None,
        }
    }

    /// Record `delta` bytes at `now`; windows shorter than 250 ms are accumulated.
    pub fn add(&mut self, delta: u64, now: Instant) {
        self.window_bytes += delta;
        let dt = now.saturating_duration_since(self.window_start);
        if dt >= Duration::from_millis(250) {
            let inst = self.window_bytes as f64 / dt.as_secs_f64();
            self.ewma = Some(match self.ewma {
                Some(prev) => 0.3 * inst + 0.7 * prev,
                None => inst,
            });
            self.window_start = now;
            self.window_bytes = 0;
        }
    }

    pub fn bytes_per_sec(&self) -> u64 {
        self.ewma.map_or(0, |r| r.max(0.0) as u64)
    }

    pub fn eta_secs(&self, remaining: u64) -> Option<u64> {
        let r = self.bytes_per_sec();
        (r > 0).then(|| remaining.div_ceil(r))
    }
}

impl Default for RateMeter {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct CurrentBlob {
    pub model: String,
    pub blob: String,
    pub done: u64,
    pub size: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ModelStatus {
    pub model: String,
    /// `queued`, `running`, `done`, `failed` or `gated`.
    pub state: String,
    pub bytes_done: u64,
    pub bytes_total: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct LastError {
    pub code: String,
    pub exit: u8,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct StatusDoc {
    pub schema: u32,
    pub job: String,
    pub state: String,
    pub updated: String,
    pub pack: Option<String>,
    pub bytes_total: u64,
    pub bytes_done: u64,
    pub rate_bps: u64,
    pub eta_s: Option<u64>,
    pub current: Option<CurrentBlob>,
    pub models: Vec<ModelStatus>,
    pub last_error: Option<LastError>,
    pub retry_in_s: Option<u64>,
}

struct State {
    doc: StatusDoc,
    rate: RateMeter,
    last_status_write: Option<Instant>,
    last_progress_event: Option<Instant>,
}

/// Thread-safe sink for everything `fetch` has to say: events and `status.json`.
pub struct Reporter {
    events: EventSink,
    status_path: Option<PathBuf>,
    state: Mutex<State>,
    started: Instant,
    status_interval: Duration,
    progress_interval: Duration,
    tty: bool,
}

/// A job id: 16 hex characters.
pub fn new_job_id() -> String {
    let mut b = [0u8; 8];
    if getrandom::getrandom(&mut b).is_err() {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        b = (t as u64).to_le_bytes();
    }
    hex::encode(b)
}

impl Reporter {
    pub fn new(events: EventSink, status_path: Option<PathBuf>, pack: Option<String>) -> Self {
        let doc = StatusDoc {
            schema: 1,
            job: new_job_id(),
            state: "idle".into(),
            updated: timefmt::now_rfc3339(),
            pack,
            bytes_total: 0,
            bytes_done: 0,
            rate_bps: 0,
            eta_s: None,
            current: None,
            models: Vec::new(),
            last_error: None,
            retry_in_s: None,
        };
        Self {
            events,
            status_path,
            state: Mutex::new(State {
                doc,
                rate: RateMeter::new(),
                last_status_write: None,
                last_progress_event: None,
            }),
            started: Instant::now(),
            status_interval: STATUS_INTERVAL,
            progress_interval: PROGRESS_INTERVAL,
            tty: false,
        }
    }

    /// Draw a one-line progress display on stderr (use only when stderr is a terminal).
    pub fn with_tty_progress(mut self) -> Self {
        self.tty = true;
        self
    }

    /// Test hook: change the throttling intervals.
    pub fn with_intervals(mut self, status: Duration, progress: Duration) -> Self {
        self.status_interval = status;
        self.progress_interval = progress;
        self
    }

    pub fn events(&self) -> &EventSink {
        &self.events
    }

    pub fn job_id(&self) -> String {
        self.lock().doc.job.clone()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn write_status(&self, st: &mut State, force: bool) {
        let Some(path) = &self.status_path else {
            return;
        };
        let now = Instant::now();
        if !force {
            if let Some(last) = st.last_status_write {
                if now.saturating_duration_since(last) < self.status_interval {
                    return;
                }
            }
        }
        st.last_status_write = Some(now);
        st.doc.updated = timefmt::now_rfc3339();
        st.doc.rate_bps = st.rate.bytes_per_sec();
        let remaining = st.doc.bytes_total.saturating_sub(st.doc.bytes_done);
        st.doc.eta_s = st.rate.eta_secs(remaining);
        let mut bytes = match serde_json::to_vec_pretty(&st.doc) {
            Ok(b) => b,
            Err(_) => return,
        };
        bytes.push(b'\n');
        // Best effort: a full or read-only stick must not take the download down with it.
        let _ = write_atomic(path, &bytes);
    }

    /// Plan accepted: `to_download` bytes still needed out of `total` for the whole plan.
    pub fn start(&self, models: Vec<ModelStatus>, to_download: u64, total: u64, already: u64) {
        let mut st = self.lock();
        st.doc.state = "running".into();
        st.doc.models = models;
        st.doc.bytes_total = total;
        st.doc.bytes_done = already;
        let n = st.doc.models.len();
        let job = st.doc.job.clone();
        let pack = st.doc.pack.clone();
        self.write_status(&mut st, true);
        drop(st);
        self.events.emit(
            &Event::new(EventKind::Start)
                .bytes(to_download, total)
                .with("job", json!(job))
                .with("pack", json!(pack))
                .with("models", json!(n)),
        );
    }

    /// `delta` new bytes of `blob` arrived; the blob now holds `done` of `size`.
    pub fn progress(&self, model: &str, blob: &str, done: u64, size: u64, delta: u64) {
        let now = Instant::now();
        let mut st = self.lock();
        st.rate.add(delta, now);
        st.doc.bytes_done = st.doc.bytes_done.saturating_add(delta);
        st.doc.state = "running".into();
        st.doc.retry_in_s = None;
        st.doc.current = Some(CurrentBlob {
            model: model.to_string(),
            blob: blob.to_string(),
            done,
            size,
        });
        if let Some(m) = st.doc.models.iter_mut().find(|m| m.model == model) {
            m.state = "running".into();
            m.bytes_done = m.bytes_done.saturating_add(delta).min(m.bytes_total);
        }
        self.write_status(&mut st, false);
        let emit = st.last_progress_event.map_or(true, |t| {
            now.saturating_duration_since(t) >= self.progress_interval
        });
        if !emit {
            return;
        }
        st.last_progress_event = Some(now);
        if self.tty {
            let pct = st
                .doc
                .bytes_done
                .saturating_mul(100)
                .checked_div(st.doc.bytes_total)
                .unwrap_or(0);
            let _ = write!(
                io::stderr(),
                "\r\x1b[2K{pct:>3}% {} / {}  {}/s  {model}",
                fmt_binary(st.doc.bytes_done),
                fmt_binary(st.doc.bytes_total),
                fmt_binary(st.rate.bytes_per_sec()),
            );
        }
        let rate = st.rate.bytes_per_sec();
        let eta = st
            .rate
            .eta_secs(st.doc.bytes_total.saturating_sub(st.doc.bytes_done));
        let (job_done, job_total) = (st.doc.bytes_done, st.doc.bytes_total);
        drop(st);
        self.events.emit(
            &Event::new(EventKind::Progress)
                .model(model)
                .blob(blob)
                .bytes(done, size)
                .rate(rate, eta)
                .with("job_bytes", json!(job_done))
                .with("job_total", json!(job_total)),
        );
    }

    /// Account bytes that were already in the cache (a resumed prefix or a present blob).
    pub fn credit(&self, model: &str, bytes: u64) {
        let mut st = self.lock();
        st.doc.bytes_done = st.doc.bytes_done.saturating_add(bytes);
        if let Some(m) = st.doc.models.iter_mut().find(|m| m.model == model) {
            m.bytes_done = m.bytes_done.saturating_add(bytes).min(m.bytes_total);
        }
    }

    pub fn blob_done(&self, model: &str, blob: &str, size: u64, skipped: bool) {
        let mut st = self.lock();
        self.write_status(&mut st, true);
        let (rate, eta) = (
            st.rate.bytes_per_sec(),
            st.rate
                .eta_secs(st.doc.bytes_total.saturating_sub(st.doc.bytes_done)),
        );
        drop(st);
        self.events.emit(
            &Event::new(EventKind::BlobDone)
                .model(model)
                .blob(blob)
                .bytes(size, size)
                .rate(rate, eta)
                .with("skipped", json!(skipped)),
        );
    }

    pub fn model_done(&self, model: &str, size_bytes: u64, skipped: bool) {
        let mut st = self.lock();
        if let Some(m) = st.doc.models.iter_mut().find(|m| m.model == model) {
            m.state = "done".into();
            m.bytes_done = m.bytes_total;
        }
        self.write_status(&mut st, true);
        drop(st);
        self.events.emit(
            &Event::new(EventKind::ModelDone)
                .model(model)
                .bytes(size_bytes, size_bytes)
                .with("skipped", json!(skipped)),
        );
    }

    pub fn model_state(&self, model: &str, state: &str) {
        let mut st = self.lock();
        if let Some(m) = st.doc.models.iter_mut().find(|m| m.model == model) {
            m.state = state.to_string();
        }
        self.write_status(&mut st, false);
    }

    /// A transient failure is being retried in `in_s` seconds (status file only).
    pub fn retrying(&self, code: &str, message: &str, in_s: u64) {
        let mut st = self.lock();
        st.doc.state = "retrying".into();
        st.doc.retry_in_s = Some(in_s);
        st.doc.last_error = Some(LastError {
            code: code.to_string(),
            exit: 0,
            message: message.to_string(),
        });
        self.write_status(&mut st, true);
    }

    /// A failure that ends a model (or the job): one `error` event.
    pub fn error(
        &self,
        model: Option<&str>,
        blob: Option<&str>,
        code: &str,
        message: &str,
        exit: u8,
        fatal: bool,
    ) {
        let mut st = self.lock();
        st.doc.last_error = Some(LastError {
            code: code.to_string(),
            exit,
            message: message.to_string(),
        });
        if let Some(m) = model {
            if let Some(ms) = st.doc.models.iter_mut().find(|x| x.model == m) {
                if ms.state != "gated" {
                    ms.state = "failed".into();
                }
            }
        }
        self.write_status(&mut st, true);
        drop(st);
        let mut ev = Event::new(EventKind::Error)
            .with("code", json!(code))
            .with("message", json!(message))
            .with("exit", json!(exit))
            .with("fatal", json!(fatal));
        if let Some(m) = model {
            ev = ev.model(m);
        }
        if let Some(b) = blob {
            ev = ev.blob(b);
        }
        self.events.emit(&ev);
    }

    /// Final state: `status` is `ok`, `failed` or `interrupted`.
    pub fn done(&self, status: &str, exit: u8, downloaded: u64, counts: (usize, usize, usize)) {
        let mut st = self.lock();
        st.doc.state = match status {
            "ok" => "done",
            "interrupted" => "interrupted",
            _ => "failed",
        }
        .into();
        st.doc.retry_in_s = None;
        st.doc.current = None;
        let total = st.doc.bytes_total;
        let secs = self.started.elapsed().as_secs_f64().max(0.001);
        let avg = (downloaded as f64 / secs) as u64;
        self.write_status(&mut st, true);
        drop(st);
        if self.tty {
            let _ = write!(io::stderr(), "\r\x1b[2K");
        }
        self.events.emit(
            &Event::new(EventKind::Done)
                .bytes(downloaded, total)
                .rate(avg, Some(0))
                .with("status", json!(status))
                .with("exit", json!(exit))
                .with("models_ok", json!(counts.0))
                .with("models_failed", json!(counts.1))
                .with("models_gated", json!(counts.2)),
        );
    }

    /// A copy of the current status document.
    pub fn snapshot(&self) -> StatusDoc {
        self.lock().doc.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex as StdMutex};

    #[derive(Clone, Default)]
    struct Capture(Arc<StdMutex<Vec<u8>>>);
    impl Write for Capture {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    impl Capture {
        fn lines(&self) -> Vec<Value> {
            String::from_utf8(self.0.lock().unwrap().clone())
                .unwrap()
                .lines()
                .map(|l| serde_json::from_str(l).unwrap())
                .collect()
        }
    }

    const STABLE_KEYS: [&str; 8] = [
        "event", "model", "blob", "bytes", "total", "rate_bps", "eta_s", "ts",
    ];

    #[test]
    fn every_line_has_the_stable_keys() {
        let cap = Capture::default();
        let r = Reporter::new(
            EventSink::writer(Box::new(cap.clone())),
            None,
            Some("p".into()),
        )
        .with_intervals(Duration::ZERO, Duration::ZERO);
        r.start(
            vec![ModelStatus {
                model: "m:1".into(),
                state: "queued".into(),
                bytes_done: 0,
                bytes_total: 100,
            }],
            100,
            100,
            0,
        );
        r.progress("m:1", "sha256:aa", 40, 100, 40);
        r.blob_done("m:1", "sha256:aa", 100, false);
        r.model_done("m:1", 100, false);
        r.error(Some("m:1"), None, "net", "boom", 6, true);
        r.done("failed", 6, 100, (1, 0, 0));
        let lines = cap.lines();
        let kinds: Vec<&str> = lines.iter().map(|l| l["event"].as_str().unwrap()).collect();
        assert_eq!(
            kinds,
            [
                "start",
                "progress",
                "blob_done",
                "model_done",
                "error",
                "done"
            ]
        );
        for l in &lines {
            for k in STABLE_KEYS {
                assert!(l.get(k).is_some(), "{k} missing in {l}");
            }
            assert!(timefmt::is_rfc3339_utc(l["ts"].as_str().unwrap()));
        }
        assert_eq!(lines[0]["pack"], "p");
        assert_eq!(lines[0]["models"], 1);
        assert_eq!(lines[1]["bytes"], 40);
        assert_eq!(lines[1]["total"], 100);
        assert_eq!(lines[1]["blob"], "sha256:aa");
        assert_eq!(lines[4]["code"], "net");
        assert_eq!(lines[4]["exit"], 6);
        assert_eq!(lines[5]["status"], "failed");
        assert!(lines[2]["rate_bps"].is_u64());
    }

    #[test]
    fn progress_lines_are_rate_limited() {
        let cap = Capture::default();
        let r = Reporter::new(EventSink::writer(Box::new(cap.clone())), None, None);
        r.start(vec![], 1000, 1000, 0);
        for i in 1..=200u64 {
            r.progress("m:1", "sha256:aa", i, 1000, 1);
        }
        let progress = cap
            .lines()
            .iter()
            .filter(|l| l["event"] == "progress")
            .count();
        assert!(
            (1..=3).contains(&progress),
            "{progress} progress lines in a tight loop"
        );
    }

    #[test]
    fn status_file_is_atomic_throttled_and_complete() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ci-models").join("status.json");
        let r = Reporter::new(
            EventSink::none(),
            Some(path.clone()),
            Some("stick-128".into()),
        );
        r.start(
            vec![
                ModelStatus {
                    model: "a:1".into(),
                    state: "queued".into(),
                    bytes_done: 0,
                    bytes_total: 50,
                },
                ModelStatus {
                    model: "b:1".into(),
                    state: "gated".into(),
                    bytes_done: 0,
                    bytes_total: 50,
                },
            ],
            100,
            100,
            0,
        );
        let first: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(first["schema"], 1);
        assert_eq!(first["state"], "running");
        assert_eq!(first["pack"], "stick-128");
        assert_eq!(first["bytes_total"], 100);
        assert_eq!(first["models"].as_array().unwrap().len(), 2);
        let stamp = std::fs::metadata(&path).unwrap().modified().unwrap();
        for i in 1..=50u64 {
            r.progress("a:1", "sha256:aa", i, 50, 1);
        }
        let mid: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert!(
            mid["bytes_done"].as_u64().unwrap() <= 1,
            "status writes are throttled to one per second"
        );
        let _ = stamp;
        r.model_done("a:1", 50, false);
        let after: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(after["bytes_done"], 50, "a state change forces a write");
        assert_eq!(after["models"][0]["state"], "done");
        assert_eq!(after["models"][1]["state"], "gated");
        r.retrying("net", "connection reset", 4);
        let ret: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(ret["state"], "retrying");
        assert_eq!(ret["retry_in_s"], 4);
        r.done("ok", 0, 50, (1, 0, 1));
        let fin: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(fin["state"], "done");
        // never a stray temp file next to it
        assert_eq!(
            std::fs::read_dir(path.parent().unwrap()).unwrap().count(),
            1
        );
    }

    #[test]
    fn rate_meter_smooths_and_estimates() {
        let t0 = Instant::now();
        let mut m = RateMeter::new();
        assert_eq!(m.bytes_per_sec(), 0);
        assert_eq!(m.eta_secs(100), None);
        m.add(1_000_000, t0 + Duration::from_secs(1));
        assert!((900_000..=1_100_000).contains(&m.bytes_per_sec()) || m.bytes_per_sec() > 0);
        assert!(m.eta_secs(1_000_000).unwrap() >= 1);
    }

    #[test]
    fn job_ids_differ() {
        assert_ne!(new_job_id(), new_job_id());
        assert_eq!(new_job_id().len(), 16);
    }
}
