# shellcheck shell=bash
# NVIDIA driver for the RTX 5060 Ti (Blackwell).
#
# Blackwell needs branch >= 570 and the *open* kernel modules. Ubuntu ships
# Canonical-signed prebuilt modules (linux-modules-nvidia-<branch>-open-<flavour>),
# which avoid DKMS and work with Secure Boot, so those are preferred.

NVIDIA_MIN_BRANCH=570

# Echo "<branch>-open" or "<branch>-server-open".
nvidia_pick_branch() {
  local flavour=$1 rec b
  if [[ $NVIDIA_DRIVER_BRANCH != auto ]]; then
    b=$NVIDIA_DRIVER_BRANCH
    [[ $b == *open ]] || b="$b-open"
    echo "$b"
    return
  fi

  # 1. What ubuntu-drivers recommends for this exact GPU, if it is an open branch >= 570.
  rec=$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/ {print $3}' | grep -E '^nvidia-driver-[0-9]+(-server)?-open$' | head -1 || true)
  if [[ -n $rec ]]; then
    b=${rec#nvidia-driver-}
    if ((${b%%-*} >= NVIDIA_MIN_BRANCH)); then
      echo "$b"
      return
    fi
  fi

  # 2. Newest open branch that has real (non-transitional) signed modules for this kernel.
  local cand info
  for cand in $(apt-cache search --names-only '^nvidia-driver-[0-9]+-open$' | awk '{print $1}' | sed 's/nvidia-driver-//; s/-open//' | sort -rn); do
    ((cand >= NVIDIA_MIN_BRANCH)) || continue
    info=$(apt-cache show "linux-modules-nvidia-$cand-open-$flavour" 2>/dev/null || true)
    if [[ $info == *Description* && $info != *[Tt]ransitional* ]]; then
      echo "$cand-open"
      return
    fi
  done
}

stage_nvidia() {
  if ! has_nvidia_gpu && [[ ${FORCE_NVIDIA:-0} != 1 ]]; then
    warn "no NVIDIA GPU detected, skipping (FORCE_NVIDIA=1 to install anyway)"
    return 0
  fi

  local flavour branch modules
  flavour=$(state_get kernel-flavour)
  flavour=${flavour:-generic-hwe-24.04}
  branch=$(nvidia_pick_branch "$flavour")
  [[ -n $branch ]] || die "no NVIDIA open driver branch >= $NVIDIA_MIN_BRANCH found in apt"
  pkg_available "nvidia-utils-${branch%-open}" || die "NVIDIA branch $branch is not available in apt"

  # Desktop: the full driver (X/Wayland bits, nvidia-settings). Server: the
  # headless compute driver only, as Ubuntu documents for GPU servers.
  local desktop=0 userspace=()
  if systemctl list-unit-files display-manager.service 2>/dev/null | grep -q display-manager; then desktop=1; fi
  if [[ $desktop == 1 ]]; then
    userspace=("nvidia-driver-$branch")
  else
    userspace=("nvidia-headless-no-dkms-$branch" "nvidia-utils-${branch%-open}")
  fi
  log "NVIDIA driver branch: $branch ($([[ $desktop == 1 ]] && echo desktop || echo headless), kernel flavour $flavour)"

  modules="linux-modules-nvidia-$branch-$flavour"
  if pkg_installed "${userspace[0]}" && { pkg_installed "$modules" || pkg_installed "nvidia-dkms-$branch"; }; then
    ok "${userspace[0]} already installed ($(pkg_version "${userspace[0]}"))"
  else
    if pkg_available "$modules"; then
      # Canonical-signed prebuilt modules: no DKMS build, fine with Secure Boot.
      if [[ $desktop == 1 ]]; then apt_install_rec "$modules" "${userspace[@]}"; else apt_install "$modules" "${userspace[@]}"; fi
    else
      warn "no prebuilt signed modules for $flavour; falling back to DKMS"
      if mokutil --sb-state 2>/dev/null | grep -q enabled; then
        warn "Secure Boot is on: run 'sudo update-secureboot-policy --enroll-key', set a password, reboot and choose 'Enroll MOK'"
      fi
      if [[ $desktop == 1 ]]; then
        apt_install_rec "nvidia-driver-$branch"
      else
        apt_install "nvidia-headless-$branch" "nvidia-utils-${branch%-open}"
      fi
    fi
    need_reboot "NVIDIA driver $branch installed"
  fi
  state_set nvidia-branch "$branch"

  # Loaded module older than the installed userspace -> reboot.
  if [[ -r /proc/driver/nvidia/version ]]; then
    local loaded installed
    loaded=$(awk '/NVRM version/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) {print $i; exit}}' /proc/driver/nvidia/version)
    installed=$(pkg_version "nvidia-utils-${branch%-open}" | cut -d- -f1)
    if [[ -n $installed && $loaded != "$installed" ]]; then
      need_reboot "NVIDIA kernel module $loaded != userspace $installed"
    fi
    grep -qi 'open kernel module' /proc/driver/nvidia/version \
      || need_reboot "proprietary NVIDIA module is loaded; Blackwell needs the open module"
  fi

  run systemctl enable nvidia-persistenced 2>/dev/null || true

  if [[ $HOLD_NVIDIA_AUTOUPDATES == 1 ]]; then
    write_file /etc/apt/apt.conf.d/51ailab-nvidia-hold <<'EOF'
// ailab: never let unattended-upgrades swap the NVIDIA driver under a running
// system. Update deliberately with `sudo apt full-upgrade && sudo reboot`.
Unattended-Upgrade::Package-Blacklist {
    "nvidia-";
    "libnvidia-";
    "linux-modules-nvidia-";
    "linux-objects-nvidia-";
    "linux-signatures-nvidia-";
};
EOF
  fi

  # Desktop installs: run the desktop on the iGPU, leave the whole card to CUDA.
  if [[ -n $PRIME_MODE ]] && command -v prime-select >/dev/null \
    && systemctl list-unit-files display-manager.service >/dev/null 2>&1 \
    && [[ $(prime-select query 2>/dev/null) != "$PRIME_MODE" ]]; then
    run prime-select "$PRIME_MODE"
    need_reboot "prime-select $PRIME_MODE"
  fi
  ok "NVIDIA stage done"
}
