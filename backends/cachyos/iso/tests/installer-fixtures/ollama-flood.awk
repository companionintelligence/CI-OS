# The redraw stream of `ollama pull`, as ollama 0.40.6 wrote it to its stderr in a pipe (the first 12 spinner frames, then one frame per
# step with the cursor moved back up over the block, then the final frame), for a model with one big layer and two small ones.
# The byte layout is that of ollama-pull-all-minilm.stderr.printf, recorded from the real binary (Arch package ollama 0.40.6-1, `ollama pull
# all-minilm`, stderr to a file); only the sizes are made up so that a test can ask for thousands of frames.
#
#   awk -v frames=3000 -f ollama-flood.awk /dev/null
function bar(pct,   n, s, i) {
  n = int(pct * 20 / 100); s = ""
  for (i = 0; i < n; i++) s = s "\342\226\210"      # U+2588, written as octal: core/lib/check-repo.sh forbids the glyph itself in backends/
  for (i = n; i < 20; i++) s = s " "
  return "▕" s "▏"
}
BEGIN {
  if (frames == "") frames = 3000
  E = sprintf("%c", 27)
  for (i = 0; i < 12; i++) printf "%s[?2026h%s[?25l%s[1Gpulling manifest ⠋ %s[K%s[?25h%s[?2026l", E, E, E, E, E, E
  for (i = 1; i <= frames; i++) {
    pct = int(i * 100 / frames)
    up = (i > 1) ? E "[A" E "[A" E "[A" : ""
    printf "%s[?2026h%s[?25l%s%s[1Gpulling manifest %s[K\n", E, E, up, E, E
    printf "pulling 6a0746a1ec1a: %3d%% %s %5d MB/ 17 GB   26 MB/s  7m5s %s[K\n", pct, bar(pct), pct * 170, E
    printf "pulling 4fa551d4f938: 100%% %s 12 KB %s[K\n", bar(100), E
    printf "pulling 8ab4849b038c: 100%% %s  254 B %s[K%s[?25h%s[?2026l", bar(100), E, E, E
  }
  printf "%s[?2026h%s[?25l%s[A%s[A%s[A%s[1Gpulling manifest %s[K\nverifying sha256 digest %s[K\nwriting manifest %s[K\nsuccess %s[K%s[?25h%s[?2026l", E, E, E, E, E, E, E, E, E, E, E, E
}
