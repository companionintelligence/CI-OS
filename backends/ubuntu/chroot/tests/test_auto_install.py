#!/usr/bin/env python3
"""Unit tests for ci-os-auto-install's disk selection and autoinstall file (no root, no disks touched).

Run: python3 backends/ubuntu/chroot/tests/test_auto_install.py
Needs python3-yaml, which yamllint (check-repo.sh) already needs.
The helper is extensionless, so it is loaded by path.
"""
import ast
import importlib.machinery
import importlib.util
import http.server
import io
import itertools
import json
import os
import re
import shutil
import socketserver
import stat
import subprocess
import tempfile
import threading
import unittest
import urllib.parse
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

    # The top-level keys of the 26.04.1 installer's autoinstall schema (autoinstall-schema.json of ubuntu-desktop-bootstrap rev 665).
    SCHEMA_KEYS = {"active-directory", "apt", "codecs", "debconf-selections", "drivers", "early-commands", "error-commands", "identity",
                   "interactive-sections", "kernel", "kernel-crash-dumps", "keyboard", "late-commands", "locale", "network", "oem",
                   "packages", "proxy", "refresh-installer", "reporting", "shutdown", "snaps", "source", "ssh", "storage", "timezone",
                   "ubuntu-advantage", "ubuntu-pro", "updates", "user-data", "version", "zdevs"}

    def test_the_document_is_a_complete_non_interactive_autoinstall(self):
        # server.py: `interactive` = bool(autoinstall["interactive-sections"]); any section named there needs a client to answer it,
        # and a server with no client waits for ever. 'autoinstall' must also be the only top-level key (_read_config).
        doc = ai.build_autoinstall(self.target, "$6$salt$hash")
        self.assertEqual(list(doc), ["autoinstall"])
        self.assertNotIn("interactive-sections", self.cfg)
        self.assertEqual(self.cfg["version"], 1)
        self.assertLessEqual(set(self.cfg), self.SCHEMA_KEYS, "a key the installer's schema does not have")
        self.assertEqual(ai.dump_yaml(doc).count("interactive"), 0)

    def test_the_machine_powers_off_when_the_install_is_done(self):
        # shutdown.py: not interactive + DONE -> initiate_poweroff() for `poweroff` (reboot is the default of the installer)
        self.assertEqual(self.cfg["shutdown"], "poweroff")
        self.assertIn(self.cfg["shutdown"], ("reboot", "poweroff"))

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
                mock.patch.object(ai, "load_region_data", return_value=region_data()), \
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


ISO_639 = {"639-3": [
    {"alpha_3": "deu", "alpha_2": "de", "name": "German"}, {"alpha_3": "eng", "alpha_2": "en", "name": "English"},
    {"alpha_3": "spa", "alpha_2": "es", "name": "Spanish"}, {"alpha_3": "fra", "alpha_2": "fr", "name": "French"},
    {"alpha_3": "por", "alpha_2": "pt", "name": "Portuguese"}, {"alpha_3": "zho", "alpha_2": "zh", "name": "Chinese"},
    {"alpha_3": "ast", "name": "Asturian"}]}
ISO_3166 = {"3166-1": [
    {"alpha_2": "US", "name": "United States"}, {"alpha_2": "GB", "name": "United Kingdom"}, {"alpha_2": "DE", "name": "Germany"},
    {"alpha_2": "AT", "name": "Austria"}, {"alpha_2": "FR", "name": "France"}, {"alpha_2": "ES", "name": "Spain"},
    {"alpha_2": "MX", "name": "Mexico"}, {"alpha_2": "BR", "name": "Brazil"}, {"alpha_2": "TW", "name": "Taiwan, Province of China",
                                                                                "common_name": "Taiwan"}]}
BASE_LST = """! model
  pc105           Generic 105-key PC
! layout
  us              English (US)
  gb              English (UK)
  de              German
  fr              French
  es              Spanish
  latam           Spanish (Latin American)
  br              Portuguese (Brazil)
  at              German (Austria)
  ca              French (Canada)
  it              Italian
  be              Belgian
  ch              German (Switzerland)
  custom          A user-defined custom Layout
! variant
  intl            us: English (US, intl., with dead keys)
! option
  grp             Switching to another layout
"""
ZONE_TAB_TEXT = """# tzdata zone.tab
DE\t+5230+01322\tEurope/Berlin\tmost of Germany
DE\t+4742+00841\tEurope/Busingen\tBusingen
FR\t+4852+00220\tEurope/Paris
US\t+404251-0740023\tAmerica/New_York\tEastern (most areas)
US\t+415100-0873900\tAmerica/Chicago\tCentral (most areas)
AR\t-3436-05827\tAmerica/Argentina/Buenos_Aires\tBuenos Aires (BA, CF)
bad line without tabs
"""
LOCALE_A = "C\nC.utf8\nde_DE.utf8\nde_AT.utf8\nen_AG\nen_AG.utf8\nen_US.utf8\nes_MX.utf8\nPOSIX\nzh_TW.utf8\nast_ES.utf8\n"


class RegionFiles:
    """Fixture files and `locale -a` in place of the live system's."""

    def __init__(self, with_files=True, locale_a=LOCALE_A):
        self.with_files, self.locale_a = with_files, locale_a

    def __enter__(self):
        self.dir = tempfile.mkdtemp(prefix="ci-os-region-")
        paths = {n: os.path.join(self.dir, n) for n in ("iso_639-3.json", "iso_3166-1.json", "base.lst", "zone.tab")}
        if self.with_files:
            for name, body in (("iso_639-3.json", json.dumps(ISO_639)), ("iso_3166-1.json", json.dumps(ISO_3166)),
                               ("base.lst", BASE_LST), ("zone.tab", ZONE_TAB_TEXT)):
                with open(paths[name], "w", encoding="utf-8") as fh:
                    fh.write(body)
        self.patches = [
            mock.patch.object(ai, "ISO_639_JSON", paths["iso_639-3.json"]), mock.patch.object(ai, "ISO_3166_JSON", paths["iso_3166-1.json"]),
            mock.patch.object(ai, "XKB_BASE_LST", paths["base.lst"]), mock.patch.object(ai, "ZONE_TAB", paths["zone.tab"]),
            mock.patch.object(ai, "sh", return_value=subprocess.CompletedProcess(["locale", "-a"], 0, self.locale_a, ""))]
        for p in self.patches:
            p.start()
        return self

    def __exit__(self, *a):
        for p in self.patches:
            p.stop()
        shutil.rmtree(self.dir, ignore_errors=True)


def region_data():
    with RegionFiles():
        return ai.load_region_data()


class RegionValueTests(unittest.TestCase):
    """What may be written into the autoinstall file."""

    def test_good_values(self):
        for loc, lay, tz in (("en_US.UTF-8", "us", "geoip"), ("de_DE.UTF-8", "de", "Europe/Berlin"), ("zh_TW.UTF-8", "tw", "UTC"),
                             ("es_MX.UTF-8", "latam", "America/Argentina/Buenos_Aires"), ("ast_ES.UTF-8", "es", "Etc/GMT+1")):
            ai.check_region(loc, lay, tz)

    def test_bad_values_are_refused(self):
        good = ("en_US.UTF-8", "us", "geoip")
        for i, bad in ((0, "en_US"), (0, "en_US.UTF-8\nfoo: bar"), (0, "C.UTF-8"), (0, "../../x"), (0, ""), (1, "US"), (1, "u s"),
                       (1, "us;rm"), (1, ""), (2, "europe/berlin"), (2, "Europe/Berlin; rm -rf /"), (2, "Europe/../x"), (2, "/etc/passwd"),
                       (2, "Berlin"), (2, "")):
            args = list(good)
            args[i] = bad
            with self.assertRaises(ValueError, msg=repr(args)):
                ai.check_region(*args)

    def test_normalize_locale(self):
        self.assertEqual(ai.normalize_locale("de_DE.utf8"), "de_DE.UTF-8")
        self.assertEqual(ai.normalize_locale("de_DE.UTF-8"), "de_DE.UTF-8")
        self.assertEqual(ai.normalize_locale("  en_US.utf8\n"), "en_US.UTF-8")
        for no in ("C", "C.utf8", "POSIX", "en_AG", "de_DE.ISO-8859-1", "de_DE@euro", "", None):
            self.assertIsNone(ai.normalize_locale(no), repr(no))

    def test_build_autoinstall_takes_the_three_answers(self):
        disks, _ = classify([stick(), nvme()], "/dev/sda3")
        cfg = ai.build_autoinstall(by_path(disks)["/dev/nvme0n1"], "$6$x$y", locale="de_DE.UTF-8", layout="de",
                                   timezone="Europe/Berlin")["autoinstall"]
        self.assertEqual((cfg["locale"], cfg["keyboard"], cfg["timezone"]),
                         ("de_DE.UTF-8", {"layout": "de"}, "Europe/Berlin"))
        dflt = ai.build_autoinstall(by_path(disks)["/dev/nvme0n1"], "$6$x$y")["autoinstall"]
        self.assertEqual((dflt["locale"], dflt["keyboard"], dflt["timezone"]), ("en_US.UTF-8", {"layout": "us"}, "geoip"))
        with self.assertRaises(ValueError):
            ai.build_autoinstall(by_path(disks)["/dev/nvme0n1"], "$6$x$y", timezone="x\ny: z")

    def test_a_hostile_value_never_reaches_the_yaml(self):
        disks, _ = classify([stick(), nvme()], "/dev/sda3")
        with self.assertRaises(ValueError):
            ai.build_autoinstall(by_path(disks)["/dev/nvme0n1"], "$6$x$y", locale="en_US.UTF-8\nlate-commands: [rm]")


