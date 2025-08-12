#!/bin/bash
# TWGCB-01-008-0223: Show last failed login count and date (pam_lastlog.so showfailed)
# Platform: RHEL 8.5
# Policy:
#   - /etc/pam.d/postlogin must have an active (non-comment) line at the top:
#       session required pam_lastlog.so showfailed
# Notes:
#   - Checks for an active pam_lastlog.so line that includes 'showfailed' (presence anywhere counts as compliant).
#     Apply places the required line at the very top if missing.
#   - Uses bright green/red messages.
#   - Prompts [Y]es / [N]o / [C]ancel before applying.
#   - Re-checks after applying.
#   - Prints lines with 'Line: <n>:' prefixes and file path.
#   - No Chinese in code.

set -o pipefail

POSTLOGIN="/etc/pam.d/postlogin"

# Colors (bright)
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
RESET="\e[0m"

print_header() {
  echo "TWGCB-01-008-0223: Enable pam_lastlog showfailed in ${POSTLOGIN}"
  echo
}

show_matches() {
  echo "Checking file: $POSTLOGIN"
  echo "Check results:"
  if [ ! -e "$POSTLOGIN" ]; then
    echo "$POSTLOGIN: (File not found)"
    return 0
  fi
  if [ ! -r "$POSTLOGIN" ]; then
    echo "$POSTLOGIN: (Permission denied)"
    return 0
  fi

  # Show all lines containing pam_lastlog.so (including commented), with file path + "Line: N:" prefix
  if ! grep -n -E 'pam_lastlog\.so' "$POSTLOGIN" 2>/dev/null | sed "s#^\\([0-9]\\+\\):#${POSTLOGIN}: Line: \\1:#"; then
    echo "$POSTLOGIN: (No matching line found)"
  fi
}

check_compliance() {
  # Returns 0 if compliant, 1 if non-compliant, 2 if cannot verify
  if [ ! -e "$POSTLOGIN" ]; then
    return 1
  fi
  if [ ! -r "$POSTLOGIN" ]; then
    return 2
  fi
  # Check for active line with pam_lastlog.so and showfailed
  if grep -Eq '^[[:space:]]*session[[:space:]]+required[[:space:]]+pam_lastlog\.so([^#]*[[:space:]]|[[:space:]]+)showfailed([[:space:]]|$)' "$POSTLOGIN"; then
    return 0
  fi
  return 1
}

apply_fix() {
  if [ ! -e "$POSTLOGIN" ]; then
    echo -e "${RED}Failed to apply${RESET}"
    echo "(File not found: $POSTLOGIN)"
    return 1
  fi
  if [ ! -w "$POSTLOGIN" ]; then
    echo -e "${RED}Failed to apply${RESET}"
    echo "(Permission denied writing $POSTLOGIN)"
    return 1
  fi

  # 1) If there is an active pam_lastlog.so line missing showfailed, append showfailed to that line
  if grep -Eq '^[[:space:]]*session[[:space:]]+required[[:space:]]+pam_lastlog\.so(?!.*(^|[[:space:]])showfailed([[:space:]]|$))' "$POSTLOGIN"; then
    # Use awk to add 'showfailed' to the first matching active line
    awk '
      BEGIN{done=0}
      {
        line=$0
        ltrim=line; sub(/^[ \t]+/, "", ltrim)
        if (!done && ltrim ~ /^session[ \t]+required[ \t]+pam_lastlog\.so/ && line !~ /(^|[ \t])showfailed([ \t]|$)/ && line !~ /^[ \t]*#/) {
          if (match(line, /[ \t]*#/, m)) {
            # Unlikely inline comment; insert before comment
            prefix=substr(line, 1, m[0, "start"]-1)
            suffix=substr(line, m[0, "start"])
            print prefix " showfailed" suffix
          } else {
            print line " showfailed"
          }
          done=1
        } else {
          print line
        }
      }
    ' "$POSTLOGIN" > "${POSTLOGIN}.twgcb.tmp" && mv "${POSTLOGIN}.twgcb.tmp" "$POSTLOGIN"
  fi

  # 2) If no active pam_lastlog.so line exists, insert required line at the very top
  if ! grep -Eq '^[[:space:]]*session[[:space:]]+required[[:space:]]+pam_lastlog\.so' "$POSTLOGIN"; then
    sed -i '1i session required pam_lastlog.so showfailed' "$POSTLOGIN" || {
      echo -e "${RED}Failed to apply${RESET}"
      return 1
    }
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
    echo -e "${GREEN}Compliant: pam_lastlog with showfailed is active in ${POSTLOGIN}.${RESET}"
    exit 0
  elif [ $rc -eq 2 ]; then
    echo -e "${RED}Non-compliant: Unable to verify (permission denied).${RESET}"
    exit 1
  else
    echo -e "${RED}Non-compliant: pam_lastlog with showfailed is missing or commented out in ${POSTLOGIN}.${RESET}"
    while true; do
      echo -n "Apply fix now (ensure 'session required pam_lastlog.so showfailed' at top of ${POSTLOGIN})? [Y]es / [N]o / [C]ancel: "
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
