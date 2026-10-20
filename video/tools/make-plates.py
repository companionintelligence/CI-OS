#!/usr/bin/env python3
"""Make the video's screenshot plates from a recorded run, and check them afterwards.

  python3 video/tools/make-plates.py --run <run dir>      write video/assets/shots/<id>.png and PROVENANCE.md
  python3 video/tools/make-plates.py --verify             check the committed plates against PROVENANCE.md

A run directory holds the screenshots and frames of one recording of the stick's first run (docs/guides/testing-in-qemu.md,
"Recording a first-run video"). tools/plates.json names, for each plate, the source file inside that directory and the
rectangles to cover. A rectangle is a redaction: the installer shows a one-time password on screen, so a plate that shows it
has the characters covered by a solid bar BEFORE the file is written, and --verify fails when a covered region is not a flat
bar any more. The bar is drawn on the pixels; nothing below it is kept.

The plates are committed (the video renders from them and a checkout cannot film again without a VM run). The recording that
made them is not (a run is a gigabyte of frames), so PROVENANCE.md carries the sha256 of every source and every plate.

Needs Pillow. pngquant is used when it is installed and reports the quality was kept (95 to 100); otherwise the PNG is lossless.

Exit status: 0 done / all good, 1 a plate or a check failed, 2 bad usage.

(c) Companion Intelligence, Lifescope Inc
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover - the message is the point
    sys.stderr.write("make-plates.py needs Pillow (python3 -m pip install pillow)\n")
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
VIDEO = os.path.dirname(HERE)
RECIPE = os.path.join(HERE, "plates.json")
SHOTS = os.path.join(VIDEO, "assets", "shots")
LEDGER = "PROVENANCE.md"
COVER = (31, 35, 41)          # the redaction bar
COVER_TOLERANCE = 10          # per channel, for the palette encoder
EDGE_INK = 225                # a grey level below this next to a cover edge is ink or its anti-aliasing (the dialogs are 250)
TABLE_HEAD = "| plate | source in the run | source sha256 | covered | plate sha256 | what it shows |"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_recipe(path=RECIPE):
    with open(path, "r", encoding="utf-8") as f:
        recipe = json.load(f)
    ids = [p["id"] for p in recipe["plates"]]
    dup = sorted(set(i for i in ids if ids.count(i) > 1))
    if dup:
        raise ValueError("plates.json repeats a plate id: " + ", ".join(dup))
    return recipe


def check_rect(rect, size, plate_id):
    if len(rect) != 4:
        raise ValueError("%s: a cover rectangle is [x0, y0, x1, y1], got %r" % (plate_id, rect))
    x0, y0, x1, y1 = rect
    if not (0 <= x0 < x1 <= size[0] and 0 <= y0 < y1 <= size[1]):
        raise ValueError("%s: cover rectangle %r is outside %dx%d or empty" % (plate_id, rect, size[0], size[1]))


def check_edges(im, rect, plate_id):
    """Refuse a cover rectangle whose left or right edge touches more text.

    A rectangle that stops short of the end of a word leaves its last characters on the plate (found by eye on the first
    run: the confirmation moves 33 px when its wording is wider, and the bar ended one character early). The two columns just
    outside each edge, across the rectangle's rows, must be the dialog's own background, not ink or its anti-aliasing.
    """
    x0, y0, x1, y1 = rect
    px = im.convert("L").load()
    for x in (x0 - 2, x0 - 1, x1, x1 + 1):
        if not 0 <= x < im.size[0]:
            continue
        for y in range(y0, y1):
            if px[x, y] < EDGE_INK:
                raise ValueError("%s: text reaches the edge of the cover rectangle %r (at x=%d, y=%d); widen it so that no character is left uncovered"
                                 % (plate_id, rect, x, y))


def draw_covers(im, rects, plate_id):
    d = ImageDraw.Draw(im)
    for rect in rects:
        check_rect(rect, im.size, plate_id)
        check_edges(im, rect, plate_id)
    for rect in rects:
        d.rounded_rectangle(rect, radius=5, fill=COVER)


def encode(im, dest, lossless):
    """Write im as a PNG; palette-quantised by pngquant when it keeps quality 95 to 100, else lossless. Returns the encoder."""
    fd, tmp = tempfile.mkstemp(suffix=".png")
    os.close(fd)
    try:
        im.save(tmp, optimize=True, compress_level=9)
        if not lossless and shutil.which("pngquant"):
            r = subprocess.run(["pngquant", "--quality=95-100", "--speed", "1", "--floyd=1", "--strip", "--force", "-o", dest, tmp],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if r.returncode == 0:
                return "pngquant 95-100"
        shutil.copyfile(tmp, dest)
        return "lossless"
    finally:
        os.unlink(tmp)


def make(run_dir, out_dir, lossless=False, recipe_path=RECIPE):
    recipe = load_recipe(recipe_path)
    size = tuple(recipe["size"])
    os.makedirs(out_dir, exist_ok=True)
    rows = []
    for plate in recipe["plates"]:
        src = os.path.join(run_dir, plate["source"])
        if not os.path.isfile(src):
            raise FileNotFoundError("%s: source %s is not in the run directory %s" % (plate["id"], plate["source"], run_dir))
        im = Image.open(src).convert("RGB")
        if im.size != size:
            raise ValueError("%s: %s is %dx%d, the recipe says %dx%d" % (plate["id"], plate["source"], im.size[0], im.size[1], size[0], size[1]))
        rects = plate.get("cover", [])
        draw_covers(im, rects, plate["id"])
        dest = os.path.join(out_dir, plate["id"] + ".png")
        encoder = encode(im, dest, lossless)
        rows.append({
            "id": plate["id"], "source": plate["source"], "source_sha": sha256_file(src), "cover": rects,
            "plate_sha": sha256_file(dest), "shows": plate["shows"], "encoder": encoder,
        })
        print("  %-18s %7d bytes  %s%s" % (plate["id"], os.path.getsize(dest), encoder, "  covered " + str(len(rects)) if rects else ""))
    write_ledger(out_dir, recipe, rows)
    return rows


def write_ledger(out_dir, recipe, rows):
    rec = recipe["recording"]
    lines = [
        "# Provenance of the screenshot plates",
        "",
        "> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**",
        "",
        "Written by `video/tools/make-plates.py` from `video/tools/plates.json`; `--verify` reads the table below. Do not edit by hand.",
        "",
        "Every plate is a frame of one recording of the first run in a virtual machine, not a mock-up. **[V]** for what the frames show; nothing",
        "here is a run on real hardware.",
        "",
        "| | |",
        "|---|---|",
        "| Taken | %s |" % rec["taken"],
        "| Image | `%s` |" % rec["image"],
        "| Image sha256 | `%s` |" % rec["image_sha256"],
        "| Machine | %s |" % rec["machine"],
        "| Choices made | %s |" % rec["choices"],
        "| Run record | `%s` |" % rec["evidence"],
        "| Plate size | %d x %d |" % tuple(recipe["size"]),
        "",
        "**Covered** is a redaction: the installer prints a one-time password for the throw-away VM account, and the rectangle is a solid bar",
        "drawn over those characters before the file was written. Rectangles are `[x0, y0, x1, y1]` in plate pixels.",
        "",
        TABLE_HEAD,
        "|---|---|---|---|---|---|",
    ]
    for r in rows:
        cov = "none" if not r["cover"] else "; ".join("`%s`" % json.dumps(c, separators=(",", ":")) for c in r["cover"])
        lines.append("| %s | `%s` | `%s` | %s | `%s` | %s |" % (r["id"], r["source"], r["source_sha"], cov, r["plate_sha"], r["shows"]))
    lines.append("")
    with open(os.path.join(out_dir, LEDGER), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def read_ledger(out_dir):
    path = os.path.join(out_dir, LEDGER)
    if not os.path.isfile(path):
        raise FileNotFoundError("%s is missing from %s" % (LEDGER, out_dir))
    rows = []
    in_table = False
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line == TABLE_HEAD:
                in_table = True
                continue
            if in_table and line.startswith("|---"):
                continue
            if in_table and line.startswith("| "):
                cells = [c.strip() for c in line.strip().strip("|").split(" | ")]
                if len(cells) < 6:
                    raise ValueError("a ledger row has %d cells, not 6: %s" % (len(cells), line))
                cover = []
                if cells[3] != "none":
                    for part in cells[3].split("; "):
                        cover.append(json.loads(part.strip("`")))
                rows.append({"id": cells[0], "cover": cover, "plate_sha": cells[4].strip("`")})
            elif in_table:
                break
    if not rows:
        raise ValueError("no plate rows were found under the table heading in %s" % LEDGER)
    return rows


def cover_is_flat(im, rect):
    x0, y0, x1, y1 = rect
    px = im.load()
    # sample the interior (the corners are rounded), every pixel of it
    for y in range(y0 + 3, y1 - 3):
        for x in range(x0 + 3, x1 - 3):
            if any(abs(a - b) > COVER_TOLERANCE for a, b in zip(px[x, y][:3], COVER)):
                return False
    return True


def verify(out_dir):
    problems = []
    rows = read_ledger(out_dir)
    listed = set(r["id"] for r in rows)
    on_disk = set(f[:-4] for f in os.listdir(out_dir) if f.endswith(".png"))
    for missing in sorted(listed - on_disk):
        problems.append("%s: listed in %s but %s.png is not in %s" % (missing, LEDGER, missing, out_dir))
    for extra in sorted(on_disk - listed):
        problems.append("%s: %s.png is not listed in %s (a plate with no recorded source)" % (extra, extra, LEDGER))
    for r in rows:
        path = os.path.join(out_dir, r["id"] + ".png")
        if not os.path.isfile(path):
            continue
        if sha256_file(path) != r["plate_sha"]:
            problems.append("%s: the file does not match the recorded sha256 (edited by hand, or made by another run)" % r["id"])
            continue
        if r["cover"]:
            im = Image.open(path).convert("RGB")
            for rect in r["cover"]:
                check_rect(rect, im.size, r["id"])
                if not cover_is_flat(im, rect):
                    problems.append("%s: the covered region %r is not a flat bar, so what it should hide may show" % (r["id"], rect))
    return problems


def main(argv):
    ap = argparse.ArgumentParser(description="Make the video's screenshot plates from a recorded run, and check them.")
    ap.add_argument("--run", help="the run directory (screenshots, and frames/ from record-frames.sh)")
    ap.add_argument("--out", default=SHOTS, help="where the plates go (default video/assets/shots)")
    ap.add_argument("--lossless", action="store_true", help="never palette-quantise")
    ap.add_argument("--verify", action="store_true", help="check the plates in --out against PROVENANCE.md and exit")
    args = ap.parse_args(argv)
    if args.verify == bool(args.run):
        ap.error("give exactly one of --run <dir> and --verify")
    try:
        if args.verify:
            problems = verify(args.out)
            for p in problems:
                print("FAIL  " + p)
            if problems:
                return 1
            print("ok: %d plates match %s, and every covered region is a flat bar" % (len(read_ledger(args.out)), LEDGER))
            return 0
        print("plates from %s:" % args.run)
        make(args.run, args.out, lossless=args.lossless)
        print("wrote %s/%s; check every covered plate by eye before it is committed" % (args.out, LEDGER))
        return 0
    except (OSError, ValueError, KeyError) as e:
        print("make-plates: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
