# First-run teardown: how other distros install and start, next to Companion OS

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**
> State of 2026-10-19 (local time). **Evidence label for every number and picture on this page: tested in a virtual machine** (QEMU 11.1.2 with the host's own accelerator, HVF, on one Apple-silicon Mac, arm64 guests, **one run of each distro, no real hardware**). Tags: **[V]** verified (run, result seen), **[I]** read from code or documentation, not run, **[N]** not checked.

## Summary

One run each of stock Ubuntu 26.04.1, Fedora Workstation 44 and Debian 13.7 (its graphical installer: Debian publishes no arm64 live image) and of Companion OS itself, all on the
same evening in the same harness, read with the stopwatch and counts the polish proposal asks for. What the runs show:

* **Companion OS already asks the least**: one confirmation, against 4 pages (Fedora), 13 (Ubuntu) and 15 plus 5 more (Debian), and it says on screen what the machine is doing after
  the install, which none of the others has to. **[V]**
* **It is the only one that shows two installers at once.** Canonical's 13-page window, with Ubuntu's name and logo, opens in front of Companion's dialog in both boot
  entries. Fedora's live session opens with one dialog and two buttons and no installer until the user asks. **[V]** (Figure 1 in [Frames](#frames))
* **The best installer in the set is Fedora's**: 4 pages, nothing typed, four named stages with a percentage, 3 min 52 s, then a first-run wizard that creates the account.
  Companion's install took 11 min 27 s (2.96 times as long), shows one block of text and a bar with no percentage, and hands out a one-time password that the user must copy and
  replace at the first sign-in. **[V]**
* **All three stock installs read `running` with no failed unit; Companion reads `degraded`** (`pd-mapper.service`, KI-28). **[V]**
* **The clock is wrong after a default Companion install.** The dialog says "time zone: detected automatically", and the installed system had `Etc/UTC`; the stock Ubuntu installer
  and Fedora found the host's zone on the same machine, and Debian asks. One run; the cause was not looked for. **[V]**
* **Where Companion is not behind**: the greeter came 28 s after power-on (stock Ubuntu 30 s, Fedora 31 s, Debian 34 s); the first session opened one window (Firefox) and no notice,
  where the others open one tour prompt or a wizard; every distro blanks the screen after 5 minutes and locks the session, so the idle lock is not a Companion gap. **[V]**
* **Where it is behind on the clock**: the live desktop at 1:30 against 1:01 (Fedora) and 1:08 (stock Ubuntu). An earlier day's records said about 2 minutes, and the greeter took 50 s
  in one of them, so a single run has a spread of tens of seconds. **[V]** for this evening, **[I]** for the size of the gap.
* What to do about it is the [ranked list](#gaps-ranked-by-what-the-best-installers-do), mapped to the proposal's items: 5, 6 and 7 move up, 8 stays, and five items are new.
  [The scorecard](#scorecard-against-companion-os) counts where Companion stands: ahead on 2 measures, level on 6, behind on 10 (one row is not scored).

## Scope and what was not measured

The question behind this page: the owner asked how to make the install and the first start of Companion OS look as good as the major Linux distros. The
polish backlog in CI-Engineering (`proposals/companion-os-home-lab-polish.md`) is ranked by effort; this page adds what the distros that most people
install actually do, measured the way that proposal asks for ("stopwatch from the first boot-menu frame, and a count of windows, tabs, notices and failed
units the user did not ask for").

| Distro | Run | Why this one |
|---|---|---|
| Ubuntu 26.04.1 LTS desktop, **stock** | [V] | the base of Companion OS, and the control: what the Ubuntu edition changed is the difference to this column |
| Fedora Workstation 44 Live | [V] | the other big desktop installer (Anaconda, new web interface) and a first-run wizard of its own |
| Debian 13.7.0, graphical installer (netinst) | [V] | the classic installer. **Debian publishes no arm64 live image** (its live images are amd64 only, checked 2026-10-19 in `debian-cd/current-live/`), so this is the installer a Debian user gets on arm64, and its install downloads packages from a mirror |
| openSUSE Tumbleweed GNOME live (aarch64) | [N] | the images exist (GNOME, KDE and XFCE live, about 1.3 to 1.4 GiB) but the owner did not approve their download |
| Linux Mint, Pop!_OS, elementary OS, Zorin | [N] | no arm64 desktop ISO was checked for; amd64 guests under emulation are too slow to give comparable times |

Not measured: any real hardware, amd64, Secure Boot, a second run of any distro (so no spread), Wi-Fi or a captive-portal network, a slow link, a language other
than English, an upgrade or a dual boot. The Companion OS column is a run of its own, made on the same evening with the same harness (see below).

## How the runs were made

Every distro went through the same steps on the same virtual machine, driven by the repository's own arm64 harness
([`boot-arm64-vm.sh`](../../backends/ubuntu/iso/tests/boot-arm64-vm.sh), [`lib/qmp-drive.py`](../../backends/ubuntu/iso/tests/lib/qmp-drive.py),
[`record-frames.sh`](../../backends/ubuntu/iso/tests/record-frames.sh); how they work is in [Testing in QEMU](../guides/testing-in-qemu.md)).
The recorder was started before power-on and took a screendump about every 3 seconds until the run ended, so every time on this page is read from a frame
(a resolution of about 3 seconds) or from a command's own timestamp.

| Item | Value |
|---|---|
| Machine | Apple-silicon Mac, 12 cores, 96 GiB RAM, macOS 27; QEMU 11.1.2, `-machine virt,gic-version=3 -accel hvf -cpu host -smp 6 -m 8192`, edk2 aarch64 firmware without Secure Boot |
| Display, input | `virtio-gpu-pci` at 1280 by 800, `qemu-xhci` with `usb-kbd` and `usb-tablet`, driven over QMP |
| Media | the ISO as a USB mass-storage drive on `bootindex=0` (what a flashed stick looks like to the firmware); a blank 64 GiB virtual NVMe disk as the install target, a file on a RAM disk so that the host's snapshots never pin it (for Companion OS a file on the SSD: its first-boot job adds about 8 GB) |
| Network | QEMU user networking (NAT), the host's real internet connection |
| Host load | other sessions used the same Mac during the runs (a one-minute load average of 7 to 24 at the starts, from searches and another virtual machine that were not ours); every run records its load in `run.txt`. Treat a time as a figure for this machine on this evening, not as a benchmark |
| Account | a throwaway name and a random password typed from a file; no password, key or token is in any frame or text record |

**What counted, the same for every distro.**

| Measure | How it was read |
|---|---|
| Stopwatch | t0 is the first frame that shows the distro's own boot menu (the firmware's frames before it are not counted). Times after it are "t0 plus" |
| Time to a live desktop | t0 to the first frame that shows the session's desktop (panel and wallpaper) |
| Installer opens by itself | an installer window or dialog is in front without a click, or the boot menu's default entry starts an install |
| Questions before the install starts | **pages** the user must pass before the install begins (counting the last review page, not the live session's own welcome), **typed values** (fields typed into), and **choices left at their default** on those pages |
| Languages, keyboard, time zone | what the installer offered, asked or detected, read from its pages |
| Install time | the click that starts the install to the first frame of the installer's own "done" page |
| First sign-in | from the first drawn desktop of the installed system until nothing more appeared for a minute: **windows**, **browser tabs**, **notices** (banners and pop-ups) the user did not ask for, and the first-run pages |
| Failed units | `systemctl --failed` (system and user) read by a read-only script about 5 minutes after the first sign-in, over a text channel (the guest fetches the script from a loopback server on the host and posts the text back; [`guest-facts.sh`](../evidence/2026-10-19-ftue-teardown/guest-facts.sh)) |
| Progress for post-install work | whether anything on screen says that the machine is still working after the install |
| Idle behaviour | the first frame that is black after the last input, and whether the session is locked |

An installer's own wizard is counted as a "page" when it stops and waits for the user, whether it asks a question or only informs. Typing speed was
limited by the test driver (a password field that checks strength dropped keys at 0.14 seconds per key and had to be retyped slowly; a person would
not meet that, so it is not counted as a defect).

**Images.** Each file was checked against its vendor's signed checksum list before it was booted
([`verify-downloads.txt`](../evidence/2026-10-19-ftue-teardown/verify-downloads.txt)): stock Ubuntu 26.04.1 desktop arm64 (the file cached by the repository's
tests, equal to Canonical's signed `SHA256SUMS`), Fedora Workstation Live 44-1.7 aarch64 (signed `CHECKSUM`, key
`36F612DC...90A6`), Debian 13.7.0 arm64 netinst (signed `SHA256SUMS`, key `DF9B9C49...BE9B`). The owner approved the two downloads before they were
made. **Companion OS** was run the same way on the same evening: a clean build of `main` (`5d50582`, the arm64 image of 871 s, `verify-iso.sh` 446 passed, 0 failed, sha256
`0cc31d9c...5110`), installed through the boot menu's automatic entry, with the target disk on the SSD instead of the RAM disk (the first-boot job adds about 8 GB). Its records are
in `companion-os-main-5d50582-arm64/` of the evidence directory. Cells marked "same evening" are from that run; the earlier records of the day (`4b7597d`, `ee4a3b4`, `b124745`,
`82e9335`) are quoted only where this run has nothing to say, and they differ in places (the greeter took 50 s in one of them and 28 s here), which is the spread of a single run.

## Results

### The install, from the boot menu to the end of the installer

| Measure | Ubuntu 26.04.1 stock | Fedora 44 Workstation | Debian 13.7 netinst | Companion OS (Ubuntu edition) |
|---|---|---|---|---|
| Boot menu, default entry | "Try or Install Ubuntu", a 30 s countdown | "Test this media & start", a countdown of about 10 s (it ran by itself) | text-mode "Install" highlighted, **no countdown**; "Graphical install" is the second line | "Try or Install Companion OS", a 30 s countdown; "Install Companion OS (automatic)" is the second line, and the runs chose it with Down, Enter [V] (frame `arm64-01`) |
| t0 to a live desktop | **1:08** (a text boot log for 55 s first, no splash) | **1:01** (a black screen with no text for about 50 s first) | no live session: the installer is the session, first page at t0 + 0:23 (of which 18 s were at the menu) | **1:30** (1:38 from power-on; Canonical's window drawn at 1:37) [V, same evening]; the earlier records (`4b7597d`, `b124745`, `82e9335`) say about 2 minutes from power-on |
| Installer opens by itself | yes, a 13-page window in front, one page asks "Try or Install" | **no**: a Welcome dialog offers "Install Fedora Linux..." or "Not Now" | yes (it is the whole session) | yes: Canonical's 13-page window opens in front in both entries; the automatic entry opens the one-click dialog **behind** it, and two "Install Companion OS" launchers are on the desktop and in the dock [V, same evening] |
| Pages before the install starts | **13** (the last is the review) | **4** (language and keyboard; method; encryption; review) | **15** before the disk is written, then **5 more** questions while it installs (mirror country, mirror, proxy, survey, software) | **1** confirmation (the disk, what is on it, a one-time password), plus an optional "Language, keyboard, time zone" dialog; the user must first pick the second boot entry or click the launcher, and close Canonical's window [V, same evening] |
| Typed values | 3 (a name, the password twice; user and computer names are filled in) | **0** (the account comes later) | 3 (a name, the password twice; root left empty, user name derived) | **0** in the installer |
| Languages in the first list | not counted [N] | not counted [N] (four "suggested" ones on top, then a search) | **78** rows (77 languages and "C") [V] | **59** locales of 8 languages, behind a button [V] (`one-click-install.md`) |
| Keyboard | asked, English (US) preselected, a Detect button and a test field | shown on the first page ("us", a change link) | asked, American English preselected | follows the language, changeable in the optional dialog |
| Time zone | asked on a map, **pre-filled by geolocation** | **not in the installer**; set from the location in the first-run wizard | asked from a list of the country's zones, default Eastern, **no detection** | optional dialog, "detected automatically" is the default, **and the installed clock was on `Etc/UTC` after it** (the stock Ubuntu installer found the host's zone on the same machine) [V, same evening]; the zone chosen by hand in `b124745` did arrive [V] |
| Install time | **10 min 02 s** | **3 min 52 s** | **6 min 24 s** from the disk write, 1 min 20 s of it spent answering the five questions (the packages came from a mirror) | **11 min 27 s** (at most; the wait polls every 5 s) [V, same evening]; 9 min 22 s to 12 min 10 s on three earlier images |
| What the installer's progress shows | a slideshow and a segmented bar with "Copying files..." | **four named stages, each marked, a percentage and the current step** ("Installing boot loader", "Generating initramfs") | a bar and the current package ("Unpacking apt-utils...") | one text block ("this takes a while", the one-time password) and a bar with no percentage [V, same evening] |
| End | "Restart now" or "Continue testing"; the stick is not mentioned | "Successfully installed", one button "Exit to live desktop", a feedback QR code | "Installation complete", **says to remove the installation media**, then "Continue" | the machine powers itself off; the text says to remove the stick and turn it on |

### The first start of the installed system

| Measure | Ubuntu 26.04.1 stock | Fedora 44 Workstation | Debian 13.7 netinst | Companion OS (Ubuntu edition) |
|---|---|---|---|---|
| Power-on to the first screen | **30 s** to the greeter (a boot log, then the greeter) | **31 s** to the setup wizard (there is no greeter) | **34 s** to the greeter (about 8 s of it the boot menu) | **28 s** to the greeter [V, same evening]; 50 s in the `82e9335` record |
| Sign-in to a drawn session | 5 s (the wizard window 2 s later, the updater banner 9 s later) | 4 s ("Start Using" to the desktop; the tour prompt a few seconds later) | 3 s (the tour prompt at 5 s) | 10 s after the new password was confirmed (the one-time password, then a new one twice, come first) [V, same evening] |
| First-run wizard | **6 pages**: welcome, Ubuntu Pro, location services, help improve Ubuntu, appearance, ready to go | **7 screens**: welcome, privacy, time zone, third-party repositories, about you, password, all done | **none** (the account was made in the installer) | **none**; a forced password change instead: the one-time password again, a new password, and a retype [V, same evening] |
| Windows, tabs and notices the user did not ask for, first sign-in | the wizard window and **1 notice** ("72 Updates Available") | **1 modal prompt** (a tour), no notice | **1 modal prompt** (a tour), no notice | **1 window** (Firefox, **1 tab**: the Companion page, by design) and **0 notices** [V, same evening] |
| Work that continues after the first screen | none | none | none | the first-boot job, about 2 min 40 s this evening, **shown by notifications**: "getting the computer ready", steps 3, 5 and 7 of 7, "ready" [V, same evening] |
| Failed units, 5 to 8 minutes after boot | **0** (`running`) | **0** (`running`) | **0** (`running`) | **1** (`pd-mapper.service`, KI-28; the system reads `degraded`) [V, same evening] |
| Firewall, and ports open to the network | `ufw` service active, nothing listens beyond localhost | `firewalld` active; ports 5355 (LLMNR) and 27500 listen on all interfaces; what 27500 is was not looked up [N] | **none**; SSH (22) on all interfaces, because the "SSH server" box is ticked by default | `ufw` service active; SSH (22), Hub (5002), Traefik (8080, 8443, 8880) and **Ollama (11434)** on all interfaces [V, same evening] (CI-Engineering proposal, tier 2) |
| Telemetry defaults | the wizard asks about system data and error reports, **both off** | the wizard has location services and automatic problem reporting, **both on**; `abrtd` runs | a survey asked in the installer, **default No** | `ubuntu-report`, `popularity-contest`, `apport` and `whoopsie` are removed and held; **`ubuntu-insights` is still installed, the Pro client's apt hook is active and `ua-timer.timer` and `motd-news.timer` are enabled** [V, same evening]; the first-run pages are skipped |
| Idle | the screen went black **5 min 02 s** after the last input and the session **locked** | **5 min 03 s**, **locked** | **5 min 02 s**, **locked** | **5 min 04 s**, then the screen blanked and the session locked [V, same evening] |
| Installed system | 1505 packages, 11 GB used, 3 error-level journal lines, boot 22.5 s | 1958 packages, 4.1 GB, **188** error-level lines, boot 17.6 s | 1565 packages, 5.0 GB, 1 error-level line, boot 21.1 s | 1876 packages, 19 GB used (Hub's images and two models included), 21 error-level journal lines, boot 19.8 s [V, same evening] |

### What the screens look like

| | Style | Words | Companion OS next to it |
|---|---|---|---|
| Ubuntu | a window in the Yaru light theme, one illustration per page with an orange accent, page dots at the bottom; the first-run wizard is a full-screen GNOME window with the same illustrations | short, friendly ("Fast, free and full of new features") | the same window opens first, then Companion's dialog; the Companion wallpaper is dark teal, the Canonical window is light |
| Fedora | a web page in a window: a blue gradient header, a **numbered list of steps on the left**, large type, flat buttons; the first-run wizard is plain GNOME with large icons | plain, one idea per screen | none of this: Companion's dialog is a small stock GTK dialog with a table |
| Debian | the classic GTK installer: a beige page under a **"debian13" banner**, long explanatory paragraphs (the root password page is five paragraphs), a Go Back button on every page | accurate and long (the root password page is five paragraphs) | the opposite pole: Companion's text is short |
| Companion OS | the desktop itself is dark teal with Companion icons; the installer dialog and the progress window are small, light, unbranded GTK dialogs; notifications are GNOME's | terse | see [Frames](#frames) |

## Frames

Every frame is a screen capture (QMP `screendump`, 1280 by 800) of a QEMU virtual machine on an Apple-silicon Mac with hardware acceleration (HVF). **None comes
from real hardware.** The three figures below are composites of four frames each, reduced to 632 pixels wide and captioned; they are not captures
(`docs/ui/ftue-teardown/MANIFEST.json` lists what each is made from). The Companion OS panels are frames of the same evening's run (`main` at `5d50582`), in
`docs/ui/ftue-teardown/companion-os-before/`; the earlier Companion OS frames are in [`docs/ui/companion-os/ubuntu/`](../ui/companion-os/ubuntu/CAPTURE.md).

![Four first screens after the boot menu, in a virtual machine: Ubuntu's installer window, Fedora's welcome dialog, Debian's language page, and Companion OS with Canonical's installer window in front.](../ui/ftue-teardown/compare-first-screen.png)

*Figure 1. The first screen after the boot menu (virtual machine). Ubuntu and Companion OS open Canonical's 13-page installer by themselves; Fedora opens one dialog with
two buttons; Debian's installer is the session.*

![Four install progress screens in a virtual machine: Ubuntu's slideshow, Fedora's four named stages with a percentage, Debian's package bar, and Companion OS's single text block with a bar.](../ui/ftue-teardown/compare-install-progress.png)

*Figure 2. The install in progress (virtual machine). Only Fedora names its stages and shows a percentage.*

![Four first sign-in screens in a virtual machine: Ubuntu's full-screen wizard with an update banner, Fedora's tour prompt, Debian's tour prompt, and Companion OS's Firefox window on the getting-started page with a first-boot notification.](../ui/ftue-teardown/compare-first-sign-in.png)

*Figure 3. The first sign-in (virtual machine). Companion OS opens Firefox on its getting-started page by itself; about 3 minutes later the first-boot job starts and a
notification says what it is doing (step 5 of 7 here). That notification is the wanted progress message, not a stray notice.*

| Set | Frames | Manifest |
|---|---|---|
| Ubuntu 26.04.1 stock | 14: boot menu, live boot, 4 installer pages, progress, done, greeter, 4 first-run pages, the desktop after | [`ubuntu-stock/MANIFEST.json`](../ui/ftue-teardown/ubuntu-stock/MANIFEST.json) |
| Fedora Workstation 44 | 10: boot menu, live welcome, 2 installer pages, progress, done, 3 first-run pages, first session | [`fedora/MANIFEST.json`](../ui/ftue-teardown/fedora/MANIFEST.json) |
| Debian 13.7 netinst | 11: boot menu, 5 installer pages, the software selection, progress, done, greeter, first session | [`debian/MANIFEST.json`](../ui/ftue-teardown/debian/MANIFEST.json) |
| Companion OS, `main` at `5d50582` | 8: boot menu, Canonical's window, the one-click dialog, progress, greeter, first session, two first-boot notifications | [`companion-os-before/MANIFEST.json`](../ui/ftue-teardown/companion-os-before/MANIFEST.json) |

Hygiene (the rules of [`docs/ui/companion-os/README.md`](../ui/companion-os/README.md)): the raw bytes of every PNG and every text record were searched for the throwaway
password and its halves (0 hits), every frame was read by OCR and searched for host names, user names, e-mail and IP addresses, hex strings of 24 or more digits and the
host's region (0 hits), and each frame was looked at. The time zone pages that pre-select the host's region (Ubuntu's map, Fedora's map) are **not** published; the installer
pages show the throwaway account name and the date of the run. The text records name the zone the stock installers detected (`America/Los_Angeles`, the host's own, as the
repository's earlier records already do); it is the evidence for the detection claims, and nothing finer than the zone is recorded. **Two Companion OS frames are not as captured:** the one-click dialog and the progress window show the one-time
password, so a dark bar was drawn over that text after the capture (the same redaction as frames 04, 05 and 14 of the existing Companion OS set, and the manifest says so); no other frame was changed.

## Scorecard against Companion OS

Verdicts compare Companion OS with the best of the three stock installs on the same measure, from the runs of one evening. "Ahead", "level" and "behind" are the author's reading of the
table; a number is quoted wherever there is one, and a difference of a few seconds counts as level.

| # | Measure | Best of the three | Companion OS | Verdict |
|---|---|---|---|---|
| 1 | Pages before the install starts | Fedora, 4 | 1 confirmation (plus the boot-entry pick and closing Canonical's window) | **Ahead** |
| 2 | Typed values in the installer | Fedora, 0 | 0 | Level |
| 3 | Installers on screen at once | 1 (Fedora: none until asked) | 2 (Canonical's window and the dialog) | **Behind** |
| 4 | t0 to a live desktop | Fedora, 1:01 | 1:30 | **Behind** |
| 5 | Install time | Fedora, 3:52 | 11:27 | **Behind** |
| 6 | Install progress detail | Fedora: four named stages, a percentage | one text block, a bar with no percentage | **Behind** |
| 7 | Power-on to the first screen | Ubuntu, 30 s | 28 s | Level |
| 8 | Account and password | the user picks both during setup (Ubuntu, Fedora, Debian) | a one-time password to copy, then three password entries at the first sign-in | **Behind** |
| 9 | First-run pages to pass | Debian, 0 | 0 | Level |
| 10 | Windows and notices not asked for at first sign-in | Fedora, Debian: 1 modal prompt | 1 window (Firefox, 1 tab), 0 notices | Level |
| 11 | Failed units | 0 (all three) | 1 | **Behind** |
| 12 | Telemetry | Ubuntu and Debian ask, default off; Fedora default on | four packages removed; `ubuntu-insights` and the Pro client's timers remain | Level |
| 13 | Services listening on all interfaces | Ubuntu: none beyond localhost | SSH, Hub, Traefik, Ollama (the `ufw` service is active; its rules were not read) | **Behind** |
| 14 | Says what the machine is doing after the install | nobody does | notifications, "step n of 7" | **Ahead** |
| 15 | Idle blank and lock | all: 5 minutes, then locked | the same | Level |
| 16 | Languages in the first list | Debian, 77 (Ubuntu and Fedora not counted) | 59 locales of 8 languages, behind a button | **Behind** |
| 17 | Look of the installer and first-run pages | Fedora and Ubuntu: branded, illustrated pages | small unbranded GTK dialogs; Canonical's window first | **Behind** |
| 18 | The installed clock | Ubuntu and Fedora detect the zone; Debian asks | `Etc/UTC` after "detected automatically" | **Behind** |
| 19 | The end of the install | a "done" page with the next step (all three) | the machine powers off; the progress text says to remove the stick | not scored (by design for a stick) |

**Ahead on 2, level on 6, behind on 10, one not scored.** Every verdict rests on a frame or a record of the same evening; rows 4, 5 and 7 are one run each, so their size is **[I]**.

## Gaps, ranked by what the best installers do

The order is: seen by every user at every install, then how many of the three stock installs do better, then the cost. The "Item" column is the number in
`proposals/companion-os-home-lab-polish.md` (CI-Engineering); **N1 to N5** are new.

| Rank | Gap | What the best do | Companion OS today | Item | Effort |
|---|---|---|---|---|---|
| 1 | **Two installers at once.** Canonical's window, with Ubuntu's name and logo, opens in front of Companion's dialog | one installer, or none until the user asks (Fedora: a dialog with "Install" and "Not Now") **[V]** | Canonical's 13-page window in both boot entries, the dialog behind it, two launchers **[V]**. The owner's request of 2026-10-19 ("hide the parts of the Ubuntu wizard") is this gap: pull request 88 hides Canonical's window (with the Pro prompts, the telemetry and a dark green theme) and was seen in a virtual machine, where the dialog is the only window and the plain boot entry opens nothing | 5 | M |
| 2 | **A password to copy, then three to type.** The one-time password has to be written down, typed at the greeter, then replaced twice | the user picks the name and the password during setup and has nothing to remember (all three) **[V]** | one-time password in a dialog ("write it down now"), typed at the greeter, then the forced change **[V]** | 6 | M |
| 3 | **A failed unit at every start** on an arm64 machine that is not a Snapdragon | none: `running` on all three **[V]** | `pd-mapper.service` fails, the system reads `degraded`, `ci-os-info` says "1 failed service(s)" **[V]** | 7 | S |
| 4 | **The clock is wrong.** The dialog promises "time zone: detected automatically" and the installed system is on `Etc/UTC` | Ubuntu (geoip) and Fedora (location) found the host's zone on the same machine, Debian asks from a list **[V]** | `Etc/UTC` after the default install, so every clock outside UTC is off by hours at the first sign-in **[V]**, one run; the zone chosen by hand did arrive (`b124745`). Cause not looked for | N1 | S to M |
| 5 | **Services listening on all interfaces.** Not seen in the first ten minutes, but the one gap here that is a risk and not a look | Ubuntu: nothing beyond localhost; Fedora: a firewall and two ports; Debian: SSH only **[V]** | SSH, Hub, Traefik and an unauthenticated Ollama listen on all interfaces **[V]**; the `ufw` service is active and its rules were not read, so whether the LAN can reach them is **[N]** (the CI-Engineering proposal, tier 2, says it can) | 8 | M, needs a human reviewer |
| 6 | **No sense of progress for 11 minutes** | Fedora: four named stages with marks, a percentage, the current step; Debian: the current package **[V]** | one text block and a bar with no percentage **[V]** | N2 | S to M |
| 7 | **Plain, unbranded dialogs.** The Companion look is on the wallpaper only | branded, illustrated pages with one idea each (Fedora, Ubuntu) **[V]** | a small stock GTK dialog with a table, a progress dialog, GNOME's notifications **[V]**. The owner's request for a dark, green theme lands here | N3 | M |
| 8 | **The install takes 3 times Fedora's, and the live desktop a third longer** | 3:52 for 4.1 GB used; live desktop 1:01 **[V]** | 11:27, and 1:30; 11 GB used on stock Ubuntu, 19 GB after Companion's first boot. Profile before acting; a one-off cost | N4 | M to L |
| 9 | **No "installed" page.** The machine just powers off | a page that says what happened and what to do next (Debian: remove the media; Fedora: exit, and a feedback code) **[V]** | the progress text says to remove the stick and turn the computer on **[V]** | N5 | S |

**What the best installers also do that Companion OS should not copy.** Debian's 20 questions and paragraphs of text; Ubuntu's 13 pages, its Ubuntu Pro page and its
update banner at the first sign-in; Fedora's default-on location services and problem reporting; Debian's software list that ticks no desktop, so that pressing Continue
installs a system without one; the SSH server ticked by default.

**What Companion OS does better and must keep** (the proposal says the same): one page for the install, no first-run wizard, and a notification that says what the machine is doing until it is ready.

## Limits and how to repeat a run

**Limits.**

* One run of each distro, so there is no spread. The host was busy with other sessions (a one-minute load average of 24 at the Fedora start, 23 at Debian, 7 at Ubuntu, 7 at
  Companion OS). The earlier Companion records of the same day differ from this evening's run by tens of seconds (the greeter 50 s against 28 s). A difference of a few seconds means
  nothing; a difference of a factor of two is probably real.
* The Companion OS install target was a file on the SSD, the other three used a RAM disk (the first-boot job needs more room than the RAM disk had).
* The live boot of the stock Ubuntu image **froze once** on a text boot log in the first attempt (the guest idle, no reaction to key or pointer for 4 minutes); the
  second attempt is the run. The Companion OS records of the same day show the same freeze once (`ee4a3b4`), so it is not specific to Companion OS **[I]**; the cause was not looked for.
* Debian's install fetched 1374 packages from a mirror over the host's connection, so its install time depends on the network.
* The question count is this page's definition (pages that wait for the user), not the distros'. Languages were counted by OCR of scrolled frames for Debian only.
* Every guest detected the host's real time zone by itself where it asks (Ubuntu, Fedora); a person elsewhere would see a different map.
* `systemctl --failed` was read once, 5 to 8 minutes after the first sign-in; a unit that fails later is not counted.
* openSUSE was not run (the owner did not approve the download); Linux Mint, Pop!_OS, elementary OS and Zorin were not looked for.
* The streamlining the owner asked for on 2026-10-19 (no Ubuntu Pro prompting, no Canonical telemetry, the Ubuntu wizard hidden, a dark green theme) is a separate change with its own pull
  request (88); this page measures the state before it (`main` at `5d50582`).

**Records.** Text records, the signature checks and the facts script are in [`docs/evidence/2026-10-19-ftue-teardown/`](../evidence/2026-10-19-ftue-teardown/) (`run.txt`
with the times, `events.txt` with every action, `installed-facts.txt`, `SHA256SUMS` per run, `verify-downloads.txt` for the signed lists). The frames are in
[`docs/ui/ftue-teardown/`](../ui/ftue-teardown/). One clip per distro was cut with `lib/make-video.py` and is kept outside the repository, like the raw frames, which show the
account typed in the installers.

**Repeat a run.** Needs Homebrew QEMU, Python 3 with Pillow and `ffmpeg`. The target disk goes on a RAM disk because a file deleted after an hourly Time Machine snapshot keeps its
space until the snapshot expires:

```bash
# 1. the image, checked against the vendor's signed list (verify-downloads.txt shows the commands for Ubuntu, Fedora and Debian)
# 2. a RAM disk for the target (16 GiB), and a disk file on it
DEV=$(hdiutil attach -nomount ram://33554432 | awk '{print $1}') && diskutil erasevolume HFS+ FTUE "$DEV"
/opt/homebrew/bin/qemu-img create -q -f qcow2 /Volumes/FTUE/target.qcow2 64G
# 3. record from before power-on, then start the VM and drive it (CI_VM_DIR must be a short path)
export CI_VM_DIR=$HOME/.cache/ftue-vm/run1 && mkdir -p "$CI_VM_DIR"
T=backends/ubuntu/iso/tests
bash $T/record-frames.sh "$HOME/ftue-frames/run1" 1.5 &
bash $T/boot-arm64-vm.sh start /path/to/the.iso /Volumes/FTUE/target.qcow2
python3 -I $T/lib/qmp-drive.py "$CI_VM_DIR/qmp.sock" click 640 400 1280x800
# 4. after the install: start the disk alone, the way a stick would be removed
bash $T/boot-arm64-vm.sh stop && bash $T/boot-arm64-vm.sh start - /Volumes/FTUE/target.qcow2
# 5. read the facts without OCR: a loopback server on the host, the script from the evidence directory in the guest terminal
#    (curl -s 10.0.2.2:8800/f.sh || wget -qO- 10.0.2.2:8800/f.sh) | sh -s NAME
# 6. one clip, then detach the RAM disk
python3 -I $T/lib/make-video.py out.mp4 --frames "$HOME/ftue-frames/run1" --chapters chapters.txt --clock
hdiutil detach /Volumes/FTUE
```

The stopwatch is read from the frame file names (`f-<epoch>.png`), which are the time the screendump was asked for: the first frame that shows the boot menu is t0, and a state
"appears" at the first frame that shows it.
