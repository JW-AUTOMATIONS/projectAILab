# Daily-driver redesign

Date: 2026-09-27. Status: design approved in chat, pending spec review.

## Goal

Turn projectAILab from a working concept into something the owner and the
people on his network want to use every day, on the one machine it was built
for (Core Ultra 9 185H, RTX 5060 Ti 16 GB, 96 GB DDR5).

The four uses, all in scope:

1. **Documents / knowledge.** Upload PDFs, notes and manuals, ask about them.
2. **Voice conversations.** Talk to it and hear replies, from a phone or laptop.
3. **Coding assistant.** IDE agents (Continue, Cline) and tab-completion using
   the local models.
4. **Web search and tools.** Answers with live web results, native tool
   calling, MCP servers.

Plain chat, including images (vision), is always included.

### Non-goals

- Other hardware. No abstraction for other GPUs or CPUs, and no machines
  without an NPU.
- Multi-tenant or client deployments: no per-customer isolation, no rebranding
  (the Open WebUI licence forbids removing its branding at 50+ users).
- Image generation. The 5060 Ti's VRAM belongs to the LLM.
- Public internet exposure. Access is the LAN plus the owner's tailnet only.

## What changes, at a glance

| Today | After |
|---|---|
| `llm-main` serves one model, fixed in `.env` | llama-server **router** with a model catalog, switched from the Open WebUI dropdown |
| `MAIN_N_CPU_MOE` / `MAIN_NGL` tuned by hand, VRAM presets in `stack.sh` | llama-server `--fit` (on by default) sizes GPU layers and CPU experts |
| Custom `npu-worker` (FastAPI, builds the NPU driver) | **OpenVINO Model Server (OVMS)**: embeddings, reranker, Whisper, Kokoro TTS |
| Web UI over plain HTTP; the microphone cannot work from other devices | **Tailscale** HTTPS front door; voice works on every device |
| Model APIs on localhost only | APIs reachable over the tailnet with an API key, for IDEs |
| No web search, no reranking, no TTS, no tab-completion | SearXNG, Qwen3 reranker, Kokoro voice, Qwen2.5-Coder-1.5B completion |
| Open WebUI on the moving `main` tag | Pinned releases, `ailab update` / `ailab rollback` |
| No backups | Daily `ailab backup` timer, 7 copies |

## Services

| Service | Image | Runs on | Job | Published on |
|---|---|---|---|---|
| `llm-main` | `ailab/llama-cuda:local` (built, CUDA sm_120) | 5060 Ti + DDR5, P-cores | router: chat, reasoning, coding, vision | `127.0.0.1:8081` |
| `llm-aux` | `ghcr.io/ggml-org/llama.cpp:server-vulkan` (pinned) | Arc iGPU, E-cores | router: task model + tab-completion | `127.0.0.1:8082` |
| `ovms-init` | `openvino/model_server:<release>-gpu` | E-cores | one-shot: pulls models, writes the OVMS config | — |
| `ovms` | same | NPU; CPU for TTS; E-cores | embeddings, rerank, STT, TTS | `127.0.0.1:8083` |
| `searxng` | `searxng/searxng:<pinned>` | E-cores | private metasearch | not published |
| `open-webui` | `ghcr.io/open-webui/open-webui:<release>` | E-cores | UI, accounts, RAG, tools | `${WEBUI_BIND_ADDR:-0.0.0.0}:3000` |
| `anythingllm` | unchanged, optional profile | E-cores | alternative UI | `:3001` |

`tailscale serve` on the host is the HTTPS front door:

| Tailnet URL | Proxies to | Who uses it |
|---|---|---|
| `https://ailab.<tailnet>.ts.net/` (443) | `127.0.0.1:3000` Open WebUI | browsers, phones |
| `https://ailab.<tailnet>.ts.net:8443/v1` | `127.0.0.1:8081` main router | IDE agents (API key) |
| `https://ailab.<tailnet>.ts.net:10000/` | `127.0.0.1:8082` aux router (`/v1`, `/infill`) | tab-completion (API key) |

