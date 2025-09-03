#!/bin/bash
# TWGCB-01-008-0004 v3 (interactive-only): Configure /tmp as tmpfs with secure options (RHEL 8.5)
# Target: /tmp on tmpfs with noexec,nodev,nosuid,mode=1777 (relatime/strictatime acceptable)
# Methods: fstab or systemd tmp.mount
# Notes:
#   - No CLI flags; purely interactive with single-key prompts read from /dev/tty.
#   - Shows findings with "Line: <num>:" prefixes.
set -uo pipefail

TITLE="TWGCB-01-008-0004: Configure /tmp as tmpfs"
FSTAB="/etc/fstab"
SYSTEMD_UNIT_DIR="/etc/systemd/system"
UNIT_PATH="${SYSTEMD_UNIT_DIR}/tmp.mount"
REQUIRED_FSTYPE="tmpfs"
REQUIRED_OPTS_COMMON="noexec,nodev,nosuid"
REQUIRED_MODE="mode=1777"

# Colors
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; BOLD="\e[1m"; RESET="\e[0m"

require_root() { [[ $EUID -ne 0 ]] && { echo -e "${RED}Must run as root.${RESET}"; exit 1; }; }

# Read one key from /dev/tty (fallback to stdin if TTY); loop until a valid key is provided
read_key_choice() {
  local prompt="$1" valid="$2" key=""
  while true; do
    if [[ -t 0 ]]; then
      echo -n "$prompt"
      IFS= read -rsn1 key || key=""
      echo
    else
      echo -n "$prompt" > /dev/tty 2>/dev/null || true
      IFS= read -rsn1 key < /dev/tty 2>/dev/null || key=""
      echo > /dev/tty 2>/dev/null || true
    fi
    [[ "$key" =~ $valid ]] && { printf "%s" "$key"; return 0; }
    echo "Please press one of: ${valid}" 1>&2
  done
}

# Runtime mount info
current_tmp_mount() { awk '$2=="/tmp"{print NR ":" $0}' /proc/self/mounts; }
current_tmp_fstype() { awk '$2=="/tmp"{print $3; exit}' /proc/self/mounts; }
current_tmp_opts() { awk '$2=="/tmp"{print $4; exit}' /proc/self/mounts; }

has_required_opts_runtime() {
  local opts="$1"
  for k in noexec nodev nosuid; do
    grep -qE "(^|,)$k(,|$)" <<<"$opts" || return 1
  done
  if grep -qE "(^|,)${REQUIRED_MODE}(,|$)" <<<"$opts"; then
    return 0
  else
    local perm; perm="$(stat -c %a /tmp 2>/dev/null || echo "")"
    [[ "$perm" == "1777" ]] || return 1
  fi
  return 0
}

# fstab helpers
fstab_line_for_tmp() { [[ -f "$FSTAB" ]] && awk '($0!~/^\s*#/ && NF>=2 && $2=="/tmp"){print NR ":" $0}' "$FSTAB"; }
fstab_has_compliant_tmp_line() {
  [[ -f "$FSTAB" ]] || return 1
  awk -v needfs="$REQUIRED_FSTYPE" -v needm="$REQUIRED_MODE" '
    function hasopt(o,pat){return o ~ "(^|,)" pat "(,|$)"}
    ($0!~/^\s*#/ && NF>=4 && $2=="/tmp") {
      fs=$3; opts=$4;
      if (fs==needfs && hasopt(opts,"noexec") && hasopt(opts,"nodev") && hasopt(opts,"nosuid") && hasopt(opts,"mode=1777")) exit 0
    }
    END{exit 1}' "$FSTAB"
}

