#!/bin/bash
# TWGCB-01-008-0130: Disable wireless network interfaces (RHEL 8.5)
# Baseline intent: If the system does not use wireless networking, disable wireless interfaces.
# Methods:
#   1) Prefer NetworkManager: nmcli radio all off
#   2) Fallback: blacklist kernel modules for detected wireless devices
# No Chinese in this file.

set -o errexit
set -o pipefail
set -o nounset

TITLE="TWGCB-01-008-0130: Disable wireless network interfaces"
GREEN="\e[1;92m"   # bright green
RED="\e[1;91m"     # bright red
YELLOW="\e[1;33m"
RESET="\e[0m"

NMCLI_BIN="$(command -v nmcli || true)"
BLACKLIST_CONF="/etc/modprobe.d/disable_wireless.conf"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${RESET}"
    exit 1
  fi
}

print_header() {
  echo "$TITLE"
  echo
}

has_wireless_dirs() {
  # Return 0 if any wireless interface dirs exist
  shopt -s nullglob
  local found=(/sys/class/net/*/wireless)
  [[ ${#found[@]} -gt 0 ]]
}

list_wireless_interfaces() {
  # Echo interface names with a wireless directory
  shopt -s nullglob
  for wdir in /sys/class/net/*/wireless; do
    basename "$(dirname "$wdir")"
  done
}

iface_driver_module() {
  # Print driver module name for a given iface (if resolvable), else empty
  local ifc="$1"
  local devpath="/sys/class/net/${ifc}/device"
  if [[ -e "${devpath}" ]]; then
    # Resolve driver module symlink if present
    if [[ -L "${devpath}/driver/module" ]]; then
      basename "$(readlink -f "${devpath}/driver/module")"
      return 0
    fi
    # Try modalias -> modinfo
    if [[ -r "${devpath}/modalias" ]] && command -v modinfo >/dev/null 2>&1; then
      local alias
      alias="$(<"${devpath}/modalias")"
      modinfo -F name "${alias}" 2>/dev/null | head -n1 || true
      return 0
    fi
  fi
  echo ""
}

show_check_lines() {
  # Produce numbered, user-friendly lines about current wireless status
  local lines=()
  if has_wireless_dirs; then
    while IFS= read -r ifc; do
      local state driver
      state="$(<"/sys/class/net/${ifc}/operstate" 2>/dev/null || echo "unknown")"
      driver="$(iface_driver_module "${ifc}")"
      lines+=("iface=${ifc} state=${state} driver=${driver:-unknown}")
    done < <(list_wireless_interfaces | sort -u)
  else
    lines+=("(No wireless interfaces detected under /sys/class/net/*/wireless)")
  fi

  if [[ -n "${NMCLI_BIN}" ]]; then
    local wifi_state wwan_state all_state
    wifi_state="$("${NMCLI_BIN}" radio wifi 2>/dev/null | tr -d '\r')"
    wwan_state="$("${NMCLI_BIN}" radio wwan 2>/dev/null | tr -d '\r' || echo "unknown")"
    all_state="$("${NMCLI_BIN}" radio all 2>/dev/null | tr -d '\r' || echo "unknown")"
    lines+=("nmcli radio: wifi=${wifi_state} wwan=${wwan_state} all=${all_state}")
    # List device types/states for extra visibility
    while IFS= read -r l; do
      lines+=("nmcli device: ${l}")
    done < <("${NMCLI_BIN}" -t -f DEVICE,TYPE,STATE dev status 2>/dev/null || true)
  else
    lines+=("(nmcli not found; will use module blacklist method if applying)")
  fi

  # Print with "Line: N:" prefix
  printf '%s\n' "${lines[@]}" | nl -ba -w1 -s':' | sed -E 's/^([[:space:]]*([0-9]+)):/Line: \2: /'
}

conf_has_module_rule() {
  # Args: module_name
  # Return 0 if BLACKLIST_CONF contains a rule for this module
  local m="$1"
  [[ -r "${BLACKLIST_CONF}" ]] && grep -Eq "^(blacklist[[:space:]]+${m}\b|install[[:space:]]+${m}\b)" "${BLACKLIST_CONF}"
}

collect_needed_modules() {
  # Echo unique driver module names for detected wireless interfaces
  local mods=()
  if has_wireless_dirs; then
    while IFS= read -r ifc; do
      local m
      m="$(iface_driver_module "${ifc}")"
      [[ -n "${m}" ]] && mods+=("${m}")
    done < <(list_wireless_interfaces | sort -u)
  fi
  printf '%s\n' "${mods[@]}" | sort -u
}

compliance_status() {
  # Returns:
  #  0 = compliant
  #  1 = non-compliant
  # Rule: compliant if
  #  - No wireless interfaces detected, OR
  #  - nmcli present and "nmcli radio all" is "disabled", OR
  #  - All detected wireless driver modules are blacklisted/installed-to-/bin/true in BLACKLIST_CONF
  if ! has_wireless_dirs; then
    return 0
  fi

  if [[ -n "${NMCLI_BIN}" ]]; then
    local all_state
    all_state="$("${NMCLI_BIN}" radio all 2>/dev/null | tr -d '\r' || echo "unknown")"
    if [[ "${all_state}" == "disabled" ]]; then
      return 0
    fi
  fi

  local all_blacklisted=1
  while IFS= read -r m; do
    if [[ -z "${m}" ]]; then
      continue
    fi
    if ! conf_has_module_rule "${m}"; then
      all_blacklisted=0
      break
    fi
  done < <(collect_needed_modules)

  if [[ ${all_blacklisted} -eq 1 ]]; then
    return 0
  fi

  return 1
}

check_compliance() {
  echo "Checking wireless status..."
  echo "Check results:"
  show_check_lines
  if compliance_status; then
    echo -e "${GREEN}Compliant: Wireless networking is disabled (no interfaces, radios off, or modules blacklisted).${RESET}"
    return 0
  else
    echo -e "${RED}Non-compliant: Wireless interfaces exist and are not disabled.${RESET}"
    return 1
  fi
}

apply_fix() {
  echo
  echo -n "Apply fix now (prefer nmcli radio all off; else write module blacklist)? [Y]es / [N]o / [C]ancel: "
  local ans
  IFS= read -rsn1 ans
  echo
  case "${ans}" in
    Y|y)
      if [[ -n "${NMCLI_BIN}" ]]; then
        echo "Running: nmcli radio all off"
        if ! "${NMCLI_BIN}" radio all off; then
          echo -e "${YELLOW}Warning: nmcli failed. Falling back to module blacklist...${RESET}"
        fi
      fi

      if ! compliance_status; then
        # Ensure blacklist contains lines for each detected module
        local wrote=0
        while IFS= read -r m; do
          [[ -z "${m}" ]] && continue
          if conf_has_module_rule "${m}"; then
            continue
          fi
          if [[ $wrote -eq 0 ]]; then
            echo "Updating ${BLACKLIST_CONF} ..."
            wrote=1
          fi
          {
            echo "install ${m} /bin/true"
            echo "blacklist ${m}"
          } >> "${BLACKLIST_CONF}"
        done < <(collect_needed_modules)

        if [[ $wrote -eq 1 ]]; then
          echo "Blacklist updated. You may need to rebuild initramfs and reboot for full effect if drivers are already loaded."
        fi
      fi

      echo
      echo "Re-checking..."
      if check_compliance; then
        echo -e "${GREEN}Successfully applied${RESET}"
        return 0
      else
        echo -e "${RED}Failed to apply${RESET}"
        return 1
      fi
      ;;
    N|n)
      echo "Skipped by user."
      return 0
      ;;
    C|c)
      echo "Canceled by user."
      exit 130
      ;;
    *)
      echo "Invalid choice."
      return 1
      ;;
  esac
}

main() {
  require_root
  print_header
  if check_compliance; then
    exit 0
  else
    apply_fix
  fi
}

main "$@"
