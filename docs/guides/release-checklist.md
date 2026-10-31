# Release checklist: gates before a Companion OS ISO is published

Private & Confidential. Property of Lifescope Inc. Do not distribute.

Use this list before an ISO leaves the build machine. There are two supported editions and the gates differ in places, so each gate says what it means for both. **Nothing has been published yet.** Images go to Cloudflare R2 (decided 2026-10-20, [Publishing to R2](#publishing-to-r2)); the signing and naming decisions are still open (see [Open decisions](#open-decisions-that-block-a-release)); this list says what must be true when they are settled.

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
| 14 | Hosted and re-verified | `verify-published.sh --full` against the public URL, then boot the downloaded file | the same |

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

The other inputs of the build and of the workflows (the build image, the actions, the compilers) are pinned as well: [Pinned inputs and how to refresh them](#pinned-inputs-and-how-to-refresh-them).

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

`build-iso.sh --sign` signs `SHA256SUMS` and `MD5SUMS` of the Ubuntu edition with the invoking user's default GPG key; the workflow signs with the `GPG_PRIVATE_KEY` and `GPG_PASSPHRASE` secrets of the `production` environment when the `sign` input is true. The Plasma build writes a `.sha256` and does not sign. For two architectures the file must list **both** images: build each on its own machine, gather the images, `cat SHA256SUMS.amd64 SHA256SUMS.arm64 > SHA256SUMS`, and sign that; `publish-r2.sh` refuses a `SHA256SUMS` that leaves a published image out, and refuses a production release with no good signature. **Who holds the release key and where the public key is published are open decisions** (KI-12). Never commit a private key and never place one in a shell history.

### 14. Hosted and re-verified

Publish to the `dev` channel first ([Publishing to R2](#publishing-to-r2)). Then, from a machine that is not the builder (ideally the one a user will use), run gate 14 as a command: it reads `latest.json` and the version's `manifest.json` from the public URL, compares the served size of every image with the manifest (a `HEAD`), checks that `SHA256SUMS` lists exactly the manifest's hashes and, with `--pubkey`, that `SHA256SUMS.asc` verifies against the **published** public key in a throw-away keyring; with `--full` it downloads every image and checks the sha256 of the bytes (5.6 GB each: this is the check that matters).

```bash
backends/ubuntu/iso/scripts/verify-published.sh --base-url https://dl-dev.ci.computer --version 1.0 --full --pubkey release-public-key.asc
```

Then flash the downloaded file with a raw writer or `ci-stick`, boot it in QEMU and look at the first frames. Only then publish to `production` and announce. The workflow's release step is now a **draft** GitHub release that carries the checksums, the signature, the SBOM and the generated release notes, and no image (a release asset is limited to 2 GiB and an image is 5.6 GB), and only for `publish=production`; a human publishes the draft.

## Publishing to R2

**Evidence.** **[I]** implemented and tested with a stub `aws`, `gpg` and `curl` and a real local HTTP server (`backends/ubuntu/iso/tests/{publish-r2.sh,verify-published.sh,build-in-docker.sh,test_release_manifest.py}`, part of `check-repo.sh`; the workflow passes `actionlint`). **[N]** never run against the real buckets: no R2 credential is configured where this was written, no bucket was written to, and a 5.6 GB multipart upload to R2 has not been seen to finish. The first real run is the `dev` rehearsal at the end of this section.

### Where each thing lives

| What | Where | Why |
|---|---|---|
| The images | R2, the shared buckets `dl-dev` (served at `https://dl-dev.ci.computer`) and `dl-prod` (`https://dl.ci.computer`), under the prefix `os/` | a GitHub release asset is limited to 2 GiB; Companion Capture already publishes its installers to the same buckets under `applet/` |
| `SHA256SUMS`, `SHA256SUMS.asc`, `SBOM.txt`, `manifest.json`, `latest.json` | R2, beside the images | the manifest is what an installer or a download page reads; `latest.json` is written last |
| The checksums, the signature, the SBOM and the release notes | a draft GitHub release (production only), without images | the audit trail and the control plane stay on GitHub |
| The R2 key pair, the release signing key | GitHub **environments** `dev` and `production` | an environment's secrets are visible only to the job that names it, and `production` can require reviewers |
| The workflow | `.github/workflows/build-companion-os-iso.yml`: manual only (`ci-local:gated`), inputs `version`, `arch`, `publish` (`none`, `dev`, `production`), `sign`, `runner_amd64`, `runner_arm64` | the org gates automatic runs because hosted minutes are billed; [`docs/CI.md`](../CI.md) has the `gh workflow run` line |

Keys: `os/<version>/<arch>/companion-os-<version>-<arch>.iso`, `os/<version>/{SHA256SUMS,SHA256SUMS.asc,SBOM.txt,manifest.json}` and `os/latest.json`.

### The two routes, one publisher

**On hardware we own (preferred: no billed minutes).** Build each architecture (the arm64 image natively on an Apple-silicon Mac; the amd64 image on an x86-64 Linux host, which is where a release image should come from, or on the Mac in its arm64 container through Rosetta, as the recipe does; [Building on a Mac](building-on-a-mac.md)), gather the images, sign, publish, verify:

```bash
backends/ubuntu/iso/scripts/build-in-docker.sh --base-iso ~/Downloads/ubuntu-26.04.1-desktop-arm64.iso --version 1.0 --output-dir ./release
# the same with --arch amd64 and the amd64 ISO (on an x86-64 host, or here); copy both images into one directory, then:
cd release && cat SHA256SUMS.amd64 SHA256SUMS.arm64 > SHA256SUMS
gpg --armor --detach-sign --output SHA256SUMS.asc SHA256SUMS            # the release key; production requires this
cd ..
backends/ubuntu/iso/scripts/publish-r2.sh --dir release --version 1.0 --channel dev        # a dry run: no credentials, no network
read -rs R2_SECRET_ACCESS_KEY && export R2_SECRET_ACCESS_KEY                                # and R2_ACCOUNT_ID, R2_ACCESS_KEY_ID: never typed into a command line
backends/ubuntu/iso/scripts/publish-r2.sh --dir release --version 1.0 --channel dev --apply --check-public
backends/ubuntu/iso/scripts/verify-published.sh --base-url https://dl-dev.ci.computer --version 1.0 --full
```

**On a GitHub runner.** `gh workflow run build-companion-os-iso.yml --repo companionintelligence/CI-OS --ref <branch> -f version=1.0 -f arch=both -f publish=dev`. The `plan` job checks the inputs (a production release must be signed), `build` runs one job per architecture (the same container build, `verify-iso.sh` included, the image kept as an artifact for 7 days), and `publish` runs only when asked: it takes the environment of the same name, checks that the secrets exist, builds one `SHA256SUMS` and an SBOM, signs when asked, runs `publish-r2.sh` as a dry run and then for real, and runs `verify-published.sh` (with `--full` for production). `runner_amd64` and `runner_arm64` send a build to a self-hosted runner instead (hosted arm64 runners for a private repository are unverified).

### What the publisher does and refuses

`publish-r2.sh` is a **dry run until `--apply`**. It uses the AWS CLI against R2's S3 endpoint with 64 MB parts, because `wrangler r2 object put` is limited to 315 MB and one object at a time. It uploads the images, then the small files, then `manifest.json`, checks every object's size against the file on disk, and only then writes `latest.json`: a failed upload never leaves "latest" naming files that are not there. It refuses (exit 2, nothing uploaded): bytes that changed after the checksums were made, a `SHA256SUMS` that leaves a published image out, a version that is not in the file names, a version, prefix or bucket that could point elsewhere, a version that already exists (without `--overwrite`), and a production release with no good signature. The credentials are read from `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`, exported to the AWS CLI only inside the script, never printed and never on a command line.

### What is left for the owner

Names only; nothing here was done, and no secret value belongs in a document, a log or a chat.

1. Create the GitHub environments `dev` and `production` for `companionintelligence/CI-OS`; give `production` required reviewers.
2. Create one R2 S3 API token per environment (R2, Manage API tokens), scoped to that environment's bucket, and store `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY` in the environment of the same name.
3. Confirm that `dl-dev.ci.computer` and `dl.ci.computer` are attached as public domains of `dl-dev` and `dl-prod` (Companion Capture's release already assumes it).
4. Decide who holds the release key (KI-12), create it, put `GPG_PRIVATE_KEY` and `GPG_PASSPHRASE` into the `production` environment and publish the public key.
5. Confirm the prefix `os/` on the shared buckets, or change it with `--prefix`.
6. Rehearse on `dev` with a throw-away version (for example `0.0-test1`): run the workflow or the commands above, then `verify-published.sh --full` from another machine, and delete the test objects in the Cloudflare dashboard. Record the run in `docs/evidence/`.

## Pinned inputs and how to refresh them

A tag or a branch can be moved to other code at any time, so every input that a workflow or the image build fetches by name is pinned to
what was reviewed: an action to the full commit sha of a release, an image to the digest of its image index, a compiler to an exact
version. `core/lib/check-guards.sh`, part of `check-repo.sh`, refuses an action reference that is not pinned that way **[V]** (its test is
`core/lib/tests/guards.sh`). The values below were read from GitHub, the Rust release channel and the registry on 2026-10-31 **[V]**; no
workflow has run with them yet, because all four are manual-only **[I]**.

| Input | Where | Pinned to | Release |
|---|---|---|---|
| `actions/checkout` | all four workflows | `11d5960a326750d5838078e36cf38b85af677262` | v4.4.0 |
| `actions/upload-artifact` | `build-companion-os-iso.yml`, `pr-checks.yml`, `stick-real-iso.yml` | `ea165f8d65b6e75b540449e92b4886f43607fa02` | v4.6.2 |
| `actions/download-artifact` | `build-companion-os-iso.yml`, `stick-real-iso.yml` | `d3f86a106a0bac45b974a628896c90dbdf5c8093` | v4.3.0 |
| `actions/setup-node` | `style-canon-lint.yml` | `49933ea5288caeca8642d1e84afbd3f7d6820020` | v4.4.0 |
| `softprops/action-gh-release` | `build-companion-os-iso.yml`, the draft release | `3bb12739c298aeb8a4eeaf626c5b8d85266b0e65` | v2.6.2 |
| `Swatinem/rust-cache` | `pr-checks.yml` | `d1527c8f67ef9af357290475d4af4b0fab8f12e0` | v2.9.3 |
| `dtolnay/rust-toolchain` | `pr-checks.yml`, `stick-real-iso.yml` | `683b588c487a69d01f6c6ddf40f036ff682cc2c8` | v1 (the action has no release tags; its commit of 2026-10-16) |
| Rust | the `toolchain:` input of those steps | `1.99.1` | the stable release of 2026-10-13 |
| Rust, MSRV | the MSRV step of `pr-checks.yml` | `1.75.0` | `rust-version = "1.75"` in `stick/Cargo.toml` |
| The build image `ubuntu:26.04` | `BUILD_IMAGE` in `build-companion-os-iso.yml` and in `build-in-docker.sh`, the `stick-qemu` job of `pr-checks.yml`, the recipe in `CLAUDE.md`, `README.md` and [Building on a Mac](building-on-a-mac.md#recipe) | `sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c`, the image index (amd64 `sha256:157dc3d6...`, arm64 `sha256:86eb1bc1...`) | the image built on 2026-10-25 (its `org.opencontainers.image.created` label) |
| `rhysd/actionlint` | the command in [Running the tests](running-the-tests.md) | `sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667` | 1.7.12 |

What a pin does not do. The image digest fixes the starting userland of the build container and nothing more: the container then runs
`apt-get update` and installs from the live Ubuntu archive, so the packages of a build are what the archive serves that day. A pinned
compiler can show new `clippy` warnings on the day it is bumped, warnings that a floating one would have shown on a day of its own.

### Refresh a pin

The commands only read; they need `gh`, `git`, `curl` and `python3` (`docker` only for the last line of the first block).

```bash
sha="$(gh api -X GET repos/actions/checkout/commits/v4 --jq .sha)"; echo "$sha"      # the commit the major tag names today (an annotated tag is followed to its commit)
git ls-remote --tags https://github.com/actions/checkout | grep "$sha"               # the release tags on that commit: they give the trailing comment
gh api -X GET repos/dtolnay/rust-toolchain/commits/v1 --jq .sha                      # the toolchain action
curl -fsSL https://static.rust-lang.org/dist/channel-rust-stable.toml | grep -m1 -A1 '^\[pkg.rustc\]'      # the current stable Rust
docker buildx imagetools inspect ubuntu:26.04 | sed -n '1,5p'                        # the image index digest, with Docker
```

Without Docker, the same digest from the registry:

```bash
TOKEN="$(curl -fsS 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/ubuntu:pull' | python3 -c 'import json, sys; print(json.load(sys.stdin)["token"])')"
curl -fsSI -H "Authorization: Bearer $TOKEN" -H 'Accept: application/vnd.oci.image.index.v1+json' https://registry-1.docker.io/v2/library/ubuntu/manifests/26.04 | grep -i docker-content-digest
```

The rules:

- **A bump is its own commit**, with the old and the new release in its message (for example `pins: actions/checkout v4.4.0 to v4.5.0`),
  so that one commit reviews it and one commit reverts it.
- **A new major version is not a pin refresh**: it is new code, reviewed as a change of its own.
- **The sha of an annotated tag is not a commit.** `git ls-remote` prints the tag object on the tag line and the commit on the `^{}`
  line; pin the commit, which is what the `commits/<tag>` call returns.
- Keep the trailing comment that names the release (`# v4.4.0`), and change every place of a row at once:
  `backends/ubuntu/iso/tests/build-in-docker.sh` fails when the workflow's `BUILD_IMAGE` and the script's differ.

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
| Whether the shared R2 buckets and the prefix `os/` are the final home, and the owner steps of [Publishing to R2](#publishing-to-r2) | R2 is chosen (2026-10-20); the environments, tokens and domains are not set up and nothing was ever uploaded | KI-12 |
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
