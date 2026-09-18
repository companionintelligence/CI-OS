# CI-OS Bazzite (Phase 5) — Just recipes for building/testing this image
# locally. Shape follows the real ublue-os convention (image-template /
# bazzite-dx and siblings all ship a justfile like this — nothing here is
# invented): `just build` runs `podman build` against the Containerfile
# using an `.env` for image name/tag/Fedora version, plus a `build-qcow2`
# recipe wrapping `quay.io/centos-bootc/bootc-image-builder` to produce a
# bootable VM disk for local smoke-testing.
#
# Deliberately NOT here: `build-iso` / `build-raw` (bootc-image-builder can
# produce those too, and other ublue-os justfiles do ship them) — ISO/
# install-media building is explicitly OUT OF SCOPE for this backend (see
# docs/architecture/multi-distro-design.md and the Containerfile's own
# header): Bazzite's own upstream project already provides ISO/install
# tooling for its base images; this backend's job is the custom
# Containerfile/image definition, not a full custom installer pipeline.
# `build-qcow2` is kept because it's a "does the image I just built actually
# boot" smoke test, not installer media in that sense.
#
# VERIFICATION STATUS (disclosed honestly, not claimed as a full pass):
# `just --justfile build.just --list/--dry-run` was run for every recipe
# (valid syntax, correct recipe dependency wiring, `.env` dotenv-loading
# confirmed to actually override `image_name`/`default_tag`, not just parse).
# `render` was actually EXECUTED for real — both staging/*.png files it
# produces exist and were inspected (1920x1080 GRUB PNG, a resized watermark
# PNG). `build`'s `podman build` command itself was NOT run (no local Podman
# machine/Linux VM was running here) — instead, this environment had a
# working Docker Desktop (a real Linux VM, network-connected), which was
# used as a stand-in to `docker build --check` the Containerfile this recipe
# invokes: it parsed cleanly end-to-end, `ghcr.io/ublue-os/bazzite:stable`
# resolved to a real, pullable ~4.7 GiB manifest (now pinned by digest in
# the Containerfile), and every individual RUN instruction's shell was
# syntax-checked with `bash -n`. An actual full `podman build`/`docker
# build` (pulling all layers, running every dnf5/curl/sed RUN step for
# real) was NOT completed — a partial real attempt was started and made it
# through the ~4.7 GiB base-image pull and was mid-way through layer
# extraction (unfinished after several minutes, still on step 1 of 22 at
# that point) before being stopped to stay within this task's time budget;
# it never reached this file's own RUN steps. Treat the package/repo/copr
# commands themselves (the actual `dnf5 install`, `copr enable`, etc.
# calls) as UNVERIFIED beyond static syntax checking — that is the one gap
# no amount of `--check`/`bash -n` can close. `build-qcow2` was not
# exercised at all (it depends on `build` having produced a real local
# image first).

set dotenv-load := true

# Repo root is three levels up from backends/bazzite/image/ (same depth
# every other backend's scripts compute REPO_ROOT from) — `just` runs
# recipes with cwd set to this justfile's own directory, so relative paths
# below are relative to backends/bazzite/image/.
repo_root := "../../.."

image_name := env_var_or_default("IMAGE_NAME", "ci-os-bazzite")
default_tag := env_var_or_default("DEFAULT_TAG", "latest")

# List available recipes.
default:
    @just --list --justfile {{ justfile() }}

# Render the token-derived raster artifacts that DON'T depend on anything
# this image installs (see the Containerfile's own header for why these two
# specifically are staged on the host rather than rendered in a build
# stage, and why the Plymouth theme's *color config* is NOT staged the same
# way): the GRUB background PNG (via core/render/render-grub-background.sh,
# completely unmodified) and the Plymouth watermark (a plain 50%-scale
# ImageMagick resize of the canon logo banner — mirrors
# backends/ubuntu/desktop-theme/10-plymouth.sh's inline
# WATERMARK_SCALE_PERCENT=50 logic without editing that file; no dedicated
# core/render/*.sh script exists for this one-call transform).
#
# Needs the same image tools every other backend's live theming step
# already needs on its target system (rsvg-convert or ImageMagick) — just
# run once here, on the build machine, instead of once per booted
# appliance.
render:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p staging
    bash {{ repo_root }}/core/render/render-grub-background.sh "$(pwd)/staging/ci-os-grub-bg.png"
    src="{{ repo_root }}/core/render/inputs/Logo_Banner_Color.png"
    dst="staging/plymouth-watermark.png"
    if command -v convert >/dev/null 2>&1; then
      convert "$src" -resize 50% "$dst"
    elif command -v magick >/dev/null 2>&1; then
      magick "$src" -resize 50% "$dst"
    else
      echo "Neither ImageMagick 'convert' nor 'magick' found — cannot render the Plymouth watermark." >&2
      exit 1
    fi

# Build the image with Podman. Depends on `render` so staging/ is always
# fresh before the Containerfile's COPY steps read from it.
build tag=default_tag: render
    podman build \
      --tag "{{ image_name }}:{{ tag }}" \
      --file Containerfile \
      {{ repo_root }}

# Produce a bootable qcow2 VM disk from the image just built, via
# bootc-image-builder — the standard ublue-os pattern for "does this
# actually boot" local smoke-testing, not installer media (see this file's
# header for the ISO/raw scope boundary). Needs a local Podman with access
# to /var/lib/containers/storage (bootc-image-builder inspects the image by
# storage path, not by pulling it again) and --privileged, per
# bootc-image-builder's own documented invocation.
build-qcow2 tag=default_tag: (build tag)
    mkdir -p output
    podman run --rm -it --privileged \
      --pull=newer \
      --security-opt label=type:unconfined_t \
      -v ./output:/output \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      "${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}" \
      --type qcow2 \
      --local \
      "{{ image_name }}:{{ tag }}"

# Remove staged render output and local build output.
clean:
    rm -rf staging output
