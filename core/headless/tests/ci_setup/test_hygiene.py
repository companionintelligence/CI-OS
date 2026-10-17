"""Repository and portability hygiene for the library and its tests.

* importing any module has no side effects (checked with an audit hook in a fresh interpreter);
* nothing needs root;
* the code stays inside Python 3.8 syntax and standard library (checked on the AST; the tests also run on newer Pythons);
* no unused imports; every module has a docstring;
* the repository rules that apply here: shebang files are executable, no block-letter art, no retired product names;
* every fixture is listed in fixtures/MANIFEST.json with an honest origin.
"""
import ast
import json
import os
import re
import stat
import subprocess
import sys
import unittest

import helpers

PKG = os.path.join(helpers.HEADLESS, "ci_setup")
TESTS = helpers.HERE


def py_files(*roots):
    out = []
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in ("__pycache__", "fixtures", "golden")]
            for name in sorted(filenames):
                if name.endswith(".py"):
                    out.append(os.path.join(dirpath, name))
    return out


def all_files(*roots):
    out = []
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d != "__pycache__"]
            out.extend(os.path.join(dirpath, n) for n in sorted(filenames))
    return out


def rel(path):
    return os.path.relpath(path, helpers.HEADLESS)


class ImportSideEffects(unittest.TestCase):
    PROBE = r'''
import sys, os, pkgutil, importlib
events = []
pkg_dir = os.path.realpath(sys.argv[1])
sys.path.insert(0, os.path.dirname(pkg_dir))
std_dirs = tuple(os.path.realpath(p) for p in {os.path.dirname(os.__file__), os.path.dirname(os.path.dirname(os.__file__)), sys.prefix, sys.base_prefix, sys.exec_prefix})
FORBID = ("subprocess.Popen", "os.system", "os.exec", "os.posix_spawn", "os.spawn", "os.fork", "os.forkpty", "os.kill",
          "socket.__new__", "socket.connect", "socket.bind", "socket.sendto", "os.remove", "os.rename", "os.mkdir", "os.rmdir",
          "os.chmod", "os.chown", "os.symlink", "os.link", "os.truncate", "shutil.copyfile", "shutil.rmtree", "shutil.move",
          "ctypes.dlopen", "urllib.Request", "http.client.connect", "tempfile.mkdtemp", "tempfile.mkstemp", "os.putenv", "os.unsetenv",
          "signal.signal" if False else "os.kill")
def hook(event, args):
    if event == "open":
        path, mode, flags = args
        p = os.path.realpath(path) if isinstance(path, (str, bytes)) and path != "" and not isinstance(path, int) else None
        writing = (isinstance(flags, int) and flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND)) or (isinstance(mode, str) and any(c in mode for c in "wax+"))
        if writing:
            events.append(("write-open", str(path)))
        elif p is not None and not (p.startswith(pkg_dir) or p.startswith(std_dirs) or p in ("/dev/urandom", "/dev/random")):
            events.append(("read-open-outside", str(path)))
    elif event in FORBID or event.startswith(("subprocess.", "socket.connect", "socket.bind", "os.exec", "os.spawn")):
        events.append((event, str(args)[:80]))
sys.addaudithook(hook)
import ci_setup
mods = ["ci_setup"]
for m in pkgutil.walk_packages(ci_setup.__path__, "ci_setup."):
    mods.append(m.name)
for name in mods:
    if name.endswith("__main__"):
        continue
    importlib.import_module(name)
print("MODULES", len(mods))
for e in events:
    print("EVENT", e)
'''

    def test_importing_every_module_does_nothing(self):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        res = subprocess.run([sys.executable, "-I", "-B", "-c", self.PROBE, PKG], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=env, cwd=os.path.dirname(helpers.HEADLESS), timeout=120)
        out = res.stdout.decode()
        self.assertEqual(0, res.returncode, res.stderr.decode()[-2000:])
        modules = int(re.search(r"MODULES (\d+)", out).group(1))
        self.assertGreaterEqual(modules, 25)
        events = [ln for ln in out.splitlines() if ln.startswith("EVENT")]
        self.assertEqual([], events)

    def test_the_probe_would_notice_a_side_effect(self):
        """Sanity check of the audit hook itself: a module that opens a file at import time is reported."""
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "evilpkg"))
            with open(os.path.join(tmp, "evilpkg", "__init__.py"), "w") as fh:
                fh.write("")
            with open(os.path.join(tmp, "evilpkg", "bad.py"), "w") as fh:
                fh.write("import subprocess\nsubprocess.run(['true'])\nopen('/etc/hosts').read()\nopen(%r, 'w').write('x')\n"
                         % os.path.join(tmp, "out.txt"))
            probe = self.PROBE.replace("ci_setup", "evilpkg")
            res = subprocess.run([sys.executable, "-I", "-B", "-c", probe, os.path.join(tmp, "evilpkg")], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"), timeout=60)
            out = res.stdout.decode()
            self.assertIn("subprocess.Popen", out)
            self.assertIn("read-open-outside", out)
            self.assertIn("write-open", out)


class NoRoot(unittest.TestCase):
    def test_nothing_asks_for_privilege(self):
        banned = re.compile(r"\b(geteuid|getuid|setuid|setgid|seteuid|sudo|su -|pkexec|CAP_NET_ADMIN)\b")
        for path in py_files(PKG):
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            for lineno, line in enumerate(text.splitlines(), 1):
                code = line.split("#", 1)[0]
                if banned.search(code) and "ci_setup/tests" not in path:
                    self.fail("%s:%d mentions a privilege call: %s" % (rel(path), lineno, line.strip()))

    def test_runs_as_the_current_user_here(self):
        # the whole suite runs unprivileged on a laptop; this documents the requirement
        self.assertTrue(os.geteuid() != 0 or os.environ.get("CI_SETUP_ALLOW_ROOT_TESTS", "1") == "1")


# --------------------------------------------------------------------------------------------------------------------
# Python 3.8 compatibility on the AST
# --------------------------------------------------------------------------------------------------------------------

NEWER_ATTRS = {
    "removeprefix": "3.9", "removesuffix": "3.9", "bit_count": "3.10", "randbytes": "3.9", "lcm": "3.9", "StrEnum": "3.11",
    "UTC": "3.11", "ExceptionGroup": "3.11", "TaskGroup": "3.11", "ParamSpec": "3.10", "TypeAlias": "3.10", "TypeGuard": "3.10",
    "Self": "3.11", "assertNoLogs": "3.10", "aiter": "3.10", "anext": "3.10", "pairwise": "3.10", "cache": "3.9",
    "is_relative_to": "3.9", "readlink": None, "with_stem": "3.9", "get_overloads": "3.11", "fromisocalendar": "3.8",
    "to_thread": "3.9", "tomllib": "3.11", "from_iterable_strict": None,
}
NEWER_ATTRS = {k: v for k, v in NEWER_ATTRS.items() if v and v > "3.8"}
NEWER_IMPORTS = {"zoneinfo", "graphlib", "tomllib", "match"}
BUILTIN_GENERICS = {"list", "dict", "tuple", "set", "frozenset", "type"}


class Py38(unittest.TestCase):
    def check(self, path):
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        problems = []
        try:
            tree = ast.parse(src, filename=path, feature_version=(3, 8))
        except SyntaxError as exc:
            return ["%s: not Python 3.8 syntax: %s" % (rel(path), exc)]
        annotation_nodes = set()
        for node in ast.walk(tree):
            anns = []
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                anns = [a.annotation for a in node.args.args + node.args.kwonlyargs + node.args.posonlyargs if a.annotation]
                for extra in (node.args.vararg, node.args.kwarg):
                    if extra is not None and extra.annotation is not None:
                        anns.append(extra.annotation)
                if node.returns is not None:
                    anns.append(node.returns)
            elif isinstance(node, ast.AnnAssign):
                anns = [node.annotation]
            for a in anns:
                for sub in ast.walk(a):
                    annotation_nodes.add(id(sub))
        has_future = "from __future__ import annotations" in src
        for node in ast.walk(tree):
            if isinstance(node, ast.Attribute) and node.attr in NEWER_ATTRS:
                problems.append("%s:%d uses .%s (Python %s)" % (rel(path), node.lineno, node.attr, NEWER_ATTRS[node.attr]))
            if isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name.split(".")[0] in NEWER_IMPORTS:
                        problems.append("%s:%d imports %s" % (rel(path), node.lineno, alias.name))
            if isinstance(node, ast.ImportFrom) and node.module and node.module.split(".")[0] in NEWER_IMPORTS:
                problems.append("%s:%d imports from %s" % (rel(path), node.lineno, node.module))
            if isinstance(node, ast.ImportFrom) and node.module == "typing":
                for alias in node.names:
                    if alias.name in NEWER_ATTRS:
                        problems.append("%s:%d imports typing.%s" % (rel(path), node.lineno, alias.name))
            if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) and node.value.id in BUILTIN_GENERICS:
                if id(node) not in annotation_nodes or not has_future:
                    problems.append("%s:%d subscripts builtin %s at run time (Python 3.9+)" % (rel(path), node.lineno, node.value.id))
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "zip":
                if any(k.arg == "strict" for k in node.keywords):
                    problems.append("%s:%d zip(strict=) is Python 3.10+" % (rel(path), node.lineno))
            if isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr):
                for side in (node.left, node.right):
                    if isinstance(side, ast.Constant) and side.value is None and id(node) not in annotation_nodes:
                        problems.append("%s:%d X | None at run time (Python 3.10+)" % (rel(path), node.lineno))
            if isinstance(node, ast.Dict) is False and isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr):
                if isinstance(node.left, ast.Dict) or isinstance(node.right, ast.Dict):
                    problems.append("%s:%d dict | dict (Python 3.9+)" % (rel(path), node.lineno))
        has_annotations = any(isinstance(n, (ast.FunctionDef, ast.AnnAssign)) and (
            getattr(n, "returns", None) is not None or isinstance(n, ast.AnnAssign)) for n in ast.walk(tree))
        if has_annotations and "ci_setup/" in path.replace(os.sep, "/") and not has_future and "/tests/" not in path.replace(os.sep, "/"):
            problems.append("%s has annotations but no `from __future__ import annotations`" % rel(path))
        return problems

    def test_package(self):
        problems = []
        for path in py_files(PKG):
            problems.extend(self.check(path))
        self.assertEqual([], problems)

    def test_tests(self):
        problems = []
        for path in py_files(TESTS):
            problems.extend(self.check(path))
        self.assertEqual([], problems)

    def test_the_checker_catches_what_it_should(self):
        import tempfile
        bad = ("from __future__ import annotations\nimport zoneinfo\nx = 'a'.removeprefix('a')\ny = list[int]\n"
               "z = {1: 2} | {3: 4}\nfor a, b in zip([1], [2], strict=True):\n    pass\n")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "bad.py")
            with open(path, "w") as fh:
                fh.write(bad)
            problems = self.check(path)
        joined = "\n".join(problems)
        for needle in ("zoneinfo", "removeprefix", "list at run time", "dict | dict", "zip(strict="):
            self.assertIn(needle if needle != "list at run time" else "builtin list", joined, needle)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "m.py")
            with open(path, "w") as fh:
                fh.write("match x:\n    case 1:\n        pass\n")
            self.assertTrue(self.check(path))


