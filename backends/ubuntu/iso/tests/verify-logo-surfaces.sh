#!/usr/bin/env bash
#=============================================================================
# Test: verify-iso.sh section 4b rejects logo surfaces that only LOOK right
#
# (Ubuntu 26.04.1's gnome-control-center 50 reads the SVG pair /usr/share/pixmaps/ubuntu-logo-text{,-dark}.svg, so the SVGs are checked
# as hard as the PNGs: not Ubuntu's file, no Ubuntu orange, diverted, every path of the vendored one-colour mark, filled with the mode's primary.)
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
#   good                   no failure (the stock copy of one diverted file is a symlink in its listing, as 26.04.1's
#                          spinner/watermark.png is: a match anchored at the end of the line missed it);
#   every other variant    the FAIL line that names its defect (one defect each: a red square, an empty PNG, the wrong
#                          colour, the other mode's file, a ring of the right colour but another shape, a
#                          one-colour greeter, a black greeter, a gradient, an empty or another SVG, an image that IS
#                          Ubuntu's stock file, a start icon that is Ubuntu's, keeps the artwork colours, lacks a path,
#                          has a crop outside the mark's canvas or one that clips half the mark, the old label). Matching
#                          the line, not just "some failure", is what makes a check that is switched off visible: an SVG
#                          that is not an SVG also lacks every path, so a count of failures cannot tell which check ran.
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
VERIFY="${VERIFY_ISO_SCRIPT:-$REPO/backends/ubuntu/iso/scripts/verify-iso.sh}"   # another copy of it: how the test itself is tested (a copy with one check switched off must make a variant misbehave)
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
    # the SVG pair: the vendored one-colour mark with currentColor replaced by the mode's primary, as render-mark-png.sh does for the PNGs
    sed "s/currentColor/$CI_LIGHT_PRIMARY/g" "$REPO/vendor/brand/logos/mark-mono.svg" > "$r/usr/share/pixmaps/ubuntu-logo-text.svg"
    sed "s/currentColor/$CI_DARK_PRIMARY/g" "$REPO/vendor/brand/logos/mark-mono.svg" > "$r/usr/share/pixmaps/ubuntu-logo-text-dark.svg"
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
    for p in /usr/share/pixmaps/ubuntu-logo-text.png /usr/share/pixmaps/ubuntu-logo-text-dark.png /usr/share/pixmaps/ubuntu-logo-text.svg \
             /usr/share/pixmaps/ubuntu-logo-text-dark.svg /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg; do
        printf '%s\n%s.ubuntu-stock\n:\n' "$p" "$p" >> "$r/var/lib/dpkg/diversions"
    done
}

break_root() { # break_root <root> <variant>: one defect
    local r="$1" about="$1/usr/share/pixmaps/ubuntu-logo-text.png" greeter="$1/usr/share/pixmaps/companion-logo.png"
    local asvg="$1/usr/share/pixmaps/ubuntu-logo-text.svg" asvgd="$1/usr/share/pixmaps/ubuntu-logo-text-dark.svg"
    local start="$1/usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg" icon="$1/usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg"
    case "$2" in
        good | svg-stock | about-stock) ;;   # (the two stock variants change the script's constant, not the root: see the loop)
        about-red-square)   "${IM[@]}" -size 192x192 xc:'#cc0000' PNG32:"$about" ;;
        about-wrong-colour) bash "$RM" "$about" 192 '#cc0000' >/dev/null ;;
        about-empty)        "${IM[@]}" -size 192x192 xc:none PNG32:"$about" ;;
        about-dark-swapped) cp "$r/usr/share/pixmaps/ubuntu-logo-text-dark.png" "$about" ;;
        about-colour-mark)  bash "$RM" "$about" 192 >/dev/null ;;
        about-other-shape)  "${IM[@]}" -size 192x192 xc:none -fill "$CI_LIGHT_PRIMARY" -stroke "$CI_LIGHT_PRIMARY" -strokewidth 1 -draw 'circle 96,96 96,30' -fill none -strokewidth 6 -draw 'circle 96,96 96,60' PNG32:"$about" ;;
        svg-missing)        rm -f "$asvg" ;;
        svg-empty)          printf '<svg/>' > "$asvg" ;;
        svg-ubuntu-orange)  printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><path fill="#e95420" d="M0 0h10v10H0z"/></svg>' > "$asvg" ;;
        svg-current-color)  sed "s/$CI_LIGHT_PRIMARY/currentColor/g" "$asvg" > "$asvg.x" && mv "$asvg.x" "$asvg" ;;
        svg-wrong-colour)   sed "s/$CI_LIGHT_PRIMARY/#cc0000/g" "$asvg" > "$asvg.x" && mv "$asvg.x" "$asvg" ;;
        svg-dark-swapped)   cp "$asvgd" "$asvg" ;;
        svg-other-shape)    sed 's/M51\.451,125\.652/M1,2/' "$asvg" > "$asvg.x" && mv "$asvg.x" "$asvg" ;;
        svg-not-svg)        printf 'not an image\n' > "$asvgd" ;;
        svg-undiverted)     grep -v -F 'ubuntu-logo-text-dark.svg' "$r/var/lib/dpkg/diversions" > "$r/var/lib/dpkg/diversions.x" || true; mv "$r/var/lib/dpkg/diversions.x" "$r/var/lib/dpkg/diversions" ;;
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

