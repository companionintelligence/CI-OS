//! GRUB environment block (`grubenv`) encoding — the A/B slot pointer on the ESP.
//!
//! The format is GRUB's own (`grub-core/lib/envblk.c`): exactly 1024 bytes, starting with
//! the line `# GRUB Environment Block`, then one `name=value` line per variable, then `#`
//! padding to the end. In values, a backslash and a newline are escaped with a backslash.
//! GRUB's `load_env` refuses a block that is not exactly this shape, so the encoder is
//! strict about size and the decoder is strict about the header.
//!
//! `ci-stick` keeps two variables here: `active_slot` (`A` or `B`) and, optionally,
//! `extra_cmdline` (appended to the kernel command line; the QEMU tests set it to
//! `console=ttyS0,115200`, production leaves it unset). An A/B switch rewrites only this
//! 1 KiB file.

use anyhow::{bail, ensure};

pub const GRUBENV_SIZE: usize = 1024;
pub const HEADER: &str = "# GRUB Environment Block\n";

pub const VAR_ACTIVE_SLOT: &str = "active_slot";
pub const VAR_EXTRA_CMDLINE: &str = "extra_cmdline";

/// An A/B boot slot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum Slot {
    A,
    B,
}

impl Slot {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::A => "A",
            Self::B => "B",
        }
    }

    pub fn other(self) -> Self {
        match self {
            Self::A => Self::B,
            Self::B => Self::A,
        }
    }

    pub fn parse(s: &str) -> anyhow::Result<Self> {
        match s {
            "A" | "a" => Ok(Self::A),
            "B" | "b" => Ok(Self::B),
            other => bail!("slot must be A or B, not {other:?}"),
        }
    }
}

impl std::fmt::Display for Slot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// An ordered set of GRUB environment variables.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GrubEnv {
    vars: Vec<(String, String)>,
}

fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

impl GrubEnv {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, name: &str) -> Option<&str> {
        self.vars
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }

    /// Set (or replace in place) a variable.
    pub fn set(&mut self, name: &str, value: &str) -> anyhow::Result<()> {
        ensure!(valid_name(name), "invalid grubenv variable name {name:?}");
        match self.vars.iter_mut().find(|(k, _)| k == name) {
            Some(slot) => slot.1 = value.to_string(),
            None => self.vars.push((name.to_string(), value.to_string())),
        }
        Ok(())
    }

    pub fn remove(&mut self, name: &str) {
        self.vars.retain(|(k, _)| k != name);
    }

    pub fn vars(&self) -> &[(String, String)] {
        &self.vars
    }

    /// The active slot; `A` when unset (the grub.cfg default too).
    pub fn active_slot(&self) -> anyhow::Result<Slot> {
        self.get(VAR_ACTIVE_SLOT).map_or(Ok(Slot::A), Slot::parse)
    }

    /// Exactly [`GRUBENV_SIZE`] bytes in GRUB's format.
    pub fn encode(&self) -> anyhow::Result<Vec<u8>> {
        let mut out = HEADER.as_bytes().to_vec();
        for (k, v) in &self.vars {
            ensure!(valid_name(k), "invalid grubenv variable name {k:?}");
            out.extend_from_slice(k.as_bytes());
            out.push(b'=');
            for b in v.bytes() {
                if b == b'\\' || b == b'\n' {
                    out.push(b'\\');
                }
                out.push(b);
            }
            out.push(b'\n');
        }
        ensure!(
            out.len() <= GRUBENV_SIZE,
            "grubenv variables need {} bytes, more than the {GRUBENV_SIZE}-byte block",
            out.len()
        );
        out.resize(GRUBENV_SIZE, b'#');
        Ok(out)
    }

    /// Parse a GRUB environment block. Rejects anything GRUB itself would reject.
    pub fn decode(bytes: &[u8]) -> anyhow::Result<Self> {
        ensure!(
            bytes.len() == GRUBENV_SIZE,
            "grubenv is {} bytes; GRUB requires exactly {GRUBENV_SIZE}",
            bytes.len()
        );
        let Some(body) = bytes.strip_prefix(HEADER.as_bytes()) else {
            bail!("grubenv does not start with {:?}", HEADER.trim_end());
        };
        let mut env = GrubEnv::new();
        let mut i = 0;
        while i < body.len() {
            match body[i] {
                // Padding and comment lines.
                b'#' => {
                    while i < body.len() && body[i] != b'\n' {
                        i += 1;
                    }
                    i += 1;
                }
                b'\n' => i += 1,
                _ => {
                    let mut line = Vec::new();
                    while i < body.len() && body[i] != b'\n' {
                        if body[i] == b'\\' && i + 1 < body.len() {
                            i += 1;
                        }
                        line.push(body[i]);
                        i += 1;
                    }
                    ensure!(i < body.len(), "grubenv: unterminated variable line");
                    i += 1;
                    let line = String::from_utf8(line)
                        .map_err(|_| anyhow::anyhow!("grubenv: variable line is not UTF-8"))?;
                    let Some((k, v)) = line.split_once('=') else {
                        bail!("grubenv: line {line:?} has no '='");
                    };
                    env.set(k, v)?;
                }
            }
        }
        Ok(env)
    }
}

