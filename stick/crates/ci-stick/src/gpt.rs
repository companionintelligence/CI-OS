//! GPT: the `sgdisk` invocation that writes a layout plan, and a small read-only parser
//! used to verify the result and to find partitions on an existing stick.
//!
//! Writing goes through `sgdisk` (gdisk package) so the on-disk structures come from a
//! well-tested implementation. Reading is done here, in Rust, so `flash` can check that
//! what landed on the target is exactly the plan (start, end, type GUID and name for
//! every entry, plus both CRCs) and `slot` can locate the ESP without trusting labels
//! alone.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

use anyhow::{bail, ensure, Context as _};

use crate::layout::LayoutPlan;

/// `sgdisk` arguments that create `plan` on a target with `sector_size`-byte sectors.
///
/// The table is cleared first (`--clear`), then every partition is created with its exact
/// first and last sector, its type GUID and its GPT name (the layout label).
pub fn sgdisk_args(plan: &LayoutPlan, sector_size: u64) -> anyhow::Result<Vec<String>> {
    ensure!(
        sector_size == 512 || sector_size == 4096,
        "unsupported logical sector size {sector_size}"
    );
    let mut args = vec!["--clear".to_string()];
    for p in &plan.partitions {
        ensure!(
            p.start_bytes % sector_size == 0 && p.size_bytes % sector_size == 0,
            "{} is not aligned to {sector_size}-byte sectors",
            p.label
        );
        let first = p.start_bytes / sector_size;
        let last = first + p.size_bytes / sector_size - 1;
        args.push(format!("--new={}:{first}:{last}", p.index));
        args.push(format!("--typecode={}:{}", p.index, p.gpt_type));
        args.push(format!("--change-name={}:{}", p.index, p.label));
    }
    Ok(args)
}

/// One parsed GPT entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GptEntry {
    pub index: u32,
    /// Upper-case canonical GUID text.
    pub type_guid: String,
    pub first_lba: u64,
    pub last_lba: u64,
    pub name: String,
}