The model APIs never listen on the LAN. Open WebUI stays reachable over plain
HTTP on the LAN (`WEBUI_BIND_ADDR`) for people without Tailscale: text chat
works there, the microphone does not.

## Models

### Main router (`llm-main`)

Generated `models/main.ini`, user-editable (the installer never overwrites an
edited file; see Installer):

```ini
version = 1

[*]
jinja = true
parallel = 2
# Total context, split across the slots: 2 x 32k, as today's single 32k slot.
c = 65536

[qwen3.6-35b-a3b]
hf-repo = unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M

[gpt-oss-120b]
hf-repo = ggml-org/gpt-oss-120b-GGUF:MXFP4
```

- **`qwen3.6-35b-a3b` is the default** (Open WebUI `DEFAULT_MODELS`): Qwen3.6,
  April 2026, 35B total / ~3B active, vision and tool calling. The file is
  `Qwen3.6-35B-A3B-UD-Q4_K_M.gguf` (20.6 GB) plus `mmproj-F16.gguf` (0.84 GB),
  which llama.cpp fetches automatically for vision.
- **`gpt-oss-120b`** (MXFP4, 59 GB, ~5.1B active) for hard reasoning. Loaded on
  demand. The first request after a switch waits for the load.
- Router flags: `--models-preset /models/main.ini --models-max 1`, plus
  `--sleep-idle-seconds 1800` (see Verification V1). `--models-max 1` means
  picking the other model swaps it in, so the two never compete for memory.
- **No `-ngl` / `--n-cpu-moe` in the defaults.** `--fit` (on by default) only
  adjusts arguments that are unset. A user can still pin either per model in
  the INI.
- **Two parallel slots**, so one chat and one IDE agent run at once. `--fit`
  accounts for the KV cache of both.
- **No dedicated coder model.** Qwen3-Coder-Next (80B-A3B, February 2026)
  scores ~70.7% on SWE-bench Verified; the default Qwen3.6-35B-A3B scores
  ~73.4% at under half the size.

### Aux router (`llm-aux`)

Generated `models/aux.ini`:

```ini
version = 1

[*]
n-gpu-layers = 999

[qwen3-4b]
hf-repo = unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M
c = 16384
parallel = 2
jinja = true

[qwen2.5-coder-1.5b]
hf-repo = ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF
c = 8192
```

- `--models-max 2`: both stay resident on the iGPU (about 4 GB of shared memory).
- `qwen3-4b` is Open WebUI's task model (titles, tags, search queries), as today.
- `qwen2.5-coder-1.5b` (base, FIM-trained, 1.5 GB) serves `/infill` for
  llama.vscode and Continue autocomplete. It lives on the iGPU because
  completions fire on nearly every keystroke and would otherwise evict the
  chat model from the main router.
- Open WebUI must not offer `qwen2.5-coder-1.5b` for chat (see V6).

### Speculative decoding

Both main models have ready-made drafts: `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`
(MTP) and `eagle3-gpt-oss-120b-Q8_0.gguf` in the gpt-oss repo (EAGLE3). Both
are **off by default**. With the experts in RAM, verifying drafted tokens reads
more experts per step, so drafting can lose. `ailab bench --spec` measures on
and off on the real box and prints the preset lines to paste when it wins.

### Memory budget (worst case: gpt-oss-120b loaded)

| Item | RAM (GB) |
|---|---|
| gpt-oss-120b, experts not on the GPU | ~50 |
| aux models (iGPU shared memory) | ~4 |
| OVMS models | ~3 |
| Open WebUI, SearXNG, docker | ~3 |
| OS and headroom | ~36 |

The ~36 GB headroom leaves room for the page cache, which keeps model switches fast.

## NPU services: OVMS

- **Image:** `openvino/model_server:<release>-gpu` (CPU, GPU and NPU runtimes
  included), pinned in `.env` as `OVMS_TAG`. The installer resolves the latest
  release, the way it does for llama.cpp.
- **Devices:** `/dev/accel/accel0` and the Intel render node, `group_add:
  RENDER_GID`, cpuset E-cores.
