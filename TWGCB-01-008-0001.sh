#!/bin/bash
# TWGCB-01-008-0001 v3: Disable cramfs filesystem (RHEL 8.5)
# Ensures:
#   - /etc/modprobe.d/cramfs.conf contains:
#       install cramfs /bin/true
#       blacklist cramfs
#   - No cramfs mounts exist (robust detector via /proc/self/mounts)
#   - Tries to unload cramfs module if loaded
#   - Rebuilds initramfs if dracut exists
#   - Recommends reboot
set -uo pipefail

TITLE="TWGCB-01-008-0001: Disable cramfs filesystem"
CONF="/etc/modprobe.d/cramfs.conf"
FSTAB="/etc/fstab"
REQUIRED_LINES=("install cramfs /bin/true" "blacklist cramfs")

# Colors (bright)
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; BOLD="\e[1m"; RESET="\e[0m"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root.${RESET}"
    exit 1
  fi
}

has_line() { [[ -f "$1" ]] && grep -Fxq -- "$2" "$1"; }

is_module_loaded() { lsmod | awk '{print $1}' | grep -Fxq "cramfs"; }

# Robust: check /proc/self/mounts instead of relying on findmnt return codes
any_cramfs_mounts() {
  awk '($3=="cramfs"){found=1; exit} END{exit !found}' /proc/self/mounts
}

list_cramfs_mounts() {
  # TARGET SOURCE FSTYPE OPTIONS (built from /proc/self/mounts)
  awk '($3=="cramfs"){printf "%s %s %s %s\n",$2,$1,$3,$4}' /proc/self/mounts \
    | nl -ba | sed 's/^/Line: /'
}

print_matches_with_prefix() {
  local file="$1" needle="$2"
  [[ -f "$file" ]] && grep -nF -- "$needle" "$file" | sed 's/^/Line: /'
}

show_current_state() {
  echo -e "${BOLD}$TITLE${RESET}"
  echo
  echo "Checking files:"
  echo "  - $CONF"
  echo
  echo "Check results:"

  local found_any=0
  if [[ -f "$CONF" ]]; then
    for ln in "${REQUIRED_LINES[@]}"; do
      local out; out="$(print_matches_with_prefix "$CONF" "$ln")"
      if [[ -n "$out" ]]; then
        echo -e "$CONF:"; echo -e "$out"; found_any=1
      fi
    done
    if [[ $found_any -eq 0 ]]; then
      echo -e "$CONF:"; echo "(No matching line found)"
    fi
  else
    echo -e "$CONF:"; echo "(File not found)"
  fi

  echo
  echo "Kernel/module state:"
  if is_module_loaded; then
    echo -e "cramfs module: ${RED}loaded${RESET}"
  else
    echo -e "cramfs module: ${GREEN}not loaded${RESET}"
  fi

  if any_cramfs_mounts; then
    echo -e "cramfs mounts: ${RED}present${RESET}"
    list_cramfs_mounts
  else
    echo -e "cramfs mounts: ${GREEN}none${RESET}"
  fi
}

is_compliant() {
  [[ -f "$CONF" ]] || return 1
  for ln in "${REQUIRED_LINES[@]}"; do has_line "$CONF" "$ln" || return 1; done
  is_module_loaded && return 1
  any_cramfs_mounts && return 1
  return 0
}

ensure_conf() {
  install -d -m 0755 /etc/modprobe.d
  if [[ -f "$CONF" ]]; then
    local tmp; tmp="$(mktemp)"
    cp -a -- "$CONF" "$tmp"
    for ln in "${REQUIRED_LINES[@]}"; do
      grep -Fxq -- "$ln" "$tmp" || printf "%s\n" "$ln" >>"$tmp"
    done
    if ! cmp -s "$CONF" "$tmp"; then
      cp -a -- "$CONF" "${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
      install -m 0644 "$tmp" "$CONF"
    fi
    rm -f "$tmp"
  else
    {
      echo "# Managed by $TITLE"
      for ln in "${REQUIRED_LINES[@]}"; do printf "%s\n" "$ln"; done
    } >"$CONF"
    chmod 0644 "$CONF"
  fi
}

scrub_fstab_cramfs() {
  # Comment out any non-comment lines with fstype 'cramfs' (3rd column)
  if [[ -f "$FSTAB" ]]; then
    if awk '($0!~/^\s*#/ && NF>=3 && $3=="cramfs"){found=1} END{exit !found}' "$FSTAB"; then
      cp -a -- "$FSTAB" "${FSTAB}.bak.$(date +%Y%m%d-%H%M%S)"
      awk '{
        if ($0 ~ /^\s*#/) { print; next }
        n=split($0,a,/[\t ]+/)
        if (n>=3 && a[3]=="cramfs") { print "#" $0 }
        else { print }
      }' "$FSTAB" > "${FSTAB}.tmp.$$" && install -m 0644 "${FSTAB}.tmp.$$" "$FSTAB"
      rm -f "${FSTAB}.tmp.$$"
      echo -e "${YELLOW}Commented cramfs entries in /etc/fstab (backup saved).${RESET}"
    fi
  fi
}

