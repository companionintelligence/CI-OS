//! Downloading one blob: resumable, verified, bounded in memory.
//!
//! # Protocol
//!
//! The blob is fetched with a series of **ranged GETs** of adaptive size (about eight seconds
//! of transfer each, between 1 MiB and 64 MiB). The first goes to the registry's blob URL,
//! which answers `307` to a presigned CDN URL (Cloudflare R2 for Ollama: 24 h, S3 style);
//! that final URL is remembered and the following chunks go straight to it. A `401`/`403`
//! from a remembered URL means it expired: the registry is asked again, transparently.
//! Chunking bounds every request by a timeout, which is how a stalled connection is
//! detected without a watchdog thread (`stall_timeout` plus three times the expected
//! duration of the chunk).
//!
//! * `206` with the exact `Content-Range` is the normal answer.
//! * `200` to a ranged request means the server ignores `Range`: accepted only for a request
//!   starting at 0 (then the whole body is read as one stream and a body longer than the
//!   locked size is an integrity failure); otherwise the transfer restarts from zero.
//! * `416` with `*/<n>` where `n` differs from the locked size means the registry's blob is
//!   not the locked one (integrity failure).
//! * `404` is permanent; `429` and `5xx` are retried with back-off honouring `Retry-After`;
//!   so are timeouts, resets and short bodies. Progress made before a failure is kept, and
//!   an attempt that advanced resets the attempt counter.
//!
//! # Safety properties
//!
//! * Bytes are hashed as they are appended; nothing is trusted until SHA-256 matches the
//!   digest from the lock, and only then is the partial renamed to `models/blobs/sha256-<hex>`.
//! * The partial lives in `ci-models/partial/`, outside the directory Ollama prunes.
//! * The journal says how many bytes are durable (`fsync` first, journal second). Resuming
//!   cuts the data back to the journal, re-reads and re-hashes that prefix from disk, then
//!   continues. If the final hash is wrong after a resume, the partial is thrown away and the
//!   blob is downloaded once more from zero before giving up.
//! * Memory is one buffer per thread.

use std::io::Read;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use sha2::{Digest as _, Sha256};

use crate::cache::partial::{read_journal, remove_partial, write_journal, Journal};
use crate::cache::sink::{is_no_space, BlobSink, SinkFactory};
use crate::cache::store::Store;
use crate::fetch::throttle::Throttle;
use crate::net::{
    parse_retry_after, sleep_unless_cancelled, Method, NetError, NetErrorKind, RetryPolicy, Url,
};
use crate::registry::RegistryClient;

const MIB: u64 = 1 << 20;

#[derive(Debug, Clone)]
pub struct ChunkPolicy {
    pub initial: u64,
    pub max: u64,
    /// Aim for chunks that take about this long at the measured rate.
    pub target: Duration,
}

impl Default for ChunkPolicy {
    fn default() -> Self {
        Self {
            initial: MIB,
            max: 64 * MIB,
            target: Duration::from_secs(8),
        }
    }
}

#[derive(Debug, Clone)]
pub struct TransferOptions {
    pub retry: RetryPolicy,
    pub chunk: ChunkPolicy,
    /// Added to the expected duration of a chunk to get its timeout.
    pub stall_timeout: Duration,
    /// `fsync` and write the journal after this many bytes.
    pub journal_every: u64,
    /// Read buffer size.
    pub buffer: usize,
}

impl Default for TransferOptions {
    fn default() -> Self {
        Self {
            retry: RetryPolicy::default(),
            chunk: ChunkPolicy::default(),
            stall_timeout: Duration::from_secs(30),
            journal_every: 64 * MIB,
            buffer: 256 * 1024,
        }
    }
}

pub struct DownloadCtx<'a> {
    pub client: &'a RegistryClient,
    pub store: &'a Store,
    pub sinks: &'a dyn SinkFactory,
    pub throttle: &'a Throttle,
    pub opts: &'a TransferOptions,
}

