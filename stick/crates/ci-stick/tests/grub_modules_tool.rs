//! `scripts/grub-builtin-modules.py` against synthetic GRUB EFI images.
//!
//! The real signed images are 2.8 MB Canonical binaries and are not committed; their module
//! lists are (`tests/fixtures/grub/`, checked in `bootcfg.rs`). Here the tool is exercised on
//! images built byte by byte the way `grub-mkimage` lays them out: a PE file whose `mods`
//! section starts with a `grub_module_info64` header and holds `{type, size}`-prefixed
//! entries, the ELF ones carrying their name in `.modname`. Skipped (loudly) without python3.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn script() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/grub-builtin-modules.py")
}

fn python3() -> Option<&'static str> {
    Command::new("python3")
        .arg("-c")
        .arg("pass")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|_| "python3")
}

fn le32(v: u32) -> [u8; 4] {
    v.to_le_bytes()
}
fn le64(v: u64) -> [u8; 8] {
    v.to_le_bytes()
}

/// A relocatable ELF64 object with just `.modname` (and the section-name table).
fn elf_module(name: &str) -> Vec<u8> {
    let mut modname = name.as_bytes().to_vec();
    modname.push(0);
    let shstrtab = b"\0.modname\0.shstrtab\0".to_vec();
    let (name_modname, name_shstrtab) = (1u32, 10u32);

    let mut b = vec![0u8; 64]; // ELF header, patched below
    let modname_off = b.len() as u64;
    b.extend_from_slice(&modname);
    let shstr_off = b.len() as u64;
    b.extend_from_slice(&shstrtab);
    while b.len() % 8 != 0 {
        b.push(0);
    }
    let shoff = b.len() as u64;
    let sh = |name: u32, typ: u32, off: u64, size: u64| {
        let mut e = Vec::new();
        e.extend_from_slice(&le32(name));
        e.extend_from_slice(&le32(typ));
        e.extend_from_slice(&le64(0)); // flags
        e.extend_from_slice(&le64(0)); // addr
        e.extend_from_slice(&le64(off));
        e.extend_from_slice(&le64(size));
        e.extend_from_slice(&le32(0)); // link
        e.extend_from_slice(&le32(0)); // info
        e.extend_from_slice(&le64(1)); // addralign
        e.extend_from_slice(&le64(0)); // entsize
        assert_eq!(e.len(), 64);
        e
    };
    b.extend(sh(0, 0, 0, 0));
    b.extend(sh(name_modname, 1, modname_off, modname.len() as u64));
    b.extend(sh(name_shstrtab, 3, shstr_off, shstrtab.len() as u64));

    b[..4].copy_from_slice(b"\x7fELF");
    b[4] = 2; // 64-bit
    b[5] = 1; // little endian
    b[6] = 1;
    b[0x10..0x12].copy_from_slice(&1u16.to_le_bytes()); // ET_REL
    b[0x28..0x30].copy_from_slice(&le64(shoff));
    b[0x3A..0x3C].copy_from_slice(&64u16.to_le_bytes()); // shentsize
    b[0x3C..0x3E].copy_from_slice(&3u16.to_le_bytes()); // shnum
    b[0x3E..0x40].copy_from_slice(&2u16.to_le_bytes()); // shstrndx
    b
}

