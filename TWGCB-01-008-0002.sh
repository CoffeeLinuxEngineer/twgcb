#
//  TWGCB-01-008-0002.sh
//  
//
//  Created by zhuo on 2025/9/3.
//


#!/bin/bash
# TWGCB-01-008-0002 v2: Disable squashfs filesystem (RHEL 8.5)
# Ensures:
#   - /etc/modprobe.d/squashfs.conf contains:
#       install squashfs /bin/true
#       blacklist squashfs
#   - No squashfs mounts exist (robust detector via /proc/self/mounts)
#   - Warns if snapd is installed/running or Snap mounts are present
#   - Tries to unload squashfs module if loaded
#   - Rebuilds initramfs if dracut exists
#   - Recommends reboot
set -uo pipefail

TITLE="TWGCB-01-008-0002: Disable squashfs filesystem"
CONF="/etc/modprobe.d/squashfs.conf"
FSTAB="/etc/fstab"
REQUIRED_LINES=("install squashfs /bin/true" "blacklist squashfs")

# Colors (bright)
GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; BOLD="\e[1m"; RESET="\e[0m"

require_root() { [[ $EUID -ne 0 ]] && { echo -e "${RED}Must run as root.${RESET}"; exit 1; }; }
has_line() { [[ -f "$1" ]] && grep -Fxq -- "$2" "$1"; }
is_module_loaded() { lsmod | awk '{print $1}' | grep -Fxq "squashfs"; }

# Robust mount detector from /proc/self/mounts (not relying on external tools)
any_squashfs_mounts() { awk '($3=="squashfs"){found=1; exit} END{exit !found}' /proc/self/mounts; }
list_squashfs_mounts() {
  awk '($3=="squashfs"){printf "%s %s %s %s\n",$2,$1,$3,$4}' /proc/self/mounts \
    | nl -ba | sed 's/^/Line: /'
}

print_matches_with_prefix() { [[ -f "$1" ]] && grep -nF -- "$2" "$1" | sed 's/^/Line: /'; }

snapd_installed() {
  # Detect via rpm or executable presence
  rpm -q snapd >/dev/null 2>&1 && return 0
  command -v snap >/dev/null 2>&1 && return 0
  return 1
}
snapd_services_active() {
  local any=1
  for unit in snapd.service snapd.socket snapd.seeded.service; do
    if systemctl is-enabled "$unit" >/dev/null 2>&1 || systemctl is-active "$unit" >/dev/null 2>&1; then
      any=0
    fi
  done
  return $any
}
list_snapd_details() {
  echo "snapd presence:"
  if rpm -q snapd >/dev/null 2>&1; then
    rpm -qi snapd | awk '{print NR ":" $0}' | sed 's/^/Line: /'
  else
    echo "Line: 1:snapd rpm not installed (rpm -q snapd failed)"
  fi
  if command -v snap >/dev/null 2>&1; then
    echo "Line: 2:snap command found at $(command -v snap)"
  else
    echo "Line: 2:snap command not found"
  fi
  echo
  echo "snapd units (enabled/active):"
  for unit in snapd.service snapd.socket snapd.seeded.service; do
    local en="disabled" ac="inactive"
    systemctl is-enabled "$unit" >/dev/null 2>&1 && en="enabled"
    systemctl is-active "$unit" >/dev/null 2>&1 && ac="active"
    echo "Line: $((RANDOM%899+100)):${unit}  enabled=${en}  active=${ac}"
  done
  echo
  echo "Potential Snap (squashfs) mounts:"
  # Many snaps appear as loop-mounted squashfs images under /var/lib/snapd/snaps
  awk '($3=="squashfs"){printf "%s %s %s %s\n",$2,$1,$3,$4}' /proc/self/mounts \
    | grep -E "/var/lib/snapd/snaps/|\.snap" | nl -ba | sed 's/^/Line: /' || true
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
      if [[ -n "$out" ]]; then echo -e "$CONF:"; echo -e "$out"; found_any=1; fi
    done
    [[ $found_any -eq 0 ]] && { echo -e "$CONF:"; echo "(No matching line found)"; }
  else
    echo -e "$CONF:"; echo "(File not found)"
  fi

  echo
  echo "Kernel/module state:"
  if is_module_loaded; then
    echo -e "squashfs module: ${RED}loaded${RESET}"
  else
    echo -e "squashfs module: ${GREEN}not loaded${RESET}"
  fi

  if any_squashfs_mounts; then
    echo -e "squashfs mounts: ${RED}present${RESET}"
    list_squashfs_mounts
  else
    echo -e "squashfs mounts: ${GREEN}none${RESET}"
  fi
}

is_compliant() {
  [[ -f "$CONF" ]] || return 1
  for ln in "${REQUIRED_LINES[@]}"; do has_line "$CONF" "$ln" || return 1; done
  is_module_loaded && return 1
  any_squashfs_mounts && return 1
  return 0
}

ensure_conf() {
  install -d -m 0755 /etc/modprobe.d
  if [[ -f "$CONF" ]]; then
    local tmp; tmp="$(mktemp)"
    cp -a -- "$CONF" "$tmp"
    for ln in "${REQUIRED_LINES[@]}"; do grep -Fxq -- "$ln" "$tmp" || echo "$ln" >>"$tmp"; done
    if ! cmp -s "$CONF" "$tmp"; then
      cp -a -- "$CONF" "${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
      install -m 0644 "$tmp" "$CONF"
    fi
    rm -f "$tmp"
  else
    { echo "# Managed by $TITLE"; for ln in "${REQUIRED_LINES[@]}"; do echo "$ln"; done; } >"$CONF"
    chmod 0644 "$CONF"
  fi
}

