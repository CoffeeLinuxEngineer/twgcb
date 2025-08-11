#!/bin/bash
# TWGCB-01-008-0227: Set maximum password age (PASS_MAX_DAYS=90)
# Platform: RHEL 8.5
# Policy:
#   - Default for new accounts: /etc/login.defs must set PASS_MAX_DAYS 90
#   - Existing accounts: chage --maxdays 90 <user>
# Notes:
#   - Uses bright green/red messages.
#   - Prompts [Y]es / [N]o / [C]ancel before applying.
#   - Re-checks after applying.
#   - Prints lines with 'Line: <n>:' prefixes.
#   - No Chinese in code.

set -o pipefail

TARGET="/etc/login.defs"
REQUIRED_MAX=90

# Colors (bright)
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
RESET="\e[0m"

print_header() {
  echo "TWGCB-01-008-0227: Maximum password age (PASS_MAX_DAYS=${REQUIRED_MAX})"
  echo
}

show_matches() {
  echo "Checking file: $TARGET"
  echo "Check results:"
  if [ ! -e "$TARGET" ]; then
    echo "(File not found)"
    return 0
  fi
  if [ ! -r "$TARGET" ]; then
    echo "(Permission denied)"
    return 0
  fi
  # Show all PASS_MAX_DAYS lines (including commented), with "Line: N:" prefix
  if ! grep -n "PASS_MAX_DAYS" "$TARGET" 2>/dev/null | sed 's/^\([0-9]\+\):/Line: \1:/' ; then
    echo "(No matching line found)"
  fi

  echo
  echo "Existing accounts (uid >= 1000):"
  local i=0
  while IFS=: read -r name uid gid gecos home shell; do
    if [ "$uid" -ge 1000 ] && [ "$name" != "nfsnobody" ]; then
      i=$((i+1))
      max="$(awk -F: -v U="$name" '($1==U){print $5}' /etc/shadow 2>/dev/null)"
      [ -z "$max" ] && max="(empty)"
      echo "Line: $i: $name  uid=$uid  shell=$shell  maxdays=$max"
    fi
  done < /etc/passwd
  [ "$i" -eq 0 ] && echo "(No eligible user accounts found)"
}

check_defaults_compliant() {
  # Returns 0 if compliant, 1 if non-compliant, 2 if cannot verify
  if [ ! -e "$TARGET" ]; then
    return 1
  fi
  if [ ! -r "$TARGET" ]; then
    return 2
  fi
  local val
  val="$(awk '
    BEGIN { v = "" }
    {
      s=$0
      sub(/^[ \t]+/, "", s)
      if (s ~ /^#/) next
      if (s ~ /^PASS_MAX_DAYS[ \t]+-?[0-9]+([ \t].*)?$/) {
        for (i=1;i<=NF;i++) {
          if ($i ~ /^-?[0-9]+$/) { v=$i }
        }
      }
    }
    END { print v }
  ' "$TARGET")"
  [ -n "$val" ] && [ "$val" -eq "$REQUIRED_MAX" ] 2>/dev/null
}

list_login_users() {
  # Emit one username per line for uid >= 1000, excluding nfsnobody
  awk -F: '($3 >= 1000 && $1 != "nfsnobody"){print $1}' /etc/passwd
}

is_user_compliant() {
  local u="$1" v
  v="$(awk -F: -v U="$u" '($1==U){print $5}' /etc/shadow 2>/dev/null)"
  [ -n "$v" ] && [ "$v" -eq "$REQUIRED_MAX" ] 2>/dev/null
}

check_users_compliant() {
  # Returns 0 if all users compliant, 1 if any non-compliant, 2 if cannot verify
  if [ ! -r /etc/passwd ] || [ ! -r /etc/shadow ]; then
    return 2
  fi
  local ok=0
  ok=1
  while read -r u; do
    if ! is_user_compliant "$u"; then
      ok=0
    fi
  done < <(list_login_users)
  [ $ok -eq 1 ]
}

check_compliance() {
  # Returns:
  # 0: fully compliant (defaults + users)
  # 1: non-compliant
  # 2: cannot verify
  check_defaults_compliant
  local d_rc=$?
  check_users_compliant
  local u_rc=$?

  if [ $d_rc -eq 2 ] || [ $u_rc -eq 2 ]; then
    return 2
  fi
  if [ $d_rc -eq 0 ] && [ $u_rc -eq 0 ]; then
    return 0
  fi
  return 1
}

apply_fix() {
  # 1) Update /etc/login.defs to set PASS_MAX_DAYS 90
  if [ ! -e "$TARGET" ]; then
    echo -e "${RED}Failed to apply${RESET}"
    echo "(File not found: $TARGET)"
    return 1
  fi
  if [ ! -w "$TARGET" ]; then
    echo -e "${RED}Failed to apply${RESET}"
    echo "(Permission denied writing $TARGET)"
    return 1
  fi

  # Replace active lines, preserve commented ones
  sed -ri "s/^[[:space:]]*PASS_MAX_DAYS[[:space:]]+-?[0-9]+.*/PASS_MAX_DAYS ${REQUIRED_MAX}/" "$TARGET"

  # Ensure at least one active line exists; if not, append
  if ! grep -Eq '^[[:space:]]*PASS_MAX_DAYS[[:space:]]+-?[0-9]+' "$TARGET"; then
    tail -c1 "$TARGET" | read -r _ || echo >> "$TARGET"
    echo "PASS_MAX_DAYS ${REQUIRED_MAX}" >> "$TARGET"
  fi

  # 2) Update existing users
  local failed=0
  while read -r u; do
    if ! chage --maxdays "$REQUIRED_MAX" "$u" >/dev/null 2>&1; then
      echo "Failed to update: $u"
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
  show_matches
  echo

  check_compliance
  rc=$?

  if [ $rc -eq 0 ]; then
    echo -e "${GREEN}Compliant: PASS_MAX_DAYS is 90 in $TARGET and all existing users have maxdays=${REQUIRED_MAX}.${RESET}"
    exit 0
  elif [ $rc -eq 2 ]; then
    echo -e "${RED}Non-compliant: Unable to verify (permission denied reading required files).${RESET}"
    exit 1
  else
    echo -e "${RED}Non-compliant: Defaults and/or users do not meet PASS_MAX_DAYS=${REQUIRED_MAX}.${RESET}"
    while true; do
      echo -n "Apply fix now (set default and update all non-system users to ${REQUIRED_MAX})? [Y]es / [N]o / [C]ancel: "
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
