# shellcheck shell=bash
# Docker Engine (official repo) + Compose plugin + NVIDIA Container Toolkit.

docker_repo() {
  local codename
  codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
  if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc
  fi
  write_file /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable
EOF
}

nvidia_ctk_repo() {
  local key=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  if [[ ! -s $key ]]; then
    if [[ $DRY_RUN == 1 ]]; then
      echo "  + fetch NVIDIA container toolkit key -> $key"
    else
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor --yes -o "$key"
    fi
  fi
  write_file /etc/apt/sources.list.d/nvidia-container-toolkit.list <<EOF
deb [signed-by=$key] https://nvidia.github.io/libnvidia-container/stable/deb/\$(ARCH) /
EOF
}

# Merge our settings into /etc/docker/daemon.json without dropping existing keys.
docker_daemon_config() {
  local current='{}' desired dockerd_root=""
  if [[ -s /etc/docker/daemon.json ]]; then current=$(cat /etc/docker/daemon.json); fi
  if [[ $DOCKER_DATA_ON_DATA_ROOT == 1 ]]; then dockerd_root="$DATA_ROOT/docker"; fi
  desired=$(jq --arg dr "$dockerd_root" '
      . + {"log-driver": "json-file", "log-opts": {"max-size": "20m", "max-file": "3"}}
      | if $dr != "" then . + {"data-root": $dr} else . end' <<<"$current")

  local old_root new_root
  old_root=$(jq -r '."data-root" // "/var/lib/docker"' <<<"$current")
  new_root=$(jq -r '."data-root" // "/var/lib/docker"' <<<"$desired")

  write_file /etc/docker/daemon.json <<<"$(jq . <<<"$desired")"
  DOCKER_RESTART=$FILE_CHANGED

  # Moving data-root after images already exist: copy them across once.
  if [[ $old_root != "$new_root" && -d $old_root ]] && [[ -n $(ls -A "$old_root" 2>/dev/null) ]] \
    && [[ ! -d $new_root || -z $(ls -A "$new_root" 2>/dev/null) ]]; then
    log "moving docker data from $old_root to $new_root"
    run systemctl stop docker.socket docker
    run mkdir -p "$new_root"
    run rsync -aHAX "$old_root/" "$new_root/"
  fi
}

stage_docker() {
  local p
  for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if pkg_installed "$p"; then run apt-get remove -y -q "$p"; fi
  done

  docker_repo
  local want_nvidia=0
  if has_nvidia_gpu || [[ ${FORCE_NVIDIA:-0} == 1 ]]; then
    want_nvidia=1
    nvidia_ctk_repo
  fi
  apt_update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  if [[ $want_nvidia == 1 ]]; then apt_install nvidia-container-toolkit; fi

  DOCKER_RESTART=0
  docker_daemon_config
  if [[ $want_nvidia == 1 ]]; then
    # Adds the "nvidia" runtime to daemon.json (idempotent); CDI mode is not needed.
    local before
    before=$(cat /etc/docker/daemon.json 2>/dev/null || true)
    run nvidia-ctk runtime configure --runtime=docker
    if [[ $before != "$(cat /etc/docker/daemon.json 2>/dev/null || true)" ]]; then DOCKER_RESTART=1; fi
  fi

  run systemctl enable docker.service containerd.service
  if [[ $DOCKER_RESTART == 1 ]]; then run systemctl restart docker; else run systemctl start docker; fi

  add_user_to_groups docker
  [[ $DRY_RUN == 1 ]] || ok "$(docker --version), $(docker compose version | head -1)"
}
