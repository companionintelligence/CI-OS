# Known issues and open decisions

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

State of 2026-10-18 (late morning), after the October 2026 work on both supported editions. Supported targets: Companion OS on Ubuntu 26.04.1 LTS (resolute) and Companion OS on CachyOS (the "Plasma" edition). Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from the tag `pre-retire-multidistro-2026-10-17`).

This page lists what is known to be wrong or undecided and would surprise a reader of the other documents. It is not the full defect list: the 189-finding repository review of 2026-10-12 (a local report, not committed) and the 51-defect setup-portal audit ([headless-setup.md](headless-setup.md)) keep their own lists. An item is here when it blocks a release, needs a decision, or was found by running an edition. Evidence for what has been run is in [test-evidence.md](test-evidence.md).

How to read a row: **Severity** is Critical (an unauthenticated party can change the device or obtain its secrets), High (a supported configuration fails visibly, or a release cannot proceed), Medium (a real defect or gap with a narrower trigger or a workaround), Low (polish or hygiene). **Owner** is left as "owner to assign" on purpose. Evidence tags: **[V]** verified (read at the cited place or observed in a run), **[I]** inferred from verified facts, **[N]** not checked.

## Index

| ID | Item | Kind | Severity | Owner |
|---|---|---|---|---|
| KI-01 | Model pulls have no disk-space guard, and the hardware-fit gate has no data on the Plasma edition | defect | High | owner to assign |
| KI-02 | The setup portal has no real authentication; its stop-gap needs a human security review | defect, decision | Critical | owner to assign |
| KI-03 | Strix Halo unified-memory boot parameters exist only in the Ubuntu edition | gap | Medium | owner to assign |
| KI-04 | The Plasma edition has no Secure Boot and cannot boot from the Companion Stick | limit | High | owner to assign |
| KI-05 | Credentials exposed in the repository history (found 2026-10-12) are still unrotated | defect | High (Critical if live) | owner to assign |
| KI-06 | ROCm source on Ubuntu 26.04: the archive's 7.1 or AMD's own line | decision | Medium | owner to assign |
| KI-07 | `ollama.service` is installed but disabled until first boot on the Plasma edition | decision | Low | owner to assign |
| KI-08 | GRUB menu clutter, splash wording and one CachyOS label in the installer on the Plasma edition (firmware entries and label: fix in the working tree; splash: open) | defect | Low | owner to assign |
| KI-09 | Calamares theme polish is only partly fixed (popup and radio highlights: stylesheet change in the working tree, not seen in Calamares) | gap | Low | owner to assign |
| KI-10 | Ollama in Companion Stick live sessions | decision | Medium | owner to assign |
| KI-11 | The Ubuntu 26.04.1 image is built and statically verified; no installer has run on it and the clean-checkout image has never been booted | gap | High | owner to assign |
| KI-12 | Public ISO hosting, the release signing key holder and the release workflow | decision, defect | High | owner to assign |
| KI-13 | Whether the CachyOS name may be used in public text | decision | High | owner to assign |
| KI-14 | Whether the first batch needs Secure Boot | decision | Medium | owner to assign |
| KI-15 | Headroom of the Ubuntu image in an 8 GiB Stick boot slot is 1.5 GB | risk | Low | owner to assign |
| KI-16 | Build and test tooling defects found while writing the guides | defect | Low | owner to assign |
| KI-17 | No physical machine has booted either edition | gap | Medium | owner to assign |
| KI-18 | The Plasma edition drifts with the rolling release | risk | Medium | owner to assign |
| KI-19 | The apt repository `packages.ci.computer` does not exist | status | Low | owner to assign |
| KI-20 | The Calamares keyring step has a 30 second limit; two of three installs on ISO #5 failed at 2 percent under emulation (fix in the working tree) | defect | High | owner to assign |
| KI-21 | The restore tag of the retired backends is local and its only fallback is one bundle on one machine | risk, decision | Medium | owner to assign |
| KI-22 | Nobody can say what the shared tunnel certificate `CI-Local-Root-CA` is for or who holds its key | gap, decision | Medium | owner to assign |
| KI-23 | There is no release key, key custody or pipeline for `ci-stick` bundles | gap, decision | High | owner to assign |
| KI-24 | Model redistribution licences for physical sticks are not reviewed, and `fetch` does not gate Gemma or Llama | gap, decision | High | owner to assign |
| KI-25 | The `docker` group is root-equivalent for every `sudo` member of the installed system | decision | Medium | owner to assign |

## KI-01 Model pulls have no disk-space guard

**Severity:** High. **Owner:** owner to assign.

**What.** The first-boot provisioning pulls Ollama models whose sizes add up to about 18.8 GB (nomic-embed-text 0.27 GB, gemma3:1b 0.81 GB, qwen3.6:27b 17.8 GB; `core/manifest/model-packs.yaml`, `backends/cachyos/installer/README.md`). Nothing checks free disk space first.

