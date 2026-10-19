"""Tests for ci_setup.qr, the small QR encoder.

Three layers of evidence, from cheapest to strongest:
1. published constants: the Reed-Solomon generator, the Reed-Solomon codewords of the standard worked example, the format and
   version words, the byte capacities of versions 1 to 10, and the block tables (their sums must equal the total codewords);
2. an independently written DECODER (below) run on every version, error-correction level and mask: it finds the format word
   by trying all 32, rebuilds the data-module order with its own traversal, unmasks, de-interleaves, checks that every
   Reed-Solomon block has zero syndromes (using its own GF(256) multiplication) and parses the byte-mode stream;
3. (not here) the operating system's QR detector on rendered images: qr_check_macos.sh.
"""
import random
import unittest

import helpers
from ci_setup import qr, wifi_qr


# ------------------------------------------------------------------------------------------------ the independent decoder
def gf_mul(a, b):
    """GF(256) with the QR polynomial 0x11D by shift and add (no tables)."""
    out = 0
    while b:
        if b & 1:
            out ^= a
        a <<= 1
        if a & 0x100:
            a ^= 0x11D
        b >>= 1
    return out


def gf_pow2(n):
    v = 1
    for _ in range(n):
        v = gf_mul(v, 2)
    return v


MASKS = [
    lambda i, j: (i + j) % 2 == 0,
    lambda i, j: i % 2 == 0,
    lambda i, j: j % 3 == 0,
    lambda i, j: (i + j) % 3 == 0,
    lambda i, j: (i // 2 + j // 3) % 2 == 0,
    lambda i, j: (i * j) % 2 + (i * j) % 3 == 0,
    lambda i, j: ((i * j) % 2 + (i * j) % 3) % 2 == 0,
    lambda i, j: ((i + j) % 2 + (i * j) % 3) % 2 == 0,
]


def is_function(n, version, r, c):
    if r < 9 and c < 9 or r < 9 and c >= n - 8 or r >= n - 8 and c < 9:
        return True                                       # finders, separators, format information, the dark module
    if r == 6 or c == 6:
        return True                                       # timing
    if version >= 7 and (r < 6 and c >= n - 11 or r >= n - 11 and c < 6):
        return True                                       # version information
    pos = qr._ALIGNMENT[version]
    for i, ar in enumerate(pos):
        for j, ac in enumerate(pos):
            corner = (i == 0 and j == 0) or (i == 0 and j == len(pos) - 1) or (i == len(pos) - 1 and j == 0)
            if not corner and abs(r - ar) <= 2 and abs(c - ac) <= 2:
                return True
    return False


def read_format(modules):
    """Both copies of the 15 format bits, MOST significant first. Copy 1 runs along row 8 from column 0 (bit 14) past the timing
    column, then up column 8 to row 0 (bit 0); copy 2 runs up from the bottom of column 8 (bit 14), then along row 8 from column
    n-8 (bit 7) to the right edge (bit 0)."""
    n = len(modules)
    first = ([modules[8][c] for c in (0, 1, 2, 3, 4, 5, 7, 8)] + [modules[r][8] for r in (7, 5, 4, 3, 2, 1, 0)])
    second = ([modules[r][8] for r in range(n - 1, n - 8, -1)] + [modules[8][c] for c in range(n - 8, n)])
    return first, second


def word_of(bits_msb_first):
    return sum((1 << (len(bits_msb_first) - 1 - i)) for i, b in enumerate(bits_msb_first) if b)


def decode_symbol(modules):
    n = len(modules)
    version = (n - 17) // 4
    first, second = read_format(modules)
    word1, word2 = word_of(first), word_of(second)
    assert word1 == word2, "the two copies of the format word differ: %x %x" % (word1, word2)
    found = None
    for ecl in "LMQH":
        for mask in range(8):
            if qr.format_word(ecl, mask) == word1:
                found = (ecl, mask)
    assert found is not None, "no format word matches %x" % word1
    ecl, mask = found
    # data modules in reading order: pairs of columns from the right, skipping column 6, alternating up and down
    cols = [c for c in range(n - 1, -1, -1) if c != 6]
    order = []
    for k in range(0, len(cols), 2):
        pair = (cols[k], cols[k + 1])
        rows = range(n - 1, -1, -1) if (k // 2) % 2 == 0 else range(n)
        for r in rows:
            for c in pair:
                if not is_function(n, version, r, c):
                    order.append((r, c))
    bits = [modules[r][c] ^ MASKS[mask](r, c) for r, c in order]
    total = qr.TOTAL_CODEWORDS[version]
    assert len(bits) >= total * 8 and len(bits) - total * 8 == (7 if 2 <= version <= 6 else 0), len(bits)
    words = [sum((1 << (7 - i)) for i in range(8) if bits[8 * w + i]) for w in range(total)]
    ec_len, groups = qr._BLOCKS[version][ecl]
    sizes = [d for count, d in groups for _ in range(count)]
    nblocks = len(sizes)
    data_total = sum(sizes)
    blocks = [[] for _ in range(nblocks)]
    pos = 0
    for i in range(max(sizes)):
        for b in range(nblocks):
            if i < sizes[b]:
                blocks[b].append(words[pos])
                pos += 1
    ecs = [[] for _ in range(nblocks)]
    for i in range(ec_len):
        for b in range(nblocks):
            ecs[b].append(words[pos])
            pos += 1
    assert pos == total
    for b in range(nblocks):
        codeword = blocks[b] + ecs[b]
        for root in range(ec_len):
            x, acc = gf_pow2(root), 0
            for w in codeword:                                # Horner: the codeword polynomial evaluated at alpha^root
                acc = gf_mul(acc, x) ^ w
            assert acc == 0, "block %d has a non-zero syndrome at alpha^%d" % (b, root)
    data = [w for blk in blocks for w in blk]
    assert len(data) == data_total
    stream = "".join("{:08b}".format(w) for w in data)
    assert stream[:4] == "0100", "not byte mode: " + stream[:4]
    cbits = 8 if version <= 9 else 16
    count = int(stream[4:4 + cbits], 2)
    body = stream[4 + cbits:4 + cbits + 8 * count]
    payload = bytes(int(body[i:i + 8], 2) for i in range(0, len(body), 8))
    used = 4 + cbits + 8 * count
    term = min(4, len(stream) - used)
    aligned = used + term + (-(used + term)) % 8
    assert set(stream[used:aligned]) <= {"0"}, "terminator and alignment bits must be zero"
    pad = [int(stream[i:i + 8], 2) for i in range(aligned, len(stream), 8)]
    assert pad == [(0xEC, 0x11)[i % 2] for i in range(len(pad))], "pad bytes must alternate 0xEC, 0x11"
    return {"version": version, "ecl": ecl, "mask": mask, "payload": payload}


# ------------------------------------------------------------------------------------------------ published constants
class Constants(unittest.TestCase):
    def test_reed_solomon_generator_of_degree_10(self):
        self.assertEqual([1, 216, 194, 159, 111, 199, 94, 95, 113, 157, 193], qr.rs_generator(10))

    def test_worked_example_hello_world_1m(self):
        data = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]
        self.assertEqual([196, 35, 39, 119, 235, 215, 231, 226, 93, 23], qr.rs_remainder(data, 10))

    def test_remainder_of_codeword_is_zero(self):
        rnd = random.Random(3)
        for degree in (7, 10, 13, 17, 18, 20, 22, 24, 26, 28, 30):
            data = [rnd.randrange(256) for _ in range(50)]
            ec = qr.rs_remainder(data, degree)
            self.assertEqual([0] * degree, qr.rs_remainder(data + ec, degree))

    def test_format_words(self):
        expect = {("L", 0): 0x77C4, ("M", 0): 0x5412, ("Q", 0): 0x355F, ("H", 0): 0x1689, ("L", 1): 0x72F3, ("M", 1): 0x5125}
        for (ecl, mask), word in expect.items():
            self.assertEqual(word, qr.format_word(ecl, mask), (ecl, mask))
        self.assertEqual(32, len({qr.format_word(e, m) for e in "LMQH" for m in range(8)}))
        for e in "LMQH":                                     # BCH(15,5,7): any two words differ in at least 7 bits
            for m in range(8):
                for e2 in "LMQH":
                    for m2 in range(8):
                        if (e, m) != (e2, m2):
                            self.assertGreaterEqual(bin(qr.format_word(e, m) ^ qr.format_word(e2, m2)).count("1"), 7)

    def test_version_words(self):
        self.assertEqual(0x07C94, qr.version_word(7))
        self.assertEqual(0x085BC, qr.version_word(8))
        self.assertEqual(0x0A4D3, qr.version_word(10))

    def test_byte_capacities_match_the_standard(self):
        expect = {1: (17, 14, 11, 7), 2: (32, 26, 20, 14), 3: (53, 42, 32, 24), 4: (78, 62, 46, 34), 5: (106, 84, 60, 44),
                  6: (134, 106, 74, 58), 7: (154, 122, 86, 64), 8: (192, 152, 108, 84), 9: (230, 180, 130, 98), 10: (271, 213, 151, 119)}
        for v, caps in expect.items():
            self.assertEqual(caps, tuple(qr.capacity_bytes(v, e) for e in "LMQH"), v)

    def test_block_tables_add_up(self):
        for v in range(1, 11):
            for e in "LMQH":
                ec, groups = qr._BLOCKS[v][e]
                self.assertEqual(qr.TOTAL_CODEWORDS[v], sum(n * (d + ec) for n, d in groups), (v, e))
        # the totals are those of the standard: 26, 44, 70, 100, 134, 172, 196, 242, 292, 346
        self.assertEqual([26, 44, 70, 100, 134, 172, 196, 242, 292, 346], [qr.TOTAL_CODEWORDS[v] for v in range(1, 11)])

    def test_alignment_pattern_positions_match_the_standard(self):
        # typed here from ISO/IEC 18004 table E.1; the CoreImage check (qr_check_macos.sh) reads versions 7 to 10 back, which a wrong
        # position would break
        self.assertEqual({1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34], 7: [6, 22, 38], 8: [6, 24, 42],
                          9: [6, 26, 46], 10: [6, 28, 50]}, qr._ALIGNMENT)

    def test_mask_formulas_match_the_standard(self):
        for m in range(8):
            for i in range(60):
                for j in range(60):
                    self.assertEqual(MASKS[m](i, j), qr._mask_bit(m, i, j), (m, i, j))

    def test_error_correction_level_bits(self):
        self.assertEqual({"L": 1, "M": 0, "Q": 3, "H": 2}, qr._FORMAT_BITS)

    def test_data_modules_per_version(self):
        # modules left for data = codewords * 8 + remainder bits: 208, 359, 567, 807, 1079, 1383, 1568, 1936, 2336, 2768
        for v, want in zip(range(1, 11), (208, 359, 567, 807, 1079, 1383, 1568, 1936, 2336, 2768)):
            n = 17 + 4 * v
            free = sum(1 for r in range(n) for c in range(n) if not is_function(n, v, r, c))
            self.assertEqual(want, free, v)


