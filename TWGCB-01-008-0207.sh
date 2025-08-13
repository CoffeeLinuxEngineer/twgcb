#!/bin/bash
#
# TWGCB-01-008-0207: Enable cron logging (rsyslog)
# Target OS: Red Hat Enterprise Linux 8.5
#
# This script ensures rsyslog logs all cron messages to /var/log/cron by having:
#     cron.* /var/log/cron
# in either /etc/rsyslog.conf or a file under /etc/rsyslog.d/*.conf.
#
# Features:
# - Shows matches with "Line: " + line numbers per file
# - Distinguishes (File not found) vs (Permission denied)
# - Color-coded compliant/non-compliant and success/failure
# - Y/N/C prompt before applying
# - Creates /etc/rsyslog.d/60-cron-logging.conf if needed and restarts rsyslog
#
set -o pipefail

GREEN="\033[1;92m"
RED="\033[1;91m"
RESET="\033[0m"

DEST="/etc/rsyslog.d/60-cron-logging.conf"

# Build file list
FILES=("/etc/rsyslog.conf")
shopt -s nullglob
for f in /etc/rsyslog.d/*.conf; do
    FILES+=("$f")
done
shopt -u nullglob

echo "TWGCB-01-008-0207: Enable cron logging (rsyslog)"
echo "Checking files:"
for f in "${FILES[@]}"; do
    echo "  - $f"
done
echo "Check results:"

pattern='^[[:space:]]*[Cc][Rr][Oo][Nn]\.\*[[:space:]]+/var/log/cron([[:space:]]|$)'

show_lines() {
    local f="$1"
    grep -nE "$pattern" "$f" 2>/dev/null | sed 's/^\([0-9]\+\):/Line: \1:/'
}

file_has_rule() {
    local f="$1"
    [ ! -r "$f" ] && return 1
    grep -Eq "$pattern" "$f"
}

check_compliance() {
    local any=1
    for f in "${FILES[@]}"; do
        if file_has_rule "$f"; then
            any=0
            break
        fi
    done
    return $any
}

# ---- Display current state per file ----
for f in "${FILES[@]}"; do
    echo "$f:"
    if [ -e "$f" ]; then
        if [ -r "$f" ]; then
            if ! show_lines "$f" || [ -z "$(show_lines "$f")" ]; then
                echo "(No matching line found)"
            fi
        else
            echo "(Permission denied)"
        fi
    else
        echo "(File not found)"
    fi
done

if check_compliance; then
    echo -e "${GREEN}Compliant: cron.* is already logged to /var/log/cron.${RESET}"
    exit 0
else
    echo -e "${RED}Non-compliant: missing 'cron.* /var/log/cron' in rsyslog configuration.${RESET}"
fi

# ---- Prompt to apply ----
while true; do
    echo -n "Apply fix now (add 'cron.* /var/log/cron' and restart rsyslog)? [Y]es / [N]o / [C]ancel: "
    read -rsn1 key
    echo
    case "$key" in
        [Yy])
            # Ensure /etc/rsyslog.d exists
            if [ ! -d "/etc/rsyslog.d" ]; then
                echo -e "${RED}Failed to apply: /etc/rsyslog.d not found.${RESET}"
                exit 1
            fi
            # Check write permission (either existing file or directory)
            if [ -e "$DEST" ] && [ ! -w "$DEST" ]; then
                echo -e "${RED}Failed to apply: permission denied writing $DEST.${RESET}"
                exit 1
            fi
            if [ ! -e "$DEST" ] && [ ! -w "/etc/rsyslog.d" ]; then
                echo -e "${RED}Failed to apply: permission denied creating $DEST.${RESET}"
                exit 1
            fi

            # Create/append the rule if missing in DEST
            if [ -e "$DEST" ]; then
                if ! grep -Eq "$pattern" "$DEST"; then
                    printf "%s\n" "cron.* /var/log/cron" >> "$DEST" || {
                        echo -e "${RED}Failed to write to $DEST.${RESET}"; exit 1; }
                fi
            else
                printf "%s\n" "cron.* /var/log/cron" > "$DEST" || {
                    echo -e "${RED}Failed to create $DEST.${RESET}"; exit 1; }
                chmod 0644 "$DEST" 2>/dev/null || true
            fi

            # Restart rsyslog
            if ! systemctl restart rsyslog; then
                echo -e "${RED}Failed to restart rsyslog.${RESET}"
                exit 1
            fi

            # Rebuild file list (DEST may be new), then re-check
            FILES=("/etc/rsyslog.conf")
            shopt -s nullglob
            for f in /etc/rsyslog.d/*.conf; do FILES+=("$f"); done
            shopt -u nullglob

            if check_compliance; then
                echo -e "${GREEN}Successfully applied.${RESET}"
                exit 0
            else
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
