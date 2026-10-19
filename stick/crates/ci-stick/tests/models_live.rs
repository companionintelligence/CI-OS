//! OPT-IN live smoke test against the real Ollama registry. Skipped (with a note) unless
//! `CI_STICK_LIVE=1`; it downloads `nomic-embed-text:latest`, 274 MB, into a scratch directory
//! under `CI_STICK_LIVE_DIR`. Run it by hand, e.g.:
//!
//! ```text
//! CI_STICK_LIVE=1 CI_STICK_LIVE_DIR=/some/scratch cargo test --test models_live -- --nocapture
//! ```
//!
//! Every other test in this crate works offline.

mod models_support;

use std::fs;
use std::path::Path;

use ci_stick::lockfile::ModelLock;
use models_support::*;

#[test]
fn live_fetch_nomic_embed_text() {
    if std::env::var("CI_STICK_LIVE").as_deref() != Ok("1") {
        eprintln!("skipped: set CI_STICK_LIVE=1 and CI_STICK_LIVE_DIR=<scratch dir> to download nomic-embed-text (274 MB) from registry.ollama.ai");
        return;
    }
    let base = std::env::var("CI_STICK_LIVE_DIR")
        .expect("CI_STICK_LIVE_DIR must name a scratch directory for the download");
    fs::create_dir_all(&base).unwrap();
    let work = tempfile::tempdir_in(&base).unwrap();
    let cache = work.path().join("cache");
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .unwrap();
    let lock_path = root.join("core/manifest/model-packs.lock.json");
    let lock = ModelLock::load(&lock_path).expect("the committed lock");
    let model = lock
        .find_model("nomic-embed-text")
        .expect("nomic-embed-text:latest is in the lock");

    let proxy = std::env::var("HTTPS_PROXY").ok();
    let envs: Vec<(&str, &str)> = proxy.iter().map(|v| ("HTTPS_PROXY", v.as_str())).collect();
    let out = run_cli(
        &[
            "models",
            "fetch",
            "--model",
            "nomic-embed-text",
            "--cache",
            p(&cache),
            "--lock",
            p(&lock_path),
            "--json",
        ],
        &envs,
    );
    assert_eq!(out.code, 0, "{}\n{}", out.stdout, out.stderr);
    let layout = ci_stick::cache::layout::CacheLayout::new(&cache);
    for l in &model.layers {
        let hex = l.digest.trim_start_matches("sha256:");
        let len = fs::metadata(layout.blob_path(hex).unwrap()).unwrap().len();
        assert_eq!(len, l.real_size(), "{}", l.digest);
    }
    let manifest = fs::read(
        layout
            .manifest_path(&[
                "registry.ollama.ai",
                "library",
                "nomic-embed-text",
                "latest",
            ])
            .unwrap(),
    )
    .unwrap();
    assert_eq!(manifest, lock.manifest_bytes(model).unwrap());
    assert!(layout.manifests_v2_dir().is_dir());
    eprintln!("live fetch ok: {}", out.stdout.trim());
}
