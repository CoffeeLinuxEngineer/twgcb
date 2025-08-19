#!/bin/bash
# TWGCB-01-008-0175: Ensure rsyslog service is enabled and running
# Target: RHEL 8.5

C_GREEN="\033[92m"
C_RED="\033[91m"
C_CYAN="\033[96m"
C_OFF="\033[0m"

echo -e "TWGCB-01-008-0175: Ensure rsyslog service is enabled and running\n"

check_compliance() {
    systemctl is-enabled rsyslog &>/dev/null || return 1
    systemctl is-active rsyslog &>/dev/null || return 1
    return 0
}

get_unit_state() {
    systemctl list-unit-files rsyslog.service --no-legend 2>/dev/null | awk '{print $2}'
}

show_status() {
    echo "Checking current service state..."
    local unit_state enabled_state active_state
    unit_state=$(get_unit_state)
    enabled_state=$(systemctl is-enabled rsyslog 2>&1)
    active_state=$(systemctl is-active rsyslog 2>&1)

    echo "State overview:"
    echo "  unit: ${unit_state:-unknown}"
    echo "  is-enabled: ${enabled_state:-unknown}"
    echo "  is-active : ${active_state:-unknown}"
    echo
}

# ---------- Check phase ----------
show_status
if check_compliance; then
    echo -e "${C_GREEN}Compliant:${C_OFF} rsyslog is enabled and running."
    exit 0
else
    echo -e "${C_RED}Non-compliant:${C_OFF} rsyslog is not enabled and active."
fi

# ---------- Prompt ----------
while true; do
    echo -n "Apply fix now (unmask if needed, then 'systemctl --now enable rsyslog')? [Y]es / [N]o / [C]ancel: "
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

# If masked, unmask first
unit_state_now=$(get_unit_state)
if [[ "$unit_state_now" == "masked" ]]; then
    if ! systemctl unmask rsyslog; then
        echo -e "${C_RED}Failed to unmask rsyslog.${C_OFF}"
        apply_failed=1
    fi
fi

# Enable and start
if [[ $apply_failed -eq 0 ]]; then
    if ! systemctl --now enable rsyslog; then
        echo -e "${C_RED}Failed to enable/start rsyslog.${C_OFF}"
        apply_failed=1
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
