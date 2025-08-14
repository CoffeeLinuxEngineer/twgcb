#!/bin/bash
# TWGCB-01-008-0176: Ensure rsyslog $FileCreateMode is 0640 or stricter
# Target OS: RHEL 8.5

FILES_TO_CHECK=("/etc/rsyslog.conf" /etc/rsyslog.d/*.conf)
REQUIRED_MODE="0640"

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0176: Ensure rsyslog \$FileCreateMode is $REQUIRED_MODE or stricter"

show_status() {
    echo
    echo "Checking files:"
    for f in "${FILES_TO_CHECK[@]}"; do
        [ -f "$f" ] && echo "  - $f"
    done
    echo
    echo "Check results:"
    local found=0
    for f in "${FILES_TO_CHECK[@]}"; do
        if [ -f "$f" ]; then
            while IFS= read -r line; do
                mode=$(echo "$line" | awk '{print $2}')
                if [[ "$mode" =~ ^0[0-7]{3}$ ]]; then
                    if [[ "$mode" =~ ^0(640|63[0-9]|6[0-2][0-9]|60[0-9]|[0-5][0-9]{2})$ ]]; then
                        echo -e "$f: Line: ${CLR_GREEN}$line${CLR_RESET}"
                    else
                        echo -e "$f: Line: ${CLR_RED}$line${CLR_RESET}"
                    fi
                    found=1
                fi
            done < <(grep -En "^[[:space:]]*\$FileCreateMode[[:space:]]+[0-9]{4}" "$f")
        fi
    done
    [ $found -eq 0 ] && echo "(No matching setting found)"
}

check_compliance() {
    for f in "${FILES_TO_CHECK[@]}"; do
        if [ -f "$f" ]; then
            if grep -Eq "^[[:space:]]*\$FileCreateMode[[:space:]]+0(640|63[0-9]|6[0-2][0-9]|60[0-9]|[0-5][0-9]{2})" "$f"; then
                return 0
            fi
        fi
    done
    return 1
}

apply_fix() {
    for f in "${FILES_TO_CHECK[@]}"; do
        [ -f "$f" ] || continue
        if grep -Eq "^[[:space:]]*\$FileCreateMode" "$f"; then
            sed -ri "s|^[[:space:]]*(\$FileCreateMode)[[:space:]]+[0-9]{4}|\1 $REQUIRED_MODE|" "$f"
        else
            echo "\$FileCreateMode $REQUIRED_MODE" >> "$f"
        fi
    done
    systemctl restart rsyslog
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: \$FileCreateMode is $REQUIRED_MODE or stricter.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: \$FileCreateMode is missing or too permissive.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now (set \$FileCreateMode to $REQUIRED_MODE)? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
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
