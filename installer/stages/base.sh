# shellcheck shell=bash
# System update, HWE kernel, and the tools the other stages and day-2 ops use.

stage_base() {
  apt_update
  run apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade

  local kflavour=generic
  if [[ $INSTALL_HWE_KERNEL == 1 ]]; then
    kflavour=generic-hwe-24.04
    if ! pkg_installed linux-generic-hwe-24.04; then
      apt_install_rec linux-generic-hwe-24.04 linux-headers-generic-hwe-24.04
      need_reboot "HWE kernel installed"
    else
      apt_install linux-headers-generic-hwe-24.04
    fi
  else
    apt_install linux-headers-generic
  fi
  state_set kernel-flavour "$kflavour"

  apt_install \
    ca-certificates curl gnupg jq git rsync unzip \
    software-properties-common apt-transport-https \
    pciutils usbutils dmidecode lshw hwloc numactl \
    lm-sensors nvme-cli smartmontools gdisk \
    ethtool iproute2 netplan.io \
    htop btop nvtop \
    mokutil ubuntu-drivers-common \
    openssh-server \
    "linux-tools-$kflavour" linux-tools-common

  run systemctl enable --now ssh
  ok "base packages installed"
}
