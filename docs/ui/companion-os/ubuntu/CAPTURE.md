# Companion OS, Ubuntu edition (arm64): screenshot capture record

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

**Evidence label for every frame: tested in a virtual machine.** Each frame is a screen capture (QMP `screendump`, 1280 by 800) of a QEMU machine on an
Apple-silicon Mac with the host's own accelerator (HVF), Homebrew's edk2 aarch64 firmware (no Secure Boot) and a file-backed 64 GiB virtual NVMe
disk. Nothing here ran on real hardware. The ten frames and their fields are in `MANIFEST.json`; the text records of the run are in
[`docs/evidence/2026-10-19-ubuntu-arm64-4b7597d/`](../../../evidence/2026-10-19-ubuntu-arm64-4b7597d/).

Run of 2026-10-19. The guest clock is UTC and the "Taken" times in `MANIFEST.json` are approximate UTC from the run log.

## Inputs

| Item | Value |
|---|---|
| ISO | `companion-os-1.0-arm64.iso`, 5,593,038,848 bytes, sha256 `c110e346c02ea5a58db318add1aa6df9063d9b72da831d090c490bf19f585ea6` (equal to the `SHA256SUMS` the build wrote) |
| Built from | commit `4b7597d` of `liam/companion-os-arm64`, a clean checkout, in a native arm64 container: 917 s |
| Verifier | `verify-iso.sh`: **438 passed, 0 failed** (`verify.log` in the evidence directory), including the two checks for the upgrade-welcome stamp |
| Harness | `backends/ubuntu/iso/tests/boot-arm64-vm.sh` and `backends/ubuntu/iso/tests/lib/qmp-drive.py`, both in this repository |
| Base ISO | `ubuntu-26.04.1-desktop-arm64.iso`, sha256 `c54d1964...2517`, equal to Canonical's signed `SHA256SUMS` |

## The run, with times

| Step | Time (UTC) | Result |
|---|---|---|
| Power on, ISO as a USB drive | 05:35:32 | GRUB menu in 12 s |
| Live desktop | about 2 min later | installer window first; closed at 05:38:02, desktop and five shortcuts with icons |
| One-click install confirmed | 05:38:30 | |
| Installer powered the machine off | 05:50:40 | **12 min 10 s** |
| Installed disk powered on | 05:50:49 | greeter within 50 s |
| First sign-in | 05:56:26 | forced new password; **no Canonical first-run page** |
| First-boot job | 05:54:01 to 05:55:59 | **1 min 58 s**, exit 0; two models; Hub healthy; 279 journal lines |

## What the frames show, and what they do not

* Frame 04 and 05 carry a one-time password in the original; both are redacted in the saved copies (a dark bar over the password line in 04, and
  the progress text re-drawn without it in 05). No other frame shows a credential. The new password of the throwaway VM was never typed on a
  visible field.
* Frame 10: the device ID is a random value of a machine that was never paired.
* Frame 08 shows two Firefox tabs. The second, "Firefox Privacy Notice", is Firefox's own first-run page and is not Companion's; see
  [KI-27](../../../architecture/known-issues-and-decisions.md). A "79 Updates Available" notice from Ubuntu's Software Updater appeared at the same moment
  (`docs/evidence/2026-10-19-ubuntu-arm64-4b7597d/frames/01-first-sign-in-with-software-updater-notice.png`); the image is built from the archive of the build day.
* Not shown: the amd64 image (its live desktop is not captured here), Secure Boot, any physical machine, a paired Hub.

## The first sign-in nearly went wrong, twice

1. The first image of this run (commit `c0059d6`) showed "Welcome to Companion OS 1.0!" with Ubuntu's raccoon at the first sign-in: the upgrade-login
   service of gnome-initial-setup, which the skel stamp did not cover. The records are in
   [`docs/evidence/2026-10-19-ubuntu-arm64-c0059d6-first-run/`](../../../evidence/2026-10-19-ubuntu-arm64-c0059d6-first-run/); the fix is commit `6aa27f6`, and this run is
   of the image built from it.
2. In this run, five sign-in attempts failed silently because the one-time password had been read from the screenshot by OCR and one character was wrong
   (`c` read as `e`). The password is a random string the dialog shows once; compare an OCR result with the picture before using it.

## Safety

File-backed images only; no host block device; the throwaway passwords stayed in a 0600 file in the session's scratch directory and are not in any frame or log
of this directory.
