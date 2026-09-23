# shellcheck shell=bash
# End-to-end health check. Safe to run any time: sudo ./install.sh verify

stage_verify() {
  local failed=0 dir=$AILAB_DIR
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

  local port name body
  for port in 8081:llm-main 8082:llm-aux 8083:npu-worker; do
    name=${port#*:}
    port=${port%%:*}
    if body=$(curl -fsS --max-time 5 "http://127.0.0.1:$port/health" 2>/dev/null); then
      ok "$name healthy ${body:0:80}"
    else
      warn "$name not answering on :$port yet (first start downloads models: ailab logs $name)"
    fi
  done
  if curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:3000/health 2>/dev/null; then
    ok "open-webui up"
  else
    warn "open-webui not answering on :3000 yet"
  fi

  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
  printf '\n  Open WebUI:  http://%s:3000\n' "${ip:-<host>}"
  printf '  Operate:     ailab status | ailab logs <service> | ailab bench\n\n'
  return $failed
}
