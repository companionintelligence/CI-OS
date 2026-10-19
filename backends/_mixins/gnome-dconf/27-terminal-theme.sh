#!/usr/bin/env bash
# Configure a CI-OS blue/teal GNOME Terminal profile as the default for new sessions.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
require_root

# Use a stable profile UUID so dconf defaults remain idempotent across reruns.
PROFILE_ID="9f6f90ea-bf5f-4aa3-9f2d-0ce9d4bd9c10"
PROFILE_PATH="/org/gnome/terminal/legacy/profiles:/:${PROFILE_ID}/"

BG_COLOR="$CI_DARK_BACKGROUND"   # canon navy (was #071A23)
FG_COLOR="$CI_DARK_FOREGROUND"   # canon dark foreground (was #D7F3F0)
CURSOR_BG="$CI_DARK_PRIMARY"     # canon sage (was #7AE7D8)
CURSOR_FG="$CI_DARK_BACKGROUND"   # canon navy (was #071A23)
PALETTE="['#0F2430', '#FF6B6B', '#3DD6B5', '#FFD166', '#4EA8DE', '#C77DFF', '#34D1BF', '#D7F3F0', '#46606F', '#FF8787', '#63E6BE', '#FFE08A', '#74C0FC', '#D0A2FF', '#66E9D2', '#F1FFFD']"

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/03-ci-os-terminal <<EOF
[org/gnome/terminal/legacy/profiles:]
default='${PROFILE_ID}'
list=['${PROFILE_ID}']

[org/gnome/terminal/legacy/profiles:/:${PROFILE_ID}]
visible-name='Companion OS'
use-theme-colors=false
use-theme-transparency=false
use-system-font=true
bold-color-same-as-fg=true
audible-bell=false
scrollback-lines=100000

# Dark blue-teal base with high contrast foreground.
background-color='${BG_COLOR}'
foreground-color='${FG_COLOR}'
bold-color='${FG_COLOR}'
cursor-colors-set=true
cursor-background-color='${CURSOR_BG}'
cursor-foreground-color='${CURSOR_FG}'

# 16-color ANSI palette tuned for readability on the blue/teal base.
palette=${PALETTE}
EOF

dconf_update_safe

install_terminal_theme_autostart_enforcer() {
	local helper="/usr/local/bin/ci-os-enforce-terminal-theme"
	local desktop_file="/etc/xdg/autostart/ci-os-terminal-theme-enforcer.desktop"

	cat > "$helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command -v gsettings >/dev/null 2>&1 || exit 0

# Ptyxis (Ubuntu default terminal app on newer releases)
ptyxis_profile_id="$(gsettings get org.gnome.Ptyxis default-profile-uuid 2>/dev/null | tr -d "'" || true)"
if [[ -n "$ptyxis_profile_id" ]]; then
	ptyxis_profile="org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/${ptyxis_profile_id}/"
	gsettings set "$ptyxis_profile" palette 'Blue' 2>/dev/null || true
	gsettings set "$ptyxis_profile" opacity 1.0 2>/dev/null || true
fi

# GNOME Terminal (for systems still using it)
gt_profile_id="$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | tr -d "'" || true)"
if [[ -n "$gt_profile_id" ]]; then
	gt_profile_path="/org/gnome/terminal/legacy/profiles:/:${gt_profile_id}/"
	gsettings set "org.gnome.Terminal.Legacy.Profile:${gt_profile_path}" use-theme-colors false 2>/dev/null || true
	gsettings set "org.gnome.Terminal.Legacy.Profile:${gt_profile_path}" use-theme-transparency false 2>/dev/null || true
	gsettings set "org.gnome.Terminal.Legacy.Profile:${gt_profile_path}" background-color '#071A23' 2>/dev/null || true
	gsettings set "org.gnome.Terminal.Legacy.Profile:${gt_profile_path}" foreground-color '#D7F3F0' 2>/dev/null || true
	gsettings set "org.gnome.Terminal.Legacy.Profile:${gt_profile_path}" bold-color '#D7F3F0' 2>/dev/null || true
	gsettings set "org.gnome.Terminal.Legacy.Profile:${gt_profile_path}" cursor-colors-set true 2>/dev/null || true
	gsettings set "org.gnome.Terminal.Legacy.Profile:${gt_profile_path}" cursor-background-color '#7AE7D8' 2>/dev/null || true
	gsettings set "org.gnome.Terminal.Legacy.Profile:${gt_profile_path}" cursor-foreground-color '#071A23' 2>/dev/null || true
	gsettings set "org.gnome.Terminal.Legacy.Profile:${gt_profile_path}" palette "['#0F2430', '#FF6B6B', '#3DD6B5', '#FFD166', '#4EA8DE', '#C77DFF', '#34D1BF', '#D7F3F0', '#46606F', '#FF8787', '#63E6BE', '#FFE08A', '#74C0FC', '#D0A2FF', '#66E9D2', '#F1FFFD']" 2>/dev/null || true
fi

exit 0
EOF

	# The heredoc above is intentionally single-quoted (it contains its own
	# runtime $(gsettings ...) calls that must not expand at write time), so
	# the stale literals it was authored with can't be caught by sourcing
	# tokens.sh — substitute them after the fact instead. This is the same
	# drift class that motivated adding this comment: a copy of a color value
	# living outside the token source will silently stop matching it.
	sed -i "s/#071A23/${BG_COLOR}/g; s/#D7F3F0/${FG_COLOR}/g; s/#7AE7D8/${CURSOR_BG}/g" "$helper"

	chmod 755 "$helper"

	mkdir -p /etc/xdg/autostart
	cat > "$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=Companion OS Terminal Theme Enforcer
Comment=Re-apply Companion OS terminal colors at login
Exec=$helper
OnlyShowIn=GNOME;Unity;
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

	chmod 644 "$desktop_file"
	log_info "Installed login-time terminal theme enforcer"
}

