//! `ci-stick` — the Companion Stick command-line tool.
//!
//! Exit codes: 0 success, 1 verification failed, 2 usage or I/O error. The `models plan|lock|fetch|
//! cache-info` commands add 3 (drift), 4 (no space), 5 (licence), 6 (interrupted, resumable) and
//! 7 (integrity); see `cmd_models`.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use anyhow::{bail, Context as _};
use clap::{Args, Parser, Subcommand};
use serde::Serialize;

use ci_stick::cmd_models;
use ci_stick::flash::{self, FlashOutcome, FlashRequest, TargetSpec};
use ci_stick::grubenv::Slot;
use ci_stick::manifest::{Bundle, BUNDLE_FILE, SIGNATURE_FILE};
use ci_stick::packs::{self, PackCatalog};
use ci_stick::progress::Progress;
use ci_stick::size::{fmt_binary, parse_size};
use ci_stick::slot::{self, SlotTarget};
use ci_stick::state::{self, Floor, FloorStore, Os, StateEnv, StateError};
use ci_stick::trust::TrustAnchors;
use ci_stick::verify::{FloorMode, Freshness, PolicyRequest, SignaturePolicy};
use ci_stick::{devices, doctor, host, layout, lock, signing, timefmt, verify};

const EXIT_FAILED: u8 = 1;
const EXIT_USAGE: u8 = 2;

#[derive(Parser)]
#[command(
    name = "ci-stick",
    version,
    about = "Build, verify, inspect and flash Companion Stick bundles",
    long_about = "Build, verify, inspect and flash Companion Stick bundles.\n\n\
                  Only `flash` and `slot set` write to a stick, and only after verifying \
                  the bundle and passing the device safety checks (see `flash --help`). \
                  Host install and updates arrive in later releases.\n\n\
                  Exit codes: 0 ok, 1 verification failed, 2 usage error, I/O error or \
                  safety refusal."
)]
struct Cli {
    /// Directory for the sequence floors and the optional revoked.txt (default: $CI_STICK_STATE_DIR,
    /// else the platform's per-user state directory; see `ci-stick trust show`).
    #[arg(long, global = true, value_name = "DIR")]
    state_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Hash a staging directory and write/update its bundle.json.
    Lock(LockArgs),
    /// Verify a bundle's signature and every artifact's size and SHA-256.
    Verify(VerifyArgs),
    /// Partition layout planning.
    #[command(subcommand)]
    Layout(LayoutCommand),
    /// Model packs.
    #[command(subcommand)]
    Models(ModelsCommand),
    /// Read-only diagnostics: host support, candidate devices, optional bundle check.
    Doctor(DoctorArgs),
    /// Development-only helpers (test keys, signing unreleased bundles).
    #[command(subcommand)]
    Dev(DevCommand),
    /// Verify a bundle and write it to a stick image or a removable USB device.
    Flash(Box<FlashArgs>),
    /// Show or switch the active A/B boot slot on a flashed stick or image.
    #[command(subcommand)]
    Slot(SlotCommand),
    /// Release keys pinned in this build and what this machine has accepted so far.
    #[command(subcommand)]
    Trust(TrustCommand),
}

