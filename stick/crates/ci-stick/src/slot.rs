//! `ci-stick slot show|set`: read or flip the A/B pointer (`ci-stick/grubenv` on the ESP).
//!
//! Root-free on image files: the ESP is found by parsing the GPT (name `CI-EFI` and the
//! EFI System type GUID) and accessed with mtools at its byte offset (`image@@offset`),
//! so nothing is mounted. Writes to a device follow the same safety rules as `flash`
//! (removable/USB, nothing mounted, `--confirm`, `O_EXCL`, identity re-check). Only the
//! 1 KiB grubenv file changes; the boot slots are never touched.

use std::fs::{self, File};
use std::path::{Path, PathBuf};

use anyhow::{bail, ensure, Context as _};
use serde::Serialize;

use crate::bootcfg;
use crate::gpt;
use crate::grubenv::{GrubEnv, Slot};
use crate::layout::{PartitionRole, GPT_TYPE_ESP};
use crate::target;
use crate::tools;

/// Which stick to act on.
#[derive(Debug, Clone)]
pub enum SlotTarget {
    Image(PathBuf),
    Device(PathBuf),
}

#[derive(Debug, Clone, Serialize)]
pub struct SlotState {
    pub target: String,
    pub esp_offset: u64,
    pub active_slot: Slot,
    pub vars: Vec<(String, String)>,
}

/// Byte offset of the stick's ESP, found by GPT name and type.
pub fn find_esp(file: &mut File, sector: Option<u64>) -> anyhow::Result<u64> {
    let g = gpt::read(file, sector).context("reading the stick's GPT")?;
    let esp_label = crate::layout::plan(crate::layout::MIN_DEVICE_BYTES)?
        .partition(PartitionRole::Esp)
        .map(|p| p.label.clone())
        .context("layout has no ESP")?;
    let e = g
        .by_name(&esp_label)
        .with_context(|| format!("no {esp_label} partition — is this a Companion Stick?"))?;
    ensure!(
        e.type_guid.eq_ignore_ascii_case(GPT_TYPE_ESP),
        "{esp_label} is not an EFI System partition (type {})",
        e.type_guid
    );
    Ok(e.start_bytes(g.sector_size))
}

fn read_env(path: &Path, offset: u64, work: &Path) -> anyhow::Result<GrubEnv> {
    let out = work.join("grubenv.read");
    let _ = fs::remove_file(&out);
    let src = format!("::/{}", bootcfg::ESP_GRUBENV);
    tools::run(
        "mcopy",
        [
            "-n".as_ref(),
            "-i".as_ref(),
            tools::mtools_image(path, offset).as_os_str(),
            src.as_ref(),
            out.as_os_str(),
        ],
    )
    .context("reading ci-stick/grubenv from the ESP")?;
    GrubEnv::decode(&fs::read(&out)?)
}

fn node_of(t: &SlotTarget) -> anyhow::Result<PathBuf> {
    match t {
        SlotTarget::Image(p) => {
            let m = fs::symlink_metadata(p).with_context(|| format!("{}", p.display()))?;
            ensure!(
                m.is_file(),
                "{} is not a regular file (use --device for block devices)",
                p.display()
            );
            Ok(p.clone())
        }
        SlotTarget::Device(p) => {
            if std::env::consts::OS != "linux" {
                bail!("slot on devices is Linux-only in this release");
            }
            let r = target::resolve_device(p)?;
            Ok(PathBuf::from(&r.node))
        }
    }
}

/// Read the current slot pointer.
pub fn show(t: &SlotTarget) -> anyhow::Result<SlotState> {
    tools::require(&tools::SLOT_TOOLS)?;
    let path = node_of(t)?;
    let mut f = File::open(&path).with_context(|| format!("opening {}", path.display()))?;
    let sector = match t {
        SlotTarget::Device(_) => {
            Some(target::read_disk_info(&path.display().to_string())?.logical_sector)
        }
        SlotTarget::Image(_) => None,
    };
    let off = find_esp(&mut f, sector)?;
    let work = tempfile::tempdir()?;
    let env = read_env(&path, off, work.path())?;
    Ok(SlotState {
        target: path.display().to_string(),
        esp_offset: off,
        active_slot: env.active_slot()?,
        vars: env.vars().to_vec(),
    })
}

/// Set the active slot. Device writes need `confirm` (and `expect_serial` when the device
/// reports a serial), exactly like `flash`.
pub fn set(
    t: &SlotTarget,
    slot: Slot,
    confirm: Option<&str>,
    expect_serial: Option<&str>,
) -> anyhow::Result<SlotState> {
    tools::require(&tools::SLOT_TOOLS)?;
    let (path, sector, guard) = match t {
        SlotTarget::Image(_) => {
            ensure!(
                confirm.is_none() && expect_serial.is_none(),
                "--confirm/--expect-serial apply to --device targets only"
            );
            (node_of(t)?, None, None)
        }
        SlotTarget::Device(p) => {
            let dev = target::prepare_device(p)?;
            let id = dev.disk.identity();
            target::check_confirmation(&id, confirm, expect_serial)?;
            // Hold O_EXCL while mtools writes: nothing can mount the ESP underneath us.
            let mut guard = target::open_exclusive(&id.node)?;
            target::recheck_identity(&id, &mut guard)?;
            (
                PathBuf::from(&id.node),
                Some(dev.disk.logical_sector),
                Some(guard),
            )
        }
    };
    let mut f = File::open(&path).with_context(|| format!("opening {}", path.display()))?;
    let off = find_esp(&mut f, sector)?;
    drop(f);
    let work = tempfile::tempdir()?;
    let mut env = read_env(&path, off, work.path())?;
    env.set(crate::grubenv::VAR_ACTIVE_SLOT, slot.as_str())?;
    let new = work.path().join("grubenv.new");
    fs::write(&new, env.encode()?)?;
    let dst = format!("::/{}", bootcfg::ESP_GRUBENV);
    tools::run(
        "mcopy",
        [
            "-o".as_ref(),
            "-i".as_ref(),
            tools::mtools_image(&path, off).as_os_str(),
            new.as_os_str(),
            dst.as_ref(),
        ],
    )
    .context("writing ci-stick/grubenv")?;
    if let Some(g) = &guard {
        g.sync_all().ok();
        target::drop_cache(g);
    }
    // Read back what GRUB will read.
    let back = read_env(&path, off, work.path())?;
    ensure!(
        back.active_slot()? == slot,
        "read-back shows active_slot={:?}, expected {slot}",
        back.get(crate::grubenv::VAR_ACTIVE_SLOT)
    );
    Ok(SlotState {
        target: path.display().to_string(),
        esp_offset: off,
        active_slot: slot,
        vars: back.vars().to_vec(),
    })
}
