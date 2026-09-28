//! The stick's GRUB configuration (`ci-stick/grub.cfg` on the ESP).
//!
//! The standalone `BOOTX64.EFI` (built by `stick/scripts/build-grub-efi.sh`) embeds only a
//! tiny loader config that finds the ESP it booted from and runs `configfile` on this
//! file. Everything else happens here:
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

const TEMPLATE: &str = include_str!("../templates/grub.cfg.in");

/// Ubuntu 24.04 live ISO paths.
pub const DEFAULT_KERNEL: &str = "/casper/vmlinuz";
pub const DEFAULT_INITRD: &str = "/casper/initrd";

/// ESP-relative locations `flash` writes.
pub const ESP_BOOTLOADER: &str = "EFI/BOOT/BOOTX64.EFI";
pub const ESP_GRUB_CFG: &str = "ci-stick/grub.cfg";
pub const ESP_GRUBENV: &str = "ci-stick/grubenv";

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
