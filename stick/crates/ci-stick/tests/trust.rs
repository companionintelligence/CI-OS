//! End-to-end tests of the trust controls of the `ci-stick` binary: the sequence floor
//! (rollback), the expiry, a revoked key, and the state directory they live in.
//!
//! Every test points `CI_STICK_STATE_DIR` at its own temporary directory, so nothing here
//! touches the real one. The bundles are built with `lock --created-at ... --valid-days ...`
//! and signed with a throw-away development key, so they expire in 2020 or in 2099 whatever
//! the clock says. This build pins no release key (KI-23), so `--pubkey` names the key.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use ci_stick::signing::{fingerprint, parse_public_key};

fn code(o: &Output) -> i32 {
    o.status.code().unwrap_or(-1)
}

fn stdout_json(o: &Output) -> serde_json::Value {
    serde_json::from_slice(&o.stdout).unwrap_or_else(|e| {
        panic!(
            "stdout is not JSON ({e}):\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&o.stdout),
            String::from_utf8_lossy(&o.stderr)
        )
    })
}

fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

fn p(path: &Path) -> &str {
    path.to_str().expect("utf-8 temp path")
}

/// Valid until the end of 2099.
const FAR: [&str; 4] = [
    "--created-at",
    "2090-01-01T00:00:00Z",
    "--valid-days",
    "3650",
];

struct Fixture {
    _tmp: tempfile::TempDir,
    stage: PathBuf,
    state: PathBuf,
    secret: PathBuf,
    public: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let tmp = tempfile::tempdir().expect("tempdir");
        let stage = tmp.path().join("stage");
        for (rel, data) in [
            ("boot/test.iso", &b"CD001 test image"[..]),
            ("efi/BOOTX64.EFI", b"MZ standalone"),
            ("docs/a.txt", b"a"),
        ] {
            let full = stage.join(rel);
            fs::create_dir_all(full.parent().expect("parent")).expect("mkdir");
            fs::write(full, data).expect("write");
        }
        let fx = Self {
            stage,
            state: tmp.path().join("state"),
            secret: tmp.path().join("dev.key"),
            public: tmp.path().join("dev.pub"),
            _tmp: tmp,
        };
        let o = fx.run(&["dev", "keygen", "--out", p(&fx.secret.with_extension(""))]);
        assert_eq!(code(&o), 0, "{}", stderr(&o));
        fx
    }

    /// Run `ci-stick` with the state directory pointed at this fixture's own.
    fn run(&self, args: &[&str]) -> Output {
        self.run_in(&self.state, args)
    }

    fn run_in(&self, state: &Path, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_ci-stick"))
            .args(args)
            .env("CI_STICK_STATE_DIR", state)
            .env_remove("SOURCE_DATE_EPOCH")
            .output()
            .expect("failed to run ci-stick")
    }

    /// `lock` the staging directory (a new bundle on the first call, an update afterwards).
    fn lock(&self, extra: &[&str]) -> Output {
        let mut args = vec![
            "lock",
            p(&self.stage),
            "--id",
            "trust-test",
            "--version",
            "1.0.0",
            "--size",
            "64GB",
        ];
        args.extend_from_slice(extra);
        let o = self.run(&args);
        assert_eq!(code(&o), 0, "lock {extra:?}: {}", stderr(&o));
        o
    }

    fn sign(&self) {
        let o = self.run(&["dev", "sign", p(&self.stage), "--key", p(&self.secret)]);
        assert_eq!(code(&o), 0, "{}", stderr(&o));
    }

    fn verify(&self) -> Output {
        self.run(&[
            "verify",
            p(&self.stage),
            "--pubkey",
            p(&self.public),
            "--json",
        ])
    }

    /// Lock with these options, sign, and verify.
    fn release(&self, lock_args: &[&str]) -> Output {
        self.lock(lock_args);
        self.sign();
        self.verify()
    }

    fn floors(&self) -> String {
        fs::read_to_string(self.state.join("floors.json")).unwrap_or_default()
    }

    fn fingerprint(&self) -> String {
        fingerprint(&parse_public_key(p(&self.public)).expect("public key"))
    }
}

