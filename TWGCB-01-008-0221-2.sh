#!/bin/bash
# TWGCB-01-008-0221: Account lockout unlock_time >= 900 seconds
# Platform: RHEL 8.5
# Policy for RHEL 8.2+:
#   - /etc/security/faillock.conf must have: unlock_time = 900 (or higher)
#   - PAM must include pam_faillock.so
# Notes:
#   - Bright green/red messages; "Line: N:" with file paths; [Y]es / [N]o / [C]ancel prompt.
#   - Tries authselect first; if it fails or still non-compliant, falls back to editing /etc/pam.d/* directly.
#   - No Chinese in code.

set -o pipefail

FAILLOCK="/etc/security/faillock.conf"
PAM_FILES=( "/etc/pam.d/system-auth" "/etc/pam.d/password-auth" )
REQUIRED_UNLOCK=900

# Colors (bright)
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
RESET="\e[0m"

print_header() {
  echo "TWGCB-01-008-0221: Account unlock_time >= ${REQUIRED_UNLOCK} seconds"
  echo
}

show_matches() {
  echo "Checking files:"
  echo "  - $FAILLOCK"
  for f in "${PAM_FILES[@]}"; do
    echo "  - $f"
  done
  echo
  echo "Check results:"

  # faillock.conf lines
  if [ ! -e "$FAILLOCK" ]; then
    echo "$FAILLOCK: (File not found)"
  elif [ ! -r "$FAILLOCK" ]; then
    echo "$FAILLOCK: (Permission denied)"
  else
    grep -n -E 'unlock_time' "$FAILLOCK" 2>/dev/null | sed "s#^\\([0-9]\\+\\):#${FAILLOCK}: Line: \\1:#" || echo "$FAILLOCK: (No matching line found)"
  fi

  # PAM files: show pam_faillock lines
  for f in "${PAM_FILES[@]}"; do
    if [ ! -e "$f" ]; then
      echo "$f: (File not found)"
      continue
    fi
    if [ ! -r "$f" ]; then
      echo "$f: (Permission denied)"
      continue
    fi
    if ! grep -n -E 'pam_faillock\.so' "$f" 2>/dev/null | sed "s#^\\([0-9]\\+\\):#${f}: Line: \\1:#"; then
      echo "$f: (No pam_faillock line found)"
    fi
  done
}

