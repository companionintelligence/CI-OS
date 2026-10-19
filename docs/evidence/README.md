# Evidence records

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

This directory holds the small, text-only records behind the **[V]** rows of [`../architecture/test-evidence.md`](../architecture/test-evidence.md):
build records, verifier logs, boot results and the sha256 of the image each run used. Before this directory existed those records lived only
in the temporary scratch directory of the session that produced them, so a reader could not re-find them and the files would have been lost
with the machine. Anything a document cites as the source of a **[V]** should be here, or in `docs/ui/` (frames and capture notes).

## What goes where

| Kind of record | Where | Why |
|---|---|---|
| Build record, `verify-iso.sh` log, installed-boot result, exit-status files, sha256 of the ISO | `docs/evidence/<YYYY-MM-DD>-<edition>-<what>/` | plain text, a few hundred KB at most |
| Screenshots of a QEMU run and its `CAPTURE.md` | `docs/ui/companion-os/<edition>/` | added by the capture step; the placeholder names are in [Figures](#figures) |
| ISOs, disk images, `qcow2` overlays, OVMF variable stores | nowhere in the repository | gigabytes; `*.iso` must never be committed |
| Session scratch (`/tmp`, a worktree's `scratchpad`) | nowhere | temporary; not a citable source once a run is over |

## Rules for a run directory

1. **Text only, 1 MB at most per run.** A transcript that is larger than that is trimmed to its result lines and says so on its first line.
2. **Name the image.** Every run directory has a `SHA256SUMS` listing the image the run used (`shasum -a 256`). A record that cannot be tied
   to an image is not evidence. If the image was built from a snapshot of a working tree and not from a commit, the directory name says so.
3. **No credentials, tokens or keys, and no host paths or user names.** Replace a scratch path with `<scratch>` and a home path with `<home>`
   before copying. Throwaway VM accounts are not repeated either (the passwords of those stay out of every record).
4. **Never edit a record to make it look better.** If a run was repeated, add a second directory.
5. **Link it.** A new directory is added to the index below and cited by the row of `test-evidence.md` that it supports, and `git add`ed. The
   gate does not check documents or `docs/` (`core/lib/check-untracked-deps.sh` skips them), so check by hand with the commands in
   [Running the tests](../guides/running-the-tests.md#checking-documents-by-hand).

Adding a run:

```bash
RUN="docs/evidence/$(date +%Y-%m-%d)-ubuntu-clean-$(git rev-parse --short HEAD)"
mkdir -p "$RUN"
(cd output && shasum -a 256 companion-os-*.iso) > "$RUN/SHA256SUMS"
for f in build.log verify.log; do
  sed -E 's#/Users/[^ )"]*#<home>#g; s#/private/tmp/[^ )"]*#<scratch>#g' "$f" > "$RUN/$f"
done
grep -r -n -i -E 'password|token|secret|BEGIN [A-Z ]*KEY' "$RUN" || echo "no credential-like strings"
git add "$RUN"
```

## Index

| Directory | Image (sha256) | Built from | What the records show | Supports |
|---|---|---|---|---|
| `2026-10-18-ubuntu-clean-02c575e/` | `companion-os-1.0-amd64.iso`, `709b8485f10da74cc281d0d0bed56747c47c502d6ac73ef6bc6bf1fe7374f5cf` | clean detached worktree at `02c575e` | `build.status` (build exit 0 in 772 s), `build-record.txt`, `verify.status` and `verify.log` (393 passed, 0 failed, 34 s), `installed-boot-nobot.log` and `.rc` (`installed-boot.sh --iso --no-boot`: 25 PASS, 0 FAIL, 413 s), `layer-sizes.txt` | test-evidence: Ubuntu build and static verification, U1 |
| `2026-10-18-ubuntu-fixpass-9.9/` | `companion-os-9.9-amd64.iso`, `dce9eb718d06af017f7d998ff7da4c3704c7b2f6ebd9c1aba8fa652f6f206a11` | a snapshot of the worktree during the fix pass, **not** a commit (version string 9.9) | `verify.log` (393 passed), `installed-boot-result.txt`, `-timeline.txt`, `-checks.txt`, `-guest-report.txt` (the assembled disk booted to the GDM greeter in 230 s), `secureboot-serial-built-iso.log` | test-evidence: fix-pass boot of a harness-built disk |
| `2026-10-18-plasma-iso4/` | `f5cda84f60b585e85895552c5738aaf2a3ddba381a838538ce5d58fe9cff8790` | clean commit `d7b3a7b` | the `.build-info` and `.iso.sha256` of ISO #4 | test-evidence: Plasma ISO #4 (the capture notes and frames follow in `docs/ui/`) |
| `2026-10-18-plasma-iso5/` | `2e254487ba6a24d1602e2b7ab9163468170cb83e55d60498f4f14623a19e0b5e` | clean commit `552063f` | the `.build-info` and `.iso.sha256` of ISO #5 | test-evidence: Plasma ISO #5 (the capture notes and frames follow in `docs/ui/`) |
| `2026-10-18-plasma-iso6/` | `5ab1fe2c422fb8960a0dfd0c2f12f70460d13fb3eb9e13febab5ef2a41802d20` | clean commit `ad37b64` | `run-record.txt` (the run in one page), the `.build-info` and `.iso.sha256`, `verify.log` (215 passed, 0 failed, 84 s), `calamares-jobs.txt` (the 47 jobs and their durations: 28 min 26 s, first attempt), `calamares-keyring-excerpt.txt` (the 32 s keyring step, no "timed out" line), `launcher-excerpt.txt` (the launcher's own lines and the Calamares requirement lines, 7 of 7 satisfied), the two sanitised QEMU command lines. The 29 frames and the capture record are in [`../ui/companion-os/plasma/`](../ui/companion-os/plasma/CAPTURE.md) | test-evidence: Plasma ISO #6, Plasma pending rows 8 and 10 |
| `2026-10-19-ubuntu-amd64-331df4d/` | `companion-os-1.0-amd64.iso`, 7,086,276,608 bytes, sha256 `f95cdf3d...b035`, built in a privileged ARM64 container (amd64 chroot through Rosetta) | branch `liam/companion-os-arm64`, commit `331df4d` (clean checkout) | `build-status.txt` (the exit code of the build was not recorded: the shell was lost in a stall; the ISO and its checksums were complete), `build.log` (ends at the layer comparison for the same reason), `verify.log` (444 passed, 0 failed) | [arm64.md](../architecture/arm64.md). Built on a busy Mac, 24 min against 12 min 52 s quiet. Not booted. |
| `2026-10-19-ubuntu-arm64/` | `companion-os-1.0-arm64.iso`, 5,593,038,848 bytes, built natively (arm64 container) | branch `liam/companion-os-arm64`, commit `ee25b63` (the verifier fixes of `2e09824` were made on the same ISO) | `build-status.txt` (build exit 0 in 1161 s), `verify.log` (436 passed, 0 failed), `installed-status-1.txt` and `installed-status-2-after-first-boot.txt` (the installed system 4 and 8 minutes after power-on: boot time, the first-boot unit and its throttle, Hub containers healthy), `installed-failed-units-and-errors.txt`, `first-boot-log-filtered.txt`, four frames in `frames/` | [arm64.md](../architecture/arm64.md). One-time passwords of the throwaway VM are not recorded; the confirmation frames that show one are not kept |

What is **not** here: a `verify-iso.sh` log for Plasma ISO #4 or #5 (none was kept; the log of ISO #6 is above), the package
lists and build logs of the Plasma ISOs (`.pkgs.txt`, `.build.log`: 20 KB and 240 to 260 KB; a release copies them, see the
[release checklist](../guides/release-checklist.md)), the full Calamares session log of ISO #6 (7,242 lines, 692 KB: the excerpt above carries the lines the
claims rest on), the first-boot log and journal of ISO #6 (read through the guest agent; the counts are in `run-record.txt`) and the logs of every pending Ubuntu row
(U2, U3 and the rest of the table in `test-evidence.md`). When a pending row is run, its records are added here in a new directory and the row is raised to **[V]** in the
same change.

## Figures

Screenshots are not part of this directory's rules. The capture step adds them under `docs/ui/companion-os/<edition>/` with the capture
notes of the run (the Plasma ISO #6 set is there, indexed in [`../ui/companion-os/README.md`](../ui/companion-os/README.md)). The one table of figure names, which every
commented-out placeholder in the documents uses, is the [Figures section of the test evidence page](../architecture/test-evidence.md#figures).

## The untracked directory `stick-qemu-evidence/`

The repository root of a working checkout may hold an untracked `stick-qemu-evidence/`: about 48 MB, files dated 2026-10-12 to 2026-10-15,
an HTML report with screenshots, macOS image checks and boot frames of the Companion Stick QEMU runs from before the 26.04.1 port. No
document, script or `.gitignore` entry refers to it. By its dates it is evidence for the retired 24.04.5 baseline **[I]** (the contents were
not re-read for this note), so it is not a source for any row in `test-evidence.md`, and at 48 MB it is not meant to be committed as it is.
The owner decides whether to keep it outside the repository or to delete it. Until then do not `git add` it. A search on 2026-10-18 found the host user name in 6 of its files, so it must not be swept in by `git add -A` or `git add .`. The same goes for the two untracked review notes at the repository root, `CI-OS-repo-review-2026-10-12.md` and `CI-Stick-flash-review-2026-10-12.md` (the first holds a path under a home directory): stage the named files and directories of a change, never the whole tree.

## Related pages

* [`../architecture/test-evidence.md`](../architecture/test-evidence.md): what has been run and what is still pending.
* [`../guides/release-checklist.md`](../guides/release-checklist.md): which records a release must keep.
* [`../guides/testing-in-qemu.md`](../guides/testing-in-qemu.md): how a run that produces such records is made.
