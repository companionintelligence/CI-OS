"""Tests for ci_setup.captive: the nine probe URLs in both states, header safety, routing in front of the portal."""
import random
import unittest

import helpers
from ci_setup import captive
from ci_setup.errors import ValidationError

AP = "192.168.99.1"
PORTAL = "http://192.168.99.1/"
NINE = ("/generate_204", "/gen_204", "/hotspot-detect.html", "/library/test/success.html", "/connecttest.txt", "/ncsi.txt",
        "/redirect", "/canonical.html", "/success.txt")


def get(path, state, method="GET"):
    return captive.probe_response(method, path, state, AP)


class Probes(unittest.TestCase):
    def test_there_are_nine_probe_urls(self):
        self.assertEqual(sorted(NINE), sorted(captive.PROBE_PATHS))

    def test_pending_redirects_every_probe_to_the_portal(self):
        for path in NINE:
            status, headers, body = get(path, "pending")
            self.assertEqual(302, status, path)
            self.assertEqual(PORTAL, captive.header((status, headers, body), "Location"), path)
            self.assertIn(PORTAL.encode(), body)

    def test_done_answers_like_the_real_services(self):
        expect = {
            "/generate_204": (204, b""), "/gen_204": (204, b""),
            "/hotspot-detect.html": (200, b"<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"),
            "/library/test/success.html": (200, b"<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"),
            "/connecttest.txt": (200, b"Microsoft Connect Test"), "/ncsi.txt": (200, b"Microsoft NCSI"),
            "/canonical.html": (200, b"success\n"), "/success.txt": (200, b"success\n"),
        }
        for path, (status, body) in expect.items():
            r = get(path, "done")
            self.assertEqual((status, body), (r[0], r[2]), path)
        self.assertEqual(302, get("/redirect", "done")[0])                # Windows' redirect probe stays a redirect

    def test_content_types(self):
        self.assertTrue(captive.header(get("/hotspot-detect.html", "done"), "Content-Type").startswith("text/html"))
        self.assertTrue(captive.header(get("/connecttest.txt", "done"), "Content-Type").startswith("text/plain"))
        self.assertIsNone(captive.header(get("/generate_204", "done"), "Content-Type"))

    def test_204_has_no_content_length_and_no_body(self):
        r = get("/generate_204", "done")
        self.assertIsNone(captive.header(r, "Content-Length"))
        self.assertEqual(b"", r[2])
        r = get("/generate_204", "done", "HEAD")
        self.assertEqual(b"", r[2])

    def test_content_length_matches_the_body_and_head_keeps_it(self):
        for state in captive.STATES:
            for path in NINE:
                g = get(path, state)
                h = get(path, state, "HEAD")
                if g[0] != 204:
                    self.assertEqual(str(len(g[2])), captive.header(g, "Content-Length"), (state, path))
                    self.assertEqual(captive.header(g, "Content-Length"), captive.header(h, "Content-Length"), (state, path))
                self.assertEqual(b"", h[2])
                self.assertEqual(g[0], h[0])

    def test_no_cache_everywhere(self):
        for state in captive.STATES:
            for path in NINE:
                r = get(path, state)
                self.assertIn("no-store", captive.header(r, "Cache-Control"))
                self.assertEqual("no-cache", captive.header(r, "Pragma"))
                self.assertEqual("nosniff", captive.header(r, "X-Content-Type-Options"))

    def test_other_methods_are_refused_on_probe_urls(self):
        for m in ("POST", "PUT", "DELETE", "OPTIONS", "PATCH"):
            r = get("/generate_204", "done", m)
            self.assertEqual(405, r[0])
            self.assertEqual("GET, HEAD", captive.header(r, "Allow"))

    def test_non_probe_path_is_not_handled_here(self):
        self.assertIsNone(captive.probe_response("GET", "/", "pending", AP))
        self.assertIsNone(captive.probe_response("GET", "/api/v1/status", "done", AP))
        self.assertIsNone(captive.probe_response("GET", "/generate_204/", "pending", AP))        # exact paths only
        self.assertIsNone(captive.probe_response("GET", "/GENERATE_204", "pending", AP))

    def test_unknown_state_is_an_error(self):
        with self.assertRaises(ValueError):
            captive.probe_response("GET", "/generate_204", "maybe", AP)

    def test_the_redirect_target_must_be_a_valid_address(self):
        for bad in ("evil.example", "192.168.99.1\r\nX-Evil: 1", "192.168.99.1/", "", "192.168.099.1", "1.2.3"):
            with self.assertRaises(ValidationError):
                captive.portal_url(bad)
            with self.assertRaises(ValidationError):
                captive.redirect_response(bad)


