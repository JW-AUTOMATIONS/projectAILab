# Daily-driver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn projectAILab into a daily driver for Jordan and the people on his network: switch models from the chat UI, documents with reranking, voice in and out over HTTPS, IDE agents and tab-completion, private web search, with backups and safe updates.

**Architecture:** The docker compose stack gets a llama-server router (`llm-main`, CUDA) over a model catalog in `config/main.ini`. Two small llama-servers run on the Arc iGPU (`llm-aux` task model, `llm-fim` tab-completion) from a Vulkan image built from the same llama.cpp release. OpenVINO Model Server replaces the custom NPU worker, SearXNG adds search, and Open WebUI is wired to all of them through environment variables. A new `tailscale` installer stage gives the stack an HTTPS front door. A CPU smoke test boots the whole stack on any Docker host, so every integration is tested without the real hardware.

**Tech Stack:** bash (installer, CLI, tests), bats 1.10 (unit tests), docker compose 2.24+ (`!reset`/`!override`), llama.cpp v0.5.0, OpenVINO Model Server 2026.4.0, Open WebUI v0.11.4, SearXNG, Tailscale, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-27-daily-driver-design.md` (revision 2). Read it before starting; this plan argues from it.

## Global Constraints

- Host target: Ubuntu 24.04 LTS. Every installer stage stays idempotent. System changes go through `run`, files through `write_file` / `write_generated` (`installer/lib.sh`), so `./install.sh --dry-run` shows them.
- Pinned versions, verbatim: `LLAMA_CPP_REF=v0.5.0`, `OPEN_WEBUI_TAG=v0.11.4`, `OVMS_TAG=2026.4.0-gpu`, `SEARXNG_TAG=2026.9.25-12f8b6515`.
- Model names and sources:
  - `qwen3.6-35b-a3b` → `unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M`
  - `gpt-oss-120b` → `ggml-org/gpt-oss-120b-GGUF:MXFP4`
  - `qwen3-4b` → `unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M`
  - `qwen2.5-coder-1.5b` → `ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF`
  - OVMS served names: `embed`, `rerank`, `whisper`, `kokoro`.
- Ports:
  - `llm-main` `127.0.0.1:8081`, `llm-aux` `:8082`, `ovms` `:8083`, `llm-fim` `:8084`; Open WebUI `${WEBUI_BIND_ADDR}:3000`.
  - Tailscale serve: 443 → 3000, 8443 → 8081, 10000 → 8084. Targets are always `http://127.0.0.1:<port>`, never `localhost`.
- The API key is `LLM_API_KEY` in `.env`, passed to containers as `LLAMA_API_KEY`. It never goes in a preset or on a command line.
- Shell: `set -euo pipefail` in scripts. Clean under Ubuntu 24.04's shellcheck **0.9.0**, which is stricter than 0.10 (it flags SC2002 and SC2012). yamllint uses the rules in `tests/ci-checks.sh`.
- Windows checkout (`core.filemode=false`): a new executable script must be added with `git add --chmod=+x <path>`.
- Session hooks on Jordan's PC:
  - The agent's Bash commands must not contain URLs, the word `sudo`, or `.env` file names. Scripts that download are run by name (`tests/ci-local.sh`, `tests/smoke/in-dind.sh`, `tests/images/llama-vulkan.sh`).
  - At the start of execution, ask Jordan once to approve their downloads (Docker images, Ubuntu packages, Hugging Face models).
  - The hook refuses `git add` of `.env.example`. When a task changes it, give Jordan the exact commit command. Never stage it through a wildcard or a directory.
- Never wipe a disk or apply network changes without asking (`MODELS_DISK`, `BOND_APPLY`). Tailscale login is Jordan's.
- Work on branch `feat/daily-driver` from `main`, and commit after every task. Do not push without asking.
- Large container logs (> 50 KB) go through `claude-forge:agency-routing` for a digest; don't `Read` them whole.

## File map

| Path | Status | Responsibility |
|---|---|---|
| `tests/ci-checks.sh` | new | the lint + unit + compose + dry-run checks CI runs |
| `tests/ci-local.sh` | new | runs `ci-checks.sh` (or any command) in a throwaway ubuntu:24.04 container |
| `tests/unit/helpers.bash` | new | bats setup: temp dir, command stubs, compose binary |
| `tests/unit/*.bats` | new | unit tests per unit (lib, generate, gen_env, ovms_init, compose, stack, tailscale, models, backup, update) |
| `docker/llama-vulkan/Dockerfile` | new | llama-server (Vulkan) at `LLAMA_CPP_REF` for the iGPU services |
| `tests/images/llama-vulkan.sh` | new | builds that image and proves `/infill`, the API key and router mode |
| `templates/main.ini` | new | default model catalog for the router |
| `templates/searxng/settings.yml` | new | SearXNG settings (JSON output on, limiter off) |
| `installer/lib.sh` | modify | + `write_generated`, `GEN_HEADER` |
| `host/scripts/gen-env.sh` | modify | + `LLM_API_KEY`, `SEARXNG_SECRET` |
| `services/ovms/init.sh` | new | ovms-init entrypoint: pull models, per-model device markers, config.json |
| `services/npu-worker/` | delete | replaced by OVMS |
| `compose.yaml`, `.env.example` | rewrite | the new services and settings |
| `host/scripts/check-features.sh` | new | feature checks against a running stack (used by `verify` and the smoke test) |
| `tests/assets/hello.wav`, `tests/assets/doc.txt` | new | speech sample for Whisper; document for the RAG check |
| `tests/smoke/compose.smoke.yaml`, `main.ini`, `run.sh`, `in-dind.sh` | new | CPU smoke test |
| `installer/stages/stack.sh` | rewrite | env merge, generated config, units incl. backup timer, both image builds |
| `installer/stages/tailscale.sh` | new | Tailscale install, login, HTTPS check, serve mappings |
| `installer/stages/verify.sh` | modify | host check + feature checks + Tailscale URL |
| `installer/stages/storage.sh` | modify | `models/ovms` instead of `models/openvino` |
| `install.sh`, `install.conf.example` | modify | tailscale stage and settings |
| `scripts/ailab` | rewrite | dispatcher for the new commands |
| `scripts/models.sh`, `connect.sh`, `backup.sh`, `update.sh` | new | `ailab models`, `connect`, `backup`, `update`/`rollback` |
| `scripts/bench.sh` | rewrite | API key, model field, `--spec` |
| `.github/workflows/ci.yml` | rewrite | `ci-checks.sh` job + smoke job |
| `.gitignore` | modify | `config/`, `.smoke/` |
| `README.md`, `docs/INSTALL.md`, `docs/ARCHITECTURE.md`, spec | modify | docs for the new stack |

---

## Phase 0: Test harness

**Skills & tools:** superpowers:test-driven-development; Docker Desktop (ubuntu:24.04 container), bats
**Files:** `tests/ci-checks.sh`, `tests/ci-local.sh`, `tests/unit/helpers.bash`, `tests/unit/lib.bats`, `.gitignore`
**Verification:** `tests/ci-local.sh` ends with `all checks passed`

### Task 1: Local CI runner and bats harness

**Files:**
- Create: `tests/unit/helpers.bash`, `tests/unit/lib.bats`, `tests/ci-checks.sh`, `tests/ci-local.sh`
- Modify: `.gitignore`

**Interfaces:**
- Produces:
  - `common_setup` / `common_teardown`. They export `T` (temp dir), `STUBS` (first on `PATH`), `STUB_LOG` and `AILAB_STATE_DIR=$T/state`.
  - `stub NAME [BASH_BODY]`, which creates a fake command. It logs `NAME args...` to `$STUB_LOG`, then runs BODY.
  - `compose_cmd ARGS...`, which runs `docker compose` or the bare compose plugin.
  - `tests/ci-local.sh [CMD...]`, which runs CMD (default `tests/ci-checks.sh`) in a clean ubuntu:24.04 container with the CI tools.

- [ ] **Step 1: Create branch**

```bash
git switch -c feat/daily-driver main
```

- [ ] **Step 2: Write the bats helpers**

`tests/unit/helpers.bash`:

```bash
# Shared setup for the bats unit tests.
# Each test gets a temp dir ($T), a stub dir first on PATH ($STUBS) and a log
# of stub calls ($STUB_LOG).
REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

common_setup() {
  T=$(mktemp -d)
  STUBS=$T/stubs
  STUB_LOG=$T/stub.log
  mkdir -p "$STUBS"
  : >"$STUB_LOG"
  PATH=$STUBS:$PATH
  AILAB_STATE_DIR=$T/state
  export T STUBS STUB_LOG PATH AILAB_STATE_DIR
}

common_teardown() { rm -rf "$T"; }

# stub NAME [BODY]: a fake command that logs "NAME args..." and then runs BODY.
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$STUB_LOG"\n%s\n' "$1" "${2:-}" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    /usr/libexec/docker/cli-plugins/docker-compose "$@"
  fi
}
```

- [ ] **Step 3: Write characterization tests for `installer/lib.sh`**

These pin current behaviour before later tasks build on it. `tests/unit/lib.bats`:

```bash
#!/usr/bin/env bats
# installer/lib.sh helpers.
load helpers

setup() {
  common_setup
  # shellcheck source=../../installer/lib.sh
  source "$REPO/installer/lib.sh"
}
teardown() { common_teardown; }

@test "env_set replaces an existing key and keeps the others" {
  printf 'A=1\nB=2\n' >"$T/env"
  env_set "$T/env" A 9
  [ "$(cat "$T/env")" = $'A=9\nB=2' ]
}

@test "env_set appends a missing key; values may hold spaces and pipes" {
  printf 'A=1\n' >"$T/env"
  env_set "$T/env" C 'x y|z'
  [ "$(env_get "$T/env" C)" = 'x y|z' ]
}

@test "write_file writes once and reports FILE_CHANGED" {
  write_file "$T/f" <<<"one"
  [ "$FILE_CHANGED" = 1 ]
  write_file "$T/f" <<<"one"
  [ "$FILE_CHANGED" = 0 ]
  [ "$(cat "$T/f")" = one ]
}

@test "write_file changes nothing in a dry run" {
  DRY_RUN=1
  run write_file "$T/f" <<<"one"
  [ ! -e "$T/f" ]
  [[ $output == *"+ write $T/f"* ]]
}

@test "a dry run without jq stops early and names the fix" {
  stub curl; stub rsync; stub gpg
  run /bin/bash -c "PATH='$STUBS'; DRY_RUN=1; source '$REPO/installer/lib.sh'; ensure_prereqs"
  [ "$status" -eq 1 ]
  [[ $output == *"a dry run needs jq; install first: sudo apt install -y jq"* ]]
}
```

- [ ] **Step 4: Write the CI checks script**

`tests/ci-checks.sh`:

```bash
#!/usr/bin/env bash
# The lint, unit, compose and dry-run checks CI runs (.github/workflows/ci.yml).
# Needs shellcheck, yamllint, bats, jq and docker compose; tests/ci-local.sh
# runs it in a container that has them.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
shopt -s nullglob

step() { printf '\n== %s\n' "$*"; }
if docker compose version >/dev/null 2>&1; then
  compose=(docker compose)
else
  compose=(/usr/libexec/docker/cli-plugins/docker-compose)
fi

step shellcheck
shellcheck -x install.sh
sh_files=(installer/lib.sh installer/stages/*.sh scripts/ailab scripts/*.sh host/scripts/*.sh
  tests/*.sh tests/images/*.sh tests/smoke/*.sh services/ovms/*.sh)
shellcheck -s bash -x "${sh_files[@]}"

step yamllint
yaml_files=(compose.yaml tests/smoke/*.yaml templates/searxng/*.yml host/netplan/*.yaml .github/workflows/*.yml)
yamllint -d '{extends: default, rules: {line-length: {max: 120}, document-start: disable, truthy: disable,
  comments: {min-spaces-from-content: 1}}}' "${yaml_files[@]}"

step "compose config"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp .env.example "$tmp/env"
host/scripts/gen-env.sh --write "$tmp/env" >/dev/null 2>&1
sed -i 's/^RENDER_GID=$/RENDER_GID=109/' "$tmp/env"
"${compose[@]}" --env-file "$tmp/env" config -q
"${compose[@]}" --env-file "$tmp/env" --profile anythingllm config -q

step "unit tests"
bats tests/unit

step "installer dry run"
./install.sh --dry-run >/dev/null

printf '\nall checks passed\n'
```

- [ ] **Step 5: Write the container runner**

`tests/ci-local.sh`:

```bash
#!/usr/bin/env bash
# Run CI's checks in a throwaway ubuntu:24.04 container against the working
# tree, uncommitted changes included. Works from Linux, macOS, WSL and Git Bash.
#   tests/ci-local.sh                          # everything (tests/ci-checks.sh)
#   tests/ci-local.sh bats tests/unit/x.bats   # one command instead
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Git Bash: pass a C:/... path to docker and don't rewrite container paths.
if command -v cygpath >/dev/null; then ROOT=$(cygpath -m "$ROOT"); fi
export MSYS_NO_PATHCONV=1
(($#)) || set -- tests/ci-checks.sh

# shellcheck disable=SC2016 # the script below runs inside the container
docker run --rm -v "$ROOT:/src:ro" ubuntu:24.04 bash -c '
set -euo pipefail
tar -C /src --exclude=./.smoke --exclude=./.git -cf - . | { mkdir /work && tar -C /work -xf -; }
cd /work
# A Windows checkout may carry CRLF and lose exec bits.
find . -type f -print0 | xargs -0 sed -i "s/\r$//"
find . -name "*.sh" -exec chmod +x {} + && chmod +x install.sh scripts/ailab
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends shellcheck yamllint bats jq curl ca-certificates \
  rsync gnupg docker-compose-v2 >/dev/null
"$@"
' ci-local "$@"
```

- [ ] **Step 6: Ignore generated and smoke-test files**

Append to `.gitignore`:

```
config/
.smoke/
```

- [ ] **Step 7: Run the whole suite**

Run: `tests/ci-local.sh`
Expected: 5 bats tests `ok`, then `all checks passed`. These are characterization tests of existing code, so they pass straight away. If one fails, the harness is wrong, so fix it before going on.

- [ ] **Step 8: Commit**

```bash
git add tests/unit .gitignore
git add --chmod=+x tests/ci-checks.sh tests/ci-local.sh
git commit -m "Add bats harness and a local runner for CI's checks"
```

---

## Phase 1: iGPU image

**Skills & tools:** superpowers:test-driven-development; Docker Desktop (`docker build` / `run`); superpowers:systematic-debugging if the build fails
**Files:** `docker/llama-vulkan/Dockerfile`, `tests/images/llama-vulkan.sh`
**Verification:** `tests/images/llama-vulkan.sh` prints three `PASS` lines

### Task 2: `ailab/llama-vulkan` image

**Files:**
- Create: `docker/llama-vulkan/Dockerfile`, `tests/images/llama-vulkan.sh`

**Interfaces:**
- Produces: the image `ailab/llama-vulkan:local` (entrypoint `llama-server`), build arg `LLAMA_CPP_REF`. It is used by `llm-aux` and `llm-fim`, and by `llm-main` in the smoke test.

- [ ] **Step 1: Write the image test**

`tests/images/llama-vulkan.sh`:

```bash
#!/usr/bin/env bash
# Build ailab/llama-vulkan and prove it serves: /infill, the API key and router
# mode. Runs on the CPU (Mesa lavapipe), so any Docker host works.
#   tests/images/llama-vulkan.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REF=${LLAMA_CPP_REF:-v0.5.0}
TINY=ggml-org/Qwen2.5-Coder-0.5B-Q8_0-GGUF
PORT=18080
export MSYS_NO_PATHCONV=1
hostpath() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

docker build -t ailab/llama-vulkan:local --build-arg LLAMA_CPP_REF="$REF" "$(hostpath "$ROOT/docker/llama-vulkan")"
docker run --rm ailab/llama-vulkan:local --version

docker volume create ailab-test-llama-cache >/dev/null
cid=""
cleanup() { if [[ -n $cid ]]; then docker rm -f "$cid" >/dev/null; cid=""; fi; }
trap cleanup EXIT
EXTRA=()

serve() { # serve SERVER_ARGS...: start llama-server on $PORT with key "test"
  cleanup
  cid=$(docker run -d -p "127.0.0.1:$PORT:8080" -e LLAMA_API_KEY=test \
    -v ailab-test-llama-cache:/root/.cache/llama.cpp "${EXTRA[@]}" \
    ailab/llama-vulkan:local "$@" --host 0.0.0.0 --port 8080)
  for _ in $(seq 150); do
    if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  docker logs "$cid" 2>&1 | tail -30
  return 1
}
api() { # api PATH [JSON]
  local args=(-fsS --max-time 300 -H 'Authorization: Bearer test')
  if (($# > 1)); then args+=(-H 'Content-Type: application/json' -d "$2"); fi
  curl "${args[@]}" "http://127.0.0.1:$PORT$1"
}

serve -hf "$TINY" --alias tiny --ctx-size 2048
api /infill '{"input_prefix":"def add(a, b):\n    return ","input_suffix":"\n","n_predict":8}' \
  | jq -e '.content | type == "string"' >/dev/null
echo "PASS: /infill"
[[ $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models") == 401 ]]
echo "PASS: API key required (/health stays open)"

mkdir -p "$ROOT/.smoke"
printf 'version = 1\n[*]\nc = 2048\n[alpha]\nhf-repo = %s\n[beta]\nhf-repo = %s\n' "$TINY" "$TINY" \
  >"$ROOT/.smoke/router-test.ini"
EXTRA=(-v "$(hostpath "$ROOT/.smoke/router-test.ini"):/p.ini:ro")
serve --models-preset /p.ini --models-max 1
api /v1/models | jq -e '[.data[].id] | (index("alpha") != null) and (index("beta") != null)' >/dev/null
api /v1/chat/completions '{"model":"beta","messages":[{"role":"user","content":"hi"}],"max_tokens":4}' \
  | jq -e '.choices[0].message.content | type == "string"' >/dev/null
echo "PASS: router mode (catalog + routed chat)"
```

