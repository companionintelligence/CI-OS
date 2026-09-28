//! Read-only discovery of candidate removable block devices.
//!
//! This module only ever *runs listing commands* (`lsblk`, `diskutil list`) and parses
//! their output. It never opens a block device. Parsing is separated from execution so
//! it can be tested against captured output on any host.

use std::process::Command;

use anyhow::{bail, Context as _};
use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BlockDevice {
    pub name: String,
    pub path: String,
    pub size_bytes: u64,
    pub removable: bool,
    pub transport: Option<String>,
    pub model: Option<String>,
    /// Mount points of the device and all its partitions.
    pub mountpoints: Vec<String>,
    /// Holds the running system (`/`, `/boot`, swap, …) — never a candidate.
    pub is_system: bool,
}

impl BlockDevice {
    /// Worth showing as a stick target: removable or USB-attached, and not the system disk.
    pub fn is_candidate(&self) -> bool {
        !self.is_system && (self.removable || self.transport.as_deref() == Some("usb"))
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "kebab-case", tag = "status")]
pub enum Discovery {
    Listed {
        method: String,
        devices: Vec<BlockDevice>,
    },
    Unsupported {
        reason: String,
    },
    Failed {
        method: String,
        error: String,
    },
}

const SYSTEM_MOUNTS: [&str; 6] = ["/", "/boot", "/boot/efi", "/usr", "/var", "[SWAP]"];

fn json_bool(v: Option<&Value>) -> bool {
    match v {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_u64() == Some(1),
        Some(Value::String(s)) => s == "1" || s.eq_ignore_ascii_case("true"),
        _ => false,
    }
}

fn json_u64(v: Option<&Value>) -> Option<u64> {
    match v {
        Some(Value::Number(n)) => n.as_u64(),
        Some(Value::String(s)) => s.trim().parse().ok(),
        _ => None,
    }
}