get_active_unlock_time() {
  [ ! -r "$FAILLOCK" ] && return 1
  awk '
    {
      s=$0
      sub(/^[ \t]+/, "", s)
      if (s ~ /^#/) next
      if (s ~ /^unlock_time[ \t]*=[ \t]*[0-9]+([ \t].*)?$/) {
        for (i=1;i<=NF;i++) {
          if ($i ~ /^[0-9]+$/) v=$i
        }
      }
    }
    END { if (v != "") print v }
  ' "$FAILLOCK"
}

pam_faillock_present() {
  # 0 if at least one PAM file has an active pam_faillock.so line; 1 otherwise; 2 if unreadable
  local any_perm=0
  local present=1
  for f in "${PAM_FILES[@]}"; do
    if [ ! -r "$f" ]; then
      any_perm=1
      continue
    fi
    if grep -Eq '^[[:space:]]*(auth|account)[[:space:]]+.*pam_faillock\.so' "$f"; then
      present=0
    fi
  done
  [ $any_perm -eq 1 ] && return 2
  return $present
}

check_compliance() {
  local v
  v="$(get_active_unlock_time)" || return 2
  if [ -z "$v" ] || ! [ "$v" -ge "$REQUIRED_UNLOCK" ] 2>/dev/null; then
    return 1
  fi
  pam_faillock_present
  local p_rc=$?
  [ $p_rc -eq 0 ] && return 0
  [ $p_rc -eq 2 ] && return 2 || return 1
}

ensure_unlock_time_in_failock() {
  if [ ! -e "$FAILLOCK" ]; then
    { echo "# Managed by TWGCB-01-008-0221"; echo "unlock_time = ${REQUIRED_UNLOCK}"; } > "$FAILLOCK" 2>/dev/null || return 1
    return 0
  fi
  if [ ! -w "$FAILLOCK" ]; then
    echo "(Permission denied writing $FAILLOCK)"
    return 1
  fi
  sed -ri "s/^[[:space:]]*unlock_time[[:space:]]*=[[:space:]]*[0-9]+.*/unlock_time = ${REQUIRED_UNLOCK}/" "$FAILLOCK"
  if ! awk '{s=$0; sub(/^[ \t]+/,"",s); if (s ~ /^#/ ) next; if (s ~ /^unlock_time[ \t]*=/) found=1} END{exit(found?0:1)}' "$FAILLOCK"; then
    tail -c1 "$FAILLOCK" | read -r _ || echo >> "$FAILLOCK"
    echo "unlock_time = ${REQUIRED_UNLOCK}" >> "$FAILLOCK"
  fi
  return 0
}

enable_faillock_with_authselect() {
  if ! command -v authselect >/dev/null 2>&1; then
    return 2
  fi
  # Try to enable feature on the current profile
  authselect enable-feature with-faillock >/dev/null 2>&1 || true
  authselect apply-changes >/dev/null 2>&1 || return 1
  return 0
}

ensure_pam_faillock_in_file() {
  local file="$1"
  [ ! -w "$file" ] && { echo "(Permission denied writing $file)"; return 1; }
  # Insert preauth at top if missing
  if ! grep -Eq '^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_faillock\.so.*preauth' "$file"; then
    sed -i '1i auth        required      pam_faillock.so preauth' "$file" || return 1
  fi
  # Insert authfail after preauth if missing
  if ! grep -Eq '^[[:space:]]*auth[[:space:]]+\[default=die\][[:space:]]+pam_faillock\.so.*authfail' "$file"; then
    sed -ri '/^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_faillock\.so.*preauth/ a auth        [default=die] pam_faillock.so authfail' "$file" || return 1
  fi
  # Ensure account line
  if ! grep -Eq '^[[:space:]]*account[[:space:]]+required[[:space:]]+pam_faillock\.so' "$file"; then
    echo 'account     required      pam_faillock.so' >> "$file" || return 1
  fi
  return 0
}

apply_fix() {
  local failed=0

  # 1) faillock.conf
  ensure_unlock_time_in_failock || failed=1

  # 2) Try authselect first
  local as_rc=1
  enable_faillock_with_authselect
  as_rc=$?

  # 3) Regardless of authselect result, verify; if still missing, fallback to direct edits
  pam_faillock_present
  local present_rc=$?
  if [ $present_rc -ne 0 ]; then
    for f in "${PAM_FILES[@]}"; do
      ensure_pam_faillock_in_file "$f" || failed=1
    done
  fi

  # Re-check
  if check_compliance; then
    echo -e "${GREEN}Successfully applied${RESET}"
    return 0
  else
    echo -e "${RED}Failed to apply${RESET}"
    # Helpful hints:
    echo "Hints:"
    echo " - If your system uses authselect with a custom profile, run: authselect select sssd with-faillock --force && authselect apply-changes"
    echo " - Otherwise, verify pam_faillock lines exist in both ${PAM_FILES[0]} and ${PAM_FILES[1]}."
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
    echo -e "${GREEN}Compliant: unlock_time >= ${REQUIRED_UNLOCK} and pam_faillock is active.${RESET}"
    exit 0
  elif [ $rc -eq 2 ]; then
    echo -e "${RED}Non-compliant: Unable to verify (permission denied).${RESET}"
    exit 1
  else
    echo -e "${RED}Non-compliant: unlock_time missing/too low or pam_faillock not active.${RESET}"
    while true; do
      echo -n "Apply fix now (set unlock_time=${REQUIRED_UNLOCK} and enable pam_faillock)? [Y]es / [N]o / [C]ancel: "
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
