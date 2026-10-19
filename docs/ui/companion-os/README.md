# Companion OS screenshots: index of editions

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

This directory holds the screen captures of Companion OS editions running in a virtual machine, one subdirectory per edition, each with the capture record of the run that made them. The six `setup-portal-*.png` files one level up (`docs/ui/`) are a different set: renders of the headless setup portal, used by the front-page README.

## Editions

| Edition | Directory | Run | Frames | Evidence label |
|---|---|---|---|---|
| Plasma (based on CachyOS) | [`plasma/`](plasma/CAPTURE.md) | ISO #6, 2026-10-18, built from the clean commit `ad37b64`, sha256 `5ab1fe2c...2d20` | 29 files (26 distinct pictures): the live medium, the installer pages, the installed system | Tested in a virtual machine |
| Ubuntu 26.04.1 (arm64 image) | [`ubuntu/`](ubuntu/CAPTURE.md) | 2026-10-19, built from `4b7597d`, sha256 `c110e346...5ea6`, QEMU with HVF | 10 files: boot menu, live desktop, the one-click dialog and progress, the installed greeter, the forced password change, the first sign-in, the installed desktop, Hub's pairing screen | Tested in a virtual machine; the amd64 image has no frames here (its live session is recorded in `docs/evidence/2026-10-19-ubuntu-amd64-4b7597d/frames/`) |

Every frame in this directory is a screen capture of a **QEMU virtual machine** (the Plasma frames: software emulation, TCG; the Ubuntu arm64 frames: hardware acceleration, HVF; both on an Apple-silicon Mac, UEFI firmware with Secure Boot off). **None comes from real hardware.** The label for the frames, in the vocabulary of the public documentation (release-status labels), is **Tested in a virtual machine**; in this repository the evidence tags are **[V]**, **[I]** and **[N]** (see [test evidence](../../architecture/test-evidence.md)).

## What is in an edition directory

| File | What it is |
|---|---|
| `NN-<slug>.png` | the frames, numbered in capture order (`NN` two digits), lossless PNG, no metadata chunks. The slug is the one of the [table of figure names](../../architecture/test-evidence.md#figures) without the edition prefix |
| `CAPTURE.md` | the run: image name and sha256, build commit, the QEMU and OVMF command lines and settings, timings, the table of frames (file, what it shows, stage, time taken), what was fixed, what was found, what the frames do not show, and the hygiene checks |
| `MANIFEST.json` | the fields of each frame: alt text, caption, what it shows, stage, time taken, notes and caveats, which placeholder asked for it |

The text records of the same run (build record, verifier log, job timeline, command lines) are in [`docs/evidence/`](../../evidence/README.md), in the directory named in `CAPTURE.md`.

## Rules for adding frames

1. **Say what the frame is.** A frame of a virtual machine says so in its caption; the virtual hardware lines of About this System and of a terminal stay visible. A frame never stands for a surface it does not show: a note in the manifest says what it cannot prove (for example, that the welcome page shows no requirements list).
2. **No credentials, no host identity.** No password, token or key, no host path (a home folder, a scratch directory), no host user or host name, no personal name, no address. The throwaway account of a capture is named as such and its password is typed from a file that is not in this repository, never revealed on screen. A frame is **not retouched**: if it shows something that must not be published, it is not exported (the first-boot unit status of the Plasma run carries two 32-digit systemd identifiers and is not in the set).
3. **Scan before you commit.** Search the raw bytes of every PNG for the password, its pieces and the host literals; OCR every distinct picture (enlarged, plain and inverted, two page-segmentation modes) and search the text for the same literals, for runs of 24 or more hex digits, addresses and e-mail addresses; then look at each picture. The method and the result for the Plasma set are in its `CAPTURE.md`.
4. **Record the run.** ISO file name and sha256, the build record, the QEMU command lines with paths replaced by `<scratch>` or `<home>`, host load, the date, the timings, and the findings, in a `CAPTURE.md` beside the frames; the text records go to `docs/evidence/`.
5. **Link it.** A document that shows a frame uses a real image with a relative path and alt text (the alt text is in `MANIFEST.json`). A frame that does not exist yet stays a commented-out placeholder in the scheme `docs/ui/companion-os/<edition>/NN-<slug>.png`, with `NN` written literally.
6. **Keep the size down.** Frames of a 1280x800 desktop are about 0.4 to 1.4 MB as lossless PNG; the Plasma set is about 16 MB, counting the three pictures that are stored under two names (git keeps one copy of each).

## Related pages

* [Test evidence, Figures](../../architecture/test-evidence.md#figures): the one table of figure names and where each is used.
* [Evidence records](../../evidence/README.md): the text records behind the verified rows.
* [Testing in QEMU](../../guides/testing-in-qemu.md): how a run that produces such frames is made.
