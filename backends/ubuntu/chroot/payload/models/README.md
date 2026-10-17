# Model tooling on the booted OS: cache environment, Hugging Face view, hardware gate, opt-in prefetch

> Private & Confidential — Property of Lifescope Inc. Do not distribute.

The OS side of the model download and cache work (design: `docs/architecture/models-tooling.md`). `ci-stick models ...` (Rust, `stick/`)
downloads, pins and verifies; the files here and in `core/lib/` decide **where** the cache is, **what the consumers
need in their environment**, **whether this machine can run a model**, and **when a background download may run**. Nothing
in `core/` or the shell backends requires ci-stick: they use it when it is there.

Status 2026-10-17: written and tested on fixtures and PATH stubs. The scripts target the images' bash 5; they are kept
bash 3.2 clean so that the tests run on a stock Mac. The final state of the code ran all five test files and the
mutation suite on the Mac (bash 3.2.57, BSD awk). Ubuntu 24.04 and 26.04 containers (bash 5.2.21 and 5.3.9, mawk) ran the
tests on an earlier state of the code (before the prefetch .path unit, the forced/automatic offline split, the newline and
empty-store hardening and the validator tests); the Docker daemon stopped answering afterwards, so the final state has not
run on bash 5 yet: run `models-all.sh` in an Ubuntu 24.04 container before relying on it. **Nothing here has run on a booted image, with real systemd, a real exFAT volume, a real GPU or a real
ci-stick.** The "Not verified" list at the end says exactly what that means.

## What is where

| File | Installed as | Mode | Notes |
|---|---|---|---|
| `core/lib/ci-os-models.sh` | `/usr/bin/ci-os-models` | 0755 | library and command in one file; design note in its header |
| `core/lib/gpu-detect.sh` (existing, extended) | `/usr/lib/ci-os/gpu-detect.sh` | 0644 | the hardware gate; `ci-os-models` finds it next to itself, there, or in the bootstrap tree |
| `core/manifest/model-packs.yaml` | `/usr/share/ci-os/model-packs.yaml` | 0644 | the gate's data (min_ram_gb / min_vram_gb) and the pack lists |
| `core/manifest/model-packs.lock.json` (once it exists) | `/usr/share/ci-os/model-packs.lock.json` | 0644 | where the Hugging Face view takes repository, commit, file and sha256 from |
| `payload/ci-os-ollama-models-env.sh` (existing, extended) | `/usr/libexec/ci-os/ollama-models-env` | 0755 | unchanged contract; now also writes the Hugging Face / llama.cpp variables and builds the view |
| `usr/lib/systemd/system/ci-os-models-prefetch.path` | same | 0644 | the opt-in switch: starts the timer when `/etc/ci-os/models-prefetch` exists; **this** is the unit to enable |
| `usr/lib/systemd/system/ci-os-models-prefetch.timer` | same | 0644 | no `[Install]`: first look 10 min after boot, then 00/06/12/18:17 (+ up to 20 min random) |
| `usr/lib/systemd/system/ci-os-models-prefetch.service` | same | 0644 | opt-in background fill, `ExecCondition=` decides |
| `usr/lib/systemd/system/ci-os-hf-view.service` | same | 0644 | builds the view at boot where Ollama does not run (live sessions) |
| `etc/profile.d/ci-os-models.sh` | same | 0644 | login shells get `HF_HUB_CACHE`, `LLAMA_CACHE`, `CI_STICK_CACHE` |
| `usr/share/ci-os/models.conf.example` | same | 0644 | `/etc/ci-os/models.conf` template |

`customize-chroot.sh` is not part of this change (another group owns the ISO build). What its Step 10e needs, as a
suggestion (nothing below is applied):

