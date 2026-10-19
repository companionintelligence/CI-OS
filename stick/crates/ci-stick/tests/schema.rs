//! Keeps the published JSON Schema, the example bundles and the pack catalog in step with the
//! Rust types, which are the source of truth.
//!
//! Two kinds of check live here:
//!
//! - **Shape**: the schema names exactly the fields and enum values the types serialise.
//! - **Values**: `support/minischema.rs` (a std-only validator for the schema's keyword subset)
//!   validates every example bundle and the real `core/manifest/model-packs.yaml` against
//!   `bundle.schema.json`, and a table of mutations (a wrong type, a missing required field, an
//!   unknown key, ...) proves the schema rejects what the Rust types reject, and says where the
//!   two deliberately differ.

use std::collections::BTreeSet;
use std::path::PathBuf;

use ci_stick::layout::{Filesystem, PartitionRole};
use ci_stick::manifest::{
    is_model_digest, validate_packs, ArtifactKind, BootChain, BootloaderRole, Bundle, Model,
    ModelPack, ModelSource, Platform,
};
use ci_stick::packs::{find_catalog, PackCatalog};
use serde_json::{json, Value};

#[path = "support/minischema.rs"]
mod minischema;
use minischema::{Regex, Schema};

fn schema_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../schema")
}

fn load_json(name: &str) -> Value {
    let path = schema_dir().join(name);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// Every bundle example, `schema/examples/bundle*.example.json`, by file name.
fn example_names() -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(schema_dir().join("examples"))
        .expect("examples dir")
        .filter_map(|e| e.ok())
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| n.starts_with("bundle") && n.ends_with(".example.json"))
        .collect();
    names.sort();
    names
}

fn load_example(name: &str) -> Value {
    load_json(&format!("examples/{name}"))
}

/// The example `Bundle::to_canonical_json` is checked against first (a full Secure Boot bundle).
const PRIMARY_EXAMPLE: &str = "bundle.example.json";
/// The example that carries a Hugging Face model and resolved digests.
const HF_EXAMPLE: &str = "bundle-hf-model.example.json";

fn bundle_schema() -> Schema {
    let text = std::fs::read_to_string(schema_dir().join("bundle.schema.json")).expect("schema");
    Schema::parse(&text).unwrap_or_else(|e| panic!("bundle.schema.json: {e}"))
}

fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default()
}

fn strings(v: &Value) -> BTreeSet<String> {
    v.as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

fn def<'a>(schema: &'a Value, name: &str) -> &'a Value {
    if name.is_empty() {
        schema
    } else {
        &schema["$defs"][name]
    }
}

/// Every serialised object of this kind has only schema-declared keys and all required ones.
fn check_object(schema: &Value, def_name: &str, instances: &[&Value]) {
    let d = def(schema, def_name);
    let props = keys(&d["properties"]);
    let required = strings(&d["required"]);
    assert_eq!(
        d["additionalProperties"], false,
        "{def_name}: must be closed"
    );
    assert!(!instances.is_empty(), "{def_name}: no instances to compare");
    let mut seen = BTreeSet::new();
    for inst in instances {
        let k = keys(inst);
        assert!(
            k.is_subset(&props),
            "{def_name}: undeclared keys {:?}",
            k.difference(&props)
        );
        assert!(
            required.is_subset(&k),
            "{def_name}: missing required {:?}",
            required.difference(&k)
        );
        seen.extend(k);
    }
    assert_eq!(
        seen, props,
        "{def_name}: schema declares properties the types never emit (or vice versa)"
    );
}

fn enum_of(schema: &Value, pointer: &str) -> BTreeSet<String> {
    strings(&schema.pointer(pointer).unwrap_or(&Value::Null)["enum"])
}

fn serde_names<T: serde::Serialize>(items: &[T]) -> BTreeSet<String> {
    items
        .iter()
        .map(|i| {
            serde_json::to_value(i)
                .ok()
                .and_then(|v| v.as_str().map(str::to_string))
                .unwrap_or_default()
        })
        .collect()
}

// ---------------------------------------------------------------------------------------
// Shape
// ---------------------------------------------------------------------------------------

#[test]
fn example_manifests_match_rust_types() {
    let names = example_names();
    assert!(
        names.iter().any(|n| n == PRIMARY_EXAMPLE) && names.iter().any(|n| n == HF_EXAMPLE),
        "{names:?}"
    );
    for name in names {
        let path = schema_dir().join("examples").join(&name);
        let bytes = std::fs::read(&path).expect("example exists");
        let bundle = Bundle::parse(&bytes).unwrap_or_else(|e| panic!("{name}: {e:#}"));
        assert!(
            bundle.validate().is_empty(),
            "{name}: {:?}",
            bundle.validate()
        );
        assert_eq!(
            String::from_utf8(bundle.to_canonical_json()).expect("utf-8"),
            String::from_utf8(bytes).expect("utf-8"),
            "{name}: example must be in canonical form (as `ci-stick lock` writes it)"
        );
    }
}

#[test]
fn schema_declares_exactly_what_the_types_emit() {
    let schema = load_json("bundle.schema.json");
    let bundle = Bundle::parse(
        &std::fs::read(schema_dir().join("examples").join(PRIMARY_EXAMPLE)).expect("example"),
    )
    .expect("example parses");
    let v = serde_json::to_value(&bundle).expect("serialise");
    let hf = load_example(HF_EXAMPLE);

    assert_eq!(
        schema["properties"]["schema_version"]["const"],
        ci_stick::manifest::SCHEMA_VERSION
    );
    check_object(&schema, "", &[&v, &hf]);
    let artifacts: Vec<&Value> = v["artifacts"]
        .as_array()
        .expect("artifacts")
        .iter()
        .chain(hf["artifacts"].as_array().expect("artifacts"))
        .collect();
    assert!(
        artifacts.iter().any(|a| a.get("platforms").is_some()),
        "example needs a platform-specific artifact"
    );
    check_object(&schema, "artifact", &artifacts);
    let packs: Vec<&Value> = v["model_packs"]
        .as_array()
        .expect("packs")
        .iter()
        .chain(hf["model_packs"].as_array().expect("packs"))
        .collect();
    check_object(&schema, "model_pack", &packs);
    let models: Vec<&Value> = packs
        .iter()
        .flat_map(|p| p["models"].as_array().expect("models"))
        .collect();
    check_object(&schema, "model", &models);
    check_object(&schema, "layout", &[&v["layout"], &hf["layout"]]);
    let parts: Vec<&Value> = v["layout"]["partitions"]
        .as_array()
        .expect("partitions")
        .iter()
        .collect();
    check_object(&schema, "partition", &parts);

    assert_eq!(
        enum_of(&schema, "/$defs/artifact/properties/kind"),
        serde_names(&ArtifactKind::ALL)
    );
    assert_eq!(
        enum_of(&schema, "/$defs/platform"),
        serde_names(&Platform::ALL)
    );
    assert_eq!(
        enum_of(&schema, "/$defs/host_platform"),
        serde_names(&Platform::HOST)
    );
    assert_eq!(
        schema["$defs"]["model"]["properties"]["platforms"]["items"]["$ref"],
        "#/$defs/host_platform",
        "models run on host platforms only"
    );
    let kinds: BTreeSet<String> = artifacts
        .iter()
        .filter_map(|a| a["kind"].as_str().map(str::to_string))
        .collect();
    assert!(
        kinds.contains("bootloader"),
        "example needs a bootloader artifact"
    );
    assert_eq!(
        enum_of(&schema, "/$defs/bootloader_role"),
        serde_names(&BootloaderRole::ALL)
    );
    assert_eq!(
        bundle.boot_chain(),
        Ok(Some(BootChain::Secure)),
        "the example shows the production (Secure Boot) chain"
    );
    assert_eq!(
        schema["$defs"]["artifact"]["then"]["required"][0], "bootloader_role",
        "the schema requires a role on bootloaders"
    );
    assert_eq!(
        enum_of(&schema, "/$defs/partition/properties/role"),
        serde_names(&[
            PartitionRole::Esp,
            PartitionRole::Shared,
            PartitionRole::BootA,
            PartitionRole::BootB,
            PartitionRole::Cache,
            PartitionRole::Persist
        ])
    );
    assert_eq!(
        enum_of(&schema, "/$defs/partition/properties/filesystem"),
        serde_names(&[
            Filesystem::Vfat,
            Filesystem::Exfat,
            Filesystem::RawImage,
            Filesystem::Ext4
        ])
    );
}

// ---------------------------------------------------------------------------------------
// Values: the examples and the catalog validate against the schema
// ---------------------------------------------------------------------------------------

#[test]
fn the_schema_only_uses_keywords_the_validator_implements() {
    // `Schema::new` fails on an unknown keyword, an unresolved $ref or a pattern outside the
    // supported regex subset, so this is the guard that keeps every other test in this file honest.
    let schema = bundle_schema();
    assert!(
        !schema.validate(&json!({})).is_empty(),
        "an empty object is not a bundle"
    );
}

#[test]
fn every_example_bundle_validates_against_the_schema() {
    let schema = bundle_schema();
    for name in example_names() {
        let errors = schema.validate(&load_example(&name));
        assert!(errors.is_empty(), "{name}:\n  {}", errors.join("\n  "));
    }
}

fn repo_catalog_path() -> PathBuf {
    find_catalog(&PathBuf::from(env!("CARGO_MANIFEST_DIR"))).expect("catalog in repo")
}

/// The raw YAML as JSON: aliases expanded, nothing interpreted by the Rust types, so a typo in a
/// key or a string where a number belongs is seen by the schema, not papered over.
fn catalog_as_json() -> Value {
    let text = std::fs::read_to_string(repo_catalog_path()).expect("catalog");
    serde_yaml::from_str(&text).expect("catalog is YAML")
}

