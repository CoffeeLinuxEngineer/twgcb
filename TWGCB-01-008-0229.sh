#!/bin/bash
# TWGCB-01-008-0229: Ensure FAIL_DELAY >= 4 in /etc/login.defs
# Platform: RHEL 8.5
# Notes:
# - Shows line numbers as "Line: <num>:" in check results.
# - Uses bright green/red messages for compliant/non-compliant and apply outcomes.
# - Handles file not found and permission denied clearly.
# - No Chinese in code.

TARGET="/etc/login.defs"
MIN_DELAY=4

# Colors (bright)
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
RESET="\e[0m"

print_header() {
    echo "TWGCB-01-008-0229: Set login failure delay (FAIL_DELAY >= ${MIN_DELAY})"
    echo
}

show_matches() {
    echo "Checking file: $TARGET"
    echo "Check results:"
    if [ ! -e "$TARGET" ]; then
        echo "(File not found)"
        return 0
    fi
    if [ ! -r "$TARGET" ]; then
        echo "(Permission denied)"
        return 0
    fi
    # Show all lines containing FAIL_DELAY (including commented), with "Line: N:" prefix
    if ! grep -n "FAIL_DELAY" "$TARGET" 2>/dev/null | sed 's/^\([0-9]\+\):/Line: \1:/' ; then
        echo "(No matching line found)"
    fi
}

check_compliance() {
    # Returns 0 if compliant, 1 if non-compliant, 2 if cannot verify (permission denied)
    if [ ! -e "$TARGET" ]; then
        return 1   # Treat missing file as non-compliant (policy requires a setting)
    fi
    if [ ! -r "$TARGET" ]; then
        return 2
    fi

    # Parse the last active (non-commented) FAIL_DELAY value in the file
    local val
    val="$(awk '
        BEGIN { v = "" }
        {
            s=$0
            sub(/^[ \t]+/, "", s)
            if (s ~ /^#/) next
            if (s ~ /^FAIL_DELAY[ \t]+[0-9]+([ \t].*)?$/) {
                for (i=1;i<=NF;i++) {
                    if ($i ~ /^[0-9]+$/) { v=$i }
                }
            }
        }
        END { print v }
    ' "$TARGET")"

    if [ -z "$val" ]; then
        return 1
    fi
    if [ "$val" -ge "$MIN_DELAY" ] 2>/dev/null; then
        return 0
    fi
    return 1
}

apply_fix() {
    # Attempt to set FAIL_DELAY to at least MIN_DELAY
    if [ ! -e "$TARGET" ]; then
        echo -e "${RED}Failed to apply${RESET}"
        return 1
    fi
    if [ ! -w "$TARGET" ]; then
        echo -e "${RED}Failed to apply${RESET}"
        echo "(Permission denied)"
        return 1
    fi

    # Replace active lines
    sed -ri "s/^[[:space:]]*FAIL_DELAY[[:space:]]+[0-9]+.*/FAIL_DELAY ${MIN_DELAY}/" "$TARGET"

    # Ensure at least one active line exists; if not, append
    if ! grep -Eq '^[[:space:]]*FAIL_DELAY[[:space:]]+[0-9]+' "$TARGET"; then
        tail -c1 "$TARGET" | read -r _ || echo >> "$TARGET"
        echo "FAIL_DELAY ${MIN_DELAY}" >> "$TARGET"
    fi

    # Re-check
    if check_compliance; then
        echo -e "${GREEN}Successfully applied${RESET}"
        return 0
    else
        echo -e "${RED}Failed to apply${RESET}"
        return 1
    fi
}

main() {
    print_header
    show_matches
    echo

    check_compliance
    rc=$?

    if [ $rc -eq 0 ]; then
        echo -e "${GREEN}Compliant: FAIL_DELAY is set to ${MIN_DELAY} or higher.${RESET}"
        exit 0
    elif [ $rc -eq 2 ]; then
        echo -e "${RED}Non-compliant: Unable to verify (permission denied).${RESET}"
        exit 1
    else
        echo -e "${RED}Non-compliant: FAIL_DELAY is missing or less than ${MIN_DELAY}.${RESET}"
        while true; do
            echo -n "Apply fix now (set FAIL_DELAY=${MIN_DELAY})? [Y]es / [N]o / [C]ancel: "
            read -rsn1 key
            echo
            case "$key" in
                [Yy])
                    apply_fix
                    exit $?
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
    fi
}

main
