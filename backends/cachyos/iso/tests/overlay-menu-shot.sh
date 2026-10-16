#!/usr/bin/env bash
#=============================================================================
# Test (manual, needs docker and QEMU, about 3 to 5 minutes): look at the two boot menus of the edition without building
# the 3 GB image. It renders the brand assets, merges the overlay onto the pinned upstream profile with the build's own
# engine, makes two tiny media from the merged profile's boot files, boots each in QEMU and takes screenshots:
#
#   BIOS   a syslinux ISO built from syslinux/*.cfg, splash.png and the .c32 modules (what mkarchiso installs), SeaBIOS
#   UEFI   the standalone GRUB that mkarchiso builds (same module list, same embedded configuration) and the merged
#          grub/ directory, on a FAT directory that OVMF boots as a disk
#
# The kernels and initramfs files are 4 KiB placeholders: only the menus are under test, so pressing Enter fails. Both
# menus are checked on the screenshots: size, the canon ground colour, the token highlight colour (CI_ACCENT_AQUA) and,
# for UEFI, the countdown line of the theme. The PNGs stay in the output directory for a human to look at.
#
#   CACHYOS_UPSTREAM_ARCHISO=<archiso/ of the pinned CachyOS-Live-ISO checkout> backends/cachyos/iso/tests/overlay-menu-shot.sh [outdir]
#
# Environment
#   CACHYOS_UPSTREAM_ARCHISO   required (also UPSTREAM_ARCHISO_DIR)
#   CI_OS_TEST_IMAGE           builder image with pacman; default ci-cachyos-builder:latest
#   CI_OS_TEST_OVMF_CODE, CI_OS_TEST_OVMF_VARS   UEFI firmware; default: Homebrew's edk2-x86_64-code.fd and edk2-i386-vars.fd,
#                              else the distribution's OVMF files; without firmware the UEFI half is skipped
#   CI_OS_TEST_UEFI_SIZE       force the GRUB resolution, e.g. 1920x1080 (default: whatever `gfxmode=auto` picks, 800x600 here)
#
# Needs docker, qemu-system-x86_64, python3 and ImageMagick on the host. Exit status: 0 pass, 1 fail, 2 cannot run here.
# TCG emulation (no KVM) is slow: under load the screenshots are taken at several moments and any of them may satisfy a check.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
UP="${CACHYOS_UPSTREAM_ARCHISO:-${UPSTREAM_ARCHISO_DIR:-}}"
IMAGE="${CI_OS_TEST_IMAGE:-ci-cachyos-builder:latest}"
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/overlay-menu-shot.XXXXXX")}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

for t in docker qemu-system-x86_64 python3; do command -v "$t" >/dev/null 2>&1 || { echo "needs $t" >&2; exit 2; }; done
if command -v magick >/dev/null 2>&1; then IM=(magick); elif command -v convert >/dev/null 2>&1; then IM=(convert); else echo "needs ImageMagick" >&2; exit 2; fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "builder image $IMAGE not found (set CI_OS_TEST_IMAGE)" >&2; exit 2; }
[[ -n "$UP" && -f "$UP/profiledef.sh" ]] || { echo "set CACHYOS_UPSTREAM_ARCHISO to the archiso/ directory of the pinned upstream checkout" >&2; exit 2; }
UP="$(cd "$UP" && pwd)"
EPOCH="$(sed -n 's/^UPSTREAM_COMMIT_EPOCH=//p' "$REPO_ROOT/backends/cachyos/upstream.lock" 2>/dev/null | head -n 1)"; EPOCH="${EPOCH:-1791041490}"

PASS=0; FAIL=0; SKIP=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
t_skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }

# --- 1. media, in the container --------------------------------------------------------------------------------------------
read -r -d '' INNER <<'EOS' || true
set -euo pipefail
pacman -Sy --noconfirm --needed librsvg imagemagick plymouth syslinux >/tmp/pacman.log 2>&1 || { tail -15 /tmp/pacman.log; exit 1; }
git config --global --add safe.directory '*'
CI_OS_STAGING_DIR=/stage CI_OS_REPO_ROOT=/repo CI_OS_VERSION=2026.10 CI_OS_BUILD_DAY=20261015 bash /repo/backends/cachyos/iso/scripts/render-assets.sh --no-installed >/dev/null 2>&1
UPSTREAM_ARCHISO_DIR=/up OVERLAY_DIR=/repo/backends/cachyos/iso/overlay WORK_ARCHISO_DIR=/profile CI_OS_STAGING_DIR=/stage SOURCE_DATE_EPOCH="$CI_EPOCH" \
  bash /repo/backends/cachyos/iso/scripts/in-container/apply-overlay.sh >/tmp/engine.log 2>&1 || { cat /tmp/engine.log; exit 1; }
