#!/bin/bash
# Runs as root INSIDE the guest (started by hotspot-hwsim.sh through systemd.run=). It loads mac80211_hwsim radios and
# drives the real hostapd, wpa_supplicant, dnsmasq, nginx and the setup portal against them; every check prints one
#   CI-HWSIM-TEST <name> <PASS|FAIL|XFAIL|XPASS|SKIP|INFO> <detail>
# line on the serial console (and into /run/hwsim/results.txt). Logs and `iw` captures go to /run/hwsim/{logs,art} and
# are written to the second virtio disk as a tar archive after every scenario.
#
# Scenarios (SCENARIOS in /run/hwsim-in/config.env, comma list):
#   veth    no radios: the same DHCP/DNS/portal/probe stack over a veth pair (runs on any Linux; the radio-free variant)
#   caps    module parameters, `iw` capabilities and regdom, channels=1 vs 2, a radio without AP mode (virt_wifi), rfkill
#   chain   hostapd (WPA2, random passphrase) -> wpa_supplicant in a network namespace (4-way handshake, wrong key refused)
#           -> dnsmasq DHCP + catch-all DNS -> the real setup_service.py under gunicorn and nginx with the shipped site
#           config -> captive-portal probe URLs -> teardown, then NetworkManager, addresses, processes and netns restored
#   legacy  the CURRENT payload scripts (setup-device-hotspot-start.sh, the hostapd/dnsmasq units, stop_hotspot_services)
#           as characterization: checks of DESIRED behaviour that are known not to hold today are XFAIL with the defect id
#           from 02-hotspot-design.md (L1..L12, S1..S12, R1..R4, H1..H6, U1..U3); XPASS means the baseline changed.
#
# The passphrases are generated here and never printed; the log lines are scrubbed of them as well.
# Development: HWSIM_LIB_ONLY=1 . guest-hotspot-test.sh defines the functions without running anything (see --shell).
IN="${HWSIM_IN:-/run/hwsim-in}"
W="${HWSIM_RUN:-/run/hwsim}"
PAYLOAD_SRC="${HWSIM_PAYLOAD:-$IN/payload}"
# HWSIM_NATIVE=1: run on a Linux machine you can throw away (a privileged container, a CI VM) instead of in the QEMU guest.
# Results go to stdout, nothing is powered off. The scenarios install the payload into /etc, /opt, /usr/local and /var/www and
# start and stop system units, so it insists on HWSIM_ALLOW_INSTALL=1.
if [ -n "${HWSIM_NATIVE:-}" ]; then
  if [ -z "${HWSIM_LIB_ONLY:-}" ] && [ "${HWSIM_ALLOW_INSTALL:-}" != 1 ]; then
    echo "native mode installs the payload system-wide and restarts units: set HWSIM_ALLOW_INSTALL=1 on a disposable machine" >&2; exit 2
  fi
fi
LOGD="$W/logs"
ART="$W/art"
RES="$W/results.txt"
mkdir -p "$W" "$LOGD" "$ART"
# config.env (written by the host script) supplies defaults; a variable already set in the environment wins, which is how the
# native mode picks its scenarios.
_env_mode="${MODE:-}"; _env_scen="${SCENARIOS:-}"; _env_strict="${STRICT_LEGACY:-}"; _env_ts="${TIME_SCALE:-}"
CONFIG_ENV="${HWSIM_CONFIG:-$IN/config.env}"
[ -n "${HWSIM_NATIVE:-}" ] && CONFIG_ENV="${HWSIM_CONFIG:-}"   # native mode reads no config unless it is named
if [ -n "$CONFIG_ENV" ] && [ -f "$CONFIG_ENV" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_ENV"
fi
[ -n "$_env_mode" ] && MODE="$_env_mode"; [ -n "$_env_scen" ] && SCENARIOS="$_env_scen"
[ -n "$_env_strict" ] && STRICT_LEGACY="$_env_strict"; [ -n "$_env_ts" ] && TIME_SCALE="$_env_ts"
: "${MODE:=test}" "${SCENARIOS:=chain,caps,veth,legacy}" "${STRICT_LEGACY:=0}" "${TIME_SCALE:=1}"

NP=0; NF=0; NXF=0; NXP=0; NSK=0
SECRETS=()      # strings that must never reach the console or a log line we print
T0=$SECONDS

# ----------------------------------------------------------------------------------------------------------------
# Reporting
# ----------------------------------------------------------------------------------------------------------------
# console LINE: the serial console in the QEMU guest, stdout in native mode (never `> /dev/stdout`: it would truncate a
# redirected file on every line)
console() { if [ -n "${HWSIM_NATIVE:-}" ]; then printf '%s\n' "$1"; else printf '%s\n' "$1" > /dev/console; fi; }
scrub() {
  local s="$1" x
  for x in "${SECRETS[@]}"; do [ -n "$x" ] && s="${s//"$x"/<secret>}"; done
  printf '%s' "$s"
}
emit() { # emit NAME STATUS DETAIL...
  local name="$1" st="$2" d; shift 2
  d="$(printf '%s' "$*" | tr '\n\r\t' '   ' | cut -c1-420)"
  d="$(scrub "$d")"
  console "CI-HWSIM-TEST $name $st $d"
  printf '%s %s %s\n' "$name" "$st" "$d" >> "$RES"
  case "$st" in
    PASS) NP=$((NP + 1)) ;; FAIL) NF=$((NF + 1)) ;; XFAIL) NXF=$((NXF + 1)) ;;
    XPASS) NXP=$((NXP + 1)) ;; SKIP) NSK=$((NSK + 1)) ;;
  esac
}
ok()   { emit "$1" PASS "${2:-}"; }
bad()  { emit "$1" FAIL "${2:-}"; }
note() { emit "$1" INFO "${2:-}"; }
skip() { emit "$1" SKIP "${2:-}"; }
# check NAME cmd...: the command's output is the detail; exit 0 = PASS.
check() { local n="$1" out rc; shift; out="$("$@" 2>&1)"; rc=$?; if [ "$rc" -eq 0 ]; then ok "$n" "$out"; else bad "$n" "$out"; fi; return "$rc"; }
# known NAME ID cmd...: DESIRED behaviour that the current payload is known not to have (defect ID). XFAIL = still broken,
# XPASS = it holds now, exit status 2 from the command = it could not be judged (SKIP).
known() { local n="$1" id="$2" out rc; shift 2; out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then emit "$n" XPASS "[$id] now holds: $out"
  elif [ "$rc" -eq 2 ]; then emit "$n" SKIP "[$id] could not tell: $out"
  else emit "$n" XFAIL "[$id] $out"; fi
  return "$rc"; }

wait_for() { # wait_for SECONDS cmd... : poll once a second (SECONDS scaled by TIME_SCALE) until cmd succeeds
  local limit=$(($1 * TIME_SCALE)) i=0; shift
  while [ "$i" -lt "$limit" ]; do "$@" >/dev/null 2>&1 && return 0; sleep 1; i=$((i + 1)); done
  return 1
}
since() { echo $((SECONDS - ${1:-$T0})); }
# no_proc PATTERN: no process has PATTERN in its command line. Called as a function, never through `sh -c`, so the
# pattern is not in the command line of the thing doing the looking.
no_proc() { ! pgrep -f "$1" > /dev/null 2>&1; }

save_artifacts() {
  # Everything useful on one tar archive on the output disk; rewritten after each scenario so a hang loses little.
  local dev=/dev/disk/by-id/virtio-CIHWOUT
  { dmesg 2>/dev/null | tail -n 400 > "$LOGD/dmesg.txt"
    journalctl -b --no-pager -u NetworkManager 2>/dev/null | tail -n 300 > "$LOGD/journal-networkmanager.txt"
    journalctl -b --no-pager -t setup-hotspot-start -t setup-network-monitor -t setup-hotspot-reset 2>/dev/null | tail -n 200 > "$LOGD/journal-setup-scripts.txt"
  } 2>/dev/null
  # keep the PSKs out of the archive's logs
  local f x
  for f in "$LOGD"/*; do
    [ -f "$f" ] || continue
    for x in "${SECRETS[@]}"; do [ -n "$x" ] && sed -i "s|$x|<secret>|g" "$f" 2>/dev/null; done
  done
  if [ -n "${HWSIM_OUT_DIR:-}" ]; then
    mkdir -p "$HWSIM_OUT_DIR" && cp -R "$W/logs" "$W/art" "$RES" "$HWSIM_OUT_DIR/" 2>/dev/null
  elif [ -e "$dev" ]; then
    tar -cf "$dev" -C "$W" logs art results.txt 2>/dev/null && sync
  fi
}

# ----------------------------------------------------------------------------------------------------------------
# Environment, NetworkManager, radios
# ----------------------------------------------------------------------------------------------------------------
nm_running() { [ "$(nmcli -t -f RUNNING general 2>/dev/null)" = running ]; }
HAVE_NM=0
rand_alnum() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2> /dev/null | head -c "${1:-20}"; }

snapshot() { # snapshot LABEL : state that a clean teardown must restore
  local l="$1" f="$ART/snap-$1"
  {
    echo "--- ip -br addr (root namespace, no hwsim devices)"; ip -br addr 2>/dev/null | grep -v -E '^(wlan[0-9]+|hwsim0|vwlan[0-9]+) ' | sort
    echo "--- netns"; ip netns list 2>/dev/null | sort
    echo "--- addresses in 192.168.99.0/24"; ip -4 -o addr 2>/dev/null | grep -F ' 192.168.99.' | sort
    echo "--- NetworkManager devices"; nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | sort
    echo "--- NetworkManager state"; nmcli -t general 2>/dev/null
    echo "--- NM-owned wireless daemons"; pgrep -a wpa_supplicant 2>/dev/null | sed 's|^[0-9]* ||' | sort
    echo "--- listening sockets"; ss -H -ltnu 2>/dev/null | awk '{print $1, $5}' | sort
    echo "--- processes of the Wi-Fi chain (name + args without the hwsim run dir)"
    ps -eo comm=,args= 2>/dev/null | grep -E '^(hostapd|dnsmasq|nginx|gunicorn|udhcpc|dhcpcd) ' | grep -v "$W/" | sort
  } > "$f" 2>&1
}

pre_env() {
  local v tools missing=""
  note kernel "$(uname -srv | cut -c1-120)"
  note qemu-cpu "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //') x$(nproc), $(free -m | awk '/^Mem:/ {print $2}') MiB"
  for tools in modprobe iw ip hostapd hostapd_cli wpa_supplicant wpa_cli dnsmasq nginx gunicorn python3 curl nmcli ss rfkill tar busybox dig; do
    command -v "$tools" >/dev/null 2>&1 || missing="$missing $tools"
  done
  if [ -n "$missing" ]; then bad tools-present "missing:$missing"; else ok tools-present "all of the chain's tools are in the image"; fi
  v="hostapd $(hostapd -v 2>&1 | sed -n 's/^hostapd v//p' | head -1) | wpa_supplicant $(wpa_supplicant -v 2>&1 | sed -n 's/^wpa_supplicant v//p' | head -1) | $(dnsmasq -v 2>&1 | head -1 | cut -c1-40) | iw $(iw --version 2>&1 | head -1) | $(nginx -v 2>&1 | cut -c1-40) | gunicorn $(gunicorn --version 2>&1 | head -1 | cut -c1-30) | NM $(nmcli -v 2>&1 | head -1) | python $(python3 -V 2>&1 | cut -d' ' -f2) flask $(python3 -c 'import importlib.metadata as m; print(m.version("flask"))' 2>&1 | tail -1)"
  note versions "$v"
  modinfo -F filename mac80211_hwsim > /dev/null 2>&1 && note hwsim-module "$(modinfo -F filename mac80211_hwsim | sed 's|.*/kernel/||') | params: $(modinfo -F parm mac80211_hwsim | cut -d: -f1 | tr '\n' ' ')" || bad hwsim-module "mac80211_hwsim.ko is not in this kernel's modules"
  modinfo -p mac80211_hwsim > "$ART/modinfo-hwsim-params.txt" 2>&1
  # Make sure we begin from no radios, then NetworkManager
  if wait_for 240 nm_running; then HAVE_NM=1; ok nm-running "NetworkManager $(nmcli -t -f STATE general), up $(since)s into the run"; else HAVE_NM=0; bad nm-running "NetworkManager is not running after $((240 * TIME_SCALE))s; the NM restore checks are skipped"; fi
  snapshot before
}

