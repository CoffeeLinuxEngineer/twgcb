#!/bin/bash
# TWGCB-01-008-0177: Ensure rsyslog logs auth, authpriv, and daemon to /var/log/secure
# Target OS: RHEL 8.5

TARGET_LINE="auth.*,authpriv.*,daemon.*    /var/log/secure"
FILES_TO_CHECK=("/etc/rsyslog.conf" /etc/rsyslog.d/*.conf)

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0177: Ensure rsyslog logs auth, authpriv, and daemon to /var/log/secure"

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
            if grep -Eq "^[[:space:]]*auth\.\*,authpriv\.\*,daemon\.\*[[:space:]]+/var/log/secure" "$f"; then
                grep -n "^[[:space:]]*auth\.\*,authpriv\.\*,daemon\.\*[[:space:]]+/var/log/secure" "$f" | sed "s|^|$f: Line: |"
                found=1
            fi
        fi
    done
    if [ $found -eq 0 ]; then
        echo "(No matching line found)"
    fi
}

check_compliance() {
    for f in "${FILES_TO_CHECK[@]}"; do
        if [ -f "$f" ]; then
            if grep -Eq "^[[:space:]]*auth\.\*,authpriv\.\*,daemon\.\*[[:space:]]+/var/log/secure" "$f"; then
                return 0
            fi
        fi
    done
    return 1
}

apply_fix() {
    # Append the rule to /etc/rsyslog.conf
    echo "$TARGET_LINE" >> /etc/rsyslog.conf
    systemctl restart rsyslog.service
}

show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: rsyslog is logging auth, authpriv, and daemon to /var/log/secure.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: rsyslog is not logging auth, authpriv, and daemon to /var/log/secure.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now (add rule to /etc/rsyslog.conf and restart rsyslog)? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
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
