#!/bin/bash
# TWGCB-01-008-0107: Remove old components after updates (RHEL 8.5)
# Requirement: Set clean_requirements_on_remove=True in both /etc/yum.conf and /etc/dnf/dnf.conf
# No Chinese in this file.

set -o errexit
set -o pipefail
set -o nounset

TITLE="TWGCB-01-008-0107: Enable clean_requirements_on_remove (yum & dnf)"
GREEN="\e[1;92m"   # bright green
RED="\e[1;91m"     # bright red
YELLOW="\e[1;33m"
RESET="\e[0m"

YUM_CONF="/etc/yum.conf"
DNF_CONF="/etc/dnf/dnf.conf"
KEY="clean_requirements_on_remove"
REQ_VALUE="True"

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

# Return 0 if file contains KEY=True (case-insensitive for key and value)
file_has_required_setting() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk -v IGNORECASE=1 -v key="$KEY" -v val="$REQ_VALUE" '
    /^[[:space:]]*#/ { next }
    match($0, /^[[:space:]]*([a-z_.]+)[[:space:]]*=[[:space:]]*([^[:space:]]+)/, m) {
      if (tolower(m[1]) == tolower(key) && tolower(m[2]) == tolower(val)) { found=1 }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

# Show numbered facts about current state with "Line: N: " prefix
show_check_lines() {
  local lines=()

  if [[ -f "$YUM_CONF" ]]; then
    lines+=("exists => ${YUM_CONF}")
    local g
    g="$(grep -n -i -E '^[[:space:]]*('"$KEY"')[[:space:]]*=' "$YUM_CONF" 2>/dev/null || true)"
    if [[ -n "$g" ]]; then
      while IFS= read -r l; do lines+=("yum.conf => ${l}"); done <<<"$g"
    else
      lines+=("yum.conf => (no ${KEY}= line found)")
    fi
  else
    lines+=("exists => ${YUM_CONF} (missing)")
  fi

  if [[ -f "$DNF_CONF" ]]; then
    lines+=("exists => ${DNF_CONF}")
    local h
    h="$(grep -n -i -E '^[[:space:]]*('"$KEY"')[[:space:]]*=' "$DNF_CONF" 2>/dev/null || true)"
    if [[ -n "$h" ]]; then
      while IFS= read -r l; do lines+=("dnf.conf => ${l}"); done <<<"$h"
    else
      lines+=("dnf.conf => (no ${KEY}= line found)")
    fi
  else
    lines+=("exists => ${DNF_CONF} (missing)")
  fi

  printf '%s\n' "${lines[@]}" | nl -ba -w1 -s':' | sed -E 's/^([[:space:]]*([0-9]+)):/Line: \2: /'
}

# Compliance: both files have KEY=True
compliance_status() {
  file_has_required_setting "$YUM_CONF" && file_has_required_setting "$DNF_CONF"
}

ensure_ini_file_and_main() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  if [[ ! -f "$file" ]]; then
    printf "%s\n\n[main]\n" "# Managed by TWGCB-01-008-0107" > "$file"
    return 0
  fi
  # Ensure [main] section exists
  if ! grep -qi '^\[main\]' "$file"; then
    # Prepend [main] if not present
    printf "%s\n%s\n%s\n" "# Managed by TWGCB-01-008-0107" "[main]" "$(cat "$file")" > "${file}.tmp"
    mv "${file}.tmp" "$file"
  fi
}

set_key_in_file() {
  local file="$1"
  ensure_ini_file_and_main "$file"

  # If key exists, normalize to True in place; else append under [main]
  if grep -qiE "^[[:space:]]*${KEY}[[:space:]]*=" "$file"; then
    # Replace existing value with True
    sed -ri "s|^[[:space:]]*(${KEY})[[:space:]]*=.*|\1=${REQ_VALUE}|I" "$file"
  else
    # Append directly after the first [main] section header
    awk -v key="$KEY" -v val="$REQ_VALUE" '
      BEGIN{IGNORECASE=1; done=0}
      /^\[main\][[:space:]]*$/ && !done { print; print key"="val; done=1; next }
      { print }
      END { if (!done) { print "[main]"; print key"="val } }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi
}

check_compliance() {
  echo "Checking ${KEY} setting in yum & dnf ..."
  echo "Check results:"
  show_check_lines
  if compliance_status; then
    echo -e "${GREEN}Compliant: ${KEY} is set to True in both ${YUM_CONF} and ${DNF_CONF}.${RESET}"
    return 0
  else
    echo -e "${RED}Non-compliant: ${KEY} is missing or not True in one or both config files.${RESET}"
    return 1
  fi
}

apply_fix() {
  echo
  echo -n "Apply fix now (set ${KEY}=True in both yum & dnf configs)? [Y]es / [N]o / [C]ancel: "
  local ans
  IFS= read -rsn1 ans
  echo
  case "${ans}" in
    Y|y)
      set_key_in_file "$YUM_CONF"
      set_key_in_file "$DNF_CONF"
      echo "Updated ${YUM_CONF} and ${DNF_CONF}"
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