#[test]
fn the_real_pack_catalog_validates_against_the_bundle_schema() {
    let schema = bundle_schema();
    let catalog = catalog_as_json();
    let packs = catalog["packs"].as_array().expect("packs");
    assert!(packs.len() >= 8, "{} packs", packs.len());
    let mut models = 0;
    let mut errors = Vec::new();
    for (i, pack) in packs.iter().enumerate() {
        models += pack["models"].as_array().map_or(0, Vec::len);
        for e in schema.validate_def("model_pack", pack) {
            errors.push(format!("/packs/{i}{e}"));
        }
    }
    assert!(
        errors.is_empty(),
        "model-packs.yaml vs bundle.schema.json:\n  {}",
        errors.join("\n  ")
    );
    assert!(models > 60, "{models} models validated");

    // And the typed form the loader produces serialises to the same valid documents.
    let cat = PackCatalog::load(&repo_catalog_path()).expect("catalog loads");
    for (i, pack) in cat.packs.iter().enumerate() {
        let v = serde_json::to_value(pack).expect("serialise");
        let errors = schema.validate_def("model_pack", &v);
        assert!(errors.is_empty(), "pack {i} ({}): {errors:?}", pack.name);
        assert_eq!(v, packs[i], "typed round trip of pack {}", pack.name);
    }
}

#[test]
fn catalog_mistakes_are_caught_by_the_schema() {
    // Take the real catalog and break one model at a time, as a hand edit could.
    let schema = bundle_schema();
    let catalog = catalog_as_json();
    let pristine = catalog["packs"][0].clone();
    assert!(schema.validate_def("model_pack", &pristine).is_empty());

    type Breakage = (&'static str, fn(&mut Value), &'static str);
    let broken: Vec<Breakage> = vec![
        (
            "typo in a key",
            |p: &mut Value| {
                let m = p["models"][0].as_object_mut().unwrap();
                let v = m.remove("license").unwrap();
                m.insert("licence".into(), v);
            },
            "unknown property \"licence\"",
        ),
        (
            "size written as text",
            |p: &mut Value| p["models"][0]["size_bytes"] = json!("274302450"),
            "/models/0/size_bytes: expected type integer but found string",
        ),
        (
            "size 0",
            |p: &mut Value| p["models"][1]["size_bytes"] = json!(0),
            "/models/1/size_bytes: 0 is below the minimum 1",
        ),
        (
            "unknown platform",
            |p: &mut Value| p["models"][0]["platforms"][0] = json!("plan9-mips"),
            "/models/0/platforms/0",
        ),
        (
            "firmware platform on a model",
            |p: &mut Value| p["models"][0]["platforms"][0] = json!("x86_64-uefi"),
            "/models/0/platforms/0",
        ),
        (
            "hand-typed digest",
            |p: &mut Value| p["models"][2]["digest"] = json!("sha256:1234"),
            "/models/2/digest",
        ),
        (
            "model without a quantization",
            |p: &mut Value| {
                p["models"][3]
                    .as_object_mut()
                    .unwrap()
                    .remove("quantization");
            },
            "missing required property \"quantization\"",
        ),
        (
            "pack without models",
            |p: &mut Value| p["models"] = json!([]),
            "/models: needs at least 1 items",
        ),
    ];
    for (what, mutate, expect) in broken {
        let mut pack = pristine.clone();
        mutate(&mut pack);
        let errors = schema.validate_def("model_pack", &pack).join("\n");
        assert!(
            errors.contains(expect),
            "{what}: wanted {expect:?} in:\n{errors}"
        );
    }
}

