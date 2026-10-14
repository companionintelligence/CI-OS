#!/usr/bin/env bash
#=============================================================================
# Test: verify-iso.sh section 4b rejects logo surfaces that only LOOK right
#
# 28244c4's checks for the Settings > About logos, the greeter logo, ci-os-logo.svg and the dock start icon
# tested a PNG header, a width, a size and "not the stock sha256". A plain red 256x256 PNG passed as the greeter
# logo, an empty file as ci-os-logo.svg. Section 4b now checks content: the opaque pixels of the About PNGs are
# exactly the mode's primary token and those of the greeter exactly the mark's three tones, the mark covers a
# sensible part of the image and (where a renderer exists) has the shape of a fresh render of the vendored mark,
# ci-os-logo.svg is the vendored mark.svg byte for byte, and the start icon carries every path of the vendored
# mark and none of the artwork's colours, lies inside the mark's canvas and (with rsvg-convert) keeps its ink: the
# crop in 40-start-icon.sh is a constant cut for the 1.0.0 mark, and a path check cannot see a clipped icon.
#
# This test builds a synthetic image root with the repo's own code (render-mark-png.sh for the PNGs, the
# 40-start-icon.sh sed for the icon), runs the REAL section 4b out of verify-iso.sh against it, and expects
#
#   good                   no failure;
#   every other variant    at least one failure (one defect each: a red square, an empty PNG, the wrong
#                          colour, the other mode's file, a ring of the right colour but another shape, a
#                          one-colour greeter, a black greeter, a gradient, an empty or another SVG, a start
#                          icon that is Ubuntu's, keeps the artwork colours, lacks a path, has a crop outside the
#                          mark's canvas or one that clips half the mark, the old label).
#
# Needs python3, rsvg-convert or ImageMagick (to build the roots) and GNU coreutils; run it in a throw-away
# container, with the repo mounted read-only, e.g.
#
#   docker run --rm -v "$PWD:/repo:ro" <ubuntu image with python3 librsvg2-bin imagemagick> \
#       bash /repo/backends/ubuntu/iso/tests/verify-logo-surfaces.sh
#
# Exit status is non-zero if any expectation fails; 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
VERIFY="$REPO/backends/ubuntu/iso/scripts/verify-iso.sh"
RM="$REPO/core/render/render-mark-png.sh"

for t in python3 od sha256sum awk paste; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done
if ! command -v rsvg-convert >/dev/null 2>&1 && ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
    echo "needs rsvg-convert or ImageMagick to build the test roots" >&2; exit 2
fi
if command -v magick >/dev/null 2>&1; then IM=(magick); else IM=(convert); fi
[[ -f "$VERIFY" && -f "$RM" ]] || { echo "run it from the repo checkout" >&2; exit 2; }

# shellcheck source=../../../../vendor/brand/tokens/tokens.sh
source "$REPO/vendor/brand/tokens/tokens.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The helpers and section 4b, taken verbatim from the script under test.
{
    sed -n '/^PASS=0; FAIL=0$/,/^# ── extract what we need/p' "$VERIFY" | sed '$d'
    sed -n '/^in_listing() {/,/^# ── 1\. pre-installed packages/p' "$VERIFY" | sed '$d'
    sed -n '/^section "4b\./,/^section "4c\./p' "$VERIFY" | sed '$d' | sed 's#^PNGTOOL=.*#PNGTOOL="$VERIFY_REPO/backends/ubuntu/lib/png-colours.py"#'
} > "$WORK/section.sh"
[[ "$(grep -c 'canon_png' "$WORK/section.sh")" -ge 3 ]] || { echo "could not extract section 4b from $VERIFY" >&2; exit 2; }

