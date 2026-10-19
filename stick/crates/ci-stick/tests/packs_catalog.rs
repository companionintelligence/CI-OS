//! The pack catalog as the `ci-stick` binary shows it: the real `core/manifest/model-packs.yaml`
//! through `models list`, and what the loader says about a catalog that breaks its rules.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn ci_stick(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_ci-stick"))
        .args(args)
        .output()
        .expect("failed to run ci-stick")
}

fn code(o: &Output) -> i32 {
    o.status.code().unwrap_or(-1)
}

fn catalog_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .expect("repo root")
        .join("core/manifest/model-packs.yaml")
}

fn p(path: &Path) -> &str {
    path.to_str().expect("utf-8 path")
}

/// The sticks on the desk report 123,942,731,776 bytes and get a 73 GiB cache. These are the
/// numbers a person sees when they ask what fits.
#[test]
fn models_list_for_the_real_128gb_stick() {
    let catalog = catalog_path();
    let o = ci_stick(&[
        "models",
        "list",
        "--catalog",
        p(&catalog),
        "--device",
        "123942731776",
        "--json",
    ]);
    assert_eq!(code(&o), 0, "{}", String::from_utf8_lossy(&o.stderr));
    let j: serde_json::Value = serde_json::from_slice(&o.stdout).expect("JSON");
    assert_eq!(j["capacity_bytes"], 73u64 * (1 << 30));
    let pack = |name: &str| {
        j["packs"]
            .as_array()
            .expect("packs")
            .iter()
            .find(|x| x["name"] == name)
            .unwrap_or_else(|| panic!("no pack {name}"))
            .clone()
    };

    let core = pack("appliance-core");
    assert_eq!(core["models"], 3);
    assert_eq!(core["size_bytes"], 18_849_446_790u64);
    assert_eq!(core["fits"], true);
    assert_eq!(core["min_ram_gb"], 32, "the flagship model sets the floor");
    assert_eq!(core["min_vram_gb"], 24);

    assert_eq!(pack("stick-128")["models"], 21);
    assert_eq!(pack("stick-128")["fits"], true);
    assert_eq!(pack("stick-128-oci")["models"], 19);
    assert_eq!(pack("stick-128-oci")["fits"], true);
    assert_eq!(
        pack("large")["fits"],
        false,
        "the frontier pack is for bigger sticks"
    );

    // No digest is resolved yet: the table says so for every pack, appliance-core included.
    for x in j["packs"].as_array().unwrap() {
        assert_eq!(x["unresolved_digests"], x["models"], "{}", x["name"]);
    }
}

#[test]
fn a_catalog_that_breaks_its_rules_is_refused_with_exit_2() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let entry = |name: &str, tag: &str, size: u64| {
        format!(
            "      - {{name: {name}, tag: {tag}, digest: null, quantization: Q4_K_M, license: Apache-2.0,\n         size_bytes: {size}, min_ram_gb: 4, min_vram_gb: null, platforms: [linux-x86_64]}}\n"
        )
    };
    let catalog = |models: String| {
        format!(
            "schema_version: 1\nstatus: provisional\npacks:\n  - name: p\n    description: d\n    models:\n{models}"
        )
    };
    let run = |name: &str, text: String| {
        let path = tmp.path().join(format!("{name}.yaml"));
        std::fs::write(&path, text).unwrap();
        ci_stick(&["models", "list", "--catalog", p(&path), "--fits", "1GB"])
    };

    // A Hugging Face model in the hf.co spelling is an ordinary entry.
    let ok = run(
        "hf",
        catalog(entry(
            "hf.co/unsloth/gemma-3-270m-it-GGUF",
            "Q4_K_M",
            253_116_654,
        )),
    );
    assert_eq!(code(&ok), 0, "{}", String::from_utf8_lossy(&ok.stderr));
    assert!(String::from_utf8_lossy(&ok.stdout).contains("PACK"));

    for (what, text, needle) in [
        (
            "a name with a space",
            catalog(entry("\"bad name\"", "1b", 1)),
            "only [A-Za-z0-9_.-]",
        ),
        (
            "a cloud-only tag",
            catalog(entry("gpt-oss", "120b-cloud", 1)),
            "no weights",
        ),
        (
            "an unsupported registry host in the name",
            catalog(entry("registry.example.com/ns/model", "1b", 1)),
            "<namespace>/<model>",
        ),
        (
            "two spellings of one file on a case-insensitive volume",
            catalog(format!(
                "{}{}",
                entry("Gemma3", "1B", 1),
                entry("gemma3", "1b", 1)
            )),
            "differ only by case",
        ),
        (
            "one model listed twice in a pack",
            catalog(format!(
                "{}{}",
                entry("gemma3", "1b", 1),
                entry("gemma3", "1b", 2)
            )),
            "duplicate model",
        ),
    ] {
        let o = run(&what.replace(' ', "-"), text);
        let err = String::from_utf8_lossy(&o.stderr);
        assert_eq!(code(&o), 2, "{what}: {err}");
        assert!(err.contains(needle), "{what}: wanted {needle:?} in {err}");
    }
}