#[derive(Debug, Clone, Copy)]
pub struct BlobJob<'a> {
    pub hex: &'a str,
    /// `sha256:<hex>`
    pub digest: &'a str,
    pub size: u64,
    /// Repository path for the URL, e.g. `library/gemma3`.
    pub repo: &'a str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlobResult {
    /// Already complete in the cache.
    Skipped,
    /// Completed by this call; `fetched` bytes crossed the network.
    Downloaded { fetched: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DlError {
    Cancelled,
    NoSpace(String),
    Integrity(String),
    /// Retries exhausted on network trouble; the partial is kept.
    Transient(String),
    Offline,
    /// A definite refusal (404, policy, malformed answer).
    Fatal(String),
    /// Another disk error.
    Io(String),
}

impl DlError {
    /// The process exit code this error maps to (see `cmd_models`).
    pub fn exit_code(&self) -> u8 {
        match self {
            DlError::Integrity(_) => 7,
            DlError::NoSpace(_) => 4,
            DlError::Cancelled | DlError::Transient(_) | DlError::Offline => 6,
            DlError::Fatal(_) | DlError::Io(_) => 1,
        }
    }

    pub fn code(&self) -> &'static str {
        match self {
            DlError::Cancelled => "interrupted",
            DlError::NoSpace(_) => "space",
            DlError::Integrity(_) => "integrity",
            DlError::Transient(_) => "net",
            DlError::Offline => "offline",
            DlError::Fatal(_) => "fatal",
            DlError::Io(_) => "io",
        }
    }

    /// Errors after which the other downloads cannot succeed either.
    pub fn stops_the_job(&self) -> bool {
        matches!(
            self,
            DlError::Cancelled | DlError::NoSpace(_) | DlError::Transient(_) | DlError::Offline
        )
    }
}

impl std::fmt::Display for DlError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DlError::Cancelled => f.write_str("interrupted; the download can be resumed"),
            DlError::Offline => f.write_str("offline mode: the network is needed but not allowed"),
            DlError::NoSpace(m)
            | DlError::Integrity(m)
            | DlError::Transient(m)
            | DlError::Fatal(m)
            | DlError::Io(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for DlError {}

/// What the caller is told while a blob downloads.
#[derive(Debug, Clone)]
pub enum Obs {
    /// Resumed from a validated prefix of this many bytes.
    Resumed(u64),
    /// The transfer started over (server ignored `Range`, or the prefix was bad).
    Restarted,
    Progress {
        done: u64,
        delta: u64,
    },
    Retry {
        in_s: u64,
        reason: String,
    },
}

fn map_io(e: &std::io::Error, what: &str) -> DlError {
    if is_no_space(e) {
        DlError::NoSpace(format!("{what}: no space left on the cache volume ({e})"))
    } else {
        DlError::Io(format!("{what}: {e}"))
    }
}

enum ChunkErr {
    Retry {
        reason: String,
        retry_after: Option<Duration>,
        progressed: u64,
    },
    Restart,
    Fatal(DlError),
}

struct Transfer<'a> {
    ctx: &'a DownloadCtx<'a>,
    job: BlobJob<'a>,
    sink: Box<dyn BlobSink>,
    data_path: PathBuf,
    journal_path: PathBuf,
    hasher: Sha256,
    /// Bytes appended and hashed.
    pos: u64,
    /// Bytes covered by the journal.
    journaled: u64,
    since_sync: u64,
    blob_url: Url,
    /// Where the registry's redirect led (a presigned URL: keep out of logs).
    cdn: Option<Url>,
    source: String,
    rate: f64,
    fetched: u64,
    resumed_from: u64,
}

/// `bytes a-b/total` -> `(a, b, total)`.
pub fn parse_content_range(v: &str) -> Option<(u64, u64, Option<u64>)> {
    let rest = v.trim().strip_prefix("bytes")?.trim_start();
    let (range, total) = rest.split_once('/')?;
    let (a, b) = range.trim().split_once('-')?;
    let total = match total.trim() {
        "*" => None,
        t => Some(t.parse().ok()?),
    };
    Some((a.trim().parse().ok()?, b.trim().parse().ok()?, total))
}

/// `bytes */total` of a 416 answer.
fn parse_unsatisfied_total(v: &str) -> Option<u64> {
    v.trim()
        .strip_prefix("bytes")?
        .trim_start()
        .strip_prefix("*/")?
        .trim()
        .parse()
        .ok()
}

