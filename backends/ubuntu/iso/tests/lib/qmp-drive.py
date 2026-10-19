#!/usr/bin/env python3
"""Tiny QMP client for driving a QEMU guest from the shell: screenshots, keys, typing, the mouse. Standard library only.

  qmp-drive.py SOCK shot FILE.png            screendump as PNG
  qmp-drive.py SOCK key ret [tab ...]        press and release keys by QEMU qcode (ctrl-alt-t as 'ctrl+alt+t')
  qmp-drive.py SOCK type "some text"         type ASCII text (QMP_TYPE_DELAY seconds per key, default 0.06; QMP_HOLD key hold time)
  qmp-drive.py SOCK click X Y [WxH]          move the (absolute) pointer to pixel X,Y of a WxH screen (default 1024x768) and click
  qmp-drive.py SOCK dclick X Y [WxH]         double click
  qmp-drive.py SOCK rclick X Y [WxH]         right click
  qmp-drive.py SOCK move X Y [WxH]           move only
  qmp-drive.py SOCK scroll N                 N wheel notches (negative = down)
  qmp-drive.py SOCK status                   run state
  qmp-drive.py SOCK quit                     power the VM off immediately
Needs the VM to be started with -qmp unix:SOCK,server=on,wait=off and, for the mouse, -device usb-tablet.

The interactive counterpart of lib/qmp.py (which only takes pictures and statistics for installed-boot.sh). Used for the screenshot
runs of the Ubuntu images (docs/guides/testing-in-qemu.md). Under load a key can be dropped or a modifier stick: raise QMP_HOLD
to 0.1 to 0.15, and tap `shift shift_r ctrl alt` once to release everything.

(c) Companion Intelligence - Lifescope Inc
"""
import json, socket, struct, sys, time, zlib

SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8',
           '(': '9', ')': '0', '_': 'minus', '+': 'equal', '{': 'bracket_left', '}': 'bracket_right',
           '|': 'backslash', ':': 'semicolon', '"': 'apostrophe', '<': 'comma', '>': 'dot', '?': 'slash', '~': 'grave_accent'}
PLAIN = {' ': 'spc', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right', '\\': 'backslash',
         ';': 'semicolon', "'": 'apostrophe', ',': 'comma', '.': 'dot', '/': 'slash', '`': 'grave_accent',
         '\n': 'ret', '\t': 'tab'}


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.f = self.s.makefile('rw')
        self.f.readline()
        self.call('qmp_capabilities')

    def call(self, cmd, **args):
        self.f.write(json.dumps({'execute': cmd, 'arguments': args} if args else {'execute': cmd}) + '\n')
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit('qmp: connection closed')
            msg = json.loads(line)
            if 'return' in msg:
                return msg['return']
            if 'error' in msg:
                raise SystemExit('qmp error: %s' % msg['error'])

    def key(self, spec, hold=float(__import__('os').environ.get('QMP_HOLD', '0.05'))):
        keys = [{'type': 'qcode', 'data': k} for k in spec.split('+')]
        self.call('send-key', keys=keys, **{'hold-time': int(hold * 1000)})

    def abs_move(self, x, y, w, h):
        ax, ay = int(x * 32767 / w), int(y * 32767 / h)
        self.call('input-send-event', events=[
            {'type': 'abs', 'data': {'axis': 'x', 'value': ax}},
            {'type': 'abs', 'data': {'axis': 'y', 'value': ay}}])

    def button(self, down):
        self.call('input-send-event', events=[{'type': 'btn', 'data': {'button': 'left', 'down': down}}])


def png_size(path):
    with open(path, 'rb') as fh:
        head = fh.read(24)
    return struct.unpack('>II', head[16:24])


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    sock, cmd, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
    q = Qmp(sock)
    if cmd == 'shot':
        q.call('screendump', filename=rest[0], format='png')
        print('%s %dx%d' % ((rest[0],) + png_size(rest[0])))
    elif cmd == 'key':
        for k in rest:
            q.key(k)
            time.sleep(0.15)
    elif cmd == 'type':
        for ch in ' '.join(rest):
            if ch.isupper():
                q.key('shift+' + ch.lower())
            elif ch in SHIFTED:
                q.key('shift+' + SHIFTED[ch])
            elif ch in PLAIN:
                q.key(PLAIN[ch])
            else:
                q.key(ch)
            time.sleep(float(__import__('os').environ.get('QMP_TYPE_DELAY', '0.06')))
    elif cmd in ('click', 'move'):
        x, y = int(rest[0]), int(rest[1])
        w, h = (int(v) for v in (rest[2] if len(rest) > 2 else '1024x768').split('x'))
        q.abs_move(x, y, w, h)
        if cmd == 'click':
            time.sleep(0.2)
            q.button(True)
            time.sleep(0.1)
            q.button(False)
    elif cmd == 'dclick':
        x, y = int(rest[0]), int(rest[1])
        w, h = (int(v) for v in (rest[2] if len(rest) > 2 else '1024x768').split('x'))
        q.abs_move(x, y, w, h)
        time.sleep(0.2)
        for _ in range(2):
            q.button(True); time.sleep(0.06); q.button(False); time.sleep(0.08)
    elif cmd == 'rclick':
        x, y = int(rest[0]), int(rest[1])
        w, h = (int(v) for v in (rest[2] if len(rest) > 2 else '1024x768').split('x'))
        q.abs_move(x, y, w, h)
        time.sleep(0.2)
        q.call('input-send-event', events=[{'type': 'btn', 'data': {'button': 'right', 'down': True}}])
        time.sleep(0.1)
        q.call('input-send-event', events=[{'type': 'btn', 'data': {'button': 'right', 'down': False}}])
    elif cmd == 'scroll':
        # scroll N  (positive = wheel up, negative = wheel down)
        n = int(rest[0])
        btn = 'wheel-up' if n > 0 else 'wheel-down'
        for _ in range(abs(n)):
            q.call('input-send-event', events=[{'type': 'btn', 'data': {'button': btn, 'down': True}}])
            q.call('input-send-event', events=[{'type': 'btn', 'data': {'button': btn, 'down': False}}])
            time.sleep(0.1)
    elif cmd == 'status':
        print(json.dumps(q.call('query-status')))
    elif cmd == 'quit':
        q.call('quit')
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
