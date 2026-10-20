#!/usr/bin/env python3
"""Test: scripts/release-manifest.py describes exactly the files that get uploaded, and refuses anything that does not fit.

Run: python3 backends/ubuntu/iso/tests/test_release_manifest.py     (stock Python 3, no network, a temporary directory)

The manifest is what a user's installer, a download page and `verify-published.sh` trust, so the checks are on facts: the sha256 and size of every
file are those of the bytes on disk, a SHA256SUMS that disagrees is refused, the upload list is in the order that keeps the pointer last, and a
version, prefix, base URL or file name that could point outside the release is a refusal and not a path.
"""
import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "release-manifest.py")
spec = importlib.util.spec_from_file_location("release_manifest", SCRIPT)
rm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rm)

BASE = "https://dl.ci.computer"


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Release:
    """A directory of build output: 1.0 images for the given arches, and optionally SHA256SUMS, the signature and the SBOM."""

    def __init__(self, arches=("amd64", "arm64"), version="1.0", sums=True, extra=()):
        self.dir = tempfile.mkdtemp(prefix="rm-test-")
        self.data = {}
        for arch in arches:
            name = "companion-os-%s-%s.iso" % (version, arch)
            self.data[name] = ("iso of %s " % arch).encode() * 1000
            with open(os.path.join(self.dir, name), "wb") as fh:
                fh.write(self.data[name])
        if sums:
            with open(os.path.join(self.dir, "SHA256SUMS"), "w") as fh:
                for name, data in sorted(self.data.items()):
                    fh.write("%s  %s\n" % (sha(data), name))
        for name in extra:
            with open(os.path.join(self.dir, name), "w") as fh:
                fh.write("content of %s\n" % name)

    def build(self, **kw):
        args = dict(version="1.0", channel="dev", base_url=BASE, prefix="os", date="2026-10-20T00:00:00Z")
        args.update(kw)
        return rm.build(self.dir, **args)

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.rel = Release(extra=("SHA256SUMS.asc", "SBOM.txt"))
        self.addCleanup(self.rel.cleanup)

    def test_every_hash_and_size_is_that_of_the_bytes_on_disk(self):
        manifest, latest, uploads = self.rel.build()
        for arch in ("amd64", "arm64"):
            iso = manifest["images"][arch]["iso"]
            data = self.rel.data["companion-os-1.0-%s.iso" % arch]
            self.assertEqual((iso["size"], iso["sha256"]), (len(data), sha(data)))
            self.assertEqual(iso["url"], "%s/os/1.0/%s/companion-os-1.0-%s.iso" % (BASE, arch, arch))
        for name in ("SHA256SUMS", "SHA256SUMS.asc", "SBOM.txt"):
            with open(os.path.join(self.rel.dir, name), "rb") as fh:
                data = fh.read()
            self.assertEqual(manifest["files"][name]["sha256"], sha(data))
            self.assertEqual(manifest["files"][name]["url"], "%s/os/1.0/%s" % (BASE, name))

    def test_the_header(self):
        manifest, latest, _ = self.rel.build(repository="companionintelligence/CI-OS", commit="abc1234", run_url="https://github.com/x/actions/runs/1")
        self.assertEqual((manifest["product"], manifest["version"], manifest["channel"], manifest["date"]), ("companion-os", "1.0", "dev", "2026-10-20T00:00:00Z"))
        self.assertEqual(manifest["source"], {"repository": "companionintelligence/CI-OS", "commit": "abc1234", "workflow_run": "https://github.com/x/actions/runs/1"})
        self.assertEqual(latest, {"product": "companion-os", "version": "1.0", "channel": "dev", "date": "2026-10-20T00:00:00Z"})
        self.assertNotIn("source", self.rel.build()[0])                    # nothing is made up when nothing is given

    def test_upload_order_images_then_small_files_then_manifest_then_latest(self):
        manifest, latest, uploads = self.rel.build()
        keys = [k for _, k, _ in uploads]
        self.assertEqual(keys[:2], ["os/1.0/amd64/companion-os-1.0-amd64.iso", "os/1.0/arm64/companion-os-1.0-arm64.iso"])
        self.assertEqual(set(keys[2:]), {"os/1.0/SHA256SUMS", "os/1.0/SHA256SUMS.asc", "os/1.0/SBOM.txt"})
        self.assertEqual(len(keys), 5)                                      # the CLI adds manifest.json and latest.json after these

    def test_content_types(self):
        _, _, uploads = self.rel.build()
        types = {k.rsplit("/", 1)[1]: t for _, k, t in uploads}
        self.assertEqual(types["companion-os-1.0-amd64.iso"], "application/x-iso9660-image")
        self.assertEqual(types["SHA256SUMS.asc"], "application/pgp-signature")
        self.assertEqual(types["SHA256SUMS"], "text/plain")

    def test_one_architecture_is_a_release(self):
        rel = Release(arches=("arm64",))
        self.addCleanup(rel.cleanup)
        manifest, _, uploads = rel.build()
        self.assertEqual(list(manifest["images"]), ["arm64"])
        self.assertEqual(len(uploads), 2)                                   # the image and SHA256SUMS

    def test_it_is_deterministic(self):
        a = json.dumps(self.rel.build()[0], sort_keys=True)
        b = json.dumps(self.rel.build()[0], sort_keys=True)
        self.assertEqual(a, b)


