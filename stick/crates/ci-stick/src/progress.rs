//! Progress reporting for long hashing runs. Only draws when stderr is a terminal, so
//! piped/CI/`--json` consumers never see carriage-return noise.

use std::io::{IsTerminal, Write};
use std::time::{Duration, Instant};

use crate::size::fmt_binary;

pub struct Progress {
    enabled: bool,
    last_draw: Option<Instant>,
    total_items: usize,
}

impl Progress {
    /// Draws on stderr iff it is a TTY.
    pub fn auto(total_items: usize) -> Self {
        Self {
            enabled: std::io::stderr().is_terminal(),
            last_draw: None,
            total_items,
        }
    }

    pub fn disabled() -> Self {
        Self {
            enabled: false,
            last_draw: None,
            total_items: 0,
        }
    }

    pub fn set_total(&mut self, total_items: usize) {
        self.total_items = total_items;
    }

    /// Report `done` of `size` bytes for item number `item` (1-based). Throttled to ~10 Hz.
    pub fn update(&mut self, item: usize, name: &str, done: u64, size: u64) {
        if !self.enabled {
            return;
        }
        let now = Instant::now();
        if let Some(last) = self.last_draw {
            if now.duration_since(last) < Duration::from_millis(100) && done < size {
                return;
            }
        }
        self.last_draw = Some(now);
        let pct = done.saturating_mul(100).checked_div(size).unwrap_or(100);
        let mut name = name.to_string();
        if name.chars().count() > 48 {
            let tail: String = name
                .chars()
                .rev()
                .take(47)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            name = format!("…{tail}");
        }
        let _ = write!(
            std::io::stderr(),
            "\r\x1b[2K[{item}/{}] {name} {pct:>3}% ({} / {})",
            self.total_items,
            fmt_binary(done),
            fmt_binary(size)
        );
    }

    /// Clear the progress line.
    pub fn finish(&mut self) {
        if self.enabled && self.last_draw.is_some() {
            let _ = write!(std::io::stderr(), "\r\x1b[2K");
            let _ = std::io::stderr().flush();
            self.last_draw = None;
        }
    }
}
