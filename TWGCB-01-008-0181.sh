#!/bin/bash
# TWGCB-01-008-0181: Ensure journald compresses large log files
# Target OS: RHEL 8.5

CONFIG_FILE="/etc/systemd/journald.conf"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0181: Ensure journald compresses large log files"

show_status() {
    echo
    echo "Checking file: $CONFIG_FILE"
    if [ -f "$CONFIG_FILE" ]; then
        grep -n '^[[:space:]]*Compress=' "$CONFIG_FILE" | sed 's/^/Line: /'
    else
        echo "(File not found)"
    fi
    echo
    echo "Current active setting from systemd:"
    systemd-analyze cat-config systemd/journald.conf | grep -i '^Compress=' || echo "(No Compress setting found)"
}

check_compliance() {
    grep -Eq '^[[:space:]]*Compress=yes' "$CONFIG_FILE" 2>/dev/null
}

apply_fix() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${CLR_YELLOW}File not found, creating: $CONFIG_FILE${CLR_RESET}"
        touch "$CONFIG_FILE" || return 1
    fi

    if grep -Eq '^[[:space:]]*Compress=' "$CONFIG_FILE"; then
        sed -ri 's/^[[:space:]]*Compress=.*/Compress=yes/' "$CONFIG_FILE"
    else
        echo "Compress=yes" >> "$CONFIG_FILE"
    fi

    systemctl restart systemd-journald
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: journald is set to compress large logs.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: journald is not set to compress large logs.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now (set Compress=yes and restart systemd-journald)? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
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
