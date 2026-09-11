# CI-OS brand — pointer

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

The Companion Intelligence brand is defined once, in **CI-Common**:
[`styles/UI-STYLE-GUIDE.md`](https://github.com/companionintelligence/CI-Common/blob/main/styles/UI-STYLE-GUIDE.md)
(the written design system) and `@companionintelligence/tokens`
(`styles/tokens/src/tokens.json`, the one hand-edited token file). This repo does
not restate it. Every colour the OS theming scripts use is a `CI_*` variable from
`vendor/brand/tokens/tokens.sh`, vendored from CI-Common's brand bundle by
`setup/scripts/vendor-brand.sh` and verified by `80-validate-ci-theme.sh`.

| Role | Token | Value (canon 1.0) | Used by |
| --- | --- | --- | --- |
| Brand primary | `CI_LIGHT_PRIMARY` | `#0a6358` phthalo | GNOME background primary, KDE focus, Plymouth text accent |
| Dark primary / accent | `CI_DARK_PRIMARY` | `#c5e8dc` sage | Plymouth progress, terminal cursor, KDE decoration focus |
| Ground | `CI_DARK_BACKGROUND` | `#041620` navy | Plymouth background, terminal background, KDE window background |
| Foreground | `CI_DARK_FOREGROUND` | `#e8f2f4` | Plymouth text, terminal foreground |
| Aqua accent | `CI_ACCENT_AQUA_LIGHT` | `#72ddd4` | KDE hover / link |

The logo's own ramp (`#066c80` / `#00a9a7` / `#72ddd4`) is part of the mark artwork
(`vendor/brand/logos/mark.svg`) and is **not** the brand palette — the boot screen,
desktop theme and this document used to be painted in it. Typography: Manrope
(`vendor/brand/fonts/`) on branded surfaces; the desktop keeps the distro's system fonts.

Refresh: `setup/scripts/vendor-brand.sh <version>` after a `@companionintelligence/tokens`
release; see CI-Common `CONSUMING.md`, Route B.
