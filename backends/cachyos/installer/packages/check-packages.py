# Check that every package the Companion OS installer asks for exists, and record the answer for the offline tests.
#
# Maintainer tool (needs network). Run it whenever packages_online.conf, netinstall.yaml or pacstrap.conf change, and
# before cutting an ISO:
#
#   python3 -I backends/cachyos/installer/packages/check-packages.py \
#       --cachyos-db https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos.db \
#       --write backends/cachyos/iso/tests/installer-fixtures/packages.json
#
# What "exists" means. A name must be a real package (not a virtual provide) in
#   - archlinux.org's package search (core, extra, multilib; JSON API, one request per name), or
#   - a CachyOS repository database given with --cachyos-db (a pacman sync database, .db, tar+zstd; a URL or a path).
# The installed system also gets the x86-64-v3/v4 CachyOS repositories (detect-architecture); their names are the same
# as the generic repository's, so the generic database is the one that is checked (the live ISO has only that one).
# A name that only some package PROVIDES is reported as "provided-by" and counts as a failure: Calamares and
# `pacman -Si` need the real name.
#
# Names checked: ci-pkglist.py's `all` set (packages_online.conf operations + netinstall.yaml, optional groups
# included, + basePackages of modules/pacstrap.conf + the always/optional names of pacstrap-code-added.list: the SAME
# definition the launcher's preflight uses) + packages/live-extra.list (packages the LIVE image needs that
# upstream's list does not have; WP-B/lead add them with overlay/packages.add).
#
# Exit 0 only when every name resolves. The fixture (--write) records, per name, the repository and version seen, the
# date, and the sha256 of each CachyOS database used; iso/tests/installer-config.sh reads it offline.
import argparse
import hashlib
import io
import json
import os
import subprocess
import sys

sys.dont_write_bytecode = True
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(INSTALLER, "lib"))

import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("ci_pkglist", os.path.join(INSTALLER, "lib", "ci-pkglist.py"))
ci_pkglist = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ci_pkglist)

ARCH_API = "https://archlinux.org/packages/search/json/?"


def read_db_bytes(src):
    if src.startswith(("http://", "https://")):
        with urllib.request.urlopen(src, timeout=120) as resp:
            return resp.read()
    with open(src, "rb") as fh:
        return fh.read()


def decompress(raw):
    if raw[:4] == b"\x28\xb5\x2f\xfd":  # zstd magic
        try:
            from compression import zstd  # Python 3.14+
            return zstd.decompress(raw)
        except ImportError:
            return subprocess.run(["zstd", "-dc"], input=raw, capture_output=True, check=True).stdout
    return raw  # tar, tar.gz or tar.xz: tarfile sniffs those


def load_db(src):
    raw = read_db_bytes(src)
    tar = tarfile.open(fileobj=io.BytesIO(decompress(raw)))
    pkgs = {}
    for member in tar.getmembers():
        if not (member.isfile() and member.name.endswith("/desc")):
            continue
        key, fields = None, {}
        for line in tar.extractfile(member).read().decode("utf-8", "replace").split("\n"):
            if line.startswith("%") and line.endswith("%"):
                key = line.strip("%")
                fields[key] = []
            elif line and key:
                fields[key].append(line)
        if "NAME" in fields:
            pkgs[fields["NAME"][0]] = fields
    return hashlib.sha256(raw).hexdigest(), pkgs


def arch_lookup(name):
    url = ARCH_API + urllib.parse.urlencode({"name": name})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                results = json.load(resp).get("results", [])
            break
        except (urllib.error.URLError, TimeoutError) as exc:
            if attempt == 2:
                return {"error": str(exc)}
            time.sleep(2)
    hits = [r for r in results if r.get("arch") in ("x86_64", "any")]
    if not hits:
        return None
    best = hits[0]
    return {"repo": best["repo"], "version": "%s-%s" % (best["pkgver"], best["pkgrel"])}


def live_extra_names():
    path = os.path.join(HERE, "live-extra.list")
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if line:
            out.append(line)
    return out


def main():
    ap = argparse.ArgumentParser(description="Check that every package the Companion OS installer asks for exists (see the header of this file).")
    ap.add_argument("--cachyos-db", action="append", default=[], metavar="URL_OR_PATH")
    ap.add_argument("--write", metavar="FIXTURE.json")
    ap.add_argument("--no-network", action="store_true", help="do not query archlinux.org (CachyOS databases only)")
    ap.add_argument("names", nargs="*", help="extra names to check besides the overlay's")
    args = ap.parse_args()

    always, optional = ci_pkglist.package_sets(INSTALLER)
    names = sorted(set(always) | set(optional) | set(live_extra_names()) | set(args.names))
    dbs = {}
    for src in args.cachyos_db:
        digest, pkgs = load_db(src)
        dbs[src] = (digest, pkgs)
        print("cachyos db %s: %d packages, sha256 %s" % (src, len(pkgs), digest[:16]), file=sys.stderr)

    found, missing = {}, {}
    for name in names:
        hit = None
        for src, (_digest, pkgs) in dbs.items():
            if name in pkgs:
                hit = {"repo": "cachyos", "version": pkgs[name]["VERSION"][0]}
                break
        if hit is None and not args.no_network:
            hit = arch_lookup(name)
            if hit and "error" in hit:
                missing[name] = hit["error"]
                continue
        if hit is None:
            provided = sorted(k for _s, (_d, p) in dbs.items() for k, v in p.items()
                              if any(x.split("=")[0] == name for x in v.get("PROVIDES", [])))
            missing[name] = ("only provided by " + ",".join(provided)) if provided else "not found"
            continue
        found[name] = hit

    for name in sorted(found):
        print("ok      %-34s %s %s" % (name, found[name]["repo"], found[name]["version"]))
    for name in sorted(missing):
        print("MISSING %-34s %s" % (name, missing[name]))

    if args.write:
        doc = {
            "checked": time.strftime("%Y-%m-%d", time.gmtime()),
            "sources": ["https://archlinux.org/packages/search/json/ (name= lookups)"]
                       + ["cachyos db %s sha256 %s" % (s if s.startswith("http") else os.path.basename(s), d)
                          for s, (d, _p) in dbs.items()],
            "found": {k: found[k] for k in sorted(found)},
            "missing": {k: missing[k] for k in sorted(missing)},
        }
        with open(args.write, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2, sort_keys=False)
            fh.write("\n")
        print("wrote %s (%d found, %d missing)" % (args.write, len(found), len(missing)), file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
