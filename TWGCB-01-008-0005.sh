#!/bin/bash
# TWGCB-01-008-0005 v6: Ensure /tmp has nodev (RHEL 8.5)
# - Uses single-key prompts: read -rsn1
# - Fixed compliance logic (no parentheses in [[ ]] boolean)
# - Falls back to fstab if no key (Enter) is detected
set -uo pipefail

TITLE="TWGCB-01-008-0005: Ensure /tmp has nodev"
FSTAB="/etc/fstab"
SYSTEMD_UNIT_DIR="/etc/systemd/system"
UNIT_PATH="${SYSTEMD_UNIT_DIR}/tmp.mount"

GREEN="\e[92m"; RED="\e[91m"; YELLOW="\e[93m"; CYAN="\e[96m"; BOLD="\e[1m"; RESET="\e[0m"

require_root() { [[ $EUID -ne 0 ]] && { echo -e "${RED}Must run as root.${RESET}"; exit 1; }; }

# -------- I/O helpers (single-key) --------
read_one_key() {
  # usage: read_one_key "Prompt text: " -> echoes key pressed (defaults to 'F' if blank)
  local prompt="$1" key=""
  if [[ -t 0 ]]; then
    echo -en "$prompt"
    IFS= read -rsn1 key || key=""
    echo
  elif [[ -r /dev/tty ]]; then
    echo -en "$prompt" > /dev/tty
    IFS= read -rsn1 key < /dev/tty 2>/dev/null || key=""
    echo > /dev/tty 2>/dev/null || true
  else
    key="F"
  fi
  [[ -z "$key" ]] && key="F"
  printf "%s" "$key"
}

# -------- Runtime state --------
current_tmp_mount_line() { awk '$2=="/tmp"{print NR ":" $0}' /proc/self/mounts; }
current_tmp_opts() { awk '$2=="/tmp"{print $4; exit}' /proc/self/mounts; }
tmp_is_mountpoint() { awk '$2=="/tmp"{found=1; exit} END{exit !found}' /proc/self/mounts; }
runtime_has_nodev() {
  local opts; opts="$(current_tmp_opts || true)"
  [[ -n "$opts" ]] && grep -qE "(^|,)nodev(,|$)" <<<"$opts"
}

# -------- fstab helpers --------
fstab_lines_for_tmp() { [[ -f "$FSTAB" ]] && awk '($0!~/^\s*#/ && NF>=2 && $2=="/tmp"){print NR ":" $0}' "$FSTAB"; }
fstab_has_nodev() {
  [[ -f "$FSTAB" ]] || return 1
  awk '($0!~/^\s*#/ && NF>=4 && $2=="/tmp"){ if ($4 ~ /(^|,)nodev(,|$)/) {exit 0}} END{exit 1}' "$FSTAB"
}
fstab_add_nodev() {
  install -d -m 0755 /etc
  touch "$FSTAB"
  cp -a -- "$FSTAB" "${FSTAB}.bak.$(date +%Y%m%d-%H%M%S)"
  awk '{
    if ($0 ~ /^\s*#/){print; next}
    n=split($0,a,/[\t ]+/)
    if (n>=4 && a[2]=="/tmp") {
      opts=a[4]
      if (opts !~ /(^|,)nodev(,|$)/) {
        if (opts ~ /,$/ || opts=="") { opts=opts "nodev" } else { opts=opts ",nodev" }
      }
      a[4]=opts
      printf "%s %s %s %s", a[1], a[2], a[3], a[4]
      for (i=5;i<=n;i++) printf " %s", a[i]
      printf "\n"
    } else { print }
  }' "$FSTAB" > "${FSTAB}.tmp.$$" && install -m 0644 "${FSTAB}.tmp.$$" "$FSTAB"
  rm -f "${FSTAB}.tmp.$$"
}

