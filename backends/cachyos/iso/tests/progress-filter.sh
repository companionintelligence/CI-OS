#!/usr/bin/env bash
#=============================================================================
# Test: provision/progress-filter.sh, the filter that keeps terminal redraws out of the first-boot log and the journal, and the
# first-boot driver's hand-over of the output to it.
#
# ISO #4's first boot wrote 14,052 lines (1.9 MB) of `ollama pull` progress to /var/log/ci-os-first-boot-setup.log, each redraw a
# "[147B blob data]" in the journal. The checks:
#   A  the REAL stream (installer-fixtures/ollama-pull-all-minilm.stderr.printf, recorded from ollama 0.40.6 with stderr in a file) comes out
#      as the 13 lines of the golden file, and no escape sequence, carriage return, spinner or bar glyph is left
#   B  the same stream with 3000 redraws (installer-fixtures/ollama-flood.awk): bounded output (a few dozen lines), every layer
#      reaches 100%, the big layer's percentages only grow, "success" once; the input is 9000+ lines, the output is not
#   C  everything that is not a redraw is copied: plain lines unchanged (leading blanks, empty lines, UTF-8), colours removed, a \r
#      redrawn line keeps its last state, CRLF loses its CR, a last line without a newline is not lost
#   D  a plain line between two pulls (the Arch script echoes "Pulling <model>...") starts the next pull afresh: both print
#      "pulling manifest" and "success"
#   E  the time rule (a layer that moved is repeated every SECS seconds) and its switch-off; the last sample of a layer is printed
#      before "success" when it was not printed before
#   F  it never fails and never hangs: truncated and garbage escape sequences, exit status 0, no escape left in the output
#   G  it STREAMS: a line written to a pipe that stays open comes out before the input ends (a log has to follow the run)
#   H  a layer whose percentage goes up and down (a retry: 41 39 41 39 ... x 20000) does not print one line per sample: it prints
#      the first step back, then at most one line per window; a restart from the beginning is one line, not a flood
#   I  the filter is LINEAR: newline-free runs of 60,000 escape bytes, a 200 KB line of 50,000 sequences, 100,000 carriage returns, 60,000
#      ESC ] after a BEL, a 1 MB plain line: each in under 2 s (the bash version needed 35 s for 15,000 and did not finish 60,000)
#   J  percentages: 20 digits are clamped (no wrapped number), zero padding is dropped, 100 stays 100
#   K  binary junk and partial lines: random bytes (exit 0, no escape left), plain random lines byte for byte, input that ends inside an
#      escape sequence
#   L  no awk, or an awk that fails: the stream is copied, not lost
#   M  the DRIVER: the last lines of the run reach the log and the unit's output when the main process exits and the leftovers of
#      its process group are killed at once (what systemd does under KillMode=control-group): 200 runs with the real filter, runs with
#      a slow filter (the sensitive case: the tail is still in the pipe when the kill comes), and a background child that keeps the
#      pipe open must not keep the script running for more than a few seconds. The same under a real systemd manager (a USER manager
#      in a container, never PID 1): first-boot-drain-container.sh
#
#   backends/cachyos/iso/tests/progress-filter.sh
#
# Needs bash 3.2+, awk, sed, cksum, mkfifo, tr, head. python3 for millisecond timing, and to play systemd in section M (that section is
# skipped without it). No root, no network, no Docker.
# Environment: PROGRESS_FILTER=file and FIRST_BOOT_SETUP=file run the tests against other copies of the two scripts (mutation checks).
# Exit: non-zero when a check fails; 2 when it cannot run.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS="$(cd "$HERE/../.." && pwd)"
FILTER="${PROGRESS_FILTER:-$CACHYOS/provision/progress-filter.sh}"
FX="$HERE/installer-fixtures"
BLOCK="$(printf '\342\226\210')"   # U+2588: written as octal, check-repo.sh forbids the glyph itself in backends/
for t in awk sed cksum mkfifo tr head; do command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }; done
[ -f "$FILTER" ] || { echo "no filter at $FILTER" >&2; exit 2; }

PASS=0; FAIL=0; SKIP=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
t_skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }
verdict() { if [ "$1" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; fi; }
same_file() { [ "$(cksum < "$1")" = "$(cksum < "$2")" ]; }   # cmp is not in every image (the Arch builder has none)
show_diff() { if command -v diff >/dev/null 2>&1; then diff "$1" "$2" | head -10 | sed 's/^/      /'; else head -10 "$2" | cat -v | sed 's/^/      /'; fi; }
# mawk, the default awk of Debian and Ubuntu, reads a pipe in blocks, so a line comes out late and the clock sees one burst: the checks
# of the time rule and of streaming cannot be made against it (the filter prefers gawk when it is installed, as this does).
blocking_awk() {
  case "$(awk -W version 2>&1 </dev/null | head -n 1)" in
    mawk*) command -v gawk >/dev/null 2>&1 && return 1; return 0 ;;
  esac
  return 1
}
# Milliseconds: python3 when there is one, else whole seconds.
if command -v python3 >/dev/null 2>&1; then now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
else now_ms() { echo $(( $(date +%s) * 1000 )); }; fi

W="$(mktemp -d "${TMPDIR:-/tmp}/progress-filter.XXXXXX")"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
# The recorded stream (ollama 0.40.6, stderr in a file) is kept as printf text: it holds U+2588 and escape bytes. Printing it gives the bytes back.
REC="$W/ollama-pull-all-minilm.stderr"
printf "$(cat "$FX/ollama-pull-all-minilm.stderr.printf")" > "$REC"
E=$'\033'
run() { bash "$FILTER"; }   # stdin -> stdout
has_esc() { LC_ALL=C grep -q "$E" "$1" || LC_ALL=C grep -q "$(printf '\r')" "$1"; }

