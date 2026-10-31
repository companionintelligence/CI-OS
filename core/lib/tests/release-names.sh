#!/usr/bin/env bash
#=============================================================================
# Test: the names and claims of the release tooling agree with each other and with the code, so drift fails the gate
#
#   bash core/lib/tests/release-names.sh
#
# run_checks ROOT prints one line per case, "PASS <case>", "SKIP <case>: <why>" or "FAIL <case>: <file:line what>". The main section runs it on
# the repository and expects PASS everywhere, then plants ONE defect per case in a temp copy of the file set and expects exactly that case to go
# red (so a case that has stopped looking cannot pass unnoticed, and a defect cannot hide behind another case that fails for the same file).
#
#   sig-name         the signature file we produce is SHA256SUMS.asc (MD5SUMS.asc) in the build, the publisher, the manifest tool, the verifier, the
#                    workflow and the checklist. Ubuntu's own stock SHA256SUMS.gpg is a different file and legitimate in the places listed in
#                    STOCK_GPG below, each with its reason; an entry that matches nothing any more fails, so the list only shrinks
#   image-grammar    release-manifest.py accepts each edition's canonical image name with its --edition and refuses the other edition's, and the
#                    Plasma name is the one ci_iso_file_name builds from EDITION_ISO_NAME and EDITION_ARCH in backends/cachyos/upstream.lock
#   workflow-claims  a workflow header (and the header of check-repo.sh) does not call a manual workflow always-on or "every PR"
#   artifact-names   the default artifact of stick-real-iso.yml is one that the build workflow uploads
#   ci-md            docs/CI.md has an entry for every workflow file, with every workflow_dispatch input in its gh workflow run line
#   pins-agree       the base ISO pins, in full or abbreviated, and the Ubuntu CD key fingerprint are the same everywhere they are written
#   image-ref        the build image string is the same in the workflow, build-in-docker.sh, the three recipes and pr-checks.yml (SKIP until pinned)
#   side-files       the files beside the images are the same in release-manifest.py, the publisher header, the checklist and the draft release
#   repro-claims     "reproducible" appears in a document only on a line listed in core/lib/repro-claims.allow (a baseline that only shrinks)
#   counts           the number of workflows that the guides write down is the number of files in .github/workflows
#
# Needs bash 3.2, python3 (3.8 or newer, stdlib only) and, for the repository itself, git. Writes only to a temporary directory. Exit 0 passed,
# 1 failed, 2 cannot run here. The mutation idiom of the repository (docs/guides/running-the-tests.md) is the temp copy edited by a function
# mutate_<name> below; the text each one edits is checked, so a change that did not apply is itself a failure.
#
# © Companion Intelligence, Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "cannot run here: python3 is missing" >&2; exit 2; }
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' || { echo "cannot run here: python3 3.8 or newer is needed" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-names.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0; SKIPPED=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

# --- the engine: the cases, as one stdlib-only program ----------------------------------------------------------------------------------------
PY="$WORK/names.py"
cat >"$PY" <<'PYEOF'
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from contextlib import redirect_stderr, redirect_stdout

sys.dont_write_bytecode = True

TREES = ("backends", "core", ".github", "docs")      # scanned for names; docs/evidence is a record that is never edited, so never scanned
ROOT_DOCS = ("CLAUDE.md", "AGENTS.md", "ANTIGRAVITY.md", "README.md")
SELF = "core/lib/tests/release-names.sh"               # spells the bad names on purpose, like check-repo.sh does
MAX_BYTES = 1000000

TOOL = "backends/ubuntu/iso/scripts/release-manifest.py"
PUBLISHER = "backends/ubuntu/iso/scripts/publish-r2.sh"
VERIFIER = "backends/ubuntu/iso/scripts/verify-published.sh"
BUILD_IN_DOCKER = "backends/ubuntu/iso/scripts/build-in-docker.sh"
ONECLICK = "backends/ubuntu/chroot/tests/oneclick-subiquity-dryrun.sh"
BUILD_WF = ".github/workflows/build-companion-os-iso.yml"
STICK_WF = ".github/workflows/stick-real-iso.yml"
PR_WF = ".github/workflows/pr-checks.yml"
CHECKLIST = "docs/guides/release-checklist.md"
CI_MD = "docs/CI.md"
LOCK = "backends/cachyos/upstream.lock"
REPRO_ALLOW = "core/lib/repro-claims.allow"


class Skip(Exception):
    pass


class CannotRun(Exception):
    pass


def list_files(root):
    """Relative paths of a tree's files: the tracked ones when it is a git work tree, every file of a plain copy."""
    if os.path.exists(os.path.join(root, ".git")):
        try:
            out = subprocess.run(["git", "-C", root, "ls-files", "-z"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True).stdout
        except (OSError, subprocess.CalledProcessError) as exc:
            raise CannotRun("git ls-files failed in %s: %s" % (root, exc))
        names = [p for p in out.decode("utf-8", "replace").split("\0") if p]
    else:
        names = []
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if x not in (".git", "node_modules", "target", "__pycache__")]
            names += [os.path.relpath(os.path.join(d, f), root).replace(os.sep, "/") for f in files]
    return sorted(set(names))


class Tree:
    def __init__(self, root):
        self.root = root
        self.all = [p for p in list_files(root) if os.path.isfile(os.path.join(root, p))]
        self.cache = {}

    def text(self, rel):
        if rel not in self.cache:
            try:
                with open(os.path.join(self.root, rel), "rb") as fh:
                    data = fh.read(MAX_BYTES + 1)
            except OSError:
                data = None
            binary = data is None or len(data) > MAX_BYTES or b"\0" in data[:8192]
            self.cache[rel] = None if binary else data.decode("utf-8", "replace")
        return self.cache[rel]

    def lines(self, rel):
        t = self.text(rel)
        return [] if t is None else t.split("\n")

    def has(self, rel):
        return self.text(rel) is not None

    def scanned(self):
        """The text files whose words the cases read: the four trees and the top-level guides, without the evidence records and this suite."""
        return [p for p in self.all if p != SELF and not p.startswith("docs/evidence/") and (p.split("/")[0] in TREES or p in ROOT_DOCS)
                and self.has(p)]

    def workflows(self):
        return [p for p in self.all if re.fullmatch(r"\.github/workflows/[^/]+\.ya?ml", p)]


def at(path, lineno, what):
    return "%s:%d %s" % (path, lineno, what) if lineno else "%s %s" % (path, what)


def indent_of(s):
    return len(s) - len(s.lstrip(" "))


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        return v[1:-1].replace("''", "'") if v[0] == "'" else v[1:-1]
    return re.sub(r"\s+#.*$", "", v)