apply_live_terminal_profile_for_user() {
	local user="$1"
	local uid runtime_dir dbus_addr xauth profile_id profile_path

	command -v gsettings >/dev/null 2>&1 || return 0

	uid="$(id -u "$user" 2>/dev/null || true)"
	[[ -n "$uid" ]] || return 0
	runtime_dir="/run/user/${uid}"
	dbus_addr="unix:path=${runtime_dir}/bus"
	xauth="/home/${user}/.Xauthority"

	[[ -S "${runtime_dir}/bus" ]] || return 0

	profile_id="$(sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | tr -d "'" || true)"

	if [[ -z "$profile_id" ]]; then
		profile_id="$PROFILE_ID"
		sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
			gsettings set org.gnome.Terminal.ProfilesList default "$profile_id" 2>/dev/null || true
	fi

	profile_path="/org/gnome/terminal/legacy/profiles:/:${profile_id}/"

	sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings set "org.gnome.Terminal.Legacy.Profile:${profile_path}" use-theme-colors false 2>/dev/null || true
	sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings set "org.gnome.Terminal.Legacy.Profile:${profile_path}" use-theme-transparency false 2>/dev/null || true
	sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings set "org.gnome.Terminal.Legacy.Profile:${profile_path}" background-color "$BG_COLOR" 2>/dev/null || true
	sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings set "org.gnome.Terminal.Legacy.Profile:${profile_path}" foreground-color "$FG_COLOR" 2>/dev/null || true
	sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings set "org.gnome.Terminal.Legacy.Profile:${profile_path}" bold-color "$FG_COLOR" 2>/dev/null || true
	sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings set "org.gnome.Terminal.Legacy.Profile:${profile_path}" cursor-colors-set true 2>/dev/null || true
	sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings set "org.gnome.Terminal.Legacy.Profile:${profile_path}" cursor-background-color "$CURSOR_BG" 2>/dev/null || true
	sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings set "org.gnome.Terminal.Legacy.Profile:${profile_path}" cursor-foreground-color "$CURSOR_FG" 2>/dev/null || true
	sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings set "org.gnome.Terminal.Legacy.Profile:${profile_path}" palette "$PALETTE" 2>/dev/null || true

	log_info "Applied live GNOME Terminal colors for user: $user"
}

set_bash_prompt_for_user() {
	local user="$1"
	local home rc tmp

	home="$(getent passwd "$user" | cut -d: -f6)"
	[[ -n "$home" ]] || return 0
	rc="${home}/.bashrc"
	[[ -f "$rc" ]] || touch "$rc"

	if grep -q "CI-OS prompt theme" "$rc" 2>/dev/null; then
		return 0
	fi

	tmp="$(mktemp)"
	cat > "$tmp" <<'PROMPT_EOF'

# >>> CI-OS prompt theme >>>
if [[ -n "${BASH_VERSION:-}" && "${CI_OS_DISABLE_PROMPT_THEME:-0}" != "1" ]]; then
	PS1='\[\e[38;2;0;148;136m\]\u@\h\[\e[0m\]:\[\e[38;2;190;234;240m\]\w\[\e[0m\]\$ '
fi
# <<< CI-OS prompt theme <<<
PROMPT_EOF
	cat "$tmp" >> "$rc"
	rm -f "$tmp"
	chown "$user:$user" "$rc"
	log_info "Applied turquoise bash prompt for user: $user"
}

apply_live_ptyxis_profile_for_user() {
	local user="$1"
	local uid runtime_dir dbus_addr xauth profile_id profile_path

	command -v gsettings >/dev/null 2>&1 || return 0

	uid="$(id -u "$user" 2>/dev/null || true)"
	[[ -n "$uid" ]] || return 0
	runtime_dir="/run/user/${uid}"
	dbus_addr="unix:path=${runtime_dir}/bus"
	xauth="/home/${user}/.Xauthority"

	[[ -S "${runtime_dir}/bus" ]] || return 0

	profile_id="$(sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings get org.gnome.Ptyxis default-profile-uuid 2>/dev/null | tr -d "'" || true)"
	[[ -n "$profile_id" ]] || return 0

	profile_path="org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/${profile_id}/"

	# Ptyxis palettes are named presets; "Blue" provides a deep blue background.
	sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings set "$profile_path" palette 'Blue' 2>/dev/null || true
	sudo -u "$user" env DISPLAY=:0 XAUTHORITY="$xauth" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
		gsettings set "$profile_path" opacity 1.0 2>/dev/null || true

	log_info "Applied live Ptyxis profile colors for user: $user (palette=Blue)"
}

ACTUAL_USER="${SUDO_USER:-}"
if [[ -z "$ACTUAL_USER" || "$ACTUAL_USER" == "root" ]]; then
	ACTUAL_USER="$(who -u 2>/dev/null | awk '{print $1; exit}' || true)"
fi

if [[ -n "$ACTUAL_USER" && "$ACTUAL_USER" != "root" ]]; then
	apply_live_terminal_profile_for_user "$ACTUAL_USER"
	apply_live_ptyxis_profile_for_user "$ACTUAL_USER"
	set_bash_prompt_for_user "$ACTUAL_USER"
fi

install_terminal_theme_autostart_enforcer

log_success "GNOME Terminal blue/teal profile defaults written"
log_info "Open a new terminal window (or re-login) to pick up profile and prompt updates"
