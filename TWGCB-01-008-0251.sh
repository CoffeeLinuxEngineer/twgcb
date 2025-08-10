#!/bin/bash
# TWGCB-01-008-0251
# Ensure at least one nftables table exists (e.g., 'table inet filter').
# Target OS: Red Hat Enterprise Linux 8.5
# Notes:
# - No Chinese in code.
# - Uses bright green/red ANSI colors for compliant/non-compliant and success/failure messages.
# - Single script does check + optional apply with Y/N/C prompt.
#
# Exit codes:
#   0 = compliant or applied successfully
#   1 = non-compliant and skipped / failed to apply
#   2 = canceled by user
#   3 = invalid input (should not happen due to loop)
#
# Requirement summary:
#   Create at least one nftables table. Example: 'nft create table inet filter'.

set -o pipefail

# Colors
GREEN="\e[92m"
RED="\e[91m"
RESET="\e[0m"

REQUIRED_TABLE_FAMILY="inet"
REQUIRED_TABLE_NAME="filter"

has_nft() {
    command -v nft >/dev/null 2>&1
}

show_tables() {
    if has_nft; then
        if nft list tables 2>/dev/null | sed 's/^/  /' | grep -q .; then
            echo "Existing nftables tables:"
            nft list tables 2>/dev/null | sed 's/^/  /'
        else
            echo "(No nftables tables found)"
        fi
    else
        echo "(nft command not found)"
    fi
}

check_compliance() {
    # Compliant if at least one nftables table exists
    has_nft || return 1
    nft list tables 2>/dev/null | grep -qE '^\s*table\s+'
}

apply_fix() {
    # Create a default table if missing (idempotent)
    has_nft || return 1
    nft list tables 2>/dev/null | grep -qE '^\s*table\s+' && return 0
    nft list tables 2>/dev/null | grep -qE "table[[:space:]]+$REQUIRED_TABLE_FAMILY[[:space:]]+$REQUIRED_TABLE_NAME" \
        || nft create table "$REQUIRED_TABLE_FAMILY" "$REQUIRED_TABLE_NAME"
}

# --- Main ---
echo "TWGCB-01-008-0251: Ensure at least one nftables table exists"
echo

if ! has_nft; then
    echo -e "${RED}Non-compliant: 'nft' command is not available.${RESET}"
    echo "Hint: Install the nftables package (requires root)."
    exit 1
fi

echo "Checking current nftables state..."
show_tables
echo

if check_compliance; then
    echo -e "${GREEN}Compliant: At least one nftables table exists.${RESET}"
    exit 0
else
    echo -e "${RED}Non-compliant: No nftables tables found.${RESET}"
fi

while true; do
    echo -n "Apply fix now (create 'table ${REQUIRED_TABLE_FAMILY} ${REQUIRED_TABLE_NAME}')? [Y]es / [N]o / [C]ancel: "
    read -rsn1 key
    echo
    case "$key" in
        [Yy])
            if apply_fix && check_compliance; then
                echo
                echo "Resulting state:"
                show_tables
                echo -e "${GREEN}Successfully applied.${RESET}"
                exit 0
            else
                echo
                echo "Resulting state:"
                show_tables
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