# ------------------------------------------------------------------------------------------------ the symbol
class Structure(unittest.TestCase):
    def test_fixed_patterns(self):
        code = qr.encode("hello", "M")
        m = code.modules
        n = code.size
        self.assertEqual(17 + 4 * code.version, n)
        for r0, c0 in ((0, 0), (0, n - 7), (n - 7, 0)):
            for r in range(7):
                for c in range(7):
                    ring = max(abs(r - 3), abs(c - 3))
                    self.assertEqual(ring != 2, m[r0 + r][c0 + c], (r0, c0, r, c))
        for i in range(8, n - 8):
            self.assertEqual(i % 2 == 0, m[6][i])
            self.assertEqual(i % 2 == 0, m[i][6])
        self.assertTrue(m[n - 8][8])                                  # the dark module
        for i in range(8):                                            # separators are light
            self.assertFalse(m[7][i] or m[i][7])

    def test_smallest_version_that_fits(self):
        for ecl in "LMQH":
            self.assertEqual(1, qr.encode(b"x" * qr.capacity_bytes(1, ecl), ecl).version)
            self.assertEqual(2, qr.encode(b"x" * (qr.capacity_bytes(1, ecl) + 1), ecl).version)
            self.assertEqual(10, qr.encode(b"x" * qr.capacity_bytes(10, ecl), ecl).version)

    def test_too_long_and_bad_arguments(self):
        with self.assertRaises(ValueError):
            qr.encode(b"x" * (qr.capacity_bytes(10, "L") + 1), "L")
        with self.assertRaises(ValueError):
            qr.encode("x", "Z")
        with self.assertRaises(ValueError):
            qr.encode("x", "M", min_version=5, max_version=3)
        with self.assertRaises(ValueError):
            qr.encode("x", "M", max_version=11)
        with self.assertRaises(ValueError):
            qr.encode(b"x" * 20, "M", max_version=1)
        with self.assertRaises(ValueError):
            qr.encode("x", "M", mask=8)

    def test_min_version(self):
        self.assertEqual(4, qr.encode("a", "M", min_version=4).version)

    def test_text_is_utf8(self):
        got = decode_symbol(qr.encode("Caf\U000000e9 \U0001f600", "Q").modules)
        self.assertEqual("Caf\U000000e9 \U0001f600".encode("utf-8"), got["payload"])

    def test_deterministic(self):
        a = qr.encode("WIFI:T:WPA;S:x;P:y;;", "M")
        b = qr.encode("WIFI:T:WPA;S:x;P:y;;", "M")
        self.assertEqual(a, b)


