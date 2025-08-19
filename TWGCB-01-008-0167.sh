#!/bin/bash
# TWGCB-01-008-0167: Ensure auditd records open_by_handle_at system call usage
# Target: RHEL 8.5
# Rules required:
#   -a always,exit -F arch=b32 -S open_by_handle_at -F exit=-EPERM  -F auid>=UID_MIN -F auid!=4294967295 -k perm_access
#   -a always,exit -F arch=b64 -S open_by_handle_at -F exit=-EPERM  -F auid>=UID_MIN -F auid!=4294967295 -k perm_access
#   -a always,exit -F arch=b32 -S open_by_handle_at -F exit=-EACCES -F auid>=UID_MIN -F auid!=4294967295 -k perm_access
#   -a always,exit -F arch=b64 -S open_by_handle_at -F exit=-EACCES -F auid>=UID_MIN -F auid!=4294967295 -k perm_access

C_GREEN="\033[92m"
C_RED="\033[91m"
C_CYAN="\033[96m"
C_OFF="\033[0m"

AUDIT_DIR="/etc/audit/rules.d"
AUDIT_FILE="$AUDIT_DIR/audit.rules"

# Determine UID_MIN dynamically (fallback to 1000)
UID_MIN=$(awk '/^\s*UID_MIN/{print $2}' /etc/login.defs)
[[ -z "$UID_MIN" ]] && UID_MIN=1000

RULES=(
"-a always,exit -F arch=b32 -S open_by_handle_at -F exit=-EPERM -F auid>=$UID_MIN -F auid!=4294967295 -k perm_access"
"-a always,exit -F arch=b64 -S open_by_handle_at -F exit=-EPERM -F auid>=$UID_MIN -F auid!=4294967295 -k perm_access"
"-a always,exit -F arch=b32 -S open_by_handle_at -F exit=-EACCES -F auid>=$UID_MIN -F auid!=4294967295 -k perm_access"
"-a always,exit -F arch=b64 -S open_by_handle_at -F exit=-EACCES -F auid>=$UID_MIN -F auid!=4294967295 -k perm_access"
)

echo -e "TWGCB-01-008-0167: Ensure auditd records open_by_handle_at system call usage\n"

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
                line=$(grep -nF -- "$r" "$AUDIT_FILE" | head -n1 | cut -d: -f1)
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

is_immutable() {
    # returns 0 if auditd is in immutable mode (enabled 2)
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
    echo -e "${C_GREEN}Compliant:${C_OFF} open_by_handle_at audit rules are configured."
    exit 0
else
    echo -e "${C_RED}Non-compliant:${C_OFF} one or more open_by_handle_at audit rules are missing."
fi

# ---------- Prompt ----------
while true; do
    echo -n "Apply fix now (append rules and reload)? [Y]es / [N]o / [C]ancel: "
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

# Ensure directory and file exist
[[ -d "$AUDIT_DIR" ]] || mkdir -p "$AUDIT_DIR" || apply_failed=1
[[ -e "$AUDIT_FILE" ]] || touch "$AUDIT_FILE" || apply_failed=1

# Append any missing rules
if [[ $apply_failed -eq 0 ]]; then
    for r in "${RULES[@]}"; do
        grep -qF -- "$r" "$AUDIT_FILE" || echo "$r" >> "$AUDIT_FILE"
    done
fi

# Try to load rules
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
