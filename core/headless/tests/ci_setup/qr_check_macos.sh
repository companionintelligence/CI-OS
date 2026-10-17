#!/usr/bin/env bash
# Opt-in check of ci_setup.qr against the operating system's own QR detector (CoreImage), macOS only.
#
#   CI_SETUP_MACOS_QR=1 core/headless/tests/ci_setup/qr_check_macos.sh
#
# The unit tests decode every symbol with a second implementation written for them; that proves the encoder and the decoder
# agree, not that a phone will read the code. This script renders PNG images of many symbols (every version 1 to 10 at every
# error-correction level, every mask pattern, the Wi-Fi codes of the setup access point, UTF-8 and escaped text), has CoreImage's
# detector read them, and requires each decoded text to equal the encoded one.
#
# Needs: macOS, swiftc (Xcode command line tools), python3. Writes only to a temporary directory. Exit status: 0 every image was
# read back correctly, 1 one was not, 2 cannot run here (not macOS, no swiftc, or CI_SETUP_MACOS_QR not set).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADLESS="$(cd "$HERE/../.." && pwd)"

if [ "${CI_SETUP_MACOS_QR:-0}" != 1 ]; then
  echo "skipped: set CI_SETUP_MACOS_QR=1 to run the CoreImage check" >&2
  exit 2
fi
if [ "$(uname -s)" != Darwin ] || ! command -v swiftc >/dev/null 2>&1; then
  echo "cannot run: needs macOS with swiftc" >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci-setup-qr.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/img"

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$HEADLESS" python3 - "$TMP/img" <<'PY'
import json, struct, sys, zlib
from ci_setup import qr, wifi_qr

out = sys.argv[1]

def png(modules, quiet=4, scale=8):
    n = len(modules) + 2 * quiet
    rows = []
    for r in range(n):
        line = bytearray()
        for c in range(n):
            rr, cc = r - quiet, c - quiet
            dark = 0 <= rr < len(modules) and 0 <= cc < len(modules) and modules[rr][cc]
            line.extend([0 if dark else 255] * scale)
        rows.extend([b"\x00" + bytes(line)] * scale)
    raw = b"".join(rows)
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    side = n * scale
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

cases = []
ap = wifi_qr.wifi_payload("Companion-Setup-AB12", "ABCDEFGHJKMN")
cases.append(("ap_key", ap, "M", None))
cases.append(("ap_key_L", ap, "L", None))
cases.append(("ap_key_H", ap, "H", None))
cases.append(("escaped", wifi_qr.wifi_payload('foo;bar\\baz:x,"y"', "p@ss;w\\rd:1,2"), "M", None))
cases.append(("utf8", wifi_qr.wifi_payload("Caf\U000000e9 \U0001f600", "12345678"), "M", None))
cases.append(("hexlike", wifi_qr.wifi_payload("ABCD", "deadBEEF"), "M", None))
for mask in range(8):
    cases.append(("mask%d_v3M" % mask, "mask test: the quick brown fox 0123456789", "M", mask))
    cases.append(("mask%d_v7Q" % mask, "x" * 80 + " mask %d" % mask, "Q", mask))
for version in range(1, 11):
    for ecl in "LMQH":
        n = qr.capacity_bytes(version, ecl)
        text = ("v%d%s " % (version, ecl) + "".join(chr(33 + (i * 7) % 90) for i in range(n)))[:n]
        cases.append(("v%02d%s_full" % (version, ecl), text, ecl, None))
        cases.append(("v%02d%s_half" % (version, ecl), text[: max(1, n // 2)], ecl, None))
expected = {}
for name, text, ecl, mask in cases:
    code = qr.encode(text, ecl, mask=mask)
    fname = "%s.png" % name
    with open("%s/%s" % (out, fname), "wb") as fh:
        fh.write(png(code.modules))
    expected[fname] = text
with open(out + "/expected.json", "w") as fh:
    json.dump(expected, fh)
print("rendered %d images" % len(expected))
PY

swiftc -O -o "$TMP/qr_detect" "$HERE/qr_detect.swift" 2>"$TMP/swiftc.log" || { echo "cannot run: swiftc failed"; cat "$TMP/swiftc.log"; exit 2; }
"$TMP/qr_detect" "$TMP/img" > "$TMP/detected.tsv"

python3 - "$TMP/img/expected.json" "$TMP/detected.tsv" <<'PY'
import json, sys
expected = json.load(open(sys.argv[1]))
seen, bad = {}, 0
for line in open(sys.argv[2], encoding="utf-8"):
    name, status, text = (line.rstrip("\n").split("\t") + ["", ""])[:3]
    seen[name] = (status, text.replace("\\n", "\n"))
for name, want in sorted(expected.items()):
    status, got = seen.get(name, ("MISSING", ""))
    ok = status == "OK" and got == want
    if not ok:
        bad += 1
        print("FAIL %-22s %s %r" % (name, status, got[:60]))
print("== qr (CoreImage): %d of %d images read back correctly" % (len(expected) - bad, len(expected)))
sys.exit(1 if bad else 0)
PY
