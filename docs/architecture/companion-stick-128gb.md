# Companion Stick on 128 GB sticks: Docker, optional tools, models, mass flashing

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Date 2026-10-13. This page is the index and the decision record for the work that makes the
Companion OS image and the Companion Stick suitable for the nine "128 GB" USB 3.x sticks in
the first batch (123,942,731,776 bytes each). The detail lives in four documents:

| Document | What it covers | State |
|---|---|---|
| [docker-in-live-sessions.md](docker-in-live-sessions.md) | Docker and the `docker` group on the installed system, the plain live ISO and a Stick live boot | Implemented; QEMU test written, **not run on a built ISO** |
| [tier-b-tools.md](tier-b-tools.md) | tailscale, cloudflared, gh, Ollama and the Companion Launcher baked into the ISO with pinned keys and hashes | Implemented; exercised in an amd64 container, **ISO build and boot test see below** |
| [model-packs-128gb.md](model-packs-128gb.md) | Which models fill the 73 GiB `CI-CACHE`, their sizes, licences, and the Ollama store layout on exFAT | Catalog implemented; **populating a stick is not** (`ci-stick models sync` does not exist) |
| [mass-flashing.md](mass-flashing.md) | Inventory of the attached sticks, how flashing works today, the recommended station, runbook, time estimates | Investigation only; **no batch tooling, nothing written to any stick** |

## What the 128 GB stick looks like

`ci-stick layout plan --size 123942731776`:

| # | Label | FS | Size | Holds |
|---|---|---|---|---|
| 1 | `CI-EFI` | vfat | 1 GiB | bootloader, A/B pointer |
| 2 | `CI-SHARED` | exFAT | 7 GiB | launchers, installers, docs (Windows and macOS see this one) |
| 3 | `CI-BOOT-A` | raw | 11 GiB | Companion OS image (about 7.9 GB with every optional tool) |
| 4 | `CI-BOOT-B` | raw | 11 GiB | update slot |
| 5 | `CI-CACHE` | exFAT | **73 GiB** | `models/` (Ollama store) and `oci/`; `stick-128` fills it to 74.4 GB of 78.4 GB |
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
- **Launcher binary drift fixed:** the binary and package are `companion-hub` (since CI-Hub 2026-06-03), not `ci-os-hub-desktop`. The pairing gate (`setup_service.py`), the Ubuntu, Fedora and Arch provisioners and the dock pin looked for the old name and never matched. `provision.sh` also verifies the Launcher download's sha256 against the release manifest now.
- cloudflared's apt key file is `cloudflare-main.gpg` (the vendor rolled the key on 2025-10-30; the old URL still serves the same bytes).
- `model-packs.yaml`: every existing size is now the exact registry size, and `qwen3.6:27b` is `Apache-2.0` instead of `unverified`.

## How to build and check

```bash
# build (Ubuntu 24.04 host, root); every Tier B knob defaults to 1
sudo ./backends/ubuntu/iso/scripts/build-iso.sh --base-iso ./ubuntu-24.04.5.1-desktop-amd64.iso
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
11. **Not done, and not asked for yet:** populating a stick (`ci-stick models sync`), batch flashing tooling, the first real `flash --device` on Linux.
