#!/bin/bash
# TWGCB-01-008-0151: Audit date/time change events (RHEL 8.5)
# Baseline requires auditing:
#   - Syscalls: adjtimex, settimeofday (b64 & b32; b32 also includes stime), clock_settime (b64 & b32) => key time-change
#   - Watch: /etc/localtime -p wa -k time-change
# Behavior:
#   - Checks /etc/audit/rules.d/time-change.rules for all rules
#   - Prints matching lines with 'Line: ' prefixed numbers
#   - Interactively appends missing rules and reloads via 'augenrules --load'
#   - If auditd is immutable (enabled=2), writes rules and exits 0 with Pending (reboot required)
# Notes:
#   - No Chinese in code.

set -u -o pipefail

# Colors (bright)
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; RESET="\e[0m"

ITEM_ID="TWGCB-01-008-0151"
TITLE="Record date/time change events (audit rules)"
RULES_DIR="/etc/audit/rules.d"
RULES_FILE="${RULES_DIR}/time-change.rules"

REQ_LINES=(
  "-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time-change"
  "-a always,exit -F arch=b32 -S adjtimex -S settimeofday -S stime -k time-change"
  "-a always,exit -F arch=b64 -S clock_settime -k time-change"
  "-a always,exit -F arch=b32 -S clock_settime -k time-change"
  "-w /etc/localtime -p wa -k time-change"
)

echo -e "${CYAN}${ITEM_ID}: ${TITLE}${RESET}"
echo
echo "Checking audit rules in ${RULES_FILE}..."
echo "Check results:"

# --- helpers ---------------------------------------------------------------

# Candidate grep for syscall rules by arch + key
candidate_grep_sys() {
  # $1=file, $2=arch(b64/b32)
  local file="$1" arch="$2"
  grep -nE "^[[:space:]]*-a[[:space:]]+always,exit\b.*arch=${arch}\b.*-k[[:space:]]*time-change([[:space:]]|$)" "$file" 2>/dev/null
}

# Verify the syscall rule line has all listed -S tokens
line_has_syscalls() {
  # $1=line content, $2="space-separated syscalls"
  local line="$1" need="$2"
  for sc in $need; do
    printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-S[[:space:]]+'"${sc}"'([[:space:]]|$)' || return 1
  done
  return 0
}

