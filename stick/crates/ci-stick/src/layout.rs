//! Capacity-aware GPT partition plan for a Companion Stick.
//!
//! This module is pure: it maps a device size in bytes to a [`LayoutPlan`]. It never
//! touches a device. The same plan is recorded in `bundle.json` (`layout`) so a bundle
//! states which geometry it was built for, and `doctor` uses it to say what a detected
//! device would get.
//!
//! Partition order and sizing policy (`ci-stick-layout/1`), all sizes in whole GiB except
//! the final partition, which absorbs the remainder:
//!
//! | # | label        | fs         | sizing                                         |
//! |---|--------------|------------|------------------------------------------------|
//! | 1 | `CI-EFI`     | vfat       | 1 GiB below 150 GiB usable, else 2 GiB         |
//! | 2 | `CI-SHARED`  | exfat      | usable / 16, clamped to 4..=32 GiB             |
//! | 3 | `CI-BOOT-A`  | raw image  | usable / 10, clamped to 8..=48 GiB             |
//! | 4 | `CI-BOOT-B`  | raw image  | same as slot A                                 |
//! | 5 | `CI-CACHE`   | exfat      | what's left after the persistence target       |
//! | 6 | `CI-PERSIST` | ext4       | ~13.5 % of the rest (8..=128 GiB) + remainder  |
//!
//! For a marketed 512 GB stick (≈ 476.8 GiB) that yields ESP 2, shared 29, boot 2 × 47,
//! cache 304 and persistence ≈ 47.8 GiB. See `docs/architecture/companion-stick.md` for
//! the rationale behind each partition.

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::size::{fmt_binary, fmt_decimal, GIB, MIB};

/// Identifies the sizing policy below. Bump it whenever the math changes so bundles
/// built for an older policy are recognisable.
pub const LAYOUT_POLICY: &str = "ci-stick-layout/1";

/// Smallest device we will plan for. A nominal "64 GB" stick reports roughly 57.5–59.6
/// GiB depending on the vendor, so the floor is set just below that.
pub const MIN_DEVICE_BYTES: u64 = 57 * GIB;

/// Reserved at the start of the disk (protective MBR + primary GPT, 1 MiB aligned).
const HEAD_RESERVED_MIB: u64 = 1;
/// Reserved at the end of the disk (backup GPT + alignment slack).
const TAIL_RESERVED_MIB: u64 = 1;
const GIB_IN_MIB: u64 = GIB / MIB;

pub const GPT_TYPE_ESP: &str = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B";
pub const GPT_TYPE_BASIC_DATA: &str = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7";
pub const GPT_TYPE_LINUX_FS: &str = "0FC63DAF-8483-4772-8E79-3D69D8477DE4";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PartitionRole {
    /// EFI system partition: bootloader + A/B slot selector.
    Esp,
    /// Cross-platform launchers, installers and docs, readable on macOS/Windows/Linux.
    Shared,
    /// Immutable boot image, update slot A.
    BootA,
    /// Immutable boot image, update slot B.
    BootB,
    /// Content-addressed OCI image and model blob cache.
    Cache,
    /// Live-session persistence, logs and updater state.
    Persist,
}