# -------- systemd tmp.mount helpers --------
unit_options_line() { [[ -f "$UNIT_PATH" ]] && awk '/^\[Mount\]/{inm=1; next} /^\[/{inm=0} inm && /^Options=/{print NR ":" $0}' "$UNIT_PATH"; }
unit_has_nodev() {
  [[ -f "$UNIT_PATH" ]] || return 1
  awk '/^\[Mount\]/{inm=1; next} /^\[/{inm=0} inm && /^Options=/ { if ($0 ~ /(^|,)nodev(,|$)/) exit 0 } END{exit 1}' "$UNIT_PATH"
}
unit_add_nodev() {
  install -d -m 0755 "$SYSTEMD_UNIT_DIR"
  if [[ -f "$UNIT_PATH" ]]; then
    cp -a -- "$UNIT_PATH" "${UNIT_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
    awk 'BEGIN{inm=0}
      /^\[Mount\]/{inm=1; print; next}
      /^\[/{inm=0; print; next}
      inm && /^Options=/{
        line=$0
        if (line !~ /(^|,)nodev(,|$)/) {
          sub(/^Options=/,"",line)
          if (line ~ /,$/ || line=="") { line=line "nodev" } else { line=line ",nodev" }
          print "Options=" line
        } else { print }
        next
      }
      {print}
    ' "$UNIT_PATH" > "${UNIT_PATH}.tmp.$$" && install -m 0644 "${UNIT_PATH}.tmp.$$" "$UNIT_PATH"
    rm -f "${UNIT_PATH}.tmp.$$"
  else
    cat >"$UNIT_PATH" <<'EOF'
[Unit]
Description=Temporary Directory (/tmp) as tmpfs
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target umount.target

[Mount]
What=tmpfs
Where=/tmp
Type=tmpfs
Options=mode=1777,strictatime,nodev

[Install]
WantedBy=local-fs.target
EOF
    chmod 0644 "$UNIT_PATH"
  fi
  systemctl daemon-reload
  systemctl unmask tmp.mount >/dev/null 2>&1 || true
  systemctl enable --now tmp.mount || true
}

# -------- show state --------
show_state() {
  echo -e "${BOLD}$TITLE${RESET}"
  echo
  echo "Runtime mount (/proc/self/mounts):"
  local cur; cur="$(current_tmp_mount_line)"
  if [[ -n "$cur" ]]; then
    echo "$cur" | sed 's/^/Line: /'
  else
    echo "Line: 1:(/tmp not found in /proc/self/mounts)"
  fi
  local opts; opts="$(current_tmp_opts || true)"
  echo
  echo "Runtime evaluation:"
  if [[ -n "$opts" ]]; then
    if runtime_has_nodev; then
      echo -e "  nodev: ${GREEN}present${RESET}  (opts: $opts)"
    else
      echo -e "  nodev: ${RED}missing${RESET}  (opts: $opts)"
    fi
  else
    echo "  nodev: (unknown at runtime — /tmp not a separate mountpoint)"
  fi

  echo
  echo "Configuration files:"
  echo "  - $FSTAB"
  fstab_lines_for_tmp | sed 's/^/Line: /'
  echo "  - $UNIT_PATH"
  unit_options_line | sed 's/^/Line: /'
}

# -------- compliance --------
is_compliant() {
  runtime_has_nodev; local r=$?
  fstab_has_nodev; local f=$?
  unit_has_nodev;  local u=$?
  if [[ $r -eq 0 ]]; then
    if [[ $f -eq 0 || $u -eq 0 ]]; then
      return 0
    fi
  fi
  return 1
}

# -------- apply --------
apply_runtime_remount() {
  if tmp_is_mountpoint; then
    echo "Remounting /tmp with nodev..."
    if mount -o remount,nodev /tmp 2>/dev/null; then
      echo -e "  ${GREEN}OK${RESET}"
      return 0
    else
      echo -e "  ${RED}Failed to remount /tmp with nodev.${RESET}"
      return 1
    fi
  else
    echo -e "${YELLOW}Note:${RESET} /tmp is not a separate mountpoint. Consider creating tmp.mount or an fstab entry."
    return 1
  fi
}

apply_via_fstab() {
  echo -e "${CYAN}Applying via /etc/fstab...${RESET}"
  fstab_add_nodev
  apply_runtime_remount || true
  return 0
}

apply_via_systemd() {
  echo -e "${CYAN}Applying via systemd tmp.mount...${RESET}"
  unit_add_nodev
  apply_runtime_remount || true
  return 0
}

prompt_apply() {
  echo
  if is_compliant; then
    echo -e "${GREEN}Already compliant.${RESET}"
    return 0
  fi
  echo -e "${RED}Non-compliant:${RESET} /tmp is missing nodev at runtime and/or persistently."
  echo "Press a key: [F]stab / [S]ystemd tmp.mount / [C]ancel"
  local key; key="$(read_one_key "> " )"
  case "${key^^}" in
    F) apply_via_fstab ;;
    S) apply_via_systemd ;;
    C) echo "Canceled by user."; return 3 ;;
    *) echo "Unknown choice; defaulting to fstab."; apply_via_fstab ;;
  esac
  return 0
}

main() {
  require_root
  echo -e "${BOLD}$TITLE${RESET}"
  echo
  echo "Checking current configuration..."
  show_state
  echo

  if is_compliant; then
    echo -e "${GREEN}Compliant:${RESET} nodev is active at runtime and persisted."
    exit 0
  fi

  prompt_apply || { rc=$?; [[ $rc -eq 3 ]] && exit 3 || exit 1; }

  echo
  echo "Re-checking..."
  show_state
  echo

  if is_compliant; then
    echo -e "${GREEN}Successfully applied.${RESET}"
    exit 0
  else
    echo -e "${RED}Failed to apply.${RESET}"
    echo -e "${YELLOW}Hints:${RESET}"
    echo "  - If /tmp is not a separate mountpoint, create systemd tmp.mount (option S) to manage it with nodev."
    echo "  - Ensure no conflicting entries in $FSTAB."
    exit 1
  fi
}

main "$@"
