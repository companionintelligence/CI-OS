# `ci-stick` — Companion Stick CLI

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

`ci-stick` is the Rust tool behind Companion Stick, a multi-function USB stick. The stick
can boot Companion OS, install CI Hub, CI Memory and model packs onto a running
macOS/Windows/Linux host, carry models offline, and update itself.
[`docs/architecture/companion-stick.md`](../docs/architecture/companion-stick.md) covers
the architecture, trust model and roadmap.

This release builds and verifies bundles, plans layouts, runs diagnostics, and **flashes**
sticks or stick images (Ubuntu x86_64 layout, A/B slots, persistence). Host install and
the signed updater come in later slices.

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

**Adding a dependency or bumping the lock.** The MSRV is 1.75, and newer releases of some dependencies (`ureq` 3.4.x, `reqwest` 0.13, ...) declare
a higher Rust version, so a plain `cargo update` can move `Cargo.lock` to a crate that 1.75 cannot build. `stick/.cargo/config.toml` sets
`incompatible-rust-versions = "fallback"` (read by Cargo 1.84 and newer; on an older cargo set `CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS=fallback`),
and `ureq` is also pinned exactly (`=3.2.1`) in `crates/ci-stick/Cargo.toml`. After any change to dependencies or to the lock, check the MSRV and
commit `Cargo.lock`:

```bash
cd stick && cargo +1.75 check --locked --all-targets
```

**One test is opt-in.** `crates/ci-stick/tests/models_live.rs` downloads `nomic-embed-text` (274 MB) from the real Ollama registry and is skipped
(with a note) unless you ask for it:

```bash
cd stick && CI_STICK_LIVE=1 CI_STICK_LIVE_DIR="$(mktemp -d)" cargo test --test models_live -- --nocapture
```

The other tuning variables of `ci-stick models fetch` and the test switches are in the [environment reference](../docs/guides/environment-reference.md).

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

# A release bundle is schema 2: a sequence number (the release pipeline picks it) and an expiry.
# expires_at is created_at + the window, never read from the clock, so the same inputs give the same bytes.
ci-stick lock ./staging --sequence 3 --valid-days 365
ci-stick lock ./staging                     # stays schema 2; a changed tree gets the previous sequence plus one

# Development signing (release bundles are signed by the release pipeline, not this)
ci-stick dev keygen --out ./dev             # writes dev.key (0600) + dev.pub
ci-stick dev sign ./staging --key ./dev.key

# Verify: the signature is mandatory unless --allow-unsigned (development only, loud warning).
# A schema 2 bundle must also be unexpired and not older than the last one this machine accepted.
ci-stick verify ./staging --pubkey ./dev.pub
ci-stick verify ./staging --pubkey <64-hex> --json

# What this build pins (nothing yet: KI-23), what is revoked, and the sequence floor per bundle id
ci-stick trust show
ci-stick trust show --json

# Read-only diagnostics: host support, candidate USB devices + the layout each would get
ci-stick doctor
ci-stick doctor --bundle /media/$USER/CI-SHARED --pubkey ./dev.pub          # sizes only
ci-stick doctor --bundle /media/$USER/CI-SHARED --pubkey ./dev.pub --full   # + sha256
```

Exit codes: `0` ok, `1` verification failed, `2` usage or I/O error, or a safety refusal.
(The `models plan|lock|fetch|cache-info` commands add `3` to `7`; see below.)

### Trust: pinned keys, expiry and the sequence floor

`verify`, `flash` and `doctor --bundle` refuse a bundle that is correctly signed but old. All of it is described in
[`docs/architecture/companion-stick.md`](../docs/architecture/companion-stick.md#bundle-format-and-trust-model); in short:

| Finding (exit 1) | When |
|---|---|
| `bundle-expired` | `now >= expires_at` (schema 2) |
| `bundle-rollback` | `sequence` is below the floor stored for the bundle `id` |
| `bundle-sequence-conflict` | `sequence` equals the floor but `bundle.json` has other bytes (the same bytes are accepted again) |
| `signature-key-revoked` | the signature verifies under a key whose fingerprint is revoked |
| `signature-key-unknown` | a pinned-key policy with no key pinned |
| `bundle-freshness-missing` | a schema 1 bundle, when this build pins a key |

* **This build pins no release key** (`stick/trust/pinned-keys.json` is `[]`; KI-23), so `--pubkey` is still the only key source and the
  commands say so. Once a key is pinned, the default is that key, `--pubkey` needs `--development-key` and is refused with `--device`, and a
  schema 1 bundle is refused. A new binary carries every pinned key and every revocation.
* **The sequence floor** is the highest `sequence` accepted per bundle `id`, kept in `floors.json` in the state directory:
  `--state-dir <dir>`, else `$CI_STICK_STATE_DIR`, else `$XDG_STATE_HOME/ci-stick` or `~/.local/state/ci-stick` (Linux),
  `~/Library/Application Support/ci-stick` (macOS), `%LOCALAPPDATA%\ci-stick` (Windows). It moves up only after a whole verification
  succeeded (in `verify`; in `flash` after the stick was written), never in `--dry-run` or `doctor`. A damaged `floors.json` is never reset:
  the command stops and names it. A `--device` write refuses when there is no usable state directory; a development `--image` flow warns.
* **`revoked.txt`** in the state directory (one key fingerprint per line, `#` comments) adds revocations before a new binary does. It can only
  add refusals, and a line that is not a fingerprint stops the command.