**Evidence.**
- [V] On the Plasma edition's ISO #4 run the 30 GiB target went from 7.8 GiB used (27 percent) to 26 GiB used (88 percent, 3.7 GiB free) after the three pulls (`df -h` in the capture, frames `installed/11` and `installed/14`). A smaller disk fails a pull for lack of space. [V] On a 64 GiB target (ISO #5) the same pulls took root from 8.4 GiB to 27 GiB used (42 percent, 37 GB free).
- [V] The shared gate `ci_os_model_gate_allows` (`core/lib/gpu-detect.sh:404-415`) judges RAM and GPU memory only. The comment in `docs/architecture/models-tooling.md` says the same ("the code does not check disk").
- [V] On the Plasma edition the gate has **no data**: `core/lib/gpu-detect.sh:216-228` looks for `model-packs.yaml` next to the library (`<bootstrap>/core/manifest/`), and `backends/cachyos/installer/stage-installer.sh:107-109` copies `gpu-detect.sh`, `ecosystem.yaml` and `pacman.yaml` to the target but not `model-packs.yaml`. Without the file `ci_os_model_fits` answers 2 ("model-packs.yaml not found") and `ci_os_model_gate_allows` turns that into "not blocking" (`core/lib/gpu-detect.sh:385-388, 404-415`). The Arch provisioner then pulls the 17.8 GB model (`backends/arch/provision/provision.sh:935-940` starts from `PULL_QWEN=1`). [I] consistent with the capture, where a 6144 MiB guest with no GPU pulled `qwen3.6:27b`.
- [V] The Ubuntu edition pulls `qwen3.6:27b` only when `ci_os_hardware_supported` is true (Strix Halo class, `backends/ubuntu/provision/provision.sh:981-993`), so it pulls the two small models elsewhere. On a Strix Halo machine the one-click installer accepts a disk from 25 GB (`MIN_DISK_BYTES`, `backends/ubuntu/chroot/payload/live-start/usr/libexec/ci-os/ci-os-auto-install:58`), which cannot hold the system plus 17.8 GB [I].

**Decision and work needed.** (1) Where the guard lives: the right place is `ci_os_model_gate_allows`, skipping a model when the free space of the model directory is below its `size_bytes` plus a margin, and not counting a deliberately skipped model as missing (so the wrapper does not end "degraded" for good). `backends/arch/**` is frozen (decision D8), and the guard needs no edit there because both callers use the shared gate. (2) Stage `model-packs.yaml` on both editions so the RAM and GPU rules apply on installed machines. (3) Raise or explain the 25 GB floor of the one-click installer. Until then the guides recommend 64 GB or more.

## KI-02 The setup portal has no real authentication

**Severity:** Critical (audit items S1 and S2). **Owner:** owner to assign.

**What.** The shared headless Wi-Fi setup portal (`core/headless/payload/`) lets anyone on its access point reconfigure the device's network. `/api/configure` needs no credential; the local pairing code is never checked; the access point passphrase is a constant committed in the repository, and the portal is plain HTTP. The audit of 2026-10-17 recorded 51 defects ([headless-setup.md](headless-setup.md), section 2).

**Evidence.** [V] Audit sections 1.4 and 2.1. [V] A stop-gap landed as commit `b882e00`, whose subject says "security review required": it restricts `/api/` to the AP subnet and loopback, stops enabling `hostapd-setup` and `dnsmasq-setup` at boot, drops TKIP and `country_code=US`, scrubs secrets from logs and deletes only Wi-Fi profiles with its own name prefix; it **does not add authentication**, sandboxing, a firewall or a credential channel (section 2.7 of the audit). [V] The hotspot SSID is `Companion-Setup-XXXX` with a random suffix per boot (`core/headless/payload/usr/local/bin/setup-device-hotspot-start.sh:495-499`) and the default passphrase is a constant (same file, line 311). [V] The replacement library `core/headless/ci_setup/` is tested (471 tests in the last full gate) and is **not wired into any service**.

**Decision needed.** A human security review of the stop-gap, and the go-ahead for the redesign (per-session access point key, PIN, token; a firewall for the AP subnet). Until then do not ship a printed hotspot QR code (README "What a printed QR code may carry") and treat first-boot setup as something done on a network you trust.

## KI-03 Strix Halo unified-memory boot parameters exist only in the Ubuntu edition

**Severity:** Medium. **Owner:** owner to assign.

**What.** On a Strix Halo-class machine (Ryzen AI Max, gfx1151) the Ubuntu edition adds `iommu=pt amdgpu.gttsize=<N> ttm.pages_limit=<M>` to the kernel command line so the GPU can address most of system RAM (`backends/ubuntu/lib/strix-halo-boot-params.sh`, called from `backends/ubuntu/provision/provision.sh`). The Plasma edition has no equivalent. [V] `grep -rl gttsize backends core` finds only those two files.

**Impact.** The README says the parameters are "needed for local-LLM/ROCm/Vulkan workloads on these unified-memory APUs" (the GPU can then address most of system RAM instead of a small fixed carve-out). What happens on the Plasma edition without them was not measured [N].

