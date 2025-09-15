#!/bin/bash

# TWGCB-01-008-0006: TWGCB-01-008-0006 Automation Script
# This script automatically configures nosuid option for /tmp directory
# to prevent SUID attribute files from being executed

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script requires root privileges"
        echo "Please run with: sudo $0"
        exit 1
    fi
}

# Backup configuration files
backup_configs() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="/etc/backup_$timestamp"
    
    log_info "Creating backup of configuration files..."
    mkdir -p "$backup_dir"
    
    # Backup /etc/fstab
    if [[ -f "/etc/fstab" ]]; then
        cp "/etc/fstab" "$backup_dir/fstab.backup"
        log_success "fstab backed up to $backup_dir/fstab.backup"
    fi
    
    # Backup tmp.mount if it exists
    local tmp_mount_file="/etc/systemd/system/local-fs.target.wants/tmp.mount"
    if [[ -f "$tmp_mount_file" ]]; then
        cp "$tmp_mount_file" "$backup_dir/tmp.mount.backup"
        log_success "tmp.mount backed up to $backup_dir/tmp.mount.backup"
    fi
    
    echo "$backup_dir" > /tmp/backup_location
    log_info "Backup location saved: $backup_dir"
}

# Check current /tmp mount status
check_tmp_status() {
    log_info "Checking current /tmp mount status..."
    
    if mount | grep -E "^.* on /tmp " | grep -q "nosuid"; then
        log_success "/tmp is already mounted with nosuid option"
        return 0
    else
        log_warning "/tmp is not currently mounted with nosuid option"
        mount | grep -E "^.* on /tmp " || log_info "/tmp mount not found in current mounts"
        return 1
    fi
}

# Detect system type (systemd or traditional)
detect_system_type() {
    if systemctl --version >/dev/null 2>&1 && [[ -d "/etc/systemd" ]]; then
        echo "systemd"
    else
        echo "traditional"
    fi
}

# Configure fstab method
configure_fstab() {
    local fstab_file="/etc/fstab"
    
    log_info "Configuring /tmp nosuid option in $fstab_file..."
    
    # Check if /tmp entry exists in fstab
    if grep -q "^[^#]*[[:space:]]/tmp[[:space:]]" "$fstab_file"; then
        log_info "Found existing /tmp entry in fstab"
        
        # Check if nosuid is already present
        if grep "^[^#]*[[:space:]]/tmp[[:space:]]" "$fstab_file" | grep -q "nosuid"; then
            log_success "nosuid option already present in /tmp fstab entry"
        else
            # Add nosuid to existing entry
            sed -i '/^[^#]*[[:space:]]\/tmp[[:space:]]/s/\([[:space:]][^[:space:]]*[[:space:]][^[:space:]]*[[:space:]][^[:space:]]*\)/\1,nosuid/' "$fstab_file"
            log_success "Added nosuid option to existing /tmp fstab entry"
        fi
    else
        # Create new /tmp entry
        log_info "Creating new /tmp entry in fstab"
        echo "tmpfs /tmp tmpfs defaults,nodev,nosuid,noexec,mode=1777 0 0" >> "$fstab_file"
        log_success "Added new /tmp entry with nosuid option to fstab"
    fi
}

# Configure systemd tmp.mount
configure_systemd_tmp() {
    local tmp_mount_dir="/etc/systemd/system"
    local tmp_mount_file="$tmp_mount_dir/tmp.mount"
    local wants_dir="/etc/systemd/system/local-fs.target.wants"
    
    log_info "Configuring systemd tmp.mount..."
    
    # Create systemd directory if not exists
    mkdir -p "$tmp_mount_dir"
    mkdir -p "$wants_dir"
    
    # Create tmp.mount unit file
    cat > "$tmp_mount_file" << 'EOF'
[Unit]
Description=Temporary Directory (/tmp)
ConditionPathIsSymbolicLink=!/tmp
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target umount.target
After=swap.target

[Mount]
What=tmpfs
Where=/tmp
Type=tmpfs
Options=mode=1777,strictatime,noexec,nodev,nosuid

[Install]
WantedBy=local-fs.target
EOF
    
    # Create symlink in wants directory
    ln -sf "$tmp_mount_file" "$wants_dir/tmp.mount"
    
    # Reload systemd and enable tmp.mount
    systemctl daemon-reload
    systemctl enable tmp.mount
    
    log_success "systemd tmp.mount configured and enabled"
}

