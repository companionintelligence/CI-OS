//! Seeded property test for resumable downloads: 250 random situations (blob size, chunk size,
//! buffer size, journal cadence, injected cuts, a partial left behind by an earlier run with
//! a journal that is right, short, long, stale or garbage, and sometimes a corrupt prefix) and
//! in every one the finished blob must be byte-identical to the source and verified, with
//! nothing left in `partial/`.
//!
//! The generator is a fixed-seed xorshift, so a failure is reproducible: the case number and
//! parameters are in the panic message. `CI_STICK_RESUME_CASES=n` changes the count and
//! `CI_STICK_RESUME_SEED=s` the seed (`CI_STICK_RESUME_VERBOSE=1` prints every case).
//!
//! The registry here is an in-process [`Transport`] (no sockets): the cases are up to a
//! megabyte each and cost about a second on a busy laptop, a few milliseconds on a quiet CI runner, and the same engine code runs as against the socket mock in
//! `models_fetch.rs`, which covers the HTTP details (redirects, headers, real connection
//! cuts).

mod models_support;

use std::collections::{HashMap, VecDeque};
use std::fs;
use std::io::Read;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ci_stick::cache::layout::CacheLayout;
use ci_stick::cache::partial::{write_journal, Journal};
use ci_stick::cache::sink::{BlobSink, FileSinkFactory, SinkFactory};
use ci_stick::events::{EventSink, Reporter};
use ci_stick::fetch::plan::Selection;
use ci_stick::fetch::{self, ChunkPolicy, FetchOptions, TransferOptions};
use ci_stick::net::{
    Fetcher, HttpRequest, HttpResponse, Method, NetError, NetPolicy, RetryPolicy, Transport, Url,
};
use ci_stick::registry::RegistryClient;
use models_support::*;

const KIB: u64 = 1024;
const MIB: u64 = 1024 * 1024;

/// The real sink minus `fsync`: this test is about offsets and hashes, not about durability,
/// and on macOS every sync is a full cache flush of the disk.
struct NoSync;
struct NoSyncSink(Box<dyn BlobSink>);

