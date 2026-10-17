"""Running commands, in a form that can be faked and that can be told to only read.

A *runner* is any callable ``runner(argv, timeout) -> CommandResult``. Three are provided:

* :class:`SubprocessRunner` runs the real command (no shell, a fixed environment with ``LC_ALL=C``, bounded output).
* :class:`FixtureRunner` answers from recorded text; a command it has no answer for behaves like a missing program.
* :class:`ReadOnlyRunner` wraps another runner and refuses every command that is not on the allow-list of
  :func:`is_read_only_command`. The ``python3 -m ci_setup`` CLI uses it, which is what makes "the CLI only reads state"
  something a test can check instead of a promise.

The allow-list is exact: each entry is a full argument vector shape, and the interface and phy names in it are validated.
``iw scan`` (which makes the radio scan) is not on it, only ``iw scan dump`` (cached results); ``nmcli device wifi list``
is only allowed together with ``--rescan no``; ``nmcli networking connectivity`` is allowed but ``... check`` (which
makes a network request) is not.
"""
from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional, Sequence, Union

from .errors import CiSetupError, ValidationError
from .validators import validate_ifname, validate_phy_name

MAX_OUTPUT = 2 * 1024 * 1024
DEFAULT_TIMEOUT = 5.0
_ENV = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C", "LANG": "C", "LANGUAGE": "C"}


@dataclass(frozen=True)
class CommandResult:
    rc: int
    stdout: str = ""
    stderr: str = ""
    missing: bool = False       # the program does not exist (or the fixture has no answer for it)
    timed_out: bool = False

    @property
    def ok(self) -> bool:
        return self.rc == 0 and not self.missing and not self.timed_out


Runner = Callable[[Sequence[str], float], CommandResult]


class ReadOnlyViolation(CiSetupError):
    """A command that may change state (or that is simply not on the allow-list) was handed to a read-only runner."""


class SubprocessRunner:
    """Runs a command with ``shell=False`` and a minimal environment. Never raises for a failing command."""

    def __call__(self, argv: Sequence[str], timeout: float = DEFAULT_TIMEOUT) -> CommandResult:
        try:
            proc = subprocess.run(list(argv), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=timeout, env=dict(_ENV), shell=False, check=False)
        except FileNotFoundError:
            return CommandResult(rc=127, missing=True)
        except PermissionError:
            return CommandResult(rc=126)
        except subprocess.TimeoutExpired:
            return CommandResult(rc=124, timed_out=True)
        except OSError:
            return CommandResult(rc=126)
        return CommandResult(rc=proc.returncode, stdout=proc.stdout[:MAX_OUTPUT].decode("utf-8", "replace"),
                             stderr=proc.stderr[:4096].decode("utf-8", "replace"))


Answer = Union[str, Dict[str, object], CommandResult]


class FixtureRunner:
    """Answers from a mapping of command line (``" ".join(argv)``) to recorded output. A command with no entry behaves
    like a program that is not installed. ``calls`` records every argv it was asked."""

    def __init__(self, answers: Optional[Dict[str, Answer]] = None) -> None:
        self.answers = dict(answers or {})
        self.calls = []  # type: List[List[str]]

    @classmethod
    def from_dir(cls, directory: str) -> "FixtureRunner":
        """Load ``<directory>/commands.json``: ``{"iw dev": "iw_dev.txt", "ip -j route": {"file": "r.json",
        "rc": 0}}``, with file names relative to the directory."""
        with open(os.path.join(directory, "commands.json"), "r", encoding="utf-8") as fh:
            spec = json.load(fh)
        answers = {}  # type: Dict[str, Answer]
        for cmd, entry in spec.items():
            if cmd.startswith("_"):
                continue
            rc, text = 0, ""
            if isinstance(entry, str):
                entry = {"file": entry}
            if "file" in entry:
                with open(os.path.normpath(os.path.join(directory, entry["file"])), "r", encoding="utf-8") as fh:
                    text = fh.read()
            else:
                text = str(entry.get("stdout", ""))
            rc = int(entry.get("rc", 0))
            answers[cmd] = CommandResult(rc=rc, stdout=text, stderr=str(entry.get("stderr", "")))
        return cls(answers)

    def __call__(self, argv: Sequence[str], timeout: float = DEFAULT_TIMEOUT) -> CommandResult:
        self.calls.append(list(argv))
        ans = self.answers.get(" ".join(argv))
        if ans is None:
            return CommandResult(rc=127, missing=True)
        if isinstance(ans, CommandResult):
            return ans
        if isinstance(ans, str):
            return CommandResult(rc=0, stdout=ans)
        return CommandResult(rc=int(ans.get("rc", 0)), stdout=str(ans.get("stdout", "")),
                             stderr=str(ans.get("stderr", "")))