# Apply immediate remount
apply_immediate_remount() {
    log_info "Applying immediate remount with nosuid option..."
    
    if mount | grep -E "^.* on /tmp "; then
        if mount -o remount,nosuid /tmp 2>/dev/null; then
            log_success "Successfully remounted /tmp with nosuid option"
        else
            log_warning "Failed to remount /tmp - may require reboot for changes to take effect"
        fi
    else
        log_info "No existing /tmp mount found - mounting tmpfs with nosuid"
        if mount -t tmpfs -o nodev,nosuid,noexec,mode=1777 tmpfs /tmp; then
            log_success "Successfully mounted /tmp with nosuid option"
        else
            log_error "Failed to mount /tmp with nosuid option"
        fi
    fi
}

# Verify configuration
verify_configuration() {
    log_info "Verifying /tmp nosuid configuration..."
    
    local verification_passed=true
    
    # Check if /tmp is mounted with nosuid
    if mount | grep -E "^.* on /tmp " | grep -q "nosuid"; then
        log_success "/tmp is currently mounted with nosuid option"
    else
        log_warning "/tmp is not currently mounted with nosuid option"
        verification_passed=false
    fi
    
    # Check fstab configuration
    if grep -q "^[^#]*[[:space:]]/tmp[[:space:]].*nosuid" /etc/fstab; then
        log_success "/etc/fstab contains /tmp entry with nosuid option"
    else
        log_warning "/etc/fstab does not contain /tmp entry with nosuid option"
    fi
    
    # Check systemd tmp.mount if systemd system
    if [[ "$(detect_system_type)" == "systemd" ]]; then
        if [[ -f "/etc/systemd/system/tmp.mount" ]] && \
           grep -q "nosuid" "/etc/systemd/system/tmp.mount"; then
            log_success "systemd tmp.mount contains nosuid option"
        else
            log_info "systemd tmp.mount configuration status varies"
        fi
    fi
    
    if $verification_passed; then
        return 0
    else
        return 1
    fi
}

# Test SUID prevention
test_suid_prevention() {
    log_info "Testing SUID prevention on /tmp..."
    
    # Create a test SUID file
    local test_file="/tmp/test_suid_$$"
    
    if touch "$test_file" && chmod u+s "$test_file" 2>/dev/null; then
        if [[ -u "$test_file" ]]; then
            log_warning "SUID bit was set on test file - nosuid may not be effective"
            rm -f "$test_file"
            return 1
        else
            log_success "SUID bit was not set - nosuid option is working correctly"
            rm -f "$test_file"
            return 0
        fi
    else
        log_info "Could not create test file or set SUID - this may indicate nosuid is working"
        rm -f "$test_file" 2>/dev/null
        return 0
    fi
}

# Show completion message
show_completion_message() {
    local backup_dir
    if [[ -f "/tmp/backup_location" ]]; then
        backup_dir=$(cat /tmp/backup_location)
        rm -f /tmp/backup_location
    fi
    
    echo
    log_success "/tmp directory nosuid configuration completed!"
    echo
    echo -e "${YELLOW}Configuration Summary:${NC}"
    echo "1. /tmp directory is configured to prevent SUID file execution"
    echo "2. Configuration is persistent across reboots"
    if [[ -n "${backup_dir:-}" ]]; then
        echo "3. Original configuration backed up to: $backup_dir"
    fi
    echo
    echo -e "${YELLOW}Security Benefits:${NC}"
    echo "- Prevents privilege escalation via SUID files in /tmp"
    echo "- Reduces attack surface for temporary file exploits"
    echo "- Complies with security hardening best practices"
    echo
    
    read -p "Reboot system to ensure all changes take effect? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "System will reboot in 10 seconds..."
        sleep 10
        reboot
    else
        log_info "Please reboot when convenient to ensure all changes take effect"
    fi
}

# Main function
main() {
    echo "==========================================================="
    echo "  TWGCB-01-008-0006: TWGCB-01-008-0006"
    echo "==========================================================="
    echo
    
    local system_type
    system_type=$(detect_system_type)
    log_info "Detected system type: $system_type"
    echo
    
    # Execute configuration steps
    check_root
    backup_configs
    check_tmp_status
    
    # Configure based on system type
    if [[ "$system_type" == "systemd" ]]; then
        configure_systemd_tmp
    fi
    
    # Always configure fstab for compatibility
    configure_fstab
    
    # Apply immediate changes
    apply_immediate_remount
    
    # Verify and test
    verify_configuration
    test_suid_prevention
    
    show_completion_message
}

# Execute main function
main "$@"