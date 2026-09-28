//! `ci-stick doctor` — strictly read-only host and device diagnostics.
//!
//! Reports what this host can do with a stick, which attached devices are candidates and
//! which layout each would get. It runs listing commands only and never opens, mounts,
//! unmounts or writes a device.

use serde::Serialize;

use crate::devices::{BlockDevice, Discovery};
use crate::host::HostCapabilities;
use crate::layout::{self, LayoutPlan};
use crate::size::{fmt_binary, fmt_decimal};
use crate::verify::{self, VerifyReport};

#[derive(Debug, Clone, Serialize)]
pub struct DeviceAssessment {
    #[serde(flatten)]
    pub device: BlockDevice,
    pub layout: Option<LayoutPlan>,
    pub layout_error: Option<String>,
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DoctorReport {
    pub host: HostCapabilities,
    pub discovery_method: Option<String>,
    pub discovery_error: Option<String>,
    pub candidates: Vec<DeviceAssessment>,
    /// Non-candidate disks seen (system/internal), by path — shown so users know why
    /// their disk is not listed.
    pub ignored: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bundle: Option<VerifyReport>,
}

impl DoctorReport {
    /// Doctor itself only "fails" when an explicitly requested bundle check fails.
    pub fn ok(&self) -> bool {
        self.bundle.as_ref().map_or(true, |b| b.ok)
    }
}

pub fn assess(device: BlockDevice) -> DeviceAssessment {
    let mut notes = Vec::new();
    if !device.mountpoints.is_empty() {
        notes.push(format!(
            "mounted at {} — would have to be unmounted before flashing",
            device.mountpoints.join(", ")
        ));
    }
    let (layout, layout_error) = match layout::plan(device.size_bytes) {
        Ok(p) => (Some(p), None),
        Err(e) => (None, Some(e.to_string())),
    };
    DeviceAssessment {
        device,
        layout,
        layout_error,
        notes,
    }
}

pub fn build_report(
    host: HostCapabilities,
    discovery: Discovery,
    bundle: Option<VerifyReport>,
) -> DoctorReport {
    let mut report = DoctorReport {
        host,
        discovery_method: None,
        discovery_error: None,
        candidates: Vec::new(),
        ignored: Vec::new(),
        bundle,
    };
    match discovery {
        Discovery::Listed { method, devices } => {
            report.discovery_method = Some(method);
            for d in devices {
                if d.is_candidate() {
                    report.candidates.push(assess(d));
                } else {
                    let why = if d.is_system {
                        "system disk"
                    } else {
                        "not removable/USB"
                    };
                    report.ignored.push(format!("{} ({why})", d.path));
                }
            }
        }
        Discovery::Unsupported { reason } => report.discovery_error = Some(reason),
        Discovery::Failed { method, error } => {
            report.discovery_method = Some(method);
            report.discovery_error = Some(error);
        }
    }
    report
}

pub fn render_human(r: &DoctorReport) -> String {
    let mut out = String::new();
    let mark = |b: bool| if b { "yes" } else { "no " };
    out.push_str("Host\n");
    out.push_str(&format!(
        "  OS / arch        {} / {}\n",
        r.host.os, r.host.arch
    ));
    out.push_str(&format!(
        "  Host install     {}  {}\n",
        mark(r.host.host_install.supported),
        r.host.host_install.note
    ));
    out.push_str(&format!(
        "  Boot from stick  {}  {}\n",
        mark(r.host.boot.supported),
        r.host.boot.note
    ));

    out.push_str(&format!(
        "\nRemovable devices{} — read-only scan, nothing is written\n",
        r.discovery_method
            .as_deref()
            .map(|m| format!(" (via {m})"))
            .unwrap_or_default()
    ));
    if let Some(e) = &r.discovery_error {
        out.push_str(&format!("  not available: {e}\n"));
    } else if r.candidates.is_empty() {
        out.push_str("  none found\n");
    }
    for c in &r.candidates {
        let d = &c.device;
        out.push_str(&format!(
            "  {}  {}  {} ({})  {}\n",
            d.path,
            d.model.as_deref().unwrap_or("(unknown model)"),
            fmt_decimal(d.size_bytes),
            fmt_binary(d.size_bytes),
            d.transport.as_deref().unwrap_or("-")
        ));
        match (&c.layout, &c.layout_error) {
            (Some(p), _) => out.push_str(&format!("      layout: {}\n", p.summary())),
            (None, Some(e)) => out.push_str(&format!("      layout: none — {e}\n")),
            _ => {}
        }
        for n in &c.notes {
            out.push_str(&format!("      note: {n}\n"));
        }
    }
    if !r.ignored.is_empty() {
        out.push_str(&format!("  ignored: {}\n", r.ignored.join(", ")));
    }
    if let Some(b) = &r.bundle {
        out.push_str("\nBundle check\n");
        for line in verify::render_human(b).lines() {
            out.push_str(&format!("  {line}\n"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::capabilities;

    fn dev(path: &str, size: u64, system: bool) -> BlockDevice {
        BlockDevice {
            name: path.trim_start_matches("/dev/").into(),
            path: path.into(),
            size_bytes: size,
            removable: true,
            transport: Some("usb".into()),
            model: None,
            mountpoints: if system { vec!["/".into()] } else { vec![] },
            is_system: system,
        }
    }

    #[test]
    fn assigns_layouts_and_skips_system_disks() {
        let discovery = Discovery::Listed {
            method: "test".into(),
            devices: vec![
                dev("/dev/sda", 512_110_190_592, false),
                dev("/dev/sdb", 16_000_000_000, false),
                dev("/dev/sdc", 256_000_000_000, true),
            ],
        };
        let r = build_report(capabilities("linux", "x86_64"), discovery, None);
        assert_eq!(r.candidates.len(), 2);
        assert!(r.candidates[0].layout.is_some());
        assert!(r.candidates[1]
            .layout_error
            .as_deref()
            .unwrap_or("")
            .contains("too small"));
        assert_eq!(r.ignored, ["/dev/sdc (system disk)"]);
        assert!(r.ok());
        let text = render_human(&r);
        assert!(text.contains("cache 304 GiB"), "{text}");
    }

    #[test]
    fn unsupported_discovery_is_reported_not_fatal() {
        let r = build_report(
            capabilities("windows", "x86_64"),
            Discovery::Unsupported {
                reason: "not yet".into(),
            },
            None,
        );
        assert!(r.ok());
        assert!(render_human(&r).contains("not available: not yet"));
    }
}
