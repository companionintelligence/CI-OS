//! The stick's GRUB configuration and where the boot chain goes on the ESP.
//!
//! One rendered `grub.cfg` serves both boot chains ([`crate::manifest::BootChain`]); only
//! where it is written differs ([`grub_cfg_paths`]):
//!
//! * **Secure chain.** Firmware loads `EFI/BOOT/BOOTX64.EFI` (= shim), shim loads
//!   `grubx64.efi` from the same directory, which is Canonical's signed *monolithic* GRUB
//!   (`grub-efi-amd64-signed`, the disk image `grubx64.efi.signed`, not the CD image
//!   `gcdx64.efi.signed`). Its embedded prefix is `/EFI/ubuntu` and it has no embedded
//!   early config (its memdisk only holds a font). Ubuntu's GRUB reads
//!   `$fw_path/grub.cfg` (the directory it was loaded from, `EFI/BOOT/`) first, then
//!   `$prefix/grub.cfg` (`EFI/ubuntu/grub.cfg` on the same ESP), else it drops to a GRUB
//!   shell. It never searches for `/.disk/info` (that is `gcdx64`'s memdisk config), so
//!   a boot slot's own ISO `grub.cfg` is never picked up by accident. We write the config
//!   to both places. Verified by booting under OVMF (see `stick/tests/secureboot/`).
//!   Under Secure Boot GRUB cannot load modules from disk, so the config only uses
//!   commands built into that image ([`CANONICAL_GRUB_BUILTIN_MODULES`]; `insmod` of a
//!   built-in module is a no-op).
//! * **Development chain.** The unsigned standalone `BOOTX64.EFI` (built by
//!   `stick/scripts/build-grub-efi.sh`) embeds only a tiny loader config that finds the ESP
//!   it booted from and runs `configfile` on `ci-stick/grub.cfg`.
//!
//! The config itself:
//!
//! 1. derive the stick's disk from `$cmdpath` (never assume `hd0`);
//! 2. `load_env` the A/B pointer from `ci-stick/grubenv` ([`crate::grubenv`]), default A;
//! 3. offer the active slot first and the other slot as a fallback. Each slot is a raw
//!    Ubuntu live ISO (casper layout) written to its partition, booted with
//!    `live-media=/dev/disk/by-partlabel/CI-BOOT-<X> persistent`. Persistence is the ext4
//!    filesystem labelled `writable` on `CI-PERSIST`, which casper finds by that label.
//!
//! Partition numbers come from the layout plan ([`crate::layout`]); they are not written
//! down anywhere else.

use anyhow::Context as _;

use crate::grubenv::Slot;
use crate::layout::{LayoutPlan, PartitionRole};
use crate::manifest::{BootChain, BootloaderRole};

const TEMPLATE: &str = include_str!("../templates/grub.cfg.in");

/// Ubuntu 26.04 live ISO paths (`casper/vmlinuz`, `casper/initrd` on the 26.04.1 desktop ISO).
pub const DEFAULT_KERNEL: &str = "/casper/vmlinuz";
pub const DEFAULT_INITRD: &str = "/casper/initrd";

/// ESP-relative locations `flash` writes.
pub const ESP_BOOTLOADER: &str = "EFI/BOOT/BOOTX64.EFI";
pub const ESP_GRUB_CFG: &str = "ci-stick/grub.cfg";
pub const ESP_GRUBENV: &str = "ci-stick/grubenv";
/// Secure chain: shim's second stage and MokManager live next to shim.
pub const ESP_SIGNED_GRUB: &str = "EFI/BOOT/grubx64.efi";
pub const ESP_MOK_MANAGER: &str = "EFI/BOOT/mmx64.efi";
/// Secure chain: Canonical GRUB reads `$fw_path/grub.cfg`, then `$prefix/grub.cfg`.
pub const ESP_GRUB_CFG_FW_PATH: &str = "EFI/BOOT/grub.cfg";
pub const ESP_GRUB_CFG_PREFIX: &str = "EFI/ubuntu/grub.cfg";

/// Modules built into Canonical's signed `grubx64.efi` (grub-efi-amd64-signed
/// 1.215+2.14-2ubuntu1, GRUB 2.14, the 26.04.1 version) that our config relies on, read out
/// of the image's `mods` section. Under Secure Boot nothing else can be loaded, so a test
/// keeps every `insmod` in the template inside this list, and another keeps this list inside
/// the module set read from the real image (`tests/fixtures/grub/`). The set changes between
/// Ubuntu releases (the previous LTS's image had `all_video`, `efi_uga`, `ntfs`, `pgp`,
/// `video_bochs` and `video_cirrus`; 26.04's has none of them). `scripts/fetch-signed-boot.sh`
/// checks every fetched image against this list, and reads it from here with `sed`: keep one
/// `"name",` per line.
pub const CANONICAL_GRUB_BUILTIN_MODULES: &[&str] = &[
    "configfile",
    "echo",
    "ext2",
    "fat",
    "iso9660",
    "linux",
    "loadenv",
    "normal",
    "part_gpt",
    "regexp",
    "search",
    "search_label",
    "sleep",
    "test",
];

