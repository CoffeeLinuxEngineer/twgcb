#!/bin/bash
# TWGCB-01-008-0189: Ensure no processes run in SELinux type 'unconfined_service_t'
# Target OS: RHEL 8.5
# This script:
#   - Checks for processes running under SELinux type unconfined_service_t
#   - If found, lists them and interactively helps you relabel their binaries to an appropriate confined type
#   - Offers optional persistence via semanage (if available) + restorecon
# Notes:
#   - You must decide the correct confined type per service (e.g., httpd_exec_t for /usr/sbin/httpd).
#   - No Chinese in code.

set -u

CLR_GREEN="\e[1;92m"
CLR_RED="\e[1;91m"
CLR_YELLOW="\e[1;93m"
CLR_RESET="\e[0m"

echo "TWGCB-01-008-0189: Ensure no processes run as 'unconfined_service_t'"

have_semanage() {
    command -v semanage >/dev/null 2>&1
}

list_unconfined() {
    # Output: PID TYPE CMD
    # ps -eZ: first column is SELinux context like user:role:type:level
    # We'll extract the 3rd field (type) by splitting on ':'
    # Use awk to robustly handle spaces in the command by printing the remainder
    ps -eZ -o label,pid,comm 2>/dev/null | awk '
        NR>1 {
            split($1, a, ":");
            type=a[3];
            if (type=="unconfined_service_t") {
                # $3 is the short command (comm). For full path, try /proc/<pid>/exe later.
                printf("%s %s %s\n", $2, type, $3);
            }
        }
    '
}

show_status() {
    echo
    echo "Checking for unconfined_service_t processes..."
    local rows
    rows="$(list_unconfined)"
    if [ -z "$rows" ]; then
        echo "No processes found in unconfined_service_t."
    else
        echo "Found the following processes in unconfined_service_t:"
        echo "PID   TYPE                     CMD (exe path if resolvable)"
        echo "$rows" | while read -r pid type cmd; do
            exe_path="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
            if [ -n "${exe_path:-}" ]; then
                printf "%-5s %-24s %s (%s)\n" "$pid" "$type" "$cmd" "$exe_path"
            else
                printf "%-5s %-24s %s\n" "$pid" "$type" "$cmd"
            fi
        done
    fi
    echo
}

check_compliance() {
    [ -z "$(list_unconfined)" ]
}

apply_fix_for_one() {
    local exe_path="$1"
    local new_type="$2"

    if [ ! -e "$exe_path" ]; then
        echo -e "${CLR_RED}Path not found: $exe_path${CLR_RESET}"
        return 1
    fi

    # Try persistent label first if semanage exists; fallback to chcon (temporary until restorecon)
    if have_semanage; then
        if semanage fcontext -a -t "$new_type" "$exe_path" 2>/dev/null; then
            if restorecon -v "$exe_path" 2>/dev/null; then
                echo "Applied persistent label with semanage + restorecon."
                return 0
            fi
        fi
        echo -e "${CLR_YELLOW}Persistent labeling failed or partially applied; attempting temporary chcon...${CLR_RESET}"
    fi

    chcon -t "$new_type" "$exe_path"
}

apply_fix() {
    # Interactive loop over each offending binary path the user wants to relabel.
    local rows exe_path new_type confirm
    rows="$(list_unconfined)"
    if [ -z "$rows" ]; then
        echo "Nothing to fix."
        return 0
    fi

    echo "Interactive relabel:"
    echo "For each offending process, specify the binary path and the intended SELinux *exec* type."
    echo "Examples:"
    echo "  /usr/sbin/httpd    -> httpd_exec_t"
    echo "  /usr/sbin/sshd     -> sshd_exec_t"
    echo

    # Derive a unique set of executable paths from PIDs (best-effort).
    mapfile -t paths < <(echo "$rows" | awk '{print $1}' | while read -r pid; do readlink -f "/proc/${pid}/exe" 2>/dev/null; done | sort -u)

    if [ "${#paths[@]}" -eq 0 ]; then
        echo "Could not resolve executable paths automatically. You can input paths manually."
    else
        echo "Detected executable paths:"
        for p in "${paths[@]}"; do
            echo "  - $p"
        done
        echo
    fi

    while true; do
        echo -ne "Enter full path to the binary to relabel (or just press Enter to stop): "
        IFS= read -r exe_path
        if [ -z "${exe_path}" ]; then
            echo "Stopping relabel loop."
            break
        fi
        if [ ! -e "$exe_path" ]; then
            echo -e "${CLR_RED}Path does not exist: $exe_path${CLR_RESET}"
            continue
        fi

        echo -ne "Enter target SELinux exec type for '$exe_path' (e.g., httpd_exec_t): "
        IFS= read -r new_type
        if [ -z "${new_type}" ]; then
            echo -e "${CLR_RED}Type cannot be empty.${CLR_RESET}"
            continue
        fi

        echo -ne "Confirm relabel '$exe_path' -> type '$new_type'? [Y/N]: "
        read -rsn1 confirm; echo
        case "$confirm" in
            [Yy])
                if apply_fix_for_one "$exe_path" "$new_type"; then
                    echo "Relabel succeeded for: $exe_path"
                else
                    echo -e "${CLR_RED}Relabel failed for: $exe_path${CLR_RESET}"
                fi
                ;;
            *)
                echo "Skipped: $exe_path"
                ;;
        esac
    done
}

# ---- Main flow ----
show_status
if check_compliance; then
    echo -e "${CLR_GREEN}Compliant: No processes are running in unconfined_service_t.${CLR_RESET}"
    exit 0
else
    echo -e "${CLR_RED}Non-compliant: One or more processes are running in unconfined_service_t.${CLR_RESET}"
fi

while true; do
    echo -ne "${CLR_YELLOW}Apply fix now (interactive relabel with chcon/semanage)? [Y]es / [N]o / [C]ancel: ${CLR_RESET}"
    read -rsn1 key
    echo
    case "$key" in
        [Yy])
            [ "$EUID" -ne 0 ] && echo -e "${CLR_RED}Failed to apply: please run as root.${CLR_RESET}" && exit 1
            apply_fix
            show_status
            if check_compliance; then
                echo -e "${CLR_GREEN}Successfully applied${CLR_RESET}"
                exit 0
            else
                echo -e "${CLR_RED}Failed to apply${CLR_RESET}"
                exit 1
            fi
            ;;
        [Nn]) echo "Skipped."; exit 1 ;;
        [Cc]) echo "Canceled."; exit 2 ;;
        *) echo "Invalid input." ;;
    esac
done
