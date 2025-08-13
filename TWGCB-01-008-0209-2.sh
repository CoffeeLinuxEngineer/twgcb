#!/bin/bash
#
# TWGCB-01-008-0209: Enforce pam_pwquality rules for root (enforce_for_root)
# Target OS: Red Hat Enterprise Linux 8.5
#
# Behavior:
# - CHECK: Inspect effective PAM stacks: /etc/pam.d/system-auth and /etc/pam.d/password-auth
#          and report lines containing pam_pwquality.so (with line numbers).
# - COMPLIANCE: Compliant if BOTH files contain "pam_pwquality.so" AND "enforce_for_root" on the same line.
# - APPLY: If non-compliant and authselect is present:
#          * If current profile is custom/* -> modify /etc/authselect/<profile>/{system-auth,password-auth}
#          * Else -> create/select custom/twgcb based on current profile (preserving enabled features),
#                   then modify its files.
#          After edits, run "authselect apply-changes".
#          Fallback (no authselect): edit /etc/pam.d files directly.
# - Output: Distinguishes (File not found) vs (Permission denied). Uses bright green/red messages.
#
set -o pipefail

GREEN="\033[1;92m"
RED="\033[1;91m"
RESET="\033[0m"

PAMD_FILES=("/etc/pam.d/system-auth" "/etc/pam.d/password-auth")

echo "TWGCB-01-008-0209: Enforce pam_pwquality rules for root (enforce_for_root)"
echo "Checking files:"
for f in "${PAMD_FILES[@]}"; do echo "  - $f"; done
echo "Check results:"

show_lines() {
    local f="$1"
    grep -n -E '^[[:space:]]*password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so\b.*' "$f" 2>/dev/null \
      | sed 's/^[0-9][0-9]*/Line: &:/'
}

has_enforce_for_root_line() {
    local f="$1"
    [ ! -r "$f" ] && return 1
    grep -Eq '^[[:space:]]*password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so\b.*\benforce_for_root\b' "$f"
}

has_pwquality_line() {
    local f="$1"
    [ ! -r "$f" ] && return 1
    grep -Eq '^[[:space:]]*password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so\b' "$f"
}

# ---- Display current effective PAM lines and collect compliance
NONCOMPL=0
for f in "${PAMD_FILES[@]}"; do
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

    if has_enforce_for_root_line "$f"; then
        :
    else
        NONCOMPL=1
        bn="$(basename "$f")"
        echo -e "${RED}Non-compliant: missing enforce_for_root on pam_pwquality.so in $bn.${RESET}"
    fi
done

if [ $NONCOMPL -eq 0 ]; then
    echo -e "${GREEN}Compliant: pam_pwquality.so has enforce_for_root in both effective PAM files.${RESET}"
    exit 0
fi

# ---- Determine authselect context ----
authselect_available() {
    command -v authselect >/dev/null 2>&1
}

get_profile_id() {
    authselect current 2>/dev/null | awk -F': ' '/^Profile ID:/ {print $2; exit}'
}

get_enabled_features() {
    # Try "Enabled features: a, b" format
    local line
    line="$(authselect current 2>/dev/null | awk -F': ' '/^Enabled features:/ {print $2; exit}')"
    if [ -n "$line" ]; then
        # Split by commas/spaces into tokens
        echo "$line" | tr ',' ' ' | xargs
        return 0
    fi
    # Try hyphen list format
    authselect current 2>/dev/null | awk '/^- /{print $2}' | xargs
}

