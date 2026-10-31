//! `ci-stick flash` / `slot` end to end against a sparse image in a tempdir.
//!
//! Needs gdisk, dosfstools, exfatprogs, e2fsprogs and mtools. When any is missing the
//! tests print a note and pass, so `cargo test` stays green on development machines;
//! CI (and `stick/tests/qemu/run.sh`) has them installed. The QEMU boot test itself is
//! `qemu_boot_harness` below, `#[ignore]`d because it downloads a kernel and boots VMs.

use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use ci_stick::gpt;
use ci_stick::layout;

/// Where the runs of this file that do not name a state directory keep theirs: never the one
/// of the person who runs the tests (their `revoked.txt` would apply to these bundles).
fn scratch_state() -> PathBuf {
    Path::new(env!("CARGO_TARGET_TMPDIR")).join("state-flash-tests")
}

fn ci_stick(args: &[&str]) -> Output {
    ci_stick_in(&scratch_state(), args)
}

fn ci_stick_in(state: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_ci-stick"))
        .args(args)
        .env("CI_STICK_STATE_DIR", state)
        .env_remove("SOURCE_DATE_EPOCH")
        .output()
        .expect("failed to run ci-stick")
}

fn ok(o: &Output) {
    assert_eq!(
        o.status.code(),
        Some(0),
        "stdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
}

fn p(path: &Path) -> &str {
    path.to_str().expect("utf-8 temp path")
}

fn tools_present() -> bool {
    let missing: Vec<&str> = ci_stick::tools::FLASH_TOOLS
        .iter()
        .map(|(t, _)| *t)
        .filter(|t| ci_stick::tools::find(t).is_none())
        .collect();
    if missing.is_empty() {
        return true;
    }
    eprintln!(
        "NOTE: skipping flash test, missing tools: {} (apt-get install gdisk dosfstools exfatprogs e2fsprogs mtools)",
        missing.join(", ")
    );
    false
}

/// A signed bundle with a fake boot image and a fake bootloader.
fn bundle(dir: &Path) -> (PathBuf, PathBuf) {
    bundle_with(dir, &["BOOTX64.EFI"])
}

/// A signed bundle whose efi/ holds these files (each "MZ <name>").
fn bundle_with(dir: &Path, efi: &[&str]) -> (PathBuf, PathBuf) {
    let stage = dir.join("stage");
    fs::create_dir_all(stage.join("boot")).unwrap();
    fs::create_dir_all(stage.join("efi")).unwrap();
    let mut iso = vec![0u8; 3 << 20];
    iso[..5].copy_from_slice(b"CD001");
    iso[(2 << 20) + 7] = 0x5A;
    fs::write(stage.join("boot/test.iso"), &iso).unwrap();
    for f in efi {
        fs::write(stage.join("efi").join(f), format!("MZ {f}")).unwrap();
    }
    ok(&ci_stick(&[
        "lock",
        p(&stage),
        "--id",
        "flash-test",
        "--version",
        "0.0.1",
        "--size",
        "64GB",
        "--created-at",
        "2026-09-28T00:00:00Z",
    ]));
    ok(&ci_stick(&["dev", "keygen", "--out", p(&dir.join("dev"))]));
    ok(&ci_stick(&[
        "dev",
        "sign",
        p(&stage),
        "--key",
        p(&dir.join("dev.key")),
    ]));
    (stage, dir.join("dev.pub"))
}

fn read_at(path: &Path, off: u64, len: usize) -> Vec<u8> {
    let mut f = fs::File::open(path).unwrap();
    f.seek(SeekFrom::Start(off)).unwrap();
    let mut b = vec![0u8; len];
    f.read_exact(&mut b).unwrap();
    b
}

#[test]
fn flash_image_then_switch_slots() {
    if !tools_present() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let (stage, pubkey) = bundle(tmp.path());
    let img = tmp.path().join("stick.img");

    // Dry run: plan printed, nothing written.
    let o = ci_stick(&[
        "flash",
        p(&stage),
        "--pubkey",
        p(&pubkey),
        "--image",
        p(&img),
        "--size",
        "64GB",
        "--dry-run",
    ]);
    ok(&o);
    let plan = String::from_utf8_lossy(&o.stdout);
    for needle in [
        "DRY RUN",
        "CI-PERSIST",
        "\"writable\"",
        "formatted empty",
        "active_slot=A",
    ] {
        assert!(
            plan.contains(needle),
            "{needle:?} missing from plan:\n{plan}"
        );
    }
    assert!(!img.exists());

    let o = ci_stick(&[
        "flash",
        p(&stage),
        "--pubkey",
        p(&pubkey),
        "--image",
        p(&img),
        "--size",
        "64GB",
        "--work-dir",
        p(tmp.path()),
        "--json",
    ]);
    ok(&o);
    let j: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap();
    assert!(j["result"]["checks"].as_array().unwrap().len() >= 7);

    // GPT matches the plan exactly.
    let plan = layout::plan(64_000_000_000).unwrap();
    let mut f = fs::File::open(&img).unwrap();
    assert_eq!(f.metadata().unwrap().len(), 64_000_000_000);
    let g = gpt::read(&mut f, None).unwrap();
    gpt::check_matches_plan(&g, &plan).unwrap();

    // Slot A holds the boot image byte for byte; slot B's header is zero.
    let a = plan.partition(layout::PartitionRole::BootA).unwrap();
    let b = plan.partition(layout::PartitionRole::BootB).unwrap();
    let iso = fs::read(stage.join("boot/test.iso")).unwrap();
    assert_eq!(read_at(&img, a.start_bytes, iso.len()), iso);
    assert!(read_at(&img, b.start_bytes, 1 << 20)
        .iter()
        .all(|&x| x == 0));

    // Filesystem labels: FAT label in the ESP boot sector, ext4 label "writable".
    let esp = plan.partition(layout::PartitionRole::Esp).unwrap();
    let boot_sector = read_at(&img, esp.start_bytes, 512);
    assert_eq!(&boot_sector[71..82], b"CI-EFI     ");
    let persist = plan.partition(layout::PartitionRole::Persist).unwrap();
    let sb = read_at(&img, persist.start_bytes + 1024, 1024);
    assert_eq!(&sb[0x38..0x3A], &[0x53, 0xEF], "ext4 magic");
    assert_eq!(&sb[0x78..0x78 + 8], b"writable");

    // A/B pointer.
    let o = ci_stick(&["slot", "show", "--image", p(&img), "--json"]);
    ok(&o);
    let s: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap();
    assert_eq!(s["active_slot"], "A");
    ok(&ci_stick(&["slot", "set", "B", "--image", p(&img)]));
    let o = ci_stick(&["slot", "show", "--image", p(&img)]);
    ok(&o);
    assert!(String::from_utf8_lossy(&o.stdout).contains("active slot B"));
    // --confirm is a device-only flag.
    let o = ci_stick(&[
        "slot",
        "set",
        "A",
        "--image",
        p(&img),
        "--confirm",
        "/dev/sdb",
    ]);
    assert_eq!(o.status.code(), Some(2));
}

#[test]
fn refuses_tampered_bundle_and_unsafe_targets() {
    let tmp = tempfile::tempdir().unwrap();
    let (stage, pubkey) = bundle(tmp.path());
    let img = tmp.path().join("t.img");

    // Tampered boot image: verification fails (exit 1) and nothing is created.
    let iso = stage.join("boot/test.iso");
    let mut bytes = fs::read(&iso).unwrap();
    bytes[100] ^= 0xFF;
    fs::write(&iso, &bytes).unwrap();
    let o = ci_stick(&[
        "flash",
        p(&stage),
        "--pubkey",
        p(&pubkey),
        "--image",
        p(&img),
        "--size",
        "64GB",
    ]);
    assert_eq!(
        o.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&o.stderr)
    );
    assert!(String::from_utf8_lossy(&o.stderr).contains("sha256"));
    assert!(!img.exists());

    // --allow-unsigned never goes with --device.
    let o = ci_stick(&[
        "flash",
        p(&stage),
        "--allow-unsigned",
        "--device",
        "/dev/null",
        "--dry-run",
    ]);
    assert_eq!(o.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&o.stderr).contains("--allow-unsigned is refused with --device")
    );

    // Restore the bundle so the remaining refusals are about the target, not the bundle.
    bytes[100] ^= 0xFF;
    fs::write(&iso, &bytes).unwrap();

    // A regular file is not a device (and is left alone).
    let fake = tmp.path().join("fake-disk");
    fs::write(&fake, b"precious").unwrap();
    let o = ci_stick(&[
        "flash",
        p(&stage),
        "--pubkey",
        p(&pubkey),
        "--device",
        p(&fake),
        "--confirm",
        p(&fake),
    ]);
    assert_eq!(o.status.code(), Some(2));
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(err.contains("not a block device"), "{err}");
    assert_eq!(fs::read(&fake).unwrap(), b"precious");

    // --image never overwrites a directory, and --slot-b-from/--confirm are image/device-only.
    let o = ci_stick(&[
        "flash",
        p(&stage),
        "--pubkey",
        p(&pubkey),
        "--image",
        p(tmp.path()),
        "--size",
        "64GB",
    ]);
    assert_eq!(o.status.code(), Some(2));
}