/// Where each bootloader binary of `chain` goes on the ESP.
pub fn esp_binaries(chain: BootChain) -> &'static [(BootloaderRole, &'static str)] {
    match chain {
        // Firmware's removable-media path is shim; shim loads grubx64.efi (and, on
        // request, mmx64.efi) from its own directory. No fbx64.efi: shim would run the
        // fallback loader, which writes boot entries into the host's NVRAM.
        BootChain::Secure => &[
            (BootloaderRole::Shim, ESP_BOOTLOADER),
            (BootloaderRole::Grub, ESP_SIGNED_GRUB),
            (BootloaderRole::MokManager, ESP_MOK_MANAGER),
        ],
        BootChain::Development => &[(BootloaderRole::StandaloneGrub, ESP_BOOTLOADER)],
    }
}

/// Where the (identical) rendered grub.cfg is written for `chain`.
pub fn grub_cfg_paths(chain: BootChain) -> &'static [&'static str] {
    match chain {
        BootChain::Secure => &[ESP_GRUB_CFG_FW_PATH, ESP_GRUB_CFG_PREFIX],
        BootChain::Development => &[ESP_GRUB_CFG],
    }
}

/// ESP directories `flash` creates for `chain` (parents first).
pub fn esp_dirs(chain: BootChain) -> Vec<String> {
    let mut dirs: Vec<String> = Vec::new();
    let files = esp_binaries(chain)
        .iter()
        .map(|(_, p)| *p)
        .chain(grub_cfg_paths(chain).iter().copied())
        .chain([ESP_GRUBENV]);
    for f in files {
        let mut acc = String::new();
        let parts: Vec<&str> = f.split('/').collect();
        for part in &parts[..parts.len() - 1] {
            if !acc.is_empty() {
                acc.push('/');
            }
            acc.push_str(part);
            if !dirs.contains(&acc) {
                dirs.push(acc.clone());
            }
        }
    }
    dirs
}

/// GPT partition numbers the boot menu needs, taken from a layout plan.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BootPartitions {
    pub esp: u32,
    pub slot_a: u32,
    pub slot_b: u32,
}

impl BootPartitions {
    pub fn from_layout(plan: &LayoutPlan) -> anyhow::Result<Self> {
        let idx = |role: PartitionRole| {
            plan.partition(role)
                .map(|p| p.index)
                .with_context(|| format!("layout has no {role:?} partition"))
        };
        Ok(Self {
            esp: idx(PartitionRole::Esp)?,
            slot_a: idx(PartitionRole::BootA)?,
            slot_b: idx(PartitionRole::BootB)?,
        })
    }

    pub fn slot(&self, slot: Slot) -> u32 {
        match slot {
            Slot::A => self.slot_a,
            Slot::B => self.slot_b,
        }
    }
}

/// GPT partition name (and `/dev/disk/by-partlabel/` name) of a slot, from the layout.
pub fn slot_label(plan: &LayoutPlan, slot: Slot) -> anyhow::Result<String> {
    let role = match slot {
        Slot::A => PartitionRole::BootA,
        Slot::B => PartitionRole::BootB,
    };
    plan.partition(role)
        .map(|p| p.label.clone())
        .with_context(|| format!("layout has no {role:?} partition"))
}

fn menuentry(
    plan: &LayoutPlan,
    parts: BootPartitions,
    slot: Slot,
    fallback: bool,
) -> anyhow::Result<String> {
    let n = parts.slot(slot);
    let label = slot_label(plan, slot)?;
    let title = if fallback {
        format!("Companion OS (slot {slot}, fallback)")
    } else {
        format!("Companion OS (slot {slot})")
    };
    let id = format!("ci-slot-{}", slot.as_str().to_ascii_lowercase());
    Ok(format!(
        "  menuentry \"{title}\" --id {id} {{\n\
         \x20   linux ($ci_disk,gpt{n}){DEFAULT_KERNEL} boot=casper live-media=/dev/disk/by-partlabel/{label} persistent ci_stick.slot={slot} quiet splash $extra_cmdline ---\n\
         \x20   initrd ($ci_disk,gpt{n}){DEFAULT_INITRD}\n\
         \x20 }}"
    ))
}

