#!/bin/bash
# TWGCB-01-008-0244
# Ensure firewalld package is installed.
# Target OS: Red Hat Enterprise Linux 8.5
# Notes:
# - No Chinese in code.
# - Bright green/red ANSI colors for compliant/non-compliant and success/failure messages.
# - Single script does check + optional apply with Y/N/C prompt.
#
# Exit codes:
#   0 = compliant or applied successfully
#   1 = non-compliant and skipped / failed to apply
#   2 = canceled by user
#   3 = invalid input (should not happen due to loop)

set -o pipefail

PKG="firewalld"

# Colors
GREEN="\e[92m"
RED="\e[91m"
RESET="\e[0m"

has_dnf() {
    command -v dnf >/dev/null 2>&1
}

pkg_installed() {
    rpm -q "$PKG" >/dev/null 2>&1
}

show_state() {
    echo "State overview:"
    if pkg_installed; then
        rpm -q "$PKG" --qf "  package: %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n" 2>/dev/null || echo "  package: installed"
    else
        echo "  package: not installed"
    fi
}

check_compliance() {
    pkg_installed
}

apply_fix() {
    has_dnf || return 1
    pkg_installed && return 0
    dnf -y install "$PKG"
}

# --- Main ---
echo "TWGCB-01-008-0244: Ensure firewalld package is installed"
echo

echo "Checking current package state..."
show_state
echo

if check_compliance; then
    echo -e "${GREEN}Compliant: '$PKG' is installed.${RESET}"
    exit 0
else
    echo -e "${RED}Non-compliant: '$PKG' is not installed.${RESET}"
fi

while true; do
    echo -n "Apply fix now (install '$PKG' via dnf)? [Y]es / [N]o / [C]ancel: "
    read -rsn1 key
    echo
    case "$key" in
        [Yy])
            if apply_fix && check_compliance; then
                echo
                echo "Resulting state:"
                show_state
                echo -e "${GREEN}Successfully applied.${RESET}"
                exit 0
            else
                echo
                echo "Resulting state:"
                show_state
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