* For rehearsals use a throw-away directory, so the real floor stays where it is:
  `CI_STICK_STATE_DIR="$(mktemp -d)" ci-stick verify ./staging --pubkey ./dev.pub`.

### Models: lock, plan, fetch, cache-info

The model-pack catalog (`core/manifest/model-packs.yaml`) says what a stick should carry.
`models lock` asks the registry what those tags are *today* and records it in
`core/manifest/model-packs.lock.json`: manifest bytes and digest, layer digests and sizes, and
the llama.cpp/GGUF child of a tag the registry serves as a manifest list. Digests are never
typed by hand, and the file is canonical JSON, so a re-run that finds nothing new changes
nothing. `models fetch` seeds an Ollama-format model store from that lock: resumable,
verified, and safe to interrupt at any moment.

```bash
# Maintainers: resolve the catalog against the registry (needs the network), then review the diff
ci-stick models lock                          # writes core/manifest/model-packs.lock.json
ci-stick models lock --check                  # exit 3 if the registry or the catalog drifted

# Anyone: what would a pack cost, and does it fit?   (no network)
ci-stick models plan --pack stick-128 --cache /Volumes/CI-CACHE

# Download it (resumable; run the same command again after any interruption)
ci-stick models fetch --pack stick-128 --cache /Volumes/CI-CACHE
ci-stick models fetch --model nomic-embed-text --cache /Volumes/CI-CACHE   # one model from the lock
ci-stick models fetch --pack stick-128 --cache ... --max-bytes-per-sec 5MiB --concurrency 2
ci-stick models fetch --pack stick-128 --cache ... --events -    # JSON-lines progress on stdout

ci-stick models cache-info --cache /Volumes/CI-CACHE             # size, partials, free space, complete packs
```

The cache directory defaults to `$CI_STICK_CACHE`, the registry to `$CI_OS_REGISTRY_URL`
(else `https://registry.ollama.ai`); `HTTPS_PROXY` and `NO_PROXY` are honoured. Layout of a
cache (`OLLAMA_MODELS` is `<cache>/models`):

```
<cache>/models/blobs/sha256-<hex>                            the model, projector, licence ... (shared blobs once)
<cache>/models/manifests/registry.ollama.ai/library/<name>/<tag>   the registry's manifest, verbatim, written last
<cache>/models/manifests-v2/                                 empty on purpose (a read-only stick needs it to exist)
<cache>/ci-models/partial/<hex>-partial, ...-partial.journal resumable downloads, outside the directory Ollama prunes
<cache>/ci-models/status.json                                progress for the setup portal, rewritten atomically
```

* **Trust**: only references in the lock can be fetched; every blob must match its SHA-256 and
  size from the lock before it gets its final name; a manifest is written only after all
  of its blobs verified. The registry's presigned download URLs are never logged or stored.
  Redirects are followed by `ci-stick` itself: https only, at most 5 hops, a host outside
  `ollama.com`/`ollama.ai`/`hf.co`/`huggingface.co`/`cloudflarestorage.com` must resolve to a
  public address (no loopback, private, link-local, CGNAT ...).
