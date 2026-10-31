# Mass-flashing Companion Sticks

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Status: investigation, 2026-10-13; re-checked against the code and the Ubuntu 26.04 archive on 2026-10-18 (what changed is in section 12). This is a design and a runbook; **no batch tooling exists yet** and no stick was written, formatted, remounted read-write or partitioned while it was researched. Everything marked **UNVERIFIED** was not observed or could not be confirmed from a primary source.

Scope: flashing nine 123,942,731,776-byte (123.9 GB, 115.4 GiB) "USB DISK 3.0" sticks (USB 13fe:6700) with `ci-stick`, and what it takes to do that repeatedly. The tenth attached disk, the 503 GB NTFS stick `CI_SETUP` (disk23), is out of scope and must never be a target.

---

## 1. Summary

1. **Today `ci-stick flash --device` writes one stick per invocation and only runs on Linux.** The Mac cannot flash these sticks with `ci-stick` at all (`stick/crates/ci-stick/src/target.rs:488-493`, `target.rs:575-578`, [companion-stick.md](companion-stick.md), Known limitations: "Device writes are Linux-only").
2. **Running several `ci-stick` processes in parallel is structurally possible**, because each process owns one O_EXCL-opened device and builds its filesystems in its own temp dir. It has never been tried, and several things will hurt at scale: every process re-hashes the whole bundle (`flash.rs:295-300`), there is no timing or throughput output, and no per-stick identity beyond what the tools generate.
3. **Write volume per stick is small today** (the ISO plus roughly 0.1 GiB of filesystem metadata) because `CI-SHARED`, `CI-CACHE` and `CI-BOOT-B` are not populated. It becomes large (about 79 GiB) as soon as the 73 GiB `CI-CACHE` is filled with models, which is not implemented yet (slice 4).
4. **The bottleneck is the sticks' NAND, not USB**, except on this Mac's current hub tree where the four USB 2 sticks share a single 480 Mb/s link (about 9.5 MB/s each if all four write at once).
5. **Recommended approach:** a dedicated headless Linux flash station (bare-metal x86_64 mini-PC or Raspberry Pi 5), externally powered USB 3 hubs with per-port power switching, one `ci-stick flash` process per stick selected by USB serial from an allow-list, a one-time destructive capacity check (`f3probe`) at intake, and an independent re-plug verification after flashing. A Mac with a Linux VM and USB capture is an experiment, not a production path.
6. **Per-stick flashing, not a golden image, is the right default for the OS part.** It writes about 6.5 GB instead of 115 GiB, and every stick gets fresh GPT GUIDs and filesystem identifiers. A golden image only makes sense later for the model cache.

---

## 2. How `ci-stick flash` works today

All `file:line` citations were made on branch `clau/companion-os-preinstall-rebrand`, HEAD `7734ff5`, and match the 2026-10-12 review (the 2026-10-12 flash review, section 2). Re-checked on 2026-10-18 (branch `liam/companion-os-single-click-install`): `flash.rs`, `target.rs`, `devices.rs`, `sparse.rs` and `gpt.rs` are byte-identical to `7734ff5` (`git diff --stat 7734ff5 HEAD` lists only `main.rs`), so their citations hold. `main.rs` gained the `models` subcommands (+16 lines), so its citations below were re-pinned to the current lines.

### 2.1 Sequence

| Step | What happens | Evidence |
|---|---|---|
| Request check | `--allow-unsigned`, `--slot-b-from` and unsigned bootloader are refused with `--device`; `--confirm`/`--expect-serial` are refused with `--image` | `flash.rs:137-161`, `main.rs:390-395` |
| Verify | Full verification of the whole bundle (`HashMode::Full`): signature first, then size + SHA-256 of every artifact. A failure exits 1 and writes nothing | `flash.rs:295-303`, `verify.rs:42-45` |
| Re-read | `plan()` then re-reads `bundle.json` **without** a signature check; every digest used later comes from this second read (review finding F-1, high) | `flash.rs:304-305` |
| Device facts | Resolve the path to a real node, read size/model/serial/sector size from sysfs and `lsblk`, `/proc/self/mountinfo`, `/proc/swaps` | `target.rs:305-319`, `383-431`, `487-514`, `603-619` |
| Layout | Recomputed for the target size (`layout::plan`), 1 MiB aligned, minimum 57 GiB | `flash.rs:380`, `layout.rs:35` |
| Build filesystems | In sparse temp files, no root: `mkfs.vfat -F 32 -n CI-EFI` plus `mmd`/`mcopy`, `mkfs.exfat -L` (SHARED, CACHE), `mkfs.ext4 -F -q -L writable -E nodiscard,lazy_itable_init=1` | `flash.rs:681-744`, `753-804` |
| Open device | `O_EXCL`, then re-check node, major:minor, size, model, serial and fd size | `flash.rs:924-927`, `target.rs:562-573`, `622-638` |
| Wipe + GPT | Zero first and last MiB, `sgdisk --zap-all`, then `sgdisk --clear --new/--typecode/--change-name` for six partitions; read the GPT back and compare to the plan | `flash.rs:935-952`, `gpt.rs:21-40` |
| Filesystems | Copy only each image's **data extents** (SEEK_DATA/SEEK_HOLE). For devices every data byte is written, even zeros (`known_zero=false`) | `flash.rs:954-966`, `sparse.rs:95-128` |
| Slots | Stream the boot ISO raw into `CI-BOOT-A`, hashing as it goes; `CI-BOOT-B` gets only a zeroed first MiB (devices) | `flash.rs:977-994` |
| Read back | fsync, `posix_fadvise(DONTNEED)`, re-read GPT (must be byte-identical), SHA-256 of slot A against the manifest, header-zero check of slot B, byte compare of every filesystem data extent | `flash.rs:996-1050`, `target.rs:581-592` |
| Success | "Flashed … (N written)" is printed only after read-back; any error exits non-zero | `main.rs:433-452` |

Partition plan for these sticks (`ci-stick layout plan --size 123942731776`):

| # | Label | FS | Start (bytes) | Size (bytes) | Size |
|---|---|---|---|---|---|
| 1 | CI-EFI | vfat | 1,048,576 | 1,073,741,824 | 1 GiB |
| 2 | CI-SHARED | exfat | 1,074,790,400 | 7,516,192,768 | 7 GiB |
| 3 | CI-BOOT-A | raw | 8,590,983,168 | 11,811,160,064 | 11 GiB |
| 4 | CI-BOOT-B | raw | 20,402,143,232 | 11,811,160,064 | 11 GiB |
| 5 | CI-CACHE | exfat | 32,213,303,296 | 78,383,153,152 | 73 GiB |
| 6 | CI-PERSIST | ext4 | 110,596,456,448 | 13,345,226,752 | 12.43 GiB |

The usable size is 123,940,634,624 bytes. The layout leaves 1 MiB at each end for the primary and backup GPT.

### 2.2 What `flash` does not do