/// Read one file out of the image's ESP with mtools (None when it does not exist).
fn esp_file(img: &Path, esp_offset: u64, path: &str, out: &Path) -> Option<Vec<u8>> {
    let _ = fs::remove_file(out);
    let st = Command::new("mcopy")
        .env("MTOOLS_SKIP_CHECK", "1")
        .env("MTOOLSRC", "/dev/null")
        .args([
            "-n",
            "-i",
            &format!("{}@@{esp_offset}", p(img)),
            &format!("::/{path}"),
            p(out),
        ])
        .output()
        .expect("mcopy");
    st.status.success().then(|| fs::read(out).unwrap())
}

#[test]
fn secure_chain_goes_where_shim_and_canonical_grub_look() {
    if !tools_present() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let (stage, pubkey) = bundle_with(tmp.path(), &["shimx64.efi", "grubx64.efi", "mmx64.efi"]);
    let img = tmp.path().join("sb.img");
    let base = [
        "flash",
        p(&stage),
        "--pubkey",
        p(&pubkey),
        "--image",
        p(&img),
        "--size",
        "64GB",
    ];

    let o = ci_stick(&[&base[..], &["--dry-run"]].concat());
    ok(&o);
    let plan = String::from_utf8_lossy(&o.stdout);
    assert!(
        plan.contains("Secure Boot: supported (shim → Canonical GRUB)"),
        "{plan}"
    );
    let o = ci_stick(&["verify", p(&stage), "--pubkey", p(&pubkey)]);
    ok(&o);
    assert!(String::from_utf8_lossy(&o.stdout).contains("Secure Boot: supported"));

    ok(&ci_stick(
        &[&base[..], &["--work-dir", p(tmp.path())]].concat(),
    ));
    let esp = layout::plan(64_000_000_000)
        .unwrap()
        .partition(layout::PartitionRole::Esp)
        .unwrap()
        .start_bytes;
    let out = tmp.path().join("out.bin");
    let get = |path: &str| esp_file(&img, esp, path, &out);
    assert_eq!(get("EFI/BOOT/BOOTX64.EFI").unwrap(), b"MZ shimx64.efi");
    assert_eq!(get("EFI/BOOT/grubx64.efi").unwrap(), b"MZ grubx64.efi");
    assert_eq!(get("EFI/BOOT/mmx64.efi").unwrap(), b"MZ mmx64.efi");
    let cfg = get("EFI/BOOT/grub.cfg").unwrap();
    assert!(String::from_utf8_lossy(&cfg).contains("load_env"));
    assert_eq!(get("EFI/ubuntu/grub.cfg").unwrap(), cfg, "identical copies");
    assert!(get("ci-stick/grubenv").is_some());
    assert!(get("ci-stick/grub.cfg").is_none(), "no dev-chain config");
    assert!(
        get("EFI/BOOT/fbx64.efi").is_none(),
        "never the fallback loader"
    );

    // The slot pointer works the same on a secure-chain stick.
    ok(&ci_stick(&["slot", "set", "B", "--image", p(&img)]));
    let o = ci_stick(&["slot", "show", "--image", p(&img)]);
    assert!(String::from_utf8_lossy(&o.stdout).contains("active slot B"));
}

