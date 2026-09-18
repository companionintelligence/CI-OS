# headless-setup.nix — CI-OS NixOS backend, WiFi-onboarding captive portal.
#
# © Companion Intelligence — Lifescope Inc
#
# NAMESPACE: `services.ci-os.headlessSetup.*` — see ecosystem.nix's header
# for the shared `services.ci-os.*` root this backend uses throughout.
#
# WHAT THIS TRANSLATES, AND THE ONE STRUCTURAL DECISION THAT SHAPES
# EVERYTHING ELSE IN THIS FILE
# ---------------------------------------------------------------------
# This is the NixOS translation of core/headless/payload/ (hostapd/dnsmasq
# configs, the nginx captive-portal site, the Flask/gunicorn setup-backend,
# and their four systemd units) plus backends/fedora/headless-setup/
# install.sh (read in full as the reference for how a prior backend stages
# this same payload). Read core/headless/payload/usr/local/bin/
# setup-device-hotspot-start.sh and setup-network-monitor.sh in full before
# changing this file — they are NOT incidental helper scripts, they are
# WHERE MOST OF THE ACTUAL BEHAVIOR LIVES, and that behavior is genuinely
# imperative in a way that changes what "wire this declaratively" can mean
# here:
#
#   setup-network-monitor.sh polls connectivity in a loop and, on loss,
#   calls setup-device-hotspot-start.sh, which: autodetects the real WiFi
#   interface via nmcli/iw (not a fixed name), generates a FRESH RANDOM
#   4-character SSID suffix EVERY TIME the hotspot starts, REWRITES
#   /etc/hostapd/hostapd-setup.conf and /etc/dnsmasq.d/setup-portal.conf in
#   place with that interface/SSID before starting hostapd-setup.service /
#   dnsmasq-setup.service, tells NetworkManager to unmanage the interface,
#   pauses CI-Hub's Traefik container to free port 80, and pre-scans WiFi
#   networks before switching the radio into AP mode (required by the
#   single-radio chips this hardware uses, which cannot scan once already
#   in AP mode).
#
# NONE of that is expressible as a NixOS module option evaluated once
# against a static config — it is runtime device-state orchestration. Two
# ways exist to handle that gap:
#   (a) Reimplement it as Nix-generated shell fragments (`preStart` hooks,
#       `ExecStartPre=`, etc.) — this would just be the same bash logic
#       moved into Nix string interpolation, with all the same runtime
#       behavior, but now a SECOND copy that can silently drift from
#       core/headless/payload/'s own, and no reduction in actual risk.
#   (b) Reuse the payload's own orchestration scripts BY PATH, unmodified,
#       staged into the Nix store — extending the EXACT principle this
#       phase's brief already applies to setup_service.py and
#       core/lib/ci-hub.sh ("do not rewrite the existing script") to the
#       two scripts that do the actual hotspot start/stop choreography too.
#
# This file uses (b). Concretely: `services.hostapd`/`services.dnsmasq`
# (nixpkgs' higher-level wrapper modules) are DELIBERATELY NOT used here —
# they would create their OWN differently-named units
# (`hostapd.service`/`dnsmasq.service`) with Nix-generated config at
# locations the reused orchestration scripts don't know about, silently
# losing the interface-autodetection/SSID-randomization/NetworkManager-
# unmanage/Traefik-pause behavior above. Instead, this module declares
# `systemd.services.hostapd-setup` / `.dnsmasq-setup` directly (via the
# NixOS module system's own `systemd.services.<name>` option — this IS
# "wired declaratively," just not through the higher-level wrapper module),
# matching backends/fedora's `hostapd-setup.service`/`dnsmasq-setup.service`
# unit shapes field-for-field, at the SAME `/etc/hostapd/hostapd-setup.conf`
# / `/etc/dnsmasq.d/setup-portal.conf` paths the reused scripts already
# target. This module SEEDS those paths with real, writable initial content
# rendered from its own options (`interface`/`ssid`/`passphrase`/
# `gatewayIp`/...) via `systemd.tmpfiles.rules`' `C` (copy-if-missing) type
# — NOT `environment.etc`, which would symlink into the read-only Nix
# store and make setup-device-hotspot-start.sh's own `cat > "$CONF" <<EOF`
# rewrite fail outright. The seed only matters before that script has ever
# run once; every later hotspot start overwrites it with the real,
# runtime-detected values, exactly as designed upstream.
#
# nginx, by contrast, genuinely IS served well by NixOS's native
# `services.nginx` declarative virtualHosts module (no runtime-rewrite
# behavior to preserve there — see the "nginx" section below) — so this
# file uses that, not a raw copied nginx.conf.
#
# THE "ALREADY PAIRED" GATE — NixOS-IDIOMATIC EQUIVALENT OF BAZZITE'S
# ONE-TIME MARKER-FILE DECISION (read this before touching pairingGate)
# ------------------------------------------------------------------------
# backends/bazzite/modules/ci-os-first-boot-setup-portal-gate.sh makes a
# ONE-TIME decision at first boot: if /var/lib/setup-device/hub.env already
# exists (the device was paired before this boot), `systemctl disable --now`
# all four portal units; otherwise `systemctl enable --now` them. It then
# writes its own marker file so it never re-decides on a later boot.
#
# NixOS modules are evaluated once against the consuming system's own
# DECLARED configuration, not "first boot" in that imperative sense — there
# is no natural place to run a Bazzite-style one-time decision script as
# part of activation without just reimplementing that same marker-file
# gate script inside Nix, gaining nothing structurally. Instead, this
# module uses systemd's own `ConditionPathExists=!<hubEnvFile>` directive
# (`services.ci-os.headlessSetup.pairingGate.hubEnvFile`, matching
# `core/headless/payload/opt/setup-backend/setup_service.py`'s own
# `save_hub_env()` target path) on all four portal units. This is a
# NATIVE systemd mechanism, re-evaluated by systemd on EVERY start attempt
# of a gated unit — not just at boot — which is arguably MORE correct than
# Bazzite's one-time decision, not merely a workaround for lacking one:
#   - A device paired LATER in its life automatically stops offering the
#     units the next time anything would start them (e.g. after a reboot),
#     with no separate re-evaluation logic and no marker file to manage.
#   - A device manually UN-paired for a diagnostic reset (hub.env removed)
#     becomes startable again automatically, with zero additional code —
#     Bazzite's one-time gate would need its own marker file removed by
#     hand for the same recovery, exactly like its own log line documents.
#   - The one thing this trades away: a device that is ALREADY mid-hotspot
#     broadcast at the exact instant hub.env first appears (pairing just
#     succeeded through the portal's own API call) is not retroactively
#     torn down by ConditionPathExists alone — Condition directives are
#     evaluated only at unit START, not against an already-running unit.
#     This is not a regression versus the bash backends: that live
#     teardown was never this gate's job on ANY backend — it's
#     setup_service.py's own `/api/configure` success path
#     (setup-network-monitor.sh's own comment: "monitor NEVER stops the
#     hotspot; only /api/configure does on success"), unmodified here
#     either way.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.ci-os.headlessSetup;

  # core/headless/payload/ — staged whole into the Nix store. See this
  # file's header for why the imperative orchestration scripts inside it
  # (setup-device-hotspot-start.sh, setup-network-monitor.sh, and friends)
  # are reused BY PATH rather than reimplemented, the same principle
  # already applied to setup_service.py and core/lib/ci-hub.sh.
  payloadSrc = ../../../core/headless/payload;

  # The imperative helper scripts setup-network-monitor.service (and, via
  # it, hostapd-setup/dnsmasq-setup) actually invoke, staged as a proper
  # derivation with explicit, correct executable permissions (rather than
  # depending on whatever mode bit the repo checkout happens to carry —
  # backends/fedora/headless-setup/install.sh has to `chmod 755` these
  # after `cp -r` for the same reason).
  #
  # TWO scripts are DELIBERATELY NOT staged here, both disclosed rather
  # than silently dropped:
  #   - `get-device-id.ts`: a standalone manual dev helper
  #     (`pnpm exec tsx scripts/get-device-id.ts`), not invoked by any
  #     systemd unit or by setup_service.py itself (verified by reading
  #     setup_service.py in full — it computes DEVICE_ID with its own
  #     Python, not by shelling out to this script). Simply out of scope.
  #   - `ci-os-post-validation.sh`: THIS ONE MATTERS. Read by this pass —
  #     it is Ubuntu-ISO-specific, not merely Ubuntu-flavored: on missing
  #     its preferred staged-bootstrap ROCm script, its fallback path
  #     `curl`s an Ubuntu apt-based ROCm installer from
  #     raw.githubusercontent.com and runs it with `bash` unconditionally.
  #     Unlike ci-os-hub-start.sh's PROVISION_SH gap (a harmless no-op —
  #     see ecosystem.nix's ci-os-hub-deploy-trigger comment), staging
  #     this script would mean setup_service.py's post-pairing flow (which
  #     calls ci-os-hub-start.sh, which in turn launches this script in
  #     the background whenever it's present and executable at
  #     /usr/local/bin/) ACTIVELY attempts to download and execute a
  #     foreign distro's package-manager script on a NixOS box — not a
  #     quiet no-op, an actively wrong action for this backend, even
  #     though it would likely just fail loudly (no apt-get) rather than
  #     corrupt anything. Both things it does (ROCm, Ollama models) are
  #     already handled correctly and natively by
  #     services.ci-os.ecosystem's own `hardware.rocm.enable` and
  #     `ollama.pullModels.enable` — this script would be pure downside
  #     here. Leaving it unstaged means ci-os-hub-start.sh's own
  #     `[ -x /usr/local/bin/ci-os-post-validation.sh ]` guard correctly
  #     skips it, the same "documented gap, not a guess at commands that
  #     could partially apply" discipline this repo already applies
  #     elsewhere (e.g. every stubbed install_rocm_driver_*()).
  ciOsHeadlessBin = pkgs.runCommand "ci-os-headless-bin" { } ''
    mkdir -p $out/bin
    for f in \
      setup-device-hotspot-start.sh \
      setup-network-monitor.sh \
      setup-hotspot-reset.sh \
      setup-wifi-recover \
      ci-os-hub-start.sh \
    ; do
      install -m0755 ${payloadSrc}/usr/local/bin/"$f" $out/bin/"$f"
    done
    install -m0755 ${payloadSrc}/usr/local/bin/setup-device-prescan.py $out/bin/setup-device-prescan.py
  '';

  # opt/setup-backend/ (setup_service.py + scripts/) staged whole, reused
  # BY PATH and unmodified — gunicorn is pointed at it via --chdir below,
  # so no /opt symlink is needed at all (setup_service.py only reads
  # absolute paths under /etc/setup-device and /var/lib/setup-device,
  # confirmed by reading it in full — no cwd-relative behavior depends on
  # living at literally /opt/setup-backend).
  ciOsSetupBackend = pkgs.runCommand "ci-os-setup-backend" { } ''
    cp -r ${payloadSrc}/opt/setup-backend $out
  '';

  pythonForSetupBackend = pkgs.python3.withPackages (ps: [ ps.flask ps.gunicorn ]);

  # ---- Rendered config seeds -------------------------------------------
  # Real, writable INITIAL content for the paths
  # setup-device-hotspot-start.sh rewrites at runtime — see this file's
  # header for why these are systemd.tmpfiles 'C' (copy-if-missing) seeds,
  # not environment.etc symlinks. Values come from this module's own
  # options, so they're not just a second hardcoded copy of the payload's
  # own static defaults.
  hostapdConfSeed = pkgs.writeText "hostapd-setup.conf" ''
    # HostAPD configuration for the setup-mode hotspot — INITIAL SEED ONLY,
    # rendered by CI-OS's NixOS headless-setup module from
    # services.ci-os.headlessSetup.* options. setup-device-hotspot-start.sh
    # (core/headless/payload, reused by path) OVERWRITES this file at every
    # hotspot start with an autodetected interface and a fresh random SSID
    # suffix — see backends/nixos/modules/headless-setup.nix's header.
    interface=${cfg.interface}
    driver=nl80211
    ssid=${cfg.ssid}
    wpa=2
    wpa_passphrase=${cfg.passphrase}
    wpa_key_mgmt=WPA-PSK
    wpa_pairwise=CCMP
    rsn_pairwise=CCMP
    hw_mode=g
    channel=6
    max_num_sta=10
    country_code=US
    ieee80211n=1
    ht_capab=[SHORT-GI-20]
    ieee80211ax=0
    wps_state=0
    logger_syslog=-1
    logger_syslog_level=2
    logger_stdout=-1
    logger_stdout_level=2
  '';

  dnsmasqConfSeed = pkgs.writeText "setup-portal.conf" ''
    # DNSmasq configuration for the setup portal — INITIAL SEED ONLY, same
    # runtime-overwrite caveat as hostapd-setup.conf above.
    interface=${cfg.interface}
    bind-interfaces
    dhcp-range=${cfg.dhcpRangeStart},${cfg.dhcpRangeEnd},255.255.255.0,12h
    dhcp-option=3,${cfg.gatewayIp}
    dhcp-option=6,${cfg.gatewayIp}
    dhcp-option=option:dns-server,${cfg.gatewayIp}
    no-resolv
    no-poll
    address=/${cfg.captivePortalDomain}/${cfg.gatewayIp}
    address=/captive.apple.com/${cfg.gatewayIp}
    address=/gstatic.com/${cfg.gatewayIp}
    address=/www.msftconnecttest.com/${cfg.gatewayIp}
    address=/connectivitycheck.gstatic.com/${cfg.gatewayIp}
    address=/connectivitycheck.android.com/${cfg.gatewayIp}
    address=/clients3.google.com/${cfg.gatewayIp}
    address=/www.google.com/${cfg.gatewayIp}
    address=/detectportal.firefox.com/${cfg.gatewayIp}
    address=/#/${cfg.gatewayIp}
    log-queries
    log-facility=/var/log/dnsmasq-setup.log
  '';

  deviceConfSeed = pkgs.writeText "device.conf" ''
    # Setup Device Configuration — INITIAL SEED ONLY (systemd.tmpfiles 'C':
    # copy-if-missing), rendered from services.ci-os.headlessSetup.*
    # options. A hand-edit after first deploy persists across rebuilds
    # unless the file is deleted.
    SERIAL_SUFFIX=

    SETUP_GATEWAY=${cfg.gatewayIp}

    PAIRING_CODE_FILE=/var/lib/setup-device/pairing-code
    SETUP_COMPLETE_FILE=/var/lib/setup-device/setup-complete
    CREDENTIALS_FILE=/var/lib/setup-device/credentials
    LOG_FILE=/var/log/setup-backend.log

    CI_CLOUD_API_URL=${cfg.cloudApiUrl}
    CI_ZONE_ID=${cfg.zoneId}
  '';

  # The four core/headless/payload systemd units this module is
  # responsible for gating identically — kept as one list so the
  # pairing-gate ConditionPathExists is applied uniformly instead of
  # risking the four `systemd.services.*` blocks below drifting out of
  # sync with each other over time.
  pairingGateCondition =
    lib.mkIf cfg.pairingGate.enable "!${cfg.pairingGate.hubEnvFile}";