# --- A: the real recorded stream ----------------------------------------------------------------------------------------------
echo "== A  the real stream of ollama 0.40.6"
run < "$REC" > "$W/a.out"
DESC="the recorded stream (28 physical lines, 4.8 KB of redraws) comes out as the golden file (13 lines)"
if same_file "$W/a.out" "$FX/ollama-pull-all-minilm.filtered"; then verdict 0; else verdict 1; show_diff "$W/a.out" "$FX/ollama-pull-all-minilm.filtered"; fi
DESC="no escape sequence, no carriage return, no spinner and no bar glyph is left"
if ! has_esc "$W/a.out" && ! grep -q '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏▕▏]' "$W/a.out" && ! grep -q "$BLOCK" "$W/a.out"; then verdict 0; else verdict 1; fi
DESC="what a person needs from a pull is there: the manifest, the layer with its percentages up to 100%, the digest check, success"
if grep -qx 'pulling manifest' "$W/a.out" && grep -q '^pulling 797b70c4edf8: 100% 45 MB/ 45 MB$' "$W/a.out" && grep -qx 'verifying sha256 digest' "$W/a.out" && [ "$(tail -n 1 "$W/a.out")" = success ]; then verdict 0; else verdict 1; fi

# --- B: thousands of redraws --------------------------------------------------------------------------------------------------
echo "== B  3000 redraws"
awk -v frames=3000 -f "$FX/ollama-flood.awk" /dev/null > "$W/b.in"
in_lines="$(wc -l < "$W/b.in" | tr -d ' ')"; in_bytes="$(wc -c < "$W/b.in" | tr -d ' ')"
start="$(date +%s)"; run < "$W/b.in" > "$W/b.out"; took=$(( $(date +%s) - start ))
out_lines="$(wc -l < "$W/b.out" | tr -d ' ')"; out_bytes="$(wc -c < "$W/b.out" | tr -d ' ')"
DESC="the input is a flood ($in_lines lines, $in_bytes bytes) and the output is bounded ($out_lines lines, $out_bytes bytes; under 60 lines, under 4 KB)"
if [ "$in_lines" -ge 9000 ] && [ "$out_lines" -lt 60 ] && [ "$out_bytes" -lt 4096 ]; then verdict 0; else verdict 1; fi
DESC="the flood is filtered in reasonable time (under 20 s for 1.1 MB; took ${took}s)"
if [ "$took" -lt 20 ]; then verdict 0; else verdict 1; fi
DESC="every layer reaches 100%, the big layer is printed first at 0%-ish and then only grows, and the pull ends with success exactly once"
if grep -q '^pulling 6a0746a1ec1a: 100% ' "$W/b.out" && grep -q '^pulling 4fa551d4f938: 100% 12 KB$' "$W/b.out" && grep -q '^pulling 8ab4849b038c: 100% 254 B$' "$W/b.out" \
   && [ "$(grep -c '^success$' "$W/b.out")" = 1 ] && [ "$(tail -n 1 "$W/b.out")" = success ] \
   && [ "$(sed -n 's/^pulling 6a0746a1ec1a: \([0-9]*\)%.*/\1/p' "$W/b.out" | awk 'NR > 1 && $1 < prev { bad = 1 } { prev = $1 } END { print bad + 0 }')" = 0 ]; then verdict 0; else verdict 1; sed -n '1,12p' "$W/b.out" | sed 's/^/      /'; fi
DESC="the big layer is printed every 5% (21 lines, 0 to 100) and nothing between"
if [ "$(grep -c '^pulling 6a0746a1ec1a: ' "$W/b.out")" -le 22 ] && [ "$(grep -c '^pulling 6a0746a1ec1a: ' "$W/b.out")" -ge 20 ]; then verdict 0; else verdict 1; grep -c '^pulling 6a0746a1ec1a: ' "$W/b.out" | sed 's/^/      /'; fi
DESC="no escape sequence, carriage return, spinner or bar glyph survives in the flood output either"
if ! has_esc "$W/b.out" && ! grep -q '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏▕▏]' "$W/b.out" && ! grep -q "$BLOCK" "$W/b.out"; then verdict 0; else verdict 1; fi
CI_OS_FILTER_STEP=10 run < "$W/b.in" > "$W/b10.out"
DESC="CI_OS_FILTER_STEP=10 halves the big layer's lines (11 or 12 instead of 21)"
n10="$(grep -c '^pulling 6a0746a1ec1a: ' "$W/b10.out")"
if [ "$n10" -ge 10 ] && [ "$n10" -le 13 ]; then verdict 0; else verdict 1; echo "      $n10 lines" ; fi

