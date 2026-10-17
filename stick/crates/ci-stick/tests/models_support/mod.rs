//! Shared test support for the `models_*` integration tests: a std-only mock of the Ollama
//! registry (plus the CDN it redirects to) with fault injection, a synthetic model builder and
//! helpers to turn synthetic models into a lock. Everything runs on 127.0.0.1; nothing here
//! touches the network.
#![allow(dead_code)]

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io::{Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use ci_stick::hashing::sha256_hex;
use ci_stick::lockfile::{b64_encode, LockedLayer, LockedManifest, LockedModel, ModelLock};
use ci_stick::registry::ollama::{self, Parsed};

pub const MT_CONFIG: &str = "application/vnd.docker.container.image.v1+json";
pub const MT_MODEL: &str = "application/vnd.ollama.image.model";
pub const MT_LICENSE: &str = "application/vnd.ollama.image.license";
pub const MT_PARAMS: &str = "application/vnd.ollama.image.params";
pub const MT_MANIFEST: &str = "application/vnd.docker.distribution.manifest.v2+json";
pub const MT_LIST: &str = "application/vnd.ollama.manifest.list.v2+json";

// ---------------------------------------------------------------------------------------
// Deterministic data
// ---------------------------------------------------------------------------------------

/// xorshift64* stream: reproducible "weights".
pub struct Rng(pub u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }
    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    /// Uniform in `0..n` (`n > 0`).
    pub fn below(&mut self, n: u64) -> u64 {
        self.next_u64() % n
    }
}

pub fn pseudo_bytes(seed: u64, len: usize) -> Vec<u8> {
    let mut rng = Rng::new(seed);
    let mut out = Vec::with_capacity(len + 8);
    while out.len() < len {
        out.extend_from_slice(&rng.next_u64().to_le_bytes());
    }
    out.truncate(len);
    out
}

pub fn digest_of(bytes: &[u8]) -> String {
    format!("sha256:{}", sha256_hex(bytes))
}

pub fn hex_of(bytes: &[u8]) -> String {
    sha256_hex(bytes)
}

// ---------------------------------------------------------------------------------------
// Synthetic models
// ---------------------------------------------------------------------------------------

#[derive(Clone)]
pub struct Synth {
    pub reference: String,
    pub name: String,
    pub tag: String,
    pub license: String,
    pub manifest: Vec<u8>,
    /// role, media type, bytes (config first)
    pub layers: Vec<(String, String, Vec<u8>)>,
}

impl Synth {
    pub fn model_bytes(&self) -> &[u8] {
        &self
            .layers
            .iter()
            .find(|l| l.0 == "model")
            .expect("model layer")
            .2
    }
    pub fn model_digest(&self) -> String {
        digest_of(self.model_bytes())
    }
    pub fn model_hex(&self) -> String {
        hex_of(self.model_bytes())
    }
}

