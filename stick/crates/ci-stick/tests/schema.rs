//! Keeps the published JSON Schema and example in step with the Rust types, which are
//! the source of truth. (No JSON-Schema validator is needed: we check that the schema
//! names exactly the fields and enum values the types serialise.)

use std::collections::BTreeSet;
use std::path::PathBuf;

use ci_stick::layout::{Filesystem, PartitionRole};
use ci_stick::manifest::{ArtifactKind, Bundle, Platform};
use serde_json::Value;

fn schema_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../schema")
}

fn load_json(name: &str) -> Value {
    let path = schema_dir().join(name);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
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

#[test]
fn example_manifest_matches_rust_types() {
    let path = schema_dir().join("examples/bundle.example.json");
    let bytes = std::fs::read(&path).expect("example exists");
    let bundle = Bundle::parse(&bytes).expect("example parses into the Rust types");
    assert!(bundle.validate().is_empty(), "{:?}", bundle.validate());
    assert_eq!(
        String::from_utf8(bundle.to_canonical_json()).expect("utf-8"),
        String::from_utf8(bytes).expect("utf-8"),
        "example must be in canonical form (as `ci-stick lock` writes it)"
    );
}

#[test]
fn schema_declares_exactly_what_the_types_emit() {
    let schema = load_json("bundle.schema.json");
    let bundle = Bundle::parse(
        &std::fs::read(schema_dir().join("examples/bundle.example.json")).expect("example"),
    )
    .expect("example parses");
    let v = serde_json::to_value(&bundle).expect("serialise");

    assert_eq!(
        schema["properties"]["schema_version"]["const"],
        ci_stick::manifest::SCHEMA_VERSION
    );
    check_object(&schema, "", &[&v]);
    let artifacts: Vec<&Value> = v["artifacts"]
        .as_array()
        .expect("artifacts")
        .iter()
        .collect();
    assert!(
        artifacts.iter().any(|a| a.get("platforms").is_some()),
        "example needs a platform-specific artifact"
    );
    check_object(&schema, "artifact", &artifacts);
    let packs: Vec<&Value> = v["model_packs"].as_array().expect("packs").iter().collect();
    check_object(&schema, "model_pack", &packs);
    let models: Vec<&Value> = packs
        .iter()
        .flat_map(|p| p["models"].as_array().expect("models"))
        .collect();
    check_object(&schema, "model", &models);
    check_object(&schema, "layout", &[&v["layout"]]);
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
