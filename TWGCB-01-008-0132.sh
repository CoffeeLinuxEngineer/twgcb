#!/bin/bash
# TWGCB-01-008-0132: Ensure auditd packages are installed (audit, audit-libs)
# Platform: Red Hat Enterprise Linux 8.5
# Behavior:
#   - Checks if `audit` and `audit-libs` are installed (rpm -q).
#   - Prints results with "Line: N:" prefix.
#   - Reports compliant if both are installed, non-compliant otherwise.
#   - Prompts Y/N/C to install missing packages using dnf.
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
#   sudo ./TWGCB-01-008-0132.sh
#
# Requirement: `dnf install audit audit-libs`

set -u

TITLE="TWGCB-01-008-0132: Ensure auditd packages (audit, audit-libs) are installed"
PACKAGES=("audit" "audit-libs")

# Bright colors
C_GRN="\e[92m"
C_RED="\e[91m"
C_YEL="\e[93m"
C_CYN="\e[96m"
C_RST="\e[0m"]

print_header() {
  echo "$TITLE"
  echo
}

list_status() {
  local i=0
  for pkg in "${PACKAGES[@]}"; do
    i=$((i+1))
    if ! command -v rpm >/dev/null 2>&1; then
      echo "Line: $i: (Permission denied or rpm not found) $pkg"
      continue
    fi
    if rpm -q "$pkg" >/dev/null 2>&1; then
      local ver
      ver="$(rpm -q "$pkg" 2>/dev/null | head -n1)"
      echo "Line: $i: installed: $ver"
    else
      echo "Line: $i: (Not installed) $pkg"
    fi
  done
}

is_compliant() {
  NONCOMPLIANT=0
  DENIED=0
  MISSING_PKGS=()

  if ! command -v rpm >/dev/null 2>&1; then
    DENIED=1
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} Cannot query packages (rpm not available or permission denied)."
    return 1
  fi

  for pkg in "${PACKAGES[@]}"; do
    if ! rpm -q "$pkg" >/dev/null 2>&1; then
      MISSING_PKGS+=("$pkg")
    fi
  done

  if ((${#MISSING_PKGS[@]}==0)); then
    echo -e "${C_GRN}Compliant:${C_RST} All required packages are installed."
    return 0
  else
    echo -e "${C_RED}Non-compliant:${C_RST} Missing package(s): ${MISSING_PKGS[*]}"
    NONCOMPLIANT=1
    return 1
  fi
}

prompt_apply() {
  local ans=""
  if (( NONCOMPLIANT == 0 )); then
    return 1
  fi

  while true; do
    echo -ne "Apply fix now (dnf install -y ${PACKAGES[*]})? [Y]es / [N]o / [C]ancel: "
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

  if ! command -v dnf >/dev/null 2>&1; then
    echo -e "${C_RED}Failed:${C_RST} dnf not found."
    ok_all=0
  else
    if ! dnf install -y "${PACKAGES[@]}"; then
      echo -e "${C_RED}Failed:${C_RST} dnf install returned an error."
      ok_all=0
    fi
  fi

  echo
  echo "Re-checking..."
  echo
  list_status
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

  echo "Checking current package state..."
  echo "State overview:"
  list_status
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