# --- workflow files, read line by line (no YAML library: the shapes in use are plain) -------------------------------------------------------------
def live_on_block(lines):
    """[(lineno, text)] of the live `on:` block: the lines after the first uncommented top-level `on:` up to the next top-level key."""
    for i, line in enumerate(lines):
        if re.match(r"""^("?on"?)\s*:""", line):
            first = line.split(":", 1)[1].strip()
            block = [(i + 1, line)] if first and not first.startswith("#") else []
            for j in range(i + 1, len(lines)):
                t = lines[j]
                if t.strip() == "" or t.lstrip().startswith("#"):
                    continue
                if not t.startswith((" ", "\t")):
                    break
                block.append((j + 1, t))
            return block
    return []


def live_triggers(lines):
    block = live_on_block(lines)
    if not block:
        return set()
    if block[0][1].lstrip().startswith(("on", '"on"')):          # on: push / on: [push, pull_request]
        return set(re.findall(r"[a-z_]+", block[0][1].split(":", 1)[1]))
    top = min(indent_of(t) for _, t in block)
    return {m.group(1) for _, t in block for m in [re.match(r"^\s*([a-z_]+)\s*:", t)] if m and indent_of(t) == top}


def dispatch_inputs(lines):
    """{name: {field: raw value}} of workflow_dispatch.inputs in the live `on:` block."""
    block = live_on_block(lines)
    inputs = {}
    i = 0
    while i < len(block):
        if re.match(r"^\s*workflow_dispatch\s*:", block[i][1]):
            a = indent_of(block[i][1])
            j = i + 1
            while j < len(block) and indent_of(block[j][1]) > a:
                if re.match(r"^\s*inputs\s*:\s*$", block[j][1]):
                    b = indent_of(block[j][1])
                    k, c, cur = j + 1, None, None
                    while k < len(block) and indent_of(block[k][1]) > b:
                        t = block[k][1]
                        c = indent_of(t) if c is None else c
                        m = re.match(r"^\s*([A-Za-z0-9_-]+)\s*:\s*(.*?)\s*$", t)
                        if m and indent_of(t) == c:
                            cur = m.group(1)
                            inputs[cur] = {"line": block[k][0]}
                        elif m and cur:
                            inputs[cur][m.group(1)] = m.group(2)
                        k += 1
                    j = k
                    continue
                j += 1
            i = j
            continue
        i += 1
    return inputs


def workflow_header(lines):
    """The lines before the first live `on:` or the gating marker, as [(lineno, text)]."""
    for i, line in enumerate(lines):
        if re.match(r"""^("?on"?)\s*:""", line) or line.startswith("# >>> ci-local:gated"):
            return [(n + 1, lines[n]) for n in range(i)]
    return [(n + 1, t) for n, t in enumerate(lines)]


def workflow_name(lines):
    for line in lines:
        m = re.match(r"^name\s*:\s*(.+?)\s*$", line)
        if m:
            return unquote(m.group(1))
    return None


# --- sig-name -------------------------------------------------------------------------------------------------------------------------------------------
GPG_TOKENS = ("SHA256SUMS.gpg", "MD5SUMS.gpg")
OURS = ("SHA256SUMS.asc", "MD5SUMS.asc")
PUBLISHER_NAMES = ("publish-r2", "release-manifest", "verify-published")
PUBLISHER_SIDE = (PUBLISHER, TOOL, VERIFIER, BUILD_WF, CHECKLIST)
# The places where Ubuntu's own stock signature file is named, each with its reason: (path, anchors, reason). Anchors (fixed substrings) narrow
# an entry to the lines that carry one of them; an entry without anchors covers the whole file, but is not honoured for one of the five files
# of PUBLISHER_SIDE (the workflow is one, so it is listed by anchors: a .gpg name on any other line of it is still a finding).
# An entry, or an anchor, that matches nothing any more fails: the list only shrinks.
STOCK_GPG = (
    (BUILD_WF, ("signer of SHA256SUMS.gpg", '"$dir_url/SHA256SUMS.gpg"', "--verify SHA256SUMS.gpg SHA256SUMS"),
     "Ubuntu's own stock signature file: the comment naming its signer, and the download and verify steps of the base ISO check"),
    (STICK_WF, None, "Ubuntu's own stock signature file: the download and verify step of the stock ISO"),
    ("backends/ubuntu/iso/scripts/build-iso.sh", None,
     "Ubuntu's own stock signature file: removed from the remastered image, because it signed the checksums of the stock layers"),
    ("backends/ubuntu/iso/tests/md5sum-txt.sh", None, "Ubuntu's own stock signature file: the test that the new md5sum.txt does not list it"),
    ("backends/ubuntu/iso/tests/split-live-layer.sh", None, "Ubuntu's own stock signature file: the test that the layer split removes it"),
    ("docs/guides/iso-build-guide.md", None, "Ubuntu's own stock signature file: how to check the stock ISO before a build"),
)
OUTPUT_RE = re.compile(r"""(?:--output(?:=|\s+)|\s-o\s+)(["']?)([^\s"']+)\1""")


def logical_lines(lines):
    """[(first line, last line, text)] with backslash continuations joined."""
    out, i = [], 0
    while i < len(lines):
        first, text = i, lines[i]
        while text.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            text = text.rstrip()[:-1] + " " + lines[i].strip()
        out.append((first + 1, i + 1, text))
        i += 1
    return out


