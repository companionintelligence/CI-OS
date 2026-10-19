#!/bin/bash
# ci-os-setup: install the Companion OS tools (Docker, Node.js, Ollama, ...) -- installed as /usr/local/bin/ci-os-setup.
# Usage: sudo ci-os-setup [provision.sh options]      e.g.  sudo ci-os-setup --tier=core,hardware
if [[ $EUID -ne 0 ]]; then
    echo "This command must be run as root: sudo ci-os-setup" >&2
    exit 1
fi
# --manual: run even if setup already completed or the automatic retries are used up.
exec /usr/lib/ci-os/first-boot-setup.sh --manual "$@"
