# core/

Distro-agnostic pieces of CI-OS: things that are true regardless of which base distro a
Companion Intelligence appliance image is built on.

- **`manifest/`** — the single source of truth for "what gets installed" (dev tools, LLM
  models, services, the CI-Hub deploy) as a declarative YAML file, plus a per-package-manager
  `role-map/` that translates generic role names into native package names. Every backend
  reads this instead of hardcoding its own tool list — see `manifest/ecosystem.yaml`.
- **`render/`** — turns `vendor/brand/tokens/` + `assets/` into portable rendered artifacts
  (a Plymouth theme, a GRUB background image, app icons, a wallpaper, a GNOME-Shell-style
  gresource) that any backend can install via its own native mechanism. This is where the
  token→color math lives, once, instead of being reimplemented per distro.
- **`lib/`** — genuinely distro-portable bash helpers (nothing here assumes apt/dnf/pacman).
- **`validate/`** — the portable half of theme validation; backend-specific checks
  (e.g. "does this file exist at this Ubuntu-specific path") stay in `backends/<distro>/`.
- **`headless/payload/`** — the captive-portal WiFi-onboarding Flask backend, static portal,
  and hostapd/dnsmasq configs. The payload itself is distro-portable; only the packaging
  wrapper (`.deb`, `.rpm`, `PKGBUILD`, ...) is backend-specific.

See `docs/architecture/multi-distro-design.md` for the full target layout across all six distro
backends (Ubuntu, Mint, Fedora, Arch, Bazzite, NixOS) and the rollout plan.
