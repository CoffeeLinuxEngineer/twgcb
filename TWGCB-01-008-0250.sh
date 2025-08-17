#!/bin/bash
# TWGCB-01-008-0250: Disable and mask firewalld when using nftables (RHEL 8.5)
# Checks compliance and, if needed, stops/disables/masks firewalld. No Chinese.

SERVICE="firewalld"

# Colors (bright)
GREEN="\033[92m"
RED="\033[91m"
YELLOW="\033[93m"
RESET="\033[0m"

unit_exists() {
    # Return 0 if the unit file exists (installed), else 1
    systemctl list-unit-files --type=service 2>/dev/null \
      | awk '{print $1}' | grep -qx "${SERVICE}.service"
}

is_masked() {
    [ "$(systemctl is-enabled "${SERVICE}" 2>/dev/null || true)" = "masked" ]
}

is_active() {
    [ "$(systemctl is-active "${SERVICE}" 2>/dev/null || true)" = "active" ]
}

check_compliance() {
    # Compliant if service is not installed, OR masked and not active
    if ! unit_exists; then
        return 0
    fi
    if is_masked && ! is_active; then
        return 0
    fi
    return 1
}

print_check() {
    echo "Checking service: ${SERVICE}"
    echo "Check results:"

    if ! unit_exists; then
        echo "(Unit not found)"
        return
    fi

    active_state="$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"
    [ -n "$active_state" ] || active_state="unknown"

    enabled_state="$(systemctl is-enabled "${SERVICE}" 2>/dev/null || true)"
    [ -n "$enabled_state" ] || enabled_state="unknown"

    echo "is-active: ${active_state}"
    echo "is-enabled: ${enabled_state}"
}

apply_fix() {
    # Require root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Failed to apply${RESET}"
        echo "Reason: this action requires root privileges."
        return 1
    fi

    # If not installed, nothing to do
    if ! unit_exists; then
        return 0
    fi

    # Stop, disable, and mask. All must succeed.
    systemctl stop "${SERVICE}" 2>/dev/null && \
    systemctl disable "${SERVICE}" && \
    systemctl mask "${SERVICE}"
}

# -------- Main --------
print_check
if check_compliance; then
    echo -e "${GREEN}Compliant: firewalld is masked and inactive (or not installed).${RESET}"
    exit 0
fi

echo -e "${RED}Non-compliant: firewalld is not masked and inactive.${RESET}"

# Prompt Y/N/C
while true; do
    printf "Apply fix now? [Y]es / [N]o / [C]ancel: "
    IFS= read -r -n1 ans
    echo
    case "$ans" in
        [Yy])
            if apply_fix; then
                # Re-check after apply
                if check_compliance; then
                    echo -e "${GREEN}Successfully applied${RESET}"
                    exit 0
                else
                    echo -e "${RED}Failed to apply${RESET}"
                    exit 1
                fi
            else
                # apply_fix already printed reason
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
