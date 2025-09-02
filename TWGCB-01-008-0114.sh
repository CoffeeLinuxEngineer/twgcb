#!/bin/bash
# TWGCB-01-008-0114: Default interface must ignore ICMP redirects (IPv4 & IPv6) on RHEL 8.5
# Requirement: net.ipv4.conf.default.accept_redirects = 0 AND net.ipv6.conf.default.accept_redirects = 0
# No Chinese in this file.

set -o errexit
set -o pipefail
set -o nounset

TITLE="TWGCB-01-008-0114: Block ICMP redirects on default interface (IPv4 & IPv6)"
GREEN="\e[1;92m"   # bright green
RED="\e[1;91m"     # bright red
YELLOW="\e[1;33m"
RESET="\e[0m"

PERSIST_FILE="/etc/sysctl.d/99-twgcb-0114.conf"
KEY4="net.ipv4.conf.default.accept_redirects"
KEY6="net.ipv6.conf.default.accept_redirects"
REQUIRED_VALUE="0"

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
  # Args: key
  local k="$1"
  local v
  if v=$(sysctl -n "$k" 2>/dev/null); then
    echo "$v"
  else
    echo "missing"
  fi
}

list_persistent_lines_for_key() {
  # Args: key
  local k="$1"
  grep -RIn --color=never -E "^[[:space:]]*${k}[[:space:]]*=" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null || true
}

show_check_lines() {
  local lines=()

  local rv4 rv6
  rv4="$(get_runtime_value "$KEY4")"
  rv6="$(get_runtime_value "$KEY6")"
  lines+=("runtime => ${KEY4} = ${rv4}")
  lines+=("runtime => ${KEY6} = ${rv6}")

  local found4 found6
  found4="$(list_persistent_lines_for_key "$KEY4")"
  found6="$(list_persistent_lines_for_key "$KEY6")"

  if [[ -n "$found4" ]]; then
    while IFS= read -r l; do
      lines+=("persist4 => ${l}")
    done <<<"$found4"
  else
    lines+=("persist4 => (no persistent setting found for ${KEY4})")
  fi

  if [[ -n "$found6" ]]; then
    while IFS= read -r l; do
      lines+=("persist6 => ${l}")
    done <<<"$found6"
  else
    lines+=("persist6 => (no persistent setting found for ${KEY6})")
  fi

  printf '%s\n' "${lines[@]}" | nl -ba -w1 -s':' | sed -E 's/^([[:space:]]*([0-9]+)):/Line: \2: /'
}

has_persistent_zero_for_key() {
  # Args: key
  local k="$1"
  grep -RIsEq "^[[:space:]]*${k}[[:space:]]*=[[:space:]]*0([[:space:]]|$)" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null
}

compliance_status() {
  # Compliant if both IPv4 and IPv6 keys are 0 at runtime AND persisted as 0 somewhere
  local rv4 rv6
  rv4="$(get_runtime_value "$KEY4")"
  rv6="$(get_runtime_value "$KEY6")"
  if [[ "$rv4" != "0" || "$rv6" != "0" ]]; then
    return 1
  fi
  if has_persistent_zero_for_key "$KEY4" && has_persistent_zero_for_key "$KEY6"; then
    return 0
  fi
  return 1
}

ensure_persist_file() {
  mkdir -p /etc/sysctl.d
  {
    printf "%s = %s\n" "$KEY4" "$REQUIRED_VALUE"
    printf "%s = %s\n" "$KEY6" "$REQUIRED_VALUE"
  } > "$PERSIST_FILE"
}

normalize_existing_files() {
  # Force any existing occurrences of the keys in sysctl configs to 0
  local files
  # IPv4
  files=($(grep -RIl -E "^[[:space:]]*${KEY4}[[:space:]]*=" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null || true))
  if [[ ${#files[@]} -gt 0 ]]; then
    for f in "${files[@]}"; do
      sed -ri "s|^[[:space:]]*(${KEY4})[[:space:]]*=.*|\\1 = ${REQUIRED_VALUE}|g" "$f"
    done
  fi
  # IPv6
  files=($(grep -RIl -E "^[[:space:]]*${KEY6}[[:space:]]*=" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null || true))
  if [[ ${#files[@]} -gt 0 ]]; then
    for f in "${files[@]}"; do
      sed -ri "s|^[[:space:]]*(${KEY6})[[:space:]]*=.*|\\1 = ${REQUIRED_VALUE}|g" "$f"
    done
  fi
}

check_compliance() {
  echo "Checking ICMP redirects (default interface, IPv4 & IPv6) ..."
  echo "Check results:"
  show_check_lines
  if compliance_status; then
    echo -e "${GREEN}Compliant: ${KEY4} and ${KEY6} are 0 at runtime and persisted to 0.${RESET}"
    return 0
  else
    echo -e "${RED}Non-compliant: One or both keys are not 0 at runtime and/or not persisted to 0.${RESET}"
    return 1
  fi
}

apply_fix() {
  echo
  echo -n "Apply fix now (set ${KEY4} and ${KEY6} to 0 persistently and at runtime)? [Y]es / [N]o / [C]ancel: "
  local ans
  IFS= read -rsn1 ans
  echo
  case "${ans}" in
    Y|y)
      echo "Updating persistent configuration..."
      normalize_existing_files
      ensure_persist_file
      echo "Applying runtime changes..."
      local ok=0
      if ! sysctl -w "${KEY4}=0"; then
        echo -e "${RED}Failed to set runtime ${KEY4}=0${RESET}"
        ok=1
      fi
      if ! sysctl -w "${KEY6}=0"; then
        echo -e "${RED}Failed to set runtime ${KEY6}=0${RESET}"
        ok=1
      fi
      # Flush routes for both stacks
      sysctl -w net.ipv4.route.flush=1 >/dev/null 2>&1 || true
      sysctl -w net.ipv6.route.flush=1 >/dev/null 2>&1 || true
      echo
      echo "Re-checking..."
      if check_compliance && [[ $ok -eq 0 ]]; then
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
