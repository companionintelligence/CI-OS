#!/usr/bin/env bash
# gen-ecosystem-json.sh — regenerate ecosystem.generated.json from
# core/manifest/ecosystem.yaml (the single source of truth for "what gets
# installed" — see that file's own header).
#
# WHY THIS EXISTS, AND WHY IT'S NOT run automatically by flake.nix
# ------------------------------------------------------------------
# Every bash backend resolves core/manifest/ecosystem.yaml through its own
# core/manifest/role-map/<pkgmgr>.yaml (apt.yaml, dnf.yaml, pacman.yaml,
# bootc.yaml) — hand-maintained documentation files, not parsed at runtime
# (see any of those files' own header). NixOS's ecosystem.nix instead reads
# STRUCTURED DATA at Nix *evaluation* time via `builtins.fromJSON
# (builtins.readFile ./ecosystem.generated.json)` — see
# docs/architecture/multi-distro-design.md's "The ecosystem manifest"
# section and the Phase 6 research this backend was built from.
#
# ecosystem.yaml itself is YAML, and Nix's evaluator has no built-in YAML
# parser — only `builtins.fromJSON`. Two ways exist to bridge that gap:
#
#   (a) Import-From-Derivation (IFD): a flake.nix `runCommand` derivation
#       invokes `yq` against ecosystem.yaml *during Nix evaluation itself*.
#       This forces a real build before `nix flake show`/`--no-build`
#       checks can even run — nixpkgs's own contribution guidance treats
#       this as something to avoid, not a stylistic nit, and it's the
#       wrong tool for data this module's OPTION TREE (tiers, per-tool
#       defaults) needs at eval time.
#   (b) A committed, regeneratable ecosystem.generated.json, read via plain
#       `builtins.fromJSON (builtins.readFile ...)` — no IFD, no build step
#       at eval time. This is the same manual-regen contract
#       vendor/brand/tokens/tokens.sh already establishes for
#       tokens.sh/tokens.json (tokens.sh's header: "GENERATED from
#       src/tokens.json ... Do not edit"), and it's literally how Nix
#       itself reads flake.lock.
#
# This backend uses (b). THIS SCRIPT is the regen step — run it by hand (or
# from CI) after editing core/manifest/ecosystem.yaml, and commit the
# resulting ecosystem.generated.json alongside that edit. ecosystem.nix
# never invokes this script itself.
#
# WHERE THE OUTPUT LIVES, AND WHY NOT core/manifest/
# ----------------------------------------------------
# The design doc's own prose describes the target as "ecosystem.generated.json"
# without pinning its directory, and every OTHER backend's role-map file
# (apt.yaml, dnf.yaml, pacman.yaml, bootc.yaml) lives under
# core/manifest/role-map/ — core/ content. This backend's build task was
# explicitly scoped to NOT modify core/ file content (backends/nixos/ is a
# new, self-contained backend directory, like every other backends/<distro>/
# tree), so this generated file and its generator script live under
# backends/nixos/manifest/ instead, reading core/manifest/ecosystem.yaml
# read-only. Nothing under core/ is written by this script.
#
# WHAT WAS ACTUALLY VERIFIED FOR THIS PASS
# -------------------------------------------
# `yq` (https://github.com/mikefarah/yq, the Go one — `yq -o=json`) was not
# available in the environment this backend was built in, so
# ecosystem.generated.json was hand-transcribed field-for-field from
# core/manifest/ecosystem.yaml instead of machine-generated for this first
# commit — NOT run through this script even once. Run this script (with a
# real `yq` on PATH) and diff its output against the committed
# ecosystem.generated.json before trusting either is byte-for-byte correct;
# treat that diff as an open TODO from this pass, matching the disclosure
# discipline every prior backend used for its own unverified pieces (e.g.
# Fedora's SELinux/firewalld steps, Arch's ArchWiki-sourced gdm profile).
#
# © Companion Intelligence — Lifescope Inc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SRC="$REPO_ROOT/core/manifest/ecosystem.yaml"
OUT="$SCRIPT_DIR/ecosystem.generated.json"

if [[ ! -f "$SRC" ]]; then
    echo "ERROR: $SRC not found (expected core/manifest/ecosystem.yaml at the repo root)." >&2
    exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: yq not found on PATH. Install mikefarah/yq (the Go rewrite; 'yq -o=json' syntax)," >&2
    echo "       not python-yq / kislyuk's yq, which uses different flags." >&2
    exit 1
fi

# Sanity-check we have mikefarah/yq, not the unrelated python-yq of the same
# name (whose CLI takes different flags and would silently produce wrong
# output or fail confusingly rather than erroring clearly here).
if ! yq --version 2>&1 | grep -qi 'mikefarah\|yq-go\|version v'; then
    echo "WARNING: 'yq --version' didn't look like mikefarah/yq — double-check this is the right yq before trusting the output." >&2
fi

yq -o=json '.' "$SRC" > "$OUT"

echo "Wrote $OUT from $SRC"
echo "Validate the schema separately with core/manifest/ecosystem.schema.json if desired (this script does not do that itself)."
