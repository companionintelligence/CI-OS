#!/usr/bin/env bash
# Workflow and secret guards: refuse the inputs that let a moved tag, a dangerous trigger, a blanket secret hand-over, a token left in a
# checkout or a private key enter the tree unnoticed.
#
# The workflows of this repository are manual-only (ci-local), so a rule that lived only in a workflow would never run on a push. This script
# is run by core/lib/check-repo.sh, which is what the PR checks workflow runs and what the author runs by hand. Its test,
# core/lib/tests/guards.sh, has a failing and a passing case for every rule and four planted defects.
#
# Usage: core/lib/check-guards.sh [ROOT]        (default: the repository this script is in)
# Output: one line per finding, "FAIL <rule> <file>:<line> <what>", and nothing at all when the tree is clean.
# Exit status: 0 clean, 1 at least one finding, 2 cannot run (no git or awk, ROOT is not a git work tree, awk failed).
#
# Rules. The ids are shared with the guards of the sibling repositories, so findings can be compared:
#   unpinned-uses         a "uses:" that can move: anything but ./local/path, docker://image@sha256:<64 hex>, or owner/repo[/path]@<40 lowercase
#                         hex> (a reusable workflow called by tag is refused as well). A trailing "# v1.2.3" comment is expected but not required.
#   dangerous-trigger     pull_request_target or workflow_run on any line that is not an ordinary comment, and in the ci-local gated block,
#                         so that restoring a gated trigger cannot bring one back. (An ordinary comment may name them.)
#   secrets-inherit       "secrets: inherit" in any spelling (extra spaces, quotes): name the secrets one by one. A job that calls a reusable
#                         workflow cannot name an environment, so "only in an environment-gated job" is never satisfiable.
#   missing-permissions   a workflow with no "permissions:" at the top level and not on every job (the default token of the repository is write).
#   checkout-credentials  an actions/checkout step without "persist-credentials: false" under its "with:" (the token would stay in .git/config).
#   private-key           a private-key block (RSA, EC, OPENSSH, PGP, PKCS8) in a tracked text file of at most 1 MiB. Public keys and certificates
#                         do not match. Every line is read, comment lines too: a key in a comment is still a key. The marker is
#                         assembled below at run time, so this file and its test do not match themselves.
#
# What it reads. Workflows (.github/workflows/*.yml and *.yaml, top level only, as GitHub reads them) and composite actions
# (.github/actions/**/action.yml or action.yaml), tracked files and new files that are not ignored, so the run before "git add" sees them.
# The YAML is read line by line: comment lines are ignored by every YAML rule except dangerous-trigger (which also reads the gated block); the
# text of a block scalar ("run: |") is not read as YAML. A flow-style step or secrets map ("- {uses: ...}") hides the value from a line reader,
# so it is refused rather than guessed at; the same goes for an alias or a folded value where a pinned reference is expected.
#
# Allow-list: core/lib/guards.allow, tab separated "rule<TAB>path-or-glob<TAB>reason" (a "#" line is a comment; the reason is at least 8
# characters and says why, and what removes the entry). It starts empty. An entry that excuses nothing any more is itself a finding
# (stale-allow), so the list only shrinks; a malformed entry is a finding too (allow-syntax). Neither can be allow-listed.
#
# Needs bash 3.2 (a stock macOS), git, awk (BSD, mawk and gawk all do), grep, wc.
#
# © Companion Intelligence, Lifescope Inc
set -uo pipefail

usage() { sed -n '2,/^# Needs bash/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
command -v git >/dev/null 2>&1 || { echo "check-guards: git is not installed" >&2; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "check-guards: awk is not installed" >&2; exit 2; }
[ -d "$ROOT" ] || { echo "check-guards: no such directory: $ROOT" >&2; exit 2; }
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "check-guards: $ROOT is not a git work tree" >&2; exit 2; }
cd "$ROOT" || exit 2

