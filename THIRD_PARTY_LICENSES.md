# Third-Party Licenses

Companion OS is built by rebranding Ubuntu Desktop, and its own [PolyForm
Noncommercial license](LICENSE.md) covers only Companion Intelligence's own
source in this repository. Ubuntu, GNOME, and other upstream components keep
their own licenses (see [`License-FAQ.md`](License-FAQ.md)). This file tracks
third-party assets that are bundled in compiled/binary form, where the
upstream license is not otherwise visible from the file itself.

## Yaru GNOME Shell theme resource

**Bundled at:**
[`packages/ci-os-branding/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource`](packages/ci-os-branding/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource)
(compiled GResource binary, ~5.99 MB / 5,987,247 bytes).

**Source:** [Yaru](https://github.com/ubuntu/yaru), the default Ubuntu
desktop theme suite, developed by Canonical Ltd. and the Ubuntu community.

**What Companion OS does with it:** `tools/iso-build/scripts/build-gdm-branding-gresource.sh`
extracts this exact resource from the `yaru-theme-gnome-shell` package on the
Ubuntu 24.04 build host, rewrites the embedded CSS to remap Ubuntu's brand
colors to Companion Intelligence's palette, replaces the Ubuntu logo SVGs
with the CI logo, and recompiles the result into the `.gresource` file
bundled above. This is a modified/derivative redistribution of Yaru's GNOME
Shell theme assets, not a verbatim passthrough.

**License:** Yaru is explicitly a mixed-license project — its own README
("Copying or Reusing" section) states *"This project has mixed licencing. You
are free to copy, redistribute and/or modify aspects of this work under the
terms of each licence accordingly."* The upstream repository carries four
license files at its root:

- `LICENSE_CCBYSA` — [Creative Commons Attribution-ShareAlike 4.0](https://creativecommons.org/licenses/by-sa/4.0/), which upstream's README explicitly assigns to the icon/cursor theme assets (`.svg` and rendered `.png` files).
- `COPYING` — [GNU GPL v3.0](https://www.gnu.org/licenses/gpl-3.0.txt), which upstream's README explicitly assigns to included scripts.
- `COPYING.LGPL-2.1` and `COPYING.LGPL-3.0` — [LGPL v2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt) / [LGPL v3.0](https://www.gnu.org/licenses/lgpl-3.0.txt). Upstream's README does not explicitly map these to a specific directory, but Yaru documents its GNOME Shell theme and GTK theme as derived from the upstream GNOME Shell theme and Adwaita GTK theme (both LGPL-licensed), which is the most plausible fit for the `gnome-shell/` theme data bundled here.

The precise directory-to-license mapping for the `gnome-shell/` theme data
specifically is not spelled out in a single upstream statement the way the
icons/scripts split is — see the [upstream repository](https://github.com/ubuntu/yaru)
for the authoritative, current license files before relying on this summary
for anything beyond attribution. Regardless of which of the four applies to
this specific asset, all of them require retaining copyright/license notices
on redistribution, and CC BY-SA additionally requires attribution and
indicating that changes were made — which this notice provides.

No warranty is made about the completeness of this notice; it does not
modify, waive, or supersede Yaru's own license terms, and it does not alter
Companion OS's own [`LICENSE.md`](LICENSE.md).