def case_sig_name(T):
    f = []
    used = {}
    for path in T.scanned():
        lines = T.lines(path)
        publisher_side = path in PUBLISHER_SIDE
        mentions_publisher = any(n in T.text(path) for n in PUBLISHER_NAMES)
        flagged = set()
        for first, last, cmd in logical_lines(lines):                 # (i) what we sign to
            if "--detach-sign" in cmd:
                for m in OUTPUT_RE.finditer(cmd):
                    name = m.group(2).rsplit("/", 1)[-1]
                    if name not in OURS:
                        f.append(at(path, first, "signs the checksums to %s; our signature files are SHA256SUMS.asc and MD5SUMS.asc" % name))
                        flagged.update(range(first, last + 1))
        for no, line in enumerate(lines, 1):
            if no in flagged:
                continue
            token = next((t for t in GPG_TOKENS if t in line), None)
            if token is None:
                if re.search(r"--sign\b", line) and re.search(r"\.gpg\b", line) and re.search(r"signature|SUMS", line, re.I):     # (iii) our --sign output
                    f.append(at(path, no, "describes the output of --sign as .gpg; our signature files are SHA256SUMS.asc and MD5SUMS.asc"))
                continue
            accepted = False
            for idx, (p, anchors, _reason) in enumerate(STOCK_GPG):
                if p != path:
                    continue
                if anchors is None and not publisher_side:
                    used[(idx, None)] = True
                    accepted = True
                elif anchors is not None:
                    for a in anchors:
                        if a in line:
                            used[(idx, a)] = True
                            accepted = True
            if accepted:
                continue
            if publisher_side or mentions_publisher:                                                  # (ii) the publisher side
                f.append(at(path, no, "names %s in a file that names the release tools; the signature they publish and check is SHA256SUMS.asc" % token))
            elif re.search(r"--verify\b", line):                                                      # (iii) a person told to verify our file
                f.append(at(path, no, "tells a person to verify our checksums with %s; the signature file is SHA256SUMS.asc" % token))
            else:
                f.append(at(path, no, "names %s; our signature file is SHA256SUMS.asc (Ubuntu's own stock file is listed, with its reason, in STOCK_GPG "
                                      "of core/lib/tests/release-names.sh)" % token))
    for idx, (p, anchors, _reason) in enumerate(STOCK_GPG):                                         # the list only shrinks
        if anchors is None:
            if (idx, None) not in used:
                f.append("STOCK_GPG lists %s, which names no stock signature file any more: delete the entry" % p)
        else:
            for a in anchors:
                if (idx, a) not in used:
                    f.append("STOCK_GPG lists %s with the anchor %r, which matches no line any more: delete the anchor" % (p, a))
    for p in PUBLISHER_SIDE:
        if not T.has(p):
            f.append("%s is missing (it is on the publisher side of the signature name)" % p)
        elif "SHA256SUMS.asc" not in T.text(p):
            f.append(at(p, 0, "does not name SHA256SUMS.asc, the signature file that is published and checked"))
    return f


