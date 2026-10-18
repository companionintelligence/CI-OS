#!/usr/bin/env bash
#=============================================================================
# Test (manual): the build pipeline against the REAL pinned upstream and the REAL overlay, up to mkarchiso, in a real container
#
# overlay-engine.sh proves the engine on fakes and needs no Docker. This one proves the pieces that only exist in a container and
# on the real tree: the builder image, the [cachyos] repository and key bootstrap, the pinned clone (commit id, committer time and
# archiso/ tree id), render-assets.sh, upstream's generators, the real patches against the real files, and that the stock
# mkarchiso accepts the merged profile. It builds no ISO and downloads no package of the live image (about 3 minutes, a few
# hundred MB the first time; Docker and network needed; not run by core/lib/check-repo.sh).
#
#   1. build-iso.sh --stop-after overlay --keep-container            the pipeline up to the merged profile (date pinned, so names are stable)
#   2. checks inside the container, on /work/build/archiso           shape of the merged profile, bash 5 sourcing profiledef.sh the
#                                                                    way mkarchiso does, upstream untouched, generated layer
#   2b. check-owned.sh on a crafted tree                            a file a package ships is a conflict, a backup= file is not
#   3. 20-build.sh with CI_OS_STOP_AFTER=validate                    stock mkarchiso reads the profile with no network
#   4. container and work volume removed; the package cache volume stays (it makes the next build faster)
#
#   backends/cachyos/iso/tests/overlay-engine-container.sh
#
# Exit status: non-zero if a check fails; 2 if it cannot run here (no docker, or a build container of the same name is in use).
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS="$(cd "$HERE/../.." && pwd)"
BUILD="$CACHYOS/iso/scripts/build-iso.sh"
LOCK="$CACHYOS/upstream.lock"
CT=ci-os-cachyos-build
VOL=ci-os-cachyos-work
CT_REPO=/work/repo
CT_SCRIPTS=$CT_REPO/backends/cachyos/iso/scripts/in-container

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "docker is not available here" >&2; exit 2; }
if docker inspect "$CT" >/dev/null 2>&1; then
  echo "a container named $CT exists (a build in progress, or a kept one): not touching it. Remove it with: docker rm -f $CT" >&2
  exit 2
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/overlay-engine-container.XXXXXX")"
cleanup() {
  # only what build-iso.sh labelled as its own
  if [ "$(docker inspect -f '{{index .Config.Labels "ci-os.cachyos"}}' "$CT" 2>/dev/null || true)" = build ]; then docker rm -f -v "$CT" >/dev/null 2>&1 || true; fi
  if [ "$(docker volume inspect -f '{{index .Labels "ci-os.cachyos"}}' "$VOL" 2>/dev/null || true)" = work ]; then docker volume rm "$VOL" >/dev/null 2>&1 || true; fi
  rm -rf "$W"
}
trap cleanup EXIT

# 1 ----------------------------------------------------------------------------------------------------------------------------
printf '== 1: build-iso.sh --stop-after overlay --keep-container\n'
rc=0
bash "$BUILD" --stop-after overlay --keep-container --unprivileged --cpus 4 --memory 8g --source-date-epoch pin --out "$W/out" > "$W/step1.out" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then t_pass "the pipeline runs through bootstrap, the pinned clone, render-assets.sh, the generators and apply-overlay.sh"
else t_fail "build-iso.sh --stop-after overlay failed (rc $rc): $(tail -n 12 "$W/step1.out")"; cat "$W/step1.out" >&2; exit 1; fi
[ ! -e "$W/out" ] && t_pass "no artifact directory is created for a stopped run" || t_fail "an output directory appeared"
[ "$(docker inspect -f '{{index .Config.Labels "ci-os.cachyos"}}' "$CT")" = build ] && t_pass "the container carries the script's label" || t_fail "container label missing"
grep -q 'guards (a)-(e) passed' "$W/step1.out" && t_pass "the engine's guards pass on the real overlay" || t_fail "no 'guards passed' line"
grep -qE 'headless payload: [1-9][0-9]* file\(s\), list digest [0-9a-f]{64}' "$W/step1.out" && t_pass "the log lists the headless payload files the container really received (the container has no .git, so every file counts)" || t_fail "no payload list in the log of the build"

