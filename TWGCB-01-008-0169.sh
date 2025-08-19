#!/bin/bash
# TWGCB-01-008-0169: Ensure auditd records chacl command usage
# Target: RHEL 8.5

C_GREEN="\033[92m"
C_RED="\033[91m"
C_CYAN="\033[96m"
C_OFF="\033[0m"

AUDIT_DIR="/etc/audit/rules.d"
AUDIT_FILE="$AUDIT_DIR/audit.rules"

UID_MIN=$(awk '/^\s*UID_MIN/{print $2}' /etc/login.defs)
[[ -z "$UID_MIN" ]] && UID_MIN=1000

RULE="-a always,exit -F path=/usr/bin/chacl -F perm=x -F auid>=$UID_MIN -F auid!=4294967295 -k perm_chng"

echo -e "TWGCB-01-008-0169: Ensure auditd records chacl command usage\n"

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

is_immutable() {
    local s
    s=$(auditctl -s 2>/dev/null | grep -Eo 'enabled[[:space:]]+[0-9]+' | awk '{print $2}')
    [[ "$s" == "2" ]]
}

ensure_auditd_running() {
    systemctl is-active --quiet auditd && return 0
    systemctl start auditd 2>/dev/null
    systemctl is-active --quiet auditd
}

# ---------- Check phase ----------
show_status
if check_compliance; then
    echo -e "${C_GREEN}Compliant:${C_OFF} chacl command usage is being recorded by auditd."
    exit 0
else
    echo -e "${C_RED}Non-compliant:${C_OFF} chacl audit rule is missing."
fi

# ---------- Prompt ----------
while true; do
    echo -n "Apply fix now (append audit rule for chacl and reload)? [Y]es / [N]o / [C]ancel: "
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

[[ -d "$AUDIT_DIR" ]] || mkdir -p "$AUDIT_DIR" || apply_failed=1
[[ -e "$AUDIT_FILE" ]] || touch "$AUDIT_FILE" || apply_failed=1

if [[ $apply_failed -eq 0 ]]; then
    grep -qF -- "$RULE" "$AUDIT_FILE" || echo "$RULE" >> "$AUDIT_FILE"
fi

if [[ $apply_failed -eq 0 ]]; then
    if ! augenrules --load; then
        if is_immutable; then
            echo
            show_status
            echo -e "${C_GREEN}Applied to disk (pending reboot).${C_OFF}"
            echo "Note: auditd is in immutable mode (-e 2). Reboot is required for new rules to take effect."
            exit 0
        fi
        if ensure_auditd_running && augenrules --load; then
            :
        else
            apply_failed=1
            echo -e "${C_RED}Failed to reload audit rules (augenrules --load).${C_OFF}"
        fi
    fi
fi

# ---------- Re-check ----------
echo
show_status
if [[ $apply_failed -eq 0 ]] && check_compliance; then
    echo -e "${C_GREEN}Successfully applied.${C_OFF}"
    exit 0
else
    echo -e "${C_RED}Failed to apply.${C_OFF}"
    exit 3
fi
