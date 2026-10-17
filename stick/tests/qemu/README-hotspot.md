# Wi-Fi hotspot tests on virtual radios (`mac80211_hwsim`)

`hotspot-hwsim.sh` boots a Companion OS ISO in QEMU and runs the **real** `hostapd`, `wpa_supplicant`, `dnsmasq`, `nginx` and the
setup portal (`core/headless/payload/opt/setup-backend/setup_service.py` under `gunicorn`) against virtual Wi-Fi radios, with no
Wi-Fi hardware. It is the "L4/L5" layer (work package G) of the hotspot test plan: everything above the radio is the code that
ships, the kernel is the ISO's own 7.0 HWE kernel, and `cfg80211`, `mac80211` and `mac80211_hwsim` come from the ISO's own
`linux-modules` package.

```bash
# needs qemu-system-x86_64, tar, dd and bsdtar (or xorriso); no root, no network; nothing outside --work is written
nice stick/tests/qemu/hotspot-hwsim.sh --iso companion-os-1.0-amd64.iso                    # chain, caps, veth, legacy
nice stick/tests/qemu/hotspot-hwsim.sh --iso companion-os-1.0-amd64.iso --scenarios chain  # just the Wi-Fi chain
nice stick/tests/qemu/hotspot-hwsim.sh --iso ... --payload /path/to/payload                 # another payload tree
stick/tests/qemu/hotspot-hwsim.sh --iso ... --shell                                         # development: root shell, no tests
```

Exit status is 0 only when the guest reached `DONE` and no check is `FAIL`. Options: `--work DIR` (default a new `mktemp -d`),
`--timeout SECS` (host wall clock, default 900), `--accel auto|tcg|kvm|hvf`, `--cpu`, `--mem`, `--smp`, `--time-scale N`,
`--scenarios LIST`, `--payload DIR`, `--strict-legacy`, `--no-trim`, `--clean`. Only the QEMU process this script started is
ever killed. `run.sh`, `docker-live.sh` and the other scripts here are untouched, and `run.sh` does not call this one.

## 1. Where `mac80211_hwsim` can run on this Mac (the spike)

| Place | Result | Evidence |
|---|---|---|
| Docker Desktop's Linux VM (privileged container) | **No.** Kernel `7.0.14-linuxkit` (aarch64) is built without wireless: `# CONFIG_WIRELESS is not set`, `# CONFIG_WLAN is not set`, `# CONFIG_RFKILL is not set`, no `cfg80211`/`mac80211` symbols, nothing in `/proc/modules`, no `/lib/modules`. `CONFIG_MODULES=y` does not help, there is nothing to load. It is also an arm64 VM and the ISO is amd64. | `docker run --rm --privileged ubuntu:26.04 sh -c 'zcat /proc/config.gz \| grep -E "WIRELESS\|WLAN\|RFKILL"'` |
| QEMU guest booted from the v7 Ubuntu ISO | **Yes.** `drivers/net/wireless/virtual/mac80211_hwsim.ko.zst` is in the image's kernel; its parameters on this kernel are `radios channels paged_rx rctbl support_p2p_device mlo multi_radio regtest`. TCG only: an Apple-silicon host cannot accelerate an x86 guest. | `hwsim-module` line of every run |
| QEMU guest booted from the CachyOS ISO #2 | **Not run.** Report 02 found the module in both CachyOS kernels, but that live image has no `hostapd`, `gunicorn` or Flask, so only the `caps` scenario could run there, and its archiso boot needs a different command line. | report 02, section 5.1 |

The v7 ISO ships the setup payload already (identical to `HEAD` `4931f4c` in all 14 compared files; the `payload-drift` line of
each run says so) together with `hostapd` 2.10, `wpa_supplicant` 2.10, `dnsmasq` 2.91, `nginx` 1.24, `gunicorn` 20.1, Flask 3.0.2,
`iw` 6.7, busybox `udhcpc`, `dig`, `curl` and NetworkManager 1.46. The guest boots to `multi-user.target` with no desktop, which is
why Haswell-vs-Nehalem (GNOME Shell crashes) does not matter; the harness uses `-cpu Nehalem` anyway.

