# Strix Halo ROCm on Companion OS (Ubuntu 26.04): which ROCm source

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Status 2026-10-18: **open decision. This page does not pick.** It sets two ways of getting ROCm onto the Ubuntu edition side by side, says what is known about each, and says what would settle it.
The previous version of this page was a plan for the retired Ubuntu 24.04 base (ROCm 7.2.4 from `repo.radeon.com` through `amdgpu-install`, with a repair for its version discovery); that
code was deleted when the helper was rewritten for 26.04 (commit `0ce308e`) and the plan is in git history. Section 6 keeps what it found.

Evidence tags: **[V]** verified (read in the cited file, or run), **[R]** recorded by someone else in the cited document and not re-measured here, **[N]** not checked or not implemented.

## 1. Context

* Support rule (`core/lib/gpu-detect.sh`): a Strix Halo-class APU (Ryzen AI Max, gfx1151, Radeon 8060S) with at least about 32 GB of RAM. Any other machine makes `install-rocm-driver.sh` exit 0 without installing a driver. [V]
* The GPU driver is the kernel's own `amdgpu` (inbox). No `amdgpu-dkms`, on either option below. Ubuntu 26.04.1 ships Linux 7.0.0-30; Strix Halo needs 6.17 or newer, and the helper warns, without changing the kernel, when the running one is older. [V] `install-rocm-driver.sh`
* The ISO does not bake ROCm in. It ships a wrapper, `ci-os-install-rocm` (`customize-chroot.sh`, Step 6), and ROCm is installed after the install by `provision.sh` (tier `hardware`, line 1682), by that wrapper, or by
  `ci-os-post-validation.sh` after pairing. [V]
* The GTT boot parameters (`iommu=pt amdgpu.gttsize=... ttm.pages_limit=...`) that unlock large unified memory are applied by `backends/ubuntu/lib/strix-halo-boot-params.sh` (called from `provision.sh`, line 1695). They exist **only in
  the Ubuntu edition**; the CachyOS edition has no equivalent. [V]
* The CachyOS edition gets ROCm from Arch's own `extra` repository through the frozen Arch provisioning engine (`backends/arch/provision/provision.sh`, decision D8). It is a third source and is not part of this decision.

## 2. Option A: the Ubuntu archive's ROCm 7.1 (what the build and the helper do today)

| Item | Fact | Tag |
|---|---|---|
| Packages | `rocm`, `rocminfo`, `rocm-smi` by `apt-get install`; resolute amd64 versions rocm 7.1.0, rocminfo 7.1.1, rocm-smi 7.1.1 (looked up 2026-10-17) | [V] `install-rocm-driver.sh` (`ROCM_PACKAGES`), `apt-cache` |
| A name that is not there | `rocm-smi-lib` is **not** a package in resolute; naming it made apt refuse the whole install. The helper now checks every name first, names the missing ones, and installs nothing from another release's repositories | [V] |
| Trust path | the Ubuntu archive's signing key, already on the system; no vendor repository, no key to pin | [V] |
| Other releases | the helper stops with an error and changes nothing on any Ubuntu release but 26.04 | [V] `lib/tests/install-rocm-driver.sh` |
| Tests | `backends/ubuntu/lib/tests/install-rocm-driver.sh`: 38 checks (42 with `CI_TEST_ARCHIVE=1` against the real archive), 3 mutants killed; run by `core/lib/check-repo.sh` | [V] |
| Installed on hardware | never. The names were looked up, not installed; the hardware gate and the kernel check were unit-tested with stubs | [N] |
| Does 7.1 run gfx1151 workloads | not checked. The retired plan recorded AMD's Strix Halo matrix as marking 7.2.1 to 7.2.3 stable; it did not say what 7.1 does | [N] |

## 3. Option B: AMD's ROCm 10.0 repository for Ubuntu 26.04 (what the fleet runs)