# ---- Apply fix ----
while true; do
    echo -n "Apply fix now (ensure enforce_for_root in PAM; use authselect if available)? [Y]es / [N]o / [C]ancel: "
    read -rsn1 key
    echo
    case "$key" in
        [Yy])
            APPLY_FAIL=0

            if authselect_available; then
                PROFILE_ID="$(get_profile_id)"
                FEATURES="$(get_enabled_features)"
                if [[ -n "$PROFILE_ID" && "$PROFILE_ID" == custom/* ]]; then
                    BASE_DIR="/etc/authselect/$PROFILE_ID"
                    echo "Active authselect profile: $PROFILE_ID"
                else
                    # Create/select custom profile "twgcb" based on current base (default to sssd if unknown)
                    BASE="${PROFILE_ID:-sssd}"
                    # If PROFILE_ID contains path fragments (e.g., "sssd"), use that token only
                    BASE="${BASE##*/}"
                    if [ ! -d "/etc/authselect/custom/twgcb" ]; then
                        if ! authselect create-profile twgcb -b "$BASE" --symlink-meta >/dev/null 2>&1; then
                            echo -e "${RED}Failed to create custom profile based on '$BASE'.${RESET}"
                            APPLY_FAIL=1
                        fi
                    fi
                    if [ $APPLY_FAIL -eq 0 ]; then
                        echo "Selecting profile: custom/twgcb ${FEATURES}"
                        if ! authselect select custom/twgcb ${FEATURES} >/dev/null 2>&1; then
                            echo -e "${RED}Failed to select custom/twgcb profile.${RESET}"
                            APPLY_FAIL=1
                        fi
                    fi
                    BASE_DIR="/etc/authselect/custom/twgcb"
                fi

                # Modify template files under BASE_DIR
                for fn in system-auth password-auth; do
                    target="$BASE_DIR/$fn"
                    if [ ! -e "$target" ]; then
                        echo -e "${RED}Failed to apply for $target: file not found.${RESET}"
                        APPLY_FAIL=1
                        continue
                    fi
                    if [ ! -w "$target" ]; then
                        echo -e "${RED}Failed to apply for $target: permission denied.${RESET}"
                        APPLY_FAIL=1
                        continue
                    fi

                    # If a pam_pwquality line exists: append enforce_for_root if missing
                    if grep -Eq '^[[:space:]]*password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so\b' "$target"; then
                        if ! grep -Eq '^[[:space:]]*password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so\b.*\benforce_for_root\b' "$target"; then
                            if ! sed -ri '/^[[:space:]]*password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so\b/ {/enforce_for_root/! s/$/ enforce_for_root/ }' "$target"; then
                                echo -e "${RED}Failed to modify $target.${RESET}"
                                APPLY_FAIL=1
                            fi
                        fi
                    else
                        # Append a minimal compliant line
                        if ! printf "%s\n" "password    requisite     pam_pwquality.so enforce_for_root" >> "$target"; then
                            echo -e "${RED}Failed to add pam_pwquality.so line to $target.${RESET}"
                            APPLY_FAIL=1
                        fi
                    fi
                done

                # Apply changes
                if [ $APPLY_FAIL -eq 0 ]; then
                    if ! authselect apply-changes >/dev/null 2>&1; then
                        echo -e "${RED}Failed to run 'authselect apply-changes'.${RESET}"
                        APPLY_FAIL=1
                    fi
                fi

            else
                # Fallback: directly edit /etc/pam.d files
                for f in "${PAMD_FILES[@]}"; do
                    if [ ! -e "$f" ]; then
                        echo -e "${RED}Failed to apply for $f: file not found.${RESET}"
                        APPLY_FAIL=1
                        continue
                    fi
                    if [ ! -w "$f" ]; then
                        echo -e "${RED}Failed to apply for $f: permission denied.${RESET}"
                        APPLY_FAIL=1
                        continue
                    fi
                    if has_pwquality_line "$f"; then
                        if ! has_enforce_for_root_line "$f"; then
                            sed -ri '/^[[:space:]]*password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so\b/ {/enforce_for_root/! s/$/ enforce_for_root/ }' "$f" \
                                || { echo -e "${RED}Failed to modify $f.${RESET}"; APPLY_FAIL=1; }
                        fi
                    else
                        printf "%s\n" "password    requisite     pam_pwquality.so enforce_for_root" >> "$f" \
                            || { echo -e "${RED}Failed to add pam_pwquality.so line to $f.${RESET}"; APPLY_FAIL=1; }
                    fi
                done
            fi

            # Re-check on effective PAM files
            if [ $APPLY_FAIL -eq 0 ]; then
                NONCOMPL=0
                for f in "${PAMD_FILES[@]}"; do
                    has_enforce_for_root_line "$f" || NONCOMPL=1
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
