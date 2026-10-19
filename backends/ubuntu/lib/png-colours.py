#!/usr/bin/env python3
"""Inspect the pixels of the logo PNGs that core/render/render-mark-png.sh writes.

verify-iso.sh and 80-validate-ci-theme.sh use it to check that the Settings > About logos and the
greeter logo really are the canon mark in the canon colours, which the PNG header and the file size
cannot tell: a plain red square of the right width passes those. Standard library only, so it runs on
a stock Ubuntu or the verify container. Reads 8-bit RGB or RGBA PNGs without interlacing (what
render-mark-png.sh produces) and says so when it meets anything else.

  png-colours.py info FILE
      width, height, pixel counts and the opaque colours (alpha 255) with their counts
  png-colours.py solid FILE RRGGBB
      every opaque pixel is exactly RRGGBB (the one-colour mark), and the mark covers a sensible
      part of the image (so an empty or fully transparent render fails)
  png-colours.py palette FILE RRGGBB[,RRGGBB...]
      every opaque pixel is one of the listed colours and each of them occurs (the colour mark)
  png-colours.py iou FILE REFERENCE
      intersection over union of the two alpha >= 128 masks, printed as a number (same size required)

Exit status: 0 when the check holds, 1 when it does not, 2 when a file cannot be read. The first line
printed says why, in words fit for a verify-iso.sh line.
"""
import struct
import sys
import zlib

# The mark is a ring of segments: neither almost empty nor almost solid. Anything outside this is not it.
MIN_COVER = 0.08
MAX_COVER = 0.50


def read_png(path):
    """(width, height, channels, rows) with rows as bytearrays of unfiltered scanlines."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, ihdr = 8, [], None
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
    if ihdr is None or not idat:
        raise ValueError("truncated PNG")
    width, height, depth, colour, _compression, _filter, interlace = ihdr
    if depth != 8 or colour not in (2, 6) or interlace != 0:
        raise ValueError("unsupported PNG (need 8-bit RGB/RGBA without interlacing; got depth %d, colour type %d, interlace %d)"
                         % (depth, colour, interlace))
    bpp = 4 if colour == 6 else 3
    raw = zlib.decompress(b"".join(idat))
    stride = width * bpp
    if len(raw) < height * (stride + 1):
        raise ValueError("truncated PNG data")
    rows, prev, pos = [], bytearray(stride), 0
    for _ in range(height):
        ftype = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if ftype == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif ftype == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif ftype == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 255
        elif ftype != 0:
            raise ValueError("bad PNG filter type %d" % ftype)
        rows.append(line)
        prev = line
    return width, height, bpp, rows


def opaque_colours(width, height, bpp, rows):
    """({'rrggbb': count} for alpha 255 pixels, number of partly transparent pixels)."""
    colours, partial = {}, 0
    for line in rows:
        for x in range(width):
            o = x * bpp
            if bpp == 4:
                alpha = line[o + 3]
                if alpha == 0:
                    continue
                if alpha != 255:
                    partial += 1
                    continue
            key = "%02x%02x%02x" % (line[o], line[o + 1], line[o + 2])
            colours[key] = colours.get(key, 0) + 1
    return colours, partial


def mask(width, height, bpp, rows):
    if bpp != 4:
        return [[True] * width for _ in range(height)]
    return [[line[x * 4 + 3] >= 128 for x in range(width)] for line in rows]


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd, path = argv[1], argv[2]
    try:
        width, height, bpp, rows = read_png(path)
    except (OSError, ValueError, zlib.error) as err:
        print("%s: cannot read: %s" % (path, err))
        return 2
    total = width * height

    if cmd == "info":
        colours, partial = opaque_colours(width, height, bpp, rows)
        print("width %d" % width)
        print("height %d" % height)
        print("pixels %d" % total)
        print("opaque %d" % sum(colours.values()))
        print("partial %d" % partial)
        for key, count in sorted(colours.items(), key=lambda kv: -kv[1]):
            print("colour %s %d" % (key, count))
        return 0

    if cmd in ("solid", "palette"):
        if len(argv) != 4:
            print(__doc__)
            return 2
        want = [c.lower().lstrip("#") for c in argv[3].split(",") if c]
        colours, _partial = opaque_colours(width, height, bpp, rows)
        opaque = sum(colours.values())
        cover = float(opaque) / total
        got = sorted(colours.items(), key=lambda kv: -kv[1])
        got_text = ", ".join("#%s x%d" % kv for kv in got[:4]) or "none"
        if not (MIN_COVER <= cover <= MAX_COVER):
            print("opaque pixels cover %.1f%% of the image (the mark covers %d-%d%%); colours: %s"
                  % (cover * 100, MIN_COVER * 100, MAX_COVER * 100, got_text))
            return 1
        if cmd == "solid":
            if list(colours) != want[:1] or len(want) != 1:
                print("opaque colours are %s, want only #%s" % (got_text, want[0] if want else "?"))
                return 1
            print("every opaque pixel is #%s, the mark covers %.1f%% of the %dx%d image" % (want[0], cover * 100, width, height))
            return 0
        extra = [k for k in colours if k not in want]
        missing = [k for k in want if k not in colours]
        if extra or missing:
            print("opaque colours are %s; want exactly #%s%s" % (
                got_text, ", #".join(want), ("; missing #" + ", #".join(missing)) if missing else ""))
            return 1
        print("opaque pixels use exactly the mark's colours (%s), covering %.1f%% of the %dx%d image"
              % (", ".join("#" + k for k in want), cover * 100, width, height))
        return 0

    if cmd == "iou":
        if len(argv) != 4:
            print(__doc__)
            return 2
        try:
            w2, h2, b2, rows2 = read_png(argv[3])
        except (OSError, ValueError, zlib.error) as err:
            print("%s: cannot read: %s" % (argv[3], err))
            return 2
        if (w2, h2) != (width, height):
            print("size differs: %dx%d against %dx%d" % (width, height, w2, h2))
            return 1
        a, b = mask(width, height, bpp, rows), mask(w2, h2, b2, rows2)
        inter = union = 0
        for ra, rb in zip(a, b):
            for pa, pb in zip(ra, rb):
                if pa and pb:
                    inter += 1
                if pa or pb:
                    union += 1
        print("%.4f" % (float(inter) / union if union else 0.0))
        return 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
