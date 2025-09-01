#!/bin/bash
# TWGCB-01-008-0161: Ensure sudo log file changes are audited
# Target OS: RHEL 8.5
# Behavior:
#   - Detect active sudo logfile path from /etc/sudoers and /etc/sudoers.d/*
#   - Check for an audit rule: -w <sudo.log> -p wa -k actions
#   - Offer to apply: append to /etc/audit/rules.d/actions.rules and load via augenrules
#   - Clear, colorized output; interactive [Y/N/C] prompt
# Notes:
#   - If 'auditctl -s' shows enabled=2 (locked), loading new rules requires reboot.
#   - No Chinese in this script per project requirements.

set -u -o pipefail

# Colors (bright)
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
CYAN="\e[96m"
RESET="\e[0m"

ITEM_ID="TWGCB-01-008-0161"
TITLE="Record admin activity log changes (audit sudo.log)"
RULES_DIR="/etc/audit/rules.d"
RULES_FILE="${RULES_DIR}/actions.rules"

echo "${CYAN}${ITEM_ID}: ${TITLE}${RESET}"
echo
echo "Detecting sudo logfile path..."
echo "Checking files:"
echo "  - /etc/sudoers"
echo "  - /etc/sudoers.d/*"
echo

# Find logfile setting from sudoers, first non-comment with logfile=
# If multiple, first hit wins.
detect_sudo_log() {
  local found
  found="$(grep -HnrE '^[[:space:]]*[^#].*logfile=' /etc/sudoers /etc/sudoers.d/* 2>/dev/null \
           | head -n1 \
           | sed -E 's/.*logfile=([^ ,]+).*/\1/')"

  if [[ -n "${found:-}" ]]; then
    echo "$found"
    return 0
  fi

  # Fallback to default commonly used path
  if [[ -e /var/log/sudo.log || -d /var/log ]]; then
    echo "/var/log/sudo.log"
    return 0
  fi

  # As a last resort, still choose default path
  echo "/var/log/sudo.log"
}

SUDO_LOG="$(detect_sudo_log)"

echo "Detected sudo logfile: ${SUDO_LOG}"
echo

# Helper: show matching lines with "Line: " prefix for numbers
show_matches_with_lines() {
  local file="$1" pattern="$2"
  if [[ -r "$file" ]]; then
    # grep -n, then prefix "Line: " before the line number
    grep -nE "$pattern" "$file" 2>/dev/null | sed -E 's/^/Line: /'
  else
    if [[ -e "$file" ]]; then
      echo "(Permission denied reading ${file})"
    else
      echo "(File not found: ${file})"
    fi
  fi
}

# Build a tolerant regex to match:
#   -w <path> ... -p with both w and a (any order/others allowed) ... -k actions
# Allow flexible spacing and option order.
path_escaped="$(printf '%s\n' "$SUDO_LOG" | sed -E 's/[][\.^$*+?(){}|/]/\\&/g')"
AUDIT_REGEX="^[[:space:]]*-w[[:space:]]+${path_escaped}([[:space:]]+(-[A-Za-z]+|[[:alnum:][:space:]\-_/.:])*)?-p[[:space:]]*[rwxad]*w[rwxad]*a[rwxad]*([[:space:]]+(-[A-Za-z]+|[[:alnum:][:space:]\-_/.:])*)?-k[[:space:]]*actions([[:space:]]|$)"

echo "Checking audit rules in ${RULES_FILE}..."
echo "Check results:"
if [[ -e "$RULES_FILE" ]]; then
  show_matches_with_lines "$RULES_FILE" "$AUDIT_REGEX"
else
  echo "(No matching line found)"
fi
echo

# Determine compliance
is_compliant=1
if [[ -f "$RULES_FILE" ]] && grep -Eq "$AUDIT_REGEX" "$RULES_FILE"; then
  is_compliant=0
fi

if [[ $is_compliant -eq 0 ]]; then
  echo -e "${GREEN}Compliant:${RESET} Audit rule for ${SUDO_LOG} with -p wa -k actions is present."
  exit 0
fi

echo -e "${RED}Non-compliant:${RESET} Audit rule for ${SUDO_LOG} is missing or incomplete."
echo -n "Apply fix now (append rule and load with 'augenrules --load')? [Y]es / [N]o / [C]ancel: "

read -rsn1 ans
echo
case "${ans}" in
  [Yy])
    ;;
  [Nn])
    echo "Skipped."
    exit 0
    ;;
  [Cc])
    echo "Canceled."
    exit 2
    ;;
  *)
    echo "Invalid choice. Aborted."
    exit 2
    ;;
esac

# Prepare rule line
RULE_LINE="-w ${SUDO_LOG} -p wa -k actions"

# Ensure rules directory exists
if [[ ! -d "$RULES_DIR" ]]; then
  echo -e "${RED}Failed to apply:${RESET} ${RULES_DIR} does not exist."
  exit 1
fi

# Append rule if not present; preserve idempotency
if [[ -f "$RULES_FILE" ]] && grep -Eq "$AUDIT_REGEX" "$RULES_FILE"; then
  echo "Rule already present in ${RULES_FILE}. Proceeding to reload."
else
  {
    echo
    echo "# ${ITEM_ID} — audit sudo logfile changes"
    echo "$RULE_LINE"
  } >> "$RULES_FILE" 2>/dev/null || {
    if [[ -e "$RULES_FILE" ]]; then
      echo -e "${RED}Failed to apply:${RESET} Permission denied writing ${RULES_FILE}."
    else
      echo -e "${RED}Failed to apply:${RESET} Unable to create ${RULES_FILE} (permission denied?)."
    fi
    exit 1
  }
fi

# Try to load rules
if ! command -v augenrules >/dev/null 2>&1; then
  echo -e "${RED}Failed to apply:${RESET} 'augenrules' not found."
  exit 1
fi

if augenrules --load >/dev/null 2>&1; then
  # Verify after load
  if grep -Eq "$AUDIT_REGEX" "$RULES_FILE"; then
    echo "Re-checking ${RULES_FILE}..."
    show_matches_with_lines "$RULES_FILE" "$AUDIT_REGEX"
    echo -e "${GREEN}Successfully applied.${RESET}"
    exit 0
  else
    echo -e "${RED}Failed to apply:${RESET} Rule not found after reload."
    exit 1
  fi
else
  # Check audit lock status
  if command -v auditctl >/dev/null 2>&1; then
    enabled_val="$(auditctl -s 2>/dev/null | awk '/^enabled/ {print $2}' | sed 's/[^0-9]//g')"
    if [[ "${enabled_val:-}" == "2" ]]; then
      echo "Warning: auditd is in locked mode (enabled=2). A reboot is required to load new rules."
    fi
  fi
  echo -e "${RED}Failed to apply:${RESET} Could not load rules via augenrules."
  exit 1
fi
