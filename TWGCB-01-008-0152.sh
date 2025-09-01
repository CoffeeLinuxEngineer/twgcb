#!/bin/bash
# TWGCB-01-008-0152: Audit MAC (SELinux policy) changes (RHEL 8.5)
# Monitors changes under /etc/selinux/ and /usr/share/selinux/.
# Required watch rules (baseline):
#   -w /etc/selinux/ -p wa -k MAC-policy
#   -w /usr/share/selinux/ -p wa -k MAC-policy
# Behavior:
#   - Checks /etc/audit/rules.d/MAC-policy.rules for both watches
#   - Prints matching lines with 'Line: ' prefixed numbers
#   - Interactively appends any missing rules and reloads via 'augenrules --load'
#   - If auditd is immutable (enabled=2), writes rules and exits 0 with Pending (reboot required)
# Notes:
#   - No Chinese in code.

set -u -o pipefail

# Colors (bright)
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; RESET="\e[0m"

ITEM_ID="TWGCB-01-008-0152"
TITLE="Record changes to system mandatory access controls (SELinux)"
RULES_DIR="/etc/audit/rules.d"
RULES_FILE="${RULES_DIR}/MAC-policy.rules"

REQ_LINES=(
  "-w /etc/selinux/ -p wa -k MAC-policy"
  "-w /usr/share/selinux/ -p wa -k MAC-policy"
)

# Tolerant regexes: -w <path> ... -p containing w and a ... -k MAC-policy
REQ_REGEX=(
  '^[[:space:]]*-w[[:space:]]+/etc/selinux/([[:space:]]+.*)?-p[[:space:]]*[rwxad]*w[rwxad]*a[rwxad]*([[:space:]]+.*)?-k[[:space:]]*MAC-policy([[:space:]]|$)'
  '^[[:space:]]*-w[[:space:]]+/usr/share/selinux/([[:space:]]+.*)?-p[[:space:]]*[rwxad]*w[rwxad]*a[rwxad]*([[:space:]]+.*)?-k[[:space:]]*MAC-policy([[:space:]]|$)'
)

# Must be root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}This script must run as root (try: sudo $0).${RESET}"
  exit 1
fi

echo -e "${CYAN}${ITEM_ID}: ${TITLE}${RESET}"
echo
echo "Checking audit rules in ${RULES_FILE}..."
echo "Check results:"

show_matches_with_lines() {
  local file="$1" regex="$2"
  if [[ -r "$file" ]]; then
    local out
    out="$(grep -nE "$regex" "$file" 2>/dev/null | sed -E 's/^/Line: /')"
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

for ((i=0; i<${#REQ_REGEX[@]}; i++)); do
  echo "Required: ${REQ_LINES[$i]}"
  show_matches_with_lines "$RULES_FILE" "${REQ_REGEX[$i]}"
done
echo

missing_idx=()
if [[ -f "$RULES_FILE" ]]; then
  for ((i=0; i<${#REQ_REGEX[@]}; i++)); do
    grep -Eq "${REQ_REGEX[$i]}" "$RULES_FILE" || missing_idx+=("$i")
  done
else
  for ((i=0; i<${#REQ_REGEX[@]}; i++)); do missing_idx+=("$i"); done
fi

if [[ ${#missing_idx[@]} -eq 0 ]]; then
  echo -e "${GREEN}Compliant:${RESET} Both MAC-policy watch rules are present."
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

# Ensure rules directory exists
if [[ ! -d "$RULES_DIR" ]]; then
  echo -e "${RED}Failed to apply:${RESET} ${RULES_DIR} does not exist."
  exit 1
fi

# Create file if needed
[[ -e "$RULES_FILE" ]] || touch "$RULES_FILE" 2>/dev/null || {
  echo -e "${RED}Failed to apply:${RESET} Unable to create ${RULES_FILE} (permission denied?)."
  exit 1
}

# Append missing lines
{
  echo
  echo "# ${ITEM_ID} — audit SELinux policy directory changes"
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
  for ((i=0; i<${#REQ_REGEX[@]}; i++)); do
    echo "Required: ${REQ_LINES[$i]}"
    show_matches_with_lines "$RULES_FILE" "${REQ_REGEX[$i]}"
  done
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
