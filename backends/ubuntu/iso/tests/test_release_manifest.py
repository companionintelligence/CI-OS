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


PLASMA_DAY = "2026.10.18"


class Release:
    """A directory of build output: 1.0 images for the given arches, and optionally SHA256SUMS, the signature and the SBOM.
    With edition="plasma" it holds the one Plasma image of the day `version` (default PLASMA_DAY) instead."""

    def __init__(self, arches=("amd64", "arm64"), version=None, sums=True, extra=(), edition="ubuntu"):
        self.dir = tempfile.mkdtemp(prefix="rm-test-")
        self.edition = edition
        self.version = version or (PLASMA_DAY if edition == "plasma" else "1.0")
        self.data = {}
        if edition == "plasma":
            self.base = "companion-os-plasma-%s-x86_64" % self.version
            self.data[self.base + ".iso"] = b"iso of the plasma edition " * 1000
        else:
            for arch in arches:
                self.data["companion-os-%s-%s.iso" % (self.version, arch)] = ("iso of %s " % arch).encode() * 1000
        for name, data in self.data.items():
            with open(os.path.join(self.dir, name), "wb") as fh:
                fh.write(data)
        if sums:
            with open(os.path.join(self.dir, "SHA256SUMS"), "w") as fh:
                for name, data in sorted(self.data.items()):
                    fh.write("%s  %s\n" % (sha(data), name))
        for name in extra:
            with open(os.path.join(self.dir, name), "w") as fh:
                fh.write("content of %s\n" % name)

    def build(self, **kw):
        args = dict(version="1.0", channel="dev", base_url=BASE, prefix="os", date="2026-10-20T00:00:00Z")
        if self.edition == "plasma":
            args.update(version=self.version, prefix="os-plasma", edition="plasma")
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


class PlasmaTests(unittest.TestCase):
    """The Plasma edition: one image named after its build day, that day as the release version, the prefix os-plasma and its own side files."""

    def setUp(self):
        self.base = "companion-os-plasma-%s-x86_64" % PLASMA_DAY
        self.side = (self.base + ".pkgs.txt", self.base + ".build-info")
        self.rel = Release(edition="plasma", extra=("SHA256SUMS.asc",) + self.side)
        self.addCleanup(self.rel.cleanup)

    def test_the_image_is_accepted_and_described_by_its_bytes(self):
        manifest, _, _ = self.rel.build()
        self.assertEqual(list(manifest["images"]), ["x86_64"])
        iso = manifest["images"]["x86_64"]["iso"]
        data = self.rel.data[self.base + ".iso"]
        self.assertEqual((iso["size"], iso["sha256"]), (len(data), sha(data)))
        self.assertEqual(iso["url"], "%s/os-plasma/%s/x86_64/%s.iso" % (BASE, PLASMA_DAY, self.base))

    def test_the_edition_is_in_the_manifest_and_the_feed_and_the_product_is_the_same(self):
        manifest, latest, _ = self.rel.build()
        self.assertEqual((manifest["product"], manifest["edition"], manifest["version"]), ("companion-os", "plasma", PLASMA_DAY))
        self.assertEqual(latest, {"product": "companion-os", "edition": "plasma", "version": PLASMA_DAY, "channel": "dev", "date": "2026-10-20T00:00:00Z"})

    def test_an_ubuntu_release_has_no_edition_key(self):
        rel = Release()
        self.addCleanup(rel.cleanup)
        manifest, latest, _ = rel.build()
        self.assertNotIn("edition", manifest)
        self.assertNotIn("edition", latest)

    def test_the_package_list_and_the_build_record_go_up_beside_the_checksums(self):
        manifest, _, uploads = self.rel.build()
        keys = [k for _, k, _ in uploads]
        self.assertEqual(keys[0], "os-plasma/%s/x86_64/%s.iso" % (PLASMA_DAY, self.base))
        self.assertEqual(keys[1:], ["os-plasma/%s/%s" % (PLASMA_DAY, n) for n in ("SHA256SUMS", "SHA256SUMS.asc") + self.side])
        types = {k.rsplit("/", 1)[1]: t for _, k, t in uploads}
        self.assertEqual([types[n] for n in self.side], ["text/plain", "text/plain"])
        for n in self.side:
            self.assertEqual(manifest["files"][n]["url"], "%s/os-plasma/%s/%s" % (BASE, PLASMA_DAY, n))

    def test_only_the_files_of_this_image_are_side_files(self):
        for stray in ("companion-os-plasma-2026.10.17-x86_64.pkgs.txt", "companion-os-plasma-2026.10.17-x86_64.build-info", "other.pkgs.txt"):
            with open(os.path.join(self.rel.dir, stray), "w") as fh:
                fh.write("not this release\n")
        manifest, _, uploads = self.rel.build()
        self.assertEqual(sorted(manifest["files"]), sorted(("SHA256SUMS", "SHA256SUMS.asc") + self.side))
        self.assertFalse([k for _, k, _ in uploads if "2026.10.17" in k or "other" in k])

    def test_the_ubuntu_edition_does_not_publish_those_files(self):
        rel = Release(arches=("amd64",), extra=("companion-os-1.0-amd64.pkgs.txt", "companion-os-1.0-amd64.build-info"))
        self.addCleanup(rel.cleanup)
        self.assertEqual(sorted(rel.build()[0].get("files", {})), ["SHA256SUMS"])

    def test_the_cli_takes_the_prefix_from_the_edition(self):
        out = tempfile.mkdtemp(prefix="rm-out-")
        self.addCleanup(shutil.rmtree, out, True)
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = rm.main(["--dir", self.rel.dir, "--version", PLASMA_DAY, "--channel", "dev", "--base-url", BASE, "--edition", "plasma", "--out-dir", out])
        self.assertEqual(rc, 0)
        keys = [l.split("\t")[1] for l in buf.getvalue().strip().splitlines()]
        self.assertTrue(all(k.startswith("os-plasma/") for k in keys), keys)
        self.assertEqual(keys[-2:], ["os-plasma/%s/manifest.json" % PLASMA_DAY, "os-plasma/latest.json"])
        self.assertEqual(json.load(open(os.path.join(out, "manifest.json")))["edition"], "plasma")
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = rm.main(["--dir", self.rel.dir, "--version", PLASMA_DAY, "--channel", "dev", "--base-url", BASE, "--edition", "plasma", "--prefix", "os-plasma/preview",
                          "--out-dir", out])
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().strip().splitlines()[-1].split("\t")[1], "os-plasma/preview/latest.json")

    def test_the_cli_default_prefix_of_ubuntu_is_still_os(self):
        rel = Release()
        self.addCleanup(rel.cleanup)
        out = tempfile.mkdtemp(prefix="rm-out-")
        self.addCleanup(shutil.rmtree, out, True)
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = rm.main(["--dir", rel.dir, "--version", "1.0", "--channel", "dev", "--base-url", BASE, "--out-dir", out])
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().strip().splitlines()[-1].split("\t")[1], "os/latest.json")


