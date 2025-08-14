#!/bin/bash
# TWGCB-01-008-0185: Ensure libselinux package is installed
# Target OS: RHEL 8.5

PACKAGE="libselinux"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0185: Ensure $PACKAGE package is installed"

show_status() {
    echo
    echo "Checking package installation status..."
    if rpm -q "$PACKAGE" &>/dev/null; then
        echo "$PACKAGE: installed"
    else
        echo "$PACKAGE: (Not installed)"
    fi
}

check_compliance() {
    rpm -q "$PACKAGE" &>/dev/null
}

apply_fix() {
    dnf install -y "$PACKAGE"
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: $PACKAGE is installed.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: $PACKAGE is not installed.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now (install $PACKAGE)? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
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