#[test]
fn a_hugging_face_model_validates_without_changing_the_record_or_the_version() {
    let schema = bundle_schema();
    let raw = load_json("bundle.schema.json");

    // The Model record is exactly these nine fields, and the format is still version 1.
    let fields = [
        "digest",
        "license",
        "min_ram_gb",
        "min_vram_gb",
        "name",
        "platforms",
        "quantization",
        "size_bytes",
        "tag",
    ];
    let expected: BTreeSet<String> = fields.iter().map(|s| s.to_string()).collect();
    assert_eq!(keys(&raw["$defs"]["model"]["properties"]), expected);
    assert_eq!(strings(&raw["$defs"]["model"]["required"]), expected);
    assert_eq!(raw["properties"]["schema_version"]["const"], 1);
    assert_eq!(ci_stick::manifest::SCHEMA_VERSION, 1);
    // Written without `..`: adding a field to `Model` breaks this test's compilation, so the
    // addition is a deliberate act that also touches the schema, the example and the docs.
    let model = Model {
        name: "hf.co/unsloth/gemma-3-270m-it-GGUF".into(),
        tag: "Q4_K_M".into(),
        digest: None,
        quantization: "Q4_K_M".into(),
        license: "Gemma Terms of Use".into(),
        size_bytes: 253_116_654,
        min_ram_gb: 4,
        min_vram_gb: None,
        platforms: Platform::HOST.to_vec(),
    };

    // A Hugging Face model is a plain record: valid for the schema and for the Rust validator.
    let as_json = serde_json::to_value(&model).unwrap();
    assert_eq!(schema.validate_def("model", &as_json), Vec::<String>::new());
    assert_eq!(model.source(), ModelSource::HuggingFace);
    assert_eq!(
        model.reference(),
        "hf.co/unsloth/gemma-3-270m-it-GGUF:Q4_K_M"
    );
    assert_eq!(model.ref_problem(), None);
    let pack = ModelPack {
        name: "hf-gguf".into(),
        description: "d".into(),
        models: vec![model],
    };
    assert_eq!(validate_packs(&[pack]), Vec::<String>::new());

    // The shipped example has one next to an Ollama-library model, both with resolved digests.
    let example = load_example(HF_EXAMPLE);
    assert_eq!(example["schema_version"], 1);
    let models = example["model_packs"][0]["models"].as_array().unwrap();
    let hf = models
        .iter()
        .find(|m| m["name"].as_str().is_some_and(|n| n.starts_with("hf.co/")))
        .expect("the example has a Hugging Face model");
    assert_eq!(hf["name"], "hf.co/unsloth/gemma-3-270m-it-GGUF");
    assert_eq!(hf["tag"], "Q4_K_M");
    assert!(is_model_digest(hf["digest"].as_str().unwrap()));
    assert!(models
        .iter()
        .any(|m| !m["name"].as_str().unwrap().starts_with("hf.co/") && m["digest"].is_string()));
    // The model digest is the sha256 of the manifest the stick carries for it, and the model
    // layer is stored under its own digest: the one-store layout the lock design relies on.
    let artifacts = example["artifacts"].as_array().unwrap();
    let digest = hf["digest"]
        .as_str()
        .unwrap()
        .strip_prefix("sha256:")
        .unwrap();
    let manifest = artifacts
        .iter()
        .find(|a| a["path"] == "models/manifests/hf.co/unsloth/gemma-3-270m-it-GGUF/Q4_K_M")
        .expect("manifest artifact");
    assert_eq!(manifest["sha256"], digest);
    for a in artifacts
        .iter()
        .filter(|a| a["path"].as_str().unwrap().starts_with("models/blobs/"))
    {
        assert_eq!(
            a["path"].as_str().unwrap(),
            format!("models/blobs/sha256-{}", a["sha256"].as_str().unwrap()),
            "blobs are named by their own digest"
        );
    }
}

// ---------------------------------------------------------------------------------------
// Mutations: the schema rejects what the Rust types reject
// ---------------------------------------------------------------------------------------

