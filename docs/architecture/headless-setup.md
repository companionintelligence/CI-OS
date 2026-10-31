# Headless Wi-Fi setup: how it works, what is wrong with it, and the tested library that replaces it

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

A Companion OS machine with no screen (a box in a cupboard, a Stick plugged into a server) must get onto the owner's Wi-Fi
and be claimed without anyone typing on it. Today a shell loop, `hostapd`, `dnsmasq`, `nginx` and one root Flask process do that.
This document records how they behave, 51 defects found in an audit on 2026-10-17, the design that replaces them, the threat
model, the phased plan, and the test strategy. It also documents the first piece of the replacement that exists and is tested:
the pure-Python library `core/headless/ci_setup/` (section 6).

Evidence tags used in the tables: **[V]** verified (read at the cited file and line, executed, or fetched from a public document
on 2026-10-17), **[I]** inferred from verified facts and not run, **[N]** not checked. "The audit" is the discovery report of
2026-10-17 that this document turns into repository documentation; "the stop-gap" is the set of small fixes to the current
code that is being landed in parallel (section 2.7).

## 0. Where things stand

| Phase | Work package | State |
|---|---|---|
| P0 | **WP-A** stop-gap fixes on the current payload | Written in the working tree, **not committed** when this was written (another agent owned it); landed in `b882e00`. Section 2.7 lists what it changes and what it leaves. |
| P0 | **WP-B** backend enablement (dependency lists, units not enabled at boot) | Edits to the Ubuntu, Arch (the provisioning engine under CachyOS) and CachyOS packaging were in the working tree, **not committed**, when this was written, and landed in `b882e00` with WP-A; not re-verified here. The Mint, Fedora and NixOS copies of those edits went with their backends on 2026-10-17 (restore: tag `pre-retire-multidistro-2026-10-17`). |
| P1 | **WP-C** core library | **Done** as a library: `core/headless/ci_setup/`, 28 modules, no service wiring. Section 6. |
| P1 | **WP-G** hwsim test infrastructure | A QEMU-based harness exists in `stick/tests/qemu/` (another agent, in progress); section 9.5. |
| P2 | WP-D agent and AP runtime, WP-E portal v2, WP-F console and names | Not started. They consume the library. |
| P3 | WP-H Stick integration, WP-I installer hand-off | Not started. |
| P4 | WP-J models page, concurrent AP+STA in the field, enterprise Wi-Fi | Not started. |

## 1. Today's map (before the stop-gap)

### 1.1 Components, who starts what, what runs as root

| Component | File (under `core/headless/payload/`) | User | Started by | Binds or touches |
|---|---|---|---|---|
| Network monitor | `usr/local/bin/setup-network-monitor.sh`, unit `systemd/system/setup-network-monitor.service` | root | boot | polls every 3 s: `ip route`, `ping 8.8.8.8`, `nmcli`; starts the AP after 2 failed checks past a 45 s grace |
| AP start script | `usr/local/bin/setup-device-hotspot-start.sh` (`set -e`) | root | the monitor; `start_hotspot_services()` in the backend on any exception; the reset script | `docker stop traefik`, `systemctl start nginx`, writes `/etc/hostapd/hostapd-setup.conf` and `/etc/dnsmasq.d/setup-portal.conf`, `nmcli device set <if> managed no`, flushes and re-adds `192.168.99.1/24`, runs the pre-scan, starts `hostapd-setup` then `dnsmasq-setup` |
| hostapd | `systemd/system/hostapd-setup.service`, `hostapd/hostapd-setup.conf` | root | the start script; also at boot in the Ubuntu and Arch packages (section 1.5) | nl80211, interface from the generated config |
| dnsmasq | `systemd/system/dnsmasq-setup.service` (`Requires=hostapd-setup`), `dnsmasq.d/setup-portal.conf` | root (drops to `nobody`) | same as hostapd | DHCP and a catch-all DNS on the AP interface |
| nginx | `nginx/sites-available/setup-portal` | root master, `www-data` workers | start script; enabled at boot in the Ubuntu and Arch packages | `listen 80 default_server` and `[::]:80`, static portal, `/api/` proxied to `127.0.0.1:5000` |
| Backend | `opt/setup-backend/setup_service.py`, unit `setup-backend.service` | **root**, `gunicorn --bind 127.0.0.1:5000 --workers 1 --threads 2` | boot | everything the API does: `nmcli`, `systemctl`, `ip`, `rfkill`, `netplan apply`, cloud HTTPS, writes under `/etc/setup-device` and `/var/lib/setup-device` |
| Pre-scan | `usr/local/bin/setup-device-prescan.py` | root | start script, once, before the AP exists | `iw dev <if> scan`, writes `/var/lib/setup-device/last-scan.json` |
| Hub hand-off | `usr/local/bin/ci-os-hub-start.sh`, `ci-os-post-validation.sh` | root | backend after pairing | sources `hub.env`, `provision.sh --step=ci-hub`, ROCm and Ollama pulls |
| Manual tools | `setup-hotspot-reset.sh`, `setup-wifi-recover` | root | by hand | restart NetworkManager; `modprobe -r` the first Wi-Fi driver found |

### 1.2 State machine as implemented

```
 boot
  |  monitor starts (After=network.target)
  v
 WATCH --(default route + ping 8.8.8.8 or gateway ok)--> WATCH           (fail_count=0)
  |  no route: wifi link "active or connecting"? --yes--> WATCH          (the regex matches only a bare "connected")
  |  configuring flag < 300 s old? ------------yes--> WATCH
  |  elapsed < 45 s and (NM connecting or scan list empty)? --yes--> WATCH
  |  fail_count >= 2 (about 6 s)
  v
 AP_START   stop Traefik, start nginx, rfkill unblock, new SSID suffix (4 random chars),
  |         write hostapd/dnsmasq configs (passphrase constant), NM managed=no, ip down/flush/up, pre-scan, add 192.168.99.1/24,
  |         start hostapd (one retry), start dnsmasq.   Failure -> 45 s back-off, run again.
  v
 AP_UP  (nothing stops it except /api/configure)
  |  POST /api/configure  (no credential)
  v
 CONFIGURE  create NM profile (deleting same-name profiles first), save credentials.json,
  |   hotspot up and wired internet -> pair first, then background join
  |   hotspot up, Wi-Fi only        -> 202 now, background: stop AP, managed=yes, join (30 tries), wait 20 s for internet, pair
  |   hotspot down (LAN client)     -> same, inline
  v
 JOINED / PAIRED   Hub callback or hub.env + ci-os-hub-start.sh
  failure -> record the pairing failure -> the monitor restarts the AP after back-off
```

### 1.3 Files and secrets

