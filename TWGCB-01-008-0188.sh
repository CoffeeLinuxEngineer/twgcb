#!/bin/bash
# TWGCB-01-008-0188: Ensure SELinux is enabled and in enforcing mode
# Target OS: RHEL 8.5

CONFIG_FILE="/etc/selinux/config"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0188: Ensure SELinux is enabled and enforcing"

show_status() {
    echo
    echo "Checking SELinux configuration file: $CONFIG_FILE"
    if [ -f "$CONFIG_FILE" ]; then
        grep -n '^SELINUX=' "$CONFIG_FILE" | sed 's/^/Line: /'
    else
        echo "(File not found)"
    fi

    echo
    echo "Checking current SELinux mode:"
    if command -v getenforce >/dev/null 2>&1; then
        getenforce 2>/dev/null || echo "(getenforce command failed)"
    else
        echo "(getenforce command not available)"
    fi
}

check_compliance() {
    # File check
    grep -Eq '^SELINUX=enforcing' "$CONFIG_FILE" 2>/dev/null || return 1
    # Runtime check
    [ "$(getenforce 2>/dev/null)" = "Enforcing" ] || return 1
    return 0
}

apply_fix() {
    # Update config file
    if [ -f "$CONFIG_FILE" ]; then
        sed -ri 's/^SELINUX=.*/SELINUX=enforcing/' "$CONFIG_FILE" || return 1
    else
        echo -e "${CLR_RED}Config file not found: $CONFIG_FILE${CLR_RESET}"
        return 1
    fi

    # Set runtime mode if possible
    if command -v setenforce >/dev/null 2>&1; then
        setenforce 1 2>/dev/null || true
    fi
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: SELinux is enabled and enforcing.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: SELinux is not set to enforcing.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now (set SELINUX=enforcing and run setenforce 1)? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
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