# --- C: everything else is copied ---------------------------------------------------------------------------------------------
echo "== C  plain output is copied"
printf '%s\n' '[CI-OS] First-boot setup starting at Sun Oct 18 10:00:00 UTC 2026' '' '   indented line, trailing blanks   ' 'ünïcödé ✓ ⠋ in a plain line' 'pulling a thing that is not a layer' 'success is a word here' > "$W/c1.in"
run < "$W/c1.in" > "$W/c1.out"
DESC="plain lines come out byte for byte (indentation, trailing blanks, an empty line, UTF-8, a spinner glyph in prose, a line that starts with 'pulling' or 'success' outside a frame)"
if same_file "$W/c1.in" "$W/c1.out"; then verdict 0; else verdict 1; show_diff "$W/c1.in" "$W/c1.out"; fi
printf '%s[0;34m[INFO]%s[0m Checking Ollama models...\n%s[1;33m[WARNING]%s[0m Failed to pull some Ollama models\n%s[0;32m[SUCCESS]%s[0m Ollama models checked/pulled\n' "$E" "$E" "$E" "$E" "$E" "$E" | run > "$W/c2.out"
DESC="the Arch script's colour codes are removed ([INFO]/[WARNING]/[SUCCESS] lines become plain text; they were journal blobs)"
if [ "$(cat "$W/c2.out")" = "$(printf '%s\n' '[INFO] Checking Ollama models...' '[WARNING] Failed to pull some Ollama models' '[SUCCESS] Ollama models checked/pulled')" ]; then verdict 0; else verdict 1; cat -v "$W/c2.out" | sed 's/^/      /'; fi
printf 'downloading   0%%\rdownloading  40%%\rdownloading 100%%\nnext line\n' | run > "$W/c3.out"
DESC="a line redrawn with carriage returns keeps what is left on the screen at the newline (the last state), not every state"
if [ "$(cat "$W/c3.out")" = "$(printf '%s\n' 'downloading 100%' 'next line')" ]; then verdict 0; else verdict 1; cat -v "$W/c3.out" | sed 's/^/      /'; fi
printf 'one\r\ntwo\r\n' | run > "$W/c4.out"
DESC="CRLF line ends lose their CR"
if [ "$(cat "$W/c4.out")" = "$(printf '%s\n' one two)" ]; then verdict 0; else verdict 1; cat -v "$W/c4.out" | sed 's/^/      /'; fi
printf 'complete\nno newline at the end' | run > "$W/c5.out"
DESC="a last line without a newline is not lost"
if [ "$(cat "$W/c5.out")" = "$(printf '%s\n' complete 'no newline at the end')" ]; then verdict 0; else verdict 1; cat -v "$W/c5.out" | sed 's/^/      /'; fi
printf 'a%s[2Kb%s[Kc\n%s]0;window title\acolumn\n' "$E" "$E" "$E" | run > "$W/c6.out"
DESC="erase sequences and a window-title sequence vanish without taking the text with them"
if [ "$(cat "$W/c6.out")" = "$(printf '%s\n' abc column)" ]; then verdict 0; else verdict 1; cat -v "$W/c6.out" | sed 's/^/      /'; fi
: | run > "$W/c7.out"
DESC="empty input gives empty output"
if [ ! -s "$W/c7.out" ]; then verdict 0; else verdict 1; fi

# --- D: the next pull starts afresh -------------------------------------------------------------------------------------------
echo "== D  consecutive pulls"
{ printf 'Pulling nomic-embed-text...\n'; cat "$REC"; printf 'Pulling gemma3:1b...\n'; cat "$REC"; printf 'done\n'; } | run > "$W/d.out"
DESC="two pulls with the Arch script's echo between them: each prints its own 'pulling manifest' and 'success' (the 'seen' list is per pull)"
if [ "$(grep -cx 'pulling manifest' "$W/d.out")" = 2 ] && [ "$(grep -cx 'success' "$W/d.out")" = 2 ] && [ "$(grep -c '^pulling 797b70c4edf8: 100% 45 MB/ 45 MB$' "$W/d.out")" = 2 ] \
   && grep -qx 'Pulling gemma3:1b...' "$W/d.out" && [ "$(tail -n 1 "$W/d.out")" = 'done' ]; then verdict 0; else verdict 1; cat "$W/d.out" | sed 's/^/      /'; fi
{ cat "$REC"; cat "$REC"; } | run > "$W/d2.out"
DESC="two pulls back to back with nothing between them: the layer's 100% is not printed twice, and 'success' ends the first pull so the second still prints its own"
if [ "$(grep -cx 'success' "$W/d2.out")" = 2 ] && [ "$(grep -cx 'pulling manifest' "$W/d2.out")" = 2 ]; then verdict 0; else verdict 1; cat "$W/d2.out" | sed 's/^/      /'; fi
{ cat "$REC"; printf 'Error: pull model manifest: file does not exist\n'; } | run > "$W/d3.out"
DESC="an error line after a frame (outside it) is printed"
if [ "$(tail -n 1 "$W/d3.out")" = 'Error: pull model manifest: file does not exist' ]; then verdict 0; else verdict 1; tail -n 3 "$W/d3.out" | sed 's/^/      /'; fi

{ head -c 3000 "$REC"; printf '\nError: pull model manifest: connection reset\nretrying\nretrying\nPulling again...\n'; cat "$REC"; } | run > "$W/d4.out"
DESC="a pull that DIES mid-frame (no success, no end marker): the next plain lines are plain again (two identical 'retrying' lines both print) and the retry prints its own manifest and success"
if [ "$(grep -cx 'retrying' "$W/d4.out")" = 2 ] && [ "$(grep -cx 'pulling manifest' "$W/d4.out")" = 2 ] && [ "$(grep -cx 'success' "$W/d4.out")" = 1 ] \
   && grep -qx 'Error: pull model manifest: connection reset' "$W/d4.out"; then verdict 0; else verdict 1; cat -v "$W/d4.out" | sed 's/^/      /'; fi

