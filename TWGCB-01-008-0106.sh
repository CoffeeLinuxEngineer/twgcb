#!/bin/bash
# TWGCB-01-008-0106: Remove tftp-server package and disable TFTP units (RHEL 8.5)

GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; RESET="\e[0m"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${RESET}"
    exit 1
  fi
}

has_pkg() {
  rpm -q tftp-server &>/dev/null
}

unit_exists() {
  systemctl list-unit-files --type=service --type=socket --no-legend | awk '{print $1}' | grep -qx "$1"
}

print_status() {
  echo "TWGCB-01-008-0106: Ensure tftp-server is removed"
  echo
  echo "Checking current state..."
  idx=0

  if has_pkg; then
    ((idx++)); echo "Line: $idx: Package installed: tftp-server"
  else
    ((idx++)); echo "Line: $idx: Package not installed: tftp-server"
  fi

  for u in tftp.service tftp.socket; do
    if unit_exists "$u"; then
      en="unknown"; ac="unknown"
      systemctl is-enabled "$u" &>/dev/null && en="enabled" || en="disabled"
      systemctl is-active "$u" &>/dev/null && ac="active"  || ac="inactive"
      ((idx++)); echo "Line: $idx: Unit present: $u (is-enabled: $en, is-active: $ac)"
    else
      ((idx++)); echo "Line: $idx: Unit not present: $u"
    fi
  done
  echo
}

is_compliant() {
  if has_pkg; then return 1; fi
  for u in tftp.service tftp.socket; do
    if unit_exists "$u"; then
      systemctl is-enabled "$u" &>/dev/null && return 1
      systemctl is-active "$u" &>/dev/null && return 1
    fi
  done
  return 0
}

apply_fix() {
  ok=true

  if has_pkg; then
    echo -e "${YELLOW}Removing package: tftp-server...${RESET}"
    if ! dnf -y remove tftp-server; then
      echo -e "${RED}Failed to remove tftp-server.${RESET}"
      ok=false
    fi
  fi

  for u in tftp.socket tftp.service; do
    if unit_exists "$u"; then
      echo -e "${YELLOW}Disabling and stopping $u ...${RESET}"
      systemctl disable --now "$u" || ok=false
    fi
  done

  $ok
}

main() {
  require_root
  print_status

  if is_compliant; then
    echo -e "${GREEN}Compliant: tftp-server not installed and no TFTP units enabled/active.${RESET}"
    exit 0
  fi

  echo -e "${RED}Non-compliant: tftp-server is installed and/or TFTP units enabled/active.${RESET}"
  echo -n "Apply fix now (remove package and disable/stop TFTP units)? [Y]es / [N]o / [C]ancel: "
  read -rsn1 ans; echo
  case "$ans" in
    Y|y)
      if apply_fix; then
        print_status
        if is_compliant; then
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
    N|n) echo -e "${YELLOW}Skipped by user.${RESET}"; exit 0 ;;
    C|c) echo -e "${YELLOW}Canceled by user.${RESET}"; exit 0 ;;
    *)   echo -e "${YELLOW}Invalid choice. Aborted.${RESET}"; exit 1 ;;
  esac
}

main "$@"
