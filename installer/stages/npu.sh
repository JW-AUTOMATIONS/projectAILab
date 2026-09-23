# shellcheck shell=bash
# Intel AI Boost NPU (Meteor Lake NPU 3720).
#
# The kernel driver (intel_vpu) ships with Ubuntu. This stage installs Intel's
# user-mode driver, compiler and newer firmware from intel/linux-npu-driver,
# gives /dev/accel/accel0 to the render group, and reloads the driver so the new
# firmware is used. The same release tag is pinned for the npu-worker image.

stage_npu() {
  if ! has_intel_npu && [[ ${FORCE_NPU:-0} != 1 ]]; then
    warn "no Intel NPU detected, skipping (FORCE_NPU=1 to install anyway)"
    return 0
  fi

  apt_install libtbb12
  # Level Zero loader (from the Intel PPA when enabled, else the Ubuntu archive).
  pkg_installed libze1 || pkg_installed level-zero || apt_install libze1

  local json tag version reload_npu=0 debs=()
  json=$(gh_release_json intel/linux-npu-driver "$NPU_DRIVER_TAG") \
    || die "cannot query intel/linux-npu-driver release '$NPU_DRIVER_TAG' (GitHub API rate limit? set GITHUB_TOKEN)"
  tag=$(jq -r .tag_name <<<"$json")
  version=${tag#v}
  log "NPU driver release: $tag"

  if [[ $(pkg_version intel-level-zero-npu) == "$version"* && $(pkg_version intel-driver-compiler-npu) == "$version"* ]]; then
    ok "NPU user-space driver $tag already installed"
  else
    local tmp url
    tmp=$(mktemp -d)
    # Assets have been published both as loose .debs and as a tarball of .debs.
    local urls
    urls=$(jq -r '.assets[].browser_download_url' <<<"$json" \
      | grep -E 'ubuntu[._-]?24\.?04[^/]*\.(deb|tar\.gz)$' | grep -v dbgsym || true)
    [[ -n $urls ]] || die "no Ubuntu 24.04 assets in $tag; available: $(jq -r '[.assets[].name] | join(", ")' <<<"$json")"
    while read -r url; do
      log "download ${url##*/}"
      run curl -fsSL --retry 3 -o "$tmp/${url##*/}" "$url"
    done <<<"$urls"

    if [[ $DRY_RUN != 1 ]]; then
      local t
      for t in "$tmp"/*.tar.gz; do
        if [[ -e $t ]]; then tar -xzf "$t" -C "$tmp"; fi
      done
      mapfile -t debs < <(find "$tmp" -name '*.deb' ! -name '*dbgsym*' | sort)
      ((${#debs[@]})) || die "release $tag has no Ubuntu 24.04 packages"
      # Older installs used a different package split; drop them so apt can't mix versions.
      local old
      for old in intel-level-zero-npu intel-driver-compiler-npu intel-fw-npu; do
        if pkg_installed "$old" && ! printf '%s\n' "${debs[@]}" | grep -q "/${old}_"; then
          run dpkg --purge --force-remove-reinstreq "$old"
        fi
      done
      apt_install "${debs[@]}"
    fi
    rm -rf "$tmp"
    reload_npu=1
  fi
  state_set npu-driver-tag "$tag"

  write_file /etc/udev/rules.d/10-intel-vpu.rules <<'EOF'
# ailab: let the render group (docker containers via group_add) use the NPU.
SUBSYSTEM=="accel", KERNEL=="accel*", GROUP="render", MODE="0660"
EOF
  if [[ $FILE_CHANGED == 1 ]]; then
    run udevadm control --reload-rules
    run udevadm trigger --subsystem-match=accel
  fi

  # Load the new firmware. Only possible when nothing holds the device open.
  if [[ $reload_npu == 1 ]]; then
    if run modprobe -r intel_vpu && run modprobe intel_vpu; then
      ok "intel_vpu reloaded with the new firmware"
    else
      need_reboot "reload intel_vpu with the new NPU firmware"
    fi
  fi

  if [[ $DRY_RUN != 1 ]]; then
    sleep 1
    if [[ -e /dev/accel/accel0 ]]; then
      ok "/dev/accel/accel0 ($(stat -c '%U:%G %a' /dev/accel/accel0))"
    else
      warn "/dev/accel/accel0 missing - check 'dmesg | grep -i vpu'"
    fi
  fi
  add_user_to_groups render
}
