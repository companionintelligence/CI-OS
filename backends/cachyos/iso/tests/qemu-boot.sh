#!/usr/bin/env bash
#=============================================================================
# Boot a Companion OS (CachyOS-based) live ISO in QEMU and wait for an expected state.
#
#   backends/cachyos/iso/tests/qemu-boot.sh [options] ISO
#
# Exits 0 only when every expectation was seen (default: a login prompt on the serial console; --expect-plasma: the Plasma
# session is running, asked of the guest agent), 1 on timeout or when the guest drops to an emergency shell, 2 when it cannot
# run here, 3 when QEMU quit before the expectations were met. Serial logs are the primary evidence: the kernel command line
# always carries console=ttyS0, so systemd's boot messages land in --serial-log; screenshots (QMP screendump) are taken at
# intervals and once more at the end.
#
# Modes (--mode):
#   direct  (default) QEMU loads the kernel and initramfs it extracts from the ISO (-kernel/-initrd) and uses the exact
#           kernel command line of the ISO's own boot/grub/grub.cfg, plus console=ttyS0. No firmware, no bootloader: this
#           is the fastest and most reproducible way to see the live system, and what the lead's loop should use.
#   bios    SeaBIOS + the ISO's syslinux menu; the script presses TAB and appends the extra arguments.
#   uefi    OVMF (non-Secure-Boot code: the ISO is not signed) + the ISO's GRUB; the script opens GRUB's command line ('c')
#           and types the menu entry's own linux/initrd lines plus the extra arguments, one byte per echoed byte (GRUB's
#           serial input reorders bursts). The kernel started about 50 s after power-on in the measured TCG run.
#
# Booting the stock upstream image under software emulation (TCG, no KVM: every Apple-silicon Mac) needs more time than
# its systemd settings allow. cachyos-settings sets DefaultTimeoutStartSec=15s for the system and the user manager,
# systemd-nsresourced needs about 25 s of vCPU time to verify and load its BPF-LSM programs under TCG, and the drm-awaiter's
# drm-module-load.target gives up 30 s after boot. A TCG guest misses all three: systemd-udevd never starts, the display
# driver never loads, the boot drops to emergency mode, and the Plasma user units are killed and restarted forever. None of
# this is expected on KVM or real hardware (the same BPF programs verify in milliseconds there; not tested here).
# --vm-fixes injects a generator (vm_fixes_generator below, measured evidence in its comment) that gives a VM the time it
# needs, without rebuilding the ISO; the same file belongs in the image's overlay, and once it is there the flag is redundant.
#
# Needs: qemu-system-x86_64, python3 (stdlib only), and for direct mode one of bsdtar, 7z or xorriso to read the ISO.
# Runs on a stock macOS (bash 3.2) and on Linux. Everything it writes goes to --work; the only other thing it creates is
# a short-named temp directory for the unix sockets (a macOS limit: 104 bytes), removed on exit. It never writes to a disk.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

SELF="$(basename "$0")"

usage() {
  cat <<'EOF'
usage: qemu-boot.sh [options] ISO

Boot ISO in QEMU; exit 0 only when the expected state is seen.

  --mode direct|bios|uefi   how to start it (default: direct, see the header of this file)
  --expect REGEX            Python regex that must appear on the serial console (repeatable; all must be seen).
                            Default when no expectation is given: 'login:\s*$' (the serial getty), or --expect-plasma with --no-menu-edit.
  --expect-plasma           the Plasma session is running: asks the guest agent whether plasmashell and kwin_wayland run
  --expect-screen           the display shows a rendered image (at least 64 distinct colours, over 20% non-black pixels in a
                            QMP screendump), i.e. the desktop is drawn, not just running; checked every 15 s
  --guest-check CMD         a shell command run in the guest through the guest agent (as root); expected to exit 0
                            (repeatable), e.g. --guest-check 'systemctl is-active plasmalogin'
  --timeout SECS            give up after SECS (default 1800 under TCG, 300 under KVM/HVF)
  --settle SECS             after the expectations are met keep the guest running SECS more (screenshots go on), so the last
                            screenshot shows the finished desktop (panel, wallpaper), not the first frame; default 0
  --work DIR                work directory, created if needed (default: a new temp dir; kept)
  --shots DIR               screenshots (default: WORK/shots); --shot-interval SECS (default 30, 0 = only the last)
  --serial-log FILE         raw serial console (default: WORK/serial.log); a cleaned, timestamped copy goes to WORK/serial.txt
  --timeline FILE           boot milestones with seconds since QEMU start (default: WORK/timeline.txt)
  --append 'ARGS'           extra kernel arguments (direct: appended; bios/uefi: typed into the bootloader editor)
  --kernel cachyos|lts      direct mode: which kernel of the ISO to boot (default cachyos = the UEFI menu default;
                            the BIOS menu default is lts)
  --cmdline 'ARGS'          direct mode: use these kernel arguments instead of the ones in the ISO's grub.cfg
  --kernel-path P --initrd-path P   direct mode: paths inside the ISO (default arch/boot/x86_64/{vmlinuz,initramfs}-linux-KERNEL[.img])
  --vm-fixes                inject the slow-boot generator (see below) into the live root through an appended initramfs
                            segment; direct mode only. Needed for the stock upstream ISO under TCG; harmless otherwise.
  --inject DIR              copy the tree DIR (laid out like the ISO's airootfs: DIR/etc/..., DIR/usr/...) into the live
                            root before it starts; direct mode only; repeatable. Use it to try an overlay without a rebuild,
                            e.g. --inject backends/cachyos/iso/overlay/files/airootfs. Files are root-owned, modes kept.
  --debug-shell             second serial port with a root shell (systemd.debug_shell=/dev/ttyS1); the unix socket path is
                            printed (talk to it with `nc -U PATH`; the log is WORK/serial1.log)
  --vga std|virtio|qxl|vmware|cirrus|none   display device (default std = the bochs driver, which boots fine)
  --cpu MODEL               default max (TCG), host (KVM/HVF)
  --smp N                   default 4
  --mem MB                  default 6144
  --machine q35|pc          default q35
  --accel auto|tcg|kvm|hvf  default auto: kvm if /dev/kvm is usable, hvf on an Intel Mac, else tcg,thread=multi
  --cd-bus ahci|ide|scsi    how the ISO is attached (default ahci)
  --no-net                  no NIC (default: a user-mode virtio NIC; the live system wants the network for NTP)
  --vnc :N                  also serve the screen on VNC display N (127.0.0.1)
  --qemu-arg ARG            extra QEMU argument (repeatable), e.g. --qemu-arg -d --qemu-arg guest_errors
  --ovmf-code F --ovmf-vars F   uefi mode firmware (default: first match from the repo's stick/tests/secureboot/out, Homebrew
                            QEMU, /usr/share/OVMF, ...); the vars file is copied into the work dir
  --no-menu-edit            bios/uefi: boot the bootloader's default entry untouched (no console=ttyS0, so no kernel log on the
                            serial port; the guest agent and the screenshots are then the evidence). Nothing is typed, so
                            nothing can be mistyped: the way to test the final image once its overlay carries the VM fix.
  --no-fail-fast            keep waiting after emergency mode / a kernel panic instead of failing at once
  --selftest                run the unit tests of the helper code (no QEMU) and exit; also checks that the overlay's copy of the
                            generator, if the overlay has one, is byte-identical to the one --vm-fixes injects
  --print-vm-fixes-generator   print the generator (to create the overlay's copy: ... > overlay/files/airootfs/usr/lib/systemd/
                            system-generators/companion-vm-timeouts)
  -h, --help

The slow-boot generator (--vm-fixes) is /usr/lib/systemd/system-generators/companion-vm-timeouts. When systemd-detect-virt
reports a VM it writes drop-ins that give systemd-nsresourced.service 5 minutes to start (default 15 s), make
drm-module-load.target wait 10 minutes (default 30 s) and raise the user manager's DefaultTimeoutStartSec to 3 minutes
(default 15 s, via /run/systemd/user.conf.d). Real hardware is left alone. The same file belongs in the image's overlay.

Examples:
  qemu-boot.sh --expect-plasma --vm-fixes --shots /tmp/shots companion-os-plasma-2026.10.15-x86_64.iso
  qemu-boot.sh --mode bios --append 'systemd.unit=multi-user.target' --expect 'login:\s*$' the.iso
EOF
}

