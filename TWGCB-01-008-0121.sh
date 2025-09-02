#!/bin/bash
# TWGCB-01-008-0121: Enable reverse path filtering on all interfaces (RHEL 8.5)
# Requirement: net.ipv4.conf.all.rp_filter = 1 (persistent) and runtime value = 1
# No Chinese in this file.

set -o errexit
set -o pipefail
set -o nounset

TITLE="TWGCB-01-008-0121: Enable reverse path filtering (all.rp_filter=1)"
GREEN="\e[1;92m"   # bright green
RED="\e[1;91m"     # bright red
YELLOW="\e[1;33m"
RESET="\e[0m"

PERSIST_FILE="/etc/sysctl.d/99-twgcb-0121.conf"
KEY="net.ipv4.conf.all.rp_filter"
REQUIRED_VALUE="1"

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

get_runtime_value() {
  # Echo runtime value or "missing"
  local v
  if v=$(sysctl -n "$KEY" 2>/dev/null); then
    echo "$v"
  else
    echo "missing"
  fi
}

list_persistent_lines() {
  # Find lines in sysctl configs that set the key
  grep -RIn --color=never -E "^[[:space:]]*${KEY}[[:space:]]*=" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null || true
}

show_check_lines() {
  local lines=()
  local rv
  rv="$(get_runtime_value)"
  lines+=("runtime => ${KEY} = ${rv}")
  local found
  found="$(list_persistent_lines)"
  if [[ -n "$found" ]]; then
    while IFS= read -r l; do
      lines+=("persist => ${l}")
    done <<<"$found"
  else
    lines+=("persist => (no persistent setting found in /etc/sysctl.conf or /etc/sysctl.d)")
  fi
  printf '%s\n' "${lines[@]}" | nl -ba -w1 -s':' | sed -E 's/^([[:space:]]*([0-9]+)):/Line: \2: /'
}

has_persistent_one() {
  # Return 0 if any file sets KEY to 1
  grep -RIsEq "^[[:space:]]*${KEY}[[:space:]]*=[[:space:]]*1([[:space:]]|$)" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null
}

compliance_status() {
  # Compliant if runtime is 1 AND persistent config sets KEY to 1 somewhere
  local rv
  rv="$(get_runtime_value)"
  if [[ "$rv" != "1" ]]; then
    return 1
  fi
  if has_persistent_one; then
    return 0
  fi
  return 1
}

check_compliance() {
  echo "Checking reverse path filtering (all interfaces) ..."
  echo "Check results:"
  show_check_lines
  if compliance_status; then
    echo -e "${GREEN}Compliant: ${KEY} is 1 at runtime and persisted to 1.${RESET}"
    return 0
  else
    echo -e "${RED}Non-compliant: ${KEY} is not 1 at runtime and/or not persisted to 1.${RESET}"
    return 1
  fi
}

ensure_persist_file() {
  mkdir -p /etc/sysctl.d
  printf "%s = %s\n" "$KEY" "$REQUIRED_VALUE" > "$PERSIST_FILE"
}

normalize_existing_files() {
  # For any existing occurrences of KEY in sysctl configs, force to 1
  local files
  files=($(grep -RIl -E "^[[:space:]]*${KEY}[[:space:]]*=" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null || true))
  if [[ ${#files[@]} -gt 0 ]]; then
    for f in "${files[@]}"; do
      sed -ri "s|^[[:space:]]*(${KEY})[[:space:]]*=.*|\\1 = ${REQUIRED_VALUE}|g" "$f"
    done
  fi
}

apply_fix() {
  echo
  echo -n "Apply fix now (set ${KEY}=1 persistently and at runtime)? [Y]es / [N]o / [C]ancel: "
  local ans
  IFS= read -rsn1 ans
  echo
  case "${ans}" in
    Y|y)
      echo "Updating persistent configuration..."
      normalize_existing_files
      ensure_persist_file
      echo "Applying runtime changes..."
      if ! sysctl -w "${KEY}=1"; then
        echo -e "${RED}Failed to set runtime ${KEY}=1${RESET}"
        return 1
      fi
      # Flush IPv4 routes as guidance suggests
      sysctl -w net.ipv4.route.flush=1 >/dev/null 2>&1 || true
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
