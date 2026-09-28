//! `ci-stick` — the Companion Stick command-line tool.
//!
//! Exit codes: 0 success, 1 verification failed, 2 usage or I/O error.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use anyhow::{bail, Context as _};
use clap::{Args, Parser, Subcommand};
use serde::Serialize;

use ci_stick::manifest::{Bundle, BUNDLE_FILE, SIGNATURE_FILE};
use ci_stick::packs::{self, PackCatalog};
use ci_stick::progress::Progress;
use ci_stick::size::{fmt_binary, parse_size};
use ci_stick::{devices, doctor, host, layout, lock, signing, timefmt, verify};

const EXIT_FAILED: u8 = 1;
const EXIT_USAGE: u8 = 2;

#[derive(Parser)]
#[command(
    name = "ci-stick",
    version,
    about = "Build, verify and inspect Companion Stick bundles",
    long_about = "Build, verify and inspect Companion Stick bundles.\n\n\
                  This build never writes to block devices: flashing, host install and \
                  updates arrive in later releases.\n\n\
                  Exit codes: 0 ok, 1 verification failed, 2 usage or I/O error."
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
        Err(e) => {
            eprintln!("error: {e:#}");
            ExitCode::from(EXIT_USAGE)
        }
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
        Command::Doctor(a) => cmd_doctor(a),
        Command::Dev(d) => cmd_dev(d),
    }
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
    let key = a
        .pubkey
        .as_deref()
        .map(signing::parse_public_key)
        .transpose()?;
    let policy = match (key, a.allow_unsigned) {
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
    };
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
