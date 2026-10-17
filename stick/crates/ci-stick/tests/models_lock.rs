//! `ci-stick models lock` against a mock registry serving the REAL manifests captured from
//! registry.ollama.ai on 2026-10-17 (tests/fixtures/models): a plain tag, a tag served as a
//! manifest list with an MLX variant first, the 404 on `/manifests/sha256:...`, children
//! fetched as blobs, HEAD digests, `--check` drift and idempotent output.
//!
//! No network: everything is 127.0.0.1.

mod models_support;

use std::fs;
use std::path::{Path, PathBuf};

use ci_stick::lockfile::ModelLock;
use models_support::*;
use serde_json::Value;

fn fixture(rel: &str) -> Vec<u8> {
    let p = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/models")
        .join(rel);
    fs::read(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

const NOMIC: &str = "nomic-embed-text.latest.v2.json";
const NOMIC_MODEL: &str = "sha256:970aa74c0a90ef7482477cf803618e776e173c007bf957f635f1015bfcfef0e6";
const QWEN_CHILD: &str = "sha256:bcbdbd4bcf86f2c4a56cd1698fb31f9434f7dd99752f71b636c750aaa67a49a5";
const QWEN_LIST: &str = "sha256:1e2b3d172b7cfced5b38fed0f2fd2b133dc43cd4ee78ea1035fb0aa90acc8685";

/// A mock registry holding `nomic-embed-text:latest` and `qwen3.6:27b` as captured.
fn real_registry() -> MockRegistry {
    let reg = MockRegistry::start();
    reg.add_manifest(
        "library/nomic-embed-text:latest",
        &fixture(&format!("manifests/{NOMIC}")),
        None,
    );
    for h in [
        "31df23ea7daa448f9ccdbbcecce6c14689c8552222b80defd3830707c0139d4f",
        "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
        "ce4a164fc04605703b485251fe9f1a181688ba0eb6badb80cc6335c0de17ca0d",
        "370b24c023f51e75e7f3b70e1b89d59a38ec2fb5af3289fcf92ff78b3fadd619",
        "5f3a3c817e78f5b8a4ad2d2c458a3e4b2cce470d6c12642c4eeb12cb8a9bf51d",
        "3f3289008cd00add7198019000e37526b44b1fb3f2bd340b0d411a25fb17838c",
    ] {
        let bytes = fixture(&format!("blobs/{h}"));
        assert_eq!(hex_of(&bytes), h, "fixture {h} is not what its name says");
        reg.add_blob(&bytes);
    }
    // the big layers exist only as lengths: HEAD answers, GET would fail
    reg.add_virtual_blob(NOMIC_MODEL, 274_290_656);
    reg.add_virtual_blob(
        "sha256:415aad607fc297a2ad84cda238febbde295f49f17c17ad7784e2246060fb06d0",
        16_837_919_680,
    );
    reg.add_virtual_blob(
        "sha256:c24919d9eb66eda0af3d7a62ef49bef7948389099de880e0cb5eefe2d3c31769",
        931_145_568,
    );
    // qwen3.6:27b: plain Accept -> the llama.cpp child; Ollama's Accept -> the list; the child is also a blob
    let child = fixture("manifests/qwen3.6.27b.child-llamacpp.json");
    assert_eq!(digest_of(&child), QWEN_CHILD);
    let list = fixture("manifests/qwen3.6.27b.list-accept.json");
    assert_eq!(digest_of(&list), QWEN_LIST);
    reg.add_manifest("library/qwen3.6:27b", &child, Some(&list));
    reg.add_blob(&child);
    reg
}

fn yaml(models: &[(&str, &str, &str, u64)], packs: &[(&str, &[usize])]) -> String {
    let mut s = String::from("schema_version: 1\nstatus: provisional\npacks:\n");
    for (pack, idx) in packs {
        s.push_str(&format!(
            "  - name: {pack}\n    description: test\n    models:\n"
        ));
        for i in *idx {
            let (name, tag, license, size) = models[*i];
            s.push_str(&format!(
                "      - {{name: {name}, tag: \"{tag}\", digest: null, quantization: Q4_K_M, license: \"{license}\", size_bytes: {size}, min_ram_gb: 2, min_vram_gb: null, platforms: [linux-x86_64]}}\n"
            ));
        }
    }
    s
}

struct Work {
    _dir: tempfile::TempDir,
    catalog: PathBuf,
    lock: PathBuf,
}

fn work(models: &[(&str, &str, &str, u64)], packs: &[(&str, &[usize])]) -> Work {
    let dir = tempfile::tempdir().unwrap();
    let catalog = dir.path().join("model-packs.yaml");
    fs::write(&catalog, yaml(models, packs)).unwrap();
    let lock = dir.path().join("model-packs.lock.json");
    Work {
        _dir: dir,
        catalog,
        lock,
    }
}

const REAL_MODELS: [(&str, &str, &str, u64); 2] = [
    ("nomic-embed-text", "latest", "Apache-2.0", 274_302_450),
    ("qwen3.6", "27b", "Apache-2.0", 17_769_076_933),
];

fn lock_args<'a>(w: &'a Work, reg: &'a MockRegistry, extra: &[&'a str]) -> Vec<String> {
    let mut v: Vec<String> = [
        "models",
        "lock",
        "--packs",
        p(&w.catalog),
        "--out",
        p(&w.lock),
        "--registry-url",
    ]
    .iter()
    .map(ToString::to_string)
    .collect();
    v.push(reg.url());
    v.extend(extra.iter().map(ToString::to_string));
    v
}

