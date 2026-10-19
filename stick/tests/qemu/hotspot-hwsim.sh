#!/usr/bin/env bash
# Wi-Fi hotspot test on virtual radios: runs the REAL hostapd, wpa_supplicant, dnsmasq, nginx and the setup portal
# (core/headless/payload) against mac80211_hwsim radios inside a QEMU guest booted from a Companion OS ISO, with no
# Wi-Fi hardware. See README-hotspot.md next to this file for what it proves and what it cannot.
#
#   hotspot-hwsim.sh --iso companion-os.iso [--work DIR] [--timeout SECS] [--accel auto|tcg|kvm|hvf]
#                    [--scenarios chain,caps,veth,legacy] [--payload DIR] [--strict-legacy] [--time-scale N]
#                    [--no-trim] [--cpu MODEL] [--mem MIB] [--smp N] [--clean]
#   hotspot-hwsim.sh --iso companion-os.iso --shell     (development: root shell on a unix socket, no tests)
#
# Scenarios: chain (hostapd -> wpa_supplicant -> dnsmasq -> portal -> probes -> teardown), caps (module parameters, iw
# capabilities, regdom, rfkill, a radio without AP mode), veth (the portal stack with no radios), legacy (the CURRENT payload
# scripts as characterization). Under TCG expect about 12 minutes for all four on a quiet machine; run it under `nice`.
#
# How it works (the same technique as docker-live.sh): the kernel and initrd are taken from the ISO and booted with
# the kernel arguments GRUB gives them, plus systemd.run= to start guest-hotspot-test.sh as root INSTEAD of a desktop
# (systemd.wants=multi-user.target pulls the multi-user units, NetworkManager among them, in as a normal boot would).
# The ISO is attached read-only as the CD-ROM. The guest script and the payload ride in on a tar archive written to a
# read-only virtio disk (no xorriso or mkisofs needed); results come back as `CI-HWSIM-TEST <name> <STATUS> <detail>`
# lines on the serial console, and the guest's logs on a second, writable virtio disk that is a tar archive too.
#
# Result statuses: PASS / FAIL for the checks the Wi-Fi chain must satisfy; XFAIL / XPASS for "desired behaviour" checks
# of the CURRENT payload scripts that are known not to hold today (a defect id from 02-hotspot-design.md is in the
# detail); INFO / SKIP are not checks. XFAIL does not fail the run; an XPASS means a stop-gap fix landed, so update
# the baseline table in README-hotspot.md. --strict-legacy makes every XFAIL a FAIL (use it once the fixes are in).
# Exit status 0 only when the guest reached DONE and there is no FAIL (and, if the guest died early, never).
#
# Needs: qemu-system-x86_64, tar, dd, and bsdtar or xorriso (to pull the kernel and initrd out of the ISO).
# macOS bash 3.2 is enough. No root, no network, nothing is written outside --work (a new mktemp dir by default).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

ISO=""; WORK=""; TIMEOUT=900; ACCEL_OPT=auto; SCENARIOS="chain,caps,veth,legacy"; STRICT=0; PAYLOAD="$REPO/core/headless/payload"
CLEAN=0; SHELL_MODE=0; CPU_OPT=""; MEM=4096; SMP=2; TRIM=1; KERNEL=""; INITRD=""; WORK_GIVEN=0; TIME_SCALE=""

