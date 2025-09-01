#!/bin/bash
# TWGCB-01-008-0147: Audit log max size behavior (auditd.conf)
# Target OS: RHEL 8.5
# Baseline requirement:
#   max_log_file_action = keep_logs
# Behavior:
#   - Checks /etc/audit/auditd.conf for the effective max_log_file_action
#   - Shows matching config lines with 'Line: ' prefixed numbers
#   - Interactively sets it to 'keep_logs' and reloads auditd
# Notes:
#   - No Chinese in code.

set -u -o pipefail

# Colors (bright)
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; RESET="\e[0m"

ITEM_ID="TWGCB-01-008-0147"
TITLE="Audit log max size action (auditd.conf)"
CONF="/etc/audit/auditd.conf"

echo -e "${CYAN}${ITEM_ID}: ${TITLE}${RESET}"
echo
echo "Checking ${CONF}..."
echo "Check results:"
echo "Required: max_log_file_action = keep_logs"

show_matches_with_lines() {
  local file="$1"
  if [[ -r "$file" ]]; then
    local out
    out="$(grep -nE '^[[:space:]]*max_log_file_action[[:space:]]*=' "$file" 2>/dev/null | sed -E 's/^/Line: /')"
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

effective_value() {
  # Prints the last non-comment assignment's value (lowercased), or empty if none
  awk '
    BEGIN{IGNORECASE=1; val=""}
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*max_log_file_action[[:space:]]*=/ {
      line=$0
      sub(/^[[:space:]]*max_log_file_action[[:space:]]*=[[:space:]]*/,"",line)
      sub(/[[:space:]]+.*/,"",line)
      val=line
    }
    END{
      if (val!="") {
        # lowercase
        for (i=1;i<=length(val);i++){ c=substr(val,i,1); printf("%s", tolower(c)); }
        printf("\n")
      }
    }
  ' "$CONF" 2>/dev/null
}

show_matches_with_lines "$CONF"
echo

val="$(effective_value || true)"
if [[ "${val:-}" == "keep_logs" ]]; then
  echo -e "${GREEN}Compliant:${RESET} max_log_file_action is set to 'keep_logs'."
  exit 0
fi

if [[ -z "${val:-}" ]]; then
  echo -e "${RED}Non-compliant:${RESET} No active max_log_file_action found (or commented only)."
else
  echo -e "${RED}Non-compliant:${RESET} max_log_file_action is '${val}', expected 'keep_logs'."
fi

echo
echo -n "Apply fix now (set max_log_file_action = keep_logs and reload auditd)? [Y]es / [N]o / [C]ancel: "
read -rsn1 ans; echo
case "$ans" in
  [Yy]) ;;
  [Nn]) echo "Skipped."; exit 0 ;;
  [Cc]) echo "Canceled."; exit 2 ;;
  *)    echo "Invalid choice. Aborted."; exit 2 ;;
esac

# --- apply change ----------------------------------------------------------

if [[ ! -e "$CONF" ]]; then
  echo -e "${RED}Failed to apply:${RESET} ${CONF} not found."
  exit 1
fi

# Backup
ts="$(date -u +'%Y%m%dT%H%M%SZ')"
cp -a "$CONF" "${CONF}.bak.${ts}" 2>/dev/null || {
  echo -e "${YELLOW}Warning:${RESET} Could not create backup ${CONF}.bak.${ts}."
}

# Update existing assignment if present; otherwise append
if grep -qE '^[[:space:]]*max_log_file_action[[:space:]]*=' "$CONF" 2>/dev/null; then
  if sed -ri 's/^[[:space:]]*max_log_file_action[[:space:]]*=.*/max_log_file_action = keep_logs/I' "$CONF"; then
    echo "Updated existing max_log_file_action to 'keep_logs'."
  else
    echo -e "${RED}Failed to apply:${RESET} Unable to update ${CONF}."
    exit 1
  fi
else
  echo "max_log_file_action = keep_logs" >> "$CONF" 2>/dev/null || {
    echo -e "${RED}Failed to apply:${RESET} Unable to append to ${CONF}."
    exit 1
  }
  echo "Appended 'max_log_file_action = keep_logs' to ${CONF}."
fi

# Reload auditd to pick up auditd.conf changes
reload_ok=0
if command -v systemctl >/dev/null 2>&1; then
  if systemctl reload auditd >/dev/null 2>&1; then
    reload_ok=1
  fi
fi
if [[ $reload_ok -eq 0 ]] && command -v service >/dev/null 2>&1; then
  if service auditd reload >/dev/null 2>&1; then
    reload_ok=1
  fi
fi
if [[ $reload_ok -eq 0 ]] && command -v pkill >/dev/null 2>&1; then
  if pkill -HUP -x auditd >/dev/null 2>&1; then
    reload_ok=1
  fi
fi

if [[ $reload_ok -eq 1 ]]; then
  echo -e "${GREEN}Reloaded auditd to apply changes.${RESET}"
else
  echo -e "${YELLOW}Warning:${RESET} Could not reload auditd automatically. A restart may be required to apply ${CONF} changes."
fi

# Re-check
echo
echo "Re-checking ${CONF}..."
echo "Check results:"
echo "Required: max_log_file_action = keep_logs"
show_matches_with_lines "$CONF"
echo

val2="$(effective_value || true)"
if [[ "${val2:-}" == "keep_logs" ]]; then
  echo -e "${GREEN}Successfully applied.${RESET}"
  exit 0
else
  echo -e "${RED}Failed:${RESET} max_log_file_action effective value is still '${val2:-<unset>}'."
  exit 1
fi
