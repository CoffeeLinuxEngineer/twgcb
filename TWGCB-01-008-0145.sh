#!/bin/bash
# TWGCB-01-008-0145: Protect audit tools integrity with AIDE
# Target OS: RHEL 8.5
# Baseline (add these rules to /etc/aide.conf):
#   /usr/sbin/auditctl       p+i+n+u+g+s+b+acl+xattrs+sha512
#   /usr/sbin/auditd         p+i+n+u+g+s+b+acl+xattrs+sha512
#   /usr/sbin/ausearch       p+i+n+u+g+s+b+acl+xattrs+sha512
#   /usr/sbin/aureport       p+i+n+u+g+s+b+acl+xattrs+sha512
#   /usr/sbin/autrace        p+i+n+u+g+s+b+acl+xattrs+sha512
#   /usr/sbin/audisp-remote  p+i+n+u+g+s+b+acl+xattrs+sha512
#   /usr/sbin/audisp-syslog  p+i+n+u+g+s+b+acl+xattrs+sha512
#   /usr/sbin/augenrules     p+i+n+u+g+s+b+acl+xattrs+sha512
# Behavior:
#   - Checks /etc/aide.conf for each rule.
#   - Prints matching lines with 'Line: ' prefixed line numbers.
#   - Interactively appends any missing rules (under a comment header) and reminds to re-init AIDE DB.
# Notes:
#   - No Chinese in code.

set -u -o pipefail

# Colors (bright)
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; RESET="\e[0m"
ITEM_ID="TWGCB-01-008-0145"
TITLE="Protect audit tools integrity (AIDE rules)"
AIDE_CONF="/etc/aide.conf"

declare -a TOOLS=(
  "/usr/sbin/auditctl"
  "/usr/sbin/auditd"
  "/usr/sbin/ausearch"
  "/usr/sbin/aureport"
  "/usr/sbin/autrace"
  "/usr/sbin/audisp-remote"
  "/usr/sbin/audisp-syslog"
  "/usr/sbin/augenrules"
)
ATTR_CANON="p+i+n+u+g+s+b+acl+xattrs+sha512"
# Tokens we must see on the same line (order-insensitive; extra tokens allowed)
read -r -a TOKENS <<< "p i n u g s b acl xattrs sha512"

# Must be root to modify config
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}This script must run as root (try: sudo $0).${RESET}"
  exit 1
fi

echo -e "${CYAN}${ITEM_ID}: ${TITLE}${RESET}"
echo
echo "Checking ${AIDE_CONF}..."
echo "Check results:"

show_matches_with_lines() {
  local file="$1" path="$2"
  if [[ -r "$file" ]]; then
    # Show any lines beginning with the path (ignore leading whitespace)
    local out
    out="$(grep -nE "^[[:space:]]*$(printf '%s' "$path" | sed -E 's/[.[\]{}()*+?^$|\\/]/\\&/g')[[:space:]]" "$file" 2>/dev/null | sed -E 's/^/Line: /')"
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

# return 0 if a compliant line exists for the given path
rule_exists() {
  local file="$1" path="$2"
  [[ -r "$file" ]] || return 1
  # Iterate candidate lines that start with the path
  while IFS= read -r cand; do
    # Strip line number if provided
    local line="${cand#*:}"
    # Remove comments after '#'
    line="${line%%#*}"
    # Ensure path is present at line start (ignoring leading spaces)
    if ! printf '%s\n' "$line" | grep -qE "^[[:space:]]*$(printf '%s' "$path" | sed -E 's/[.[\]{}()*+?^$|\\/]/\\&/g')([[:space:]]|$)"; then
      continue
    fi
    # Now require each token to exist as a '+'-separated token (order-insensitive). Allow extra tokens.
    local ok=1
    for t in "${TOKENS[@]}"; do
      printf '%s\n' "$line" | grep -qE "(^|[[:space:]+])${t}([[:space:]+]|$)" || { ok=0; break; }
    done
    if [[ $ok -eq 1 ]]; then
      return 0
    fi
  done < <(grep -nE "^[[:space:]]*$(printf '%s' "$path" | sed -E 's/[.[\]{}()*+?^$|\\/]/\\&/g')[[:space:]]" "$file" 2>/dev/null || true)
  return 1
}

missing=()

for p in "${TOOLS[@]}"; do
  echo "Required: ${p} ${ATTR_CANON}"
  show_matches_with_lines "$AIDE_CONF" "$p"
done
echo

if [[ -f "$AIDE_CONF" ]]; then
  for p in "${TOOLS[@]}"; do
    rule_exists "$AIDE_CONF" "$p" || missing+=("$p")
  done
else
  # If file doesn't exist, treat all as missing
  missing=("${TOOLS[@]}")
fi

if [[ ${#missing[@]} -eq 0 ]]; then
  echo -e "${GREEN}Compliant:${RESET} All AIDE rules for audit tools are present."
  exit 0
fi

echo -e "${RED}Non-compliant:${RESET} Missing ${#missing[@]} required rule(s):"
for p in "${missing[@]}"; do
  echo "  - ${p} ${ATTR_CANON}"
done

echo
echo -n "Apply fix now (append missing rules to ${AIDE_CONF})? [Y]es / [N]o / [C]ancel: "
read -rsn1 ans; echo
case "$ans" in
  [Yy]) ;;
  [Nn]) echo "Skipped."; exit 0 ;;
  [Cc]) echo "Canceled."; exit 2 ;;
  *)    echo "Invalid choice. Aborted."; exit 2 ;;
esac

# Apply: ensure file exists and is writable
if [[ ! -e "$AIDE_CONF" ]]; then
  # Attempt to create
  touch "$AIDE_CONF" 2>/dev/null || {
    echo -e "${RED}Failed to apply:${RESET} Unable to create ${AIDE_CONF} (permission denied?)."
    exit 1
  }
fi

# Backup
ts="$(date -u +'%Y%m%dT%H%M%SZ')"
cp -a "$AIDE_CONF" "${AIDE_CONF}.bak.${ts}" 2>/dev/null || {
  echo -e "${YELLOW}Warning:${RESET} Could not create backup ${AIDE_CONF}.bak.${ts}."
}

# Append missing rules under a header
{
  echo
  echo "# ${ITEM_ID} — Audit Tools"
  for p in "${missing[@]}"; do
    echo "${p} ${ATTR_CANON}"
  done
} >> "$AIDE_CONF" 2>/dev/null || {
  echo -e "${RED}Failed to apply:${RESET} Permission denied writing ${AIDE_CONF}."
  exit 1
}

echo -e "${GREEN}Rules appended to ${AIDE_CONF}.${RESET}"
echo
echo -e "${YELLOW}Note:${RESET} Remember to (re)initialize the AIDE database so these rules take effect:"
echo "  aide --init"
echo "Then replace the database (paths vary by distro), e.g.:"
echo "  mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz"
echo
echo "Re-checking ${AIDE_CONF}..."
for p in "${TOOLS[@]}"; do
  echo "Required: ${p} ${ATTR_CANON}"
  show_matches_with_lines "$AIDE_CONF" "$p"
done

echo -e "${GREEN}Successfully applied.${RESET}"
exit 0