scrub_fstab_squashfs() {
  if [[ -f "$FSTAB" ]]; then
    if awk '($0!~/^\s*#/ && NF>=3 && $3=="squashfs"){found=1} END{exit !found}' "$FSTAB"; then
      cp -a -- "$FSTAB" "${FSTAB}.bak.$(date +%Y%m%d-%H%M%S)"
      awk '{
        if ($0 ~ /^\s*#/) { print; next }
        n=split($0,a,/[\t ]+/)
        if (n>=3 && a[3]=="squashfs") { print "#" $0 } else { print }
      }' "$FSTAB" > "${FSTAB}.tmp.$$" && install -m 0644 "${FSTAB}.tmp.$$" "$FSTAB"
      rm -f "${FSTAB}.tmp.$$"
      echo -e "${YELLOW}Commented squashfs entries in /etc/fstab (backup saved).${RESET}"
    fi
  fi
}

unmount_squashfs_mounts() {
  local failed=0
  mapfile -t mps < <(awk '($3=="squashfs"){print $2}' /proc/self/mounts | awk '{print length, $0}' | sort -nr | cut -d" " -f2-)
  for mp in "${mps[@]}"; do
    echo "Attempting to unmount: $mp"
    if umount "$mp" 2>/dev/null; then echo -e "  ${GREEN}OK${RESET}"
    else
      echo -e "  ${YELLOW}Busy, retrying with lazy unmount (-l)...${RESET}"
      umount -l "$mp" 2>/dev/null && echo -e "  ${GREEN}OK (lazy)${RESET}" || { echo -e "  ${RED}Failed $mp${RESET}"; failed=1; }
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

warn_snapd_if_needed() {
  local warn=1
  snapd_installed && warn=0
  snapd_services_active && warn=0
  # Snap mounts (squashfs images usually under /var/lib/snapd/snaps/*.snap)
  if awk '($3=="squashfs"){print $2,$1}' /proc/self/mounts | grep -Eq "/var/lib/snapd/snaps/|\.snap"; then
    warn=0
  fi
  if [[ $warn -eq 0 ]]; then
    echo
    echo -e "${YELLOW}Warning:${RESET} Disabling squashfs can break Snap packages (snapd)."
    echo "Collected details:"
    list_snapd_details
    echo -n "Proceed anyway? [Y]es / [N]o / [C]ancel: "
    local ans
    while true; do
      IFS= read -rsn1 ans; echo
      case "$ans" in
        [Yy]) return 0 ;;
        [Nn]) echo "Skipped due to Snap presence."; return 2 ;;
        [Cc]) echo "Canceled by user."; return 3 ;;
        *) echo -n "Please press Y/N/C: " ;;
      esac
    done
  fi
  return 0
}

apply_fix() {
  echo
  echo -e "${CYAN}Applying fix...${RESET}"
  ensure_conf

  # If mounts exist, offer to clean fstab then unmount
  if any_squashfs_mounts; then
    echo
    echo "Current squashfs mounts:"
    list_squashfs_mounts
    echo
    echo -n "Comment squashfs lines in /etc/fstab and unmount now? [Y]es / [N]o / [C]ancel: "
    local ans
    while true; do
      IFS= read -rsn1 ans; echo
      case "$ans" in
        [Yy]) scrub_fstab_squashfs; unmount_squashfs_mounts || return 1; break ;;
        [Nn]) echo "Skipped unmounting."; break ;;
        [Cc]) echo "Canceled."; return 3 ;;
        *) echo -n "Please press Y/N/C: " ;;
      esac
    done
  fi

  # Try to remove module if still loaded
  if is_module_loaded; then
    rmmod squashfs 2>/dev/null || echo -e "${YELLOW}Could not unload squashfs module (it may be in use). Continuing.${RESET}"
  fi

  rebuild_initramfs_if_present
  return 0
}

prompt_apply() {
  echo
  echo -e "${RED}Non-compliant:${RESET} squashfs is enabled and/or not fully blacklisted (or mounts exist)."
  # Pre-apply Snap warning, if applicable
  warn_snapd_if_needed
  case $? in
    2) return 2 ;;  # user chose No
    3) return 3 ;;  # user canceled
  esac

  echo -en "Apply fix now (update ${CONF}, unmount squashfs if present, try to unload module)? [Y]es / [N]o / [C]ancel: "
  local ans
  while true; do
    IFS= read -rsn1 ans; echo
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
    echo -e "${GREEN}Compliant:${RESET} squashfs is disabled and blacklisted."
    exit 0
  fi

  prompt_apply
  rc=$?
  [[ $rc -eq 2 ]] && exit 2
  [[ $rc -eq 3 ]] && exit 3

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
    echo "  - Ensure no services or tools auto-mount squashfs (check ${FSTAB}, snapd, and any *.mount units under /etc/systemd/system)."
    echo "  - Stop processes using squashfs mount points, then re-run."
    exit 1
  fi
}

main "$@"
