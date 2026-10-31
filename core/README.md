# core/

Distro-agnostic pieces of CI-OS: things that are true regardless of which base a Companion Intelligence appliance image is built
on. Nothing under `core/` assumes apt, pacman or any other package manager, and nothing under `core/` may depend on `stick/` or on
a backend.

- **`manifest/`**: the single source of truth for "what gets installed" (dev tools, LLM models, services, the CI-Hub deploy) as
  a declarative YAML file (`ecosystem.yaml`, schema `ecosystem.schema.json`), plus a per-package-manager `role-map/` (`apt.yaml`,
  `pacman.yaml`) that translates generic role names into native package names. Every backend reads this instead of hardcoding its
  own tool list. Also here: `model-packs.yaml` and its `model-packs.lock.json` (what a Companion Stick carries; digests are written by
  `ci-stick models lock`, never by hand), `tier-b-pins.env` (key fingerprints and download hashes of the optional tools baked into
  the Ubuntu image) and `licenses.yaml`.
- **`render/`**: turns `vendor/brand/tokens/` + `assets/` into portable rendered artifacts (a GRUB background image, the MOTD,
  mark PNGs, a GNOME-Shell-style gresource) that a backend installs via its own native mechanism. This is where the token to
  colour math lives, once, instead of being reimplemented per backend. `render/inputs/` holds the raw PNG inputs.
- **`lib/`**: distro-portable bash helpers: `theme-lib.sh` (tokens, logging, Plymouth theme writers), `grub-merge.sh`,
  `gpu-detect.sh` (the Strix Halo hardware rule and the data-driven model-fit gate), `ci-os-models.sh` (the OS-side model adapter),
  `ci-hub.sh` (CI-Hub deploy), `vendor-brand.sh` and `check-brand-mirrors.sh` (the brand bundle), and the repository gates
  `check-repo.sh`, `check-untracked-deps.sh`, `retired-names.allow` and `repro-claims.allow`. `lib/tests/` holds the tests of the helpers and
  `release-names.sh`, the names and claims suite of the release tooling.
- **`headless/payload/`**: the captive-portal Wi-Fi onboarding payload: the Flask setup backend, the static portal, the
  hostapd, dnsmasq and nginx configuration, and the systemd units. The payload itself is distro-portable; only the packaging
  wrapper (the Ubuntu `.deb` in `backends/ubuntu/headless-package/`, the CachyOS stager `backends/cachyos/provision/stage-headless.sh`)
  is backend-specific. A change to the payload ships on both editions.
- **`headless/ci_setup/`**: a tested pure-Python library for the redesigned setup flow. It is not wired into any service yet; see
  `docs/architecture/headless-setup.md`.
- **`headless/tests/`**: the payload tests (`payload/run.sh`; the separate, slow `payload/mutation-check.py` is run by hand, `run.sh` does not
  call it) and the `ci_setup` tests (`ci_setup/run.sh --quick` in the gate; without `--quick` it adds the mutation check). The whole map of
  suites is in `docs/guides/running-the-tests.md`.

Supported targets: Companion OS on Ubuntu 26.04 LTS (resolute) and Companion OS on CachyOS.
Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from tag pre-retire-multidistro-2026-10-17).
`backends/arch` is not a target: it is the provisioning engine under CachyOS.

See `docs/architecture/multi-distro-design.md` for how `core/` and the two backends fit together, and
`docs/architecture/supported-targets.md` for the support policy.

## Bumping the brand bundle

`vendor/brand/` is a pinned copy of the `ci-brand` bundle that CI-Common attaches to each `@companionintelligence/tokens` release. A token
change reaches the images through several committed or rendered artefacts, so a bump is more than one command. In order:

```bash
core/lib/vendor-brand.sh <version>          # needs gh and read access to CI-Common releases: downloads and verifies ci-brand-<version>.tar.gz
core/lib/vendor-brand.sh --check            # vendor/brand matches its SHA256SUMS
core/lib/check-brand-mirrors.sh --write     # rewrites the mirrors of the logos and the portal font (assets/logos, the setup portal, ci-os-logo.svg)
core/lib/check-brand-mirrors.sh             # and verifies them
bash core/lib/tests/grub-nearest-color.sh   # the nearest GRUB colour names are derived from the tokens: a token change can move them
```

Then, on an Ubuntu 26.04 host or container with Yaru installed, because the GNOME Shell theme is rebuilt from the tokens:

```bash
backends/ubuntu/iso/scripts/build-gdm-branding-gresource.sh     # rebuilds the committed gnome-shell-theme.gresource; prints a [PROVENANCE] block
bash core/render/tests/gresource-provenance.sh                  # pins the behaviour: the blob rebuilds byte for byte from Yaru 26.04.5.1
```

Update `backends/ubuntu/packages/PROVENANCE-gnome-shell-theme.txt` with the printed input and output hashes, and the token table in
`assets/branding/brand-guidelines.md`. If the nearest GRUB colour moved, the menu colours in `backends/ubuntu/iso/README.md` change with it
(`verify-iso.sh` recomputes them from the tokens and fails on a mismatch). Finish with `./core/lib/check-repo.sh`, one build of each edition and
`verify-iso.sh` (the canon checks need `VERIFY_REQUIRE_CANON=1` on the Ubuntu image). `.github/workflows/style-canon-lint.yml` runs the
CI-Common canon lint plus `vendor-brand.sh --check` and `check-brand-mirrors.sh`; it is manual-only, so start it by hand
(`docs/CI.md`) or run its steps locally. The CachyOS edition renders its brand assets at build time and commits none, so it needs no extra
step beyond the build.
