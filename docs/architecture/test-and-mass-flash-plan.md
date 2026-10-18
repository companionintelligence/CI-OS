# Testing the Companion OS image and mass-flashing Companion Sticks: the plan

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Date 2026-10-13; sections 1, 3, 5 and 8 re-checked 2026-10-18. Status: **plan, not implementation.**
It was produced by three independent designers (test ladder, IP-KVM bench, mass-flash rollout)
and two red-team reviews (safety, feasibility); where they disagreed, this page takes the
stricter or cheaper reading and says so. Facts marked **UNVERIFIED** were not confirmed from a
primary source or a run. Since 2026-10-17 the supported targets are Companion OS on Ubuntu
26.04.1 and on CachyOS; evidence from the Ubuntu 24.04.5 image is labelled **retired baseline
(24.04.5)** and is not evidence for the 26.04 image. Companion documents: [companion-stick-128gb.md](companion-stick-128gb.md) (decisions),
[mass-flashing.md](mass-flashing.md) (hardware investigation),
[docker-in-live-sessions.md](docker-in-live-sessions.md), [tier-b-tools.md](tier-b-tools.md),
[model-packs-128gb.md](model-packs-128gb.md).

## 1. Where we are

Rows 1 to 4 are the 2026-10-13 state on the **retired 24.04.5 base**; they show what the
design was proven against and must be redone on 26.04. Rows 5 onward are the state on
2026-10-18.

