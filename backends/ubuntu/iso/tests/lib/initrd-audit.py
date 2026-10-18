#!/usr/bin/env python3
"""Look for casper in an initramfs image without unpacking it to disk. Used by installed-boot-disk.sh.

  initrd-audit.py INITRD

Parses the image the way the kernel does: any number of uncompressed "early" cpio archives, then one compressed cpio archive (zstd,
xz, gzip, lz4 or bzip2; the decompressor is the system's own binary). Ubuntu 26.04.1's initramfs-tools 0.151 writes three early
archives (AMD microcode, Intel microcode, and the firmware files, 52 MB uncompressed) and a zstd main archive; the stock casper/initrd
has exactly that shape. Streams the cpio and prints, one per line:

  entries N            number of cpio entries seen
  path NAME            an entry whose path mentions casper (at most 12 of them)
  more N               the number of further such entries
  conf NAME: LINE      a conf/conf.d file that mentions casper (BOOT=casper is what makes a normal boot run the live-session
                       scripts), with its first matching line
  total N              the number of entries that mention casper (0 = clean)
  error TEXT           the image could not be read (exit status 3)

This is the same check as running unmkinitramfs and grepping the tree, in seconds: unmkinitramfs finds the archive borders with
dd bs=1 loops, which takes minutes under an emulated (Rosetta/QEMU user mode) container.

(c) Companion Intelligence - Lifescope Inc
"""
import subprocess
import sys

MAGICS = [
    (b'\x28\xb5\x2f\xfd', ['zstd', '-dc']),
    (b'\xfd7zXZ\x00', ['xz', '-dc']),
    (b'\x1f\x8b', ['gzip', '-dc']),
    (b'\x04\x22\x4d\x18', ['lz4', '-dc']),
    (b'BZh', ['bzip2', '-dc']),
]


def cpio_entries(read, limit_early=False):
    """Yield (name, mode, data-or-None) for the entries of a newc cpio stream; stops after TRAILER!!!. read(n) returns exactly n
    bytes (fewer at the end of the stream)."""
    while True:
        head = read(110)
        if len(head) < 110 or head[:6] != b'070701':
            return
        mode = int(head[14:22], 16)
        size = int(head[54:62], 16)
        namesz = int(head[94:102], 16)
        name = read(namesz)[:-1].decode('utf-8', 'replace')
        pad = (-(110 + namesz)) & 3
        if pad:
            read(pad)
        if name == 'TRAILER!!!':
            return
        want = name.startswith('conf/') and (mode & 0o170000) == 0o100000 and size < 1 << 20
        if want:
            data = read(size)
        else:
            data = None
            left = size
            while left > 0:
                got = read(min(left, 1 << 20))
                if not got:
                    return
                left -= len(got)
        pad = (-size) & 3
        if pad:
            read(pad)
        yield name, mode, data


def main(path):
    with open(path, 'rb') as fh:
        raw = fh.read()
    off = 0
    entries = 0
    hits = []
    confs = []

    def scan(it):
        nonlocal entries
        for name, _mode, data in it:
            entries += 1
            if 'casper' in name.lower():
                hits.append(name)
            if data is not None and name.startswith('conf/conf.d/'):
                for line in data.decode('utf-8', 'replace').splitlines():
                    if 'casper' in line.lower():
                        confs.append((name, line.strip()))
                        break

    # early archives: uncompressed newc cpio, each ended by TRAILER!!! and padded with NULs
    while raw[off:off + 6] == b'070701':
        pos = [off]

        def rd(n):
            b = raw[pos[0]:pos[0] + n]
            pos[0] += n
            return b
        scan(cpio_entries(rd))
        off = pos[0]
        while off < len(raw) and raw[off:off + 1] == b'\x00':
            off += 1
    rest = raw[off:]
    if not rest:
        print('error no main archive after the early archives')
        return 3
    if rest[:6] == b'070701':
        decoded = rest
    else:
        cmd = next((c for m, c in MAGICS if rest[:len(m)] == m), None)
        if cmd is None:
            print('error unknown compression, first bytes %s' % rest[:6].hex())
            return 3
        try:
            res = subprocess.run(cmd, input=rest, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        except OSError as ex:
            print('error cannot run %s: %s' % (cmd[0], ex))
            return 3
        if not res.stdout:
            print('error %s produced nothing: %s' % (cmd[0], res.stderr.decode('utf-8', 'replace').strip()[:200]))
            return 3
        decoded = res.stdout
    dpos = [0]

    def drd(n):
        b = decoded[dpos[0]:dpos[0] + n]
        dpos[0] += n
        return b
    scan(cpio_entries(drd))
    print('entries %d' % entries)
    for name in hits[:12]:
        print('path %s' % name)
    if len(hits) > 12:
        print('more %d' % (len(hits) - 12))
    for name, line in confs:
        print('conf %s: %s' % (name, line))
    print('total %d' % len(hits))
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
