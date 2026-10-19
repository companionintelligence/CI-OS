//! HTTP transport for model downloads: URL handling, the redirect/SSRF policy, retry timing
//! and the [`Transport`] trait with its `ureq` implementation.
//!
//! Layering (everything above `Transport` is transport-independent, so a `curl`-based
//! implementation can replace [`UreqTransport`] without touching the engine):
//!
//! ```text
//!   registry / fetch      what to ask for, resume, verification
//!        |
//!   Fetcher               walks redirects hop by hop, applying NetPolicy to every hop
//!        |
//!   dyn Transport         ONE request, no redirects, no status-to-error mapping
//! ```
//!
//! # Policy (the baseline is Ollama's own, see report 03 section 3.2)
//!
//! * https only. No https -> http downgrade, ever.
//! * A host is trusted if it matches the allow-list (`ollama.com`, `ollama.ai`, `hf.co`,
//!   `huggingface.co`, `cloudflarestorage.com`, by suffix) or is the registry the operator
//!   configured. Any other host must resolve to **public** addresses only (no loopback,
//!   private, link-local, CGNAT, documentation, benchmarking, 6to4, v4-mapped ...); the
//!   resolver hands the connector only validated addresses, so the connection cannot be
//!   rebound to an internal address between the check and the connect.
//! * A configured registry on a loopback host may use plain `http` (the traffic never
//!   leaves the machine); redirects from such a registry may stay on loopback. This is how
//!   the offline tests run and it needs no flag.
//! * At most [`MAX_REDIRECTS`] hops; no user-info in URLs.
//! * `Authorization`/`Cookie` headers are never forwarded to another origin. (Nothing in
//!   this release sends one: the Ollama registry is anonymous.)
//! * Query strings of redirect targets carry presigned credentials (`X-Amz-Signature=`,
//!   `Signature=`): they are never logged. [`Url`]'s `Debug` is redacted and every error
//!   message passes through [`redact_text`].
//!
//! Behind a proxy (`HTTPS_PROXY`, honouring `NO_PROXY`) the *proxy* resolves the target, so
//! the public-address check cannot run; with a proxy, hosts outside the allow-list are
//! therefore refused instead of being checked.

use std::fmt;
use std::io::{self, Read};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use ureq::unversioned::resolver::{ResolvedSocketAddrs, Resolver};
use ureq::unversioned::transport::{DefaultConnector, NextTimeout};

/// Redirect hops followed per request (registry -> CDN needs one; Hugging Face two).
pub const MAX_REDIRECTS: usize = 5;
/// Hosts (and their subdomains) a registry may redirect to without further address checks.
pub const DEFAULT_ALLOWED_SUFFIXES: [&str; 5] = [
    "ollama.com",
    "ollama.ai",
    "hf.co",
    "huggingface.co",
    "cloudflarestorage.com",
];
/// Marker in the `io::Error` the resolver raises, so the transport can report a policy
/// refusal as such instead of as a generic I/O error.
const POLICY_MARK: &str = "ci-stick network policy: ";

// ---------------------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetErrorKind {
    /// Refused by [`NetPolicy`]; retrying cannot help.
    Policy,
    /// The URL could not be parsed or is not acceptable.
    BadUrl,
    Timeout,
    /// DNS, refused/reset connection, unreachable network.
    Connect,
    /// Broken connection while sending or reading.
    Io,
    /// TLS failure (certificate problems are not transient).
    Tls,
    /// The server spoke invalid HTTP.
    Protocol,
    TooManyRedirects,
    Other,
}

/// A network failure. `message` has been passed through [`redact_text`].
#[derive(Debug, Clone)]
pub struct NetError {
    pub kind: NetErrorKind,
    pub message: String,
}

impl NetError {
    pub fn new(kind: NetErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: redact_text(&message.into()),
        }
    }

    /// `true` for failures a later attempt can plausibly fix (the network, not the policy).
    pub fn is_transient(&self) -> bool {
        matches!(
            self.kind,
            NetErrorKind::Timeout
                | NetErrorKind::Connect
                | NetErrorKind::Io
                | NetErrorKind::Protocol
        )
    }
}

impl fmt::Display for NetError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for NetError {}

/// Classify an I/O error raised while reading a response body.
pub fn io_error_to_net(e: &io::Error) -> NetError {
    use io::ErrorKind as K;
    let kind = match e.kind() {
        K::TimedOut | K::WouldBlock => NetErrorKind::Timeout,
        K::ConnectionRefused | K::ConnectionReset | K::ConnectionAborted | K::NotConnected => {
            NetErrorKind::Connect
        }
        _ => NetErrorKind::Io,
    };
    NetError::new(kind, e.to_string())
}

// ---------------------------------------------------------------------------------------
// URLs
// ---------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scheme {
    Http,
    Https,
}

impl Scheme {
    fn as_str(self) -> &'static str {
        match self {
            Scheme::Http => "http",
            Scheme::Https => "https",
        }
    }
    fn default_port(self) -> u16 {
        match self {
            Scheme::Http => 80,
            Scheme::Https => 443,
        }
    }
}

/// A minimal absolute `http(s)` URL. No user-info, no fragment, ASCII only.
#[derive(Clone, PartialEq, Eq)]
pub struct Url {
    pub scheme: Scheme,
    /// Lowercase host name or IP literal (IPv6 without brackets).
    pub host: String,
    pub port: Option<u16>,
    /// Path and query, always starting with `/`.
    pub path_query: String,
}

impl fmt::Debug for Url {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Redacted on purpose: a derived Debug would print presigned credentials.
        f.debug_tuple("Url").field(&self.redacted()).finish()
    }
}

fn is_host_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '-' | '.' | '_')
}

