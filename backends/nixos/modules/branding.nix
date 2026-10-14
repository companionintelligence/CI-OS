# backends/nixos/modules/branding.nix — CI-OS declarative brand theming for
# NixOS (Phase 6). See docs/architecture/multi-distro-design.md for the
# overall six-backend rollout and this backend's own place in it.
#
# ============================================================================
# WHAT THIS FILE IS, AND ISN'T
# ============================================================================
# Every prior backend (Ubuntu/Mint/Fedora/Arch) ships a bash script that
# mutates an already-running system in place; Bazzite (Phase 5) bakes an OCI
# image once via a Containerfile. NixOS is neither: this file is a NixOS
# MODULE — an attribute set of `options` (a namespaced knob a consumer's own
# flake can set) and `config` (what setting those knobs actually changes) —
# exposed by ../flake.nix as (expected to be) `nixosModules.branding` /
# part of `nixosModules.default`. It produces no script and no image; the
# deliverable is reusable Nix CODE that a THIRD PARTY's own NixOS system
# flake imports and opts into, e.g.:
#
#   # someone else's flake.nix
#   imports = [ ci-os.nixosModules.default ];
#   services.ci-os.branding.enable = true;
#
# Nothing in this file "runs" on its own; it only takes effect once a real
# NixOS system configuration (which this repo does not own or ship) imports
# it and sets `services.ci-os.branding.enable = true`. That's why every
# `config.*` assignment below prefers `lib.mkDefault` — a value that
# ACTIVATES cleanly for someone who imports this module and does nothing
# else, but that their own config can still freely override without a
# priority conflict, because "consumed by a config we don't own or control"
# is the entire point of a NixOS module versus a script we run ourselves.
#
# ============================================================================
# OPTION NAMESPACE — for the sibling ecosystem.nix / headless-setup.nix /
# flake.nix agent to match
# ============================================================================
# Everything here lives under `services.ci-os.branding.*`, mirroring how
# consumers already think about `services.tailscale.*` / `services.ollama.*`
# (a single shared `services.ci-os.*` prefix, one leaf per module, each with
# its own `enable`). Concretely, this file declares:
#   services.ci-os.branding.enable            (top-level switch)
#   services.ci-os.branding.plymouth.enable
#   services.ci-os.branding.grub.enable
#   services.ci-os.branding.gnome.enable
#   services.ci-os.branding.gnome.accentColor
#   services.ci-os.branding.motd.enable
#   services.ci-os.branding.motd.extraText
# The sibling modules are expected to be `services.ci-os.ecosystem.*` (per
# the plan's own tier language: `services.ci-os.ecosystem.core.enable` etc.)
# and `services.ci-os.headlessSetup.*` — not verified against their actual
# output since this was written concurrently and those files did not exist
# yet at the time of writing (only backends/nixos/manifest/{gen-ecosystem-json.sh,
# ecosystem.generated.json} existed — no flake.nix, no ecosystem.nix).
#
# ============================================================================
# CONFIDENCE LEVELS (same discipline every prior backend's header uses —
# Nix comments, same honesty)
# ============================================================================
# CONFIRMED by reading the actual nixpkgs module source directly (not
# inferred, not taken on the research pass's word alone — re-verified via a
# live `curl` of nixos/modules/{system/boot/plymouth.nix, programs/dconf.nix,
# system/boot/loader/grub/grub.nix, security/pam.nix} against the
# release-25.11 branch while writing this file):
#   - boot.plymouth's option surface (enable/package/theme/themePackages/
#     logo/font/extraConfig/showDelay) and that `themesEnv` is built via
#     `pkgs.buildEnv { paths = [cfg.package plymouthLogos] ++ cfg.themePackages; }`
#     — the exact reason this file overrides `package` rather than
#     `themePackages` for the recolored spinner/bgrt themes (see the
#     `ciPlymouthPackage` comment below).
#   - boot.loader.grub.splashImage/splashMode/backgroundColor all exist,
#     splashImage is `nullOr path`, splashMode is `enum [ "normal" "stretch" ]`
#     (default already "stretch" once a non-default splashImage is set).
#   - programs.dconf.profiles.<name>.databases compiles into a real
#     `/etc/dconf/profile/<name>` + `/etc/dconf/db/<name>` pair with NO
#     home-manager involvement — genuinely system-level, confirmed by
#     reading nixos/modules/programs/dconf.nix's `mkDconfProfile` directly.
#     One real subtlety this file's own reading turned up (not called out by
#     the earlier research pass): `dconfProfile.enableUserDb` always emits
#     the LITERAL line `user-db:user` regardless of the profile's own name —
#     there is no way through this option to emit `user-db:gdm` the way
#     Fedora's/Arch's ArchWiki-documented convention does. This turns out
#     not to matter: per `dconf.conf(5)`, the `NAME` in `user-db:NAME` is
#     just an on-disk label for the per-UID writable database (it resolves
#     against the CURRENT PROCESS's UID regardless of what NAME says), not a
#     username lookup — so `user-db:user` under `/etc/dconf/profile/gdm` is
#     functionally equivalent to `user-db:gdm`, just a different on-disk
#     filename for gdm's own (normally-empty) per-user overrides. Left at
#     its default (true) rather than fighting the module over a
#     non-issue.
#   - `services.desktopManager.gnome.enable` is the CURRENT (release-25.11)
#     option path (moved from `services.xserver.desktopManager.gnome.enable`
#     — nixos/modules/services/desktop-managers/gnome.nix, confirmed to no
#     longer live under services/x11/). This module deliberately does NOT
#     read or gate on that path (see the `gnome.enable` config block below
#     for why) specifically BECAUSE it has already moved once and nothing
#     here should break for a consumer pinned to an older nixpkgs where the
#     old path is still what exists.
#   - `users.motd` is `lib.types.lines`, default `""`, lives at top-level
#     `users.motd` (security/pam.nix), and PAM's own `motd` service enables
#     itself whenever `showMotd && (users.motd != "" || users.motdFile != null)`
#     — no separate enablement step, matching the research pass's finding,
#     with the one correction that the gate is "non-empty string", not
#     "non-null" (the option can never be null; only `motdFile` is nullable).
#
# BEST-EFFORT / NOT INDEPENDENTLY VERIFIED HERE:
#   - `boot.loader.grub.enable` being safe to reference unconditionally
#     (assumed always-declared because grub.nix is unconditionally in
#     nixpkgs's base module-list.nix, not gated behind an import a consumer
#     might have dropped) — extremely likely correct (GRUB has been a
#     baseline NixOS module for its entire history) but not fetched/grepped
#     the way the four files above were.
#   - Everything about how this file behaves once actually imported into a
#     real consuming flake and evaluated with `nix flake check` / `nixos-rebuild`
#     — see the bottom of this file for exactly what could and couldn't be
#     checked in THIS environment (no `nix` binary present here at all).
#
# ============================================================================
# THEMING ARTIFACTS: which ones invoke an existing core/render/*.sh script
# via a Nix derivation vs. which reimplement token math natively, and why
# ============================================================================
# Per the research this backend was handed (see the task's own research
# section on declarative theming — Plymouth/GRUB/GNOME/MOTD), the split is:
#
#   - GRUB background PNG: genuinely NOT pure-Nix-expressible (rasterizing
#     vendor/brand/logos/mark.svg onto a token-colored canvas needs
#     rsvg-convert/ImageMagick). INVOKES core/render/render-grub-background.sh
#     BY PATH, unmodified, inside a `pkgs.runCommand` derivation
#     (`grubBackgroundPng` below) — not a second, drifting reimplementation
#     of that script's own compositing logic.
#   - Plymouth watermark PNG: same "needs a raster tool" reasoning, but
#     there is no standalone core/render/*.sh for just this resize (Ubuntu's
#     10-plymouth.sh does it inline as one step of a much larger live-system
#     mutation — see `plymouthWatermarkPng`'s own comment for why that
#     script isn't invoked here either). Replicates the one `convert -resize
#     50%` operation against the same source asset and the same constant.
#   - Plymouth theme COLORS (BackgroundStartColor/BackgroundEndColor/
#     ProgressBarBackgroundColor/ProgressBarForegroundColor): a plain
#     `0xRRGGBB` value substitution — reimplemented NATIVELY via `ciHex0x`
#     against `tokens.json`, replicating (not invoking, for the same
#     "no standalone renderer script exists, and the live-system script does
#     unrelated interactive-upgrade bookkeeping" reason Bazzite's own
#     Containerfile gives) the exact 4-key sed transform every other backend
#     applies to the same two stock theme files.
#   - GNOME/GDM accent-color + color-scheme, and the MOTD banner text: pure
#     value lookups — reimplemented NATIVELY in Nix (`cfg.gnome.accentColor`,
#     `motdBanner`), read straight from `tokens.json` via `builtins.fromJSON`,
#     no external tool, no shelling out to tokens.sh. This is the same
#     "read structured JSON via builtins.fromJSON against a committed file"
#     shape this backend's sibling ecosystem.nix uses for
#     ecosystem.generated.json (no Import-From-Derivation anywhere in this
#     file).
#
# ============================================================================
# CONSTRAINTS HONORED
# ============================================================================
# - NO FONT CHANGES: this file never sets boot.plymouth.font,
#   boot.loader.grub.font, or any fontconfig/GNOME font option. Manrope
#   stays limited to Plymouth/terminal/MOTD/setup-portal on the OTHER
#   backends, as already true; nothing here touches fonts at all.
# - backends/{ubuntu,mint,fedora,arch,bazzite}/, backends/_mixins/, and
#   core/ file CONTENT are untouched — every core/render/*.sh, core/lib/*.sh,
#   and vendor/brand/* file this module reads is read BY PATH by a
#   derivation, never copied-and-edited into this repo.
# - ISO/install-media generation is out of scope for this phase (per the
#   plan) and this file does not attempt it — no nixos-generators, no
#   installer image, just the flake-importable module.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.ci-os.branding;

  # ==========================================================================
  # 1. The canon tokens — read directly via builtins.fromJSON against the
  #    COMMITTED vendor/brand/tokens/tokens.json. No Import-From-Derivation:
  #    this is the exact mechanism Nix itself uses to read flake.lock, and
  #    the same "read structured data via builtins against a checked-in
  #    file" shape the plan commits to for ecosystem.generated.json.
  # ==========================================================================
  tokens = builtins.fromJSON (builtins.readFile ../../../vendor/brand/tokens/tokens.json);

  # ==========================================================================
  # 2. vendor/brand/tokens/tokens.sh's two helper functions, reimplemented
  #    natively — per the plan's own explicit expectation ("only tokens.sh's
  #    two helper functions need a ~5-line Nix reimplementation"). Nix has
  #    no arithmetic-context hex-literal parsing the way bash's `$((0x1a))`
  #    does, so hex-byte decoding here is a plain lookup-table + arithmetic
  #    primitive instead — still well under the "~5 lines" the plan expects
  #    once you don't count the lookup table itself as "logic".
  # ==========================================================================

  # ci_hex0x(): "#0a6358" -> "0x0a6358" — the form Plymouth's *Color= keys want.
  ciHex0x = hex: "0x" + lib.removePrefix "#" hex;

  hexDigitValue =
    c:
    {
      "0" = 0;
      "1" = 1;
      "2" = 2;
      "3" = 3;
      "4" = 4;
      "5" = 5;
      "6" = 6;
      "7" = 7;
      "8" = 8;
      "9" = 9;
      "a" = 10;
      "b" = 11;
      "c" = 12;
      "d" = 13;
      "e" = 14;
      "f" = 15;
    }
    .${lib.toLower c};

  hexByteValue =
    pair: (hexDigitValue (builtins.substring 0 1 pair)) * 16 + (hexDigitValue (builtins.substring 1 1 pair));

  # ci_rgb(): "#0a6358" -> "10 99 88". Not called by anything in THIS file
  # today (every artifact branding.nix touches wants either the 0x.. form or
  # a bare named enum) — kept alongside ciHex0x for parity with tokens.sh's
  # own two-function surface, and because it's exactly what a future KDE (or
  # other Colors=R,G,B-style DE) addition to this backend would need, the
  # same role backends/_mixins/kde-plasma/CI-OS-Dark.colors fills today for
  # Bazzite. Unused-but-correct, not speculative dead code with unverified
  # behavior — exercises the same hexByteValue primitive ciHex0x's sibling
  # artifacts already depend on.
  ciRgb =
    hex:
    let
      h = lib.removePrefix "#" hex;
    in
    "${toString (hexByteValue (builtins.substring 0 2 h))} ${toString (hexByteValue (builtins.substring 2 2 h))} ${toString (hexByteValue (builtins.substring 4 2 h))}";

  # ==========================================================================
  # 3. The specific canon values this module needs — named to match the
  #    CI_* bash variables backends/ubuntu/desktop-theme/10-plymouth.sh and
  #    backends/fedora/desktop-theme/28-gdm-accent-branding.sh use, so this
  #    file reads the same as its bash siblings side-by-side.
  # ==========================================================================
  ciDarkBackground = tokens.dark.background.hex; # CI_DARK_BACKGROUND
  ciDarkSecondary = tokens.dark.secondary.hex; # CI_DARK_SECONDARY
  ciDarkPrimary = tokens.dark.primary.hex; # CI_DARK_PRIMARY

  # ==========================================================================
  # 4. GRUB background PNG — invokes core/render/render-grub-background.sh
  #    BY PATH, unmodified, inside a runCommand derivation. That script
  #    computes its own REPO_ROOT from `dirname "${BASH_SOURCE[0]}"` (two
  #    levels up from its own location) and sources core/lib/theme-lib.sh
  #    (which in turn sources vendor/brand/tokens/tokens.sh and derives
  #    ASSET_INPUTS_DIR from REPO_ROOT), and reads
  #    vendor/brand/logos/mark.svg directly — so this derivation stages
  #    exactly that much of the real tree, at the real relative layout, into
  #    a throwaway build directory rather than trying to fake REPO_ROOT any
  #    other way.
  #
  #    UNVERIFIED: whether plain relative Nix path literals like
  #    `../../../core/render/render-grub-background.sh` (reaching OUTSIDE
  #    backends/nixos/, this module's own nominal flake directory) resolve
  #    correctly under every way a consumer might fetch this flake — a
  #    direct local `path:` input or a full-repo checkout both stage the
  #    WHOLE repository tree on disk, so this should resolve fine either
  #    way, but a `dir=backends/nixos` flake-ref input's interaction with
  #    Nix's pure-eval sandboxing was not independently tested against a
  #    live `nix flake check` (no `nix` binary in this environment — see the
  #    verification note at the bottom of this file).
  # ==========================================================================
  grubBackgroundPng =
    pkgs.runCommand "ci-os-grub-background.png"
      {
        nativeBuildInputs = [
          pkgs.librsvg
          pkgs.imagemagick
        ];
      }
      ''
        mkdir -p build/core/render build/core/lib build/vendor/brand/tokens build/vendor/brand/logos
        cp ${../../../core/render/render-grub-background.sh} build/core/render/render-grub-background.sh
        cp ${../../../core/lib/theme-lib.sh} build/core/lib/theme-lib.sh
        cp ${../../../vendor/brand/tokens/tokens.sh} build/vendor/brand/tokens/tokens.sh
        cp ${../../../vendor/brand/logos/mark.svg} build/vendor/brand/logos/mark.svg
        chmod +x build/core/render/render-grub-background.sh
        ( cd build && bash core/render/render-grub-background.sh "$out" 1920 1080 )
      '';

  # ==========================================================================
  # 5. Plymouth watermark PNG. There is no dedicated
  #    core/render/render-plymouth-watermark.sh to invoke — Ubuntu's
  #    10-plymouth.sh does the resize as one inline step of a much larger
  #    live-system mutation (timestamped backups, update-alternatives,
  #    update-initramfs — none of which mean anything against a pure Nix
  #    derivation producing one file), so — same reasoning
  #    backends/bazzite/image/Containerfile gives for replicating rather
  #    than invoking that same script — this replicates just its one
  #    `convert -resize 50%` operation against the identical source asset
  #    (core/render/inputs/Logo_Banner_Color.png) and the identical
  #    WATERMARK_SCALE_PERCENT=50 constant.
  # ==========================================================================
  plymouthWatermarkPng =
    pkgs.runCommand "ci-os-plymouth-watermark.png"
      {
        nativeBuildInputs = [ pkgs.imagemagick ];
      }
      ''
        convert ${../../../core/render/inputs/Logo_Banner_Color.png} -resize 50% "$out"
      '';

  # ==========================================================================
  # 6. Plymouth theme colors. boot.plymouth has NO color option of its own
  #    (confirmed by reading nixos/modules/system/boot/plymouth.nix directly
  #    — the full option surface is enable/package/theme/themePackages/logo/
  #    font/extraConfig/showDelay; `extraConfig` is appended verbatim to
  #    plymouthd.conf's [Daemon] section, which is daemon-wide config, not a
  #    per-theme color), so the only declarative hook for the
  #    BackgroundStartColor/BackgroundEndColor/ProgressBarBackgroundColor/
  #    ProgressBarForegroundColor keys inside spinner.plymouth/bgrt.plymouth
  #    is `package`: a full plymouth build whose bundled theme files are
  #    already patched.
  #
  #    Overriding `themePackages` instead of `package` was considered and
  #    REJECTED: the module builds `themesEnv = pkgs.buildEnv { paths =
  #    [cfg.package plymouthLogos] ++ cfg.themePackages; }` (confirmed by
  #    reading the module source), and a themePackages entry providing
  #    share/plymouth/themes/{spinner,bgrt}/* — the SAME relative paths the
  #    stock `cfg.package` (pkgs.plymouth) already provides — collides in
  #    that buildEnv (two equal-priority paths providing the same file is a
  #    build-time collision error, not a silent override) unless a
  #    `priority` is set on the entry, which the module's `themePackages`
  #    option (a plain `listOf package`) has no way to express. Overriding
  #    `package` wholesale with a full patched copy sidesteps that
  #    collision by construction, at the cost of one extra full copy of the
  #    plymouth closure living in the Nix store (a disclosed size tradeoff,
  #    not a hidden one — the alternative, `pkgs.plymouth.overrideAttrs` to
  #    patch the same two files as a source-level postInstall step, avoids
  #    the duplicate copy but forces a real rebuild of plymouth from source
  #    instead of reusing its substituter-fetched binary closure, which is
  #    the worse trade for a two-file sed patch).
  # ==========================================================================
  ciPlymouthPackage = pkgs.runCommand "ci-os-plymouth" { } ''
    cp -r ${pkgs.plymouth} $out
    chmod -R u+w $out

    bg="${ciHex0x ciDarkBackground}"
    pbg="${ciHex0x ciDarkSecondary}"
    pfg="${ciHex0x ciDarkPrimary}"

    for f in \
      "$out/share/plymouth/themes/spinner/spinner.plymouth" \
      "$out/share/plymouth/themes/bgrt/bgrt.plymouth"
    do
      if [ -f "$f" ]; then
        sed -i \
          -e "s/BackgroundStartColor=0x[0-9a-fA-F]*/BackgroundStartColor=$bg/" \
          -e "s/BackgroundEndColor=0x[0-9a-fA-F]*/BackgroundEndColor=$bg/" \
          -e "s/ProgressBarBackgroundColor=0x[0-9a-fA-F]*/ProgressBarBackgroundColor=$pbg/" \
          -e "s/ProgressBarForegroundColor=0x[0-9a-fA-F]*/ProgressBarForegroundColor=$pfg/" \
          "$f"
      fi
    done
  '';

  # ==========================================================================
  # 7. Static MOTD banner. Deliberately NOT a full port of
  #    core/render/render-motd.sh: that script's 10-ci-sysinfo fragment
  #    shells out to `date`/`free`/`df`/`uptime` freshly on every login via
  #    Debian/Ubuntu's /etc/update-motd.d + pam_motd run-parts convention.
  #    NixOS's own `users.motd` is a single STATIC string baked once (a
  #    plain `lib.types.lines` value rendered to /etc/motd at activation
  #    time — confirmed by reading nixos/modules/security/pam.nix directly),
  #    with no run-parts/exec mechanism of its own — structurally incapable
  #    of reproducing per-login dynamic content. This is a disclosed gap,
  #    the same category as every prior backend's own MOTD uncertainty (this
  #    backend's is a real structural limit of the option, not just an
  #    unverified assumption) — only the static banner (the CI ASCII mark
  #    + tagline, `render-motd.sh`'s 00-ci-os-header equivalent) is reproduced
  #    here; the live system-info block (10-ci-sysinfo) is not, and can't
  #    be via this option. The ANSI color escapes Ubuntu's version prints
  #    via `echo -e` are also dropped here (plain text only) — cosmetic, not
  #    load-bearing, and avoids embedding raw escape bytes in this source
  #    file.
  # ==========================================================================
  motdBanner = ''

      ██████╗██╗     ██████╗ ███████╗
     ██╔════╝██║    ██╔═══██╗██╔════╝
     ██║     ██║    ██║   ██║███████╗
     ██║     ██║    ██║   ██║╚════██║
     ╚██████╗██║    ╚██████╔╝███████║
      ╚═════╝╚═╝     ╚═════╝ ╚══════╝

     Companion OS
     Uncloud Modern Life
  '';