- [ ] **Step 2: Run it to see it fail**

Run: `tests/images/llama-vulkan.sh`
Expected: FAIL at `docker build` (path `docker/llama-vulkan` not found).

- [ ] **Step 3: Write the Dockerfile**

`docker/llama-vulkan/Dockerfile`:

```dockerfile
# llama.cpp for the Arc iGPU (Vulkan), built from the same LLAMA_CPP_REF as
# docker/llama-cuda. llama.cpp's own images are tagged by nightly build number,
# not by release, so they can't be pinned to the release the CUDA image uses.
FROM ubuntu:24.04 AS build

ARG LLAMA_CPP_REF=master

# libssl-dev: -hf downloads go over HTTPS via OpenSSL.
# libvulkan-dev + glslc: the Vulkan backend and its shader compiler.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git cmake build-essential libssl-dev ca-certificates libvulkan-dev glslc \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/ggml-org/llama.cpp /src \
    && git -C /src checkout "${LLAMA_CPP_REF}"

WORKDIR /src
# Same CPU flags as the CUDA image: the 185H has AVX2 + AVX-VNNI, no AVX-512.
RUN cmake -B build \
        -DGGML_VULKAN=ON \
        -DGGML_NATIVE=OFF -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_AVX_VNNI=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DLLAMA_OPENSSL=ON \
        -DCMAKE_BUILD_TYPE=Release \
    # Without OpenSSL cmake only warns and the server can't download models.
    && { grep -q '^OPENSSL_SSL_LIBRARY:FILEPATH=/' build/CMakeCache.txt \
         || { echo "OpenSSL not found: llama-server would have no HTTPS" >&2; exit 1; }; } \
    && cmake --build build -j"$(nproc)" --target llama-server

FROM ubuntu:24.04

# mesa-vulkan-drivers: Intel ANV for the Arc iGPU, and lavapipe for CPU-only tests.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libvulkan1 mesa-vulkan-drivers libssl3t64 libgomp1 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/build/bin/llama-server /usr/local/bin/

ENV LLAMA_CACHE=/root/.cache/llama.cpp
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10m \
    CMD curl -fsS http://localhost:8080/health || exit 1
ENTRYPOINT ["llama-server"]
```

- [ ] **Step 4: Run the test until it passes**

Run: `tests/images/llama-vulkan.sh` (the first build takes 15–30 min).
Expected: three `PASS` lines.
- If cmake reports missing SPIR-V headers, add `spirv-headers` to the build-stage `apt-get install`.
- If `/v1/models` is served without auth in router mode, run the check against `/models` too, and record which path the router protects in the commit message.

- [ ] **Step 5: Commit**

```bash
git add docker/llama-vulkan
git add --chmod=+x tests/images/llama-vulkan.sh
git commit -m "Add llama-vulkan image for the iGPU services, pinned like the CUDA one"
```

---

## Phase 2: Configuration layer

**Skills & tools:** superpowers:test-driven-development; bats; `docker compose config`
**Files:** `installer/lib.sh`, `templates/*`, `host/scripts/gen-env.sh`, `services/ovms/init.sh`, `compose.yaml`, `.env.example`, `installer/stages/storage.sh`, `.github/workflows/ci.yml` (pytest step only), `services/npu-worker/` (delete), `tests/unit/{generate,gen_env,ovms_init,compose}.bats`
**Verification:** `tests/ci-local.sh` passes

### Task 3: Generated config files that respect edits

**Files:**
- Modify: `installer/lib.sh` (after `write_file`)
- Create: `templates/main.ini`, `templates/searxng/settings.yml`, `tests/unit/generate.bats`

**Interfaces:**
- Produces: `GEN_HEADER` (the first line of every template) and `write_generated PATH [MODE] < content`.
  - It writes PATH when it is missing, or when it is unchanged since ailab last wrote it (a sha256 is recorded in `$AILAB_STATE_DIR/generated/`).
  - Otherwise it keeps the file, logs `keeping PATH`, and sets `FILE_CHANGED=0`.

- [ ] **Step 1: Write the failing tests**

`tests/unit/generate.bats`:

```bash
#!/usr/bin/env bats
# write_generated: files people may edit are generated, then left alone once edited.
load helpers

setup() {
  common_setup
  # shellcheck source=../../installer/lib.sh
  source "$REPO/installer/lib.sh"
  F=$T/config/main.ini
}
teardown() { common_teardown; }

@test "writes a missing file" {
  write_generated "$F" <<<"v1"
  [ "$(cat "$F")" = v1 ]
  [ "$FILE_CHANGED" = 1 ]
}

@test "updates a file nobody edited when the template changes" {
  write_generated "$F" <<<"v1"
  write_generated "$F" <<<"v2"
  [ "$(cat "$F")" = v2 ]
}

@test "keeps a file someone edited" {
  write_generated "$F" <<<"v1"
  echo mine >"$F"
  run write_generated "$F" <<<"v2"
  [ "$(cat "$F")" = mine ]
  [[ $output == *"keeping $F"* ]]
}

@test "keeps a file that ailab did not write" {
  mkdir -p "${F%/*}"
  echo theirs >"$F"
  write_generated "$F" <<<"v1"
  [ "$(cat "$F")" = theirs ]
}

@test "a dry run writes and records nothing" {
  DRY_RUN=1
  run write_generated "$F" <<<"v1"
  [ ! -e "$F" ]
  [ ! -d "$AILAB_STATE_DIR/generated" ]
}

@test "the shipped templates start with the generated header" {
  [ "$(head -1 "$REPO/templates/main.ini")" = "$GEN_HEADER" ]
  [ "$(head -1 "$REPO/templates/searxng/settings.yml")" = "$GEN_HEADER" ]
}
```

- [ ] **Step 2: Run to see them fail**

Run: `tests/ci-local.sh bats tests/unit/generate.bats`
Expected: FAIL, `write_generated: command not found`.

- [ ] **Step 3: Implement `write_generated`**

Add to `installer/lib.sh`, directly after `write_file`:

```bash
# write_generated PATH [MODE] < content
# For generated files people may edit (the model catalog, SearXNG settings):
# written when missing or unchanged since ailab last wrote them. A file someone
# edited, or one ailab never wrote, is kept.
GEN_HEADER='# generated by ailab; your edits are kept on re-install (delete this file to get the default back)'
write_generated() {
  local path=$1 mode=${2:-0644} sum_file
  sum_file=$AILAB_STATE_DIR/generated/$(printf '%s' "$path" | tr '/' '_').sha256
  if [[ -f $path ]] && { [[ ! -f $sum_file ]] || [[ $(sha256sum <"$path" | cut -d' ' -f1) != "$(cat "$sum_file")" ]]; }; then
    log "keeping $path (edited, or not written by ailab)"
    cat >/dev/null
    FILE_CHANGED=0
    return 0
  fi
  write_file "$path" "$mode"
  if [[ $DRY_RUN != 1 && $FILE_CHANGED == 1 ]]; then
    mkdir -p "${sum_file%/*}"
    sha256sum <"$path" | cut -d' ' -f1 >"$sum_file"
  fi
}
```

- [ ] **Step 4: Write the templates**

`templates/main.ini`. llama.cpp's preset parser accepts `#` / `;` comments:

```ini
# generated by ailab; your edits are kept on re-install (delete this file to get the default back)
#
# Model catalog for llm-main (llama-server router mode). Each [section] is a
# model; its name is what Open WebUI and IDEs select. Keys are llama-server long
# options without the dashes; [*] applies to every model. --fit sizes GPU layers
# and CPU experts unless you set n-gpu-layers / n-cpu-moe here.
version = 1

[*]
jinja = true
parallel = 2
# Total context, split across the slots: 2 x 32k.
c = 65536

[qwen3.6-35b-a3b]
hf-repo = unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M

[gpt-oss-120b]
hf-repo = ggml-org/gpt-oss-120b-GGUF:MXFP4
```

`templates/searxng/settings.yml`:

```yaml
# generated by ailab; your edits are kept on re-install (delete this file to get the default back)
# SearXNG for Open WebUI's web search. The secret key comes from SEARXNG_SECRET in .env.
use_default_settings: true
server:
  # Only Open WebUI can reach it (compose network), so no rate limiter.
  limiter: false
  image_proxy: false
search:
  # Open WebUI reads JSON; without it SearXNG answers 403.
  formats:
    - html
    - json
```

- [ ] **Step 5: Run to see them pass**

Run: `tests/ci-local.sh bats tests/unit/generate.bats`
Expected: 6 tests `ok`.

- [ ] **Step 5b: Prove the shipped catalog parses in llama-server**

Append to `tests/images/llama-vulkan.sh`. The router lists the catalog without loading anything (autoload off), so nothing is downloaded:

```bash
EXTRA=(-v "$(hostpath "$ROOT/templates/main.ini"):/p.ini:ro")
serve --models-preset /p.ini --models-max 1 --no-models-autoload
api /v1/models | jq -e '[.data[].id] | (index("qwen3.6-35b-a3b") != null) and (index("gpt-oss-120b") != null)' >/dev/null
echo "PASS: templates/main.ini parses (catalog listed, nothing loaded)"
```

Run: `tests/images/llama-vulkan.sh`
Expected: four `PASS` lines. The image is cached from Task 2.

- [ ] **Step 6: Commit**

```bash
git add installer/lib.sh templates tests/unit/generate.bats tests/images/llama-vulkan.sh
git commit -m "Add write_generated and the model catalog / SearXNG templates"
```

### Task 4: Secrets for the API key and SearXNG

**Files:**
- Modify: `host/scripts/gen-env.sh:101-103` (the `WEBUI_SECRET_KEY` block)
- Create: `tests/unit/gen_env.bats`

**Interfaces:**
- Produces: `gen-env.sh --write FILE` fills empty or missing `WEBUI_SECRET_KEY` (64 hex), `LLM_API_KEY` (48 hex) and `SEARXNG_SECRET` (64 hex). It never replaces a set value.

- [ ] **Step 1: Write the failing tests**

`tests/unit/gen_env.bats`:

```bash
#!/usr/bin/env bats
# host/scripts/gen-env.sh against a fake 4-CPU, non-hybrid sysfs.
load helpers

setup() {
  common_setup
  export SYSFS_ROOT=$T/sys DEV_ROOT=$T/dev
  mkdir -p "$SYSFS_ROOT/devices/system/cpu" "$DEV_ROOT"
  echo 0-3 >"$SYSFS_ROOT/devices/system/cpu/online"
  for c in 0 1 2 3; do
    mkdir -p "$SYSFS_ROOT/devices/system/cpu/cpu$c/topology"
    echo "$c" >"$SYSFS_ROOT/devices/system/cpu/cpu$c/topology/thread_siblings_list"
  done
  printf 'WEBUI_SECRET_KEY=\nLLM_API_KEY=\n' >"$T/env"
}
teardown() { common_teardown; }

val() { sed -n "s/^$1=//p" "$T/env"; }

@test "fills empty and missing secrets with random hex" {
  "$REPO/host/scripts/gen-env.sh" --write "$T/env" 2>/dev/null
  [[ $(val WEBUI_SECRET_KEY) =~ ^[0-9a-f]{64}$ ]]
  [[ $(val LLM_API_KEY) =~ ^[0-9a-f]{48}$ ]]
  [[ $(val SEARXNG_SECRET) =~ ^[0-9a-f]{64}$ ]]
}

@test "never replaces a secret that is set" {
  sed -i 's/^LLM_API_KEY=$/LLM_API_KEY=keepme/' "$T/env"
  "$REPO/host/scripts/gen-env.sh" --write "$T/env" 2>/dev/null
  [ "$(val LLM_API_KEY)" = keepme ]
}

@test "writes the cpusets" {
  "$REPO/host/scripts/gen-env.sh" --write "$T/env" 2>/dev/null
  [ "$(val MAIN_CPUSET)" = 0-3 ]
  [ "$(val AUX_CPUSET)" = 0-3 ]
}
```

- [ ] **Step 2: Run to see them fail**

Run: `tests/ci-local.sh bats tests/unit/gen_env.bats`
Expected: test 1 FAILS (`LLM_API_KEY` stays empty, `SEARXNG_SECRET` missing); tests 2–3 pass.

- [ ] **Step 3: Generate all three secrets**

In `host/scripts/gen-env.sh`, replace

```bash
    if grep -q '^WEBUI_SECRET_KEY=$' "$env_file"; then
      sed -i "s|^WEBUI_SECRET_KEY=$|WEBUI_SECRET_KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')|" "$env_file"
    fi
```

with

```bash
    # Secrets: generated once, never replaced. NAME:bytes of randomness.
    local secret bytes
    for secret in WEBUI_SECRET_KEY:32 LLM_API_KEY:24 SEARXNG_SECRET:32; do
      bytes=${secret#*:}
      secret=${secret%%:*}
      grep -q "^$secret=" "$env_file" || echo "$secret=" >>"$env_file"
      if grep -q "^$secret=$" "$env_file"; then
        sed -i "s|^$secret=$|$secret=$(head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n')|" "$env_file"
      fi
    done
```

- [ ] **Step 4: Run to see them pass**

Run: `tests/ci-local.sh bats tests/unit/gen_env.bats`
Expected: 3 tests `ok`.

- [ ] **Step 5: Commit**

```bash
git add host/scripts/gen-env.sh tests/unit/gen_env.bats
git commit -m "gen-env: generate LLM_API_KEY and SEARXNG_SECRET once"
```

### Task 5: `ovms-init` entrypoint

**Files:**
- Create: `services/ovms/init.sh`, `tests/unit/ovms_init.bats`

**Interfaces:**
- Consumes: env `OVMS_EMBED_DEVICE`, `OVMS_RERANK_DEVICE`, `OVMS_STT_DEVICE`, `OVMS_TTS_DEVICE`; overridable `OVMS_BIN` (default `/ovms/bin/ovms`) and `MODEL_REPO` (default `/models`).
- Produces:
  - `$MODEL_REPO/config.json`, registering `embed`, `rerank`, `whisper` and `kokoro`.
  - `$MODEL_REPO/<source id>/.ailab-device` markers.

- [ ] **Step 1: Write the failing tests**

`tests/unit/ovms_init.bats`:

```bash
#!/usr/bin/env bats
# services/ovms/init.sh with a fake ovms binary.
load helpers

setup() {
  common_setup
  # Fake ovms: on --pull, create the model directory the real one would.
  stub ovms '
for ((i = 1; i <= $#; i++)); do
  case ${!i} in
    --source_model) j=$((i + 1)); src=${!j} ;;
    --model_repository_path) j=$((i + 1)); repo=${!j} ;;
  esac
done
if [[ -n ${src:-} && -n ${repo:-} ]]; then mkdir -p "$repo/$src"; fi'
  export OVMS_BIN=$STUBS/ovms MODEL_REPO=$T/models
  export OVMS_EMBED_DEVICE=NPU OVMS_RERANK_DEVICE=NPU OVMS_STT_DEVICE=NPU OVMS_TTS_DEVICE=CPU
}
teardown() { common_teardown; }

pulls() { grep -- '--pull' "$STUB_LOG"; }

@test "first run pulls the four models on their devices and registers them" {
  run "$REPO/services/ovms/init.sh"
  [ "$status" -eq 0 ]
  [ "$(pulls | wc -l)" -eq 4 ]
  pulls | grep -q -- "--source_model OpenVINO/Qwen3-Embedding-0.6B-fp16-ov --model_repository_path $T/models --task embeddings --target_device NPU --pooling LAST --max_length 2048"
  pulls | grep -q -- "--source_model OpenVINO/Qwen3-Reranker-0.6B-seq-cls-fp16-ov --model_repository_path $T/models --task rerank --target_device NPU --max_length 2048"
  pulls | grep -q -- "--source_model OpenVINO/whisper-base-fp16-ov --model_repository_path $T/models --task speech2text --target_device NPU"
  pulls | grep -q -- "--source_model OpenVINO/Kokoro-82M-int8-ov --model_repository_path $T/models --task text2speech --target_device CPU"
  [ "$(grep -c -- '--add_to_config' "$STUB_LOG")" -eq 4 ]
  grep -q -- "--add_to_config --config_path $T/models/config.json --model_name kokoro --model_path $T/models/OpenVINO/Kokoro-82M-int8-ov" "$STUB_LOG"
  ! grep -q -- '--overwrite_models' "$STUB_LOG"
  [ "$(cat "$T/models/OpenVINO/Kokoro-82M-int8-ov/.ailab-device")" = CPU ]
}

@test "a second run with the same devices regenerates nothing" {
  "$REPO/services/ovms/init.sh" >/dev/null
  : >"$STUB_LOG"
  "$REPO/services/ovms/init.sh" >/dev/null
  ! grep -q -- '--overwrite_models' "$STUB_LOG"
}

@test "a device change regenerates only that model" {
  "$REPO/services/ovms/init.sh" >/dev/null
  : >"$STUB_LOG"
  export OVMS_EMBED_DEVICE=CPU
  run "$REPO/services/ovms/init.sh"
  [ "$(grep -c -- '--overwrite_models' "$STUB_LOG")" -eq 1 ]
  grep -- '--overwrite_models' "$STUB_LOG" | grep -q 'Qwen3-Embedding'
  [[ $output == *"embed: device NPU -> CPU, regenerating"* ]]
  [ "$(cat "$T/models/OpenVINO/Qwen3-Embedding-0.6B-fp16-ov/.ailab-device")" = CPU ]
}

@test "config.json starts empty on every run, so removed models disappear" {
  mkdir -p "$T/models"
  echo stale >"$T/models/config.json"
  "$REPO/services/ovms/init.sh" >/dev/null
  [ "$(tr -d ' \n' <"$T/models/config.json")" = '{"model_config_list":[]}' ]
}
```

- [ ] **Step 2: Run to see them fail**

Run: `tests/ci-local.sh bats tests/unit/ovms_init.bats`
Expected: FAIL, `services/ovms/init.sh: No such file or directory`.

- [ ] **Step 3: Implement**

`services/ovms/init.sh`:

```bash
#!/usr/bin/env bash
# ovms-init: download the OVMS models once and rewrite /models/config.json.
# Runs in the openvino/model_server image before the ovms service starts.
# A model is pulled again (--overwrite_models) only when its device changed,
# so OVMS_<X>_DEVICE=CPU in .env + `ailab edit` moves a model off the NPU.
set -euo pipefail

OVMS=${OVMS_BIN:-/ovms/bin/ovms}
REPO=${MODEL_REPO:-/models}
CONFIG=$REPO/config.json

# name|source|task|device|extra pull options
models() {
  cat <<EOF
embed|OpenVINO/Qwen3-Embedding-0.6B-fp16-ov|embeddings|${OVMS_EMBED_DEVICE:-NPU}|--pooling LAST --max_length 2048
rerank|OpenVINO/Qwen3-Reranker-0.6B-seq-cls-fp16-ov|rerank|${OVMS_RERANK_DEVICE:-NPU}|--max_length 2048
whisper|OpenVINO/whisper-base-fp16-ov|speech2text|${OVMS_STT_DEVICE:-NPU}|
kokoro|OpenVINO/Kokoro-82M-int8-ov|text2speech|${OVMS_TTS_DEVICE:-CPU}|
EOF
}

mkdir -p "$REPO/cache"
# The served-model list is rebuilt every start; downloaded weights stay.
echo '{"model_config_list": []}' >"$CONFIG"

while IFS='|' read -r name source task device extra; do
  path=$REPO/$source
  marker=$path/.ailab-device
  args=(--pull --source_model "$source" --model_repository_path "$REPO" --task "$task" --target_device "$device")
  # shellcheck disable=SC2206 # extra holds space-separated flags
  if [[ -n $extra ]]; then args+=($extra); fi
  if [[ -f $marker && $(cat "$marker") != "$device" ]]; then
    echo "ovms-init: $name: device $(cat "$marker") -> $device, regenerating"
    args+=(--overwrite_models)
  fi
  "$OVMS" "${args[@]}"
  echo "$device" >"$marker"
  "$OVMS" --add_to_config --config_path "$CONFIG" --model_name "$name" --model_path "$path"
done < <(models)
echo "ovms-init: models ready in $CONFIG"
```

- [ ] **Step 4: Run to see them pass**

Run: `tests/ci-local.sh bats tests/unit/ovms_init.bats`
Expected: 4 tests `ok`.

- [ ] **Step 5: Check the flags against the real image**

Run:

```bash
docker run --rm --entrypoint /bin/bash openvino/model_server:2026.4.0-gpu -c "ls -l /ovms/bin/ovms; /ovms/bin/ovms --help 2>&1 | grep -E -- '--(pull|add_to_config|pooling|max_length|cache_dir|overwrite_models|target_device|task|model_repository_path)'"
```

Expected: `/ovms/bin/ovms` exists and every flag is listed.
- If the binary lives elsewhere, change `OVMS_BIN`'s default.
- If a flag has another name, fix `init.sh` and the test, keeping the test's expected strings in step with the code.

- [ ] **Step 6: Commit**

```bash
git add tests/unit/ovms_init.bats
git add --chmod=+x services/ovms/init.sh
git commit -m "Add ovms-init: pull OVMS models once, regenerate a model on device change"
```

### Task 6: New compose stack and settings; remove npu-worker

**Files:**
- Rewrite: `compose.yaml`, `.env.example`
- Modify: `installer/stages/storage.sh:92` (`models/openvino` → `models/ovms`), `.github/workflows/ci.yml` (delete the `setup-python` and `npu-worker tests` steps)
- Delete: `services/npu-worker/`
- Create: `tests/unit/compose.bats`

**Interfaces:**
- Consumes: the image from Task 2, `services/ovms/init.sh` (Task 5), `config/main.ini` and `config/searxng/` (generated in Task 8), secrets from Task 4.
- Produces:
  - Service names `llm-main`, `llm-aux`, `llm-fim`, `ovms-init`, `ovms`, `searxng`, `open-webui` (plus the `anythingllm` profile). Compose project `ailab`, so the volume is `ailab_open-webui`.
  - The `.env` keys listed in the `.env.example` below.

- [ ] **Step 1: Write the failing tests**

`tests/unit/compose.bats`:

```bash
#!/usr/bin/env bats
# compose.yaml rendered with .env.example: the wiring the spec requires.
load helpers

setup_file() {
  export CFG=$BATS_FILE_TMPDIR/config.json
  local env=$BATS_FILE_TMPDIR/env
  cp "$REPO/.env.example" "$env"
  sed -i -e 's/^MAIN_CPUSET=$/MAIN_CPUSET=0-3/' -e 's/^AUX_CPUSET=$/AUX_CPUSET=0-3/' \
    -e 's/^RENDER_GID=$/RENDER_GID=109/' -e 's/^LLM_API_KEY=$/LLM_API_KEY=testkey/' \
    -e 's/^WEBUI_SECRET_KEY=$/WEBUI_SECRET_KEY=s/' -e 's/^SEARXNG_SECRET=$/SEARXNG_SECRET=s/' "$env"
  compose_cmd --project-directory "$REPO" -f "$REPO/compose.yaml" --env-file "$env" \
    config --format json >"$CFG"
}

q() { jq -r "$1" "$CFG"; }

@test "the service set; npu-worker is gone" {
  [ "$(q '.services | keys | join(" ")')" = "llm-aux llm-fim llm-main open-webui ovms ovms-init searxng" ]
}

@test "llm-main runs the router with no hand-tuned offload" {
  cmd=$(q '.services["llm-main"].command | join(" ")')
  [[ $cmd == *"--models-preset /config/main.ini"* && $cmd == *"--models-max 1"* ]]
  [[ $cmd == *"--sleep-idle-seconds 1800"* ]]
  [[ $cmd != *--n-cpu-moe* && $cmd != *--n-gpu-layers* && $cmd != *-hf* ]]
}

@test "the API key reaches every llama server through the environment only" {
  for s in llm-main llm-aux llm-fim; do
    [ "$(q ".services[\"$s\"].environment.LLAMA_API_KEY")" = testkey ]
    [[ $(q ".services[\"$s\"].command | join(\" \")") != *testkey* ]]
  done
}

@test "only the web UI is published beyond localhost" {
  run q '.services | to_entries[] | select(.key != "open-webui") | (.value.ports // [])[] | .host_ip'
  [ -n "$output" ]
  for ip in $output; do [ "$ip" = 127.0.0.1 ]; done
}

@test "Open WebUI is wired to the routers, OVMS and SearXNG" {
  e() { q ".services[\"open-webui\"].environment[\"$1\"]"; }
  [ "$(e OPENAI_API_BASE_URLS)" = "http://llm-main:8080/v1;http://llm-aux:8080/v1" ]
  [ "$(e OPENAI_API_KEYS)" = "testkey;testkey" ]
  [ "$(e DEFAULT_MODELS)" = qwen3.6-35b-a3b ]
  [ "$(e TASK_MODEL_EXTERNAL)" = qwen3-4b ]
  [ "$(e RAG_OPENAI_API_BASE_URL)" = http://ovms:8000/v3 ]
  [ "$(e RAG_EMBEDDING_MODEL)" = embed ]
  [ "$(e ENABLE_RAG_HYBRID_SEARCH)" = true ]
  [ "$(e RAG_RERANKING_ENGINE)" = external ]
  [ "$(e RAG_EXTERNAL_RERANKER_URL)" = http://ovms:8000/v3/rerank ]
  [ "$(e RAG_RERANKING_MODEL)" = rerank ]
  [ "$(e AUDIO_STT_MODEL)" = whisper ]
  [ "$(e AUDIO_TTS_MODEL)" = kokoro ]
  [ "$(e ENABLE_WEB_SEARCH)" = true ]
  [ "$(e WEB_SEARCH_ENGINE)" = searxng ]
  [ "$(e SEARXNG_QUERY_URL)" = "http://searxng:8080/search?q=<query>" ]
  [ "$(e DEFAULT_USER_ROLE)" = pending ]
}

@test "Open WebUI never connects to the tab-completion server" {
  [[ $(q '.services["open-webui"].environment | tostring') != *llm-fim* ]]
}

@test "ovms waits for ovms-init and is recreated when a device changes" {
  [ "$(q '.services.ovms.depends_on["ovms-init"].condition')" = service_completed_successfully ]
  [ "$(q '.services.ovms.environment.OVMS_EMBED_DEVICE')" = NPU ]
  [ "$(q '.services["ovms-init"].environment.OVMS_TTS_DEVICE')" = CPU ]
}

@test "images are pinned to the tested versions" {
  [ "$(q '.services["open-webui"].image')" = ghcr.io/open-webui/open-webui:v0.11.4 ]
  [ "$(q '.services.ovms.image')" = openvino/model_server:2026.4.0-gpu ]
  [ "$(q '.services.searxng.image')" = searxng/searxng:2026.9.25-12f8b6515 ]
  [ "$(q '.services["llm-main"].build.args.LLAMA_CPP_REF')" = v0.5.0 ]
  [ "$(q '.services["llm-aux"].build.args.LLAMA_CPP_REF')" = v0.5.0 ]
}
```

- [ ] **Step 2: Run to see them fail**

Run: `tests/ci-local.sh bats tests/unit/compose.bats`
Expected: FAIL. The rendered services still include `npu-worker`, and `LLM_API_KEY` is not a key in `.env.example`.

- [ ] **Step 3: Rewrite `.env.example`**

```
# Copy to .env, then run:  host/scripts/gen-env.sh --write .env
# The installer does both. Values marked (auto) are filled in by gen-env.sh.

# --- Host topology (auto) ---------------------------------------------------
# P-core logical CPUs (both hyperthreads) for the main LLM.
MAIN_CPUSET=
# One decode thread per physical P-core; batch/prefill may use the siblings too.
MAIN_THREADS=6
MAIN_THREADS_BATCH=12
# E-cores (not LP E-cores) for everything else.
AUX_CPUSET=
# Group that owns /dev/dri/renderD* and /dev/accel/accel0, and the Intel render node.
RENDER_GID=
INTEL_RENDER_NODE=/dev/dri/renderD128

# --- Secrets (auto: generated once, never replaced) ------------------------
WEBUI_SECRET_KEY=
# Checked by llm-main, llm-aux and llm-fim; IDEs use it too (ailab connect).
LLM_API_KEY=
SEARXNG_SECRET=

# --- Network exposure -------------------------------------------------------
# Model APIs stay on localhost; Tailscale serve is the way in from other devices.
BIND_ADDR=127.0.0.1
WEBUI_BIND_ADDR=0.0.0.0
WEBUI_PORT=3000
ANYTHINGLLM_PORT=3001
# Open WebUI's HTTPS address on the tailnet (the installer's tailscale stage sets it).
WEBUI_URL=

# --- Versions: tested together by tests/smoke; `ailab update` moves them ----
LLAMA_CPP_REF=v0.5.0
CUDA_ARCH=120
OPEN_WEBUI_TAG=v0.11.4
OVMS_TAG=2026.4.0-gpu
SEARXNG_TAG=2026.9.25-12f8b6515
ANYTHINGLLM_TAG=latest

# --- Main router (RTX 5060 Ti + DDR5) ---------------------------------------
# The model catalog is config/main.ini (from templates/main.ini; edit freely).
# An idle model is put to sleep after this many seconds.
MAIN_SLEEP_IDLE_SECONDS=1800
MAIN_EXTRA_ARGS=

# --- Arc iGPU models ----------------------------------------------------------
# Task model for Open WebUI: titles, tags, search queries.
AUX_MODEL=unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M
AUX_CTX=16384
AUX_PARALLEL=2
AUX_EXTRA_ARGS=
# Tab completion for IDEs: a fill-in-the-middle base model, not an instruct one.
FIM_MODEL=ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF
FIM_CTX=8192

# --- NPU services (OpenVINO Model Server): NPU or CPU per model ------------
# A model that fails on the NPU: set it to CPU; `ailab edit` applies it.
OVMS_EMBED_DEVICE=NPU
OVMS_RERANK_DEVICE=NPU
OVMS_STT_DEVICE=NPU
OVMS_TTS_DEVICE=CPU
# Kokoro voice for spoken replies.
TTS_VOICE=af_heart

# --- Paths / profiles ----------------------------------------------------------
# Model weights and caches (installer: <DATA_ROOT>/models).
MODELS_DIR=./models
HF_TOKEN=
# Optional services, comma separated: anythingllm
COMPOSE_PROFILES=
```

- [ ] **Step 4: Rewrite `compose.yaml`**

```yaml
# AI Lab: local AI stack for Core Ultra 9 185H + RTX 5060 Ti + 96 GB DDR5.
#
# Installed and run by ./install.sh (docs/INSTALL.md), which writes .env and
# config/ and starts this under ailab.service. By hand:
#   cp .env.example .env && host/scripts/gen-env.sh --write .env
#   mkdir -p config/searxng && cp templates/main.ini config/
#   cp templates/searxng/settings.yml config/searxng/
#   docker compose up -d
#
# Silicon map (docs/ARCHITECTURE.md):
#   llm-main    RTX 5060 Ti + DDR5: router over config/main.ini   P-cores
#   llm-aux     Arc iGPU: task model (titles, tags, queries)       E-cores
#   llm-fim     Arc iGPU: tab completion for IDEs                  E-cores
#   ovms        NPU: embeddings, reranker, Whisper; CPU: TTS       E-cores
#   searxng     private web search                                E-cores
#   open-webui  UI, accounts, documents, tools                    E-cores

name: ailab

x-e-cores: &e-cores
  cpuset: ${AUX_CPUSET:?run host/scripts/gen-env.sh}

x-logging: &logging
  logging:
    driver: json-file
    options: {max-size: "20m", max-file: "3"}

x-llama-env: &llama-env
  LLAMA_CACHE: /root/.cache/llama.cpp
  # Checked on every request except /health; never on the command line.
  LLAMA_API_KEY: ${LLM_API_KEY:?run host/scripts/gen-env.sh}
  HF_TOKEN: ${HF_TOKEN:-}

x-igpu: &igpu
  build:
    context: docker/llama-vulkan
    args:
      LLAMA_CPP_REF: ${LLAMA_CPP_REF:?pin LLAMA_CPP_REF in .env}
  image: ailab/llama-vulkan:local
  restart: unless-stopped
  # Only the Intel render node is mapped, so Vulkan can't pick the NVIDIA card.
  devices:
    - ${INTEL_RENDER_NODE:-/dev/dri/renderD128}:/dev/dri/renderD128
  group_add:
    - "${RENDER_GID:?run host/scripts/gen-env.sh}"
  volumes:
    - ${MODELS_DIR:-./models}/llama.cpp:/root/.cache/llama.cpp
    - ${MODELS_DIR:-./models}/huggingface:/root/.cache/huggingface
  environment: *llama-env

x-ovms-devices: &ovms-devices
  # Set on ovms too, so a device change recreates it after ovms-init re-runs.
  OVMS_EMBED_DEVICE: ${OVMS_EMBED_DEVICE:-NPU}
  OVMS_RERANK_DEVICE: ${OVMS_RERANK_DEVICE:-NPU}
  OVMS_STT_DEVICE: ${OVMS_STT_DEVICE:-NPU}
  OVMS_TTS_DEVICE: ${OVMS_TTS_DEVICE:-CPU}

services:
  llm-main:
    build:
      context: docker/llama-cuda
      args:
        LLAMA_CPP_REF: ${LLAMA_CPP_REF:?pin LLAMA_CPP_REF in .env}
        CUDA_ARCH: ${CUDA_ARCH:-120}
    image: ailab/llama-cuda:local
    restart: unless-stopped
    <<: *logging
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    # Decode threads must all run at P-core speed or every layer waits on the slowest thread.
    cpuset: ${MAIN_CPUSET:?run host/scripts/gen-env.sh}
    ulimits:
      memlock: -1
    volumes:
      - ${MODELS_DIR:-./models}/llama.cpp:/root/.cache/llama.cpp
      - ${MODELS_DIR:-./models}/huggingface:/root/.cache/huggingface
      - ./config/main.ini:/config/main.ini:ro
    environment: *llama-env
    # No model on the command line: router mode over the catalog in
    # config/main.ini, one model loaded at a time. --fit (on by default) sizes
    # GPU layers and CPU experts per model.
    command: >-
      --models-preset /config/main.ini
      --models-max 1
      --sleep-idle-seconds ${MAIN_SLEEP_IDLE_SECONDS:-1800}
      --threads ${MAIN_THREADS:-6}
      --threads-batch ${MAIN_THREADS_BATCH:-12}
      --host 0.0.0.0 --port 8080
      ${MAIN_EXTRA_ARGS:-}
    ports:
      - "${BIND_ADDR:-127.0.0.1}:8081:8080"

  llm-aux:
    <<: [*igpu, *e-cores, *logging]
    command: >-
      -hf ${AUX_MODEL:-unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M}
      --alias qwen3-4b
      --n-gpu-layers 999
      --ctx-size ${AUX_CTX:-16384}
      --parallel ${AUX_PARALLEL:-2}
      --jinja
      --host 0.0.0.0 --port 8080
      ${AUX_EXTRA_ARGS:-}
    ports:
      - "${BIND_ADDR:-127.0.0.1}:8082:8080"

  llm-fim:
    <<: [*igpu, *e-cores, *logging]
    # Tab completion. Open WebUI never connects here, so it stays out of the chat list.
    command: >-
      -hf ${FIM_MODEL:-ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF}
      --alias qwen2.5-coder-1.5b
      --n-gpu-layers 999
      --ctx-size ${FIM_CTX:-8192}
      --ubatch-size 1024 --batch-size 1024
      --cache-reuse 256
      --host 0.0.0.0 --port 8080
    ports:
      - "${BIND_ADDR:-127.0.0.1}:8084:8080"

  ovms-init:
    image: openvino/model_server:${OVMS_TAG:?pin OVMS_TAG in .env}
    <<: [*e-cores, *logging]
    user: "0:0"
    entrypoint: ["/bin/bash", "/init.sh"]
    volumes:
      - ${MODELS_DIR:-./models}/ovms:/models
      - ./services/ovms/init.sh:/init.sh:ro
    environment:
      <<: *ovms-devices
      HF_TOKEN: ${HF_TOKEN:-}

  ovms:
    image: openvino/model_server:${OVMS_TAG:?pin OVMS_TAG in .env}
    restart: unless-stopped
    <<: [*e-cores, *logging]
    user: "0:0"
    depends_on:
      ovms-init:
        condition: service_completed_successfully
    command: --config_path /models/config.json --rest_port 8000 --cache_dir /models/cache
    devices:
      - /dev/accel:/dev/accel
    group_add:
      - "${RENDER_GID:?run host/scripts/gen-env.sh}"
    volumes:
      - ${MODELS_DIR:-./models}/ovms:/models
    environment: *ovms-devices
    ports:
      - "${BIND_ADDR:-127.0.0.1}:8083:8000"

  searxng:
    image: searxng/searxng:${SEARXNG_TAG:?pin SEARXNG_TAG in .env}
    restart: unless-stopped
    <<: [*e-cores, *logging]
    volumes:
      - ./config/searxng:/etc/searxng
    environment:
      SEARXNG_SECRET: ${SEARXNG_SECRET:?run host/scripts/gen-env.sh}
      SEARXNG_BASE_URL: http://searxng:8080/

  open-webui:
    image: ghcr.io/open-webui/open-webui:${OPEN_WEBUI_TAG:?pin OPEN_WEBUI_TAG in .env}
    restart: unless-stopped
    <<: [*e-cores, *logging]
    depends_on: [llm-main, llm-aux, ovms, searxng]
    volumes:
      - open-webui:/app/backend/data
    # Most of these seed Open WebUI's database on its first start; afterwards
    # Admin Settings owns them (docs/INSTALL.md, "Changing settings").
    environment:
      WEBUI_SECRET_KEY: ${WEBUI_SECRET_KEY:?run host/scripts/gen-env.sh}
      WEBUI_URL: ${WEBUI_URL:-http://localhost:3000}
      ENABLE_SIGNUP: "true"
      DEFAULT_USER_ROLE: pending
      ENABLE_OLLAMA_API: "false"
      OPENAI_API_BASE_URLS: http://llm-main:8080/v1;http://llm-aux:8080/v1
      OPENAI_API_KEYS: ${LLM_API_KEY};${LLM_API_KEY}
      DEFAULT_MODELS: qwen3.6-35b-a3b
      TASK_MODEL_EXTERNAL: qwen3-4b
      # Documents: NPU embeddings, hybrid (keyword + vector) search, NPU reranker
      RAG_EMBEDDING_ENGINE: openai
      RAG_OPENAI_API_BASE_URL: http://ovms:8000/v3
      RAG_OPENAI_API_KEY: none
      RAG_EMBEDDING_MODEL: embed
      ENABLE_RAG_HYBRID_SEARCH: "true"
      RAG_RERANKING_ENGINE: external
      RAG_EXTERNAL_RERANKER_URL: http://ovms:8000/v3/rerank
      RAG_RERANKING_MODEL: rerank
      # Voice: Whisper in (NPU), Kokoro out (CPU)
      AUDIO_STT_ENGINE: openai
      AUDIO_STT_OPENAI_API_BASE_URL: http://ovms:8000/v3
      AUDIO_STT_OPENAI_API_KEY: none
      AUDIO_STT_MODEL: whisper
      AUDIO_TTS_ENGINE: openai
      AUDIO_TTS_OPENAI_API_BASE_URL: http://ovms:8000/v3
      AUDIO_TTS_OPENAI_API_KEY: none
      AUDIO_TTS_MODEL: kokoro
      AUDIO_TTS_VOICE: ${TTS_VOICE:-af_heart}
      # Web search
      ENABLE_WEB_SEARCH: "true"
      WEB_SEARCH_ENGINE: searxng
      SEARXNG_QUERY_URL: http://searxng:8080/search?q=<query>
      # Tools: native function calling is the default; code runs in the browser
      ENABLE_CODE_INTERPRETER: "true"
    ports:
      - "${WEBUI_BIND_ADDR:-0.0.0.0}:${WEBUI_PORT:-3000}:8080"

  anythingllm:
    profiles: [anythingllm]
    image: mintplexlabs/anythingllm:${ANYTHINGLLM_TAG:-latest}
    restart: unless-stopped
    <<: [*e-cores, *logging]
    depends_on: [llm-main, ovms]
    cap_add: [SYS_ADMIN]
    volumes:
      - anythingllm:/app/server/storage
    environment:
      STORAGE_DIR: /app/server/storage
      LLM_PROVIDER: generic-openai
      GENERIC_OPEN_AI_BASE_PATH: http://llm-main:8080/v1
      GENERIC_OPEN_AI_MODEL_PREF: qwen3.6-35b-a3b
      GENERIC_OPEN_AI_MODEL_TOKEN_LIMIT: "32768"
      GENERIC_OPEN_AI_API_KEY: ${LLM_API_KEY}
      EMBEDDING_ENGINE: generic-openai
      EMBEDDING_BASE_PATH: http://ovms:8000/v3
      EMBEDDING_MODEL_PREF: embed
      GENERIC_OPEN_AI_EMBEDDING_API_KEY: none
      VECTOR_DB: lancedb
    ports:
      - "${WEBUI_BIND_ADDR:-0.0.0.0}:${ANYTHINGLLM_PORT:-3001}:3001"

volumes:
  open-webui:
  anythingllm:
```