fn with(far: &[&'static str], more: &[&'static str]) -> Vec<&'static str> {
    far.iter().chain(more).copied().collect()
}

#[test]
fn a_bundle_rebuilt_at_a_lower_sequence_is_refused() {
    let fx = Fixture::new();

    // Sequence 2 is accepted, and the machine remembers it.
    let o = fx.release(&with(&FAR, &["--sequence", "2"]));
    assert_eq!(
        code(&o),
        0,
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        stderr(&o)
    );
    let j = stdout_json(&o);
    assert_eq!(j["ok"], true);
    assert_eq!(j["signature"]["status"], "valid");
    assert_eq!(j["signature"]["sequence"], 2);
    assert_eq!(j["signature"]["expires_at"], "2099-12-30T00:00:00Z");
    let floors: serde_json::Value = serde_json::from_str(&fx.floors()).expect("floors.json");
    assert_eq!(floors["schema"], 1);
    assert_eq!(floors["floors"]["trust-test"]["sequence"], 2);
    assert_eq!(floors["floors"]["trust-test"]["signer"], fx.fingerprint());
    assert_eq!(
        floors["floors"]["trust-test"]["bundle_sha256"]
            .as_str()
            .map(str::len),
        Some(64)
    );

    // The same bundle rebuilt at sequence 1 and signed by the very same key: refused.
    let lock_again = fx.lock(&[
        "--created-at",
        "2090-01-02T00:00:00Z",
        "--valid-days",
        "3650",
        "--sequence",
        "1",
    ]);
    assert!(
        stderr(&lock_again).contains("not greater than"),
        "lock warns when the sequence does not go up: {}",
        stderr(&lock_again)
    );
    fx.sign();
    let o = fx.verify();
    assert_eq!(code(&o), 1, "{}", stderr(&o));
    let j = stdout_json(&o);
    assert_eq!(j["ok"], false);
    assert_eq!(j["errors"][0]["code"], "bundle-rollback");
    assert_eq!(
        j["artifacts_total"], 0,
        "refused before any artifact was hashed"
    );
    assert!(fx.floors().contains("\"sequence\": 2"), "{}", fx.floors());

    // A newer release is accepted and raises the floor.
    let o = fx.release(&[
        "--created-at",
        "2090-01-03T00:00:00Z",
        "--valid-days",
        "3650",
        "--sequence",
        "3",
    ]);
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    assert!(fx.floors().contains("\"sequence\": 3"), "{}", fx.floors());
}

#[test]
fn the_same_bytes_may_be_verified_again_but_other_bytes_may_not_share_a_sequence() {
    let fx = Fixture::new();
    let args = with(&FAR, &["--sequence", "5"]);
    assert_eq!(code(&fx.release(&args)), 0);
    assert_eq!(code(&fx.verify()), 0, "the very same bytes again");

    // Other bytes (a changed document), the same sequence and the same timestamps.
    fs::write(fx.stage.join("docs/a.txt"), b"changed").expect("write");
    let o = fx.release(&args);
    assert_eq!(code(&o), 1);
    assert_eq!(
        stdout_json(&o)["errors"][0]["code"],
        "bundle-sequence-conflict"
    );
}

#[test]
fn an_expired_bundle_is_refused_and_leaves_no_floor() {
    let fx = Fixture::new();
    let o = fx.release(&[
        "--sequence",
        "1",
        "--created-at",
        "2020-01-01T00:00:00Z",
        "--valid-days",
        "30",
    ]);
    assert_eq!(code(&o), 1, "{}", stderr(&o));
    let j = stdout_json(&o);
    assert_eq!(j["errors"][0]["code"], "bundle-expired");
    assert!(
        j["errors"][0]["message"]
            .as_str()
            .is_some_and(|m| m.contains("2020-01-31T00:00:00Z")),
        "{j}"
    );
    assert_eq!(j["artifacts_total"], 0);
    assert!(!fx.state.exists(), "a refused bundle writes nothing");
}

