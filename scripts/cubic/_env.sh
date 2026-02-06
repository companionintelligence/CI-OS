#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${CUBIC_WORKDIR:="$REPO_ROOT/build/cubic"}"
: "${CUBIC_PROJECT_DIR:="$CUBIC_WORKDIR/project"}"
: "${CUBIC_ISO_BASE_DIR:="$CUBIC_WORKDIR/iso/base"}"
: "${CUBIC_ISO_OUTPUT_DIR:="$CUBIC_WORKDIR/iso/output"}"

: "${UBUNTU_ISO_NAME:="ubuntu-24.04.2-desktop-amd64.iso"}"
: "${UBUNTU_ISO_URL:="https://releases.ubuntu.com/24.04/${UBUNTU_ISO_NAME}"}"
: "${UBUNTU_ISO_SHA256SUMS_URL:="https://releases.ubuntu.com/24.04/SHA256SUMS"}"

: "${CUBIC_STAGING_DIR:="$CUBIC_WORKDIR/staging/ci-os"}"
: "${CUBIC_WAIT_MINUTES:=240}"

export REPO_ROOT CUBIC_WORKDIR CUBIC_PROJECT_DIR CUBIC_ISO_BASE_DIR CUBIC_ISO_OUTPUT_DIR
export UBUNTU_ISO_NAME UBUNTU_ISO_URL UBUNTU_ISO_SHA256SUMS_URL CUBIC_STAGING_DIR CUBIC_WAIT_MINUTES
