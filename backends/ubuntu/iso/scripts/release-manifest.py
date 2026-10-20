#!/usr/bin/env python3
"""The files that describe a published Companion OS release: manifest.json, latest.json and a SHA256SUMS to check them by.

  release-manifest.py --dir DIR --version 1.0 --channel dev|production --base-url https://dl.ci.computer --prefix os
                      [--commit SHA] [--run-url URL] [--repository companionintelligence/CI-OS] [--date 2026-10-20T00:00:00Z]
                      [--out-dir OUT] [--notes-out FILE]

DIR holds the build's output: companion-os-<version>-<arch>.iso (amd64 and/or arm64) and, beside each set, SHA256SUMS, SHA256SUMS.asc and SBOM.txt
when they exist. Nothing is uploaded here, and nothing is read from the network: the sha256 of every file is computed from the bytes on disk, and
SHA256SUMS (when there is one) must agree with them, so a manifest can never describe a different file than the one that gets uploaded.

Writes OUT/manifest.json and OUT/latest.json (default OUT = DIR) and prints the list of files to upload, one "<local path>TAB<key under the prefix>TAB<content type>" per line, in the order they must go up: the images first, the small files after, manifest.json next to last, latest.json last
(the pointer moves only when everything it points to is in place).

The shape follows what Companion Capture publishes to the same bucket (CI-Capture .github/scripts/upload-desktop-r2.sh): per-platform entries with
url, size and sha256, a manifest per version and a small latest.json feed. Key layout: <prefix>/<version>/<arch>/<file>, <prefix>/<version>/manifest.json,
<prefix>/latest.json (prefix "os" on the shared dl-dev and dl-prod buckets).

--notes-out FILE also writes release notes in Markdown (the images with size, sha256 and URL, how to verify and where to go next), generated from the
manifest so they cannot disagree with it.

Exit codes: 0 ok, 2 a usage or input problem (no image, a name that does not fit, SHA256SUMS that disagrees with the files).
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import sys
import urllib.parse

ARCHES = ("amd64", "arm64")
VERSION_RE = re.compile(r"^[0-9]+(\.[0-9]+)*([-.][0-9A-Za-z]+)*$")
PREFIX_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*$")
CHANNELS = ("dev", "production")
SIDE_FILES = ("SHA256SUMS", "SHA256SUMS.asc", "MD5SUMS", "SBOM.txt")
TYPES = {".iso": "application/x-iso9660-image", ".json": "application/json", ".asc": "application/pgp-signature", ".txt": "text/plain"}
CHUNK = 1024 * 1024


class Problem(Exception):
    pass


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def content_type(name):
    if name in ("SHA256SUMS", "MD5SUMS"):
        return "text/plain"
    return TYPES.get(os.path.splitext(name)[1].lower(), "application/octet-stream")


def check_args(version, channel, prefix, base_url):
    if not VERSION_RE.match(version or ""):
        raise Problem("version %r is not like 1.0 or 1.0-rc1" % version)
    if channel not in CHANNELS:
        raise Problem("channel %r is not one of %s" % (channel, ", ".join(CHANNELS)))
    if not PREFIX_RE.match(prefix or "") or ".." in prefix:
        raise Problem("prefix %r is not a plain key prefix like os" % prefix)
    if not re.match(r"^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$", base_url or ""):
        raise Problem("base URL %r must be an https URL without a query" % base_url)


def find_images(directory, version):
    """{arch: path} of companion-os-<version>-<arch>.iso in the directory; anything else named companion-os-*.iso is a problem."""
    images = {}
    for name in sorted(os.listdir(directory)):
        if not (name.startswith("companion-os-") and name.endswith(".iso")):
            continue
        m = re.fullmatch(r"companion-os-(.+)-(amd64|arm64)\.iso", name)
        if not m:
            raise Problem("%s does not look like companion-os-<version>-<amd64|arm64>.iso" % name)
        if m.group(1) != version:
            raise Problem("%s is version %s, not %s" % (name, m.group(1), version))
        images[m.group(2)] = os.path.join(directory, name)
    if not images:
        raise Problem("no companion-os-%s-<arch>.iso in %s" % (version, directory))
    return images


def read_sums(path):
    """{file name: sha256} of a SHA256SUMS file ('<hash>  <name>' or '<hash> *<name>')."""
    out = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"^([0-9a-f]{64}) [ *](.+)$", line.rstrip("\n"))
            if m:
                out[os.path.basename(m.group(2))] = m.group(1)
    return out


def url_for(base_url, prefix, version, arch, name):
    path = "/".join([prefix, version] + ([arch] if arch else []) + [name])
    return "%s/%s" % (base_url.rstrip("/"), urllib.parse.quote(path, safe="/"))


def build(directory, version, channel, base_url, prefix, repository="", commit="", run_url="", date=None):
    """(manifest dict, latest dict, uploads) for the build output in `directory`. Uploads: [(local path, key under the prefix, content type)]."""
    check_args(version, channel, prefix, base_url)
    images = find_images(directory, version)
    sums_path = os.path.join(directory, "SHA256SUMS")
    claimed = read_sums(sums_path) if os.path.exists(sums_path) else {}
    date = date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest = {"product": "companion-os", "version": version, "channel": channel, "date": date, "images": {}}
    if repository or commit or run_url:
        manifest["source"] = {k: v for k, v in (("repository", repository), ("commit", commit), ("workflow_run", run_url)) if v}
    uploads = []
    for arch in ARCHES:
        if arch not in images:
            continue
        path = images[arch]
        name = os.path.basename(path)
        digest = sha256_of(path)
        if claimed and claimed.get(name) not in (None, digest):
            raise Problem("SHA256SUMS says %s for %s, the file on disk is %s" % (claimed[name], name, digest))
        if claimed and name not in claimed:
            # the file that is published beside the images, and that gate 14 checks them by, must name every one of them: two builds on two machines each
            # write a SHA256SUMS of their own image, and uploading either alone leaves the other architecture unchecked
            raise Problem("SHA256SUMS has no line for %s: it must list every image that is published (make one over all of them: remove it and "
                          "run publish-r2.sh with --make-checksums, or `sha256sum companion-os-*.iso > SHA256SUMS` in the directory)" % name)
        entry = {"iso": {"name": name, "url": url_for(base_url, prefix, version, arch, name), "size": os.path.getsize(path), "sha256": digest}}
        uploads.append((path, "%s/%s/%s/%s" % (prefix, version, arch, name), content_type(name)))
        manifest["images"][arch] = entry
    # the files that sit beside the images: one copy of each, under the first arch's directory is wrong for a shared SHA256SUMS, so they live at the
    # version's root, where the manifest is
    for name in SIDE_FILES:
        path = os.path.join(directory, name)
        if os.path.exists(path):
            manifest.setdefault("files", {})[name] = {"url": url_for(base_url, prefix, version, None, name), "size": os.path.getsize(path),
                                                       "sha256": sha256_of(path)}
            uploads.append((path, "%s/%s/%s" % (prefix, version, name), content_type(name)))
    latest = {"product": "companion-os", "version": version, "channel": channel, "date": date}
    return manifest, latest, uploads


def human_size(n):
    for unit, step in (("GiB", 1024 ** 3), ("MiB", 1024 ** 2)):
        if n >= step:
            return "%.1f %s" % (n / step, unit)
    return "%d bytes" % n


def render_notes(manifest):
    """Markdown release notes for a manifest: a fact for every claim, and nothing about testing the generator cannot know."""
    v, ch = manifest["version"], manifest["channel"]
    lines = ["# Companion OS %s%s" % (v, "" if ch == "production" else " (%s build)" % ch), "",
             "Companion OS on Ubuntu 26.04.1 LTS. Built %s." % manifest["date"]]
    src = manifest.get("source", {})
    if src.get("commit"):
        lines.append("Source commit `%s`%s." % (src["commit"][:12], (", [workflow run](%s)" % src["workflow_run"]) if src.get("workflow_run") else ""))
    lines += ["", "## Images", "", "| Architecture | File | Size | sha256 |", "|---|---|---|---|"]
    for arch in ARCHES:
        iso = manifest["images"].get(arch, {}).get("iso")
        if iso:
            lines.append("| %s | [`%s`](%s) | %s | `%s` |" % (arch, iso["name"], iso["url"], human_size(iso["size"]), iso["sha256"]))
    files = manifest.get("files", {})
    lines += ["", "## Check what you downloaded", "", "```sh"]
    if "SHA256SUMS" in files:
        lines += ["curl -fLO %s" % files["SHA256SUMS"]["url"], "sha256sum -c --ignore-missing SHA256SUMS      # macOS: shasum -a 256 -c SHA256SUMS"]
    if "SHA256SUMS.asc" in files:
        lines += ["curl -fLO %s" % files["SHA256SUMS.asc"]["url"], "gpg --verify SHA256SUMS.asc SHA256SUMS      # with the release key's public key"]
    lines += ["```", ""]
    if "SHA256SUMS.asc" not in files:
        lines += ["**This build is not signed**: the checksums say the download is intact, not who made it.", ""]
    lines += ["## Install", "",
              "Write the image for your computer's architecture to a USB stick (Raspberry Pi Imager, balenaEtcher, Rufus, or `dd` on Linux and macOS), "
              "restart, pick the stick in the boot menu and choose **Install Companion OS (automatic)**. "
              "Step by step: https://docs.ci.computer/docs/getting-started/install-companion-os-usb", "",
              "The automatic install erases one internal disk after one confirmation that names it. Read it.", ""]
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--channel", required=True)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--prefix", default="os")
    ap.add_argument("--repository", default="")
    ap.add_argument("--commit", default="")
    ap.add_argument("--run-url", default="")
    ap.add_argument("--date")
    ap.add_argument("--out-dir")
    ap.add_argument("--notes-out")
    a = ap.parse_args(argv)
    out = a.out_dir or a.dir
    try:
        manifest, latest, uploads = build(a.dir, a.version, a.channel, a.base_url, a.prefix, a.repository, a.commit, a.run_url, a.date)
    except (Problem, OSError) as exc:
        print("release-manifest: %s" % exc, file=sys.stderr)
        return 2
    os.makedirs(out, exist_ok=True)
    mpath, lpath = os.path.join(out, "manifest.json"), os.path.join(out, "latest.json")
    for path, doc in ((mpath, manifest), (lpath, latest)):
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")
    if a.notes_out:
        with open(a.notes_out, "w", encoding="utf-8") as fh:
            fh.write(render_notes(manifest))
    uploads.append((mpath, "%s/%s/manifest.json" % (a.prefix, a.version), "application/json"))
    uploads.append((lpath, "%s/latest.json" % a.prefix, "application/json"))
    for path, key, ctype in uploads:
        print("%s\t%s\t%s" % (path, key, ctype))
    return 0


if __name__ == "__main__":
    sys.exit(main())