impl GptEntry {
    pub fn start_bytes(&self, sector: u64) -> u64 {
        self.first_lba * sector
    }
    pub fn size_bytes(&self, sector: u64) -> u64 {
        (self.last_lba + 1 - self.first_lba) * sector
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Gpt {
    pub sector_size: u64,
    pub entries: Vec<GptEntry>,
    /// The raw header sector and entry array (what a read-back compares).
    pub raw: Vec<u8>,
}

impl Gpt {
    pub fn by_name(&self, name: &str) -> Option<&GptEntry> {
        self.entries.iter().find(|e| e.name == name)
    }
}

/// IEEE CRC-32 as used by GPT (and zlib).
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &b in data {
        crc ^= u32::from(b);
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

fn guid_to_string(b: &[u8]) -> String {
    // Mixed-endian: first three fields little-endian, the rest as stored.
    format!(
        "{:08X}-{:04X}-{:04X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        u32::from_le_bytes([b[0], b[1], b[2], b[3]]),
        u16::from_le_bytes([b[4], b[5]]),
        u16::from_le_bytes([b[6], b[7]]),
        b[8],
        b[9],
        b[10],
        b[11],
        b[12],
        b[13],
        b[14],
        b[15]
    )
}

fn le_u32(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

fn le_u64(b: &[u8], at: usize) -> u64 {
    let mut a = [0u8; 8];
    a.copy_from_slice(&b[at..at + 8]);
    u64::from_le_bytes(a)
}

/// Parse a primary GPT header (at LBA 1) and its entry array from `read_at`.
pub fn parse_with(
    sector_size: u64,
    mut read_at: impl FnMut(u64, usize) -> std::io::Result<Vec<u8>>,
) -> anyhow::Result<Gpt> {
    let mut header = read_at(sector_size, sector_size as usize).context("reading GPT header")?;
    ensure!(&header[..8] == b"EFI PART", "no GPT header at LBA 1");
    let header_size = le_u32(&header, 12) as usize;
    ensure!(
        (92..=sector_size as usize).contains(&header_size),
        "GPT header size {header_size} is invalid"
    );
    let stored_crc = le_u32(&header, 16);
    let mut h = header[..header_size].to_vec();
    h[16..20].fill(0);
    ensure!(crc32(&h) == stored_crc, "GPT header CRC mismatch");
    let entries_lba = le_u64(&header, 72);
    let count = le_u32(&header, 80) as usize;
    let entry_size = le_u32(&header, 84) as usize;
    let entries_crc = le_u32(&header, 88);
    ensure!(
        entry_size >= 128 && count <= 1024,
        "GPT entry array geometry is invalid"
    );
    let raw_entries =
        read_at(entries_lba * sector_size, count * entry_size).context("reading GPT entries")?;
    ensure!(
        crc32(&raw_entries) == entries_crc,
        "GPT entry array CRC mismatch"
    );

    let mut entries = Vec::new();
    for i in 0..count {
        let e = &raw_entries[i * entry_size..(i + 1) * entry_size];
        if e[..16].iter().all(|&b| b == 0) {
            continue;
        }
        let name_units: Vec<u16> = e[56..128]
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .take_while(|&u| u != 0)
            .collect();
        entries.push(GptEntry {
            index: i as u32 + 1,
            type_guid: guid_to_string(&e[..16]),
            first_lba: le_u64(e, 32),
            last_lba: le_u64(e, 40),
            name: String::from_utf16_lossy(&name_units),
        });
    }
    header.truncate(header_size);
    let mut raw = header;
    raw.extend_from_slice(&raw_entries);
    Ok(Gpt {
        sector_size,
        entries,
        raw,
    })
}

/// Read the primary GPT from an open file or block device. Tries 512- then 4096-byte
/// sectors unless `sector_size` is given.
pub fn read(file: &mut File, sector_size: Option<u64>) -> anyhow::Result<Gpt> {
    let sizes: &[u64] = match sector_size {
        Some(512) => &[512],
        Some(4096) => &[4096],
        Some(other) => bail!("unsupported sector size {other}"),
        None => &[512, 4096],
    };
    let mut last_err = None;
    for &s in sizes {
        let result = parse_with(s, |off, len| {
            let mut buf = vec![0u8; len];
            file.seek(SeekFrom::Start(off))?;
            file.read_exact(&mut buf)?;
            Ok(buf)
        });
        match result {
            Ok(g) => return Ok(g),
            Err(e) => last_err = Some(e),
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow::anyhow!("no GPT found")))
}

/// Check that a parsed GPT is exactly `plan`.
pub fn check_matches_plan(gpt: &Gpt, plan: &LayoutPlan) -> anyhow::Result<()> {
    let s = gpt.sector_size;
    ensure!(
        gpt.entries.len() == plan.partitions.len(),
        "GPT has {} partitions, the plan has {}",
        gpt.entries.len(),
        plan.partitions.len()
    );
    for (e, p) in gpt.entries.iter().zip(&plan.partitions) {
        let ok = e.index == p.index
            && e.start_bytes(s) == p.start_bytes
            && e.size_bytes(s) == p.size_bytes
            && e.type_guid.eq_ignore_ascii_case(&p.gpt_type)
            && e.name == p.label;
        if !ok {
            bail!(
                "GPT entry {} ({} {} @{}+{}) does not match the plan ({} {} @{}+{})",
                e.index,
                e.name,
                e.type_guid,
                e.start_bytes(s),
                e.size_bytes(s),
                p.label,
                p.gpt_type,
                p.start_bytes,
                p.size_bytes
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout;

    #[test]
    fn crc32_known_vector() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(crc32(b""), 0);
    }

    #[test]
    fn sgdisk_args_follow_the_layout() {
        let plan = layout::plan(64_000_000_000).unwrap();
        let args = sgdisk_args(&plan, 512).unwrap();
        assert_eq!(args[0], "--clear");
        assert_eq!(args.len(), 1 + 3 * plan.partitions.len());
        // ESP: starts at 1 MiB (sector 2048), 1 GiB long.
        assert_eq!(args[1], "--new=1:2048:2099199");
        assert_eq!(args[2], "--typecode=1:C12A7328-F81F-11D2-BA4B-00A0C93EC93B");
        assert_eq!(args[3], "--change-name=1:CI-EFI");
        for p in &plan.partitions {
            let first = p.start_bytes / 512;
            let last = first + p.size_bytes / 512 - 1;
            assert!(args.contains(&format!("--new={}:{first}:{last}", p.index)));
            assert!(args.contains(&format!("--change-name={}:{}", p.index, p.label)));
        }
        let names: Vec<&str> = plan.partitions.iter().map(|p| p.label.as_str()).collect();
        assert_eq!(
            names,
            [
                "CI-EFI",
                "CI-SHARED",
                "CI-BOOT-A",
                "CI-BOOT-B",
                "CI-CACHE",
                "CI-PERSIST"
            ]
        );
        // 4K-sector devices get the same byte extents.
        let args4k = sgdisk_args(&plan, 4096).unwrap();
        assert_eq!(args4k[1], "--new=1:256:262399");
        assert!(sgdisk_args(&plan, 1024).is_err());
    }

    /// Build a GPT header + entries in memory, parse it back.
    #[test]
    fn parses_a_synthetic_gpt_and_checks_plan() {
        let plan = layout::plan(64_000_000_000).unwrap();
        let mut entries = vec![0u8; 128 * 128];
        for (i, p) in plan.partitions.iter().enumerate() {
            let e = &mut entries[i * 128..(i + 1) * 128];
            let g = p.gpt_type.replace('-', "");
            let raw = hex::decode(g).unwrap();
            // to mixed-endian
            let mut t = [0u8; 16];
            t[..4].copy_from_slice(&[raw[3], raw[2], raw[1], raw[0]]);
            t[4..6].copy_from_slice(&[raw[5], raw[4]]);
            t[6..8].copy_from_slice(&[raw[7], raw[6]]);
            t[8..].copy_from_slice(&raw[8..]);
            e[..16].copy_from_slice(&t);
            e[16] = 1; // unique GUID, non-zero
            e[32..40].copy_from_slice(&(p.start_bytes / 512).to_le_bytes());
            e[40..48].copy_from_slice(&((p.start_bytes + p.size_bytes) / 512 - 1).to_le_bytes());
            for (j, u) in p.label.encode_utf16().enumerate() {
                e[56 + 2 * j..58 + 2 * j].copy_from_slice(&u.to_le_bytes());
            }
        }
        let mut header = vec![0u8; 512];
        header[..8].copy_from_slice(b"EFI PART");
        header[12..16].copy_from_slice(&92u32.to_le_bytes());
        header[72..80].copy_from_slice(&2u64.to_le_bytes());
        header[80..84].copy_from_slice(&128u32.to_le_bytes());
        header[84..88].copy_from_slice(&128u32.to_le_bytes());
        header[88..92].copy_from_slice(&crc32(&entries).to_le_bytes());
        let crc = crc32(&header[..92]);
        header[16..20].copy_from_slice(&crc.to_le_bytes());
        let mut disk = vec![0u8; 512];
        disk.extend_from_slice(&header);
        disk.extend_from_slice(&entries);
        let reader = |off: u64, len: usize| Ok(disk[off as usize..off as usize + len].to_vec());
        let gpt = parse_with(512, reader).unwrap();
        assert_eq!(gpt.entries.len(), 6);
        assert_eq!(gpt.by_name("CI-EFI").unwrap().first_lba, 2048);
        check_matches_plan(&gpt, &plan).unwrap();
        let other = layout::plan(128_000_000_000).unwrap();
        assert!(check_matches_plan(&gpt, &other).is_err());

        // Corrupt one entry byte: the entry-array CRC must catch it.
        let mut bad = disk.clone();
        bad[1024 + 60] ^= 1;
        let reader = |off: u64, len: usize| Ok(bad[off as usize..off as usize + len].to_vec());
        assert!(parse_with(512, reader).is_err());
    }
}
