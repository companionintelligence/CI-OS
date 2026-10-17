# Model packs for 128 GB Companion Sticks

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Status: **implemented** as the packs `stick-128` and `stick-128-oci` in `core/manifest/model-packs.yaml`, and pinned by the test `stick_128_packs_fit_the_real_128gb_stick_with_headroom` in `stick/crates/ci-stick/src/packs.rs`. The daemon-free fetch that populates `CI-CACHE` (called `ci-stick models sync` in the first draft of this review) is now `ci-stick models fetch`; its design and what exists are in [models-tooling.md](models-tooling.md). Sizes were read from the Ollama registry on 2026-10-13; see the drift note below.

## 1. Result in one table

All sizes are the exact sum of `config.size + sum(layers.size)` from `https://registry.ollama.ai/v2/library/<name>/manifests/<tag>`, fetched 2026-10-13.

| Variant | Models | Sum of `size_bytes` | On-disk exFAT footprint (128 KiB clusters, see 5.4) | Free of 78,383,153,152 B | Verdict |
|---|--:|--:|--:|---|---|
| **A, `stick-128`** | 21 | 74,359,550,640 | 74,393,583,616 (69.28 GiB) | 3.72 GiB (**5.09 %**) | passes the 3 % rule. Leaves only ~3.7 GiB for OCI and tmp, so it is a models-only layout |
| **B, `stick-128-oci`** | 19 (A minus `gpt-oss:20b` and `qwen3.5:0.8b`) | 59,244,039,797 | 59,275,870,208 (55.2 GiB) | 17.80 GiB; **2.80 GiB (3.83 %) left after reserving 15 GiB for OCI** | passes the 3 % rule with the 15 GiB OCI reserve |

- `ci-stick layout plan --size 123942731776` gives a 73 GiB cache (78,383,153,152 B). I reproduced it in a scratch copy.
- `ci-stick models list --device 123942731776` shows `stick-128 74.4 GB yes` and `stick-128-oci 59.2 GB yes`.
- Per-file cluster rounding is negligible (8.96 MB over 85 blob files for A). Seven or fewer files dominate the size.
- Only 3 of the 21 models are required by `core/manifest/ecosystem.yaml:84`: `nomic-embed-text`, `gemma3:1b`, `qwen3.6:27b`. They are ranks 1-3.

**Drift since 2026-10-13.** Registry tags are mutable, and one already moved. On 2026-10-17 a re-fetch of all 21 `stick-128` manifests matched the sizes in this section to the byte for 20 models; `glm-ocr:latest` had been re-pushed on 2026-10-14T15:27:10Z and grew from 2,219,299,168 to 2,655,025,740 bytes (+435,726,572, +19.6 %; it now has four layers, including an 869,018,176 B projector). With that figure `stick-128` is 74,795,277,212 bytes and leaves 3.34 GiB of the 73 GiB cache instead of 3.72 GiB; `stick-128-oci` is 59,679,766,369 bytes and leaves 2.42 GiB (3.3 %) after the 15 GiB OCI reserve. Both still pass the 3 % rule, but the tables in sections 1 and 4.2 are the 2026-10-13 snapshot. The catalog test that read only the YAML could not see this; once `core/manifest/model-packs.lock.json` exists, `catalog_sizes_match_the_lock_when_it_exists` fails on any difference of even one byte ([models-tooling.md](models-tooling.md), section 4.3). The sizes of the other models in the catalog (`starter` to `large`) were last read on 2026-10-13 and have not been re-checked.

## 2. What the repo requires (read first)

