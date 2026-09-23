# shellcheck shell=bash
# Kernel/CPU/power settings for a dedicated inference box.

stage_tuning() {
  write_file /etc/sysctl.d/90-ailab.conf <<'EOF'
# ailab: keep model weights (page cache / mmap) in RAM rather than swapping,
# and allow the many mappings large GGUF files and containers create.
vm.swappiness = 10
vm.max_map_count = 1048576
# Busy LAN clients: bigger listen backlog for the web UIs.
net.core.somaxconn = 4096
EOF
  if [[ $FILE_CHANGED == 1 ]]; then run sysctl --system >/dev/null; fi

  # CPU energy/performance preference, re-applied on every boot.
  write_file /usr/local/sbin/ailab-tune 0755 <<EOF
#!/bin/sh
# ailab: boot-time tuning (installed by install.sh)
EPP="$CPU_EPP"
for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
  [ -w "\$f" ] && echo "\$EPP" >"\$f" 2>/dev/null
done
# Keep the NVIDIA driver initialised between requests (faster first token).
command -v nvidia-smi >/dev/null && nvidia-smi -pm 1 >/dev/null 2>&1
exit 0
EOF
  write_file /etc/systemd/system/ailab-tune.service <<'EOF'
[Unit]
Description=AI Lab CPU/GPU tuning
After=multi-user.target nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ailab-tune
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable ailab-tune.service

  # Desktop installs: power-profiles-daemon would override the EPP set above.
  if systemctl is-active --quiet power-profiles-daemon 2>/dev/null && command -v powerprofilesctl >/dev/null; then
    run powerprofilesctl set performance || warn "could not set the performance power profile"
  fi
  run systemctl restart ailab-tune.service

  if [[ $DISABLE_SLEEP == 1 ]]; then
    run systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    ok "suspend/hibernate disabled"
  fi
  ok "tuning applied (EPP=$CPU_EPP, swappiness=10)"
}