- [ ] **Step 5: Remove the old worker and its CI step; rename the OVMS model dir**

```bash
git rm -r -q services/npu-worker
```

- In `.github/workflows/ci.yml`, delete the `actions/setup-python@v5` step and the `npu-worker tests` step.
- In `installer/stages/storage.sh`, change `"$DATA_ROOT/models/openvino"` to `"$DATA_ROOT/models/ovms"`.

- [ ] **Step 6: Run the whole suite**

Run: `tests/ci-local.sh`
Expected: compose.bats 8 `ok`, and all other tests still pass. Then `all checks passed`.

- [ ] **Step 7: Commit (two commits: the hook blocks staging `.env.example`)**

```bash
git add compose.yaml installer/stages/storage.sh .github tests/unit/compose.bats
git commit -m "Compose: router, iGPU and FIM servers, OVMS, SearXNG; drop npu-worker"
```

Then ask Jordan to run, in his own terminal:

```bash
git add .env.example && git commit -m "Env template for the daily-driver stack"
```

---

## Phase 3: Integration gate (CPU smoke test)

**Skills & tools:** superpowers:test-driven-development (the smoke test is written before its fixes); superpowers:systematic-debugging for each failure; claude-forge:agency-routing for container logs over 50 KB; the pinned images themselves as the primary source for names (grep their code). Use WebFetch only if an image can't answer.
**Files:** `host/scripts/check-features.sh`, `tests/assets/hello.wav`, `tests/assets/doc.txt`, `tests/smoke/{compose.smoke.yaml,main.ini,run.sh,in-dind.sh}`
**Verification:** `tests/smoke/in-dind.sh` ends with `SMOKE TEST PASSED`

### Task 7: Feature checks and the CPU smoke test

**Files:**
- Create: `host/scripts/check-features.sh`, `tests/assets/hello.wav`, `tests/assets/doc.txt`, `tests/smoke/compose.smoke.yaml`, `tests/smoke/main.ini`, `tests/smoke/run.sh`, `tests/smoke/in-dind.sh`

**Interfaces:**
- Consumes: the services from Task 6 (ports and model names in Global Constraints), and `env_get` / `env_set` / `ok` / `die` / `stage` from `installer/lib.sh`.
- Produces:
  - `host/scripts/check-features.sh [--env FILE] [--strict]`. It exits 1 on a failed check. A service that isn't up yet is a WARN unless `--strict`. It reads `COMPOSE_PROJECT_NAME` (default `ailab`) to reach `<project>-open-webui-1`.
  - `tests/smoke/run.sh` (Linux Docker host) and `tests/smoke/in-dind.sh` (Docker Desktop).

- [ ] **Step 1: Make the test assets**

`tests/assets/doc.txt`:

```
Lab notes for the smoke test.
The smoke-test password is PURPLE-ELEPHANT-42.
The lab's main model runs on the RTX 5060 Ti with its experts in system RAM.
```

`tests/assets/hello.wav` is real speech from the Windows speech synthesizer, 16 kHz mono. Run in PowerShell from the repo root:

```powershell
Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
$s.SetOutputToWaveFile("$PWD\tests\assets\hello.wav", $fmt)
$s.Speak("Hello world. This is the lab speaking.")
$s.Dispose()
```

Expected: `tests/assets/hello.wav`, about 80–120 KB.

- [ ] **Step 2: Write the feature checks**

`host/scripts/check-features.sh`:

```bash
#!/usr/bin/env bash
# Feature checks against the running stack: each model API, the OVMS models,
# web search and the web UI. Read-only.
#   host/scripts/check-features.sh [--env FILE] [--strict]
# A service that is not up yet (the first start downloads models) is a WARN
# unless --strict. Exit 1 if any check failed.
# pass/warn/fail always succeed, so `cond && pass || fail` is safe here.
# shellcheck disable=SC2015
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ENV_FILE=$ROOT/.env
STRICT=0
while (($#)); do
  case $1 in
    --env) ENV_FILE=${2:?--env needs a file}; shift ;;
    --strict) STRICT=1 ;;
    *) echo "usage: $0 [--env FILE] [--strict]" >&2; exit 2 ;;
  esac
  shift
done

envval() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -1; }
KEY=$(envval LLM_API_KEY)
VOICE=$(envval TTS_VOICE)
PROJECT=${COMPOSE_PROJECT_NAME:-ailab}
MAIN=http://127.0.0.1:8081
AUX=http://127.0.0.1:8082
OVMS=http://127.0.0.1:8083
FIM=http://127.0.0.1:8084
webui_port=$(envval WEBUI_PORT)
WEBUI=http://127.0.0.1:${webui_port:-3000}

fails=0 pending=0
pass() { printf '  \e[32mPASS\e[0m %s\n' "$*"; }
warn() { printf '  \e[33mWARN\e[0m %s\n' "$*"; }
fail() { printf '  \e[31mFAIL\e[0m %s\n' "$*"; fails=$((fails + 1)); }
section() { printf '\n%s\n' "$*"; }
not_ready() {
  if ((STRICT)); then
    fail "$1 not answering"
  else
    warn "$1 not answering yet (the first start downloads models: ailab logs $1)"
    pending=$((pending + 1))
  fi
}
up() { curl -fsS --max-time 5 -o /dev/null "$1" 2>/dev/null; }
api() { # api URL [JSON]: GET, or POST when JSON is given, with the API key
  local args=(-fsS --max-time "${TIMEOUT:-300}" -H "Authorization: Bearer $KEY")
  if (($# > 1)); then args+=(-H 'Content-Type: application/json' -d "$2"); fi
  curl "${args[@]}" "$1"
}
ovms_post() { curl -fsS --max-time 120 -H 'Content-Type: application/json' "$OVMS$1" -d "$2"; }
hint() { printf '%s on %s failed; to move it to the CPU set %s=CPU in .env and run: ailab edit' "$1" "$(envval "$2")" "$2"; }

section "Model servers"
if up "$MAIN/health"; then
  ids=$(api "$MAIN/v1/models" | jq -r '.data[].id' 2>/dev/null)
  for m in qwen3.6-35b-a3b gpt-oss-120b; do
    grep -qx "$m" <<<"$ids" && pass "llm-main catalog has $m" || fail "llm-main catalog lacks $m (config/main.ini)"
  done
  [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$MAIN/v1/models") == 401 ]] \
    && pass "llm-main rejects requests without the API key" || fail "llm-main answers without the API key"
else
  not_ready llm-main
fi
if up "$AUX/health"; then
  api "$AUX/v1/chat/completions" '{"model":"qwen3-4b","messages":[{"role":"user","content":"Say OK"}],"max_tokens":8}' \
    | jq -e '.choices[0].message.content | type == "string"' >/dev/null \
    && pass "llm-aux (qwen3-4b) answers" || fail "llm-aux chat failed"
else
  not_ready llm-aux
fi
if up "$FIM/health"; then
  api "$FIM/infill" '{"input_prefix":"def add(a, b):\n    return ","input_suffix":"\n","n_predict":8}' \
    | jq -e '.content | type == "string"' >/dev/null \
    && pass "llm-fim /infill answers" || fail "llm-fim /infill failed"
else
  not_ready llm-fim
fi

section "NPU services (OVMS)"
if up "$OVMS/v2/health/ready"; then
  ovms_post /v3/embeddings '{"model":"embed","input":"hello"}' \
    | jq -e '.data[0].embedding | length > 0' >/dev/null \
    && pass "embed ($(envval OVMS_EMBED_DEVICE))" || fail "$(hint embed OVMS_EMBED_DEVICE)"
  ovms_post /v3/rerank '{"model":"rerank","query":"capital of France","documents":["Paris is the capital of France.","Bananas are yellow."]}' \
    | jq -e '.results | length == 2' >/dev/null \
    && pass "rerank ($(envval OVMS_RERANK_DEVICE))" || fail "$(hint rerank OVMS_RERANK_DEVICE)"
  curl -fsS --max-time 120 -F "file=@$ROOT/tests/assets/hello.wav" -F model=whisper "$OVMS/v3/audio/transcriptions" \
    | jq -e '.text | ascii_downcase | contains("hello")' >/dev/null \
    && pass "whisper ($(envval OVMS_STT_DEVICE))" || fail "$(hint whisper OVMS_STT_DEVICE)"
  bytes=$(ovms_post /v3/audio/speech "$(jq -nc --arg v "$VOICE" '{model: "kokoro", input: "Hello from the lab.", voice: $v}')" | wc -c)
  ((bytes > 1000)) && pass "kokoro ($(envval OVMS_TTS_DEVICE), voice $VOICE)" || fail "$(hint kokoro OVMS_TTS_DEVICE)"
else
  not_ready ovms
fi

section "Search and UI"
if up "$WEBUI/health"; then
  pass "open-webui up"
  docker exec "$PROJECT-open-webui-1" curl -fsS --max-time 20 'http://searxng:8080/search?q=open+webui&format=json' \
    | jq -e '.results | type == "array"' >/dev/null \
    && pass "searxng answers JSON" || fail "searxng JSON search failed (search.formats must include json)"
else
  not_ready open-webui
fi

printf '\n'
if ((fails)); then
  echo "$fails feature check(s) failed."
elif ((pending)); then
  echo "$pending service(s) still starting."
else
  echo "All feature checks passed."
fi
exit $((fails > 0))
```

- [ ] **Step 3: Write the smoke override, catalog and runner**

`tests/smoke/main.ini`:

```ini
# Smoke-test catalog: the real model names, served by a tiny model on the CPU.
version = 1

[*]
c = 2048
parallel = 1
jinja = true

[qwen3.6-35b-a3b]
hf-repo = ggml-org/Qwen2.5-Coder-0.5B-Q8_0-GGUF

[gpt-oss-120b]
hf-repo = ggml-org/Qwen2.5-Coder-0.5B-Q8_0-GGUF
```

`tests/smoke/compose.smoke.yaml`:

```yaml
# CPU-only override for tests/smoke/run.sh: no GPU, NPU or iGPU; tiny models.
# All llama services run our llama-vulkan image, which falls back to Mesa's
# lavapipe or the CPU when there is no GPU.
services:
  llm-main:
    build:
      context: docker/llama-vulkan
    image: ailab/llama-vulkan:local
    deploy: !reset {}
    volumes:
      - ./tests/smoke/main.ini:/config/main.ini:ro
  llm-aux:
    devices: !reset []
  llm-fim:
    devices: !reset []
  ovms:
    devices: !reset []
    command: >-
      --config_path /models/config.json --rest_port 8000 --cache_dir /models/cache
      --metrics_enable --log_level DEBUG
  searxng:
    volumes: !override
      - ${SMOKE_WORK:?}/searxng:/etc/searxng
```

`tests/smoke/run.sh`:

```bash
#!/usr/bin/env bash
# CPU smoke test: the whole stack on any x86 Linux Docker host, no GPU or NPU.
# The real compose.yaml plus tests/smoke/compose.smoke.yaml: a tiny model for
# every llama role and every OVMS model on the CPU. Needs curl, jq and ~25 GB
# of Docker disk. Docker Desktop (Windows/macOS): use tests/smoke/in-dind.sh.
#   tests/smoke/run.sh          # build, start, check, tear down
#   KEEP=1 tests/smoke/run.sh   # leave the stack running afterwards
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$ROOT/.smoke
TINY=ggml-org/Qwen2.5-Coder-0.5B-Q8_0-GGUF
W=http://127.0.0.1:3000
export COMPOSE_PROJECT_NAME=ailab-smoke
# shellcheck source=../../installer/lib.sh
source "$ROOT/installer/lib.sh"

compose() {
  docker compose --project-directory "$ROOT" -f "$ROOT/compose.yaml" \
    -f "$ROOT/tests/smoke/compose.smoke.yaml" --env-file "$WORK/env" "$@"
}
finish() {
  local rc=$?
  if ((rc != 0)); then
    compose ps || true
    compose logs --tail 60 || true
  fi
  if [[ ${KEEP:-0} != 1 ]]; then compose down -v --remove-orphans >/dev/null 2>&1 || true; fi
  exit "$rc"
}
trap finish EXIT
wait_up() { # wait_up NAME URL SECONDS
  local i
  for ((i = 0; i < $3; i += 5)); do
    if curl -fsS --max-time 5 -o /dev/null "$2" 2>/dev/null; then ok "$1 up"; return 0; fi
    sleep 5
  done
  die "$1 did not come up within $3 s ($2)"
}

stage "settings for a CPU-only box"
rm -rf "$WORK/env" "$WORK/searxng"
mkdir -p "$WORK/models" "$WORK/searxng"
cp "$ROOT/.env.example" "$WORK/env"
"$ROOT/host/scripts/gen-env.sh" --write "$WORK/env" >/dev/null 2>&1
if [[ -z $(env_get "$WORK/env" RENDER_GID) ]]; then env_set "$WORK/env" RENDER_GID 0; fi
env_set "$WORK/env" MODELS_DIR "$WORK/models"
env_set "$WORK/env" SMOKE_WORK "$WORK"
env_set "$WORK/env" AUX_MODEL "$TINY"
env_set "$WORK/env" AUX_CTX 2048
env_set "$WORK/env" AUX_PARALLEL 1
env_set "$WORK/env" FIM_MODEL "$TINY"
env_set "$WORK/env" FIM_CTX 2048
for d in EMBED RERANK STT TTS; do env_set "$WORK/env" "OVMS_${d}_DEVICE" CPU; done
cp "$ROOT/templates/searxng/settings.yml" "$WORK/searxng/settings.yml"
KEY=$(env_get "$WORK/env" LLM_API_KEY)

stage "build and start"
compose build
compose up -d
wait_up llm-main http://127.0.0.1:8081/health 900
wait_up llm-aux http://127.0.0.1:8082/health 900
wait_up llm-fim http://127.0.0.1:8084/health 900
wait_up ovms http://127.0.0.1:8083/v2/health/ready 1800
wait_up open-webui "$W/health" 600

stage "feature checks"
"$ROOT/host/scripts/check-features.sh" --env "$WORK/env" --strict

stage "router"
for m in qwen3.6-35b-a3b gpt-oss-120b; do
  curl -fsS --max-time 600 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    http://127.0.0.1:8081/v1/chat/completions \
    -d "$(jq -nc --arg m "$m" '{model: $m, max_tokens: 8, messages: [{role: "user", content: "Say OK"}]}')" \
    | jq -e '.choices[0].message.content | type == "string"' >/dev/null || die "router chat on $m failed"
  ok "router serves $m"
done

stage "Open WebUI"
token=$(curl -fsS "$W/api/v1/auths/signup" -H 'Content-Type: application/json' \
  -d '{"name":"smoke","email":"smoke@example.com","password":"smoke-test-password"}' | jq -r '.token // empty')
[[ -n $token ]] || die "could not sign up the first (admin) user"
auth=(-H "Authorization: Bearer $token")
ids=$(curl -fsS "${auth[@]}" "$W/api/models" | jq -r '.data[].id')
for m in qwen3.6-35b-a3b gpt-oss-120b qwen3-4b; do
  grep -qx "$m" <<<"$ids" || die "Open WebUI does not list $m"
done
if grep -qx qwen2.5-coder-1.5b <<<"$ids"; then die "Open WebUI lists the tab-completion model"; fi
ok "Open WebUI lists the chat models, not the completion model"

owui_chat() { # owui_chat JSON
  curl -fsS --max-time 600 "${auth[@]}" -H 'Content-Type: application/json' "$W/api/chat/completions" -d "$1" \
    | jq -e '.choices[0].message.content | type == "string"' >/dev/null
}
owui_chat '{"model":"qwen3.6-35b-a3b","max_tokens":8,"messages":[{"role":"user","content":"Say OK"}]}' \
  || die "chat through Open WebUI failed"
ok "chat through Open WebUI"

file_id=$(curl -fsS "${auth[@]}" -H 'Accept: application/json' -F "file=@$ROOT/tests/assets/doc.txt" \
  "$W/api/v1/files/" | jq -r '.id // empty')
[[ -n $file_id ]] || die "document upload failed"
st=""
for _ in $(seq 60); do
  st=$(curl -fsS "${auth[@]}" "$W/api/v1/files/$file_id/process/status" | jq -r '.status // empty' || true)
  if [[ $st == completed || $st == failed ]]; then break; fi
  sleep 5
done
[[ $st == completed ]] || die "document processing ended as '$st' (embeddings via OVMS?)"
ok "document embedded through OVMS"
owui_chat "$(jq -nc --arg id "$file_id" '{model: "qwen3.6-35b-a3b", max_tokens: 16,
  messages: [{role: "user", content: "What is the smoke-test password?"}], files: [{type: "file", id: $id}]}')" \
  || die "chat with a document failed"
curl -fsS http://127.0.0.1:8083/metrics | grep -i rerank | grep -Eq ' [1-9][0-9.e+]*$' \
  || die "the document chat did not call the OVMS reranker"
if compose logs open-webui 2>&1 | grep -i rerank | grep -Eiq 'error|exception|traceback'; then
  die "Open WebUI logged reranker errors"
fi
ok "document chat used hybrid search and the OVMS reranker"

stage "web search"
owui_chat '{"model":"qwen3.6-35b-a3b","max_tokens":8,"features":{"web_search":true},
  "messages":[{"role":"user","content":"What is Open WebUI?"}]}' || die "chat with web search failed"
if compose logs open-webui 2>&1 | grep -i searxng | grep -Eiq 'error|exception| 403'; then
  die "Open WebUI logged SearXNG errors"
fi
ok "web search through SearXNG"

printf '\nSMOKE TEST PASSED\n'
```

`tests/smoke/in-dind.sh`:

```bash
#!/usr/bin/env bash
# Run tests/smoke/run.sh inside a throwaway Docker-in-Docker container, for
# machines where the stack can't bind-mount the checkout directly (Docker
# Desktop on Windows or macOS). Needs ~25 GB free in Docker's disk.
#   tests/smoke/in-dind.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
if command -v cygpath >/dev/null; then ROOT=$(cygpath -m "$ROOT"); fi
export MSYS_NO_PATHCONV=1
name=ailab-smoke-dind

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --privileged --name "$name" -v "$ROOT:/src:ro" docker:dind >/dev/null
trap 'docker rm -f "$name" >/dev/null' EXIT
until docker exec "$name" docker info >/dev/null 2>&1; do sleep 2; done
docker exec "$name" sh -c '
  apk add --no-cache bash curl jq coreutils sed grep findutils tar >/dev/null
  mkdir /work && tar -C /src --exclude=./.smoke --exclude=./.git -cf - . | tar -C /work -xf -
  cd /work && find . -type f -print0 | xargs -0 sed -i "s/\r$//"
  find . -name "*.sh" -exec chmod +x {} +'
docker exec "$name" bash /work/tests/smoke/run.sh
```

- [ ] **Step 4: Run the smoke test and see what fails**

Run: `tests/smoke/in-dind.sh` (the first run downloads ~10 GB and builds the Vulkan image).
Expected on the first run: it reaches the checks, and any failures fall into the spec's verification items V4–V6. Record each failure before fixing it.

- [ ] **Step 5: Fix each failure from the pinned image's own code (superpowers:systematic-debugging)**