usage() { awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "${BASH_SOURCE[0]}"; }
die() { echo "hotspot-hwsim: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="${2:?--iso needs a path}"; shift 2 ;;
    --work) WORK="${2:?--work needs a directory}"; WORK_GIVEN=1; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --accel) ACCEL_OPT="${2:?--accel needs auto|tcg|kvm|hvf}"; shift 2 ;;
    --cpu) CPU_OPT="${2:?--cpu needs a QEMU cpu model}"; shift 2 ;;
    --mem) MEM="${2:?--mem needs MiB}"; shift 2 ;;
    --time-scale) TIME_SCALE="${2:?--time-scale needs a whole number}"; shift 2 ;;
    --smp) SMP="${2:?--smp needs a count}"; shift 2 ;;
    --scenarios) SCENARIOS="${2:?--scenarios needs a comma list}"; shift 2 ;;
    --payload) PAYLOAD="${2:?--payload needs a directory}"; shift 2 ;;
    --kernel) KERNEL="${2:?}"; shift 2 ;;
    --initrd) INITRD="${2:?}"; shift 2 ;;
    --no-trim) TRIM=0; shift ;;
    --strict-legacy) STRICT=1; shift ;;
    --clean) CLEAN=1; shift ;;
    --shell) SHELL_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$ISO" ] || die "--iso PATH is required (try --help)"
[ -r "$ISO" ] || die "cannot read the ISO: $ISO"
case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a number of seconds" ;; esac
case "$SCENARIOS" in *[!a-z,]*|'') die "--scenarios is a comma list of chain,caps,veth,legacy" ;; esac
[ -f "$HERE/guest-hotspot-test.sh" ] || die "guest-hotspot-test.sh is missing next to this script"
[ -d "$PAYLOAD/opt/setup-backend" ] || die "not a payload directory (no opt/setup-backend): $PAYLOAD"

QEMU="$(command -v qemu-system-x86_64 || true)"
if [ -z "$QEMU" ]; then
  for d in /opt/homebrew/bin /usr/local/bin /usr/bin; do [ -x "$d/qemu-system-x86_64" ] && QEMU="$d/qemu-system-x86_64" && break; done
fi
[ -n "$QEMU" ] || die "qemu-system-x86_64 not found (brew install qemu / apt-get install qemu-system-x86)"
for t in tar dd tr grep sed awk; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done

if [ -z "$WORK" ]; then WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-hotspot-hwsim.XXXXXX")" || die "mktemp failed"; fi
mkdir -p "$WORK" || die "cannot create $WORK"
WORK="$(cd "$WORK" && pwd)"
SERIAL="$WORK/serial.log"; RESULTS="$WORK/results.txt"; ART="$WORK/artifacts"
mkdir -p "$ART"

QPID=""; SOCKDIR=""
cleanup() {
  # Kill only the QEMU this script started.
  if [ -n "$QPID" ] && kill -0 "$QPID" 2>/dev/null; then
    kill "$QPID" 2>/dev/null; sleep 1; kill -0 "$QPID" 2>/dev/null && kill -9 "$QPID" 2>/dev/null
  fi
  QPID=""
  [ -n "$SOCKDIR" ] && rm -rf "$SOCKDIR"
}
trap cleanup EXIT
trap 'echo "hotspot-hwsim: interrupted"; exit 130' INT TERM

# --- acceleration ------------------------------------------------------------------
ACCEL=(); ACCEL_NAME=tcg
case "$ACCEL_OPT" in
  tcg) ;;
  kvm) ACCEL=(-accel kvm -cpu host); ACCEL_NAME=kvm ;;
  hvf) ACCEL=(-accel hvf -cpu host); ACCEL_NAME=hvf ;;
  auto)
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL=(-accel kvm -cpu host); ACCEL_NAME=kvm
    elif [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = x86_64 ]; then ACCEL=(-accel hvf -cpu host); ACCEL_NAME=hvf
    fi ;;
  *) die "--accel is auto, tcg, kvm or hvf" ;;
esac
# The guest's waits (association, DHCP, portal start) are multiplied by this; TCG on a busy machine is slow.
[ -n "$TIME_SCALE" ] || { if [ "$ACCEL_NAME" = tcg ]; then TIME_SCALE=2; else TIME_SCALE=1; fi; }
case "$TIME_SCALE" in ''|*[!0-9]*|0) die "--time-scale must be a whole number of at least 1" ;; esac
if [ "$ACCEL_NAME" = tcg ]; then
  # Nehalem, not Haswell: Haswell crashed GNOME Shell and the installer under TCG in earlier work on this ISO. No desktop
  # starts here, so either boots, but one model for every TCG run keeps the timings comparable.
  TCG_ACCEL="tcg,thread=multi"
  ACCEL=(-accel "$TCG_ACCEL" -cpu "${CPU_OPT:-Nehalem}")
