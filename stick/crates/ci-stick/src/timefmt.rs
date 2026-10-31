//! Minimal RFC 3339 (UTC, second precision) formatting/parsing, so the manifest can carry
//! `created_at` and `expires_at` without pulling in a date/time crate.

use std::time::{SystemTime, UNIX_EPOCH};

/// The last instant a four-digit year can hold: `9999-12-31T23:59:59Z`.
const MAX_UNIX: u64 = 253_402_300_799;

/// `1970-01-01T00:00:00Z` style.
pub fn format_unix(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

pub fn now_rfc3339() -> String {
    format_unix(unix_now().unwrap_or(0))
}

/// Seconds since the Unix epoch on the system clock, `None` if the clock reads a time before
/// 1970 (a clock that cannot be believed: callers that enforce an expiry must refuse then).
pub fn unix_now() -> Option<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs())
}

/// Accepts exactly the shape [`format_unix`] produces.
pub fn is_rfc3339_utc(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 20 {
        return false;
    }
    let digits = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18];
    digits.iter().all(|&i| b[i].is_ascii_digit())
        && b[4] == b'-'
        && b[7] == b'-'
        && b[10] == b'T'
        && b[13] == b':'
        && b[16] == b':'
        && b[19] == b'Z'
}

/// Seconds since the Unix epoch for a string in the shape [`format_unix`] produces.
///
/// `None` for any other shape, for a date or time that does not exist (month 13, 30 February,
/// hour 24, a leap second `:60`) and for an instant before 1970, which a `u64` cannot hold.
pub fn parse_rfc3339_utc(s: &str) -> Option<u64> {
    if !is_rfc3339_utc(s) {
        return None;
    }
    let b = s.as_bytes();
    // `is_rfc3339_utc` guarantees ASCII digits at these positions.
    let two = |i: usize| u32::from(b[i] - b'0') * 10 + u32::from(b[i + 1] - b'0');
    let year = i64::from(two(0)) * 100 + i64::from(two(2));
    let (month, day) = (two(5), two(8));
    let (hour, minute, second) = (two(11), two(14), two(17));
    if !(1..=12).contains(&month)
        || day == 0
        || day > days_in_month(year, month)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    let days = u64::try_from(days_from_civil(year, month, day)).ok()?;
    Some(days * 86_400 + u64::from(hour) * 3600 + u64::from(minute) * 60 + u64::from(second))
}

/// `s` plus `days` whole days, in the same shape. `None` if `s` does not parse or the result
/// would not fit a four-digit year. This is how `lock` derives `expires_at` from `created_at`
/// (never from the wall clock, so the same inputs always give the same bytes).
pub fn plus_days_rfc3339(s: &str, days: u32) -> Option<String> {
    let secs = parse_rfc3339_utc(s)?.checked_add(u64::from(days) * 86_400)?;
    (secs <= MAX_UNIX).then(|| format_unix(secs))
}

fn is_leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

fn days_in_month(year: i64, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if is_leap(year) => 29,
        _ => 28,
    }
}

/// Howard Hinnant's days-from-civil (proleptic Gregorian): days since 1970-01-01.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (i64::from(m) + 9) % 12;
    let doy = (153 * mp + 2) / 5 + i64::from(d) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Howard Hinnant's days-from-civil inverse (proleptic Gregorian).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_known_instants() {
        assert_eq!(format_unix(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_unix(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(format_unix(1_790_000_000), "2026-09-21T14:13:20Z");
        assert!(is_rfc3339_utc(&now_rfc3339()));
        assert!(!is_rfc3339_utc("2026-09-21 14:13:20"));
    }

    #[test]
    fn parses_known_instants() {
        for (text, secs) in [
            ("1970-01-01T00:00:00Z", 0),
            ("1970-01-01T00:00:01Z", 1),
            ("2000-02-29T00:00:00Z", 951_782_400),
            ("2026-09-21T14:13:20Z", 1_790_000_000),
            ("2038-01-19T03:14:07Z", 2_147_483_647),
            ("9999-12-31T23:59:59Z", MAX_UNIX),
        ] {
            assert_eq!(parse_rfc3339_utc(text), Some(secs), "{text}");
        }
    }

    #[test]
    fn parse_and_format_agree_across_the_range() {
        // A stride that is not a multiple of a day, a week or a month visits every month length
        // and both kinds of year.
        let mut secs = 0u64;
        while secs <= MAX_UNIX {
            let text = format_unix(secs);
            assert_eq!(parse_rfc3339_utc(&text), Some(secs), "{text}");
            secs += 86_399 * 31 + 17;
        }
    }

    #[test]
    fn impossible_dates_and_times_do_not_parse() {
        for bad in [
            "2026-13-01T00:00:00Z",
            "2026-00-10T00:00:00Z",
            "2026-04-31T00:00:00Z",
            "2026-02-29T00:00:00Z",
            "1900-02-29T00:00:00Z",
            "2100-02-29T00:00:00Z",
            "2026-01-00T00:00:00Z",
            "2026-01-32T00:00:00Z",
            "2026-01-01T24:00:00Z",
            "2026-01-01T00:60:00Z",
            "2026-01-01T00:00:60Z",
            "1969-12-31T23:59:59Z",
            "0000-01-01T00:00:00Z",
            "2026-09-21 14:13:20",
            "2026-09-21T14:13:20+00:00",
            "2026-09-21T14:13:20.5Z",
            "",
        ] {
            assert_eq!(parse_rfc3339_utc(bad), None, "{bad:?}");
        }
        // The leap days that do exist.
        assert!(parse_rfc3339_utc("2000-02-29T00:00:00Z").is_some());
        assert!(parse_rfc3339_utc("2024-02-29T23:59:59Z").is_some());
    }

    #[test]
    fn adds_whole_days_without_the_clock() {
        // 2020 is a leap year: 365 days from 1 January is 30 December.
        assert_eq!(
            plus_days_rfc3339("2020-01-01T00:00:00Z", 365).as_deref(),
            Some("2020-12-31T00:00:00Z")
        );
        assert_eq!(
            plus_days_rfc3339("2020-01-01T00:00:00Z", 30).as_deref(),
            Some("2020-01-31T00:00:00Z")
        );
        assert_eq!(
            plus_days_rfc3339("2026-09-28T12:00:00Z", 365).as_deref(),
            Some("2027-09-28T12:00:00Z")
        );
        assert_eq!(plus_days_rfc3339("not a date", 1), None);
        assert_eq!(plus_days_rfc3339("9999-12-31T00:00:00Z", 1), None);
        assert_eq!(plus_days_rfc3339("2026-01-01T00:00:00Z", u32::MAX), None);
    }

    #[test]
    fn the_system_clock_is_after_the_epoch() {
        assert!(unix_now().is_some_and(|n| n > 1_700_000_000));
    }
}
