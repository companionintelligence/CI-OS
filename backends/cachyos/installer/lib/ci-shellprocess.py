# Time limits and drift of the `shellprocess` steps of the Companion OS installer.
#
# Why this exists. Calamares' shellprocess module kills a command that runs longer than its `timeout` and fails the installation with
# "failed to finish in N seconds". A config that sets no timeout gets 30 s. The pinned installer's shellprocess_initialize_pacman.conf
# gives only its first command (update-mirrorlist) a timeout; the second one, `bash /etc/calamares/scripts/create-pacman-keyring`
# (pacman-key --init, two pacman -Sy of the keyring packages, pacman-key --populate), got the default 30 s. Under QEMU/TCG the populate
# step alone took about 28 s: ISO #5 died at job 13 of 47 (2 percent) twice, and passed the third time with 2 s to spare. A slow disk, a
# slow Wi-Fi or an old board gets there without an emulator. (Only shellprocess has a 30 s default: the process calls of Calamares' C++
# and Python job modules default to 0, "no timeout", which is why pacstrap, packages, chwd and initcpio ran for 442 s, 586 s, 132 s and
# 93 s on the same install.)
#
# What it checks (three rules, one definition for the launcher's guard, the repository tests and, in a copy, verify-iso.sh):
#   R1  every command of every shellprocess step has an EXPLICIT timeout: its own, or the file's top-level one. Nothing runs on the
#       silent 30 s default.
#   R2  a command that runs a heavy tool has a generous one: at least NET_FLOOR seconds for the network and package tools (pacman,
#       pacman-key, curl, git, rate-mirrors, pip, ...), DISK_FLOOR for the disk and initramfs tools (mkinitcpio, dracut,
#       update-initramfs, grub-install, limine-update, sdboot-manage, plymouth-set-default-theme, locale-gen, btrfs, snapper, cp -a,
#       ...). "Runs" means the command line AND, when its command word is a script (`bash X`, `X`), the text of that script, comments
#       removed. 0 and negative values mean "no limit" to Calamares and do not count as a generous one.
#   R3  a config of the overlay that replaces a stock one still runs every command of the stock one, in the stock one's order, with
#       the same dontChroot (inside the target or on the live system), and has every top-level key of it (so a step upstream adds, or
#       changes where or in which order the steps run, is reviewed, not silently dropped by the frozen copy). The overlay's copy may
#       add commands of its own; it may not drop, reorder or move the stock ones.
#   `script:` may be a list (of strings and `command:` mappings), or, the two shorter forms, one string or one mapping: all three are
#   read the same way (items_of).
#
# Usage (python3 -I; PyYAML, which the live image has because Calamares' own Python modules need it):
#   ci-shellprocess.py audit  ROOT OVERLAY    the steps settings.conf runs, configs from OVERLAY/modules first, else ROOT/etc/calamares/modules;
#                                             prints one problem per line, exit 1 when there is one, 3 without PyYAML
#   ci-shellprocess.py capture FILE           the config as one line of JSON in the shape the tests' fake installer tree is built from
#                                             (capture-upstream-facts.sh uses it)
# As a module (the tests): audit_doc, compare_docs, heavy_classes, effective_timeout, NET_FLOOR, DISK_FLOOR, HEAVY.
import json
import os
import re
import shlex
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - reported to the caller, which decides the policy
    sys.stderr.write("ci-shellprocess: PyYAML (python-yaml) is not installed\n")
    sys.exit(3)

# --- shared: iso/scripts/verify-iso.sh embeds this text, up to the closing marker, character for character (installer-config.py compares them) ---
NET_FLOOR = 600
DISK_FLOOR = 300
FLOORS = {"net": NET_FLOOR, "disk": DISK_FLOOR}