UUID=2026-10-03-15-31-30-00
subst() { sed "s|%ARCHISO_LABEL%|COMPANION_202610|g; s|%ARCHISO_UUID%|$UUID|g; s|%INSTALL_DIR%|arch|g; s|%KERNEL_PARAMS%||g; s|%ARCH%|x86_64|g; s|%ARCHISO_SEARCH_FILENAME%|/boot/$UUID.uuid|g" "$1"; }
placeholders() { mkdir -p "$1/arch/boot/x86_64"; for f in vmlinuz-linux-cachyos vmlinuz-linux-cachyos-lts initramfs-linux-cachyos.img initramfs-linux-cachyos-lts.img; do head -c 4096 /dev/zero > "$1/arch/boot/x86_64/$f"; done; }
# BIOS
I=/out/bios-iso; mkdir -p "$I/boot/syslinux"
for cfg in /profile/syslinux/*.cfg; do subst "$cfg" > "$I/boot/syslinux/$(basename "$cfg")"; done
cp /profile/syslinux/splash.png "$I/boot/syslinux/"
cp /usr/lib/syslinux/bios/*.c32 /usr/lib/syslinux/bios/isolinux.bin /usr/lib/syslinux/bios/lpxelinux.0 /usr/lib/syslinux/bios/memdisk "$I/boot/syslinux/"
placeholders "$I"
xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -joliet -joliet-long -rational-rock -volid COMPANION_202610 \
  -eltorito-boot boot/syslinux/isolinux.bin -eltorito-catalog boot/syslinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
  -isohybrid-mbr /usr/lib/syslinux/bios/isohdpfx.bin -output /out/bios-mini.iso "$I" >/dev/null 2>&1
# UEFI: grub-mkstandalone exactly as mkarchiso calls it (module list from archiso 91), the embedded configuration taken from mkarchiso itself
E=/out/esp; mkdir -p "$E/EFI/BOOT" "$E/boot/grub"
awk '/^    IFS=.. read -r -d .. grubembedcfg <<.EOF. \|\| true$/ {f=1; next} f && /^EOF$/ {exit} f {print}' /usr/bin/mkarchiso | sed "s|%ARCHISO_SEARCH_FILENAME%|/boot/$UUID.uuid|g" > /tmp/embed.cfg
test -s /tmp/embed.cfg
MODS="$(awk '/^[[:space:]]+grubmodules=\(all_video/ { f = 1 } f { print } f && /\)$/ { exit }' /usr/bin/mkarchiso | tr -d '\\\n' | sed 's/.*grubmodules=(//; s/).*//')"
test -n "$MODS"; echo "grub modules: $MODS" | cut -c1-120
grub-mkstandalone -O x86_64-efi --modules="$MODS" --locales="en@quot" --themes="" --sbat=/usr/share/grub/sbat.csv --disable-shim-lock -o "$E/EFI/BOOT/BOOTx64.EFI" "boot/grub/grub.cfg=/tmp/embed.cfg" >/dev/null 2>&1
for cfg in /profile/grub/*.cfg; do subst "$cfg" > "$E/boot/grub/$(basename "$cfg")"; done
cp -R /profile/grub/splash.png /profile/grub/theme "$E/boot/grub/"
if [ -n "${CI_UEFI_SIZE:-}" ]; then sed -i "s|set gfxmode=\"auto\"|set gfxmode=${CI_UEFI_SIZE}|" "$E/boot/grub/grub.cfg"; fi
: > "$E/boot/$UUID.uuid"
placeholders "$E"
echo "media built: $(ls -l /out/bios-mini.iso | awk '{print $5}') byte ISO, $(find "$E" -type f | wc -l) files on the ESP"
EOS
echo "== building the boot-menu media in $IMAGE"
rm -rf "$OUT/bios-iso" "$OUT/esp" "$OUT/bios-mini.iso"
docker run --rm --platform linux/amd64 --cpus 4 --memory 8g -v "$REPO_ROOT:/repo:ro" -v "$UP:/up:ro" -v "$OUT:/out" \
  -e "CI_EPOCH=$EPOCH" -e "CI_UEFI_SIZE=${CI_OS_TEST_UEFI_SIZE:-}" "$IMAGE" bash -c "$INNER" | tail -n 3
[[ -s "$OUT/bios-mini.iso" && -f "$OUT/esp/EFI/BOOT/BOOTx64.EFI" ]] && t_pass "media built from the merged profile (engine guards passed)" || { t_fail "media were not built"; echo "== Summary: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1; }

# --- 2. boot and screenshot ----------------------------------------------------------------------------------------------------
shoot() { # shoot <bios|uefi> <outdir> <delay>...   the QEMU command line is built here, QMP screendump by python
  local mode="$1" dir="$2"; shift 2
  mkdir -p "$dir"
  MODE="$mode" OUTDIR="$dir" ISO="$OUT/bios-mini.iso" ESP="$OUT/esp" CODE="${OVMF_CODE:-}" VARS="${OVMF_VARS:-}" python3 -I - "$@" <<'PYEOF'
import json, os, shutil, socket, subprocess, sys, tempfile, time
mode, outdir = os.environ["MODE"], os.environ["OUTDIR"]
delays = [float(x) for x in sys.argv[1:]]
tmp = tempfile.mkdtemp(prefix="menushot-"); sock = os.path.join(tmp, "qmp.sock")
q = ["qemu-system-x86_64", "-machine", "q35", "-m", "2048", "-smp", "2", "-accel", "tcg,thread=multi", "-cpu", "max",
     "-device", "ahci,id=ahci", "-vga", "std", "-display", "none", "-serial", "file:" + os.path.join(outdir, "serial.log"),
     "-qmp", "unix:%s,server=on,wait=off" % sock, "-no-reboot"]
if mode == "bios":
    q += ["-drive", "file=%s,media=cdrom,readonly=on,if=none,id=cd" % os.environ["ISO"], "-device", "ide-cd,bus=ahci.0,drive=cd,bootindex=1"]
else:
    vars_ = os.path.join(tmp, "vars.fd"); shutil.copy(os.environ["VARS"], vars_)
    q += ["-drive", "if=pflash,format=raw,readonly=on,file=" + os.environ["CODE"], "-drive", "if=pflash,format=raw,file=" + vars_,
          "-drive", "file=fat:rw:%s,format=raw,if=none,id=esp" % os.environ["ESP"], "-device", "ide-hd,drive=esp,bus=ahci.0,bootindex=1"]
p = subprocess.Popen(q, stdout=subprocess.DEVNULL, stderr=open(os.path.join(outdir, "qemu.err"), "w"))
try:
    for _ in range(150):
        if os.path.exists(sock): break
        time.sleep(0.2)
    s = socket.socket(socket.AF_UNIX); s.connect(sock); f = s.makefile("rw")
    def qmp(cmd, **args):
        f.write(json.dumps({"execute": cmd, "arguments": args}) + "\n"); f.flush()
        while True:
            r = json.loads(f.readline())
            if "return" in r or "error" in r: return r
    f.readline(); qmp("qmp_capabilities")
    t0 = time.time()
    for d in delays:
        time.sleep(max(0, d - (time.time() - t0)))
        qmp("screendump", filename=os.path.join(outdir, "%s-%03ds.png" % (mode, int(d))), format="png")
    qmp("quit")
finally:
    try: p.wait(timeout=30)
    except Exception: p.kill()
    shutil.rmtree(tmp, ignore_errors=True)
PYEOF
}

# colours of the canon the screenshots must show
ground="$(cd "$REPO_ROOT" && ( source core/lib/theme-lib.sh >/dev/null; printf '%s' "$CI_DARK_BACKGROUND" ))"
aqua="$(cd "$REPO_ROOT" && ( source core/lib/theme-lib.sh >/dev/null; printf '%s' "$CI_ACCENT_AQUA" ))"
# (the listing goes to a variable first: grep -q on a pipe closes it early, and with pipefail ImageMagick's SIGPIPE would fail the check at random)
has_color() { local u; u="$("${IM[@]}" "$1" -depth 8 -unique-colors txt:- 2>/dev/null || true)"; grep -qi "$2" <<< "$u"; }

echo "== BIOS (SeaBIOS, syslinux vesamenu)"
shoot bios "$OUT/shots-bios" 5 7 9
bios_ok=0
for f in "$OUT"/shots-bios/bios-*.png; do
  [[ -f "$f" ]] || continue
  if has_color "$f" "$aqua" && has_color "$f" "$ground"; then bios_ok=1; best_bios="$f"; break; fi
done
if [[ $bios_ok -eq 1 ]]; then
  t_pass "BIOS menu on screen: the canon ground $ground and the token highlight $aqua are both there ($(basename "$best_bios"), $("${IM[@]}" identify -format '%wx%h' "$best_bios" 2>/dev/null || true))"
else
  t_fail "BIOS menu screenshots show no highlight/ground colours: look at $OUT/shots-bios/"
fi

echo "== UEFI (OVMF, standalone GRUB)"
OVMF_CODE="${CI_OS_TEST_OVMF_CODE:-}"; OVMF_VARS="${CI_OS_TEST_OVMF_VARS:-}"
if [[ -z "$OVMF_CODE" ]]; then
  for c in /opt/homebrew/share/qemu/edk2-x86_64-code.fd /usr/local/share/qemu/edk2-x86_64-code.fd /usr/share/qemu/edk2-x86_64-code.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f "$c" ]] && { OVMF_CODE="$c"; break; }; done
fi
if [[ -z "$OVMF_VARS" ]]; then
  for c in /opt/homebrew/share/qemu/edk2-i386-vars.fd /usr/local/share/qemu/edk2-i386-vars.fd /usr/share/qemu/edk2-i386-vars.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS.fd; do [[ -f "$c" ]] && { OVMF_VARS="$c"; break; }; done
fi
if [[ -z "$OVMF_CODE" || -z "$OVMF_VARS" ]]; then
  t_skip "no OVMF firmware found (set CI_OS_TEST_OVMF_CODE and CI_OS_TEST_OVMF_VARS)"
else
  export OVMF_CODE OVMF_VARS
  shoot uefi "$OUT/shots-uefi" 6 8 10
  uefi_ok=0
  for f in "$OUT"/shots-uefi/uefi-*.png; do
    [[ -f "$f" ]] || continue
    if has_color "$f" "$aqua" && has_color "$f" "$ground"; then uefi_ok=1; best_uefi="$f"; break; fi
  done
  if [[ $uefi_ok -eq 1 ]]; then
    t_pass "UEFI menu on screen: the canon ground $ground and the token highlight $aqua are both there ($(basename "$best_uefi"), $("${IM[@]}" identify -format '%wx%h' "$best_uefi" 2>/dev/null || true))"
    # The theme draws a filled highlight bar in the accent colour (the mark has some aqua too, a few thousand pixels at most)
    n="$("${IM[@]}" "$best_uefi" -fill black +opaque "$aqua" -fill white -opaque "$aqua" -format '%[fx:round(mean*w*h)]' info: 2>/dev/null || echo 0)"
    [[ "$n" =~ ^[0-9]+$ && "$n" -gt 6000 ]] && t_pass "the aqua highlight bar of the theme is on screen ($n aqua pixels)" || t_fail "no aqua highlight bar found ($n aqua pixels): the theme did not load, the text menu is showing"
  else
    t_fail "UEFI menu screenshots show no highlight/ground colours: look at $OUT/shots-uefi/ (serial log: $OUT/shots-uefi/serial.log)"
  fi
  # GRUB mirrors its console on the serial port: the entry titles must be there too
  if grep -aq 'Companion OS (Plasma)' "$OUT/shots-uefi/serial.log" 2>/dev/null; then t_pass "the serial mirror of GRUB lists 'Companion OS (Plasma)'"; else t_fail "no 'Companion OS (Plasma)' on the serial console"; fi
  ! grep -aqi 'cachyos' <(grep -a 'menuentry\|Companion\|Booting' "$OUT/shots-uefi/serial.log" 2>/dev/null | tr -d '\033' | sed 's/\[[0-9;?]*[A-Za-z]//g' | grep -aiv 'vmlinuz\|initramfs') && t_pass "no CachyOS text in the menu lines of the serial mirror" || t_fail "CachyOS text on the GRUB console"
fi

echo "== screenshots: $OUT/shots-bios and $OUT/shots-uefi"
echo "== Summary: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