class RegionDataTests(unittest.TestCase):
    def test_locales_are_the_generated_utf8_ones_once(self):
        with RegionFiles():
            self.assertEqual(ai.generated_locales(),
                             ["de_DE.UTF-8", "de_AT.UTF-8", "en_AG.UTF-8", "en_US.UTF-8", "es_MX.UTF-8", "zh_TW.UTF-8", "ast_ES.UTF-8"])

    def test_locale_command_failing_leaves_english(self):
        with RegionFiles():
            with mock.patch.object(ai, "sh", return_value=subprocess.CompletedProcess([], 1, "", "boom")):
                self.assertEqual(ai.generated_locales(), [])
                self.assertEqual(ai.load_region_data()["locales"], [("English (United States)", "en_US.UTF-8")])

    def test_names_come_from_iso_codes(self):
        d = region_data()
        self.assertIn(("German (Germany)", "de_DE.UTF-8"), d["locales"])
        self.assertIn(("German (Austria)", "de_AT.UTF-8"), d["locales"])
        self.assertIn(("Chinese (Taiwan)", "zh_TW.UTF-8"), d["locales"])               # common_name wins
        self.assertIn(("Asturian (Spain)", "ast_ES.UTF-8"), d["locales"])               # a three-letter language code
        self.assertIn(("English (United States)", "en_US.UTF-8"), d["locales"])
        self.assertEqual([l for l, _ in d["locales"]], sorted((l for l, _ in d["locales"]), key=str.casefold))

    def test_unknown_names_fall_back_to_the_code(self):
        with RegionFiles(with_files=False):
            d = ai.load_region_data()
        self.assertIn(("de_DE.UTF-8", "de_DE.UTF-8"), d["locales"])
        self.assertEqual(ai.locale_label("de_XX.UTF-8", {"de": "German"}, {}), "German")

    def test_layouts_come_from_the_layout_section_only(self):
        d = region_data()
        self.assertEqual({c for _, c in d["layouts"]}, {"us", "gb", "de", "fr", "es", "latam", "br", "at", "ca", "it", "be", "ch"})
        self.assertIn(("German (Austria)", "at"), d["layouts"])
        self.assertNotIn("intl", {c for _, c in d["layouts"]})
        self.assertNotIn("pc105", {c for _, c in d["layouts"]})
        self.assertNotIn("custom", {c for _, c in d["layouts"]})                  # xkb's placeholder, not a layout

    def test_zones_are_named_by_city_and_country(self):
        d = region_data()
        labels = dict(d["zones"])
        self.assertEqual(d["zones"][0][1], "geoip")
        self.assertEqual(d["zones"][1], ("UTC (no region)", "UTC"))
        self.assertEqual(labels["Berlin, Germany"], "Europe/Berlin")
        self.assertEqual(labels["New York, United States"], "America/New_York")
        self.assertEqual(labels["Buenos Aires"], "America/Argentina/Buenos_Aires")      # no country name for AR in the fixture: the city alone
        self.assertEqual(d["by_country"]["DE"], ["Europe/Berlin", "Europe/Busingen"])
        self.assertNotIn("bad line without tabs", labels)

    def test_missing_files_still_give_a_usable_list(self):
        with RegionFiles(with_files=False, locale_a=""):
            d = ai.load_region_data()
        self.assertEqual(d["locales"], [("en_US.UTF-8", "en_US.UTF-8")])
        self.assertEqual(d["layouts"], [("English (US)", "us")])
        self.assertEqual([c for _, c in d["zones"]], ["geoip", "UTC"])
        self.assertEqual(d["by_country"], {})

    def test_every_listed_code_is_acceptable_to_the_installer(self):
        d = region_data()
        for _, code in d["locales"]:
            ai.check_region(code, "us", "geoip")
        for _, code in d["layouts"]:
            ai.check_region("en_US.UTF-8", code, "geoip")
        for _, code in d["zones"]:
            ai.check_region("en_US.UTF-8", "us", code)


class RegionSuggestionTests(unittest.TestCase):
    def setUp(self):
        self.d = region_data()

    def layout(self, loc):
        return ai.suggest_layout(loc, self.d["layouts"])

    def test_keyboard_follows_the_language(self):
        for loc, want in (("en_US.UTF-8", "us"), ("en_GB.UTF-8", "gb"), ("en_AU.UTF-8", "us"), ("en_CA.UTF-8", "us"),
                          ("de_DE.UTF-8", "de"), ("de_AT.UTF-8", "at"), ("de_IT.UTF-8", "de"), ("it_IT.UTF-8", "it"), ("de_CH.UTF-8", "ch"),
                          ("fr_BE.UTF-8", "be"), ("fr_FR.UTF-8", "fr"),
                          ("fr_CA.UTF-8", "ca"), ("es_ES.UTF-8", "es"), ("es_MX.UTF-8", "latam"), ("es_US.UTF-8", "latam"),
                          ("pt_BR.UTF-8", "br"), ("zh_CN.UTF-8", "us"), ("xx_YY.UTF-8", "us")):
            self.assertEqual(self.layout(loc), want, loc)

    def test_a_suggested_layout_always_exists(self):
        codes = {c for _, c in self.d["layouts"]}
        for _, loc in self.d["locales"]:
            self.assertIn(self.layout(loc), codes)

    def test_time_zone_only_when_the_country_has_exactly_one(self):
        self.assertEqual(ai.suggest_zone("fr_FR.UTF-8", self.d["by_country"]), "Europe/Paris")
        self.assertEqual(ai.suggest_zone("de_DE.UTF-8", self.d["by_country"]), "geoip")       # Berlin and Busingen
        self.assertEqual(ai.suggest_zone("en_US.UTF-8", self.d["by_country"]), "geoip")
        self.assertEqual(ai.suggest_zone("zh_TW.UTF-8", self.d["by_country"]), "geoip")       # not in the table


class RegionChangeTests(unittest.TestCase):
    def setUp(self):
        self.d = region_data()

    def test_start_is_the_one_click_default(self):
        r = ai.new_region()
        self.assertEqual((r["locale"], r["layout"], r["timezone"]), ("en_US.UTF-8", "us", "geoip"))
        self.assertEqual(r["touched"], set())
        with self.assertRaises(ValueError):
            ai.new_region(timezone="nope")

    def test_choosing_a_language_suggests_keyboard_and_time_zone(self):
        r = ai.change_region(ai.new_region(), "locale", "fr_FR.UTF-8", self.d)
        self.assertEqual((r["locale"], r["layout"], r["timezone"]), ("fr_FR.UTF-8", "fr", "Europe/Paris"))
        back = ai.change_region(r, "locale", "en_US.UTF-8", self.d)
        self.assertEqual((back["layout"], back["timezone"]), ("us", "geoip"))                # untouched: they follow again

    def test_what_the_user_chose_by_hand_is_kept(self):
        r = ai.change_region(ai.new_region(), "layout", "gb", self.d)
        r = ai.change_region(r, "timezone", "America/New_York", self.d)
        r = ai.change_region(r, "locale", "fr_FR.UTF-8", self.d)
        self.assertEqual((r["locale"], r["layout"], r["timezone"]), ("fr_FR.UTF-8", "gb", "America/New_York"))

    def test_change_does_not_modify_the_old_region(self):
        old = ai.new_region()
        ai.change_region(old, "locale", "de_DE.UTF-8", self.d)
        self.assertEqual((old["locale"], old["layout"], old["touched"]), ("en_US.UTF-8", "us", set()))

    def test_unknown_field_and_bad_value(self):
        with self.assertRaises(ValueError):
            ai.change_region(ai.new_region(), "hostname", "x", self.d)
        with self.assertRaises(ValueError):
            ai.change_region(ai.new_region(), "timezone", "not a zone", self.d)

    def test_describe(self):
        self.assertEqual(ai.describe_region(ai.new_region(), self.d),
                         "English (United States), keyboard: English (US), time zone: detected automatically")
        r = ai.change_region(ai.new_region(), "locale", "de_DE.UTF-8", self.d)
        r = ai.change_region(r, "timezone", "Europe/Berlin", self.d)
        self.assertEqual(ai.describe_region(r, self.d), "German (Germany), keyboard: German, time zone: Berlin, Germany")
        self.assertEqual(ai.describe_region(ai.new_region(), self.d), ai.DEFAULT_REGION_TEXT)