#[derive(Args)]
#[command(
    long_about = "Verify a bundle and write it to a stick image or a removable USB device.\n\n\
                  ERASES THE TARGET. Always run with --dry-run first and read the plan. \
                  A --device write requires --confirm <device node exactly as shown> (plus \
                  --expect-serial when the device reports a serial), and a bundle carrying \
                  the unsigned development bootloader also needs --allow-unsigned-bootloader \
                  (the Secure Boot chain, shim → Canonical GRUB, does not). Devices must be \
                  removable or USB-attached, with nothing mounted and no swap; the node is \
                  opened O_EXCL and its identity is re-checked right before the first write."
)]
struct FlashArgs {
    /// Bundle root (the directory containing bundle.json and bundle.json.sig).
    root: PathBuf,
    /// Write a sparse stick image file (created or overwritten). Requires --size.
    #[arg(
        long,
        conflicts_with = "device",
        requires = "size",
        required_unless_present = "device"
    )]
    image: Option<PathBuf>,
    /// Image size, e.g. 64GB or 476GiB (with --image).
    #[arg(long, requires = "image")]
    size: Option<String>,
    /// Whole block device to ERASE and write, e.g. /dev/sdb or /dev/disk/by-id/usb-... (Linux).
    #[arg(long)]
    device: Option<PathBuf>,
    /// Trusted ed25519 public key: 64 hex characters, or a file containing it.
    #[arg(long)]
    pubkey: Option<String>,
    /// DEVELOPMENT ONLY, --image only: accept the key given with --pubkey although this build
    /// pins release keys (without a pinned key it is not needed). Refused with --device.
    #[arg(long, requires = "pubkey")]
    development_key: bool,
    /// DEVELOPMENT ONLY, --image only: accept an unsigned bundle.
    #[arg(long)]
    allow_unsigned: bool,
    /// DEVELOPMENT ONLY: allow a --device write of a bundle whose bootloader is the unsigned
    /// development GRUB (the stick then boots only with Secure Boot disabled).
    #[arg(long)]
    allow_unsigned_bootloader: bool,
    /// Print the plan and write nothing.
    #[arg(long)]
    dry_run: bool,
    /// Device writes: must equal the device node shown in the plan (e.g. /dev/sdb).
    #[arg(long)]
    confirm: Option<String>,
    /// Device writes: must equal the serial shown in the plan, when the device has one.
    #[arg(long)]
    expect_serial: Option<String>,
    /// Manifest path of the boot image, when the bundle carries more than one.
    #[arg(long)]
    boot_image: Option<String>,
    /// TESTS/DEVELOPMENT, --image only: also write this ISO into boot slot B.
    #[arg(long)]
    slot_b_from: Option<PathBuf>,
    /// Extra kernel arguments stored in grubenv (e.g. "console=ttyS0,115200" for tests).
    #[arg(long)]
    extra_cmdline: Option<String>,
    /// Directory for the temporary sparse filesystem images (default: system temp dir).
    #[arg(long)]
    work_dir: Option<PathBuf>,
    /// Machine-readable plan/result on stdout.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
#[group(required = true, multiple = false)]
struct SlotTargetArgs {
    /// A stick image file.
    #[arg(long)]
    image: Option<PathBuf>,
    /// A stick device (Linux), e.g. /dev/sdb.
    #[arg(long)]
    device: Option<PathBuf>,
}

impl SlotTargetArgs {
    fn target(&self) -> anyhow::Result<SlotTarget> {
        match (&self.image, &self.device) {
            (Some(i), None) => Ok(SlotTarget::Image(i.clone())),
            (None, Some(d)) => Ok(SlotTarget::Device(d.clone())),
            _ => bail!("give exactly one of --image <file> or --device <dev>"),
        }
    }
}

#[derive(Subcommand)]
enum SlotCommand {
    /// Show the active slot and the grubenv variables.
    Show {
        #[command(flatten)]
        target: SlotTargetArgs,
        #[arg(long)]
        json: bool,
    },
    /// Make A or B the active slot (only the ESP's 1 KiB grubenv changes).
    Set {
        /// A or B.
        slot: String,
        #[command(flatten)]
        target: SlotTargetArgs,
        /// Device writes: must equal the device node.
        #[arg(long)]
        confirm: Option<String>,
        /// Device writes: must equal the device serial, when it has one.
        #[arg(long)]
        expect_serial: Option<String>,
        #[arg(long)]
        json: bool,
    },
}

