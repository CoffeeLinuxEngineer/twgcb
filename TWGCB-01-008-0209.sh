#!/bin/bash
#
# TWGCB-01-008-0209: Enforce pam_pwquality rules for root (enforce_for_root)
# Target OS: Red Hat Enterprise Linux 8.5
#
# This script checks and enforces that both system-auth and password-auth
# include "password requisite pam_pwquality.so ... enforce_for_root" using authselect.
# - Detects active authselect profile; uses /etc/authselect/custom/<profile> when applicable,
#   otherwise /etc/authselect/
# - Treats as compliant if "enforce_for_root" appears anywhere on the same line as pam_pwquality.so
# - Shows matching lines with "Line: " prefix for line numbers
# - Distinguishes (File not found) vs (Permission denied)
# - Prompts Y/N/C before applying, runs "authselect apply-changes" after edits
# - Uses bright green/red messages for compliant/non-compliant and success/failure
#
set -o pipefail

GREEN="\033[1;92m"
RED="\033[1;91m"
RESET="\033[0m"

FILES=(system-auth password-auth)

# Determine base path for authselect-managed files
get_profile_id() {
    # Prefer "Profile ID:" line if present
    if authselect current >/dev/null 2>&1; then
        local id
        id="$(authselect current 2>/dev/null | awk -F': ' '/^Profile ID:/ {print $2; exit}')"
        if [ -n "$id" ]; then
            printf "%s" "$id"
            return 0
        fi
        # Fallback to first token approach (older outputs)
        id="$(authselect current 2>/dev/null | awk 'NR==1{print $3}')"
        printf "%s" "$id"
        return 0
    fi
    return 1
}

get_base_dir() {
    local pid
    pid="$(get_profile_id)"
    if [ -n "$pid" ] && [[ "$pid" == custom/* ]]; then
        printf "/etc/authselect/%s" "$pid"
    else
        printf "/etc/authselect"
    fi
}

BASE_DIR="$(get_base_dir)"
# If detection failed, default to /etc/authselect
[ -z "$BASE_DIR" ] && BASE_DIR="/etc/authselect"

echo "TWGCB-01-008-0209: Enforce pam_pwquality rules for root (enforce_for_root)"
echo "Active authselect base: $BASE_DIR"
echo "Checking files:"
for fn in "${FILES[@]}"; do
    echo "  - $BASE_DIR/$fn"
done
echo "Check results:"

# Helpers
show_lines() {
    local f="$1"
    grep -n -E '^[[:space:]]*password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so\b.*' "$f" 2>/dev/null \
        | sed 's/^[0-9][0-9]*/Line: &:/'
}

has_enforce_for_root() {
    local f="$1"
    [ ! -r "$f" ] && return 1
    grep -Eq '^[[:space:]]*password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so\b.*\benforce_for_root\b' "$f"
}

has_pwquality_line() {
    local f="$1"
    [ ! -r "$f" ] && return 1
    grep -Eq '^[[:space:]]*password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so\b' "$f"
}

# Display current lines and collect compliance
NONCOMPL=0
for fn in "${FILES[@]}"; do
    f="$BASE_DIR/$fn"
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

    if has_enforce_for_root "$f"; then
        :
    else
        NONCOMPL=1
        echo -e "${RED}Non-compliant: missing enforce_for_root on pam_pwquality.so in $fn.${RESET}"
    fi
done

if [ $NONCOMPL -eq 0 ]; then
    echo -e "${GREEN}Compliant: pam_pwquality.so has enforce_for_root in both files.${RESET}"
    exit 0
fi

# Prompt to apply
while true; do
    echo -n "Apply fix now (append enforce_for_root to pam_pwquality.so lines and apply authselect)? [Y]es / [N]o / [C]ancel: "
    read -rsn1 key
    echo
    case "$key" in
        [Yy])
            APPLY_FAIL=0
            for fn in "${FILES[@]}"; do
                f="$BASE_DIR/$fn"
                if [ ! -e "$f" ]; then
                    echo -e "${RED}Failed to apply for $fn: file not found.${RESET}"
                    APPLY_FAIL=1
                    continue
                fi
                if [ ! -w "$f" ]; then
                    echo -e "${RED}Failed to apply for $fn: permission denied.${RESET}"
                    APPLY_FAIL=1
                    continue
                fi

                if has_pwquality_line "$f"; then
                    # Append enforce_for_root if not already present
                    if ! has_enforce_for_root "$f"; then
                        if ! sed -ri 's/^([[:space:]]*password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so\b[[:space:]]*.*[^[:alnum:]_]?)$/\1 enforce_for_root/' "$f"; then
                            echo -e "${RED}Failed to modify $fn.${RESET}"
                            APPLY_FAIL=1
                        fi
                    fi
                else
                    # No pam_pwquality line: add a minimal compliant line
                    printf "%s\n" "password    requisite     pam_pwquality.so enforce_for_root" >> "$f" || {
                        echo -e "${RED}Failed to add pam_pwquality.so line to $fn.${RESET}"
                        APPLY_FAIL=1
                    }
                fi
            done

            # Apply authselect changes if edits succeeded
            if [ $APPLY_FAIL -eq 0 ]; then
                if authselect apply-changes >/dev/null 2>&1; then
                    :
                else
                    echo -e "${RED}Failed to run 'authselect apply-changes'.${RESET}"
                    APPLY_FAIL=1
                fi
            fi

            # Re-check
            if [ $APPLY_FAIL -eq 0 ]; then
                NONCOMPL=0
                for fn in "${FILES[@]}"; do
                    f="$BASE_DIR/$fn"
                    has_enforce_for_root "$f" || NONCOMPL=1
                done
                if [ $NONCOMPL -eq 0 ]; then
                    echo -e "${GREEN}Successfully applied.${RESET}"
                    exit 0
                else
                    echo -e "${RED}Failed to apply.${RESET}"
                    exit 1
                fi
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