impl Url {
    pub fn parse(input: &str) -> Result<Self, NetError> {
        let bad = |why: &str| NetError::new(NetErrorKind::BadUrl, format!("bad URL: {why}"));
        if input.is_empty() || input.len() > 8192 {
            return Err(bad("empty or too long"));
        }
        if !input.is_ascii() || input.chars().any(|c| c.is_ascii_control() || c == ' ') {
            return Err(bad("contains non-ASCII, control or space characters"));
        }
        let lower_head: String = input
            .chars()
            .take(8)
            .collect::<String>()
            .to_ascii_lowercase();
        let (scheme, rest) = if lower_head.starts_with("https://") {
            (Scheme::Https, &input[8..])
        } else if lower_head.starts_with("http://") {
            (Scheme::Http, &input[7..])
        } else {
            return Err(bad("only http and https URLs are accepted"));
        };
        let rest = rest.split('#').next().unwrap_or("");
        let auth_end = rest.find(['/', '?']).unwrap_or(rest.len());
        let (authority, tail) = rest.split_at(auth_end);
        if authority.contains('@') {
            return Err(bad("user-info in a URL is not accepted"));
        }
        let (host, port) = if let Some(inner) = authority.strip_prefix('[') {
            let close = inner
                .find(']')
                .ok_or_else(|| bad("unterminated IPv6 literal"))?;
            let host = &inner[..close];
            host.parse::<Ipv6Addr>()
                .map_err(|_| bad("invalid IPv6 literal"))?;
            let after = &inner[close + 1..];
            let port = match after.strip_prefix(':') {
                Some(p) => Some(parse_port(p).ok_or_else(|| bad("invalid port"))?),
                None if after.is_empty() => None,
                None => return Err(bad("garbage after IPv6 literal")),
            };
            (host.to_ascii_lowercase(), port)
        } else {
            let (h, p) = match authority.rsplit_once(':') {
                Some((h, p)) => (h, Some(parse_port(p).ok_or_else(|| bad("invalid port"))?)),
                None => (authority, None),
            };
            if h.is_empty() || h.len() > 253 || !h.chars().all(is_host_char) {
                return Err(bad("invalid host"));
            }
            (h.to_ascii_lowercase(), p)
        };
        let path_query = if tail.is_empty() {
            "/".to_string()
        } else if tail.starts_with('?') {
            format!("/{tail}")
        } else {
            tail.to_string()
        };
        Ok(Url {
            scheme,
            host,
            port,
            path_query,
        })
    }

    /// Resolve a `Location` header value against `self`.
    pub fn join(&self, location: &str) -> Result<Url, NetError> {
        // An absolute URI with some other scheme (`ftp:`, `file:`, `javascript:`) is an error,
        // not a relative path that happens to contain a colon.
        let head = location.split(['/', '?', '#']).next().unwrap_or("");
        if let Some((scheme, _)) = head.split_once(':') {
            let looks_like_scheme = !scheme.is_empty()
                && scheme
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_ascii_alphabetic())
                && scheme
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
            if looks_like_scheme
                && !matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https")
            {
                return Err(NetError::new(
                    NetErrorKind::BadUrl,
                    format!("bad URL: redirect to a {scheme}: URL is not accepted (only http and https)"),
                ));
            }
        }
        let lower: String = location
            .chars()
            .take(8)
            .collect::<String>()
            .to_ascii_lowercase();
        if lower.starts_with("http://") || lower.starts_with("https://") {
            return Url::parse(location);
        }
        if let Some(rest) = location.strip_prefix("//") {
            return Url::parse(&format!("{}://{rest}", self.scheme.as_str()));
        }
        let base_path = self.path_query.split('?').next().unwrap_or("/");
        let path_query = if location.starts_with('/') {
            location.to_string()
        } else if location.starts_with('?') {
            format!("{base_path}{location}")
        } else {
            let dir = match base_path.rfind('/') {
                Some(i) => &base_path[..=i],
                None => "/",
            };
            format!("{dir}{location}")
        };
        let (path, query) = match path_query.split_once('?') {
            Some((p, q)) => (p.to_string(), Some(q.to_string())),
            None => (path_query.clone(), None),
        };
        let path = remove_dot_segments(path.split('#').next().unwrap_or("/"));
        let mut joined = format!(
            "{}://{}{}{}",
            self.scheme.as_str(),
            self.host_for_authority(),
            self.port.map(|p| format!(":{p}")).unwrap_or_default(),
            path
        );
        if let Some(q) = query {
            joined.push('?');
            joined.push_str(q.split('#').next().unwrap_or(""));
        }
        Url::parse(&joined)
    }

    fn host_for_authority(&self) -> String {
        if self.host.contains(':') {
            format!("[{}]", self.host)
        } else {
            self.host.clone()
        }
    }

    pub fn port_or_default(&self) -> u16 {
        self.port.unwrap_or_else(|| self.scheme.default_port())
    }

    /// `(scheme, host, port)` identity, for "same origin" decisions.
    pub fn origin(&self) -> (Scheme, &str, u16) {
        (self.scheme, &self.host, self.port_or_default())
    }

    /// The path without the query.
    pub fn path(&self) -> &str {
        self.path_query.split('?').next().unwrap_or("/")
    }

    pub fn has_query(&self) -> bool {
        self.path_query.contains('?')
    }

    /// The full URL, **including any query string**. Never log this; use [`Url::redacted`].
    pub fn full(&self) -> String {
        format!(
            "{}://{}{}{}",
            self.scheme.as_str(),
            self.host_for_authority(),
            self.port.map(|p| format!(":{p}")).unwrap_or_default(),
            self.path_query
        )
    }

    /// The URL without its query string (safe for logs, events and status files).
    pub fn redacted(&self) -> String {
        format!(
            "{}://{}{}{}",
            self.scheme.as_str(),
            self.host_for_authority(),
            self.port.map(|p| format!(":{p}")).unwrap_or_default(),
            self.path()
        )
    }

    /// `host[:port]` as it would appear in an `Authority`.
    pub fn authority(&self) -> String {
        format!(
            "{}{}",
            self.host_for_authority(),
            self.port.map(|p| format!(":{p}")).unwrap_or_default()
        )
    }

    pub fn is_loopback_host(&self) -> bool {
        is_loopback_host(&self.host)
    }
}

