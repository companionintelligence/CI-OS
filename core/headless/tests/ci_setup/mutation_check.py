#!/usr/bin/env python3
"""Mutation check of the security-relevant functions of ci_setup.

A passing test suite only matters if it would FAIL when the code is wrong. This script proves that for the functions where being
wrong is a vulnerability: it copies the package, applies one small deliberate bug (a "mutant": a comparison weakened, a check
removed, an escape dropped, a constant changed), runs the tests that cover that code, and requires them to fail. A mutant that
survives means a test is missing. The mutated copies live in a temporary directory; nothing in the tree is touched.

Each mutant names the file, the exact text to replace (which must occur exactly once, so a refactor cannot silently turn a mutant
into a no-op) and the replacement. Run: python3 mutation_check.py [--only ID] [--list] [-j N]. Exit 0 when every mutant is killed,
1 when one survives or a specification is stale, 2 when it cannot run.
"""
import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HEADLESS = os.path.normpath(os.path.join(HERE, "..", ".."))
PKG = os.path.join(HEADLESS, "ci_setup")

V = ["test_validators", "test_fuzz_validators"]
ST = ["test_statement"]
RP = ["test_replay"]

# (id, file under ci_setup/, exact old text, new text, test modules that must fail)
MUTANTS = [
    # ---- validators: what reaches nmcli, hostapd, nft and logs
    ("val-ssid-chars-not-bytes", "validators.py", "if not 1 <= len(raw) <= SSID_MAX_BYTES:", "if not 1 <= len(s) <= SSID_MAX_BYTES:", V),
    ("val-ssid-controls-allowed", "validators.py", "    if has_control_char(s):\n        raise _fail(field, \"control_char\", \"control characters are not allowed\")", "    if False:\n        raise _fail(field, \"control_char\", \"control characters are not allowed\")", V),
    ("val-ssid-bidi-allowed", "validators.py", "        if ch in _BIDI_CONTROLS:", "        if False:", V),
    ("val-ssid-edge-invisible", "validators.py", "    if s[0] in _INVISIBLE_EDGE or s[-1] in _INVISIBLE_EDGE:", "    if False:", V),
    ("val-psk-min-off-by-one", "validators.py", "    if n < PSK_MIN:", "    if n < PSK_MIN - 1:", V),
    ("val-psk-hex-any", "validators.py", "if not all(c in _HEXDIGITS for c in p):\n            raise _fail(field, \"format\", \"64 characters must all be hex digits\")", "if not any(c in _HEXDIGITS for c in p):\n            raise _fail(field, \"format\", \"64 characters must all be hex digits\")", V),
    ("val-psk-latin1", "validators.py", "if not 0x20 <= ord(ch) <= 0x7E:", "if not 0x20 <= ord(ch) <= 0xFF:", V),
    ("val-ipv4-leading-zero", "validators.py", "if len(part) > 1 and part[0] == \"0\":", "if False:", V),
    ("val-cidr-host-bits", "validators.py", "if strict and addr & ~mask & 0xFFFFFFFF:", "if False:", V),
    ("val-subnet-public-ok", "validators.py", "if private_only and not (is_rfc1918(net.network) and is_rfc1918(net.last)):", "if False:", V),
    ("val-ifname-16", "validators.py", "IFNAME_MAX = 15", "IFNAME_MAX = 16", V),
    ("val-ifname-charset", "validators.py", "if not all(c in _IFNAME_CHARS for c in n):", "if False:", V),
    ("val-json-duplicate-keys", "validators.py", "object_pairs_hook=_no_duplicates, ", "", V),
    ("val-json-nan", "validators.py", "parse_constant=_no_constants, ", "", V),
    ("val-join-open-with-key", "validators.py", "if security == \"open\" and psk is not None:", "if False:", V),
    ("val-join-sae-raw-key", "validators.py", "if security == \"sae-only\" and psk is not None and psk_kind(psk) == \"pmk_hex\":", "if False:", V),
    ("val-port-accepts-bool", "validators.py", "    if type(value) is not int:  # bool is an int subclass and must not pass", "    if not isinstance(value, int):  # bool is an int subclass and must not pass", V),
    ("val-mac-multicast", "validators.py", "octets[0] & 1 or not any(octets)", "octets[0] & 2 or not any(octets)", V),
    ("val-error-echoes-value", "validators.py", "raise _fail(field, \"length\", \"too long\")", "raise _fail(field, \"length\", \"too long: \" + value)", V),
    ("val-provisioning-hex-for-sae", "validators.py", "if psk_hex is not None and security not in (\"wpa2\", \"wpa3\"):", "if False:", V),
    # ---- auth: the AP key, PIN, tokens, comparison, limits
    ("auth-compare-with-eq", "auth.py", "return hmac.compare_digest(bytes(a), bytes(b))", "return bytes(a) == bytes(b)", ["test_auth"]),
    ("auth-alphabet-has-O", "auth.py", "AP_KEY_ALPHABET = \"ABCDEFGHJKMNPQRSTUVWXYZ23456789\"", "AP_KEY_ALPHABET = \"ABCDEFGHJKMNOPQRSTUVWXYZ23456789\"", ["test_auth"]),
    ("auth-key-length-11", "auth.py", "AP_KEY_LEN = 12", "AP_KEY_LEN = 11", ["test_auth"]),
    ("auth-key-not-from-secrets", "auth.py", "        return secrets.randbelow(n)", "        import random\n        return random.randrange(n)", ["test_auth"]),
    ("auth-pin-never-9", "auth.py", "DIGITS[r.randbelow(10)]", "DIGITS[r.randbelow(9)]", ["test_auth"]),
    ("auth-modulo-bias", "auth.py", "            if byte < limit:", "            if True:", ["test_auth"]),
    ("auth-token-mac-skipped", "auth.py", "        if not consteq(expected, mac):\n            return None", "        if False:\n            return None", ["test_auth"]),
    ("auth-token-not-bound-to-client", "auth.py", "return hmac.new(self._key, msg, sha256).digest()", "return hmac.new(self._key, msg.rsplit(b\"|\", 1)[0], sha256).digest()", ["test_auth"]),
    ("auth-token-never-expires", "auth.py", "if now_ms >= expires_ms or issued_ms > now_ms + 1000 or sid in self._revoked:", "if issued_ms > now_ms + 1000 or sid in self._revoked:", ["test_auth"]),
    ("auth-revocation-ignored", "auth.py", "or sid in self._revoked:", ":", ["test_auth"]),
    ("auth-refresh-ignores-cap", "auth.py", "expires_ms = min(now_ms + int(self.ttl_s * 1000), issued_ms + int(self.max_lifetime_s * 1000))", "expires_ms = now_ms + int(self.ttl_s * 1000)", ["test_auth"]),
    ("auth-limiter-no-lockout", "auth.py", "if st[\"failures\"] >= p.max_failures_per_client:", "if st[\"failures\"] >= p.max_failures_per_client + 1000:", ["test_auth"]),
    ("auth-limiter-no-backoff", "auth.py", "st[\"next_allowed\"] = now + wait", "st[\"next_allowed\"] = now", ["test_auth"]),
    ("auth-limiter-lock-ignored", "auth.py", "        if st[\"locked_until\"] > now:\n            return Verdict(False, \"locked\", st[\"locked_until\"] - now)", "        if False:\n            return Verdict(False, \"locked\", st[\"locked_until\"] - now)", ["test_auth"]),
    ("auth-limiter-no-rotation", "auth.py", "rotate = self._global_failures >= p.max_failures_global", "rotate = False", ["test_auth"]),
    ("auth-limiter-unbounded-state", "auth.py", "if client not in self._clients and len(self._clients) >= p.max_clients:", "if False:", ["test_auth"]),
    ("auth-gate-accepts-any-pin", "auth.py", "if well_formed and consteq(guess, self._pin):", "if well_formed:", ["test_auth"]),
    ("auth-gate-pin-never-expires", "auth.py", "if now - self._pin_born >= self.pin_ttl_s:", "if False:", ["test_auth"]),
    ("auth-gate-limits-after-pin", "auth.py", "            verdict = self.limiter.check(client)\n            if not verdict.allowed:\n                return GateResult(verdict.reason, retry_after_s=verdict.retry_after_s)", "            verdict = self.limiter.check(client)\n            if False:\n                return GateResult(verdict.reason, retry_after_s=verdict.retry_after_s)", ["test_auth"]),
    ("auth-derive-label-changed", "auth.py", "_hmac_blocks(key, b\"ci-setup/ap-key\")", "_hmac_blocks(key, b\"ci-setup/ap-key2\")", ["test_auth"]),
    # ---- Wi-Fi QR payload escaping
    ("qr-backslash-not-escaped", "wifi_qr.py", "_SPECIAL = \"\\\\;,\\\":\"", "_SPECIAL = \";,\\\":\"", ["test_wifi_qr"]),
    ("qr-semicolon-not-escaped", "wifi_qr.py", "_SPECIAL = \"\\\\;,\\\":\"", "_SPECIAL = \"\\\\,\\\":\"", ["test_wifi_qr"]),
    ("qr-colon-not-escaped", "wifi_qr.py", "_SPECIAL = \"\\\\;,\\\":\"", "_SPECIAL = \"\\\\;,\\\"\"", ["test_wifi_qr"]),
    ("qr-hex-not-quoted", "wifi_qr.py", "if value and all(c in _HEX for c in value):", "if False:", ["test_wifi_qr"]),
    ("qr-unvalidated-ssid", "wifi_qr.py", "    ssid = validate_ssid(ssid)\n", "", ["test_wifi_qr"]),
    # ---- captive portal answers
    ("captive-pending-serves-success", "captive.py", "if state == \"pending\" or kind == \"msft_redirect\":", "if kind == \"msft_redirect\":", ["test_captive"]),
    ("captive-unvalidated-redirect-target", "captive.py", "return \"http://%s/\" % validate_ipv4(ap_ip)", "return \"http://%s/\" % ap_ip", ["test_captive"]),
    ("captive-spaces-in-path", "captive.py", "if ord(ch) <= 0x20 or ord(ch) >= 0x7F:", "if ord(ch) < 0x20 or ord(ch) >= 0x7F:", ["test_captive"]),
    ("captive-foreign-host-passes-through", "captive.py", "    if is_portal_host(host, ap_ip, names, port):\n        return None", "    if True:\n        return None", ["test_captive"]),
    ("captive-204-with-length", "captive.py", "if status != 204:  # RFC 7230", "if True:  # RFC 7230", ["test_captive"]),
    # ---- renderers and the firewall
    ("render-ssid-written-raw", "apcfg.py", "\"SSID_HEX\": ssid_bytes(p.ssid).hex()", "\"SSID_HEX\": p.ssid", ["test_render"]),
    ("render-ssid-not-validated", "apcfg.py", "        validate_ssid(self.ssid, \"ssid\")\n", "", ["test_render"]),
    ("render-passphrase-not-validated", "apcfg.py", "        validate_psk(self.passphrase, \"passphrase\")\n", "", ["test_render"]),
    ("render-iface-not-validated-fw", "fw.py", "    validate_ifname(iface, \"iface\")\n", "", ["test_render"]),
    ("render-low-port-allowed", "fw.py", "validate_port(port, \"port\", minimum=1024)", "validate_port(port, \"port\")", ["test_render"]),
    ("render-run-path-newline", "apcfg.py", "_RUN_PATH.fullmatch(value)", "_RUN_PATH.match(value)", ["test_render"]),
    ("render-public-ap-address", "fw.py", "if not is_rfc1918(addr):", "if False:", ["test_render"]),
    ("template-sequential-substitution", "templating.py", "return _PLACEHOLDER.sub(lambda m: values[m.group(1)], template)", "out = template\n    for k in values:\n        out = out.replace('@%s@' % k, values[k])\n    return out", ["test_render"]),
    ("template-newline-in-value", "templating.py", "        elif \"\\n\" in value or \"\\r\" in value:", "        elif False:", ["test_render"]),
    ("template-lint-disabled", "templating.py", "        raise TemplateError(\"line %d is not a directive\" % n)", "        continue", ["test_render"]),
    ("template-unused-value", "templating.py", "    if wanted != given:", "    if not wanted <= given:", ["test_render"]),
    ("nft-hook-not-raw", "templates/ci_setup.nft.in", "type filter hook prerouting priority raw; policy accept;", "type filter hook prerouting priority filter; policy accept;", ["test_render", "test_cli"]),
    ("nft-final-drop-removed", "templates/ci_setup.nft.in", "limit rate 5/second accept\n    iifname \"@IFACE@\" drop\n", "limit rate 5/second accept\n", ["test_render"]),
    ("nft-no-source-check", "templates/ci_setup.nft.in", "    iifname \"@IFACE@\" ip saddr @SUBNET@ tcp dport { 53, 80 } accept", "    iifname \"@IFACE@\" tcp dport { 53, 80 } accept", ["test_render"]),
    ("nft-forward-open", "templates/ci_setup.nft.in", "    iifname \"@IFACE@\" drop\n    oifname \"@IFACE@\" drop", "    iifname \"@IFACE@\" accept\n    oifname \"@IFACE@\" drop", ["test_render"]),
    ("nft-accept-anything-from-ap", "templates/ci_setup.nft.in", "    iifname \"@IFACE@\" drop\n  }\n  # nothing from the access point", "    iifname \"@IFACE@\" accept\n  }\n  # nothing from the access point", ["test_render"]),
    ("hostapd-no-client-isolation", "templates/hostapd.conf.in", "ap_isolate=1", "ap_isolate=0", ["test_render"]),
    ("hostapd-tkip", "templates/hostapd.conf.in", "rsn_pairwise=CCMP", "rsn_pairwise=CCMP TKIP", ["test_render"]),
    ("dnsmasq-query-log", "templates/dnsmasq.conf.in", "no-poll\n", "no-poll\nlog-queries\n", ["test_render"]),
    ("privfile-mode-0644", "privfile.py", "fd = os.open(tmp, _FLAGS, mode)", "fd = os.open(tmp, _FLAGS, 0o644)", ["test_render"]),
    ("privfile-mode-check", "privfile.py", "    if mode & 0o177:", "    if False:", ["test_render"]),
    ("privfile-not-exclusive", "privfile.py", "_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL |", "_FLAGS = os.O_WRONLY | os.O_CREAT |", ["test_render"]),
    # ---- QR encoder
    ("qr-gf-polynomial", "qr.py", "        _x ^= 0x11D", "        _x ^= 0x11B", ["test_qr.Constants"]),
    ("qr-format-xor-mask", "qr.py", "return ((data << 10) | rem) ^ 0x5412", "return ((data << 10) | rem) ^ 0x5413", ["test_qr.Constants"]),
    ("qr-ecl-bits-swapped", "qr.py", "_FORMAT_BITS = {\"L\": 1, \"M\": 0, \"Q\": 3, \"H\": 2}", "_FORMAT_BITS = {\"L\": 0, \"M\": 1, \"Q\": 3, \"H\": 2}", ["test_qr.Constants"]),
    ("qr-mask-5-formula", "qr.py", "return (row * col) % 2 + (row * col) % 3 == 0", "return (row * col) % 2 + (row * col) % 3 == 1", ["test_qr.Constants"]),
    ("qr-alignment-v7", "qr.py", "7: [6, 22, 38]", "7: [6, 22, 40]", ["test_qr.Constants"]),
    ("qr-pad-bytes-swapped", "qr.py", "pad = (0xEC, 0x11)", "pad = (0x11, 0xEC)", ["test_qr.RoundTrip.test_wifi_codes_of_the_access_point"]),
    ("qr-no-interleave", "qr.py", "        for b in blocks:\n            if i < len(b):\n                out.append(b[i])", "        for b in blocks[:1]:\n            if i < len(b):\n                out.append(b[i])", ["test_qr.RoundTrip.test_wifi_codes_of_the_access_point"]),
    ("qr-zigzag-direction", "qr.py", "upward = ((right + 1) & 2) == 0", "upward = ((right + 1) & 2) != 0", ["test_qr.RoundTrip.test_wifi_codes_of_the_access_point"]),
    ("qr-dark-module-missing", "qr.py", "    g.set(n - 8, 8, True)                                    # the always-dark module", "    g.set(n - 8, 8, False)                                   # the always-dark module", ["test_qr.Structure"]),
    # ---- policy
    ("policy-claimed-opens", "policy.py", "    if ctx == \"installed-claimed\":\n        blockers.append(\"claimed_lockdown\")", "    if False:\n        blockers.append(\"claimed_lockdown\")", ["test_policy"]),
    ("policy-display-opens", "policy.py", "    if display == \"connected\":\n        blockers.append(\"display_attached\")", "    if False:\n        blockers.append(\"display_attached\")", ["test_policy"]),
    ("policy-unknown-display-opens", "policy.py", "    elif display == \"unknown\":", "    elif False:", ["test_policy"]),
    ("policy-network-up-opens", "policy.py", "    if network == \"up\":\n        blockers.append(\"network_up\")", "    if False:\n        blockers.append(\"network_up\")", ["test_policy"]),
    ("policy-plain-live-opens", "policy.py", "    if ctx == \"live\" and not inp.stick:", "    if False:", ["test_policy"]),
    ("policy-any-trigger-counts", "policy.py", "if isinstance(t, str) and t in TRIGGERS:", "if True:", ["test_policy"]),
    ("policy-no-credential-channel-ok", "policy.py", "    if channel is None:\n        missing.append(\"no_credential_channel\")", "    if False:\n        missing.append(\"no_credential_channel\")", ["test_policy"]),
    ("policy-no-radio-ok", "policy.py", "    if not inp.ap_capable_radio:\n        missing.append(\"no_ap_capable_radio\")", "    if False:\n        missing.append(\"no_ap_capable_radio\")", ["test_policy"]),
    ("policy-down-when-no-connectivity", "policy.py", "connectivity in (\"full\", \"limited\", \"portal\", \"unknown\")", "connectivity in (\"full\", \"limited\", \"portal\", \"unknown\", \"none\")", ["test_policy"]),
    ("policy-no-grace", "policy.py", "    if inp.network_down_for_s < GRACE_S:", "    if False:", ["test_policy"]),
    ("policy-param-off-ignored", "policy.py", "    if hp == \"0\":\n        blockers.append(\"kernel_param_off\")", "    if False:\n        blockers.append(\"kernel_param_off\")", ["test_policy"]),
    # ---- regulatory domain
    ("regdom-dfs-always-allowed", "regdom.py", "if allow_dfs and not f.no_ir:", "if True:", ["test_regdom"]),
    ("regdom-5ghz-without-country", "regdom.py", "    if not country.known:\n        reasons.append(\"5 GHz not offered: the country is unknown\")\n        return None", "    if False:\n        return None", ["test_regdom"]),
    ("regdom-usable-ignores-radar", "parsers/iw.py", "return not (self.disabled or self.no_ir or self.radar)", "return not (self.disabled or self.no_ir)", ["test_regdom", "test_parsers_iw"]),
    ("regdom-usable-ignores-no-ir", "parsers/iw.py", "return not (self.disabled or self.no_ir or self.radar)", "return not (self.disabled or self.radar)", ["test_regdom", "test_parsers_iw"]),
    ("regdom-scan-needs-no-majority", "regdom.py", "if votes[top_code] >= min_votes and votes[top_code] >= min_share * total:", "if True:", ["test_regdom"]),
    ("regdom-12-13-without-country", "regdom.py", "max_allowed = 13 if (country.known and country.code in CH_1_13) else 11", "max_allowed = 13", ["test_regdom"]),
    ("regdom-follow-5ghz-without-country", "regdom.py", "    if band == \"5\" and not country.known:\n        return fail(\"5 GHz needs a known country\")", "    if False:\n        return fail(\"5 GHz needs a known country\")", ["test_regdom"]),
    ("regdom-explicit-not-first", "regdom.py", "    if exp is not None:\n        if kernel_code is not None", "    if False:\n        if kernel_code is not None", ["test_regdom"]),
    # ---- job state machine
    ("jobs-secret-fields-accepted", "jobs.py", "            if name in FORBIDDEN_FIELDS:", "            if False:", ["test_jobs"]),
    ("jobs-credentials-without-auth", "jobs.py", "        if not self.authenticated:\n            return self._result(False, \"not_authenticated\", prev, [])", "        if False:\n            return self._result(False, \"not_authenticated\", prev, [])", ["test_jobs"]),
    ("jobs-no-timeouts", "jobs.py", "if self.terminal or self._deadline is None or self.clock.now() < self._deadline:", "if True:", ["test_jobs"]),
    ("jobs-terminal-not-absorbing", "jobs.py", "        if self.terminal:\n            return self._result(False, \"terminal\", original, [])", "        if False:\n            return self._result(False, \"terminal\", original, [])", ["test_jobs"]),
    ("jobs-cancel-mid-join-no-rollback", "jobs.py", "        if self.state in (JOINING, VERIFYING):\n            return self._begin_rollback(prev, \"cancel\", \"cancelled\")", "        if False:\n            return self._begin_rollback(prev, \"cancel\", \"cancelled\")", ["test_jobs"]),
    ("jobs-public-view-leaks-ssid", "jobs.py", "return {\"state\": self.state, \"step\": self.step,", "return {\"ssid\": self.ssid, \"state\": self.state, \"step\": self.step,", ["test_jobs"]),
    ("jobs-uplink-interrupts-setup", "jobs.py", "        if self.authenticated:\n            return self._result(False, \"client_active\", prev, [])", "        if False:\n            return self._result(False, \"client_active\", prev, [])", ["test_jobs"]),
    ("jobs-idle-extended-by-clients", "jobs.py", "                self._idle_deadline = self._idle_deadline if self._idle_deadline is not None else now + cfg.ap_idle_timeout_s", "                self._idle_deadline = now + cfg.ap_idle_timeout_s", ["test_jobs"]),
    # ---- the read-only command line
    ("ro-wifi-list-may-rescan", "runners.py", "(\"nmcli\", \"-t\", \"-f\", \"IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY\", \"device\", \"wifi\", \"list\", \"--rescan\", \"no\"),", "(\"nmcli\", \"-t\", \"-f\", \"IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY\", \"device\", \"wifi\", \"list\"),", ["test_probe"]),
    ("ro-ifname-unchecked", "runners.py", "        if len(a) == 4 and a[:2] == (\"iw\", \"dev\") and a[3] in (\"link\", \"info\"):\n            validate_ifname(a[2])\n            return True", "        if len(a) == 4 and a[:2] == (\"iw\", \"dev\") and a[3] in (\"link\", \"info\"):\n            return True", ["test_probe"]),
    ("ro-scan-trigger-allowed", "runners.py", "a[3] in (\"link\", \"info\")", "a[3] in (\"link\", \"info\", \"scan\")", ["test_probe"]),
    ("ro-environment-inherited", "runners.py", "env=dict(_ENV), shell=False", "env=None, shell=False", ["test_probe"]),
    ("ro-wrapper-does-not-check", "runners.py", "        if not is_read_only_command(argv):\n            raise ReadOnlyViolation", "        if False:\n            raise ReadOnlyViolation", ["test_probe", "test_cli"]),
    ("ro-connectivity-check", "runners.py", "(\"nmcli\", \"networking\", \"connectivity\"),", "(\"nmcli\", \"networking\", \"connectivity\"), (\"nmcli\", \"networking\", \"connectivity\", \"check\"),", ["test_probe"]),
    # ---- parsers: the places where hostile text meets a decision
    ("parse-iw-ssid-escapes-ignored", "parsers/common.py", "            if nxt in (\"x\", \"X\") and i + 3 < n and text[i + 2] in _HEX and text[i + 3] in _HEX:", "            if False:", ["test_parsers_iw", "test_probe"]),
    ("parse-nm-colon-escape", "parsers/nmcli.py", "        if ch == \"\\\\\" and i + 1 < n and line[i + 1] in (\":\", \"\\\\\"):", "        if ch == \"\\\\\" and i + 1 < n and line[i + 1] in (\"\\\\\",):", ["test_parsers_misc"]),
    ("parse-nm-rows-not-checked", "parsers/nmcli.py", "            if len(fields) != len(columns):\n                dropped += 1\n                continue", "            if False:\n                dropped += 1\n                continue", ["test_parsers_misc", "test_fuzz_parsers"]),
    ("parse-nm-enterprise-as-wpa2", "parsers/nmcli.py", "    if \"802.1X\" in tokens or \"WPA-EAP-SUITE-B-192\" in tokens:\n        return \"enterprise\"", "    if False:\n        return \"enterprise\"", ["test_parsers_misc"]),
    ("parse-nm-state-detail-ignored", "parsers/nmcli.py", "(?:\\s*\\(([^)]*)\\))?$\", re.IGNORECASE)", "$\", re.IGNORECASE)", ["test_parsers_misc"]),
    ("parse-iw-concurrency-shared-slot", "parsers/iw.py", "                if a is not g or a.max >= 2:  # one shared group must hold both interfaces", "                if True:  # one shared group must hold both interfaces", ["test_parsers_iw"]),
    ("parse-iw-selfmanaged-flag", "parsers/iw.py", "scope, phy, selfm = \"phy\", \"phy\" + m.group(1), bool(m.group(2))", "scope, phy, selfm = \"phy\", \"phy\" + m.group(1), False", ["test_parsers_iw", "test_regdom"]),
    ("parse-iw-hidden-zero-ssid", "parsers/common.py", "return len(raw) == 0 or all(b == 0 for b in raw)", "return len(raw) == 0", ["test_parsers_iw"]),
    ("parse-iw-scan-unsafe-ssid-as-text", "parsers/common.py", "        return validate_ssid(text)\n    except (UnicodeDecodeError, ValidationError):", "        return text\n    except (UnicodeDecodeError, ValidationError):", ["test_parsers_iw"]),
    ("parse-iw-start-ap-not-required", "parsers/iw.py", "return (not self.commands) or (\"start_ap\" in self.commands)", "return True", ["test_parsers_iw"]),
    ("parse-iw-dfs-subline-as-header", "parsers/iw.py", "if section == \"freqs\" and not stripped.endswith(\":\") and not _BAND_HDR.match(stripped):\n                continue", "if False:\n                continue", ["test_parsers_iw"]),
    ("parse-ip-blackhole-default-usable", "parsers/ipjson.py", "usable = [r for r in routes if r.is_default and r.type == \"unicast\" and r.dev]", "usable = [r for r in routes if r.is_default]", ["test_parsers_misc"]),
    ("parse-cmdline-last-wins", "sysinfo.py", "        params[name[:64]] = value[:256]", "        params.setdefault(name[:64], value[:256])", ["test_parsers_misc"]),
    ("probe-follow-uplink-unchecked", "probe.py", "        if radio.follow_uplink_mhz is not None and not plan.ok:", "        if False:", ["test_probe"]),
    ("probe-hard-block-ignored", "probe.py", "        if name in blocks and blocks[name].hard_blocked:\n            hard_blocked = True", "        if False:\n            hard_blocked = True", ["test_probe"]),
    # ---- owner statements (statement.py) and the replay guard (replay.py)
    ("stmt-signature-skipped", "statement.py", "    if not _signature_ok(verifier, SIGNING_PREFIX + data, signature):", "    if False:", ST),
    ("stmt-namespace-dropped", "statement.py", "verifier.verify(NAMESPACE, message, bytes(signature))", "verifier.verify(\"\", message, bytes(signature))", ST),
    ("stmt-noncanonical-accepted", "statement.py", "    if canonical != data:", "    if False:", ST),
    ("stmt-duplicate-key-accepted", "statement.py", "        obj = loads_strict(data)", "        obj = json.loads(data)", ST),
    ("stmt-float-accepted", "statement.py", "    if t is int:", "    if t is int or t is float:", ST),
    ("stmt-unknown-field-accepted", "statement.py", "    if set(obj) != FIELD_SET:", "    if not FIELD_SET <= set(obj):", ST),
    ("stmt-version-ignored", "statement.py", "    if version != VERSION:", "    if False:", ST),
    ("stmt-size-unbounded", "statement.py", "    if len(data) > MAX_STATEMENT_BYTES:", "    if False:", ST),
    ("stmt-type-ignored", "statement.py", "    if obj[\"type\"] not in expected.types:", "    if False:", ST),
    ("stmt-scope-ignored", "statement.py", "    if not consteq(obj[\"scope\"], expected.scope):", "    if False:", ST),
    ("stmt-target-ignored", "statement.py", "    if not consteq(obj[\"target\"], expected.target):", "    if False:", ST),
    ("stmt-params-not-bound", "statement.py", "    if not consteq(obj[\"params_hash\"], params_hash(params)):", "    if False:", ST),
    ("stmt-params-burns-id", "statement.py", "    _check_params(obj, params)\n    t = _read_clock(now)\n    _check_time(obj, t, expected)\n    _claim(store, obj, t, expected)\n", "    t = _read_clock(now)\n    _claim(store, obj, t, expected)\n    _check_params(obj, params)\n    _check_time(obj, t, expected)\n", ST),
    ("stmt-expiry-off-by-one", "statement.py", "    if t >= obj[\"expires_at\"]:", "    if t > obj[\"expires_at\"]:", ST),
    ("stmt-ttl-cap-removed", "statement.py", "    if obj[\"expires_at\"] - t > expected.max_ttl_s + expected.skew_s:", "    if False:", ST),
    ("stmt-skew-widened", "statement.py", "DEFAULT_SKEW_S = 120", "DEFAULT_SKEW_S = 1200", ST),
    ("stmt-error-echoes-value", "statement.py", "        raise StatementError(\"target\")", "        raise StatementError(\"target\", \"expected \" + obj[\"target\"])", ST),
    ("stmt-record-type-from-allow-list", "statement.py", "return VerifiedStatement(type=obj[\"type\"],", "return VerifiedStatement(type=expected.types[0],", ST),
    ("stmt-signature-too-long-accepted", "statement.py", "or not 1 <= len(signature) <= MAX_SIGNATURE_BYTES:", "or not 1 <= len(signature):", ST),
    ("stmt-signature-empty-accepted", "statement.py", "or not 1 <= len(signature) <= MAX_SIGNATURE_BYTES:", "or not len(signature) <= MAX_SIGNATURE_BYTES:", ST),
    ("stmt-canonical-statement-skips-members", "statement.py", "    _check_fields(fields)\n    return canonical_json(fields, MAX_STATEMENT_BYTES)", "    return canonical_json(fields, MAX_STATEMENT_BYTES)", ST),
    ("stmt-canonical-statement-skips-type-check", "statement.py", "    if type(fields) is not dict:\n        raise StatementError(\"format\")\n    _check_fields(fields)", "    _check_fields(fields)", ST),
    ("canon-sort-keys-removed", "statement.py", "sort_keys=True, ", "sort_keys=False, ", ST),
    ("canon-separator-changed", "statement.py", "separators=(\",\", \":\")", "separators=(\", \", \": \")", ST),
    ("replay-floor-ignored", "replay.py", "                if now < floor - skew_s:", "                if False:", RP),
    ("replay-floor-advances-on-reject", "replay.py", "                names = _listing(backend)\n", "                backend.write_floor(max(now, floor))\n                names = _listing(backend)\n", RP),
    ("replay-damaged-marker-ignored", "replay.py", "if any(n.endswith(\"-\" + digest) for n in names):", "if any(n.endswith(\"-\" + digest) and backend.marker_body(n) == MARKER_BODY for n in names):", RP),
    ("replay-lookup-by-exact-name", "replay.py", "if any(n.endswith(\"-\" + digest) for n in names):", "if name in names:", RP),
    ("replay-purge-by-now", "replay.py", "live = self._purge(names, floor, max_ttl_s, skew_s)", "live = self._purge(names, now, max_ttl_s, skew_s)", RP),
    ("replay-store-unbounded", "replay.py", "                if live >= self.max_markers:", "                if False:", RP),
]