#[derive(Args)]
struct LockArgs {
    /// Staging directory (boot/, installers/, oci/, models/, docs/, tools/).
    dir: PathBuf,
    /// Bundle id (required for a new bundle), e.g. companion-stick-ubuntu.
    #[arg(long)]
    id: Option<String>,
    /// Bundle version (required for a new bundle), e.g. 2026.09.0.
    #[arg(long = "version")]
    bundle_version: Option<String>,
    /// Model-pack catalog to record (e.g. core/manifest/model-packs.yaml).
    #[arg(long)]
    packs: Option<PathBuf>,
    /// Target device size (e.g. 512GB, 476GiB); required for a new bundle.
    #[arg(long)]
    size: Option<String>,
    /// Fixed created_at (RFC 3339 UTC). Defaults to SOURCE_DATE_EPOCH when set.
    #[arg(long)]
    created_at: Option<String>,
    /// Write schema_version 2 with this release counter (1 or more). Without it a schema 2
    /// bundle that changed gets the previous bundle.json's plus one (1 for a new one).
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
    sequence: Option<u64>,
    /// Write schema_version 2 that expires this many days after created_at (default 365).
    /// Counted from created_at, never from the clock, so the output stays reproducible.
    #[arg(long, value_parser = clap::value_parser!(u32).range(1..))]
    valid_days: Option<u32>,
    /// Machine-readable output.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
struct VerifyArgs {
    /// Bundle root (the directory containing bundle.json).
    root: PathBuf,
    /// Trusted ed25519 public key: 64 hex characters, or a file containing it.
    #[arg(long)]
    pubkey: Option<String>,
    /// DEVELOPMENT ONLY: accept the key given with --pubkey although this build pins release
    /// keys (without a pinned key it is not needed).
    #[arg(long, requires = "pubkey")]
    development_key: bool,
    /// DEVELOPMENT ONLY: accept a bundle with no signature.
    #[arg(long)]
    allow_unsigned: bool,
    /// Machine-readable output.
    #[arg(long)]
    json: bool,
}

#[derive(Subcommand)]
enum LayoutCommand {
    /// Show the GPT plan for a device size.
    Plan {
        /// Device size, e.g. 512GB (marketed, 10^9) or 476GiB (2^30).
        #[arg(long)]
        size: String,
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand)]
enum ModelsCommand {
    /// List model packs and whether they fit a model cache.
    List(ModelsListArgs),
    /// What `models fetch` would download for a pack, and whether it fits the cache volume.
    Plan(cmd_models::PlanArgs),
    /// Resolve the pack catalog against the registry into model-packs.lock.json (--check: drift).
    Lock(cmd_models::LockArgs),
    /// Download a pack's (or one model's) blobs into a cache, resumably, verified against the lock.
    Fetch(cmd_models::FetchArgs),
    /// Size, blobs, partial downloads, free space and complete packs of a model cache.
    CacheInfo(cmd_models::CacheInfoArgs),
}

#[derive(Args)]
struct ModelsListArgs {
    /// Pack catalog (default: core/manifest/model-packs.yaml found from the current directory).
    #[arg(long, conflicts_with = "bundle")]
    catalog: Option<PathBuf>,
    /// Read packs from a bundle's bundle.json instead (not signature-checked).
    #[arg(long)]
    bundle: Option<PathBuf>,
    /// Model-cache capacity to test against, e.g. 300GiB.
    #[arg(long, conflicts_with = "device")]
    fits: Option<String>,
    /// Device size; tests against the cache partition of its layout plan.
    #[arg(long)]
    device: Option<String>,
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
struct DoctorArgs {
    /// Also check a bundle (sizes only unless --full).
    #[arg(long)]
    bundle: Option<PathBuf>,
    /// With --bundle: hash every artifact.
    #[arg(long, requires = "bundle")]
    full: bool,
    /// With --bundle: trusted public key to check the signature against.
    #[arg(long, requires = "bundle")]
    pubkey: Option<String>,
    /// DEVELOPMENT ONLY: accept the key given with --pubkey although this build pins release keys.
    #[arg(long, requires = "pubkey")]
    development_key: bool,
    #[arg(long)]
    json: bool,
}

#[derive(Subcommand)]
enum DevCommand {
    /// Generate a DEVELOPMENT ed25519 key pair: <OUT>.key (secret) and <OUT>.pub.
    Keygen {
        #[arg(long)]
        out: PathBuf,
    },
    /// Sign <ROOT>/bundle.json with a DEVELOPMENT key, writing bundle.json.sig.
    Sign {
        root: PathBuf,
        #[arg(long)]
        key: PathBuf,
    },
}

#[derive(Subcommand)]
enum TrustCommand {
    /// Pinned and revoked key fingerprints, the state directory, and each stored sequence floor.
    /// Read-only.
    Show {
        #[arg(long)]
        json: bool,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli) {
        Ok(code) => code,
        Err(e) if is_broken_pipe(&e) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e:#}");
            ExitCode::from(EXIT_USAGE)
        }
    }
}

/// A reader that exits early (`grep -q`, `head`) closes stdout. That is success, not a crash.
fn is_broken_pipe(err: &anyhow::Error) -> bool {
    err.chain().any(|cause| {
        cause
            .downcast_ref::<std::io::Error>()
            .is_some_and(|io| io.kind() == std::io::ErrorKind::BrokenPipe)
    })
}

fn write_stdout(text: &str) -> anyhow::Result<()> {
    let mut out = std::io::stdout().lock();
    match out.write_all(text.as_bytes()).and_then(|()| out.flush()) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => Ok(()),
        Err(e) => Err(e).context("writing to stdout"),
    }
}