* **Resume**: a partial is a file plus a journal that is `fsync`'d before it is updated. A killed
  process (even SIGKILL) loses at most the last 64 MiB; Ctrl-C and SIGTERM flush the journal and
  exit with 6. Resuming re-reads and re-hashes the vouched prefix, and a bad prefix costs one
  clean restart, never a corrupt blob.
* **Licences**: a model whose licence is `unverified` in the catalog is skipped (exit 5) unless
  you pass `--accept-licenses`; the other models of the pack are still fetched.
* **Space**: `plan`/`fetch` refuse (exit 4) when the pack is more than 97 % of the volume (the
  3 % rule of the pack catalog) or the bytes still to write exceed the free space; running out
  of space mid-download also exits 4 and keeps the partial.
* **exFAT**: no symlinks or hard links, no reliance on `chmod`, names checked for characters and
  reserved device names Windows cannot hold, case-folding collisions refused, `._*`
  AppleDouble and Finder files ignored.

Exit codes of these four commands: `0` ok, `1` error (not resumable), `2` usage error or
unreadable input, `3` `lock --check` found drift, `4` not enough space, `5` a licence was not
accepted, `6` interrupted or the network stayed down (partials kept, rerun to resume),
`7` integrity failure. `--events` lines, `status.json` and the full CLI contract are documented
at the top of `src/cmd_models.rs` and `src/events.rs`. This release handles Ollama registry
models; Hugging Face entries in the catalog are skipped by `lock` with a warning.

### Flashing

> **⚠ `flash --device` ERASES THE WHOLE DEVICE.** Always run `--dry-run` first and read
> the plan: node, model, serial and size are printed prominently. `ci-stick` only writes
> to removable or USB disks with nothing mounted and no swap, and it refuses the system
> disk. It opens the device exclusively and re-checks its identity right before the first
> write, but *you* are the last check. Device writes are Linux-only for now.

