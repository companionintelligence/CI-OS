#!/bin/bash
# progress-filter.sh -- stdin to stdout: terminal output made fit for a log and the journal.
#
#   some-command 2>&1 | progress-filter.sh
#
# Why. The first-boot run of ISO #4 wrote 14,052 lines (1.9 MB) to /var/log/ci-os-first-boot-setup.log and 14,075 to the journal for
# three `ollama pull`s, and the journal showed each of them as "[147B blob data]". Ollama redraws its progress block about ten times a
# second with cursor movements (ESC[A, ESC[1G, ESC[K, ESC[?25l, ESC[?2026h ...) whatever its stdout is, and the Arch provisioner
# (backends/arch/**, frozen) pipes it straight to the unit's stdout. The same script also colours every log_info/log_warning line with
# ESC[0;34m ... ESC[0m, which journald stores as a blob as well. A PATH shim around `ollama` cannot help: the Arch script runs the pulls
# through `sudo -u "$ACTUAL_USER"`, and Arch's sudoers sets secure_path=/usr/local/sbin:/usr/local/bin:/usr/bin (checked in a container:
# `PATH=/tmp/shim:$PATH sudo -u demo bash -c 'command -v ollama'` printed /usr/bin/ollama). The one place every byte of the run passes
# is the output of the script that started it, so that is where this sits (first-boot-setup.sh).
#
# What it does, on the stream as a terminal would show it:
#   - every escape sequence is removed (colours, erase, cursor visibility). A cursor movement (ESC[A, ESC[1G, ...) ends the line being
#     written, as on a screen, and so does the end of a physical line; of a line redrawn with \r only what is left on screen stays.
#   - Ollama's redraw frames (from ESC[?25l or ESC[?2026h to ESC[?25h or ESC[?2026l) are not copied. Each layer ("pulling <digest>:  NN% ...")
#     is printed when it is first seen, whenever it has advanced by STEP percent (default 5) beyond the furthest point it was printed at
#     (its high-water mark), when it reaches 100%, and, if it moved at all, every SECS seconds (default 30), so a slow link shows it is
#     alive. Its bar is dropped: "pulling 797b70c4edf8: 33% 15 MB/ 45 MB 26 MB/s 9s". A layer that goes BACK (a retry restarts a chunk:
#     41 -> 39 -> 41 -> 39 ...) is printed when it first does and then at most once per SECS seconds (one second when SECS is 0), so a
#     flapping layer cannot turn the log into one line per sample. A percentage of more than three digits is clamped to 100.
#     Every other line of a frame ("pulling manifest", "verifying sha256 digest", "writing manifest", "success") is printed once per pull;
#     when "success" arrives, a layer whose last sample was not printed is printed first, so the log ends on the final state.
#   - everything else is copied, line by line, with its escape sequences removed. A plain line also ends the pull being tracked, so
#     the next pull prints its own "pulling manifest" again (the Arch script echoes "Pulling <model>..." between pulls). A plain line
#     (no escape sequence, no carriage return) is copied byte for byte.
#
# How. ONE awk program, linear in the size of its input. The first version of this file parsed escape sequences in bash, a byte at a time
# with `rest="${rest#...}"` and `buf="$buf..."`, which copy the rest of the line each time: a line of 15,000 ESC took 35 s, 60,000 did not
# finish in three minutes, and while the filter chewed on it the pipe filled up and the provisioner blocked in write(). Here a physical
# line is rewritten with a handful of gsub() passes (every pass is one scan; none can backtrack over a long run), split once at the few
# markers that matter, and each piece is cut out with one substr(). Only POSIX awk is used (no gensub, no systime()-only clock, no
# `delete array`, no character classes), so that the BSD awk of the macOS the tests also run on, mawk and gawk (Arch) run the same
# program; the clock is the one thing that differs and is chosen below.
#
# It reads a line at a time and writes at once (fflush after every printed line), so a `tail -f` of the log follows the run (except under
# mawk, see "which awk" below). It never exits early and always exits 0: a filter that died would give its writer SIGPIPE and stop the
# provisioning. If there is no awk, or awk dies, the rest of the stream is copied with `cat`, and the caller (first-boot-setup.sh)
# falls back to `cat` as well should this script itself fail.
#
# Environment (tests): CI_OS_FILTER_STEP (percent, default 5), CI_OS_FILTER_SECS (default 30; 0 turns the time rule off).
LC_ALL=C
export LC_ALL

STEP="${CI_OS_FILTER_STEP:-5}"
SECS="${CI_OS_FILTER_SECS:-30}"
case "$STEP" in ''|*[!0-9]*|0) STEP=5 ;; esac
case "$SECS" in ''|*[!0-9]*) SECS=30 ;; esac

if ! command -v awk >/dev/null 2>&1; then cat; exit 0; fi

