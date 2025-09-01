#!/bin/bash
# TWGCB-01-008-0155: Audit unsuccessful unauthorized file access (RHEL 8.5)
# Monitors failed attempts to create/open/truncate files by real users (auid>=UID_MIN) excluding daemon (auid=4294967295).
# Required rules (baseline):
#   -a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EACCES -F auid>=UID_MIN -F auid!=4294967295 -k access
#   -a always,exit -F arch=b32 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EACCES -F auid>=UID_MIN -F auid!=4294967295 -k access
#   -a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EPERM  -F auid>=UID_MIN -F auid!=4294967295 -k access
#   -a always,exit -F arch=b32 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EPERM  -F auid>=UID_MIN -F auid!=4294967295 -k access
# Behavior:
#   - Detects UID_MIN from /etc/login.defs (fallback 1000)
#   - Checks /etc/audit/rules.d/access.rules for all four rules (b64/b32 × EACCES/EPERM)
#   - Prints matching lines with 'Line: ' prefixed numbers
#   - Interactively appends any missing rules and reloads via 'augenrules --load'
#   - If auditd is immutable (enabled=2), writes rules and exits 0 with Pending (reboot required)
# Notes:
#   - No Chinese in code.

set -u -o pipefail

# Colors (bright)
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; RESET="\e[0m"

ITEM_ID="TWGCB-01-008-0155"
TITLE="Record unsuccessful unauthorized file access (audit rules)"
RULES_DIR="/etc/audit/rules.d"
RULES_FILE="${RULES_DIR}/access.rules"

# Must be root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}This script must run as root (try: sudo $0).${RESET}"
  exit 1
fi

# Determine UID_MIN (fallback 1000)
UID_MIN="$(awk '/^\s*UID_MIN/{print $2}' /etc/login.defs 2>/dev/null | head -n1)"
if ! [[ "$UID_MIN" =~ ^[0-9]+$ ]]; then UID_MIN=1000; fi

REQ_LINES=(
  "-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EACCES -F auid>=${UID_MIN} -F auid!=4294967295 -k access"
  "-a always,exit -F arch=b32 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EACCES -F auid>=${UID_MIN} -F auid!=4294967295 -k access"
  "-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EPERM  -F auid>=${UID_MIN} -F auid!=4294967295 -k access"
  "-a always,exit -F arch=b32 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EPERM  -F auid>=${UID_MIN} -F auid!=4294967295 -k access"
)

echo -e "${CYAN}${ITEM_ID}: ${TITLE}${RESET}"
echo
echo "Checking audit rules in ${RULES_FILE}..."
echo "Check results:"

# --- helpers ---------------------------------------------------------------

candidate_grep() {
  # $1=file, $2=arch(b64/b32), $3=exit (EACCES|EPERM)
  local file="$1" arch="$2" exitc="$3"
  grep -nE "^[[:space:]]*-a[[:space:]]+always,exit\b.*arch=${arch}\b.*exit=-${exitc}\b.*-k[[:space:]]*access([[:space:]]|$)" "$file" 2>/dev/null
}

line_has_all_tokens() {
  # $1=line content
  local line="$1"
  # Required syscalls
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-S[[:space:]]+creat([[:space:]]|$)'     || return 1
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-S[[:space:]]+open([[:space:]]|$)'      || return 1
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-S[[:space:]]+openat([[:space:]]|$)'    || return 1
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-S[[:space:]]+truncate([[:space:]]|$)'  || return 1
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-S[[:space:]]+ftruncate([[:space:]]|$)' || return 1
  # AUID filters
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-F[[:space:]]+auid>='"$UID_MIN"'([[:space:]]|$)'       || return 1
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-F[[:space:]]+auid!=4294967295([[:space:]]|$)'         || return 1
  return 0
}

show_matching_rule() {
  # $1=file, $2=arch, $3=exit -> prints "Line: n: <line>" or "(No matching line found)"
  local file="$1" arch="$2" exitc="$3"
  if [[ -r "$file" ]]; then
    local found=0
    while IFS= read -r cand; do
      local num="${cand%%:*}"
      local content="${cand#*:}"
      if line_has_all_tokens "$content"; then
        echo "Line: ${num}: ${content}"
        found=1
      fi
    done < <(candidate_grep "$file" "$arch" "$exitc")
    if [[ $found -eq 0 ]]; then
      echo "(No matching line found)"
    fi
  else
    if [[ -e "$file" ]]; then
      echo "(Permission denied reading ${file})"
    else
      echo "(File not found: ${file})"
    fi
  fi
}

rule_exists() {
  # $1=file, $2=arch, $3=exit -> returns 0 if a matching line exists with all tokens
  local file="$1" arch="$2" exitc="$3"
  if [[ ! -r "$file" ]]; then return 1; fi
  while IFS= read -r cand; do
    local content="${cand#*:}"
    if line_has_all_tokens "$content"; then
      return 0
    fi
  done < <(candidate_grep "$file" "$arch" "$exitc")
  return 1
}

