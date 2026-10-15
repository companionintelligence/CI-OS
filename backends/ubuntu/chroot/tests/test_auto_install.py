#!/usr/bin/env python3
"""Unit tests for ci-os-auto-install's disk selection and autoinstall file (no root, no disks touched).

Run: python3 backends/ubuntu/chroot/tests/test_auto_install.py
Needs python3-yaml, which yamllint (check-repo.sh) already needs.
The helper is extensionless, so it is loaded by path.
"""
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
# CI_OS_AI_HELPER points the same tests at another copy of the script: verify-iso.sh runs them against the one inside the ISO.
HELPER = os.environ.get("CI_OS_AI_HELPER") or os.path.join(
    HERE, "..", "payload", "live-start", "usr", "libexec", "ci-os", "ci-os-auto-install")
_loader = importlib.machinery.SourceFileLoader("ci_os_auto_install", HELPER)
_spec = importlib.util.spec_from_loader("ci_os_auto_install", _loader)
ai = importlib.util.module_from_spec(_spec)
_loader.exec_module(ai)

GB = 1000 ** 3


def part(name, size, fstype=None, label=None, partlabel=None, mounts=None):
    return {"name": name, "path": "/dev/" + name, "size": size, "type": "part", "rm": False, "ro": False,
            "hotplug": False, "fstype": fstype, "label": label, "partlabel": partlabel,
            "mountpoints": mounts or [None]}


def disk(name, size, *, model="Disk", tran="sata", rm=False, ro=False, hotplug=False, rota=False, children=None):
    return {"name": name, "path": "/dev/" + name, "size": size, "type": "disk", "rm": rm, "ro": ro,
            "hotplug": hotplug, "model": model, "serial": "S-" + name, "tran": tran, "rota": rota,
            "fstype": None, "label": None, "partlabel": None, "mountpoints": [None], "children": children or []}


def stick(name="sda", size=123_942_731_776, mounted=True):
    """A Companion Stick with its GPT layout, booted from (CI-BOOT-A mounted at /cdrom)."""
    return disk(name, size, model="USB DISK 3.0", tran="usb", rm=True, hotplug=True, children=[
        part(name + "1", 512 * 1000 ** 2, "vfat", "CI-EFI", "CI-EFI"),
        part(name + "2", 4 * GB, "exfat", "CI-SHARED", "CI-SHARED"),
        part(name + "3", 8 * GB, "iso9660", "CI-BOOT-A", "CI-BOOT-A", ["/cdrom"] if mounted else None),
        part(name + "4", 8 * GB, "iso9660", "CI-BOOT-B", "CI-BOOT-B"),
        part(name + "5", 73 * 1024 ** 3, "ext4", "CI-CACHE", "CI-CACHE"),
    ])


def nvme(name="nvme0n1", size=512 * GB, with_windows=True):
    kids = [part(name + "p1", 260 * 1000 ** 2, "vfat", "SYSTEM"),
            part(name + "p2", size - 400 * 1000 ** 2, "ntfs", "Windows")] if with_windows else []
    return disk(name, size, model="Samsung SSD 980", tran="nvme", children=kids)


def write_fixture(devs):
    fh = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump({"blockdevices": devs}, fh)
    fh.close()
    return fh.name


class Env:
    """Point the helper at a fixture instead of the live system."""

    def __init__(self, devs, cdrom, cmdline="BOOT_IMAGE=/casper/vmlinuz boot=casper quiet splash"):
        self.devs, self.cdrom, self.cmdline = devs, cdrom, cmdline

    def __enter__(self):
        self.path = write_fixture(self.devs)
        self._old = {k: os.environ.get(k) for k in ("CI_OS_AI_LSBLK_JSON", "CI_OS_AI_CDROM_SOURCE", "CI_OS_AI_CMDLINE")}
        os.environ["CI_OS_AI_LSBLK_JSON"] = self.path
        os.environ["CI_OS_AI_CDROM_SOURCE"] = self.cdrom or ""
        os.environ["CI_OS_AI_CMDLINE"] = self.cmdline
        return self

    def __exit__(self, *a):
        os.unlink(self.path)
        for k, v in self._old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def classify(devs, cdrom):
    nodes = ai.flatten(devs)
    return ai.classify(nodes, cdrom)


def by_path(disks):
    return {d["path"]: d for d in disks}


