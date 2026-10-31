# Companion Stick architecture

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Companion Stick turns Companion OS into a product that fits in a pocket: one large USB stick
(target: 512 GB) that boots Companion OS, installs the Companion Intelligence stack onto
a machine that is already running an OS, carries the curated models offline, and updates
itself safely.

`backends/` stays the place where OS images are built (one adapter per supported target:
Ubuntu 26.04.1 and CachyOS). The product itself is a Rust CLI, **`ci-stick`**, in
[`stick/`](../../stick/README.md). It builds, verifies, flashes, installs from and updates
sticks. It uses the image backends and the contracts that CI Hub and CI Memory publish; it
does not reimplement them.

Status of the targets on the Stick (verified against the code and the logs named below, 2026-10-18):

| Target | Boots from the Stick? | Evidence |
|---|---|---|
| Stock Ubuntu 26.04.1 Desktop ISO in a slot, Secure Boot on | **Yes, as far as the live system's early systemd** [V] | the `ci-stick flash` plan, the serial log and the key lines in the evidence of the 26.04 port run of the Stick (outside the repository, see [Evidence](#evidence-and-where-it-lives)): kernel line with `boot=casper live-media=/dev/disk/by-partlabel/CI-BOOT-A persistent`, "Secure boot enabled" and kernel lockdown, `EXT4-fs (sda6): mounted ... r/w` (the `writable` persistence partition), casper loop-mounted three layers, systemd 259.5 started. Stopped there (TCG). GNOME, the installer and an installed system were not booted |
| Companion OS on Ubuntu 26.04.1 in a slot | **Not yet proven** [N] | pending evidence: see [Open items](#open-items). What confirms it: the serial log of a Secure Boot boot of the built ISO from a `ci-stick flash` image, reaching the casper live session |
| Companion OS on CachyOS in a slot | **No**; a design exists, nothing is built [N] | the boot menu is casper-shaped and CachyOS has no signed chain: [cachyos-backend.md](cachyos-backend.md#secure-boot-and-the-companion-stick) |

## What the stick does

| # | Function | How |
|---|----------|-----|
| 1 | **Boot Companion OS (live)** | UEFI boots an immutable image from the active A/B slot, with persistence. Companion OS on Ubuntu 26.04.1 is the only image the boot menu can start today (the menu is casper-shaped). The CachyOS edition cannot boot from the Stick yet. |
| 2 | **Install onto a running host** (macOS / Windows / Linux) | The user runs the signed launcher on `CI-SHARED` themselves, and it asks for admin consent. It installs CI Hub, CI Memory and the chosen model packs. Nothing runs automatically. |
| 3 | **Carry models offline** | Signed model packs sit in a content-addressed cache and import with no network. |
| 4 | **Update itself** | Signed, resumable, atomic A/B updates with rollback, run by `ci-stick` on the stick. |

## Commands

| Command | Status | Purpose |
|---------|--------|---------|
| `ci-stick lock <dir>` | **done** | Hash a staging tree and write a deterministic `bundle.json`; `--sequence` and `--valid-days` write schema 2 (sequence and expiry) |
| `ci-stick verify <root>` | **done** | Check the signature (fails closed), then the expiry and the sequence floor, then each artifact's size and SHA-256, path escapes and untracked files |
| `ci-stick trust show` | **done** | Read-only: the release keys pinned in this build (none yet), revoked fingerprints, the state directory and every stored sequence floor |
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
  for schema 2 also `sequence` and `expires_at`, then `artifacts[]` (path, kind, sha256,
  size, optional platforms), `model_packs[]` and `layout`. The Rust types in
  `stick/crates/ci-stick/src/manifest.rs` are the source of truth. The published mirror is
  [`stick/schema/bundle.schema.json`](../../stick/schema/bundle.schema.json), and tests
  fail if the two disagree. Unknown fields and any `schema_version` other than 1 and 2 are
  rejected, never half-parsed. Schema 1 has neither new key and its bytes are unchanged, so
  a signed schema 1 bundle stays valid; schema 2 requires both.
- **Signature.** `bundle.json.sig` is a detached **ed25519** signature over the exact
  bytes of `bundle.json`, checked with `verify_strict`. Because `lock` writes canonical
  JSON (fixed field order, sorted artifacts, stable formatting), a rebuild from identical
  inputs produces an identical signature payload.
- **Pinned keys.** [I] A build can carry release public keys: `stick/trust/pinned-keys.json`
  (`[{"id": "<16 hex>", "key": "<64 hex>"}]`) and the revoked fingerprints in
  `stick/trust/revoked.json`, both compiled in with `include_str!`
  (`stick/crates/ci-stick/src/trust.rs`). **Both lists are empty today** [V]
  (`no_release_key_is_pinned_until_the_owner_chooses_one`): no release key, key custody or
  signing pipeline exists (KI-23), so `--pubkey` is still the only key source and `verify`,
  `flash` and `doctor` print "no release key is pinned in this build (KI-23)". Once a key is
  pinned, the default policy is `Pinned`: some non-revoked pinned key must verify the
  signature (a signature that verifies only under a revoked key is `signature-key-revoked`,
  any other failure `signature-invalid`); a schema 1 bundle is refused
  (`bundle-freshness-missing`); and `--pubkey` is accepted only with `--development-key`
  (a loud warning) and never with `--device`. Pinning a key, rotating it or revoking one is
  a change to those two files and ships in a new binary. It needs the owner's explicit
  approval and a second reviewer. Release signing happens in the release pipeline;
  `ci-stick dev sign` exists only for development and tests.
- **Revocation.** [I] A revoked key is refused whatever supplied it, `--pubkey` included
  (`signature-key-revoked`), and its bundle is not believed about anything. The revocations
  compiled into a build reach users with a new binary. A file `revoked.txt` in the state
  directory (below), one fingerprint per line, reaches a user sooner: it can only add
  refusals, and a line that is not a fingerprint stops the command instead of being skipped.
- **Expiry and rollback protection.** [I] Schema 2 adds `sequence` (1 or more, increasing
  with every release of the same bundle `id`, assigned by the release pipeline) and
  `expires_at` (RFC 3339 UTC, after `created_at`). Once the signature and the manifest have
  checked out, and before any artifact is hashed, `verify` and `flash` refuse a bundle at or
  past `expires_at` (`bundle-expired`), one below the floor this machine stored for its `id`
  (`bundle-rollback`), and one at the floor with other `bundle.json` bytes
  (`bundle-sequence-conflict`). The same bytes are accepted again, so a stick can be
  re-flashed. Only a manifest the signature vouched for is believed about its age: an
  unsigned one never moves a floor. `lock` counts `expires_at` from `created_at` and never
  reads the clock for it, so the same inputs give the same bytes. Schema 1 stays readable
  for development and `--image`; while no key is pinned it can also go onto a `--device`,
  and the plan then says "nothing protects against an old bundle".
- **The sequence floor.** [I] The highest `sequence` accepted per bundle `id`, in
  `floors.json` of the per-user state directory (mode 0700): `$CI_STICK_STATE_DIR`, else
  `$XDG_STATE_HOME/ci-stick` or `$HOME/.local/state/ci-stick` (Linux),
  `$HOME/Library/Application Support/ci-stick` (macOS), `%LOCALAPPDATA%\ci-stick`
  (Windows); `--state-dir` overrides all of them. It is keyed by `id` alone, never by
  signer, so rotating the signing key cannot reset it. It moves up only after a whole
  verification succeeded: in `verify`, and in `flash` after the stick was written and read
  back. `--dry-run` and `doctor` read it and never write it. The file is replaced
  atomically under a lock (not locked on Windows). A damaged file stops every command that
  needs it and names it; nothing resets it. With no usable state directory a pinned or
  `--device` flow refuses and a development `--image` flow warns. The floor protects against
  a stale bundle, not against someone who controls your account or environment.
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
- **Planned trust extensions** [N]: per-pack signatures, and signed key-rotation statements
  and update metadata. Until then a rotation or a revocation reaches users only in a new
  binary (a revocation also through `revoked.txt`), and nothing in the repository chooses
  the key (KI-23).

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
- `digest` stays `null` in the YAML; `ci-stick models lock` resolves it from the registry.
  Digests are never typed by hand. A release bundle will require every digest to be resolved.
  What the registries said (manifest bytes, layer digests, sizes) is recorded in the
  generated and committed `core/manifest/model-packs.lock.json` (commit `89f7b27`, generated
  2026-10-17T20:15:00Z, 36 distinct models, Ollama library only); the YAML's `size_bytes` is a
  copy of it, and the test `catalog_sizes_match_the_lock_when_it_exists` fails on a one-byte
  difference ([models-tooling.md](models-tooling.md), section 4). `ci-stick lock --packs` does
  not copy the lock's digests into `bundle.json` yet.
- `size_bytes` is the exact byte size the Ollama registry lists (config plus layers), read
  on a given date; registry tags are mutable, so the digest-pinning `models lock` step is
  what makes a bundle reproducible. `ci-stick models list --device 512GB` shows what fits.
  All packs together come to 320.3 GB (checked with `ci-stick models list`, 2026-10-18),
  which fits the 512 GB layout's 304 GiB cache.
- **128 GB sticks:** the `stick-128` pack (21 ranked models, 74.8 GB since `glm-ocr:latest`
  grew on 2026-10-14) fills the 73 GiB cache of a 123.9 GB stick and leaves 3.34 GiB
  (4.6 %); `stick-128-oci` (19 models, 59.7 GB) keeps 15 GiB for OCI images. Why these
  models, the licences and the rejected list: [model-packs-128gb.md](model-packs-128gb.md).
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

`backends/ubuntu/` and `backends/cachyos/` keep building OS images (each has its own
`build-iso.sh`; the other distro backends were retired on 2026-10-17, see
[multi-distro-design.md](multi-distro-design.md)).
`ci-stick build` will call them, place their outputs under `boot/` in a staging tree, and
`lock` and sign the result. `core/manifest/ecosystem.yaml` remains the source of truth for
what a booted Companion OS provisions. The stick only adds packaging, trust and delivery.
Rust is first-class inside `stick/` only. `core/` and the shell backends must never
require it.

## Flashing (slice 3)

`ci-stick flash <bundle> --pubkey <key> (--image <file> --size <size> | --device <dev>)`
(`stick/crates/ci-stick/src/flash.rs`). Every step refuses before anything is written if
it fails.

1. **Verify first.** The bundle goes through `verify` with full hashing. A signature is
   required. `--allow-unsigned` is accepted only for `--image` targets and refused with
   `--device`. A schema 2 bundle must also be unexpired and not below the sequence floor
   (see [Bundle format and trust model](#bundle-format-and-trust-model)); a `--device`
   write needs a usable state directory for the floor. A failed verification exits 1 and
   writes nothing. The floor is recorded only after the stick was written and read back.
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
linux  ($ci_disk,gpt3)/casper/vmlinuz boot=casper live-media=/dev/disk/by-partlabel/CI-BOOT-A persistent ci_stick.slot=A quiet splash $extra_cmdline ---
initrd ($ci_disk,gpt3)/casper/initrd
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
- `stick/tests/qemu/run.sh` runs as the `stick-qemu` job in PR checks, inside a privileged
  `ubuntu:26.04` container (`.github/workflows/pr-checks.yml`), so QEMU, OVMF 2025.11, GRUB
  2.14, the filesystem tools and the kernel it boots are the target release's. It builds a
  tiny casper-shaped test ISO: a real Ubuntu kernel (from `linux-image-*-generic` of the
  resolute archive; its `usb-storage` is a module under `usr/lib/modules`, which
  `build-test-boot-image.sh` now looks in, and it stops if a USB driver is neither a module
  nor in `modules.builtin`) plus a busybox initrd whose `/init` reports its slot and
  `ci_stick.slot`, then increments `/boot-count` on the `writable` filesystem. It flashes a
  sparse 64 GB image and boots it three times in QEMU as a USB mass-storage device under
  OVMF. Boot 1 must report slot A with count 1, boot 2 must report count 2, and after
  `slot set B`, boot 3 must report slot B with count 3. The production grub.cfg is used
  unchanged. The same script checks that a tampered bundle, `--allow-unsigned` with
  `--device`, a regular file and a non-removable disk are all refused without writes.
  [V] Recorded run on the 26.04 userland (an arm64 `ubuntu:26.04` container on Apple silicon,
  because an amd64 one failed there with a tar ENOSYS and the arm64 one is the proven route; gdisk 1.0.10, exfatprogs 1.3.2, e2fsprogs 1.47.2,
  mtools 4.0.49, GRUB 2.14, OVMF 2025.11, kernel 7.0.0-38): `RESULT: PASS` with 17 PASS lines in its
  summary (the evidence file `qemu-run-sh/run.log`; an earlier report counted 16, the log
  has 17). The non-removable-disk case printed "lsblk listed /dev/vda but the device
  node is absent; skipping that case" in that run, so it did not exercise the system-disk
  refusal; CI sets `CI_STICK_TEST_SYSDISK_WRITE_REFUSAL=1` on a runner whose disk is real.
- `.github/workflows/stick-real-iso.yml` is manual. It downloads the Ubuntu 26.04
  desktop ISO of the release directory, checks it against SHA256SUMS, whose GPG signature
  must verify against Ubuntu's CD signing key (fingerprint pinned in the workflow), then
  flashes and boots the ISO to casper. It picks the ISO with `sort -V | tail -n1`, because
  the 26.04 `SHA256SUMS` lists both `ubuntu-26.04-desktop-amd64.iso` and
  `ubuntu-26.04.1-desktop-amd64.iso` and the first line is the older GA image. **No
  workflow in this repository has run on GitHub since the 26.04 port** [N]; the pieces were
  exercised in isolation (signature and pin logic on the real `SHA256SUMS`, loop mounts of
  the real ISO in a privileged container).

**Known limitations** (next slices):

- Secure Boot works through shim for Ubuntu images; see its own limitations under
  [Secure Boot](#secure-boot). CachyOS images cannot use this chain.
- Slots are sized from the device (8 GiB each on a 64 GB stick, 11 GiB on a 123.9 GB
  stick). `ci-stick flash` refuses an ISO that does not fit its slot ("boot image ... does
  not fit"). The stock Ubuntu 26.04.1 Desktop ISO is 6,482,409,472 bytes (6.04 GiB) and
  fits both. `verify-iso.sh` section 9 now fails an image larger than 8,589,934,592 bytes
  (override: `VERIFY_MAX_ISO_BYTES`). A built Companion OS ISO on 26.04.1 measured
  **7,076,577,280 bytes** (6.59 GiB; 1,513,357,312 bytes to spare) in that check [V for that
  build: `real-image-verify-after-fix.log` of the port-fix-A run, outside the repository];
  the 24.04.5 build was 7.9 GB (7.4 GiB; retired baseline). Growth past 8 GiB (Ollama's
  CUDA libraries, a second language, the encryption variant's seed) would stop a 64 GB stick
  carrying it; the options would be a smaller ISO, larger sticks or a change of the layout
  policy (`ci-stick-layout/1`), an owner decision. The clean-checkout build of 2026-10-18 (commit `02c575e`) measures the same 7,076,577,280
  bytes (`docs/evidence/2026-10-18-ubuntu-clean-02c575e/`).
- `CI-SHARED` and `CI-CACHE` are formatted empty. Populating them (launchers, docs, OCI
  images and models) is slice 4; the model half has its tool now: the daemon-free
  `ci-stick models fetch` fetches manifests and blobs from the registry, verifies size and
  sha256, and writes the manifest last, into any directory, but it has not been run against a
  real exFAT volume or a real Ollama 0.40 daemon (a prototype was proven against the public
  registry and a 0.33 daemon; see [model-packs-128gb.md](model-packs-128gb.md), section 5.4,
  and [models-tooling.md](models-tooling.md)). exFAT can't be written without root or
  mounting, so a host without that has to fill a directory and copy it. `stick/README.md`
  documents the `models` commands.
- Mass flashing (several sticks at once, intake capacity test, per-stick identity,
  independent verification) has no tooling yet: [mass-flashing.md](mass-flashing.md).
- Device writes are Linux-only. On macOS and Windows, `flash --device` and `slot --device`
  say "not supported yet". To use another OS, write an image with `--image` and flash it
  with that OS's tools.
- The real-ISO boot test is manual. It is not part of PR checks, and it has not yet been
  run on real hardware. The stock 26.04.1 ISO was booted from a flashed image under
  Secure Boot in QEMU/TCG up to the live system's early systemd; nothing later (GNOME, the
  installer) was booted from a stick.
- Replacing grubenv with mtools is not an atomic update. The signed A/B updater (slice 5)
  owns atomic pointer flips and rollback.

## Secure Boot

Companion Stick boots on PCs with UEFI Secure Boot **enabled**, through the same signed
chain Ubuntu's own install media uses. We add no keys of our own and need no MOK
enrollment for Ubuntu images. The chain below was re-derived from the Ubuntu 26.04
(resolute) archive on 2026-10-17; the 24.04 chain it replaces is retired.

```
firmware db (Microsoft Corporation UEFI CA 2011)
  -> EFI/BOOT/BOOTX64.EFI   shim 15.8, Microsoft-signed        (shim-signed)
  -> EFI/BOOT/grubx64.efi   GRUB 2.14, Canonical-signed        (grub-efi-amd64-signed)
  -> /casper/vmlinuz        Canonical-signed kernel, inside the boot slot's ISO
     EFI/BOOT/mmx64.efi     MokManager, Canonical-signed, for recovery only
```

shim trusts GRUB and the kernel through the Canonical CA certificate embedded in it
(`.vendor_cert`). GRUB asks shim to verify the kernel before `linux` loads it; the
initrd is not verified (as in stock Ubuntu). With Secure Boot on, the kernel runs in
lockdown (integrity) mode.

**Where the binaries come from** (`stick/scripts/fetch-signed-boot.sh <out-dir>`):

1. `apt-get download shim-signed grub-efi-amd64-signed` on Ubuntu 26.04 (`SERIES=resolute`;
   the script stops on any other release, and in a container elsewhere). apt accepts a `.deb` only if its hash matches the Packages index, which the
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
5. `grub-builtin-modules.py --require`: every GRUB module the stick's `grub.cfg` relies on
   (the 14 names of `CANONICAL_GRUB_BUILTIN_MODULES` in `bootcfg.rs`, which the script reads
   with `sed`: one `"name",` per line) must be built into `grubx64.efi`, or the script
   refuses the image. Under Secure Boot shim refuses every module GRUB would load from disk,
   and Canonical changes the built-in set between releases.
6. `signed-boot.lock` records the series, the package versions, the `.deb` sha256s, each
   binary's sha256, source path and SBAT generation. `--expect <lock>` re-fetches the same
   versions and fails on any hash difference.

As of 2026-10-17 (the resolute archive and the 26.04.1 ISO's `pool/` carry the same versions,
there is no `-updates` build yet): `shim-signed 1.59+15.8-0ubuntu2` (shim 15.8, SBAT
`shim,4`) and `grub-efi-amd64-signed 1.215+2.14-2ubuntu1` (GRUB 2.14, SBAT `grub,5`).
[V] The real `fetch-signed-boot.sh` ran against the live resolute archive: exit 0, all
`sbverify` checks, `--expect` of its own lock reproduced it byte for byte, a doctored lock
exited 1, a `bootcfg.rs` that required `all_video` exited 1 naming the module. The lock it
wrote is in the evidence directory (`fetch-signed-boot/resolute-signed-boot.lock`, outside the
repository). The Canonical CA embedded in shim has the same sha256 (`98933813...`) as on 24.04.
The Canonical-signed `linux-image-7.0.0-38-generic` of resolute-updates verifies against it
(`sbverify --cert`).

**How Canonical's signed GRUB finds its config.** We read this out of the image (its
`mods` section) and confirmed it by booting under OVMF, rather than assuming it:

- `grubx64.efi.signed` is monolithic. On the 24.04 image (GRUB 2.12) we read an embedded
  prefix of `/EFI/ubuntu`, **no** embedded config, and a memdisk that holds only
  `fonts/unicode.pf2`. The 26.04 disk image (GRUB 2.14, 2,828,168 bytes, sha256
  `33e1d46c...`) was re-read for its module set only: it has **122** built-in modules, read
  the way GRUB reads them (PE section `mods`, `grub_module_info64` entries, ELF `.modname`)
  with `stick/scripts/grub-builtin-modules.py`, and the 122 names are the fixture
  `stick/crates/ci-stick/tests/fixtures/grub/grubx64.efi.signed.builtin-modules.txt`. All 14
  modules our config relies on are among them (`configfile echo ext2 fat iso9660 linux
  loadenv normal part_gpt regexp search search_label sleep test`). Under Secure Boot it
  cannot load modules from disk. The template's `insmod` lines are no-ops for built-ins.
  Three unit tests in `bootcfg.rs` keep this honest:
  `fixture_is_the_module_list_of_the_signed_grub_image`,
  `pinned_list_is_inside_what_the_real_signed_grub_has` (the pinned list and every `insmod` of
  the template must be among the 122) and `pinned_list_stays_readable_by_fetch_signed_boot_sh`.
  Five more in `tests/grub_modules_tool.rs` run the Python reader against synthetic images
  built byte by byte, including a feature-flag string that must not count as a module.
- **What changed from 24.04 to 26.04, and why it matters.** The 24.04 disk image had 124
  modules. 26.04's has **no `all_video`** (a string search finds only `feature_all_video_module`,
  a feature flag; `all_video.mod` exists only as a loadable module in `grub-efi-amd64-bin`,
  which Secure Boot refuses), and also dropped `efi_uga ntfs pgp video_bochs video_cirrus`;
  it added `gcry_hwfeatures gcry_keccak key_protector pubkey`. A `grub.cfg` that does
  `insmod all_video` therefore fails on 26.04 under Secure Boot; ours never did. The CD image
  that the 26.04.1 ISO itself boots through shim (`gcdx64.efi.signed`, 2,398,088 bytes, also
  `EFI/boot/grubx64.efi` on the ISO) has 95 modules, a strict subset of the disk image's 122,
  and also lacks `all_video`. It is a different file from the one the stick ships.
- Ubuntu's `normal` module loads `$fw_path/grub.cfg` first (the directory GRUB was loaded
  from, `EFI/BOOT/`), then `$prefix/grub.cfg` (`EFI/ubuntu/grub.cfg` on the same ESP), and
  otherwise drops to a `grub>` shell. Booting with different menu titles in each copy
  showed `EFI/BOOT` wins when both exist, `EFI/ubuntu` is used when it is the only copy,
  and with neither the result is the shell. That experiment was done on the 24.04 image
  (GRUB 2.12) and was **not repeated** on 26.04's GRUB 2.14 [N]. What the 26.04 runs show
  is that the stick, which carries both copies, boots through this lookup under Secure Boot
  (runs A and C below); the precedence and the memdisk content of the 26.04 disk image are
  not re-measured.
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

The build runs in `ubuntu:26.04` (linux/amd64) under Docker. It fetches the signed chain,
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

`--iso <ubuntu-or-Companion-OS.iso>` builds a signed stick with that ISO in slot A and boots it
in a window with Secure Boot on, so you can check `mokutil --sb-state` and casper
persistence by hand. It needs about 8 GB free and is slow under TCG. The script also
runs on Linux: on an Ubuntu 26.04 host it builds without Docker. `--skip-build` refuses an
`out/` whose `signed-boot.lock` is not `series=resolute` (the gitignored `out/` of a
checkout that predates the port still holds a 24.04 build, and so does the Docker volume
`ci-stick-sb-cache`).

[V] Result on 26.04 (`run-on-mac.sh`, native Homebrew QEMU 11.1.2 in TCG mode on Apple
silicon, OVMF `2025.11-3ubuntu7.3` from `ovmf-generic`, shim `1.59+15.8-0ubuntu2`, GRUB
`1.215+2.14-2ubuntu1`, kernel `linux-image-7.0.0-38-generic` verified against the Canonical CA
embedded in shim): **RESULT: PASS, 8 checks.** A boots with `secureboot=1`, slot A, boot count
1 and, after a reboot, 2; B (unsigned chain) is refused with `Access Denied`; C (Secure Boot
off) boots with `secureboot=0`, count 3. The harness output is the evidence file
`secureboot-abc/results.txt` (outside the repository).

**Docker Desktop on Apple silicon failed to run the build half as written** [V once; a limit of the
host, not a repository bug; the trigger was not isolated, and another amd64 `ubuntu:26.04` container ran
to the end on 2026-10-18]. Measured with Docker Desktop 29 on macOS 27: in a
`linux/amd64` `ubuntu:26.04` container (Rosetta) GNU tar 1.35 failed to create anything inside
a directory it has just created ("Cannot mkdir ... Function not implemented"), so
`dpkg-deb -x` fails. The same tar in an amd64 `ubuntu:24.04` works; bsdtar and Python's
`tarfile` work in 26.04; `--privileged` and `seccomp=unconfined` do not help.
`build-in-container.sh` runs a nested create-and-extract check first and stops with this
explanation instead of failing later. What works, and was used for the result above:
`fetch-signed-boot.sh` alone, and then the rest of the build half, in an **arm64**
`ubuntu:26.04` container whose apt is pointed at the amd64 archive through an `APT_CONFIG`
file (`APT::Architecture "amd64"`, a separate `Dir::State`), because both only download and
unpack; amd64 busybox and GRUB modules were then placed by hand, so that case is not
scripted. The supported route is an x86_64 Ubuntu 26.04 machine. A related known
defect: `run-on-mac.sh` does not forward `CI_STICK_SB_SIZE` into the container, so it
always builds 64 GB images; `build-in-container.sh` honours it
(`CI_STICK_SB_SIZE=123942731776` reproduces the 123.9 GB sticks) when called directly.

**Limitations.**

- **Intel Macs with a T2 chip** don't trust the Microsoft UEFI CA 2011 that signs shim.
  Apple's firmware trusts only Apple and the *Microsoft Windows Production CA 2011*
  ([Apple Platform Security: boot process for an Intel-based Mac](https://support.apple.com/guide/security/sec5d0fab7c6/web)).
  At Full or Medium Security the stick won't boot. Set Startup Security Utility to
  **No Security** and allow booting from external media. Pre-T2 Intel Macs have no UEFI
  Secure Boot and boot the stick as they are.
- **Apple Silicon Macs** can't boot x86_64 sticks at all. The Mac harness *emulates* a PC
  there.
- **Kernels must be Canonical-signed.** Stock Ubuntu ISOs are fine. A Companion OS image
  with a custom or rebuilt kernel (or custom kernel modules) won't boot under Secure Boot
  through this shim. It will need a Canonical-signed kernel, our own MOK (a key enrolled
  by the user through MokManager on first boot), or our own shim through the shim-review
  process with Microsoft signing. Unsigned kernel modules are also refused under lockdown.
- SBAT and dbx revocations can retire today's shim or GRUB. Re-run
  `fetch-signed-boot.sh` to pick up Ubuntu's updates. The lock file shows what a bundle
  shipped.
- Only x86_64. arm64 sticks (`shimaa64.efi`) come later.
- Tested under OVMF (QEMU) with Microsoft's keys, not yet on physical PCs.
- **CachyOS cannot use this chain**: its GRUB is an unsigned standalone image and its
  kernels are not Canonical-signed. A CachyOS stick would need the development chain with
  Secure Boot off until the project runs its own MOK and shim.

## Delivery sequence

1. Security closure (tracked separately).
2. **Bundle schema, lockfile, `verify` and read-only `doctor`. ✅**
3. **Safe Ubuntu x86_64 flashing, persistence and QEMU boot tests. ✅**
4. Offline Hub/Memory payload install and model import.
5. Signed A/B updater with rollback.
6. A CachyOS slot, and ARM64. The CachyOS ISO (`backends/cachyos`) is archiso-based; a Stick slot for it needs an archiso boot profile in `bootcfg.rs`, a `boot_profile` field in `bundle.schema.json` and an archiso-shaped QEMU boot image, and Secure Boot is unavailable for it. See [cachyos-backend.md](cachyos-backend.md#secure-boot-and-the-companion-stick).

### Still out of scope after slice 3

- Nothing mounts or unmounts anything; `flash` refuses mounted devices instead.
- **No host install**, and no launcher yet.
- **No updater** (manual `slot set` only) and no key rotation.
- **No `build`.** Staging trees are assembled by hand or by scripts for now.
- **The lock is committed, but not used by `lock --packs`.** `core/manifest/model-packs.lock.json`
  is in the repository (commit `89f7b27`), and `ci-stick lock --packs` has no step yet that
  copies the lock's digests into `bundle.json`, which still carries `digest: null`. There is
  also no Windows device listing (`doctor` says "not supported yet").

## Open items

Each row says what is open and what closes it. Items about the Stick only; the CachyOS edition's
own list is in [cachyos-backend.md](cachyos-backend.md#risk-register) and the models list in
[models-tooling.md](models-tooling.md#14-open-items).

| # | Open item | State | What closes it |
|---|---|---|---|
| S1 | A **built Companion OS on Ubuntu 26.04.1** booting from a Stick slot | Not proven [N]. The stock 26.04.1 ISO reaches the live system's early systemd from a flashed image under Secure Boot; a Companion OS ISO has not been put in a slot | The serial log of a Secure Boot boot of the built ISO from a `ci-stick flash` image that shows `boot=casper live-media=/dev/disk/by-partlabel/CI-BOOT-A persistent`, "Secure boot enabled" and the `writable` partition mounted, then the live session. Pending: the 26.04.1 build and capture in progress on 2026-10-18 will add the build and boot rows; this page makes no claim about it until a log shows it |
| S2 | A built 26.04 ISO against the slot size | One build measured 7,076,577,280 bytes, inside 8 GiB [V]; the size can grow | `verify-iso.sh` section 9 on every release build (limit 8,589,934,592 bytes for 64 GB sticks; 11,811,160,064 for 123.9 GB sticks); owner decision if a build is larger (see Known limitations above) |
| S3 | **CachyOS cannot boot from the Stick** and has no Secure Boot | By design today [N] | An archiso boot profile in `bootcfg.rs`, a `boot_profile` field in `bundle.schema.json` and an archiso-shaped QEMU boot image; for Secure Boot, a project-owned MOK and shim |
| S4 | **Strix Halo GTT boot parameters** (`iommu=pt amdgpu.gttsize= ttm.pages_limit=`, and `amdttm.pages_limit=` where AMD's DKMS amdgpu driver is installed) exist only in the Ubuntu backend (`backends/ubuntu/lib/strix-halo-boot-params.sh`, hooked from `backends/ubuntu/provision/provision.sh`); `git grep` finds them nowhere else | Gap on CachyOS and on the Stick's grub.cfg | A decision where they belong for a Stick boot (`extra_cmdline` in `grubenv` is the existing hook) and for the CachyOS edition |
| S5 | **Ollama in a Stick live boot**: `10-not-live.conf` keeps Ollama off in every Ubuntu live session, so the 73 GiB `CI-CACHE` serves installed machines only | Owner decision open (stick audit D5) | The decision, then a self-test assertion for whichever is chosen |
| S6 | **Secure Boot requirement for the first batch** | Open. Sticks boot with Secure Boot on through the Canonical chain, [V] only in QEMU/OVMF; a real PC has not been tried | An owner statement whether the first batch must boot with Secure Boot on, and a boot on one real PC |
| S7 | **Disk-space guard for model pulls**: the model set takes about 18.8 GB; the shared fit gate checks RAM and GPU memory, not disk | Open, see [models-tooling.md](models-tooling.md#14-open-items) | The guard in `ci_os_model_gate_allows` (`core/lib/gpu-detect.sh`) |
| S8 | Hosted workflows have not run since the 26.04 port | Open [N] | One green run each of `pr-checks.yml` (including `stick-qemu`), `build-companion-os-iso.yml` and, manually, `stick-real-iso.yml` |
| S9 | **No release key is pinned**: the pinned list, revocation, expiry and sequence floor are implemented [I] and tested with throw-away keys, but `stick/trust/pinned-keys.json` is `[]` (KI-23) | Open [N] | The owner names the key holder and the signing pipeline, then a change to `stick/trust/pinned-keys.json` with the owner's explicit approval and a second reviewer; and the owner's call on the 365-day window, who assigns `sequence`, and whether schema 1 stays usable with `--device` while no key is pinned |

## Evidence and where it lives

Logs, serial output and screenshots of the runs named on this page are in the scratch
directories of the sessions that ran them, **not in this repository** (the same convention as
[cachyos-backend.md](cachyos-backend.md#test-status)). Names, so they can be asked for:

| Claim | Evidence file (session scratch, `retire/port-C-evidence/`, the 26.04 port run of the Stick) |
|---|---|
| 122 and 95 GRUB modules, the diff to 24.04 | `grub-modules/` |
| the resolute lock | `fetch-signed-boot/resolute-signed-boot.lock` |
| Secure Boot A/B/C, 8 checks | `secureboot-abc/results.txt`, serial logs `A1 A2 B C` |
| stock 26.04.1 ISO on a stick, Secure Boot on | `real-iso-secureboot/{flash-plan.txt,key-lines.txt,serial.log}` |
| `run.sh` on the 26.04 userland | `qemu-run-sh/run.log` |
| `check-repo.sh` at HEAD in an `ubuntu:26.04` container | `check-repo-at-HEAD-in-ubuntu-26.04-container.log` |

Two repository facts are testable without them: `cargo test --locked` in `stick/` (the three
`bootcfg.rs` tests and `tests/grub_modules_tool.rs` named above), and
`python3 -I stick/scripts/grub-builtin-modules.py <grubx64.efi.signed>`, which regenerates the
fixture.
