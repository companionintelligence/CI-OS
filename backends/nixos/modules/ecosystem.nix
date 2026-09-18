# ecosystem.nix — CI-OS NixOS backend, "what gets installed" half.
#
# © Companion Intelligence — Lifescope Inc
#
# NAMESPACE: every option here lives under `services.ci-os.ecosystem.*`,
# sharing the `services.ci-os.*` root with the sibling `branding.nix`
# (`services.ci-os.branding.*`) and `headless-setup.nix`
# (`services.ci-os.headlessSetup.*`) — see backends/nixos/flake.nix's header
# for why this root was chosen (it mirrors how consuming systems already
# read `services.tailscale.*`/`services.ollama.*`).
#
# WHAT THIS FILE IS THE NixOS TRANSLATION OF
# --------------------------------------------
# This is the Nix-module equivalent of backends/fedora/provision/provision.sh
# (read in full as the primary "what needs to exist" reference for this
# module, per this phase's brief) and, for role-map-style data,
# core/manifest/role-map/dnf.yaml / pacman.yaml. Two things are
# fundamentally different here, both deliberate, both documented inline
# where they matter:
#
#   1. There is no `provision.sh` "run once against an existing system"
#      entrypoint. Every option below is a NixOS module option — the
#      consuming flake's own `nixosConfigurations.<host>` decides what's
#      enabled, and `nixos-rebuild switch` (or an image build) makes it so.
#      There is no --tier=/--step= CLI flag; the equivalent is which
#      `services.ci-os.ecosystem.*.enable` options a consumer sets to
#      `true` in their own configuration.
#   2. core/manifest/ecosystem.yaml is still the single source of truth for
#      WHAT gets installed and at which tier, but this backend does NOT
#      hand-maintain a parallel role-map/nix.yaml the way every bash
#      backend hand-maintains role-map/<pkgmgr>.yaml. Instead it reads
#      ../manifest/ecosystem.generated.json (a committed, regeneratable
#      JSON transcription of ecosystem.yaml — see
#      ../manifest/gen-ecosystem-json.sh's header for the full reasoning,
#      including why this is NOT an Import-From-Derivation) via
#      `builtins.fromJSON`, and derives each core/extended-tier tool
#      option's DEFAULT `enable` value from that data — see `tierOf` below.
#      Editing ecosystem.yaml, regenerating the JSON, and rebuilding is
#      therefore enough to change this backend's defaults, the same "one
#      source of truth" property the manifest promises every other backend.
#
# TIER MODEL, ADAPTED FOR NIX'S EVALUATION MODEL
# --------------------------------------------------
# core/manifest/ecosystem.yaml defines four tiers: core (auto-run),
# extended (opt-in), hardware (auto-detected, never flag-gated), reserved
# (not implemented here). `core` and `extended` translate directly: this
# module's master `enable` switch corresponds to "core tier requested" (the
# default when a bash backend's provision.sh runs with no flags is
# `--tier=core,hardware`; the direct analog here is
# `services.ci-os.ecosystem.enable = true;` with nothing else set), and
# `services.ci-os.ecosystem.extended.enable` corresponds to `--tier=extended`.
#
# `hardware` does NOT translate directly, and this is a deliberate,
# disclosed adaptation, not an oversight: every bash backend's hardware
# tier is populated by a RUNTIME probe (core/lib/gpu-detect.sh's
# `is_strix_halo_from_system`, `/dev/kfd` checks, `nvidia-smi`) that
# inspects the machine `provision.sh` is actually running on, right now.
# A Nix module has no equivalent — it is evaluated against the consuming
# flake's own DECLARED configuration, not against live hardware (and
# reaching for real hardware probing at eval time would mean either
# Import-From-Derivation or an impure `builtins.readFile /proc/...`, both
# of which break the reproducibility a flake exists to provide — the exact
# same reasoning ../manifest/gen-ecosystem-json.sh's header gives for
# avoiding IFD on the ecosystem-manifest side). So on this backend, the
# "hardware" tier is instead an EXPLICIT, user-declared opt-in
# (`services.ci-os.ecosystem.hardware.rocm.enable` /
# `.hardware.lact.enable`, both default `false`) — the consuming flake's
# own author is expected to know their own hardware and flip these the same
# way they already declare `hardware.amdgpu.enable` or
# `services.xserver.videoDrivers` in their own configuration. This mirrors
# how nixpkgs itself handles hardware: there is no
# `nixpkgs.config.rocmSupport = "auto"`.
#
# PER-TOOL DISPOSITION (confirmed real Nix module/package vs. documented
# gap — see each option's own comment for the reasoning, this is the
# summary the final report cross-references):
#   REAL nixpkgs package/module: docker (virtualisation.docker),
#     gh (pkgs.gh), cloudflared (pkgs.cloudflared), chromium (pkgs.chromium),
#     vscode (pkgs.vscode — the genuine MS-branded build, CONFIRMED distinct
#     from pkgs.vscodium), tailscale (services.tailscale), ollama
#     (services.ollama, including acceleration), uv (pkgs.uv — CONFIRMED
#     native nixpkgs package, unlike every other backend's curl|sh install),
#     rocm (rocmPackages.* + nixpkgs.config.rocmSupport), lact
#     (services.lact + hardware.amdgpu.overdrive).
#   REIMPLEMENTED AS A NIX-DECLARED SYSTEMD UNIT (not a plain package, since
#     the underlying tool's own install method is a $HOME-writing script,
#     not a distro package): asdf + Node.js 22.15.1 (pinned via asdf, like
#     every other backend, NOT substituted with nixpkgs' generic
#     `pkgs.nodejs` — see `asdfNodejsScript` below for why the version pin
#     specifically motivates keeping asdf here despite Nix having its own
#     Node packages), corepack/pnpm (same unit, chained after asdf).
#   REAL SHADOW-UTILS EQUIVALENT: ci_user -> `users.users.<name>` (NixOS's
#     own declarative user management, the direct analog of
#     `useradd -m ci; usermod -aG docker ci`).
#   REAL, UNMODIFIED SCRIPT WRAPPED IN A SYSTEMD UNIT: ci_hub ->
#     core/lib/ci-hub.sh staged into the Nix store and invoked by-path,
#     never forked — see `ciHubScript` below.
#   DOCUMENTED NO-OP (not a broken/guessed-at option): telemetry_removal
#     (NixOS ships no phone-home telemetry by default — see the bottom of
#     `config` below), homebrew (philosophically redundant on NixOS —
#     package management is Nix's own job; treated the same as every prior
#     backend treats it: tier extended, opt-in, and here specifically not
#     wired to anything).
#   OMITTED ENTIRELY, NOT A no-op OPTION: companion_launcher — per this
#     phase's research, no NixOS/Nix package exists anywhere and
#     dl.ci.computer still ships .deb only, matching every prior backend's
#     finding. An `enable` option a user could flip that silently does
#     nothing is a Nix-specific footgun with no log line the way bash's
#     `install_companion_launcher()` stub prints one — so, per the
#     research's own recommendation, this option is simply not defined
#     here, and the gap is documented in this comment instead, the way
#     nixpkgs itself omits options for platforms a package doesn't support
#     rather than defining a `mkIf`-to-`{}` no-op.
#
# WHAT THIS FILE DELIBERATELY DOES NOT DO
# -------------------------------------------
# It does not configure a desktop environment, GPU driver selection
# (`services.xserver.videoDrivers`, `hardware.graphics.enable`), disk
# partitioning, or any of the things every NixOS system needs regardless of
# CI-OS — those belong to the CONSUMING flake's own
# `hardware-configuration.nix` and desktop choices (GNOME is `branding.nix`'s
# concern, a sibling module, not this one — see this backend's final
# report). `hardware.rocm.enable` below wires ROCm's userspace
# (rocmPackages, nixpkgs.config.rocmSupport, Ollama's acceleration) but
# deliberately does NOT touch `hardware.graphics.*`/kernel driver selection
# — that option's exact current name shifts across nixpkgs releases and
# wasn't independently confirmed for this pass (see "hardware tier"
# disclosure in the final report); getting it wrong would be a hard eval
# error, worse than leaving it to the consumer who already owns that
# choice. It also does not set `nixpkgs.config.allowUnfree`
# unconditionally — see `vscode.enable`'s own comment for the one place
# that matters and its disclosed caveat.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.ci-os.ecosystem;

  # ../manifest/ecosystem.generated.json — see that directory's
  # gen-ecosystem-json.sh for how this is produced/regenerated, and this
  # file's own header for why builtins.fromJSON against a committed file
  # (not Import-From-Derivation) is the right mechanism here.
  ecosystemData = builtins.fromJSON (builtins.readFile ../manifest/ecosystem.generated.json);

  # Look up a dev_tools[].tier by id from the manifest data, e.g.
  # `tierOf "gh" == "core"`. Falls back to null (never auto-enabled) for an
  # id the manifest doesn't (yet) list, rather than erroring the whole
  # module eval over a manifest/module drift — a missing id here means
  # "this module doesn't wire that tool yet," which is exactly the
  # documented-gap posture every prior backend's role-map file uses for its
  # own `unresolved` entries.
  tierOf = id:
    let matches = builtins.filter (t: t.id == id) ecosystemData.dev_tools;
    in if matches == [ ] then null else (builtins.head matches).tier;

  # A tool's Nix-module default: on when the ecosystem is enabled at all
  # AND the manifest tags it core; on when extended tier is requested AND
  # the manifest tags it extended; off otherwise (including "hardware" —
  # see this file's header for why hardware tier is never auto-derived
  # here). This is the concrete mechanism behind "editing ecosystem.yaml
  # changes this backend's defaults" — see the file header.
  defaultForTool = id:
    let tier = tierOf id;
    in cfg.enable && (tier == "core" || (tier == "extended" && cfg.extended.enable));

  # The "node" dev_tools entry's pinned version, read from the manifest so
  # the version pin itself has one source of truth too, not just the
  # decision to install it at all.
  nodeManifestEntry = lib.findFirst (t: t.id == "node") { version = "22.15.1"; } ecosystemData.dev_tools;

  # core/lib/ci-hub.sh's own directory — copied WHOLE (not just ci-hub.sh
  # alone) into the Nix store, because ci-hub.sh sources a SIBLING script
  # (generate-tunnel-certs.sh) via `"${SCRIPT_DIR}/generate-tunnel-certs.sh"`,
  # where SCRIPT_DIR is computed at runtime from `dirname
  # "${BASH_SOURCE[0]}"`. Referencing only the single file would put
  # ci-hub.sh in the store WITHOUT that sibling next to it, silently
  # breaking the tunnel-token-cert-generation path the first time
  # TUNNEL_TOKEN is actually set. This directory copy is this backend's
  # answer to the same problem Bazzite's Containerfile solves by an
  # explicit `COPY core/lib/ /usr/lib/ci-os/bootstrap/core/lib/` step (see
  # its own header) — Nix does the equivalent automatically by copying the
  # whole referenced directory into a single store path, no manual staging
  # instruction needed.
  ciHubLibDir = ../../../core/lib;
  ciHubScript = "${ciHubLibDir}/ci-hub.sh";

  # Everything ci-hub.sh's REQUIREMENTS section and its own body actually
  # shells out to: docker + `docker compose` (v2 plugin — ci-hub.sh hard-
  # fails its own prerequisite check if `docker compose version` doesn't
  # work), jq (manual docker-auth JSON edit, and now also this module's own
  # config.json seeding below), openssl (JWT_SECRET generation), dmidecode
  # (best-effort DEVICE_ID via `sudo dmidecode`, optional — see ci-hub.sh's
  # own fallback chain), and sudo itself (NixOS's `security.sudo.enable`
  # default covers the binary; dmidecode/sudo staying on PATH is what this
  # `path` list is for). `hostname` (ci-hub.sh's last-resort DEVICE_ID
  # fallback) comes from `pkgs.inetutils` — moderate, not fully
  # independently confirmed confidence on that exact package providing it
  # vs. some other nixpkgs hostname derivation; low severity either way (a
  # failed `$(hostname)` only degrades that one fallback string, not a hard
  # failure).
  #
  # `docker-compose` DELIBERATELY DOES NOT APPEAR IN THIS LIST — an earlier
  # draft of this module put `pkgs.docker-compose` here on the assumption
  # that having the binary on PATH would be "harmless if redundant,
  # load-bearing if not" for the `docker compose` (space, CLI-plugin)
  # subcommand ci-hub.sh actually calls. That assumption was checked against
  # nixpkgs directly during this pass and turned out to be WRONG, not merely
  # unverified: Docker's CLI plugin discovery does not scan PATH at all — it
  # only checks `~/.docker/cli-plugins/`, a fixed set of platform default
  # directories, and `cliPluginsExtraDirs` in `~/.docker/config.json`
  # (confirmed via docker/cli's own manager_unix.go and
  # https://github.com/NixOS/nixpkgs/issues/424333, which documents that
  # nixpkgs' `docker` package post-patches ITS OWN first-party plugins'
  # search path but does not do the same for the separate `docker-compose`
  # derivation — so a plain PATH-available `docker-compose` binary is
  # invisible to the `docker compose` subcommand regardless of this `path`
  # list). The actual fix is the `dockerComposePluginDir`/preStart wiring
  # below, which points Docker's own `cliPluginsExtraDirs` config at
  # `pkgs.docker-compose`'s store path — nixpkgs' `docker-compose` builds
  # the real upstream github.com/docker/compose v2 binary, which implements
  # the CLI-plugin metadata handshake and is safe to expose this way, it
  # simply isn't auto-discovered without this extra step.
  ciHubRuntimeDeps = with pkgs; [ docker jq openssl dmidecode gnused coreutils gawk gnugrep inetutils sudo ];

  # The directory `docker compose` (the CLI-plugin subcommand, not the
  # `docker-compose` binary name itself) needs added to
  # `~/.docker/config.json`'s `cliPluginsExtraDirs` for the plugin manager
  # to find it — see `ciHubRuntimeDeps`'s comment above for why this is
  # necessary at all and the nixpkgs issue confirming it.
  dockerComposePluginDir = "${pkgs.docker-compose}/bin";

  # asdf + Node.js (pinned version), run as a Nix-declared systemd oneshot
  # instead of a first-boot marker-file script (see this file's header for
  # why asdf, not pkgs.nodejs, is kept here at all: every OTHER backend
  # pins the exact same version via asdf specifically so CI-Hub's own build
  # tooling and every appliance behave identically regardless of distro;
  # nixpkgs' own `pkgs.nodejs_22` tracks whatever 22.x nixpkgs currently
  # ships, not necessarily this exact patch version, so substituting it
  # would silently drop the cross-backend version-pin guarantee). This
  # still only writes into `$HOME` (`~/.asdf`), exactly like every other
  # backend's install_asdf_nodejs() — the only thing that changes here is
  # HOW it's invoked: a declared systemd unit gated by
  # `ConditionPathExists=!` against the same install-marker path asdf
  # itself would produce, instead of an imperative call inside a
  # provisioning script.
  asdfNodejsScript = pkgs.writeShellScript "ci-os-asdf-nodejs.sh" ''
    set -euo pipefail
    ASDF_DIR="$HOME/.asdf"
    ASDF_DATA_DIR="''${ASDF_DATA_DIR:-$ASDF_DIR}"
    ASDF_VERSION="v0.14.0"
    NODE_VERSION="${cfg.nodejs.version}"

    export PATH="${lib.makeBinPath [ pkgs.git pkgs.curl pkgs.gnutar pkgs.gzip pkgs.gnumake pkgs.gcc pkgs.python3 ]}:$PATH"

    if [ ! -d "$ASDF_DIR" ]; then
      git clone https://github.com/asdf-vm/asdf.git "$ASDF_DIR" --branch "$ASDF_VERSION"
    fi
    export ASDF_DIR ASDF_DATA_DIR
    # shellcheck source=/dev/null
    . "$ASDF_DIR/asdf.sh"

    echo 'legacy_version_file = yes' > "$HOME/.asdfrc"
    asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git 2>/dev/null || true
    asdf install nodejs "$NODE_VERSION"
    asdf reshim nodejs
    asdf global nodejs "$NODE_VERSION"

    if [ "${lib.boolToString cfg.corepack.enable}" = "true" ]; then
      export PATH="$ASDF_DIR/shims:$ASDF_DIR/bin:$PATH"
      corepack enable || true
      corepack prepare pnpm@latest --activate || true
      asdf reshim nodejs || true
    fi
  '';
