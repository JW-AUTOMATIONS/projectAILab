# shellcheck shell=bash
# Helpers shared by install.sh and installer/stages/*.sh. Sourced, not executed.

AILAB_STATE_DIR=${AILAB_STATE_DIR:-/var/lib/ailab}
REBOOT_FLAG=$AILAB_STATE_DIR/reboot-required
DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}

export DEBIAN_FRONTEND=noninteractive
# Ubuntu 24.04's needrestart otherwise stops apt with an interactive prompt.
export NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

if [[ -t 1 ]]; then
  c_reset=$'\e[0m' c_bold=$'\e[1m' c_red=$'\e[31m' c_green=$'\e[32m' c_yellow=$'\e[33m' c_blue=$'\e[34m'
else
  c_reset='' c_bold='' c_red='' c_green='' c_yellow='' c_blue=''
fi

log()   { printf '%s[ailab]%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()    { printf '%s[ ok ]%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
die()   { printf '%s[fail]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }
stage() { printf '\n%s==> %s%s\n' "$c_bold" "$*" "$c_reset"; }

# Run a command that changes the system; in dry-run mode only print it.
run() {
  if [[ $DRY_RUN == 1 ]]; then
    printf '  + %s\n' "$*"
    return 0
  fi
  "$@"
}

# write_file PATH [MODE] < content
# Writes only when the content differs. Sets FILE_CHANGED=1 when it wrote.
FILE_CHANGED=0
write_file() {
  local path=$1 mode=${2:-0644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  FILE_CHANGED=0
  if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    return 0
  fi
  # shellcheck disable=SC2034 # read by the stages
  FILE_CHANGED=1
  if [[ $DRY_RUN == 1 ]]; then
    printf '  + write %s (mode %s)\n' "$path" "$mode"
    sed 's/^/  | /' "$tmp"
    rm -f "$tmp"
    return 0
  fi
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  log "wrote $path"
}

confirm() { # confirm "question" -> 0 if yes
  [[ $ASSUME_YES == 1 ]] && return 0
  [[ -r /dev/tty ]] || return 1
  local answer
  read -r -p "$1 [y/N] " answer </dev/tty
  [[ $answer =~ ^[Yy]$ ]]
}

need_reboot() {
  warn "reboot required: $*"
  [[ $DRY_RUN == 1 ]] && return 0
  mkdir -p "$AILAB_STATE_DIR"
  echo "$*" >>"$REBOOT_FLAG"
  cat /proc/sys/kernel/random/boot_id >"$REBOOT_FLAG.boot_id"
}

# A reboot flag written during an earlier boot has been satisfied.
clear_stale_reboot_flag() {
  [[ -f $REBOOT_FLAG ]] || return 0
  if [[ $(cat "$REBOOT_FLAG.boot_id" 2>/dev/null) != "$(cat /proc/sys/kernel/random/boot_id)" ]]; then
    rm -f "$REBOOT_FLAG" "$REBOOT_FLAG.boot_id"
  fi
}

state_set() { # state_set KEY VALUE
  [[ $DRY_RUN == 1 ]] && { printf '  + state %s=%s\n' "$1" "$2"; return 0; }
  mkdir -p "$AILAB_STATE_DIR"
  printf '%s\n' "$2" >"$AILAB_STATE_DIR/$1"
}
state_get() { cat "$AILAB_STATE_DIR/$1" 2>/dev/null || true; }

# --- apt ----------------------------------------------------------------------
apt_update() { run apt-get update -q; }
apt_install() { run apt-get install -y -q --no-install-recommends "$@"; }
apt_install_rec() { run apt-get install -y -q "$@"; }
pkg_available() { [[ -n $(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" {print $2}') ]]; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
pkg_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

# Tools the stages use before/without the base stage.
ensure_prereqs() {
  local missing=() c
  for c in curl jq rsync gpg; do command -v "$c" >/dev/null || missing+=("$c"); done
  ((${#missing[@]})) || return 0
  [[ $DRY_RUN == 1 ]] && { warn "missing tools (installed on a real run): ${missing[*]}"; return 0; }
  log "installing prerequisites: ${missing[*]}"
  apt-get update -q
  apt-get install -y -q --no-install-recommends ca-certificates curl jq rsync gnupg
}

# Install whichever of the given packages exist in the configured repos.
apt_install_available() {
  local p want=()
  for p in "$@"; do
    if pkg_available "$p"; then want+=("$p"); else warn "package $p not available, skipping"; fi
  done
  ((${#want[@]})) && apt_install "${want[@]}"
  return 0
}

# --- GitHub releases ----------------------------------------------------------
gh_api() {
  local args=(-fsSL --retry 3 -H 'Accept: application/vnd.github+json')
  [[ -n ${GITHUB_TOKEN:-} ]] && args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl "${args[@]}" "https://api.github.com/$1"
}

gh_release_json() { # gh_release_json owner/repo tag|latest
  if [[ ${2:-latest} == latest ]]; then gh_api "repos/$1/releases/latest"; else gh_api "repos/$1/releases/tags/$2"; fi
}

# --- misc ---------------------------------------------------------------------
# pci_has VENDOR CLASS_REGEX: any PCI function from VENDOR (0x....) whose class matches.
pci_has() {
  local d
  for d in /sys/bus/pci/devices/*; do
    [[ $(cat "$d/vendor" 2>/dev/null) == "$1" && $(cat "$d/class" 2>/dev/null) =~ $2 ]] && return 0
  done
  return 1
}
has_nvidia_gpu() { pci_has 0x10de '^0x030[02]'; }  # VGA or 3D controller
has_intel_npu() { pci_has 0x8086 '^0x1200'; }      # processing accelerator

target_user_home() { getent passwd "$AILAB_USER" | cut -d: -f6; }

add_user_to_groups() {
  local g
  [[ -n ${AILAB_USER:-} ]] || return 0
  for g in "$@"; do
    getent group "$g" >/dev/null || continue
    if id -nG "$AILAB_USER" | tr ' ' '\n' | grep -qx "$g"; then continue; fi
    run usermod -aG "$g" "$AILAB_USER"
    log "added $AILAB_USER to group $g (takes effect at next login)"
  done
}

# env_set FILE KEY VALUE: replace KEY=... or append it.
env_set() {
  local file=$1 key=$2 value=$3
  if [[ $DRY_RUN == 1 ]]; then printf '  + %s: %s=%s\n' "$file" "$key" "$value"; return 0; fi
  if grep -q "^$key=" "$file"; then
    KEY="$key" VALUE="$value" awk 'BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"] }
      index($0, k "=") == 1 { print k "=" v; next } { print }' "$file" >"$file.tmp"
    cat "$file.tmp" >"$file" && rm -f "$file.tmp"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}
env_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }
