#!/usr/bin/env bash
#=============================================================================
# Render the Companion OS stick film (landscape and square) from the committed plates and narration, on this machine.
#
#   ./video/render.sh                 verify the plates, build, check, render landscape and square into video/out/
#   ./video/render.sh --check-only    the same without the render (about half a minute)
#   ./video/render.sh --narrate       first record the missing lines and re-record the ones whose text changed (needs the network), then as above
#   ./video/render.sh --copy-out      after the render, copy the files to ~/Movies/CI-Product-Videos/companion-os-usb/
#
# There is no video/make.sh and no video/stage.sh on purpose. The org's runner (make.sh) stands an app up and films it with Playwright;
# this film is of an operating system installing in a virtual machine, so there is nothing to stand up and nothing to drive. Its plates
# are frames of a recorded run (video/tools/make-plates.py, docs/guides/testing-in-qemu.md "Recording a first-run video"), committed,
# and this script only renders them. It finds the kit the way the org's make.sh shim does (CI_WORKSPACE, else a CI-Common clone above this
# repository) and refuses a kit that is behind origin or has local changes, unless CI_VIDEO_ALLOW_STALE_KIT=1.
#
# One workaround, to be removed when the kit has the fix: `ci-video check` fails a shot with no portrait plate (<id>.mobile.png) even when
# no portrait cut is built, and this film builds only landscape and square, which read the desktop plates. So the missing-plate gate is done
# here, for the plates the film uses, and `check --allow-slates` is run for the rest. A missing desktop plate still stops the run.
#
# Needs: Node 22 or newer, ffmpeg and ffprobe, python3 with Pillow, network the first time (hyperframes is fetched by npx and cached).
# Output: video/out/companion-os-usb-landscape.mp4, ...-square.mp4 and companion-os-usb.vtt. Videos are build output and are never committed.
#
# Exit status: 0 done, 1 a gate or a step failed, 2 bad usage or a missing tool.
#
# © Companion Intelligence, Lifescope Inc
#=============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
VIDEO_DIR="$PWD"
SELF="$VIDEO_DIR/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd .. && pwd)"
APP_ID="companion-os-usb"

RENDER=1
NARRATE=0
COPY_OUT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) RENDER=0; shift ;;
    --narrate)    NARRATE=1; shift ;;
    --copy-out)   COPY_OUT=1; shift ;;
    -h|--help)    sed -n '2,/^# Exit status/p' "$SELF" | sed -e '/^#=\{10,\}$/d' -e 's/^# \{0,1\}//' ; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31m x %s\033[0m\n' "$*" >&2; exit 1; }

for tool in node python3; do command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }; done
if [ "$RENDER" = 1 ]; then
  for tool in ffmpeg ffprobe; do command -v "$tool" >/dev/null || { echo "missing tool: $tool (brew install ffmpeg)" >&2; exit 2; }; done
fi

# --- the kit ---------------------------------------------------------------------------------------------------------------------------
KIT_REL="CI-Common/packages/video-kit"
KIT_DIR=""
if [ -n "${CI_WORKSPACE:-}" ]; then
  KIT_DIR="$CI_WORKSPACE/$KIT_REL"
else
  d="$REPO_ROOT"
  while [ "$d" != "/" ]; do
    if [ -d "$d/$KIT_REL" ]; then KIT_DIR="$d/$KIT_REL"; break; fi
    d="$(dirname "$d")"
  done
fi
[ -n "$KIT_DIR" ] && [ -d "$KIT_DIR" ] || die "video-kit not found (looked for */$KIT_REL above $REPO_ROOT).
     Clone CI-Common into the workspace, or set CI_WORKSPACE to the directory that holds it."
if [ -f "$KIT_DIR/dist/ci-video.js" ]; then
  KIT_BIN="$KIT_DIR/dist/ci-video.js"; KIT_FLAGS=""
else
  KIT_BIN="$KIT_DIR/bin/ci-video.ts"; KIT_FLAGS="--experimental-strip-types --disable-warning=ExperimentalWarning"
fi
[ -f "$KIT_BIN" ] || die "the kit at $KIT_DIR has no CLI (neither dist/ci-video.js nor bin/ci-video.ts)"
# shellcheck disable=SC2086  # KIT_FLAGS is a deliberate word split
kit() { local sub="$1"; shift; node $KIT_FLAGS "$KIT_BIN" "$sub" --project "$VIDEO_DIR" "$@"; }