# --------------------------------------------------------------------------------------------------------------------
# the read-only allow-list
# --------------------------------------------------------------------------------------------------------------------

_NMCLI_FIXED = (
    ("nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"),
    ("nmcli", "-t", "-f", "NAME,UUID,TYPE,DEVICE", "connection", "show"),
    ("nmcli", "-t", "general", "status"),
    ("nmcli", "networking", "connectivity"),
    ("nmcli", "-t", "-m", "multiline", "device", "show"),
    ("nmcli", "-t", "-f", "IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "no"),
)
_FIXED = (
    ("iw", "dev"), ("iw", "list"), ("iw", "reg", "get"),
    ("rfkill", "list"), ("rfkill", "--json", "list"),
    ("ip", "-j", "link"), ("ip", "-j", "addr"), ("ip", "-j", "route"), ("ip", "-j", "-6", "route"),
) + _NMCLI_FIXED


def _safe_ctrl_dir(path: str) -> bool:
    if not path.startswith("/run/") or len(path) > 100 or ".." in path:
        return False
    return all(c.isalnum() and c.isascii() or c in "_./-" for c in path)


def is_read_only_command(argv: Sequence[str]) -> bool:
    """True only for the exact command shapes listed in the module docstring."""
    if not argv or any((not isinstance(a, str)) or "\x00" in a for a in argv):
        return False
    a = tuple(argv)
    if a in _FIXED:
        return True
    try:
        if len(a) == 4 and a[:2] == ("iw", "phy") and a[3] == "info":
            validate_phy_name(a[2])
            return True
        if len(a) == 4 and a[:2] == ("iw", "dev") and a[3] in ("link", "info"):
            validate_ifname(a[2])
            return True
        if len(a) == 5 and a[:2] == ("iw", "dev") and a[3:] in (("station", "dump"), ("scan", "dump")):
            validate_ifname(a[2])
            return True
        # nmcli device show <if>
        if len(a) == 7 and a[:6] == _NMCLI_FIXED[4]:
            validate_ifname(a[6])
            return True
        # nmcli ... device wifi list ifname <if> --rescan no
        base = _NMCLI_FIXED[5]
        if len(a) == len(base) + 2 and a[:len(base) - 2] == base[:-2] and a[-2:] == ("--rescan", "no") and \
                a[len(base) - 2] == "ifname":
            validate_ifname(a[len(base) - 1])
            return True
        if len(a) in (4, 6) and a[0] in ("hostapd_cli", "wpa_cli"):
            rest = a[1:]
            if rest[0] == "-p":
                if len(rest) < 5 or not _safe_ctrl_dir(rest[1]):
                    return False
                rest = rest[2:]
            if len(rest) == 3 and rest[0] == "-i" and (
                    (a[0] == "hostapd_cli" and rest[2] in ("status", "all_sta")) or
                    (a[0] == "wpa_cli" and rest[2] == "status")):
                validate_ifname(rest[1])
                return True
    except ValidationError:
        return False
    return False


class ReadOnlyRunner:
    """Refuses (raises :class:`ReadOnlyViolation`) any command that is not on the read-only allow-list."""

    def __init__(self, inner: Runner) -> None:
        self.inner = inner

    def __call__(self, argv: Sequence[str], timeout: float = DEFAULT_TIMEOUT) -> CommandResult:
        if not is_read_only_command(argv):
            raise ReadOnlyViolation("refusing to run a command that is not on the read-only list")
        return self.inner(argv, timeout)