class SelectionTests(unittest.TestCase):
    def test_stick_boot_never_targets_the_stick(self):
        disks, known = classify([stick(), nvme()], "/dev/sda3")
        self.assertTrue(known)
        d = by_path(disks)
        self.assertEqual(d["/dev/sda"]["status"], "excluded")
        self.assertEqual(d["/dev/nvme0n1"]["status"], "candidate")

    def test_iso_in_cdrom_drive(self):
        sr0 = {"name": "sr0", "path": "/dev/sr0", "size": 6 * GB, "type": "rom", "rm": True, "ro": False, "hotplug": True,
               "model": "QEMU DVD-ROM", "tran": "sata", "rota": True, "fstype": "iso9660", "label": "Companion OS",
               "mountpoints": ["/cdrom"], "children": []}
        disks, known = classify([sr0, disk("vda", 40 * GB, tran="virtio")], "/dev/sr0")
        self.assertTrue(known)
        self.assertEqual([d["path"] for d in disks if d["status"] == "candidate"], ["/dev/vda"])

    def test_boot_medium_unknown_is_refused(self):
        # /cdrom is a loop mount (Ventoy, netboot) or findmnt printed nothing: do not guess.
        disks, known = classify([stick(), nvme()], None)
        self.assertFalse(known)
        disks, known = classify([stick(), nvme()], "/dev/loop9")
        self.assertFalse(known)

    def test_stick_labels_exclude_a_stick_that_was_not_booted_from(self):
        other = stick("sdb", mounted=False)
        # booted from the DVD drive; a second Stick is plugged in
        sr0 = {"name": "sr0", "path": "/dev/sr0", "size": 6 * GB, "type": "rom", "rm": True, "ro": False, "hotplug": True,
               "tran": "sata", "rota": True, "mountpoints": ["/cdrom"], "children": []}
        disks, _ = classify([sr0, other, nvme()], "/dev/sr0")
        self.assertEqual(by_path(disks)["/dev/sdb"]["status"], "excluded")

    def test_only_candidate_filters(self):
        small = disk("sdc", 16 * GB)
        usb_nonrm = disk("sdd", 500 * GB, tran="usb")
        rm = disk("sde", 500 * GB, rm=True)
        hot = disk("sdf", 500 * GB, hotplug=True)
        ro = disk("sdg", 500 * GB, ro=True)
        loop = disk("loop3", 500 * GB)
        loop["path"] = "/dev/loop3"
        good = disk("sdh", 500 * GB)
        disks, _ = classify([stick(), small, usb_nonrm, rm, hot, ro, loop, good], "/dev/sda3")
        d = by_path(disks)
        for p in ("/dev/sda", "/dev/sdc", "/dev/sdd", "/dev/sde", "/dev/sdf", "/dev/sdg", "/dev/loop3"):
            self.assertEqual(d[p]["status"], "excluded", p)
        self.assertEqual(d["/dev/sdh"]["status"], "candidate")

    def test_lsblk_string_booleans(self):
        # Older util-linux prints "1"/"0" strings for RM/RO/HOTPLUG.
        dev = disk("sdb", 500 * GB, rm="1")
        disks, _ = classify([stick(), dev], "/dev/sda3")
        self.assertEqual(by_path(disks)["/dev/sdb"]["status"], "excluded")

    def test_no_internal_disk_means_no_target(self):
        disks, known = classify([stick()], "/dev/sda3")
        self.assertTrue(known)
        self.assertIsNone(ai.choose_default([d for d in disks if d["status"] == "candidate"]))

    def test_default_prefers_nvme_then_ssd_then_largest(self):
        a = disk("sda", 4000 * GB, rota=True)
        b = disk("sdb", 1000 * GB)
        c = nvme("nvme0n1", 500 * GB, with_windows=False)
        disks, _ = classify([stick("sdz"), a, b, c], "/dev/sdz3")
        cand = [d for d in disks if d["status"] == "candidate"]
        self.assertEqual(ai.choose_default(cand)["path"], "/dev/nvme0n1")
        self.assertEqual(ai.choose_default([d for d in cand if d["tran"] != "nvme"])["path"], "/dev/sdb")

    def test_partition_mounted_under_cdrom_protects_its_disk(self):
        d = disk("sdb", 500 * GB, children=[part("sdb1", 400 * GB, "ext4", mounts=["/cdrom/foo"])])
        disks, _ = classify([stick(), d], "/dev/sda3")
        self.assertEqual(by_path(disks)["/dev/sdb"]["status"], "excluded")

    def test_dm_parent_chain_resolves_to_disk(self):
        # /cdrom on a device-mapper node whose parent is the stick partition
        dm = {"name": "dm-0", "path": "/dev/mapper/ventoy", "size": 8 * GB, "type": "dm", "mountpoints": ["/cdrom"], "children": []}
        s = stick(mounted=False)
        s["children"][2]["children"] = [dm]
        disks, known = classify([s, nvme()], "/dev/mapper/ventoy")
        self.assertTrue(known)
        self.assertEqual(by_path(disks)["/dev/sda"]["status"], "excluded")


class DescribeTests(unittest.TestCase):
    def test_windows_disk_has_data_and_is_listed(self):
        disks, _ = classify([stick(), nvme()], "/dev/sda3")
        head, lines, has_data = ai.describe_disk(by_path(disks)["/dev/nvme0n1"])
        self.assertTrue(has_data)
        self.assertIn("Samsung SSD 980", head)
        self.assertIn("/dev/nvme0n1", head)
        self.assertTrue(any("Windows (NTFS)" in line for line in lines))

    def test_blank_disk_has_no_data(self):
        disks, _ = classify([stick(), nvme(with_windows=False)], "/dev/sda3")
        _, lines, has_data = ai.describe_disk(by_path(disks)["/dev/nvme0n1"])
        self.assertFalse(has_data)
        self.assertEqual(lines, [])

    def test_human_sizes(self):
        self.assertEqual(ai.human(512 * GB), "512 GB")
        self.assertEqual(ai.human(1000 * GB), "1.0 TB")
        self.assertEqual(ai.human(4 * 1000 ** 4), "4.0 TB")