fn run(args: &[String], envs: &[(&str, &str)]) -> CliRun {
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    run_cli(&refs, envs)
}

#[test]
fn locks_real_manifests_and_matches_the_golden_file() {
    let reg = real_registry();
    let w = work(&REAL_MODELS, &[("starter", &[0]), ("big", &[0, 1])]);
    let out = run(
        &lock_args(&w, &reg, &[]),
        &[("SOURCE_DATE_EPOCH", "1790000000")],
    );
    assert_eq!(out.code, 0, "stderr: {}", out.stderr);
    assert!(out.stdout.contains("wrote"), "{}", out.stdout);

    let bytes = fs::read(&w.lock).unwrap();
    let lock = ModelLock::parse(&bytes).expect("the produced lock validates");
    assert_eq!(lock.models.len(), 2);
    assert_eq!(lock.packs["starter"], ["nomic-embed-text:latest"]);
    assert_eq!(
        lock.packs["big"],
        ["nomic-embed-text:latest", "qwen3.6:27b"]
    );

    let nomic = lock.model("nomic-embed-text:latest").unwrap();
    assert_eq!(
        nomic.size_bytes, 274_302_450,
        "same figure as model-packs.yaml"
    );
    assert!(nomic.list_digest.is_none());
    assert_eq!(
        nomic.manifest.digest,
        digest_of(&fixture(&format!("manifests/{NOMIC}")))
    );
    assert_eq!(nomic.quant.as_deref(), Some("F16"));
    assert_eq!(nomic.push_time, Some(1_790_000_000));

    // the list-served tag: pinned twice, and the named manifest is the llama.cpp child
    let qwen = lock.model("qwen3.6:27b").unwrap();
    assert_eq!(qwen.list_digest.as_deref(), Some(QWEN_LIST));
    assert_eq!(qwen.manifest.digest, QWEN_CHILD);
    assert_eq!(qwen.manifest.runner.as_deref(), Some("llamacpp"));
    assert_eq!(qwen.manifest.format.as_deref(), Some("gguf"));
    assert_eq!(qwen.size_bytes, 17_769_076_933);
    assert_eq!(qwen.requires_ollama.as_deref(), Some("0.30.0"));
    assert_eq!(qwen.quant.as_deref(), Some("Q4_K_M"));
    let roles: Vec<&str> = qwen.layers.iter().map(|l| l.role.as_str()).collect();
    assert_eq!(roles, ["config", "model", "projector", "license", "params"]);
    assert_eq!(
        lock.blobs_inline.len(),
        6,
        "config + licence + params for each model"
    );
    assert_eq!(lock.tag_digest_of("qwen3.6:27b"), QWEN_LIST);

    // the registry was asked the way Ollama asks, and never for a manifest by digest
    let hits = reg.hits();
    assert!(hits.iter().all(|h| !h.path.contains("/manifests/sha256:")));
    assert!(hits
        .iter()
        .any(|h| h.method == "HEAD" && h.path.ends_with("/manifests/27b")));
    assert!(
        hits.iter()
            .any(|h| h.path.ends_with(&format!("/blobs/{QWEN_CHILD}"))),
        "child fetched as a blob"
    );

    // byte-for-byte golden (the mock's port is the only thing that varies between runs)
    let mut normalised = lock.clone();
    normalised.registry = "https://registry.ollama.ai".to_string();
    normalised.tool = "ci-stick".to_string();
    let bytes = normalised.to_canonical_json();
    let golden =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/models/golden.lock.json");
    if std::env::var_os("CI_STICK_BLESS").is_some() {
        fs::write(&golden, &bytes).unwrap();
    }
    let want = fs::read(&golden)
        .expect("tests/fixtures/models/golden.lock.json (re-create with CI_STICK_BLESS=1)");
    assert_eq!(
        String::from_utf8_lossy(&bytes),
        String::from_utf8_lossy(&want),
        "the lock differs from the golden file (set CI_STICK_BLESS=1 to accept)"
    );
}

