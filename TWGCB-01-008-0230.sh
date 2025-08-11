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
    grep -n -E '^[[:space:]]*#?[[:space:]]*CREATE_HOME([[:space:]]+|[[:space:]]*=[[:space:]]+).*' "$TARGET" 2>/dev/null \
        | sed -E 's/^([0-9]+):/Line: \1:/' \
        || echo "(No CREATE_HOME line found)"
}

check_compliance() {
    # Compliant if a non-comment line sets CREATE_HOME to 'yes' (allow '=' or whitespace).
    # Missing file or unreadable file -> non-compliant.
    [ -r "$TARGET" ] || return 1
    awk 'BEGIN{IGNORECASE=1}
         {
           line=$0
           sub(/#.*/,"",line)                # strip trailing comments
           if (match(line,/^[ \t]*CREATE_HOME[ \t]*(=?)[ \t]*([[:alnum:]_+-]+)/,m)) {
               val=m[2]
               if (tolower(val)=="yes") { ok=1 }
               found=1
           }
         }
         END{ exit (found && ok)?0:1 }' "$TARGET"
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

    # 1) Try to update an existing non-comment CREATE_HOME line (with '=' or whitespace)
    if sed -ri -E 's/^[[:space:]]*CREATE_HOME([[:space:]]*=[[:space:]]*|[[:space:]]+).*$/CREATE_HOME yes/' "$TARGET"; then
        :
    else
        echo -e "${RED}Failed to apply${RESET}"
        echo "Reason: sed failed updating non-comment CREATE_HOME."
        return 1
    fi

    # 2) If still not compliant, try to convert a commented line to active
    if ! check_compliance; then
        if grep -qEi '^[[:space:]]*#[[:space:]]*CREATE_HOME([[:space:]]*=[[:space:]]*|[[:space:]]+).*' "$TARGET"; then
            if ! sed -ri -E 's/^[[:space:]]*#[[:space:]]*CREATE_HOME([[:space:]]*=[[:space:]]*|[[:space:]]+).*$/CREATE_HOME yes/' "$TARGET"; then
                echo -e "${RED}Failed to apply${RESET}"
                echo "Reason: unable to uncomment CREATE_HOME in $TARGET."
                return 1
            fi
        fi
    fi

    # 3) If still not compliant, append a new line
    if ! check_compliance; then
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

