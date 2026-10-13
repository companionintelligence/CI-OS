# Docker in Companion OS: installed, live ISO and Companion Stick live boot

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Date 2026-10-13. Status: **implemented** in `backends/ubuntu/chroot/customize-chroot.sh` (Step 10d) and `backends/ubuntu/chroot/payload/docker/`, asserted by `backends/ubuntu/iso/scripts/verify-iso.sh` (section 3b). The QEMU tests in section 8 are written (`stick/tests/qemu/docker-live.sh`) but **have not been run on a built ISO**; the live-session facts come from upstream sources and container tests, not from a boot.

## 0. Summary of findings

1. **`casper.conf` has no `USERGROUPS`.** On noble, casper reads only `USERNAME USERFULLNAME HOST BUILD_SYSTEM FLAVOUR`. Nothing in the 34 `casper-bottom` scripts, `casper` or `casper-functions` refers to a group list (grep over the Launchpad `applied/ubuntu/noble` files, , , ). The premise "add `docker` to `USERGROUPS`" is a no-op. The live user's groups come from debconf `passwd/user-default-groups` (user-setup), read from the **rootfs** debconf database. The supported, targeted hook is to set that question in the squashfs. Proven end to end with the real `user-setup-apply` (T3 below).
2. **The installer cannot be told about `docker` on 24.04.** Subiquity 24.04.4/24.04.5 creates the first user with `useradd --groups <list>` where `<list>` is a file baked into the snap at build time (`adm cdrom dip lpadmin plugdev sambashare debian-tor libvirtd users lxd`) intersected with the target's groups, plus `sudo`. `docker` is never in it. `useradd` ignores `/etc/adduser.conf`. Autoinstall `identity.groups` only exists from Subiquity 26.04, and only for autoinstall. So the installed user must be put in `docker` by our own boot-time code. Recommended: an idempotent offline oneshot that adds every `sudo`-group member to `docker`, plus the online `provision.sh` path, which today adds the wrong user (see section 3).
3. **`customize-chroot.sh` does not currently guard Docker.** Step 10d writes `10-not-live.conf` only for `hostapd-setup`, `dnsmasq-setup`, `setup-backend`, `setup-network-monitor`, `nginx` (lines 817-826). `docker.service` and `containerd.service` are enabled (line 811) with no `ConditionPathExists`. An earlier draft of this change would have **added** the guard to `docker.service docker.socket containerd.service`. That is not what shipped: the Docker units stay unguarded and the loop names the setup-stack units and `nginx.service` only.
4. **Docker cannot use the live root as its data root.** In a casper live session `/` is an overlayfs. A local test (T-ovl, kernel 7.0.14-linuxkit, not Ubuntu's kernel) shows `overlay: filesystem on /t/u not supported as upperdir` when the upper dir is on an overlayfs, while tmpfs, and a bind-mounted tmpfs, work. Docker's `overlay2` driver and the containerd `overlayfs` snapshotter both need a real filesystem. Fix: a live-only oneshot that bind-mounts `/var/lib/docker` and `/var/lib/containerd` from (a) a sibling directory on the casper-owned `writable` ext4 volume (Stick), or (b) a size-capped tmpfs (plain ISO). Section 5 has the exact files and the container tests that exercised them.
5. **Docker group membership does not change the live threat model.** casper writes `${USERNAME} ALL=(ALL) NOPASSWD: ALL` for the live user (`25adduser` lines 76-78). On the installed system it is a real step up from password-protected `sudo`; that is the open question Q-SEC.

## 1. Evidence base

| Claim | Evidence |
|---|---|
| casper.conf supports only 5 variables | (Launchpad `casper.conf?h=applied/ubuntu/noble`, header lines 2-3: "USERNAME, USERFULLNAME, HOST, BUILD_SYSTEM, FLAVOUR"). `grep -rn USERGROUPS` over , , , returns nothing. 25adduser and casper script identical on `resolute` (`diff` clean for `25adduser`; `casper.noble` == `casper.resolute`). |
| initrd `/etc/casper.conf` is what casper sources | `casper.noble:23` (`[ -f /etc/casper.conf ] && . /etc/casper.conf`), `casper.noble:1064-65` (copies it into the rootfs). build-iso.sh `brand_boot_media` (lines 520-550) appends a cpio overlay carrying it. It covers only those 5 variables. |
| Live user creation | `25adduser` : sets debconf `passwd/*`, then `chroot /root /usr/lib/user-setup/user-setup-apply`, then writes `/root/etc/sudoers.d/casper` NOPASSWD (lines 76-78). `casper-functions.noble:43-51` `load_confmodule` sources `/root/usr/share/debconf/confmodule`, so the **rootfs** debconf DB is used. `casper.noble:1021` copies the rootfs `config.dat`. `casper` Depends on `user-setup` (`debian/control` line 14). |
| user-setup group logic | `user-setup-apply:213` `adduser --disabled-password ...`; `:242-256` creates `lpadmin sambashare`, then `db_get passwd/user-default-groups` and `adduser "$USER" $group` for each (silently skipped if the group does not exist); `:362` `adduser "$USER" sudo`. Default `Default: adm cdrom dip lpadmin plugdev sambashare debian-tor libvirtd users` (`user-setup.templates:22`, 1.95ubuntu1; also seen by `debconf-communicate` in the T3 container). |
| Live user is NOT created if the rootfs has a UID 1000-59999 account | `functions.sh is_system_user` (`user-setup-apply:109`). Seen first-hand: my first T3 run silently created no user because the ubuntu:24.04 image has `ubuntu` (uid 1000). verify-iso should assert there is no such account in the squashfs. |
| Subiquity 24.04.5 installer user creation | `subiquity/server/controllers/install.py:670-710` (tag 24.04.5): `create_users` runs `useradd <user> --comment ... --shell /bin/bash --groups <csv> --create-home` then `chpasswd --encrypted`. `subiquity/common/resources.py:30-47`: groups = contents of snap file `users-and-groups`, then `.append("sudo")`, intersected with `getent group` of the target. 24.04.4 has the same code (lines 652-686). 24.04.1-.3 use cloud-init `users:` with `"groups": ",".join(sorted(groups))` from the same function . `snapcraft.yaml:166-180` (24.04.5): the file is generated from `debconf-communicate user-setup` (`get passwd/user-default-groups`) plus `lxd`. The ISO's installer is `ubuntu-desktop-bootstrap_680.snap` on "Ubuntu 24.04.5 LTS ... (20260914)" (`audit-baseline-2.txt:4`); the snap's own `users-and-groups` file was not extracted (UNVERIFIED which of the two code paths rev 680 uses; both give the same list). |
| `groups` in autoinstall identity is new | `identity.py` has no `"groups"` key at tags 24.04.5, 25.04, 25.10; present at 26.04, 26.04.1, 26.10 (GitHub raw, grep count 0/0/0/1/1/1). Documented at `doc/reference/autoinstall-reference.rst:849-865` (26.04.1). Interactive installs (our case) have no way to set it. |
| useradd ignores adduser.conf; adduser does not | T5 in container (adduser 3.137ubuntu1): with `ADD_EXTRA_GROUPS=1`, `EXTRA_GROUPS="users docker"`: `adduser erin` -> `erin users docker`; `useradd -m frank` -> `frank`. adduser source `adduser.pl:885-887` (`add_extra_groups`/`extra_groups`). |
| Docker units and socket | moby `contrib/init/systemd/docker.service`: `ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock`, `Wants=network-online.target containerd.service`, `Requires=docker.socket`. `docker.socket`: `SocketMode=0660 SocketUser=root SocketGroup=docker`. `docker-ce.postinst` (docker-ce-packaging master): `groupadd --system docker` only on fresh install (`-z "$2"`), then `#DEBHELPER#`. |
| Engine 29 default image store | docs.docker.com/engine/storage/drivers/select-storage-driver: "Docker Engine 29.0 and later uses the containerd image store by default for fresh installations" (page cites Engine 29.8.2; host Docker Desktop server here is 29.8.2). docs.docker.com/engine/storage/containerd: "not available when using user namespace remapping (userns-remap)". Same page: overlay2 supported backing filesystems "xfs with ftype=1, ext4, btrfs (and more)"; overlayfs is not listed. |
| Docker probes overlay by really mounting | moby master `daemon/graphdriver/overlay2/overlay.go:143` `overlayutils.SupportsOverlay(testdir, true)`, then `fs.SupportsDType`. |
| Persistence layout | `casper.noble:545-585,683`: `/cow` = tmpfs (default) or the `writable` device (`find_cow_device`, `casper-helpers.noble:195-262`, falls back to label `casper-rw`); `/cow/upper` and `/cow/work` are created on first use and everything else at the top level is moved into `upper` only if `upper` does not exist yet. `mount -t overlay -o upperdir=/cow/upper,... "/cow" "$rootmnt"`. `/cow` is not moved into the new root (`05mountpoints` moves only `/cdrom`). Stick cmdline: `boot=casper live-media=/dev/disk/by-partlabel/CI-BOOT-A persistent ci_stick.slot=A quiet splash $extra_cmdline ---` (`stick/crates/ci-stick/src/bootcfg.rs:182`); persistence is ext4 label `writable` on `CI-PERSIST` (`companion-stick.md:260`, `flash.rs:48`). |
| Today's repo behaviour | `customize-chroot.sh:811` enables docker + containerd, `:817-826` guard loop (5 units, no Docker), `:1077,:1101` first-boot unit/timer guards, `:197-208` casper.conf. `verify-iso.sh:96-101,128-131` asserts `docker-ce*` installed and `docker.service containerd.service` enabled, no guard assertions for them. `provision.sh:81-91` `detect_user` and `:295-317` `add_user_to_docker_group`. `core/lib/ci-hub.sh:410,431` mount `/var/run/docker.sock:ro` into Hub containers. |

## 2. (a) casper and the live user

* Where `USERGROUPS` is read from: **nowhere** on noble. `/etc/casper.conf` (rootfs copy, and the copy inside `casper/initrd` that build-iso.sh overlays) is sourced by `scripts/casper` and is limited to the five variables above. The overlay already covers every variable casper understands; adding `USERGROUPS` there would be silently ignored.
* Supported hook: debconf `passwd/user-default-groups`, owned by `user-setup`, stored in the rootfs `/var/cache/debconf/config.dat`. It is consumed only by `user-setup-apply` (casper's live user; oem-config users). It is **not** consumed by Subiquity, so it does not alter what `adduser` does elsewhere. That is why it is preferable to `adduser.conf` `ADD_EXTRA_GROUPS=1`, which would also leak into the installed target (the squashfs is copied there) and turn every later `adduser`-created account into a Docker-root-equivalent one.
* Exact, build-time, self-adjusting change (runs in the chroot after docker-ce is installed; it extends the stock default instead of hard-coding it):

```bash
# Step 10d, right after the docker-ce install block and `systemctl enable docker.service containerd.service`
cat > "$CHROOT_PATH/tmp/live-user-docker-group.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
getent group docker >/dev/null || { echo "docker group missing: docker-ce did not create it" >&2; exit 1; }
cur="$(echo 'get passwd/user-default-groups' | debconf-communicate user-setup | cut -d' ' -f2-)"
[ -n "$cur" ] || { echo "user-setup default group list is empty" >&2; exit 1; }
case " $cur " in *" docker "*) ;; *) cur="$cur docker" ;; esac
echo "user-setup passwd/user-default-groups string $cur" | debconf-set-selections
echo 'get passwd/user-default-groups' | debconf-communicate user-setup | grep -Eq ' docker( |$)'
EOF
chmod 755 "$CHROOT_PATH/tmp/live-user-docker-group.sh"
chroot_exec "/tmp/live-user-docker-group.sh"
rm -f "$CHROOT_PATH/tmp/live-user-docker-group.sh"
```

* Proof (T3, container `ubuntu:24.04` arm64: user-setup 1.95ubuntu1, adduser 3.137ubuntu1): default is `adm cdrom dip lpadmin plugdev sambashare debian-tor libvirtd users`; after the snippet `config.dat` holds `Value: ... users docker` with `Owners: user-setup`; running the real `/usr/lib/user-setup/user-setup-apply` with casper's debconf answers (`passwd/username=companion`, uid, blank password) yielded `companion adm cdrom sudo dip plugdev users docker lpadmin sambashare`. The test could not run casper itself or a real squashfs.
* Live-session gotcha to guard in verify-iso: a UID 1000-59999 account in the squashfs makes `user-setup-apply` skip creating the live user (see evidence table).

## 3. (b) Installed user: what Subiquity does and the robust mechanism

What happens (24.04.4/.5): see evidence table. Consequences:

| Mechanism | Verdict |
|---|---|
| casper `USERGROUPS` | Does not exist. |
| `/etc/adduser.conf` `EXTRA_GROUPS`+`ADD_EXTRA_GROUPS=1` | Does not apply (Subiquity uses `useradd`; T5). Also leaks `docker` into every later `adduser`. Rejected. |
| Autoinstall `identity.groups` | Only Subiquity >= 26.04 and only autoinstall. Not available on a 24.04 base or in the interactive desktop installer. Mention for a future resolute (26.04) image. |
| Edit the snap's `users-and-groups` | Snap is in the signed seed (`snap-store`/`thunderbird` removal is already deferred for that reason, customize-chroot.sh first-boot script). Not possible. |
| `pam_group` (`/etc/security/group.conf`) | Rejected on reasoning, UNVERIFIED by test: it grants groups to the PAM-authenticated process only; GNOME apps are started by the `systemd --user` manager, whose group set comes from `/etc/group`, so desktop terminals would likely lack `docker`. |
| Boot-time oneshot adding the `sudo` group members to `docker` | **Recommended.** Works offline, before the display manager and before user sessions, regardless of installer version, and also covers admins created later. Layered with the existing online `provision.sh` path. |

Why `sudo` members and not "all UIDs >= 1000": Subiquity always puts the installer user in `sudo`, and `docker` is root-equivalent anyway, so granting it to exactly the accounts that already have `sudo` adds no new class of principal (it removes only the password prompt). It keeps service/kiosk accounts out. Opt-out file: `/etc/ci-os/no-docker-group`.

Defect found in current `provision.sh`: when run by systemd as root there is no `SUDO_USER`, so `detect_user` (lines 81-91) picks `root` (`ACTUAL_USER="${USER:-$(whoami)}"`), and `add_user_to_docker_group` (295-317) does `usermod -aG docker root`; the installer user is never added. Fixing the resolution order (an explicit `CI_OS_TARGET_USER`, then `SUDO_USER`, then the lowest-UID login user) is a separate follow-up; the oneshot below makes Docker access independent of that online run.

### Final files (installed system)

`/usr/lib/ci-os/ci-os-docker-group` (mode 755; tested in the container, T2):

```bash
#!/bin/bash
# Companion OS: put the machine's administrators (members of 'sudo') in the 'docker' group.
#
# Why this exists: the installer (ubuntu-desktop-bootstrap / Subiquity 24.04.x) creates the first user with
# `useradd --groups <fixed list>,sudo`; the list is baked into the snap and 'docker' is not in it, and
# /etc/adduser.conf is not consulted by useradd. So the group is granted here, offline, before any login.
# Idempotent and quick: safe to run on every boot (and from a .path unit).
# Opt out: touch /etc/ci-os/no-docker-group
set -u
[ -e /etc/ci-os/no-docker-group ] && { echo "ci-os-docker-group: /etc/ci-os/no-docker-group present; leaving groups alone"; exit 0; }

if ! getent group docker >/dev/null; then
 groupadd --system docker || { echo "ci-os-docker-group: cannot create group docker" >&2; exit 0; }
fi

uid_min="$(awk '$1=="UID_MIN"{print $2}' /etc/login.defs 2>/dev/null)"; uid_min="${uid_min:-1000}"
uid_max="$(awk '$1=="UID_MAX"{print $2}' /etc/login.defs 2>/dev/null)"; uid_max="${uid_max:-60000}"

rc=0
for u in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
 uid="$(id -u "$u" 2>/dev/null)" || continue
 { [ "$uid" -ge "$uid_min" ] && [ "$uid" -le "$uid_max" ]; } || continue
 if id -nG "$u" | tr ' ' '\n' | grep -qx docker; then continue; fi
 if usermod -aG docker "$u"; then echo "ci-os-docker-group: added $u to docker"; else echo "ci-os-docker-group: usermod failed for $u" >&2; rc=1; fi
done
exit "$rc"
```

`/usr/lib/systemd/system/ci-os-docker-group.service` (enable with `ln -sf` into `multi-user.target.wants`; `systemd-analyze verify` printed no warnings, T1):

```ini
[Unit]
Description=Companion OS: put administrators in the docker group
Documentation=file:///usr/share/doc/ci-os/live-docker.md
# Installed system only. A live session's user gets docker from casper (debconf passwd/user-default-groups).
ConditionPathExists=!/cdrom/casper/vmlinuz
ConditionPathExists=!/etc/ci-os/no-docker-group
After=local-fs.target
Before=systemd-user-sessions.service display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/lib/ci-os/ci-os-docker-group

[Install]
WantedBy=multi-user.target
```

Container test T2 result (ubuntu:24.04): `sudo`+uid 2000 and 2002 added; `bob` (no sudo) untouched; system uid 150 in `sudo` untouched; second run is a no-op (rc 0); opt-out file honoured.

Optional hardening, UNVERIFIED: a `ci-os-docker-group.path` with `PathChanged=/etc/group` and `Unit=ci-os-docker-group.service` would also catch admins created after boot. Whether systemd's inotify handling fires on `rename`-over of `/etc/group` was not tested; add it only if QEMU test T-path (`useradd -G sudo x`, then within 5 s `id -nG x` shows docker) passes. Its own `usermod` edit re-triggers one harmless no-op run.

This replaces the earlier draft's marker-file oneshot: no marker is needed because the unit is idempotent.

## 4. (c) Offline first-boot oneshot, refined from D16/D17

Design notes: (1) idempotent, runs every boot, so the "no user yet, retry next boot" marker hack disappears (OEM-style installs are covered); (2) selects `sudo` members rather than "any UID >= 1000 with a home in /home" (the `$1!="ci"` name exclusion becomes unnecessary; `ci` is added by `provision.sh:771-777` on purpose); (3) `Before=systemd-user-sessions.service` in addition to the display manager, so tty/ssh logins also see the group; (4) creates the `docker` group if the package did not (`docker-ce.postinst` only creates it on a fresh install); (5) opt-out file. Effective after the next login (group sets are fixed per session). First GUI login after the first reboot already has it because the unit runs before `display-manager.service`.

## 5. (d) Live-guard exemption and the Docker data root in live boots

### 5.1 Exact lines

* `backends/ubuntu/chroot/customize-chroot.sh:811` `chroot_exec "systemctl enable docker.service containerd.service"` and `:817-826` the guard loop. The loop's unit list is `hostapd-setup.service dnsmasq-setup.service setup-backend.service setup-network-monitor.service nginx.service`. **`docker.service`, `docker.socket` and `containerd.service` currently have no `ConditionPathExists` and no `10-not-live.conf`.** Docker therefore already starts in every live boot today (it will fail there on overlay2 until the storage unit below exists).
* The earlier design draft proposed to add the same guard to `docker.service`, `docker.socket` and `containerd.service`. That is **not** what is implemented: the decision (2026-10-13) is that Docker runs in every boot mode, so the guard loop names `nginx.service` and the setup-stack units only, and `verify-iso.sh` section 3b fails if a `/cdrom/casper` or `boot=casper` condition ever appears on a Docker unit.
* The code, as shipped, in Step 10d of `customize-chroot.sh`:

```bash
# Docker and containerd are intentionally absent from the 10-not-live.conf guard list.
chroot_exec "systemctl enable docker.service docker.socket containerd.service"
```

(`ConditionKernelCommandLine=!boot=casper` is NOT a Stick detector: the stock ISO has no `boot=casper` and the Stick has it, so it only ever distinguishes the two when used positively.)

### 5.2 Plain ISO versus Stick detection (if ever needed)

Not needed for Docker. If a future unit must tell them apart: Stick = `ConditionKernelCommandLine=ci_stick.slot` (the word matches `ci_stick.slot=A`; set by `bootcfg.rs:182`) together with `ConditionPathExists=/cdrom/casper/vmlinuz`; "persistence actually in use" is better read from the ext4 sysfs entry that casper's mount creates (`/sys/fs/ext4/<kname of /dev/disk/by-label/writable>`) than from the command line, because `persistent` with no matching volume silently falls back to tmpfs (`casper.noble:557-566`). The storage script below uses exactly that rule.

### 5.3 Why a storage shim is required, and what it does

Live root: `mount -t overlay -o upperdir=/cow/upper,lowerdir=...,workdir=/cow/work /cow $rootmnt` (`casper.noble:683`), with `/cow` = tmpfs (plain ISO) or `writable` ext4 (Stick). So `/var/lib/docker` is an overlayfs path either way. T-ovl (privileged `ubuntu:24.04`, Docker Desktop VM kernel `7.0.14-linuxkit`, root fs overlay): A) overlay with `upperdir` on the overlay root -> `overlay: filesystem on /t/u not supported as upperdir`; B) upper on tmpfs -> mounts, writes; C) upper under a bind-mounted tmpfs directory that sits on the overlay root -> mounts. This is a different kernel from Ubuntu noble's; the QEMU test T-live-0 must re-prove it on the real kernel.

