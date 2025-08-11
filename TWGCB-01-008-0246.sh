#!/bin/bash
# TWGCB-01-008-0246
# Mask iptables and ip6tables when using firewalld.
# Target OS: Red Hat Enterprise Linux 8.5
# Notes:
# - No Chinese in code.
# - Bright green/red ANSI colors for compliant/non-compliant and success/failure.
# - Single script does check + optional apply with Y/N/C prompt.
#
# Exit codes:
#   0 = compliant or applied successfully
#   1 = non-compliant and skipped / failed to apply
#   2 = canceled by user
#   3 = invalid input (should not happen due to loop)

set -o pipefail

SERVICES=("iptables.service" "ip6tables.service")

# Colors
GREEN="\e[92m"
RED="\e[91m"
RESET="\e[0m"

has_systemctl() {
    command -v systemctl >/dev/null 2>&1
}

unit_exists() {
    local svc="$1"
    systemctl list-unit-files "$svc" --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "$svc"
}

enabled_state() {
    local svc="$1"
    systemctl is-enabled "$svc" 2>/dev/null || echo "unknown"
}

active_state() {
    local svc="$1"
    systemctl is-active "$svc" 2>/dev/null || echo "unknown"
}

show_state_one() {
    local svc="$1"
    if unit_exists "$svc"; then
        printf "  %-15s  present  enabled=%-10s active=%s\n" "$svc" "$(enabled_state "$svc")" "$(active_state "$svc")"
    else
        printf "  %-15s  not-present\n" "$svc"
    fi
}

show_state() {
    echo "State overview:"
    for s in "${SERVICES[@]}"; do
        show_state_one "$s"
    done
}

is_one_compliant() {
    local svc="$1"
    if ! unit_exists "$svc"; then
        return 0
    fi
    local en act
    en="$(enabled_state "$svc")"
    act="$(active_state "$svc")"
    [[ "$en" == "masked" ]] && [[ "$act" != "active" ]]
}

check_compliance() {
    has_systemctl || return 1
    for s in "${SERVICES[@]}"; do
        if ! is_one_compliant "$s"; then
            return 1
        fi
    done
    return 0
}

apply_fix() {
    has_systemctl || return 1
    local ok=0
    for s in "${SERVICES[@]}"; do
        if unit_exists "$s"; then
            if systemctl --now mask "$s"; then
                ok=1
            else
                ok=0
            fi
        fi
    done
    return $ok
}

# --- Main ---
echo "TWGCB-01-008-0246: Disable and mask iptables/ip6tables"
echo

if ! has_systemctl; then
    echo -e "${RED}Non-compliant: 'systemctl' command is not available.${RESET}"
    echo "Hint: This script targets systemd-based systems."
    exit 1
fi

echo "Checking current service state..."
show_state
echo

if check_compliance; then
    echo -e "${GREEN}Compliant: iptables and ip6tables are masked and not active (or units not present).${RESET}"
    exit 0
else
    echo -e "${RED}Non-compliant: One or both services are not masked and stopped.${RESET}"
fi

while true; do
    echo -n "Apply fix now (run 'systemctl --now mask iptables ip6tables')? [Y]es / [N]o / [C]ancel: "
    read -rsn1 key
    echo
    case "$key" in
        [Yy])
            if apply_fix && check_compliance; then
                echo
                echo "Resulting state:"
                show_state
                echo -e "${GREEN}Successfully applied.${RESET}"
                exit 0
            else
                echo
                echo "Resulting state:"
                show_state
                echo -e "${RED}Failed to apply.${RESET}"
                exit 1
            fi
            ;;
        [Nn])
            echo "Skipped."
            exit 1
            ;;
        [Cc])
            echo "Canceled."
            exit 2
            ;;
        *)
            echo "Invalid input."
            ;;
    esac
done
