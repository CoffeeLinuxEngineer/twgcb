#!/bin/bash
# TWGCB-01-008-0138: Ensure audit log file permission is 600 or stricter
# Platform: Red Hat Enterprise Linux 8.5
# Behavior:
#   - Resolves audit log file from /etc/audit/auditd.conf (log_file).
#   - Defaults to /var/log/audit/audit.log if not configured.
#   - Prints results with "Line: N:" prefix.
#   - Prompts to apply chmod 600 if non-compliant.
#   - Handles missing and permission denied distinctly.
#   - Re-checks after applying and reports success/failure.
# Notes:
#   - English only in code and messages.
#
# Exit codes:
#   0: compliant or successfully applied
#   1: non-compliant and user skipped/canceled or apply failed
#
# Example:
#   sudo ./TWGCB-01-008-0138.sh
#
# Requirement: audit log file permission must be 600 or stricter.

set -u

TITLE="TWGCB-01-008-0138: Ensure audit log file permission is 600 or stricter"
AUDITD_CONF="/etc/audit/auditd.conf"
DEFAULT_LOG_FILE="/var/log/audit/audit.log"
REQUIRED_MAX=600

# Bright colors
C_GRN="\e[92m"
C_RED="\e[91m"
C_YEL="\e[93m"
C_CYN="\e[96m"
C_RST="\e[0m"]

resolve_log_file() {
  # Parse log_file from auditd.conf; ignore comments and whitespace.
  # If log_file points to a directory (e.g., /var/log/audit), append /audit.log.
  local conf="$AUDITD_CONF"
  local path="" line=""
  if [[ -r "$conf" ]]; then
    while IFS= read -r line; do
      # Trim spaces
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
      if [[ "$line" =~ ^[Ll][Oo][Gg]_[Ff][Ii][Ll][Ee][[:space:]]*=?[[:space:]]*(.+)$ ]]; then
        path="${BASH_REMATCH[1]}"
        path="${path%%#*}"
        path="${path%\"}"; path="${path#\"}"
        path="${path%\'}"; path="${path#\'}"
        path="${path#"${path%%[![:space:]]*}"}"
        path="${path%"${path##*[![:space:]]}"}"
      fi
    done <"$conf"
  fi

  if [[ -z "$path" ]]; then
    echo "$DEFAULT_LOG_FILE"
    return
  fi

  [[ "$path" == */ ]] && path="${path%/}"
  if [[ -d "$path" ]]; then
    echo "$path/audit.log"
    return
  fi
  echo "$path"
}

list_status() {
  local f="$1"
  local i=1
  if [[ -z "$f" ]]; then
    echo "Line: $i: (Unknown) audit log file could not be determined"
    return
  fi
  if [[ ! -e "$f" ]]; then
    echo "Line: $i: (Missing) $f"
    return
  fi
  if ! stat -c "%a %U:%G %n" -- "$f" >/dev/null 2>&1; then
    echo "Line: $i: (Permission denied) $f"
    return
  fi
  local out
  out="$(stat -c "%a %U:%G %n" -- "$f")"
  echo "Line: $i: $out"
}

check_compliance() {
  local f="$1"
  NONCOMPLIANT=0
  MISSING=0

  if [[ -z "$f" ]]; then
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} Audit log file could not be resolved."
    return
  fi

  if [[ ! -e "$f" ]]; then
    MISSING=1
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} $f is missing."
    return
  fi

  if ! stat -c "%a" -- "$f" >/dev/null 2>&1; then
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} Unable to read permission of $f (permission denied)."
    return
  fi

  local perm
  perm="$(stat -c "%a" -- "$f")"
  if (( perm > REQUIRED_MAX )); then
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} $f has mode ${perm} (> ${REQUIRED_MAX})."
  else
    echo -e "${C_GRN}Compliant:${C_RST} $f has mode ${perm} (<= ${REQUIRED_MAX})."
  fi
}

prompt_apply() {
  local f="$1"
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
    echo -ne "Apply fix now (set chmod 600 on $f; skip missing=${skip_missing_choice})? [Y]es / [N]o / [C]ancel: "
    IFS= read -rsn1 ans || true
    echo
    case "${ans^^}" in
      Y|"")
        apply_changes "$f" "$skip_missing_choice"
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
  local f="$1"
  local skip_missing_choice="${2:-Y}"
  local ok_all=1

  if [[ ! -e "$f" ]]; then
    if [[ "$skip_missing_choice" == "Y" ]]; then
      echo "Skip (missing): $f"
    else
      echo -e "${C_RED}Failed to apply:${C_RST} $f is missing."
      ok_all=0
    fi
  else
    if ! chmod 600 -- "$f"; then
      echo -e "${C_RED}Failed to chmod:${C_RST} $f"
      ok_all=0
    fi
  fi

  echo
  echo "Re-checking..."
  echo
  list_status "$f"
  echo

  # Verify compliance after changes
  check_compliance_post "$f"
  if (( $? == 0 )) && (( ok_all == 1 )); then
    echo -e "${C_GRN}Successfully applied.${C_RST}"
    return 0
  else
    echo -e "${C_RED}Failed to apply.${C_RST}"
    return 1
  fi
}

check_compliance_post() {
  local f="$1"
  if [[ -z "$f" || ! -e "$f" ]]; then
    return 1
  fi
  if ! stat -c "%a" -- "$f" >/dev/null 2>&1; then
    return 1
  fi
  local perm
  perm="$(stat -c "%a" -- "$f")"
  if (( perm > REQUIRED_MAX )); then
    return 1
  fi
  return 0
}

main() {
  echo "$TITLE"
  echo

  echo "Resolving audit log file from $AUDITD_CONF (log_file)..."
  LOG_FILE="$(resolve_log_file)"
  echo "Resolved file: ${LOG_FILE:-<unknown>}"
  echo

  echo "Checking current status..."
  echo "State overview:"
  list_status "$LOG_FILE"
  echo

  check_compliance "$LOG_FILE"
  echo

  if (( NONCOMPLIANT == 0 )); then
    exit 0
  fi

  if prompt_apply "$LOG_FILE"; then
    exit 0
  else
    exit 1
  fi
}

main "$@"
