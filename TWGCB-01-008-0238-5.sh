#!/bin/bash
# TWGCB-01-008-0238: Ensure Bash auto-logout (TMOUT) is set (<= 900 and > 0) with readonly and export
# Platform: RHEL 8.5
# Policy line example: readonly TMOUT=900 ; export TMOUT
# Notes:
# - Checks /etc/bashrc, /etc/profile, and all /etc/profile.d/*.sh
# - Shows line numbers prefixed with "Line: " for any lines containing TMOUT (including commented)
# - Compliance requires an active (non-commented) line that looks like: readonly TMOUT=<n> ; export TMOUT
#   with 1 <= n <= 900. Trailing comments after 'export TMOUT' are allowed.
# - Apply writes /etc/profile.d/00-tmout.sh with the required line.
# - Uses bright green/red messages and prompts [Y]es / [N]o / [C]ancel.
# - No Chinese in code.

TARGETS=(
  "/etc/bashrc"
  "/etc/profile"
)

PROFILE_D_DIR="/etc/profile.d"
APPLY_FILE="${PROFILE_D_DIR}/00-tmout.sh"

# Colors (bright)
GREEN="\e[92m"
RED="\e[91m"
YELLOW="\e[93m"
RESET="\e[0m"

print_header() {
    echo "TWGCB-01-008-0238: Set Bash idle timeout (TMOUT) with readonly and export (<=900, >0)"
    echo
}

show_matches() {
    echo "Checking files:"
    for f in "${TARGETS[@]}"; do
        echo "  - $f"
    done
    echo "  - ${PROFILE_D_DIR}/*.sh"
    echo
    echo "Check results:"

    # Show matches in regular files
    for f in "${TARGETS[@]}"; do
        if [ ! -e "$f" ]; then
            echo "$f: (File not found)"
            continue
        fi
        if [ ! -r "$f" ]; then
            echo "$f: (Permission denied)"
            continue
        fi
        if ! grep -n "TMOUT" "$f" 2>/dev/null | sed 's/^\([0-9]\+\):/Line: \1:/' ; then
            echo "$f: (No matching line found)"
        fi
    done

    # Show matches in profile.d/*.sh
    if [ -d "$PROFILE_D_DIR" ] && ls -1 "${PROFILE_D_DIR}"/*.sh >/dev/null 2>&1; then
        for f in "${PROFILE_D_DIR}"/*.sh; do
            if [ ! -r "$f" ]; then
                echo "$f: (Permission denied)"
                continue
            fi
            if ! grep -n "TMOUT" "$f" 2>/dev/null | sed "s#^\([0-9]\+\):#${f}: Line: \1:#"; then
                # Only print something if no match and user wants verbose; otherwise, stay quiet per-file
                :
            fi
        done
    else
        echo "${PROFILE_D_DIR}: (No .sh files or directory missing)"
    fi
}

check_one_file_active_tmout() {
    # Args: file
    # Echo numeric value if compliant line found; else echo empty
    local file="$1"
    [ ! -r "$file" ] && return 1
    awk '
        {
            line=$0
            ltrim=line; sub(/^[ \t]+/, "", ltrim)
            if (ltrim ~ /^#/) next
            # Match: readonly TMOUT=<num> ; export TMOUT (allow spaces, allow trailing comment)
            # We also allow additional whitespace around semicolon.
            if (ltrim ~ /^readonly[ \t]+TMOUT=[0-9]+[ \t]*;[ \t]*export[ \t]+TMOUT([ \t]+#.*)?$/) {
                # Extract number
                n = ltrim
                sub(/^readonly[ \t]+TMOUT=/, "", n)
                sub(/[ \t]*;.*$/, "", n)
                print n
            }
        }
    ' "$file"
}

check_compliance() {
    # Returns 0 if compliant, 1 if non-compliant, 2 if cannot verify
    # Search TARGETS and /etc/profile.d/*.sh
    local val found=0

    # Read main files
    for f in "${TARGETS[@]}"; do
        if [ -e "$f" ] && [ ! -r "$f" ]; then
            return 2
        fi
        if [ -r "$f" ]; then
            val="$(check_one_file_active_tmout "$f" | tail -n1)"
            if [ -n "$val" ]; then
                if [ "$val" -ge 1 ] 2>/dev/null && [ "$val" -le 900 ] 2>/dev/null; then
                    return 0
                else
                    found=1
                fi
            fi
        fi
    done

    # Read profile.d files
    if [ -d "$PROFILE_D_DIR" ]; then
        for f in "${PROFILE_D_DIR}"/*.sh 2>/dev/null; do
            [ -e "$f" ] || continue
            if [ ! -r "$f" ]; then
                return 2
            fi
            val="$(check_one_file_active_tmout "$f" | tail -n1)"
            if [ -n "$val" ]; then
                if [ "$val" -ge 1 ] 2>/dev/null && [ "$val" -le 900 ] 2>/dev/null; then
                    return 0
                else
                    found=1
                fi
            fi
        done
    fi

    # If we saw a TMOUT line but out of range, treat as non-compliant
    if [ $found -eq 1 ]; then
        return 1
    fi

    return 1
}

apply_fix() {
    # Create /etc/profile.d/00-tmout.sh with the required line
    local dir="$PROFILE_D_DIR"
    local file="$APPLY_FILE"
    if [ ! -d "$dir" ]; then
        echo -e "${RED}Failed to apply${RESET}"
        echo "(Directory not found: $dir)"
        return 1
    fi
    if [ ! -w "$dir" ]; then
        echo -e "${RED}Failed to apply${RESET}"
        echo "(Permission denied to write in $dir)"
        return 1
    fi

    {
        echo "# Enforce Bash idle timeout per TWGCB-01-008-0238"
        echo "readonly TMOUT=900 ; export TMOUT"
    } > "$file" 2>/dev/null || {
        echo -e "${RED}Failed to apply${RESET}"
        return 1
    }

    chmod 0644 "$file" 2>/dev/null || true

    # Re-check
    if check_compliance; then
        echo -e "${GREEN}Successfully applied${RESET}"
        return 0
    else
        echo -e "${RED}Failed to apply${RESET}"
        return 1
    fi
}

main() {
    print_header
    show_matches
    echo

    check_compliance
    rc=$?

    if [ $rc -eq 0 ]; then
        echo -e "${GREEN}Compliant: TMOUT is configured (<= 900 and > 0) with readonly and export.${RESET}"
        exit 0
    elif [ $rc -eq 2 ]; then
        echo -e "${RED}Non-compliant: Unable to verify (permission denied).${RESET}"
        exit 1
    else
        echo -e "${RED}Non-compliant: TMOUT is missing or not within 1..900 with readonly+export.${RESET}"
        while true; do
            echo -n "Apply fix now (write ${APPLY_FILE} with 'readonly TMOUT=900 ; export TMOUT')? [Y]es / [N]o / [C]ancel: "
            read -rsn1 key
            echo
            case "$key" in
                [Yy])
                    apply_fix
                    exit $?
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
    fi
}

main
