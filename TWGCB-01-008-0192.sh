#!/bin/bash
# TWGCB-01-008-0192: Enable and start crond service
# Target OS: RHEL 8.5

SERVICE="crond"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0192: Enable and start crond service"

show_status() {
    echo
    echo "Checking current service state..."
    echo "State overview:"
    systemctl list-unit-files | grep -E "^$SERVICE\.service" || echo "  unit: not present"
    systemctl is-enabled "$SERVICE" 2>/dev/null || echo "  is-enabled: unknown"
    systemctl is-active "$SERVICE" 2>/dev/null || echo "  is-active : unknown"
}

check_compliance() {
    systemctl is-enabled "$SERVICE" &>/dev/null &&     systemctl is-active "$SERVICE" &>/dev/null
}

apply_fix() {
    systemctl --now enable "$SERVICE"
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: $SERVICE is enabled and active.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: $SERVICE is not enabled and active.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now (run 'systemctl --now enable $SERVICE')? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
    read -rsn1 key
    echo
    case "$key" in
        [Yy])
            [ "$EUID" -ne 0 ] && echo -e "${CLR_RED}Failed to apply: please run as root.${CLR_RESET}" && exit 1
            apply_fix
            show_status
            if check_compliance; then
                echo -e "${CLR_GREEN}Successfully applied${CLR_RESET}"
                exit 0
            else
                echo -e "${CLR_RED}Failed to apply${CLR_RESET}"
                exit 1
            fi
            ;;
        [Nn]) echo "Skipped."; exit 1 ;;
        [Cc]) echo "Canceled."; exit 2 ;;
        *) echo "Invalid input." ;;
    esac
done
