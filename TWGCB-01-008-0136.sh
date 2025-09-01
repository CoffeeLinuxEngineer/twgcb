#!/bin/bash
# TWGCB-01-008-0136: Ensure audit processing failure notifies administrator (postmaster -> root)
# Platform: Red Hat Enterprise Linux 8.5
# Behavior:
#   - Checks /etc/aliases for `postmaster: root`.
#   - Prints results with "Line: N:" prefix (shows matching/non-matching postmaster lines or missing state).
#   - Prompts to insert or correct the alias.
#   - Runs `newaliases` after modification.
#   - Handles missing and permission denied distinctly.
#   - Re-checks after applying and reports success/failure with bright green/red messages.
# Notes:
#   - English only in code and messages.
#
# Exit codes:
#   0: compliant or successfully applied
#   1: non-compliant and user skipped/canceled or apply failed
#
# Example:
#   sudo ./TWGCB-01-008-0136.sh
#
# Requirement: /etc/aliases must contain `postmaster: root`

set -u

TITLE="TWGCB-01-008-0136: Ensure audit failure notifications go to root (postmaster alias)"
TARGET="/etc/aliases"

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
  local i=0
  if [[ ! -e "$TARGET" ]]; then
    echo "Line: $((i+1)): (Missing) $TARGET"
    return
  fi
  if [[ ! -r "$TARGET" ]]; then
    echo "Line: $((i+1)): (Permission denied) $TARGET"
    return
  fi

  # Show lines related to postmaster (including commented or malformed), or a clear message if none
  local found=0
  local lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      if [[ "$line" =~ [Pp][Oo][Ss][Tt][Mm][Aa][Ss][Tt][Ee][Rr][[:space:]]*: ]]; then
        i=$((i+1)); echo "Line: $i: (Commented) $TARGET:$lineno: $line"; found=1
      fi
      continue
    fi
    if [[ "$line" =~ [Pp][Oo][Ss][Tt][Mm][Aa][Ss][Tt][Ee][Rr][[:space:]]*: ]]; then
      i=$((i+1)); echo "Line: $i: $TARGET:$lineno: $line"; found=1
    fi
  done <"$TARGET"

  if (( found == 0 )); then
    echo "Line: $((i+1)): (No matching line found) postmaster:* in $TARGET"
  fi
}

is_compliant() {
  # Returns 0 if compliant, 1 otherwise; sets globals
  NONCOMPLIANT=0
  MISSING=0
  DENIED=0

  if [[ ! -e "$TARGET" ]]; then
    MISSING=1
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} $TARGET is missing."
    return 1
  fi
  if [[ ! -r "$TARGET" ]]; then
    DENIED=1
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} Unable to read $TARGET (permission denied)."
    return 1
  fi

  # A strict match: postmaster: root (allow whitespace variations, case-insensitive key, exact 'root' value)
  if grep -Pqi '^[[:space:]]*postmaster[[:space:]]*:[[:space:]]*root[[:space:]]*(#.*)?$' "$TARGET"; then
    echo -e "${C_GRN}Compliant:${C_RST} Found 'postmaster: root' in $TARGET."
    return 0
  fi

  NONCOMPLIANT=1
  echo -e "${C_RED}Non-compliant:${C_RST} 'postmaster: root' not present or incorrect in $TARGET."
  return 1
}

prompt_apply() {
  local ans=""
  if (( NONCOMPLIANT == 0 )); then
    return 1
  fi

  local action_hint="insert or correct alias"
  local skip_missing_choice="Y"
  if (( MISSING == 1 )); then
    while true; do
      echo -ne "Target is missing. Create $TARGET and add alias? [Y]es / [N]o / [C]ancel: "
      IFS= read -rsn1 ans || true
      echo
      case "${ans^^}" in
        Y|"") skip_missing_choice="N"; break ;; # choose not to skip => create
        N)    skip_missing_choice="Y"; break ;;
        C)    echo -e "${C_YEL}Canceled by user.${C_RST}"; exit 1 ;;
        *)    ;;
      esac
    done
  fi

  while true; do
    echo -ne "Apply fix now (${action_hint}; skip missing=${skip_missing_choice})? [Y]es / [N]o / [C]ancel: "
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

  # Ensure file exists (depending on choice)
  if [[ ! -e "$TARGET" ]]; then
    if [[ "$skip_missing_choice" == "Y" ]]; then
      echo "Skip (missing): $TARGET"
      ok_all=0
    else
      # Create with sane header
      if ! install -m 0644 /dev/null "$TARGET"; then
        echo -e "${C_RED}Failed to create:${C_RST} $TARGET"
        ok_all=0
      fi
    fi
  fi

  # If we have a file, attempt to enforce the alias
  if [[ -e "$TARGET" ]]; then
    # If there is any postmaster line (even commented), replace active lines, and ensure one correct line exists.
    if grep -Pq '^[[:space:]]*postmaster[[:space:]]*:' "$TARGET"; then
      if ! sed -ri 's/^[[:space:]]*postmaster[[:space:]]*:.*/postmaster: root/' "$TARGET"; then
        echo -e "${C_RED}Failed to modify:${C_RST} $TARGET"
        ok_all=0
      fi
    else
      echo "postmaster: root" >> "$TARGET" || { echo -e "${C_RED}Failed to append:${C_RST} $TARGET"; ok_all=0; }
    fi

    # Rebuild aliases database (Postfix/Sendmail)
    if command -v newaliases >/dev/null 2>&1; then
      if ! newaliases >/dev/null 2>&1; then
        echo -e "${C_RED}Failed to run newaliases.${C_RST}"
        ok_all=0
      fi
    else
      echo -e "${C_YEL}Warning:${C_RST} 'newaliases' not found; ensure your MTA refreshes aliases."
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

  echo "Checking current status..."
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