impl<'a> Transfer<'a> {
    fn open(
        ctx: &'a DownloadCtx<'a>,
        job: BlobJob<'a>,
        obs: &mut dyn FnMut(Obs),
    ) -> Result<Self, DlError> {
        let layout = ctx.store.layout();
        let data_path = layout
            .partial_path(job.hex)
            .map_err(|e| DlError::Fatal(e.to_string()))?;
        let journal_path = layout
            .journal_path(job.hex)
            .map_err(|e| DlError::Fatal(e.to_string()))?;
        let blob_url = ctx.client.blob_url(job.repo, job.digest);
        let mut sink = ctx
            .sinks
            .open(&data_path)
            .map_err(|e| map_io(&e, "opening the partial file"))?;
        let on_disk = sink
            .size()
            .map_err(|e| map_io(&e, "reading the partial file"))?;
        let mut committed = read_journal(&journal_path)
            .filter(|j| j.matches(job.hex, job.size))
            .map_or(0, |j| j.committed);
        if committed > on_disk {
            // the data the journal vouches for is gone: do not trust any of it
            committed = 0;
        }
        if on_disk > committed {
            sink.truncate(committed)
                .map_err(|e| map_io(&e, "trimming the partial file"))?;
        }
        let mut hasher = Sha256::new();
        if committed > 0
            && sink
                .read_prefix(committed, &mut |chunk| hasher.update(chunk))
                .is_err()
        {
            // unreadable prefix: start over
            hasher = Sha256::new();
            committed = 0;
            sink.truncate(0)
                .map_err(|e| map_io(&e, "resetting the partial file"))?;
        }
        if committed > 0 {
            obs(Obs::Resumed(committed));
        }
        let source = blob_url.redacted();
        Ok(Self {
            ctx,
            job,
            sink,
            data_path,
            journal_path,
            hasher,
            pos: committed,
            journaled: committed,
            since_sync: 0,
            blob_url,
            cdn: None,
            source,
            rate: 0.0,
            fetched: 0,
            resumed_from: committed,
        })
    }

    /// Make everything appended so far durable, then record it in the journal.
    fn checkpoint(&mut self) -> Result<(), DlError> {
        if self.pos == self.journaled {
            return Ok(());
        }
        self.sink
            .sync()
            .map_err(|e| map_io(&e, "syncing the partial file"))?;
        let j = Journal::new(self.job.hex, self.job.size, self.pos, &self.source);
        write_journal(&self.journal_path, &j)
            .map_err(|e| map_io(&e, "writing the resume journal"))?;
        self.journaled = self.pos;
        self.since_sync = 0;
        Ok(())
    }

    fn reset(&mut self) -> Result<(), DlError> {
        self.sink
            .truncate(0)
            .map_err(|e| map_io(&e, "resetting the partial file"))?;
        self.hasher = Sha256::new();
        self.pos = 0;
        self.journaled = 0;
        self.since_sync = 0;
        self.cdn = None;
        let _ = std::fs::remove_file(&self.journal_path);
        Ok(())
    }

    fn chunk_len(&self) -> u64 {
        let remaining = self.job.size - self.pos;
        let p = &self.ctx.opts.chunk;
        let want = if self.rate > 0.0 {
            (self.rate * p.target.as_secs_f64()) as u64
        } else {
            p.initial
        };
        want.clamp(p.initial, p.max.max(p.initial)).min(remaining)
    }

    fn chunk_timeout(&self, len: u64) -> Duration {
        let rate = self.rate.max(64.0 * 1024.0);
        let expected = Duration::from_secs_f64((3.0 * len as f64 / rate).min(3600.0));
        self.ctx.opts.stall_timeout + expected
    }

