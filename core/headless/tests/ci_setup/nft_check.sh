#!/usr/bin/env bash
# Opt-in check of the setup firewall against a REAL nftables and a real kernel, inside a throw-away Docker container.
#
#   CI_SETUP_DOCKER=1 core/headless/tests/ci_setup/nft_check.sh
#
# It renders the ruleset with ci_setup.fw and runs nft_packets.py in a container: `nft -c` (syntax and kernel dry run), `nft -f`
# (load), the same again (idempotent), the teardown script (twice), and a packet-level test with a veth pair and a network
# namespace standing in for a phone (see nft_packets.py for what is checked). Nothing is installed or changed on the host.
#
# Environment: CI_SETUP_DOCKER=1 (required: this is not part of run.sh), CI_SETUP_NFT_IMAGE (an image that has nft, ip and python3;
# default archlinux:latest with python3 added from the image's own repositories only if CI_SETUP_DOCKER_INSTALL=1, which needs
# network access; a local image that already has all three needs none). The container gets 2 CPUs and 2 GB, NET_ADMIN and
# SYS_ADMIN, no volumes except this checkout, read-only.
# Needs bash 3.2 or newer. Exit status: 0 all expectations hold, 1 one does not, 2 cannot run here.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
IMAGE="${CI_SETUP_NFT_IMAGE:-archlinux:latest}"

if [ "${CI_SETUP_DOCKER:-0}" != 1 ]; then
  echo "skipped: set CI_SETUP_DOCKER=1 to run the container check" >&2
  exit 2
fi
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "cannot run: docker is not available" >&2
  exit 2
fi

inner='command -v nft >/dev/null && command -v ip >/dev/null || { echo "cannot run: nft or ip missing in the image"; exit 2; }'
if [ "${CI_SETUP_DOCKER_INSTALL:-0}" = 1 ]; then
  inner='command -v python3 >/dev/null || pacman -Sy --noconfirm python >/dev/null 2>&1 || apt-get install -y python3 >/dev/null 2>&1; '"$inner"
fi
inner="$inner"'; command -v python3 >/dev/null || { echo "cannot run: python3 missing in the image"; exit 2; }; exec python3 /work/core/headless/tests/ci_setup/nft_packets.py'

nice -n 10 docker run --rm --cpus 2 --memory 2g --cap-add NET_ADMIN --cap-add SYS_ADMIN \
  -e PYTHONDONTWRITEBYTECODE=1 -e PYTHONPATH=/work/core/headless -v "$ROOT:/work:ro" \
  "$IMAGE" sh -c "$inner"
