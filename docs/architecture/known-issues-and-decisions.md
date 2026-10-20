# Known issues and open decisions

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

State of 2026-10-18 (afternoon, after the Plasma ISO #6 run), after the October 2026 work on both supported editions. Supported targets: Companion OS on Ubuntu 26.04.1 LTS (resolute) and Companion OS on CachyOS (the "Plasma" edition). Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from the tag `pre-retire-multidistro-2026-10-17`).

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
| KI-08 | Splash wording and CachyOS names in raw pacman output on the Plasma edition (the GRUB firmware entries and the driver-job label are fixed and seen on ISO #6) | defect | Low | owner to assign |
| KI-09 | Calamares theme polish is only partly fixed (the zone popup and the radio buttons are fixed and seen on ISO #6; three highlight gaps and some copy remain) | gap | Low | owner to assign |
| KI-10 | Ollama in Companion Stick live sessions | decision | Medium | owner to assign |
| KI-11 | The Ubuntu 26.04.1 image is built and statically verified; the stock installer has now installed it and the installed disk booted and logged in, in a virtual machine only (2026-10-18/19: see KI-27); the one-click path and real hardware are still unproven | gap | High | owner to assign |
| KI-12 | Public ISO hosting (R2 chosen 2026-10-20, owner steps open), the release signing key holder and the release workflow (rewritten, never run) | decision, defect | High | owner to assign |
| KI-13 | Whether the CachyOS name may be used in public text | decision | High | owner to assign |
| KI-14 | Whether the first batch needs Secure Boot | decision | Medium | owner to assign |
| KI-15 | Headroom of the Ubuntu image in an 8 GiB Stick boot slot is 1.5 GB | risk | Low | owner to assign |
| KI-16 | Build and test tooling defects found while writing the guides | defect | Low | owner to assign |
| KI-17 | No physical machine has booted either edition | gap | Medium | owner to assign |
| KI-18 | The Plasma edition drifts with the rolling release | risk | Medium | owner to assign |
| KI-19 | The apt repository `packages.ci.computer` does not exist | status | Low | owner to assign |
| KI-20 | The Calamares keyring step had a 30 second limit; two of three installs on ISO #5 failed at 2 percent under emulation. **Fixed in `ad37b64`, seen working once on ISO #6** | defect, fixed | High when found | owner to assign |
| KI-21 | The restore tag of the retired backends is local and its only fallback is one bundle on one machine | risk, decision | Medium | owner to assign |
| KI-22 | Nobody can say what the shared tunnel certificate `CI-Local-Root-CA` is for or who holds its key | gap, decision | Medium | owner to assign |
| KI-23 | There is no release key, key custody or pipeline for `ci-stick` bundles | gap, decision | High | owner to assign |
| KI-24 | Model redistribution licences for physical sticks are not reviewed, and `fetch` does not gate Gemma or Llama | gap, decision | High | owner to assign |
| KI-25 | The `docker` group is root-equivalent for every `sudo` member of the installed system | decision | Medium | owner to assign |
| KI-26 | Plasma edition leftovers found by the ISO #6 run: log noise, a greeter without the Companion mark, installer copy that does not match the installed system | defect, cosmetic | Low | owner to assign |
| KI-27 | First install of the clean-checkout Ubuntu image (2026-10-18): the first graphical login failed twice while the first boot was still working, boot stayed "not finished" for 30+ minutes, the desktop-icons process was relaunched every 4 s, and the first-run screens and login text still carry Ubuntu branding | defect, gap | High (login) to Low (branding) | owner to assign |
| KI-28 | The arm64 build of the Ubuntu edition (a supported architecture since 2026-10-19): built, verified (436/0), installed in 12 min and booted natively on an Apple-silicon Mac; the system reads `degraded` on non-Snapdragon hardware, Capture is absent, Secure Boot, real hardware, Stick support and a CI job are missing | gap, decision | Medium | owner to assign |
| KI-29 | Language, keyboard and time zone in the one-click install, and first-boot progress on the desktop (2026-10-19): [V] on a fresh arm64 install in a virtual machine; no action button, English-only text, no keyboard variants, amd64 and real hardware untried | gap | Low | owner to assign |
| KI-30 | Streamlined setup (2026-10-19): no Ubuntu Pro prompts, no Canonical telemetry, Canonical's installer window not opened by itself in the live session, dark with a green accent by default; seen on arm64 images in a virtual machine, which found and fixed a live session without dock and icons (green or teal, Canonical's launcher on the live desktop) | decision | Low | owner to assign |

## KI-01 Model pulls have no disk-space guard

**Severity:** High. **Owner:** owner to assign.

**What.** The first-boot provisioning pulls Ollama models whose sizes add up to about 18.8 GB (nomic-embed-text 0.27 GB, gemma3:1b 0.81 GB, qwen3.6:27b 17.8 GB; `core/manifest/model-packs.yaml`, `backends/cachyos/installer/README.md`). Nothing checks free disk space first.

**Evidence.**
- [V] On the Plasma edition's ISO #4 run the 30 GiB target went from 7.8 GiB used (27 percent) to 26 GiB used (88 percent, 3.7 GiB free) after the three pulls (`df -h` in the capture, frames `installed/11` and `installed/14`). A smaller disk fails a pull for lack of space. [V] On a 64 GiB target (ISO #5) the same pulls took root from 8.4 GiB to 27 GiB used (42 percent, 37 GB free).
- [V] On the ISO #6 run (64 GiB target, 6144 MiB, no GPU) the pristine post-install disk had 8.34 GiB allocated; after the first-boot pulls the root file system showed 26 GB used of 64 GB (42 percent, 37 GB free), and `qwen3.6:27b` (17 GB) was pulled again (`docs/ui/companion-os/plasma/`, frame 29 and `CAPTURE.md`).
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

**What.** On a Strix Halo-class machine (Ryzen AI Max, gfx1151) the Ubuntu edition adds `iommu=pt amdgpu.gttsize=<N> ttm.pages_limit=<M>` to the kernel command line so the GPU can address most of system RAM (`backends/ubuntu/lib/strix-halo-boot-params.sh`, called from `backends/ubuntu/provision/provision.sh`). On a machine that also has AMD's out-of-tree DKMS amdgpu driver it adds `amdttm.pages_limit=<M>` as well: that driver uses its own copy of the TTM memory manager, the module `amdttm`, and `ttm.pages_limit` does not reach it. The Plasma edition has no equivalent. [V] `grep -rl gttsize backends core` finds the script, `provision.sh` and the script's test (`backends/ubuntu/lib/tests/strix-halo-boot-params.sh`), and nothing else.

**Evidence (the DKMS driver).** [R] core-7 (125,780 MiB, `amdgpu-dkms` 6.19.4), 2026-10-19, read-only over ssh by the fleet QA session: the command line carried `amdgpu.gttsize=110058 ttm.pages_limit=28174848`, `/sys/module/ttm/parameters/pages_limit` read 28174848 and `/sys/module/amdttm/parameters/pages_limit` read 16099952 (half of RAM), so 107 GiB of GTT but only 61 GiB the GPU could pin. Nodes on the inbox driver (core-6, liam-demo, core-17, fzzy) load only `amdgpu` and `ttm` and are served by `ttm.pages_limit`. [V] Read the same day, also read-only: core-7 has `amdttm.ko.zst` under `/lib/modules/<kernel>/updates/dkms/` for three of its nine installed kernels (the running one among them) and `dpkg-query -W -f '${db:Status-Status}' amdgpu-dkms` prints `installed`; fzzy prints `config-files` for the same package (removed, configuration kept) and has no `amdttm` module anywhere, so the script reads the status word and not whether dpkg knows the package. [V] The script's rewrite, with and without the DKMS driver, is rehearsed on throwaway GRUB files by `backends/ubuntu/lib/tests/strix-halo-boot-params.sh` (run by `core/lib/check-repo.sh`; checked in Ubuntu 26.04 and Debian 12 containers, under bash and dash). [N] `amdttm.pages_limit` taking effect from the command line is not yet observed: core-7 was fixed by hand (the runtime value, and the same GRUB line the script writes) and had not rebooted when this was written.

**Impact.** The README says the parameters are "needed for local-LLM/ROCm/Vulkan workloads on these unified-memory APUs" (the GPU can then address most of system RAM instead of a small fixed carve-out). What happens on the Plasma edition without them was not measured [N].

**Decision needed.** Port the parameters to the CachyOS path (the GRUB defaults are written by Calamares and by the installed system's `grub-mkconfig`, so the place is the first-boot or the Calamares stage), or state that the Plasma edition does not support Strix Halo memory settings. `backends/arch/**` is frozen, so a port belongs in `backends/cachyos/`.

## KI-04 The Plasma edition has no Secure Boot and cannot boot from the Stick

**Severity:** High. **Owner:** owner to assign.

**What.** The ISO's GRUB is an unsigned standalone image (`--disable-shim-lock`), there is no shim, and the kernels are unsigned CachyOS kernels, so a machine with Secure Boot enforced must turn it off. The Companion Stick's boot menu is built for casper (`boot=casper live-media=... persistent`) and its persistence is an ext4 volume labelled `writable`, which an archiso image does not use, so `ci-stick` can write this ISO to a slot but its menu cannot start it.

**Evidence.** [V] `docs/architecture/cachyos-backend.md` section "Secure Boot and the Companion Stick" and risk R4. [V] Plasma ISO #4, #5 and #6 were booted with the **non-Secure-Boot** firmware only; the Secure Boot variant was not tried, so a refusal is expected, not observed.

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

## KI-08 Splash wording and CachyOS names in raw pacman output on the Plasma edition

**Severity:** Low. **Owner:** owner to assign.

**What.** Three things were found by the runs, and the first two are fixed:

1. [V] On ISO #4 the installed GRUB menu listed firmware leftovers that the installer's `grub-mkconfig` captured in the VM: "UEFI Firmware Settings", "UiApp (EFI BootNext)", the install DVD drive (gone after the install), the NVMe disk, "EFI Internal Shell" and a second "companion-os (EFI BootNext)". **Fixed in `ad37b64`, seen on ISO #6 [V]** (frame 19 of [`docs/ui/companion-os/plasma/`](../ui/companion-os/plasma/CAPTURE.md)): the installed menu lists exactly Companion OS Linux, Advanced options for Companion OS Linux, UEFI Firmware Settings and Companion OS snapshots, although the virtual machine's firmware still held a UiApp, an EFI shell and an NVMe boot entry. `backends/cachyos/installer/modules/grubcfg.conf` sets `GRUB_DISABLE_BOOTNEXT: true` (the grub package's `/etc/grub.d/31_efi_bootnext` turns every entry of `efibootmgr -v` into a menu entry and has its own switch, independent of the os-prober one) and `GRUB_DISABLE_OS_PROBER: true`, and the installed `/etc/default/grub` has both. `scripts/ci-os-post-install-fixups.sh` warns when either key is missing or `grub.cfg` still holds `efi-bootnext-` entries. The cost, on purpose: another system installed next to Companion OS gets no GRUB entry; it stays reachable from the firmware's boot menu and from "UEFI Firmware Settings", and `GRUB_DISABLE_OS_PROBER=false` plus `grub-mkconfig -o /boot/grub/grub.cfg` brings the scan back. The firmware entries will look different on real hardware [I].
2. [V] On ISO #5 one status line of the install window said "Installing needed drivers for CachyOS..." (35 percent, the upstream `chwd` job). **Fixed in `ad37b64`, seen on ISO #6 [V]**: the line reads "Installing needed drivers for Companion OS..." at 35 percent (a frame of the capture that is not in the exported set). `backends/cachyos/installer/patches.list` has a row that rewrites the label in `/usr/lib/calamares/modules/chwd/main.py`; a Python job's label is a gettext msgid and the new text has no translation, so it shows in English in every language.
3. **Still open.** [V] The boot splash shows the company lockup "COMPANION INTELLIGENCE" (ISO #4 frame `installed/02`; again on ISO #6, frame 20) while every other surface says "Companion OS". And, new on the ISO #6 record [V]: during the `pacstrap` and `packages` jobs the install page's status line passes pacman's own output through for seconds at a time, and some of it names CachyOS packages ("Updating CachyOS specific configuration.", "Optional dependencies for linux-cachyos-lts", "pacman: installing cachyos-alacritty-config..."). These are the packages' lines, not job labels, and no other install frame names CachyOS (the three frames are in the capture, not in the exported set). Low.

**Tests of the fixes.** `iso/tests/installer-launcher.sh`, `installer-config.py` and `installer-stage.sh` (the facts file records the marker string of the real `chwd` module); `verify-iso.sh` checks the GRUB switches and the label row (215 passed on ISO #6).

**Decision needed.** Whether the splash may carry the company lockup or must read "Companion OS"; whether the status line may show raw package-manager text or should show a fixed label per job; and whether a menu without other systems' entries is acceptable.

## KI-09 Calamares theme polish is only partly fixed

**Severity:** Low. **Owner:** owner to assign.

**What.** ISO #4's installer frames showed six cosmetic defects: no highlight on the selected keyboard and bootloader rows, a generic zip-archive picture on the bootloader page, an inverted and very low-contrast progress bar, a dark pictogram on the "Companion OS Support" link, descriptions cut off on the packages page, and a taller window on the summary page. Commit `552063f` addressed the first five in the installer stylesheet (colours derived from the brand tokens and checked for contrast), the bootloader chooser picture and the descriptions; commit `ad37b64` added rules for the menu-style combo box popups (check marks, highlights) and the radio buttons.

**Status after ISO #6 ([V], frames and notes in [`docs/ui/companion-os/plasma/CAPTURE.md`](../ui/companion-os/plasma/CAPTURE.md) and [test-evidence.md](test-evidence.md#plasma-edition-iso-6-the-whole-path-on-the-first-attempt)).**
- Fixed and seen: progress bar, keyboard rows, package row, bootloader row and picture, package descriptions, the Support link (no icon), the zone popup (current entry with a check mark, hovered entry highlighted) and the radio buttons on the partition page (a ring, and a ring plus a dot when selected; frame 11).
- **Not fixed (Low):** (1) the right-hand column of the language popup is white on the pale highlight and nearly unreadable on the highlighted row; (2) the filesystem drop-down on the Partitions page has no highlight at all, neither for the current entry nor on hover; (3) the selected partition option has the ring-and-dot radio but no row highlight. Items 1 and 2 are from capture frames that are not in the exported set; item 3 is visible in frame 11.
- **Not touched, unchanged from ISO #4 and #5 (Low):** the summary page still grows the window and does not list the package choice; the confirmation dialog says "your disk" without naming the device, which the summary behind it does (frames 14, 15); the language selector keeps the stock translate pictogram; the Bootloader page's text says GRUB "finds other operating systems on the disk", which the installed system does not do (KI-08, KI-26).

## KI-10 Ollama in Companion Stick live sessions

**Severity:** Medium. **Owner:** owner to assign.

**What.** `ollama.service` is disabled in Stick live sessions (the Ubuntu `10-not-live.conf` drop-in), so the cache on the stick serves installed machines only and is reachable in a live session through `ci-stick` and `llama-server -m`. This is decision D5 of the stick audit and is open ([models-tooling.md](models-tooling.md), sections 10 and 14).

**Decision needed.** Allow Ollama in a live session with the store on `CI-CACHE`, or keep it off and say so in the product text.

## KI-11 The Ubuntu 26.04.1 image is built and statically verified; the stock installer has installed it in a virtual machine (updated 2026-10-19), nothing else is proven

> **Update 2026-10-19.** The clean-checkout image (`709b8485...`, commit `02c575e`) was installed with the stock interactive installer in QEMU/OVMF under Secure Boot firmware (the installer reached `DONE` after about 5 h 54 min under emulation, 4 h 15 min of it in the installer's own update step), the installed disk booted through shim to the branded GDM greeter, and a graphical login reached the desktop once the model download had finished and the machine was quiet. What that run found is KI-27. The one-click path was re-run on a newer image (`39d3ae49...`, commit `457b4e6`): the confirmation is now accepted by the real installer (the HTTP 500 is gone); that install had not finished when this was written. Nothing has run on real hardware (KI-17). The text below is the state of 2026-10-18 and is kept for the record.

**Severity:** High. **Owner:** owner to assign.

**What.** The Ubuntu backend was ported from 24.04 to 26.04.1 on 2026-10-17 and 18. Every piece was tested on the real stock ISO's data or on fixtures (counts in [test-evidence.md](test-evidence.md)). The first complete image from a clean checkout was then built: `build-iso.sh` exited 0 in 772 seconds and `verify-iso.sh` reported **393 passed, 0 failed** on it (2026-10-18, [V], [test-evidence.md](test-evidence.md#ubuntu-2604-image-build-and-static-verification), image `709b8485...`, records in [`../evidence/`](../evidence/README.md)). The installed-system static checks on it passed too (`installed-boot.sh --iso --no-boot`: 0 FAIL, 0 WARN, 25 PASS).

**What has and has not booted.** The clean-checkout image (`709b8485...`, commit `02c575e`) has **not** been booted by `installed-boot.sh`; only its `--no-boot` run was made. An **earlier image of the fix pass** (version 9.9, `dce9eb71...`, built from a worktree snapshot and not from a commit) did have a harness-assembled disk boot to the GDM greeter in 230 s [V] (`docs/evidence/2026-10-18-ubuntu-fixpass-9.9/`), and its themed GRUB menu drew under Secure Boot. That is not an install: the live session, the interactive installer, the one-click installer, the installed system of the clean-checkout image and the Secure Boot boot to a live system are all **pending**. The one-click installer has never run end to end on any release: its snap unit name, client pattern and API states were confirmed by reading the 26.04.1 installer, not by running it.

**Decision and work needed.** Run the pending rows listed in [test-evidence.md](test-evidence.md#pending-evidence-for-the-ubuntu-2604-image). Until they pass, the Ubuntu installation text in the guides is marked as implemented, not proven.

## KI-12 Public hosting, the release signing key holder and the release workflow

**Severity:** High. **Owner:** owner to assign.

**What.** Nothing has been published. The old guides pointed at GitHub releases that do not exist. Three items; the first was decided on 2026-10-20 and implemented, and none of it has run against the real buckets:
1. **Where ISOs are hosted: decided, R2.** GitHub Releases allow 2 GiB per asset and the images are 5.6 GB, so the images go to Cloudflare R2, the shared buckets `dl-dev` (`https://dl-dev.ci.computer`) and `dl-prod` (`https://dl.ci.computer`) under the prefix `os/`, the pair Companion Capture's release already uses under `applet/`. **[I]** `publish-r2.sh` (dry run until `--apply`; multipart through the AWS CLI because `wrangler r2 object put` stops at 315 MB; `latest.json` written last), `verify-published.sh` (gate 14 as a command), `release-manifest.py`, `build-in-docker.sh` (the build on our own hardware) and the rewritten workflow (manual only; inputs `arch`, `publish` = none, dev or production; a draft GitHub release with the small files for production, no image) are tested with stubs and a local HTTP server, and **[N]** none of it ran against R2. What the old workflow did, a non-draft release that uploaded the ISO on every dispatch, is gone. [Publishing to R2](../guides/release-checklist.md#publishing-to-r2) has the layout, the two routes and the owner steps.
2. **Who holds the release key.** `build-iso.sh --sign` signs with the invoking user's default key and the workflow signs with the `production` environment's `GPG_PRIVATE_KEY` and `GPG_PASSPHRASE`; **production refuses an unsigned release**, but no key holder, no published public key and no procedure for users to verify with it exist.
3. **Roles.** Build owner, verifier, signer and publisher are not named (see the [release checklist](../guides/release-checklist.md)).

**Decision and work needed.** The owner steps in the checklist (environments `dev` and `production`, one R2 token per environment, the two public domains, the prefix), a key holder and a key-rotation rule, the four roles, a retention rule for old versions on R2, and one rehearsal on `dev` with a throw-away version recorded in `docs/evidence/`.

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
| `backends/ubuntu/chroot/tests/first-boot-units-boot.sh` booted containers with systemd as PID 1 in `--privileged` mode (`docker create --privileged ... /sbin/init`), the likely cause (by timing, and by what `systemd-binfmt` does; the wipe itself was never reproduced) of three wipes of the Docker VM's Rosetta registrations on Docker Desktop for Apple silicon in one week | the script and its header; commit `f20d3a6`; [building-on-a-mac.md](../guides/building-on-a-mac.md#never-run-systemd-as-pid-1-in-a-privileged-container); [running-the-tests.md](../guides/running-the-tests.md#tests-that-start-systemd-as-pid-1) | **Fixed in `f20d3a6`; the guard now exists.** The default profile is unprivileged (no added capability, the default seccomp profile, `--cgroupns=host`, a tmpfs `/run`) and all 45 checks and 14 boots pass in it. **`CAP_SYS_ADMIN` is deliberately not granted, because it is not enough on its own**: a container that has it can `mount -t binfmt_misc` itself and gets the shared instance read-write (measured: the VM's own superblock, the rosetta and qemu handlers listed), so `--cap-add SYS_ADMIN` with a read-only `/proc/sys` keeps `systemd-binfmt.service` out but not a process that mounts it. A gate runs before any systemd container exists and refuses (exit 1) if `/proc/sys` is writable or `binfmt_misc` can be mounted; the four binfmt and sysctl units are masked in every container; every boot is re-checked; `--selftest` (43 checks, no Docker, 14 mutants killed) is in `check-repo.sh`. `CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED=1` is the explicit, loud override: do not set it on Docker Desktop. [V] the commit message and the header, read; the counts were not re-run for this page. The rule for every other test: no `--privileged` and no `CAP_SYS_ADMIN` with `/sbin/init` |
| The ISO workflow installed `debootstrap`, which nothing uses | `.github/workflows/build-companion-os-iso.yml` | **Fixed:** the line is gone (the Mac recipe and `build-in-docker.sh` never installed it, and the images they built verified); a test keeps the workflow's package list equal to the script's |
| `docs/CI.md` is generated and listed only two workflows ("No local checks detected") | `docs/CI.md` | **Regenerated 2026-10-20** with `ci-local`'s own renderer (`render_repo_doc`, the code `ship --write-docs` runs; `ci-local docs` writes the cross-repo runbook, not this file): four workflows and the new inputs. It is marked do-not-hand-edit; regenerate it after any change to a workflow's inputs |
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

## KI-20 The Calamares keyring step had a 30 second limit (fixed in `ad37b64`, seen working once on ISO #6)

**Severity:** High when found; **fixed**. **Owner:** owner to assign.

**What.** In the installer's `shellprocess_initialize_pacman.conf` only the first command (`update-mirrorlist`) has `timeout: 3600`; the second, `bash /etc/calamares/scripts/create-pacman-keyring`, has no `timeout` key, so Calamares applies its 30 second default. The script runs `pacman-key --init`, two `pacman -Sy` of the keyring packages and `pacman-key --populate` (a gpg import of the Arch and CachyOS keys). Under QEMU TCG that takes about 28 to 32 seconds, and on a slow disk, an old board or a loaded virtual machine it can exceed 30.

**Evidence of the defect.** [V] ISO #5, stage 2: attempts 1 and 2 ended at 2 percent with the dialog "Installation Failed: command `bash /etc/calamares/scripts/create-pacman-keyring` failed to finish in 30 seconds" (frame `install/09b`; log line `Process "/bin/sh" timed out after 30000 ms`, then `Installation failed: External command failed to finish`). Attempt 3 passed the step about 2 seconds inside the limit, with the product's own scripts and nothing hand-initialised, and the install then completed (23 min 20 s). ISO #4 passed the same step at a lower host load. A failed attempt leaves the disk partitioned, so the next attempt lists extra partition choices. A real machine does this in a few seconds [I].

**Fix, committed in `ad37b64` and run on ISO #6.** `backends/cachyos/installer/modules/` has overlay copies of three stock configs, `shellprocess_initialize_pacman.conf` (`timeout: 3600` on the two commands that talk to mirrors, 600 s for the rest of the file), `shellprocess_modify_mk_hook.conf` and `shellprocess_reset_mk_hook.conf` (600 s), which differ from the installer's only in explicit `timeout` keys. A `shell-timeouts` guard (`installer/lib/ci-shellprocess.py`, a row in `installer/guards.list`) fails the launcher, `verify-iso.sh` and the tests when any `shellprocess` command of the effective install sequence has no explicit limit, when a command that runs a network or package tool has less than 600 s (disk tools: 300 s), and when a frozen copy no longer runs every command of the installer's file. Tests: `iso/tests/installer-launcher.sh`, against a fake installer tree that holds the installer's real commands (the `spconf` lines of the facts file), including the keyring command that has no limit.

**Evidence of the fix.** [V] **ISO #6 (one run, in a virtual machine):** the install passed on the **first attempt**, no error dialog, all 47 jobs in 28 min 26 s. `create-pacman-keyring` ran **32 seconds** (15:48:13 to 15:48:45 guest time; the Arch key import alone 25 s), longer than the old 30 second default, and passed under the explicit limit; the session log has no "timed out" line (`docs/evidence/2026-10-18-plasma-iso6/calamares-keyring-excerpt.txt`, `calamares-jobs.txt`). `verify-iso.sh` on that ISO reported 215 passed, 0 failed, including the explicit-limit checks (`verify.log`).

**What remains.** The code defect is closed by construction (an explicit limit on every command); the evidence is **one run** at host load 9 to 13, so a second run and a real slow machine would turn "once" into a rate (test-evidence, Plasma rows 10 and 11). A person on an ISO older than `ad37b64` still sees the dialog: close it and start the installer again, which can take several tries on a slow machine.

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

## KI-26 Plasma edition leftovers found by the ISO #6 run

**Severity:** Low (cosmetic and noise). **Owner:** owner to assign.

**What.** The run that installed on the first attempt (ISO #6, [V] in a virtual machine, [`docs/ui/companion-os/plasma/CAPTURE.md`](../ui/companion-os/plasma/CAPTURE.md), findings 1, 5 to 9) found small things that no earlier entry covers. None blocks anything and none changes an exit code.

| Item | Evidence | Note |
|---|---|---|
| The Plasma Login Manager greeter has the stock avatar and button set and no Companion mark; only the wallpaper behind it is Companion's. It starts on a clock page and shows the password prompt after a key press | [V] frame 21; decision D2 (the login manager is not SDDM) | decide whether the greeter is themed |
| The install log of a successful run has 58 `WARNING` lines and 1 `ERROR` line: `Could not inhibit sleep` (no PowerManagement service in the live session), unknown global-storage keys, ten "Cannot enable/disable systemd unit" failures for units this edition does not ship (cups, vboxservice, vmtoolsd, firewalld, the zfs units, pacman-init), `No config file for "chwd"`, and **eight lines `[Errno 2] No such file or directory: 'chcon'`** | [V] the session log of ISO #6; the `chcon` lines were also on ISO #4 | SELinux is not used on this edition, so `chcon` is noise; the missing binary is the only thing the line names |
| The first-boot log carries a Node stack trace `Cannot find module '.../pnpm.cjs'` after `corepack prepare pnpm@latest --activate: ok`, then "[SUCCESS] pnpm is available"; `[WARNING] gdm not detected` (irrelevant on Plasma); a Node 22.15.1 maintenance warning | [V] the guest log (301 lines), read through the guest agent | both the corepack step and the GDM warning are in `backends/arch/provision/provision.sh` (`backends/arch/**` is frozen, decision D8), so the owner decides where a fix goes |
| The Bootloader page says GRUB "finds other operating systems on the disk", but the installed `GRUB_DISABLE_OS_PROBER` is `true` by design (KI-08) | [V] frame 10 and the installed `/etc/default/grub` | the page text is upstream's; the trade-off is stated in KI-08 |
| Live medium: `systemctl is-system-running` is `degraded` because `systemd-time-wait-sync.service` fails; `/usr/local/bin` lists upstream helper names (`choose-mirror`, `dmcheck`, `pkexec-wrapper`, `prepare-live-desktop.sh`, `remove-nvidia`, `removeun`, `removeun-online`); `cachyos-hello` is installed but hidden and does not start | [V] `CAPTURE.md`; the first also on ISO #4 and #5 | not user-visible; the installed system is `running` |
| Installed boot: a user unit "Failed to start Portal service" 51 s into the session under heavy load, a libinput "event processing lagging behind" warning, `virt/tdx: TDX not supported` (kernel, harmless in a virtual machine); the first journal lines carry the host name `cachyos` before the hostname is applied | [V] `journalctl -b -p err` of the ISO #6 run | the portal failure was not investigated [N]; the desktop and About page worked |

**Decision needed.** None before a release; fix with the next pass over the installer overlay and the provisioner, or leave as disclosed noise.

## KI-27 What the first install of the clean-checkout Ubuntu image found (2026-10-18/19)

**Severity:** High for the first login, Low for the branding items. **Owner:** owner to assign.

**What.** All [V] in one virtual machine (QEMU/OVMF, Secure Boot firmware, TCG, 4 vCPUs, the host at a load average of 20 to 35 throughout), image `709b8485...`, stock interactive installer, then the installed disk on a throwaway overlay. Frames and logs are in the session scratch directory and are not yet in `docs/evidence/`.

| Finding | Evidence | Note |
|---|---|---|
| **The first graphical login failed twice and returned to the greeter** while `snapd.seeded.service` and the model download were still running. The journal says `org.gnome.Shell@ubuntu.service` failed after 1 min 36 s having used 50 s of CPU, then `gnome-session@ubuntu.target ... failed with result 'dependency'`. The same login worked about 14 minutes later, after the model download had finished and the load was low (snap seeding was still running then) | journal of the installed system; the third attempt reached the desktop in about a minute | On real hardware the work is minutes, not an hour, so this may never show; a slow machine or a slow USB disk is the case. Mitigation committed (not proven on an image): the first-boot unit runs after `snapd.seeded`, as `Type=exec`, at idle CPU and IO priority, journal only. It does not throttle `ollama.service`, which does the actual download, so the real fix may be to start the pull only once the desktop is up |
| **Boot stayed "not finished" for 30+ minutes**: `systemctl list-jobs` showed `snapd.seeded.service` running with `cloud-final`, `cloud-init.target`, `multi-user.target` and `graphical.target` waiting behind it. The browser (Firefox) was not in the dock until seeding ended | `systemctl list-jobs` and `systemd-analyze` in the guest | Stock Ubuntu behaviour that the emulation makes slow. A first-login page that needs a browser must wait for it: `welcome-once` now does |
| **The old first-boot unit printed the model-download progress bar on the text console** (`StandardOutput=journal+console`), so at the first login the screen showed `first-boot-setup.sh[...]: pulling ...: 100% |####|` instead of the desktop | frame taken during the login | Fixed in the unit (journal only) |
| **The first-boot setup itself worked**: it ran 16 min 30 s, pulled the small models and wrote its done marker (`First-boot setup completed`) | `/var/log/ci-os-first-boot-setup.log` | **Correction (2026-10-19):** an earlier version of this row said it pulls `qwen3.6:27b` (about 17.8 GB) on every install. That was wrong: `provision.sh` pulls it only when `ci_os_hardware_supported` and the RAM/GPU fit gate (`core/lib/gpu-detect.sh`) allow it, and in the 6 GiB test VM it was skipped. The pull there was `nomic-embed-text` and `gemma3:1b` (about 1.1 GB) |
| **The desktop-icons extension (DING) was relaunched 102 times in about 12 minutes** (`Launching DING process` every 4 s in the shell journal), and no desktop icon ever showed, not even a test shortcut. Run by hand it started and printed `Detected async api for thumbnails` | shell journal, `gnome-extensions info` says ACTIVE | Not shown to be a defect of the image: Nautilus and ArchiveManager were being D-Bus-activated by each instance, which is slow here. **Desktop shortcuts for the Companion links are in the image but have never been seen to render or launch.** The dock and the application grid carry the same links |
| The **first-run screen** is Canonical's: "Welcome to Companion OS 1.0!" with the Ubuntu raccoon artwork. The **login text** is Ubuntu's: the ESM/Pro advert (`sudo pro status`), "The programs included with the Ubuntu system ...", "Ubuntu comes with ABSOLUTELY NO WARRANTY". The text login banner itself (`Companion OS / Companion Intelligence - https://ci.computer`) is ours | frames | Branding gaps; the legal sentences may need to stay |
| `Hub` deploy defaults point at `portal.companionintelligence.com`, which has no DNS record on 2026-10-19; Hub's own `.env.example` uses `https://hub.ci.computer` (production) | `dig`, `core/lib/ci-hub.sh`, `core/manifest/ecosystem.yaml` | Not changed; decide which host is current before the next image |
| The installer's update step (`unattended-upgrades`, 227 packages) took 4 h 15 min under emulation; the one-click path sets `updates: security` | installer log | Stock behaviour; real hardware is a small fraction of this |

**Done since (2026-10-19, in the same pull request, not yet proven on a booted image):** the first-boot setup is started by its timer three minutes after boot (no longer linked into `multi-user.target`), waits for a quiet machine (`wait-quiet`: load below 60 percent of the CPUs three times in a row, never for more than 20 minutes) and throttles `ollama.service` for its run; Canonical's first-run is skipped by `~/.config/gnome-initial-setup-done` in `/etc/skel`; the motd scripts that advertise Ubuntu Pro are held off by `dpkg-statoverride` (the first install showed the advert because an upgrade had restored the executable bit); `/etc/legal` says Companion OS; the Ubuntu Pro autostart notification is diverted aside.

**Proved on a booted arm64 image (2026-10-19, [V] in a virtual machine, `docs/evidence/2026-10-19-ubuntu-arm64-4b7597d/`):** the timer, `wait-quiet` (quiet after 30 s), the `ollama.service` throttle, the journal-only output (279 journal lines, 16.6 KB, against 40 KB for one pull before) and the Hub start ran as designed: 1 min 58 s, exit 0, two models, `ci-hub` healthy. **The skel stamp was not enough.** On the image of `c0059d6` the first sign-in still showed "Welcome to Companion OS 1.0!" with the raccoon: `gnome-initial-setup-upgrade-login.service` runs `gnome-initial-setup --upgrade-user` when `~/.config/gnome-initial-setup-done` exists but `~/.config/gnome-initial-setup/upgrade-26.04-done` does not ([`docs/evidence/2026-10-19-ubuntu-arm64-c0059d6-first-run/`](../evidence/2026-10-19-ubuntu-arm64-c0059d6-first-run/)). Commit `6aa27f6` puts the stamp that unit names into `/etc/skel` (read from the unit in the image, so a later release keeps working), `verify-iso.sh` checks it, and the image built from it showed no first-run page at the first sign-in. The first-run finding of the amd64 image is covered by the same unit and by 446 verifier checks; a boot of the amd64 image has not been done [I].

**The amd64 image of `4b7597d`, live session only, under software emulation (2026-10-19, [V] in a virtual machine, `docs/evidence/2026-10-19-ubuntu-amd64-4b7597d/x86-live-run.txt`):** the splash at 8 min 30 s, the greeter at about 11 minutes, the desktop after one click on the live user (the session did not log in by itself on this run; on arm64 it did). The dock is right and **holds Companion Capture**; **no desktop icon appeared in six minutes**, although `~/Desktop` holds the five trusted shortcuts and `ding@rastersoft.com` is ACTIVE: its process is relaunched every 3 seconds, as the earlier image's 102 relaunches in 12 minutes. The arm64 image, same configuration, showed every icon at once. So **desktop-icon rendering on amd64 is still [I]**; slowness of emulation is the suspect and real hardware is the test.

**Fixed and proved on a fresh install of `ee4a3b4` (2026-10-19, [V] in a virtual machine, `docs/evidence/2026-10-19-ubuntu-arm64-ee4a3b4/`):** the first sign-in opens one tab, the Companion page, with no "Firefox Privacy Notice" tab (a policy file, `/etc/firefox/policies/policies.json`, which the snap reads through its `etc-firefox` interface) and no "Software Updater" pop-up although 78 packages were waiting (`com/ubuntu/update-notifier no-show-notifications=true` in the dconf local database; security updates still install by themselves, and `ci-os-info` says when a restart is waiting). The setup log no longer carries "not deployed", "deploy read key", "gsettings not available" or the "log out for Docker and PATH" note, and ends with next steps that name Hub, `ci-os-info` and the Docker group. `ci-os-info` now reports the setup, Hub's address, the models, the disk, failed services and a pending restart, and offers the ROCm command only where it exists. The verifier checks all of it (442 checks on arm64); the 36-check `ci-os-info.sh` suite and section 12 of `customize-chroot-checks.sh` pin it. Not changed: the pop-ups are off for every user, so a restart notice is not shown on the desktop.

Two small things the image of `4b7597d` showed (both fixed in `ee4a3b4`, above): Ubuntu's Software Updater announces "79 Updates Available" at the first sign-in (the image carries the archive of its build day), and Firefox opens its own "Firefox Privacy Notice" tab next to the Companion getting-started page.

**Decision needed.** (1) Which host the Hub deploy should use. (2) Whether `ubuntu-insights` (it ran at session start; with the first-run skipped there is no consent page, so by its design nothing is uploaded) should be removed (answered in [KI-30](#ki-30-streamlined-setup-no-ubuntu-pro-prompts-no-canonical-telemetry-no-canonical-wizard-in-the-live-session-dark-and-green-by-default): purged when apt removes it alone, otherwise its units are masked). (3) Run the same install on real hardware (KI-17).

## KI-28 The arm64 build of the Ubuntu edition

**Severity:** Medium. **Owner:** owner to assign.

**What.** `build-iso.sh --arch arm64` builds Companion OS from Canonical's Ubuntu 26.04.1 desktop arm64 ISO ([arm64.md](arm64.md), records in [`../evidence/2026-10-19-ubuntu-arm64/`](../evidence/README.md)). All [V] in QEMU with HVF on an Apple-silicon Mac, natively: build 19 min, `verify-iso.sh` 436 passed 0 failed, live desktop in 2 min, the one-click install in 12 min, installed boot in 19.8 s of userspace, a first sign-in with no Canonical first-run screen and the Companion welcome page, first-boot setup in 2 min 48 s with Companion Hub started headless and healthy.

| Item | Evidence | Note |
|---|---|---|
| The installed system reads `degraded`: `pd-mapper.service` ("Qualcomm PD mapper service") fails on every arm64 machine that is not a Snapdragon | `systemctl --failed` in the installed VM | Canonical ships `protection-domain-mapper` in the arm64 image. Not changed here; a drop-in that requires the Qualcomm device-tree node would stop it, but that is a guess about hardware not at hand |
| Companion Capture is not in the arm64 image | `https://dl.ci.computer/applet/v0.2.0-alpha.7/manifest.json` has no Linux arm64 build; the arm64 pins are empty | the dock entry is hidden by GNOME |
| `companion-os.local` looks like it resolves to a Docker bridge address | On the machine itself, `getent hosts companion-os.local` returned 172.20.0.1. A probe on each interface of the installed image (a multicast query on that interface, answer parsed) showed avahi answers with only that interface's own address (enp0s1 gave 10.0.2.15; each Docker bridge its own), so other devices get the LAN address. **Not a defect on the network side**; not tried from a phone or laptop [N] | no change made |
| At the first sign-in Ubuntu's Software Updater said "79 Updates Available", and Firefox opened its own privacy-notice tab beside the Companion page | `docs/evidence/2026-10-19-ubuntu-arm64-4b7597d/frames/` | **fixed in `ee4a3b4`** [V] on arm64 (KI-27); the same files ship on amd64 [I] |
| The boot shows kernel messages, not the splash | Canonical's arm64 menu line carries `console=tty0` | stock; the verifier accepts exactly that shape |
| The installed GRUB's background is stock | the arm64 base image has no GRUB to configure; its name follows `os-release` | |
| **Secure Boot on arm64, and every real arm64 machine** (Snapdragon X, Ampere, Raspberry Pi 5), are not tried | Homebrew ships no aarch64 Secure Boot firmware | KI-17 applies |
| `ci-stick` cannot flash or boot an arm64 image | `stick/crates/ci-stick/src/host.rs`: "arm64 boot images are not built yet" | |
| arm64 had no CI build | **[I] since 2026-10-20** the workflow builds both architectures (input `arch`; arm64 on `ubuntu-24.04-arm` or a self-hosted runner) and `backends/ubuntu/iso/scripts/build-in-docker.sh` builds arm64 natively on an Apple-silicon Mac; **[N]** neither has run on GitHub | GitHub-hosted arm64 runners for a private repository: unverified |
| The installed system showed the root filesystem check message and then nothing for a minute: an idle guest, no input accepted, no console output, on the first start of the installed disk | `docs/evidence/2026-10-19-ubuntu-arm64-82e9335-video-run/` (events.txt, 00:36:47); the second time seen | [V] stopped and started again, and the second start reached the greeter in 73 s (as seen by polling); the cause is not known and has not been reproduced on purpose. A virtual machine only: do not read it as a statement about hardware. Next: boot the installed disk five times with the serial log and `systemd.log_level=debug` and see whether it recurs |
| Hub on arm64 needs Docker Compose 2.33+ (Hub's own requirement); the image bakes Docker's current Compose | the Hub containers ran | |

**Decided 2026-10-19 (owner, in chat):** arm64 is a supported architecture of the Ubuntu target ([supported-targets.md](supported-targets.md)); the gaps are listed in [arm64.md](arm64.md#gaps-against-the-five-points). **Still open:** which arm64 hardware to test first, a fixture self-test of the verifier's arm64 branches, a first run of the rewritten workflow for arm64 (a runner, and the build on it), and a safe condition for `pd-mapper.service` (a wrong one would break audio on a Snapdragon X).

## KI-29 Language, keyboard and time zone in the one-click install, and first-boot progress on the desktop

**Severity:** Low. **Owner:** owner to assign.

**What.** Items 1 and 2 of the home-lab polish proposal ([CI-Engineering](https://github.com/companionintelligence/CI-Engineering)). The one-click confirmation has a **Language, keyboard, time zone...** button
([one-click-install.md](one-click-install.md#language-keyboard-and-time-zone)), and the first-boot setup writes `/var/lib/ci-os/setup-status` for a per-user script that shows it as one desktop notification
([installation guide](../guides/installation-guide.md#ubuntu-edition)). Fresh install of the arm64 image of `b124745`, records in [`../evidence/2026-10-19-ubuntu-arm64-b124745/`](../evidence/2026-10-19-ubuntu-arm64-b124745/) and frames 12 to 19b of [`../ui/companion-os/ubuntu/`](../ui/companion-os/ubuntu/CAPTURE.md):
German (Germany), the German keyboard and Berlin were chosen in the dialog and the installed system had `LANG=de_DE.UTF-8`, X11 layout `de`, `/etc/timezone` `Europe/Berlin`, a German greeter and Firefox; the notifications
"getting ready", "step 3 of 7", "step 5 of 7", "step 7 of 7" and "ready" reached GNOME during the first boot (2 min 28 s); the ready message was not repeated at the next run. All **[V]** in a virtual machine, not real hardware.

| Item | Evidence | Note |
|---|---|---|
| The first version of the ready message asked for an "Open Companion Hub" button; none appeared | `notify-send -A` printed "Actions are not supported by this notifications server" and sent an empty action list, although `GetCapabilities` lists `actions` (`guest-text/notify-send-actions.txt`); a direct D-Bus call with an action list is accepted | **fixed in `c8de040`, and the image of `82e9335` (its code) installed fresh [V]**: no button, the message says Hub is the first icon in the dock. The unit test could not have found it (its `notify-send` is a stub); it now refuses any `-A`. A real button would need a D-Bus listener (`gdbus monitor` for `ActionInvoked`): not built |
| The banner for "needs attention" was not photographed (the one for "waiting for the internet" was, on the fifth run, frame 20) | the failure text is in `notifications-sent.txt` (sent by the revised script against a fake status file) and in the unit tests; a real failed first boot was not provoked | provoking one (no network at the first boot, then a manual run) is a cheap next step |
| The notification text is English whatever language was chosen | the strings are in the script | not translated; a later step if the audience needs it |
| Only the languages whose packs are on the image (de, en, es, fr, it, pt, ru, zh) are offered, and the keyboard has no variants | `locale -a` and `base.lst` in the live session | the normal installer offers more and installs their packs from the network; `fr_CH` and `it_CH` suggest the `ch` layout, which xkb calls "German (Switzerland)" |
| A step shorter than the 15-second look is not shown, so the numbers skip (3, 5, 7 were seen; 1, 2, 4 and 6 went by) | `status-transitions.txt` | by design: one notification per observed change |
| The progress text says "up to a few minutes, longer on a slow connection"; the first boot took 2 min 28 s on a fast link | `installed-facts.txt` | a slow link and a larger model set (Strix Halo class) were not tried |
| Five minutes after the last input the screen blanks and the session locks, which a person waiting for the first boot (about two minutes) can meet | frame 23 and `docs/evidence/2026-10-19-ubuntu-arm64-82e9335/run.txt` | Ubuntu's default; not changed. The notifications are in the list after the unlock |
| amd64 is untried, as is anything on real hardware | | KI-17 applies |

**Not decided.** Whether the notification text is worth translating, and whether a "Open Hub" button is worth a D-Bus listener.

## KI-30 Streamlined setup: no Ubuntu Pro prompts, no Canonical telemetry, no Canonical wizard in the live session, dark and green by default

**Severity:** Low (nothing blocks). **Owner:** owner to assign. **Status of 2026-10-19 (evening, local):** built, installed and looked at on arm64 in a virtual machine, once each, no real hardware. The image of `cf68024` (sha256 `ee5f850d...76e9`, `verify-iso.sh` 492 passed, 0 failed) showed everything below and one defect, a live session with no dock and no desktop icons; the image of `5ff5224` (sha256 `217c1144...3f07`, 493 passed, 0 failed) has the fix and shows it fixed. Records: [`docs/evidence/2026-10-19-ubuntu-arm64-streamline/`](../evidence/2026-10-19-ubuntu-arm64-streamline/run.txt). Frames: [`docs/ui/companion-os/ubuntu-streamline/`](../ui/companion-os/ubuntu-streamline/CAPTURE.md). amd64 was not built: **[N]**.

**What.** The owner's request of 2026-10-19: "Streamline os setup, disable Ubuntu Pro prompting and Canonical telemetry and hide the parts of the Ubuntu wizard, make theme dark and green by default."
Five changes on one branch (`liam/companion-os-streamline-setup-2`), each with a check in `verify-iso.sh` and a unit test that runs on a Mac:

| Change | Where | Evidence |
|---|---|---|
| Ubuntu Pro and Canonical's background callers go quiet: the Pro client's apt news and timers off in `uaclient.conf`, its apt hook diverted, `88-esm-announce` and the other login-text adverts kept off, `ua-timer`/`apt-news`/`esm-cache`/`motd-news` masked, `ubuntu-insights` purged only when apt removes it alone and otherwise its units masked, every Pro and telemetry autostart entry diverted, two GNOME privacy defaults off, two more hosts blocked | `backends/ubuntu/lib/quiet-canonical.sh`, `customize-chroot.sh` Step 2c, `remove-telemetry.sh`; `verify-iso.sh` 6b | **[V]** `lib/tests/quiet-canonical.sh` (118 checks on fake roots with stub dpkg commands; 18 mutants caught) and `iso/tests/verify-quiet-appearance.sh` (the real text of sections 6b and 6c on good, stock and singly broken fake roots; 23 checks; 11 mutants caught); **[V]** the installed arm64 system, read by `proof.sh` (`after-cf68024/proof-facts.txt`): `apt_news: false` and the three timers at 0, the apt hook is `20apt-esm-hook.conf.disabled`, `ua-timer.timer` and `motd-news.timer` and the three services are masked, `ubuntu-insights` is removed and held, six hosts are blocked, `pro status` still runs, the Pro autostart entry is diverted; on `5ff5224` also `sudo apt-get update` (11 lines) and a simulated `apt-get -s upgrade` print no Pro, ESM or news line (`after-5ff5224/apt-update.txt`, `apt-upgrade-simulation.txt`; `main` was not run for comparison). The same read on `main` shows all of the settings as they were (`before-main-5d50582/proof-facts.txt`). **[I]** a real `apt upgrade` as root, a machine attached to Ubuntu Pro, and amd64 |
| Canonical's installer window no longer opens by itself in the live session: the user-service link is removed (Step 7b), the dock pins only the automatic launcher, the helper starts the installer's server unit itself | `customize-chroot.sh`, `dock-favorites.txt`, `ci-os-auto-install`; `verify-iso.sh` 3g, dock | **[V]** unit tests (`customize-chroot-checks.sh` section 14, three helper tests, the dock list test); **[V]** arm64, both images: from the automatic boot entry the one-click dialog is the first and only window, Canonical's installer is not open and its unit is not started (`live-facts.txt`), the server unit is active; from the plain entry (`5ff5224`) the live session shows the desktop and no window at all (frame 13); **[V]** `5ff5224`: Canonical's installer still opens from the dialog's **Use the normal installer** button and from its own launcher on the desktop |
| **The live session is taken out of "installer mode"** (found by the boot of `cf68024`). The live layer starts the session with the dock hidden and the desktop-icons extension off; Canonical's unit undoes that when its window closes, and the unit is not started any more | `ci-os-auto-install` (`RESTORE_SESSION`, `restore_normal_session`, called by `live_setup`); `verify-iso.sh` `restore_drift` | **[V]** `test_auto_install.py` (212 tests, 5 of them new; 7 mutants of the new code caught) and `iso/tests/verify-restore-drift.sh` (25 checks; 6 mutants of the script caught); **[V]** the defect: the live session of `cf68024` had no dock and no desktop icons, eight minutes in (`dock-fixed false`, `intellihide false`, `disabled-extensions ['ding@rastersoft.com']`, `after-cf68024/live-facts.txt` and `dock-facts.txt`, frame 01); **[V]** the fix: the live session of `5ff5224` has `dock-fixed true`, `intellihide true`, `ding@rastersoft.com` enabled and running, the dock and the icons drawn (`after-5ff5224/live-facts.txt`, frames 02 and 03); the real verifier read the stock unit out of the image and passed `restore_drift` |
| The installed system's first-run pages (welcome, Ubuntu Pro, Location Services, Help improve Ubuntu, Appearance, Ready to go) were already skipped by the `/etc/skel` stamps; the verifier now also reads the first-login unit of the image | `verify-iso.sh` | **[V]** both images: the first sign-in opened one window (Firefox, one tab) and no first-run page and no Software Updater banner (frames 08, 09); the new verifier check passed on the real image |
| Dark and green: `color-scheme` `prefer-dark` and `accent-color` `green` for every user, as a dconf default and a schema override | `backends/ubuntu/lib/appearance.sh`, `customize-chroot.sh` Step 3; `verify-iso.sh` 6c | **[V]** `lib/tests/appearance.sh` (20 checks) and the section 6c half of `iso/tests/verify-quiet-appearance.sh`; **[V]** both images: `color-scheme 'prefer-dark'` and `accent-color 'green'` for the live user and for the new user, Settings > Appearance shows Dark selected and the green swatch (frame 12), the one-click dialog and the progress window are dark with a green bar, Firefox and the docs page it opens are dark, the stock installer's window is dark with a green page dot, the greeter's selected card is outlined in green (it was orange) |

| Item | Note |
|---|---|
| **Green or teal** | Green is on screen now (the swatch, the progress bar, switches, the greeter's card outline, the stock installer's page dot); teal was not tried. The brand's phthalo `#0a6358` and sage `#c5e8dc` are not GNOME accents. Green (`#3a944a`) and teal (`#2190a4`) share their hue (CIELAB hue 181 degrees; green 144, teal 220). Euclidean RGB distance says green is nearer (70 against 91), CIELAB distance says teal (dE 26; green 40). The frozen Arch backend and the backends retired on 2026-10-17 (tag `pre-retire-multidistro-2026-10-17`) chose teal and called it "a judgment call". The owner said green. One edit of `CI_OS_ACCENT_COLOR` flips it, and the test keeps any change to those two |
| **Yaru's GTK 3 theme** | Firefox's window (GTK 3) followed the dark scheme, and so did the docs page it shows **[V]**. Whether a GTK 3 window follows the green accent, and how Software Properties looks, were not looked at **[N]**; `gtk-theme` is still not set (a name Yaru 26.04 may not have would make GTK apps fall back to Adwaita). The terminal keeps Ubuntu's aubergine palette: nothing asked for it and nothing changed it **[V]** |
| **The greeter** | The login screen has its own dconf database (`gdm.d`, no appearance keys, checked) and the recoloured Yaru shell theme (phthalo and sage, built by `core/render`), and both are unchanged. It does read the schema override, so the selected user card is outlined in green now **[V]** (`compare-before-after.png`); the background and the logo are as they were |
| **`ua-timer` is masked** | The Pro client stays installed and `pro attach` works, but its periodic jobs do not run. A user who attaches later runs `sudo systemctl unmask ua-timer.timer apt-news.service esm-cache.service`. A machine that is attached when `remove-telemetry.sh` runs keeps its client, hook and timers |
| **`uaclient.conf` is a conffile that is now modified** | An upgrade of `ubuntu-pro-client` that changes the file keeps ours under unattended-upgrades (its dpkg options keep the old file **[I]**) and asks in an interactive `apt upgrade` |
| **`ubuntu-insights`** | KI-27 asked whether to remove it. On the arm64 image it was purged and held (`hn` in the installed system's package list **[V]**); where apt would remove something else with it, its units are masked instead and the build log says so (`[WARN] ... is not purged: apt would remove ...`) |
| **Canonical's wizard itself** | The 13 pages and "Welcome to Ubuntu" are text in a snap and cannot be hidden by remastering. It stays reachable as the advanced path (dual boot, manual partitions): the dialog's button, its own launcher on the live desktop and the application grid; the first two were seen opening it **[V]**, in the dark scheme with a green page dot |
| **Canonical's launcher is on the live desktop** | Drawing the desktop icons shows the stock file in `~/Desktop` (`ubuntu-desktop-bootstrap_ubuntu-desktop-bootstrap.desktop`, which casper names "Install Companion OS") next to ours ("Install Companion OS..."): two installer icons, one with the Ubuntu mark **[V]** (frame 03). It is not pinned in the dock. Hiding the desktop copy is a follow-up; `customize-chroot.sh` does not touch that file |
| **The post-install re-skin mixins are unchanged** | `backends/_mixins/gnome-dconf/25-session-gsettings.sh` still sets `com.ubuntu.update-notifier no-show-notifications false` and a `Yaru-*-dark` `gtk-theme` on a machine that runs `apply-ci-os-desktop.sh`; they are shared with the frozen Arch backend |
| **Time zone, not changed here** | After the one-click install the installed clock reads `Etc/UTC` although the dialog says "time zone: detected automatically", on every Companion image looked at that evening (the stock Ubuntu installer found the host's zone on the same machine); see the first-run teardown (`ftue-teardown.md`, in pull request 87 and not on `main` yet), gap N1. `DEFAULT_ZONE = "geoip"` in the helper is the first place to look **[N]** |

**What the boot of `5ff5224` showed.** Live session, from the automatic entry: the dialog (dark) in front of a normal desktop with the dock (the automatic launcher first, Canonical's not pinned) and the icons; no Canonical window; the dock launcher reopens the dialog; **Use the normal installer** opens Canonical's window. From the plain entry: the same desktop and nothing open. Installed system: the two values for the new user; no first-run window and no Software Updater banner; the Pro and telemetry state listed in the first row; `systemctl --failed` lists only `pd-mapper.service` (KI-28). **What no run looked at:** a real `apt upgrade` as root printing no Ubuntu Pro, ESM or news line **[N]** (`apt-get update` and a simulated upgrade did **[V]**), a GTK 3 window other than Firefox's, amd64, real hardware, a second run.

**Decision needed.** (1) Green or teal, now that green has been seen. (2) Whether to hide Canonical's launcher on the live desktop. (3) Whether masking `ua-timer` is acceptable for users who attach to Ubuntu Pro later.

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
