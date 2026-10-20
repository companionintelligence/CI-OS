# Building Companion OS on a Mac (Apple silicon)

Private & Confidential. Property of Lifescope Inc. Do not distribute.

This guide is for building and testing both Companion OS editions on an Apple-silicon Mac with Docker Desktop. It records what works, what breaks, and the recoveries that were needed in the October 2026 sessions. The general build instructions are in the [ISO build guide](iso-build-guide.md); the QEMU side is in [Testing in QEMU](testing-in-qemu.md).

Evidence tags used below: **[V]** verified in a session (command run, result seen), **[I]** read from the code or documentation and not run, **[N]** not checked.

## What a Mac can and cannot do

| Task | Mac with Docker Desktop | How |
|---|---|---|
| Build the Ubuntu 26.04.1 edition ISO | Works, in a privileged **arm64** `ubuntu:26.04` container (12 min 52 s in the first run) | [Ubuntu edition](#ubuntu-edition-an-arm64-ubuntu2604-container) |
| Build the CachyOS (Plasma) edition ISO | Works, under Rosetta (the builder image is amd64) | [Plasma edition](#plasma-edition-the-builder-script) |
| Run `core/lib/check-repo.sh` | Works on stock macOS (bash 3.2) with a few brew tools | [Host tools](#host-tools-and-the-bash-32-rule) |
| Boot an x86-64 ISO | Works, slowly: QEMU TCG only (no KVM, no HVF for another ISA) | [Testing in QEMU](testing-in-qemu.md) |
| Run the Stick QEMU suite (`stick/tests/qemu/run.sh`) | Works in a privileged Linux container, because the script needs Linux tools (`sgdisk`, `mkfs.exfat`, `grub-mkstandalone`, `apt-get`, `dpkg-deb`); the recorded run was in an ARM64 `ubuntu:26.04` container (17 PASS lines) | [Running the tests](running-the-tests.md#running-the-stick-qemu-suite-on-a-mac) |
| Run the Secure Boot A, B, C harness (`stick/tests/secureboot/run-on-mac.sh`) | Needs Homebrew QEMU and Docker. Its build half runs in an amd64 `ubuntu:26.04` container and stops at a tar preflight if that container fails (below). The recorded A, B, C run passed (8 checks, `RESULT: PASS`) | [stick/README.md](../../stick/README.md) |
| Build a release ISO | Not recommended. The CachyOS edition records "release builds belong on x86-64" (risk R10 in [cachyos-backend.md](../architecture/cachyos-backend.md)) | [Release checklist](release-checklist.md) |

## Host requirements

| Item | Value | Evidence |
|---|---|---|
| Docker Desktop with Rosetta emulation for amd64 enabled | Docker Desktop 29, macOS 27 in the sessions. The setting is "Use Rosetta for x86_64/amd64 emulation on Apple Silicon" in this version; check the wording in yours | [V] Rosetta and QEMU binfmt entries were present in the Docker VM (see [binfmt registrations](#never-run-systemd-as-pid-1-in-a-privileged-container)) |
| Free space on the Data volume | **At least 40 GiB at all times**, more than 120 GiB comfortable | [V] two Docker Desktop wedges, see [Time Machine](#time-machine-local-snapshots-pin-disk-space) |
| Disk for one Ubuntu build | 35 GB in the Docker volume (`backends/ubuntu/iso/README.md`), plus the 1.4 GB Ollama tarball cache | [I] |
| Disk for one CachyOS build | 25 GiB (header of `backends/cachyos/iso/scripts/build-iso.sh`), plus a 2.5 GiB pacman cache volume kept between builds | [I] |
| Docker memory | The CachyOS build defaults to `--memory 16g`; `mksquashfs` peaks near 8 GiB | [I] |
| QEMU | Homebrew `qemu-system-x86_64` 11.1.2 (`brew install qemu`) | [V] |
| `caffeinate` | Wrap runs of tens of minutes in `caffeinate -i` so the Mac does not sleep half way through `mksquashfs` | [I] |

Do not restart Docker Desktop on a shared machine without asking: other containers (a running Hub, test stacks) go down with it.

## Ubuntu edition: an arm64 ubuntu:26.04 container

`build-iso.sh` stops unless the host is Ubuntu 26.04 (`check_build_host`, `backends/ubuntu/iso/scripts/build-iso.sh`), and it must run as root with loop mounts, overlayfs, `mknod` and `chroot`. On a Mac that means a privileged Ubuntu 26.04 container.

### Why arm64

The route that produced the first Ubuntu 26.04.1 Companion OS image is an **arm64** `ubuntu:26.04` container: the container itself runs natively, and the image's customization steps run x86-64 programs in a chroot of the ISO's root filesystem through the Rosetta (or QEMU) binfmt handlers of the Docker VM, so the registrations must be intact (see below). [V] The build finished with exit status 0 in 772 seconds.

An **amd64** `ubuntu:26.04` container is less predictable on this stack, and the trigger was not isolated:

- [V] On 2026-10-17, in the container of `stick/tests/secureboot/build-in-container.sh` (Docker Desktop 29 with Rosetta, macOS 27), GNU tar 1.35 of 26.04 failed to create anything inside a directory it had just created (`Cannot mkdir ... Cannot open: Function not implemented`), so `dpkg-deb -x` failed. The same tar in an amd64 `ubuntu:24.04` worked; bsdtar and Python `tarfile` worked in 26.04; `--privileged` and `seccomp=unconfined` did not help. That script runs a tar preflight and stops with this explanation.
- [V] On 2026-10-18, on the same machine, an amd64 `ubuntu:26.04` container started by `backends/ubuntu/iso/tests/installed-boot.sh` (its process list showed `/run/rosetta/rosetta` as the interpreter) installed packages with apt without error.

So treat amd64 26.04 containers as "may fail with ENOSYS from tar" and use the arm64 recipe for the ISO build. If you must use amd64, run the tar preflight of `build-in-container.sh` first.

### Recipe

Use a **clean copy** of the repository, not your working directory. The working directory may hold gigabytes of ignored build output (`stick/target`, `stick/tests/secureboot/out`), and the build writes into `backends/ubuntu/packages` and `core/render`.

Status: steps 4 to 9 are the commands of the first 26.04.1 build and its verification: **[V]** the build exited 0 after 772 seconds and `verify-iso.sh` reported 393 passed, 0 failed after 34 seconds (details in [test-evidence.md](../architecture/test-evidence.md#ubuntu-2604-image-build-and-static-verification)). Steps 2, 3 and 10 are the recommended wrapping and were not run in exactly this form (**[I]**).

```bash
# 1. Variables: adjust the two paths.
export ISO="$HOME/Downloads/ubuntu-26.04.1-desktop-amd64.iso"
export BUILD="$HOME/ci-os-build-tree"

# 2. The base ISO must be the 26.04.1 file (the 26.04 directory also lists the 26.04.0 image).
echo '601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f  '"$ISO" | shasum -a 256 -c -

# 3. A clean tree of the commit you want to build.
rm -rf "$BUILD" && mkdir -p "$BUILD" && git archive HEAD | tar -x -C "$BUILD"

# 4. A privileged ARM64 container with a named volume for the work, output and cache.
docker volume create ci-os-ubuild-vol
docker run -d --name ci-os-ubuild --privileged --platform linux/arm64 \
  -v ci-os-ubuild-vol:/vol \
  -v "$BUILD":/src:ro \
  -v "$ISO":/base/ubuntu-base.iso:ro \
  -w /vol -e DEBIAN_FRONTEND=noninteractive ubuntu:26.04 sleep infinity

# 5. Loop device nodes: a container's /dev only has the loop nodes that existed at start,
#    and `mount -o loop` takes the first free one.
docker exec ci-os-ubuild bash -euc '
  for i in $(seq 0 127); do [ -e /dev/loop$i ] || mknod -m 0660 /dev/loop$i b 7 $i; done
  [ -e /dev/loop-control ] || mknod -m 0660 /dev/loop-control c 10 237'

# 6. Build dependencies (the list build-iso.sh checks for, plus file, mount and util-linux).
docker exec ci-os-ubuild bash -euo pipefail -c '
  apt-get update -qq
  apt-get install -y -qq ca-certificates squashfs-tools xorriso rsync gpg curl cpio zstd \
    initramfs-tools-core imagemagick librsvg2-bin libglib2.0-bin libglib2.0-dev-bin \
    yaru-theme-gnome-shell python3 python3-yaml diffutils mount util-linux file'

# 7. A writable copy of the tree inside the volume (the build writes under backends/ubuntu/packages).
docker exec ci-os-ubuild bash -euc 'mkdir -p /vol/repo /vol/work /vol/out /vol/cache && rsync -a --delete /src/ /vol/repo/'

# 8. Build. Wrap in caffeinate so the Mac stays awake; stdout goes to a log you can tail.
caffeinate -i docker exec -e CI_OS_CACHE_DIR=/vol/cache -w /vol/repo ci-os-ubuild \
  ./backends/ubuntu/iso/scripts/build-iso.sh \
  --base-iso /base/ubuntu-base.iso --output-dir /vol/out --work-dir /vol/work \
  --version 1.0 --clean 2>&1 | tee build.log

# 9. Verify inside the same container. VERIFY_BASE_ISO makes the Secure Boot binaries, the kernel
#    block and the volume id checks compare against the stock ISO; VERIFY_REQUIRE_CANON=1 fails the
#    run if the brand checks that need the repository checkout could not run.
docker exec -e VERIFY_BASE_ISO=/base/ubuntu-base.iso -e VERIFY_REQUIRE_CANON=1 -w /vol/repo ci-os-ubuild \
  ./backends/ubuntu/iso/scripts/verify-iso.sh /vol/out/companion-os-1.0-amd64.iso

# 10. Copy the result out and remove the container and volume.
mkdir -p output && docker cp ci-os-ubuild:/vol/out/. ./output/
docker rm -f ci-os-ubuild && docker volume rm ci-os-ubuild-vol
```

The root `README.md` and `CLAUDE.md` carry this same block without the comments. The three copies are changed together; if they disagree, this guide is the one that was run. [The script](#the-script) below does the same in one command.

Notes on the recipe:

- The work directory must live **inside the container** (the named volume). A macOS bind mount cannot hold device nodes, root ownership, extended attributes or names that differ only by case, and overlayfs needs a real filesystem under its upper directory. This is the same reason `.github/workflows/build-companion-os-iso.yml` bind-mounts the workspace from the runner's disk, never the container layer.
- `build-iso.sh` needs network access: apt inside the image, Docker's, Tailscale's, Cloudflare's and GitHub's apt repositories, the Ollama release tarball and the Companion Launcher `.deb`. Every key fingerprint and hash is pinned in `core/manifest/tier-b-pins.env` and a mismatch fails the build.
- To skip the optional 1.5 GB of Ollama CUDA libraries, add `-e CI_OS_OLLAMA_CUDA=none` to the build `docker exec`. The size matters because a 64 GB Stick has an 8 GiB boot slot (see [Size](iso-build-guide.md#size-and-the-stick-boot-slot)).
- To resume after an interruption, run step 8 again without `--clean`: the chroot of the previous run is reused and every customization step is written to be repeat-safe.

### The script

`backends/ubuntu/iso/scripts/build-in-docker.sh` is this recipe as one command (**[I]**: its command sequence is tested against a stub `docker`; the recipe above is the part that was run):

```bash
backends/ubuntu/iso/scripts/build-in-docker.sh --base-iso "$ISO" --version 1.0 --output-dir ./output      # the host's own architecture (arm64 on an Apple-silicon Mac); add --arch amd64 and the amd64 ISO for the x86-64 image
backends/ubuntu/iso/scripts/build-in-docker.sh --base-iso "$ISO" --dry-run                                # print every docker command, run nothing
```

It differs from the steps above in a few ways. It **refuses** a dirty working tree (a build comes from a commit; `--allow-dirty` builds the commit without your changes), a base ISO whose sha256 is not the pin of the architecture, an arm64 image on an x86-64 host (qemu-user binfmt, never tried; `--allow-emulated`, not for a release image), and a missing or stopped Docker. **The container is always the host's own platform**, as in the recipe: on an Apple-silicon Mac `--arch amd64` builds the x86-64 image in the arm64 container, whose chroot runs x86-64 programs through the Docker VM's Rosetta binfmt (the route above, [V] 772 s; the script itself built the amd64 image of `66ff6e8` in 1,142 s on a loaded host and `verify-iso.sh` passed 454, failed 0: [`docs/evidence/2026-10-20-ubuntu-amd64-66ff6e8-build/`](../evidence/2026-10-20-ubuntu-amd64-66ff6e8-build/run.txt)), never in an amd64 container; the script says so, and prints a hint about the binfmt handler if such a build fails. A release image comes from an x86-64 host. It names the container and the volume with the process id, so two builds never collide (the fixed names of the recipe would remove a build that is running). It keeps the downloaded tier B tools in a volume between builds (`--cache-volume`). It writes `build-in-docker-<arch>.log`, `verify-iso-<arch>.log` and `SHA256SUMS.<arch>` into the output directory, next to the image (the names the workflow's artifacts use), and removes the container and the volume afterwards (`--keep` leaves them for debugging). The output directory is what `publish-r2.sh` takes: [Publishing to R2](release-checklist.md#publishing-to-r2). Exit codes: 0 built and verified, 1 the build or the verify failed, 2 usage or a missing tool, 3 refused, 4 the container could not be set up. A test keeps its pins and package list equal to the workflow's. Keep more than 40 GiB free where Docker keeps its data.

### Timings

| Run | Time | Evidence |
|---|---|---|
| Ubuntu **24.04.5** edition build in an amd64 container (retired baseline) | about 27 minutes (the v5 build); about 18 minutes for the lighter v3 | [V] session logs, retired |
| Ubuntu **26.04.1** edition build in the arm64 container above (`build-iso.sh --clean`, Ollama CUDA libraries included) | **772 seconds** (12 min 52 s) to a 7,076,577,280 byte ISO. The layer-split self-check ("overlay(B + placeholder + L) == rootfs") took 280 seconds of it | [V] build log, 2026-10-18 |
| `verify-iso.sh` on that image | 34 seconds, 393 passed, 0 failed | [V] |

## Plasma edition: the builder script

The CachyOS (Plasma) edition needs only Docker on the host. `backends/cachyos/iso/scripts/build-iso.sh` runs as a normal user, starts a privileged amd64 `archlinux` container under Rosetta, copies the repository subset into it as a tar stream, builds with stock `mkarchiso`, copies the ISO out and re-checks its hash on the host. The host filesystem is never bind-mounted.

```bash
# Print every input and every docker command, run nothing (docker is not even needed).
backends/cachyos/iso/scripts/build-iso.sh --dry-run

# Fast overlay check (about two minutes, no ISO): merge the overlay and let mkarchiso read the profile with no network.
backends/cachyos/iso/scripts/build-iso.sh --stop-after validate

# The real build. A release build also refuses a dirty tree.
caffeinate -i backends/cachyos/iso/scripts/build-iso.sh --out ./output --require-clean
```

The ISO is built from the **working tree**, not from a commit (the container has no `.git`); the build record next to the ISO says `REPO_COMMIT` and `REPO_TREE` (`clean`, `dirty` or `unknown`). Read the [Plasma build notes](iso-build-guide.md#plasma-edition-cachyos-based) for the outputs and the verifier.

### Rosetta limits for this edition

All [V] in the 2026-10-16 probe, recorded in [cachyos-backend.md](../architecture/cachyos-backend.md#building-on-apple-silicon-rosetta-limits):

- pacman's seccomp download sandbox cannot install its filter under Rosetta (`error restricting syscalls via seccomp: 22!`); the build container disables it only when pacman says it must.
- `--privileged` is the default; `--cap-add SYS_ADMIN` (`--unprivileged`) was proven only for a trimmed profile.
- The `cachyos-v3` repositories do not work under Rosetta (CachyOS's glibc build needs the `faccessat2` system call, which Rosetta lacks), so the live profile stays on the baseline repositories (decision D3). The installed system gets v3 and v4 repositories on the user's own hardware.
- Timings: ISO #4 took 26 minutes from the first line of its log to the last, and ISO #5 took 25 minutes, on a lightly loaded host; of that, installing packages took about 12 minutes and the `mksquashfs` step about 11 minutes with no visible progress (ISO #4 log, 2026-10-18). Earlier, loaded runs took 31 to 37 minutes.

## Docker Desktop hazards

These are the failures that cost time in the sessions. Each has a rule.

### Never run systemd as PID 1 in a privileged container

A privileged container that boots systemd as PID 1 (for example, to test a unit file) **wipes the Docker VM's `binfmt_misc` registrations**, including the Rosetta and QEMU handlers. The amd64 containers and the x86-64 chroot of the Ubuntu build stop working until the registrations come back. [V]: this happened in a session while systemd tests ran in privileged containers; a watcher that polled every 45 seconds found all ten entries missing and re-registered them twice (08:28 and 08:29 on 2026-10-18).

**`CAP_SYS_ADMIN` is not a safe middle way.** With `--cap-add SYS_ADMIN` and the engine's read-only `/proc/sys`, systemd's own `systemd-binfmt.service` stays out, but a container that has the capability can run `mount -t binfmt_misc` itself and gets the **shared** instance, read-write: on Docker Desktop 29.8.2 (kernel 7.0.14-linuxkit, arm64, cgroup v2) the superblock was the VM's own and the `rosetta` and `qemu-*` handlers were listed [V] (measured by the author of commit `f20d3a6`, recorded in the header of the test below). Without the capability the mount is refused (EPERM). So a systemd container gets neither `--privileged` nor `CAP_SYS_ADMIN`.

Rules:

1. Test units with `systemd-nspawn`, a container with no added capability, or a QEMU guest; do not use `--privileged` or `--cap-add SYS_ADMIN` with `/sbin/init`. The reference implementation is `backends/ubuntu/chroot/tests/first-boot-units-boot.sh` (since `f20d3a6`): unprivileged by default (no added capability, the default seccomp profile, `--cgroupns=host`, a tmpfs `/run`), a gate that runs first and refuses if `/proc/sys` is writable or `binfmt_misc` can be mounted, the four binfmt and sysctl units masked in every container, a probe after every boot, and `--selftest` (43 checks, no Docker). Copy its containment block for any new test that needs systemd as PID 1.
2. Before any long job, dump the registrations (read-only; the command enters the Docker VM's namespaces):

```bash
docker run --rm --privileged --pid=host ubuntu:26.04 nsenter -t 1 -m -u -n -i sh -c '
  for f in /proc/sys/fs/binfmt_misc/*; do
    case "${f##*/}" in register|status) ;; *) echo "## ${f##*/}"; cat "$f";; esac
  done' > binfmt-before.txt
grep -E '^##|interpreter' binfmt-before.txt
```

   On the machine of the sessions this listed `arm`, `i386`, `mips64`, `mips64le`, `ppc64le`, `riscv64`, `s390x` and `x86_64` (all QEMU), plus `rosetta` (interpreter `/run/rosetta/rosetta`) and `rosetta-wrapper` (interpreter `/usr/bin/rosetta-wrapper`). [V]
3. Recovery, in order of preference: **restart Docker Desktop**; or re-register the missing entries by writing the entry line to `/proc/sys/fs/binfmt_misc/register` in the same namespaces. The line format is `:name:M:0:<magic>:<mask>:<interpreter>:<flags>`, built from the dump (`flags: POCF` is the flags field, `offset 0` the offset). **Order matters: register `rosetta` after `rosetta-wrapper`**, because the newest entry is matched first and the wrapper alone segfaults amd64 containers (exit 139). Values differ between Docker Desktop versions; take them from your own dump.

### Time Machine local snapshots pin disk space

Local Time Machine snapshots hold on to blocks that Docker and the build freed, so `df` stays low after the volume is cleaned, and Docker Desktop wedged twice at a full disk. Check and thin:

```bash
tmutil listlocalsnapshots /
df -g /System/Volumes/Data | awk 'NR==2 {print $4 " GiB free"}'
# Ask macOS to reclaim up to 100 GB of snapshot space at urgency 4. No sudo was needed in the sessions.
tmutil thinlocalsnapshots / 100000000000 4
```

A guard that ran this every ten minutes while the free space was under 120 GiB kept a long session alive: free space went from 110 GiB to 249 GiB after one thinning, and from 105 GiB to 218 GiB after another (guard log, 2026-10-17 and 2026-10-18). Keep the Data volume above 40 GiB at all times; stop and thin by hand if it falls under 30 GiB. A full 26.04 install in QEMU needs 16 to 20 GB of sparse disk and each Companion ISO is 3 to 8 GB.

### Other limits

- **amd64 `ubuntu:26.04` may fail with a tar ENOSYS** (above). The Secure Boot harness `stick/tests/secureboot/run-on-mac.sh` builds in an amd64 `ubuntu:26.04` container and stops at its tar preflight when that happens. The documented workaround that worked for `fetch-signed-boot.sh` only is an arm64 `ubuntu:26.04` container whose apt is pointed at the amd64 archive through an `APT_CONFIG` file (`stick/README.md`).
- **Docker Desktop's virtual disk** has its own size limit (Settings, Resources). A build that needs 35 GB fails with "No space left on device" when the limit is lower, whatever the Mac has free.
- **Unix socket paths are limited to 104 bytes on macOS.** QMP and guest-agent sockets for QEMU must sit in a short directory such as `mktemp -d /tmp/ci-qmp.XXXXXX`.

## Host tools and the bash 3.2 rule

The repository's checks run on a stock macOS. `core/lib/check-repo.sh` needs bash 3.2+, git, shellcheck, python3 and yamllint, and its tests are written for BSD tools:

```bash
brew install shellcheck yamllint qemu
# PyYAML is needed by the one-click installer's unit tests; use a virtual environment, not the system Python.
python3 -m venv ~/ci-os-venv && ~/ci-os-venv/bin/pip install pyyaml yamllint
PATH="$HOME/ci-os-venv/bin:$PATH" ./core/lib/check-repo.sh
```

The full run takes about six minutes on a loaded host (the payload test `test_hotspot_start.sh` dominates). Rules the suites follow, which new scripts must keep:

- bash 3.2 compatible: no `mapfile`, no associative arrays, no `${var,,}`; arrays are filled with `while read` loops.
- No `\b` in regular expressions used by `git grep` or `grep -E`: BSD regex ignores it silently. Spell the boundary out (`(^|[^A-Za-z])word([^A-Za-z]|$)`).
- No `((n++))` statements: they exit 1 while `n` is 0 and end a `set -e` script. Write `n=$((n + 1))`. The check "no ((VAR++)) statements" enforces it.
- `shasum -a 256`, not `sha256sum`; `stat -f`, not `stat -c`; `sed -i ''` differs from GNU. Scripts that must run in both places test for the tool or avoid the flag.
- Several suites skip themselves on a Mac for want of root, overlayfs, GNU `dd`, `xorriso` or `rsync -AX`; the skip is printed (for example "xorriso is not installed: Part B ... skipped"). Run those parts in the arm64 container.

## Checking an ISO from the Mac

Reading the identity of an ISO needs no extra tools; `bsdtar` and `7z` both read ISO 9660 [V]:

```bash
bsdtar -xOf companion-os-1.0-amd64.iso .disk/info
# 7z e -so companion-os-1.0-amd64.iso .disk/info      (the same, with 7-Zip)
```

A Companion OS image built on 26.04.1 prints a first line that begins `Companion OS 26.04.1 LTS`; the stock base prints `Ubuntu 26.04.1 LTS "Resolute Raccoon"`. A line that mentions 24.04 is a retired baseline and must not be published (see the [release checklist](release-checklist.md)).

## Where to go next

- [Testing in QEMU](testing-in-qemu.md): boot, install and capture the images you just built.
- [Release checklist](release-checklist.md): the gates before an ISO leaves the machine.
- [Running the tests](running-the-tests.md): every suite, and the ones that must not run on Docker Desktop for Mac.
- [Evidence records](../evidence/README.md): where the text records of a build or a boot are kept.
- [Known issues and decisions](../architecture/known-issues-and-decisions.md) and [Test evidence](../architecture/test-evidence.md).

© Companion Intelligence, Lifescope Inc
