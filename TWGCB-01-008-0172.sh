#!/bin/bash
# TWGCB-01-008-0172: Ensure auditd records execve system call usage
# Target: RHEL 8.5

C_GREEN="\033[92m"
C_RED="\033[91m"
C_CYAN="\033[96m"
C_OFF="\033[0m"

AUDIT_DIR="/etc/audit/rules.d"
AUDIT_FILE="$AUDIT_DIR/audit.rules"

RULES=(
"-a always,exit -F arch=b32 -F auid!=unset -S execve -C uid!=euid -F key=execpriv"
"-a always,exit -F arch=b64 -F auid!=unset -S execve -C uid!=euid -F key=execpriv"
"-a always,exit -F arch=b32 -F auid!=unset -S execve -C gid!=egid -F key=execpriv"
"-a always,exit -F arch=b64 -F auid!=unset -S execve -C gid!=egid -F key=execpriv"
)

echo -e "TWGCB-01-008-0172: Ensure auditd records execve system call usage\n"

check_compliance() {
    local missing=0
    for r in "${RULES[@]}"; do
        grep -qF -- "$r" "$AUDIT_FILE" 2>/dev/null || missing=1
    done
    return $missing
}

show_status() {
    echo "Checking audit rules in $AUDIT_FILE..."
    if [[ -f "$AUDIT_FILE" ]]; then
        for r in "${RULES[@]}"; do
            if grep -qF -- "$r" "$AUDIT_FILE"; then
                line=$(grep -nF -- "$r" "$AUDIT_FILE" | cut -d: -f1)
                echo "Line: ${line:-?}: $r"
            else
                echo "(Missing) $r"
            fi
        done
    else
        echo "(File not found: $AUDIT_FILE)"
    fi
    echo
}

# ---------- Check phase ----------
show_status
if check_compliance; then
    echo -e "${C_GREEN}Compliant:${C_OFF} execve audit rules are configured."
    exit 0
else
    echo -e "${C_RED}Non-compliant:${C_OFF} one or more execve audit rules are missing."
fi

# ---------- Prompt ----------
while true; do
    echo -n "Apply fix now (append execve audit rules to $AUDIT_FILE and reload)? [Y]es / [N]o / [C]ancel: "
    read -rn1 ans
    echo
    case "$ans" in
        Y|y) break ;;
        N|n) echo "Skipped."; exit 1 ;;
        C|c) echo "Canceled."; exit 2 ;;
        *) echo "Invalid input." ;;
    esac
done

# ---------- Apply ----------
apply_failed=0

if [[ ! -d "$AUDIT_DIR" ]]; then
    mkdir -p "$AUDIT_DIR" || apply_failed=1
fi

if [[ ! -e "$AUDIT_FILE" ]]; then
    touch "$AUDIT_FILE" || apply_failed=1
fi

if [[ $apply_failed -eq 0 ]]; then
    for r in "${RULES[@]}"; do
        grep -qF -- "$r" "$AUDIT_FILE" || echo "$r" >> "$AUDIT_FILE"
    done
    if ! augenrules --load; then
        echo -e "${C_RED}Failed to reload audit rules (augenrules --load).${C_OFF}"
        apply_failed=1
    fi
fi

# ---------- Re-check ----------
echo
show_status
if [[ $apply_failed -eq 0 ]] && check_compliance; then
    echo -e "${C_GREEN}Successfully applied.${C_OFF}"
    echo "Note: If auditd is in immutable mode (-e 2), a reboot is required for new rules to take effect."
    exit 0
else
    echo -e "${C_RED}Failed to apply.${C_OFF}"
    exit 3
fi