class Imports(unittest.TestCase):
    def test_no_unused_imports_and_every_module_has_a_docstring(self):
        problems = []
        for path in py_files(PKG, TESTS):
            with open(path, encoding="utf-8") as fh:
                src = fh.read()
            tree = ast.parse(src)
            is_init = os.path.basename(path) == "__init__.py"
            if ast.get_docstring(tree) is None and not (is_init and os.path.getsize(path) == 0):
                problems.append("%s has no module docstring" % rel(path))
            imported = {}
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for a in node.names:
                        imported[(a.asname or a.name).split(".")[0]] = node.lineno
                elif isinstance(node, ast.ImportFrom) and node.module != "__future__":
                    for a in node.names:
                        imported[a.asname or a.name] = node.lineno
            used = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)} | {
                n.value.id for n in ast.walk(tree) if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name)}
            exported = set()
            for node in ast.walk(tree):
                if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "__all__" for t in node.targets):
                    exported = {e.value for e in getattr(node.value, "elts", []) if isinstance(e, ast.Constant)}
            # names used only inside `# type:` comments and string annotations count as used
            for name, lineno in imported.items():
                if name in used or name in exported:
                    continue
                if re.search(r"#\s*type:.*\b%s\b" % re.escape(name), src) or re.search(r"['\"].*\b%s\b.*['\"]" % re.escape(name), src):
                    continue
                line = src.splitlines()[lineno - 1]
                if "noqa" in line or is_init:
                    continue
                problems.append("%s:%d imports %s but never uses it" % (rel(path), lineno, name))
        self.assertEqual([], problems)


