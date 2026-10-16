# Package names the Companion OS installer will ask pacman for, read from the overlay's own YAML.
#
# One reader for three users, so that "what the installer installs" has a single definition:
#   - calamares-online.sh (live system) runs it before Calamares starts, to refuse a package list that
#     the repositories can no longer satisfy BEFORE the user partitions a disk;
#   - packages/check-packages.py (maintainer tool) checks the names against archlinux.org / the CachyOS repo
#     database and writes the fixture the offline tests use;
#   - iso/tests/installer-config.sh asserts invariants over the same names.
#
# It reads, from the overlay directory:
#   modules/pacstrap.conf        `basePackages:`, the base system pacstrap installs first (a failure there happens
#                                after the disk has been written, so these names matter most to the preflight)
#   pacstrap-code-added.list     the packages pacstrap/main.py appends to basePackages IN CODE (see that file)
#   modules/packages_online.conf `operations:` -> `install:` lists, which Calamares' packages job runs for every install
#   modules/netinstall.yaml      the groups of the package selection page. Calamares' netinstall module installs a
#                                group when it is `selected` (the user can untick it unless `hidden`);
#                                `hidden: true, selected: true` groups are the always-on base, `selected: false` groups are opt-in.
#
# Sets:
#   always    basePackages + the "always" names of pacstrap-code-added.list + operations + every netinstall group (and
#             subgroup) that is selected by default and not platform-restricted to something other than "desktop"
#   optional  netinstall groups that are not selected by default + the "optional" names of pacstrap-code-added.list
#   all       both
# The "unused" names of pacstrap-code-added.list are in neither set. Names that contain "$" (firefox-i18n-$LOCALE) are
# Calamares placeholders and are skipped.
#
# Usage: python3 -I ci-pkglist.py <overlay-dir> [always|optional|all]     one name per line, sorted, unique
# Needs PyYAML (python-yaml is in the live image: Calamares' own Python modules need it).
import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - reported to the caller, which decides the policy
    sys.stderr.write("ci-pkglist: PyYAML (python-yaml) is not installed\n")
    sys.exit(3)


def _load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


CODE_LIST = "pacstrap-code-added.list"
CODE_SETS = ("always", "optional", "unused")


def base_packages(overlay):
    """Names in modules/pacstrap.conf basePackages: the base system, installed before any Calamares package job."""
    conf = _load(os.path.join(overlay, "modules", "pacstrap.conf")) or {}
    names = conf.get("basePackages")
    if not isinstance(names, list) or not names:
        raise ValueError("modules/pacstrap.conf has no basePackages list")
    return [str(n) for n in names]


def code_added(overlay):
    """{set: [names]} of pacstrap-code-added.list ("set | package | why" lines): packages pacstrap/main.py adds in code."""
    out = {k: [] for k in CODE_SETS}
    with open(os.path.join(overlay, CODE_LIST), "r", encoding="utf-8") as fh:
        for number, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            fields = [f.strip() for f in line.split("|")]
            if len(fields) < 2 or fields[0] not in CODE_SETS or not re.match(r"^[A-Za-z0-9@._+-]+$", fields[1]):
                raise ValueError("%s:%d: expected 'always|optional|unused | package | why', got: %s" % (CODE_LIST, number, raw.strip()))
            out[fields[0]].append(fields[1])
    return out


def operations(overlay):
    """Names in packages_online.conf operations (install / try_install lists)."""
    conf = _load(os.path.join(overlay, "modules", "packages_online.conf")) or {}
    names = []
    for entry in conf.get("operations") or []:
        for key, value in entry.items():
            if key in ("install", "try_install", "localInstall") and isinstance(value, list):
                names.extend(str(v) for v in value)
    return names


def _walk(groups, parent_selected, always, optional):
    """A group installs when it is selected AND its parent is; a missing `selected` means false (Calamares' default)."""
    for group in groups or []:
        platform = group.get("platform")
        # A group for another platform (handheld) is never installed on a desktop.
        if platform not in (None, "desktop"):
            continue
        selected = parent_selected and bool(group.get("selected", False))
        for pkg in group.get("packages") or []:
            (always if selected else optional).append(str(pkg))
        _walk(group.get("subgroups"), selected, always, optional)


def netinstall(overlay):
    """(always, optional) name lists of netinstall.yaml."""
    groups = _load(os.path.join(overlay, "modules", "netinstall.yaml")) or []
    always, optional = [], []
    _walk(groups, True, always, optional)
    return always, optional


def package_sets(overlay):
    ops = operations(overlay)
    net_always, net_optional = netinstall(overlay)
    code = code_added(overlay)
    always = sorted({n for n in ops + net_always + base_packages(overlay) + code["always"] if "$" not in n})
    optional = sorted({n for n in net_optional + code["optional"] if "$" not in n} - set(always))
    return always, optional


def main(argv):
    if len(argv) < 2 or len(argv) > 3:
        sys.stderr.write(__doc__ or "")
        return 2
    which = argv[2] if len(argv) == 3 else "all"
    if which not in ("always", "optional", "all"):
        sys.stderr.write("ci-pkglist: set must be always, optional or all\n")
        return 2
    try:
        always, optional = package_sets(argv[1])
    except (OSError, ValueError, yaml.YAMLError) as exc:
        sys.stderr.write("ci-pkglist: cannot read the overlay: %s\n" % exc)
        return 1
    names = {"always": always, "optional": optional, "all": sorted(set(always) | set(optional))}[which]
    for name in names:
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
