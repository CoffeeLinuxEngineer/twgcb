#!/bin/bash
# TWGCB-01-008-0194: Ensure /etc/crontab file permissions
# Target OS: RHEL 8.5

TARGET_FILE="/etc/crontab"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0194: Ensure /etc/crontab file permissions"

get_mode() {
    [ -e "$1" ] && stat -c '%a' "$1" 2>/dev/null || echo ""
}

is_mode_le_600() {
    local m
    [ -e "$1" ] || return 1
    m=$(get_mode "$1")
    [ -n "$m" ] || return 1
    [ "$m" -le 600 ] 2>/dev/null
}

show_status() {
    echo
    echo "Checking file:"
    echo "  - $TARGET_FILE"
    echo
    echo "Check results:"
    if [ -f "$TARGET_FILE" ]; then
        m=$(get_mode "$TARGET_FILE")
        is_mode_le_600 "$TARGET_FILE" && echo "$TARGET_FILE: mode $m (OK)" || echo "$TARGET_FILE: mode ${m:-unknown} (Too permissive; should be 600 or stricter)"
    else
        echo "$TARGET_FILE: (Not present)"
    fi
}

check_compliance() {
    [ -f "$TARGET_FILE" ] && is_mode_le_600 "$TARGET_FILE"
}

apply_fix() {
    [ -f "$TARGET_FILE" ] || return 1
    chmod 600 "$TARGET_FILE" || return 1
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: /etc/crontab permissions are 600 or stricter.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: /etc/crontab permissions too permissive or file missing.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now (set permissions to 600)? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
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
