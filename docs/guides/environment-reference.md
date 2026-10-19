# Environment reference

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

The environment variables an operator or a maintainer sets, grouped by area. Before this page most of them were documented only in the
header of the script that reads them. Each row says what the variable does, its default and where it is read (**[V]**: read in that file).

Two kinds are left out on purpose: the **test seams** (variables that point a test at a stub or a scratch directory, for example
`CI_OS_PROC_MEMINFO`, `CI_OS_SYSFS_DRM`, `CI_OS_LOCK_FILE`, `CI_OS_CMDLINE_FILE`, `CI_OS_NETWORK_PROBE`, `CI_OS_FORCE_TTY`,
`CI_OS_BOOTSTRAP_ROOT`, `CI_OS_STATE_DIR`, `CI_OS_LOG_FILE`; each is listed in the header of the script that reads it) and the pure test
parameters of the unit suites. Credentials are never set in a variable that is written to a log: see [CI-Hub deploy](ci-hub-deploy.md).

## Building the Ubuntu image

Read by `backends/ubuntu/iso/scripts/build-iso.sh` and `backends/ubuntu/chroot/customize-chroot.sh`; the options of the script itself are in
its header and in [`backends/ubuntu/iso/README.md`](../../backends/ubuntu/iso/README.md).

| Variable | Values, default | What it does |
|---|---|---|
| `CI_OS_ALLOW_OTHER_BUILD_HOST` | `1` to skip the check, unset | `build-iso.sh` stops on a host that is not Ubuntu 26.04 with Yaru; `1` lets it continue with a warning, for a host you verified yourself |
| `CI_OS_BAKE_THIRD_PARTY` | `0` or `1`, default `1` | tailscale, cloudflared and `gh` from the vendors' apt repositories, pinned keys |
| `CI_OS_BAKE_OLLAMA` | `0` or `1`, default `1` | Ollama from the vendor's pinned release tarball (never `install.sh`) |
| `CI_OS_BAKE_LAUNCHER` | `0` or `1`, default `1` | the Companion Launcher `.deb` from `dl.ci.computer`, pinned sha256 |
| `CI_OS_BAKE_CAPTURE` | `0` or `1`, default `1` | the Companion Capture `.deb`, pinned sha256. Its release is on a **private** GitHub repository: the build uses the file in `CI_OS_CACHE_DIR` when it matches the pin, otherwise `gh release download` (`gh` signed in, or `GH_TOKEN` with read access to `companionintelligence/CI-Capture`), and stops if neither works |
| `CI_OS_OLLAMA_CUDA` | `all` (default) or `none` | `none` drops Ollama's bundled CUDA libraries: about 2.0 GiB installed, about 1.5 GB less in the ISO |
| `CI_OS_LAUNCHER_AUTOSTART` | `0` (default) or `1` | start the Launcher at graphical login on the installed system |
| `CI_OS_CACHE_DIR` | a path, default `~/.cache/ci-os` | download cache for the Ollama tarball (about 1.5 GB) and the Launcher and Capture `.deb`s; on a Mac recipe put it on the volume (`/vol/cache`) |
| `CI_OS_TIERB_PINS` | a path, default `core/manifest/tier-b-pins.env` | the pins file; a fingerprint or sha256 mismatch aborts the build |

Pins are fail-closed. The knobs and the size each one saves are in [`tier-b-tools.md`](../architecture/tier-b-tools.md).

## Verifying an Ubuntu image

Read by `backends/ubuntu/iso/scripts/verify-iso.sh`.

| Variable | Values, default | What it does |
|---|---|---|
| `VERIFY_BASE_ISO` | the stock 26.04.1 ISO | also compare the Secure Boot binaries, the kernel block and the volume id with the stock image |
| `VERIFY_REQUIRE_CANON` | `1` | fail if the brand content checks, which need the repository checkout, could not run |
| `VERIFY_MAX_ISO_BYTES` | default 8,589,934,592 (the 8 GiB boot slot of a 64 GB Stick) | the image must be at most this size |
| `VERIFY_TIERB` | `0` | skip section 3c, for an image built with `CI_OS_BAKE_THIRD_PARTY=0` |
| `VERIFY_KEEP`, `VERIFY_WORK` | `1`; a directory (about 8 GB free) | keep the extracted files; choose the scratch space |

## Building and verifying the CachyOS image