# A command word starts where the previous character cannot continue a name: not in the middle of `libgit2`, `github-cli`, `pacman.conf`,
# `/etc/pacman.d`. A path in front (`/usr/bin/pacman`) is fine, hence '/' is not in the first class.
_B = r"(?<![\w.-])"
_E = r"(?![\w.-])"
HEAVY = [
    # ("net" | "disk", name, regex). Read-only pacman queries (-Q, -T, -V, -h) are not heavy: they read the local database.
    ("net", "pacman", _B + r"pacman" + r"(?![\w.-])(?!\s+-[QTVh])"),
    ("net", "pacman-key", _B + r"pacman-key" + _E),
    ("net", "pacstrap", _B + r"pacstrap" + _E),
    ("net", "rate-mirrors", _B + r"(?:cachyos-)?rate-mirrors" + _E),
    ("net", "curl", _B + r"curl" + _E),
    ("net", "wget", _B + r"wget" + _E),
    ("net", "git", _B + r"git" + _E),
    ("net", "package manager", _B + r"(?:apt|apt-get|flatpak|snap|yay|paru|pamac|makepkg|pip|pip3|pipx|npm|pnpm|yarn|cargo|chwd)" + _E),
    ("net", "ollama/docker", _B + r"(?:ollama|docker)\s+(?:pull|build|compose|run|push|load)" + _E),
    ("disk", "mkinitcpio", _B + r"mkinitcpio" + _E),
    # `/usr/lib/dracut/` is a directory, not the tool: no '/' after the name.
    ("disk", "dracut/update-initramfs", _B + r"(?:dracut|update-initramfs)" + _E + r"(?!/)"),
    ("disk", "plymouth-set-default-theme", _B + r"plymouth-set-default-theme" + _E),
    ("disk", "locale-gen", _B + r"locale-gen" + _E),
    ("disk", "limine-update/sdboot-manage", _B + r"(?:limine-update|sdboot-manage)" + _E),
    ("disk", "grub", _B + r"(?:grub-install|grub-mkconfig|update-grub)" + _E),
    ("disk", "btrfs/snapper", _B + r"(?:btrfs|snapper)" + _E),
    ("disk", "rsync/squashfs", _B + r"(?:rsync|unsquashfs|mksquashfs)" + _E),
    ("disk", "mkfs/fsck/dd", _B + r"(?:mkfs(?:\.\w+)?|fsck(?:\.\w+)?|dd|parted|sgdisk)" + _E),
    ("disk", "cp -a/-r", _B + r"cp\s+(?:-[A-Za-z]*[aRr][A-Za-z]*|--recursive|--archive)" + _E),
]

_WRAPPERS = {"bash", "sh", "dash", "zsh", "sudo", "env", "exec", "nice", "ionice", "time", "timeout"}


def strip_comments(src):
    """A shell script without its full-line comments and the trailing `# ...` of a line (a `#` inside a word, as in `$#`, stays)."""
    out = []
    for line in src.splitlines():
        if line.lstrip().startswith("#"):
            continue
        out.append(re.sub(r"(?:^|\s)#.*$", "", line))
    return "\n".join(out)


def command_word_script(command, script_dirs):
    """The text of the script a command runs, or "". The command word is the first token that is not a wrapper (bash, sudo, ...) or an
    option or an assignment; it names a script when a file of that base name is in one of the script directories."""
    try:
        tokens = shlex.split(command.lstrip("-").strip())
    except ValueError:
        tokens = command.lstrip("-").split()
    for tok in tokens:
        if tok in _WRAPPERS or tok.startswith("-") or "=" in tok.split("/")[0]:
            continue
        base = os.path.basename(tok)
        for d in script_dirs:
            p = os.path.join(d, base)
            if base and os.path.isfile(p):
                try:
                    with open(p, encoding="utf-8", errors="replace") as fh:
                        return strip_comments(fh.read())
                except OSError:
                    return ""
        return ""
    return ""


def heavy_classes(command, script_text=""):
    """{"net": [tool names], "disk": [...]} the command line and the script it runs use; empty lists when nothing heavy."""
    text = command.lstrip("-").strip() + "\n" + (script_text or "")
    found = {"net": [], "disk": []}
    for cls, name, rx in HEAVY:
        if re.search(rx, text) and name not in found[cls]:
            found[cls].append(name)
    return found