#[test]
fn relocking_changes_nothing_and_check_passes() {
    let reg = real_registry();
    let w = work(&REAL_MODELS, &[("p", &[0, 1])]);
    assert_eq!(
        run(
            &lock_args(&w, &reg, &[]),
            &[("SOURCE_DATE_EPOCH", "1790000000")]
        )
        .code,
        0
    );
    let first = fs::read(&w.lock).unwrap();
    // a later run (different clock) leaves the file byte-identical
    let again = run(
        &lock_args(&w, &reg, &[]),
        &[("SOURCE_DATE_EPOCH", "1800000000")],
    );
    assert_eq!(again.code, 0, "{}", again.stderr);
    assert!(again.stdout.contains("unchanged"), "{}", again.stdout);
    assert_eq!(fs::read(&w.lock).unwrap(), first);
    // --check: one HEAD per model, no drift, nothing written
    let check = run(&lock_args(&w, &reg, &["--check", "--json"]), &[]);
    assert_eq!(check.code, 0, "{} {}", check.stdout, check.stderr);
    let v: Value = serde_json::from_str(&check.stdout).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(v["models_checked"], 2);
    assert_eq!(fs::read(&w.lock).unwrap(), first);
}

#[test]
fn check_exits_3_when_the_tag_moved() {
    let reg = real_registry();
    let w = work(&REAL_MODELS, &[("p", &[0, 1])]);
    assert_eq!(run(&lock_args(&w, &reg, &[]), &[]).code, 0);
    // somebody re-pushes the tag: HEAD now reports another digest
    *reg.state.head_digest_override.lock().unwrap() = Some("f".repeat(64));
    let check = run(&lock_args(&w, &reg, &["--check", "--json"]), &[]);
    assert_eq!(check.code, 3, "{} {}", check.stdout, check.stderr);
    let v: Value = serde_json::from_str(&check.stdout).unwrap();
    assert_eq!(v["ok"], false);
    let kinds: Vec<&str> = v["drift"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["kind"].as_str().unwrap())
        .collect();
    assert!(kinds.iter().all(|k| *k == "registry_changed"), "{kinds:?}");
    assert_eq!(kinds.len(), 2);
    // and the human report names the model and says what to do
    let human = run(&lock_args(&w, &reg, &["--check"]), &[]);
    assert_eq!(human.code, 3);
    assert!(
        human.stdout.contains("DRIFT") && human.stdout.contains("qwen3.6:27b"),
        "{}",
        human.stdout
    );
}

#[test]
fn check_exits_3_when_the_catalog_and_lock_disagree() {
    let reg = real_registry();
    let w = work(&REAL_MODELS, &[("p", &[0, 1])]);
    assert_eq!(run(&lock_args(&w, &reg, &[]), &[]).code, 0);
    // the catalog's size_bytes goes stale, a model is added, the licence changes
    let mut models = REAL_MODELS.to_vec();
    models[0].3 += 1;
    models[1].2 = "unverified";
    fs::write(&w.catalog, yaml(&models, &[("p", &[0, 1])])).unwrap();
    let check = run(&lock_args(&w, &reg, &["--check", "--json"]), &[]);
    assert_eq!(check.code, 3, "{}", check.stdout);
    let v: Value = serde_json::from_str(&check.stdout).unwrap();
    let kinds: Vec<&str> = v["drift"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["kind"].as_str().unwrap())
        .collect();
    assert!(
        kinds.contains(&"size_mismatch") && kinds.contains(&"license_mismatch"),
        "{kinds:?}"
    );
    // a model in the catalog without a lock entry, and a stale lock entry
    let w2 = work(&REAL_MODELS, &[("p", &[0])]);
    fs::copy(&w.lock, &w2.lock).unwrap();
    let check = run(&lock_args(&w2, &reg, &["--check", "--json"]), &[]);
    assert_eq!(check.code, 3);
    let v: Value = serde_json::from_str(&check.stdout).unwrap();
    let kinds: Vec<&str> = v["drift"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["kind"].as_str().unwrap())
        .collect();
    assert!(
        kinds.contains(&"stale_in_lock") && kinds.contains(&"packs_mismatch"),
        "{kinds:?}"
    );
}

