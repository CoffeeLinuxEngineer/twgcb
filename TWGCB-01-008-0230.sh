#!/bin/bash
# TWGCB-01-008-0230: Ensure CREATE_HOME=yes in /etc/login.defs (RHEL 8.5)
# Purpose: New user accounts should have a home directory created by default.
# No Chinese. Single script: check + prompt + apply. Bright colors.

TARGET="/etc/login.defs"
REQUIRED_KEY="CREATE_HOME"
REQUIRED_VALUE="yes"

# Colors (bright)
GREEN="\033[92m"
RED="\033[91m"
YELLOW="\033[93m"
RESET="\033[0m"

print_header() {
    echo "TWGCB-01-008-0230: Ensure new user accounts have home directories (CREATE_HOME=yes)"
    echo
}

show_lines() {
    # Print lines (with numbers) that mention CREATE_HOME, including commented ones.
    # Distinguish file-not-found vs permission-denied explicitly.
    if [ ! -e "$TARGET" ]; then
        echo "(File not found)"
        return
    fi
    if [ ! -r "$TARGET" ]; then
        echo "(Permission denied)"
        return
    fi
    grep -n -E '^[[:space:]]*#?[[:space:]]*CREATE_HOME[[:space:]]*=' "$TARGET" 2>/dev/null \
        | sed -E 's/^([0-9]+):/Line: \1:/' \
        || echo "(No CREATE_HOME line found)"
}

check_compliance() {
    # Compliant if a non-comment line sets CREATE_HOME to 'yes' (case-insensitive).
    # Missing file or unreadable file -> non-compliant.
    [ -r "$TARGET" ] || return 1
    awk 'BEGIN{IGNORECASE=1}
         /^[ \t]*#/ {next}
         /^[ \t]*CREATE_HOME[ \t]*=[ \t]*yes([ \t]|$)/ {found=1}
         END{exit found?0:1}' "$TARGET"
}

apply_fix() {
    # Require root and write access to modify the file.
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Failed to apply${RESET}"
        echo "Reason: requires root privileges."
        return 1
    fi

    if [ ! -e "$TARGET" ]; then
        echo -e "${RED}Failed to apply${RESET}"
        echo "Reason: $TARGET not found."
        return 1
    fi

    if [ ! -w "$TARGET" ]; then
        echo -e "${RED}Failed to apply${RESET}"
        echo "Reason: insufficient permissions to write $TARGET."
        return 1
    fi

    # If a (possibly commented) CREATE_HOME line exists, replace it. Otherwise append.
    if grep -qEi '^[[:space:]]*#?[[:space:]]*CREATE_HOME[[:space:]]*=' "$TARGET"; then
        if ! sed -ri 's/^[[:space:]]*#?[[:space:]]*CREATE_HOME[[:space:]]*=.*/CREATE_HOME yes/' "$TARGET"; then
            echo -e "${RED}Failed to apply${RESET}"
            echo "Reason: unable to update CREATE_HOME in $TARGET."
            return 1
        fi
    else
        if ! printf '\nCREATE_HOME yes\n' >> "$TARGET"; then
            echo -e "${RED}Failed to apply${RESET}"
            echo "Reason: unable to append CREATE_HOME to $TARGET."
            return 1
        fi
    fi

    return 0
}

print_header
echo "Checking file: $TARGET"
echo "Check results:"
show_lines

if check_compliance; then
    echo -e "${GREEN}Compliant: CREATE_HOME is set to 'yes'.${RESET}"
    exit 0
else
    echo -e "${RED}Non-compliant: CREATE_HOME is not set to 'yes' in $TARGET.${RESET}"
fi

# Prompt Y/N/C
while true; do
    printf "Apply fix now (set CREATE_HOME=yes)? [Y]es / [N]o / [C]ancel: "
    IFS= read -r -n1 key
    echo
    case "$key" in
        [Yy])
            if apply_fix; then
                echo
                echo "Resulting check:"
                echo "Checking file: $TARGET"
                echo "Check results:"
                show_lines
                if check_compliance; then
                    echo -e "${GREEN}Successfully applied${RESET}"
                    exit 0
                else
                    echo -e "${RED}Failed to apply${RESET}"
                    exit 1
                fi
            else
                echo
                echo "Resulting check:"
                echo "Checking file: $TARGET"
                echo "Check results:"
                show_lines
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
