# Package repository: status and what a resolute repository would need

Private & Confidential. Property of Lifescope Inc. Do not distribute.

**Status: there is no Companion OS apt repository, and nothing consumes one.** The earlier version of this guide described publishing a signed `noble` (Ubuntu 24.04) repository at `packages.ci.computer`, with `reprepro`, `aptly` and `nginx` recipes, a keyring package and a GitHub Actions publisher. That was a design for packages that were never built, for a release that is retired. It has been replaced by this note; the earlier text is in the git history of this file.

Supported targets: Companion OS on Ubuntu 26.04.1 LTS (resolute) and Companion OS on CachyOS. Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from the tag `pre-retire-multidistro-2026-10-17`). The Plasma edition installs from the Arch and CachyOS repositories with pacman; this note concerns the Ubuntu edition only.

Evidence tags: **[V]** verified on 2026-10-18, **[I]** read from the code and not run, **[N]** not checked.

## What exists

| Item | State |
|---|---|
| The host `packages.ci.computer` | [V] does not resolve from the build machine (`nslookup`: "Can't find packages.ci.computer: No answer"; `curl`: "Could not resolve host"), while `https://ci.computer/` answers HTTP 200 |
| A client template in the image | [V] `backends/ubuntu/chroot/customize-chroot.sh` (Step 10) writes `/etc/apt/sources.list.d/companion-intelligence.list.disabled` with the line `deb [signed-by=/usr/share/keyrings/ci-archive-keyring.gpg] https://packages.ci.computer/ubuntu resolute main` commented out. A test pins that it names `resolute` (`backends/ubuntu/chroot/tests/customize-chroot-checks.sh`) |
| A server helper | [I] `backends/ubuntu/iso/scripts/setup-repository.sh` creates a `reprepro` repository with `Codename: resolute` and an `nginx` site. It needs a GPG key id in `CI_OS_GPG_KEY` and was not run |
| Packages the repository could carry | `ci-os-branding` (built by `backends/ubuntu/iso/scripts/build-packages.sh`; the ISO build does not install it from a repository, see [GDM branding package](gdm-branding-package.md)) and `setup-device` (the headless setup package, built by `backends/ubuntu/headless-package/build.sh`). The other package names the old guide listed (`companion-os-base`, `companion-os-keyring`, `companion-agents`, `companion-memory`, `companion-os-amd-meta`) have no source in the repository |
| A consumer | None. The image installs everything from the Ubuntu archive and the vendors' own repositories (Docker, Tailscale, Cloudflare, GitHub), each pinned by key fingerprint in `core/manifest/tier-b-pins.env`. No enabled apt source points at `packages.ci.computer` |

## What a resolute repository would need

Decisions first (owner to assign; tracked as KI-19 in [known-issues-and-decisions.md](../architecture/known-issues-and-decisions.md)):

1. **Whether it is wanted at all.** What it would host, who runs the server, who signs, and what it replaces (for example, shipping `setup-device` to machines that were not installed from the ISO).
2. **The signing key and its holder.** The release signing key for ISOs is also undecided (KI-12); the repository key should be a separate key with subkeys for daily signing, a stored revocation certificate and an expiry.
3. **Where it is hosted**, and the retention and backup policy.

Then the technical work, in this order:

1. Suite `resolute`, component `main`, architectures `amd64` and `all`. The helper already writes these.
2. A keyring package that installs the public key to `/usr/share/keyrings/ci-archive-keyring.gpg` and the source line to `/etc/apt/sources.list.d/`. Only then enable the template above. `signed-by=` is the right form; never use `[trusted=yes]` and never disable host-key checking in a publisher.
3. Build the packages in an Ubuntu 26.04 environment (the container recipe in [Building on a Mac](building-on-a-mac.md) works), with versions that sort correctly across releases.
4. A publisher that pins the server's host key instead of accepting any key, with credentials in the CI secret store and never in the repository.
5. A test: a fresh Ubuntu 26.04 install adds the source, runs `apt update` and installs a package from it. This test did not exist for the old design either.

A minimal manual start with the existing helper, for a throwaway test server (**[N]**, not run):

```bash
gpg --full-generate-key                                # a dedicated key: RSA 4096, with an expiry
sudo CI_OS_GPG_KEY=<key id> ./backends/ubuntu/iso/scripts/setup-repository.sh /srv/packages.ci.computer
sudo reprepro -b /srv/packages.ci.computer includedeb resolute ./output/packages/ci-os-branding_1.0_all.deb
```

The helper prints the remaining steps (certificate, nginx reload, the client line). Until the decisions above are taken, do not enable the client template and do not point any machine at `packages.ci.computer`.

## Known defects in the files this note refers to

- The standalone `ci-os-branding` package cannot be removed cleanly (its diversion is added in `postinst`, after the package has replaced Yaru's file). This matters before it goes into any repository; see [GDM branding package](gdm-branding-package.md#rollback) and KI-16.

© Companion Intelligence, Lifescope Inc
