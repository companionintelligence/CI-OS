# Companion Stick on 128 GB sticks: Docker, optional tools, models, mass flashing

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Date 2026-10-13, state re-checked 2026-10-18. This page is the index and the decision record
for the work that makes the Companion OS image and the Companion Stick suitable for the nine
"128 GB" USB 3.x sticks in the first batch (123,942,731,776 bytes each). On 2026-10-17 the
supported targets became Companion OS on Ubuntu 26.04.1 and on CachyOS; Ubuntu 24.04 is
retired. Every measurement below that was taken on 24.04.5 is labelled **retired baseline
(24.04.5)**; it explains a decision but is not evidence for the 26.04 image. The detail lives
in five documents:

| Document | What it covers | State |
|---|---|---|
| [docker-in-live-sessions.md](docker-in-live-sessions.md) | Docker and the `docker` group on the installed system, the plain live ISO and a Stick live boot | Implemented. **Retired baseline (24.04.5):** the plain live ISO was proven in QEMU (`docker-live.sh iso`: PASS, `hello-world` offline as the unprivileged user). Not re-run on 26.04 [N]; Stick + persistence and the installed system still to prove |
| [tier-b-tools.md](tier-b-tools.md) | tailscale, cloudflared, gh, Ollama and the Companion Launcher baked into the ISO with pinned keys and hashes | Implemented. **Retired baseline (24.04.5):** built into a 7.9 GB ISO that passed `verify-iso.sh` 147/147 and booted live. The 26.04.1 build is pending evidence (see [Open items](#open-decisions-for-the-owner)) |
| [model-packs-128gb.md](model-packs-128gb.md) | Which models fill the 73 GiB `CI-CACHE`, their sizes, licences, and the Ollama store layout on exFAT | Catalog implemented and locked (`core/manifest/model-packs.lock.json`). `ci-stick models fetch` exists for Ollama references, tested against local listeners only; **no real stick has been populated** |
| [models-tooling.md](models-tooling.md) | `ci-stick models`, the lock, the cache layout, the OS adapter, the hardware-fit gate | `lock`, `plan`, `fetch`, `cache-info` implemented; `verify`, `gc`, `export`, `import`, `view` not built in `ci-stick` |
| [mass-flashing.md](mass-flashing.md) | Inventory of the attached sticks, how flashing works today, the recommended station, runbook, time estimates | Investigation only; **no batch tooling, nothing written to any stick** |
| [test-and-mass-flash-plan.md](test-and-mass-flash-plan.md) | The test ladder (QEMU on the Mac, Linux/KVM, real hardware through the tailnet IP-KVMs), the staged mass-flash programme with approval gates, safety requirements and effort | Plan; reviewed by two red teams |

## What the 128 GB stick looks like

`ci-stick layout plan --size 123942731776`:

| # | Label | FS | Size | Holds |
|---|---|---|---|---|
| 1 | `CI-EFI` | vfat | 1 GiB | bootloader, A/B pointer |
| 2 | `CI-SHARED` | exFAT | 7 GiB | launchers, installers, docs (Windows and macOS see this one) |
| 3 | `CI-BOOT-A` | raw | 11 GiB | Companion OS image (about 7.9 GB with every optional tool on the retired 24.04.5 base; one 26.04.1 build measured 7.08 GB) |
| 4 | `CI-BOOT-B` | raw | 11 GiB | update slot |
| 5 | `CI-CACHE` | exFAT | **73 GiB** | `models/` (Ollama store) and `oci/`; `stick-128` fills it to 74.8 GB of 78.4 GB |
| 6 | `CI-PERSIST` | ext4 `writable` | 12.4 GiB | live persistence; Docker's data root in a Stick live boot |

A stick of exactly 128e9 bytes would get 77 GiB; these sticks are 3 % smaller and get 73.

## Decisions taken (2026-10-13, from the request "add docker support and docker group, all optional tools and as many models as the 128 GB sticks allow")

1. **Docker is not guarded against live sessions.** It must work in the plain live ISO and in a Stick live boot. Because `/` is an overlayfs in a live session, a live-only unit bind-mounts `/var/lib/docker` and `/var/lib/containerd` from tmpfs (plain ISO) or from `CI-PERSIST` (Stick with persistence).
2. **`docker` group:** the live user gets it through casper's debconf default group list (casper has no `USERGROUPS`), and the installer-created user gets it from an offline, idempotent boot oneshot that adds every member of `sudo`. Opt out with `/etc/ci-os/no-docker-group`.
3. **Every optional tool is on by default** (`CI_OS_BAKE_*` = 1), each with a fail-closed fingerprint or sha256 pin in `core/manifest/tier-b-pins.env`. tailscaled and Ollama are enabled on the installed system and guarded off in live sessions; cloudflared and gh ship no unit.
4. **Models:** the 3 models `ecosystem.yaml` pre-pulls are ranks 1 to 3; the pack is 21 ranked models (embeddings, small chat, general, coding, vision, OCR, tool calling, one reasoning model), Apache-2.0 or MIT wherever possible.
5. **Mass flashing:** a dedicated Linux station with powered USB 3 hubs, one `ci-stick flash` per stick chosen by USB serial from an allow-list, an intake capacity test, and a re-plug verification. The Mac cannot run `ci-stick flash --device`.

## Also changed on the way (needed for the above to be safe)

- `build-iso.sh` gives the chroot a **private tmpfs `/run`** instead of binding the host's. With the host's `/run` the chroot sees `/run/systemd/system`, so a maintainer script believed systemd was running and could `systemctl start` / `pkill` on the **build host**. The setup-device `postinst`/`prerm` also check `ischroot` now.
- The nginx `listen 5002` proxy block in the setup portal was removed: the Hub publishes host port 5002, so nginx and Docker could never both bind it.
- **Launcher binary drift fixed:** the binary and package are `companion-hub` (since CI-Hub 2026-06-03), not `ci-os-hub-desktop`. The pairing gate (`setup_service.py`), the provisioners and the dock pin looked for the old name and never matched. `provision.sh` also verifies the Launcher download's sha256 against the release manifest now.
- cloudflared's apt key file is `cloudflare-main.gpg` (the vendor rolled the key on 2025-10-30; the old URL still serves the same bytes).
- `model-packs.yaml`: every existing size is now the exact registry size, and `qwen3.6:27b` is `Apache-2.0` instead of `unverified`.

## How to build and check

```bash
# build (Ubuntu 26.04 host, root; build-iso.sh stops on any other host); every Tier B knob defaults to 1
sudo ./backends/ubuntu/iso/scripts/build-iso.sh --base-iso ./ubuntu-26.04.1-desktop-amd64.iso
# a smaller image without Ollama's bundled CUDA libraries (-1.5 GB)
sudo CI_OS_OLLAMA_CUDA=none ./backends/ubuntu/iso/scripts/build-iso.sh --base-iso ...

# rootless inspection of the result (no boot)
backends/ubuntu/iso/scripts/verify-iso.sh output/companion-os-*.iso

# what fits a stick
ci-stick layout plan --size 123942731776
ci-stick models list --device 123942731776

# Docker works offline as the unprivileged user (needs qemu and a hello-world tarball)
stick/tests/qemu/docker-live.sh iso   output/companion-os-*.iso
stick/tests/qemu/docker-live.sh stick output/companion-os-*.iso path/to/stick.img
```

## Open decisions for the owner

1. **`stick-128` (21 models, 3.7 GiB spare) or `stick-128-oci` (19 models, 15 GiB reserved for OCI images)?** The Hub image sizes are not in this repo, so the OCI reserve is a guess.
2. **Second large model:** `gpt-oss:20b` (as shipped, satisfies "one or two large models") or the "maximum model count" variant (23 models: drop gpt-oss, add `gemma4:12b`, `phi4-mini-reasoning:3.8b`, `translategemma:4b`).
3. **Licences for redistribution on physical sticks:** three Gemma Terms-of-Use models (one is forced by `ecosystem.yaml`) and `llama3.2:3b` (Llama 3.2 Community License). Not legally reviewed.
4. **Ollama CUDA:** `all` (default, +1.5 GB, useless without the NVIDIA driver that the ISO does not carry) or `none`. Baking Ollama also removed the first-boot NVIDIA/AMD driver step of its `install.sh`; nothing replaces it yet.
5. **Ollama update policy:** the baked 0.40.3 is never upgraded by `provision.sh`. Rebuild cadence, or an online upgrade with the same hash check?
6. **Launcher autostart** is off: its bundled Hub stack and `ci-hub.sh` both publish host port 5002 (inferred from compose files, not run). Should the Launcher replace `ci-hub.sh`'s deploy on the appliance, run beside it, or be manual-only?
7. **`docker` group is root-equivalent** for every `sudo` member. Keep (as requested), or require `sudo docker`?
8. **Pin freshness:** add a scheduled CI job that re-checks vendor keys and Ollama/Launcher releases (GitHub's key already rotated once).
9. **Hot-plug:** restart Ollama automatically when `CI-CACHE` appears, or require a restart/reboot?
10. **Layout:** a smaller `CI-PERSIST` would give the cache more room; it is also where Docker lives in a Stick live boot.
11. **Not done, and not asked for yet:** populating a real stick (`ci-stick models fetch` exists and has not been pointed at an exFAT volume or a stick), batch flashing tooling, the first real `flash --device` on Linux.
12. **Disk-space guard for model pulls.** The `stick-128` set is cache-sized, but on an installed machine the three `appliance-core` models take about 18.8 GB (nomic-embed-text 0.27 GB, gemma3:1b 0.81 GB, qwen3.6:27b 17.8 GB). On the CachyOS edition's 30 GiB test target they moved the disk from 7.8 GiB to 26 GiB used (88 %); a smaller disk would fail a pull for lack of space. The shared gate `ci_os_model_gate_allows` (`core/lib/gpu-detect.sh`) checks RAM and GPU memory only. Details and the proposed fix: [models-tooling.md](models-tooling.md#14-open-items).
13. **Strix Halo GTT boot parameters** exist only in the Ubuntu backend (`backends/ubuntu/lib/strix-halo-boot-params.sh`); neither the CachyOS edition nor the Stick's `grub.cfg` sets them.
14. **A built 26.04 Companion OS ISO against the slot size.** An 8 GiB slot (64 GB sticks) holds 8,589,934,592 bytes; the first 128 GB sticks have 11 GiB slots. One 26.04.1 build measured 7,076,577,280 bytes (`verify-iso.sh` section 9 now checks this on every build). See [companion-stick.md](companion-stick.md#open-items).
