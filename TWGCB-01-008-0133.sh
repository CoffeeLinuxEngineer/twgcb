#!/bin/bash
# TWGCB-01-008-0133: Ensure auditd service is enabled and running
# Platform: Red Hat Enterprise Linux 8.5
# Behavior:
#   - Checks auditd unit presence, is-enabled, and is-active.
#   - Prints results with "Line: N:" prefix.
#   - Reports compliant if enabled+active, non-compliant otherwise.
#   - Prompts Y/N/C to run `systemctl --now enable auditd`.
#   - Handles missing/permission denied distinctly.
#   - Re-checks after applying with bright green/red results.
# Notes:
#   - English only in code and messages.
#
# Exit codes:
#   0: compliant or successfully applied
#   1: non-compliant and user skipped/canceled or apply failed
#
# Example:
#   sudo ./TWGCB-01-008-0133.sh
#
# Requirement: `systemctl --now enable auditd`

set -u

TITLE="TWGCB-01-008-0133: Ensure auditd service is enabled and running"

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

unit_present() {
  # Return 0 if the auditd unit file is known to systemd
  systemctl list-unit-files auditd.service >/dev/null 2>&1
}

state_overview() {
  local i=0

  # Check unit presence
  local present="unknown"
  if unit_present; then
    present="present"
  else
    present="absent"
  fi

  # Check enabled state
  local enabled="unknown"
  if systemctl is-enabled auditd  >/dev/null 2>&1; then
    enabled="$(systemctl is-enabled auditd 2>/dev/null)"
  else
    if systemctl is-enabled auditd 2>&1 | grep -qi "masked"; then
      enabled="masked"
    elif systemctl is-enabled auditd 2>&1 | grep -qi "disabled"; then
      enabled="disabled"
    elif systemctl is-enabled auditd 2>&1 | grep -qi "not-found"; then
      enabled="not-found"
    fi
  fi

  # Check active state
  local active="unknown"
  if systemctl is-active auditd >/dev/null 2>&1; then
    active="$(systemctl is-active auditd 2>/dev/null)"
  else
    if systemctl is-active auditd 2>&1 | grep -qi "inactive"; then
      active="inactive"
    elif systemctl is-active auditd 2>&1 | grep -qi "failed"; then
      active="failed"
    elif systemctl is-active auditd 2>&1 | grep -qi "unknown"; then
      active="unknown"
    fi
  fi

  i=$((i+1)); echo "Line: $i: unit: $present"
  i=$((i+1)); echo "Line: $i: is-enabled: $enabled"
  i=$((i+1)); echo "Line: $i: is-active : $active"
}

is_compliant() {
  NONCOMPLIANT=0
  DENIED=0

  # If systemctl is denied, mark non-compliant
  if ! systemctl --version >/dev/null 2>&1; then
    DENIED=1
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} Unable to query systemd (permission denied or not available)."
    return 1
  fi

  # Enabled and active?
  local enabled active
  enabled="$(systemctl is-enabled auditd 2>/dev/null || true)"
  active="$(systemctl is-active  auditd 2>/dev/null || true)"

  if [[ "$enabled" == "enabled" && "$active" == "active" ]]; then
    echo -e "${C_GRN}Compliant:${C_RST} auditd is enabled and active."
    return 0
  fi

  NONCOMPLIANT=1
  echo -e "${C_RED}Non-compliant:${C_RST} auditd is not enabled and active."
  return 1
}

prompt_apply() {
  local ans=""
  if (( NONCOMPLIANT == 0 )); then
    return 1
  fi

  while true; do
    echo -ne "Apply fix now (run 'systemctl --now enable auditd')? [Y]es / [N]o / [C]ancel: "
    IFS= read -rsn1 ans || true
    echo
    case "${ans^^}" in
      Y|"")
        apply_changes
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
  local ok_all=1

  if ! systemctl --now enable auditd; then
    echo -e "${C_RED}Failed to enable/start auditd.${C_RST}"
    ok_all=0
  fi

  echo
  echo "Re-checking..."
  echo
  echo "State overview:"
  state_overview
  echo

  # Verify compliance after changes
  is_compliant
  if (( $? == 0 )) && (( ok_all == 1 )); then
    echo -e "${C_GRN}Successfully applied.${C_RST}"
    return 0
  else
    echo -e "${C_RED}Failed to apply.${C_RST}"
    return 1
  fi
}

main() {
  print_header

  echo "Checking current service state..."
  echo "State overview:"
  state_overview
  echo

  is_compliant
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