def apply_mutant(root, rel, old, new):
    path = os.path.join(root, "ci_setup", rel)
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    count = text.count(old)
    if count != 1:
        return "the text to replace occurs %d times in %s (must be exactly once): %r" % (count, rel, old[:70])
    if old == new:
        return "mutant does not change anything"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text.replace(old, new))
    return None


def run_one(index, spec, tmp_root, timeout):
    mid, rel, old, new, tests = spec
    work = os.path.join(tmp_root, "m%03d" % index)
    shutil.copytree(os.path.dirname(PKG) + "/ci_setup", os.path.join(work, "ci_setup"),
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    problem = apply_mutant(work, rel, old, new)
    if problem:
        return mid, "STALE", problem, 0.0
    env = dict(os.environ, PYTHONPATH=work, PYTHONDONTWRITEBYTECODE="1", CI_SETUP_FUZZ_N="4000", PYTHONHASHSEED="0")
    t0 = time.time()
    try:
        res = subprocess.run([sys.executable, "-m", "unittest", "-q"] + tests, cwd=HERE, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired:
        return mid, "killed", "timeout (the mutant hangs)", time.time() - t0
    finally:
        shutil.rmtree(work, ignore_errors=True)
    out = res.stdout.decode("utf-8", "replace")
    if res.returncode == 0:
        return mid, "SURVIVED", "tests " + ", ".join(tests) + " still pass", time.time() - t0
    m = re.search(r"^(FAIL|ERROR): (\S+) \((\S+)\)", out, re.M)
    first = "%s %s" % (m.group(1).lower(), m.group(2)) if m else "failed to import or run"
    return mid, "killed", first, time.time() - t0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--only", help="run the mutants whose id contains this text")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("-j", type=int, default=3, help="parallel runs (default 3)")
    ap.add_argument("--timeout", type=int, default=180)
    args = ap.parse_args()
    specs = [s for s in MUTANTS if not args.only or args.only in s[0]]
    ids = [s[0] for s in MUTANTS]
    if len(ids) != len(set(ids)):
        print("duplicate mutant ids", file=sys.stderr)
        return 1
    if args.list:
        for s in specs:
            print("%-40s %-28s %s" % (s[0], s[1], ",".join(s[4])))
        return 0
    if not specs:
        print("no mutant matches", file=sys.stderr)
        return 2
    try:
        os.nice(5)
    except (AttributeError, OSError):
        pass
    tmp_root = tempfile.mkdtemp(prefix="ci-setup-mutants.")
    results = []
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.j)) as pool:
            futures = [pool.submit(run_one, i, s, tmp_root, args.timeout) for i, s in enumerate(specs)]
            for fut in futures:
                results.append(fut.result())
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)
    bad = 0
    for mid, status, detail, secs in results:
        print("%-9s %-40s %s (%.1fs)" % (status, mid, detail, secs))
        if status != "killed":
            bad += 1
    killed = sum(1 for r in results if r[1] == "killed")
    print("== mutation: %d of %d mutants killed" % (killed, len(results)))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
