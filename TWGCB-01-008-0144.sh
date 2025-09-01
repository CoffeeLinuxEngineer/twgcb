# create the script right here
cat > TWGCB-01-008-0144-v3.sh <<'SH'
#!/bin/bash
# TWGCB-01-008-0144 v3: Audit tools ownership must be root:root (interactive)
# New: directly asks whether to SKIP missing tools (during fixes) and IGNORE missing tools (for compliance).
# Target OS: RHEL 8.5
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

# --- Prompt: skip & ignore -------------------------------------------------
read_yn() {
  # $1=prompt, $2=default(Y/N)
  local prompt="$1" def="${2:-Y}" ans
  local hint="[Y]es / [N]o"
  echo -n "${prompt} ${hint}: "
  IFS= read -r ans
  if [[ -z "${ans:-}" ]]; then ans="$def"; fi
  case "$ans" in
    [Yy]|[Yy]es) return 0 ;;
    [Nn]|[Nn]o)  return 1 ;;
    *) echo "Please answer Y or N."; read_yn "$prompt" "$def"; return $? ;;
  esac
}

SKIP_MISSING=0
IGNORE_MISSING=0
if read_yn "Skip missing tools during fixes (they'll be reported but not block the operation)?" "Y"; then
  SKIP_MISSING=1
fi
if read_yn "Ignore missing tools for compliance (treat as N/A)?" "Y"; then
  IGNORE_MISSING=1
fi
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
compliant_now=0
if [[ ${#BAD_PATHS[@]} -eq 0 ]]; then
  if [[ ${#MISSING[@]} -eq 0 || $IGNORE_MISSING -eq 1 ]]; then
    compliant_now=1
  fi
fi

if [[ $compliant_now -eq 1 ]]; then
  echo -e "${GREEN}Compliant:${RESET} All applicable audit tools are owned by root:root."
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Note:${RESET} ${#MISSING[@]} tool(s) missing but ignored per your choice."
  fi
  exit 0
fi

# Report issues
if [[ ${#BAD_PATHS[@]} -gt 0 ]]; then
  echo -e "${RED}Non-compliant:${RESET} ${#BAD_PATHS[@]} item(s) with wrong ownership:"
  for desc in "${BAD_DESC[@]}"; do echo "  - ${desc}"; done
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
  if [[ $IGNORE_MISSING -eq 1 ]]; then
    echo -e "${YELLOW}Info:${RESET} ${#MISSING[@]} missing tool(s) treated as N/A:"
    for m in "${MISSING[@]}"; do echo "  - ${m} (ignored)"; done
  else
    echo -e "${RED}Non-compliant:${RESET} ${#MISSING[@]} missing tool(s):"
    for m in "${MISSING[@]}"; do echo "  - ${m} missing"; done
  fi
fi

# If nothing to fix (only missing and NOT ignoring), stop here
if [[ ${#BAD_PATHS[@]} -eq 0 && $IGNORE_MISSING -eq 0 && ${#MISSING[@]} -gt 0 ]]; then
  if [[ $SKIP_MISSING -eq 1 ]]; then
    echo
    echo "Nothing to fix automatically (only missing tools). Skipping per your choice."
    exit 1
  else
    echo
    echo "Missing tools remain and were not skipped. Install required packages or rerun with ignore."
    exit 1
  fi
fi

# Prompt to apply ownership fixes for existing files
echo
if read_yn "Apply fix now (chown root:root on existing non-compliant files)?" "Y"; then
  :
else
  echo "Skipped."
  exit 0
fi

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
    if [[ $SKIP_MISSING -eq 1 ]]; then
      echo "Skip (missing): ${path}"
    else
      echo -e "${RED}Missing (not skipped):${RESET} ${path}"
      fix_fail=1
    fi
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
  elif [[ ${#MISSING[@]} -eq 0 ]]; then
    echo -e "${GREEN}Successfully applied.${RESET}"
  else
    echo -e "${YELLOW}Applied with notes:${RESET} Some tools are missing."
  fi
  exit 0
else
  echo -e "${YELLOW}Applied with warnings:${RESET} Some items may still be non-compliant."
  exit 1
fi
