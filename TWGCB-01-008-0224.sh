#!/bin/bash
# TWGCB-01-008-0224: Ensure password hashing algorithm is SHA512
# Platform: RHEL 8.5
# Policy requires:
#   - /etc/libuser.conf: crypt_style = sha512
#   - /etc/login.defs : ENCRYPT_METHOD SHA512
#   - PAM (system-auth, password-auth): pam_unix.so line includes 'sha512'
# Implementation notes:
#   - Uses authselect to manage PAM profiles. If not on a custom profile, creates/selects custom 'twgcb-sha512'
#     with features: with-sudo with-faillock without-nullok, then enforces 'sha512' in pam_unix.so lines.
#   - Uses bright green/red messages, prompts [Y]es / [N]o / [C]ancel, prints line numbers as 'Line: N:'.
#   - No Chinese in code.

set -o pipefail

LIBUSER="/etc/libuser.conf"
LOGINDEFS="/etc/login.defs"
PAM_FILES=( "/etc/pam.d/system-auth" "/etc/pam.d/password-auth" )

PROFILE_NAME="twgcb-sha512"   # custom authselect profile name to use/create

# Colors (bright)
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
RESET="\e[0m"

print_header() {
  echo "TWGCB-01-008-0224: Password hashing algorithm = SHA512"
  echo
}

show_matches() {
  echo "Checking files:"
  echo "  - $LIBUSER"
  echo "  - $LOGINDEFS"
  for f in "${PAM_FILES[@]}"; do
    echo "  - $f"
  done
  echo
  echo "Check results:"

  # /etc/libuser.conf lines (with file path prefix)
  if [ ! -e "$LIBUSER" ]; then
    echo "$LIBUSER: (File not found)"
  elif [ ! -r "$LIBUSER" ]; then
    echo "$LIBUSER: (Permission denied)"
  else
    grep -n -E 'crypt_style' "$LIBUSER" 2>/dev/null | sed "s#^\\([0-9]\\+\\):#${LIBUSER}: Line: \\1:#" || echo "$LIBUSER: (No matching line found)"
  fi

  # /etc/login.defs lines (with file path prefix)
  if [ ! -e "$LOGINDEFS" ]; then
    echo "$LOGINDEFS: (File not found)"
  elif [ ! -r "$LOGINDEFS" ]; then
    echo "$LOGINDEFS: (Permission denied)"
  else
    grep -n -E 'ENCRYPT_METHOD' "$LOGINDEFS" 2>/dev/null | sed "s#^\\([0-9]\\+\\):#${LOGINDEFS}: Line: \\1:#" || echo "$LOGINDEFS: (No matching line found)"
  fi

  # PAM files (effective) — already include file path prefix
  for f in "${PAM_FILES[@]}"; do
    if [ ! -e "$f" ]; then
      echo "$f: (File not found)"
      continue
    fi
    if [ ! -r "$f" ]; then
      echo "$f: (Permission denied)"
      continue
    fi
    if ! grep -n -E '^[[:space:]]*password[[:space:]]+sufficient[[:space:]]+pam_unix\.so' "$f" 2>/dev/null | sed "s#^\\([0-9]\\+\\):#${f}: Line: \\1:#"; then
      echo "$f: (No pam_unix password line found)"
    fi
  done
}