| Item | Fact | Tag |
|---|---|---|
| Source | `https://stable.repo.amd.com/rocm/core/packages/ubuntu2604/` | [R] CI-Engineering `operations/cursor-fleet-hub.md`, "ROCm 10 rollout" |
| Packages | `amdrocm10.0-gfx1151` (Strix Halo), `amdrocm-core10.0-gfx1150` (Strix Point), `amdrocm10.0-gfx1036`; one package per GPU family | [R] same page |
| Version on the fleet | ROCm 10.0.0-4, `rocminfo` shows gfx1151 / 8060S on `beta-max`, `core-1`, `core-2`, `core-3`, `core-6`, `bench-1`, `bench-2` and `bdc-core` (`core-3` was upgraded from amdrocm 7.13) | [R] measured 2026-09-01 and 2026-09-11, not re-measured since |
| Kernel driver | inbox `amdgpu`; the unsigned DKMS driver was removed on several nodes to bring `/dev/kfd` back | [R] |
| Ticket | CI-Engineering issue 203 | [R] |
| Not on the fleet | `core-4` (still Ubuntu 24.04.5 when last measured) and `beta-3-glass` (NVIDIA) | [R] |
| In this repository | nothing installs it: a search of the tracked tree for `ubuntu2604`, `amdrocm` and `stable.repo.amd.com`, made before this page named them, found nothing | [V] |
| Signing key and fingerprint of that repository | not captured anywhere in the repository. A Tier B style pin (fingerprint checked before use, see [tier-b-tools.md](../architecture/tier-b-tools.md)) would need it | [N] |
| Whether the repository answers today, and for how long it keeps 10.0 | not checked | [N] |

## 4. The decision

| | A: archive 7.1 | B: AMD repository 10.0 |
|---|---|---|
| Matches the fleet | no | yes |
| Third-party repository and key to pin | no | yes |
| Package choice | one set for every GPU | one package per GPU family, so the helper must map the detected GPU to a name |
| Updates | with the Ubuntu archive | on AMD's schedule |
| Evidence that it runs gfx1151 | none | recorded on eight machines (section 3) |
| Code in this repository | exists and is tested | none |

Questions that settle it:

1. Do the Hub, Ollama and ComfyUI containers expect ROCm 10 on the host, or do they carry their own user space? (`install-rocm-driver.sh` prints a ComfyUI hint for Strix Halo.)
2. Does the archive's 7.1 enumerate gfx1151 and run a model on it? One fleet node reinstalled from a 26.04.1 image can answer it:

```bash
sudo ./backends/ubuntu/lib/install-rocm-driver.sh
rocminfo | grep -E 'Marketing Name|gfx'
ls -l /dev/kfd /dev/dri
apt-cache policy rocm rocminfo rocm-smi
```

3. What signs the AMD repository, and may a Companion OS image trust it?
4. Should the image or first boot ever install ROCm automatically on a machine that passes the support rule, as `provision.sh` does today for the `hardware` tier?

Nothing below depends on the answer.

## 5. What stays the same either way

* Inbox `amdgpu`, no DKMS; the kernel gate at Linux 6.17; the render and video group handling; the `/dev/kfd` and `/dev/dri` check after install and the reboot advice.
* The support rule of `core/lib/gpu-detect.sh` and the GTT parameters of `strix-halo-boot-params.sh`.
* `core/manifest/role-map/apt.yaml` (`rocm:`) says "ROCm from the Ubuntu 26.04 archive (rocm, rocminfo, rocm-smi; ROCm 7.1)". It describes option A and has to change with the decision.
* The workflow release notes (`.github/workflows/build-companion-os-iso.yml`) use version-free wording about ROCm; they need no edit unless option B is chosen.

## 6. History: the retired 24.04 plan

Kept because it explains the shape of the old helper, not as a requirement. All of it concerned Ubuntu 24.04 (noble), which is retired.

* There was no ROCm 7.3 on AMD's `amdgpu-install` index; the newest Ryzen-compatible line on noble was 7.2.4 (`repo.radeon.com/amdgpu-install/7.2.4/ubuntu/noble/...`).
* AMD's Strix Halo guidance required `--no-dkms` (inbox `amdgpu`), and marked 7.2.1, 7.2.2 and 7.2.3 stable with a new enough kernel (24.04 HWE 6.17.0-19 or OEM 6.14.0-1018). [R] AMD's pages, read when the plan was written
* The helper's discovery of the "newest" installer picked the 31.40 Radeon graphics line instead of a ROCm 7.2.x line, and had to be fixed.
* ROCm 7.14 existed in mainline documentation without an `amdgpu-install` path; the plan decided not to chase it.
* The 26.04 rewrite deleted `amdgpu-install`, `repo.radeon.com`, the DKMS handling and the version discovery, and kept the groups, the kernel check and the verification (commit `0ce308e`). `backends/arch/provision/provision.sh:1210` (frozen) still has a comment that says Ubuntu pins 7.2.4.

See also: [ubuntu-2604-port-notes.md](../architecture/ubuntu-2604-port-notes.md) (the port) and [tier-b-tools.md](../architecture/tier-b-tools.md) (how vendor repositories and keys are pinned in the image).
