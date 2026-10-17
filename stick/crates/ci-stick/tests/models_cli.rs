//! `ci-stick models plan | fetch | cache-info` end to end through the binary, against the
//! mock registry: exit codes, the event stream on stdout, status.json, redaction, and the
//! two ways a download process can die (SIGKILL and SIGINT) followed by a resume.

mod models_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use ci_stick::cache::layout::CacheLayout;
use ci_stick::cache::partial::read_journal;
use ci_stick::lockfile::ModelLock;
use models_support::*;
use serde_json::Value;

const KIB: usize = 1024;

struct Setup {
    reg: MockRegistry,
    dir: tempfile::TempDir,
    lock_path: PathBuf,
}

impl Setup {
    fn new(synths: Vec<Synth>) -> Setup {
        let reg = MockRegistry::start();
        for s in &synths {
            reg.add_model(s);
        }
        let refs: Vec<&Synth> = synths.iter().collect();
        let names: Vec<&str> = synths.iter().map(|s| s.reference.as_str()).collect();
        let lock = lock_for(&refs, &[("p", &names)]);
        let dir = tempfile::tempdir().unwrap();
        let lock_path = dir.path().join("model-packs.lock.json");
        fs::write(&lock_path, lock.to_canonical_json()).unwrap();
        fs::create_dir_all(dir.path().join("cache")).unwrap();
        Setup {
            reg,
            dir,
            lock_path,
        }
    }

    fn cache(&self) -> PathBuf {
        self.dir.path().join("cache")
    }

    fn layout(&self) -> CacheLayout {
        CacheLayout::new(self.cache())
    }

    fn args(&self, sub: &[&str]) -> Vec<String> {
        let mut v: Vec<String> = ["models"].iter().map(ToString::to_string).collect();
        v.extend(sub.iter().map(ToString::to_string));
        for (k, val) in [
            ("--cache", p(&self.cache())),
            ("--lock", p(&self.lock_path)),
        ] {
            v.push(k.into());
            v.push(val.into());
        }
        v
    }

    fn fetch_args(&self, extra: &[&str]) -> Vec<String> {
        let mut v = self.args(&["fetch", "--pack", "p"]);
        v.push("--registry-url".into());
        v.push(self.reg.url());
        v.extend(extra.iter().map(ToString::to_string));
        v
    }

    fn run(&self, args: &[String]) -> CliRun {
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        run_cli(&refs, &[])
    }

    fn assert_complete(&self, s: &Synth) {
        for (_, _, bytes) in &s.layers {
            let path = self.layout().blob_path(&hex_of(bytes)).unwrap();
            assert_eq!(
                fs::read(&path).unwrap_or_default(),
                *bytes,
                "{}",
                path.display()
            );
        }
        let m = self
            .layout()
            .manifest_path(&["registry.ollama.ai", "library", &s.name, &s.tag])
            .unwrap();
        assert_eq!(fs::read(m).unwrap(), s.manifest);
    }
}

fn json_lines(text: &str) -> Vec<Value> {
    text.lines()
        .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("not JSON: {l:?}: {e}")))
        .collect()
}