fi

# --- kernel and initrd out of the ISO -----------------------------------------------
[ -n "$KERNEL" ] || KERNEL="$WORK/vmlinuz"
[ -n "$INITRD" ] || INITRD="$WORK/initrd"
if [ ! -s "$KERNEL" ] || [ ! -s "$INITRD" ]; then
  if command -v bsdtar >/dev/null 2>&1; then
    ( cd "$WORK" && bsdtar -xf "$ISO" casper/vmlinuz casper/initrd && mv -f casper/vmlinuz vmlinuz && mv -f casper/initrd initrd && rmdir casper ) \
      || die "bsdtar could not extract casper/vmlinuz and casper/initrd from $ISO"
  elif command -v xorriso >/dev/null 2>&1; then
    xorriso -osirrox on -indev "$ISO" -extract /casper/vmlinuz "$WORK/vmlinuz" -extract /casper/initrd "$WORK/initrd" >/dev/null 2>&1 \
      || die "xorriso could not extract the kernel and initrd from $ISO"
  else
    die "need bsdtar or xorriso to read the kernel out of the ISO (or pass --kernel and --initrd)"
  fi
fi
[ -s "$KERNEL" ] && [ -s "$INITRD" ] || die "kernel or initrd is empty"

# --- input archive: guest script, config, payload ------------------------------------
STAGE="$WORK/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE/payload"
cp "$HERE/guest-hotspot-test.sh" "$STAGE/guest-hotspot-test.sh"
# Everything but caches; the payload is copied exactly as it is in the tree under test.
( cd "$PAYLOAD" && tar -cf - --exclude='__pycache__' --exclude='*.pyc' . ) | ( cd "$STAGE/payload" && tar -xf - )
{
  echo "MODE=$([ "$SHELL_MODE" = 1 ] && echo shell || echo test)"
  echo "SCENARIOS=$SCENARIOS"
  echo "STRICT_LEGACY=$STRICT"
  echo "HOST_TIMEOUT=$TIMEOUT"
  echo "TIME_SCALE=$TIME_SCALE"
} > "$STAGE/config.env"
IN="$WORK/in.tar"; OUT="$WORK/out.img"
rm -f "$IN" "$OUT"
# ustar and no AppleDouble files, so GNU tar in the guest reads what bsdtar on a Mac wrote.
( cd "$STAGE" && COPYFILE_DISABLE=1 tar --format ustar -cf "$IN" . ) || die "cannot write $IN"
dd if=/dev/zero of="$OUT" bs=1048576 count=0 seek=64 2>/dev/null || die "cannot create $OUT"

# --- boot ---------------------------------------------------------------------------
# No dollar sign and no percent sign in this string: systemd expands both in ExecStart. The loop waits for the udev
# symlink of the input disk (its virtio serial is CIHWIN); the host timeout ends a boot where it never appears.
BOOT_CMD="udevadm settle --timeout=120; until [ -e /dev/disk/by-id/virtio-CIHWIN ]; do sleep 1; done; mkdir -p /run/hwsim-in; tar -xf /dev/disk/by-id/virtio-CIHWIN -C /run/hwsim-in; exec /bin/bash /run/hwsim-in/guest-hotspot-test.sh"
# Trimmed boot (default): mask units that have nothing to do with Wi-Fi and that cost minutes under TCG on a busy machine
# (snapd seeding, apt timers, the container runtime and its live-session storage, printing, Bluetooth, crash reporting).
# NetworkManager, wpa_supplicant, udev and everything the chain uses stay as shipped. --no-trim boots the full multi-user target.
MASK=""
if [ "$TRIM" = 1 ]; then
  for u in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service snapd.autoimport.service snapd.core-fixup.service \
           snapd.recovery-chooser-trigger.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service \
           motd-news.timer man-db.timer fstrim.timer e2scrub_all.timer update-notifier-download.timer update-notifier-motd.timer \
           ua-timer.timer esm-cache.service unattended-upgrades.service whoopsie.service apport.service packagekit.service \
           cups.service cups.socket cups-browsed.service bluetooth.service docker.service docker.socket containerd.service \
           ci-os-live-container-storage.service ollama.service ci-os-first-boot-setup.service casper-md5check.service \
           cloud-init-local.service cloud-init.service cloud-init-main.service cloud-init-network.service cloud-config.service \
           cloud-final.service kerneloops.service \
           ubuntu-advantage.service plymouth-quit.service plymouth-quit-wait.service setvtrgb.service; do
    MASK="$MASK systemd.mask=$u"
  done
