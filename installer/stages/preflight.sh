# shellcheck shell=bash
# Checks that nothing else depends on; changes nothing.

stage_preflight() {
  # shellcheck source=/dev/null
  source /etc/os-release
  if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 ]]; then
    [[ ${FORCE_OS:-0} == 1 ]] || die "Ubuntu 24.04 LTS required (found ${PRETTY_NAME:-unknown}); FORCE_OS=1 to override"
    warn "unsupported OS ${PRETTY_NAME:-unknown}, continuing because FORCE_OS=1"
  fi
  [[ $(uname -m) == x86_64 ]] || die "x86_64 required"
  ok "OS: $PRETTY_NAME, kernel $(uname -r)"

  local cpu
  cpu=$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo)
  ok "CPU: $cpu"
  [[ $cpu == *"Ultra 9 185H"* ]] || warn "not a Core Ultra 9 185H; cpusets are still detected, other defaults may not fit"

  if has_nvidia_gpu; then ok "NVIDIA GPU present"
  else warn "no NVIDIA GPU visible on PCI (eGPU/OCuLink not connected or powered?); the nvidia stage will be skipped"; fi
  if has_intel_npu; then ok "Intel NPU present"
  else warn "no Intel NPU on PCI; check it is enabled in firmware setup"; fi
  if pci_has 0x8086 '^0x03'; then ok "Intel iGPU present"
  else warn "Intel iGPU not on PCI - many boards disable it when a dGPU is fitted; enable 'iGPU multi-monitor' in firmware setup"; fi

  local mem_gb
  mem_gb=$(awk '/MemTotal/ {printf "%d", $2 / 1048576}' /proc/meminfo)
  ok "RAM: ${mem_gb} GiB"

  if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q enabled; then
    log "Secure Boot is enabled: fine with Ubuntu's signed NVIDIA modules; a DKMS fallback would need MOK enrollment"
  fi

  if [[ -z $AILAB_USER || $AILAB_USER == root ]]; then
    warn "no non-root user detected (run via sudo from your account, or set AILAB_USER)"
  else
    id "$AILAB_USER" >/dev/null 2>&1 || die "AILAB_USER=$AILAB_USER does not exist"
    ok "stack owner: $AILAB_USER"
  fi

  local host
  for host in archive.ubuntu.com download.docker.com nvidia.github.io api.github.com ghcr.io huggingface.co; do
    if curl -fsS -o /dev/null --max-time 10 --head "https://$host" 2>/dev/null \
      || curl -sS -o /dev/null --max-time 10 "https://$host" 2>/dev/null; then
      ok "reachable: $host"
    else
      warn "cannot reach https://$host - later stages will fail without it"
    fi
  done

  local free_gb target=$DATA_ROOT
  while [[ ! -d $target ]]; do target=$(dirname "$target"); done
  free_gb=$(df -BG --output=avail "$target" | tail -1 | tr -dc 0-9)
  # The storage stage grows an LVM root into free volume-group space first.
  local src vg_free
  src=$(findmnt -no SOURCE /)
  if [[ ${EXTEND_ROOT_LV:-1} == 1 && $(lsblk -no TYPE "$src" 2>/dev/null) == lvm ]]; then
    vg_free=$(vgs --noheadings --units g --nosuffix -o vg_free "$(lvs --noheadings -o vg_name "$src" 2>/dev/null | xargs)" 2>/dev/null | xargs | cut -d. -f1 || true)
    free_gb=$((free_gb + ${vg_free:-0}))
  fi
  if [[ -z $MODELS_DISK ]] && ((free_gb < 150)); then
    warn "only ${free_gb} GB free under $target; the default models + images need ~120 GB"
  fi

  if [[ -n $MODELS_DISK ]]; then
    [[ -b $MODELS_DISK ]] || die "MODELS_DISK=$MODELS_DISK is not a block device"
    log "MODELS_DISK=$MODELS_DISK ($(lsblk -dno SIZE,MODEL "$MODELS_DISK" | xargs)) will hold $DATA_ROOT"
  fi
}