hw_unload() {
  local ns
  for ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do ip netns del "$ns" 2>/dev/null; done
  modprobe -r mac80211_hwsim 2>/dev/null
  wait_for 20 hw_gone
  # The regulatory domain is global and outlives the radios (a hostapd country_code=US leaves the whole machine on US):
  # every scenario starts from the world domain.
  iw reg set 00 2>/dev/null
}
hw_gone() { ! lsmod | grep -q '^mac80211_hwsim'; }
hw_count() { iw dev 2>/dev/null | grep -c '^[[:space:]]*Interface '; }
hw_count_ge() { [ "$(hw_count)" -ge "$1" ]; }
hw_load() { # hw_load RADIOS [module params...]
  local n="$1"; shift
  modprobe mac80211_hwsim radios="$n" "$@" > "$LOGD/modprobe.out" 2>&1 || return 1
  wait_for 40 hw_count_ge "$n"
}
# hw_map fills IFN[i]/PHN[i] (interface and phy of radio i, in phy order)
hw_map() {
  IFN=(); PHN=()
  local p i
  while read -r p i; do PHN+=("$p"); IFN+=("$i"); done < <(iw dev 2>/dev/null | awk '/^phy#/ {p=substr($1,5)} /^[ \t]*Interface / {print "phy" p, $2}' | sort -V)
}
regdom() { iw reg get 2>/dev/null | awk '/^country/ {gsub(":", "", $2); print $2; exit}'; }
nm_state_of() { nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v d="$1" '$1 == d {print $2}'; }
nm_sees() { [ "$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep -c ':wifi$')" -ge "$1" ]; }
# A new netdev is "unmanaged" to NetworkManager until udev has initialized it; on a slow guest (TCG on a busy machine) that
# takes minutes, so wait for udev first and then for NetworkManager to manage the radios, as on a real boot.
hw_settle() { udevadm settle --timeout=$((120 * TIME_SCALE)) 2>/dev/null; }
nm_manages() { [ "$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | awk -F: '$2 == "wifi" && $3 != "unmanaged"' | wc -l)" -ge "$1" ]; }
nm_all_managed() { # nm_all_managed IF... : none of the interfaces is unmanaged
  local i; for i in "$@"; do [ "$(nm_state_of "$i")" = unmanaged ] && return 1; done; return 0
}
nm_unmanage() { local i; for i in "$@"; do nmcli device set "$i" managed no >/dev/null 2>&1; done; }

# ----------------------------------------------------------------------------------------------------------------
# Config generators
# ----------------------------------------------------------------------------------------------------------------
gen_hostapd_conf() { # gen_hostapd_conf IFACE SSID PSK CHANNEL [extra lines...]
  local ifc="$1" ssid="$2" psk="$3" ch="$4"; shift 4
  local cc; cc="$(regdom)"
  {
    echo "interface=$ifc"; echo "driver=nl80211"; echo "ctrl_interface=${HAPD_CTRL:-$W/hostapd-ctrl}"
    echo "ssid=$ssid"
    # Country from the radio's own regdom; omitted when it is the world domain "00" (the design's rule).
    case "$cc" in 00|''|99) ;; *) echo "country_code=$cc"; echo "ieee80211d=1" ;; esac
    echo "hw_mode=g"; echo "channel=$ch"; echo "wmm_enabled=1"; echo "ieee80211n=1"; echo "ht_capab=[SHORT-GI-20]"
    echo "auth_algs=1"; echo "wpa=2"; echo "wpa_key_mgmt=WPA-PSK"; echo "rsn_pairwise=CCMP"; echo "wpa_passphrase=$psk"
    echo "max_num_sta=10"; echo "wps_state=0"
    local l; for l in "$@"; do echo "$l"; done
  }
}
gen_wpa_conf() { # gen_wpa_conf SSID PSK
  printf 'ctrl_interface=DIR=%s/wpa-ctrl GROUP=0\nupdate_config=0\nnetwork={\n  ssid="%s"\n  psk="%s"\n  key_mgmt=WPA-PSK\n  proto=RSN\n  pairwise=CCMP\n}\n' "$W" "$1" "$2"
}
gen_udhcpc_script() { # DHCP client hook: address, route and a per-namespace resolv.conf (never the host's)
  cat <<'EOF'
#!/bin/sh
# usage: udhcpc.script <event>; env from busybox udhcpc: interface ip mask router dns
case "$1" in
  bound|renew)
    ip -4 addr flush dev "$interface"
    ip addr add "$ip/${mask:-24}" dev "$interface"
    [ -n "$router" ] && ip route replace default via "${router%% *}" dev "$interface"
    if [ -n "$HWSIM_NS" ]; then
      mkdir -p "/etc/netns/$HWSIM_NS"
      : > "/etc/netns/$HWSIM_NS/resolv.conf"
      for d in $dns; do echo "nameserver $d" >> "/etc/netns/$HWSIM_NS/resolv.conf"; done
    fi
    echo "$ip $router $dns" > "${HWSIM_LEASE_OUT:-/dev/null}"
    ;;
esac
exit 0
EOF
}

# ----------------------------------------------------------------------------------------------------------------
# Station namespace helpers
# ----------------------------------------------------------------------------------------------------------------
ns_add() { # ns_add NAME PHY IFACE : move the radio into its own namespace
  ip netns add "$1" 2>/dev/null
  iw phy "$2" set netns name "$1" || return 1
  ip netns exec "$1" ip link set lo up
  wait_for 10 ip netns exec "$1" ip link show "$3"
}
sta_state() { # sta_state NS IFACE
  wpa_cli -p "$W/wpa-ctrl" -i "$2" status 2>/dev/null | sed -n 's/^wpa_state=//p'
}
sta_completed() { [ "$(sta_state "$1" "$2")" = COMPLETED ]; }
sta_start() { # sta_start NS IFACE CONFFILE LOGFILE
  ip netns exec "$1" wpa_supplicant -B -i "$2" -c "$3" -P "$W/wpa-$1.pid" -f "$4" -dd -t >/dev/null 2>&1
}
sta_stop() { # sta_stop NS
  if [ -s "$W/wpa-$1.pid" ]; then kill "$(cat "$W/wpa-$1.pid")" 2>/dev/null; rm -f "$W/wpa-$1.pid"; fi
  wait_for 10 no_proc "wpa_supplicant.*$W/wpa-$1"
}
sta_dhcp() { # sta_dhcp NS IFACE : busybox udhcpc with our hook; prints the lease on success
  # The hook must live where files can be executed: /run is mounted noexec on Ubuntu, and busybox execs the script itself.
  local hook=/var/tmp/hwsim-udhcpc.script
  gen_udhcpc_script > "$hook"; chmod 755 "$hook"
  rm -f "$W/lease-$1"
  ip netns exec "$1" env HWSIM_NS="$1" HWSIM_LEASE_OUT="$W/lease-$1" busybox udhcpc -i "$2" -n -q -t 8 -T 3 -s "$hook" > "$LOGD/udhcpc-$1.log" 2>&1
  [ -s "$W/lease-$1" ] && cat "$W/lease-$1"
}
ns_http() { # ns_http NS URL [curl args...] -> "CODE|redirect_url|content_type" (000 when curl failed; the reason is in logs/ns-http-errors.log)
  local ns="$1" url="$2" out rc; shift 2
  out="$(ip netns exec "$ns" curl -sS -o /dev/null --max-time 20 -w '%{http_code}|%{redirect_url}|%{content_type}' "$@" "$url" 2>"$LOGD/.curl-err")"; rc=$?
  [ "$rc" -ne 0 ] && echo "$(date +%T) $url curl rc=$rc: $(head -c 160 "$LOGD/.curl-err")" >> "$LOGD/ns-http-errors.log"
  printf '%s' "$out"
}
ns_body() { local ns="$1" url="$2"; shift 2; ip netns exec "$ns" curl -sS --max-time 20 "$@" "$url" 2>&1; }

