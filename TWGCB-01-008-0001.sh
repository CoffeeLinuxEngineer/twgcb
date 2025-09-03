#!/bin/bash
# TWGCB-01-008-0001: Disable cramfs filesystem (RHEL 8.5)
# - Checks if cramfs is loaded, mountable, or mounted
# - Ensures /etc/modprobe.d/cramfs.conf forces disable
# - Interactive apply step (Y/N/C)
# Notes:
#   * No Chinese in code
#   * Colorized status (bright green/red)
#   * Prompts use single keypress (read -rsn1)

set -u

RULE_FILE="/etc/modprobe.d/cramfs.conf"
REQUIRED_LINES=(
  "install cramfs /bin/true"
  "blacklist cramfs"
)

# Colors
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
BLUE="\e[94m"
BOLD="\e[1m"
RESET="\e[0m"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error:${RESET} This script must be run as root."
    exit 1
  fi
}

header() {
  echo -e "${BOLD}TWGCB-01-008-0001: Disable cramfs filesystem${RESET}"
  echo
}

show_checks() {
  echo "Checking current state..."
  echo "Check results:"

  # 1) Is the cramfs module currently loaded?
  if lsmod | awk '{print $1}' | grep -qx "cramfs"; then
    echo -e " - Module loaded: ${RED}yes${RESET}"
  else
    echo -e " - Module loaded: ${GREEN}no${RESET}"
  fi

  # 2) Is cramfs mountable (modprobe -n -v indicates /bin/true when disabled)?
  MODPROBE_OUT="$(modprobe -n -v cramfs 2>&1 || true)"
  if echo "$MODPROBE_OUT" | grep -q "/bin/true"; then
    echo -e " - Module install override (/bin/true): ${GREEN}present${RESET}"
  else
    echo -e " - Module install override (/bin/true): ${RED}missing${RESET}"
  fi
  if [[ -n "$MODPROBE_OUT" ]]; then
    echo "$MODPROBE_OUT" | sed 's/^/Line: /'
  else
    echo "Line: (no modprobe output)"
  fi

  # 3) Is cramfs currently mounted anywhere?
  if findmnt -t cramfs >/dev/null 2>&1; then
    echo -e " - Mounted cramfs: ${RED}yes${RESET}"
    findmnt -t cramfs | tail -n +2 | nl -ba | sed 's/^\s*\([0-9]\+\)\s\+/Line: \1:/'
  else
    echo -e " - Mounted cramfs: ${GREEN}no${RESET}"
  fi

  # 4) Required lines present in /etc/modprobe.d/cramfs.conf?
  if [[ -f "$RULE_FILE" ]]; then
    echo " - $RULE_FILE exists: yes"
    for pat in "${REQUIRED_LINES[@]}"; do
      if grep -n -E "^[[:space:]]*${pat//\//\\/}[[:space:]]*$" "$RULE_FILE" >/dev/null 2>&1; then
        echo -e "   * '${pat}': ${GREEN}present${RESET}"
        grep -n -E "^[[:space:]]*${pat//\//\\/}[[:space:]]*$" "$RULE_FILE" | sed 's/^\([0-9]\+\):/Line: \1:/'
      else
        echo -e "   * '${pat}': ${RED}missing${RESET}"
      fi
    done
  else
    echo " - $RULE_FILE exists: no"
  fi
}

is_compliant() {
  local ok=1

  # Not loaded
  if lsmod | awk '{print $1}' | grep -qx "cramfs"; then
    ok=0
  fi

  # modprobe override present
  if ! modprobe -n -v cramfs 2>&1 | grep -q "/bin/true"; then
    ok=0
  fi

  # Required lines present
  if [[ ! -f "$RULE_FILE" ]]; then
    ok=0
  else
    for pat in "${REQUIRED_LINES[@]}"; do
      if ! grep -q -E "^[[:space:]]*${pat//\//\\/}[[:space:]]*$" "$RULE_FILE"; then
        ok=0
      fi
    done
  fi

  # Not mounted
  if findmnt -t cramfs >/dev/null 2>&1; then
    ok=0
  fi

  return $(( ok == 1 ? 0 : 1 ))
}

apply_fix() {
  echo
  echo -e "${BLUE}Applying remediation...${RESET}"

  # Ensure directory exists
  install -d -m 0755 /etc/modprobe.d

  # Create or update rule file atomically
  {
    echo "install cramfs /bin/true"
    echo "blacklist cramfs"
  } > "${RULE_FILE}.tmp" && chmod 0644 "${RULE_FILE}.tmp" && mv -f "${RULE_FILE}.tmp" "$RULE_FILE"

  # If module is currently loaded, try to remove it
  if lsmod | awk '{print $1}' | grep -qx "cramfs"; then
    if ! rmmod cramfs 2>/dev/null; then
      echo -e "${YELLOW}Warning:${RESET} Unable to remove cramfs module right now (it may be in use)."
    fi
  fi

  # Unmount any cramfs mounts if present
  if findmnt -t cramfs >/dev/null 2>&1; then
    mapfile -t MPTS < <(findmnt -t cramfs -n -o TARGET)
    for mp in "${MPTS[@]}"; do
      umount "$mp" 2>/dev/null || true
    done
  fi

  # Verify
  echo
  echo "Re-checking..."
  show_checks
  if is_compliant; then
    echo -e "${GREEN}Successfully applied.${RESET}"
    return 0
  else
    echo -e "${RED}Failed to apply.${RESET}"
    return 1
  fi
}

prompt_apply() {
  echo
  echo -ne "Apply fix now (create ${RULE_FILE}, force /bin/true, remove module, unmount cramfs if mounted)? [Y]es / [N]o / [C]ancel: "
  read -rsn1 ans
  echo
  case "${ans:-}" in
    Y|y) apply_fix ;;
    N|n) echo "Skipped by user." ; exit 0 ;;
    C|c) echo "Canceled by user." ; exit 1 ;;
    *)   echo "Invalid choice."; exit 1 ;;
  esac
}

main() {
  require_root
  header
  show_checks
  echo
  if is_compliant; then
    echo -e "${GREEN}Compliant:${RESET} cramfs is disabled and not mounted."
    exit 0
  else
    echo -e "${RED}Non-compliant:${RESET} cramfs is enabled/mountable/loaded or rule file is missing."
    prompt_apply
  fi
}
