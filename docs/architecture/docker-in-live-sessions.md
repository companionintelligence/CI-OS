# Docker in Companion OS: installed, live ISO and Companion Stick live boot

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Date 2026-10-18 (designed 2026-10-13 on Ubuntu 24.04.5, ported to Ubuntu 26.04.1). Status: **implemented** in `backends/ubuntu/chroot/customize-chroot.sh` (Step 10d, the Docker block at lines 963-1019) and
`backends/ubuntu/chroot/payload/docker/`, asserted by `backends/ubuntu/iso/scripts/verify-iso.sh` (section 3b: 19 checks, all passed on the real 26.04.1 build of 2026-10-18).
The QEMU tests of section 8 (`stick/tests/qemu/docker-live.sh`) passed on the 24.04.5 based v7 image (retired baseline, section 10) and **have not been run on a 26.04.1 image**.
What changed from 24.04 to 26.04.1 is in [ubuntu-2604-port-notes.md](ubuntu-2604-port-notes.md).

Evidence tags: **[V]** verified (run, or read in the cited file), **[I]** implemented, not proven end to end, **[N]** not implemented or not checked. Measurements and line numbers of Ubuntu
24.04 (noble) are labelled "retired baseline (24.04.5)"; they stay where they explain a design decision.

## 0. Summary of findings

