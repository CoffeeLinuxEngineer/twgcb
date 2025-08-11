#!/bin/bash
# TWGCB-01-008-0228: Set account inactive days after password expiry (INACTIVE=30)
# Platform: RHEL 8.5
# Policy:
#   - Default for new accounts: useradd -D -f 30
#   - Existing accounts: chage --inactive 30 <user>
# Notes:
#   - Uses bright green/red messages.
#   - Prompts [Y]es / [N]o / [C]ancel before applying.
#   - Re-checks after applying.
#   - Prints lists with "Line: <n>:" prefixes.
#   - No Chinese in code.

set -o pipefail

REQUIRED_INACTIVE=30
DEFAULT_FILE="/etc/default/useradd"

# Colors (bright)
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
RESET="\e[0m"

print_header() {
  echo "TWGCB-01-008-0228: Account inactive days after password expiry (INACTIVE=${REQUIRED_INACTIVE})"
  echo
}

get_default_inactive() {
  # Prefer parsing useradd -D output
  useradd -D | awk -F= '/^INACTIVE=/{print $2}'
}

list_login_users() {
  # Emit "username:uid:shell"
  # RHEL 8: real users typically uid >= 1000; exclude nobody (65534) and system users.
  awk -F: '($3 >= 1000 && $1 != "nfsnobody") {print $1 ":" $3 ":" $7}' /etc/passwd
}

get_user_inactive_from_shadow() {
  # Arg: username
  # Read field 7 (inactive) from /etc/shadow; print blank if not set.
  local u="$1"
  awk -F: -v U="$u" '($1==U){print $7}' /etc/shadow
}

show_check_results() {
  echo "Checking files and settings:"
  echo "  - $DEFAULT_FILE (default for new accounts)"
  echo "  - /etc/passwd + /etc/shadow (existing accounts)"
  echo
  echo "Check results:"

  # Show INACTIVE line number from /etc/default/useradd if present
  if [ -r "$DEFAULT_FILE" ]; then
    if ! grep -n '^INACTIVE=' "$DEFAULT_FILE" | sed 's/^\([0-9]\+\):/Line: \1:/' ; then
      echo "$DEFAULT_FILE: (No matching line found)"
    fi
  else
    [ -e "$DEFAULT_FILE" ] || echo "$DEFAULT_FILE: (File not found)"
    [ -e "$DEFAULT_FILE" ] && [ ! -r "$DEFAULT_FILE" ] && echo "$DEFAULT_FILE: (Permission denied)"
  fi

  echo
  echo "Existing accounts (uid >= 1000):"
  local i=0
  while IFS=: read -r name uid shell; do
    i=$((i+1))
    # Skip nologin/false shells (optional; still list for visibility)
    inactive="$(get_user_inactive_from_shadow "$name")"
    # Normalize empty to "(empty)"
    [ -z "$inactive" ] && inactive="(empty)"
    echo "Line: $i: $name  uid=$uid  shell=$shell  inactive=$inactive"
  done < <(list_login_users)
  [ "$i" -eq 0 ] && echo "(No eligible user accounts found)"
}

is_default_compliant() {
  local cur
  cur="$(get_default_inactive)"
  [ -n "$cur" ] && [ "$cur" -eq "$REQUIRED_INACTIVE" ] 2>/dev/null
}

is_user_compliant() {
  # compliant if field7 == REQUIRED_INACTIVE
  local u="$1" v
  v="$(get_user_inactive_from_shadow "$u")"
  [ -n "$v" ] && [ "$v" -eq "$REQUIRED_INACTIVE" ] 2>/dev/null
}

check_compliance() {
  # Return codes:
  #   0: compliant (default + all users)
  #   1: non-compliant
  #   2: cannot verify (permission denied)
  # Check readable status of essential files
  if [ ! -r /etc/passwd ] || [ ! -r /etc/shadow ]; then
    return 2
  fi

  local all_ok=0
  is_default_compliant && all_ok=1 || all_ok=0

  local ok_users=1
  while IFS=: read -r name uid shell; do
    # Skip root and system users by uid threshold already; still exclude root if appears
    [ "$name" = "root" ] && continue
    if ! is_user_compliant "$name"; then
      ok_users=0
    fi
  done < <(list_login_users)

  if [ $all_ok -eq 1 ] && [ $ok_users -eq 1 ]; then
    return 0
  fi
  return 1
}

apply_fix() {
  # 1) Set default for new accounts
  if ! useradd -D -f "$REQUIRED_INACTIVE" >/dev/null 2>&1; then
    echo -e "${RED}Failed to apply${RESET}"
    echo "(Could not set default with 'useradd -D -f ${REQUIRED_INACTIVE}')"
    return 1
  fi

  # 2) Fix existing accounts
  local failed=0
  while IFS=: read -r name uid shell; do
    [ "$name" = "root" ] && continue
    if ! chage --inactive "$REQUIRED_INACTIVE" "$name" >/dev/null 2>&1; then
      echo "Failed to update: $name"
      failed=1
    fi
  done < <(list_login_users)

  if [ $failed -eq 1 ]; then
    echo -e "${RED}Failed to apply${RESET}"
    return 1
  fi

  # Re-check
  if check_compliance; then
    echo -e "${GREEN}Successfully applied${RESET}"
    return 0
  else
    echo -e "${RED}Failed to apply${RESET}"
    return 1
  fi
}

main() {
  print_header
  show_check_results
  echo

  check_compliance
  rc=$?

  if [ $rc -eq 0 ]; then
    echo -e "${GREEN}Compliant: Default INACTIVE=${REQUIRED_INACTIVE} and all existing users set to ${REQUIRED_INACTIVE}.${RESET}"
    exit 0
  elif [ $rc -eq 2 ]; then
    echo -e "${RED}Non-compliant: Unable to verify (permission denied reading /etc/passwd or /etc/shadow).${RESET}"
    exit 1
  else
    echo -e "${RED}Non-compliant: Default and/or existing user settings do not meet INACTIVE=${REQUIRED_INACTIVE}.${RESET}"
    while true; do
      echo -n "Apply fix now (set default and update all existing non-system users to ${REQUIRED_INACTIVE})? [Y]es / [N]o / [C]ancel: "
      read -rsn1 key
      echo
      case "$key" in
        [Yy])
          apply_fix
          exit $?
          ;;
        [Nn])
          echo "Skipped."
          exit 1
          ;;
        [Cc])
          echo "Canceled."
          exit 2
          ;;
        *)
          echo "Invalid input."
          ;;
      esac
    done
  fi
}

main
