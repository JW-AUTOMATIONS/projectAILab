# shellcheck shell=bash
# DATA_ROOT for model weights, caches and docker images. Optionally on a
# dedicated NVMe (MODELS_DISK), which is partitioned and formatted once.

DATA_LABEL=ailab-data

storage_prepare_disk() {
  local disk part root_src root_disk
  disk=$(readlink -f "$MODELS_DISK")
  [[ -b $disk ]] || die "MODELS_DISK=$MODELS_DISK is not a block device"
  [[ $(lsblk -dno TYPE "$disk") == disk ]] || die "$disk is not a whole disk"

  # Already ours? Then only make sure it is mounted.
  part=$(blkid -L "$DATA_LABEL" 2>/dev/null || true)
  if [[ -n $part && $(lsblk -no PKNAME "$part" | head -1) == "$(basename "$disk")" ]]; then
    ok "$disk already carries the $DATA_LABEL filesystem ($part)"
    return 0
  fi

  # Never touch the disk the OS runs from (walk up through LVM/LUKS/md), anything
  # mounted, or a disk that is part of an LVM/RAID set.
  root_src=$(findmnt -no SOURCE /)
  while read -r root_disk; do
    [[ $(basename "$disk") != "$root_disk" ]] || die "$disk holds the root filesystem - refusing to wipe it"
  done < <(lsblk -nrso NAME,TYPE "$root_src" | awk '$2 == "disk" {print $1}')
  if lsblk -nro MOUNTPOINTS "$disk" | grep -q .; then
    die "$disk (or something on it) is mounted: $(lsblk -nro MOUNTPOINTS "$disk" | xargs)"
  fi
  if lsblk -nro FSTYPE "$disk" | grep -qE 'LVM2_member|linux_raid_member|crypto_LUKS|zfs_member'; then
    die "$disk contains LVM/RAID/LUKS/ZFS members - clear it by hand if you really mean to reuse it"
  fi
  if grep -q "^$disk" /proc/swaps; then die "$disk is used as swap"; fi

  warn "About to ERASE $disk: $(lsblk -dno SIZE,MODEL,SERIAL "$disk" | xargs)"
  lsblk -o NAME,SIZE,FSTYPE,LABEL "$disk" >&2
  if [[ $DRY_RUN != 1 ]]; then
    if [[ ${WIPE_MODELS_DISK:-0} != 1 ]]; then
      [[ -r /dev/tty ]] || die "non-interactive: set WIPE_MODELS_DISK=1 to allow erasing $disk"
      local answer
      read -r -p "Type the device name ($(basename "$disk")) to erase it: " answer </dev/tty
      [[ $answer == "$(basename "$disk")" ]] || die "not confirmed, nothing changed"
    fi
  fi

  run wipefs -a "$disk"
  run sgdisk --zap-all "$disk"
  run sgdisk -n 1:0:0 -t 1:8300 -c "1:$DATA_LABEL" "$disk"
  run partprobe "$disk"
  run udevadm settle
  part=$(lsblk -nrpo NAME "$disk" | sed -n 2p)
  [[ $DRY_RUN == 1 ]] && part="${disk}p1"
  # -m 0: no reserved blocks on a data-only disk.
  run mkfs.ext4 -F -L "$DATA_LABEL" -m 0 "$part"
  ok "formatted $part as ext4 ($DATA_LABEL)"
}

# Ubuntu Server's guided LVM install gives / only ~100 GB. Grow it (online,
# non-destructive) when the models will live on the root filesystem.
storage_grow_root_lv() {
  [[ ${EXTEND_ROOT_LV:-1} == 1 ]] || return 0
  local src vg free_g
  src=$(findmnt -no SOURCE /)
  [[ $(lsblk -no TYPE "$src" 2>/dev/null) == lvm ]] || return 0
  vg=$(lvs --noheadings -o vg_name "$src" 2>/dev/null | xargs || true)
  free_g=$(vgs --noheadings --units g --nosuffix -o vg_free "$vg" 2>/dev/null | xargs | cut -d. -f1 || true)
  if [[ -n $free_g ]] && ((free_g >= 10)); then
    log "growing $src by ${free_g} GB (free space in volume group $vg)"
    run lvextend -r -l +100%FREE "$src"
  fi
}

stage_storage() {
  if [[ -n $MODELS_DISK ]]; then
    storage_prepare_disk
    run mkdir -p "$DATA_ROOT"
    if ! grep -q "LABEL=$DATA_LABEL" /etc/fstab; then
      # nofail: the machine still boots (without models) if the disk goes missing.
      if [[ $DRY_RUN == 1 ]]; then
        echo "  + append to /etc/fstab: LABEL=$DATA_LABEL $DATA_ROOT ext4 defaults,noatime,nofail,x-systemd.device-timeout=15s 0 2"
      else
        printf 'LABEL=%s %s ext4 defaults,noatime,nofail,x-systemd.device-timeout=15s 0 2\n' "$DATA_LABEL" "$DATA_ROOT" >>/etc/fstab
      fi
      run systemctl daemon-reload
    fi
    if ! mountpoint -q "$DATA_ROOT"; then run mount "$DATA_ROOT"; fi
    [[ $DRY_RUN == 1 ]] || mountpoint -q "$DATA_ROOT" || die "$DATA_ROOT did not mount"
  else
    log "MODELS_DISK not set: $DATA_ROOT stays on the root filesystem"
    storage_grow_root_lv
  fi

  run mkdir -p "$DATA_ROOT/models/llama.cpp" "$DATA_ROOT/models/huggingface" "$DATA_ROOT/models/openvino"
  if [[ -n $AILAB_USER ]]; then run chown -R "$AILAB_USER:" "$DATA_ROOT/models"; fi
  if [[ -d $DATA_ROOT ]]; then ok "data root: $DATA_ROOT ($(df -h --output=avail "$DATA_ROOT" | tail -1 | xargs) free)"; fi
}
