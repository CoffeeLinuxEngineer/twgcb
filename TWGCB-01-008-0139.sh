#!/bin/bash
# TWGCB-01-008-0139: Ensure audit log directory ownership is root:root
# Platform: Red Hat Enterprise Linux 8.5
# Behavior:
#   - Resolves audit log directory from /etc/audit/auditd.conf (log_file).
#   - Defaults to /var/log/audit if not configured.
#   - Prints results with "Line: N:" prefix.
#   - Prompts to apply chown root:root if non-compliant.
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
#   sudo ./TWGCB-01-008-0139.sh
#
# Requirement: audit log directory must be owned by root:root.

set -u

TITLE="TWGCB-01-008-0139: Ensure audit log directory ownership is root:root"
AUDITD_CONF="/etc/audit/auditd.conf"
DEFAULT_LOG_DIR="/var/log/audit"
REQUIRED_USER="root"
REQUIRED_GROUP="root"

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
    while IFS= read -r line; do
      # Trim
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
    echo "$DEFAULT_LOG_DIR"
    return
  fi

  [[ "$path" == */ ]] && path="${path%/}"
  if [[ -n "$path" && -e "$path" && ! -d "$path" ]]; then
    echo "$(dirname -- "$path")"
    return
  fi
  if [[ "$path" == *.log || "$path" == *.txt || "$path" == *.* ]]; then
    echo "$(dirname -- "$path")"
    return
  fi
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

  # Read owner:group; handle permission denied explicitly
  if ! stat -c "%U:%G" -- "$dir" >/dev/null 2>&1; then
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} Unable to read owner/group of $dir (permission denied)."
    return
  fi

  local ownergroup owner group
  ownergroup="$(stat -c "%U:%G" -- "$dir")"
  owner="${ownergroup%%:*}"
  group="${ownergroup##*:}"

  if [[ "$owner" == "$REQUIRED_USER" && "$group" == "$REQUIRED_GROUP" ]]; then
    echo -e "${C_GRN}Compliant:${C_RST} $dir is owned by $ownergroup."
  else
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} $dir is owned by $ownergroup (expected ${REQUIRED_USER}:${REQUIRED_GROUP})."
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
    echo -ne "Apply fix now (set chown ${REQUIRED_USER}:${REQUIRED_GROUP} on $dir; skip missing=${skip_missing_choice})? [Y]es / [N]o / [C]ancel: "
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
        echo -e "${C_YEL}Canceled by user.${C_RST}"
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
    if ! chown "${REQUIRED_USER}:${REQUIRED_GROUP}" -- "$dir"; then
      echo -e "${C_RED}Failed to chown:${C_RST} $dir"
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
  if [[ -z "$dir" || ! -e "$dir" ]]; then
    return 1
  fi
  if ! stat -c "%U:%G" -- "$dir" >/dev/null 2>&1; then
    return 1
  fi
  local ownergroup
  ownergroup="$(stat -c "%U:%G" -- "$dir")"
  [[ "$ownergroup" == "${REQUIRED_USER}:${REQUIRED_GROUP}" ]]
  return $?
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
