"""Captive-portal detection: what the setup portal answers when a phone or laptop probes the network.

Every operating system tests a new Wi-Fi network by fetching a well-known URL and comparing the answer with what the open
internet would return. While setup is **pending** the portal answers every probe with a redirect to its own page, which
makes the OS open its sign-in sheet there. After setup is **done** it answers each probe exactly as the real service would,
so the sheet closes and the phone does not complain about a network without internet while it stays on the AP for the
last few seconds.

All functions are pure: ``(method, path, host, state, ap_ip)`` in, ``(status, headers, body)`` out. Nothing from the request
reaches a response header or body (the redirect target is built from the AP address only), so there is nothing to inject.

The nine probe URLs are those of Android (``/generate_204``, ``/gen_204``), Apple (``/hotspot-detect.html``,
``/library/test/success.html``), Windows (``/connecttest.txt``, ``/ncsi.txt``, ``/redirect``) and Firefox
(``/canonical.html``, ``/success.txt``). Their exact behaviour on current phones has not been checked against devices
(the manual checklist in docs/architecture/headless-setup.md does that); the bodies below are those the vendors document or
that are widely observed.
"""
from __future__ import annotations

from typing import Dict, Iterable, List, Optional, Tuple

from .validators import validate_ipv4

Response = Tuple[int, List[Tuple[str, str]], bytes]

STATES = ("pending", "done")

# path -> probe kind
PROBE_PATHS = {
    "/generate_204": "android",
    "/gen_204": "android",
    "/hotspot-detect.html": "apple",
    "/library/test/success.html": "apple",
    "/connecttest.txt": "msft_connect",
    "/ncsi.txt": "msft_ncsi",
    "/redirect": "msft_redirect",
    "/canonical.html": "firefox",
    "/success.txt": "firefox",
}

# What the real services answer (state "done").
_APPLE_BODY = b"<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
_DONE_BODIES = {
    "apple": (200, "text/html", _APPLE_BODY),
    "msft_connect": (200, "text/plain", b"Microsoft Connect Test"),
    "msft_ncsi": (200, "text/plain", b"Microsoft NCSI"),
    "firefox": (200, "text/plain", b"success\n"),
    "android": (204, "", b""),
}

STATUS_TEXT = {200: "OK", 204: "No Content", 302: "Found", 400: "Bad Request", 404: "Not Found",
               405: "Method Not Allowed"}

_NO_CACHE = [("Cache-Control", "no-store, no-cache, must-revalidate"), ("Pragma", "no-cache"), ("Expires", "0")]
_COMMON = [("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"), ("Connection", "close")]


def portal_url(ap_ip: str) -> str:
    """``http://<ap_ip>/``; the address is validated, so the result is always a plain dotted quad URL."""
    return "http://%s/" % validate_ipv4(ap_ip)


def _response(status: int, ctype: str, body: bytes, extra: Optional[List[Tuple[str, str]]] = None,
              head: bool = False) -> Response:
    headers = list(_NO_CACHE)
    if extra:
        headers.extend(extra)
    if ctype:
        headers.append(("Content-Type", ctype))
    if status != 204:  # RFC 7230 3.3.2: a 204 response carries no Content-Length
        headers.append(("Content-Length", str(len(body))))
    headers.extend(_COMMON)
    return status, headers, b"" if head or status == 204 else body


def redirect_response(ap_ip: str, head: bool = False) -> Response:
    """302 to the portal page."""
    url = portal_url(ap_ip)
    body = ("<html><body><a href=\"%s\">Companion OS setup</a></body></html>\n" % url).encode("ascii")
    return _response(302, "text/html; charset=utf-8", body, [("Location", url)], head)


def split_path(target: str) -> Optional[str]:
    """The path of a request target without query string or fragment; None if it is not a plain origin-form path (it
    contains a control character or space, does not start with '/', or is absurdly long)."""
    if not isinstance(target, str) or not 1 <= len(target) <= 512 or not target.startswith("/"):
        return None
    for ch in target:
        if ord(ch) <= 0x20 or ord(ch) >= 0x7F:
            return None
    return target.split("?", 1)[0].split("#", 1)[0]


