# Yaru accent-color remap table for core/render/render-gnome-shell-gresource.sh.
# Yaru's default theme uses a wide palette of orange variants, NOT just #E95420.
# We must remap ALL of them to CI-OS teal/green equivalents. The mapping
# preserves relative luminance relationships (darkest→darkest, lightest→lightest).
#
# Only the two anchor substitutions (marked below) resolve to $ENV{ACCENT_*} —
# the canon primary/secondary tokens, sourced by the caller from
# vendor/brand/tokens/tokens.sh. The ~28 intermediate hex values are a
# hand-tuned luminance ramp between those two anchors, not a 1:1 token
# mapping, and are intentionally left as literals — see
# docs/architecture/multi-distro-design.md.
#
# This file's content is passed to `perl -0pi -e` by the generic render
# script — it must be valid Perl statements only (no shell syntax), and can
# reference $ENV{ACCENT_PRIMARY} / $ENV{ACCENT_SECONDARY} /
# $ENV{ACCENT_PRIMARY_RGB} / $ENV{ACCENT_SECONDARY_RGB}, which the caller
# exports before invoking perl.

# ── Yaru orange accent family (sorted dark→light) ────────────────────
# Dark orange variants → CI-OS dark teal
s/#be3f13/#04525e/g;  s/#BE3F13/#04525e/g;
s/#c04013/#045260/g;  s/#C04013/#045260/g;
s/#c14013/#045360/g;  s/#C14013/#045360/g;
s/#c54113/#055663/g;  s/#C54113/#055663/g;
s/#c74214/#055865/g;  s/#C74214/#055865/g;
s/#d34615/$ENV{ACCENT_SECONDARY}/g;  s/#D34615/$ENV{ACCENT_SECONDARY}/g;   # Primary Yaru accent (24×) — canon secondary/phthalo
s/#da4816/#077486/g;  s/#DA4816/#077486/g;

# Mid orange variants → CI-OS primary teal
s/#e14b16/#08808e/g;  s/#E14B16/#08808e/g;
s/#e54c17/#098891/g;  s/#E54C17/#098891/g;
s/#e64c17/#098a93/g;  s/#E64C17/#098a93/g;
s/#e84f19/#0a8e96/g;  s/#E84F19/#0a8e96/g;
s/#E95420/$ENV{ACCENT_PRIMARY}/g;  s/#e95420/$ENV{ACCENT_PRIMARY}/g;   # Classic Ubuntu orange — canon primary/sage
s/#e95c2a/#14b0ab/g;  s/#e95C2A/#14b0ab/g;
s/#ea5d2c/#1ab2ad/g;  s/#EA5D2C/#1ab2ad/g;
s/#eb6030/#20b5b0/g;  s/#EB6030/#20b5b0/g;

# Light orange variants → CI-OS light teal
s/#ec6b3e/#33bbb6/g;  s/#EC6B3E/#33bbb6/g;
s/#ef845f/#55ccc8/g;  s/#EF845F/#55ccc8/g;
s/#ef8661/#59ceca/g;  s/#EF8661/#59ceca/g;   # Most common Yaru light accent (32×)

# ── Yaru yellow/amber warning palette → CI-OS gold-teal ──────────────
s/#f9990c/#0ec4a8/g;  s/#F9990C/#0ec4a8/g;
s/#f99b11/#12c5aa/g;  s/#F99B11/#12c5aa/g;
s/#faa52a/#2dccb3/g;  s/#FAA52A/#2dccb3/g;

# ── Yaru red accent variants → CI-OS dark teal ───────────────────────
s/#c7162b/#044f5b/g;  s/#C7162B/#044f5b/g;
s/#da3450/#066677/g;  s/#DA3450/#066677/g;
s/#dc415b/#07707e/g;  s/#DC415B/#07707e/g;
s/#dd445e/#077381/g;  s/#DD445E/#077381/g;
s/#dd455f/#077482/g;  s/#DD455F/#077482/g;
s/#de4a63/#087986/g;  s/#DE4A63/#087986/g;
s/#e82d43/#0a8c94/g;  s/#E82D43/#0a8c94/g;
s/#e15970/#099098/g;  s/#E15970/#099098/g;
s/#e15b71/#09929a/g;  s/#E15B71/#09929a/g;
s/#e25f75/#0a969d/g;  s/#E25F75/#0a969d/g;

# ── Yaru aubergine/purple brand (#77216F) ────────────────────────────
s/#77216F/$ENV{ACCENT_SECONDARY}/g;  s/#77216f/$ENV{ACCENT_SECONDARY}/g;
s/rgb\(119\s*,\s*33\s*,\s*111\)/rgb($ENV{ACCENT_SECONDARY_RGB})/g;
s/rgba\(119\s*,\s*33\s*,\s*111\s*,\s*([0-9.]+)\)/rgba($ENV{ACCENT_SECONDARY_RGB}, $1)/g;

# ── Ubuntu highlight/selection blue (#19B6EE) ────────────────────────
s/#19B6EE/$ENV{ACCENT_PRIMARY}/g;  s/#19b6ee/$ENV{ACCENT_PRIMARY}/g;
s/rgb\(25\s*,\s*182\s*,\s*238\)/rgb($ENV{ACCENT_PRIMARY_RGB})/g;
s/rgba\(25\s*,\s*182\s*,\s*238\s*,\s*([0-9.]+)\)/rgba($ENV{ACCENT_PRIMARY_RGB}, $1)/g;

# ── Catch rgb/rgba forms of the main Ubuntu orange ───────────────────
s/rgb\(233\s*,\s*84\s*,\s*32\)/rgb($ENV{ACCENT_PRIMARY_RGB})/g;
s/rgba\(233\s*,\s*84\s*,\s*32\s*,\s*([0-9.]+)\)/rgba($ENV{ACCENT_PRIMARY_RGB}, $1)/g;
s/rgb\(211\s*,\s*70\s*,\s*21\)/rgb($ENV{ACCENT_SECONDARY_RGB})/g;
s/rgba\(211\s*,\s*70\s*,\s*21\s*,\s*([0-9.]+)\)/rgba($ENV{ACCENT_SECONDARY_RGB}, $1)/g;
