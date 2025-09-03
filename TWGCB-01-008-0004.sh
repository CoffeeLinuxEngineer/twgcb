#!/bin/bash
# TWGCB-01-008-0004: Configure /tmp as tmpfs with secure options (RHEL 8.5)
# Compliance target:
#   /tmp mounted as tmpfs with: noexec,nodev,nosuid,mode=1777 (atime policy flexible: relatime/strictatime)
# Methods supported:
#   - fstab method (add tmpfs line for /tmp, mount or remount)
#   - systemd tmp.mount method (create/enable unit with correct options)
# Output style:
#   - Shows matches with "Line: <num>:" prefixes
#   - Y/N/C prompts using single keypress
# Notes:
#   - Mounting tmpfs on /tmp will hide any existing contents until unmounted.
#   - This script backs up files it edits.
set -uo pipefail

TITLE="TWGCB-01-008-0004: Configure /tmp as tmpfs"
FSTAB="/etc/fstab"
SYSTEMD_UNIT_DIR="/etc/systemd/system"
SYSTEMD_WANTS_DIR="/etc/systemd/system/local-fs.target.wants"
UNIT_PATH="${SYSTEMD_UNIT_DIR}/tmp.mount"     # we'll manage this unit path
REQUIRED_FSTYPE="tmpfs"
REQUIRED_OPTS_COMMON="noexec,nodev,nosuid"
REQUIRED_MODE="mode=1777"

# Colors
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; BOLD="\e[1m"; RESET="\e[0m"

require_root() { [[ $EUID -ne 0 ]] && { echo -e "${RED}Must run as root.${RESET}"; exit 1; }; }

# Detect current mount of /tmp from /proc/self/mounts
current_tmp_mount() {
  awk '$2=="/tmp"{print NR ":" $0}' /proc/self/mounts
}
current_tmp_fstype() {
  awk '$2=="/tmp"{print $3; exit}' /proc/self/mounts
}
current_tmp_opts() {
  awk '$2=="/tmp"{print $4; exit}' /proc/self/mounts
}

has_required_opts_runtime() {
  local opts="$1"
  # require noexec,nodev,nosuid all present
  for k in noexec nodev nosuid; do
    grep -qE "(^|,)$k(,|$)" <<<"$opts" || return 1
  done
  # mode=1777 is preferred; accept either mount option or live dir perms 1777
  if grep -qE "(^|,)mode=1777(,|$)" <<<"$opts"; then
    return 0
  else
    # fallback to directory perms check
    local perm; perm="$(stat -c %a /tmp 2>/dev/null || echo "")"
    [[ "$perm" == "1777" ]] || return 1
  fi
  return 0
}

# fstab helpers
fstab_line_for_tmp() {
  awk '($0!~/^\s*#/ && NF>=2 && $2=="/tmp"){print NR ":" $0}' "$FSTAB" 2>/dev/null
}
fstab_has_compliant_tmp_line() {
  awk -v needfs="$REQUIRED_FSTYPE" -v need1="noexec" -v need2="nodev" -v need3="nosuid" -v needm="mode=1777" '
    ($0!~/^\s*#/ && NF>=4 && $2=="/tmp") {
      fs=$3; opts=$4;
      if (fs==needfs && opts ~ /(^|,)noexec(,|$)/ && opts ~ /(^|,)nodev(,|$)/ && opts ~ /(^|,)nosuid(,|$)/ && opts ~ /(^|,)mode=1777(,|$)/) { exit 0 }
    }
    END{ exit 1 }' "$FSTAB" 2>/dev/null
}

# systemd unit helpers
unit_options_line() {
  # returns Options=... line from tmp.mount if present
  awk '/^\[Mount\]/{inm=1; next} /^\[/{inm=0} inm && /^Options=/{print NR ":" $0}' "$UNIT_PATH" 2>/dev/null
}
unit_is_compliant() {
  [[ -f "$UNIT_PATH" ]] || return 1
  awk -v need1="noexec" -v need2="nodev" -v need3="nosuid" -v needm="mode=1777" '
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
  # Also require that either fstab or unit config encodes the target options (persist across reboot)
  if fstab_has_compliant_tmp_line || unit_is_compliant; then
    return 0
  fi
  return 1
}

prompt_choice_method() {
  # Decide how to apply: F) fstab, S) systemd tmp.mount, C) cancel
  echo
  echo -n "Choose method to enforce /tmp=tmpfs (secure): [F]stab / [S]ystemd tmp.mount / [C]ancel: "
  local ans
  while true; do
    IFS= read -rsn1 ans; echo
    case "$ans" in
      [Ff]) echo "fstab"; return 0 ;;
      [Ss]) echo "systemd"; return 0 ;;
      [Cc]) echo "cancel"; return 0 ;;
      *) echo -n "Press F/S/C: " ;;
    esac
  done
}

backup_file() {
  local p="$1"
  [[ -f "$p" ]] || return 0
  cp -a -- "$p" "${p}.bak.$(date +%Y%m%d-%H%M%S)"
}

apply_via_fstab() {
  echo -e "${CYAN}Applying via /etc/fstab...${RESET}"
  install -d -m 0755 /etc
  touch "$FSTAB"
  backup_file "$FSTAB"

  # Build compliant line
  local opts_add="rw,relatime,${REQUIRED_OPTS_COMMON},${REQUIRED_MODE}"
  local line="tmpfs /tmp tmpfs ${opts_add} 0 0"

  # Remove existing active /tmp lines (uncommented) by commenting them
  awk '{
    if ($0 ~ /^\s*#/){print; next}
    n=split($0,a,/[\t ]+/)
    if (n>=2 && a[2]=="/tmp") { print "#" $0 }
    else { print }
  }' "$FSTAB" > "${FSTAB}.tmp.$$" && install -m 0644 "${FSTAB}.tmp.$$" "$FSTAB"
  rm -f "${FSTAB}.tmp.$$"

  # Append our compliant line
  echo "$line" >> "$FSTAB"
  echo "Added fstab entry:"
  echo "Line: 1:$line"

  # Apply runtime:
  local fstype; fstype="$(current_tmp_fstype || true)"
  if [[ "$fstype" == "tmpfs" ]]; then
    mount -o "remount,${opts_add}" /tmp 2>/dev/null || true
  else
    # warn about hiding contents
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
  local method; method="$(prompt_choice_method)"
  case "$method" in
    fstab) apply_via_fstab && return 0 || return 1 ;;
    systemd) apply_via_systemd && return 0 || return 1 ;;
    cancel) echo "Canceled by user."; return 3 ;;
  esac
}

main() {
  require_root
  echo -e "${BOLD}$TITLE${RESET}"
  echo; echo "Checking current configuration..."; show_state; echo

  if is_compliant; then
    echo -e "${GREEN}Compliant:${RESET} /tmp is tmpfs with required options and persistent config present."
    exit 0
  fi

  prompt_apply
  rc=$?
  [[ $rc -eq 3 ]] && exit 3
  [[ $rc -ne 0 ]] && { echo -e "${RED}Failed to apply.${RESET}"; exit 1; }

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
