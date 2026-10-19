#!/usr/bin/env python3
"""A stand-in for QEMU, for lib/selftest.sh: speaks just enough QMP (qmp_capabilities, screendump, query-status, quit) and writes
what a booting guest would write on the serial console, so boot-watch.py's decisions can be tested in seconds.

  fake-qemu.py --serial FILE --qmp SOCK --scenario NAME

Scenarios: casper (the live-medium message), casperloop (only the repeated /dev/sr0 line), pass (probe OK + a drawn screen),
blank (probe OK + a black screen), nogreeter (the probe says FAIL), exit (the process dies), silent (nothing at all),
efishell (the firmware finds nothing to boot and starts its EFI shell).

(c) Companion Intelligence - Lifescope Inc
"""
import json
import os
import socket
import sys
import threading
import time

a = dict(zip(sys.argv[1::2], sys.argv[2::2]))
serial, sock, scenario = a['--serial'], a['--qmp'], a['--scenario']
rich = scenario == 'pass'


def w(text):
    with open(serial, 'a') as f:
        f.write(text)


def guest():
    time.sleep(1)
    if scenario == 'silent':
        time.sleep(600)
    w('BdsDxe: loading Boot0003 "Companion OS"\r\nBdsDxe: starting Boot0003 "Companion OS"\r\n')
    time.sleep(2)
    if scenario == 'casper':
        w("/init: line 38: can't open /dev/sr0: No medium found\n" * 3)
        time.sleep(1)
        w('Unable to find a medium containing a live file system\nAttempt interactive netboot from a URL?\n')
    elif scenario == 'casperloop':
        for _ in range(8):
            w("/init: line 38: can't open /dev/sr0: No medium found\nstdin: Invalid argument\n")
            time.sleep(0.5)
    elif scenario in ('pass', 'blank'):
        w('[  OK  ] Started GNOME Display Manager.\nCI-PROBE: begin\nCI-PROBE: cmdline=x\n')
        time.sleep(2)
        w('CI-PROBE: failed-units=\nCI-PROBE-OK gdm greeter up after 20s (session c1 type=wayland state=active)\nCI-PROBE: end\n')
    elif scenario == 'nogreeter':
        w('CI-PROBE: begin\nCI-PROBE-FAIL the GDM greeter did not come up within 5s (display-manager=failed)\nCI-PROBE: end\n')
    elif scenario == 'efishell':
        w('BdsDxe: loading Boot0002 "EFI Internal Shell" from Fv(7CB8BDC9)\r\nBdsDxe: starting Boot0002 "EFI Internal Shell" from Fv(7CB8BDC9)\r\nShell> \r\n')
    elif scenario == 'exit':
        os._exit(3)
    time.sleep(600)


def picture(path):
    w_, h_ = 320, 200
    px = bytearray()
    for y in range(h_):
        for x in range(w_):
            px += bytes([(x * 3) % 256, (y * 5) % 256, (x + y) % 256]) if rich else b'\x00\x00\x00'
    with open(path, 'wb') as f:
        f.write(b'P6\n%d %d\n255\n' % (w_, h_) + bytes(px))


threading.Thread(target=guest, daemon=True).start()
try:
    os.unlink(sock)
except OSError:
    pass
srv = socket.socket(socket.AF_UNIX)
srv.bind(sock)
srv.listen(1)
while True:
    conn, _ = srv.accept()
    f = conn.makefile('rw')
    f.write(json.dumps({'QMP': {}}) + '\n')
    f.flush()
    for line in f:
        msg = json.loads(line)
        cmd = msg['execute']
        if cmd == 'screendump':
            picture(msg['arguments']['filename'])
        if cmd == 'quit':
            f.write(json.dumps({'return': {}}) + '\n')
            f.flush()
            os._exit(0)
        f.write(json.dumps({'return': {'status': 'running'} if cmd == 'query-status' else {}}) + '\n')
        f.flush()
