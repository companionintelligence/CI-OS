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
| `ci-stick models lock / plan / fetch / cache-info` | **done** for Ollama models (4) | Resolve digests into a lock file, then fill the cache from it, resumably and hash-verified ([models-tooling.md](models-tooling.md)) |
| `ci-stick models verify / gc / export / import / view`, Hugging Face models | planned (4) | Audit and clean a cache, carry signed offline packs, build the symlink view for Hugging Face-layout tools |
| `ci-stick update` | planned (5) | Signed A/B updater with rollback |

Exit codes for every command: `0` means OK, `1` means verification failed, `2` means a
usage or I/O error. Every command that reports something also accepts `--json`. The
`models` commands add `3` (drift found by `lock --check`), `4` (not enough space), `5` (a
licence was not accepted), `6` (interrupted or network lost; partials are kept, run again) and
`7` (a hash or size did not match).

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
| 128 GB (exactly 128e9 B) | 1 | 7 | 2 × 11 | 77 | ~12.2 |
| 123.9 GB (the "128 GB" sticks on the desk, 123,942,731,776 B) | 1 | 7 | 2 × 11 | 73 | ~12.4 |
| 256 GB | 2 | 14 | 2 × 23 | 152 | ~24.4 |
| 512 GB | 2 | 29 | 2 × 47 | 304 | ~47.8 |