/// A one-model-layer synthetic model. The licence text is shared between models with the
/// same `license` string, so its blob is deduplicated by digest.
pub fn synth(name: &str, tag: &str, model_len: usize, license: &str, seed: u64) -> Synth {
    let config =
        format!(r#"{{"model_format":"gguf","file_type":"Q4_K_M","seed":{seed}}}"#).into_bytes();
    let model = pseudo_bytes(seed, model_len);
    let lic = format!("Licence text for {license}\n").into_bytes();
    let params = br#"{"temperature":0.7}"#.to_vec();
    let manifest = format!(
        r#"{{"schemaVersion":2,"mediaType":"{MT_MANIFEST}","config":{{"mediaType":"{MT_CONFIG}","digest":"{}","size":{}}},"layers":[{{"mediaType":"{MT_MODEL}","digest":"{}","size":{}}},{{"mediaType":"{MT_LICENSE}","digest":"{}","size":{}}},{{"mediaType":"{MT_PARAMS}","digest":"{}","size":{}}}]}}"#,
        digest_of(&config),
        config.len(),
        digest_of(&model),
        model.len(),
        digest_of(&lic),
        lic.len(),
        digest_of(&params),
        params.len()
    )
    .into_bytes();
    Synth {
        reference: if tag.is_empty() {
            name.to_string()
        } else {
            format!("{name}:{tag}")
        },
        name: name.to_string(),
        tag: tag.to_string(),
        license: license.to_string(),
        manifest,
        layers: vec![
            ("config".into(), MT_CONFIG.into(), config),
            ("model".into(), MT_MODEL.into(), model),
            ("license".into(), MT_LICENSE.into(), lic),
            ("params".into(), MT_PARAMS.into(), params),
        ],
    }
}

/// Build a lock for synthetic models without any network: what `models lock` would write.
pub fn lock_for(models: &[&Synth], packs: &[(&str, &[&str])]) -> ModelLock {
    let mut lock = ModelLock::new("http://127.0.0.1", "2026-10-17T00:00:00Z");
    for s in models {
        let Parsed::Manifest(m) = ollama::parse(&s.manifest).expect("synthetic manifest parses")
        else {
            panic!("not a manifest")
        };
        lock.models.push(LockedModel {
            reference: s.reference.clone(),
            source: "ollama".into(),
            license: s.license.clone(),
            manifest: LockedManifest {
                digest: digest_of(&s.manifest),
                size: s.manifest.len() as u64,
                runner: None,
                format: None,
                b64: b64_encode(&s.manifest),
            },
            list_digest: None,
            layers: m
                .layers
                .iter()
                .map(|l| LockedLayer {
                    role: l.role.clone(),
                    media_type: l.media_type.clone(),
                    digest: l.digest.clone(),
                    size: l.size,
                    actual: None,
                })
                .collect(),
            size_bytes: m.size_bytes,
            requires_ollama: None,
            quant: Some("Q4_K_M".into()),
            push_time: Some(1_790_000_000),
        });
        for (role, _, bytes) in &s.layers {
            if role != "model" {
                lock.blobs_inline
                    .insert(digest_of(bytes), b64_encode(bytes));
            }
        }
    }
    lock.models.sort_by(|a, b| a.reference.cmp(&b.reference));
    for (name, refs) in packs {
        lock.packs.insert(
            (*name).to_string(),
            refs.iter().map(|r| (*r).to_string()).collect(),
        );
    }
    lock.validate().expect("synthetic lock is valid");
    lock
}

// ---------------------------------------------------------------------------------------
// Minimal HTTP/1.1 server
// ---------------------------------------------------------------------------------------

pub struct Request {
    pub method: String,
    pub path: String,
    pub query: String,
    pub headers: HashMap<String, String>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .get(&name.to_ascii_lowercase())
            .map(String::as_str)
    }
}

pub type Handler = Arc<dyn Fn(&Request, &mut TcpStream) + Send + Sync>;

pub struct Server {
    pub addr: SocketAddr,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl Server {
    pub fn start(handler: Handler) -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        listener.set_nonblocking(true).expect("nonblocking");
        let addr = listener.local_addr().expect("addr");
        let stop = Arc::new(AtomicBool::new(false));
        let stop2 = stop.clone();
        let handle = std::thread::spawn(move || {
            while !stop2.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let _ = stream.set_nonblocking(false);
                        let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
                        let h = handler.clone();
                        std::thread::spawn(move || {
                            if let Some(req) = read_request(&mut stream) {
                                h(&req, &mut stream);
                            }
                            let _ = stream.shutdown(Shutdown::Both);
                        });
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(2));
                    }
                    Err(_) => break,
                }
            }
        });
        Server {
            addr,
            stop,
            handle: Some(handle),
        }
    }

    pub fn port(&self) -> u16 {
        self.addr.port()
    }

    pub fn url(&self) -> String {
        format!("http://127.0.0.1:{}", self.addr.port())
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

fn read_request(stream: &mut TcpStream) -> Option<Request> {
    let mut buf = Vec::new();
    let mut byte = [0u8; 1];
    while !buf.ends_with(b"\r\n\r\n") {
        match stream.read(&mut byte) {
            Ok(1) => buf.push(byte[0]),
            _ => return None,
        }
        if buf.len() > 16 * 1024 {
            return None;
        }
    }
    let text = String::from_utf8_lossy(&buf).into_owned();
    let mut lines = text.split("\r\n");
    let first = lines.next()?;
    let mut parts = first.split(' ');
    let method = parts.next()?.to_string();
    let target = parts.next()?.to_string();
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target, String::new()),
    };
    let mut headers = HashMap::new();
    for l in lines {
        if let Some((k, v)) = l.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    Some(Request {
        method,
        path,
        query,
        headers,
    })
}