enum Entry<'a> {
    Module(&'a str),
    /// A non-module entry: type 1 memdisk, 2 config, 3 prefix, ... with any payload.
    Other(u32, &'a [u8]),
}

/// A PE32+ file with one section called `section_name`, holding the module blob.
fn grub_image(section_name: &str, entries: &[Entry]) -> Vec<u8> {
    let mut body = Vec::new();
    for e in entries {
        let (typ, payload) = match e {
            Entry::Module(n) => (0u32, elf_module(n)),
            Entry::Other(t, p) => (*t, p.to_vec()),
        };
        body.extend_from_slice(&le32(typ));
        body.extend_from_slice(&le32(8 + payload.len() as u32));
        body.extend_from_slice(&payload);
    }
    let mut mods = Vec::new();
    mods.extend_from_slice(&le32(0x676d_696d)); // "mimg"
    mods.extend_from_slice(&le32(0));
    mods.extend_from_slice(&le64(24)); // offset of the first entry
    mods.extend_from_slice(&le64(24 + body.len() as u64)); // size of the lot
    mods.extend_from_slice(&body);

    let mut f = vec![0u8; 0x40];
    f[..2].copy_from_slice(b"MZ");
    f[0x3C..0x40].copy_from_slice(&le32(0x40));
    f.extend_from_slice(b"PE\0\0");
    f.extend_from_slice(&0x8664u16.to_le_bytes()); // machine
    f.extend_from_slice(&1u16.to_le_bytes()); // sections
    f.extend_from_slice(&[0u8; 12]); // timestamp, symbol table, symbol count
    f.extend_from_slice(&0u16.to_le_bytes()); // optional header size
    f.extend_from_slice(&0u16.to_le_bytes()); // characteristics
    let mut name = [0u8; 8];
    name[..section_name.len()].copy_from_slice(section_name.as_bytes());
    let data_off = (f.len() + 40) as u32;
    f.extend_from_slice(&name);
    f.extend_from_slice(&le32(mods.len() as u32)); // virtual size
    f.extend_from_slice(&le32(0x1000)); // virtual address
    f.extend_from_slice(&le32(mods.len() as u32)); // raw size
    f.extend_from_slice(&le32(data_off)); // raw offset
    f.extend_from_slice(&[0u8; 16]);
    f.extend_from_slice(&mods);
    f
}

fn run(image: &[u8], extra: &[&str]) -> Option<Output> {
    let py = python3().or_else(|| {
        eprintln!("SKIPPED: python3 not found");
        None
    })?;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("grubx64.efi");
    std::fs::write(&path, image).unwrap();
    Some(
        Command::new(py)
            .arg("-I")
            .arg(script())
            .arg(&path)
            .args(extra)
            .output()
            .unwrap(),
    )
}

fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

#[test]
fn lists_the_elf_modules_sorted_and_ignores_memdisk_config_and_prefix() {
    let img = grub_image(
        "mods",
        &[
            Entry::Module("normal"),
            Entry::Other(1, b"a memdisk would be large"),
            Entry::Module("configfile"),
            Entry::Other(2, b"set root=x"),
            Entry::Other(3, b"/EFI/ubuntu"),
            Entry::Module("part_gpt"),
        ],
    );
    let Some(o) = run(&img, &[]) else { return };
    assert!(o.status.success(), "{}", text(&o.stderr));
    assert_eq!(text(&o.stdout), "configfile\nnormal\npart_gpt\n");
}

#[test]
fn require_passes_when_every_module_is_built_in() {
    let img = grub_image(
        "mods",
        &[
            Entry::Module("linux"),
            Entry::Module("loadenv"),
            Entry::Module("echo"),
        ],
    );
    let Some(o) = run(&img, &["--require", "linux,echo"]) else {
        return;
    };
    assert_eq!(o.status.code(), Some(0), "{}", text(&o.stderr));
    assert!(text(&o.stdout).contains("all 2 required modules are built in (3 in total)"));
}

#[test]
fn require_fails_and_names_every_missing_module() {
    let img = grub_image("mods", &[Entry::Module("linux"), Entry::Module("echo")]);
    let Some(o) = run(&img, &["--require", "linux,all_video,gfxterm"]) else {
        return;
    };
    assert_eq!(o.status.code(), Some(1));
    let err = text(&o.stderr);
    assert!(
        err.contains("all_video gfxterm") && !err.contains(" linux"),
        "{err}"
    );
}

#[test]
fn a_feature_flag_string_is_not_a_module() {
    // The signed 26.04 image contains the text `feature_all_video_module` and no all_video
    // module; a string search would call it present.
    let img = grub_image(
        "mods",
        &[
            Entry::Module("video"),
            Entry::Other(1, b"feature_all_video_module"),
        ],
    );
    let Some(o) = run(&img, &["--require", "all_video"]) else {
        return;
    };
    assert_eq!(o.status.code(), Some(1), "{}", text(&o.stderr));
}

#[test]
fn anything_that_is_not_a_grub_image_is_refused_with_exit_2() {
    let Some(o) = run(
        b"just some text, not a PE file at all, long enough to look",
        &[],
    ) else {
        return;
    };
    assert_eq!(o.status.code(), Some(2));
    assert!(text(&o.stderr).contains("not a PE/EFI image"));

    // A PE file with another section name (shim, a kernel): no `mods`.
    let shim_like = grub_image("text", &[Entry::Module("normal")]);
    let o = run(&shim_like, &[]).unwrap();
    assert_eq!(o.status.code(), Some(2));
    assert!(text(&o.stderr).contains("no `mods` section"));

    // A `mods` section that does not start with the module-info header.
    let mut broken = grub_image("mods", &[Entry::Module("normal")]);
    let at = broken.windows(4).position(|w| w == b"mimg").unwrap();
    broken[at] = b'X';
    let o = run(&broken, &[]).unwrap();
    assert_eq!(o.status.code(), Some(2));
    assert!(text(&o.stderr).contains("module-info header"));
}