# 2 ----------------------------------------------------------------------------------------------------------------------------
printf '== 2: the merged profile, inside the container\n'
# shellcheck source=/dev/null
. "$LOCK"
# the commit build-iso.sh recorded for the working tree it copied in (the same function it uses)
EXPECT_COMMIT="$( export CI_PROG=test; . "$CACHYOS/iso/scripts/lib/common.sh"; ci_repo_commit "$CACHYOS/../.." )"
docker exec -i -e "EXPECT_COMMIT=$EXPECT_COMMIT" -e "EXPECT_SHA=$UPSTREAM_SHA" -e "EXPECT_MIRROR_SHA=$MIRRORLIST_SHA256" -e "EXPECT_ISO_NAME=$EDITION_ISO_NAME" -e "EXPECT_LABEL_PREFIX=$EDITION_LABEL_PREFIX" \
  "$CT" bash -s > "$W/step2.out" 2>&1 <<'INNER' || true
set -u
P=/work/build/archiso; OV=/work/repo/backends/cachyos/iso/overlay; U=/work/upstream; ST=/work/staging; G=/work/build/generated; R=/work/build/overlay-report.env
ok()  { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; }
same() { [ -f "$1" ] && [ -f "$2" ] && [ "$(sha256sum < "$1")" = "$(sha256sum < "$2")" ]; }     # the builder image has no cmp
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

chk "upstream is at the pinned commit" test "$(git -C $U rev-parse HEAD)" = "$EXPECT_SHA"
chk "upstream checkout is pristine (git status clean)" test -z "$(git -C $U status --porcelain)"
chk "the merged profile exists and upstream's archiso/ was copied, not edited" test -f $P/profiledef.sh -a -f $U/archiso/profiledef.sh
chk "packages.x86_64 is written" test -s $P/packages.x86_64
if [ -f $OV/packages.remove ]; then
  gone=1; while read -r n; do n="${n%%#*}"; n="$(echo $n)"; [ -n "$n" ] || continue; grep -qxF -- "$n" $P/packages.x86_64 && gone=0; done < $OV/packages.remove
  chk "every package in packages.remove is gone from packages.x86_64" test "$gone" = 1
fi
if [ -f $OV/packages.add ]; then
  there=1; while read -r n; do n="${n%%#*}"; n="$(echo $n)"; [ -n "$n" ] || continue; grep -qxF -- "$n" $P/packages.x86_64 || there=0; done < $OV/packages.add
  chk "every package in packages.add is in packages.x86_64" test "$there" = 1
fi
chk "syslinux, grub and mkinitcpio-archiso stay in the list" test "$(grep -cxE 'syslinux|grub|mkinitcpio-archiso' $P/packages.x86_64)" = 3

# overlay files and symlinks arrive (the staging layer, applied last, may legitimately replace one)
miss=0; diffcount=0
if [ -d $OV/files ]; then
  while IFS= read -r f; do
    rel="${f#$OV/files/}"
    if [ -L "$f" ]; then [ "$(readlink "$f")" = "$(readlink "$P/$rel" 2>/dev/null)" ] || miss=$((miss + 1))
    elif [ -e "$ST/$rel" ]; then :
    else [ -f "$P/$rel" ] || miss=$((miss + 1)); same "$f" "$P/$rel" || diffcount=$((diffcount + 1)); fi
  done < <(find $OV/files ! -type d)
fi
chk "every overlay file and symlink is in the merged profile with its content ($miss missing, $diffcount different)" test "$miss" = 0 -a "$diffcount" = 0
smiss=0; if [ -d $ST ]; then while IFS= read -r f; do rel="${f#$ST/}"; if [ -L "$f" ]; then :; else same "$f" "$P/$rel" || smiss=$((smiss + 1)); fi; done < <(find $ST ! -type d); fi
chk "every file rendered into the staging layer is in the merged profile ($smiss missing or different)" test "$smiss" = 0
# the compatibility libraries (risk R1): fetched from the Arch Linux Archive by stage-compat-libs.sh, so they are in the profile with the lock's hashes
cmiss=0; cn=0
while read -r kind _ cpath csha _; do
  [ "$kind" = lib ] || continue
  cn=$((cn + 1)); [ -f "$P/airootfs/$cpath" ] && [ "$(sha256sum < "$P/airootfs/$cpath" | cut -d' ' -f1)" = "$csha" ] || cmiss=$((cmiss + 1))
