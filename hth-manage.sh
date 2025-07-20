#!/bin/bash

################################################################################
# hth-manage.sh - Helpthehomeless Wallet Management Script
# Version: 1.5
# Description: Deploys a super simple Peer - Bloom enabled wallet designed for a single core VPS so it uses cpulimit to limit the wallet to 10% of CPU
# Adds ipv4 and ipv6 peers for the wallet in the config
# Installs everything needed to use the pre-built wallet.
# Will download the daemon, CLI. Start the Daemon, Cpulimit the Daemon. 
# Has smarts to handle IPv6 only VPS's so we can still get the files from github (Shame for no IPv6). 
# Adds DNS64 if V6 only for help navigating most IPv4 domains.
# Built for Server versions of Debian 11+ and Ubuntu 20.04+
#
# Usage:
# Run as root from /root
# wget https://github.com/R4nd0m-us/HTH-STUFF/raw/refs/heads/main/hth-manage.sh
# IPv6 Only use wget https://gh-v6.com/R4nd0m-us/HTH-STUFF/raw/refs/heads/main/hth-manage.sh
# chmod +x hth-manage.sh
# ./hth-manage.sh
# Author: R4nd0m.us AKA Cryptominer937 
################################################################################

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
COL_RESET='\033[0m'

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/hth-manage.log" # Changed log file name to match script
DEBUG_MODE=false

# Wallet specific variables (as per user request)
WALLET_DIR="/root/.helpthehomeless"
CONFIG_FILE="$WALLET_DIR/helpthehomeless.conf"
WALLET_DAEMON="/root/helpthehomelessd"
WALLET_CLI="/root/helpthehomeless-cli"
SCREEN_SESSION_NAME="hthwallet" # Changed from 'hthd' to 'hthwallet' as requested

################################################################################
# Logging and Debug Functions
################################################################################

# Initialize logging
init_logging() {
    # Clean up old log files (keep only last 10)
    if [[ -f "$LOG_FILE" ]]; then
        local log_dir="$(dirname "$LOG_FILE")"
        local log_name="$(basename "$LOG_FILE" .log)"
        # Archive current log if it exists
        if [[ -s "$LOG_FILE" ]]; then
            mv "$LOG_FILE" "${log_dir}/${log_name}_$(date +%Y%m%d_%H%M%S).log"
        fi
        # Clean up old archived logs (keep only 10 most recent)
        ls -t "${log_dir}/${log_name}_"*.log 2>/dev/null | tail -n +11 | xargs -r rm -f
    fi
    echo "=== hth-manage.sh Script Started: $(date) ===" > "$LOG_FILE"
    echo "Script: ${BASH_SOURCE[1]:-$0}" >> "$LOG_FILE"
    echo "User: $(whoami)" >> "$LOG_FILE"
    echo "Working Directory: $(pwd)" >> "$LOG_FILE"
    echo "=================================" >> "$LOG_FILE"
}

# Debug logging function
debug_log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $message" >> "$LOG_FILE"
    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo -e "${CYAN}[DEBUG]${COL_RESET} $message"
    fi
}

# Error logging function
error_log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $message" >> "$LOG_FILE"
    echo -e "${RED}[ERROR]${COL_RESET} $message"
}

# Info logging function
info_log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $message" >> "$LOG_FILE"
    echo -e "${GREEN}[INFO]${COL_RESET} $message"
}

################################################################################
# Spinner Functions
################################################################################

# Spinner animation function
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

################################################################################
# Prerequisites Installation
################################################################################