#[test]
fn fetch_streams_events_on_stdout_and_writes_status_json() {
    let a = synth("alpha", "1b", 300 * KIB, "Apache-2.0", 1);
    let b = synth("beta", "1b", 100 * KIB, "Apache-2.0", 2);
    let s = Setup::new(vec![a.clone(), b.clone()]);
    let out = s.run(&s.fetch_args(&["--events", "-"]));
    assert_eq!(out.code, 0, "{}", out.stderr);
    let events = json_lines(&out.stdout);
    assert_eq!(events.first().unwrap()["event"], "start");
    let last = events.last().unwrap();
    assert_eq!(last["event"], "done");
    assert_eq!(last["status"], "ok");
    assert_eq!(last["models_ok"], 2);
    assert!(events.iter().any(|e| e["event"] == "progress"));
    for e in &events {
        for k in [
            "event", "model", "blob", "bytes", "total", "rate_bps", "eta_s", "ts",
        ] {
            assert!(e.get(k).is_some(), "{k} missing: {e}");
        }
    }
    s.assert_complete(&a);
    s.assert_complete(&b);
    let status: Value =
        serde_json::from_slice(&fs::read(s.layout().status_file()).unwrap()).unwrap();
    assert_eq!(status["state"], "done");
    assert_eq!(status["schema"], 1);
    assert_eq!(status["pack"], "p");
    assert!(status["bytes_done"].as_u64().unwrap() > 0);
    // nothing but event lines went to stdout, and no presigned query string anywhere
    let all = format!(
        "{}{}{}",
        out.stdout,
        out.stderr,
        fs::read_to_string(s.layout().status_file()).unwrap()
    );
    assert!(
        !all.contains("SECRETSIG") && !all.contains("X-Amz"),
        "{all}"
    );

    // --events FILE appends instead; --json prints the result
    let file = s.dir.path().join("events.jsonl");
    let again = s.run(&s.fetch_args(&["--events", p(&file), "--json"]));
    assert_eq!(again.code, 0, "{}", again.stderr);
    let result: Value = serde_json::from_str(&again.stdout).unwrap();
    assert_eq!(result["status"], "ok");
    assert_eq!(result["bytes_downloaded"], 0);
    assert_eq!(
        result["models_ok"], 2,
        "complete models are counted and cost no downloads"
    );
    let lines = json_lines(&fs::read_to_string(&file).unwrap());
    assert_eq!(lines.last().unwrap()["event"], "done");
}

#[test]
fn exit_codes() {
    let a = synth("alpha", "1b", 60 * KIB, "Apache-2.0", 3);
    let g = synth("gated", "1b", 60 * KIB, "unverified", 4);
    let s = Setup::new(vec![a.clone(), g.clone()]);

    // 2: usage and input errors
    let usage = |args: Vec<String>| s.run(&args).code;
    assert_eq!(usage(s.args(&["fetch"])), 2, "neither --pack nor --model");
    assert_eq!(
        usage(s.args(&["fetch", "--pack", "p", "--model", "x"])),
        2,
        "both"
    );
    assert_eq!(
        usage(s.args(&["fetch", "--pack", "nope", "--registry-url", &s.reg.url()])),
        2,
        "unknown pack"
    );
    assert_eq!(
        usage(s.args(&[
            "fetch",
            "--model",
            "ghost:1",
            "--registry-url",
            &s.reg.url()
        ])),
        2,
        "not in the lock"
    );
    assert_eq!(usage(s.fetch_args(&["--concurrency", "0"])), 2);
    assert_eq!(usage(s.fetch_args(&["--max-bytes-per-sec", "0"])), 2);
    assert_eq!(usage(s.fetch_args(&["--max-bytes-per-sec", "fast"])), 2);
    let mut no_cache: Vec<String> = ["models", "fetch", "--pack", "p", "--lock", p(&s.lock_path)]
        .iter()
        .map(ToString::to_string)
        .collect();
    no_cache.push("--registry-url".into());
    no_cache.push(s.reg.url());
    assert_eq!(usage(no_cache), 2, "no cache directory");
    let bad_lock = s.dir.path().join("bad.json");
    fs::write(&bad_lock, b"{not json").unwrap();
    let mut a2 = s.fetch_args(&[]);
    let i = a2.iter().position(|x| x == "--lock").unwrap();
    a2[i + 1] = p(&bad_lock).to_string();
    assert_eq!(usage(a2), 2, "malformed lock");
    assert!(
        s.reg.hits().is_empty(),
        "usage errors must not touch the network"
    );

    // 7: a lock that lies about its own contents
    let mut lock: Value = serde_json::from_slice(&fs::read(&s.lock_path).unwrap()).unwrap();
    lock["models"][0]["size_bytes"] = Value::from(1);
    let tampered = s.dir.path().join("tampered.json");
    fs::write(&tampered, lock.to_string()).unwrap();
    let mut a3 = s.fetch_args(&[]);
    let i = a3.iter().position(|x| x == "--lock").unwrap();
    a3[i + 1] = p(&tampered).to_string();
    let out = s.run(&a3);
    assert_eq!(out.code, 7, "{}", out.stderr);

    // 5: the unverified licence; the other model is still fetched
    let out = s.run(&s.fetch_args(&["--json"]));
    assert_eq!(out.code, 5, "{}", out.stderr);
    s.assert_complete(&a);
    let r: Value = serde_json::from_str(&out.stdout).unwrap();
    assert_eq!(r["models_gated"], 1);
    assert!(
        r["errors"][0]
            .as_str()
            .unwrap()
            .contains("--accept-licenses"),
        "{r}"
    );
    // 0 once accepted
    assert_eq!(s.run(&s.fetch_args(&["--accept-licenses"])).code, 0);
    s.assert_complete(&g);
    // 6: offline with nothing cached
    let empty = Setup::new(vec![a.clone()]);
    let out = empty.run(&empty.fetch_args(&["--offline"]));
    assert_eq!(out.code, 6, "{}", out.stderr);
    assert!(empty.reg.hits().is_empty());
    // 0: offline with everything cached
    assert_eq!(
        s.run(&s.fetch_args(&["--offline", "--accept-licenses"]))
            .code,
        0
    );
}

