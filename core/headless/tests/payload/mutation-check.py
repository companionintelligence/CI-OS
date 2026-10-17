#!/usr/bin/env python3
"""Mutation check for the payload tests: break each fix on purpose and see that a test notices. TEST-ONLY, slow.

For every mutation below the script copies the payload and the installers into a scratch directory, applies ONE textual
change that undoes (or weakens) a fix, runs the suite that is meant to guard it against the copy (PAYLOAD_DIR and
BACKENDS_DIR point at it), and expects a non-zero exit. KILLED = a test failed (good). SURVIVED = every test still
passed: the fix is not guarded; read the row, then add the missing test or explain the mutant. A mutation whose text is not
found exactly once is reported as BROKEN (the mutation table is stale against the source), never counted as killed.

Before any mutation the unmodified copy is run once per suite (twice if the first run fails: a loaded machine can fail a
timing check once) and must pass, so a broken harness cannot masquerade as a string of kills.

    core/headless/tests/payload/mutation-check.py            all mutations (3 at a time; -j N)
    core/headless/tests/payload/mutation-check.py -k hotspot only mutations whose id, file or finding contains the word
    core/headless/tests/payload/mutation-check.py --list

Exit status: 0 every mutation killed, 1 something survived or was broken, 2 cannot run.
The repository is only read; the scratch directory (tempfile.mkdtemp) is the only thing removed.
"""
import argparse
import concurrent.futures
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
SERVICE = 'payload/opt/setup-backend/setup_service.py'
START = 'payload/usr/local/bin/setup-device-hotspot-start.sh'
MONITOR = 'payload/usr/local/bin/setup-network-monitor.sh'
PRESCAN = 'payload/usr/local/bin/setup-device-prescan.py'
NGINX = 'payload/nginx/sites-available/setup-portal'

# suites: ('py', 'module[.Class]') or ('sh', 'file.sh', 'SECTIONS' or '')
PY_PROFILE = ('py', 'test_setup_service.ProfileDeletionTests')
PY_CONFIGURE = ('py', 'test_setup_service.ConfigureRequestHandlingTests')
PY_VALID = ('py', 'test_setup_service.ValidatorTests')
PY_PSK = ('py', 'test_setup_service.PskNeverOnTheCommandLineTests')
PY_SECRET = ('py', 'test_setup_service.SecretFileTests')
PY_LOG = ('py', 'test_setup_service.LogHygieneTests')
PY_DEVID = ('py', 'test_setup_service.DeviceIdTests')
PY_HEALTH = ('py', 'test_setup_service.HealthEndpointTests')
PY_SIGNAL = ('py', 'test_setup_service.SignalHandlerTests')
PY_RUNSCRIPT = ('py', 'test_setup_service.RunScriptTests')
PY_PRESCAN = ('py', 'test_prescan')
PY_STATIC = ('py', 'test_static')
SH_MONITOR = ('sh', 'test_monitor.sh', '')


def SH_START(sections):  # noqa: N802
    return ('sh', 'test_hotspot_start.sh', sections)