/// Characters allowed in `extra_cmdline`. It is expanded unquoted on the `linux` line, so
/// shell/GRUB metacharacters are refused rather than escaped.
pub fn validate_extra_cmdline(s: &str) -> anyhow::Result<()> {
    let bad = s.chars().find(|c| {
        !(c.is_ascii_graphic() || *c == ' ')
            || matches!(c, '"' | '\'' | '$' | '\\' | ';' | '{' | '}' | '`')
    });
    if let Some(c) = bad {
        bail!("--extra-cmdline may not contain {c:?}");
    }
    ensure!(s.len() <= 512, "--extra-cmdline is longer than 512 bytes");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_format() {
        let mut env = GrubEnv::new();
        env.set(VAR_ACTIVE_SLOT, "A").unwrap();
        let bytes = env.encode().unwrap();
        assert_eq!(bytes.len(), GRUBENV_SIZE);
        let expected_head = b"# GRUB Environment Block\nactive_slot=A\n";
        assert_eq!(&bytes[..expected_head.len()], expected_head);
        assert!(bytes[expected_head.len()..].iter().all(|&b| b == b'#'));
    }

    #[test]
    fn empty_env_matches_grub_editenv_create() {
        // `grub-editenv FILE create` writes exactly this.
        let bytes = GrubEnv::new().encode().unwrap();
        let mut expected = HEADER.as_bytes().to_vec();
        expected.resize(1024, b'#');
        assert_eq!(bytes, expected);
    }

    #[test]
    fn round_trip_with_escapes_and_order() {
        let mut env = GrubEnv::new();
        env.set(VAR_ACTIVE_SLOT, "B").unwrap();
        env.set(VAR_EXTRA_CMDLINE, "console=ttyS0,115200 panic=5")
            .unwrap();
        env.set("odd", "back\\slash\nnewline").unwrap();
        let back = GrubEnv::decode(&env.encode().unwrap()).unwrap();
        assert_eq!(back, env);
        assert_eq!(back.active_slot().unwrap(), Slot::B);
        assert_eq!(
            back.get(VAR_EXTRA_CMDLINE),
            Some("console=ttyS0,115200 panic=5")
        );
        // Replacing keeps position.
        let mut again = back.clone();
        again.set(VAR_ACTIVE_SLOT, "A").unwrap();
        assert_eq!(again.vars()[0], ("active_slot".into(), "A".into()));
    }

    #[test]
    fn rejects_bad_blocks() {
        assert!(GrubEnv::decode(&[b'#'; 1023]).is_err(), "wrong size");
        assert!(GrubEnv::decode(&[b'#'; 1024]).is_err(), "no header");
        let mut env = GrubEnv::new();
        env.set("big", &"x".repeat(1100)).unwrap();
        assert!(env.encode().is_err(), "too big for the block");
        assert!(env.set("bad name", "1").is_err());
        assert_eq!(GrubEnv::new().active_slot().unwrap(), Slot::A);
        let mut junk = GrubEnv::new();
        junk.set(VAR_ACTIVE_SLOT, "C").unwrap();
        assert!(junk.active_slot().is_err());
    }

    #[test]
    fn extra_cmdline_rules() {
        assert!(validate_extra_cmdline("console=ttyS0,115200 panic=5").is_ok());
        for bad in ["a;b", "$x", "a\nb", "\"q\"", "{x}"] {
            assert!(validate_extra_cmdline(bad).is_err(), "{bad:?}");
        }
    }
}