#[test]
fn a_revoked_key_is_refused_and_a_damaged_revocation_file_is_not_ignored() {
    let fx = Fixture::new();
    let args = with(&FAR, &["--sequence", "1"]);
    assert_eq!(code(&fx.release(&args)), 0, "control: the key is good");

    fs::write(
        fx.state.join("revoked.txt"),
        format!("# the dev key of this test\n{}\n", fx.fingerprint()),
    )
    .expect("write revoked.txt");
    let o = fx.verify();
    assert_eq!(code(&o), 1, "{}", stderr(&o));
    let j = stdout_json(&o);
    assert_eq!(j["errors"][0]["code"], "signature-key-revoked");
    assert!(
        j["errors"][0]["message"]
            .as_str()
            .is_some_and(|m| m.contains(&fx.fingerprint())),
        "{j}"
    );
    assert_eq!(j["artifacts_total"], 0);

    // A line that is not a fingerprint must not silently stop a revocation from applying.
    fs::write(
        fx.state.join("revoked.txt"),
        "0123456789abcdef\nnot a fingerprint\n",
    )
    .expect("write revoked.txt");
    let o = fx.verify();
    assert_eq!(code(&o), 2);
    assert!(
        stderr(&o).contains("revoked.txt") && stderr(&o).contains("line 2"),
        "{}",
        stderr(&o)
    );

    // Taking the revocation away makes the same bundle good again.
    fs::remove_file(fx.state.join("revoked.txt")).expect("rm");
    assert_eq!(code(&fx.verify()), 0);
}

#[test]
fn a_schema_1_bundle_still_verifies_and_never_touches_the_state_directory() {
    let fx = Fixture::new();
    let o = fx.release(&["--created-at", "2026-09-28T00:00:00Z"]);
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    let j = stdout_json(&o);
    assert_eq!(j["ok"], true);
    assert!(j["signature"].get("sequence").is_none(), "{j}");
    let manifest = fs::read_to_string(fx.stage.join("bundle.json")).expect("bundle.json");
    assert!(manifest.contains("\"schema_version\": 1"), "{manifest}");
    assert!(!manifest.contains("sequence") && !manifest.contains("expires_at"));
    assert!(!fx.state.exists());
    assert!(
        stderr(&o).contains("no release key is pinned in this build (KI-23)"),
        "{}",
        stderr(&o)
    );
}

#[test]
fn a_damaged_floor_file_is_refused_not_reset() {
    let fx = Fixture::new();
    let args = with(&FAR, &["--sequence", "2"]);
    assert_eq!(code(&fx.release(&args)), 0);
    fs::write(fx.state.join("floors.json"), "{ not json").expect("damage");

    let o = fx.verify();
    assert_eq!(code(&o), 2, "{}", stderr(&o));
    assert!(stderr(&o).contains("floors.json"), "{}", stderr(&o));
    assert_eq!(
        fx.floors(),
        "{ not json",
        "the damaged file is left as it was"
    );
}

#[test]
fn a_state_directory_nobody_can_name_warns_in_a_development_flow() {
    let fx = Fixture::new();
    fx.lock(&with(&FAR, &["--sequence", "1"]));
    fx.sign();
    // No flag, no variable, no HOME: there is nowhere to keep a floor.
    let o = Command::new(env!("CARGO_BIN_EXE_ci-stick"))
        .args(["verify", p(&fx.stage), "--pubkey", p(&fx.public), "--json"])
        .env_remove("CI_STICK_STATE_DIR")
        .env_remove("XDG_STATE_HOME")
        .env_remove("HOME")
        .env_remove("LOCALAPPDATA")
        .output()
        .expect("run");
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    let j = stdout_json(&o);
    assert_eq!(j["warnings"][0]["code"], "floor-not-checked", "{j}");
}