    fn fetch_chunk(&mut self, obs: &mut dyn FnMut(Obs)) -> Result<u64, ChunkErr> {
        let started = Instant::now();
        let start = self.pos;
        let want = self.chunk_len();
        let end = start + want - 1;
        let timeout = self.chunk_timeout(want);
        let headers = vec![("Range".to_string(), format!("bytes={start}-{end}"))];
        let fetcher = self.ctx.client.fetcher();
        let mut re_resolved = 0;
        let (resp, final_url) = loop {
            let (url, cached) = match &self.cdn {
                Some(u) => (u.clone(), true),
                None => (self.blob_url.clone(), false),
            };
            let (resp, fin) = match fetcher.send(Method::Get, &url, &headers, timeout) {
                Ok(r) => r,
                Err(e) => return Err(net_to_chunk_err(&e)),
            };
            if cached && matches!(resp.status, 401 | 403 | 404 | 410) && re_resolved < 2 {
                // an expired presigned URL: ask the registry for a fresh one
                self.cdn = None;
                re_resolved += 1;
                continue;
            }
            break (resp, fin);
        };
        let size = self.job.size;
        let retry_after = resp.header("retry-after").and_then(parse_retry_after);
        let (expected, whole_body) = match resp.status {
            206 => {
                let Some((a, b, total)) =
                    resp.header("content-range").and_then(parse_content_range)
                else {
                    return Err(ChunkErr::Retry {
                        reason: "206 answer without a usable Content-Range".into(),
                        retry_after,
                        progressed: 0,
                    });
                };
                if total.is_some_and(|t| t != size) {
                    return Err(ChunkErr::Fatal(DlError::Integrity(format!(
                        "the server holds {} bytes for sha256:{}, the lock says {size}",
                        total.unwrap_or(0),
                        self.job.hex
                    ))));
                }
                if a != start || b < a || b > end || b >= size {
                    return Err(ChunkErr::Retry {
                        reason: format!(
                            "unexpected Content-Range {a}-{b} for a request of {start}-{end}"
                        ),
                        retry_after,
                        progressed: 0,
                    });
                }
                if resp.content_length().is_some_and(|cl| cl != b - a + 1) {
                    return Err(ChunkErr::Retry {
                        reason: "Content-Length disagrees with Content-Range".into(),
                        retry_after,
                        progressed: 0,
                    });
                }
                (b - a + 1, false)
            }
            200 => {
                if start != 0 {
                    // the server ignores Range and we are mid-file: begin again
                    return Err(ChunkErr::Restart);
                }
                if resp.content_length().is_some_and(|cl| cl != size) {
                    return Err(ChunkErr::Fatal(DlError::Integrity(format!(
                        "the server's body for sha256:{} is {} bytes, the lock says {size}",
                        self.job.hex,
                        resp.content_length().unwrap_or(0)
                    ))));
                }
                (size, true)
            }
            416 => {
                let total = resp
                    .header("content-range")
                    .and_then(parse_unsatisfied_total);
                return Err(match total {
                    Some(t) if t != size => ChunkErr::Fatal(DlError::Integrity(format!(
                        "the server holds {t} bytes for sha256:{}, the lock says {size}",
                        self.job.hex
                    ))),
                    _ => ChunkErr::Retry {
                        reason: "416 Range Not Satisfiable".into(),
                        retry_after,
                        progressed: 0,
                    },
                });
            }
            404 | 410 => {
                return Err(ChunkErr::Fatal(DlError::Fatal(format!(
                    "the registry has no blob sha256:{} ({})",
                    self.job.hex,
                    final_url.redacted()
                ))))
            }
            401 | 403 => {
                return Err(ChunkErr::Fatal(DlError::Fatal(format!(
                    "access to sha256:{} was refused (HTTP {}) at {}",
                    self.job.hex,
                    resp.status,
                    final_url.redacted()
                ))))
            }
            429 => {
                return Err(ChunkErr::Retry {
                    reason: "HTTP 429 (rate limited)".into(),
                    retry_after,
                    progressed: 0,
                })
            }
            s if s >= 500 => {
                return Err(ChunkErr::Retry {
                    reason: format!("HTTP {s}"),
                    retry_after,
                    progressed: 0,
                })
            }
            s => {
                return Err(ChunkErr::Fatal(DlError::Fatal(format!(
                    "unexpected HTTP {s} for sha256:{} at {}",
                    self.job.hex,
                    final_url.redacted()
                ))))
            }
        };
        // Good answer: remember the (possibly redirected) URL for the next chunk.
        if self.cdn.is_none() {
            self.cdn = Some(final_url);
        }
        let mut body = resp.body;
        let got = self.drain(&mut *body, expected, obs)?;
        if whole_body {
            // exactly `size` bytes were promised; anything more is not the locked blob
            let mut probe = [0u8; 1];
            if matches!(body.read(&mut probe), Ok(n) if n > 0) {
                let _ = self.checkpoint();
                return Err(ChunkErr::Fatal(DlError::Integrity(format!(
                    "the server sent more than the locked {size} bytes for sha256:{}",
                    self.job.hex
                ))));
            }
        }
        let secs = started.elapsed().as_secs_f64().max(0.001);
        let inst = got as f64 / secs;
        self.rate = if self.rate == 0.0 {
            inst
        } else {
            0.5 * self.rate + 0.5 * inst
        };
        Ok(got)
    }