class RegionDialogTests(unittest.TestCase):
    """The language, keyboard and time zone dialogs: what they ask, and how each answer is read."""

    def setUp(self):
        self.calls = []
        self.d = region_data()

    def scripted(self, *answers):
        left = list(answers)

        def fz(args, **kw):
            self.calls.append(args)
            rc, out = left.pop(0)
            return subprocess.CompletedProcess(args, rc, out, "")
        return fz

    def test_confirmation_has_the_region_button_and_names_the_choice(self):
        disks, _ = classify([stick(), nvme()], "/dev/sda3")
        t = by_path(disks)["/dev/nvme0n1"]
        with mock.patch.object(ai, "zenity", self.scripted((1, ai.BTN_REGION + "\n"))):
            self.assertEqual(ai.confirm_dialog(t, "abcd-efgh-jkmn-pqrs", [], "German (Germany), keyboard: German, time zone: Berlin"),
                             "region")
        args = self.calls[0]
        self.assertIn("--extra-button=" + ai.BTN_REGION, args)
        self.assertIn("--extra-button=" + ai.BTN_NORMAL, args)
        self.assertIn("--default-cancel", args)                                  # Enter still never erases
        text = next(a for a in args if a.startswith("--text="))
        self.assertIn("German (Germany), keyboard: German, time zone: Berlin", text)
        self.assertIn(ai.BTN_REGION, text)

    def test_confirmation_answers(self):
        disks, _ = classify([stick(), nvme()], "/dev/sda3")
        t = by_path(disks)["/dev/nvme0n1"]
        for (rc, out), want in (((0, ""), "install"), ((1, ai.BTN_NORMAL + "\n"), "normal"), ((1, ai.BTN_REGION + "\n"), "region"),
                                ((1, ""), "cancel"), ((-9, ""), "cancel"), ((0, "x"), "install")):
            with mock.patch.object(ai, "zenity", self.scripted((rc, out))):
                self.assertEqual(ai.confirm_dialog(t, "pw", []), want, (rc, out))

    def test_button_labels_are_plain_ascii(self):
        # a launcher without a UTF-8 locale must not turn the label into something the answer no longer matches
        self.assertTrue(ai.BTN_REGION.isascii() and ai.BTN_NORMAL.isascii())

    def test_pick_one_reads_the_code_and_refuses_anything_else(self):
        rows = self.d["layouts"]
        with mock.patch.object(ai, "zenity", self.scripted((0, "de\n"))):
            self.assertEqual(ai.pick_one("Keyboard", "Now: English (US)", rows), "de")
        args = self.calls[0]
        self.assertEqual(args[args.index("German") + 1], "de")                   # name, then code
        self.assertIn("--hide-column=2", args)
        self.assertIn("--print-column=2", args)
        for rc, out in ((1, "de\n"), (0, ""), (0, "xx\n"), (0, "German\n")):
            with mock.patch.object(ai, "zenity", self.scripted((rc, out))):
                self.assertIsNone(ai.pick_one("Keyboard", "t", rows), (rc, out))

    def test_menu_changes_one_setting_at_a_time_and_keeps_the_rest(self):
        z = self.scripted((0, "Language\n"), (0, "de_DE.UTF-8\n"),      # language: German
                          (0, "Time zone\n"), (0, "Europe/Berlin\n"),   # time zone: Berlin
                          (1, ""))                                      # Done
        with mock.patch.object(ai, "zenity", z):
            r = ai.choose_region(ai.new_region(), self.d)
        self.assertEqual((r["locale"], r["layout"], r["timezone"]), ("de_DE.UTF-8", "de", "Europe/Berlin"))
        menu_after_language = self.calls[2]
        self.assertIn("German (Germany)", menu_after_language)
        self.assertIn("German", menu_after_language)                           # the keyboard row followed
        self.assertIn("Detect automatically (needs the internet)", self.calls[0])
        self.assertIn("--cancel-label=Done", self.calls[0])

    def test_back_and_done_keep_the_answers(self):
        start = ai.new_region()
        with mock.patch.object(ai, "zenity", self.scripted((1, ""))):
            self.assertIs(ai.choose_region(start, self.d), start)
        with mock.patch.object(ai, "zenity", self.scripted((0, "Language\n"), (1, ""), (1, ""))):   # Back out of the list, then Done
            self.assertEqual(ai.choose_region(start, self.d)["locale"], "en_US.UTF-8")

    def test_an_empty_or_unknown_menu_answer_asks_again(self):
        with mock.patch.object(ai, "zenity", self.scripted((0, ""), (0, "Hostname\n"), (1, ""))):
            self.assertEqual(ai.choose_region(ai.new_region(), self.d)["locale"], "en_US.UTF-8")
        self.assertEqual(len(self.calls), 3)

    def test_titles_and_text_are_escaped(self):
        rows = [("Tom & <Jerry>", "us")]
        with mock.patch.object(ai, "zenity", self.scripted((1, ""))):
            ai.pick_one("Keyboard", "Now: A & B", rows)
        text = next(a for a in self.calls[0] if a.startswith("--text="))
        self.assertIn("A &amp; B", text)


class RegionFlowTests(unittest.TestCase):
    """interactive() with the region menu in the loop."""

    def run_flow(self, answers, region_after=None):
        devs = [stick(), nvme()]
        answers = list(answers)
        seen, runs = [], []

        def confirm(target, password, others, text=ai.DEFAULT_REGION_TEXT):
            seen.append((password, text))
            return answers.pop(0)
        with Env(devs, "/dev/sda3"), RegionFiles(), \
                mock.patch.object(ai, "is_live", return_value=True), mock.patch.object(ai, "take_lock", return_value=True), \
                mock.patch.object(ai.shutil, "which", return_value="/usr/bin/zenity"), \
                mock.patch.object(ai, "hash_password", return_value="$6$x$y"), \
                mock.patch.object(ai, "choose_disk", side_effect=lambda c, d: d), \
                mock.patch.object(ai, "confirm_dialog", side_effect=confirm), \
                mock.patch.object(ai, "choose_region", side_effect=lambda r, d: region_after or r), \
                mock.patch.object(ai, "error_dialog"), mock.patch.object(ai, "normal_installer", return_value=0), \
                mock.patch.object(ai, "run_install", side_effect=lambda *a: runs.append(a) or 0):
            rc = ai.interactive()
        return rc, seen, runs

    def german(self):
        d = region_data()
        r = ai.change_region(ai.new_region(), "locale", "de_DE.UTF-8", d)
        return ai.change_region(r, "timezone", "Europe/Berlin", d)

    def test_without_a_change_the_install_is_english_us_geoip(self):
        rc, seen, runs = self.run_flow(["install"])
        self.assertEqual(len(seen), 1)
        self.assertEqual(seen[0][1], ai.DEFAULT_REGION_TEXT)
        self.assertIn("locale: en_US.UTF-8", runs[0][1])
        self.assertIn("layout: us", runs[0][1])
        self.assertIn("timezone: geoip", runs[0][1])

    def test_the_region_button_asks_again_with_the_same_password_and_installs_the_new_answers(self):
        rc, seen, runs = self.run_flow(["region", "install"], region_after=self.german())
        self.assertEqual(rc, 0)
        self.assertEqual(len(seen), 2)
        self.assertEqual(seen[0][0], seen[1][0])                                  # the one-time password does not change
        self.assertIn("German (Germany)", seen[1][1])
        self.assertIn("time zone: Berlin, Germany", seen[1][1])
        self.assertEqual(len(runs), 1)
        y = runs[0][1]
        self.assertIn("locale: de_DE.UTF-8", y)
        self.assertRegex(y, r"keyboard:\n    layout: de\n")
        self.assertIn("timezone: Europe/Berlin", y)
        self.assertNotIn(runs[0][2], y)

    def test_cancel_and_normal_after_a_change_install_nothing(self):
        for last, want in (("cancel", 6), ("normal", 0)):
            rc, seen, runs = self.run_flow(["region", last], region_after=self.german())
            self.assertEqual((rc, runs), (want, []), last)

    def test_the_menu_can_be_opened_again_and_again(self):
        rc, seen, runs = self.run_flow(["region", "region", "region", "install"])
        self.assertEqual((rc, len(seen), len(runs)), (0, 4, 1))

    def test_cli_values_start_the_dialog_and_the_plan(self):
        buf = io.StringIO()
        with Env([stick(), nvme()], "/dev/sda3"), RegionFiles(), redirect_stdout(buf):
            rc = ai.main(["--plan", "--locale", "de_DE.UTF-8", "--keyboard", "de", "--timezone", "Europe/Berlin"])
        out = buf.getvalue()
        self.assertEqual(rc, 0)
        self.assertIn("LANGUAGE, KEYBOARD, TIME ZONE: German (Germany), keyboard: German, time zone: Berlin, Germany", out)
        self.assertIn("locale: de_DE.UTF-8", out)
        self.assertIn("timezone: Europe/Berlin", out)

    def test_bad_cli_values_are_refused_before_anything_happens(self):
        for argv in (["--locale", "english"], ["--keyboard", "US layout"], ["--timezone", "Mars/Olympus; rm"]):
            err = io.StringIO()
            with mock.patch.object(ai, "interactive") as inter, mock.patch("sys.stderr", err):
                self.assertEqual(ai.main(argv), 2, argv)
            inter.assert_not_called()
            self.assertIn("ci-os-auto-install:", err.getvalue())


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


