#!/bin/bash
# TWGCB-01-008-0143: Ensure audit tools have permissions 750 or stricter
# Platform: Red Hat Enterprise Linux 8.5
# Behavior:
#   - Checks specific audit/rsyslog tools for mode <= 750.
#   - Prints results with "Line: N:" prefix.
#   - Prompts to apply chmod 750 to any non-compliant files.
#   - Allows skipping missing files.
# Notes:
#   - English only in code and messages (per user preference).

set -u

TITLE="TWGCB-01-008-0143: Ensure audit tools have permissions 750 or stricter"
# Bright colors
C_GRN="\e[92m"
C_RED="\e[91m"
C_YEL="\e[93m"
C_CYN="\e[96m"
C_RST="\e[0m"

# Targets from the baseline
TARGETS=(
  "/sbin/auditctl"
  "/sbin/aureport"
  "/sbin/ausearch"
  "/sbin/autrace"
  "/sbin/auditd"
  "/sbin/audisp-remote"
  "/sbin/audisp-syslog"
  "/sbin/augenrules"
  "/sbin/rsyslogd"
)

REQUIRED_MAX=750

print_header() {
  echo "$TITLE"
  echo
}

list_status() {
  local i=0
  for p in "${TARGETS[@]}"; do
    i=$((i+1))
    if [[ ! -e "$p" ]]; then
      echo "Line: $i: (Missing) $p"
      continue
    fi
    if ! stat -c "%a %U:%G %n" -- "$p" >/dev/null 2>&1; then
      echo "Line: $i: (Permission denied) $p"
      continue
    fi
    local out perm owner path
    out="$(stat -c "%a %U:%G %n" -- "$p")"
    perm="${out%% *}"
    owner="${out#* }"; owner="${owner%% *}"
    path="${out##* }"
    echo "Line: $i: $out"
  done
}

check_compliance() {
  # Populates two arrays: NONCOMPLIANT (existing files with mode > 750)
  # and MISSING (paths that do not exist)
  NONCOMPLIANT=()
  MISSING=()
  local p
  for p in "${TARGETS[@]}"; do
    if [[ ! -e "$p" ]]; then
      MISSING+=("$p")
      continue
    fi
    if ! stat -c "%a" -- "$p" >/dev/null 2>&1; then
      # If we cannot stat, treat as non-compliant (cannot verify)
      NONCOMPLIANT+=("$p")
      continue
    fi
    local perm
    perm="$(stat -c "%a" -- "$p")"
    # Numeric compare; %a is like 755, 640, etc.
    if (( perm > REQUIRED_MAX )); then
      NONCOMPLIANT+=("$p")
    fi
  done

  if ((${#NONCOMPLIANT[@]}==0)); then
    echo -e "${C_GRN}Compliant:${C_RST} All existing audit tools have permissions <= ${REQUIRED_MAX}."
  else
    echo -e "${C_RED}Non-compliant:${C_RST} The following existing files have permissions > ${REQUIRED_MAX}:"
    local idx=0
    for p in "${NONCOMPLIANT[@]}"; do
      idx=$((idx+1))
      local perm="N/A"
      if stat -c "%a" -- "$p" >/dev/null 2>&1; then
        perm="$(stat -c "%a" -- "$p")"
      fi
      echo "  - $p (mode: $perm)"
    done
  fi
}

prompt_apply() {
  local ans=""
  if ((${#NONCOMPLIANT[@]}==0)); then
    return 1  # nothing to do
  fi

  local skip_missing_choice="Y"
  if ((${#MISSING[@]}>0)); then
    # Ask once whether to skip missing files
    while true; do
      echo -ne "Missing files detected (${#MISSING[@]}). Skip missing files during apply? [Y]es / [N]o / [C]ancel: "
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
    echo -ne "Apply fix now (chmod 750 on non-compliant files; skip missing=${skip_missing_choice})? [Y]es / [N]o / [C]ancel: "
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

  for p in "${NONCOMPLIANT[@]}"; do
    if [[ ! -e "$p" ]]; then
      if [[ "$skip_missing_choice" == "Y" ]]; then
        echo "Skip (missing): $p"
        continue
      else
        echo -e "${C_RED}Failed to apply:${C_RST} $p is missing."
        ok_all=0
        continue
      fi
    fi

    if ! chmod 750 -- "$p"; then
      echo -e "${C_RED}Failed to chmod:${C_RST} $p"
      ok_all=0
      continue
    fi
  done

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
  local p perm rc=0
  for p in "${TARGETS[@]}"; do
    [[ -e "$p" ]] || continue
    if ! stat -c "%a" -- "$p" >/dev/null 2>&1; then
      rc=1
      continue
    fi
    perm="$(stat -c "%a" -- "$p")"
    if (( perm > REQUIRED_MAX )); then
      rc=1
    fi
  done
  return $rc
}

main() {
  print_header

  echo "Checking current status..."
  echo "State overview:"
  list_status
  echo

  check_compliance
  echo

  if ((${#NONCOMPLIANT[@]}==0)); then
    exit 0
  fi

  if prompt_apply; then
    exit 0
  else
    exit 1
  fi
}

main "$@"