# ----------------------------------------------------------------------------------------------------------------
# Scenario: caps
# ----------------------------------------------------------------------------------------------------------------
phy_modes() { iw phy "$1" info 2>/dev/null | awk '/Supported interface modes:/ {f=1; next} f && /^[[:space:]]+\* / {printf "%s ", $2; next} f {exit}'; }
phy_bands() { iw phy "$1" info 2>/dev/null | awk '/^[[:space:]]+Band [0-9]+:/ {if (b != "") printf "band%s=%d ", b, n; b=$2; sub(":", "", b); n=0; next} /MHz \[/ {n++} END {if (b != "") printf "band%s=%d", b, n}'; }
phy_channels_max() { echo "$1" | grep -o '#channels <= [0-9]*' | tr '\n' ' '; }
phy_combos() { iw phy "$1" info 2>/dev/null | awk '/valid interface combinations:/ {f=1; next} f && /#\{|total <=/ {print; next} f {exit}' | tr -s ' \t' ' ' | tr '\n' ' '; }

scenario_caps() {
  local t=$SECONDS i cc c1 c2
  hw_unload
  if hw_load 3; then ok caps-load "modprobe mac80211_hwsim radios=3: $(hw_count) interfaces in $(since "$t")s"; else bad caps-load "modprobe mac80211_hwsim radios=3 failed: $(cat "$LOGD/modprobe.out")"; return; fi
  hw_map
  [ "${#IFN[@]}" -eq 3 ] && ok caps-radio-count "3 phys: ${PHN[*]} / ${IFN[*]}" || bad caps-radio-count "expected 3 radios, found ${#IFN[@]}: ${IFN[*]}"
  iw dev > "$ART/iw-dev.txt" 2>&1; iw phy > "$ART/iw-phy-all.txt" 2>&1
  iw phy "${PHN[0]}" info > "$ART/iw-phy0-info.txt" 2>&1; iw reg get > "$ART/iw-reg-get.txt" 2>&1
  for i in 0 1 2; do
    [ -n "${PHN[$i]:-}" ] || continue
    case " $(phy_modes "${PHN[$i]}") " in
      *" AP "*) ok "caps-ap-mode-$i" "${PHN[$i]} modes: $(phy_modes "${PHN[$i]}")" ;;
      *) bad "caps-ap-mode-$i" "${PHN[$i]} has no AP mode: $(phy_modes "${PHN[$i]}")" ;;
    esac
  done
  note caps-combinations "${PHN[0]}: $(phy_combos "${PHN[0]}" | cut -c1-300)"
  cc="$(regdom)"
  [ -n "$cc" ] && ok caps-regdom "iw reg get reports country $cc (00 = world domain; hostapd country_code is omitted for 00)" || bad caps-regdom "iw reg get gave no country line"
  note caps-bands "${PHN[0]} frequencies per band: $(phy_bands "${PHN[0]}") (iw numbers the bands 1 = 2.4 GHz, 2 = 5 GHz, 4 = 6 GHz)"
  # NetworkManager sees the radios and the AP-mode handover works on them
  if [ "$HAVE_NM" = 1 ]; then
    hw_settle
    if wait_for 120 nm_manages 3; then ok caps-nm-manages-radios "NetworkManager manages the 3 radios: $(nmcli -t -f DEVICE,STATE device | grep '^wlan' | tr '\n' ' ')"; else bad caps-nm-manages-radios "NetworkManager does not manage the radios after $((120 * TIME_SCALE))s: $(nmcli -t -f DEVICE,STATE device | grep '^wlan' | tr '\n' ' ')"; fi
    nmcli device set "${IFN[0]}" managed no >/dev/null 2>&1; sleep 1
    [ "$(nm_state_of "${IFN[0]}")" = unmanaged ] && ok caps-nm-unmanage "nmcli device set ${IFN[0]} managed no -> unmanaged" || bad caps-nm-unmanage "state after managed no: $(nm_state_of "${IFN[0]}")"
    local rs; rs="$(nmcli device set "${IFN[0]}" managed reset 2>&1)"
    if [ $? -eq 0 ]; then
      sleep 2; ok caps-nm-managed-reset "nmcli 'managed reset' is supported by $(nmcli -v | head -1); state now $(nm_state_of "${IFN[0]}")"
    else
      note caps-nm-managed-reset "nmcli ($(nmcli -v | head -1)) rejects 'managed reset' ($rs): the exit path must use 'managed yes' or a conf.d file"
    fi
    nmcli device set "${IFN[0]}" managed yes >/dev/null 2>&1
    wait_for 60 nm_all_managed "${IFN[0]}" && ok caps-nm-managed-yes "nmcli device set ${IFN[0]} managed yes restores management: ${IFN[0]}=$(nm_state_of "${IFN[0]}")" || bad caps-nm-managed-yes "${IFN[0]} is $(nm_state_of "${IFN[0]}") after managed yes"
  fi
  # rfkill: the script helpers rely on `rfkill unblock wifi`
  if command -v rfkill >/dev/null 2>&1; then
    rfkill block wifi >/dev/null 2>&1; sleep 1
    local blocked; blocked="$(rfkill list wifi 2>/dev/null | grep -c 'Soft blocked: yes')"
    rfkill unblock wifi >/dev/null 2>&1; sleep 1
    local after; after="$(rfkill list wifi 2>/dev/null | grep -c 'Soft blocked: yes')"
    if [ "$blocked" -ge 1 ] && [ "$after" -eq 0 ]; then ok caps-rfkill "block wifi blocked $blocked radios, unblock restored them"; else bad caps-rfkill "blocked=$blocked after-unblock=$after"; fi
  fi
  # channels=1 versus channels=2: different valid interface combinations
  hw_unload; hw_load 1 channels=1 && { hw_map; c1="$(phy_combos "${PHN[0]}")"; echo "$c1" > "$ART/combos-channels1.txt"; }
  hw_unload; hw_load 1 channels=2 && { hw_map; c2="$(phy_combos "${PHN[0]}")"; echo "$c2" > "$ART/combos-channels2.txt"; }
  if [ -n "${c1:-}" ] && [ -n "${c2:-}" ] && [ "$c1" != "$c2" ]; then ok caps-channels-differ "channels=1 -> $(phy_channels_max "$c1"); channels=2 -> $(phy_channels_max "$c2") (the probe can tell concurrent AP+STA from sequential)"
  else bad caps-channels-differ "channels=1: [$(phy_channels_max "${c1:-}")] channels=2: [$(phy_channels_max "${c2:-}")]; combos identical or missing"; fi
  # a radio without AP mode: virt_wifi
  hw_unload
  if modprobe virt_wifi 2>/dev/null; then
    ip link add dummyv0 type dummy 2>/dev/null; ip link set dummyv0 up 2>/dev/null
    if ip link add link dummyv0 name vwlan0 type virt_wifi 2>/dev/null; then
      sleep 1; hw_map
      local vp; vp="$(iw dev 2>/dev/null | awk '/^phy#/ {p=substr($1,5)} /Interface vwlan0/ {print "phy" p}')"
      if [ -n "$vp" ]; then
        local vm; vm="$(phy_modes "$vp")"
        case " $vm " in
          *" AP "*) bad caps-no-ap-radio "virt_wifi $vp unexpectedly lists AP mode: $vm" ;;
          *) ok caps-no-ap-radio "virt_wifi $vp is a managed-only radio (modes: $vm): the stand-in for a chip without AP mode" ;;
        esac
        iw phy "$vp" info > "$ART/iw-phy-virt_wifi.txt" 2>&1
      else bad caps-no-ap-radio "virt_wifi created no wiphy"; fi
      ip link del vwlan0 2>/dev/null
    else skip caps-no-ap-radio "ip link add type virt_wifi failed"; fi
    ip link del dummyv0 2>/dev/null; modprobe -r virt_wifi 2>/dev/null
  else skip caps-no-ap-radio "virt_wifi module not available in this kernel"; fi
  hw_unload
  save_artifacts
}