class FakeClock:
    """Virtual time: sleep() moves the clock, so a ten-minute wait costs nothing and its length can be asserted."""

    def __init__(self, start=1_000_000.0):
        self.start = self.now = start

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds
        if self.elapsed > 2 * 86400:                  # a wait that is not bounded fails the test instead of hanging the suite
            raise AssertionError("the helper was still waiting after two days of virtual time")

    @property
    def elapsed(self):
        return self.now - self.start


# What the real server reports, in order, for an install that goes well (server/controllers/install.py; observed in its dry-run mode,
# backends/ubuntu/chroot/tests/oneclick-subiquity-dryrun.sh): the second WAITING is the window between curtin and the post-install
# work, which the first revision of the helper did not know about.
PREPARE_OK = ["EARLY_COMMANDS", "WAITING", "WAITING", "NEEDS_CONFIRMATION"]
AFTER_OK = ["RUNNING", "WAITING", "RUNNING", "UU_RUNNING", "LATE_COMMANDS", "DONE"]
TTY_TEXT_500 = ('Traceback (most recent call last):\n  File "/snap/ubuntu-desktop-bootstrap/665/bin/subiquity/subiquity/common/api/server.py", '
                'line 156, in handler\n    raise TypeError(\'missing required argument "{}"\'.format(arg))\n'
                'TypeError: missing required argument "tty"\n')


class FakeServer:
    """The installer's server, as the 26.04.1 snap (ubuntu-desktop-bootstrap rev 665) behaves. Read in its code and run in its dry-run mode.

      * GET /meta/status answers {"state", "interactive", "log_syslog_id": "subiquity_log.<pid>", ...}. `interactive` is False when the
        server was started while our autoinstall file was in place and True when it found none (server.py load_autoinstall_config); it
        is None until the server has read the file.
      * POST /meta/confirm takes `tty` from the QUERY string, JSON-encoded. A JSON body, or no tty, is HTTP 500 with a TypeError. The
        server does not look at its own state: a confirmation sent too early is kept (so the helper must send it at the right time).
      * a restart is a NEW process (new log_syslog_id) that starts its script from the top; it is interactive unless the file is there.

    `before`: the script of the server of the live session, which is running when the helper starts. `plans`: one (prepare, after) pair per
    restart: `prepare` is what the new server reports until it is confirmed, `after` what it reports from the accepted confirmation on.
    A script is a list; every GET /meta/status takes the next entry and the last entry repeats. An entry is a state name, a dict of
    status fields (with "state"), or None (the server does not answer)."""

    STARTING = ("STARTING_UP", "CLOUD_INIT_WAIT")

    def __init__(self, before=("WAITING",), plans=None, confirm_code=200, confirm_body="null", confirm_takes_effect=None,
                 reads_file=True, restart_works=True, restart_accepted=True, stock_interactive=True):
        self.pid = 1000
        self.plans = list(plans) if plans is not None else [(PREPARE_OK, AFTER_OK)]
        self.confirm_code, self.confirm_body = confirm_code, confirm_body
        self.confirm_takes_effect = (confirm_code == 200) if confirm_takes_effect is None else confirm_takes_effect
        self.reads_file, self.restart_works, self.restart_accepted = reads_file, restart_works, restart_accepted
        self.file_written = False
        self.restarts = 0
        self.posts = []             # (state the server was last seen in, JSON body, query) of every POST /meta/confirm
        self.requests = []
        self.instance = self._new(before, [], stock_interactive)

    def _new(self, script, after, interactive):
        self.pid += 1
        return {"pid": self.pid, "script": list(script), "after": list(after), "i": 0, "interactive": interactive, "last": None}

    def restart(self):
        """systemctl restart: True when systemd accepts it."""
        self.restarts += 1
        if not self.restart_accepted:
            return False
        if self.restart_works:
            prepare, after = self.plans[min(self.restarts - 1, len(self.plans) - 1)]
            self.instance = self._new(prepare, after, interactive=not (self.file_written and self.reads_file))
        return True

    def api(self, method, path, data=None, timeout=20, query=None):
        self.requests.append((method, path, data, query))
        inst = self.instance
        if (method, path) == ("GET", "/meta/status"):
            entry = inst["script"][min(inst["i"], len(inst["script"]) - 1)]
            inst["i"] += 1
            inst["last"] = entry["state"] if isinstance(entry, dict) else entry
            if entry is None:
                return 0, ""
            fields = dict(entry) if isinstance(entry, dict) else {"state": entry}
            body = {"state": fields["state"], "confirming_tty": "", "error": None, "nonreportable_error": None, "cloud_init_ok": True,
                    "interactive": None if fields["state"] in self.STARTING else inst["interactive"],
                    "echo_syslog_id": f"subiquity_echo.{inst['pid']}", "log_syslog_id": f"subiquity_log.{inst['pid']}",
                    "event_syslog_id": f"subiquity_event.{inst['pid']}"}
            body.update(fields)
            return 200, json.dumps(body)
        if (method, path) == ("POST", "/meta/confirm"):
            self.posts.append((inst["last"], data, query))
            if data is not None or not query or "tty" not in query:
                return 500, TTY_TEXT_500
            if self.confirm_takes_effect and inst["after"]:
                inst["script"], inst["i"] = list(inst["after"]), 0
            return self.confirm_code, self.confirm_body
        raise AssertionError(f"the helper asked the installer for {method} {path}")


class installer_world:
    """The helper talks to `server` instead of the installer's socket, and time is the fake clock's."""

    def __init__(self, server, clock=None):
        self.server, self.clock = server, clock or FakeClock()

    def __enter__(self):
        self._patches = [mock.patch.object(ai, "api", self.server.api), mock.patch.object(ai.time, "time", self.clock.time),
                         mock.patch.object(ai.time, "sleep", self.clock.sleep)]
        for p in self._patches:
            p.start()
        return self.clock

    def __exit__(self, *a):
        for p in reversed(self._patches):
            p.stop()


class RestartIfIdleTests(unittest.TestCase):
    """After a failure the server is restarted to drop the settings it loaded, unless that would kill an install."""

    def run_it(self, state, target=False, curtin=False, restart_ok=True):
        restarted = []
        with mock.patch.object(ai, "status", return_value={"state": state} if state else {}), \
                mock.patch.object(ai, "target_in_use", return_value=target), mock.patch.object(ai, "curtin_running", return_value=curtin), \
                mock.patch.object(ai, "restart_server", lambda: restarted.append(1) or restart_ok):
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

    def test_a_restart_that_systemd_refuses_is_reported_as_not_restarted(self):
        self.assertEqual(self.run_it("ERROR", restart_ok=False), (False, [1]))


class RestartServerTests(unittest.TestCase):
    def test_the_answer_is_systemds(self):
        for rc, expected in ((0, True), (1, False)):
            with mock.patch.object(ai, "sh", return_value=subprocess.CompletedProcess([], rc, "", "")) as sh:
                self.assertEqual(ai.restart_server(), expected)
            self.assertEqual(sh.call_args[0][0], ["sudo", "-n", "systemctl", "restart", ai.SERVER_UNIT])


class ConfirmRequestTests(unittest.TestCase):
    """POST /meta/confirm: the request the real server accepts, and only when it is waiting for it."""

    def confirm(self, server):
        with installer_world(server):
            return ai.confirm_install()

    def test_the_request_is_the_one_the_real_client_sends(self):
        # subiquity/client/client.py: `await self.client.meta.confirm.POST(self.our_tty)` = POST /meta/confirm?tty="/dev/tty1", no body
        srv = FakeServer(before=("NEEDS_CONFIRMATION",), stock_interactive=False)
        self.assertEqual(self.confirm(srv), (True, None))
        self.assertEqual(srv.posts, [("NEEDS_CONFIRMATION", None, {"tty": "/dev/tty1"})])

    def test_the_first_revision_of_the_request_is_what_the_real_server_refused(self):
        # the tty as a JSON body: HTTP 500 `missing required argument "tty"`, observed on the first real run (and in the dry run)
        srv = FakeServer(before=("NEEDS_CONFIRMATION",), stock_interactive=False)
        code, body = srv.api("POST", "/meta/confirm", "/dev/tty1")
        self.assertEqual(code, 500)
        self.assertIn('missing required argument "tty"', body)
        self.assertEqual(srv.api("POST", "/meta/confirm", query={"tty": "/dev/tty1"})[0], 200)

    def test_it_is_sent_in_needs_confirmation_and_in_no_other_state(self):
        for state in SUBIQUITY_STATES:
            if state == "NEEDS_CONFIRMATION":
                continue
            srv = FakeServer(before=(state,), stock_interactive=False)
            sent, problem = self.confirm(srv)
            self.assertEqual(srv.posts, [], state)
            self.assertFalse(sent, state)
            self.assertIn(f"state: {state}", problem)

    def test_it_is_not_sent_to_a_server_in_interactive_mode(self):
        # a server that did not read our file, or one a person is clicking through: its answers are not ours to confirm
        for flag in (True, None):
            srv = FakeServer(before=({"state": "NEEDS_CONFIRMATION", "interactive": flag},), stock_interactive=True)
            sent, problem = self.confirm(srv)
            self.assertEqual((srv.posts, sent), ([], False), flag)
            self.assertIn("not waiting for the confirmation", problem)

    def test_a_500_on_which_the_server_went_on_anyway_counts_as_confirmed(self):
        srv = FakeServer(before=("NEEDS_CONFIRMATION",), stock_interactive=False,
                         confirm_code=500, confirm_body=TTY_TEXT_500, confirm_takes_effect=True)
        srv.instance["after"] = list(AFTER_OK)
        self.assertEqual(self.confirm(srv), (True, None))

    def test_a_500_that_changed_nothing_is_a_refusal_with_the_servers_own_words(self):
        srv = FakeServer(before=("NEEDS_CONFIRMATION",), stock_interactive=False, confirm_code=500, confirm_body=TTY_TEXT_500)
        sent, problem = self.confirm(srv)
        self.assertFalse(sent)                                # the server said no and is still waiting: the disk is untouched
        self.assertIn("HTTP 500", problem)
        self.assertIn('missing required argument "tty"', problem)

    def test_no_answer_at_all_may_still_have_been_delivered(self):
        srv = FakeServer(before=("NEEDS_CONFIRMATION",), stock_interactive=False, confirm_code=0, confirm_body="")
        sent, problem = self.confirm(srv)
        self.assertTrue(sent)                                 # honest about the disk: we cannot say it was not started
        self.assertIn("HTTP 0", problem)