/// What the Rust side does with the same mutated document.
enum Rust {
    /// `Bundle::parse` fails (a wrong type, a missing field, an unknown key, an unknown enum value).
    Parse,
    /// It parses but `Bundle::validate` reports a problem.
    Validate,
    /// A known gap: the schema is stricter than the Rust reader, which accepts the document. The
    /// text says why. If Rust ever starts rejecting it the row must move to `Parse`/`Validate`.
    Gap(&'static str),
}

struct Case {
    name: &'static str,
    /// Only the primary example has a bootloader.
    primary_only: bool,
    mutate: fn(&mut Value),
    /// Text that must appear in the schema's errors.
    schema: &'static str,
    rust: Rust,
}

fn set(v: &mut Value, pointer: &str, new: Value) {
    *v.pointer_mut(pointer)
        .unwrap_or_else(|| panic!("no {pointer}")) = new;
}

fn remove(v: &mut Value, pointer: &str) {
    let (parent, key) = pointer.rsplit_once('/').expect("pointer");
    v.pointer_mut(parent)
        .and_then(Value::as_object_mut)
        .unwrap_or_else(|| panic!("no object at {parent}"))
        .remove(key)
        .unwrap_or_else(|| panic!("no key at {pointer}"));
}

fn add(v: &mut Value, parent: &str, key: &str, new: Value) {
    let target = if parent.is_empty() {
        Some(&mut *v)
    } else {
        v.pointer_mut(parent)
    };
    target
        .and_then(Value::as_object_mut)
        .unwrap_or_else(|| panic!("no object at {parent}"))
        .insert(key.into(), new);
}

fn bootloader_index(v: &Value) -> usize {
    v["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .position(|a| a["kind"] == "bootloader")
        .expect("a bootloader artifact")
}

const M0: &str = "/model_packs/0/models/0";
const UPPER_DIGEST: &str =
    "sha256:ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789";

fn cases() -> Vec<Case> {
    macro_rules! case {
        ($name:expr, $schema:expr, $rust:expr, $mutate:expr) => {
            Case {
                name: $name,
                primary_only: false,
                mutate: $mutate,
                schema: $schema,
                rust: $rust,
            }
        };
        (primary $name:expr, $schema:expr, $rust:expr, $mutate:expr) => {
            Case {
                name: $name,
                primary_only: true,
                mutate: $mutate,
                schema: $schema,
                rust: $rust,
            }
        };
    }
    vec![
        // ---- a wrong type ----
        case!(
            "model size_bytes as a string",
            "/model_packs/0/models/0/size_bytes: expected type integer but found string",
            Rust::Parse,
            |d| set(d, &format!("{M0}/size_bytes"), json!("274302450"))
        ),
        case!(
            "model size_bytes as a float",
            "expected type integer but found number",
            Rust::Parse,
            |d| set(d, &format!("{M0}/size_bytes"), json!(1.5))
        ),
        case!(
            "model min_ram_gb negative",
            "is below the minimum 0",
            Rust::Parse,
            |d| set(d, &format!("{M0}/min_ram_gb"), json!(-1))
        ),
        case!(
            "model min_vram_gb as a string",
            "/min_vram_gb: expected type integer|null but found string",
            Rust::Parse,
            |d| set(d, &format!("{M0}/min_vram_gb"), json!("24"))
        ),
        case!(
            "model digest as a number",
            "/digest: expected type string|null but found integer",
            Rust::Parse,
            |d| set(d, &format!("{M0}/digest"), json!(5))
        ),
        case!(
            "model platforms as a string",
            "/platforms: expected type array but found string",
            Rust::Parse,
            |d| set(d, &format!("{M0}/platforms"), json!("linux-x86_64"))
        ),
        case!(
            "pack name as a number",
            "/model_packs/0/name: expected type string but found integer",
            Rust::Parse,
            |d| set(d, "/model_packs/0/name", json!(7))
        ),
        case!(
            "artifact size negative",
            "/size: -1 is below the minimum 0",
            Rust::Parse,
            |d| set(d, "/artifacts/0/size", json!(-1))
        ),
        case!(
            "artifacts as an object",
            "/artifacts: expected type array but found object",
            Rust::Parse,
            |d| set(d, "/artifacts", json!({}))
        ),
        case!(
            "schema_version as a string",
            "/schema_version: must equal 1",
            Rust::Parse,
            |d| set(d, "/schema_version", json!("1"))
        ),
        // ---- values the type allows and the schema bounds ----
        case!(
            "model size_bytes zero",
            "is below the minimum 1",
            Rust::Validate,
            |d| set(d, &format!("{M0}/size_bytes"), json!(0))
        ),
        case!(
            "digest with the wrong algorithm",
            "/digest: \"md5:",
            Rust::Validate,
            |d| set(
                d,
                &format!("{M0}/digest"),
                json!("md5:0123456789abcdef0123456789abcdef")
            )
        ),
        case!(
            "digest with uppercase hex",
            "/digest: \"sha256:ABCDEF",
            Rust::Validate,
            |d| set(d, &format!("{M0}/digest"), json!(UPPER_DIGEST))
        ),
        case!(
            "digest too short",
            "/digest: \"sha256:1234\"",
            Rust::Validate,
            |d| set(d, &format!("{M0}/digest"), json!("sha256:1234"))
        ),
        case!(
            "model name empty",
            "/name: shorter than 1 characters",
            Rust::Validate,
            |d| set(d, &format!("{M0}/name"), json!(""))
        ),
        case!(
            "model tag empty",
            "/tag: shorter than 1 characters",
            Rust::Validate,
            |d| set(d, &format!("{M0}/tag"), json!(""))
        ),
        case!(
            "model platforms empty",
            "/platforms: needs at least 1 items",
            Rust::Validate,
            |d| set(d, &format!("{M0}/platforms"), json!([]))
        ),
        case!(
            "model on a firmware platform",
            "/platforms/0: \"x86_64-uefi\" is not one of",
            Rust::Validate,
            |d| set(d, &format!("{M0}/platforms/0"), json!("x86_64-uefi"))
        ),
        case!(
            "pack without models",
            "/model_packs/0/models: needs at least 1 items",
            Rust::Validate,
            |d| set(d, "/model_packs/0/models", json!([]))
        ),
        case!(
            "pack name not an identifier",
            "/model_packs/0/name: \"Starter Pack\" does not match",
            Rust::Validate,
            |d| set(d, "/model_packs/0/name", json!("Starter Pack"))
        ),
        case!(
            "bundle id not an identifier",
            "/id: \"Companion Stick\" does not match",
            Rust::Validate,
            |d| set(d, "/id", json!("Companion Stick"))
        ),
        case!(
            "bundle version empty",
            "/version: shorter than 1 characters",
            Rust::Validate,
            |d| set(d, "/version", json!(""))
        ),
        case!(
            "created_at not RFC 3339 UTC",
            "/created_at: \"yesterday\" does not match",
            Rust::Validate,
            |d| set(d, "/created_at", json!("yesterday"))
        ),
        case!(
            "created_at with an offset",
            "/created_at: \"2026-10-17T12:00:00+02:00\" does not match",
            Rust::Validate,
            |d| set(d, "/created_at", json!("2026-10-17T12:00:00+02:00"))
        ),
        case!(
            "schema_version 2",
            "/schema_version: must equal 1",
            Rust::Validate,
            |d| set(d, "/schema_version", json!(2))
        ),
        case!(
            "artifact sha256 uppercase",
            "/artifacts/0/sha256",
            Rust::Validate,
            |d| set(
                d,
                "/artifacts/0/sha256",
                json!("ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789")
            )
        ),
        case!(
            "artifact sha256 short",
            "/artifacts/0/sha256",
            Rust::Validate,
            |d| set(d, "/artifacts/0/sha256", json!("abcdef"))
        ),
        case!(
            "artifact path escapes the root",
            "/artifacts/0/path: \"../escape\" does not match",
            Rust::Validate,
            |d| set(d, "/artifacts/0/path", json!("../escape"))
        ),
        case!(
            "artifact path is absolute",
            "/artifacts/0/path: \"/etc/passwd\" does not match",
            Rust::Validate,
            |d| set(d, "/artifacts/0/path", json!("/etc/passwd"))
        ),
        case!(
            "artifact path with an empty component",
            "/artifacts/0/path: \"a//b\" does not match",
            Rust::Validate,
            |d| set(d, "/artifacts/0/path", json!("a//b"))
        ),
        case!(
            "artifact path with a drive colon",
            "/artifacts/0/path: \"C:/x\" does not match",
            Rust::Validate,
            |d| set(d, "/artifacts/0/path", json!("C:/x"))
        ),
        case!(
            "artifact path with a backslash",
            "/artifacts/0/path",
            Rust::Validate,
            |d| set(d, "/artifacts/0/path", json!("a\\b"))
        ),
        case!(
            "artifact path is the manifest itself",
            "matches a schema it must not match",
            Rust::Validate,
            |d| set(d, "/artifacts/0/path", json!("bundle.json"))
        ),
        case!(
            "artifact platforms empty",
            "/artifacts/0/platforms: needs at least 1 items",
            Rust::Validate,
            |d| add(d, "/artifacts/0", "platforms", json!([]))
        ),
        case!(
            "a non-bootloader with a role",
            "matches a schema it must not match",
            Rust::Validate,
            |d| add(d, "/artifacts/0", "bootloader_role", json!("grub"))
        ),
        case!(primary "a bootloader without a role", "missing required property \"bootloader_role\"", Rust::Validate,
        |d| {
            let i = bootloader_index(d);
            remove(d, &format!("/artifacts/{i}/bootloader_role"));
        }),
        case!(
            "layout partition index 0",
            "/layout/partitions/0/index: 0 is below the minimum 1",
            Rust::Validate,
            |d| set(d, "/layout/partitions/0/index", json!(0))
        ),
        case!(
            "layout partition size 0",
            "/layout/partitions/0/size_bytes: 0 is below the minimum 1",
            Rust::Validate,
            |d| set(d, "/layout/partitions/0/size_bytes", json!(0))
        ),
        // ---- a missing required field ----
        case!(
            "model without a license",
            "missing required property \"license\"",
            Rust::Parse,
            |d| remove(d, &format!("{M0}/license"))
        ),
        case!(
            "model without a name",
            "missing required property \"name\"",
            Rust::Parse,
            |d| remove(d, &format!("{M0}/name"))
        ),
        case!(
            "model without platforms",
            "missing required property \"platforms\"",
            Rust::Parse,
            |d| remove(d, &format!("{M0}/platforms"))
        ),
        case!(
            "pack without a description",
            "missing required property \"description\"",
            Rust::Parse,
            |d| remove(d, "/model_packs/0/description")
        ),
        case!(
            "pack without models key",
            "missing required property \"models\"",
            Rust::Parse,
            |d| remove(d, "/model_packs/0/models")
        ),
        case!(
            "artifact without a kind",
            "missing required property \"kind\"",
            Rust::Parse,
            |d| remove(d, "/artifacts/0/kind")
        ),
        case!(
            "bundle without a layout",
            "missing required property \"layout\"",
            Rust::Parse,
            |d| remove(d, "/layout")
        ),
        case!(
            "bundle without model_packs",
            "missing required property \"model_packs\"",
            Rust::Parse,
            |d| remove(d, "/model_packs")
        ),
        case!(
            "layout without partitions",
            "missing required property \"partitions\"",
            Rust::Parse,
            |d| remove(d, "/layout/partitions")
        ),
        case!(
            "model without a digest key",
            "missing required property \"digest\"",
            Rust::Gap(
                "serde reads a missing Option as None; canonical output always writes the key"
            ),
            |d| remove(d, &format!("{M0}/digest"))
        ),
        case!(
            "model without a min_vram_gb key",
            "missing required property \"min_vram_gb\"",
            Rust::Gap(
                "serde reads a missing Option as None; canonical output always writes the key"
            ),
            |d| remove(d, &format!("{M0}/min_vram_gb"))
        ),
        // ---- an unknown key ----
        case!(
            "unknown key on a model",
            "unknown property \"licence\"",
            Rust::Parse,
            |d| add(d, M0, "licence", json!("MIT"))
        ),
        case!(
            "unknown key on a pack",
            "unknown property \"tier\"",
            Rust::Parse,
            |d| add(d, "/model_packs/0", "tier", json!(1))
        ),
        case!(
            "unknown key on an artifact",
            "unknown property \"mode\"",
            Rust::Parse,
            |d| add(d, "/artifacts/0", "mode", json!("0755"))
        ),
        case!(
            "unknown key on the bundle",
            "unknown property \"signature\"",
            Rust::Parse,
            |d| add(d, "", "signature", json!("00"))
        ),
        case!(
            "unknown key on the layout",
            "unknown property \"boot_mode\"",
            Rust::Parse,
            |d| add(d, "/layout", "boot_mode", json!("uefi"))
        ),
        case!(
            "unknown key on a partition",
            "unknown property \"uuid\"",
            Rust::Parse,
            |d| add(d, "/layout/partitions/0", "uuid", json!("x"))
        ),
        // ---- an unknown enum value ----
        case!(
            "model on an unknown platform",
            "/platforms/0: \"plan9-mips\" is not one of",
            Rust::Parse,
            |d| set(d, &format!("{M0}/platforms/0"), json!("plan9-mips"))
        ),
        case!(
            "artifact of an unknown kind",
            "/artifacts/0/kind: \"weights\" is not one of",
            Rust::Parse,
            |d| set(d, "/artifacts/0/kind", json!("weights"))
        ),
        case!(primary "bootloader with an unknown role", "is not one of", Rust::Parse,
        |d| {
            let i = bootloader_index(d);
            set(d, &format!("/artifacts/{i}/bootloader_role"), json!("lilo"));
        }),
        case!(
            "partition with an unknown role",
            "/layout/partitions/0/role: \"boot-c\" is not one of",
            Rust::Parse,
            |d| set(d, "/layout/partitions/0/role", json!("boot-c"))
        ),
        case!(
            "partition with an unknown filesystem",
            "/layout/partitions/0/filesystem: \"ntfs\" is not one of",
            Rust::Parse,
            |d| set(d, "/layout/partitions/0/filesystem", json!("ntfs"))
        ),
        // ---- where the schema is stricter than the Rust reader (documented gaps) ----
        case!(
            "layout table that is not gpt",
            "/layout/table: must equal \"gpt\"",
            Rust::Gap("`table` is a plain String in Rust; only the schema pins it to \"gpt\""),
            |d| set(d, "/layout/table", json!("mbr"))
        ),
        case!(
            "partition gpt_type in lowercase",
            "/layout/partitions/0/gpt_type",
            Rust::Gap("`gpt_type` is a plain String in Rust; only the schema checks its shape"),
            |d| set(
                d,
                "/layout/partitions/0/gpt_type",
                json!("c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
            )
        ),
    ]
}

#[test]
fn the_unmutated_examples_pass_both_validators() {
    // The control for the mutation table: a validator that rejects everything would "pass" it.
    let schema = bundle_schema();
    for name in example_names() {
        let doc = load_example(&name);
        assert_eq!(schema.validate(&doc), Vec::<String>::new(), "{name}");
        let bundle = Bundle::parse(doc.to_string().as_bytes()).expect(&name);
        assert_eq!(bundle.validate(), Vec::<String>::new(), "{name}");
    }
}

#[test]
fn mutated_bundles_are_rejected_by_the_schema_as_the_rust_types_reject_them() {
    let schema = bundle_schema();
    let table = cases();
    assert!(table.len() >= 50, "{} cases", table.len());
    let mut gaps = 0;
    let mut failures = Vec::new();
    for name in example_names() {
        let base = load_example(&name);
        for case in &table {
            if case.primary_only && name != PRIMARY_EXAMPLE {
                continue;
            }
            let mut doc = base.clone();
            (case.mutate)(&mut doc);
            let label = format!("[{name}] {}", case.name);
            if doc == base {
                failures.push(format!("{label}: the mutation changed nothing"));
                continue;
            }

            let errors = schema.validate(&doc);
            let joined = errors.join("\n");
            if errors.is_empty() {
                failures.push(format!("{label}: the schema accepted it"));
            } else if !joined.contains(case.schema) {
                failures.push(format!(
                    "{label}: wanted {:?} in the schema errors:\n{joined}",
                    case.schema
                ));
            }

            let parsed = Bundle::parse(doc.to_string().as_bytes());
            match (&case.rust, parsed) {
                (Rust::Parse, Ok(_)) => {
                    failures.push(format!("{label}: Bundle::parse accepted it"))
                }
                (Rust::Parse, Err(_)) => {}
                (Rust::Validate, Err(e)) => {
                    failures.push(format!(
                        "{label}: Bundle::parse failed, expected validate(): {e:#}"
                    ));
                }
                (Rust::Validate, Ok(b)) => {
                    if b.validate().is_empty() {
                        failures.push(format!("{label}: Bundle::validate accepted it"));
                    }
                }
                (Rust::Gap(_), Err(e)) => {
                    failures.push(format!("{label}: documented gap, but Bundle::parse now rejects it ({e:#}); make it Rust::Parse"));
                }
                (Rust::Gap(why), Ok(b)) => {
                    gaps += 1;
                    if !b.validate().is_empty() {
                        failures.push(format!(
                            "{label}: documented gap ({why}), but Bundle::validate now rejects it; make it Rust::Validate"
                        ));
                    }
                }
            }
        }
    }
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
    assert!(gaps >= 4, "the documented gaps are exercised ({gaps})");
}

// ---------------------------------------------------------------------------------------
// The schema's patterns agree with the Rust predicates they mirror
// ---------------------------------------------------------------------------------------

fn pattern_at(schema: &Value, pointer: &str) -> Regex {
    let p = schema
        .pointer(pointer)
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("no pattern at {pointer}"));
    Regex::new(p).unwrap_or_else(|e| panic!("{pointer}: {e}"))
}

#[test]
fn schema_patterns_agree_with_the_rust_validators() {
    let raw = load_json("bundle.schema.json");

    // artifact sha256: 64 lowercase hex.
    let sha = pattern_at(&raw, "/$defs/sha256/pattern");
    let good = "0123456789abcdef".repeat(4);
    let cases = [
        good.as_str(),
        &good[..63],
        &format!("{good}0"),
        &good.to_uppercase(),
        &format!("{}g", &good[..63]),
        "",
        " ",
    ];
    for s in cases {
        assert_eq!(
            sha.is_match(s),
            ci_stick::hashing::is_sha256_hex(s),
            "sha256 {s:?}"
        );
    }

    // model digest: sha256:<64 lowercase hex>.
    let digest = pattern_at(&raw, "/$defs/model/properties/digest/pattern");
    for s in [
        format!("sha256:{good}"),
        format!("sha256:{}", &good[..63]),
        format!("sha256:{}", good.to_uppercase()),
        format!("sha512:{good}"),
        good.clone(),
        "sha256:".to_string(),
        format!(" sha256:{good}"),
    ] {
        assert_eq!(digest.is_match(&s), is_model_digest(&s), "digest {s:?}");
    }

    // created_at: RFC 3339 UTC, second precision.
    let created = pattern_at(&raw, "/properties/created_at/pattern");
    for s in [
        "2026-10-17T12:00:00Z",
        "2026-10-17T12:00:00",
        "2026-10-17 12:00:00Z",
        "2026-10-17T12:00:00.5Z",
        "2026-10-17T12:00:00+00:00",
        "26-10-17T12:00:00Z",
        "",
    ] {
        assert_eq!(
            created.is_match(s),
            ci_stick::timefmt::is_rfc3339_utc(s),
            "created_at {s:?}"
        );
    }

    // artifact paths: the schema's regex and `paths::validate_rel_path` accept the same strings,
    // except for the two C1 control characters below, which the schema's class does not list.
    let schema = bundle_schema();
    let looser_in_schema = ["a\u{80}b", "a\u{9f}b"];
    for s in [
        "a",
        "boot/x.img",
        "models/blobs/sha256-0123",
        "models/manifests/hf.co/unsloth/gemma-3-270m-it-GGUF/Q4_K_M",
        "a.b/.hidden",
        "a/..b",
        "a/b..",
        "ünï/файл",
        "with space/x y",
        "",
        "/a",
        "a//b",
        "a/",
        "../a",
        "a/..",
        "a/../b",
        ".",
        "./a",
        "a/./b",
        "a\\b",
        "a:b",
        "C:/x",
        "a\u{0}b",
        "a\nb",
        "a\u{7f}b",
        "bundle.json",
        "bundle.json.sig",
        "a\u{80}b",
        "a\u{9f}b",
    ] {
        let schema_ok = schema.validate_def("rel_path", &json!(s)).is_empty();
        let rust_ok = ci_stick::paths::validate_rel_path(s).is_ok();
        if looser_in_schema.contains(&s) {
            assert!(schema_ok && !rust_ok, "documented looseness for {s:?}");
        } else {
            assert_eq!(
                schema_ok, rust_ok,
                "path {s:?}: schema {schema_ok}, rust {rust_ok}"
            );
        }
    }
}
