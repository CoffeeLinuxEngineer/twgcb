#!/bin/bash
# TWGCB-01-008-0003: Disable udf filesystem (RHEL 8.5)
# Baseline actions:
#   - /etc/modprobe.d/udf.conf: add "install udf /bin/true" and "blacklist udf"
#   - rmmod udf
#   - reboot recommended
# Warning: may impact Azure systems
set -uo pipefail

TITLE="TWGCB-01-008-0003: Disable udf filesystem"
CONF="/etc/modprobe.d/udf.conf"
FSTAB="/etc/fstab"
REQUIRED_LINES=("install udf /bin/true" "blacklist udf")

GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; BOLD="\e[1m"; RESET="\e[0m"

require_root() { [[ $EUID -ne 0 ]] && { echo -e "${RED}Must run as root.${RESET}"; exit 1; }; }
has_line() { [[ -f "$1" ]] && grep -Fxq -- "$2" "$1"; }
is_module_loaded() { lsmod | awk '{print $1}' | grep -Fxq "udf"; }

any_udf_mounts() { awk '($3=="udf"){found=1; exit} END{exit !found}' /proc/self/mounts; }
list_udf_mounts() {
  awk '($3=="udf"){printf "%s %s %s %s\n",$2,$1,$3,$4}' /proc/self/mounts \
    | nl -ba | sed 's/^/Line: /'
}

print_matches_with_prefix() { [[ -f "$1" ]] && grep -nF -- "$2" "$1" | sed 's/^/Line: /'; }

running_on_azure() {
  [[ -d /var/lib/waagent ]] && return 0
  [[ -f /sys/class/dmi/id/sys_vendor && "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" =~ Microsoft ]] && return 0
  return 1
}

show_current_state() {
  echo -e "${BOLD}$TITLE${RESET}"
  echo; echo "Checking files:"; echo "  - $CONF"; echo; echo "Check results:"

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

  echo; echo "Kernel/module state:"
  if is_module_loaded; then
    echo -e "udf module: ${RED}loaded${RESET}"
  else
    echo -e "udf module: ${GREEN}not loaded${RESET}"
  fi

  if any_udf_mounts; then
    echo -e "udf mounts: ${RED}present${RESET}"
    list_udf_mounts
  else
    echo -e "udf mounts: ${GREEN}none${RESET}"
  fi
}

is_compliant() {
  [[ -f "$CONF" ]] || return 1
  for ln in "${REQUIRED_LINES[@]}"; do has_line "$CONF" "$ln" || return 1; done
  is_module_loaded && return 1
  any_udf_mounts && return 1
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

unmount_udf_mounts() {
  local failed=0
  mapfile -t mps < <(awk '($3=="udf"){print $2}' /proc/self/mounts | awk '{print length, $0}' | sort -nr | cut -d" " -f2-)
  for mp in "${mps[@]}"; do
    echo "Attempting to unmount: $mp"
    if umount "$mp" 2>/dev/null; then echo -e "  ${GREEN}OK${RESET}"
    else
      echo -e "  ${YELLOW}Busy, retrying lazy...${RESET}"
      umount -l "$mp" 2>/dev/null && echo -e "  ${GREEN}OK (lazy)${RESET}" || { echo -e "  ${RED}Failed $mp${RESET}"; failed=1; }
    fi
  done
  return $failed
}

rebuild_initramfs_if_present() {
  if command -v dracut >/dev/null 2>&1; then
    local kver; kver="$(uname -r)"
    dracut -f "/boot/initramfs-${kver}.img" "${kver}" >/dev/null 2>&1 || \
      echo -e "${YELLOW}Warning: dracut rebuild may have failed.${RESET}"
  fi
}

apply_fix() {
  echo; echo -e "${CYAN}Applying fix...${RESET}"
  ensure_conf
  if any_udf_mounts; then
    echo; echo "Current udf mounts:"; list_udf_mounts
    echo; echo -n "Unmount udf mounts now? [Y]es / [N]o / [C]ancel: "
    local ans
    while true; do
      IFS= read -rsn1 ans; echo
      case "$ans" in
        [Yy]) unmount_udf_mounts || return 1; break ;;
        [Nn]) echo "Skipped unmounting."; break ;;
        [Cc]) echo "Canceled."; return 3 ;;
        *) echo -n "Press Y/N/C: " ;;
      esac
    done
  fi
  if is_module_loaded; then rmmod udf 2>/dev/null || echo -e "${YELLOW}Could not unload udf module.${RESET}"; fi
  rebuild_initramfs_if_present
  return 0
}

prompt_apply() {
  echo
  if running_on_azure; then
    echo -e "${YELLOW}Warning:${RESET} This system looks like it's running on Microsoft Azure."
    echo "Disabling udf may impact system functionality."
    echo -n "Proceed anyway? [Y]es / [N]o / [C]ancel: "
    local ans
    while true; do
      IFS= read -rsn1 ans; echo
      case "$ans" in
        [Yy]) break ;;
        [Nn]) echo "Skipped due to Azure warning."; return 2 ;;
        [Cc]) echo "Canceled."; return 3 ;;
        *) echo -n "Press Y/N/C: " ;;
      esac
    done
  fi

  echo -e "${RED}Non-compliant:${RESET} udf is enabled and/or not fully blacklisted."
  echo -en "Apply fix now (update ${CONF}, unmount udf if present, try to unload module)? [Y]es / [N]o / [C]ancel: "
  local ans
  while true; do
    IFS= read -rsn1 ans; echo
    case "$ans" in
      [Yy]) apply_fix; return $? ;;
      [Nn]) echo "Skipped applying."; return 2 ;;
      [Cc]) echo "Canceled."; return 3 ;;
      *) echo -n "Press Y/N/C: " ;;
    esac
  done
}

main() {
  require_root
  echo -e "${BOLD}$TITLE${RESET}"
  echo; echo "Checking current configuration..."; show_current_state; echo
  if is_compliant; then echo -e "${GREEN}Compliant:${RESET} udf is disabled and blacklisted."; exit 0; fi
  prompt_apply; rc=$?
  [[ $rc -eq 2 ]] && exit 2
  [[ $rc -eq 3 ]] && exit 3
  echo; echo "Re-checking..."; show_current_state; echo
  if is_compliant; then echo -e "${GREEN}Successfully applied.${RESET} Reboot recommended."; exit 0
  else echo -e "${RED}Failed to apply.${RESET}"; exit 1; fi
}

main "$@"