# --------------------------------------------------------------------------------------------------------------------
# repository rules
# --------------------------------------------------------------------------------------------------------------------

# the retired names of check-repo.sh, spelled in pieces so that this file does not contain them itself
RETIRED = re.compile("|".join([
    "CI" + " OS", "CI-OS" + " Desktop", "CI-OS" + " Blue Teal", "Companion" + " Ubuntu", "Intelligence" + " Operating System",
    "Companion Intelligence" + " OS", "Companion Intelligence" + " [0-9$]"]))


class RepositoryRules(unittest.TestCase):
    def test_shebang_files_are_executable(self):
        bad = []
        for path in all_files(PKG, TESTS):
            if path.endswith((".pyc",)):
                continue
            with open(path, "rb") as fh:
                head = fh.read(2)
            if head == b"#!" and not os.stat(path).st_mode & stat.S_IXUSR:
                bad.append(rel(path))
        self.assertEqual([], bad)

    def test_run_sh_is_executable_and_bash_3_2_clean(self):
        path = os.path.join(TESTS, "run.sh")
        self.assertTrue(os.stat(path).st_mode & stat.S_IXUSR)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        self.assertTrue(text.startswith("#!/usr/bin/env bash"))
        for banned in ("mapfile", "readarray", "declare -A", "${!", "&>>", "|&", "[[ -v", "coproc", "${var,,}", "${var^^}"):
            self.assertNotIn(banned, text, banned)

    def test_no_block_art_and_no_retired_product_names(self):
        for path in all_files(PKG, TESTS):
            if path.endswith(".pyc"):
                continue
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            self.assertNotIn("\u2588", text, rel(path))
            self.assertIsNone(RETIRED.search(text), rel(path))

    def test_no_secrets_committed(self):
        pat = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20}|hf_[A-Za-z0-9]{30}|AKIA[0-9A-Z]{16}|xox[bp]-[0-9]")
        for path in all_files(PKG, TESTS):
            if path.endswith(".pyc"):
                continue
            with open(path, encoding="utf-8", errors="replace") as fh:
                self.assertIsNone(pat.search(fh.read()), rel(path))

    def test_no_build_artifacts(self):
        for path in all_files(PKG, TESTS):
            self.assertFalse(re.search(r"\.(deb|rpm|iso|squashfs|pyc|pyo|so|dylib)$", path), path)

    def test_no_state_is_written_into_the_package_or_tests_by_this_suite(self):
        leftovers = [rel(p) for p in all_files(PKG, TESTS) if ".tmp-" in os.path.basename(p) or p.endswith(".orig")]
        self.assertEqual([], leftovers)

    def test_templates_ship_with_the_package(self):
        names = sorted(os.listdir(os.path.join(PKG, "templates")))
        self.assertEqual(["ci_setup.nft.in", "dnsmasq.conf.in", "hostapd.conf.in"], names)


