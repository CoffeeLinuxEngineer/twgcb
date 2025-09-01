#!/bin/bash
# TWGCB-01-008-0146: Audit log max file size (auditd.conf)
# Target OS: RHEL 8.5
# Baseline requirement:
#   max_log_file >= 32  (MB)
# Behavior:
#   - Checks /etc/audit/auditd.conf for the effective max_log_file value
#   - Shows matching config lines with 'Line: ' prefixed numbers
#   - Interactively sets it to at least 32 (defaults to 32) and reloads auditd
# Notes:
#   - No Chinese in code.

set -u -o pipefail

# Colors (bright)
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; RESET="\e[0m"

ITEM_ID="TWGCB-01-008-0146"
TITLE="Audit log max file size (auditd.conf)"
CONF="/etc/audit/auditd.conf"
MIN_MB=32

echo -e "${CYAN}${ITEM_ID}: ${TITLE}${RESET}"
echo
echo "Checking ${CONF}..."
echo "Check results:"
echo "Required: max_log_file >= ${MIN_MB}"

show_matches_with_lines() {
  local file="$1"
  if [[ -r "$file" ]]; then
    local out
    out="$(grep -nE '^[[:space:]]*max_log_file[[:space:]]*=' "$file" 2>/dev/null | sed -E 's/^/Line: /')"
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

# Returns the last active (non-comment) assignment's numeric value, empty if none or non-numeric
effective_value() {
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*max_log_file[[:space:]]*=/ {
      line=$0
      sub(/^[[:space:]]*max_log_file[[:space:]]*=[[:space:]]*/,"",line)
      # Trim after number (allow inline comments)
      if (match(line, /^[0-9]+/)) {
        val=substr(line, RSTART, RLENGTH)
      } else {
        val=""
      }
    }
    END{ if (val!="") print val; }
  ' "$CONF" 2>/dev/null
}

show_matches_with_lines "$CONF"
echo

cur="$(effective_value || true)"
if [[ -n "${cur:-}" && "$cur" =~ ^[0-9]+$ && "$cur" -ge "$MIN_MB" ]]; then
  echo -e "${GREEN}Compliant:${RESET} max_log_file is ${cur} MB (>= ${MIN_MB})."
  exit 0
fi

if [[ -z "${cur:-}" ]]; then
  echo -e "${RED}Non-compliant:${RESET} No active numeric max_log_file found."
else
  echo -e "${RED}Non-compliant:${RESET} max_log_file is ${cur} MB (< ${MIN_MB})."
fi

echo
echo -n "Apply fix now (set max_log_file to at least ${MIN_MB} MB and reload auditd)? [Y]es / [N]o / [C]ancel: "
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

target="$MIN_MB"

# Update existing assignment if present; otherwise append
if grep -qE '^[[:space:]]*max_log_file[[:space:]]*=' "$CONF" 2>/dev/null; then
  if sed -ri "s/^[[:space:]]*max_log_file[[:space:]]*=.*/max_log_file = ${target}/I" "$CONF"; then
    echo "Updated existing max_log_file to ${target} MB."
  else
    echo -e "${RED}Failed to apply:${RESET} Unable to update ${CONF}."
    exit 1
  fi
else
  echo "max_log_file = ${target}" >> "$CONF" 2>/dev/null || {
    echo -e "${RED}Failed to apply:${RESET} Unable to append to ${CONF}."
    exit 1
  }
  echo "Appended 'max_log_file = ${target}' to ${CONF}."
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
echo "Required: max_log_file >= ${MIN_MB}"
show_matches_with_lines "$CONF"
echo

cur2="$(effective_value || true)"
if [[ -n "${cur2:-}" && "$cur2" =~ ^[0-9]+$ && "$cur2" -ge "$MIN_MB" ]]; then
  echo -e "${GREEN}Successfully applied.${RESET}"
  exit 0
else
  echo -e "${RED}Failed:${RESET} max_log_file effective value is '${cur2:-<unset>}' (expected >= ${MIN_MB})."
  exit 1
fi