fn parse_port(p: &str) -> Option<u16> {
    if p.is_empty() || p.len() > 5 || !p.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    p.parse::<u16>().ok().filter(|&n| n != 0)
}

fn remove_dot_segments(path: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    let trailing_slash = path.ends_with('/') || path.ends_with("/.") || path.ends_with("/..");
    for seg in path.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            s => out.push(s),
        }
    }
    let mut r = format!("/{}", out.join("/"));
    if trailing_slash && !r.ends_with('/') {
        r.push('/');
    }
    r
}

/// `localhost`, `*.localhost` and loopback IP literals.
pub fn is_loopback_host(host: &str) -> bool {
    if host == "localhost" || host.ends_with(".localhost") {
        return true;
    }
    host.parse::<IpAddr>().is_ok_and(|ip| ip.is_loopback())
}

/// Replace the query string of every `http(s)://` URL inside `text` with `?<redacted>`.
/// Applied to every error message that may have been produced from a URL.
pub fn redact_text(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    loop {
        let lower = rest.to_ascii_lowercase();
        let found = [lower.find("http://"), lower.find("https://")]
            .into_iter()
            .flatten()
            .min();
        let Some(start) = found else {
            out.push_str(rest);
            return out;
        };
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        let end = tail
            .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '<' | '>' | ')' | ','))
            .unwrap_or(tail.len());
        let (url, after) = tail.split_at(end);
        match url.find('?') {
            Some(q) => {
                out.push_str(&url[..q]);
                out.push_str("?<redacted>");
            }
            None => out.push_str(url),
        }
        rest = after;
        if rest.is_empty() {
            return out;
        }
    }
}

// ---------------------------------------------------------------------------------------
// Public-address test
// ---------------------------------------------------------------------------------------

/// `true` if `ip` is a globally routable unicast address. Everything an SSRF would want
/// (loopback, private, link-local, CGNAT, documentation, benchmarking, 6to4, Teredo,
/// multicast, v4-mapped private ...) is `false`.
pub fn is_public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_v4(v4),
        IpAddr::V6(v6) => is_public_v6(v6),
    }
}

fn is_public_v4(ip: Ipv4Addr) -> bool {
    let [a, b, c, _] = ip.octets();
    !(ip.is_unspecified()
        || ip.is_loopback()
        || ip.is_private()
        || ip.is_link_local()
        || ip.is_broadcast()
        || ip.is_multicast()
        || ip.is_documentation()
        || a == 0                                   // 0.0.0.0/8 "this network"
        || (a == 100 && (64..=127).contains(&b))    // 100.64.0.0/10 CGNAT
        || (a == 192 && b == 0 && c == 0)           // 192.0.0.0/24 IETF protocol assignments
        || (a == 198 && (b == 18 || b == 19))       // 198.18.0.0/15 benchmarking
        || a >= 240) // 240.0.0.0/4 reserved
}

fn is_public_v6(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return is_public_v4(v4);
    }
    let seg = ip.segments();
    let first = seg[0];
    !(ip.is_unspecified()
        || ip.is_loopback()
        || ip.is_multicast()
        || (first & 0xfe00) == 0xfc00                      // fc00::/7 unique local
        || (first & 0xffc0) == 0xfe80                      // fe80::/10 link-local
        || (first & 0xffc0) == 0xfec0                      // fec0::/10 site-local (deprecated)
        || (first == 0x2001 && seg[1] == 0x0db8)           // 2001:db8::/32 documentation
        || (first == 0x2001 && seg[1] == 0)                // 2001::/32 Teredo
        || first == 0x2002                                 // 2002::/16 6to4
        || (first == 0x0064 && seg[1] == 0xff9b)           // 64:ff9b::/96 NAT64
        || (first == 0 && seg[..6] == [0, 0, 0, 0, 0, 0])  // ::/96 v4-compatible
        || (first & 0xe000) != 0x2000) // outside 2000::/3 global unicast
}

// ---------------------------------------------------------------------------------------
// Policy
// ---------------------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct NetPolicy {
    allowed_suffixes: Vec<String>,
    trusted_hosts: Vec<String>,
    /// The configured registry is a loopback host: `http` to loopback hosts is accepted.
    pub allow_loopback_http: bool,
    /// Requests go through an HTTP(S) proxy (target addresses cannot be checked).
    pub proxy_active: bool,
    pub max_redirects: usize,
}

impl NetPolicy {
    /// Policy for talking to `registry` (the operator-configured base URL).
    pub fn for_registry(registry: &Url) -> Self {
        let loopback_http = registry.scheme == Scheme::Http && registry.is_loopback_host();
        Self {
            allowed_suffixes: DEFAULT_ALLOWED_SUFFIXES
                .iter()
                .map(|s| s.to_string())
                .collect(),
            trusted_hosts: vec![registry.host.clone()],
            allow_loopback_http: loopback_http,
            proxy_active: false,
            max_redirects: MAX_REDIRECTS,
        }
    }

    /// Everything on loopback over plain http, for tests of the library API.
    pub fn test_loopback() -> Self {
        Self {
            allowed_suffixes: Vec::new(),
            trusted_hosts: vec!["127.0.0.1".into(), "localhost".into(), "::1".into()],
            allow_loopback_http: true,
            proxy_active: false,
            max_redirects: MAX_REDIRECTS,
        }
    }

    /// Trust one more host exactly (e.g. a mirror's CDN named by the operator).
    pub fn trust_host(&mut self, host: &str) {
        self.trusted_hosts.push(host.to_ascii_lowercase());
    }

    /// `true` if `host` is trusted without an address check.
    pub fn is_trusted_host(&self, host: &str) -> bool {
        if self.trusted_hosts.iter().any(|h| h == host) {
            return true;
        }
        self.allowed_suffixes
            .iter()
            .any(|s| host == s || host.ends_with(&format!(".{s}")))
    }

