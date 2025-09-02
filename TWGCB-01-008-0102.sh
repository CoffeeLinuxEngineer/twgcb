#!/bin/bash
# TWGCB-01-008-0102: Remove NIS client package (ypbind) (RHEL 8.5)

GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; RESET="\e[0m"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${RESET}"
    exit 1
  fi
}

has_pkg() {
  rpm -q ypbind &>/dev/null
}

print_status() {
  echo "TWGCB-01-008-0102: Ensure NIS client (ypbind) is removed"
  echo
  echo "Checking current state..."
  idx=0

  if has_pkg; then
    ((idx++)); echo "Line: $idx: Package installed: ypbind"
  else
    ((idx++)); echo "Line: $idx: Package not installed: ypbind"
  fi
  echo
}

is_compliant() {
  if has_pkg; then return 1; fi
  return 0
}

apply_fix() {
  if has_pkg; then
    echo -e "${YELLOW}Removing package: ypbind...${RESET}"
    if ! dnf -y remove ypbind; then
      echo -e "${RED}Failed to remove ypbind.${RESET}"
      return 1
    fi
  fi
  return 0
}

main() {
  require_root
  print_status

  if is_compliant; then
    echo -e "${GREEN}Compliant: ypbind not installed.${RESET}"
    exit 0
  fi

  echo -e "${RED}Non-compliant: ypbind is installed.${RESET}"
  echo -n "Apply fix now (remove ypbind)? [Y]es / [N]o / [C]ancel: "
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