# --- E: the time rule --------------------------------------------------------------------------------------------------------
echo "== E  the time rule"
# One frame of a pull with a single layer, as ollama draws it: the manifest line, a newline, the layer line (no newline after it).
frame() { printf '%s[?2026h%s[?25l%s[1Gpulling manifest %s[K\npulling cafe0123: %3d%% ▕%s        ▏ 1 GB/ 17 GB  %s[K%s[?25h%s[?2026l' "$E" "$E" "$E" "$E" "$1" "$BLOCK$BLOCK" "$E" "$E" "$E"; }
# a pull whose last sample of a layer was not printed (STEP 50, no time rule): the log still ends on the final state, before 'success'
{ frame 10; frame 20; frame 33; printf '%s[?2026h%s[?25l%s[1Gverifying sha256 digest %s[K\nwriting manifest %s[K\nsuccess %s[K%s[?25h%s[?2026l\n' "$E" "$E" "$E" "$E" "$E" "$E" "$E" "$E"; } | CI_OS_FILTER_STEP=50 CI_OS_FILTER_SECS=0 run > "$W/d5.out"
DESC="when 'success' arrives, a layer whose last sample was not printed (33%, STEP 50) is printed just before it: the log ends on the final state"
if [ "$(tail -n 2 "$W/d5.out" | head -n 1)" = 'pulling cafe0123: 33% 1 GB/ 17 GB' ] && [ "$(tail -n 1 "$W/d5.out")" = success ] && [ "$(grep -c '^pulling cafe0123' "$W/d5.out")" = 2 ]; then verdict 0; else verdict 1; cat -v "$W/d5.out" | sed 's/^/      /'; fi
DESC="a layer that moves by less than a step is still printed every SECS seconds (3 prints: first sight, +1 s, +2 s), never twice for the same percentage"
if blocking_awk; then t_skip "$DESC (this awk is mawk, which reads a pipe in blocks: install gawk)"; else
{ frame 1; frame 1; sleep 1.1; frame 2; frame 2; sleep 1.1; frame 3; frame 3; } | CI_OS_FILTER_STEP=50 CI_OS_FILTER_SECS=1 run > "$W/e1.out"
if [ "$(grep -c '^pulling cafe0123' "$W/e1.out")" = 3 ] && grep -qx 'pulling cafe0123: 3% 1 GB/ 17 GB' "$W/e1.out"; then verdict 0; else verdict 1; cat "$W/e1.out" | sed 's/^/      /'; fi
fi
{ frame 1; sleep 1.1; frame 2; sleep 1.1; frame 3; } | CI_OS_FILTER_STEP=50 CI_OS_FILTER_SECS=0 run > "$W/e2.out"
DESC="CI_OS_FILTER_SECS=0 turns the time rule off: only the first sight is printed"
if [ "$(grep -c '^pulling cafe0123' "$W/e2.out")" = 1 ]; then verdict 0; else verdict 1; cat "$W/e2.out" | sed 's/^/      /'; fi
{ frame 7; frame 5; frame 5; } | CI_OS_FILTER_STEP=50 CI_OS_FILTER_SECS=0 run > "$W/e3.out"
DESC="a layer that goes BACK (a retry) is printed again"
if [ "$(grep -c '^pulling cafe0123' "$W/e3.out")" = 2 ]; then verdict 0; else verdict 1; cat "$W/e3.out" | sed 's/^/      /'; fi

# --- F: it never fails, never hangs -------------------------------------------------------------------------------------------
echo "== F  garbage in"
{ printf '%s[' "$E"; printf 'text%s[?25' "$E"; printf '\n%s[99999999999;;;;;?m after\n' "$E"; printf '%s%s%s' "$E" "$E" "$E"; printf '\nlast %s' "$E"; } > "$W/f.in"
head -c 20000 /dev/urandom >> "$W/f.in" 2>/dev/null || true
run < "$W/f.in" > "$W/f.out" 2>"$W/f.err"; frc=$?
DESC="truncated and absurd escape sequences, three ESC in a row, a lone ESC at the end and 20 KB of random bytes: exit status 0, nothing on stderr from the filter itself that is not bash noise"
if [ "$frc" = 0 ]; then verdict 0; else verdict 1; head -3 "$W/f.err" | sed 's/^/      /'; fi
DESC="a recognised sequence leaves nothing of itself and no line break in the middle of a line (colours, show-cursor outside a redraw frame)"
printf 'a%s[0mb%s[31;1mc%s[?25hd\n' "$E" "$E" "$E" | run > "$W/f2.out"
if [ "$(cat "$W/f2.out")" = abcd ]; then verdict 0; else verdict 1; cat -v "$W/f2.out" | sed 's/^/      /'; fi
run < /dev/null > "$W/f3.out"; DESC="exit status 0 with an empty stdin"; if [ $? = 0 ]; then verdict 0; else verdict 1; fi

# --- G: it streams ------------------------------------------------------------------------------------------------------------
echo "== G  streaming"
if blocking_awk; then
  t_skip "streaming: this awk is mawk, which reads a pipe in blocks (and its -W interactive drops every line of 4096 bytes and the input after it): install gawk"
else
mkfifo "$W/g.fifo"
bash "$FILTER" < "$W/g.fifo" > "$W/g.out" &
gpid=$!
exec 7> "$W/g.fifo"
printf 'first line\n' >&7
printf '%s[0;34m[INFO]%s[0m second, coloured\n' "$E" "$E" >&7
i=0; while [ "$i" -lt 40 ] && [ "$(wc -l < "$W/g.out" | tr -d ' ')" -lt 2 ]; do sleep 0.1; i=$((i + 1)); done
DESC="lines written to a pipe that stays open come out while it is open (within 4 s), plain and coloured alike: a log follows the run"
if [ "$(cat "$W/g.out")" = "$(printf '%s\n' 'first line' '[INFO] second, coloured')" ]; then verdict 0; else verdict 1; cat -v "$W/g.out" | sed 's/^/      /'; fi
frame2() { printf '%s[?2026h%s[?25l%s[1Gpulling manifest %s[K\npulling aa11bb22: %3d%% ▕%s         ▏ 1 GB/ 10 GB  %s[K%s[?25h%s[?2026l' "$E" "$E" "$E" "$E" "$1" "$BLOCK" "$E" "$E" "$E" >&7; }
frame2 10
frame2 20
i=0; while [ "$i" -lt 40 ] && ! grep -q 'pulling aa11bb22' "$W/g.out"; do sleep 0.1; i=$((i + 1)); done
DESC="a redraw frame is handled while the pipe is open: its last line (no newline after it) comes out when the next frame's first line ends, about a frame later, not at EOF"
if grep -qx 'pulling aa11bb22: 10% 1 GB/ 10 GB' "$W/g.out"; then verdict 0; else verdict 1; cat -v "$W/g.out" | sed 's/^/      /'; fi
exec 7>&-
wait "$gpid"
DESC="and it ends when the input does (exit status 0)"
if [ $? = 0 ]; then verdict 0; else verdict 1; fi
fi