class EditionRefusalTests(unittest.TestCase):
    """An image of the other edition is a refusal, never a silent skip, and a name that only nearly fits a grammar is not an image."""

    def test_the_other_editions_image_in_the_directory_is_refused(self):
        for edition, other in (("ubuntu", "companion-os-plasma-%s-x86_64.iso" % PLASMA_DAY), ("plasma", "companion-os-1.0-amd64.iso")):
            rel = Release(edition=edition)
            self.addCleanup(rel.cleanup)
            with open(os.path.join(rel.dir, other), "wb") as fh:
                fh.write(b"x")
            with self.assertRaises(rm.Problem, msg=edition) as cm:
                rel.build()
            self.assertIn(other, str(cm.exception))
            self.assertIn("edition", str(cm.exception))

    def test_a_directory_of_one_edition_is_refused_by_the_other(self):
        ubuntu = Release()
        plasma = Release(edition="plasma")
        self.addCleanup(ubuntu.cleanup)
        self.addCleanup(plasma.cleanup)
        with self.assertRaises(rm.Problem):
            ubuntu.build(edition="plasma", version=PLASMA_DAY, prefix="os-plasma")
        with self.assertRaises(rm.Problem):
            plasma.build(edition="ubuntu", version="1.0", prefix="os")

    def test_names_that_nearly_fit_a_grammar_are_refused(self):
        near = (("plasma", PLASMA_DAY, "companion-os-plasma-2026.1.18-x86_64.iso"), ("plasma", PLASMA_DAY, "companion-os-plasma-latest-x86_64.iso"),
                ("plasma", PLASMA_DAY, "companion-os-plasma-%s-amd64.iso" % PLASMA_DAY), ("plasma", PLASMA_DAY, "companion-os-plasma-%s-arm64.iso" % PLASMA_DAY),
                ("plasma", PLASMA_DAY, "companion-os-plasma-%s.iso" % PLASMA_DAY), ("plasma", PLASMA_DAY, "companion-os-plasma-%s-x86_64-old.iso" % PLASMA_DAY),
                ("ubuntu", "1.0", "companion-os-1.0-x86_64.iso"), ("ubuntu", "1.0", "companion-os-1.0-i386.iso"))
        for edition, version, name in near:
            d = tempfile.mkdtemp(prefix="rm-test-")
            self.addCleanup(shutil.rmtree, d, True)
            with open(os.path.join(d, name), "wb") as fh:
                fh.write(b"x")
            with self.assertRaises(rm.Problem, msg="%s %s" % (edition, name)):
                rm.build(d, version, "dev", BASE, "os", edition=edition)

    def test_the_plasma_version_is_the_image_date(self):
        rel = Release(edition="plasma")
        self.addCleanup(rel.cleanup)
        with self.assertRaises(rm.Problem) as cm:
            rel.build(version="1.0")
        self.assertIn(PLASMA_DAY, str(cm.exception))

    def test_an_edition_that_does_not_exist_is_refused(self):
        rel = Release()
        self.addCleanup(rel.cleanup)
        with self.assertRaises(rm.Problem):
            rel.build(edition="nope")
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
            rm.main(["--dir", rel.dir, "--version", "1.0", "--channel", "dev", "--base-url", BASE, "--edition", "nope"])
        self.assertEqual(cm.exception.code, 2)

    def test_the_cli_refuses_a_plasma_directory_without_the_edition(self):
        rel = Release(edition="plasma")
        self.addCleanup(rel.cleanup)
        err = io.StringIO()
        with redirect_stderr(err):
            rc = rm.main(["--dir", rel.dir, "--version", PLASMA_DAY, "--channel", "dev", "--base-url", BASE])
        self.assertEqual(rc, 2)
        self.assertIn("plasma edition", err.getvalue())


