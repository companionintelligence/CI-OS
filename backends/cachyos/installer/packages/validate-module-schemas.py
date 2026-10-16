# Validate the overlay's module configs against the JSON schemas the installer itself ships, and compare with the installer's own configs.
#
# Maintainer tool for a pin bump (needs python-jsonschema and PyYAML; not part of the offline tests, which must not need jsonschema):
#
#   python3 -I backends/cachyos/installer/packages/validate-module-schemas.py <installer-root>
#
# <installer-root> holds the installer at its installed paths (an unpacked cachyos-calamares-next, or an unpacked ISO root). For
# each module that ships usr/lib/calamares/modules/<module>/<module>.schema.yaml and has a config in the overlay it validates
# the overlay's config and the installer's own config of the same name, and prints both. A config that is invalid in BOTH is a schema
# the installer itself does not honour (pinned 3.4.2-13: grubcfg wants `defaults.GRUB_DEFAULT`, which the installer's own grubcfg.conf
# does not set either), not an overlay error. Exit 1 only when the overlay's config is invalid and the installer's own is valid.
import os
import sys

sys.dont_write_bytecode = True

try:
    import jsonschema
    import yaml
except ImportError as exc:
    print("validate-module-schemas: %s (pacman -S python-jsonschema python-yaml)" % exc)
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
OVERLAY_MODULES = os.path.join(os.path.dirname(HERE), "modules")


def load(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def verdict(doc, schema):
    try:
        jsonschema.validate(doc, schema)
        return None
    except jsonschema.ValidationError as exc:
        return "%s at %s" % (exc.message[:140], list(exc.absolute_path))


def main(root):
    modules = os.path.join(root, "usr", "lib", "calamares", "modules")
    etc = os.path.join(root, "etc", "calamares", "modules")
    if not os.path.isdir(modules):
        print("validate-module-schemas: %s has no usr/lib/calamares/modules" % root)
        return 2
    rc = 0
    for conf in sorted(f for f in os.listdir(OVERLAY_MODULES) if f.endswith(".conf")):
        # The schema belongs to the module: packages_online.conf -> packages, services-systemd.conf -> services-systemd.
        candidates = [conf[:-5], conf[:-5].split("_")[0], conf[:-5].split("-")[0]]
        mod = next((m for m in candidates if os.path.exists(os.path.join(modules, m, m + ".schema.yaml"))), None)
        if mod is None:
            continue
        schema = load(os.path.join(modules, mod, mod + ".schema.yaml"))
        ours = verdict(load(os.path.join(OVERLAY_MODULES, conf)), schema)
        up_path = os.path.join(etc, conf)
        theirs = verdict(load(up_path), schema) if os.path.exists(up_path) else "(no such file in the installer)"
        print("%-34s overlay: %-8s installer's own: %s" % (conf, "valid" if ours is None else "INVALID", "valid" if theirs is None else "INVALID"))
        for label, v in (("overlay", ours), ("installer", theirs)):
            if v:
                print("    %s: %s" % (label, v))
        if ours and not theirs:
            rc = 1
    return rc


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: validate-module-schemas.py <installer-root>")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
