#!/usr/bin/env python3
"""List the GRUB modules built into a signed GRUB EFI image, or check that some are.

    grub-builtin-modules.py IMAGE                    one module name per line
    grub-builtin-modules.py IMAGE --require a,b,c    exit 1 if any of them is not built in

Why: under Secure Boot, shim's lock refuses every module GRUB would load from disk, so the
stick's grub.cfg can only use what Canonical compiled into `grubx64.efi` itself. That set
changes between Ubuntu releases (grubx64.efi.signed of grub-efi-amd64-signed
1.202.5+2.12-1ubuntu7.3, the previous LTS, has `all_video`, `efi_uga`, `ntfs`, `pgp`,
`video_bochs` and `video_cirrus`; 26.04's 1.215+2.14-2ubuntu1 has none of them), and a string
search of the image is not a reliable way to tell: it finds `feature_all_video_module`, a
feature flag, which is not a module. This reads the module list the way GRUB does.

Layout (grub-mkimage, util/mkimage.c): the PE section named `mods` starts with a
`grub_module_info64 { u32 magic = "mimg"; u32 pad; u64 offset; u64 size }`, then, at
`offset`, a sequence of `{ u32 type; u32 size }` headers (size includes the 8 header bytes)
each followed by its payload. Type 0 is a relocatable ELF module whose `.modname` section
holds its name; 1 memdisk, 2 config, 3 prefix, 4 pubkey, ... are not modules.

Standard library only; no signature is checked here (fetch-signed-boot.sh does that).
"""
import struct
import sys

MODS_MAGIC = 0x676D696D  # "mimg"
OBJ_TYPE_ELF = 0


def fail(msg):
    print(f"grub-builtin-modules.py: {msg}", file=sys.stderr)
    sys.exit(2)


def pe_section(data, wanted):
    """(offset, size) in the file of the PE section called `wanted`."""
    if len(data) < 0x40 or data[:2] != b"MZ":
        fail("not a PE/EFI image")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        fail("not a PE/EFI image (no PE signature)")
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    optsz = struct.unpack_from("<H", data, pe + 20)[0]
    table = pe + 24 + optsz
    for i in range(nsec):
        o = table + 40 * i
        name = data[o:o + 8].rstrip(b"\0").decode("latin1")
        vsize, _vaddr, rsize, roff = struct.unpack_from("<IIII", data, o + 8)
        if name == wanted:
            return roff, min(rsize, vsize) if vsize else rsize
    fail(f"no `{wanted}` section: not a GRUB image built by grub-mkimage")


def elf_modname(blob):
    """The module name stored in an ELF64 relocatable module's `.modname` section."""
    if blob[:4] != b"\x7fELF" or blob[4] != 2:
        fail("a module in the image is not a 64-bit ELF object")
    shoff = struct.unpack_from("<Q", blob, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", blob, 0x3A)
    sections = []
    for i in range(shnum):
        name, _typ, _flags, _addr, off, size = struct.unpack_from(
            "<IIQQQQ", blob, shoff + i * shentsize)
        sections.append((name, off, size))
    strtab = sections[shstrndx][1]
    for name, off, size in sections:
        start = strtab + name
        if blob[start:blob.index(b"\0", start)] == b".modname":
            return blob[off:off + size].rstrip(b"\0").decode()
    fail("a module in the image has no .modname section")


def builtin_modules(path):
    with open(path, "rb") as f:
        data = f.read()
    off, size = pe_section(data, "mods")
    mods = data[off:off + size]
    if len(mods) < 24:
        fail("`mods` section is too small")
    magic, _pad, first, total = struct.unpack_from("<IIQQ", mods, 0)
    if magic != MODS_MAGIC:
        fail("`mods` section does not start with the GRUB module-info header")
    mods = mods[:total]
    names = []
    pos = first
    while pos + 8 <= len(mods):
        typ, length = struct.unpack_from("<II", mods, pos)
        if length < 8 or pos + length > len(mods):
            fail("corrupt module header in the `mods` section")
        if typ == OBJ_TYPE_ELF:
            names.append(elf_modname(mods[pos + 8:pos + length]))
        pos += length
    if not names:
        fail("the image has no built-in modules")
    return sorted(names)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip().split("\n\n")[0])
        return 0 if len(argv) >= 2 else 2
    names = builtin_modules(argv[1])
    if len(argv) >= 4 and argv[2] == "--require":
        required = [m for m in argv[3].replace(" ", ",").split(",") if m]
        if not required:
            fail("--require needs at least one module name")
        missing = [m for m in required if m not in names]
        if missing:
            print("not built into " + argv[1] + ": " + " ".join(missing), file=sys.stderr)
            return 1
        print(f"all {len(required)} required modules are built in ({len(names)} in total)")
        return 0
    if len(argv) != 2:
        fail("usage: grub-builtin-modules.py IMAGE [--require a,b,c]")
    print("\n".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
