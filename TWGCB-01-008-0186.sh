#!/bin/bash
# TWGCB-01-008-0186: Ensure SELinux is enabled in bootloader (GRUB)
# Target OS: RHEL 8.5

GRUB_FILE="/etc/default/grub"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0186: Ensure SELinux is enabled in bootloader (GRUB)"

show_status() {
    echo
    echo "Checking GRUB configuration file: $GRUB_FILE"
    if [ -f "$GRUB_FILE" ]; then
        grep -n 'GRUB_CMDLINE_LINUX' "$GRUB_FILE" | sed 's/^/Line: /'
    else
        echo "(File not found)"
    fi

    echo
    echo "Checking for 'selinux=0' or 'enforcing=0' in current GRUB config:"
    if grep -Eq '(selinux=0|enforcing=0)' "$GRUB_FILE" 2>/dev/null; then
        echo "Found disablers in $GRUB_FILE"
    else
        echo "No disablers found in $GRUB_FILE"
    fi
}

check_compliance() {
    if [ -f "$GRUB_FILE" ]; then
        ! grep -Eq '(selinux=0|enforcing=0)' "$GRUB_FILE"
    else
        return 1
    fi
}

apply_fix() {
    if [ ! -f "$GRUB_FILE" ]; then
        echo -e "${CLR_RED}Config file not found: $GRUB_FILE${CLR_RESET}"
        return 1
    fi

    # Remove selinux=0 and enforcing=0 from GRUB_CMDLINE_LINUX* lines
    sed -ri 's/(selinux=0|enforcing=0)\s*//g' "$GRUB_FILE"

    # Rebuild grub config
    GRUB_CFG_PATH=$(dirname "$(find /boot -type f \( -name 'grubenv' -o -name 'grub.conf' -o -name 'grub.cfg' \) -exec grep -Pl '^(\s*(kernelopts=|linux|kernel))' {} \; )")/grub.cfg
    if [ -n "$GRUB_CFG_PATH" ] && [ -d "$(dirname "$GRUB_CFG_PATH")" ]; then
        grub2-mkconfig -o "$GRUB_CFG_PATH"
    else
        echo -e "${CLR_RED}Failed to determine grub.cfg path. Please update grub manually.${CLR_RESET}"
        return 1
    fi
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: No SELinux-disabling parameters in GRUB config.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: GRUB config contains SELinux-disabling parameters.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now (remove selinux=0/enforcing=0 and update grub)? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
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
