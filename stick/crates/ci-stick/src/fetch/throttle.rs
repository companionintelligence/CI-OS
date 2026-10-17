//! A pacing limiter shared by every download thread: `--max-bytes-per-sec` is a limit on the
//! whole job, not per connection.

use std::sync::atomic::AtomicBool;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::net::sleep_unless_cancelled;

pub struct Throttle {
    rate: Option<u64>,
    /// When the bytes already granted will have been "sent" at the allowed rate.
    next: Mutex<Instant>,
}

impl Throttle {
    /// `None` or `Some(0)` means unlimited.
    pub fn new(bytes_per_sec: Option<u64>) -> Self {
        Self {
            rate: bytes_per_sec.filter(|r| *r > 0),
            next: Mutex::new(Instant::now()),
        }
    }

    pub fn unlimited() -> Self {
        Self::new(None)
    }

    pub fn rate(&self) -> Option<u64> {
        self.rate
    }

    /// Account for `n` bytes that were just received and wait until the allowed rate would
    /// have delivered them. Returns `false` if `cancel` was set while waiting.
    pub fn acquire(&self, n: u64, cancel: &AtomicBool) -> bool {
        let Some(rate) = self.rate else { return true };
        let cost = Duration::from_secs_f64(n as f64 / rate as f64);
        let wait = {
            let mut next = self.next.lock().unwrap_or_else(|e| e.into_inner());
            let now = Instant::now();
            let finish = (*next).max(now) + cost;
            *next = finish;
            finish.saturating_duration_since(now)
        };
        wait.is_zero() || sleep_unless_cancelled(wait, cancel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;
    use std::sync::Arc;

    #[test]
    fn unlimited_never_waits() {
        let t = Throttle::unlimited();
        let start = Instant::now();
        let cancel = AtomicBool::new(false);
        for _ in 0..1000 {
            assert!(t.acquire(1 << 20, &cancel));
        }
        assert!(start.elapsed() < Duration::from_millis(200));
        assert_eq!(Throttle::new(Some(0)).rate(), None);
    }

    #[test]
    fn paces_to_the_configured_rate() {
        let t = Throttle::new(Some(2_000_000));
        let cancel = AtomicBool::new(false);
        let start = Instant::now();
        for _ in 0..4 {
            assert!(t.acquire(100_000, &cancel));
        }
        let took = start.elapsed();
        assert!(
            took >= Duration::from_millis(180),
            "400 kB at 2 MB/s took only {took:?}"
        );
        assert!(took < Duration::from_millis(1500), "{took:?}");
    }

    #[test]
    fn the_limit_is_shared_between_threads() {
        let t = Arc::new(Throttle::new(Some(4_000_000)));
        let cancel = Arc::new(AtomicBool::new(false));
        let start = Instant::now();
        let handles: Vec<_> = (0..4)
            .map(|_| {
                let (t, c) = (t.clone(), cancel.clone());
                std::thread::spawn(move || {
                    for _ in 0..2 {
                        t.acquire(200_000, &c);
                    }
                })
            })
            .collect();
        for h in handles {
            h.join().unwrap();
        }
        // 4 threads x 400 kB = 1.6 MB at 4 MB/s
        assert!(
            start.elapsed() >= Duration::from_millis(350),
            "{:?}",
            start.elapsed()
        );
    }

    #[test]
    fn a_cancelled_wait_returns_false() {
        let t = Throttle::new(Some(1000));
        let cancel = AtomicBool::new(false);
        assert!(t.acquire(1, &cancel)); // tiny
        cancel.store(true, Ordering::Relaxed);
        let start = Instant::now();
        assert!(
            !t.acquire(100_000, &cancel),
            "100 kB at 1 kB/s would be 100 s"
        );
        assert!(start.elapsed() < Duration::from_secs(2));
    }
}
