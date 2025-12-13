#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Script to start a TFTP lab server on Fedora and sniff traffic with tcpdump,
# restoring the environment when finished.
#
# Usage:
#   ./tftp_server.sh <network_interface> <firmware.bin>
#   ./tftp_server.sh -d <network_interface> <firmware.bin>   # debug mode
#
# Example:
#   ./tftp_server.sh enp3s0 TL-WR841N_v14_0.9.1_4.18_up_boot(190115).bin
#
# Author: [Your Name]
# Version: 2.3
# Date: $(date +%Y-%m-%d)
###############################################################################

# =============================================================================
# CONFIGURATION AND GLOBAL VARIABLES
# =============================================================================

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color
readonly BOLD='\033[1m'
readonly DIM='\033[2m'

# Status symbols
readonly CHECKMARK="✓"
readonly CROSSMARK="✗"
readonly WARNING="⚠"
readonly INFO="ℹ"

# Network configuration
readonly IPV4_LAB_ADDR="192.168.0.66/24"
readonly TFTP_PORT=69

# Paths
readonly SERVICE_PATH="/etc/systemd/system/tftp.service"
readonly SOCKET_PATH="/etc/systemd/system/tftp.socket"
readonly TFTP_ROOT="/var/lib/tftpboot"
readonly TFTP_FILENAME="tp_recovery.bin"

# State variables
declare -g IFACE FW_SRC
declare -g DEBUG_MODE=0
declare -g FIREWALL_TFTP_WAS_ENABLED="no" FIREWALL_TFTP_CHANGED="no"
declare -g SELINUX_MODE="" SELINUX_CHANGED=0
declare -g TFTP_SERVICE_PRESENT_BEFORE=0 TFTP_SOCKET_PRESENT_BEFORE=0
declare -g TFTP_SERVICE_BACKUP="" TFTP_SOCKET_BACKUP=""
declare -g TFTP_SOCKET_ENABLED_BEFORE="unknown" TFTP_SOCKET_ENABLED_CHANGED="no"
declare -g USE_NM=0 NM_CONNECTION="" NM_PREV_IPV4_METHOD="" NM_PREV_IPV4_ADDRS=""

# =============================================================================
# LOGGING AND UTILITY FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}${INFO}${NC} ${BOLD}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}${CHECKMARK}${NC} ${BOLD}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}${WARNING}${NC} ${BOLD}[WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}${CROSSMARK}${NC} ${BOLD}[ERROR]${NC} $*" >&2
}

log_debug() {
    [[ "${DEBUG_MODE}" -eq 1 ]] && echo -e "${DIM}[DEBUG] $*${NC}" >&2
}

log_cmd() {
    [[ "${DEBUG_MODE}" -eq 1 ]] && echo -e "${DIM}[CMD] $*${NC}" >&2
}

log_step() {
    echo -e "\n${CYAN}▶${NC} ${BOLD}${MAGENTA}$*${NC}"
}

log_divider() {
    echo -e "${BLUE}$(printf '=%.0s' {1..60})${NC}"
}

print_header() {
    echo -e "\n${BOLD}${CYAN}TFTP LAB SERVER SCRIPT${NC}"
    echo -e "${DIM}Version 2.3 | Fedora/RHEL/CentOS${NC}"
    log_divider
    echo
}

print_footer() {
    log_divider
    echo -e "${DIM}Script completed at $(date +%H:%M:%S)${NC}"
    log_divider
}

print_usage() {
    echo -e "${BOLD}${CYAN}Usage:${NC}"
    echo -e "  $0 [OPTIONS] <interface> <firmware.bin>"
    echo -e "\n${BOLD}${CYAN}Options:${NC}"
    echo -e "  -d, --debug    Enable debug mode (verbose output)"
    echo -e "  -h, --help     Show this help message"
    echo -e "\n${BOLD}${CYAN}Example:${NC}"
    echo -e "  $0 enp3s0 firmware.bin"
    echo -e "  $0 --debug enp45s0 firmware-backdoored-stripped.bin"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run with root privileges"
        log_info "Use: sudo $0 [args]"
        exit 1
    fi
}