fn print_json<T: Serialize>(value: &T) -> anyhow::Result<()> {
    let mut out = std::io::stdout().lock();
    serde_json::to_writer_pretty(&mut out, value).context("writing JSON")?;
    writeln!(out).context("writing JSON")?;
    Ok(())
}

fn run(cli: Cli) -> anyhow::Result<ExitCode> {
    let state_dir = cli.state_dir;
    match cli.command {
        Command::Lock(a) => cmd_lock(a),
        Command::Verify(a) => cmd_verify(a, state_dir.as_deref()),
        Command::Layout(LayoutCommand::Plan { size, json }) => {
            let bytes = parse_size(&size)?;
            let plan = layout::plan(bytes)?;
            if json {
                print_json(&plan)?;
            } else {
                print!("{}", layout::render_table(&plan));
            }
            Ok(ExitCode::SUCCESS)
        }
        Command::Models(ModelsCommand::List(a)) => cmd_models_list(a),
        Command::Models(ModelsCommand::Plan(a)) => cmd_models::cmd_plan(a),
        Command::Models(ModelsCommand::Lock(a)) => cmd_models::cmd_lock(a),
        Command::Models(ModelsCommand::Fetch(a)) => cmd_models::cmd_fetch(a),
        Command::Models(ModelsCommand::CacheInfo(a)) => cmd_models::cmd_cache_info(a),
        Command::Doctor(a) => cmd_doctor(a, state_dir.as_deref()),
        Command::Dev(d) => cmd_dev(d),
        Command::Flash(a) => cmd_flash(*a, state_dir.as_deref()),
        Command::Slot(s) => cmd_slot(s),
        Command::Trust(TrustCommand::Show { json }) => cmd_trust_show(json, state_dir.as_deref()),
    }
}

/// The build's trust anchors plus what this machine's state directory adds to them.
struct Trust {
    /// Compiled-in lists plus the fingerprints in the state directory's `revoked.txt`.
    anchors: TrustAnchors,
    /// The floor store, or why there is none.
    store: Result<FloorStore, String>,
}

fn load_trust(state_dir_flag: Option<&Path>) -> anyhow::Result<Trust> {
    // Malformed lists in this build: refuse to verify anything.
    let builtin = TrustAnchors::builtin()?;
    let resolved =
        state::resolve_state_dir(Os::current(), &StateEnv::from_process(), state_dir_flag);
    Ok(match resolved {
        Ok((dir, _source)) => {
            let store = FloorStore::new(dir);
            let extra = match store.extra_revoked() {
                Ok(v) => v,
                // A revoked.txt that cannot be read must not silently stop revoking.
                Err(e @ StateError::Damaged(_)) => return Err(e.into()),
                // An unusable directory is reported where the floors are needed.
                Err(_) => Vec::new(),
            };
            Trust {
                anchors: builtin.with_revoked(extra),
                store: Ok(store),
            }
        }
        Err(e) => Trust {
            anchors: builtin,
            store: Err(e.to_string()),
        },
    })
}

impl Trust {
    /// `required`: an unusable state directory refuses (pinned and `--device` flows) instead of
    /// warning. `record`: raise the floor after a fully successful verification.
    fn freshness(&self, required: bool, record: bool) -> anyhow::Result<Freshness> {
        let now = timefmt::unix_now()
            .context("the system clock reads a time before 1970, so an expiry cannot be checked")?;
        let floors = match &self.store {
            Ok(store) => FloorMode::Store {
                store: store.clone(),
                required,
                record,
            },
            Err(reason) => FloorMode::Unavailable {
                reason: reason.clone(),
                required,
            },
        };
        Ok(Freshness {
            now,
            revoked: self.anchors.revoked().map(str::to_string).collect(),
            floors,
        })
    }
}

