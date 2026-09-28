//! What this host can do with a Companion Stick.
//!
//! * **Host install** — the stick is plugged into a running OS and its signed launcher
//!   installs CI Hub / CI Memory / model packs (explicit invocation + admin consent).
//! * **Boot** — this machine can boot the stick's live image. Only x86_64 UEFI images
//!   exist today; Apple Silicon can never boot them and is host-install only.

use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Support {
    pub supported: bool,
    pub note: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HostCapabilities {
    pub os: String,
    pub arch: String,
    pub host_install: Support,
    pub boot: Support,
}

fn yes(note: &str) -> Support {
    Support {
        supported: true,
        note: note.into(),
    }
}

fn no(note: &str) -> Support {
    Support {
        supported: false,
        note: note.into(),
    }
}

/// Pure capability matrix for an (`std::env::consts::OS`, `ARCH`) pair.
pub fn capabilities(os: &str, arch: &str) -> HostCapabilities {
    let (host_install, boot) = match (os, arch) {
        ("linux", "x86_64") => (yes("Linux x86_64"), yes("x86_64 UEFI")),
        ("linux", "aarch64") => (
            yes("Linux arm64"),
            no("arm64 boot images are not built yet (planned)"),
        ),
        ("macos", "aarch64") => (
            yes("macOS on Apple Silicon"),
            no("Apple Silicon cannot boot x86_64 images — host-install only"),
        ),
        ("macos", "x86_64") => (
            yes("macOS on Intel"),
            yes("Intel Mac, UEFI; T2 Macs need Secure Boot set to No Security and external boot allowed in Startup Security Utility (Apple does not trust the Microsoft UEFI CA that signs shim)"),
        ),
        ("windows", "x86_64") => (
            yes("Windows x86_64"),
            yes("x86_64 UEFI; Secure Boot works with the signed chain (shim → Canonical GRUB)"),
        ),
        ("windows", "aarch64") => (
            no("Windows on ARM is not supported yet"),
            no("arm64 boot images are not built yet"),
        ),
        _ => (
            no("this OS/architecture is not supported"),
            no("this OS/architecture is not supported"),
        ),
    };
    HostCapabilities {
        os: os.into(),
        arch: arch.into(),
        host_install,
        boot,
    }
}

pub fn current() -> HostCapabilities {
    capabilities(std::env::consts::OS, std::env::consts::ARCH)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matrix() {
        let cases = [
            ("linux", "x86_64", true, true),
            ("linux", "aarch64", true, false),
            ("macos", "aarch64", true, false),
            ("macos", "x86_64", true, true),
            ("windows", "x86_64", true, true),
            ("windows", "aarch64", false, false),
            ("freebsd", "x86_64", false, false),
        ];
        for (os, arch, install, boot) in cases {
            let c = capabilities(os, arch);
            assert_eq!(c.host_install.supported, install, "{os}/{arch} install");
            assert_eq!(c.boot.supported, boot, "{os}/{arch} boot");
        }
    }
}
