# Daily-driver redesign

Date: 2026-09-27. Status: approved; revision 2 folds in the research refresh
of the same day.

## Revision 2: what the research refresh changed

Five research passes (llama.cpp router, OVMS, Open WebUI + SearXNG, Tailscale,
model landscape) checked every external fact the design depends on. Primary
sources are listed under Sources.

| Change | Why |
|---|---|
| Tab-completion moves to its own `llm-fim` service; `llm-aux` stays a single-model server | Hiding a model from Open WebUI needs `OPENAI_API_CONFIGS`, which is not parsed from the environment (open-webui#19017, closed "not planned"). A model Open WebUI never connects to needs no hiding. |
| Both iGPU services use our own `ailab/llama-vulkan` image, built from the same `LLAMA_CPP_REF` as the CUDA image | llama.cpp's Docker images are tagged by nightly build number (`server-vulkan-bNNNN`), not by release (`v0.5.0`), and not every build is published, so the prebuilt image cannot be pinned to a release. |
| All versions pinned to known-good values in `.env.example`; `ailab update` moves them forward | A fresh install then runs exactly what CI tested. |
| The API key is passed as `LLAMA_API_KEY`, not in a preset | `api-key` is a reserved preset key that the router strips; the router is the only auth checkpoint. The environment also keeps it out of `ps`. |
| `verify` and `ailab` send the API key to `/models` | Only `/health` and `/v1/health` are exempt from auth. |
| OVMS pinned to `2026.4.0-gpu`; embeddings and rerank get `--max_length 2048`, and embeddings get `--pooling LAST` | 2026.4.0 fixed the Qwen3 >8k NPU load failure via `--max_length`. The NPU pads every input to `max_length`, so a smaller value is faster. `LAST` is Qwen3-Embedding's pooling. |
| A device change for an OVMS model regenerates only that model (`--overwrite_models`) | A plain re-run of `--pull` keeps the existing graph, so the device would not change. |
| Web-search variables are `ENABLE_WEB_SEARCH` / `WEB_SEARCH_ENGINE` | The older `RAG_WEB_SEARCH_*` names are gone. |
| Open WebUI settings from the environment seed the first start only | They are PersistentConfig; after the first start the admin UI owns them. Forcing the environment instead (`ENABLE_PERSISTENT_CONFIG=False`) would also wipe admin-added MCP servers on every restart. |
| Speculative decoding stays off; gpt-oss reasoning effort left at the template default | Qwen3.6 MTP measured 3-12% *slower* on an RTX 3090. The EAGLE3 speedups for gpt-oss are from vLLM clusters, not llama.cpp with experts in RAM. |
| Model catalog unchanged | Nothing released after April 2026 beats Qwen3.6-35B-A3B or gpt-oss-120b within ~85 GB: the larger MoEs don't fit, Gemma 4 and Granite 4.x are dense, GLM-4.7-Flash has no vision, and Nemotron-3's GGUF path crashes in llama.cpp. |
| Verification items V1-V4 and V10 resolved; new items for `--fit` context, mmproj choice, reranker parsing, Kokoro voices, WebSockets | See Verification items. |

## Goal

Turn projectAILab from a working concept into something the owner and the
people on his network want to use every day, on the one machine it was built
for (Core Ultra 9 185H, RTX 5060 Ti 16 GB, 96 GB DDR5).

The four uses, all in scope:

1. **Documents / knowledge.** Upload PDFs, notes and manuals, then ask about them.
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
  (the Open WebUI licence forbids removing its branding above 50 end-users in
  a rolling 30 days).
- Image generation. The 5060 Ti's VRAM belongs to the LLM.
- Public internet exposure. Access is the LAN plus the owner's tailnet only.

## What changes, at a glance

| Today | After |
|---|---|
| `llm-main` serves one model, fixed in `.env` | llama-server **router** with a model catalog, switched from the Open WebUI dropdown |
| `MAIN_N_CPU_MOE` / `MAIN_NGL` tuned by hand, VRAM presets in `stack.sh` | `--fit` (on by default) sizes GPU layers and CPU experts |
| Custom `npu-worker` (FastAPI, builds the NPU driver) | **OpenVINO Model Server (OVMS)**: embeddings, reranker, Whisper, Kokoro TTS |
| Web UI over plain HTTP; the microphone cannot work from other devices | **Tailscale** HTTPS front door; voice works on every device |
| Model APIs on localhost only | Main API and tab-completion reachable over the tailnet with an API key |
| No web search, no reranking, no TTS, no tab-completion | SearXNG, Qwen3 reranker, Kokoro voice, Qwen2.5-Coder-1.5B completion |
| `llm-aux` on the moving `server-vulkan` tag; Open WebUI on `main` | Everything pinned; `ailab update` / `ailab rollback` |
| No backups | Daily `ailab backup` timer, 7 copies |

## Services

| Service | Image | Runs on | Job | Published on |
|---|---|---|---|---|
| `llm-main` | `ailab/llama-cuda:local` (built, CUDA sm_120) | 5060 Ti + DDR5, P-cores | router: chat, reasoning, coding, vision | `127.0.0.1:8081` |
| `llm-aux` | `ailab/llama-vulkan:local` (built) | Arc iGPU, E-cores | `qwen3-4b`: titles, tags, search queries | `127.0.0.1:8082` |
| `llm-fim` | `ailab/llama-vulkan:local` | Arc iGPU, E-cores | `qwen2.5-coder-1.5b`: `/infill` for IDEs | `127.0.0.1:8084` |
| `ovms-init` | `openvino/model_server:${OVMS_TAG}` | E-cores | one-shot: pulls models, writes the OVMS config | — |
| `ovms` | same | NPU; CPU for TTS; E-cores | embeddings, rerank, STT, TTS | `127.0.0.1:8083` |
| `searxng` | `searxng/searxng:${SEARXNG_TAG}` | E-cores | private metasearch | not published |
| `open-webui` | `ghcr.io/open-webui/open-webui:${OPEN_WEBUI_TAG}` | E-cores | UI, accounts, RAG, tools | `${WEBUI_BIND_ADDR:-0.0.0.0}:3000` |
| `anythingllm` | unchanged, optional profile | E-cores | alternative UI | `:3001` |

Pinned in `.env.example`, all tested by the CPU smoke test:

| Key | Value |
|---|---|
| `LLAMA_CPP_REF` | `v0.5.0` (2026-09-23) |
| `OPEN_WEBUI_TAG` | `v0.11.4` (2026-09-21) |
| `OVMS_TAG` | `2026.4.0-gpu` (2026-09-17; GPU, NPU and CPU runtimes) |
| `SEARXNG_TAG` | `2026.9.25-12f8b6515` |

`tailscale serve` on the host is the HTTPS front door:

| Tailnet URL | Proxies to | Who uses it |
|---|---|---|
| `https://ailab.<tailnet>.ts.net/` (443) | `http://127.0.0.1:3000` Open WebUI | browsers, phones |
| `https://ailab.<tailnet>.ts.net:8443/v1` | `http://127.0.0.1:8081` main router | IDE agents (API key) |
| `https://ailab.<tailnet>.ts.net:10000/` | `http://127.0.0.1:8084` `llm-fim` | tab-completion (API key) |

Serve proxies only to `http://127.0.0.1:<port>`; `localhost` is not supported.
The model APIs never listen on the LAN. Open WebUI stays reachable over plain
HTTP on the LAN (`WEBUI_BIND_ADDR`) for people without Tailscale: text chat
works there, the microphone does not.

## Models

### Main router (`llm-main`)

Started with no model, which puts llama-server in router mode:

```
llama-server --models-preset /models/main.ini --models-max 1 \
  --sleep-idle-seconds 1800 --host 0.0.0.0 --port 8080
```

with `LLAMA_API_KEY=${LLM_API_KEY}` in the environment. Child processes run
without a key; they listen only inside the container, so the router is the one
checkpoint.

Generated `models/main.ini`, user-editable (the installer never overwrites an
edited file; see Installer):

```ini
# generated by ailab - edit freely; an edited file is never overwritten
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
  April 2026, 35B total / ~3B active, hybrid Gated DeltaNet + gated attention,
  vision and tool calling. The file is `Qwen3.6-35B-A3B-UD-Q4_K_M.gguf`
  (20.6 GB). The vision projector is fetched automatically (`--mmproj-auto`
  is on by default); the repo offers F16, BF16 and F32 (see V2).
- **`gpt-oss-120b`** (MXFP4, 59 GB, ~5.1B active) for hard reasoning. Loaded on
  demand; the first request after a switch waits for the load. Its reasoning
  effort stays at the chat template's default. Users can raise it per request
  with `chat_template_kwargs` (`{"reasoning_effort": "high"}`).
- **`--models-max 1`**: picking the other model swaps it in, so the two never
  compete for memory. **`--sleep-idle-seconds 1800`** puts an idle child to
  sleep; this works per model in router mode.
- **No `-ngl` / `--n-cpu-moe` in the defaults.** `--fit` (on by default, runs
  in each child) only adjusts arguments that are unset. A user can still pin
  either per model in the INI.
- **Two parallel slots**, so one chat and one IDE agent run at once.
- **No dedicated coder model.** Qwen3-Coder-Next (80B-A3B, February 2026)
  scores ~70.7% on SWE-bench Verified; the default Qwen3.6-35B-A3B scores
  ~73.4% at under half the size.

### iGPU services (`llm-aux`, `llm-fim`)

Both run `ailab/llama-vulkan:local`, a single-model llama-server on the Intel
render node, pinned to the E-cores, with `LLAMA_API_KEY` set:

- `llm-aux`: `-hf unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M --alias qwen3-4b
  -ngl 999 -c 16384 --parallel 2 --jinja`. Open WebUI's task model (titles,
  tags, search queries), as today.
- `llm-fim`: `-hf ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF --alias
  qwen2.5-coder-1.5b -ngl 999 -c 8192 -ub 1024 -b 1024 --cache-reuse 256`
  (llama.vscode's recommended server flags, checked against its README when
  implementing). It serves `/infill` for
  llama.vscode and Continue autocomplete. It is its own service because
  completions fire on nearly every keystroke, and Open WebUI never connects to
  it, so it cannot show up in the chat dropdown.

Together they use about 4 GB of shared memory.

### Speculative decoding

Drafts exist for both main models: `unsloth/Qwen3.6-35B-A3B-MTP-GGUF` (MTP,
`spec-type = draft-mtp`) and `eagle3-gpt-oss-120b-*.gguf` in the gpt-oss repo
(`spec-type = draft-eagle3` with a draft model). Both are **off**. Reported
results: Qwen3.6 MTP is 3-12% slower on an RTX 3090, because 3B-active decoding
is already cheap. The EAGLE3 speedups come from vLLM/TensorRT-LLM, not from
llama.cpp with the experts in RAM. `ailab bench --spec` measures on vs off on
the real box and prints the preset lines to paste when it wins.

### Later candidates (not in the first version)

- EmbeddingGemma-300M against Qwen3-Embedding-0.6B.
- whisper-large-v3-turbo NPU builds against whisper-base.
- Nemotron-3-Super (120B / 12B active) once its llama.cpp path stops crashing.

### Memory budget (worst case: gpt-oss-120b loaded)

| Item | RAM (GB) |
|---|---|
| gpt-oss-120b, experts not on the GPU | ~50 |
| `llm-aux` + `llm-fim` (iGPU shared memory) | ~4 |
| OVMS models | ~3 |
| Open WebUI, SearXNG, docker | ~3 |
| OS and headroom | ~36 |

## New image: `docker/llama-vulkan`

Built like `docker/llama-cuda`: two stages from `ubuntu:24.04`, cloning
`ggml-org/llama.cpp` at `LLAMA_CPP_REF`, `-DGGML_VULKAN=ON`, `-DLLAMA_OPENSSL=ON`
(with the same OpenSSL guard), the same CPU flags (`GGML_NATIVE=OFF`, AVX2,
AVX-VNNI), target `llama-server`. The build stage needs `libvulkan-dev` and
`glslc`. The runtime stage has `mesa-vulkan-drivers`, `libvulkan1`,
`libssl3t64`, `libgomp1` and `curl` for the health check. Mesa's Intel ANV
driver runs the Arc iGPU. In the CPU smoke test the same image runs on Mesa's
lavapipe (a software Vulkan device), so the image under test is the one that
ships.

## NPU services: OVMS

- **Image:** `openvino/model_server:2026.4.0-gpu` (`OVMS_TAG`), which includes
  the CPU, GPU and NPU runtimes.
- **Devices:** `/dev/accel`, `group_add: RENDER_GID`, cpuset E-cores. No GPU
  is used.
- **Models** (all four ids exist in the OpenVINO HF org):

| Name in API | Source | `--task` | Options | Device (`.env`) |
|---|---|---|---|---|
| `embed` | `OpenVINO/Qwen3-Embedding-0.6B-fp16-ov` | `embeddings` | `--pooling LAST --max_length 2048` | `OVMS_EMBED_DEVICE=NPU` |
| `rerank` | `OpenVINO/Qwen3-Reranker-0.6B-seq-cls-fp16-ov` | `rerank` | `--max_length 2048` | `OVMS_RERANK_DEVICE=NPU` |
| `whisper` | `OpenVINO/whisper-base-fp16-ov` | `speech2text` | — | `OVMS_STT_DEVICE=NPU` |
| `kokoro` | `OpenVINO/Kokoro-82M-int8-ov` | `text2speech` | — | `OVMS_TTS_DEVICE=CPU` |

The plain `Qwen3-Reranker-0.6B` is not supported by OVMS; the `seq-cls`
variant is.

- **`ovms-init`** runs before `ovms` (`depends_on: condition:
  service_completed_successfully`). For each model it runs `--pull
  --source_model <id> --task <task> --target_device <dev> <options>
  --model_repository_path /models`, then `--add_to_config --config_path
  /models/config.json --model_name <name> --model_path <path>`.
  - `--pull` reuses existing files, so weights download once.
  - Each model directory carries a `.ailab-device` marker. When `.env` names a
    different device, that model alone is pulled again with
    `--overwrite_models`, then the marker is updated. `ailab restart ovms`
    therefore applies a device change.
  - NPU models get an OpenVINO `CACHE_DIR` under `/models/cache` through
    `--plugin_config`, so compiled NPU blobs survive restarts.
- **Endpoints:** `/v3/embeddings` (OpenAI), `/v3/rerank` (Cohere-compatible:
  `{model, query, documents}` → `results[].index/relevance_score`),
  `/v3/audio/transcriptions`, `/v3/audio/speech`. Health: `/v2/health/ready`;
  per-model state: `/v1/config`.
- **NPU status:** embeddings and rerank on the NPU are a preview feature in
  OVMS, and no source names Meteor Lake (NPU 3720) explicitly, so V7 decides it
  on the hardware. There is no automatic fallback (`AUTO:NPU,CPU` is not
  documented for these pipelines). A model that fails on the NPU gets `CPU` in
  `.env`, and `verify` names the model and the setting to change.
- **Host:** the `npu` stage keeps installing the kernel firmware and udev rule.
  The container-side pin (`NPU_DRIVER_TAG` build arg) is removed, since OVMS
  ships its own user-mode driver.
- **Removed:** `services/npu-worker/` (app, Dockerfile, tests) and the
  `EMBED_*` / `STT_*` / `NPU_WITH_EXPORTER` settings.

## Open WebUI

Pinned to `v0.11.4`. It is configured through environment variables in
`compose.yaml`; the smoke test proves each one against this release (V4).

| Area | Variables |
|---|---|
| Connections | `ENABLE_OLLAMA_API=false`; `OPENAI_API_BASE_URLS=http://llm-main:8080/v1;http://llm-aux:8080/v1`; `OPENAI_API_KEYS=${LLM_API_KEY};${LLM_API_KEY}` |
| Defaults | `DEFAULT_MODELS=qwen3.6-35b-a3b`; `TASK_MODEL_EXTERNAL=qwen3-4b` |
| Documents | `RAG_EMBEDDING_ENGINE=openai`, `RAG_OPENAI_API_BASE_URL=http://ovms:8000/v3`, `RAG_OPENAI_API_KEY=none`, `RAG_EMBEDDING_MODEL=embed`; `ENABLE_RAG_HYBRID_SEARCH=true`; `RAG_RERANKING_ENGINE=external`, `RAG_EXTERNAL_RERANKER_URL=http://ovms:8000/v3/rerank`, `RAG_RERANKING_MODEL=rerank` |
| Voice | `AUDIO_STT_ENGINE=openai`, `AUDIO_STT_OPENAI_API_BASE_URL=http://ovms:8000/v3`, `AUDIO_STT_OPENAI_API_KEY=none`, `AUDIO_STT_MODEL=whisper`; `AUDIO_TTS_ENGINE=openai`, `AUDIO_TTS_OPENAI_API_BASE_URL=http://ovms:8000/v3`, `AUDIO_TTS_OPENAI_API_KEY=none`, `AUDIO_TTS_MODEL=kokoro`, `AUDIO_TTS_VOICE` (a Kokoro voice, V6) |
| Web search | `ENABLE_WEB_SEARCH=true`, `WEB_SEARCH_ENGINE=searxng`, `SEARXNG_QUERY_URL=http://searxng:8080/search?q=<query>` |
| Tools | `ENABLE_CODE_INTERPRETER=true`. Native function calling is the default since v0.10. MCP servers are added in the UI; none are bundled. |
| Accounts | `ENABLE_SIGNUP=true`, `DEFAULT_USER_ROLE=pending`; `WEBUI_SECRET_KEY` generated as today; `WEBUI_URL` set to the Tailscale HTTPS URL when known |

- **PersistentConfig.** Most of these variables seed the database on the first
  start, and the admin UI owns them after that. We keep that default rather
  than setting `ENABLE_PERSISTENT_CONFIG=False`, which would also reset
  admin-added MCP servers on every restart. `ailab edit` warns when a changed
  variable is one Open WebUI no longer reads from the environment.
- **Vision:** image upload works with `qwen3.6-35b-a3b`.
- **WebSockets:** see V10.

## SearXNG

`searxng/searxng:2026.9.25-12f8b6515` (`SEARXNG_TAG`). The installer generates
`searxng/settings.yml`:

```yaml
# generated by ailab - edit freely; an edited file is never overwritten
use_default_settings: true
server:
  secret_key: "<random, 64 hex>"
  limiter: false
search:
  formats: [html, json]
```

Without `json` in `formats`, SearXNG answers Open WebUI with 403. The limiter
is off because only Open WebUI can reach it. The container listens on 8080 on
the compose network only.

## Security

- `LLM_API_KEY` (random, 48 hex) is generated in `.env` (mode 600). It is given
  to `llm-main`, `llm-aux` and `llm-fim` as `LLAMA_API_KEY`. Open WebUI and
  `ailab connect` use it. `/health` and `/v1/health` stay open for health
  checks.
- Model APIs bind to `127.0.0.1`; Tailscale serve is the only remote path.
- OVMS and SearXNG have no remote path at all.
- Open WebUI sign-ups need admin approval.
- Tailscale access control is the tailnet's own: the owner shares the device or
  invites users.

## Installer

### New `tailscale` stage (between `network` and `tuning`)

Order becomes: `preflight base nvidia intel-gpu npu storage docker network
tailscale tuning stack`.

1. `TAILSCALE_ENABLE=1` by default; `0` skips the stage.
2. Adds the signed apt repo (keyring
   `https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg` →
   `/usr/share/keyrings/tailscale-archive-keyring.gpg`, list
   `noble.tailscale-keyring.list` → `/etc/apt/sources.list.d/tailscale.list`)
   and installs `tailscale`.
3. Reads `tailscale status --json`. If `BackendState` is not `Running`, runs
   `tailscale up --hostname=$TAILSCALE_HOSTNAME --timeout=10m`, with
   `--auth-key=$TAILSCALE_AUTHKEY` when set. Without a key, the login URL is
   printed (and is also `AuthURL` in the status JSON). On timeout the stage
   warns, skips step 5, and can be re-run later (`sudo ./install.sh
   tailscale`). If already running under another hostname, it uses `tailscale
   set --hostname=...`, since `tailscale up` with changed flags refuses without
   `--reset`.
4. Checks `CurrentTailnet.MagicDNSEnabled` and a non-empty `CertDomains`. If
   either is off, it prints the admin-console steps (enable MagicDNS, then
   HTTPS Certificates) and continues. Serve provisions the certificate itself
   on the first request once they are on.
5. For each mapping, compares `tailscale serve status --json`
   (`Web["<Self.DNSName>:<port>"].Handlers["/"].Proxy`) with the desired
   target and only then runs `tailscale serve --bg --https=<port>
   http://127.0.0.1:<target>`. `--bg` mappings persist across reboots.
6. Records the HTTPS URL in installer state (`state_set tailscale-url`). The
   `stack` stage, which creates `.env`, writes it as `WEBUI_URL`.

New `install.conf` keys: `TAILSCALE_ENABLE`, `TAILSCALE_AUTHKEY`,
`TAILSCALE_HOSTNAME` (default `ailab`).

### `stack` stage

- Generates `models/main.ini`, `searxng/settings.yml` from templates in the
  repo. **A file the user has edited is kept.** The stage writes a generated
  file only when it is missing, or when it still starts with the
  `# generated by ailab` header and differs from the template output.
- Generates `LLM_API_KEY` once.
- Builds `ailab/llama-cuda` and `ailab/llama-vulkan` at `LLAMA_CPP_REF`; pulls
  the pinned OVMS, SearXNG and Open WebUI images.
- Removes the VRAM-preset block, the `LLAMA_CPP_REF=master` resolution and the
  `NPU_DRIVER_TAG` pin.

### `verify` stage

In addition to today's host check and CUDA-in-container check, it checks each
feature (sending the API key where required):

- `llm-main` `GET /models` lists `qwen3.6-35b-a3b` and `gpt-oss-120b`.
- `llm-aux` answers a chat request; `llm-fim` answers an `/infill` request.
- OVMS `/v2/health/ready`; then one embedding, one rerank, a transcript of
  `tests/assets/hello.wav` (a 1 s WAV in the repo) and one TTS response. Each
  model's configured device is reported, and a failing NPU model is named with
  the `.env` setting to change.
- SearXNG returns JSON for a query.
- Open WebUI `/health`; the Tailscale HTTPS URL answers (when enabled).

### `ailab` CLI

| Command | Does |
|---|---|
| `ailab models` | catalog and load state of the main router, plus the aux and fim models |
| `ailab models pull` | sends each catalog model one tiny request, so the downloads happen now, not at a user's first request |
| `ailab connect` | prints the HTTPS URLs and ready-to-paste Continue and llama.vscode config with the API key |
| `ailab backup` | stops `open-webui` briefly, archives its volume + `.env` + `models/main.ini` + `searxng/settings.yml` to `$DATA_ROOT/backups/ailab-<date>.tar.gz`, keeps 7 |
| `ailab update` | saves the pins to `.env.prev`; moves `LLAMA_CPP_REF`, `OPEN_WEBUI_TAG` and `OVMS_TAG` to the latest GitHub releases and `SEARXNG_TAG` to the newest dated Docker Hub tag; rebuilds, restarts |
| `ailab rollback` | restores `.env.prev` pins, rebuilds, restarts |
| `ailab bench [--spec]` | as today, plus speculative decoding on vs off |

`ailab-backup.timer` runs `ailab backup` daily at 03:30.

## Testing

### CPU smoke test (new, the main safety net)

`tests/smoke/compose.smoke.yaml` overrides the real compose file so the whole
stack runs on any x86 machine with Docker:

- `llm-main`, `llm-aux` and `llm-fim` all run our `ailab/llama-vulkan` image
  on Mesa's lavapipe (no devices), so the pinned llama.cpp that ships is the
  one tested. `llm-main` runs in router mode with `tests/smoke/main.ini`,
  which maps both real model names to `ggml-org/SmolLM2-135M-GGUF:Q4_K_M`
  (96 MB); `llm-aux` and `llm-fim` serve the same file under their aliases.
  `deploy` and `devices` are reset.
- `ovms-init` and `ovms` use the real models with every device set to `CPU`
  and no devices.
- `searxng` and `open-webui` are unchanged.

`tests/smoke/run.sh` brings it up, waits for health, then asserts:

1. chat through the router on both model names;
2. `/models` rejects a request without the key;
3. `llm-aux` chat and `llm-fim` `/infill`;
4. OVMS embeddings, rerank, STT on `hello.wav`, and TTS returns audio;
5. switching `OVMS_TTS_DEVICE` to another value and restarting regenerates
   only that model (marker logic);
6. SearXNG JSON;
7. Open WebUI: sign up the first user (becomes admin) with `POST
   /api/v1/auths/signup`, then `GET /api/models` shows `qwen3.6-35b-a3b`,
   `gpt-oss-120b` and `qwen3-4b`, and not `qwen2.5-coder-1.5b`;
8. a chat completion through Open WebUI's API;
9. a document upload and a retrieval query through Open WebUI, which exercises
   embeddings, hybrid search and the reranker response parsing (V5).

It catches wrong environment variable names, API paths and config generation
without the real hardware. It runs in CI as its own job and locally in Docker
Desktop.

### Existing checks

Shellcheck, yamllint, `compose config` and the installer dry run stay. New:

- CI runs the `stack` stage's generator functions against a temporary
  directory and validates the output (the INI parses, `settings.yml` lints).
- The npu-worker pytest job is removed with the service.
- `actions/checkout` moves to a Node 24 release (v4 runs on a deprecated
  Node 20).
- The CUDA image is not built in CI (size and time). Its OpenSSL guard was
  checked against a real configure; the Vulkan image is built by the smoke job.

## Docs

- `README.md`: rewritten around the four uses. What it does, how to reach it,
  how to connect an IDE, day-to-day commands.
- `docs/INSTALL.md`: Tailscale steps (install, admin console toggles, sharing
  with others), unchanged BIOS and Ubuntu steps.
- `docs/ARCHITECTURE.md`: router and `--fit`, OVMS, memory budget, a dated
  research refresh with sources (models, speculative decoding, NPU, Open WebUI
  licence).

## Verification items

### Resolved by the research refresh (2026-09-27)

| Was | Result |
|---|---|
| `--sleep-idle-seconds` in router mode | works, per child |
| `--api-key` through the router | enforced only at the router; `api-key` is reserved in presets (use `LLAMA_API_KEY`) |
| `/health` without a key | `/health` and `/v1/health` are exempt; `/models` is not |
| `tailscale serve` syntax and ports | `--bg --https=<port> http://127.0.0.1:<port>`; any port for tailnet-only serve |
| OVMS tasks, repo ids, tag | `embeddings`, `rerank`, `speech2text`, `text2speech`; all four ids exist; `2026.4.0-gpu` |
| Pinned image tag formats | llama.cpp images are not pinnable to a release, so we build our own; OVMS is `<release>-gpu` |
| Router needs `LLAMA_SUBPROCESS` | on by default in Linux builds |

### Still open

| # | Fact to confirm | How | If it doesn't hold |
|---|---|---|---|
| V1 | `--fit` leaves the explicit `c = 65536` alone and budgets for 2 slots | hardware: the child's log shows the final ctx and offload | set `fit-ctx = 65536` in `[*]`, or lower `parallel` |
| V2 | the auto-downloaded Qwen3.6 mmproj works | hardware: an image question | name the file explicitly with `mmproj-url` in the preset |
| V3 | the OVMS device-change marker logic and NPU `CACHE_DIR` | smoke test (CPU path) and hardware (NPU path) | document a manual `rm -r` of that model's directory |
| V4 | Open WebUI env names on v0.11.4 | smoke test fails until fixed | set the value once in the admin UI and document it |
| V5 | Open WebUI parses OVMS `/v3/rerank` responses | smoke test step 9 | turn reranking off (`RAG_RERANKING_ENGINE` empty); hybrid search still works |
| V6 | Kokoro voice names served by OVMS | smoke test (TTS request) | use the voice the OVMS demo uses |
| V7 | each OVMS model runs on the Meteor Lake NPU | hardware only | set that model's device to `CPU` in `.env.example` |
| V8 | speculative decoding speeds up either model | hardware: `ailab bench --spec` | stays off |
| V9 | Qwen3.6-35B-A3B decodes faster than gpt-oss-120b with experts in RAM (its Gated DeltaNet layers run on the GPU; llama.cpp #19480 concerns the CPU path) | hardware: `ailab bench` | make `gpt-oss-120b` the default |
| V10 | Open WebUI WebSockets stay up through `tailscale serve` (tailscale#18827 reports drops on one WSL2 machine) | hardware | `ENABLE_WEBSOCKET_SUPPORT=false` (Socket.IO falls back to polling) |

## Sources

- llama-server router, `--fit`, auth, sleep: <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md>, `tools/server/server-models.cpp`, `tools/server/server-http.cpp`
- llama.cpp `-hf` quant selection (`find_best_model`): <https://github.com/ggml-org/llama.cpp/blob/master/common/download.cpp>
- llama.cpp speculative decoding: <https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md>
- llama.cpp Docker tags: `.github/workflows/docker.yml`, `.github/actions/get-tag-name` in ggml-org/llama.cpp
- llama.cpp latest release: <https://github.com/ggml-org/llama.cpp/releases/tag/v0.5.0>
- OVMS release: <https://github.com/openvinotoolkit/model_server/releases/tag/v2026.4.0>
- OVMS parameters: <https://github.com/openvinotoolkit/model_server/blob/main/docs/parameters.md>
- OVMS with Open WebUI: <https://github.com/openvinotoolkit/model_server/blob/main/demos/integration_with_OpenWebUI/README.md>
- OVMS embeddings / rerank / audio demos: `demos/embeddings`, `demos/rerank`, `demos/audio` in openvinotoolkit/model_server
- Open WebUI release: <https://github.com/open-webui/open-webui/releases/tag/v0.11.4>
- Open WebUI `OPENAI_API_CONFIGS` not parsed from env: <https://github.com/open-webui/open-webui/issues/19017>
- Open WebUI env reference: <https://docs.openwebui.com/getting-started/env-configuration>
- Open WebUI MCP: <https://docs.openwebui.com/features/extensibility/mcp/>
- Open WebUI licence: <https://docs.openwebui.com/license/>
- SearXNG tags: <https://hub.docker.com/r/searxng/searxng/tags>
- Tailscale serve: <https://tailscale.com/kb/1242/tailscale-serve>; install on 24.04: <https://tailscale.com/kb/1031/install-ubuntu-2404>; status fields: `ipn/ipnstate/ipnstate.go` in tailscale/tailscale
- Tailscale WebSocket report: <https://github.com/tailscale/tailscale/issues/18827>
- Qwen3.6-35B-A3B model card (architecture): <https://huggingface.co/Qwen/Qwen3.6-35B-A3B>
- Qwen3.6-35B-A3B vs gpt-oss-120b: <https://artificialanalysis.ai/models/comparisons/qwen3-6-35b-a3b-vs-gpt-oss-120b>
- Qwen3.6 MTP results: <https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/discussions/14>
- Qwen3-Coder-Next benchmarks: <https://unsloth.ai/docs/models/qwen3-coder-next>
- Qwen3-Next CPU slowness in llama.cpp: <https://github.com/ggml-org/llama.cpp/issues/19480>
- Autocomplete models: <https://docs.continue.dev/ide-extensions/autocomplete/model-setup>
- NPU driver v1.38.0: <https://github.com/intel/linux-npu-driver/releases/tag/v1.38.0>