class Routing(unittest.TestCase):
    def route(self, method, target, host, state="pending"):
        return captive.route(method, target, host, state, AP)

    def test_probes_win_whatever_the_host(self):
        for host in ("connectivitycheck.gstatic.com", "captive.apple.com", "www.msftconnecttest.com", AP, None, "", "x" * 400):
            r = self.route("GET", "/generate_204", host)
            self.assertEqual(302, r[0], host)

    def test_query_string_and_fragment_are_ignored(self):
        self.assertEqual(302, self.route("GET", "/generate_204?x=1&y=2", "a.test")[0])
        self.assertEqual(204, self.route("GET", "/generate_204?x=1", "a.test", "done")[0])
        self.assertEqual(302, self.route("GET", "/hotspot-detect.html#frag", "a.test")[0])

    def test_foreign_host_non_probe_is_redirected_while_pending_and_404_when_done(self):
        for target in ("/", "/index.html", "/some/page", "/favicon.ico"):
            r = self.route("GET", target, "example.org")
            self.assertEqual((302, PORTAL), (r[0], captive.header(r, "Location")), target)
            self.assertEqual(404, self.route("GET", target, "example.org", "done")[0])
        self.assertEqual(302, self.route("HEAD", "/x", "example.org")[0])
        self.assertEqual(b"", self.route("HEAD", "/x", "example.org")[2])

    def test_own_host_non_probe_goes_to_the_portal(self):
        for host in (AP, "192.168.99.1:80", "companion.local", "COMPANION.LOCAL", "companion-os.local",
                     "setup.ci.computer", "setup.ci.computer:80"):
            self.assertIsNone(self.route("GET", "/", host), host)
            self.assertIsNone(self.route("POST", "/api/v1/auth", host), host)
        # the portal's own port counts only when the caller says which port it listens on
        self.assertEqual(302, self.route("GET", "/", "192.168.99.1:8080")[0])
        self.assertIsNone(captive.route("GET", "/", "192.168.99.1:8080", "pending", AP, port=8080))

    def test_lookalike_hosts_are_foreign(self):
        for host in ("192.168.99.10", "192.168.99.1.evil.test", "evil.test:192.168.99.1", "companion.local.evil.test",
                     "xcompanion.local", "192.168.99.1\r\nHost: x", "192.168.99.1@evil.test", "[::1]", ""):
            self.assertFalse(captive.is_portal_host(host, AP), host)

    def test_port_is_matched_exactly(self):
        self.assertTrue(captive.is_portal_host("192.168.99.1:8080", AP, port=8080))
        self.assertFalse(captive.is_portal_host("192.168.99.1:8081", AP, port=8080))
        self.assertFalse(captive.is_portal_host("192.168.99.1:8080", AP))

    def test_foreign_host_with_a_write_method(self):
        for m in ("POST", "PUT", "DELETE", "PATCH"):
            self.assertEqual(405, self.route(m, "/x", "example.org")[0])

    def test_bad_targets(self):
        for target in ("", "x", "//", "/a b", "/a\tb", "/a\nb", "/a\x00b", "/a\x7fb", "/\U000000e9", "/" + "a" * 600, "http://x/y", None, 5):
            r = self.route("GET", target, "example.org")
            self.assertEqual(400 if target not in ("//",) else 302, r[0], repr(target))
        self.assertEqual(400, self.route("BREW", "/", "example.org")[0])

    def test_split_path(self):
        self.assertEqual("/a", captive.split_path("/a?b=c"))
        self.assertEqual("/a", captive.split_path("/a#b"))
        self.assertEqual("/", captive.split_path("/"))
        self.assertIsNone(captive.split_path("a"))
        self.assertIsNone(captive.split_path("/a b"))


class HeaderSafety(unittest.TestCase):
    def test_nothing_from_the_request_reaches_the_response(self):
        rnd = random.Random(helpers.fuzz_seed())
        evil_hosts = ["evil\r\nSet-Cookie: x=1", "a\nLocation: http://evil/", "h" * 3000, "\x00", "\ud800", "a b", "x:y:z"]
        evil_paths = ["/generate_204\r\nX: y", "/x\r\nLocation: http://evil", "/%0d%0aSet-Cookie:x", "/\r\n", "/a?b=\r\nc"]
        for _ in range(helpers.fuzz_n(20000) // 4 or 1):
            host = rnd.choice(evil_hosts + [helpers.rand_text(rnd, 30), None])
            target = rnd.choice(NINE + tuple(evil_paths) + ("/" + helpers.rand_text(rnd, 30),))
            method = rnd.choice(["GET", "HEAD", "POST", "XYZ", helpers.rand_text(rnd, 5)])
            state = rnd.choice(captive.STATES)
            r = captive.route(method, target, host, state, AP)
            if r is None:
                continue
            status, headers, body = r
            self.assertIn(status, captive.STATUS_TEXT)
            for name, value in headers:
                self.assertNotRegex(name + value, "[\r\n\x00]")
            if host and len(host) > 5:
                blob = " ".join(value for _, value in headers) + body.decode("latin-1")
                self.assertNotIn(host, blob)
            loc = captive.header(r, "Location")
            self.assertTrue(loc is None or loc == PORTAL, loc)
            if status in (302, 404, 400):
                self.assertNotIn(b"evil", body)
            raw = captive.serialize(r)
            head, _, tail = raw.partition(b"\r\n\r\n")
            self.assertTrue(head.startswith(b"HTTP/1.1 %d " % status))
            self.assertEqual(body, tail)
            for line in head.split(b"\r\n")[1:]:
                self.assertIn(b": ", line)

    def test_serialize_example(self):
        raw = captive.serialize(get("/connecttest.txt", "done"))
        self.assertTrue(raw.startswith(b"HTTP/1.1 200 OK\r\n"))
        self.assertTrue(raw.endswith(b"\r\n\r\nMicrosoft Connect Test"))
        self.assertIn(b"Content-Length: 22\r\n", raw)
        self.assertEqual("HTTP/1.1 204 No Content", captive.status_line(204))
        self.assertEqual("HTTP/1.1 999 Unknown", captive.status_line(999))


if __name__ == "__main__":
    unittest.main()