The stick boots with **Secure Boot enabled** when the bundle carries the signed chain
(shim → Canonical GRUB → Canonical-signed kernel), taken from Ubuntu's archive through
apt. The plan, `verify` and `doctor --bundle` all say which chain a bundle has.
`fetch-signed-boot.sh` also checks that the GRUB it fetched has every module the stick's
`grub.cfg` relies on built in (`CANONICAL_GRUB_BUILTIN_MODULES` in `bootcfg.rs`): under
Secure Boot GRUB loads nothing from disk, and the built-in set differs between Ubuntu
releases (26.04's has no `all_video` module, for instance).

```bash
# Tools (Debian/Ubuntu); no root needed for image files
sudo apt-get install gdisk dosfstools exfatprogs e2fsprogs mtools grub-efi-amd64-bin sbsigntool

# Bootloader, production: the Secure Boot chain (on Ubuntu 26.04; apt + sbverify checked)
stick/scripts/fetch-signed-boot.sh ./signed-boot      # + signed-boot.lock (versions, sha256)
cp ./signed-boot/{shimx64,grubx64,mmx64}.efi ./staging/efi/

# ...or, development only: an unsigned standalone GRUB (boots with Secure Boot OFF only;
# `flash --device` then also needs --allow-unsigned-bootloader). Stage one chain, not both.
stick/scripts/build-grub-efi.sh ./staging/efi/BOOTX64.EFI

# A sparse stick image (write it to a stick with any imaging tool)
ci-stick flash ./staging --pubkey ./dev.pub --image stick.img --size 64GB --dry-run
ci-stick flash ./staging --pubkey ./dev.pub --image stick.img --size 64GB

# A real stick (Linux, as root): dry run, check the plan, then confirm the node (+ serial)
sudo ci-stick flash ./staging --pubkey ./dev.pub --device /dev/disk/by-id/usb-XYZ --dry-run
sudo ci-stick flash ./staging --pubkey ./dev.pub --device /dev/disk/by-id/usb-XYZ \
    --confirm /dev/sdb --expect-serial 4C530001234

# A/B boot slot pointer (ci-stick/grubenv on the ESP)
ci-stick slot show --image stick.img
ci-stick slot set B --image stick.img
sudo ci-stick slot set A --device /dev/sdb --confirm /dev/sdb --expect-serial 4C530001234
```

What goes where:

- `CI-EFI`, Secure Boot chain: `EFI/BOOT/BOOTX64.EFI` (shim), `EFI/BOOT/grubx64.efi`,
  `EFI/BOOT/mmx64.efi`, the generated grub.cfg as `EFI/BOOT/grub.cfg` and
  `EFI/ubuntu/grub.cfg` (the two places Canonical's GRUB looks), and `ci-stick/grubenv`
  (`active_slot=A`). Development chain: `EFI/BOOT/BOOTX64.EFI`, `ci-stick/grub.cfg`,
  `ci-stick/grubenv`.
- `CI-BOOT-A` gets the bundle's boot image (an Ubuntu live ISO), written raw.
- `CI-BOOT-B` stays empty until an update.
- `CI-PERSIST` is ext4 with filesystem label `writable`, which is where casper keeps
  persistence.
- `CI-SHARED` and `CI-CACHE` are formatted empty. Their contents arrive in slice 4.

`--allow-unsigned` and `--slot-b-from` are for `--image` targets only, and
`--extra-cmdline` (e.g. `console=ttyS0,115200`) is for tests. After a write,
`ci-stick` reads the GPT, both slots and every filesystem extent back and verifies them.

### QEMU boot test

```bash
stick/tests/qemu/run.sh     # needs qemu-system-x86 ovmf xorriso busybox-static cpio zstd too
```

It flashes a sparse 64 GB image from a casper-shaped test ISO and boots it three times as
a USB stick under UEFI: slot A, a reboot (persistence), then slot B after `slot set B`.
It also checks the safety refusals, and it prints a PASS/FAIL summary. It uses KVM when
`/dev/kvm` is usable and TCG otherwise. `cargo test -- --ignored qemu_boot_harness` runs
the same script. It uses the unsigned development chain, like CI. CI runs it in a privileged `ubuntu:26.04` container, so the
tools and the kernel it boots are the target release's; the recorded run on that userland passed all its checks (17 lines in the summary).

### Test Secure Boot on your Mac

Local only: no GitHub workflow runs Secure Boot tests. Apple Silicon and Intel both work,
because the PC is emulated.

```bash
# once
brew install --cask docker && open -a Docker    # wait until Docker Desktop is running
brew install qemu

# from the repo root: build in Docker, then boot A/B/C with Homebrew QEMU (~10–30 min on
# Apple Silicon the first time; re-runs reuse the cached toolchain)
stick/tests/secureboot/run-on-mac.sh
stick/tests/secureboot/run-on-mac.sh --show          # watch each boot in a window
stick/tests/secureboot/run-on-mac.sh --skip-build    # boot again without rebuilding

# a real Ubuntu (or Companion OS) ISO in slot A, Secure Boot on, in a window (~8 GB free, slow
# under TCG): check `mokutil --sb-state` says enabled, and that files survive a reboot
stick/tests/secureboot/run-on-mac.sh --iso ~/Downloads/ubuntu-26.04.1-desktop-amd64.iso
```

It checks **A** Secure Boot on + signed chain boots (`secureboot=1`, slot A, then boot
count 2 after a reboot), **B** Secure Boot on + unsigned chain is refused by the firmware
before any kernel runs, and **C** Secure Boot off + signed chain still boots
(`secureboot=0`). Then it prints a PASS/FAIL table. Serial logs and results go to
`stick/tests/secureboot/out/run/`, which is gitignored. On Linux the same script works;
an Ubuntu 26.04 host builds without Docker. Behind a TLS-intercepting proxy, add
`--ca-bundle <pem>`. `--skip-build` refuses an `out/` that was built for another Ubuntu
series.

The build runs in a `linux/amd64` `ubuntu:26.04` container. Known limit: on Docker
Desktop for Apple Silicon with Rosetta emulation (seen with Docker Desktop 29 on macOS 27),
Ubuntu 26.04's GNU `tar` cannot create files inside a directory it has just created
("Function not implemented"; bsdtar and Python's `tarfile` work there), so `dpkg-deb -x`
fails. `build-in-container.sh` checks this first and stops with a message instead of
failing later. The trigger was not isolated (another amd64 `ubuntu:26.04` container ran `installed-boot.sh --no-boot` to the end on 2026-10-18), so treat amd64 on this setup as "may fail": run the build half on an x86_64 Ubuntu 26.04 machine.
`fetch-signed-boot.sh` alone also runs in an arm64 `ubuntu:26.04` container whose apt is
pointed at the amd64 archive through an `APT_CONFIG` file (`APT::Architecture "amd64"`, the
archive's own sources, a separate `Dir::State`), because it only downloads and unpacks; the
rest of the build half (amd64 busybox, GRUB modules and kernel) is not scripted for that case.

### Staging layout

A file's top-level directory determines its artifact `kind`: `boot/` → `boot-image`,
`installers/` → `installer`, `oci/` → `oci-image`, `models/` → `model-blob`, `docs/` →
`doc`, `tools/` → `tool`, `efi/` → `bootloader` (platform `x86_64-uefi`, and a
`bootloader_role` from the name: `shimx64.efi`/`grubx64.efi`/`mmx64.efi` are the Secure
Boot chain, `BOOTX64.EFI` the development chain; anything else, both chains at once or a
partial Secure Boot chain is refused). If any path component is a platform id (`linux-x86_64`,
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
    trust.rs  state.rs          pinned keys + revocations (stick/trust/*.json); state directory, sequence floors
    paths.rs                    relative-path rules (no escapes)
    packs.rs                    model-pack catalog + fit logic
    cmd_models.rs               models plan | lock | fetch | cache-info (CLI contract in its header)
    net.rs                      HTTP transport trait (ureq), URL + redirect/SSRF policy, retry timing
    registry/                   Ollama registry client: references, manifests, tag -> lock entry
    lockfile.rs                 model-packs.lock.json types, validation, canonical JSON
    fetch/                      plan, resumable verified downloads, workers, throttle
    cache/                      cache layout + name rules, store, resume journal, BlobSink
    events.rs                   JSON-lines events and status.json
    devices.rs  host.rs         read-only device listing; host capability matrix
    doctor.rs  progress.rs  timefmt.rs
    flash.rs                    verify -> plan -> build filesystems -> write -> read back
    target.rs                   image/device targets + the device safety rules
    gpt.rs  sparse.rs  tools.rs sgdisk args + GPT read-back; sparse copy; external tools
    grubenv.rs  bootcfg.rs      A/B pointer (GRUB env block); grub.cfg from the layout
    slot.rs                     slot show / set
  crates/ci-stick/templates/    grub.cfg template
  crates/ci-stick/tests/        CLI end-to-end, flash-to-image, schema drift, trust (sequence floor, expiry, revocation), model catalog,
                                lock, fetch and resume tests, and the opt-in live-registry test (models_live.rs)
  .cargo/config.toml            MSRV-aware dependency resolution (see "Adding a dependency or bumping the lock")
  scripts/fetch-signed-boot.sh  Secure Boot chain (shim, Canonical GRUB, MokManager) via apt
  scripts/grub-builtin-modules.py  modules built into a signed GRUB image (fetch-signed-boot.sh checks them)
  scripts/build-grub-efi.sh     standalone GRUB EFI (development chain, not signed)
  scripts/usb-inventory-macos.py  read-only inventory of the USB disks on a Mac, by serial (mass-flashing.md, section 8.7)
  tests/qemu/                   QEMU boot harness (run.sh, build-test-boot-image.sh), Docker-in-a-live-session tests (docker-live.sh,
                                guest-docker-test.sh) and the mac80211_hwsim hotspot test (hotspot-hwsim.sh, guest-hotspot-test.sh,
                                README-hotspot.md)
  tests/secureboot/             local Secure Boot harness (run-on-mac.sh, build-in-container.sh; not in CI)
  schema/bundle.schema.json     published JSON Schema (mirror of manifest.rs; schema_version 1 and 2)
  schema/examples/              canonical example bundle.json files (schema 1, schema 1 with a Hugging Face model, schema 2)
  trust/pinned-keys.json        release keys compiled into the binary (empty: KI-23)
  trust/revoked.json            revoked key fingerprints compiled into the binary (empty)
```

Rust is first-class inside `stick/` only. `core/` and the shell backends must never
depend on it.
