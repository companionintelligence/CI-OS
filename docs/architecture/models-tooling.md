# Model download and cache tooling (Ollama and Hugging Face)

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Design and status of `ci-stick models`: how a Companion Stick (or a provisioned Companion OS) gets the
curated models onto an exFAT cache, how that cache stays correct, and how Ollama, llama.cpp and
Hugging Face tools read the same bytes. The pack contents and licences are in
[model-packs-128gb.md](model-packs-128gb.md); the stick itself is in [companion-stick.md](companion-stick.md);
the Ollama store on `CI-CACHE` at boot is in [tier-b-tools.md](tier-b-tools.md), section 5.

Dated facts below come from live probes of `registry.ollama.ai` and `huggingface.co` on 2026-10-17 (anonymous
GETs, no weights downloaded) and from the Ollama v0.40.6, huggingface_hub 2.2.0 and llama.cpp sources read
that day. Where something was not executed, the text says so ([Not verified](#not-verified)).

## 1. Status

First written 2026-10-17 while the download code and the OS adapter were still being finished; this table was
re-read against the repository on 2026-10-18 (HEAD `02c575e`). Evidence tags: **[V]** verified by running or
reading the file named, **[I]** implemented and tested on fixtures, not proven end to end, **[N]** not implemented.

| Piece | State | Where |
|---|---|---|
| Pack catalog: `appliance-core`, reference spelling, cross-pack consistency, Hugging Face spelling | **done**, tested | `core/manifest/model-packs.yaml`, `manifest.rs`, `packs.rs` |
| Licence table and release gate (`LicenseTable`, `release_blockers`, `acceptance_required`) | **done**, tested. `fetch` does **not** use it yet: it gates only the licence string `unverified` (`fetch/plan.rs`, `license_needs_acceptance`), so Gemma and Llama terms are not yet asked for | `core/manifest/licenses.yaml`, `packs.rs` |
| Schema validator, mutation tests, example with a Hugging Face model | **done**, tested | `tests/schema.rs`, `tests/support/minischema.rs`, `schema/examples/` |
| Catalog-versus-lock comparison and the "resolved" accessor | **done**, tested. The repository lock exists now, so `catalog_sizes_match_the_lock_when_it_exists` compares for real (it no longer prints `SKIPPED`) | `packs.rs` (`LockView`, `lock_drift`, `resolve_packs`) |
| Lock format, writer and checks | **implemented** | `lockfile.rs`, `registry/` |
| `ci-stick models lock` | **implemented** for Ollama-library models (manifest lists resolved to the llama.cpp/GGUF child). `hf.co/...` references are skipped with a message. `--check` exits 3 on drift. A dry run into a scratch file on 2026-10-17 resolved all 36 distinct catalog models in 19 s; the only size difference from the catalog was `glm-ocr:latest` | `cmd_models.rs` |
| The generated lock `core/manifest/model-packs.lock.json` | **committed** in `89f7b27` [V]: schema 1, generated 2026-10-17T20:15:00Z, registry `https://registry.ollama.ai`, 36 models, all eight packs, 406,877 bytes. Its sizes sum (shared models counted once) to 320,261,934,062 bytes, the 320.3 GB `ci-stick models list` prints. Ollama references only | `core/manifest/model-packs.lock.json` |
| `models plan`, `models fetch`, `models cache-info` | **implemented** for Ollama references: ranged, resumable, SHA-256-verified downloads, manifest written last, `--offline`, `--max-bytes-per-sec`, `--concurrency` (default 1), `--events`, `status.json`, SIGINT/SIGTERM handling. Tested against local listeners, no real registry | `cmd_models.rs`, `fetch/`, `cache/`, `net.rs`, `events.rs`, `tests/models_*.rs` |
| `models verify`, `gc`, `export`, `import`, `view` | **not built** in `ci-stick` | |
| Hugging Face download (lock, fetch, view) | **not built**; references are recognised and set aside | |
| OS adapter, hardware gate, Hugging Face symlink view, prefetch units | **implemented** [I] in `df4ed3f` (work package 6): five test files plus a 110-mutant suite; the payload README records them passing on a stock Mac (bash 3.2, BSD awk) and, after the move to 26.04, in an `ubuntu:26.04` container (bash 5.3.9, uutils coreutils 0.10, mawk and gawk; `models-all.sh --mutation` 114 checks, 0 mutants survived). `check-repo.sh` runs the suites. **Nothing has run on a booted image, with real systemd, a real exFAT volume, a real GPU or a real `ci-stick`** | `core/lib/ci-os-models.sh`, `core/lib/gpu-detect.sh`, `backends/ubuntu/chroot/payload/models/`, `backends/ubuntu/chroot/tests/models-*.sh` |
| Hardware gate called by the provisioners | **wired** [V by reading]: Ubuntu (`backends/ubuntu/provision/provision.sh`, before `qwen3.6:27b`), the Arch engine (`backends/arch/provision/provision.sh`, so CachyOS too) and the CachyOS wrapper (`backends/cachyos/provision/provision.sh`, which skips a model the gate refuses instead of counting it missing). It checks **RAM and GPU memory only** | `core/lib/gpu-detect.sh` (`ci_os_model_fits`, `ci_os_model_gate_allows`) |
| Disk-space guard before a pull | **not built** [N]. Open item, section 14 | |
| Binary distribution into the images (work package 7), `serve-cache`, schema version 2 | **not built** | |
| Rust 1.75 compile of the whole tree | **not run here** [N]: there is no 1.75 toolchain on the host that ran the 26.04 port either. The `stick` job in PR checks runs `cargo +1.75 check --locked --all-targets` and has not run on GitHub since | |

## 2. Summary

1. `ci-stick models` resolves, pins, downloads and verifies models into a cache; the designed family is `{lock,plan,fetch,verify,gc,export,import,view,cache-info}`, of which
   `lock`, `plan`, `fetch` and `cache-info` exist today (section 1). It does **not** search, browse or recommend: that stays with CI Hub's catalog. `fetch` accepts only references
   that appear in a lock the maintainers reviewed.
2. The integration surface with CI Hub is the **Ollama model-store directory format** (`blobs/` plus
   `manifests/`). Hub already reads it: `fleet-llamacpp.ts` resolves a manifest in an Ollama store, takes the
   `application/vnd.ollama.image.model` digest and starts `llama-server --model /models/blobs/sha256-<digest>`,
   `hf.co/...` names included. No new Hub API is needed.
3. Registry tags are mutable and the Ollama registry cannot serve an old manifest by digest (every
   `GET /v2/library/<m>/manifests/sha256:<hex>` is 404). The lock therefore carries the manifest **bytes** inline.
4. Six of the 21 `stick-128` models are served as a **manifest list** under Ollama 0.40's `Accept` header, and
   for `qwen3.6:27b` one child is an 18.8 GB MLX safetensors variant. The lock pins the `llamacpp`/`gguf` child.
5. The pack sizes have already drifted: `glm-ocr:latest` was re-pushed on 2026-10-14 and grew from
   2,219,299,168 to 2,655,025,740 bytes (+19.6 %). The catalog test used to read only the YAML and could not
   see it; it now compares with the lock ([section 4.3](#43-the-catalog-is-a-copy-the-lock-is-the-fact)).
6. A Hugging Face GGUF file and an Ollama blob can be **the same file**: HF serves an Ollama-compatible
   registry whose model-layer digest equals the repo file's LFS sha256. Ollama-library GGUFs are different bytes
   from any HF GGUF of the same model, so there is no cross-world dedup for library models.
7. exFAT has **no symlinks and no hard links**, so both huggingface_hub and llama.cpp would copy a 40 GB file into
   `snapshots/`. The cache is therefore **one content-addressed store** (Ollama's) plus a tiny HF-layout *view* of
   symlinks built at boot on a Linux-native filesystem.
8. HTTP: `ureq` 3.2.1 with rustls and ring, default features off, behind a small `Transport` trait so a `curl`
   implementation can replace it.
9. Background prefetch is **off** by default, and when on it is throttled and unmetered-only.

## 3. Architecture and ownership

```
CI Hub catalog (curated-models.ts, future export)          owner: Hub    WHAT models exist, tiers, licence verdicts
        |  generates (future) / hand-maintained today
core/manifest/model-packs.yaml     intent: ref, quant, licence, min RAM, a size snapshot      owner: CI-OS
core/manifest/licenses.yaml        how each licence is treated; what blocks a release          owner: CI-OS
        |  ci-stick models lock                 (needs network; a maintainer or the release pipeline runs it)
core/manifest/model-packs.lock.json   facts: digests, sizes, manifest bytes, HF commits     generated, committed
        |  ci-stick lock --packs ... (digest -> bundle.json)       the lock also ships as a bundle artifact
bundle.json (signed)  --->  stick
        |  ci-stick models fetch / import / view / verify / gc      (dev host, release host, or the booted OS)
<CI-CACHE>/models      (Ollama store)        <CI-CACHE>/ci-models   (ci-stick private state)
        |  OLLAMA_MODELS                       |  `models view`: HF-cache symlinks on a Linux-native filesystem
   Ollama daemon / CI Hub                      llama.cpp -hf, huggingface_hub
```

- **`ci-stick` (Rust)** owns all network protocol logic, hashing, resume, the store writer, verification, gc,
  export/import, the HF view builder and progress events. It is the only component that talks to registries.
  It runs on macOS, Windows and Linux hosts (to populate a mounted stick) and on the booted OS.
- **A thin shell adapter** (`core/lib/ci-os-models.sh`, `df4ed3f`) picks the cache directory, calls `ci-stick models fetch` if the binary exists and
  otherwise falls back to today's `ollama pull` for Ollama references only, and applies the hardware gate. It must not require Rust: `core/` and the shell backends never depend
  on `stick/`.
- **CI Hub** owns the catalog and the online UX. `cihub models install` (which is `docker exec ollama pull`)
  stays as it is. What Hub is asked for, not a dependency: a catalog export with `backendModelId`, licence id and size
  per row.
- **No marketplace.** There is no `search` and no `pull <arbitrary-ref>`; the stick is a backend adapter for bare
  live boots and offline delivery (companion-stick.md, "Consuming Hub, Memory and model contracts").

## 4. The three files: catalog, lock, licences

### 4.1 The pack catalog (`core/manifest/model-packs.yaml`)

Hand-maintained and provisional until it is generated from Hub's catalog. Each model is the same `Model` record
that `bundle.json` carries; the Rust types in `manifest.rs` are the source of truth and
`stick/schema/bundle.schema.json` mirrors them. Packs:

| Pack | Models | Purpose |
|---|--:|---|
| `starter`, `balanced`, `coding`, `vision`, `large` | 4, 5, 5, 4, 5 | the curated sets by use |
| `stick-128` | 21 | ranked fill of a 123.9 GB stick's 73 GiB cache |
| `stick-128-oci` | 19 | `stick-128` minus its two lowest ranks, leaving 15 GiB for OCI images |
| `appliance-core` | 3 | exactly what `core/manifest/ecosystem.yaml` `llm.models` pre-pulls: `nomic-embed-text:latest`, `gemma3:1b`, `qwen3.6:27b` (18.85 GB) |

`appliance-core` exists because three places need "the models a provisioned machine must have" as a *pack*: the
hardware gate for the 17.8 GB model on the backends that pull it (the Ubuntu provisioner and the Arch engine under
CachyOS), a background prefetch (off by default) and the model-fit check. It aliases the first three `stick-128` entries,
so one model has one set of facts, and a test keeps it equal to `ecosystem.yaml` in both directions.

Rules the loader and the tests enforce:

- Digests stay `null` in the YAML; `models lock` resolves them. Never hand-write one.
- The same reference in two packs is the same model in every field (size, quantization, licence, RAM, VRAM,
  platforms, digest); `unique_models_bytes` would otherwise count whichever came last.
- Reference spelling (`Model::ref_problem`): an Ollama model is `<name>:<tag>` or `<namespace>/<name>:<tag>`; a
  Hugging Face model is `hf.co/<org>/<repo>:<quant-or-file>`. Name parts and tags are 1 to 80 characters of
  `[A-Za-z0-9_.-]` starting with a letter, digit or `_`, not ending in `.`, and not a Windows device name (the
  strings become exFAT directory names that a Windows host must be able to open). A registry host in the name is
  refused, as is a `:cloud` tag (no weights), and two references that differ only by case (exFAT is
  case-insensitive).
- Every `license:` string has a row in `licenses.yaml` (4.4).
- `stick-128` and `stick-128-oci` fit the real 128 GB stick's cache with 3 % headroom (the existing sizing test).

**Hugging Face entries.** The record needs no new field: `name: hf.co/<org>/<repo>`, `tag: <quantization label or
file name>`, `digest` null until locked. That is the spelling CI Hub's catalog already uses
(`hf.co/unsloth/GLM-5.2-GGUF:UD-Q4_K_XL`) and the reference Ollama itself stores. The repository revision, the
file, its LFS sha256 and the licence id live in the lock. **No pack lists a Hugging Face model today.** The
discovery work named no catalog candidate: its examples (`ggml-org/gemma-3-270m-GGUF`,
`unsloth/gemma-3-270m-it-GGUF`) prove the protocol, duplicate `gemma3:270m` which `stick-128` already carries
from the Ollama library, and the second needs Gemma terms acceptance. Entries are added when a model has a
reviewed licence, a single ungated GGUF file and LFS sha256 evidence, and not before.

### 4.2 The lock (`core/manifest/model-packs.lock.json`)

Generated, canonical JSON, committed, reviewed like code. It is the *fact* behind the catalog's *intent*:

```
{ "schema_version": 1, "generated_at": "...", "tool": "ci-stick ...", "registry": "https://registry.ollama.ai",
  "packs":  { "<pack>": ["<ref>", ...] },                  // catalog order, so plan and fetch work from the lock alone
  "models": [ { "ref": "qwen3.6:27b", "source": "ollama", "license": "Apache-2.0",
                "manifest": { "digest": "sha256:...", "size": 1046, "runner": "llamacpp", "format": "gguf", "b64": "..." },
                "list_digest": "sha256:...",               // present when the tag was served as a manifest list
                "layers": [ { "role": "config|model|projector|license|params|...", "media_type": "...", "digest": "sha256:...", "size": 0 } ],
                "size_bytes": 17769076933, "requires_ollama": "0.30.0", "quant": "Q4_K_M", "push_time": 1791991630 } ],
  "blobs_inline": { "sha256:...": "<base64 of every blob of at most 64 KiB>" } }
```

Sorted keys, two-space indent, trailing newline; models sorted by `ref`; a re-run that finds nothing new is byte-identical. (The Hugging Face fields in the first design, a repo,
a pinned revision, the file and its LFS sha256, are not in the format yet.)

- It is a separate file, not YAML: `serde_yaml` cannot round-trip the catalog's anchors and comments, and a lock is
  an observation with a date, not intent. `schema_version` is the lock's own; **the bundle's stays 1**.
- `size_bytes` is the sum of the config and layer sizes: the figure the catalog's `size_bytes` copies. A registry manifest can state a wrong length for a small
  blob (`qwen3-coder:30b`'s config is declared as 539 bytes and is 542); `models lock` warns and trusts the digest, and the layer sizes in the lock stay as the manifest declares them.
- A tag served as a manifest list is pinned twice: `list_digest` detects the tag moving, the child's
  `manifest.digest` is the reproducible content. The named manifest written to a store is the child, so the
  daemon never wants the MLX variant.
- `Model.digest` in `bundle.json` is the lock's `manifest.digest` (already a legal value); `ci-stick lock --packs`
  needs only a merge step, and the lock ships in a bundle as a `model-blob` artifact so the bundle signature
  covers it.
- The catalog checks read three facts from it (`ref`, `size_bytes`, `manifest.digest`) through `packs::LockView`,
  which ignores everything else so the lock can grow; a test keeps it in agreement with the writer's `ModelLock`.

### 4.3 The catalog is a copy; the lock is the fact

`packs::lock_drift(packs, lock)` compares each distinct model: not in the lock, `size_bytes` different by **any**
number of bytes, or a catalog digest the lock does not pin. `packs::resolve_packs(packs, Some(lock))` returns the
packs with the lock's size and digest applied, so `fit_report(&resolve_packs(..), capacity)` sizes a cache from the
registry's numbers instead of a 2026-10-13 snapshot; `ResolvedModel` records where each value came from.

The unit test `catalog_sizes_match_the_lock_when_it_exists` fails on drift once the lock file exists, and it
exists now (when it is absent the test prints `SKIPPED (this is not a pass)` on stderr). The drift below was found
on 2026-10-17 and **is resolved**: the YAML now carries 2,655,025,740 for `glm-ocr:latest`, copied from the lock
(with a comment in `model-packs.yaml` that says never to edit it by hand). It is kept as the worked example:

| Model | Catalog (read 2026-10-13) | Registry (2026-10-17) | Cause |
|---|--:|--:|---|
| `glm-ocr:latest` | 2,219,299,168 | 2,655,025,740 (+435,726,572) | re-pushed 2026-10-14T15:27:10Z; now 4 layers including an 869,018,176 B projector |

The other 20 `stick-128` models match to the byte. This moves `stick-128` from 74,359,550,640 to 74,795,277,212
bytes and the free space of the 73 GiB cache from 3.72 GiB to 3.34 GiB; both packs still pass the 3 % rule
(`stick-128-oci` plus 15 GiB of OCI images: 75.79 GB of 76.03 GB allowed). The 15 distinct models that are
not in `stick-128` (`starter` to `large`) were last read on 2026-10-13 and are unchecked since. A `HEAD` per
model (`ollama-content-digest`, `ollama-push-time`) is enough to detect a re-push, so `models lock --check` is one
tiny request per model and suits a scheduled job.

### 4.4 Licences (`core/manifest/licenses.yaml`)

One row per licence string a pack uses: SPDX id (or a `LicenseRef-...` where SPDX lists none), terms URL, a
`gate`, aliases (Hugging Face `cardData.license` ids, registry short names; matched case-insensitively) and
notes.

| Gate | Meaning | Licences today |
|---|---|---|
| `none` | nothing; the licence text travels with the model blob | Apache-2.0, MIT |
| `notice` | show name and URL, no recorded acceptance | (unused) |
| `accept` | refuse until the person accepts by name, recorded with the time and the licence text hash (design: `--accept-license "<name>"` or the launcher's dialog; today `fetch` has only `--accept-licenses`, which covers `unverified`) | Gemma Terms of Use, Llama 3.1 / 3.2 / 3.3 Community Licenses |

`release_blocking` is the **explicit** list of `license` strings that stop a release bundle. It holds one entry,
`unverified` (companion-stick.md: "any entry marked `unverified` blocks a release"); a licence that is neither in the table nor
on that list also blocks (`packs::release_blockers`). A test pins the list, another asserts that `stick-128`,
`stick-128-oci` and `appliance-core` have no blocker, another that every licence a pack names is listed. This is
not legal review; Gemma and Llama redistribution still need a person (model-packs-128gb.md, 4.5).

## 5. Command contract

The family is `ci-stick models`. A column says what exists; everything marked "not built" is the design the code was
written to fit.

| Command | Network | Writes | Purpose | State |
|---|---|---|---|---|
| `models list` | no | no | pack fit table | exists |
| `models lock` | yes | the lock file only | resolve tag to digest and size, pick the llama.cpp child of a manifest list, inline small blobs; `--check` re-resolves and reports drift (exit 3) | implemented for Ollama references |
| `models plan --pack P` | no | no | bytes present, in partials and still to fetch; occupancy after cluster rounding; free space; whether it fits (the 3 % rule); exit 4 when it does not | implemented |
| `models fetch (--pack P \| --model REF)` | yes | the cache | download missing blobs, verify, write manifests last | implemented for Ollama references |
| `models cache-info` | no | no | size, blobs, partials, free space, which pack models are complete; warns about RAM-backed and read-only volumes | implemented (no symlink, case or exFAT dirty-flag probe yet) |
| `models verify` | no | no | audit a cache (sizes; `--full`: hashes) | not built |
| `models gc` | no | with `--apply` only | remove what is provably dead | not built |
| `models export` / `import` | no | out dir / cache | a signed offline pack that is also a valid `OLLAMA_MODELS` root | not built |
| `models view` | no | the view dir | the Hugging Face-layout symlink view | not built in `ci-stick`; the OS adapter builds it in shell |

`--json` is accepted by every reporting command. The cache directory defaults to `$CI_STICK_CACHE`, the registry to
`--registry-url`, else `$CI_OS_REGISTRY_URL`, else `https://registry.ollama.ai`; `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` are honoured.

**Exit codes.** `0` ok, `1` error that is not resumable (a 404 for a blob, a read-only cache, a disk error), `2` usage error or unreadable
input, `3` `lock --check` found drift, `4` not enough space (preflight or while writing), `5` a licence was not accepted (the other models were still
fetched), `6` interrupted, or the network stayed down after the retry budget, or `--offline` with work left (partials are kept and a rerun resumes),
`7` integrity failure (a hash or size did not match). Codes 0 to 2 keep their meaning from companion-stick.md; 3 to 7 are new and let a service manager
tell "try again later" (6) from "do not retry" (1, 2, 4, 5, 7). The shell adapter adds 10 to 13 for its own conditions.

**Events.** `fetch --events <file>` appends JSON lines, `--events -` writes them to stdout and then nothing else goes to stdout. Every line carries the keys
`event`, `model`, `blob`, `bytes`, `total`, `rate_bps`, `eta_s` and `ts` (null where they do not apply). `event` is `start`, `progress` (at most two per
second), `blob_done`, `model_done`, `error` (with `code`, `message`, `exit`, `fatal`) or `done` (with `status` `ok`/`failed`/`interrupted`, `exit` and the
counts of models done, failed and gated). Retries are not events; they show in `status.json`. URLs in events, logs and error messages are the pre-redirect
URL with the query stripped: presigned redirect targets carry `X-Amz-Signature` or `Signature=` credentials and are never written anywhere.

**Status file.** `<cache>/ci-models/status.json` is rewritten atomically (temp file and rename), at most once a second except on state changes. It carries
`schema`, `job`, `state` (`idle|running|retrying|done|failed|interrupted`), `updated`, `pack`, `bytes_total`, `bytes_done`, `rate_bps`, `eta_s`, `current`
(model, blob, done, size), per-model state (`queued|running|done|failed|gated`), `last_error` and `retry_in_s`. The setup portal can poll it with the Python
standard library and no new service. The portal runs as root and its `POST /api/configure` has no credential today, so **no job-start endpoint may be
exposed through it** until the authentication work lands. An optional local API (`models serve` on a Unix socket, mode 0660) is phase 4. The design also wanted
a `waiting` state for "no route for hours" (the setup access point flips the Wi-Fi radio when there is no default route); today a lost network ends the job with
exit 6 and the OS adapter's timer starts it again.

## 6. Behaviour

**`lock`** (implemented for Ollama references). For each reference it `GET`s `/v2/library/<name>/manifests/<tag>` with the Accept header Ollama 0.40.6 sends,
records the body's sha256 (the `GET` carries no digest header) and confirms it with a `HEAD` (`ollama-content-digest`, `ollama-push-time`). If the body is a
list it picks the child whose `runner`/`format` is `llamacpp`/`gguf`, fetches it from `/blobs/<child digest>` (child manifests are content-addressable there)
and verifies its sha256. It validates layer media types against an allow-list (**`image.tensor` and `image.json` rejected**), digests `^sha256:[0-9a-f]{64}$`,
at most 64 layers and a manifest of at most 1 MiB; it stores every blob of at most 64 KiB inline and de-duplicated, and it prints where the catalog's
`size_bytes` differs from the registry. A re-run that finds nothing new leaves the file byte-identical. `--check` writes nothing: one `HEAD` per model, plus the
catalog-versus-lock comparison. Not built: the Hugging Face half (`GET /api/models/<repo>?blobs=true`, the pinned commit and `lfs.sha256`, refusal of shards and
non-LFS weights, the check that HF's Ollama-compatible manifest carries a model layer equal to that sha256, an allow-list for the `params` keys HF generates
(`stop`, `temperature`, `top_k`, `top_p`, `min_p`, `repeat_penalty`, `num_predict`, a capped `num_ctx`), and `unverified` for a card without a licence) and
the comparison of licence-layer digests between two locks.

**`plan`** (implemented) needs no network and no cache directory. It subtracts blobs already present and resumable partials, counts blobs shared between models
once (space is accounted by digest, not by `name:tag`), rounds each file up to the 128 KiB cluster `mkfs.exfat` picks above 32 GiB, and requires the bytes to
write plus 3 % of the volume's capacity to fit in the free space. Not built: the `requires` check against the installed Ollama and a host-fit verdict.

**`fetch`** (implemented).

- Small blobs from the lock are written first with no network. Big blobs are downloaded by `--concurrency` workers (default 1: one stream is kind to a USB
  stick; the design also wanted four on a non-removable cache, which nothing detects yet) with one shared `--max-bytes-per-sec` limiter.
- A blob that exists with the right size is skipped. Otherwise it goes to `ci-models/partial/` with a journal that says how many bytes are durable (`fsync`
  first, journal second, so exFAT's valid-data-length behaviour after a power loss cannot lie to us). Resuming cuts the data back to the journal, re-reads and
  re-hashes that prefix from disk, then continues; if the final hash is wrong after a resume the partial is discarded and the blob is fetched once more from zero
  before giving up.
- The transfer is a series of ranged `GET`s of adaptive size (about eight seconds each, 1 to 64 MiB), which is also how a stall is detected without a watchdog.
  `206` with the exact `Content-Range` continues; `200` to a ranged request means the range was ignored (accepted only from offset 0); a `416` that reports a
  different size is an integrity failure; `404` is permanent; `429` and `5xx` back off honouring `Retry-After`. A `401`/`403` from the remembered CDN URL means it
  expired, and the registry is asked again (R2 URLs live 24 hours, Hugging Face's 3600 s).
- Completion: size equals the locked size, SHA-256 equals the locked digest (computed while streaming), `fsync`, rename to `models/blobs/sha256-<hex>` on the same
  volume. Nothing is trusted before the hash matches.
- **Order: all blobs of a model verify first, the manifest is written last** (temp file and rename), verbatim from the lock, and an empty `manifests-v2/` is
  created, so a daemon scanning the store never sees a manifest whose blobs are missing. After a hard failure of one blob the other models carry on; running out of
  space, a network that stays down or an interrupt stop the whole job and leave resumable partials.
- Preflight: a read-only volume is refused, free space is checked before the first byte (exit 4). Licences: a model whose licence string is `unverified` is skipped
  unless `--accept-licenses`, and the job exits 5 after fetching the rest. **Gating Gemma and Llama terms from `licenses.yaml` is not wired in yet** (4.4). Not built:
  refusing a RAM-backed target (`cache-info` only warns), reading the exFAT dirty flag, `--unmetered-only` (the OS adapter checks NetworkManager's `Metered`
  property before it starts a prefetch), per-hop `--allow-private-network` and `--insecure` switches (a configured registry on a loopback host may use `http`, which is how
  the tests run).

**`verify`, `gc`, `export`, `import`, `view`** are the designed rest of the family and none is built in `ci-stick`.

- `verify` would parse every manifest under `models/manifests/**`, check that each referenced blob exists with the stated size (or hash, with `--full`), and report blobs
  nobody references, AppleDouble `._*` files, `.DS_Store`, `.fseventsd`, `.Spotlight-V100`, `.Trashes`, files whose names are not valid digests, zero-byte files, leftover
  `*-partial*` from an interrupted `ollama pull`, case-fold collisions, and manifests whose sha256 differs from the lock. `--full` of 74.8 GB is about 8 minutes at
  150 MB/s and about 36 minutes at 35 MB/s (arithmetic only).
- `gc` would be a dry run unless `--apply`, never run while `ollama.service` is active on that directory, remove stale partials, Finder and Spotlight debris, unreferenced
  blobs older than an hour and Ollama's own leftover `*-partial*`, and never delete manifests (that is `ollama rm`) or touch `models/metadata/` (a regenerable GGUF header cache
  the daemon writes). With `OLLAMA_NOPRUNE=1` the daemon never reclaims the layers a re-pull replaces, so a stick used with live pulls grows until `gc` runs.
- `export`/`import`: blobs are named by sha256, so **signing the lock authenticates the whole tree** and no per-blob signature is needed. `export` writes the lock, its
  detached ed25519 signature (`signing::sign_to_hex`) and `models/{blobs,manifests}`; `import` verifies the signature fail-closed, then copies each blob while hashing it.
- `view`: for each locked model that a Hugging Face-layout consumer reads, create `<view>/models--<org>--<repo>/refs/main` (the pinned commit) and
  `<view>/models--<org>--<repo>/snapshots/<commit>/<file>` as a **symlink to the blob on the exFAT store**. The view directory must support symlinks (it is probed) and lives
  on the host root, `CI-PERSIST` or tmpfs; it is a few kilobytes and rebuilt idempotently at boot.

## 7. Cache layout on the stick

Options judged against the three consumers (Ollama blobs, HF/llama.cpp layout, plain `-m file.gguf`) and the reason the cache is exFAT at all (readable from any host
during a host install):

| Option | Duplicates 40 GB? | Windows and macOS can read it? | Verdict |
|---|---|---|---|
| A. HF cache directly on exFAT, symlinks disabled | yes if the same GGUF is also in Ollama's store | yes | only for HF-only repos |
| B. flat store plus snapshot materialised by copy | yes | yes | rejected |
| C. flat store plus reflink | no, but only on btrfs, XFS, APFS | n/a on exFAT | rejected |
| D. loopback ext4 image on exFAT holding the caches | no | **no** (opaque file) | rejected for models |
| E. make `CI-CACHE` ext4 | no | **no**: loses host install and Windows/macOS population | optional later (`--cache-fs ext4`) for Linux-only sticks |
| **F. one store on exFAT plus an HF-layout view of symlinks on a Linux-native filesystem** | **no** | **yes** | **chosen** |

Why a symlink view rather than a second copy: exFAT's directory operations are create, lookup, unlink, mkdir, rmdir, rename, setattr and getattr (Linux v6.8
`fs/exfat/namei.c`); there is no `symlink` and no `link`. `huggingface_hub` probes for symlink support and, when it fails, *moves or copies* the blob into
`snapshots/<commit>/<file>`; llama.cpp tries a relative symlink and on failure renames or copies. Both accept regular files *or* symlinks when reading, and both read
`refs/<branch>` plus `snapshots/<commit>/`. So a view of symlinks that point at the one exFAT blob serves them with zero duplicate bytes. Why one store can serve both
runtimes: for a Hugging Face GGUF the Ollama blob digest *is* the repo file's sha256, and the Ollama blob is a plain GGUF (magic `GGUF`, version 3, and Hub already runs
`llama-server` on it). For library models only the Ollama world exists and llama.cpp reads the blob directly with `-m`.

```
<CI-CACHE>/
  models/                       <- OLLAMA_MODELS: Ollama files only; nothing else may live here
    blobs/sha256-<hex>          config, model, projector, template, params, license and manifest blobs; HF-sourced GGUF too
    manifests/registry.ollama.ai/library/<name>/<tag>   the registry's child manifest, verbatim, named after the tag
    manifests/hf.co/<org>/<repo>/<quant>                (designed) manifest assembled from the lock, HF's own bytes
    manifests-v2/               empty directory (Ollama 0.40 calls MkdirAll on every access)
  ci-models/                    <- ci-stick private; a sibling of models/, never inside OLLAMA_MODELS
    VERSION                     "ci-models-cache/1"
    blobs/<hh>/<hex>            content-addressed files Ollama must not see (safetensors shards, llama.cpp-only GGUF)
    partial/<hex>-partial, <hex>-partial.journal      resumable downloads
    status.json                 progress for the setup portal
    (designed, not built: locks/<pack>-<sha8>.json, receipts/<ref>.json)
  oci/                          OCI images, unchanged
```

Rules that follow from Ollama's source (v0.40.6): at start, unless `OLLAMA_NOPRUNE` is set, the daemon deletes every file in `blobs/` older than an hour that is
not a valid digest name or that no manifest references. Therefore partials live **outside** `models/blobs`, and anything no Ollama manifest references (llama.cpp-only
GGUF, safetensors) lives in `ci-models/blobs`. The legacy `manifests/<host>/...` tree is what Ollama 0.33 to 0.40 read; 0.40 prefers a `manifests-v2/` tree and falls
back to the legacy file without mutating it. Space is counted by digest, not by `name:tag`: the Apache licence blob `c71d239d...` (11,357 B) is shared by several models.

## 8. Security rules

Remote data names files and sizes; treat all of it as hostile. What the code enforces today is marked; the rest is the rule the unbuilt parts must meet.

- **Names.** Every path derived from remote data passes the cache layout's name rules (`cache/layout.rs`): no empty or over-long component, no separator, control or
  reserved character, no component ending in `.` or space, no Windows device name, no `._` prefix, and case-fold collision detection. Ollama references use Ollama's own rule;
  digests match `^sha256:[0-9a-f]{64}$` (lowercase only). The catalog applies the same character rules to names and tags when it loads (4.1), and a test checks that the two
  parsers refuse the same spellings. *Enforced.*
- **No symlink is ever followed or created inside the store**; `view` creates symlinks only in its own output directory, with targets computed from digests, never from remote
  strings. *Nothing in the store writer makes a link; `view` is not built in `ci-stick`.*
- **Size caps.** Manifest at most 1 MiB, inline blob at most 64 KiB, at most 64 layers, a body longer than declared is an integrity failure, `Content-Range` must match the
  request. *Enforced.*
- **Redirects** (`net.rs`). https only and never a downgrade; at most 5 hops; no user-info in URLs; a host is trusted if it is on the allow-list (`ollama.com`, `ollama.ai`,
  `hf.co`, `huggingface.co`, `cloudflarestorage.com`, suffix match) or is the registry the operator configured, and any other host must resolve to **public** addresses only
  (no loopback, private, link-local, CGNAT, documentation, benchmarking, 6to4 or v4-mapped ranges), with the resolver handing the connector only validated addresses so the
  connection cannot be rebound between the check and the connect. Behind a proxy the proxy resolves the target and the check cannot run, so hosts outside the allow-list are
  refused. A configured registry on a loopback host may use `http` (this is how the offline tests run). `Authorization` and `Cookie` headers are never forwarded to another
  origin. *Enforced.*
- **Tokens.** `HF_TOKEN` from the environment (or `--token-stdin`) only; never persisted or logged; never written to the lock, journal, events, status file or process
  arguments; attached only to requests to `huggingface.co`, `hf.co` or the configured endpoint; never forwarded to CDN hops; no implicit read of
  `~/.cache/huggingface/token`. Accepting a gated repo's licence is a logged-in web action and cannot be automated, so a gated repo must end in an action-required exit
  with the web URL. *Rules for the unbuilt Hugging Face half: the Ollama registry is anonymous and the current code sends no credential.*
- **Content.** Allowed types: `.gguf`, `.safetensors` (phase 3), small JSON/text and licence files. Pickle-family files (`.bin`, `.pt`, `.pth`, `.pkl`, `.ckpt`, `.h5`, `.onnx`
  unless explicitly allowed) are refused. GGUF is never parsed beyond the 4-byte magic and version. README and licence text are untrusted: control characters and ANSI
  escapes are stripped for terminals and HTML-escaped in the portal, and never fed to a model. *Tensor layers are refused at lock time; the rest applies to the Hugging Face half.*
- **Supply chain.** Trust is the digest in a reviewed, signed lock. A mirror or CDN cannot change content without failing the hash; metadata fetched from a mirror at lock
  time is unauthenticated, so `models lock` should refuse a non-official endpoint unless explicitly told (`--allow-mirror-lock`, not built).
- **Device safety** is untouched: nothing here writes a block device (`target.rs` rules stay pure and fixture-tested).

## 9. Test strategy

No test downloads a model. Everything runs offline against local listeners and golden fixtures; anything live is opt-in behind an environment variable and off by default.

Catalog and schema (this document's owner; `cargo test` in `stick/`):

- `tests/schema.rs` with `tests/support/minischema.rs`, a std-only JSON-Schema validator for the keyword subset the schema uses, including a small backtracking regex
  engine for its `pattern`s (`stick/Cargo.lock` has no `regex` crate). It **validates**, not only compares key sets: every `schema/examples/bundle*.example.json` and the real
  `model-packs.yaml` (converted through `serde_yaml`) against `bundle.schema.json`. An unimplemented keyword in a schema is an error when it loads, never a skipped check.
- A table of 62 **mutations** (a wrong type, a missing required field, an unknown key, an out-of-range number, a bad enum value, a path escape, ...) applied to both
  examples. Each must fail the schema *and* fail `Bundle::parse` or `Bundle::validate`; four rows record where the schema is deliberately stricter than the Rust reader (a
  missing nullable `digest` or `min_vram_gb` key, `layout.table`, `gpt_type`) and fail if Rust ever starts rejecting them, so the gap cannot widen unnoticed. Breaking the
  schema in five different ways (a bound, a pattern, `additionalProperties`, a required list, an extra property) was tried and each was caught.
- The schema's `pattern`s are cross-checked against the Rust predicates they mirror (`is_sha256_hex`, `is_model_digest`, `is_rfc3339_utc`, `validate_rel_path`) on a corpus;
  the one known difference (C1 control characters in paths) is asserted, not hidden.
- `a_hugging_face_model_validates_without_changing_the_record_or_the_version` pins the `Model` record at nine fields and `schema_version` at 1, and validates an
  `hf.co/<org>/<repo>` model (the second example bundle) without touching either.
- In `packs.rs`: the lock reader and drift detection (plus or minus one byte on every model of the real catalog), `resolve_packs`, the licence table, the release gate,
  `appliance-core` against `ecosystem.yaml`, reference spelling and its agreement with the downloader's parser, cross-pack consistency, and agreement of `LockView` with the
  lock writer's `ModelLock`. `tests/packs_catalog.rs` runs `models list` on the real catalog and on broken ones.

Download code (owned by the work package that wrote it): `tests/models_lock.rs`, `tests/models_fetch.rs` and `tests/models_resume.rs` drive the real binary and library against
a std-only mock registry and CDN (`tests/models_support/`), with golden manifests captured from the live registries (`tests/fixtures/models/`), and unit tests sit beside the
modules. They cover: relocking changes nothing and `--check` exits 3 when a tag moved or the catalog and lock disagree; catalog size drift like `glm-ocr`; transient registry
errors; refusal of tensor layers and conflicting licences; Hugging Face entries skipped with a warning; shared blobs counted once and the 3 % rule; resume from the journal, a
journal and data that disagree, a corrupt resumed prefix, random cuts with seeded sizes; a body cut short, 5xx and 429 with `Retry-After`, a network that stays down, a missing
blob, an expired presigned URL, a server that ignores `Range`, a stall; wrong bytes (exit 7, nothing enters the store) and a wrong size; a hostile redirect refused without being
followed; `unverified` licence gating; `--offline`; the shared rate limit with parallel workers; a full disk (exit 4, consistent partial); cancellation mid-transfer; and macOS or
Windows litter in the cache being ignored.

Not in the tree when this was written: Hugging Face routes, opt-in live tests, a run against a loop-mounted exFAT image (a separate Linux job nobody has executed) and
tests of the unbuilt commands. The live tests were specified to use the smallest models that exist (`CI_STICK_LIVE=1`): `all-minilm:latest` (45,960,996 bytes) and, for Hugging
Face, `ggml-org/models-moved` `tinyllamas/stories260K.gguf` (1,185,376 bytes, no licence on its card, so it exercises the `unverified` path).

## 10. Runtime integration on a booted stick or installed OS

Work package 6 in the plan, written by a different group and committed in `df4ed3f`. This section is the design it was given; the code is in `core/lib/ci-os-models.sh`, `core/lib/gpu-detect.sh` and
`backends/ubuntu/chroot/payload/models/` (see its README, which also lists what is not verified), and the CachyOS overlay carries copies of the units under
`backends/cachyos/iso/overlay/files/airootfs/usr/share/ci-os/models/`. Read those, not this paragraph, for what they do today.

- **Environment.** `ollama-models-env` writes `OLLAMA_MODELS` and `OLLAMA_NOPRUNE=1`. The design adds `CI_STICK_CACHE=<mnt>`, `HF_HUB_CACHE` and `LLAMA_CACHE` pointing at the view
  directory (llama.cpp reads `LLAMA_CACHE` first and uses it as the hub directory itself). `HF_HUB_OFFLINE=1` only inside the units that run models, not globally; do not set `HF_HOME`
  (it also holds the user's token).
- **View unit.** A oneshot after the cache mount builds the symlink view on a Linux-native filesystem. The shell adapter carries a view builder; `ci-stick models view` does not exist.
- **Prefetch.** A timer plus service, enabled only by a flag file, throttled, idle I/O class, an `ExecCondition=` that checks NetworkManager's `Metered` property; default off. systemd
  has no per-unit bandwidth cap, so the limit is the tool's token bucket (`--max-bytes-per-sec`).
- **Where it may write.** On a Stick live boot the only valid targets are `CI-CACHE` and the persistence volume; on an installed system, the Ollama store. Never RAM.
- **Hardware gate.** Before this work only Ubuntu gated the 17.8 GB model, and by a vendor rule (Strix Halo with at least 30,000 MiB). The design replaces it with data: RAM and GPU
  memory against each model's `min_ram_gb` and `min_vram_gb`, counting unified-memory machines as having their GPU-addressable share (CI Hub's `computeInferenceBudget` fractions were the ones
  to copy; the code applies the practical minimums without a second fraction, see the header of `core/lib/gpu-detect.sh`). The rule, from that header: RAM needs at least `min_ram_gb` GiB x 91 %;
  a numeric `min_vram_gb` needs GPU memory of at least that many GiB x 95 % (a CPU-only machine does not fit such a model unless `CI_OS_FIT_CPU_OK=1`); a unified-memory machine needs
  `MemTotal` plus the BIOS carve-out to cover `max(min_ram_gb, min_vram_gb)` at the RAM percentage. The first draft of this paragraph said "RAM, VRAM and disk": **the code does not check
  disk** (section 14, item 1). The adapter reads the numbers from `model-packs.yaml`; `appliance-core` is the pack that carries the 17.8 GB model on the Ubuntu and CachyOS editions.
  **Operator overrides** (all read in `core/lib/gpu-detect.sh`): `CI_OS_MODEL_FIT_OVERRIDE=allow|deny` forces the answer of `ci_os_model_fits` before any data is read (`allow` pulls a model the machine does not fit, `deny` skips every model);
  `CI_OS_MODEL_RAM_PCT` (default 91) and `CI_OS_MODEL_VRAM_PCT` (default 95) move the percentages; `CI_OS_FIT_CPU_OK=1`, `CI_OS_FIT_RAM_MIB`, `CI_OS_FIT_VRAM_MIB`, `CI_OS_FIT_UNIFIED` and `CI_OS_MODEL_PACKS_FILE` are for support and tests. Without a `model-packs.yaml` the gate has no data and
  does not block (the CachyOS edition's situation, KI-01). The table of these variables is in the [environment reference](../guides/environment-reference.md#models-and-the-hardware-fit-gate).
- **Getting `ci-stick` into the OS** is unsolved: no backend ships it. Options: the bundle's `tools/linux-x86_64/ci-stick` on `CI-SHARED` (exFAT is mounted `noexec`, so copy to tmpfs first); bake
  it into the base layer with a pinned sha256 in `tier-b-pins.env`; a static musl build. New payload files belong in the **base** layer so they exist on the installed system too
  ([ubuntu-iso-layers.md](ubuntu-iso-layers.md)).
- **Live sessions.** `ollama.service` is disabled in Stick live sessions today (the Ubuntu `10-not-live.conf` drop-in). Until that is decided (stick audit decision D5, open), the cache is only reachable through `ci-stick` and
  `llama-server -m`. On the CachyOS edition `ollama.service` is installed by Calamares but left disabled; the first-boot provisioning enables it, so `ollama --version` prints two "no server" warnings between the install and the end of the first
  boot (seen on ISO #4, [cachyos-backend.md](cachyos-backend.md#test-status)).

## 11. Decisions

The numbering is this document's own. "Audit D5" below is decision D5 of the stick audit, a different list.

| # | Decision | Chosen default | Still open |
|---|---|---|---|
| D1 | HTTP and TLS stack | `ureq` **3.2.1**, `default-features = false`, `rustls` (ring), pinned with `=`, behind `net::Transport` (`UreqTransport`). A `curl` implementation can replace it; it cannot enforce public-IP checks or token scoping beyond curl's defaults, so it is the OS-adapter fallback, not the primary. Under MSRV-aware resolution the dependency adds 26 lock entries (17 on non-Windows) and no ICU or `url` stack; ureq 3.4.2 and reqwest 0.13.5 declare Rust 1.85, which is why the pin and `stick/.cargo/config.toml` matter. *Implemented.* | A compile with Rust 1.75 was not run here (section 1); release-binary size; a TLS-intercepting proxy needs `rustls-native-certs` behind a CA-bundle option; `ureq::unversioned` is an unstable API, hence the exact pin |
| D2 | Schema and spelling | `Model` and `schema_version` unchanged. A Hugging Face model is `name: hf.co/<org>/<repo>`, `tag: <quant>`. The bundle schema is not tightened. *Implemented and tested.* | First-class `source`, `runtime` and `hf` fields arrive with `schema_version: 2` only when a non-GGUF consumer needs them; a writer emits 2 only when it uses one, and a reader should peek the version before the full parse so a v3 says "needs a newer ci-stick" |
| D3 | Lock | Separate canonical JSON `core/manifest/model-packs.lock.json`, generated, committed; manifest bytes and small blobs inline; list digest and child digest both pinned; the catalog's sizes are a copy of it. *Format and `models lock` implemented; the file is committed (`89f7b27`, 2026-10-17).* | Who runs `models lock` and when (a scheduled `--check` job is suggested); the lock's own `schema_version` policy |
| D4 | Cache layout | One content-addressed store: Ollama's `models/{blobs,manifests}` plus `ci-models/` for files Ollama must not see; partials outside `models/blobs`; written by `ci-stick` with no daemon; manifest last. *Implemented for Ollama references.* | Ollama 0.40.x reading a legacy-only seed, and writing to a real exFAT volume, were not executed |
| D5 | Hugging Face-layout consumers | A symlink *view* built at boot on a Linux-native filesystem, zero duplicate bytes; a copy only with an explicit `--allow-duplicate`. *Built in the shell adapter, not in `ci-stick`.* | Whether the view lives on the host root, `CI-PERSIST` or tmpfs; hot-plug of `CI-CACHE` is not handled (Ollama picks the volume at start) |
| D6 | Hugging Face scope, v1 | Single-file, ungated GGUF. Shards, safetensors, pickle-family files and gated repos are refused. *Not built: references are set aside.* | Sharded GGUF (Ollama's registry answers 400 for them; whether a hand-written manifest with N model layers loads is untested), safetensors for non-Ollama runtimes |
| D7 | Credentials | `HF_TOKEN` from the environment only; never persisted or logged; sent only to HF hosts, never to CDN hops. *The current code sends no credential at all.* | Behaviour with a token was not exercised |
| D8 | Licences | `licenses.yaml` drives gating. `fetch` refuses a model whose licence is `unverified` unless `--accept-licenses` *(implemented)*; `gate: accept` needs a named, recorded acceptance *(not wired: the table and `acceptance_required` exist, `fetch` does not call them)*; `unverified` and unknown licences block a release *(`release_blockers`, tested; no `lock --release` calls it yet)* | Legal review of Gemma and Llama redistribution terms and of the Llama 3.2 vision European Union clause; the launcher dialog; receipts |
| D9 | Background prefetch | Off. Opt-in by a file flag, throttled, unmetered-only, idle I/O class | Whether any shipped image enables it |
| D10 | `serve-cache` (LAN) | Deferred to phase 4. If built: static, read-only `GET /blobs/sha256-<hex>`, bound to one interface address, off by default, per-IP rate limit | It needs the pairing-code authentication from the hotspot work; redistribution terms apply to anyone who can fetch |
| D11 | Concurrency | One stream (`--concurrency 1`, a USB flash translation layer dislikes several write streams), up to 16 on request. The design wanted four on a non-removable cache; nothing detects removable media yet | Unmeasured: only a single-stream 24.8 MB/s figure exists |

Also open and owned elsewhere: **audit D5** (Ollama in a Stick live session: with it off, the 73 GiB cache serves installed machines only), the exFAT write path for populating
`CI-CACHE` from a host without root (mtools cannot write exFAT), and the Hub catalog contract that would let the YAML be generated.

## 12. Work packages and status

Effort: S up to a day, M two to four days, L five to eight.

| # | Package | Effort | State |
|---|---|---|---|
| WP1 | Protocol clients and lock (`registry/`, `lockfile.rs`, `net.rs`, `cmd_models.rs`, `ureq` dependency, `.cargo/config.toml`) | L | Ollama half implemented; Hugging Face half not built; the lock file is committed (`89f7b27`) |
| WP2 | Cache store and fetch engine (`cache/`, `fetch/`, `events.rs`; `plan`, `fetch`, `cache-info`) | L | implemented for Ollama references |
| WP3 | `verify`, `gc`, `export`, `import`, licence gating | M | not built; the licence table exists (WP4) |
| WP4 | Schema tie and catalog (this document's owner) | M | **done** |
| WP5 | Hugging Face view and consumer environment | S-M | the view is built in the shell adapter (WP6), not in `ci-stick` |
| WP6 | OS adapter, units, hardware gate (`core/lib/ci-os-models.sh`, `gpu-detect.sh`, backend payloads) | M | implemented and tested on fixtures (`df4ed3f`); never run on a booted image |
| WP7 | Binary distribution into the images | M | not built |
| WP8 | Progress contract and portal glue (`status.json` writer is in WP2; optional socket; portal side belongs to the hotspot work) | S-M | status file implemented; socket not built |
| WP9 | This document and the edits to companion-stick.md, model-packs-128gb.md, tier-b-tools.md | S | **done** (`8a1763a`); re-read and updated 2026-10-18 |

Phases. **Phase 1** (shippable alone): Ollama half of WP1 and WP2, and WP4: `models lock` fills digests, `models fetch` seeds a store that a real daemon lists, a drift check; the code
for this exists and the lock is committed; what remains is running the daemon check against a seeded store. **Phase 2:** Hugging Face single-file GGUF in WP1 and WP2, WP3, WP5, WP6, WP7. **Phase 3:**
schema version 2 (non-GGUF consumers), sharded GGUF, WP8's socket, the hardware gate on every provisioner. **Phase 4:** `serve-cache`, the ext4-cache variant, mirror support.

## 13. Registry and filesystem facts the design relies on

Measured on 2026-10-17 unless noted.

- **Ollama registry.** `GET /v2/` is 404 and there is no `/tags/list`; manifests are anonymous. `HEAD` adds `ollama-content-digest` (no `sha256:`
  prefix) and `ollama-push-time`; the `GET` has no digest header. Blob `GET`s answer `307` to a presigned Cloudflare R2 URL valid for 24 hours that
  supports `Range`; `HEAD` on the presigned URL is 403 (the signature covers the method), so size comes from `HEAD` on the registry blob URL. The model
  layer starts with the bytes `GGUF`. Config blobs carry `requires` (for example `0.30.0` for `qwen3.6:27b`, `0.30.9` for `gemma4:e4b`), enforced at pull
  time by Ollama.
- **Ollama store (v0.40.6).** Blob files are `sha256-<64 hex>`; a pull writes the manifest verbatim; partials are `<blob>-partial` with journal files;
  `OLLAMA_NOPRUNE` also suppresses removal of layers replaced by a re-pull; the delete-model path never consults it. Ollama honours `HTTPS_PROXY` only.
- **Hugging Face.** `GET /api/models/<repo>?blobs=true` gives `sha`, `gated`, `cardData.license` (may be absent), `gguf{...}` and `siblings[]` with
  `lfs.sha256`. `resolve/<commit>/<file>` answers `302` with `x-linked-etag` (the sha256), `x-repo-commit` and a CDN URL valid for 3600 s whose `etag`
  is a Xet hash, not the sha256; a plain ranged `GET` works. Unauthenticated limits: 500 API calls and 3000 `resolve` calls per 300 s. A gated repo's
  metadata is public but `resolve` is `401 GatedRepo`; a private or missing repo is also 401, told apart by `x-error-code`. `https://hf.co/v2/...` redirects
  to `huggingface.co`. A sharded GGUF's Ollama manifest request answers `400`.
- **exFAT.** (Read from Linux v6.8 sources, the 24.04 GA kernel. Ubuntu 26.04 ships kernel 7.0 (`7.0.0-30` on the 26.04.1 ISO, `7.0.0-38` in `-updates`); `fs/exfat` of 7.0 was **not** re-read [N].) No symlinks, no hard links. Permissions come from mount options and `chmod` is silently ignored. Case-insensitive, case-preserving; names up to
  255 UTF-16 units; 128 KiB clusters above 32 GiB with `mkfs.exfat`. No 4 GiB file limit (inherited, not tested on a real write). Linux does not fsck an
  unclean unplug.

## 14. Open items

Each says what is open and what closes it. Numbering is this document's own.

1. **Disk-space guard for model pulls** [N]. The model set of a provisioned machine (`appliance-core`: `nomic-embed-text` 0.27 GB, `gemma3:1b` 0.81 GB, `qwen3.6:27b` 17.8 GB, 18.85 GB in all)
   took the 30 GiB target of the CachyOS ISO #4 run from 7.8 GiB (27 %) to 26 GiB (88 %) used, with 3.7 GiB left; a smaller disk would fail a pull for lack of space. Neither the shared gate
   (`ci_os_model_fits`, RAM and GPU memory only) nor the Arch script checks free space, and `ollama pull` does not refuse early. The right place is `ci_os_model_gate_allows` in
   `core/lib/gpu-detect.sh`, which the Ubuntu provisioner, the Arch engine and the CachyOS wrapper all call: skip a model when the free space of the model directory is below its `size_bytes` plus a
   margin, and have the CachyOS wrapper not count a skipped model as missing (it already does this for a model the RAM/GPU gate refuses). It cannot be done in the CachyOS wrapper alone without editing
   `backends/arch/**` (decision D8). Close with: the guard, a table test beside `backends/ubuntu/chroot/tests/models-gate.sh`, and one provisioning run on a small disk image.
2. **Hugging Face half** of `lock`, `fetch` and `view` in `ci-stick` [N]; the OS adapter builds the symlink view in shell from a lock that has no Hugging Face entry yet.
3. **`models verify`, `gc`, `export`, `import`** [N].
4. **Licence gating in `fetch`** [N]: it asks for acceptance only when the licence string is `unverified`; Gemma and Llama terms (`gate: accept` in `licenses.yaml`) are not asked for. Legal review of those terms is also open.
5. **Ollama 0.40.x reading a legacy-only seeded store, and writing to a real exFAT volume** [N]: proven on 0.33.3 on APFS only.
6. **`ci-stick` inside the images** (WP7) [N]: no backend ships it, so on an image the adapter falls back to `ollama pull` for Ollama references and refuses Hugging Face ones.
7. **Rust 1.75 compile** [N] (section 1).
8. **Hot-plug of `CI-CACHE`** [N]: Ollama picks the volume at start.
9. **Ollama in a Stick live boot** (audit D5): see section 10.

## Not verified

- Nothing was executed against a real exFAT volume or a real Ollama 0.40.x daemon. Daemon-free seeding was proven on Ollama 0.33.3 on APFS on 2026-10-13
  (model-packs-128gb.md, 5.4).
- Whether Ollama loads a hand-written manifest with several consecutive `image.model` layers (sharded GGUF).
- `Vary: User-Agent` on the Ollama registry: two user agents gave identical bodies.
- Throughput of the sticks: only one single-stream figure (24.8 MB/s) exists; USB write speed and SLC-cache behaviour are unmeasured.
- Hugging Face behaviour with a token; `Link`-header pagination for large trees; llama.cpp's command-line spelling of its offline switch.
- Licences were read as the first lines of each licence layer plus keyword searches. That is not legal review.

## Where things are

| What | File |
|---|---|
| Pack catalog | `core/manifest/model-packs.yaml` |
| Licence table | `core/manifest/licenses.yaml` |
| Lock (generated, committed in `89f7b27`) | `core/manifest/model-packs.lock.json` |
| Catalog, lock reader, drift, licence table, release gate | `stick/crates/ci-stick/src/packs.rs` |
| `Model`, reference grammar, `ModelSource` | `stick/crates/ci-stick/src/manifest.rs` |
| Bundle schema and examples | `stick/schema/bundle.schema.json`, `stick/schema/examples/` |
| Schema validator and mutation tests | `stick/crates/ci-stick/tests/schema.rs`, `tests/support/minischema.rs` |
| `models list` on the real and on broken catalogs | `stick/crates/ci-stick/tests/packs_catalog.rs` |
| Lock format and writer | `stick/crates/ci-stick/src/lockfile.rs` |
| `models plan`, `lock`, `fetch`, `cache-info` | `stick/crates/ci-stick/src/cmd_models.rs`, `fetch/`, `registry/`, `cache/`, `events.rs` |
| HTTP transport and redirect policy | `stick/crates/ci-stick/src/net.rs` |
| Tests of the download code and golden manifests | `stick/crates/ci-stick/tests/models_*.rs`, `tests/models_support/`, `tests/fixtures/models/` |
| OS adapter, hardware gate, view, prefetch (`df4ed3f`) | `core/lib/ci-os-models.sh`, `core/lib/gpu-detect.sh`, `backends/ubuntu/chroot/payload/models/`, tests in `backends/ubuntu/chroot/tests/models-*.sh` |