class AutoinstallTests(unittest.TestCase):
    def setUp(self):
        disks, _ = classify([stick(), nvme()], "/dev/sda3")
        self.target = by_path(disks)["/dev/nvme0n1"]
        self.cfg = ai.build_autoinstall(self.target, "$6$salt$hash")["autoinstall"]

    def test_targets_exactly_the_chosen_disk(self):
        layout = self.cfg["storage"]["layout"]
        self.assertEqual(layout["name"], "direct")
        self.assertEqual(layout["match"], {"path": "/dev/nvme0n1"})

    def test_no_enhanced_secureboot_and_no_network_surprises(self):
        text = ai.dump_yaml({"autoinstall": self.cfg})
        self.assertNotIn("enhanced-secureboot", text)
        self.assertFalse(self.cfg["refresh-installer"]["update"])
        self.assertFalse(self.cfg["drivers"]["install"])
        self.assertEqual(self.cfg["updates"], "security")

    def test_early_command_pins_size_and_refuses_the_medium(self):
        cmd = self.cfg["early-commands"][0]
        self.assertIn(str(self.target["size"]), cmd)
        self.assertIn("blockdev --getsize64 /dev/nvme0n1", cmd)
        self.assertIn("/cdrom", cmd)
        self.assertIn("exit 1", cmd)

    def test_first_login_forces_password_change_and_cleanup(self):
        late = " ".join(self.cfg["late-commands"])
        self.assertIn("chage -d 0 companion", late)
        self.assertIn("autoinstall.yaml", late)

    def test_plan_masks_the_hash(self):
        text = ai.dump_yaml({"autoinstall": self.cfg}, mask_hash=True)
        self.assertNotIn("$6$", text)
        self.assertIn("not shown", text)

    def test_yaml_roundtrips(self):
        import yaml
        text = ai.dump_yaml({"autoinstall": self.cfg})
        self.assertEqual(yaml.safe_load(text)["autoinstall"]["identity"]["username"], "companion")

    def test_password_shape_and_entropy(self):
        pws = {ai.generate_password() for _ in range(200)}
        self.assertEqual(len(pws), 200)
        for pw in pws:
            self.assertRegex(pw, r"^[a-hj-km-np-z2-9]{4}(-[a-hj-km-np-z2-9]{4}){3}$")
            self.assertNotRegex(pw, r"[01oli]")


class PlanCliTests(unittest.TestCase):
    def run_plan(self, devs, cdrom):
        buf = io.StringIO()
        with Env(devs, cdrom), redirect_stdout(buf):
            rc = ai.main(["--plan"])
        return rc, buf.getvalue()

    def test_plan_on_stick_boot(self):
        rc, out = self.run_plan([stick(), nvme()], "/dev/sda3")
        self.assertEqual(rc, 0)
        self.assertIn("TARGET: Samsung SSD 980", out)
        self.assertIn("HAS DATA: True", out)
        self.assertIn("/dev/sda (the disk this session started from)", out)
        self.assertNotIn("$6$", out)

    def test_plan_refuses_when_medium_unknown(self):
        rc, out = self.run_plan([stick(), nvme()], None)
        self.assertEqual(rc, 3)
        self.assertIn("NO SAFE TARGET", out)

    def test_plan_refuses_when_only_the_stick_exists(self):
        rc, out = self.run_plan([stick()], "/dev/sda3")
        self.assertEqual(rc, 3)

    def test_disks_table(self):
        buf = io.StringIO()
        with Env([stick(), nvme()], "/dev/sda3"), redirect_stdout(buf):
            rc = ai.main(["--disks"])
        self.assertEqual(rc, 0)
        self.assertRegex(buf.getvalue(), r"excluded\s+/dev/sda\b")
        self.assertRegex(buf.getvalue(), r"candidate\s+/dev/nvme0n1")


class SourceRulesTests(unittest.TestCase):
    """Properties of the script text that a unit test of the logic cannot see."""

    def setUp(self):
        with open(HELPER, encoding="utf-8") as fh:
            self.src = fh.read()

    def test_no_shell_true_and_no_dd(self):
        self.assertNotIn("shell=True", self.src)
        self.assertNotRegex(self.src, r"\bmkfs\b|\bwipefs\b|\bsgdisk\b|\bparted\b|\bdd\s+if=")

    def test_password_never_printed(self):
        import ast
        bad = []
        for node in ast.walk(ast.parse(self.src)):
            if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "print":
                names = {n.id for a in node.args for n in ast.walk(a) if isinstance(n, ast.Name)}
                if names & {"password", "pw"}:
                    bad.append(node.lineno)
        self.assertEqual(bad, [], "print() of the password at lines %s" % bad)


if __name__ == "__main__":
    unittest.main(verbosity=2)