#[test]
fn not_enough_space_is_exit_4_and_writes_nothing() {
    // a model that claims 1.5 TB: more than any free space
    let mut big = synth("whale", "1b", 1000, "Apache-2.0", 5);
    let real = big.model_bytes().len();
    big.manifest = String::from_utf8(big.manifest)
        .unwrap()
        .replacen(&format!("\"size\":{real}"), "\"size\":1500000000000", 1)
        .into_bytes();
    let s = Setup::new(vec![big]);
    let out = s.run(&s.fetch_args(&["--events", "-"]));
    assert_eq!(out.code, 4, "{}", out.stderr);
    let events = json_lines(&out.stdout);
    assert!(
        events
            .iter()
            .any(|e| e["event"] == "error" && e["code"] == "space"),
        "{events:?}"
    );
    assert_eq!(events.last().unwrap()["exit"], 4);
    assert!(
        !s.layout().blobs_dir().exists(),
        "nothing may be written when the preflight fails"
    );
    assert!(s.reg.hits().is_empty());

    // `plan` says the same without a network
    let plan = s.run(&s.args(&["plan", "--pack", "p", "--json"]));
    assert_eq!(plan.code, 4, "{}", plan.stdout);
    let v: Value = serde_json::from_str(&plan.stdout).unwrap();
    assert_eq!(v["fits"], false);
    assert_eq!(v["fits_free"], false);
    assert!(v["missing_bytes"].as_u64().unwrap() >= 1_500_000_000_000);
}