- **One device per invocation.** `--device` takes one path (`main.rs:77-100`). There is no batch mode, no queue, and no inter-process locking beyond the kernel's O_EXCL.
- **Linux only.** `LiveFacts::gather` bails on any other OS with "writing to devices on macos is not supported yet" (`target.rs:488-493`), and `open_exclusive` is `bail!` off Linux (`target.rs:575-578`).
- **No timing.** `--json` disables progress (`main.rs:409-413`); `WriteReport` holds only `bytes_written` and a list of check strings (`flash.rs:235-239`); `step()` lines on stderr carry no timestamps (`flash.rs:676-678`). Throughput per stick cannot be recovered from `ci-stick` output.
- **Progress is silent without a TTY.** `Progress::auto` draws only on a terminal (`progress.rs:17-23`), and the sparse filesystem copy passes a no-op callback (`flash.rs:958`).
- **Bundle hashing is repeated per process.** `verify::verify(..., HashMode::Full)` is hard-coded. Nine parallel flashes read and hash the entire bundle nine times, including in `--dry-run`. For today's ~6 GB bundle that is cheap. For a bundle carrying 73 GiB of models it is a real cost (and a reason to add a verify-once path, section 9).
- **No per-stick state is written.** The only mutable ESP content is `ci-stick/grubenv` with `active_slot=A` (+ optional `extra_cmdline`). No stick id, serial, flash time, host or key fingerprint is recorded on the stick (`flash.rs:418-423`, `grubenv.rs`).
- **No capacity test.** The only capacity check is the size read from sysfs against the 57 GiB minimum (`target.rs:272-279`).
- **Not crash-safe** (review F-8): the GPT and a populated ESP with `active_slot=A` exist long before slot A is complete (`flash.rs:935-977`). An interrupted flash leaves a stick that looks valid. Re-running recovers.

### 2.3 Per-stick identifiers

| Identifier | Set by | Random per run? | Evidence |
|---|---|---|---|
| GPT disk GUID, six partition GUIDs | `sgdisk --clear` + `--new` | Expected yes (gdisk generates GUIDs on creation). **Not observed**: no sgdisk on this Mac and the review also never ran it. `sgdisk -G` exists to re-randomize after cloning | `gpt.rs:21-40`; sgdisk man page <https://manpages.debian.org/testing/gdisk/sgdisk.8.en.html> ("-G … may be used after cloning a disk in order to render all GUIDs once again unique") |
| ESP FAT volume ID | `mkfs.vfat` default | **Time-derived** ("a number which depends on the filesystem creation time"). Two processes started within the clock's resolution could get the same ID (UNVERIFIED). `ci-stick` passes no `-i` | `flash.rs:694-703`; <https://manpages.debian.org/testing/dosfstools/mkfs.fat.8.en.html> |
| exFAT volume serial (CI-SHARED, CI-CACHE) | `mkfs.exfat` | Not documented; `mkfs.exfat` has no option to set the serial (`-U` sets the volume GUID only). `tune.exfat -I` can set it later | `flash.rs:713-716`; <https://manpages.debian.org/testing/exfatprogs/mkfs.exfat.8.en.html>, <https://manpages.debian.org/testing/exfatprogs/tune.exfat.8.en.html> |
| ext4 UUID (label `writable`) | `mkfs.ext4` | Yes. A scratch mke2fs 1.47.4 run on a file of the exact CI-PERSIST size printed a fresh random UUID | measured, section 7 |
| grubenv, grub.cfg, bootloaders, slot A ISO | bundle | Identical on every stick by design | `flash.rs:753-804` |
| Device key, serial label, stick id | nothing | n/a. **None exists.** | no match in `stick/crates` |

Review F-21 already says the same: writing one image to many sticks duplicates GUIDs and filesystem serials; either flash each stick separately or re-randomize (`sgdisk -G`, `tune2fs -U`).

### 2.4 Safety rules (what protects the wrong disk)

From `target.rs:227-281`, `527-573`, `622-638` and `flash.rs:362-376`:

1. Not a loop, zram, ram, dm, md, nbd, sr or mmcblk0boot device (`NEVER_TARGETS`).
2. `lsblk` must list it as a whole disk, not holding `/`, `/boot`, `/boot/efi`, `/usr`, `/var` or swap, and it must be `rm=1` **or** `tran=usb` (`devices.rs:29-31`). This also matches a non-removable USB hard disk (review F-14) and, on this Mac, would match `CI_SETUP`.
3. No partition mounted (by major:minor against mountinfo), no swap, no holders.
4. At least 57 GiB.
5. `--confirm` must equal the resolved node; `--expect-serial` is required whenever a serial is found.
6. O_EXCL open; identity re-read immediately before the first write.
7. Serial discovery falls back to the nearest `serial` attribute up the sysfs chain, which can be a hub's (review F-16).

For mass flashing these are necessary but not sufficient: they stop mounted and system disks but **do not know which sticks belong to the batch**. A batch wrapper must supply that (section 8.7).

### 2.5 Test coverage relevant to this work

`stick/tests/qemu/run.sh` flashes a **sparse 64 GB image** (not a device), boots it in QEMU three times and checks the safety refusals. It never exercises `flash --device` positively, parallel runs, 123.9 GB geometry, or real USB hardware. The review confirms: "No `--device` command was run" and `open_exclusive`/`recheck_identity` "have never been executed" (the 2026-10-12 flash review sections 5 and 7).

---

## 3. The attached hardware (read-only inspection, 2026-10-13)

Host: MacBook Pro Mac14,6, Apple M2 Max, 96 GB, macOS 27.0.1 (`sw_vers`, `system_profiler SPHardwareDataType`). Commands used, all read-only: `diskutil list external physical`, `diskutil info`, `system_profiler SPUSBHostDataType`, `ioreg -p IOUSB -l -w0`, `ioreg -a -r -c IOUSBHostDevice -l`.

### 3.1 What the sticks look like

- Nine identical devices: 123,942,731,776 bytes = 242,075,648 × 512-byte sectors, 512-byte logical and preferred block size, "USB DISK 3.0", protocol USB, "Removable Media: Removable", Media Read-Only: No (`diskutil info disk14..disk22`).
- Each carries a vendor **MBR** with one FAT32 partition `USB DISK`, starting at byte **24,838,144** (sector 48,512) and running to the exact end of the disk (24,838,144 + 123,917,893,632 = 123,942,731,776). Each volume is 64 KiB-cluster FAT32 with 6.4-6.6 MB used. All nine are currently **auto-mounted read-write under /Volumes** (`USB DISK` … `USB DISK 8`). Volume UUIDs differ per stick (`diskutil info disk14s1` …).
- USB descriptors, all identical except serial: `idVendor 0x13fe`, `idProduct 0x6700`, `bcdDevice 0x0110`, one configuration, one interface of class 8 / subclass 6 / protocol 0x50 = **Bulk-Only Transport, not UASP**, even on the 5 Gb/s links (ioreg interface nodes). `bcdUSB` is 0x0320 on SuperSpeed links and 0x0210 on High-Speed links. Declared max power 504 mA at SuperSpeed, 300 mA at High-Speed (system_profiler "Power Allocated").
- Serial numbers are unique across all nine (16 hex characters each), so USB serial is usable as the per-stick key. Whether the serial is stable and unique in a larger purchase is UNVERIFIED.