    /// Check a URL before connecting: scheme, user-info (already impossible), and, for
    /// hosts that are not trusted, the literal address or the proxy restriction.
    pub fn check_url(&self, url: &Url) -> Result<(), NetError> {
        let refuse = |why: String| Err(NetError::new(NetErrorKind::Policy, why));
        match url.scheme {
            Scheme::Https => {}
            Scheme::Http => {
                if !(self.allow_loopback_http && url.is_loopback_host()) {
                    return refuse(format!(
                        "refusing plain http to {}: only https is accepted",
                        url.redacted()
                    ));
                }
                return Ok(());
            }
        }
        if self.is_trusted_host(&url.host) {
            return Ok(());
        }
        if let Ok(ip) = url.host.parse::<IpAddr>() {
            if !is_public_ip(ip) {
                return refuse(format!(
                    "refusing {}: address is not a public one",
                    url.redacted()
                ));
            }
            return Ok(());
        }
        if is_loopback_host(&url.host) {
            return refuse(format!("refusing {}: loopback host", url.redacted()));
        }
        if self.proxy_active {
            return refuse(format!(
                "refusing {}: behind a proxy only the registry and its known CDN hosts are \
                 accepted (the destination address cannot be checked)",
                url.redacted()
            ));
        }
        Ok(())
    }

    /// Check a redirect from `from` to `to`.
    pub fn check_redirect(&self, from: &Url, to: &Url) -> Result<(), NetError> {
        if from.scheme == Scheme::Https && to.scheme == Scheme::Http {
            return Err(NetError::new(
                NetErrorKind::Policy,
                format!(
                    "refusing redirect from {} to plain http {}",
                    from.redacted(),
                    to.redacted()
                ),
            ));
        }
        self.check_url(to)
    }
}

// ---------------------------------------------------------------------------------------
// Retry timing
// ---------------------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct RetryPolicy {
    /// Total attempts per operation (the first try included).
    pub max_attempts: u32,
    pub base: Duration,
    pub max_delay: Duration,
    pub jitter: bool,
}

impl Default for RetryPolicy {
    /// 6 attempts, 1 2 4 8 16 s apart (cap 60 s), jittered.
    fn default() -> Self {
        Self {
            max_attempts: 6,
            base: Duration::from_secs(1),
            max_delay: Duration::from_secs(60),
            jitter: true,
        }
    }
}

impl RetryPolicy {
    /// No waiting; for tests.
    pub fn immediate(max_attempts: u32) -> Self {
        Self {
            max_attempts,
            base: Duration::from_millis(1),
            max_delay: Duration::from_millis(5),
            jitter: false,
        }
    }

    /// Delay before attempt number `attempt + 1`, given that `attempt` (1-based) failed.
    /// A server `Retry-After` is honoured, capped at four times the maximum delay.
    pub fn delay(&self, attempt: u32, retry_after: Option<Duration>) -> Duration {
        let exp = attempt.saturating_sub(1).min(16);
        let mut d = self
            .base
            .checked_mul(1u32 << exp)
            .unwrap_or(self.max_delay)
            .min(self.max_delay);
        if self.jitter {
            // between 50 % and 100 % of the nominal delay
            let f = 0.5 + 0.5 * random_unit();
            d = d.mul_f64(f);
        }
        match retry_after {
            Some(ra) => d.max(ra.min(self.max_delay.saturating_mul(4))),
            None => d,
        }
    }
}

/// A uniform value in `[0, 1)`; jitter does not need to be cryptographic.
fn random_unit() -> f64 {
    let mut b = [0u8; 4];
    if getrandom::getrandom(&mut b).is_err() {
        return 0.5;
    }
    f64::from(u32::from_le_bytes(b)) / (f64::from(u32::MAX) + 1.0)
}

/// Parse a `Retry-After: <seconds>` value (the HTTP-date form is ignored).
pub fn parse_retry_after(value: &str) -> Option<Duration> {
    value.trim().parse::<u64>().ok().map(Duration::from_secs)
}

/// Sleep for `total`, waking early when `cancel` is set. Returns `false` if cancelled.
pub fn sleep_unless_cancelled(total: Duration, cancel: &AtomicBool) -> bool {
    let start = Instant::now();
    loop {
        if cancel.load(Ordering::Relaxed) {
            return false;
        }
        let left = total.saturating_sub(start.elapsed());
        if left.is_zero() {
            return true;
        }
        std::thread::sleep(left.min(Duration::from_millis(50)));
    }
}

// ---------------------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Get,
    Head,
}

#[derive(Debug, Clone)]
pub struct HttpRequest {
    pub method: Method,
    pub url: Url,
    /// Extra request headers (`Accept`, `Range`, ...). Never contains credentials unless the
    /// caller added them deliberately; [`Fetcher`] strips them on cross-origin redirects.
    pub headers: Vec<(String, String)>,
    /// Whole-exchange limit: connect, headers and body.
    pub timeout: Duration,
}

pub struct HttpResponse {
    pub status: u16,
    /// Header names lowercased.
    pub headers: Vec<(String, String)>,
    pub body: Box<dyn Read + Send>,
}

impl HttpResponse {
    pub fn header(&self, name: &str) -> Option<&str> {
        let name = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| *k == name)
            .map(|(_, v)| v.as_str())
    }

    pub fn content_length(&self) -> Option<u64> {
        self.header("content-length")
            .and_then(|v| v.trim().parse().ok())
    }
}

impl fmt::Debug for HttpResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HttpResponse")
            .field("status", &self.status)
            .finish_non_exhaustive()
    }
}

/// One HTTP exchange. Implementations do **not** follow redirects and do **not** turn 4xx/5xx
/// into errors; they report what the server said. Must be usable from several threads.
pub trait Transport: Send + Sync {
    fn send(&self, req: &HttpRequest) -> Result<HttpResponse, NetError>;
}