Read by `backends/cachyos/iso/scripts/build-iso.sh` (host), `in-container/20-build.sh` and `verify-iso.sh`. The host script's options
(`--out`, `--version`, `--cpus`, `--memory`, `--jobs`, `--require-clean`, `--allow-dirty`, `--stop-after`, `--fallback-pin`, ...) are in its
header and in [`backends/cachyos/README.md`](../../backends/cachyos/README.md).

| Variable | Values, default | What it does |
|---|---|---|
| `CI_OS_VERSION` | default `1.0` | the version in `os-release` and the build record (`--version` overrides) |
| `CI_OS_PIN` | `primary` (default) or `fallback` | which upstream commit of `upstream.lock` to build; `--fallback-pin` sets it |
| `CI_OS_JOBS` | a number | `mksquashfs` threads (`--jobs` sets it) |
| `CI_OS_UPSTREAM_REUSE` | `1` | verify and reuse an existing checkout in `$CI_OS_UPSTREAM_DIR` instead of fetching upstream |
| `CI_OS_COMPAT_LIBS` | `off` | stage no compatibility libraries; this is how the installer gate was proven to fail |
| `CI_OS_COMPAT_REVIEW` | `error` | turn a passed `review-by` date of `compat-libs.lock` into a failure; use it for a release |
| `VERIFY_REQUIRE_CLEAN` | `1` | fail unless the build record says `REPO_TREE=clean`; also fails an overdue compat review |
| `VERIFY_REQUIRE_ALL` | `1` | fail if any group of checks had to be skipped |
| `VERIFY_FETCH_UPSTREAM`, `VERIFY_UPSTREAM_DIR` | `1`; a checkout | enable the kernel-line parity checks (network, or a mounted checkout at the pinned commit) |
| `VERIFY_MIN_MB`, `VERIFY_MAX_MB` | default 1500 and 6144 | the size window; `VERIFY_MIN_ENTRIES` (default 1000) is the fewest files the squashfs may hold |
| `VERIFY_GRUB_EXTRA_PARAMS` | `"a=b c"` | kernel parameters the overlay may add to upstream's lines |
| `VERIFY_SKIP_SFS_HASH`, `VERIFY_KEEP`, `VERIFY_WORK`, `VERIFY_REUSE` | `1`; `1`; a directory; `1` | skip the 20 s squashfs hash; keep or reuse extracted files; scratch space (about 4 GB, not a macOS bind mount) |

## The live installer on CachyOS

Read by `backends/cachyos/iso/overlay/files/airootfs/usr/local/bin/calamares-online.sh`.

| Variable | Values, default | What it does |
|---|---|---|
| `CI_OS_INSTALLER_UPDATE` | `auto` (default) or `0` | take a newer `cachyos-calamares-next` when it passes the guards, or keep the one on the ISO. The kernel parameter `ci_os.installer_update=0` does the same from the boot menu |
| `CI_OS_SKIP_KEYRING` | `1` | skip the keyring work, the database sync and NTP, for a machine whose keyring already works |

## Models and the hardware-fit gate

Read by `core/lib/gpu-detect.sh` and `core/lib/ci-os-models.sh`. The gate decides whether a provisioner pulls a model: see
[`models-tooling.md`](../architecture/models-tooling.md) and KI-01. **The gate checks RAM and GPU memory, not disk space.**