#[test]
fn lock_refuses_both_chains_and_dev_chain_plan_says_so() {
    let tmp = tempfile::tempdir().unwrap();
    let stage = tmp.path().join("both");
    fs::create_dir_all(stage.join("efi")).unwrap();
    for f in ["shimx64.efi", "grubx64.efi", "mmx64.efi", "BOOTX64.EFI"] {
        fs::write(stage.join("efi").join(f), b"MZ").unwrap();
    }
    let o = ci_stick(&[
        "lock",
        p(&stage),
        "--id",
        "x",
        "--version",
        "1",
        "--size",
        "64GB",
    ]);
    assert_eq!(o.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&o.stderr).contains("both the Secure Boot chain"));

    let (stage, pubkey) = bundle(&tmp.path().join("dev"));
    let o = ci_stick(&[
        "flash",
        p(&stage),
        "--pubkey",
        p(&pubkey),
        "--image",
        p(&tmp.path().join("d.img")),
        "--size",
        "64GB",
        "--dry-run",
    ]);
    ok(&o);
    let plan = String::from_utf8_lossy(&o.stdout);
    assert!(plan.contains("Secure Boot: NOT supported (unsigned development GRUB)"));
    assert!(plan.contains("--allow-unsigned-bootloader"), "{plan}");
}