# (id, finding, file, old text, new text, suite[, equivalent-note])
# A mutation with a 7th element is a known EQUIVALENT mutant: it is expected to survive and the note says why.
EQUIVALENT = "bash runs the EXIT trap when a fatal signal ends it (checked on bash 3.2.57), with status 128+n: the explicit signal traps only spell that out"
MUTATIONS = [
    # ---- setup_service.py -------------------------------------------------------------------------------------------
    ('S4-type', 'S4 profile deletion filters by type', SERVICE,
     "if con_type != NM_WIFI_TYPE or name != wanted_name or not uuid or uuid == keep_uuid:",
     "if name != wanted_name or not uuid or uuid == keep_uuid:", PY_PROFILE),
    ('S4-prefix', 'S4 only profiles with our prefix are deleted', SERVICE,
     "    return OWN_PROFILE_PREFIX + ssid", "    return ssid", PY_PROFILE),
    ('S4-keep', 'S4 the new profile is never deleted by its own cleanup', SERVICE,
     "if con_type != NM_WIFI_TYPE or name != wanted_name or not uuid or uuid == keep_uuid:",
     "if con_type != NM_WIFI_TYPE or name != wanted_name or not uuid:", PY_PROFILE),
    ('S4-unescape', 'S4 nmcli terse escaping is undone', SERVICE,
     "        elif ch == '\\\\':\n            escaped = True", "        elif ch == '\\\\' and False:\n            escaped = True", PY_PROFILE),
    ('L7-restart', 'L7 configure() error path restarts the AP', SERVICE,
     "        logger.error(f\"Configuration error: {e}\", exc_info=True)\n        return jsonify({'error': 'Internal server error'}), 500\n    finally:\n        if not handed_off:",
     "        logger.error(f\"Configuration error: {e}\", exc_info=True)\n        start_hotspot_services()\n        return jsonify({'error': 'Internal server error'}), 500\n    finally:\n        if not handed_off:", PY_CONFIGURE),
    ('L7-notdict', 'L7 a JSON body that is not an object is a 400', SERVICE,
     "        if not isinstance(data, dict):\n            return None, (jsonify({'error': 'Request body must be a JSON object'}), 400)",
     "        if data is None:\n            return None, (jsonify({'error': 'Request body must be a JSON object'}), 400)", PY_CONFIGURE),
    ('L7-restore-guard', 'L7 the AP is restored only if this attempt stopped it', SERVICE,
     "        if hotspot_stopped:\n", "        if True:\n", PY_CONFIGURE),
    ('S-size', 'S8 request body size is capped', SERVICE,
     "app.config['MAX_CONTENT_LENGTH'] = 64 * 1024", "pass", PY_CONFIGURE),
    ('I1-bytes', 'I1 SSID length is counted in bytes', SERVICE,
     "    if not 1 <= len(raw) <= 32:", "    if not 1 <= len(ssid) <= 32:", PY_VALID),
    ('I1-control', 'I1 control characters are refused', SERVICE,
     "        if unicodedata.category(ch) in ('Cc', 'Zl', 'Zp'):", "        if unicodedata.category(ch) in ('Zl', 'Zp'):", PY_VALID),
    ('I1-psk-max', 'I1 passphrase is at most 63 characters', SERVICE,
     "    if not 8 <= len(psk) <= 63 or any(", "    if not 8 <= len(psk) <= 64 or any(", PY_VALID),
    ('I1-psk-hex', 'I1 a 64-digit hex PSK is accepted', SERVICE,
     "    if _HEX_PSK.match(psk):\n        return psk\n", "", PY_VALID),
    ('I1-psk-ascii', 'I1 passphrase is printable ASCII', SERVICE,
     "any(not 0x20 <= ord(ch) <= 0x7e for ch in psk)", "any(not 0x20 <= ord(ch) for ch in psk)", PY_VALID),
    ('I1-route', 'I1 the route validates before side effects', SERVICE,
     "        ssid = validate_ssid(raw_ssid)\n        password = validate_psk(raw_password) if raw_password else ''",
     "        ssid = raw_ssid\n        password = raw_password", PY_CONFIGURE),
    ('I2-argv', 'I2 the passphrase is on the nmcli command line', SERVICE,
     "            cmd.extend(['wifi-sec.key-mgmt', 'wpa-psk'])\n        else:",
     "            cmd.extend(['wifi-sec.key-mgmt', 'wpa-psk', 'wifi-sec.psk', password])\n        else:", PY_PSK),
    ('I2-nofile', 'I2 activation passes the secret through passwd-file', SERVICE,
     "            if secrets_path:\n                cmd.extend(['passwd-file', secrets_path])", "            if False:\n                cmd.extend(['passwd-file', secrets_path])", PY_PSK),
    ('I2-filemode', 'I2 the passwd file is created 0600', SERVICE,
     "fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)", "fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)", PY_PSK),
    ('I2-dirmode', 'I2 the passwd file lives in a 0700 directory', SERVICE,
     "    os.chmod(RUN_DIR, 0o700)", "    os.chmod(RUN_DIR, 0o755)", PY_PSK),
    ('I2-cleanup', 'I2 the passwd file is removed afterwards', SERVICE,
     "        with contextlib.suppress(OSError):\n            os.unlink(path)", "        pass", PY_PSK),
    ('I2-readback', 'I2 a passphrase NetworkManager did not keep is reported', SERVICE,
     "        if password and use_uuid and _passphrase_is_stored(connection_target) is False:", "        if False:", PY_PSK),
    ('I3-atomic', 'I3 secret files are replaced atomically', SERVICE,
     "        os.replace(tmp, path)", "        Path(path).write_text(text)\n        os.unlink(tmp)", PY_SECRET),
    ('I3-mode', 'I3 secret files are created 0600', SERVICE,
     "fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)", "fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)", PY_SECRET),
    ('I3-excl', 'I3 secret files never go through an existing file or symlink', SERVICE,
     "fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)", "fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)", PY_SECRET),
    ('I3-credentials', 'I3 credentials.json goes through the secret writer', SERVICE,
     "            _write_secret_file(CREDENTIALS_JSON, json.dumps(credentials, indent=2))",
     "            Path(CREDENTIALS_JSON).write_text(json.dumps(credentials, indent=2))", PY_SECRET),
    ('I3-cleanup-on-failure', 'I3 a failed write leaves no temporary file', SERVICE,
     "    except BaseException:\n        with contextlib.suppress(OSError):\n            os.unlink(tmp)\n        raise",
     "    except BaseException:\n        raise", PY_SECRET),
    ('I4-logperm', 'I4 the log file is 0600', SERVICE,
     "os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600))\n        os.chmod(path, 0o600)",
     "os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644))\n        os.chmod(path, 0o644)", PY_LOG),
    ('I4-url', 'I4 the pairing code is not logged through the request URL', SERVICE,
     "    logger.info(f\"[CLOUD GET] Request: {_cloud_pairing_url()} (pairing code in the query string, not logged)\")",
     "    logger.info(f\"[CLOUD GET] Request URL: {url}\")", PY_LOG),
    ('I4-body', 'I4 raw cloud bodies are not logged', SERVICE,
     "logger.info(f\"[CLOUD GET] Response status: {resp.status}; {_describe_cloud_payload(body)}\")",
     "logger.info(f\"[CLOUD GET] Response body: {body}\")", PY_LOG),
    ('I4-errbody', 'I4 raw cloud error bodies are not logged', SERVICE,
     "logger.error(f\"[CLOUD GET] HTTP Error {e.code}: {_describe_cloud_payload(body)}\")",
     "logger.error(f\"[CLOUD GET] HTTP Error {e.code}: {body}\")", PY_LOG),
    ('I4-compare', 'I4 the pairing codes are not logged when compared', SERVICE,
     "                logger.info(\"[PAIRING VALIDATION] Comparing pairing codes\")",
     "                logger.info(f\"[PAIRING VALIDATION] Comparing {user_code_normalized} with {cloud_code_normalized}\")", PY_LOG),
    ('I4-net', 'I4 the log formatter masks registered secrets', SERVICE,
     "    def format(self, record):\n        return _scrub(super().format(record))", "    def format(self, record):\n        return super().format(record)", PY_LOG),
    ('I4-local-code', 'I4 the local pairing code is not logged', SERVICE,
     "        logger.info(\"Generated a new pairing code\")", "        logger.info(f\"Generated new pairing code: {pairing_data['code']}\")", PY_LOG),
    ('I4-registry', 'I4 the secret registry evicts the oldest entry, not all of them', SERVICE,
     "                del _REGISTERED_SECRETS[next(iter(_REGISTERED_SECRETS))]", "                _REGISTERED_SECRETS.clear()", PY_SECRET),
    ('I4-configure-code', 'I4 the submitted pairing code is not logged', SERVICE,
     "            logger.info(\"[CONFIGURE] Pairing code required for this device state\")",
     "            logger.info(f\"[CONFIGURE] Pairing code (normalized): {normalized_code}\")", PY_LOG),
    ('I8-getdeviceid', 'I8 the dmidecode / machine-id probes can run', SERVICE,
     "                stdout=subprocess.PIPE,\n                stderr=subprocess.DEVNULL,\n                text=True,\n                timeout=5\n            )\n            if result.returncode == 0 and result.stdout.strip():",
     "                capture_output=True,\n                text=True,\n                timeout=5,\n                stderr=subprocess.DEVNULL\n            )\n            if result.returncode == 0 and result.stdout.strip():", PY_DEVID),
    ('H2-signal', 'H2 no signal handler at import time', SERVICE,
     "def normalize_pairing_code(code):", "signal.signal(signal.SIGTERM, signal_handler)\n\ndef normalize_pairing_code(code):", PY_SIGNAL),
    ('H2-main', 'H2 main() installs the handlers for the stand-alone server', SERVICE,
     "    signal.signal(signal.SIGTERM, signal_handler)\n    signal.signal(signal.SIGINT, signal_handler)\n", "", PY_SIGNAL),
    ('U1-health', 'U1 /api/health is served', SERVICE,
     "@app.route('/api/health', methods=['GET'])\n", "", PY_HEALTH),
    ('U1-health-leak', 'U1 health carries no unexpected field', SERVICE,
     "        'pairing_code_error': _pairing_code_error,\n    })\n\n@app.route('/api/status'",
     "        'pairing_code_error': _pairing_code_error,\n        'log_file': LOG_FILE,\n    })\n\n@app.route('/api/status'", PY_HEALTH),
    ('L4-stop', 'L4 ending the join stops the hotspot through the script', SERVICE,
     "status = _run_script([HOTSPOT_SCRIPT, 'stop'], timeout=60)", "status = 0", PY_CONFIGURE),
    ('L4-sigterm-first', 'L4 a timeout asks the script to stop before killing it', SERVICE,
     "        proc.terminate()\n        try:", "        proc.kill()\n        try:", PY_RUNSCRIPT),
    # ---- hotspot start / stop ---------------------------------------------------------------------------------------------
    ('L4-trap', 'L4 failure and signals roll the start back', START, "trap on_exit EXIT\n", "", SH_START('F G')),
    ('L4-term', 'L4 SIGTERM is handled', START, "trap 'exit 143' TERM\n", "", SH_START('G'), EQUIVALENT),
    ('L4-int', 'L4 SIGINT is handled', START, "trap 'exit 130' INT\n", "", SH_START('G'), EQUIVALENT),
    ('L4-hup', 'L4 SIGHUP is handled', START, "trap 'exit 129' HUP\n", "", SH_START('G'), EQUIVALENT),
    ('L4-nm', 'L4 the radio goes back to NetworkManager', START,
     "nmcli device set \"$iface\" managed yes 2>/dev/null", "nmcli device set \"$iface\" managed no 2>/dev/null", SH_START('A F')),
    ('L4-addr', 'L4 the AP address is removed', START,
     "        ip addr del \"$AP_ADDR\" dev \"$iface\" 2>/dev/null || true", "        true", SH_START('A F')),
    ('L4-nginx', 'L4 nginx started by the script is stopped', START,
     "        systemctl stop nginx.service 2>/dev/null || true\n    fi\n\n    if valid_iface", "        true\n    fi\n\n    if valid_iface", SH_START('A F')),
    ('L4-nginx-foreign', 'L4 an nginx the script did not start is left running', START,
     "    if ! systemctl is-active --quiet nginx.service 2>/dev/null; then\n        state_set nginx_started 1\n    fi",
     "    state_set nginx_started 1", SH_START('B')),
    ('L4-hostapd', 'L4 hostapd is stopped', START,
     "    systemctl stop hostapd-setup.service 2>/dev/null || true\n    # A unit that failed", "    true\n    # A unit that failed", SH_START('A F')),
    ('L4-state-first', 'L4 the unmanaged mark is written before the change', START,
     "    state_set nm_unmanaged 1\n    nmcli device set \"$WIFI_IFACE\" managed no", "    nmcli device set \"$WIFI_IFACE\" managed no", SH_START('G')),
    ('L4-verify-hostapd', 'L4 a hostapd that is not running fails the start', START,
     "if ! systemctl is-active --quiet hostapd-setup.service; then\n    log \"hostapd-setup.service is not running", "if false; then\n    log \"hostapd-setup.service is not running", SH_START('F')),
    ('L4-verify-dnsmasq', 'L4 a dnsmasq that is not running fails the start', START,
     "if ! systemctl is-active --quiet dnsmasq-setup.service; then\n    log \"dnsmasq-setup.service is not running", "if false; then\n    log \"dnsmasq-setup.service is not running", SH_START('F')),
    ('L4-hostapd-fail', 'L4 a hostapd that cannot start fails the start', START,
     "if ! start_hostapd_with_retry; then\n    log \"hostapd-setup.service failed to start after retry\" err", "if false; then\n    log \"hostapd-setup.service failed to start after retry\" err", SH_START('F')),
    ('L4-stale', 'L4 state of a crashed episode is undone before a start', START,
     "    log \"Found state from an earlier hotspot episode; undoing it first\" warning\n    teardown", "    log \"Found state from an earlier hotspot episode; undoing it first\" warning", SH_START('I')),
    ('L4-idempotent', 'L4 a start while the AP is up changes nothing', START,
     "    && systemctl is-active --quiet dnsmasq-setup.service 2>/dev/null; then\n    log \"Hotspot is already up; nothing to do\"",
     "    && false; then\n    log \"Hotspot is already up; nothing to do\"", SH_START('H')),
    ('L4-nap', 'L4 a signal during a sleep is handled at once', START,
     "nap() {\n    sleep \"$1\" &\n    NAP_PID=$!\n    wait \"$NAP_PID\" 2>/dev/null || true\n    NAP_PID=\"\"\n}",
     "nap() {\n    sleep \"$1\"\n}", SH_START('G')),
    ('L6-lock', 'L6 only one instance runs', START, "if ! flock -n 9; then", "if false; then", SH_START('H')),
    ('L6-stop-waits', 'L6 stop waits for a start in progress', START, "    flock 9\n    teardown", "    teardown", SH_START('H')),
    ('L3-docker', 'L3 Traefik is not stopped', START,
     "start_nginx_captive_portal\nnap 1", "docker stop traefik 2>/dev/null || true\nstart_nginx_captive_portal\nnap 1", SH_START('A C')),
    ('R2-ap', 'R2 only an interface that supports AP is chosen', START, "iface_supports_ap \"$c\" || rc=$?", "rc=0", SH_START('D')),
    ('R2-exit3', 'R2 no AP-capable interface is exit status 3', START,
     "    log \"ERROR: $(cat \"$RUN_DIR/pick.err\" 2>/dev/null)\" err\n    rm -f \"$RUN_DIR/pick.err\"\n    exit 3",
     "    log \"ERROR: $(cat \"$RUN_DIR/pick.err\" 2>/dev/null)\" err\n    rm -f \"$RUN_DIR/pick.err\"\n    exit 1", SH_START('D')),
    ('R2-before-changes', 'R2 the interface is chosen before anything is changed', START,
     "# Step 1: Pick an interface that can run an access point (nothing has been changed yet)\nif ! WIFI_IFACE=\"$(pick_ap_interface 2> \"$RUN_DIR/pick.err\")\"; then",
     "start_nginx_captive_portal\n# Step 1: Pick an interface that can run an access point (nothing has been changed yet)\nif ! WIFI_IFACE=\"$(pick_ap_interface 2> \"$RUN_DIR/pick.err\")\"; then", SH_START('D')),
    ('R1-us', 'R1 no hard-coded country', START,
     "    if valid_country \"$c\"; then\n        echo \"$c\"\n    fi\n    return 0", "    echo \"${c:-US}\"\n    return 0", SH_START('A E')),
    ('R1-letters', 'R1 a country is two LETTERS (00, 98 and 99 are the kernel\'s placeholders)', START,
     "        [A-Z][A-Z]) return 0 ;;", "        [A-Z0-9][A-Z0-9]) return 0 ;;", SH_START('E')),
    ('R1-global', 'R1 only the global regulatory section counts', START, "            /^phy#/ { g = 0 }\n", "", SH_START('E')),
    ('R1-strict', 'R1 an override is exactly two letters', START,
     "        [A-Za-z][A-Za-z]) printf '%s' \"$v\" | tr 'a-z' 'A-Z' ;;", "        [A-Za-z]*) printf '%s' \"$v\" | tr -dc 'A-Za-z' | head -c 2 | tr 'a-z' 'A-Z' ;;", SH_START('E')),
    ('R1-after-prescan', 'R1 the country is read after the pre-scan taught the kernel one', START,
     "COUNTRY=\"$(detect_country)\"", "COUNTRY=\"\"", SH_START('E')),
    ('R3-isolate', 'R3 clients of the AP are isolated', START, "ap_isolate=1\n", "ap_isolate=0\n", SH_START('A')),
    ('R3-tkip', 'R3 only CCMP', START, "wpa_pairwise=CCMP", "wpa_pairwise=TKIP CCMP", SH_START('A')),
    ('H3-umask', 'H3 files written by the start are root-only', START, "umask 077\n\nROOT=", "umask 022\n\nROOT=", SH_START('A')),
    ('H3-dnslog', 'H3 the DNS query log is root-only', START, "    chmod 600 \"$DNSMASQ_LOG\"", "    chmod 644 \"$DNSMASQ_LOG\"", SH_START('A')),
    ('H3-hostapd-mode', 'H3 the hostapd config is root-only', START, "    chmod 600 \"$HOSTAPD_CONF\"", "    chmod 644 \"$HOSTAPD_CONF\"", SH_START('A')),
    ('L3-port80', 'L3 a foreign port-80 owner is reported, not stopped', START,
     "            log \"WARNING: port 80 is also held by another process", "            : \"WARNING: port 80 is also held by another process", SH_START('C')),
    # ---- monitor ------------------------------------------------------------------------------------------------------------
    ('L5-regex', 'L5 nmcli device state strings', MONITOR,
     "grep -Eq '^(connected|connecting)( \\(.*\\))?$'", "grep -Eq '(^|\\n)(connected|connecting|config|ip-config|ip-check|need-auth)($|\\n)'", SH_MONITOR),
    ('L5-locale', 'L5 nmcli is read in the C locale', MONITOR, "export LC_ALL=C\n", "", SH_MONITOR),
    ('R2-monitor-backoff', 'R2 exit 3 backs the monitor off', MONITOR, "    elif [ \"$rc\" -eq 3 ]; then", "    elif [ \"$rc\" -eq 99 ]; then", SH_MONITOR),
    # ---- scan parser --------------------------------------------------------------------------------------------------------
    ('R4-strongest', 'R4 the strongest BSS of an SSID wins', PRESCAN,
     "if known is None or entry['signal'] > known['signal']:", "if known is None:", PY_PRESCAN),
    ('R4-sae', 'R4 WPA3-only networks are labelled sae', PRESCAN, "        if 'sae' in akms:\n            return 'sae'\n", "", PY_PRESCAN),
    ('R4-enterprise', 'R4 802.1X networks are labelled enterprise', PRESCAN, "        if 'ieee8021x' in akms:\n            return 'enterprise'\n", "", PY_PRESCAN),
    ('R4-owe', 'R4 OWE networks are labelled owe', PRESCAN, "        if 'owe' in akms:\n            return 'owe'\n", "", PY_PRESCAN),
    ('R4-wep', 'R4 WEP networks are labelled wep', PRESCAN, "    if privacy:\n        return 'wep'\n", "", PY_PRESCAN),
    ('R4-nosignal', 'R4 an unreadable signal is the weakest', PRESCAN, "NO_SIGNAL = -100", "NO_SIGNAL = 0", PY_PRESCAN),
    ('R4-hidden', 'R4 hidden networks are left out', PRESCAN, "    if not data or all(b == 0 for b in data):\n        return None", "    if not data:\n        return None", PY_PRESCAN),
    ('R4-decoy', 'R4 only RSN/WPA element bullets define the key management', PRESCAN,
     "        elif section is not None and s.startswith('*'):", "        elif s.startswith('*'):", PY_PRESCAN),
    # ---- configs, units, installers ---------------------------------------------------------------------------------------
    ('S3-deny', 'S3 nginx /api/ ends with deny all', NGINX, "        deny all;\n", "", PY_STATIC),
    ('S3-allow-subnet', 'S3 nginx /api/ allows the setup subnet', NGINX, "        allow 192.168.99.0/24;\n", "", PY_STATIC),
    ('S3-allow-v6', 'S3 nginx /api/ allows IPv6 loopback', NGINX, "        allow ::1;\n", "", PY_STATIC),
    ('S3-open', 'S3 nginx /api/ is not open to everyone', NGINX, "        deny all;\n", "        allow all;\n", PY_STATIC),
    ('R3-static-isolate', 'R3 the shipped hostapd config isolates clients', 'payload/hostapd/hostapd-setup.conf', "ap_isolate=1", "ap_isolate=0", PY_STATIC),
    ('R1-static-country', 'R1 the shipped hostapd config sets no country', 'payload/hostapd/hostapd-setup.conf', "ieee80211n=1\n", "country_code=US\nieee80211n=1\n", PY_STATIC),
    ('R3-static-tkip', 'R3 the shipped default has no TKIP', 'payload/usr/share/setup-device/defaults/hostapd-setup.conf', "wpa_pairwise=CCMP", "wpa_pairwise=TKIP CCMP", PY_STATIC),
    ('H4-startlimit', 'H4 hostapd has a start limit', 'payload/systemd/system/hostapd-setup.service', "StartLimitBurst=5\n", "", PY_STATIC),
    ('L2-ubuntu-enable', 'L2 the deb does not enable nginx at boot', 'backends/ubuntu/headless-package/DEBIAN/postinst',
     "systemctl enable setup-backend.service 2>/dev/null || true\n", "systemctl enable setup-backend.service 2>/dev/null || true\nsystemctl enable nginx.service 2>/dev/null || true\n", PY_STATIC),
    ('L2-mint-enable', 'L2 the mint deb does not enable hostapd at boot', 'backends/mint/headless-package/DEBIAN/postinst',
     "systemctl enable setup-backend.service 2>/dev/null || true\n", "systemctl enable setup-backend.service 2>/dev/null || true\nsystemctl enable hostapd-setup.service 2>/dev/null || true\n", PY_STATIC),
    ('L2-fedora-enable', 'L2 the fedora installer does not enable dnsmasq-setup at boot', 'backends/fedora/headless-setup/install.sh',
     "systemctl enable setup-backend.service 2>/dev/null || true\n", "systemctl enable setup-backend.service 2>/dev/null || true\nsystemctl enable dnsmasq-setup.service 2>/dev/null || true\n", PY_STATIC),
    ('L2-arch-startnginx', 'L2 the arch installer does not start nginx', 'backends/arch/headless-setup/install.sh',
     "log_info \"Validating nginx configuration (nginx itself is started on demand by the hotspot script)...\"",
     "systemctl start nginx.service\nlog_info \"Validating nginx configuration (nginx itself is started on demand by the hotspot script)...\"", PY_STATIC),
    ('L2-disable', 'L2 an older install\'s boot-enabling is turned off', 'backends/arch/headless-setup/install.sh',
     "systemctl disable hostapd-setup.service 2>/dev/null || true\n", "", PY_STATIC),
    ('L2-nix', 'L2 NixOS does not start nginx at boot', 'backends/nixos/modules/headless-setup.nix',
     "    systemd.services.nginx.wantedBy = lib.mkIf cfg.portalOnDemand (lib.mkForce [ ]);\n", "", PY_STATIC),
    ('L3-nix-docker', 'L3 the NixOS monitor has no docker', 'backends/nixos/modules/headless-setup.nix',
     "        util-linux\n        systemd\n        coreutils\n        gnugrep\n        gnused", "        util-linux\n        docker\n        systemd\n        coreutils\n        gnugrep\n        gnused", PY_STATIC),
    ('K2-deb', 'K2 the deb depends on iw', 'backends/ubuntu/headless-package/DEBIAN/control', "network-manager, iw, iproute2, rfkill", "network-manager, iproute2, rfkill", PY_STATIC),
    ('K2-mint', 'K2 the mint deb depends on rfkill', 'backends/mint/headless-package/DEBIAN/control', "iw, iproute2, rfkill", "iw, iproute2", PY_STATIC),
    ('K2-fedora', 'K2 fedora installs iw', 'backends/fedora/headless-setup/install.sh', "NetworkManager iw iproute util-linux)", "NetworkManager iproute util-linux)", PY_STATIC),
    ('K2-arch', 'K2 arch installs util-linux', 'backends/arch/headless-setup/install.sh', "networkmanager iw iproute2 util-linux)", "networkmanager iw iproute2)", PY_STATIC),
]


