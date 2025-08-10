#!/bin/bash
# TWGCB-01-008-0248
# Set firewalld default zone (e.g., public).
# Target OS: Red Hat Enterprise Linux 8.5
# Notes:
# - No Chinese in code.
# - Bright green/red ANSI colors for compliant/non-compliant and success/failure messages.
# - Single script does check + optional apply with Y/N/C prompt.
# - Does not start/enable firewalld; it will set both runtime (if daemon is running) and permanent config.
#
# Exit codes:
#   0 = compliant or applied successfully
#   1 = non-compliant and skipped / failed to apply
#   2 = canceled by user
#   3 = invalid input (should not happen due to loop)
#
# Requirement summary:
#   Default zone must be configured to the required value (default: public).
#
# Customize the required zone by exporting REQUIRED_ZONE before running:
#   REQUIRED_ZONE=work ./TWGCB-01-008-0248.sh

set -o pipefail

# Colors
GREEN="\e[92m"
RED="\e[91m"
RESET="\e[0m"

REQUIRED_ZONE="${REQUIRED_ZONE:-public}"
SERVICE="firewalld.service"
CONF="/etc/firewalld/firewalld.conf"

has_systemctl() {
    command -v systemctl >/dev/null 2>&1
}

has_firewall_cmd() {
    command -v firewall-cmd >/dev/null 2>&1
}

unit_exists() {
    systemctl list-unit-files "$SERVICE" --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "$SERVICE"
}

is_active() {
    systemctl is-active "$SERVICE" 2>/dev/null || echo "unknown"
}

get_default_zone_runtime() {
    has_firewall_cmd || return 1
    firewall-cmd --get-default-zone 2>/dev/null
}

get_default_zone_permanent() {
    # Try firewall-cmd first; if that fails, read from config file.
    if has_firewall_cmd; then
        firewall-cmd --permanent --get-default-zone 2>/dev/null && return 0
    fi
    if [ -r "$CONF" ]; then
        # Extract DefaultZone=... from config
        awk -F= '/^[[:space:]]*DefaultZone[[:space:]]*=/{print $2}' "$CONF" | tail -n1
        return 0
    fi
    return 1
}

show_state() {
    echo "State overview:"
    if has_systemctl && unit_exists; then
        echo "  unit: present"
        echo "  is-active : $(is_active)"
    else
        echo "  unit: not present or systemctl unavailable"
    fi

    local rt perm
    rt="$(get_default_zone_runtime 2>/dev/null)"
    perm="$(get_default_zone_permanent 2>/dev/null)"
    [ -n "$rt" ]   && echo "  runtime  default zone: $rt"   || echo "  runtime  default zone: (unknown)"
    [ -n "$perm" ] && echo "  permanent default zone: $perm" || echo "  permanent default zone: (unknown)"

    # If config file is readable, show the line number containing DefaultZone=
    if [ -r "$CONF" ]; then
        # Print the first matching line with a 'Line: ' prefix before the number.
        grep -n '^[[:space:]]*DefaultZone[[:space:]]*=' "$CONF" | sed 's/^\([0-9]\+\):/Line: \1:/' | sed 's/^/  /' || true
    else
        if [ -e "$CONF" ] && [ ! -r "$CONF" ]; then
            echo "  ($CONF: permission denied)"
        else
            echo "  ($CONF: not found)"
        fi
    fi
}

check_compliance() {
    # Compliant if the permanent default zone equals REQUIRED_ZONE.
    local perm
    perm="$(get_default_zone_permanent 2>/dev/null)"
    [ -n "$perm" ] && [ "$perm" = "$REQUIRED_ZONE" ]
}

apply_fix() {
    local ok=0

    # If firewall-cmd is available, set both runtime (if daemon is running) and permanent.
    if has_firewall_cmd; then
        # Set permanent
        if firewall-cmd --permanent --set-default-zone="$REQUIRED_ZONE" >/dev/null 2>&1; then
            ok=1
        else
            ok=0
        fi

        # If daemon is running, set runtime too (best-effort).
        if [ "$(is_active)" = "active" ]; then
            firewall-cmd --set-default-zone="$REQUIRED_ZONE" >/dev/null 2>&1 || true
        fi
    fi

    # Fallback: edit config file directly if firewall-cmd was unavailable or failed.
    if [ $ok -eq 0 ]; then
        if [ -e "$CONF" ]; then
            # Replace existing DefaultZone= line; if not present, append.
            if grep -q '^[[:space:]]*DefaultZone[[:space:]]*=' "$CONF" 2>/dev/null; then
                sed -ri 's/^[[:space:]]*DefaultZone[[:space:]]*=.*/DefaultZone='"$REQUIRED_ZONE"'/' "$CONF" 2>/dev/null || return 1
            else
                printf "\nDefaultZone=%s\n" "$REQUIRED_ZONE" >>"$CONF" 2>/dev/null || return 1
            fi
        else
            # Try to create the file and parent dir if missing.
            mkdir -p /etc/firewalld 2>/dev/null || return 1
            printf "DefaultZone=%s\n" "$REQUIRED_ZONE" >"$CONF" 2>/dev/null || return 1
        fi
    fi

    return 0
}

# --- Main ---
echo "TWGCB-01-008-0248: Set firewalld default zone to '$REQUIRED_ZONE'"
echo

echo "Checking current state..."
show_state
echo

if check_compliance; then
    echo -e "${GREEN}Compliant: permanent default zone is '$REQUIRED_ZONE'.${RESET}"
    exit 0
else
    echo -e "${RED}Non-compliant: permanent default zone is not '$REQUIRED_ZONE'.${RESET}"
fi

while true; do
    echo -n "Apply fix now (set default zone to '$REQUIRED_ZONE')? [Y]es / [N]o / [C]ancel: "
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
