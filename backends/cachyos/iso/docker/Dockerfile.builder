# check=skip=InvalidDefaultArgInFrom,SecretsUsedInArgOrEnv
# (BuildKit lint: BASE_IMAGE has no default ON PURPOSE, see below; the key fingerprint is public.)
# Builder image for the Companion OS (CachyOS edition) ISO.
#
# build-iso.sh builds this as ci-os-cachyos-builder:<hash> (the hash covers this file, the key file and the two build
# arguments, so any change here or in upstream.lock's BASE_IMAGE / CACHYOS_KEY_FPR yields a new tag). By hand:
#
#   . backends/cachyos/upstream.lock
#   docker build --platform linux/amd64 --build-arg BASE_IMAGE="$BASE_IMAGE" --build-arg CACHYOS_KEY_FPR="$CACHYOS_KEY_FPR" \
#       -f backends/cachyos/iso/docker/Dockerfile.builder -t ci-os-cachyos-builder:dev backends/cachyos/iso/docker
#
# BASE_IMAGE has no default on purpose: it is the digest-pinned official archlinux image from upstream.lock, and a build
# without it must fail instead of silently taking archlinux:latest. The image is amd64 only (Rosetta on Apple silicon).
#
# What this layer stack adds to the stock image, and only that:
#   1. pacman's seccomp download sandbox is switched off IF AND ONLY IF it fails here. Rosetta cannot install the filter
#      ("error restricting syscalls via seccomp: 22!"); on a native x86-64 host nothing is changed.
#   2. The archiso toolchain (archiso pulls squashfs-tools, libisoburn, mtools, dosfstools, arch-install-scripts), grub
#      (NOT a dependency of archiso, and mkarchiso refuses the uefi.grub boot mode without it), git and curl.
#   3. The CachyOS repository key, from the committed armoured copy, imported only after its fingerprint equals the pin, then
#      locally signed. pacstrap verifies [cachyos] packages with the builder's keyring, not the profile's.
# What it does NOT add: the [cachyos] repository, cachyos-keyring and the render dependencies. in-container/10-bootstrap.sh
# does that at build time, idempotently, and works on a bare archlinux container too. Package versions are whatever the Arch
# mirrors serve on the day the image is built (the base image digest pins the image, not the repositories); the
# versions that built an ISO are recorded in its .build-info.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG CACHYOS_KEY_FPR
COPY cachyos-repo-key.asc /usr/share/ci-os/cachyos-repo-key.asc

# (1) The shipped pacman.conf has two [options] headers; the option goes under the first one only.
RUN set -eu; \
    out="$(pacman -Sy 2>&1 || true)"; \
    case "$out" in \
      *seccomp*) opt=DisableSandboxSyscalls ;; \
      *landlock*) opt=DisableSandboxFilesystem ;; \
      *) opt= ;; \
    esac; \
    if [ -n "$opt" ] && ! grep -q "^${opt}\$" /etc/pacman.conf; then \
      awk -v o="$opt" '{ print } /^\[options\]$/ && !d { print o; d = 1 }' /etc/pacman.conf > /tmp/pacman.conf.new; \
      cat /tmp/pacman.conf.new > /etc/pacman.conf; rm -f /tmp/pacman.conf.new; \
    fi; \
    pacman -Sy

# (2) -Syu first: archiso needs current libraries and the base image is a snapshot.
RUN set -eu; \
    pacman -Syu --noconfirm --needed archiso grub git curl python python-yaml; \
    pacman-key --init; \
    pacman-key --populate archlinux; \
    rm -rf /var/cache/pacman/pkg/*

# (3) Refuse any key but the pinned one: the primary fingerprint of the file must equal the build argument.
RUN set -eu; \
    test -n "$CACHYOS_KEY_FPR"; \
    got="$(gpg --batch --show-keys --with-colons /usr/share/ci-os/cachyos-repo-key.asc | awk -F: '$1=="pub"{p=1;next} p&&$1=="fpr"{print $10; exit}')"; \
    test "$got" = "$CACHYOS_KEY_FPR"; \
    pacman-key --add /usr/share/ci-os/cachyos-repo-key.asc; \
    gpg --homedir /etc/pacman.d/gnupg --batch --with-colons --fingerprint "$CACHYOS_KEY_FPR" \
      | awk -F: -v f="$CACHYOS_KEY_FPR" '$1=="fpr" && $10==f {ok=1} END{exit !ok}'; \
    pacman-key --lsign-key "$CACHYOS_KEY_FPR"

WORKDIR /work
CMD ["bash"]
