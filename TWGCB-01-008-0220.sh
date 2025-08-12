#!/bin/bash
# TWGCB-01-008-0220: Account lockout threshold (deny <= 5; apply sets deny=5)
# Platform: RHEL 8.5
# Policy (RHEL 8.2+):
#   - /etc/security/faillock.conf must set: deny = 5  (baseline uses 5; value must be >0 and <=5)
#   - PAM should include pam_faillock.so so the setting is enforced.
# Notes:
#   - Bright green/red messages; "Line: N:" with file paths; [Y]es / [N]o / [C]ancel prompt.
#   - Applies by setting deny = 5 in faillock.conf and enabling pam_faillock (authselect first, then direct edit fallback).
#   - Re-checks after applying.
#   - No Chinese in code.

set -o pipefail

FAILLOCK="/etc/security/faillock.conf"
PAM_FILES=( "/etc/pam.d/system-auth" "/etc/pam.d/password-auth" )
REQUIRED_DENY=5

# Colors (bright)
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
RESET="\e[0m"

print_header() {
  echo "TWGCB-01-008-0220: Account lockout threshold (deny=${REQUIRED_DENY})"
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
    grep -n -E '^[[:space:]]*#?[[:space:]]*deny[[:space:]]*=' "$FAILLOCK" 2>/dev/null | sed "s#^\\([0-9]\\+\\):#${FAILLOCK}: Line: \\1:#" || echo "$FAILLOCK: (No matching line found)"
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

get_active_deny_value() {
  # Echo last active 'deny' numeric value from faillock.conf; empty if none/unreadable
  [ ! -r "$FAILLOCK" ] && return 1
  awk '
    {
      s=$0
      sub(/^[ \t]+/, "", s)
      if (s ~ /^#/ ) next
      if (s ~ /^deny[ \t]*=[ \t]*[0-9]+([ \t].*)?$/) {
        for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) v=$i
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
  # Returns:
  # 0: compliant (deny <= REQUIRED_DENY and >0, and pam_faillock present)
  # 1: non-compliant
  # 2: cannot verify
  local v
  v="$(get_active_deny_value)" || return 2
  if [ -z "$v" ]; then
    return 1
  fi
  if ! [ "$v" -le "$REQUIRED_DENY" ] 2>/dev/null || [ "$v" -le 0 ] 2>/dev/null; then
    return 1
  fi
  pam_faillock_present
  local p_rc=$?
  [ $p_rc -eq 2 ] && return 2
  [ $p_rc -eq 0 ] && return 0 || return 1
}

ensure_deny_in_failock() {
  # Set deny to REQUIRED_DENY in FAILLOCK
  if [ ! -e "$FAILLOCK" ]; then
    { echo "# Managed by TWGCB-01-008-0220"; echo "deny = ${REQUIRED_DENY}"; } > "$FAILLOCK" 2>/dev/null || return 1
    return 0
  fi
  if [ ! -w "$FAILLOCK" ]; then
    echo "(Permission denied writing $FAILLOCK)"
    return 1
  fi
  # Replace active lines
  sed -ri "s/^[[:space:]]*deny[[:space:]]*=[[:space:]]*[0-9]+.*/deny = ${REQUIRED_DENY}/" "$FAILLOCK"
  # Ensure at least one active line exists; append if not
  if ! awk '{s=$0; sub(/^[ \t]+/,"",s); if (s ~ /^#/) next; if (s ~ /^deny[ \t]*=/) found=1} END{exit(found?0:1)}' "$FAILLOCK"; then
    tail -c1 "$FAILLOCK" | read -r _ || echo >> "$FAILLOCK"
    echo "deny = ${REQUIRED_DENY}" >> "$FAILLOCK"
  fi
  return 0
}

enable_faillock_with_authselect() {
  # Enable with-faillock feature if available
  if ! command -v authselect >/dev/null 2>&1; then
    return 2
  fi
  authselect enable-feature with-faillock >/dev/null 2>&1 || true
  authselect apply-changes >/dev/null 2>&1 || return 1
  return 0
}

ensure_pam_faillock_in_file() {
  # Insert minimal pam_faillock lines if missing (RHEL 8.5 reads options from faillock.conf)
  local file="$1"
  [ ! -w "$file" ] && { echo "(Permission denied writing $file)"; return 1; }
  if ! grep -Eq '^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_faillock\.so.*preauth' "$file"; then
    sed -i '1i auth        required      pam_faillock.so preauth' "$file" || return 1
  fi
  if ! grep -Eq '^[[:space:]]*auth[[:space:]]+\[default=die\][[:space:]]+pam_faillock\.so.*authfail' "$file"; then
    sed -ri '/^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_faillock\.so.*preauth/ a auth        [default=die] pam_faillock.so authfail' "$file" || return 1
  fi
  if ! grep -Eq '^[[:space:]]*account[[:space:]]+required[[:space:]]+pam_faillock\.so' "$file"; then
    echo 'account     required      pam_faillock.so' >> "$file" || return 1
  fi
  return 0
}

apply_fix() {
  local failed=0

  # 1) Ensure deny in faillock.conf
  ensure_deny_in_failock || failed=1

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
    echo -e "${GREEN}Compliant: deny <= ${REQUIRED_DENY} and pam_faillock is active.${RESET}"
    exit 0
  elif [ $rc -eq 2 ]; then
    echo -e "${RED}Non-compliant: Unable to verify (permission denied).${RESET}"
    exit 1
  else
    echo -e "${RED}Non-compliant: deny missing/too high or pam_faillock not active.${RESET}"
    while true; do
      echo -n "Apply fix now (set deny=${REQUIRED_DENY} and enable pam_faillock)? [Y]es / [N]o / [C]ancel: "
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