| Path | Writer | Mode as written | Content |
|---|---|---|---|
| `/etc/hostapd/hostapd-setup.conf` | installer, then the start script | 0644 | **the AP passphrase** |
| `/etc/dnsmasq.d/setup-portal.conf` | same | 0644 | interface, `address=/#/192.168.99.1`, `log-queries` to `/var/log/dnsmasq-setup.log` |
| `/etc/setup-device/pairing_code.json` | backend on first request | 0600 | local 6-character code, **never checked** (S1) |
| `/var/lib/setup-device/credentials.json` | backend | 0600 after `open()` and `chmod` | **plaintext Wi-Fi password** |
| `/var/lib/setup-device/cloud_credentials.json`, `hub.env` | `_write_secret_file` | 0600 | device key, tunnel id, zone |
| `/var/lib/setup-device/{ssid-suffix,last-scan.json,last_pairing_error.json}` | start script, pre-scan, backend | umask (0644) | SSID suffix, neighbour SSIDs, last failure text (contains the user's SSID) |
| `/var/log/setup-backend.log` | `logging.FileHandler` | 0644 | SSIDs, the pairing code in clear, the raw cloud GET body |
| `/run/setup-device/configuring` | backend | n/a | "I own the radio" flag, 300 s |
| `/etc/hosts` | postinst, `install.sh`, `stage-headless.sh` | n/a | permanent `192.168.99.1 setup.ci.computer` |
| `/etc/netplan/50-setup-mode.yaml` | Ubuntu package only | 0600 | `eth0` networkd renderer, removed on first configure |

### 1.4 HTTP surface (all through nginx, backend on loopback)

| Endpoint | Method | Auth | Effect |
|---|---|---|---|
| `/api/configure` | POST | **none** | profile create/delete, AP teardown, Wi-Fi join, cloud pairing, `ci-os-hub-start.sh` |
| `/api/status` | GET | none | `setup_complete`, `require_pairing`, `hub_running`, `last_pairing_error` (names the SSID) |
| `/api/networks`, `/api/scan-networks`, `/api/setup-data`, `/api/ssid-suffix` | GET | none | cached scan from AP start, SSID |
| `/health` | GET | none | liveness (the page called `/api/health`, which did not exist) |
| probe paths `/hotspot-detect.html`, `/connecttest.txt`, `/ncsi.txt`, `/generate_204`, `/canonical.html`, `/success.txt` | GET | none | 302 to `http://192.168.99.1/` (nginx only) |
| host port 5002 (CI Hub container) | any | none at this layer | reachable on the AP address; the nginx file says so on purpose |

### 1.5 Per-backend install matrix

| Backend | Boot-enabled units | Live-session behaviour | Notes |
|---|---|---|---|
| Ubuntu (`DEBIAN/postinst`) | hostapd-setup, dnsmasq-setup, nginx, setup-backend, setup-network-monitor | Ubuntu ISO: `10-not-live.conf` drop-ins keep those units off (`customize-chroot.sh`, asserted by `verify-iso.sh`) | `Depends` lacked `iw`; the ISO build installs it separately |
| Arch (`install.sh`, the engine under CachyOS) | same five | n/a | prints "only start once the monitor detects no connectivity", which was false; the list had no `iw` |
| CachyOS | setup-backend, setup-network-monitor | the live ISO has no hostapd, nginx, gunicorn or flask; the payload is staged on the target only | README: "runs only when it is needed" |

Retired on 2026-10-17 (restore from the tag `pre-retire-multidistro-2026-10-17`): the Mint, Fedora, NixOS and Bazzite packaging. The audit's findings on them went with them: the same five units enabled at boot by two of them, a stale `:5002` nginx proxy block and an always-on nginx in a third, and no portal at all in the fourth.

Doc drift: `docs/Create-headless-setup.md` (the original spec) says the pairing code is `XXX-XXX`, root-only, expires in 24 h and is
validated, that the hotspot units are gated on `setup-complete`, that the SSID is `Setup-Device-XXXX`, and that the page needs no
JavaScript. The code did none of that. `README.md` tells operators to `sudo cat /etc/setup-device/pairing_code.json` for "the" code.

### 1.6 What the audit did not check [N]

Nothing was run on a real NetworkManager, hostapd, dnsmasq, nginx, nft or gunicorn (stand-ins only, harness in the audit's
scratch directory). Real `iw` output was never captured (no wireless hardware); the scan parser was exercised on synthetic text.
Captive-portal behaviour of current iOS, Android and Windows is from general knowledge. Whether `hostapd-setup` really restart-loops
on an installed Ubuntu (L2) is reasoned from the units; the installed-boot probe prints `restarted-units` and will confirm or refute it.

## 2. Defects and risks

Severity: **Critical** = a stranger in radio range or on the LAN changes the device's network or identity with no credential; **High**
= serious exposure, or an availability loss that needs no attacker; **Medium** = real defect, narrower trigger; **Low** = hygiene.
"Stop-gap" says what the working-tree fixes do (section 2.7); "Closed by" says which part of the design finishes it.

### 2.1 Authentication and exposure

| ID | Sev | Defect | Tag | Stop-gap | Closed by |
|---|---|---|---|---|---|
| S1 | Critical | `/api/configure` needs no credential. With `require_pairing` it only checks "6 characters were typed" before creating the profile and queuing the join; the local `validate_pairing_code` has no callers. With no Launcher process (every Stick, every CachyOS box) there is no check at all. | V | no | per-session AP key + PIN + token (4.1), `auth.py` |
| S2 | Critical | The AP passphrase `SetupDevice123` is a public constant committed in four places; the portal is plain HTTP, so the Wi-Fi password and pairing code cross a link whose key everyone has. | V (constant), I (decryption: a WPA2-PSK property) | partly: the generated configuration is private, the committed default stays | per-session random key (4.1) |
| S3 | High | Anyone who can reach port 80 can use the API (`listen 80 default_server`, no `allow`/`deny`); nginx enabled at boot on four backends at the audit (two of them since retired). | V | **yes**: `allow` for the AP subnet and loopback, `deny all` on `/api/` | portal on the AP address only (4.0) |
| S4 | High | An unauthenticated caller can make the device delete NetworkManager profiles of **any** type whose name equals the posted SSID or "SSID N" (wired, VPN, Wi-Fi). | V | **yes**: only Wi-Fi profiles with this service's name prefix | `con-name = ci-setup-<uuid>` (4.7) |
| S5 | High | The CI Hub on host port 5002 is meant to be reachable from the AP; its unauthenticated `GET /api/registration/device-id` mints the callback nonce and `POST /registration/callback` accepts the Hub's identity. An AP client can register an unclaimed Hub onto its own tunnel. | V (code), I (exploit not run) | no | nft drop at prerouting/raw (4.4); a Hub-side fix is a CI-Hub task |
| S6 | High | No firewall for the AP subnet; Docker-published ports are NAT'd before the filter chains ufw manages, so a ufw INPUT rule would not protect 5002; Ollama on `0.0.0.0:11434` is open to the AP. | V (docs), I (reachability) | no | `fw.py` ruleset (4.4); packet test, section 9.3 |
| S7 | Medium | CSRF and DNS rebinding: `/api/configure` accepts form-encoded bodies, checks no `Origin`/`Host`/token, and nginx answers any `Host`. | V | partly (the subnet allow list) | Origin/Host allow-list, JSON only (4.1) |
| S8 | Medium | No rate limiting or lockout; no request-size limit beyond nginx's default. | V | partly: body size limit | `AttemptLimiter`, `PinGate` |
| S9 | Medium | Any AP client reads the last pairing failure (names the home SSID) from `/api/status`; the DNS query log of every phone is kept without rotation. | V | no | minimal public status (4.5); no query log in `apcfg.py` |
| S10 | Low | The cloud `redirect_url` reaches `window.location.assign()` after a check that accepts any scheme containing `://`. | V (code), I | no | portal v2 (WP-E) |
| S11 | Low | `save_hub_env` writes unquoted `KEY=value` lines that `ci-os-hub-start.sh` sources as root. | V (code), I | no | quoted, validated writes (WP-D) |
| S12 | Low | `ci-os-post-validation.sh` downloads a script from `raw.githubusercontent.com/.../main/scripts` (a directory that no longer exists) to a predictable `/tmp` path and runs it as root. | V | no | delete the fallback |

### 2.2 Input handling (nobody found shell or config injection, and the audit did not either)

SSID, password and pairing code reach `nmcli` as separate argv entries (no shell), `credentials.json`, the log, and (SSID only) JSON
and HTML responses where they are escaped. The hostapd and dnsmasq files were generated from values the script makes itself. [V]

| ID | Sev | Defect | Tag | Stop-gap | Closed by |
|---|---|---|---|---|---|
| I1 | Medium | No validation: SSID length in bytes, control characters, PSK length. Failures surface as a generic 500 or an unseen `nmcli` error. | V | **yes**: `validate_ssid`, `validate_psk` in the service | `validators.py` (one module for API, provisioning file and CLI) |
| I2 | Medium | The PSK is on the `nmcli` command line, readable through `/proc/<pid>/cmdline` for the length of the call. | V | **yes**: handed over in a root-only `passwd-file` (the behaviour on a real NetworkManager is unverified) | D-Bus or a 0600 keyfile (4.5) |
| I3 | Medium | `credentials.json` keeps the Wi-Fi password in clear next to the NM keyfile, created with `open()` then `chmod`. | V | partly: created private from the first byte, still plaintext | no `credentials.json`; `privfile.py` |
| I4 | Medium | Log hygiene: pairing code and local code logged in clear, raw cloud GET body logged, log file 0644, SSID logged raw so a newline forges lines. | V | **yes**: scrubbing formatter, private log file, no pairing code | canary test over `journalctl`, `/run`, `ps` (9.3) |
| I5 | Medium | A connected profile named like the SSID is reused and the **submitted password is ignored**; otherwise the same-name profile is deleted before the new one is proven, so a typo destroys the working credentials. | V | no | join with rollback (4.5) |
| I6 | Medium | Security hard-coded to `wpa-psk` or `none`: no SAE, OWE, 802.1X, hidden SSIDs; outcomes decided by lower-casing English `nmcli` messages without `LC_ALL=C`. | V (code), I (locale) | no | `JOINABLE_SECURITY`, `LC_ALL=C` runner |
| I7 | Low | Every profile gets `ipv4.dns 8.8.8.8 1.1.1.1`, leaking the user's DNS to two third parties. | V | no | remove (decision 11) |
| I8 | Low | `get_device_id()` passes `stderr=DEVNULL` to `capture_output=True`, which raises, so the `dmidecode` probes can never succeed. | V | **yes** | n/a |
| I9 | Low | Connectivity depends on Google (`ping 8.8.8.8`, `nslookup google.com`). | V | no | NM connectivity + Portal HTTPS (decision 9) |
| I10 | Low | `nmcli device wifi list` is run without `--rescan no`, contradicting the module's own "never scan" rule. | V | no | allow-list requires `--rescan no` |

### 2.3 Privilege, hardening, services

| ID | Sev | Defect | Tag | Stop-gap | Closed by |
|---|---|---|---|---|---|
| H1 | High | The network-facing process is root with no sandbox (`NoNewPrivileges`, `ProtectSystem`, `PrivateTmp`, `CapabilityBoundingSet`, `RestrictAddressFamilies`, `SystemCallFilter` all absent). | V | no | agent + unprivileged portal (4.0) |
| H2 | Medium | Module-level `signal.signal(SIGTERM/SIGINT)` replaces gunicorn's own handler, so `systemctl stop` waits out `TimeoutStopSec`. | V (23.0.0 source), I (image version) | **yes**: handlers moved into `main()` | WP-E |
| H3 | Medium | Secrets in world-readable files: hostapd config (0644), backend log, `last_pairing_error.json`. | V | **yes**: umask 077, hostapd config and log 0600 | `privfile.write_private_file` under `/run` |
| H4 | Low | `Restart=on-failure` with no `StartLimit*`: a hostapd that cannot start loops forever. | V | **yes**: `StartLimitBurst=5` in 120 s | systemd analyze test (L3) |
| H5 | Low | `/etc/hosts` gets a permanent `setup.ci.computer` line on every installed machine. | V | no | mDNS names (4.5) |
| H6 | Low | `/etc/dnsmasq.d/setup-portal.conf` is globbed by any other dnsmasq on the host. | I | no | rendered into `/run`, `-C` only (`apcfg.py`) |

### 2.4 Lifecycle and availability

| ID | Sev | Defect | Tag | Stop-gap | Closed by |
|---|---|---|---|---|---|
| L1 | High | The radio is set `managed no` at AP start and back to `yes` only inside a successful portal run. A machine that boots a minute before its router becomes an AP and stays one. | V (code), I (scenario) | no (the monitor still never stops the AP) | idle duty cycle (4.4), `jobs.py` timeouts |
| L2 | High | `hostapd-setup`, `dnsmasq-setup` and `nginx` enabled at boot on four backends (two since retired) with a static config naming `wlp192s0`: on any other machine hostapd restarts every 5 s forever. | V (units), I (runtime) | **yes**: not enabled at boot (WP-B) | agent starts the AP target on demand |
| L3 | High | `docker stop traefik` at every AP start, guarded by `docker ps \| grep -q traefik`; nothing ever starts it again. | V | **yes** (per the working tree) | redirect 80 to 8080 instead (4.4) |
| L4 | High | No cleanup: the `192.168.99.1/24` address, nginx, the DNS log and the unmanaged flag stay; `set -e` with no trap leaves NM unmanaged on a failure. | V | **yes**: trap and cleanup | `ExecStopPost` + reconcile pass (4.4) |
| L5 | Medium | `wifi_link_active_or_connecting` matches only a bare `connected`, but `nmcli` prints `connecting (getting IP configuration)`, `connected (externally)` ... | V | **yes**: matches `connecting*` and `connected*` | `parse_device_state` (keeps the detail apart) |
| L6 | Medium | Two callers start the AP with no lock; the script's `sleep`s plus the pre-scan exceed the caller's 30 s `timeout`. | V (sleeps), I (typical) | **yes**: `flock` | single agent (4.0) |
| L7 | Medium | Any exception in `configure()` re-runs the whole AP start: a malformed JSON body restarts the AP for any caller. | V | **yes** | `loads_strict` -> `ValidationError`, never touches the AP |
| L8 | Medium | The connectivity test is Google-specific and IPv4-only and counts a gateway ping as "online". | V | no | NM connectivity (decision 9) |
| L9 | Medium | The 45 s boot grace is shorter than many routers' cold start; no periodic re-probe once the AP is up. | V | no | idle duty cycle |
| L10 | Low | `setup-hotspot-reset.sh` defaults to `wlp192s0` and restarts NetworkManager (dropping wired links); `setup-wifi-recover` unloads the first driver it finds. | V | partly (both scripts changed) | `ci-setup reset` / `recover` |
| L11 | Low | A new random SSID suffix on every AP start. | V | no | stable suffix from the setup key or `product_uuid` |
| L12 | Low | Fixed subnet `192.168.99.0/24`; collides with an uplink on the same subnet. | V | no | `pick_ap_subnet` |

### 2.5 Radio

| ID | Sev | Defect | Tag | Stop-gap | Closed by |
|---|---|---|---|---|---|
| R1 | High | `country_code=US` hard-coded, `hw_mode=g channel=6`, no `ieee80211d`, no probe of the current regulatory domain. | V | **yes**: no default country | `regdom.py` |
| R2 | Medium | The interface is the first `wifi` device `nmcli` lists; no `iw` capability probe. | V | **yes**: an AP-capable interface per `iw` | `probe.select_radio` |
| R3 | Medium | No `ap_isolate`, no `ctrl_interface`, TKIP listed in the generated `wpa_pairwise`. | V | **yes**: `ap_isolate=1`, CCMP only | `apcfg.render_hostapd` |
| R4 | Medium | The "never scan in AP mode" rule is applied to every chip, so the network list never refreshes; the parser keeps the first BSS per SSID, calls SAE/OWE/802.1X `wpa-psk` and WEP `none`, and the UI prints dBm as a percentage. | V (synthetic input) | partly | `parsers/iw.py` (classification, strongest BSS, `signal_pct`) |
| R5 | Low | IPv6 ignored. | V | no | none (no addresses on the AP) |

### 2.6 Packaging, tests, UI

| ID | Sev | Defect | Tag | Stop-gap | Closed by |
|---|---|---|---|---|---|
| K1 | Medium | Arch printed that the AP units "only start once the monitor detects no connectivity" right after enabling them at boot (a second backend, since retired, printed the same). | V | **yes**: the units are no longer enabled and the message is true | n/a |
| K2 | Medium | Undeclared runtime dependencies: `iw` missing from the deb `Depends` and from `ARCH_DEPS` (and from the list of a third backend, since retired); `ip`, `rfkill`, `ping`, `nslookup`, `systemd-cat`, `stat -c` assumed. | V | **yes** for `iw`, `iproute`, `util-linux` in the lists read | the lists of 4.8 |
| K3 | Medium | No test exercises any payload code. | V | **yes**: payload tests under `core/headless/tests/payload` (another agent's) | the `ci_setup` suites, section 9 |
| U1 | Low | The portal polls `/api/health` (404) every 5 s. | V | **yes**: the route exists | n/a |
| U2 | Low | `runLegacyCaptivePortalDismissal()` navigates to `captive.apple.com/hotspot-detect.html`, which dnsmasq resolves to the portal and nginx redirects straight back, so it can never produce the "Success" page. | I | no | `captive.py` answers it in the done state |
| U3 | Medium | No progress model: on a single-radio chip the phone loses the AP during the join, the page redirects after 20 s, and the result exists only in `/api/status`. | V | no | `jobs.py` steps and persisted job result (4.5) |

### 2.7 What the stop-gap changes (working tree, uncommitted, read on 2026-10-17)

From `git diff` of `core/headless/payload/` and of the backends' packaging files: `nginx` restricts `/api/` to the AP subnet and loopback and caps the body at 64 KiB;
`hostapd-setup.service` and `dnsmasq-setup.service` get `StartLimitIntervalSec=120` / `StartLimitBurst=5` and are no longer enabled at
boot; the default AP configuration drops `country_code=US` and TKIP and adds `ap_isolate=1`; the start script detects an AP-capable
interface with `iw`, takes the country from `/etc/setup-device/regdom`, `ci.country=XX` or `iw reg get`, runs under a lock with a
cleanup trap, and no longer stops Traefik; `setup_service.py` validates the SSID and passphrase, scrubs secrets from every log line,
keeps the log file private, deletes only Wi-Fi profiles with its own name prefix, no longer restarts the AP for a malformed body,
registers its signal handlers in `main()` only, hands the passphrase to `nmcli` in a root-only password file, matches every `connecting (...)` and `connected (...)` state, and answers `/api/health`. It does **not** add authentication (S1, S2), sandboxing
(H1), a firewall (S5, S6), an idle duty cycle or a credential channel. The library and the stop-gap agree on the country file
(`/etc/setup-device/regdom`, then `/var/lib/setup-device/regdom`).

The payload was still being edited while this document was finished (the start script was last changed at 13:24 on 2026-10-17, after
the stop-gap column of section 2 was checked against it). Treat that column as true of the working tree as read, and re-check it
against the commit that lands the stop-gap.

## 3. Threat model for the redesign

Attackers: **A1** a stranger in radio range with no secret; **A2** a holder of the AP key (saw the screen or the sticker); **A3** a
peer on the user's LAN or Wi-Fi; **A4** a local unprivileged account on the box (the live `ubuntu` user); **A5** a web page in a
browser that can reach the device; **A6** someone with the Stick or box in hand; **A7** a hostile cloud or portal response.

| Asset | Attacker | Threat | Design mitigation | Residual |
|---|---|---|---|---|
| User's home Wi-Fi password | A1 | read it off the air | per-session random AP key (12 of 31 symbols, about 59 bits), WPA2-CCMP | the key is visible to anyone who sees the console or QR (physical presence accepted) |
| same | A2 | read it from other clients' traffic | `ap_isolate=1`, `max_num_sta=4`, PIN gates the API, token bound to the client address | a co-resident with the key can observe other phones; accepted, one trusted user at a time |
| same | A4 | `ps`, `/proc`, world-readable log or `credentials.json` | secrets to NM through D-Bus or a 0600 keyfile, never argv; no `credentials.json`; 0600 files under `/run`; log redaction with a canary test | none known |
| Device network position | A1, A2, A3, A5 | force the device onto an attacker SSID; delete saved profiles | PIN and token on every state-changing call; `Origin`/`Host` allow-list; JSON only; deletion only of profiles this service created | A2 who has the PIN |
| Device claim (cloud pairing) | A1, A2 | claim an unclaimed device | the cloud pairing code stays a cloud-side check after the PIN | the physical possessor can claim an unclaimed device: inherent |
| Hub identity (tunnel token) | A2 | register an unclaimed Hub over port 5002 | nft drops every AP packet except DHCP, DNS and the portal at prerouting/raw, before Docker's DNAT | a Hub-side fix (nonce on `device-id`, drop the GET callback) is a CI-Hub task |
| Availability of setup | A1, A2 | restart the AP with a bad body; exhaust threads | the error path never touches the AP; limits per client and overall; PIN rotation; body-size cap | radio jamming |
| LAN services | A3 | reach the portal or API from the LAN | portal listens on the AP address only; nothing on `0.0.0.0` | none |
| Local root | A4, A7 | argv, log or env-file injection into root scripts | agent in a systemd sandbox; typed JSON to a fixed set of operations; `hub.env` written quoted and validated | the agent remains root |
| Model tokens (Hugging Face) | A1, A2 | sniff the token on the AP | never accepted on the AP; held only in the kernel keyring; redaction filter and `LogFilterPatterns=` | a token typed on the LAN needs HTTPS |
| Stick | A6 | read a per-stick key from the label or ESP | key valid only until the first claim, then replaced; optional `--no-label` mode | whoever claims first wins, as with any unclaimed appliance |
| Config files | A5, A7 | smuggle a directive line into hostapd, dnsmasq or nft through an SSID or a name | typed parameter objects, SSID written as hex, single-pass templates, a lint of the rendered text (6.4) | none known |
| Probe output | A1 | a neighbour's SSID forges a field in `nmcli`/`iw` output | `iw` escapes (decoded and re-escaped); `nmcli` rows with the wrong field count are dropped; **an `nmcli` SSID is display-only** | a forged row with the right field count cannot be told apart (documented by a test) |

## 4. Target design

### 4.0 Shape

```
ci-setup-agent.service   root, always on, sandboxed. Probes, decides, owns state (/run/ci-setup/state.json), drives the AP target.
ci-setup-ap.target       Wants: ci-setup-fw, ci-setup-hostapd, ci-setup-dnsmasq, ci-setup-web.socket, ci-setup-banner. Conflicts: shutdown.
ci-setup-fw.service      oneshot: loads and removes the nft tables of fw.py.
ci-setup-hostapd.service hostapd, config rendered by the agent into /run/ci-setup/hostapd.conf (0600). ExecStopPost cleans.
ci-setup-dnsmasq.service dnsmasq -C /run/ci-setup/dnsmasq.conf (no conf-dir, so nothing from /etc/dnsmasq.d).
ci-setup-web.socket      ListenStream=<AP-IP>:8080, FreeBind=yes, started only with the target.
ci-setup-web.service     unprivileged, no capabilities, talks to the agent over /run/ci-setup/agent.sock (SO_PEERCRED).
ci-setup (CLI)           status, show, start, stop, probe, doctor, reset, recover
```

Why split the web process from the agent: today one root process parses attacker-controlled HTTP and runs `nmcli`/`systemctl`. After
the split the web process cannot touch the system; it can only ask the agent for the fixed operations of 4.5 with typed arguments
that the agent validates again. Socket-activated and bound to the AP address, the portal does not exist on any other interface and
does not need port 80.

### 4.1 Credentials and the authentication model

**Three secrets, three jobs.** (1) **AP key**: 12 characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (no look-alikes), from `secrets`,
new for every AP session, never written outside `/run/ci-setup`. (2) **PIN**: 6 digits, new per session, valid 10 minutes, rotated after
5 failures overall or on expiry, compared in constant time. (3) **API token**: issued by `POST /api/v1/auth {pin}`, HMAC-signed, bound to
the client address, 15 minutes sliding with an absolute cap of 45 minutes, sent as `Authorization: Bearer` (a header, not a cookie,
because captive-sheet WebViews restrict cookies and storage [I]). Every state-changing call also needs `Content-Type:
application/json`, an `Origin` that is absent or equals the portal origin, and a `Host` in the allow-list. The cloud pairing code
stays a claim code entered after the PIN, because the device can only validate it once it is online.

The old local code was the right idea in a form that could not work: persistent, never shown, never checked, logged in clear, 31
bits, no lockout. The PIN keeps its good parts (CSPRNG, root-only, constant-time compare) and fixes the rest. `pairing_code.json` is
retired; `ci-setup show` replaces `sudo cat`.

**Where the operator sees the secrets** (the channel decides which mode is available; `policy.credential_channel` implements this):

| Situation | Channel | What is shown |
|---|---|---|
| A display is attached | console banner on `/dev/tty1` and `/dev/console`, `/run/issue.d/60-ci-setup.issue`, a Plymouth message if it runs | SSID, AP key, PIN, URL, and the Wi-Fi QR code (`wifi_qr.console_qr`, or `qrencode`) |
| A graphical session exists | desktop notification, not the AP (the desktop already has Wi-Fi settings) | the same text |
| No display, a **label** or a per-stick key exists | printed setup key; AP key, PIN and SSID suffix derive from it (`auth.derive_credentials`) | the label states the SSID suffix and the key; the key is burned (replaced, no longer valid) at the first claim |
| No display, no label | **no AP is opened**; the agent logs why and waits for the provisioning file | `ci-setup show` over SSH if SSH exists |
| Test only | `ci.setup.static_credentials=1`, refused unless `ci.headless=1` is also set, with a loud banner line | hwsim tests |

The Wi-Fi QR payload is `WIFI:T:WPA;S:<ssid>;P:<key>;;` (ZXing format; Android and iOS 11 cameras): `\ ; , " :` are escaped, a value
made only of hex digits is wrapped in double quotes. The AP key alphabet needs no escaping.

### 4.2 Interface selection, capability probe, regulatory domain

**Probe** (`probe.py`, pure over command output): `iw dev` for interfaces, `iw phy <phy> info` for modes, bands, per-frequency flags
(`disabled`, `no IR`, `radar detection`) and the `valid interface combinations`, `iw reg get` (including `self-managed` blocks),
`rfkill list`, `ip -j link/addr/route`, `nmcli -t` device, connection and connectivity, and the bus and driver from `/sys`.

**Choice of radio**, in order (`probe.select_radio`):

1. An AP-capable radio that does not carry the uplink or an association hosts the AP (PCIe and SoC before SDIO before USB). If another
   radio can join, the mode is **dedicated**: the AP stays up while the other radio joins the home network.
2. With one radio: if the driver allows AP and station together on **two channels**, **concurrent**; if on one channel only, the AP
   follows the uplink's channel (`follow_uplink_mhz`) when an uplink exists, and the join is sequential otherwise.
3. Otherwise **sequential**: the AP and the join take turns (the phone drops for a few seconds).
4. No radio can run an AP (`no_ap_capable_radio`), none is usable (`hard_blocked`, `no_netdev`) or there is no Wi-Fi (`no_wifi`): mode
   `none`, the reason in the report, nothing touched. The old script retried every 45 s while taking the radio away.

**Channel** (`regdom.plan_channel`): 2.4 GHz only unless 5 GHz is requested; channels 1, 6, 11 minus any flagged `disabled`, `no IR` or
`radar`, least loaded by the scan survey (a neighbour on the channel counts fully, within two channels half, within four a quarter; ties prefer 6).
5 GHz only if the country is known and the radio lists a non-DFS, non-`no IR` channel in the **current** domain; **DFS is never used**
(an AP would have to listen for radar for 60 s and can be forced off). Channels 12 and 13 only for a country on the short list of
certain 1-13 countries, and only when 1, 6, 11 and 2-10 are all unusable.

**Regulatory domain**, first hit wins (`regdom.resolve_country`): (1) `ci.country=XX` on the kernel command line or
`/etc/setup-device/regdom` (or `/var/lib/setup-device/regdom`); (2) the kernel's current domain unless it is `00`/`97`/`98`/`99`, with a
phy that has a **self-managed** domain read from its own block (the chip ignores hostapd's `country_code`); (3) the country announced
by at least 3 scanned networks and at least 60 % of those that announce one; (4) the country of the time zone, when exactly one country
owns it (`zone.tab`); (5) **unknown**: `country_code` and `ieee80211d` omitted, channels 1-11, no 5 GHz. `country_code=US` as a
constant is gone.

### 4.3 Live-session operation from the Stick (`policy.py`)

The static guards (`ConditionPathExists=!/cdrom/casper/vmlinuz` on five units) are replaced by **one decision function**: the agent
always runs; policy decides whether it opens an AP. Inputs: the kernel command line (`ci.headless=0|1|auto`, `ci_stick.slot=`,
`boot=casper`, `archisobasedir`, and `rd.live.image`, a dracut live image that no supported edition uses; `is_live_boot` in `core/headless/ci_setup/sysinfo.py` still tests for it and this list is kept in step with it), connected DRM connectors, the claim state (`hub.env` or `cloud_credentials.json`),
network state, the provisioning file, the radio probe, the credential channel. The table below is generated by
`python3 -m ci_setup policy --matrix --table` and pinned by a golden-file test (with a printed setup key present):

```
context                        display   network automatic                          with ci.headless=1
------------------------------------------------------------------------------------------------------
live (plain media)             connected up      no (network_up)                    AP
live (plain media)             connected down    no (plain_live_media)              AP
live (plain media)             headless  up      no (network_up)                    AP
live (plain media)             headless  down    no (plain_live_media)              AP
live (Stick)                   connected up      no (network_up)                    AP
live (Stick)                   connected down    no (display_attached)              AP
live (Stick)                   headless  up      no (network_up)                    AP
live (Stick)                   headless  down    AP                                 AP
installed-unclaimed            connected up      no (network_up)                    AP
installed-unclaimed            connected down    no (display_attached)              AP
installed-unclaimed            headless  up      no (network_up)                    AP
installed-unclaimed            headless  down    AP                                 AP
installed-claimed              connected up      no (claimed_lockdown)              AP
installed-claimed              connected down    no (claimed_lockdown)              AP
installed-claimed              headless  up      no (claimed_lockdown)              AP
installed-claimed              headless  down    no (claimed_lockdown)              AP
```

Rules behind it, all tested for every combination (144 rows with kernel parameter and trigger variations): a machine with a display
never becomes a hotspot by itself; a claimed appliance never does; plain live media never does; where it may (a Stick or an unclaimed
install without a display) it does so only after the network has been down for 60 s; `ci.headless=0` switches the automatic AP off; a
display state of `unknown` (no `/sys/class/drm`) counts as a display; explicit recovery is `ci.headless=1`, the boot-menu entry, `ci-setup
start` or the physical key, and **no event the AP or the LAN can cause is a trigger** (unknown trigger names are ignored and
reported). Every AP, automatic or not, needs a radio that can run one and a credential channel. Without a printed setup key a
headless machine opens nothing, which is deliberate: the two "AP" rows of the automatic column become `no (no_credential_channel)`, and
so does every headless row of the `ci.headless=1` column (`golden/policy_table_no_key.txt`). Timing: 60 s without a usable network (the
audit's figure for a Stick; the same value is used for an unclaimed install, which the audit left open).

**Provisioning file (no radio).** `CI-SHARED` is exFAT, readable on macOS, Windows and Linux. A file `companion-setup.json` there:

```json
{"version": 1,
 "wifi": [{"ssid": "HomeNet", "psk_hex": "<64 hex>", "hidden": false, "security": "wpa2"}],
 "country": "DE", "hostname": "companion-os"}
```

`psk_hex` is the WPA2 pairwise master key, `PBKDF2-HMAC-SHA1(passphrase, ssid, 4096, 32 bytes)`, so the file need not hold the
passphrase; a plain `psk` is accepted (SAE-only networks need it) and flagged. `validators.validate_provisioning_doc` is the schema:
version 1, no unknown keys, at most 8 networks, an open network takes no key, a raw key only for WPA2 and the WPA2/WPA3 transition mode,
the same SSID and passphrase rules as the API. The agent mounts the volume read-only with `nosuid,nodev,noexec`, joins, verifies (4.5),
writes `companion-setup.result.txt` (outcome, SSID, IP, name; no secret) back with a read-write remount, and renames the input to
`.done`. This is the safest headless path: no AP, no firewall surface, no phone. Someone with the Stick in hand can plant a file (A6);
accepted, they can do worse with the Stick.

**What persists to `CI-PERSIST`** only when casper really uses the `writable` volume: the NM keyfile of the joined network and
`/var/lib/setup-device/{cloud_credentials.json,hub.env,regdom}`. Not persisted: AP key, PIN, tokens, hostapd and dnsmasq configs (all
under `/run`). Without persistence the banner says so.

### 4.4 Lifecycle, NetworkManager, firewall, Docker

| Event | Action |
|---|---|
| Entry (policy says yes) | probe, render files, start `ci-setup-ap.target`, `nmcli device set <if> managed no` (marker file), flush stale addresses, add the AP address |
| Idle duty cycle | while no station is associated, every 120 s stop the AP for at most 20 s, `managed reset`, let NM autoconnect to known networks, re-enter only if there is still no connectivity (closes L1) |
| Exit: success | join verified, keep the AP 30 s so the phone sees the result, stop the target |
| Exit: cancel | `POST /api/v1/cancel` or console; same teardown |
| Exit: timeout | 15 min with no authenticated client, 45 min total; then 10 min quiet; then a new session with a **new** key and PIN, at most 3 per boot unless the user triggers it |
| Exit: uplink appears | default route + NM connectivity `full` or `limited` for 60 s with no authenticated client: stop |
| Every exit | flush the AP address, `managed reset` if the marker exists, delete the nft tables, remove the issue file and banner, remove the rendered files; a reconcile pass at agent start undoes the same after a crash |

`jobs.py` implements the state machine behind this table; the idle, total and per-step timeouts are its defaults (15 min, 45 min, 60 s
probe, 30 s start-of-join, 90 s join, 60 s verify, 60 s rollback). NetworkManager: `nmcli device set <if> managed no` changes the
runtime state only; every exit uses `managed reset`, not `yes`.

**Firewall** (`fw.py`, rendered from `templates/ci_setup.nft.in`): two dedicated tables that exist only while the AP is up; the filter
hooks `prerouting` at priority `raw` (-300), before connection tracking and before Docker's DNAT (-100), so a container port published
on `0.0.0.0` cannot be reached from the AP. From the AP interface only DHCP (client port 68 to 67, which a client without an address
sends from `0.0.0.0`) is accepted by port alone; from a source address inside the AP subnet only DNS and HTTP to **any** destination
(redirected to the local resolver and the portal port), the portal port on the AP address, mDNS, and ping to the AP address at 5 per
second are accepted; everything else from the interface is dropped, including SSH, 5002, 11434, every Docker-published port and
anything sent from a spoofed source address. A `forward` chain drops all traffic into or out of the AP interface. No NAT leaves the AP. Loading is one
transaction (`add`/`delete`/define), so it is idempotent; the teardown script works whether or not the tables exist.

Two limits to know. (1) `accept` ends evaluation of **its own base chain** only: a packet accepted here still passes other tables' chains
on the same hook, so a host firewall with a default-deny input policy (ufw) would still drop the portal port unless the agent opens the
AP interface in it for the lifetime of the AP. The shipped images have no such firewall; this must be handled before one does.
(2) The rule syntax was checked against a real nftables (v1.1.7) and the behaviour with packets against a real kernel
(section 9.3). The sketch in the audit used a chain named `fwd`, which nftables rejects (`fwd` is a statement keyword); the chain is
named `forward`.

Docker and Traefik are never touched (the old script stopped Traefik so that port 80 was free; the redirect to 8080 removes the
need). Tailscale and other VPNs: the agent's route test reads the main table and NM connectivity; an exit-node default route is not in
the main table. IPv6: no addresses on the AP; DNS answers A only. Time: no NTP on the AP; a device without an RTC may have a wrong
clock, so the verify step tolerates up to 2 minutes or checks `timedatectl`.

### 4.5 Portal features

API v1 (all under `/api/v1`, JSON, `Authorization: Bearer` except the first two):

| Endpoint | Purpose |
|---|---|
| `GET /status` (public, minimal) | `{state, ssid (the AP's own), needs_pin, version}`: `Job.public_view()` plus the AP's SSID and the version; no home SSID, no errors, no addresses |
| `POST /auth {pin}` | token; 429 with `Retry-After` after the limits; the PIN rotates after 5 failures overall |
| `GET /health` | interface, phy, mode, regdom, clients, uplink and NM connectivity, time sync, free space, persistence, `CI-CACHE`, slot, last errors |
| `GET /wifi/networks` | cached list with its age; `security` in {open, wpa2, wpa3, sae-only, owe, enterprise, wep, wpa1, unknown}, `signal_dbm`, `signal_pct`, strongest BSS per SSID, hidden flagged separately |
| `POST /wifi/join {ssid, psk?, hidden?, security?}` | validated (`validate_wifi_join_request`), returns `202 {job}` |
| `GET /jobs/<id>` | `state` and `step` of the job, `error_code` in {`bad_psk`, `no_ap_seen`, `dhcp_timeout`, `no_internet`, `upstream_portal`, `time_wrong`}; persisted under `/run/ci-setup/jobs/` so the result is shown when the phone reconnects |
| `POST /cancel` | tear down |
| `GET /models/...`, `POST /models/...` | section 4.6 |

**Join with rollback** (agent side): remember the active Wi-Fi profile `prev`; create `new` named `ci-setup-<job>` with `autoconnect no`;
pass the passphrase without argv (D-Bus `AddConnection2` or a 0600 keyfile loaded with `nmcli connection load` [I]); sequential radios
save the job, stop the AP, `managed reset`, `nmcli connection up new` (45 s); **verify** = device `activated` and a lease and
connectivity `full` and an HTTPS HEAD to the Portal URL; `portal` connectivity means an upstream sign-in page and ends the job
`upstream_portal` with advice. Success: `autoconnect yes`, rename to the SSID, delete an older same-SSID profile this service did not
create only now. Failure: delete `new`, bring `prev` back up (rollback), or with no `prev` re-open the AP with the **same** key and PIN
so the phone reconnects to the network it already trusts. The `jobs.py` machine has a `rolling_back` state for exactly this (an addition
to the audit's list: undoing a join takes time and can fail, so it is observable and bounded).

**Captive-portal answers** (`captive.py`, served by the portal on 8080 after the 80 redirect). While setup is pending every probe gets a
302 to `http://<ap-ip>/`; after success the same URLs answer what the OS expects so the sheet closes: 204 for `/generate_204` and
`/gen_204`, `<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>` for `/hotspot-detect.html` and
`/library/test/success.html`, `Microsoft Connect Test` for `/connecttest.txt`, `Microsoft NCSI` for `/ncsi.txt`, `success\n` for
`/canonical.html` and `/success.txt`; `/redirect` stays a 302. Nothing from the request reaches a response header or body. DHCP option
114 / RFC 8910 is not used: it requires an `https` URI and the AP has no certificate people trust. These bodies are those the vendors
document or that are widely observed; **they have not been checked against devices** [N] (Appendix A).

**Names**: `companion-os.local` and `companion.local` published by Avahi on the AP interface; Android browsers resolve `.local`
unreliably, so the IP URL is the primary link. **Content security**: split the inline script and style out of `index.html`, serve
`Content-Security-Policy: default-src 'self'; frame-ancestors 'none'`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store`.

### 4.6 Model download page (what the portal needs; the contract is in `models-tooling.md`)

The portal is a thin authenticated proxy to a local service over a Unix socket; it never opens a model file itself. It needs: storage
candidates (`GET /models/storage`: id, label, path, fs, free and total bytes, removable, symlink and hardlink support), packs that fit
(`GET /models/packs?storage=`), start/pause/resume/cancel of tasks (resume is a property of the service: byte ranges and verified
blobs), progress (`GET /models/tasks/<id>`), and free-space refusal (`size * 1.05 > free`). The Hugging Face token: **disabled while the setup
AP is the transport** (HTTP on a shared-key network); the AP page offers public, ungated models only and says why. Enabled on
loopback or on the LAN over HTTPS; held in the kernel keyring, never in a URL, argv, environment of a child, log, job file or error
text; a redaction filter and `LogFilterPatterns=~hf_[A-Za-z0-9]+` back that up and a canary test greps every file, the journal and the
process table.

### 4.7 Input handling in the new code (`validators.py`)

One validator module for the API, the provisioning file and the CLI, with IEEE 802.11 and the kernel as the spec: SSID 1-32 **bytes** of
UTF-8 without control, line-separator or direction-control characters and no invisible character at either end; passphrase 8-63
printable ASCII or exactly 64 hex digits; interface names 1-15 characters of `A-Za-z0-9_.-`; hostnames per RFC 1123; IPv4 parsed by
hand (decimal only, no leading zeros: the standard library's `ipaddress` accepted them before 3.9.5 and 3.8.12, where they can read as octal); subnets aligned and RFC 1918;
JSON with a size cap, no duplicate keys, no `NaN`, no number over 30 characters, bounded nesting. Pitfalls closed on purpose: no
`$` anchor (it matches before a trailing newline), no `\d` or `str.isdigit()` (they accept non-ASCII digits), no `len()` for byte
limits, no `str.lower()` before an ASCII check (the Kelvin sign lowers to `k`). Error messages never contain the rejected value.
Nothing is built by string formatting: `nmcli` argv or D-Bus properties only; `con-name` is `ci-setup-<uuid>`, not the SSID, so profile
names never collide with other profiles (closes S4 and I5).

### 4.8 Packaging: where code lives and what changes per backend

Code stays in `core/headless/payload/` (shared by every backend; security-sensitive). Today `ci_setup/` sits next to it, as a package
with no dependency on the payload; the later layout puts it at `opt/setup-backend/ci_setup/`, with the templates at
`ci_setup/templates/`. A new payload file needs an entry in each backend's explicit file list (`REQUIRED_FILES` in the Ubuntu
`build.sh`, the required list in the Arch `install.sh`, a `rule()` line in the CachyOS
`stage-headless.sh` and its parity test). Python 3.8 or newer is required (the Ubuntu 20.04 floor); no third-party package.

| Backend | Changes for the redesign (steward rule: explicit file lists) |
|---|---|
| Ubuntu `.deb` | `Depends`: drop `nginx-light` and `dnsmasq`, add `iw, nftables, iproute2, rfkill`, `Recommends: qrencode, avahi-daemon`; `postinst` enables only `ci-setup-agent`, no `/etc/hosts` edit; `build.sh` file lists |
| Ubuntu ISO | replace the five `10-not-live.conf` drop-ins by the policy file; `verify-iso.sh` section 3 must change in the same commit (the layer-split work owns that file now) |
| Arch | `install.sh`: dependency list adds `iw nftables iproute rfkill` (and `qrencode`), drops `nginx`; stop enabling the AP units; fix the misleading log lines |
| CachyOS | `packages_online.conf`: remove `nginx`, add `nftables`, `qrencode`; `stage-headless.sh` rules for the new paths; the live ISO needs `hostapd`, `python-flask`, `gunicorn` for headless live mode |
| Retired backends | none: removed 2026-10-17, restore from the tag `pre-retire-multidistro-2026-10-17` |
| Stick | `grub.cfg.in` + `bootcfg.rs` entry `Companion OS (headless setup)` with `ci.headless=1`; optional `ci-stick wifi add`; a per-stick setup key written at flash time |

## 5. Decisions

Made before this work and not reopened (listed so a disagreement has somewhere to go): hotspot-by-default on machines with a
display is **off**; claimed devices never open the AP by themselves; the stop-gap comes before any authentication redesign inside
the shared payload; the new design is a separate tested library first; dropping `nginx`, the agent/portal split and the headless boot
entry are later phases. For models: HTTP stack `ureq` behind a Transport trait, a canonical `core/manifest/model-packs.lock.json`,
one content-addressed store on exFAT, Hugging Face v1 limited to single-file ungated GGUF with `HF_TOKEN` from the environment only,
refusal of licence `unverified` without `--accept-licenses`, background prefetch off.

| # | Decision | Default chosen | Where it is enforced |
|---|---|---|---|
| 1 | Hotspot on machines with a screen | only headless (no connected display, no graphical session) | `policy.decide` |
| 2 | Open vs password AP | WPA2-CCMP with a per-session random key and a separate PIN; SAE transition off | `apcfg`, `auth` |
| 3 | Where credentials are shown | console + QR, label, provisioning file, SSH, in that precedence; refuse to open an AP when none is available | `policy.credential_channel` |
| 4 | Per-stick or per-unit labels | sticker key burned at the first claim; Sticks get a key at flash time | `auth.derive_credentials` (the burn is the agent's) |
| 5 | Drop `nginx` for a socket-activated listener plus an nft redirect | drop (later phase) | `fw`, `captive` |
| 6 | A claimed device that loses Wi-Fi | lockdown; recovery is explicit | `policy` |
| 7 | Hugging Face token on the setup AP | refuse | section 4.6 |
| 8 | Default regdom when unknown | world-safe: channels 1-11, no 5 GHz, no DFS | `regdom` |
| 9 | Connectivity test | NM check + Portal HTTPS, no Google | agent (later) |
| 10 | Claiming from a live session | defer unless the Stick gets its own identity | open: needs a product call |
| 11 | Pin `8.8.8.8 1.1.1.1` into the Wi-Fi profile | remove | agent (later) |
| 12 | Enterprise (802.1X) and hidden networks in v1 | hidden yes, enterprise no | `validators.JOINABLE_SECURITY` |
| 13 | Persist the joined network on the Stick | yes if persistence is in use, and say so | agent (later) |
| 14 | Provisioning file holds a PMK or the passphrase | PMK by default, passphrase only for SAE-only, with a warning | `validate_provisioning_doc` |

Choices made while building the library that the audit left open: the 60 s grace applies to an unclaimed install as well as a Stick; an
unknown display state blocks the automatic AP; the allow-list of the read-only runner is exact argument vectors; the country file is read
from `/etc/setup-device` first (where the stop-gap reads it) and `/var/lib/setup-device` second; channels 12 and 13 are considered only for
a short list of countries (EU/EFTA, UK, AU, NZ, JP, KR, CN, IN, SG, HK, ZA, BR, TR) and everything else counts as 1-11.

## 6. The library: `core/headless/ci_setup/`

Python 3.8 or newer, standard library only, **no side effects on import** (checked with an audit hook), **no root**, no service wiring.
Time comes from an injected monotonic clock (`clock.py`), randomness from an injectable source that defaults to `secrets`, commands
from an injectable runner, files from an injectable read-only view. Run it from `core/headless`:

```
python3 -m ci_setup probe  [--fixtures DIR] [--country XX] [--no-scan]    # read iw/nmcli/rfkill/ip, choose a radio, print JSON
python3 -m ci_setup policy [--matrix [--table]] [--auto] [--context ... --display ... --network ...] [--trigger cli]
python3 -m ci_setup render hostapd|dnsmasq|nft|nft-teardown|all [--example | --key-stdin] [--iface wlan0] [--subnet 192.168.99.0/24]
python3 -m ci_setup selftest                                               # built-in vectors, no test files needed
```

### 6.1 Modules

| Module | What it does |
|---|---|
| `ci_setup/validators.py` | SSID (bytes, controls, bidi, edges), passphrase, hostname, country, MAC, PIN, ids, port, channel, interface and phy names, strict IPv4 and CIDR, `loads_strict`, `validate_wifi_join_request`, `validate_provisioning_doc` |
| `ci_setup/errors.py`, `ci_setup/clock.py` | `ValidationError` (never echoes the value), `SystemClock`, `ManualClock`; `WallClock` and `ManualWallClock` for an absolute expiry that a signer chose (section 6.6) |
| `ci_setup/parsers/iw.py` | `iw dev`, `iw phy info` / `iw list` (modes, frequency flags, interface combinations, `concurrent_ap_sta`), `iw reg get`, `iw scan dump` (security classification, hidden, strongest per SSID, survey, country votes), `iw link`, `iw station dump` |
| `ci_setup/parsers/nmcli.py` | terse tabular (escaped colons, dropped forged rows), multiline, device state with detail, connection list with TYPE, Wi-Fi list, connectivity, general status |
| `ci_setup/parsers/rfkill.py`, `ipjson.py`, `supplicant.py`, `common.py` | `rfkill list` and `-J`; `ip -j` link/addr/route, uplink, used networks; `wpa_cli` and `hostapd_cli` status, `all_sta`, control-socket events; SSID decoding, band and channel arithmetic, bounded line reader |
| `ci_setup/sysinfo.py` | kernel command line, DRM display state, bus and driver of an interface, claim state, `zone.tab` |
| `ci_setup/regdom.py` | ISO country table, `resolve_country`, `plan_channel` (never DFS, never 5 GHz without a country, follow-the-uplink) |
| `ci_setup/probe.py`, `runners.py`, `fs.py` | `run_probe`, `select_radio`; subprocess, fixture and **read-only** runners (exact allow-list); real and dictionary file-system views |
| `ci_setup/policy.py` | the table of 4.3, `decide`, `iter_matrix`, `matrix_table` |
| `ci_setup/auth.py` | AP key, PIN, setup key and its derivation, `consteq`, `TokenIssuer`, `AttemptLimiter`, `PinGate` |
| `ci_setup/wifi_qr.py`, `ci_setup/qr.py` | the `WIFI:` payload and its parser; a QR encoder (byte mode, versions 1-10, levels L/M/Q/H) with black-on-white console rendering |
| `ci_setup/captive.py` | the nine probe URLs in pending and done states, host and target routing, header safety |
| `ci_setup/jobs.py` | the setup job state machine with timeouts, cancellation, snapshots |
| `ci_setup/statement.py` | operation-bound owner statements (section 6.6): `canonical_json`, `params_hash`, `Expected`, `verify_statement` with an injected signature check, `new_request_id`; library only, not wired into any service |
| `ci_setup/replay.py` | the replay guard (section 6.6): `ReplayGuard` over a backend interface, `MemoryBackend` with crash injection; library only, not wired into any service |
| `ci_setup/apcfg.py`, `fw.py`, `templating.py`, `privfile.py`, `templates/*.in` | hostapd and dnsmasq renderers, AP subnet picker, the nftables ruleset and teardown, strict templating with a lint, 0600-from-the-first-byte file writer |
| `ci_setup/cli.py`, `selftest.py`, `__main__.py` | the command line above and the built-in self-test |

### 6.2 What the probe reports

`probe` prints one JSON document: `commands` (what ran, return code, missing, timed out), `interfaces` (with bus and driver), `phys` (modes,
bands, usable / DFS / passive-only channels per band, combinations, whether AP and station can run together), `regdom`, `rfkill`, `ip`
(links, addresses, routes, the uplink, networks already in use), `network_manager`, `wifi_links`, `scan` (count, country votes, 2.4 GHz
survey, the strongest BSS per visible SSID), `country` (code, source, confidence, self-managed), `radio` (mode, AP and station interface,
`follow_uplink_mhz`, notes), `channel_plan`, and `system` (display, live, stick, claimed, timezone). Every command goes through
`ReadOnlyRunner`, so a test can state that the CLI only reads. `--fixtures DIR` answers from recorded text and never looks at the
machine it runs on. Six whole-probe scenarios are pinned by golden files: one radio offline, two radios with the uplink on the first, a
chip without AP mode, a hard-blocked radio, one USB radio holding the uplink on a single channel, and no Wi-Fi at all.

### 6.3 Credentials, tokens, limits

12-character AP key from the 31-symbol alphabet; 6-digit PIN; setup key (16 symbols, `ABCD-EFGH-JKMN-PQRS`) from which the AP key, PIN and
SSID suffix derive by `HMAC-SHA256(setup_key, label || 0x00 || counter)` with rejection sampling (no modulo bias; a known-answer test
pins the construction). Tokens are `v1.<session id>.<issued ms>.<expires ms>.<HMAC>`, the MAC over those fields **and the client address**,
so a token used from another address, or altered in any field, fails; sliding refresh capped at issue time plus 45 minutes; revocation.
`AttemptLimiter`: back-off 1, 2, 4 ... capped at 30 s; a client is locked out for 5 minutes after 3 failures; after 5 failures overall the PIN
rotates, so **no PIN generation is ever tested more than five times** (a test drives 3000 attempts from thousands of addresses and counts);
one address gets about three guesses per five minutes (a test counts over an hour); tracked state is bounded at 64 clients; the snapshot has
counters only. Every comparison of a secret goes through `consteq` (`hmac.compare_digest`; a test patches it to prove it is the function used).

### 6.4 Renderers

hostapd: the SSID is written `ssid2=<hex of the UTF-8 bytes>` (documented form), `ap_isolate=1`, `rsn_pairwise=CCMP` only, `max_num_sta=4`,
a control socket for station events, `country_code` and `ieee80211d` only when the country is known, `wpa_passphrase=` or `wpa_psk=`
for a raw key. dnsmasq: `-C` with one file, `bind-interfaces`, `no-resolv`, `no-hosts`, DHCP `.10` to `.250` for 2 hours, router and DNS set to
the AP, `address=/#/<AP>`, **no query log**. Template values are validated typed parameters; substitution is one pass; no value may contain a
line break; the finished text is linted line by line; the template names are a whitelist. Golden files pin the exact output. The hostapd
file for a known country (`golden/hostapd_de_2g.conf`; the passphrase is the example `ABCDEFGHJKMN`) and the firewall for `wlan0` at
`192.168.99.1` (`golden/ci_setup.nft`, which also begins with the four idempotence lines of 4.4):

```
# Generated by ci_setup. Do not edit. This file holds the AP key: write it mode 0600 and only under /run.
interface=wlan0
driver=nl80211
ctrl_interface=/run/ci-setup/hostapd-ctrl
ctrl_interface_group=0
ssid2=436f6d70616e696f6e2d53657475702d41423132
utf8_ssid=1
country_code=DE
ieee80211d=1
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=ABCDEFGHJKMN
ap_isolate=1
max_num_sta=4
macaddr_acl=0
ignore_broadcast_ssid=0
dtim_period=2
disassoc_low_ack=1
```

```
table inet ci_setup {
  # prerouting at priority raw runs before connection tracking and before Docker's DNAT (dstnat, -100), so a
  # container port published on 0.0.0.0 cannot be reached from the access point.
  chain raw_in {
    type filter hook prerouting priority raw; policy accept;
    iifname "wlan0" udp sport 68 udp dport 67 accept
    iifname "wlan0" ip saddr 192.168.99.0/24 udp dport 53 accept
    iifname "wlan0" ip saddr 192.168.99.0/24 tcp dport { 53, 80 } accept
    iifname "wlan0" ip saddr 192.168.99.0/24 ip daddr 192.168.99.1 tcp dport 8080 accept
    iifname "wlan0" ip saddr 192.168.99.0/24 ip daddr 224.0.0.251 udp dport 5353 accept
    iifname "wlan0" ip saddr 192.168.99.0/24 ip daddr 192.168.99.1 icmp type echo-request limit rate 5/second accept
    iifname "wlan0" drop
  }
  # nothing from the access point is routed anywhere, and nothing is routed to it
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "wlan0" drop
    oifname "wlan0" drop
  }
}

table ip ci_setup_nat {
  chain pre {
    type nat hook prerouting priority dstnat - 5; policy accept;
    iifname "wlan0" udp dport 53 redirect to :53
    iifname "wlan0" tcp dport 53 redirect to :53
    iifname "wlan0" tcp dport 80 redirect to :8080
  }
}
```

### 6.5 Known limits of the library

* Parsers are written from the output formats in the tools' sources and manuals; **no fixture of `iw` or `rfkill` output was captured from
  hardware** (section 9.2). The `ip -j` fixtures and `zone.tab` are real captures. Real-chip output must be added under
  `fixtures/real/` when someone has hardware; `MANIFEST.json` makes the provenance of every fixture explicit.
* The state machines and renderers have no runtime behind them yet: `jobs.py` emits effects for an agent that does not exist.
* Interface selection by bus order and the channel-load weights are reasonable defaults, not measured.
* The QR encoder is verified by a second decoder and by CoreImage; it has not been scanned from a screen with a phone camera.
* `nmcli` SSIDs are untrusted display text. A newline inside an SSID can forge a row with the right field count; use `iw scan dump`
  (which escapes) for anything that is acted on.
* The owner-statement library has no signature scheme, no on-disk replay store and no caller (section 6.6).

### 6.6 Operation-bound owner statements and the replay guard (library only)

`statement.py`, `replay.py` and the wall clocks of `clock.py` are a library for the setup-service redesign (known issue KI-02) and the
identity daemon. **They are not wired into any service**: only the self-test and the tests import them [V: `git grep` over `core`,
`backends` and `stick`, 2026-10-30]. No signature scheme ships with them: the check is an object that the caller injects, and the tests use
an HMAC stand-in labelled test-only [V: `helpers.py`]. The library decides whether the owner approved exactly this operation, on exactly
this target, with exactly these parameters, once.

A statement has exactly seven members, and any other member is refused: `v` (the integer 1), `type` (1 to 32 characters of `a-z 0-9 . _ -`,
from the caller's allow-list), `request_id` (32 lowercase hex digits, 128 random bits, the key of the replay guard), `scope` (1 to 128
printable ASCII characters, what the verifier expects for itself), `target` (1 to 128 printable ASCII characters, what the caller is about
to act on), `params_hash` (SHA-256 of the canonical JSON of the parameters about to be applied) and `expires_at` (whole seconds since the
epoch). The statement is canonical JSON: members sorted by key, no space, ASCII only (other characters as `\u` escapes in lower case), integers
up to 2^53 - 1, no floats, nesting at most 8 deep, at most 2048 bytes. A received statement is accepted only if its bytes equal the canonical
encoding of what they parse to. The signature covers the bytes `ci-os-statement/1`, a newline and then those bytes, and the injected check is
called with the namespace `ci-os-statement@ci.computer`, so a login proof and an operation statement can never stand in for each other
[V: `test_statement.py`]. Known answers for other languages are in `fixtures/statements/vectors.json`; an independent JavaScript
implementation, run once and not kept, reproduced all 38 byte strings and hashes in it [V, 2026-10-30].

`verify_statement` runs these steps in this order, and the first failure ends it with an error whose `code` names the step. The text of the
error is constant: it never contains the statement, the target, the scope, the id or the parameters [V: `test_statement.py`].

| Step | Code | Refused when |
|---|---|---|
| 1 | `size`, `encoding`, `format` | more than 2048 bytes; a byte above 0x7F; not a JSON object, a duplicate member, NaN, a number of more than 30 characters |
| 2 | `noncanonical` | the bytes differ from the canonical encoding of what they parse to |
| 3 | `signature` | the injected check says no or raises, or the signature is not 1 to 1024 bytes |
| 4 | `version`, `field` | `v` is an integer other than 1; the members are not exactly the seven, or one has the wrong type or shape |
| 5 | `type`, `scope`, `target`, `params` | the statement is for another operation, scope, target or parameter set (the hash is compared with `consteq`) |
| 6 | `expired`, `ttl` | `now >= expires_at`; `expires_at - now > max_ttl_s + skew_s`, which is also the defence against a clock far behind |
| 7 | `clock` | the clock reading is not a whole number of seconds, or it is behind the replay floor by more than `skew_s` |
| 8 | `replayed`, `store`, `store_full` | the request id is already consumed; the store failed; the store is full |

Nothing unauthenticated has an effect: the signature is checked on the exact bytes before any member is given a meaning, and a statement that
fails a step before the last one does not consume its id, so a valid statement presented with the wrong parameters cannot be burned
[V: `test_statement.py`, planted defects `stmt-*` and `canon-*`]. On success the caller gets a frozen record and then acts; if the action
fails it needs a new statement (at most once).

The replay guard keeps one marker per consumed id, named `<expiry as 12 digits>-<sha256 of the id>`, and one number, the clock floor. Its rules
each have a test and a planted defect [V: `test_replay.py`, `replay-*`, on the in-memory backend]:

* The claim is durable before the operation runs: `claim` returns only after the marker and then the floor have been written. A crash
  before the marker exists leaves the id untouched; after that it is consumed.
* A marker is found by the hash in its name, so any name ending in `-<hash>` means consumed, whatever its expiry digits or its body. A damaged
  marker stays consumed: existence is the signal and the body is never read for the decision.
* The floor is raised to `now` only when a statement is accepted, so only the holder of the signing key can move it. A claim with
  `now < floor - skew_s` fails with `clock`. The floor file is decimal digits and a final newline; a file without the newline has been cut
  short, and it is damaged, never read as a smaller floor.
* A marker is purged only when `expiry + skew_s + max_ttl_s < floor`, using the persisted floor and never the current clock, so a clock that
  later jumps backwards cannot bring back a statement whose marker is gone. At most 4096 markers: the guard purges first, then refuses with
  `store_full`.

Not covered, and for the reviewer to decide [N unless marked otherwise]:

* The durable steps (create, write, flush the file, flush the directory) are modelled in memory and the tests stop the sequence at each one
  [V]. The on-disk store, the flush order on a real file system and a claim from several processes are the next change.
* Defaults: `max_ttl_s` 600 and `skew_s` 120, with ceilings of 86400 and 3600 that `Expected` enforces [V: `test_statement.py`]. Which values
  to ship, which signature scheme to inject first and where the store lives are open.
* A damaged floor makes the guard fail closed with `store` and repair nothing, and a lost store is not handled; the rules for both are open.
* The floor moves only when a statement is accepted and a marker goes only by the floor, so a store that fills inside one lifetime stays full
  until a statement can be accepted [V: `test_replay.py`]. Whether to accept that is open.
* The floor notices a clock that goes back past the latest accepted statement, not one set back to a time after it, which is why the life of
  a statement is short by default [V: `test_statement.py`]. Any expiry judged by a wall clock alone has this limit.
* The purge slack is `max_ttl_s`: a later policy with a `skew_s` larger than the earlier `skew_s + max_ttl_s` could accept a statement whose
  marker was purged, so the policy values should be constants of the caller.

Run the self-test with `cd core/headless && python3 -m ci_setup selftest`, and the tests with `bash core/headless/tests/ci_setup/run.sh --quick`.

## 7. Phased plan

Effort in engineer-days (S <= 1, M 2-4, L 5+); estimates, not measurements.

| Phase | Work package | Owns (disjoint paths) | Tests | Needs first | Effort | State |
|---|---|---|---|---|---|---|
| P0 | WP-A stop-gap | `setup_service.py`, start script, monitor, reset, nginx file, pre-scan, `systemd/system/*.service` | the payload tests of that work | nothing | M (3) | working tree |
| P0 | WP-B backend enablement | `backends/*/headless-*`, `DEBIAN/*`, `install.sh`, `stage-headless.sh`, Ubuntu `customize-chroot.sh` and `verify-iso.sh` section 3 | `installer-stage.sh`, `verify-iso.sh`, installed-boot probe | the layer-split commit of `verify-iso.sh` | S-M (2) | partly in the working tree |
| P1 | WP-C core library | `ci_setup/**`, templates, fixtures | section 9 | nothing | L (6) | **done** |
| P1 | WP-G test infrastructure | `core/headless/tests/{stubs,hwsim}/`, a manual-only workflow | L1, L4 scaffold | a 1-day spike: does the CI host kernel have the module | M (4) | section 9.5 |
| P2 | WP-D AP runtime | `agent`, units, target, `ci-setup`, sandbox settings | L1, L3, L4 | WP-C | L (7) | not started |
| P2 | WP-E portal v2 | `api`, `var/www/setup-portal/*`, CSP split | L2, L4 | WP-C | L (5) | not started |
| P2 | WP-F console and names | banner, issue file, Avahi, desktop notification | L1, L4 (serial marker) | WP-D | S-M (3) | not started |
| P3 | WP-H Stick integration | `grub.cfg.in`, `bootcfg.rs`, optional `ci-stick wifi`, flash-time setup key, provisioning unit | `cargo test`, `stick/tests/qemu/run.sh`, L5 | WP-D, populating `CI-SHARED` | L (5) | not started |
| P3 | WP-I installer hand-off | `ci-os-auto-install`, CachyOS `ci-os-stage-target.sh` | `test_auto_install.py`, `installer-stage.sh` | the one-click-install owners | M (3) | not started |
| P4 | WP-J models page | `models_proxy`, portal page | L2 plus a fake models service | report 03 contract | M (4) | not started |
| P4 | concurrent AP+STA, WPA-Enterprise, SAE transition, RFC 8910 | agent, probe | L4 with `channels=2` | WP-D, real-chip data | L | not started |

Order: P0 (A and B in parallel; B waits for the layer-split commit) -> P1 (C and G in parallel) -> P2 (D, then E and F) -> P3 -> P4. P0
alone does not close S1 and S2 (they need the credential channel of P2). About 35-45 engineer-days in total.

What WP-D has to do with this library: call `probe.run_probe` and `select_radio`; call `policy.decide` on every change of facts;
render with `apcfg` and write with `privfile.write_private_file`; load `fw.render_nft`; drive a `jobs.Job` with the events of hostapd
(`parsers.supplicant.parse_ctrl_event`) and the portal, and carry out its effects; hand the portal a `PinGate`; and add the pieces the
library deliberately lacks: the D-Bus or keyfile `nmctl` that changes NetworkManager, the units, the console banner, the burn of the
setup key at the first claim, and the host-firewall opening of the AP interface.

## 8. Test strategy

Layers, cheapest first. "Needs" is what the layer requires; the first two run on any laptop and in the PR checks.

| Layer | What | Needs | State |
|---|---|---|---|
| L0 pure logic | validators, parsers, regdom, policy, tokens and limits, captive answers, job machine, renderers, QR | python3 only | **built** (section 9.1) |
| L1 stubs on PATH | fake `nmcli`, `iw`, `ip`, `systemctl`, `hostapd_cli`, `nft`, `rfkill`, `docker` driving the bash that remains and the agent end to end (no radio, AP start failing halfway, two simultaneous starts, malformed body) | bash, python3 | not built (the library's `FixtureRunner` is the Python half) |
| L2 web | Flask `test_client` against the app factory: auth on every state-changing route, Origin/Host/Content-Type rejects, lockout, body limits, CSP, probe URLs in both states, no secrets in responses or logs | `python3-flask` | not built (WP-E) |
| L3 units | `systemd-analyze verify` on all units; `systemd-analyze security --offline` with a threshold; no `Restart=` without `StartLimit*`; `ExecStopPost` on the AP units | systemd in a container | not built |
| L4 hwsim | `modprobe mac80211_hwsim radios=4`: radio0 the AP (real hostapd, dnsmasq, nft, portal), radio1 a "phone" in a network namespace, radio2 a "home router", radio3 spare | privileged Linux container or QEMU guest | section 9.5 |
| L5 the real kernel | the L4 script in a QEMU guest that boots the ISO's own kernel and modules | QEMU | not built |
| L6 phones and chips | the manual checklist of Appendix A | people, hardware | not run |

Scenarios the hwsim layer must cover (from the audit): the AP comes up in under 10 s and a station joins with the right key and not the
wrong one; client isolation; DHCP and DNS catch-all (A only); the firewall from a phone namespace (22, 5002, 11434, the LAN address
dropped; 8080 and 80 answer; DHCP works); captive probes with the user agents of an iOS sheet, Android and Windows, pending and done;
auth (no token 401, wrong Origin 403, form body 415, six wrong PINs 429 and a new PIN, malformed JSON 400 with the hostapd PID
unchanged, `Wired connection 1` as SSID deletes nothing); join to a "home router" radio (WPA2, SAE-only, hidden, wrong password with
rollback, no DHCP, upstream portal); every exit path leaves no address, a managed radio, no `ci_setup*` tables, nothing in `/run/ci-setup`
but `state.json`, and a dummy `traefik` container still running; `channels=1` vs `channels=2` and `virt_wifi` as "no AP mode";
regdom plumbing with fixtures (hwsim lets any channel be used, so enforcement is not simulated); secret hygiene with canaries over
`journalctl`, `/run`, `/var`, `/etc`, `ps -eo args` and the HTTP access log; the Stick boot path printing `CI-SETUP state=ap_up` on the
serial console.

Stays untested without hardware: real chips' interface combinations and AP+STA limits, DFS/CAC timing, firmware-enforced regulatory
limits, power save and suspend, the phones' captive-sheet behaviour, radio coexistence. They go on the L6 checklist, and the probe
logs the raw `iw phy info` into its report so field results become new fixtures.

## 9. What exists today and what was run

### 9.1 L0: the unit suites (`core/headless/tests/ci_setup/`)

`./run.sh` (bash 3.2, python3 standard library, exit 2 = cannot run) does `py_compile` of the package and the tests into a temporary
directory, the unittest suites below, `python3 -m ci_setup selftest`, and the mutation check. `--quick` uses small fuzz sizes and skips the
mutation check; `--pythons "a b"` runs the suites under several interpreters.

| Suite | Covers |
|---|---|
| `test_validators.py`, `test_fuzz_validators.py` | every validator on boundaries and known-bad input; **200 000 seeded cases** for SSID and passphrase against an independently written oracle, and tens of thousands each for the rest; errors never echo the input |
| `test_parsers_iw.py`, `test_parsers_misc.py`, `test_fuzz_parsers.py` | the fixtures, dozens of edge cases, a seeded fuzz of 28 parsers (mutated fixtures and garbage: never raise, JSON-serialisable) and pathological input (60 000-character lines, deep JSON) that must stay under a CPU budget |
| `test_regdom.py` | the ISO table, every precedence rule, never DFS, 5 GHz only with a known country, follow-the-uplink, a seeded property test over random frequency tables |
| `test_probe.py` | radio selection scenarios, six whole-probe goldens, the read-only runner (allowed and refused vectors, no state-changing verb), file-system views |
| `test_policy.py` | the 144-row matrix as properties (claimed, display, network, plain media, explicit triggers, credential channel) and as golden files |
| `test_auth.py` | alphabet, entropy, distribution, `secrets` is the default source, derivation (reference construction and known answer), tokens (binding, every field protected, expiry boundary, sliding cap, revocation, garbage), limiter, PIN gate, brute-force budgets, threads |
| `test_wifi_qr.py`, `test_qr.py` | escaping (the ZXing example), round trips, injection; the encoder against published constants and an independent decoder for **every version, level and mask** (over a thousand symbols) |
| `test_captive.py` | the nine URLs in both states, `Content-Length` rules, HEAD, routing by host, header-injection fuzz |
| `test_jobs.py` | happy path, every failure path, cancellation from every active state, every timeout, an exhaustive (state, event) matrix, snapshot and restore in every state, random event sequences |
| `test_render.py` | goldens for hostapd (three variants), dnsmasq (two), nft (two) and the teardown; injection attempts through every parameter; the template engine and lint; the subnet picker with a real capture; the private-file writer (mode 0600 from creation, umask, symlink, failure cleanup) |
| `test_cli.py` | all four commands, injected runner and file system, refusals, exit codes, the key never on the command line |
| `test_statement.py` | the canonical encoding and the known answers in `fixtures/statements/vectors.json`, every structural refusal with its code, the signer-side `canonical_statement`, the signature step (each member tampered, another namespace, the length bounds), the binding to type, scope, target and parameters, the expiry and lifetime boundaries, the clock floor, the result record (which type it names), error text that never echoes a value, the self-test vectors |
| `test_replay.py` | single use across a restart, damaged markers that stay consumed, the same id with another expiry, the floor rules, purging by the persisted floor, the bound, crash injection at every durable step, backend failures, the order of the backend calls, threads |
| `test_fuzz_statements.py` | seeded mutations of a signed statement (never accepted under the old signature, only the module's error escapes), re-signed mutations against an independent oracle, random input of every shape, random clock readings and policies against a plain model, random claims against a dictionary model |
| `test_hygiene.py` | no side effects on import (audit hook), nothing asks for root, Python 3.8 syntax and API on the AST, no unused imports, executable bits, no block art or retired product names, every fixture listed in `MANIFEST.json` with an honest origin |

### 9.2 Fixtures

`fixtures/MANIFEST.json` lists 57 files with their origin (the six probe scenarios under `fixtures/scenarios/` are compositions of them). **Captured (real):** the four `ip -j` outputs (iproute2-7.2.0, in a throwaway
container with dummy interfaces) and an excerpt of the tz database `zone.tab`. **Synthetic:** everything else, written by hand or by a
throwaway script from the formats in the tools' sources and manuals (`iw`'s `interface.c`, `info.c`, `reg.c`, `scan.c`, `link.c`,
`station.c`; `nmcli-utils.c`, `nmcli-common2.c`, `nmcli-devices.c`; the `rfkill`, `wpa_cli` and `hostapd_cli` formats from memory).
A synthetic fixture proves that the parser reads the documented format, not that a particular chip prints it. `statements/vectors.json` is synthetic in another way: it holds known answers for the owner-statement encoding (section 6.6) that the Portal and a phone must reproduce byte for byte. The `iw phy info`
examples are chip-shaped (dual band with 6 GHz and two channels, a USB dongle limited to one channel, a station-only chip, a world
domain) and are not captures of any real chip.

### 9.3 Checks against real tools (opt-in, not part of `run.sh`)

* `nft_check.sh` (`CI_SETUP_DOCKER=1`; a container with `nft`, `ip` and python3): `nft -c`, `nft -f`, the same again, the teardown twice,
  and a **packet test** (`nft_packets.py`) with a veth pair and a network namespace standing in for a phone. Result on nftables v1.1.7
  in the Docker Desktop Linux kernel: before the rules every listener answers; with them the portal on 8080, port 80 and any
  destination's port 80 (redirected), and DNS to the AP and to 8.8.8.8 (redirected) answer, DHCP from port 68 reaches dnsmasq's port and
  a datagram from port 1234 does not, while ports 22, 5002, 11434 and 8000 on the AP address and a listener on the container's other
  address time out (dropped, not refused); after the teardown everything answers again, which proves the rules did the blocking.
  **Caveat, stated plainly:** those results were obtained on the ruleset *before* the source-address restriction was added (every accept
  except DHCP now also requires `ip saddr` inside the AP subnet, so a client that picks another source address gets nothing). After that
  change the container runtime stopped answering on this machine (load average 180 to 430), so `nft -c`, `nft -f` and the packet test
  have **not** been re-run against the current template. What does cover the change: the rendered ruleset is a golden file, a unit test
  asserts that every accept except DHCP carries `ip saddr` and an AP-interface match, and the mutant `nft-no-source-check` (the
  source match removed from one accept) is killed. `nft_packets.py` already contains the matching probe (a connection to the portal
  from a spoofed source, expected to time out, and expected to succeed before the rules and after the teardown); run
  `CI_SETUP_DOCKER=1 bash core/headless/tests/ci_setup/nft_check.sh` once a container runtime is available, and treat the first
  result as the one that counts.
* `qr_check_macos.sh` (`CI_SETUP_MACOS_QR=1`, macOS with `swiftc`): renders 102 PNG images (every version 1-10 at every level, full and
  half capacity, all 8 masks, the AP code, escaped and UTF-8 text) and has CoreImage's QR detector read them: **102 of 102 read back
  correctly**.

### 9.4 Mutation check (`mutation_check.py`)

161 deliberate bugs in the security-relevant code (a comparison weakened to `==`, a check removed, an escape dropped, a lockout or
rotation disabled, a table value changed, the nft hook moved from `raw` to `filter`, the file mode widened ...). Each is applied to a copy
of the package, the covering tests run, and the mutant must be killed. Every `old` text must occur exactly once, so a refactor cannot turn
a mutant into a no-op. The first run killed 112 of 115 and exposed three gaps that were closed: a redundant port check (removed, the
validator already refuses it), an idle-timeout clock that a client could restart by coming and going (test added), and a read-only
allow-list mutant that was unreachable (rewritten to target the reachable branch). The last 32 (`stmt-*`, `canon-*`, `replay-*`) plant a
defect in the owner-statement verifier or the replay guard: a check skipped or reordered, an off-by-one at an expiry, a damaged marker read
as absent, a purge by the clock instead of the floor, the floor written before the marker, a floor file cut short read as a smaller floor,
a bound on the signature removed, a record that names the wrong type.

### 9.5 The hwsim harness and the other test directories

Two other pieces of test infrastructure sit next to this library's. Neither is part of `run.sh`.

* **`stick/tests/qemu/hotspot-hwsim.sh`** with `guest-hotspot-test.sh` and `README-hotspot.md` (WP-G, another agent; still being written when
  this was read). It boots a Companion OS ISO's own kernel in QEMU (TCG, no root, no network) and runs the **real** hostapd 2.10,
  wpa_supplicant 2.10, dnsmasq 2.91, nginx 1.24, gunicorn and `setup_service.py` against `mac80211_hwsim` radios, reporting
  `CI-HWSIM-TEST <name> <PASS|FAIL|XFAIL|XPASS|INFO|SKIP> <detail>` lines on the serial console. Scenarios: `chain` (AP up with a generated
  config, wrong key refused, WPA2 association, DHCP, catch-all DNS, portal, probe URLs, teardown and NetworkManager restored), `caps`
  (module parameters, AP-capable radios, `channels=1` versus `channels=2`, `virt_wifi` as a chip without AP mode, raw `iw` output saved),
  `veth` (the L3 stack without radios) and `legacy` (the current payload scripts judged against desired behaviour: `XFAIL` while a defect
  stands, `XPASS` once a stop-gap fix lands). Its spike found that the Docker Desktop Linux VM kernel has no wireless support at all, so
  `mac80211_hwsim` can only run in a QEMU guest on this Mac, and that the v7 Ubuntu ISO's 7.0.0-31 kernel ships the module. What I could see of
  it: development boots that reach the test script, find the tools (`iw` 6.7 among them) and the module, and show NetworkManager running.
  Its README still had placeholders for the baseline table and the timings, and I saw **no end-to-end `chain` result**, so none is
  claimed here. Note that the container used for `nft_check.sh` (9.3) is a different thing: netfilter works in that kernel, wireless does not.
* **`core/headless/tests/payload/`** (WP-A, another agent): bash and Python tests of the payload scripts and the backend (`run.sh`,
  `test_static.py`, `test_setup_service.py`, `test_hotspot_start.sh`, `test_monitor.sh`, `test_prescan.py`) with stand-ins for flask
  and flock.

How they meet this library: once the `caps` scenario has run, its `art/iw-*.txt` (real output of `iw` 6.7 on real mac80211 code with
virtual radios) should be copied to `fixtures/real/` and listed as captured in `MANIFEST.json`, and the parser tests extended to
them; the `legacy` baseline becomes a regression test when the stop-gap lands (`--strict-legacy`); and the L4 scenarios of section 8 that
need the agent (firewall from a phone namespace, auth, join with rollback) belong in the same harness once WP-D exists. The library's
`FixtureRunner` is the Python-side counterpart of the harness's stubs.

### 9.6 Bugs and design corrections found while building and testing the library

* The audit's nftables sketch used `chain fwd`: **real nftables rejects it** (`fwd` is a statement keyword). Found by loading the
  rendered ruleset into nftables v1.1.7; the chain is `forward`, and a test keeps chain names off the keyword list.
* `accept` in an nft base chain does not override another table's `drop` (4.4). Not a bug in the ruleset, a caveat for hosts with ufw.
* An `$`-anchored regular expression accepted `"/run/x\n"` as a path; fixed with `fullmatch`, and the same rule applied across the package.
* `render dnsmasq --subnet 8.8.8.0/24` was accepted (the AP subnet was validated as a /24 but not as private); now RFC 1918 only.
* The `ValidationError` text must not carry the value: a mutant that appended it was killed by a property test over thousands of secrets.
* Python before 3.11 parses a 60 000-digit JSON integer; `loads_strict` now refuses numbers over 30 characters on every version.
* A malformed `Host` or target cannot reach a response: header-injection fuzz over `captive.route` found nothing, and the test stays.
* `iw` prints an SSID's leading and trailing spaces as `\x20` and a backslash as `\x5c`; the decoder handles both and a round trip
  test covers all 256 byte values.
* A lone `\ud800` in a string is not encodable; every validator rejects it as `encoding` instead of raising from `str.encode`.
* The file-writing tool used to produce this change decoded `\uXXXX` sequences in source files into literal characters (bidi and
  zero-width controls among them). A script re-escaped them as `\UXXXXXXXX` and proved the syntax tree identical; a hygiene
  test now fails on any non-ASCII character in the package and the tests' strings that is not escaped.

## 10. Not verified, and open questions

* Real `iw`, `rfkill`, `nmcli`, `hostapd_cli` output from hardware: none captured [N].
* Captive-portal behaviour of current iOS, Android, Windows and macOS against the answers of `captive.py` [N] (Appendix A).
* Whether `hostapd` accepts every line of the rendered file: hostapd was not available; the form (`ssid2=<hex>`, `ap_isolate`, `rsn_pairwise`,
  `ctrl_interface_group`) is from the hostapd.conf reference [I]. The same for dnsmasq: `address=/#/IP` answering A only [I].
* The nft ruleset was loaded and exercised in a container kernel; the Ubuntu 7.0 and CachyOS kernels were not used [N].
* Python 3.8 itself was not available (nothing larger than a few megabytes was downloaded): 3.8 compatibility is checked on the AST for
  syntax, banned later APIs and runtime generics, and the suites ran on 3.9, 3.11, 3.12, 3.13 and 3.14 (section 9.1 table, evidence log).
* Decision 10 (claiming from a live session) needs a product call. Whether Calamares runs `networkcfg` in the CachyOS overlay is open.
* GitHub-hosted runners and `modprobe mac80211_hwsim`: unknown; the one-day spike decides the shape of L4 and L5.

## Appendix A. Manual checklist for phones and chips (L6)

Record the result next to the device model and OS version; add any real `iw phy <phy> info`, `iw reg get` and `iw dev <if> scan dump` output
to `fixtures/real/` with an entry in `MANIFEST.json`.

1. **iPhone (iOS 17 or newer).** Join the setup network by scanning the console QR code. Expected: the join prompt shows the SSID; after
   joining, the captive sheet opens on its own showing the portal; entering the PIN works; after setup the sheet closes (answer to
   `/hotspot-detect.html`); with the app in the background the phone does not announce "no internet" before the AP goes away.
2. **Android (current stable and one older version).** Scan the QR code from the camera and from Settings; expected: the "sign in to network"
   notification opens the portal (`/generate_204` redirect); after setup it disappears. Note whether Private DNS or a data-saver mode
   changes this. Open `http://companion-os.local/`; expected to fail on some browsers, so the on-screen IP URL must work.
3. **Windows 11.** Join by hand; expected: the browser opens the portal (`/connecttest.txt`, `/ncsi.txt`, `/redirect`); after setup the
   network icon stops showing "no internet" within a minute.
4. **macOS.** Join by hand; expected: the captive sheet opens; after setup it closes.
5. **Chips**: at least an Intel AX2xx, a MediaTek MT7921 or MT7925, and a Realtek USB dongle. For each: does `iw phy info` list AP, what
   are the `valid interface combinations` (AP+STA, `#channels`), which bands, is the regulatory domain self-managed, does hostapd start on
   the planned channel, and does the AP survive a join from a second radio (dedicated) or drop and return (sequential).
6. **Regulatory behaviour**: boot with `ci.country=XX` for two countries and with none; confirm the AP uses 2.4 GHz channels 1, 6 or 11
   only when the country is unknown and never a DFS channel on 5 GHz.
7. **Failure paths**: wrong Wi-Fi password (the old network returns, or the AP reappears with the same key and PIN), a router that is off,
   a captive upstream network, a hidden SSID, a WPA3-only network, an SSID with a space at the end and one with emoji.
8. **Lifecycle**: leave the AP idle for 15 minutes (the session must end and a new key and PIN must appear), cancel from the console, power
   the router on while the AP is up with no phone attached (the duty cycle must rejoin it), reboot mid-setup.

## Appendix B. Evidence log (what was run, 2026-10-17)

Everything below was run on one Mac (macOS, Apple silicon) with the repository's working tree, under `nice`. The machine was heavily
loaded by other jobs (load average 180 to 430), so wall-clock times are 5 to 20 times the CPU times and mean nothing; the CPU figures
are the ones to compare. Nothing here needed the network. Numbers are from the final runs after the last code change; earlier runs with
fewer tests are not quoted.

| What | Command | Result |
|---|---|---|
| Full suite on five interpreters, selftest, mutation check | `bash core/headless/tests/ci_setup/run.sh --pythons "python3 /usr/bin/python3 python3.11 python3.12 python3.13"` | exit 0. Python 3.14.7, 3.9.6, 3.11.14, 3.12.11, 3.13.11: **all OK** (the first two interpreters ran 469 tests and the last three 471, because two tests were added while the run was in progress; the quick run below has all 471). `selftest`: 12 of 12 checks. Mutation check: **129 of 129** mutants killed. About 136 s user CPU. |
| Quick suite under the system shell | `/bin/bash ./run.sh --quick` (bash 3.2.57, Python 3.14.7) | exit 0. **471 tests OK**, selftest 12 of 12, mutation check skipped by design. 9.5 s user CPU. |
| Syntax of every file | `py_compile` inside `run.sh` | 48 files compile. |
| Python 3.8 | AST checks in `test_hygiene.py` | Syntax and banned APIs only. **No 3.8 interpreter was run.** |
| Shell scripts | `shellcheck -S error run.sh nft_check.sh qr_check_macos.sh` | clean. |
| Repository rules | greps over the package, the tests and this document | no U+2588, no non-ASCII character in a source file that is not an escape, no retired product name, no `__pycache__` or `.pyc` left, the four executable files carry the executable bit. |
| nftables syntax and load | `nft -c`, `nft -f`, again, teardown twice, nftables v1.1.7 in a Linux container | passed **on the ruleset before the `ip saddr` change** (section 9.3). Not re-run since: the container runtime stopped answering. |
| Packet test | `nft_packets.py` in the same container | passed on that earlier ruleset (portal, port 80 redirect, DNS redirect, DHCP by port, everything else dropped, all reachable again after the teardown). **Not re-run on the current ruleset.** |
| QR encoder | `CI_SETUP_MACOS_QR=1 bash qr_check_macos.sh` (CoreImage detector) | 102 of 102 images read back correctly. |
| Probe on a real machine | `python3 -m ci_setup probe` on the Mac | exit 0, reported `no_wifi`; the probe degrades instead of failing on a machine without the Linux tools. |
| Files | `git status` on the owned paths | untracked and **not committed**: 167 files in the package and its tests, plus this document. |

What the evidence does **not** cover is listed in section 10: no real `iw`, `rfkill` or `nmcli` output from hardware, no real
`hostapd` or `dnsmasq` run, no phone, no Python 3.8, and no packet test of the current nft ruleset.
