#!/bin/bash
# TWGCB-01-008-0250
# Disable and mask firewalld when using nftables.
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

SERVICE="firewalld.service"

# Colors
GREEN="\e[92m"
RED="\e[91m"
RESET="\e[0m"

has_systemctl() {
    command -v systemctl >/dev/null 2>&1
}

unit_exists() {
    # Returns 0 if the unit file exists (installed), else 1
    systemctl list-unit-files "$SERVICE" --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "$SERVICE"
}

enabled_state() {
    systemctl is-enabled "$SERVICE" 2>/dev/null || echo "unknown"
}

active_state() {
    systemctl is-active "$SERVICE" 2>/dev/null || echo "unknown"
}

show_state() {
    echo "State overview:"
    if unit_exists; then
        echo "  unit: present"
        echo "  is-enabled: $(enabled_state)"
        echo "  is-active : $(active_state)"
    else
        echo "  unit: not present"
        # is-enabled/is-active would be irrelevant if the unit is missing
    fi
}

check_compliance() {
    # Compliant if:
    # - unit does not exist, OR
    # - unit is masked AND not active
    if ! has_systemctl; then
        return 1
    fi

    if ! unit_exists; then
        return 0
    fi

    local en act
    en="$(enabled_state)"
    act="$(active_state)"

    [[ "$en" == "masked" ]] && [[ "$act" != "active" ]]
}

apply_fix() {
    # Mask and stop the service now (idempotent)
    has_systemctl || return 1
    unit_exists || return 0
    systemctl --now mask "$SERVICE"
}

# --- Main ---
echo "TWGCB-01-008-0250: Disable and mask firewalld"
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
    echo -e "${GREEN}Compliant: firewalld is masked and not active (or unit not present).${RESET}"
    exit 0
else
    echo -e "${RED}Non-compliant: firewalld is not masked and stopped.${RESET}"
fi

while true; do
    echo -n "Apply fix now (run 'systemctl --now mask firewalld')? [Y]es / [N]o / [C]ancel: "
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
