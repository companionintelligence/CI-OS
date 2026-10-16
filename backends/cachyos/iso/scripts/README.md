# Build scripts: Companion OS (CachyOS edition) ISO

The ISO is the pinned CachyOS live profile (`upstream.lock`) plus the Companion OS overlay (`../overlay/`), built by the
stock `mkarchiso` in a throw-away amd64 container. Upstream is read, never written. Entry point: `build-iso.sh`
(host, bash 3.2, needs only docker).

## Pipeline

1. `build-iso.sh` builds `ci-os-cachyos-builder:<hash>` from `../docker/Dockerfile.builder` if the tag is absent (base image pinned by
   digest, CachyOS key pinned by fingerprint, pacman sandbox switched off only where it cannot start, i.e. under Rosetta).
2. It starts the container `ci-os-cachyos-build` with a per-run work volume and the shared package cache volume, both labelled
   `ci-os.cachyos`; it never removes a container or volume that lacks that label.
3. It streams the repo subset named in `repo-subset.txt` into `/work/repo` (`tar | docker cp -`; no bind mount). This is the
   **working tree as it is on disk**, not a commit: the container has no `.git`. See "Working tree provenance" below.
4. `in-container/10-bootstrap.sh`: `[cachyos]` repo above `[core]` (the generic baseline repo only), key import with a fingerprint
   check, `archiso grub cachyos-keyring git curl` plus `../render-deps.txt`.
5. `in-container/20-build.sh`: fetch the pinned commit and assert id, committer time and `archiso/` tree id; run
   `render-assets.sh` into a staging tree; replay upstream's generators into a *generated layer*; `in-container/apply-overlay.sh`
   merges everything and runs the guards; `in-container/check-owned.sh` checks, from the repositories' file lists, that no package of
   the image ships a file the build adds (a conflict would abort pacstrap 8 minutes in); `mkarchiso -v`; write `.sha256`, `.pkgs.txt`,
   `.build-info`.
6. `build-iso.sh` copies the artifacts out, re-hashes the ISO on the host, prints the SHA256, removes the container and work volume.
   If the build finished but the copy-out did not (a failing `docker cp`, a hash mismatch), the container and the work volume are
   **kept** with the ISO inside, and the `docker cp ci-os-cachyos-build:/work/out/. DIR` command that takes it out is printed. A failed
   build, or a failure before the ISO existed, still removes both. The cleanup trap cannot be aborted half way by a failing log move.
   `--out` is checked before step 1 (nearest existing ancestor must be a writable directory; nothing is created), so an unwritable
   `--out` costs a second, not a build. `--stop-after` writes nothing there and skips the check.

Checking an overlay change without a build: `build-iso.sh --stop-after validate` (about two minutes). The container runs everything
up to `mkarchiso`, which then reads the merged profile in a network-less namespace and must stop at the first database sync: it has
validated the options, printed the image name, label, publisher and boot modes, copied airootfs and applied `file_permissions`.
`--stop-after overlay` stops before the ownership check and mkarchiso. `tests/overlay-engine.sh` needs no Docker at all;
`tests/overlay-engine-container.sh` runs the real pin and the real overlay through `--stop-after overlay`, inspects the merged tree,
exercises `check-owned.sh` on a crafted tree and then does the validate step (Docker and network, about five minutes, manual).

