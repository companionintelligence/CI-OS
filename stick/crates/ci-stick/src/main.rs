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
    match cli.command {
        Command::Lock(a) => cmd_lock(a),
        Command::Verify(a) => cmd_verify(a),
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
        Command::Doctor(a) => cmd_doctor(a),
        Command::Dev(d) => cmd_dev(d),
        Command::Flash(a) => cmd_flash(*a),
        Command::Slot(s) => cmd_slot(s),
    }
}

fn signature_policy(
    pubkey: Option<&str>,
    allow_unsigned: bool,
) -> anyhow::Result<verify::SignaturePolicy> {
    let key = pubkey.map(signing::parse_public_key).transpose()?;
    Ok(match (key, allow_unsigned) {
        (Some(k), false) => verify::SignaturePolicy::Require(k),
        (k, true) => {
            eprintln!(
                "WARNING: --allow-unsigned given. An unsigned bundle proves NOTHING about who \
                 built it. Use this only for local development bundles, never for a stick you \
                 will hand to someone."
            );
            verify::SignaturePolicy::AllowUnsigned(k)
        }
        (None, false) => bail!(
            "a trusted public key is required: --pubkey <hex|file> \
             (or --allow-unsigned for development bundles)"
        ),
    })
}

fn cmd_flash(a: FlashArgs) -> anyhow::Result<ExitCode> {
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
    let req = FlashRequest {
        bundle_root: a.root,
        policy: signature_policy(a.pubkey.as_deref(), a.allow_unsigned)?,
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
            changed: bool,
            stale_signature: bool,
            artifacts: usize,
            total_bytes: u64,
            warnings: &'a [String],
        }
        print_json(&LockJson {
            bundle_json: a.dir.join(BUNDLE_FILE).display().to_string(),
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

fn cmd_verify(a: VerifyArgs) -> anyhow::Result<ExitCode> {
    let policy = signature_policy(a.pubkey.as_deref(), a.allow_unsigned)?;
    let mut progress = if a.json {
        Progress::disabled()
    } else {
        Progress::auto(0)
    };
    let report = verify::verify(&a.root, &policy, verify::HashMode::Full, &mut progress)?;
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

fn cmd_doctor(a: DoctorArgs) -> anyhow::Result<ExitCode> {
    let bundle = match &a.bundle {
        Some(root) => {
            let policy = match a
                .pubkey
                .as_deref()
                .map(signing::parse_public_key)
                .transpose()?
            {
                Some(k) => verify::SignaturePolicy::Require(k),
                None => verify::SignaturePolicy::NotChecked,
            };
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
            Some(verify::verify(root, &policy, mode, &mut progress)?)
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