#[test]
fn plan_and_cache_info_report_what_is_there() {
    let a = synth("alpha", "1b", 200 * KIB, "Apache-2.0", 6);
    let g = synth("gated", "1b", 50 * KIB, "unverified", 7);
    let s = Setup::new(vec![a.clone(), g.clone()]);
    // before: plan without a cache (positional env var absent), with one, human and JSON
    let before = s.run(&s.args(&["plan", "--pack", "p", "--json"]));
    assert_eq!(before.code, 0, "{}", before.stderr);
    let v: Value = serde_json::from_str(&before.stdout).unwrap();
    assert_eq!(v["pack"], "p");
    assert_eq!(v["gated_models"], 1);
    assert_eq!(v["present_bytes"], 0);
    assert_eq!(v["models"].as_array().unwrap().len(), 2);
    assert_eq!(v["models"][1]["gated"], true);
    let human = s.run(&s.args(&["plan", "--pack", "p"]));
    assert!(
        human.stdout.contains("needs --accept-licenses") && human.stdout.contains("Fits: yes"),
        "{}",
        human.stdout
    );

    assert_eq!(s.run(&s.fetch_args(&["--accept-licenses"])).code, 0);
    // macOS leaves litter on exFAT volumes
    fs::write(
        s.layout()
            .blobs_dir()
            .join(format!("._sha256-{}", a.model_hex())),
        b"x",
    )
    .unwrap();
    fs::write(s.layout().blobs_dir().join(".DS_Store"), b"x").unwrap();

    let after = s.run(&s.args(&["plan", "--pack", "p", "--accept-licenses", "--json"]));
    let v: Value = serde_json::from_str(&after.stdout).unwrap();
    assert_eq!(v["missing_bytes"], 0);
    assert!(v["models"]
        .as_array()
        .unwrap()
        .iter()
        .all(|m| m["complete"] == true));

    let info = s.run(&s.args(&["cache-info", "--json"]));
    assert_eq!(info.code, 0, "{}", info.stderr);
    let v: Value = serde_json::from_str(&info.stdout).unwrap();
    assert_eq!(v["exists"], true);
    assert_eq!(v["seeded"], true);
    assert_eq!(v["manifests"], 2);
    assert_eq!(v["partials"], 0);
    assert_eq!(v["junk_files"], 2);
    assert_eq!(v["foreign_blob_files"], 0);
    assert_eq!(v["packs"][0]["name"], "p");
    assert_eq!(v["packs"][0]["complete"], true);
    assert_eq!(v["packs"][0]["complete_models"], 2);
    #[cfg(unix)]
    assert!(v["free_bytes"].as_u64().unwrap() > 0);
    let human = s.run(&s.args(&["cache-info"]));
    assert!(
        human.stdout.contains("COMPLETE") && human.stdout.contains("pack p"),
        "{}",
        human.stdout
    );

    // an empty directory: nothing complete
    let fresh = Setup::new(vec![a.clone()]);
    let info = fresh.run(&fresh.args(&["cache-info", "--json"]));
    let v: Value = serde_json::from_str(&info.stdout).unwrap();
    assert_eq!(v["exists"], true);
    assert_eq!(v["seeded"], false);
    assert_eq!(v["packs"][0]["complete"], false);
    assert_eq!(v["packs"][0]["incomplete"][0], "alpha:1b");
}

#[test]
fn a_missing_cache_directory_is_never_created() {
    // an unmounted stick: /Volumes/CI-CACHE does not exist, and must not be conjured up
    let a = synth("alpha", "1b", 60 * KIB, "Apache-2.0", 12);
    let s = Setup::new(vec![a]);
    let missing = s.dir.path().join("not-mounted").join("CI-CACHE");
    let mut args = s.fetch_args(&[]);
    let i = args.iter().position(|x| x == "--cache").unwrap();
    args[i + 1] = p(&missing).to_string();
    let out = s.run(&args);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert!(
        out.stderr.contains("does not exist") && out.stderr.contains("mounted"),
        "{}",
        out.stderr
    );
    assert!(!missing.exists() && !missing.parent().unwrap().exists());
    assert!(s.reg.hits().is_empty());
    // read-only commands cope with it
    let mut args = s.args(&["cache-info", "--json"]);
    let i = args.iter().position(|x| x == "--cache").unwrap();
    args[i + 1] = p(&missing).to_string();
    let out = s.run(&args);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let v: Value = serde_json::from_str(&out.stdout).unwrap();
    assert_eq!(v["exists"], false);
    assert!(!missing.exists());
}

#[test]
fn the_cache_directory_and_registry_can_come_from_the_environment() {
    let a = synth("alpha", "1b", 60 * KIB, "Apache-2.0", 8);
    let s = Setup::new(vec![a.clone()]);
    let cache = s.cache();
    let url = s.reg.url();
    let out = run_cli(
        &["models", "fetch", "--pack", "p", "--lock", p(&s.lock_path)],
        &[("CI_STICK_CACHE", p(&cache)), ("CI_OS_REGISTRY_URL", &url)],
    );
    assert_eq!(out.code, 0, "{}", out.stderr);
    s.assert_complete(&a);
    let info = run_cli(
        &["models", "cache-info", "--lock", p(&s.lock_path), "--json"],
        &[("CI_STICK_CACHE", p(&cache))],
    );
    assert_eq!(info.code, 0);
}