### 3.2 Stick-by-stick topology

`diskN` names are macOS's and change on replug or reboot. The USB serial is the identity.

| BSD disk | USB serial | Speed | Location ID | Path (root → stick) |
|---|---|---|---|---|
| disk14 | 0721557FA198BB28 | **5 Gb/s** | 0x00241000 | Intel 8087:0b40 (10 Gb/s) → Sonnet 2a8c:305d (10 Gb/s) port 1 |
| disk16 | 0721557FA698BB32 | **5 Gb/s** | 0x00242000 | Intel 8087:0b40 → Sonnet 2a8c:305d port 2 |
| disk15 | 0721557F9B657202 | **5 Gb/s** | 0x00243000 | Intel 8087:0b40 → Sonnet 2a8c:305d port 3 |
| disk17 | 0721557FAB98BB51 | **5 Gb/s** | 0x00221000 | Intel 8087:0b40 → Genesys 05e3:0626 (5 Gb/s) port 1 |
| disk18 | 0721557F96657201 | **5 Gb/s** | 0x00222000 | Intel 8087:0b40 → Genesys 05e3:0626 port 2 |
| disk19 | 0721557FB098BB70 | 480 Mb/s | 0x00146000 | Fresco 1d5c:5801 → Sonnet 2a8c:205d (USB 2 half) port 6 |
| disk20 | 07215570C4657242 | 480 Mb/s | 0x00123100 | Fresco 1d5c:5801 → Genesys 05e3:0610 (USB 2) port 3 → Terminus 1a40:0801 port 1 |
| disk21 | 0721557F9B98BB08 | 480 Mb/s | 0x00131200 | Fresco 1d5c:5801 → Terminus 1a40:0101 port 3 → Terminus 1a40:0101 port 1 → port 2 |
| disk22 | 07215570C4657241 | 480 Mb/s | 0x00131400 | same chain as disk21, port 4 |
| disk23 (**not ours**) | 74573870 (24a9:205a, `CI_SETUP`, NTFS 503 GB) | 480 Mb/s | 0x00110000 | Fresco 1d5c:5801 port 1 |

Sources: `system_profiler SPUSBHostDataType`; the disk-to-serial mapping came from walking the `ioreg -a` plist (IOMedia `BSD Name` under the owning `IOUSBHostDevice`), and `UsbLinkSpeed` is 5,000,000,000 for the five SuperSpeed sticks and 480,000,000 for the four High-Speed ones.

**What this means**