The date in the ISO name, the volume label, the boot UUID and the `CI_OS_BUILD` day comes from `SOURCE_DATE_EPOCH`, which `build-iso.sh`
fixes once per run: the build day by default, `--source-date-epoch pin` for the pinned upstream commit's time (a stable file name for
comparing builds), or an explicit number of seconds. A run that crosses midnight cannot disagree with itself (upstream issue #108).

## Working tree provenance

The tar in step 3 carries every file under the subset directories exactly as it is on disk: an uncommitted edit, an untracked file
and an *ignored* file (a stray `.env`, an editor `.orig`) all ship, and the container cannot tell (`installer/stage-installer.sh` falls
back from `git ls-files` to `find` there, so every file of `core/headless/payload` counts, tracked or not). Only what the tar excludes
(`.DS_Store`, `._*`, `__pycache__`, `*.pyc`, `*.iso`: one list, `CI_TAR_EXCLUDE_PATTERNS` in `lib/common.sh`) never arrives.

- **Before the build** `build-iso.sh` lists every file under the subset that is not exactly what `HEAD` has, by kind: `changed`
  (differs from `HEAD`, staged or not, or deleted), `untracked`, `ignored`. By default it warns (the first 20, then a count) and goes
  ahead; `--require-clean` makes it an error (exit 1, before any docker command); `--allow-dirty` says the build from this tree is
  intended and drops the warning. A `--stop-after` run builds no ISO, so by default it only notes the state. A tree that is not the
  top level of a git checkout (a tarball, a copy inside another repository) is `unknown`, never silently clean.
- **In the build record** (`<iso>.build-info` and `/usr/share/ci-os/iso-build-info` in the image): `REPO_COMMIT`, `REPO_TREE`
  (`clean|dirty|unknown`), `REPO_TREE_CHANGED|UNTRACKED|IGNORED` (counts), `REPO_SUBSET_SHA256` (one digest over what the container
  received), `PAYLOAD_FILES` and `PAYLOAD_SHA256` (the digest of the `sha256  path` list of `core/headless/payload`, also printed in
  the build log), `KERNEL_LINES_SHA256` (the final boot-menu kernel lines; `KERNEL_LINES_CHANGED=1` alone is constant in every real
  build because patch 0002 is marked) and `MIRRORLIST_SHA256` as **computed** from the fetched file, not copied from the lock.
- The `tree digest` in the plan equals the record's `OVERLAY_SHA256`: both are computed over the tar's view of the overlay.

## Layers and precedence (apply-overlay.sh)

upstream `archiso/` < overlay patches < **generated layer** (from `20-build.sh`) < `overlay/files/` < **staging layer** (`render-assets.sh`).

The generated layer is what upstream's `prepare_profile()` would have written, so an overlay file at the same path wins:
`airootfs/etc/{motd,version-tag,edition-tag,environment}`, `etc/pacman.d/cachyos-mirrorlist` (pinned commit, sha256 checked),
`etc/systemd/system/display-manager.service -> plasmalogin.service`, `/dev/null` masks for `cachyos-rate-mirrors.timer` and
`archlinux-keyring-wkd-sync.timer`, and `usr/share/ci-os/iso-build-info` (pins, overlay and staging digests, working-tree provenance,
tool versions, repo db hashes).

## What the overlay authors must know

- **`render-assets.sh`** (optional; `iso/scripts/render-assets.sh`): run with `bash`, environment `CI_OS_STAGING_DIR` (empty dir to fill,
  same shape as `overlay/files`), `CI_OS_REPO_ROOT`, `CI_OS_VERSION`, `CI_OS_BUILD_DAY` (YYYYMMDD), `SOURCE_DATE_EPOCH`. Non-zero exit
  fails the build. It can read only what `repo-subset.txt` copies into the container.
- **`profiledef.append.sh`**: set `iso_name`, `iso_label`, `iso_publisher`, `iso_application` as one-line assignments (the guards evaluate
  those lines). `iso_name`/`iso_label` follow `upstream.lock` (`companion-os-plasma`, `COMPANION_YYYYMM`); none of the four may contain
  "cachy". Every executable under `airootfs` needs a `["/abs/path"]="0:0:755"` entry in `file_permissions`.
- **Patches** (`patches/NNNN-name.patch`, `git apply -p1`, exact context, no fuzz, name order). A patch that changes a `linux`, `initrd`,
  `LINUX`, `INITRD`, `APPEND` or `KERNEL` line of the boot menus (memtest entries included) must carry the line
  `# ci-os: allow-kernel-line-change`. The marker licenses **that patch** and nothing else: guard (a) compares the final profile with
  the state right after the patches, so an overlay file, the staging layer or the generated layer that moves a kernel line is refused
  even though a marked patch exists (the real overlay always has one). The marker does not say *which* line a patch may change;
  `tests/overlay-brand.sh` pins the one real change (the Memtest path).
- **Package-owned paths**: pacstrap aborts on an overlay file that a package also ships (only `backup=` files may be overridden).
  `check-owned.sh` finds those exactly (`--ownership-check error|warn|off`). Guard (b), which runs first and needs no network, is a
  rule of thumb that refuses `/usr/lib`, `/usr/share` (except `/usr/share/ci-os`, `wallpapers/companion*`, `applications/companion-*|ci-os-*`),
  `/usr/bin`, `/usr/sbin`, `/usr/include`, `/etc/xdg`, `/opt`, `/boot` unless `overlay/package-owned-ok.txt` lists the file, or its directory
  with a trailing `/`, as `/absolute/path | justification`. `/etc` is not judged: the build tells.
- `packages.add` / `packages.remove`: one name per line, `#` comments. Removing a package upstream lacks is an error (upstream drifted).
  `syslinux`, `grub` and `mkinitcpio-archiso` must stay.

## Files

| File | Role |
|---|---|
| `build-iso.sh` | host entry point; `--dry-run` prints the plan and runs nothing |
| `repo-subset.txt` | repo paths copied into the container |
| `lib/common.sh` | hashing, lock loading and validation, date helpers, the tar view, git provenance, the `--out` check, and the pin / mirrorlist / key assertions (`ci_check_checkout`, `ci_check_sha256`, `ci_check_key_fpr`; bash 3.2 safe) |
| `in-container/10-bootstrap.sh` | container to build host |
| `in-container/20-build.sh` | fetch, render, generate, merge, mkarchiso, artifacts |
| `in-container/apply-overlay.sh` | the merge and the guards; stand-alone and unit-tested |
| `in-container/check-owned.sh` | exact package-ownership pre-flight (`pacman -F`, the closure of the package list, `.PKGINFO` backup=) |
| `../docker/Dockerfile.builder`, `cachyos-repo-key.asc` | builder image; committed public key of the CachyOS repository |
| `../../upstream.lock` | every pin, and how to bump it |

## The assertions behind `upstream.lock` are functions

`20-build.sh` and `10-bootstrap.sh` do not carry their own `[ a = b ] || die`: they call `ci_check_checkout DIR SHA EPOCH TREE` (commit
id, committer time, `archiso/` tree id, clean checkout), `ci_check_sha256 FILE HASH LABEL` (the fetched mirrorlist) and
`ci_check_key_fpr ASC FPR` (exactly one primary key in the committed key file, and it is the pinned one). `tests/overlay-engine.sh`
part D runs each against a throwaway repository, a temp file or canned gpg output with a wrong value and requires the refusal, and
checks that the call sites (and the key check in `../docker/Dockerfile.builder`, which cannot source `common.sh` at image build time)
still exist, anchored on whole lines and before the thing they guard. A mutation that turns any of them into `true` turns that test red.

## Not pinned

Package versions: the profile installs from rolling repositories and CachyOS has no snapshot service. `.pkgs.txt` and `.build-info`
(tool versions, sha256 of the repo databases the builder synced before `pacstrap`, which syncs again itself) record what was used.
