#!/bin/bash
# TWGCB-01-008-0144: Audit tools ownership must be root:root
# Target OS: RHEL 8.5
# Baseline check items (either /sbin or /usr/sbin as available):
#   auditctl, aureport, ausearch, autrace, auditd, audisp-remote, audisp-syslog, augenrules, rsyslogd
# Requirement: each binary's owner and group must be root:root.
# Behavior:
#   - Resolves each tool path (prefers /sbin, then /usr/sbin).
#   - Shows current ownership using `ls -ld`, prefixed with 'Line: ' numbers.
#   - If any are not root:root (or missing), offers to fix with chown root:root.
# Notes:
#   - No Chinese in code.

set -u -o pipefail

# Colors
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; RESET="\e[0m"

ITEM_ID="TWGCB-01-008-0144"
TITLE="Audit tools ownership (must be root:root)"

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

for name in "${TOOLS[@]}"; do
  # Desired canonical path for messaging
  local_req="/sbin/${name}"
  path="$(resolve_path "$name" || true)"
  if [[ -n "${path:-}" ]]; then
    # Show current ownership using ls -ld
    ((line_no++))
    if command ls -ld -- "$path" >/dev/null 2>&1; then
      echo -n "Line: ${line_no}:"
      command ls -ld -- "$path"
    else
      echo "Line: ${line_no}: (Permission denied reading ${path})"
    fi
    # Evaluate owner:group
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
    BAD_PATHS+=("${local_req}")
    BAD_DESC+=("${local_req} missing")
  fi
done

echo
if [[ ${#BAD_PATHS[@]} -eq 0 ]]; then
  echo -e "${GREEN}Compliant:${RESET} All listed audit tools are owned by root:root."
  exit 0
fi

echo -e "${RED}Non-compliant:${RESET} ${#BAD_PATHS[@]} item(s) need attention:"
for desc in "${BAD_DESC[@]}"; do
  echo "  - ${desc}"
done

echo
echo -n "Apply fix now (chown root:root on existing files; skip missing)? [Y]es / [N]o / [C]ancel: "
read -rsn1 ans; echo
case "$ans" in
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
  echo -e "${GREEN}Successfully applied.${RESET}"
  exit 0
else
  echo -e "${YELLOW}Applied with warnings:${RESET} Some items may still be non-compliant."
  exit 1
fi
