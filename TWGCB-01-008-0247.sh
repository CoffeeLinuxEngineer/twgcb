#!/bin/bash
# TWGCB-01-008-0247: Disable and mask nftables (when using firewalld) on RHEL 8.5
# No Chinese. Single script: check + prompt + apply.

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

enabled_state() {
    local s
    s="$(systemctl is-enabled "${SERVICE}" 2>/dev/null || true)"
    [ -n "$s" ] && echo "$s" || echo "unknown"
}

active_state() {
    local s
    s="$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"
    [ -n "$s" ] && echo "$s" || echo "unknown"
}

print_state() {
    echo "Checking current service state..."
    echo "State overview:"
    if unit_exists; then
        echo "  unit: present"
        echo "  is-enabled: $(enabled_state)"
        echo "  is-active : $(active_state)"
    else
        echo "  unit: not found"
    fi
}

check_compliance() {
    # Compliant if service is not installed OR masked and not active
    if ! unit_exists; then
        return 0
    fi
    if is_masked && ! is_active; then
        return 0
    fi
    return 1
}

apply_fix() {
    # Require root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Failed to apply${RESET}"
        echo "Reason: requires root privileges."
        return 1
    fi

    # If not installed, nothing to do
    if ! unit_exists; then
        return 0
    fi

    # Stop, disable, and mask (stop first; masking does not stop a running unit)
    systemctl stop "${SERVICE}" 2>/dev/null && \
    systemctl disable "${SERVICE}" && \
    systemctl mask "${SERVICE}"
}

# -------- Main --------
echo "TWGCB-01-008-0247: Disable and mask nftables (when using firewalld)"
echo
print_state

if check_compliance; then
    echo -e "${GREEN}Compliant: ${SERVICE} is masked and inactive (or not installed).${RESET}"
    exit 0
fi

echo -e "${RED}Non-compliant: ${SERVICE} is not masked and stopped.${RESET}"
while true; do
    printf "Apply fix now (run 'systemctl stop %s && systemctl disable %s && systemctl mask %s')? [Y]es / [N]o / [C]ancel: " "${SERVICE}" "${SERVICE}" "${SERVICE}"
    IFS= read -r -n1 ans
    echo
    case "$ans" in
        [Yy])
            if apply_fix; then
                echo
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
                echo
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