#[test]
fn a_hostile_redirect_never_leaks_into_any_output() {
    let a = synth("alpha", "1b", 100 * KIB, "Apache-2.0", 9);
    let s = Setup::new(vec![a]);
    *s.reg.state.redirect_override.lock().unwrap() =
        Some("http://169.254.169.254/latest/api/token?X-Amz-Signature=SECRETSIG".into());
    let out = s.run(&s.fetch_args(&["--events", "-"]));
    assert_eq!(out.code, 1, "{}", out.stderr);
    let all = format!(
        "{}{}{}",
        out.stdout,
        out.stderr,
        fs::read_to_string(s.layout().status_file()).unwrap()
    );
    assert!(
        !all.contains("SECRETSIG") && !all.contains("X-Amz"),
        "{all}"
    );
    assert!(
        !all.contains("api/token?"),
        "the query string is dropped: {all}"
    );
    assert!(all.contains("network policy"), "{all}");
}

// ---- dying and resuming ------------------------------------------------------------------

fn spawn_fetch(s: &Setup, extra_env: &[(&str, &str)]) -> std::process::Child {
    let args = s.fetch_args(&[]);
    let mut cmd = Command::new(ci_stick_bin());
    cmd.args(&args)
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("CI_STICK_RETRY_BASE_MS", "1")
        .env("CI_STICK_CHUNK_BYTES", "65536")
        .env("CI_STICK_JOURNAL_BYTES", "65536")
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    for (k, v) in extra_env {
        cmd.env(k, v);
    }
    cmd.spawn().expect("spawn ci-stick")
}

fn partial_len(layout: &CacheLayout, hex: &str) -> u64 {
    fs::metadata(layout.partial_path(hex).unwrap()).map_or(0, |m| m.len())
}

#[test]
fn a_killed_download_resumes_where_the_journal_says() {
    let a = synth("alpha", "1b", 1200 * KIB, "Apache-2.0", 10);
    let hex = a.model_hex();
    let s = Setup::new(vec![a.clone()]);
    s.reg
        .state
        .cdn_bps
        .store(400 * KIB as u64, std::sync::atomic::Ordering::Relaxed);
    let mut child = spawn_fetch(&s, &[]);
    let layout = s.layout();
    wait_for(60, "a journal with progress", || {
        read_journal(&layout.journal_path(&hex).unwrap())
            .is_some_and(|j| j.committed >= 128 * KIB as u64)
    });
    child.kill().expect("SIGKILL");
    let status = child.wait().unwrap();
    assert!(!status.success());
    // what the dead process left behind: a partial and a journal that never claims too much
    let j = read_journal(&layout.journal_path(&hex).unwrap()).expect("journal survives a kill");
    assert!(j.committed >= 128 * KIB as u64);
    assert!(
        partial_len(&layout, &hex) >= j.committed,
        "data covers the journal"
    );
    assert!(!layout.blob_path(&hex).unwrap().exists());
    assert!(!layout
        .manifest_path(&["registry.ollama.ai", "library", "alpha", "1b"])
        .unwrap()
        .exists());
    // the same command, at full speed, finishes and asks only for the rest
    s.reg
        .state
        .cdn_bps
        .store(0, std::sync::atomic::Ordering::Relaxed);
    s.reg.clear_hits();
    let out = s.run(&s.fetch_args(&[]));
    assert_eq!(out.code, 0, "{}", out.stderr);
    let first = &s.reg.cdn_ranges(&hex)[0];
    let start: u64 = first
        .trim_start_matches("bytes=")
        .split('-')
        .next()
        .unwrap()
        .parse()
        .unwrap();
    assert!(
        start >= j.committed && start > 0,
        "resumed from {start}, journal said {}",
        j.committed
    );
    s.assert_complete(&a);
}