class RoundTrip(unittest.TestCase):
    def test_every_version_level_and_mask_decodes(self):
        rnd = random.Random(helpers.fuzz_seed())
        cases = 0
        quick = helpers.fuzz_n(200000) < 20000
        for version in range(1, 11):
            for ecl in "LMQH":
                cap = qr.capacity_bytes(version, ecl)
                lengths = {cap, max(0, cap - 1), cap // 2, 1 if version == 1 else qr.capacity_bytes(version - 1, ecl) + 1}
                for length in sorted(lengths):
                    payload = bytes(rnd.randrange(256) for _ in range(length))
                    for mask in ((version % 8, (version + 3) % 8) if quick else range(8)):
                        code = qr.encode(payload, ecl, min_version=version, max_version=version, mask=mask)
                        got = decode_symbol(code.modules)
                        self.assertEqual((version, ecl, mask, payload), (got["version"], got["ecl"], got["mask"], got["payload"]))
                        cases += 1
        self.assertGreater(cases, 150 if quick else 1000)

    def test_default_mask_selection_decodes(self):
        rnd = random.Random(helpers.fuzz_seed() + 1)
        for _ in range(helpers.fuzz_n(20000) // 400 or 1):
            ecl = rnd.choice("LMQH")
            length = rnd.randrange(0, qr.capacity_bytes(rnd.randint(1, 10), ecl) + 1)
            payload = bytes(rnd.randrange(256) for _ in range(length))
            code = qr.encode(payload, ecl)
            self.assertEqual(payload, decode_symbol(code.modules)["payload"])

    def test_wifi_codes_of_the_access_point(self):
        for ssid, key in (("Companion-Setup-AB12", "ABCDEFGHJKMN"), ("Companion-Setup-ZZ99", "23456789ABCD"),
                          ("x", "12345678"), ("Caf\U000000e9 \U0001f600", "p@ss;w\\rd:1,2")):
            payload = wifi_qr.wifi_payload(ssid, key)
            code = qr.encode(payload, "M")
            self.assertLessEqual(code.version, 6)
            self.assertEqual(payload.encode("utf-8"), decode_symbol(code.modules)["payload"])
        code = qr.encode(wifi_qr.wifi_payload("Companion-Setup-AB12", "ABCDEFGHJKMN"), "M")
        self.assertEqual(4, code.version)                              # 50 bytes: version 4 at level M

    def test_a_corrupted_symbol_fails_the_decoder(self):
        """The decoder is not vacuous: damage a data module and the Reed-Solomon check must notice."""
        code = qr.encode(b"The quick brown fox", "L", mask=2)
        n = code.size
        bad = [list(row) for row in code.modules]
        flipped = 0
        for r in range(n - 1, 0, -1):
            for c in range(n - 1, n - 3, -1):
                if not is_function(n, code.version, r, c) and flipped < 1:
                    bad[r][c] = not bad[r][c]
                    flipped += 1
        with self.assertRaises(AssertionError):
            decode_symbol(bad)


class Penalty(unittest.TestCase):
    def test_chosen_mask_has_the_lowest_penalty(self):
        payload = b"WIFI:T:WPA;S:Companion-Setup-AB12;P:ABCDEFGHJKMN;;"
        scores = []
        for mask in range(8):
            code = qr.encode(payload, "M", mask=mask)
            scores.append(qr._penalty([list(row) for row in code.modules]))
        chosen = qr.encode(payload, "M")
        self.assertEqual(min(scores), scores[chosen.mask])
        self.assertEqual(scores.index(min(scores)), chosen.mask)

    def test_penalty_rules(self):
        n = 21
        light = [[False] * n for _ in range(n)]
        self.assertGreater(qr._penalty(light), 1000)                   # long runs, 2x2 blocks and a lopsided balance
        checker = [[(r + c) % 2 == 0 for c in range(n)] for r in range(n)]
        self.assertLess(qr._penalty(checker), 60)
        # a 1:1:3:1:1 pattern with four light modules on one side costs 40 in each direction it appears
        base = [[(r * 7 + c * 3) % 5 == 0 for c in range(n)] for r in range(n)]
        with_pattern = [row[:] for row in base]
        for i, ch in enumerate("10111010000"):
            with_pattern[10][i] = ch == "1"
        self.assertGreater(qr._penalty(with_pattern), qr._penalty(base) - 100)


class Rendering(unittest.TestCase):
    def setUp(self):
        self.code = qr.encode(wifi_qr.wifi_payload("Companion-Setup-AB12", "ABCDEFGHJKMN"), "M")

    def test_ascii_roundtrip(self):
        text = qr.render_ascii(self.code, quiet=2)
        lines = text.split("\n")[:-1]
        n = self.code.size
        self.assertEqual(n + 4, len(lines))
        for ln in lines:
            self.assertEqual(2 * (n + 4), len(ln))
        back = tuple(tuple(lines[r + 2][2 * (c + 2):2 * (c + 2) + 2] == "##" for c in range(n)) for r in range(n))
        self.assertEqual(self.code.modules, back)
        for ln in lines[:2] + lines[-2:]:
            self.assertEqual("", ln.strip())                                   # quiet zone

    def test_ansi_roundtrip(self):
        text = qr.render_ansi(self.code, quiet=2)
        lines = text.split("\n")[:-1]
        n = self.code.size
        self.assertEqual((n + 4 + 1) // 2, len(lines))
        full, up, low = "\U00002588", "\U00002580", "\U00002584"
        grid = []
        for ln in lines:
            self.assertTrue(ln.startswith("\x1b[30;47m") and ln.endswith("\x1b[0m"))
            body = ln[len("\x1b[30;47m"):-len("\x1b[0m")]
            self.assertNotIn("\x1b", body)
            self.assertEqual(n + 4, len(body))
            grid.append([ch in (full, up) for ch in body])
            grid.append([ch in (full, low) for ch in body])
        back = tuple(tuple(grid[r + 2][c + 2] for c in range(n)) for r in range(n))
        self.assertEqual(self.code.modules, back)
        self.assertTrue(all(not v for v in grid[0] + grid[1]))

    def test_ansi_forces_black_on_white_whatever_the_theme(self):
        self.assertIn("\x1b[30;47m", qr.render_ansi(self.code))

    def test_console_qr(self):
        text = wifi_qr.console_qr("Companion-Setup-AB12", "ABCDEFGHJKMN")
        self.assertEqual(qr.render_ansi(self.code), text)
        self.assertEqual(qr.render_ascii(self.code), wifi_qr.console_qr("Companion-Setup-AB12", "ABCDEFGHJKMN", ansi=False))
        self.assertIsNone(wifi_qr.console_qr(";" * 32, "\\" * 63, ecl="H"))   # 208 bytes once escaped: version 10 holds 119 at level H

    def test_source_has_no_block_art_literal(self):
        with open(qr.__file__, encoding="utf-8") as fh:
            self.assertNotIn("\U00002588", fh.read())


if __name__ == "__main__":
    unittest.main()