#[test]
fn an_unwritable_state_directory_warns_in_a_development_flow() {
    let fx = Fixture::new();
    fx.lock(&with(&FAR, &["--sequence", "1"]));
    fx.sign();
    let blocker = fx.state.parent().expect("parent").join("blocker");
    fs::write(&blocker, b"a file where a directory is needed").expect("write");
    let o = fx.run_in(
        &blocker.join("state"),
        &["verify", p(&fx.stage), "--pubkey", p(&fx.public), "--json"],
    );
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    assert_eq!(stdout_json(&o)["warnings"][0]["code"], "floor-not-checked");
}

#[test]
fn the_flag_chooses_the_state_directory_over_the_variable() {
    let fx = Fixture::new();
    fx.lock(&with(&FAR, &["--sequence", "4"]));
    fx.sign();
    let other = fx.state.parent().expect("parent").join("chosen-by-flag");
    let o = fx.run(&[
        "--state-dir",
        p(&other),
        "verify",
        p(&fx.stage),
        "--pubkey",
        p(&fx.public),
    ]);
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    assert!(other.join("floors.json").exists());
    assert!(
        !fx.state.exists(),
        "the variable's directory stayed untouched"
    );

    // The flag also works after the subcommand.
    let o = fx.run(&["trust", "show", "--json", "--state-dir", p(&other)]);
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    let j = stdout_json(&o);
    assert_eq!(j["state_dir_source"], "--state-dir");
    assert_eq!(j["floors"]["trust-test"]["sequence"], 4);
}

#[cfg(unix)]
#[test]
fn the_state_directory_and_its_files_are_private() {
    use std::os::unix::fs::PermissionsExt as _;
    let fx = Fixture::new();
    assert_eq!(code(&fx.release(&with(&FAR, &["--sequence", "1"]))), 0);
    let mode = |path: PathBuf| fs::metadata(path).expect("stat").permissions().mode() & 0o777;
    assert_eq!(mode(fx.state.clone()), 0o700);
    assert_eq!(mode(fx.state.join("floors.json")), 0o600);
}

#[test]
fn a_dry_run_flash_checks_the_floor_but_never_moves_it() {
    let fx = Fixture::new();
    fx.lock(&with(&FAR, &["--sequence", "2"]));
    fx.sign();
    let image = fx.state.parent().expect("parent").join("stick.img");
    let flash = |fx: &Fixture| {
        fx.run(&[
            "flash",
            p(&fx.stage),
            "--pubkey",
            p(&fx.public),
            "--image",
            p(&image),
            "--size",
            "64GB",
            "--dry-run",
            "--json",
        ])
    };
    let o = flash(&fx);
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    assert!(!image.exists());
    assert!(!fx.state.exists(), "a dry run writes no floor");
    assert_eq!(stdout_json(&o)["signature"]["sequence"], 2);

    // Verifying is what accepts a bundle; after it a dry run of an older one is refused.
    assert_eq!(code(&fx.verify()), 0);
    fx.lock(&[
        "--created-at",
        "2090-01-02T00:00:00Z",
        "--valid-days",
        "3650",
        "--sequence",
        "1",
    ]);
    fx.sign();
    let o = flash(&fx);
    assert_eq!(code(&o), 1, "{}", stderr(&o));
    assert_eq!(stdout_json(&o)["errors"][0]["code"], "bundle-rollback");
    assert!(fx.floors().contains("\"sequence\": 2"));
}