# --- which awk, and its clock ------------------------------------------------------------------------------------------------------------
# gawk (what Arch ships), BSD awk (macOS) and mawk all run this program. mawk, the default awk of Debian and Ubuntu, reads a pipe in blocks
# (a line comes out only when 4 KB more have arrived, or at the end of the input), and its cure, `-W interactive`, truncates every line
# of more than 4096 bytes AND DROPS EVERYTHING AFTER IT (checked with mawk 1.3.4 20240123), which is far worse for a log than a late
# line: so gawk is used when it is installed, and otherwise mawk runs as it is.
AWK='awk'
case "$(awk -W version 2>&1 </dev/null)" in
  mawk*) if command -v gawk >/dev/null 2>&1; then AWK=gawk; fi ;;
esac
# awk has no portable clock. gawk and mawk have systime(); BSD awk and busybox awk do not, but POSIX srand() with no argument seeds from
# the time of day and returns the PREVIOUS seed, so `srand(); srand()` returns the current time. (Naming systime() in the program text
# is a parse error in an awk without it, hence the probe and the two spellings.) If neither works the time rules are off.
CLOCK_FN='function now() { return 0 }'
if [ "$("$AWK" 'BEGIN { if (systime() > 1000000000) print "ok" }' 2>/dev/null </dev/null)" = ok ]; then
  CLOCK_FN='function now() { return systime() }'
elif [ "$("$AWK" 'BEGIN { srand(); t = srand(); if (t > 1000000000) print "ok" }' 2>/dev/null </dev/null)" = ok ]; then
  CLOCK_FN='function now(   t) { srand(); t = srand(); return t }'
fi

IFS= read -r -d '' PROGRAM <<'AWK_PROGRAM'
BEGIN {
  ESC = sprintf("%c", 27); CR = sprintf("%c", 13); BEL = sprintf("%c", 7)
  M = sprintf("%c", 1)          # internal marker byte: M followed by a code letter (f frame starts, e frame ends, n line break)
  STEP = STEP + 0; SECS = SECS + 0
  DIPWIN = (SECS > 0) ? SECS : 1
  # U+2595 and U+258F, the ends of Ollama's bar, and its ten braille spinner frames, written as octal bytes (the C locale matches bytes).
  BAR_L = "\342\226\225"; BAR_R = "\342\226\217"
  SPIN = "\342\240[\213\231\271\270\274\264\246\247\207\217]"
  RE_MORE_BLANKS = "  +"
  RE_CR_RUN = CR "+"
  RE_TO_LAST_CR = "^.*" CR
  RE_TO_LAST_BAR_R = "^.*" BAR_R
  RE_CHARSET = ESC "[()*+].?"                      # ESC ( B and kin: the introducer and one more byte (if there is one)
  RE_FRAME_ON1 = ESC "\\[\\?25l"; RE_FRAME_ON2 = ESC "\\[\\?2026h"
  RE_FRAME_OFF1 = ESC "\\[\\?25h"; RE_FRAME_OFF2 = ESC "\\[\\?2026l"
  RE_CSI_MOVE = ESC "\\[[0-9;?:<=>]*[ABEFGHfd]"     # cursor movement: ends the line being written
  RE_CSI_ANY = ESC "\\[[0-9;?:<=>]*[A-Za-z@`~]"     # any other well-formed CSI sequence: dropped
  RE_ESC_BRACKET = ESC "\\["; RE_ESC_OSC = ESC "\\]"; RE_ESC_OSC_LIT = ESC "]"
  RE_TO_LAST_BEL = "^.*" BEL
  RE_OSC_FULL = ESC "\\][^" BEL "]*" BEL
  M_FRAME_ON = M "f"; M_FRAME_OFF = M "e"; M_BREAK = M "n"
  frame = 0; nid = 0; nseen = 0
}

function out(s) { print s; fflush() }

function reset_state() {
  if (nid == 0 && nseen == 0) return
  split("", last); split("", hw); split("", at); split("", dat); split("", cur); split("", curtxt); split("", seen); split("", ord)
  nid = 0; nseen = 0
}

# A layer whose latest sample was not printed is printed before "success", in the order the layers were first seen.
function flush_pending(   i, id) {
  for (i = 1; i <= nid; i++) { id = ord[i]; if (cur[id] != last[id]) out(curtxt[id]) }
}

