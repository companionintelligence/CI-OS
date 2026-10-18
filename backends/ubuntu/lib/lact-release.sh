#!/usr/bin/env bash
# Choose the LACT .deb of the right Ubuntu release from the GitHub "latest release" JSON. Sourced by provision.sh.
#
# The release carries one .deb per distro build, named lact-<version>-<rev>.amd64.<series>.deb, for example
#   lact-0.10.1-0.amd64.ubuntu-2604.deb       (the GUI, built for Ubuntu 26.04)  <- what Companion OS installs
#   lact-0.10.1-0.amd64.ubuntu-2404.deb       (built for another release)
#   lact-0.10.1-0.amd64.debian-13.deb
#   lact-headless-0.10.1-0.amd64.ubuntu-2604.deb   (no GUI: Companion OS pins lact-gui.desktop)
# provision.sh used to take the first asset whose name matched 'amd64.deb' (a regex, so "amd64" + any character + "deb"),
# which is the Debian 13 build: it is listed first and the pattern also matches "amd64.debian". Choosing by series
# makes a build for another release impossible to pick, and nothing at all is picked when the series is missing.
# shellcheck shell=bash

_LACT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=os-release.sh
source "${_LACT_LIB_DIR}/os-release.sh"

# lact_series: the series suffix of the asset for this Ubuntu release, e.g. ubuntu-2604.
lact_series() {
  printf 'ubuntu-%s' "$(ci_os_ubuntu_version_id | tr -d '.')"
}

# lact_pick_asset <series>: reads the release JSON on stdin and prints "<download url><TAB><sha256 or empty>" for the
# GUI .deb built for <series>; prints nothing (status 1) when there is none or the JSON is unusable. The sha256 comes
# from the "digest" field GitHub puts on each asset; it is empty when the field is absent.
lact_pick_asset() {
  python3 -c '
import json, re, sys
series = sys.argv[1]
try:
    release = json.load(sys.stdin)
    assets = release.get("assets", [])
except Exception:
    sys.exit(1)
wanted = re.compile(r"^lact-[0-9][^/]*\.amd64\." + re.escape(series) + r"\.deb$")
for asset in assets:
    if wanted.match(str(asset.get("name", ""))):
        digest = str(asset.get("digest") or "")
        sha = digest.split(":", 1)[1] if digest.startswith("sha256:") else ""
        print(asset["browser_download_url"] + "\t" + sha)
        sys.exit(0)
sys.exit(1)
' "$1"
}