def probe_kind(path: str) -> Optional[str]:
    return PROBE_PATHS.get(path)


def probe_response(method: str, path: str, state: str, ap_ip: str) -> Optional[Response]:
    """The answer to a probe path in the given state, or None when ``path`` is not one of the nine probe URLs. ``method``
    must be GET or HEAD (anything else: 405)."""
    kind = PROBE_PATHS.get(path)
    if kind is None:
        return None
    if method not in ("GET", "HEAD"):
        return _response(405, "text/plain", b"", [("Allow", "GET, HEAD")])
    head = method == "HEAD"
    if state not in STATES:
        raise ValueError("state must be 'pending' or 'done'")
    if state == "pending" or kind == "msft_redirect":
        return redirect_response(ap_ip, head)
    status, ctype, body = _DONE_BODIES[kind]
    return _response(status, ctype, body, None, head)


def is_portal_host(host: Optional[str], ap_ip: str, names: Iterable[str] = ("companion.local", "companion-os.local",
                                                                           "setup.ci.computer"),
                   port: Optional[int] = None) -> bool:
    """Is the ``Host`` header one of the names the portal answers to (its own address, optionally with a port, or one of
    ``names``)? Comparison is case-insensitive and exact."""
    if not isinstance(host, str) or not 1 <= len(host) <= 255:
        return False
    h = host.strip().lower()
    allowed = {validate_ipv4(ap_ip)}
    allowed.update(n.lower() for n in names)
    candidates = set(allowed)
    if port is not None:
        candidates.update("%s:%d" % (n, port) for n in allowed)
    candidates.update(n + ":80" for n in allowed)
    return h in candidates


def route(method: str, target: str, host: Optional[str], state: str, ap_ip: str,
          names: Iterable[str] = ("companion.local", "companion-os.local", "setup.ci.computer"),
          port: Optional[int] = None) -> Optional[Response]:
    """The captive layer in front of the portal.

    * a malformed request target gets 400;
    * a probe URL gets :func:`probe_response`;
    * any other URL for a host that is not the portal's own (a phone fetching some site, an app's HTTP check) is redirected
      to the portal while setup is pending and answered 404 once it is done;
    * a request for the portal's own host and a non-probe path returns None: the portal serves it.
    """
    if method not in ("GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"):
        return _response(400, "text/plain", b"")
    path = split_path(target)
    if path is None:
        return _response(400, "text/plain", b"bad request\n", None, method == "HEAD")
    resp = probe_response(method, path, state, ap_ip)
    if resp is not None:
        return resp
    if is_portal_host(host, ap_ip, names, port):
        return None
    if method not in ("GET", "HEAD"):
        return _response(405, "text/plain", b"", [("Allow", "GET, HEAD")])
    if state == "pending":
        return redirect_response(ap_ip, method == "HEAD")
    return _response(404, "text/plain", b"not found\n", None, method == "HEAD")


def status_line(status: int) -> str:
    return "HTTP/1.1 %d %s" % (status, STATUS_TEXT.get(status, "Unknown"))


def serialize(resp: Response) -> bytes:
    """The response as HTTP/1.1 bytes (for a minimal server and for tests)."""
    status, headers, body = resp
    lines = [status_line(status)] + ["%s: %s" % (k, v) for k, v in headers]
    return ("\r\n".join(lines) + "\r\n\r\n").encode("ascii") + body


def header(resp: Response, name: str) -> Optional[str]:
    """First value of a header, case-insensitively."""
    low = name.lower()
    for k, v in resp[1]:
        if k.lower() == low:
            return v
    return None


def headers_dict(resp: Response) -> Dict[str, str]:
    return {k: v for k, v in resp[1]}