class WaitForConfirmationTests(unittest.TestCase):
    """What the helper does after the restart, state by state."""

    def wait(self, server, old=None, timeout=600):
        with installer_world(server) as clock:
            return ai.wait_for_confirmation(timeout, old), clock.elapsed

    def test_it_waits_through_waiting_for_the_confirmation_state(self):
        srv = FakeServer(before=PREPARE_OK, stock_interactive=False)
        (outcome, state, _), _ = self.wait(srv)
        self.assertEqual((outcome, state), ("confirm", "NEEDS_CONFIRMATION"))

    def test_startup_states_are_waited_out(self):
        srv = FakeServer(before=["STARTING_UP", "CLOUD_INIT_WAIT", None, "EARLY_COMMANDS", "WAITING", "NEEDS_CONFIRMATION"], stock_interactive=False)
        (outcome, _, _), _ = self.wait(srv)
        self.assertEqual(outcome, "confirm")

    def test_a_server_that_stays_in_waiting_is_given_up_on_at_the_time_limit(self):
        # automatic mode, but it never gets to the confirmation: bounded, and the last state is reported
        srv = FakeServer(before=["WAITING"], stock_interactive=False)
        (outcome, state, _), elapsed = self.wait(srv)
        self.assertEqual((outcome, state), ("timeout", "WAITING"))
        self.assertGreaterEqual(elapsed, 600)
        self.assertLess(elapsed, 600 + 2 * ai.POLL_SECONDS)

    def test_waiting_in_interactive_mode_is_recognised_at_once(self):
        srv = FakeServer(before=["EARLY_COMMANDS", "WAITING"], stock_interactive=True)
        (outcome, state, st), elapsed = self.wait(srv)
        self.assertEqual((outcome, state, st["interactive"]), ("ignored", "WAITING", True))
        self.assertLess(elapsed, 3 * ai.POLL_SECONDS)

    def test_the_confirmation_state_in_interactive_mode_is_not_ours(self):
        srv = FakeServer(before=["WAITING", "NEEDS_CONFIRMATION"], stock_interactive=True)
        (outcome, _, _), _ = self.wait(srv)
        self.assertEqual(outcome, "ignored")

    def test_error_and_exited_are_failures_not_waits(self):
        for state in ("ERROR", "EXITED"):
            srv = FakeServer(before=["EARLY_COMMANDS", state], stock_interactive=False)
            (outcome, got, _), elapsed = self.wait(srv)
            self.assertEqual((outcome, got), ("failed", state))
            self.assertLess(elapsed, 3 * ai.POLL_SECONDS)

    def test_a_server_that_is_already_installing_is_followed_not_confirmed(self):
        for state in ("RUNNING", "UU_RUNNING", "LATE_COMMANDS", "DONE"):
            srv = FakeServer(before=[state], stock_interactive=False)
            (outcome, got, _), _ = self.wait(srv)
            self.assertEqual((outcome, got), ("started", state))

    def test_the_answers_of_the_server_that_was_running_before_the_restart_do_not_count(self):
        # restart accepted but nothing happened (or the old process is still shutting down): same pid, same instance id
        srv = FakeServer(before=["NEEDS_CONFIRMATION"], stock_interactive=False, restart_works=False)
        old = ai.instance_of(json.loads(srv.api("GET", "/meta/status")[1]))
        (outcome, state, _), elapsed = self.wait(srv, old=old)
        self.assertEqual((outcome, state), ("timeout", None))
        self.assertGreaterEqual(elapsed, 600)
        # without the instance check the stale answer would be taken for the new server's
        srv2 = FakeServer(before=["NEEDS_CONFIRMATION"], stock_interactive=False, restart_works=False)
        (outcome2, _, _), _ = self.wait(srv2, old=None)
        self.assertEqual(outcome2, "confirm")

    def test_the_new_server_after_a_restart_is_accepted(self):
        srv = FakeServer(before=["NEEDS_CONFIRMATION"], stock_interactive=False)
        old = ai.instance_of(json.loads(srv.api("GET", "/meta/status")[1]))
        srv.file_written = True
        srv.restart()
        (outcome, _, st), _ = self.wait(srv, old=old)
        self.assertEqual(outcome, "confirm")
        self.assertNotEqual(ai.instance_of(st), old)

    def test_the_texts_name_the_state_and_the_reason(self):
        self.assertIn("state WAITING", ai.not_ready_text("ignored", "WAITING", {}))
        self.assertIn("interactive", ai.not_ready_text("ignored", "WAITING", {}))
        self.assertIn("10 minutes", ai.not_ready_text("timeout", "WAITING", {}))
        self.assertIn("still in state WAITING", ai.not_ready_text("timeout", "WAITING", {}))
        self.assertIn("did not answer", ai.not_ready_text("timeout", None, {}))
        failed = ai.not_ready_text("failed", "ERROR", {"nonreportable_error": {"cause": "AutoinstallUserSuppliedCmdError", "message": "x"}})
        self.assertIn("state: ERROR", failed)
        self.assertIn("the disk is still the one you confirmed", failed)
        other = ai.error_detail({"nonreportable_error": {"cause": "SomethingElse", "message": "m" * 500}})
        self.assertIn("SomethingElse", other)
        self.assertLess(len(other), 200)
        self.assertEqual(ai.error_detail({"error": {"kind": "UNKNOWN", "base": "1792.unknown"}}), "; UNKNOWN, crash report 1792.unknown")
        self.assertEqual(ai.error_detail({}), "")


class FollowInstallTests(unittest.TestCase):
    """follow_install: RUNNING ... DONE, ERROR, EXITED, silence."""

    def follow(self, script):
        srv = FakeServer(before=script, stock_interactive=False)
        said = []
        with installer_world(srv) as clock:
            try:
                ai.follow_install(said.append)
                result = None
            except RuntimeError as exc:
                result = str(exc)
        return result, said, clock.elapsed

    def test_a_whole_install_ends_at_done(self):
        result, said, _ = self.follow(AFTER_OK)
        self.assertIsNone(result)
        text = " ".join(said)
        for expected in ("Installing Companion OS", "Finishing up", "Applying updates"):
            self.assertIn(expected, text)
        self.assertEqual(said.count(ai.PROGRESS_TEXT["WAITING"]), 2)           # WAITING, then LATE_COMMANDS: both "Finishing up"

    def test_done_is_the_only_success(self):
        for last in ("ERROR", "EXITED"):
            result, _, _ = self.follow(["RUNNING", "UU_RUNNING", last])
            self.assertIsNotNone(result, last)

    def test_error_says_why_in_the_installers_words(self):
        failed = {"state": "ERROR", "nonreportable_error": {"cause": "AutoinstallUserSuppliedCmdError", "message": "x"}}
        result, _, _ = self.follow(["RUNNING", failed])
        self.assertIn("the install failed", result)
        self.assertIn("the disk is still the one you confirmed", result)

    def test_exited_before_done_is_a_failure(self):
        result, _, _ = self.follow(["RUNNING", "LATE_COMMANDS", "EXITED"])
        self.assertIn("exited before the installation was finished", result)

    def test_a_server_that_goes_quiet_for_long_is_a_failure_a_short_silence_is_not(self):
        result, _, elapsed = self.follow(["RUNNING", "LATE_COMMANDS", None])
        self.assertIn("stopped answering (last state: LATE_COMMANDS)", result)
        self.assertGreater(elapsed, ai.SILENCE_TIMEOUT)
        self.assertLess(elapsed, ai.SILENCE_TIMEOUT + 4 * ai.FOLLOW_POLL_SECONDS)
        # a restart of the server in the middle: 60 s of silence, then it is back and finishes
        result, said, _ = self.follow(["RUNNING"] + [None] * 12 + ["RUNNING", "DONE"])
        self.assertIsNone(result)

    def test_an_install_that_never_ends_stops_at_the_time_limit(self):
        result, _, elapsed = self.follow(["RUNNING"])
        self.assertIn("did not finish in 4 hours", result)
        self.assertGreaterEqual(elapsed, ai.FOLLOW_TIMEOUT)
        self.assertLess(elapsed, ai.FOLLOW_TIMEOUT + 2 * ai.FOLLOW_POLL_SECONDS)