/// A schema 2 bundle (`sequence`, valid until the end of 2099) with a fake boot image and a fake
/// bootloader, signed with a throw-away key. `relock` moves it to another sequence.
fn bundle_v2(dir: &Path, sequence: &str) -> (PathBuf, PathBuf) {
    let (stage, pubkey) = bundle(dir);
    relock(
        &stage,
        &dir.join("dev.key"),
        sequence,
        "2090-01-01T00:00:00Z",
    );
    (stage, pubkey)
}

fn relock(stage: &Path, key: &Path, sequence: &str, created_at: &str) {
    ok(&ci_stick(&[
        "lock",
        p(stage),
        "--sequence",
        sequence,
        "--created-at",
        created_at,
        "--valid-days",
        "3650",
    ]));
    ok(&ci_stick(&["dev", "sign", p(stage), "--key", p(key)]));
}

#[test]
fn a_written_schema_2_stick_records_its_floor_and_an_older_release_is_refused() {
    if !tools_present() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let state = tmp.path().join("state");
    let (stage, pubkey) = bundle_v2(tmp.path(), "2");
    let img = tmp.path().join("stick.img");
    let flash = |extra: &[&str]| {
        ci_stick_in(
            &state,
            &[
                &[
                    "flash",
                    p(&stage),
                    "--pubkey",
                    p(&pubkey),
                    "--image",
                    p(&img),
                    "--size",
                    "64GB",
                    "--work-dir",
                    p(tmp.path()),
                ][..],
                extra,
            ]
            .concat(),
        )
    };
    let floor = || -> Option<serde_json::Value> {
        let text = fs::read(state.join("floors.json")).ok()?;
        serde_json::from_slice::<serde_json::Value>(&text)
            .ok()
            .map(|f| f["floors"]["flash-test"].clone())
    };

    // A dry run plans and checks, and writes nothing: no image, no floor, no state directory.
    ok(&flash(&["--dry-run"]));
    assert!(!img.exists());
    assert!(!state.exists());

    // A completed write records what it wrote: the sequence and the digest of bundle.json.
    ok(&flash(&[]));
    assert!(img.exists());
    let recorded = floor().expect("the floor of the stick that was written");
    assert_eq!(recorded["sequence"], 2);
    assert_eq!(
        recorded["bundle_sha256"],
        ci_stick::hashing::sha256_hex(&fs::read(stage.join("bundle.json")).unwrap())
    );

    // The very same bytes may be written again.
    ok(&flash(&[]));
    assert_eq!(floor().expect("still there")["sequence"], 2);

    // An older release is refused with nothing written, and the floor stays.
    fs::remove_file(&img).unwrap();
    relock(
        &stage,
        &tmp.path().join("dev.key"),
        "1",
        "2090-01-02T00:00:00Z",
    );
    let o = flash(&[]);
    assert_eq!(
        o.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&o.stderr)
    );
    assert!(String::from_utf8_lossy(&o.stderr).contains("bundle-rollback"));
    assert!(!img.exists());
    assert_eq!(floor().expect("kept")["sequence"], 2);

    // A newer one is written and raises it.
    relock(
        &stage,
        &tmp.path().join("dev.key"),
        "3",
        "2090-01-03T00:00:00Z",
    );
    ok(&flash(&[]));
    assert_eq!(floor().expect("raised")["sequence"], 3);
}

/// The full QEMU boot test (downloads an Ubuntu kernel, boots three VMs). Run with
/// `cargo test -- --ignored qemu_boot_harness` or directly: `stick/tests/qemu/run.sh`.
#[test]
#[ignore]
fn qemu_boot_harness() {
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/qemu/run.sh");
    let status = Command::new(script)
        .env("CI_STICK_BIN", env!("CARGO_BIN_EXE_ci-stick"))
        .status()
        .expect("running tests/qemu/run.sh");
    assert!(
        status.success(),
        "QEMU boot harness failed (see its summary above)"
    );
}