fn print_notes(notes: &[String]) {
    for n in notes {
        eprintln!("{n}");
    }
}

fn signature_policy(
    trust: &Trust,
    pubkey: Option<&str>,
    development_key: bool,
    allow_unsigned: bool,
    device: bool,
) -> anyhow::Result<SignaturePolicy> {
    let chosen = verify::choose_policy(
        &trust.anchors,
        PolicyRequest {
            pubkey: pubkey.map(signing::parse_public_key).transpose()?,
            development_key,
            allow_unsigned,
            device,
        },
    )?;
    print_notes(&chosen.notes);
    Ok(chosen.policy)
}

fn cmd_flash(a: FlashArgs, state_dir: Option<&Path>) -> anyhow::Result<ExitCode> {
    let target = match (&a.image, &a.device) {
        (Some(path), None) => {
            let size = a.size.as_deref().context("--image requires --size")?;
            TargetSpec::Image {
                path: path.clone(),
                size_bytes: parse_size(size)?,
            }
        }
        (None, Some(path)) => TargetSpec::Device { path: path.clone() },
        _ => bail!("give exactly one target: --image <file> --size <size>, or --device <dev>"),
    };
    if target.is_device() && a.allow_unsigned {
        bail!(
            "--allow-unsigned is refused with --device: a physical stick is only ever written \
             from a signed bundle (it is accepted with --image for development)"
        );
    }
    let trust = load_trust(state_dir)?;
    let policy = signature_policy(
        &trust,
        a.pubkey.as_deref(),
        a.development_key,
        a.allow_unsigned,
        target.is_device(),
    )?;
    // A device or a pinned key makes the floor mandatory: no state directory, no write. The
    // floor itself is recorded by `flash` after the stick was written, never by a dry run.
    let required = target.is_device() || matches!(policy, SignaturePolicy::Pinned(_));
    let req = FlashRequest {
        bundle_root: a.root,
        freshness: trust.freshness(required, false)?,
        policy,
        target,
        boot_image: a.boot_image,
        slot_b_from: a.slot_b_from,
        extra_cmdline: a.extra_cmdline,
        dry_run: a.dry_run,
        confirm: a.confirm,
        expect_serial: a.expect_serial,
        work_dir: a.work_dir,
        allow_unsigned_bootloader: a.allow_unsigned_bootloader,
    };
    let mut progress = if a.json {
        Progress::disabled()
    } else {
        Progress::auto(0)
    };
    match flash::flash(&req, &mut progress)? {
        FlashOutcome::VerifyFailed(report) => {
            eprintln!("refusing to flash: the bundle failed verification; nothing was written\n");
            if a.json {
                print_json(&report)?;
            } else {
                eprint!("{}", verify::render_human(&report));
            }
            Ok(ExitCode::from(EXIT_FAILED))
        }
        FlashOutcome::DryRun(plan) => {
            if a.json {
                print_json(&plan)?;
            } else {
                print!("{}", flash::render_plan(&plan, true));
            }
            Ok(ExitCode::SUCCESS)
        }
        FlashOutcome::Written(plan, report) => {
            if a.json {
                #[derive(Serialize)]
                struct Out<'a> {
                    plan: &'a flash::FlashPlan,
                    result: &'a flash::WriteReport,
                }
                print_json(&Out {
                    plan: &plan,
                    result: &report,
                })?;
            } else {
                println!(
                    "Flashed {} {} ({} written)",
                    plan.bundle_id,
                    plan.bundle_version,
                    fmt_binary(report.bytes_written)
                );
                for c in &report.checks {
                    println!("  ok  {c}");
                }
                if let flash::PlannedTarget::Device { identity, .. } = &plan.target {
                    println!(
                        "Unplug and re-plug the stick (or run `sudo partprobe {}`) so the OS sees the new partitions.",
                        identity.node
                    );
                }
            }
            Ok(ExitCode::SUCCESS)
        }
    }
}