def copy_tree(dest: Path):
    ignore = shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store')
    shutil.copytree(REPO / 'core' / 'headless' / 'payload', dest / 'payload', symlinks=True, ignore=ignore)
    for sub in ('ubuntu/headless-package', 'mint/headless-package', 'fedora/headless-setup', 'arch/headless-setup',
                'nixos/modules', 'cachyos/installer/modules'):
        shutil.copytree(REPO / 'backends' / sub, dest / 'backends' / sub, symlinks=True, ignore=ignore)


def run_suite(suite, tree: Path, timeout=1800):
    env = dict(os.environ)
    env['PAYLOAD_DIR'] = str(tree / 'payload')
    env['BACKENDS_DIR'] = str(tree / 'backends')
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    if suite[0] == 'py':
        cmd = ['nice', '-n', '10', sys.executable, '-B', '-m', 'unittest', suite[1]]
    else:
        cmd = ['nice', '-n', '10', 'bash', str(HERE / suite[1])]
        if suite[2]:
            env['ONLY_SECTIONS'] = suite[2]
    try:
        proc = subprocess.run(cmd, cwd=HERE, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, 'TIMEOUT'
    return proc.returncode, proc.stdout


def first_failure(output):
    for line in output.splitlines():
        if line.startswith('FAIL') or line.startswith('FAIL:') or line.startswith('ERROR:') or line.startswith('AssertionError'):
            return line.strip()[:110]
    return ''


def failures(output, limit=12):
    return '\n'.join(l for l in output.splitlines() if l.startswith(('FAIL', 'ERROR:', 'AssertionError')))[:limit * 150]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-k', dest='keyword')
    ap.add_argument('--list', action='store_true')
    ap.add_argument('-j', dest='jobs', type=int, default=3, help='mutations run at the same time (default 3)')
    args = ap.parse_args()
    selected = [m for m in MUTATIONS if not args.keyword or args.keyword in m[0] or args.keyword in m[2] or args.keyword in m[1]]
    if args.list:
        for m in selected:
            print(f'{m[0]:22} {m[1]}  [{m[2]}]')
        return 0
    if not shutil.which('nice') or not shutil.which('bash'):
        print('cannot run: nice and bash are needed', file=sys.stderr)
        return 2
    scratch = Path(tempfile.mkdtemp(prefix='payload-mutation-'))
    print_lock = threading.Lock()

    def say(text):
        with print_lock:
            print(text, flush=True)

    try:
        base = scratch / 'baseline'
        copy_tree(base)
        suites = []
        for m in selected:
            if m[5] not in suites:
                suites.append(m[5])

        def baseline(suite):
            label = suite[1] + (f' [{suite[2]}]' if suite[0] == 'sh' and suite[2] else '')
            rc, out = run_suite(suite, base)
            if rc != 0:
                rc, out = run_suite(suite, base)
            return suite, label, rc, out

        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            for suite, label, rc, out in pool.map(baseline, suites):
                if rc != 0:
                    say(f'BASELINE FAILS for {label}: the unmodified copy does not pass (twice); fix that first\n{failures(out) or out[-1500:]}')
                    return 1
                say(f'baseline ok: {label}')

        def one(m):
            mid, finding, rel, old, new, suite = m[:6]
            note = m[6] if len(m) > 6 else ''
            tree = scratch / mid
            copy_tree(tree)
            try:
                target = tree / rel
                text = target.read_text()
                if text.count(old) != 1:
                    say(f'{mid:22} BROKEN   {finding}: text found {text.count(old)}x')
                    return (mid, finding, 'BROKEN', f'mutation text found {text.count(old)} times in {rel}')
                target.write_text(text.replace(old, new))
                started = time.time()
                rc, out = run_suite(suite, tree)
                if rc != 0:
                    say(f'{mid:22} KILLED   {finding}  ({time.time() - started:0.0f}s)  {first_failure(out)}')
                    return (mid, finding, 'KILLED', first_failure(out))
                if note:
                    say(f'{mid:22} EQUIVALENT {finding}  ({time.time() - started:0.0f}s)  {note}')
                    return (mid, finding, 'EQUIVALENT', note)
                say(f'{mid:22} SURVIVED {finding}  ({time.time() - started:0.0f}s)')
                return (mid, finding, 'SURVIVED', '')
            finally:
                shutil.rmtree(tree, ignore_errors=True)

        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            results = list(pool.map(one, selected))
        killed = sum(1 for r in results if r[2] == 'KILLED')
        bad = [r for r in results if r[2] not in ('KILLED', 'EQUIVALENT')]
        print(f'\n== {len(results)} mutations: {killed} killed, {len([r for r in results if r[2] == "EQUIVALENT"])} equivalent (explained), '
              f'{len([r for r in results if r[2] == "SURVIVED"])} survived, {len([r for r in results if r[2] == "BROKEN"])} broken')
        for r in bad:
            print(f'   {r[2]}: {r[0]}: {r[1]} {r[3]}')
        return 0 if not bad else 1
    finally:
        if scratch.name.startswith('payload-mutation-'):      # only ever the directory mkdtemp made above
            shutil.rmtree(scratch, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