## 2. How a run works

```
hotspot-hwsim.sh                               guest (Ubuntu live, 7.0.0-31-generic, TCG)
  bsdtar/xorriso: casper/vmlinuz + initrd  ->  -kernel/-initrd with GRUB's arguments, ISO read-only as the CD-ROM
  in.tar (guest script, config.env, the        virtio disk CIHWIN  -> tar -xf into /run/hwsim-in   (systemd.run=, like
          payload tree under test)  -------->  docker-live.sh; systemd.wants=multi-user.target brings NetworkManager in)
  serial.log  <------------------------------ `CI-HWSIM-TEST <name> <PASS|FAIL|XFAIL|XPASS|SKIP|INFO> <detail>` on ttyS0
  artifacts/  <------------------------------ virtio disk CIHWOUT: tar of /run/hwsim/{logs,art,results.txt}, rewritten after
                                                every scenario (a hang loses little); `iw` captures are fixtures for parsers
```

* No `xorriso`/`mkisofs` is needed for the input (the old CI_TEST ISO is replaced by a tar on a virtio disk); a unique `mktemp -d`
  holds everything, `results.txt` has one line per check, `serial.log` is kept.
* `-vga none -nic none`, `virtio-rng` (without it the guest waits minutes for entropy), 2 vCPUs, 4 GiB. Start it under `nice`.
* The default boot is **trimmed**: `systemd.mask=` for 43 units that have nothing to do with Wi-Fi (snapd, apt timers, cloud-init,
  ollama, the container runtime and its live-storage unit, printing, Bluetooth, md5 check of the ISO). Boot to the guest script
  took 171 s on a quiet machine; the first, untrimmed boots on a busy one took 21 to 36 minutes (the two effects were not
  measured apart, see section 7). NetworkManager, wpa_supplicant and udev are as shipped. The kernel command line
  must stay under 2048 bytes (x86 silently truncates it, which would drop `systemd.run=`); the script refuses to run past 1990.
  `--no-trim` boots the full target.
* The payload is copied into the guest **from the tree under test** and installed the way the `.deb` would (`/etc/hostapd`,
  `/etc/nginx`, `/opt/setup-backend`, `/usr/local/bin`, `/var/www/setup-portal`, units in `/etc/systemd/system`), nothing enabled,
  the live-session guard drop-ins removed. The tree moves while other work lands: record what you tested. The baseline below is
  `git archive HEAD core/headless/payload` (`--payload`).
* Passphrases are generated in the guest, kept in 0600 files under `/run/hwsim`, never printed; console lines and archived logs are
  scrubbed of them and `*-psk-not-leaked` greps `ps` arguments, logs and `dmesg` for them.
* `--time-scale N` multiplies the guest's waits (default 2 under TCG, 1 with KVM/HVF).

## 3. What each scenario checks

