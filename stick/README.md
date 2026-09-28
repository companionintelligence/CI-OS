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

Exit codes: `0` ok, `1` verification failed, `2` usage or I/O error, or a safety refusal.

### Flashing

> **⚠ `flash --device` ERASES THE WHOLE DEVICE.** Always run `--dry-run` first and read
> the plan: node, model, serial and size are printed prominently. `ci-stick` only writes
> to removable or USB disks with nothing mounted and no swap, and it refuses the system
> disk. It opens the device exclusively and re-checks its identity right before the first
> write, but *you* are the last check. Device writes are Linux-only for now.

The stick boots with **Secure Boot enabled** when the bundle carries the signed chain
(shim → Canonical GRUB → Canonical-signed kernel), taken from Ubuntu's archive through
apt. The plan, `verify` and `doctor --bundle` all say which chain a bundle has.

```bash
# Tools (Debian/Ubuntu); no root needed for image files
sudo apt-get install gdisk dosfstools exfatprogs e2fsprogs mtools grub-efi-amd64-bin sbsigntool

# Bootloader, production: the Secure Boot chain (on Ubuntu 24.04; apt + sbverify checked)
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
the same script. It uses the unsigned development chain, like CI.

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

# a real Ubuntu (or CI-OS) ISO in slot A, Secure Boot on, in a window (~8 GB free, slow
# under TCG): check `mokutil --sb-state` says enabled, and that files survive a reboot
stick/tests/secureboot/run-on-mac.sh --iso ~/Downloads/ubuntu-24.04.4-desktop-amd64.iso
```

It checks **A** Secure Boot on + signed chain boots (`secureboot=1`, slot A, then boot
count 2 after a reboot), **B** Secure Boot on + unsigned chain is refused by the firmware
before any kernel runs, and **C** Secure Boot off + signed chain still boots
(`secureboot=0`). Then it prints a PASS/FAIL table. Serial logs and results go to
`stick/tests/secureboot/out/run/`, which is gitignored. On Linux the same script works;
an Ubuntu 24.04 host builds without Docker. Behind a TLS-intercepting proxy, add
`--ca-bundle <pem>`.

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
    paths.rs                    relative-path rules (no escapes)
    packs.rs                    model-pack catalog + fit logic
    devices.rs  host.rs         read-only device listing; host capability matrix
    doctor.rs  progress.rs  timefmt.rs
    flash.rs                    verify -> plan -> build filesystems -> write -> read back
    target.rs                   image/device targets + the device safety rules
    gpt.rs  sparse.rs  tools.rs sgdisk args + GPT read-back; sparse copy; external tools
    grubenv.rs  bootcfg.rs      A/B pointer (GRUB env block); grub.cfg from the layout
    slot.rs                     slot show / set
  crates/ci-stick/templates/    grub.cfg template
  crates/ci-stick/tests/        CLI end-to-end, flash-to-image, schema drift tests
  scripts/fetch-signed-boot.sh  Secure Boot chain (shim, Canonical GRUB, MokManager) via apt
  scripts/build-grub-efi.sh     standalone GRUB EFI (development chain, not signed)
  tests/qemu/                   QEMU boot harness + casper-shaped test boot image
  tests/secureboot/             local Secure Boot harness (run-on-mac.sh; not in CI)
  schema/bundle.schema.json     published JSON Schema (mirror of manifest.rs)
  schema/examples/              canonical example bundle.json
```

Rust is first-class inside `stick/` only. `core/` and the shell backends must never
depend on it.
