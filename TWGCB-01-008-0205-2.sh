#!/bin/bash
# TWGCB-01-008-0205: Configure at.allow & cron.allow ownership and remove deny lists
# Target OS: RHEL 8.5

CRON_DENY="/etc/cron.deny"
AT_DENY="/etc/at.deny"
CRON_ALLOW="/etc/cron.allow"
AT_ALLOW="/etc/at.allow"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0205: Configure at.allow & cron.allow ownership"

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
    echo "Checking files:"
    printf "  - %s\n" "$CRON_DENY" "$AT_DENY" "$CRON_ALLOW" "$AT_ALLOW"
    echo
    echo "Check results:"
    [ -e "$CRON_DENY" ] && echo "$CRON_DENY: exists (should be absent)" || echo "$CRON_DENY: (Not present)"
    [ -e "$AT_DENY" ] && echo "$AT_DENY: exists (should be absent)" || echo "$AT_DENY: (Not present)"
    if [ -e "$CRON_ALLOW" ]; then
        og1=$(get_owner_group "$CRON_ALLOW")
        is_owned_by_root "$CRON_ALLOW" && echo "$CRON_ALLOW: owner $og1 (OK)" || echo "$CRON_ALLOW: owner ${og1:-unknown} (Not root:root)"
    else
        echo "$CRON_ALLOW: (Not present)"
    fi
    if [ -e "$AT_ALLOW" ]; then
        og2=$(get_owner_group "$AT_ALLOW")
        is_owned_by_root "$AT_ALLOW" && echo "$AT_ALLOW: owner $og2 (OK)" || echo "$AT_ALLOW: owner ${og2:-unknown} (Not root:root)"
    else
        echo "$AT_ALLOW: (Not present)"
    fi
}

check_compliance() {
    [ ! -e "$CRON_DENY" ] || return 1
    [ ! -e "$AT_DENY" ] || return 1
    [ -e "$CRON_ALLOW" ] && is_owned_by_root "$CRON_ALLOW" || return 1
    [ -e "$AT_ALLOW" ] && is_owned_by_root "$AT_ALLOW" || return 1
    return 0
}

apply_fix() {
    rm -f "$CRON_DENY" "$AT_DENY" 2>/dev/null
    touch "$CRON_ALLOW" "$AT_ALLOW" || return 1
    chown root:root "$CRON_ALLOW" "$AT_ALLOW" 2>/dev/null || return 1
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: at.allow/cron.allow owned by root:root and deny files absent.${CLR_RESET}"
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
