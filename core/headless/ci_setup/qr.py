"""A small QR code encoder: byte mode, versions 1 to 10 (up to 271 bytes at level L), error correction levels L, M, Q and H.

It exists so that the console of a headless machine can show the Wi-Fi join code (see :mod:`ci_setup.wifi_qr`) on systems
where the ``qrencode`` program is not installed. The Wi-Fi string of the setup access point is about 50 bytes, which is version
3 or 4. Text longer than the capacity raises ``ValueError`` and the caller shows the SSID and key as text instead.

How it is checked (tests/ci_setup/test_qr.py and qr_check_macos.sh): the Reed-Solomon generator and the format and version words
against the values in ISO/IEC 18004; a second, independently written decoder in the tests (format word, unmasking, module order,
de-interleaving, Reed-Solomon syndromes, byte-mode parsing) for every version, level and mask; and, on a Mac, the operating
system's own QR detector (CoreImage) on rendered images. Pure standard library, no side effects.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple, Union

ECC_LEVELS = ("L", "M", "Q", "H")
_FORMAT_BITS = {"L": 1, "M": 0, "Q": 3, "H": 2}
MAX_VERSION = 10

# version -> level -> (error-correction codewords per block, [(blocks, data codewords per block), ...])   ISO/IEC 18004 table 9
_BLOCKS = {
    1: {"L": (7, [(1, 19)]), "M": (10, [(1, 16)]), "Q": (13, [(1, 13)]), "H": (17, [(1, 9)])},
    2: {"L": (10, [(1, 34)]), "M": (16, [(1, 28)]), "Q": (22, [(1, 22)]), "H": (28, [(1, 16)])},
    3: {"L": (15, [(1, 55)]), "M": (26, [(1, 44)]), "Q": (18, [(2, 17)]), "H": (22, [(2, 13)])},
    4: {"L": (20, [(1, 80)]), "M": (18, [(2, 32)]), "Q": (26, [(2, 24)]), "H": (16, [(4, 9)])},
    5: {"L": (26, [(1, 108)]), "M": (24, [(2, 43)]), "Q": (18, [(2, 15), (2, 16)]), "H": (22, [(2, 11), (2, 12)])},
    6: {"L": (18, [(2, 68)]), "M": (16, [(4, 27)]), "Q": (24, [(4, 19)]), "H": (28, [(4, 15)])},
    7: {"L": (20, [(2, 78)]), "M": (18, [(4, 31)]), "Q": (18, [(2, 14), (4, 15)]), "H": (26, [(4, 13), (1, 14)])},
    8: {"L": (24, [(2, 97)]), "M": (22, [(2, 38), (2, 39)]), "Q": (22, [(4, 18), (2, 19)]), "H": (26, [(4, 14), (2, 15)])},
    9: {"L": (30, [(2, 116)]), "M": (22, [(3, 36), (2, 37)]), "Q": (20, [(4, 16), (4, 17)]), "H": (24, [(4, 12), (4, 13)])},
    10: {"L": (18, [(2, 68), (2, 69)]), "M": (26, [(4, 43), (1, 44)]), "Q": (24, [(6, 19), (2, 20)]), "H": (28, [(6, 15), (2, 16)])},
}
TOTAL_CODEWORDS = {1: 26, 2: 44, 3: 70, 4: 100, 5: 134, 6: 172, 7: 196, 8: 242, 9: 292, 10: 346}
_ALIGNMENT = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34], 7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46],
              10: [6, 28, 50]}


def data_codewords(version: int, ecl: str) -> int:
    return sum(n * d for n, d in _BLOCKS[version][ecl][1])


def capacity_bytes(version: int, ecl: str) -> int:
    """How many bytes of text fit (byte mode: 4 bits mode, 8 or 16 bits count)."""
    header = 12 if version <= 9 else 20
    return (data_codewords(version, ecl) * 8 - header) // 8


# ---------------------------------------------------------------------------------------------------- GF(256) and Reed-Solomon
_EXP = [0] * 512
_LOG = [0] * 256
_x = 1
for _i in range(255):
    _EXP[_i] = _x
    _LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]


def _gmul(a: int, b: int) -> int:
    return 0 if a == 0 or b == 0 else _EXP[_LOG[a] + _LOG[b]]


def rs_generator(degree: int) -> List[int]:
    """Coefficients (highest power first, leading 1) of the product of (x - 2^i) for i < degree over GF(256)."""
    poly = [1]
    for i in range(degree):
        nxt = [0] * (len(poly) + 1)
        for j, c in enumerate(poly):
            nxt[j] ^= c
            nxt[j + 1] ^= _gmul(c, _EXP[i])
        poly = nxt
    return poly


def rs_remainder(data: Sequence[int], degree: int) -> List[int]:
    """The ``degree`` error-correction codewords of ``data``."""
    gen = rs_generator(degree)
    rem = [0] * degree
    for byte in data:
        factor = byte ^ rem[0]
        rem = rem[1:] + [0]
        if factor:
            for i in range(degree):
                rem[i] ^= _gmul(gen[i + 1], factor)
    return rem


# ---------------------------------------------------------------------------------------------------- format and version words
def format_word(ecl: str, mask: int) -> int:
    """The 15-bit format information: 5 data bits, 10 BCH bits (generator 0x537), XOR 0x5412."""
    data = (_FORMAT_BITS[ecl] << 3) | mask
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    return ((data << 10) | rem) ^ 0x5412


def version_word(version: int) -> int:
    """The 18-bit version information (versions 7 and up): 6 data bits, 12 BCH bits (generator 0x1F25)."""
    rem = version
    for _ in range(12):
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
    return (version << 12) | rem


# ---------------------------------------------------------------------------------------------------- the symbol
@dataclass(frozen=True)
class QrCode:
    version: int
    ecl: str
    mask: int
    modules: Tuple[Tuple[bool, ...], ...]       # modules[row][col], True is dark

    @property
    def size(self) -> int:
        return len(self.modules)


def _bits(data: Sequence[int]) -> List[int]:
    return [(b >> (7 - i)) & 1 for b in data for i in range(8)]


def _encode_data(payload: bytes, version: int, ecl: str) -> List[int]:
    cap_bits = data_codewords(version, ecl) * 8
    bits = [0, 1, 0, 0]
    count_bits = 8 if version <= 9 else 16
    bits += [(len(payload) >> (count_bits - 1 - i)) & 1 for i in range(count_bits)]
    bits += _bits(payload)
    bits += [0] * min(4, cap_bits - len(bits))
    bits += [0] * (-len(bits) % 8)
    words = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = (0xEC, 0x11)
    i = 0
    while len(words) < cap_bits // 8:
        words.append(pad[i % 2])
        i += 1
    return words


def _interleave(words: List[int], version: int, ecl: str) -> List[int]:
    ec_len, groups = _BLOCKS[version][ecl]
    blocks, pos = [], 0
    for count, size in groups:
        for _ in range(count):
            blocks.append(words[pos:pos + size])
            pos += size
    ecs = [rs_remainder(b, ec_len) for b in blocks]
    out = []  # type: List[int]
    for i in range(max(len(b) for b in blocks)):
        for b in blocks:
            if i < len(b):
                out.append(b[i])
    for i in range(ec_len):
        for e in ecs:
            out.append(e[i])
    return out


class _Grid:
    def __init__(self, version: int) -> None:
        self.size = 17 + 4 * version
        self.version = version
        self.dark = [[False] * self.size for _ in range(self.size)]
        self.func = [[False] * self.size for _ in range(self.size)]

    def set(self, row: int, col: int, dark: bool) -> None:
        self.dark[row][col] = dark
        self.func[row][col] = True

    def finder(self, row: int, col: int) -> None:           # centre of the 7x7 pattern
        for dr in range(-4, 5):
            for dc in range(-4, 5):
                r, c = row + dr, col + dc
                if 0 <= r < self.size and 0 <= c < self.size:
                    dist = max(abs(dr), abs(dc))
                    self.set(r, c, dist not in (2, 4))

    def alignment(self, row: int, col: int) -> None:
        for dr in range(-2, 3):
            for dc in range(-2, 3):
                self.set(row + dr, col + dc, max(abs(dr), abs(dc)) != 1)


def _build_function_patterns(version: int) -> _Grid:
    g = _Grid(version)
    n = g.size
    for i in range(n):                                       # timing patterns
        g.set(6, i, i % 2 == 0)
        g.set(i, 6, i % 2 == 0)
    g.finder(3, 3)
    g.finder(3, n - 4)
    g.finder(n - 4, 3)
    pos = _ALIGNMENT[version]
    for i, r in enumerate(pos):
        for j, c in enumerate(pos):
            if (i == 0 and j == 0) or (i == 0 and j == len(pos) - 1) or (i == len(pos) - 1 and j == 0):
                continue
            g.alignment(r, c)
    _draw_format(g, "L", 0)                                  # reserve the area; the real word is drawn after masking
    if version >= 7:
        word = version_word(version)
        for i in range(18):
            bit = (word >> i) & 1 == 1
            a, b = n - 11 + i % 3, i // 3
            g.set(b, a, bit)
            g.set(a, b, bit)
    return g


def _draw_format(g: _Grid, ecl: str, mask: int) -> None:
    word = format_word(ecl, mask)
    n = g.size

    def bit(i: int) -> bool:
        return (word >> i) & 1 == 1

    for i in range(6):
        g.set(i, 8, bit(i))                                  # first copy, down the column next to the left finder
    g.set(7, 8, bit(6))
    g.set(8, 8, bit(7))
    g.set(8, 7, bit(8))
    for i in range(9, 15):
        g.set(8, 14 - i, bit(i))
    for i in range(8):                                       # second copy
        g.set(8, n - 1 - i, bit(i))
    for i in range(8, 15):
        g.set(n - 15 + i, 8, bit(i))
    g.set(n - 8, 8, True)                                    # the always-dark module


def _mask_bit(mask: int, row: int, col: int) -> bool:
    if mask == 0:
        return (row + col) % 2 == 0
    if mask == 1:
        return row % 2 == 0
    if mask == 2:
        return col % 3 == 0
    if mask == 3:
        return (row + col) % 3 == 0
    if mask == 4:
        return (row // 2 + col // 3) % 2 == 0
    if mask == 5:
        return (row * col) % 2 + (row * col) % 3 == 0
    if mask == 6:
        return ((row * col) % 2 + (row * col) % 3) % 2 == 0
    if mask == 7:
        return ((row + col) % 2 + (row * col) % 3) % 2 == 0
    raise ValueError("mask must be 0 to 7")


def _place(g: _Grid, codewords: List[int]) -> None:
    bits = _bits(codewords)
    i, n = 0, g.size
    right = n - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(n):
            for j in range(2):
                col = right - j
                upward = ((right + 1) & 2) == 0
                row = n - 1 - vert if upward else vert
                if not g.func[row][col] and i < len(bits):
                    g.dark[row][col] = bits[i] == 1
                    i += 1
        right -= 2


def _penalty(dark: List[List[bool]]) -> int:
    n = len(dark)
    score = 0
    for lines in (dark, [list(col) for col in zip(*dark)]):
        for line in lines:
            run = 1
            for k in range(1, n):
                if line[k] == line[k - 1]:
                    run += 1
                else:
                    if run >= 5:
                        score += 3 + run - 5
                    run = 1
            if run >= 5:
                score += 3 + run - 5
            text = "".join("1" if v else "0" for v in line)
            for pat in ("10111010000", "00001011101"):
                start = 0
                while True:
                    at = text.find(pat, start)
                    if at < 0:
                        break
                    score += 40
                    start = at + 1
    for r in range(n - 1):
        for c in range(n - 1):
            if dark[r][c] == dark[r][c + 1] == dark[r + 1][c] == dark[r + 1][c + 1]:
                score += 3
    total = n * n
    ones = sum(sum(row) for row in dark)
    k = (abs(ones * 20 - total * 10) + total - 1) // total - 1
    return score + max(k, 0) * 10


def encode(data: Union[str, bytes], ecl: str = "M", min_version: int = 1, max_version: int = MAX_VERSION,
           mask: Optional[int] = None) -> QrCode:
    """The smallest symbol (versions ``min_version``..``max_version``) that holds ``data`` at level ``ecl``. Text is encoded as
    UTF-8. ``mask`` forces a mask pattern (for tests); by default the one with the lowest penalty is used. Raises ValueError when
    the data does not fit."""
    if ecl not in ECC_LEVELS:
        raise ValueError("error correction level must be L, M, Q or H")
    payload = data.encode("utf-8") if isinstance(data, str) else bytes(data)
    if not 1 <= min_version <= max_version <= MAX_VERSION:
        raise ValueError("version range must lie within 1..%d" % MAX_VERSION)
    for version in range(min_version, max_version + 1):
        if len(payload) <= capacity_bytes(version, ecl):
            break
    else:
        raise ValueError("%d bytes do not fit in a version %d symbol at level %s" % (len(payload), max_version, ecl))
    codewords = _interleave(_encode_data(payload, version, ecl), version, ecl)
    base = _build_function_patterns(version)
    _place(base, codewords)
    best = None  # type: Optional[Tuple[int, int, List[List[bool]]]]
    for m in ([mask] if mask is not None else range(8)):
        g = _Grid(version)
        g.dark = [row[:] for row in base.dark]
        g.func = [row[:] for row in base.func]
        for r in range(g.size):
            for c in range(g.size):
                if not g.func[r][c] and _mask_bit(m, r, c):
                    g.dark[r][c] = not g.dark[r][c]
        _draw_format(g, ecl, m)
        score = _penalty(g.dark)
        if best is None or score < best[0]:
            best = (score, m, g.dark)
    assert best is not None
    return QrCode(version, ecl, best[1], tuple(tuple(row) for row in best[2]))


# ---------------------------------------------------------------------------------------------------- text output
_FULL, _UPPER, _LOWER = "\U00002588", "\U00002580", "\U00002584"
_ANSI_ON, _ANSI_OFF = "\x1b[30;47m", "\x1b[0m"


def _padded(qr: QrCode, quiet: int) -> List[List[bool]]:
    n = qr.size + 2 * quiet
    grid = [[False] * n for _ in range(n)]
    for r in range(qr.size):
        for c in range(qr.size):
            grid[r + quiet][c + quiet] = qr.modules[r][c]
    return grid


def render_ascii(qr: QrCode, quiet: int = 2, dark: str = "##", light: str = "  ") -> str:
    """One text line per module row, ``dark`` or ``light`` per module (two characters wide so the code is roughly square). Safe
    for logs and serial consoles; the quiet zone is ``quiet`` modules of light on every side."""
    return "\n".join("".join(dark if v else light for v in row) for row in _padded(qr, quiet)) + "\n"


def render_ansi(qr: QrCode, quiet: int = 2) -> str:
    """Two module rows per line using half-block characters, drawn black on white with explicit colours so the code is the right
    way round on a dark terminal as well as a light one. Each line ends by resetting the colours."""
    grid = _padded(qr, quiet)
    if len(grid) % 2:
        grid.append([False] * len(grid[0]))
    lines = []
    for r in range(0, len(grid), 2):
        chars = []
        for c in range(len(grid[0])):
            top, bottom = grid[r][c], grid[r + 1][c]
            chars.append(_FULL if top and bottom else _UPPER if top else _LOWER if bottom else " ")
        lines.append(_ANSI_ON + "".join(chars) + _ANSI_OFF)
    return "\n".join(lines) + "\n"

