#!/usr/bin/env python3
"""Test: video/tools/make-plates.py makes the video's plates from a recorded run, covers the one-time password, and notices when a plate is wrong.

The tool's one safety job is the bar over the one-time password, so these checks look at PIXELS of synthetic 1920 x 1080 frames: a covered
rectangle is a flat bar in the plate and the pixels around it are untouched, a rectangle that stops beside more text is refused (the real
mistake found by eye on the first run: the dialog moves 33 px when its wording is wider), a plate of the wrong size or a rectangle outside
the picture is refused, and --verify fails for a plate that was edited, one that is missing from the ledger, a ledger row with no file, and a
covered region that is not a flat bar any more. The last test checks the plates committed in video/assets/shots against their ledger, so a
hand-edited plate fails the gate. It needs Pillow (exit 2, "cannot run here", without it).

Run: python3 video/tools/test_make_plates.py
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("cannot run here: Pillow is missing (pip install pillow, or apt install python3-pil)")
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("make_plates", os.path.join(HERE, "make-plates.py"))
mp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mp)

SIZE = (1920, 1080)
BG = (250, 250, 250)
INK = (30, 30, 30)
BAR = [100, 200, 400, 230]            # a cover rectangle with clear margin on a frame that has ink at 150..350 x 205..225


def write_frame(path, ink_box=(150, 205, 350, 225), size=SIZE):
    im = Image.new("RGB", size, BG)
    if ink_box:
        ImageDraw.Draw(im).rectangle(ink_box, fill=INK)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im.save(path)


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_text(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def write_recipe(path, plates, size=SIZE):
    recipe = {
        "recording": {"taken": "2026-10-19", "image": "test.iso", "image_sha256": "0" * 64, "machine": "test", "choices": "none", "evidence": "none"},
        "size": list(size),
        "plates": plates,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(recipe, f)


class Workspace(object):
    def __init__(self, test):
        self.dir = tempfile.mkdtemp(prefix="plates-test-")
        test.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.run = os.path.join(self.dir, "run")
        self.out = os.path.join(self.dir, "shots")
        self.recipe = os.path.join(self.dir, "plates.json")


class MakePlates(unittest.TestCase):
    def make(self, plates, ink_box=(150, 205, 350, 225), frames=("a.png", "b.png")):
        ws = Workspace(self)
        for name in frames:
            write_frame(os.path.join(ws.run, name), ink_box)
        write_recipe(ws.recipe, plates)
        return ws

    def test_a_covered_rectangle_is_a_flat_bar_and_the_rest_is_untouched(self):
        ws = self.make([{"id": "one", "source": "a.png", "shows": "x", "cover": [BAR]}, {"id": "two", "source": "b.png", "shows": "y"}])
        rows = mp.make(ws.run, ws.out, lossless=True, recipe_path=ws.recipe)
        self.assertEqual([r["id"] for r in rows], ["one", "two"])
        one = Image.open(os.path.join(ws.out, "one.png")).convert("RGB")
        self.assertEqual(one.size, SIZE)
        for x, y in ((120, 215), (399, 215), (250, 215), (250, 229)):          # inside the bar, away from the rounded corners
            self.assertEqual(one.getpixel((x, y)), mp.COVER, (x, y))
        for x, y in ((50, 215), (450, 215), (250, 150), (250, 300)):           # outside it
            self.assertEqual(one.getpixel((x, y)), BG, (x, y))
        self.assertNotIn(INK, [one.getpixel((x, 215)) for x in range(150, 351, 10)], "the ink under the bar must be gone, not hidden")
        two = Image.open(os.path.join(ws.out, "two.png")).convert("RGB")
        self.assertEqual(two.getpixel((250, 215)), INK, "a plate with no cover keeps its pixels")

    def test_the_ledger_is_written_and_verify_passes(self):
        ws = self.make([{"id": "one", "source": "a.png", "shows": "x", "cover": [BAR]}, {"id": "two", "source": "b.png", "shows": "y"}])
        mp.make(ws.run, ws.out, lossless=True, recipe_path=ws.recipe)
        ledger = read_text(os.path.join(ws.out, "PROVENANCE.md"))
        self.assertIn("| one |", ledger)
        self.assertIn("| two |", ledger)
        self.assertIn("none |", ledger)
        self.assertEqual(mp.verify(ws.out), [])

    def test_a_rectangle_that_ends_beside_more_text_is_refused(self):
        # ink runs 150..350; a bar that stops at x=330 leaves the last characters on the plate
        ws = self.make([{"id": "one", "source": "a.png", "shows": "x", "cover": [[100, 200, 330, 230]]}])
        with self.assertRaises(ValueError) as cm:
            mp.make(ws.run, ws.out, lossless=True, recipe_path=ws.recipe)
        self.assertIn("text reaches the edge", str(cm.exception))

    def test_a_rectangle_outside_the_picture_or_empty_is_refused(self):
        for rect in ([1900, 100, 1950, 140], [100, 100, 100, 140], [100, 300, 200, 200]):
            ws = self.make([{"id": "one", "source": "a.png", "shows": "x", "cover": [rect]}])
            with self.assertRaises(ValueError, msg=str(rect)):
                mp.make(ws.run, ws.out, lossless=True, recipe_path=ws.recipe)

    def test_a_source_of_the_wrong_size_or_a_missing_source_is_refused(self):
        ws = Workspace(self)
        write_frame(os.path.join(ws.run, "small.png"), size=(1280, 720), ink_box=None)
        write_recipe(ws.recipe, [{"id": "one", "source": "small.png", "shows": "x"}])
        with self.assertRaises(ValueError) as cm:
            mp.make(ws.run, ws.out, lossless=True, recipe_path=ws.recipe)
        self.assertIn("1280x720", str(cm.exception))
        write_recipe(ws.recipe, [{"id": "one", "source": "nope.png", "shows": "x"}])
        with self.assertRaises(FileNotFoundError):
            mp.make(ws.run, ws.out, lossless=True, recipe_path=ws.recipe)

    def test_a_repeated_plate_id_is_refused(self):
        ws = self.make([{"id": "one", "source": "a.png", "shows": "x"}, {"id": "one", "source": "b.png", "shows": "y"}])
        with self.assertRaises(ValueError):
            mp.make(ws.run, ws.out, lossless=True, recipe_path=ws.recipe)

    def test_verify_fails_for_an_edited_plate(self):
        ws = self.make([{"id": "one", "source": "a.png", "shows": "x", "cover": [BAR]}])
        mp.make(ws.run, ws.out, lossless=True, recipe_path=ws.recipe)
        p = os.path.join(ws.out, "one.png")
        im = Image.open(p).convert("RGB")
        im.putpixel((5, 5), (1, 2, 3))
        im.save(p)
        problems = mp.verify(ws.out)
        self.assertEqual(len(problems), 1)
        self.assertIn("does not match the recorded sha256", problems[0])

    def test_verify_fails_for_an_unlisted_plate_and_a_row_with_no_file(self):
        ws = self.make([{"id": "one", "source": "a.png", "shows": "x"}, {"id": "two", "source": "b.png", "shows": "y"}])
        mp.make(ws.run, ws.out, lossless=True, recipe_path=ws.recipe)
        shutil.copyfile(os.path.join(ws.out, "one.png"), os.path.join(ws.out, "stray.png"))
        os.unlink(os.path.join(ws.out, "two.png"))
        problems = " | ".join(mp.verify(ws.out))
        self.assertIn("stray: stray.png is not listed", problems)
        self.assertIn("two: listed in PROVENANCE.md but two.png is not", problems)

    def test_verify_fails_when_a_covered_region_is_not_a_flat_bar(self):
        # a plate made WITHOUT the cover, but recorded as covered (the ledger hash is of that plate, so only the flat-bar rule can catch it)
        ws = self.make([{"id": "one", "source": "a.png", "shows": "x", "cover": [BAR]}])
        mp.make(ws.run, ws.out, lossless=True, recipe_path=ws.recipe)
        plain = Image.open(os.path.join(ws.run, "a.png")).convert("RGB")
        plain.save(os.path.join(ws.out, "one.png"))
        ledger_path = os.path.join(ws.out, "PROVENANCE.md")
        text = read_text(ledger_path)
        row = [r for r in text.splitlines() if r.startswith("| one |")][0]
        old_sha = row.split(" | ")[4].strip("`")
        new_sha = mp.sha256_file(os.path.join(ws.out, "one.png"))
        write_text(ledger_path, text.replace(old_sha, new_sha))
        problems = mp.verify(ws.out)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("not a flat bar", problems[0])

    def test_verify_needs_a_ledger(self):
        ws = Workspace(self)
        os.makedirs(ws.out)
        with self.assertRaises(FileNotFoundError):
            mp.verify(ws.out)

    def test_the_committed_plates_match_their_ledger(self):
        problems = mp.verify(mp.SHOTS)
        self.assertEqual(problems, [], "the plates in video/assets/shots do not match PROVENANCE.md: " + "; ".join(problems))

    def test_every_plate_of_the_recipe_is_committed_and_the_storyboard_uses_only_those(self):
        recipe = mp.load_recipe()
        ids = set(p["id"] for p in recipe["plates"])
        for pid in ids:
            self.assertTrue(os.path.isfile(os.path.join(mp.SHOTS, pid + ".png")), pid)
        sb = json.loads(read_text(os.path.join(mp.VIDEO, "storyboard.json")))
        used = set(shot["id"] for scene in sb["scenes"] for shot in scene.get("shots", []))
        self.assertEqual(sorted(used - ids), [], "the storyboard names a shot with no plate in plates.json")
        self.assertEqual(sorted(ids - used), [], "a plate in plates.json is used by no shot")


if __name__ == "__main__":
    res = unittest.main(verbosity=2, exit=False).result
    bad = len(res.failures) + len(res.errors)
    print("== Summary: %d passed, %d failed" % (res.testsRun - bad - len(res.skipped), bad))
    raise SystemExit(0 if res.wasSuccessful() else 1)
