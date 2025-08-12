#!/bin/bash
# TWGCB-01-008-0222: Enforce password history (remember >= 3)
# Platform: RHEL 8.5
# Policy:
#   - Ensure PAM password stack enforces password history with remember=3 or higher.
#   - Typical modules: pam_pwhistory.so (preferred) or pam_unix.so
#   - Managed via authselect; if unavailable, edit effective /etc/pam.d files directly.
# Notes:
#   - Uses bright green/red messages.
#   - Prompts [Y]es / [N]o / [C]ancel before applying.
#   - Re-checks after applying.
#   - Shows lines with 'Line: <n>:' and file path.
#   - No Chinese in code.

set -o pipefail

PAM_FILES=( "/etc/pam.d/system-auth" "/etc/pam.d/password-auth" )
PROFILE_NAME="twgcb-remember"  # custom authselect profile name

REQUIRED_REMEMBER=3

# Colors (bright)
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
RESET="\e[0m]"

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
    # Show pam_pwhistory or pam_unix password lines with file path + number prefix
    if ! grep -n -E '^[[:space:]]*password[[:space:]]+(sufficient|required|requisite)[[:space:]]+(pam_pwhistory|pam_unix)\.so' "$f" 2>/dev/null \
        | sed "s#^\\([0-9]\\+\\):#${f}: Line: \\1:#"; then
      echo "$f: (No matching password line found)"
    fi
  done
}

has_remember_ge() {
  # Args: file, min_value
  # Return 0 if file has an active pam_pwhistory.so or pam_unix.so 'password' line with remember>=min_value; else 1.
  local file="$1" minv="$2"
  awk -v MIN="$minv" '
    function is_comment(l){gsub(/^[ \t]+/,"",l); return l ~ /^#/}
    function get_param(l,key,   m){ if (match(l, key"=[^ \t#]+")) { return substr(l, RSTART+RLENGTH - length(substr(l,RSTART+RLENGTH)), RLENGTH - length(key"=")) } return "" }
    {
      line=$0
      if (is_comment(line)) next
      if (line ~ /^[ \t]*password[ \t]+(sufficient|required|requisite)[ \t]+pam_(pwhistory|unix)\.so/) {
        if (match(line, /(^|[ \t])remember=[^ \t#]+/)) {
          val = line
          sub(/.*(^|[ \t])remember=/, "", val)
          sub(/[ \t#].*$/, "", val)
          if (val+0 >= MIN) { ok=1 }
        }
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

apply_pam_remember_edit_file() {
  # Args: file
  # Ensure remember=REQUIRED_REMEMBER on pam_pwhistory.so or pam_unix.so password lines
  local file="$1"
  [ ! -w "$file" ] && return 1
  awk -v REQ="$REQUIRED_REMEMBER" '
    function is_comment(l){gsub(/^[ \t]+/,"",l); return l ~ /^#/}
    function add_or_fix_remember(l) {
      # Append before inline comment if present
      if (l ~ /(^|[ \t])remember=[^ \t#]+/) {
        gsub(/remember=[^ \t#]+/, "remember="REQ, l)
        return l
      } else {
        if (match(l, /[ \t]*#/)) {
          pre=substr(l,1,RSTART-1); post=substr(l,RSTART)
          return pre " remember=" REQ post
        } else {
          return l " remember=" REQ
        }
      }
    }
    {
      line=$0
      if (!is_comment(line) && line ~ /^[ \t]*password[ \t]+(sufficient|required|requisite)[ \t]+pam_(pwhistory|unix)\.so/) {
        print add_or_fix_remember(line)
      } else {
        print line
      }
    }
  ' "$file" > "${file}.twgcb.tmp" && mv "${file}.twgcb.tmp" "$file"
}

apply_with_authselect() {
  if ! command -v authselect >/dev/null 2>&1; then
    return 2
  fi
  local current_profile selpath
  current_profile="$(authselect current 2>/dev/null | awk 'NR==1{print $3}')"

  if [[ "$current_profile" != custom/* ]]; then
    if ! authselect create-profile "$PROFILE_NAME" -b sssd --symlink-meta >/dev/null 2>&1; then
      return 1
    fi
    if ! authselect select "custom/$PROFILE_NAME" with-sudo with-faillock without-nullok >/dev/null 2>&1; then
      return 1
    fi
    current_profile="custom/$PROFILE_NAME"
  fi

  selpath="/etc/authselect/$current_profile"
  local failed=0
  for fn in system-auth password-auth; do
    local f="$selpath/$fn"
    if [ ! -w "$f" ]; then
      failed=1
      continue
    fi
    apply_pam_remember_edit_file "$f" || failed=1
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
  if [ $rc -eq 2 ]; then
    # Fallback: edit effective PAM files directly
    local failed=0
    for f in "${PAM_FILES[@]}"; do
      if ! apply_pam_remember_edit_file "$f"; then
        failed=1
      fi
    done
    [ $failed -eq 1 ] && echo -e "${RED}Failed to apply${RESET}" && return 1
  elif [ $rc -ne 0 ]; then
    echo -e "${RED}Failed to apply${RESET}"
    return 1
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
      echo -n "Apply fix now (set remember=${REQUIRED_REMEMBER} via authselect or PAM files)? [Y]es / [N]o / [C]ancel: "
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