```bash
install -d -m 0755 "$CHROOT_PATH/usr/lib/ci-os" "$CHROOT_PATH/usr/share/ci-os" "$CHROOT_PATH/etc/profile.d"
install -m 0755 "$REPO_ROOT/core/lib/ci-os-models.sh"  "$CHROOT_PATH/usr/bin/ci-os-models"
install -m 0644 "$REPO_ROOT/core/lib/gpu-detect.sh"    "$CHROOT_PATH/usr/lib/ci-os/gpu-detect.sh"
install -m 0644 "$REPO_ROOT/core/manifest/model-packs.yaml" "$CHROOT_PATH/usr/share/ci-os/model-packs.yaml"
[[ -f "$REPO_ROOT/core/manifest/model-packs.lock.json" ]] && install -m 0644 "$REPO_ROOT/core/manifest/model-packs.lock.json" "$CHROOT_PATH/usr/share/ci-os/"
cp -a "$REPO_ROOT/backends/ubuntu/chroot/payload/models/usr/." "$CHROOT_PATH/usr/"
install -m 0644 "$REPO_ROOT/backends/ubuntu/chroot/payload/models/etc/profile.d/ci-os-models.sh" "$CHROOT_PATH/etc/profile.d/"
systemctl --root="$CHROOT_PATH" enable ci-os-hf-view.service ci-os-models-prefetch.path   # nothing is scheduled until the flag file exists
```

All of it belongs to the **installed** layer (the system the installer writes), none of it is live-only
(`docs/architecture/ubuntu-iso-layers.md`). Note `core/lib/*.sh` is already staged to `/usr/lib/ci-os/bootstrap/core/lib/`
by Step 10c; `core/manifest/model-packs.yaml` is **not** (only `ecosystem.yaml` and `role-map/apt.yaml` are), so
`provision.sh`'s fit gate has no data on an installed machine until the YAML is staged to
`/usr/lib/ci-os/bootstrap/core/manifest/` as well. Without it the gate answers "no data" and never blocks a pull.

## The cache and the environment

```
<root>/models/                  = OLLAMA_MODELS (Ollama format: blobs/sha256-<hex>, manifests/...)
<root>/ci-models/               ci-stick's private state: blobs/<hh>/<hex>, partial/, status.json
```

`<root>` is, in this order: `$CI_OS_MODELS_CACHE`; the volume labelled `CI-CACHE` where it is mounted (by
`ollama-models-env`, by udisks, or at `$CI_OS_CACHE_MOUNT`); else `/var/lib/ci-os`. Only the first two are wired to
Ollama. `ci-os-models cache` prints what was found.

`ci-os-models env` prints the consumer environment, and only when a cache is in use (an installation without one keeps an
empty environment file, as before):

| Variable | Value | Why |
|---|---|---|
| `OLLAMA_MODELS`, `OLLAMA_NOPRUNE=1` | `<root>/models` | unchanged: Ollama deletes unreferenced files in `blobs/` at start-up, a seeded store is made offline. Daemon file only (`--user` leaves them out) |
| `CI_STICK_CACHE` | `<root>` | ci-stick's default cache; scripts |
| `HF_HUB_CACHE`, `HUGGINGFACE_HUB_CACHE`, `LLAMA_CACHE` | `/var/lib/ci-os/hf-view/hub` | the view below. llama.cpp uses `LLAMA_CACHE` as the hub directory itself (`common/hf-cache.cpp:35-60`, read from the llama.cpp source, not run) |
| `HF_HUB_OFFLINE=1` | `CI_OS_OFFLINE=1` or `offline=1` in `models.conf`; and, in the daemon's file only, with the default `offline=auto`, while there is no default IPv4 route; `offline=0` never | huggingface_hub then answers from the view instead of waiting for the network. Login shells get only a forced one: an automatic "offline" decided at login would outlive the moment the network returns and make every download fail |
| `HF_HOME` | **not set** unless `set_hf_home=1` in `models.conf` | `HF_HOME` also decides where a Hugging Face login token is stored, so it is left alone (`docs/architecture/models-tooling.md`: "do not set HF_HOME") |

