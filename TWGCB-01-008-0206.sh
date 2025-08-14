#!/bin/bash
# TWGCB-01-008-0206: Configure at.allow & cron.allow permissions and remove deny lists
# Target OS: RHEL 8.5

CRON_DENY="/etc/cron.deny"
AT_DENY="/etc/at.deny"
CRON_ALLOW="/etc/cron.allow"
AT_ALLOW="/etc/at.allow"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0206: Configure at.allow & cron.allow permissions"

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
    echo "Checking files:"
    printf "  - %s\n" "$CRON_DENY" "$AT_DENY" "$CRON_ALLOW" "$AT_ALLOW"
    echo
    echo "Check results:"
    [ -e "$CRON_DENY" ] && echo "$CRON_DENY: exists (should be absent)" || echo "$CRON_DENY: (Not present)"
    [ -e "$AT_DENY" ] && echo "$AT_DENY: exists (should be absent)" || echo "$AT_DENY: (Not present)"
    if [ -e "$CRON_ALLOW" ]; then
        m1=$(get_mode "$CRON_ALLOW")
        is_mode_le_600 "$CRON_ALLOW" && echo "$CRON_ALLOW: mode $m1 (OK)" || echo "$CRON_ALLOW: mode ${m1:-unknown} (Too permissive)"
    else
        echo "$CRON_ALLOW: (Not present)"
    fi
    if [ -e "$AT_ALLOW" ]; then
        m2=$(get_mode "$AT_ALLOW")
        is_mode_le_600 "$AT_ALLOW" && echo "$AT_ALLOW: mode $m2 (OK)" || echo "$AT_ALLOW: mode ${m2:-unknown} (Too permissive)"
    else
        echo "$AT_ALLOW: (Not present)"
    fi
}

check_compliance() {
    [ ! -e "$CRON_DENY" ] || return 1
    [ ! -e "$AT_DENY" ] || return 1
    [ -e "$CRON_ALLOW" ] && is_mode_le_600 "$CRON_ALLOW" || return 1
    [ -e "$AT_ALLOW" ] && is_mode_le_600 "$AT_ALLOW" || return 1
    return 0
}

apply_fix() {
    rm -f "$CRON_DENY" "$AT_DENY" 2>/dev/null
    touch "$CRON_ALLOW" "$AT_ALLOW" || return 1
    chown root:root "$CRON_ALLOW" "$AT_ALLOW" 2>/dev/null
    chmod 600 "$CRON_ALLOW" "$AT_ALLOW" || return 1
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: at.allow/cron.allow configured and deny files absent.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: Configuration does not meet policy.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
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
