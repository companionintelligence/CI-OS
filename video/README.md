# Companion OS stick film

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

The first run of a Companion OS install from the stick, as a film: the stick, the boot menu, the one-click question, the language
choice, the install, the first sign-in, the setup notices and Companion Hub's pairing page. **86 seconds in 13 scenes** (12 narrated and a
silent closing card), in two formats: **landscape** (1920 x 1080) and **square** (1080 x 1080), with a captions file.

It is made with the org's video system, not with a one-off script: the storyboard grammar, camera, narration, loudness and render come from
[`CI-Common/packages/video-kit`](https://github.com/companionintelligence/CI-Common/tree/main/packages/video-kit) (`AUTHORING.md` and
`MESSAGING.md` there govern the craft and the words), and the film belongs to the pipeline described in CI-Engineering
`projects/product-video-pipeline/`. The internal cut of the same run (`backends/ubuntu/iso/tests/lib/make-video.py`, a real-time time-lapse
with click rings) is a different thing: see [`docs/guides/testing-in-qemu.md`](../docs/guides/testing-in-qemu.md#recording-a-first-run-video).

## What is true about it

| | |
|---|---|
| Evidence label | **[V]** for what the frames show: a recorded run of the arm64 image of commit `82e9335`, in a virtual machine (QEMU 11, HVF, Apple-silicon Mac). **Not real hardware.** No run on a real computer is recorded. |
| The closing card | "How this was filmed" says so on screen (a virtual machine, arm64, real hardware: not yet). Delete that scene only after a real-hardware run is recorded and the film is re-shot from it. |
| What is hidden | The installer prints a one-time password for the throw-away VM account. Three plates carry a solid bar over it, drawn on the pixels before the file was written (below). The caption of the last card says so. |
| What it does not show | amd64, a first boot on a slow network, any model answering, the Hub paired with an account, the banner "needs attention", a language other than English (United Kingdom). The install time is not claimed anywhere (this run's was 16 min 33 s on a loaded host, the German one 11 min 38 s on a quiet one). |
| The pictures of the stick | Brand-canon cutouts from CI-Common, unedited ([`assets/brand-photos/PROVENANCE.md`](assets/brand-photos/PROVENANCE.md)). They show what the stick looks like, not the one in the recording. |
| The run record | [`docs/evidence/2026-10-19-ubuntu-arm64-82e9335-video-run/`](../docs/evidence/2026-10-19-ubuntu-arm64-82e9335-video-run/run.txt) |

## The scenes

| Scene | Seconds | On screen | Words (house voice, en-GB-SoniaNeural) |
|---|---|---|---|
| `open` | 8.0 | the mark, "Companion OS" | Companion OS turns a computer you own into a private AI server. It arrives on a USB stick. |
| `the-stick` | 5.6 | two images of the stick, cap on and cap off | The stick holds the installer. Plug it in, and start the computer from it. |
| `boot-menu` | 6.0 | the boot menu, "Install Companion OS (automatic)" | Choose the automatic entry. The computer starts a live desktop from the stick. |
| `one-question` | 7.5 | the one-click dialog, password hidden, a click on "Language, keyboard, time zone..." | One window asks one question. It names the disk it will erase, and gives a one-time password for your first sign-in. |
| `your-language` | 8.4 | the three dialogs of the language choice, two clicks | If a default is wrong, one button changes the language, the keyboard and the time zone. Here, English, United Kingdom. |
| `confirm` | 7.0 | the dialog naming the choice, a click on "Erase the disk and install" | The window now names the choice. One click on erase the disk and install, and it asks nothing more. |
| `installing` | 8.3 | the progress window, password hidden | Then it installs by itself. When it finishes, the computer turns off. Take out the stick, and turn it on. |
| `sign-in` | 6.9 | the sign-in screen (a click on the user), the forced password change | Sign in as companion with the one-time password. The first sign-in asks you to choose your own. |
| `desktop` | 4.7 | the first desktop, the getting started page open | Then the desktop, with the getting started page already open. |
| `setup` | 11.0 | three notices: getting ready, step 5 of 7, ready | A few minutes after the first start, setup runs in the background. It says what it is doing, step by step, and you can keep working. Then it says it is ready. |
| `hub` | 6.4 | the desktop (a click on the first dock icon), Companion Hub's pairing page | Open Companion Hub, the first icon in the dock. It starts at its pairing page. |
| `close` | 4.0 | "UnCloud your life." and ci.computer | Companion Intelligence. Apps you own. |
| `how-this-was-filmed` | 7.0 | the disclosure card, silent | none |

The words follow `MESSAGING.md`: product names (Companion Hub, not CI-Hub), no exclamation marks, no number that the recording does not
support, the closing line is the fleet's.

## Render it

```bash
./video/render.sh                 # verify the plates, build, check, render landscape and square into video/out/ (about 3 minutes)
./video/render.sh --check-only    # the same without the render (about half a minute)
./video/render.sh --narrate       # first record the missing lines and re-record the ones whose text changed (needs the network), then as above
./video/render.sh --copy-out      # then copy the files to ~/Movies/CI-Product-Videos/companion-os-usb/ with the org's other films
```

Needs Node 22 or newer, ffmpeg with ffprobe, python3 with Pillow, and a CI-Common clone above this repository (or `CI_WORKSPACE`
pointing at one). `render.sh` announces which kit answered and **refuses** a kit that is behind origin or has local changes, because
a film made with the wrong kit looks fine and is not (CI-Common keeps its own account of the day six films were re-rendered with a stale
kit and came out byte-identical). In a shared CI-Common clone, never switch branches: make a worktree and point `CI_WORKSPACE` at it. The
output is `out/companion-os-usb-landscape.mp4`, `out/companion-os-usb-square.mp4` and `out/companion-os-usb.vtt`; the render masters the
sound to -14 LUFS and refuses a master that misses it. **Videos are build output and are never committed.**

There is no `make.sh` and no `stage.sh` on purpose. The org's runner stands an app up and films it with Playwright; this film is of an
operating system installing in a virtual machine, so there is nothing to stand up and nothing to drive. The pictures are committed.

## Where the pictures come from

`assets/shots/` holds 15 plates, each a frame of one recording of the run (1920 x 1080, taken from the VM's screen buffer, no
mouse pointer, no mock-up). `tools/plates.json` names each plate's source frame in the recording and the rectangles to cover;
`tools/make-plates.py` makes the plates and writes [`assets/shots/PROVENANCE.md`](assets/shots/PROVENANCE.md) (the sha256 of every source frame
and every plate). The recording itself is not in the repository: it is about a gigabyte of frames and they show the one-time password.

**The redaction is the point of the tool.** `make-plates.py` draws the bar on the pixels, refuses a rectangle whose edge touches more text (the
first run found by eye that the dialog moves 33 px when its wording is wider, and a bar that was one character short), and `--verify` fails when a
covered region is not a flat bar. Even so, **look at every covered plate at 2x before it is committed** (`installing`, `one-click-dialog`,
`confirm-uk`): an OCR scan proves nothing here, because `tesseract` does not read that bold monospace text at this size.

`python3 video/tools/test_make_plates.py` (part of `core/lib/check-repo.sh`) checks the tool on synthetic frames and checks the committed
plates against their ledger, so a hand-edited plate fails the gate.

### To shoot it again

A new film needs a new recording; the steps are those of [the QEMU guide](../docs/guides/testing-in-qemu.md#recording-a-first-run-video),
at the film's size and with these differences:

1. Start the VM at 1920 x 1080: `CI_VM_RES=1920x1080` in front of `backends/ubuntu/iso/tests/boot-arm64-vm.sh` (the harness gives the guest that
   size and the clicks of `qmp-drive.py` take `1920x1080` as the screen size).
2. Record frames from before power-on (`record-frames.sh DIR 1.5`), drive the run at a human pace and log the clicks (`QMP_CLICK_LOG`).
   Keep the guest awake with a mouse move every couple of minutes.
3. Note the epoch of the frames you want (GRUB with the automatic entry highlighted, the three notices) and the click coordinates
   (`clicks.txt`: the pointer fractions in `storyboard.json` are `x / 1920`, `y / 1080`).
4. Edit `tools/plates.json` (sources, covers) and run `python3 video/tools/make-plates.py --run <run dir>`. Measure a password's pixels with
   a scan before you trust a rectangle (the plate maker prints nothing about what is under the bar: you do).
5. Look at the covered plates at 2x, then `./video/render.sh`, then the contact sheet below, then commit the plates and the ledger.

## Editing the film

- **Words.** Edit `scenes[].narration` or `caption` in `storyboard.json`, then `./video/render.sh --narrate`: it records a scene that has no recording and
  re-records exactly the scenes whose text moved (`ci-video narrate`, then `ci-video narrate --stale`). Never `narrate --force`: edge-tts is not byte-deterministic, so it rewrites every recording, and under
  `meta.pacing: "fit"` the durations move and re-time the whole film. Commit `assets/audio/narration.json` with the mp3s.
- **Pictures.** A new or changed plate means `plates.json`, `make-plates.py`, and its entry in the storyboard's shots; `focus` rectangles are
  fractions of the 1920 x 1080 plate, and `ci-video focus-preview --scene <id>` shows the end frame of a camera move without a render (it is a
  reconstruction: render before you believe the framing).
- **Pointers.** A `pointer` is a point on the plate (`x / 1920`, `y / 1080`), and it must be something the recording really did: the clicks in
  `clicks.txt` are the only ones in the film. `check` refuses a pointer that does not land.
- **Length.** `meta.pacing: "fit"` sizes each scene from its narration; do not set `seconds` to fight it.

## Looking at it before it goes anywhere

```bash
ffmpeg -i video/out/companion-os-usb-landscape.mp4 -vf "fps=1/3,scale=480:-1,tile=5x6" -frames:v 1 -y /tmp/sheet.png      # the whole film as one picture
ffmpeg -nostats -i video/out/companion-os-usb-landscape.mp4 -af silencedetect=n=-45dB:d=0.8 -f null -                      # dead air
ffmpeg -nostats -i video/out/companion-os-usb-landscape.mp4 -vf freezedetect=n=-60dB:d=1.5 -an -f null -                  # frozen picture
```

The last cut had no silence and one frozen span of 2.5 s (the closing card), and a loudness of -14 LUFS at -2.5 dBTP. A caption on a device frame,
a cursor that teleports and three scenes that look the same show in the contact sheet and in no metric.

## What the kit made difficult

| | |
|---|---|
| The missing-plate gate counts the portrait plate | `ci-video check` fails a shot that has no `<id>.mobile.png` even when no portrait cut is built. This film builds landscape and square, which read the desktop plates, so `render.sh` does that gate itself for the plates the film uses and runs `check --allow-slates` for the rest. Remove the workaround when the kit counts only the plates of the formats it builds. |
| The plates are 1080p | The kit assumes captures of 3840 x 2160. At the camera's tightest framing a 1920 x 1080 plate is enlarged about 1.9 times, which softens small text. It stays readable (dialog text is about 24 px at that point); a recording at 3840 x 2160 with the guest at 200 percent scaling would be sharper and is the upgrade. |
| No portrait cut | The plates are 16:9 frames of a virtual machine's screen. In the kit's 9:16 cut they would sit in a phone frame, which claims a phone interface that does not exist. |
| Masters are large | The landscape master is about 100 MB and the square about 64 MB at the kit's high quality. Make a smaller file for sending, for example `ffmpeg -i in.mp4 -c:v libx264 -crf 24 -preset slow -c:a copy small.mp4`. |

## Files

| Path | What |
|---|---|
| `storyboard.json` | the script, the camera and the pointers: the one source of truth |
| `assets/shots/*.png`, `PROVENANCE.md` | the 15 plates and where each came from |
| `assets/brand-photos/` | the two cutouts of the stick, and where they came from |
| `assets/audio/*.mp3`, `narration.json` | the recorded lines and the record of which text each one reads |
| `tools/make-plates.py`, `plates.json`, `test_make_plates.py` | the plate maker, its recipe, its tests |
| `render.sh` | verify, build, check, render |
| `build/`, `out/` | build output; ignored, never committed |
