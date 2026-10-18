#!/usr/bin/env python3
"""Unit tests for ci-os-auto-install's disk selection and autoinstall file (no root, no disks touched).

Run: python3 backends/ubuntu/chroot/tests/test_auto_install.py
Needs python3-yaml, which yamllint (check-repo.sh) already needs.
The helper is extensionless, so it is loaded by path.
"""
import ast
import importlib.machinery
import importlib.util
import io
import itertools
import json
import os
import re
import stat
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

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


def write_text(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def read_text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write_fixture(devs):
    fh = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump({"blockdevices": devs}, fh)
    fh.close()
    return fh.name


class Env:
    """Point the helper at a fixture instead of the live system."""

    def __init__(self, devs, cdrom, cmdline="BOOT_IMAGE=/casper/vmlinuz boot=casper quiet splash", backing=None):
        self.devs, self.cdrom, self.cmdline, self.backing = devs, cdrom, cmdline, backing

    def __enter__(self):
        self.path = write_fixture(self.devs)
        self._old = {k: os.environ.get(k) for k in ("CI_OS_AI_LSBLK_JSON", "CI_OS_AI_CDROM_SOURCE", "CI_OS_AI_CMDLINE",
                                                    "CI_OS_AI_LOOP_BACKING")}
        if self.backing is None:
            os.environ.pop("CI_OS_AI_LOOP_BACKING", None)
        else:
            os.environ["CI_OS_AI_LOOP_BACKING"] = self.backing
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


def classify(devs, cdrom, backing=None):
    nodes = ai.flatten(devs)
    return ai.classify(nodes, cdrom, backing)


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

    def test_docker_group_is_appended_to_the_installers_defaults_when_the_image_has_it(self):
        # identity.groups is in the 26.04.1 installer's autoinstall schema as {append: [...]} (keeps the default groups) or
        # {override: [...]} (replaces them): append is the one that cannot take sudo away from the first user.
        cfg = ai.build_autoinstall(self.target, "$6$salt$hash", extra_groups=["docker"])["autoinstall"]
        self.assertEqual(cfg["identity"]["groups"], {"append": ["docker"]})
        self.assertEqual(set(cfg["identity"]), {"realname", "hostname", "username", "password", "groups"})
        self.assertNotIn("override", cfg["identity"]["groups"])

    def test_no_groups_key_without_extra_groups(self):
        cfg = ai.build_autoinstall(self.target, "$6$salt$hash", extra_groups=[])["autoinstall"]
        self.assertNotIn("groups", cfg["identity"])

    def test_extra_groups_default_to_the_groups_this_image_has(self):
        with mock.patch.object(ai.grp, "getgrnam", return_value=object()):
            self.assertEqual(ai.available_extra_groups(), ["docker"])
            cfg = ai.build_autoinstall(self.target, "$6$salt$hash")["autoinstall"]
            self.assertEqual(cfg["identity"]["groups"], {"append": ["docker"]})
        with mock.patch.object(ai.grp, "getgrnam", side_effect=KeyError("docker")):
            # useradd fails on a group the new system lacks, and the new system is a copy of this one: ask for none
            self.assertEqual(ai.available_extra_groups(), [])
            cfg = ai.build_autoinstall(self.target, "$6$salt$hash")["autoinstall"]
            self.assertNotIn("groups", cfg["identity"])

    def test_identity_matches_the_installers_schema(self):
        # autoinstall-schema.json of the 26.04.1 installer: identity allows exactly these keys, requires username,
        # hostname and password, and takes groups as a list or {override|append: list}
        schema_keys = {"realname", "username", "hostname", "password", "groups"}
        cfg = ai.build_autoinstall(self.target, "$6$salt$hash", extra_groups=["docker"])["autoinstall"]
        self.assertTrue(set(cfg["identity"]) <= schema_keys)
        self.assertTrue({"username", "hostname", "password"} <= set(cfg["identity"]))
        groups = cfg["identity"]["groups"]
        self.assertTrue(isinstance(groups, list) or set(groups) <= {"override", "append"})

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


def loopdev(n=0, mounts=("/cdrom",)):
    """The node lsblk prints for a loop device carrying an ISO."""
    return {"name": f"loop{n}", "path": f"/dev/loop{n}", "size": 6 * GB, "type": "loop", "rm": False, "ro": True,
            "hotplug": False, "model": None, "tran": None, "rota": False, "fstype": "iso9660", "label": None,
            "partlabel": None, "mountpoints": list(mounts), "children": []}


class LoopMediumTests(unittest.TestCase):
    """An ISO booted from a FILE (GRUB loopback, iso-scan, Ventoy): the disk that holds the file is the medium."""

    def internal_with_iso(self):
        return disk("sda", 500 * GB, children=[part("sda1", 400 * GB, "ext4", "data", mounts=["/isodevice"])])

    def test_loop_on_an_internal_disk_protects_that_disk(self):
        disks, known = classify([loopdev(), self.internal_with_iso(), nvme()], "/dev/loop0",
                                {"source": "/dev/sda1", "fstype": "ext4"})
        d = by_path(disks)
        self.assertTrue(known)
        self.assertEqual(d["/dev/sda"]["status"], "excluded")
        self.assertEqual(d["/dev/nvme0n1"]["status"], "candidate")

    def test_loop_with_unknown_backing_fails_closed_even_though_isodevice_is_mounted(self):
        disks, known = classify([loopdev(), self.internal_with_iso(), nvme()], "/dev/loop0", None)
        self.assertFalse(known)                                        # the caller refuses
        self.assertEqual(by_path(disks)["/dev/sda"]["status"], "excluded")   # and /isodevice protected it anyway

    def test_loop_in_ram_is_known(self):
        disks, known = classify([loopdev(), nvme()], "/dev/loop0", {"source": "tmpfs", "fstype": "tmpfs"})
        self.assertTrue(known)
        self.assertEqual(by_path(disks)["/dev/nvme0n1"]["status"], "candidate")

    def test_loop_backing_on_a_disk_not_in_lsblk_fails_closed(self):
        _, known = classify([loopdev(), nvme()], "/dev/loop0", {"source": "/dev/sdz9", "fstype": "ext4"})
        self.assertFalse(known)

    def test_loop_via_cli_end_to_end(self):
        buf = io.StringIO()
        with Env([loopdev(), self.internal_with_iso(), nvme()], "/dev/loop0", backing="/dev/sda1 ext4"), redirect_stdout(buf):
            rc = ai.main(["--plan"])
        self.assertEqual(rc, 0)
        self.assertIn("TARGET: Samsung SSD 980", buf.getvalue())
        buf = io.StringIO()
        with Env([loopdev(), self.internal_with_iso(), nvme()], "/dev/loop0", backing=""), redirect_stdout(buf):
            rc = ai.main(["--plan"])
        self.assertEqual(rc, 3)

    def test_isodevice_and_rofs_mounts_protect_a_disk(self):
        for mp in ("/isodevice", "/rofs", "/run/ci-os/x", "/cdrom"):
            d = disk("sdb", 500 * GB, children=[part("sdb1", 400 * GB, "ext4", mounts=[mp])])
            disks, _ = classify([stick(), d], "/dev/sda3")
            self.assertEqual(by_path(disks)["/dev/sdb"]["status"], "excluded", mp)
        d = disk("sdb", 500 * GB, children=[part("sdb1", 400 * GB, "ext4", mounts=["/media/x/photos"])])
        disks, _ = classify([stick(), d], "/dev/sda3")
        self.assertEqual(by_path(disks)["/dev/sdb"]["status"], "candidate")   # an auto-mounted data disk is still a target

    def test_findmnt_source_cleaning(self):
        self.assertEqual(ai.clean_source("/dev/sda3[/casper]\n/dev/sda3\n"), "/dev/sda3")
        self.assertEqual(ai.clean_source("\n\n/dev/sr0\n"), "/dev/sr0")
        self.assertIsNone(ai.clean_source(""))
        self.assertIsNone(ai.clean_source(None))


class ExcludeMoreTests(unittest.TestCase):
    def test_sd_and_emmc_cards_are_excluded(self):
        mmc = disk("mmcblk0", 512 * GB, tran=None)
        disks, _ = classify([stick(), mmc, nvme()], "/dev/sda3")
        self.assertEqual(by_path(disks)["/dev/mmcblk0"]["status"], "excluded")

    def test_thunderbolt_or_usb_bridged_disk_is_excluded_by_sysfs(self):
        ext = nvme("nvme1n1", 2000 * GB)          # lsblk says tran=nvme, rm=0, hotplug=0
        with mock.patch.object(ai, "external_bus", side_effect=lambda name: name == "nvme1n1"):
            disks, _ = classify([stick(), ext, nvme()], "/dev/sda3")
        self.assertEqual(by_path(disks)["/dev/nvme1n1"]["status"], "excluded")
        self.assertEqual(by_path(disks)["/dev/nvme0n1"]["status"], "candidate")

    def test_external_bus_reads_sysfs_path(self):
        with mock.patch.object(ai.os.path, "realpath", return_value="/sys/devices/pci0000:00/0000:00:14.0/usb2/2-1/host6/target6:0:0/block/sdb"):
            self.assertTrue(ai.external_bus("sdb"))
        with mock.patch.object(ai.os.path, "realpath", return_value="/sys/devices/pci0000:00/0000:00:1d.0/nvme/nvme0/nvme0n1"):
            self.assertFalse(ai.external_bus("nvme0n1"))

    def test_exclusion_reasons_are_listed_in_the_error(self):
        buf = io.StringIO()
        with Env([stick()], "/dev/sda3"), redirect_stdout(buf):
            rc = ai.main(["--plan"])
        self.assertEqual(rc, 3)
        self.assertIn("sda: the disk this session started from", buf.getvalue().replace("/dev/", ""))


class DescribeMoreTests(unittest.TestCase):
    def only(self, dev):
        disks, _ = classify([stick(), dev], "/dev/sda3")
        return by_path(disks)["/dev/" + dev["name"]]

    def test_whole_disk_filesystem_is_data(self):
        dev = disk("sdb", 500 * GB)
        dev["fstype"], dev["label"] = "ext4", "Backups"
        head, lines, has_data = ai.describe_disk(self.only(dev))
        self.assertTrue(has_data)
        self.assertTrue(any("whole disk" in line and "Linux (ext4)" in line and "Backups" in line for line in lines))

    def test_raid_luks_lvm_members_are_data(self):
        for fs in ("crypto_LUKS", "LVM2_member", "linux_raid_member", "isw_raid_member", "zfs_member"):
            dev = disk("sdb", 500 * GB)
            dev["fstype"] = fs
            self.assertTrue(ai.describe_disk(self.only(dev))[2], fs)

    def test_partition_with_unrecognised_contents_is_data_and_says_so(self):
        dev = disk("sdb", 500 * GB, children=[part("sdb1", 400 * GB, None)])
        _, lines, has_data = ai.describe_disk(self.only(dev))
        self.assertTrue(has_data)
        self.assertIn("contents not recognised", lines[0])

    def test_non_partition_children_are_listed(self):
        dev = disk("sdb", 500 * GB, children=[{"name": "md0", "path": "/dev/md0", "size": 400 * GB, "type": "raid1", "children": []}])
        _, lines, has_data = ai.describe_disk(self.only(dev))
        self.assertTrue(has_data)
        self.assertTrue(any("md0" in line for line in lines))

    def test_truly_blank_disk(self):
        _, lines, has_data = ai.describe_disk(self.only(disk("sdb", 500 * GB)))
        self.assertFalse(has_data)
        self.assertEqual(lines, [])
        self.assertEqual(ai.summary(self.only(disk("sdb", 500 * GB))), "nothing found")

    def test_markup_escaping(self):
        self.assertEqual(ai.esc("Photos & Backup <x>"), "Photos &amp; Backup &lt;x&gt;")
        self.assertEqual(ai.esc("a\\nb"), "a\\\\nb")          # a literal backslash-n must not become a newline


class DialogTests(unittest.TestCase):
    """zenity is replaced by a recorder: what the dialog asks, and how its answer is read."""

    def setUp(self):
        self.calls = []

    def fake_zenity(self, rc=0, out=""):
        def fz(args, **kw):
            self.calls.append(args)
            return subprocess.CompletedProcess(args, rc, out, "")
        return fz

    def target(self, label="Windows"):
        dev = nvme()
        dev["children"][1]["label"] = label
        disks, _ = classify([stick(), dev], "/dev/sda3")
        return by_path(disks)["/dev/nvme0n1"]

    def test_confirm_defaults_to_cancel_even_for_a_blank_disk(self):
        dev = nvme(with_windows=False)
        disks, _ = classify([stick(), dev], "/dev/sda3")
        with mock.patch.object(ai, "zenity", self.fake_zenity(1, "")):
            self.assertEqual(ai.confirm_dialog(by_path(disks)["/dev/nvme0n1"], "abcd-efgh-jkmn-pqrs", []), "cancel")
        self.assertIn("--default-cancel", self.calls[0])

    def test_confirm_answers(self):
        t = self.target()
        with mock.patch.object(ai, "zenity", self.fake_zenity(0, "")):
            self.assertEqual(ai.confirm_dialog(t, "pw", []), "install")
        with mock.patch.object(ai, "zenity", self.fake_zenity(1, "Use the normal installer\n")):
            self.assertEqual(ai.confirm_dialog(t, "pw", []), "normal")
        with mock.patch.object(ai, "zenity", self.fake_zenity(1, "")):
            self.assertEqual(ai.confirm_dialog(t, "pw", []), "cancel")
        with mock.patch.object(ai, "zenity", self.fake_zenity(255, "")):
            self.assertEqual(ai.confirm_dialog(t, "pw", []), "cancel")           # zenity failing is a Cancel, never an install

    def test_confirm_text_names_the_disk_and_escapes_labels(self):
        t = self.target(label="Photos & <Backup>")
        with mock.patch.object(ai, "zenity", self.fake_zenity(1, "")):
            ai.confirm_dialog(t, "abcd-efgh-jkmn-pqrs", [])
        text = next(a for a in self.calls[0] if a.startswith("--text="))
        self.assertIn("Samsung SSD 980", text)
        self.assertIn("/dev/nvme0n1", text)
        self.assertIn("Photos &amp; &lt;Backup&gt;", text)
        self.assertIn("abcd-efgh-jkmn-pqrs", text)
        self.assertIn("ERASE EVERYTHING", text)

    def test_zenity_environment_cannot_remap_answers(self):
        with mock.patch.dict(os.environ, {"ZENITY_OK": "7", "ZENITY_CANCEL": "0", "DIALOG_OK": "9", "PATH": os.environ["PATH"]}):
            env = ai.zenity_env()
        self.assertNotIn("ZENITY_OK", env)
        self.assertNotIn("ZENITY_CANCEL", env)
        self.assertNotIn("DIALOG_OK", env)
        self.assertIn("PATH", env)

    def test_chooser_not_shown_for_one_disk_and_picks_the_clicked_one_for_several(self):
        a = self.target()
        with mock.patch.object(ai, "zenity", self.fake_zenity(0, "")):
            self.assertIs(ai.choose_disk([a], a), a)
        self.assertEqual(self.calls, [])
        dev2 = disk("sdb", 1000 * GB)
        disks, _ = classify([stick(), nvme(), dev2], "/dev/sda3")
        cands = [d for d in disks if d["status"] == "candidate"]
        with mock.patch.object(ai, "zenity", self.fake_zenity(0, "/dev/sdb\n")):
            self.assertEqual(ai.choose_disk(cands, ai.choose_default(cands))["path"], "/dev/sdb")
        row = [a for a in self.calls[0] if a in ("TRUE", "FALSE")]
        self.assertEqual(row.count("TRUE"), 1)                                  # exactly one preselected
        with mock.patch.object(ai, "zenity", self.fake_zenity(1, "")):
            self.assertIsNone(ai.choose_disk(cands, ai.choose_default(cands)))
        with mock.patch.object(ai, "zenity", self.fake_zenity(0, "/dev/evil\n")):
            self.assertIsNone(ai.choose_disk(cands, ai.choose_default(cands)))   # an answer that is not a candidate is nothing


class InteractiveFlowTests(unittest.TestCase):
    """interactive() with the dialogs and run_install replaced: who gets asked, and what is written."""

    def run_flow(self, dialog_answers, devs=None, **kw):
        devs = devs or [stick(), nvme(), disk("sdb", 1000 * GB)]
        answers = list(dialog_answers)
        runs = []
        with Env(devs, "/dev/sda3"), \
                mock.patch.object(ai, "is_live", return_value=True), \
                mock.patch.object(ai, "take_lock", return_value=True), \
                mock.patch.object(ai.shutil, "which", return_value="/usr/bin/zenity"), \
                mock.patch.object(ai, "hash_password", return_value="$6$x$y"), \
                mock.patch.object(ai, "choose_disk", side_effect=lambda c, d: kw.get("chosen", d)), \
                mock.patch.object(ai, "confirm_dialog", side_effect=lambda *a: answers.pop(0)), \
                mock.patch.object(ai, "error_dialog") as err, \
                mock.patch.object(ai, "normal_installer", return_value=0) as normal, \
                mock.patch.object(ai, "run_install", side_effect=lambda *a: runs.append(a) or 0):
            rc = ai.interactive()
        return rc, runs, normal, err

    def test_cancel_writes_nothing(self):
        rc, runs, normal, _ = self.run_flow(["cancel"])
        self.assertEqual((rc, runs), (6, []))
        normal.assert_not_called()

    def test_normal_installer_writes_nothing(self):
        rc, runs, normal, _ = self.run_flow(["normal"])
        self.assertEqual((rc, runs), (0, []))
        normal.assert_called_once()

    def test_install_runs_with_the_chosen_disk_only(self):
        rc, runs, _, _ = self.run_flow(["install"])
        self.assertEqual(rc, 0)
        self.assertEqual(len(runs), 1)
        d, yaml_text, password = runs[0]
        self.assertEqual(d["path"], "/dev/nvme0n1")
        self.assertIn("path: /dev/nvme0n1", yaml_text)
        self.assertNotIn("/dev/sda", yaml_text.replace("/dev/sdb", ""))
        self.assertNotIn(password, yaml_text)                                 # only the hash is in the file

    def test_user_choice_in_the_chooser_wins_over_the_default(self):
        disks, _ = classify([stick(), nvme(), disk("sdb", 1000 * GB)], "/dev/sda3")
        sdb = by_path(disks)["/dev/sdb"]
        rc, runs, _, _ = self.run_flow(["install"], chosen=sdb)
        self.assertEqual(runs[0][0]["path"], "/dev/sdb")

    def test_disks_changing_after_the_click_aborts_before_any_write(self):
        devs = [stick(), nvme(), disk("sdb", 1000 * GB)]
        later = [stick(), nvme(size=256 * GB), disk("sdb", 1000 * GB)]        # the target is now a different size
        loads = iter([{"blockdevices": devs}, {"blockdevices": later}])
        with Env(devs, "/dev/sda3"), \
                mock.patch.object(ai, "load_lsblk", side_effect=lambda: next(loads)), \
                mock.patch.object(ai, "is_live", return_value=True), \
                mock.patch.object(ai, "take_lock", return_value=True), \
                mock.patch.object(ai.shutil, "which", return_value="/usr/bin/zenity"), \
                mock.patch.object(ai, "hash_password", return_value="$6$x$y"), \
                mock.patch.object(ai, "choose_disk", side_effect=lambda c, d: d), \
                mock.patch.object(ai, "confirm_dialog", return_value="install"), \
                mock.patch.object(ai, "error_dialog") as err, \
                mock.patch.object(ai, "run_install") as run:
            rc = ai.interactive()
        self.assertEqual(rc, 3)
        run.assert_not_called()
        self.assertIn("changed", err.call_args[0][0])

    def test_not_live_and_second_instance_do_nothing(self):
        with Env([stick(), nvme()], "/dev/sda3"), mock.patch.object(ai, "is_live", return_value=False), \
                mock.patch.object(ai, "error_dialog"), mock.patch.object(ai, "run_install") as run:
            self.assertEqual(ai.interactive(), 4)
        with Env([stick(), nvme()], "/dev/sda3"), mock.patch.object(ai, "is_live", return_value=True), \
                mock.patch.object(ai, "take_lock", return_value=False), \
                mock.patch.object(ai, "error_dialog"), mock.patch.object(ai, "run_install") as run:
            self.assertEqual(ai.interactive(), 6)
            run.assert_not_called()

    def test_medium_unknown_offers_no_dialog(self):
        with Env([stick(), nvme()], None), mock.patch.object(ai, "is_live", return_value=True), \
                mock.patch.object(ai, "take_lock", return_value=True), \
                mock.patch.object(ai, "confirm_dialog") as confirm, mock.patch.object(ai, "error_dialog"), \
                mock.patch.object(ai, "run_install") as run:
            self.assertEqual(ai.interactive(), 3)
        confirm.assert_not_called()
        run.assert_not_called()

    def test_unexpected_exception_shows_a_dialog_and_changes_nothing(self):
        with Env([stick(), nvme()], "/dev/sda3"), mock.patch.object(ai, "is_live", return_value=True), \
                mock.patch.object(ai, "take_lock", return_value=True), mock.patch.object(ai.shutil, "which", return_value="/x"), \
                mock.patch.object(ai, "hash_password", side_effect=subprocess.CalledProcessError(1, "openssl")), \
                mock.patch.object(ai, "choose_disk", side_effect=lambda c, d: d), \
                mock.patch.object(ai, "confirm_dialog", return_value="install"), \
                mock.patch.object(ai, "error_dialog") as err, mock.patch.object(ai, "run_install") as run:
            self.assertEqual(ai.main([]), 7)
        run.assert_not_called()
        self.assertIn("Nothing was changed", err.call_args[0][0])


class FakePopen:
    def __init__(self, *a, **k):
        self.lines = []
        self.stdin = self
        self.terminated = False

    def write(self, text):
        self.lines.append(text)

    def flush(self):
        pass

    def terminate(self):
        self.terminated = True


# The states of ApplicationState in the 26.04.1 installer snap (ubuntu-desktop-bootstrap rev 665, subiquity/common/types/__init__.py).
# A state name used by the helper that is not in this list is a bug (POST_WAIT, POST_RUNNING and UU_CANCELLING were).
SUBIQUITY_STATES = ["STARTING_UP", "CLOUD_INIT_WAIT", "EARLY_COMMANDS", "NEEDS_CONFIRMATION", "WAITING", "RUNNING", "UU_RUNNING",
                    "LATE_COMMANDS", "DONE", "ERROR", "EXITED"]


class StateGuardTests(unittest.TestCase):
    """is_busy(): the rule that stops a second click from restarting an installer that is writing a disk."""

    def busy(self, state, target=False, curtin=False):
        with mock.patch.object(ai, "target_in_use", return_value=target), mock.patch.object(ai, "curtin_running", return_value=curtin):
            return ai.is_busy(state)

    def test_the_sets_use_only_states_the_installer_has(self):
        for name in ("STARTUP_STATES", "BUSY_STATES", "IDLE_STATES", "INSTALL_STARTED", "FAILED_STATES"):
            self.assertLessEqual(getattr(ai, name), set(SUBIQUITY_STATES), name)
        self.assertIn(ai.AMBIGUOUS_STATE, SUBIQUITY_STATES)

    def test_every_state_is_accounted_for_exactly_once(self):
        groups = [ai.STARTUP_STATES, ai.BUSY_STATES, ai.IDLE_STATES, {ai.AMBIGUOUS_STATE}]
        union = set().union(*groups)
        self.assertEqual(union, set(SUBIQUITY_STATES))
        self.assertEqual(sum(len(g) for g in groups), len(union), "a state is in two groups")

    def test_the_busy_set_is_exactly_what_the_installer_does_while_it_writes(self):
        self.assertEqual(ai.BUSY_STATES, {"RUNNING", "UU_RUNNING", "LATE_COMMANDS", "DONE"})
        for gone in ("POST_WAIT", "POST_RUNNING", "UU_CANCELLING"):
            self.assertNotIn(gone, ai.BUSY_STATES)
            self.assertNotIn(gone, ai.INSTALL_STARTED)

    def test_busy_states_are_busy_whatever_the_mounts_say(self):
        for state in ("RUNNING", "UU_RUNNING", "LATE_COMMANDS", "DONE"):
            for target in (False, True):
                for curtin in (False, True):
                    self.assertTrue(self.busy(state, target, curtin), f"{state} target={target} curtin={curtin}")

    def test_idle_states_are_idle_whatever_the_mounts_say(self):
        # NEEDS_CONFIRMATION: nothing is written yet. ERROR and EXITED: it stopped; restarting the server is how to retry.
        for state in ("NEEDS_CONFIRMATION", "ERROR", "EXITED"):
            for target in (False, True):
                for curtin in (False, True):
                    self.assertFalse(self.busy(state, target, curtin), f"{state} target={target} curtin={curtin}")

    def test_waiting_is_idle_before_the_install_and_busy_after_curtin(self):
        self.assertFalse(self.busy("WAITING", target=False, curtin=False))      # the installer has just started
        self.assertTrue(self.busy("WAITING", target=True, curtin=False))        # curtin wrote the system and unmounted nothing yet
        self.assertTrue(self.busy("WAITING", target=False, curtin=True))        # curtin is running
        self.assertTrue(self.busy("WAITING", target=True, curtin=True))

    def test_waiting_costs_no_mount_check_for_the_other_states(self):
        with mock.patch.object(ai, "target_in_use", side_effect=AssertionError("asked")), \
                mock.patch.object(ai, "curtin_running", side_effect=AssertionError("asked")):
            self.assertTrue(ai.is_busy("RUNNING"))
            self.assertFalse(ai.is_busy("ERROR"))

    def test_startup_states_and_unknown_states_count_as_busy(self):
        # wait_ready() never hands these to run_install; if one arrives anyway, the server is not touched.
        for state in ("STARTING_UP", "CLOUD_INIT_WAIT", "EARLY_COMMANDS", "POST_WAIT", "POST_RUNNING", "UU_CANCELLING",
                      "SOMETHING_NEW", "", None):
            self.assertTrue(self.busy(state), repr(state))

    def test_wait_ready_skips_the_startup_states(self):
        answers = iter([{"state": "STARTING_UP"}, {"state": "CLOUD_INIT_WAIT"}, {"state": "EARLY_COMMANDS"}, {}, {"state": "WAITING"}])
        with mock.patch.object(ai, "status", side_effect=lambda: next(answers)), mock.patch.object(ai.time, "sleep", lambda s: None):
            self.assertEqual(ai.wait_ready(timeout=60), "WAITING")

    def test_wait_ready_gives_up_without_an_answer(self):
        with mock.patch.object(ai, "status", return_value={}), mock.patch.object(ai.time, "sleep", lambda s: None), \
                mock.patch.object(ai.time, "time", side_effect=itertools.count(0, 50)):
            self.assertIsNone(ai.wait_ready(timeout=100))


class TargetInUseTests(unittest.TestCase):
    """target_in_use() reads the mount table for /target."""

    def check(self, text):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "mountinfo")
            write_text(path, text)
            with mock.patch.object(ai, "MOUNTINFO", path):
                return ai.target_in_use()

    ROOT = "25 1 0:22 / / rw,relatime - overlay overlay rw\n"
    CDROM = "40 25 8:3 / /cdrom ro,relatime - iso9660 /dev/sda3 ro\n"

    def test_the_live_session_alone_is_not_the_target(self):
        self.assertFalse(self.check(self.ROOT + self.CDROM))

    def test_a_mounted_target_is_in_use(self):
        self.assertTrue(self.check(self.ROOT + "90 25 259:2 / /target rw,relatime - ext4 /dev/nvme0n1p2 rw\n"))

    def test_something_mounted_below_the_target_is_in_use(self):
        self.assertTrue(self.check(self.ROOT + "91 25 259:1 / /target/boot/efi rw - vfat /dev/nvme0n1p1 rw\n"))

    def test_look_alikes_are_not_the_target(self):
        self.assertFalse(self.check(self.ROOT + "92 25 0:50 / /targets rw - tmpfs tmpfs rw\n93 25 0:51 / /mnt/target rw - tmpfs tmpfs rw\n"
                                    "94 25 0:52 / /run/target rw - tmpfs tmpfs rw\n"))

    def test_octal_escapes_in_other_mount_points_do_not_confuse_it(self):
        self.assertFalse(self.check(self.ROOT + "95 25 0:53 / /media/ci/My\\040Disk rw - ext4 /dev/sdb1 rw\n"))
        self.assertTrue(self.check(self.ROOT + "96 25 0:54 / /target/home/a\\040b rw - ext4 /dev/nvme0n1p3 rw\n"))

    def test_malformed_lines_are_skipped(self):
        self.assertFalse(self.check("short\n\n" + self.ROOT))

    def test_an_unreadable_mount_table_counts_as_in_use(self):
        with mock.patch.object(ai, "MOUNTINFO", "/nonexistent/mountinfo"):
            self.assertTrue(ai.target_in_use())