const USER_AGENT: &str = concat!("ci-stick/", env!("CARGO_PKG_VERSION"), " (Companion OS)");

/// [`Transport`] over `ureq` 3 with rustls (ring) and the bundled webpki roots.
pub struct UreqTransport {
    agent: ureq::Agent,
}

impl UreqTransport {
    /// Build an agent for `policy`. The proxy (if any) comes from `ALL_PROXY`/`HTTPS_PROXY`
    /// with `NO_PROXY`; a loopback-only policy never uses one.
    pub fn new(policy: &NetPolicy) -> Self {
        let proxy = if policy.allow_loopback_http {
            None
        } else {
            ureq::Proxy::try_from_env()
        };
        let proxy_host = proxy.as_ref().map(|p| p.host().to_ascii_lowercase());
        let config = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .max_redirects(0)
            .https_only(!policy.allow_loopback_http)
            .proxy(proxy)
            .user_agent(USER_AGENT)
            // Resumable ranges must be byte-exact: never ask for a content-encoding.
            .accept_encoding("identity")
            .timeout_connect(Some(Duration::from_secs(20)))
            .build();
        let resolver = PolicyResolver {
            policy: policy.clone(),
            proxy_host,
        };
        Self {
            agent: ureq::Agent::with_parts(config, DefaultConnector::default(), resolver),
        }
    }
}

impl Transport for UreqTransport {
    fn send(&self, req: &HttpRequest) -> Result<HttpResponse, NetError> {
        let url = req.url.full();
        let builder = match req.method {
            Method::Get => self.agent.get(&url).config(),
            Method::Head => self.agent.head(&url).config(),
        };
        let mut builder = builder.timeout_global(Some(req.timeout)).build();
        for (k, v) in &req.headers {
            builder = builder.header(k.as_str(), v.as_str());
        }
        let resp = builder.call().map_err(map_ureq_error)?;
        let status = resp.status().as_u16();
        let headers = resp
            .headers()
            .iter()
            .filter_map(|(k, v)| {
                v.to_str()
                    .ok()
                    .map(|v| (k.as_str().to_ascii_lowercase(), v.to_string()))
            })
            .collect();
        let body: Box<dyn Read + Send> = if req.method == Method::Head {
            Box::new(io::empty())
        } else {
            Box::new(resp.into_body().into_reader())
        };
        Ok(HttpResponse {
            status,
            headers,
            body,
        })
    }
}

fn map_ureq_error(e: ureq::Error) -> NetError {
    use ureq::Error as E;
    match e {
        E::Timeout(_) => NetError::new(NetErrorKind::Timeout, "timed out"),
        E::HostNotFound => NetError::new(NetErrorKind::Connect, "host not found"),
        E::ConnectionFailed => NetError::new(NetErrorKind::Connect, "connection failed"),
        E::Io(io) => {
            let msg = io.to_string();
            if io.kind() == io::ErrorKind::PermissionDenied && msg.contains(POLICY_MARK) {
                NetError::new(NetErrorKind::Policy, msg)
            } else {
                io_error_to_net(&io)
            }
        }
        E::BadUri(m) => NetError::new(NetErrorKind::BadUrl, m),
        E::Protocol(p) => NetError::new(NetErrorKind::Protocol, p.to_string()),
        E::TooManyRedirects => NetError::new(NetErrorKind::TooManyRedirects, "too many redirects"),
        other => {
            let msg = other.to_string();
            let lower = msg.to_ascii_lowercase();
            if lower.contains("tls") || lower.contains("certificate") || lower.contains("rustls") {
                NetError::new(NetErrorKind::Tls, msg)
            } else {
                NetError::new(NetErrorKind::Other, msg)
            }
        }
    }
}

/// Resolves names but hands the connector only addresses the policy accepts, so a name
/// that points at an internal address (or is re-pointed after the policy check) cannot be
/// connected to.
#[derive(Debug)]
struct PolicyResolver {
    policy: NetPolicy,
    proxy_host: Option<String>,
}

impl Resolver for PolicyResolver {
    fn resolve(
        &self,
        uri: &ureq::http::Uri,
        _config: &ureq::config::Config,
        _timeout: NextTimeout,
    ) -> Result<ResolvedSocketAddrs, ureq::Error> {
        let host = uri
            .host()
            .ok_or_else(|| ureq::Error::BadUri("no host".into()))?
            .trim_matches(['[', ']'])
            .to_ascii_lowercase();
        let port = uri
            .port_u16()
            .or(match uri.scheme_str() {
                Some("https") => Some(443),
                Some("http") => Some(80),
                _ => None,
            })
            .ok_or_else(|| ureq::Error::BadUri("no port".into()))?;
        let all: Vec<SocketAddr> = (host.as_str(), port)
            .to_socket_addrs()
            .map_err(ureq::Error::Io)?
            .collect();
        let trusted = self.policy.is_trusted_host(&host)
            || self.proxy_host.as_deref() == Some(host.as_str())
            || (self.policy.allow_loopback_http && is_loopback_host(&host));
        let mut out = self.empty();
        for addr in all {
            if (trusted || is_public_ip(addr.ip())) && out.len() < 16 {
                out.push(addr);
            }
        }
        if out.is_empty() {
            return Err(ureq::Error::Io(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("{POLICY_MARK}{host} resolves to no public address"),
            )));
        }
        Ok(out)
    }
}

// ---------------------------------------------------------------------------------------
// Redirect-walking client
// ---------------------------------------------------------------------------------------

/// Sends requests through a [`Transport`] and follows redirects itself, applying the
/// [`NetPolicy`] to the first URL and to every hop.
#[derive(Clone)]
pub struct Fetcher {
    transport: Arc<dyn Transport>,
    policy: Arc<NetPolicy>,
}

fn is_sensitive_header(name: &str) -> bool {
    matches!(
        name.to_ascii_lowercase().as_str(),
        "authorization" | "cookie" | "proxy-authorization"
    )
}

