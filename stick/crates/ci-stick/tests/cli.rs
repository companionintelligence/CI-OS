//! End-to-end tests of the `ci-stick` binary: build a tiny bundle in a tempdir, sign it
//! with a throwaway key, verify OK, tamper, verify FAIL — checking exit codes and JSON.

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

fn ci_stick(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_ci-stick"))
        .args(args)
        // Never the state directory of the person who runs the tests: their revoked.txt would
        // apply to these bundles.
        .env(
            "CI_STICK_STATE_DIR",
            Path::new(env!("CARGO_TARGET_TMPDIR")).join("state-cli-tests"),
        )
        .env_remove("SOURCE_DATE_EPOCH")
        .output()
        .expect("failed to run ci-stick")
}

fn code(o: &Output) -> i32 {
    o.status.code().unwrap_or(-1)
}

fn stdout_json(o: &Output) -> serde_json::Value {
    serde_json::from_slice(&o.stdout).unwrap_or_else(|e| {
        panic!(
            "stdout is not JSON ({e}):\n{}",
            String::from_utf8_lossy(&o.stdout)
        )
    })
}

fn repo_root() -> &'static Path {
    // stick/crates/ci-stick -> repo root
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .expect("repo root")
}

fn write(root: &Path, rel: &str, data: &[u8]) {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().expect("parent")).expect("mkdir");
    fs::write(p, data).expect("write");
}

fn p(path: &Path) -> &str {
    path.to_str().expect("utf-8 temp path")
}

#[test]
fn sign_verify_tamper_round_trip() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let stage = tmp.path().join("stage");
    write(
        &stage,
        "boot/companion-ubuntu-x86_64.img",
        &vec![0xAB; 3 * 1024 * 1024 + 17],
    );
    write(&stage, "installers/macos-arm64/launcher.pkg", b"pkg");
    write(&stage, "models/blobs/sha256-feed", b"weights");
    write(&stage, "docs/README.txt", b"hello");
    let catalog = repo_root().join("core/manifest/model-packs.yaml");

    // lock
    let o = ci_stick(&[
        "lock",
        p(&stage),
        "--id",
        "fixture",
        "--version",
        "0.1.0",
        "--size",
        "512GB",
        "--packs",
        p(&catalog),
        "--created-at",
        "2026-09-28T00:00:00Z",
        "--json",
    ]);
    assert_eq!(code(&o), 0, "{}", String::from_utf8_lossy(&o.stderr));
    let j = stdout_json(&o);
    assert_eq!(j["artifacts"], 4);
    assert_eq!(j["changed"], true);

    // relock is a no-op
    let o = ci_stick(&["lock", p(&stage), "--json"]);
    assert_eq!(stdout_json(&o)["changed"], false);

    // dev key + sign
    let key = tmp.path().join("test");
    assert_eq!(code(&ci_stick(&["dev", "keygen", "--out", p(&key)])), 0);
    let secret = tmp.path().join("test.key");
    let public = tmp.path().join("test.pub");
    assert_eq!(
        code(&ci_stick(&["dev", "sign", p(&stage), "--key", p(&secret)])),
        0
    );
    // keygen refuses to overwrite an existing secret
    assert_eq!(code(&ci_stick(&["dev", "keygen", "--out", p(&key)])), 2);

    // verify OK (file key and inline hex key)
    let o = ci_stick(&["verify", p(&stage), "--pubkey", p(&public), "--json"]);
    assert_eq!(code(&o), 0, "{}", String::from_utf8_lossy(&o.stdout));
    let j = stdout_json(&o);
    assert_eq!(j["ok"], true);
    assert_eq!(j["signature"]["status"], "valid");
    assert_eq!(j["artifacts_ok"], 4);
    let hex = fs::read_to_string(&public).expect("pub");
    assert_eq!(
        code(&ci_stick(&["verify", p(&stage), "--pubkey", hex.trim()])),
        0
    );

    // doctor with the bundle: quick (sizes) mode passes
    let o = ci_stick(&[
        "doctor",
        "--bundle",
        p(&stage),
        "--pubkey",
        p(&public),
        "--json",
    ]);
    assert_eq!(code(&o), 0, "{}", String::from_utf8_lossy(&o.stdout));
    assert_eq!(stdout_json(&o)["bundle"]["hash_mode"], "sizes-only");

    // tamper with a large artifact without changing its size
    let img = stage.join("boot/companion-ubuntu-x86_64.img");
    let mut data = fs::read(&img).expect("read img");
    data[1_000_000] ^= 0xFF;
    fs::write(&img, &data).expect("write img");
    let o = ci_stick(&["verify", p(&stage), "--pubkey", p(&public), "--json"]);
    assert_eq!(code(&o), 1);
    let j = stdout_json(&o);
    assert_eq!(j["ok"], false);
    assert_eq!(j["errors"][0]["code"], "sha256-mismatch");
    assert_eq!(j["errors"][0]["path"], "boot/companion-ubuntu-x86_64.img");
    // quick doctor can't see same-size tampering; --full can
    assert_eq!(
        code(&ci_stick(&["doctor", "--bundle", p(&stage), "--json"])),
        0
    );
    assert_eq!(
        code(&ci_stick(&[
            "doctor",
            "--bundle",
            p(&stage),
            "--full",
            "--json"
        ])),
        1
    );

    // tamper with the manifest itself -> signature fails, closed
    let manifest = stage.join("bundle.json");
    let text = fs::read_to_string(&manifest).expect("manifest");
    fs::write(&manifest, text.replace("\"0.1.0\"", "\"0.1.1\"")).expect("write manifest");
    let o = ci_stick(&["verify", p(&stage), "--pubkey", p(&public), "--json"]);
    assert_eq!(code(&o), 1);
    assert_eq!(stdout_json(&o)["signature"]["status"], "invalid");

    // missing signature: fails closed; --allow-unsigned warns loudly
    fs::remove_file(stage.join("bundle.json.sig")).expect("rm sig");
    fs::write(&manifest, text).expect("restore manifest");
    fs::write(&img, vec![0xAB; 3 * 1024 * 1024 + 17]).expect("restore img");
    assert_eq!(
        code(&ci_stick(&["verify", p(&stage), "--pubkey", p(&public)])),
        1
    );
    let o = ci_stick(&["verify", p(&stage), "--allow-unsigned"]);
    assert_eq!(code(&o), 0);
    assert!(String::from_utf8_lossy(&o.stderr).contains("WARNING"));
}