fn json_str(v: Option<&Value>) -> Option<String> {
    v.and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn collect_mounts(node: &Value, out: &mut Vec<String>) {
    // util-linux >= 2.37 has MOUNTPOINTS (array); older has MOUNTPOINT (string).
    if let Some(arr) = node.get("mountpoints").and_then(Value::as_array) {
        out.extend(arr.iter().filter_map(Value::as_str).map(str::to_string));
    }
    if let Some(m) = node.get("mountpoint").and_then(Value::as_str) {
        out.push(m.to_string());
    }
    if let Some(children) = node.get("children").and_then(Value::as_array) {
        for c in children {
            collect_mounts(c, out);
        }
    }
}

/// Parse `lsblk -J -b -o NAME,PATH,SIZE,RM,TRAN,TYPE,MOUNTPOINTS,MODEL` output. Returns
/// whole disks only (partitions are folded into their disk's mount points).
pub fn parse_lsblk(json: &str) -> anyhow::Result<Vec<BlockDevice>> {
    let root: Value = serde_json::from_str(json).context("lsblk output is not JSON")?;
    let Some(list) = root.get("blockdevices").and_then(Value::as_array) else {
        bail!("lsblk output has no \"blockdevices\" array");
    };
    let mut out = Vec::new();
    for dev in list {
        if dev.get("type").and_then(Value::as_str) != Some("disk") {
            continue;
        }
        let Some(name) = json_str(dev.get("name")) else {
            continue;
        };
        let mut mountpoints = Vec::new();
        collect_mounts(dev, &mut mountpoints);
        mountpoints.sort();
        mountpoints.dedup();
        let is_system = mountpoints
            .iter()
            .any(|m| SYSTEM_MOUNTS.contains(&m.as_str()));
        out.push(BlockDevice {
            path: json_str(dev.get("path")).unwrap_or_else(|| format!("/dev/{name}")),
            name,
            size_bytes: json_u64(dev.get("size")).unwrap_or(0),
            removable: json_bool(dev.get("rm")),
            transport: json_str(dev.get("tran")),
            model: json_str(dev.get("model")),
            mountpoints,
            is_system,
        });
    }
    Ok(out)
}

/// Parse `diskutil list -plist external physical` output (best effort).
pub fn parse_diskutil_plist(bytes: &[u8]) -> anyhow::Result<Vec<BlockDevice>> {
    let root = plist::Value::from_reader(std::io::Cursor::new(bytes))
        .context("diskutil output is not a property list")?;
    let Some(disks) = root
        .as_dictionary()
        .and_then(|d| d.get("AllDisksAndPartitions"))
        .and_then(plist::Value::as_array)
    else {
        bail!("diskutil output has no AllDisksAndPartitions array");
    };
    let mut out = Vec::new();
    for disk in disks {
        let Some(d) = disk.as_dictionary() else {
            continue;
        };
        let Some(name) = d.get("DeviceIdentifier").and_then(plist::Value::as_string) else {
            continue;
        };
        let mut mountpoints = Vec::new();
        let mut push_mount = |dict: &plist::Dictionary| {
            if let Some(m) = dict.get("MountPoint").and_then(plist::Value::as_string) {
                mountpoints.push(m.to_string());
            }
        };
        push_mount(d);
        for key in ["Partitions", "APFSVolumes"] {
            if let Some(parts) = d.get(key).and_then(plist::Value::as_array) {
                parts
                    .iter()
                    .filter_map(plist::Value::as_dictionary)
                    .for_each(&mut push_mount);
            }
        }
        mountpoints.sort();
        mountpoints.dedup();
        let is_system = mountpoints
            .iter()
            .any(|m| m == "/" || m.starts_with("/System/Volumes"));
        out.push(BlockDevice {
            name: name.to_string(),
            path: format!("/dev/{name}"),
            size_bytes: d
                .get("Size")
                .and_then(plist::Value::as_unsigned_integer)
                .unwrap_or(0),
            // We asked diskutil for external physical disks only.
            removable: true,
            transport: Some("external".into()),
            model: None,
            mountpoints,
            is_system,
        });
    }
    Ok(out)
}

fn run(cmd: &str, args: &[&str]) -> anyhow::Result<Vec<u8>> {
    let out = Command::new(cmd)
        .args(args)
        .output()
        .with_context(|| format!("running {cmd}"))?;
    if !out.status.success() {
        bail!(
            "{cmd} {} exited with {}: {}",
            args.join(" "),
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(out.stdout)
}

/// List block devices on this host using read-only listing commands.
pub fn discover() -> Discovery {
    match std::env::consts::OS {
        "linux" => {
            let method = "lsblk".to_string();
            let modern = run(
                "lsblk",
                &[
                    "-J",
                    "-b",
                    "-o",
                    "NAME,PATH,SIZE,RM,TRAN,TYPE,MOUNTPOINTS,MODEL",
                ],
            );
            // util-linux < 2.37 has no MOUNTPOINTS column.
            let result = modern
                .or_else(|_| {
                    run(
                        "lsblk",
                        &[
                            "-J",
                            "-b",
                            "-o",
                            "NAME,PATH,SIZE,RM,TRAN,TYPE,MOUNTPOINT,MODEL",
                        ],
                    )
                })
                .and_then(|b| parse_lsblk(&String::from_utf8_lossy(&b)));
            match result {
                Ok(devices) => Discovery::Listed { method, devices },
                Err(e) => Discovery::Failed {
                    method,
                    error: format!("{e:#}"),
                },
            }
        }
        "macos" => {
            let method = "diskutil".to_string();
            match run("diskutil", &["list", "-plist", "external", "physical"])
                .and_then(|b| parse_diskutil_plist(&b))
            {
                Ok(devices) => Discovery::Listed { method, devices },
                Err(e) => Discovery::Failed {
                    method,
                    error: format!("{e:#}"),
                },
            }
        }
        other => Discovery::Unsupported {
            reason: format!("device listing on {other} is not supported yet"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LSBLK: &str = r#"{
   "blockdevices": [
      {"name":"nvme0n1", "path":"/dev/nvme0n1", "size":1000204886016, "rm":false, "tran":"nvme", "type":"disk", "mountpoints":[null], "model":"Samsung SSD 980 PRO 1TB",
         "children": [
            {"name":"nvme0n1p1", "path":"/dev/nvme0n1p1", "size":536870912, "rm":false, "tran":null, "type":"part", "mountpoints":["/boot/efi"], "model":null},
            {"name":"nvme0n1p2", "path":"/dev/nvme0n1p2", "size":999666221056, "rm":false, "tran":null, "type":"part", "mountpoints":["/"], "model":null}
         ]
      },
      {"name":"sda", "path":"/dev/sda", "size":512110190592, "rm":true, "tran":"usb", "type":"disk", "mountpoints":[null], "model":"Extreme Pro     ",
         "children": [
            {"name":"sda1", "path":"/dev/sda1", "size":512109142016, "rm":true, "tran":null, "type":"part", "mountpoints":["/media/u/STICK"], "model":null}
         ]
      },
      {"name":"sdb", "path":"/dev/sdb", "size":"61918000000", "rm":"0", "tran":"usb", "type":"disk", "mountpoint":null, "model":"Cruzer"},
      {"name":"loop0", "path":"/dev/loop0", "size":4096, "rm":false, "tran":null, "type":"loop", "mountpoints":["/snap/x"], "model":null},
      {"name":"sr0", "path":"/dev/sr0", "size":1073741312, "rm":true, "tran":"sata", "type":"rom", "mountpoints":[null], "model":"DVD"}
   ]
}"#;

    #[test]
    fn parses_lsblk_disks_and_flags_system_disk() {
        let devs = parse_lsblk(LSBLK).unwrap();
        let names: Vec<&str> = devs.iter().map(|d| d.name.as_str()).collect();
        assert_eq!(names, ["nvme0n1", "sda", "sdb"], "only whole disks");
        assert!(devs[0].is_system && !devs[0].is_candidate());
        let sda = &devs[1];
        assert!(sda.is_candidate());
        assert_eq!(sda.size_bytes, 512_110_190_592);
        assert_eq!(sda.model.as_deref(), Some("Extreme Pro"));
        assert_eq!(sda.mountpoints, ["/media/u/STICK"]);
        // Old lsblk: string sizes/flags, MOUNTPOINT column; USB transport makes it a candidate.
        let sdb = &devs[2];
        assert_eq!(sdb.size_bytes, 61_918_000_000);
        assert!(!sdb.removable && sdb.is_candidate());
    }

    #[test]
    fn rejects_garbage_lsblk() {
        assert!(parse_lsblk("nope").is_err());
        assert!(parse_lsblk("{}").is_err());
    }

    const DISKUTIL: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AllDisks</key><array><string>disk4</string><string>disk4s1</string></array>
  <key>AllDisksAndPartitions</key>
  <array>
    <dict>
      <key>Content</key><string>GUID_partition_scheme</string>
      <key>DeviceIdentifier</key><string>disk4</string>
      <key>OSInternal</key><false/>
      <key>Partitions</key>
      <array>
        <dict>
          <key>Content</key><string>Microsoft Basic Data</string>
          <key>DeviceIdentifier</key><string>disk4s2</string>
          <key>MountPoint</key><string>/Volumes/CI-SHARED</string>
          <key>Size</key><integer>31138512896</integer>
          <key>VolumeName</key><string>CI-SHARED</string>
        </dict>
      </array>
      <key>Size</key><integer>512110190592</integer>
    </dict>
  </array>
  <key>VolumesFromDisks</key><array><string>CI-SHARED</string></array>
  <key>WholeDisks</key><array><string>disk4</string></array>
</dict>
</plist>"#;

    #[test]
    fn parses_diskutil_plist() {
        let devs = parse_diskutil_plist(DISKUTIL.as_bytes()).unwrap();
        assert_eq!(devs.len(), 1);
        let d = &devs[0];
        assert_eq!(d.path, "/dev/disk4");
        assert_eq!(d.size_bytes, 512_110_190_592);
        assert_eq!(d.mountpoints, ["/Volumes/CI-SHARED"]);
        assert!(d.is_candidate());
        assert!(parse_diskutil_plist(b"not a plist").is_err());
    }
}