pub fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        206 => "Partial Content",
        307 => "Temporary Redirect",
        403 => "Forbidden",
        404 => "Not Found",
        416 => "Range Not Satisfiable",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "Status",
    }
}

/// Write head + full body.
pub fn respond(stream: &mut TcpStream, status: u16, headers: &[(&str, String)], body: &[u8]) {
    respond_declared(stream, status, headers, body.len(), body);
}

/// Write a head that promises `declared_len` bytes, then only `body` (a short body = truncation).
pub fn respond_declared(
    stream: &mut TcpStream,
    status: u16,
    headers: &[(&str, String)],
    declared_len: usize,
    body: &[u8],
) {
    let mut head = format!(
        "HTTP/1.1 {status} {}\r\nConnection: close\r\nContent-Length: {declared_len}\r\n",
        reason(status)
    );
    for (k, v) in headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    head.push_str("\r\n");
    if stream.write_all(head.as_bytes()).is_err() {
        return;
    }
    let _ = stream.write_all(body);
    let _ = stream.flush();
}

/// Write `body` in pieces at roughly `bps` bytes per second (0 = at once).
pub fn write_paced(stream: &mut TcpStream, body: &[u8], bps: u64) -> bool {
    if bps == 0 {
        return stream.write_all(body).is_ok();
    }
    let piece = (bps / 20).max(1) as usize;
    for chunk in body.chunks(piece) {
        if stream.write_all(chunk).is_err() {
            return false;
        }
        let _ = stream.flush();
        std::thread::sleep(Duration::from_millis(50));
    }
    true
}

// ---------------------------------------------------------------------------------------
// The mock registry and its CDN
// ---------------------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub enum Fault {
    /// Answer with this status and no body.
    Status { code: u16, retry_after: Option<u64> },
    /// Promise the full length, send this many bytes, close.
    TruncateAfter(usize),
    /// Send this many bytes, then sleep.
    StallAfter { bytes: usize, secs: u64 },
    /// Answer 200 with the whole file although a range was asked.
    IgnoreRange,
    /// 206 with a Content-Range that starts elsewhere.
    BadContentRange,
    /// 403, as an expired presigned URL would.
    Expire,
    /// Body followed by this many extra bytes (Content-Length covers them).
    Longer(usize),
}

#[derive(Clone, Debug)]
pub struct Hit {
    pub server: &'static str,
    pub method: String,
    pub path: String,
    pub query: String,
    pub range: Option<String>,
}

/// A tag's plain manifest and, for list-served tags, the list.
pub type ManifestPair = (Vec<u8>, Option<Vec<u8>>);

#[derive(Default)]
pub struct State {
    /// "library/name:tag" -> (plain body, optional list body)
    pub manifests: Mutex<BTreeMap<String, ManifestPair>>,
    pub blobs: Mutex<HashMap<String, Arc<Vec<u8>>>>,
    /// Blobs that exist only as a length (HEAD works, GET does not).
    pub virtual_blobs: Mutex<HashMap<String, u64>>,
    pub cdn_faults: Mutex<VecDeque<(Option<String>, Fault)>>,
    pub registry_faults: Mutex<VecDeque<Fault>>,
    pub hits: Mutex<Vec<Hit>>,
    /// Flip one bit at this absolute blob offset whenever the byte is served.
    pub corrupt_offset: Mutex<Option<u64>>,
    /// Pace CDN bodies at this rate (0 = unlimited).
    pub cdn_bps: AtomicU64,
    /// Serve the blobs from the registry itself, no redirect.
    pub direct: AtomicBool,
    /// Presigned URLs with a token below this are expired.
    pub min_valid_token: AtomicU64,
    pub next_token: AtomicU64,
    /// `ollama-push-time` to report.
    pub push_time: AtomicU64,
    /// Override of the blob's size in HEAD answers (the registry "lies").
    pub size_override: Mutex<HashMap<String, u64>>,
    /// `ollama-content-digest` to report on HEAD instead of the real one (a tag that moved).
    pub head_digest_override: Mutex<Option<String>>,
    /// Where the registry's blob redirect points instead of the CDN (a hostile redirect).
    pub redirect_override: Mutex<Option<String>>,
}