fi
APPEND="console=ttyS0 systemd.show_status=0 systemd.wants=multi-user.target$MASK systemd.run=\"/bin/sh -c '$BOOT_CMD'\""
# x86 Linux silently cuts the command line at 2048 bytes, which would drop systemd.run= and boot a desktop instead.
[ "${#APPEND}" -le 1990 ] || die "the kernel command line is ${#APPEND} bytes (limit 2047): shorten the mask list or use --no-trim"

QARGS=(-machine q35 "${ACCEL[@]}" -m "$MEM" -smp "$SMP"
  -display none -vga none -monitor none -no-reboot -nic none
  -serial "file:$SERIAL")
SOCK=""
if [ "$SHELL_MODE" = 1 ]; then
  # A unix socket path must stay under 104 bytes on macOS, which the work directory usually exceeds.
  SOCKDIR="$(mktemp -d "${TMPDIR:-/tmp}/chw.XXXXXX")"; [ "${#SOCKDIR}" -le 80 ] || { rmdir "$SOCKDIR"; SOCKDIR="$(mktemp -d /tmp/chw.XXXXXX)"; }
  SOCK="$SOCKDIR/s"
  QARGS+=(-serial "unix:$SOCK,server=on,wait=off")
fi
QARGS+=(-kernel "$KERNEL" -initrd "$INITRD" -append "$APPEND"
  -drive "file=$ISO,media=cdrom,readonly=on,format=raw"
  -object "rng-random,filename=/dev/urandom,id=rng0" -device "virtio-rng-pci,rng=rng0"
  -drive "if=none,id=cin,format=raw,readonly=on,file=$IN" -device "virtio-blk-pci,drive=cin,serial=CIHWIN"
  -drive "if=none,id=cout,format=raw,file=$OUT" -device "virtio-blk-pci,drive=cout,serial=CIHWOUT")

: > "$SERIAL"
echo "hotspot-hwsim: work dir $WORK"
echo "hotspot-hwsim: accel $ACCEL_NAME, ${MEM} MiB, ${SMP} cpus, timeout ${TIMEOUT}s, scenarios $SCENARIOS"
START=$SECONDS
"$QEMU" "${QARGS[@]}" > "$WORK/qemu.out" 2>&1 &
QPID=$!
echo "$QPID" > "$WORK/qemu.pid"
echo "hotspot-hwsim: qemu pid $QPID"
if [ "$SHELL_MODE" = 1 ]; then
  echo "hotspot-hwsim: shell mode. The guest opens a root shell on $SOCK once it has booted (about 2 minutes under TCG)."
  echo "  use:  nc -U $SOCK     (type 'poweroff -f' in it, or kill pid $QPID, to end)"
  wait "$QPID"; exit 0
fi