# Install required prerequisites
install_prerequisites() {
    show_section "Installing Prerequisites"

    local screen_was_installed=false

    # Check if figlet is installed
    if ! command -v figlet &> /dev/null; then
        apt_install figlet
    else
        info_log "figlet already installed"
    fi

    # Check if lolcat is installed
    if ! command -v lolcat &> /dev/null; then
        apt_install lolcat
    else
        info_log "lolcat already installed"
    fi

    # Check if wget is installed
    if ! command -v wget &> /dev/null; then
        apt_install wget
    else
        info_log "wget already installed"
    fi

    # Check if htop is installed
    if ! command -v htop &> /dev/null; then
        apt_install htop
    else
        info_log "htop already installed"
    fi

    # Check if cpulimit is installed
    if ! command -v cpulimit &> /dev/null; then
        apt_install cpulimit
    else
        info_log "cpulimit already installed"
    fi

    # Check if screen is installed
    if ! command -v screen &> /dev/null; then
        apt_install screen
        screen_was_installed=true
    else
        info_log "screen already installed"
    fi

    # Handle first-time screen run to dismiss any initial prompts
    if [[ "$screen_was_installed" == "true" ]]; then
        echo -e "${CYAN}Performing first-run setup for screen...${COL_RESET}"
        # Create a dummy session and immediately quit it to dismiss any welcome messages
        screen -dmS temp_screen_init bash -c "true"
        sleep 1 # Give screen a moment to start
        screen -X -S temp_screen_init quit > /dev/null 2>&1
        info_log "Screen first-run setup completed."
    fi

    show_success "Prerequisites installation completed"
}

# Hide output function with spinner
hide_output() {
    local command="$*"
    debug_log "Executing: $command"

    # Reverted to original behavior (hiding output with spinner)
    if [[ "$DEBUG_MODE" == "true" ]]; then
        eval "$command"
    else
        eval "$command" > /dev/null 2>&1 &
        spinner $!
        wait $!
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
            error_log "Command failed with exit code $exit_code: $command"
            return $exit_code
        fi
    fi
}

################################################################################
# System Detection Functions
################################################################################

# Detect operating system
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
        debug_log "Detected OS: $OS $VER"
        echo "$OS"
    else
        error_log "Cannot detect operating system"
        exit 1
    fi
}

# Check if running as root (REQUIRED for /root/ directory and apt commands)
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_log "This script must be run as root."
        echo -e "${RED}Please run this script with sudo: sudo ./hth-manage.sh${COL_RESET}"
        exit 1
    fi
    debug_log "Running as root confirmed."
}

# Function to check if the system is IPv6-only
is_ipv6_only() {
    # Check for global IPv4 addresses (excluding loopback and link-local)
    local has_ipv4_address=$(ip -4 addr show scope global | grep -q 'inet ' && echo true || echo false)
    # Check for a default IPv4 route
    local has_ipv4_route=$(ip -4 route show default | grep -q 'default' && echo true || echo false)

    if [[ "$has_ipv4_address" == "false" && "$has_ipv4_route" == "false" ]]; then
        debug_log "System detected as potentially IPv6-only."
        return 0 # True (IPv6-only)
    else
        debug_log "System detected as having IPv4 connectivity."
        return 1 # False (not IPv6-only)
    fi
}

################################################################################
# Package Management Functions
################################################################################

# Update package lists
update_packages() {
    echo -e "${CYAN}Updating package lists...${COL_RESET}"
    hide_output sudo apt update
    info_log "Package lists updated"
}

# Install a package with error checking
apt_install() {
    local package="$1"
    echo -e "${CYAN}Installing $package...${COL_RESET}"
    # Switched to apt-get for more consistent non-interactive behavior
    sudo apt-get install -y "$package"
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        info_log "Successfully installed: $package"
    else
        error_log "Failed to install: $package (Exit Code: $exit_code)"
        echo -e "${RED}Installation of $package failed. Please check the output above for errors.${COL_RESET}"
        exit 1
    fi
}

################################################################################
# Banner and Display Functions
################################################################################

# Display the main banner
show_banner() {
    clear
    echo
    # Ensure figlet and lolcat are installed before using them
    if command -v figlet &> /dev/null && command -v lolcat &> /dev/null; then
        figlet -f slant -w 80 "HTH Manager By R4ndom.us" | lolcat -f -a -s 100 -t
    else
        echo -e "${CYAN}### HTH Manager ###${COL_RESET}"
    fi
    echo
}