unmount_cramfs_mounts() {
  local failed=0
  # Build from /proc/self/mounts, deepest first
  mapfile -t mps < <(awk '($3=="cramfs"){print $2}' /proc/self/mounts | awk '{print length, $0}' | sort -nr | cut -d" " -f2-)
  for mp in "${mps[@]}"; do
    echo "Attempting to unmount: $mp"
    if umount "$mp" 2>/dev/null; then
      echo -e "  ${GREEN}OK${RESET}"
    else
      echo -e "  ${YELLOW}Busy, retrying with lazy unmount (-l)...${RESET}"
      if umount -l "$mp" 2>/dev/null; then
        echo -e "  ${GREEN}OK (lazy)${RESET}"
      else
        echo -e "  ${RED}Failed to unmount $mp${RESET}"
        failed=1
      fi
    fi
  done
  return $failed
}

rebuild_initramfs_if_present() {
  if command -v dracut >/dev/null 2>&1; then
    local kver; kver="$(uname -r)"
    dracut -f "/boot/initramfs-${kver}.img" "${kver}" >/dev/null 2>&1 || \
      echo -e "${YELLOW}Warning: dracut rebuild may have failed or been unnecessary.${RESET}"
  fi
}

apply_fix() {
  echo
  echo -e "${CYAN}Applying fix...${RESET}"
  ensure_conf

  # If mounts exist, offer to clean fstab then unmount
  if any_cramfs_mounts; then
    echo
    echo "Current cramfs mounts:"
    list_cramfs_mounts
    echo
    echo -n "Comment any cramfs lines in /etc/fstab and unmount now? [Y]es / [N]o / [C]ancel: "
    local ans
    while true; do
      IFS= read -rsn1 ans
      echo
      case "$ans" in
        [Yy])
          scrub_fstab_cramfs
          if ! unmount_cramfs_mounts; then
            echo -e "${RED}Some cramfs mounts could not be unmounted.${RESET}"
            return 1
          fi
          break
          ;;
        [Nn]) echo "Skipped unmounting."; break ;;
        [Cc]) echo "Canceled."; return 3 ;;
        *) echo -n "Please press Y/N/C: " ;;
      esac
    done
  fi

  # Try to remove module if still loaded
  if is_module_loaded; then
    if ! rmmod cramfs 2>/dev/null; then
      echo -e "${YELLOW}Could not unload cramfs module (it may be in use). Continuing.${RESET}"
    fi
  fi

  rebuild_initramfs_if_present
  return 0
}

prompt_apply() {
  echo
  echo -e "${RED}Non-compliant:${RESET} cramfs is enabled and/or not fully blacklisted (or mounts exist)."
  echo -en "Apply fix now (update ${CONF}, unmount cramfs if present, try to unload module)? [Y]es / [N]o / [C]ancel: "
  local ans
  while true; do
    IFS= read -rsn1 ans
    echo
    case "$ans" in
      [Yy]) apply_fix; return $? ;;
      [Nn]) echo "Skipped applying."; return 2 ;;
      [Cc]) echo "Canceled."; return 3 ;;
      *) echo -n "Please press Y/N/C: " ;;
    esac
  done
}

main() {
  require_root
  echo -e "${BOLD}$TITLE${RESET}"
  echo
  echo "Checking current configuration..."
  show_current_state
  echo

  if is_compliant; then
    echo -e "${GREEN}Compliant:${RESET} cramfs is disabled and blacklisted."
    exit 0
  fi

  prompt_apply
  rc=$?
  if [[ $rc -eq 2 ]]; then exit 2; fi
  if [[ $rc -eq 3 ]]; then exit 3; fi

  echo
  echo "Re-checking..."
  show_current_state
  echo

  if is_compliant; then
    echo -e "${GREEN}Successfully applied.${RESET} A reboot is recommended to ensure the setting persists."
    exit 0
  else
    echo -e "${RED}Failed to apply.${RESET}"
    echo -e "${YELLOW}Hints:${RESET}"
    echo "  - Ensure no services auto-mount cramfs (check ${FSTAB} and any *.mount units under /etc/systemd/system)."
    echo "  - Manually stop processes using cramfs mount points, then re-run."
    exit 1
  fi
}

main "$@"
