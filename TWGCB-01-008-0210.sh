#!/bin/bash
#
# TWGCB-01-008-0210: Minimum password length (pwquality.minlen & login.defs PASS_MIN_LEN)
# Target OS: Red Hat Enterprise Linux 8.5
# - Checks and enforces:
#     /etc/security/pwquality.conf -> minlen = 12  (accept >=12 as compliant)
#     /etc/login.defs              -> PASS_MIN_LEN 12 (accept >=12 as compliant)
# - Shows matching lines with "Line: " prefix for line numbers
# - Distinguishes (File not found) vs (Permission denied)
# - Prompts Y/N/C before applying
# - Uses bright green/red messages for compliant/non-compliant and success/failure
#
set -o pipefail

PWQ="/etc/security/pwquality.conf"
LDEF="/etc/login.defs"
REQ_MIN=12

GREEN="\033[1;92m"
RED="\033[1;91m"
RESET="\033[0m"

echo "TWGCB-01-008-0210: Minimum password length (pwquality.minlen & login.defs PASS_MIN_LEN)"
echo "Checking files:"
echo "  - $PWQ"
echo "  - $LDEF"
echo "Check results:"

# ---- helpers ----
show_lines_pwq() {
    # Show minlen lines in pwquality.conf
    grep -n -E "^[[:space:]]*minlen[[:space:]]*=" "$PWQ" 2>/dev/null | sed 's/^[0-9][0-9]*/Line: &:/'
}
show_lines_ldef() {
    # Show PASS_MIN_LEN lines in login.defs
    grep -n -E "^[[:space:]]*PASS_MIN_LEN[[:space:]]+" "$LDEF" 2>/dev/null | sed 's/^[0-9][0-9]*/Line: &:/'
}

get_pwq_minlen() {
    # Extract max minlen value from uncommented lines; prints number or empty
    [ ! -r "$PWQ" ] && return 1
    awk '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*minlen[[:space:]]*=/ {
            gsub(/[[:space:]]*/,"")
            split($0,a,"=")
            if (a[2] ~ /^[0-9]+$/) {
                if (a[2] > max) max=a[2]
                if (max=="") max=a[2]
            }
        }
        END { if (max!="") print max }
    ' "$PWQ"
}

get_ldef_minlen() {
    # Extract max PASS_MIN_LEN value from uncommented lines; prints number or empty
    [ ! -r "$LDEF" ] && return 1
    awk '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*PASS_MIN_LEN[[:space:]]+/ {
            for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {
                if ($i > max) max=$i
                if (max=="") max=$i
            }
        }
        END { if (max!="") print max }
    ' "$LDEF"
}

check_pwq_compliant() {
    local val
    val="$(get_pwq_minlen)"
    [ -n "$val" ] && [ "$val" -ge "$REQ_MIN" ]
}
check_ldef_compliant() {
    local val
    val="$(get_ldef_minlen)"
    [ -n "$val" ] && [ "$val" -ge "$REQ_MIN" ]
}

# ---- display current lines ----
echo "$PWQ:"
if [ -e "$PWQ" ]; then
    if [ -r "$PWQ" ]; then
        if ! show_lines_pwq || [ -z "$(show_lines_pwq)" ]; then
            echo "(No matching line found)"
        fi
    else
        echo "(Permission denied)"
    fi
else
    echo "(File not found)"
fi

echo "$LDEF:"
if [ -e "$LDEF" ]; then
    if [ -r "$LDEF" ]; then
        if ! show_lines_ldef || [ -z "$(show_lines_ldef)" ]; then
            echo "(No matching line found)"
        fi
    else
        echo "(Permission denied)"
    fi
else
    echo "(File not found)"
fi

# ---- compliance summary ----
PWQ_OK=1
LDEF_OK=1
check_pwq_compliant && PWQ_OK=0
check_ldef_compliant && LDEF_OK=0

if [ $PWQ_OK -eq 0 ] && [ $LDEF_OK -eq 0 ]; then
    echo -e "${GREEN}Compliant: minlen in pwquality and PASS_MIN_LEN in login.defs are both >= ${REQ_MIN}.${RESET}"
    exit 0
fi

# Print which parts are failing
[ $PWQ_OK -ne 0 ] && echo -e "${RED}Non-compliant: $PWQ minlen < ${REQ_MIN} or missing.${RESET}"
[ $LDEF_OK -ne 0 ] && echo -e "${RED}Non-compliant: $LDEF PASS_MIN_LEN < ${REQ_MIN} or missing.${RESET}"

# ---- prompt to apply ----
while true; do
    echo -n "Apply fix now (set minlen=${REQ_MIN} in pwquality.conf and PASS_MIN_LEN ${REQ_MIN} in login.defs)? [Y]es / [N]o / [C]ancel: "
    read -rsn1 key
    echo
    case "$key" in
        [Yy])
            # pwquality.conf
            if [ ! -e "$PWQ" ]; then
                echo -e "${RED}Failed to apply $PWQ: file not found.${RESET}"
                PWQ_APPL=1
            elif [ ! -w "$PWQ" ]; then
                echo -e "${RED}Failed to apply $PWQ: permission denied.${RESET}"
                PWQ_APPL=1
            else
                if grep -Eq "^[[:space:]]*minlen[[:space:]]*=" "$PWQ"; then
                    sed -ri "s|^[[:space:]]*minlen[[:space:]]*=.*|minlen = ${REQ_MIN}|" "$PWQ" \
                        && PWQ_APPL=0 || PWQ_APPL=1
                else
                    printf "%s\n" "minlen = ${REQ_MIN}" >> "$PWQ" \
                        && PWQ_APPL=0 || PWQ_APPL=1
                fi
                [ $PWQ_APPL -eq 0 ] && check_pwq_compliant || true
                [ $? -eq 0 ] && echo -e "${GREEN}Applied $PWQ successfully.${RESET}" || { echo -e "${RED}Failed to apply $PWQ.${RESET}"; PWQ_APPL=1; }
            fi

            # login.defs
            if [ ! -e "$LDEF" ]; then
                echo -e "${RED}Failed to apply $LDEF: file not found.${RESET}"
                LDEF_APPL=1
            elif [ ! -w "$LDEF" ]; then
                echo -e "${RED}Failed to apply $LDEF: permission denied.${RESET}"
                LDEF_APPL=1
            else
                if grep -Eq "^[[:space:]]*PASS_MIN_LEN[[:space:]]+" "$LDEF"; then
                    sed -ri "s|^[[:space:]]*PASS_MIN_LEN[[:space:]]+[0-9]+|PASS_MIN_LEN ${REQ_MIN}|" "$LDEF" \
                        && LDEF_APPL=0 || LDEF_APPL=1
                else
                    printf "%s\n" "PASS_MIN_LEN ${REQ_MIN}" >> "$LDEF" \
                        && LDEF_APPL=0 || LDEF_APPL=1
                fi
                [ $LDEF_APPL -eq 0 ] && check_ldef_compliant || true
                [ $? -eq 0 ] && echo -e "${GREEN}Applied $LDEF successfully.${RESET}" || { echo -e "${RED}Failed to apply $LDEF.${RESET}"; LDEF_APPL=1; }
            fi

            # Final status
            if check_pwq_compliant && check_ldef_compliant; then
                echo -e "${GREEN}Successfully applied both settings.${RESET}"
                exit 0
            else
                echo -e "${RED}Failed to apply one or more settings.${RESET}"
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
