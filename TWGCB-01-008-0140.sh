#!/bin/bash
# TWGCB-01-008-0140: Ensure audit log directory permission is 700 or stricter
# Platform: Red Hat Enterprise Linux 8.5
# Behavior:
#   - Resolves audit log directory from /etc/audit/auditd.conf (log_file).
#   - Defaults to /var/log/audit if not configured.
#   - Prints results with "Line: N:" prefix.
#   - Prompts to apply chmod 700 if non-compliant.
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
#   sudo ./TWGCB-01-008-0140.sh

set -u

TITLE="TWGCB-01-008-0140: Ensure audit log directory permission is 700 or stricter"
AUDITD_CONF="/etc/audit/auditd.conf"
DEFAULT_LOG_DIR="/var/log/audit"
REQUIRED_MAX=700

# Bright colors
C_GRN="\e[92m"
C_RED="\e[91m"
C_YEL="\e[93m"
C_CYN="\e[96m"
C_RST="\e[0m"

resolve_log_dir() {
  # Parse log_file from auditd.conf; ignore comments and whitespace.
  # If log_file points to a file (e.g., /var/log/audit/audit.log), return its directory.
  local conf="$AUDITD_CONF"
  local path="" line=""
  if [[ -r "$conf" ]]; then
    # Extract last occurrence of non-comment 'log_file' assignment
    while IFS= read -r line; do
      # Trim leading/trailing spaces
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      # Skip comments and empty lines
      [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
      # Match log_file (case-insensitive) with optional '=' and spaces
      if [[ "$line" =~ ^[Ll][Oo][Gg]_[Ff][Ii][Ll][Ee][[:space:]]*=?[[:space:]]*(.+)$ ]]; then
        path="${BASH_REMATCH[1]}"
        # strip inline comments starting with # (not inside quotes)
        path="${path%%#*}"
        # strip surrounding quotes
        path="${path%\"}"; path="${path#\"}"
        path="${path%\'}"; path="${path#\'}"
        # trim again
        path="${path#"${path%%[![:space:]]*}"}"
        path="${path%"${path##*[![:space:]]}"}"
      fi
    done <"$conf"
  fi

  if [[ -z "$path" ]]; then
    echo "$DEFAULT_LOG_DIR"
    return
  fi

  # If path ends with '/', remove it (normalize)
  [[ "$path" == */ ]] && path="${path%/}"
  # If path is a file path (ends with .log or contains a basename with a dot), take dirname
  if [[ -n "$path" && -e "$path" && ! -d "$path" ]]; then
    echo "$(dirname -- "$path")"
    return
  fi
  # If path looks like a file by extension even if it doesn't exist, still treat as file
  if [[ "$path" == *.log || "$path" == *.txt || "$path" == *.* ]]; then
    echo "$(dirname -- "$path")"
    return
  fi
  # Otherwise assume it is a directory path
  echo "$path"
}

list_status() {
  local dir="$1"
  local i=1
  if [[ -z "$dir" ]]; then
    echo "Line: $i: (Unknown) audit log directory could not be determined"
    return
  fi
  if [[ ! -e "$dir" ]]; then
    echo "Line: $i: (Missing) $dir"
    return
  fi
  if ! stat -c "%a %U:%G %n" -- "$dir" >/dev/null 2>&1; then
    echo "Line: $i: (Permission denied) $dir"
    return
  fi
  local out
  out="$(stat -c "%a %U:%G %n" -- "$dir")"
  echo "Line: $i: $out"
}

check_compliance() {
  local dir="$1"
  NONCOMPLIANT=0
  MISSING=0

  if [[ -z "$dir" ]]; then
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} Audit log directory could not be resolved."
    return
  fi

  if [[ ! -e "$dir" ]]; then
    MISSING=1
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} $dir is missing."
    return
  fi

  if ! stat -c "%a" -- "$dir" >/dev/null 2>&1; then
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} Unable to read permission of $dir (permission denied)."
    return
  fi

  local perm
  perm="$(stat -c "%a" -- "$dir")"
  if (( perm > REQUIRED_MAX )); then
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} $dir has mode ${perm} (> ${REQUIRED_MAX})."
  else
    echo -e "${C_GRN}Compliant:${C_RST} $dir has mode ${perm} (<= ${REQUIRED_MAX})."
  fi
}

prompt_apply() {
  local dir="$1"
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
    echo -ne "Apply fix now (set chmod 700 on $dir; skip missing=${skip_missing_choice})? [Y]es / [N]o / [C]ancel: "
    IFS= read -rsn1 ans || true
    echo
    case "${ans^^}" in
      Y|"")
        apply_changes "$dir" "$skip_missing_choice"
        return 0
        ;;
      N)
        echo -e "${C_YEL}Skipped apply by user.${C_RST}"
        return 1
        ;;
      C)
        echo -ne "${C_YEL}Canceled by user.${C_RST}\n"
        exit 1
        ;;
      *)
        ;;
    esac
  done
}

apply_changes() {
  local dir="$1"
  local skip_missing_choice="${2:-Y}"
  local ok_all=1

  if [[ ! -e "$dir" ]]; then
    if [[ "$skip_missing_choice" == "Y" ]]; then
      echo "Skip (missing): $dir"
    else
      echo -e "${C_RED}Failed to apply:${C_RST} $dir is missing."
      ok_all=0
    fi
  else
    if ! chmod 700 -- "$dir"; then
      echo -e "${C_RED}Failed to chmod:${C_RST} $dir"
      ok_all=0
    fi
  fi

  echo
  echo "Re-checking..."
  echo
  list_status "$dir"
  echo

  # Verify compliance after changes
  check_compliance_post "$dir"
  if (( $? == 0 )) && (( ok_all == 1 )); then
    echo -e "${C_GRN}Successfully applied.${C_RST}"
    return 0
  else
    echo -e "${C_RED}Failed to apply.${C_RST}"
    return 1
  fi
}

check_compliance_post() {
  local dir="$1"
  # Return 0 if compliant, 1 otherwise
  if [[ -z "$dir" || ! -e "$dir" ]]; then
    return 1
  fi
  if ! stat -c "%a" -- "$dir" >/dev/null 2>&1; then
    return 1
  fi
  local perm
  perm="$(stat -c "%a" -- "$dir")"
  if (( perm > REQUIRED_MAX )); then
    return 1
  fi
  return 0
}

main() {
  echo "$TITLE"
  echo

  echo "Resolving audit log directory from $AUDITD_CONF (log_file)..."
  LOG_DIR="$(resolve_log_dir)"
  echo "Resolved directory: ${LOG_DIR:-<unknown>}"
  echo

  echo "Checking current status..."
  echo "State overview:"
  list_status "$LOG_DIR"
  echo

  check_compliance "$LOG_DIR"
  echo

  if (( NONCOMPLIANT == 0 )); then
    exit 0
  fi

  if prompt_apply "$LOG_DIR"; then
    exit 0
  else
    exit 1
  fi
}

main "$@"