class CurtinRunningTests(unittest.TestCase):
    def test_the_pattern_matches_how_the_installer_starts_curtin(self):
        pat = re.compile(ai.CURTIN_PATTERN)
        for cmdline in (
                "/snap/ubuntu-desktop-bootstrap/665/usr/bin/python3.12 -m curtin --showtrace -vvv --set json:reporting={} install /run/c.yaml",
                "/snap/ubuntu-desktop-bootstrap/665/usr/bin/python3.12 /snap/ubuntu-desktop-bootstrap/665/bin/curtin in-target --target=/target -- chage -d 0 companion",
                "curtin in-target --target=/target -- chage -d 0 companion",
                "python3 -m curtin block-meta simple"):
            self.assertTrue(pat.search(cmdline), cmdline)

    def test_the_pattern_leaves_this_tool_and_the_server_alone(self):
        pat = re.compile(ai.CURTIN_PATTERN)
        for cmdline in (
                "/usr/bin/python3 /usr/libexec/ci-os/ci-os-auto-install",
                "/snap/ubuntu-desktop-bootstrap/665/usr/bin/python3.12 -m subiquity.cmd.server --use-os-prober",
                "/snap/ubuntu-desktop-bootstrap/665/bin/ubuntu_bootstrap --try-or-install",
                "vim curtin-notes.txt",
                "less /var/log/installer/curtin_event.123.json",
                "/snap/ubuntu-desktop-bootstrap/665/lib/python3.12/site-packages/curtin/commands/install.py"):
            self.assertFalse(pat.search(cmdline), cmdline)

    def test_pgrep_answers(self):
        with mock.patch.object(ai, "sh", return_value=subprocess.CompletedProcess([], 0, "123\n", "")) as run:
            self.assertTrue(ai.curtin_running())
            self.assertEqual(run.call_args[0][0], ["pgrep", "-f", ai.CURTIN_PATTERN])
        with mock.patch.object(ai, "sh", return_value=subprocess.CompletedProcess([], 1, "", "")):
            self.assertFalse(ai.curtin_running())

    def test_pgrep_that_cannot_run_counts_as_running(self):
        with mock.patch.object(ai, "sh", side_effect=FileNotFoundError("pgrep")):
            self.assertTrue(ai.curtin_running())