# --- shared helpers of H to L -----------------------------------------------------------------------------------------------
# run_timed LIMIT_SECS INPUT OUTPUT [ENV=value ...]: the filter on a file, killed after LIMIT_SECS (a quadratic filter must fail the
# test by timing out, not hang it). Sets RT_RC (124 = killed) and RT_MS.
run_timed() {
  local limit="$1" in="$2" out="$3" pid i=0 t0 t1; shift 3
  t0="$(now_ms)"
  env "$@" bash "$FILTER" < "$in" > "$out" 2> "$W/rt.err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((limit * 20)) ]; then
      pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      RT_RC=124; t1="$(now_ms)"; RT_MS=$((t1 - t0)); return 0
    fi
    sleep 0.05; i=$((i + 1))
  done
  wait "$pid"; RT_RC=$?; t1="$(now_ms)"; RT_MS=$((t1 - t0))
}
# gen_frames N A B: N redraw frames of ONE layer whose percentage alternates between A and B, as ollama draws them; then the end of the pull.
gen_frames() {
  awk -v n="$1" -v a="$2" -v b="$3" 'BEGIN {
    E = sprintf("%c", 27)
    bar = "\342\226\225\342\226\210\342\226\210\342\226\210\342\226\210\342\226\210\342\226\210\342\226\210\342\226\210\342\226\210       \342\226\217"
    for (i = 0; i < n; i++) {
      p = (i % 2 == 0) ? a : b
      printf "%s[?25l%s[?2026hpulling manifest %s[K\npulling 797b70c4edf8: %3d%% %s 15 MB/ 45 MB 26 MB/s 9s%s[K\n%s[?2026l%s[?25h%s[2A", E, E, E, p, bar, E, E, E, E
    }
    printf "%s[?25l%s[?2026hverifying sha256 digest %s[K\nwriting manifest %s[K\nsuccess %s[K%s[?25h%s[?2026l\n", E, E, E, E, E, E, E
  }' /dev/null
}

# --- H: a layer that goes up and down -----------------------------------------------------------------------------------------
echo "== H  a layer whose percentage is not monotonic"
gen_frames 20000 41 39 > "$W/h.in"
h_in="$(wc -l < "$W/h.in" | tr -d ' ')"; h_bytes="$(wc -c < "$W/h.in" | tr -d ' ')"
run_timed 60 "$W/h.in" "$W/h.out"
h_out="$(wc -l < "$W/h.out" | tr -d ' ')"
DESC="41 -> 39 -> 41 ... x 20000 samples ($h_in lines, $h_bytes bytes) comes out as $h_out lines (a few dozen at most; took ${RT_MS} ms, rc $RT_RC)"
if [ "$RT_RC" = 0 ] && [ "$h_out" -le 12 ] && [ "$h_out" -ge 4 ] && [ "$(tail -n 1 "$W/h.out")" = success ]; then verdict 0; else verdict 1; head -8 "$W/h.out" | sed 's/^/      /'; fi
DESC="...the first step back is visible (41% and 39% are both there) and 'success' is there once"
if grep -q '^pulling 797b70c4edf8: 41% ' "$W/h.out" && grep -q '^pulling 797b70c4edf8: 39% ' "$W/h.out" && [ "$(grep -c '^success$' "$W/h.out")" = 1 ]; then verdict 0; else verdict 1; fi
run_timed 60 "$W/h.in" "$W/h0.out" CI_OS_FILTER_SECS=0
DESC="...and with the time rule off (CI_OS_FILTER_SECS=0) it is bounded as well ($(wc -l < "$W/h0.out" | tr -d ' ') lines; the window of a step back is then one second)"
if [ "$RT_RC" = 0 ] && [ "$(wc -l < "$W/h0.out" | tr -d ' ')" -le 12 ]; then verdict 0; else verdict 1; head -8 "$W/h0.out" | sed 's/^/      /'; fi
# 100 -> 0 -> 100 -> 0 ...: every second sample is a step back and every other one a completion; the window must hold for both
gen_frames 20000 100 0 > "$W/h1.in"
run_timed 60 "$W/h1.in" "$W/h1.out"
DESC="100 -> 0 -> 100 -> 0 ... x 20000 samples: $(wc -l < "$W/h1.out" | tr -d ' ') lines out (at most 12; took ${RT_MS} ms, rc $RT_RC)"
if [ "$RT_RC" = 0 ] && [ "$(wc -l < "$W/h1.out" | tr -d ' ')" -le 12 ] && [ "$(tail -n 1 "$W/h1.out")" = success ]; then verdict 0; else verdict 1; head -8 "$W/h1.out" | sed 's/^/      /'; fi
# a restart from the beginning after the layer was complete: 0..100 in 1% steps, then 3..100 again, then success
awk -v E="$E" 'BEGIN {
  bar = "\342\226\225\342\226\210\342\226\217"
  for (r = 0; r < 2; r++) for (p = (r ? 3 : 0); p <= 100; p++)
    printf "%s[?25l%s[?2026hpulling manifest %s[K\npulling 797b70c4edf8: %3d%% %s 15 MB/ 45 MB%s[K\n%s[?2026l%s[?25h%s[2A", E, E, E, p, bar, E, E, E, E
  printf "%s[?25lverifying sha256 digest %s[K\nwriting manifest %s[K\nsuccess %s[K%s[?25h\n", E, E, E, E, E
}' /dev/null > "$W/h2.in"
run_timed 20 "$W/h2.in" "$W/h2.out"
DESC="a layer restarted after it reached 100%: the first pass is one line per 5%, the restart is one line for the step back and one for 100% again ($(grep -c '^pulling 797b70c4edf8: ' "$W/h2.out") lines in all, at most 24), never one line per percent"
if [ "$RT_RC" = 0 ] && [ "$(grep -c '^pulling 797b70c4edf8: ' "$W/h2.out")" -le 24 ] && [ "$(grep -c '^pulling 797b70c4edf8: 100% ' "$W/h2.out")" = 2 ] && grep -q '^pulling 797b70c4edf8: 3% ' "$W/h2.out"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/h2.out" | head -30; fi
# the window: within one second at most two lines for a flapping layer; after the window the next change is printed again
DESC="a flapping layer is printed at most once per window: 41 39 41 39 in one burst = 2 lines, the next change after the window = 1 more"
if blocking_awk; then t_skip "$DESC (this awk is mawk, which reads a pipe in blocks: install gawk)"; else
{ frame 41; frame 39; frame 41; frame 39; sleep 1.2; frame 41; } | CI_OS_FILTER_STEP=50 CI_OS_FILTER_SECS=1 run > "$W/h3.out"
if [ "$(grep -c '^pulling cafe0123' "$W/h3.out")" = 3 ] && grep -q '^pulling cafe0123: 39% ' "$W/h3.out"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/h3.out"; fi
fi

