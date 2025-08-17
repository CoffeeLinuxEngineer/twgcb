#!/bin/bash
# TWGCB-01-008-0222: Enforce password history (remember >= 3)
# Platform: RHEL 8.5
# Notes:
#   - Prefer pam_pwhistory.so with remember>=3.
#   - Uses authselect when available; falls back to editing /etc/pam.d files.
#   - Inserts a pam_pwhistory line if missing (before pam_unix password line).
#   - Bright green/red messages, prompts, re-checks; prints "Line: N:" with file path.
#   - No Chinese in code.

set -o pipefail

PAM_FILES=( "/etc/pam.d/system-auth" "/etc/pam.d/password-auth" )
PROFILE_NAME="twgcb-remember"
REQUIRED_REMEMBER=3

# Colors (bright)
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
RESET="\e[0m"

print_header() {
  echo "TWGCB-01-008-0222: Enforce password history (remember >= ${REQUIRED_REMEMBER})"
  echo
}

show_matches() {
  echo "Checking files:"
  for f in "${PAM_FILES[@]}"; do
    echo "  - $f"
  done
  echo
  echo "Check results:"
  for f in "${PAM_FILES[@]}"; do
    if [ ! -e "$f" ]; then
      echo "$f: (File not found)"
      continue
    fi
    if [ ! -r "$f" ]; then
      echo "$f: (Permission denied)"
      continue
    fi
    # Show password lines for pam_pwhistory or pam_unix
    if ! grep -n -E '^[[:space:]]*password[[:space:]]+(sufficient|required|requisite)[[:space:]]+(pam_pwhistory|pam_unix)\.so' "$f" 2>/dev/null \
        | sed "s#^\\([0-9]\\+\\):#${f}: Line: \\1:#"; then
      echo "$f: (No matching password line found)"
    fi
  done
}