# ----------------------------------------------------------------------------------------------------------------
# Payload as the .deb would install it, without enabling anything. The image already carries its own copy (with the
# live-session guard drop-ins); the tree under test is copied over it, and the files that differ are reported.
# ----------------------------------------------------------------------------------------------------------------
payload_drift() { # files of the tree under test that differ from, or are missing in, the copy the image carries
  local P="$PAYLOAD_SRC" f out="" n=0
  for f in opt/setup-backend/setup_service.py usr/local/bin/setup-device-hotspot-start.sh usr/local/bin/setup-network-monitor.sh \
           usr/local/bin/setup-hotspot-reset.sh usr/local/bin/setup-device-prescan.py usr/local/bin/setup-wifi-recover \
           hostapd/hostapd-setup.conf dnsmasq.d/setup-portal.conf nginx/sites-available/setup-portal \
           systemd/system/hostapd-setup.service systemd/system/dnsmasq-setup.service systemd/system/setup-backend.service \
           systemd/system/setup-network-monitor.service var/www/setup-portal/index.html; do
    case "$f" in
      hostapd/*) inst="/etc/$f" ;; dnsmasq.d/*) inst="/etc/$f" ;; nginx/*) inst="/etc/$f" ;; systemd/*) inst="/etc/$f" ;;
      *) inst="/$f" ;;
    esac
    n=$((n + 1))
    if [ ! -e "$inst" ]; then out="$out $f(missing)"; elif ! cmp -s "$P/$f" "$inst"; then out="$out $f"; fi
  done
  if [ -z "$out" ]; then echo "the image's payload copy equals the tree under test in all $n compared files"; else echo "the image's payload copy differs from the tree under test in:$out"; fi
}
install_payload() {
  local P="$PAYLOAD_SRC"
  [ -d "$P/opt/setup-backend" ] || return 1
  [ -n "${PAYLOAD_DRIFT_DONE:-}" ] || { note payload-drift "$(payload_drift)"; PAYLOAD_DRIFT_DONE=1; }
  mkdir -p /etc/hostapd /etc/dnsmasq.d /etc/nginx /etc/setup-device /etc/systemd /opt /usr /var /var/lib/setup-device
  cp -a "$P/hostapd/." /etc/hostapd/ && cp -a "$P/dnsmasq.d/." /etc/dnsmasq.d/ && cp -a "$P/nginx/." /etc/nginx/ \
    && cp -a "$P/setup-device-defaults/." /etc/setup-device/ && cp -a "$P/systemd/." /etc/systemd/ \
    && cp -a "$P/opt/." /opt/ && cp -a "$P/usr/." /usr/ && cp -a "$P/var/." /var/ || return 1
  chmod 755 /usr/local/bin/setup-* /usr/local/bin/ci-os-* 2>/dev/null
  chmod 600 /etc/setup-device/device.conf 2>/dev/null
  mkdir -p /etc/nginx/sites-enabled
  ln -sf /etc/nginx/sites-available/setup-portal /etc/nginx/sites-enabled/setup-portal
  rm -f /etc/nginx/sites-enabled/default
  # The image's own guard drop-ins (nothing may run in a live session) would hide what the payload does.
  local u
  for u in hostapd-setup dnsmasq-setup setup-backend setup-network-monitor nginx; do rm -f "/etc/systemd/system/$u.service.d/10-not-live.conf"; done
  systemctl daemon-reload
  mkdir -p /var/log/nginx
  echo "payload installed: setup_service.py sha256 $(sha256sum /opt/setup-backend/setup_service.py | cut -c1-12)"
}

# ----------------------------------------------------------------------------------------------------------------
# Scenario: chain  (the generic AP -> station -> DHCP -> portal chain with generated configs)
# ----------------------------------------------------------------------------------------------------------------
AP_NET=192.168.99
AP_ADDR=$AP_NET.1
hostapd_state() { hostapd_cli -p "$W/hostapd-ctrl" -i "$1" status 2>/dev/null | sed -n 's/^state=//p'; }
hostapd_enabled() { [ "$(hostapd_state "$1")" = ENABLED ]; }
sta_authorized() { hostapd_cli -p "$W/hostapd-ctrl" -i "$1" all_sta 2>/dev/null | grep -q 'AUTHORIZED'; }
sta_not_authorized() { ! sta_authorized "$1"; }
http_up() { # http_up NS URL : any HTTP answer (a 4xx counts) from the portal
  local c; c="$(ns_http "$1" "$2" | cut -d'|' -f1)"; case "$c" in 2??|3??|4??) return 0 ;; *) return 1 ;; esac
}
# stop_gunicorn: SIGTERM the master and time how long gunicorn takes to leave. The payload installs its own SIGTERM handler at
# import (H2), which replaces the worker's, so the worker only goes when the master's graceful timeout (30s) kills it.
GUNICORN_STOP_SECONDS=""
stop_gunicorn() {
  local t=$SECONDS pid
  pid="$(cat "$W/gunicorn.pid" 2>/dev/null)"
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null
  wait_for 90 no_proc gunicorn
  GUNICORN_STOP_SECONDS=$((SECONDS - t))
}
gunicorn_stops_fast() {
  if [ "${GUNICORN_STOP_SECONDS:-99}" -le 15 ]; then echo "gunicorn left ${GUNICORN_STOP_SECONDS}s after SIGTERM"
  else echo "gunicorn needed ${GUNICORN_STOP_SECONDS}s to leave after SIGTERM (systemd would wait TimeoutStopSec=30)"; return 1; fi
}
gunicorn_start() { # gunicorn_start : the unit's command, plus a second bind on the AP address
  ( cd /opt/setup-backend && PYTHONUNBUFFERED=1 gunicorn -D --pid "$W/gunicorn.pid" --bind 127.0.0.1:5000 --bind "$AP_ADDR:8081" \
      --workers 1 --threads 2 --timeout 120 --access-logfile "$LOGD/gunicorn-access.log" --error-logfile "$LOGD/gunicorn-error.log" \
      setup_service:app > "$LOGD/gunicorn-start.log" 2>&1 )
}
nginx_start() { # the shipped site config, verbatim, in a private main config (no change to the image's nginx)
  cat > "$W/nginx.conf" <<NGX
worker_processes 1;
pid $W/nginx.pid;
error_log $LOGD/nginx-error.log;
events { worker_connections 64; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  include /etc/nginx/sites-available/setup-portal;
}
NGX
  nginx -t -c "$W/nginx.conf" > "$LOGD/nginx-test.log" 2>&1 && nginx -c "$W/nginx.conf" >> "$LOGD/nginx-test.log" 2>&1
}

PROBES=(
  "http://captive.apple.com/hotspot-detect.html|CaptiveNetworkSupport-355.60.2 wispr"
  "http://www.msftconnecttest.com/connecttest.txt|Microsoft NCSI"
  "http://www.msftncsi.com/ncsi.txt|Microsoft NCSI"
  "http://connectivitycheck.gstatic.com/generate_204|Dalvik/2.1.0 (Linux; U; Android 14; Pixel 8 Build/AP2A.240805.005)"
  "http://detectportal.firefox.com/canonical.html|Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"
  "http://detectportal.firefox.com/success.txt|Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"
)
PROBES_EXTRA=(
  "http://connectivitycheck.gstatic.com/gen_204|Dalvik/2.1.0"
  "http://captive.apple.com/library/test/success.html|CaptiveNetworkSupport-355.60.2 wispr"
  "http://www.msftconnecttest.com/redirect|Microsoft NCSI"
)

chain_probe_checks() { # chain_probe_checks NS PREFIX : the six URLs the shipped nginx handles must 302 to the portal
  local ns="$1" pre="$2" entry url ua r code loc bad_list="" n=0
  for entry in "${PROBES[@]}"; do
    url="${entry%%|*}"; ua="${entry#*|}"; n=$((n + 1))
    r="$(ns_http "$ns" "$url" -A "$ua")"; code="${r%%|*}"; loc="$(echo "$r" | cut -d'|' -f2)"
    if [ "$code" != 302 ] || [ "$loc" != "http://$AP_ADDR/" ]; then bad_list="$bad_list [$url -> $code $loc]"; fi
  done
  if [ -z "$bad_list" ]; then ok "$pre-probes-302" "$n probe URLs (iOS, Windows x2, Android, Firefox x2) answered 302 to http://$AP_ADDR/ by name through the catch-all DNS"
  else bad "$pre-probes-302" "unexpected answers:$bad_list"; fi
  local extra=""
  for entry in "${PROBES_EXTRA[@]}"; do
    url="${entry%%|*}"; ua="${entry#*|}"
    r="$(ns_http "$ns" "$url" -A "$ua")"; extra="$extra ${url##*/}=${r%%|*}"
  done
  note "$pre-probes-extra" "probe paths the shipped nginx has no rule for (served by the portal fallback):$extra"
}

aaaa_is_nodata() { # aaaa_is_nodata "status: X"
  if [ "$1" = 'status: NOERROR' ]; then echo 'AAAA is NOERROR with no answer (NODATA)'
  else echo "AAAA for a name under the catch-all address=/#/ answers '$1' ($(dnsmasq -v 2>&1 | head -1 | cut -c1-28)) with no-resolv, not NODATA"; return 1; fi
}

# l3_stack PREFIX AP_IF NS STA_IF : everything above the radio link, shared by the Wi-Fi chain and the radio-free veth variant:
# dnsmasq DHCP + catch-all DNS on the AP interface, a lease in the namespace, the real setup_service.py under gunicorn
# (127.0.0.1:5000 as the unit, plus the AP address on 8081), nginx with the shipped site config and the captive-portal probes.
l3_stack() {
  local pre="$1" AP="$2" ns="$3" S1="$4" t1 lease r a aaaa
  cat > "$W/dnsmasq.conf" <<DNS
interface=$AP
bind-interfaces
except-interface=lo
dhcp-range=$AP_NET.10,$AP_NET.50,255.255.255.0,12h
dhcp-option=3,$AP_ADDR
dhcp-option=6,$AP_ADDR
no-resolv
no-poll
address=/#/$AP_ADDR
dhcp-leasefile=$W/dnsmasq.leases
pid-file=$W/dnsmasq.pid
log-dhcp
log-facility=$LOGD/dnsmasq.log
DNS
  dnsmasq -C "$W/dnsmasq.conf" > "$LOGD/dnsmasq-start.log" 2>&1
  if wait_for 15 sh -c "[ -s '$W/dnsmasq.pid' ] && kill -0 \"\$(cat '$W/dnsmasq.pid')\""; then ok "$pre-dnsmasq-up" "dnsmasq pid $(cat "$W/dnsmasq.pid" 2>/dev/null) bound to $AP ($AP_ADDR)"; else bad "$pre-dnsmasq-up" "dnsmasq did not start: $(head -3 "$LOGD/dnsmasq-start.log")"; return 1; fi
  t1=$SECONDS
  lease="$(sta_dhcp "$ns" "$S1")"
  if [ -n "$lease" ]; then ok "$pre-dhcp" "lease in $(since "$t1")s: $lease (ip router dns)"; else bad "$pre-dhcp" "no lease: $(tail -3 "$LOGD/udhcpc-$ns.log" | tr '\n' ' ')"; return 1; fi
  if grep -q "$(ip netns exec "$ns" cat "/sys/class/net/$S1/address")" "$W/dnsmasq.leases" 2>/dev/null; then ok "$pre-lease-file" "dnsmasq lease file lists the station MAC: $(cut -d' ' -f2-4 "$W/dnsmasq.leases" | head -1)"; else bad "$pre-lease-file" "station MAC not in $W/dnsmasq.leases"; fi
  a="$(ip netns exec "$ns" dig +short +time=5 +tries=1 A catch-all.example.test "@$AP_ADDR" 2>&1 | head -1)"
  aaaa="$(ip netns exec "$ns" dig +noall +comments +time=5 +tries=1 AAAA catch-all.example.test "@$AP_ADDR" 2>&1 | grep -a -o 'status: [A-Z]*' | head -1)"
  if [ "$a" = "$AP_ADDR" ]; then ok "$pre-dns-a" "any name resolves to $AP_ADDR through the catch-all (A)"; else bad "$pre-dns-a" "A answer: '$a'"; fi
  if ip netns exec "$ns" dig +short +time=5 +tries=1 AAAA catch-all.example.test "@$AP_ADDR" 2>&1 | grep -q .; then bad "$pre-dns-aaaa" "AAAA answered ($aaaa)"; else ok "$pre-dns-aaaa" "AAAA has no answer record ($aaaa)"; fi
  # Design report 02 assumed dnsmasq answers NODATA (NOERROR, empty) for AAAA here. A REFUSED is a failure to a dual-stack
  # phone's resolver, which then waits or retries.
  known "$pre-dns-aaaa-nodata" N1 aaaa_is_nodata "$aaaa"
  t1=$SECONDS
  gunicorn_start
  if wait_for 120 http_up "$ns" "http://$AP_ADDR:8081/health"; then ok "$pre-portal-up" "setup_service.py under gunicorn answers on $AP_ADDR:8081 after $(since "$t1")s"; else bad "$pre-portal-up" "no answer from the portal: $(tail -5 "$LOGD/gunicorn-error.log" "$LOGD/gunicorn-start.log" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"; return 1; fi
  r="$(ns_http "$ns" "http://$AP_ADDR:8081/health")"; if [ "${r%%|*}" = 200 ]; then ok "$pre-portal-health" "GET /health -> $r"; else bad "$pre-portal-health" "GET /health -> $r"; fi
  r="$(ns_body "$ns" "http://$AP_ADDR:8081/api/status")"
  if echo "$r" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "setup_complete" in d' 2>/dev/null; then ok "$pre-portal-status" "GET /api/status is JSON with setup_complete: $(echo "$r" | tr -d '\n ' | cut -c1-120)"; else bad "$pre-portal-status" "GET /api/status -> $(echo "$r" | head -c 200)"; fi
  r="$(ns_http "$ns" "http://$AP_ADDR:8081/api/health")"
  note "$pre-portal-api-health" "GET /api/health -> ${r%%|*} (the portal page polls this path; 404 means the poll never works, defect U1)"
  if nginx_start; then
    ok "$pre-nginx-up" "nginx started with the shipped site config (include /etc/nginx/sites-available/setup-portal)"
    chain_probe_checks "$ns" "$pre"
    r="$(ns_http "$ns" "http://$AP_ADDR/")"; case "$r" in 200\|*text/html*) ok "$pre-portal-page" "GET / via nginx -> $r" ;; *) bad "$pre-portal-page" "GET / via nginx -> $r" ;; esac
    r="$(ns_body "$ns" "http://$AP_ADDR/api/status")"
    if echo "$r" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then ok "$pre-nginx-proxy" "GET /api/status via nginx -> backend (127.0.0.1:5000)"; else bad "$pre-nginx-proxy" "GET /api/status via nginx -> $(echo "$r" | head -c 160)"; fi
  else bad "$pre-nginx-up" "nginx -t/start failed: $(tail -3 "$LOGD/nginx-test.log" | tr '\n' ' ')"; fi
  return 0
}

