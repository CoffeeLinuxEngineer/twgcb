#!/bin/bash
# TWGCB-01-008-0158: Audit privileged command executions
# Target OS: RHEL 8.5
# Behavior:
#   - Discover setuid/setgid files on all local real filesystems (xfs/ext*/btrfs) using find -xdev.
#   - For each file, ensure an audit rule exists:
#       -a always,exit -F path=<file> -F perm=x -F auid>=UID_MIN -F auid!=4294967295 -k privileged
#   - Check existing rules in /etc/audit/rules.d/privileged.rules and show matching lines with 'Line: ' prefixes.
#   - Interactively append any missing rules and reload via augenrules.
#   - If auditd is immutable (enabled=2), mark as Pending (reboot required) and exit 0.
# Notes:
#   - UID_MIN is read from /etc/login.defs (fallback 1000).
#   - No Chinese in code.

set -u -o pipefail

# Colors (bright)
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; RESET="\e[0m"

ITEM_ID="TWGCB-01-008-0158"
TITLE="Record privileged command usage (audit rules)"
RULES_DIR="/etc/audit/rules.d"
RULES_FILE="${RULES_DIR}/privileged.rules"

# Must be root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}This script must run as root (try: sudo $0).${RESET}"
  exit 1
fi

# Determine UID_MIN (fallback 1000)
UID_MIN="$(awk '/^\s*UID_MIN/{print $2}' /etc/login.defs 2>/dev/null | head -n1)"
if ! [[ "$UID_MIN" =~ ^[0-9]+$ ]]; then UID_MIN=1000; fi

echo -e "${CYAN}${ITEM_ID}: ${TITLE}${RESET}"
echo
echo "Discovering setuid/setgid files on local filesystems..."
# Collect candidate mountpoints (exclude pseudo filesystems)
mapfile -t MPS < <(findmnt -rn -lo TARGET,FSTYPE 2>/dev/null | awk '
  BEGIN{IGNORECASE=1}
  {
    tgt=$1; fstype=$2;
    # Allow common real filesystems
    if (fstype ~ /^(xfs|ext2|ext3|ext4|btrfs)$/) {
      print tgt
    }
  }' | sort -u)

if [[ ${#MPS[@]} -eq 0 ]]; then
  # Fallback to root only
  MPS=("/")
fi

declare -A SEEN=()
declare -a PRIV_FILES=()

for mp in "${MPS[@]}"; do
  while IFS= read -r -d '' f; do
    # Deduplicate by path
    [[ -n "${SEEN[$f]:-}" ]] && continue
    SEEN[$f]=1
    PRIV_FILES+=("$f")
  done < <(find "$mp" -xdev \( -perm -4000 -o -perm -2000 \) -type f -print0 2>/dev/null)
done

# Sort for stable output
IFS=$'\n' PRIV_FILES=($(printf '%s\n' "${PRIV_FILES[@]}" | sort -u)); unset IFS
echo "Found ${#PRIV_FILES[@]} privileged file(s)."
echo

echo "Checking existing rules in ${RULES_FILE}..."
echo "Check results:"
if [[ -r "$RULES_FILE" ]]; then
  # Show all lines with -k privileged and their numbers
  grep -nE '(^|[[:space:]])-k[[:space:]]*privileged([[:space:]]|$)' "$RULES_FILE" 2>/dev/null | sed -E 's/^/Line: /' || true
  # If none matched, indicate that
  if ! grep -qE '(^|[[:space:]])-k[[:space:]]*privileged([[:space:]]|$)' "$RULES_FILE" 2>/dev/null; then
    echo "(No matching line found)"
  fi
else
  if [[ -e "$RULES_FILE" ]]; then
    echo "(Permission denied reading ${RULES_FILE})"
  else
    echo "(File not found: ${RULES_FILE})"
  fi
fi
echo

# Build required lines for each discovered file
declare -a REQ_LINES=()
for p in "${PRIV_FILES[@]}"; do
  REQ_LINES+=("-a always,exit -F path=${p} -F perm=x -F auid>=${UID_MIN} -F auid!=4294967295 -k privileged")
done

# Determine which rules are missing
declare -a MISSING=()
if [[ -f "$RULES_FILE" ]]; then
  for line in "${REQ_LINES[@]}"; do
    # Use fixed-string grep to match the canonical line
    if ! grep -Fqx -- "$line" "$RULES_FILE"; then
      MISSING+=("$line")
    fi
  done
else
  MISSING=("${REQ_LINES[@]}")
fi

if [[ ${#MISSING[@]} -eq 0 ]]; then
  echo -e "${GREEN}Compliant:${RESET} Audit rules for all ${#PRIV_FILES[@]} privileged file(s) are present."
  exit 0
fi

echo -e "${RED}Non-compliant:${RESET} Missing ${#MISSING[@]} rule(s) for privileged files."
# Show up to 20 missing examples to avoid flooding output
show_max=20
idx=0
for line in "${MISSING[@]}"; do
  printf '  - %s\n' "$line"
  idx=$((idx+1))
  if [[ $idx -ge $show_max ]]; then
    remain=$(( ${#MISSING[@]} - show_max ))
    if [[ $remain -gt 0 ]]; then
      echo "  ... and ${remain} more"
    fi
    break
  fi
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

# Create rules file if missing
[[ -e "$RULES_FILE" ]] || touch "$RULES_FILE" 2>/dev/null || {
  echo -e "${RED}Failed to apply:${RESET} Unable to create ${RULES_FILE} (permission denied?)."
  exit 1
}

# Append missing lines
{
  echo
  echo "# ${ITEM_ID} — audit privileged command executions (UID_MIN=${UID_MIN})"
  echo "# Generated on $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  for line in "${MISSING[@]}"; do
    echo "$line"
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
  grep -nE '(^|[[:space:]])-k[[:space:]]*privileged([[:space:]]|$)' "$RULES_FILE" 2>/dev/null | sed -E 's/^/Line: /' || true
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