class DocInSync(unittest.TestCase):
    """docs/architecture/headless-setup.md quotes numbers and a table that the code produces; keep them from drifting."""

    DOC = os.path.normpath(os.path.join(helpers.HEADLESS, "..", "..", "docs", "architecture", "headless-setup.md"))

    def setUp(self):
        if not os.path.exists(self.DOC):
            self.skipTest("docs/architecture/headless-setup.md is not part of this checkout")
        with open(self.DOC, encoding="utf-8") as fh:
            self.text = fh.read()

    def test_the_policy_table_is_the_generated_one(self):
        with open(os.path.join(helpers.GOLDEN, "policy_table.txt"), encoding="utf-8") as fh:
            table = fh.read().rstrip("\n")
        self.assertTrue(table in self.text, "the policy table in the document differs from golden/policy_table.txt")

    def test_the_quoted_configurations_are_the_golden_files(self):
        with open(os.path.join(helpers.GOLDEN, "hostapd_de_2g.conf"), encoding="utf-8") as fh:
            self.assertTrue(fh.read().rstrip("\n") in self.text, "the hostapd example differs from golden/hostapd_de_2g.conf")
        with open(os.path.join(helpers.GOLDEN, "ci_setup.nft"), encoding="utf-8") as fh:
            nft = fh.read()
        chains = nft[nft.index("table inet ci_setup {"):].rstrip("\n").replace("\n\ntable ip", "\n\ntable ip")
        self.assertTrue(chains in self.text, "the nft example differs from golden/ci_setup.nft")

    def test_every_module_and_every_suite_is_mentioned(self):
        for path in py_files(PKG):
            name = os.path.basename(path)
            if name not in ("__init__.py", "__main__.py"):
                self.assertTrue(name in self.text, "the document does not mention " + name)
        for name in sorted(os.listdir(TESTS)):
            if name.startswith("test_") and name.endswith(".py"):
                self.assertTrue(name in self.text, "the document does not mention " + name)
        for name in ("run.sh", "mutation_check.py", "nft_check.sh", "nft_packets.py", "qr_check_macos.sh"):
            self.assertTrue(name in self.text, "the document does not mention " + name)

    def test_the_counts_match(self):
        modules = [p for p in py_files(PKG) if os.path.basename(p) not in ("__init__.py", "__main__.py")]
        self.assertTrue("%d modules" % len(modules) in self.text, "the document should say %d modules" % len(modules))
        sys.path.insert(0, TESTS)
        try:
            import mutation_check
        finally:
            sys.path.remove(TESTS)
        self.assertTrue("%d deliberate bugs" % len(mutation_check.MUTANTS) in self.text,
                        "the document should say %d deliberate bugs" % len(mutation_check.MUTANTS))
        with open(os.path.join(helpers.FIXTURES, "MANIFEST.json"), encoding="utf-8") as fh:
            count = len(json.load(fh)["files"])
        self.assertTrue("lists %d files" % count in self.text, "the document should say the manifest lists %d files" % count)

    def test_the_document_follows_the_repository_rules(self):
        self.assertFalse("\U00002588" in self.text)
        self.assertIsNone(RETIRED.search(self.text), "a retired product name is in the document")
        self.assertFalse("PLACEHOLDER" in self.text, "the document still has a placeholder")


