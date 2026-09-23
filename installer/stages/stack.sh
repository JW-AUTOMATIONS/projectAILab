# shellcheck shell=bash
# Install the compose stack to AILAB_DIR, generate .env, build images and
# register ailab.service so it comes up on every boot.

stack_sync_repo() {
  if [[ $(readlink -f "$REPO_DIR") == $(readlink -f "$AILAB_DIR" 2>/dev/null || echo "$AILAB_DIR") ]]; then
    log "running from $AILAB_DIR, no copy needed"
    return 0
  fi
  run mkdir -p "$AILAB_DIR"
  # .env and local config belong to the installed copy; never overwrite them.
  run rsync -a --delete \
    --exclude .env --exclude install.conf --exclude models/ --exclude '__pycache__/' \
    "$REPO_DIR/" "$AILAB_DIR/"
  ok "stack files synced to $AILAB_DIR"
}

stack_vram_mib() {
  command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc 0-9
}

stack_env() {
  local env=$AILAB_DIR/.env fresh=0
  if [[ ! -f $env ]]; then
    run cp "$AILAB_DIR/.env.example" "$env"
    fresh=1
  fi
  if [[ $DRY_RUN == 1 && ! -f $env ]]; then
    log "would generate $env from .env.example"
    return 0
  fi
  run chmod 600 "$env"

  # Host-specific values: cpusets, Intel render node, render GID, WebUI secret.
  run "$AILAB_DIR/host/scripts/gen-env.sh" --write "$env"

  if [[ $DRY_RUN != 1 && -z $(env_get "$env" RENDER_GID) ]]; then
    warn "RENDER_GID could not be detected; set it in $env (getent group render) or compose will refuse to start"
  fi
  env_set "$env" MODELS_DIR "$DATA_ROOT/models"
  if [[ -n $INTEL_GPU_PPA ]]; then env_set "$env" INTEL_GPU_PPA "$INTEL_GPU_PPA"; fi
  [[ -n $HF_TOKEN ]] && env_set "$env" HF_TOKEN "$HF_TOKEN"

  # Pin the NPU user-space driver in the container to what the host runs.
  local npu_tag
  npu_tag=$(state_get npu-driver-tag)
  [[ -n $npu_tag ]] && env_set "$env" NPU_DRIVER_TAG "$npu_tag"

  # Pin llama.cpp to its latest release instead of building a moving master.
  if [[ $(env_get "$env" LLAMA_CPP_REF) == master ]]; then
    local ref
    ref=$(gh_release_json ggml-org/llama.cpp latest 2>/dev/null | jq -r '.tag_name // empty' || true)
    if [[ -n $ref ]]; then
      env_set "$env" LLAMA_CPP_REF "$ref"
      log "llama.cpp pinned to $ref"
    else
      warn "could not resolve the latest llama.cpp release; building master"
    fi
  fi

  # First install only: size the main model to the card.
  if [[ $fresh == 1 ]]; then
    local vram
    vram=$(stack_vram_mib || true)
    if [[ -n $vram ]] && ((vram < 12000)); then
      log "${vram} MiB VRAM: using the 8 GB preset (Qwen3-30B-A3B, all experts on CPU)"
      env_set "$env" MAIN_MODEL_ARGS "-hf unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF:Q4_K_M"
      env_set "$env" MAIN_N_CPU_MOE 48
    else
      log "${vram:-unknown (driver not loaded yet)} MiB VRAM: using the 16 GB preset (gpt-oss-120b)"
    fi
  fi
  [[ -n $AILAB_USER ]] && run chown "$AILAB_USER:" "$env"
  ok ".env ready ($env)"
}

stack_unit() {
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
  run systemctl daemon-reload
  run systemctl enable ailab.service
  run ln -sfn "$AILAB_DIR/scripts/ailab" /usr/local/bin/ailab
}

stage_stack() {
  command -v docker >/dev/null || [[ $DRY_RUN == 1 ]] || die "docker is not installed (run the docker stage first)"

  stack_sync_repo
  if [[ -n $AILAB_USER ]]; then run chown -R "$AILAB_USER:" "$AILAB_DIR"; fi
  stack_env
  stack_unit

  if [[ $BUILD_IMAGES == 1 ]]; then
    log "pulling images and building llama.cpp (CUDA) + npu-worker; the CUDA build takes a while"
    run docker compose -f "$AILAB_DIR/compose.yaml" --project-directory "$AILAB_DIR" pull --ignore-buildable --quiet
    run docker compose -f "$AILAB_DIR/compose.yaml" --project-directory "$AILAB_DIR" build --pull
    ok "images ready"
  fi

  if [[ -s $REBOOT_FLAG ]]; then
    log "not starting the stack now: a reboot is pending (it starts by itself after the reboot)"
  elif [[ $START_STACK == 1 ]]; then
    run systemctl restart ailab.service
    ok "stack started; first start downloads the models (see: ailab logs llm-main)"
  fi
}
