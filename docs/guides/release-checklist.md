# Release checklist: gates before a Companion OS ISO is published

Private & Confidential. Property of Lifescope Inc. Do not distribute.

Use this list before an ISO leaves the build machine. There are two supported editions and the gates differ in places, so each gate says what it means for both. **Nothing has been published yet and the hosting, signing and naming decisions are open** (see [Open decisions](#open-decisions-that-block-a-release)); this list says what must be true when they are settled.

Supported targets: Companion OS on Ubuntu 26.04.1 LTS (resolute) and Companion OS on CachyOS (the "Plasma" edition). Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from the tag `pre-retire-multidistro-2026-10-17`).

Related: [ISO build guide](iso-build-guide.md), [Testing in QEMU](testing-in-qemu.md), [Test evidence](../architecture/test-evidence.md), [Known issues and decisions](../architecture/known-issues-and-decisions.md).

## The gates

Run them in order. A failed gate ends the release attempt; fix, rebuild, and start again from gate 2, because every later gate applies to the rebuilt file.

| # | Gate | Ubuntu 26.04.1 edition | Plasma (CachyOS-based) edition |
|---|---|---|---|
| 1 | Source is final and checked | Tagged commit, `./core/lib/check-repo.sh` exits 0 on that tree | the same |
| 2 | Built from a clean checkout | `git archive` tree, build in a 26.04 container or host | `build-iso.sh --require-clean`; build record says `REPO_TREE=clean` |
| 3 | Base input verified | base ISO sha256 equals the pin (601e30fb...da1f) and Ubuntu's signed `SHA256SUMS` | builder image and upstream pin as recorded in the `.build-info`; compat-libs review date not overdue |
| 4 | Static verifier passes | `verify-iso.sh` with `VERIFY_BASE_ISO`: 0 FAIL | `verify-iso.sh` with `VERIFY_REQUIRE_CLEAN=1 VERIFY_REQUIRE_ALL=1`: 0 FAIL, nothing skipped |
| 5 | Size is within limits | at most 8 GiB (a 64 GB Stick slot); section 9 of the verifier | size window of the verifier (1500 to 6144 MB by default) |
| 6 | Installed system boots | `installed-boot.sh --iso ... --strict`, then with `--secure-boot` | full QEMU install of this ISO to a booted desktop |
| 7 | Both install paths work | one-click automatic install and the interactive installer, in a VM | Calamares online install, on a disk of at least 64 GB |
| 8 | First-boot provisioning finishes | `.first-boot-setup-done` exists, no degraded status | the same, and the three models are present |
| 9 | Secure Boot behaves as stated | boots with Secure Boot **on**; `mokutil --sb-state` says enabled | **not supported**: the release notes must say so |
| 10 | Real hardware smoke test | at least one physical x86-64 machine; one Strix Halo-class machine if ROCm is claimed | the same |
| 11 | Brand and content scan | no Ubuntu marks where they are not intended; no credentials or host keys in the image | no CachyOS mark in file names, titles or frames; no credentials in the image |
| 12 | Retired baselines and stale builds excluded | `.disk/info` says 26.04.1, not 24.04 | built on the publication day; gates 4, 6 and 7 rerun the same day |
| 13 | Checksums and signature | `SHA256SUMS` signed by the release key | the same, over both ISOs |
| 14 | Hosted and re-verified | download from the public URL, verify, boot the downloaded file | the same |

## Gate details

### 1. Source is final and checked

```bash
git status --short                                  # must print nothing
git describe --tags --exact-match HEAD              # a release tag
PATH="$HOME/ci-os-venv/bin:$PATH" ./core/lib/check-repo.sh     # about 6 minutes; exit 0
```

`check-repo.sh` includes the retired-name guard, the one-click installer unit tests (`backends/ubuntu/chroot/tests/test_auto_install.py`), the md5sum tests, the CachyOS suites and the setup-portal suites. The last recorded run on the commit set of 2026-10-18 exited 0 ([test evidence](../architecture/test-evidence.md#the-repository-gate)). The four GitHub workflows are gated to manual dispatch, so no remote check runs this for you.

### 2. Built from a clean checkout

Ubuntu edition: build from `git archive`, not from a working directory, in a 26.04 environment ([Building on a Mac](building-on-a-mac.md) for the container recipe, or run `build-iso.sh` as root on an Ubuntu 26.04 host).

```bash
rm -rf /tmp/release-tree && mkdir /tmp/release-tree && git archive HEAD | tar -x -C /tmp/release-tree
```

Plasma edition: the build packs the working tree, so refuse a dirty one:

```bash
backends/cachyos/iso/scripts/build-iso.sh --out ./output --require-clean
```

Keep the files the build writes next to the ISO: `.sha256`, `.pkgs.txt`, `.build-info`, and for the Ubuntu edition `SHA256SUMS` and `MD5SUMS`. Copy the build record, the exit status and the sha256 into a new directory of [`docs/evidence/`](../evidence/README.md) (its README has the commands and the rules: text only, no credentials, no host paths); a release whose build record is only in a scratch directory has no record.

### 3. Base input verified

Ubuntu: the workflow does this for you (signed `SHA256SUMS`, pinned key fingerprint, pinned hash). By hand:

```bash
echo '601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f  ubuntu-26.04.1-desktop-amd64.iso' | shasum -a 256 -c -
```

Take the `.1` file; the 26.04 directory also lists the GA 26.04.0 ISO. A change of the base (26.04.2) is not a one-line bump: follow [Changing the base ISO](iso-build-guide.md#changing-the-base-iso) in the ISO build guide (layer-split table, md5sum convention, signed GRUB module list, initrd shape).

Plasma: read `REPO_COMMIT`, `UPSTREAM_SHA`, `COMPAT_REVIEW_BY` and `COMPAT_REVIEW_OVERDUE` in the `.build-info`. `COMPAT_REVIEW_OVERDUE=1` means the compatibility libraries (`backends/cachyos/compat-libs.lock`, review by 2026-12-01) were not reviewed in time; build releases with `CI_OS_COMPAT_REVIEW=error`.

### 4. Static verifier passes

Ubuntu, in the build container (no root needed, no boot):

```bash
VERIFY_BASE_ISO=/base/ubuntu-base.iso ./backends/ubuntu/iso/scripts/verify-iso.sh output/companion-os-1.0-amd64.iso
```

Plasma, on a Mac in the builder image (see `backends/cachyos/README.md`):

```bash
IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' ci-os-cachyos-builder | head -n 1)"
docker run --rm --platform linux/amd64 --cpus 4 --memory 8g \
  -v "$PWD:/repo:ro" -v "$PWD/output:/iso:ro" "$IMAGE" bash -c '
    VERIFY_REQUIRE_CLEAN=1 VERIFY_REQUIRE_ALL=1 VERIFY_FETCH_UPSTREAM=1 \
    /repo/backends/cachyos/iso/scripts/verify-iso.sh "$(ls /iso/companion-os-plasma-*-x86_64.iso | head -n 1)"'
```

Record the pass count and copy the `verify.log` into the run's directory of [`docs/evidence/`](../evidence/README.md). **Status:** on the first complete Ubuntu 26.04.1 image the verifier reported 393 passed, 0 failed in 34 seconds (2026-10-18, with `VERIFY_BASE_ISO` and `VERIFY_REQUIRE_CANON=1`). No log of a verifier run on Plasma ISO #4 or #5 was kept in the session records. The latest Plasma run is **215 passed, 0 failed on ISO #6** (about 84 s, 2026-10-18; `docs/evidence/2026-10-18-plasma-iso6/verify.log`), then 187 passed, 0 failed on ISO #2 and 182 passed, 1 failed on the first full build. A run on the release candidate is still **required**, not a formality, for both editions.

### 5. Size

The Stick's boot slot is the usable space divided by 10, clamped to 8 to 48 GiB, so a **64 GB stick has 8 GiB (8,589,934,592 bytes)** and a 128 GB stick 11 GiB. `ci-stick flash` refuses an image that does not fit. `verify-iso.sh` section 9 fails an Ubuntu image above 8 GiB (`VERIFY_MAX_ISO_BYTES=<n>` for a build meant for bigger sticks only). The first complete Ubuntu 26.04.1 image, built with every optional tool baked in, is **7,076,577,280 bytes** (6.59 GiB), so 1,513,357,312 bytes are spare in an 8 GiB slot (`verify-iso.sh` section 9). The Plasma ISO is 3,217,129,472 bytes.

### 6 and 7. Boot and install, in a VM

Follow [Testing in QEMU](testing-in-qemu.md). Pass conditions:

- Ubuntu: `installed-boot.sh` exits 0 on the built ISO (static checks pass and the GDM greeter is reached), also with `--secure-boot`; the interactive installer completes an install to an NVMe target and the installed disk boots; the automatic entry ("Install Companion OS (automatic)") completes an install, powers the machine off, and the installed disk boots with the one-time password changed at first sign-in.
- Plasma: Calamares reports `completion: succeeded`, the installed disk boots to the greeter and a desktop, the login works.
- Keep the QEMU command line, the frames and a `CAPTURE.md` for each run, and copy the text records (result files, timelines, serial and installer logs, the sha256 of the image the run used) into [`docs/evidence/`](../evidence/README.md); frames and capture notes go under `docs/ui/companion-os/`.

### 8. First-boot provisioning

On the installed system:

```bash
ls -l /var/lib/ci-os/.first-boot-setup-done       # present when provisioning succeeded once
cat /var/lib/ci-os/first-boot-setup-status        # Plasma edition: must not say "degraded"
sudo journalctl -u ci-os-first-boot-setup --no-pager -n 40
ollama list                                       # the models the manifest names (core/manifest/ecosystem.yaml, llm.models)
df -h /                                           # note the free space after the model pulls
```

On a 30 GiB target the Plasma edition ended at 88 percent used after the models (7.8 GiB before, 26 GiB after); on a 64 GiB target at 42 percent (8.4 GiB before, 27 GiB after). That is why the guides recommend 64 GB. A disk-space guard does not exist yet (known issue KI-01).

### 9. Secure Boot

The Ubuntu edition keeps Canonical's signed chain (shim, GRUB, kernel); `verify-iso.sh` compares the EFI binaries with the stock ISO's under `VERIFY_BASE_ISO`. Static equality is not a boot: boot the built ISO with the Secure Boot firmware and check:

```bash
# in the guest
mokutil --sb-state            # SecureBoot enabled
```

The Plasma edition has no Secure Boot (unsigned GRUB, no shim, unsigned kernels) and cannot be started from the Companion Stick (its boot menu is built for casper). Say both in the release notes. Whether the first batch needs Secure Boot is an open decision (KI-14).

### 10. Real hardware

No physical machine has booted either edition in these sessions. Before the first release, boot each ISO on at least one physical x86-64 machine in UEFI mode and install it. If the notes claim ROCm or the Strix Halo memory settings, test on a Strix Halo-class machine: the unified-memory boot parameters exist only in the Ubuntu edition (KI-03).

### 11. Brand and content scan

```bash
# Frames of a run: no "Ubuntu" where Companion OS belongs, no CachyOS mark anywhere, no host paths.
# Image: no host keys, no .env, no credentials.
bsdtar -tf output/companion-os-1.0-amd64.iso | grep -i -E '\.env|id_rsa|\.pem$' || echo "none found"
```

The Plasma file name, volume label, publisher and application strings must not contain the CachyOS name (`verify-iso.sh` section 1). The About page and `os-release` still say "Plasma (based on CachyOS)" and keep `ID=cachyos` on purpose (decisions D1 and D4). Whether the name may be used in public text is an open decision (KI-13). Review a full frame set of the run: the installed Plasma desktop of ISO #4 showed a CachyOS update notifier that ISO #5 removes, so frames of the release candidate must be looked at.

### 12. Retired baselines and stale builds

Do **not** publish:

- any Ubuntu **24.04**-based image, including the v1 to v7 builds and anything named `companion-os-*-amd64.iso` whose base is 24.04. Check:

```bash
bsdtar -xOf output/companion-os-1.0-amd64.iso .disk/info      # must start "Companion OS 26.04.1 LTS"
# 7z e -so output/companion-os-1.0-amd64.iso .disk/info       # the same with 7-Zip
```

- any image built from a dirty tree, or without gate 4;
- the Plasma test builds #1 to #6 (they were built to find defects; ISO #6 is built from a clean commit and passed the verifier, but it is still a test build, run only in a virtual machine), and any Plasma ISO that is **old**: the edition is a rolling release. The installer fetches current packages on install day and the live image carries the libraries of build day, so an old ISO fails when the repositories move (the boost skew found on 2026-10-18 had existed since 2026-08-13, two months before the first Companion OS ISO was built, and was first exposed when the installer was first launched on a booted ISO; the launcher's message for a key failure tells the person to download a newer ISO). Rebuild on the publication day, rerun gates 4, 6 and 7 the same day, and publish with an expiry note.

### 13. Checksums and signature

```bash
cd output
shasum -a 256 companion-os-1.0-amd64.iso companion-os-plasma-*-x86_64.iso > SHA256SUMS
gpg --armor --detach-sign --output SHA256SUMS.asc SHA256SUMS      # with the release key
gpg --verify SHA256SUMS.asc SHA256SUMS
shasum -a 256 -c SHA256SUMS
```

`build-iso.sh --sign` signs `SHA256SUMS` and `MD5SUMS` of the Ubuntu edition with the invoking user's default GPG key; the workflow signs with the `GPG_PRIVATE_KEY` and `GPG_PASSPHRASE` secrets when the `sign` input is true. The Plasma build writes a `.sha256` and does not sign. **Who holds the release key and where the public key is published are open decisions** (KI-12). Never commit a private key and never place one in a shell history.

### 14. Hosted and re-verified

Publish to a private location first. From a clean machine: download over the public URL, verify the signature and the checksum, flash with a raw writer or `ci-stick`, boot it in QEMU and look at the first frames. Only then announce.

The existing workflow's "Create GitHub Release" step is **not** a safe publisher: it runs on every manual dispatch, creates a release that is not a draft, and uploads files of several gigabytes, while GitHub allows 2 GiB per release asset (the step is expected to fail for an ISO; known issue KI-12). Do not rely on it, and fix it (draft, no ISO upload) before dispatching the workflow for anything but an artifact.

## Stick bundle release

A Companion Stick bundle (`ci-stick lock`) carries an ISO, the signed boot chain and optionally model packs, and is signed with ed25519
([`companion-stick.md`](../architecture/companion-stick.md)). **A bundle cannot be released today**: there is no release key, no signing
command for one and no pipeline (KI-23); `ci-stick dev sign` is for development and tests and must never sign a bundle that leaves the
building. When the key holder is named, the gates for a bundle are, in order:

| # | Gate | How |
|---|---|---|
| S1 | The ISO inside passed gates 1 to 12 above | the bundle's `boot/` ISO is a released ISO, not a development build |
| S2 | The signed boot chain is fetched, not copied | `stick/scripts/fetch-signed-boot.sh ./signed-boot` on Ubuntu 26.04: shim, Canonical GRUB, MokManager from the resolute archive, signatures checked |
| S3 | The bundle is locked | `ci-stick lock ./staging --id companion-stick-ubuntu --version <YYYY.M.N> --size <stick size, for example 64GB> --packs core/manifest/model-packs.yaml` |
| S4 | The model packs are licensed for the media | counsel's answer on the Gemma and Llama terms (KI-24); `ci-stick models fetch` does not gate them yet |
| S5 | **Signed with the release key** | **[N]** no command, key or pipeline exists (KI-23). Record the key id and the date here when they do |
| S6 | Verified with the published public key | `ci-stick verify ./staging --pubkey <release public key>` exits 0 on the bundle as it will be flashed |
| S7 | Flashed and booted | `ci-stick flash ... --dry-run` first, then flash a sparse image and run `stick/tests/secureboot/run-on-mac.sh --iso <the ISO>` or `stick/tests/qemu/run.sh`; a physical stick only with a device the owner named |
| S8 | Recorded | the bundle id, version, the sha256 of `bundle.json` and of the ISO, and the verifier output, in `docs/evidence/` |

The Plasma edition cannot be carried by a Stick (KI-04).

## Open decisions that block a release

| Decision | Why it blocks | Tracked as |
|---|---|---|
| Where ISOs are hosted publicly | the guides point at releases that do not exist; GitHub Releases cannot carry a multi-GB asset | KI-12 |
| Who holds the release signing key | gate 13 cannot be passed without a named holder and a published public key | KI-12 |
| Whether CachyOS may be named in public text | release notes, About page, website | KI-13 |
| Whether the first batch needs Secure Boot | the Plasma edition cannot offer it | KI-14 |
| Roles: build owner, verifier, signer, publisher | a gate needs a person; owner to assign | KI-12 |
| Who holds the `ci-stick` bundle signing key, and the pipeline that signs a bundle | a physical stick cannot be released with a signature a user can check ([Stick bundle release](#stick-bundle-release)) | KI-23 |
| Counsel's answer on redistributing Gemma and Llama models on physical media | `fetch` does not ask for acceptance of those terms | KI-24 |
| A pushed restore tag and a durable bundle of the retired backends | the restore recipe works only on one machine | KI-21 |

## Release record (copy into the release notes)

| Field | Value |
|---|---|
| Edition | Ubuntu 26.04.1 / Plasma |
| File and size | |
| sha256 | |
| Source commit and tree state | |
| Build date and builder | |
| `verify-iso.sh` result (passed / failed / skipped) | |
| Installed-boot or Calamares run (date, result, the `docs/evidence/` directory, where the frames are) | |
| Secure Boot | tested enabled / not supported |
| Real hardware tested | machine and result, or "none" |
| Signed by | key id, date |
| Known issues shipped | list from [Known issues and decisions](../architecture/known-issues-and-decisions.md) |

© Companion Intelligence, Lifescope Inc