- `core/manifest/model-packs.yaml:16-17`: `size_bytes` is the approximate download size of the default quantization, decimal bytes, "exact when the digest is resolved".
- `model-packs.yaml:21-22`: every `llm.models` entry must appear in some pack. `stick/crates/ci-stick/src/packs.rs:237` enforces `nomic-embed-text:latest`, `gemma3:1b`, `qwen3.6:27b`. `packs.rs:231-235` enforces `digest == null`.
- `packs.rs:228` asserts the pack **names are exactly** `["starter","balanced","coding","vision","large"]`. Adding packs fails that test until it is updated.
- `packs.rs:246-248` asserts that the unique total of all packs fits the 512 GB layout's cache (304 GiB).
- `manifest.rs:394-448` (`validate_packs`) rejects duplicate refs within a pack, `size_bytes == 0`, empty platforms and firmware platforms.
- `packs.rs:110`: `fits = size <= capacity`, raw bytes only. It has no exFAT overhead and no headroom.
- `lock.rs:269-276` and `main.rs:496-497`: `lock --packs <catalog>` records the whole catalog (every pack) into `bundle.json`, and warns if the union exceeds the cache. There is no per-pack selector.
- `docs/architecture/companion-stick.md:68` says "128 GB -> 77 GiB cache". That is for a stick of exactly 128e9 B. The user's sticks are 123,942,731,776 B and get 73 GiB. `ci-stick models list --device 128GB` over-reports capacity by 4 GiB for these sticks.
- `stick/schema/examples/bundle.example.json:68` already uses `models/blobs/sha256-<hex>`, so the bundle layout equals an Ollama `OLLAMA_MODELS` root.

**Validation.** I appended the proposed YAML to a scratch copy of the catalog and ran the real parser (`serde_yaml 0.9`) with `cargo test --offline` in a scratch copy of `stick/`. It parses, including YAML aliases to anchored model mappings. The only failure was the `packs.rs:228` names assertion, as predicted. After updating that assertion in the scratch copy, all tests pass (83 lib tests plus the integration tests). All digests are `null`.

## 3. Registry facts (primary source, 2026-10-13)

- `https://ollama.com/library` lists **248 families**. I parsed the page. Newest and most active: `gemma4` (updated 20 hours ago), `qwen3.5` (24 minutes ago), `qwen3.6`, `qwen3.8` (2 weeks), `ornith-1.5`, `nemotron-3.5-lightning`, `laguna-xs-2.1`, `embeddinggemma-2`.
- **Tags are mutable.** `qwen3.5` was updated minutes before the fetch, and `qwen3.6:27b-q8_0` hours before. Treat `size_bytes` as a snapshot. `ci-stick models lock` must pin the manifest digest. The 3.7 GiB headroom in A covers about 5 % drift.
- **`qwen3.6:27b` exists.** It is 17,769,076,933 B in 4 layers plus config:
 - model layer 16,837,919,680 B (`application/vnd.ollama.image.model`, Q4_K_M, family `qwen35`, "27.3B")
 - projector layer 931,145,568 B (`...image.projector`, so it is multimodal)
 - license layer 11,357 B (Apache-2.0 text, digest `sha256:5f3a3c817e78...`)
 - params layer 114 B
 - config 214 B
 - It carries `"runner":"llamacpp","format":"gguf"` and `requires 0.30.0`.
 - `model-packs.yaml:112` lists it as `license: unverified, size_bytes: 17000000000`. That `unverified` blocks a release per `companion-stick.md` ("any entry marked `unverified` blocks a release"). It can now be set to `Apache-2.0` (registry license layer) and `17769076933`.
 - `qwen3.6:latest` is **not** 27b. It is `35b-a3b`, 22,621,314,381 B.
