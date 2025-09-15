#!/bin/bash

# TWGCB-01-008-0001: Disable cramfs Filesystem Automation Script
# This script automatically disables cramfs filesystem to reduce system attack surface

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

# Backup existing configuration
backup_config() {
    local config_file="/etc/modprobe.d/cramfs.conf"
    local backup_dir="/etc/modprobe.d/backup"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    if [[ -f "$config_file" ]]; then
        log_info "Existing cramfs.conf found, creating backup..."
        mkdir -p "$backup_dir"
        cp "$config_file" "$backup_dir/cramfs.conf.backup_$timestamp"
        log_success "Backup created: $backup_dir/cramfs.conf.backup_$timestamp"
    fi
}

# Check cramfs module status
check_cramfs_status() {
    log_info "Checking current cramfs module status..."
    
    if lsmod | grep -q "cramfs"; then
        log_warning "cramfs module is currently loaded"
        return 0
    else
        log_info "cramfs module is not currently loaded"
        return 1
    fi
}

# Create cramfs.conf configuration file
create_cramfs_config() {
    local config_file="/etc/modprobe.d/cramfs.conf"
    local config_dir="/etc/modprobe.d"
    
    log_info "Creating cramfs disable configuration file..."
    
    # Ensure directory exists
    mkdir -p "$config_dir"
    
    # Create configuration file content
    cat > "$config_file" << EOF
# TWGCB-01-008-0001: Disable cramfs filesystem
# This configuration prevents cramfs module loading to reduce system attack surface
# Generated on: $(date)

# Prevent cramfs module installation
install cramfs /bin/true

# Blacklist cramfs module
blacklist cramfs
EOF
    
    # Set appropriate permissions
    chmod 644 "$config_file"
    
    log_success "cramfs.conf configuration file created: $config_file"
}

# Remove cramfs module
remove_cramfs_module() {
    log_info "Attempting to remove cramfs module..."
    
    if lsmod | grep -q "cramfs"; then
        if rmmod cramfs 2>/dev/null; then
            log_success "cramfs module removed successfully"
        else
            log_warning "Unable to remove cramfs module (may be in use)"
            log_info "Configuration will take effect after system reboot"
        fi
    else
        log_info "cramfs module not loaded, no removal needed"
    fi
}

# Verify configuration
verify_configuration() {
    local config_file="/etc/modprobe.d/cramfs.conf"
    
    log_info "Verifying configuration file..."
    
    if [[ -f "$config_file" ]]; then
        if grep -q "install cramfs /bin/true" "$config_file" && \
           grep -q "blacklist cramfs" "$config_file"; then
            log_success "Configuration file verification passed"
            return 0
        else
            log_error "Configuration file content is incorrect"
            return 1
        fi
    else
        log_error "Configuration file does not exist"
        return 1
    fi
}

# Update initramfs
update_initramfs() {
    log_info "Updating initramfs..."
    
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u
        log_success "initramfs updated"
    elif command -v dracut >/dev/null 2>&1; then
        dracut -f
        log_success "initramfs updated (dracut)"
    else
        log_warning "initramfs update tool not found, please update manually"
    fi
}

# Display completion message
show_completion_message() {
    echo
    log_success "cramfs filesystem disable operation completed!"
    echo
    echo -e "${YELLOW}Important Notes:${NC}"
    echo "1. Please reboot the system to ensure all settings take effect"
    echo "2. After reboot, cramfs module will be permanently disabled"
    echo "3. To re-enable, delete /etc/modprobe.d/cramfs.conf file"
    echo
    
    read -p "Reboot now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "System will reboot in 10 seconds..."
        sleep 10
        reboot
    else
        log_info "Please reboot manually later to complete configuration"
    fi
}

# Main function
main() {
    echo "=================================================="
    echo "  TWGCB-01-008-0001: Disable cramfs Filesystem"
    echo "=================================================="
    echo
    
    # Execute all steps
    check_root
    check_cramfs_status
    backup_config
    create_cramfs_config
    remove_cramfs_module
    verify_configuration
    update_initramfs
    show_completion_message
}

# Execute main function
main "$@"