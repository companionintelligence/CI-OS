//! Byte-size parsing and formatting.
//!
//! Storage is marketed in decimal units (a "512 GB" stick is 512 × 10⁹ bytes ≈ 476.8 GiB)
//! while partition tools think in binary units. Both are accepted, and the unit must be
//! explicit about which one it means: `GB` = 10⁹, `GiB` = 2³⁰. A bare number is bytes.
//! Single-letter units (`G`, `T`) are rejected because they are ambiguous.

use thiserror::Error;

pub const KIB: u64 = 1 << 10;
pub const MIB: u64 = 1 << 20;
pub const GIB: u64 = 1 << 30;
pub const TIB: u64 = 1 << 40;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SizeError {
    #[error("empty size")]
    Empty,
    #[error("invalid number in size {0:?}")]
    BadNumber(String),
    #[error("unknown unit {unit:?} in {input:?}: use B, KB/MB/GB/TB (powers of 10) or KiB/MiB/GiB/TiB (powers of 2)")]
    BadUnit { input: String, unit: String },
    #[error("size {0:?} is too large")]
    Overflow(String),
    #[error("size {0:?} has a fractional byte count")]
    FractionalBytes(String),
}

fn unit_multiplier(unit: &str) -> Option<u64> {
    let m = match unit.to_ascii_lowercase().as_str() {
        "" | "b" => 1,
        "kb" => 1_000,
        "mb" => 1_000_000,
        "gb" => 1_000_000_000,
        "tb" => 1_000_000_000_000,
        "kib" => KIB,
        "mib" => MIB,
        "gib" => GIB,
        "tib" => TIB,
        _ => return None,
    };
    Some(m)
}

/// Parse `512GB`, `476GiB`, `476.8 GiB`, `1TB`, or a plain byte count.
///
/// Fractions are computed exactly (no floating point) and truncated to whole bytes.
pub fn parse_size(input: &str) -> Result<u64, SizeError> {
    let s = input.trim();
    if s.is_empty() {
        return Err(SizeError::Empty);
    }
    let split = s
        .find(|c: char| !(c.is_ascii_digit() || c == '.' || c == '_'))
        .unwrap_or(s.len());
    let (num, unit) = s.split_at(split);
    let num: String = num.chars().filter(|&c| c != '_').collect();
    let unit = unit.trim();
    let mult = unit_multiplier(unit).ok_or_else(|| SizeError::BadUnit {
        input: input.to_string(),
        unit: unit.to_string(),
    })?;

    let (int_part, frac_part) = match num.split_once('.') {
        Some((i, f)) => (i, f),
        None => (num.as_str(), ""),
    };
    if int_part.is_empty() && frac_part.is_empty() {
        return Err(SizeError::BadNumber(input.to_string()));
    }
    if frac_part.contains('.') || frac_part.len() > 18 {
        return Err(SizeError::BadNumber(input.to_string()));
    }
    let int: u128 = if int_part.is_empty() {
        0
    } else {
        int_part
            .parse()
            .map_err(|_| SizeError::BadNumber(input.to_string()))?
    };
    let mut total: u128 = int
        .checked_mul(u128::from(mult))
        .ok_or_else(|| SizeError::Overflow(input.to_string()))?;
    if !frac_part.is_empty() {
        if mult == 1 {
            return Err(SizeError::FractionalBytes(input.to_string()));
        }
        let frac: u128 = frac_part
            .parse()
            .map_err(|_| SizeError::BadNumber(input.to_string()))?;
        let scale = 10u128.pow(frac_part.len() as u32);
        total += frac * u128::from(mult) / scale;
    }
    u64::try_from(total).map_err(|_| SizeError::Overflow(input.to_string()))
}

/// `476.8 GiB` style, one decimal, binary units.
pub fn fmt_binary(bytes: u64) -> String {
    const UNITS: [(&str, u64); 4] = [("TiB", TIB), ("GiB", GIB), ("MiB", MIB), ("KiB", KIB)];
    for (name, unit) in UNITS {
        if bytes >= unit {
            return format!("{} {name}", one_decimal(bytes, unit));
        }
    }
    format!("{bytes} B")
}

/// `512.1 GB` style, one decimal, decimal units.
pub fn fmt_decimal(bytes: u64) -> String {
    const UNITS: [(&str, u64); 4] = [
        ("TB", 1_000_000_000_000),
        ("GB", 1_000_000_000),
        ("MB", 1_000_000),
        ("kB", 1_000),
    ];
    for (name, unit) in UNITS {
        if bytes >= unit {
            return format!("{} {name}", one_decimal(bytes, unit));
        }
    }
    format!("{bytes} B")
}

/// Exact integer rendering of `bytes / unit` to one decimal place (rounded half up),
/// dropping a trailing `.0`.
fn one_decimal(bytes: u64, unit: u64) -> String {
    let tenths = (u128::from(bytes) * 10 + u128::from(unit) / 2) / u128::from(unit);
    let whole = tenths / 10;
    let frac = tenths % 10;
    if frac == 0 {
        format!("{whole}")
    } else {
        format!("{whole}.{frac}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_decimal_and_binary_units() {
        assert_eq!(parse_size("512GB").unwrap(), 512_000_000_000);
        assert_eq!(parse_size("512 gb").unwrap(), 512_000_000_000);
        assert_eq!(parse_size("476GiB").unwrap(), 476 * GIB);
        assert_eq!(parse_size("1TB").unwrap(), 1_000_000_000_000);
        assert_eq!(parse_size("1.5GiB").unwrap(), GIB + GIB / 2);
        assert_eq!(parse_size("4096").unwrap(), 4096);
        assert_eq!(parse_size("1_000B").unwrap(), 1000);
    }

    #[test]
    fn rejects_ambiguous_or_bad_input() {
        assert!(matches!(parse_size("512G"), Err(SizeError::BadUnit { .. })));
        assert!(matches!(parse_size(""), Err(SizeError::Empty)));
        assert!(matches!(parse_size("GB"), Err(SizeError::BadNumber(_))));
        assert!(matches!(
            parse_size("1.2.3GB"),
            Err(SizeError::BadNumber(_))
        ));
        assert!(matches!(
            parse_size("1.5"),
            Err(SizeError::FractionalBytes(_))
        ));
        assert!(matches!(
            parse_size("99999999999TiB"),
            Err(SizeError::Overflow(_))
        ));
    }

    #[test]
    fn formats() {
        assert_eq!(fmt_binary(512_000_000_000), "476.8 GiB");
        assert_eq!(fmt_decimal(512_000_000_000), "512 GB");
        assert_eq!(fmt_binary(2 * GIB), "2 GiB");
        assert_eq!(fmt_binary(12), "12 B");
    }
}
