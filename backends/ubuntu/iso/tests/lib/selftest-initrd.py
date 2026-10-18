#!/usr/bin/env python3
"""Part of lib/selftest.sh: builds synthetic initramfs images (an early microcode archive plus a compressed main archive, with and
without casper) and runs initrd-audit.py on them. Prints PASS/FAIL lines.

  selftest-initrd.py TMPDIR LIBDIR

(c) Companion Intelligence - Lifescope Inc
"""
import gzip, os, subprocess, sys
tmp, lib = sys.argv[1], sys.argv[2]

def newc(entries):
    out = b''
    for name, mode, data in entries + [('TRAILER!!!', 0, b'')]:
        nm = name.encode() + b'\0'
        hdr = b'070701' + b''.join(b'%08X' % v for v in (0, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nm), 0))
        out += hdr + nm + b'\0' * ((-(110 + len(nm))) & 3) + data + b'\0' * ((-len(data)) & 3)
    return out

# The shape of an initrd that initramfs-tools 0.151 writes on Ubuntu 26.04.1: AMD microcode, Intel microcode (padded to 512, with a
# pad file), the firmware files (an uncompressed cpio of its own), then the compressed main archive.
early = newc([('kernel', 0o40755, b''), ('kernel/x86/microcode/AuthenticAMD.bin', 0o100644, b'\x02' * 300)])
early += b'\0' * ((-len(early)) % 512)
intel = newc([('kernel', 0o40755, b''), ('kernel/x86/microcode/GenuineIntel.bin', 0o100644, b'\x01' * 1000),
              ('kernel/x86/microcode/.enuineIntel.align.0123456789abc', 0o100644, b'')])
early += intel + b'\0' * ((-len(intel)) % 512)
firmware = newc([('usr', 0o40755, b''), ('usr/lib', 0o40755, b''), ('usr/lib/firmware', 0o40755, b''),
                 ('usr/lib/firmware/x.bin.zst', 0o100644, b'\x28\xb5\x2f\xfd' + b'\x00' * 200)])   # (a .zst file inside: not a compression frame start)
early += firmware
base = [('conf', 0o40755, b''), ('conf/conf.d', 0o40755, b''), ('scripts', 0o40755, b''), ('scripts/local', 0o100755, b'#!/bin/sh\n'),
        ('conf/conf.d/resume', 0o100644, b'RESUME=none\n')]
live = base + [('conf/conf.d/default-boot-to-casper.conf', 0o100644, b'if [ -z "$BOOT" ]; then\nexport BOOT=casper\nfi\n'),
               ('scripts/casper', 0o100755, b'#!/bin/sh\n'), ('scripts/casper-bottom/05mountpoints', 0o100755, b'#!/bin/sh\n')]
comps = [('gzip', lambda d: gzip.compress(d))]
try:
    subprocess.run(['zstd', '-q', '-c'], input=b'x', stdout=subprocess.PIPE, check=True)
    comps.append(('zstd', lambda d: subprocess.run(['zstd', '-q', '-c'], input=d, stdout=subprocess.PIPE, check=True).stdout))
except Exception:
    pass
for cname, comp in comps:
    for label, ents in (('clean', base), ('casper', live)):
        path = os.path.join(tmp, 'initrd-%s-%s' % (cname, label))
        with open(path, 'wb') as fh:
            fh.write(early + comp(newc(ents)))
        res = subprocess.run([sys.executable, '-I', os.path.join(lib, 'initrd-audit.py'), path], stdout=subprocess.PIPE, text=True).stdout
        total = [l.split()[1] for l in res.splitlines() if l.startswith('total ')]
        confs = [l for l in res.splitlines() if l.startswith('conf ')]
        ok = (total == ['0'] and not confs) if label == 'clean' else (total == ['3'] and len(confs) == 1 and 'BOOT=casper' in confs[0])
        print('%s  initrd audit, %s image, %s: total=%s conf lines=%d' % ('PASS' if ok else 'FAIL', cname, label, total, len(confs)))
