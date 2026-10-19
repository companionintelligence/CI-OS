#!/usr/bin/env python3
"""Frames of a VM run -> one captioned, redacted, time-compressed mp4 (a first-run video).

  make-video.py OUT.mp4 --frames DIR [--frames DIR ...] --chapters chapters.txt [--redact redact.txt] [--clicks clicks.txt]
                [--title TEXT] [--outro TEXT] [--clock] [--from T] [--until T] [--fps 5] [--hold 0.4]

The frames are f-<epoch>.png from record-frames.sh (a QMP screendump every second or two). Nothing here talks to the VM. Needs Pillow and
ffmpeg. Coordinates in the files are those of a 1280 x 800 screen and are scaled to the frames' size.

  chapters.txt  one per line:  <epoch or ISO time UTC> | caption      a caption lasts until the next chapter; '-' clears it; # starts a comment
  redact.txt    one per line:  <start> <end> <x> <y> <w> <h> [bright <x> <y> <w> <h>]
                a box painted over those pixels in frames of that time window. With `bright`, only when that other region of the
                frame is light (mean luminance above 200): "the dialog is on screen", so a console or a login screen is left alone
  clicks.txt    what qmp-drive.py writes with QMP_CLICK_LOG: "<epoch> <x> <y> <w> <h>" (the click's position on a w x h screen); a ring
                is drawn there for about a second, because a screendump has no pointer

A frame that looks like the one before it is dropped, so a wait (an install, a download) costs a moment, and every change on screen costs
--hold seconds of video. --clock shows the real time that has passed since the first frame, so a sped-up wait is not mistaken for a fast
one. Frames can show a one-time password: redact them (this tool paints boxes; it does not look for the password) and look at the result.
"""
import argparse
import datetime
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageStat

REF_W, REF_H = 1280, 800
FONTS = ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc",
         "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf")
CLICK_SECONDS = 1.2


def font(px):
    for p in FONTS:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, px)
            except OSError:
                continue
    try:
        return ImageFont.load_default(size=px)
    except TypeError:                       # Pillow before 10.1 has one size
        return ImageFont.load_default()


def when(text):
    """'1792449387' or '2026-10-19T22:36:21Z' -> epoch seconds."""
    text = text.strip()
    if re.fullmatch(r"\d{9,}", text):
        return int(text)
    return int(datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp())


def lines_of(path):
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.strip() and not line.lstrip().startswith("#"):
                yield line.rstrip("\n")


def parse_chapters(path):
    out = []
    for line in lines_of(path):
        t, cap = line.split("|", 1)
        out.append((when(t), "" if cap.strip() == "-" else cap.strip()))
    return sorted(out)


def parse_redactions(path):
    out = []
    for line in (lines_of(path) if path else ()):
        f = line.split()
        cond = tuple(int(v) for v in f[7:11]) if len(f) >= 11 and f[6] == "bright" else None
        out.append((when(f[0]), when(f[1]), int(f[2]), int(f[3]), int(f[4]), int(f[5]), cond))
    return out


def parse_clicks(path):
    out = []
    for line in (lines_of(path) if path else ()):
        t, x, y, w, h = (int(v) for v in line.split())
        out.append((t, x, y, w, h))
    return out


def caption_for(chapters, t):
    cap = ""
    for ct, text in chapters:
        if ct <= t:
            cap = text
    return cap