class RestartIfIdleTests(unittest.TestCase):
    """After a failure the server is restarted to drop the settings it loaded, unless that would kill an install."""

    def run_it(self, state, target=False, curtin=False):
        restarted = []
        with mock.patch.object(ai, "status", return_value={"state": state} if state else {}), \
                mock.patch.object(ai, "target_in_use", return_value=target), mock.patch.object(ai, "curtin_running", return_value=curtin), \
                mock.patch.object(ai, "restart_server", lambda: restarted.append(1)):
            result = ai.restart_if_idle()
        return result, restarted

    def test_a_server_that_is_installing_is_not_restarted(self):
        for state in ("RUNNING", "UU_RUNNING", "LATE_COMMANDS", "DONE"):
            self.assertEqual(self.run_it(state), (False, []), state)
        self.assertEqual(self.run_it("WAITING", target=True), (False, []))
        self.assertEqual(self.run_it("WAITING", curtin=True), (False, []))

    def test_an_idle_or_failed_server_is_restarted(self):
        for state in ("NEEDS_CONFIRMATION", "ERROR", "EXITED"):
            self.assertEqual(self.run_it(state), (True, [1]), state)
        self.assertEqual(self.run_it("WAITING"), (True, [1]))

    def test_a_server_that_does_not_answer_is_restarted(self):
        self.assertEqual(self.run_it(None), (True, [1]))