| Claim | State | Evidence |
|---|---|---|
| Image has Docker, docker group, tailscale, cloudflared, gh, Ollama, Companion Launcher, pinned and verified | **Retired baseline (24.04.5): proven statically.** 26.04.1 build: **pending evidence** | `verify-iso.sh`: 147 passed, 0 failed on ISO sha256 `0e8780a9…` (built from commit `3a3ead3`). What confirms the 26.04 row: `verify-iso.sh` output on the 26.04.1 build (the build and capture were started on 2026-10-18 and have not finished) |
| Docker works offline as the unprivileged live user, plain live ISO, data root on tmpfs | **Retired baseline (24.04.5): proven in QEMU/TCG.** 26.04: not re-run [N] | `stick/tests/qemu/docker-live.sh iso`: `RESULT: PASS` (groups incl. `docker`, daemon active, tmpfs backing, `hello-world` run offline) |
| Same on a Stick live boot with persistence, surviving a reboot | **Never completed** | `docker-live.sh stick` on a 123,942,731,776-byte image was running on 2026-10-13; no result is recorded |
| An installed system has our packages in dpkg/apt | **Fixed in code, not proven** | stock language layers carried a stock `dpkg/status` and `gschemas.compiled`; removed in commit `ef00bbb` (24.04 era); needs a build and a real installer run on 26.04 |
| Secure Boot chain on 26.04 (shim 15.8, GRUB 2.14, Canonical-signed 7.0 kernel), signed/unsigned/off | **Proven in QEMU/OVMF (TCG)**, 8 checks | `run-on-mac.sh` A/B/C: `RESULT: PASS` ([companion-stick.md](companion-stick.md#secure-boot)) |
| The stock Ubuntu 26.04.1 ISO boots from a flashed stick image, Secure Boot on | **Proven up to the live system's early systemd** (QEMU/TCG) | serial log: lockdown, `EXT4-fs (sda6): mounted ... r/w` (the `writable` partition), casper loop-mounted the three layers, systemd 259.5; GNOME and the installer not booted |
| `stick/tests/qemu/run.sh` on 26.04 userland | **PASS**, 17 summary lines | privileged `ubuntu:26.04` container, kernel 7.0.0-38 |
| A built Companion OS on Ubuntu 26.04.1 boots, installs, provisions | **Built and statically verified [V]; boots, installs and provisions pending** | done: a clean-checkout build and a `verify-iso.sh` pass (393 passed, 0 failed), and on a fix-pass image a harness-assembled disk that booted to the GDM greeter (230 s). Still to do, each with a log: a QEMU/OVMF boot to the live desktop, an install to a disk image (through the one-click helper or the stock installer), a boot of the installed disk and first boot ([test-evidence.md](test-evidence.md#pending-evidence-for-the-ubuntu-2604-image), U2 to U11) |
| Companion OS on CachyOS: live boot, Calamares online install, installed boot, first-boot provisioning | **Proven end to end twice** in QEMU/OVMF (TCG): ISO #4 with defects that commit `552063f` fixes, and ISO #5, which shows those fixes working (its install needed three attempts, KI-20) | [cachyos-backend.md](cachyos-backend.md#test-status) |
| `ci-stick flash --device` writes a physical stick | **Never run** | Linux-only; its identity re-check and `O_EXCL` path have only run in QEMU against image files |
| The image boots on real hardware, Secure Boot on | **Never run** | the only evidence is QEMU/OVMF |
| Models on `CI-CACHE` | **Tool exists, no stick populated** | `ci-stick models fetch` (Ollama references) is tested against local listeners; the lock is committed; nothing was written to a stick or an exFAT volume ([models-tooling.md](models-tooling.md)) |

Nothing has been written to any attached stick. The nine `13fe:6700` sticks still carry their
vendor FAT32; the 503 GB NTFS `CI_SETUP` stick (serial `74573870`) is out of scope for every
step below.

## 2. Principles (from the red team)

1. **Freeze the ISO before spending more.** Every extra ISO change costs about 25 minutes of
   emulated build and invalidates all earlier boot evidence. Make exactly one change set (section
   6), commit it, build once, run the gates on that ISO. Name ISOs `companion-os-<gitsha>-<isosha12>.iso`
   and refuse to test one built from a dirty tree.
2. **No write to a physical stick before gate G0 and an explicit `go` for that exact serial.**
   Writes happen in stages (section 8), never "all nine" first.
3. **Run the unmodified code first.** The first real `flash --device` runs on the code as it is,
   on one sacrificial stick, with only a wrapper and an allow-list around it. Fixes land against
   observed failures, not before.
4. **Shared and production machines are never test targets.** Hosts tagged `tag:ci-server` are
   treated as production. Destructive steps (installer, `CI_STICK_TEST_SYSDISK_WRITE_REFUSAL`,
   a native `build-iso.sh --clean`) run only in disposable VMs or on a machine the owner names as
   sacrificial in writing.
5. **Evidence never goes onto a stick that will ship.** Logs go to the host or a collector. A
   stick that has booted anywhere or been mounted read-write is `TAINTED` and ships only after a
   full re-flash.

## 3. The test ladder

| Rung | Where | Proves | Time | State |
|---|---|---|---|---|
| **L0** static | anywhere | `check-repo.sh` (about 6 min on a loaded host), `cargo test --locked` in `stick/` (the 2026-10-13 count of 84 is stale: the 26.04 port run reported 156 library tests and 82 in the integration test files), `verify-iso.sh` (Ubuntu: 3b Docker, 3c optional tools, 3d no language layers; CachyOS: its own `verify-iso.sh`) | 4–8 min | green on the last full run before the 26.04 port; the gate run after it is the orchestrator's |
| **L1** container | Docker, linux/amd64 | geometry of `flash --image --size 123942731776` (`sgdisk -p`, fsck of all four filesystems), sparse-image-onto-used-media hazard, simulated installer layer stack (`dpkg-query` shows `ii` for docker-ce, tailscale, cloudflared, gh, companion-hub) | 5 min native, 20–40 min emulated | to write |
| **L2** QEMU/TCG on the Mac | this Mac | Docker live (plain ISO: done on 24.04.5, not re-run on 26.04; Stick + persistence: never completed); Secure Boot A/B/C with the test image (done on 26.04); stock 26.04.1 ISO from a stick under Secure Boot (done to early systemd); CachyOS live, install and installed boot (done twice); macOS attach of the image | 4 min to a desktop (CachyOS, host load 2.5 to 9) to 10 min per boot | partly done |
| **L3** QEMU/KVM on Linux | needs a Linux host with `/dev/kvm` (section 5) | the same at 2–3 min per boot; GRUB + shim + Secure Boot with the real ISO; **emulated-USB `flash --device`** (a QEMU `usb-storage` disk with a settable serial looks like a removable USB disk to `lsblk`); installer replay; Ollama on a second exFAT disk | smoke under 20 min, release about 5 h | blocked on a host |
| **L4** real hardware | a human at a PC, or an IP-KVM (section 4) | the `13fe:6700` controller, firmware boot order, USB 2 hubs, Secure Boot on real firmware | about 30 min per machine | blocked on a flashed stick |
| **M** manual | humans | macOS and Windows see `CI-SHARED`/`CI-CACHE` without a "format" prompt; unplug/replug; thermals | 15 min each | blocked on a stick |

Claims no test proves yet, to add: abrupt removal with persistence (`device_del` mid-write, then
fsck and Docker data root), flashing a **dirty** emulated device through the real `--device` path,
"test the tester" (flip one byte in slot A, in the backup GPT and in the cache region and require
`verify-stick` to fail), a scan of the finished ISO for baked secrets (`tskey-`, tunnel tokens,
`/var/lib/tailscale`, apt auth, SSH host keys, non-empty `machine-id`), Ollama loading a model
larger than 4 GB from exFAT with `noexec`, and a non-English offline install.

Smoke = `verify-iso.sh` + geometry + `docker-live.sh iso`, **measured** under 20 minutes (do not
count on running the two Docker tests concurrently to hit 15). Release = every row of the ladder on
one ISO sha256 and one bundle id, evidence in `release-evidence/<isosha12>/` (sanitised: tailnet
names, IPs and DMI serials removed before it is attached to anything).

## 4. The "KVM fleet" is IP-KVM hardware: what it is for

Read-only discovery (tailnet list and unauthenticated landing pages): six `-kvm` devices serve a
NanoKVM page (Sipeed, RISC-V) and one is PiKVM-style. They cannot run QEMU or Docker. They are a
**real-hardware bench**: virtual CD/USB-disk mount, keyboard/mouse injection, HDMI capture, ATX
power/reset, all over the tailnet.

What that means:

- A 7.9 GB ISO (the 24.04.5 size; the 26.04.1 stock ISO is 6.5 GB) fits a NanoKVM virtual CD (the images live on its microSD, about 21 GB on the Full
  model, UNVERIFIED for our units). A 115 GiB stick image does not. **The Stick itself is tested
  by a human plugging a physical stick the flash station wrote**; the IP-KVM supplies screen,
  keyboard and power. The USB gadget is USB 2, so a live boot from the virtual CD takes minutes.
- **We have no credentials**, so every API beyond the landing page is blocked. The device-reported
  hostnames disagree with the tailnet names (`core-4-kvm` calls itself `core-5`, `liam-core-kvm`
  calls itself `demo-1-kvm`), so pairing by name prefix is a guess. A person must confirm each
  KVM-to-machine pairing before the first power action.
- A KVM is full console access to its host. Booting external media or touching Secure Boot can
  trigger BitLocker/LUKS recovery on a TPM-sealed disk. No Secure Boot toggling or key enrolment on
  shared machines; check disk-encryption state before the first external boot; one unique password
  per KVM; no remote firmware upgrades.
- Excluded until explained or approved: `beta-kvm-2` (its SSH host key **changed**; do not type a
  password into it), `core-7-kvm` (owned by Bennett), any host that is merely "offline" (that can
  mean decommissioned, unplugged or deliberately shut down).
- **Start manual.** Liam logs in once (30 minutes), boots the ISO on one approved machine over the
  web UI, takes screenshots at fixed marks, and types `ci-os-selftest`. Automation (`fleetctl`,
  beacon, collector) is built only if that earns its keep. The framework designs (a `fleetctl` driver, a beacon
  and collector) are parked, not rejected.
- The first L4 run that matters needs no KVM at all: a person at any UEFI PC with Secure Boot on,
  the flashed stick, and a phone photo of the screen.

## 5. Where tests run (compute)

The three needs are different and one purchase covers all of them:

| Need | Today | Recommendation |
|---|---|---|
| (a) A Linux/KVM host for L3 and native ISO builds (about 10–15 min native vs 25 emulated) | none confirmed; tailnet `core-N` boxes are `tag:ci-server` | **Day 0:** run the existing hosted workflows (`stick-real-iso.yml` boots a real ISO under KVM; `pr-checks.yml` has the KVM udev step and runs `stick-qemu` in a privileged `ubuntu:26.04` container; the `ubuntu-24.04` in their `runs-on:` is only the label of the VM that hosts the container). `build-companion-os-iso.yml` was reworked for 26.04.1 (it now builds in a privileged `ubuntu:26.04` container and downloads and verifies the base ISO against the signed `SHA256SUMS` and a pinned sha256) but **no workflow has run on GitHub since the port** [N], and before the port it failed in 0 s on every push: treat it as unproven. **In parallel:** buy one x86_64 mini-PC (32 GB RAM, 1 TB NVMe, SHA-NI, `/dev/kvm`). A 60 GB disk is too small for a native ISO build (stock ISO 6 GB, chroot 15–20 GB, squashfs, 8 GB output, 115 GiB sparse images): size it at 150 GB or more |
| (b) A flash station with physical USB | none | the same mini-PC plus powered hubs (section 8) |
| (c) A bench with a human to boot sticks | none | any UEFI PC; IP-KVM as an optional second path |

A self-hosted GitHub runner on the tailnet is an ephemeral, own-tagged VM (for example
`tag:ci-runner`, ACL: outbound to the collector port only, no secrets, fork PRs disabled), never a
shared server. Test any ACL change with Tailscale ACL `tests` first, and merge, never replace.

## 6. The single ISO change set (do this before more testing)

Everything below goes into **one** commit and **one** build:

1. `ci-os-selftest` in the image (`/usr/lib/ci-os/ci-os-selftest <live-iso|live-stick|installed> [user] [first|second]`):
   today's assertions live in `stick/tests/qemu/guest-docker-test.sh` and can only be injected by
   `systemd.run=` in a direct-kernel QEMU boot, which an IP-KVM cannot do. It prints
   `CI-SELFTEST <name> PASS|FAIL` lines and a large banner, and `guest-docker-test.sh` becomes a
   wrapper. Add: live services inactive and installed services active, Launcher binary, dpkg
   (`dpkg -s` of the packages), `mokutil --sb-state`, the Ollama cache env, `ss -ltnup` (nothing
   listens beyond loopback and Docker's unix sockets, Docker has no TCP socket, Ollama binds
   127.0.0.1, no `openssh-server`).
2. A normal GRUB entry **"Companion OS (diagnostics)"** whose command line runs the selftest, so
   nothing has to be typed into the GRUB editor through a KVM. Drop the nonce/HMAC/collector/
   tailnet-join-key beacon design: a PASS/FAIL banner plus a screenshot is enough for an internal
   smoke test, and an auth key on the kernel command line leaks into `/proc/cmdline`, the HDMI
   stream and the persistence journal.
3. The offline `hello-world` image inside the ISO (or on `CI-SHARED`), pinned by digest.
4. **Decide Ollama in a Stick live boot.** `10-not-live.conf` keeps Ollama off in every live
   session, so the 73 GiB cache is unusable until the stick's OS is installed. Either that is the
   design (the cache serves installed machines) or Ollama must run in Stick live; the selftest asserts
   whichever is chosen. This is an owner decision.
5. A secrets scan in `verify-iso.sh` (salted-hash match against the leaked values from the
   2026-10-12 review, which must not print them; plus the absence list above).

Also fix before relying on any geometry claim: `run-on-mac.sh` does not forward
`CI_STICK_SB_SIZE`, so it builds 64 GB images (checked 2026-10-18: the `docker run` in
`run-on-mac.sh` has no `-e CI_STICK_SB_SIZE`; `build-in-container.sh` honours it); build via
`build-in-container.sh` directly (as done for the 123.9 GB image) or add the `-e`. On Docker
Desktop for Apple silicon the amd64 `ubuntu:26.04` container failed the build half once
(GNU tar fails under Rosetta; the trigger was not isolated); see [companion-stick.md](companion-stick.md#secure-boot).

## 7. Safety requirements before any physical write (P0)

1. **Allow-list inside `ci-stick`, not only in a wrapper.** Today `--expect-serial` is optional and
   `is_candidate` accepts any non-system removable/USB disk, which includes `CI_SETUP`. Make
   `--expect-serial` and `--expect-size` mandatory for `--device` and `slot set --device`; hard-deny
   VID:PID `24a9:205a` and any disk larger than the expected size, with no flag to override; refuse
   to run at all if a denied device is attached; make `--confirm` the USB **serial** (a node name is
   what a hot-plug race changes); re-read serial and size from `/sys/dev/block/<major:minor>` of the
   opened file descriptor, not from the path.
2. **Destructive raw tools go through ci-stick's gate.** `f3probe --destructive` and `fio --rw=write`
   must not be run on a bare `/dev/…` path. Add `ci-stick raw-test --device … --tool f3probe|fio`
   that reuses the same assessment, allow-list, approval and lock. Until it exists, run them by hand
   on one stick that is the only USB mass-storage device attached.
3. **No receipt-skip of bundle hashing.** Hashing 8 GB costs about a minute; a write costs 5–90.
   Seal the bundle (copy to a root-owned 0444 content-addressed directory and verify the signature
   from that copy) and hash-as-streamed every artifact, including `bundle.json`.
4. **Rotate the leaked credentials (RT-01) before Stage 1**, not before shipping, and run the
   secrets scan. As of 2026-10-18 the credentials found in the 2026-10-12 review are still
   unrotated (the owner's record; this page did not re-check them and never copies a value). Do not deploy any collector under the old Cloudflare account until rotation is
   recorded.
5. **Approvals are not self-issued.** The session that runs `--write` must not be able to create
   its own approval: a human creates it on the station (or signs it with a key/TOTP the session
   does not hold), single-use, valid at most 2 hours, bound to station hostname, serial list,
   bundle sha256 and the `ci-stick` binary sha256. The session gets sudo for one wrapper only.
   Build `ci-stick` from a clean tagged commit with `cargo build --locked`.
6. **`build-iso.sh` guard:** before any `rm -rf "$WORK_DIR"`, require `findmnt -R "$chroot"` to be
   empty, and replace lazy `umount -lf` with a retry loop that fails loudly (natively, a lazy unmount
   followed by `rm -rf` is how host `/dev` or `/run` get deleted).
7. Station hygiene: mask `udisks2` and any automounter globally; restrict `uhubctl` to the listed
   hub locations; hash-chain the ledger and keep an off-station copy.

## 8. Mass flashing: staged, with gates

Station: a dedicated headless x86_64 Linux mini-PC, Ubuntu 26.04, two **externally powered**
7-port USB 3 hubs with per-port power switching that actually cuts VBUS (verify with
`lsusb -v … | grep -i "Per-port power switching"` and a dead LED after `uhubctl … -a off`), each on
its own SuperSpeed host port, **at most 5 sticks per upstream link**, short USB 3 cables,
an inline USB power meter and an IR thermometer, space and a fan between sticks, 2–3 spare sticks of the
same SKU (one sacrificial, one canary, one spare), an optional 300 VA UPS. Raspberry Pi 5 is
second choice (its onboard ports are ganged, so "per-port" power does not apply). A Mac with a
Linux VM and USB capture is a 3-hour experiment on one spare stick, never production.

Per-stick **flash for the OS part; a golden image only for `CI-CACHE`** (copy the whole partition,
patch the exFAT volume serial per stick). Cheapest tooling that is still safe for nine sticks
(the red team's cut of the 118-hour design):

- a udev rule generated from `sticks.tsv` that creates `/dev/ci-stick/<serial>` for the nine
  serials only, and `deny.tsv` (`74573870 24a9:205a CI_SETUP`);
- a shell wrapper that refuses to run if any other USB mass-storage device is attached, then runs
  `ci-stick flash --device /dev/ci-stick/<serial> --confirm <serial> --expect-serial <serial> --expect-size 123942731776`
  per stick under `xargs -P`, with timestamped per-stick logs and the saved `--dry-run --json` plan;
- `verify-stick` as a **shell script first** (primary and backup GPT, slot-A sha256, `fsck.vfat -n`,
  `fsck.exfat -n`, `e2fsck -fn`, uniqueness of GUIDs/volume IDs) run after a replug;
- small code changes worth keeping: timing in `--json`, unique FAT volume ID and `sgdisk -G`,
  and F-8 (write GPT and ESP **last**) but only after Stage 1 has run on the unmodified code.

Deferred: the receipt system, hash-chained ledger and label printer, the exFAT boot-region patcher
(`tune.exfat -I` is enough), `uhubctl` automation (replug by hand), `flash-batch` increments 2–3,
and a Rust `models sync` (a golden cache can be built once with real `ollama pull` into a
loop-mounted exFAT image and written whole).

| Stage | What | Gate (you say, in chat) | Pass |
|---|---|---|---|
| **G0** | ISO from section 6 booted in QEMU with Docker working; `verify-iso.sh` 0 failed; secrets scan clean; credentials rotated | `ISO OK` | all green on one ISO sha256 |
| **0** | Mac, read-only: freeze `sticks.tsv`/`deny.tsv` from `usb-inventory-macos.py`; geometry image; rehearsal on emulated sticks (decoy `74573870` attached must abort the run) | `LISTS OK` | nine unique serials, none denied; decoy test aborts |
| **1** | **One sacrificial stick**, unmodified code: identify (`lsusb -v`), `f3probe --destructive --time-ops`, sustained-rate `fio` fill, plan, flash, replug, `verify-stick --full`, QEMU boot of the device read-only (`blockdev --setro` first), macOS mount read-only, then **a human boots it on a real PC with Secure Boot** | `GO STAGE1 <serial> <bundle sha8>`, `GO INTAKE <serials>` for each destructive tool | every criterion met; measured MB/s, SLC cliff, temperature recorded in [mass-flashing.md](mass-flashing.md) §11 |
| **Intake** | `f3probe` on the other eight, in parallel | `GO INTAKE <serials>` | size ≥ 123,942,731,776 B, no counterfeit verdict, else quarantine |
| **2** | three in parallel on different hubs (include one that ran at 480 Mb/s on the Mac, moved to a SuperSpeed port) | `GO STAGE2 <3 serials>` | per-stick rate within 30 % of solo; no kernel resets; fsck/verify clean; unique IDs |
| **3a** | nine OS-only, one wave across two hubs | `GO STAGE3A <batch>` | as Stage 2 for all nine; real-hardware boot on three |
| **3b** | golden `CI-CACHE` image on all nine | `GO STAGE3B <batch>` | `verify-stick --full`; `ollama list` shows 21 models on an installed machine |
| **G8** | before any stick leaves the building | `SHIP OK <batch>` | compliance checklist signed: Gemma and Llama licence terms travel with the models, Canonical's trademark/IP policy for a modified Ubuntu (an open finding), GPL source offer for Ubuntu components, dev-signed bundle vs release key |

**Time for nine** (rates for this stick are UNVERIFIED; Stage 1 replaces them with measurements).
OS-only writes about 8.0 GB per stick (the 24.04.5-era figure; one 26.04.1 build measured 7.08 GB): 2 min / 4.5 min / 9 min at 60 / 30 / 15 MB/s, plus read-back and
verify; the whole wave about 25 minutes. With models the write is about 86 GB per stick: 24 / 48 /
96 minutes at 60 / 30 / 15 MB/s, about 80 minutes typical wall time for all nine in parallel. All
writes are NAND-bound; the four sticks behind USB 2 hubs would share ~38 MB/s and are not used until moved.
The golden cache build is a one-off: 74.4 GB download at about 25 MB/s (about 50 minutes), copy and fsck about 12.

Failure handling: re-flash once on the first failure; quarantine (red bin, serial recorded, never
re-used in a batch) on the second, then `f3probe`. Never retry automatically on a different device
node. Per-serial states: `NEW → INTAKE_OK → FLASHED → VERIFIED → ACCEPTED → SHIPPED`, plus
`RETEST`, `QUARANTINED`, `RETIRED`, and `TAINTED` (booted anywhere or mounted read-write: ships only
after a full re-flash).

## 9. Effort and order

The three designs summed to over 200 engineer-hours; with the red team's cuts the realistic figure
to reach **nine verified OS-only sticks is about 35–45 engineer-hours**, plus waiting time for
hardware and approvals. Order of work:

1. Section 6 change set → commit → one ISO build → G0 gates (hosted runner or Mac). *(about 8–10 h)*
2. Order the mini-PC and hubs now; lead time is the long pole. *(your decision, G1)*
3. Rotate credentials; secrets scan. *(RT-01/02)*
4. ci-stick safety changes (section 7 items 1–3) and the wrapper/udev/`verify-stick` script. *(about 12–16 h)*
5. Stage 0 rehearsal on emulated sticks (one harness, on the x86 KVM node, not also an arm64 rig).
6. Stage 1 on the unmodified code, then fix what it finds; Intake; Stage 2; Stage 3a.
7. `CI-CACHE` golden image and Stage 3b (about 12 h more).
8. IP-KVM: manual smoke after Liam logs in; automation only if it earns it.
9. Parked: `stick_compact` layout profile (needs a layout-policy bump and tests a geometry that
   never ships), `fleetctl`, Rust `models sync`, ledger and labels, Windows/macOS matrices beyond one stick.

## 10. What is needed from you

1. **Access:** which IP-KVM and which machine first, with a least-privilege login (30 minutes of
   your time), and an explanation of `beta-kvm-2`'s changed host key. A named sacrificial machine
   (all other disks disconnected, a person present) for the installer on hardware.
2. **A Linux/KVM host:** approve the hosted-runner stopgap and the mini-PC purchase (G1), or hand over a
   disposable VM. Not a `tag:ci-server` box.
3. **Decisions:** Ollama in a Stick live boot (section 6, item 4); `stick-128` vs `stick-128-oci`;
   whether the first batch is dev-signed internal only; Canonical IP policy before any external hand-out.
4. **A tenth stick** (or designate one of the nine as pilot) for Stage 1.
5. **Rotation** of the credentials listed in the 2026-10-12 review (still open on 2026-10-18).

## 11. Contradictions between the designs, resolved here

- Tests that write to `CI-SHARED` vs a read-only acceptance: read-only (or a sacrificial stick).
- Logs on the stick vs a collector: never on the stick.
- Production-tagged machines as KVM-node candidates vs out of bounds: out of bounds.
- IP-KVM power actions only when the paired host is offline vs any paired machine: the stricter
  rule, plus a person confirming the pairing.
- The dpkg-database finding was written up as "expected to FAIL today"; it is already fixed in
  `ef00bbb`, so the check is a regression gate, and the open risk is that no real installer run has
  confirmed it (plus offline non-English installs, which fetch language packs from apt).

## 12. Disclosures

- During discovery one designer issued plain-HTTP GETs on port 80 to five KVM devices and followed
  one 302 redirect, beyond "one unauthenticated HTTPS GET"; nothing else was requested and nothing
  was sent. Do not repeat it.
- An SSH login attempt (publickey/password prompts refused, no guessing) was made to
  `core-4-kvm`, `core-7-kvm` and `liam-core-kvm`, and `core-7-kvm`'s host key was added to this Mac's
  `~/.ssh/known_hosts`.