# Show matches for syscall rule per arch
show_match_sys() {
  # $1=file, $2=arch, $3="space-separated syscalls"
  local file="$1" arch="$2" need="$3"
  if [[ -r "$file" ]]; then
    local found=0
    while IFS= read -r cand; do
      local num="${cand%%:*}"
      local content="${cand#*:}"
      if line_has_syscalls "$content" "$need"; then
        echo "Line: ${num}: ${content}"
        found=1
      fi
    done < <(candidate_grep_sys "$file" "$arch")
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

# Determine if syscall rule exists for given arch and set of syscalls
rule_exists_sys() {
  # $1=file, $2=arch, $3="space-separated syscalls" -> returns 0 if match exists
  local file="$1" arch="$2" need="$3"
  if [[ ! -r "$file" ]]; then return 1; fi
  while IFS= read -r cand; do
    local content="${cand#*:}"
    if line_has_syscalls "$content" "$need"; then
      return 0
    fi
  done < <(candidate_grep_sys "$file" "$arch")
  return 1
}

# Tolerant regex for -w PATH ... -p containing w and a ... -k time-change
regex_watch() {
  # $1=escaped path
  local p="$1"
  printf '^[[:space:]]*-w[[:space:]]+%s([[:space:]]+.*)?-p[[:space:]]*[rwxad]*w[rwxad]*a[rwxad]*([[:space:]]+.*)?-k[[:space:]]*time-change([[:space:]]|$)' "$p"
}

# Show match for a watch path
show_match_watch() {
  # $1=file, $2=path
  local file="$1" pat="$2"
  local escaped
  escaped=$(printf '%s\n' "$pat" | sed -E 's/[][\.^$*+?(){}|/]/\\&/g')
  local rgx
  rgx="$(regex_watch "$escaped")"
  if [[ -r "$file" ]]; then
    local out
    out="$(grep -nE "$rgx" "$file" 2>/dev/null | sed -E 's/^/Line: /')"
    if [[ -n "$out" ]]; then
      echo "$out"
    else
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

# Check existence of a watch path rule
rule_exists_watch() {
  # $1=file, $2=path
  local file="$1" pat="$2"
  local escaped rgx
  escaped=$(printf '%s\n' "$pat" | sed -E 's/[][\.^$*+?(){}|/]/\\&/g')
  rgx="$(regex_watch "$escaped")"
  if [[ ! -r "$file" ]]; then return 1; fi
  grep -Eq "$rgx" "$file"
}

# syscall sets
SYSC_TIME_B64="adjtimex settimeofday"
SYSC_TIME_B32="adjtimex settimeofday stime"
SYSC_CLOCK="clock_settime"

# --- display current state -------------------------------------------------

if [[ -e "$RULES_FILE" ]]; then
  echo "Required: ${REQ_LINES[0]}"; show_match_sys   "$RULES_FILE" "b64" "$SYSC_TIME_B64"
  echo "Required: ${REQ_LINES[1]}"; show_match_sys   "$RULES_FILE" "b32" "$SYSC_TIME_B32"
  echo "Required: ${REQ_LINES[2]}"; show_match_sys   "$RULES_FILE" "b64" "$SYSC_CLOCK"
  echo "Required: ${REQ_LINES[3]}"; show_match_sys   "$RULES_FILE" "b32" "$SYSC_CLOCK"
  echo "Required: ${REQ_LINES[4]}"; show_match_watch "$RULES_FILE" "/etc/localtime"
else
  for i in {0..4}; do
    echo "Required: ${REQ_LINES[$i]}"
  done
  echo "(File not found: ${RULES_FILE})"
fi
echo

missing_idx=()
if [[ -f "$RULES_FILE" ]]; then
  rule_exists_sys   "$RULES_FILE" "b64" "$SYSC_TIME_B64" || missing_idx+=(0)
  rule_exists_sys   "$RULES_FILE" "b32" "$SYSC_TIME_B32" || missing_idx+=(1)
  rule_exists_sys   "$RULES_FILE" "b64" "$SYSC_CLOCK"     || missing_idx+=(2)
  rule_exists_sys   "$RULES_FILE" "b32" "$SYSC_CLOCK"     || missing_idx+=(3)
  rule_exists_watch "$RULES_FILE" "/etc/localtime"        || missing_idx+=(4)
else
  missing_idx+=(0 1 2 3 4)
fi

if [[ ${#missing_idx[@]} -eq 0 ]]; then
  echo -e "${GREEN}Compliant:${RESET} All time-change audit rules are present."
  exit 0
fi

echo -e "${RED}Non-compliant:${RESET} Missing ${#missing_idx[@]} required rule(s):"
for idx in "${missing_idx[@]}"; do
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
  echo "# ${ITEM_ID} — audit date/time change events"
  for idx in "${missing_idx[@]}"; do
    echo "${REQ_LINES[$idx]}"
  done
} >> "$RULES_FILE" 2>/dev/null || {
  echo -e "${RED}Failed to apply:${RESET} Permission denied writing ${RULES_FILE}."
  exit 1
}

# Try to reload rules
if ! command -v augenrules >/dev/null 2>&1; then
  echo -e "${RED}Failed to apply:${RESET} 'augenrules' not found."
  exit 1
fi

if augenrules --load >/dev/null 2>&1; then
  echo "Re-checking ${RULES_FILE}..."
  echo "Required: ${REQ_LINES[0]}"; show_match_sys   "$RULES_FILE" "b64" "$SYSC_TIME_B64"
  echo "Required: ${REQ_LINES[1]}"; show_match_sys   "$RULES_FILE" "b32" "$SYSC_TIME_B32"
  echo "Required: ${REQ_LINES[2]}"; show_match_sys   "$RULES_FILE" "b64" "$SYSC_CLOCK"
  echo "Required: ${REQ_LINES[3]}"; show_match_sys   "$RULES_FILE" "b32" "$SYSC_CLOCK"
  echo "Required: ${REQ_LINES[4]}"; show_match_watch "$RULES_FILE" "/etc/localtime"
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