done < <(sed -e 's/#.*//' /work/repo/backends/cachyos/compat-libs.lock)
chk "the $cn compatibility libraries of compat-libs.lock are in the merged profile with their pinned sha256 ($cmiss wrong or missing)" test "$cn" -ge 1 -a "$cmiss" = 0

# profiledef.sh the way mkarchiso reads it: bash 5, associative file_permissions, SOURCE_DATE_EPOCH from the environment
out="$(cd $P && SOURCE_DATE_EPOCH=$(git -C $U log -1 --format=%ct) bash -c 'declare -A file_permissions=(); source ./profiledef.sh; printf "%s|%s|%s|%s|%s\n" "$iso_name" "$iso_label" "$iso_version" "${#file_permissions[@]}" "$arch"; for k in "${!file_permissions[@]}"; do echo "FP $k ${file_permissions[$k]}"; done' 2>&1)"
head1="$(printf '%s\n' "$out" | head -n 1)"
chk "bash 5 sources the merged profiledef.sh: $head1" test "$(printf '%s' "$head1" | cut -d'|' -f1)" = "$EXPECT_ISO_NAME"
label="$(printf '%s' "$head1" | cut -d'|' -f2)"
chk "iso_label is $EXPECT_LABEL_PREFIX plus YYYYMM and fits an ISO 9660 volume id ($label)" test "${label#"$EXPECT_LABEL_PREFIX"}" != "$label" -a "${#label}" -le 32
chk "the report names the ISO file mkarchiso will write" grep -qx "ISO_FILE=$EXPECT_ISO_NAME-$(printf '%s' "$head1" | cut -d'|' -f3)-x86_64.iso" $R
noperm=0
while IFS= read -r f; do
  img="/${f#airootfs/}"
  printf '%s\n' "$out" | awk -v k="$img" '$1=="FP" && $2==k {found=1; split($3,a,":"); m=a[3]; o=substr(m,length(m)-2,1); if (o!=1 && o!=3 && o!=5 && o!=7) found=0} END{exit !found}' || { noperm=$((noperm + 1)); echo "   no executable file_permissions entry for $img"; }
done < <(cd $P && find airootfs -type f -perm -100 | while read -r e; do same "$U/archiso/$e" "$P/$e" || echo "$e"; done)
chk "every executable file that is new or differs from upstream has an executable file_permissions entry for mkarchiso ($noperm without)" test "$noperm" = 0

# kernel lines. The merged profile must equal what upstream PLUS THE PATCHES give: the marker licenses a patch, never an overlay file,
# the staging layer or the generated layer. (A comparison with upstream's own lines would fail on the Memtest path patch 0002 changes
# on purpose; skipping it whenever a patch is marked is what let anything else through.)
pt="$(mktemp -d)"; cp -pPR $U/archiso/. "$pt/"
for p in $OV/patches/*.patch; do [ -e "$p" ] || continue; (cd "$pt" && GIT_CEILING_DIRECTORIES="$(dirname "$pt")" git apply -p1 --whitespace=nowarn "$p") || bad "patch $p does not apply to a copy of upstream"; done
kl() { (cd "$1"; grep -hE '^[[:space:]]*(linux|initrd)[[:space:]]' grub/grub.cfg grub/loopback.cfg; grep -ihE '^[[:space:]]*(linux|initrd|append|kernel)[[:space:]]' syslinux/*.cfg) | sha256sum; }
a="$(kl "$pt")"; b="$(kl $P)"; up="$(kl $U/archiso)"
chk "the kernel, initrd and append lines of the merged profile are exactly what upstream plus the patches give (no overlay file, staging file or generated file moved one)" test "$a" = "$b"
if grep -qx 'KERNEL_LINES_CHANGED=0' $R; then
  chk "KERNEL_LINES_CHANGED=0 and the patches really left every kernel line as upstream has it" test "$a" = "$up"
else
  chk "KERNEL_LINES_CHANGED=1 and the patches really did move kernel lines (on purpose: patch 0002, the Memtest path)" test "$a" != "$up"
fi
chk "the report carries the digest of the final kernel lines" grep -qE '^KERNEL_LINES_SHA256=[0-9a-f]{64}$' $R
rm -rf "$pt"

# generated layer
chk "cachyos-mirrorlist is the pinned file" test "$(sha256sum $P/airootfs/etc/pacman.d/cachyos-mirrorlist | cut -d' ' -f1)" = "$EXPECT_MIRROR_SHA"
chk "display-manager.service points at plasmalogin.service" test "$(readlink $P/airootfs/etc/systemd/system/display-manager.service)" = /usr/lib/systemd/system/plasmalogin.service
chk "cachyos-rate-mirrors.timer and archlinux-keyring-wkd-sync.timer are masked" test "$(readlink $P/airootfs/etc/systemd/system/cachyos-rate-mirrors.timer)" = /dev/null -a "$(readlink $P/airootfs/etc/systemd/system/archlinux-keyring-wkd-sync.timer)" = /dev/null
BI=$P/airootfs/usr/share/ci-os/iso-build-info
chk "the build record is in the image: usr/share/ci-os/iso-build-info names the pin" grep -qx "UPSTREAM_SHA=$EXPECT_SHA" $BI
chk "the build record names the commit of the working tree that was copied in ($EXPECT_COMMIT)" grep -qx "REPO_COMMIT=$EXPECT_COMMIT" $BI
chk "the build record says whether that tree was clean, with the counts of changed, untracked and ignored files" test "$(grep -cE '^REPO_TREE=(clean|dirty|unknown)$|^REPO_TREE_(CHANGED|UNTRACKED|IGNORED)=([0-9]+|unknown)$' $BI)" = 4
chk "the build record holds a digest of the copied subset and of the headless payload file list, and counts the payload files" test "$(grep -cE '^(REPO_SUBSET_SHA256|PAYLOAD_SHA256)=[0-9a-f]{64}$|^PAYLOAD_FILES=[1-9][0-9]*$' $BI)" = 3
chk "the mirrorlist hash in the record is the hash of the mirrorlist that is in the image" test "$(sed -n 's/^MIRRORLIST_SHA256=//p' $BI)" = "$(sha256sum $P/airootfs/etc/pacman.d/cachyos-mirrorlist | cut -d' ' -f1)"
chk "grub.cfg carries a date stamp, not the placeholder GIT" sh -c "! grep -q 'CACHYOS_VERSION=\"GIT\"' $P/grub/grub.cfg"
INNER
cat "$W/step2.out"
PASS=$((PASS + $(grep -c '^PASS' "$W/step2.out" || true))); FAIL=$((FAIL + $(grep -c '^FAIL' "$W/step2.out" || true)))
grep -q '^PASS' "$W/step2.out" || t_fail "the in-container checks printed no result"

# 2b ---------------------------------------------------------------------------------------------------------------------------
printf '== 2b: check-owned.sh on a crafted tree (the exact package-ownership check)\n'
docker exec -i -e "SCRIPTS=$CT_SCRIPTS" "$CT" bash -s > "$W/step2b.out" 2>&1 <<'INNER2' || true
set -u
ok()  { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; }
t="$(mktemp -d)"; mkdir -p $t/w/airootfs/usr/lib $t/w/airootfs/etc $t/w/airootfs/usr/share/ci-os $t/u/airootfs
echo x > $t/w/airootfs/usr/lib/os-release       # shipped by filesystem, not a backup= file: a real conflict
echo x > $t/w/airootfs/etc/hosts                # shipped by filesystem as a backup= file: the overlay copy may win
echo x > $t/w/airootfs/usr/share/ci-os/mine     # no package ships it
mkdir -p $t/u/airootfs/usr/bin $t/w/airootfs/usr/bin
echo x > $t/u/airootfs/usr/bin/bash; echo x > $t/w/airootfs/usr/bin/bash      # shipped by bash, but upstream's airootfs already has the path: not examined
printf 'base\n' > $t/w/packages.x86_64
run() { WORK_ARCHISO_DIR=$t/w UPSTREAM_ARCHISO_DIR=$t/u "$@" bash "$SCRIPTS/check-owned.sh" > $t/out 2>&1; echo $?; }
rc="$(run env)"
if [ "$rc" = 1 ] && grep -q 'conflict: /usr/lib/os-release is shipped by filesystem' $t/out; then ok "a file that a package ships and does not list in backup= is a conflict (exit 1)"; else bad "conflict not found (rc $rc): $(tail -n 5 $t/out)"; fi
grep -q 'ok: /etc/hosts is a backup= file of filesystem' $t/out && ok "a backup= file is reported as an allowed override" || bad "backup= file not recognised: $(cat $t/out)"
grep -q 'usr/share/ci-os/mine' $t/out && bad "a path no package ships was reported" || ok "a path of our own is not reported"
grep -q 'usr/bin/bash' $t/out && bad "a path upstream already has was examined" || ok "a path that upstream's airootfs already has is not examined"
rc="$(run env CI_OS_OWNERSHIP_CHECK=warn)"; [ "$rc" = 0 ] && ok "CI_OS_OWNERSHIP_CHECK=warn reports the conflict and succeeds" || bad "warn mode rc $rc"
rc="$(run env CI_OS_OWNERSHIP_CHECK=off)"; [ "$rc" = 0 ] && ok "CI_OS_OWNERSHIP_CHECK=off skips" || bad "off mode rc $rc"
rm $t/w/airootfs/usr/lib/os-release
rc="$(run env)"; if [ "$rc" = 0 ] && grep -q 'no conflict' $t/out; then ok "without the conflicting file the check passes (exit 0)"; else bad "clean tree rc $rc: $(tail -n 4 $t/out)"; fi
INNER2
cat "$W/step2b.out"
PASS=$((PASS + $(grep -c '^PASS' "$W/step2b.out" || true))); FAIL=$((FAIL + $(grep -c '^FAIL' "$W/step2b.out" || true)))
grep -q '^PASS' "$W/step2b.out" || t_fail "the check-owned.sh checks printed no result"

# 3 ----------------------------------------------------------------------------------------------------------------------------
printf '== 3: mkarchiso reads the profile with no network\n'
rc=0
docker exec -e CI_OS_STOP_AFTER=validate -e CI_OS_UPSTREAM_REUSE=1 -e CI_OS_REPO_ROOT=$CT_REPO "$CT" "$CT_SCRIPTS/20-build.sh" > "$W/step3.out" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'accepted the profile and stopped at the first package database sync' "$W/step3.out"; then
  if grep -q 'no conflict\|is shipped by a package of the image' "$W/step3.out" && ! grep -q 'ERROR\|skipped' "$W/step3.out"; then
    t_pass "check-owned.sh on the real tree: $(grep -m1 'no conflict\|is shipped by a package of the image' "$W/step3.out" | sed 's/^[a-z-]*: //')"
  else t_fail "the real-tree ownership check did not report a clean result: $(grep 'check-owned' "$W/step3.out" | tail -n 4 | tr '\n' '|')"; fi
  t_pass "stock mkarchiso accepts the merged profile and stops at the first package database sync ($(grep -m1 'Image file name' "$W/step3.out" | sed 's/^ *//'))"
else t_fail "the validate stage failed (rc $rc): $(tail -n 8 "$W/step3.out")"; fi

# 4 ----------------------------------------------------------------------------------------------------------------------------
printf '== 4: cleanup\n'
docker rm -f -v "$CT" >/dev/null && docker volume rm "$VOL" >/dev/null
if ! docker inspect "$CT" >/dev/null 2>&1 && ! docker volume inspect "$VOL" >/dev/null 2>&1; then t_pass "the build container and its work volume are removed"; else t_fail "leftovers"; fi

printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
