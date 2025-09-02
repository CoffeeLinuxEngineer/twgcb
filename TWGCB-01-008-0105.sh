#!/bin/bash
# TWGCB-01-008-0105: Remove rsh-server package (RHEL 8.5)

GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; RESET="\e[0m"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${RESET}"
    exit 1
  fi
}

has_pkg() {
  rpm -q rsh-server &>/dev/null
}

print_status() {
  echo "TWGCB-01-008-0105: Ensure rsh-server is removed"
  echo
  echo "Checking current state..."
  idx=0

  if has_pkg; then
    ((idx++)); echo "Line: $idx: Package installed: rsh-server"
  else
    ((idx++)); echo "Line: $idx: Package not installed: rsh-server"
  fi
  echo
}

is_compliant() {
  if has_pkg; then return 1; fi
  return 0
}

apply_fix() {
  if has_pkg; then
    echo -e "${YELLOW}Removing package: rsh-server...${RESET}"
    if ! dnf -y remove rsh-server; then
      echo -e "${RED}Failed to remove rsh-server.${RESET}"
      return 1
    fi
  fi
  return 0
}

main() {
  require_root
  print_status

  if is_compliant; then
    echo -e "${GREEN}Compliant: rsh-server not installed.${RESET}"
    exit 0
  fi

  echo -e "${RED}Non-compliant: rsh-server is installed.${RESET}"
  echo -n "Apply fix now (remove rsh-server)? [Y]es / [N]o / [C]ancel: "
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
