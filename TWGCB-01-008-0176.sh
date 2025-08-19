#!/bin/bash
# TWGCB-01-008-0176 (v3): Ensure rsyslog $FileCreateMode is 0640 or stricter
# Target: RHEL 8.5
# This script checks and (optionally) fixes $FileCreateMode in:
#   - /etc/rsyslog.conf
#   - /etc/rsyslog.d/90-google.conf
# It ensures a single normalized "$FileCreateMode 0640" per file (no duplicates).

set -u

FILES=(
  "/etc/rsyslog.conf"
  "/etc/rsyslog.d/90-google.conf"
)

# Colors
C_GREEN="\033[92m"
C_RED="\033[91m"
C_CYAN="\033[96m"
C_YELLOW="\033[93m"
C_OFF="\033[0m"

title="TWGCB-01-008-0176 (v3): Ensure rsyslog \$FileCreateMode is 0640 or stricter"
echo -e "$title\n"

# ---------- helpers ----------
oct_leq_0640() {
  # return 0 if given octal (e.g., 0640) <= 0640, else 1
  local v="${1:-}"
  # Must look like octal digits (optionally leading 0)
  [[ "$v" =~ ^0?[0-7]{3,4}$ ]] || return 1
  local dec_v=$((8#${v#0}))
  local dec_ref=$((8#0640))
  [[ $dec_v -le $dec_ref ]]
}

print_matches() {
  # Show all lines containing $FileCreateMode (commented or not), with "Line: N:" prefix
  local file="$1"
  if [[ -r "$file" ]]; then
    local out
    out=$(grep -nE '^\s*(#\s*)?\$FileCreateMode\b' "$file" 2>/dev/null | sed -E 's/^([0-9]+):/Line: \1:/')
    if [[ -n "$out" ]]; then
      echo "$out"
    else
      echo "(No matching setting found)"
    fi
  else
    if [[ -e "$file" ]]; then
      echo "(Permission denied)"
    else
      echo "(File not found)"
    fi
  fi
}

effective_mode_in_file() {
  # Print the last active (non-commented) $FileCreateMode value in a file; empty if none
  local file="$1"
  [[ -r "$file" ]] || { echo ""; return 0; }
  awk '
    BEGIN{val=""}
    /^[[:space:]]*#/ { next }  # skip commented lines
    /^[[:space:]]*\$FileCreateMode[[:space:]]+/ {
      # capture numeric token after key
      for (i=2;i<=NF;i++) {
        if ($i ~ /^[0-7]+$/) { val=$i }
      }
    }
    END{ print val }
  ' "$file"
}

file_is_compliant() {
  # returns 0 if file exists and last active mode is <= 0640
  # returns 1 otherwise (including no active setting)
  local file="$1"
  [[ -r "$file" ]] || return 1
  local mode
  mode="$(effective_mode_in_file "$file")"
  [[ -n "$mode" ]] && oct_leq_0640 "$mode"
}

normalize_file() {
  # Remove all existing $FileCreateMode lines, append a single compliant one
  # Return 0 on success, 1 on failure
  local file="$1"
  # Ensure the directory exists and the file is at least creatable if missing
  if [[ -e "$file" && ! -w "$file" ]]; then
    return 1
  fi
  # If file doesn't exist, try to create it
  if [[ ! -e "$file" ]]; then
    touch "$file" 2>/dev/null || return 1
  fi
  # Remove all existing lines (commented or not) with $FileCreateMode
  if ! sed -ri '/^[[:space:]]*(#\s*)?\$FileCreateMode[[:space:]]+/d' "$file" 2>/dev/null; then
    return 1
  fi
  # Append the compliant setting
  echo '$FileCreateMode 0640' >> "$file" || return 1
  return 0
}

all_files_status() {
  local any_noncompliant=0
  for f in "${FILES[@]}"; do
    if ! file_is_compliant "$f"; then
      any_noncompliant=1
      break
    fi
  done
  return $any_noncompliant
}

# ---------- Check phase ----------
echo -e "${C_CYAN}Checking files:${C_OFF}"
for f in "${FILES[@]}"; do
  echo "  - $f"
done
echo

echo "Check results:"
for f in "${FILES[@]}"; do
  echo "${f}:"
  print_matches "$f"
done
echo

if all_files_status; then
  echo -e "${C_GREEN}Compliant:${C_OFF} \$FileCreateMode is 0640 or stricter in all target files."
  exit 0
else
  echo -e "${C_RED}Non-compliant:${C_OFF} \$FileCreateMode is missing or too permissive in one or more files."
fi

# ---------- Prompt ----------
while true; do
  echo -n "Apply fix now (set \$FileCreateMode to 0640 and remove duplicates)? [Y]es / [N]o / [C]ancel: "
  read -r ans
  case "${ans:-}" in
    Y|y)
      break
      ;;
    N|n)
      echo "Skipped."
      exit 1
      ;;
    C|c)
      echo "Canceled."
      exit 2
      ;;
    *)
      echo "Invalid input."
      ;;
  esac
done

# ---------- Apply phase ----------
apply_failed=0
for f in "${FILES[@]}"; do
  if ! normalize_file "$f"; then
    echo -e "${C_RED}Failed to update:${C_OFF} $f"
    apply_failed=1
  fi
done

if [[ $apply_failed -eq 0 ]]; then
  if systemctl restart rsyslog 2>/dev/null; then
    :
  else
    echo -e "${C_RED}Failed to restart rsyslog.${C_OFF}"
    apply_failed=1
  fi
fi

# Re-check after apply
echo
echo -e "${C_CYAN}Re-checking after apply...${C_OFF}"
echo
echo "Check results:"
for f in "${FILES[@]}"; do
  echo "${f}:"
  print_matches "$f"
done
echo

if [[ $apply_failed -eq 0 ]] && all_files_status; then
  echo -e "${C_GREEN}Successfully applied.${C_OFF}"
  exit 0
else
  echo -e "${C_RED}Failed to apply.${C_OFF}"
  exit 3
fi