pub struct MockRegistry {
    pub registry: Server,
    pub cdn: Server,
    pub state: Arc<State>,
}

impl MockRegistry {
    pub fn start() -> MockRegistry {
        let state = Arc::new(State::default());
        state.push_time.store(1_790_000_000, Ordering::Relaxed);
        let cdn_state = state.clone();
        let cdn = Server::start(Arc::new(move |req, stream| {
            cdn_handle(&cdn_state, req, stream)
        }));
        let cdn_port = cdn.port();
        let reg_state = state.clone();
        let registry = Server::start(Arc::new(move |req, stream| {
            registry_handle(&reg_state, cdn_port, req, stream)
        }));
        MockRegistry {
            registry,
            cdn,
            state,
        }
    }

    pub fn url(&self) -> String {
        self.registry.url()
    }

    pub fn add_model(&self, s: &Synth) {
        let key = format!("library/{}:{}", s.name, s.tag);
        self.state
            .manifests
            .lock()
            .unwrap()
            .insert(key, (s.manifest.clone(), None));
        for (_, _, bytes) in &s.layers {
            self.add_blob(bytes);
        }
    }

    pub fn add_blob(&self, bytes: &[u8]) -> String {
        let hex = hex_of(bytes);
        self.state
            .blobs
            .lock()
            .unwrap()
            .insert(hex.clone(), Arc::new(bytes.to_vec()));
        hex
    }

    pub fn add_manifest(&self, repo_tag: &str, plain: &[u8], list: Option<&[u8]>) {
        self.state.manifests.lock().unwrap().insert(
            repo_tag.to_string(),
            (plain.to_vec(), list.map(<[u8]>::to_vec)),
        );
    }

    pub fn add_virtual_blob(&self, digest: &str, size: u64) {
        self.state
            .virtual_blobs
            .lock()
            .unwrap()
            .insert(digest.trim_start_matches("sha256:").to_string(), size);
    }

    pub fn fault(&self, hex: Option<&str>, f: Fault) {
        self.state
            .cdn_faults
            .lock()
            .unwrap()
            .push_back((hex.map(str::to_string), f));
    }

    pub fn registry_fault(&self, f: Fault) {
        self.state.registry_faults.lock().unwrap().push_back(f);
    }

    pub fn hits(&self) -> Vec<Hit> {
        self.state.hits.lock().unwrap().clone()
    }

    pub fn cdn_ranges(&self, hex: &str) -> Vec<String> {
        self.hits()
            .into_iter()
            .filter(|h| h.server == "cdn" && h.path.ends_with(hex) && h.method == "GET")
            .map(|h| h.range.unwrap_or_default())
            .collect()
    }

    pub fn clear_hits(&self) {
        self.state.hits.lock().unwrap().clear();
    }

    /// Bytes of blob data the CDN has been asked for (sum of the requested range lengths).
    pub fn cdn_get_count(&self) -> usize {
        self.hits()
            .iter()
            .filter(|h| h.server == "cdn" && h.method == "GET")
            .count()
    }
}

fn record(state: &State, server: &'static str, req: &Request) {
    state.hits.lock().unwrap().push(Hit {
        server,
        method: req.method.clone(),
        path: req.path.clone(),
        query: req.query.clone(),
        range: req.header("range").map(str::to_string),
    });
}