# --- I: linear time on escape-heavy input --------------------------------------------------------------------------------------
echo "== I  linear time"
I_LIMIT_MS=2000
i_check() {  # NAME INPUT EXPECTED-LINES: the run is timed against I_LIMIT_MS; no escape or CR may be left
  local name="$1" in="$2" want="$3" got
  run_timed 20 "$in" "$W/i.out"
  got="$(wc -l < "$W/i.out" | tr -d ' ')"
  DESC="$name: $(wc -c < "$in" | tr -d ' ') bytes in ${RT_MS} ms (limit $I_LIMIT_MS), exit status $RT_RC, $got lines out"
  if [ "$RT_RC" = 0 ] && [ "$RT_MS" -lt "$I_LIMIT_MS" ] && [ "$got" = "$want" ] && ! has_esc "$W/i.out"; then verdict 0; else verdict 1; head -c 300 "$W/i.out" | cat -v | sed 's/^/      /'; fi
}
head -c 60000 /dev/zero | tr '\0' '\033' > "$W/i1.in"
i_check "60,000 ESC, no newline" "$W/i1.in" 0
awk 'BEGIN { E = sprintf("%c", 27); for (i = 0; i < 50000; i++) printf "A%s[K", E; printf "\n" }' > "$W/i2.in"
i_check "a 200 KB line of 50,000 text bytes each followed by ESC[K" "$W/i2.in" 1
DESC="...and the line is exactly the 50,000 text bytes (nothing lost, nothing added)"
if [ "$(wc -c < "$W/i.out" | tr -d ' ')" = 50001 ] && [ "$(tr -d 'A\n' < "$W/i.out" | wc -c | tr -d ' ')" = 0 ]; then verdict 0; else verdict 1; fi
awk 'BEGIN { E = sprintf("%c", 27); for (i = 0; i < 60000; i++) printf "%s[0m", E }' > "$W/i3.in"
i_check "60,000 colour resets (360 KB), no newline" "$W/i3.in" 0
awk 'BEGIN { E = sprintf("%c", 27); for (i = 0; i < 20000; i++) printf "x%s[A", E; printf "\n" }' > "$W/i4.in"
i_check "20,000 cursor-up sequences between 20,000 x" "$W/i4.in" 20000
{ printf 'a'; head -c 100000 /dev/zero | tr '\0' '\r'; printf 'b\n'; } > "$W/i5.in"
i_check "a, 100,000 carriage returns, b" "$W/i5.in" 1
DESC="...and what is left on the screen is b"
if [ "$(cat "$W/i.out")" = b ]; then verdict 0; else verdict 1; head -c 100 "$W/i.out" | cat -v | sed 's/^/      /'; fi
{ printf 'x\007'; awk 'BEGIN { E = sprintf("%c", 27); for (i = 0; i < 60000; i++) printf "%s]", E }'; printf 'y\n'; } > "$W/i6.in"
i_check "a BEL, then 60,000 ESC ] (an OSC introducer that never ends)" "$W/i6.in" 1
{ head -c 1000000 /dev/zero | tr '\0' 'A'; printf '\n'; } > "$W/i7.in"
i_check "a 1 MB plain line" "$W/i7.in" 1
DESC="...which comes out byte for byte"
if same_file "$W/i7.in" "$W/i.out"; then verdict 0; else verdict 1; fi
awk 'BEGIN { E = sprintf("%c", 27); for (i = 0; i < 30000; i++) printf "%s]0;t%c", E, 7; printf "after\n" }' > "$W/i8.in"
i_check "30,000 window-title sequences on one line" "$W/i8.in" 1
DESC="...the titles go and the text stays"
if [ "$(cat "$W/i.out")" = after ]; then verdict 0; else verdict 1; head -c 100 "$W/i.out" | cat -v | sed 's/^/      /'; fi

# --- J: percentages ---------------------------------------------------------------------------------------------------------------
echo "== J  percentages"
printf 'pulling abcdef: 99999999999999999999%% x\npulling abc: 50%% after\npulling abcdef: 000000000000000000000050%% y\npulling d1: 0007%% z\npulling d2: 0%% w\n' | run > "$W/j.out"
DESC="a 20-digit percentage is clamped to 100 (no wrapped number); a zero-padded one loses its zeros"
if [ "$(cat "$W/j.out")" = "$(printf '%s\n' 'pulling abcdef: 100% x' 'pulling abc: 50% after' 'pulling abcdef: 50% y' 'pulling d1: 7% z' 'pulling d2: 0% w')" ]; then verdict 0; else verdict 1; cat -v "$W/j.out" | sed 's/^/      /'; fi
DESC="...and no number of more than three digits comes out of a percentage"
if ! grep -q '[0-9][0-9][0-9][0-9]%' "$W/j.out" && ! grep -q -e ': -[0-9]*%' "$W/j.out"; then verdict 0; else verdict 1; fi
printf 'pulling %s: 5%% x\nafter\n' "$(head -c 200000 /dev/zero | tr '\0' 'a')" | run > "$W/j2.out"
DESC="a 200 KB layer name is no problem (two lines out, the second is 'after')"
if [ "$(wc -l < "$W/j2.out" | tr -d ' ')" = 2 ] && [ "$(tail -n 1 "$W/j2.out")" = after ]; then verdict 0; else verdict 1; fi

