# flake.nix — CI-OS NixOS backend (Phase 6) entry point.
#
# © Companion Intelligence — Lifescope Inc
#
# WHAT THIS BACKEND IS, AND WHY IT LOOKS NOTHING LIKE THE OTHER FIVE
# ----------------------------------------------------------------------
# Every other backends/<distro>/ tree (Ubuntu/Mint/Fedora/Arch: bash
# provisioning scripts run against an already-installed system; Bazzite: a
# Containerfile building one shared OCI image) produces something you RUN
# or BUILD once. This backend produces NEITHER a script nor an image — it
# produces REUSABLE NIX CODE: a flake exposing NixOS modules
# (`nixosModules.*`) that a USER IMPORTS into their OWN NixOS system
# configuration flake, e.g.:
#
#   # a consumer's own flake.nix
#   {
#     inputs.ci-os-nixos.url = "github:companionintelligence/CI-OS?dir=backends/nixos";
#     # Recommended: pin this flake's nixpkgs to your own, so CI-OS's
#     # modules build against the exact same package set as the rest of
#     # your system (the standard reusable-flake convention — see the
#     # `inputs.nixpkgs` comment below).
#     inputs.ci-os-nixos.inputs.nixpkgs.follows = "nixpkgs";
#
#     outputs = { self, nixpkgs, ci-os-nixos, ... }: {
#       nixosConfigurations.my-companion-appliance = nixpkgs.lib.nixosSystem {
#         system = "x86_64-linux";
#         modules = [
#           ci-os-nixos.nixosModules.default
#           ./hardware-configuration.nix
#           {
#             services.ci-os.ecosystem.enable = true;
#             services.ci-os.ecosystem.hardware.rocm.enable = true;  # if applicable
#             services.ci-os.headlessSetup.enable = true;
#             services.desktopManager.gnome.enable = true;   # your own choice — this
#             # is the current (release-25.11+) option path; older nixpkgs
#             # revisions use services.xserver.desktopManager.gnome.enable
#             # instead (a deprecated but still-working compat alias) — see
#             # modules/branding.nix's own header for the full note.
#           }
#         ];
#       };
#     };
#   }
#
# There is no `--tier=`/`--step=` CLI, no ISO, no first-boot script to run
# by hand — `nixos-rebuild switch` (against the consumer's own
# `nixosConfigurations.<host>`) IS the deploy mechanism. See each module's
# own header (backends/nixos/modules/ecosystem.nix,
# backends/nixos/modules/headless-setup.nix) for what each actually wires.
#
# ISO/install-media building is NOT in scope for this phase (per
# docs/architecture/multi-distro-design.md's Rollout table and this
# phase's brief) — NixOS users very commonly consume a flake as a config
# import into an existing install, or via nixos-generators for whatever
# image format they need; that is a distinct, larger undertaking this
# flake does not attempt.
#
# MODULE NAMESPACE: `services.ci-os.*`
# ----------------------------------------
# `services.ci-os.branding.*` (Plymouth/GRUB/GDM-accent/MOTD — a SIBLING
# piece of work, see below), `services.ci-os.ecosystem.*` (this phase:
# Docker/dev-tools/Ollama/CI-Hub), `services.ci-os.headlessSetup.*` (this
# phase: WiFi-onboarding captive portal). Chosen to mirror how a consuming
# system already reads `services.tailscale.*`/`services.ollama.*` — a
# single shared root rather than three independent tops, matching the
# `numtide/srvos` convention of grouping a project's modules under one
# namespace even when they're independently importable. This choice is
# documented here so the branding.nix module (developed independently, in
# parallel, by a sibling task that cannot see this file) lands in the same
# namespace family — this flake does not, and cannot, enforce that on
# branding.nix's own content; it only imports whatever that module
# declares, under whatever options IT defines.
#
# BRANDING.NIX MAY NOT EXIST YET WHEN THIS FLAKE IS EVALUATED
# -----------------------------------------------------------------
# backends/nixos/modules/branding.nix is a sibling deliverable this task
# cannot see the final content of, and — depending on timing — may not
# exist on disk at all yet. This flake tolerates that: `nixosModules`
# exposes `ecosystem`/`headlessSetup` unconditionally, `branding` only if
# the file is present (`builtins.pathExists`, checked at eval time — no
# IFD, no network, no build step; a plain file-existence check, the same
# class of operation Nix's own `flake.lock` handling relies on), and
# `nixosModules.default` imports whichever of the three actually exist,
# emitting a `warnings`-list entry (visible on `nixos-rebuild switch`, not
# a build failure) when branding.nix is still missing. This means
# `ecosystem.nix`/`headless-setup.nix` (this task's actual deliverables)
# can be evaluated and checked independently of branding.nix's own
# progress, while `nixosModules.default` becomes complete automatically
# the moment branding.nix lands, with no edit to this file required.
{
  description = "CI-OS: Companion Intelligence appliance branding + ecosystem provisioning for NixOS (backends/nixos — Phase 6 of docs/architecture/multi-distro-design.md)";

  inputs = {
    # A consuming flake should typically override this via
    # `inputs.<this-flake>.inputs.nixpkgs.follows = "nixpkgs";` in its own
    # flake.nix, so CI-OS's modules evaluate against the exact same
    # package set as the rest of that system, rather than pulling in a
    # second, independently-pinned nixpkgs closure. The input declared
    # here is only the fallback used for standalone evaluation of THIS
    # flake (e.g. its own `nix flake check`, `devShells`, `checks`).
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      brandingModulePath = ./modules/branding.nix;
      hasBrandingModule = builtins.pathExists brandingModulePath;

      baseModules = {
        ecosystem = import ./modules/ecosystem.nix;
        headlessSetup = import ./modules/headless-setup.nix;
      };

      brandingModuleAttr =
        if hasBrandingModule
        then { branding = import brandingModulePath; }
        else { };

      defaultModule = { lib, ... }: {
        imports = [ baseModules.ecosystem baseModules.headlessSetup ]
          ++ lib.optional hasBrandingModule brandingModuleAttr.branding;
        warnings = lib.optional (!hasBrandingModule) ''
          CI-OS: backends/nixos/modules/branding.nix was not found when this
          flake was evaluated, so nixosModules.default does not include
          CI-OS's Plymouth/GRUB/GDM-accent/MOTD theming (only
          services.ci-os.ecosystem.* and services.ci-os.headlessSetup.* are
          active). Re-evaluate once branding.nix has landed, or import
          nixosModules.branding explicitly yourself if it exists but this
          warning is stale.
        '';
      };
    in
    {
      nixosModules = baseModules // brandingModuleAttr // {
        default = defaultModule;
      };

      # A convenience shell for iterating on this backend: regenerating
      # ../manifest/ecosystem.generated.json (see that script's own header
      # for why `yq-go`, not the unrelated python-yq of the same name),
      # and formatting/linting this flake's own .nix files.
      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.yq-go pkgs.jq pkgs.nixpkgs-fmt pkgs.statix pkgs.deadnix ];
          };
        });

      formatter = forAllSystems (system: (import nixpkgs { inherit system; }).nixpkgs-fmt);

      # A lightweight eval-time smoke check: builds a minimal
      # nixosSystem importing this backend's own modules with every option
      # (core, extended, both hardware toggles, headless-setup) turned on,
      # then FORCES (`builtins.deepSeq`) the entirety of the resulting
      # `config.services.ci-os` tree before the returned derivation can
      # even be constructed — so `nix flake check` (or realizing
      # `checks.<system>.default` any other way) cannot succeed without
      # every option default, every `tierOf`/`defaultForTool` lookup
      # against ../manifest/ecosystem.generated.json, and every
      # string/attrset this backend's two modules build having evaluated
      # without a Nix-level error somewhere in that tree. It deliberately
      # only forces `services.ci-os.*`, not the whole merged NixOS
      # `config` (e.g. not `config.systemd.services.*` or
      # `config.system.build.toplevel`) — that keeps the check scoped to
      # what THIS backend's own code is responsible for, and cheap (no
      # real package builds), at the cost of not verifying that every
      # `systemd.services`/`services.nginx`/etc. option NAME this backend
      # writes into actually exists on the pinned nixpkgs revision (a
      # typo there would only surface once the module system tries to
      # merge it against the real option declarations elsewhere in
      # nixpkgs, which THIS check does not force). This does NOT include
      # branding.nix (whether or not it currently exists — see this file's
      # own header) — it checks only what this task actually delivered.
      #
      # DISCLOSED: this check was authored and read closely for syntax and
      # logic, but COULD NOT BE RUN in the environment this backend was
      # built in — no `nix` binary was available (verified: `command -v
      # nix nix-instantiate nix-build` all failed). Run
      # `nix flake check ./backends/nixos` for real verification before
      # trusting this compiles or evaluates cleanly, matching Bazzite's own
      # precedent of disclosing exactly what could and couldn't be checked
      # without a working build host.
      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          evalResult = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              baseModules.ecosystem
              baseModules.headlessSetup
              {
                services.ci-os.ecosystem.enable = true;
                services.ci-os.ecosystem.extended.enable = true;
                services.ci-os.ecosystem.hardware.rocm.enable = true;
                services.ci-os.ecosystem.hardware.lact.enable = true;
                services.ci-os.headlessSetup.enable = true;
                nixpkgs.config.allowUnfree = true;
                fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
                boot.loader.grub.device = "nodev";
                system.stateVersion = "25.05";
              }
            ];
          };
        in
        {
          default = builtins.deepSeq evalResult.config.services.ci-os (
            pkgs.runCommand "ci-os-nixos-modules-eval-check" { } ''
              echo "services.ci-os.{ecosystem,headlessSetup} evaluated without a Nix-level error for ${system}" > $out
            ''
          );
        });
    };
}
