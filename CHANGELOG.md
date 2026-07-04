# Changelog

All notable changes to CI-OS are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

#### Design system

The headless WiFi **setup portal** — the appliance's only user-facing surface — was
refactored onto the Companion Intelligence canonical design system. It remains a
**single-theme (dark) captive portal by design** (no light mode). All changes are
confined to `setup/headless/setup-device/var/www/setup-portal/index.html` plus docs
and CI; no runtime or packaging behavior changed.

- **Canonical CI teal primary.** `--primary` is now the CI teal — `#0f717a` (canon
  light) with `#abd4d8` (canon dark) as the hover/accent — replacing the previous
  bespoke portal palette. Bespoke CSS variables (`--bg-color` / `--card-bg` /
  `--primary-color` / `--field-radius`) were renamed to canonical token names
  (`--background` / `--card` / `--primary` / `--radius`).
- **Montserrat typography.** The portal now uses Montserrat, **vendored locally**
  (weights 200/400/500/600/700 as `woff2` under `fonts/`, with offline `@font-face`
  rules). No Google Fonts `<link>` is used — the captive portal must work with no
  internet access.
- **Enriched design tokens v0.2.0.** Added a fuller token set inlined into the portal
  stylesheet, mirroring the canonical `@companionintelligence/tokens` source (the
  offline portal inlines the values rather than depending on the npm package):
  - Brand **teal ramp** `--teal-50` … `--teal-950`.
  - **Aqua / mint accents** (`--aqua`, `--aqua-light`, `--mint`, plus `--teal-accent`,
    `--teal-mid`).
  - **Semantic status** tokens (`--success`, `--warning`, `--info`, each with a paired
    `-foreground`).
  - **Gradients** (`--gradient-brand`, `--gradient-hero`, `--gradient-aurora`) and an
    **elevation/shadow** scale (`--shadow-sm/-md/-lg`).
  - A **radius scale** (`--radius-sm` … `--radius-2xl`) derived from `--radius`.

### Added

- **Design-canon lint gate.** `scripts/lint-canon.mjs` (zero-dependency, Node
  built-ins only) fails CI if any resolvable `--primary` value is not CI teal in any
  color notation (hex/rgb/hsl/bare-hsl-triplet/oklch/oklab), and warns on hardcoded
  hex in component source. Wired up as the **Style canon lint** workflow
  (`.github/workflows/style-canon-lint.yml`) on pull_request and push.
- **Refreshed UI screenshots.** README now carries a screen-by-screen gallery of the
  setup portal on the CI teal design system — pairing form, network scan results,
  manual entry, no-pairing variant, success, and error states. All are genuine
  headless renders of the shipped portal (`docs/ui/setup-portal-*-dark.png`); the
  gallery is **dark-only**, matching the portal's single-theme design.

[Unreleased]: https://github.com/companionintelligence/CI-OS/compare/main...HEAD