class FixtureProvenance(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(helpers.FIXTURES, "MANIFEST.json"), encoding="utf-8") as fh:
            self.manifest = json.load(fh)

    def test_every_fixture_is_listed_and_every_entry_exists(self):
        on_disk = set()
        for root, _d, files in os.walk(helpers.FIXTURES):
            for name in files:
                full = os.path.join(root, name)
                relp = os.path.relpath(full, helpers.FIXTURES).replace(os.sep, "/")
                if relp == "MANIFEST.json" or relp.startswith("scenarios/"):
                    continue
                on_disk.add(relp)
        listed = set(self.manifest["files"])
        self.assertEqual(sorted(on_disk - listed), [], "fixtures missing from MANIFEST.json")
        self.assertEqual(sorted(listed - on_disk), [], "MANIFEST.json lists files that do not exist")

    def test_origins_are_honest_and_the_real_ones_are_the_real_ones(self):
        for relp, entry in self.manifest["files"].items():
            self.assertIn(entry["origin"], ("synthetic", "captured"), relp)
            self.assertTrue(entry.get("note"), relp)
            if entry["origin"] == "captured":
                self.assertTrue(entry.get("tool"), relp)
        captured = {p for p, e in self.manifest["files"].items() if e["origin"] == "captured"}
        self.assertEqual({"real/ip_j_addr.json", "real/ip_j_link.json", "real/ip_j_route.json", "real/ip_j_route6.json", "sys/zone.tab"}, captured)
        for relp in captured:
            if relp.startswith("real/"):
                self.assertTrue(relp.endswith(".json"))
        self.assertIn("synthetic", self.manifest["legend"])

    def test_scenarios_reference_existing_files(self):
        base = os.path.join(helpers.FIXTURES, "scenarios")
        for name in sorted(os.listdir(base)):
            with open(os.path.join(base, name, "commands.json"), encoding="utf-8") as fh:
                spec = json.load(fh)
            for cmd, target in spec.items():
                self.assertTrue(os.path.exists(os.path.normpath(os.path.join(base, name, target))), (name, cmd, target))


if __name__ == "__main__":
    unittest.main()