# systemd unit helpers
unit_options_line() { [[ -f "$UNIT_PATH" ]] && awk '/^\[Mount\]/{inm=1; next} /^\[/{inm=0} inm && /^Options=/{print NR ":" $0}' "$UNIT_PATH"; }
unit_is_compliant() {
  [[ -f "$UNIT_PATH" ]] || return 1
  awk '
    /^\[Mount\]/{inm=1; next} /^\[/{inm=0}
    inm && /^Type=/{type=$0}
    inm && /^What=/{what=$0}
    inm && /^Where=/{where=$0}
    inm && /^Options=/{opts=$0}
    END{
      if (where ~ /Where=\/tmp/ && type ~ /Type=tmpfs/ && what ~ /What=tmpfs/ && opts ~ /noexec/ && opts ~ /nodev/ && opts ~ /nosuid/ && opts ~ /mode=1777/) exit 0; else exit 1
    }' "$UNIT_PATH"
}

show_state() {
  echo -e "${BOLD}$TITLE${RESET}"
  echo
  echo "Runtime mount (/proc/self/mounts):"
  local cur; cur="$(current_tmp_mount)"
  if [[ -n "$cur" ]]; then
    echo "$cur" | sed 's/^/Line: /'
  else
    echo "Line: 1:(/tmp not found in /proc/self/mounts)"
  fi
  local fstype opts
  fstype="$(current_tmp_fstype || true)"
  opts="$(current_tmp_opts || true)"
  echo
  echo "Runtime evaluation:"
  if [[ -n "$fstype" ]]; then
    echo "  fstype: $fstype"
    echo "  opts  : $opts"
  else
    echo "  fstype: (none)"
  fi

  echo
  echo "Configuration files:"
  echo "  - $FSTAB"
  fstab_line_for_tmp | sed 's/^/Line: /'
  echo "  - $UNIT_PATH"
  unit_options_line | sed 's/^/Line: /'
}

is_compliant() {
  local fstype opts
  fstype="$(current_tmp_fstype || true)"
  opts="$(current_tmp_opts || true)"
  [[ "$fstype" == "$REQUIRED_FSTYPE" ]] || return 1
  has_required_opts_runtime "$opts" || return 1
  if fstab_has_compliant_tmp_line || unit_is_compliant; then return 0; fi
  return 1
}

backup_file() { local p="$1"; [[ -f "$p" ]] && cp -a -- "$p" "${p}.bak.$(date +%Y%m%d-%H%M%S)"; }

ensure_tmp_dir() { install -d -m 1777 /tmp; chown root:root /tmp; }

apply_via_fstab() {
  echo -e "${CYAN}Applying via /etc/fstab...${RESET}"
  ensure_tmp_dir
  install -d -m 0755 /etc
  touch "$FSTAB"
  backup_file "$FSTAB"

  local opts_add="rw,relatime,${REQUIRED_OPTS_COMMON},${REQUIRED_MODE}"
  local line="tmpfs /tmp tmpfs ${opts_add} 0 0"

  awk '{
    if ($0 ~ /^\s*#/){print; next}
    n=split($0,a,/[\t ]+/)
    if (n>=2 && a[2]=="/tmp") { print "#" $0 }
    else { print }
  }' "$FSTAB" > "${FSTAB}.tmp.$$" && install -m 0644 "${FSTAB}.tmp.$$" "$FSTAB"
  rm -f "${FSTAB}.tmp.$$"

  echo "$line" >> "$FSTAB"
  echo "Added fstab entry:"
  echo "Line: 1:$line"

  local fstype; fstype="$(current_tmp_fstype || true)"
  if [[ "$fstype" == "tmpfs" ]]; then
    mount -o "remount,${opts_add}" /tmp 2>/dev/null || true
  else
    echo -e "${YELLOW}Note:${RESET} Mounting tmpfs on /tmp will hide existing contents until unmounted."
    mount -t tmpfs -o "${opts_add}" tmpfs /tmp 2>/dev/null || {
      echo -e "${RED}Failed to mount tmpfs on /tmp at runtime.${RESET}"
      return 1
    }
  fi
  return 0
}

apply_via_systemd() {
  echo -e "${CYAN}Applying via systemd tmp.mount...${RESET}"
  ensure_tmp_dir
  install -d -m 0755 "$SYSTEMD_UNIT_DIR"
  backup_file "$UNIT_PATH"
cat >"$UNIT_PATH" <<'EOF'
[Unit]
Description=Temporary Directory (/tmp) as tmpfs
Documentation=man:hier(7) man:tmpfs(5)
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target umount.target

[Mount]
What=tmpfs
Where=/tmp
Type=tmpfs
Options=mode=1777,strictatime,noexec,nodev,nosuid

[Install]
WantedBy=local-fs.target
EOF
  chmod 0644 "$UNIT_PATH"
  systemctl daemon-reload
  systemctl unmask tmp.mount >/dev/null 2>&1 || true
  systemctl enable --now tmp.mount || {
    echo -e "${YELLOW}Note:${RESET} systemd failed to start tmp.mount. Trying manual mount..."
    mount -t tmpfs -o "mode=1777,strictatime,${REQUIRED_OPTS_COMMON}" tmpfs /tmp || return 1
  }
  return 0
}

prompt_apply() {
  echo
  echo -e "${RED}Non-compliant:${RESET} /tmp is not tmpfs with required options and/or persistent config missing."
  local method key
  key="$(read_key_choice "Choose method: [F]stab / [S]ystemd tmp.mount / [C]ancel: " "^[FfSsCc]$")"
  case "$key" in
    [Ff]) method="fstab" ;;
    [Ss]) method="systemd" ;;
    [Cc]) echo "Canceled by user."; return 3 ;;
  esac
  local confirm
  confirm="$(read_key_choice "Proceed applying via ${method}? [Y]es / [N]o: " "^[YyNn]$")"
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted by user."; return 3; }

  if [[ "$method" == "fstab" ]]; then
    apply_via_fstab
  else
    apply_via_systemd
  fi
}

main() {
  require_root
  echo -e "${BOLD}$TITLE${RESET}"
  echo; echo "Checking current configuration..."; show_state; echo

  if is_compliant; then
    echo -e "${GREEN}Compliant:${RESET} /tmp is tmpfs with required options and persistent config present."
    exit 0
  fi

  prompt_apply || { rc=$?; [[ $rc -eq 3 ]] && exit 3 || exit 1; }

  echo; echo "Re-checking..."; show_state; echo
  if is_compliant; then
    echo -e "${GREEN}Successfully applied.${RESET} Reboot is recommended."
    exit 0
  else
    echo -e "${RED}Failed to apply.${RESET}"
    exit 1
  fi
}

main "$@"