in
{
  options.services.ci-os.ecosystem = {
    enable = lib.mkEnableOption ''
      the CI-OS ecosystem's core tier: Docker, GitHub CLI, cloudflared,
      Tailscale, Ollama (+ the fixed 3-model set), uv, asdf-managed
      Node.js, the `ci` service user, and the CI-Hub deploy. This is the
      direct analog of running provision.sh with no --tier flag
      (--tier=core,hardware on a bash backend)'';

    extended.enable = lib.mkEnableOption ''
      extended-tier tooling: Chromium and VS Code. The direct analog of
      --tier=extended on a bash backend. Homebrew, Bun, and Companion
      Launcher are ALSO extended-tier in core/manifest/ecosystem.yaml but
      are not wired to any option here — see this file's header ("PER-TOOL
      DISPOSITION"). Bun specifically: ecosystem.yaml's own note says no
      component in this repo requires it at build or run time (CI-Hub
      ships as a prebuilt Docker image; no bun.lockb/bunfig.toml
      anywhere in-tree) — kept unwired for the same reason every other
      backend also leaves it unimplemented, not an oversight specific to
      this one'';

    hardware = {
      rocm.enable = lib.mkEnableOption ''
        ROCm GPU acceleration (AMD). Hardware tier in
        core/manifest/ecosystem.yaml, but — unlike every bash backend,
        which auto-detects this via core/lib/gpu-detect.sh at
        provision-time — this is an EXPLICIT opt-in here, because Nix
        module evaluation has no live-hardware probe to auto-derive it
        from (see this file's header, "TIER MODEL" section). Enabling this
        sets `nixpkgs.config.rocmSupport = true;`, installs
        `rocmPackages.clr` (the OpenCL runtime/ICD this phase's research
        confirmed — see the config block's own comment for why
        `rocmPackages.rocminfo` is deliberately NOT also installed; that
        attribute wasn't independently confirmed for this pass), and
        (unless `ecosystem.ollama.acceleration` was set explicitly)
        defaults `services.ollama.acceleration` to `"rocm"` — matching
        backends/arch/provision/provision.sh's genuine (non-stubbed) ROCm
        install. Confirmed via this phase's research that `rocmPackages`
        is a real, substantial nixpkgs package set (~72 derivations),
        unlike Fedora's stubbed gap. Does NOT touch kernel/graphics driver
        selection — see this file's closing header note'';

      rocmOverrideGfx = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "11.0.0";
        description = ''
          Passed to `services.ollama.rocmOverrideGfx` when set — for GPUs
          whose ROCm gfx-version autodetection needs an override (the same
          class of problem core/lib/gpu-detect.sh's Strix Halo (gfx1151)
          special-casing exists to work around on the bash backends,
          expressed here as the nixpkgs-native knob instead).
        '';
      };

      lact.enable = lib.mkEnableOption ''
        the LACT GPU control daemon. Hardware tier, explicit opt-in for the
        same reason as `hardware.rocm.enable` above. Confirmed via this
        phase's research to have a real, first-class `services.lact`
        nixpkgs module (pairs with `hardware.amdgpu.overdrive.enable`) — a
        genuine improvement over Fedora's stubbed gap and on par with
        Bazzite's COPR-based non-stubbed finding, per
        docs/architecture/multi-distro-design.md'';
    };

    ciUser = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.enable;
        description = ''
          Create the `ci` service user declaratively via `users.users.*` —
          the Nix-native analog of every bash backend's create_ci_user()
          (`useradd -m ci; usermod -aG docker ci`).
        '';
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = "ci";
        description = "Username for the CI-OS service user.";
      };
      extraGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = lib.optionals cfg.docker.enable [ "docker" ]
          ++ lib.optionals cfg.hardware.rocm.enable [ "render" "video" ];
        defaultText = lib.literalExpression ''
          [ "docker" ] (if docker.enable) ++ [ "render" "video" ] (if hardware.rocm.enable)
        '';
        description = ''
          Extra groups for the `ci` user. Defaults mirror
          backends/arch/provision/provision.sh's fix (ported from Ubuntu's
          working ROCm installer) after an earlier pass discovered
          create_ci_user() never granted `render`/`video` membership
          needed for ROCm device access — this module's default includes
          that fix from the start rather than needing the same bug found
          twice.
        '';
      };
    };

    docker.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Enable `virtualisation.docker` (role: containerization, tier core).";
    };

    ghCli.enable = lib.mkOption {
      type = lib.types.bool;
      default = defaultForTool "gh";
      defaultText = lib.literalExpression ''derived from ecosystem.generated.json's "gh" tier (core)'';
      description = "Install GitHub CLI (`pkgs.gh`).";
    };

    cloudflared.enable = lib.mkOption {
      type = lib.types.bool;
      default = defaultForTool "cloudflared";
      defaultText = lib.literalExpression ''derived from ecosystem.generated.json's "cloudflared" tier (core)'';
      description = ''
        Install the cloudflared CLI (`pkgs.cloudflared`) as a plain system
        package. Per this phase's research: this repo's usage is the bare
        CLI (status/pairing), not a standing tunnel, so this is
        `environment.systemPackages`, not `services.cloudflared.tunnels` —
        that module stays a note for if Portal's tunnel is ever run from
        this backend directly.
      '';
    };

    tailscale.enable = lib.mkOption {
      type = lib.types.bool;
      default = defaultForTool "tailscale";
      defaultText = lib.literalExpression ''derived from ecosystem.generated.json's "tailscale" tier (core)'';
      description = "Enable `services.tailscale` (mature, first-class nixpkgs module).";
    };

    chromium.enable = lib.mkOption {
      type = lib.types.bool;
      default = defaultForTool "chromium";
      defaultText = lib.literalExpression ''derived from ecosystem.generated.json's "chromium" tier (extended)'';
      description = "Install Chromium (`pkgs.chromium`).";
    };

    vscode.enable = lib.mkOption {
      type = lib.types.bool;
      default = defaultForTool "vscode";
      defaultText = lib.literalExpression ''derived from ecosystem.generated.json's "vscode" tier (extended)'';
      description = ''
        Install Microsoft's VS Code build (`pkgs.vscode`) — CONFIRMED via
        this phase's research to be the genuine MS-branded, telemetry-on
        build (needs `nixpkgs.config.allowUnfree = true`), distinct from
        `pkgs.vscodium` (the OSS/no-telemetry fork). This is a real
        difference from backends/arch/, where the MS build lives ONLY in
        the AUR and native `code` is unrelated Code-OSS — nixpkgs' own
        `vscode` attribute IS the real thing here, no AUR/COPR-style
        substitution risk.

        CAVEAT (disclosed, not silently assumed): this module sets
        `nixpkgs.config.allowUnfree = true` itself when this option is
        enabled, via the standard `nixpkgs.config` module option. That only
        takes effect if the CONSUMING flake lets the NixOS module system
        construct `pkgs` (the common case). If a consuming flake instead
        constructs `pkgs` itself via `import nixpkgs { ... }` before the
        module system ever runs, this module's automatic unfree-enable
        will NOT take effect and `code` will fail to build with the
        standard unfree-package eval error — the consumer must set
        `nixpkgs.config.allowUnfree = true;` in their own flake in that
        case. Not independently verified against every possible consumer
        flake shape.
      '';
    };

    uv.enable = lib.mkOption {
      type = lib.types.bool;
      default = defaultForTool "uv";
      defaultText = lib.literalExpression ''derived from ecosystem.generated.json's "uv" tier (core)'';
      description = ''
        Install uv (`pkgs.uv`) as a plain system package. DEVIATION FROM
        EVERY OTHER BACKEND, disclosed: every bash backend runs
        astral.sh/uv/install.sh into `$HOME` (ecosystem.yaml's own `uv`
        entry: `installer: {method: curl_script, ...}`). This phase's
        research confirmed nixpkgs packages uv natively
        (`pkgs.uv`/`pkgs/by-name/uv/uv`) — strictly more idiomatic on
        NixOS (a real store path, updates with the rest of the system, no
        $HOME-writing curl|sh needed) with no discovered downside, so this
        module uses the native package rather than reimplementing the
        curl-script $HOME install via an activation script. uv's own
        project-level `.python-version`/venv behavior is unaffected either
        way — only WHERE the `uv` binary itself comes from changes.
      '';
    };

    nodejs = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = defaultForTool "node";
        defaultText = lib.literalExpression ''derived from ecosystem.generated.json's "node" tier (core)'';
        description = ''
          Install Node.js via asdf (pinned to `version`, matching every
          other backend) for `ciUser.name`, as a Nix-declared systemd
          oneshot — see `asdfNodejsScript` above for why asdf (not
          `pkgs.nodejs`) was kept, and the "REIMPLEMENTED AS A NIX-DECLARED
          SYSTEMD UNIT" line in this file's header for the general
          pattern.
        '';
      };
      version = lib.mkOption {
        type = lib.types.str;
        default = nodeManifestEntry.version;
        defaultText = lib.literalExpression ''derived from ecosystem.generated.json's "node" entry's "version" field'';
        description = "Pinned Node.js version, installed via asdf.";
      };
    };

    corepack.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.nodejs.enable;
      description = "Enable corepack + `pnpm@latest` after asdf's Node.js install, matching every other backend's enable_corepack().";
    };

    ollama = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.enable;
        description = "Enable services.ollama.";
      };
      acceleration = lib.mkOption {
        # The real upstream `services.ollama.acceleration` type is
        # `nullOr (enum [false "rocm" "cuda" "vulkan"])` (confirmed against
        # nixpkgs source by this phase's adversarial review) — this wrapper
        # option previously narrowed that to just "rocm"/"cuda"/null,
        # silently making `false` (explicitly disable GPU acceleration) and
        # "vulkan" unreachable through this module. Widened to match
        # upstream's real surface exactly rather than a subset of it.
        type = lib.types.nullOr (lib.types.enum [ false "rocm" "cuda" "vulkan" ]);
        default = if cfg.hardware.rocm.enable then "rocm" else null;
        defaultText = lib.literalExpression ''"rocm" if hardware.rocm.enable else null'';
        description = ''
          Passed to `services.ollama.acceleration`. Per this phase's
          research, nixpkgs' services.ollama module resolves acceleration
          from `nixpkgs.config.{rocmSupport,cudaSupport}` when left at its
          own default; this option lets it be pinned explicitly instead —
          including `false`, to explicitly force CPU-only even when
          `hardware.rocm.enable` would otherwise default it to `"rocm"`.
          NOTE: `services.ollama`'s exact option surface (`host`, `port`,
          `environmentVariables`, `rocmOverrideGfx`) was confirmed by this
          phase's research in substance but not re-verified attribute name
          by attribute name against the exact nixpkgs revision this flake
          pins — check `nix eval` / the module's own source if any of
          these fail to apply.
        '';
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = ''
          Matches every bash backend's `OLLAMA_HOST=0.0.0.0` systemd
          drop-in (exposes the API beyond localhost — a deliberate,
          pre-existing product decision this module preserves, not
          something newly introduced here).
        '';
      };
      contextLength = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = ''
          DISCLOSED GAP vs. every bash backend: Ubuntu/Fedora/Arch/Bazzite
          all auto-size OLLAMA_CONTEXT_LENGTH from `/proc/meminfo` at
          provision time (see provision.sh's
          recommend_ollama_context_length()). Nix module evaluation has no
          reproducible way to read the target machine's live RAM (the same
          "no runtime probe at eval time" limitation documented under
          `hardware.rocm.enable` above) — auto-sizing this would require
          either IFD or impure evaluation, both rejected for the same
          reasons given in this file's header and in
          ../manifest/gen-ecosystem-json.sh's. Left at `null` (Ollama's own
          default) unless the consuming flake's author sets it explicitly
          for their own known hardware.
        '';
      };
      pullModels.enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.ollama.enable;
        description = ''
          Pull the fixed model set (below) via a systemd oneshot, gated by
          a marker file (multi-GB downloads — see this option's
          implementation for why THIS one keeps Bazzite's marker-file
          pattern while CI-Hub deploy below deliberately doesn't).
        '';
      };
      models = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ecosystemData.llm.models;
        defaultText = lib.literalExpression "ecosystem.generated.json's llm.models (the fixed 3-model set)";
        description = "Models pulled by the ci-os-ollama-models systemd oneshot.";
      };
    };

    ciHub = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.enable;
        description = ''
          Wire a systemd service that invokes core/lib/ci-hub.sh
          UNMODIFIED (staged into the Nix store — see `ciHubScript` above)
          to deploy the CI Hub Service (Docker Compose, port 5002).
        '';
      };
      environmentFile = lib.mkOption {
        # STRING, not `lib.types.path`, and deliberately so: this holds the
        # path to a file containing SECRETS (REGISTRY_USERNAME/PASSWORD,
        # TUNNEL_TOKEN/API_KEY). `lib.types.path`'s check accepts a Nix path
        # LITERAL (e.g. `./my-secrets.env`) as readily as a plain string —
        # and a path literal gets copied into the world-readable /nix/store
        # at evaluation time with no warning, which would leak the secrets
        # it's meant to protect. `lib.types.str` forces the safe runtime-
        # only-lookup form (a plain string naming a path that exists on the
        # TARGET system, e.g. one written by sops-nix/agenix at activation
        # time, never evaluated or copied by Nix itself) and rejects a path
        # literal outright at eval time instead of silently accepting the
        # unsafe form. Same reasoning sops-nix/agenix apply to their own
        # equivalent `secrets.<name>.path` options.
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Optional systemd EnvironmentFile path (e.g. produced by sops-nix or
          agenix) supplying REGISTRY_USERNAME/REGISTRY_PASSWORD and
          optionally TUNNEL_TOKEN/DEVICE_ID/API_KEY for ci-hub.sh. Loaded
          with the `-` (ignore-if-missing) EnvironmentFile prefix, so a
          device with no credentials configured yet does not fail the
          unit — ci-hub.sh itself already handles their absence by
          printing one clear message and exiting 0 (see its own header);
          this module relies on that existing behavior rather than
          re-implementing the gate. Pass a plain string path (e.g.
          `config.sops.secrets.ci-hub-env.path`), never a Nix path literal
          — see the type comment above for why.
        '';
      };
      pairingEnvironmentFile = lib.mkOption {
        # STRING, not `lib.types.path` — same reasoning as `environmentFile`
        # above: this file holds device-pairing secrets (DEVICE_ID/API_KEY),
        # written to the target system at runtime by the headless-setup
        # portal, never something Nix itself should read or copy into the
        # store.
        type = lib.types.str;
        default = "/var/lib/setup-device/hub.env";
        description = ''
          Written by core/headless/payload/opt/setup-backend/setup_service.py's
          save_hub_env() once WiFi/device pairing completes (CI_ZONE_ID,
          DEVICE_ID, API_KEY, CI_CLOUD_API_URL) — see
          services.ci-os.headlessSetup's own module. Loaded (also with the
          `-` ignore-if-missing prefix) BEFORE `environmentFile`, so an
          operator-supplied `environmentFile` can still override any
          overlapping key, matching the precedence
          ci-os-first-boot-ci-hub.sh (Bazzite) already establishes by
          sourcing HUB_ENV before invoking ci-hub.sh.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.docker.enable {
      virtualisation.docker.enable = true;
    })

    # ---- Plain-package tools ------------------------------------------------
    {
      environment.systemPackages =
        lib.optional cfg.ghCli.enable pkgs.gh
        ++ lib.optional cfg.cloudflared.enable pkgs.cloudflared
        ++ lib.optional cfg.chromium.enable pkgs.chromium
        ++ lib.optional cfg.vscode.enable pkgs.vscode
        ++ lib.optional cfg.uv.enable pkgs.uv;
    }

    (lib.mkIf cfg.vscode.enable {
      nixpkgs.config.allowUnfree = true;
    })

    (lib.mkIf cfg.tailscale.enable {
      services.tailscale.enable = true;
    })

    # ---- Ollama --------------------------------------------------------------
    (lib.mkIf cfg.ollama.enable {
      services.ollama = {
        enable = true;
        host = cfg.ollama.host;
        acceleration = cfg.ollama.acceleration;
      }
      // lib.optionalAttrs (cfg.hardware.rocmOverrideGfx != null) {
        rocmOverrideGfx = cfg.hardware.rocmOverrideGfx;
      }
      // lib.optionalAttrs (cfg.ollama.contextLength != null) {
        environmentVariables.OLLAMA_CONTEXT_LENGTH = toString cfg.ollama.contextLength;
      };
    })

    (lib.mkIf cfg.ollama.pullModels.enable {
      # Multi-GB downloads — unlike CI-Hub deploy below, this KEEPS the
      # Bazzite-style marker-file/ConditionPathExists pattern deliberately.
      # See ci-os-first-boot-ollama-models.sh's own header (Bazzite) for the
      # original rationale; it applies unchanged here: a device with no
      # network yet, or that already pulled the models, must not re-attempt
      # multi-GB downloads on every boot. Re-run manually with
      # `sudo rm /var/lib/ci-os/.ollama-models-pulled && sudo systemctl
      # start ci-os-ollama-models.service`.
      systemd.services.ci-os-ollama-models = {
        description = "CI-OS: pull the fixed Ollama model set";
        after = [ "ollama.service" "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        unitConfig.ConditionPathExists = "!/var/lib/ci-os/.ollama-models-pulled";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -uo pipefail
          for model in ${lib.escapeShellArgs cfg.ollama.models}; do
            if ${pkgs.ollama}/bin/ollama list 2>/dev/null | grep -qF "$model"; then
              echo "$model already installed"
            else
              echo "Pulling $model..."
              ${pkgs.ollama}/bin/ollama pull "$model" || echo "WARNING: failed to pull $model (will retry next un-gated run)"
            fi
          done
          mkdir -p /var/lib/ci-os
          date -u > /var/lib/ci-os/.ollama-models-pulled
        '';
      };
    })

    # ---- ROCm / LACT (hardware tier — explicit opt-in, see options above) ----
    (lib.mkIf cfg.hardware.rocm.enable {
      nixpkgs.config.rocmSupport = true;
      # rocmPackages.clr is the specific attribute this phase's research
      # confirmed (OpenCL runtime/ICD) — kept to just that one, deliberately
      # not guessing at further rocmPackages.* attribute names (e.g. a
      # rocminfo diagnostic package likely also exists under this set, but
      # wasn't independently confirmed for this pass — add it to your own
      # config's environment.systemPackages once verified against your
      # pinned nixpkgs revision).
      environment.systemPackages = [ pkgs.rocmPackages.clr ];
    })

    (lib.mkIf cfg.hardware.lact.enable {
      services.lact.enable = true;
      hardware.amdgpu.overdrive.enable = lib.mkDefault true;
    })

    # ---- ci_user ---------------------------------------------------------------
    (lib.mkIf cfg.ciUser.enable {
      users.users.${cfg.ciUser.name} = {
        isNormalUser = true;
        description = "CI-OS service user (declarative analog of create_ci_user() on every bash backend)";
        extraGroups = cfg.ciUser.extraGroups;
      };
    })

    # ---- asdf + Node.js + corepack (systemd oneshot, see asdfNodejsScript) ----
    (lib.mkIf cfg.nodejs.enable {
      systemd.services.ci-os-asdf-nodejs = {
        description = "CI-OS: install Node.js ${cfg.nodejs.version} via asdf for ${cfg.ciUser.name}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        unitConfig.ConditionPathExists = "!/home/${cfg.ciUser.name}/.asdf/installs/nodejs/${cfg.nodejs.version}/bin/node";
        serviceConfig = {
          Type = "oneshot";
          User = cfg.ciUser.name;
          ExecStart = "${asdfNodejsScript}";
        };
      };
    })

    # ---- CI-Hub deploy ----------------------------------------------------------
    # UNLIKE the Ollama-model-pull unit above, this deliberately does NOT
    # use a first-boot marker file. Reasoning (see also
    # services.ci-os.ecosystem.ciHub.enable's own doc comment):
    #   - ci-hub.sh is idempotent BY DESIGN: it backs up and reuses an
    #     existing .env's JWT_SECRET, and `docker compose up -d` is a
    #     correct, side-effect-free no-op when the stack is already
    #     running. Re-running it is not "redo expensive work," unlike
    #     pulling multi-gigabyte model weights.
    #   - ci-hub.sh ALREADY self-gates on missing registry credentials —
    #     prints one clear message and exits 0 (see its own header) —
    #     duplicating that gate as a marker file would only add a second,
    #     redundant layer that could drift from the first.
    #   - Running this on every boot (rather than "only once, ever, unless
    #     manually reset") means a device that gets paired/credentialed
    #     LATER in its life automatically gets CI-Hub deployed on its very
    #     next boot, with no manual `rm marker && systemctl start` recovery
    #     step required — a genuine improvement Nix's declarative "this is
    #     what should be running" model makes easy, that Bazzite's
    #     imperative first-boot-only model does not get for free.
    (lib.mkIf cfg.ciHub.enable {
      systemd.services.ci-os-hub-deploy = {
        description = "CI-OS: deploy CI Hub Service via core/lib/ci-hub.sh (unmodified)";
        after = [ "docker.service" "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        path = ciHubRuntimeDeps;
        environment.HOME = "/var/lib/ci-os-hub";
        # Seeds (merges, not overwrites — see the `jq` branch below)
        # `cliPluginsExtraDirs` into $HOME/.docker/config.json BEFORE
        # ci-hub.sh runs, so its own "docker compose version" prerequisite
        # check (the very first thing it does) succeeds — see
        # `dockerComposePluginDir`'s comment above for why this is required
        # at all instead of just listing `pkgs.docker-compose` in `path`.
        # Uses `jq` (already on this unit's `path` via `ciHubRuntimeDeps`)
        # to MERGE rather than clobber, because ci-hub.sh's own later
        # registry-auth step (further down in its REQUIREMENTS-adjacent
        # logic) reads/rewrites this SAME file's `.auths` key — a blind
        # overwrite here would race that step's idempotency across
        # `ci-os-hub-deploy`'s repeated every-boot runs (see this option's
        # own "UNLIKE the Ollama-model-pull unit" comment below for why this
        # unit re-runs every boot at all).
        preStart = ''
          mkdir -p "$HOME/.docker"
          if [ -s "$HOME/.docker/config.json" ] && jq empty "$HOME/.docker/config.json" 2>/dev/null; then
            jq --arg dir "${dockerComposePluginDir}" \
              '.cliPluginsExtraDirs = ((.cliPluginsExtraDirs // []) - [$dir] + [$dir])' \
              "$HOME/.docker/config.json" > "$HOME/.docker/config.json.tmp" \
              && mv "$HOME/.docker/config.json.tmp" "$HOME/.docker/config.json"
          else
            printf '%s\n' '{"cliPluginsExtraDirs": ["${dockerComposePluginDir}"]}' > "$HOME/.docker/config.json"
          fi
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StateDirectory = "ci-os-hub";
          EnvironmentFile =
            [ "-${cfg.ciHub.pairingEnvironmentFile}" ]
            ++ lib.optional (cfg.ciHub.environmentFile != null) "-${cfg.ciHub.environmentFile}";
          ExecStart = "${pkgs.bash}/bin/bash ${ciHubScript}";
        };
      };

      # DISCLOSED GAP THIS CLOSES: core/headless/payload's own
      # opt/setup-backend/setup_service.py triggers CI-Hub deploy
      # immediately after successful pairing by invoking
      # /usr/local/bin/ci-os-hub-start.sh (reused unmodified by
      # headless-setup.nix's ciOsHeadlessBin — see that module). That
      # script's own PROVISION_SH constant
      # ("/usr/lib/ci-os/bootstrap/backends/ubuntu/provision/provision.sh")
      # is an Ubuntu-ISO-specific staged path (see its own header comment)
      # that never exists on this backend, so on NixOS that call is a
      # silent, harmless no-op ("PROVISION_SH not found; cannot deploy
      # CI-Hub") rather than a crash — but it also means the immediate
      # "deploy right after pairing" trigger every bash backend gets for
      # free does NOT fire here. Patching ci-os-hub-start.sh's hardcoded
      # path would mean forking a reused-by-path script for a
      # single-backend concern, which this phase's brief asks NOT to do.
      # Instead: a native `systemd.paths` unit watches
      # `cfg.ciHub.pairingEnvironmentFile` (the same hub.env
      # setup_service.py's save_hub_env() writes) and starts
      # ci-os-hub-deploy.service the moment that file appears — closing
      # the same gap declaratively, without touching any reused payload
      # file. Without this, CI-Hub would still deploy (ci-os-hub-deploy.service
      # is wantedBy multi-user.target and re-runs every boot regardless —
      # see that service's own comment), just only on the NEXT boot rather
      # than within seconds of pairing.
      systemd.paths.ci-os-hub-deploy-trigger = {
        description = "CI-OS: trigger CI-Hub deploy as soon as device pairing completes";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathExists = cfg.ciHub.pairingEnvironmentFile;
          Unit = "ci-os-hub-deploy.service";
        };
      };
    })

    # ---- telemetry_removal: documented no-op, not a silently-missing step ----
    # NixOS ships nothing phone-home by default — no analog to Ubuntu's
    # ubuntu-report/whoopsie or even Fedora's local-only ABRT. Confirmed by
    # this phase's research; matches every prior backend's own finding for
    # its own distro (Fedora/Arch: "ships no equivalent... deliberate
    # no-op"). No option or config statement is needed here — this comment
    # IS the documentation, the same posture role-map/dnf.yaml's
    # telemetry_removal entry (`install_method: none`) takes.

    # ---- assertions: catch interdependent-option misconfiguration at -----
    # `nixos-rebuild switch` EVAL TIME, not at boot. Under this module's own
    # defaults everything is self-consistent (nodejs/ciUser/docker/ciHub all
    # derive from the same top-level `cfg.enable`), so these only fire for a
    # consumer who deviates from the defaults — e.g. sets `ciUser.enable =
    # false` while leaving `nodejs.enable` at its default `true`. Without
    # these, that specific case produces a working `nixos-rebuild switch`
    # that only fails at BOOT, when ci-os-asdf-nodejs.service's `User =
    # cfg.ciUser.name` references a system user that was never declared —
    # an adversarial review of this phase caught the gap; a build-time
    # error is a strictly better failure mode than a boot-time one.
    {
      assertions = [
        {
          assertion = cfg.nodejs.enable -> cfg.ciUser.enable;
          message = ''
            services.ci-os.ecosystem.nodejs.enable requires
            services.ci-os.ecosystem.ciUser.enable: the asdf/Node.js
            systemd unit runs as `User = ciUser.name`, a system user this
            module only declares when ciUser.enable is true.
          '';
        }
        {
          assertion = cfg.ciHub.enable -> cfg.docker.enable;
          message = ''
            services.ci-os.ecosystem.ciHub.enable requires
            services.ci-os.ecosystem.docker.enable: core/lib/ci-hub.sh's
            first prerequisite check is `docker compose version`, which
            has nothing to succeed against unless
            virtualisation.docker.enable is also set.
          '';
        }
      ];
    }
  ];
}
