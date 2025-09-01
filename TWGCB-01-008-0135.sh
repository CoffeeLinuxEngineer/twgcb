#!/bin/bash
# TWGCB-01-008-0135: Ensure audit_backlog_limit >= 8192 in GRUB kernel cmdline
# Platform: Red Hat Enterprise Linux 8.5
# Behavior:
#   - Checks /etc/default/grub for audit_backlog_limit in GRUB_CMDLINE_LINUX.
#   - Prints results with "Line: N:" prefix.
#   - Reports compliant if >= 8192, non-compliant otherwise.
#   - Prompts Y/N/C to insert or set audit_backlog_limit=8192 (keeps other args unchanged).
#   - Regenerates grub.cfg for BIOS or UEFI accordingly.
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
#   sudo ./TWGCB-01-008-0135.sh

set -u

TITLE="TWGCB-01-008-0135: Ensure audit_backlog_limit >= 8192 in GRUB"
GRUB_DEFAULT="/etc/default/grub"
REQUIRED_MIN=8192

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

detect_grub_cfg_target() {
  # Prefer canonical paths; fallback to find.
  local target=""
  if [[ -d /sys/firmware/efi ]]; then
    # UEFI
    if [[ -f /boot/efi/EFI/redhat/grub.cfg ]]; then
      target="/boot/efi/EFI/redhat/grub.cfg"
    else
      # Fallback: first matching grub.cfg under /boot/efi
      target="$(find /boot/efi -type f -name grub.cfg 2>/dev/null | head -n1)"
    fi
  else
    # BIOS
    if [[ -f /boot/grub2/grub.cfg ]]; then
      target="/boot/grub2/grub.cfg"
    else
      # Fallback: first matching grub.cfg under /boot
      target="$(find /boot -type f -name grub.cfg 2>/dev/null | head -n1)"
    fi
  fi
  echo "$target"
}

list_status() {
  local i=0
  if [[ ! -e "$GRUB_DEFAULT" ]]; then
    echo "Line: $((i+1)): (Missing) $GRUB_DEFAULT"
    return
  fi
  if [[ ! -r "$GRUB_DEFAULT" ]]; then
    echo "Line: $((i+1)): (Permission denied) $GRUB_DEFAULT"
    return
  fi
  # Show all GRUB_CMDLINE_LINUX lines (commented or not) with their file line numbers
  local found=0
  local lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      if [[ "$line" =~ GRUB_CMDLINE_LINUX ]]; then
        i=$((i+1)); echo "Line: $i: (Commented) $GRUB_DEFAULT:$lineno: $line"; found=1
      fi
      continue
    fi
    if [[ "$line" =~ GRUB_CMDLINE_LINUX ]]; then
      i=$((i+1)); echo "Line: $i: $GRUB_DEFAULT:$lineno: $line"; found=1
    fi
  done <"$GRUB_DEFAULT"
  if (( found == 0 )); then
    echo "Line: $((i+1)): (No matching line found) GRUB_CMDLINE_LINUX in $GRUB_DEFAULT"
  fi
}