in
{
  options.services.ci-os.headlessSetup = {
    enable = lib.mkEnableOption ''
      the WiFi-onboarding captive portal (core/headless/payload/):
      hostapd + dnsmasq hotspot, the Flask/gunicorn setup-backend, and the
      nginx-served static portal + CI-Hub proxy.'';

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wlp192s0";
      description = ''
        Wireless interface hostapd/dnsmasq's SEED config binds to (see
        `hostapdConfSeed`/`dnsmasqConfSeed` above). The default matches
        core/headless/payload/hostapd/hostapd-setup.conf's own hardcoded
        value (the reference Mediatek MT7925 module this payload was
        authored against) — override it if your hardware differs.
        setup-device-hotspot-start.sh (reused by path) autodetects the
        real interface at every hotspot start and rewrites the live config
        accordingly regardless of this seed, once it has run at least
        once — see this file's header.
      '';
    };

    ssid = lib.mkOption {
      type = lib.types.str;
      default = "Companion-Setup";
      description = "SEED SSID (see `interface`'s doc comment for the runtime-overwrite caveat).";
    };

    passphrase = lib.mkOption {
      type = lib.types.str;
      default = "SetupDevice123";
      description = ''
        WPA2-PSK passphrase for the setup hotspot's SEED config. THIS IS
        THE SAME DEFAULT VALUE core/headless/payload/hostapd/
        hostapd-setup.conf already ships in plaintext — a pre-existing
        property of the payload, not introduced by this module. Override
        it (ideally via a secret-management tool such as sops-nix/agenix
        rather than a plain string literal in your own flake) for
        anything beyond local development.
      '';
    };

    gatewayIp = lib.mkOption {
      type = lib.types.str;
      default = "192.168.99.1";
      description = "Gateway/DNS-redirect-target IP for the setup network, matching the payload's own hardcoded value.";
    };

    dhcpRangeStart = lib.mkOption {
      type = lib.types.str;
      default = "192.168.99.10";
    };

    dhcpRangeEnd = lib.mkOption {
      type = lib.types.str;
      default = "192.168.99.250";
    };

    captivePortalDomain = lib.mkOption {
      type = lib.types.str;
      default = "setup.ci.computer";
      description = "Hostname the portal answers to; also added to networking.extraHosts pointing at gatewayIp.";
    };

    cloudApiUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://portal.companionintelligence.com/api/";
      description = "Rendered into device.conf's CI_CLOUD_API_URL (setup_service.py reads this, or the CI_CLOUD_API_URL env var, falling back to this same literal itself).";
    };

    zoneId = lib.mkOption {
      type = lib.types.str;
      default = "2b77d4360dbd4a9ccdad5c8d947323c9";
      description = "Rendered into device.conf's CI_ZONE_ID, matching core/headless/payload/setup-device-defaults/device.conf's own default.";
    };

    pairingGate = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Gate all four portal units (hostapd-setup, dnsmasq-setup,
          setup-backend, setup-network-monitor) behind
          `ConditionPathExists=!hubEnvFile` — see this file's header,
          "THE 'ALREADY PAIRED' GATE" section, for the full reasoning.
          Disable only if you have some other mechanism managing when the
          onboarding portal should run (e.g. an appliance that is never
          field-paired at all).
        '';
      };
      hubEnvFile = lib.mkOption {
        # STRING, not `lib.types.path` — matching
        # services.ci-os.ecosystem.ciHub.pairingEnvironmentFile's own type
        # (see that option's comment for the full reasoning). This
        # specific path never exists at Nix evaluation time on the build
        # machine (it's written by the target device at runtime, after
        # pairing), so a path literal here would fail eval outright with
        # "path does not exist" — worse UX than the anti-pattern risk
        # itself, but the same underlying type mismatch: this value is a
        # runtime filesystem fact for `ConditionPathExists` to check, never
        # something Nix itself should resolve or copy.
        type = lib.types.str;
        default = "/var/lib/setup-device/hub.env";
        description = ''
          Must match services.ci-os.ecosystem.ciHub.pairingEnvironmentFile
          — both point at the same file setup_service.py's save_hub_env()
          writes. Kept as two separate options (not a single shared one)
          because ecosystem.nix and this module are independently
          importable; they agree on the same default literal instead.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # ---- /etc seeds (writable — see header for why NOT environment.etc) ----
    #
    # The "L+ /usr/local/bin/..." rules below exist for a SPECIFIC reason,
    # not just convenience: setup-network-monitor.sh, setup-device-hotspot-
    # start.sh, setup-hotspot-reset.sh, ci-os-hub-start.sh, and even
    # setup_service.py ITSELF (verified by reading it —
    # `subprocess.run(['/usr/local/bin/setup-device-hotspot-start.sh'], ...)`
    # / `['/usr/local/bin/ci-os-hub-start.sh']`) all invoke each other by
    # HARDCODED ABSOLUTE PATH under /usr/local/bin/, not via PATH lookup.
    # `environment.systemPackages` (below) only puts `ciOsHeadlessBin/bin/*`
    # on the general PATH (`/run/current-system/sw/bin/`) — it does NOT
    # populate literal `/usr/local/bin/`, which NixOS leaves alone by
    # design for exactly this kind of FHS-compatibility use. These symlink
    # rules are what makes those hardcoded absolute-path calls resolve at
    # all; without them, every cross-script call above would fail with "No
    # such file or directory" the first time it actually ran.
    systemd.tmpfiles.rules = [
      "d /etc/hostapd 0755 root root -"
      "d /etc/dnsmasq.d 0755 root root -"
      "d /etc/setup-device 0700 root root -"
      "d /var/lib/setup-device 0755 root root -"
      "d /usr/local/bin 0755 root root -"
      "C /etc/hostapd/hostapd-setup.conf 0644 root root - ${hostapdConfSeed}"
      "C /etc/dnsmasq.d/setup-portal.conf 0644 root root - ${dnsmasqConfSeed}"
      "C /etc/setup-device/device.conf 0600 root root - ${deviceConfSeed}"
      "L+ /usr/local/bin/setup-device-hotspot-start.sh - - - - ${ciOsHeadlessBin}/bin/setup-device-hotspot-start.sh"
      "L+ /usr/local/bin/setup-network-monitor.sh - - - - ${ciOsHeadlessBin}/bin/setup-network-monitor.sh"
      "L+ /usr/local/bin/setup-hotspot-reset.sh - - - - ${ciOsHeadlessBin}/bin/setup-hotspot-reset.sh"
      "L+ /usr/local/bin/setup-wifi-recover - - - - ${ciOsHeadlessBin}/bin/setup-wifi-recover"
      "L+ /usr/local/bin/ci-os-hub-start.sh - - - - ${ciOsHeadlessBin}/bin/ci-os-hub-start.sh"
      "L+ /usr/local/bin/setup-device-prescan.py - - - - ${ciOsHeadlessBin}/bin/setup-device-prescan.py"
    ];

    networking.extraHosts = "${cfg.gatewayIp} ${cfg.captivePortalDomain}\n";

    # ---- hostapd-setup / dnsmasq-setup --------------------------------------
    # Declared directly via systemd.services (not nixpkgs' higher-level
    # services.hostapd/services.dnsmasq wrapper modules) — see this file's
    # header for why. Deliberately NOT wantedBy multi-user.target: these
    # are started imperatively, by unit name, from
    # setup-network-monitor.sh (via `systemctl start hostapd-setup.service`
    # / `dnsmasq-setup.service`) only once connectivity is actually lost —
    # exactly matching this payload's own log line ("hostapd-setup/
    # dnsmasq-setup only start once setup-network-monitor detects no
    # connectivity"). backends/fedora/headless-setup/install.sh's
    # `systemctl enable hostapd-setup.service` (which WOULD also
    # autostart it at every boot via multi-user.target, contradicting that
    # same script's own log line) is a pre-existing inconsistency in that
    # bash backend that this module does not repeat.
    systemd.services.hostapd-setup = {
      description = "HostAP daemon for setup mode hotspot";
      after = [ "network.target" ];
      before = [ "dnsmasq-setup.service" ];
      wants = [ "network.target" ];
      unitConfig.ConditionPathExists = pairingGateCondition;
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.hostapd}/bin/hostapd /etc/hostapd/hostapd-setup.conf";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.dnsmasq-setup = {
      description = "DNSmasq for setup portal DHCP and DNS";
      after = [ "hostapd-setup.service" "network.target" ];
      requires = [ "hostapd-setup.service" ];
      unitConfig.ConditionPathExists = pairingGateCondition;
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --no-daemon -C /etc/dnsmasq.d/setup-portal.conf";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # ---- setup-network-monitor -----------------------------------------------
    # The one unit in this set that IS wantedBy multi-user.target — it is
    # the always-on watcher that decides, at runtime, whether to start the
    # two units above (see this file's header). Runs as root (no User=),
    # matching the original unit file, since it needs `ip link`/`nmcli
    # device set ... managed no`/`docker stop traefik` privileges.
    systemd.services.setup-network-monitor = {
      description = "Setup Device Network Monitor";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = pairingGateCondition;
      path = with pkgs; [
        networkmanager
        iproute2
        iputils
        rfkill
        util-linux
        docker
        systemd
        coreutils
        gnugrep
        gawk
      ];
      serviceConfig = {
        Type = "simple";
        # ciOsHeadlessBin/bin is also on environment.systemPackages (below),
        # so setup-network-monitor.sh's own
        # `/usr/local/bin/setup-device-hotspot-start.sh` absolute-path call
        # resolves whether or not it's additionally invoked via this
        # unit's own PATH.
        ExecStart = "${ciOsHeadlessBin}/bin/setup-network-monitor.sh";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # ---- setup-backend (Flask/gunicorn, reused by path) ----------------------
    systemd.services.setup-backend = {
      description = "Setup Device Backend Service";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = pairingGateCondition;
      path = with pkgs; [ networkmanager dmidecode coreutils inetutils ];
      environment.PYTHONUNBUFFERED = "1";
      serviceConfig = {
        Type = "simple";
        User = "root";
        WorkingDirectory = "${ciOsSetupBackend}";
        ExecStart = "${pythonForSetupBackend}/bin/gunicorn --bind 127.0.0.1:5000 --workers 1 --threads 2 --timeout 120 --access-logfile - --error-logfile - setup_service:app";
        Restart = "on-failure";
        RestartSec = 5;
        KillMode = "mixed";
        KillSignal = "SIGTERM";
        TimeoutStopSec = 30;
      };
    };

    # ---- /usr/local/bin equivalents, for manual/admin use --------------------
    # setup-wifi-recover, setup-hotspot-reset.sh, ci-os-post-validation.sh
    # are meant to be run by hand (see their own headers: "Run when: sudo
    # setup-wifi-recover"); ci-os-hub-start.sh and
    # setup-device-prescan.py are invoked by the other reused scripts
    # above via ciOsHeadlessBin directly. Putting the whole bin/ on PATH
    # covers both.
    environment.systemPackages = [ ciOsHeadlessBin ];

    # ---- nginx: genuinely fits NixOS's native declarative module here -------
    # Unlike hostapd/dnsmasq, nothing rewrites nginx's config at runtime —
    # services.nginx's declarative virtualHosts are a direct, faithful fit
    # for core/headless/payload/nginx/sites-available/setup-portal's two
    # server blocks, ported as data (locations/proxyPass/extraConfig)
    # rather than by copying the raw conf file, the same way this module
    # renders hostapd/dnsmasq's SEED content from options above instead of
    # blindly `cp`-ing the payload's static defaults. `root` points
    # directly at the payload's static portal assets IN THE NIX STORE
    # (read-only, which is exactly what static served files should be —
    # no copy needed, unlike setup-backend's Python code, which gunicorn
    # needs a --chdir-able directory for).
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;

      virtualHosts."ci-os-setup-portal" = {
        default = true;
        serverName = cfg.captivePortalDomain;
        listen = [
          { addr = "0.0.0.0"; port = 80; }
          { addr = "[::]"; port = 80; }
        ];
        root = "${payloadSrc}/var/www/setup-portal";
        extraConfig = ''
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-XSS-Protection "1; mode=block" always;
          add_header Referrer-Policy "no-referrer" always;
          access_log /var/log/nginx/setup-portal-access.log;
          error_log /var/log/nginx/setup-portal-error.log;
        '';
        locations = {
          "/hotspot-detect.html".extraConfig = "return 302 http://${cfg.gatewayIp}/;";
          "/connecttest.txt".extraConfig = "return 302 http://${cfg.gatewayIp}/;";
          "/ncsi.txt".extraConfig = "return 302 http://${cfg.gatewayIp}/;";
          "/generate_204".extraConfig = "return 302 http://${cfg.gatewayIp}/;";
          "= /canonical.html".extraConfig = "return 302 http://${cfg.gatewayIp}/;";
          "= /success.txt".extraConfig = "return 302 http://${cfg.gatewayIp}/;";

          "= /" = {
            tryFiles = "$uri $uri/ /index.html";
            extraConfig = ''
              add_header Cache-Control "no-store, no-cache, must-revalidate";
              add_header Pragma "no-cache";
            '';
          };

          "/api/" = {
            proxyPass = "http://127.0.0.1:5000";
          };

          "/" = {
            tryFiles = "$uri $uri/ /index.html";
            extraConfig = ''
              add_header Cache-Control "no-store, no-cache, must-revalidate";
            '';
          };
        };
      };

      # CI OS Hub proxy — <captivePortalDomain>:5002 -> Hub (when on the
      # setup network), matching the payload's own second server block.
      virtualHosts."ci-os-hub-proxy" = {
        serverName = cfg.captivePortalDomain;
        listen = [
          { addr = "0.0.0.0"; port = 5002; }
          { addr = "[::]"; port = 5002; }
        ];
        locations."/" = {
          proxyPass = "http://127.0.0.1:5002";
          proxyWebsockets = true;
        };
      };
    };
  };
}