#[test]
fn reports_catalog_size_drift_like_glm_ocr() {
    let reg = real_registry();
    let mut models = REAL_MODELS.to_vec();
    models[0].3 = 100; // the catalog is behind the registry
    let w = work(&models, &[("p", &[0, 1])]);
    let out = run(&lock_args(&w, &reg, &["--json"]), &[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let v: Value = serde_json::from_str(&out.stdout).unwrap();
    let drift = v["size_drift"].as_array().unwrap();
    assert_eq!(drift.len(), 1);
    assert_eq!(drift[0]["model"], "nomic-embed-text:latest");
    assert_eq!(drift[0]["delta"], 274_302_450 - 100);
}

#[test]
fn survives_transient_registry_errors() {
    let reg = real_registry();
    for _ in 0..2 {
        reg.registry_fault(Fault::Status {
            code: 503,
            retry_after: None,
        });
    }
    reg.registry_fault(Fault::Status {
        code: 429,
        retry_after: Some(0),
    });
    let w = work(&REAL_MODELS[..1], &[("p", &[0])]);
    let out = run(&lock_args(&w, &reg, &[]), &[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(w.lock.exists());
}

#[test]
fn records_a_blob_length_the_manifest_gets_wrong() {
    // qwen3-coder:30b on the real registry declares its config as 539 bytes; the blob has 542.
    let mut s = synth("skewed", "1b", 3000, "Apache-2.0", 5);
    let config = s.layers[0].2.clone();
    let wrong = config.len() - 3;
    s.manifest = String::from_utf8(s.manifest.clone())
        .unwrap()
        .replacen(
            &format!("\"size\":{}", config.len()),
            &format!("\"size\":{wrong}"),
            1,
        )
        .into_bytes();
    let reg = MockRegistry::start();
    reg.add_model(&s);
    // and the big layer is served with another length than declared
    let hex = s.model_hex();
    reg.state.size_override.lock().unwrap().insert(hex, 3001);
    let w = work(&[("skewed", "1b", "Apache-2.0", 3000)], &[("p", &[0])]);
    let out = run(&lock_args(&w, &reg, &["--json"]), &[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let v: Value = serde_json::from_str(&out.stdout).unwrap();
    let warnings: Vec<&str> = v["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w.as_str().unwrap())
        .collect();
    assert!(
        warnings
            .iter()
            .any(|w| w.contains("539") || w.contains("declares") && w.contains("(config)")),
        "{warnings:?}"
    );
    assert!(
        warnings
            .iter()
            .any(|w| w.contains("(model)") && w.contains("serves 3001")),
        "{warnings:?}"
    );
    let lock = ModelLock::parse(&fs::read(&w.lock).unwrap()).unwrap();
    let m = lock.model("skewed:1b").unwrap();
    assert_eq!(m.layers[0].size as usize, wrong);
    assert_eq!(m.layers[0].actual, Some(config.len() as u64));
    assert_eq!(m.layers[1].actual, Some(3001));
    assert_eq!(m.layers[1].real_size(), 3001);
    assert_eq!(
        m.size_bytes as usize,
        wrong + 3000 + s.layers[2].2.len() + s.layers[3].2.len(),
        "size_bytes stays the manifest's figure"
    );
}

#[test]
fn refuses_what_a_gguf_stick_cannot_carry() {
    // a safetensors/tensor model
    let mut s = synth("tensor", "1b", 100, "Apache-2.0", 6);
    s.manifest = String::from_utf8(s.manifest)
        .unwrap()
        .replace(MT_MODEL, "application/vnd.ollama.image.tensor")
        .into_bytes();
    let reg = MockRegistry::start();
    reg.add_model(&s);
    let w = work(&[("tensor", "1b", "Apache-2.0", 100)], &[("p", &[0])]);
    let out = run(&lock_args(&w, &reg, &[]), &[]);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stderr.contains("not carried"), "{}", out.stderr);
    assert!(!w.lock.exists(), "no partial lock is written");

    // a list without a llama.cpp variant
    let reg = MockRegistry::start();
    let only_mlx = format!(
        r#"{{"schemaVersion":2,"mediaType":"{MT_LIST}","manifests":[{{"mediaType":"{MT_MANIFEST}","digest":"sha256:{}","runner":"mlx","format":"safetensors"}}]}}"#,
        "a".repeat(64)
    );
    reg.add_manifest(
        "library/mlxonly:1b",
        only_mlx.as_bytes(),
        Some(only_mlx.as_bytes()),
    );
    let w = work(&[("mlxonly", "1b", "Apache-2.0", 100)], &[("p", &[0])]);
    let out = run(&lock_args(&w, &reg, &[]), &[]);
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("llama.cpp/GGUF"), "{}", out.stderr);

    // a child whose bytes do not hash to the digest the list promised
    let reg = MockRegistry::start();
    let real_child = fixture("manifests/qwen3.6.27b.child-llamacpp.json");
    let list = fixture("manifests/qwen3.6.27b.list-accept.json");
    reg.add_manifest("library/qwen3.6:27b", &real_child, Some(&list));
    let mut tampered = real_child.clone();
    tampered[20] ^= 1;
    reg.state.blobs.lock().unwrap().insert(
        QWEN_CHILD.trim_start_matches("sha256:").to_string(),
        std::sync::Arc::new(tampered),
    );
    let w = work(&REAL_MODELS[1..], &[("p", &[0])]);
    let out = run(&lock_args(&w, &reg, &[]), &[]);
    assert_eq!(out.code, 7, "{}", out.stderr);
    assert!(out.stderr.contains("promised"), "{}", out.stderr);
}

#[test]
fn a_tag_that_moves_while_locking_is_an_integrity_failure() {
    let reg = real_registry();
    *reg.state.head_digest_override.lock().unwrap() = Some("e".repeat(64));
    let w = work(&REAL_MODELS[..1], &[("p", &[0])]);
    let out = run(&lock_args(&w, &reg, &[]), &[]);
    assert_eq!(out.code, 7, "{}", out.stderr);
    assert!(out.stderr.contains("moved while locking"), "{}", out.stderr);
}

#[test]
fn hugging_face_entries_are_skipped_with_a_warning_and_conflicting_licences_refused() {
    let reg = real_registry();
    let w = work(
        &[
            REAL_MODELS[0],
            (
                "hf.co/unsloth/inkling-GGUF",
                "UD-Q4_K_XL",
                "Apache-2.0",
                100,
            ),
        ],
        &[("p", &[0, 1])],
    );
    let out = run(&lock_args(&w, &reg, &["--json"]), &[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let v: Value = serde_json::from_str(&out.stdout).unwrap();
    assert!(
        v["warnings"][0].as_str().unwrap().contains("Hugging Face"),
        "{v}"
    );
    let lock = ModelLock::parse(&fs::read(&w.lock).unwrap()).unwrap();
    assert_eq!(lock.models.len(), 1);
    assert_eq!(lock.packs["p"], ["nomic-embed-text:latest"]);

    // the same model with two licences in two packs cannot be locked (the catalog loader refuses it)
    let w = work(
        &[
            REAL_MODELS[0],
            ("nomic-embed-text", "latest", "MIT", 274_302_450),
        ],
        &[("a", &[0]), ("b", &[1])],
    );
    let out = run(&lock_args(&w, &reg, &[]), &[]);
    assert_eq!(out.code, 2, "{}", out.stdout);
    assert!(out.stderr.contains("license"), "{}", out.stderr);
}

#[test]
fn an_unknown_model_is_a_clean_error() {
    let reg = MockRegistry::start();
    let w = work(&[("ghost", "1b", "Apache-2.0", 100)], &[("p", &[0])]);
    let out = run(&lock_args(&w, &reg, &[]), &[]);
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("not found"), "{}", out.stderr);
    assert!(!out.stderr.contains("SECRETSIG"));
}