has_remember_ge() {
  # Args: file, min_value
  # Return 0 if file has an active pam_pwhistory.so (preferred) OR pam_unix.so 'password' line with remember>=min_value; else 1.
  local file="$1" minv="$2"
  awk -v MIN="$minv" '
    function ltrim(s){sub(/^[ \t]+/, "", s); return s}
    {
      line=$0
      if (ltrim(line) ~ /^#/) next
      if (line ~ /^[ \t]*password[ \t]+(sufficient|required|requisite)[ \t]+pam_(pwhistory|unix)\.so/) {
        # extract remember value if present
        if (match(line, /(^|[ \t])remember=[0-9]+/)) {
          v=substr(line, RSTART, RLENGTH); sub(/.*=/, "", v)
          if (v+0 >= MIN) { ok=1 }
        }
        # treat presence of pam_pwhistory without remember as non-compliant
      }
    }
    END { exit(ok?0:1) }
  ' "$file"
}

check_compliance() {
  local any_perm=0
  local ok_all=1
  for f in "${PAM_FILES[@]}"; do
    if [ ! -r "$f" ]; then
      any_perm=1
      continue
    fi
    if ! has_remember_ge "$f" "$REQUIRED_REMEMBER"; then
      ok_all=0
    fi
  done
  [ $any_perm -eq 1 ] && return 2
  [ $ok_all -eq 1 ] && return 0 || return 1
}

ensure_pwhistory_remember_in_file() {
  # Ensure pam_pwhistory.so line exists with remember>=REQUIRED_REMEMBER (and use_authtok), inserting before pam_unix if needed.
  local file="$1"
  [ ! -w "$file" ] && return 1

  # If pam_pwhistory line exists, fix/append remember=
  if grep -Eq '^[[:space:]]*password[[:space:]]+(sufficient|required|requisite)[[:space:]]+pam_pwhistory\.so' "$file"; then
    awk -v REQ="$REQUIRED_REMEMBER" '
      function ltrim(s){sub(/^[ \t]+/, "", s); return s}
      function add_or_fix(line){
        if (line ~ /(^|[ \t])remember=[0-9]+/) {
          gsub(/remember=[0-9]+/, "remember=" REQ, line)
        } else {
          if (match(line, /[ \t]*#/)) {
            pre=substr(line,1,RSTART-1); post=substr(line,RSTART)
            line=pre " remember=" REQ post
          } else {
            line=line " remember=" REQ
          }
        }
        return line
      }
      {
        orig=$0
        if (ltrim(orig) !~ /^#/ && orig ~ /^[ \t]*password[ \t]+(sufficient|required|requisite)[ \t]+pam_pwhistory\.so/) {
          print add_or_fix(orig)
        } else {
          print orig
        }
      }
    ' "$file" > "${file}.twgcb.tmp" && mv "${file}.twgcb.tmp" "$file" || return 1
  else
    # Insert a new pam_pwhistory line before the first pam_unix password line; else append at end.
    if grep -Eq '^[[:space:]]*password[[:space:]]+(sufficient|required|requisite)[[:space:]]+pam_unix\.so' "$file"; then
      sed -ri '/^[[:space:]]*password[[:space:]]+(sufficient|required|requisite)[[:space:]]+pam_unix\.so/ i password    requisite    pam_pwhistory.so use_authtok remember='"$REQUIRED_REMEMBER" "$file" || return 1
    else
      echo "password    requisite    pam_pwhistory.so use_authtok remember=${REQUIRED_REMEMBER}" >> "$file" || return 1
    fi
  fi
  return 0
}

apply_with_authselect() {
  if ! command -v authselect >/dev/null 2>&1; then
    return 2
  fi
  local current_profile selpath
  current_profile="$(authselect current 2>/dev/null | awk -F': ' '/^Profile ID/ {print $2}')"
  if [ -z "$current_profile" ]; then
    # nothing selected; select base first
    if ! authselect select sssd >/dev/null 2>&1; then
      return 1
    fi
    current_profile="sssd"
  fi

  if [[ "$current_profile" != custom/* ]]; then
    if ! authselect create-profile "$PROFILE_NAME" -b "$current_profile" --symlink-meta >/dev/null 2>&1; then
      return 1
    fi
    if ! authselect select "custom/$PROFILE_NAME" >/dev/null 2>&1; then
      return 1
    fi
  fi

  selpath="/etc/authselect/$(authselect current | awk -F': ' '/^Profile ID/ {print $2}')"
  local failed=0
  for fn in system-auth password-auth; do
    local f="$selpath/$fn"
    if ! ensure_pwhistory_remember_in_file "$f"; then
      failed=1
    fi
  done

  if [ $failed -eq 1 ]; then
    return 1
  fi

  authselect apply-changes >/dev/null 2>&1 || return 1
  return 0
}

apply_fix() {
  local rc
  apply_with_authselect
  rc=$?
  if [ $rc -ne 0 ]; then
    # Fallback: edit effective PAM files directly
    local failed=0
    for f in "${PAM_FILES[@]}"; do
      if ! ensure_pwhistory_remember_in_file "$f"; then
        failed=1
      fi
    done
    if [ $failed -eq 1 ]; then
      echo -e "${RED}Failed to apply${RESET}"
      return 1
    fi
  fi

  # Re-check
  if check_compliance; then
    echo -e "${GREEN}Successfully applied${RESET}"
    return 0
  else
    echo -e "${RED}Failed to apply${RESET}"
    return 1
  fi
}

main() {
  print_header
  show_matches
  echo

  check_compliance
  rc=$?

  if [ $rc -eq 0 ]; then
    echo -e "${GREEN}Compliant: remember >= ${REQUIRED_REMEMBER} is enforced in system-auth and password-auth.${RESET}"
    exit 0
  elif [ $rc -eq 2 ]; then
    echo -e "${RED}Non-compliant: Unable to verify (permission denied).${RESET}"
    exit 1
  else
    echo -e "${RED}Non-compliant: remember >= ${REQUIRED_REMEMBER} not enforced across PAM files.${RESET}"
    while true; do
      echo -n "Apply fix now (enforce pam_pwhistory remember=${REQUIRED_REMEMBER})? [Y]es / [N]o / [C]ancel: "
      read -rsn1 key
      echo
      case "$key" in
        [Yy])
          apply_fix
          exit $?
          ;;
        [Nn])
          echo "Skipped."
          exit 1
          ;;
        [Cc])
          echo "Canceled."
          exit 2
          ;;
        *)
          echo "Invalid input."
          ;;
      esac
    done
  fi
}

main