Find names in the pinned image itself, in the same dind session (`KEEP=1` keeps the stack):
- **Open WebUI variable names (V4):** `docker exec ailab-smoke-dind docker exec ailab-smoke-open-webui-1 grep -n -E "RERANKING_ENGINE|EXTERNAL_RERANKER|WEB_SEARCH_ENGINE|ENABLE_WEB_SEARCH|AUDIO_TTS_VOICE|TASK_MODEL_EXTERNAL" /app/backend/open_webui/config.py`. Correct `compose.yaml` and the matching `compose.bats` line together.
- **Reranker response parsing (V5):** if the rerank metric stays at 0 or Open WebUI logs a parse error, read how Open WebUI's external reranker builds its request (`grep -rn "relevance_score" /app/backend/open_webui/retrieval/`). If it can't read OVMS's Cohere-style response, clear `RAG_RERANKING_ENGINE` in `compose.yaml`, record V5 as failed in the spec, and remove the smoke rerank assertion.
- **Kokoro voice (V6):** if TTS fails, list the voices: `docker exec ... ls /models/OpenVINO/Kokoro-82M-int8-ov`. Set `TTS_VOICE` in `.env.example` and the compose default to a listed voice.
- **OVMS config (Task 5):** if `ovms` rejects `config.json`, look at how `--add_to_config` wrote it (`cat /models/config.json` in `ovms-init`'s volume) and adjust the skeleton in `init.sh` and its bats expectation.

Re-run `tests/smoke/in-dind.sh` after each fix.
Expected at the end: `SMOKE TEST PASSED`.

- [ ] **Step 6: Commit**

```bash
git add tests/assets tests/smoke/compose.smoke.yaml tests/smoke/main.ini compose.yaml services tests/unit
git add --chmod=+x host/scripts/check-features.sh tests/smoke/run.sh tests/smoke/in-dind.sh
git commit -m "Add feature checks and a CPU smoke test of the whole stack"
```

If `.env.example` changed (e.g. `TTS_VOICE`), ask Jordan to commit it:

```bash
git add .env.example && git commit -m "Env template: smoke-tested defaults"
```

---

## Phase 4: Installer

**Skills & tools:** superpowers:test-driven-development; bats with command stubs; `tests/ci-local.sh` (runs the installer dry run)
**Files:** `installer/stages/stack.sh`, `installer/stages/tailscale.sh`, `installer/stages/verify.sh`, `install.sh`, `install.conf.example`, `tests/unit/{stack,tailscale}.bats`
**Verification:** `tests/ci-local.sh` passes, and the dry run lists the tailscale stage and the backup timer

### Task 8: `stack` stage

**Files:**
- Rewrite: `installer/stages/stack.sh`
- Create: `tests/unit/stack.bats`

**Interfaces:**
- Consumes: `write_generated`, `env_set`, `env_get`, `state_get` (lib); `gen-env.sh --write`; `templates/`; `state_get tailscale-url` (written in Task 9).
- Produces:
  - `stack_env_merge ENV_FILE` adds keys that `.env.example` has and ENV_FILE lacks.
  - `stack_config` writes `$AILAB_DIR/config/main.ini` and `config/searxng/settings.yml`.
  - The units `ailab.service`, `ailab-backup.service` and `ailab-backup.timer` (the timer runs `$AILAB_DIR/scripts/backup.sh`, created in Task 12).

- [ ] **Step 1: Write the failing tests**

`tests/unit/stack.bats`:

```bash
#!/usr/bin/env bats
# installer/stages/stack.sh
load helpers

setup() {
  common_setup
  # shellcheck source=../../installer/lib.sh
  source "$REPO/installer/lib.sh"
  # shellcheck source=../../installer/stages/stack.sh
  source "$REPO/installer/stages/stack.sh"
  REPO_DIR=$REPO AILAB_DIR=$T/opt DATA_ROOT=$T/srv AILAB_USER="" HF_TOKEN=""
  BUILD_IMAGES=1 START_STACK=1 REBOOT_FLAG=$T/reboot
}
teardown() { common_teardown; }

@test "dry run: shows the units, the timer, the config and the builds, and touches nothing" {
  DRY_RUN=1
  stub docker
  run stage_stack
  [ "$status" -eq 0 ]
  [[ $output == *"+ write /etc/systemd/system/ailab-backup.timer"* ]]
  [[ $output == *"OnCalendar=*-*-* 03:30:00"* ]]
  [[ $output == *"+ write $T/opt/config/main.ini"* ]]
  [[ $output == *"+ write $T/opt/config/searxng/settings.yml"* ]]
  [[ $output == *"build --pull"* ]]
  [[ $output != *"LLAMA_CPP_REF"* ]]
  [ ! -e "$T/opt" ]
}

@test "the env merge adds new settings and keeps existing values" {
  printf 'LLAMA_CPP_REF=b1234\nLLM_API_KEY=abc\n' >"$T/env"
  stack_env_merge "$T/env"
  [ "$(env_get "$T/env" LLAMA_CPP_REF)" = b1234 ]
  [ "$(env_get "$T/env" LLM_API_KEY)" = abc ]
  [ "$(env_get "$T/env" OVMS_TAG)" = 2026.4.0-gpu ]
  [ "$(grep -c '^LLAMA_CPP_REF=' "$T/env")" -eq 1 ]
}

@test "stack_config writes the catalog once and keeps an edited one" {
  stack_config
  cmp "$T/opt/config/main.ini" "$REPO/templates/main.ini"
  echo "# mine" >>"$T/opt/config/main.ini"
  stack_config
  [ "$(tail -1 "$T/opt/config/main.ini")" = "# mine" ]
}
```

- [ ] **Step 2: Run to see them fail**

Run: `tests/ci-local.sh bats tests/unit/stack.bats`
Expected: FAIL. `stack_env_merge` and `stack_config` are not defined, and the dry run has no timer.

- [ ] **Step 3: Rewrite the stage**

`installer/stages/stack.sh`:

```bash
# shellcheck shell=bash
# Install the compose stack to AILAB_DIR: .env, generated config, images, the
# ailab.service unit, the daily backup timer and the `ailab` command.

stack_sync_repo() {
  if [[ $(readlink -f "$REPO_DIR") == $(readlink -f "$AILAB_DIR" 2>/dev/null || echo "$AILAB_DIR") ]]; then
    log "running from $AILAB_DIR, no copy needed"
    return 0
  fi
  run mkdir -p "$AILAB_DIR"
  # .env, config/ and local settings belong to the installed copy; never overwrite them.
  run rsync -a --delete \
    --exclude .env --exclude .env.prev --exclude install.conf --exclude config/ \
    --exclude models/ --exclude .smoke/ --exclude '__pycache__/' \
    "$REPO_DIR/" "$AILAB_DIR/"
  ok "stack files synced to $AILAB_DIR"
}

# Add settings that .env.example has and ENV_FILE lacks (new after an update).
stack_env_merge() {
  local line key
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z_][A-Z0-9_]*)= ]] || continue
    key=${BASH_REMATCH[1]}
    grep -q "^$key=" "$1" || env_set "$1" "$key" "${line#*=}"
  done <"$REPO_DIR/.env.example"
}

stack_env() {
  local env=$AILAB_DIR/.env url
  if [[ ! -f $env ]]; then
    if [[ $DRY_RUN == 1 ]]; then
      log "would create $env from .env.example and fill in host values and secrets"
      return 0
    fi
    cp "$REPO_DIR/.env.example" "$env"
  fi
  stack_env_merge "$env"
  run chmod 600 "$env"
  # Host-specific values (cpusets, Intel render node, render GID) and secrets.
  run "$AILAB_DIR/host/scripts/gen-env.sh" --write "$env"
  if [[ $DRY_RUN != 1 && -z $(env_get "$env" RENDER_GID) ]]; then
    warn "RENDER_GID could not be detected; set it in $env (getent group render) or compose will refuse to start"
  fi
  env_set "$env" MODELS_DIR "$DATA_ROOT/models"
  if [[ -n $HF_TOKEN ]]; then env_set "$env" HF_TOKEN "$HF_TOKEN"; fi
  url=$(state_get tailscale-url)
  if [[ -n $url ]]; then env_set "$env" WEBUI_URL "$url"; fi
  if [[ -n $AILAB_USER ]]; then run chown "$AILAB_USER:" "$env"; fi
  ok ".env ready ($env)"
}

# Files people may edit: generated once, kept once edited (write_generated).
stack_config() {
  local dir=$AILAB_DIR/config
  write_generated "$dir/main.ini" <"$REPO_DIR/templates/main.ini"
  write_generated "$dir/searxng/settings.yml" <"$REPO_DIR/templates/searxng/settings.yml"
  if [[ -n $AILAB_USER && -d $dir ]]; then run chown -R "$AILAB_USER:" "$dir"; fi
}

stack_units() {
  write_file /etc/systemd/system/ailab.service <<EOF
[Unit]
Description=AI Lab inference stack (docker compose)
Documentation=file://$AILAB_DIR/docs/INSTALL.md
Requires=docker.service
After=docker.service network-online.target nvidia-persistenced.service ailab-tune.service
Wants=network-online.target
# Model weights live here; wait for the data disk when there is one.
RequiresMountsFor=$DATA_ROOT

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$AILAB_DIR
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose stop
ExecReload=/usr/bin/docker compose up -d --remove-orphans
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  write_file /etc/systemd/system/ailab-backup.service <<EOF
[Unit]
Description=AI Lab backup (Open WebUI data, .env, config)
After=ailab.service

[Service]
Type=oneshot
WorkingDirectory=$AILAB_DIR
ExecStart=$AILAB_DIR/scripts/backup.sh
EOF
  write_file /etc/systemd/system/ailab-backup.timer <<'EOF'
[Unit]
Description=Daily AI Lab backup

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  run systemctl daemon-reload
  run systemctl enable ailab.service
  run systemctl enable --now ailab-backup.timer
  run ln -sfn "$AILAB_DIR/scripts/ailab" /usr/local/bin/ailab
}

stage_stack() {
  command -v docker >/dev/null || [[ $DRY_RUN == 1 ]] || die "docker is not installed (run the docker stage first)"

  stack_sync_repo
  if [[ -n $AILAB_USER ]]; then run chown -R "$AILAB_USER:" "$AILAB_DIR"; fi
  stack_env
  stack_config
  stack_units
  run mkdir -p "$DATA_ROOT/models/ovms" "$DATA_ROOT/backups"

  if [[ $BUILD_IMAGES == 1 ]]; then
    log "pulling images and building llama.cpp (CUDA + Vulkan); the CUDA build takes a while"
    run docker compose -f "$AILAB_DIR/compose.yaml" --project-directory "$AILAB_DIR" pull --ignore-buildable --quiet
    run docker compose -f "$AILAB_DIR/compose.yaml" --project-directory "$AILAB_DIR" build --pull
    ok "images ready"
  fi

  if [[ -s $REBOOT_FLAG ]]; then
    log "not starting the stack now: a reboot is pending (it starts by itself after the reboot)"
  elif [[ $START_STACK == 1 ]]; then
    run systemctl restart ailab.service
    ok "stack started; the first start downloads the models (see: ailab models)"
  fi
}
```

- [ ] **Step 4: Run the whole suite**

Run: `tests/ci-local.sh`
Expected: stack.bats 3 `ok`, the dry run passes, and `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add installer/stages/stack.sh tests/unit/stack.bats
git commit -m "stack stage: env merge, generated config, backup timer, both llama images"
```

### Task 9: `tailscale` stage

**Files:**
- Create: `installer/stages/tailscale.sh`, `tests/unit/tailscale.bats`
- Modify: `install.sh:17-21` (stage list, config keys), `install.sh:39-81` (defaults), `install.conf.example`

**Interfaces:**
- Consumes: `TAILSCALE_ENABLE`, `TAILSCALE_HOSTNAME`, `TAILSCALE_AUTHKEY` (config), `TAILSCALE_LOGIN_TIMEOUT` (env, default `10m`).
- Produces:
  - `state_set tailscale-url https://<Self.DNSName>`, read by `stack_env` and `stage_verify`.
  - Functions `ts_status`, `ts_dns`, `tailscale_login`, `tailscale_https_ready` and `tailscale_serve`.

- [ ] **Step 1: Write the failing tests**

`tests/unit/tailscale.bats`:

```bash
#!/usr/bin/env bats
# installer/stages/tailscale.sh with a fake tailscale CLI.
load helpers

setup() {
  common_setup
  # shellcheck source=../../installer/lib.sh
  source "$REPO/installer/lib.sh"
  # shellcheck source=../../installer/stages/tailscale.sh
  source "$REPO/installer/stages/tailscale.sh"
  TAILSCALE_HOSTNAME=ailab TAILSCALE_AUTHKEY="" TAILSCALE_ENABLE=1
}
teardown() { common_teardown; }

running='{"BackendState":"Running","Self":{"DNSName":"ailab.tail1234.ts.net.","HostName":"ailab"},
  "CurrentTailnet":{"MagicDNSEnabled":true},"CertDomains":["ailab.tail1234.ts.net"]}'
web() { # web PROXY443 PROXY8443 PROXY10000 -> serve status JSON
  jq -nc --arg a "$1" --arg b "$2" --arg c "$3" '{Web: {
    "ailab.tail1234.ts.net:443": {Handlers: {"/": {Proxy: $a}}},
    "ailab.tail1234.ts.net:8443": {Handlers: {"/": {Proxy: $b}}},
    "ailab.tail1234.ts.net:10000": {Handlers: {"/": {Proxy: $c}}}}}'
}
# fake STATUS_JSON SERVE_JSON [UP_EXIT]
fake() {
  printf '%s' "$1" >"$T/status.json"
  printf '%s' "$2" >"$T/serve.json"
  stub tailscale "
case \"\$1 \$2\" in
  'status --json') cat '$T/status.json' ;;
  'serve status') cat '$T/serve.json' ;;
  up*) exit ${3:-0} ;;
esac"
}

@test "serve: adds only the mappings that are missing or wrong" {
  fake "$running" "$(web http://127.0.0.1:3000 http://127.0.0.1:9999 '')"
  run tailscale_serve
  [ "$status" -eq 0 ]
  ! grep -q -- '--https=443' "$STUB_LOG"
  grep -q -- 'tailscale serve --bg --https=8443 http://127.0.0.1:8081' "$STUB_LOG"
  grep -q -- 'tailscale serve --bg --https=10000 http://127.0.0.1:8084' "$STUB_LOG"
}

@test "serve: nothing to do when every mapping is right" {
  fake "$running" "$(web http://127.0.0.1:3000 http://127.0.0.1:8081 http://127.0.0.1:8084)"
  run tailscale_serve
  ! grep -q -- 'serve --bg' "$STUB_LOG"
}

@test "login: already running under the right name does nothing" {
  fake "$running" '{}'
  run tailscale_login
  [ "$status" -eq 0 ]
  ! grep -Eq 'tailscale (up|set)' "$STUB_LOG"
}

@test "login: another hostname is fixed with tailscale set" {
  fake "${running/\"HostName\":\"ailab\"/\"HostName\":\"old\"}" '{}'
  run tailscale_login
  grep -q 'tailscale set --hostname=ailab' "$STUB_LOG"
}

@test "login: logged out runs up with a timeout and the auth key" {
  fake '{"BackendState":"NeedsLogin"}' '{}'
  TAILSCALE_AUTHKEY=tskey-abc
  run tailscale_login
  [ "$status" -eq 0 ]
  grep -q 'tailscale up --hostname=ailab --timeout=10m --auth-key=tskey-abc' "$STUB_LOG"
}

@test "login: a login that times out warns and returns non-zero" {
  fake '{"BackendState":"NeedsLogin"}' '{}' 1
  run tailscale_login
  [ "$status" -eq 1 ]
  [[ $output == *"sudo ./install.sh tailscale"* ]]
}

@test "a dry run never prints the auth key" {
  DRY_RUN=1
  fake '{"BackendState":"NeedsLogin"}' '{}'
  TAILSCALE_AUTHKEY=tskey-secret
  run tailscale_login
  [[ $output != *tskey-secret* ]]
  [[ $output == *"--auth-key=<TAILSCALE_AUTHKEY>"* ]]
}

@test "https check: warns when HTTPS certificates are off" {
  fake '{"BackendState":"Running","CurrentTailnet":{"MagicDNSEnabled":true},"CertDomains":null}' '{}'
  run tailscale_https_ready
  [ "$status" -eq 1 ]
  [[ $output == *"HTTPS Certificates"* ]]
}
```

- [ ] **Step 2: Run to see them fail**

Run: `tests/ci-local.sh bats tests/unit/tailscale.bats`
Expected: FAIL, `installer/stages/tailscale.sh: No such file or directory`.

- [ ] **Step 3: Implement the stage**

`installer/stages/tailscale.sh`:

```bash
# shellcheck shell=bash
# Tailscale: the HTTPS front door. Phones, laptops and IDEs on the owner's
# tailnet reach Open WebUI and the model APIs at https://<host>.<tailnet>.ts.net,
# at home and away. Browsers only allow the microphone on HTTPS pages.

# HTTPS port on the tailnet : local port. Serve only proxies to 127.0.0.1.
TS_MAPPINGS=(443:3000 8443:8081 10000:8084)

ts_status() { tailscale status --json 2>/dev/null || echo '{}'; }
ts_dns() { ts_status | jq -r '.Self.DNSName // "" | rtrimstr(".")'; }

tailscale_repo() {
  local key=/usr/share/keyrings/tailscale-archive-keyring.gpg codename
  codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
  if [[ ! -s $key ]]; then
    run curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$codename.noarmor.gpg" -o "$key"
  fi
  write_file /etc/apt/sources.list.d/tailscale.list <<EOF
deb [signed-by=$key] https://pkgs.tailscale.com/stable/ubuntu $codename main
EOF
}

tailscale_login() {
  local status timeout=${TAILSCALE_LOGIN_TIMEOUT:-10m}
  status=$(ts_status)
  if [[ $(jq -r '.BackendState // ""' <<<"$status") == Running ]]; then
    if [[ $(jq -r '.Self.HostName // ""' <<<"$status") != "$TAILSCALE_HOSTNAME" ]]; then
      run tailscale set --hostname="$TAILSCALE_HOSTNAME"
    fi
    ok "tailscale: logged in"
    return 0
  fi
  if [[ $DRY_RUN == 1 ]]; then
    # Never print the auth key.
    printf '  + tailscale up --hostname=%s --timeout=%s%s\n' "$TAILSCALE_HOSTNAME" "$timeout" \
      "${TAILSCALE_AUTHKEY:+ --auth-key=<TAILSCALE_AUTHKEY>}"
    return 0
  fi
  local args=(up --hostname="$TAILSCALE_HOSTNAME" --timeout="$timeout")
  if [[ -n $TAILSCALE_AUTHKEY ]]; then
    args+=(--auth-key="$TAILSCALE_AUTHKEY")
  else
    log "log in with the URL tailscale prints below (waiting up to $timeout)"
  fi
  if ! tailscale "${args[@]}"; then
    warn "tailscale login did not complete; finish it later with: sudo ./install.sh tailscale"
    return 1
  fi
}

tailscale_https_ready() {
  local status
  status=$(ts_status)
  if [[ $(jq -r '.CurrentTailnet.MagicDNSEnabled // false' <<<"$status") == true ]] \
    && (($(jq -r '.CertDomains // [] | length' <<<"$status") > 0)); then
    return 0
  fi
  warn "HTTPS is off for this tailnet. In the Tailscale admin console (DNS page): enable MagicDNS, then HTTPS Certificates."
  warn "The serve mappings are set up anyway and start working once HTTPS is on."
  return 1
}

tailscale_serve() {
  local dns serve_json m port want have
  dns=$(ts_dns)
  serve_json=$(tailscale serve status --json 2>/dev/null || echo '{}')
  for m in "${TS_MAPPINGS[@]}"; do
    port=${m%%:*}
    want=http://127.0.0.1:${m#*:}
    have=$(jq -r --arg hp "$dns:$port" '.Web[$hp].Handlers["/"].Proxy // ""' <<<"$serve_json")
    if [[ $have == "$want" ]]; then
      ok "serve https://$dns:$port -> $want"
    else
      run tailscale serve --bg --https="$port" "$want"
    fi
  done
}

stage_tailscale() {
  if [[ $TAILSCALE_ENABLE != 1 ]]; then
    log "TAILSCALE_ENABLE=0: no HTTPS front door (voice input then only works on this machine)"
    return 0
  fi
  tailscale_repo
  apt_update
  apt_install tailscale
  run systemctl enable --now tailscaled
  if [[ $DRY_RUN == 1 ]]; then
    tailscale_login
    local m
    for m in "${TS_MAPPINGS[@]}"; do
      printf '  + tailscale serve --bg --https=%s http://127.0.0.1:%s\n' "${m%%:*}" "${m#*:}"
    done
    return 0
  fi
  tailscale_login || return 0
  tailscale_https_ready || true
  tailscale_serve
  state_set tailscale-url "https://$(ts_dns)"
  ok "Open WebUI on the tailnet: https://$(ts_dns)"
}
```

- [ ] **Step 4: Register the stage and its settings**

In `install.sh`:
- Replace line 17 with `ALL_STAGES=(preflight base nvidia intel-gpu npu storage docker network tailscale tuning stack)`.
- In `CONFIG_KEYS`, add `TAILSCALE_ENABLE TAILSCALE_HOSTNAME TAILSCALE_AUTHKEY` after `BOND_APPLY`.
- In `load_config`, after the `BOND_APPLY` default, add:

```bash
  TAILSCALE_ENABLE=${TAILSCALE_ENABLE:-1}
  TAILSCALE_HOSTNAME=${TAILSCALE_HOSTNAME:-ailab}
  TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY:-}
```

In `install.conf.example`, before `# --- Tuning`, add:

```
# --- Tailscale (HTTPS front door) ---------------------------------------------------------
# Phones, laptops and IDEs on your tailnet reach https://<hostname>.<tailnet>.ts.net.
# Voice input needs HTTPS. 0 = skip (Open WebUI stays plain HTTP on the LAN).
TAILSCALE_ENABLE=1
TAILSCALE_HOSTNAME=ailab
# Optional: an auth key from the Tailscale admin console for unattended installs. Without
# one the installer prints a login URL and waits up to 10 minutes.
TAILSCALE_AUTHKEY=
```

- [ ] **Step 5: Run the whole suite**

Run: `tests/ci-local.sh`
Expected: tailscale.bats 8 `ok`. The dry run lists `==> tailscale` with the three serve lines. Then `all checks passed`.

- [ ] **Step 6: Commit**

```bash
git add installer/stages/tailscale.sh tests/unit/tailscale.bats install.sh install.conf.example
git commit -m "Add tailscale stage: HTTPS front door for the UI and model APIs"
```

### Task 10: `verify` stage uses the feature checks

**Files:**
- Modify: `installer/stages/verify.sh` (whole function)

**Interfaces:**
- Consumes: `host/scripts/check-features.sh` (Task 7) and `state_get tailscale-url` (Task 9).

- [ ] **Step 1: Replace the per-port health loop and the open-webui check**

`installer/stages/verify.sh`:

```bash
# shellcheck shell=bash
# End-to-end health check. Safe to run any time: sudo ./install.sh verify

stage_verify() {
  local failed=0 dir=$AILAB_DIR url ip
  [[ -f $dir/compose.yaml ]] || dir=$REPO_DIR

  "$dir/host/scripts/check-host.sh" || failed=1

  printf '\n%s\n' "Containers"
  if has_nvidia_gpu; then
    if docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi -L >/dev/null 2>&1; then
      ok "CUDA works inside containers"
    else
      warn "docker --gpus all failed (driver loaded? nvidia-ctk configured? reboot pending?)"
      failed=1
    fi
  fi
  if systemctl is-enabled --quiet ailab.service 2>/dev/null; then
    (cd "$dir" && docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Health}}' 2>/dev/null) || true
  else
    warn "ailab.service not installed (run the stack stage)"
    failed=1
  fi

  "$dir/host/scripts/check-features.sh" --env "$dir/.env" || failed=1

  url=$(state_get tailscale-url)
  if [[ -n $url ]]; then
    if curl -fsS --max-time 10 -o /dev/null "$url/health"; then
      ok "Tailscale HTTPS: $url"
    else
      warn "$url not answering (MagicDNS and HTTPS Certificates on in the Tailscale admin console?)"
    fi
  fi

  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
  printf '\n  Open WebUI:  %s\n' "${url:-http://${ip:-<host>}:3000}"
  printf '  IDEs:        ailab connect\n'
  printf '  Operate:     ailab status | ailab models | ailab logs <service>\n\n'
  return $failed
}
```

- [ ] **Step 2: Check it against the smoke stack**

Run: `KEEP=1 tests/smoke/in-dind.sh`, then in the same container: `docker exec ailab-smoke-dind bash -c 'cd /work && COMPOSE_PROJECT_NAME=ailab-smoke host/scripts/check-features.sh --env .smoke/env'`.
Expected: `All feature checks passed.` Then `docker rm -f ailab-smoke-dind`.

- [ ] **Step 3: Run the suite and commit**

Run: `tests/ci-local.sh` → `all checks passed`.

```bash
git add installer/stages/verify.sh
git commit -m "verify: run the feature checks and the Tailscale URL"
```

---

## Phase 5: The `ailab` command

**Skills & tools:** superpowers:test-driven-development; bats with stubbed `curl`/`docker`. WebFetch for the llama.vscode README (setting names) and llama.cpp `docs/speculative.md` at `v0.5.0` (draft keys).
**Files:** `scripts/ailab`, `scripts/models.sh`, `scripts/connect.sh`, `scripts/backup.sh`, `scripts/update.sh`, `scripts/bench.sh`, `tests/unit/{models,backup,update}.bats`
**Verification:** `tests/ci-local.sh` passes

### Task 11: `ailab models`, `ailab connect`, dispatcher

**Files:**
- Create: `scripts/models.sh`, `scripts/connect.sh`, `tests/unit/models.bats`
- Rewrite: `scripts/ailab`

**Interfaces:**
- Consumes: `.env` keys `LLM_API_KEY`, `WEBUI_URL`. Every script honours `AILAB_ENV` (path to the env file, default `<repo>/.env`) so tests can point it elsewhere.
- Produces: `scripts/models.sh [list|pull]`, `scripts/connect.sh`, and the `ailab` subcommands listed in its header.

- [ ] **Step 1: Write the failing tests**

`tests/unit/models.bats`:

```bash
#!/usr/bin/env bats
# scripts/models.sh and scripts/connect.sh with a fake curl.
load helpers

setup() {
  common_setup
  export AILAB_ENV=$T/env
  printf 'LLM_API_KEY=k123\nWEBUI_URL=https://ailab.tail1234.ts.net\n' >"$AILAB_ENV"
  stub curl '
case "$*" in
  */v1/models*) echo "{\"data\":[{\"id\":\"qwen3.6-35b-a3b\",\"status\":{\"value\":\"loaded\"}},{\"id\":\"gpt-oss-120b\",\"status\":{\"value\":\"unloaded\"}}]}" ;;
  */v1/chat/completions*) echo "{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}" ;;
esac'
}
teardown() { common_teardown; }

@test "models lists the catalog with its state, using the API key" {
  run "$REPO/scripts/models.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"qwen3.6-35b-a3b"*"loaded"* ]]
  [[ $output == *"gpt-oss-120b"*"unloaded"* ]]
  grep -q 'Authorization: Bearer k123' "$STUB_LOG"
}

@test "models pull loads each catalog model once" {
  run "$REPO/scripts/models.sh" pull
  [ "$status" -eq 0 ]
  [ "$(grep -c 'chat/completions' "$STUB_LOG")" -eq 2 ]
  grep 'chat/completions' "$STUB_LOG" | grep -q 'gpt-oss-120b'
}

@test "connect prints the three URLs and the key" {
  run "$REPO/scripts/connect.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"https://ailab.tail1234.ts.net:8443/v1"* ]]
  [[ $output == *"https://ailab.tail1234.ts.net:10000"* ]]
  [[ $output == *"k123"* ]]
}

@test "connect explains what to do without a Tailscale URL" {
  printf 'LLM_API_KEY=k123\nWEBUI_URL=\n' >"$AILAB_ENV"
  run "$REPO/scripts/connect.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"install.sh tailscale"* ]]
}
```

- [ ] **Step 2: Run to see them fail**

Run: `tests/ci-local.sh bats tests/unit/models.bats`
Expected: FAIL, the scripts don't exist.

- [ ] **Step 3: Check the IDE setting names**

WebFetch `https://raw.githubusercontent.com/ggml-org/llama.vscode/master/README.md` and `https://docs.continue.dev/reference`. Confirm llama.vscode's endpoint and API-key setting names and Continue's `provider: openai` / `apiBase` / `apiKey` / `roles` keys. Use the confirmed names in step 4's `connect.sh`. The ones written below are the expected names.

- [ ] **Step 4: Implement**

`scripts/models.sh`:

```bash
#!/usr/bin/env bash
# The main router's model catalog and what is loaded.
#   scripts/models.sh         id and state of each catalog model
#   scripts/models.sh pull    load each catalog model once, so its download happens
#                             now rather than at someone's first request
set -euo pipefail
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
ENV_FILE=${AILAB_ENV:-$DIR/.env}
KEY=$(sed -n 's/^LLM_API_KEY=//p' "$ENV_FILE" | tail -1)
MAIN=${MAIN_URL:-http://127.0.0.1:8081}

api() { # api PATH [JSON]
  local args=(-fsS -H "Authorization: Bearer $KEY")
  if (($# > 1)); then args+=(-H 'Content-Type: application/json' -d "$2"); fi
  curl "${args[@]}" "$MAIN$1"
}
catalog() {
  api /v1/models | jq -r '.data[] | [.id, (.status | if type == "object" then .value else (. // "") end)] | @tsv'
}

case ${1:-list} in
  list)
    printf '%-22s %s\n' MODEL STATE
    catalog | while IFS=$'\t' read -r id state; do printf '%-22s %s\n' "$id" "${state:-available}"; done
    printf '\niGPU: qwen3-4b (task model, llm-aux), qwen2.5-coder-1.5b (tab completion, llm-fim)\n'
    ;;
  pull)
    catalog | cut -f1 | while read -r id; do
      echo "loading $id (the first time downloads it; gpt-oss-120b is ~59 GB)..."
      api /v1/chat/completions "$(jq -nc --arg m "$id" '{model: $m, max_tokens: 1, messages: [{role: "user", content: "hi"}]}')" >/dev/null
      echo "  $id ready"
    done
    ;;
  *) echo "usage: ailab models [pull]" >&2; exit 2 ;;
esac
```

`scripts/connect.sh`:

```bash
#!/usr/bin/env bash
# How to reach the lab from other devices, with ready-to-paste IDE settings.
set -euo pipefail
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
ENV_FILE=${AILAB_ENV:-$DIR/.env}
envval() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1; }
KEY=$(envval LLM_API_KEY)
URL=$(envval WEBUI_URL)

if [[ $URL != https://* ]]; then
  echo "No Tailscale HTTPS address yet (WEBUI_URL in .env). Set it up with: sudo /opt/ailab/install.sh tailscale"
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' || true)
  echo "Meanwhile Open WebUI is at http://${ip:-<host>}:3000 on the LAN (text only: the microphone needs HTTPS)."
  exit 1
fi

cat <<EOF
Open WebUI (browser, phone):     $URL
Chat and agent API (OpenAI):     $URL:8443/v1
Tab completion (/infill):        $URL:10000
API key:                         $KEY
Models: qwen3.6-35b-a3b (default), gpt-oss-120b (deep reasoning)

Continue (~/.continue/config.yaml, under models:)
  - name: Qwen3.6 (ailab)
    provider: openai
    model: qwen3.6-35b-a3b
    apiBase: $URL:8443/v1
    apiKey: $KEY
    roles: [chat, edit, apply]
  - name: gpt-oss-120b (ailab)
    provider: openai
    model: gpt-oss-120b
    apiBase: $URL:8443/v1
    apiKey: $KEY
    roles: [chat]

llama.vscode (VS Code settings.json) for tab completion:
  "llama-vscode.endpoint": "$URL:10000",
  "llama-vscode.api_key": "$KEY"

Cline and other OpenAI-compatible tools: base URL $URL:8443/v1, the key above.
EOF
```

`scripts/ailab`:

```bash
#!/usr/bin/env bash
# Day-2 operations for the AI Lab stack (installed as /usr/local/bin/ailab).
#
#   ailab status             containers, GPU, NPU devices, memory
#   ailab models [pull]      the model catalog and what is loaded; pull = download all now
#   ailab connect            HTTPS addresses and ready-to-paste IDE settings
#   ailab logs [service]     follow logs (llm-main, llm-aux, llm-fim, ovms, open-webui, ...)
#   ailab restart [service]  restart everything or one service
#   ailab stop | start       stop/start the whole stack
#   ailab bench [options]    prompt/generation speed (scripts/bench.sh --help)
#   ailab check              host and feature checks (sudo)
#   ailab edit               edit .env, then apply it
#   ailab backup             back up chats, settings, .env and config now
#   ailab update | rollback  move the pinned versions forward, or back to the previous ones
set -euo pipefail

DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
cd "$DIR"

compose() {
  if docker info >/dev/null 2>&1; then docker compose "$@"; else sudo docker compose "$@"; fi
}

# .env settings Open WebUI copies into its database on first start; later
# changes don't reach it (docs/INSTALL.md, "Changing settings").
WEBUI_SEEDED=(LLM_API_KEY TTS_VOICE WEBUI_URL)

edit_env() {
  local before after k changed=()
  before=$(cat "$DIR/.env")
  "${EDITOR:-nano}" "$DIR/.env"
  after=$(cat "$DIR/.env")
  for k in "${WEBUI_SEEDED[@]}"; do
    [[ $(grep "^$k=" <<<"$before" || true) == "$(grep "^$k=" <<<"$after" || true)" ]] || changed+=("$k")
  done
  compose up -d --remove-orphans
  if ((${#changed[@]})); then
    echo "note: Open WebUI keeps its own copy of ${changed[*]}; change it in Admin Settings too" >&2
  fi
}

case ${1:-status} in
  status)
    compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Health}}\t{{.Ports}}'
    echo
    if command -v nvidia-smi >/dev/null; then
      nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw --format=csv
      echo
    fi
    grep -E '^OVMS_[A-Z]+_DEVICE=' "$DIR/.env" | sed 's/^/ovms: /'
    echo
    free -h | head -2
    ;;
  models) shift; "$DIR/scripts/models.sh" "$@" ;;
  connect) "$DIR/scripts/connect.sh" ;;
  logs) shift; compose logs -f --tail 200 "$@" ;;
  restart) shift; compose restart "$@" ;;
  stop) sudo systemctl stop ailab.service ;;
  start) sudo systemctl start ailab.service ;;
  bench) shift; "$DIR/scripts/bench.sh" "$@" ;;
  check) sudo "$DIR/install.sh" verify ;;
  edit) edit_env ;;
  backup) "$DIR/scripts/backup.sh" ;;
  update | rollback) "$DIR/scripts/update.sh" "$1" ;;
  -h | --help | help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command: $1 (ailab help)" >&2; exit 2 ;;
esac
```

- [ ] **Step 5: Run to see them pass**

Run: `tests/ci-local.sh bats tests/unit/models.bats`, then `tests/ci-local.sh`.
Expected: 4 `ok`, then `all checks passed`.

- [ ] **Step 6: Commit**

```bash
git add tests/unit/models.bats
git add --chmod=+x scripts/ailab scripts/models.sh scripts/connect.sh
git commit -m "ailab: models, connect, and a dispatcher for the new commands"
```

### Task 12: `ailab backup`

**Files:**
- Create: `scripts/backup.sh`, `tests/unit/backup.bats`

**Interfaces:**
- Consumes: `.env` keys `MODELS_DIR`, `OPEN_WEBUI_TAG`; volume `ailab_open-webui`; `COMPOSE_PROJECT_NAME` (default `ailab`); `BACKUP_DIR`, `BACKUP_KEEP` (defaults `<MODELS_DIR>/../backups`, 7).
- Produces: `<BACKUP_DIR>/ailab-YYYYmmdd-HHMMSS.tar.gz` (mode 600), containing `open-webui.tar.gz`, `env` and `config/`. `ailab-backup.service` (Task 8) runs it.

- [ ] **Step 1: Write the failing tests**

`tests/unit/backup.bats`:

```bash
#!/usr/bin/env bats
# scripts/backup.sh with a fake docker.
load helpers

setup() {
  common_setup
  export AILAB_ENV=$T/env BACKUP_DIR=$T/backups
  printf 'MODELS_DIR=%s/srv/models\nOPEN_WEBUI_TAG=v0.11.4\nLLM_API_KEY=k\n' "$T" >"$AILAB_ENV"
  # Fake docker: `docker run ... -v <dir>:/out ...` writes the volume archive.
  stub docker '
if [[ $1 == run ]]; then
  for a in "$@"; do [[ $a == *:/out ]] && echo data >"${a%:/out}/open-webui.tar.gz"; done
  exit ${DOCKER_RUN_EXIT:-0}
fi'
}
teardown() { common_teardown; }

@test "archives the Open WebUI volume, .env and config, readable only by the owner" {
  run "$REPO/scripts/backup.sh"
  [ "$status" -eq 0 ]
  f=$(ls "$BACKUP_DIR"/ailab-*.tar.gz)
  [ "$(stat -c %a "$f")" = 600 ]
  tar -tzf "$f" | grep -qx './open-webui.tar.gz'
  tar -tzf "$f" | grep -qx './env'
  grep -q 'run --rm --entrypoint tar -v ailab_open-webui:/data:ro' "$STUB_LOG"
  grep -q 'ghcr.io/open-webui/open-webui:v0.11.4' "$STUB_LOG"
}

@test "stops open-webui first and always starts it again" {
  export DOCKER_RUN_EXIT=1
  run "$REPO/scripts/backup.sh"
  [ "$status" -ne 0 ]
  stop=$(grep -n 'stop open-webui' "$STUB_LOG" | cut -d: -f1)
  start=$(grep -n 'start open-webui' "$STUB_LOG" | cut -d: -f1)
  [ -n "$stop" ] && [ -n "$start" ] && [ "$stop" -lt "$start" ]
}

@test "keeps the newest seven" {
  mkdir -p "$BACKUP_DIR"
  for d in 01 02 03 04 05 06 07 08; do touch "$BACKUP_DIR/ailab-202601$d-000000.tar.gz"; done
  "$REPO/scripts/backup.sh" >/dev/null
  [ "$(ls "$BACKUP_DIR" | wc -l)" -eq 7 ]
  [ ! -e "$BACKUP_DIR/ailab-20260102-000000.tar.gz" ]
}
```

- [ ] **Step 2: Run to see them fail**

Run: `tests/ci-local.sh bats tests/unit/backup.bats`
Expected: FAIL, the script doesn't exist.

- [ ] **Step 3: Implement**

`scripts/backup.sh`:

```bash
#!/usr/bin/env bash
# Back up what can't be downloaded again: Open WebUI's data (accounts, chats,
# documents, settings), .env and config/. Model weights are not included.
#   scripts/backup.sh   -> <DATA_ROOT>/backups/ailab-YYYYmmdd-HHMMSS.tar.gz, keeps the newest 7
# Restore: docs/INSTALL.md, "Backups".
set -euo pipefail
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
ENV_FILE=${AILAB_ENV:-$DIR/.env}
envval() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1; }
models_dir=$(envval MODELS_DIR)
BACKUP_DIR=${BACKUP_DIR:-$(dirname "${models_dir:-/srv/ai/models}")/backups}
KEEP=${BACKUP_KEEP:-7}
PROJECT=${COMPOSE_PROJECT_NAME:-ailab}
work=$(mktemp -d)

compose() { docker compose --project-directory "$DIR" "$@"; }
finish() {
  compose start open-webui >/dev/null || echo "warning: could not start open-webui again" >&2
  rm -rf "$work"
}

mkdir -p "$BACKUP_DIR"
# Open WebUI keeps SQLite and its vector store in the volume; stop it for a consistent copy.
compose stop open-webui >/dev/null
trap finish EXIT
docker run --rm --entrypoint tar -v "${PROJECT}_open-webui:/data:ro" -v "$work:/out" \
  "ghcr.io/open-webui/open-webui:$(envval OPEN_WEBUI_TAG)" -czf /out/open-webui.tar.gz -C /data .
cp "$ENV_FILE" "$work/env"
if [[ -d $DIR/config ]]; then cp -r "$DIR/config" "$work/config"; fi

out=$BACKUP_DIR/ailab-$(date +%Y%m%d-%H%M%S).tar.gz
tar -czf "$out" -C "$work" .
chmod 600 "$out" # it holds .env's secrets
# Timestamped names sort chronologically.
printf '%s\n' "$BACKUP_DIR"/ailab-*.tar.gz | sort -r | tail -n +$((KEEP + 1)) | xargs -r rm -f
echo "backup: $out ($(du -h "$out" | cut -f1))"
```

- [ ] **Step 4: Run to see them pass**

Run: `tests/ci-local.sh bats tests/unit/backup.bats`
Expected: 3 `ok`.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/backup.bats
git add --chmod=+x scripts/backup.sh
git commit -m "Add ailab backup: Open WebUI data, .env and config, keeps 7"
```

### Task 13: `ailab update` / `ailab rollback`

**Files:**
- Create: `scripts/update.sh`, `tests/unit/update.bats`

**Interfaces:**
- Consumes: `env_set`, `env_get`, `gh_release_json`, `log`, `ok`, `warn`, `die` (lib); `AILAB_NO_APPLY=1` skips the rebuild (tests).
- Produces: `.env.prev` beside the env file, holding the four pins before the last update.

- [ ] **Step 1: Write the failing tests**

`tests/unit/update.bats`:

```bash
#!/usr/bin/env bats
# scripts/update.sh with a fake curl (GitHub releases, Docker Hub tags).
load helpers

setup() {
  common_setup
  export AILAB_ENV=$T/env AILAB_NO_APPLY=1
  printf 'LLAMA_CPP_REF=v0.5.0\nOPEN_WEBUI_TAG=v0.11.4\nOVMS_TAG=2026.4.0-gpu\nSEARXNG_TAG=2026.9.25-12f8b6515\nX=1\n' >"$AILAB_ENV"
  stub curl '
case "${*: -1}" in
  *ggml-org/llama.cpp/releases/latest) echo "{\"tag_name\":\"v0.6.0\"}" ;;
  *open-webui/open-webui/releases/latest) echo "{\"tag_name\":\"${OWUI_TAG-v0.12.0}\"}" ;;
  *openvinotoolkit/model_server/releases/latest) echo "{\"tag_name\":\"v2026.5.0\"}" ;;
  *searxng/searxng/tags*) echo "{\"results\":[{\"name\":\"latest\"},{\"name\":\"2026.10.1-abcdef123\"}]}" ;;
  *) exit 22 ;;
