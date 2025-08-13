#!/bin/bash
#
# TWGCB-01-008-0214: Minimum number of lowercase letters in password
# Target OS: Red Hat Enterprise Linux 8.5
# This script checks and enforces lcredit=-1 in /etc/security/pwquality.conf
# - Shows matching lines with "Line: " prefix for line numbers
# - Distinguishes (File not found) vs (Permission denied)
# - Prompts Y/N/C before applying
# - Uses bright green/red messages for compliant/non-compliant and success/failure
#
set -o pipefail

TARGET="/etc/security/pwquality.conf"
SETTING_KEY="lcredit"
REQUIRED_VALUE="-1"

GREEN="\033[1;92m"
RED="\033[1;91m"
RESET="\033[0m"

echo "TWGCB-01-008-0214: Minimum number of lowercase letters in password"
echo "Checking file: $TARGET"
echo "Check results:"

show_lines() {
    grep -n -E "^[[:space:]]*${SETTING_KEY}[[:space:]]*=" "$TARGET" 2>/dev/null | sed 's/^[0-9][0-9]*/Line: &:/'
}

check_compliance() {
    [ ! -r "$TARGET" ] && return 1
    grep -Eq "^[[:space:]]*${SETTING_KEY}[[:space:]]*=[[:space:]]*${REQUIRED_VALUE}[[:space:]]*(#.*)?$" "$TARGET"
}

if [ -e "$TARGET" ]; then
    if [ -r "$TARGET" ]; then
        if ! show_lines || [ -z "$(show_lines)" ]; then
            echo "(No matching line found)"
        fi
    else
        echo "(Permission denied)"
    fi
else
    echo "(File not found)"
fi

if check_compliance; then
    echo -e "${GREEN}Compliant: ${SETTING_KEY} is set to ${REQUIRED_VALUE}.${RESET}"
    exit 0
else
    echo -e "${RED}Non-compliant: ${SETTING_KEY} is missing or not set to ${REQUIRED_VALUE}.${RESET}"
fi

while true; do
    echo -n "Apply fix now (set ${SETTING_KEY}=${REQUIRED_VALUE})? [Y]es / [N]o / [C]ancel: "
    read -rsn1 key
    echo
    case "$key" in
        [Yy])
            if [ ! -e "$TARGET" ]; then
                echo -e "${RED}Failed to apply: file not found.${RESET}"
                exit 1
            fi
            if [ ! -w "$TARGET" ]; then
                echo -e "${RED}Failed to apply: permission denied.${RESET}"
                exit 1
            fi
            if grep -Eq "^[[:space:]]*${SETTING_KEY}[[:space:]]*=" "$TARGET"; then
                if ! sed -ri "s|^[[:space:]]*${SETTING_KEY}[[:space:]]*=.*|${SETTING_KEY}=${REQUIRED_VALUE}|" "$TARGET"; then
                    echo -e "${RED}Failed to apply: unable to modify file.${RESET}"
                    exit 1
                fi
            else
                if ! printf "%s\n" "${SETTING_KEY}=${REQUIRED_VALUE}" >> "$TARGET"; then
                    echo -e "${RED}Failed to apply: unable to write to file.${RESET}"
                    exit 1
                fi
            fi
            if check_compliance; then
                echo -e "${GREEN}Successfully applied.${RESET}"
                exit 0
            else
                echo -e "${RED}Failed to apply.${RESET}"
                exit 1
            fi
            ;;
        [Nn])
            echo "Skipped."
            exit 1
            ;;
        [Cc])
            echo "Canceled."
            exit 2
            ;;
        *)
            echo "Invalid input."
            ;;
    esac
done