check_interface() {
    if ! ip link show "$1" &>/dev/null; then
        log_error "Network interface '$1' not found"
        log_info "Available interfaces:"
        ip -brief link show | awk '{print "  - " $1}'
        return 1
    fi
    return 0
}

validate_file() {
    [[ -f "$1" ]] || {
        log_error "File '$1' not found"
        return 1
    }

    [[ -r "$1" ]] || {
        log_error "Insufficient permissions to read file '$1'"
        return 1
    }

    local size
    size=$(stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null)
    [[ $size -gt 0 ]] || {
        log_error "File '$1' is empty"
        return 1
    }

    log_success "Firmware file validated: $(basename "$1") ($((size/1024/1024)) MB)"
    return 0
}

safe_exec() {
    local cmd="$*"
    log_cmd "$cmd"
    if ! eval "$cmd" 2>/dev/null; then
        return 1
    fi
    return 0
}

# =============================================================================
# CLEANUP FUNCTION
# =============================================================================

cleanup() {
    local exit_code=$?
    echo -e "\n\n${YELLOW}${BOLD}Starting cleanup...${NC}"

    # Restore NetworkManager
    if [[ $USE_NM -eq 1 ]] && [[ -n "$NM_CONNECTION" ]]; then
        log_info "Restoring NetworkManager configuration"
        if [[ -n "$NM_PREV_IPV4_METHOD" ]]; then
            safe_exec nmcli connection modify "$NM_CONNECTION" ipv4.method "$NM_PREV_IPV4_METHOD"
        fi
        if [[ -n "$NM_PREV_IPV4_ADDRS" ]]; then
            safe_exec nmcli connection modify "$NM_CONNECTION" ipv4.addresses "$NM_PREV_IPV4_ADDRS"
        else
            safe_exec nmcli connection modify "$NM_CONNECTION" ipv4.addresses ""
        fi
        safe_exec nmcli connection up "$NM_CONNECTION"
    else
        log_info "Restoring IP configuration"
        safe_exec ip addr flush dev "$IFACE"
        if command -v dhclient &>/dev/null; then
            safe_exec dhclient "$IFACE"
        fi
    fi

    # Restore SELinux
    if [[ $SELINUX_CHANGED -eq 1 ]] && [[ -n "$SELINUX_MODE" ]]; then
        log_info "Restoring SELinux to: $SELINUX_MODE"
        safe_exec setenforce "$SELINUX_MODE"
    fi

    # Restore firewall
    if [[ "$FIREWALL_TFTP_CHANGED" == "yes" ]] && command -v firewall-cmd &>/dev/null; then
        log_info "Removing TFTP rule from firewall"
        safe_exec firewall-cmd --remove-service=tftp --permanent
        safe_exec firewall-cmd --reload
    fi

    # Stop TFTP services
    log_info "Stopping TFTP services"
    safe_exec systemctl stop tftp.service
    safe_exec systemctl stop tftp.socket

    if [[ "$TFTP_SOCKET_ENABLED_CHANGED" == "yes" ]]; then
        log_info "Disabling tftp.socket"
        safe_exec systemctl disable tftp.socket
    fi

    # Restore systemd files
    if [[ $TFTP_SERVICE_PRESENT_BEFORE -eq 0 ]] && [[ -f "$SERVICE_PATH" ]]; then
        log_info "Removing created service file"
        safe_exec rm -f "$SERVICE_PATH"
    elif [[ -f "$TFTP_SERVICE_BACKUP" ]]; then
        log_info "Restoring original service file"
        safe_exec mv -f "$TFTP_SERVICE_BACKUP" "$SERVICE_PATH"
    fi

    if [[ $TFTP_SOCKET_PRESENT_BEFORE -eq 0 ]] && [[ -f "$SOCKET_PATH" ]]; then
        log_info "Removing created socket file"
        safe_exec rm -f "$SOCKET_PATH"
    elif [[ -f "$TFTP_SOCKET_BACKUP" ]]; then
        log_info "Restoring original socket file"
        safe_exec mv -f "$TFTP_SOCKET_BACKUP" "$SOCKET_PATH"
    fi

    # Reload systemd
    safe_exec systemctl daemon-reload

    # Remove TFTP directory
    if [[ -d "$TFTP_ROOT" ]]; then
        log_info "Removing TFTP directory: $TFTP_ROOT"
        safe_exec rm -rf "$TFTP_ROOT"
    fi

    # Clean up temporary backups
    safe_exec rm -f /tmp/tftp.*.bak.*

    if [[ $exit_code -eq 0 ]]; then
        log_success "Cleanup completed successfully"
    elif [[ $exit_code -eq 130 ]]; then
        log_info "Script interrupted by user (Ctrl+C)"
    else
        log_warn "Cleanup completed with exit code: $exit_code"
    fi

    print_footer
    exit $exit_code
}

