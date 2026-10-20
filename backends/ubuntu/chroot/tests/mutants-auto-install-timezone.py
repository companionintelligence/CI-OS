#!/usr/bin/env python3
"""Mutation check for the time zone lookup of ci-os-auto-install (KI-29): every mutant is one deliberate bug, and the unit tests must fail on it.

The one-click install used to write `timezone: geoip` and every installed system read Etc/UTC, because the installer does not apply a "geoip" it
is handed in an autoinstall file. The helper now asks the installer's own service itself (docs/architecture/one-click-install.md, "The time zone").
This script proves that test_auto_install.py would notice if that went wrong again: it copies the helper, applies one mutant at a time, runs the
whole test file against the copy (CI_OS_AI_HELPER) and requires a failure. A mutant names the exact text to replace, which must occur exactly once,
so that a refactor cannot silently turn a mutant into a no-op. The unmutated copy must pass first.

Run:  python3 backends/ubuntu/chroot/tests/mutants-auto-install-timezone.py [--list] [--only TEXT]
Exit: 0 every mutant killed, 1 a mutant survived (or the control failed), 2 a mutant does not apply or PyYAML is missing.
Needs python3-yaml, like the tests. About 10 seconds per mutant.

© Companion Intelligence, Lifescope Inc
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "payload", "live-start", "usr", "libexec", "ci-os", "ci-os-auto-install")
TESTS = os.path.join(HERE, "test_auto_install.py")

# (id, what the bug is, text to replace, replacement)
MUTANTS = [
    ("install-writes-geoip-unresolved", "the bug of 2026-10-19: the file gets the dialog's answer as it is, never the looked-up zone",
     'cfg = build_autoinstall(target, hash_password(password), locale=region["locale"], layout=region["layout"], timezone=zone)',
     'cfg = build_autoinstall(target, hash_password(password), locale=region["locale"], layout=region["layout"], timezone=region["timezone"])'),
    ("resolve-never-resolves", "resolve_timezone() returns what it was given",
     "    if requested != DEFAULT_ZONE:\n        return requested, None\n    zone = geoip_zone(fetch_geoip())",
     "    if True:\n        return requested, None\n    zone = geoip_zone(fetch_geoip())"),
    ("resolve-overrules-the-choice", "a zone chosen by hand is looked up and replaced too",
     "    if requested != DEFAULT_ZONE:\n        return requested, None\n    zone = geoip_zone(fetch_geoip())",
     "    if False:\n        return requested, None\n    zone = geoip_zone(fetch_geoip())"),
    ("plan-skips-the-lookup", "--plan prints a file the real run would not write",
     '        zone, how = resolve_timezone(region["timezone"])\n        if how:\n            print("TIME ZONE LOOKUP: " + how)',
     '        zone, how = region["timezone"], None\n        if how:\n            print("TIME ZONE LOOKUP: " + how)'),
    ("lookup-before-the-dialog", "the service is asked before the user has clicked (a cancel sends the address out all the same)",
     "    password = generate_password()\n    data = load_region_data()\n",
     '    password = generate_password()\n    data = load_region_data()\n    resolve_timezone(region["timezone"])\n'),
    ("zone-not-checked-against-the-installer", "a zone the installer does not know is written (and stops the whole install)",
     "    if zone not in installer_zones():", "    if False:"),
    ("unknown-name-falls-back-to-utc", "the fallback for an unknown name is UTC instead of geoip",
     'return DEFAULT_ZONE, f"geoip.ubuntu.com said {zone}', 'return "UTC", f"geoip.ubuntu.com said {zone}'),
    ("no-answer-falls-back-to-utc", "the fallback for no answer is UTC instead of geoip",
     'return DEFAULT_ZONE, "geoip.ubuntu.com gave no time zone', 'return "UTC", "geoip.ubuntu.com gave no time zone'),
    ("shape-not-checked", "a name that is not shaped like a zone is taken out of the answer",
     "zone != DEFAULT_ZONE and ZONE_RE.match(zone) else None", "zone != DEFAULT_ZONE else None"),
    ("geoip-accepted-as-an-answer", "the word geoip counts as a zone the service named",
     "zone if zone and zone != DEFAULT_ZONE and ZONE_RE.match(zone) else None", "zone if zone and ZONE_RE.match(zone) else None"),
    ("url-over-http", "the lookup is not encrypted", 'GEOIP_URL = "https://geoip.ubuntu.com/lookup"', 'GEOIP_URL = "http://geoip.ubuntu.com/lookup"'),
    ("url-another-service", "the lookup goes to a service the installer does not use", 'GEOIP_URL = "https://geoip.ubuntu.com/lookup"',
     'GEOIP_URL = "https://geoip.example.com/lookup"'),
    ("no-time-limit", "curl waits for ever", '"--max-time", str(GEOIP_TIMEOUT), ', ""),
    ("time-limit-ten-minutes", "the dialog is gone and nothing is shown for ten minutes", "GEOIP_TIMEOUT = 8 ", "GEOIP_TIMEOUT = 600 "),
    ("no-size-limit", "curl takes any size", '"--max-filesize", str(GEOIP_MAX_BYTES), ', ""),
    ("http-errors-are-answers", "an HTTP error page is read as an answer", '"curl", "-fsS"', '"curl", "-sS"'),
    ("failed-curl-is-an-answer", "what a failed curl printed is read as an answer", "return r.stdout if r.returncode == 0 else None\n\n\ndef installer_zones",
     "return r.stdout\n\n\ndef installer_zones"),
    ("missing-curl-stops-the-tool", "a machine without curl raises instead of falling back", "    except (OSError, ValueError):\n        return None\n    return r.stdout",
     "    except ZeroDivisionError:\n        return None\n    return r.stdout"),
    ("answer-bytes-are-not-tolerated", "bytes that are not text stop the tool", ', errors="replace")', ")"),
    ("zone-list-ignores-failure", "a failed `timedatectl` leaves a list that is read anyway", "return set(r.stdout.split()) if r.returncode == 0 else set()",
     "return set(r.stdout.split())"),
    ("zone-list-from-the-wrong-command", "the list is not the installer's own", '["timedatectl", "list-timezones"]', '["timedatectl", "status"]'),
]


def run_tests(helper):
    env = dict(os.environ, CI_OS_AI_HELPER=helper, PYTHONDONTWRITEBYTECODE="1")
    r = subprocess.run([sys.executable, "-I", TESTS], capture_output=True, text=True, env=env, timeout=300)
    out = (r.stdout or "") + (r.stderr or "")
    return r.returncode, re.findall(r"^(?:FAIL|ERROR): (\w+)", out, re.M), out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--list", action="store_true", help="list the mutants and stop")
    ap.add_argument("--only", help="run the mutants whose id contains this text")
    args = ap.parse_args(argv)
    ids = [m[0] for m in MUTANTS]
    assert len(ids) == len(set(ids)), "duplicate mutant ids"
    chosen = [m for m in MUTANTS if not args.only or args.only in m[0]]
    if args.list:
        for mid, why, _, _ in chosen:
            print(f"{mid:42} {why}")
        return 0
    try:
        import yaml  # noqa: F401
    except ImportError:
        print("mutants: PyYAML is missing (python3-yaml); the tests need it", file=sys.stderr)
        return 2
    with open(HELPER, encoding="utf-8") as fh:
        source = fh.read()
    tmp = tempfile.mkdtemp(prefix="ci-os-mutants.")
    try:
        copy = os.path.join(tmp, "ci-os-auto-install")
        shutil.copyfile(HELPER, copy)
        rc, _, out = run_tests(copy)
        if rc != 0:
            print("control: the unmutated helper FAILS its tests, so no mutant means anything\n" + out[-1500:])
            return 1
        print(f"control: the unmutated helper passes ({re.findall(r'Ran (\d+) tests', out)[0]} tests)")
        survived, bad = [], []
        for mid, why, old, new in chosen:
            if source.count(old) != 1:
                bad.append(mid)
                print(f"NOT APPLIED  {mid}: the text occurs {source.count(old)} times, it must occur once")
                continue
            with open(copy, "w", encoding="utf-8") as fh:
                fh.write(source.replace(old, new))
            rc, failed, _ = run_tests(copy)
            if rc == 0:
                survived.append(mid)
                print(f"SURVIVED     {mid}: {why}")
            else:
                print(f"killed       {mid}: {len(failed)} tests fail, first {failed[0] if failed else '(the run itself)'}")
        print(f"== mutation: {len(chosen) - len(survived) - len(bad)} of {len(chosen)} mutants killed")
        return 2 if bad else (1 if survived else 0)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