/// Render `ci-stick/grub.cfg` for a layout.
pub fn render_grub_cfg(plan: &LayoutPlan) -> anyhow::Result<String> {
    let parts = BootPartitions::from_layout(plan)?;
    let order = |first: Slot| -> anyhow::Result<String> {
        Ok(format!(
            "{}\n{}",
            menuentry(plan, parts, first, false)?,
            menuentry(plan, parts, first.other(), true)?
        ))
    };
    Ok(TEMPLATE
        .replace("@POLICY@", &plan.policy)
        .replace("@ESP_PART@", &parts.esp.to_string())
        .replace("@SLOT_A_PART@", &parts.slot_a.to_string())
        .replace("@SLOT_B_PART@", &parts.slot_b.to_string())
        .replace("@ENTRIES_A_FIRST@", &order(Slot::A)?)
        .replace("@ENTRIES_B_FIRST@", &order(Slot::B)?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout;

    fn cfg() -> String {
        render_grub_cfg(&layout::plan(64_000_000_000).unwrap()).unwrap()
    }

    #[test]
    fn slot_partitions_come_from_the_layout() {
        let plan = layout::plan(512_000_000_000).unwrap();
        let parts = BootPartitions::from_layout(&plan).unwrap();
        assert_eq!(
            parts,
            BootPartitions {
                esp: plan.partition(PartitionRole::Esp).unwrap().index,
                slot_a: plan.partition(PartitionRole::BootA).unwrap().index,
                slot_b: plan.partition(PartitionRole::BootB).unwrap().index,
            }
        );
        assert_eq!((parts.esp, parts.slot_a, parts.slot_b), (1, 3, 4));
        let c = cfg();
        assert!(c.contains("linux ($ci_disk,gpt3)/casper/vmlinuz"));
        assert!(c.contains("initrd ($ci_disk,gpt4)/casper/initrd"));
        assert!(c.contains("set ci_esp=\"($ci_disk,gpt1)\""));
    }

    fn insmods(text: &str) -> Vec<String> {
        text.lines()
            .filter_map(|l| l.trim().strip_prefix("insmod "))
            .map(|m| m.trim().to_string())
            .collect()
    }

    /// Module names of the real signed GRUB 2.14 image (comment lines start with `#`).
    const SIGNED_GRUB_MODULES: &str =
        include_str!("../tests/fixtures/grub/grubx64.efi.signed.builtin-modules.txt");

    fn signed_grub_modules() -> Vec<&'static str> {
        SIGNED_GRUB_MODULES
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .collect()
    }

    #[test]
    fn fixture_is_the_module_list_of_the_signed_grub_image() {
        let real = signed_grub_modules();
        assert_eq!(real.len(), 122, "grubx64.efi.signed of 1.215+2.14-2ubuntu1");
        assert!(
            real.windows(2).all(|w| w[0] < w[1]),
            "sorted and unique, as grub-builtin-modules.py prints them"
        );
        // The modules the comment on CANONICAL_GRUB_BUILTIN_MODULES says are gone, and some that matter.
        for gone in [
            "all_video",
            "efi_uga",
            "ntfs",
            "video_bochs",
            "video_cirrus",
        ] {
            assert!(
                !real.contains(&gone),
                "{gone} is not built into 26.04's signed GRUB"
            );
        }
        for present in ["efi_gop", "gfxterm", "png", "video", "video_fb", "loadenv"] {
            assert!(real.contains(&present), "{present}");
        }
    }

    #[test]
    fn pinned_list_is_inside_what_the_real_signed_grub_has() {
        let real = signed_grub_modules();
        let mut sorted = CANONICAL_GRUB_BUILTIN_MODULES.to_vec();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(
            sorted.len(),
            CANONICAL_GRUB_BUILTIN_MODULES.len(),
            "no duplicates"
        );
        for m in CANONICAL_GRUB_BUILTIN_MODULES {
            assert!(
                real.contains(m),
                "{m} is not built into Canonical's signed grubx64.efi (tests/fixtures/grub/): \
                 under Secure Boot GRUB could not load it"
            );
        }
        for m in insmods(TEMPLATE) {
            assert!(real.contains(&m.as_str()), "grub.cfg.in loads {m}");
        }
    }

    #[test]
    fn pinned_list_stays_readable_by_fetch_signed_boot_sh() {
        // fetch-signed-boot.sh reads the array out of this file with sed, one `"name",` per
        // line between the const and its closing `];`; a reformat must not blind it.
        let src = include_str!("bootcfg.rs");
        let start = src
            .find("pub const CANONICAL_GRUB_BUILTIN_MODULES")
            .expect("const");
        let body = &src[start..start + src[start..].find("\n];").expect("end of array")];
        let lines: Vec<&str> = body.lines().skip(1).collect();
        assert_eq!(lines.len(), CANONICAL_GRUB_BUILTIN_MODULES.len());
        for (line, m) in lines.iter().zip(CANONICAL_GRUB_BUILTIN_MODULES) {
            assert_eq!(*line, format!("    \"{m}\","));
        }
    }

    #[test]
    fn config_only_uses_modules_both_grubs_have_built_in() {
        let used = insmods(TEMPLATE);
        assert!(used.contains(&"loadenv".to_string()) && used.contains(&"regexp".to_string()));
        for m in &used {
            assert!(
                CANONICAL_GRUB_BUILTIN_MODULES.contains(&m.as_str()),
                "grub.cfg loads {m}, which Canonical's signed GRUB does not have built in \
                 (it cannot load modules under Secure Boot)"
            );
        }
        // The standalone development GRUB embeds its modules too (no /boot/grub on the ESP).
        let script = include_str!("../../../scripts/build-grub-efi.sh");
        let start = script
            .find("modules=(")
            .expect("modules=( in build-grub-efi.sh")
            + 9;
        let end = start + script[start..].find(')').expect("closing )");
        let standalone: Vec<&str> = script[start..end].split_whitespace().collect();
        let extra = ["search", "search_label", "sleep", "normal"];
        for m in used.iter().map(String::as_str).chain(extra) {
            assert!(
                standalone.contains(&m),
                "build-grub-efi.sh does not embed {m}"
            );
            assert!(CANONICAL_GRUB_BUILTIN_MODULES.contains(&m), "{m}");
        }
    }

    #[test]
    fn esp_placement_per_chain() {
        assert_eq!(
            esp_binaries(BootChain::Secure),
            &[
                (BootloaderRole::Shim, "EFI/BOOT/BOOTX64.EFI"),
                (BootloaderRole::Grub, "EFI/BOOT/grubx64.efi"),
                (BootloaderRole::MokManager, "EFI/BOOT/mmx64.efi"),
            ]
        );
        assert_eq!(
            esp_binaries(BootChain::Development),
            &[(BootloaderRole::StandaloneGrub, "EFI/BOOT/BOOTX64.EFI")]
        );
        for chain in [BootChain::Secure, BootChain::Development] {
            let roles: Vec<BootloaderRole> = esp_binaries(chain).iter().map(|(r, _)| *r).collect();
            assert_eq!(roles, chain.roles(), "every role of {chain:?} is placed");
        }
        assert_eq!(
            grub_cfg_paths(BootChain::Secure),
            &["EFI/BOOT/grub.cfg", "EFI/ubuntu/grub.cfg"]
        );
        assert_eq!(
            grub_cfg_paths(BootChain::Development),
            &["ci-stick/grub.cfg"]
        );
        assert_eq!(
            esp_dirs(BootChain::Secure),
            vec!["EFI", "EFI/BOOT", "EFI/ubuntu", "ci-stick"]
        );
        assert_eq!(
            esp_dirs(BootChain::Development),
            vec!["EFI", "EFI/BOOT", "ci-stick"]
        );
    }

    #[test]
    fn renders_complete_boot_lines_and_no_placeholders() {
        let c = cfg();
        assert!(!c.contains('@'), "unreplaced placeholder:\n{c}");
        assert!(c.contains(
            "live-media=/dev/disk/by-partlabel/CI-BOOT-A persistent ci_stick.slot=A quiet splash $extra_cmdline ---"
        ));
        assert!(
            c.contains("live-media=/dev/disk/by-partlabel/CI-BOOT-B persistent ci_stick.slot=B")
        );
        assert!(
            c.contains("load_env --file \"$ci_esp/ci-stick/grubenv\" active_slot extra_cmdline")
        );
        assert!(c.contains("regexp --set=1:ci_disk"));
        assert!(
            !c.contains("console="),
            "production config must not force a console"
        );
        // Active slot first, other slot as fallback, in both branches.
        let b_branch =
            &c[c.find("if [ \"$active_slot\" = \"B\" ]").unwrap()..c.find("\nelse\n").unwrap()];
        let first_b = b_branch.find("Companion OS (slot B)").unwrap();
        let fallback_a = b_branch.find("Companion OS (slot A, fallback)").unwrap();
        assert!(first_b < fallback_a);
        let a_branch = &c[c.find("\nelse\n").unwrap()..];
        assert!(a_branch.find("(slot A)").unwrap() < a_branch.find("(slot B, fallback)").unwrap());
        // Balanced braces: every menuentry closes.
        assert_eq!(c.matches('{').count(), c.matches('}').count());
    }
}
