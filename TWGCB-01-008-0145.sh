#!/bin/bash
# TWGCB-01-008-0145 v2: Protect audit tools integrity (AIDE rules)
# Fixes:
#   - Avoids sed/regex escaping entirely when matching paths (uses awk, robust for '/usr/...').
#   - Treats empty <Enter> at the prompt as "Y" for convenience.
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
# Tokens to verify (order-insensitive; extra tokens allowed)
TOKENS=(p i n u g s b acl xattrs sha512)

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
  # Prints lines beginning with the given path (ignoring leading whitespace), with line numbers
  local file="$1" path="$2"
  if [[ -r "$file" ]]; then
    awk -v p="$path" '
      {
        line=$0
        sub(/^[[:space:]]*/,"", line)      # trim leading spaces
        # strip trailing comment for display test but keep original line output
        disp=$0
        if (substr(line,1,length(p))==p) {
          printf "Line: %d:%s\n", NR, disp
        }
      }
    ' "$file"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      # If awk errored, say so; otherwise if no output, show "No matching line..."
      echo "(No matching line found)"
    else
      # Check if any lines printed; if not, note it
      if ! awk -v p="$path" '
          {
            line=$0; sub(/^[[:space:]]*/,"", line)
            if (substr(line,1,length(p))==p) { found=1 }
          }
          END { exit(found?0:1) }
        ' "$file"; then
        echo "(No matching line found)"
      fi
    fi
  else
    if [[ -e "$file" ]]; then
      echo "(Permission denied reading ${file})"
    else
      echo "(File not found: ${file})"
    fi
  fi
}

# Return 0 if a compliant line exists for the given path
rule_exists() {
  local file="$1" path="$2"
  [[ -r "$file" ]] || return 1
  awk -v p="$path" '
    function has_token(rest, t,  re) {
      # token boundary: start or +/space before and +/space/end after
      re = "(^|[+[:space:]])" t "([+[:space:]]|$)"
      return (rest ~ re)
    }
    /^[[:space:]]*#/ {next}
    {
      line=$0
      # Remove trailing comment
      sub(/[[:space:]]*#.*/,"", line)
      # Trim leading whitespace
      sub(/^[[:space:]]*/,"", line)
      if (substr(line,1,length(p))==p) {
        rest=substr(line,length(p)+1)
        # Verify all required tokens exist
        ok=1
        split("p i n u g s b acl xattrs sha512", req, " ")
        for (i in req) {
          if (!has_token(rest, req[i])) { ok=0; break }
        }
        if (ok) { print "OK"; exit 0 }
      }
    }
    END { if (!ok) exit 1 }
  ' "$file" >/dev/null
}

missing=()

for p in "${TOOLS[@]}"; do
  echo "Required: ${p} ${ATTR_CANON}"
  show_matches_with_lines "$AIDE_CONF" "$p"
done
echo

if [[ -f "$AIDE_CONF" ]]; then
  for p in "${TOOLS[@]}"; do
    if ! rule_exists "$AIDE_CONF" "$p"; then
      missing+=("$p")
    fi
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
# Treat empty input as Yes
IFS= read -rsn1 ans; echo
[[ -z "${ans:-}" ]] && ans="Y"
case "$ans" in
  [Yy]) ;;
  [Nn]) echo "Skipped."; exit 0 ;;
  [Cc]) echo "Canceled."; exit 2 ;;
  *)    echo "Invalid choice. Aborted."; exit 2 ;;
esac

# Apply: ensure file exists and is writable
if [[ ! -e "$AIDE_CONF" ]]; then
  # Attempt to create
  if ! touch "$AIDE_CONF" 2>/dev/null; then
    echo -e "${RED}Failed to apply:${RESET} Unable to create ${AIDE_CONF} (permission denied?)."
    exit 1
  fi
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