class NotesTests(unittest.TestCase):
    def test_notes_state_the_facts_of_the_manifest(self):
        rel = Release(extra=("SHA256SUMS.asc",))
        self.addCleanup(rel.cleanup)
        manifest, _, _ = rel.build(commit="0123456789abcdef", run_url="https://github.com/x/actions/runs/7", channel="production")
        notes = rm.render_notes(manifest)
        self.assertTrue(notes.startswith("# Companion OS 1.0\n"))                      # production: no "(build)" qualifier
        for arch in ("amd64", "arm64"):
            iso = manifest["images"][arch]["iso"]
            self.assertIn(iso["sha256"], notes)
            self.assertIn(iso["url"], notes)
        self.assertIn("`0123456789ab`", notes)
        self.assertIn("[workflow run](https://github.com/x/actions/runs/7)", notes)
        self.assertIn("gpg --verify SHA256SUMS.asc SHA256SUMS", notes)
        self.assertNotIn("not signed", notes)

    def test_an_unsigned_dev_build_says_so(self):
        rel = Release()
        self.addCleanup(rel.cleanup)
        notes = rm.render_notes(rel.build()[0])
        self.assertTrue(notes.startswith("# Companion OS 1.0 (dev build)\n"))
        self.assertIn("This build is not signed", notes)
        self.assertNotIn("gpg --verify", notes)

    def test_notes_make_no_claim_about_testing_or_hardware(self):
        rel = Release(extra=("SHA256SUMS.asc",))
        self.addCleanup(rel.cleanup)
        notes = rm.render_notes(rel.build()[0]).lower()
        for word in ("tested", "works on", "supported hardware", "certified", "seamless"):
            self.assertNotIn(word, notes)

    def test_sizes_are_human(self):
        self.assertEqual(rm.human_size(5593038848), "5.2 GiB")
        self.assertEqual(rm.human_size(3 * 1024 ** 2), "3.0 MiB")
        self.assertEqual(rm.human_size(12), "12 bytes")

    def test_cli_writes_the_notes(self):
        rel = Release()
        self.addCleanup(rel.cleanup)
        out = tempfile.mkdtemp(prefix="rm-out-")
        self.addCleanup(shutil.rmtree, out, True)
        notes = os.path.join(out, "notes.md")
        with redirect_stdout(io.StringIO()):
            rc = rm.main(["--dir", rel.dir, "--version", "1.0", "--channel", "dev", "--base-url", BASE, "--out-dir", out, "--notes-out", notes])
        self.assertEqual(rc, 0)
        self.assertIn("## Images", open(notes).read())


