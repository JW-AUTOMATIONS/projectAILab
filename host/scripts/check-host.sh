#!/usr/bin/env bash
# Preflight for the AI Lab stack. Read-only; prints PASS/WARN/FAIL per check.
#   host/scripts/check-host.sh
# pass/warn/fail always succeed, so `cond && pass || warn` is safe here.
# shellcheck disable=SC2015
set -uo pipefail

fails=0
pass() { printf '  \e[32mPASS\e[0m %s\n' "$*"; }
warn() { printf '  \e[33mWARN\e[0m %s\n' "$*"; }
fail() { printf '  \e[31mFAIL\e[0m %s\n' "$*"; fails=$((fails + 1)); }
section() { printf '\n%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
ver_ge() { [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1) == "$2" ]]; }

section "Kernel / CPU / memory"
kver=$(uname -r | cut -d- -f1)
if ver_ge "$kver" 6.8; then pass "kernel $kver"; else fail "kernel $kver < 6.8 (NPU + Meteor Lake iGPU support)"; fi
grep -q avx_vnni /proc/cpuinfo && pass "AVX-VNNI present" || warn "AVX-VNNI not reported"
grep -q avx512f /proc/cpuinfo && warn "AVX-512 reported (unexpected on 185H)"
mem_gb=$(awk '/MemTotal/ {printf "%d", $2 / 1048576}' /proc/meminfo)
((mem_gb >= 88)) && pass "RAM ${mem_gb} GiB" || warn "RAM ${mem_gb} GiB (stack is sized for 96 GB)"
if have dmidecode && [[ $EUID -eq 0 ]]; then
  speeds=$(dmidecode -t memory | awk -F': ' '/Configured Memory Speed: [0-9]/ {print $2}' | sort -u | paste -sd,)
  [[ -n $speeds ]] && pass "DIMM speed: $speeds (DDR5-5600 dual channel ~= 89.6 GB/s peak)"
fi
swap_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
((swap_kb > 0)) && warn "swap is enabled; a model spilling to swap is far slower than mmap from NVMe" || pass "no swap"

section "NVIDIA RTX 5060 Ti"
if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
  IFS=, read -r name drv mem gen width gen_max width_max < <(nvidia-smi \
    --query-gpu=name,driver_version,memory.total,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max \
    --format=csv,noheader,nounits | head -1 | tr -d ' ')
  pass "$name, ${mem} MiB VRAM"
  if ver_ge "$drv" 570; then pass "driver $drv"; else fail "driver $drv < 570 (Blackwell needs 570+)"; fi
  grep -qi "open kernel module" /proc/driver/nvidia/version 2>/dev/null \
    && pass "open kernel modules (required for Blackwell)" \
    || fail "proprietary kernel module loaded; Blackwell requires nvidia-open"
  msg="PCIe link gen${gen} x${width} (max gen${gen_max} x${width_max}); the card is x8 native"
  if ((width_max < 8)); then warn "$msg - narrow link (OCuLink/Thunderbolt?) slows prompt processing with CPU-offloaded experts"; else pass "$msg"; fi
else
  fail "nvidia-smi missing or not working"
fi
if have docker && docker info 2>/dev/null | grep -qi 'runtimes:.*nvidia'; then
  pass "nvidia container runtime registered with docker"
else
  fail "NVIDIA Container Toolkit not configured (nvidia-ctk runtime configure --runtime=docker)"
fi

section "Intel Arc iGPU"
intel_node=""
for n in /sys/class/drm/renderD*; do
  [[ $(cat "$n/device/vendor" 2>/dev/null) == 0x8086 ]] && intel_node=/dev/dri/$(basename "$n") && break
done
if [[ -n $intel_node ]]; then
  drv=$(basename "$(readlink -f "/sys/class/drm/$(basename "$intel_node")/device/driver")")
  pass "$intel_node (driver: $drv, group: $(stat -c %G "$intel_node"))"
else
  fail "no Intel render node under /dev/dri"
fi

section "Intel AI Boost NPU"
if [[ -e /dev/accel/accel0 ]]; then
  pass "/dev/accel/accel0 (group: $(stat -c %G /dev/accel/accel0))"
  [[ $(stat -c %G /dev/accel/accel0) == render ]] \
    || warn "accel0 not group 'render': echo 'SUBSYSTEM==\"accel\", KERNEL==\"accel*\", GROUP=\"render\", MODE=\"0660\"' > /etc/udev/rules.d/10-intel-vpu.rules"
else
  fail "/dev/accel/accel0 missing (modprobe intel_vpu; check dmesg | grep -i vpu)"
fi
[[ -d /sys/module/intel_vpu ]] && pass "intel_vpu loaded" || warn "intel_vpu module not loaded"
compgen -G '/lib/firmware/intel/vpu/vpu_37xx*' >/dev/null \
  && pass "NPU firmware present" || warn "no NPU 37xx (Meteor Lake) firmware in /lib/firmware/intel/vpu - install intel-fw-npu or a newer linux-firmware"

section "Storage / network"
for d in /sys/block/nvme*n1; do
  [[ -e $d ]] || continue
  printf '  INFO %s %s\n' "$(basename "$d")" "$(cat "$d/device/model" 2>/dev/null | xargs)"
done
if [[ -r /proc/net/bonding/bond0 ]]; then
  mode=$(awk -F': ' '/Bonding Mode/ {print $2}' /proc/net/bonding/bond0)
  up=$(grep -c 'MII Status: up' /proc/net/bonding/bond0)
  pass "bond0: $mode, $((up - 1)) slave(s) up"
  grep -q 'Partner Mac Address: 00:00:00:00:00:00' /proc/net/bonding/bond0 \
    && warn "no LACP partner - is LACP enabled on the switch ports?"
else
  warn "bond0 not configured (optional; see host/netplan)"
fi

printf '\n%s\n' "$([[ $fails -eq 0 ]] && echo 'All required checks passed.' || echo "$fails required check(s) failed.")"
exit $((fails > 0))