# Display a section header
show_section() {
    local section_name="$1"
    echo
    echo -e "${YELLOW}============================================================${COL_RESET}"
    echo -e "${YELLOW}   $section_name${COL_RESET}"
    echo -e "${YELLOW}============================================================${COL_RESET}"
    echo
}

# Display success message
show_success() {
    local message="$1"
    echo -e "${GREEN}✅ $message${COL_RESET}"
}

# Display warning message
show_warning() {
    local message="$1"
    echo -e "${YELLOW}⚠️  $message${COL_RESET}"
}

# Display error message
show_error() {
    local message="$1"
    echo -e "${RED}❌ $message${COL_RESET}"
}

################################################################################
# Input Functions
################################################################################

# Read user input with prompt
read_input() {
    local prompt="$1"
    local variable_name="$2"
    local default_value="$3"

    if [[ -n "$default_value" ]]; then
        read -p "$prompt [$default_value]: " input
        if [[ -z "$input" ]]; then
            input="$default_value"
        fi
    else
        read -p "$prompt: " input
    fi

    eval "$variable_name='$input'"
    debug_log "User input for '$prompt': $input"
}

# Read yes/no input
read_yes_no() {
    local prompt="$1"
    local variable_name="$2"
    local default_value="${3:-n}"

    while true; do
        read_input "$prompt [y/N]" response "$default_value"
        case "$response" in
            [Yy]|[Yy][Ee][Ss])
                eval "$variable_name='y'"
                break
                ;;
            [Nn]|[Nn][Oo]|"")
                eval "$variable_name='n'"
                break
                ;;
            *)
                show_error "Please answer yes (y) or no (n)"
                ;;
        esac
    done
}

################################################################################
# Wallet Specific Functions
################################################################################

# Function to configure the wallet
configure_wallet() {
    show_section "Configuring Wallet"
    echo "Creating wallet directory and configuration file..."
    mkdir -p "$WALLET_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        cat <<EOF > "$CONFIG_FILE"
tx-index=1
server=1
maxconnections=1000
addnode=188.119.191.19
addnode=24.229.175.195
addnode=37.26.136.250
addnode=2602:f953:6:8c::a
addnode=2602:f7c4:1:560c::1
daemon=1
EOF
        info_log "Configuration file created at $CONFIG_FILE"
    else
        info_log "Configuration file already exists. Skipping creation."
    fi
}

# Function to download and set up the wallet binaries
setup_wallet_binaries() {
    show_section "Setting Up Wallet Binaries"
    echo "Downloading and setting up Helpthehomeless binaries..."

    local github_base_url="https://github.com"
    if is_ipv6_only; then
        github_base_url="https://gh-v6.com"
        info_log "Detected IPv6-only system, using GitHub mirror: $github_base_url"
    else
        info_log "System has IPv4 connectivity, using standard GitHub: $github_base_url"
    fi

    # Construct full download URLs using the determined base URL
    local cli_url="${github_base_url}/HTHcoin/helpthehomelesscoin/releases/download/0.14.1/helpthehomeless-cli"
    local daemon_url="${github_base_url}/HTHcoin/helpthehomelesscoin/releases/download/0.14.1/helpthehomelessd"

    # Added check for existing binaries to prevent re-downloading
    if [ ! -f "$WALLET_CLI" ] || [ ! -f "$WALLET_DAEMON" ]; then
        echo -e "${CYAN}Downloading helpthehomeless-cli from ${cli_url}...${COL_RESET}"
        hide_output curl -L -o "$WALLET_CLI" "$cli_url"
        local cli_download_status=$?

        echo -e "${CYAN}Downloading helpthehomelessd from ${daemon_url}...${COL_RESET}"
        hide_output curl -L -o "$WALLET_DAEMON" "$daemon_url"
        local daemon_download_status=$?
    else
        info_log "Wallet binaries already exist. Skipping download."
        local cli_download_status=0 # Assume success if files exist
        local daemon_download_status=0 # Assume success if files exist
    fi


    if [ "$cli_download_status" -eq 0 ] && [ "$daemon_download_status" -eq 0 ] && [ -f "$WALLET_DAEMON" ] && [ -f "$WALLET_CLI" ]; then
        chmod +x "$WALLET_DAEMON"
        chmod +x "$WALLET_CLI"
        info_log "Binaries downloaded (if needed) and made executable."
    else
        error_log "Error downloading binaries. One or both downloads failed or files are missing."
        exit 1
    fi
}