fn apply_status_fault(stream: &mut TcpStream, f: &Fault) -> bool {
    match f {
        Fault::Status { code, retry_after } => {
            let mut h = Vec::new();
            if let Some(r) = retry_after {
                h.push(("Retry-After", r.to_string()));
            }
            respond(stream, *code, &h, b"");
            true
        }
        Fault::Expire => {
            respond(stream, 403, &[], b"<Error>ExpiredToken</Error>");
            true
        }
        _ => false,
    }
}

fn registry_handle(state: &State, cdn_port: u16, req: &Request, stream: &mut TcpStream) {
    record(state, "registry", req);
    if let Some(f) = state.registry_faults.lock().unwrap().pop_front() {
        if apply_status_fault(stream, &f) {
            return;
        }
    }
    let Some(rest) = req.path.strip_prefix("/v2/") else {
        return respond(stream, 404, &[], b"");
    };
    if let Some((repo, tag)) = rest.split_once("/manifests/") {
        if tag.starts_with("sha256:") {
            return respond(
                stream,
                404,
                &[],
                br#"{"errors":[{"code":"MANIFEST_UNKNOWN"}]}"#,
            );
        }
        let key = format!("{repo}:{tag}");
        let Some((plain, list)) = state.manifests.lock().unwrap().get(&key).cloned() else {
            return respond(
                stream,
                404,
                &[],
                br#"{"errors":[{"code":"MANIFEST_UNKNOWN"}]}"#,
            );
        };
        let wants_list = req.header("accept").is_some_and(|a| a.contains(MT_LIST));
        let (body, ctype) = match (&list, wants_list) {
            (Some(l), true) => (l.clone(), MT_LIST),
            _ => (plain, MT_MANIFEST),
        };
        let mut headers = vec![("Content-Type", ctype.to_string())];
        if req.method == "HEAD" {
            let digest = state
                .head_digest_override
                .lock()
                .unwrap()
                .clone()
                .unwrap_or_else(|| hex_of(&body));
            headers.push(("ollama-content-digest", digest));
            headers.push((
                "ollama-push-time",
                state.push_time.load(Ordering::Relaxed).to_string(),
            ));
            return respond_declared(stream, 200, &headers, body.len(), b"");
        }
        return respond(stream, 200, &headers, &body);
    }
    if let Some((_repo, digest)) = rest.split_once("/blobs/") {
        let hex = digest.trim_start_matches("sha256:").to_string();
        let blob = state.blobs.lock().unwrap().get(&hex).cloned();
        let virtual_len = state.virtual_blobs.lock().unwrap().get(&hex).copied();
        let overridden = state.size_override.lock().unwrap().get(&hex).copied();
        let len = blob.as_ref().map(|b| b.len() as u64).or(virtual_len);
        let Some(len) = len else {
            return respond(stream, 404, &[], br#"{"errors":[{"code":"BLOB_UNKNOWN"}]}"#);
        };
        let len = overridden.unwrap_or(len);
        let ctype = ("Content-Type", "application/octet-stream".to_string());
        if req.method == "HEAD" {
            return respond_declared(stream, 200, &[ctype], len as usize, b"");
        }
        let Some(blob) = blob else {
            return respond(stream, 500, &[], b"virtual blob has no bytes");
        };
        if state.direct.load(Ordering::Relaxed) {
            return serve_blob(state, "registry-direct", req, stream, &hex, &blob);
        }
        let token = state.next_token.fetch_add(1, Ordering::Relaxed) + 1;
        if let Some(loc) = state.redirect_override.lock().unwrap().clone() {
            return respond(stream, 307, &[("Location", loc)], b"");
        }
        let loc = format!(
            "http://127.0.0.1:{cdn_port}/blob/{hex}?X-Amz-Signature=SECRETSIG{token}&X-Amz-Expires=86400&token={token}"
        );
        return respond(stream, 307, &[("Location", loc)], b"");
    }
    respond(stream, 404, &[], b"");
}

fn cdn_handle(state: &State, req: &Request, stream: &mut TcpStream) {
    record(state, "cdn", req);
    let Some(hex) = req.path.strip_prefix("/blob/") else {
        return respond(stream, 404, &[], b"");
    };
    let token: u64 = req
        .query
        .split('&')
        .find_map(|kv| kv.strip_prefix("token="))
        .and_then(|t| t.parse().ok())
        .unwrap_or(0);
    if token < state.min_valid_token.load(Ordering::Relaxed) {
        return respond(stream, 403, &[], b"<Error>ExpiredToken</Error>");
    }
    let Some(blob) = state.blobs.lock().unwrap().get(hex).cloned() else {
        return respond(stream, 404, &[], b"");
    };
    serve_blob(state, "cdn", req, stream, hex, &blob);
}

fn take_fault(state: &State, hex: &str) -> Option<Fault> {
    let mut q = state.cdn_faults.lock().unwrap();
    let pos = q
        .iter()
        .position(|(h, _)| h.as_deref().map_or(true, |h| h == hex))?;
    q.remove(pos).map(|(_, f)| f)
}

fn serve_blob(
    state: &State,
    _who: &str,
    req: &Request,
    stream: &mut TcpStream,
    hex: &str,
    blob: &Arc<Vec<u8>>,
) {
    let total = blob.len() as u64;
    let mut fault = take_fault(state, hex);
    if let Some(f) = &fault {
        if apply_status_fault(stream, f) {
            return;
        }
    }
    let range = req.header("range").and_then(|r| {
        let spec = r.strip_prefix("bytes=")?;
        let (a, b) = spec.split_once('-')?;
        let a: u64 = a.parse().ok()?;
        let b: Option<u64> = if b.is_empty() {
            None
        } else {
            Some(b.parse().ok()?)
        };
        Some((a, b))
    });
    let ignore = matches!(fault, Some(Fault::IgnoreRange));
    let (status, start, end) = match range {
        Some((a, b)) if !ignore => {
            if a >= total {
                return respond(
                    stream,
                    416,
                    &[("Content-Range", format!("bytes */{total}"))],
                    b"",
                );
            }
            let end = b.map_or(total - 1, |b| b.min(total - 1));
            (206u16, a, end)
        }
        _ => (200u16, 0, total.saturating_sub(1)),
    };
    let mut body: Vec<u8> = if total == 0 {
        Vec::new()
    } else {
        blob[start as usize..=end as usize].to_vec()
    };
    if let Some(off) = *state.corrupt_offset.lock().unwrap() {
        if off >= start && off <= end && !body.is_empty() {
            body[(off - start) as usize] ^= 0x01;
        }
    }
    let mut headers = vec![
        ("Content-Type", "application/octet-stream".to_string()),
        ("Accept-Ranges", "bytes".to_string()),
    ];
    if status == 206 {
        let mut a = start;
        if matches!(fault, Some(Fault::BadContentRange)) {
            a += 1;
        }
        headers.push(("Content-Range", format!("bytes {a}-{end}/{total}")));
    }
    let bps = state.cdn_bps.load(Ordering::Relaxed);
    match fault.take() {
        Some(Fault::TruncateAfter(n)) => {
            let n = n.min(body.len());
            respond_declared(stream, status, &headers, body.len(), &body[..n]);
        }
        Some(Fault::StallAfter { bytes, secs }) => {
            let n = bytes.min(body.len());
            respond_declared(stream, status, &headers, body.len(), &body[..n]);
            std::thread::sleep(Duration::from_secs(secs));
        }
        Some(Fault::Longer(extra)) => {
            let declared = body.len() + extra;
            body.extend(std::iter::repeat(0xAB).take(extra));
            respond_declared(stream, status, &headers, declared, &body);
        }
        _ => {
            let mut head = format!(
                "HTTP/1.1 {status} {}\r\nConnection: close\r\nContent-Length: {}\r\n",
                reason(status),
                body.len()
            );
            for (k, v) in &headers {
                head.push_str(&format!("{k}: {v}\r\n"));
            }
            head.push_str("\r\n");
            if stream.write_all(head.as_bytes()).is_err() {
                return;
            }
            let _ = write_paced(stream, &body, bps);
        }
    }
}

// ---------------------------------------------------------------------------------------
// Running the CLI
// ---------------------------------------------------------------------------------------

pub fn ci_stick_bin() -> &'static str {
    env!("CARGO_BIN_EXE_ci-stick")
}

