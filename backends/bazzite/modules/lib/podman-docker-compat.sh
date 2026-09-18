#!/usr/bin/env bash
# backends/bazzite/modules/lib/podman-docker-compat.sh
#
# Thin Docker->Podman adapter so core/lib/ci-hub.sh (genuinely distro-portable,
# read in full and NOT modified for this backend) can run unchanged on
# Bazzite. Per this phase's research ("Docker vs. Podman" — see
# docs/architecture/multi-distro-design.md's Bazzite section and this
# module's own summary in the implementing agent's report): Bazzite ships
# Podman + Distrobox by default and no Docker CE. Layering Docker CE via a
# Containerfile RUN step was considered and rejected — it works, but fights
# the platform's own default tooling and adds image weight the plan's
# bake-vs-first-boot discipline argues against. This backend adapts to
# Podman instead, at the two points core/lib/ci-hub.sh actually needs a
# translation:
#
#   1. The `docker` / `docker compose` CLI itself — ci-hub.sh calls
#      `command -v docker`, `docker compose version`, `docker login`, and
#      `docker compose <profiles> {pull,down,up}`. Podman 4+ ships a native
#      `podman compose` subcommand (auto-detects a compose provider), so a
#      plain name-level shim is sufficient: no flag/output translation is
#      needed, only `docker` -> `podman`.
#   2. The literal `/var/run/docker.sock` bind mounts ci-hub.sh's generated
#      docker-compose.yml hardcodes for both the ci-os-hub and traefik
#      services (so those containers can talk to the engine). Podman's
#      rootful API socket lives at /run/podman/podman.sock, not
#      /run/docker.sock, so that path must exist on the host or the bind
#      mount fails at container start.
#
# Both fixes must survive every subsequent boot, not just the first one
# this module runs on (see docs/architecture/multi-distro-design.md and this
# backend's own CLAUDE.md: /run is tmpfs and is wiped every boot, while /etc
# is the persistent, writable overlay on an ostree/bootc root). So:
#
#   - The `docker` shim is a plain bash function, exported so it is
#     inherited by the `bash core/lib/ci-hub.sh` child process this
#     module's caller execs. It only needs to exist for the lifetime of
#     that one first-boot run (ci-hub.sh's own systemd-generated containers
#     don't re-invoke a `docker` CLI on later boots — only Podman itself,
#     restarting the containers it created, does).
#   - The /run/docker.sock alias is instead declared as a systemd-tmpfiles
#     rule written to /etc/tmpfiles.d/ (writable, persistent). systemd
#     re-applies every /etc/tmpfiles.d/*.conf on every boot via
#     systemd-tmpfiles-setup.service, with no re-run of this script needed —
#     so once written here, the symlink keeps getting recreated forever,
#     including on boots after this module's own marker file already
#     short-circuits it. This module also applies the rule immediately
#     (`systemd-tmpfiles --create`) so the very first-boot ci-hub deploy
#     that sources this file has a working socket path without waiting for
#     a reboot.
#
# NOTE for the sibling image-definition agent (backends/bazzite/image/):
# writing /etc/tmpfiles.d/90-ci-os-podman-docker-compat.conf at first boot
# (below) works, but it is static, device-independent content — it would be
# just as correct, and one fewer moving part, to instead COPY this same
# rule to /usr/lib/tmpfiles.d/ at image build time. This module writes it
# defensively either way, so the two approaches don't conflict (systemd
# merges /usr/lib/tmpfiles.d and /etc/tmpfiles.d; whichever exists wins).
#
# Requires: podman itself is a build-time (image-baked) concern, not this
# module's job — it ships in every Bazzite base image by default.

set -o nounset
set -o pipefail

_ci_os_podman_compat_log() {
    echo "[CI-OS/podman-docker-compat] $*"
}

# ensure_podman_docker_compat — call once, before invoking anything that
# expects a `docker` CLI (e.g. `bash core/lib/ci-hub.sh`) in THIS process
# tree. Idempotent: safe to call more than once in the same run.
ensure_podman_docker_compat() {
    if ! command -v podman >/dev/null 2>&1; then
        _ci_os_podman_compat_log "ERROR: podman not found — cannot provide a docker-compatible CLI. This should never happen on a Bazzite base image; check the sibling image-definition's Containerfile."
        return 1
    fi

    # 1. `docker` -> `podman` shim, exported so a child `bash <script>`
    #    process (ci-hub.sh is invoked that way, not sourced) inherits it.
    #    `docker compose ...` becomes `podman compose ...`; every other
    #    ci-hub.sh call (`docker login`, `command -v docker`) maps 1:1.
    # shellcheck disable=SC2317,SC2329  # invoked indirectly via the exported function
    docker() {
        podman "$@"
    }
    export -f docker

    # 2. Bring up Podman's rootful API socket. Harmless/no-op if the image
    #    already enabled it at build time (RUN systemctl enable
    #    podman.socket) — see this module's coordination note in the
    #    implementing agent's report.
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl enable --now podman.socket >/dev/null 2>&1; then
            _ci_os_podman_compat_log "WARNING: could not enable/start podman.socket — /run/podman/podman.sock may not exist yet; ci-hub deploy may fail to bind-mount it."
        fi
    fi

    # 3. Alias /run/docker.sock -> /run/podman/podman.sock, persistently
    #    (see header). `L+` = create-or-replace symlink; safe to re-run.
    local tmpfiles_conf="/etc/tmpfiles.d/90-ci-os-podman-docker-compat.conf"
    mkdir -p "$(dirname "$tmpfiles_conf")"
    cat > "$tmpfiles_conf" <<'EOF'
# Managed by CI-OS (backends/bazzite/modules/lib/podman-docker-compat.sh) —
# aliases the Docker CLI's conventional socket path to Podman's rootful API
# socket so core/lib/ci-hub.sh's hardcoded /var/run/docker.sock bind mounts
# keep working. Re-applied by systemd-tmpfiles on every boot.
L+ /run/docker.sock - - - - /run/podman/podman.sock
EOF

    if command -v systemd-tmpfiles >/dev/null 2>&1; then
        systemd-tmpfiles --create "$tmpfiles_conf" 2>/dev/null || \
            _ci_os_podman_compat_log "WARNING: systemd-tmpfiles --create failed for $tmpfiles_conf — /run/docker.sock may not exist until next boot."
    fi

    _ci_os_podman_compat_log "Docker-CLI compat established (docker -> podman; /run/docker.sock -> /run/podman/podman.sock)."
    return 0
}
