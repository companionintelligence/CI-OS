# shellcheck shell=bash
# ci-guards.sh: the checks calamares-online.sh runs before it puts the Companion OS overlay on top of CachyOS' installer.
#
# SOURCED, never executed (so no shebang and no executable bit). Plain bash 3.2 syntax on purpose: the unit tests
# (iso/tests/installer-launcher.sh) run on a stock macOS as well as in the live image (bash 5).
#
# Why guards. The overlay replaces module configs of cachyos-calamares-next and writes its own settings.conf. The installer
# package is whatever the repository holds on install day (calamares-online.sh reinstalls it, as upstream's script does), so
# every assumption the overlay makes about it is checked first, against a root directory that is NOT necessarily "/":
#
#   CI_OS_CALAMARES_ROOT   prefix of the installer tree ("" = the live system). Everything below is looked up as
#                          $CI_OS_CALAMARES_ROOT/etc/calamares, .../usr/share/calamares, .../usr/lib/calamares/modules.
#                          The launcher points it at an unpacked candidate package to judge an update before installing it;
#                          the tests point it at a fake tree.
#   CI_OS_OVERLAY_DIR      the overlay (default /usr/share/ci-os/calamares): settings.conf, modules/, branding/, guards.list ...
#   CI_OS_SUDO             command prefix for writes into the tree ("sudo" by default, empty in tests)
#
# Policy (decision D6). Every guard has a severity.
#   critical  an assumption the package list or the payload staging depends on. A failure means: do not run the overlay on
#             this installer. The launcher then keeps the installer that is already on the ISO (update case) or stops with
#             a dialog (bundled installer case). Never a silent fallback.
#   cosmetic  a string, a theme or a slideshow. A failure is logged loudly (WARN lines and a summary) and the overlay is
#             applied anyway; the worst outcome is a CachyOS word in the installer window.
# `keys` is critical for the two configs whose frozen copy the installer's PYTHON reads key by key (pacstrap, bootloader: a key
# upstream renames or adds is a KeyError or a silently missing package mid-install) and cosmetic for the rest, whose keys are
# optional with defaults.
#
# guards.list format, one guard per line, fields separated by "|", "#" starts a comment line:
#   severity | kind | argument-1 | argument-2 | why
#   exists       PATH                        file or directory exists under the installer root
#   contains     PATH   | FIXED-STRING       file under the installer root contains the string
#   oexists      PATH                        file exists under the OVERLAY directory
#   lexists      PATH                        file exists in the LIVE system (under CI_OS_LIVE_ROOT, default none), not in the installer
#   keys         NAME                        top-level keys of the installer's modules/NAME.conf are all present in the
#                                            overlay's modules/NAME.conf (a key upstream added is a feature we would drop)
#   settings-drift allow=a,b,c | anchors=x,y   every exec/show entry of the installer's settings_online.conf is either in the
#                                            overlay's settings.conf or in the allow list (entries dropped on purpose); and the
#                                            parsed sequence holds every anchor (kind:module, e.g. exec:pacstrap): an empty or
#                                            unparseable sequence (flow-style lists, a renamed key) FAILS instead of "no difference"
#   list-drift   CONF:KEY | allow=a,b,c      every item of the block list KEY in the installer's modules/CONF.conf is either in the
#                                            overlay's copy or in the allow list (items dropped on purpose); an installer list that
#                                            parses to nothing FAILS. For the lists the overlay replaces and freezes, whose values
#                                            `keys` cannot see (pacstrap basePackages, postInstallFiles)
#   code-names   PATH | LISTFILE             the packages the installer's Python module PATH appends to base_packages in code are
#                                            exactly the names the overlay's LISTFILE (pacstrap-code-added.list) lists
#   settings     (none)                      the overlay's settings.conf resolves: every module exists, every instance has a
#                                            config file (in the overlay or the installer), the branding component exists
#   shell-timeouts (none)                    every shellprocess step of the overlay's sequence has an explicit time limit on every command,
#                                            and a generous one (>= 600 s network and package tools, >= 300 s disk tools) where it runs a
#                                            heavy tool; an overlay copy of a stock shellprocess config still runs every command of the
#                                            installer's, in its order and with its dontChroot (lib/ci-shellprocess.py, which reads the configs with PyYAML). Calamares kills a
#                                            shellprocess command after 30 s unless told otherwise: ISO #5 died at 2 percent that way
#
# Messages are collected, not printed one by one: ci_g_report prints them all, so a maintainer sees every problem at once.