| Variable | Values, default | What it does |
|---|---|---|
| `CI_OS_MODEL_FIT_OVERRIDE` | `allow` or `deny` | force the answer of `ci_os_model_fits`: `allow` pulls a model the machine does not fit, `deny` skips every model. **The operator's way to override the gate.** Checked before any data is read |
| `CI_OS_MODEL_RAM_PCT` | default 91 | a model needs `min_ram_gb` GiB times this percent of RAM (a "32 GB" machine reports about 30,000 MiB) |
| `CI_OS_MODEL_VRAM_PCT` | default 95 | the same for GPU memory (a 24 GB card reports 24,564 of 24,576 MiB) |
| `CI_OS_FIT_CPU_OK` | `1` | accept CPU-only speed for models that name a minimum GPU memory |
| `CI_OS_FIT_RAM_MIB`, `CI_OS_FIT_VRAM_MIB`, `CI_OS_FIT_UNIFIED` | numbers; `0` or `1` | override the detected facts (support and tests) |
| `CI_OS_MODEL_PACKS_FILE` | a path | use this `model-packs.yaml`; without any file the gate has **no data and does not block** (the Plasma edition's situation, KI-01) |
| `CI_OS_MODELS_CACHE` | a path | the model cache root; otherwise the `CI-CACHE` volume where it is mounted |
| `CI_OS_MODEL_LOCK_FILE` | a path | the model lock, before `/usr/share/ci-os/model-packs.lock.json` and the repository's file |
| `CI_OS_CACHE_UMASK`, `CI_OS_CACHE_GROUP` | default umask 0077 | widen the mount options of the model cache; nothing else changes them (`models-env.sh`) |

## First boot on CachyOS

Read by `backends/cachyos/provision/first-boot-setup.sh`; the defaults are the installed system's. `sudo ci-os-setup` re-runs it.

| Variable | Default | What it does |
|---|---|---|
| `CI_OS_NETWORK_TRIES`, `CI_OS_NETWORK_SLEEP` | 30 and 2 (seconds) | how long the script waits for a network before it exits 0 and leaves a retry to the timer |
| `CI_OS_OLLAMA_TRIES`, `CI_OS_OLLAMA_SLEEP` | 30 and 2 (seconds) | the readiness poll of the wrapper `provision.sh` for the Ollama server, before it reports a model missing (exit 74) |
| `CI_OS_FALLBACK_HOME` | `/root` | `HOME` for the provisioner when the unit has none |

## The Companion Stick (`ci-stick`)

| Variable | Default | What it does |
|---|---|---|
| `CI_STICK_RETRY_BASE_MS` | 1000 | first back-off delay of `ci-stick models fetch` |
| `CI_STICK_STALL_TIMEOUT_S` | 30 | how long a transfer may stall |
| `CI_STICK_CHUNK_BYTES` | | initial and maximum request size |
| `CI_STICK_JOURNAL_BYTES` | 64 MiB | bytes between two `fsync`s of a partial download and its journal: a killed process loses at most this much progress |

They change how patiently and in what pieces `fetch` talks to the registry and never weaken a check (`stick/crates/ci-stick/src/cmd_models.rs`).

## Tests

| Variable | What it does | Read by |
|---|---|---|
| `SKIP_CACHYOS_TESTS=1` | skip the CachyOS block of the gate | `core/lib/check-repo.sh` |
| `CACHYOS_UPSTREAM_ARCHISO`, `CACHYOS_TEST_FETCH=1` | let `overlay-brand.sh` check the patches against the pinned upstream (a checkout's `archiso/`, or fetch the pin) | `backends/cachyos/iso/tests/overlay-brand.sh` |
| `CI_OS_REAL_CALAMARES_ROOT=<dir>` | run the installer guards on the real files of an unpacked installer too | `installer-config.sh` |
| `CI_TEST_STOCK_ISO`, `CI_TEST_STOCK_INITRD` | run `md5sum-txt.sh` against the real stock ISO and `boot-media-plymouth.sh` against the real stock initrd | the Ubuntu ISO tests |
| `SPLIT_TEST_CHROOT`, `SPLIT_TEST_ONLY` | Part B of the layer-split test on a rootfs; run only one group, for example `B1` to audit a new base ISO | `split-live-layer.sh` |
| `CI_OS_BOOT_TEST_IMAGE` | the builder image of `installed-boot.sh` (default `ubuntu:26.04`) | `installed-boot.sh` |
| `PAYLOAD_DIR`, `BACKENDS_DIR` | test another copy of the payload and the installers (the mutation checker does) | `core/headless/tests/payload/` |
| `PYTHON`, `CI_SETUP_FUZZ_N`, `CI_SETUP_FUZZ_SEED`, `CI_SETUP_UPDATE_GOLDEN=1` | interpreter, fuzz size and seed; rewrite the golden files (read the diff before you commit) | `core/headless/tests/ci_setup/run.sh` |
| `CI_STICK_BIN`, `CI_STICK_QEMU_WORK`, `CI_STICK_QEMU_TIMEOUT`, `CI_STICK_TEST_CACHE` | use this `ci-stick` binary; work directory (kept); seconds per boot (default 120 with KVM, 480 under TCG); kernel download cache (default `~/.cache/ci-stick-test`) | `stick/tests/qemu/run.sh` |
| `CI_STICK_TEST_SYSDISK_WRITE_REFUSAL=1` | also check that a write at the host's own system disk is refused; skipped by default on a developer machine | `stick/tests/qemu/run.sh` |
| `CI_STICK_LIVE=1`, `CI_STICK_LIVE_DIR=<dir>` | the opt-in live registry test (downloads 274 MB) | `stick/crates/ci-stick/tests/models_live.rs` |

Which suite to run for which change: [Running the tests](running-the-tests.md).

© Companion Intelligence, Lifescope Inc