Devices below **57 GiB** are refused. A nominal "64 GB" stick reports 57.5–59.6 GiB,
depending on the vendor, and a nominal "128 GB" stick can report 3 % less than 128e9 B
(the sticks used for the first batch report 123,942,731,776 B and get a 73 GiB cache, not
77). Run `ci-stick layout plan --size <exact bytes>` to get exact numbers; never size model
packs from the marketing figure.

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
- **Bootloader.** Bootloader binaries under `efi/` are artifacts of kind `bootloader`
  (platform `x86_64-uefi`) with a `bootloader_role` taken from the file name:
  `shimx64.efi` (`shim`), `grubx64.efi` (`grub`), `mmx64.efi` (`mok-manager`) form the
  Secure Boot chain; `BOOTX64.EFI` (`standalone-grub`) is the unsigned development chain.
  A bundle carries exactly one complete chain (see [Secure Boot](#secure-boot)). The
  bootloader is covered by the same signature as everything else.
- **Planned trust extensions:** per-pack signatures, and a signed update metadata chain
  with rollback protection (TUF-style version and expiry).

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
  `balanced`, `coding`, `vision` and `large`, the two 128 GB packs below, and
  `appliance-core` (the three models `ecosystem.yaml` pre-pulls). Each model entry pins
  `name:tag`, `digest`, quantization, licence, `size_bytes`, `min_ram_gb`, `min_vram_gb`
  (null means it runs on CPU or unified memory) and supported platforms. A Hugging Face
  GGUF model is the same record, spelled `hf.co/<org>/<repo>` with the quantization label as
  `tag`; the schema and `schema_version` do not change for it.
- The source is
  [`core/manifest/model-packs.yaml`](../../core/manifest/model-packs.yaml). It is
  **provisional** and will be generated from CI Hub's curated catalog once that catalog is
  published. Every model that `ecosystem.yaml` pre-pulls must appear in some pack, and a
  test enforces this.
- `digest` stays `null` until a `models lock` step resolves it from the registry. Digests
  are never typed by hand. A release bundle will require every digest to be resolved. What the
  registries said (manifest bytes, layer digests, sizes, Hugging Face commits) is recorded in the
  generated `core/manifest/model-packs.lock.json` (to be committed); the YAML's `size_bytes` is a copy of it,
  and a test fails on a one-byte difference once the lock exists
  ([models-tooling.md](models-tooling.md), section 4).
- `size_bytes` is the exact byte size the Ollama registry lists (config plus layers), read
  on a given date; registry tags are mutable, so the digest-pinning `models lock` step is
  what makes a bundle reproducible. `ci-stick models list --device 512GB` shows what fits.
  Today, all packs together come to ≈ 320 GB, which fits the 512 GB layout's 304 GiB cache.
- **128 GB sticks:** the `stick-128` pack (21 ranked models, 74.4 GB) fills the 73 GiB
  cache of a 123.9 GB stick with 5 % to spare; `stick-128-oci` (19 models, 59.2 GB) keeps
  15 GiB for OCI images. Why these models, the licences and the rejected list:
  [model-packs-128gb.md](model-packs-128gb.md).
- **Cache layout and Ollama.** The cache is an Ollama model store rooted at
  `<CI-CACHE>/models/` (`blobs/sha256-<hex>`, `manifests/registry.ollama.ai/library/<name>/<tag>`),
  with OCI images under `<CI-CACHE>/oci/`. A booted Companion OS points Ollama at it
  (`OLLAMA_MODELS`, `OLLAMA_NOPRUNE=1`) through `ollama-models-env`
  ([tier-b-tools.md](tier-b-tools.md), section 5). Ollama deletes unreferenced files under
  `blobs/` at start-up unless `OLLAMA_NOPRUNE` is set, so never put other files there.
  exFAT has no symlinks or permissions (ownership comes from mount options). When a stick
  is populated from macOS, copy with `COPYFILE_DISABLE=1` and run `dot_clean`, or the
  AppleDouble `._*` files inside `manifests/` are read as manifests named `._latest`.
  It is **one** content-addressed store for every consumer: partial downloads and files
  Ollama must not see live in a sibling `<CI-CACHE>/ci-models/`, and Hugging Face-layout tools (which
  need symlinks) read a small symlink view built on a Linux-native filesystem instead of a second
  copy ([models-tooling.md](models-tooling.md), section 7).
- Each licence travels with its model. The launcher shows licences before import, and any
  entry marked `unverified` blocks a release. `core/manifest/licenses.yaml` maps every licence a pack
  names to its SPDX id, terms URL and gate (Gemma and Llama terms need a recorded acceptance; Apache-2.0 and
  MIT do not) and holds the explicit `release_blocking` list; a test fails if a pack names a licence that
  is not in it.

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

**Boot chain and A/B.** Real sticks boot through shim and Canonical's signed GRUB (see
[Secure Boot](#secure-boot)). For development and CI, `stick/scripts/build-grub-efi.sh`
builds an unsigned standalone GRUB instead. Its embedded config finds the ESP it was
loaded from (through `$cmdpath`, with a `search --label CI-EFI` fallback) and runs
`configfile` on `ci-stick/grub.cfg`. Both chains read the same `grub.cfg`, which `flash`
renders from a template in the crate; the slot partition numbers come from
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

- Secure Boot works through shim for Ubuntu images; see its own limitations under
  [Secure Boot](#secure-boot).
- `CI-SHARED` and `CI-CACHE` are formatted empty. Populating them (launchers, docs, OCI
  images and models) is slice 4; the model half has its tool now: the daemon-free
  `ci-stick models fetch` fetches manifests and blobs from the registry, verifies size and
  sha256, and writes the manifest last, into any directory, but it has not been run against a
  real exFAT volume or a real Ollama 0.40 daemon (a prototype was proven against the public
  registry and a 0.33 daemon; see [model-packs-128gb.md](model-packs-128gb.md), section 5.4,
  and [models-tooling.md](models-tooling.md)). exFAT can't be written without root or
  mounting, so a host without that has to fill a directory and copy it, and there is no
  README yet either.
- Mass flashing (several sticks at once, intake capacity test, per-stick identity,
  independent verification) has no tooling yet: [mass-flashing.md](mass-flashing.md).
- Device writes are Linux-only. On macOS and Windows, `flash --device` and `slot --device`
  say "not supported yet". To use another OS, write an image with `--image` and flash it
  with that OS's tools.
- The real-ISO boot test is manual. It is not part of PR checks, and it has not yet been
  run on real hardware.
- Replacing grubenv with mtools is not an atomic update. The signed A/B updater (slice 5)
  owns atomic pointer flips and rollback.

## Secure Boot

Companion Stick boots on PCs with UEFI Secure Boot **enabled**, through the same signed
chain Ubuntu's own install media uses. We add no keys of our own and need no MOK
enrollment for Ubuntu images.

```
firmware db (Microsoft Corporation UEFI CA 2011)
  -> EFI/BOOT/BOOTX64.EFI   shim 15.8, Microsoft-signed        (shim-signed)
  -> EFI/BOOT/grubx64.efi   GRUB 2.12, Canonical-signed        (grub-efi-amd64-signed)
  -> /casper/vmlinuz        Canonical-signed kernel, inside the boot slot's ISO
     EFI/BOOT/mmx64.efi     MokManager, Canonical-signed, for recovery only
```

shim trusts GRUB and the kernel through the Canonical CA certificate embedded in it
(`.vendor_cert`). GRUB asks shim to verify the kernel before `linux` loads it; the
initrd is not verified (as in stock Ubuntu). With Secure Boot on, the kernel runs in
lockdown (integrity) mode.

**Where the binaries come from** (`stick/scripts/fetch-signed-boot.sh <out-dir>`):

1. `apt-get download shim-signed grub-efi-amd64-signed` on Ubuntu 24.04 (in a container
   elsewhere). apt accepts a `.deb` only if its hash matches the Packages index, which the
   archive's signed `InRelease` authenticates. Nothing is fetched outside apt.
2. `dpkg-deb -x`, then:
   - `shimx64.efi` is `/usr/lib/shim/shimx64.efi.signed.latest`, shim 15.8 with SBAT
     `shim,4`. We don't use `.signed.previous`: that is shim 15.4 (`shim,1`), which the
     SBAT revocations shipped by Windows updates and by shim 15.8 itself reject. We also
     skip `.dualsigned`. It is the same shim with an extra Canonical signature, and only
     firmware ever checks shim, against the Microsoft signature.
   - `grubx64.efi` is `/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed`. That is the
     *disk* image; `gcdx64.efi.signed` is the CD image, see below.
   - `mmx64.efi` is `/usr/lib/shim/mmx64.efi`.
   - `fbx64.efi` (shim's fallback loader) is deliberately left out. shim would run it
     from a removable path, and it writes boot entries into the host's NVRAM.
3. `sbverify --list`: shim must be signed via *Microsoft Corporation UEFI CA 2011*, and
   GRUB and MokManager by *Canonical Ltd. Secure Boot Signing*.
4. `sbverify --cert`: GRUB and MokManager must verify cryptographically against the
   Canonical CA extracted from that shim's `.vendor_cert`, which is the check shim itself
   makes at boot. The CA is written out as `canonical-uefi-ca.pem`, and the Mac harness
   checks its test kernel against it the same way.
5. `signed-boot.lock` records the package versions, the `.deb` sha256s, each binary's
   sha256, source path and SBAT generation. `--expect <lock>` re-fetches the same versions
   and fails on any hash difference.

As of this writing: `shim-signed 1.58+15.8-0ubuntu1` and
`grub-efi-amd64-signed 1.202.5+2.12-1ubuntu7.3` (grub2 `2.12-1ubuntu7.3`, SBAT `grub,5`).

**How Canonical's signed GRUB finds its config.** We read this out of the image (its
`mods` section) and confirmed it by booting under OVMF, rather than assuming it:

- `grubx64.efi.signed` is monolithic. It has an embedded prefix of `/EFI/ubuntu`, **no**
  embedded config, and a memdisk that holds only `fonts/unicode.pf2`. It contains 124
  built-in modules, including everything our config uses: `part_gpt fat iso9660 ext2
  regexp loadenv test echo linux search search_label configfile normal sleep`. Under
  Secure Boot it cannot load modules from disk. The template's `insmod` lines are no-ops
  for built-ins, and a unit test keeps them inside that list and inside
  `build-grub-efi.sh`'s module list.
- Ubuntu's `normal` module loads `$fw_path/grub.cfg` first (the directory GRUB was loaded
  from, `EFI/BOOT/`), then `$prefix/grub.cfg` (`EFI/ubuntu/grub.cfg` on the same ESP), and
  otherwise drops to a `grub>` shell. Booting with different menu titles in each copy
  showed `EFI/BOOT` wins when both exist, `EFI/ubuntu` is used when it is the only copy,
  and with neither the result is the shell.
- The `/.disk/info` search belongs to `gcdx64.efi.signed`, the CD image, whose memdisk
  config is `search --file /.disk/info` and then `$prefix/grub.cfg`. Every boot slot's
  Ubuntu ISO contains `/.disk/info`, so that image could load an arbitrary slot's own
  `grub.cfg`. We never ship it.
- `flash` therefore writes the rendered `grub.cfg` to both `EFI/BOOT/grub.cfg` and
  `EFI/ubuntu/grub.cfg`. The development chain keeps reading `ci-stick/grub.cfg`. It is
  one template for both chains, and nothing in it needed changing for lockdown: `$cmdpath`
  disk detection, `load_env` of `ci-stick/grubenv` and `linux`/`initrd` from the slot's
  ISO all work under Canonical GRUB with Secure Boot on.

**Bundles, flashing and policy.** `ci-stick lock` records a chain from the staging
tree's `efi/` directory: `shimx64.efi` + `grubx64.efi` + `mmx64.efi` (Secure Boot), or
`BOOTX64.EFI` (development). It refuses both chains at once, an incomplete Secure Boot
chain, and unknown names. `verify` and `doctor --bundle` print `Boot  Secure Boot:
supported (shim → Canonical GRUB)`, or `Secure Boot: NOT supported (unsigned development
GRUB) — disable Secure Boot to boot this stick`, and `flash` prints the same line in its
plan. The ESP gets:

| chain       | ESP files                                                                                                      |
|-------------|----------------------------------------------------------------------------------------------------------------|
| Secure Boot | `EFI/BOOT/BOOTX64.EFI` (= shim), `EFI/BOOT/grubx64.efi`, `EFI/BOOT/mmx64.efi`, `EFI/BOOT/grub.cfg`, `EFI/ubuntu/grub.cfg`, `ci-stick/grubenv` |
| development | `EFI/BOOT/BOOTX64.EFI` (standalone GRUB), `ci-stick/grub.cfg`, `ci-stick/grubenv`                              |

`flash --device` with the development chain is refused unless you pass
`--allow-unsigned-bootloader`. With the flag, the plan carries a loud warning banner.
`--image` targets accept either chain without a flag, and the CI QEMU harness
(`stick/tests/qemu/run.sh`) still uses the development chain, so CI is unchanged.

**Testing it on a Mac** (local only; no GitHub workflow runs Secure Boot tests):

```bash
brew install --cask docker && open -a Docker     # once; wait until it is running
brew install qemu
stick/tests/secureboot/run-on-mac.sh
```

The build runs in `ubuntu:24.04` (linux/amd64) under Docker. It fetches the signed chain,
builds a test boot image with a Canonical-signed kernel and a busybox init that prints
`CI-STICK-SB secureboot=<0|1> slot=A cmdline_slot=A`, and flashes a signed and an
unsigned 64 GB stick. Only small qcow2 conversions leave the container. It also copies
Ubuntu's OVMF out: the Secure Boot build with Microsoft keys enrolled, and the plain
build. The boots then run on the Mac under Homebrew QEMU (HVF on Intel, TCG on Apple
Silicon), with the stick as a USB disk:

- **A.** Secure Boot on, signed chain. It boots with `secureboot=1`, slot A, boot count 1,
  and again with boot count 2.
- **B.** Secure Boot on, unsigned chain. The kernel is never reached, because the firmware
  reports `Access Denied`.
- **C.** Secure Boot off, signed chain. It boots with `secureboot=0`.

`--iso <ubuntu-or-CI-OS.iso>` builds a signed stick with that ISO in slot A and boots it
in a window with Secure Boot on, so you can check `mokutil --sb-state` and casper
persistence by hand. It needs about 8 GB free and is slow under TCG. The script also
runs on Linux: on an Ubuntu 24.04 host it builds without Docker.

**Limitations.**

- **Intel Macs with a T2 chip** don't trust the Microsoft UEFI CA 2011 that signs shim.
  Apple's firmware trusts only Apple and the *Microsoft Windows Production CA 2011*
  ([Apple Platform Security: boot process for an Intel-based Mac](https://support.apple.com/guide/security/sec5d0fab7c6/web)).
  At Full or Medium Security the stick won't boot. Set Startup Security Utility to
  **No Security** and allow booting from external media. Pre-T2 Intel Macs have no UEFI
  Secure Boot and boot the stick as they are.
- **Apple Silicon Macs** can't boot x86_64 sticks at all. The Mac harness *emulates* a PC
  there.
- **Kernels must be Canonical-signed.** Stock Ubuntu ISOs are fine. A future CI-OS image
  with a custom or rebuilt kernel (or custom kernel modules) won't boot under Secure Boot
  through this shim. It will need a Canonical-signed kernel, our own MOK (a key enrolled
  by the user through MokManager on first boot), or our own shim through the shim-review
  process with Microsoft signing. Unsigned kernel modules are also refused under lockdown.
- SBAT and dbx revocations can retire today's shim or GRUB. Re-run
  `fetch-signed-boot.sh` to pick up Ubuntu's updates. The lock file shows what a bundle
  shipped.
- Only x86_64. arm64 sticks (`shimaa64.efi`) come later.
- Tested under OVMF (QEMU) with Microsoft's keys, not yet on physical PCs.

## Delivery sequence

1. Security closure (tracked separately).
2. **Bundle schema, lockfile, `verify` and read-only `doctor`. ✅**
3. **Safe Ubuntu x86_64 flashing, persistence and QEMU boot tests. ✅**
4. Offline Hub/Memory payload install and model import.
5. Signed A/B updater with rollback.
6. Other distros (Fedora, Arch, Debian) and ARM64. The CachyOS ISO (backends/cachyos) is archiso-based; a Stick slot for it needs an archiso boot profile in bootcfg.rs, a boot_profile field in bundle.schema.json and an archiso-shaped QEMU boot image, and Secure Boot is unavailable for it. See docs/architecture/cachyos-backend.md#secure-boot-and-the-companion-stick.

### Still out of scope after slice 3

- Nothing mounts or unmounts anything; `flash` refuses mounted devices instead.
- **No host install**, and no launcher yet.
- **No updater** (manual `slot set` only) and no key rotation.
- **No `build`.** Staging trees are assembled by hand or by scripts for now.
- **No committed lock yet.** `ci-stick models lock` resolves digests, but
  `core/manifest/model-packs.lock.json` is not in the repository, and `ci-stick lock --packs`
  has no step yet that copies the lock's digests into `bundle.json`, which still carries
  `digest: null`. There is also no Windows device listing (`doctor` says "not supported yet").