want_of() { # want_of <variant>: the text the variant's FAIL line must contain
    case "$1" in
        about-stock)           echo "ubuntu-logo-text.png is still Ubuntu's stock wordmark" ;;
        about-*)               echo "ubuntu-logo-text.png (light mode)" ;;
        svg-missing)           echo "Settings > About SVG logo missing: /usr/share/pixmaps/ubuntu-logo-text.svg" ;;
        svg-empty|svg-other-shape) echo "ubuntu-logo-text.svg lacks" ;;
        svg-ubuntu-orange)     echo "ubuntu-logo-text.svg still has Ubuntu orange (#e95420)" ;;
        svg-current-color|svg-wrong-colour|svg-dark-swapped) echo "ubuntu-logo-text.svg is not filled with the canon primary of light mode" ;;
        svg-stock)             echo "ubuntu-logo-text.svg is still Ubuntu's stock wordmark" ;;
        svg-not-svg)           echo "ubuntu-logo-text-dark.svg is not an SVG" ;;
        svg-undiverted)        echo "ubuntu-logo-text-dark.svg is not dpkg-diverted to ubuntu-logo-text-dark.svg.ubuntu-stock" ;;
        greeter-*)             echo "greeter logo companion-logo.png" ;;
        icon-*)                echo "icon ci-os-logo.svg differs from vendor/brand/logos/mark.svg" ;;
        start-ubuntu)          echo "Yaru start-here-symbolic.svg is still Ubuntu's (viewBox 0 0 16 16)" ;;
        start-artwork-colours) echo "Yaru start-here-symbolic.svg ships logo artwork colours" ;;
        start-missing-path)    echo "Yaru start-here-symbolic.svg lacks 1 of" ;;
        start-outside)         echo "is not inside the vendored mark's canvas" ;;
        start-clipped)         echo "Yaru start-here-symbolic.svg clips the mark" ;;
        hub-old-label)         echo "Hub launcher entry is labelled Companion Hub" ;;
        *)                     echo "" ;;
    esac
}
section_failures() { # section_failures <root> [section file]: run the real section 4b against it, print the number of FAIL lines
    local r="$1" sec="${2:-$WORK/section.sh}" out
    out="$( ( R="$r"; LISTING="$WORK/listing.txt"; VERIFY_REPO="$REPO"
              # shellcheck disable=SC1090
              source "$sec" ) 2>&1 )"
    printf '%s\n' "$out" > "$WORK/last-out.txt"
    printf '%s\n' "$out" | grep -c '^FAIL' || true
}

