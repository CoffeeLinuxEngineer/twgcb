#!/bin/bash
# TWGCB-01-008-0187: Ensure SELinux policy is set to targeted (or stricter)
# Target OS: RHEL 8.5

CONFIG_FILE="/etc/selinux/config"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0187: Ensure SELinux policy is set to targeted or stricter"

show_status() {
    echo
    echo "Checking SELinux configuration file: $CONFIG_FILE"
    if [ -f "$CONFIG_FILE" ]; then
        grep -n '^SELINUXTYPE=' "$CONFIG_FILE" | sed 's/^/Line: /'
    else
        echo "(File not found)"
    fi

    echo
    echo "Checking current SELinux policy type:"
    if command -v sestatus >/dev/null 2>&1; then
        sestatus | grep "Loaded policy name" || echo "(Unable to detect current policy)"
    else
        echo "(sestatus command not available)"
    fi
}

check_compliance() {
    if grep -Eq '^SELINUXTYPE=(targeted|mls)$' "$CONFIG_FILE" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

apply_fix() {
    if [ -f "$CONFIG_FILE" ]; then
        sed -ri 's/^SELINUXTYPE=.*/SELINUXTYPE=targeted/' "$CONFIG_FILE" || return 1
    else
        echo -e "${CLR_RED}Config file not found: $CONFIG_FILE${CLR_RESET}"
        return 1
    fi
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: SELinux policy is targeted or stricter.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: SELinux policy is not targeted or stricter.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now (set SELINUXTYPE=targeted)? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
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