#[test]
fn doctor_reads_the_floor_and_never_moves_it() {
    let fx = Fixture::new();
    assert_eq!(code(&fx.release(&with(&FAR, &["--sequence", "2"]))), 0);
    let before = fx.floors();

    // Doctor on an older bundle reports the rollback (and exits 1 as for any failed check) ...
    fx.lock(&[
        "--created-at",
        "2090-01-02T00:00:00Z",
        "--valid-days",
        "3650",
        "--sequence",
        "1",
    ]);
    fx.sign();
    let doctor = |fx: &Fixture| {
        fx.run(&[
            "doctor",
            "--bundle",
            p(&fx.stage),
            "--pubkey",
            p(&fx.public),
            "--json",
        ])
    };
    let o = doctor(&fx);
    assert_eq!(code(&o), 1, "{}", stderr(&o));
    assert_eq!(
        stdout_json(&o)["bundle"]["errors"][0]["code"],
        "bundle-rollback"
    );

    // ... and on a newer one passes without raising anything.
    fx.lock(&[
        "--created-at",
        "2090-01-03T00:00:00Z",
        "--valid-days",
        "3650",
        "--sequence",
        "9",
    ]);
    fx.sign();
    let o = doctor(&fx);
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    assert_eq!(fx.floors(), before, "doctor must not move the floor");
}

#[test]
fn trust_show_reports_what_the_build_pins_and_what_the_machine_remembers() {
    let fx = Fixture::new();
    let o = fx.run(&["trust", "show", "--json"]);
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    let j = stdout_json(&o);
    assert_eq!(j["pinned_keys"], serde_json::json!([]));
    assert_eq!(j["revoked_built_in"], serde_json::json!([]));
    assert_eq!(j["state_dir"], p(&fx.state));
    assert_eq!(j["state_dir_source"], "CI_STICK_STATE_DIR");
    assert_eq!(j["floors"], serde_json::json!({}));
    assert!(!fx.state.exists(), "trust show is read-only");

    assert_eq!(code(&fx.release(&with(&FAR, &["--sequence", "6"]))), 0);
    let o = fx.run(&["trust", "show"]);
    assert_eq!(code(&o), 0);
    let text = String::from_utf8_lossy(&o.stdout).into_owned();
    for needle in [
        "no release key is pinned in this build (KI-23)",
        p(&fx.state),
        "trust-test",
        "sequence 6",
        &fx.fingerprint(),
    ] {
        assert!(text.contains(needle), "{needle:?} missing from:\n{text}");
    }
}

#[test]
fn lock_derives_the_expiry_from_created_at_and_is_reproducible() {
    let a = Fixture::new();
    let b = Fixture::new();
    let args = [
        "--sequence",
        "7",
        "--created-at",
        "2020-01-01T00:00:00Z",
        "--valid-days",
        "30",
        "--json",
    ];
    let o = a.lock(&args);
    let j = stdout_json(&o);
    assert_eq!(j["schema_version"], 2);
    assert_eq!(j["sequence"], 7);
    assert_eq!(j["expires_at"], "2020-01-31T00:00:00Z");
    b.lock(&args);
    assert_eq!(
        fs::read(a.stage.join("bundle.json")).expect("a"),
        fs::read(b.stage.join("bundle.json")).expect("b"),
        "the same inputs give the same bytes"
    );
    // Nothing to change: nothing is rewritten.
    let o = a.lock(&["--json"]);
    assert_eq!(stdout_json(&o)["changed"], false);

    // Default window, still counted from created_at.
    let c = Fixture::new();
    let o = c.lock(&[
        "--sequence",
        "1",
        "--created-at",
        "2020-01-01T00:00:00Z",
        "--json",
    ]);
    assert_eq!(stdout_json(&o)["expires_at"], "2020-12-31T00:00:00Z");
}

#[test]
fn lock_refuses_a_zero_sequence_and_a_zero_day_window() {
    let fx = Fixture::new();
    for bad in [["--sequence", "0"], ["--valid-days", "0"]] {
        let mut args = vec![
            "lock",
            p(&fx.stage),
            "--id",
            "trust-test",
            "--version",
            "1.0.0",
            "--size",
            "64GB",
        ];
        args.extend_from_slice(&bad);
        assert_eq!(code(&fx.run(&args)), 2, "{bad:?}");
    }
    assert!(!fx.stage.join("bundle.json").exists());
}