* Engine 29+ fresh installs use the containerd image store, so snapshot data lives under containerd's root, not `/var/lib/docker`; Engine <29 / upgraded hosts use overlay2 under `/var/lib/docker`. Because `docker.service` runs `dockerd --containerd=/run/containerd/containerd.sock` (system containerd), both `/var/lib/docker` and `/var/lib/containerd` must be on a real filesystem. Which directory holds what for the Docker CE .deb was not inspected (UNVERIFIED); binding both makes it moot. No `daemon.json` change is needed, so the installed system is untouched and the daemon's behaviour is identical everywhere else.
* Plain ISO or Stick without a usable `writable` volume: **tmpfs**, default `size=40%` of RAM (override in `/etc/ci-os/live-container.conf`, `CI_LIVE_TMPFS_SIZE`). It counts against RAM only as it fills; casper's own `/cow` tmpfs is capped separately (50% default), so the two together can exceed RAM: that is the OOM risk and why the cap exists. Nothing survives shutdown, same as the rest of a plain live session.
* Stick with `persistent` and casper actually using the `writable` ext4: the volume is mounted a second time (same device, same options `rw,noatime` as casper's mount, so the kernel shares one superblock) and Docker's directories are `ci-container/{docker,containerd}`, a sibling of casper's `upper/` and `work/`. casper only moves top-level content into `upper/` when `upper/` does not exist yet (`casper.noble:572-581`), so a sibling directory is stable. Space: `CI-PERSIST` is 12.4 GiB and also holds the whole live overlay; Docker images compete with it (open question). `vfs` or `fuse-overlayfs` are not recommended (vfs copies every layer; fuse-overlayfs adds a package and `/dev/fuse` for nothing, because bind-mounted ext4/tmpfs works with overlay2/overlayfs).
* When the Stick is removed: the live root itself (squashfs lower on the medium, ext4 upper) is already gone or I/O-erroring, as for any casper persistence session; Docker will log I/O errors, and `docker.service` (`Restart=always`, `StartLimitBurst=3`/60 s in the upstream unit) stops retrying after three failures. We add no special handling beyond ordered `ExecStop` unmounts for a clean shutdown. UNVERIFIED by test; QEMU `device_del` on the stick is the manual probe (section 8).

### 5.4 Final files (live only; all inert on an installed system)

`/usr/lib/ci-os/ci-os-live-container-storage` (mode 755). Exercised in a privileged `ubuntu:24.04` container with a simulated `/cdrom/casper/vmlinuz`, a loop-mounted ext4 labelled `writable`, and a bind-mounted `/proc/cmdline` (`t-store.sh`): S0 not-live -> no-op; S1 plain live -> `tmpfs`, both dirs tmpfs, overlay mount with upper under `/var/lib/docker` OK, `stop` unmounts; S2 `persistent` + volume mounted by "casper" -> `ext4 /dev/loop0[/ci-container/docker]`, `upper`/`work`/marker untouched, overlay mount on it OK, `stop` unmounts; S3 `persistent` but volume not claimed by casper -> tmpfs; S4 `nopersistent` -> tmpfs. Not exercised: real udev symlink timing, real casper, `/sys/fs/ext4` behaviour after `switch_root`.

```bash
#!/bin/bash
# Companion OS live session: give Docker and containerd a backing filesystem that overlayfs can use.
#
# In a casper live session "/" is an overlayfs whose upper layer is tmpfs (plain ISO) or the ext4 'writable'
# partition (Companion Stick, boot=casper persistent). Docker's overlay2 driver and containerd's overlayfs
# snapshotter need a real filesystem under their data roots (xfs ftype=1, ext4, btrfs, tmpfs...), not an
# overlayfs, so /var/lib/docker and /var/lib/containerd are bind-mounted from:
# persist the 'writable' (or legacy 'casper-rw') ext4 volume, when casper is actually using it
# tmpfs otherwise (size-capped; contents vanish at shutdown, like the rest of a plain live session)
# Not a live session: does nothing (the installed system keeps /var/lib/docker on its own disk).
set -euo pipefail
say { echo "ci-os-live-container-storage: $*"; }

action="${1:-start}"
BASE=/run/ci-os/live-container

if [ "$action" = stop ]; then
 for d in docker containerd; do mountpoint -q "/var/lib/$d" && umount "/var/lib/$d" 2>/dev/null || true; done
 mountpoint -q "$BASE/persist" && { umount "$BASE/persist" 2>/dev/null || umount -l "$BASE/persist" || true; }
 mountpoint -q "$BASE/tmpfs" && { umount "$BASE/tmpfs" 2>/dev/null || umount -l "$BASE/tmpfs" || true; }
 rm -f "$BASE/backing"
 exit 0
fi

[ -e /cdrom/casper/vmlinuz ] || { say "not a live session; nothing to do"; exit 0; }

CI_LIVE_TMPFS_SIZE="40%" # tmpfs mode only; override in /etc/ci-os/live-container.conf
# shellcheck disable=SC1091
[ -r /etc/ci-os/live-container.conf ] && . /etc/ci-os/live-container.conf

mkdir -p "$BASE/persist" "$BASE/tmpfs"
chmod 0711 /run/ci-os "$BASE"

want_persist=0
case " $(cat /proc/cmdline) " in *" persistent "*) want_persist=1 ;; esac
case " $(cat /proc/cmdline) " in *" nopersistent "*) want_persist=0 ;; esac

store=""; backing=tmpfs
if [ "$want_persist" = 1 ]; then
 label=writable
 for _ in $(seq 1 20); do # udev may still be creating the symlinks
 if [ -e /dev/disk/by-label/writable ] || [ -e /dev/disk/by-label/casper-rw ]; then break; fi
 sleep 0.5
 done
 [ -e /dev/disk/by-label/writable ] || label=casper-rw
 dev="$(readlink -f "/dev/disk/by-label/$label" 2>/dev/null || true)"
 if [ -b "$dev" ]; then
 fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
 if [ "$fstype" != ext4 ]; then
 say "persistence volume $dev is '$fstype', not ext4: using tmpfs"
 elif [ ! -d "/sys/fs/ext4/$(basename "$dev")" ]; then
 # casper mounts the volume as the overlay upper layer in the initramfs. If it is not mounted, casper
 # fell back to tmpfs for "/", and so do we (never mount a volume casper did not claim).
 say "$dev is not mounted by casper (no persistence in use): using tmpfs"
 else
 # Same device, same options as casper's own mount ("rw,noatime"), so the kernel shares the superblock.
 mount -t ext4 -o rw,noatime "$dev" "$BASE/persist"
 store="$BASE/persist/ci-container" # sibling of casper's upper/ and work/: casper never touches it
 backing=persist
 fi
 else
 say "no 'writable' volume found: using tmpfs"
 fi
fi
if [ "$backing" = tmpfs ]; then
 mount -t tmpfs -o "size=${CI_LIVE_TMPFS_SIZE},mode=0711" tmpfs "$BASE/tmpfs"
 store="$BASE/tmpfs"
fi

for d in docker containerd; do
 mkdir -p "$store/$d" "/var/lib/$d"
 chmod 0711 "$store"
 mountpoint -q "/var/lib/$d" || mount --bind "$store/$d" "/var/lib/$d"
done
echo "$backing" > "$BASE/backing"
say "Docker and containerd data live on $backing ($(findmnt -no FSTYPE -T /var/lib/docker))"
```

`/usr/lib/systemd/system/ci-os-live-container-storage.service` (`systemd-analyze verify` clean, T1):

```ini
[Unit]
Description=Companion OS live session: backing store for Docker and containerd
Documentation=file:///usr/share/doc/ci-os/live-docker.md
# Live sessions only (plain ISO and Companion Stick). /cdrom is where casper mounts the boot medium; the stock
# Ubuntu 24.04 live session has no boot=casper on its command line, so the medium is the reliable marker.
ConditionPathExists=/cdrom/casper/vmlinuz
Before=containerd.service docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/ci-os/ci-os-live-container-storage start
ExecStop=/usr/lib/ci-os/ci-os-live-container-storage stop
TimeoutStartSec=60
```

`/etc/systemd/system/docker.service.d/20-ci-os-live.conf` and the identical `/etc/systemd/system/containerd.service.d/20-ci-os-live.conf`:

```ini
[Unit]
# No-op on an installed system (the storage unit's ConditionPathExists skips it). In a live session it puts
# /var/lib/docker and /var/lib/containerd on a filesystem overlayfs can use before the daemons start.
Wants=ci-os-live-container-storage.service
After=ci-os-live-container-storage.service
```

`Wants=` (not `Requires=`) so a storage failure still lets Docker try and fail visibly. The drop-in file names must never be `10-not-live.conf`, so they cannot collide with a future guard.

Wiring into `customize-chroot.sh` Step 10d (after `systemctl enable docker...`): put the five files above under `backends/ubuntu/chroot/files/docker-live/` and `install -D -m 755 / 644` them into `$CHROOT_PATH`, then `chroot_exec "systemctl enable ci-os-docker-group.service"` (a `WantedBy` symlink; the storage unit needs no enable, it is pulled in by the drop-ins). `Mint` shares the casper boot flow and can reuse the same files.

Boot-time cost to measure (UNVERIFIED): upstream `docker.service` has `Wants=network-online.target`/`After=network-online.target`; on an offline live boot this may delay the first `docker` call until NetworkManager-wait-online finishes. The guest test records `systemd-analyze blame` for it. If it hurts, a live-only reset of `After=`/`Wants=` can be added to the storage service's drop-in.

## 6. (e) Security

* Live session: no change; the live user already has passwordless `sudo` (`25adduser:76-78`).
* Installed system: `docker` group = root-equivalent without a password (socket `0660 root:docker`, `docker run -v /:/host`). The Hub compose files already mount `/var/run/docker.sock` into containers (`core/lib/ci-hub.sh:410,431`, `:ro` does not restrict the API), so a rootful daemon is a design assumption of the Hub.
* Options considered: **rootless Docker** (`docker-ce-rootless-extras`) needs a per-user systemd instance, `net.ipv4.ip_unprivileged_port_start` for Traefik 80/443, and a different socket path, and conflicts with the Hub's expectations: not a drop-in. **userns-remap** is incompatible with the default containerd image store on Engine 29 (docs.docker.com/engine/storage/containerd) and breaks the Hub's host-path bind mounts and `--privileged` use. **`sudo docker`** only: safe but contradicts the user's decision.
* Recommended default (user's decision implemented with the narrowest scope): `docker` for members of `sudo` only, an opt-out file, and no silent hardening of `daemon.json`. Flag as open question Q-SEC rather than choosing more: whether to extend the group to all human users, or to ship `no-new-privileges`/log rotation defaults.
* `ci` user is already added on purpose (`provision.sh:759-777`).

## 7. (f) verify-iso.sh assertions (rootless, no boot)

Extend the `unsquashfs` list at `verify-iso.sh:76-83` with: `etc/group etc/gshadow etc/passwd var/cache/debconf/config.dat usr/lib/systemd/system/docker.service usr/lib/systemd/system/docker.socket usr/lib/systemd/system/containerd.service usr/lib/systemd/system/ci-os-docker-group.service usr/lib/systemd/system/ci-os-live-container-storage.service usr/lib/ci-os etc/ci-os`. Add after section 3 (existing lines 128-131 already check `docker.service`/`containerd.service` are enabled; replace that loop to add `docker.socket`):

```bash
section "3b. Docker works in every boot mode (installed, plain-ISO live, Companion Stick live)"
for u in docker.service containerd.service; do
 unit_enabled "$u" && pass "enabled: $u" || fail "NOT enabled: $u"
done
in_listing 'etc/systemd/system/sockets\.target\.wants/docker\.socket -> ' \
 && pass "enabled: docker.socket" || fail "NOT enabled: docker.socket"
# Docker must NOT be guarded against live sessions (decision: Docker runs in the Stick live boot and the plain ISO).
for u in docker.service docker.socket containerd.service; do
 if grep -rqsE '/cdrom/casper|boot=casper' "$R/etc/systemd/system/$u.d" "$R/usr/lib/systemd/system/$u" 2>/dev/null; then
 fail "live-session guard found on $u (Docker must run in a live boot)"
 else
 pass "no live-session guard on $u"
 fi
done
for u in docker containerd; do
 f="$R/etc/systemd/system/$u.service.d/20-ci-os-live.conf"
 if file_has "$f" '^Wants=ci-os-live-container-storage\.service$' && file_has "$f" '^After=ci-os-live-container-storage\.service$'; then
 pass "$u waits for the live storage unit"
 else fail "$u has no 20-ci-os-live.conf ordering on the live storage unit"; fi
done
S="$R/usr/lib/systemd/system/ci-os-live-container-storage.service"
file_has "$S" '^ConditionPathExists=/cdrom/casper/vmlinuz$' && pass "live storage unit runs only in live sessions" || fail "live storage unit is not live-only"
file_has "$S" '^Before=.*docker\.service' && pass "live storage unit runs before docker.service" || fail "live storage unit not ordered before docker.service"
[[ -x "$R/usr/lib/ci-os/ci-os-live-container-storage" ]] && pass "live storage script present and executable" || fail "live storage script missing"
G="$R/usr/lib/systemd/system/ci-os-docker-group.service"
file_has "$G" '^ConditionPathExists=!/cdrom/casper/vmlinuz$' && pass "docker-group unit is installed-system only" || fail "docker-group unit missing its not-live condition"
unit_enabled ci-os-docker-group.service && pass "enabled: ci-os-docker-group.service" || fail "NOT enabled: ci-os-docker-group.service"
[[ -x "$R/usr/lib/ci-os/ci-os-docker-group" ]] && pass "docker-group script present and executable" || fail "docker-group script missing"
# Group and the live user's group list.
grep -qE '^docker:x:[0-9]+:' "$R/etc/group" && pass "group docker exists in the image" || fail "group docker missing from /etc/group"
if awk 'BEGIN{RS=""} /Name: passwd\/user-default-groups/' "$R/var/cache/debconf/config.dat" 2>/dev/null | grep -Eq '^Value: .*(^| )docker( |$)'; then
 pass "debconf passwd/user-default-groups contains docker (casper live user gets it)"
else fail "debconf passwd/user-default-groups lacks docker (live user would not be in docker)"; fi
# user-setup-apply skips creating the live user if any 1000-59999 account exists in the image.
if awk -F: '$3>=1000 && $3<=59999 {f=1} END{exit !f}' "$R/etc/passwd"; then
 fail "image has a UID 1000-59999 account: casper will NOT create the live user"
else pass "no UID 1000-59999 account in the image (casper creates the live user)"; fi
# casper has no USERGROUPS; do not cargo-cult it.
check "casper.conf does not pretend to set USERGROUPS (casper ignores it)" bash -c "! grep -q USERGROUPS '$R/etc/casper.conf'"
check "docker.io is not installed (conflicts with docker-ce)" bash -c "! awk 'BEGIN{RS=\"\"} \$1==\"Package: docker.io\"' '$R/var/lib/dpkg/status' | grep -q 'install ok installed'"
```

(`config.dat` entries are blank-line separated `Name:/Template:/Value:/Owners:` blocks, as printed in T3.)

## 8. (f) QEMU test plan

Harness: `stick/tests/qemu/docker-live.sh` + `stick/tests/qemu/guest-docker-test.sh` (new; both syntax-checked with `bash -n`/`sh -n`, shellcheck gives only SC2054/SC2015 style notes; **not executed** because no built ISO was available in this stream). It boots kernel and initrd straight from the ISO with the same kernel arguments GRUB gives them, a second USB disk labelled `CI_TEST` carries the guest script and an offline `hello-world` image tarball, `systemd.run=` runs the guest script as soon as basic.target is reached and powers off, results are `CI-DOCKER-TEST <name> PASS|FAIL|INFO` lines on the serial console, and the VM has `-nic none` so the run is provably offline. GRUB, shim and Secure Boot are already covered by `stick/tests/secureboot`; `systemd.run` cannot be injected through `ci-stick --extra-cmdline` because `validate_extra_cmdline` (`grubenv.rs:176-185`) refuses quotes, `$`, `;`, so the harness uses direct kernel boot.

Prerequisite (once, on any online host): `docker pull --platform linux/amd64 hello-world && docker save hello-world -o stick/tests/qemu/hello-world-amd64.tar`.

Run on this Mac (TCG; allow 15-30 min per boot, mirror `iso-boot.sh` flags in `stick-qemu-evidence/macos-and-image-checks/iso-boot.sh`):

```bash
# Plain ISO live session (no persistence): expects Docker data on tmpfs
stick/tests/qemu/docker-live.sh iso path/to/companion-os-*.iso
# Companion Stick: build the image first with the repo's flash path (stick/tests/secureboot or `ci-stick flash --image`), then
stick/tests/qemu/docker-live.sh stick path/to/companion-os-*.iso path/to/stick.img # 2 boots; boot 2 proves persistence
```

Assertions the guest script makes (names in the serial log): `groups` (`id -nG companion` contains `docker`), `cli` (`runuser -u companion -- docker version` works with no sudo), `daemon-active`, `backing` (`findmnt -T /var/lib/docker` is `tmpfs` for the ISO, `ext4` for the Stick, and never `overlay`), `backing-marker` (`/run/ci-os/live-container/backing` is `tmpfs`/`persist`), `storage-unit` active, `load` (`docker load -i hello-world.tar`), `run` (`docker run --rm --network none hello-world` prints "Hello from Docker!" as the unprivileged user), second Stick boot: `persisted` (image still present), plus `INFO` lines for `docker info` driver, containerd root fs and `systemd-analyze blame` for docker/containerd/wait-online. The guest script and harness are `stick/tests/qemu/guest-docker-test.sh` and `stick/tests/qemu/docker-live.sh`.

Additional probes (manual, record outputs in the evidence folder):
* **T-live-0 control:** boot the ISO with the kernel argument `systemd.mask=ci-os-live-container-storage.service` and run `docker info`: expect the overlay2 probe to fail ("driver not supported" / `Backing Filesystem` not usable). This is the check that proves on Ubuntu's kernel what T-ovl showed on the Docker Desktop kernel.
* **T-removal:** with the Stick booted and Docker running a container, QMP `device_del stick` (see `stick-qemu-evidence/macos-and-image-checks/qmp.py`) and record `docker ps`, `journalctl -u docker` after 60 s.
* **T-path** (only if the optional `.path` unit is adopted): in a booted installed system `useradd -m -G sudo x`, `sleep 5`, `id -nG x`.

**Installed system** (GUI install cannot be fully automated; the repo already has the install flow evidence in `stick-qemu-evidence/installer/`): (1) run the desktop installer in the live QEMU session to `target.qcow2`, create user `tester`; (2) before restarting, still in the live session: `mount /dev/<target-root> /mnt/t; grep '^docker:' /mnt/t/etc/group` (group exists, `tester` not listed: this documents the installer behaviour), `chroot /mnt/t systemctl is-enabled ci-os-docker-group.service` (expect `enabled`), and add `GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0 systemd.unit=multi-user.target"` via `/mnt/t/etc/default/grub.d/99-serial.cfg` then `chroot /mnt/t update-grub`; (3) boot `target.qcow2` with OVMF and log in on the serial console as `tester` (no sudo): `id -nG` must contain `docker` (the oneshot ran before `systemd-user-sessions`), `journalctl -b -u ci-os-docker-group -o cat` must contain `added tester to docker`, then `docker load -i <hello-world.tar from a second disk>` and `docker run --rm hello-world`. Run the same guest script with mode `installed` and user `tester` (it asserts the storage unit's `ConditionResult=no` and that `/var/lib/docker` is not an overlayfs).

Expected pass table for the three modes:

| Assertion | installed | plain ISO live | Stick live (boot 1 / boot 2) |
|---|---|---|---|
| `id -nG` has `docker` | yes (after oneshot) | yes (debconf default) | yes |
| `docker run hello-world` offline as the user | yes | yes | yes |
| `/var/lib/docker` fs | root disk fs | tmpfs | ext4 |
| survives reboot | yes | no | yes (boot 2 `persisted`) |
| `ci-os-live-container-storage` | skipped | active | active |

## 9. What I could not verify (see `unverified`)

Nothing in this stream was run on a built Companion OS ISO, a real casper boot or a real Stick; the live-session facts come from the Launchpad casper/user-setup/adduser sources, Subiquity tags, container tests that reproduce the user-setup and storage logic, and a nested-overlay test on a non-Ubuntu kernel.
