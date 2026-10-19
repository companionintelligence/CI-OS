# Companion OS quick start

Private & Confidential. Property of Lifescope Inc. Do not distribute.

The shortest path from an ISO to a working machine. Every step links to the full text in the [installation guide](installation-guide.md). Supported targets: Companion OS on Ubuntu 26.04.1 LTS and Companion OS on CachyOS (the "Plasma" edition). Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from the tag `pre-retire-multidistro-2026-10-17`).

Evidence tags: **[V]** verified in a run, **[I]** implemented and unit-tested, not proven end to end. Both editions were run under QEMU only; the Plasma install is verified, the Ubuntu install is pending (see [test evidence](../architecture/test-evidence.md)).

## Pick an edition

| | Ubuntu 26.04.1 | Plasma (CachyOS-based) |
|---|---|---|
| Secure Boot | on is fine | turn it **off** |
| Install network | not needed to copy; needed on first boot | **required** during the install |
| Installer | Canonical's, plus a one-click automatic install | Calamares |
| Boots from the Companion Stick | yes | no |

## Install in five steps

No Companion OS ISO has been published yet (KI-12). Build one with the [ISO build guide](iso-build-guide.md) or get one with its checksum file.

**1. Verify.**

```bash
sha256sum -c SHA256SUMS            # macOS: shasum -a 256 -c SHA256SUMS
# Plasma: sha256sum -c companion-os-plasma-<YYYY.MM.DD>-x86_64.iso.sha256
```

**2. Write the USB stick** (16 GB or larger; this erases it):

```bash
sudo dd if=companion-os-1.0-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync    # Linux
sudo dd if=companion-os-1.0-amd64.iso of=/dev/rdiskN bs=4m                            # macOS, after diskutil unmountDisk
```

On Windows use Rufus (DD Image mode) or balenaEtcher (not tested here).

**3. Boot the stick in UEFI mode** from the firmware boot menu (F12, F2, F10, Esc or Del).

**4. Install.**

- Ubuntu edition: choose **Install Companion OS (automatic)**. The dialog names the disk and what is on it and shows a one-time password for the user `companion`. English, a US keyboard and an automatically detected time zone are used unless you press **Language, keyboard, time zone...** first. **Erase the disk and install** is the only action that writes anything; Enter never confirms. The machine turns itself off at the end: remove the stick, turn it on. Or choose **Try or Install Companion OS** for the interactive installer. [I]
- Plasma edition: choose **Companion OS (Plasma)**, connect to the internet, open the application menu and start **Install Companion OS**, then follow Calamares: choose **Erase disk**, create your user, **Install**. It took 22 to 28 minutes on an emulated machine (a virtual machine, not real hardware). [V]

**5. First boot.** Sign in. With a network the machine provisions itself in the background (Docker, Ollama, the tools and about 18.8 GB of models; 16 to 22 minutes on a fast link). On the Ubuntu edition a notification shows the step it is at and tells you when it is ready [I]. Check:

```bash
ls /var/lib/ci-os/.first-boot-setup-done       # present when it has succeeded
ollama list                                    # the models
```

Allow **64 GB or more** of disk: the system takes about 8 GiB and the default models about 18.8 GB, and nothing checks free space first (KI-01).

## What you get

| | |
|---|---|
| Identity | Companion OS, the Companion Intelligence brand look |
| Docker | Docker with Compose and Buildx; the first user is in the `docker` group |
| Local AI | Ollama with `nomic-embed-text`, `gemma3:1b` and (on supported hardware, and on the Plasma edition) `qwen3.6:27b` |
| Setup portal | A hotspot named `Companion-Setup-XXXX` that appears when the machine has no network, for onboarding a headless box |
| Ubuntu edition extras | Tailscale, cloudflared and the GitHub CLI pre-installed; ROCm helper for Strix Halo-class machines; Strix Halo memory boot parameters |
| Removed (Ubuntu edition) | `ubuntu-report`, `popularity-contest`, `apport`, `whoopsie`; metrics hosts blocked in `/etc/hosts`; the Snap Store |

## Everyday commands

```bash
cat /etc/os-release                     # which edition and version
sudo ci-os-setup                        # run the first-boot setup again (both editions)
ci-os-info                              # Ubuntu edition: version, kernel, GPU and ROCm status, groups
sudo ci-os-install-rocm                 # Ubuntu edition, Strix Halo-class machines only
sudo apt update && sudo apt upgrade     # Ubuntu edition updates
sudo pacman -Syu                        # Plasma edition updates (rolling release)
```

Logs: `/var/log/ci-os-first-boot-setup.log` and `sudo journalctl -u ci-os-first-boot-setup`.

## Provision an existing machine

An Ubuntu **26.04** machine you already have can be converted without the ISO. From a checkout of the repository:

```bash
# core and hardware tiers by default; add "extended" for VS Code, Chromium, Homebrew and the Launcher
sudo ./backends/ubuntu/provision/provision.sh --tier=core,extended,hardware
# or the one-command version with the headless setup package and the desktop branding
sudo ./backends/ubuntu/provision/bootstrap-ci-os.sh --yes
```

`provision.sh` installs what `core/manifest/ecosystem.yaml` lists (Docker and Compose, Node.js through asdf, Ollama and its models, the GitHub CLI, the CI-Hub service when registry credentials and pairing exist, ROCm and LACT on supported AMD hardware). It is idempotent, and on any other Ubuntu release the ROCm step stops with an error and installs nothing.

## Connect a headless machine

When a machine has no connectivity it starts a hotspot `Companion-Setup-XXXX` (random suffix per boot). Join it from a phone, open `http://192.168.99.1`, choose your Wi-Fi network and submit. The portal has **no real authentication yet**; do this on a network you trust (KI-02). Details and the hotspot passphrase: [installation guide](installation-guide.md#connecting-a-headless-machine-the-setup-hotspot).

## If something goes wrong

| Symptom | First thing to try |
|---|---|
| Plasma install fails at about 2 percent with "failed to finish in 30 seconds" | Close and start **Install Companion OS** again (known defect KI-20 of ISO #5 and older: a 30 second default on the keyring step; fixed in `ad37b64`, and ISO #6 installed on its first attempt [V], in a virtual machine, once) |
| Plasma install: "The package signing keys ... could not be set up or verified" | Get online and retry; if it persists the ISO is too old, use a newer one |
| Ubuntu one-click: "No internal disk of at least 25 GB was found." | Use the normal installer, or a bigger internal disk |
| First-boot setup says "Network not available" | It retries by itself every 15 minutes; or `sudo ci-os-setup` once online |
| Disk full after the model pulls | Free space, then `sudo ci-os-setup` to resume (a disk under 64 GB is too small for the default models) |

More in the [installation guide](installation-guide.md#troubleshooting). Report problems at https://github.com/companionintelligence/CI-OS/issues with the ISO file name and sha256, the edition and the output of `cat /etc/os-release` and `sudo journalctl -b --no-pager | tail -200`.

© Companion Intelligence, Lifescope Inc
