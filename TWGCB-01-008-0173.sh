#!/bin/bash
# TWGCB-01-008-0173: Ensure auditd immutable mode is enabled
# Target: RHEL 8.5

C_GREEN="\033[92m"
C_RED="\033[91m"
C_CYAN="\033[96m"
C_OFF="\033[0m"

AUDIT_DIR="/etc/audit/rules.d"
AUDIT_FILE="$AUDIT_DIR/99-final.rules"

echo -e "TWGCB-01-008-0173: Ensure auditd immutable mode is enabled\n"

check_compliance() {
    local output
    output=$(grep -h "^[[:space:]]*[^#]" "$AUDIT_DIR"/*.rules 2>/dev/null | grep -E "(-e[[:space:]]*2|--loginuid-immutable)")
    echo "$output" | grep -q -- "-e[[:space:]]*2" || return 1
    echo "$output" | grep -q -- "--loginuid-immutable" || return 1
    return 0
}

show_status() {
    echo "Checking audit rules..."
    if [[ -d "$AUDIT_DIR" ]]; then
        grep -Hn "^[[:space:]]*[^#]" "$AUDIT_DIR"/*.rules 2>/dev/null | grep -E "(-e[[:space:]]*2|--loginuid-immutable)" \
            | sed -E 's/^([^:]+):([0-9]+):/File: \1 Line: \2:/' || echo "(No matching setting found)"
    else
        echo "(Audit rules directory not found)"
    fi
    echo
}

# ---------- Check phase ----------
show_status
if check_compliance; then
    echo -e "${C_GREEN}Compliant:${C_OFF} auditd immutable mode is enabled."
    exit 0
else
    echo -e "${C_RED}Non-compliant:${C_OFF} auditd immutable mode is missing."
fi

# ---------- Prompt ----------
while true; do
    echo -n "Apply fix now (add '-e 2' and '--loginuid-immutable' to $AUDIT_FILE)? [Y]es / [N]o / [C]ancel: "
    read -r ans
    case "$ans" in
        Y|y) break ;;
        N|n) echo "Skipped."; exit 1 ;;
        C|c) echo "Canceled."; exit 2 ;;
        *) echo "Invalid input." ;;
    esac
done

# ---------- Apply ----------
apply_failed=0

# Ensure directory exists
if [[ ! -d "$AUDIT_DIR" ]]; then
    mkdir -p "$AUDIT_DIR" || apply_failed=1
fi

# Ensure target file exists
if [[ ! -e "$AUDIT_FILE" ]]; then
    touch "$AUDIT_FILE" || apply_failed=1
fi

if [[ $apply_failed -eq 0 ]]; then
    # Remove existing occurrences
    sed -i '/^-e[[:space:]]*2$/d' "$AUDIT_FILE"
    sed -i '/^--loginuid-immutable$/d' "$AUDIT_FILE"
    # Append compliant lines
    echo "-e 2" >> "$AUDIT_FILE"
    echo "--loginuid-immutable" >> "$AUDIT_FILE"
else
    echo -e "${C_RED}Failed to prepare $AUDIT_FILE.${C_OFF}"
fi

# ---------- Re-check ----------
echo
show_status
if [[ $apply_failed -eq 0 ]] && check_compliance; then
    echo -e "${C_GREEN}Successfully applied.${C_OFF}"
    echo "Note: Changes take effect after reboot."
    exit 0
else
    echo -e "${C_RED}Failed to apply.${C_OFF}"
    exit 3
fi