- Manifest media type: `application/vnd.docker.distribution.manifest.v2+json`. Config media type: `application/vnd.docker.container.image.v1+json`. The config blob is JSON, e.g. `{"model_format":"gguf","model_family":"qwen35","model_type":"27.3B","file_type":"Q4_K_M","requires":"0.30.0",...}`.
- Layer media types seen: `application/vnd.ollama.image.model`, `.projector`, `.draft` (speculative-decode drafter, gemma4 and qwen3.5:0.8b), `.license`, `.params`, `.template`, `.system`. Newer embedding models have only `model` (no license layer).
- **Trap: `:cloud` tags.** e.g. `gemma4:cloud`, `gpt-oss:120b-cloud` have 300-400 B manifests and no weights. Families like `kimi-k3`, `glm-5.3-flash`, `mistral-large-4` have only `:cloud` tags. Never put them in a pack.
- **Trap: non-GGUF `tensor` models.** `embeddinggemma-2` has layers `json,tensor` (nvfp4). I excluded these, because the llama.cpp runner path is not established.
- The 12-hex ID shown by `ollama list` and on tag pages is the first 12 hex digits of the sha256 of the manifest bytes. Evidence: `gemma3:270m` shows `e7d36fb2c3b3` on `ollama list` and the tag page; the manifest sha256 of `nomic-embed-text:latest` is `0a109f422b47e3a3...`, identical for the registry response (708 B) and `~/.ollama/models/manifests/registry.ollama.ai/library/nomic-embed-text/latest`. This gives two independent sources for the manifest-digest definition. I did not write any digest into the YAML.
- Download throughput from this host, one sample: 200 MiB range of the qwen3.6:27b blob in 8.46 s, 24.8 MB/s. About 50 min to fetch 74.4 GB. Blob GETs return a 307 to a Cloudflare R2 pre-signed URL (24 h) and support `Range` (206 observed). HEAD on the registry blob URL returns 200 with `content-length` directly.

Exact sizes for **all 21 models currently in the repo catalog** were also fetched (all tags exist). Largest drift from the listed approximations: `qwen3.6:27b` +0.77 GB, `llama3.3:70b` -0.48 GB, `qwen3-coder:30b` -0.44 GB, `gemma3:27b` +0.41 GB, `gpt-oss:120b` +0.37 GB, `devstral:24b` +0.33 GB. The listed unique total is 283,889,000,000 B and the exact total is 284,812,025,956 B.

## 4. Candidates, ranking and licences

### 4.1 Selected pack, ranked (the YAML order is the rank order)

Columns: bytes = config + layers. "Req. Ollama" is the `requires` field of the config blob. It matters for the offline Ollama binary shipped on the stick: the maximum across the pack is **0.30.9** (gemma4), and `glm-ocr` needs 0.15.5.