extract_current_value() {
  # Echoes numeric value if present, else empty
  if [[ ! -r "$GRUB_DEFAULT" ]]; then
    echo ""
    return
  fi
  # Take last active (non-comment) GRUB_CMDLINE_LINUX line
  local line
  line="$(grep -P '^[[:space:]]*GRUB_CMDLINE_LINUX=' "$GRUB_DEFAULT" | tail -n1)"
  [[ -z "$line" ]] && { echo ""; return; }
  # Extract the quoted cmdline contents
  local cmd
  if [[ "$line" =~ GRUB_CMDLINE_LINUX=[\"\'](.*)[\"\'] ]]; then
    cmd="${BASH_REMATCH[1]}"
  else
    cmd="${line#GRUB_CMDLINE_LINUX=}"
  fi
  # Find audit_backlog_limit=NUMBER (last occurrence wins)
  local val
  val="$(grep -oP 'audit_backlog_limit=\d+' <<<"$cmd" | tail -n1 | cut -d= -f2)"
  echo "$val"
}

is_compliant() {
  NONCOMPLIANT=0
  MISSING=0
  DENIED=0

  if [[ ! -e "$GRUB_DEFAULT" ]]; then
    MISSING=1
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} $GRUB_DEFAULT is missing."
    return 1
  fi
  if [[ ! -r "$GRUB_DEFAULT" ]]; then
    DENIED=1
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} Unable to read $GRUB_DEFAULT (permission denied)."
    return 1
  fi

  local val
  val="$(extract_current_value)"
  if [[ -z "$val" ]]; then
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} audit_backlog_limit is not set in GRUB_CMDLINE_LINUX."
    return 1
  fi
  if (( val >= REQUIRED_MIN )); then
    echo -e "${C_GRN}Compliant:${C_RST} audit_backlog_limit=$val (>= $REQUIRED_MIN)."
    return 0
  else
    NONCOMPLIANT=1
    echo -e "${C_RED}Non-compliant:${C_RST} audit_backlog_limit=$val (< $REQUIRED_MIN)."
    return 1
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
      echo -ne "Target is missing. Create $GRUB_DEFAULT and set the parameter? [Y]es / [N]o / [C]ancel: "
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
    echo -ne "Apply fix now (set audit_backlog_limit=$REQUIRED_MIN; skip missing=${skip_missing_choice})? [Y]es / [N]o / [C]ancel: "
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

  # Ensure file exists
  if [[ ! -e "$GRUB_DEFAULT" ]]; then
    if [[ "$skip_missing_choice" == "Y" ]]; then
      echo "Skip (missing): $GRUB_DEFAULT"
      ok_all=0
    else
      if ! install -m 0644 /dev/null "$GRUB_DEFAULT"; then
        echo -e "${C_RED}Failed to create:${C_RST} $GRUB_DEFAULT"
        ok_all=0
      fi
    fi
  fi

  if [[ -e "$GRUB_DEFAULT" ]]; then
    # Ensure there is an active GRUB_CMDLINE_LINUX line. If not, create one with just our parameter.
    if ! grep -Pq '^[[:space:]]*GRUB_CMDLINE_LINUX=' "$GRUB_DEFAULT"; then
      echo 'GRUB_CMDLINE_LINUX="audit_backlog_limit='"$REQUIRED_MIN"'"' >> "$GRUB_DEFAULT" || { echo -e "${C_RED}Failed to append GRUB_CMDLINE_LINUX.${C_RST}"; ok_all=0; }
    else
      # Modify the last active line: if parameter exists, replace its value; otherwise, append parameter inside quotes.
      # This sed finds the last occurrence line and edits it in-place.
      # 1) Replace value if present:
      if ! sed -ri ':a;$!{N;ba}; s/(^[[:space:]]*GRUB_CMDLINE_LINUX=)(["\x27])(.*)\2$/\1"\3"/' "$GRUB_DEFAULT"; then
        echo -e "${C_RED}Failed to normalize quotes in $GRUB_DEFAULT.${C_RST}"
        ok_all=0
      fi
      if grep -Pq '^[[:space:]]*GRUB_CMDLINE_LINUX="([^"]*)audit_backlog_limit=\d+([^"]*)"$' "$GRUB_DEFAULT"; then
        if ! sed -ri 's/^(^[[:space:]]*GRUB_CMDLINE_LINUX="([^"]*))audit_backlog_limit=\d+/\1audit_backlog_limit='"$REQUIRED_MIN"'/; t; s/^([[:space:]]*GRUB_CMDLINE_LINUX="[^"]*)$/\1/' "$GRUB_DEFAULT"; then
          echo -e "${C_RED}Failed to set audit_backlog_limit value in $GRUB_DEFAULT.${C_RST}"
          ok_all=0
        fi
      else
        if ! sed -ri 's/^([[:space:]]*GRUB_CMDLINE_LINUX=")([^"]*)(")$/\1\2 audit_backlog_limit='"$REQUIRED_MIN"'\3/' "$GRUB_DEFAULT"; then
          echo -e "${C_RED}Failed to append audit_backlog_limit in $GRUB_DEFAULT.${C_RST}"
          ok_all=0
        fi
      fi
    fi

    # Rebuild grub.cfg
    local target
    target="$(detect_grub_cfg_target)"
    if [[ -n "$target" ]]; then
      if ! grub2-mkconfig -o "$target" >/dev/null 2>&1; then
        echo -e "${C_RED}Failed to regenerate grub config:${C_RST} grub2-mkconfig -o $target"
        ok_all=0
      fi
    else
      echo -e "${C_YEL}Warning:${C_RST} Could not determine grub.cfg path; please run grub2-mkconfig manually."
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
