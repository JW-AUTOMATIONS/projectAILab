#!/usr/bin/env bash
# Detect host-specific values for .env: CPU core classes on Intel hybrid CPUs,
# the Intel render node, and the render group id.
#
#   host/scripts/gen-env.sh              # print KEY=VALUE lines
#   host/scripts/gen-env.sh --write .env # update those keys in .env in place
#
# Core classes on Meteor Lake (185H: 6P + 8E + 2 LP-E, 22 threads):
#   P-core   -> listed in /sys/devices/cpu_core/cpus
#   E-core   -> listed in /sys/devices/cpu_atom/cpus and has an L3 (compute tile)
#   LP E-core-> listed in cpu_atom but has no L3 (SoC tile); left to the OS
set -euo pipefail

SYSFS=${SYSFS_ROOT:-/sys}
DEV=${DEV_ROOT:-/dev}
CPU_DIR=$SYSFS/devices/system/cpu

expand() { # "0-3,8" -> one cpu per line
  local IFS=, part
  for part in $1; do
    if [[ $part == *-* ]]; then seq "${part%-*}" "${part#*-}"; else echo "$part"; fi
  done
}

compress() { # sorted cpu ids on stdin -> "0-3,8"
  awk 'function flush() { out = out (out == "" ? "" : ",") (s == p ? s : s "-" p) }
       NR == 1 { s = p = $1; next }
       $1 == p + 1 { p = $1; next }
       { flush(); s = p = $1 }
       END { if (NR) { flush(); print out } }'
}

online_cpus() { expand "$(cat "$CPU_DIR/online")"; }

detect_topology() {
  local p_cpus=() e_cpus=() lpe_cpus=() c
  if [[ -r $SYSFS/devices/cpu_core/cpus && -r $SYSFS/devices/cpu_atom/cpus ]]; then
    mapfile -t p_cpus < <(expand "$(cat "$SYSFS/devices/cpu_core/cpus")")
    for c in $(expand "$(cat "$SYSFS/devices/cpu_atom/cpus")"); do
      if [[ -d $CPU_DIR/cpu$c/cache/index3 ]]; then e_cpus+=("$c"); else lpe_cpus+=("$c"); fi
    done
    # A hybrid part without a separate low-power island: nothing to exclude.
    if ((${#e_cpus[@]} == 0)); then e_cpus=("${lpe_cpus[@]}"); lpe_cpus=(); fi
  else
    echo "note: not a hybrid CPU; main and aux share all CPUs" >&2
    mapfile -t p_cpus < <(online_cpus)
    e_cpus=("${p_cpus[@]}")
  fi

  # Physical P-cores = distinct sibling groups among the P-core threads.
  local phys
  phys=$(for c in "${p_cpus[@]}"; do
    cat "$CPU_DIR/cpu$c/topology/thread_siblings_list" 2>/dev/null || echo "$c"
  done | sort -u | wc -l)

  echo "MAIN_CPUSET=$(printf '%s\n' "${p_cpus[@]}" | sort -n | compress)"
  echo "MAIN_THREADS=$phys"
  echo "MAIN_THREADS_BATCH=${#p_cpus[@]}"
  echo "AUX_CPUSET=$(printf '%s\n' "${e_cpus[@]}" | sort -n | compress)"
  if ((${#lpe_cpus[@]})); then
    echo "# LP E-cores left for the OS: $(printf '%s\n' "${lpe_cpus[@]}" | sort -n | compress)" >&2
  fi
}

detect_devices() {
  local node vendor gid=""
  for node in "$SYSFS"/class/drm/renderD*; do
    [[ -e $node ]] || continue
    vendor=$(cat "$node/device/vendor" 2>/dev/null || true)
    if [[ $vendor == 0x8086 ]]; then
      echo "INTEL_RENDER_NODE=$DEV/dri/$(basename "$node")"
      [[ -e $DEV/dri/$(basename "$node") ]] && gid=$(stat -c %g "$DEV/dri/$(basename "$node")")
      break
    fi
  done
  [[ -z $gid ]] && gid=$(getent group render | cut -d: -f3 || true)
  if [[ -n $gid ]]; then
    echo "RENDER_GID=$gid"
  else
    echo "warn: could not determine the render group id" >&2
  fi
  if [[ -e $DEV/accel/accel0 && -n $gid && $(stat -c %g "$DEV/accel/accel0") != "$gid" ]]; then
    echo "warn: $DEV/accel/accel0 is not owned by gid $gid; add a udev rule (see docs)" >&2
  fi
}

main() {
  local out
  out=$(detect_topology; detect_devices)
  if [[ ${1:-} == --write ]]; then
    local env_file=${2:?usage: $0 --write <env-file>} line key
    [[ -f $env_file ]] || { echo "$env_file not found (cp .env.example .env first)" >&2; exit 1; }
    while IFS= read -r line; do
      key=${line%%=*}
      if grep -q "^$key=" "$env_file"; then
        sed -i "s|^$key=.*|$line|" "$env_file"
      else
        echo "$line" >>"$env_file"
      fi
    done <<<"$out"
    if grep -q '^WEBUI_SECRET_KEY=$' "$env_file"; then
      sed -i "s|^WEBUI_SECRET_KEY=$|WEBUI_SECRET_KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')|" "$env_file"
    fi
    echo "updated $env_file:" >&2
  fi
  echo "$out"
}

main "$@"