CI_G_CRIT_MSGS=""
CI_G_WARN_MSGS=""
CI_G_CRIT_COUNT=0
CI_G_WARN_COUNT=0

ci_g_reset() { CI_G_CRIT_MSGS=""; CI_G_WARN_MSGS=""; CI_G_CRIT_COUNT=0; CI_G_WARN_COUNT=0; }

ci_g_root() {
  local r="${CI_OS_CALAMARES_ROOT:-}"
  while [ "${r%/}" != "$r" ]; do r="${r%/}"; done   # no trailing slash
  printf '%s' "$r"
}
ci_g_path() { printf '%s%s' "$(ci_g_root)" "$1"; }
ci_g_overlay() { printf '%s' "${CI_OS_OVERLAY_DIR:-/usr/share/ci-os/calamares}"; }

ci_g_critical() {
  CI_G_CRIT_COUNT=$((CI_G_CRIT_COUNT + 1))
  CI_G_CRIT_MSGS="${CI_G_CRIT_MSGS}  - $*"$'\n'
}
ci_g_warn() {
  CI_G_WARN_COUNT=$((CI_G_WARN_COUNT + 1))
  CI_G_WARN_MSGS="${CI_G_WARN_MSGS}  - $*"$'\n'
}
# ci_g_fail SEVERITY MESSAGE
ci_g_fail() {
  case "$1" in
    critical) shift; ci_g_critical "$@" ;;
    *)        shift; ci_g_warn "$@" ;;
  esac
}

ci_g_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# --- parsing helpers ---------------------------------------------------------------------------------------------------

# Top-level YAML keys of a file, one per line, sorted.
ci_g_top_keys() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*:' "$1" 2>/dev/null | LC_ALL=C sort -u; }