The daemon's file `/run/ollama/ci-models.env` is produced by `ollama-models-env`, which asks `ci-os-models env --format
systemd` (told which cache it chose, so the two cannot disagree) and falls back to the old two lines if the helper is
missing, fails, disagrees about `OLLAMA_MODELS` or prints anything that is not `KEY=value`. The same script then builds the
view (best effort, 20 s limit). Login shells get the `--user` subset from `/etc/profile.d/ci-os-models.sh`.

**Permissions.** The exFAT volume is mounted for the `ollama` user only (`uid=ollama,umask=0077`, unchanged). A Hugging Face
tool or llama.cpp running as another user cannot read the blobs through the view unless the volume is mounted for them:
`CI_OS_CACHE_UMASK=0027` and `CI_OS_CACHE_GROUP=<group>` (for example in a drop-in for `ollama.service`) widen the mount
options; both are validated, and the defaults are the old ones. A volume that udisks mounted for the desktop user is
readable by that user.

**HF_HUB_CACHE is writable.** `hf download` run on the box writes into the view directory, which is on the root file system:
in a plain-ISO live session that is RAM. Nothing here prevents it.

## The Hugging Face view

exFAT has no symlinks, so huggingface_hub and llama.cpp would each **copy** a 40 GB file into `snapshots/`. The view is a
directory of symlinks on a Linux file system instead:

```
/var/lib/ci-os/hf-view/hub/models--ORG--NAME/refs/main                    a regular file: the commit
/var/lib/ci-os/hf-view/hub/models--ORG--NAME/snapshots/<commit>/<file>    symlink -> <root>/models/blobs/sha256-<hex>
```

`ci-os-models view` builds it from the lock (objects with `repo`, `revision`|`commit`, `file`|`path`|`filename` and
`sha256` side by side, at any depth; pretty or compact JSON; `--spec FILE` takes the same four columns, tab separated).
Why the lock and not the manifests in the store: an Ollama manifest (`manifests/hf.co/<org>/<repo>/<quant>`) holds digests,
and neither the commit nor the file name a Hugging Face tool looks for; the lock has both. Which lock: `--lock`, else
`$CI_OS_MODEL_LOCK_FILE`, else the image's (`/usr/share/ci-os/model-packs.lock.json`, then `core/manifest/` next to the
library; `CI_OS_MODEL_LOCK_SEARCH` replaces that list), and only if there is none the copies in
`<root>/ci-models/locks/*.json`: a lock that lives on a removable volume is the least trusted of the four. The view trusts the lock's digest and the store's
file names and does not hash the blobs (40 GB); proving a blob is `ci-stick models verify`'s job.
`ci_models_view_build` is a small POSIX-style function: idempotent (a second run changes nothing, down to the inodes),
and it only ever creates, replaces or removes symlinks that point into the store.

What it refuses, counts and goes on (nothing is created for them): a file name with a control character (newline, tab,
CR, ESC, DEL), a backslash, a leading `/`, an empty, `.` or `..` component, or more than 1024 bytes; a repository that is
not `ORG/NAME` of letters, digits, `.`, `_`, `-` (or has `--`, which llama.cpp would read back as `/`); a revision that is
not 40 lowercase hex; a digest that is not 64 lowercase hex; a symlink or a file where a directory belongs; a real file
or directory, or a link to somewhere else, where a link belongs; a blob that is itself a symlink. Spaces, quotes,
`$(...)`, backticks, leading dashes, globs, brackets, unicode are ordinary characters: no path is ever evaluated or word
split, and every path handed to a command is absolute. Escapes in the lock (`\n`, `\u00e9`) that decode to a control or
non-ASCII character drop the entry; serde_json writes non-ASCII raw, so a real lock does not need them.

Not shown: that huggingface_hub or llama.cpp actually read this layout. The layout is the one their source reads (llama.cpp
`get_cached_files`/`get_cached_ref`: a regular `refs/main`, entries that are files or symlinks under `snapshots/<commit>`;
huggingface_hub `try_to_load_from_cache`), neither tool is installed here. The lock ci-stick writes has no Hugging Face
model yet (`stick/crates/ci-stick/src/lockfile.rs` has `source = ollama` only); when it does, its keys should be `repo`, `revision`, `file`, `sha256`
in one object, or the reader's alias list needs the new names.

## The hardware-fit gate

`ci_os_model_fits <name[:tag]>` in `core/lib/gpu-detect.sh`: 0 fits, 1 does not, 2 no data. `ci_os_model_gate_allows` is
what the provisioners call (0 go ahead, 1 skip; "no data" never blocks). Data: `min_ram_gb` / `min_vram_gb` of
`model-packs.yaml`, read by an awk program (no YAML parser on the images) whose rows are compared in a test with Ruby's
YAML parser on the checked-in file (every pack, every alias).

| | rule |
|---|---|
| RAM | `MemTotal >= min_ram_gb x 1024 x 91 %`. A "32 GB" machine reports about 30,000 MiB, which is why the old Strix Halo rule says `CI_OS_MIN_SUPPORTED_RAM_MIB=30000`; the floor for a 32 GB model is 29,818 MiB, so nothing that rule accepted is refused now (a test checks it) |
| GPU memory | `min_vram_gb` null: no requirement. A number is the practical minimum of **discrete-GPU** memory (the YAML header): `nvidia-smi` + `rocm-smi`/amdgpu sysfs total `>= min_vram_gb x 1024 x 95 %` (a 24 GB card reports 24,564 of 24,576 MiB). A CPU-only machine does not fit such a model however much RAM it has; `CI_OS_FIT_CPU_OK=1` relaxes it |
| Unified memory (Strix Halo) | no separate pool: `MemTotal` + the BIOS carve-out must cover `max(min_ram_gb, min_vram_gb)` at the RAM percentage. CI-Hub applies 0.7 to unified memory; these thresholds are already practical minimums, so a second fraction would reject the 32 GB class the Strix Halo rule exists for |
| Missing detector | counts as "no GPU memory", never an error. `/proc/meminfo` unreadable: does not fit |

The provisioners: Ubuntu keeps `ci_os_hardware_supported` (Strix Halo class, 30,000 MiB) and adds the fit gate on top; Arch
had no gate and now has the fit gate for `qwen3.6:27b`. `backends/ubuntu/provision/install-models.sh` (the headless
post-validation step), Fedora and NixOS pull the same model with the old rule or none: a three-line change each, not
made here (files outside this change).

## Fallbacks when ci-stick is not installed

| Reference | ci-stick absent | ci-stick present |
|---|---|---|
| Ollama (`gemma3:1b`, `nomic-embed-text`) | `ollama pull` (needs the daemon; no lock, no digest pinning; said on stderr) | ci-stick, when Ollama reads the cache (a stick or an explicit cache, or `OLLAMA_MODELS` points at it); else `ollama pull` fills the daemon's own store |
| Hugging Face (`hf.co/...`, `huggingface.co/...`) | **refused, status 10, never `ollama pull`**: nothing else pins the commit, refuses gated repositories or checks the digest | ci-stick |
| Anything else (option-looking, `..`, spaces, `;`...) | refused, status 12 | refused, status 12 |

A failing ci-stick is **not** retried through `ollama pull` (that would skip the lock and the digest check). `ensure` gates
first (status 11 when nothing fit, 12 for a model nothing is known about); `fetch` does not (filling a stick is not about
the machine it is plugged into).

Exit codes of `ci-os-models`: ci-stick's `0 ok, 1 error, 2 usage, 3 drift, 4 no space, 5 licence (others still fetched), 6
interrupted / network down / --offline with work left, 7 integrity`, each explained on stderr, plus `10` ci-stick not
installed, `11` nothing fits this machine, `12` reference refused, `13` cache not writable by this user (the volume is mounted
for `ollama`: run as root or `ollama`). `fetch --pack` with several items stops at 4, 6 and 7 and goes on after 3 and 5.

## Background prefetch (design; OFF by default)

`ci-os-models-prefetch.path` starts `ci-os-models-prefetch.timer` only when the flag file exists (the timer has no `[Install]`
section, so with the flag absent nothing is scheduled); the timer wakes up the service; `ExecCondition=/usr/bin/ci-os-models prefetch-check` lets the service run only if
**all** of these hold (each one is a test case): the flag file `/etc/ci-os/models-prefetch` exists; in a live session the
persistence volume is really in use (`persistent` on the command line, ext4 label `writable`/`casper-rw`, mounted by casper:
the same test as `ci-os-live-container-storage`), so a flag in a plain ISO session's RAM never counts; `models.conf` names a
`pack=`; ci-stick is installed; the cache is a CI-CACHE-like volume that is writable by the unit's user and not on
`tmpfs`/`ramfs`/`overlay`/...; the rate in `limit_rate` (default `5MiB/s`) is one ci-stick parses and ci-stick has a bandwidth
option; the default route's NetworkManager metered state is `no` or `no (guessed)` (`unknown` only with
`assume_unmetered=1`; `yes (guessed)` counts as metered, as the NM docs advise); no setup access point is up
(`/run/setup-device/configuring`, `/run/ci-setup/hostapd.conf`, `hostapd-setup.service`, `ci-setup-ap.target` or an `iw` interface
in AP mode). A skipped run is "condition not met" in the journal, not a failure. The job fetches the pack's models that
this machine can run (the gate), `Nice=19`, idle I/O, `CPUWeight=10`, never accepts a licence unless `accept_licenses=1`.
Statuses 3, 4 and 5 end the run quietly (nothing more to do until a person acts); 6, 7 and 1 fail the unit.

To turn it on: `printf 'pack=appliance-core\n' > /etc/ci-os/models.conf; touch /etc/ci-os/models-prefetch`. The path unit
is the only thing enabled; the flag file is the switch (it also starts the timer if created while the system is up). Progress for the setup portal is `<cache>/ci-models/status.json`,
written by ci-stick.

## How the ISO gets the ci-stick binary (WP7: design only, nothing built)

Facts: no backend ships `ci-stick` today; there is no musl build in the repo; the bundle plans `tools/linux-x86_64/ci-stick`
on `CI-SHARED` (exFAT, mounted `noexec` by the selector, so it would have to be copied to tmpfs before it can run); the
crate needs a C compiler and assembler for `ring`; Ubuntu 24.04 has glibc 2.39, and CachyOS (Arch) has a newer one.

| Option | Good | Bad |
|---|---|---|
| A. Run the copy from the stick's own bundle (`CI-SHARED/tools/...`), after copying to `/run` | needs no image change; always the version of the stick | only on a booted or host-installing stick; nothing on an installed disk or on a plain ISO; needs the copy-to-tmpfs step and a signature check |
| **B. Bake a pinned, prebuilt binary into the image** (`/usr/lib/ci-os/ci-stick`, sha256 in `tier-b-pins.env`), built by a release job on Ubuntu 24.04 | one rule for both ISOs and the installed system; the pattern Tier-B already uses for Ollama, Tailscale and the Launcher; reproducible; the image build needs no Rust | a release artifact to host and to refresh; a glibc floor of 2.39 (fine for Ubuntu 24.04 and Arch) |
| C. Static musl build | runs on any host and in a minimal initramfs | needs a musl C toolchain for `ring` (or zig); one more target to test; not needed by the two ISOs |
| D. Compile in the chroot or on the build host (`cargo build --release --locked`) | no artifact to host | the ISO build then depends on a Rust toolchain >= 1.75 and on crates.io; minutes added to every build; the lock must be honoured with `incompatible-rust-versions = fallback` |
| E. A `.deb` / PKGBUILD in an apt/pacman repo | proper upgrades | a repository to run; heavy for one binary |

Recommendation: **B for the Ubuntu ISO and the installed system, A as an addition for host installs**, and for CachyOS the
same prebuilt glibc binary placed by the overlay (or a PKGBUILD later). `ci_models_stick_bin` already looks in `PATH`,
`/usr/lib/ci-os/ci-stick` and `/usr/local/bin/ci-stick`.

What a build step would pin in `core/manifest/tier-b-pins.env`, in the file's own format (plain `KEY=value`, reviewed
date bumped in the same commit); the values below are placeholders, there is no release yet:

```
# ---- ci-stick (the Companion Stick CLI, stick/; prebuilt by the release job on Ubuntu 24.04, linux-x86_64, glibc >= 2.39)
CI_STICK_VERSION=<crate version>
CI_STICK_SOURCE_COMMIT=<40 hex: the commit of stick/ it was built from>
CI_STICK_URL=<https URL of the release asset>
CI_STICK_SHA256=<64 hex>
CI_STICK_SIZE=<bytes>
```

and what the step does, in the order Step 10e uses: download to the build host, check size then sha256 against the pin
(fail the build otherwise), `file`/ELF check, `install -m 0755 -o root -g root` to `usr/lib/ci-os/ci-stick`, then the
`verify-iso.sh` assertions: the file exists, is executable, `ci-stick --version` (run in the chroot) prints
`CI_STICK_VERSION`, `ci-stick models --help` lists `fetch`, and no `models-prefetch` flag file is present
(`/etc/ci-os/models-prefetch` absent) in a freshly built image. If the release is signed with the bundle key (who holds the
release key is still undecided), the step could check a detached signature as well; the sha256 pin is what exists today.

## Follow-ups in files this change does not own

1. **Required with the Arch gate.** `backends/cachyos/provision/provision.sh` (`check_models`) treats every `llm.models`
   entry of `ecosystem.yaml` as required and ends "degraded" (exit 74, tried again) when one is missing. The Arch
   provisioner now skips `qwen3.6:27b` on a machine that cannot hold it, so on such a machine that check could never pass.
   `check_models` has to skip what the gate refuses: source `core/lib/gpu-detect.sh` and, inside the loop over `$want`,
   `if declare -F ci_os_model_gate_allows >/dev/null && ! ci_os_model_gate_allows "$m"; then echo "[CI-OS] $m skipped on
   purpose: $CI_OS_MODEL_FIT_REASON" >&2; continue; fi`.
2. `customize-chroot.sh`: the install lines above, and stage `core/manifest/model-packs.yaml` (and the lock, once there is one)
   into `/usr/lib/ci-os/bootstrap/core/manifest/` next to `ecosystem.yaml`, or the gate has no data on an installed machine.
3. The same three-line gate (`ci_os_model_gate_allows qwen3.6:27b`) in `backends/ubuntu/provision/install-models.sh`,
   `backends/fedora/provision/provision.sh` and `backends/nixos/modules/ecosystem.nix`.
4. `verify-iso.sh`: the files above exist with the modes in the table; `ci-os-models help` runs in the chroot; the units pass
   `systemd-analyze verify`; `/etc/ci-os/models-prefetch` does not exist; `ci-os-hf-view.service` and
   `ci-os-models-prefetch.path` are enabled and the timer is not.
5. `core/lib/check-repo.sh`: run `bash backends/ubuntu/chroot/tests/models-all.sh` (about a minute on a quiet machine;
   `--mutation` is manual).
6. `docs/architecture/models-tooling.md` (still says the adapter is "not built yet"), `tier-b-tools.md` section 5 (the new
   variables and mount-option knobs) and `companion-stick.md` (command table).
7. CachyOS installer: place the units and the drop-in from `backends/cachyos/iso/overlay/files/airootfs/usr/share/ci-os/models/`
   (its README lists the targets) and the binaries; a unit file added to the overlay at its final path needs a
   `carry-over.list` line, and a script a `file_permissions` entry.

## Tests (no root, no Docker, no network)

`backends/ubuntu/chroot/tests/`: `models-gate.sh` (reader, decision table to the MiB, detectors, the provisioners' real
functions), `models-view.sh` (layout, idempotence, odd and hostile names, planted symlinks, pruning, the lock reader,
parallel builders), `models-lib.sh` (cache, environment, every ci-stick status, fallbacks, `ensure`, the prefetch
condition one case at a time), `models-env.sh` (the real env script against stubs), `models-units.sh` (the unit files, the Arch-based edition's
copies, the conf example and profile snippet, file modes), `models-mutation.sh` (110 broken copies of the code, one rule
each, run four at a time; every one must make its test fail, none may survive). `models-all.sh` runs the first five,
`models-all.sh --mutation` adds the last. Run them on bash 3.2 and 5, and as a normal user (as root the unwritable-cache
cases are skipped, and `models-env.sh` needs a block device node, or root to make one).

## Not verified

- Anything on a booted image: the units under real systemd (no `systemd-analyze verify` result beyond the syntax check
  was available here; run it where systemd is), `ExecCondition=` skipping, the timer re-arming, `User=ollama` on the live medium.
- The exFAT mount and `OLLAMA_MODELS` on it with this script on a real device (tested on 2026-10-13 for the old script;
  here `mount` is a stub).
- `nvidia-smi`, `rocm-smi` and amdgpu sysfs output formats are from documentation and memory of the tools, not from
  hardware; the unified-memory carve-out arithmetic has not seen a Strix Halo.
- That huggingface_hub and llama.cpp read the view (see above), and `ci-stick` itself (its CLI was read from source in
  `cmd_models.rs`; no binary was run).
- NetworkManager's `GENERAL.METERED` words were read from nmcli's source; a real `nmcli` was not run. The gate looks at the
  device's runtime state (`nmcli -g GENERAL.METERED device show <default-route device>`), not at `connection.metered`, which
  is only what the profile was configured to say.
- Intel GPU memory (Arc, integrated) is not detected: such a machine counts as CPU-only for the models that name a
  GPU minimum. Only NVIDIA (`nvidia-smi`), AMD (`rocm-smi`, amdgpu sysfs) and the Strix Halo unified-memory rule are read.