# Scenario: veth  (no radios at all: the same L3 stack over a veth pair; runs on any Linux with the tools, no mac80211_hwsim)
scenario_veth() {
  SECRETS=()
  hw_unload
  install_payload > /dev/null 2>&1 || { bad veth-payload "the payload could not be installed from $PAYLOAD_SRC"; return; }
  ip link add vap0 type veth peer name vphone0 2>"$LOGD/veth.err" || { skip veth "cannot create a veth pair here: $(head -1 "$LOGD/veth.err")"; return; }
  [ "$HAVE_NM" = 1 ] && nm_unmanage vap0 vphone0
  ip netns add phone && ip link set vphone0 netns phone && ip netns exec phone ip link set lo up && ip netns exec phone ip link set vphone0 up
  ip addr add "$AP_ADDR/24" dev vap0 && ip link set vap0 up
  if l3_stack veth vap0 phone vphone0; then :; fi
  save_artifacts
  local p
  stop_gunicorn
  known veth-gunicorn-stops-quickly H2 gunicorn_stops_fast
  for p in dnsmasq nginx; do [ -s "$W/$p.pid" ] && kill "$(cat "$W/$p.pid")" 2>/dev/null; done
  wait_for 20 no_proc "$W/"
  ip link del vap0 2>/dev/null; ip netns del phone 2>/dev/null; rm -rf /etc/netns/phone
  if ip link show vap0 >/dev/null 2>&1 || [ -n "$(ip netns list)" ] || ! no_proc "$W/"; then bad veth-down "veth, namespace or a process is left"; else ok veth-down "veth pair, namespace and daemons are gone"; fi
}

scenario_chain() {
  local t=$SECONDS t1 ssid psk wrong cc lease
  SECRETS=()
  hw_unload
  install_payload > /dev/null 2>&1 || { bad chain-payload "the payload could not be installed from $PAYLOAD_SRC"; return; }
  if ! hw_load 3; then bad chain-hwsim-load "radios=3 did not come up: $(cat "$LOGD/modprobe.out")"; return; fi
  hw_map
  local AP="${IFN[0]}" S1="${IFN[1]}" S1P="${PHN[1]}" S2="${IFN[2]}"
  [ -n "$S2" ] || { bad chain-radios "need 3 radios, found ${IFN[*]}"; return; }
  ssid="CI-HWSIM-$(rand_alnum 4)"; psk="$(rand_alnum 20)"; wrong="$(rand_alnum 20)"
  SECRETS=("$psk" "$wrong")
  # NetworkManager sees the radios first (as on a real boot), then the chain takes them away from it
  hw_settle
  NM_OK=0
  if [ "$HAVE_NM" = 1 ]; then
    if wait_for 120 nm_manages 3; then NM_OK=1; ok chain-nm-manages-radios "after udev settled, NetworkManager manages the 3 radios (${IFN[*]}): $(nmcli -t -f DEVICE,STATE device | grep '^wlan' | tr '\n' ' ')($(since "$t")s in)"
    else bad chain-nm-manages-radios "NetworkManager does not manage the radios after $((120 * TIME_SCALE))s: $(nmcli -t -f DEVICE,STATE device | grep '^wlan' | tr '\n' ' ') (udev backlog on a slow guest?); the NM restore checks are skipped"; fi
    nm_unmanage "$AP" "$S1" "$S2"; sleep 1
    [ "$(nm_state_of "$AP")" = unmanaged ] && ok chain-nm-unmanaged "$AP unmanaged by 'nmcli device set $AP managed no' (the payload's own mechanism)" || bad chain-nm-unmanaged "$AP is $(nm_state_of "$AP") after managed no"
  fi
  # --- AP ---------------------------------------------------------------------------------------------------------
  mkdir -p "$W/hostapd-ctrl" "$W/wpa-ctrl"
  (umask 077; gen_hostapd_conf "$AP" "$ssid" "$psk" 6 > "$W/hostapd.conf")
  cp "$W/hostapd.conf" "$ART/hostapd.conf.generated"; sed -i "s|^wpa_passphrase=.*|wpa_passphrase=<secret>|" "$ART/hostapd.conf.generated"
  t1=$SECONDS
  hostapd -B -P "$W/hostapd.pid" -f "$LOGD/hostapd.log" -dd -t "$W/hostapd.conf" > "$LOGD/hostapd-start.log" 2>&1
  if wait_for 30 hostapd_enabled "$AP"; then ok chain-ap-up "hostapd ENABLED on $AP in $(since "$t1")s (SSID $ssid, WPA2-PSK CCMP, regdom $(regdom))"; else bad chain-ap-up "hostapd on $AP not ENABLED: $(tail -3 "$LOGD/hostapd.log" "$LOGD/hostapd-start.log" 2>/dev/null | tr '\n' ' ')"; save_artifacts; return; fi
  local info; info="$(iw dev "$AP" info 2>&1)"
  echo "$info" > "$ART/iw-ap-info.txt"
  echo "$info" | grep -q 'type AP' && echo "$info" | grep -q "ssid $ssid" && echo "$info" | grep -q 'channel 6 ' \
    && ok chain-ap-iw "iw dev $AP info: type AP, ssid $ssid, channel 6" || bad chain-ap-iw "$(echo "$info" | tr '\n' ' ' | cut -c1-250)"
  ip addr add "$AP_ADDR/24" dev "$AP" 2>/dev/null; ip link set "$AP" up
  # --- station namespace ------------------------------------------------------------------------------------------
  if ns_add phone "$S1P" "$S1"; then ok chain-netns "radio $S1P/$S1 moved into network namespace 'phone' (iw phy $S1P set netns name phone)"; else bad chain-netns "could not move $S1P into netns phone"; save_artifacts; return; fi
  # wrong key first: it must not associate
  gen_wpa_conf "$ssid" "$wrong" > "$W/wpa-wrong.conf"; chmod 600 "$W/wpa-wrong.conf"
  sta_start phone "$S1" "$W/wpa-wrong.conf" "$LOGD/wpa-wrong.log"
  if wait_for 45 grep -q -E 'WRONG_KEY|4-Way Handshake failed|CTRL-EVENT-SSID-TEMP-DISABLED' "$LOGD/wpa-wrong.log"; then
    if sta_completed phone "$S1" || sta_authorized "$AP"; then bad chain-wrong-psk "a station with the wrong passphrase reached COMPLETED/AUTHORIZED"
    else ok chain-wrong-psk "wrong passphrase refused: $(grep -a -o -m1 -E 'reason=WRONG_KEY|4-Way Handshake failed|SSID-TEMP-DISABLED' "$LOGD/wpa-wrong.log" | head -1), never COMPLETED, AP shows no authorized station"; fi
  else bad chain-wrong-psk "no handshake failure seen in 45s; state $(sta_state phone "$S1")"; fi
  sta_stop phone
  # right key: 4-way handshake
  gen_wpa_conf "$ssid" "$psk" > "$W/wpa-right.conf"; chmod 600 "$W/wpa-right.conf"
  t1=$SECONDS
  sta_start phone "$S1" "$W/wpa-right.conf" "$LOGD/wpa-right.log"
  if wait_for 90 sta_completed phone "$S1"; then ok chain-assoc "wpa_supplicant COMPLETED on $S1 in $(since "$t1")s (WPA2-PSK 4-way handshake)"; else bad chain-assoc "wpa_state $(sta_state phone "$S1") after 90s: $(grep -a -E 'CTRL-EVENT' "$LOGD/wpa-right.log" | tail -3 | cut -c1-160 | tr '\n' ' ')"; save_artifacts; return; fi
  wait_for 15 sta_authorized "$AP" && ok chain-ap-sees-sta "hostapd_cli all_sta: $(hostapd_cli -p "$W/hostapd-ctrl" -i "$AP" all_sta 2>/dev/null | grep -a -m1 -o 'flags=[^ ]*')" || bad chain-ap-sees-sta "no AUTHORIZED station on the AP"
  grep -a -q 'pairwise key handshake completed (RSN)' "$LOGD/hostapd.log" && ok chain-4way "hostapd log: pairwise key handshake completed (RSN)" || bad chain-4way "no 'pairwise key handshake completed' line in the hostapd log"
  # --- everything above the radio link: DHCP, DNS, portal, probes ---------------------------------------------------
  l3_stack chain "$AP" phone "$S1" || { save_artifacts; return; }
  # --- secrets never leaked ----------------------------------------------------------------------------------------
  local leak=""
  { ps -eo args= | grep -F -e "$psk" -e "$wrong" | grep -v grep; } > /dev/null 2>&1 && leak="$leak ps-args"
  grep -rlF -e "$psk" -e "$wrong" "$LOGD" "$RES" 2>/dev/null | grep -q . && leak="$leak logs"
  dmesg 2>/dev/null | grep -qF -e "$psk" -e "$wrong" && leak="$leak dmesg"
  [ -z "$leak" ] && ok chain-psk-not-leaked "neither passphrase appears in ps args, the debug logs of hostapd/wpa_supplicant/dnsmasq/gunicorn/nginx, dmesg or the results" || bad chain-psk-not-leaked "found in:$leak"
  save_artifacts
  # --- teardown and restore ------------------------------------------------------------------------------------------
  chain_teardown "$AP"
}

