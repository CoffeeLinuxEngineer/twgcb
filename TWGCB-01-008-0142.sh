#!/bin/bash
# TWGCB-01-008-0142: Ensure /etc/audit/auditd.conf permission is 640 or stricter
# Platform: Red Hat Enterprise Linux 8.5
# Behavior:
#   - Checks /etc/audit/auditd.conf for mode <= 640.
#   - Prints results with "Line: N:" prefix.
#   - Prompts to apply chmod 640 if non-compliant.
#   - Handles missing and permission denied distinctly.
#   - Re-checks after applying and reports success/failure.
# Notes:
#   - English only in code and messages.

set -u

TITLE="TWGCB-01-008-0142: Ensure /etc/audit/auditd.conf permission is 640 or stricter"
TARGET="/etc/audit/auditd.conf"
REQUIRED_MAX=640

# Bright colors
C_GRN="\e[92m"
C_RED="\e[91m"
C_YEL="\e[93m"
C_CYN="\e[96m"
C_RST="\e[0m"

print_header() {
  echo "$TITLE"
  echo
}

list_status() {
  # Always print a single numbered line for the target
  local i=1
  if [[ ! -e "$TARGET" ]]; then
    echo "Line: $i: (Missing) $TARGET"
    return
  fi
  if ! stat -c "%a %U:%G %n" -- "$TARGET" >/dev/null 2>&1; then
    echo "Line: $i: (Permission denied) $TARGET"
    return
  fi
  local out
  out="$(stat -c "%a %U:%G %n" -- "$TARGET")"
  echo "Line: $i: $out"
}

check_compliance() {
  NONCOMPLIANT=0
  MISSING=0

  if [[ ! -e "$TARGET" ]]; then
    MISSING=1
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} $TARGET is missing."
    return
  fi

  if ! stat -c "%a" -- "$TARGET" >/dev/null 2>&1; then
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} Unable to read permission of $TARGET (permission denied)."
    return
  fi

  local perm
  perm="$(stat -c "%a" -- "$TARGET")"
  if (( perm > REQUIRED_MAX )); then
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} $TARGET has mode ${perm} (> ${REQUIRED_MAX})."
  else
    echo -e "${C_GRN}Compliant:${C_RST} $TARGET has mode ${perm} (<= ${REQUIRED_MAX})."
  fi
}

prompt_apply() {
  local ans=""
  if (( NONCOMPLIANT == 0 )); then
    return 1
  fi

  local skip_missing_choice="Y"
  if (( MISSING == 1 )); then
    while true; do
      echo -ne "Target is missing. Skip if missing during apply? [Y]es / [N]o / [C]ancel: "
      IFS= read -rsn1 ans || true
      echo
      case "${ans^^}" in
        Y|"") skip_missing_choice="Y"; break ;;
        N)    skip_missing_choice="N"; break ;;
        C)    echo -e "${C_YEL}Canceled by user.${C_RST}"; exit 1 ;;
        *)    ;;
      esac
    done
  fi

  while true; do
    echo -ne "Apply fix now (set chmod 640 on $TARGET; skip missing=${skip_missing_choice})? [Y]es / [N]o / [C]ancel: "
    IFS= read -rsn1 ans || true
    echo
    case "${ans^^}" in
      Y|"")
        apply_changes "$skip_missing_choice"
        return 0
        ;;
      N)
        echo -e "${C_YEL}Skipped apply by user.${C_RST}"
        return 1
        ;;
      C)
        echo -e "${C_YEL}Canceled by user.${C_RST}"
        exit 1
        ;;
      *)
        ;;
    esac
  done
}

apply_changes() {
  local skip_missing_choice="${1:-Y}"
  local ok_all=1

  if [[ ! -e "$TARGET" ]]; then
    if [[ "$skip_missing_choice" == "Y" ]]; then
      echo "Skip (missing): $TARGET"
    else
      echo -e "${C_RED}Failed to apply:${C_RST} $TARGET is missing."
      ok_all=0
    fi
  else
    if ! chmod 640 -- "$TARGET"; then
      echo -e "${C_RED}Failed to chmod:${C_RST} $TARGET"
      ok_all=0
    fi
  fi

  echo
  echo "Re-checking..."
  echo
  list_status
  echo

  # Verify compliance after changes
  check_compliance_post
  if (( $? == 0 )) && (( ok_all == 1 )); then
    echo -e "${C_GRN}Successfully applied.${C_RST}"
    return 0
  else
    echo -e "${C_RED}Failed to apply.${C_RST}"
    return 1
  fi
}

check_compliance_post() {
  # Return 0 if compliant, 1 otherwise
  if [[ ! -e "$TARGET" ]]; then
    return 1
  fi
  if ! stat -c "%a" -- "$TARGET" >/dev/null 2>&1; then
    return 1
  fi
  local perm
  perm="$(stat -c "%a" -- "$TARGET")"
  if (( perm > REQUIRED_MAX )); then
    return 1
  fi
  return 0
}

main() {
  print_header

  echo "Checking current status..."
  echo "State overview:"
  list_status
  echo

  check_compliance
  echo

  if (( NONCOMPLIANT == 0 )); then
    exit 0
  fi

  if prompt_apply; then
    exit 0
  else
    exit 1
  fi
}

main "$@"
