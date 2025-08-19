#!/bin/bash
# TWGCB-01-008-0171: Ensure Pam_Faillock log file is recorded by auditd
# Target: RHEL 8.5

C_GREEN="\033[92m"
C_RED="\033[91m"
C_CYAN="\033[96m"
C_OFF="\033[0m"

AUDIT_DIR="/etc/audit/rules.d"
AUDIT_FILE="$AUDIT_DIR/audit.rules"

RULE='-w /var/log/faillock -p wa -k logins'

echo -e "TWGCB-01-008-0171: Ensure Pam_Faillock log file is recorded by auditd\n"

check_compliance() {
    grep -qF -- "$RULE" "$AUDIT_FILE" 2>/dev/null
}

show_status() {
    echo "Checking audit rules in $AUDIT_FILE..."
    if [[ -f "$AUDIT_FILE" ]]; then
        if grep -qF -- "$RULE" "$AUDIT_FILE"; then
            line=$(grep -nF -- "$RULE" "$AUDIT_FILE" | cut -d: -f1)
            echo "Line: ${line:-?}: $RULE"
        else
            echo "(Missing) $RULE"
        fi
    else
        echo "(File not found: $AUDIT_FILE)"
    fi
    echo
}

# ---------- Check phase ----------
show_status
if check_compliance; then
    echo -e "${C_GREEN}Compliant:${C_OFF} Pam_Faillock log file is being recorded by auditd."
    exit 0
else
    echo -e "${C_RED}Non-compliant:${C_OFF} Pam_Faillock log file rule is missing."
fi

# ---------- Prompt ----------
while true; do
    echo -n "Apply fix now (append audit rule for /var/log/faillock and reload)? [Y]es / [N]o / [C]ancel: "
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
    if ! grep -qF -- "$RULE" "$AUDIT_FILE"; then
        echo "$RULE" >> "$AUDIT_FILE"
    fi
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