chain_teardown() { # chain_teardown APIF
  local ap="$1" p
  stop_gunicorn
  known chain-gunicorn-stops-quickly H2 gunicorn_stops_fast
  for p in wpa-phone hostapd dnsmasq nginx; do
    if [ -s "$W/$p.pid" ]; then kill "$(cat "$W/$p.pid")" 2>/dev/null; fi
  done
  pkill -f "wpa_supplicant.*$W/" 2>/dev/null
  wait_for 20 no_proc "$W/"
  ip addr flush dev "$ap" 2>/dev/null
  ip netns del phone 2>/dev/null
  rm -rf /etc/netns/phone
  local left; left="$(pgrep -af "$W/" | grep -v -E 'pgrep|guest-hotspot-test' | cut -c1-120)"
  [ -z "$left" ] && ok chain-down-procs "no process of the chain is left (hostapd, wpa_supplicant, dnsmasq, gunicorn, nginx)" || bad chain-down-procs "still running: $left"
  ip -4 -o addr | grep -qF " $AP_NET." && bad chain-down-addr "an address in $AP_NET.0/24 is still on: $(ip -4 -o addr | grep -F " $AP_NET." | awk '{print $2, $4}' | tr '\n' ' ')" || ok chain-down-addr "no $AP_NET.0/24 address left on any interface"
  [ -z "$(ip netns list)" ] && ok chain-down-netns "no network namespace left" || bad chain-down-netns "namespaces left: $(ip netns list | tr '\n' ' ')"
  if wait_for 15 ip link show "${IFN[1]}"; then ok chain-down-radio-returns "the station radio ${IFN[1]} is back in the root namespace after the namespace was deleted"; else bad chain-down-radio-returns "${IFN[1]} did not return to the root namespace"; fi
  local lp; lp="$(ss -H -ltnu 2>/dev/null | awk '{print $5}' | grep -E "^(\*|0\.0\.0\.0|\[::\]|192\.168\.99\.1|127\.0\.0\.1):(80|67|5000|8081)$|^192\.168\.99\.1:53$" | tr '\n' ' ')"
  [ -z "$lp" ] && ok chain-down-ports "nothing listens on 80, 67, 5000 or 8081, nor on $AP_ADDR:53 (systemd-resolved's own 127.0.0.53:53 is not ours)" || bad chain-down-ports "still listening: $lp"
  if [ "$HAVE_NM" = 1 ] && [ "${NM_OK:-0}" = 1 ]; then
    local i
    hw_settle
    for i in "${IFN[@]}"; do nmcli device set "$i" managed yes >/dev/null 2>&1; done
    local st
    if wait_for 60 nm_all_managed "${IFN[@]}"; then ok chain-down-nm-managed "NetworkManager manages all radios again after 'nmcli device set <if> managed yes': $(for i in "${IFN[@]}"; do echo -n "$i=$(nm_state_of "$i") "; done)"
    else bad chain-down-nm-managed "NetworkManager still has an unmanaged radio after 'managed yes': $(for i in "${IFN[@]}"; do echo -n "$i=$(nm_state_of "$i") "; done)"; fi
    nm_running && ok chain-down-nm-active "NetworkManager is still running ($(nmcli -t -f STATE general))" || bad chain-down-nm-active "NetworkManager stopped"
    snapshot after
    # the lines of the snapshot that describe things we did not touch must be identical
    if diff <(sed -n '/^--- ip -br addr/,/^--- netns/p;/^--- listening/,/^--- processes/p' "$ART/snap-before") <(sed -n '/^--- ip -br addr/,/^--- netns/p;/^--- listening/,/^--- processes/p' "$ART/snap-after") > "$ART/snap-diff.txt" 2>&1; then
      ok chain-down-snapshot "addresses and listening sockets of the non-Wi-Fi world are identical before and after"
    else bad chain-down-snapshot "differs: $(head -6 "$ART/snap-diff.txt" | tr '\n' ' ' | cut -c1-300)"; fi
  elif [ "$HAVE_NM" = 1 ]; then skip chain-down-nm-managed "NetworkManager never managed the radios in this run (see chain-nm-manages-radios)"
  fi
}

# ----------------------------------------------------------------------------------------------------------------
# Scenario: legacy  (the CURRENT payload scripts as characterization; defect ids are from 02-hotspot-design.md)
# ----------------------------------------------------------------------------------------------------------------
unit_active() { [ "$(systemctl is-active "$1" 2>/dev/null)" = active ]; }
unit_inactive() { ! unit_active "$1"; }
conf_val() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
shim_docker_install() { # records `docker stop traefik`; lets the script's guard (docker ps | grep traefik) match
  rm -f "$W/docker-calls"
  cat > /usr/local/bin/docker <<'SHIM'
#!/bin/sh
echo "$*" >> /run/hwsim/docker-calls
case "$1" in ps) echo "0123456789ab traefik:v3 /entrypoint.sh traefik" ;; esac
exit 0
SHIM
  chmod 755 /usr/local/bin/docker
}
shim_docker_remove() { rm -f /usr/local/bin/docker; }
static_iface_exists() {
  local c=/etc/hostapd/hostapd-setup.conf i
  [ -f "$c" ] || { echo "no static hostapd config is shipped, so no interface name is pinned"; return 0; }
  i="$(conf_val "$c" interface)"
  [ -z "$i" ] && { echo "the static config names no interface"; return 0; }
  if [ -e "/sys/class/net/$i" ]; then echo "interface=$i exists"; else echo "interface=$i does not exist (this machine has: $(for d in /sys/class/net/wl*; do basename "$d"; done | tr '\n' ' '))"; return 1; fi
}
# The configs that are actually in use, taken from the running processes, so a payload that renders them somewhere else
# (for example under /run) is still checked.
running_hostapd_conf() { pgrep -a hostapd 2>/dev/null | grep -v -F -e "$W/" -e pgrep | head -1 | awk '{print $NF}'; }   # not the home-router hostapd of this run
running_dnsmasq_conf() { pgrep -a dnsmasq 2>/dev/null | grep -v -F -e "$W/" | head -1 | grep -o -E -- '(-C |--conf-file=)[^ ]+' | head -1 | sed -E 's/^(-C |--conf-file=)//'; }
# static_unit_runs: start hostapd-setup.service as the boot-enabled unit would (static config, pinned interface) and watch it
# for up to 40s (scaled): a hostapd that cannot open its interface dies, systemd restarts it every 5s forever (H4).
static_unit_runs() {
  local i=0 n err
  while [ "$i" -lt $((40 * TIME_SCALE)) ]; do
    n="$(systemctl show -p NRestarts --value hostapd-setup.service 2>/dev/null)"
    err="$(journalctl -u hostapd-setup.service --no-pager 2>/dev/null | grep -a -m1 -E 'Could not|does not exist|No such device|failed|Failed' | cut -c1-160)"
    if [ "${n:-0}" -ge 1 ] || [ -n "$err" ]; then
      echo "restart loop: NRestarts=${n:-0}, state $(systemctl is-active hostapd-setup.service); journal: ${err:-none}"; return 1
    fi
    sleep 1; i=$((i + 1))
  done
  echo "unit stayed active and was not restarted for $i s"
}
# foreign_profile_untouched MARK: the ethernet profile "Wired connection 1" survived a POST /api/configure for an SSID of that
# name AND the backend log (lines after MARK) shows no attempt to delete it. On a slow guest the backend's 5s delete can time
# out, so the log, not only the final state, is the evidence.
foreign_profile_untouched() {
  local mark="$1" tried nmstate
  tried="$(tail -n +$((mark + 1)) /var/log/setup-backend.log 2>/dev/null | grep -a -E 'Deleted existing connection profile Wired connection 1|Failed to delete connection profile Wired connection 1|Failed to cleanup connection profiles for Wired connection 1' | head -1 | cut -c1-200)"
  if [ -n "$tried" ]; then echo "POST /api/configure with ssid='Wired connection 1' went for the ethernet profile of that name: $tried"; return 1; fi
  nmstate="$(systemctl is-active NetworkManager 2>/dev/null)"
  # The backend runs `netplan apply` (10s timeout) first; on a slow machine that kills netplan after it stopped NetworkManager.
  [ "$nmstate" = active ] || { systemctl start NetworkManager 2>/dev/null; wait_for 120 nm_running || { echo "NetworkManager was $nmstate after the POST and did not come back"; return 2; }; }
  if nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep -q '^Wired connection 1:.*ethernet'; then echo "ethernet profile kept, no delete attempt in the backend log"; return 0; fi
  echo "the ethernet profile 'Wired connection 1' is gone after POST /api/configure"; return 1
}
regdom_restored() { # regdom_restored BEFORE
  local now; now="$(regdom)"
  if [ "$now" = "$1" ]; then echo "regulatory domain back to $1"
  else echo "the regulatory domain is still $now after the AP was stopped (it was $1 before); it is global and applies to every radio"; return 1; fi
}
legacy_ap_up() { unit_active hostapd-setup.service && unit_active dnsmasq-setup.service; }
iw_is_ap() { iw dev "$1" info 2>/dev/null | grep -q 'type AP'; }

