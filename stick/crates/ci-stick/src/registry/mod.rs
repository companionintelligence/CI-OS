//! Talking to an Ollama-compatible registry.
//!
//! * [`ollama`]: references, manifests and lists (pure parsing and validation)
//! * [`resolve`]: tag -> lock entry (the network half of `models lock`)
//! * this module: [`RegistryClient`], small bounded GETs/HEADs with retry
//!
//! Large blob downloads are not done here; they go through `fetch`, which needs ranges,
//! journals and cached redirect targets.

pub mod ollama;
pub mod resolve;

use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use thiserror::Error;

use crate::net::{
    io_error_to_net, parse_retry_after, sleep_unless_cancelled, Fetcher, Method, NetError,
    RetryPolicy, Url,
};

pub const DEFAULT_REGISTRY_URL: &str = "https://registry.ollama.ai";
/// Environment variable that overrides [`DEFAULT_REGISTRY_URL`].
pub const REGISTRY_ENV: &str = "CI_OS_REGISTRY_URL";

#[derive(Debug, Error)]
pub enum RegistryError {
    #[error("{0}")]
    Net(NetError),
    #[error("not found: {url}")]
    NotFound { url: String },
    #[error("the registry answered HTTP {status} for {url}")]
    Status { status: u16, url: String },
    #[error("the response from {url} is larger than the {limit}-byte limit")]
    TooLarge { url: String, limit: u64 },
    #[error("{0}")]
    Invalid(String),
    #[error("cancelled")]
    Cancelled,
}

impl RegistryError {
    /// Worth trying again later (network trouble, 429, 5xx) as opposed to a definite answer.
    pub fn is_transient(&self) -> bool {
        match self {
            RegistryError::Net(e) => e.is_transient(),
            RegistryError::Status { status, .. } => *status == 429 || *status >= 500,
            _ => false,
        }
    }
}

impl From<NetError> for RegistryError {
    fn from(e: NetError) -> Self {
        RegistryError::Net(e)
    }
}

/// What `HEAD` on a manifest tells us.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeadInfo {
    /// `ollama-content-digest` as `sha256:<hex>`.
    pub digest: Option<String>,
    /// `ollama-push-time` (Unix seconds).
    pub push_time: Option<u64>,
}

/// The registry base URL: `--registry-url`, else `CI_OS_REGISTRY_URL`, else the default.
pub fn registry_url(arg: Option<&str>) -> Result<Url, NetError> {
    let from_env = std::env::var(REGISTRY_ENV)
        .ok()
        .filter(|v| !v.trim().is_empty());
    let raw = arg
        .map(str::to_string)
        .or(from_env)
        .unwrap_or_else(|| DEFAULT_REGISTRY_URL.to_string());
    let mut url = Url::parse(raw.trim_end_matches('/'))?;
    if url.has_query() || url.path() != "/" {
        // A registry base is scheme://host[:port]; keep it simple and unambiguous.
        url.path_query = "/".into();
    }
    Ok(url)
}

#[derive(Clone)]
pub struct RegistryClient {
    fetcher: Fetcher,
    base: Url,
    retry: RetryPolicy,
    timeout: Duration,
    cancel: Arc<AtomicBool>,
}