| Scenario | Checks (the `CI-HWSIM-TEST` names) |
|---|---|
| `chain` | `chain-nm-manages-radios` (after udev settled), `chain-nm-unmanaged` (the payload's own `nmcli device set <if> managed no`), `chain-ap-up` (generated config: WPA2-PSK CCMP, random passphrase, `country_code` only when the radio's regdom is not `00`), `chain-ap-iw`, `chain-netns` (`iw phy <phy> set netns name phone`), `chain-wrong-psk` (4-way handshake fails, never `COMPLETED`), `chain-assoc`, `chain-ap-sees-sta` (`[AUTHORIZED]`), `chain-4way`, the L3 stack below, `chain-psk-not-leaked`, `chain-gunicorn-stops-quickly`, and `chain-down-*` (processes, addresses, namespace, the radio returning to the root namespace, ports, NetworkManager manages the radios again after `managed yes` and still runs, before/after snapshot of addresses and listening sockets) |
| L3 stack (`chain-*` and `veth-*`) | `*-dnsmasq-up`, `*-dhcp` (busybox `udhcpc` in the namespace with its own hook; the per-namespace `resolv.conf` means the guest's is never touched), `*-lease-file`, `*-dns-a`, `*-dns-aaaa`, `*-dns-aaaa-nodata`, `*-portal-up` (real `setup_service.py`, gunicorn on `127.0.0.1:5000` as the unit has it and on `192.168.99.1:8081`), `*-portal-health`, `*-portal-status`, `*-portal-api-health` (INFO), `*-nginx-up` (the shipped site config, verbatim), `*-probes-302` (iOS, Windows x2, Android, Firefox x2 URLs by name, with their user agents), `*-probes-extra` (INFO: `gen_204`, `library/test/success.html`, `redirect`), `*-portal-page`, `*-nginx-proxy` |
| `caps` | `caps-load`, `caps-radio-count`, `caps-ap-mode-N`, `caps-combinations` (INFO), `caps-regdom`, `caps-bands` (INFO), `caps-nm-manages-radios`, `caps-nm-unmanage`, `caps-nm-managed-reset`, `caps-nm-managed-yes`, `caps-rfkill`, `caps-channels-differ` (`channels=1` vs `channels=2` change `#channels` in the valid interface combinations), `caps-no-ap-radio` (`virt_wifi`: managed-only, the stand-in for a chip without AP mode). `artifacts/art/` keeps raw `iw dev`, `iw phy info`, `iw reg get` as parser fixtures. |
| `veth` | the L3 stack over a veth pair, no radios (section 6) |
| `legacy` | characterization of the **current** payload scripts (section 4) |

## 4. Baseline of the current payload

`legacy` models a machine with **one** radio (`wlan0`, root namespace); the "phone" and a "home router" AP (`HomeNet-xxxx`,
channel 1) live in their own namespaces, and a shim `docker` records `docker stop traefik`. `setup-network-monitor.service` decides
there is no network and starts the AP through `setup-device-hotspot-start.sh`; the checks then ask for DESIRED behaviour. A check
that does not hold is `XFAIL` with the defect id of `02-hotspot-design.md` (`N1` = found here, not in the report); when a fix makes
it hold it turns `XPASS`, which does not fail the run but means this table needs updating. `--strict-legacy` turns every `XFAIL`
into a failure for the day the fixes are in.

Measured on 2026-10-17. **Baseline** = committed payload at `4931f4c` (setup_service.py sha256 `42ce2ed5...`); run `cold5`: 69 PASS,
0 FAIL, 20 XFAIL, 0 XPASS. **Working tree** = the payload as the stop-gap work had it that afternoon (setup_service.py `3265412bad6c`,
`setup-device-hotspot-start.sh` `947e19394a34`; a snapshot, not a release), run in the same image.

| Check | Defect | Baseline | Working tree snapshot |
|---|---|---|---|
| `legacy-static-conf-names-a-real-interface` | L2 | XFAIL `interface=wlp192s0` on a machine whose radio is `wlan0` | XFAIL |
| `legacy-static-ap-unit-runs-here` | L2, H4 | XFAIL hostapd: `Could not read interface wlp192s0 flags: No such device`, unit in auto-restart | XFAIL |
| `legacy-psk-not-a-public-constant` | S2 | XFAIL `SetupDevice123` | XFAIL |
| `legacy-hostapd-conf-private` | H3 | XFAIL mode 644 | XPASS 600 |
| `legacy-country-follows-regdom` | R1 | XFAIL `country_code=US` hard-coded, regdom `00` | XPASS |
| `legacy-teardown-restores-regdom` | R1 | XFAIL regdom is still `US` after the AP stopped (global, affects every radio) | XPASS |
| `legacy-client-isolation`, `legacy-ccmp-only` | R3 | XFAIL no `ap_isolate=1`; `wpa_pairwise=TKIP CCMP` | XPASS |
| `legacy-no-traefik-stop` | L3 | XFAIL the script ran `docker stop traefik` | XPASS |
| `legacy-api-health-endpoint` | U1 | XFAIL `GET /api/health` -> 404 (confirms report 02 on real Flask) | XPASS 200 |
| `legacy-malformed-json-leaves-ap-alone` | L7 | XFAIL one bad request restarted hostapd (new pid, new SSID) | XPASS HTTP 400, AP untouched |
| `legacy-teardown-removes-ap-address` | L4 | XFAIL `192.168.99.1/24` stays on `wlan0` | XPASS |
| `legacy-teardown-stops-nginx` | L4 | XFAIL nginx keeps serving :80 | XFAIL |
| `legacy-teardown-returns-radio-to-nm` | L1 | XFAIL `wlan0` stays `unmanaged` | XPASS |
| `legacy-configure-keeps-foreign-profiles` | S4 | XFAIL the backend went for the ethernet profile `Wired connection 1` (`nmcli connection delete uuid`, in its log) | XPASS |
| `legacy-reset-default-interface-exists` | L10 | XFAIL `setup-hotspot-reset.sh` with no argument works on `wlp192s0` | XPASS |
| `chain-/veth-gunicorn-stops-quickly` | H2 | XFAIL gunicorn needs 30 to 32 s to leave after SIGTERM (the app's handler replaces the worker's) | XPASS 1 s |
| `*-dns-aaaa-nodata` | N1 | XFAIL `address=/#/` with `no-resolv` answers AAAA with **REFUSED**, not NODATA as report 02 assumed | XFAIL |

What the baseline does right (PASS in both): the monitor starts the AP 33 to 52 s after it starts (grace 45 s); the **start script
is not pinned**: it detects `wlan0` and rewrites the hostapd and dnsmasq configs for it (the pinned `wlp192s0` bites only the
static units and the reset helper); the AP, the address, the pre-scan (it lists the home router from a real `iw scan`), a station
joining with the shipped passphrase in 4 to 12 s, DHCP, the portal, and the six probe URLs answering 302. The three extra probe
paths (`gen_204`, `library/test/success.html`, `redirect`) get the portal page with 200.

## 5. What this proves and what it cannot

Proves: the hostapd/wpa_supplicant/dnsmasq/portal/nginx **configuration and lifecycle logic** works end to end on the real
userland and the real mac80211/cfg80211 stack: an AP with a generated config comes up, a WPA2 station associates and a wrong key
is refused, DHCP and the catch-all DNS work, the portal and the probe URLs answer from the client side, and everything is torn
down with NetworkManager's view restored. It runs the exact payload files of the tree.

Cannot: real chipset behaviour (firmware limits, AP+STA concurrency of a given part, its real `iw phy` combinations),
regulatory enforcement (hwsim lets any channel be used; only the plumbing of `country_code` and the global regdom side effect are
exercised), DFS/CAC timing, power save and suspend, radio coexistence, signal strength and rate adaptation (the pre-scan's
`-30 dBm` is hwsim's), and what iOS, Android and Windows really do with the probe responses (their user agents are sent, the
phones are not simulated). Frames travel in software, so throughput and latency mean nothing. Those stay on the manual
phone/chip checklist.

Findings made while building it, not in report 02: NetworkManager 1.46 on this image **rejects `nmcli device set <if> managed
reset`** (`'reset' is not valid; use [true, yes, on] or [false, no, off]`), so the design's exit path must use `managed yes` (which
works, `caps-nm-managed-yes`) or a conf.d file; a new netdev is `unmanaged` to NetworkManager until udev has initialized it, which
takes minutes on a slow guest, so the harness waits for `udevadm settle` and then for the radios to be managed; AAAA is REFUSED
(N1); hostapd's `country_code=US` leaves the machine on `US` after the AP stops; and the backend's `netplan apply` (10 s timeout)
stopped NetworkManager and was killed before it started it again in this slow guest, leaving it down for minutes (seen in 3 of
the 7 `legacy` runs, in the S4 step, on the baseline and on the working tree; not in the final `cold5`; the harness restarts
NetworkManager when it sees this; the slowness of the guest probably triggers it, but the 10 s kill between stop and start is a
real fragility).