# Function to start the wallet in a detached screen session with cpulimit
start_wallet() {
    show_section "Starting Wallet Daemon"
    echo "Starting Helpthehomeless daemon in a detached screen session..."

    # Start the daemon directly in screen
    screen -dmS "$SCREEN_SESSION_NAME" "$WALLET_DAEMON"
    if [ $? -ne 0 ]; then
        error_log "Error starting Helpthehomeless daemon in screen. Exiting."
        exit 1
    fi
    info_log "Helpthehomeless daemon started in screen session '$SCREEN_SESSION_NAME'."

    echo -e "${CYAN}Waiting for daemon to initialize and get PID for cpulimit (max 20 tries, 3s interval)...${COL_RESET}"
    local daemon_pid=""
    local attempts=0
    local max_attempts=20
    local sleep_interval=3

    while [[ -z "$daemon_pid" && "$attempts" -lt "$max_attempts" ]]; do
        sleep "$sleep_interval"
        daemon_pid=$(pgrep -f "$WALLET_DAEMON")
        attempts=$((attempts + 1))
        echo -n "." # Visual feedback
    done
    echo # Newline after dots

    if [[ -n "$daemon_pid" ]]; then
        echo -e "${CYAN}Applying cpulimit -l 10 -p to PID: $daemon_pid${COL_RESET}"
        # Apply cpulimit to the daemon's PID, and run in background
        cpulimit -l 10 -p "$daemon_pid" &
        if [ $? -eq 0 ]; then
            info_log "cpulimit applied successfully to PID $daemon_pid."
        else
            error_log "Failed to apply cpulimit to PID $daemon_pid."
        fi
    else
        show_warning "Could not find PID for $WALLET_DAEMON after $((max_attempts * sleep_interval)) seconds. cpulimit will not be applied."
        error_log "Failed to start daemon: Could not find PID for $WALLET_DAEMON after $((max_attempts * sleep_interval)) seconds. Exiting."
        exit 1 # Exit if daemon fails to start
    fi

    echo -e "${YELLOW}You can re-attach to the session using: screen -r $SCREEN_SESSION_NAME${COL_RESET}"
    echo -e "${YELLOW}Or run this script with: sudo ./hth-manage.sh -go${COL_RESET}"
}

# Function to configure Cloudflare DNS64 if the system is IPv6-only
configure_dns64_if_ipv6_only() {
    show_section "Configuring DNS64 (if IPv6-only)"
    if is_ipv6_only; then
        echo -e "${CYAN}System detected as IPv6-only. Configuring /etc/resolv.conf with Cloudflare DNS64...${COL_RESET}"
        local resolv_conf="/etc/resolv.conf"
        local resolv_conf_backup="${resolv_conf}.$(date +%Y%m%d_%H%M%S).bak"

        # Backup existing resolv.conf
        if [[ -f "$resolv_conf" ]]; then
            sudo cp "$resolv_conf" "$resolv_conf_backup"
            info_log "Backed up $resolv_conf to $resolv_conf_backup"
        else
            info_log "$resolv_conf does not exist, no backup needed."
        fi

        # Write new resolv.conf with DNS64 addresses
        cat <<EOF | sudo tee "$resolv_conf" > /dev/null
nameserver 2606:4700:4700::64
nameserver 2606:4700:4700::6400
EOF
        if [ $? -eq 0 ]; then
            info_log "Successfully configured $resolv_conf with Cloudflare DNS64."
            echo -e "${GREEN}Cloudflare DNS64 configured for IPv6-only system.${COL_RESET}"
        else
            error_log "Failed to configure $resolv_conf with Cloudflare DNS64."
            echo -e "${RED}Failed to configure Cloudflare DNS64. Please check permissions or system configuration.${COL_RESET}"
        fi
    else
        info_log "System is not IPv6-only. Skipping DNS64 configuration."
        echo -e "${YELLOW}System has IPv4 connectivity. DNS64 configuration skipped.${COL_RESET}"
    fi
}

