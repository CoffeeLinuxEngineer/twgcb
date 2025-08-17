#!/bin/bash
#
# TWGCB-01-008-0207 (variant): Ensure 'cron.* /var/log/cron' exists in /etc/rsyslog.d/90-google.conf if present
# Target OS: Red Hat Enterprise Linux 8.5
#
# Behavior vs. standard 0207:
# - Still considers the system COMPLIANT if the rule exists in ANY rsyslog config.
# - Additionally offers to ADD the rule to /etc/rsyslog.d/90-google.conf when that file exists,
#   and can optionally COMMENT duplicate rules elsewhere to avoid double logging.
#
set -o pipefail

GREEN="\033[1;92m"
RED="\033[1;91m"
RESET="\033[0m"

MAIN="/etc/rsyslog.conf"
PREFERRED="/etc/rsyslog.d/90-google.conf"
FALLBACK="/etc/rsyslog.d/60-cron-logging.conf"

# Build list
FILES=("$MAIN")
shopt -s nullglob
for f in /etc/rsyslog.d/*.conf; do FILES+=("$f"); done
shopt -u nullglob

echo "TWGCB-01-008-0207 (variant): Prefer rule in $PREFERRED"
echo "Checking files:"
for f in "${FILES[@]}"; do echo "  - $f"; done
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

any_has_rule() {
    local any=1
    for f in "${FILES[@]}"; do
        if file_has_rule "$f"; then any=0; break; fi
    done
    return $any
}

preferred_has_rule=1
dest="$FALLBACK"
if [ -e "$PREFERRED" ]; then dest="$PREFERRED"; fi

# ---- Display matches per file ----
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

# ---- Compliance summary (global) ----
if any_has_rule; then
    echo -e "${GREEN}Compliant: cron.* is already logged to /var/log/cron.${RESET}"
else
    echo -e "${RED}Non-compliant: missing 'cron.* /var/log/cron' in rsyslog configuration.${RESET}"
fi

# ---- Preferred destination status ----
if [ -e "$dest" ] && [ -r "$dest" ] && file_has_rule "$dest"; then
    preferred_has_rule=0
fi
if [ "$dest" = "$PREFERRED" ]; then
    if [ $preferred_has_rule -eq 0 ]; then
        echo "Preferred file $PREFERRED already contains the rule."
        exit 0
    else
        echo "Preferred file $PREFERRED does not contain the rule."
    fi
else
    echo "$PREFERRED not present; will use $FALLBACK if you choose to apply."
fi

# ---- Prompt to add to preferred (or fallback) ----
while true; do
    echo -n "Add 'cron.* /var/log/cron' to $dest now? [Y]es / [N]o / [C]ancel: "
    read -rsn1 key
    echo
    case "$key" in
        [Yy])
            # Writable check
            if [ "$dest" = "$PREFERRED" ] && [ ! -e "$dest" ]; then
                echo -e "${RED}Failed to apply: $dest does not exist.${RESET}"
                exit 1
            fi
            if [ -e "$dest" ] && [ ! -w "$dest" ]; then
                echo -e "${RED}Failed to apply: permission denied writing $dest.${RESET}"
                exit 1
            fi
            if [ ! -e "$dest" ] && [ ! -w "/etc/rsyslog.d" ]; then
                echo -e "${RED}Failed to apply: permission denied creating $dest.${RESET}"
                exit 1
            fi
            # Add if missing
            if [ -e "$dest" ]; then
                if ! grep -Eq "$pattern" "$dest"; then
                    printf "%s\n" "cron.* /var/log/cron" >> "$dest" || {
                        echo -e "${RED}Failed to write to $dest.${RESET}"; exit 1; }
                fi
            else
                printf "%s\n" "cron.* /var/log/cron" > "$dest" || {
                    echo -e "${RED}Failed to create $dest.${RESET}"; exit 1; }
                chmod 0644 "$dest" 2>/dev/null || true
            fi

            # Optional: comment duplicates elsewhere
            DUP_FOUND=0
            for f in "${FILES[@]}"; do
                [ "$f" = "$dest" ] && continue
                if [ -w "$f" ] && grep -Eq "$pattern" "$f"; then
                    DUP_FOUND=1
                fi
            done
            if [ $DUP_FOUND -eq 1 ]; then
                while true; do
                    echo -n "Comment duplicate rules elsewhere to avoid double logging? [Y]es / [N]o: "
                    read -rsn1 k2
                    echo
                    case "$k2" in
                        [Yy])
                            for f in "${FILES[@]}"; do
                                [ "$f" = "$dest" ] && continue
                                if [ -w "$f" ]; then
                                    sed -ri 's/^([[:space:]]*[Cc][Rr][Oo][Nn]\.\*[[:space:]]+\/var\/log\/cron.*)$/# \1/' "$f" 2>/dev/null || true
                                fi
                            done
                            break
                            ;;
                        [Nn]) break ;;
                        *) echo "Invalid input." ;;
                    esac
                done
            fi

            # Restart and re-check
            if ! systemctl restart rsyslog; then
                echo -e "${RED}Failed to restart rsyslog.${RESET}"
                exit 1
            fi

            if [ -e "$dest" ] && file_has_rule "$dest"; then
                echo -e "${GREEN}Successfully applied to $dest.${RESET}"
                exit 0
            else
                echo -e "${RED}Failed to apply to $dest.${RESET}"
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