fn cmd_slot(s: SlotCommand) -> anyhow::Result<ExitCode> {
    let (state, json) = match s {
        SlotCommand::Show { target, json } => (slot::show(&target.target()?)?, json),
        SlotCommand::Set {
            slot: which,
            target,
            confirm,
            expect_serial,
            json,
        } => {
            let which = Slot::parse(&which)?;
            let state = slot::set(
                &target.target()?,
                which,
                confirm.as_deref(),
                expect_serial.as_deref(),
            )?;
            (state, json)
        }
    };
    if json {
        print_json(&state)?;
    } else {
        let mut text = format!("{}: active slot {}\n", state.target, state.active_slot);
        for (k, v) in &state.vars {
            text.push_str(&format!("  {k}={v}\n"));
        }
        write_stdout(&text)?;
    }
    Ok(ExitCode::SUCCESS)
}

fn created_at_from_env() -> anyhow::Result<Option<String>> {
    match std::env::var("SOURCE_DATE_EPOCH") {
        Ok(v) => {
            let secs: u64 = v
                .trim()
                .parse()
                .with_context(|| format!("SOURCE_DATE_EPOCH={v:?} is not a Unix timestamp"))?;
            Ok(Some(timefmt::format_unix(secs)))
        }
        Err(_) => Ok(None),
    }
}

