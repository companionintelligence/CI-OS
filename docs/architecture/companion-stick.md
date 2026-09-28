# Companion Stick architecture

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Companion Stick turns CI-OS into a product that fits in a pocket: one large USB stick
(target: 512 GB) that boots Companion OS, installs the Companion Intelligence stack onto
a machine that is already running an OS, carries the curated models offline, and updates
itself safely.

`backends/` stays the place where OS images are built (one adapter per distro). The
product itself is a Rust CLI, **`ci-stick`**, in [`stick/`](../../stick/README.md). It
builds, verifies, flashes, installs from and updates sticks. It uses the image backends
and the contracts that CI Hub and CI Memory publish; it does not reimplement them.

## What the stick does

| # | Function | How |
|---|----------|-----|
| 1 | **Boot Companion OS (live)** | UEFI boots an immutable image from the active A/B slot, with persistence. Companion Ubuntu first; Fedora, Arch and Debian follow later as separately tested images. |
| 2 | **Install onto a running host** (macOS / Windows / Linux) | The user runs the signed launcher on `CI-SHARED` themselves, and it asks for admin consent. It installs CI Hub, CI Memory and the chosen model packs. Nothing runs automatically. |
| 3 | **Carry models offline** | Signed model packs sit in a content-addressed cache and import with no network. |
| 4 | **Update itself** | Signed, resumable, atomic A/B updates with rollback, run by `ci-stick` on the stick. |

## Commands