impl RegistryClient {
    pub fn new(fetcher: Fetcher, base: Url) -> Self {
        Self {
            fetcher,
            base,
            retry: RetryPolicy::default(),
            timeout: Duration::from_secs(60),
            cancel: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn with_retry(mut self, retry: RetryPolicy) -> Self {
        self.retry = retry;
        self
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn with_cancel(mut self, cancel: Arc<AtomicBool>) -> Self {
        self.cancel = cancel;
        self
    }

    pub fn base(&self) -> &Url {
        &self.base
    }
    pub fn fetcher(&self) -> &Fetcher {
        &self.fetcher
    }
    pub fn retry_policy(&self) -> &RetryPolicy {
        &self.retry
    }
    pub fn timeout(&self) -> Duration {
        self.timeout
    }
    pub fn cancel_flag(&self) -> &Arc<AtomicBool> {
        &self.cancel
    }

    fn url(&self, path: &str) -> Url {
        Url {
            path_query: path.to_string(),
            ..self.base.clone()
        }
    }

    /// `/v2/<repo>/manifests/<reference>`; `reference` is a tag (validated by `ModelRef`).
    pub fn manifest_url(&self, repo: &str, reference: &str) -> Url {
        self.url(&format!("/v2/{repo}/manifests/{reference}"))
    }

    /// `/v2/<repo>/blobs/<digest>`, `digest` being `sha256:<hex>`.
    pub fn blob_url(&self, repo: &str, digest: &str) -> Url {
        self.url(&format!("/v2/{repo}/blobs/{digest}"))
    }

    /// GET a small body (at most `limit` bytes), following redirects and retrying transient
    /// failures. Returns the body and the `Content-Type`.
    pub fn get_bytes(
        &self,
        url: &Url,
        accept: Option<&str>,
        limit: u64,
    ) -> Result<(Vec<u8>, Option<String>), RegistryError> {
        let mut headers = Vec::new();
        if let Some(a) = accept {
            headers.push(("Accept".to_string(), a.to_string()));
        }
        self.with_retries(url, |this| {
            let (resp, final_url) = this
                .fetcher
                .send(Method::Get, url, &headers, this.timeout)
                .map_err(Attempt::Net)?;
            match resp.status {
                200 => {}
                404 => {
                    return Err(Attempt::Fatal(RegistryError::NotFound {
                        url: url.redacted(),
                    }))
                }
                s => {
                    return Err(Attempt::Status(
                        s,
                        resp.header("retry-after").and_then(parse_retry_after),
                    ))
                }
            }
            if resp.content_length().is_some_and(|n| n > limit) {
                return Err(Attempt::Fatal(RegistryError::TooLarge {
                    url: final_url.redacted(),
                    limit,
                }));
            }
            let content_type = resp.header("content-type").map(str::to_string);
            let mut body = Vec::new();
            resp.body
                .take(limit + 1)
                .read_to_end(&mut body)
                .map_err(|e| Attempt::Net(io_error_to_net(&e)))?;
            if body.len() as u64 > limit {
                return Err(Attempt::Fatal(RegistryError::TooLarge {
                    url: final_url.redacted(),
                    limit,
                }));
            }
            Ok((body, content_type))
        })
    }

    /// HEAD a manifest tag.
    pub fn head(&self, url: &Url, accept: Option<&str>) -> Result<HeadInfo, RegistryError> {
        let mut headers = Vec::new();
        if let Some(a) = accept {
            headers.push(("Accept".to_string(), a.to_string()));
        }
        self.with_retries(url, |this| {
            let (resp, _) = this
                .fetcher
                .send(Method::Head, url, &headers, this.timeout)
                .map_err(Attempt::Net)?;
            match resp.status {
                200 => {}
                404 => {
                    return Err(Attempt::Fatal(RegistryError::NotFound {
                        url: url.redacted(),
                    }))
                }
                s => {
                    return Err(Attempt::Status(
                        s,
                        resp.header("retry-after").and_then(parse_retry_after),
                    ))
                }
            }
            let digest = resp
                .header("ollama-content-digest")
                .map(|d| d.trim().trim_start_matches("sha256:").to_ascii_lowercase())
                .filter(|d| crate::hashing::is_sha256_hex(d))
                .map(|d| format!("sha256:{d}"));
            let push_time = resp
                .header("ollama-push-time")
                .and_then(|v| v.trim().parse().ok());
            Ok(HeadInfo { digest, push_time })
        })
    }

    /// The length of a blob as the registry reports it (`HEAD`, `Content-Length`), or `None`
    /// if the registry does not say. A `404` is an error.
    pub fn blob_length(&self, url: &Url) -> Result<Option<u64>, RegistryError> {
        self.with_retries(url, |this| {
            let (resp, _) = this
                .fetcher
                .send(Method::Head, url, &[], this.timeout)
                .map_err(Attempt::Net)?;
            match resp.status {
                200 => Ok(resp.content_length()),
                404 => Err(Attempt::Fatal(RegistryError::NotFound {
                    url: url.redacted(),
                })),
                // some registries refuse HEAD on blobs; the length is then learned at download time
                405 | 501 => Ok(None),
                s => Err(Attempt::Status(
                    s,
                    resp.header("retry-after").and_then(parse_retry_after),
                )),
            }
        })
    }

    fn with_retries<T>(
        &self,
        url: &Url,
        mut op: impl FnMut(&Self) -> Result<T, Attempt>,
    ) -> Result<T, RegistryError> {
        let mut attempt = 0u32;
        loop {
            if self.cancel.load(Ordering::Relaxed) {
                return Err(RegistryError::Cancelled);
            }
            attempt += 1;
            let (err, retry_after) = match op(self) {
                Ok(v) => return Ok(v),
                Err(Attempt::Fatal(e)) => return Err(e),
                Err(Attempt::Net(e)) if !e.is_transient() => return Err(RegistryError::Net(e)),
                Err(Attempt::Net(e)) => (RegistryError::Net(e), None),
                Err(Attempt::Status(s, ra)) => {
                    let e = RegistryError::Status {
                        status: s,
                        url: url.redacted(),
                    };
                    if !e.is_transient() {
                        return Err(e);
                    }
                    (e, ra)
                }
            };
            if attempt >= self.retry.max_attempts {
                return Err(err);
            }
            if !sleep_unless_cancelled(self.retry.delay(attempt, retry_after), &self.cancel) {
                return Err(RegistryError::Cancelled);
            }
        }
    }
}

/// Outcome of one attempt inside the retry loop.
enum Attempt {
    Net(NetError),
    Status(u16, Option<Duration>),
    Fatal(RegistryError),
}