# =============================================================================
# MAIN FUNCTIONS (SIMPLIFIED LIKE ORIGINAL)
# =============================================================================

install_packages() {
    log_step "Checking required packages"

    local -a required_pkgs=("tftp-server" "tftp" "tcpdump" "iproute")
    local -a missing_pkgs=()

    for pkg in "${required_pkgs[@]}"; do
        if ! rpm -q "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        log_success "All required packages are already installed"
        return 0
    fi

    log_info "Installing packages: ${missing_pkgs[*]}"
    dnf install -y "${missing_pkgs[@]}" || {
        log_error "Failed to install packages"
        return 1
    }

    log_success "Packages installed successfully"
    return 0
}

configure_firewall() {
    log_step "Configuring firewall"

    if ! command -v firewall-cmd &>/dev/null; then
        log_warn "firewalld not installed, skipping firewall configuration"
        return 0
    fi

    if firewall-cmd --query-service=tftp --permanent &>/dev/null; then
        FIREWALL_TFTP_WAS_ENABLED="yes"
        log_info "TFTP service already enabled in firewall"
    else
        FIREWALL_TFTP_WAS_ENABLED="no"
        log_info "Enabling TFTP service in firewall"
        firewall-cmd --add-service=tftp --permanent && \
        firewall-cmd --reload && {
            FIREWALL_TFTP_CHANGED="yes"
            log_success "Firewall configured for TFTP"
        } || log_warn "Could not configure firewall, continuing anyway"
    fi

    return 0
}

configure_selinux() {
    log_step "Configuring SELinux"

    if ! command -v getenforce &>/dev/null; then
        log_warn "SELinux not available"
        return 0
    fi

    SELINUX_MODE=$(getenforce 2>/dev/null || echo "Unknown")
    log_info "Current SELinux status: $SELINUX_MODE"

    if [[ "$SELINUX_MODE" == "Enforcing" ]]; then
        log_info "Setting SELinux to Permissive mode temporarily"
        setenforce 0 && {
            SELINUX_CHANGED=1
            log_success "SELinux set to Permissive"
        } || log_warn "Could not modify SELinux"
    fi

    return 0
}