class RunInstallTests(unittest.TestCase):
    """run_install against FakeServer, with systemd, sudo and the dialogs replaced by recorders, on a virtual clock."""

    def setUp(self):
        disks, _ = classify([stick(), nvme()], "/dev/sda3")
        self.target = by_path(disks)["/dev/nvme0n1"]
        self.log = []
        self.popen = FakePopen()
        self.errors = []
        self.normal = []
        self.zenity_calls = []

    def go(self, plans=None, before=("WAITING",), in_the_way=False, disks_ok=True, sudo_ok=True, target_mounted=False, curtin=False,
           start_rc=0, **server_kw):
        """`target_mounted`: True/False, or a list of the successive answers of target_in_use() (the last one repeats)."""
        self.server = FakeServer(before=before, plans=plans, **server_kw)
        self.clock = FakeClock()
        mounted = list(target_mounted) if isinstance(target_mounted, (list, tuple)) else [target_mounted]
        asked = []

        def fake_target_in_use():
            asked.append(1)
            return mounted[min(len(asked), len(mounted)) - 1]

        def fake_run(cmd, **kw):
            self.log.append(("run", cmd))
            if "tee" in cmd:
                self.server.file_written = True
            return subprocess.CompletedProcess(cmd, 0, "", "")

        def fake_sh(cmd, **kw):
            self.log.append(("sh", cmd))
            if cmd[:5] == ["sudo", "-n", "systemctl", "start", ai.SERVER_UNIT]:
                return subprocess.CompletedProcess(cmd, start_rc, "", "")
            return subprocess.CompletedProcess(cmd, 0 if sudo_ok or cmd[-1] != "true" else 1, "", "")

        def fake_remove():
            self.log.append(("remove",))
            self.server.file_written = False

        def fake_restart():
            self.log.append(("restart",))
            return self.server.restart()

        devs = [stick(), nvme()] if disks_ok else [stick(), nvme(size=1)]
        with Env(devs, "/dev/sda3"), \
                mock.patch.object(ai.subprocess, "run", fake_run), \
                mock.patch.object(ai.subprocess, "Popen", return_value=self.popen), \
                mock.patch.object(ai, "sh", fake_sh), \
                mock.patch.object(ai.time, "time", self.clock.time), \
                mock.patch.object(ai.time, "sleep", self.clock.sleep), \
                mock.patch.object(ai, "target_in_use", fake_target_in_use), \
                mock.patch.object(ai, "curtin_running", return_value=curtin), \
                mock.patch.object(ai, "api", self.server.api), \
                mock.patch.object(ai, "autoinstall_in_the_way", return_value=in_the_way), \
                mock.patch.object(ai, "remove_autoinstall", fake_remove), \
                mock.patch.object(ai, "restart_server", fake_restart), \
                mock.patch.object(ai, "normal_installer", lambda: self.normal.append(1) or 0), \
                mock.patch.object(ai, "error_dialog", lambda t: self.errors.append(t)), \
                mock.patch.object(ai, "zenity", lambda a, **k: self.zenity_calls.append(a) or subprocess.CompletedProcess(a, 0, "", "")):
            return ai.run_install(self.target, "autoinstall: {}\n", "abcd-efgh-jkmn-pqrs")

    def wrote(self):
        return any(c[0] == "run" and "tee" in c[1] for c in self.log)

    def restarts(self):
        """How often the server was restarted. A normal run restarts it once, to load the autoinstall file."""
        return self.log.count(("restart",))

    def test_success_confirms_exactly_once_and_cleans_up(self):
        rc = self.go()
        self.assertEqual(rc, 0)
        self.assertEqual(self.server.posts, [("NEEDS_CONFIRMATION", None, {"tty": "/dev/tty1"})])
        self.assertIn(("remove",), self.log)
        self.assertTrue(self.popen.terminated)
        self.assertEqual(self.errors, [])
        self.assertEqual(self.restarts(), 1)
        self.assertEqual(self.normal, [])

    def test_the_whole_sequence_in_order(self):
        # write the file, restart, wait for the NEW server's NEEDS_CONFIRMATION, one confirmation, follow to DONE
        self.assertEqual(self.go(), 0)
        kinds = [c[0] if c[0] != "run" else ("tee" if "tee" in c[1] else "run") for c in self.log]
        self.assertLess(kinds.index("tee"), kinds.index("restart"))
        gets = [r for r in self.server.requests if r[0] == "GET"]
        posts = [i for i, r in enumerate(self.server.requests) if r[0] == "POST"]
        self.assertEqual(len(posts), 1)
        self.assertTrue(all(r[1] == "/meta/status" for r in gets))
        self.assertGreater(len(self.server.requests) - posts[0], 3)             # it kept reading the state after the confirmation
        self.assertEqual(self.server.instance["last"], "DONE")

    def test_a_whole_real_run_through_every_state(self):
        rc = self.go()
        self.assertEqual(rc, 0)
        said = " ".join(self.popen.lines)
        for text in ("getting ready", "Installing Companion OS", "Finishing up", "Applying updates"):
            self.assertIn(text, said)

    def test_an_install_that_is_already_confirmed_is_followed_not_confirmed_again(self):
        # a kernel command line with the word `autoinstall` skips the confirmation: the server goes straight to RUNNING
        rc = self.go(plans=[(["EARLY_COMMANDS", "WAITING", "RUNNING", "UU_RUNNING", "LATE_COMMANDS", "DONE"], [])])
        self.assertEqual(rc, 0)
        self.assertEqual(self.server.posts, [])

    def test_progress_text_keeps_the_sign_in_details(self):
        self.go()
        self.assertTrue(self.popen.lines)
        self.assertTrue(all("abcd-efgh-jkmn-pqrs" in line for line in self.popen.lines))
        self.assertTrue(all(line.count("\n") == 1 for line in self.popen.lines))   # one line each: "# text\n"

    def test_the_dialog_after_done_shows_the_sign_in_details_and_the_poweroff_hint(self):
        self.assertEqual(self.go(), 0)
        info = [c for c in self.zenity_calls if "--info" in c]
        self.assertEqual(len(info), 1)
        text = " ".join(info[0])
        self.assertIn("abcd-efgh-jkmn-pqrs", text)
        self.assertIn("remove the USB stick", text)

    def test_busy_installer_is_never_touched(self):
        for busy in ("RUNNING", "UU_RUNNING", "LATE_COMMANDS", "DONE"):
            self.log.clear()
            self.assertEqual(self.go(before=(busy,)), 5, busy)
            self.assertFalse(self.wrote(), busy)
            self.assertEqual(self.restarts(), 0, busy)
            self.assertEqual(self.server.posts, [], busy)
            self.assertTrue(any("already running" in e for e in self.errors), busy)
            self.errors.clear()

    def test_the_post_install_window_is_busy(self):
        # WAITING after curtin has written the system: the state the old guard missed
        for kw in ({"target_mounted": True}, {"curtin": True}, {"target_mounted": True, "curtin": True}):
            self.log.clear()
            self.assertEqual(self.go(before=("WAITING",), **kw), 5, kw)
            self.assertFalse(self.wrote(), kw)
            self.assertEqual(self.restarts(), 0, kw)
            self.assertEqual(self.server.posts, [], kw)

    def test_unknown_states_are_never_touched(self):
        for odd in ("POST_WAIT", "POST_RUNNING", "UU_CANCELLING", "SOMETHING_NEW"):
            self.log.clear()
            self.assertEqual(self.go(before=(odd,)), 5, odd)
            self.assertFalse(self.wrote(), odd)
            self.assertEqual(self.restarts(), 0, odd)

    def test_idle_installers_are_taken_over(self):
        # the installer has just started (WAITING, nothing mounted), is at the confirmation, or stopped after a failure
        for idle in ("WAITING", "NEEDS_CONFIRMATION", "ERROR", "EXITED"):
            self.log.clear()
            self.errors.clear()
            self.assertEqual(self.go(before=(idle,)), 0, idle)
            self.assertTrue(self.wrote(), idle)
            self.assertEqual(self.errors, [], idle)

    START = ("sh", ["sudo", "-n", "systemctl", "start", "snap.ubuntu-desktop-bootstrap.subiquity-server.service"])

    def test_the_installer_server_is_started_before_it_is_waited_for(self):
        # The live session no longer opens the stock installer window (customize-chroot.sh Step 7b); the helper asks systemd for the server itself.
        self.assertEqual(self.go(), 0)
        self.assertEqual(self.START[1][-1], ai.SERVER_UNIT)
        self.assertEqual(self.log.count(self.START), 1)
        kinds = [c[0] if c[0] != "run" else ("tee" if "tee" in c[1] else "run") for c in self.log]
        self.assertLess(self.log.index(self.START), kinds.index("tee"), "the server is started before anything is written")
        self.assertLess(self.log.index(("sh", ["sudo", "-n", "true"])), self.log.index(self.START), "and after the check that sudo works")
        self.assertEqual(self.restarts(), 1, "starting it is not a restart: the one restart still loads the autoinstall file")

    def test_a_server_that_cannot_be_started_yet_is_waited_for_not_an_error(self):
        # snapd is still seeding the installer snap: the unit does not exist, systemctl answers non-zero, and the run goes on to wait_ready()
        self.assertEqual(self.go(start_rc=5, before=("STARTING_UP", "STARTING_UP", "WAITING")), 0)
        self.assertEqual(self.log.count(self.START), 1)
        self.assertEqual(self.errors, [])

    def test_the_server_is_not_started_when_the_run_is_refused_first(self):
        for kw in ({"in_the_way": True}, {"sudo_ok": False}):
            self.log = []
            self.assertEqual(self.go(**kw), 5, kw)
            self.assertNotIn(self.START, self.log, kw)

    def test_installer_not_ready_writes_nothing(self):
        self.assertEqual(self.go(before=(None,)), 5)
        self.assertFalse(self.wrote())
        self.assertGreaterEqual(self.clock.elapsed, 180)

    def test_foreign_autoinstall_file_is_not_touched(self):
        self.assertEqual(self.go(in_the_way=True), 5)
        self.assertFalse(self.wrote())

    def test_no_sudo_writes_nothing(self):
        self.assertEqual(self.go(sudo_ok=False), 5)
        self.assertFalse(self.wrote())

    def test_disks_changed_at_the_last_moment_never_confirms(self):
        rc = self.go(disks_ok=False)
        self.assertEqual(rc, 7)
        self.assertEqual(self.server.posts, [])
        self.assertIn("Nothing was erased", self.errors[0])
        self.assertIn(("remove",), self.log)
        self.assertEqual(self.restarts(), 2)        # one to load the settings, one to drop them again
        self.assertEqual(self.normal, [1])          # and the stock installer window this tool closed comes back

    # ── the sequence after the restart ──

    def test_a_server_stuck_in_waiting_ends_in_a_dialog_with_the_state_and_the_log(self):
        rc = self.go(plans=[(["EARLY_COMMANDS", "WAITING"], [])])
        self.assertEqual(rc, 7)                     # (the file was written, so the new server is in automatic mode: it is not "ignored")
        self.assertEqual(self.server.posts, [])
        self.assertIn("still in state WAITING", self.errors[0])
        self.assertIn("10 minutes", self.errors[0])
        self.assertIn(ai.SERVER_LOG, self.errors[0])
        self.assertIn("Nothing was erased", self.errors[0])
        self.assertGreaterEqual(self.clock.elapsed, ai.PREPARE_TIMEOUT)
        self.assertLess(self.clock.elapsed, ai.PREPARE_TIMEOUT + 60)          # bounded: not an hours-long wait
        self.assertIn(("remove",), self.log)
        self.assertEqual(self.restarts(), 2)
        self.assertEqual(self.normal, [1])

    def test_a_server_that_did_not_read_the_file_fails_at_once_and_says_so(self):
        # exactly the state of the VM run after the helper's clean-up: WAITING, interactive true
        rc = self.go(reads_file=False)
        self.assertEqual(rc, 7)
        self.assertEqual(self.server.posts, [])
        self.assertIn("interactive mode", self.errors[0])
        self.assertIn("state WAITING", self.errors[0])
        self.assertIn(ai.SERVER_LOG, self.errors[0])
        self.assertLess(self.clock.elapsed, 60)
        self.assertEqual(self.normal, [1])

    def test_a_restart_that_systemd_refuses_is_a_failure_before_any_wait(self):
        rc = self.go(restart_accepted=False)
        self.assertEqual(rc, 7)
        self.assertEqual(self.server.posts, [])
        self.assertIn("could not be restarted", self.errors[0])
        self.assertIn("Nothing was erased", self.errors[0])
        self.assertIn(("remove",), self.log)
        self.assertEqual(self.normal, [])           # nothing restarted, so no promise of a fresh installer window

    def test_the_old_server_answering_after_the_restart_is_never_confirmed(self):
        # a leftover server in NEEDS_CONFIRMATION with a document of its own (a failed earlier attempt whose restart did not happen)
        rc = self.go(before=("NEEDS_CONFIRMATION",), stock_interactive=False, restart_works=False)
        self.assertEqual(rc, 7)
        self.assertEqual(self.server.posts, [])
        self.assertIn("did not answer", self.errors[0])

    def test_error_after_the_restart_is_a_failure_before_any_confirm(self):
        failed = {"state": "ERROR", "nonreportable_error": {"cause": "AutoinstallUserSuppliedCmdError", "message": "x"}}
        rc = self.go(plans=[(["EARLY_COMMANDS", failed], [])])
        self.assertEqual(rc, 7)
        self.assertEqual(self.server.posts, [])
        self.assertIn("state: ERROR", self.errors[0])
        self.assertIn("the disk is still the one you confirmed", self.errors[0])
        self.assertIn("Nothing was erased", self.errors[0])

    def test_exited_after_the_restart_is_a_failure_before_any_confirm(self):
        rc = self.go(plans=[(["EARLY_COMMANDS", "EXITED"], [])])
        self.assertEqual(rc, 7)
        self.assertEqual(self.server.posts, [])
        self.assertIn("state: EXITED", self.errors[0])

    def test_the_confirmation_is_refused_with_a_500(self):
        rc = self.go(confirm_code=500, confirm_body=TTY_TEXT_500)
        self.assertEqual(rc, 7)
        self.assertEqual(len(self.server.posts), 1)
        self.assertIn("HTTP 500", self.errors[0])
        self.assertIn('missing required argument "tty"', self.errors[0])
        self.assertIn("Nothing was erased", self.errors[0])
        self.assertIn(("remove",), self.log)
        self.assertEqual(self.restarts(), 2)
        self.assertEqual(self.normal, [1])
        self.assertLess(self.clock.elapsed, ai.PREPARE_TIMEOUT)                # a failure, not a wait

    def test_a_500_after_which_the_install_runs_is_followed(self):
        rc = self.go(confirm_code=500, confirm_body="oops", confirm_takes_effect=True)
        self.assertEqual(rc, 0)
        self.assertEqual(len(self.server.posts), 1)

    def test_a_confirmation_nobody_answered_may_have_started_the_install(self):
        rc = self.go(confirm_code=0, confirm_body="")
        self.assertEqual(rc, 7)
        self.assertIn("partly or completely erased", self.errors[0])
        self.assertEqual(self.normal, [])

    def test_error_after_confirmation_says_the_disk_may_be_erased(self):
        rc = self.go(plans=[(PREPARE_OK, ["RUNNING", "RUNNING", "ERROR"])])
        self.assertEqual(rc, 7)
        self.assertIn("partly or completely erased", self.errors[0])
        self.assertIn(("remove",), self.log)
        self.assertEqual(self.restarts(), 2)        # ERROR is idle: the second restart drops the loaded settings
        self.assertTrue(self.popen.terminated)
        self.assertEqual(self.normal, [])           # an install was started: no installer window on top of it

    def test_exited_while_installing_is_a_failure(self):
        rc = self.go(plans=[(PREPARE_OK, ["RUNNING", "UU_RUNNING", "EXITED"])])
        self.assertEqual(rc, 7)
        self.assertIn("exited before the installation was finished", self.errors[0])
        self.assertIn("partly or completely erased", self.errors[0])

    def test_giving_up_on_a_slow_install_does_not_restart_the_server_under_it(self):
        # the tool stops waiting after 4 hours, but the installer is still RUNNING: a restart would kill curtin mid-write
        rc = self.go(plans=[(PREPARE_OK, ["RUNNING"])])
        self.assertEqual(rc, 7)
        self.assertIn("did not finish in 4 hours", self.errors[0])
        self.assertIn("partly or completely erased", self.errors[0])
        self.assertIn(("remove",), self.log)         # our files go: a crash must not leave an autoinstall behind
        self.assertEqual(self.restarts(), 1)         # only the one that loaded the settings
        self.assertEqual(self.normal, [])

    def test_a_confirmation_that_never_took_effect_restarts_an_idle_server_only(self):
        # after the confirm the server reports WAITING (not a started state): with nothing mounted it is idle and is restarted,
        # with the new system mounted it is installing and is left alone
        rc = self.go(plans=[(PREPARE_OK, ["WAITING"])])
        self.assertEqual(rc, 7)
        self.assertIn("did not start after it was confirmed (state: WAITING)", self.errors[0])
        self.assertEqual(self.restarts(), 2)
        self.log.clear()
        self.errors.clear()
        # not mounted when the tool starts (idle installer), mounted by the time it gives up
        rc = self.go(plans=[(PREPARE_OK, ["WAITING"])], target_mounted=[False, True])
        self.assertEqual(rc, 7)
        self.assertEqual(self.restarts(), 1)

    def test_a_reopened_installer_that_cannot_start_is_not_an_error(self):
        with mock.patch.object(ai, "normal_installer", side_effect=FileNotFoundError("gtk-launch")), \
                mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            ai.reopen_normal_installer()
        self.assertIn("could not open the normal installer", err.getvalue())

    def test_the_failure_text_says_where_the_log_is_and_what_to_do_next(self):
        text = ai.failure_text(RuntimeError("it broke"), False, True)
        self.assertIn("it broke", text)
        self.assertIn("Nothing was erased", text)
        self.assertIn(ai.SERVER_LOG, text)
        self.assertIn("opens when you close this message", text)
        text = ai.failure_text(RuntimeError("it broke"), True, False)
        self.assertIn("partly or completely erased", text)
        self.assertIn("from the dock", text)
        self.assertNotIn("desktop icon", text)


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

    def test_a_file_named_on_the_kernel_command_line_is_read_instead_of_ours_so_it_is_in_the_way(self):
        # server.py select_autoinstall: --autoinstall, then subiquity.autoinstallpath=, then /autoinstall.yaml: the first one wins
        with tempfile.TemporaryDirectory() as td:
            ours, link = os.path.join(td, "run", "autoinstall.yaml"), os.path.join(td, "autoinstall.yaml")
            with mock.patch.object(ai, "AUTOINSTALL_PATH", ours), mock.patch.object(ai, "AUTOINSTALL_LINK", link):
                for cmdline, expected in (("BOOT_IMAGE=/casper/vmlinuz boot=casper subiquity.autoinstallpath=/cdrom/x.yaml quiet", True),
                                          ("BOOT_IMAGE=/casper/vmlinuz boot=casper ci.autoinstall=1 --- quiet splash", False),
                                          ("BOOT_IMAGE=/casper/vmlinuz xsubiquity.autoinstallpath=/x", False),
                                          ("", False)):
                    with mock.patch.dict(os.environ, {"CI_OS_AI_CMDLINE": cmdline}):
                        self.assertEqual(ai.autoinstall_in_the_way(), expected, cmdline)

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
            self.assertEqual(ai.api("POST", "/meta/confirm", query={"tty": "/dev/tty1"})[0], 500)
            self.assertEqual(ai.status(), {})
        with mock.patch.object(ai.subprocess, "run", fake("")):
            self.assertEqual(ai.api("GET", "/meta/status"), (0, ""))
        with mock.patch.object(ai.subprocess, "run", side_effect=OSError):
            self.assertEqual(ai.api("GET", "/meta/status"), (0, ""))
        with mock.patch.object(ai.subprocess, "run", fake('["not", "a", "dict"]\n200')):
            self.assertEqual(ai.status(), {})

    def curl_argv(self, *args, **kw):
        seen = []
        with mock.patch.object(ai.subprocess, "run", lambda cmd, **k: seen.append(cmd) or subprocess.CompletedProcess(cmd, 0, "null\n200", "")):
            ai.api(*args, **kw)
        return seen[0]

    def test_query_arguments_are_json_encoded_and_url_quoted_and_there_is_no_body(self):
        # the installer's API: `POST /meta/confirm?tty="/dev/tty1"` (JSON-encoded, then percent-encoded), not a request body
        cmd = self.curl_argv("POST", "/meta/confirm", query={"tty": "/dev/tty1"})
        self.assertEqual(cmd[-1], "http://a/meta/confirm?tty=%22%2Fdev%2Ftty1%22")
        self.assertNotIn("-d", cmd)
        self.assertNotIn("Content-Type: application/json", cmd)
        self.assertEqual(cmd[:2], ["sudo", "-n"])
        self.assertIn("--unix-socket", cmd)

    def test_a_body_is_still_possible_and_a_plain_get_has_no_query(self):
        cmd = self.curl_argv("POST", "/x", {"a": 1})
        self.assertIn("http://a/x", cmd)
        self.assertEqual(cmd[cmd.index("-d") + 1], '{"a": 1}')
        self.assertEqual(self.curl_argv("GET", "/meta/status")[-1], "http://a/meta/status")

    def test_awkward_query_values_survive(self):
        cmd = self.curl_argv("POST", "/x", query={"a": "b&c=d e", "n": 3})
        parsed = urllib.parse.parse_qs(urllib.parse.urlsplit(cmd[-1]).query)
        self.assertEqual({k: json.loads(v[0]) for k, v in parsed.items()}, {"a": "b&c=d e", "n": 3})