esac'
}
teardown() { common_teardown; }

pin() { sed -n "s/^$1=//p" "$AILAB_ENV"; }

@test "update moves all four pins and saves the old ones" {
  run "$REPO/scripts/update.sh" update
  [ "$status" -eq 0 ]
  [ "$(pin LLAMA_CPP_REF)" = v0.6.0 ]
  [ "$(pin OPEN_WEBUI_TAG)" = v0.12.0 ]
  [ "$(pin OVMS_TAG)" = 2026.5.0-gpu ]
  [ "$(pin SEARXNG_TAG)" = 2026.10.1-abcdef123 ]
  grep -qx 'OVMS_TAG=2026.4.0-gpu' "$T/.env.prev"
}

@test "update changes nothing when a version can't be resolved" {
  export OWUI_TAG=""
  run "$REPO/scripts/update.sh" update
  [ "$status" -ne 0 ]
  [ "$(pin OPEN_WEBUI_TAG)" = v0.11.4 ]
  [ "$(pin LLAMA_CPP_REF)" = v0.5.0 ]
}

@test "rollback restores the saved pins" {
  "$REPO/scripts/update.sh" update >/dev/null
  run "$REPO/scripts/update.sh" rollback
  [ "$status" -eq 0 ]
  [ "$(pin LLAMA_CPP_REF)" = v0.5.0 ]
  [ "$(pin SEARXNG_TAG)" = 2026.9.25-12f8b6515 ]
  [ "$(pin X)" = 1 ]
}

@test "rollback without a previous update explains itself" {
  run "$REPO/scripts/update.sh" rollback
  [ "$status" -ne 0 ]
  [[ $output == *"rollback works after an update"* ]]
}
```

- [ ] **Step 2: Run to see them fail**

Run: `tests/ci-local.sh bats tests/unit/update.bats`
Expected: FAIL, the script doesn't exist.

- [ ] **Step 3: Implement**

`scripts/update.sh`:

```bash
#!/usr/bin/env bash
# Move the pinned versions forward, or back.
#   scripts/update.sh update     save the pins to .env.prev; move llama.cpp, Open WebUI and
#                                OVMS to their latest releases and SearXNG to its newest
#                                image; rebuild and restart
#   scripts/update.sh rollback   restore the .env.prev pins; rebuild and restart
set -euo pipefail
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
ENV_FILE=${AILAB_ENV:-$DIR/.env}
PREV=$(dirname "$ENV_FILE")/.env.prev
PINS=(LLAMA_CPP_REF OPEN_WEBUI_TAG OVMS_TAG SEARXNG_TAG)
# shellcheck source=../installer/lib.sh
source "$DIR/installer/lib.sh"

gh_latest() { gh_release_json "$1" latest 2>/dev/null | jq -r '.tag_name // empty' || true; }
searxng_latest() {
  curl -fsSL 'https://hub.docker.com/v2/repositories/searxng/searxng/tags/?page_size=25&ordering=last_updated' 2>/dev/null \
    | jq -r '[.results[].name | select(test("^[0-9]{4}\\.[0-9]+\\.[0-9]+-[0-9a-f]+$"))][0] // empty' || true
}
apply() {
  if [[ ${AILAB_NO_APPLY:-0} == 1 ]]; then return 0; fi
  sudo BUILD_IMAGES=1 START_STACK=1 "$DIR/install.sh" stack
}

case ${1:-} in
  update)
    if [[ -d $DIR/.git ]]; then git -C "$DIR" pull --ff-only || warn "git pull failed; continuing with the local copy"; fi
    declare -A new
    new[LLAMA_CPP_REF]=$(gh_latest ggml-org/llama.cpp)
    new[OPEN_WEBUI_TAG]=$(gh_latest open-webui/open-webui)
    ovms=$(gh_latest openvinotoolkit/model_server)
    new[OVMS_TAG]=${ovms:+${ovms#v}-gpu}
    new[SEARXNG_TAG]=$(searxng_latest)
    for k in "${PINS[@]}"; do
      [[ -n ${new[$k]} ]] || die "could not resolve the latest $k (GitHub rate limit? set GITHUB_TOKEN); nothing changed"
    done
    for k in "${PINS[@]}"; do printf '%s=%s\n' "$k" "$(env_get "$ENV_FILE" "$k")"; done >"$PREV"
    for k in "${PINS[@]}"; do
      old=$(env_get "$ENV_FILE" "$k")
      env_set "$ENV_FILE" "$k" "${new[$k]}"
      if [[ $old == "${new[$k]}" ]]; then log "$k $old (unchanged)"; else log "$k $old -> ${new[$k]}"; fi
    done
    apply
    ok "updated; if something broke: ailab rollback"
    ;;
  rollback)
    [[ -s $PREV ]] || die "no saved versions ($PREV): rollback works after an update"
    while IFS='=' read -r k v; do
      env_set "$ENV_FILE" "$k" "$v"
      log "$k -> $v"
    done <"$PREV"
    apply
    ok "rolled back"
    ;;
  *) echo "usage: $0 update|rollback" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Run to see them pass**