# --- wait, echoing results as they arrive ---------------------------------------------
SEEN=0; DONE=0; TIMED_OUT=0; DONE_AT=0
while kill -0 "$QPID" 2>/dev/null; do
  sleep 2
  if [ -s "$SERIAL" ]; then
    tr -d '\r' < "$SERIAL" | grep -a -o 'CI-HWSIM-TEST .*' > "$WORK/.lines" 2>/dev/null || : > "$WORK/.lines"
    TOTAL="$(wc -l < "$WORK/.lines" | tr -d ' ')"
    if [ "$TOTAL" -gt "$SEEN" ]; then
      sed -n "$((SEEN + 1)),${TOTAL}p" "$WORK/.lines" | cut -c1-200 | sed "s/^/[$((SECONDS - START))s] /"
      SEEN="$TOTAL"
    fi
    if [ "$DONE" = 0 ] && grep -aq '^CI-HWSIM-TEST DONE ' "$WORK/.lines"; then DONE=1; DONE_AT=$SECONDS; fi
  fi
  # After DONE the guest powers itself off; give it 30 s, then stop it.
  if [ "$DONE" = 1 ] && [ $((SECONDS - DONE_AT)) -gt 30 ]; then break; fi
  if [ $((SECONDS - START)) -gt "$TIMEOUT" ]; then TIMED_OUT=1; echo "hotspot-hwsim: TIMEOUT after ${TIMEOUT}s"; break; fi
done
cleanup
ELAPSED=$((SECONDS - START))

# --- collect ---------------------------------------------------------------------------
tr -d '\r' < "$SERIAL" | grep -a -o 'CI-HWSIM-TEST .*' | sed 's/^CI-HWSIM-TEST //' > "$RESULTS"
tar -xf "$OUT" -C "$ART" 2>/dev/null || echo "hotspot-hwsim: no artifact archive on the output disk (the guest never wrote one)"
rm -f "$WORK/.lines"
# The DONE line is the guest's own summary, not a check.
CHECKS="$WORK/.checks"; grep -v '^DONE ' "$RESULTS" > "$CHECKS" || true
npass=$(grep -c '^[^ ]* PASS ' "$CHECKS" || true); nfail=$(grep -c '^[^ ]* FAIL ' "$CHECKS" || true)
nxfail=$(grep -c '^[^ ]* XFAIL ' "$CHECKS" || true); nxpass=$(grep -c '^[^ ]* XPASS ' "$CHECKS" || true)
nskip=$(grep -c '^[^ ]* SKIP ' "$CHECKS" || true)
RC=0
echo
echo "================ Wi-Fi hotspot hwsim summary ================"
grep -E '^[^ ]* (FAIL|XPASS) ' "$CHECKS" | sed 's/^/  /' || true
echo "pass $npass, fail $nfail, xfail $nxfail (known defects, baseline), xpass $nxpass (baseline changed), skip $nskip; ${ELAPSED}s wall, accel $ACCEL_NAME"
if [ "$STRICT" = 1 ] && [ "$nxfail" -gt 0 ]; then echo "strict legacy: $nxfail known-defect check(s) counted as FAIL"; RC=1; fi
[ "$nfail" -gt 0 ] && RC=1
if ! grep -aq '^DONE ' "$RESULTS"; then
  echo "FAIL: the guest never reported DONE ($([ "$TIMED_OUT" = 1 ] && echo "timed out" || echo "qemu exited early")); see $SERIAL"; RC=1
elif ! grep -aq '^DONE PASS' "$RESULTS" && [ "$nfail" = 0 ] && [ "$STRICT" = 0 ]; then
  echo "FAIL: guest reported $(grep -a '^DONE ' "$RESULTS" | head -1)"; RC=1
fi
[ "$npass" -gt 0 ] || { echo "FAIL: no check passed"; RC=1; }
rm -f "$CHECKS"
echo "results: $RESULTS"; echo "serial:  $SERIAL"; echo "logs:    $ART"
if [ "$RC" = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
if [ "$CLEAN" = 1 ] && [ "$RC" = 0 ] && [ "$WORK_GIVEN" = 0 ]; then rm -rf "$WORK"; fi
exit "$RC"