def _int(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def effective_timeout(item_timeout, file_timeout):
    """What Calamares applies (CommandList::run): the command's own value when it has one (>= 0), else the file's, else 30 s. Returns
    (seconds, explicit): explicit False means the silent default."""
    it, ft = _int(item_timeout), _int(file_timeout)
    if it is not None and it >= 0:
        return it, True
    if ft is not None and ft >= 0:
        return ft, True
    return 30, False


def items_of(doc):
    """[(command, own timeout or None)] of a shellprocess config document, in order. A plain string is a command; a mapping holds
    `command:` and optionally `timeout:` and `verbose:`. `script:` is a list of those, or one string, or one mapping (iterating a
    string would read it one character at a time, a mapping one key at a time)."""
    out = []
    script = (doc or {}).get("script")
    if isinstance(script, (str, dict)) and script:
        script = [script]
    elif not isinstance(script, list):
        script = []
    for raw in script:
        if isinstance(raw, str):
            out.append((raw.strip(), None))
        elif isinstance(raw, dict) and raw.get("command") is not None:
            out.append((str(raw["command"]).strip(), raw.get("timeout")))
    return out


def audit_doc(name, doc, script_dirs=()):
    """Problems (list of strings) of one shellprocess config: rules R1 and R2."""
    problems = []
    if not isinstance(doc, dict):
        return ["%s: not a mapping (empty or unreadable), so its time limits cannot be judged" % name]
    ftimeout = doc.get("timeout")
    its = items_of(doc)
    if not its:
        return problems
    light_default = []
    for n, (cmd, own) in enumerate(its, 1):
        secs, explicit = effective_timeout(own, ftimeout)
        short = cmd if len(cmd) <= 70 else cmd[:67] + "..."
        heavy = heavy_classes(cmd, command_word_script(cmd, script_dirs))
        if not explicit:
            if heavy["net"] or heavy["disk"]:
                problems.append("%s: command %d `%s` runs %s and has no timeout of its own while the file sets none, so Calamares kills it after 30 s"
                                % (name, n, short, ", ".join(heavy["net"] + heavy["disk"])))
            else:
                light_default.append(n)
            continue
        for cls in ("net", "disk"):
            if heavy[cls] and secs < FLOORS[cls]:
                problems.append("%s: command %d `%s` runs %s (%s) but may only take %d s (needs at least %d s; 0 means no limit and does not count)"
                                % (name, n, short, ", ".join(heavy[cls]), "network and packages" if cls == "net" else "disk", secs, FLOORS[cls]))
    if light_default:
        problems.append("%s: command%s %s %s no timeout and the file sets none, so Calamares applies its silent default of 30 s (set `timeout:` at the top of the file)"
                        % (name, "s" if len(light_default) > 1 else "", ", ".join(str(n) for n in light_default), "have" if len(light_default) > 1 else "has"))
    return problems


def _norm_cmd(c):
    return " ".join(str(c).split())


def compare_docs(name, stock, ours):
    """Problems of rule R3: what the stock config has and the overlay's copy lacks or changes (a command, the order of the commands,
    dontChroot, a top-level key). The overlay's copy may run more commands than the stock one, never fewer or in another order."""
    problems = []
    if not isinstance(stock, dict) or not stock:
        return problems
    if not isinstance(ours, dict):
        return ["%s: the overlay's copy is not a mapping" % name]
    for k in sorted(set(stock) - set(ours)):
        problems.append("%s: the installer's config has the key '%s' that the overlay's copy lacks" % (name, k))
    # dontChroot decides where every command runs: false (the default) inside the target, true on the live system. (A key the overlay's copy
    # lacks is reported above, once.)
    where = {False: "inside the target (chroot)", True: "on the live system (dontChroot)"}
    s_dc, o_dc = bool(stock.get("dontChroot", False)), bool(ours.get("dontChroot", False))
    if s_dc != o_dc and ("dontChroot" in ours or "dontChroot" not in stock):
        problems.append("%s: the installer's config runs its commands %s, the overlay's copy %s" % (name, where[s_dc], where[o_dc]))
    mine = [_norm_cmd(c) for c, _ in items_of(ours)]
    pos = 0
    for c in (_norm_cmd(c) for c, _ in items_of(stock)):
        if c not in mine:
            problems.append("%s: the installer's config runs `%s`, which the overlay's copy does not" % (name, c))
        elif c in mine[pos:]:
            pos = mine.index(c, pos) + 1
        else:
            problems.append("%s: the installer's config runs `%s` at a place in its order of commands where the overlay's copy does not (reordered, or run fewer times)" % (name, c))
    return problems


# --- end shared ---


def capture(doc):
    """The config in the shape the fake installer tree of the tests is built from: JSON (valid YAML), values of keys that are not
    time limits or commands reduced to "x"."""
    doc = doc or {}
    out = {}
    for k in sorted(doc):
        if k == "dontChroot":
            out[k] = bool(doc[k])
        elif k == "timeout" and _int(doc[k]) is not None:
            out[k] = doc[k]
        elif k == "script":
            out[k] = [{"command": c} if t is None else {"command": c, "timeout": t} for c, t in items_of(doc)]
        else:
            out[k] = "x"
    return out


def _load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def sequence_steps(settings):
    """The shellprocess steps of settings.conf's exec sequence as (step name, config file). A bare `shellprocess` runs shellprocess.conf."""
    inst = {}
    for i in settings.get("instances") or []:
        if isinstance(i, dict) and i.get("module") == "shellprocess":
            inst[str(i.get("id"))] = i.get("config")
    steps = []
    for blk in settings.get("sequence") or []:
        if not isinstance(blk, dict):
            continue
        for item in blk.get("exec") or []:
            item = str(item)
            if item == "shellprocess":
                steps.append((item, "shellprocess.conf"))
            elif item.startswith("shellprocess@"):
                steps.append((item, inst.get(item.split("@", 1)[1])))
    return steps


def audit(root, overlay):
    """Rules R1 to R3 for every shellprocess step the overlay's settings.conf runs. Returns a list of problems. ROOT is the prefix of the
    installer tree: "/" or "" (an empty prefix, which is what ci-guards.sh passes for the live system) is the running system itself."""
    problems = []
    root = root or "/"
    try:
        settings = _load(os.path.join(overlay, "settings.conf")) or {}
    except (OSError, yaml.YAMLError) as exc:
        return ["cannot read the overlay's settings.conf: %s" % str(exc).splitlines()[0]]
    script_dirs = [os.path.join(overlay, "scripts"), os.path.join(root, "etc", "calamares", "scripts")]
    seen = set()
    for step, cfg in sequence_steps(settings):
        if not cfg:
            problems.append("%s: no instance with a config file in the overlay's settings.conf" % step)
            continue
        if cfg in seen:
            continue
        seen.add(cfg)
        ours, stock = os.path.join(overlay, "modules", cfg), os.path.join(root, "etc", "calamares", "modules", cfg)
        path = ours if os.path.isfile(ours) else stock
        if not os.path.isfile(path):
            problems.append("%s: %s is in neither the overlay nor the installer" % (step, cfg))
            continue
        try:
            doc = _load(path)
        except yaml.YAMLError as exc:
            problems.append("%s: %s does not parse: %s" % (step, cfg, str(exc).splitlines()[0]))
            continue
        problems += audit_doc(cfg, doc, script_dirs)
        if path == ours and os.path.isfile(stock):
            try:
                problems += compare_docs(cfg, _load(stock), doc)
            except yaml.YAMLError:
                problems.append("%s: the installer's copy does not parse, so the overlay's copy cannot be compared with it" % cfg)
    return problems


def main(argv):
    if len(argv) >= 4 and argv[1] == "audit":
        problems = audit(argv[2], argv[3])
        for p in problems:
            print(p)
        return 1 if problems else 0
    if len(argv) == 3 and argv[1] == "capture":
        print(json.dumps(capture(_load(argv[2])), sort_keys=True, separators=(", ", ": ")))
        return 0
    sys.stderr.write("usage: ci-shellprocess.py audit ROOT OVERLAY | capture FILE\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