scenario_legacy() {
  local t=$SECONDS t1 ap s1 s1p s2 s2p home_ssid home_psk reg0
  SECRETS=()
  hw_unload
  note legacy-payload "$(install_payload 2>&1 | tail -1)"
  [ -f /opt/setup-backend/setup_service.py ] || { bad legacy-payload "the payload is not in the guest"; return; }
  systemctl is-active --quiet dnsmasq.service && note legacy-distro-dnsmasq "the distro dnsmasq.service is ACTIVE and holds port 53; dnsmasq-setup will fail to bind" || note legacy-distro-dnsmasq "the distro dnsmasq.service is $(systemctl is-active dnsmasq.service 2>&1)"
  if ! hw_load 3; then bad legacy-hwsim-load "radios=3: $(cat "$LOGD/modprobe.out")"; return; fi
  hw_map; ap="${IFN[0]}"; s1="${IFN[1]}"; s1p="${PHN[1]}"; s2="${IFN[2]}"; s2p="${PHN[2]}"
  reg0="$(regdom)"
  hw_settle
  if [ "$HAVE_NM" = 1 ]; then
    wait_for 120 nm_manages 3 || bad legacy-nm-manages-radios "NetworkManager does not manage the radios: $(nmcli -t -f DEVICE,STATE device | grep '^wlan' | tr '\n' ' ')"
    nm_unmanage "$s1" "$s2"; sleep 1
  fi
  # A machine with ONE radio ($ap, in the root namespace); the phone and the home router live in their own namespaces.
  ns_add phone "$s1p" "$s1" || { bad legacy-netns "cannot move $s1p to netns phone"; return; }
  ns_add home "$s2p" "$s2" || { bad legacy-netns "cannot move $s2p to netns home"; return; }
  home_ssid="HomeNet-$(rand_alnum 4)"; home_psk="$(rand_alnum 20)"; SECRETS=("$home_psk")
  mkdir -p "$W/hostapd-home-ctrl" "$W/hostapd-ctrl" "$W/wpa-ctrl"
  (umask 077; HAPD_CTRL="$W/hostapd-home-ctrl" gen_hostapd_conf "$s2" "$home_ssid" "$home_psk" 1 > "$W/hostapd-home.conf")
  ip netns exec home hostapd -B -P "$W/hostapd-home.pid" -f "$LOGD/hostapd-home.log" -dd -t "$W/hostapd-home.conf" > "$LOGD/hostapd-home-start.log" 2>&1
  if wait_for 30 sh -c "[ \"\$(hostapd_cli -p '$W/hostapd-home-ctrl' -i '$s2' status 2>/dev/null | sed -n 's/^state=//p')\" = ENABLED ]"; then ok legacy-home-router "a 'home router' AP ($home_ssid, channel 1) is up on $s2 in namespace home"; else bad legacy-home-router "home router hostapd not ENABLED: $(tail -2 "$LOGD/hostapd-home.log" | tr '\n' ' ')"; fi
  note legacy-machine "one radio in the root namespace: $(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep wifi | tr '\n' ' '); regdom before: $reg0"
  # --- the shipped static config, as the boot-enabled unit would run it ------------------------------------------------
  known legacy-static-conf-names-a-real-interface L2 static_iface_exists
  systemctl start hostapd-setup.service 2>/dev/null
  known legacy-static-ap-unit-runs-here L2 static_unit_runs
  systemctl stop hostapd-setup.service 2>/dev/null; systemctl reset-failed hostapd-setup.service 2>/dev/null
  # --- the monitor decides there is no network and starts the AP -------------------------------------------------------
  shim_docker_install
  : > "$W/legacy-monitor-start"
  t1=$SECONDS
  systemctl start setup-network-monitor.service
  if wait_for 300 legacy_ap_up; then
    note legacy-monitor-trigger "no network: the monitor started the AP $(since "$t1")s after it was started (grace 45s, check every 3s)"
  else
    bad legacy-monitor-trigger "the monitor did not bring the AP up within $((300 * TIME_SCALE))s; falling back to running the start script by hand"
    journalctl -b --no-pager -t setup-network-monitor 2>/dev/null | tail -5 | cut -c1-160 | sed 's/^/CI-HWSIM-TEST legacy-monitor-log INFO /' | while IFS= read -r l; do console "$l"; done
    PATH="$PATH" /usr/local/bin/setup-device-hotspot-start.sh > "$LOGD/legacy-start.out" 2>&1; note legacy-start-script-fallback "setup-device-hotspot-start.sh exit $?"
  fi
  wait_for 60 iw_is_ap "$ap"
  local conf dconf ssid psk
  conf="$(running_hostapd_conf)"; [ -f "$conf" ] || conf=/etc/hostapd/hostapd-setup.conf
  dconf="$(running_dnsmasq_conf)"; [ -f "$dconf" ] || dconf=/etc/dnsmasq.d/setup-portal.conf
  note legacy-config-paths "hostapd runs with $conf, dnsmasq with $dconf"
  cp "$conf" "$ART/legacy-hostapd.conf.generated"; sed -i 's|^wpa_passphrase=.*|wpa_passphrase=<constant>|' "$ART/legacy-hostapd.conf.generated"
  cp "$dconf" "$ART/legacy-dnsmasq.conf.generated" 2>/dev/null
  ssid="$(conf_val "$conf" ssid)"; psk="$(conf_val "$conf" wpa_passphrase)"
  # does the ctrl socket exist? the shipped config has no ctrl_interface (R3): detect AP state with iw instead
  local info; info="$(iw dev "$ap" info 2>&1)"; echo "$info" > "$ART/legacy-iw-ap-info.txt"
  echo "$info" | grep -q 'type AP' && echo "$info" | grep -q "ssid $ssid" && ok legacy-ap-up "legacy AP on $ap: $(echo "$info" | grep -E 'ssid|channel' | tr -s ' \t' ' ' | tr '\n' ' ')" || bad legacy-ap-up "iw dev $ap info: $(echo "$info" | tr '\n' ' ' | cut -c1-220)"
  case "$ssid" in Companion-Setup-????) ok legacy-ssid-format "SSID $ssid" ;; *) bad legacy-ssid-format "SSID '$ssid'" ;; esac
  if [ "$(conf_val "$conf" interface)" = "$ap" ] && [ "$(conf_val "$dconf" interface)" = "$ap" ]; then ok legacy-config-follows-interface "the start script configured hostapd and dnsmasq for $ap (not the pinned wlp192s0)"; else bad legacy-config-follows-interface "hostapd interface=$(conf_val "$conf" interface), dnsmasq interface=$(conf_val "$dconf" interface), machine radio $ap"; fi
  ip -4 -o addr show dev "$ap" | grep -q "192.168.99.1/24" && ok legacy-ap-address "$ap has 192.168.99.1/24" || bad legacy-ap-address "$(ip -4 -o addr show dev "$ap" | tr '\n' ' ')"
  # prescan: the home router must be in the cached list (iw scan before the AP existed)
  if [ -s /var/lib/setup-device/last-scan.json ]; then
    cp /var/lib/setup-device/last-scan.json "$ART/legacy-last-scan.json"
    grep -q "$home_ssid" /var/lib/setup-device/last-scan.json && ok legacy-prescan-sees-router "setup-device-prescan.py cached '$home_ssid' (real iw scan output under hwsim): $(tr -d '\n ' < /var/lib/setup-device/last-scan.json | cut -c1-160)" || bad legacy-prescan-sees-router "last-scan.json lacks $home_ssid: $(tr -d '\n ' < /var/lib/setup-device/last-scan.json | cut -c1-200)"
  else bad legacy-prescan-sees-router "no /var/lib/setup-device/last-scan.json was written"; fi
  note legacy-regdom-after "regdom before the AP: $reg0, after: $(regdom) (hostapd country_code=$(conf_val "$conf" country_code))"
  # desired behaviours that do not hold today
  known legacy-psk-not-a-public-constant S2 sh -c "[ '$psk' != SetupDevice123 ] && echo 'per-device passphrase' || { echo 'passphrase is the committed constant SetupDevice123'; exit 1; }"
  known legacy-hostapd-conf-private H3 sh -c "m=\$(stat -c %a $conf); [ \"\$m\" -le 600 ] && echo \"mode \$m\" || { echo \"$conf is mode \$m and holds the passphrase\"; exit 1; }"
  known legacy-country-follows-regdom R1 sh -c "c='$(conf_val "$conf" country_code)'; [ -z \"\$c\" ] || [ \"\$c\" = '$reg0' ] && echo 'country_code omitted or equal to the radio regdom' || { echo \"country_code=\$c hard-coded, the radio regdom was $reg0\"; exit 1; }"
  known legacy-client-isolation R3 sh -c "grep -q '^ap_isolate=1' $conf && echo ap_isolate=1 || { echo 'no ap_isolate=1: clients of the shared passphrase can reach each other'; exit 1; }"
  known legacy-ccmp-only R3 sh -c "grep -q '^wpa_pairwise=.*TKIP' $conf && { echo \"\$(grep '^wpa_pairwise=' $conf) lists TKIP\"; exit 1; } || echo 'CCMP only'"
  known legacy-no-traefik-stop L3 sh -c "[ ! -s '$W/docker-calls' ] || ! grep -q 'stop traefik' '$W/docker-calls' && echo 'docker untouched' || { echo \"the script ran: docker \$(grep 'stop' '$W/docker-calls' | head -1)\"; exit 1; }"
  # --- a phone joins with the shipped passphrase, gets a lease, reaches the portal ----------------------------------------
  gen_wpa_conf "$ssid" "$psk" > "$W/wpa-legacy.conf"; chmod 600 "$W/wpa-legacy.conf"
  t1=$SECONDS
  sta_start phone "$s1" "$W/wpa-legacy.conf" "$LOGD/wpa-legacy.log"
  if wait_for 90 sta_completed phone "$s1"; then ok legacy-station-joins "a station associated to $ssid in $(since "$t1")s with the shipped passphrase"; else bad legacy-station-joins "wpa_state $(sta_state phone "$s1")"; fi
  local lease; t1=$SECONDS; lease="$(sta_dhcp phone "$s1")"
  [ -n "$lease" ] && ok legacy-dhcp "dnsmasq-setup leased in $(since "$t1")s: $lease" || bad legacy-dhcp "no lease: $(tail -2 "$LOGD/udhcpc-phone.log" | tr '\n' ' ')"
  systemctl start setup-backend.service
  if wait_for 150 http_up phone "http://$AP_ADDR/api/status"; then
    ok legacy-portal-up "nginx -> setup-backend.service (gunicorn 127.0.0.1:5000) answers GET /api/status"
    local r; r="$(ns_http phone "http://$AP_ADDR/")"; case "$r" in 200\|*text/html*) ok legacy-portal-page "GET / -> $r" ;; *) bad legacy-portal-page "GET / -> $r" ;; esac
    chain_probe_checks phone legacy
    known legacy-api-health-endpoint U1 sh -c "c=\$(ip netns exec phone curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://$AP_ADDR/api/health); [ \"\$c\" = 200 ] && echo 200 || { echo \"GET /api/health -> \$c (the portal page polls it every 5s)\"; exit 1; }"
    # malformed JSON: the handler must answer 400 and leave the AP alone
    local pid0 pid1 ssid1 code
    pid0="$(systemctl show -p MainPID --value hostapd-setup.service)"
    code="$(ip netns exec phone curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X POST -H 'Content-Type: application/json' --data '{broken' "http://$AP_ADDR/api/configure" 2>&1)"
    note legacy-malformed-json-response "POST /api/configure with a malformed JSON body -> HTTP $code"
    sleep 5; wait_for 120 legacy_ap_up
    pid1="$(systemctl show -p MainPID --value hostapd-setup.service)"; ssid1="$(conf_val "$conf" ssid)"
    known legacy-malformed-json-leaves-ap-alone L7 sh -c "[ '$pid0' = '$pid1' ] && [ '$ssid' = '$ssid1' ] && echo 'AP untouched (hostapd pid $pid0)' || { echo \"the AP was restarted by one bad request: hostapd pid $pid0 -> $pid1, SSID $ssid -> $ssid1\"; exit 1; }"
    ssid="$ssid1"
  else
    bad legacy-portal-up "no answer from the portal through nginx after $((150 * TIME_SCALE))s: nginx $(systemctl is-active nginx.service), backend $(systemctl is-active setup-backend.service)"
  fi
  save_artifacts
  # --- what the backend's own stop_hotspot_services() leaves behind -----------------------------------------------------
  wait_for 120 legacy_ap_up || { /usr/local/bin/setup-device-hotspot-start.sh > "$LOGD/legacy-start2.out" 2>&1; }
  sta_stop phone
  ( cd /opt/setup-backend && timeout 90 python3 -c 'import setup_service; setup_service.stop_hotspot_services()' > "$LOGD/stop-hotspot.out" 2>&1 )
  sleep 3
  check legacy-teardown-stops-ap-units sh -c "systemctl is-active hostapd-setup.service dnsmasq-setup.service | grep -qx active && { echo 'a setup unit is still active'; exit 1; } || echo 'hostapd-setup and dnsmasq-setup stopped'"
  known legacy-teardown-restores-regdom R1 regdom_restored "$reg0"
  known legacy-teardown-removes-ap-address L4 sh -c "ip -4 -o addr show dev $ap | grep -q ' 192.168.99.1/' && { echo '192.168.99.1/24 is still on $ap after the AP was stopped'; exit 1; } || echo 'address removed'"
  known legacy-teardown-stops-nginx L4 sh -c "[ \"\$(systemctl is-active nginx.service)\" = active ] && { echo 'nginx still serves the portal on :80 after the AP was stopped'; exit 1; } || echo 'nginx stopped'"
  [ "$HAVE_NM" = 1 ] && known legacy-teardown-returns-radio-to-nm L1 sh -c "s=\$(nmcli -t -f DEVICE,STATE device | awk -F: '\$1==\"$ap\" {print \$2}'); [ \"\$s\" = unmanaged ] && { echo '$ap is still unmanaged by NetworkManager after the AP was stopped'; exit 1; } || echo \"$ap is \$s\""
  # --- a foreign NetworkManager profile named like the posted SSID ------------------------------------------------------------
  if [ "$HAVE_NM" = 1 ] && unit_active setup-backend.service; then
    nmcli connection add type ethernet ifname dummy9 con-name 'Wired connection 1' >/dev/null 2>&1
    if nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep -q '^Wired connection 1:.*ethernet'; then
      local mark; mark="$(wc -l < /var/log/setup-backend.log 2>/dev/null || echo 0)"
      curl -s -o /dev/null --max-time $((60 * TIME_SCALE)) -X POST -H 'Content-Type: application/json' --data '{"ssid":"Wired connection 1","password":"hwsim-test-pass","pairing_code":"AAAAAA"}' http://127.0.0.1:5000/api/configure >/dev/null 2>&1
      wait_for 60 sh -c "tail -n +$((mark + 1)) /var/log/setup-backend.log | grep -a -q -E 'Deleted existing connection profile|Failed to delete connection profile|Failed to cleanup connection profiles|Error creating WiFi|Created NetworkManager connection|Failed to create WiFi'"
      note legacy-configure-nm-after "NetworkManager is $(systemctl is-active NetworkManager 2>/dev/null) after the POST (the backend ran: $(tail -n +$((mark + 1)) /var/log/setup-backend.log 2>/dev/null | grep -a -o -E 'Removing setup-mode netplan configuration|Error removing netplan config[^\n]{0,60}' | head -2 | tr '\n' ';'))"
      known legacy-configure-keeps-foreign-profiles S4 foreign_profile_untouched "$mark"
    else skip legacy-configure-keeps-foreign-profiles "could not create the ethernet test profile"; fi
    wait_for 120 nm_running; nmcli connection delete 'Wired connection 1' >/dev/null 2>&1
  else skip legacy-configure-keeps-foreign-profiles "needs NetworkManager and the backend"; fi
  # --- the reset helper with no argument -------------------------------------------------------------------------------------
  systemctl stop setup-network-monitor.service setup-backend.service 2>/dev/null
  t1=$SECONDS
  timeout 240 /usr/local/bin/setup-hotspot-reset.sh > "$LOGD/legacy-reset.out" 2>&1; local rrc=$?
  local used; used="$(grep -a -m1 'Starting hotspot reset on interface' "$LOGD/legacy-reset.out" | sed 's/.*interface //')"
  note legacy-reset-run "setup-hotspot-reset.sh (no argument) exit $rrc after $(since "$t1")s on interface '$used'"
  known legacy-reset-default-interface-exists L10 sh -c "[ -e '/sys/class/net/$used' ] && echo '$used exists' || { echo \"the helper's default interface '$used' does not exist here (this machine's radio is $ap)\"; exit 1; }"
  # --- cleanup ----------------------------------------------------------------------------------------------------------------------
  systemctl stop setup-network-monitor.service setup-backend.service hostapd-setup.service dnsmasq-setup.service nginx.service 2>/dev/null
  shim_docker_remove
  pkill -f "hostapd.*$W/" 2>/dev/null; pkill -f "wpa_supplicant.*$W/" 2>/dev/null
  cp /var/log/setup-backend.log "$LOGD/setup-backend.log" 2>/dev/null
  save_artifacts
  hw_unload
}

