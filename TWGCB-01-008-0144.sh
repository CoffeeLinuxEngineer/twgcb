#!/bin/bash
# TWGCB-01-008-0144 v2: Audit tools ownership must be root:root
# Adds:
#   --ignore-missing  : treat missing tools as N/A (do not fail compliance)
#   --apply           : non-interactive; auto-fix ownership of existing files
# Target OS: RHEL 8.5
# Notes:
#   - No Chinese in code.

set -u -o pipefail

# Colors
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; RESET="\e[0m"

ITEM_ID="TWGCB-01-008-0144"
TITLE="Audit tools ownership (must be root:root)"

USAGE="Usage: $0 [--ignore-missing] [--apply]
  --ignore-missing  Treat missing tools as N/A for compliance
  --apply           Auto-apply chown fixes without prompting"

IGNORE_MISSING=0
AUTO_APPLY=0
for arg in "$@"; do
  case "$arg" in
    --ignore-missing) IGNORE_MISSING=1 ;;
    --apply)          AUTO_APPLY=1 ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    *) echo "Unknown option: $arg"; echo "$USAGE"; exit 2 ;;
  esac
done

# Must be root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}This script must run as root (try: sudo $0).${RESET}"
  exit 1
fi

echo -e "${CYAN}${ITEM_ID}: ${TITLE}${RESET}"
echo

TOOLS=(
  "auditctl"
  "aureport"
  "ausearch"
  "autrace"
  "auditd"
  "audisp-remote"
  "audisp-syslog"
  "augenrules"
  "rsyslogd"
)

resolve_path() {
  local name="$1"
  local cand
  for cand in "/sbin/${name}" "/usr/sbin/${name}"; do
    if [[ -e "$cand" ]]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

echo "Checking tools ownership..."
echo "Check results:"
echo "Required: each listed file must be owned by root:root"
echo

line_no=0
declare -a BAD_PATHS=()
declare -a BAD_DESC=()
declare -a MISSING=()

for name in "${TOOLS[@]}"; do
  local_req="/sbin/${name}"
  path="$(resolve_path "$name" || true)"
  if [[ -n "${path:-}" ]]; then
    ((line_no++))
    if command ls -ld -- "$path" >/dev/null 2>&1; then
      echo -n "Line: ${line_no}:"
      command ls -ld -- "$path"
    else
      echo "Line: ${line_no}: (Permission denied reading ${path})"
    fi
    if owner="$(stat -c '%U' -- "$path" 2>/dev/null)" && group="$(stat -c '%G' -- "$path" 2>/dev/null)"; then
      if [[ "$owner" != "root" || "$group" != "root" ]]; then
        BAD_PATHS+=("$path")
        BAD_DESC+=("${path} owner:group is ${owner}:${group} (expected root:root)")
      fi
    else
      BAD_PATHS+=("$path")
      BAD_DESC+=("${path} ownership unknown (stat failed)")
    fi
  else
    ((line_no++))
    echo "Line: ${line_no}: (File not found: ${local_req} or /usr/sbin/${name})"
    MISSING+=("${local_req}")
  fi
done

echo
if [[ ${#BAD_PATHS[@]} -eq 0 ]]; then
  if [[ ${#MISSING[@]} -eq 0 || $IGNORE_MISSING -eq 1 ]]; then
    echo -e "${GREEN}Compliant:${RESET} All applicable audit tools are owned by root:root."
    if [[ ${#MISSING[@]} -gt 0 ]]; then
      echo -e "${YELLOW}Note:${RESET} ${#MISSING[@]} tool(s) missing but ignored due to --ignore-missing."
    fi
    exit 0
  fi
fi

# Build non-compliance message
if [[ ${#BAD_PATHS[@]} -gt 0 ]]; then
  echo -e "${RED}Non-compliant:${RESET} ${#BAD_PATHS[@]} item(s) with wrong ownership:"
  for desc in "${BAD_DESC[@]}"; do echo "  - ${desc}"; done
fi
if [[ ${#MISSING[@]} -gt 0 && $IGNORE_MISSING -eq 0 ]]; then
  echo -e "${RED}Non-compliant:${RESET} ${#MISSING[@]} missing tool(s):"
  for m in "${MISSING[@]}"; do echo "  - ${m} missing"; done
fi
if [[ ${#MISSING[@]} -gt 0 && $IGNORE_MISSING -eq 1 ]]; then
  echo -e "${YELLOW}Info:${RESET} ${#MISSING[@]} missing tool(s) ignored (--ignore-missing):"
  for m in "${MISSING[@]}"; do echo "  - ${m} missing (ignored)"; done
fi

# If nothing to fix (only missing and we're strict), offer suggestion and exit
if [[ ${#BAD_PATHS[@]} -eq 0 ]]; then
  if [[ $IGNORE_MISSING -eq 1 ]]; then
    # Already reported compliant earlier; safety fallback
    exit 0
  else
    echo
    echo "Nothing to fix automatically (only missing tools found)."
    echo "Tip: install required packages or re-run with --ignore-missing if acceptable."
    exit 1
  fi
fi

# Apply fixes
if [[ $AUTO_APPLY -eq 1 ]]; then
  ans="Y"
else
  echo
  echo -n "Apply fix now (chown root:root on existing files; skip missing)? [Y]es / [N]o / [C]ancel: "
  read -rsn1 ans; echo
fi

case "${ans:-}" in
  [Yy]) ;;
  [Nn]) echo "Skipped."; exit 0 ;;
  [Cc]) echo "Canceled."; exit 2 ;;
  *)    echo "Invalid choice. Aborted."; exit 2 ;;
esac

fix_fail=0
for path in "${BAD_PATHS[@]}"; do
  if [[ -e "$path" ]]; then
    if chown root:root -- "$path" 2>/dev/null; then
      echo "Fixed: ${path} -> root:root"
    else
      echo -e "${RED}Failed:${RESET} chown root:root ${path}"
      fix_fail=1
    fi
  else
    echo "Skip (missing): ${path}"
  fi
done

echo
echo "Re-checking..."
echo

line_no=0
any_bad=0
for name in "${TOOLS[@]}"; do
  path="$(resolve_path "$name" || true)"
  if [[ -n "${path:-}" ]]; then
    ((line_no++))
    echo -n "Line: ${line_no}:"
    command ls -ld -- "$path" 2>/dev/null || echo "(Permission denied reading ${path})"
    if owner="$(stat -c '%U' -- "$path" 2>/dev/null)" && group="$(stat -c '%G' -- "$path" 2>/dev/null)"; then
      if [[ "$owner" != "root" || "$group" != "root" ]]; then
        any_bad=1
      fi
    else
      any_bad=1
    fi
  fi
done

echo
if [[ $any_bad -eq 0 && $fix_fail -eq 0 ]]; then
  if [[ ${#MISSING[@]} -gt 0 && $IGNORE_MISSING -eq 1 ]]; then
    echo -e "${GREEN}Successfully applied (missing tools ignored).${RESET}"
  else
    echo -e "${GREEN}Successfully applied.${RESET}"
  fi
  exit 0
else
  echo -e "${YELLOW}Applied with warnings:${RESET} Some items may still be non-compliant."
  exit 1
fi