ALLOW="core/lib/guards.allow"
RULES="unpinned-uses dangerous-trigger secrets-inherit missing-permissions checkout-credentials private-key"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-guards.XXXXXX")" || { echo "check-guards: cannot make a temporary directory" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
FINDINGS="$TMP/findings"   # rule<TAB>file<TAB>line<TAB>what, before the allow-list is applied
META="$TMP/meta"           # problems with the allow-list itself, printed as they are
: > "$FINDINGS"; : > "$META"

# --- the YAML reader (awk) ----------------------------------------------------------------------------------------------------------
# Pass one sorts every line into a kind (blank, ordinary comment, gated comment, marker, block-scalar text, live); pass two applies the rules.
cat > "$TMP/guards.awk" <<'AWK'
function add(rule, ln, what) {
  gsub(/[\t\n]/, " ", what)
  printf "%s\t%s\t%d\t%s\n", rule, file, ln, what
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# the text before an inline comment (a "#" that follows a blank)
function uncomment(s) { if (match(s, /[ \t]#/)) s = substr(s, 1, RSTART - 1); return s }
# the key of a "key: value" line, without quotes; "" when the line is not a mapping entry
function keyname(s,   j) {
  j = match(s, /:([ \t]|$)/)
  if (j == 0) return ""
  s = substr(s, 1, j - 1)
  gsub(/^["' \t]+/, "", s); gsub(/["' \t]+$/, "", s)
  return s
}
# the text after "key:"
function keyvalue(s,   j) {
  j = match(s, /:([ \t]|$)/)
  if (j == 0) return ""
  return trim(substr(s, j + 1))
}
# a YAML scalar without its quotes or its trailing comment
function scalar(v,   q, j) {
  if (v == "") return ""
  q = substr(v, 1, 1)
  if (q == "\"" || q == "'") {
    j = index(substr(v, 2), q)
    if (j == 0) return v
    return substr(v, 2, j - 1)
  }
  return trim(uncomment(v))
}
# s contains the word w (not inside a longer name)
function has_word(s, w,   from, p, pre, post, lw) {
  lw = length(w); from = 1
  while (from <= length(s)) {
    p = index(substr(s, from), w)
    if (p == 0) return 0
    p = from + p - 1
    pre = (p > 1) ? substr(s, p - 1, 1) : ""
    post = substr(s, p + lw, 1)
    if (pre !~ /[A-Za-z0-9_]/ && post !~ /[A-Za-z0-9_]/) return 1
    from = p + 1
  }
  return 0
}
function trigger(s, ln, where) {
  if (has_word(s, "pull_request_target")) add("dangerous-trigger", ln, "pull_request_target runs code from a fork with the repository secrets and a write token" where)
  if (has_word(s, "workflow_run")) add("dangerous-trigger", ln, "workflow_run runs with secrets on the output of another workflow, which may have run fork code" where)
}
# the pin of an action or a called workflow: a full 40 character commit sha in lowercase hex (a tag or a branch can be moved)
function pinned_ref(ref) { return (length(ref) == 40 && ref ~ /^[0-9a-f]+$/) }
function check_uses(val, ln,   at, j, path, ref, digest) {
  if (val == "") { add("unpinned-uses", ln, "uses: has no value"); return }
  if (substr(val, 1, 2) == "./") return
  if (substr(val, 1, 9) == "docker://") {
    at = index(val, "@sha256:")
    if (at > 10) {
      digest = substr(val, at + 8)
      if (length(digest) == 64 && digest ~ /^[0-9a-f]+$/) return
    }
    add("unpinned-uses", ln, substr(val, 1, 100) " is not pinned by a sha256 digest")
    return
  }
  at = 0
  for (j = length(val); j >= 1; j--) if (substr(val, j, 1) == "@") { at = j; break }
  if (at > 1) {
    path = substr(val, 1, at - 1); ref = substr(val, at + 1)
    if (path ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.\/-]+$/ && pinned_ref(ref)) return
  }
  add("unpinned-uses", ln, substr(val, 1, 100) " is not pinned to a full 40 character lowercase commit sha (a tag or a branch can move)")
}
# the step that holds the actions/checkout line i must set persist-credentials: false under with:
function check_checkout(i,   kc, s, e, j, in_with, ok, b, v) {
  kc = KC[i]; s = i
  while (s > 0 && !(K[s] == "L" && DASH[s] && KC[s] == kc)) {
    if (K[s] == "L" && IND[s] < kc) { s = 0; break }
    s--
  }
  if (s < 1) { add("checkout-credentials", i, "actions/checkout is not inside a list of steps, so its with: block cannot be read"); return }
  e = i
  for (j = i + 1; j <= n; j++) {
    if (K[j] == "L" && IND[j] < kc) break
    if (K[j] == "L" || K[j] == "S") e = j
  }
  in_with = 0; ok = 0
  for (j = s; j <= e; j++) {
    if (K[j] != "L") continue
    b = BODY[j]
    if (KC[j] == kc) {
      in_with = (keyname(b) == "with")
      if (in_with && b ~ /^with[ \t]*:[ \t]*\{.*persist-credentials[ \t]*:[ \t]*["']?[Ff]alse["']?/) ok = 1
    } else if (in_with && IND[j] > kc && keyname(b) == "persist-credentials") {
      v = scalar(keyvalue(b))
      if (tolower(v) == "false") ok = 1
    }
  }
  if (!ok) add("checkout-credentials", i, "actions/checkout without persist-credentials: false leaves the token in .git/config for every later step")
}
function end_job() {
  if (injob) {
    njobs++
    if (!jperm) { nmiss++; MNAME[nmiss] = jname; MLINE[nmiss] = jline }
  }
  injob = 0
}

BEGIN {
  kind = ENVIRON["GUARD_KIND"]; file = ENVIRON["GUARD_FILE"]
  n = 0; gated = 0; blk = 0; blk_ind = 0
  top_perm = 0; in_jobs = 0; injob = 0; njobs = 0; nmiss = 0; job_ind = -1
}

# pass one: what kind of line is this?   B blank, C ordinary comment, G comment inside the gated block, M gate marker, S block-scalar text, L live
{
  line = $0
  sub("\r$", "", line)
  n++
  match(line, /^ */)
  ind = RLENGTH
  t = substr(line, ind + 1)
  IND[n] = ind; KC[n] = ind; DASH[n] = 0; BODY[n] = t
  if (t ~ /^[ \t]*$/) { K[n] = "B"; next }
  if (blk) {
    if (ind > blk_ind) { K[n] = "S"; next }
    blk = 0
  }
  if (t ~ /^#[ \t]*>>>[ \t]*ci-local:gated/) { K[n] = "M"; gated = 1; next }
  if (t ~ /^#[ \t]*<<<[ \t]*ci-local:gated/) { K[n] = "M"; gated = 0; next }
  if (t ~ /^#/) {
    # the text after the "#"; only the trigger rule reads it, and only inside the gated block
    b = substr(t, 2); sub(/^[ \t]/, "", b); BODY[n] = b
    K[n] = gated ? "G" : "C"
    next
  }
  K[n] = "L"
  if (t ~ /^-([ \t]|$)/) {
    DASH[n] = 1
    b = substr(t, 2)
    match(b, /^[ \t]*/)
    KC[n] = ind + 1 + RLENGTH
    BODY[n] = substr(b, RLENGTH + 1)
  }
  v = BODY[n]
  if (v ~ /:[ \t]+[|>][-+0-9]*[ \t]*(#.*)?$/ || (DASH[n] && v ~ /^[|>][-+0-9]*[ \t]*(#.*)?$/)) {
    blk = 1
    blk_ind = (DASH[n] && v ~ /^[|>]/) ? ind : KC[n]
  }
}

# pass two: the rules
END {
  for (i = 1; i <= n; i++) {
    k = K[i]
    if (k == "B" || k == "M") continue
    if (k == "C") continue   # an ordinary comment: no rule reads it (core/lib/tests/guards.sh plants a guard that does)
    if (k == "G") { trigger(uncomment(BODY[i]), i, " (inside the ci-local gated block: restoring that trigger would add it)"); continue }
    if (k == "S") { if (BODY[i] !~ /^#/) trigger(uncomment(BODY[i]), i, ""); continue }
    b = BODY[i]   # a live line
    trigger(uncomment(b), i, "")

    if (b ~ /^["']?uses["']?[ \t]*:/) {
      val = scalar(keyvalue(b))
      check_uses(val, i)
      lv = tolower(val)
      if (lv == "actions/checkout" || index(lv, "actions/checkout@") == 1) check_checkout(i)
    } else if (b ~ /(^|:[ \t]+)\{/ && b ~ /[ \t{,"']uses["']?[ \t]*:/) {
      add("unpinned-uses", i, "a flow-style mapping hides the action reference from this guard; write the step as a block mapping")
    }
    if (b ~ /^["']?secrets["']?[ \t]*:[ \t]*["']?inherit["']?[ \t]*(#.*)?$/ || (b ~ /(^|:[ \t]+)\{/ && b ~ /[ \t{,"']secrets["']?[ \t]*:[ \t]*["']?inherit/))
      add("secrets-inherit", i, "secrets: inherit hands every secret to the called workflow; list the secrets it needs by name")

    if (kind == "workflow") {
      if (IND[i] == 0 && !DASH[i]) {
        end_job(); in_jobs = 0
        key = keyname(b)
        if (key == "permissions") top_perm = 1
        if (key == "jobs") { in_jobs = 1; job_ind = -1 }
      } else if (in_jobs) {
        if (job_ind < 0) job_ind = IND[i]
        if (IND[i] == job_ind && !DASH[i]) {
          end_job(); injob = 1; jname = keyname(b); jline = i; jperm = 0; jchild = -1
        } else if (injob && IND[i] > job_ind) {
          if (jchild < 0) jchild = IND[i]
          if (IND[i] == jchild && !DASH[i] && keyname(b) == "permissions") jperm = 1
        }
      }
    }
  }
  end_job()
  if (kind == "workflow" && !top_perm) {
    for (m = 1; m <= nmiss; m++)
      add("missing-permissions", MLINE[m], "job " MNAME[m] " has no permissions block and the workflow has none at the top level (the default token may be able to write)")
    if (njobs == 0) add("missing-permissions", 1, "the workflow has no permissions block")
  }
}
AWK

# scan_yaml KIND FILE: run the reader on one workflow ("workflow") or composite action ("action")
scan_yaml() {
  if ! GUARD_KIND="$1" GUARD_FILE="$2" awk -f "$TMP/guards.awk" "$2" >> "$FINDINGS" 2> "$TMP/awk.err"; then
    echo "check-guards: awk could not read $2: $(head -n 1 "$TMP/awk.err")" >&2
    exit 2
  fi
}

while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  case "$f" in
    .github/workflows/*/*) ;;   # GitHub reads only the top level of this directory
    .github/workflows/*.yml|.github/workflows/*.yaml) scan_yaml workflow "$f" ;;
    .github/actions/action.yml|.github/actions/action.yaml|.github/actions/*/action.yml|.github/actions/*/action.yaml) scan_yaml action "$f" ;;
  esac
done < <(git ls-files -co --exclude-standard -z -- .github)

# --- private keys in tracked text files --------------------------------------------------------------------------------------------
# The header is put together here, so that neither this file nor its test contains a line that a scanner (this one included) would report.
KD='-----'; KB='BEGIN'; KP='PRIVATE KEY'
KEY_RE="${KD}${KB} [A-Z0-9 ]*${KP}( BLOCK)?${KD}"
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  size="$(wc -c < "$f" | tr -d ' ')"
  [ "$size" -le 1048576 ] || continue
  while IFS= read -r ln; do
    printf 'private-key\t%s\t%s\t%s\n' "$f" "$ln" "a private key block starts here; take it out of the tree and rotate the key" >> "$FINDINGS"
  done < <(grep -n -I -E -e "$KEY_RE" -- "$f" 2>/dev/null | cut -d: -f1)
done < <(git grep -I -l -z -E -e "$KEY_RE" 2>/dev/null)

# --- the allow-list ----------------------------------------------------------------------------------------------------------------
AL_RULE=(); AL_PATH=(); AL_LINE=(); AL_USED=()
if [ -f "$ALLOW" ]; then
  alln=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    alln=$((alln + 1))
    raw="${raw%$'\r'}"
    lead="${raw%%[![:space:]]*}"; body="${raw#"$lead"}"
    case "$body" in ''|'#'*) continue ;; esac
    a_rule=""; a_path=""; a_why=""
    IFS=$'\t' read -r a_rule a_path a_why <<EOF
$raw
EOF
    problem=""
    if [ -z "$a_rule" ] || [ -z "$a_path" ] || [ -z "$a_why" ]; then
      problem="expected three tab separated columns: rule, path or glob, reason"
    else
      case " $RULES " in *" $a_rule "*) ;; *) problem="unknown rule '$a_rule' (the rules are: $RULES)" ;; esac
      if [ -z "$problem" ] && [ "${#a_why}" -lt 8 ]; then problem="the reason must say why, in at least 8 characters"; fi
      case "$a_path" in /*|./*|*..*) [ -n "$problem" ] || problem="the path is relative to the repository root, without a leading ./ and without .." ;; esac
    fi
    if [ -n "$problem" ]; then
      printf 'FAIL allow-syntax %s:%s %s\n' "$ALLOW" "$alln" "$problem" >> "$META"
      continue
    fi
    AL_RULE+=("$a_rule"); AL_PATH+=("$a_path"); AL_LINE+=("$alln"); AL_USED+=(0)
  done < "$ALLOW"
fi

# allowed RULE FILE: 0 when an entry excuses this finding (the entry is then marked as used)
allowed() {
  local i=0 hit=1
  while [ "$i" -lt "${#AL_RULE[@]}" ]; do
    if [ "${AL_RULE[$i]}" = "$1" ]; then
      # shellcheck disable=SC2254  # the path column is a glob on purpose
      case "$2" in ${AL_PATH[$i]}) AL_USED[i]=1; hit=0 ;; esac
    fi
    i=$((i + 1))
  done
  return $hit
}

failed=0
while IFS=$'\t' read -r rule file ln what; do
  [ -n "$rule" ] || continue
  if allowed "$rule" "$file"; then continue; fi
  printf 'FAIL %s %s:%s %s\n' "$rule" "$file" "$ln" "$what"
  failed=1
done < "$FINDINGS"

i=0
while [ "$i" -lt "${#AL_RULE[@]}" ]; do
  if [ "${AL_USED[$i]}" = 0 ]; then
    printf 'FAIL stale-allow %s:%s %s %s: no finding matches this entry any more; delete the line\n' "$ALLOW" "${AL_LINE[$i]}" "${AL_RULE[$i]}" "${AL_PATH[$i]}"
    failed=1
  fi
  i=$((i + 1))
done
if [ -s "$META" ]; then cat "$META"; failed=1; fi

[ "$failed" -eq 0 ]