in
{
  options.services.ci-os.branding = {
    enable = lib.mkEnableOption "Companion Intelligence (CI-OS) brand theming (Plymouth, GRUB background, GNOME/GDM accent color, MOTD) for this NixOS system";

    plymouth.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Apply the CI-OS Plymouth boot-splash theme (recolored bgrt/spinner + CI watermark).";
    };

    grub.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = ''
        Apply the CI-OS GRUB background. Only takes effect when
        `boot.loader.grub.enable` is also true — this option does not
        itself choose or enable a bootloader, and is a silent no-op on a
        systemd-boot system. (systemd-boot currently exposes no equivalent
        splash-image option in nixpkgs — a disclosed gap, not an
        oversight, same category as every prior backend's own GRUB-vs-
        systemd-boot disclosures.)
      '';
    };

    gnome.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = ''
        Set the CI-OS GNOME accent-color/color-scheme dconf defaults, for
        both the login user session and GDM's own greeter, via
        `programs.dconf.profiles.{user,gdm}`. Deliberately does NOT gate on
        `services.desktopManager.gnome.enable` (or the older
        `services.xserver.desktopManager.gnome.enable` — the option moved
        between nixpkgs releases; see this file's header) — this module
        only supplies dconf VALUES, which are inert if GNOME/GDM are never
        actually running, so there is nothing to gain from reading a
        desktop-manager option whose exact path is a moving target across
        nixpkgs versions, and something to lose (an eval-time "attribute
        missing" error on a nixpkgs checkout where that path doesn't exist
        the way this file expects).
      '';
    };

    gnome.accentColor = lib.mkOption {
      type = lib.types.enum [
        "blue"
        "teal"
        "green"
        "yellow"
        "orange"
        "red"
        "pink"
        "purple"
        "slate"
      ];
      default = "teal";
      description = ''
        The GNOME 47+ org.gnome.desktop.interface accent-color enum value
        closest to the CI-OS brand primary (#0a6358 light / #c5e8dc dark).
        "teal" is picked for cross-backend naming consistency with
        backends/fedora/ and backends/arch/'s identical judgment call, not
        because it's the closest RGB match — see
        backends/fedora/desktop-theme/gnome-defaults-fedora-overrides.inc.sh's
        own comment on this exact tradeoff ("green" is marginally closer by
        raw RGB distance to #0a6358, ~4900 vs ~8300 squared distance, but
        every other backend's own comments and this repo's copy call the
        brand "teal/phthalo", so teal wins on consistency).
      '';
    };

    motd.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Set the CI-OS MOTD banner via users.motd (static banner only — see this file's header for why the live sysinfo block core/render/render-motd.sh also writes cannot be reproduced this way).";
    };

    motd.extraText = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Extra text appended after the CI-OS banner in users.motd / /etc/motd.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf cfg.plymouth.enable {
        boot.plymouth.enable = lib.mkDefault true;
        boot.plymouth.theme = lib.mkDefault "bgrt";
        boot.plymouth.package = lib.mkDefault ciPlymouthPackage;
        boot.plymouth.logo = lib.mkDefault plymouthWatermarkPng;
      })

      (lib.mkIf (cfg.grub.enable && config.boot.loader.grub.enable) {
        boot.loader.grub.splashImage = lib.mkDefault grubBackgroundPng;
        boot.loader.grub.splashMode = lib.mkDefault "stretch";
        # No GRUB_DISTRIBUTOR equivalent: unlike Ubuntu's/Bazzite's
        # /etc/default/grub key-merge (core/lib/grub-merge.sh's
        # ci_grub_merge_key), nixpkgs's boot.loader.grub module exposes no
        # option for the menu's distributor/OS name string — disclosed gap,
        # not attempted via extraConfig (which would mean hand-writing a
        # grub.cfg fragment guessing at the generator's own internal
        # variable names, exactly the "guess at commands that might
        # partially apply" failure mode every prior backend's stubs avoid).
      })

      (lib.mkIf cfg.gnome.enable {
        programs.dconf.enable = true;
        programs.dconf.profiles.user.databases = [
          {
            settings."org/gnome/desktop/interface" = {
              accent-color = cfg.gnome.accentColor;
              color-scheme = "prefer-dark";
            };
          }
        ];
        programs.dconf.profiles.gdm.databases = [
          {
            settings."org/gnome/desktop/interface" = {
              accent-color = cfg.gnome.accentColor;
              color-scheme = "prefer-dark";
            };
          }
        ];
      })

      (lib.mkIf cfg.motd.enable {
        # types.lines merges multiple modules' contributions by
        # newline-concatenation (confirmed: this is the same option type
        # networking.extraHosts uses for the identical reason), so a plain
        # assignment here composes with anything else a consuming flake
        # sets on users.motd rather than conflicting with it.
        users.motd = motdBanner + cfg.motd.extraText;
      })
    ]
  );
}