# handle(s): one finished line, escape sequences already gone. Reads frame.
function handle(s,   p, h, t, hd, id, d, pct, rest, txt, pl, doprint, isdip, nw) {
  # A carriage return rewinds to the start of the line: what a person would see at the newline is the text after the last one that has
  # text behind it (so "one\r" is "one" and "a\rb\r" is "b"). Runs of CR are made one first, then everything up to the last CR goes.
  if (index(s, CR)) {
    gsub(RE_CR_RUN, CR, s)
    if (substr(s, length(s), 1) == CR) s = substr(s, 1, length(s) - 1)
    sub(RE_TO_LAST_CR, "", s)
  }
  if (frame == 1 || index(s, BAR_L)) {
    gsub(SPIN, "", s)
    p = index(s, BAR_L)
    if (p && index(s, BAR_R)) {                        # "name  pct ▕bar▏ rest": the bar goes, the text before and after it stays
      h = substr(s, 1, p - 1); t = s; sub(RE_TO_LAST_BAR_R, "", t); s = h " " t
    }
    gsub(RE_MORE_BLANKS, " ", s)
    if (substr(s, 1, 1) == " ") s = substr(s, 2)
    if (substr(s, length(s), 1) == " ") s = substr(s, 1, length(s) - 1)
    if (s == "") return
  }
  if (match(s, /^pulling[ \t]+[0-9a-f]+:[ \t]*[0-9]+%/)) {
    hd = substr(s, 1, RLENGTH); rest = substr(s, RLENGTH + 1)
    sub(/^pulling[ \t]+/, "", hd)
    p = index(hd, ":"); id = substr(hd, 1, p - 1); d = substr(hd, p + 1)
    sub(/^[ \t]*/, "", d); sub(/%$/, "", d); sub(/^0+/, "", d)
    if (d == "") d = "0"
    pct = (length(d) > 3) ? 100 : d + 0                # no arithmetic on a 20-digit number: more than three digits is 100
    if (pct > 100) pct = 100
    txt = "pulling " id ": " pct "%" rest
    nw = now(); isdip = 0
    if (!(id in last)) { nid++; ord[nid] = id; doprint = 1 }
    else {
      pl = last[id]; doprint = 0
      if (pct < pl) {                                  # it went back (a retry): once, then at most once per window
        if (!(id in dat) || nw - dat[id] >= DIPWIN) { doprint = 1; isdip = 1 }
      } else if (pct == 100 && pl != 100) doprint = 1
      else if (pct > hw[id] && int(pct / STEP) > int(hw[id] / STEP)) doprint = 1   # a new step beyond the high-water mark
      if (!doprint && SECS > 0 && pct != pl && nw - at[id] >= SECS) doprint = 1
    }
    cur[id] = pct; curtxt[id] = txt
    if (doprint) {
      last[id] = pct; at[id] = nw
      if (!(id in hw) || pct > hw[id]) hw[id] = pct
      if (isdip) dat[id] = nw
      out(txt)
    }
    return
  }
  if (frame == 1) {
    if (s == "success") {
      flush_pending()
      if (!(s in seen)) out(s)
      reset_state()
      return
    }
    if (!(s in seen)) { seen[s] = 1; nseen++; out(s) }
    return
  }
  reset_state()
  out(s)
}

{
  line = $0
  if (index(line, ESC) == 0) {
    # No escape sequence at all: a plain line. (Every line of a redraw frame ends with ESC[K, so this also ends a frame that never closed.)
    frame = 0
    handle(line)
    next
  }
  s = line
  if (index(s, M)) gsub(M, "", s)                      # the marker byte itself is not terminal output
  # OSC (window title): ESC ] up to the next BEL. Only the part of the line up to its LAST BEL can hold one (every ESC ] in it has a BEL
  # behind it, so every match succeeds and consumes its bytes: one pass); an ESC ] after the last BEL loses just its two bytes, below.
  # (A pattern tried at 60,000 ESC ] that have no BEL behind them would scan to the end of the line from each of them.)
  if (index(s, RE_ESC_OSC_LIT) && index(s, BEL)) {
    t = s; sub(RE_TO_LAST_BEL, "", t)                  # t: what follows the last BEL
    h = substr(s, 1, length(s) - length(t))
    gsub(RE_OSC_FULL, "", h)
    s = h t
  }
  gsub(RE_CHARSET, "", s)
  if (index(s, ESC "[?")) {
    gsub(RE_FRAME_ON1, M_FRAME_ON, s); gsub(RE_FRAME_ON2, M_FRAME_ON, s)
    gsub(RE_FRAME_OFF1, M_FRAME_OFF, s); gsub(RE_FRAME_OFF2, M_FRAME_OFF, s)
  }
  gsub(RE_CSI_MOVE, M_BREAK, s)
  gsub(RE_CSI_ANY, "", s)
  gsub(RE_ESC_BRACKET, "", s); gsub(RE_ESC_OSC, "", s)
  gsub(ESC, "", s)
  if (index(s, M) == 0) { if (s != "") handle(s); next }
  # Cut the line at the tokens that end a line (or start/stop a frame) and handle each piece; a piece with nothing in it is no line.
  n = split(s, P, M)
  a = 1; cum = length(P[1])
  for (k = 2; k <= n; k++) {
    p = cum + 1; c = substr(P[k], 1, 1); cum = cum + 1 + length(P[k])
    if (c == "e" && frame != 1) continue               # the end of a frame that is not there: not a line break
    seg = substr(s, a, p - a); a = p + 2
    if (index(seg, M)) gsub(M_FRAME_OFF, "", seg)
    if (seg != "") handle(seg)
    if (c == "f") frame = 1
    else if (c == "e") frame = 0
  }
  seg = substr(s, a)
  if (index(seg, M)) gsub(M_FRAME_OFF, "", seg)
  if (seg != "") handle(seg)
}

END { exit 0 }
AWK_PROGRAM

"$AWK" -v STEP="$STEP" -v SECS="$SECS" "$CLOCK_FN
$PROGRAM" || cat
exit 0
