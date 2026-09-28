# `ci-stick` — Companion Stick CLI

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

`ci-stick` is the Rust tool behind Companion Stick, a multi-function USB stick. The stick
can boot Companion OS, install CI Hub, CI Memory and model packs onto a running
macOS/Windows/Linux host, carry models offline, and update itself.
[`docs/architecture/companion-stick.md`](../docs/architecture/companion-stick.md) covers
the architecture, trust model and roadmap.

**This release never writes to a block device.** It builds and verifies bundles, plans
layouts and runs diagnostics. Flashing, host install and updates come in later slices.

## Build and test

Requires Rust 1.75 or newer (stable is fine).

```bash
cd stick
cargo build --release            # -> target/release/ci-stick
cargo test                       # unit + integration tests
cargo clippy --all-targets -- -D warnings
cargo fmt --check
```

CI runs the same commands, plus a 1.75 MSRV check, in the `stick` job of
`.github/workflows/pr-checks.yml`.

## Usage

```bash
# Partition plan for a device (marketed GB = 10^9, GiB = 2^30; "512G" is rejected as ambiguous)
ci-stick layout plan --size 512GB
ci-stick layout plan --size 476GiB --json

# Model packs (reads core/manifest/model-packs.yaml, found by walking up from the cwd)
ci-stick models list
ci-stick models list --fits 300GiB          # against a cache capacity
ci-stick models list --device 256GB         # against that device's cache partition

# Lock a staging tree: boot/ installers/ oci/ models/ docs/ tools/
ci-stick lock ./staging --id companion-stick-ubuntu --version 2026.09.0 \
    --size 512GB --packs ../core/manifest/model-packs.yaml
ci-stick lock ./staging                     # re-lock: id/version/layout/packs carried over

# Development signing (release bundles are signed by the release pipeline, not this)
ci-stick dev keygen --out ./dev             # writes dev.key (0600) + dev.pub
ci-stick dev sign ./staging --key ./dev.key

# Verify: the signature is mandatory unless --allow-unsigned (development only, loud warning)
ci-stick verify ./staging --pubkey ./dev.pub
ci-stick verify ./staging --pubkey <64-hex> --json

# Read-only diagnostics: host support, candidate USB devices + the layout each would get
ci-stick doctor
ci-stick doctor --bundle /media/$USER/CI-SHARED --pubkey ./dev.pub          # sizes only
ci-stick doctor --bundle /media/$USER/CI-SHARED --pubkey ./dev.pub --full   # + sha256
```

Exit codes: `0` ok, `1` verification failed, `2` usage or I/O error.

### Staging layout

A file's top-level directory determines its artifact `kind`: `boot/` → `boot-image`,
`installers/` → `installer`, `oci/` → `oci-image`, `models/` → `model-blob`, `docs/` →
`doc`, `tools/` → `tool`. If any path component is a platform id (`linux-x86_64`,
`linux-arm64`, `macos-arm64`, `macos-x86_64`, `windows-x86_64`), that platform is recorded
on the artifact. Files anywhere else, and symlinks, are errors: the stick's data
partitions are exFAT.

`lock` is deterministic. It sorts artifacts by path and writes canonical JSON. It takes
`created_at` from `--created-at` or `SOURCE_DATE_EPOCH` when either is set, and otherwise
keeps the previous value if nothing else changed. When the manifest changes, `lock` warns
that any existing `bundle.json.sig` is stale.

## Layout of this directory

```
stick/
  Cargo.toml, Cargo.lock        workspace (lockfile committed)
  crates/ci-stick/src/
    main.rs                     CLI (clap) — thin; everything else is the library
    manifest.rs                 bundle.json types — the schema's source of truth
    layout.rs  size.rs          partition plan (pure) + size parsing
    lock.rs  verify.rs          staging -> bundle.json; bundle -> report
    signing.rs  hashing.rs      ed25519 detached signatures; streaming sha256
    paths.rs                    relative-path rules (no escapes)
    packs.rs                    model-pack catalog + fit logic
    devices.rs  host.rs         read-only device listing; host capability matrix
    doctor.rs  progress.rs  timefmt.rs
  crates/ci-stick/tests/        CLI end-to-end + schema drift tests
  schema/bundle.schema.json     published JSON Schema (mirror of manifest.rs)
  schema/examples/              canonical example bundle.json
```

Rust is first-class inside `stick/` only. `core/` and the shell backends must never
depend on it.