#[cfg(unix)]
#[test]
fn sigint_stops_gracefully_with_exit_6_and_a_resumable_partial() {
    let a = synth("alpha", "1b", 1200 * KIB, "Apache-2.0", 11);
    let hex = a.model_hex();
    let s = Setup::new(vec![a.clone()]);
    s.reg
        .state
        .cdn_bps
        .store(400 * KIB as u64, std::sync::atomic::Ordering::Relaxed);
    // a long journal interval: only a graceful stop can have written the journal
    let mut child = spawn_fetch(&s, &[("CI_STICK_JOURNAL_BYTES", "67108864")]);
    let layout = s.layout();
    wait_for(60, "some bytes", || {
        partial_len(&layout, &hex) >= 200 * KIB as u64
    });
    assert!(
        read_journal(&layout.journal_path(&hex).unwrap()).is_none(),
        "no journal yet"
    );
    let pid = child.id().to_string();
    assert!(Command::new("kill")
        .args(["-INT", &pid])
        .status()
        .unwrap()
        .success());
    let status = child.wait().unwrap();
    assert_eq!(status.code(), Some(6), "graceful interrupt is exit 6");
    let mut err = String::new();
    std::io::Read::read_to_string(child.stderr.as_mut().unwrap(), &mut err).unwrap();
    assert!(
        err.contains("resume"),
        "tells the user the download resumes: {err}"
    );
    let j = read_journal(&layout.journal_path(&hex).unwrap())
        .expect("the journal is flushed on SIGINT");
    assert!(j.committed >= 128 * KIB as u64);
    let st: Value = serde_json::from_slice(&fs::read(layout.status_file()).unwrap()).unwrap();
    assert_eq!(st["state"], "interrupted");
    // resume
    s.reg
        .state
        .cdn_bps
        .store(0, std::sync::atomic::Ordering::Relaxed);
    s.reg.clear_hits();
    let out = s.run(&s.fetch_args(&[]));
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(
        s.reg.cdn_ranges(&hex)[0].starts_with(&format!("bytes={}-", j.committed)),
        "{:?}",
        s.reg.cdn_ranges(&hex)
    );
    s.assert_complete(&a);
}

#[test]
fn the_real_lock_in_the_repository_parses_and_covers_the_catalog() {
    // Not an exact-equality test (the catalog's size_bytes can lag a re-pushed tag, which is
    // what `models lock --check` reports); it must load, validate and cover every model.
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .unwrap()
        .to_path_buf();
    let lock_path = root.join("core/manifest/model-packs.lock.json");
    let catalog_path = root.join("core/manifest/model-packs.yaml");
    if !lock_path.exists() {
        eprintln!("no committed lock yet; skipping");
        return;
    }
    let lock = ModelLock::load(&lock_path).expect("the committed lock is valid");
    let catalog = ci_stick::packs::PackCatalog::load(&catalog_path).unwrap();
    for pack in &catalog.packs {
        let locked = lock.packs.get(&pack.name).unwrap_or_else(|| {
            panic!(
                "pack {} is not in the lock; run `ci-stick models lock`",
                pack.name
            )
        });
        let wanted: Vec<String> = pack
            .models
            .iter()
            .filter(|m| !m.name.starts_with("hf.co/"))
            .map(|m| m.reference())
            .collect();
        assert_eq!(
            &wanted, locked,
            "pack {} differs between the catalog and the lock",
            pack.name
        );
    }
    let mut drift = Vec::new();
    for pack in &catalog.packs {
        for m in pack.models.iter().filter(|m| !m.name.starts_with("hf.co/")) {
            let l = lock.find_model(&m.reference()).unwrap();
            assert_eq!(l.license, m.license, "{}", m.reference());
            if l.size_bytes != m.size_bytes {
                drift.push(format!(
                    "{}: catalog {} lock {}",
                    m.reference(),
                    m.size_bytes,
                    l.size_bytes
                ));
            }
        }
    }
    if !drift.is_empty() {
        eprintln!("catalog size drift (run `ci-stick models lock --check`): {drift:?}");
    }
    let _ = Duration::ZERO;
}