die() { echo "$SELF: $*" >&2; exit 2; }
qesc() { printf '%s' "${1//,/,,}"; }   # a comma inside a QEMU option value is written as two

# ---------------------------------------------------------------------------------------------------------------------
# The generator that --vm-fixes injects. Keep it identical to the file in the image overlay (see the header).
# ---------------------------------------------------------------------------------------------------------------------
vm_fixes_generator() {
  cat <<'GEN'
#!/bin/sh
# Slow-boot relief for virtual machines (Companion OS live ISO). © Companion Intelligence — Lifescope Inc
#
# cachyos-settings sets DefaultTimeoutStartSec=15s for the system and the user manager, and cachyos-drm-awaiter's
# drm-module-load.target gives up 30 s after boot. Measured under QEMU TCG (no KVM) on a loaded host: systemd-nsresourced
# needs ~25 s of vCPU time to verify and load its BPF-LSM programs and is killed after 15 s, over and over; while it is
# starting, systemd-tmpfiles-setup-dev-early (ordered before systemd-udevd) hangs with a connection queued on the nsresourced
# socket, so systemd-udevd never starts, the display driver never loads and the 30 s DRM target drops the boot into emergency
# mode. The Plasma user units then miss the same 15 s limit. None of this is expected on KVM or on real hardware, so only a VM gets the longer limits.
# $1 is the generator output directory; a generator must never fail the boot.
out="${1:-/run/systemd/generator}"
systemd-detect-virt --quiet --vm 2>/dev/null || exit 0
mkdir -p "$out/systemd-nsresourced.service.d" "$out/drm-module-load.target.d" /run/systemd/user.conf.d 2>/dev/null || exit 0
printf '[Service]\nTimeoutStartSec=5min\n' > "$out/systemd-nsresourced.service.d/10-companion-vm.conf"
printf '[Unit]\nJobTimeoutSec=10min\n' > "$out/drm-module-load.target.d/10-companion-vm.conf"
printf '[Manager]\nDefaultTimeoutStartSec=3min\n' > /run/systemd/user.conf.d/10-companion-vm.conf
exit 0
GEN
}

# ---------------------------------------------------------------------------------------------------------------------
# The Python helper: ISO extraction logic, initramfs injection, the QEMU supervisor (serial log, QMP screenshots, guest agent,
# bootloader keystrokes, expectations). Stdlib only. `-I` keeps the working directory and the environment out of its imports.
# ---------------------------------------------------------------------------------------------------------------------
pydriver() {
  python3 -I - "$@" <<'PYEOF'
import argparse, json, lzma, os, re, signal, socket, stat, struct, subprocess, sys, threading, time, zlib

# --------------------------------------------------------------------------------------------------- terminal text
ANSI_RE = re.compile(
    rb'\x1b\[[0-9;?<=>]*[ -/]*[@-~]'            # CSI
    rb'|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)'      # OSC (systemd's context marks, ]3008;...)
    rb'|\x1bP[^\x1b]*\x1b\\'                     # DCS
    rb'|\x1b[()][0-9A-Za-z]|\x1b[=>78M]|\x00')


def clean_bytes(raw):
    """Serial bytes to text: escape sequences gone, CR gone (a CR-only line rewrite keeps its last text)."""
    txt = ANSI_RE.sub(b'', raw).decode('utf-8', 'replace')
    return txt.replace('\r\n', '\n').replace('\r', '\n')


# --------------------------------------------------------------------------------------------------- cpio (newc)
def cpio_parse(data, off):
    """Parse one newc archive starting at off. Returns ({name: (mode, bytes)}, offset after the trailer)."""
    out = {}
    while True:
        if data[off:off + 6] not in (b'070701', b'070702'):
            raise ValueError('not a newc archive at offset %d' % off)
        f = [int(data[off + 6 + 8 * i:off + 14 + 8 * i], 16) for i in range(13)]
        mode, filesize, namesize = f[1], f[6], f[11]
        name = data[off + 110:off + 110 + namesize - 1].decode('utf-8', 'replace')
        doff = (off + 110 + namesize + 3) & ~3
        off = (doff + filesize + 3) & ~3
        if name == 'TRAILER!!!':
            return out, off
        out[name] = (mode, data[doff:doff + filesize])


class CpioWriter(object):
    def __init__(self):
        self.parts, self.ino = [], 0

    def add(self, name, mode, data=b''):
        self.ino += 1
        nb = name.encode('utf-8') + b'\0'
        hdr = b'070701' + b''.join(('%08X' % v).encode() for v in
                                   (self.ino, mode, 0, 0, 2 if stat.S_ISDIR(mode) else 1, 0, len(data), 0, 0, 0, 0, len(nb), 0))
        blob = hdr + nb
        blob += b'\0' * (-len(blob) % 4)
        blob += data
        blob += b'\0' * (-len(blob) % 4)
        self.parts.append(blob)

    def finish(self):
        self.add('TRAILER!!!', 0)
        blob = b''.join(self.parts)
        return blob + b'\0' * (-len(blob) % 512)


def initramfs_read(path, want):
    """Last copy of file `want` in a (possibly early-cpio + xz/gzip compressed) initramfs, or None. zstd is not read."""
    with open(path, 'rb') as fh:
        data = fh.read()
    found, off = None, 0
    while off < len(data):
        while off < len(data) and data[off] == 0:
            off += 1
        if off >= len(data):
            break
        head = data[off:off + 6]
        if head in (b'070701', b'070702'):
            ents, off = cpio_parse(data, off)
            if want in ents:
                found = ents[want][1]
        elif head == b'\xfd7zXZ\x00':
            dec = lzma.LZMADecompressor()
            raw = dec.decompress(data[off:])
            off = len(data) - len(dec.unused_data)
            pos = 0
            while pos < len(raw):
                while pos < len(raw) and raw[pos] == 0:
                    pos += 1
                if pos >= len(raw):
                    break
                ents, pos = cpio_parse(raw, pos)
                if want in ents:
                    found = ents[want][1]
        elif head[:2] == b'\x1f\x8b':
            dec = zlib.decompressobj(31)
            raw = dec.decompress(data[off:])
            off = len(data) - len(dec.unused_data)
            pos = 0
            while pos < len(raw):
                while pos < len(raw) and raw[pos] == 0:
                    pos += 1
                if pos >= len(raw):
                    break
                ents, pos = cpio_parse(raw, pos)
                if want in ents:
                    found = ents[want][1]
        else:
            break
    return found


FALLBACK_CONFIG = (b'EARLYHOOKS="udev archiso_pxe_nbd"\n'
                   b'HOOKS="udev memdisk archiso archiso_loop_mnt archiso_pxe_common archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs"\n'
                   b'LATEHOOKS="archiso_pxe_common"\nCLEANUPHOOKS="udev"\nEMERGENCYHOOKS=""\n')

INJECT_HOOK = b'''#!/usr/bin/ash
# Added by qemu-boot.sh (--inject / --vm-fixes): copy a tree into the live root before switch_root.
run_latehook() {
    msg ":: ci-inject: copying /ci_inject_root into /sysroot"
    cp -a /ci_inject_root/. /sysroot/ || err "ci-inject: copy failed"
}
'''


def add_latehook(config_bytes, hook):
    text = config_bytes.decode('utf-8', 'replace')
    if re.search(r'^LATEHOOKS="', text, re.M):
        text = re.sub(r'^LATEHOOKS="([^"]*)"', lambda m: 'LATEHOOKS="%s %s"' % (m.group(1), hook), text, count=1, flags=re.M)
    else:
        text += '\nLATEHOOKS="%s"\n' % hook
    return text.encode()


def walk_tree(root):
    """Yield (relative path, kind, mode, payload) with parents first; kind is d, f or l."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel = os.path.relpath(dirpath, root)
        rel = '' if rel == '.' else rel
        if rel:
            yield rel, 'd', 0o755, b''
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rp = os.path.join(rel, fn) if rel else fn
            if os.path.islink(full):
                yield rp, 'l', 0o777, os.readlink(full).encode()
            else:
                m = os.stat(full).st_mode
                with open(full, 'rb') as fh:
                    yield rp, 'f', 0o755 if m & 0o111 else 0o644, fh.read()


def build_initrd(src, dst, trees, generator=None):
    """dst = src + one appended uncompressed newc archive that adds an `ci_inject` late hook and the tree(s)."""
    cfg = initramfs_read(src, 'config') or FALLBACK_CONFIG
    w = CpioWriter()
    w.add('config', stat.S_IFREG | 0o644, add_latehook(cfg, 'ci_inject'))
    w.add('hooks', stat.S_IFDIR | 0o755)
    w.add('hooks/ci_inject', stat.S_IFREG | 0o755, INJECT_HOOK)
    w.add('ci_inject_root', stat.S_IFDIR | 0o755)
    seen = set()

    def put(rel, kind, mode, payload):
        name = 'ci_inject_root/' + rel
        parts = name.split('/')
        for i in range(2, len(parts)):                     # parents the tree itself did not list (generator path)
            d = '/'.join(parts[:i])
            if d not in seen:
                seen.add(d)
                w.add(d, stat.S_IFDIR | 0o755)
        if name in seen:
            return
        seen.add(name)
        w.add(name, {'d': stat.S_IFDIR, 'f': stat.S_IFREG, 'l': stat.S_IFLNK}[kind] | mode, payload)

    for t in trees:
        for rel, kind, mode, payload in walk_tree(t):
            put(rel, kind, mode, payload)
    if generator is not None:
        put('usr/lib/systemd/system-generators/companion-vm-timeouts', 'f', 0o755, generator)
    with open(src, 'rb') as fh:
        base = fh.read()
    with open(dst, 'wb') as fh:
        fh.write(base)
        fh.write(w.finish())
    return len(seen)


# --------------------------------------------------------------------------------------------------- grub.cfg
def grub_cmdline(grub_cfg, kernel_suffix):
    """(kernel path in the ISO, initrd path, kernel arguments) of the first menu entry that boots vmlinuz-linux-<suffix>."""
    lines = grub_cfg.splitlines()
    pat = re.compile(r'^\s*linux\s+(\S*vmlinuz-linux-%s)(?:\s+(.*))?$' % re.escape(kernel_suffix))
    for i, ln in enumerate(lines):
        m = pat.match(ln)
        if not m:
            continue
        initrd = None
        for nxt in lines[i + 1:i + 4]:
            m2 = re.match(r'^\s*initrd\s+(\S+)', nxt)
            if m2:
                initrd = m2.group(1)
                break
        return m.group(1).lstrip('/'), (initrd or '').lstrip('/') or None, (m.group(2) or '').strip()
    return None


# --------------------------------------------------------------------------------------------------- images
def ppm_info(data):
    m = re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s', data)
    if not m:
        raise ValueError('not a P6 ppm')
    return int(m.group(1)), int(m.group(2)), m.end()


def ppm_to_png(data):
    w, h, off = ppm_info(data)
    pix = data[off:]
    rows = b''.join(b'\x00' + pix[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(rows, 3)) + chunk(b'IEND', b''))


def ppm_stats(data):
    """(width, height, distinct colours in a 1/4 sample, share of non-black samples)."""
    w, h, off = ppm_info(data)
    cols, nonblack, total = set(), 0, 0
    for y in range(0, h, 4):
        row = off + y * w * 3
        for x in range(0, w, 4):
            px = data[row + x * 3:row + x * 3 + 3]
            total += 1
            if px != b'\x00\x00\x00':
                nonblack += 1
            if len(cols) < 5000:
                cols.add(px)
    return w, h, len(cols), (nonblack / float(total) if total else 0.0)


# --------------------------------------------------------------------------------------------------- QMP / QGA
class Qmp(object):
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(60)
        self.s.connect(path)
        self.f = self.s.makefile('rw', encoding='utf-8', newline='\n')
        self.f.readline()
        self.call('qmp_capabilities')

    def call(self, cmd, **args):
        msg = {'execute': cmd}
        if args:
            msg['arguments'] = args
        self.f.write(json.dumps(msg) + '\n')
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise EOFError('qmp closed')
            r = json.loads(line)
            if 'return' in r:
                return r['return']
            if 'error' in r:
                raise RuntimeError(r['error'].get('desc', str(r['error'])))


class Qga(object):
    """qemu-guest-agent over a virtio-serial unix socket. The guest may not be there yet: every call can fail softly."""

    def __init__(self, path):
        self.path, self.s, self.sync_id, self.synced = path, None, 0, False

    def close(self):
        if self.s:
            try:
                self.s.close()
            except OSError:
                pass
        self.s, self.synced = None, False

    def _read_until(self, pred, timeout):
        end, buf = time.time() + timeout, b''
        while time.time() < end:
            self.s.settimeout(max(0.1, end - time.time()))
            try:
                d = self.s.recv(65536)
            except socket.timeout:
                break
            if not d:
                raise EOFError('qga closed')
            buf += d
            r = pred(buf)
            if r is not None:
                return r
        return None

    def _sync(self):
        self.sync_id += 1
        want = self.sync_id
        self.s.sendall(b'\xff{"execute":"guest-sync-delimited","arguments":{"id":%d}}\n' % want)

        def pred(buf):
            for part in buf.split(b'\xff')[1:]:
                try:
                    if json.loads(part.decode('utf-8', 'replace')).get('return') == want:
                        return True
                except ValueError:
                    pass
            return None
        return bool(self._read_until(pred, 2.5))

    def call(self, cmd, args=None, timeout=8):
        try:
            if self.s is None:
                self.s = socket.socket(socket.AF_UNIX)
                self.s.settimeout(2)
                self.s.connect(self.path)
                self.synced = False
            if not self.synced:
                if not self._sync():
                    return None
                self.synced = True
            msg = {'execute': cmd}
            if args:
                msg['arguments'] = args
            self.s.sendall((json.dumps(msg) + '\n').encode())

            def pred(buf):
                for ln in buf.split(b'\n'):
                    try:
                        r = json.loads(ln.decode('utf-8', 'replace'))
                    except ValueError:
                        continue
                    if 'return' in r or 'error' in r:
                        return r
                return None
            return self._read_until(pred, timeout)
        except (OSError, EOFError, ValueError):
            self.close()
            return None

    def shell_ok(self, command):
        """Run `command` through /bin/sh in the guest. True/False for its exit status, None if the agent is not answering."""
        r = self.call('guest-exec', {'path': '/bin/sh', 'arg': ['-c', command], 'capture-output': False})
        if not r or 'return' not in r:
            return None
        pid = r['return']['pid']
        end = time.time() + 20
        while time.time() < end:
            st = self.call('guest-exec-status', {'pid': pid})
            if st and 'return' in st and st['return'].get('exited'):
                return st['return'].get('exitcode') == 0
            time.sleep(0.5)
        return None


# --------------------------------------------------------------------------------------------------- supervisor
MILESTONES = [
    ('menu', r'Automatic boot in|executed automatically in|Press \[Tab\] to edit'),
    ('initramfs', r':: running early hook'),
    ('medium found', r"Mounting '/dev/\S+' to '/run/archiso/bootmnt'"),
    ('root mounted', r':: running cleanup hook'),
    ('systemd started', r'(?m)^Welcome to [^()\n]*!\s*$'),
    ('nsresourced failing', r'(Failed to start|Timed out starting) .*Namespace Resource Manager'),
    ('udev started', r'Started .*Rule-based Manager for Device Events'),
    ('DRM target reached', r'Reached target .*DRM module load target'),
    ('display manager started', r'Started .*(Plasma Login Manager|Display Manager|SDDM)'),
    ('serial login prompt', r'(?m)login:\s*$'),
    ('graphical.target', r'Reached target .*Graphical Interface'),
]
FAILFAST = [
    ('emergency mode', r'You are in emergency mode|Welcome to emergency mode|Give root password for maintenance'),
    ('DRM target timed out', r'Timed out starting .*DRM module load target'),
    ('kernel panic', r'Kernel panic - not syncing'),
    ('root mount failed', r'Failed to mount the real root device|Bailing out, you are on your own'),
]


SCREEN_LABEL = 'the screen shows an image'


class Result(object):
    def __init__(self):
        self.reason, self.ok, self.code = 'not finished', False, 1


def run_supervisor(a, qemu_argv):
    os.makedirs(a.shots, exist_ok=True)
    t0 = time.time()
    el = lambda: time.time() - t0
    ts_path = os.path.join(a.workdir, 'serial.txt')
    tl = open(a.timeline, 'w')
    ts = open(ts_path, 'w')
    qout = open(os.path.join(a.workdir, 'qemu.out'), 'w')
    qerr = open(os.path.join(a.workdir, 'qemu.err'), 'w')
    proc = subprocess.Popen(qemu_argv, stdin=subprocess.DEVNULL, stdout=qout, stderr=qerr, start_new_session=True)
    res = Result()
    stop = {'sig': None}

    def on_sig(sn, fr):
        stop['sig'] = sn
    signal.signal(signal.SIGTERM, on_sig)
    signal.signal(signal.SIGINT, on_sig)

    def tline(name, detail=''):
        s = 'T+%7.1fs  %-24s %s' % (el(), name, detail)
        tl.write(s.rstrip() + '\n')
        tl.flush()
        print('[%s]' % s.rstrip(), flush=True)
    tline('qemu started', 'pid %d' % proc.pid)

    qmp, qga, ser_in = None, (Qga(a.qga) if a.qga else None), None
    shots, seen, failed_reason = [], {}, None
    expect = [(e, re.compile(e, re.M)) for e in a.expect]
    guest = [(c, None) for c in a.guest_check]
    ms = [(n, re.compile(p, re.M)) for n, p in MILESTONES]
    ff = [(n, re.compile(p, re.M)) for n, p in FAILFAST]
    satisfied = {}
    raw_pos, partial, text = 0, '', ''
    menu_state = {'done': False, 'at': None}
    last_shot, last_guest, last_beat, done_at = -1e9, -1e9, 0, None
    screen = None
    deadline = a.timeout

    def screenshot(tag):
        nonlocal screen
        if qmp is None:
            return
        tmp = os.path.join(a.workdir, '.shot.ppm')
        try:
            qmp.call('screendump', filename=tmp, format='ppm')
            with open(tmp, 'rb') as fh:
                data = fh.read()
            os.unlink(tmp)
            png = os.path.join(a.shots, 'shot-%04ds%s.png' % (int(el()), tag))
            with open(png, 'wb') as fh:
                fh.write(ppm_to_png(data))
            with open(os.path.join(a.shots, 'last.png'), 'wb') as fh:
                fh.write(ppm_to_png(data))
            screen = ppm_stats(data)
            shots.append(png)
        except Exception as ex:            # the display may not exist yet; never fatal
            tline('screenshot failed', str(ex)[:80])

    def cd_read():
        """Bytes the guest has read from the ISO so far (QMP query-blockstats): tells a slow bootloader from a stuck one."""
        if qmp is None:
            return '?'
        try:
            for dev in qmp.call('query-blockstats'):
                if dev.get('device') == 'cd' or dev.get('qdev', '').endswith('cd'):
                    return '%.0f MiB' % (dev['stats']['rd_bytes'] / 1048576.0)
        except Exception:
            pass
        return '?'

    def send_serial(b, delay=0.0):
        """Type b on the guest's serial console, one byte at a time and in lock step with the guest's echo: GRUB's serial
        driver reorders bytes that sit in the UART FIFO together ('cosnole', 'linxu'), so the next byte goes out only after
        the previous one was echoed (new data in the serial log), with a time limit for prompts that do not echo."""
        nonlocal ser_in
        if ser_in is None:
            ser_in = socket.socket(socket.AF_UNIX)
            ser_in.connect(a.ser0)
            threading.Thread(target=lambda s: [None for _ in iter(lambda: s.recv(65536), b'')], args=(ser_in,), daemon=True).start()
        for i in range(len(b)):
            try:
                before = os.path.getsize(a.serial_log)
            except OSError:
                before = 0
            ser_in.sendall(b[i:i + 1])
            end = time.time() + 2.0
            while time.time() < end:
                time.sleep(0.02)
                try:
                    if os.path.getsize(a.serial_log) > before:
                        break
                except OSError:
                    pass
            time.sleep(0.04)
        time.sleep(delay)

    def drive_menu(new_text):
        if menu_state['done'] or a.menu == 'none':
            return
        if a.menu == 'bios' and re.search(r'Automatic boot in|Press \[Tab\] to edit', new_text):
            tline('bootloader', 'syslinux menu: TAB + append')
            send_serial(b'\t', 0.8)
            send_serial((' ' + a.menu_append).encode() + b'\r')
            menu_state['done'] = True
        elif a.menu == 'uefi' and re.search(r'executed automatically in|Use the .* keys to select', new_text):
            # GRUB's entry editor is not scriptable over a serial line (its cursor does not follow Ctrl-N/Down reliably and
            # the text landed on `set gfxpayload=keep`), so open the command line and type the entry as one line.
            tline('bootloader', 'GRUB menu: command line (linux + initrd + boot)')
            send_serial(b'c', 1.5)
            send_serial(('set gfxpayload=keep; linux %s; initrd %s; boot' % (a.menu_linux, a.menu_initrd)).encode() + b'\r')
            menu_state['done'] = True

    try:
        end = time.time() + 40
        while time.time() < end and not os.path.exists(a.qmp):
            if proc.poll() is not None:
                break
            time.sleep(0.2)
        try:
            qmp = Qmp(a.qmp)
        except Exception as ex:
            tline('qmp unavailable', str(ex)[:80])
        while True:
            if stop['sig']:
                res.reason = 'interrupted by signal %d' % stop['sig']
                break
            # --- serial
            new = ''
            try:
                with open(a.serial_log, 'rb') as fh:
                    fh.seek(raw_pos)
                    raw = fh.read()
                raw_pos += len(raw)
                if raw:
                    new = clean_bytes(raw)
            except IOError:
                pass
            if new:
                text += new
                if len(text) > 4000000:
                    text = text[-2000000:]
                buf = partial + new
                parts = buf.split('\n')
                partial = parts.pop()
                for ln in parts:
                    if ln.strip():
                        ts.write('[%7.1f] %s\n' % (el(), ln[:400]))
                ts.flush()
                window = text[-(len(new) + 4096):]
                drive_menu(window)
                for n, rx in ms:
                    if n not in seen and rx.search(window):
                        seen[n] = el()
                        tline(n)
                for n, rx in ff:
                    if rx.search(window) and failed_reason is None:
                        failed_reason = n
                        tline('FAIL-FAST MARKER', n)
                for e, rx in expect:
                    if e not in satisfied and rx.search(window):
                        satisfied[e] = el()
                        tline('expect seen', e)
            # --- guest agent
            if qga is not None and guest and el() - last_guest > 10 and not all(c in satisfied for c, _ in guest):
                last_guest = el()
                for c, _ in guest:
                    if c in satisfied:
                        continue
                    r = qga.shell_ok(c)
                    if r is not None and 'guest agent' not in seen:
                        seen['guest agent'] = el()
                        tline('guest agent answering')
                    if r is True:
                        satisfied[c] = el()
                        tline('guest check ok', c)
            # --- screenshots, heartbeat
            if (a.interval > 0 or a.expect_screen) and el() - last_shot >= (min(a.interval, 15) if a.expect_screen and a.interval > 0 else (a.interval or 15)):
                last_shot = el()
                screenshot('')
            if el() - last_beat >= 60:
                last_beat = el()
                lines = [l for l in (partial or '\n'.join(text.splitlines()[-1:])).splitlines() if l.strip()]
                print('[T+%6.0fs] waiting; ISO read %s; last serial: %s' % (el(), cd_read(), (lines[-1] if lines else '-')[:100]), flush=True)
            if a.expect_screen and SCREEN_LABEL not in satisfied and screen and screen[2] >= 64 and screen[3] > 0.2:
                satisfied[SCREEN_LABEL] = el()
                tline('expect seen', SCREEN_LABEL)
            # --- verdicts
            if all(e in satisfied for e in a.expect) and all(c in satisfied for c, _ in guest) and (not a.expect_screen or SCREEN_LABEL in satisfied):
                if done_at is None:
                    done_at = el()
                    if a.settle > 0:
                        tline('settling', '%ds more, then the final screenshot' % a.settle)
                if el() - done_at >= a.settle:
                    res.ok, res.code, res.reason = True, 0, 'all expectations seen'
                    break
            if failed_reason and not a.no_fail_fast:
                res.reason, res.code = 'guest failed: ' + failed_reason, 1
                break
            if proc.poll() is not None:
                res.reason, res.code = 'QEMU exited (status %s) before the expectations were met' % proc.returncode, 3
                break
            if el() > deadline:
                res.reason, res.code = 'timeout after %ds' % int(deadline), 1
                break
            time.sleep(1.0)
        screenshot('-final')
    finally:
        if qmp is not None and proc.poll() is None:
            try:
                qmp.call('quit')
            except Exception:
                pass
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        for f in (tl, ts, qout, qerr):
            f.close()
        if qga:
            qga.close()
    return res, seen, satisfied, screen, shots, el()


def write_summary(a, res, seen, satisfied, screen, shots, took):
    lines = ['== qemu-boot result ==',
             'result:    %s (%s)' % ('PASS' if res.ok else 'FAIL', res.reason),
             'iso:       %s' % a.iso,
             'mode:      %s    accel/cpu: %s/%s    smp %s    mem %sM    vga %s' % (a.mode_label, a.accel, a.cpu, a.smp, a.mem, a.vga),
             'duration:  %.0f s' % took]
    for e in list(a.expect) + list(a.guest_check) + ([SCREEN_LABEL] if a.expect_screen else []):
        lines.append('expect:    %-36s %s' % (e[:36], ('seen at T+%.0fs' % satisfied[e]) if e in satisfied else 'NOT seen'))
    ordered = sorted(seen.items(), key=lambda kv: kv[1])
    lines.append('milestones (seconds since QEMU start): ' + ', '.join('%s %.0f' % (n, t) for n, t in ordered))
    if screen:
        lines.append('screen:    %dx%d, %d distinct colours (sampled), %.0f%% non-black' % (screen[0], screen[1], screen[2], screen[3] * 100))
    if res.code == 3 or not seen:
        try:
            with open(os.path.join(a.workdir, 'qemu.err'), 'r', errors='replace') as fh:
                tail = [l.strip() for l in fh.read().splitlines() if l.strip()][-3:]
            if tail:
                lines.append('qemu said: ' + ' | '.join(tail)[:300])
        except IOError:
            pass
    lines.append('files:     %s (raw serial), %s, %s, %d screenshots in %s' % (
        a.serial_log, os.path.join(a.workdir, 'serial.txt'), a.timeline, len(shots), a.shots))
    text = '\n'.join(lines) + '\n'
    with open(os.path.join(a.workdir, 'result.txt'), 'w') as fh:
        fh.write(text)
    with open(os.path.join(a.workdir, 'result.json'), 'w') as fh:
        json.dump({'ok': res.ok, 'reason': res.reason, 'code': res.code, 'seconds': round(took, 1), 'milestones': seen,
                   'expectations': satisfied, 'screen': screen}, fh, indent=1)
    sys.stdout.write('\n' + text)


# --------------------------------------------------------------------------------------------------- self tests
def selftest():
    ok = []

    def check(name, cond):
        ok.append(bool(cond))
        print('%s  %s' % ('PASS' if cond else 'FAIL', name))
    # terminal text
    raw = b'\x1b[0;32m  OK  \x1b[0m] Reached target \x1b[0;1;39mDRM module load target\x1b[0m.\r\n\x1b]3008;start=ab;x\x1b\\CachyOS login: '
    t = clean_bytes(raw)
    check('ANSI and OSC sequences are stripped', 'Reached target DRM module load target.' in t and '3008' not in t)
    check('login prompt without newline matches', re.search(r'(?m)login:\s*$', t) is not None)
    check('milestone: DRM target', any(n == 'DRM target reached' and re.search(p, t, re.M) for n, p in MILESTONES))
    check('fail-fast: emergency', re.search(FAILFAST[0][1], 'You are in emergency mode.') is not None)
    banner = dict(MILESTONES)['systemd started']
    soup = clean_bytes(b'\x1bP+q6E616D65\x1b\\\x1b[18t\x1b7\x1b[32766;32766H\x1b[6n\x1b8Welcome to \x1b[38;2;23;147;209mCachyOS\x1b[0m!\r\n\r\n')
    check('milestone: the systemd banner matches, GRUB\'s own welcome line does not',
          re.search(banner, soup) is not None and
          re.search(banner, 'previous menu.      Welcome to CachyOS 261003 Live ISO (UEFI)!     ------') is None)
    # cpio round trip, including a symlink and an empty file
    w = CpioWriter()
    w.add('config', stat.S_IFREG | 0o644, b'LATEHOOKS="a"\n')
    w.add('d', stat.S_IFDIR | 0o755)
    w.add('d/l', stat.S_IFLNK | 0o777, b'target')
    w.add('d/empty', stat.S_IFREG | 0o644, b'')
    blob = w.finish()
    ents, end = cpio_parse(blob, 0)
    check('cpio newc round trip', ents['config'][1] == b'LATEHOOKS="a"\n' and ents['d/l'][1] == b'target' and ents['d/empty'][1] == b'' and end <= len(blob))
    check('LATEHOOKS gets ci_inject', add_latehook(b'X=1\nLATEHOOKS="a b"\nY=2\n', 'ci_inject') == b'X=1\nLATEHOOKS="a b ci_inject"\nY=2\n')
    check('LATEHOOKS added when missing', add_latehook(b'X=1\n', 'ci_inject').endswith(b'LATEHOOKS="ci_inject"\n'))
    # an initramfs shaped like mkinitcpio's: plain early archive, then an xz-compressed archive with /config
    import tempfile
    d = tempfile.mkdtemp(prefix='qb-selftest.')
    early = CpioWriter()
    early.add('early_cpio', stat.S_IFREG | 0o644, b'')
    main = CpioWriter()
    main.add('config', stat.S_IFREG | 0o644, FALLBACK_CONFIG)
    src = os.path.join(d, 'initrd.img')
    with open(src, 'wb') as fh:
        fh.write(early.finish())
        fh.write(lzma.compress(main.finish(), format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32))
    check('config is read from early-cpio + xz initramfs', initramfs_read(src, 'config') == FALLBACK_CONFIG)
    tree = os.path.join(d, 'tree')
    os.makedirs(os.path.join(tree, 'etc/systemd/system'))
    with open(os.path.join(tree, 'etc/systemd/system/x.conf'), 'wb') as fh:
        fh.write(b'[Unit]\n')
    with open(os.path.join(tree, 'etc/run.sh'), 'wb') as fh:
        fh.write(b'#!/bin/sh\n')
    os.chmod(os.path.join(tree, 'etc/run.sh'), 0o755)
    os.symlink('run.sh', os.path.join(tree, 'etc/link'))
    dst = os.path.join(d, 'out.img')
    n = build_initrd(src, dst, [tree], generator=b'#!/bin/sh\nexit 0\n')
    with open(dst, 'rb') as fh:
        out = fh.read()
    with open(src, 'rb') as fh:
        orig = fh.read()
    check('injected initrd keeps the original bytes as a prefix', out.startswith(orig))
    ents, _ = cpio_parse(out, len(orig))
    check('appended archive has config with the ci_inject late hook', b'ci_inject' in ents['config'][1])
    check('appended archive has the hook, executable', ents['hooks/ci_inject'][0] & 0o111 == 0o111)
    check('tree files are under ci_inject_root with their modes',
          ents['ci_inject_root/etc/run.sh'][0] & 0o777 == 0o755 and ents['ci_inject_root/etc/systemd/system/x.conf'][0] & 0o777 == 0o644)
    check('symlinks are kept', stat.S_ISLNK(ents['ci_inject_root/etc/link'][0]) and ents['ci_inject_root/etc/link'][1] == b'run.sh')
    names = list(ents)
    check('parents are listed before their files',
          all(names.index('/'.join(nm.split('/')[:i])) < names.index(nm)
              for nm in names if nm.startswith('ci_inject_root/') for i in range(2, len(nm.split('/')))))
    check('generator lands in usr/lib/systemd/system-generators, executable',
          ents['ci_inject_root/usr/lib/systemd/system-generators/companion-vm-timeouts'][0] & 0o111 == 0o111 and n > 5)
    # grub.cfg
    cfg = ('menuentry "A" {\n    linux /arch/boot/x86_64/vmlinuz-linux-cachyos archisobasedir=arch archisosearchuuid=U x=1\n'
           '    initrd /arch/boot/x86_64/initramfs-linux-cachyos.img\n}\n'
           'menuentry "B" {\n    linux /arch/boot/x86_64/vmlinuz-linux-cachyos-lts archisobasedir=arch y=2\n'
           '    initrd /arch/boot/x86_64/initramfs-linux-cachyos-lts.img\n}\n')
    check('grub.cfg: cachyos entry', grub_cmdline(cfg, 'cachyos') == ('arch/boot/x86_64/vmlinuz-linux-cachyos', 'arch/boot/x86_64/initramfs-linux-cachyos.img', 'archisobasedir=arch archisosearchuuid=U x=1'))
    check('grub.cfg: lts entry is not confused with cachyos', grub_cmdline(cfg, 'cachyos-lts')[2] == 'archisobasedir=arch y=2')
    check('grub.cfg: unknown kernel gives None', grub_cmdline(cfg, 'nope') is None)
    # images
    ppm = b'P6\n8 8\n255\n' + (b'\x00\x00\x00' * 32 + b'\x10\x20\x30' * 32)
    png = ppm_to_png(ppm)
    check('png header and IDAT inflate to 8 rows', png[:8] == b'\x89PNG\r\n\x1a\n' and len(zlib.decompress(png[png.index(b'IDAT') + 4:png.index(b'IEND') - 8])) == 8 * (1 + 24))
    st = ppm_stats(ppm)
    check('screen stats: two colours, half non-black', st[2] == 2 and abs(st[3] - 0.5) < 0.01)
    import shutil
    shutil.rmtree(d, ignore_errors=True)
    print('%d/%d passed' % (sum(ok), len(ok)))
    return 0 if all(ok) else 1


# --------------------------------------------------------------------------------------------------- CLI
def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd')
    sub.add_parser('selftest')
    p = sub.add_parser('grub')
    p.add_argument('cfg')
    p.add_argument('kernel')
    p = sub.add_parser('initrd')
    p.add_argument('src')
    p.add_argument('dst')
    p.add_argument('--tree', action='append', default=[])
    p.add_argument('--generator')
    p = sub.add_parser('run')
    for opt in ('qmp', 'ser0', 'qga', 'serial_log', 'shots', 'timeline', 'workdir', 'iso', 'menu', 'menu_append', 'mode_label',
                'accel', 'cpu', 'smp', 'mem', 'vga', 'menu_linux', 'menu_initrd'):
        p.add_argument('--' + opt.replace('_', '-'), dest=opt, default='')
    p.add_argument('--timeout', type=float, default=1800)
    p.add_argument('--interval', type=float, default=30)
    p.add_argument('--settle', type=float, default=0)
    p.add_argument('--expect', action='append', default=[])
    p.add_argument('--guest-check', action='append', default=[], dest='guest_check')
    p.add_argument('--no-fail-fast', action='store_true', dest='no_fail_fast')
    p.add_argument('--expect-screen', action='store_true', dest='expect_screen')
    argv, qemu = sys.argv[1:], []
    if '--' in argv:
        i = argv.index('--')
        argv, qemu = argv[:i], argv[i + 1:]
    a = ap.parse_args(argv)
    if a.cmd == 'selftest':
        return selftest()
    if a.cmd == 'grub':
        with open(a.cfg, 'r', errors='replace') as fh:
            r = grub_cmdline(fh.read(), a.kernel)
        if not r:
            return 1
        print(r[0])
        print(r[1] or '')
        print(r[2])
        return 0
    if a.cmd == 'initrd':
        gen = None
        if a.generator:
            with open(a.generator, 'rb') as fh:
                gen = fh.read()
        n = build_initrd(a.src, a.dst, a.tree, gen)
        print('%d entries injected' % n)
        return 0
    if a.cmd == 'run':
        res, seen, satisfied, screen, shots, took = run_supervisor(a, qemu)
        write_summary(a, res, seen, satisfied, screen, shots, took)
        return res.code
    ap.print_help()
    return 2


sys.exit(main())
PYEOF
}

selftest() {
  local rc=0 here overlay_copy
  pydriver selftest || rc=1
  here="$(cd "$(dirname "$0")" && pwd)"
  overlay_copy="$here/../overlay/files/airootfs/usr/lib/systemd/system-generators/companion-vm-timeouts"
  if [ -f "$overlay_copy" ]; then
    if vm_fixes_generator | cmp -s - "$overlay_copy"; then echo "PASS  the overlay's companion-vm-timeouts is identical to the --vm-fixes generator"
    else echo "FAIL  the overlay's companion-vm-timeouts differs from the generator embedded in qemu-boot.sh (regenerate it with --print-vm-fixes-generator)"; rc=1; fi
  else
    echo "SKIP  the overlay has no companion-vm-timeouts yet; --vm-fixes is the only copy"
  fi
  if vm_fixes_generator | sh -n 2>/dev/null; then echo "PASS  the generator is valid sh"; else echo "FAIL  the generator is not valid sh"; rc=1; fi
  return "$rc"
}

# ---------------------------------------------------------------------------------------------------------------------
# Option parsing
# ---------------------------------------------------------------------------------------------------------------------
MODE=direct; TIMEOUT=""; SETTLE=0; WORK=""; SHOTS=""; SHOT_INTERVAL=30; SERIAL_LOG=""; TIMELINE=""; APPEND=""; KERNEL=cachyos
CMDLINE=""; KERNEL_PATH=""; INITRD_PATH=""; VM_FIXES=0; DEBUG_SHELL=0; VGA=std; CPU=""; SMP=4; MEM=6144; MACHINE=q35
ACCEL=auto; CD_BUS=ahci; NET=1; VNC=""; OVMF_CODE=""; OVMF_VARS=""; NO_FAIL_FAST=0; NO_MENU_EDIT=0; EXPECT_PLASMA=0; EXPECT_SCREEN=0; ISO=""
EXPECTS=(); GUEST_CHECKS=(); INJECTS=(); QEMU_EXTRA=()

need_arg() { [ "$#" -ge 2 ] || die "$1 needs a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) need_arg "$@"; MODE="$2"; shift 2 ;;
    --expect) need_arg "$@"; EXPECTS+=("$2"); shift 2 ;;
    --expect-plasma) EXPECT_PLASMA=1; shift ;;
    --expect-screen) EXPECT_SCREEN=1; shift ;;
    --guest-check) need_arg "$@"; GUEST_CHECKS+=("$2"); shift 2 ;;
    --timeout) need_arg "$@"; TIMEOUT="$2"; shift 2 ;;
    --settle) need_arg "$@"; SETTLE="$2"; shift 2 ;;
    --work) need_arg "$@"; WORK="$2"; shift 2 ;;
    --shots) need_arg "$@"; SHOTS="$2"; shift 2 ;;
    --shot-interval) need_arg "$@"; SHOT_INTERVAL="$2"; shift 2 ;;
    --serial-log) need_arg "$@"; SERIAL_LOG="$2"; shift 2 ;;
    --timeline) need_arg "$@"; TIMELINE="$2"; shift 2 ;;
    --append) need_arg "$@"; APPEND="$2"; shift 2 ;;
    --kernel) need_arg "$@"; KERNEL="$2"; shift 2 ;;
    --cmdline) need_arg "$@"; CMDLINE="$2"; shift 2 ;;
    --kernel-path) need_arg "$@"; KERNEL_PATH="$2"; shift 2 ;;
    --initrd-path) need_arg "$@"; INITRD_PATH="$2"; shift 2 ;;
    --vm-fixes) VM_FIXES=1; shift ;;
    --inject) need_arg "$@"; INJECTS+=("$2"); shift 2 ;;
    --debug-shell) DEBUG_SHELL=1; shift ;;
    --vga) need_arg "$@"; VGA="$2"; shift 2 ;;
    --cpu) need_arg "$@"; CPU="$2"; shift 2 ;;
    --smp) need_arg "$@"; SMP="$2"; shift 2 ;;
    --mem) need_arg "$@"; MEM="$2"; shift 2 ;;
    --machine) need_arg "$@"; MACHINE="$2"; shift 2 ;;
    --accel) need_arg "$@"; ACCEL="$2"; shift 2 ;;
    --cd-bus) need_arg "$@"; CD_BUS="$2"; shift 2 ;;
    --no-net) NET=0; shift ;;
    --vnc) need_arg "$@"; VNC="$2"; shift 2 ;;
    --qemu-arg) need_arg "$@"; QEMU_EXTRA+=("$2"); shift 2 ;;
    --ovmf-code) need_arg "$@"; OVMF_CODE="$2"; shift 2 ;;
    --ovmf-vars) need_arg "$@"; OVMF_VARS="$2"; shift 2 ;;
    --no-fail-fast) NO_FAIL_FAST=1; shift ;;
    --no-menu-edit) NO_MENU_EDIT=1; shift ;;
    --selftest) selftest; exit $? ;;
    --print-vm-fixes-generator) vm_fixes_generator; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) [ -z "$ISO" ] || die "more than one ISO given: $ISO and $1"; ISO="$1"; shift ;;
  esac
done
if [ "$#" -gt 0 ]; then
  if [ -z "$ISO" ] && [ "$#" -eq 1 ]; then ISO="$1"; else die "unexpected arguments: $*"; fi
fi
[ -n "$ISO" ] || { usage >&2; exit 2; }
[ -r "$ISO" ] || die "cannot read the ISO: $ISO"
ISO="$(cd "$(dirname "$ISO")" && pwd)/$(basename "$ISO")"

case "$MODE" in direct|bios|uefi) ;; *) die "--mode must be direct, bios or uefi" ;; esac
case "$VGA" in std|virtio|qxl|vmware|cirrus|none) ;; *) die "--vga must be std, virtio, qxl, vmware, cirrus or none" ;; esac
case "$CD_BUS" in ahci|ide|scsi) ;; *) die "--cd-bus must be ahci, ide or scsi" ;; esac
case "$MACHINE" in q35|pc) ;; *) die "--machine must be q35 or pc" ;; esac
case "$KERNEL" in lts) KERNEL=cachyos-lts ;; esac
if [ "$MODE" != direct ]; then
  { [ "$VM_FIXES" -eq 0 ] && [ "${#INJECTS[@]}" -eq 0 ]; } || die "--vm-fixes and --inject need --mode direct (they ride on the -initrd that only direct mode controls)"
fi
for t in ${INJECTS[@]+"${INJECTS[@]}"}; do [ -d "$t" ] || die "--inject: not a directory: $t"; done

command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found (brew install qemu / apt-get install qemu-system-x86)"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

# ---------------------------------------------------------------------------------------------------------------------
# Work directory, sockets, acceleration
# ---------------------------------------------------------------------------------------------------------------------
if [ -z "$WORK" ]; then WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-cachyos-boot.XXXXXX")"; fi
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
[ -n "$SHOTS" ] || SHOTS="$WORK/shots"
[ -n "$SERIAL_LOG" ] || SERIAL_LOG="$WORK/serial.log"
[ -n "$TIMELINE" ] || TIMELINE="$WORK/timeline.txt"
mkdir -p "$SHOTS" "$(dirname "$SERIAL_LOG")" "$(dirname "$TIMELINE")"
SOCK="$(mktemp -d "${TMPDIR:-/tmp}/cibootq.XXXXXX")"
DRIVER_PID=""
cleanup() {
  local qpid=""
  if [ -n "$DRIVER_PID" ] && kill -0 "$DRIVER_PID" 2>/dev/null; then kill -TERM "$DRIVER_PID" 2>/dev/null || true; wait "$DRIVER_PID" 2>/dev/null || true; fi
  # the supervisor stops QEMU itself; this is the backstop for a supervisor that died without doing so
  [ -f "$WORK/qemu.pid" ] && qpid="$(cat "$WORK/qemu.pid" 2>/dev/null || true)"
  if [ -n "$qpid" ] && kill -0 "$qpid" 2>/dev/null && ps -o command= -p "$qpid" 2>/dev/null | grep -q 'ci-cachyos-boot'; then
    kill -TERM "$qpid" 2>/dev/null || true; sleep 2; kill -KILL "$qpid" 2>/dev/null || true
  fi
  rm -rf "$SOCK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ "$ACCEL" = auto ]; then
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL=kvm
  elif [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = x86_64 ]; then ACCEL=hvf
  else ACCEL=tcg; fi
fi
case "$ACCEL" in
  kvm|hvf) ACCEL_ARGS=(-accel "$ACCEL"); [ -n "$CPU" ] || CPU=host; [ -n "$TIMEOUT" ] || TIMEOUT=300 ;;
  tcg) ACCEL_ARGS=(-accel tcg,thread=multi); [ -n "$CPU" ] || CPU=max; [ -n "$TIMEOUT" ] || TIMEOUT=1800 ;;
  *) die "--accel must be auto, tcg, kvm or hvf" ;;
esac

# ---------------------------------------------------------------------------------------------------------------------
# Expectations
# ---------------------------------------------------------------------------------------------------------------------
if [ "$EXPECT_PLASMA" -eq 1 ]; then
  GUEST_CHECKS+=("pgrep -x plasmashell >/dev/null && pgrep -x kwin_wayland >/dev/null")
fi
if [ "${#EXPECTS[@]}" -eq 0 ] && [ "${#GUEST_CHECKS[@]}" -eq 0 ] && [ "$EXPECT_SCREEN" -eq 0 ]; then
  if [ "$NO_MENU_EDIT" -eq 1 ]; then GUEST_CHECKS+=("pgrep -x plasmashell >/dev/null && pgrep -x kwin_wayland >/dev/null"); else EXPECTS+=('login:\s*$'); fi
fi

# ---------------------------------------------------------------------------------------------------------------------
# Reading the ISO
# ---------------------------------------------------------------------------------------------------------------------
iso_extract() {   # dest member...
  local dest="$1"; shift
  mkdir -p "$dest"
  if command -v bsdtar >/dev/null 2>&1; then bsdtar -xf "$ISO" -C "$dest" "$@"
  elif command -v 7z >/dev/null 2>&1; then 7z x -y -bso0 -bsp0 "-o$dest" "$ISO" "$@" >/dev/null
  elif command -v xorriso >/dev/null 2>&1; then
    local m; for m in "$@"; do xorriso -osirrox on -indev "$ISO" -extract "/$m" "$dest/$m" >/dev/null 2>&1; done
  else die "need bsdtar, 7z or xorriso to read the ISO (direct mode)"; fi
}

KERNEL_FILE=""; INITRD_FILE=""
if [ "$MODE" = direct ] || { [ "$MODE" = uefi ] && [ "$NO_MENU_EDIT" -eq 0 ]; }; then
  mkdir -p "$WORK/boot"
  if [ -z "$CMDLINE" ] || [ -z "$KERNEL_PATH" ]; then
    iso_extract "$WORK/boot/iso" boot/grub/grub.cfg 2>/dev/null || true
    [ -f "$WORK/boot/iso/boot/grub/grub.cfg" ] || die "no boot/grub/grub.cfg in the ISO; pass --cmdline, --kernel-path and --initrd-path"
    g="$(pydriver grub "$WORK/boot/iso/boot/grub/grub.cfg" "$KERNEL")" || die "grub.cfg has no entry booting vmlinuz-linux-$KERNEL (try --kernel lts, or --cmdline/--kernel-path/--initrd-path)"
    g_k="$(printf '%s\n' "$g" | sed -n 1p)"; g_i="$(printf '%s\n' "$g" | sed -n 2p)"; g_c="$(printf '%s\n' "$g" | sed -n 3p)"
    [ -n "$KERNEL_PATH" ] || KERNEL_PATH="$g_k"
    [ -n "$INITRD_PATH" ] || INITRD_PATH="$g_i"
    [ -n "$CMDLINE" ] || CMDLINE="$g_c"
  fi
  [ -n "$INITRD_PATH" ] || INITRD_PATH="$(dirname "$KERNEL_PATH")/initramfs-linux-${KERNEL}.img"
fi
if [ "$MODE" = direct ]; then
  iso_extract "$WORK/boot/iso" "$KERNEL_PATH" "$INITRD_PATH" 2>/dev/null || true
  KERNEL_FILE="$WORK/boot/iso/$KERNEL_PATH"; INITRD_FILE="$WORK/boot/iso/$INITRD_PATH"
  [ -f "$KERNEL_FILE" ] || die "$KERNEL_PATH is not in the ISO"
  [ -f "$INITRD_FILE" ] || die "$INITRD_PATH is not in the ISO"
  if [ "$VM_FIXES" -eq 1 ] || [ "${#INJECTS[@]}" -gt 0 ]; then
    vm_fixes_generator > "$WORK/boot/companion-vm-timeouts"
    inject_args=()
    for t in ${INJECTS[@]+"${INJECTS[@]}"}; do inject_args+=(--tree "$t"); done
    gen_args=(); [ "$VM_FIXES" -eq 1 ] && gen_args=(--generator "$WORK/boot/companion-vm-timeouts")
    pydriver initrd "$INITRD_FILE" "$WORK/boot/initrd-injected.img" ${inject_args[@]+"${inject_args[@]}"} ${gen_args[@]+"${gen_args[@]}"} \
      || die "could not build the injected initramfs"
    INITRD_FILE="$WORK/boot/initrd-injected.img"
  fi
fi

# ---------------------------------------------------------------------------------------------------------------------
# Kernel arguments added by this script (all modes): serial console + a quiet-free, status-visible boot
# ---------------------------------------------------------------------------------------------------------------------
EXTRA_ARGS="console=tty0 console=ttyS0,115200 systemd.show_status=1"
[ "$DEBUG_SHELL" -eq 1 ] && EXTRA_ARGS="$EXTRA_ARGS systemd.debug_shell=/dev/ttyS1"
[ -z "$APPEND" ] || EXTRA_ARGS="$EXTRA_ARGS $APPEND"
MENU_LINUX=""; MENU_INITRD=""
if [ "$MODE" = uefi ] && [ "$NO_MENU_EDIT" -eq 0 ]; then MENU_LINUX="/$KERNEL_PATH $CMDLINE $EXTRA_ARGS"; MENU_INITRD="/$INITRD_PATH"; fi

# ---------------------------------------------------------------------------------------------------------------------
# The QEMU command line
# ---------------------------------------------------------------------------------------------------------------------
Q=(qemu-system-x86_64 -name ci-cachyos-boot -pidfile "$WORK/qemu.pid" -machine "$MACHINE" ${ACCEL_ARGS[@]+"${ACCEL_ARGS[@]}"} -cpu "$CPU" -smp "$SMP" -m "$MEM"
   -rtc base=utc -no-reboot
   -drive "file=$(qesc "$ISO"),media=cdrom,readonly=on,if=none,id=cd,format=raw")
case "$CD_BUS" in
  ahci) Q+=(-device ahci,id=ahci -device ide-cd,bus=ahci.0,drive=cd,bootindex=1) ;;
  ide)  [ "$MACHINE" = pc ] && Q+=(-device ide-cd,drive=cd,bootindex=1) || die "--cd-bus ide needs --machine pc" ;;
  scsi) Q+=(-device virtio-scsi-pci,id=scsi0 -device scsi-cd,bus=scsi0.0,drive=cd,bootindex=1) ;;
esac
if [ "$VGA" = none ]; then Q+=(-vga none); else Q+=(-vga "$VGA"); fi
if [ -n "$VNC" ]; then Q+=(-display "vnc=127.0.0.1$VNC"); else Q+=(-display none); fi
Q+=(-chardev "socket,id=ser0,path=$SOCK/ser0.sock,server=on,wait=off,logfile=$(qesc "$SERIAL_LOG"),logappend=off" -serial chardev:ser0)
if [ "$DEBUG_SHELL" -eq 1 ]; then
  Q+=(-chardev "socket,id=ser1,path=$SOCK/ser1.sock,server=on,wait=off,logfile=$(qesc "$WORK")/serial1.log,logappend=off" -serial chardev:ser1)
fi
Q+=(-qmp "unix:$SOCK/qmp.sock,server=on,wait=off"
    -device virtio-serial-pci,id=vser0 -chardev "socket,id=qga0,path=$SOCK/qga.sock,server=on,wait=off"
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0,bus=vser0.0
    -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0
    -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0)
if [ "$NET" -eq 1 ]; then Q+=(-nic user,model=virtio-net-pci); else Q+=(-nic none); fi

MENU=none
case "$MODE" in
  direct)
    Q+=(-kernel "$KERNEL_FILE" -initrd "$INITRD_FILE" -append "$CMDLINE $EXTRA_ARGS") ;;
  bios) MENU=bios ;;
  uefi)
    MENU=uefi
    if [ -z "$OVMF_CODE" ]; then
      here="$(cd "$(dirname "$0")" && pwd)"
      for pair in "$here/../../../../stick/tests/secureboot/out/firmware/OVMF_CODE_4M.fd:$here/../../../../stick/tests/secureboot/out/firmware/OVMF_VARS_4M.fd" \
                  /opt/homebrew/share/qemu/edk2-x86_64-code.fd:/opt/homebrew/share/qemu/edk2-i386-vars.fd \
                  /usr/local/share/qemu/edk2-x86_64-code.fd:/usr/local/share/qemu/edk2-i386-vars.fd \
                  /usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd \
                  /usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd \
                  /usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd \
                  /usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd; do
        if [ -f "${pair%%:*}" ] && [ -f "${pair##*:}" ]; then OVMF_CODE="${pair%%:*}"; OVMF_VARS="${pair##*:}"; break; fi
      done
    fi
    { [ -f "$OVMF_CODE" ] && [ -f "$OVMF_VARS" ]; } || die "no OVMF firmware found; pass --ovmf-code and --ovmf-vars"
    cp "$OVMF_VARS" "$WORK/ovmf-vars.fd"
    Q+=(-drive "if=pflash,format=raw,unit=0,readonly=on,file=$(qesc "$OVMF_CODE")" -drive "if=pflash,format=raw,unit=1,file=$(qesc "$WORK")/ovmf-vars.fd") ;;
esac
Q+=(${QEMU_EXTRA[@]+"${QEMU_EXTRA[@]}"})
if [ "$NO_MENU_EDIT" -eq 1 ]; then
  [ "$MODE" != direct ] || die "--no-menu-edit is for --mode bios or uefi"
  MENU=none
fi

echo "$SELF: mode $MODE, accel $ACCEL, cpu $CPU, work $WORK" >&2
[ "$DEBUG_SHELL" -eq 1 ] && echo "$SELF: debug shell socket: $SOCK/ser1.sock (and $WORK/serial1.log); the sockets live only while this script runs" >&2
{ printf '%s\n' "${Q[@]}"; } > "$WORK/qemu-cmdline.txt"

# ---------------------------------------------------------------------------------------------------------------------
# Supervise
# ---------------------------------------------------------------------------------------------------------------------
run_args=(run --qmp "$SOCK/qmp.sock" --ser0 "$SOCK/ser0.sock" --qga "$SOCK/qga.sock" --serial-log "$SERIAL_LOG" --shots "$SHOTS"
          --timeline "$TIMELINE" --workdir "$WORK" --iso "$ISO" --menu "$MENU" --menu-append "$EXTRA_ARGS" --menu-linux "$MENU_LINUX" --menu-initrd "$MENU_INITRD"
          --mode-label "$MODE" --accel "$ACCEL" --cpu "$CPU" --smp "$SMP" --mem "$MEM" --vga "$VGA"
          --timeout "$TIMEOUT" --settle "$SETTLE" --interval "$SHOT_INTERVAL")
[ "$NO_FAIL_FAST" -eq 0 ] || run_args+=(--no-fail-fast)
[ "$EXPECT_SCREEN" -eq 0 ] || run_args+=(--expect-screen)
for e in ${EXPECTS[@]+"${EXPECTS[@]}"}; do run_args+=(--expect "$e"); done
for c in ${GUEST_CHECKS[@]+"${GUEST_CHECKS[@]}"}; do run_args+=(--guest-check "$c"); done

set +e
pydriver "${run_args[@]}" -- "${Q[@]}" &
DRIVER_PID=$!
wait "$DRIVER_PID"
rc=$?
DRIVER_PID=""
exit "$rc"
