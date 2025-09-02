#!/bin/bash
# TWGCB-01-008-0129: Disable TIPC protocol (RHEL 8.5)
# Baseline intent: Blacklist TIPC so it cannot be loaded; ensure it's not currently loaded.
# No Chinese in this file.

set -o errexit
set -o pipefail
set -o nounset

TITLE="TWGCB-01-008-0129: Disable TIPC protocol"
GREEN="\e[1;92m"   # bright green
RED="\e[1;91m"     # bright red
YELLOW="\e[1;33m"
RESET="\e[0m"

CONF_FILE="/etc/modprobe.d/tipc.conf"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${RESET}"
    exit 1
  fi
}

print_header() {
  echo "$TITLE"
  echo
}

# Return 0 if /sbin/lsmod shows 'tipc' loaded
is_loaded() {
  lsmod | awk 'BEGIN{rc=1} $1=="tipc"{rc=0} END{exit rc}'
}

# Return 0 if modprobe is overridden to /bin/true for tipc
has_install_override() {
  # modprobe -n -v shows what would be done without doing it
  # Expect a line like: "install /bin/true"
  local out
  out="$(modprobe -n -v tipc 2>/dev/null || true)"
  grep -Eq -- '(^|[[:space:]])/bin/true([[:space:]]|$)' <<<"$out"
}

# Return 0 if any blacklist line for tipc exists in modprobe.d
has_blacklist() {
  grep -RIsEq '^[[:space:]]*blacklist[[:space:]]+tipc([[:space:]]|$)' /etc/modprobe.d 2>/dev/null
}

# Show numbered "facts" for the check section, prefixed with "Line: N: "
show_check_lines() {
  local lines=()

  # What modprobe would do
  local modprobe_out
  modprobe_out="$(modprobe -n -v tipc 2>/dev/null || true)"
  lines+=("modprobe -n -v tipc => ${modprobe_out:-<no output>}")

  # Is module loaded
  if is_loaded; then
    lines+=("lsmod => tipc is currently loaded")
  else
    lines+=("lsmod => tipc is not loaded")
  fi

  # Where blacklist/override lines are
  local grep_out
  grep_out="$(grep -RIn -- '^[[:space:]]*(install[[:space:]]+tipc[[:space:]]+/bin/true|blacklist[[:space:]]+tipc([[:space:]]|$))' /etc/modprobe.d 2>/dev/null || true)"
  if [[ -n "$grep_out" ]]; then
    # Normalize path:line:content to our "Line: N: path:line:content" by adding later
    while IFS= read -r l; do
      lines+=("conf => ${l}")
    done <<<"$grep_out"
  else
    lines+=("conf => (no install/blacklist lines for tipc found under /etc/modprobe.d)")
  fi

  printf '%s\n' "${lines[@]}" | nl -ba -w1 -s':' | sed -E 's/^([[:space:]]*([0-9]+)):/Line: \2: /'
}

# Compliant if: (install override present OR blacklist present) AND module not loaded.
# (The baseline requires disable; install override + blacklist is ideal.)
compliance_status() {
  if is_loaded; then
    return 1
  fi
  if has_install_override || has_blacklist; then
    return 0
  fi
  return 1
}

check_compliance() {
  echo "Checking TIPC status..."
  echo "Check results:"
  show_check_lines
  if compliance_status; then
    echo -e "${GREEN}Compliant: TIPC is disabled (not loaded, and blocked by install/blacklist).${RESET}"
    return 0
  else
    echo -e "${RED}Non-compliant: TIPC is loadable or currently loaded, and not fully blocked.${RESET}"
    return 1
  fi
}

apply_fix() {
  echo
  echo -n "Apply fix now (write install/blacklist to ${CONF_FILE} and unload if loaded)? [Y]es / [N]o / [C]ancel: "
  local ans
  IFS= read -rsn1 ans
  echo
  case "${ans}" in
    Y|y)
      # Ensure conf file contains required lines
      local wrote=0
      if [[ ! -f "${CONF_FILE}" ]]; then
        touch "${CONF_FILE}"
      fi

      if ! grep -Eq '^[[:space:]]*install[[:space:]]+tipc[[:space:]]+/bin/true([[:space:]]|$)' "${CONF_FILE}"; then
        echo "install tipc /bin/true" >> "${CONF_FILE}"
        wrote=1
      fi
      if ! grep -Eq '^[[:space:]]*blacklist[[:space:]]+tipc([[:space:]]|$)' "${CONF_FILE}"; then
        echo "blacklist tipc" >> "${CONF_FILE}"
        wrote=1
      fi
      if [[ $wrote -eq 1 ]]; then
        echo "Updated ${CONF_FILE}"
      else
        echo "${CONF_FILE} already contains required rules"
      fi

      # If currently loaded, try to unload
      if is_loaded; then
        echo "Attempting to unload currently loaded module: rmmod tipc"
        if ! rmmod tipc 2>/dev/null; then
          echo -e "${YELLOW}Warning: Could not unload tipc (in use?). A reboot may be required for full enforcement.${RESET}"
        fi
      fi

      echo
      echo "Re-checking..."
      if check_compliance; then
        echo -e "${GREEN}Successfully applied${RESET}"
        return 0
      else
        echo -e "${RED}Failed to apply${RESET}"
        return 1
      fi
      ;;
    N|n)
      echo "Skipped by user."
      return 0
      ;;
    C|c)
      echo "Canceled by user."
      exit 130
      ;;
    *)
      echo "Invalid choice."
      return 1
      ;;
  esac
}

main() {
  require_root
  print_header
  if check_compliance; then
    exit 0
  else
    apply_fix
  fi
}

main "$@"