# --- image-grammar --------------------------------------------------------------------------------------------------------------------------------
def load_tool(T):
    path = os.path.join(T.root, TOOL)
    spec = importlib.util.spec_from_file_location("release_manifest_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run_tool(mod, names, edition, version):
    d, out = tempfile.mkdtemp(prefix="rn-dir-"), tempfile.mkdtemp(prefix="rn-out-")
    try:
        for n in names:
            open(os.path.join(d, n), "wb").close()
        sink = io.StringIO()
        with redirect_stdout(sink), redirect_stderr(sink):
            try:
                rc = mod.main(["--dir", d, "--out-dir", out, "--version", version, "--channel", "dev", "--base-url", "https://dl.example.test",
                               "--edition", edition, "--date", "2026-10-20T00:00:00Z"])
            except SystemExit as exc:
                rc = exc.code if isinstance(exc.code, int) else 2
        doc = None
        if rc == 0 and os.path.isfile(os.path.join(out, "manifest.json")):
            with open(os.path.join(out, "manifest.json"), encoding="utf-8") as fh:
                doc = json.load(fh)
        return rc, doc, sink.getvalue().strip().split("\n")[-1][:160]
    finally:
        shutil.rmtree(d, True)
        shutil.rmtree(out, True)


def case_image_grammar(T):
    f = []
    if not T.has(TOOL):
        return [TOOL + " is missing"]
    plasma = os.environ.get("RN_PLASMA_ISO", "")
    m = re.fullmatch(r"(.+)-(\d{4}\.\d{2}\.\d{2})-([A-Za-z0-9_]+)\.iso", plasma)
    if not m:
        return [at(LOCK, 0, "ci_iso_file_name gave no image name (%r): it builds it from EDITION_ISO_NAME and EDITION_ARCH, and "
                            "backends/cachyos/iso/scripts/lib/common.sh must be readable" % plasma)]
    pre, date, parch = m.groups()
    y, mo, d = date.split(".")
    try:
        mod = load_tool(T)
    except Exception as exc:                                       # a tool that does not load is a finding, not a crash of the suite
        return [at(TOOL, 0, "does not load: %s: %s" % (type(exc).__name__, exc))]
    uam, ubm = "companion-os-1.0-amd64.iso", "companion-os-1.0-arm64.iso"

    def accepted(edition, version, names, arches):
        rc, doc, said = run_tool(mod, names, edition, version)
        if rc != 0 or doc is None:
            f.append(at(TOOL, 0, "--edition %s refuses %s (exit %s: %s)" % (edition, " + ".join(names), rc, said)))
        elif sorted(doc.get("images", {})) != sorted(arches) or doc.get("edition", "ubuntu") != edition or doc.get("product") != "companion-os":
            f.append(at(TOOL, 0, "--edition %s describes %s as the images %r of the edition %r" % (edition, " + ".join(names), sorted(doc.get("images", {})),
                                                                                                    doc.get("edition", "ubuntu"))))

    def refused(edition, version, names, why):
        rc, _, _ = run_tool(mod, names, edition, version)
        if rc != 2:
            f.append(at(TOOL, 0, "--edition %s accepts %s (exit %s), and must refuse it: %s" % (edition, " + ".join(names), rc, why)))

    accepted("ubuntu", "1.0", [uam], ["amd64"])
    accepted("ubuntu", "1.0", [ubm], ["arm64"])
    accepted("ubuntu", "1.0", [uam, ubm], ["amd64", "arm64"])
    accepted("plasma", date, [plasma], [parch])
    refused("plasma", "1.0", [uam], "an Ubuntu image in a Plasma release")
    refused("ubuntu", date, [plasma], "a Plasma image in an Ubuntu release")
    refused("ubuntu", "1.0", [uam, plasma], "a directory of both editions, as Ubuntu")
    refused("plasma", date, [plasma, uam], "a directory of both editions, as Plasma")
    # each near miss is offered with the version it carries itself, so that only the grammar of the name can refuse it (a wrong version would)
    near = (("a date without its zeros", "%s-%s.1.8-%s.iso" % (pre, y, parch), "%s.1.8" % y),
            ("a date with a two digit year", "%s-%s.%s.%s-%s.iso" % (pre, y[2:], mo, d, parch), "%s.%s.%s" % (y[2:], mo, d)),
            ("a date with a five digit year", "%s-%s9.%s.%s-%s.iso" % (pre, y, mo, d, parch), "%s9.%s.%s" % (y, mo, d)),
            ("a date with a three digit day", "%s-%s.%s.%s9-%s.iso" % (pre, y, mo, d, parch), "%s.%s.%s9" % (y, mo, d)),
            ("a release version where the date goes", "%s-1.0-%s.iso" % (pre, parch), "1.0"),
            ("a date and a suffix", "%s-%s-rc1-%s.iso" % (pre, date, parch), date + "-rc1"),
            ("the Ubuntu architecture", "%s-%s-amd64.iso" % (pre, date), date), ("the other Ubuntu architecture", "%s-%s-arm64.iso" % (pre, date), date),
            ("no architecture", "%s-%s.iso" % (pre, date), date), ("something after the architecture", "%s-%s-%s-old.iso" % (pre, date, parch), date),
            ("another edition name", "%sx-%s-%s.iso" % (pre, date, parch), date))
    for why, name, version in near:
        refused("plasma", version, [name], "near miss: " + why)
    for why, name in (("the Plasma architecture", "companion-os-1.0-%s.iso" % parch), ("a third architecture", "companion-os-1.0-i386.iso"),
                      ("no architecture", "companion-os-1.0.iso")):
        refused("ubuntu", "1.0", [name], "near miss: " + why)
    return f


# --- workflow-claims ------------------------------------------------------------------------------------------------------------------------------
CLAIMS = ("always-on", "always on", "every pr", "every pull request", "deliberately not gated")


def case_workflow_claims(T):
    f = []
    triggers = {}
    for wf in T.workflows():
        lines = T.lines(wf)
        triggers[wf] = live_triggers(lines)
        automatic = bool(triggers[wf] & {"pull_request", "pull_request_target", "push"})
        for no, text in workflow_header(lines):
            low = text.lower()
            for phrase in CLAIMS:
                if phrase in low and not automatic:
                    f.append(at(wf, no, 'header says "%s", but the live trigger is %s' % (phrase, ", ".join(sorted(triggers[wf])) or "none")))
    script = "core/lib/check-repo.sh"                                # the script the PR checks workflow runs says the same things about it
    head = []
    for n, text in enumerate(T.lines(script), 1):
        if n > 1 and not text.startswith("#"):
            break
        head.append((n, text))
    pr = triggers.get(PR_WF)
    if pr is not None and not (pr & {"pull_request", "pull_request_target", "push"}):
        for no, text in head:
            for phrase in CLAIMS:
                if phrase in text.lower():
                    f.append(at(script, no, 'header says "%s", but %s is started by hand (%s)' % (phrase, PR_WF, ", ".join(sorted(pr)) or "none")))
    return f


# --- artifact-names -------------------------------------------------------------------------------------------------------------------------------
def uploaded_artifacts(lines):
    names = []
    for i, line in enumerate(lines):
        if re.search(r"uses:\s*actions/upload-artifact@", line):
            base = indent_of(line)
            in_with = False
            for t in lines[i + 1:i + 14]:
                if re.match(r"^\s*-\s", t) and indent_of(t) <= base:
                    break
                if re.match(r"^\s*with\s*:\s*$", t):
                    in_with = True
                m = re.match(r"^\s+name\s*:\s*(.+?)\s*$", t)
                if in_with and m:
                    names.append(unquote(m.group(1)))
                    break
    return names


def case_artifact_names(T):
    for p in (STICK_WF, BUILD_WF):
        if not T.has(p):
            return [p + " is missing"]
    inputs = dispatch_inputs(T.lines(STICK_WF))
    if "ci_os_artifact" not in inputs or "default" not in inputs["ci_os_artifact"]:
        return [at(STICK_WF, 0, "has no workflow_dispatch input ci_os_artifact with a default")]
    default = unquote(inputs["ci_os_artifact"]["default"])
    arch_input = dispatch_inputs(T.lines(BUILD_WF)).get("arch", {})
    arches = [a for a in re.findall(r"[a-z0-9_]+", arch_input.get("options", "")) if a != "both"]
    if not arches:
        return [at(BUILD_WF, 0, "has no input `arch` with options: the architectures of the uploaded artifacts cannot be read")]
    names = set()
    for raw in uploaded_artifacts(T.lines(BUILD_WF)):
        if re.search(r"\$\{\{\s*matrix\.arch\s*\}\}", raw):
            names.update(re.sub(r"\$\{\{\s*matrix\.arch\s*\}\}", a, raw) for a in arches)
        else:
            names.add(raw)
    if default not in names:
        return [at(STICK_WF, inputs["ci_os_artifact"]["line"], "defaults ci_os_artifact to %r, and %s uploads %s" % (default, BUILD_WF.split("/")[-1],
                                                                                                                   ", ".join(sorted(names)) or "nothing"))]
    return []


# --- ci-md ----------------------------------------------------------------------------------------------------------------------------------------
def case_ci_md(T):
    f = []
    if not T.has(CI_MD):
        return [CI_MD + " is missing"]
    lines = T.lines(CI_MD)
    entries = {}
    for i, line in enumerate(lines):
        m = re.match(r"^\*\*(.+?)\*\* \u2014 `([^`]+)`\s*$", line)
        if m:
            run = next((t for t in lines[i + 1:i + 8] if t.startswith("gh workflow run ")), "")
            entries[m.group(2)] = (m.group(1), run, i + 1)
    files = {p.split("/")[-1]: p for p in T.workflows()}
    for base, path in sorted(files.items()):
        wl = T.lines(path)
        if base not in entries:
            f.append(at(CI_MD, 0, "has no entry for %s (the generated form is **name** \u2014 `file`)" % path))
            continue
        title, run, no = entries[base]
        if title != workflow_name(wl):
            f.append(at(CI_MD, no, "calls %s %r, and its name: is %r" % (base, title, workflow_name(wl))))
        for name in dispatch_inputs(wl):
            if not re.search(r"(^|\s)-f %s=" % re.escape(name), run):
                f.append(at(CI_MD, no, "the gh workflow run line of %s lacks the input %s" % (base, name)))
    for base, (_title, _run, no) in sorted(entries.items()):
        if base not in files:
            f.append(at(CI_MD, no, "has an entry for %s, and there is no such workflow file" % base))
    return f


# --- pins-agree -----------------------------------------------------------------------------------------------------------------------------------
HEX64 = re.compile(r"(?<![0-9A-Fa-f])[0-9a-f]{64}(?![0-9A-Fa-f])")
ABBREV = re.compile(r"(?<![0-9a-f])([0-9a-f]{8})(?:\.\.\.|\u2026)([0-9a-f]{4})(?![0-9a-f])")


def hamming(a, b):
    return sum(1 for x, y in zip(a, b) if x != y)


def one(T, path, pattern, what, flags=re.M):
    m = re.search(pattern, T.text(path) or "", flags)
    return m.group(1) if m else None


def case_pins_agree(T):
    f = []
    for p in (BUILD_WF, BUILD_IN_DOCKER, ONECLICK, STICK_WF):
        if not T.has(p):
            return [p + " is missing"]
    pins = {"amd64": one(T, BUILD_WF, r'^\s*BASE_ISO_SHA256_AMD64:\s*"?([0-9a-f]{64})"?', "amd64"),
            "arm64": one(T, BUILD_WF, r'^\s*BASE_ISO_SHA256_ARM64:\s*"?([0-9a-f]{64})"?', "arm64")}
    if not all(pins.values()):
        return [at(BUILD_WF, 0, "BASE_ISO_SHA256_AMD64 and BASE_ISO_SHA256_ARM64 cannot be read: they are the pins every other place is held to")]
    for path, pattern, arch in ((BUILD_IN_DOCKER, r'^PIN_AMD64="([0-9a-f]{64})"', "amd64"), (BUILD_IN_DOCKER, r'^PIN_ARM64="([0-9a-f]{64})"', "arm64"),
                                (ONECLICK, r'^KNOWN_ISO_SHA256="([0-9a-f]{64})"', "amd64")):
        got = one(T, path, pattern, arch)
        if got is None:
            f.append(at(path, 0, "the %s base ISO pin cannot be read" % arch))
        elif got != pins[arch]:
            f.append(at(path, 0, "pins the %s base ISO to %s...%s, and %s says %s...%s" % (arch, got[:8], got[-4:], BUILD_WF.split("/")[-1],
                                                                                             pins[arch][:8], pins[arch][-4:])))
    fa = one(T, BUILD_WF, r'^\s*UBUNTU_CD_KEY_FPR:\s*"?([0-9A-F]{40})"?', "fpr")
    fb = one(T, STICK_WF, r'^\s*UBUNTU_CD_KEY_FPR:\s*"?([0-9A-F]{40})"?', "fpr")
    if fa is None or fb is None:
        f.append("UBUNTU_CD_KEY_FPR cannot be read in %s and %s" % (BUILD_WF.split("/")[-1], STICK_WF.split("/")[-1]))
    elif fa != fb:
        f.append(at(STICK_WF, 0, "UBUNTU_CD_KEY_FPR differs from the one in %s" % BUILD_WF.split("/")[-1]))
    values = set(pins.values())
    for path in T.scanned():                                                  # every place that writes a pin, in full or abbreviated
        for no, line in enumerate(T.lines(path), 1):
            for m in HEX64.finditer(line):
                h = m.group(0)
                if h not in values and min(hamming(h, p) for p in values) <= 8:
                    f.append(at(path, no, "has %s...%s, which is a base ISO pin with a changed digit" % (h[:8], h[-4:])))
            for m in ABBREV.finditer(line):
                pre, suf = m.groups()
                for arch, p in pins.items():
                    if (pre == p[:8]) != (suf == p[-4:]):
                        f.append(at(path, no, "has %s...%s, which matches only one end of the %s base ISO pin %s...%s" % (pre, suf, arch, p[:8], p[-4:])))
    return f


# --- image-ref ------------------------------------------------------------------------------------------------------------------------------------
_RECIPE = re.compile(r"(ubuntu:26\.04\S*)\s+sleep infinity")
IMAGE_PLACES = (
    (BUILD_WF, re.compile(r'^\s*BUILD_IMAGE:\s*"?([^"\s#]+)')),
    (BUILD_IN_DOCKER, re.compile(r'^BUILD_IMAGE="([^"]+)"')),
    ("CLAUDE.md", _RECIPE),
    ("README.md", _RECIPE),
    ("docs/guides/building-on-a-mac.md", _RECIPE),
    (PR_WF, re.compile(r"(ubuntu:26\.04\S*)\s+bash -euo pipefail")),
)


def case_image_ref(T):
    f = []
    found = {}
    for path, pattern in IMAGE_PLACES:
        tokens = []
        for no, line in enumerate(T.lines(path), 1):
            m = pattern.search(line)
            if m:
                tokens.append((no, m.group(1)))
        if not tokens:
            f.append(at(path, 0, "carries no build image reference that this check can read (pattern %s)" % pattern.pattern))
        found[path] = tokens
    if f:
        return f
    everything = {tok for toks in found.values() for _, tok in toks}
    if not any("@sha256:" in t for t in everything):
        raise Skip("the build image is not pinned by digest anywhere yet (the pin of the image is a separate change); the six places are compared "
                   "once it lands")
    for path, toks in found.items():
        for no, tok in toks:
            if not re.fullmatch(r"ubuntu:26\.04@sha256:[0-9a-f]{64}", tok):
                f.append(at(path, no, "has the build image %r; the pinned form is ubuntu:26.04@sha256:<64 hex>" % tok))
    if len(everything) > 1:
        f.append("the build image is written %d ways: %s" % (len(everything), "; ".join("%s has %s" % (p, " ".join(sorted({t for _, t in toks})))
                                                                                       for p, toks in found.items())))
    return f


# --- side-files -----------------------------------------------------------------------------------------------------------------------------------
def brace_names(text, after):
    i = text.find(after)
    if i < 0:
        return None
    m = re.search(r"\{([^{}]*)\}", text[i + len(after):])
    return None if not m else [x.strip() for x in m.group(1).split(",") if x.strip()]


DRAFT_OMITS = {"MD5SUMS": "only the local route writes it; the hosted publish job has no such file to attach"}


def case_side_files(T):
    f = []
    for p in (TOOL, PUBLISHER, CHECKLIST, BUILD_WF):
        if not T.has(p):
            return [p + " is missing"]
    try:
        mod = load_tool(T)
        tool = set(mod.SIDE_FILES)
        patterns = [p.replace("{base}", "<base>") for p in mod.EDITIONS["plasma"]["side"]]
    except Exception as exc:
        return [at(TOOL, 0, "SIDE_FILES and the Plasma side-file patterns cannot be read: %s: %s" % (type(exc).__name__, exc))]
    common = {"manifest.json", "latest.json"}

    def compare(path, no, what, names):
        got = set(names) - common
        if got != tool:
            f.append(at(path, no, "%s names %s, and %s publishes %s" % (what, sorted(got), TOOL.split("/")[-1], sorted(tool))))

    header = [(n, t) for n, t in enumerate(T.lines(PUBLISHER), 1)]
    layout = next(((n, brace_names(t, "<prefix>/<version>/")) for n, t in header if "<prefix>/<version>/{" in t), None)
    if layout is None or layout[1] is None:
        f.append(at(PUBLISHER, 0, "the header has no layout line <prefix>/<version>/{...}"))
    else:
        compare(PUBLISHER, layout[0], "the header layout", layout[1])
    clines = T.lines(CHECKLIST)
    row = next(((n, re.findall(r"`([^`]+)`", t.split("|")[1])) for n, t in enumerate(clines, 1)
                if t.startswith("|") and t.count("|") > 2 and "`SHA256SUMS`" in t.split("|")[1] and "`manifest.json`" in t.split("|")[1]), None)
    if row is None:
        f.append(at(CHECKLIST, 0, "has no row of the layout table that lists SHA256SUMS and manifest.json"))
    else:
        compare(CHECKLIST, row[0], "the layout table", row[1])
    keys = next(((n, brace_names(t, "os/<version>/")) for n, t in enumerate(clines, 1) if t.startswith("Keys:")), None)
    if keys is None or keys[1] is None:
        f.append(at(CHECKLIST, 0, "has no Keys: line with os/<version>/{...}"))
    else:
        compare(CHECKLIST, keys[0], "the Keys line", keys[1])
    for path, text in ((PUBLISHER, T.text(PUBLISHER)), (CHECKLIST, T.text(CHECKLIST))):
        for pat in patterns:
            if pat not in text:
                f.append(at(path, 0, "does not name %s, a file that the Plasma edition publishes beside its image" % pat))
    draft = []
    wl = T.lines(BUILD_WF)
    for i, line in enumerate(wl):
        if re.match(r"^\s*files:\s*\|\s*$", line):
            base = indent_of(line)
            for t in wl[i + 1:]:
                m = re.match(r"^\s+release/([A-Za-z0-9._-]+)\s*$", t)
                if not m or indent_of(t) <= base:
                    break
                draft.append(m.group(1))
    if not draft:
        f.append(at(BUILD_WF, 0, "attaches no files to the draft release (files: | release/...)"))
    else:
        extra, missing = set(draft) - tool, tool - set(draft)
        if extra:
            f.append(at(BUILD_WF, 0, "the draft release attaches %s, which %s does not publish" % (sorted(extra), TOOL.split("/")[-1])))
        for name in sorted(missing):
            if name not in DRAFT_OMITS:
                f.append(at(BUILD_WF, 0, "the draft release does not attach %s, which %s publishes" % (name, TOOL.split("/")[-1])))
        for name in DRAFT_OMITS:
            if name in draft:
                f.append("DRAFT_OMITS lists %s, which the draft release attaches now: delete the entry" % name)
        if not {"SHA256SUMS", "SHA256SUMS.asc"} <= set(draft):
            f.append(at(BUILD_WF, 0, "the draft release must attach SHA256SUMS and SHA256SUMS.asc together, or a download cannot be checked"))
    return f


# --- repro-claims ---------------------------------------------------------------------------------------------------------------------------------
def case_repro_claims(T):
    f = []
    if not T.has(REPRO_ALLOW):
        return [REPRO_ALLOW + " is missing (the baseline of the document lines that may say reproducible)"]
    entries = []
    for no, line in enumerate(T.lines(REPRO_ALLOW), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3 or not all(x.strip() for x in parts):
            f.append(at(REPRO_ALLOW, no, "needs three tab separated fields: path, a fixed substring of the line, the reason"))
            continue
        entries.append([parts[0].strip(), parts[1], no, False])
    for path in T.all:
        if path.startswith("docs/evidence/") or not (path.startswith("docs/") and path.endswith(".md") or path.split("/")[-1] == "README.md"):
            continue
        for no, line in enumerate(T.lines(path), 1):
            if "reproducib" not in line.lower():
                continue
            for e in entries:
                if e[0] == path and e[1] in line:
                    e[3] = True
                    break
            else:
                f.append(at(path, no, "says 'reproducib...': an image is called reproducible only after a recorded two-build comparison under docs/evidence; "
                                      "a line about something else is listed, with its reason, in " + REPRO_ALLOW))
    for path, sub, no, hit in entries:
        if not hit:
            f.append(at(REPRO_ALLOW, no, "lists %r in %s, and no such line exists any more: delete the entry" % (sub, path)))
    return f


# --- counts ---------------------------------------------------------------------------------------------------------------------------------------
NUMBERS = {w: i for i, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve".split())}
COUNT_DOCS = ("CLAUDE.md", "docs/guides/iso-build-guide.md", CHECKLIST, "docs/guides/running-the-tests.md")


def case_counts(T):
    f = []
    n = len(T.workflows())
    for path in COUNT_DOCS:
        if not T.has(path):
            f.append(path + " is missing")
            continue
        for no, line in enumerate(T.lines(path), 1):
            for m in re.finditer(r"\b(%s|[0-9]+)\s+(?:GitHub\s+)?workflows\b" % "|".join(NUMBERS), line, re.I):
                word = m.group(1).lower()
                value = int(word) if word.isdigit() else NUMBERS[word]
                if value != n:
                    f.append(at(path, no, 'says "%s workflows", and .github/workflows holds %d' % (m.group(1), n)))
    return f


CASES = (("sig-name", case_sig_name), ("image-grammar", case_image_grammar), ("workflow-claims", case_workflow_claims),
         ("artifact-names", case_artifact_names), ("ci-md", case_ci_md), ("pins-agree", case_pins_agree), ("image-ref", case_image_ref),
         ("side-files", case_side_files), ("repro-claims", case_repro_claims), ("counts", case_counts))


def run_all(root):
    T = Tree(root)
    for name, fn in CASES:
        try:
            found = fn(T)
        except Skip as why:
            print("SKIP %s: %s" % (name, why))
            continue
        except CannotRun:
            raise
        except Exception as exc:                                            # a case that cannot run is a failure, never a pass
            print("FAIL %s: the case itself broke: %s: %s" % (name, type(exc).__name__, exc))
            continue
        if found:
            for item in found[:20]:
                print("FAIL %s: %s" % (name, str(item).replace("\n", " ")))
            if len(found) > 20:
                print("FAIL %s: ... and %d more" % (name, len(found) - 20))
        else:
            print("PASS %s" % name)


# --- helpers for the planted changes: a copy of the file set, and edits of it that must apply --------------------------------------------------
def copy_tree(src, dst):
    T = Tree(src)
    scanned = set(T.scanned())
    for p in T.all:
        if p == SELF or p.startswith("docs/evidence/") or not T.has(p):
            continue
        if p in scanned or p.split("/")[-1] == "README.md":
            target = os.path.join(dst, p)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(os.path.join(src, p), target)


def edit(root, rel, fn):
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    new = fn(text)
    if new is None or new == text:
        print("the planted change did not apply to %s" % rel, file=sys.stderr)
        sys.exit(1)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(new)


def pin_image(root, digest, other_path=None, other_digest=None):
    """Write the build image in all six places as ubuntu:26.04@sha256:<digest> (one place, if named, with another digest)."""
    for path, pattern in IMAGE_PLACES:
        want = "ubuntu:26.04@sha256:" + (other_digest if path == other_path else digest)

        def fn(text, pattern=pattern, want=want):
            out, n = [], 0
            for line in text.split("\n"):
                m = pattern.search(line)
                if m:
                    line = line[:m.start(1)] + want + line[m.end(1):]
                    n += 1
                out.append(line)
            return "\n".join(out) if n else None
        edit(root, path, fn)


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    try:
        if mode == "check":
            run_all(argv[2])
        elif mode == "copy":
            copy_tree(argv[2], argv[3])
        elif mode == "sub":                                                      # sub ROOT REL OLD NEW: every occurrence of OLD becomes NEW
            edit(argv[2], argv[3], lambda t: t.replace(argv[4], argv[5]) if argv[4] in t else None)
        elif mode == "resub":                                                    # resub ROOT REL REGEX NEW
            edit(argv[2], argv[3], lambda t: re.sub(argv[4], argv[5], t) if re.search(argv[4], t) else None)
        elif mode == "delete-lines":                                             # delete-lines ROOT REL SUBSTRING
            edit(argv[2], argv[3], lambda t: "\n".join(x for x in t.split("\n") if argv[4] not in x) if argv[4] in t else None)
        elif mode == "ci-entry":                                                 # ci-entry ROOT NAME FILE: an entry of docs/CI.md in the generated form
            entry = "\n**%s** \u2014 `%s`\n\n```bash\ngh workflow run %s --repo companionintelligence/CI-OS --ref main\n```\n" % (argv[3], argv[4], argv[4])
            edit(argv[2], CI_MD, lambda t: t + entry)
        elif mode == "append":                                                   # append ROOT REL TEXT
            edit(argv[2], argv[3], lambda t: t + argv[4] + "\n")
        elif mode == "add":                                                      # add ROOT REL: the content comes from stdin
            target = os.path.join(argv[2], argv[3])
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w", encoding="utf-8") as fh:
                fh.write(sys.stdin.read())
        elif mode == "pin-image":                                                # pin-image ROOT DIGEST [PATH OTHER_DIGEST]
            pin_image(argv[2], argv[3], *(argv[4:6] if len(argv) > 5 else ()))
        else:
            print("usage: names.py check|copy|sub|resub|delete-lines|append|add|pin-image ...", file=sys.stderr)
            return 2
    except CannotRun as exc:
        print("cannot run here: %s" % exc, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PYEOF

py() { python3 -I "$PY" "$@"; }

# The image name ci_iso_file_name builds for a build on 2026-10-18, from EDITION_ISO_NAME and EDITION_ARCH of the lock under ROOT (the real function
# of the CachyOS build scripts, so the Plasma grammar is tied to its one source and not written twice).
plasma_iso_name() {
  ( cd "$1" 2>/dev/null \
      && EDITION_ISO_NAME="$(sed -n 's/^EDITION_ISO_NAME=//p' backends/cachyos/upstream.lock)" \
      && EDITION_ARCH="$(sed -n 's/^EDITION_ARCH=//p' backends/cachyos/upstream.lock)" \
      && export EDITION_ISO_NAME EDITION_ARCH \
      && . backends/cachyos/iso/scripts/lib/common.sh \
      && ci_iso_file_name 1792349378 ) 2>/dev/null
}

run_checks() { # ROOT: one PASS, SKIP or FAIL line per case
  RN_PLASMA_ISO="$(plasma_iso_name "$1")" py check "$1"
}

# --- 1. the repository -----------------------------------------------------------------------------------------------------------------------
echo "== the repository"
OUT="$(run_checks "$REPO")"; RC=$?
if [[ $RC -eq 2 ]]; then echo "cannot run here: $OUT" >&2; exit 2; fi
while IFS= read -r line; do
  case "$line" in
    PASS\ *) pass "${line#PASS }" ;;
    SKIP\ *) SKIPPED=$((SKIPPED + 1)); printf 'SKIP  %s\n' "${line#SKIP }" ;;
    FAIL\ *) fail "${line#FAIL }" ;;
    '') ;;
    *) fail "unexpected output: $line" ;;
  esac
