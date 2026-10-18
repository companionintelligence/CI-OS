#!/usr/bin/env python3
"""Write a synthetic GRUB EFI image whose built-in modules are the names given.

    make-grub-image.py OUT.efi MODULE [MODULE ...]

A test fixture for verify-iso.sh's check that every `insmod` of the live menu is compiled into the signed GRUB (the real image is a
2.4 MB Canonical binary and is not committed). The layout is the one grub-mkimage writes and stick/scripts/grub-builtin-modules.py
reads: a PE file whose `mods` section starts with a grub_module_info64 header, then {type, size}-prefixed entries; a module (type 0) is
a relocatable ELF64 object whose `.modname` section holds its name. Same bytes as the builder in
stick/crates/ci-stick/tests/grub_modules_tool.rs.
"""
import struct
import sys


def elf_module(name):
    modname = name.encode() + b"\0"
    shstrtab = b"\0.modname\0.shstrtab\0"
    b = bytearray(64)
    modname_off = len(b)
    b += modname
    shstr_off = len(b)
    b += shstrtab
    while len(b) % 8:
        b.append(0)
    shoff = len(b)

    def sh(nm, typ, off, size):
        return struct.pack("<IIQQQQIIQQ", nm, typ, 0, 0, off, size, 0, 0, 1, 0)

    b += sh(0, 0, 0, 0)
    b += sh(1, 1, modname_off, len(modname))
    b += sh(10, 3, shstr_off, len(shstrtab))
    b[0:4] = b"\x7fELF"
    b[4] = 2  # 64-bit
    b[5] = 1  # little endian
    b[6] = 1
    b[0x10:0x12] = struct.pack("<H", 1)  # ET_REL
    b[0x28:0x30] = struct.pack("<Q", shoff)
    b[0x3A:0x3C] = struct.pack("<H", 64)  # shentsize
    b[0x3C:0x3E] = struct.pack("<H", 3)  # shnum
    b[0x3E:0x40] = struct.pack("<H", 2)  # shstrndx
    return bytes(b)


def grub_image(names):
    body = b""
    for n in names:
        payload = elf_module(n)
        body += struct.pack("<II", 0, 8 + len(payload)) + payload
    mods = struct.pack("<IIQQ", 0x676D696D, 0, 24, 24 + len(body)) + body
    f = bytearray(0x40)
    f[0:2] = b"MZ"
    f[0x3C:0x40] = struct.pack("<I", 0x40)
    f += b"PE\0\0"
    f += struct.pack("<H", 0x8664)  # machine
    f += struct.pack("<H", 1)  # sections
    f += b"\0" * 12  # timestamp, symbol table, symbol count
    f += struct.pack("<H", 0)  # optional header size
    f += struct.pack("<H", 0)  # characteristics
    data_off = len(f) + 40
    f += b"mods".ljust(8, b"\0")
    f += struct.pack("<IIII", len(mods), 0x1000, len(mods), data_off)
    f += b"\0" * 16
    f += mods
    return bytes(f)


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().split("\n\n")[0], file=sys.stderr)
        return 2
    with open(argv[1], "wb") as out:
        out.write(grub_image(argv[2:]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