## 6. Dependency-light variants

* **No radios (`--scenarios veth`).** The whole L3 stack (dnsmasq DHCP and DNS, the portal under gunicorn, nginx with the shipped
  site config, the probes, teardown, gunicorn's stop time) over a veth pair into a network namespace: no QEMU and no
  `mac80211_hwsim`. It needs root, `ip`, `dnsmasq`, `nginx`, `gunicorn`, Flask, `curl`, `dig` and busybox `udhcpc`.
* **Native mode.** The guest script runs on any Linux machine you can throw away (a privileged container, a CI VM):
  `HWSIM_NATIVE=1 HWSIM_ALLOW_INSTALL=1 HWSIM_PAYLOAD=core/headless/payload HWSIM_OUT_DIR=out SCENARIOS=veth bash guest-hotspot-test.sh`
  (results on stdout, nothing powered off, no config file read unless `HWSIM_CONFIG` names one). It installs the payload
  system-wide and starts and stops units, hence the second variable. Tested inside the QEMU guest as
  `SCENARIOS=veth`: 15 PASS, 2 XFAIL (N1, H2) in 57 s. `SCENARIOS=chain,caps` additionally needs `modprobe mac80211_hwsim`: a
  runner kernel with `linux-modules-extra` works in principle, the Docker Desktop VM does not (section 1). GitHub-hosted runners
  have not been tried, and the Docker Desktop VM was not tried for `veth` (its images here lack dnsmasq/nginx/Flask).
* **Pure logic needs neither:** parsers and renderers belong in Python unit tests on fixtures; `artifacts/art/iw-*.txt` and
  `legacy-last-scan.json` are real captures to start from.

## 7. Timings (TCG, 2 vCPUs, `nice -n 2`, the machine shared with other work)

| Host load average | Boot to guest script | `chain` | `caps` | `veth` | `legacy` | Whole run |
|---|---|---|---|---|---|---|
| about 15 to 40 (`cold5`, the final script) | 171 s | 99 s | 19 s | 54 s | 335 s | **716 s** (12 min) |
| about 100 (`cold1`, `--time-scale 3`) | 745 s | 218 s | 73 s | 108 s | 445 s | 1713 s |
| 150 to 500, untrimmed boot, no `-vga none` (first attempts) | 21 to 36 min | not reached in the dev shell: single commands took seconds to minutes |

So `--scenarios chain` is about 4.5 minutes on a quiet machine and the whole matrix about 12; on a busy one budget three times
that. The guest wait loops are scaled by `--time-scale`, the host timeout is yours (`--timeout`, default 900 s is too short for a
busy machine). With KVM (Linux CI) expect well under a minute of boot and a few minutes in total. If a run times out, `serial.log`
and `results.txt` still hold every check that finished.

## 8. Wiring (not done here, for the maintainer)

* `core/lib/check-repo.sh` already `bash -n`/shellchecks tracked `*.sh`; both new scripts are clean at `-S error` and `-S warning`
  (style notes `SC2015` remain, deliberate: the report helpers never fail). Neither file contains a retired product name.
* A manual-only workflow job (with the `ci-local:gated` marker, like the other long VM tests) can run
  `hotspot-hwsim.sh --scenarios chain,caps,veth` on a runner with KVM; do not add it to `stick-qemu` until its time is known there.
* When the stop-gap fixes land, run with `--strict-legacy` and delete the `known` lines that turned `XPASS`, so the table in
  section 4 becomes the regression test it is meant to be.
