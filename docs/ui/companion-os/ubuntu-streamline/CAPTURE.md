# Streamlined setup of the Ubuntu edition: screenshot capture record

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

**Evidence label for every frame: tested in a virtual machine.** Each frame is a screen capture (QMP `screendump`, 1280 by 800) of a QEMU 11.1.2 machine on an Apple-silicon
Mac with the host's own accelerator (HVF), Homebrew's edk2 aarch64 firmware (no Secure Boot) and a file-backed 64 GiB virtual NVMe disk. **Nothing here ran on real hardware, and each
image was run once.** The change these frames belong to is KI-30 in [`known-issues-and-decisions.md`](../../../architecture/known-issues-and-decisions.md); the text records of the
runs (times, every action, facts read from the guests, the verifier logs, the image checksums) are in
[`docs/evidence/2026-10-19-ubuntu-arm64-streamline/`](../../../evidence/2026-10-19-ubuntu-arm64-streamline/run.txt) and, for frames 14 to 17 (the follow-up that takes Canonical's launcher off the live desktop),
[`docs/evidence/2026-10-19-ubuntu-arm64-0ea3ee8-hide-launcher/`](../../../evidence/2026-10-19-ubuntu-arm64-0ea3ee8-hide-launcher/run.txt).

Run of 2026-10-19 (local time; the "taken" times in the manifest are UTC of 2026-10-20 and are the time the screendump was asked for or the recorded frame's own time).

## Inputs

| Image | Built from | sha256 | `verify-iso.sh` | Used for |
|---|---|---|---|---|
| `companion-os-1.0-arm64.iso` | `main` at `5d50582` | `0cc31d9ce18040dac743d664cc15f04af7d8b18b2b2fad5f48ee506ac7e25110` | 446 passed, 0 failed | the "before" side of `compare-before-after.png` (frames of the teardown set, `docs/ui/ftue-teardown/companion-os-before/`) |
| `companion-os-1.0-arm64.iso` | this branch at `cf68024` | `ee5f850d2e51a6651da5915954ad46442d0eec3f4c2e4dd5eb2263d0e65a76e9` | 492 passed, 0 failed | frame 01 (the defect) |
| `companion-os-1.0-arm64.iso` | this branch at `5ff5224` | `217c11444e4bc1d8502e689c0aad622d2d21389590936f4daf76b7128a983f07` | 493 passed, 0 failed | frames 02 to 13 |
| `companion-os-1.0-arm64.iso` | the follow-up at `0ea3ee8` | `3936d54d087d8d0725f1907e9789ca27bbe560298f716898edc30ce8977dadbc` | 493 passed, 0 failed | frames 14 to 17 (booted, not installed) |

All four were built from a clean tree (`git archive HEAD`) in a native arm64 `ubuntu:26.04` container and checked with `verify-iso.sh` (`VERIFY_BASE_ISO` and `VERIFY_REQUIRE_CANON=1`).

| Item | Value |
|---|---|
| Harness | `backends/ubuntu/iso/tests/boot-arm64-vm.sh`, `lib/qmp-drive.py` and `record-frames.sh` (1.5 s between screendumps, about 3 s in practice), unchanged |
| Machine | `-machine virt,gic-version=3 -accel hvf -cpu host -smp 6 -m 8192`, `virtio-gpu-pci`, `qemu-xhci` with `usb-kbd` and `usb-tablet`, `virtio-rng`, user networking |
| Media | the ISO as a USB drive on `bootindex=0`, the boot menu's automatic entry chosen with Down, Enter (frames 14 to 16 are from it; frame 17 is from the default entry, Try or Install Companion OS, with Enter); the install target a blank NVMe disk (qcow2) on the SSD; after the install the VM was started again without the ISO (frames 14 to 17: the disk was not installed to) |
| Account | the account the installer makes (`companion`), a one-time password read from the screen by eye (never by OCR) and typed from a 0600 file kept outside the repository, then a throwaway new password of the same kind |

## What the frames show

The manifest lists each frame with its alt text, what it shows, its image, its stage and its time. In short: the live session of the image without the fix and of the image with
it (the dialog, the dock, the icons, and the plain boot entry's desktop), Canonical's installer window opened from the dialog's button, the install in progress, the installed system's greeter, the forced password
change, the first session and the first-boot notifications, and Settings > Appearance. Frames 14 to 17 (the follow-up, `0ea3ee8`) show the live desktop with Canonical's launcher taken off, the application grid with both installers, Canonical's installer opened from the dialog's button once more, and the
plain entry's desktop. Three composites are in the set: `compare-live-session.png` (the defect and the fix, and the stock installer), `compare-before-after.png` (`main` next to this branch: the greeter and the first
session) and `compare-live-desktop-launcher.png` (frames 03 and 14: two installer icons, then one).

## Redactions and hygiene

* **Three frames are not as captured**: the one-click dialog and the progress window show the one-time password, so a dark bar with the words "hidden in this capture" was drawn over
  that text after the capture (frames 01, 02 and 05), the same redaction as frames 04, 05 and 14 of the existing Ubuntu set (`docs/ui/companion-os/ubuntu/CAPTURE.md`). The manifest
  says so. No other frame was changed. **Frames 14 to 17 are as captured**: none shows the dialog or the progress window (the dialog, opened a second time for the test of its button, showed a one-time password and no frame of it is kept).
* **No password.** The throwaway password and the one-time passwords were searched for, whole and in halves, in the bytes of every PNG and in every text record of the runs: 0 hits.
  The password fields show dots.
* **No host identity.** Every frame was read by OCR four ways (plain and negated, two page-segmentation modes, enlarged) and searched for the host user name, the owner's name and e-mail,
  host paths, IP addresses, hex strings of 24 or more digits and the host's region: 0 hits.
* The frames of the discarded first attempt of the last run (it started without a target disk, by mistake) are kept where they show the live session: frame 03 is from it.

## What the frames do not show

A second run of any image; amd64; real hardware; the installed system after the first-boot job (its settled state is in the text records); a GTK 3 window other than Firefox's; the
application grid beyond the search for Install; the installed system of the follow-up image (it was not installed); Software Properties; the first attempt of the last run's install (there was none).