build_root() { # build_root <dir>: what a correct build ships, in the places verify-iso.sh looks
    local r="$1" vb w h
    mkdir -p "$r/usr/share/pixmaps" "$r/usr/share/icons/Yaru/scalable/places" "$r/usr/share/icons/hicolor/scalable/apps" \
             "$r/usr/share/applications" "$r/usr/lib" "$r/etc/dconf/db/gdm.d" "$r/var/lib/dpkg"
    bash "$RM" "$r/usr/share/pixmaps/ubuntu-logo-text.png" 192 "$CI_LIGHT_PRIMARY" >/dev/null
    bash "$RM" "$r/usr/share/pixmaps/ubuntu-logo-text-dark.png" 192 "$CI_DARK_PRIMARY" >/dev/null
    bash "$RM" "$r/usr/share/pixmaps/companion-logo.png" 256 >/dev/null
    # the same transformation 40-start-icon.sh applies to the vendored one-colour mark, with the crop it defines
    vb="$(sed -n 's/^START_ICON_VIEWBOX="\(.*\)"$/\1/p' "$REPO/backends/ubuntu/desktop-theme/40-start-icon.sh")"
    [[ -n "$vb" ]] || { echo "no START_ICON_VIEWBOX in 40-start-icon.sh" >&2; exit 2; }
    read -r _ _ w h <<<"$vb"
    sed "s/viewBox=\"[^\"]*\"/viewBox=\"$vb\" width=\"$w\" height=\"$h\"/" "$REPO/vendor/brand/logos/mark-mono.svg" > "$r/usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg"
    cp "$REPO/vendor/brand/logos/mark.svg" "$r/usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg"
    printf 'ci-os-logo\n' > "$r/usr/share/icons/hicolor/icon-theme.cache"
    printf 'LOGO=ci-os-logo\n' > "$r/usr/lib/os-release"
    cp "$REPO/core/headless/payload/usr/share/applications/ci-os-hub.desktop" "$r/usr/share/applications/"
    printf "[org/gnome/login-screen]\nlogo='/usr/share/pixmaps/companion-logo.png'\n" > "$r/etc/dconf/db/gdm.d/01-ci-os-login"
    : > "$r/var/lib/dpkg/diversions"
    local p
    for p in /usr/share/pixmaps/ubuntu-logo-text.png /usr/share/pixmaps/ubuntu-logo-text-dark.png /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg; do
        printf '%s\n%s.ubuntu-stock\n:\n' "$p" "$p" >> "$r/var/lib/dpkg/diversions"
    done
}

break_root() { # break_root <root> <variant>: one defect
    local r="$1" about="$1/usr/share/pixmaps/ubuntu-logo-text.png" greeter="$1/usr/share/pixmaps/companion-logo.png"
    local start="$1/usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg" icon="$1/usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg"
    case "$2" in
        good) ;;
        about-red-square)   "${IM[@]}" -size 192x192 xc:'#cc0000' PNG32:"$about" ;;
        about-wrong-colour) bash "$RM" "$about" 192 '#cc0000' >/dev/null ;;
        about-empty)        "${IM[@]}" -size 192x192 xc:none PNG32:"$about" ;;
        about-dark-swapped) cp "$r/usr/share/pixmaps/ubuntu-logo-text-dark.png" "$about" ;;
        about-colour-mark)  bash "$RM" "$about" 192 >/dev/null ;;
        about-other-shape)  "${IM[@]}" -size 192x192 xc:none -fill "$CI_LIGHT_PRIMARY" -stroke "$CI_LIGHT_PRIMARY" -strokewidth 1 -draw 'circle 96,96 96,30' -fill none -strokewidth 6 -draw 'circle 96,96 96,60' PNG32:"$about" ;;
        greeter-red-square) "${IM[@]}" -size 256x256 xc:'#cc0000' PNG32:"$greeter" ;;
        greeter-one-colour) bash "$RM" "$greeter" 256 "$CI_LIGHT_PRIMARY" >/dev/null ;;
        greeter-black)      bash "$RM" "$greeter" 256 '#000000' >/dev/null ;;
        greeter-gradient)   "${IM[@]}" -size 256x256 gradient:'#ffc0ff-#c0ffff' PNG32:"$greeter" ;;
        icon-empty)         printf '<svg/>' > "$icon" ;;
        icon-other-mark)    sed 's/M51\.451,125\.652/M1,2/' "$REPO/vendor/brand/logos/mark.svg" > "$icon" ;;
        start-ubuntu)       printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z"/></svg>' > "$start" ;;
        start-artwork-colours) sed 's/currentColor/#066c80/g' "$start" > "$start.x" && mv "$start.x" "$start" ;;
        start-missing-path) sed 's/M51\.451,125\.652/M1,2/' "$start" > "$start.x" && mv "$start.x" "$start" ;;
        # a crop for another mark: partly outside the canvas (caught by the containment check, no renderer needed) ...
        start-outside)      sed 's/viewBox="[^"]*"/viewBox="-19.938 -19.938 119.295 119.625"/' "$start" > "$start.x" && mv "$start.x" "$start" ;;
        # ... and one inside the canvas that cuts away about three quarters of the mark (needs rsvg-convert to be seen)
        start-clipped)      sed 's/viewBox="[^"]*"/viewBox="34.6 36.5 90 90"/' "$start" > "$start.x" && mv "$start.x" "$start" ;;
        hub-old-label)      sed 's/^Name=.*/Name=CI OS Hub/' "$r/usr/share/applications/ci-os-hub.desktop" > "$r/x.desktop" && mv "$r/x.desktop" "$r/usr/share/applications/ci-os-hub.desktop" ;;
        *) echo "unknown variant $2" >&2; return 2 ;;
    esac
}

