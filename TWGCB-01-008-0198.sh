#!/bin/bash
# TWGCB-01-008-0198: Ensure /etc/cron.daily directory permissions
# Target OS: RHEL 8.5

TARGET_DIR="/etc/cron.daily"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0198: Ensure /etc/cron.daily directory permissions"

get_mode() {
    [ -e "$1" ] && stat -c '%a' "$1" 2>/dev/null || echo ""
}

is_mode_le_700() {
    local m
    [ -e "$1" ] || return 1
    m=$(get_mode "$1")
    [ -n "$m" ] || return 1
    [ "$m" -le 700 ] 2>/dev/null
}

show_status() {
    echo
    echo "Checking directory:"
    echo "  - $TARGET_DIR"
    echo
    echo "Check results:"
    if [ -d "$TARGET_DIR" ]; then
        m=$(get_mode "$TARGET_DIR")
        is_mode_le_700 "$TARGET_DIR" && echo "$TARGET_DIR: mode $m (OK)" || echo "$TARGET_DIR: mode ${m:-unknown} (Too permissive; should be 700 or stricter)"
    else
        echo "$TARGET_DIR: (Not present)"
    fi
}

check_compliance() {
    [ -d "$TARGET_DIR" ] && is_mode_le_700 "$TARGET_DIR"
}

apply_fix() {
    [ -d "$TARGET_DIR" ] || return 1
    chmod 700 "$TARGET_DIR" || return 1
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: /etc/cron.daily permissions are 700 or stricter.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: /etc/cron.daily permissions too permissive or directory missing.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now (set permissions to 700)? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
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
