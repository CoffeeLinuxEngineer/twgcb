#!/bin/bash
# TWGCB-01-008-0178: Ensure /var/log/messages file ownership
# Target OS: RHEL 8.5

TARGET_FILE="/var/log/messages"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0178: Ensure /var/log/messages file ownership"

get_owner_group() {
    [ -e "$1" ] && stat -c '%U:%G' "$1" 2>/dev/null || echo ""
}

is_owned_by_root() {
    local og
    [ -e "$1" ] || return 1
    og=$(get_owner_group "$1")
    [ "$og" = "root:root" ]
}

show_status() {
    echo
    echo "Checking file:"
    echo "  - $TARGET_FILE"
    echo
    echo "Check results:"
    if [ -f "$TARGET_FILE" ]; then
        og=$(get_owner_group "$TARGET_FILE")
        is_owned_by_root "$TARGET_FILE" && echo "$TARGET_FILE: owner $og (OK)" || echo "$TARGET_FILE: owner ${og:-unknown} (Not root:root)"
    else
        echo "$TARGET_FILE: (Not present)"
    fi
}

check_compliance() {
    [ -f "$TARGET_FILE" ] && is_owned_by_root "$TARGET_FILE"
}

apply_fix() {
    [ -f "$TARGET_FILE" ] || return 1
    chown root:root "$TARGET_FILE" || return 1
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: /var/log/messages owned by root:root.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: /var/log/messages ownership incorrect or file missing.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now (set owner to root:root)? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
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