done <<<"$OUT"

# --- 2. one planted change per case, in a temp copy ------------------------------------------------------------------------------------------
BASE_COPY="$WORK/base-copy"
py copy "$REPO" "$BASE_COPY" || { echo "cannot copy the file set" >&2; exit 2; }
PIN="$(sed -n 's/^ *BASE_ISO_SHA256_AMD64: *"\([0-9a-f]\{64\}\)".*/\1/p' "$REPO/.github/workflows/build-companion-os-iso.yml")"
FPR="$(sed -n 's/^ *UBUNTU_CD_KEY_FPR: *"\{0,1\}\([0-9A-F]\{40\}\).*/\1/p' "$REPO/.github/workflows/stick-real-iso.yml")"
flip() { # the same string with its last hex digit changed (to a digit of the same case)
  local last="${1: -1}" new
  case "$last" in
    [A-F]) new=E; [[ "$last" == E ]] && new=F ;;
    *)     new=e; [[ "$last" == e ]] && new=f ;;
  esac
  printf '%s%s' "${1%?}" "$new"
}
FAKE_A="$(printf 'a%.0s' $(seq 1 64))"; FAKE_B="$(printf 'b%.0s' $(seq 1 64))"

SB=backends/ubuntu/iso/scripts
mutate_sig_build()       { py sub "$1" $SB/build-iso.sh '--detach-sign --output SHA256SUMS.asc' '--detach-sign --output SHA256SUMS.gpg'; }
mutate_sig_publisher()   { py sub "$1" $SB/publish-r2.sh '"$DIR/SHA256SUMS.asc"' '"$DIR/SHA256SUMS.gpg"'; }
mutate_sig_doc()         { py sub "$1" docs/guides/installation-guide.md 'gpg --verify SHA256SUMS.asc SHA256SUMS' 'gpg --verify SHA256SUMS.gpg SHA256SUMS'; }
mutate_sig_stale()       { py delete-lines "$1" docs/guides/iso-build-guide.md 'SHA256SUMS.gpg'; }
mutate_plasma_re()       { py sub "$1" $SB/release-manifest.py '(\d{4}\.\d{2}\.\d{2})' '(.+)'; }
mutate_ubuntu_re()       { py sub "$1" $SB/release-manifest.py '(amd64|arm64)\.iso' '(amd64|arm64|x86_64)\.iso'; }
mutate_lock_arch()       { py sub "$1" backends/cachyos/upstream.lock 'EDITION_ARCH=x86_64' 'EDITION_ARCH=aarch64'; }
mutate_sig_workflow()    { py sub "$1" .github/workflows/build-companion-os-iso.yml '  UBUNTU_VERSION: "26.04"' $'  # the release is signed to SHA256SUMS.gpg\n  UBUNTU_VERSION: "26.04"'; }
mutate_always_on()       { py sub "$1" .github/workflows/build-companion-os-iso.yml 'name: Build Companion OS ISO' $'name: Build Companion OS ISO\n\n# Always-on: every PR is built.'; }
mutate_claim_script()    { py sub "$1" core/lib/check-repo.sh '# Fast repo checks: run them before any push.' '# Fast repo checks, run on every PR and before any push.'; }
mutate_artifact_default() { py sub "$1" .github/workflows/stick-real-iso.yml "default: 'companion-os-amd64'" "default: 'ci-os-iso'"; }
mutate_ci_md_stale()     { py ci-entry "$1" 'Gone' gone.yml; }
mutate_ci_md_input()     { py resub "$1" docs/CI.md ' -f ci_os_artifact=[^ ]*' ''; }
mutate_pin_digit()       { py sub "$1" docs/guides/release-checklist.md "$PIN" "$(flip "$PIN")"; }
mutate_pin_abbrev()      { py sub "$1" docs/guides/release-checklist.md "${PIN:0:8}...${PIN: -4}" "${PIN:0:8}...$(flip "${PIN: -4}")"; }
mutate_pin_oneclick()    { py sub "$1" backends/ubuntu/chroot/tests/oneclick-subiquity-dryrun.sh "$PIN" "$(flip "$PIN")"; }
mutate_pin_fpr()         { py sub "$1" .github/workflows/stick-real-iso.yml "$FPR" "$(flip "$FPR")"; }
mutate_fifth_workflow()  {
  printf 'name: Extra checks\non:\n  workflow_dispatch:\n' | py add "$1" .github/workflows/extra-checks.yml && py ci-entry "$1" 'Extra checks' extra-checks.yml
}
mutate_side_header()     { py sub "$1" $SB/publish-r2.sh '{SHA256SUMS,SHA256SUMS.asc,MD5SUMS,SBOM.txt,manifest.json}' '{SHA256SUMS,SHA256SUMS.asc,SBOM.txt,manifest.json}'; }
mutate_side_checklist()  { py sub "$1" docs/guides/release-checklist.md '`SHA256SUMS.asc`, `MD5SUMS`, `SBOM.txt`' '`SHA256SUMS.asc`, `SBOM.txt`'; }
mutate_side_plasma()     { py sub "$1" docs/guides/release-checklist.md '<base>.pkgs.txt' '<base>.packages'; }
mutate_side_draft()      { py sub "$1" .github/workflows/build-companion-os-iso.yml 'release/SBOM.txt' 'release/NOTES.txt'; }
mutate_imgref_landed()   { py pin-image "$1" "$FAKE_A"; }
mutate_imgref_drift()    { py pin-image "$1" "$FAKE_A" backends/ubuntu/iso/scripts/build-in-docker.sh "$FAKE_B"; }
mutate_repro_readme()    { py append "$1" backends/ubuntu/iso/README.md 'The builds are reproducible.'; }
mutate_repro_stale()     { py delete-lines "$1" docs/architecture/supported-targets.md 'Reproducible package set'; }