KIT_REPO="${KIT_DIR%/packages/video-kit}"
KIT_VERSION="$(node -p "require('$KIT_DIR/package.json').version" 2>/dev/null || echo unknown)"
kit_git() { git -C "$KIT_REPO" "$@" 2>/dev/null; }
NOTES=""; STALE=0
if kit_git rev-parse --git-dir >/dev/null; then
  kit_git fetch --quiet origin || warn "could not fetch CI-Common: the comparison below may itself be stale"
  DEFAULT="$(kit_git symbolic-ref --short refs/remotes/origin/HEAD | sed 's|^origin/||' || true)"; [ -n "$DEFAULT" ] || DEFAULT=main
  BRANCH="$(kit_git symbolic-ref --short HEAD || true)"
  if [ -n "$BRANCH" ]; then NOTES="on $BRANCH"; else NOTES="detached at $(kit_git rev-parse --short HEAD || echo unknown)"; fi
  [ "$BRANCH" = "$DEFAULT" ] || NOTES="$NOTES, not $DEFAULT"
  BEHIND="$(kit_git rev-list --count "HEAD..origin/$DEFAULT" -- packages/video-kit || echo 0)"
  if [ "${BEHIND:-0}" -gt 0 ]; then NOTES="$NOTES, $BEHIND commit(s) behind origin/$DEFAULT under packages/video-kit"; STALE=1; fi
  if [ -n "$(kit_git status --porcelain -- packages/video-kit)" ]; then NOTES="$NOTES, uncommitted changes under packages/video-kit"; STALE=1; fi
else
  NOTES="not a git checkout, provenance unknown"; STALE=1
fi
LABEL="video-kit $KIT_VERSION, CI-Common working tree: $NOTES"
if [ "$STALE" = 0 ]; then
  printf '\033[0;2mkit:\033[0m \033[0;32m%s\033[0m\n' "$LABEL"
elif [ "${CI_VIDEO_ALLOW_STALE_KIT:-0}" = 1 ]; then
  warn "kit: $LABEL"; warn "proceeding anyway (CI_VIDEO_ALLOW_STALE_KIT=1): do not publish a cut from this run"
else
  die "kit: $LABEL

     A film made with a kit that is not what origin ships looks fine and is not. Do NOT switch branches in a shared CI-Common clone;
     make a worktree and point this script at it:

       git -C $KIT_REPO worktree add /tmp/ci-common-kit origin/$DEFAULT
       CI_WORKSPACE=/tmp/ci-common-kit ./video/render.sh

     or, to test a kit branch on purpose: CI_VIDEO_ALLOW_STALE_KIT=1 ./video/render.sh"
fi

# --- the plates and the narration ------------------------------------------------------------------------------------------------------
say "checking the plates (sha256 against PROVENANCE.md, every covered region a flat bar)"
python3 tools/make-plates.py --verify || die "the plates do not match their provenance: re-make them from the recording, never edit one by hand"

say "checking that every shot has its plate and every narrated scene its recording"
python3 - <<'PY' || die "a plate or a recording is missing (see above)"
import json, os, sys
sb = json.load(open("storyboard.json"))
bad = []
for scene in sb["scenes"]:
    for shot in scene.get("shots", []):
        p = "assets/shots/%s.png" % shot["id"]
        if not os.path.isfile(p) or os.path.getsize(p) == 0:
            bad.append("no plate: " + p)
    if scene.get("narration") and not scene.get("coda"):
        a = "assets/audio/%s.mp3" % scene["id"]
        if not os.path.isfile(a) or os.path.getsize(a) == 0:
            bad.append("no recording: %s (run ./video/render.sh --narrate)" % a)
for b in bad:
    print("  x " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY

if [ "$NARRATE" = 1 ]; then
  say "recording the scenes that have no recording, then re-recording the lines that changed (edge-tts, needs the network)"
  kit narrate          # records a scene with no mp3; keeps every mp3 that exists
  kit narrate --stale  # re-records exactly the scenes whose text no longer matches the mp3 (never --force: it moves every duration)
fi

# --- build, check, render --------------------------------------------------------------------------------------------------------------
say "building the compositions"
kit build

say "checking the compositions (hyperframes lint, layout, contrast; every pointer must land)"
# --allow-slates: see the note at the top. The plates the film uses were checked above.
kit check --allow-slates

if [ "$RENDER" = 0 ]; then
  say "check only: nothing rendered"
  exit 0
fi

say "rendering landscape and square (slow: several minutes)"
kit render --format all

say "what was made"
for f in "out/$APP_ID-landscape.mp4" "out/$APP_ID-square.mp4"; do
  [ -f "$f" ] || die "$f was not written"
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate:format=duration,size -of default=nw=1 "$f" | tr '\n' ' '
  printf '  %s\n' "$f"
done
[ -f "out/$APP_ID.vtt" ] && echo "  out/$APP_ID.vtt (captions sidecar)"

if [ "$COPY_OUT" = 1 ]; then
  dest="$HOME/Movies/CI-Product-Videos/$APP_ID"
  mkdir -p "$dest"
  cp "out/$APP_ID-landscape.mp4" "out/$APP_ID-square.mp4" "$dest/"
  [ -f "out/$APP_ID.vtt" ] && cp "out/$APP_ID.vtt" "$dest/"
  echo "  copied to $dest"
fi
echo
echo "Look at the film before you send it: ffmpeg -i out/$APP_ID-landscape.mp4 -vf \"fps=1/3,scale=400:-1,tile=5x6\" -frames:v 1 -y /tmp/sheet.png"