1. **`casper.conf` has no `USERGROUPS`.** casper reads only `USERNAME USERFULLNAME HOST BUILD_SYSTEM FLAVOUR`. Nothing in the 34 `casper-bottom` scripts, `casper` or `casper-functions` refers to a group list
   (grep over the Launchpad `applied/ubuntu/noble` and `applied/ubuntu/resolute` files). The premise "add `docker` to `USERGROUPS`" is a no-op. The live user's groups come from debconf
   `passwd/user-default-groups` (user-setup), read from the **rootfs** debconf database. The supported, targeted hook is to set that question in the squashfs. On 26.04.1, casper 26.04.2's `25adduser`
   is the same logic (`diff` against noble's clean; read again in the real initrd: it sets the `passwd/*` answers and runs `chroot /root /usr/lib/user-setup/user-setup-apply`). [V] Proven end to end with the real
   `user-setup-apply` on 24.04 (T3 below, retired baseline); on 26.04.1 the answer is asserted in the built image by `verify-iso.sh` and the live user has not been seen in a booted session [I].
2. **The interactive installer cannot be told about `docker`; the autoinstall path can.** Subiquity creates the first user with `useradd --groups <list>` where `<list>` is a file baked into the snap at build
   time (`adm cdrom dip lpadmin plugdev sambashare debian-tor libvirtd users lxd`) intersected with the target's groups, plus `sudo`. `docker` is never in it, and `useradd` ignores `/etc/adduser.conf`.
   Autoinstall `identity.groups: {append: [...]}` exists from Subiquity 26.04 and is merged with that list (`models/identity.py` of snap rev 665; an explicit group is not intersected with the target's, so
   `useradd --groups docker` would fail on a target without the group). The one-click installer ([one-click-install.md](one-click-install.md)) asks for `docker` when the image has the group. Every other install
   (the interactive installer, which has no page for it) is covered by our own boot-time code: an idempotent offline oneshot that adds every `sudo`-group member to `docker`, plus the online `provision.sh`
   path, which today adds the wrong user (section 3). [V] code and schema, [N] a real run.
3. **Docker is not guarded against live sessions.** Step 10d writes `10-not-live.conf` only for `hostapd-setup`, `dnsmasq-setup`, `setup-backend`, `setup-network-monitor` and `nginx` (the loop at
   `customize-chroot.sh:1011-1019`). `docker.service`, `docker.socket` and `containerd.service` are enabled (line 963) with no `ConditionPathExists`, on purpose: the decision of 2026-10-13 is that Docker runs in every
   boot mode. `verify-iso.sh` section 3b fails if a `/cdrom/casper` or `boot=casper` condition ever appears on a Docker unit. [V]
4. **Docker cannot use the live root as its data root.** In a casper live session `/` is an overlayfs. A local test (T-ovl, kernel 7.0.14-linuxkit, not Ubuntu's kernel) shows
   `overlay: filesystem on /t/u not supported as upperdir` when the upper dir is on an overlayfs, while tmpfs, and a bind-mounted tmpfs, work. Docker's `overlay2` driver and the containerd `overlayfs` snapshotter both
   need a real filesystem. Fix: a live-only oneshot that bind-mounts `/var/lib/docker` and `/var/lib/containerd` from (a) a sibling directory on the casper-owned `writable` ext4 volume (Stick), or (b) a size-capped
   tmpfs (plain ISO). Section 5 has the files and the container tests that exercised them. [V] on the Docker Desktop kernel; the same probe on Ubuntu's 7.0 kernel is the control T-live-0 of section 8 (not run).
5. **Docker group membership does not change the live threat model.** casper writes `${USERNAME} ALL=(ALL) NOPASSWD: ALL` for the live user (`25adduser`). On the installed system it is a real step up from
   password-protected `sudo`; that is the open question Q-SEC.

## 1. Evidence base

| Claim | Evidence |
|---|---|
| casper.conf supports only 5 variables | Launchpad `casper.conf?h=applied/ubuntu/noble`, header lines 2-3: "USERNAME, USERFULLNAME, HOST, BUILD_SYSTEM, FLAVOUR". `grep -rn USERGROUPS` over the casper, 25adduser and helper files returns nothing. `25adduser` and the casper script are identical on `resolute` (`diff` clean for `25adduser`; `casper.noble` == `casper.resolute`). |
| initrd `/etc/casper.conf` is what casper sources | `casper.noble:23` (`[ -f /etc/casper.conf ] && . /etc/casper.conf`), `casper.noble:1064-65` (copies it into the rootfs). `build-iso.sh` `brand_boot_media` (line 804) appends a cpio overlay carrying it. It covers only those 5 variables. |
| Live user creation | `25adduser`: sets debconf `passwd/*`, then `chroot /root /usr/lib/user-setup/user-setup-apply`, then writes `/root/etc/sudoers.d/casper` NOPASSWD (lines 76-78 on noble). `casper-functions.noble:43-51` `load_confmodule` sources `/root/usr/share/debconf/confmodule`, so the **rootfs** debconf DB is used. `casper.noble:1021` copies the rootfs `config.dat`. `casper` Depends on `user-setup` (`debian/control` line 14). |
| user-setup group logic | `user-setup-apply:213` `adduser --disabled-password ...`; `:242-256` creates `lpadmin sambashare`, then `db_get passwd/user-default-groups` and `adduser "$USER" $group` for each (silently skipped if the group does not exist); `:362` `adduser "$USER" sudo`. `Default: adm cdrom dip lpadmin plugdev sambashare debian-tor libvirtd users` (`user-setup.templates:22`, 1.95ubuntu1, retired baseline (24.04.5)). 26.04.1 ships user-setup 1.107ubuntu2 in the live layer; its template was not re-read [N], and `verify-iso.sh` asserts only that the answer in the built image contains `docker`. |
| Live user is NOT created if the rootfs has a UID 1000-59999 account | `functions.sh is_system_user` (`user-setup-apply:109`). Seen first-hand: the first T3 run silently created no user because the ubuntu:24.04 image has `ubuntu` (uid 1000). `verify-iso.sh` section 3b asserts there is no such account in the squashfs. |
| Subiquity 24.04.5 installer user creation (retired baseline) | `subiquity/server/controllers/install.py:670-710` (tag 24.04.5): `create_users` runs `useradd <user> --comment ... --shell /bin/bash --groups <csv> --create-home` then `chpasswd --encrypted`. `subiquity/common/resources.py:30-47`: groups = contents of snap file `users-and-groups`, then `.append("sudo")`, intersected with `getent group` of the target. The ISO's installer was `ubuntu-desktop-bootstrap_680.snap`. |
| Subiquity 26.04.1 | snap rev 665, extracted from the live layer of the real ISO. The group list and the merge with `identity.groups` are as in summary item 2. [V] read in `models/identity.py` |
| `groups` in autoinstall identity is new | `identity.py` has no `"groups"` key at tags 24.04.5, 25.04, 25.10; present at 26.04, 26.04.1, 26.10 (GitHub raw, grep count 0/0/0/1/1/1). Documented at `doc/reference/autoinstall-reference.rst:849-865` (26.04.1); the key is also in the schema `autoinstall-schema.json` of the snap. |
| useradd ignores adduser.conf; adduser does not | T5 in a 24.04 container (adduser 3.137ubuntu1): with `ADD_EXTRA_GROUPS=1`, `EXTRA_GROUPS="users docker"`: `adduser erin` -> `erin users docker`; `useradd -m frank` -> `frank`. adduser source `adduser.pl:885-887` (`add_extra_groups`/`extra_groups`). |
| Docker units and socket | moby `contrib/init/systemd/docker.service`: `ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock`, `Wants=network-online.target containerd.service`, `Requires=docker.socket`. `docker.socket`: `SocketMode=0660 SocketUser=root SocketGroup=docker`. `docker-ce.postinst` (docker-ce-packaging master): `groupadd --system docker` only on fresh install (`-z "$2"`), then `#DEBHELPER#`. |
| Engine 29 default image store | docs.docker.com/engine/storage/drivers/select-storage-driver: "Docker Engine 29.0 and later uses the containerd image store by default for fresh installations". docs.docker.com/engine/storage/containerd: "not available when using user namespace remapping (userns-remap)". Same page: overlay2 supported backing filesystems "xfs with ftype=1, ext4, btrfs (and more)"; overlayfs is not listed. |
| Docker probes overlay by really mounting | moby master `daemon/graphdriver/overlay2/overlay.go:143` `overlayutils.SupportsOverlay(testdir, true)`, then `fs.SupportsDType`. |
| Persistence layout (retired baseline (24.04.5): `casper.noble`) | `casper.noble:545-585,683`: `/cow` = tmpfs (default) or the `writable` device (`find_cow_device`, `casper-helpers.noble:195-262`, falls back to label `casper-rw`); `/cow/upper` and `/cow/work` are created on first use and everything else at the top level is moved into `upper` only if `upper` does not exist yet. `mount -t overlay -o upperdir=/cow/upper,... "/cow" "$rootmnt"`. `/cow` is not moved into the new root (`05mountpoints` moves only `/cdrom`). The persistence logic was read again in the unpacked 26.04.1 initrd for `live-media=` / `persistent` / `writable` only; the line numbers above were not re-proved [N]. Stick command line: `boot=casper live-media=/dev/disk/by-partlabel/CI-BOOT-A persistent ci_stick.slot=A quiet splash $extra_cmdline ---` (`stick/crates/ci-stick/src/bootcfg.rs:188`, pinned by the test at line 395); persistence is ext4 label `writable` on `CI-PERSIST` (`companion-stick.md`, `flash.rs:48`). |
| Today's repo behaviour | `customize-chroot.sh:963` enables docker, docker.socket and containerd; `:1011-1019` the guard loop (5 units, no Docker); `:1021-1028` records the baked tools. `provision.sh:82-91` `detect_user` and `:295-317` `add_user_to_docker_group`. `core/lib/ci-hub.sh:410,431` mount `/var/run/docker.sock:ro` into Hub containers. `verify-iso.sh:296-336` section 3b. |

## 2. (a) casper and the live user

* Where `USERGROUPS` is read from: **nowhere**. `/etc/casper.conf` (rootfs copy, and the copy inside `casper/initrd` that `build-iso.sh` overlays) is sourced by `scripts/casper` and is limited to the five variables
  above. The overlay already covers every variable casper understands; adding `USERGROUPS` there would be silently ignored, and `verify-iso.sh` fails an image whose `casper.conf` names it.
* Supported hook: debconf `passwd/user-default-groups`, owned by `user-setup`, stored in the rootfs `/var/cache/debconf/config.dat`. It is consumed only by `user-setup-apply` (casper's live user; oem-config users).
  It is **not** consumed by Subiquity, so it does not alter what `adduser` does elsewhere. That is why it is preferable to `adduser.conf` `ADD_EXTRA_GROUPS=1`, which would also leak into the installed target (the squashfs
  is copied there) and turn every later `adduser`-created account into a Docker-root-equivalent one. The split keeps `/var/cache/debconf/config.dat` and `user-setup` in the base layer
  ([ubuntu-iso-layers.md](ubuntu-iso-layers.md)).
* The change is made at build time, in the chroot, after docker-ce is installed, and extends the stock default instead of hard-coding it: `customize-chroot.sh:993-1005` reads the current answer with
  `debconf-communicate user-setup`, appends `docker` if it is missing, sets it with `debconf-set-selections` and checks it again. It stops the build if the `docker` group is missing or the answer is empty.
* Proof (T3, retired baseline (24.04.5): container `ubuntu:24.04` arm64, user-setup 1.95ubuntu1, adduser 3.137ubuntu1): default is `adm cdrom dip lpadmin plugdev sambashare debian-tor libvirtd users`; after the
  snippet `config.dat` holds `Value: ... users docker` with `Owners: user-setup`; running the real `/usr/lib/user-setup/user-setup-apply` with casper's debconf answers (`passwd/username=companion`, uid, blank
  password) yielded `companion adm cdrom sudo dip plugdev users docker lpadmin sambashare`. The test could not run casper itself or a real squashfs.
* Live-session gotcha guarded in `verify-iso.sh`: a UID 1000-59999 account in the squashfs makes `user-setup-apply` skip creating the live user.

## 3. (b) Installed user: what Subiquity does and the robust mechanism

What happens: see the evidence table. Consequences:

| Mechanism | Verdict |
|---|---|
| casper `USERGROUPS` | Does not exist. |
| `/etc/adduser.conf` `EXTRA_GROUPS` + `ADD_EXTRA_GROUPS=1` | Does not apply (Subiquity uses `useradd`; T5). Also leaks `docker` into every later `adduser`. Rejected. |
| Autoinstall `identity.groups: {append: [docker]}` | Works on Subiquity 26.04 and later, for autoinstall only. **Used by the one-click installer** when the image has the group. The interactive desktop installer has no page for it. |
| Edit the snap's `users-and-groups` | The snap is in the signed seed. Not possible. |
| `pam_group` (`/etc/security/group.conf`) | Rejected on reasoning, UNVERIFIED by test: it grants groups to the PAM-authenticated process only; GNOME apps are started by the `systemd --user` manager, whose group set comes from `/etc/group`, so desktop terminals would likely lack `docker`. |
| Boot-time oneshot adding the `sudo` group members to `docker` | **Shipped.** Works offline, before the display manager and before user sessions, regardless of how the user was created, and also covers admins created later. Layered with the existing online `provision.sh` path. |

Why `sudo` members and not "all UIDs >= 1000": Subiquity always puts the installer user in `sudo`, and `docker` is root-equivalent anyway, so granting it to exactly the accounts that already have `sudo` adds no new class of
principal (it removes only the password prompt). It keeps service and kiosk accounts out. Opt-out file: `/etc/ci-os/no-docker-group`.

**Defect still present in `provision.sh`:** when run by systemd as root there is no `SUDO_USER`, so `detect_user` (lines 82-91) picks `root` (`ACTUAL_USER="${USER:-$(whoami)}"`), and `add_user_to_docker_group`
(lines 295-317) does `usermod -aG docker root`; the installer user is never added. Fixing the resolution order (an explicit `CI_OS_TARGET_USER`, then `SUDO_USER`, then the lowest-UID login user) is a separate follow-up; the
oneshot makes Docker access independent of that online run.

### Shipped files (installed system)

| File | What it does |
|---|---|
| `payload/docker/usr/lib/ci-os/ci-os-docker-group` (mode 755) | Puts every member of `sudo` whose uid is within `UID_MIN..UID_MAX` of `/etc/login.defs` into `docker`; creates the group if the package did not; idempotent; honours `/etc/ci-os/no-docker-group`. Its comment names the 26.04 installer and the one-click path |
| `payload/docker/usr/lib/systemd/system/ci-os-docker-group.service` | `Type=oneshot`; `ConditionPathExists=!/cdrom/casper/vmlinuz` and `!/etc/ci-os/no-docker-group`; `Before=systemd-user-sessions.service display-manager.service`; `WantedBy=multi-user.target` (enabled by `customize-chroot.sh:991`) |

Container test T2 result (retired baseline (24.04.5): ubuntu:24.04): `sudo`+uid 2000 and 2002 added; `bob` (no sudo) untouched; system uid 150 in `sudo` untouched; second run is a no-op (rc 0); opt-out file honoured.

Optional hardening, UNVERIFIED: a `ci-os-docker-group.path` with `PathChanged=/etc/group` and `Unit=ci-os-docker-group.service` would also catch admins created after boot. Whether systemd's inotify handling fires on
`rename`-over of `/etc/group` was not tested; add it only if QEMU test T-path (`useradd -G sudo x`, then within 5 s `id -nG x` shows docker) passes. Its own `usermod` edit re-triggers one harmless no-op run.

## 4. (c) Offline first-boot oneshot

Design notes: (1) idempotent, runs every boot, so there is no "no user yet, retry next boot" marker file (OEM-style installs are covered); (2) selects `sudo` members rather than "any UID >= 1000 with a home in
/home" (`ci` is added by `provision.sh` on purpose); (3) `Before=systemd-user-sessions.service` in addition to the display manager, so tty and ssh logins also see the group; (4) creates the `docker` group if the package
did not (`docker-ce.postinst` only creates it on a fresh install); (5) opt-out file. Effective after the next login (group sets are fixed per session). The first GUI login after the first reboot already has it because
the unit runs before `display-manager.service`.

## 5. (d) Live-guard exemption and the Docker data root in live boots

### 5.1 The exemption

* `customize-chroot.sh:963` `chroot_exec "systemctl enable docker.service docker.socket containerd.service"` and `:1011-1019` the guard loop. The loop's unit list is `hostapd-setup.service dnsmasq-setup.service
  setup-backend.service setup-network-monitor.service nginx.service`. **`docker.service`, `docker.socket` and `containerd.service` have no `ConditionPathExists` and no `10-not-live.conf`.** Docker therefore starts in every
  live boot; it would fail there on overlay2 without the storage unit of 5.4.
* The earlier design draft proposed to add the same guard to the Docker units. That is **not** what is implemented: the decision (2026-10-13) is that Docker runs in every boot mode.
  `ConditionKernelCommandLine=!boot=casper` is NOT a Stick detector. The stock 26.04.1 menus carry no `boot=casper` (their kernel lines are `--- quiet splash`; casper's own initrd hook sets `BOOT=casper`), and the Stick's
  line has it, so the word only distinguishes the two when used positively.

### 5.2 Plain ISO versus Stick detection (if ever needed)

Not needed for Docker. If a future unit must tell them apart: Stick = `ConditionKernelCommandLine=ci_stick.slot` (the word matches `ci_stick.slot=A`; set by `bootcfg.rs:188`) together with
`ConditionPathExists=/cdrom/casper/vmlinuz`; "persistence actually in use" is better read from the ext4 sysfs entry that casper's mount creates (`/sys/fs/ext4/<kname of /dev/disk/by-label/writable>`) than from the command
line, because `persistent` with no matching volume silently falls back to tmpfs (`casper.noble:557-566`, retired baseline (24.04.5)). The storage script below uses exactly that rule.

### 5.3 Why a storage shim is required, and what it does

Live root: `mount -t overlay -o upperdir=/cow/upper,lowerdir=...,workdir=/cow/work /cow $rootmnt` (`casper.noble:683`), with `/cow` = tmpfs (plain ISO) or `writable` ext4 (Stick). So `/var/lib/docker` is an
overlayfs path either way. T-ovl (privileged `ubuntu:24.04`, Docker Desktop VM kernel `7.0.14-linuxkit`, root fs overlay): A) overlay with `upperdir` on the overlay root -> `overlay: filesystem on /t/u not supported as upperdir`;
B) upper on tmpfs -> mounts, writes; C) upper under a bind-mounted tmpfs directory that sits on the overlay root -> mounts. This is a different kernel from Ubuntu's; the QEMU control T-live-0 must re-prove it on the real kernel.

* Engine 29+ fresh installs use the containerd image store, so snapshot data lives under containerd's root, not `/var/lib/docker`; Engine <29 / upgraded hosts use overlay2 under `/var/lib/docker`. Because `docker.service`
  runs `dockerd --containerd=/run/containerd/containerd.sock` (system containerd), both `/var/lib/docker` and `/var/lib/containerd` must be on a real filesystem. Which directory holds what for the Docker CE .deb was not
  inspected (UNVERIFIED); binding both makes it moot. No `daemon.json` change is needed, so the installed system is untouched and the daemon's behaviour is identical everywhere else.
* Plain ISO or Stick without a usable `writable` volume: **tmpfs**, default `size=40%` of RAM (override in `/etc/ci-os/live-container.conf`, `CI_LIVE_TMPFS_SIZE`). It counts against RAM only as it fills; casper's own `/cow`
  tmpfs is capped separately (50% default), so the two together can exceed RAM: that is the OOM risk and why the cap exists. Nothing survives shutdown, same as the rest of a plain live session.
* Stick with `persistent` and casper actually using the `writable` ext4: the volume is mounted a second time (same device, same options `rw,noatime` as casper's mount, so the kernel shares one superblock) and Docker's
  directories are `ci-container/{docker,containerd}`, a sibling of casper's `upper/` and `work/`. casper only moves top-level content into `upper/` when `upper/` does not exist yet (`casper.noble:572-581`), so a sibling
  directory is stable. Space: `CI-PERSIST` is 12.4 GiB and also holds the whole live overlay; Docker images compete with it (open question). `vfs` or `fuse-overlayfs` are not recommended (vfs copies every layer;
  fuse-overlayfs adds a package and `/dev/fuse` for nothing, because bind-mounted ext4/tmpfs works with overlay2/overlayfs).
* When the Stick is removed: the live root itself (squashfs lower on the medium, ext4 upper) is already gone or I/O-erroring, as for any casper persistence session; Docker will log I/O errors, and `docker.service`
  (`Restart=always`, `StartLimitBurst=3`/60 s in the upstream unit) stops retrying after three failures. We add no special handling beyond ordered `ExecStop` unmounts for a clean shutdown. UNVERIFIED by test; QEMU
  `device_del` on the stick is the manual probe (section 8).

### 5.4 Shipped files (live only; all inert on an installed system)

| File | What it does |
|---|---|
| `payload/docker/usr/lib/ci-os/ci-os-live-container-storage` (mode 755) | `start`: not a live session (`/cdrom/casper/vmlinuz` absent) -> no-op. Reads `/etc/ci-os/live-container.conf`. `persistent` on the kernel command line, and the `writable` (or legacy `casper-rw`) volume exists, is ext4 **and is mounted by casper** (`/sys/fs/ext4/<kname>` exists) -> mounts it a second time and uses `ci-container/` on it. Anything else -> a size-capped tmpfs. Bind-mounts `docker` and `containerd` from the store onto `/var/lib/docker` and `/var/lib/containerd`; records `persist` or `tmpfs` in `/run/ci-os/live-container/backing`. `stop` unmounts them |
| `payload/docker/usr/lib/systemd/system/ci-os-live-container-storage.service` | `Type=oneshot`, `RemainAfterExit=yes`, `ConditionPathExists=/cdrom/casper/vmlinuz`, `Before=containerd.service docker.service`, `TimeoutStartSec=300` |
| `payload/docker/etc/systemd/system/{docker,containerd}.service.d/20-ci-os-live.conf` | `Requires=` and `After=ci-os-live-container-storage.service` |

`Requires=` (a skipped unit, as on an installed system, satisfies it): if the storage unit fails, Docker must not start on the live overlayfs, where it appears to run and then fails on the first pull or run. The drop-in
file names must never be `10-not-live.conf`, so they cannot collide with a future guard. The storage unit needs no `enable`: the drop-ins pull it in.

The script was exercised in a privileged `ubuntu:24.04` container with a simulated `/cdrom/casper/vmlinuz`, a loop-mounted ext4 labelled `writable`, and a bind-mounted `/proc/cmdline` (`t-store.sh`; retired baseline (24.04.5)):
S0 not-live -> no-op; S1 plain live -> `tmpfs`, both dirs tmpfs, overlay mount with upper under `/var/lib/docker` OK, `stop` unmounts; S2 `persistent` + volume mounted by "casper" -> `ext4 /dev/loop0[/ci-container/docker]`,
`upper`/`work`/marker untouched, overlay mount on it OK, `stop` unmounts; S3 `persistent` but volume not claimed by casper -> tmpfs; S4 `nopersistent` -> tmpfs. Not exercised: real udev symlink timing, real casper,
`/sys/fs/ext4` behaviour after `switch_root`.

Boot-time cost to measure (UNVERIFIED): upstream `docker.service` has `Wants=network-online.target` / `After=network-online.target`; on an offline live boot this may delay the first `docker` call until
NetworkManager-wait-online finishes. The guest test records `systemd-analyze blame` for it. If it hurts, a live-only reset of `After=`/`Wants=` can be added to the storage service's drop-in.

## 6. (e) Security

* Live session: no change; the live user already has passwordless `sudo` (`25adduser`).
* Installed system: `docker` group = root-equivalent without a password (socket `0660 root:docker`, `docker run -v /:/host`). The Hub compose files already mount `/var/run/docker.sock` into containers
  (`core/lib/ci-hub.sh:410,431`, `:ro` does not restrict the API), so a rootful daemon is a design assumption of the Hub.
* Options considered: **rootless Docker** (`docker-ce-rootless-extras`) needs a per-user systemd instance, `net.ipv4.ip_unprivileged_port_start` for Traefik 80/443, and a different socket path, and conflicts with
  the Hub's expectations: not a drop-in. **userns-remap** is incompatible with the default containerd image store on Engine 29 (docs.docker.com/engine/storage/containerd) and breaks the Hub's host-path bind mounts and
  `--privileged` use. **`sudo docker`** only: safe but contradicts the owner's decision.
* Recommended default (the owner's decision implemented with the narrowest scope): `docker` for members of `sudo` only, an opt-out file, and no silent hardening of `daemon.json`. Open question Q-SEC: whether to extend
  the group to all human users, or to ship `no-new-privileges` and log rotation defaults.
* The `ci` user is already added on purpose (`provision.sh`).

## 7. (f) What verify-iso.sh asserts (rootless, no boot)

Section 3b (`verify-iso.sh:296-336`) runs on every built image; on the real 26.04.1 build all 19 checks passed. [V] 2026-10-18

| Assertion | Why |
|---|---|
| `docker.service`, `containerd.service` enabled; `docker.socket` enabled (`sockets.target.wants`) | Docker works in every boot mode |
| no `/cdrom/casper` or `boot=casper` in `docker.service`, `docker.socket`, `containerd.service` or their drop-in directories | the exemption of 5.1 cannot be undone silently |
| `20-ci-os-live.conf` of both services has `Requires=` and `After=ci-os-live-container-storage.service` | Docker must not start on the live overlayfs |
| the storage unit has `ConditionPathExists=/cdrom/casper/vmlinuz` and `Before=...docker.service`; the script is present and executable | live only, ordered |
| `ci-os-docker-group.service` has `ConditionPathExists=!/cdrom/casper/vmlinuz`, is enabled; its script is executable | installed system only |
| group `docker` exists in `/etc/group`; the debconf answer `passwd/user-default-groups` in `config.dat` contains `docker` | the live user gets the group |
| no account with a UID 1000-59999 in `/etc/passwd` | casper must be able to create the live user |
| `casper.conf` does not mention `USERGROUPS` | casper ignores it; do not cargo-cult it |
| `docker.io` is not installed | it conflicts with docker-ce |

## 8. (f) QEMU test plan

Harness: `stick/tests/qemu/docker-live.sh` + `stick/tests/qemu/guest-docker-test.sh`. It boots kernel and initrd straight from the ISO with the same kernel arguments GRUB gives them (`-machine q35`, KVM when
`/dev/kvm` is writable, else TCG with `-cpu Haswell`; read the script for the exact flags), a second USB disk labelled `CI_TEST` carries the guest script and an offline `hello-world` image tarball, `systemd.run=`
runs the guest script as soon as basic.target is reached and powers off, results are `CI-DOCKER-TEST <name> PASS|FAIL|INFO` lines on the serial console, and the VM has `-nic none` so the run is provably offline. GRUB,
shim and Secure Boot are already covered by `stick/tests/secureboot`; `systemd.run` cannot be injected through `ci-stick --extra-cmdline` because `validate_extra_cmdline` (`grubenv.rs:176-185`) refuses quotes, `$`, `;`,
so the harness uses direct kernel boot. Under TCG on Apple silicon the Ubuntu desktop needs `-cpu Nehalem` (port notes, section 13). This harness uses Haswell under TCG and starts no desktop (it boots to `multi-user.target`), so the GNOME crash seen with Haswell on 24.04.5 does not apply to it [I].

Prerequisite (once, on any online host): `docker pull --platform linux/amd64 hello-world && docker save hello-world -o stick/tests/qemu/hello-world-amd64.tar`.

```bash
# Plain ISO live session (no persistence): expects Docker data on tmpfs
stick/tests/qemu/docker-live.sh iso path/to/companion-os-*.iso
# Companion Stick: build the image first with the repo's flash path (stick/tests/secureboot or `ci-stick flash --image`), then
stick/tests/qemu/docker-live.sh stick path/to/companion-os-*.iso path/to/stick.img   # 2 boots; boot 2 proves persistence
```

Assertions the guest script makes (names in the serial log): `groups` (`id -nG companion` contains `docker`), `cli` (`runuser -u companion -- docker version` works with no sudo), `daemon-active`, `backing`
(`findmnt -T /var/lib/docker` is `tmpfs` for the ISO, `ext4` for the Stick, and never `overlay`), `backing-marker` (`/run/ci-os/live-container/backing` is `tmpfs` or `persist`), `storage-unit` active, `load`
(`docker load -i hello-world.tar`), `run` (`docker run --rm --network none hello-world` prints "Hello from Docker!" as the unprivileged user), second Stick boot: `persisted` (image still present), plus `INFO` lines
for `docker info` driver, containerd root fs and `systemd-analyze blame` for docker, containerd and wait-online.

Additional probes (manual, record the output next to the capture of the run):
* **T-live-0 control:** boot the ISO with the kernel argument `systemd.mask=ci-os-live-container-storage.service` and run `docker info`: expect the overlay2 probe to fail ("driver not supported" or an unusable
  `Backing Filesystem`). This proves on Ubuntu's kernel what T-ovl showed on the Docker Desktop kernel.
* **T-removal:** with the Stick booted and Docker running a container, QMP `device_del stick` and record `docker ps` and `journalctl -u docker` after 60 s.
* **T-path** (only if the optional `.path` unit is adopted): in a booted installed system `useradd -m -G sudo x`, `sleep 5`, `id -nG x`.

**Installed system:** a GUI install cannot be fully automated. (1) run the installer in the live QEMU session to `target.qcow2`, create user `tester`; (2) before restarting, still in the live session:
`mount /dev/<target-root> /mnt/t; grep '^docker:' /mnt/t/etc/group` (group exists, `tester` not listed: this documents the interactive installer's behaviour), `chroot /mnt/t systemctl is-enabled
ci-os-docker-group.service` (expect `enabled`); (3) boot `target.qcow2` with OVMF and log in on the serial console as `tester` (no sudo): `id -nG` must contain `docker` (the oneshot ran before
`systemd-user-sessions`), `journalctl -b -u ci-os-docker-group -o cat` must contain `added tester to docker`, then `docker load -i <hello-world.tar from a second disk>` and `docker run --rm hello-world`. Run the same
guest script with mode `installed` and user `tester` (it asserts the storage unit's `ConditionResult=no` and that `/var/lib/docker` is not an overlayfs). The one-click path should show `tester`-equivalent `companion` in
`docker` straight away, from `identity.groups`, before the oneshot has anything to add.

Expected pass table for the three modes:

| Assertion | installed | plain ISO live | Stick live (boot 1 / boot 2) |
|---|---|---|---|
| `id -nG` has `docker` | yes (after oneshot, or from `identity.groups` on the one-click path) | yes (debconf default) | yes |
| `docker run hello-world` offline as the user | yes | yes | yes |
| `/var/lib/docker` fs | root disk fs | tmpfs | ext4 |
| survives reboot | yes | no | yes (boot 2 `persisted`) |
| `ci-os-live-container-storage` | skipped | active | active |

## 9. What has not been verified

* Nothing in this document has been run on a booted 26.04.1 image: the section 8 tests, T-live-0, the live user's groups in a real session, the persistence logic of casper 26.04.2 (read for `live-media=`, `persistent`,
  `writable` only), and the installed system. **Pending evidence:** `stick/tests/qemu/docker-live.sh iso` and `... stick` on a built image, with the serial logs saved beside a `CAPTURE.md` in
  the capture directories of the Ubuntu run (`shots/ubuntu/` and `ubuntu/` in the session scratch; their text records are copied into [`docs/evidence/`](../evidence/README.md) and the frames into `docs/ui/companion-os/ubuntu/` when the row is run); PASS lines `groups`, `backing`, `run` (and `persisted` on boot 2) confirm the
  design on 26.04.1.
* The live-session facts come from the Launchpad casper, user-setup and adduser sources, the Subiquity tags and the 26.04.1 snap, container tests that reproduce the user-setup and storage logic, and a nested-overlay
  test on a non-Ubuntu kernel.
* `provision.sh` still resolves the wrong user when run as root without `SUDO_USER` (section 3).

## 10. Test results (QEMU, TCG on an Apple-silicon Mac), retired baseline (24.04.5)

| Test | Result |
|---|---|
| Plain ISO live, `docker-live.sh iso`, ISO built from commit 3a3ead3 | **PASS**: `docker` in the live user's groups, daemon active, data root on tmpfs, containerd snapshotter `overlayfs` works, `hello-world` loaded and run offline as the unprivileged user |
| Stick live (123,942,731,776-byte image), boot 1 | **PASS**: data root on ext4 (`CI-PERSIST`), marker `persist`, same offline `hello-world` run |
| Stick live, boot 2 (persistence), build 3a3ead3 | **FAIL, fixed in the next build**: `ci-os-live-container-storage.service` hit its 60 s start timeout (it had used the same ~15 s of CPU as in boot 1, but took 57 s of wall time while a 7.9 GB ISO build was running on the same Mac, after an ext4 journal replay from the previous boot's power-off). Docker then started on the overlayfs and the persisted image was not found. Fix: `TimeoutStartSec=300` and `Requires=` instead of `Wants=` |
| Stick live, boots 1 and 2, v7 image (2026-10-14) | **PASS** per the owner's session notes (the logs were in a scratchpad that is not kept): boot 2 found the boot-1 `hello-world` image with Docker on ext4 `CI-PERSIST`; the unit took 6.8 s. The machine was busy (load 10 to 130) and the unit never came near a timeout, so the 300 s timeout and the `Requires=` failure path were not exercised |
| Installed system | not run |
| 26.04.1 image, any of the above | not run: see section 9 |