class RunInstallTests(unittest.TestCase):
    """run_install with the installer's API, systemd and sudo replaced by recorders."""

    def setUp(self):
        disks, _ = classify([stick(), nvme()], "/dev/sda3")
        self.target = by_path(disks)["/dev/nvme0n1"]
        self.log = []
        self.popen = FakePopen()
        self.errors = []
        self.api_calls = []
        self.waited = []          # the sets of states wait_for() was asked to wait for, in order

    def go(self, states, post_code=200, ready="WAITING", in_the_way=False, disks_ok=True, sudo_ok=True, target_mounted=False,
           curtin=False, slow_install=False):
        """`states`: the installer states, in the order the server reports them. wait_for() polls through them until one is
        in the set it was asked for (as the real one does); status() hands out what is left, one per call.
        `target_mounted`: True/False, or a list of the successive answers of target_in_use() (the last one repeats)."""
        states = list(states)
        mounted = list(target_mounted) if isinstance(target_mounted, (list, tuple)) else [target_mounted]
        asked = []

        def fake_target_in_use():
            asked.append(1)
            return mounted[min(len(asked), len(mounted)) - 1]

        def fake_run(cmd, **kw):
            self.log.append(("run", cmd))
            return subprocess.CompletedProcess(cmd, 0, "", "")

        def fake_sh(cmd, **kw):
            self.log.append(("sh", cmd))
            return subprocess.CompletedProcess(cmd, 0 if sudo_ok or cmd[-1] != "true" else 1, "", "")

        seen = []                                   # the states already handed out; the server stays in the last one

        def fake_wait_for(wanted, timeout, poll=3):
            self.waited.append(set(wanted))
            last = None
            while states:
                last = states.pop(0)
                seen.append(last)
                if last in wanted:
                    return last, {"state": last}
            return last, {}

        def fake_api(method, path, data=None, timeout=20):
            self.api_calls.append((method, path, data))
            return (post_code, "") if method == "POST" else (200, "{}")

        def fake_status():
            if not states:
                return {"state": seen[-1] if seen else "ERROR"}
            seen.append(states[0])
            return {"state": states.pop(0) if len(states) > 1 else states[0]}

        devs = [stick(), nvme()] if disks_ok else [stick(), nvme(size=1)]
        clock = mock.patch.object(ai.time, "time", side_effect=itertools.count(0, 5 * 3600)) if slow_install else mock.patch.object(ai.time, "time", wraps=ai.time.time)
        with Env(devs, "/dev/sda3"), clock, \
                mock.patch.object(ai.subprocess, "run", fake_run), \
                mock.patch.object(ai.subprocess, "Popen", return_value=self.popen), \
                mock.patch.object(ai, "sh", fake_sh), \
                mock.patch.object(ai.time, "sleep", lambda s: None), \
                mock.patch.object(ai, "target_in_use", fake_target_in_use), \
                mock.patch.object(ai, "curtin_running", return_value=curtin), \
                mock.patch.object(ai, "wait_ready", return_value=ready), \
                mock.patch.object(ai, "wait_for", fake_wait_for), \
                mock.patch.object(ai, "status", fake_status), \
                mock.patch.object(ai, "api", fake_api), \
                mock.patch.object(ai, "autoinstall_in_the_way", return_value=in_the_way), \
                mock.patch.object(ai, "remove_autoinstall", lambda: self.log.append(("remove",))), \
                mock.patch.object(ai, "restart_server", lambda: self.log.append(("restart",))), \
                mock.patch.object(ai, "error_dialog", lambda t: self.errors.append(t)), \
                mock.patch.object(ai, "zenity", lambda a, **k: subprocess.CompletedProcess(a, 0, "", "")):
            return ai.run_install(self.target, "autoinstall: {}\n", "abcd-efgh-jkmn-pqrs")

    def wrote(self):
        return any(c[0] == "run" and "tee" in c[1] for c in self.log)

    def restarts(self):
        """How often the server was restarted. A normal run restarts it once, to load the autoinstall file."""
        return self.log.count(("restart",))

    def test_success_confirms_exactly_once_and_cleans_up(self):
        rc = self.go(["NEEDS_CONFIRMATION", "RUNNING", "DONE"])
        self.assertEqual(rc, 0)
        posts = [c for c in self.api_calls if c[0] == "POST"]
        self.assertEqual(posts, [("POST", "/meta/confirm", "/dev/tty1")])
        self.assertIn(("remove",), self.log)
        self.assertTrue(self.popen.terminated)
        self.assertEqual(self.errors, [])

    def test_a_whole_real_run_through_every_state(self):
        # the order install.py reports them, the idle WAITING first and the post-install WAITING in the middle
        rc = self.go(["WAITING", "NEEDS_CONFIRMATION", "RUNNING", "WAITING", "RUNNING", "UU_RUNNING", "LATE_COMMANDS", "DONE"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.errors, [])
        said = " ".join(self.popen.lines)
        for text in ("Installing Companion OS", "Finishing up", "Applying updates"):
            self.assertIn(text, said)
        self.assertEqual(len([c for c in self.api_calls if c[0] == "POST"]), 1)

    def test_the_waits_ask_for_every_state_that_can_follow(self):
        # polling every few seconds can miss a short state, so each wait names ALL the states that mean "past this point"
        self.assertEqual(self.go(["NEEDS_CONFIRMATION", "RUNNING", "DONE"]), 0)
        started = {"RUNNING", "UU_RUNNING", "LATE_COMMANDS", "DONE"}
        failed = {"ERROR", "EXITED"}
        self.assertEqual(self.waited, [{"NEEDS_CONFIRMATION"} | started | failed, started | failed])

    def test_an_install_that_is_already_confirmed_is_followed_not_confirmed_again(self):
        # a kernel command line with the word `autoinstall` skips the confirmation: the server goes straight to RUNNING
        rc = self.go(["RUNNING", "UU_RUNNING", "LATE_COMMANDS", "DONE"])
        self.assertEqual(rc, 0)
        self.assertEqual([c for c in self.api_calls if c[0] == "POST"], [])

    def test_progress_text_keeps_the_sign_in_details(self):
        self.go(["NEEDS_CONFIRMATION", "RUNNING", "DONE"])
        self.assertTrue(self.popen.lines)
        self.assertTrue(all("abcd-efgh-jkmn-pqrs" in line for line in self.popen.lines))
        self.assertTrue(all(line.count("\n") == 1 for line in self.popen.lines))   # one line each: "# text\n"

    def test_busy_installer_is_never_touched(self):
        for busy in ("RUNNING", "UU_RUNNING", "LATE_COMMANDS", "DONE"):
            self.log.clear()
            self.assertEqual(self.go([], ready=busy), 5, busy)
            self.assertFalse(self.wrote(), busy)
            self.assertEqual(self.restarts(), 0, busy)
            self.assertTrue(any("already running" in e for e in self.errors), busy)
            self.errors.clear()

    def test_the_post_install_window_is_busy(self):
        # WAITING after curtin has written the system: the state the old guard missed
        for kw in ({"target_mounted": True}, {"curtin": True}, {"target_mounted": True, "curtin": True}):
            self.log.clear()
            self.assertEqual(self.go([], ready="WAITING", **kw), 5, kw)
            self.assertFalse(self.wrote(), kw)
            self.assertEqual(self.restarts(), 0, kw)
            self.assertEqual(self.api_calls, [], kw)

    def test_unknown_states_are_never_touched(self):
        for odd in ("POST_WAIT", "POST_RUNNING", "UU_CANCELLING", "SOMETHING_NEW", "STARTING_UP"):
            self.log.clear()
            self.assertEqual(self.go([], ready=odd), 5, odd)
            self.assertFalse(self.wrote(), odd)
            self.assertEqual(self.restarts(), 0, odd)

    def test_idle_installers_are_taken_over(self):
        # the installer has just started (WAITING, nothing mounted), is at the confirmation, or stopped after a failure
        for idle in ("WAITING", "NEEDS_CONFIRMATION", "ERROR", "EXITED"):
            self.log.clear()
            self.errors.clear()
            self.assertEqual(self.go(["NEEDS_CONFIRMATION", "RUNNING", "DONE"], ready=idle), 0, idle)
            self.assertTrue(self.wrote(), idle)
            self.assertEqual(self.errors, [], idle)

    def test_installer_not_ready_writes_nothing(self):
        self.assertEqual(self.go([], ready=None), 5)
        self.assertFalse(self.wrote())

    def test_foreign_autoinstall_file_is_not_touched(self):
        self.assertEqual(self.go([], in_the_way=True), 5)
        self.assertFalse(self.wrote())

    def test_no_sudo_writes_nothing(self):
        self.assertEqual(self.go([], sudo_ok=False), 5)
        self.assertFalse(self.wrote())

    def test_disks_changed_at_the_last_moment_never_confirms(self):
        rc = self.go(["NEEDS_CONFIRMATION"], disks_ok=False)
        self.assertEqual(rc, 7)
        self.assertEqual([c for c in self.api_calls if c[0] == "POST"], [])
        self.assertIn("Nothing was erased", self.errors[0])
        self.assertIn(("remove",), self.log)
        self.assertEqual(self.restarts(), 2)        # one to load the settings, one to drop them again

    def test_refused_confirmation_is_a_failure_not_an_hours_long_wait(self):
        rc = self.go(["NEEDS_CONFIRMATION"], post_code=500)
        self.assertEqual(rc, 7)
        self.assertIn("Nothing was erased", self.errors[0])
        self.assertIn(("remove",), self.log)

    def test_error_after_confirmation_says_the_disk_may_be_erased(self):
        rc = self.go(["NEEDS_CONFIRMATION", "RUNNING", "ERROR"])
        self.assertEqual(rc, 7)
        self.assertIn("partly or completely erased", self.errors[0])
        self.assertIn(("remove",), self.log)
        self.assertEqual(self.restarts(), 2)        # ERROR is idle: the second restart drops the loaded settings
        self.assertTrue(self.popen.terminated)

    def test_giving_up_on_a_slow_install_does_not_restart_the_server_under_it(self):
        # the tool stops waiting after 4 hours, but the installer is still RUNNING: a restart would kill curtin mid-write
        rc = self.go(["NEEDS_CONFIRMATION", "RUNNING", "RUNNING"], slow_install=True)
        self.assertEqual(rc, 7)
        self.assertIn("did not finish in 4 hours", self.errors[0])
        self.assertIn("partly or completely erased", self.errors[0])
        self.assertIn(("remove",), self.log)         # our files go: a crash must not leave an autoinstall behind
        self.assertEqual(self.restarts(), 1)         # only the one that loaded the settings

    def test_a_confirmation_that_never_took_effect_restarts_an_idle_server_only(self):
        # after the confirm the server reports WAITING (not a started state): with nothing mounted it is idle and is restarted,
        # with the new system mounted it is installing and is left alone
        rc = self.go(["NEEDS_CONFIRMATION", "WAITING"])
        self.assertEqual(rc, 7)
        self.assertIn("did not start after it was confirmed (state: WAITING)", self.errors[0])
        self.assertEqual(self.restarts(), 2)
        self.log.clear()
        self.errors.clear()
        # not mounted when the tool starts (idle installer), mounted by the time it gives up
        rc = self.go(["NEEDS_CONFIRMATION", "WAITING"], target_mounted=[False, True])
        self.assertEqual(rc, 7)
        self.assertEqual(self.restarts(), 1)

    def test_server_that_rejects_the_settings_is_a_failure_before_any_confirm(self):
        rc = self.go(["ERROR"])
        self.assertEqual(rc, 7)
        self.assertEqual([c for c in self.api_calls if c[0] == "POST"], [])
        self.assertIn("Nothing was erased", self.errors[0])


class AutoinstallFileTests(unittest.TestCase):
    def test_only_our_symlink_counts_as_ours(self):
        with tempfile.TemporaryDirectory() as td:
            ours, link = os.path.join(td, "run", "autoinstall.yaml"), os.path.join(td, "autoinstall.yaml")
            with mock.patch.object(ai, "AUTOINSTALL_PATH", ours), mock.patch.object(ai, "AUTOINSTALL_LINK", link):
                self.assertFalse(ai.autoinstall_in_the_way())                     # nothing there
                os.symlink(ours, link)                                            # ours (dangling after a crash)
                self.assertFalse(ai.autoinstall_in_the_way())
                os.unlink(link)
                write_text(link, "autoinstall: {}\n")                        # somebody else's real file
                self.assertTrue(ai.autoinstall_in_the_way())
                os.unlink(link)
                os.symlink("/etc/hostname", link)                                 # somebody else's symlink
                self.assertTrue(ai.autoinstall_in_the_way())

    def test_remove_never_removes_a_foreign_file(self):
        with tempfile.TemporaryDirectory() as td:
            ours, link = os.path.join(td, "run.yaml"), os.path.join(td, "autoinstall.yaml")
            write_text(link, "theirs\n")
            seen = []
            with mock.patch.object(ai, "AUTOINSTALL_PATH", ours), mock.patch.object(ai, "AUTOINSTALL_LINK", link), \
                    mock.patch.object(ai, "sh", lambda cmd, **k: seen.append(cmd)):
                ai.remove_autoinstall()
            self.assertNotIn(["sudo", "-n", "rm", "-f", link], seen)
            self.assertEqual(read_text(link), "theirs\n")


class EarlyCommandTests(unittest.TestCase):
    """Run the installer-side pin in bash with stub blockdev/findmnt, on the real command text."""

    def run_pin(self, target_path, target_size, real_size, findmnt_out):
        disks, _ = classify([stick(), nvme()], "/dev/sda3")
        t = dict(by_path(disks)["/dev/nvme0n1"], path=target_path, size=target_size)
        with tempfile.TemporaryDirectory() as td:
            for name, body in (("blockdev", f'echo {real_size}'), ("findmnt", f'printf "%s\\n" "{findmnt_out}"')):
                p = os.path.join(td, name)
                with open(p, "w") as fh:
                    fh.write("#!/bin/sh\n" + body + "\n")
                os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
            env = {"PATH": td + ":/usr/bin:/bin"}
            return subprocess.run(["bash", "-c", ai.target_check_command(t)], env=env, capture_output=True, text=True)

    def test_healthy_install_passes(self):
        self.assertEqual(self.run_pin("/dev/nvme0n1", 512 * GB, 512 * GB, "/dev/sda3").returncode, 0)

    def test_size_mismatch_aborts(self):
        r = self.run_pin("/dev/nvme0n1", 512 * GB, 256 * GB, "/dev/sda3")
        self.assertEqual(r.returncode, 1)
        self.assertIn("not the disk that was confirmed", r.stderr)

    def test_target_that_carries_the_medium_aborts(self):
        for src in ("/dev/nvme0n1p3", "/dev/nvme0n1", "/dev/nvme0n1p3[/casper]"):
            r = self.run_pin("/dev/nvme0n1", 512 * GB, 512 * GB, src)
            self.assertEqual(r.returncode, 1, src)
            self.assertIn("carries the install medium", r.stderr)


class LiveSetupTests(unittest.TestCase):
    def run_setup(self, cmdline, cdrom_present=False):
        with tempfile.TemporaryDirectory() as td:
            launcher = os.path.join(td, "launcher.desktop")
            write_text(launcher, "[Desktop Entry]\nName=x\n")
            home = os.path.join(td, "home")
            os.makedirs(home)
            with mock.patch.dict(os.environ, {"HOME": home, "CI_OS_AI_CMDLINE": cmdline}), \
                    mock.patch.object(ai, "LAUNCHER_SRC", launcher), \
                    mock.patch.object(ai.os.path, "exists", side_effect=lambda p: cdrom_present if p == "/cdrom/casper/vmlinuz" else os.path.lexists(p)), \
                    mock.patch.object(ai, "sh") as sh_, \
                    mock.patch.object(ai, "interactive", return_value=0) as inter:
                rc = ai.live_setup()
            placed = sorted(os.path.relpath(os.path.join(r, f), home) for r, _, fs in os.walk(home) for f in fs)
            return rc, placed, inter, sh_

    def test_inert_on_an_installed_system(self):
        rc, placed, inter, sh_ = self.run_setup("BOOT_IMAGE=/boot/vmlinuz root=/dev/nvme0n1p2 ro quiet splash ci.autoinstall=1")
        self.assertEqual((rc, placed), (0, []))
        inter.assert_not_called()
        sh_.assert_not_called()

    def test_live_session_places_the_launcher_but_does_not_start_an_install(self):
        rc, placed, inter, _ = self.run_setup("BOOT_IMAGE=/casper/vmlinuz boot=casper quiet splash ---")
        self.assertEqual(rc, 0)
        self.assertEqual(placed, sorted(["Desktop/ci-os-auto-install.desktop", ".local/share/applications/ci-os-auto-install.desktop"]))
        inter.assert_not_called()

    def test_the_boot_menu_word_opens_the_dialog_and_only_as_a_whole_word(self):
        _, _, inter, _ = self.run_setup("boot=casper ci.autoinstall=1 ---")
        inter.assert_called_once()
        for cmd in ("boot=casper xci.autoinstall=1", "boot=casper ci.autoinstall=10", "boot=casper autoinstall", "boot=casper ci.autoinstall"):
            _, _, inter, _ = self.run_setup(cmd)
            inter.assert_not_called()


class PinToDockTests(unittest.TestCase):
    """The live session of 26.04 has no desktop icons (ding@rastersoft.com is disabled by the live layer): the dock is the place."""

    def run_pin(self, get_out, get_rc=0, set_rc=0, side_effect=None):
        calls = []

        def fake_sh(cmd, **kw):
            calls.append(cmd)
            if cmd[1] == "get":
                return subprocess.CompletedProcess(cmd, get_rc, get_out, "")
            return subprocess.CompletedProcess(cmd, set_rc, "", "")
        with mock.patch.object(ai, "sh", side_effect=side_effect or fake_sh):
            result = ai.pin_to_dock()
        return result, calls

    def test_the_launcher_goes_first_and_the_others_stay(self):
        ok, calls = self.run_pin("['ubuntu-desktop-bootstrap_ubuntu-desktop-bootstrap.desktop', 'firefox_firefox.desktop']\n")
        self.assertTrue(ok)
        self.assertEqual(calls[1], ["gsettings", "set", "org.gnome.shell", "favorite-apps",
                                    "['ci-os-auto-install.desktop', 'ubuntu-desktop-bootstrap_ubuntu-desktop-bootstrap.desktop', 'firefox_firefox.desktop']"])

    def test_already_pinned_changes_nothing(self):
        ok, calls = self.run_pin("['ci-os-auto-install.desktop', 'firefox_firefox.desktop']\n")
        self.assertTrue(ok)
        self.assertEqual(len(calls), 1)          # only the read

    def test_an_empty_list_prints_as_at_as(self):
        ok, calls = self.run_pin("@as []\n")
        self.assertTrue(ok)
        self.assertEqual(calls[1][-1], "['ci-os-auto-install.desktop']")

    def test_failures_are_not_exceptions(self):
        self.assertFalse(self.run_pin("", get_rc=1)[0])                       # no session bus
        self.assertFalse(self.run_pin("garbage (", get_rc=0)[0])               # not a list
        self.assertFalse(self.run_pin("[1, 2]\n")[0])                         # not strings
        self.assertFalse(self.run_pin("['a.desktop']", set_rc=1)[0])           # set refused
        self.assertFalse(self.run_pin("", side_effect=FileNotFoundError("gsettings"))[0])

    def test_live_setup_pins_in_a_live_session_and_only_there(self):
        with tempfile.TemporaryDirectory() as td:
            launcher = os.path.join(td, "launcher.desktop")
            write_text(launcher, "[Desktop Entry]\nName=x\n")
            home = os.path.join(td, "home")
            os.makedirs(home)
            with mock.patch.dict(os.environ, {"HOME": home, "CI_OS_AI_CMDLINE": "boot=casper quiet"}), \
                    mock.patch.object(ai, "LAUNCHER_SRC", launcher), \
                    mock.patch.object(ai.os.path, "exists", side_effect=lambda p: p == "/cdrom/casper/vmlinuz" or os.path.lexists(p)), \
                    mock.patch.object(ai, "sh"), mock.patch.object(ai, "pin_to_dock") as pin:
                self.assertEqual(ai.live_setup(), 0)
                pin.assert_called_once_with()
            with mock.patch.dict(os.environ, {"HOME": home, "CI_OS_AI_CMDLINE": "root=/dev/nvme0n1p2 ro quiet"}), \
                    mock.patch.object(ai, "LAUNCHER_SRC", launcher), \
                    mock.patch.object(ai.os.path, "exists", side_effect=lambda p: False if p == "/cdrom/casper/vmlinuz" else os.path.lexists(p)), \
                    mock.patch.object(ai, "pin_to_dock") as pin:
                self.assertEqual(ai.live_setup(), 0)
                pin.assert_not_called()


class LockTests(unittest.TestCase):
    def test_second_instance_is_refused(self):
        with tempfile.TemporaryDirectory() as td, mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": td}):
            ai._lock_fd = None
            self.assertTrue(ai.take_lock())
            first = ai._lock_fd
            self.assertFalse(ai.take_lock())
            os.close(first)
            ai._lock_fd = None


class ApiTests(unittest.TestCase):
    def test_http_errors_and_unreachable_server(self):
        def fake(code_out):
            return lambda cmd, **k: subprocess.CompletedProcess(cmd, 0, code_out, "")
        with mock.patch.object(ai.subprocess, "run", fake('{"state": "DONE"}\n200')):
            self.assertEqual(ai.api("GET", "/meta/status"), (200, '{"state": "DONE"}'))
            self.assertEqual(ai.status(), {"state": "DONE"})
        with mock.patch.object(ai.subprocess, "run", fake("\n500")):
            self.assertEqual(ai.api("POST", "/meta/confirm", "/dev/tty1")[0], 500)
            self.assertEqual(ai.status(), {})
        with mock.patch.object(ai.subprocess, "run", fake("")):
            self.assertEqual(ai.api("GET", "/meta/status"), (0, ""))
        with mock.patch.object(ai.subprocess, "run", side_effect=OSError):
            self.assertEqual(ai.api("GET", "/meta/status"), (0, ""))


class SourceRulesTests(unittest.TestCase):
    """Properties of the script text that a unit test of the logic cannot see."""

    def setUp(self):
        with open(HELPER, encoding="utf-8") as fh:
            self.src = fh.read()

    def test_no_shell_true_and_no_dd(self):
        self.assertNotIn("shell=True", self.src)
        self.assertNotRegex(self.src, r"\bmkfs\b|\bwipefs\b|\bsgdisk\b|\bparted\b|\bdd\s+if=")

    # Long options in the helper that belong to something other than zenity: its own command line (argparse), curl, blockdev,
    # curtin in-target.
    NOT_ZENITY = {"--plan", "--disks", "--live-setup", "--max-time", "--unix-socket", "--getsize64", "--target"}

    def test_every_zenity_option_exists_in_the_zenity_of_the_image(self):
        # zenity 4.0.1 rejected --class and --name: every dialog, including the confirmation, failed. The list is
        # `zenity --help-all` of zenity 4.2.1-1, the version in the Ubuntu 26.04.1 desktop image.
        with open(os.path.join(HERE, "fixtures", "zenity-4.2.1-options.txt"), encoding="utf-8") as fh:
            known = {line.strip() for line in fh if line.startswith("--")}
        self.assertIn("--radiolist", known)
        self.assertNotIn("--class", known)
        used = set()
        for node in ast.walk(ast.parse(self.src)):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                used.update(re.findall(r"(?<![\w-])--[a-z][a-z0-9-]*", node.value))
        used -= self.NOT_ZENITY
        self.assertTrue({"--question", "--default-cancel", "--list", "--progress", "--pulsate"} <= used)
        self.assertEqual(sorted(used - known), [], "options the image's zenity does not have")
        self.assertNotIn("--class", self.src)
        self.assertNotIn("--name=", self.src)

    def test_no_state_name_that_the_installer_does_not_have(self):
        # every upper-case state name in a string of the helper is one the installer reports
        names = set()
        for node in ast.walk(ast.parse(self.src)):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and re.fullmatch(r"[A-Z][A-Z_]{3,}", node.value):
                names.add(node.value)
        looks_like_state = {n for n in names if n in set(SUBIQUITY_STATES) or n.startswith(("POST_", "UU_", "LATE_")) or n.endswith("_WAIT")}
        self.assertEqual(sorted(looks_like_state - set(SUBIQUITY_STATES)), [])

    def test_the_run_dir_is_made_with_sudo_only(self):
        self.assertNotIn("os.makedirs(RUN_DIR", self.src)                  # /run is root's; the unprivileged user cannot

    def test_curl_never_hides_http_errors(self):
        self.assertIn("%{http_code}", self.src)

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