pub struct CliRun {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// Run `ci-stick` with a clean environment apart from fast retries.
pub fn run_cli(args: &[&str], envs: &[(&str, &str)]) -> CliRun {
    let mut cmd = std::process::Command::new(ci_stick_bin());
    cmd.args(args)
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("CI_STICK_RETRY_BASE_MS", "1")
        .env_remove("CI_OS_REGISTRY_URL");
    for (k, v) in envs {
        cmd.env(k, v);
    }
    let out = cmd.output().expect("run ci-stick");
    CliRun {
        code: out.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

pub fn p(path: &std::path::Path) -> &str {
    path.to_str().expect("utf-8 path")
}

/// Wait until `cond` holds, or panic after `secs`.
pub fn wait_for(secs: u64, what: &str, mut cond: impl FnMut() -> bool) {
    let start = std::time::Instant::now();
    while !cond() {
        assert!(
            start.elapsed() < Duration::from_secs(secs),
            "timed out waiting for {what}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

// ---------------------------------------------------------------------------------------
// Capturing events, injecting disk faults
// ---------------------------------------------------------------------------------------

use ci_stick::cache::sink::{no_space_error, BlobSink, FileSinkFactory, SinkFactory};

/// A `Write` that collects what is written, for event streams.
#[derive(Clone, Default)]
pub struct Capture(pub Arc<Mutex<Vec<u8>>>);

impl Write for Capture {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Capture {
    pub fn lines(&self) -> Vec<serde_json::Value> {
        String::from_utf8(self.0.lock().unwrap().clone())
            .unwrap()
            .lines()
            .map(|l| {
                serde_json::from_str(l).unwrap_or_else(|e| panic!("bad event line {l:?}: {e}"))
            })
            .collect()
    }
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

/// A sink factory whose disk "fills up" after `limit` bytes appended in total (all opens
/// together), failing the append that crosses it after writing what fits, as `write(2)` does.
pub struct FullDisk {
    pub limit: u64,
    pub used: Arc<AtomicU64>,
}

impl FullDisk {
    pub fn after(limit: u64) -> Self {
        FullDisk {
            limit,
            used: Arc::new(AtomicU64::new(0)),
        }
    }
}

struct FullSink {
    inner: Box<dyn BlobSink>,
    limit: u64,
    used: Arc<AtomicU64>,
}

impl BlobSink for FullSink {
    fn size(&mut self) -> std::io::Result<u64> {
        self.inner.size()
    }
    fn truncate(&mut self, len: u64) -> std::io::Result<()> {
        self.inner.truncate(len)
    }
    fn read_prefix(&mut self, len: u64, f: &mut dyn FnMut(&[u8])) -> std::io::Result<()> {
        self.inner.read_prefix(len, f)
    }
    fn append(&mut self, data: &[u8]) -> std::io::Result<()> {
        let used = self.used.load(Ordering::SeqCst);
        let room = self.limit.saturating_sub(used) as usize;
        if data.len() > room {
            if room > 0 {
                self.inner.append(&data[..room])?;
                self.used.fetch_add(room as u64, Ordering::SeqCst);
            }
            return Err(no_space_error());
        }
        self.used.fetch_add(data.len() as u64, Ordering::SeqCst);
        self.inner.append(data)
    }
    fn sync(&mut self) -> std::io::Result<()> {
        self.inner.sync()
    }
}

impl SinkFactory for FullDisk {
    fn open(&self, partial: &std::path::Path) -> std::io::Result<Box<dyn BlobSink>> {
        Ok(Box::new(FullSink {
            inner: FileSinkFactory.open(partial)?,
            limit: self.limit,
            used: self.used.clone(),
        }))
    }
}