# "show:welcome@online" / "exec:partition" lines of a Calamares settings.conf sequence.
ci_g_sequence() {
  awk '
    /^sequence:[[:space:]]*(#.*)?$/ { insec = 1; next }
    /^#/ { next }
    insec && /^[^[:space:]-]/ { insec = 0 }
    insec && /^-[[:space:]]*show:/ { mode = "show"; next }
    insec && /^-[[:space:]]*exec:/ { mode = "exec"; next }
    insec && mode != "" && /^[[:space:]]+-[[:space:]]+[^[:space:]#]/ {
      line = $0
      sub(/^[[:space:]]+-[[:space:]]+/, "", line)
      sub(/[[:space:]]*(#.*)?$/, "", line)
      print mode ":" line
    }' "$1"
}

# "id<TAB>module<TAB>config" per instance of a settings.conf.
ci_g_instances() {
  awk '
    /^instances:[[:space:]]*$/ { inst = 1; next }
    inst && /^[A-Za-z_]/ { inst = 0 }
    inst && /^-[[:space:]]+id:/ { id = $NF; mod = ""; next }
    inst && /^[[:space:]]+module:/ { mod = $NF; next }
    inst && /^[[:space:]]+config:/ { print id "\t" mod "\t" $NF }
  ' "$1"
}

# The value of a top-level `key: value` line (quotes stripped).
ci_g_value() {
  sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n 1 | sed -e 's/[[:space:]]*#.*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

# The items of the top-level block list KEY of a YAML file, one per line, quotes and trailing comments stripped. A flow-style list
# (`KEY: [a, b]`) and a missing key give nothing: callers treat "nothing" as "cannot read", never as "no difference".
ci_g_list() {
  awk -v key="$2" '
    $0 ~ ("^" key ":[[:space:]]*(#.*)?$") { insec = 1; next }
    insec && /^[A-Za-z_]/ { insec = 0 }
    insec && /^[[:space:]]*-[[:space:]]+[^[:space:]#]/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]+/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
    }' "$1" 2>/dev/null | sed -e "s/^[\"']//" -e "s/[\"']\$//"
}

# The statements of a Python module that add to base_packages (`base_packages += [...]`, `base_packages.append("...")`), as written,
# one line per source line: a statement that spans lines is followed until its brackets close.
ci_g_code_statements() {
  awk '
    /base_packages[[:space:]]*(\+=|\.append[[:space:]]*\()/ { on = 1; depth = 0 }
    on {
      print $0
      line = $0
      sub(/[[:space:]]#.*$/, "", line)
      depth += gsub(/[[(]/, "&", line) - gsub(/[])]/, "&", line)
      if (depth <= 0) on = 0
    }' "$1"
}
# The package names those statements hold (the quoted words), sorted, unique.
ci_g_code_names() {
  ci_g_code_statements "$1" | sed 's/[[:space:]]#.*$//' | grep -oE '"[A-Za-z0-9@._+-]+"' | tr -d '"' | LC_ALL=C sort -u
}

# --- individual guards -------------------------------------------------------------------------------------------------

ci_g_g_exists() {  # severity path why
  local p; p="$(ci_g_path "$2")"
  [ -e "$p" ] || ci_g_fail "$1" "missing $2 in the installer ($3)"
}
ci_g_g_contains() {  # severity path string why
  local p; p="$(ci_g_path "$2")"
  if [ ! -f "$p" ]; then ci_g_fail "$1" "missing $2 in the installer, so it cannot contain '$3' ($4)"; return 0; fi
  grep -qF -- "$3" "$p" || ci_g_fail "$1" "$2 no longer contains '$3' ($4)"
  return 0
}
ci_g_g_oexists() {  # severity path-in-overlay why
  [ -e "$(ci_g_overlay)/$2" ] || ci_g_fail "$1" "missing $2 in the overlay $(ci_g_overlay) ($3)"
}
ci_g_g_lexists() {  # severity path why
  [ -e "${CI_OS_LIVE_ROOT:-}$2" ] || ci_g_fail "$1" "missing $2 in the live system ($3)"
}
ci_g_g_keys() {  # severity name why
  local up ours missing
  up="$(ci_g_path "/etc/calamares/modules/$2.conf")"
  ours="$(ci_g_overlay)/modules/$2.conf"
  [ -f "$up" ] || { ci_g_fail "$1" "the installer has no modules/$2.conf any more ($3)"; return 0; }
  [ -f "$ours" ] || { ci_g_fail "$1" "the overlay has no modules/$2.conf ($3)"; return 0; }
  missing="$(LC_ALL=C comm -23 <(ci_g_top_keys "$up") <(ci_g_top_keys "$ours") | tr '\n' ' ')"
  [ -z "${missing// /}" ] || ci_g_fail "$1" "the installer's modules/$2.conf has top-level keys the overlay's copy lacks: ${missing}($3)"
}
ci_g_g_settings_drift() {  # severity allow=a,b [anchors=x,y] why
  local up ours allow anchors why entry a ups missing=""
  up="$(ci_g_path /usr/share/calamares/settings_online.conf)"
  ours="$(ci_g_overlay)/settings.conf"
  allow=",${2#allow=},"
  case "$3" in anchors=*) anchors="${3#anchors=}"; why="$4" ;; *) anchors=""; why="$4" ;; esac
  [ -f "$up" ] || { ci_g_fail "$1" "no usr/share/calamares/settings_online.conf in the installer: cannot compare the install sequence ($why)"; return 0; }
  [ -f "$ours" ] || { ci_g_fail "$1" "the overlay has no settings.conf ($why)"; return 0; }
  ups="$(ci_g_sequence "$up" | LC_ALL=C sort -u)"
  # An installer sequence that parses to nothing, or without the steps this overlay is built around, is not "no difference": the
  # parser did not understand the file (flow-style lists, a header with a comment it does not know, a renamed key), or the
  # installer was restructured. Either way a human has to look.
  if [ -z "$ups" ]; then
    ci_g_fail "$1" "could not read an install sequence out of the installer's settings_online.conf (empty, flow-style lists or a renamed 'sequence' key), so a step it gained would go unnoticed ($why)"
  else
    for a in $(printf '%s' "$anchors" | tr ',' ' '); do
      printf '%s\n' "$ups" | grep -qxF -- "$a" || missing="$missing $a"
    done
    [ -z "$missing" ] || ci_g_fail "$1" "the install sequence read from the installer's settings_online.conf lacks${missing}, which the overlay is built around: the file was restructured or only partly understood ($why)"
  fi
  ci_g_sequence "$ours" | LC_ALL=C sort -u > "${CI_G_TMP:-/tmp}/ci-g-ours.$$"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$allow" in *",${entry#*:},"*) continue ;; esac
    ci_g_fail "$1" "the installer's install sequence has '$entry', which the overlay neither contains nor drops on purpose ($why)"
  done < <(printf '%s\n' "$ups" | LC_ALL=C comm -23 - "${CI_G_TMP:-/tmp}/ci-g-ours.$$")
  rm -f "${CI_G_TMP:-/tmp}/ci-g-ours.$$"
}
ci_g_g_list_drift() {  # severity CONF:KEY allow=a,b why
  local conf="${2%%:*}" key="${2#*:}" up ours allow ups mine entry
  up="$(ci_g_path "/etc/calamares/modules/$conf.conf")"
  ours="$(ci_g_overlay)/modules/$conf.conf"
  allow=",${3#allow=},"
  [ -f "$up" ] || { ci_g_fail "$1" "the installer has no modules/$conf.conf any more ($4)"; return 0; }
  [ -f "$ours" ] || { ci_g_fail "$1" "the overlay has no modules/$conf.conf ($4)"; return 0; }
  ups="$(ci_g_list "$up" "$key" | LC_ALL=C sort -u)"
  mine="$(ci_g_list "$ours" "$key" | LC_ALL=C sort -u)"
  if [ -z "$ups" ]; then
    ci_g_fail "$1" "could not read the list '$key' of the installer's modules/$conf.conf (empty, flow style or renamed), so an item it gained would go unnoticed ($4)"
    return 0
  fi
  [ -n "$mine" ] || { ci_g_fail "$1" "the overlay's modules/$conf.conf has no list '$key' ($4)"; return 0; }
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$allow" in *",$entry,"*) continue ;; esac
    ci_g_fail "$1" "the installer's modules/$conf.conf '$key' has '$entry', which the overlay's frozen copy neither contains nor drops on purpose ($4)"
  done < <(LC_ALL=C comm -23 <(printf '%s\n' "$ups") <(printf '%s\n' "$mine"))
}
ci_g_g_code_names() {  # severity module-path listfile-in-overlay why
  local p list code known n
  p="$(ci_g_path "$2")"; list="$(ci_g_overlay)/$3"
  [ -f "$p" ] || { ci_g_fail "$1" "missing $2 in the installer, so the packages it adds in code cannot be compared with $3 ($4)"; return 0; }
  [ -f "$list" ] || { ci_g_fail "$1" "the overlay has no $3 ($4)"; return 0; }
  code="$(ci_g_code_names "$p")"
  known="$(awk -F'|' '{ sub(/#.*/, "") } NF >= 2 { gsub(/[[:space:]]/, "", $2); if ($2 != "") print $2 }' "$list" | LC_ALL=C sort -u)"
  [ -n "$code" ] || { ci_g_fail "$1" "found no base_packages additions in $2 (the code was restructured), so $3 cannot be checked against it ($4)"; return 0; }
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    ci_g_fail "$1" "$2 adds '$n' to the base system, which $3 does not list: the package preflight would not check it ($4)"
  done < <(LC_ALL=C comm -23 <(printf '%s\n' "$code") <(printf '%s\n' "$known"))
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    ci_g_fail "$1" "$3 lists '$n', which $2 no longer adds ($4)"
  done < <(LC_ALL=C comm -13 <(printf '%s\n' "$code") <(printf '%s\n' "$known"))
}
ci_g_g_settings() {  # severity why
  local ours entry mod inst id m c found branding comp
  ours="$(ci_g_overlay)/settings.conf"
  [ -f "$ours" ] || { ci_g_fail "$1" "the overlay has no settings.conf ($2)"; return 0; }
  local instances; instances="$(ci_g_instances "$ours")"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    mod="${entry#*:}"; inst=""
    case "$mod" in *@*) inst="${mod#*@}"; mod="${mod%@*}" ;; esac
    [ -f "$(ci_g_path "/usr/lib/calamares/modules/$mod/module.desc")" ] \
      || ci_g_fail "$1" "settings.conf uses module '$mod' (entry '${entry#*:}') but the installer has no usr/lib/calamares/modules/$mod ($2)"
    if [ -n "$inst" ]; then
      found=""
      while IFS=$'\t' read -r id m c; do
        if [ "$id" = "$inst" ] && [ "$m" = "$mod" ]; then found="$c"; fi
      done <<EOF
$instances
EOF
      [ -n "$found" ] || ci_g_fail "$1" "settings.conf entry '${entry#*:}' has no matching instance (module $mod, id $inst) ($2)"
    fi
  done < <(ci_g_sequence "$ours")
  while IFS=$'\t' read -r id m c; do
    [ -n "$id" ] || continue
    [ -f "$(ci_g_path "/usr/lib/calamares/modules/$m/module.desc")" ] \
      || ci_g_fail "$1" "instance $m@$id uses a module the installer does not have ($2)"
    if [ ! -f "$(ci_g_overlay)/modules/$c" ] && [ ! -f "$(ci_g_path "/etc/calamares/modules/$c")" ]; then
      ci_g_fail "$1" "instance $m@$id needs modules/$c, which neither the overlay nor the installer has ($2)"
    fi
  done <<EOF
$instances
EOF
  branding="$(ci_g_value "$ours" branding)"
  if [ -z "$branding" ]; then
    ci_g_fail "$1" "settings.conf names no branding component ($2)"
  elif [ ! -f "$(ci_g_overlay)/branding/$branding/branding.desc" ]; then
    ci_g_fail "$1" "settings.conf uses branding '$branding' but the overlay has no branding/$branding/branding.desc ($2)"
  else
    comp="$(ci_g_value "$(ci_g_overlay)/branding/$branding/branding.desc" componentName)"
    [ "$comp" = "$branding" ] || ci_g_fail "$1" "branding/$branding/branding.desc says componentName '$comp'; Calamares requires it to equal the directory name ($2)"
  fi
}

ci_g_g_shell_timeouts() {  # severity why
  local helper out rc=0 line root
  helper="$(ci_g_overlay)/lib/ci-shellprocess.py"
  [ -f "$helper" ] || { ci_g_fail "$1" "the overlay has no lib/ci-shellprocess.py, so the time limits of the shellprocess steps cannot be checked ($2)"; return 0; }
  command -v python3 >/dev/null 2>&1 || { ci_g_fail "$1" "python3 is not installed, so the time limits of the shellprocess steps cannot be checked ($2)"; return 0; }
  # ci_g_root is empty for the live system itself (no prefix); the reader joins paths to it, so it gets "/" then, never a relative path.
  root="$(ci_g_root)"
  out="$(python3 -I "$helper" audit "${root:-/}" "$(ci_g_overlay)" 2>&1)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) while IFS= read -r line; do
         [ -n "$line" ] || continue
         ci_g_fail "$1" "$line ($2)"
       done <<PROBLEMS
$out
PROBLEMS
       ;;
    *) ci_g_fail "$1" "lib/ci-shellprocess.py could not run (exit $rc: $(printf '%s' "$out" | head -n 1)), so the time limits of the shellprocess steps cannot be checked ($2)" ;;
  esac
}

# ci_g_run_table FILE: run every guard of a guards.list.
ci_g_run_table() {
  local file="$1" line sev kind a1 a2 why
  [ -f "$file" ] || { ci_g_critical "guard table $file is missing"; return 0; }
  CI_G_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci-guards.XXXXXX")"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *'|'*) ;; *) continue ;; esac
    IFS='|' read -r sev kind a1 a2 why <<EOF
$line
EOF
    sev="$(ci_g_trim "$sev")"; kind="$(ci_g_trim "$kind")"; a1="$(ci_g_trim "$a1")"; a2="$(ci_g_trim "$a2")"; why="$(ci_g_trim "$why")"
    case "$sev" in critical|cosmetic) ;; *) ci_g_critical "guards.list: unknown severity '$sev' in: $line"; continue ;; esac
    case "$kind" in
      exists)         ci_g_g_exists "$sev" "$a1" "$why" ;;
      contains)       ci_g_g_contains "$sev" "$a1" "$a2" "$why" ;;
      oexists)        ci_g_g_oexists "$sev" "$a1" "$why" ;;
      lexists)        ci_g_g_lexists "$sev" "$a1" "$why" ;;
      keys)           ci_g_g_keys "$sev" "$a1" "$why" ;;
      settings-drift) ci_g_g_settings_drift "$sev" "$a1" "$a2" "$why" ;;
      list-drift)     ci_g_g_list_drift "$sev" "$a1" "$a2" "$why" ;;
      code-names)     ci_g_g_code_names "$sev" "$a1" "$a2" "$why" ;;
      settings)       ci_g_g_settings "$sev" "$why" ;;
      shell-timeouts) ci_g_g_shell_timeouts "$sev" "$why" ;;
      *) ci_g_critical "guards.list: unknown guard kind '$kind' in: $line" ;;
    esac
  done < "$file"
  rm -rf "$CI_G_TMP"
  CI_G_TMP=""
}

