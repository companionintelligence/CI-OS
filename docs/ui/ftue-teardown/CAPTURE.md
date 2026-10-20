# First-run teardown: screenshot capture record

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

**Evidence label for every frame: tested in a virtual machine.** Each frame is a screen capture (QMP `screendump`, 1280 by 800) of a QEMU 11.1.2 machine on an
Apple-silicon Mac with the host's own accelerator (HVF), Homebrew's edk2 aarch64 firmware (no Secure Boot) and a file-backed 64 GiB virtual NVMe disk. **Nothing here ran on
real hardware, and each distro was run once.** The page these frames belong to is [`docs/architecture/ftue-teardown.md`](../../architecture/ftue-teardown.md); the text
records (times, every action, facts read from the guests, the signature checks) are in [`docs/evidence/2026-10-19-ftue-teardown/`](../../evidence/2026-10-19-ftue-teardown/).

Run of 2026-10-19 (local time; the "taken" times in the manifests are UTC of 2026-10-20 and are the time the screendump was asked for).

## Inputs

| Set | Image | Size | sha256 | Checked against |
|---|---|---|---|---|
| `ubuntu-stock/` | `ubuntu-26.04.1-desktop-arm64.iso`, Canonical's stock image | 4,154,798,080 bytes | `c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517` | Canonical's signed `SHA256SUMS`, key `843938DF...2092` |
| `fedora/` | `Fedora-Workstation-Live-44-1.7.aarch64.iso` | 2,689,781,760 bytes | `162ba3c552a2d241c7c63ec26777af0255ee1b5a135adc0be986ceed999933ef` | Fedora's signed `CHECKSUM`, key `36F612DC...90A6` (Fedora 44) |
| `debian/` | `debian-13.7.0-arm64-netinst.iso` | 735,358,976 bytes | `6e93fa1759bd9d4b0fc11e938987de6967ee7de5297dac1be27c3a75cc17024b` | Debian's signed `SHA256SUMS`, key `DF9B9C49...BE9B` (Debian CD signing key) |

The two downloads were made with the owner's approval; the Ubuntu image was already in the repository's test cache. The commands and results of the signature checks are in
`verify-downloads.txt` in the evidence directory.

| Item | Value |
|---|---|
| Harness | `backends/ubuntu/iso/tests/boot-arm64-vm.sh`, `lib/qmp-drive.py` and `record-frames.sh` (1.5 s between screendumps, about 3 s in practice), unchanged |
| Machine | `-machine virt,gic-version=3 -accel hvf -cpu host -smp 6 -m 8192`, `virtio-gpu-pci`, `qemu-xhci` with `usb-kbd` and `usb-tablet`, `virtio-rng`, user networking |
| Media | the ISO as a USB drive on `bootindex=0`; the install target a blank NVMe disk (qcow2) on a RAM disk; after the install the VM was started again without the ISO |
| Host load at the start | Ubuntu 10.4 and 6.7 (two attempts), Fedora 24.4, Debian 23.4 (one-minute averages; other sessions were using the machine) |
| Account | a throwaway name ("FTUE Tester") and a random 20 character password typed from a 0600 file kept outside the repository |

## What the frames show

The three manifests list each frame with its alt text, what it shows, its stage (boot menu, live boot, live desktop, installer, install, first start) and its time. In short:
the boot menu and first screens of each distro, the installer pages that differ most (the first page, the account or root password page, the time zone page where it is asked, the
review), the progress and the "done" page, the first screen of the installed system, and what the first sign-in opens by itself.

## Hygiene

* **No password.** The throwaway password was searched for, whole and in two halves, in the bytes of every PNG and in every text record of the run: 0 hits. The password fields
  show dots; no "show password" control was pressed.
* **No host identity.** Every frame was read by OCR and searched for the host user name, the owner's name and e-mail, host paths, IP addresses, hex strings of 24 or more digits
  and the host's region: 0 hits. The two frames that pre-select the host's region on a map (Ubuntu's time zone page and Fedora's time zone page) are **not** in the set. The
  installer pages show the date of the run and the throwaway account name and, on Ubuntu, the computer name derived from it.
* **Not retouched.** No frame was edited. The comparison figures are composites made from the frames (reduced, captioned) and say so.

## What the frames do not show

A second run of any distro; the Companion OS install (its frames are in [`../companion-os/ubuntu/`](../companion-os/ubuntu/CAPTURE.md)); openSUSE; amd64; Secure Boot; any real
hardware; the first attempt of the stock Ubuntu live boot, which froze on a text boot log and was not counted (see the evidence record); the frames of the installed systems'
terminals, which ran a read-only facts script.