class RefusalTests(unittest.TestCase):
    def test_sums_that_disagree_with_the_file_are_refused(self):
        rel = Release()
        self.addCleanup(rel.cleanup)
        with open(os.path.join(rel.dir, "SHA256SUMS"), "w") as fh:
            fh.write("%s  companion-os-1.0-amd64.iso\n" % ("0" * 64))
        with self.assertRaises(rm.Problem) as cm:
            rel.build()
        self.assertIn("companion-os-1.0-amd64.iso", str(cm.exception))

    def test_sums_that_leave_out_a_published_image_are_refused(self):
        # two builds on two machines each write a SHA256SUMS of their own image; gathering both images and keeping one of them would publish
        # a release whose checksums cover only one architecture
        rel = Release()
        self.addCleanup(rel.cleanup)
        with open(os.path.join(rel.dir, "SHA256SUMS"), "w") as fh:
            fh.write("%s  companion-os-1.0-arm64.iso\n" % sha(rel.data["companion-os-1.0-arm64.iso"]))
        with self.assertRaises(rm.Problem) as cm:
            rel.build()
        self.assertIn("no line for companion-os-1.0-amd64.iso", str(cm.exception))
        self.assertIn("--make-checksums", str(cm.exception))

    def test_sums_that_list_a_file_that_is_not_published_are_fine(self):
        # the build's own SHA256SUMS may also name the md5 file, a log or an image of another version that is not in the directory
        rel = Release(arches=("arm64",))
        self.addCleanup(rel.cleanup)
        with open(os.path.join(rel.dir, "SHA256SUMS"), "a") as fh:
            fh.write("%s  something-else.txt\n" % ("1" * 64))
        manifest, _latest, _uploads = rel.build()
        self.assertEqual(list(manifest["images"]), ["arm64"])

    def test_no_image_a_wrong_version_and_an_odd_name(self):
        empty = tempfile.mkdtemp(prefix="rm-test-")
        self.addCleanup(shutil.rmtree, empty, True)
        with self.assertRaises(rm.Problem):
            rm.build(empty, "1.0", "dev", BASE, "os")
        rel = Release(version="1.1")
        self.addCleanup(rel.cleanup)
        with self.assertRaises(rm.Problem) as cm:
            rel.build(version="1.0")
        self.assertIn("1.1", str(cm.exception))
        with open(os.path.join(rel.dir, "companion-os-1.1-i386.iso"), "wb") as fh:
            fh.write(b"x")
        with self.assertRaises(rm.Problem):
            rel.build(version="1.1")

    def test_arguments_that_could_point_outside_the_release(self):
        rel = Release()
        self.addCleanup(rel.cleanup)
        for kw in ({"version": "../1.0"}, {"version": "1.0/../x"}, {"version": ""}, {"channel": "staging"}, {"prefix": "../os"}, {"prefix": "/os"},
                   {"prefix": "os/../x"}, {"prefix": "OS"}, {"base_url": "http://dl.ci.computer"}, {"base_url": "https://dl.ci.computer?x=1"},
                   {"base_url": "https://dl.ci.computer/a b"}, {"base_url": ""}):
            with self.assertRaises(rm.Problem, msg=repr(kw)):
                rel.build(**kw)

    def test_good_arguments(self):
        rel = Release(version="1.0-rc1")
        self.addCleanup(rel.cleanup)
        manifest, _, _ = rel.build(version="1.0-rc1", prefix="os/preview", base_url="https://dl.ci.computer/")
        self.assertEqual(manifest["images"]["amd64"]["iso"]["url"], "https://dl.ci.computer/os/preview/1.0-rc1/amd64/companion-os-1.0-rc1-amd64.iso")


class CliTests(unittest.TestCase):
    def test_cli_writes_the_files_and_lists_the_uploads(self):
        rel = Release(extra=("SBOM.txt",))
        self.addCleanup(rel.cleanup)
        out = tempfile.mkdtemp(prefix="rm-out-")
        self.addCleanup(shutil.rmtree, out, True)
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = rm.main(["--dir", rel.dir, "--version", "1.0", "--channel", "production", "--base-url", BASE, "--out-dir", out, "--date", "2026-10-20T00:00:00Z"])
        self.assertEqual(rc, 0)
        lines = [l.split("\t") for l in buf.getvalue().strip().splitlines()]
        self.assertTrue(all(len(l) == 3 for l in lines), lines)             # tab separated: a path with a space stays one field
        self.assertEqual([l[1] for l in lines][-2:], ["os/1.0/manifest.json", "os/latest.json"])
        self.assertEqual(json.load(open(os.path.join(out, "manifest.json")))["channel"], "production")
        self.assertEqual(json.load(open(os.path.join(out, "latest.json")))["version"], "1.0")
        self.assertFalse(os.path.exists(os.path.join(rel.dir, "manifest.json")))   # --out-dir keeps the build output clean

    def test_cli_exit_2_on_a_problem(self):
        empty = tempfile.mkdtemp(prefix="rm-test-")
        self.addCleanup(shutil.rmtree, empty, True)
        err = io.StringIO()
        with redirect_stderr(err):
            rc = rm.main(["--dir", empty, "--version", "1.0", "--channel", "dev", "--base-url", BASE])
        self.assertEqual(rc, 2)
        self.assertIn("release-manifest:", err.getvalue())

    def test_a_path_with_a_space_survives(self):
        rel = Release()
        self.addCleanup(rel.cleanup)
        spaced = os.path.join(tempfile.mkdtemp(prefix="rm-test-"), "out put")
        shutil.copytree(rel.dir, spaced)
        self.addCleanup(shutil.rmtree, os.path.dirname(spaced), True)
        r = subprocess.run([sys.executable, SCRIPT, "--dir", spaced, "--version", "1.0", "--channel", "dev", "--base-url", BASE],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        first = r.stdout.splitlines()[0].split("\t")
        self.assertTrue(first[0].endswith("out put/companion-os-1.0-amd64.iso"), first)


if __name__ == "__main__":
    res = unittest.main(verbosity=2, exit=False).result
    bad = len(res.failures) + len(res.errors)
    print("== Summary: %d passed, %d failed" % (res.testsRun - bad, bad))
    raise SystemExit(0 if res.wasSuccessful() else 1)