# ----------------------------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------------------------
shell_mode() {
  stty -F /dev/ttyS1 -echo raw 2>/dev/null
  note shell "root shell on ttyS1 (no prompt; send a command, read the output); functions: HWSIM_LIB_ONLY=1 . $IN/guest-hotspot-test.sh"
  # stdout and stderr go through a pipe so bash is not interactive (no readline echo, no prompts, no nested shells)
  while :; do /bin/bash --noprofile --norc 2>&1 < /dev/ttyS1 | cat > /dev/ttyS1; sleep 1; done
}

main() {
  note guest-start "guest test script started, mode=$MODE scenarios=$SCENARIOS time-scale=$TIME_SCALE, $(awk '{print int($1)}' /proc/uptime)s after boot"
  if [ "$MODE" = shell ]; then shell_mode; return; fi
  pre_env
  local s IFS=,
  for s in $SCENARIOS; do
    IFS=' '
    local t=$SECONDS
    case "$s" in
      caps) scenario_caps ;;
      chain) scenario_chain ;;
      veth) scenario_veth ;;
      legacy) scenario_legacy ;;
      *) bad scenario "unknown scenario '$s'" ;;
    esac
    note "scenario-$s" "finished in $(since "$t")s"
    IFS=,
  done
  IFS=' '
  hw_unload
  save_artifacts
  emit DONE "$([ "$NF" = 0 ] && echo PASS || echo FAIL)" "pass=$NP fail=$NF xfail=$NXF xpass=$NXP skip=$NSK in $(since)s"
  sync
  [ -n "${HWSIM_NATIVE:-}" ] && return 0
  echo o > /proc/sysrq-trigger 2>/dev/null
  sleep 5
  systemctl poweroff -f 2>/dev/null
}

if [ -z "${HWSIM_LIB_ONLY:-}" ]; then main; fi