- **Models** (Intel's reference set for Open WebUI):

| Name in API | Source | Task | Device (`.env`) |
|---|---|---|---|
| `embed` | `OpenVINO/Qwen3-Embedding-0.6B-fp16-ov` | `embeddings` | `OVMS_EMBED_DEVICE=NPU` |
| `rerank` | `OpenVINO/Qwen3-Reranker-0.6B-seq-cls-fp16-ov` | `rerank` | `OVMS_RERANK_DEVICE=NPU` |
| `whisper` | `OpenVINO/whisper-base-fp16-ov` | `speech2text` | `OVMS_STT_DEVICE=NPU` |
| `kokoro` | `Kokoro-82M-int8-ov` (exact repo confirmed in V5) | text-to-speech | `OVMS_TTS_DEVICE=CPU` |

- **`ovms-init`** runs before `ovms` (`depends_on: condition:
  service_completed_successfully`). For each model it runs `--pull` with its
  task and `--target_device`, then `--add_to_config`, into
  `MODELS_DIR/ovms`. Weights download once. The graph and config files are
  regenerated on every start, so a device change in `.env` takes effect with
  `ailab restart ovms`.
- **NPU input limit:** Qwen3 embeddings fail to load on the NPU above 8k
  tokens of context, so the embedding model is capped at 4096 tokens. Open
  WebUI chunks are ~1000 tokens.
- **Fallback:** no automatic fallback. A model that fails on the NPU gets
  `CPU` in `.env`. `verify` names the failing model and the setting to change.
- **Host:** the `npu` stage keeps installing the kernel firmware and udev rule.
  The container-side pin (`NPU_DRIVER_TAG` build arg) is removed, since OVMS
  ships its own user-mode driver.
- **Removed:** `services/npu-worker/` (app, Dockerfile, tests) and the
  `EMBED_*` / `STT_*` / `NPU_WITH_EXPORTER` settings.

## Open WebUI

Configured through environment variables in `compose.yaml`. The admin UI can
still change them afterwards. Names are checked against the pinned release in
V6.

- **Connections:** OpenAI-compatible, main router then aux router, both with
  `LLM_API_KEY`. The aux connection is limited to `qwen3-4b`.
- **Defaults:** `DEFAULT_MODELS=qwen3.6-35b-a3b`, task model `qwen3-4b`.
- **Documents:** embeddings from OVMS `embed`; hybrid search (BM25 + vector)
  on; reranking by OVMS `rerank` over the top chunks.
- **Voice:** STT through OVMS `whisper`, TTS through OVMS `kokoro` (OpenAI
  audio API). Call mode works over the Tailscale HTTPS URL.
- **Web search:** on, engine SearXNG, `http://searxng:8080/search?q=<query>`.
- **Tools:** native function calling on; code interpreter on. MCP servers are
  added per user in the UI; none are bundled.
- **Accounts:** sign-up on, new users `pending` until the admin approves.
  `WEBUI_SECRET_KEY` generated as today.
- **Version:** pinned `OPEN_WEBUI_TAG`, resolved to the latest release by the
  installer and bumped by `ailab update`.

## SearXNG

`searxng/searxng` pinned by `SEARXNG_TAG`. The installer generates
`searxng/settings.yml` from a template: random `server.secret_key`,
`search.formats: [html, json]` (Open WebUI needs JSON), limiter off (only
Open WebUI can reach it). It is on the compose network only.

## Security

- `LLM_API_KEY` (random, 48 hex) is generated in `.env` (mode 600) and passed
  to both routers with `--api-key`. Open WebUI and `ailab connect` use it.
- Model APIs bind to `127.0.0.1`. Tailscale serve is the only remote path.
- OVMS and SearXNG have no remote path at all.
- Open WebUI sign-ups need admin approval.
- Tailscale access control is the tailnet's own: the owner shares the device or
  invites users.

## Installer

### New `tailscale` stage (between `network` and `tuning`)

Order becomes: `preflight base nvidia intel-gpu npu storage docker network
tailscale tuning stack`.

1. `TAILSCALE_ENABLE=1` by default; `0` skips the stage.
2. Adds the signed apt repo from `pkgs.tailscale.com` for noble and installs
   `tailscale`.
3. If not logged in, runs `tailscale up --hostname=$TAILSCALE_HOSTNAME`
   (default `ailab`), with `--auth-key=$TAILSCALE_AUTHKEY` when set. Without a
   key it prints the login URL and waits up to 10 minutes. If the login does
   not complete, it warns, skips step 5, and the stage can be re-run later
   (`sudo ./install.sh tailscale`).
4. Checks `tailscale status --json`: `CurrentTailnet.MagicDNSEnabled` is true
   and `CertDomains` is non-empty (HTTPS certificates on). If not, it prints
   the admin-console steps and continues. The serve config is still written,
   and HTTPS starts working once they are enabled.
5. Writes the three `tailscale serve --bg` mappings from the table above,
   comparing with `tailscale serve status --json` first so a re-run changes
   nothing.

New `install.conf` keys: `TAILSCALE_ENABLE`, `TAILSCALE_AUTHKEY`,
`TAILSCALE_HOSTNAME`.

### `stack` stage

- Generates `models/main.ini`, `models/aux.ini`, `searxng/settings.yml` from
  templates in the repo. **A file the user has edited is kept.** The stage
  writes a generated file only when it is missing, or when it still carries the
  `# generated by ailab` header and differs.
- Generates `LLM_API_KEY` once.
- Resolves and pins `LLAMA_CPP_REF`, `OPEN_WEBUI_TAG`, `OVMS_TAG` (latest
  releases) on first install; `SEARXNG_TAG` comes from `.env.example`.
- Removes the VRAM-preset block and the `NPU_DRIVER_TAG` pin.

### `verify` stage

In addition to today's host check and CUDA-in-container check, it checks each
feature:

- `llm-main` `GET /models` lists `qwen3.6-35b-a3b` and `gpt-oss-120b`.
- `llm-aux` answers a chat request on `qwen3-4b` and an `/infill` request on
  `qwen2.5-coder-1.5b`.
- OVMS: one embedding, one rerank, a transcript of `tests/assets/hello.wav`
  (a 1 s WAV in the repo) and one TTS response. Each model's configured device
  is reported.
- SearXNG returns JSON for a query.
- Open WebUI `/health`; the Tailscale HTTPS URL answers (when enabled).

### `ailab` CLI

| Command | Does |
|---|---|
| `ailab models` | catalog of both routers and what is loaded |
| `ailab models pull` | loads each catalog model once, so the downloads happen now, not at a user's first request |
| `ailab connect` | prints the HTTPS URLs and ready-to-paste Continue and llama.vscode config with the API key |
| `ailab backup` | stops `open-webui` briefly, archives its volume + `.env` + `models/*.ini` to `$DATA_ROOT/backups/ailab-<date>.tar.gz`, keeps 7 |
| `ailab update` | saves pins to `.env.prev`, bumps llama.cpp / Open WebUI / OVMS to the latest releases, rebuilds, restarts |
| `ailab rollback` | restores `.env.prev` pins and restarts |
| `ailab bench [--spec]` | as today, plus speculative decoding on vs off |

`ailab-backup.timer` runs `ailab backup` daily at 03:30.

## Testing

### CPU smoke test (new, the main safety net)

`tests/smoke/compose.smoke.yaml` overrides the real compose file so the whole
stack runs on any x86 machine with Docker:

- `llm-main` and `llm-aux` use `ghcr.io/ggml-org/llama.cpp:server` (CPU) with a
  catalog of `ggml-org/SmolLM2-135M-GGUF:Q4_K_M` (96 MB) under the real model
  names. `deploy` and `devices` are reset.
- `ovms` uses the real models with every device set to `CPU`, and no devices.
- `searxng` and `open-webui` are unchanged.

`tests/smoke/run.sh` brings it up, waits for health, then asserts:

- chat through each router;
- `/infill`;
- embeddings, rerank and STT on `hello.wav`;
- TTS returns audio;
- SearXNG JSON;
- Open WebUI `/health` and its model list (showing `qwen3.6-35b-a3b` and
  `gpt-oss-120b` names, not `qwen2.5-coder-1.5b`).

It catches wrong environment variable names, API paths and config generation
without the real hardware. It runs in CI as its own job and locally in Docker
Desktop.

### Existing checks

Shellcheck, yamllint, `compose config` and the installer dry run stay. New:
CI runs the `stack` stage's generator functions against a temporary directory
and validates the output (the INI files parse, `settings.yml` lints). The smoke
test uses its own INI files (`tests/smoke/main.ini`, `tests/smoke/aux.ini`)
with the real model names mapped to SmolLM2. The npu-worker pytest job is
removed with the service.

## Docs

- `README.md`: rewritten around the four uses. What it does, how to reach it,
  how to connect an IDE, day-to-day commands.
- `docs/INSTALL.md`: Tailscale steps (install, admin console toggles, sharing
  with others), unchanged BIOS and Ubuntu steps.
- `docs/ARCHITECTURE.md`: router and `--fit`, OVMS, memory budget, a dated
  research refresh with sources (models, speculative decoding, NPU, Open WebUI
  licence).

## Verification items

These are facts to confirm while implementing, each with its decision rule:

| # | Fact to confirm | If it doesn't hold |
|---|---|---|
| V1 | `--sleep-idle-seconds` unloads idle models in router mode | drop the flag; the loaded model stays resident (bounded by `--models-max 1`) |
| V2 | `--api-key` on the router covers routed requests | put `api-key` in the `[*]` preset section too |
| V3 | `/health` needs no API key | health checks send the key |
| V4 | `tailscale serve` syntax and the HTTPS ports 443 / 8443 / 10000 on the current release | use the syntax the installed version documents; keep the ports |
| V5 | OVMS `--pull` supports all four tasks with those repos, including the exact Kokoro repo id | take the repo ids from the OVMS release's own demo |
| V6 | Open WebUI env names (web search, reranker, audio, per-connection model filter) on the pinned release | smoke test fails until fixed; if no model filter exists, document hiding the model in Admin → Models |
| V7 | each OVMS model runs on the Meteor Lake NPU | only on real hardware; set that model's device to `CPU` in `.env.example` |
| V8 | speculative decoding speeds up either model | only on real hardware; it stays off unless `ailab bench --spec` shows a win |
| V9 | Qwen3.6-35B-A3B decodes faster than gpt-oss-120b with experts in RAM (its hybrid attention may hit slow llama.cpp paths, cf. llama.cpp #19480) | only on real hardware; if not, make `gpt-oss-120b` the default |
| V10 | pinned tag formats: OVMS `<release>-gpu` from its GitHub release tag, and a Vulkan server tag matching `LLAMA_CPP_REF` | pin whatever format the registries actually publish; `llm-aux` must run a llama.cpp new enough for router mode |

## Sources

- llama-server router, `--fit`, speculative decoding: <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md>
- llama.cpp `-hf` quant selection (`find_best_model`): <https://github.com/ggml-org/llama.cpp/blob/master/common/download.cpp>
- OVMS with Open WebUI: <https://github.com/openvinotoolkit/model_server/blob/main/demos/integration_with_OpenWebUI/README.md>
- OVMS embeddings on NPU: <https://github.com/openvinotoolkit/model_server/blob/main/demos/embeddings/README.md>
- Qwen3.6-35B-A3B vs gpt-oss-120b: <https://artificialanalysis.ai/models/comparisons/qwen3-6-35b-a3b-vs-gpt-oss-120b>
- Qwen3-Coder-Next benchmarks: <https://unsloth.ai/docs/models/qwen3-coder-next>
- Qwen3-Next CPU slowness in llama.cpp: <https://github.com/ggml-org/llama.cpp/issues/19480>
- Autocomplete models: <https://docs.continue.dev/ide-extensions/autocomplete/model-setup>
- Open WebUI MCP: <https://docs.openwebui.com/features/extensibility/mcp/>
- Open WebUI licence: <https://docs.openwebui.com/license/>
- NPU driver v1.38.0: <https://github.com/intel/linux-npu-driver/releases/tag/v1.38.0>
