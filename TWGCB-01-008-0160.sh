#
//  TWGCB-01-008-0160.sh
//  
//
//  Created by zhuo on 2025/9/1.
//


#!/bin/bash
# TWGCB-01-008-0160: Audit kernel module load/unload events
# Target OS: RHEL 8.5
# Required rules (from baseline):
#   -w /sbin/insmod   -p x -k modules
#   -w /sbin/rmmod    -p x -k modules
#   -w /sbin/modprobe -p x -k modules
#   -a always,exit -F arch=b64 -S init_module -S delete_module -k modules
#   -a always,exit -F arch=b32 -S init_module -S delete_module -k modules
# Behavior:
#   - Check the above in /etc/audit/rules.d/audit.rules
#   - Print matching lines with "Line: <n>:" prefixes
#   - Offer to append any missing rules and reload with augenrules
#   - Color-coded outputs; interactive [Y/N/C]
# Notes:
#   - If 'auditctl -s' shows enabled=2 (locked), a reboot is required to load new rules.
#   - No Chinese in code per project requirements.

set -u -o pipefail

# Colors (bright)
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
CYAN="\e[96m"
RESET="\e[0m"

ITEM_ID="TWGCB-01-008-0160"
TITLE="Record kernel module load/unload events (audit rules)"
RULES_DIR="/etc/audit/rules.d"
RULES_FILE="${RULES_DIR}/audit.rules"

echo -e "${CYAN}${ITEM_ID}: ${TITLE}${RESET}"
echo
echo "Checking audit rules in ${RULES_FILE}..."
echo "Check results:"

# Patterns (exact lines recommended by baseline)
REQ_LINES=(
  "-w /sbin/insmod -p x -k modules"
  "-w /sbin/rmmod -p x -k modules"
  "-w /sbin/modprobe -p x -k modules"
  "-a always,exit -F arch=b64 -S init_module -S delete_module -k modules"
  "-a always,exit -F arch=b32 -S init_module -S delete_module -k modules"
)

# Tolerant regexes to detect presence (allow extra spaces/options order not strictly enforced)
REQ_REGEX=(
  '^[[:space:]]*-w[[:space:]]+/sbin/insmod\b.*-p[[:space:]]*x\b.*-k[[:space:]]*modules([[:space:]]|$)'
  '^[[:space:]]*-w[[:space:]]+/sbin/rmmod\b.*-p[[:space:]]*x\b.*-k[[:space:]]*modules([[:space:]]|$)'
  '^[[:space:]]*-w[[:space:]]+/sbin/modprobe\b.*-p[[:space:]]*x\b.*-k[[:space:]]*modules([[:space:]]|$)'
  '^[[:space:]]*-a[[:space:]]+always,exit\b.*arch=b64\b.*-S[[:space:]]+init_module\b.*-S[[:space:]]+delete_module\b.*-k[[:space:]]*modules([[:space:]]|$)'
  '^[[:space:]]*-a[[:space:]]+always,exit\b.*arch=b32\b.*-S[[:space:]]+init_module\b.*-S[[:space:]]+delete_module\b.*-k[[:space:]]*modules([[:space:]]|$)'
)

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

# Display findings for each required rule
for ((i=0; i<${#REQ_REGEX[@]}; i++)); do
  echo "Required: ${REQ_LINES[$i]}"
  show_matches_with_lines "$RULES_FILE" "${REQ_REGEX[$i]}"
done
echo

# Determine compliance
missing_idx=()
if [[ -f "$RULES_FILE" ]]; then
  for ((i=0; i<${#REQ_REGEX[@]}; i++)); do
    if ! grep -Eq "${REQ_REGEX[$i]}" "$RULES_FILE"; then
      missing_idx+=("$i")
    fi
  done
else
  # If file not present, treat all as missing
  for ((i=0; i<${#REQ_REGEX[@]}; i++)); do missing_idx+=("$i"); done
fi

if [[ ${#missing_idx[@]} -eq 0 ]]; then
  echo -e "${GREEN}Compliant:${RESET} All required audit rules are present."
  exit 0
fi

echo -e "${RED}Non-compliant:${RESET} Missing ${#missing_idx[@]} required rule(s):"
for idx in "${missing_idx[@]}"; do
  echo "  - ${REQ_LINES[$idx]}"
done

echo
echo -n "Apply fix now (append missing rules to ${RULES_FILE} and reload)? [Y]es / [N]o / [C]ancel: "
read -rsn1 ans
echo
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
if [[ ! -e "$RULES_FILE" ]]; then
  if ! touch "$RULES_FILE" 2>/dev/null; then
    echo -e "${RED}Failed to apply:${RESET} Unable to create ${RULES_FILE} (permission denied?)."
    exit 1
  fi
fi

# Append missing lines
{
  echo
  echo "# ${ITEM_ID} — audit kernel module operations"
  for idx in "${missing_idx[@]}"; do
    echo "${REQ_LINES[$idx]}"
  done
} >> "$RULES_FILE" 2>/dev/null || {
  echo -e "${RED}Failed to apply:${RESET} Permission denied writing ${RULES_FILE}."
  exit 1
}

# Reload audit rules
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
  # Verify all present now
  all_ok=1
  for ((i=0; i<${#REQ_REGEX[@]}; i++)); do
    grep -Eq "${REQ_REGEX[$i]}" "$RULES_FILE" || all_ok=0
  done
  if [[ $all_ok -eq 1 ]]; then
    echo -e "${GREEN}Successfully applied.${RESET}"
    exit 0
  else
    echo -e "${RED}Failed to apply:${RESET} Some rules still missing after reload."
    exit 1
  fi
else
  if command -v auditctl >/dev/null 2>&1; then
    enabled_val="$(auditctl -s 2>/dev/null | awk '/^enabled/ {print $2}' | sed 's/[^0-9]//g')"
    if [[ "${enabled_val:-}" == "2" ]]; then
      echo "Warning: auditd is in locked mode (enabled=2). Reboot is required to load new rules."
    fi
  fi
  echo -e "${RED}Failed to apply:${RESET} Could not load rules via augenrules."
  exit 1
fi
