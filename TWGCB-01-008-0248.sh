#!/bin/bash
# TWGCB-01-008-0248: Set firewalld default zone to 'public' (RHEL 8.5)
# No Chinese. Single script: check + prompt + apply.

SERVICE="firewalld"
CONF="/etc/firewalld/firewalld.conf"
REQUIRED_ZONE="public"

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

get_perm_zone() {
    # Prints the configured DefaultZone value from firewalld.conf, or empty if not present
    [ -f "$CONF" ] || return 0
    awk -F= '
        /^[ \t]*#/ {next}
        /^[ \t]*DefaultZone[ \t]*=/ {
            val=$2
            gsub(/^[ \t]+|[ \t]+$/, "", val)
            print val
            exit
        }
    ' "$CONF"
}

get_perm_line() {
    # Prints the line number of DefaultZone= in firewalld.conf, or empty if not present
    [ -f "$CONF" ] || return 0
    awk -F= '
        /^[ \t]*#/ {next}
        /^[ \t]*DefaultZone[ \t]*=/ { print NR; exit }
    ' "$CONF"
}

get_runtime_zone() {
    if is_active; then
        firewall-cmd --get-default-zone 2>/dev/null || echo "(unknown)"
    else
        echo "(inactive)"
    fi
}

print_state() {
    echo "Checking current state..."
    echo "State overview:"
    if unit_exists; then
        echo "  unit: present"
        echo "  is-enabled: $(enabled_state)"
        echo "  is-active : $(active_state)"
    else
        echo "  unit: not found"
    fi

    local rzone pzone pline
    rzone="$(get_runtime_zone)"
    pzone="$(get_perm_zone)"
    pline="$(get_perm_line)"

    echo "  runtime  default zone: ${rzone:-"(unknown)"}"
    echo "  permanent default zone: ${pzone:-"(unknown)"}"

    if [ -n "$pline" ] && [ -n "$pzone" ]; then
        echo "  Line: ${pline}:DefaultZone=${pzone}"
    else
        echo "  (No DefaultZone line found in ${CONF})"
    fi
}

check_compliance() {
    # Compliant if permanent default zone is exactly 'public'
    [ "$(get_perm_zone)" = "$REQUIRED_ZONE" ]
}

apply_fix() {
    # Require root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Failed to apply${RESET}"
        echo "Reason: requires root privileges."
        return 1
    fi

    if [ ! -f "$CONF" ]; then
        echo -e "${RED}Failed to apply${RESET}"
        echo "Reason: ${CONF} not found."
        return 1
    fi

    if grep -qE '^[[:space:]]*DefaultZone[[:space:]]*=' "$CONF"; then
        if ! sed -ri 's/^[[:space:]]*DefaultZone[[:space:]]*=.*/DefaultZone=public/' "$CONF"; then
            echo -e "${RED}Failed to apply${RESET}"
            echo "Reason: unable to update DefaultZone in ${CONF}."
            return 1
        fi
    else
        if ! printf '\nDefaultZone=public\n' >> "$CONF"; then
            echo -e "${RED}Failed to apply${RESET}"
            echo "Reason: unable to append DefaultZone to ${CONF}."
            return 1
        fi
    fi

    # If firewalld is running, also set runtime default zone now
    if is_active; then
        if ! firewall-cmd --set-default-zone=public >/dev/null 2>&1; then
            echo -e "${YELLOW}Warning:${RESET} runtime default zone not updated; service may be inactive or command failed."
        fi
    fi

    return 0
}

# -------- Main --------
echo "TWGCB-01-008-0248: Set firewalld default zone to 'public'"
echo
print_state

if check_compliance; then
    echo -e "${GREEN}Compliant: permanent default zone is 'public'.${RESET}"
    exit 0
fi

echo -e "${RED}Non-compliant: permanent default zone is not 'public'.${RESET}"
while true; do
    printf "Apply fix now (set default zone to 'public')? [Y]es / [N]o / [C]ancel: "
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