| Command | Status | Purpose |
|---------|--------|---------|
| `ci-stick lock <dir>` | **done** | Hash a staging tree and write a deterministic `bundle.json` |
| `ci-stick verify <root>` | **done** | Check the signature (fails closed), then each artifact's size and SHA-256, path escapes and untracked files |
| `ci-stick layout plan --size` | **done** | Work out the GPT plan for a device size, as a pure function |
| `ci-stick models list [--fits\|--device]` | **done** | List the model packs and which ones fit a cache |
| `ci-stick doctor` | **done** | Read-only report on host support, candidate devices and an optional quick bundle check |
| `ci-stick dev keygen / dev sign` | **done** | Development keys and signing only; release keys never touch this path |
| `ci-stick build` | planned | Call `backends/<distro>` image builds and stage the bundle |
| `ci-stick flash` | **done** | Verify, then partition and write a stick or a sparse stick image from the layout plan |
| `ci-stick slot show / set` | **done** | Read or flip the A/B pointer (`active_slot` in the ESP's grubenv) |
| `ci-stick install` | planned (4) | Install Hub, Memory and models onto the host with consent |
| `ci-stick models sync / import / lock` | planned (4) | Fill the cache, import packs into Hub and resolve digests |
| `ci-stick update` | planned (5) | Signed A/B updater with rollback |

Exit codes for every command: `0` means OK, `1` means verification failed, `2` means a
usage or I/O error. Every command that reports something also accepts `--json`.

## Partition layout (`ci-stick-layout/1`)

The plan is a pure function of device size (`stick/crates/ci-stick/src/layout.rs`). It is
unit-tested across sizes, and `bundle.json` records it so each bundle states the geometry
it was built for. Here is the plan for a marketed 512 GB stick (≈ 476.8 GiB usable):

| # | Label | FS | Size | Purpose |
|---|-------|----|------|---------|
| 1 | `CI-EFI` | vfat | 2 GiB | ESP: bootloader, `ci-stick/grub.cfg` and the A/B pointer (`ci-stick/grubenv`) |
| 2 | `CI-SHARED` | exFAT | 29 GiB | Launchers, installers and docs, readable on every host |
| 3 | `CI-BOOT-A` | raw image | 47 GiB | Immutable boot image, slot A |
| 4 | `CI-BOOT-B` | raw image | 47 GiB | Immutable boot image, slot B |
| 5 | `CI-CACHE` | exFAT | 304 GiB | Content-addressed OCI images and model blobs |
| 6 | `CI-PERSIST` | ext4, fs label `writable` | ≈ 47.8 GiB | Live persistence, logs and updater state (takes the remainder) |

**Sizing rules.** The ESP is 1 GiB below 150 GiB usable and 2 GiB above that. Shared is
usable/16, clamped to 4–32 GiB. Each boot slot is usable/10, clamped to 8–48 GiB.
Persistence targets about 13.5 % of what remains (8–128 GiB), and the cache gets the rest
in whole GiB. The cache is the part that grows: a 2 TB stick gives most of its extra
space to models.

| Device | ESP | Shared | Boot (A+B) | Cache | Persist |
|--------|-----|--------|------------|-------|---------|
| 57 GiB (minimum) | 1 | 4 | 2 × 8 | 27 | ~9 |
| 128 GB | 1 | 7 | 2 × 11 | 77 | ~12.2 |
| 256 GB | 2 | 14 | 2 × 23 | 152 | ~24.4 |
| 512 GB | 2 | 29 | 2 × 47 | 304 | ~47.8 |

Devices below **57 GiB** are refused. A nominal "64 GB" stick reports 57.5–59.6 GiB,
depending on the vendor. Run `ci-stick layout plan --size <X>` to get exact numbers.

**Why this shape.**

- **The ESP comes first and stays small.** Every UEFI firmware finds it there. It holds
  only the bootloader and a tiny slot pointer, so an A/B switch is a single small write.
- **`CI-SHARED` is the first data partition, formatted exFAT.** macOS and Windows mount it
  without drivers, and Windows has always handled the first basic-data partition on a
  removable disk best. This is where the user finds the launcher, so it can't be ext4.
- **Boot slots hold raw images, not filesystems we edit.** An update writes the complete
  new image into the inactive slot, checks it against the signed digest, and only then
  flips the pointer in the ESP. A slot is never modified in place, so an interrupted
  update leaves the old slot bootable. Because the updater writes whole images, it needs
  no filesystem driver for the slot, which lets a macOS or Windows host update the stick.
- **`CI-CACHE` is exFAT and content-addressed.** Blobs are named by digest
  (`sha256-<hex>`) with no symlinks. That makes them readable from any host during a
  host install, and it de-duplicates models that several packs share. Most of the space
  goes here, because models are most of the payload.
- **`CI-PERSIST` comes last and takes the remainder.** It is only used when the stick is
  booted, so ext4 is fine. Keeping it last means it absorbs rounding slack, and a future
  "grow to fill" operation only has to touch one partition.

## Bundle format and trust model

A bundle is a directory tree with this layout: `boot/`, `installers/`, `oci/`, `models/`,
`docs/` and `tools/` at the top, plus `bundle.json` and `bundle.json.sig`.

- **Manifest.** `bundle.json` records `schema_version`, `id`, `version`, `created_at`,
  `artifacts[]` (path, kind, sha256, size, optional platforms), `model_packs[]` and
  `layout`. The Rust types in `stick/crates/ci-stick/src/manifest.rs` are the source of
  truth. The published mirror is
  [`stick/schema/bundle.schema.json`](../../stick/schema/bundle.schema.json), and tests
  fail if the two disagree. Unknown fields and unknown `schema_version` values are
  rejected, never half-parsed.
- **Signature.** `bundle.json.sig` is a detached **ed25519** signature over the exact
  bytes of `bundle.json`, checked with `verify_strict`. Because `lock` writes canonical
  JSON (fixed field order, sorted artifacts, stable formatting), a rebuild from identical
  inputs produces an identical signature payload.
- **Pinned keys.** For now, `verify` requires `--pubkey`. Release public keys will be
  compiled into `ci-stick` and rotated through signed key-rotation statements. Release
  signing happens in the release pipeline; `ci-stick dev sign` exists only for
  development and tests.
- **Fail closed.** `verify` checks the signature first. If it is missing, malformed or
  wrong, the tool stops without hashing anything and without reporting the manifest's
  claims as trusted. `--allow-unsigned` must be passed explicitly and prints a loud
  warning. Even with that flag, a signature that is present but invalid still fails.
- **Artifact integrity.** Each path must be a plain relative path (no `..`, absolute paths,
  backslashes or colons). No symlink is followed anywhere along a path, since exFAT can't
  store symlinks and finding one means tampering. The canonical target must stay under the
  root. Sizes and streamed SHA-256 must match. Files the manifest doesn't list are
  reported as warnings.
- **Bootloader.** `efi/BOOTX64.EFI` is an artifact of kind `bootloader` (platform
  `x86_64-uefi`, taken from the UEFI file name), so the bootloader is covered by the same
  signature as everything else.
- **Planned trust extensions:** per-pack signatures, a signed update metadata chain with
  rollback protection (TUF-style version and expiry), and Secure Boot shim signing for
  boot images.

## Host-install consent model

- **The stick never auto-runs anything.** It ships no `autorun.inf`, no macOS login items
  and no udev rules that execute code. The user starts the platform launcher from
  `CI-SHARED` explicitly.
- The launcher is code-signed for its platform (Developer ID and notarisation on macOS,
  Authenticode on Windows). Before it touches anything, it runs `ci-stick verify` against
  the pinned key.
- The launcher shows what it will install (Hub, Memory, which packs, disk and RAM needs,
  and licences) and then asks for OS-native admin consent: an Authorization prompt, UAC or
  polkit/sudo. Declining makes no changes.
- Installs are reversible, and the stick keeps an install record on `CI-PERSIST` or the
  host so that uninstall and repair know what was added.

## Model-pack policy

- "All models" has no upper bound, so sticks carry **curated packs**: `starter`,
  `balanced`, `coding`, `vision` and `large`. Each model entry pins `name:tag`, `digest`,
  quantization, licence, `size_bytes`, `min_ram_gb`, `min_vram_gb` (null means it runs on
  CPU or unified memory) and supported platforms.
- The source is
  [`core/manifest/model-packs.yaml`](../../core/manifest/model-packs.yaml). It is
  **provisional** and will be generated from CI Hub's curated catalog once that catalog is
  published. Every model that `ecosystem.yaml` pre-pulls must appear in some pack, and a
  test enforces this.
- `digest` stays `null` until a `models lock` step resolves it from the registry. Digests
  are never typed by hand. A release bundle will require every digest to be resolved.
- Sizes are approximate until they are resolved. `ci-stick models list --device 512GB`
  shows what fits. Today, all packs together come to ≈ 284 GB, which fits the 512 GB
  layout's 304 GiB cache.
- Each licence travels with its model. The launcher shows licences before import, and any
  entry marked `unverified` blocks a release.

## Consuming Hub, Memory and model contracts

The stick is a delivery vehicle. It does not own the marketplace.

| Concern | Owner | What the stick does |
|---------|-------|---------------------|
| Marketplace and app installs | **CI Hub** | Carries Hub's OCI image and installer, then hands off to Hub |
| CI Memory | **Hub's first-party `ci-memory` contract** | Asks Hub to install Memory through that contract; it never installs Memory directly |
| Models | **`cihub models install`** or backend adapters | Imports cached blobs by digest through Hub, or through a backend adapter when Hub isn't present (for example, a bare live boot) |
| What a pack contains | **Hub's curated catalog** (eventually) | Reads it; the local YAML is a stand-in until then |

If a contract is missing, `ci-stick` should report it and stop. It must not grow a
parallel implementation.

## Relationship to `backends/`

`backends/<distro>/` keep building OS images (Ubuntu's `build-iso.sh` today). `ci-stick
build` will call them, place their outputs under `boot/` in a staging tree, and `lock`
and sign the result. `core/manifest/ecosystem.yaml` remains the source of truth for what
a booted Companion OS provisions. The stick only adds packaging, trust and delivery.
Rust is first-class inside `stick/` only, the same way Nix is inside `backends/nixos/`.
`core/` and the shell backends must never require it.

## Flashing (slice 3)

`ci-stick flash <bundle> --pubkey <key> (--image <file> --size <size> | --device <dev>)`
(`stick/crates/ci-stick/src/flash.rs`). Every step refuses before anything is written if
it fails.

1. **Verify first.** The bundle goes through `verify` with full hashing. A signature is
   required. `--allow-unsigned` is accepted only for `--image` targets and refused with
   `--device`. A failed verification exits 1 and writes nothing.
2. **Plan.** Resolve the target, compute the layout for its size (not the size the bundle
   was locked for, though the policy must match), pick the `boot-image` and the
   `bootloader`, and check that the image fits its slot. `--dry-run` prints the target's
   identity, the layout table and what goes into each partition, then stops.
3. **Build without root.** Every filesystem is created in a sparse temporary file:
   `mkfs.vfat -F 32 -n CI-EFI` (populated with `mmd`/`mcopy`, no mounting),
   `mkfs.exfat -L CI-SHARED` / `CI-CACHE`, and `mkfs.ext4 -L writable -E
   nodiscard,lazy_itable_init=1` for persistence.
4. **Write.** Zero the first and last MiB, run `sgdisk --zap-all`, then run `sgdisk` with
   the plan's exact first and last sectors. The GPT partition names are the layout labels,
   and the type GUIDs are EFI System, Microsoft basic data (exFAT) and Linux filesystem
   (boot slots and persistence). Only the data extents of each filesystem image are
   copied (`SEEK_DATA`/`SEEK_HOLE`). The boot image is streamed raw into `CI-BOOT-A`,
   hashed as it goes. `CI-BOOT-B` gets a zeroed first MiB.
5. **Read back.** After `fsync` (and dropping the page cache for devices), the GPT must
   parse, pass both CRCs, match the plan entry for entry, and be byte-identical to what
   `sgdisk` wrote. Each slot must hash to its manifest digest, and every filesystem
   extent must compare equal.

Copying only data extents is safe on a stick with old contents because none of the mkfs
tools discard: anything a filesystem relies on being zero was written by mkfs, so it is
data, not a hole. Zero blocks are skipped only when the destination is a freshly created
image file.

**Device safety model** (`target.rs`, pure functions unit-tested over lsblk, mountinfo
and swaps fixtures):

- The disk must be one of `doctor`'s removable or USB candidates. That rules out the
  system disk, and loop, zram, dm, md, nbd and optical devices are refused by name as
  well.
- No partition may be mounted. This is checked by comparing `major:minor` of the disk and
  each partition against `/proc/self/mountinfo`, never by name. The disk must also hold
  no swap (`/proc/swaps`) and have no holders (dm, md or LVM).
- The disk must be at least the layout minimum.
- A `/dev/disk/by-*` path is resolved, and the real node is always shown.
- A write needs `--confirm <node exactly as shown>`, and also `--expect-serial` when the
  device reports a serial. The node is opened with `O_EXCL`, so the kernel refuses if
  anything has it mounted or claimed. Immediately before the first write, the size,
  model, serial and `major:minor` are re-read from sysfs and compared with the plan, to
  catch re-enumeration or a different stick.
- `--slot-b-from` writes unsigned content into a slot, so it is accepted with `--image`
  only (tests use it).

**Boot chain and A/B.** `stick/scripts/build-grub-efi.sh` builds a standalone GRUB. Its
embedded config finds the ESP it was loaded from (through `$cmdpath`, with a
`search --label CI-EFI` fallback) and runs `configfile` on `ci-stick/grub.cfg`. `flash`
renders that file from a template in the crate, and the slot partition numbers come from
`layout.rs`. The config derives the disk from `$cmdpath` rather than assuming `hd0`,
runs `load_env` on `ci-stick/grubenv`, and offers the active slot first and the other
slot as a fallback:

```
linux  ($disk,gpt3)/casper/vmlinuz boot=casper live-media=/dev/disk/by-partlabel/CI-BOOT-A persistent ci_stick.slot=A quiet splash $extra_cmdline ---
initrd ($disk,gpt3)/casper/initrd
```

`grubenv` is GRUB's own 1024-byte environment block, generated in Rust. It holds
`active_slot=A|B` and an optional `extra_cmdline`, which tests set to `console=ttyS0,…`
and production leaves empty. `ci-stick slot set B` rewrites only that 1 KiB file,
through mtools at the ESP's offset, under the same device rules as `flash`.
**Persistence** is the ext4 filesystem labelled `writable` on `CI-PERSIST`. Ubuntu's
casper finds it by that label, and the GPT partition name stays `CI-PERSIST`. Both slots
share it.

**Tests.**

- `cargo test` covers grubenv round trips and the exact format, grub.cfg rendering, GPT
  arguments and parsing (CRCs), sparse-copy correctness, every device-refusal rule, and
  a real `flash` plus `slot set` against a 64 GB sparse image. That last test is skipped,
  with a note, when the gdisk, dosfstools, exfatprogs, e2fsprogs or mtools tools are
  missing.
- `stick/tests/qemu/run.sh` runs as the `stick-qemu` job in PR checks. It builds a tiny
  casper-shaped test ISO: a real Ubuntu kernel plus a busybox initrd whose `/init`
  reports its slot and `ci_stick.slot`, then increments `/boot-count` on the `writable`
  filesystem. It flashes a sparse 64 GB image and boots it three times in QEMU as a USB
  mass-storage device under OVMF. Boot 1 must report slot A with count 1, boot 2 must
  report count 2, and after `slot set B`, boot 3 must report slot B with count 3. The
  production grub.cfg is used unchanged. The same script checks that a tampered bundle,
  `--allow-unsigned` with `--device`, a regular file and a non-removable disk are all
  refused without writes.
- `.github/workflows/stick-real-iso.yml` is manual. It checks the Ubuntu 24.04 desktop
  ISO against SHA256SUMS, whose GPG signature must verify against Ubuntu's CD signing
  key, then flashes and boots the ISO to casper.

**Known limitations** (next slices):

- **No Secure Boot.** `BOOTX64.EFI` is not signed, so Secure Boot has to be disabled.
  Booting through a Microsoft-signed shim and a signed GRUB is an explicit follow-up.
- `CI-SHARED` and `CI-CACHE` are formatted empty. Populating them (launchers, docs, OCI
  images and models) is slice 4. exFAT can't be written without root or mounting, so
  there is no README yet either.
- Device writes are Linux-only. On macOS and Windows, `flash --device` and `slot --device`
  say "not supported yet". To use another OS, write an image with `--image` and flash it
  with that OS's tools.
- The real-ISO boot test is manual. It is not part of PR checks, and it has not yet been
  run on real hardware.
- Replacing grubenv with mtools is not an atomic update. The signed A/B updater (slice 5)
  owns atomic pointer flips and rollback.

## Delivery sequence

1. Security closure (tracked separately).
2. **Bundle schema, lockfile, `verify` and read-only `doctor`. ✅**
3. **Safe Ubuntu x86_64 flashing, persistence and QEMU boot tests. ✅**
4. Offline Hub/Memory payload install and model import.
5. Signed A/B updater with rollback.
6. Other distros (Fedora, Arch, Debian) and ARM64.

### Still out of scope after slice 3

- Nothing mounts or unmounts anything; `flash` refuses mounted devices instead.
- **No host install**, and no launcher yet.
- **No updater** (manual `slot set` only) and no key rotation.
- **No `build`.** Staging trees are assembled by hand or by scripts for now.
- **No digest resolution** (`models lock`), and no Windows device listing (`doctor` says
  "not supported yet").