impl Fetcher {
    pub fn new(transport: Arc<dyn Transport>, policy: NetPolicy) -> Self {
        Self {
            transport,
            policy: Arc::new(policy),
        }
    }

    /// The production client for `registry`: ureq transport, policy derived from the URL.
    pub fn for_registry(registry: &Url) -> Self {
        let mut policy = NetPolicy::for_registry(registry);
        policy.proxy_active = !policy.allow_loopback_http
            && ureq::Proxy::try_from_env().is_some_and(|p| !p.is_no_proxy(&uri_of(registry)));
        let transport = UreqTransport::new(&policy);
        Self::new(Arc::new(transport), policy)
    }

    pub fn policy(&self) -> &NetPolicy {
        &self.policy
    }

    /// Send one request and follow redirects. Returns the final response together with the
    /// URL it came from (the presigned CDN URL after a redirect; keep it out of logs).
    pub fn send(
        &self,
        method: Method,
        url: &Url,
        headers: &[(String, String)],
        timeout: Duration,
    ) -> Result<(HttpResponse, Url), NetError> {
        self.policy.check_url(url)?;
        let mut current = url.clone();
        let mut headers: Vec<(String, String)> = headers.to_vec();
        for hop in 0..=self.policy.max_redirects {
            let resp = self.transport.send(&HttpRequest {
                method,
                url: current.clone(),
                headers: headers.clone(),
                timeout,
            })?;
            if !matches!(resp.status, 301 | 302 | 303 | 307 | 308) {
                return Ok((resp, current));
            }
            let Some(loc) = resp.header("location") else {
                return Ok((resp, current));
            };
            if hop == self.policy.max_redirects {
                break;
            }
            let next = current.join(loc)?;
            self.policy.check_redirect(&current, &next)?;
            if next.origin() != current.origin() {
                headers.retain(|(k, _)| !is_sensitive_header(k));
            }
            drop(resp);
            current = next;
        }
        Err(NetError::new(
            NetErrorKind::TooManyRedirects,
            format!(
                "more than {} redirects from {}",
                self.policy.max_redirects,
                url.redacted()
            ),
        ))
    }
}