class PlasmaNotesTests(unittest.TestCase):
    def setUp(self):
        base = "companion-os-plasma-%s-x86_64" % PLASMA_DAY
        self.rel = Release(edition="plasma", extra=("SHA256SUMS.asc", base + ".pkgs.txt", base + ".build-info"))
        self.addCleanup(self.rel.cleanup)
        self.manifest, _, self.uploads = self.rel.build(channel="production", commit="0123456789abcdef")
        self.notes = rm.render_notes(self.manifest)

    def test_the_first_lines_come_from_the_edition(self):
        self.assertTrue(self.notes.startswith("# Companion OS Plasma edition %s\n" % PLASMA_DAY))
        self.assertIn("Companion OS, Plasma edition (x86-64).", self.notes)
        self.assertIn("`0123456789ab`", self.notes)

    def test_it_says_what_the_checklist_requires_of_this_edition(self):
        self.assertIn("No Secure Boot", self.notes)
        self.assertIn("An online installer", self.notes)
        self.assertIn("Rolling packages", self.notes)                                    # the expiry note of gate 12
        self.assertIn("the date in its file name", self.notes)
        self.assertIn("Turn Secure Boot off", self.notes)

    def test_it_has_none_of_the_ubuntu_text(self):
        for text in ("Install Companion OS (automatic)", "Ubuntu", "26.04", "install-companion-os-usb", "erases one internal disk"):
            self.assertNotIn(text, self.notes)

    def test_the_cachyos_mark_is_nowhere_in_what_is_published(self):
        everything = self.notes + json.dumps(self.manifest) + " ".join(k for _, k, _ in self.uploads)
        self.assertNotIn("cachy", everything.lower())

    def test_it_makes_no_claim_about_testing_or_hardware(self):
        for word in ("tested", "works on", "supported hardware", "certified", "seamless"):
            self.assertNotIn(word, self.notes.lower())

    def test_the_package_list_and_the_build_record_are_linked(self):
        for n in (self.manifest["files"]):
            if n.endswith((".pkgs.txt", ".build-info")):
                self.assertIn(self.manifest["files"][n]["url"], self.notes)
        self.assertIn("## Build record", self.notes)

    def test_a_dev_build_and_an_unsigned_one_say_so(self):
        rel = Release(edition="plasma")
        self.addCleanup(rel.cleanup)
        notes = rm.render_notes(rel.build()[0])
        self.assertTrue(notes.startswith("# Companion OS Plasma edition %s (dev build)\n" % PLASMA_DAY))
        self.assertIn("This build is not signed", notes)
        self.assertNotIn("## Build record", notes)                                      # no record files in this directory: nothing is linked

    def test_the_ubuntu_notes_keep_their_install_text(self):
        rel = Release()
        self.addCleanup(rel.cleanup)
        notes = rm.render_notes(rel.build()[0])
        self.assertIn("Companion OS on Ubuntu 26.04.1 LTS.", notes)
        self.assertIn("choose **Install Companion OS (automatic)**", notes)
        self.assertNotIn("Secure Boot", notes)


if __name__ == "__main__":
    res = unittest.main(verbosity=2, exit=False).result
    bad = len(res.failures) + len(res.errors)
    print("== Summary: %d passed, %d failed" % (res.testsRun - bad, bad))
    raise SystemExit(0 if res.wasSuccessful() else 1)
