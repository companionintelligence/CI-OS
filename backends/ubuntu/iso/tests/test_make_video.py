#!/usr/bin/env python3
"""Test: lib/make-video.py turns recorded frames into a captioned, redacted, time-compressed video, and never leaves a box off.

The tool's one safety job is to paint a box over the one-time password, so those checks look at PIXELS of synthetic frames (320 x 200 and
640 x 400 pictures, scaled from the 1280 x 800 coordinates of the files): a box covers its rectangle inside its time window and only there, a
`bright` rule fires only when the dialog is on screen, a click ring shows for about a second, a repeat frame is dropped, a wait is capped, and the
end-to-end run through ffmpeg yields a video of the length the frames call for. It needs Pillow (exit 2, "cannot run here", without it); the
ffmpeg part is skipped without ffmpeg.

Run: python3 backends/ubuntu/iso/tests/test_make_video.py
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

try:
    from PIL import Image, ImageChops
except ImportError:
    print("cannot run here: Pillow is missing (pip install pillow, or apt install python3-pil)")
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("make_video", os.path.join(HERE, "lib", "make-video.py"))
mv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mv)

T0 = 1792449000                       # an epoch for the frames
DARK = (20, 24, 28)
WHITE = (250, 250, 250)


def frame(color=WHITE, size=(640, 400), patch=None):
    img = Image.new("RGB", size, color)
    if patch:
        x, y, w, h, c = patch
        img.paste(c, (x, y, x + w, y + h))
    return img


def px(img, x, y):
    return img.getpixel((x, y))


def write(tmp, name, text):
    p = os.path.join(tmp, name)
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(text)
    return p


class ParseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mv-test-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_when(self):
        self.assertEqual(mv.when("1792449387"), 1792449387)
        self.assertEqual(mv.when("2026-10-19T22:36:27Z"), mv.when("2026-10-19T22:36:27+00:00"))
        self.assertEqual(mv.when("2026-10-19T22:36:27Z") - mv.when("2026-10-19T22:36:26Z"), 1)
        with self.assertRaises(ValueError):
            mv.when("tomorrow")

    def test_chapters_sorted_comments_and_clear(self):
        p = write(self.tmp, "c.txt", "# a comment\n1792449100 | second\n\n1792449000 | first\n1792449200 | -\n")
        ch = mv.parse_chapters(p)
        self.assertEqual([c for _, c in ch], ["first", "second", ""])
        self.assertEqual(mv.caption_for(ch, 1792448999), "")
        self.assertEqual(mv.caption_for(ch, 1792449000), "first")
        self.assertEqual(mv.caption_for(ch, 1792449150), "second")
        self.assertEqual(mv.caption_for(ch, 1792449300), "")                 # '-' clears it
        self.assertEqual(mv.parse_chapters(write(self.tmp, "d.txt", "1792449000 | a | b\n"))[0][1], "a | b")

    def test_redactions_plain_and_bright(self):
        p = write(self.tmp, "r.txt", "1792449000 1792449060 10 20 30 40\n# x\n1792449000 1792449060 1 2 3 4 bright 5 6 7 8\n")
        r = mv.parse_redactions(p)
        self.assertEqual(r[0], (1792449000, 1792449060, 10, 20, 30, 40, None))
        self.assertEqual(r[1][6], (5, 6, 7, 8))
        self.assertEqual(mv.parse_redactions(None), [])

    def test_clicks(self):
        self.assertEqual(mv.parse_clicks(write(self.tmp, "k.txt", "1792449001 640 574 1280 800\n")), [(1792449001, 640, 574, 1280, 800)])

    def test_list_frames_filters_by_time_and_name(self):
        d = os.path.join(self.tmp, "f"); os.makedirs(d)
        for n in ("f-1792449000.png", "f-1792449010.png", "f-1792449020.png", "x-1.png", "f-abc.png"):
            frame().save(os.path.join(d, n))
        self.assertEqual([t for t, _ in mv.list_frames([d])], [1792449000, 1792449010, 1792449020])
        self.assertEqual([t for t, _ in mv.list_frames([d], 1792449005, 1792449015)], [1792449010])


class AnnotateTests(unittest.TestCase):
    def test_redaction_box_inside_its_window_only_and_scaled(self):
        red = [(T0, T0 + 10, 640, 400, 200, 40, None)]              # reference coordinates: the middle of the screen
        img = frame()                                                # 640 x 400: half the reference size
        inside = mv.annotate(img, T0 + 5, T0, "", red, [], False)
        self.assertEqual(px(inside, 400, 215), DARK)                 # scaled: x 320..420, y 200..220
        self.assertEqual(px(inside, 319, 215), WHITE)
        self.assertEqual(px(inside, 421, 215), WHITE)
        self.assertEqual(px(inside, 400, 222), WHITE)
        for t in (T0 - 1, T0 + 11):
            self.assertEqual(px(mv.annotate(img, t, T0, "", red, [], False), 400, 215), WHITE, t)
        self.assertEqual(px(img, 400, 215), WHITE)                  # the input is not modified

    def test_a_box_is_painted_whatever_the_frame_holds(self):
        red = [(T0, T0 + 10, 0, 0, 1280, 800, None)]                # the whole screen
        out = mv.annotate(frame(color=(200, 30, 30)), T0, T0, "", red, [], False)
        self.assertEqual(px(out, 100, 100), DARK)
        self.assertEqual(px(out, 639, 399), DARK)

    def test_bright_rule_only_when_the_dialog_is_on_screen(self):
        red = [(T0, T0 + 10, 640, 400, 200, 40, (100, 100, 100, 40))]   # the dialog's body at reference (100,100)
        dialog = frame(color=(10, 40, 40), patch=(50, 50, 100, 40, WHITE))            # a white patch where the rule looks
        console = frame(color=(10, 40, 40))                                           # dark there: not the dialog
        self.assertEqual(px(mv.annotate(dialog, T0 + 1, T0, "", red, [], False), 400, 215), DARK)
        self.assertEqual(px(mv.annotate(console, T0 + 1, T0, "", red, [], False), 400, 215), (10, 40, 40))

    def test_click_ring_for_about_a_second_at_the_scaled_position(self):
        clicks = [(T0 + 2, 640, 400, 1280, 800)]                     # the middle of a 640 x 400 frame: (320, 200)
        base = frame(color=(0, 0, 0))

        def ring_pixels(t):
            out = mv.annotate(base, t, T0, "", [], clicks, False)
            return sum(1 for x in range(260, 380) for y in range(140, 260) if px(out, x, y) != (0, 0, 0))
        self.assertEqual(ring_pixels(T0 + 1), 0)                     # before the click
        self.assertGreater(ring_pixels(T0 + 2), 40)                  # at the click
        self.assertGreater(ring_pixels(T0 + 3), 0)                   # a second later: fading
        self.assertEqual(ring_pixels(T0 + 4), 0)                     # gone
        far = mv.annotate(base, T0 + 2, T0, "", [], [(T0 + 2, 1000, 100, 1280, 800)], False)
        self.assertEqual(px(far, 320, 200), (0, 0, 0))               # a ring elsewhere leaves the middle alone

    def test_click_position_follows_the_clicks_own_screen_size(self):
        out = mv.annotate(frame(color=(0, 0, 0)), T0, T0, "", [], [(T0, 512, 384, 1024, 768)], False)    # the middle of a 1024 x 768 screen
        self.assertTrue(any(px(out, x, 200) != (0, 0, 0) for x in range(290, 350)))

    def test_caption_and_clock_change_the_picture(self):
        base = frame(color=(0, 0, 0))
        plain = mv.annotate(base, T0, T0, "", [], [], False)
        self.assertEqual(plain.tobytes(), base.tobytes())
        self.assertNotEqual(mv.annotate(base, T0, T0, "Hello there", [], [], False).tobytes(), plain.tobytes())
        self.assertNotEqual(mv.annotate(base, T0 + 125, T0, "", [], [], True).tobytes(), plain.tobytes())


class RenderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mv-test-")
        self.src = os.path.join(self.tmp, "src"); os.makedirs(self.src)
        self.out = os.path.join(self.tmp, "out"); os.makedirs(self.out)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def frames(self, spec):
        """spec: [(seconds after T0, picture)] -> the list render() takes."""
        files = []
        for dt, img in spec:
            p = os.path.join(self.src, "f-%d.png" % (T0 + dt))
            img.save(p)
            files.append((T0 + dt, p))
        return files

    def render(self, spec, **kw):
        return mv.render(self.frames(spec), self.out, [], [], kw.pop("clicks", []), **kw)

    def test_repeats_are_dropped_and_changes_kept(self):
        a, b = frame(), frame(color=(0, 90, 120))
        n = self.render([(0, a), (3, a), (6, a), (9, b), (12, b), (15, a)], fps=5, hold=0.4)
        self.assertEqual(n, 3 * 2)                                   # a, b, a: three kept frames of round(0.4 * 5) = 2 video frames
        self.assertEqual(len(os.listdir(self.out)), n)

    def test_a_long_wait_is_still_shown_now_and_then(self):
        a = frame()
        n = self.render([(i * 10, a) for i in range(8)], fps=5, hold=0.4, max_repeat=30)
        self.assertEqual(n, 2 * 3)                                   # t=0, then 30, then 60: not 70

    def test_a_click_keeps_the_frames_around_it_even_if_nothing_else_moved(self):
        a = frame()
        spec = [(0, a), (1, a), (2, a), (3, a), (4, a), (8, a)]
        without = self.render(spec, fps=5, hold=0.4)
        with_click = self.render(spec, fps=5, hold=0.4, clicks=[(T0 + 1, 100, 100, 1280, 800)])
        self.assertEqual(without, 2)
        self.assertEqual(with_click, 2 * 3)                          # t=0, and the two frames within a second and a bit of the click

    def test_title_and_outro_cards(self):
        a = frame()
        base = self.render([(0, a), (3, a)], fps=5, hold=0.4)
        shutil.rmtree(self.out); os.makedirs(self.out)
        both = self.render([(0, a), (3, a)], fps=5, hold=0.4, title="Start", outro="End")
        self.assertEqual(both, base + 2 * round(2.5 * 5))
        first = Image.open(os.path.join(self.out, "000000.png"))
        self.assertEqual(first.size, a.size)
        self.assertNotEqual(first.getpixel((5, 5)), WHITE)           # the card is not the frame

    def test_card_text_fits_inside_the_picture(self):
        bg = (4, 24, 31)
        for size in ((1280, 800), (640, 400), (320, 200)):
            img = mv.card(size, "Companion OS: from the USB stick to a ready desktop")
            w, h = img.size
            cols = [x for x in range(w) if any(img.getpixel((x, y)) != bg for y in range(h))]
            self.assertTrue(cols, size)                                  # there is text
            self.assertGreaterEqual(cols[0], int(w * 0.04), size)        # and it starts and ends well inside the frame
            self.assertLessEqual(cols[-1], int(w * 0.96), size)

    def assert_text_inside(self, size, text):
        """Every non-background pixel of the card lies inside the picture, with a margin of 4% on all four sides."""
        bg = (4, 24, 31)
        img = mv.card(size, text)
        self.assertEqual(img.size, size)
        box = ImageChops.difference(img, Image.new("RGB", size, bg)).getbbox()
        self.assertIsNotNone(box, (size, text))                          # there is text
        w, h = size
        self.assertGreaterEqual(box[0], int(w * 0.04), (size, text))
        self.assertLessEqual(box[2], int(w * 0.96), (size, text))
        self.assertGreaterEqual(box[1], int(h * 0.04), (size, text))
        self.assertLessEqual(box[3], int(h * 0.96), (size, text))
        return box

    def test_a_title_too_long_for_one_line_is_wrapped_and_still_fits(self):
        title = ("Companion OS: from the USB stick to a ready desktop, installed in one click, "
                 "with nothing to type and nothing to configure first")
        for size in ((1280, 800), (640, 400), (320, 200)):
            self.assert_text_inside(size, title)

    def test_a_wrapped_title_has_more_than_one_line_and_the_short_one_still_has_one(self):
        # a 320 x 200 picture cannot hold this on one line at any size above 6 pixels in a wide font, so it is wrapped: the text block is
        # then taller than one line of the same size would be; the short title stays on one line, as it always did
        short = self.assert_text_inside((320, 200), "Start")
        long_ = self.assert_text_inside((320, 200), "Companion OS: from the USB stick to a ready desktop, installed in one click")
        self.assertLess(short[3] - short[1], 20)                         # one line of about 14 pixels
        self.assertGreater(long_[3] - long_[1], short[3] - short[1])    # two or more lines

    def test_a_single_word_wider_than_the_picture_shrinks_instead_of_overflowing(self):
        self.assert_text_inside((320, 200), "Companion" * 8)              # 72 characters, no space to wrap at

    def test_an_unreadable_frame_is_skipped(self):
        files = self.frames([(0, frame()), (3, frame(color=(0, 90, 120)))])
        bad = os.path.join(self.src, "f-%d.png" % (T0 + 1))
        with open(bad, "wb") as fh:
            fh.write(b"not a png")
        files.insert(1, (T0 + 1, bad))
        self.assertEqual(mv.render(files, self.out, [], [], [], fps=5, hold=0.4), 4)

    def test_every_kept_frame_carries_the_redaction(self):
        red = [(T0, T0 + 100, 0, 0, 1280, 800, None)]
        files = self.frames([(0, frame()), (3, frame(color=(0, 90, 120))), (6, frame())])
        n = mv.render(files, self.out, [], red, [], fps=5, hold=0.4)
        for i in range(n):
            self.assertEqual(Image.open(os.path.join(self.out, "%06d.png" % i)).getpixel((200, 200)), DARK, i)


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg is not installed")
class EndToEndTests(unittest.TestCase):
    def test_a_video_of_the_length_the_frames_call_for(self):
        tmp = tempfile.mkdtemp(prefix="mv-test-")
        try:
            src = os.path.join(tmp, "src"); os.makedirs(src)
            for i, color in enumerate(((255, 255, 255), (0, 90, 120), (255, 255, 255), (120, 0, 90))):
                Image.new("RGB", (320, 200), color).save(os.path.join(src, "f-%d.png" % (T0 + i * 4)))
            ch = write(tmp, "c.txt", "%d | Step one\n" % T0)
            out = os.path.join(tmp, "o.mp4")
            self.assertEqual(mv.main([out, "--frames", src, "--chapters", ch, "--fps", "5", "--hold", "0.4", "--clock"]), 0)
            dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", out],
                                       capture_output=True, text=True, check=True).stdout)
            self.assertAlmostEqual(dur, 4 * 2 / 5, delta=0.25)       # four kept frames, two video frames each, five a second
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_no_frames_is_an_error_and_a_missing_ffmpeg_is_exit_2(self):
        tmp = tempfile.mkdtemp(prefix="mv-test-")
        try:
            ch = write(tmp, "c.txt", "%d | x\n" % T0)
            with self.assertRaises(SystemExit):
                mv.main([os.path.join(tmp, "o.mp4"), "--frames", tmp, "--chapters", ch])
            with mock.patch.object(mv.shutil, "which", return_value=None):
                self.assertEqual(mv.main([os.path.join(tmp, "o.mp4"), "--frames", tmp, "--chapters", ch]), 2)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    res = unittest.main(verbosity=2, exit=False).result
    bad = len(res.failures) + len(res.errors)
    print("== Summary: %d passed, %d failed" % (res.testsRun - bad - len(res.skipped), bad))
    raise SystemExit(0 if res.wasSuccessful() else 1)