#[test]
fn usage_errors_exit_2() {
    let tmp = tempfile::tempdir().expect("tempdir");
    // no key and no --allow-unsigned
    assert_eq!(code(&ci_stick(&["verify", p(tmp.path())])), 2);
    // not a bundle root
    assert_eq!(
        code(&ci_stick(&["verify", p(tmp.path()), "--allow-unsigned"])),
        2
    );
    // bad sizes
    assert_eq!(code(&ci_stick(&["layout", "plan", "--size", "512G"])), 2);
    assert_eq!(code(&ci_stick(&["layout", "plan", "--size", "32GB"])), 2);
    // unknown subcommand
    assert_eq!(code(&ci_stick(&["flash"])), 2);
}

#[test]
fn layout_and_models_json() {
    let o = ci_stick(&["layout", "plan", "--size", "512GB", "--json"]);
    assert_eq!(code(&o), 0);
    let j = stdout_json(&o);
    let labels: Vec<&str> = j["partitions"]
        .as_array()
        .expect("partitions")
        .iter()
        .filter_map(|x| x["label"].as_str())
        .collect();
    assert_eq!(
        labels,
        [
            "CI-EFI",
            "CI-SHARED",
            "CI-BOOT-A",
            "CI-BOOT-B",
            "CI-CACHE",
            "CI-PERSIST"
        ]
    );

    let catalog = repo_root().join("core/manifest/model-packs.yaml");
    let o = ci_stick(&[
        "models",
        "list",
        "--catalog",
        p(&catalog),
        "--fits",
        "10GB",
        "--json",
    ]);
    assert_eq!(code(&o), 0);
    let j = stdout_json(&o);
    let fits: Vec<(String, bool)> = j["packs"]
        .as_array()
        .expect("packs")
        .iter()
        .map(|x| {
            (
                x["name"].as_str().unwrap_or("").to_string(),
                x["fits"] == true,
            )
        })
        .collect();
    assert_eq!(fits[0], ("starter".to_string(), true));
    assert!(fits.iter().any(|(n, f)| n == "large" && !f));
    assert_eq!(j["all_fit"], false);

    let o = ci_stick(&[
        "models",
        "list",
        "--catalog",
        p(&catalog),
        "--device",
        "512GB",
        "--json",
    ]);
    assert_eq!(stdout_json(&o)["all_fit"], true);
}