impl PartitionRole {
    pub fn purpose(self) -> &'static str {
        match self {
            Self::Esp => "bootloader, A/B slot selector",
            Self::Shared => "launchers, installers, docs (all hosts)",
            Self::BootA => "boot image slot A (immutable)",
            Self::BootB => "boot image slot B (immutable)",
            Self::Cache => "content-addressed OCI + model cache",
            Self::Persist => "live persistence, logs, update state",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Filesystem {
    Vfat,
    Exfat,
    /// The slot holds a whole filesystem image written as-is; no host filesystem driver
    /// is needed to update it.
    RawImage,
    Ext4,
}

impl Filesystem {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Vfat => "vfat",
            Self::Exfat => "exfat",
            Self::RawImage => "raw-image",
            Self::Ext4 => "ext4",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Partition {
    /// 1-based GPT partition number.
    pub index: u32,
    pub label: String,
    pub role: PartitionRole,
    pub filesystem: Filesystem,
    pub gpt_type: String,
    pub start_bytes: u64,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutPlan {
    pub policy: String,
    pub table: String,
    pub device_bytes: u64,
    pub usable_bytes: u64,
    pub partitions: Vec<Partition>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum LayoutError {
    #[error(
        "device is too small: {} ({}) — Companion Stick needs at least {} (a nominal 64 GB stick)",
        fmt_decimal(*.device_bytes),
        fmt_binary(*.device_bytes),
        fmt_binary(MIN_DEVICE_BYTES)
    )]
    TooSmall { device_bytes: u64 },
}

impl LayoutPlan {
    pub fn partition(&self, role: PartitionRole) -> Option<&Partition> {
        self.partitions.iter().find(|p| p.role == role)
    }

    /// Size of the content-addressed cache partition (0 if the plan has none).
    pub fn cache_bytes(&self) -> u64 {
        self.partition(PartitionRole::Cache)
            .map_or(0, |p| p.size_bytes)
    }

    /// One-line summary, e.g. `ESP 2 GiB · shared 29 GiB · boot 2×47 GiB · cache 304 GiB · persist 47.8 GiB`.
    pub fn summary(&self) -> String {
        let size = |r| self.partition(r).map_or(0, |p| p.size_bytes);
        format!(
            "ESP {} · shared {} · boot 2×{} · cache {} · persist {}",
            fmt_binary(size(PartitionRole::Esp)),
            fmt_binary(size(PartitionRole::Shared)),
            fmt_binary(size(PartitionRole::BootA)),
            fmt_binary(size(PartitionRole::Cache)),
            fmt_binary(size(PartitionRole::Persist)),
        )
    }

    /// Internal consistency: contiguous, 1 MiB-aligned, inside the device.
    pub fn check_consistency(&self) -> Result<(), String> {
        let mut cursor = HEAD_RESERVED_MIB * MIB;
        for (i, p) in self.partitions.iter().enumerate() {
            if p.index as usize != i + 1 {
                return Err(format!("partition {} has index {}", i + 1, p.index));
            }
            if p.start_bytes != cursor {
                return Err(format!(
                    "{} does not start where the previous ends",
                    p.label
                ));
            }
            if p.start_bytes % MIB != 0 || p.size_bytes % MIB != 0 || p.size_bytes == 0 {
                return Err(format!(
                    "{} is not a non-empty, 1 MiB-aligned extent",
                    p.label
                ));
            }
            cursor += p.size_bytes;
        }
        if cursor + TAIL_RESERVED_MIB * MIB > self.device_bytes {
            return Err("partitions extend past the backup GPT".into());
        }
        Ok(())
    }
}

fn clamp_gib(value: u64, min: u64, max: u64) -> u64 {
    value.clamp(min, max)
}

/// Compute the partition plan for a device of `device_bytes`.
pub fn plan(device_bytes: u64) -> Result<LayoutPlan, LayoutError> {
    if device_bytes < MIN_DEVICE_BYTES {
        return Err(LayoutError::TooSmall { device_bytes });
    }
    let total_mib = device_bytes / MIB;
    let usable_mib = total_mib - HEAD_RESERVED_MIB - TAIL_RESERVED_MIB;
    let usable_gib = usable_mib / GIB_IN_MIB;

    let esp_gib = if usable_gib < 150 { 1 } else { 2 };
    let shared_gib = clamp_gib(usable_gib / 16, 4, 32);
    let slot_gib = clamp_gib(usable_gib / 10, 8, 48);

    let fixed_mib = (esp_gib + shared_gib + 2 * slot_gib) * GIB_IN_MIB;
    // MIN_DEVICE_BYTES guarantees this cannot underflow; checked_sub keeps it honest.
    let rest_mib = usable_mib
        .checked_sub(fixed_mib)
        .ok_or(LayoutError::TooSmall { device_bytes })?;
    let persist_target_mib = (rest_mib * 27 / 200).clamp(8 * GIB_IN_MIB, 128 * GIB_IN_MIB);
    let cache_mib = rest_mib.saturating_sub(persist_target_mib) / GIB_IN_MIB * GIB_IN_MIB;
    let persist_mib = rest_mib - cache_mib;
    if cache_mib < 16 * GIB_IN_MIB {
        return Err(LayoutError::TooSmall { device_bytes });
    }

    let specs = [
        (
            "CI-EFI",
            PartitionRole::Esp,
            Filesystem::Vfat,
            GPT_TYPE_ESP,
            esp_gib * GIB_IN_MIB,
        ),
        (
            "CI-SHARED",
            PartitionRole::Shared,
            Filesystem::Exfat,
            GPT_TYPE_BASIC_DATA,
            shared_gib * GIB_IN_MIB,
        ),
        (
            "CI-BOOT-A",
            PartitionRole::BootA,
            Filesystem::RawImage,
            GPT_TYPE_LINUX_FS,
            slot_gib * GIB_IN_MIB,
        ),
        (
            "CI-BOOT-B",
            PartitionRole::BootB,
            Filesystem::RawImage,
            GPT_TYPE_LINUX_FS,
            slot_gib * GIB_IN_MIB,
        ),
        (
            "CI-CACHE",
            PartitionRole::Cache,
            Filesystem::Exfat,
            GPT_TYPE_BASIC_DATA,
            cache_mib,
        ),
        (
            "CI-PERSIST",
            PartitionRole::Persist,
            Filesystem::Ext4,
            GPT_TYPE_LINUX_FS,
            persist_mib,
        ),
    ];

    let mut start = HEAD_RESERVED_MIB * MIB;
    let partitions = specs
        .iter()
        .enumerate()
        .map(|(i, &(label, role, filesystem, gpt_type, size_mib))| {
            let p = Partition {
                index: i as u32 + 1,
                label: label.to_string(),
                role,
                filesystem,
                gpt_type: gpt_type.to_string(),
                start_bytes: start,
                size_bytes: size_mib * MIB,
            };
            start += p.size_bytes;
            p
        })
        .collect();

    Ok(LayoutPlan {
        policy: LAYOUT_POLICY.to_string(),
        table: "gpt".to_string(),
        device_bytes,
        usable_bytes: usable_mib * MIB,
        partitions,
    })
}

/// Human-readable table for `layout plan`.
pub fn render_table(plan: &LayoutPlan) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "Device {} ({}), usable {} — GPT, policy {}\n\n",
        fmt_decimal(plan.device_bytes),
        fmt_binary(plan.device_bytes),
        fmt_binary(plan.usable_bytes),
        plan.policy
    ));
    out.push_str(&format!(
        "{:>2}  {:<11} {:<10} {:>10} {:>12}  {}\n",
        "#", "LABEL", "FS", "SIZE", "START (MiB)", "PURPOSE"
    ));
    for p in &plan.partitions {
        out.push_str(&format!(
            "{:>2}  {:<11} {:<10} {:>10} {:>12}  {}\n",
            p.index,
            p.label,
            p.filesystem.as_str(),
            fmt_binary(p.size_bytes),
            p.start_bytes / MIB,
            p.role.purpose()
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::size::parse_size;

    fn gib(p: &LayoutPlan, role: PartitionRole) -> f64 {
        p.partition(role)
            .map_or(0.0, |x| x.size_bytes as f64 / GIB as f64)
    }

    #[test]
    fn marketed_512gb_matches_product_ranges() {
        let p = plan(parse_size("512GB").unwrap()).unwrap();
        p.check_consistency().unwrap();
        let esp = gib(&p, PartitionRole::Esp);
        let shared = gib(&p, PartitionRole::Shared);
        let boot = gib(&p, PartitionRole::BootA) + gib(&p, PartitionRole::BootB);
        let cache = gib(&p, PartitionRole::Cache);
        let persist = gib(&p, PartitionRole::Persist);
        assert!((1.0..=2.0).contains(&esp), "esp {esp}");
        assert!((24.0..=32.0).contains(&shared), "shared {shared}");
        assert!((80.0..=100.0).contains(&boot), "boot {boot}");
        assert!((280.0..=320.0).contains(&cache), "cache {cache}");
        assert!(persist >= 16.0, "persist {persist}");
        assert_eq!(gib(&p, PartitionRole::BootA), gib(&p, PartitionRole::BootB));
        // Exact values are part of the policy; changing them means bumping LAYOUT_POLICY.
        assert_eq!((esp, shared, boot, cache), (2.0, 29.0, 94.0, 304.0));
    }

    #[test]
    fn binary_476gib_is_equivalent_to_marketed_512gb() {
        let p = plan(parse_size("476GiB").unwrap()).unwrap();
        p.check_consistency().unwrap();
        assert!((280.0..=320.0).contains(&gib(&p, PartitionRole::Cache)));
        assert_eq!(gib(&p, PartitionRole::BootA), 47.0);
    }

    #[test]
    fn scales_down_to_256_and_128() {
        let p256 = plan(parse_size("256GB").unwrap()).unwrap();
        let p128 = plan(parse_size("128GB").unwrap()).unwrap();
        p256.check_consistency().unwrap();
        p128.check_consistency().unwrap();
        assert_eq!(gib(&p256, PartitionRole::Esp), 2.0);
        assert_eq!(gib(&p128, PartitionRole::Esp), 1.0);
        assert!(gib(&p128, PartitionRole::BootA) >= 8.0);
        assert!(gib(&p128, PartitionRole::Cache) < gib(&p256, PartitionRole::Cache));
        assert!(gib(&p256, PartitionRole::Cache) >= 128.0);
        assert!(gib(&p128, PartitionRole::Cache) >= 60.0);
    }

    #[test]
    fn scales_up_with_caps() {
        let p = plan(parse_size("2TB").unwrap()).unwrap();
        p.check_consistency().unwrap();
        assert_eq!(gib(&p, PartitionRole::Shared), 32.0);
        assert_eq!(gib(&p, PartitionRole::BootA), 48.0);
        // Cache is the elastic partition on big devices; persistence is capped (+ < 1 GiB slack).
        assert!(gib(&p, PartitionRole::Persist) < 129.0);
        assert!(gib(&p, PartitionRole::Cache) > 1500.0);
    }

    #[test]
    fn minimum_is_enforced_and_minimum_plan_is_valid() {
        assert_eq!(
            plan(MIN_DEVICE_BYTES - 1),
            Err(LayoutError::TooSmall {
                device_bytes: MIN_DEVICE_BYTES - 1
            })
        );
        assert!(plan(parse_size("32GB").unwrap()).is_err());
        let p = plan(MIN_DEVICE_BYTES).unwrap();
        p.check_consistency().unwrap();
        assert!(gib(&p, PartitionRole::Cache) >= 16.0);
        assert!(gib(&p, PartitionRole::Persist) >= 8.0);
        // A real "64 GB" stick (vendor-reported bytes) must be accepted.
        assert!(plan(61_918_000_000).is_ok());
    }

    #[test]
    fn every_size_in_range_is_consistent_and_monotonic() {
        let mut last_cache = 0;
        let mut size = MIN_DEVICE_BYTES;
        while size <= 4_000_000_000_000 {
            let p = plan(size).unwrap();
            p.check_consistency()
                .unwrap_or_else(|e| panic!("{size}: {e}"));
            let total: u64 = p.partitions.iter().map(|x| x.size_bytes).sum();
            assert_eq!(
                total, p.usable_bytes,
                "{size}: plan must use the whole disk"
            );
            assert!(p.cache_bytes() >= last_cache, "{size}: cache shrank");
            last_cache = p.cache_bytes();
            size += 7 * GIB + 12_345;
        }
    }

    #[test]
    fn table_mentions_every_label() {
        let p = plan(parse_size("512GB").unwrap()).unwrap();
        let t = render_table(&p);
        for part in &p.partitions {
            assert!(t.contains(&part.label));
        }
    }
}