fn uri_of(url: &Url) -> ureq::http::Uri {
    url.redacted()
        .parse()
        .unwrap_or_else(|_| ureq::http::Uri::from_static("http://invalid/"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_redacts_urls() {
        let u = Url::parse("HTTPS://Example.COM:8443/a/b?X-Amz-Signature=abc#frag").unwrap();
        assert_eq!(u.scheme, Scheme::Https);
        assert_eq!(u.host, "example.com");
        assert_eq!(u.port, Some(8443));
        assert_eq!(u.path_query, "/a/b?X-Amz-Signature=abc");
        assert_eq!(u.redacted(), "https://example.com:8443/a/b");
        assert!(
            !format!("{u:?}").contains("abc"),
            "Debug must not leak the query"
        );
        assert_eq!(u.full(), "https://example.com:8443/a/b?X-Amz-Signature=abc");

        let v6 = Url::parse("http://[::1]:5000/x").unwrap();
        assert_eq!(v6.host, "::1");
        assert!(v6.is_loopback_host());
        assert_eq!(v6.full(), "http://[::1]:5000/x");

        assert_eq!(Url::parse("https://h").unwrap().path_query, "/");
        assert_eq!(Url::parse("https://h?x=1").unwrap().path_query, "/?x=1");
    }

    #[test]
    fn rejects_bad_urls() {
        for bad in [
            "",
            "ftp://x/",
            "file:///etc/passwd",
            "https://user:pw@host/",
            "https://host name/",
            "https://host/\r\nHost: evil",
            "https://",
            "https://:80/",
            "https://h:0/",
            "https://h:99999/",
            "https://h/é",
            "https://[::1/",
            "//host/path",
        ] {
            assert!(Url::parse(bad).is_err(), "{bad:?} must be rejected");
        }
    }

    #[test]
    fn joins_locations() {
        let base = Url::parse("https://registry.example/v2/library/m/blobs/sha256:ab?x=1").unwrap();
        let cases = [
            ("https://cdn.example/p?q=1", "https://cdn.example/p?q=1"),
            ("//cdn.example/p", "https://cdn.example/p"),
            ("/abs/path?z=2", "https://registry.example/abs/path?z=2"),
            ("rel", "https://registry.example/v2/library/m/blobs/rel"),
            ("../up", "https://registry.example/v2/library/m/up"),
            (
                "?only=q",
                "https://registry.example/v2/library/m/blobs/sha256:ab?only=q",
            ),
        ];
        for (loc, want) in cases {
            assert_eq!(base.join(loc).unwrap().full(), want, "{loc}");
        }
    }

    #[test]
    fn redacts_query_strings_in_text() {
        let s = "error sending https://x.r2.cloudflarestorage.com/ollama/blob?X-Amz-Signature=SECRET&a=b: reset, \
                 and also (http://h/p?token=ZZZ) done";
        let r = redact_text(s);
        assert!(!r.contains("SECRET") && !r.contains("ZZZ"), "{r}");
        assert!(r.contains("https://x.r2.cloudflarestorage.com/ollama/blob?<redacted>"));
        assert!(r.contains("http://h/p?<redacted>"));
        assert_eq!(redact_text("no urls here"), "no urls here");
        assert_eq!(redact_text("https://h/p"), "https://h/p");
    }

    #[test]
    fn public_address_table() {
        let private = [
            "127.0.0.1",
            "10.1.2.3",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.1.1",
            "169.254.169.254",
            "100.64.0.1",
            "100.127.255.255",
            "0.0.0.0",
            "0.1.2.3",
            "192.0.2.1",
            "198.51.100.7",
            "203.0.113.9",
            "198.18.0.1",
            "198.19.255.255",
            "192.0.0.8",
            "224.0.0.1",
            "255.255.255.255",
            "240.0.0.1",
            "::",
            "::1",
            "fe80::1",
            "fc00::1",
            "fd12:3456::1",
            "ff02::1",
            "2001:db8::1",
            "2002:c000:204::1",
            "::ffff:127.0.0.1",
            "::ffff:10.0.0.1",
            "::ffff:169.254.169.254",
            "64:ff9b::1",
            "2001::1",
            "::1.2.3.4",
        ];
        for s in private {
            assert!(!is_public_ip(s.parse().unwrap()), "{s} must not be public");
        }
        let public = [
            "8.8.8.8",
            "1.1.1.1",
            "104.18.0.1",
            "100.63.255.255",
            "100.128.0.1",
            "198.17.0.1",
            "198.20.0.1",
            "172.15.0.1",
            "172.32.0.1",
            "2606:4700:4700::1111",
            "2a00:1450:4001::1",
            "::ffff:8.8.8.8",
        ];
        for s in public {
            assert!(is_public_ip(s.parse().unwrap()), "{s} must be public");
        }
    }

    #[test]
    fn production_policy() {
        let reg = Url::parse("https://registry.ollama.ai").unwrap();
        let p = NetPolicy::for_registry(&reg);
        let ok = |u: &str| p.check_url(&Url::parse(u).unwrap()).is_ok();
        assert!(ok("https://registry.ollama.ai/v2/"));
        assert!(ok("https://abc.r2.cloudflarestorage.com/x?sig=1"));
        assert!(ok("https://cdn-lfs.huggingface.co/x"));
        assert!(
            ok("https://something.example.org/x"),
            "unknown names pass the URL check; the resolver checks addresses"
        );
        assert!(!ok("http://registry.ollama.ai/v2/"), "plain http");
        assert!(
            !ok("http://127.0.0.1:8000/x"),
            "plain http to loopback is test-only"
        );
        assert!(!ok("https://127.0.0.1/x"));
        assert!(!ok("https://localhost/x"));
        assert!(!ok("https://10.0.0.5/x"));
        assert!(!ok("https://[::1]/x"));
        assert!(!ok("https://169.254.169.254/latest/meta-data"));
        assert!(ok("https://8.8.8.8/x"));
        // lookalike of an allowed suffix is not allowed by suffix
        assert!(!p.is_trusted_host("evilollama.ai"));
        assert!(p.is_trusted_host("a.b.ollama.ai"));
        assert!(!p.is_trusted_host("ollama.ai.evil.com"));

        let from = Url::parse("https://registry.ollama.ai/x").unwrap();
        let down = Url::parse("http://cdn.example/x").unwrap();
        assert!(p.check_redirect(&from, &down).is_err(), "downgrade");
    }

    #[test]
    fn proxy_restricts_unknown_hosts() {
        let reg = Url::parse("https://registry.ollama.ai").unwrap();
        let mut p = NetPolicy::for_registry(&reg);
        p.proxy_active = true;
        assert!(p
            .check_url(&Url::parse("https://x.r2.cloudflarestorage.com/").unwrap())
            .is_ok());
        assert!(p
            .check_url(&Url::parse("https://unknown.example/").unwrap())
            .is_err());
    }

    #[test]
    fn loopback_registry_may_use_http_and_redirect_on_loopback() {
        let reg = Url::parse("http://127.0.0.1:5000").unwrap();
        let p = NetPolicy::for_registry(&reg);
        assert!(p.allow_loopback_http);
        assert!(p
            .check_url(&Url::parse("http://127.0.0.1:6000/blob").unwrap())
            .is_ok());
        assert!(p
            .check_url(&Url::parse("http://example.com/").unwrap())
            .is_err());
        // an https registry gets no such exception
        let prod = NetPolicy::for_registry(&Url::parse("https://registry.ollama.ai").unwrap());
        assert!(!prod.allow_loopback_http);
    }

    #[test]
    fn retry_delay_doubles_and_honours_retry_after() {
        let p = RetryPolicy {
            max_attempts: 6,
            base: Duration::from_secs(1),
            max_delay: Duration::from_secs(60),
            jitter: false,
        };
        let secs: Vec<u64> = (1..=8).map(|a| p.delay(a, None).as_secs()).collect();
        assert_eq!(secs, [1, 2, 4, 8, 16, 32, 60, 60]);
        assert_eq!(p.delay(1, Some(Duration::from_secs(30))).as_secs(), 30);
        assert_eq!(
            p.delay(1, Some(Duration::from_secs(100_000))).as_secs(),
            240,
            "capped"
        );
        let j = RetryPolicy { jitter: true, ..p };
        for a in 1..=6 {
            let d = j.delay(a, None);
            let nominal = Duration::from_secs(1 << (a - 1)).min(Duration::from_secs(60));
            assert!(
                d <= nominal && d >= nominal / 2,
                "{a}: {d:?} vs {nominal:?}"
            );
        }
        assert_eq!(parse_retry_after(" 7 "), Some(Duration::from_secs(7)));
        assert_eq!(parse_retry_after("Wed, 21 Oct 2026 07:28:00 GMT"), None);
    }

    #[test]
    fn sleep_is_interruptible() {
        let cancel = AtomicBool::new(true);
        let t = Instant::now();
        assert!(!sleep_unless_cancelled(Duration::from_secs(30), &cancel));
        assert!(t.elapsed() < Duration::from_secs(2));
        cancel.store(false, Ordering::Relaxed);
        assert!(sleep_unless_cancelled(Duration::from_millis(5), &cancel));
    }

    fn resolve_for(policy: &NetPolicy, uri: &str) -> Result<ResolvedSocketAddrs, ureq::Error> {
        use ureq::unversioned::transport::time::Duration as UDuration;
        let resolver = PolicyResolver {
            policy: policy.clone(),
            proxy_host: None,
        };
        let uri: ureq::http::Uri = uri.parse().unwrap();
        resolver.resolve(
            &uri,
            &ureq::config::Config::default(),
            NextTimeout {
                after: UDuration::NotHappening,
                reason: ureq::Timeout::Global,
            },
        )
    }

    #[test]
    fn the_resolver_hands_out_only_public_addresses_for_untrusted_names() {
        let prod = NetPolicy::for_registry(&Url::parse("https://registry.ollama.ai").unwrap());
        // `localhost` is not trusted, and resolves to loopback only: no address may be returned,
        // so a name re-pointed at an internal address cannot be connected to
        let err = resolve_for(&prod, "https://localhost:443/x").unwrap_err();
        assert!(
            matches!(&err, ureq::Error::Io(e) if e.kind() == io::ErrorKind::PermissionDenied),
            "{err:?}"
        );
        let err = resolve_for(&prod, "https://127.0.0.1:443/x").unwrap_err();
        assert!(matches!(err, ureq::Error::Io(_)));
        let err = resolve_for(&prod, "https://169.254.169.254:443/x").unwrap_err();
        assert!(matches!(err, ureq::Error::Io(_)));
        // a public literal passes
        assert_eq!(
            resolve_for(&prod, "https://8.8.8.8:443/x").unwrap().len(),
            1
        );
        // the operator's own loopback registry (tests) is trusted
        let dev = NetPolicy::for_registry(&Url::parse("http://127.0.0.1:5000").unwrap());
        assert_eq!(
            resolve_for(&dev, "http://127.0.0.1:5000/x").unwrap().len(),
            1
        );
        assert!(resolve_for(&dev, "http://10.0.0.1:80/x").is_err());
        // a configured proxy host is exempt (corporate proxies live on private addresses)
        let resolver = PolicyResolver {
            policy: prod.clone(),
            proxy_host: Some("10.1.2.3".into()),
        };
        let uri: ureq::http::Uri = "http://10.1.2.3:3128".parse().unwrap();
        let ok = resolver.resolve(
            &uri,
            &ureq::config::Config::default(),
            NextTimeout {
                after: ureq::unversioned::transport::time::Duration::NotHappening,
                reason: ureq::Timeout::Global,
            },
        );
        assert!(ok.is_ok());
    }

    /// A scripted transport for redirect-walking tests.
    struct Script(
        std::sync::Mutex<Vec<(u16, Option<String>)>>,
        std::sync::Mutex<Vec<HttpRequest>>,
    );

    impl Transport for Script {
        fn send(&self, req: &HttpRequest) -> Result<HttpResponse, NetError> {
            self.1.lock().unwrap().push(req.clone());
            let (status, loc) = self.0.lock().unwrap().remove(0);
            let mut headers = Vec::new();
            if let Some(l) = loc {
                headers.push(("location".to_string(), l));
            }
            Ok(HttpResponse {
                status,
                headers,
                body: Box::new(io::empty()),
            })
        }
    }

    #[test]
    fn fetcher_follows_and_strips_credentials_across_origins() {
        let script = Arc::new(Script(
            std::sync::Mutex::new(vec![
                (
                    307,
                    Some("https://x.r2.cloudflarestorage.com/blob?sig=S".into()),
                ),
                (206, None),
            ]),
            std::sync::Mutex::new(Vec::new()),
        ));
        let reg = Url::parse("https://registry.ollama.ai").unwrap();
        let f = Fetcher::new(script.clone(), NetPolicy::for_registry(&reg));
        let headers = vec![
            ("Range".to_string(), "bytes=0-9".to_string()),
            ("Authorization".to_string(), "Bearer T".to_string()),
        ];
        let (resp, fin) = f
            .send(
                Method::Get,
                &Url::parse("https://registry.ollama.ai/v2/a/blobs/b").unwrap(),
                &headers,
                Duration::from_secs(5),
            )
            .unwrap();
        assert_eq!(resp.status, 206);
        assert_eq!(fin.host, "x.r2.cloudflarestorage.com");
        let seen = script.1.lock().unwrap();
        assert!(seen[0].headers.iter().any(|(k, _)| k == "Authorization"));
        assert!(
            !seen[1].headers.iter().any(|(k, _)| k == "Authorization"),
            "must not follow to another origin"
        );
        assert!(seen[1].headers.iter().any(|(k, _)| k == "Range"));
    }

    #[test]
    fn fetcher_refuses_bad_hops_and_loops() {
        let reg = Url::parse("https://registry.ollama.ai").unwrap();
        let bad_targets = [
            "http://cdn.example/x",
            "https://127.0.0.1/x",
            "https://10.0.0.1/x",
            "https://169.254.169.254/x",
            "https://100.64.0.1/x",
        ];
        for t in bad_targets {
            let script = Arc::new(Script(
                std::sync::Mutex::new(vec![(302, Some(t.to_string())), (200, None)]),
                std::sync::Mutex::new(Vec::new()),
            ));
            let f = Fetcher::new(script.clone(), NetPolicy::for_registry(&reg));
            let err = f
                .send(
                    Method::Get,
                    &Url::parse("https://registry.ollama.ai/x").unwrap(),
                    &[],
                    Duration::from_secs(5),
                )
                .unwrap_err();
            assert_eq!(err.kind, NetErrorKind::Policy, "{t}: {err}");
            assert_eq!(
                script.1.lock().unwrap().len(),
                1,
                "{t}: the bad hop must never be requested"
            );
        }
        let looping = Arc::new(Script(
            std::sync::Mutex::new((0..20).map(|_| (302, Some("/again".to_string()))).collect()),
            std::sync::Mutex::new(Vec::new()),
        ));
        let f = Fetcher::new(looping, NetPolicy::for_registry(&reg));
        let err = f
            .send(
                Method::Get,
                &Url::parse("https://registry.ollama.ai/x").unwrap(),
                &[],
                Duration::from_secs(5),
            )
            .unwrap_err();
        assert_eq!(err.kind, NetErrorKind::TooManyRedirects);
    }
}