fn cmd_lock(a: LockArgs) -> anyhow::Result<ExitCode> {
    let packs = match &a.packs {
        Some(p) => Some(PackCatalog::load(p)?.packs),
        None => None,
    };
    let device_bytes = a.size.as_deref().map(parse_size).transpose()?;
    let created_at = match a.created_at {
        Some(ts) => {
            if !timefmt::is_rfc3339_utc(&ts) {
                bail!("--created-at must look like 2026-09-28T12:00:00Z");
            }
            Some(ts)
        }
        None => created_at_from_env()?,
    };
    let opts = lock::LockOptions {
        id: a.id,
        version: a.bundle_version,
        packs,
        device_bytes,
        created_at,
        sequence: a.sequence,
        valid_days: a.valid_days,
    };
    let mut progress = if a.json {
        Progress::disabled()
    } else {
        Progress::auto(0)
    };
    let out = lock::lock(&a.dir, &opts, &mut progress)?;

    if a.json {
        #[derive(Serialize)]
        struct LockJson<'a> {
            bundle_json: String,
            schema_version: u32,
            #[serde(skip_serializing_if = "Option::is_none")]
            sequence: Option<u64>,
            #[serde(skip_serializing_if = "Option::is_none")]
            expires_at: Option<&'a str>,
            changed: bool,
            stale_signature: bool,
            artifacts: usize,
            total_bytes: u64,
            warnings: &'a [String],
        }
        print_json(&LockJson {
            bundle_json: a.dir.join(BUNDLE_FILE).display().to_string(),
            schema_version: out.bundle.schema_version,
            sequence: out.bundle.sequence,
            expires_at: out.bundle.expires_at.as_deref(),
            changed: out.changed,
            stale_signature: out.stale_signature,
            artifacts: out.bundle.artifacts.len(),
            total_bytes: out.bundle.artifacts.iter().map(|x| x.size).sum(),
            warnings: &out.warnings,
        })?;
    } else {
        let total: u64 = out.bundle.artifacts.iter().map(|x| x.size).sum();
        println!(
            "{} {} — {} artifacts, {}, {} model packs, layout {}",
            out.bundle.id,
            out.bundle.version,
            out.bundle.artifacts.len(),
            fmt_binary(total),
            out.bundle.model_packs.len(),
            out.bundle.layout.policy
        );
        if let (Some(n), Some(until)) = (out.bundle.sequence, &out.bundle.expires_at) {
            println!("sequence {n}, expires {until}");
        }
        println!(
            "{} {}",
            if out.changed { "wrote" } else { "unchanged" },
            a.dir.join(BUNDLE_FILE).display()
        );
        for w in &out.warnings {
            eprintln!("warning: {w}");
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_verify(a: VerifyArgs, state_dir: Option<&Path>) -> anyhow::Result<ExitCode> {
    let trust = load_trust(state_dir)?;
    let policy = signature_policy(
        &trust,
        a.pubkey.as_deref(),
        a.development_key,
        a.allow_unsigned,
        false,
    )?;
    // Verifying is accepting: the floor moves up once the whole bundle checked out.
    let required = matches!(policy, SignaturePolicy::Pinned(_));
    let fresh = trust.freshness(required, true)?;
    let mut progress = if a.json {
        Progress::disabled()
    } else {
        Progress::auto(0)
    };
    let report = verify::verify_at(
        &a.root,
        &policy,
        &fresh,
        verify::HashMode::Full,
        &mut progress,
    )?;
    if a.json {
        print_json(&report)?;
    } else {
        print!("{}", verify::render_human(&report));
    }
    Ok(if report.ok {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(EXIT_FAILED)
    })
}

fn cmd_models_list(a: ModelsListArgs) -> anyhow::Result<ExitCode> {
    let (packs, bundle_cache) = if let Some(root) = &a.bundle {
        let b = Bundle::load(&root.join(BUNDLE_FILE))?;
        let cache = b.layout.cache_bytes();
        (b.model_packs, Some(cache))
    } else {
        let path = match &a.catalog {
            Some(p) => p.clone(),
            None => {
                let cwd = std::env::current_dir().context("reading current directory")?;
                packs::find_catalog(&cwd).with_context(|| {
                    format!(
                        "no {} found above {}; pass --catalog <file>",
                        packs::CATALOG_REL_PATH,
                        cwd.display()
                    )
                })?
            }
        };
        (PackCatalog::load(&path)?.packs, None)
    };
    let capacity = match (&a.fits, &a.device) {
        (Some(s), _) => Some(parse_size(s)?),
        (None, Some(d)) => Some(layout::plan(parse_size(d)?)?.cache_bytes()),
        (None, None) => bundle_cache,
    };
    let report = packs::fit_report(&packs, capacity);
    if a.json {
        print_json(&report)?;
    } else {
        print!("{}", packs::render_table(&report));
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_doctor(a: DoctorArgs, state_dir: Option<&Path>) -> anyhow::Result<ExitCode> {
    let bundle = match &a.bundle {
        Some(root) => {
            let trust = load_trust(state_dir)?;
            // Diagnostics: report only. With no pinned key and no --pubkey nothing is trusted.
            let policy = if a.pubkey.is_none() && !trust.anchors.has_pinned_keys() {
                SignaturePolicy::NotChecked
            } else {
                signature_policy(&trust, a.pubkey.as_deref(), a.development_key, false, false)?
            };
            // Read-only: the floors are looked at, never raised, and a missing state
            // directory does not make a diagnostic fail.
            let fresh = trust.freshness(false, false)?;
            let mode = if a.full {
                verify::HashMode::Full
            } else {
                verify::HashMode::SizesOnly
            };
            let mut progress = if a.json {
                Progress::disabled()
            } else {
                Progress::auto(0)
            };
            Some(verify::verify_at(
                root,
                &policy,
                &fresh,
                mode,
                &mut progress,
            )?)
        }
        None => None,
    };
    let report = doctor::build_report(host::current(), devices::discover(), bundle);
    if a.json {
        print_json(&report)?;
    } else {
        print!("{}", doctor::render_human(&report));
    }
    Ok(if report.ok() {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(EXIT_FAILED)
    })
}

fn cmd_trust_show(json: bool, state_dir: Option<&Path>) -> anyhow::Result<ExitCode> {
    #[derive(Serialize)]
    struct TrustShow {
        /// Fingerprints of the release keys pinned in this build (none today: KI-23).
        pinned_keys: Vec<String>,
        /// Revoked by the committed list.
        revoked_built_in: Vec<String>,
        /// Revoked by the state directory's revoked.txt.
        revoked_state_file: Vec<String>,
        state_dir: Option<String>,
        state_dir_source: Option<&'static str>,
        state_dir_error: Option<String>,
        floors: std::collections::BTreeMap<String, Floor>,
    }
    let builtin = TrustAnchors::builtin()?;
    let mut show = TrustShow {
        pinned_keys: builtin.pinned().iter().map(|k| k.id.clone()).collect(),
        revoked_built_in: builtin.revoked().map(str::to_string).collect(),
        revoked_state_file: Vec::new(),
        state_dir: None,
        state_dir_source: None,
        state_dir_error: None,
        floors: Default::default(),
    };
    match state::resolve_state_dir(Os::current(), &StateEnv::from_process(), state_dir) {
        Ok((dir, source)) => {
            let store = FloorStore::new(dir);
            show.state_dir = Some(store.dir().display().to_string());
            show.state_dir_source = Some(source.as_str());
            show.revoked_state_file = store.extra_revoked()?;
            show.floors = store.load()?;
        }
        Err(e) => show.state_dir_error = Some(e.to_string()),
    }
    if json {
        print_json(&show)?;
        return Ok(ExitCode::SUCCESS);
    }
    let list = |items: &[String]| {
        if items.is_empty() {
            "none".to_string()
        } else {
            items.join(", ")
        }
    };
    let mut text = String::new();
    text.push_str(&format!(
        "Pinned release keys   {}\n",
        if show.pinned_keys.is_empty() {
            "none: no release key is pinned in this build (KI-23), so --pubkey is the only key source"
                .to_string()
        } else {
            show.pinned_keys.join(", ")
        }
    ));
    text.push_str(&format!(
        "Revoked fingerprints  built in: {}\n                      state file: {}\n",
        list(&show.revoked_built_in),
        list(&show.revoked_state_file)
    ));
    match (&show.state_dir, &show.state_dir_error) {
        (Some(dir), _) => text.push_str(&format!(
            "State directory       {dir} ({})\n",
            show.state_dir_source.unwrap_or("default location")
        )),
        (None, Some(e)) => text.push_str(&format!(
            "State directory       none: {e}\n                      (set {} or pass --state-dir)\n",
            state::STATE_DIR_ENV
        )),
        (None, None) => {}
    }
    if show.floors.is_empty() {
        text.push_str("Sequence floors       none recorded\n");
    } else {
        text.push_str("Sequence floors\n");
        for (id, f) in &show.floors {
            text.push_str(&format!(
                "  {id}  sequence {}  bundle.json sha256 {}  signer {}\n",
                f.sequence,
                &f.bundle_sha256[..12],
                f.signer
            ));
        }
    }
    write_stdout(&text)?;
    Ok(ExitCode::SUCCESS)
}

fn cmd_dev(d: DevCommand) -> anyhow::Result<ExitCode> {
    match d {
        DevCommand::Keygen { out } => {
            let sk = signing::generate_signing_key()?;
            let secret = with_suffix(&out, ".key");
            let public = with_suffix(&out, ".pub");
            signing::write_secret_file(&secret, &format!("{}\n", hex::encode(sk.to_bytes())))?;
            let pk = sk.verifying_key();
            std::fs::write(&public, format!("{}\n", hex::encode(pk.as_bytes())))
                .with_context(|| format!("writing {}", public.display()))?;
            eprintln!("DEVELOPMENT key pair — never use it to sign a bundle you distribute.");
            println!("secret: {}", secret.display());
            println!(
                "public: {} (fingerprint {})",
                public.display(),
                signing::fingerprint(&pk)
            );
        }
        DevCommand::Sign { root, key } => {
            let sk = signing::load_signing_key(&key)?;
            let manifest = root.join(BUNDLE_FILE);
            let bytes = std::fs::read(&manifest)
                .with_context(|| format!("reading {}", manifest.display()))?;
            // Refuse to sign something that is not a valid bundle.
            let bundle = Bundle::parse(&bytes)?;
            let problems = bundle.validate();
            if !problems.is_empty() {
                bail!(
                    "refusing to sign an invalid bundle.json:\n  {}",
                    problems.join("\n  ")
                );
            }
            let sig_path = root.join(SIGNATURE_FILE);
            std::fs::write(&sig_path, signing::sign_to_hex(&sk, &bytes))
                .with_context(|| format!("writing {}", sig_path.display()))?;
            println!(
                "signed {} with DEVELOPMENT key {}",
                manifest.display(),
                signing::fingerprint(&sk.verifying_key())
            );
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn with_suffix(p: &Path, suffix: &str) -> PathBuf {
    let mut s = p.as_os_str().to_owned();
    s.push(suffix);
    PathBuf::from(s)
}
