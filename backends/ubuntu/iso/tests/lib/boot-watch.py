#!/usr/bin/env python3
"""Start QEMU, watch an installed system boot, and decide: reached the GDM greeter, or not. Used by tests/installed-boot.sh.

  boot-watch.py --serial LOG --qmp SOCK --shots DIR --result FILE --timeline FILE [--timeout S] [--grace S]
                [--shot-interval S] [--poll S] -- qemu-system-x86_64 ARGS...

QEMU must be given -serial file:LOG and -qmp unix:SOCK,server,nowait (the shell script does). The decision, from the serial console
(the installed kernel command line has console=ttyS0 last, so the initramfs and systemd talk there) and the display:

  PASS   the in-guest probe printed CI-PROBE-OK (display manager active, a greeter session, gnome-shell of the gdm user alive for
         5 s, Plymouth gone) AND the screen shows a drawn picture (>= 64 colours, > 20% not black) within --grace seconds after it;
  FAIL   a known failure line on the serial console (the casper live-medium search, an initramfs shell, a panic, emergency mode),
         the probe's own CI-PROBE-FAIL, QEMU exiting early, or --timeout seconds without the greeter.

Writes RESULT (key=value lines), TIMELINE (seconds since QEMU started), a screenshot every --shot-interval seconds and final.png in
SHOTS, and guest-report.txt (the probe's report) next to RESULT. Exit status: 0 PASS, 1 FAIL, 2 QEMU cannot be started.

(c) Companion Intelligence - Lifescope Inc
"""
import argparse
import os
import re
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True   # importing qmp must not leave a __pycache__ in the repository
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qmp as qmplib  # noqa: E402

ANSI = re.compile(r'\x1b\[[0-9;?=]*[A-Za-z]|\x1b[()][A-Z0-9]|\r')

# (label, regex, explanation): a boot that printed one of these is not going to reach the greeter.
FAILFAST = [
    ('casper', r'Unable to find a medium containing a live file system',
     'the installed system boots into casper (the live-session scripts in the initramfs) and searches for a live medium'),
    ('casper', r'Attempt interactive netboot from a URL',
     'the installed system boots into casper (the live-session scripts in the initramfs) and offers a netboot'),
    ('kernel panic', r'Kernel panic - not syncing', 'the kernel panicked'),
    ('initramfs shell', r'\(initramfs\)|Dropping to a shell|ALERT!', 'the initramfs gave up and dropped to a shell'),
    ('root device', r'Gave up waiting for root file system device', 'the root file system was not found'),
    ('emergency mode', r'You are in emergency mode|Give root password for maintenance|Welcome to emergency mode',
     'systemd dropped to emergency mode'),
    ('firmware', r'BdsDxe: failed to start', 'the firmware could not start the boot entry'),
    ('no boot entry', r'starting Boot\d+ "EFI Internal Shell"',
     'the firmware found nothing to boot (no mountable ESP or no EFI/BOOT/BOOTX64.EFI) and started its EFI shell'),
]
CASPER_LOOP = re.compile(r"can't open /dev/sr0: No medium found")

TIMELINE_EVENTS = [
    ('firmware output on the serial console', r'BdsDxe|UEFI|EFI'),
    ('boot entry started by the firmware', r'BdsDxe: starting Boot'),
    ('kernel/initramfs output', r'Linux version|/init:|Loading, please wait|Begin: '),
    ('systemd started', r'Welcome to .*!|systemd\[1\]|Started .*'),
    ('display manager started', r'Started .*(Display Manager|GDM)'),
    ('probe running', r'CI-PROBE: begin'),
]