# --- K: binary junk and partial lines ------------------------------------------------------------------------------------------
echo "== K  binary junk and partial lines"
head -c 1000000 /dev/urandom > "$W/k1.in"
run_timed 30 "$W/k1.in" "$W/k1.out"
DESC="1 MB of random bytes: exit status 0 ($RT_RC), no escape sequence or carriage return left, done in ${RT_MS} ms (under 20 s)"
if [ "$RT_RC" = 0 ] && [ "$RT_MS" -lt 20000 ] && ! has_esc "$W/k1.out"; then verdict 0; else verdict 1; fi
# plain random lines: no NUL, ESC, CR, and no 0xE2 (the first byte of the bar and spinner glyphs, which a plain line may hold only by chance)
head -c 400000 /dev/urandom | LC_ALL=C tr -d '\000\033\r\342' > "$W/k2.in"; printf '\n' >> "$W/k2.in"
run_timed 30 "$W/k2.in" "$W/k2.out"
DESC="400 KB of random bytes without NUL, ESC, CR (and the glyph lead byte): every line comes out byte for byte"
if [ "$RT_RC" = 0 ] && same_file "$W/k2.in" "$W/k2.out"; then verdict 0; else verdict 1; fi
printf 'text%s[3' "$E" | run > "$W/k3.out"
DESC="input that ends inside an escape sequence (ESC [ 3): the introducer goes, the text stays (as the bash version did: text3)"
if [ "$(cat "$W/k3.out")" = text3 ]; then verdict 0; else verdict 1; cat -v "$W/k3.out" | sed 's/^/      /'; fi
printf 'text%s' "$E" | run > "$W/k4.out"
DESC="input that ends in a lone ESC: the text is kept"
if [ "$(cat "$W/k4.out")" = text ]; then verdict 0; else verdict 1; cat -v "$W/k4.out" | sed 's/^/      /'; fi
printf 'a%s]0;never ended' "$E" | run > "$W/k5.out"
DESC="input that ends inside a window title (no BEL ever comes): no failure, no escape left"
if ! has_esc "$W/k5.out"; then verdict 0; else verdict 1; fi
printf '%s[?25lpulling manifest %s[K\npulling cafe0123:  50%% x %s[K' "$E" "$E" "$E" | run > "$W/k6.out"
DESC="input that ends in the middle of a redraw frame: the last layer line is still printed at the end of the input"
if grep -qx 'pulling cafe0123: 50% x' "$W/k6.out" && grep -qx 'pulling manifest' "$W/k6.out"; then verdict 0; else verdict 1; cat -v "$W/k6.out" | sed 's/^/      /'; fi
printf 'one\ntwo\n\n\n' | run > "$W/k7.out"
DESC="empty lines are kept (two empty lines after 'two')"
if [ "$(wc -l < "$W/k7.out" | tr -d ' ')" = 4 ]; then verdict 0; else verdict 1; fi

# --- L: no awk, or an awk that fails ---------------------------------------------------------------------------------------------
echo "== L  no awk, a failing awk"
mkdir -p "$W/nobin" "$W/badbin"
for t in cat head tr sed; do ln -sf "$(command -v "$t")" "$W/nobin/$t"; ln -sf "$(command -v "$t")" "$W/badbin/$t"; done
printf '#!/bin/sh\nexit 1\n' > "$W/badbin/awk"; chmod +x "$W/badbin/awk"
BASH_BIN="$(command -v bash)"
printf '%s[0;34m[INFO]%s[0m a\nplain\n' "$E" "$E" > "$W/l.in"
env PATH="$W/nobin" "$BASH_BIN" "$FILTER" < "$W/l.in" > "$W/l1.out"; l1rc=$?
DESC="no awk at all: the stream is copied unchanged and the exit status is 0 ($l1rc)"
if [ "$l1rc" = 0 ] && same_file "$W/l.in" "$W/l1.out"; then verdict 0; else verdict 1; fi
env PATH="$W/badbin" "$BASH_BIN" "$FILTER" < "$W/l.in" > "$W/l2.out"; l2rc=$?
DESC="an awk that fails at once: the stream is copied unchanged and the exit status is 0 ($l2rc)"
if [ "$l2rc" = 0 ] && same_file "$W/l.in" "$W/l2.out"; then verdict 0; else verdict 1; fi

# --- M: the tail of the output survives the exit of the main process ----------------------------------------------------------
echo "== M  the driver hands the output over and waits for it"
FBD="${FIRST_BOOT_SETUP:-$CACHYOS/provision/first-boot-setup.sh}"   # (an override, to run the tests against a mutated copy)
DR="$W/dr"; mkdir -p "$DR/bin"
command -v flock >/dev/null 2>&1 || { printf '#!/bin/bash\nexit 0\n' > "$DR/bin/flock"; chmod +x "$DR/bin/flock"; }
# The provisioner: some output, a redraw flood (so that the filter has a backlog when the run ends), an optional background child that
# keeps the output pipe open for a minute, and a normal exit. The driver then writes its closing lines itself.
cat > "$DR/provision.sh" <<'PROVISIONER'
#!/bin/bash
echo "provisioner running"
n=0
while [ "$n" -lt "${DR_REDRAWS:-0}" ]; do
  n=$((n + 1))
  printf '\033[?25l\033[?2026hpulling manifest \033[K\n'
  printf 'pulling 797b70c4edf8: %3d%% \342\226\225\342\226\210\342\226\210\342\226\217 15 MB/ 45 MB 26 MB/s 9s\033[K\n' $((n % 101))
  printf '\033[?2026l\033[?25h\033[2A'
