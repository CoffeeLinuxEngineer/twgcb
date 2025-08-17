#!/bin/bash
# TWGCB-01-008-0176: Ensure rsyslog $FileCreateMode is 0640 or stricter
# Target OS: RHEL 8.5
# v2: more robust globbing, backups, immutable-file checks, explicit writes

set -euo pipefail

REQUIRED_MODE="0640"
PRIMARY_CONF="/etc/rsyslog.conf"
EXTRA_DIR="/etc/rsyslog.d"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0176 (v2): Ensure rsyslog \$FileCreateMode is $REQUIRED_MODE or stricter"

shopt -s nullglob
FILES_TO_CHECK=("$PRIMARY_CONF")
if [ -d "$EXTRA_DIR" ]; then
  for f in "$EXTRA_DIR"/*.conf; do
    FILES_TO_CHECK+=("$f")
  done
fi

has_setting_in_file() {
  local f="$1"
  grep -Eq "^[[:space:]]*\$FileCreateMode[[:space:]]+[0-9]{4}" "$f"
}

is_compliant_line() {
  # stdin: one line containing "$FileCreateMode <mode>"
  # Return 0 if mode is 0640 or more restrictive, else 1
  local mode
  mode="$(awk '{print $2}' | tr -d '\r')"
  [[ "$mode" =~ ^0[0-7]{3}$ ]] || return 1
  # Allow 0640 and any 0[0-5]xx, 0600-0639
  [[ "$mode" =~ ^0(640|63[0-9]|6[0-2][0-9]|60[0-9]|[0-5][0-9]{2})$ ]]
}

file_has_compliant_setting() {
  local f="$1"
  grep -E "^[[:space:]]*\$FileCreateMode[[:space:]]+[0-9]{4}" "$f" | while IFS= read -r line; do
    if echo "$line" | is_compliant_line; then
      return 0
    fi
  done
  return 1
}

show_status() {
  echo
  echo "Checking files:"
  for f in "${FILES_TO_CHECK[@]}"; do
    [ -f "$f" ] && echo "  - $f"
  done
  echo
  echo "Check results:"
  local found=0
  for f in "${FILES_TO_CHECK[@]}"; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      mode="$(echo "$line" | awk '{print $2}')"
      if [[ "$mode" =~ ^0[0-7]{3}$ ]]; then
        if echo "$line" | is_compliant_line; then
          echo -e "$f: Line: ${CLR_GREEN}$line${CLR_RESET}"
        else
          echo -e "$f: Line: ${CLR_RED}$line${CLR_RESET}"
        fi
        found=1
      fi
    done < <(grep -En "^[[:space:]]*\$FileCreateMode[[:space:]]+[0-9]{4}" "$f" || true)
  done
  [ $found -eq 0 ] && echo "(No matching setting found)"
}

check_compliance() {
  for f in "${FILES_TO_CHECK[@]}"; do
    [ -f "$f" ] || continue
    if file_has_compliant_setting "$f"; then
      return 0
    fi
  done
  return 1
}

ensure_writable() {
  local f="$1"
  # Detect immutable bit, which would block edits even as root
  if command -v lsattr >/dev/null 2>&1; then
    if lsattr -a "$f" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
      echo -e "${CLR_RED}$f appears to be immutable (chattr +i). Remove immutability first: chattr -i $f${CLR_RESET}"
      return 1
    fi
  fi
  return 0
}

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  cp -a "$f" "${f}.bak-0176-$(date +%Y%m%d%H%M%S)"
}

apply_fix_in_file() {
  local f="$1"
  [ -f "$f" ] || return 0

  ensure_writable "$f" || return 1
  backup_file "$f"

  if has_setting_in_file "$f"; then
    # Replace first occurrence; keep others untouched
    awk -v req="$REQUIRED_MODE" '
      BEGIN{done=0}
      /^[[:space:]]*\$FileCreateMode[[:space:]]+[0-9]{4}/ && !done {
        print "$FileCreateMode " req; done=1; next
      }
      {print $0}
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    printf "%s\n" "\$FileCreateMode $REQUIRED_MODE" >> "$f"
  fi
}

apply_fix() {
  local changed=0
  # Prefer to write to PRIMARY_CONF if nothing else has the setting
  local any_setting=0
  for f in "${FILES_TO_CHECK[@]}"; do
    [ -f "$f" ] || continue
    if has_setting_in_file "$f"; then
      any_setting=1
      break
    fi
  done

  if [ $any_setting -eq 1 ]; then
    for f in "${FILES_TO_CHECK[@]}"; do
      [ -f "$f" ] || continue
      if has_setting_in_file "$f"; then
        apply_fix_in_file "$f" && changed=1
      fi
    done
  else
    # Append only to PRIMARY_CONF to avoid scattering settings
    [ -f "$PRIMARY_CONF" ] || touch "$PRIMARY_CONF"
    apply_fix_in_file "$PRIMARY_CONF" && changed=1
  fi

  if [ $changed -eq 1 ]; then
    systemctl restart rsyslog || true
  fi
}

# ---- Main flow ----
show_status
if check_compliance; then
  echo -e "${CLR_GREEN}Compliant: \$FileCreateMode is $REQUIRED_MODE or stricter.${CLR_RESET}"
  exit 0
else
  echo -e "${CLR_RED}Non-compliant: \$FileCreateMode is missing or too permissive.${CLR_RESET}"
fi

while true; do
  echo -ne "${CLR_YELLOW}Apply fix now (set \$FileCreateMode to $REQUIRED_MODE)? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
  read -rsn1 key || true
  echo
  case "${key:-}" in
    [Yy])
      if [ "$EUID" -ne 0 ]; then
        echo -e "${CLR_RED}Failed to apply: please run as root.${CLR_RESET}"
        exit 1
      fi
      apply_fix
      show_status
      if check_compliance; then
        echo -e "${CLR_GREEN}Successfully applied${CLR_RESET}"
        exit 0
      else
        echo -e "${CLR_RED}Failed to apply${CLR_RESET}"
        exit 1
      fi
      ;;
    [Nn]) echo "Skipped."; exit 1 ;;
    [Cc]) echo "Canceled."; exit 2 ;;
    *) echo "Invalid input." ;;
  esac
done