**Decision needed.** Port the parameters to the CachyOS path (the GRUB defaults are written by Calamares and by the installed system's `grub-mkconfig`, so the place is the first-boot or the Calamares stage), or state that the Plasma edition does not support Strix Halo memory settings. `backends/arch/**` is frozen, so a port belongs in `backends/cachyos/`.

## KI-04 The Plasma edition has no Secure Boot and cannot boot from the Stick

**Severity:** High. **Owner:** owner to assign.

**What.** The ISO's GRUB is an unsigned standalone image (`--disable-shim-lock`), there is no shim, and the kernels are unsigned CachyOS kernels, so a machine with Secure Boot enforced must turn it off. The Companion Stick's boot menu is built for casper (`boot=casper live-media=... persistent`) and its persistence is an ext4 volume labelled `writable`, which an archiso image does not use, so `ci-stick` can write this ISO to a slot but its menu cannot start it.

**Evidence.** [V] `docs/architecture/cachyos-backend.md` section "Secure Boot and the Companion Stick" and risk R4. [V] Plasma ISO #4 and #5 were booted with the **non-Secure-Boot** firmware only; the Secure Boot variant was not tried, so a refusal is expected, not observed.

**Decision needed.** Whether this edition may ship without Secure Boot (see KI-14), or the design for a signed chain (own MOK and shim, an archiso boot profile in `stick/crates/ci-stick/src/bootcfg.rs`, a `boot_profile` field in the bundle schema). The release notes must state the limit either way.

## KI-05 Credentials exposed in the repository history are still unrotated

**Severity:** High (Critical if any of them is live). **Owner:** owner to assign.

**What.** The review of 2026-10-12 (finding H1) found secrets of these kinds readable in the history, on the tip of an old branch and in pull-request refs: a Cloudflare API token, a shared tunnel token, a Hub JWT secret, a CI-Hub API key, a registry login, and database, OS and search-service passwords. They were removed from the tree on 2026-09-16 and nothing in the repository shows they were rotated. As of 2026-10-18 they are still recorded as unrotated.

**No value is repeated here or anywhere in the documents.** The review file (`CI-OS-repo-review-2026-10-12.md`, untracked at the repository root of the review worktree) holds the locations; treat it as sensitive.

**Where the report lives, and who may read it.** It is a local, untracked file inside a git worktree under `.claude/worktrees/`, which `.gitignore` excludes (line 66), so it exists only on the review machine and is lost if that worktree is removed. It must not be committed, because it names where the secrets are. **The custodian and an access-controlled copy (a vault or a private drive) are not decided [N]**: the owner names them here, and says how a second maintainer requests the file. Until then: before any `git worktree remove` of the review worktree, copy the report (and `CI-Stick-flash-review-2026-10-12.md` beside it) out of the worktree to the owner's private storage, and keep the local snapshot tags out of every push (below).

**Evidence.** [V] review H1 and M7 (a deployed Hub keeps a leaked `JWT_SECRET` in its `.env`), M40 (no preventive control). [N] liveness of any value was never tested, on purpose.

**Decision and work needed.** Who rotates and confirms each item; read the Cloudflare audit log from the first date of exposure; delete `JWT_SECRET` from deployed Hubs; enable secret scanning and push protection or add a scan to `check-repo.sh`; only then delete the old branches and pull-request refs. Never run `git push --tags` from the review worktree: local snapshot tags there contain the secrets.

## KI-06 ROCm source on Ubuntu 26.04

**Severity:** Medium. **Owner:** owner to assign.

**What.** `backends/ubuntu/lib/install-rocm-driver.sh` installs `rocm`, `rocminfo` and `rocm-smi` from the **Ubuntu 26.04 archive** (ROCm 7.1: rocm 7.1.0, the other two 7.1.1) with the kernel's inbox amdgpu driver, and nothing from `repo.radeon.com`. The decision to take is whether to stay with the archive's 7.1 or to use AMD's own newer line.

**Evidence.**
- [V] The script header and `core/manifest/role-map/apt.yaml:76-79`; the package names were checked against the resolute archive on 2026-10-17 (`rocm-smi-lib` is not a package there).
- [V] On 2026-10-18, `https://repo.radeon.com/amdgpu-install/` lists numbered directories up to `7.2.4` and has no `10.0`; `.../amdgpu-install/latest/ubuntu/` has a `resolute/` suite holding `amdgpu-install_31.60.316000-1_all.deb`. [N] which ROCm release that installer would install was not examined, so the "AMD 10.0 line" named in the owner note is **not verified**.
- [I] The retired 24.04 plan (`docs/plans/strix-halo-rocm-companion-ubuntu.md`) recorded AMD's Strix Halo matrix as stable for ROCm 7.2.1 to 7.2.3; the archive's 7.1 is older than that. Whether 7.1 works on gfx1151 was **not tested** (no Strix Halo machine, KI-17).

**Decision needed.** Archive 7.1 (distribution-supported, no vendor repository, possibly too old for gfx1151) or the vendor line (newer, a third-party repository that the build and the first boot would trust). Test on a Strix Halo machine before choosing.

## KI-07 `ollama.service` is installed but disabled on the Plasma edition

**Severity:** Low. **Owner:** owner to assign.

**What.** Calamares installs Ollama and leaves the unit disabled; the first-boot provisioning enables it after configuring it (`backends/cachyos/installer/modules/services-systemd.conf:33`). Between the install and the end of the first boot, `ollama --version` prints two "no server" warnings. [V] Seen on ISO #4 (frame `installed/08`); clean after provisioning (`installed/08b`).

**The Ubuntu edition does the opposite:** it bakes Ollama and `ollama.service` is enabled for the installed system and never started in a live session ([V] `verify-iso.sh` section 3c on the first 26.04.1 image). Which choice is right for both editions is part of the decision below.

**Why it is not simply enabled on the Plasma edition.** The first-boot provisioning configures Ollama to listen on `0.0.0.0:11434` (CI-Hub's containers reach it through the docker bridge) and the shared payload has no credential, so once it runs it is reachable from the LAN and from the setup access point (risk R7b in [cachyos-backend.md](cachyos-backend.md), `backends/cachyos/installer/README.md`; audit item S6 in [headless-setup.md](headless-setup.md)).

**Decision needed.** Leave as is and document it (this page does), or enable it bound to loopback and fix the exposure first.

## KI-08 GRUB menu clutter, splash wording and one CachyOS label on the Plasma edition

**Severity:** Low. **Owner:** owner to assign.

**What.** [V] On ISO #4 the installed GRUB menu listed firmware leftovers that the installer's `grub-mkconfig` captured in the VM: "UEFI Firmware Settings", "UiApp (EFI BootNext)", the install DVD drive (gone after the install), the NVMe disk, "EFI Internal Shell" and a second "companion-os (EFI BootNext)" (frame `installed/01`). The two Companion entries and the theme were right. [V] The boot splash shows the company lockup "COMPANION INTELLIGENCE" (frame `installed/02`) while every other surface says "Companion OS".

**Also (ISO #5, stage 2):** one status line of the install window says "Installing needed drivers for CachyOS..." (frame `install/11b`, 35 percent, the upstream `chwd` job); every other install frame says Companion OS.

**Status in the working tree [I] (uncommitted when this page was written, not run on a built ISO).**
- The firmware entries: `backends/cachyos/installer/modules/grubcfg.conf` now sets `GRUB_DISABLE_BOOTNEXT: true` (the grub package's `/etc/grub.d/31_efi_bootnext` turns every entry of `efibootmgr -v` into a menu entry and has its own switch, independent of the os-prober one) and `GRUB_DISABLE_OS_PROBER: true`. `scripts/ci-os-post-install-fixups.sh` warns when `/etc/default/grub` lacks either key or `grub.cfg` still holds `efi-bootnext-` entries. The cost, on purpose: another system installed next to Companion OS gets no GRUB entry; it stays reachable from the firmware's boot menu and from "UEFI Firmware Settings", and `GRUB_DISABLE_OS_PROBER=false` plus `grub-mkconfig -o /boot/grub/grub.cfg` brings the scan back.
- The status line: `backends/cachyos/installer/patches.list` has a row that rewrites the label in `/usr/lib/calamares/modules/chwd/main.py`; a Python job's label is a gettext msgid and the new text has no translation, so it shows in English in every language.
- Tests: `iso/tests/installer-launcher.sh`, `installer-config.py` and `installer-stage.sh` (the facts file records the marker string of the real `chwd` module).

**Not changed.** The splash wording.

**Decision needed.** Whether the splash may carry the company lockup or must read "Companion OS", and whether a menu without other systems' entries is acceptable. The firmware entries will look different on real hardware [I].

## KI-09 Calamares theme polish is only partly fixed

**Severity:** Low. **Owner:** owner to assign.

**What.** ISO #4's installer frames showed six cosmetic defects: no highlight on the selected keyboard and bootloader rows, a generic zip-archive picture on the bootloader page, an inverted and very low-contrast progress bar, a dark pictogram on the "Companion OS Support" link, descriptions cut off on the packages page, and a taller window on the summary page. Commit `552063f` addresses the first five in the installer stylesheet (colours derived from the brand tokens and checked for contrast), the bootloader chooser picture and the descriptions.

**Status after the install stage of ISO #5 ([V], frames and notes in [test-evidence.md](test-evidence.md#plasma-edition-iso-5-all-three-stages)).** Fixed and seen: progress bar, keyboard rows, package row, bootloader row and picture, package descriptions, the Support link (no icon). Not fixed on that record: the popup of a combo box (the zone list) shows no highlight for the current entry or on hover; on the partition page the selected radio is a bare white dot without its ring and the row has no highlight; the summary page still grows the window; the confirmation dialog says "your disk" without naming the device; the language selector keeps the stock translate pictogram.

**In the working tree [I] (uncommitted when this page was written).** `branding/companion/stylesheet.qss` adds rules for the combo box popups (the menu-style popup, `combobox-popup: 1`, painted by the stylesheet) and for the radio buttons, with contrast numbers checked in `installer-config.py`. It was rendered offscreen with PySide6 and the Breeze style by its author; **it has not been seen in Calamares.** The other three items are untouched.

## KI-10 Ollama in Companion Stick live sessions

**Severity:** Medium. **Owner:** owner to assign.

**What.** `ollama.service` is disabled in Stick live sessions (the Ubuntu `10-not-live.conf` drop-in), so the cache on the stick serves installed machines only and is reachable in a live session through `ci-stick` and `llama-server -m`. This is decision D5 of the stick audit and is open ([models-tooling.md](models-tooling.md), sections 10 and 14).

**Decision needed.** Allow Ollama in a live session with the store on `CI-CACHE`, or keep it off and say so in the product text.

## KI-11 The Ubuntu 26.04.1 image is built and statically verified; no installer has run on it and the clean-checkout image has never been booted

**Severity:** High. **Owner:** owner to assign.

**What.** The Ubuntu backend was ported from 24.04 to 26.04.1 on 2026-10-17 and 18. Every piece was tested on the real stock ISO's data or on fixtures (counts in [test-evidence.md](test-evidence.md)). The first complete image from a clean checkout was then built: `build-iso.sh` exited 0 in 772 seconds and `verify-iso.sh` reported **393 passed, 0 failed** on it (2026-10-18, [V], [test-evidence.md](test-evidence.md#ubuntu-2604-image-build-and-static-verification), image `709b8485...`, records in [`../evidence/`](../evidence/README.md)). The installed-system static checks on it passed too (`installed-boot.sh --iso --no-boot`: 0 FAIL, 0 WARN, 25 PASS).

**What has and has not booted.** The clean-checkout image (`709b8485...`, commit `02c575e`) has **not** been booted by `installed-boot.sh`; only its `--no-boot` run was made. An **earlier image of the fix pass** (version 9.9, `dce9eb71...`, built from a worktree snapshot and not from a commit) did have a harness-assembled disk boot to the GDM greeter in 230 s [V] (`docs/evidence/2026-10-18-ubuntu-fixpass-9.9/`), and its themed GRUB menu drew under Secure Boot. That is not an install: the live session, the interactive installer, the one-click installer, the installed system of the clean-checkout image and the Secure Boot boot to a live system are all **pending**. The one-click installer has never run end to end on any release: its snap unit name, client pattern and API states were confirmed by reading the 26.04.1 installer, not by running it.

**Decision and work needed.** Run the pending rows listed in [test-evidence.md](test-evidence.md#pending-evidence-for-the-ubuntu-2604-image). Until they pass, the Ubuntu installation text in the guides is marked as implemented, not proven.

## KI-12 Public hosting, the release signing key holder and the release workflow

**Severity:** High. **Owner:** owner to assign.

**What.** Nothing has been published. The old guides pointed at GitHub releases that do not exist. Three open items:
1. **Where ISOs are hosted.** GitHub Releases allow 2 GiB per asset and the images are multi-gigabyte. [V] `.github/workflows/build-companion-os-iso.yml` still has a "Create GitHub Release" step that runs on every manual dispatch with `draft: false` and uploads the ISO; it is expected to fail on size and, on a size it could carry, would publish immediately.
2. **Who holds the release key.** `build-iso.sh --sign` signs with the invoking user's default key and the workflow signs with repository secrets; no key holder, no published public key and no verification procedure for users exist.
3. **Roles.** Build owner, verifier, signer and publisher are not named (see the [release checklist](../guides/release-checklist.md)).

**Decision needed.** A hosting location and retention, a key holder and a key-rotation rule, and the four roles. Then fix the workflow (draft release, no ISO upload, or a different publisher).

## KI-13 Whether the CachyOS name may be used in public text

**Severity:** High. **Owner:** owner to assign.

**What.** Decision D1 keeps the CachyOS name out of every artifact name and title (`iso_name=companion-os-plasma`, file `companion-os-plasma-<YYYY.MM.DD>-x86_64.iso`) and allows "based on CachyOS" only as a fact in documents, in `NOTICE` and in the `VARIANT` field. The About page and `os-release` do say "Plasma (based on CachyOS)" and keep `ID=cachyos` (decision D4: CI-Hub's installers match `ID_LIKE=arch`), and the installed system still carries `cachyos-*` packages. Counsel and a written answer from the CachyOS project are still needed (risk R3, `backends/cachyos/NOTICE` sections 2 and 6).

**Decision needed.** Yes or no for public release notes, the website and the About page, and for the kernel name that stays visible in `uname`.

## KI-14 Whether the first batch needs Secure Boot

**Severity:** Medium. **Owner:** owner to assign.

**What.** The Ubuntu edition keeps Canonical's signed chain (verified statically and, for the Stick with the stock ISO, by a Secure Boot boot to the live system's systemd; a boot of a built image is pending). The Plasma edition cannot offer it (KI-04). If the first batch of machines or customers requires Secure Boot, only the Ubuntu edition qualifies.

**Decision needed.** The requirement, and therefore which edition leads the first batch.

## KI-15 Headroom of the Ubuntu image in an 8 GiB Stick boot slot is 1.5 GB

**Severity:** Low. **Owner:** owner to assign.

**What.** `ci-stick flash` refuses an image that does not fit its slot, and a 64 GB stick has 8 GiB (8,589,934,592 bytes). The first complete Ubuntu 26.04.1 image measures **7,076,577,280 bytes** with every optional tool baked in, so 1,513,357,312 bytes are spare (`verify-iso.sh` section 9, [V] 2026-10-18); the estimate made before the build was about 7.3 GB. Anything added later (a second model, more tools) eats that margin, and `verify-iso.sh` fails an image above 8 GiB.

**Decision needed (only if the margin is used up).** A smaller image (`CI_OS_OLLAMA_CUDA=none` saves about 1.5 GB), larger sticks, or a layout policy change (`ci-stick-layout/1`). The slot size is the smallest Stick's, so a 128 GB stick (11 GiB slots) has room.

## KI-16 Build and test tooling defects found while writing the guides

**Severity:** Low. **Owner:** owner to assign.

| Item | Evidence | Note |
|---|---|---|
| `installed-boot.sh` starts its builder container with `--platform linux/amd64` and defaults to `ubuntu:26.04`; an amd64 26.04 container failed with a tar ENOSYS in `stick/tests/secureboot/build-in-container.sh` on 2026-10-17 | `backends/ubuntu/iso/tests/installed-boot.sh:216` | [V] the same builder container unpacked packages without error under Rosetta on 2026-10-18; the trigger of the tar failure was not isolated. If it fails, pass `--image` with a prebuilt tools image |
| The one-click helper's error dialogs say "Use the normal installer from the desktop icon" (`backends/ubuntu/chroot/payload/live-start/usr/libexec/ci-os/ci-os-auto-install:825` and the failure text near line 715), but Ubuntu 26.04's live session draws no desktop icons (the stock installer is in the dock) | the helper; `docs/architecture/one-click-install.md` | [V] text read; fix the wording to "from the dock" |
| The standalone `ci-os-branding` `.deb` cannot be removed cleanly: the `postinst` diverts the Yaru file after the package has already replaced it (dpkg "Ignoring request to rename file ... owned by diverting package"), so no `.distrib` copy is made; removing the package before a Yaru update leaves no `gnome-shell-theme.gresource`, and removing it after one fails in `prerm` ("rename involves overwriting ... not allowed", exit 2) | `backends/ubuntu/packages/ci-os-branding/DEBIAN/{postinst,prerm}` | [V] ran in an `ubuntu:26.04` container on 2026-10-18 (see [gdm-branding-package.md](../guides/gdm-branding-package.md#rollback)); the ISO build does not use the package. The usual fix is to divert in `preinst` |
| `backends/ubuntu/chroot/tests/first-boot-units-boot.sh` boots containers with systemd as PID 1 (`docker create --privileged ... /sbin/init`), which on Docker Desktop for Apple silicon wipes the Docker VM's Rosetta registrations | the script, line 140; [building-on-a-mac.md](../guides/building-on-a-mac.md#never-run-systemd-as-pid-1-in-a-privileged-container) | [V] the script's invocation was read; [I] that it caused the 2026-10-18 wipe (timing only). Run it on a Linux Docker host or a VM; a guard that refuses on Docker Desktop for Mac is a follow-up in the script ([running-the-tests.md](../guides/running-the-tests.md#tests-that-start-systemd-as-pid-1)) |
| The ISO workflow still installs `debootstrap`, which nothing uses | `.github/workflows/build-companion-os-iso.yml:131` | harmless, remove the line |
| `docs/CI.md` is generated and lists only two workflows ("No local checks detected") | `docs/CI.md` | regenerate with `ci-local docs`; it is marked do-not-hand-edit, so the guides do not point readers at it for the workflow list |
| README links `docs/Create-headless-setup.md` as the "Headless Setup Guide" | `README.md` | the file is an LLM task prompt and now says so at the top; relabel the link |
| The four workflows are gated to manual dispatch | each file's `ci-local:gated` block | no remote check runs `check-repo.sh`; run it locally before every push |
| Hardware-fit gate and disk guard | KI-01 | listed here for completeness |

## KI-17 No physical machine has booted either edition

**Severity:** Medium. **Owner:** owner to assign.

**What.** Every boot and install in the evidence is under QEMU TCG on an Apple-silicon Mac. [N] Real hardware (GPU drivers, Wi-Fi, suspend, Secure Boot on a real firmware, the Strix Halo paths) is untested for both editions.

**Work needed.** At least one physical UEFI machine per edition before a release, one Strix Halo-class machine if ROCm or the memory settings are claimed (release checklist gate 10).

## KI-18 The Plasma edition drifts with the rolling release

**Severity:** Medium. **Owner:** owner to assign.

**What.** Packages are current at build time and again at install time (risk R1). The boost soname skew found on 2026-10-18 (installer built against boost 1.91, repositories at 1.92) dated from 2026-08-13, when `boost-libs` 1.92.0-1 reached `[extra]` eleven hours after the installer was built (`backends/cachyos/compat-libs.lock`): it predates every Companion OS ISO, and was first exposed when the installer was first launched on a booted ISO (ISO #3, 2026-10-18). It was fixed by three pinned compatibility libraries (`backends/cachyos/compat-libs.lock`, review by 2026-12-01) and a build gate that fails the build on the next skew. A canary rebuild and an Arch Linux Archive date for `core` and `extra` are not in place, and only the installer package is gated; other `[cachyos]` packages built against older libraries would fail at first use.

**Decision needed.** A scheduled canary rebuild, a maximum age for a published ISO (see the release checklist), and whether to snapshot the Arch repositories.

## KI-19 The apt repository `packages.ci.computer` does not exist

**Severity:** Low. **Owner:** owner to assign.

**What.** [V] On 2026-10-18 the name did not resolve from the build machine (`nslookup`: "No answer"; `curl`: "Could not resolve host"), while `ci.computer` answered HTTP 200. The only consumers are a disabled template in the Ubuntu image (`/etc/apt/sources.list.d/companion-intelligence.list.disabled`, written by `backends/ubuntu/chroot/customize-chroot.sh`, suite `resolute`) and the helper `backends/ubuntu/iso/scripts/setup-repository.sh`. The guide [package-repository-setup.md](../guides/package-repository-setup.md) is now a status note.

**Decision needed.** Whether a repository is wanted at all (what it would host, who runs it, who signs it), or the template and helper are removed.

## KI-20 The Calamares keyring step has a 30 second limit

**Severity:** High. **Owner:** owner to assign.

**What.** In the installer's `shellprocess_initialize_pacman.conf` only the first command (`update-mirrorlist`) has `timeout: 3600`; the second, `bash /etc/calamares/scripts/create-pacman-keyring`, has no `timeout` key, so Calamares applies its 30 second default. The script runs `pacman-key --init`, two `pacman -Sy` of the keyring packages and `pacman-key --populate` (a gpg import of the Arch and CachyOS keys). Under QEMU TCG that takes about 28 seconds, and on a slow disk, an old board or a loaded virtual machine it can exceed 30.

**Evidence.** [V] ISO #5, stage 2: attempts 1 and 2 ended at 2 percent with the dialog "Installation Failed: command `bash /etc/calamares/scripts/create-pacman-keyring` failed to finish in 30 seconds" (frame `install/09b`; log line `Process "/bin/sh" timed out after 30000 ms`, then `Installation failed: External command failed to finish`). Attempt 3 passed the step about 2 seconds inside the limit, with the product's own scripts and nothing hand-initialised, and the install then completed (23 min 20 s). ISO #4 passed the same step at a lower host load. A failed attempt leaves the disk partitioned, so the next attempt lists extra partition choices. A real machine does this in a few seconds [I].

**Fix in the working tree [I] (uncommitted when this page was written, not run on a built ISO).** `backends/cachyos/installer/modules/` has overlay copies of three stock configs, `shellprocess_initialize_pacman.conf` (3600 s on the two commands that talk to mirrors, 600 s for the rest of the file), `shellprocess_modify_mk_hook.conf` and `shellprocess_reset_mk_hook.conf` (600 s), which differ from the installer's only in explicit `timeout` keys. A new `shell-timeouts` guard (`installer/lib/ci-shellprocess.py`, a row in `installer/guards.list`) fails the launcher when any `shellprocess` command of the effective install sequence has no explicit limit, when a command that runs a network or package tool has less than 600 s (disk tools: 300 s), and when a frozen copy no longer runs every command of the installer's file. Tests: `iso/tests/installer-launcher.sh`, against a fake installer tree that holds the installer's real commands (the `spconf` lines of the facts file), including the keyring command that has no limit. The user-visible workaround until a rebuilt ISO is in hand: close the dialog and start the installer again from the launcher, which can take several tries on a slow machine.

## KI-21 The restore tag of the retired backends is local, and its only fallback is one bundle on one machine

**Severity:** Medium. **Owner:** owner to assign.

**What.** The four retired backends and the Ubuntu 24.04 baseline are kept by the tag `pre-retire-multidistro-2026-10-17` (commit `855cd0a`). **[V]** `git branch -a --contains 855cd0a` lists only `liam/companion-os-single-click-install`; the tag is not on any remote, and `origin/main` does not contain it. The fallback is a verified bundle, `CI-OS-pre-retire-multidistro-20261017.bundle` (25 MB, sha256 `f7483f034fcdf268b53ff0cd735b3f79e8066d8afbff8849f0f925938c96ae7b`, `git bundle verify`: complete history), in the maintainer's `_archive` directory on one laptop. If that branch is deleted or that disk fails, the restore recipe of [supported-targets.md](supported-targets.md#7-retired-targets-and-the-restore-recipe) stops working.

**Decision and work needed.** Push the tag by name (`git push origin refs/tags/pre-retire-multidistro-2026-10-17`), **never** `git push --tags`: the local snapshot tags `phase0-snapshot/*` and `phase1-snapshot/*` contain the secrets of KI-05. Name a shared, retained location for the bundle and state it in [supported-targets.md](supported-targets.md#7-retired-targets-and-the-restore-recipe).

## KI-22 Nobody can say what the shared tunnel certificate `CI-Local-Root-CA` is for

**Severity:** Medium. **Owner:** owner to assign.

**What.** `core/lib/generate-tunnel-certs.sh` writes the same self-signed certificate (`CN=CI-Local-Root-CA`, `OU=LocalDev`, valid 2026-01-13 to 2036-01-11) into `tunnel/certs/custom-ca.pem` of every deployment that sets a tunnel token. [V] Nothing else in the tree reads that file. **[N]** Where its private key is held, what it signs and whether any machine is meant to trust it are stated nowhere in the repository. Details and the fingerprint: [ci-hub-deploy.md](../guides/ci-hub-deploy.md#the-tunnel-certificate).

**Decision needed.** The owner records what the CA is, who holds the key and whether the certificate may stay in a script that ships on every appliance, or is replaced by a per-device certificate or removed.

## KI-23 There is no release key, key custody or pipeline for `ci-stick` bundles

**Severity:** High. **Owner:** owner to assign.

**What.** A Companion Stick bundle is an ed25519-signed manifest ([companion-stick.md](companion-stick.md), "Pinned keys"). The architecture says "Release signing happens in the release pipeline", release public keys "will be compiled into `ci-stick`" and rotated by signed statements. **[V]** None of that exists: the only bundle signing in any workflow is the throw-away development key that `stick-real-iso.yml` generates for its own test, `stick/README.md` documents only the development key (`ci-stick dev keygen`, `ci-stick dev sign`), `verify` always needs `--pubkey`, and the release checklist and KI-12 cover the ISO's GPG signature only. So a physical stick cannot be released with a signature a user can check without a key the maintainers have not chosen.

**Decision needed.** Who holds the bundle signing key and where; the rotation rule and the signed rotation statement; where the public key is published and how it gets compiled into `ci-stick`; the pipeline or the manual procedure that signs and verifies a bundle before flashing. The gate is in the [release checklist](../guides/release-checklist.md#stick-bundle-release).

## KI-24 Model redistribution licences for physical sticks are not reviewed, and `fetch` does not gate Gemma or Llama

**Severity:** High. **Owner:** owner to assign.

**What.** The `stick-128` pack carries three Gemma Terms-of-Use models (one is forced by `ecosystem.yaml`) and `llama3.2:3b` (Llama 3.2 Community License) ([companion-stick-128gb.md](companion-stick-128gb.md), open decision 3: "Not legally reviewed"; [models-tooling.md](models-tooling.md), open item 4: "Legal review of those terms is also open"). **[V]** `ci-stick models fetch` asks for acceptance only when a licence string is `unverified` (`license_needs_acceptance`, `fetch/plan.rs`); the table `core/manifest/licenses.yaml` and its release gate (`release_blockers`, `acceptance_required`) are done and tested but **not wired into `fetch`**. So a stick can be filled with those models without anyone being asked.

**Decision needed.** Counsel's answer for redistribution on physical media; then wire the licence table into `fetch` (item 4 of the open items) before any stick is sold or given away.

## KI-25 The `docker` group is root-equivalent for every `sudo` member

**Severity:** Medium. **Owner:** owner to assign.

**What.** On the installed system, membership of `docker` gives root. The first user is a `sudo` member and is added to `docker`, as requested; casper already gives the live user passwordless `sudo`, so in a live session the group changes nothing, but on an installed system it is a step up from password-protected `sudo` ([docker-in-live-sessions.md](docker-in-live-sessions.md), open question Q-SEC; [companion-stick-128gb.md](companion-stick-128gb.md), open decision 7).

**Decision needed.** Keep it (as requested), or require `sudo docker`.

## Also open, kept in their source pages

Items that need a decision but have no register entry of their own. Each links to the page that holds the reasoning.

| Item | Where |
|---|---|
| The Launcher and `ci-hub.sh` both publish host port 5002, and the Launcher's bundled stack wants port 80 that the setup portal's nginx also wants; should the Launcher replace, run beside, or never run with the `ci-hub.sh` deploy? | [companion-stick-128gb.md](companion-stick-128gb.md) open decision 6; [tier-b-tools.md](tier-b-tools.md) risk R3; [ci-hub-deploy.md](../guides/ci-hub-deploy.md) |
| Ollama update policy: the baked 0.40.3 is never upgraded by `provision.sh` | [companion-stick-128gb.md](companion-stick-128gb.md) open decision 5; [tier-b-tools.md](tier-b-tools.md) risk R1 |
| A scheduled job that re-checks vendor keys and release pins (GitHub's key already rotated once) | [companion-stick-128gb.md](companion-stick-128gb.md) open decision 8; [tier-b-tools.md](tier-b-tools.md) risk R2 |
| Hot-plug of `CI-CACHE`, and the size of `CI-PERSIST` | [companion-stick-128gb.md](companion-stick-128gb.md) open decisions 9 and 10 |
| Which of `stick-128` and `stick-128-oci` the first batch uses, and the second large model | [companion-stick-128gb.md](companion-stick-128gb.md) open decisions 1 and 2 |
| The inclusion rule of this page: an item is listed when it blocks a release, needs a decision, or was found by running an edition; a decision that lives only in another page's open list is mirrored in this table | this page |

© Companion Intelligence, Lifescope Inc