# Function to add GitHub IPv6 entries to /etc/hosts
configure_github_hosts_entries() {
    show_section "Configuring GitHub IPv6 Hosts Entries"
    local hosts_file="/etc/hosts"
    local hosts_backup="${hosts_file}.$(date +%Y%m%d_%H%M%S).bak"

    # Define GitHub IPv6 entries
    local github_entries=(
        "2a01:4f8:c010:d56::2 github.com"
        "2a01:4f8:c010:d56::3 api.github.com"
        "2a01:4f8:c010:d56::4 codeload.github.com"
        "2a01:4f8:c010:d56::5 objects.githubusercontent.com"
        "2a01:4f8:c010:d56::6 ghcr.io"
        "2a01:4f8:c010:d56::7 pkg.github.com npm.pkg.github.com maven.pkg.github.com nuget.pkg.github.com rubygems.pkg.github.com"
        "2a01:4f8:c010:d56::8 uploads.github.com"
    )

    echo -e "${CYAN}Adding GitHub IPv6 entries to $hosts_file...${COL_RESET}"

    # Backup existing hosts file
    if [[ -f "$hosts_file" ]]; then
        sudo cp "$hosts_file" "$hosts_backup"
        info_log "Backed up $hosts_file to $hosts_backup"
    else
        info_log "$hosts_file does not exist, no backup needed."
    fi

    local entries_added=0
    for entry in "${github_entries[@]}"; do
        # Check if the entry already exists to avoid duplicates
        if ! grep -qF "$entry" "$hosts_file"; then
            echo "$entry" | sudo tee -a "$hosts_file" > /dev/null
            if [ $? -eq 0 ]; then
                info_log "Added host entry: $entry"
                entries_added=$((entries_added + 1))
            else
                error_log "Failed to add host entry: $entry"
            fi
        else
            info_log "Host entry already exists, skipping: $entry"
        fi
    done

    if [[ "$entries_added" -gt 0 ]]; then
        show_success "Successfully added $entries_added new GitHub IPv6 entries to $hosts_file."
    else
        show_warning "No new GitHub IPv6 entries were added to $hosts_file (all already existed or an error occurred)."
    fi
}


################################################################################
# Main Initialization Function
################################################################################

# Initialize the base script
init_cryptobase() {
    local script_title="${1:-HTH Manager}"

    # Initialize logging
    init_logging

    # Ensure running as root
    check_root

    # Install prerequisites (includes screen first-run handling)
    install_prerequisites

    # Show banner
    show_banner "$script_title"

    # Detect OS
    local os=$(detect_os)
    info_log "Running on: $os"

    # Update packages
    update_packages

    # Configure DNS64 if the system is IPv6-only
    configure_dns64_if_ipv6_only

    # Configure GitHub IPv6 hosts entries (before wallet binaries download)
    configure_github_hosts_entries

    # Configure the wallet directory and config file
    configure_wallet

    # Download and set up wallet binaries
    setup_wallet_binaries

    # Start the wallet daemon in a screen session and apply cpulimit
    start_wallet

    show_success "HTH-Peer initialization completed"
    show_success "It will take time to sync. Check its status with: $WALLET_CLI getinfo"
    debug_log "HTH Manager initialization completed successfully"
}