- All ten storage devices hang off **one** Apple xHCI instance (bus Location 0x00000000, driver `AppleT8112USBXHCI`). The USB 2 side (Fresco hub at root port 1) and the USB 3 side (Intel hub at root port 2) are separate root ports of that controller, almost certainly one Thunderbolt/USB-C connection (inferred, not proven).
- **The five SuperSpeed sticks share the Intel hub's single 10 Gb/s link** (marked `USB4: Yes`). Three share the Sonnet 305d hub with a Realtek LAN adapter; two share the Genesys 0626 hub with another Realtek LAN adapter.
- **The four High-Speed sticks share one 480 Mb/s link**, the Fresco hub at root port 1, together with `CI_SETUP`, a card reader (05e3:0751), a video adapter, the Sonnet dock's USB 2 side and others. Theoretical USB 2.0 maximum is 53 MB/s (<https://en.wikipedia.org/wiki/USB_2.0>); a practical figure of 30-40 MB/s is a rule of thumb (UNVERIFIED). Four sticks writing at once get about 9.5 MB/s each at best.
- **Why four are at 480 Mb/s:** three of the four sit behind hubs that are USB 2 only (Terminus FE1.1 `1a40:0101` is listed as a plain USB 2 "Hub" in usb.ids; the second Terminus `1a40:0801` is not in usb.ids so its class is UNVERIFIED, but it enumerates at 480 Mb/s as "USB 2.0 Hub"). A SuperSpeed device on a USB 2 hub link-trains at High-Speed by design. The fourth, `0721557FB098BB70`, is on the USB 2 half (`2a8c:205d`) of a hub whose SuperSpeed half (`2a8c:305d`) carries the other three; why that port did not train SuperSpeed (USB-A port without SS lanes, cable, port wiring) is UNVERIFIED. Moving it to a known-good SuperSpeed port is the test.
- The five SuperSpeed sticks prove the sticks themselves support 5 Gb/s.
- Hub cascade depth in use is at most three hubs (Fresco → Terminus → Terminus), within the five-tier limit (<https://en.wikipedia.org/wiki/USB_hub>).
- **`ci-stick doctor` on this Mac lists `CI_SETUP` (disk23) as a flashable candidate** with a 468.8 GiB layout, next to the nine target sticks. Any batch tooling that selects "all external USB disks" would erase it. Select by serial allow-list only.

### 3.3 Chip identification

| ID | What the public source says | Confidence |
|---|---|---|
| 13fe (vendor) | `usb.ids` (usbids/usbids on GitHub, fetched 2026-10-13) lists `13fe Phison Electronics Corp.` with Kingston DataTraveler and generic flash-drive products. `13fe:6700` itself is **not** in usb.ids | vendor yes, product no |
| Controller behind 13fe:6700 | Not found. A forum post shows a Phison PS2307 reporting VID 13FE and the string "USB DISK 3.0", but the same string appears on other controllers (<https://qna.habr.com/q/620361>). Identify it on a spare stick with ChipGenius-class tools or `lsusb -v` on Linux | **UNVERIFIED**. "Phison-family OEM stick" is a reasonable assumption, not a fact |
| 05e3:0610 / 05e3:0626 (Genesys) | `usb.ids` lists both as "Hub". A Linux kernel thread identifies 05e3:0610 as the USB 2.0 half and 05e3:0620 as the USB 3 half of the GL3523 4-port hub (<https://lkml.iu.edu/hypermail/linux/kernel/2301.1/01363.html>). 0626 is not named there | 0610: probable GL3523 family; 0626: UNVERIFIED |
| 1a40:0101 (Terminus) | usb.ids: "Hub" (Terminus FE1.1-class 4-port USB 2 hub; chip family inferred) | vendor yes, model inferred |
| 1a40:0801 | Not in usb.ids (1a40:0201 is "FE 2.1 7-port Hub") | UNVERIFIED |
| 1d5c:5801 (Fresco Logic) | vendor in usb.ids; product not listed. system_profiler calls it "USB2.0 Hub" | UNVERIFIED model |
| 2a8c:205d / 305d | Manufacturer string "Sonnet Technologies, Inc." in system_profiler; not in usb.ids. The Sonnet "Echo 11 Thunderbolt 4 Dock" (2a8c:005d) is a separate downstream device | vendor via system_profiler only |
| 8087:0b40 (Intel "USB3.0 Hub", 10 Gb/s, USB4) | Not in usb.ids; no public mapping found. Consistent with the USB hub function of an Intel Thunderbolt/USB4 controller | **UNVERIFIED** |

Implications: the sticks use Bulk-Only Transport, so the kernel's `usb-storage` driver, not `uas`, will drive them on Linux. The sticks' own controller and NAND are unknown, so their sustained-write behaviour must be measured, not assumed. The hubs on this desk are consumer dock hubs; whether any of them supports per-port power switching (needed for `uhubctl`) is UNVERIFIED.

---

## 4. Real-world throughput, counterfeit risk and what to test

### 4.1 Sustained write on cheap 128 GB sticks

There is no independent test of `13fe:6700` I could find. Public evidence for the category:

- Gough Lui's full-drive HD Tune pass of a SanDisk Ultra Flair 128 GB (2018): writes peaked at about 37-38 MB/s, then averaged about 15 MB/s for the rest of the drive. He estimated a pSLC cache of about 3-4 GiB from the early peak. CrystalDiskMark 1 GiB sequential write was 37.72 MB/s. The plug was "noticeably warm" and no throttling was measured; fully-written read speed was 156 MB/s versus 59.9 MB/s on a fresh drive (<https://goughlui.com/2018/09/30/review-sandisk-ultra-flair-128gb-usb-3-0-flash-drive-sdcz73-128g-g46b/>).
- Raspberry Pi's 128 GB flash drive is specified at 75 MB/s sustained write, measured "after the cache is filled and operating in write through mode". That is a vendor claim for a premium part (<https://www.helpnetsecurity.com/?p=354328>).
- A roundup lists the Amazon Basics 128 GB at 130 MB/s read / 30 MB/s write. I found no sustained test to confirm it.
- Thermal throttling evidence exists for portable SSDs (AnandTech: cut-offs around 67 C and 75 C, drops to 10-100 MB/s), not for sticks, so it is only an analogue (<https://at-web1.www.anandtech.com/show/13341/seagate-fast-ssd-and-sandisk-extreme-portable-ssd-1tb-usb-31-das-review/4>).

**Planning bands used below:** 15 MB/s (post-cache cheap stick), 30 MB/s (typical), 60 MB/s (optimistic). The QLC-versus-TLC split and exact SLC-cache size of this stick family are UNVERIFIED (no source found); treat the first 3-4 GiB as possibly faster and everything after as the real rate.

### 4.2 Counterfeit and fake-capacity risk

- All nine report the identical size and the same BOT descriptors, which is consistent with one product, but a fake-capacity stick also reports a consistent (false) size, so identical numbers prove nothing.
- The reported 123.94 GB is 3.2% below the 128 GB (decimal) marketing figure. That alone is not proof of a fake (the layout code itself notes vendors differ, `layout.rs:33-35`), but it is a reason to test.
- F3 is the standard tool: `f3write`/`f3read` fill a mounted filesystem and re-read it (Linux, macOS, FreeBSD, Windows); `f3probe` tests the raw unmounted device, writes only what it needs, is destructive, and is **Linux-only** (<https://fight-flash-fraud.readthedocs.io/en/stable/introduction.html>).
- What `ci-stick`'s read-back would and would not catch: it writes at offsets across the whole device (the last-MiB zeroing at 123.9 GB, GPT backup, persist at 103 GiB, cache at 30-103 GiB), so a wrap-around fake would very likely corrupt the primary GPT and fail the "GPT changed while writing partitions" check (`flash.rs:1001-1006`). That is luck-based, not a capacity test, and a stick that is only partly fake in the unwritten holes would pass.
- **Recommendation:** make a destructive capacity check a **one-time intake gate** per stick (`f3probe --destructive --time-ops` on Linux, section 8.4), not part of every flash. Once the CI-CACHE is populated and every model blob is SHA-256 verified after flashing, that verification also covers most of the 30-103 GiB range.

---

## 5. Where the flashing can run

| Option | Verdict | Why |
|---|---|---|
| **Bare-metal Linux station** (x86_64 mini-PC or small server, Ubuntu 26.04, headless) | **Recommended** | `ci-stick flash --device` is written for it and CI-tested only in QEMU. Direct xHCI, honest `sysfs`/udev serials, O_EXCL works as designed, no virtualization layer between `ci-stick` and the sticks. Needs sgdisk, mkfs.vfat/exfat/ext4, mtools (`tools.rs:12-19`) |
| **Raspberry Pi 5 + powered hubs** | Good, cheaper, **UNVERIFIED for ci-stick** | Two USB 3.0 ports at 5 Gb/s simultaneously and 5 V / 5 A supply (<https://www.raspberrypi.com/products/raspberry-pi-5/>) give two independent 5 Gb/s roots. `ci-stick` has not been built or run on aarch64 Linux by anyone here (UNVERIFIED); the flashed content is still x86_64 |
| **Cloud-less dedicated station** | Same as the first row | There is no reason for network connectivity during flashing beyond fetching the bundle once |
| **Mac + Linux VM with USB capture** | Experimental only | See below |
| **Mac + Docker Desktop** | Not suitable for `--device` | Docker documents that Desktop has no direct USB passthrough and offers USB/IP instead (<https://docs.docker.com/desktop/troubleshoot-and-support/faqs/general/>). Nine mass-storage devices through USB/IP into the Docker VM is untested and not recommended. Docker **is** fine for `flash --image` (no USB involved) |
| **Mac + Lima 1.0.6** | Not suitable | I found no verified host-USB passthrough for Lima (UNVERIFIED) |
| **Mac + `--image` + manual write** | Possible, second best | Section 6 |

### Mac plus a Linux VM

- **UTM 4.7.4 (QEMU backend), installed.** UTM documents USB sharing as supported only by the QEMU backend, notes that macOS captures devices without custom kernel drivers so a proper hardware reset is not possible and "many devices won't work properly" when captured, and says some flash drives cannot be captured on iOS (<https://docs.getutm.app/guest-support/sharing/usb/>). Capturing mass-storage sticks requires the host to release them first (unmount) and puts every byte through QEMU's USB redirection. Throughput and reliability with nine sticks are UNVERIFIED.
- **Apple Virtualization framework.** Historically no host-USB capture existed (Apple Developer Forums, <https://developer.apple.com/forums/thread/739985>). This Mac runs macOS 27.0.1 and Apple's documentation now lists `VZUSBPassthroughDeviceConfiguration` / `VZUSBPassthroughDevice` as available from macOS 27.0 (<https://developer.apple.com/documentation/virtualization/vzusbpassthroughdeviceconfiguration.md>). The pages say nothing about device classes, entitlements, Linux-guest support or limits. Whether UTM 4.7.4, Lima 1.0.6 or Docker 4.95.0 use it is UNVERIFIED. Treat it as something to test with **one** spare stick, never with the batch.
- QEMU 11.1.2 (Homebrew), VirtualBox 7.2.4 and Docker Desktop 4.95.0 are also installed. None was exercised.
- Even if capture works, `ci-stick`'s sysfs-based identity checks would see virtual `usb-storage` devices with the sticks' serials but would run against a VM, and the USB 3 tree's 5 Gb/s negotiation would be emulated. Not a production path.

---

## 6. What is and is not possible from this Mac today

### Possible now

| Action | Status |
|---|---|
| Read-only inventory by USB serial (diskutil, system_profiler, ioreg) | Done; commands in section 10 |
| `ci-stick layout plan --size 123942731776`, `ci-stick doctor` | Done. `doctor` works read-only via diskutil and lists disk14-22 plus disk23. It prints "Host install yes" which is premature (review F-19) |
| `ci-stick flash <bundle> … --image <file> --size 123942731776 --dry-run` | Possible (needs a signed bundle; planning does not need the mkfs tools, `flash.rs:290-534`). Not run: no bundle was available |
| Producing real sparse stick images (`flash --image`) | Needs the Linux tool set. **None of sgdisk, mkfs.vfat, mkfs.exfat, mkfs.ext4 (only Android's `mke2fs` and Homebrew's e2fsprogs 1.47.4), mtools exist on this Mac.** Docker Desktop or Lima can host them. Availability of exfatprogs/dosfstools/gptfdisk for macOS is UNVERIFIED |
| Running `f3write`/`f3read` | f3 is not installed. They work on macOS on a mounted filesystem (per F3 docs) |

### Possible only by the user, outside `ci-stick`'s safety model

- Writing a finished stick image to a stick with `sudo dd of=/dev/rdiskN` after `diskutil unmountDisk`. `ci-stick` offers no macOS device writes, no confirmation, no serial pinning, no read-back. This is a manual, destructive step and I did not and will not do it. **Critical caveat:** an image written with `--image` skips all-zero blocks inside filesystem data extents and leaves holes (`flash.rs:922` sets `known_zero=true`; `sparse.rs:95-128`). Writing that sparse file onto a **used** stick with a hole-skipping writer (bmaptool, `dd conv=sparse`, sparse-aware imagers) leaves the old FAT32 bytes in those holes, which can corrupt the exFAT bitmap or the ext4 journal. The image must be written in full (115.4 GiB per stick) or the stick must be zeroed first. This is a different, additional hazard from review F-12.

### Not possible from this Mac

- `ci-stick flash --device` or `ci-stick slot set --device` (hard refusal, `target.rs:488-493`).
- Booting the result (Apple Silicon cannot boot x86_64 sticks, `doctor` says so).
- Measuring true write throughput, SLC-cache cliff, thermals, counterfeit capacity or hub power draw. All require writing to the sticks, which was forbidden for this investigation. These are the open measurements in section 11.
- `f3probe`, `uhubctl`, `udevadm`, `lsusb -t`: Linux-only tooling.
- Parallel-flash behaviour: untested anywhere.

---

## 7. Write volume and time estimates

### 7.1 What a flash writes

| Item | Bytes written | Evidence |
|---|---|---|
| Boot ISO into CI-BOOT-A | ISO size (slot cap 11 GiB). The Companion OS ISO was about 7.9 GB with every optional tool baked on the retired 24.04.5 base (docs/architecture/tier-b-tools.md, section 6); the stock Ubuntu 26.04.1 Desktop ISO is 6,482,409,472 bytes; one built 26.04.1 Companion OS image measured 7,076,577,280 bytes (`verify-iso.sh` section 9). The 11 GiB slot holds any of them | `flash.rs:977` |
| CI-PERSIST ext4 data extents | **68.5 MiB** (19 extents, journal 64 MiB). Measured on this Mac with e2fsprogs 1.47.4, `-t ext4 -F -q -L writable -E nodiscard,lazy_itable_init=1`, on a 13,345,226,752-byte scratch file, using SEEK_DATA. Ubuntu 26.04's e2fsprogs (1.47.2) and `mke2fs.conf` may differ slightly | measured in scratch, file deleted |
| CI-EFI FAT32, CI-SHARED / CI-CACHE exFAT metadata | Estimated a few MiB each plus about 8-10 MiB of bootloaders in the ESP. **Not measured**: no dosfstools/exfatprogs on this Mac. exFAT default cluster is 128 KiB above 32 GiB per the mkfs.exfat man page | UNVERIFIED |
| CI-BOOT-B | 1 MiB of zeros | `flash.rs:988-992` |
| Skipped (holes, never touched) | slot A remainder, slot B, SHARED, CACHE, most of PERSIST, ESP free space | `sparse.rs` |

So scenario **S1 (an OS-only flash)** is about 6.5 GB for a stock-sized ISO and about 8 GB with the optional tools, 5-6.5% of the stick. The tables below keep the 6.5 GB figure; scale them by 1.25 for the larger ISO. Read-back re-reads slot A and every extent, so it is about the same volume again.

When slice 4 fills CI-CACHE, scenario **S2** is 6.5 GB + 73 GiB (78.4 GB) = about 84.9 GB. Scenario **S3** is a full-device overwrite: 123.94 GB (this is what a golden image written whole, or an f3-style test, costs).

### 7.2 Per-stick write time (single stick, uncapped)

| Scenario | 10 MB/s | 15 MB/s | 30 MB/s | 60 MB/s |
|---|---|---|---|---|
| S1: ~6.5 GB | 10m50s | 7m13s | 3m36s | 1m48s |
| S2: ~84.9 GB | 2h21m | 1h34m | 47m | 24m |
| S3: 123.94 GB | 3h26m | 2h17m | 1h08m | 34m |

Computed with 1 MB = 10^6 bytes. If the stick's SLC cache is 3-4 GiB and the post-cache rate is 15 MB/s, S1 is dominated by the cache and could be nearer the 30 MB/s column; S2 and S3 are dominated by the post-cache rate.

### 7.3 Batches of 1, 5 and 9

The per-stick time is unchanged when sticks write in parallel **as long as the shared uplink is not the limit**. Uplink caps per stick:

| Uplink | Aggregate | 1 stick | 5 sticks | 9 sticks |
|---|---|---|---|---|
| 5 Gb/s USB 3 (USB 3.0 spec: ~400 MB/s reasonable, ~450 MB/s available to apps, <https://en.wikipedia.org/wiki/USB_3.0>) | ~450 MB/s | not limiting | 90 MB/s each | **50 MB/s each** |
| 480 Mb/s USB 2 (theoretical 53 MB/s; ~38 MB/s is my planning figure, UNVERIFIED) | ~38 MB/s | 38 | 7.6 | 4.2 |

Batch wall time (all sticks in parallel) is the single-stick time in 7.2, with 60 MB/s sticks capped to 50 MB/s when nine share one 5 Gb/s link. Compare writing one stick at a time (9 ×):

| Scenario | 15 MB/s: 1 / 5 / 9 parallel | 15 MB/s: 9 serial | 30 MB/s: 1 / 5 / 9 parallel | 30 MB/s: 9 serial | 60 MB/s: 1 / 5 parallel; 9 parallel (capped at 50) | 60 MB/s: 9 serial |
|---|---|---|---|---|---|---|
| S1 | 7m13s each | 1h05m | 3m36s each | 32m | 1m48s; 2m10s | 16m |
| S2 | 1h34m each | 14h08m | 47m each | 7h04m | 24m; 28m | 3h32m |
| S3 | 2h17m each | 20h39m | 1h08m each | 10h20m | 34m; 41m | 5h10m |

For this Mac's current tree: the four USB 2 sticks writing together would get ~9.5 MB/s each, so S1 takes about 11m25s, S2 about 2h29m, S3 about 3h37m, on top of whatever else shares that link. The five SuperSpeed sticks share a 10 Gb/s link, which is not the limit at 15-60 MB/s each (5 × 60 = 300 MB/s).

Read-back adds roughly the same volume at the stick's read speed. At 100 MB/s that is about 1 minute for S1, 14 minutes for S2, 21 minutes for a full-device read (fresh sticks may read slower: 60 MB/s on the Gough Lui sample).

**Sparse skipping:** it is what makes S1 cheap. It saves about 108 GiB per stick today (115.4 GiB minus ~7 GiB), including the whole of `CI-BOOT-B`. It stops mattering once CI-CACHE is populated, and it never applies to the `--image` route onto used media (section 6).

### 7.4 Power and thermals

- Each SuperSpeed stick declares up to 504 mA (2.52 W) and each High-Speed one 300 mA (system_profiler "Power Allocated"). Nine at worst case is about 22.7 W at 5 V (4.5 A). Real draw while writing is UNVERIFIED; measure with an inline USB power meter.
- A bus-powered hub can provide at most four 100 mA units downstream (<https://en.wikipedia.org/wiki/USB_hub>). Use **externally powered** hubs sized for at least the declared worst case plus margin, with per-port power switching if you want remote power cycling (`uhubctl` needs hubs that "implement per-port power switching" and actually cut VBUS; USB 3 hubs appear as two virtual hubs and both must be switched, <https://github.com/mvp/uhubctl>).
- Sticks in a tight stack on a long write get hot (Gough Lui: "noticeably warm"). Space them, add airflow, and abort the batch on a measured per-stick rate collapse (section 8.8).

---

## 8. Recommended design

### 8.1 Hardware

1. A headless Linux station: x86_64 mini-PC or Raspberry Pi 5, 8 GB or more RAM, local NVMe/SSD with room for the bundle plus logs.
2. One or two **externally powered** USB 3 hubs with per-port power switching (verify with `lsusb -v | grep -i "per-port power"`; confirm VBUS actually drops). Spread nine sticks across at least two host-side ports or controllers (`lsusb -t`, `lspci | grep -i xhci`); do not hang them behind USB 2 hubs.
3. A 30-40 W 5 V supply budget for the hubs (nine sticks at the declared 504 mA is ~23 W).
4. Gap, airflow and a way to read stick temperature (IR thermometer) for the first run.

### 8.2 Golden image vs per-stick flash

| | Per-stick `ci-stick flash --device` | Golden image written whole |
|---|---|---|
| Bytes per stick (S1) | ~6.5 GB | 123.94 GB (S3) |
| GPT disk and partition GUIDs | Fresh each stick (expected) | Identical on every stick unless `sgdisk -G` afterwards (review F-21) |
| FS identifiers | Fresh ext4 UUID; FAT/exFAT IDs depend on mkfs defaults (see 2.3) | Identical unless re-tuned (`tune2fs -U`, `tune.exfat -I`/`-U`, `mlabel`/`mkfs.vfat -i`) |
| Safety checks (mounted, serial, O_EXCL, identity recheck, read-back) | Built in | Do not exist for `dd` |
| Time for 9 sticks in parallel at 30 MB/s | 3m36s | 1h08m |
| Fits the future model cache | No (slice 4 required) | Yes: build the cache once, copy it |

**Recommendation:** per-stick flash for CI-EFI / CI-BOOT-A / CI-PERSIST, and later a **golden CI-CACHE exFAT image** copied into partition 5 by `ci-stick` (new `--cache-image`, section 9) with `tune.exfat -I`/`-U` applied per stick, because exFAT cannot be populated without root or mounting ([companion-stick.md](companion-stick.md), Known limitations).

**What must be unique per stick:** disk GUID; the six partition GUIDs; ESP FAT volume ID; exFAT serial and GUID for CI-SHARED and CI-CACHE; ext4 UUID. **Recommended additions:** a per-stick identity record (USB serial, bundle id and version, key fingerprint, UTC time, flash host) written to the ESP (for example `ci-stick/stick.json`) as the **last** step, and the same record appended to a station log keyed by USB serial.

### 8.3 Writers in parallel

- One `ci-stick flash --device` process per stick; the number of writers equals the number of sticks (9) as long as the aggregate stays well under the uplink: nine at 50 MB/s is already ~450 MB/s on one 5 Gb/s root. Use at most five writers per 5 Gb/s root and use both Pi 5 ports or two xHCI controllers.
- Give each process its own work dir (`--work-dir /var/tmp/ci-stick/<serial>`), on a filesystem with SEEK_DATA. ZFS with compression breaks the sparse-copy assumption (review F-32).
- Lower dirty-page limits (for example `vm.dirty_background_bytes`, `vm.dirty_bytes` in the 64-256 MiB range) so slow sticks do not stall each other behind the page cache and so `fsync` and progress mean something. This is general Linux practice (UNVERIFIED for this workload).
- Limit CPU contention: SHA-256 runs in-process for hashing and read-back. Modern x86_64 and Pi 5 have SHA instructions; measure.

### 8.4 Intake test (once per stick)

Per new stick on the Linux station, destructive, before it gets a serial label:

```bash
# Identify it first. Never run this on a disk you have not matched by serial.
sudo f3probe --destructive --time-ops /dev/sdX     # fastest honest capacity + speed test (Linux-only)
```

A failure (reported usable size smaller than 123,942,731,776 bytes, or `f3probe` "bad" result) quarantines the stick. A pass is recorded with the date and USB serial. Optionally follow with a full `f3write`/`f3read` pass on the three or four oldest or odd-looking sticks.

### 8.5 Verification

What `ci-stick` already does (2.1) is a good first-pass check. For a batch also do:

1. **Replug and re-verify.** After flash, power-cycle the port (or physically replug), wait for re-enumeration, then run an independent verifier that re-reads with `O_DIRECT` or after `blockdev --flushbufs`: primary **and backup** GPT, slot A SHA-256, `fsck.vfat -n`/`fsck.exfat`/`e2fsck -fn` on the partitions, and (once populated) SHA-256 of every model blob. `ci-stick` has no such command (review F-32, F-5), so this is a recommended new `verify-stick` (section 9). The in-process `posix_fadvise(DONTNEED)` is advisory.
2. **Sampled versus full:** a full-device verify at 100 MB/s costs ~21 minutes per stick in parallel; verifying only the written extents costs a minute (S1). Do full verification on the first run of any new batch of sticks and on the intake test, then extents-only.
3. **Boot check:** boot one stick per batch in a real x86_64 machine (not yet demonstrated end to end, review section 1) and record the result.

### 8.6 Failure handling and re-flash

- Flashing is idempotent: a re-run zeroes the first and last MiB, rewrites the GPT and all extents (`flash.rs:935-1000`). Re-flash is the first response to any failure.
- Any `error:` exit, identity-changed abort, or read-back mismatch marks the stick `FAILED` in the log with the serial and reason. A stick that fails twice goes to quarantine and gets `f3probe`.
- Do not treat "unplugged during flash" as recoverable-by-inspection: the stick may look valid (review F-8). Always re-flash.
- Never retry automatically with a different device node.

### 8.7 Hotplug and wrong-disk safety

1. **Allow-list by serial.** A tab-separated `sticks.tsv` (`serial<TAB>label`) of exactly the nine serials above. The wrapper must refuse any device whose `ID_SERIAL_SHORT` is not on the list, whose `ID_VENDOR_ID:ID_MODEL_ID` is not `13fe:6700`, or whose size is not 123,942,731,776 bytes. `74573870` (CI_SETUP) is on a deny-list.
2. Resolve by serial each time; never trust `/dev/sdX` or macOS `diskN` across replugs. `ID_PATH` identifies a physical port (it changes if the cable moves, <https://oneuptime.com/blog/post/2026-09-13-sysfs-path-changes-stable-udev-identity/markdown>), `ID_SERIAL_SHORT` identifies the stick; only trust a serial after confirming uniqueness (done for these nine).
3. Always run the `--dry-run --json` plan first and compare `.target.identity.serial` and `.size_bytes` to expectation; then pass `--confirm <that node> --expect-serial <that serial>`. `ci-stick` re-checks identity right before the first write (`target.rs:622-638`).
4. Take a per-serial `flock` so two operators or scripts cannot target the same stick.
5. Run the station headless with no udisks automounter, or add `UDISKS_IGNORE=1` for `13fe:6700` while flashing. A desktop automounter would mount new partitions mid-batch and trip `ci-stick`'s mounted-device refusal on the next run.
6. Refuse sticks that enumerate at 480 Mb/s unless explicitly allowed (read `/sys/bus/usb/devices/*/speed`), so a USB 2 hub does not silently turn a 2-hour batch into a 14-hour one.
7. Remember `ci-stick doctor` and the `is_candidate` rule accept any USB disk (`devices.rs:29-31`), so tooling must not use them as the selector.

### 8.8 Logging and traceability

Per stick, under `/var/log/ci-stick/<bundle-id>-<version>/`:

- `<serial>.plan.json` (the `--dry-run --json` output)
- `<serial>.result.json` (the real `--json` output) and `<serial>.log` (stderr with `ts` timestamps added by the wrapper, because `ci-stick` adds none)
- one summary line in `batch.csv`: serial, label, node, USB speed, port path, start, end, bytes written, average MB/s, read-back result, verify-stick result, operator.

Abort or flag a stick whose average MB/s is below a floor (suggest less than half the batch median) or whose rate collapses mid-run.

### 8.9 Runbook (destructive steps marked)

1. **Prepare the station** (Ubuntu 26.04, the supported release; the 24.04 station of the first draft is retired): `sudo apt-get install gdisk dosfstools exfatprogs e2fsprogs mtools f3 uhubctl usbutils jq` (every one of these names has a candidate in the resolute archive, checked 2026-10-18 in an `ubuntu:26.04` container: gdisk 1.0.10-2build1, dosfstools 4.2-1.2build1, exfatprogs 1.3.2-1, e2fsprogs 1.47.2-3ubuntu4, mtools 4.0.49-1, f3 9.0-1build1, uhubctl 2.6.0-3, usbutils 1:019-1, jq 1.8.1-4ubuntu2; only `apt-cache policy` was run, nothing was installed), build `ci-stick` from `stick/` (`cargo build --release --locked`), configure the udev ignore rule and dirty-page limits.
2. **Stage and sign the bundle once** on a trusted machine: `stick/scripts/fetch-signed-boot.sh`, `ci-stick lock`, release signing. Copy the bundle to the station's local disk (not a network share; review F-1 TOCTOU).
3. **Verify once:** `ci-stick verify <bundle> --pubkey <key>`.
4. **Inventory and allow-list** (section 10, Linux half). Compare to the nine serials in 3.2; reject any extra device.
5. **Intake test** each new stick (`f3probe`, 8.4). *Destructive.*
6. **Dry run** the plan for every allow-listed serial (section 10).
7. **Flash in parallel.** *Destructive.* For each serial, in the background with `xargs -P`/GNU parallel, at most five per 5 Gb/s root:
   `sudo ci-stick flash <bundle> --pubkey <key> --device <node-from-plan> --confirm <node> --expect-serial <serial> --work-dir /var/tmp/ci-stick/<serial> --json > <serial>.result.json 2> >(ts > <serial>.log)`
8. **Replug and independent verify** (8.5).
9. **Label** the physical stick with its serial and batch id; record in `batch.csv`.
10. **Archive** the log directory with the bundle id, signature fingerprint and station hostname.

**One sequence floor for the whole station.** `verify` (step 3) and the `sudo ci-stick flash` of step 7 are two accounts unless both
run under `sudo`, and `sudo` usually does not pass `CI_STICK_STATE_DIR` on, so they would keep separate floors. Give both the same
directory with the flag, which does survive `sudo`, and run both as the same account:
`sudo ci-stick --state-dir /var/lib/ci-stick verify <bundle> --pubkey <key>` and
`sudo ci-stick --state-dir /var/lib/ci-stick flash <bundle> ...`. The parallel flashes record the same floor and are safe together
(`simultaneous_writers_do_not_lose_updates`). A floor raised by mistake is forgotten by moving `floors.json` away, which forgets every floor
([companion-stick.md](companion-stick.md#bundle-format-and-trust-model)). UNKNOWN: how the `sudo` of Ubuntu 26.04 treats `HOME` was not checked.

---

## 9. Gaps in the repo that this design depends on

These are not implemented; see the structured recommendations.

1. `flash` re-hashes the entire bundle per invocation (`flash.rs:295-300`) and re-reads the manifest unsigned (`flash.rs:304-305`, F-1). A verify-once path (return the parsed `Bundle` plus a receipt) fixes both and makes 9 parallel flashes cheap.
2. `WriteReport` / `--json` carry no durations or MB/s; `step()` has no timestamps; the sparse copy has no progress.
3. No per-stick identity file; no explicit FAT volume ID; no way to set exFAT serial/GUID; no uniqueness assertion across sticks.
4. No `verify-stick` command for an independent post-replug check.
5. No batch wrapper, allow-list, or lock.
6. No `--expect-size` / `--expect-vid-pid` / USB-speed report in the plan.
7. No supported way to populate `CI-CACHE`, and no warning in the docs that an `--image` output must not be written to used media with a hole-skipping writer.
8. The docs still say `--size 64GB` for the macOS/Windows image route (review F-3); for these sticks the exact device size is `--size 123942731776`.

---

## 10. Dry-run-only command sequence

None of these commands writes to any disk. The first block was run on this Mac during the investigation (output summarized in section 3). The second and third blocks are the proposed Linux-station sequence and were **not executed** (no Linux station was available; UNVERIFIED on real hardware).

### 10.1 Mac, read-only inventory

```bash
diskutil list external physical
for n in 14 15 16 17 18 19 20 21 22; do diskutil info disk$n; done     # NOT disk23
system_profiler SPUSBHostDataType
ioreg -p IOUSB -l -w0
# BSD name <-> USB serial <-> link speed <-> hub chain (read-only; walks `ioreg -a -r -c IOUSBHostDevice -l`):
python3 -I stick/scripts/usb-inventory-macos.py --vidpid 13fe:6700 --deny 74573870
python3 -I stick/scripts/usb-inventory-macos.py --allow sticks.tsv       # flags anything not on the allow-list
# pure planning, no device access:
ci-stick layout plan --size 123942731776
ci-stick doctor                                    # lists disk23 too: never use it as a selector
```

The helper reports `UsbLinkSpeed` (5,000,000,000 or 480,000,000 bit/s); `USBSpeed` 4 = 5 Gb/s and 3 = 480 Mb/s in the same output.

### 10.2 Linux station, inventory and gate

```bash
lsusb -t                                          # tree with 5000M / 480M per link
lspci | grep -i xhci
for d in /sys/block/sd*; do
  n=/dev/${d##*/}
  eval "$(udevadm info -q property -n "$n" | grep -E '^(ID_SERIAL_SHORT|ID_VENDOR_ID|ID_MODEL_ID)=')"
  printf '%s %s %s:%s %s bytes speed=%s\n' "$n" "$ID_SERIAL_SHORT" "$ID_VENDOR_ID" "$ID_MODEL_ID" \
         "$(blockdev --getsize64 "$n")" "$(cat /sys/block/${n##*/}/device/../../../speed 2>/dev/null)"
done
# Keep only 13fe:6700, size 123942731776, serial in sticks.tsv, serial != 74573870.
lsblk -dno PATH,SERIAL,TRAN,RM,SIZE
```

### 10.3 Linux station, plan every allow-listed stick (writes nothing)

```bash
ci-stick verify "$BUNDLE" --pubkey "$KEY"
while IFS=$'\t' read -r serial label; do
  node=$(resolve_node_by_serial "$serial") || { echo "MISSING $serial"; continue; }
  sudo ci-stick flash "$BUNDLE" --pubkey "$KEY" --device "$node" --dry-run --json \
       > "plan-$serial.json"
  jq -e --arg s "$serial" '.target.kind=="device" and .target.identity.serial==$s
        and .target.identity.size_bytes==123942731776' "plan-$serial.json" \
     || echo "MISMATCH $serial"
done < sticks.tsv
```

`resolve_node_by_serial` is the udev loop from 10.2. Note each dry-run still hashes the full bundle (`flash.rs:295-300`).

---

## 11. Open measurements (cannot be done read-only)

1. Sustained write rate per stick (SLC-cache size and post-cache rate) with a destructive test on one spare stick (`f3probe --time-ops`, or `fio` sequential write over 90% of the device).
2. Real power draw per stick during writes (inline USB power meter).
3. Stick temperature under a 1-2 hour continuous write.
4. Controller identity of 13fe:6700 (ChipGenius-class tool or `lsusb -v` on the sticks).
5. Whether the High-Speed stick on Sonnet 205d port 6 trains SuperSpeed in another port.
6. First real `ci-stick flash --device` run, on one stick, on Linux, then three in parallel, then nine.
7. Whether UTM 4.7.4 (QEMU) or the macOS 27 `VZUSBPassthrough` API can pass a mass-storage stick through reliably (one spare stick only).

---

## 12. What changed on 2026-10-18

| Topic | Then (2026-10-13) | Now | Evidence |
|---|---|---|---|
| Station OS | Ubuntu 24.04 | Ubuntu 26.04 (24.04 is retired). Tool packages exist in resolute | section 8.9 step 1 |
| What a station flashes | a 24.04-based Companion OS image | a 26.04.1-based image; the Stick's Secure Boot chain was re-derived from the resolute archive (shim 15.8 `1.59+15.8-0ubuntu2`, GRUB 2.14 `1.215+2.14-2ubuntu1`) and checked with the A/B/C QEMU run (8 checks, PASS) | [companion-stick.md](companion-stick.md#secure-boot) |
| ISO size | about 7.9 GB (24.04.5) | stock 26.04.1 ISO 6,482,409,472 bytes; one built image 7,076,577,280 bytes | [companion-stick.md](companion-stick.md#open-items), item S2 |
| `flash.rs`, `target.rs`, `devices.rs`, `sparse.rs`, `gpt.rs` | as cited | unchanged | `git diff --stat 7734ff5 HEAD` |
| Batch tooling, intake test, first real `flash --device` | none | **still none**; nothing was written to any of the nine sticks | [test-and-mass-flash-plan.md](test-and-mass-flash-plan.md) |
| Model population (scenario S2 of section 7.1) | `ci-stick models sync`, not built | `ci-stick models fetch` exists for Ollama references (tested against local listeners); the golden-cache route of 8.2 is still the recommendation, and `fetch` has not been pointed at an exFAT volume | [models-tooling.md](models-tooling.md) |

The 8 GiB slot of a 64 GB stick matters to a built 26.04 ISO that grows; it does not
affect these 123.9 GB sticks (11 GiB slots), only a later batch of smaller ones.

---

## 13. Sources

Repo: `stick/crates/ci-stick/src/{flash,target,devices,sparse,verify,layout,gpt,tools,main,progress}.rs`, `stick/tests/qemu/run.sh`, `stick/scripts/fetch-signed-boot.sh`, `docs/architecture/companion-stick.md`. The 2026-10-12 flash review (finding numbers `F-n` below) was delivered with that review and is not stored in the repo.

External (fetched 2026-10-13): usb.ids (<https://raw.githubusercontent.com/usbids/usbids/master/usb.ids>), F3 docs (<https://fight-flash-fraud.readthedocs.io/en/stable/introduction.html>), Gough Lui review (link in 4.1), Raspberry Pi flash drive article (<https://www.helpnetsecurity.com/?p=354328>), Raspberry Pi 5 product page, Docker Desktop FAQ, UTM USB docs, Apple Virtualization pages, Wikipedia USB 3.0 / USB 2.0 / USB hub, Debian man pages for mkfs.exfat, tune.exfat, mkfs.fat and sgdisk, uhubctl README, LKML Genesys thread.