impl BlobSink for NoSyncSink {
    fn size(&mut self) -> std::io::Result<u64> {
        self.0.size()
    }
    fn truncate(&mut self, len: u64) -> std::io::Result<()> {
        self.0.truncate(len)
    }
    fn read_prefix(&mut self, len: u64, f: &mut dyn FnMut(&[u8])) -> std::io::Result<()> {
        self.0.read_prefix(len, f)
    }
    fn append(&mut self, data: &[u8]) -> std::io::Result<()> {
        self.0.append(data)
    }
    fn sync(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl SinkFactory for NoSync {
    fn open(&self, partial: &std::path::Path) -> std::io::Result<Box<dyn BlobSink>> {
        Ok(Box::new(NoSyncSink(FileSinkFactory.open(partial)?)))
    }
}

/// How a cut body ends: a clean EOF before `Content-Length`, or a connection reset.
#[derive(Clone, Copy)]
enum Cut {
    Eof,
    Reset,
}

/// A registry that lives in memory: serves ranges of known blobs, with cuts injected.
#[derive(Default)]
struct MemTransport {
    blobs: Mutex<HashMap<String, Arc<Vec<u8>>>>,
    cuts: Mutex<VecDeque<(String, usize, Cut)>>,
    log: Mutex<Vec<(String, String)>>,
}

struct Cutting {
    data: std::io::Cursor<Vec<u8>>,
    mode: Cut,
}

impl Read for Cutting {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self.data.read(buf)? {
            0 => match self.mode {
                Cut::Eof => Ok(0),
                Cut::Reset => Err(std::io::Error::from(std::io::ErrorKind::ConnectionReset)),
            },
            n => Ok(n),
        }
    }
}

impl Transport for MemTransport {
    fn send(&self, req: &HttpRequest) -> Result<HttpResponse, NetError> {
        let path = req.url.path().to_string();
        let hex = path.rsplit("sha256:").next().unwrap_or("").to_string();
        let range = req
            .headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("range"))
            .map(|(_, v)| v.clone());
        self.log
            .lock()
            .unwrap()
            .push((hex.clone(), range.clone().unwrap_or_default()));
        let Some(blob) = self.blobs.lock().unwrap().get(&hex).cloned() else {
            return Ok(HttpResponse {
                status: 404,
                headers: vec![],
                body: Box::new(std::io::empty()),
            });
        };
        let total = blob.len() as u64;
        let (status, a, b) = match range
            .as_deref()
            .and_then(|r| r.strip_prefix("bytes="))
            .and_then(|r| r.split_once('-'))
        {
            Some((a, b)) => {
                let a: u64 = a.parse().unwrap();
                if a >= total {
                    return Ok(HttpResponse {
                        status: 416,
                        headers: vec![("content-range".into(), format!("bytes */{total}"))],
                        body: Box::new(std::io::empty()),
                    });
                }
                (
                    206u16,
                    a,
                    b.parse::<u64>().map_or(total - 1, |b| b.min(total - 1)),
                )
            }
            None => (200, 0, total.saturating_sub(1)),
        };
        let slice = if total == 0 {
            Vec::new()
        } else {
            blob[a as usize..=b as usize].to_vec()
        };
        let mut headers = vec![("content-length".to_string(), slice.len().to_string())];
        if status == 206 {
            headers.push(("content-range".into(), format!("bytes {a}-{b}/{total}")));
        }
        if req.method == Method::Head {
            return Ok(HttpResponse {
                status,
                headers,
                body: Box::new(std::io::empty()),
            });
        }
        let cut = {
            let mut q = self.cuts.lock().unwrap();
            q.iter()
                .position(|(h, _, _)| *h == hex)
                .and_then(|i| q.remove(i))
        };
        let body: Box<dyn Read + Send> = match cut {
            Some((_, n, mode)) => Box::new(Cutting {
                data: std::io::Cursor::new(slice[..n.min(slice.len())].to_vec()),
                mode,
            }),
            None => Box::new(std::io::Cursor::new(slice)),
        };
        Ok(HttpResponse {
            status,
            headers,
            body,
        })
    }
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// Sizes that matter: empty, one byte, around chunk and buffer boundaries, and random ones.
fn pick_size(rng: &mut Rng) -> u64 {
    const EDGES: [u64; 12] = [
        0,
        1,
        2,
        4095,
        4096,
        4097,
        65_535,
        65_536,
        65_537,
        MIB - 1,
        MIB,
        MIB + 1,
    ];
    if rng.below(3) == 0 {
        EDGES[rng.below(EDGES.len() as u64) as usize]
    } else {
        rng.below(900 * KIB)
    }
}

/// A committed offset: random, or one of the interesting ones.
fn pick_committed(rng: &mut Rng, size: u64) -> u64 {
    let cands = [0, 1, size.saturating_sub(1), size, 64 * KIB, MIB, size / 2];
    let c = if rng.below(2) == 0 {
        cands[rng.below(cands.len() as u64) as usize]
    } else {
        rng.below(size + 1)
    };
    c.min(size)
}

#[test]
fn random_cuts_and_stale_partials_always_end_in_the_right_bytes() {
    ci_stick::cache::store::set_fsync_enabled(false);
    let cases = env_u64("CI_STICK_RESUME_CASES", 250);
    let seed = env_u64("CI_STICK_RESUME_SEED", 0xC0FFEE);
    let mut rng = Rng::new(seed);
    let mem = Arc::new(MemTransport::default());
    let url = Url::parse("http://127.0.0.1:1").unwrap();
    let base = tempfile::tempdir().unwrap();

    let mut resumed_cases = 0;
    let mut cut_cases = 0;
    let mut clean_restart_cases = 0;

    for case in 0..cases {
        let size = pick_size(&mut rng);
        let chunk = [16 * KIB, 64 * KIB, 100_000, 256 * KIB, MIB][rng.below(5) as usize];
        let buffer = [4 * KIB, 16 * KIB, 100 * KIB][rng.below(3) as usize];
        // (a journal write is a handful of file-system operations: cadences below 64 KiB would
        // make this test measure the file system, not the resume logic)
        let journal_every = [128 * KIB, 256 * KIB, MIB, 64 * MIB][rng.below(4) as usize];
        let scenario = rng.below(4);
        let name = format!("case{case}");
        let s = synth(&name, "1b", size as usize, "Apache-2.0", 1000 + case);
        let hex = s.model_hex();
        mem.blobs
            .lock()
            .unwrap()
            .insert(hex.clone(), Arc::new(s.model_bytes().to_vec()));
        let source = s.model_bytes().to_vec();

        let cache = base.path().join(format!("cache{case}"));
        fs::create_dir_all(&cache).unwrap();
        let layout = CacheLayout::new(&cache);
        let mut describe = format!("case {case} (seed {seed:#x}): size {size}, chunk {chunk}, buffer {buffer}, journal_every {journal_every}, scenario {scenario}");

        // what an earlier, interrupted run left behind
        let mut valid_prefix = 0u64;
        if scenario >= 2 && size > 0 {
            let committed = pick_committed(&mut rng, size);
            // data on disk: exactly the committed bytes, more (unjournaled tail), or fewer (power cut)
            let data_len = match rng.below(3) {
                0 => committed,
                1 => (committed + rng.below(200 * KIB)).min(size),
                _ => rng.below(committed + 1),
            };
            let mut data = source[..data_len as usize].to_vec();
            let corrupt = rng.below(5) == 0 && data_len > 0;
            if corrupt {
                let at = rng.below(data_len) as usize;
                data[at] ^= 0x40;
            }
            fs::create_dir_all(layout.partial_dir()).unwrap();
            fs::write(layout.partial_path(&hex).unwrap(), &data).unwrap();
            let (j_size, j_hex) = match rng.below(6) {
                0 => (size + 1, hex.clone()), // stale: another size
                1 => (size, "0".repeat(64)),  // stale: another blob
                _ => (size, hex.clone()),
            };
            let j = Journal::new(&j_hex, j_size, committed, "http://x/y");
            let garbage = rng.below(8) == 0;
            if garbage {
                fs::write(layout.journal_path(&hex).unwrap(), b"\x00garbage").unwrap();
            } else {
                write_journal(&layout.journal_path(&hex).unwrap(), &j).unwrap();
            }
            if !corrupt && !garbage && j.matches(&hex, size) && data_len >= committed {
                valid_prefix = committed;
            }
            describe.push_str(&format!(", partial: data {data_len}, journal {committed} ({j_hex:.4}/{j_size}), corrupt {corrupt}, garbage journal {garbage}"));
        } else if size > 0 {
            // cuts in the middle of bodies
            let cuts = rng.below(4);
            for _ in 0..cuts {
                let mode = if rng.below(2) == 0 {
                    Cut::Eof
                } else {
                    Cut::Reset
                };
                mem.cuts.lock().unwrap().push_back((
                    hex.clone(),
                    rng.below(chunk.min(size) + 1) as usize,
                    mode,
                ));
            }
            if cuts > 0 {
                cut_cases += 1;
            }
            describe.push_str(&format!(", {cuts} injected cuts"));
        }

        let refs = [&s];
        let lock = lock_for(&refs, &[("p", &[s.reference.as_str()])]);
        let mut opts = FetchOptions::new(&cache);
        opts.transfer = TransferOptions {
            retry: RetryPolicy::immediate(8),
            chunk: ChunkPolicy {
                initial: chunk,
                max: chunk,
                target: Duration::from_secs(1),
            },
            stall_timeout: Duration::from_secs(5),
            journal_every,
            buffer: buffer as usize,
        };
        let client = RegistryClient::new(
            Fetcher::new(mem.clone(), NetPolicy::test_loopback()),
            url.clone(),
        )
        .with_retry(RetryPolicy::immediate(8))
        .with_cancel(Arc::new(AtomicBool::new(false)));
        let reporter = Reporter::new(EventSink::none(), None, None);
        mem.log.lock().unwrap().clear();
        if std::env::var_os("CI_STICK_RESUME_VERBOSE").is_some() {
            eprintln!("{describe}");
        }
        let t_fetch = std::time::Instant::now();
        let outcome = fetch::run(
            &lock,
            &Selection::Pack("p".into()),
            &opts,
            &client,
            &NoSync,
            &reporter,
        )
        .unwrap_or_else(|e| panic!("{describe}: {e}"));
        if std::env::var_os("CI_STICK_RESUME_VERBOSE").is_some() {
            eprintln!("  fetch took {:?}", t_fetch.elapsed());
        }
        assert_eq!(outcome.exit, 0, "{describe}: {:?}", outcome.errors);

        let got =
            fs::read(layout.blob_path(&hex).unwrap()).unwrap_or_else(|e| panic!("{describe}: {e}"));
        assert!(
            got == source,
            "{describe}: the finished blob differs from the source"
        );
        let leftovers: Vec<String> = fs::read_dir(layout.partial_dir())
            .map(|rd| {
                rd.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        assert!(
            leftovers.is_empty(),
            "{describe}: left in partial/: {leftovers:?}"
        );
        assert_eq!(
            fs::read(
                layout
                    .manifest_path(&["registry.ollama.ai", "library", &name, "1b"])
                    .unwrap()
            )
            .unwrap(),
            s.manifest,
            "{describe}"
        );

        if valid_prefix > 0 {
            resumed_cases += 1;
            // a valid partial must not be downloaded again
            let ranges: Vec<String> = mem
                .log
                .lock()
                .unwrap()
                .iter()
                .filter(|(h, _)| *h == hex)
                .map(|(_, r)| r.clone())
                .collect();
            let first = ranges.first().map(String::as_str).unwrap_or("");
            if valid_prefix < size {
                assert!(
                    first.starts_with(&format!("bytes={valid_prefix}-")),
                    "{describe}: resumed at the wrong place: {ranges:?}"
                );
            } else {
                assert!(
                    ranges.is_empty(),
                    "{describe}: a complete partial needs no download: {ranges:?}"
                );
            }
            assert!(
                outcome.bytes_downloaded <= size - valid_prefix,
                "{describe}: downloaded {}",
                outcome.bytes_downloaded
            );
        } else if scenario >= 2 {
            clean_restart_cases += 1;
        }
        let _ = fs::remove_dir_all(&cache);
    }
    // the generator really exercised all three situations
    if cases >= 200 {
        assert!(resumed_cases > 20, "only {resumed_cases} resumed cases");
        assert!(cut_cases > 20, "only {cut_cases} cut cases");
        assert!(
            clean_restart_cases > 10,
            "only {clean_restart_cases} stale/corrupt cases"
        );
    }
}
