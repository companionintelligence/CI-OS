//! External tools `flash` and `slot` drive (gdisk, dosfstools, exfatprogs, e2fsprogs,
//! mtools). None of them needs root when pointed at image files, and none of them is
//! ever asked to mount anything.

use std::ffi::OsStr;
use std::path::Path;
use std::process::Command;

use anyhow::{bail, Context as _};

/// `(binary, Debian/Ubuntu package)` for everything `flash` runs.
pub const FLASH_TOOLS: [(&str, &str); 6] = [
    ("sgdisk", "gdisk"),
    ("mkfs.vfat", "dosfstools"),
    ("mkfs.exfat", "exfatprogs"),
    ("mkfs.ext4", "e2fsprogs"),
    ("mcopy", "mtools"),
    ("mmd", "mtools"),
];

/// What `slot` runs.
pub const SLOT_TOOLS: [(&str, &str); 1] = [("mcopy", "mtools")];

/// `true` if `name` is an executable on `PATH` (or in the sbin directories, which are
/// often missing from a normal user's `PATH`).
pub fn find(name: &str) -> Option<std::path::PathBuf> {
    let mut dirs: Vec<std::path::PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    for extra in ["/usr/sbin", "/sbin", "/usr/local/sbin"] {
        dirs.push(extra.into());
    }
    dirs.into_iter().map(|d| d.join(name)).find(|p| p.is_file())
}

/// Error listing every missing tool and the packages that provide them.
pub fn require(tools: &[(&str, &str)]) -> anyhow::Result<()> {
    let missing: Vec<&(&str, &str)> = tools.iter().filter(|(t, _)| find(t).is_none()).collect();
    if missing.is_empty() {
        return Ok(());
    }
    let mut pkgs: Vec<&str> = missing.iter().map(|(_, p)| *p).collect();
    pkgs.sort_unstable();
    pkgs.dedup();
    bail!(
        "missing tools: {} — install them (Debian/Ubuntu: sudo apt-get install {})",
        missing
            .iter()
            .map(|(t, _)| *t)
            .collect::<Vec<_>>()
            .join(", "),
        pkgs.join(" ")
    )
}

/// Run a tool to completion; on failure, the error carries its stderr.
pub fn run<I, S>(tool: &str, args: I) -> anyhow::Result<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let path = find(tool).with_context(|| format!("{tool} not found"))?;
    let args: Vec<std::ffi::OsString> = args.into_iter().map(|a| a.as_ref().to_owned()).collect();
    let out = Command::new(&path)
        .args(&args)
        // mtools: don't refuse images whose geometry it finds unusual; ignore ~/.mtoolsrc.
        .env("MTOOLS_SKIP_CHECK", "1")
        .env("MTOOLSRC", "/dev/null")
        .env("LC_ALL", "C")
        .output()
        .with_context(|| format!("running {}", path.display()))?;
    if !out.status.success() {
        bail!(
            "{tool} {} failed ({}): {}",
            args.iter()
                .map(|a| a.to_string_lossy())
                .collect::<Vec<_>>()
                .join(" "),
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// mtools drive spec for a FAT filesystem at `offset` inside `image` (`image@@offset`).
pub fn mtools_image(image: &Path, offset: u64) -> std::ffi::OsString {
    let mut s = image.as_os_str().to_owned();
    if offset > 0 {
        s.push(format!("@@{offset}"));
    }
    s
}
