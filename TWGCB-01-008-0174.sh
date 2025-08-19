#!/bin/bash
# TWGCB-01-008-0174: Ensure rsyslog package is installed
# Target: RHEL 8.5

C_GREEN="\033[92m"
C_RED="\033[91m"
C_CYAN="\033[96m"
C_OFF="\033[0m"

echo -e "TWGCB-01-008-0174: Ensure rsyslog package is installed\n"

check_compliance() {
    rpm -q rsyslog &>/dev/null
}

show_status() {
    echo "Checking package status..."
    if rpm -q rsyslog &>/dev/null; then
        echo "  rsyslog package: installed"
    else
        echo "  rsyslog package: not installed"
    fi
    echo
}

# ---------- Check phase ----------
show_status
if check_compliance; then
    echo -e "${C_GREEN}Compliant:${C_OFF} rsyslog package is installed."
    exit 0
else
    echo -e "${C_RED}Non-compliant:${C_OFF} rsyslog package is missing."
fi

# ---------- Prompt ----------
while true; do
    echo -n "Apply fix now (install rsyslog package)? [Y]es / [N]o / [C]ancel: "
    read -r ans
    case "$ans" in
        Y|y) break ;;
        N|n) echo "Skipped."; exit 1 ;;
        C|c) echo "Canceled."; exit 2 ;;
        *) echo "Invalid input." ;;
    esac
done

# ---------- Apply ----------
if dnf install -y rsyslog; then
    :
else
    echo -e "${C_RED}Failed to install rsyslog.${C_OFF}"
    exit 3
fi

# ---------- Re-check ----------
echo
show_status
if check_compliance; then
    echo -e "${C_GREEN}Successfully applied.${C_OFF}"
    exit 0
else
    echo -e "${C_RED}Failed to apply.${C_OFF}"
    exit 3
fi