active_crypt_style_ok() {
  if [ ! -e "$LIBUSER" ]; then
    return 1
  fi
  if [ ! -r "$LIBUSER" ]; then
    return 2
  fi
  awk '
    {
      s=$0
      sub(/^[ \t]+/, "", s)
      if (s ~ /^#/) next
      if (s ~ /^crypt_style[ \t]*=[ \t]*sha512([ \t].*)?$/) { found=1 }
    }
    END { exit (found?0:1) }
  ' "$LIBUSER"
}

active_encrypt_method_ok() {
  if [ ! -e "$LOGINDEFS" ]; then
    return 1
  fi
  if [ ! -r "$LOGINDEFS" ]; then
    return 2
  fi
  awk '
    {
      s=$0
      sub(/^[ \t]+/, "", s)
      if (s ~ /^#/) next
      if (s ~ /^ENCRYPT_METHOD[ \t]+SHA512([ \t].*)?$/) { found=1 }
    }
    END { exit (found?0:1) }
  ' "$LOGINDEFS"
}

pam_files_sha512_ok() {
  local any_perm=0
  local ok_all=1
  for f in "${PAM_FILES[@]}"; do
    if [ ! -r "$f" ]; then
      any_perm=1
      continue
    fi
    if ! grep -Eq '^[[:space:]]*password[[:space:]]+sufficient[[:space:]]+pam_unix\.so.*\bsha512\b' "$f"; then
      ok_all=0
    fi
  done
  [ $any_perm -eq 1 ] && return 2
  [ $ok_all -eq 1 ]
}

check_compliance() {
  active_crypt_style_ok; local c1=$?
  active_encrypt_method_ok; local c2=$?
  pam_files_sha512_ok; local c3=$?

  if [ $c1 -eq 2 ] || [ $c2 -eq 2 ] || [ $c3 -eq 2 ]; then
    return 2
  fi
  if [ $c1 -eq 0 ] && [ $c2 -eq 0 ] && [ $c3 -eq 0 ]; then
    return 0
  fi
  return 1
}

ensure_line_in_file_kv() {
  local file="$1" key_re="$2" desired="$3"
  if [ ! -e "$file" ] || [ ! -w "$file" ]; then
    return 1
  fi
  sed -ri "s/^[[:space:]]*(${key_re})[[:space:]]*(=.*|[[:space:]]+.*)$/\1 ${desired}/" "$file"
  if ! awk -v KEY="$key_re" '
      BEGIN{found=0}
      {
        s=$0; sub(/^[ \t]+/,"",s);
        if (s ~ /^#/) next;
        if (s ~ "^" KEY "[ \t]") { found=1 }
      }
      END{exit(found?0:1)}
    ' "$file"; then
    tail -c1 "$file" | read -r _ || echo >> "$file"
    if [[ "$key_re" == "ENCRYPT_METHOD" ]]; then
      echo "ENCRYPT_METHOD SHA512" >> "$file"
    elif [[ "$key_re" == "crypt_style" ]]; then
      echo "crypt_style = sha512" >> "$file"
    fi
  fi
  return 0
}

apply_pam_sha512_with_authselect() {
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
    if ! grep -Eq '^[[:space:]]*password[[:space:]]+sufficient[[:space:]]+pam_unix\.so.*\bsha512\b' "$f"; then
      sed -ri 's/^[[:space:]]*(password[[:space:]]+sufficient[[:space:]]+pam_unix\.so)(.*)$/\1\2 sha512/' "$f" || failed=1
    fi
  done

  if [ $failed -eq 1 ]; then
    return 1
  fi
  authselect apply-changes >/dev/null 2>&1 || return 1
  return 0
}

apply_fix() {
  local ok=0

  if [ ! -e "$LIBUSER" ]; then
    echo "$LIBUSER not found; creating minimal file."
    echo -e "[defaults]\ncrypt_style = sha512" > "$LIBUSER" 2>/dev/null || true
  fi
  if [ -w "$LIBUSER" ]; then
    ensure_line_in_file_kv "$LIBUSER" "crypt_style" "= sha512" || ok=1
  else
    ok=1
  fi

  if [ -w "$LOGINDEFS" ]; then
    ensure_line_in_file_kv "$LOGINDEFS" "ENCRYPT_METHOD" "SHA512" || ok=1
  else
    ok=1
  fi

  local pam_rc
  apply_pam_sha512_with_authselect
  pam_rc=$?
  if [ $pam_rc -eq 2 ]; then
    local failed=0
    for f in "${PAM_FILES[@]}"; do
      if [ -w "$f" ]; then
        if ! grep -Eq '^[[:space:]]*password[[:space:]]+sufficient[[:space:]]+pam_unix\.so.*\bsha512\b' "$f"; then
          sed -ri 's/^[[:space:]]*(password[[:space:]]+sufficient[[:space:]]+pam_unix\.so)(.*)$/\1\2 sha512/' "$f" || failed=1
        fi
      else
        failed=1
      fi
    done
    [ $failed -eq 1 ] && ok=1
  elif [ $pam_rc -ne 0 ]; then
    ok=1
  fi

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
    echo -e "${GREEN}Compliant: SHA512 is configured in libuser, login.defs, and PAM.${RESET}"
    exit 0
  elif [ $rc -eq 2 ]; then
    echo -e "${RED}Non-compliant: Unable to verify (permission denied reading one or more files).${RESET}"
    exit 1
  else
    echo -e "${RED}Non-compliant: SHA512 is not fully enforced across libuser, login.defs, and PAM.${RESET}"
    while true; do
      echo -n "Apply fix now (set crypt_style/login.defs and enforce sha512 in PAM)? [Y]es / [N]o / [C]ancel: "
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