    /// Copy exactly `expected` bytes from `body` into the sink.
    fn drain(
        &mut self,
        body: &mut dyn Read,
        expected: u64,
        obs: &mut dyn FnMut(Obs),
    ) -> Result<u64, ChunkErr> {
        let cancel = self.ctx.client.cancel_flag().clone();
        let mut buf = vec![0u8; self.ctx.opts.buffer.max(4096)];
        let mut got = 0u64;
        while got < expected {
            if cancel.load(Ordering::Relaxed) {
                let _ = self.checkpoint();
                return Err(ChunkErr::Fatal(DlError::Cancelled));
            }
            let want = (expected - got).min(buf.len() as u64) as usize;
            let n = match body.read(&mut buf[..want]) {
                Ok(0) => {
                    return Err(ChunkErr::Retry {
                        reason: format!("connection closed after {got} of {expected} bytes"),
                        retry_after: None,
                        progressed: got,
                    })
                }
                Ok(n) => n,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) => {
                    return Err(ChunkErr::Retry {
                        reason: crate::net::io_error_to_net(&e).message,
                        retry_after: None,
                        progressed: got,
                    })
                }
            };
            if let Err(e) = self.sink.append(&buf[..n]) {
                let _ = self.checkpoint();
                return Err(ChunkErr::Fatal(map_io(&e, "writing the partial file")));
            }
            self.hasher.update(&buf[..n]);
            self.pos += n as u64;
            got += n as u64;
            self.fetched += n as u64;
            self.since_sync += n as u64;
            obs(Obs::Progress {
                done: self.pos,
                delta: n as u64,
            });
            if self.since_sync >= self.ctx.opts.journal_every {
                self.checkpoint().map_err(ChunkErr::Fatal)?;
            }
            // pace to --max-bytes-per-sec; a cancel during the wait keeps what we have
            if !self.ctx.throttle.acquire(n as u64, &cancel) {
                let _ = self.checkpoint();
                return Err(ChunkErr::Fatal(DlError::Cancelled));
            }
        }
        Ok(got)
    }

    /// All bytes are here: verify, then move into the store.
    fn finish(&mut self) -> Result<bool, DlError> {
        self.sink
            .sync()
            .map_err(|e| map_io(&e, "syncing the partial file"))?;
        // The hash covers the bytes this process appended; the file must hold exactly those.
        let on_disk = self
            .sink
            .size()
            .map_err(|e| map_io(&e, "reading the partial file"))?;
        let got = hex::encode(self.hasher.clone().finalize());
        if got != self.job.hex || on_disk != self.job.size {
            return Ok(false);
        }
        self.ctx
            .store
            .commit_blob(&self.data_path, self.job.hex)
            .map_err(|e| map_io(&e, "moving the finished blob into place"))?;
        let _ = std::fs::remove_file(&self.journal_path);
        Ok(true)
    }
}

fn net_to_chunk_err(e: &NetError) -> ChunkErr {
    if e.is_transient() {
        ChunkErr::Retry {
            reason: e.message.clone(),
            retry_after: None,
            progressed: 0,
        }
    } else if e.kind == NetErrorKind::Policy {
        ChunkErr::Fatal(DlError::Fatal(format!(
            "blocked by the network policy: {}",
            e.message
        )))
    } else {
        ChunkErr::Fatal(DlError::Fatal(e.message.clone()))
    }
}

