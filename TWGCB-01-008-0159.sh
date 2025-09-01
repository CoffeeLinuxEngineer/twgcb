#!/bin/bash
# TWGCB-01-008-0159: Audit file deletion/rename events (RHEL 8.5)
# Monitors unlink, unlinkat, rename, renameat, rmdir done by real users (auid>=UID_MIN) and not the daemon user (auid!=4294967295).
# Required rules:
#   -a always,exit -F arch=b64 -S unlink -S unlinkat -S rename -S renameat -S rmdir -F auid>=UID_MIN -F auid!=4294967295 -k delete
#   -a always,exit -F arch=b32 -S unlink -S unlinkat -S rename -S renameat -S rmdir -F auid>=UID_MIN -F auid!=4294967295 -k delete
# Behavior:
#   - Prints matching lines with "Line: " prefixed line numbers.
#   - If auditd is immutable (enabled=2), treats as Pending after writing rules (reboot required).
#   - No Chinese in code.

set -u -o pipefail

# Colors (bright)
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; RESET="\e[0m"

ITEM_ID="TWGCB-01-008-0159"
TITLE="Record file deletion events (audit rules)"
RULES_DIR="/etc/audit/rules.d"
RULES_FILE="${RULES_DIR}/delete.rules"

# Must be root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}This script must run as root (try: sudo $0).${RESET}"
  exit 1
fi

# Determine UID_MIN (fallback 1000)
UID_MIN="$(awk '/^\s*UID_MIN/{print $2}' /etc/login.defs 2>/dev/null | head -n1)"
if ! [[ "$UID_MIN" =~ ^[0-9]+$ ]]; then UID_MIN=1000; fi

REQ_LINES=(
  "-a always,exit -F arch=b64 -S unlink -S unlinkat -S rename -S renameat -S rmdir -F auid>=${UID_MIN} -F auid!=4294967295 -k delete"
  "-a always,exit -F arch=b32 -S unlink -S unlinkat -S rename -S renameat -S rmdir -F auid>=${UID_MIN} -F auid!=4294967295 -k delete"
)

echo -e "${CYAN}${ITEM_ID}: ${TITLE}${RESET}"
echo
echo "Checking audit rules in ${RULES_FILE}..."
echo "Check results:"

# --- helpers ---------------------------------------------------------------

candidate_grep() {
  # $1=file, $2=arch(b64/b32)
  local file="$1" arch="$2"
  grep -nE "^[[:space:]]*-a[[:space:]]+always,exit\b.*arch=${arch}\b.*-k[[:space:]]*delete([[:space:]]|$)" "$file" 2>/dev/null
}

line_has_all_tokens() {
  # $1=line content
  local line="$1"
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-S[[:space:]]+unlink([[:space:]]|$)'      || return 1
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-S[[:space:]]+unlinkat([[:space:]]|$)'    || return 1
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-S[[:space:]]+rename([[:space:]]|$)'      || return 1
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-S[[:space:]]+renameat([[:space:]]|$)'    || return 1
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-S[[:space:]]+rmdir([[:space:]]|$)'       || return 1
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-F[[:space:]]+auid>='"$UID_MIN"'([[:space:]]|$)' || return 1
  printf '%s\n' "$line" | grep -qE '(^|[[:space:]])-F[[:space:]]+auid!=4294967295([[:space:]]|$)'   || return 1
  return 0
}

show_matching_rule() {
  # $1=file, $2=arch -> prints "Line: n: <line>" or "(No matching line found)"
  local file="$1" arch="$2"
  local found=0
  while IFS= read -r cand; do
    local num="${cand%%:*}"
    local content="${cand#*:}"
    if line_has_all_tokens "$content"; then
      echo "Line: ${num}: ${content}"
      found=1
    fi
  done < <(candidate_grep "$file" "$arch")
  if [[ $found -eq 0 ]]; then
    echo "(No matching line found)"
  fi
}

rule_exists() {
  # $1=file, $2=arch -> returns 0 if a matching line exists with all tokens
  local file="$1" arch="$2"
  while IFS= read -r cand; do
    local content="${cand#*:}"
    if line_has_all_tokens "$content"; then
      return 0
    fi
  done < <(candidate_grep "$file" "$arch")
  return 1
}

# --- display current state -------------------------------------------------

if [[ -e "$RULES_FILE" ]]; then
  echo "Required: ${REQ_LINES[0]}"; show_matching_rule "$RULES_FILE" "b64"
  echo "Required: ${REQ_LINES[1]}"; show_matching_rule "$RULES_FILE" "b32"
else
  echo "Required: ${REQ_LINES[0]}"; echo "(File not found: ${RULES_FILE})"
  echo "Required: ${REQ_LINES[1]}"; echo "(File not found: ${RULES_FILE})"
fi
echo

missing=()
if ! [[ -f "$RULES_FILE" ]]; then
  missing+=(b64 b32)
else
  rule_exists "$RULES_FILE" "b64" || missing+=(b64)
  rule_exists "$RULES_FILE" "b32" || missing+=(b32)
fi

if [[ ${#missing[@]} -eq 0 ]]; then
  echo -e "${GREEN}Compliant:${RESET} Both b64 and b32 delete rules are present."
  exit 0
fi

echo -e "${RED}Non-compliant:${RESET} Missing ${#missing[@]} required rule(s):"
for m in "${missing[@]}"; do
  if [[ "$m" == "b64" ]]; then echo "  - ${REQ_LINES[0]}"; else echo "  - ${REQ_LINES[1]}"; fi
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
  echo "# ${ITEM_ID} — audit delete/rename events (UID_MIN=${UID_MIN})"
  for m in "${missing[@]}"; do
    if [[ "$m" == "b64" ]]; then
      echo "${REQ_LINES[0]}"
    else
      echo "${REQ_LINES[1]}"
    fi
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
  echo "Required: ${REQ_LINES[0]}"; show_matching_rule "$RULES_FILE" "b64"
  echo "Required: ${REQ_LINES[1]}"; show_matching_rule "$RULES_FILE" "b32"
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