# --- display current state -------------------------------------------------

if [[ -e "$RULES_FILE" ]]; then
  echo "Required: ${REQ_LINES[0]}"; show_matching_rule "$RULES_FILE" "b64" "EACCES"
  echo "Required: ${REQ_LINES[1]}"; show_matching_rule "$RULES_FILE" "b32" "EACCES"
  echo "Required: ${REQ_LINES[2]}"; show_matching_rule "$RULES_FILE" "b64" "EPERM"
  echo "Required: ${REQ_LINES[3]}"; show_matching_rule "$RULES_FILE" "b32" "EPERM"
else
  for i in 0 1 2 3; do
    echo "Required: ${REQ_LINES[$i]}"
    echo "(File not found: ${RULES_FILE})"
  done
fi
echo

missing=()
if ! [[ -f "$RULES_FILE" ]]; then
  missing+=(0 1 2 3)
else
  rule_exists "$RULES_FILE" "b64" "EACCES" || missing+=(0)
  rule_exists "$RULES_FILE" "b32" "EACCES" || missing+=(1)
  rule_exists "$RULES_FILE" "b64" "EPERM"  || missing+=(2)
  rule_exists "$RULES_FILE" "b32" "EPERM"  || missing+=(3)
fi

if [[ ${#missing[@]} -eq 0 ]]; then
  echo -e "${GREEN}Compliant:${RESET} All required access-failure audit rules are present."
  exit 0
fi

echo -e "${RED}Non-compliant:${RESET} Missing ${#missing[@]} required rule(s):"
for idx in "${missing[@]}"; do
  echo "  - ${REQ_LINES[$idx]}"
done

echo
echo -n "Apply fix now (append missing rules to ${RULES_FILE} and reload)? [Y]es / [N]o / [C]ancel: "
read -rsn1 ans; echo
case "$ans" in
  [Yy]) ;;
  [Nn]) echo "Skipped."; exit 0 ;;
  [Cc]) echo "Canceled."; exit 2 ;;
  *)    echo "Invalid choice. Aborted."; exit 2 ;;
esac

# --- apply ----------------------------------------------------------------

if [[ ! -d "$RULES_DIR" ]]; then
  echo -e "${RED}Failed to apply:${RESET} ${RULES_DIR} does not exist."
  exit 1
fi

# Create file if missing
[[ -e "$RULES_FILE" ]] || touch "$RULES_FILE" 2>/dev/null || {
  echo -e "${RED}Failed to apply:${RESET} Unable to create ${RULES_FILE} (permission denied?)."
  exit 1
}

# Append missing lines
{
  echo
  echo "# ${ITEM_ID} — audit failed file access attempts (UID_MIN=${UID_MIN})"
  for idx in "${missing[@]}"; do
    echo "${REQ_LINES[$idx]}"
  done
} >> "$RULES_FILE" 2>/dev/null || {
  echo -e "${RED}Failed to apply:${RESET} Permission denied writing ${RULES_FILE}."
  exit 1
}

# Try to reload
if ! command -v augenrules >/dev/null 2>&1; then
  echo -e "${RED}Failed to apply:${RESET} 'augenrules' not found."
  exit 1
fi

if augenrules --load >/dev/null 2>&1; then
  echo "Re-checking ${RULES_FILE}..."
  echo "Required: ${REQ_LINES[0]}"; show_matching_rule "$RULES_FILE" "b64" "EACCES"
  echo "Required: ${REQ_LINES[1]}"; show_matching_rule "$RULES_FILE" "b32" "EACCES"
  echo "Required: ${REQ_LINES[2]}"; show_matching_rule "$RULES_FILE" "b64" "EPERM"
  echo "Required: ${REQ_LINES[3]}"; show_matching_rule "$RULES_FILE" "b32" "EPERM"
  echo -e "${GREEN}Successfully applied.${RESET}"
  exit 0
else
  enabled_val=""
  if command -v auditctl >/dev/null 2>&1; then
    enabled_val="$(auditctl -s 2>/dev/null | awk '/^enabled/ {print $2}' | sed 's/[^0-9]//g')"
  fi
  if [[ "${enabled_val:-}" == "2" ]]; then
    echo -e "${YELLOW}Pending:${RESET} auditd is immutable (enabled=2)."
    echo "Rules were written to ${RULES_FILE} and will load on next boot if '-e 2' loads last."
    echo "Tip: keep '-e 2' only in /etc/audit/rules.d/99-finalize.rules."
    exit 0
  fi
  echo -e "${RED}Failed to apply:${RESET} Could not load rules via augenrules."
  exit 1
fi