configure_systemd() {
    log_step "Configuring systemd TFTP"

    # Backup existing files
    if [[ -f "$SERVICE_PATH" ]]; then
        TFTP_SERVICE_PRESENT_BEFORE=1
        TFTP_SERVICE_BACKUP=$(mktemp /tmp/tftp.service.bak.XXXXXX)
        cp "$SERVICE_PATH" "$TFTP_SERVICE_BACKUP" 2>/dev/null || true
        log_info "Backup service: $TFTP_SERVICE_BACKUP"
    fi

    if [[ -f "$SOCKET_PATH" ]]; then
        TFTP_SOCKET_PRESENT_BEFORE=1
        TFTP_SOCKET_BACKUP=$(mktemp /tmp/tftp.socket.bak.XXXXXX)
        cp "$SOCKET_PATH" "$TFTP_SOCKET_BACKUP" 2>/dev/null || true
        log_info "Backup socket: $TFTP_SOCKET_BACKUP"
    fi

    # Create socket if it doesn't exist
    if [[ ! -f "$SOCKET_PATH" ]]; then
        if [[ -f "/usr/lib/systemd/system/tftp.socket" ]]; then
            cp /usr/lib/systemd/system/tftp.socket "$SOCKET_PATH" || {
                log_error "Failed to create socket file"
                return 1
            }
            log_info "Socket file created from system template"
        else
            log_error "System tftp.socket file not found"
            return 1
        fi
    fi

    # Create service file (SAME AS ORIGINAL)
    cat << 'EOF' > "$SERVICE_PATH"
[Unit]
Description=TFTP Server
Requires=tftp.socket
Documentation=man:in.tftpd

[Service]
ExecStart=/usr/sbin/in.tftpd -c -p -s /var/lib/tftpboot
StandardInput=socket

[Install]
WantedBy=multi-user.target
Also=tftp.socket
EOF

    log_info "Service file created"

    # Check previous state
    if systemctl list-unit-files | grep -q '^tftp.socket'; then
        TFTP_SOCKET_ENABLED_BEFORE=$(systemctl is-enabled tftp.socket 2>/dev/null || echo "disabled")
        log_info "Previous tftp.socket state: $TFTP_SOCKET_ENABLED_BEFORE"
    else
        TFTP_SOCKET_ENABLED_BEFORE="not-found"
    fi

    # Reload and enable/start
    systemctl daemon-reload
    systemctl enable --now tftp.socket || {
        log_warn "Failed to start tftp.socket, but continuing"
    }

    if [[ "$TFTP_SOCKET_ENABLED_BEFORE" != "enabled" ]]; then
        TFTP_SOCKET_ENABLED_CHANGED="yes"
    fi

    log_success "Systemd TFTP configured"
    return 0
}

setup_tftp_root() {
    log_step "Preparing TFTP directory"

    mkdir -p "$TFTP_ROOT" || {
        log_error "Failed to create TFTP directory"
        return 1
    }

    chmod 0777 "$TFTP_ROOT" || {
        log_warn "Could not set permissions on TFTP directory"
    }

    cp "$FW_SRC" "$TFTP_ROOT/$TFTP_FILENAME" || {
        log_error "Failed to copy firmware to TFTP directory"
        return 1
    }

    local fw_size
    fw_size=$(du -h "$TFTP_ROOT/$TFTP_FILENAME" | cut -f1)
    log_success "Firmware copied: $TFTP_FILENAME ($fw_size)"

    return 0
}

configure_network() {
    log_step "Configuring network interface"

    # Try NetworkManager first
    if command -v nmcli &>/dev/null; then
        USE_NM=1
        NM_CONNECTION=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v IFACE="$IFACE" '$2==IFACE{print $1; exit}')

        if [[ -z "$NM_CONNECTION" ]]; then
            NM_CONNECTION=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v IFACE="$IFACE" '$2==IFACE{print $1; exit}')
        fi

        if [[ -n "$NM_CONNECTION" ]]; then
            log_info "Using NetworkManager: $NM_CONNECTION"
            NM_PREV_IPV4_METHOD=$(nmcli -g ipv4.method connection show "$NM_CONNECTION" 2>/dev/null || echo "")
            NM_PREV_IPV4_ADDRS=$(nmcli -g ipv4.addresses connection show "$NM_CONNECTION" 2>/dev/null || echo "")

            nmcli connection modify "$NM_CONNECTION" ipv4.method manual ipv4.addresses "$IPV4_LAB_ADDR" ipv4.gateway "" ipv4.dns ""
            nmcli connection up "$NM_CONNECTION" || {
                log_warn "Could not activate NetworkManager connection"
                USE_NM=0
            }
        else
            USE_NM=0
        fi
    fi

    # Fall back to manual configuration
    if [[ $USE_NM -eq 0 ]]; then
        log_info "Using manual IP configuration"
        ip addr flush dev "$IFACE" 2>/dev/null || true
        ip addr add "$IPV4_LAB_ADDR" dev "$IFACE" || {
            log_warn "Could not configure static IP (interface may be down)"
        }
    fi

    # Show IP configuration
    local current_ip
    current_ip=$(ip -4 addr show dev "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")

    if [[ -n "$current_ip" ]]; then
        log_success "Interface $IFACE IP address: $current_ip"
    else
        log_info "Interface $IFACE is configured with: $IPV4_LAB_ADDR"
        log_info "IP will be active when interface comes up"
    fi

    return 0
}

