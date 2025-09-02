#!/bin/bash
# TWGCB-01-008-0131: Disable network interface promiscuous mode (RHEL 8.5)
# This script checks for interfaces in PROMISC mode and can disable it.
# No Chinese in this file.

set -o errexit
set -o pipefail
set -o nounset

TITLE="TWGCB-01-008-0131: Disable network interface promiscuous mode"
GREEN="\e[1;32m"
RED="\e[1;31m"
YELLOW="\e[1;33m"
RESET="\e[0m"

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

# Show lines with PROMISC and prefix "Line: N:"
show_promisc_lines() {
  local lines
  # Filter out nothing; show all 'ip -o link' lines that include PROMISC
  # Number them starting from 1 and prefix with "Line: "
  if ! lines=$(ip -o link show | grep -n "PROMISC" || true); then
    return 0
  fi
  if [[ -n "${lines}" ]]; then
    # Add "Line: " before the line numbers
    echo "${lines}" | sed -E 's/^([0-9]+):/Line: \1: /'
  fi
}

# Collect interface names that are in PROMISC
collect_promisc_ifaces() {
  # Output unique interface names that have PROMISC flag
  ip -o link show \
    | awk '/PROMISC/ {iface=$2; gsub(":", "", iface); print iface}' \
    | sort -u
}

check_compliance() {
  echo "Checking current network interfaces..."
  echo "Check results:"
  local out
  out=$(show_promisc_lines)
  if [[ -z "${out}" ]]; then
    echo "(No interfaces in PROMISC mode found)"
    echo -e "${GREEN}Compliant: Promiscuous mode is disabled on all interfaces.${RESET}"
    return 0
  else
    echo "${out}"
    echo -e "${RED}Non-compliant: One or more interfaces are in PROMISC mode.${RESET}"
    return 1
  fi
}

apply_fix() {
  echo
  echo -n "Apply fix now (disable promiscuous & multicast on those interfaces)? [Y]es / [N]o / [C]ancel: "
  local ans
  IFS= read -rsn1 ans
  echo
  case "${ans}" in
    Y|y)
      local ifs failed=0
      mapfile -t ifs < <(collect_promisc_ifaces)
      if [[ ${#ifs[@]} -eq 0 ]]; then
        echo "Nothing to do (no interfaces in PROMISC)."
        return 0
      fi
      echo "Applying:"
      for dev in "${ifs[@]}"; do
        echo "  ip link set dev ${dev} multicast off promisc off"
        if ! ip link set dev "${dev}" multicast off promisc off; then
          echo -e "  ${RED}Failed on ${dev}${RESET}"
          failed=1
        fi
      done
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