plant() { # NAME WANTED_CASE DESCRIPTION: the change is made by mutate_NAME, then exactly WANTED_CASE (and no other) must be red
  local name="$1" want="$2" what="$3" copy="$WORK/copy-$1" out failed
  rm -rf "$copy"; cp -R "$BASE_COPY" "$copy"
  if ! "mutate_$name" "$copy" 2>"$WORK/mutate.err"; then fail "planted: $what (the change did not apply: $(head -n 1 "$WORK/mutate.err"))"; return; fi
  out="$(run_checks "$copy")"
  failed="$(printf '%s\n' "$out" | sed -n 's/^FAIL \([a-z-]*\):.*/\1/p' | sort -u | tr '\n' ' ')"
  if [[ "$failed" == "$want " ]]; then pass "planted: $what: only $want is red"
  else fail "planted: $what: red cases are '${failed:-none}', wanted '$want'"; printf '%s\n' "$out" | grep -E '^(FAIL|SKIP)' | head -n 6 | sed 's/^/        /'; fi
  rm -rf "$copy"
}

echo
echo "== one defect planted per case: exactly that case goes red"
plant sig_build          sig-name        "the build signs to SHA256SUMS.gpg"
plant sig_publisher      sig-name        "the publisher looks for SHA256SUMS.gpg"
plant sig_doc            sig-name        "the installation guide tells people to verify with SHA256SUMS.gpg"
plant sig_stale          sig-name        "an allow-list entry for Ubuntu's stock file whose lines are gone"
plant sig_workflow       sig-name        "the workflow names SHA256SUMS.gpg outside the stock download and verify steps"
plant plasma_re          image-grammar   "the Plasma image-name pattern accepts any date"
plant ubuntu_re          image-grammar   "the Ubuntu image-name pattern accepts x86_64"
plant lock_arch          image-grammar   "EDITION_ARCH in the lock is not the architecture the tool accepts"
plant always_on          workflow-claims "a manual workflow header says always-on"
plant claim_script       workflow-claims "the header of check-repo.sh says it runs on every PR"
plant artifact_default   artifact-names  "stick-real-iso.yml defaults to an artifact nobody uploads"
plant ci_md_input        ci-md           "docs/CI.md lacks a workflow_dispatch input"
plant ci_md_stale        ci-md           "docs/CI.md has an entry for a workflow file that is gone"
plant fifth_workflow     counts          "a fifth workflow file (with its docs/CI.md entry)"
plant pin_digit          pins-agree      "one digit of the base ISO pin changed in a document"
plant pin_abbrev         pins-agree      "the abbreviated pin ends differently"
plant pin_oneclick       pins-agree      "the one-click dry run pins another ISO"
plant pin_fpr            pins-agree      "the CD key fingerprint differs between two workflows"
plant side_header        side-files      "the publisher header leaves a published file out"
plant side_checklist     side-files      "the checklist table leaves a published file out"
plant side_plasma        side-files      "the checklist does not name a Plasma side file"
plant side_draft         side-files      "the draft release attaches a file nobody publishes"
plant repro_readme       repro-claims    "a README says the builds are reproducible"
plant repro_stale        repro-claims    "a baseline entry whose line is gone"

# image-ref skips until the image is pinned; with the pin written in all six places it must pass, and with one place on another digest it must fail
copy="$WORK/copy-imgref"; rm -rf "$copy"; cp -R "$BASE_COPY" "$copy"
if mutate_imgref_landed "$copy" 2>"$WORK/mutate.err"; then
  out="$(run_checks "$copy")"
  if [[ "$(printf '%s\n' "$out" | grep -c '^PASS image-ref$')" == 1 && -z "$(printf '%s\n' "$out" | grep '^FAIL')" ]]; then pass "planted: the build image pinned in all six places: image-ref passes (it is not skipped)"
  else fail "planted: the build image pinned in all six places: image-ref should pass and no case fail"; printf '%s\n' "$out" | grep -E '^(FAIL|SKIP)' | head -n 6 | sed 's/^/        /'; fi
else fail "planted: pinning the build image in the copy (the change did not apply: $(head -n 1 "$WORK/mutate.err"))"; fi
rm -rf "$copy"
plant imgref_drift       image-ref       "one place names another build image digest"

echo
echo "== Summary: $PASS passed, $FAIL failed, $SKIPPED skipped"
[[ $FAIL -eq 0 ]]