Run: `tests/ci-local.sh bats tests/unit/update.bats`
Expected: 4 `ok`.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/update.bats
git add --chmod=+x scripts/update.sh
git commit -m "Add ailab update/rollback over the four pinned versions"
```

### Task 14: `ailab bench` with the API key, models and `--spec`

**Files:**
- Rewrite: `scripts/bench.sh`

**Interfaces:**
- Consumes: `LLM_API_KEY`, `MAIN_THREADS`, `MAIN_THREADS_BATCH` (.env); `config/main.ini`; compose service `llm-main`.
- Produces: `scripts/bench.sh [--model M] [--spec M]`.

- [ ] **Step 1: Confirm the speculative-decoding keys at the pinned release**

WebFetch `https://raw.githubusercontent.com/ggml-org/llama.cpp/v0.5.0/docs/speculative.md` and the file list of `https://huggingface.co/api/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/tree/main`. Confirm:
- the MTP setup: `spec-type = draft-mtp` with the MTP GGUF as the model, and its `UD-Q4_K_M` file name;
- how an EAGLE3 draft file is chosen from a repo: `hf-repo-draft` plus a file key, since `-hf` quant selection skips `eagle3-` files.

Put the confirmed keys in `spec_extra` below. The keys written there are the expected ones.

- [ ] **Step 2: Rewrite the script**

`scripts/bench.sh`:

```bash
#!/usr/bin/env bash
# Prompt-processing and generation speed of the running llama-servers.
#   scripts/bench.sh                        main (default model) and aux
#   scripts/bench.sh --model gpt-oss-120b   one catalog model on the main router
#   scripts/bench.sh --spec qwen3.6-35b-a3b that model with and without speculative
#                                           decoding (stops llm-main while measuring)
# Measure with nobody else using the lab: everything shares memory bandwidth.
set -euo pipefail
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
ENV_FILE=${AILAB_ENV:-$DIR/.env}
envval() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1; }
KEY=$(envval LLM_API_KEY)
N_PROMPT=${N_PROMPT:-1024}
N_GEN=${N_GEN:-128}

bench() { # bench PORT MODEL LABEL
  local port=$1 model=$2 label=$3 prompt resp
  if ! curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then echo "$label: not up"; return 0; fi
  prompt=$(printf 'hello %.0s' $(seq "$N_PROMPT"))
  resp=$(jq -n --arg p "$prompt" --arg m "$model" --argjson n "$N_GEN" \
      '{model: $m, prompt: $p, n_predict: $n, cache_prompt: false, ignore_eos: true, temperature: 0}' |
    curl -fsS "http://127.0.0.1:$port/completion" -H "Authorization: Bearer $KEY" \
      -H 'Content-Type: application/json' -d @-)
  jq -r --arg l "$label" '.timings |
    "\($l): prompt \(.prompt_n) tok @ \(.prompt_per_second | floor) t/s | " +
    "gen \(.predicted_n) tok @ \(.predicted_per_second * 10 | floor / 10) t/s"' <<<"$resp"
}

# Speculative-decoding settings to compare, per catalog model (docs/ARCHITECTURE.md).
spec_extra() {
  case $1 in
    qwen3.6-35b-a3b) printf '%s\n' 'hf-repo = unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_M' 'spec-type = draft-mtp' ;;
    gpt-oss-120b) printf '%s\n' 'spec-type = draft-eagle3' 'hf-repo-draft = ggml-org/gpt-oss-120b-GGUF' \
      'hf-file-draft = eagle3-gpt-oss-120b-Q8_0.gguf' ;;
    *) return 1 ;;
  esac
}

spec() { # spec MODEL: a temporary router with MODEL and MODEL-spec
  local model=$1 extra ini=$DIR/config/bench-spec.ini keys
  extra=$(spec_extra "$model") || { echo "no speculative-decoding settings for $model" >&2; exit 2; }
  keys=$(sed 's/ *=.*//' <<<"$extra" | paste -sd'|')
  {
    printf 'version = 1\n\n[*]\n'
    sed -n '/^\[\*\]/,/^\[/{/^\[/d;p}' "$DIR/config/main.ini"
    printf '\n[%s]\n' "$model"
    sed -n "/^\[$model\]/,/^\[/{/^\[/d;p}" "$DIR/config/main.ini"
    printf '\n[%s-spec]\n' "$model"
    sed -n "/^\[$model\]/,/^\[/{/^\[/d;p}" "$DIR/config/main.ini" | grep -Ev "^($keys) *=" || true
    printf '%s\n' "$extra"
  } >"$ini"
  echo "stopping llm-main while measuring (it restarts afterwards)"
  docker compose --project-directory "$DIR" stop llm-main >/dev/null
  trap 'docker rm -f ailab-bench >/dev/null 2>&1; docker compose --project-directory "$DIR" start llm-main >/dev/null' EXIT
  docker compose --project-directory "$DIR" run -d --rm --name ailab-bench -p 127.0.0.1:8091:8080 \
    -v "$ini:/config/bench.ini:ro" llm-main \
    --models-preset /config/bench.ini --models-max 1 \
    --threads "$(envval MAIN_THREADS)" --threads-batch "$(envval MAIN_THREADS_BATCH)" \
    --host 0.0.0.0 --port 8080 >/dev/null
  until curl -fsS http://127.0.0.1:8091/health >/dev/null 2>&1; do sleep 2; done
  bench 8091 "$model" "$model (plain)"
  bench 8091 "$model-spec" "$model (speculative)"
  echo "If speculative wins, add these lines to [$model] in config/main.ini:"
  printf '  %s\n' "$extra"
}

case ${1:-} in
  "") bench 8081 qwen3.6-35b-a3b "llm-main qwen3.6-35b-a3b"; bench 8082 qwen3-4b "llm-aux qwen3-4b" ;;
  --model) bench 8081 "${2:?--model needs a name}" "llm-main $2" ;;
  --spec) spec "${2:?--spec needs a model name}" ;;
  -h | --help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown option $1 (--help)" >&2; exit 2 ;;
esac
```

- [ ] **Step 3: Check it against the smoke stack**

Run: `KEEP=1 tests/smoke/in-dind.sh`, then:

```bash
docker exec ailab-smoke-dind bash -c 'cd /work && AILAB_ENV=.smoke/env scripts/bench.sh --model gpt-oss-120b'
```

Expected: one line `llm-main gpt-oss-120b: prompt ... t/s | gen ... t/s`. (`--spec` needs the real models; it is exercised on the hardware, V8.) Then `docker rm -f ailab-smoke-dind`.

- [ ] **Step 4: Lint and commit**

Run: `tests/ci-local.sh` → `all checks passed`.

```bash
git add scripts/bench.sh
git commit -m "bench: API key, per-model runs, speculative decoding comparison"
```

---

## Phase 6: CI

**Skills & tools:** none (plain edit); `gh run watch` after Jordan approves a push
**Files:** `.github/workflows/ci.yml`
**Verification:** `tests/ci-local.sh` passes (yamllint checks the workflow); the GitHub run is green once pushed

### Task 15: CI runs the same checks, plus the smoke test

**Files:**
- Rewrite: `.github/workflows/ci.yml`

- [ ] **Step 1: Rewrite the workflow**

```yaml
name: ci

on:
  push:
  pull_request:
  workflow_dispatch:

jobs:
  checks:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v5

      - name: Tools
        run: |
          sudo apt-get update -q
          sudo apt-get install -y -q shellcheck yamllint bats jq

      - name: Lint, unit tests, compose config, installer dry run
        run: tests/ci-checks.sh

  smoke:
    # The whole stack on the CPU; ~45 min. On PRs, main and by hand.
    if: github.event_name != 'push' || github.ref == 'refs/heads/main'
    needs: checks
    runs-on: ubuntu-24.04
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v5

      - name: Free disk space for the images and models
        run: |
          sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL
          docker system prune -af
          df -h /

      - name: CPU smoke test
        run: tests/smoke/run.sh
```

- [ ] **Step 2: Lint it**

Run: `tests/ci-local.sh`
Expected: yamllint passes, then `all checks passed`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "CI: shared checks script, bats, and the CPU smoke test"
```

---

## Phase 7: Documentation

**Skills & tools:** engineering:documentation
**Files:** `README.md`, `docs/INSTALL.md`, `docs/ARCHITECTURE.md`, `docs/superpowers/specs/2026-09-27-daily-driver-design.md`
**Verification:** every command in the docs exists in `scripts/ailab help` or the installer; `tests/ci-local.sh` still passes

### Task 16: Docs for the daily driver

**Files:**
- Rewrite: `README.md`
- Modify: `docs/INSTALL.md`, `docs/ARCHITECTURE.md`, the spec

- [ ] **Step 1: Rewrite `README.md`**

````markdown
# projectAILab

A private AI workstation for the people on your network, on one machine:
**Intel Core Ultra 9 185H + NVIDIA RTX 5060 Ti + 96 GB DDR5**. Every piece of
silicon does the work it is best at, and you use it from a browser, a phone or
your IDE.

## What you can do with it

- **Chat, with images.** Pick a model from the dropdown: `qwen3.6-35b-a3b` (fast,
  reads images) or `gpt-oss-120b` (deep reasoning). The lab loads it for you.
- **Ask your documents.** Upload PDFs, notes and manuals; answers use hybrid
  search and a reranker, both on the NPU.
- **Talk to it.** Speech in (Whisper, NPU) and spoken replies (Kokoro), from any
  device on your tailnet.
- **Code with it.** IDE agents (Continue, Cline) use the main models over HTTPS;
  tab-completion runs on the Arc iGPU. `ailab connect` prints the settings.
- **Search the web.** Private web search through SearXNG, plus tools and MCP servers.

## Install

On a fresh **Ubuntu 24.04 LTS**, with the firmware settings from
[docs/INSTALL.md](docs/INSTALL.md):

```bash
sudo apt install -y git jq
git clone https://github.com/JW-AUTOMATIONS/projectAILab.git && cd projectAILab
./install.sh --dry-run      # optional: shows every change without making it
sudo ./install.sh           # drivers, docker, Tailscale, images, service
sudo reboot                 # the stack starts by itself afterwards
sudo /opt/ailab/install.sh verify
```

Then open the address `ailab connect` prints (`https://ailab.<tailnet>.ts.net`).
The first account you create is the admin; others wait for your approval.

## Day to day

```bash
ailab status          # containers, GPU, NPU devices, memory
ailab models          # the model catalog and what is loaded
ailab connect         # addresses and IDE settings
ailab logs llm-main   # follow one service
ailab edit            # change settings (.env) and apply them
ailab backup          # also runs daily at 03:30
ailab update          # newer llama.cpp / Open WebUI / OVMS / SearXNG; `ailab rollback` undoes it
```

Add a model: edit `/opt/ailab/config/main.ini` (one `[section]` per model), then
`ailab restart llm-main`. How it fits together: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Layout

```
install.sh, installer/     staged, idempotent host installer (docs/INSTALL.md)
compose.yaml, .env.example the services and their settings
templates/                 model catalog and SearXNG settings (copied to config/)
docker/llama-cuda/         llama.cpp for the RTX 5060 Ti (CUDA 12.8, sm_120)
docker/llama-vulkan/       llama.cpp for the Arc iGPU (Vulkan), same release
services/ovms/             OpenVINO Model Server model setup (NPU)
host/scripts/              host and feature checks, .env detection
scripts/                   the `ailab` command
tests/                     unit tests (bats), CPU smoke test, local CI runner
```

## Development

```bash
tests/ci-local.sh          # lint, unit tests, compose config, installer dry run (any Docker host)
tests/smoke/in-dind.sh     # the whole stack on the CPU (Docker Desktop); tests/smoke/run.sh on Linux
```
````

- [ ] **Step 2: Update `docs/INSTALL.md`**

- **Section 3 (Run the installer):** add `TAILSCALE_AUTHKEY` and `TAILSCALE_ENABLE` rows to the settings table.
- **New subsection "Tailscale" after section 3:**
  - install the Tailscale app on each phone or laptop and join your tailnet;
  - in the admin console DNS page, enable **MagicDNS**, then **HTTPS Certificates**;
  - share the `ailab` machine with other people from the admin console;
  - without an auth key the installer prints a login URL.
- **"What the installer does" table:** add the `tailscale` row. Update the `stack` row to "generated `config/`, two llama.cpp images, backup timer" and the `storage` row to `models/ovms`.
- **Day-to-day block:** replace it with the README's.
- **New section "Changing settings":** most Open WebUI settings in `.env` seed its database on first start; after that, change them in Admin Settings. Name the affected keys (`LLM_API_KEY`, `TTS_VOICE`, `WEBUI_URL`).
- **New section "Backups":** what's in the archive, where it goes (`/srv/ai/backups`), and the restore steps:

```bash
ailab stop
mkdir /tmp/ailab-restore && tar -xzf /srv/ai/backups/ailab-<stamp>.tar.gz -C /tmp/ailab-restore
sudo cp /tmp/ailab-restore/env /opt/ailab/.env && sudo cp -r /tmp/ailab-restore/config /opt/ailab/
docker run --rm --entrypoint sh -v ailab_open-webui:/data -v /tmp/ailab-restore:/in \
  ghcr.io/open-webui/open-webui:<OPEN_WEBUI_TAG> -c 'rm -rf /data/* && tar -xzf /in/open-webui.tar.gz -C /data'
ailab start
```

- **Troubleshooting:**
  - replace the `npu-worker` row with an OVMS row: `ailab check` names the failing model; set its `OVMS_*_DEVICE=CPU`, then `ailab edit`;
  - add "microphone button greyed out → use the HTTPS address, not `http://<ip>:3000`";
  - add "chat stops updating through Tailscale → set `ENABLE_WEBSOCKET_SUPPORT=false` in Admin or compose (V10)";
  - replace the `MAIN_N_CPU_MOE` advice with "`--fit` sizes offload; pin `n-cpu-moe` per model in `config/main.ini` only if a benchmark says so".
- **Removing it:** add `ailab-backup.*` units, `sudo tailscale serve reset`, `/etc/apt/sources.list.d/tailscale.list`.

- [ ] **Step 3: Update `docs/ARCHITECTURE.md`**

- **Silicon map table and diagram:**
  - `llm-main` is the router (catalog in `config/main.ini`, `--fit`);
  - add `llm-fim` on the iGPU;
  - `npu-worker` becomes `ovms` (embeddings, reranker, Whisper on the NPU, Kokoro on the CPU);
  - add `searxng`;
  - replace the LAN/bond diagram's front door with Tailscale serve 443/8443/10000.
- **Replace "Why llama.cpp `--n-cpu-moe`…" / sizing text:** keep the MoE-in-RAM rationale and the sizing table; replace the tuning loop with `--fit` and per-model overrides; add the spec's memory budget table.
- **Replace the "NPU worker" section with "OVMS on the NPU":** the model table, `ovms-init` device markers, the `--max_length 2048` / `--pooling LAST` rationale, and no automatic fallback.
- **New section "Research refresh, 2026-09-27":** the spec's revision-2 table in prose, with its sources (catalog unchanged and why, speculative decoding results, Open WebUI licence clause, the llama.cpp docker-tag finding).
- **Dify section:** ports 8081/8083 now need the API key (`LLM_API_KEY`); via Tailscale use `https://ailab.<tailnet>.ts.net:8443/v1`.

- [ ] **Step 4: Bring the spec in line with the implementation**

In the spec:
- `models/main.ini` → `config/main.ini` everywhere;
- the SearXNG secret comes from `SEARXNG_SECRET` in `.env` (env override), not from `server.secret_key` in `settings.yml`, so the generated file is the same on every run;
- the NPU compile cache is OVMS's `--cache_dir /models/cache` on the `ovms` command, not `--plugin_config`;
- the smoke test uses `ggml-org/Qwen2.5-Coder-0.5B-Q8_0-GGUF` (FIM-capable) for every llama role, not SmolLM2;
- smoke step 5 (device marker) is covered by `tests/unit/ovms_init.bats`;
- mark V4–V6 with the smoke test's outcome.

- [ ] **Step 5: Check and commit**

Run: `tests/ci-local.sh` → `all checks passed`. Check by eye that every `ailab …` command in the docs appears in `scripts/ailab help`.

```bash
git add README.md docs
git commit -m "Docs for the daily-driver stack: uses, Tailscale, settings, backups"
```

---

## Phase 8: Close-out

**Skills & tools:** superpowers:requesting-code-review, superpowers:receiving-code-review, superpowers:verification-before-completion, superpowers:finishing-a-development-branch
**Files:** any fixes from review
**Verification:** `tests/ci-local.sh` and `tests/smoke/in-dind.sh` both pass on the final tree; the GitHub run is green after Jordan approves the push

### Task 17: Review, final verification, integration

- [ ] **Step 1: Code review**

Use superpowers:requesting-code-review on `main..feat/daily-driver`, with the spec and this plan as the requirements. Handle the findings with superpowers:receiving-code-review: verify each finding before changing anything, and push back on wrong ones with evidence.

- [ ] **Step 2: Final verification on the exact tree**

Run: `tests/ci-local.sh` → `all checks passed`
Run: `tests/smoke/in-dind.sh` → `SMOKE TEST PASSED`
Record both outputs' last lines in the report (superpowers:verification-before-completion).

- [ ] **Step 3: Update memory**

Update `projectailab-direction` in the memory directory: the redesign is implemented, which verification items remain for the hardware (V1, V2, V7–V10), and where they are listed (the spec's "Still open" table).

- [ ] **Step 4: Integrate**

Use superpowers:finishing-a-development-branch. Ask Jordan before pushing. On his OK:
- push `feat/daily-driver`;
- let CI run the checks and the smoke job (`gh run watch`);
- merge to `main` the way he chooses.