class _UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class _InstallerHandler(http.server.BaseHTTPRequestHandler):
    """The two endpoints of the installer's API that the helper uses, with the argument binding of the real server
    (subiquity/common/api/server.py): a parameter that is not a Payload comes from the query string and is JSON-decoded; a missing one
    is TypeError('missing required argument ...') = HTTP 500."""
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def address_string(self):
        return "unix"

    def reply(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.server.seen.append(("GET", self.path, b""))
        if urllib.parse.urlsplit(self.path).path == "/meta/status":
            return self.reply(200, json.dumps(self.server.status))
        self.reply(404, "")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.server.seen.append(("POST", self.path, body))
        url = urllib.parse.urlsplit(self.path)
        if url.path != "/meta/confirm":
            return self.reply(404, "")
        query = urllib.parse.parse_qs(url.query)
        if "tty" not in query:
            return self.reply(500, TTY_TEXT_500)
        try:
            tty = json.loads(query["tty"][0])
        except ValueError as exc:
            return self.reply(500, f"json.decoder.JSONDecodeError: {exc}")
        if not isinstance(tty, str):
            return self.reply(500, "TypeError: tty is not a string")
        self.server.status = dict(self.server.status, state="RUNNING", confirming_tty=tty)
        self.reply(200, "null")


@unittest.skipUnless(shutil.which("curl"), "curl is not installed")
class InstallerSocketTests(unittest.TestCase):
    """The helper's own curl calls against a real HTTP server on a Unix socket that binds arguments like the installer's does."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ci-os-")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.path = os.path.join(self.dir, "s")
        if len(self.path) > 100:
            self.skipTest("no room for a Unix socket path in the temporary directory")
        self.server = _UnixServer(self.path, _InstallerHandler)
        self.server.seen = []
        self.server.status = {"state": "NEEDS_CONFIRMATION", "interactive": False, "confirming_tty": "", "log_syslog_id": "subiquity_log.7"}
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        real_run = subprocess.run

        def run_without_sudo(cmd, **kw):               # the test is not root: `sudo -n curl ...` is `curl ...`
            return real_run(cmd[2:] if cmd[:2] == ["sudo", "-n"] else cmd, **kw)

        for p in (mock.patch.object(ai, "SOCKET", self.path), mock.patch.object(ai.subprocess, "run", run_without_sudo)):
            p.start()
            self.addCleanup(p.stop)

    def test_status_over_the_socket(self):
        self.assertEqual(ai.status()["state"], "NEEDS_CONFIRMATION")
        self.assertEqual(ai.instance_of(ai.status()), "subiquity_log.7")

    def test_the_confirmation_the_helper_sends_is_accepted(self):
        self.assertEqual(ai.confirm_install(), (True, None))
        post = [r for r in self.server.seen if r[0] == "POST"]
        self.assertEqual(post, [("POST", "/meta/confirm?tty=%22%2Fdev%2Ftty1%22", b"")])
        self.assertEqual(ai.status()["confirming_tty"], "/dev/tty1")

    def test_the_first_revision_of_the_request_gets_the_500_of_the_first_real_run(self):
        code, body = ai.api("POST", "/meta/confirm", "/dev/tty1")                 # the tty as a JSON body
        self.assertEqual(code, 500)
        self.assertIn('missing required argument "tty"', body)
        code, body = ai.api("POST", "/meta/confirm", query=None)
        self.assertEqual(code, 500)
        self.assertEqual(ai.status()["state"], "NEEDS_CONFIRMATION")             # nothing changed

    def test_a_confirmation_that_is_not_json_quoted_is_refused_too(self):
        code, body = ai.api("POST", "/meta/confirm?tty=/dev/tty1")
        self.assertEqual(code, 500)
        self.assertIn("JSONDecodeError", body)


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
    NOT_ZENITY = {"--plan", "--disks", "--live-setup", "--locale", "--keyboard", "--timezone", "--max-time", "--unix-socket", "--getsize64", "--target"}

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

    def test_the_confirmation_is_a_query_argument_never_a_body_and_is_posted_in_one_place(self):
        # POST /meta/confirm takes `tty` from the query string (the first revision sent it as a JSON body: HTTP 500 on a real server)
        posts = []
        for node in ast.walk(ast.parse(self.src)):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "api" and node.args \
                    and isinstance(node.args[0], ast.Constant) and node.args[0].value == "POST":
                posts.append(node)
        self.assertEqual(len(posts), 1, "the helper may POST to the installer in exactly one place")
        call = posts[0]
        self.assertEqual([a.value for a in call.args if isinstance(a, ast.Constant)], ["POST", "/meta/confirm"])
        self.assertEqual(len(call.args), 2, "a third positional argument is a request body")
        self.assertEqual([k.arg for k in call.keywords], ["query"])

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
