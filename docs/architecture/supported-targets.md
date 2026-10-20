# Supported targets

> Private & Confidential. Property of Lifescope Inc. Do not distribute.
> Policy page. Decision of 2026-10-17 (owner): "only support cachyos and ubuntu 26, retire 24".
> Decision of 2026-10-19 (owner, in chat, asked whether arm64 should be promoted from experimental to a supported target): "yes". arm64 is a second architecture of the Ubuntu target, not a third target ([section 2](#2-what-supported-means), [`arm64.md`](arm64.md)).
> Last checked against the tree and the evidence on 2026-10-18 (commit `02c575e` for the Ubuntu rows, the Plasma ISO #6 run of the same day, built from `ad37b64`, for the Plasma rows, plus the uncommitted documentation work).

Companion OS has two supported targets. Everything else is retired. This page is the single place that says what that means, what
each target can and cannot do today, and how a target is added or brought back. The other documents link here instead of repeating
the matrix.

Evidence tags used in this page, and in the README and the evidence pages:

| Tag | Meaning |
|---|---|
| **[V]** | Verified. It was executed or read on the real artifact, and the result is recorded in the file, test or log that is named next to it. |
| **[I]** | Implemented, not proven end to end. The code and tests exist; nobody has run the real artifact through that step. |
| **[N]** | Not implemented. |

A row marked **pending** is [I] today, and a run will turn it into [V] or into a defect. The single table that says exactly what
confirms each one is in [`test-evidence.md`](test-evidence.md#pending-evidence-for-the-ubuntu-2604-image); [section 5](#5-pending-evidence)
maps the matrix rows to its IDs. Nothing in this page claims a pending row as verified, and [`test-evidence.md`](test-evidence.md) is the
single owner of the status of a run: this page quotes it, it does not restate it.

## 1. The two targets

| | Companion OS on Ubuntu 26.04.1 LTS | Companion OS on CachyOS (Plasma edition) |
|---|---|---|
| Backend | `backends/ubuntu/` | `backends/cachyos/`, with `backends/arch/` as its frozen provisioning engine |
| Base | The stock Ubuntu 26.04.1 Desktop ISO (`resolute`, sha256 `601e30fb...da1f`), repacked. 26.04.0 and every 24.04 image are not bases. | The pinned CachyOS-Live-ISO profile (archiso, commit `3215497d`, fallback `4937780`) plus a Companion overlay, built with the stock `mkarchiso` |
| Desktop | GNOME 50, one Wayland session | KDE Plasma 6 with `plasma-login-manager` |
| Architectures | **amd64** (the reference) and **arm64** (since 2026-10-19; one image per architecture; Companion Capture has no arm64 build) | x86-64 only |
| Image | `companion-os-<version>-amd64.iso`, `companion-os-<version>-arm64.iso` | `companion-os-plasma-<YYYY.MM.DD>-x86_64.iso` |
| Build entry point | `backends/ubuntu/iso/scripts/build-iso.sh`, as root on Ubuntu 26.04 | `backends/cachyos/iso/scripts/build-iso.sh`, any host with Docker |
| Verifier | `backends/ubuntu/iso/scripts/verify-iso.sh` | `backends/cachyos/iso/scripts/verify-iso.sh` |
| Where the details live | [`backends/ubuntu/iso/README.md`](../../backends/ubuntu/iso/README.md), [`ubuntu-iso-layers.md`](ubuntu-iso-layers.md) | [`backends/cachyos/README.md`](../../backends/cachyos/README.md), [`cachyos-backend.md`](cachyos-backend.md) |

`core/` (manifest, render, shared libraries, the headless setup payload) and `stick/` (the `ci-stick` CLI) serve both targets.
`backends/arch/` is not a target and offers no entry point of its own; see [section 6](#6-backendsarch-is-not-a-target).

## 2. What "supported" means

A target is supported when the repository does all of the following for it, and keeps doing them on every change:

1. **It builds.** There is a documented command that produces the image, or provisions a machine, from a clean checkout.
2. **It is verified without booting.** A verifier that can fail runs on the finished image (`verify-iso.sh`), and its checks are
   themselves tested against a good and a broken fixture (`backends/cachyos/iso/tests/verify-selftest.sh`,
   `backends/ubuntu/iso/tests/verify-installer-base.sh`, `verify-logo-surfaces.sh`).
3. **Its fast tests are in the gate.** `./core/lib/check-repo.sh` runs the target's host-side suites; a suite that needs a tool
   the host lacks exits 2 and is reported as "cannot run here", never as a pass.
4. **Its limits are written down with evidence tags** in this page and in the target's own README.
5. **It is the subject of maintenance.** A defect in a supported target is fixed in this repository; documentation, workflows and
   tests follow the target.

For an architecture the five points apply to its image: arm64 meets them with the gaps that [`arm64.md`](arm64.md#gaps-against-the-five-points) names (no CI job, no fixture self-test of the verifier's arm64 branches, one run on one host).

"Supported" does **not** mean released, signed, hosted or proven on real hardware. No Companion OS image is published today and no
run on physical hardware is recorded for either target ([N]; see [known issues](known-issues-and-decisions.md)).

## 3. Capability matrix

Read each cell with its tag. The evidence for every [V] is in [`test-evidence.md`](test-evidence.md), in the target's own README or
in the commit message named in the cell; the text records of the main runs are in [`../evidence/`](../evidence/README.md), and the
remaining capture records of the QEMU runs are still in a session scratch directory outside the repository.

| Capability | Ubuntu 26.04.1 | CachyOS Plasma |
|---|---|---|
| Image build | **[V]** Clean checkout at `02c575e`: `build-iso.sh --clean` exited 0 after **772 s** (12 min 52 s) in a privileged ARM64 `ubuntu:26.04` container on an Apple-silicon Mac on 2026-10-18 and produced `companion-os-1.0-amd64.iso`, 7,076,577,280 bytes, sha256 `709b8485...f5cf` (`docs/evidence/2026-10-18-ubuntu-clean-02c575e/`). The earlier full build of a worktree snapshot during the fix pass (version string 9.9, `dce9eb71...6a11`) took 860 s and gave the same size. | **[V]** Six ISOs built, 2026-10-16 to 2026-10-18; every ISO whose size is recorded (#1, #2, #4, #5, #6) is 3,217,129,472 bytes. 25 to 26 minutes on a lightly loaded host (ISO #4 26 min, ISO #5 25 min, ISO #6 about 26 min, from the clean commit `ad37b64`; `docs/evidence/2026-10-18-plasma-iso6/`), 31 to 37 minutes under Rosetta on a loaded one (`cachyos-backend.md`, Test status). |
| Static verification | **[V]** `verify-iso.sh` with `VERIFY_BASE_ISO` and `VERIFY_REQUIRE_CANON=1` on the clean-checkout image: 393 passed, 0 failed, 0 skipped in 34 s (`docs/evidence/2026-10-18-ubuntu-clean-02c575e/verify.log`); the same count on the fix-pass image. | **[V]** `verify-iso.sh` on ISO #6: **215 passed, 0 failed**, no skipped group, about 84 s (`docs/evidence/2026-10-18-plasma-iso6/verify.log`); it includes the checks of the compatibility libraries, the first-boot properties and the explicit Calamares time limits. 187 passed, 0 failed on ISO #2. **No `verify-iso.sh` log of ISO #4 or ISO #5 was kept** (test-evidence, Plasma row 8: done for ISO #6). |
| arm64 image (the second architecture of the Ubuntu target) | **[V]** built natively three times and verified (438 passed, 0 failed on the current commit `4b7597d`), live desktop with trusted shortcuts, one-click install (12 min 10 s), installed boot, first sign-in without Canonical's first-run page, first-boot provisioning (1 min 58 s) with Hub up on its pairing screen, all in QEMU with HVF on an Apple-silicon Mac, 2026-10-19 (`docs/evidence/2026-10-19-ubuntu-arm64-4b7597d/`, [`arm64.md`](arm64.md), frames in [`docs/ui/companion-os/ubuntu/`](../ui/companion-os/ubuntu/CAPTURE.md)). Companion Capture is absent (no arm64 build). Secure Boot, real hardware, the Stick and CI are **[N]**. | **[N]** x86-64 only. |
| Size against the Stick slot | **[V]** 7,076,577,280 bytes against the 8 GiB (8,589,934,592) slot of a 64 GB stick; `verify-iso.sh` section 9 fails an image above it. | n/a, the Stick cannot boot this image. |
| Live session boots | **[V]** The themed GRUB menu of the fix-pass image draws under the Secure Boot OVMF variant. The GNOME live desktop: **pending** (test-evidence U3, U4, U5). | **[V]** UEFI GRUB to the Plasma desktop under QEMU/OVMF with software emulation; first frame 4 min 10 s after Enter (ISO #4), 4 min 05 s (ISO #5), 5 min 08 s (ISO #6, a busier host; settled after 6 min 38 s). Frames: `docs/ui/companion-os/plasma/`. |
| Installer | Canonical's installer (`ubuntu-desktop-bootstrap`, subiquity), plus "Install Companion OS (automatic)". | Calamares (`cachyos-calamares-next`) with a Companion overlay. Online only. |
| Install to disk | **[I]** Pending (U6 interactive, U7 one-click). The installed-boot harness (`installed-boot.sh --iso`) builds a disk from the installer base layer the way an install ends up and booted it to the GDM greeter in 230 s **[V]**, on the **fix-pass snapshot image** (version 9.9, `dce9eb71...6a11`; `docs/evidence/2026-10-18-ubuntu-fixpass-9.9/installed-boot-result.txt`), not on the clean-checkout image; on that one only the `--no-boot` run was made (25 PASS). Neither is a run of the installer. | **[V]** ISO #4: all 47 Calamares jobs, "completion: succeeded", exec phase 22 min 9 s on a 30 GiB virtual NVMe, installed system boots to login and desktop. ISO #5: all 47 jobs in 23 min 20 s on the third attempt, installed boot **[V]** (`graphical.target` after 37.8 s); the first two attempts failed in `create-pacman-keyring` (30 second default, KI-20; see section 4). ISO #6 (`ad37b64`): all 47 jobs in 28 min 26 s on the **first** attempt, the keyring step 32 s under its explicit limit; installed boot **[V]** (greeter 1 min 32 s after Enter, `graphical.target` after 43.9 s of userspace); one run, in a virtual machine. |
| One-click automatic install | **[I]** 204 unit tests (`test_auto_install.py`, run by `check-repo.sh`); not yet driven on a booted ISO. Pending (U7). | **[N]** |
| First-boot provisioning | **[I]** Pending (U8). | **[V]** ISO #4: pulled the three models in 16 min 4.6 s and ended "degraded" because of a defect. ISO #5 (the fix of commit `552063f`): 21 min 49 s, `status=0/SUCCESS`, `.first-boot-setup-done` written, no "degraded", a 367-line log (`test-evidence.md`, Plasma ISO #5). ISO #6: 21 min 19 s, exit 0, the marker, all three models, a 301-line log (`test-evidence.md`, Plasma ISO #6). |
| Docker | **[I]** Baked into the image and also meant to run in live sessions; not booted on 26.04. | **[V]** Installed system: `Docker version 29.9.1`, service enabled and running on a fresh install (ISO #4; the version again on ISO #6). The live medium has no Docker **[V]**. |
| Models | **[I]** Ollama baked in (pinned tarball); models pulled at first boot; `qwen3.6:27b` only on a Strix Halo class machine, and then the model-fit gate applies on top. | **[V]** `nomic-embed-text`, `gemma3:1b` and `qwen3.6:27b` pulled on first boot (ISO #4, #5 and #6). The set takes about 18.8 GB; a 30 GiB disk ended 88 % full. |
| Headless Wi-Fi setup (hotspot) | **[I]** `setup-device` package in the image; the QEMU hwsim harness was not run on 26.04. | **[I]** Payload staged by Calamares; units present on the installed system **[V]**; no access point has been brought up (the VM has no Wi-Fi). |
| Companion Stick boot | **[V]** The stock 26.04.1 ISO boots from slot A under Secure Boot to early systemd; `stick/tests/qemu/run.sh` ends `RESULT: PASS` with 17 PASS lines in its summary and the Secure Boot A, B, C run (8 checks) passes. A Companion image on a Stick: **[I]**, pending (U10). | **[N]** The Stick's boot menu is built for casper (`stick/crates/ci-stick/src/bootcfg.rs:44-45,188`). |
| Secure Boot | **[I]** Inherited from the base ISO (shim, Canonical GRUB, Canonical kernel); `verify-iso.sh` compares those binaries with the stock ISO. The themed menu of the fix-pass image draws under Secure Boot; a boot to the live system is pending (U9). | **[N]** Unsigned standalone GRUB and unsigned kernels. |
| GPU, ROCm | **[I]** ROCm packages from the Ubuntu 26.04 archive (7.1 at the time of writing) on Strix Halo class machines only; the inbox amdgpu driver. | **[I]** `ollama-vulkan` is installed. ROCm and LACT only through `ci-os-setup --tier=core,hardware`. |
| Strix Halo unified-memory boot parameters | **[I]** `backends/ubuntu/lib/strix-halo-boot-params.sh`, with `amdttm.pages_limit` too where AMD's DKMS amdgpu driver is installed. Its rewrite of the GRUB line is rehearsed on throwaway files by `backends/ubuntu/lib/tests/strix-halo-boot-params.sh` **[V]**. | **[N]** Nothing in `backends/cachyos/` or `backends/arch/` sets `amdgpu.gttsize` or `ttm.pages_limit`. |
| Reproducible package set | Partly. Base ISO pinned by sha256 and GPG signature; third-party keys and downloads pinned in `core/manifest/tier-b-pins.env`; apt packages are not snapshotted. | **[N]** Rolling. Neither the live package set nor the install-day set is pinned; `.pkgs.txt` and `.build-info` record what a build got. |
| Offline install | **[I]** The installer copies the layer from the medium; first-boot provisioning needs the network. | **[N]** Online installer only. |
| Real hardware | **[N]** | **[N]** |
| Public hosting, signing key holder | **[N]** Open decision. | **[N]** Open decision. |

## 4. Caveats per target

### Ubuntu 26.04.1

* **Build host.** `build-iso.sh` stops on any host that is not Ubuntu 26.04 with Yaru installed, unless
  `CI_OS_ALLOW_OTHER_BUILD_HOST=1`. On a Mac use the privileged **ARM64** `ubuntu:26.04` container recipe in
  [`building-on-a-mac.md`](../guides/building-on-a-mac.md#recipe) (the same commands are in the README): it is the route that produced the
  image **[V]**. An amd64 `ubuntu:26.04` container is "may fail": on 2026-10-17 one on Docker Desktop for Apple silicon failed with GNU tar
  1.35 "Function not implemented" under Rosetta (`stick/tests/secureboot/build-in-container.sh` checks for it first), and on 2026-10-18 another
  one ran `installed-boot.sh --no-boot` to the end (25 PASS). The trigger was not isolated **[N]**.
* **arm64** is a supported architecture of this target since 2026-10-19, with the limits of [`arm64.md`](arm64.md): QEMU/HVF only, no Secure Boot or hardware run, no `ci-stick` support, no Capture, no CI job, and the installed system reads "degraded" on non-Snapdragon machines (`pd-mapper.service`, KI-28).
* **The installer window stays Ubuntu's.** It is Canonical's snap; "Welcome to Ubuntu" and the roundel are inside it. The launcher
  label and the last page read "Companion OS" through `/.disk/info`. The one-click path uses its own progress window.
* **Installer base layer and live layer.** The image is split so that the installed system never receives live-only content
  (`ubuntu-iso-layers.md`). The merged base is initramfs-tools based, and `/etc/apt/preferences.d/ci-os-no-dracut` pins dracut out.
* **ROCm source is an open decision.** The build installs ROCm from the Ubuntu archive; AMD publishes a newer line for 26.04.
  See [`docs/plans/strix-halo-rocm-companion-ubuntu.md`](../plans/strix-halo-rocm-companion-ubuntu.md).
* **One-click install is the headline path and is unproven.** Its safety rules are pinned by tests
  ([`one-click-install.md`](one-click-install.md)); the run that drives it on a booted ISO is pending.
* **Retired baseline (24.04.5).** Numbers measured on 24.04.5 appear in the Ubuntu documents only where they explain a design
  decision, and are labelled as such.

### CachyOS Plasma edition

* **Online only, rolling.** The installer builds the target from the network, and the package set differs from build to build and
  again on install day. An ISO built weeks ago installs whatever the repositories hold. The boost soname skew found on
  2026-10-18 (risk R1, `cachyos-backend.md`) is the example: it dates from 2026-08-13, two months before the first Companion OS ISO, and is now caught
  by a build gate and bridged by `compat-libs.lock`.
* **No Secure Boot, and the Stick cannot boot it.** Neither is on a roadmap in this repository.
* **Disk size and model gate.** The installed system takes about 7.9 GiB; the model set adds about 18.8 GB. Give the machine 64 GiB
  or more. No guard stops a model pull that does not fit the disk; the right place is `ci_os_model_gate_allows` in
  `core/lib/gpu-detect.sh` **[N]**. On this edition the RAM and GPU-memory part of that gate has no data on an installed system
  (`model-packs.yaml` is not staged), so `qwen3.6:27b` is pulled on every machine (KI-01 in `known-issues-and-decisions.md`).
* **The keyring step (KI-20): fixed, seen once.** On ISO #5 (2026-10-18) the first two Calamares attempts failed at 2 percent with
  "create-pacman-keyring failed to finish in 30 seconds"; the third ran all 47 jobs **[V]**. The cause was established: the installer's own
  `shellprocess_initialize_pacman.conf` gives that command no `timeout` key, so Calamares applies its 30 second default, and the step takes
  about 28 to 32 seconds under software emulation (a real machine does it in a few seconds **[I]**). Commit `ad37b64` ships overlay copies of
  three stock `shellprocess` configs with explicit time limits and a `shell-timeouts` guard that fails the launcher when any command of the
  install sequence has none. **ISO #6 installed on its first attempt**, the step took 32 s and passed under the explicit limit **[V]**, in one
  run in a virtual machine; a second run and any physical machine are still to do.
* **Names that stay CachyOS.** `ID=cachyos`, `ID_LIKE=arch`, `VARIANT="Plasma (based on CachyOS)"`, kernel and package names.
  `ID_LIKE=arch` is what CI-Hub's installers match. The image, ISO file name and boot menus carry no CachyOS mark. Whether the
  name may be used publicly is an open decision (D1 in `backends/cachyos/README.md`, `NOTICE`).
* **Cosmetic findings from the ISO #4, #5 and #6 runs** are listed in `known-issues-and-decisions.md` (KI-07 to KI-09, KI-26). Fixed and seen on
  ISO #6 **[V]**: the GRUB menu no longer lists firmware leftovers, the install status line says "Companion OS" for the drivers job, the zone popup
  and the radio buttons have highlights. Still open, all Low: the boot splash says "COMPANION INTELLIGENCE", raw pacman text in the install status
  line names `cachyos` packages, three Calamares highlight gaps, log noise and a greeter without the Companion mark, and `ollama.service` is
  disabled until first boot.

### Both

* **The setup portal is a stop-gap.** The shared payload under `core/headless/payload/` runs a root Flask backend on an open
  access point. The stop-gap fixes landed in `b882e00`; a human security review is still required
  ([`headless-setup.md`](headless-setup.md), 51 defects found in the audit of 2026-10-17). The tested replacement library
  `core/headless/ci_setup/` is not wired into any service.
* **Credentials found by the 2026-10-12 review have not been rotated.** See `known-issues-and-decisions.md`. No document in this
  repository copies a credential value.

## 5. Pending evidence

The pending rows of the matrix are [I] today. **There is one table that says what confirms each of them**, with the command, the pass
condition and the place the proof will be written: [Pending evidence for the Ubuntu 26.04 image](test-evidence.md#pending-evidence-for-the-ubuntu-2604-image)
(IDs U1 to U11) and [Pending evidence for the Plasma edition](test-evidence.md#pending-evidence-for-the-plasma-edition). This page keeps only the
mapping from the matrix rows to those IDs, so the two pages cannot disagree.

| Matrix row | ID in `test-evidence.md` |
|---|---|
| Ubuntu: live session boots | U3 live desktop, U4 boot menu and splash, U5 `casper-md5check` |
| Ubuntu: install to disk | U6 interactive installer, U7 one-click install; U2 installed system boots (the harness boot of the clean-checkout image) |
| Ubuntu: one-click automatic install | U7 |
| Ubuntu: first-boot provisioning, Docker | U8 |
| Ubuntu: Secure Boot | U9 |
| Ubuntu: a Companion image on a Stick | U10 |
| Both: real hardware | U11 and KI-17 |
| Plasma: static verification | Plasma row 8: **done** for ISO #6 (215 passed, 0 failed); no log of ISO #4 or #5 exists |
| Plasma: Secure Boot firmware refuses the unsigned GRUB | Plasma row 9 |
| Plasma: install without the keyring timeout | Plasma row 10 (KI-20): **done once** on ISO #6; row 11 asks for a second run |
| Plasma: real hardware, KVM, offline, BIOS | Plasma row 13 and KI-17 |

The Ubuntu image's build and static verification on a clean checkout are **done** (the matrix above; the stage that the capture's early
notes called U0). The Plasma first-boot fix and most of the installer look are **seen on ISO #5**, and the keyring-step fix, the driver-job label, the
clean installed GRUB menu and the verifier log are **seen on ISO #6** (the matrix above; test-evidence, Plasma ISO #5 and ISO #6), so the Plasma
edition has no row here except those above. As each pending row is run, its text records go into a new directory of
[`../evidence/`](../evidence/README.md) and the row moves from pending to [V] in `test-evidence.md` in the same change.

## 6. `backends/arch` is not a target

`backends/arch/` is the pacman provisioning engine that the CachyOS edition runs on first boot (decision D8). It offers users no
entry point and no ISO. It is **frozen**: it is never edited unless the owner decides to, because the CachyOS wrapper
(`backends/cachyos/provision/provision.sh`) and the payload tests depend on its exact behaviour.

| Path | Role |
|---|---|
| `backends/arch/provision/provision.sh` | Run on first boot by the CachyOS wrapper. |
| `backends/arch/headless-setup/install.sh` | Read, not run: its `ARCH_DEPS` is the dependency oracle for the setup payload tests and for the CachyOS ISO verifier. |
| `backends/arch/desktop-theme/` | Unused. Plasma brands itself through the overlay. |

The findings recorded in its comments are preserved in [`multi-distro-design.md`](multi-distro-design.md).

## 7. Retired targets and the restore recipe

Retired on 2026-10-17 by the owner's decision (restore tag `pre-retire-multidistro-2026-10-17`): Ubuntu 24.04, Linux Mint, Fedora, Bazzite and NixOS.
The four distribution backends were removed in commit `6e7b0b5`, and Ubuntu 24.04 was dropped by the 26.04.1 port (`8c20d33`, `0ce308e`, `84798a4`).

| Retired | What it was | Restore |
|---|---|---|
| Linux Mint | provisioning wrapper over the Ubuntu backend | `git checkout pre-retire-multidistro-2026-10-17 -- backends/mint` |
| Fedora | dnf provisioning, GNOME accent branding, plain installer | `git checkout pre-retire-multidistro-2026-10-17 -- backends/fedora core/manifest/role-map/dnf.yaml` |
| Bazzite | OCI image layering with bootc | `git checkout pre-retire-multidistro-2026-10-17 -- backends/bazzite core/manifest/role-map/bootc.yaml` |
| NixOS | flake of NixOS modules | `git checkout pre-retire-multidistro-2026-10-17 -- backends/nixos` |
| Ubuntu 24.04 | the noble base of the Ubuntu backend | not a backend of its own: the tag holds the whole Ubuntu backend as it was, so read it in a separate worktree (`git worktree add ../CI-OS-noble pre-retire-multidistro-2026-10-17`) and never check it out over `backends/ubuntu` |

The tag `pre-retire-multidistro-2026-10-17` points at `855cd0a`, the commit before the retirement (`bdde0ce`). **It is a local tag, and it
is reachable from one branch only** (`git branch -a --contains 855cd0a` lists `liam/companion-os-single-click-install` and nothing on the
remote; `git ls-remote --tags origin 'pre-retire*'` printed nothing when this page was written). Until it is pushed, the restore recipe works
only in this clone and in a clone made from the bundle. Push it **by name**, and never with `git push --tags`: the local snapshot tags
`phase0-snapshot/*` and `phase1-snapshot/*` of this clone contain the credentials of the 2026-10-12 review (KI-05):

```bash
git push origin refs/tags/pre-retire-multidistro-2026-10-17
git ls-remote --tags origin 'pre-retire*'
```

A bundle that contains the tag was made on 2026-10-17: `CI-OS-pre-retire-multidistro-20261017.bundle`, 25 MB, sha256
`f7483f034fcdf268b53ff0cd735b3f79e8066d8afbff8849f0f925938c96ae7b`, and `git bundle verify` reports a complete history. It is kept in the
maintainer's `_archive` directory, outside the repository. **That one copy is the only fallback until the tag is pushed, and it is not a
durable location** (KI-21): the owner names a shared place and a retention rule for it. From a clone that does not have the tag:

```bash
git fetch /path/to/CI-OS-pre-retire-multidistro-20261017.bundle \
  'refs/tags/pre-retire-multidistro-2026-10-17:refs/tags/pre-retire-multidistro-2026-10-17'
git checkout pre-retire-multidistro-2026-10-17 -- backends/mint
```

The bundle recipe above was run on 2026-10-18 into an empty repository, and the tag `pre-retire-multidistro-2026-10-17` then listed eight directories under `backends/`:
the two supported backends, `arch`, `_mixins` and the four retired ones.

A restored backend is a starting point, not a supported target: it was written against the layout of 2026-10-17 and has not been
kept in step with `core/` since. Do not re-add a retired target as new files; restore from the tag so that its history stays attached.

### What a restore touches

`git checkout pre-retire-multidistro-2026-10-17 -- backends/<name>` restores the backend directory and nothing else. The retirement
commit `6e7b0b5` changed 64 files; the authoritative list is `git show --stat 6e7b0b5`. Outside `backends/<name>/` it removed or edited the
following, and a restore that skips any of them leaves `core/lib/check-repo.sh` red or the payload tests blind to the restored installer
(the allow-list and the test edits are the two that fail a gate; the rest is context):

| # | Path | What the retirement did, and so what a restore redoes | Inverse of the change |
|---|---|---|---|
| 1 | `backends/<name>/` | removed | `git checkout pre-retire-multidistro-2026-10-17 -- backends/<name>` |
| 2 | `core/manifest/role-map/` | removed the role maps of two of the four (the dnf one and the bootc one), and edited the comments of the apt and pacman ones | `git checkout pre-retire-multidistro-2026-10-17 -- core/manifest/role-map/<file>`; the recipe table above names the file for each target |
| 3 | `core/lib/retired-names.allow` | holds the paths where retired names may appear | add the restored path to it for the time the target is restored without being supported, and delete the entry when the target is supported again: a stale entry fails the guard (section 8, step 3) |
| 4 | `core/lib/check-repo.sh` | the guard regexes `RETIRED_RE_I` and `RETIRED_RE_S` name the retired distributions and their tooling | remove the target's names from both regexes when it is supported again (section 8, step 3) |
| 5 | `core/headless/tests/payload/test_static.py` | removed the per-backend path constants and the entries of the `installers()` dict, and the tests that read the retired installers (deb dependencies, dependency lists, boot enabling, executable bits, the postinst behaviour) | `git show 6e7b0b5 -- core/headless/tests/payload/test_static.py` is the inverse patch; one line of `installers()` is what puts a restored installer under the boot-enabling tests |
| 6 | `core/headless/tests/payload/mutation-check.py` | removed the restored backends' mutation rows and their entries in `copy_tree` | `git show 6e7b0b5 -- core/headless/tests/payload/mutation-check.py`; re-run it, every mutation must be killed (the retirement ran 98: 95 killed, 3 equivalent, 0 survived) |
| 7 | `.gitignore` | removed the rendered-artifact line of the OCI image build (`backends/bazzite/image/staging/`, `pre-retire-multidistro-2026-10-17`) | add it back with the backend |
| 8 | `.claude/settings.json` | removed three `nix` permission entries (`pre-retire-multidistro-2026-10-17`, NixOS) | add them back with that backend |
| 9 | `core/render/`, `core/lib/gpu-detect.sh`, `core/headless/ci_setup/sysinfo.py` | one-line wording edits that mentioned the retired targets | see `git show 6e7b0b5` for each; cosmetic |
| 10 | The editions tables | README, `CLAUDE.md`, `AGENTS.md`, `ANTIGRAVITY.md`, `.github/copilot-instructions.md`, `opencode.json` and the steward skill were reworded to two targets | section 8, step 1 |

After a restore: run `./core/lib/check-repo.sh`, then the payload tests (`bash core/headless/tests/payload/run.sh` and the mutation check), and
treat everything else in the restored directory as untested on this tree.

## 8. How a target is added, or brought back

Only the owner adds or restores a target. The steps, in order:

1. **Decision.** The owner records it. Update the two tables in section 1 and section 3 of this page, the README edition table,
   `CLAUDE.md`, `AGENTS.md`, `ANTIGRAVITY.md`, `.github/copilot-instructions.md` and `opencode.json`, in one change.
2. **Backend.** Create `backends/<name>/` (restore it from the tag for a retired one, section 7). It must meet the per-backend contract in
   [`multi-distro-design.md`](multi-distro-design.md#10-per-backend-contract), which has ten obligations: the six of the design (a
   manifest consumer through a role map in `core/manifest/role-map/<pkgmgr>.yaml`, a theme-render consumer, an identity writer, a declared
   output mode, a validation hook, a lint or smoke test) and four that a new edition is most likely to forget: the **headless setup payload**
   wrapper and its test registration, the **first-boot provisioning** unit with its status file and re-run command, the **model gate** staging,
   and a written **Stick and Secure Boot** stance.
3. **Guard.** For a restored target, remove its names from `RETIRED_RE_I` and `RETIRED_RE_S` in `core/lib/check-repo.sh` and its
   paths from `core/lib/retired-names.allow`; the guard fails on a stale allow-list entry, so leave nothing behind. For a new
   target, add nothing to the guard.
4. **Gate.** Wire the target's host-side suites into `core/lib/check-repo.sh` (exit 2 when a tool is missing, never a silent
   skip) and its container or VM suites into the manual list in its README. Register its payload installer in the payload tests (section 7,
   rows 5 and 6).
5. **Verifier.** Write a `verify-iso.sh` equivalent whose every check can fail, with a self-test that feeds each check a good and a
   broken fixture. Mutation-check it: weaken the verifier and see the test go red.
6. **Evidence.** Build, verify statically, boot the live session, run the installer to the end, boot the installed system and let
   first-boot provisioning finish, each recorded in `test-evidence.md` with tags and its text records in [`../evidence/`](../evidence/README.md).
   Rows that have not run stay [I] with the run that will confirm them.
7. **Documents.** The target's README, an architecture page, a column in the capability matrix and the guides that name editions
   (`docs/guides/`). New files must be `git add`ed before the checks are trusted (`core/lib/check-untracked-deps.sh` covers tracked scripts
   that name an untracked file; it does not look at Markdown, so a document that nothing links to is found by the documentation index in
   [`../README.md`](../README.md), not by the gate).
8. **Review.** Security-sensitive areas (the steward skill lists them) need a human reviewer, not only a green gate.

## 9. Related pages

* [`multi-distro-design.md`](multi-distro-design.md): how `core/` and `backends/` fit together, the per-backend contract and the
  history of the retired backends.
* [`known-issues-and-decisions.md`](known-issues-and-decisions.md): open defects and decisions, with an owner column.
* [`test-evidence.md`](test-evidence.md): what has been run, where and with what result, and the one table of pending evidence.
* [`../evidence/README.md`](../evidence/README.md): the text records behind the verified rows.
* [`../guides/running-the-tests.md`](../guides/running-the-tests.md): every suite, and which one to run for which change.
* [`../README.md`](../README.md): the documentation index.