start_server() {
    log_step "Starting TFTP server and traffic capture"

    echo -e "${GREEN}${BOLD}"
    log_divider
    echo "TFTP SERVER ACTIVE"
    log_divider
    echo -e "${NC}"

    echo -e "${CYAN}${BOLD}SERVER CONFIGURATION:${NC}"
    echo -e "  ${BOLD}Interface:${NC} $IFACE"
    echo -e "  ${BOLD}Configured IP:${NC} $IPV4_LAB_ADDR"
    echo -e "  ${BOLD}TFTP Port:${NC} $TFTP_PORT"
    echo -e "  ${BOLD}TFTP Directory:${NC} $TFTP_ROOT"
    echo -e "  ${BOLD}File Served:${NC} $TFTP_FILENAME"
    echo -e "  ${BOLD}File Size:${NC} $(du -h "$TFTP_ROOT/$TFTP_FILENAME" 2>/dev/null | cut -f1 || echo 'unknown')"
    echo -e "  ${BOLD}Interface State:${NC} $(cat /sys/class/net/"$IFACE"/operstate 2>/dev/null || echo 'unknown')"
    echo -e "  ${BOLD}TFTP Socket Status:${NC} $(systemctl is-active tftp.socket 2>/dev/null || echo 'unknown')"
    log_divider

    echo -e "${YELLOW}${BOLD}WAITING FOR TFTP REQUESTS...${NC}"
    echo -e "${DIM}Target should download: tftp://192.168.0.66/$TFTP_FILENAME${NC}"
    echo -e "${DIM}Press Ctrl+C to stop and cleanup${NC}"
    log_divider
    echo

    # Start tcpdump in foreground (LIKE ORIGINAL)
    log_info "Starting tcpdump on $IFACE port $TFTP_PORT..."
    tcpdump -i "$IFACE" -v -e -n -X -s 0 port $TFTP_PORT
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

main() {
    local help_flag=0

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--debug)
                DEBUG_MODE=1
                shift
                ;;
            -h|--help)
                help_flag=1
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done

    if [[ $help_flag -eq 1 ]]; then
        print_usage
        exit 0
    fi

    # Check arguments
    if [[ $# -ne 2 ]]; then
        log_error "Incorrect number of arguments"
        print_usage
        exit 1
    fi

    IFACE="$1"
    FW_SRC="$2"

    print_header

    # Check privileges
    check_root

    # Validate input
    log_step "Validating parameters"
    check_interface "$IFACE" || exit 1
    validate_file "$FW_SRC" || exit 1

    # Setup cleanup trap (MUST BE BEFORE ANY EXIT POSSIBILITY)
    trap cleanup EXIT INT TERM

    # Execute configuration (SAME ORDER AS ORIGINAL)
    install_packages
    configure_firewall
    configure_selinux
    configure_systemd
    setup_tftp_root
    configure_network

    # Start server
    start_server
}

# =============================================================================
# SCRIPT ENTRY POINT
# =============================================================================

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
