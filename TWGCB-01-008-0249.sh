#!/bin/bash
# TWGCB-01-008-0249: Enable and start nftables (RHEL 8.5)
# Checks compliance and, if needed, unmasks/enables/starts nftables. No Chinese.

SERVICE="nftables"

# Colors (bright)
GREEN="\033[92m"
RED="\033[91m"
YELLOW="\033[93m"
RESET="\033[0m"

unit_exists() {
    systemctl list-unit-files --type=service 2>/dev/null \
      | awk '{print $1}' | grep -qx "${SERVICE}.service"
}

is_active() {
    [ "$(systemctl is-active "${SERVICE}" 2>/dev/null || true)" = "active" ]
}

is_enabled() {
    [ "$(systemctl is-enabled "${SERVICE}" 2>/dev/null || true)" = "enabled" ]
}

is_masked() {
    [ "$(systemctl is-enabled "${SERVICE}" 2>/dev/null || true)" = "masked" ]
}

print_state() {
    echo "Checking current service state..."
    echo "State overview:"
    if unit_exists; then
        echo "  unit: present"
        enabled_state="$(systemctl is-enabled "${SERVICE}" 2>/dev/null || true)"
        [ -n "$enabled_state" ] || enabled_state="unknown"
        active_state="$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"
        [ -n "$active_state" ] || active_state="unknown"
        echo "  is-enabled: ${enabled_state}"
        echo "  is-active : ${active_state}"
    else
        echo "  unit: not found"
    fi
}

check_compliance() {
    # Compliant when service exists AND is enabled AND active
    unit_exists && is_enabled && is_active
}

apply_fix() {
    # Require root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Failed to apply${RESET}"
        echo "Reason: requires root privileges."
        return 1
    fi

    if ! unit_exists; then
        echo -e "${RED}Failed to apply${RESET}"
        echo "Reason: ${SERVICE}.service not installed."
        return 1
    fi

    # If masked, unmask first
    if is_masked; then
        echo "Unmasking ${SERVICE}..."
        if ! systemctl unmask "${SERVICE}"; then
            echo -e "${RED}Failed to apply${RESET}"
            echo "Reason: unable to unmask ${SERVICE}."
            return 1
        fi
    fi

    # Enable and start now
    if systemctl enable --now "${SERVICE}"; then
        return 0
    else
        echo -e "${RED}Failed to apply${RESET}"
        echo "Reason: 'systemctl --now enable ${SERVICE}' failed."
        return 1
    fi
}

# -------- Main --------
print_state
if check_compliance; then
    echo -e "${GREEN}Compliant: ${SERVICE} is enabled and active.${RESET}"
    exit 0
fi

echo -e "${RED}Non-compliant: ${SERVICE} is not enabled and active.${RESET}"
while true; do
    printf "Apply fix now (run 'systemctl --now enable %s')? [Y]es / [N]o / [C]ancel: " "${SERVICE}"
    IFS= read -r -n1 ans
    echo
    case "$ans" in
        [Yy])
            if apply_fix; then
                echo "Resulting state:"
                print_state
                if check_compliance; then
                    echo -e "${GREEN}Successfully applied${RESET}"
                    exit 0
                else
                    echo -e "${RED}Failed to apply${RESET}"
                    exit 1
                fi
            else
                echo "Resulting state:"
                print_state
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
