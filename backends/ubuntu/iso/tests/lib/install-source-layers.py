#!/usr/bin/env python3
"""The squashfs layers the installer installs, from a casper/install-sources.yaml. Used by installed-boot-disk.sh (--iso).

  install-source-layers.py INSTALL_SOURCES_YAML [ID]

Takes the entry marked "default: true" (or the one with id ID) and prints the layer stack curtin builds from its path, bottom layer
first, one file name per line: a path of a.b.squashfs is the stack a.squashfs + a.b.squashfs (so minimal.standard.squashfs installs
minimal.squashfs and minimal.standard.squashfs; minimal.squashfs alone installs just itself). Only top-level keys of an entry are read:
the "variations" paths below it are other choices of the same source. Exits 1 with a message on stderr when there is no such entry.

The file is read as text, not parsed as YAML: it is machine-written, flat, and python3-yaml is not in a stock container.

(c) Companion Intelligence - Lifescope Inc
"""
import re
import sys


def layers(text, wanted_id=None):
    # split on the "- " that opens each top-level entry; the first key of an entry is then not indented, the others are (2 spaces)
    entries = re.split(r'(?m)^- ', text)[1:]
    if wanted_id:
        pick = [e for e in entries if re.search(r'(?m)^(?:  )?id: %s\s*$' % re.escape(wanted_id), e)]
    else:
        pick = [e for e in entries if re.search(r'(?m)^(?:  )?default: true\s*$', e)]
    if not pick:
        raise ValueError('no %s entry in install-sources.yaml' % ('id: ' + wanted_id if wanted_id else 'default: true'))
    m = re.search(r'(?m)^(?:  )?path: (\S+)\s*$', pick[0])
    if not m or not m.group(1).endswith('.squashfs'):
        raise ValueError('the entry has no path ending in .squashfs')
    parts = m.group(1)[:-len('.squashfs')].split('.')
    return ['.'.join(parts[:i]) + '.squashfs' for i in range(1, len(parts) + 1)]


def main(argv):
    if len(argv) not in (2, 3):
        sys.stderr.write(__doc__)
        return 2
    try:
        with open(argv[1]) as fh:
            out = layers(fh.read(), argv[2] if len(argv) == 3 else None)
    except (OSError, ValueError) as ex:
        sys.stderr.write('%s\n' % ex)
        return 1
    print('\n'.join(out))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