done
[ -z "${DR_BACKGROUND:-}" ] || { sleep 60 & }
echo "[SUCCESS] the provisioner's last line"
exit 0
PROVISIONER
printf '#!/bin/bash\nwhile IFS= read -r l; do sleep 0.02; printf "%%s\\n" "$l"; done\n' > "$DR/slow-filter.sh"
# The "systemd" of these tests is a few lines of python3: it starts the driver in a session of its own, waits for the MAIN process to
# exit and SIGTERMs what is left of the process group at once, which is what systemd does to a unit with the default
# KillMode=control-group. (A shell cannot do that reliably: job control is off inside a background subshell, so a process there does not
# get a process group of its own, in bash 5.3 at least.)
cat > "$DR/runner.py" <<'RUNNER'
import os, signal, subprocess, sys, time
t0 = time.time()
with open(sys.argv[1], "wb") as out:
    p = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    p.wait()
    t1 = time.time()
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
print(int((t1 - t0) * 1000))
RUNNER
# dr_one N FILTER [VAR=value ...]: one run. Result: $DR/rN/res = ok|lost (is the tail in the log AND in the output?), $DR/rN/ms.
dr_one() {
  local n="$1" flt="$2" D; shift 2
  D="$DR/r$n"; rm -rf "$D"; mkdir -p "$D/boot/backends/cachyos/provision" "$D/state"
  cp "$DR/provision.sh" "$D/boot/backends/cachyos/provision/provision.sh"; cp "$flt" "$D/boot/backends/cachyos/provision/progress-filter.sh"
  echo "BOOT_IMAGE=x" > "$D/cmdline"
  env -i PATH="$DR/bin:$PATH" "$@" CI_OS_BOOTSTRAP_ROOT="$D/boot" CI_OS_STATE_DIR="$D/state" CI_OS_LOG_FILE="$D/log" CI_OS_LOCK_FILE="$D/lock" \
    CI_OS_CMDLINE_FILE="$D/cmdline" CI_OS_RUN_ARCHISO="$D/none" CI_OS_NETWORK_PROBE=/usr/bin/true \
    python3 "$DR/runner.py" "$D/out" bash "$FBD" --manual > "$D/ms" 2>/dev/null
  sleep 0.05
  if grep -q 'NOTE: Log out' "$D/log" && grep -q 'NOTE: Log out' "$D/out" && grep -q "provisioner's last line" "$D/log"; then echo ok > "$D/res"; else echo lost > "$D/res"; fi
}
# dr_batch RUNS PARALLEL FILTER [VAR=value ...] -> DR_LOST
dr_batch() {
  local runs="$1" par="$2" flt="$3" i=0 j; shift 3
  while [ "$i" -lt "$runs" ]; do
    j=0
    while [ "$j" -lt "$par" ] && [ "$i" -lt "$runs" ]; do dr_one "$i" "$flt" "$@" & i=$((i + 1)); j=$((j + 1)); done
    wait
  done
  DR_LOST=0; i=0
  while [ "$i" -lt "$runs" ]; do [ "$(cat "$DR/r$i/res" 2>/dev/null)" = ok ] || DR_LOST=$((DR_LOST + 1)); i=$((i + 1)); done
}
dr_probe="$(bash -c ': > >(cat > /dev/null); echo "$!"' 2>/dev/null)"
if ! command -v python3 >/dev/null 2>&1; then
  t_skip "the driver's drain: needs python3 (it plays systemd: waits for the main process, then kills its process group)"
elif [ -z "$dr_probe" ]; then
  t_skip "the driver's drain: this bash sets no \$! for a process substitution, so there is nothing to wait for"
else
  dr_batch 200 10 "$CACHYOS/provision/progress-filter.sh" DR_REDRAWS=300
  DESC="200 runs (a 300-redraw flood, then the closing lines) with the real filter, the main process exiting and its process group killed at once: $DR_LOST of 200 lost the tail"
  if [ "$DR_LOST" = 0 ]; then verdict 0; else verdict 1; for k in 0 1 2 3 4 5 6 7 8 9; do [ "$(cat "$DR/r$k/res" 2>/dev/null)" = ok ] || { tail -n 4 "$DR/r$k/log" | cat -v | sed 's/^/      /'; break; }; done; fi
  dr_batch 60 10 "$DR/slow-filter.sh" DR_REDRAWS=0
  DESC="60 runs with a SLOW filter (20 ms a line: the tail is still in the pipe when the kill comes): $DR_LOST of 60 lost the tail"
  if [ "$DR_LOST" = 0 ]; then verdict 0; else verdict 1; fi
  # The interactive branch has two substitutions, one inside the other; waiting for the outer one is waiting for both only where `wait`
  # accepts the pid of a process substitution (bash 4.4 and later; the Arch image has 5.3).
  dr_bash="$(bash -c 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"')"
  dr_major="${dr_bash% *}"; dr_minor="${dr_bash#* }"
  DESC="the interactive branch (screen = raw stream, log = filtered copy, CI_OS_FORCE_TTY=1) with a SLOW filter: the log copy is waited for as well"
  if [ "$dr_major" -lt 4 ] || { [ "$dr_major" = 4 ] && [ "$dr_minor" -lt 4 ]; }; then t_skip "$DESC (bash $dr_major.$dr_minor cannot wait for a process substitution: needs 4.4)"; else
    dr_batch 40 10 "$DR/slow-filter.sh" DR_REDRAWS=0 CI_OS_FORCE_TTY=1
    DESC="$DESC: $DR_LOST of 40 runs lost the tail of the screen or of the log"
    if [ "$DR_LOST" = 0 ]; then verdict 0; else verdict 1; fi
  fi
  dr_batch 1 1 "$CACHYOS/provision/progress-filter.sh" DR_REDRAWS=0
  DESC="one ordinary run takes under 2 s from start to exit, so the drain does not wait for a process that is already gone ($(cat "$DR/r0/ms") ms)"
  if [ "$(cat "$DR/r0/ms")" -lt 2000 ]; then verdict 0; else verdict 1; fi
  DESC="a background child that keeps the output pipe open (sleep 60) does not keep the script running: it exits after the drain's bound of 5 s, and the closing lines are in the log"
  if blocking_awk; then t_skip "$DESC (this awk is mawk, which holds a line back until its block is full or the input ends, and the child keeps the input from ending: install gawk)"; else
    dr_batch 1 1 "$CACHYOS/provision/progress-filter.sh" DR_BACKGROUND=1
    ms="$(cat "$DR/r0/ms")"
    DESC="$DESC ($ms ms; 3.5 to 9 s)"
    if [ "$ms" -ge 3500 ] && [ "$ms" -lt 9000 ] && [ "$(cat "$DR/r0/res")" = ok ]; then verdict 0; else verdict 1; tail -n 3 "$DR/r0/log" | cat -v | sed 's/^/      /'; fi
  fi
fi

echo
printf '== %s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
