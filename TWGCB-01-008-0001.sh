#!/bin/bash
# TWGCB-01-008-0001: Disable cramfs filesystem (RHEL 8.5)
# Baseline actions: add "install cramfs /bin/true" and "blacklist cramfs" to /etc/modprobe.d/cramfs.conf,
# unload the cramfs module if loaded, then recommend reboot. (Source: TWGCB-01-008-0001 doc)
set -uo pipefail

TITLE="TWGCB-01-008-0001: Disable cramfs filesystem"
CONF="/etc/modprobe.d/cramfs.conf"
REQUIRED_LINES=(
  "install cramfs /bin/true"
  "blacklist cramfs"
)

# Colors: bright green/red per user's preference
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
CYAN="\e[96m"
BOLD="\e[1m"
RESET="\e[0m"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root.${RESET}"
    exit 1
  fi
}

has_line() {
  # args: <file> <exact line>
  local file="$1" needle="$2"
  [[ -f "$file" ]] && grep -Fxq -- "$needle" "$file"
}

print_matches_with_prefix() {
  # args: <file> <pattern> (fixed string)
  local file="$1" pattern="$2"
  if [[ -f "$file" ]]; then
    # Use grep -n to include line numbers, then prefix each with "Line: "
    # Use fixed-string match for exact content display
    grep -nF -- "$pattern" "$file" | sed 's/^/Line: /'
  fi
}

is_module_loaded() {
  lsmod | awk '{print $1}' | grep -Fxq "cramfs"
}

any_cramfs_mounts() {
  findmnt -nt cramfs >/dev/null 2>&1
}

show_current_state() {
  echo -e "${BOLD}$TITLE${RESET}"
  echo
  echo "Checking files:"
  echo "  - $CONF"
  echo
  echo "Check results:"

  local found_any=0
  if [[ -f "$CONF" ]]; then
    for ln in "${REQUIRED_LINES[@]}"; do
      local out
      out="$(print_matches_with_prefix "$CONF" "$ln")"
      if [[ -n "$out" ]]; then
        echo -e "$CONF:"
        echo -e "$out"
        found_any=1
      fi
    done
    if [[ $found_any -eq 0 ]]; then
      echo -e "$CONF:"
      echo "(No matching line found)"
    fi
  else
    echo -e "$CONF:"
    echo "(File not found)"
  fi

  # Module & mount state
  echo
  echo "Kernel/module state:"
  if is_module_loaded; then
    echo -e "cramfs module: ${RED}loaded${RESET}"
  else
    echo -e "cramfs module: ${GREEN}not loaded${RESET}"
  fi

  if any_cramfs_mounts; then
    echo -e "cramfs mounts: ${RED}present${RESET}"
    findmnt -nt cramfs | nl -ba | sed 's/^/Line: /'
  else
    echo -e "cramfs mounts: ${GREEN}none${RESET}"
  fi
}

is_compliant() {
  # conditions: file exists and both lines present; module not loaded; no cramfs mounts
  [[ -f "$CONF" ]] || return 1
  for ln in "${REQUIRED_LINES[@]}"; do
    has_line "$CONF" "$ln" || return 1
  done
  is_module_loaded && return 1
  any_cramfs_mounts && return 1
  return 0
}

apply_fix() {
  echo
  echo -e "${CYAN}Applying fix...${RESET}"

  # Ensure directory exists
  install -d -m 0755 /etc/modprobe.d

  # Backup if file exists and different
  if [[ -f "$CONF" ]]; then
    local tmpfile; tmpfile="$(mktemp)"
    cp -a -- "$CONF" "$tmpfile"
    # Ensure lines exist (append if missing)
    for ln in "${REQUIRED_LINES[@]}"; do
      if ! grep -Fxq -- "$ln" "$tmpfile"; then
        printf "%s\n" "$ln" >> "$tmpfile"
      fi
    done
    if ! cmp -s "$CONF" "$tmpfile"; then
      cp -a -- "$CONF" "${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
      install -m 0644 "$tmpfile" "$CONF"
    fi
    rm -f "$tmpfile"
  else
    {
      echo "# Managed by $TITLE"
      for ln in "${REQUIRED_LINES[@]}"; do
        printf "%s\n" "$ln"
      done
    } > "$CONF"
    chmod 0644 "$CONF"
  fi

  # Unload cramfs module if currently loaded
  if is_module_loaded; then
    if ! rmmod cramfs 2>/dev/null; then
      echo -e "${RED}Failed to unload cramfs module. Make sure no cramfs mounts exist, then try again.${RESET}"
      return 1
    fi
  fi

  # Optional: rebuild initramfs if dracut exists (harmless if not needed)
  if command -v dracut >/dev/null 2>&1; then
    # Rebuild for the current kernel
    local kver
    kver="$(uname -r)"
    if ! dracut -f "/boot/initramfs-${kver}.img" "${kver}" >/dev/null 2>&1; then
      echo -e "${YELLOW}Warning: dracut rebuild may have failed or is unnecessary. Continuing.${RESET}"
    fi
  fi

  return 0
}

prompt_apply() {
  echo
  echo -e "${RED}Non-compliant:${RESET} cramfs is enabled and/or not fully blacklisted."
  echo -en "Apply fix now (create/update ${CONF}, unload module)? [Y]es / [N]o / [C]ancel: "
  local ans
  while true; do
    IFS= read -rsn1 ans
    echo
    case "$ans" in
      [Yy]) apply_fix && return 0 || return 1 ;;
      [Nn]) echo "Skipped applying."; return 2 ;;
      [Cc]) echo "Canceled."; return 3 ;;
      *) echo -n "Please press Y/N/C: " ;;
    esac
  done
}

main() {
  require_root
  echo -e "${BOLD}$TITLE${RESET}"
  echo
  echo "Checking current configuration..."
  show_current_state
  echo

  if is_compliant; then
    echo -e "${GREEN}Compliant:${RESET} cramfs is disabled and blacklisted."
    exit 0
  fi

  prompt_apply
  rc=$?
  if [[ $rc -ne 0 ]]; then
    # 2=skipped, 3=canceled, 1=apply failed handled below
    [[ $rc -eq 2 ]] && exit 2
    [[ $rc -eq 3 ]] && exit 3
  fi

  echo
  echo "Re-checking..."
  show_current_state
  echo

  if is_compliant; then
    echo -e "${GREEN}Successfully applied.${RESET} A reboot is recommended to ensure the setting persists."
    exit 0
  else
    echo -e "${RED}Failed to apply.${RESET}"
    exit 1
  fi
}

main "$@"