class Watch(object):
    def __init__(self, a, argv):
        self.a = a
        self.argv = argv
        self.t0 = time.time()
        self.tl = open(a.timeline, 'w')
        self.text = ''
        self.raw_pos = 0
        self.events = set()
        self.shots = []
        self.last_stats = None
        self.q = None
        self.proc = None

    def el(self):
        return time.time() - self.t0

    def tline(self, name, detail=''):
        s = 'T+%7.1fs  %-42s %s' % (self.el(), name, detail)
        self.tl.write(s.rstrip() + '\n')
        self.tl.flush()
        print('[%s]' % s.rstrip(), flush=True)

    def read_serial(self):
        try:
            with open(self.a.serial, 'rb') as fh:
                fh.seek(self.raw_pos)
                chunk = fh.read()
                self.raw_pos += len(chunk)
        except OSError:
            return ''
        new = ANSI.sub('', chunk.decode('utf-8', errors='replace'))
        self.text += new
        return new

    def screenshot(self, tag):
        if self.q is None:
            try:
                self.q = qmplib.Qmp(self.a.qmp, timeout=1.0)
            except Exception:
                return None
        png = os.path.join(self.a.shots, 'shot-%04ds%s.png' % (int(self.el()), tag))
        try:
            st = qmplib.shot(self.q, png, os.path.join(self.a.shots, '.shot.ppm'))
        except Exception as ex:
            self.tline('screenshot failed', str(ex)[:100])
            self.q = None
            return None
        self.shots.append(png)
        self.last_stats = st
        try:
            with open(os.path.join(self.a.shots, 'last.png'), 'wb') as dst, open(png, 'rb') as src:
                dst.write(src.read())
        except OSError:
            pass
        return st

    def stop_qemu(self):
        if self.proc is None or self.proc.poll() is not None:
            return
        try:
            if self.q is None:
                self.q = qmplib.Qmp(self.a.qmp, timeout=2.0)
            self.q.call('quit')
        except Exception:
            pass
        for _ in range(100):
            if self.proc.poll() is not None:
                return
            time.sleep(0.1)
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()

    def result(self, ok, reason, extra=None):
        self.tline('RESULT', ('PASS: ' if ok else 'FAIL: ') + reason)
        lines = ['RESULT=%s' % ('PASS' if ok else 'FAIL'), 'REASON=%s' % reason, 'SECONDS=%.0f' % self.el()]
        for k, v in sorted((extra or {}).items()):
            lines.append('%s=%s' % (k, v))
        if self.last_stats:
            lines.append('SCREEN=%dx%d colours=%d nonblack=%s' % (self.last_stats['width'], self.last_stats['height'],
                                                                self.last_stats['colours'], self.last_stats['nonblack']))
        with open(self.a.result, 'w') as fh:
            fh.write('\n'.join(lines) + '\n')
        return 0 if ok else 1

    def report(self):
        """The probe's lines (between CI-PROBE: begin and the last CI-PROBE line seen) into guest-report.txt."""
        lines = [l for l in self.text.splitlines() if 'CI-PROBE' in l]
        path = os.path.join(os.path.dirname(os.path.abspath(self.a.result)), 'guest-report.txt')
        with open(path, 'w') as fh:
            fh.write('\n'.join(l[l.index('CI-PROBE'):] for l in lines) + ('\n' if lines else ''))

    def run(self):
        os.makedirs(self.a.shots, exist_ok=True)
        try:
            self.proc = subprocess.Popen(self.argv, stdin=subprocess.DEVNULL, start_new_session=True,
                                         stdout=open(os.path.join(os.path.dirname(os.path.abspath(self.a.result)), 'qemu.out'), 'w'),
                                         stderr=open(os.path.join(os.path.dirname(os.path.abspath(self.a.result)), 'qemu.err'), 'w'))
        except OSError as ex:
            sys.stderr.write('cannot start %s: %s\n' % (self.argv[0], ex))
            return 2
        self.tline('qemu started', 'pid %d' % self.proc.pid)
        stop = {'sig': None}
        signal.signal(signal.SIGTERM, lambda s, f: stop.update(sig=s))
        signal.signal(signal.SIGINT, lambda s, f: stop.update(sig=s))
        casper_loops = 0
        probe_ok_at = None
        last_shot = -1e9
        rc = None
        try:
            while rc is None:
                time.sleep(self.a.poll)
                if stop['sig']:
                    rc = self.result(False, 'interrupted by signal %s' % stop['sig'])
                    break
                new = self.read_serial()
                for name, pat in TIMELINE_EVENTS:
                    if name not in self.events and re.search(pat, self.text):
                        self.events.add(name)
                        self.tline(name)
                if new:
                    casper_loops += len(CASPER_LOOP.findall(new))
                if self.proc.poll() is not None:
                    self.report()
                    rc = self.result(False, 'QEMU exited early with status %s before the greeter (the guest powered off or rebooted)'
                                     % self.proc.returncode)
                    break
                # Known failures first: they are definite, and the cause is named.
                if probe_ok_at is None:
                    for label, pat, why in FAILFAST:
                        if re.search(pat, self.text):
                            self.screenshot('-fail')
                            self.tline('failure line seen', label)
                            self.report()
                            rc = self.result(False, '%s: %s' % (label, why), {'FAIL_KIND': label})
                            break
                    if rc is not None:
                        break
                    if casper_loops >= 6:
                        self.screenshot('-fail')
                        self.report()
                        rc = self.result(False, 'casper: the installed system boots into casper (the live-session scripts in the initramfs) '
                                         'and keeps looking for a live medium (/dev/sr0: No medium found, %d times)' % casper_loops,
                                         {'FAIL_KIND': 'casper'})
                        break
                    if 'CI-PROBE-FAIL' in self.text:
                        self.screenshot('-fail')
                        self.report()
                        m = re.search(r'CI-PROBE-FAIL (.*)', self.text)
                        rc = self.result(False, 'booted to systemd but no greeter: %s' % (m.group(1).strip() if m else ''),
                                         {'FAIL_KIND': 'no-greeter'})
                        break
                if self.el() - last_shot >= self.a.shot_interval:
                    last_shot = self.el()
                    self.screenshot('')
                if probe_ok_at is None and 'CI-PROBE-OK' in self.text:
                    probe_ok_at = self.el()
                    self.tline('probe: GDM greeter up', re.search(r'CI-PROBE-OK (.*)', self.text).group(1).strip()[:120])
                if probe_ok_at is not None:
                    st = self.screenshot('-greeter')
                    if st is not None and qmplib.is_rich(st):
                        self.tline('screen shows a drawn picture', 'colours=%d nonblack=%s' % (st['colours'], st['nonblack']))
                        time.sleep(3)
                        self.read_serial()
                        self.report()
                        self.screenshot('-final')
                        os.replace(self.shots_last(), os.path.join(self.a.shots, 'final.png'))
                        m = re.search(r'CI-PROBE-OK (.*)', self.text)
                        rc = self.result(True, 'the GDM greeter is up (%s) and the screen shows it' % (m.group(1).strip() if m else ''),
                                         {'GREETER_AT_SECONDS': '%.0f' % probe_ok_at})
                        break
                    if self.el() - probe_ok_at > self.a.grace:
                        self.report()
                        rc = self.result(False, 'the probe saw the GDM greeter but the display shows no drawn picture %ds later (stuck frame?)'
                                         % self.a.grace, {'FAIL_KIND': 'blank-screen'})
                        break
                if self.el() > self.a.timeout:
                    self.screenshot('-timeout')
                    self.report()
                    tail = [l for l in self.text.splitlines() if l.strip()][-3:]
                    seen = 'no serial output at all (the firmware, GRUB or the kernel never started?)' if not self.text.strip() else \
                        'last serial lines: ' + ' | '.join(t.strip()[:100] for t in tail)
                    rc = self.result(False, 'timeout: no greeter within %ds; %s' % (self.a.timeout, seen), {'FAIL_KIND': 'timeout'})
                    break
        finally:
            if rc is not None and not os.path.exists(os.path.join(self.a.shots, 'final.png')) and self.shots:
                try:
                    with open(os.path.join(self.a.shots, 'final.png'), 'wb') as dst, open(self.shots[-1], 'rb') as src:
                        dst.write(src.read())
                except OSError:
                    pass
            self.stop_qemu()
            self.tl.close()
        return rc if rc is not None else 1

    def shots_last(self):
        return self.shots[-1]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--serial', required=True)
    ap.add_argument('--qmp', required=True)
    ap.add_argument('--shots', required=True)
    ap.add_argument('--result', required=True)
    ap.add_argument('--timeline', required=True)
    ap.add_argument('--timeout', type=int, default=1800)
    ap.add_argument('--grace', type=int, default=120)
    ap.add_argument('--shot-interval', type=int, default=30)
    ap.add_argument('--poll', type=float, default=2.0, help='seconds between looks at the serial console')
    ap.add_argument('qemu', nargs=argparse.REMAINDER)
    a = ap.parse_args()
    argv = a.qemu[1:] if a.qemu and a.qemu[0] == '--' else a.qemu
    if not argv:
        ap.error('no QEMU command given after --')
    return Watch(a, argv).run()


if __name__ == '__main__':
    sys.exit(main())