section_failures() { # section_failures <root>: run the real section 4b against it, print the number of FAIL lines
    local r="$1" out
    out="$( ( R="$r"; LISTING="$WORK/listing.txt"; VERIFY_REPO="$REPO"
              # shellcheck disable=SC1090
              source "$WORK/section.sh" ) 2>&1 )"
    printf '%s\n' "$out" > "$WORK/last-out.txt"
    printf '%s\n' "$out" | grep -c '^FAIL' || true
}

cat > "$WORK/listing.txt" <<'EOF'
-rw-r--r-- root/root 5278 2026-10-14 16:42 /usr/share/pixmaps/ubuntu-logo-text.png.ubuntu-stock
-rw-r--r-- root/root 4642 2026-10-14 16:42 /usr/share/pixmaps/ubuntu-logo-text-dark.png.ubuntu-stock
-rw-r--r-- root/root 5250 2026-10-14 16:42 /usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg
lrwxrwxrwx root/root 33 2024-04-18 17:06 /usr/share/icons/Yaru/scalable/actions/view-app-grid-ubuntu-symbolic.svg -> ../places/start-here-symbolic.svg
EOF

BAD=0
for variant in good about-red-square about-wrong-colour about-empty about-dark-swapped about-colour-mark about-other-shape \
               greeter-red-square greeter-one-colour greeter-black greeter-gradient icon-empty icon-other-mark \
               start-ubuntu start-artwork-colours start-missing-path start-outside start-clipped hub-old-label; do
    if [[ "$variant" == start-clipped ]] && ! command -v rsvg-convert >/dev/null 2>&1; then
        echo "info  start-clipped: skipped (the ink check needs rsvg-convert)"; continue
    fi
    root="$WORK/root-$variant"
    build_root "$root"
    break_root "$root" "$variant" || { echo "FAIL  $variant: could not build the variant"; BAD=$((BAD + 1)); continue; }
    n="$(section_failures "$root")"
    if [[ "$variant" == good ]]; then
        if [[ "$n" -eq 0 ]]; then echo "PASS  good root: section 4b has no failure"; else echo "FAIL  good root: section 4b reports $n failure(s)"; grep '^FAIL' "$WORK/last-out.txt" | sed 's/^/        /'; BAD=$((BAD + 1)); fi
    else
        if [[ "$n" -ge 1 ]]; then echo "PASS  $variant: rejected ($n failure(s))"; else echo "FAIL  $variant: section 4b accepted it"; BAD=$((BAD + 1)); fi
    fi
    rm -rf "$root"
done

echo
if [[ "$BAD" -eq 0 ]]; then echo "all variants behaved"; else echo "$BAD variant(s) misbehaved"; fi
[[ "$BAD" -eq 0 ]]