def annotate(img, t, t0, caption, redactions, clicks, clock):
    """A copy of `img` (a frame taken at epoch t) with its redaction boxes, click rings, caption and clock."""
    img = img.convert("RGB")
    w, h = img.size
    sx, sy = w / REF_W, h / REF_H
    d = ImageDraw.Draw(img, "RGBA")
    for a, b, x, y, bw, bh, cond in redactions:
        if not a <= t <= b:
            continue
        if cond is not None:
            cx, cy, cw, ch = cond
            region = img.crop((int(cx * sx), int(cy * sy), int((cx + cw) * sx), int((cy + ch) * sy))).convert("L")
            if ImageStat.Stat(region).mean[0] <= 200:
                continue
        box = [int(x * sx), int(y * sy), int((x + bw) * sx), int((y + bh) * sy)]
        d.rectangle(box, fill=(20, 24, 28, 255))
        d.text((box[0] + 4, box[1] + 2), "hidden", fill=(160, 170, 180, 255), font=font(max(8, int(12 * sy))))
    for ct, x, y, cw, chh in clicks:
        age = t - ct
        if 0 <= age <= CLICK_SECONDS:
            px, py = x * w / cw, y * h / chh
            r = (14 + 22 * age / CLICK_SECONDS) * sx
            alpha = int(255 * (1 - age / CLICK_SECONDS))
            d.ellipse([px - r, py - r, px + r, py + r], outline=(255, 214, 10, alpha), width=max(2, int(5 * sx)))
    if caption:
        f = font(max(10, int(26 * sy)))
        bx = d.textbbox((0, 0), caption, font=f)
        tw, th = bx[2] - bx[0], bx[3] - bx[1]
        x0, y0 = (w - tw) // 2, h - th - int(46 * sy)
        pad = int(12 * sy)
        d.rounded_rectangle([x0 - 2 * pad, y0 - pad, x0 + tw + 2 * pad, y0 + th + pad + 4], radius=int(14 * sy), fill=(8, 12, 16, 210))
        d.text((x0, y0), caption, fill=(255, 255, 255, 255), font=f)
    if clock:
        secs = max(0, int(t - t0))
        label = "real time %d:%02d" % (secs // 60, secs % 60)
        f = font(max(9, int(16 * sy)))
        bx = d.textbbox((0, 0), label, font=f)
        d.rounded_rectangle([int(10 * sx), int(40 * sy), int(10 * sx) + bx[2] + 16, int(40 * sy) + bx[3] + 12], radius=8, fill=(8, 12, 16, 190))
        d.text((int(10 * sx) + 8, int(40 * sy) + 4), label, fill=(210, 220, 230, 255), font=f)
    return img


def card(size, text):
    """A title or end card: the text centred on a dark picture, in the largest size (up to a fourteenth of the height) that fits in 90% of the width."""
    img = Image.new("RGB", size, (4, 24, 31))
    d = ImageDraw.Draw(img)
    px = max(14, size[1] // 14)
    while px > 10:
        f = font(px)
        bx = d.textbbox((0, 0), text, font=f)
        if bx[2] - bx[0] <= size[0] * 0.9:
            break
        px -= 2
    d.text(((size[0] - (bx[2] - bx[0])) // 2 - bx[0], (size[1] - (bx[3] - bx[1])) // 2 - bx[1]), text, fill=(240, 250, 250), font=f)
    return img


def list_frames(dirs, start=None, until=None):
    out = []
    for d in dirs:
        for p in glob.glob(os.path.join(d, "f-*.png")):
            m = re.search(r"f-(\d+)\.png$", p)
            if m:
                t = int(m.group(1))
                if (start is None or t >= start) and (until is None or t <= until):
                    out.append((t, p))
    return sorted(out)


def is_repeat(prev_small, small, threshold):
    return prev_small is not None and sum(ImageStat.Stat(ImageChops.difference(prev_small, small)).mean) / 3 < threshold


def render(files, outdir, chapters, redactions, clicks, fps=5, hold=0.4, threshold=0.4, max_repeat=30, clock=False, title=None, outro=None):
    """Write the kept, annotated frames to outdir as 000000.png...; return how many. A frame is repeated round(hold * fps) times."""
    per = max(1, round(hold * fps))
    n, prev, prev_t, t0, last_size = 0, None, 0, files[0][0] if files else 0, None

    def put(img, times=1):
        nonlocal n
        for _ in range(times):
            img.save(os.path.join(outdir, "%06d.png" % n))
            n += 1
    for t, p in files:
        try:
            img = Image.open(p).convert("RGB")
        except OSError:
            continue                                         # a frame cut off by the end of the run
        if title and last_size is None:
            put(card(img.size, title), max(1, round(2.5 * fps)))
        last_size = img.size
        small = img.resize((160, 100))
        if is_repeat(prev, small, threshold) and t - prev_t < max_repeat and not any(0 <= t - ct <= CLICK_SECONDS for ct, *_ in clicks):
            continue
        prev, prev_t = small, t
        put(annotate(img, t, t0, caption_for(chapters, t), redactions, clicks, clock), per)
    if outro and last_size:
        put(card(last_size, outro), max(1, round(2.5 * fps)))
    return n


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("out")
    ap.add_argument("--frames", action="append", required=True)
    ap.add_argument("--chapters", required=True)
    ap.add_argument("--redact")
    ap.add_argument("--clicks")
    ap.add_argument("--title")
    ap.add_argument("--outro")
    ap.add_argument("--clock", action="store_true")
    ap.add_argument("--from", dest="start")
    ap.add_argument("--until")
    ap.add_argument("--fps", type=float, default=5)
    ap.add_argument("--hold", type=float, default=0.4, help="seconds of video per kept frame")
    ap.add_argument("--threshold", type=float, default=0.4, help="mean per-channel difference below which a frame is a repeat")
    ap.add_argument("--max-repeat", type=int, default=30, help="keep a frame anyway after this many seconds without a change")
    a = ap.parse_args(argv)
    if not shutil.which("ffmpeg"):
        print("make-video: cannot run here: ffmpeg is missing", file=sys.stderr)
        return 2
    files = list_frames(a.frames, when(a.start) if a.start else None, when(a.until) if a.until else None)
    if not files:
        sys.exit("make-video: no frames f-<epoch>.png in " + ", ".join(a.frames))
    tmp = tempfile.mkdtemp(prefix="ftue-video-")
    try:
        kept = render(files, tmp, parse_chapters(a.chapters), parse_redactions(a.redact), parse_clicks(a.clicks), a.fps, a.hold,
                      a.threshold, a.max_repeat, a.clock, a.title, a.outro)
        if not kept:
            sys.exit("make-video: every frame was unreadable")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(a.fps), "-i", os.path.join(tmp, "%06d.png"),
                        "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart", a.out], check=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("%s: %d source frames, %d video frames, %.1f s" % (a.out, len(files), kept, kept / a.fps))
    return 0


if __name__ == "__main__":
    sys.exit(main())