cat > "$WORK/listing.txt" <<'EOF'
-rw-r--r-- root/root 5278 2026-10-14 16:42 /usr/share/pixmaps/ubuntu-logo-text.png.ubuntu-stock
-rw-r--r-- root/root 4642 2026-10-14 16:42 /usr/share/pixmaps/ubuntu-logo-text-dark.png.ubuntu-stock
-rw-r--r-- root/root 6018 2026-08-24 10:33 /usr/share/pixmaps/ubuntu-logo-text.svg.ubuntu-stock
lrwxrwxrwx root/root 31 2026-08-24 10:33 /usr/share/pixmaps/ubuntu-logo-text-dark.svg.ubuntu-stock -> ubuntu-logo-text-dark.svg.orig
-rw-r--r-- root/root 5250 2026-10-14 16:42 /usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg
lrwxrwxrwx root/root 33 2024-04-18 17:06 /usr/share/icons/Yaru/scalable/actions/view-app-grid-ubuntu-symbolic.svg -> ../places/start-here-symbolic.svg
EOF

BAD=0
for variant in good about-red-square about-wrong-colour about-empty about-dark-swapped about-colour-mark about-other-shape \
               svg-missing svg-empty svg-ubuntu-orange svg-current-color svg-wrong-colour svg-dark-swapped svg-other-shape svg-not-svg svg-undiverted svg-stock about-stock \
               greeter-red-square greeter-one-colour greeter-black greeter-gradient icon-empty icon-other-mark \
               start-ubuntu start-artwork-colours start-missing-path start-outside start-clipped hub-old-label; do
    if [[ "$variant" == start-clipped ]] && ! command -v rsvg-convert >/dev/null 2>&1; then
        echo "info  start-clipped: skipped (the ink check needs rsvg-convert)"; continue
    fi
    root="$WORK/root-$variant"
    build_root "$root"
    break_root "$root" "$variant" || { echo "FAIL  $variant: could not build the variant"; BAD=$((BAD + 1)); continue; }
    sec="$WORK/section.sh"
    case "$variant" in
        # an image whose file IS "Ubuntu's stock one": the script under test compares with a sha256 constant, so the copy of the section that
        # runs here has the constant of the file the variant ships (the real stock files are not in the repo)
        svg-stock)   sec="$WORK/section-$variant.sh"; sed "s/^STOCK_ABOUT_LIGHT_SVG_SHA=.*/STOCK_ABOUT_LIGHT_SVG_SHA=$(sha256sum "$root/usr/share/pixmaps/ubuntu-logo-text.svg" | cut -d' ' -f1)/" "$WORK/section.sh" > "$sec" ;;
        about-stock) sec="$WORK/section-$variant.sh"; sed "s/^STOCK_ABOUT_LIGHT_SHA=.*/STOCK_ABOUT_LIGHT_SHA=$(sha256sum "$root/usr/share/pixmaps/ubuntu-logo-text.png" | cut -d' ' -f1)/" "$WORK/section.sh" > "$sec" ;;
    esac
    n="$(section_failures "$root" "$sec")"
    if [[ "$variant" == good ]]; then
        if [[ "$n" -eq 0 ]]; then echo "PASS  good root: section 4b has no failure"; else echo "FAIL  good root: section 4b reports $n failure(s)"; grep '^FAIL' "$WORK/last-out.txt" | sed 's/^/        /'; BAD=$((BAD + 1)); fi
    else
        want="$(want_of "$variant")"
        fails="$(grep '^FAIL' "$WORK/last-out.txt" || true)"   # (a variable and a here-string: `grep | grep -q` under pipefail dies of SIGPIPE on a long output)
        if [[ "$n" -ge 1 && -n "$want" ]] && grep -qF -- "$want" <<<"$fails"; then echo "PASS  $variant: rejected ($n failure(s), one says: $want)"
        else echo "FAIL  $variant: section 4b did not reject it with a line saying '${want:-?}' ($n failure(s))"; printf '%s\n' "$fails" | cut -c1-200 | head -n 6 | sed 's/^/        got: /'; BAD=$((BAD + 1)); fi
    fi
    rm -rf "$root"
done

echo
if [[ "$BAD" -eq 0 ]]; then echo "all variants behaved"; else echo "$BAD variant(s) misbehaved"; fi
[[ "$BAD" -eq 0 ]]