# ci_g_report: print what ci_g_run_table collected. Return 1 when something critical failed.
ci_g_report() {
  if [ "$CI_G_WARN_COUNT" -gt 0 ]; then
    printf 'WARN: %s cosmetic installer guard(s) failed; the overlay is applied anyway, some installer text may still say CachyOS:\n%s' \
      "$CI_G_WARN_COUNT" "$CI_G_WARN_MSGS"
  fi
  if [ "$CI_G_CRIT_COUNT" -gt 0 ]; then
    printf 'FAIL: %s critical installer guard(s) failed:\n%s' "$CI_G_CRIT_COUNT" "$CI_G_CRIT_MSGS"
    return 1
  fi
  printf 'guards: all critical checks passed (%s cosmetic warning(s))\n' "$CI_G_WARN_COUNT"
  return 0
}

# --- applying the overlay ------------------------------------------------------------------------------------------------

# ci_g_apply_overlay: stage the final file set in a temporary directory, then copy it into the installer tree in one step, so a
# failure while building it leaves the installer exactly as it was.
#   settings.conf        -> etc/calamares/settings.conf
#   modules/*            -> etc/calamares/modules/
#   branding/<name>/     -> usr/share/calamares/branding/<name>/
# The overlay's scripts/ and target/ stay where they are (/usr/share/ci-os/calamares): the shellprocess steps run them from there.
ci_g_apply_overlay() {
  local ov stage priv rc=0 old_umask
  ov="$(ci_g_overlay)"
  priv="${CI_OS_SUDO-sudo}"
  old_umask="$(umask)"; umask 022   # the files are read by root-run Calamares, but keep them world-readable like the package's
  stage="$(mktemp -d "${TMPDIR:-/tmp}/ci-overlay.XXXXXX")" || { umask "$old_umask"; return 1; }
  mkdir -p "$stage/etc/calamares/modules" "$stage/usr/share/calamares/branding" || rc=1
  if [ "$rc" -eq 0 ]; then cp "$ov/settings.conf" "$stage/etc/calamares/settings.conf" || rc=1; fi
  if [ "$rc" -eq 0 ]; then cp "$ov"/modules/* "$stage/etc/calamares/modules/" || rc=1; fi
  if [ "$rc" -eq 0 ]; then cp -R "$ov"/branding/* "$stage/usr/share/calamares/branding/" || rc=1; fi
  if [ "$rc" -eq 0 ]; then
    find "$stage" -type d -exec chmod 755 {} + && find "$stage" -type f -exec chmod 644 {} + || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    # shellcheck disable=SC2086  # $priv is "sudo", or empty
    $priv mkdir -p "$(ci_g_path /etc/calamares/modules)" "$(ci_g_path /usr/share/calamares/branding)" \
      && $priv cp -R "$stage"/. "$(ci_g_root)/" || rc=1
  fi
  rm -rf "$stage"
  umask "$old_umask"
  return "$rc"
}

# ci_g_apply_cosmetic_patches FILE: patches.list lines "path | sed-expression | marker". The marker is a fixed string that must be
# in the file before the edit; a missing file or marker is a cosmetic warning, not a stop.
ci_g_apply_cosmetic_patches() {
  local file="$1" line path expr marker priv p tmp
  priv="${CI_OS_SUDO-sudo}"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    IFS='|' read -r path expr marker <<EOF
$line
EOF
    path="$(ci_g_trim "$path")"; expr="$(ci_g_trim "$expr")"; marker="$(ci_g_trim "$marker")"
    p="$(ci_g_path "$path")"
    if [ ! -f "$p" ]; then ci_g_warn "cosmetic patch: $path does not exist in the installer"; continue; fi
    if ! grep -qF -- "$marker" "$p"; then ci_g_warn "cosmetic patch: $path no longer contains '$marker' (already branded, or the text changed)"; continue; fi
    tmp="$(mktemp "${TMPDIR:-/tmp}/ci-patch.XXXXXX")"
    sed -e "$expr" "$p" > "$tmp"
    # shellcheck disable=SC2086
    if ! $priv cp "$tmp" "$p"; then ci_g_warn "cosmetic patch: could not write $path"; fi
    rm -f "$tmp"
  done < "$file"
}

# --- reporting to the person at the desktop ------------------------------------------------------------------------------

# ci_ui_notify TITLE TEXT: a passing desktop notification (nothing to click), if there is a desktop and notify-send.
ci_ui_notify() {
  [ "${CI_OS_NONINTERACTIVE:-0}" = 1 ] && return 0
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 0
  command -v notify-send >/dev/null 2>&1 && notify-send -a "Companion OS installer" "$1" "$2" || true
  return 0
}

# ci_ui_message KIND TITLE TEXT   (KIND: error | info). calamares-online.sh is started from a desktop icon, so a message that
# only goes to stderr is never seen. kdialog if present, then zenity, then notify-send (libnotify is in the live image),
# else stderr. CI_OS_NONINTERACTIVE=1 (tests, scripted use) prints to stderr only.
ci_ui_message() {
  local kind="$1" title="$2" text="$3"
  printf '%s: %s\n' "$title" "$text" >&2
  [ "${CI_OS_NONINTERACTIVE:-0}" = 1 ] && return 0
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 0
  if command -v kdialog >/dev/null 2>&1; then
    if [ "$kind" = error ]; then kdialog --title "$title" --error "$text" || true; else kdialog --title "$title" --msgbox "$text" || true; fi
  elif command -v zenity >/dev/null 2>&1; then
    if [ "$kind" = error ]; then zenity --error --no-markup --title "$title" --text "$text" || true; else zenity --info --no-markup --title "$title" --text "$text" || true; fi
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send -a "Companion OS installer" -u "$([ "$kind" = error ] && echo critical || echo normal)" "$title" "$text" || true
  fi
  return 0
}
