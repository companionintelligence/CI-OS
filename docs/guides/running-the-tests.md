# Running the tests

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

One page that lists every test suite of the repository, what each one covers, what it needs, whether the gate runs it, and which ones to
run for the change you made. The suites are described in more detail next to the code: [`backends/ubuntu/iso/README.md`](../../backends/ubuntu/iso/README.md)
("Script tests: what runs where"), [`backends/cachyos/README.md`](../../backends/cachyos/README.md) ("Tests"),
[`stick/README.md`](../../stick/README.md), [`headless-setup.md`](../architecture/headless-setup.md) (section 9). The environment variables
the suites read are in the [environment reference](environment-reference.md).

Evidence tags: **[V]** read in the file named, or run and the result seen; **[I]** read from the code and not run in that form.

## The rules every suite follows

| Rule | Why |
|---|---|
| Exit 0 passed, 1 failed, **2 cannot run here** | A suite that needs a tool the host lacks (root, `xorriso`, overlayfs, Docker, QEMU, GNU `dd`) exits 2 and is reported as "cannot run here", never as a pass. `core/lib/check-repo.sh` prints those lines with a leading `!`. |
| bash 3.2 and BSD tools on the host | The suites run on a stock macOS and in Ubuntu 26.04 containers (bash 5.3, uutils coreutils, sudo-rs). See [Building on a Mac](building-on-a-mac.md#host-tools-and-the-bash-32-rule) for the rules a new script must keep. |
| Every check can fail | A verifier or a test is itself tested against a good and a broken fixture, and a mutation check proves that weakening the code turns a test red. |
| A new file must be `git add`ed | `core/lib/check-untracked-deps.sh` fails when a tracked script names an untracked file. It looks at scripts and configuration, **not at Markdown or `docs/`**: a new document that nothing links to is not caught by the gate. |

## The gate

```bash
PATH="$HOME/ci-os-venv/bin:$PATH" ./core/lib/check-repo.sh      # about 6 minutes on a loaded laptop
```

It needs `git`, `shellcheck`, `python3` with PyYAML and `yamllint` (macOS: `brew install shellcheck yamllint`, and a virtual environment for
PyYAML; see Building on a Mac). It is what the `PR checks` workflow runs, and the four workflows are manual-only today, so **run it
yourself before every push**. `SKIP_CACHYOS_TESTS=1` skips the CachyOS block (`check-repo.sh`, "CachyOS edition tests"), for a change that
cannot affect it; do not use it for a push.

## Index of the suites

"Gate" means `check-repo.sh` runs it. "Manual" means nothing runs it for you.

### Static checks and guards (gate)

| What | Covers | Needs |
|---|---|---|
| `bash -n`, `shellcheck -S error` | every shell file | shellcheck |
| `((VAR++))` guard, retired product names, retired distro names, block-letter art | text rules | git |
| `py_compile`, `yamllint -d relaxed` | Python and YAML files | python3, yamllint |
| shebang files executable, no committed build artefacts | file modes and names | git |
| `core/lib/check-untracked-deps.sh` (its own test: `core/lib/tests/untracked-deps.sh`) | a tracked script naming an untracked file | git |

### Ubuntu edition

| Suite | Command | Covers | Needs | Where |
|---|---|---|---|---|
| One-click installer unit tests | `python3 backends/ubuntu/chroot/tests/test_auto_install.py` | the safety rules, state machine and zenity options of `ci-os-auto-install` (121 tests) | python3, PyYAML | gate |
| ISO `md5sum.txt` | `bash backends/ubuntu/iso/tests/md5sum-txt.sh` | `md5sum-txt.sh` and its wiring in `build-iso.sh`; with `xorriso` and GNU `dd` also the mini-ISO part (Part B). `CI_TEST_STOCK_ISO=<stock ISO>` adds the real `md5sum.txt` | awk, find, a hash tool | gate |
| Live GRUB menu modules | `bash backends/ubuntu/iso/tests/grub-live-menu-modules.sh` | the `insmod` lines of the live menu against the module list of the signed GRUB | GNU sed and stat for part of it | gate |
| Layer split, Part A | `bash backends/ubuntu/iso/tests/split-live-layer.sh` | the helpers of `scripts/lib/split-live-layer.sh` on synthetic trees | none special | gate |
| Installed-boot self-test | `bash backends/ubuntu/iso/tests/installed-boot.sh --selftest` | the harness's own parsing and verdicts | python3 | gate |
| OS model adapter | `bash backends/ubuntu/chroot/tests/models-all.sh` | `ci-os-models.sh`, the cache environment, the Hugging Face view, the hardware gate, the units (five test files and `models-mutation.sh`) | none special | gate |
| os-release writer, ROCm, LACT, shell theme, dock list | `bash backends/ubuntu/lib/tests/{os-release-golden,install-rocm-driver,lact-release,shell-theme,dock-favorites}.sh` | the golden files, the archive package names, the release lookup, the overlay decision, the dock list and what its reader refuses | glib tools for `shell-theme.sh` | gate |
| `customize-chroot.sh` guards | `bash backends/ubuntu/chroot/tests/customize-chroot-checks.sh` | the refusal of a base that is not 26.04, 24.04 included, and the step order | none special | gate |
| Headless package dependencies | `bash backends/ubuntu/headless-package/tests/control-depends.sh` | `DEBIAN/control` against the payload's needs | none special | gate |
| gresource provenance | `bash core/render/tests/gresource-provenance.sh` | the tracked GNOME Shell blob rebuilds byte for byte from Yaru 26.04.5.1 | glib tools | gate |
| Layer split, Part B | `SPLIT_TEST_CHROOT=<rootfs> bash backends/ubuntu/iso/tests/split-live-layer.sh` (`SPLIT_TEST_ONLY=B1` audits a NEW base ISO) | the whole split on a real merged rootfs and the stock layers | root, overlayfs, a privileged ARM64 `ubuntu:26.04` container | manual |
| Installer-base verifier | `bash backends/ubuntu/iso/tests/verify-installer-base.sh` | section 3g of `verify-iso.sh`: every check against a good image and a defect each (226 variants) | python3 | manual |
| Logo-surface verifier | `bash backends/ubuntu/iso/tests/verify-logo-surfaces.sh` | the logo checks of `verify-iso.sh` section 4b | none special | manual |
| Boot-media branding | `bash backends/ubuntu/iso/tests/boot-media-plymouth.sh` (`CI_TEST_STOCK_INITRD=<stock casper/initrd>` for the real initrd) | `brand_boot_media`, the initrd overlay, `.disk/info` | throw-away `ubuntu:26.04` container (`unmkinitramfs`, `cpio`, `zstd`) | manual |
| Plymouth, placeholder layer | `bash backends/ubuntu/iso/tests/{plymouth-ground-render,placeholder-layer-modes}.sh`, `bash backends/ubuntu/desktop-theme/tests/plymouth-theme.sh` | what the real Plymouth plugin draws; layer modes; the rootfs Plymouth step | container; the command is in each header | manual |
| Desktop-theme and chroot tests | `bash backends/ubuntu/desktop-theme/tests/{about-logo-svg,visible-names,about-logo-no-renderer,start-icon-from-mark}.sh`, `bash backends/ubuntu/chroot/tests/{no-dracut-pin,render-preflight}.sh`, `bash backends/ubuntu/headless-package/tests/netplan-keeps-networkmanager.sh`, `bash core/lib/tests/{divert-file,grub-nearest-color}.sh` | the About logo, the visible names, apt pinning, the render preflight, netplan, `dpkg-divert`, the nearest GRUB colour | throw-away `ubuntu:26.04` container (root, dpkg) for most; the command is in each header | manual |
| First-boot units under systemd | `bash backends/ubuntu/chroot/tests/first-boot-units-boot.sh` (`--selftest` runs only its containment logic: 43 checks, no Docker, about a second) | host keys and the rebrand unit with an installer-style machine-id (45 checks and 14 boots in the contained default, `f20d3a6`; the earlier privileged version reported 41) | Docker, cgroup v2; **it boots systemd as PID 1 in a contained container by default (no `--privileged`, no added capability, `CAP_SYS_ADMIN` deliberately not granted, a gate that refuses first)**, so it runs on Docker Desktop for Mac; `CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED=1` is the explicit override, see below | the run: manual; `--selftest`: gate |
| Installed-system harness | `bash backends/ubuntu/iso/tests/installed-boot.sh --iso <ISO> [--no-boot]` | a disk assembled the way an install ends up, initrds regenerated, then booted in QEMU to the greeter (`--no-boot` stops after the 25 static checks: 413 s on the clean-checkout image; with a boot, 681 s on the fix-pass image) | privileged Docker (`--platform linux/amd64`) and QEMU | manual |
| Whole image | `VERIFY_BASE_ISO=<stock ISO> VERIFY_REQUIRE_CANON=1 backends/ubuntu/iso/scripts/verify-iso.sh <ISO>` | 393 checks, sections 1 to 9 (34 s) | xorriso, squashfs-tools, zstd, cpio, python3 | manual, per image |

### CachyOS edition

| Suite | Command | Covers | Needs | Where |
|---|---|---|---|---|
| Overlay engine, brand, installer, verifier self-test | `bash backends/cachyos/iso/tests/{overlay-engine,overlay-brand,installer-config,verify-selftest}.sh` | the merge engine and its guards, identity and hooks, the installer overlay with the launcher (`installer-launcher.sh`, including the `shell-timeouts` guard), the stager and first-boot provisioning (`installer-stage.sh`), the filter (`progress-filter.sh`), the compat lock and the gate (`compat-libs.sh`, `gate-calamares.sh`), and every check of `verify-iso.sh` against a good and a broken fixture (336 checks, about 20 s) | bash 3.2, awk, sed, python3 with PyYAML (check with `python3 -c 'import yaml'`) | gate |
| QEMU boot helper | `bash backends/cachyos/iso/tests/qemu-boot.sh --selftest` | the helper code of the boot recipe | python3 | gate |
| Mini ISO | `backends/cachyos/iso/tests/verify-mini-iso.sh` | the real overlay and renderer into a 15 MB ISO, then `verify-iso.sh` (about 2 minutes) | Docker, network | manual |
| Container tests | `backends/cachyos/iso/tests/{overlay-engine-container,overlay-pacstrap,overlay-hook-pacman,overlay-menu-shot,compat-gate-container,first-boot-units-container,first-boot-drain-container}.sh` | the pipeline up to `mkarchiso`, identity against real pacman hooks, the boot menus in QEMU, the installer gate on the real packages (about 10 minutes), `systemd-analyze verify`, the first-boot drain | Docker, network for most; **these never run systemd as PID 1** | manual |
| Boot in QEMU | `backends/cachyos/iso/tests/qemu-boot.sh <ISO> --mode uefi` | an ISO reaches a login prompt or the Plasma session | QEMU, OVMF; slow without KVM | manual |
| Whole image | `backends/cachyos/iso/scripts/verify-iso.sh <ISO>` inside the builder image (README "Verify") | the 8 sections, about a minute | Docker, `VERIFY_FETCH_UPSTREAM=1` needs the network | manual, per image |

### Setup portal and `ci_setup` (shared)

| Suite | Command | Covers | Needs | Where |
|---|---|---|---|---|
| Payload tests | `bash core/headless/tests/payload/run.sh [-v] [SUITE...]` | the backend, hotspot scripts, monitor, the installers of both editions (`test_static.py`, `test_monitor.sh`, `test_hotspot_start.sh` dominates the time) | python3; Flask optional (a stand-in is used) | gate |
| Payload mutation check | `python3 core/headless/tests/payload/mutation-check.py [-k WORD] [--list]` | undoes each fix in a copy and expects a test to fail (98 mutations at the retirement: 95 killed, 3 equivalent, 0 survived). **`run.sh` does not call it**; run it by hand after changing the payload or its installers | python3; slow | manual |
| `ci_setup` library, quick | `bash core/headless/tests/ci_setup/run.sh --quick` | the library's unit tests and the repository-hygiene test that reads `docs/architecture/headless-setup.md` (about half a minute) | python3 3.8 or newer | gate; **also run it after editing that document** |
| `ci_setup` library, full | `bash core/headless/tests/ci_setup/run.sh [--pythons "python3 python3.9"]` | adds the mutation check and the interpreter matrix | several interpreters | manual |
| hwsim hotspot | `stick/tests/qemu/hotspot-hwsim.sh` | the real hostapd, wpa_supplicant, dnsmasq and portal over `mac80211_hwsim` in a QEMU guest of the ISO | Linux with QEMU; `stick/tests/qemu/README-hotspot.md` | manual |

### Companion Stick

| Suite | Command | Covers | Needs | Where |
|---|---|---|---|---|
| Rust | `(cd stick && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test)` | the `ci-stick` crates: 238 passed, 1 ignored in the last full run | Rust 1.75 or newer; for the flash tests also `gdisk dosfstools exfatprogs e2fsprogs mtools`, otherwise they skip | PR workflow (the `stick` job), not `check-repo.sh` |
| Rust, MSRV | `(cd stick && cargo +1.75 check --locked --all-targets)` | the oldest supported compiler | rustup | PR workflow |
| Rust, live registry | `CI_STICK_LIVE=1 CI_STICK_LIVE_DIR=<scratch dir> cargo test --test models_live -- --nocapture` (in `stick/`) | `ci-stick models fetch` against the real Ollama registry: downloads `nomic-embed-text:latest`, 274 MB, into the scratch directory | network; **opt-in**: without `CI_STICK_LIVE=1` the test prints a note and returns | manual |
| Flash and boot in QEMU | `stick/tests/qemu/run.sh` | flash a sparse 64 GB image and boot it three times (slot A, persistence, slot B), a tampered bundle, device-safety refusals: `RESULT: PASS`, 17 PASS lines | **Linux** tools (`sgdisk`, `mkfs.exfat`, `mcopy`, `grub-mkstandalone`, `apt-get`, `dpkg-deb`, QEMU, OVMF); on a Mac, run it in a container (below) | PR workflow (`stick-qemu`); manual on a Mac |
| Secure Boot A, B, C | `stick/tests/secureboot/run-on-mac.sh` | the signed chain boots with Secure Boot on, an unsigned chain is refused, Secure Boot off boots (8 checks); `--iso <ISO>` boots a given ISO | macOS with QEMU and Docker; builds in an `ubuntu:26.04` container | manual |
| Docker in a live session | `stick/tests/qemu/docker-live.sh iso` (also `stick`) | Docker as the unprivileged live user; **retired baseline (24.04.5) result only**, not re-run on 26.04 | Linux with QEMU | manual |

### Brand and docs

| Check | Command | When |
|---|---|---|
| Brand bundle intact | `core/lib/vendor-brand.sh --check` | after touching `vendor/brand/` |
| Brand mirrors match the bundle | `core/lib/check-brand-mirrors.sh` (`--write` rewrites the mirrors) | after touching the setup portal's logo or font, or `assets/logos/` |
| Model-pack lock current | `ci-stick models lock --check` | after touching `core/manifest/model-packs.yaml` |
| Headless setup document | `bash core/headless/tests/ci_setup/run.sh --quick` | after editing `docs/architecture/headless-setup.md` |

## I changed X, run Y

| You changed | Run |
|---|---|
| Anything | `./core/lib/check-repo.sh` |
| `core/headless/payload/**` or either edition's payload wrapper | `payload/run.sh`, then `mutation-check.py`; for a new dependency also `control-depends.sh` and `installer-config.sh`; the change ships on both editions |
| `core/manifest/**` | `check-repo.sh`; `ci-stick models lock --check` for `model-packs.yaml` |
| `core/lib/gpu-detect.sh`, `ci-os-models.sh` | `bash backends/ubuntu/chroot/tests/models-all.sh` |
| `core/render/**`, `vendor/brand/**`, `assets/` | `gresource-provenance.sh`, `vendor-brand.sh --check`, `check-brand-mirrors.sh`, `grub-nearest-color.sh`; then a build and `verify-iso.sh` ([brand bump steps](../../core/README.md#bumping-the-brand-bundle)) |
| `backends/ubuntu/iso/scripts/build-iso.sh`, `md5sum-txt.sh` | `md5sum-txt.sh`, `grub-live-menu-modules.sh`, `boot-media-plymouth.sh` (container), then a real build |
| `backends/ubuntu/iso/scripts/lib/split-live-layer.sh` | `split-live-layer.sh` Parts A and B, `verify-installer-base.sh` |
| Ubuntu `verify-iso.sh` | `verify-installer-base.sh`, `verify-logo-surfaces.sh`, then `verify-iso.sh` on a built image |
| `backends/ubuntu/chroot/**` | `customize-chroot-checks.sh`, `test_auto_install.py` (the installer helper), `no-dracut-pin.sh`, a real build |
| `backends/ubuntu/desktop-theme/**` | the tests in `desktop-theme/tests/` in a container |
| `backends/cachyos/installer/**` | `bash backends/cachyos/iso/tests/installer-config.sh`, then a built ISO and `verify-iso.sh` |
| `backends/cachyos/iso/overlay/**`, `scripts/**` | `overlay-engine.sh`, `overlay-brand.sh`, `verify-selftest.sh`; `verify-mini-iso.sh` when Docker is at hand |
| `backends/cachyos/compat-libs.lock` or the gate | `installer-config.sh` (runs `compat-libs.sh` and `gate-calamares.sh`), `compat-gate-container.sh` |
| `stick/**` | the Rust commands, then `stick/tests/qemu/run.sh` (flash, boot slots, GRUB configuration) and, for the signed chain, `stick/tests/secureboot/run-on-mac.sh` |
| Documents only | `check-repo.sh` (retired names, tracked-file guard); `ci_setup/run.sh --quick` if you touched `headless-setup.md` |

## Checking documents by hand

The gate does not look at documents (see the rules above), so check these before a document change is committed. First, that nothing is
untracked and every new document is in the index:

```bash
git status --short docs README.md CLAUDE.md          # '??' lines are untracked: git add them
for f in $(git ls-files -o -c --exclude-standard 'docs/*.md' | grep -v -e '^docs/README.md$'); do
  grep -q "${f#docs/}" docs/README.md || echo "not in the docs index: $f"
done
```

Second, that every relative link and anchor resolves (the script reads Markdown, skips fenced code and web links, and compares an anchor with
the headings of the target file in GitHub's style; save it as `linkcheck.py` outside the repository):

```python
import os, re, sys
bad = 0
for f in sys.argv[1:]:
    txt = re.sub(r'```.*?```', '', open(f, encoding='utf-8').read(), flags=re.S)
    for m in re.finditer(r'\[[^\]]*\]\(([^)\s]+)\)|<img src="([^"]+)"', txt):
        t = m.group(1) or m.group(2)
        if t.startswith(('http', 'mailto:')): continue
        path = t.split('#')[0]
        full = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else f
        if not os.path.exists(full):
            print('MISSING', f, t); bad += 1
        elif '#' in t and full.endswith('.md'):
            heads = [re.sub(r'[^\w\- ]', '', h.strip().lower()).replace(' ', '-')
                     for h in re.findall(r'^#+\s+(.*)$', open(full, encoding='utf-8').read(), flags=re.M)]
            if t.split('#', 1)[1] not in heads: print('ANCHOR?', f, t); bad += 1
sys.exit(1 if bad else 0)
```

```bash
python3 linkcheck.py $(git ls-files -o -c --exclude-standard '*.md' | grep -v -e '^vendor/')
```

Third, the dash rule for new prose (no em or en dashes) and the host-path rule (no `/Users/` or scratch paths):

```bash
git diff -U0 -- '*.md' | grep -E '^\+[^+]' | grep -n -e $'\xe2\x80\x94' -e $'\xe2\x80\x93' || echo "no em or en dashes in added lines"
grep -rn -E '/Users/|/private/tmp/' --include='*.md' docs README.md CLAUDE.md | grep -v -e 'running-the-tests.md' -e 'evidence/README.md' || echo "no host paths"
```

## Running the Stick QEMU suite on a Mac

`stick/tests/qemu/run.sh` needs Linux tools, so on Apple silicon it runs inside a privileged `ubuntu:26.04` container with QEMU in software
emulation. The recorded run used an ARM64 container and ended `RESULT: PASS` with 17 PASS lines **[V]** (the log `qemu-run-sh/run.log` of the
2026-10-18 port work). The command below is the `stick-qemu` job of `.github/workflows/pr-checks.yml` adapted to a Mac; it was **not run in
exactly this form [I]**. Software emulation makes each boot slow (the script allows 480 s per boot without KVM).

```bash
docker run --rm --privileged --platform linux/arm64 -v "$PWD":/src -w /src -e DEBIAN_FRONTEND=noninteractive ubuntu:26.04 bash -euo pipefail -c '
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates cargo qemu-system-x86 ovmf-generic grub-efi-amd64-bin grub-common \
    gdisk dosfstools mtools exfatprogs e2fsprogs xorriso busybox-static cpio zstd util-linux
  stick/tests/qemu/run.sh'
```

The container builds `ci-stick` itself (no `CI_STICK_BIN`), and writes `stick/target/` into your checkout through the bind mount, which is
ignored by git. This container does not run systemd.

## Tests that start systemd as PID 1

A privileged container that boots systemd as PID 1 wipes the Docker VM's Rosetta registrations on Docker Desktop for Mac, and `CAP_SYS_ADMIN`
alone lets a container mount the shared `binfmt_misc` itself (see
[Building on a Mac](building-on-a-mac.md#never-run-systemd-as-pid-1-in-a-privileged-container)). `backends/ubuntu/chroot/tests/first-boot-units-boot.sh`
is such a test by construction (its containers run `/sbin/init`), and its first version ran them `--privileged`; that it was the trigger of the
2026-10-18 wipes is **[I]**, by timing only. Since commit `f20d3a6` it is **contained by default [V]** (the commit's author ran it on Docker
Desktop 29.8.2; not re-run for this page):

- the default profile has no added capability, the default seccomp profile, `--cgroupns=host` and a tmpfs `/run`, and all its checks and boots pass in it. The
  system ends `degraded` (`tmp.mount`, `systemd-resolved` and `netplan-configure` fail), and none of the units under test depends on them;
- **`CAP_SYS_ADMIN` is deliberately not granted**: a container that has it can mount the shared `binfmt_misc` itself;
- a gate runs before any systemd container exists, with the same flags and a plain shell, and stops the test with exit 1 if `/proc/sys` is writable,
  a write to it is accepted, or `mount -t binfmt_misc` succeeds; the four binfmt and sysctl units are masked in every container, and every boot is probed again;
- if the contained profile cannot boot systemd on an engine (cgroup v1, a hardened daemon) the test exits 2 and never falls back by itself. The override is
  `CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED=1`, which runs the containers `--privileged` (the masks stay, the gate is skipped, and where the engine looks shared a banner
  and a 10 second pause come first). **Do not set it on Docker Desktop, OrbStack, Colima or Rancher Desktop**: run the test on a Linux Docker host or in a QEMU
  guest. That the masks alone keep the handlers safe in the override is not verified, on purpose;
- `--selftest` runs the decision logic against canned probe reports and a fake `docker` (43 checks, 14 mutants killed) and is in `core/lib/check-repo.sh`.

Use this script as the reference for any new test that needs systemd as PID 1. The CachyOS container tests say in their headers that they never do this,
and `first-boot-drain-container.sh` refuses to start when systemd is PID 1.

© Companion Intelligence, Lifescope Inc