| # | Model | Role | Quant | Bytes | Licence (source) | Req. Ollama |
|--|--|--|--|--:|--|--|
| 1 | `nomic-embed-text:latest` | embedding (required) | F16 | 274,302,450 | Apache-2.0 (license layer) | - |
| 2 | `gemma3:1b` | tiny chat (required) | Q4_K_M | 806,067,407 | Gemma Terms of Use (layer) | 0.30.0 |
| 3 | `qwen3.6:27b` | flagship general + vision + agentic coding (required, large #1) | Q4_K_M | 17,769,076,933 | Apache-2.0 (layer) | 0.30.0 |
| 4 | `qwen3.5:9b` | general, vision, tools, thinking | Q4_K_M | 6,550,825,550 | Apache-2.0 (layer) | 0.30.0 |
| 5 | `gemma4:e4b` | general, vision, audio, tools, thinking | Q4_K_M | 6,583,656,505 | Apache-2.0 (layer **and** HF `google/gemma-4-E4B-it` tag) | 0.30.9 |
| 6 | `qwen3.5:4b` | 8 GB-machine default | Q4_K_M | 3,324,173,934 | Apache-2.0 (layer) | 0.30.0 |
| 7 | `qwen2.5-coder:7b` | coding | Q4_K_M | 4,683,087,561 | Apache-2.0 (layer) | - |
| 8 | `qwen3-vl:8b` | vision, documents, screenshots | Q4_K_M | 6,140,415,879 | Apache-2.0 (layer) | - |
| 9 | `bge-m3:latest` | multilingual embedding | F16 | 1,157,672,605 | MIT (layer; HF `BAAI/bge-m3` = mit) | - |
| 10 | `mxbai-embed-large:latest` | English embedding | F16 | 669,615,493 | Apache-2.0 (layer; HF = apache-2.0) | - |
| 11 | `qwen3-embedding:0.6b` | multilingual embedding | Q8_0 | 639,150,858 | Apache-2.0 (HF `Qwen/Qwen3-Embedding-0.6B` only; no license layer) | - |
| 12 | `glm-ocr:latest` | OCR for Capture | F16 | 2,219,299,168 | MIT (HF `zai-org/GLM-OCR` only; no license layer) | 0.15.5 |
| 13 | `granite4.1:3b` | small tool-calling model | Q4_K_M | 2,099,520,281 | Apache-2.0 (layer) | - |
| 14 | `llama3.2:3b` | Meta-family small chat | Q4_K_M | 2,019,393,189 | Llama 3.2 Community License (layer: has "Built with Llama" and 700 million MAU clauses) | - |
| 15 | `qwen3.5:2b` | 2B vision + tools | Q8_0 | 2,683,396,812 | Apache-2.0 (layer) | 0.30.0 |
| 16 | `qwen2.5-coder:1.5b` | code autocomplete / FIM | Q4_K_M | 986,062,089 | Apache-2.0 (layer) | - |
| 17 | `functiongemma:270m` | function-call router | Q8_0 | 300,807,157 | Gemma Terms of Use (layer) | - |
| 18 | `gemma3:270m` | smallest chat | Q8_0 | 291,554,930 | Gemma Terms of Use (layer) | - |
| 19 | `all-minilm:latest` | 46 MB embedding | F16 | 45,960,996 | Apache-2.0 (layer) | - |
| 20 | `gpt-oss:20b` | **large #2**, reasoning + tools, 16 GB RAM | MXFP4 | 13,793,441,566 | Apache-2.0 (layer) | 0.30.0 |
| 21 | `qwen3.5:0.8b` | smallest vision + tools | Q8_0 | 1,322,069,277 | Apache-2.0 (layer) | 0.30.0 |

Why this mix:
- Embeddings: 5 models. English-only, multilingual, tiny, and instruction-aware are covered. All are Apache or MIT.
- Tiny and fast: ranks 2, 14-18, 21.
- General chat: Qwen, Gemma 4 and Llama families.
- Coding: a 7B chat model plus a 1.5B FIM model. `qwen3.6:27b` already advertises agentic coding.
- Vision: `qwen3-vl:8b`, plus `glm-ocr` for documents. `qwen3.5` and `gemma4` are natively multimodal, so no separate `llava`-class models are needed.
- Reasoning and tools: `gpt-oss:20b`, plus the `thinking` and `tools` capabilities of Qwen 3.5/3.6 and Gemma 4. `functiongemma` and `granite4.1:3b` cover tool routing.
- Multilingual: `bge-m3`, `qwen3-embedding`, `qwen3.5`, `gemma4`.
- Large: `qwen3.6:27b` (required) and `gpt-oss:20b`. A 70B or 80B class model would take 56-66 % of the cache, see 4.3.

### 4.2 Cumulative totals (A grows left to right; B is the prefix of 19)

| # | Added | Cumulative `size_bytes` | Cumulative on-disk exFAT | Free of 73 GiB |
|--|--|--:|--:|--:|
| 1 | nomic-embed-text | 274,302,450 | 285,474,816 | 72.73 GiB (99.6 %) |
| 3 | + qwen3.6:27b | 18,849,446,790 | 18,863,357,952 | 55.43 GiB (75.9 %) |
| 7 | + qwen2.5-coder:7b | 39,991,190,340 | 40,010,121,216 | 35.74 GiB (49.0 %) |
| 12 | + glm-ocr | 50,817,344,343 | 50,841,649,152 | 25.65 GiB (35.1 %) |
| 16 | + qwen2.5-coder:1.5b | 58,605,716,714 | 58,634,141,696 | 18.39 GiB (25.2 %) |
| 19 | + all-minilm (**= B**) | 59,244,039,797 | 59,275,870,208 | 17.80 GiB (24.4 %); 2.80 GiB (3.83 %) after a 15 GiB OCI reserve |
| 20 | + gpt-oss:20b | 73,037,481,363 | 73,070,673,920 | 4.95 GiB (6.8 %) |
| 21 | + qwen3.5:0.8b (**= A**) | 74,359,550,640 | 74,393,583,616 | 3.72 GiB (5.09 %) |

The full 21-row table follows from the sizes in `model-packs.yaml` and the footprint model in section 5.2.

### 4.3 Alternatives (swap menu), all computed with the same footprint model, 3 % rule = on-disk <= 76,031,658,557 B

| Variant | Models | On-disk | Free | Result |
|---|--:|--:|--:|---|
| S1: A minus `gpt-oss:20b`, plus `gemma4:12b`, `phi4-mini-reasoning:3.8b` (MIT), `translategemma:4b` (Gemma ToU) | **23** | 75,075,158,016 | 4.22 % | OK. This is the "max model count" option |
| S3: A minus `gpt-oss:20b`, plus `mistral-small3.2:24b` (Apache, vision, tools) | 21 | 75,777,703,936 | 3.32 % | OK, tight |
| S5: A minus `gpt-oss:20b`, plus `gemma4:26b` | 21 | 79,330,803,712 | -1.21 % | does not fit |
| S6: A minus `gpt-oss:20b` and `qwen3.5:0.8b`, plus `qwen3-coder:30b` | 20 | 77,833,830,400 | 0.70 % | does not fit |
| S7: S6 and also minus `qwen3-vl:8b` | 19 | 71,692,320,768 | 8.54 % | OK |
| XL: `nomic`, `gemma3:1b`, `qwen3.6:27b`, `qwen3-next:80b` (50.35 GB, Apache), `qwen3.5:4b`, `bge-m3` | 6 | 73,700,605,952 | 5.97 % | fits, but 6 models only |
| XL2: same with `llama3.3:70b` (42.52 GB, Llama 3.3 licence) | 7 | 72,421,343,232 | 7.61 % | fits, but few models |
| `gpt-oss:120b` (65.37 GB) + `nomic` + `gemma3:1b` | 3 | 66,464,120,832 | 15.2 % | fits, 3 models |

I chose A over S1 because the request asked for "1-2 large models". Switching to S1 is a one-line decision for the owner (see open questions).

### 4.4 Considered and rejected

| Candidate | Exact bytes | Reason |
|---|--:|---|
| `qwen2.5-coder:3b`, `smallthinker:3b` | 1.93 GB, 3.62 GB | licence layer is the **Qwen Research License** (contains "Non-Commercial"). The 0.5b/1.5b/7b/14b/32b siblings are Apache |
| `aya-expanse`, `command-r7b` | 5.06 GB | CC-BY-NC (layer text) |
| `exaone-deep` | 1.64-19.3 GB | "EXAONE AI Model License Agreement 1.1 - NC" (layer title) |
| `lfm2`, `lfm2.5`, `lfm2.5-thinking` | 0.73-14.4 GB | LFM Open License v1.0 contains "Non-Commercial"/"research purposes" and a $10,000,000 revenue Threshold |
| `minicpm-v:8b` | 5.47 GB | licence text: commercial use only after a registration questionnaire. `minicpm-v4.5/4.6` have no licence layer |
| `medgemma` | 3.34 GB | "Health AI Developer Foundations Terms of Use" |
| `nemotron-3-nano:4b/30b`, `nemotron-3.5-lightning` | 2.84-25.4 GB | NVIDIA Open Model License Agreement. Redistribution terms need legal review |
| `llama3.2-vision:11b` (**currently in the `vision` pack**) | 7.82 GB | licence layer contains an "European Union" clause. Flag before bundling |
| `starcoder2` | 1.7-9.1 GB | BigCode OpenRAIL-M |
| `deepseek-coder-v2` | 8.9 GB | DeepSeek licence (use-restriction terms) |
| `embeddinggemma:300m` | 622 MB | Gemma ToU. Apache alternatives exist |
| `embeddinggemma-2` | 0.38-1.3 GB | non-GGUF `json,tensor` layers (nvfp4) |
| `snowflake-arctic-embed2:568m` | 1.16 GB | duplicates `bge-m3`. Licence is Apache-2.0 only per HF `Snowflake/snowflake-arctic-embed-l-v2.0` |
| `devstral-small-2:24b` | 15.18 GB | HF `Devstral-Small-2-24B-Instruct-2512` = apache-2.0, but no license layer. Does not fit alongside `qwen3.6:27b` and `gpt-oss:20b` |
| `qwen3-coder:30b` | 18.56 GB | Apache, fits only by dropping `qwen3-vl:8b`, `gpt-oss`, `qwen3.5:0.8b` (S7). Covered by `qwen3.6:27b` and `qwen2.5-coder:7b` |
| `north-mini-code-1.0` | 18.59 GB | Apache license layer; newer coder with the same fit problem |
| `gemma4:26b/31b`, `qwen3.6:35b`, `qwen3.8:27b` (needs Ollama 0.32.12), `mistral-small3.2:24b`, `glm-4.7-flash` (19.02 GB, MIT) | 15-22.6 GB | each costs 20-30 % of the cache |
| `kimi-k3`, `glm-5.3-flash`, `mistral-large-4` | ~300 B | cloud-only tags, no weights |
| `laguna-xs-2.1` | 20.27 GB | OpenMDW licence, needs review |

### 4.5 Licence handling

Every licence is the Ollama registry licence-layer text unless stated. I read only the first lines and searched for keywords in the non-Apache/MIT ones. This is **not legal review**.

- Apache-2.0 or MIT: 17 of 21 models. These are safe to redistribute with the licence text. The licence layer travels in the blob store.
- **Gemma Terms of Use**: `gemma3:1b`, `gemma3:270m`, `functiongemma:270m`. The layer contains a "Prohibited Use" section. Redistribution is permitted with notices and flow-down, so the launcher must show the licence before import (`companion-stick.md` policy). Gemma 4 is Apache-2.0 per both its license layer and the HF tags, so Gemma 4 avoids this.
- **Llama 3.2 Community License**: `llama3.2:3b`. Requires "Built with Llama" attribution and has a 700M MAU clause. It has no EU clause (that is only in the vision variant).
- Gated or click-through: none selected. HF `google/gemma-3-4b-it` is `gated: manual`, but the Ollama blob is public and carries the Gemma terms.

### 4.6 `min_ram_gb`, `min_vram_gb`, platforms

- Existing catalog values are kept where the model already existed.
- For new models I used `1.5 x size_GB + 2`, rounded up to {2, 4, 8, 16, 24, 32, 48, 64}. This reproduces most of the existing entries. It is a heuristic, not a benchmark.
- `min_vram_gb`: null except dense models of 27B or more. The catalog uses 24 for `qwen3.6:27b`.
- Platforms follow the file's convention. `*all` for models up to about 10 GB. `*large` (no Intel Mac) for 13 GB and above: `qwen3.6:27b`, `gpt-oss:20b`.

## 5. Ollama model store on a removable exFAT volume

### 5.1 On-disk format (observed, not recalled)

Evidence: the real store at `~/.ollama/models` (Ollama 0.33.3 client, 183 GB, 3357 blobs), and the Ollama source.

```
$OLLAMA_MODELS/
 blobs/sha256-<64 lowercase hex> # config, model, projector, license, params, template ... (raw bytes)
 manifests/registry.ollama.ai/library/<model>/<tag> # the registry manifest JSON, byte-identical, no extension
 metadata/sha256-<hex>.json # newer builds only: GGUF header cache, regenerable (UNVERIFIED how it is used)
```

- The blob filename is `sha256-` + hex, with a hyphen not a colon. `manifest/manifest.go` defines `blobFilenamePattern = ^sha256-[0-9a-fA-F]{64}$`, and `BlobsPath` replaces ":" with "-".
- The manifest file in the store is **byte-identical** to the registry response: 708 B, sha256 `0a109f422b47...` in both places for `nomic-embed-text:latest`.
- `OLLAMA_MODELS` is read in `envconfig/config.go:113-114` and documented in `docs/faq.mdx` ("set the environment variable `OLLAMA_MODELS`").
- **Newer releases add `manifests-v2/`.** The source for v0.40.0 and v0.40.3 contains it (`manifest/paths.go`), while v0.33.3, v0.34.4 and v0.35.1 do not. v0.40.3 is the latest stable release (published 2026-10-11 per the GitHub API). In v0.40.3, `resolveManifestPath` checks `manifests-v2/ollama.com/library/<m>/<tag>` first and **falls back to the legacy `manifests/registry.ollama.ai/...` file**. Regular-file legacy manifests are "opened without mutating the local store" (`OpenVerifiedManifest` comment). So a legacy-layout seed is readable by 0.33.x (tested) and by 0.40.x (by reading the source; UNVERIFIED by execution).

### 5.2 Is exFAT workable? (source-level)

- **No symlinks.** The v2 writer `linkManifest` calls `os.Symlink` and, when that fails, `copyManifestFile`. exFAT therefore degrades to copies. No code path requires symlinks.
- **No POSIX permissions.** Ollama calls `os.Chmod(tmp, 0o644)` after writes. Linux kernel v6.8 `fs/exfat/file.c:335-342` says "We don't return -EPERM here" and silently drops an invalid mode change. chown to a uid other than the mount's `uid=` returns EPERM (`file.c:325-333`). Ollama does not chown. v6.8 is the Ubuntu 24.04 GA kernel. So mount with `uid=`/`gid=` of the `ollama` user plus `fmask=0133,dmask=0022`.
- **Case-insensitive, case-preserving.** Registry names and tags are lowercase here, and hashes are lowercase hex. Ollama also does case-insensitive name matching (`FindName`). Do not seed two tags that differ only by case.
- **Name limits.** exFAT allows 255 UTF-16 characters per name; `sha256-` + 64 hex is 71. Illegal characters (`: * ? " < > |`) do not occur in these tags.
- **File size.** exFAT has no 4 GiB limit; the largest blob here is about 16.84 GB. UNVERIFIED by a write test on a real volume (see 7).
- **Clusters.** `exfatprogs` `mkfs.exfat` picks 128 KiB clusters for any volume over 32 GiB (`lib/libexfat.c:198-208`). `flash.rs:709-714` uses `mkfs.exfat`, so a 73 GiB `CI-CACHE` gets 128 KiB. The macOS `newfs_exfat` default was not determined.
- **Footprint model** (the footprint model): every distinct blob digest is one file rounded up to 128 KiB; each manifest counts 3 clusters (legacy, v2 copy, manifest blob); directories cost 2 trees of clusters; one `metadata/` file per model; plus an 8 MiB allowance for FAT (about 2.3 MiB for 599,040 clusters), bitmap, upcase table and boot regions. Distinct blobs are deduplicated. For A: 85 blob files, 74,359,457,979 B unique, 74,368,417,792 B after rounding, 16.8 MB for manifests, directories and metadata.
- **macOS population hazards.** AppleDouble `._*` files in `manifests/` would be parsed as manifests named `._latest` (invalid manifests are ignored with a warning, but they are noise). Use `COPYFILE_DISABLE=1` and `dot_clean`, and exclude `.fseventsd`, `.Spotlight-V100` and `.Trashes`.

### 5.3 Pruning risk, important

`server/routes.go:2388-2394` (v0.40.3): on startup, unless `OLLAMA_NOPRUNE` is set, Ollama runs `PruneLayers`. It deletes every file in `blobs/` older than 1 hour (`layerPruneGracePeriod`, `images.go:42`) that no manifest references, and deletes files in `blobs/` whose names are not valid digests (for example partial downloads). If any manifest is corrupt it skips pruning with a warning. Consequences for the stick:

- Never put non-Ollama files in `<cache>/models/blobs/`. Keep OCI under `oci/`.
- A half-seeded store that is opened by a daemon loses its orphan blobs.
- For a stick used directly by a booted daemon, set `OLLAMA_NOPRUNE=1` and `OLLAMA_MODELS=<CI-CACHE mount>/models`. This matches `bundle.example.json`, which uses `models/blobs/...`.

### 5.4 Daemon-free pre-seeding, tested

A prototype (not committed) implemented this and ran against the public registry; `ci-stick models fetch` ([models-tooling.md](models-tooling.md)) is the committed version of the same procedure, with a lock that pins the manifest bytes:

1. `GET https://registry.ollama.ai/v2/library/<name>/manifests/<tag>` with `Accept: application/vnd.docker.distribution.manifest.v2+json`. Keep the raw bytes.
2. For `config` and each `layers[]` entry, `GET /v2/library/<name>/blobs/sha256:<hex>` (follows the 307 to R2; use `Range` to resume). Stream to `blobs/sha256-<hex>.partial`, check byte length equals `size` and sha256 equals `<hex>`, then rename to `blobs/sha256-<hex>`.
3. Only after all blobs verify, write the manifest bytes verbatim to `manifests/registry.ollama.ai/library/<name>/<tag>` (temp file, then rename).
4. Skip any manifest with `layers == null` or a `:cloud` tag.
5. Dedupe by digest. The shared Apache license blob appears under several models, and storing it once is what the footprint model assumes.

**Test result.** I seeded `all-minilm:latest`, `nomic-embed-text:latest` and `gemma3:270m` (12 blob files) into a scratch directory and started a throwaway `OLLAMA_MODELS=<scratch> OLLAMA_HOST=127.0.0.1:11987 OLLAMA_NOPRUNE=1 ollama serve` (version 0.33.3). `ollama list` listed all three with the correct IDs. `/api/embed` returned an embedding and `/api/chat` returned a reply. The daemon created no extra files in the store. This proves the layout for 0.33.3 on APFS. It does not prove exFAT.

## 6. The catalog entries

The two packs are appended to `core/manifest/model-packs.yaml` (search for `name: stick-128`). `stick-128-oci` aliases the first pack's entries with YAML anchors (`serde_yaml` resolves them; the Hub catalog contract that will eventually generate this file must either support aliases or expand them). All digests are `null`. The existing entries in the other five packs were refreshed to the exact registry sizes at the same time, so one model ref has one size everywhere, and `qwen3.6:27b` changed from `license: unverified` to `Apache-2.0` (the registry licence layer).

A third pack, `appliance-core` (`nomic-embed-text:latest`, `gemma3:1b`, `qwen3.6:27b`, 18,849,446,790 bytes), aliases the first three `stick-128` entries. It is the pack-shaped form of what `core/manifest/ecosystem.yaml` pre-pulls; a test keeps it equal to that list. Every licence in the catalog also has a row in `core/manifest/licenses.yaml`, which says which ones (Gemma, Llama) need a recorded acceptance and keeps `unverified` as the explicit release blocker.

Effects on the existing checks:
- All packs together (shared models counted once) go from 284.8 GB to **319.8 GB**. That still fits the 512 GB layout's 304 GiB (326.4 GB) cache, so the whole-catalog test still passes.
- `ci-stick models list --device 123942731776` reports `stick-128` at 74.4 GB (fits) and `stick-128-oci` at 59.2 GB (fits); `large` (159.7 GB) does not fit a 128 GB stick, as expected.
- The names assertion in `packs.rs` was extended to the seven pack names.

## 7. Risks, gaps and what could not be verified

- exFAT with Ollama was never run. The rules forbade attaching or formatting any disk, so I did not attach a disk image either. Everything in 5.2 is from kernel v6.8 and Ollama source, not an on-device test.
- v0.40.x was not executed. The legacy-manifest fallback is from the v0.40.3 source only.
- Read speed from the sticks is unknown. As arithmetic only: USB 2.0 is 480 Mb/s (60 MB/s theoretical), so mmap-loading `qwen3.6:27b` (17.77 GB) takes at least 5 min and realistically 7 min or more at about 40 MB/s. The five USB 3 sticks should be several times faster. Measure before promising anything.
- Population time: 74.4 GB per stick (74.8 GB with the current `glm-ocr`). Download once (about 50 min at the 24.8 MB/s I measured) and then copy the verified seed to each stick. Do not re-download nine times. Copy speed is limited by the sticks, and the four USB 2 sticks share cascaded hubs.
- Licences were read only as the first lines of each layer plus keyword searches. Gemma ToU flow-down and Llama attribution still need a human review before a release bundle.
