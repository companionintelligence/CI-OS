#!/usr/bin/env python3
"""Test: lib/qmp-drive.py types the characters it is given on a guest with a US or a German keyboard.

QMP send-key names physical keys by their US position, so for a German guest every character must be the key that PRODUCES it on a German
layout (y and z swapped, "-" on the slash key, ":" on shift+dot, "|" on AltGr+less ...). The first German install run on 2026-10-19 needed
this to type the one-time password and a command into the guest. The check here does not trust the table it tests: it keeps its own copy of
the German layout the other way round (physical key -> what it produces plain, with shift and with AltGr), takes the key spec that
qmp-drive.py chooses for each character and asks what that spec produces.

Run: python3 backends/ubuntu/iso/tests/test_qmp_layouts.py     (stock Python 3, no VM, no network)
"""
import importlib.util
import os
import string
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("qmp_drive", os.path.join(HERE, "lib", "qmp-drive.py"))
qd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qd)

# German (QWERTZ) layout: physical key (its US name) -> (plain, shift, AltGr). None: no such character without a dead key.
DE = {
    "1": ("1", "!", None), "2": ("2", '"', None), "3": ("3", None, None), "4": ("4", "$", None), "5": ("5", "%", None),
    "6": ("6", "&", None), "7": ("7", "/", "{"), "8": ("8", "(", "["), "9": ("9", ")", "]"), "0": ("0", "=", "}"),
    "minus": (None, "?", "\\"),
    "q": ("q", "Q", "@"), "w": ("w", "W", None), "e": ("e", "E", None), "r": ("r", "R", None), "t": ("t", "T", None),
    "y": ("z", "Z", None), "u": ("u", "U", None), "i": ("i", "I", None), "o": ("o", "O", None), "p": ("p", "P", None),
    "bracket_right": ("+", "*", "~"),
    "a": ("a", "A", None), "s": ("s", "S", None), "d": ("d", "D", None), "f": ("f", "F", None), "g": ("g", "G", None),
    "h": ("h", "H", None), "j": ("j", "J", None), "k": ("k", "K", None), "l": ("l", "L", None),
    "backslash": ("#", "'", None),
    "less": ("<", ">", "|"),
    "z": ("y", "Y", None), "x": ("x", "X", None), "c": ("c", "C", None), "v": ("v", "V", None), "b": ("b", "B", None),
    "n": ("n", "N", None), "m": ("m", "M", None), "comma": (",", ";", None), "dot": (".", ":", None), "slash": ("-", "_", None),
    "spc": (" ", None, None), "ret": ("\n", None, None), "tab": ("\t", None, None),
}
US = {  # the same, for the US keyboard
    **{k: (k, k.upper(), None) for k in string.ascii_lowercase},
    "1": ("1", "!", None), "2": ("2", "@", None), "3": ("3", "#", None), "4": ("4", "$", None), "5": ("5", "%", None),
    "6": ("6", "^", None), "7": ("7", "&", None), "8": ("8", "*", None), "9": ("9", "(", None), "0": ("0", ")", None),
    "minus": ("-", "_", None), "equal": ("=", "+", None), "bracket_left": ("[", "{", None), "bracket_right": ("]", "}", None),
    "backslash": ("\\", "|", None), "semicolon": (";", ":", None), "apostrophe": ("'", '"', None), "comma": (",", "<", None),
    "dot": (".", ">", None), "slash": ("/", "?", None), "grave_accent": ("`", "~", None),
    "spc": (" ", None, None), "ret": ("\n", None, None), "tab": ("\t", None, None),
}


def produces(layout, spec_text):
    """What a keyboard with `layout` types when the keys of `spec_text` (a+b+c) are pressed together."""
    keys = spec_text.split("+")
    mods = {"shift"} & set(keys), {"alt_r"} & set(keys)
    shift, altgr = bool(mods[0]), bool(mods[1])
    base = [k for k in keys if k not in ("shift", "alt_r")]
    assert len(base) == 1, spec_text
    plain, shifted, alt = layout[base[0]]
    return alt if altgr else (shifted if shift else plain)


class LayoutTests(unittest.TestCase):
    PRINTABLE = [c for c in string.printable if c not in "\r\x0b\x0c"]

    def test_german_layout_produces_every_character_it_is_asked_for(self):
        no_key = set("`^")            # dead keys on a German layout: not typed
        for ch in self.PRINTABLE:
            if ch in no_key:
                with self.assertRaises(SystemExit, msg=repr(ch)):
                    qd.key_spec(ch, "de")
                continue
            self.assertEqual(produces(DE, qd.key_spec(ch, "de")), ch, repr(ch))

    def test_us_layout_still_produces_every_character_it_is_asked_for(self):
        for ch in self.PRINTABLE:
            self.assertEqual(produces(US, qd.key_spec(ch, "us")), ch, repr(ch))

    def test_the_default_layout_is_us(self):
        self.assertEqual(qd.key_spec("A"), "shift+a")
        self.assertEqual(qd.key_spec("-"), "minus")

    def test_the_known_traps_of_a_german_keyboard(self):
        self.assertEqual(qd.key_spec("y", "de"), "z")
        self.assertEqual(qd.key_spec("z", "de"), "y")
        self.assertEqual(qd.key_spec("Z", "de"), "shift+y")
        self.assertEqual(qd.key_spec("-", "de"), "slash")                  # the key the US layout calls slash
        self.assertEqual(qd.key_spec(":", "de"), "shift+dot")
        self.assertEqual(qd.key_spec("/", "de"), "shift+7")
        self.assertEqual(qd.key_spec("|", "de"), "alt_r+less")

    def test_the_one_time_password_alphabet_survives_the_german_layout(self):
        # ci-os-auto-install: abcdefghjkmnpqrstuvwxyz23456789 in groups of four joined by "-"
        text = "abcd-efgh-jkmn-pqrs-tuvw-xyz2-3456-789"
        self.assertEqual("".join(produces(DE, qd.key_spec(c, "de")) for c in text), text)

    def test_an_unknown_layout_is_refused(self):
        with self.assertRaises(SystemExit):
            qd.key_spec("a", "fr")


if __name__ == "__main__":
    unittest.main(verbosity=2)