/// Download one blob into the store. `obs` is told about resumption, progress and retries.
pub fn download_blob(
    ctx: &DownloadCtx<'_>,
    job: BlobJob<'_>,
    obs: &mut dyn FnMut(Obs),
) -> Result<BlobResult, DlError> {
    match ctx.store.blob_len(job.hex) {
        Ok(Some(n)) if n == job.size => return Ok(BlobResult::Skipped),
        Ok(_) => {}
        Err(e) => return Err(map_io(&e, "checking the cache")),
    }
    if job.size == 0 {
        if hex::encode(Sha256::digest([])) != job.hex {
            return Err(DlError::Integrity(format!(
                "sha256:{} is not the digest of an empty blob",
                job.hex
            )));
        }
        ctx.store
            .write_blob_bytes(job.hex, &[])
            .map_err(|e| map_io(&e, "writing an empty blob"))?;
        return Ok(BlobResult::Downloaded { fetched: 0 });
    }
    let cancel = ctx.client.cancel_flag().clone();
    let mut t = Transfer::open(ctx, job, obs)?;
    let mut attempt = 0u32;
    let mut clean_restarts = 0u32;
    loop {
        if t.pos == job.size {
            if t.finish()? {
                return Ok(BlobResult::Downloaded { fetched: t.fetched });
            }
            // wrong bytes: if we resumed, the stored prefix may be the culprit, so try once clean
            if t.resumed_from > 0 && clean_restarts == 0 {
                clean_restarts += 1;
                t.resumed_from = 0;
                t.reset()?;
                obs(Obs::Restarted);
                continue;
            }
            remove_partial(&t.data_path, &t.journal_path);
            return Err(DlError::Integrity(format!(
                "sha256 mismatch for blob sha256:{} from {}: the registry's bytes are not the locked ones",
                job.hex, t.source
            )));
        }
        if cancel.load(Ordering::Relaxed) {
            let _ = t.checkpoint();
            return Err(DlError::Cancelled);
        }
        match t.fetch_chunk(obs) {
            Ok(n) => {
                if n > 0 {
                    attempt = 0;
                }
            }
            Err(ChunkErr::Restart) => {
                t.reset()?;
                obs(Obs::Restarted);
                attempt += 1;
                if attempt >= ctx.opts.retry.max_attempts {
                    return Err(DlError::Transient(
                        "the server keeps ignoring byte ranges".to_string(),
                    ));
                }
            }
            Err(ChunkErr::Retry {
                reason,
                retry_after,
                progressed,
            }) => {
                if progressed > 0 {
                    attempt = 0;
                }
                attempt += 1;
                t.checkpoint()?;
                if attempt >= ctx.opts.retry.max_attempts {
                    return Err(DlError::Transient(format!(
                        "giving up on sha256:{} after {attempt} attempts: {reason}",
                        job.hex
                    )));
                }
                let delay = ctx.opts.retry.delay(attempt, retry_after);
                obs(Obs::Retry {
                    in_s: delay.as_secs().max(u64::from(!delay.is_zero())),
                    reason,
                });
                if !sleep_unless_cancelled(delay, &cancel) {
                    let _ = t.checkpoint();
                    return Err(DlError::Cancelled);
                }
            }
            Err(ChunkErr::Fatal(e)) => {
                if matches!(e, DlError::Integrity(_)) {
                    remove_partial(&t.data_path, &t.journal_path);
                } else {
                    let _ = t.checkpoint();
                }
                return Err(e);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_range_parsing() {
        assert_eq!(
            parse_content_range("bytes 0-9/100"),
            Some((0, 9, Some(100)))
        );
        assert_eq!(parse_content_range("bytes 5-5/*"), Some((5, 5, None)));
        assert_eq!(
            parse_content_range(" bytes  10-19 / 20 "),
            Some((10, 19, Some(20)))
        );
        for bad in [
            "",
            "bytes",
            "bytes 1-2",
            "bytes a-b/c",
            "items 0-1/2",
            "bytes */10",
            "bytes 1/2",
        ] {
            assert_eq!(parse_content_range(bad), None, "{bad}");
        }
        assert_eq!(parse_unsatisfied_total("bytes */1234"), Some(1234));
        assert_eq!(parse_unsatisfied_total("bytes 0-1/5"), None);
    }

    #[test]
    fn error_classes_map_to_the_documented_exit_codes() {
        assert_eq!(DlError::Integrity("x".into()).exit_code(), 7);
        assert_eq!(DlError::NoSpace("x".into()).exit_code(), 4);
        assert_eq!(DlError::Cancelled.exit_code(), 6);
        assert_eq!(DlError::Transient("x".into()).exit_code(), 6);
        assert_eq!(DlError::Offline.exit_code(), 6);
        assert_eq!(DlError::Fatal("x".into()).exit_code(), 1);
        assert_eq!(DlError::Io("x".into()).exit_code(), 1);
        assert!(DlError::NoSpace("x".into()).stops_the_job());
        assert!(!DlError::Integrity("x".into()).stops_the_job());
    }
}
