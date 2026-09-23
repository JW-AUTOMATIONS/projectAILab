#!/usr/bin/env bash
# AI Lab installer for Ubuntu 24.04 LTS on Core Ultra 9 185H + RTX 5060 Ti.
#
#   sudo ./install.sh                  # everything, in order
#   sudo ./install.sh nvidia docker    # only some stages
#   ./install.sh --dry-run             # print what would change, change nothing
#   sudo ./install.sh verify           # health check (after the reboot)
#
# Every stage is idempotent: re-running is safe and only changes what drifted.
# Settings: install.conf.example -> install.conf. See docs/INSTALL.md.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=installer/lib.sh
source "$REPO_DIR/installer/lib.sh"

ALL_STAGES=(preflight base nvidia intel-gpu npu storage docker network tuning stack)
CONFIG_KEYS=(AILAB_USER AILAB_DIR INSTALL_HWE_KERNEL NVIDIA_DRIVER_BRANCH HOLD_NVIDIA_AUTOUPDATES
  PRIME_MODE INTEL_GPU_PPA NPU_DRIVER_TAG DATA_ROOT MODELS_DISK EXTEND_ROOT_LV DOCKER_DATA_ON_DATA_ROOT
  BOND_ENABLE BOND_MODE BOND_INTERFACES BOND_ADDRESS BOND_GATEWAY BOND_DNS BOND_APPLY
  CPU_EPP DISABLE_SLEEP BUILD_IMAGES START_STACK AUTO_REBOOT HF_TOKEN GITHUB_TOKEN)

usage() {
  cat <<EOF
Usage: sudo ./install.sh [options] [stage...]

Stages (default: all, in this order):
  ${ALL_STAGES[*]}
  verify   health checks; run after the post-install reboot

Options:
  -n, --dry-run        show the changes without making them
  -y, --yes            answer yes to prompts (the disk wipe still needs WIPE_MODELS_DISK=1)
  -c, --config FILE    extra config file (after /etc/ailab/install.conf and ./install.conf)
  -h, --help
EOF
}

load_config() {
  local key f
  local -A from_env=()
  for key in "${CONFIG_KEYS[@]}"; do
    [[ -n ${!key+x} ]] && from_env[$key]=${!key}
  done
  for f in /etc/ailab/install.conf "$REPO_DIR/install.conf" ${CONFIG_FILE:+"$CONFIG_FILE"}; do
    if [[ -f $f ]]; then
      # shellcheck source=/dev/null
      source "$f"
      log "config: $f"
    fi
  done
  for key in "${!from_env[@]}"; do printf -v "$key" '%s' "${from_env[$key]}"; done

  AILAB_USER=${AILAB_USER:-${SUDO_USER:-}}
  AILAB_DIR=${AILAB_DIR:-/opt/ailab}
  INSTALL_HWE_KERNEL=${INSTALL_HWE_KERNEL:-1}
  NVIDIA_DRIVER_BRANCH=${NVIDIA_DRIVER_BRANCH:-auto}
  HOLD_NVIDIA_AUTOUPDATES=${HOLD_NVIDIA_AUTOUPDATES:-1}
  PRIME_MODE=${PRIME_MODE-on-demand}
  INTEL_GPU_PPA=${INTEL_GPU_PPA-ppa:kobuk-team/intel-graphics}
  NPU_DRIVER_TAG=${NPU_DRIVER_TAG:-latest}
  DATA_ROOT=${DATA_ROOT:-/srv/ai}
  MODELS_DISK=${MODELS_DISK:-}
  EXTEND_ROOT_LV=${EXTEND_ROOT_LV:-1}
  DOCKER_DATA_ON_DATA_ROOT=${DOCKER_DATA_ON_DATA_ROOT:-1}
  BOND_ENABLE=${BOND_ENABLE:-0}
  BOND_MODE=${BOND_MODE:-802.3ad}
  BOND_INTERFACES=${BOND_INTERFACES:-}
  BOND_ADDRESS=${BOND_ADDRESS:-}
  BOND_GATEWAY=${BOND_GATEWAY:-}
  BOND_DNS=${BOND_DNS-1.1.1.1 9.9.9.9}
  BOND_APPLY=${BOND_APPLY:-0}
  CPU_EPP=${CPU_EPP:-performance}
  DISABLE_SLEEP=${DISABLE_SLEEP:-1}
  BUILD_IMAGES=${BUILD_IMAGES:-1}
  START_STACK=${START_STACK:-1}
  AUTO_REBOOT=${AUTO_REBOOT:-0}
  HF_TOKEN=${HF_TOKEN:-}
  GITHUB_TOKEN=${GITHUB_TOKEN:-}
  export GITHUB_TOKEN
}

main() {
  local stages=() s
  while (($#)); do
    case $1 in
      -n | --dry-run) DRY_RUN=1 ;;
      -y | --yes) ASSUME_YES=1 ;;
      -c | --config) CONFIG_FILE=${2:?--config needs a file}; shift ;;
      -h | --help) usage; exit 0 ;;
      -*) usage >&2; exit 2 ;;
      *) stages+=("$1") ;;
    esac
    shift
  done
  ((${#stages[@]})) || stages=("${ALL_STAGES[@]}")

  for s in "${stages[@]}"; do
    [[ -f $REPO_DIR/installer/stages/$s.sh ]] || die "unknown stage '$s' (see --help)"
  done

  if [[ $DRY_RUN != 1 ]]; then
    [[ $EUID -eq 0 ]] || die "run as root: sudo $0 $*"
    mkdir -p "$AILAB_STATE_DIR"
    clear_stale_reboot_flag
    exec > >(tee -a /var/log/ailab-install.log) 2>&1
    log "log: /var/log/ailab-install.log"
  else
    log "dry run: nothing will be changed"
  fi

  load_config
  ensure_prereqs

  for s in "${stages[@]}"; do
    # shellcheck source=/dev/null
    source "$REPO_DIR/installer/stages/$s.sh"
    stage "$s"
    "stage_${s//-/_}"
  done

  if [[ -s $REBOOT_FLAG ]]; then
    printf '\n%sReboot required:%s\n' "$c_bold" "$c_reset"
    sort -u "$REBOOT_FLAG" | sed 's/^/  - /'
    echo "The stack starts by itself after the reboot (ailab.service). Then check it with:"
    echo "  sudo $AILAB_DIR/install.sh verify"
    if [[ $AUTO_REBOOT == 1 ]]; then
      rm -f "$REBOOT_FLAG"
      log "AUTO_REBOOT=1: rebooting in 10 s"
      sleep 10
      systemctl reboot
    fi
  elif [[ " ${stages[*]} " == *" stack "* && $DRY_RUN != 1 ]]; then
    source "$REPO_DIR/installer/stages/verify.sh"
    stage verify
    stage_verify || true
  fi
}

main "$@"