################################################################################
# Utility Functions
################################################################################

# Check if a service is running (not directly used for this script's main flow, but kept from template)
check_service() {
    local service_name="$1"
    if systemctl is-active --quiet "$service_name"; then
        debug_log "Service $service_name is running"
        return 0
    else
        debug_log "Service $service_name is not running"
        return 1
    fi
}

# Start and enable a service (not directly used for this script's main flow, but kept from template)
start_service() {
    local service_name="$1"
    echo -e "${CYAN}Starting $service_name service...${COL_RESET}"
    hide_output sudo systemctl start "$service_name"
    hide_output sudo systemctl enable "$service_name"
    info_log "Service $service_name started and enabled"
}

# Generate random password (kept from template)
generate_password() {
    local length="${1:-12}"
    openssl rand -base64 "$length" | tr -d "=+/" | cut -c1-"$length"
}

# Check if port is available (kept from template)
check_port() {
    local port="$1"
    if netstat -tuln | grep -q ":$port "; then
        debug_log "Port $port is in use"
        return 1
    else
        debug_log "Port $port is available"
        return 0
    fi
}

# Create directory with proper permissions (kept from template)
create_directory() {
    local dir_path="$1"
    local owner="${2:-$USER}"
    local permissions="${3:-755}"
    if [[ ! -d "$dir_path" ]]; then
        sudo mkdir -p "$dir_path"
        sudo chown "$owner:$owner" "$dir_path"
        sudo chmod "$permissions" "$dir_path"
        debug_log "Created directory: $dir_path"
    else
        debug_log "Directory already exists: $dir_path"
    fi
}

# Backup a file (kept from template)
backup_file() {
    local file_path="$1"
    local backup_suffix="${2:-.backup.$(date +%Y%m%d_%H%M%S)}"
    if [[ -f "$file_path" ]]; then
        sudo cp "$file_path" "${file_path}${backup_suffix}"
        debug_log "Backed up file: $file_path to ${file_path}${backup_suffix}"
    else
        debug_log "File not found for backup: $file_path"
    fi
}

################################################################################
# Cleanup Functions
################################################################################

# Cleanup function
cleanup() {
    debug_log "Cleanup function called"
    echo -e "\n${CYAN}Cleaning up...${COL_RESET}"
    # Clean up temporary files
    cleanup_temp_files
    # Final log entry
    echo "=== hth-manage.sh Script Ended: $(date) ===" >> "$LOG_FILE"
}

# Clean up temporary files
cleanup_temp_files() {
    local temp_patterns=(
        "*.tmp"
        "*.temp"
    )
    for pattern in "${temp_patterns[@]}"; do
        if ls $pattern >/dev/null 2>&1; then
            rm -f $pattern
            debug_log "Cleaned up temporary files: $pattern"
        fi
    done
}

# Set trap for cleanup on exit
trap cleanup EXIT

################################################################################
# Main execution logic
################################################################################

# This block determines what the script does based on arguments
if [[ "$1" == "-go" ]]; then
    show_section "Attaching to Wallet Session"
    echo "Attempting to attach to wallet screen session '$SCREEN_SESSION_NAME'..."
    if screen -list | grep -q "$SCREEN_SESSION_NAME"; then
        screen -r "$SCREEN_SESSION_NAME"
    else
        show_error "Screen session '$SCREEN_SESSION_NAME' does not exist."
        echo -e "${YELLOW}Please run the script without -go first to set up and start the wallet daemon:${COL_RESET}"
        echo -e "${YELLOW}  sudo ./hth-manage.sh${COL_RESET}"
    fi
else
    # Full setup and start if no arguments or other arguments are provided
    init_cryptobase "HTH Manager"
fi
