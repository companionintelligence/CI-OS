#!/usr/bin/env python3
"""Minimal QMP client for tests/installed-boot.sh: screenshots as PNG and a few statistics about the picture. Standard library only.

  qmp.py SOCK shot FILE.png     screendump, converted to PNG; prints the picture statistics
  qmp.py SOCK status            the run state of the VM
  qmp.py SOCK quit              power the VM off at once
  qmp.py --stats FILE.png       statistics of an existing PNG (written by this tool: 8-bit RGB, filter type 0)

A QMP socket path on macOS is limited to 104 bytes, so the caller keeps it in a short temporary directory.

(c) Companion Intelligence - Lifescope Inc
"""
import json
import os
import socket
import struct
import sys
import time
import zlib


class Qmp(object):
    def __init__(self, path, timeout=30.0):
        deadline = time.time() + timeout
        last = None
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX)
                self.sock.settimeout(60)
                self.sock.connect(path)
                break
            except OSError as ex:
                last = ex
                self.sock.close()
                if time.time() > deadline:
                    raise RuntimeError('cannot connect to the QMP socket %s: %s' % (path, last))
                time.sleep(0.5)
        self.f = self.sock.makefile('rw')
        self.f.readline()   # greeting
        self.call('qmp_capabilities')

    def call(self, cmd, **args):
        self.f.write(json.dumps({'execute': cmd, 'arguments': args} if args else {'execute': cmd}) + '\n')
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise RuntimeError('QMP connection closed')
            msg = json.loads(line)
            if 'return' in msg:
                return msg['return']
            if 'error' in msg:
                raise RuntimeError('QMP %s: %s' % (cmd, msg['error'].get('desc', msg['error'])))

    def close(self):
        try:
            self.f.close()
            self.sock.close()
        except Exception:
            pass

    def screendump_ppm(self, tmp):
        self.call('screendump', filename=tmp, format='ppm')
        with open(tmp, 'rb') as fh:
            data = fh.read()
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return data


def parse_ppm(data):
    """(width, height, rgb bytes) of a binary P6 PPM."""
    if data[:2] != b'P6':
        raise ValueError('not a P6 PPM')
    pos, fields = 2, []
    while len(fields) < 3:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b'#':
            while data[pos:pos + 1] != b'\n':
                pos += 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(int(data[pos:end]))
        pos = end
    pos += 1   # the single whitespace after maxval
    w, h, _maxval = fields
    return w, h, data[pos:pos + w * h * 3]


def png_bytes(w, h, rgb):
    def chunk(tag, body):
        c = struct.pack('>I', len(body)) + tag + body
        return c + struct.pack('>I', zlib.crc32(tag + body) & 0xffffffff)
    stride = w * 3
    raw = b''.join(b'\x00' + rgb[y * stride:(y + 1) * stride] for y in range(h))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def stats(w, h, rgb):
    """Distinct colours and the share of non-black pixels, on every second pixel of every second row (fast enough in pure Python)."""
    stride = w * 3
    colours = set()
    seen = nonblack = 0
    for y in range(0, h, 2):
        row = rgb[y * stride:(y + 1) * stride]
        for x in range(0, w * 3 - 2, 6):
            px = row[x:x + 3]
            colours.add(px)
            seen += 1
            if px[0] > 16 or px[1] > 16 or px[2] > 16:
                nonblack += 1
    return {'width': w, 'height': h, 'colours': len(colours), 'nonblack': round(nonblack / float(seen or 1), 3)}


def is_rich(st):
    """The display shows a drawn picture (a login screen), not a black screen or a handful of text colours."""
    return st['colours'] >= 64 and st['nonblack'] > 0.2


def shot(qmp, png_path, tmp):
    w, h, rgb = parse_ppm(qmp.screendump_ppm(tmp))
    with open(png_path, 'wb') as fh:
        fh.write(png_bytes(w, h, rgb))
    return stats(w, h, rgb)


def stats_of_png(path):
    with open(path, 'rb') as fh:
        data = fh.read()
    pos, w, h, idat = 8, 0, 0, b''
    while pos < len(data):
        n, tag = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if tag == b'IHDR':
            w, h = struct.unpack('>II', body[:8])
        elif tag == b'IDAT':
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * 3
    rgb = b''.join(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)] for y in range(h))
    return stats(w, h, rgb)


def main(argv):
    if len(argv) == 3 and argv[1] == '--stats':
        print(json.dumps(stats_of_png(argv[2])))
        return 0
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    q = Qmp(argv[1])
    try:
        if argv[2] == 'shot' and len(argv) == 4:
            print(json.dumps(shot(q, argv[3], argv[3] + '.ppm')))
        elif argv[2] == 'status':
            print(q.call('query-status')['status'])
        elif argv[2] == 'quit':
            q.call('quit')
        else:
            sys.stderr.write(__doc__)
            return 2
    finally:
        q.close()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
