#!/bin/bash

# ============================================
# TP-Link Firmware Patching Tool - FIXED
# ============================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Logging functions
info() { echo -e "${BLUE}[*]${NC} $1"; }
success() { echo -e "${GREEN}[+]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[-]${NC} $1"; }
bold() { echo -e "${BOLD}$1${NC}"; }
debug() { [[ "${DEBUG:-0}" -eq 1 ]] && echo -e "${PURPLE}[D]${NC} $1"; }

# Global variables
WORKDIR="/tmp/rebuild"
ORIG_FW=""
ROOTFS_DIR=""
OUTPUT_FILE=""
DEBUG=0
KEEP_WORKDIR=0
AUTO_DETECT=1
BINWALK_CMD=""

# Function to show help
show_help() {
    cat << EOF
${BOLD}TP-Link Firmware Patching Tool${NC}

${BOLD}Usage:${NC} $0 [OPTIONS]

${BOLD}Options:${NC}
  -f, --firmware FILE     Original firmware file (required)
  -r, --rootfs DIR        Modified rootfs directory (required)
  -o, --output FILE       Output patched firmware file (required)
  -w, --workdir DIR       Working directory (default: /tmp/rebuild)
  -d, --debug             Enable debug output
  -k, --keep-workdir      Keep working directory after completion
  -m, --manual            Manual parameter entry (skip auto-detection)
  -h, --help              Show this help message

${BOLD}Examples:${NC}
  $0 --firmware original.bin --rootfs ./rootfs --output patched.bin
  $0 -f original.bin -r ./rootfs -o /tmp/patched.bin
  $0 -f original.bin -r /path/to/rootfs -o /tmp/firmware.bin --debug

${BOLD}Note:${NC}
  - The script will clean ${WORKDIR} at start
  - All paths are converted to absolute paths (output may not exist yet)
  - Use --keep-workdir to preserve intermediate files
  - Output will create both regular and stripped versions
EOF
    exit 0
}

# Function to clean work directory
cleanup_workdir() {
    if [[ -d "$WORKDIR" ]]; then
        if [[ $KEEP_WORKDIR -eq 0 ]]; then
            info "Cleaning up work directory: $WORKDIR"
            rm -rf "$WORKDIR" 2>/dev/null || warning "Could not completely clean $WORKDIR"
        else
            info "Keeping work directory: $WORKDIR"
        fi
    fi
}

# Function to handle errors
handle_error() {
    local exit_code=$?
    local line=$1
    local cmd=$2
    error "Error at line $line: $cmd (exit code: $exit_code)"
    cleanup_workdir
    exit $exit_code
}

# Setup error trap
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

# Function to get absolute path
get_absolute_path() {
    local path="$1"

    # If the path is an existing directory, return its absolute path
    if [[ -d "$path" ]]; then
        (cd "$path" && pwd)
        return 0
    fi

    # If the path is an existing file, return absolute path
    if [[ -f "$path" ]]; then
        local dir=$(dirname "$path")
        local file=$(basename "$path")
        (cd "$dir" && echo "$(pwd)/$file")
        return 0
    fi

    # If the path does not exist yet, try to resolve using its parent directory
    local parent
    parent=$(dirname "$path")
    if [[ -d "$parent" ]]; then
        local file
        file=$(basename "$path")
        (cd "$parent" && echo "$(pwd)/$file")
        return 0
    fi

    # If parent directory doesn't exist, error out with clear message
    error "Path or parent directory does not exist: $path"
    error "Ensure the parent directory exists or create it first: $parent"
    exit 1
}

# Function to check dependencies
check_deps() {
    info "Checking dependencies..."
    local missing=()
    for cmd in unsquashfs mksquashfs; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    # Check for binwalk or binwalk3
    if ! command -v binwalk &>/dev/null && ! command -v binwalk3 &>/dev/null; then
        missing+=("binwalk or binwalk3")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing the following commands: ${missing[*]}"
        exit 1
    fi
    success "All dependencies are satisfied."
}

# Function to get stripped filename
get_stripped_filename() {
    local base_file="$1"
    local dir=$(dirname "$base_file")
    local filename=$(basename "$base_file")
    local name="${filename%.*}"
    local ext="${filename##*.}"

    if [[ "$ext" == "$filename" ]]; then
        # no extension
        echo "$dir/${filename}-stripped"
    elif [[ "$ext" == "bin" ]]; then
        echo "$dir/${name}-stripped.bin"
    else
        echo "$dir/${name}-stripped.$ext"
    fi
}

# Main function
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--firmware)
                ORIG_FW="$2"
                shift 2
                ;;
            -r|--rootfs)
                ROOTFS_DIR="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -w|--workdir)
                WORKDIR="$2"
                shift 2
                ;;
            -d|--debug)
                DEBUG=1
                shift
                ;;
            -k|--keep-workdir)
                KEEP_WORKDIR=1
                shift
                ;;
            -m|--manual)
                AUTO_DETECT=0
                shift
                ;;
            -h|--help)
                show_help
                ;;
            -*)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                error "Unexpected argument: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [[ $DEBUG -eq 0 ]]; then
        clear
    fi

    bold "========================================"
    bold "    TP-Link Firmware Patching Tool"
    bold "========================================"
    echo

    # Validate required arguments
    if [[ -z "$ORIG_FW" ]] || [[ -z "$ROOTFS_DIR" ]] || [[ -z "$OUTPUT_FILE" ]]; then
        error "Missing required arguments"
        echo
        echo "Usage: $0 --firmware FILE --rootfs DIR --output FILE"
        echo "Try '$0 --help' for more information."
        exit 1
    fi

    # Convert paths to absolute (OUTPUT_FILE may not exist yet — function handles that)
    ORIG_FW=$(get_absolute_path "$ORIG_FW")
    ROOTFS_DIR=$(get_absolute_path "$ROOTFS_DIR")
    OUTPUT_FILE=$(get_absolute_path "$OUTPUT_FILE")

    info "Original firmware: $ORIG_FW"
    info "Rootfs directory: $ROOTFS_DIR"
    info "Output file: $OUTPUT_FILE"

    # Validate files/directories
    if [[ ! -f "$ORIG_FW" ]]; then
        error "Firmware file not found: $ORIG_FW"
        exit 1
    fi

    if [[ ! -d "$ROOTFS_DIR" ]]; then
        error "Rootfs directory not found: $ROOTFS_DIR"
        exit 1
    fi

    # Check dependencies
    check_deps

    # Clean and create work directory
    if [[ -d "$WORKDIR" ]]; then
        info "Cleaning existing work directory: $WORKDIR"
        rm -rf "$WORKDIR"
    fi

    mkdir -p "$WORKDIR"
    success "Created work directory: $WORKDIR"

    # --------------------------------------------------
    # 1. DETERMINE BINWALK COMMAND
    # --------------------------------------------------
    if command -v binwalk &>/dev/null; then
        BINWALK_CMD="binwalk"
    elif command -v binwalk3 &>/dev/null; then
        BINWALK_CMD="binwalk3"
    else
        error "Neither binwalk nor binwalk3 are available."
        exit 1
    fi

    info "Using $(bold "$BINWALK_CMD") for analysis..."

    # --------------------------------------------------
    # 2. DETECT SQUASHFS PARAMETERS (with advanced fallback)
    # --------------------------------------------------
    info "Analyzing firmware to detect offset and SquashFS parameters..."

    local OFFSET BLOCK_SIZE COMPRESSION
    local SQUASHFS_LINE=""

    if [[ $AUTO_DETECT -eq 1 ]]; then
        # Try auto-detection
        SQUASHFS_LINE=$($BINWALK_CMD "$ORIG_FW" 2>/dev/null | grep -i "squashfs" | head -1 || true)

        if [[ -n "$SQUASHFS_LINE" ]]; then
            info "Auto-detection successful!"
            info "Found line: $(bold "$SQUASHFS_LINE")"

            # Extract offset (first column) - handles both decimal and hexadecimal
            OFFSET=$(echo "$SQUASHFS_LINE" | awk '{print $1}')
            # If offset is hexadecimal (e.g., 0x100200), convert it
            if [[ $OFFSET == 0x* ]]; then
                OFFSET=$((OFFSET))
            fi
            info "SquashFS offset detected: $(bold "$OFFSET (0x$(printf '%x' "$OFFSET"))")"
        else
            warning "Auto-detection failed."
            AUTO_DETECT=0
        fi
    fi

    # Manual entry if auto-detection failed or disabled
    if [[ $AUTO_DETECT -eq 0 ]]; then
        echo
        info "Showing complete output of $(bold "$BINWALK_CMD") for file $(bold "$(basename "$ORIG_FW")"):"
        echo "----------------------------------------------------------------"
        $BINWALK_CMD "$ORIG_FW"
        echo "----------------------------------------------------------------"
        echo
        warning "In the output above, look for the line containing 'SquashFS'."
        info "Take the number from the FIRST column of that line (offset)."
        info "Example: if you see '1049088 0x100200 SquashFS filesystem...', the offset is 1049088"
        echo

        while true; do
            read -p "Enter SquashFS offset (number from first column): " USER_OFFSET
            if [[ -n "$USER_OFFSET" ]]; then
                # If it's hexadecimal (e.g., 0x100200), convert
                if [[ $USER_OFFSET == 0x* ]]; then
                    USER_OFFSET=$((USER_OFFSET))
                fi
                # Verify it's a number
                if [[ "$USER_OFFSET" =~ ^[0-9]+$ ]]; then
                    OFFSET="$USER_OFFSET"
                    success "Offset set to: $(bold "$OFFSET")"
                    break
                else
                    error "Invalid offset. Enter a number (e.g., 1049088)."
                fi
            else
                error "You must enter an offset to proceed."
            fi
        done

        # Also ask for block size and compression manually
        echo
        info "Now enter the other parameters:"

        # Block size with default value based on your commands
        read -p "Block Size [default: 262144]: " USER_BLOCK_SIZE
        if [[ -z "$USER_BLOCK_SIZE" ]]; then
            BLOCK_SIZE="262144"
        else
            BLOCK_SIZE="$USER_BLOCK_SIZE"
        fi

        # Compression with default value
        read -p "Compression [default: xz]: " USER_COMPRESSION
        if [[ -z "$USER_COMPRESSION" ]]; then
            COMPRESSION="xz"
        else
            COMPRESSION="$USER_COMPRESSION"
        fi
    fi

    # If we got here with OFFSET but without BLOCK_SIZE/COMPRESSION (auto-detection)
    if [[ -n "${OFFSET:-}" ]] && ([[ -z "${BLOCK_SIZE:-}" ]] || [[ -z "${COMPRESSION:-}" ]]); then
        # Extract the SquashFS block temporarily to read parameters
        local TEMP_SQUASHFS="$WORKDIR/temp_original.squashfs"
        info "Extracting SquashFS block for parameter analysis..."
        dd if="$ORIG_FW" bs=1 skip="$OFFSET" of="$TEMP_SQUASHFS" 2>/dev/null || true

        if [[ ! -s "$TEMP_SQUASHFS" ]]; then
            warning "Unable to extract filesystem from offset $OFFSET (temporary). Using defaults."
            BLOCK_SIZE="${BLOCK_SIZE:-262144}"
            COMPRESSION="${COMPRESSION:-xz}"
        else
            # Read parameters with unsquashfs -s
            local SQUASHFS_INFO
            SQUASHFS_INFO=$(unsquashfs -s "$TEMP_SQUASHFS" 2>/dev/null || true)
            rm -f "$TEMP_SQUASHFS"

            # Extract Block Size and Compression
            BLOCK_SIZE=$(echo "$SQUASHFS_INFO" | grep "Block size" | awk '{print $3}' || true)
            COMPRESSION=$(echo "$SQUASHFS_INFO" | grep "Compression" | awk '{print $2}' || true)

            if [[ -z "$BLOCK_SIZE" ]] || [[ -z "$COMPRESSION" ]]; then
                warning "Unable to read parameters from filesystem. Falling back to defaults."
                BLOCK_SIZE="${BLOCK_SIZE:-262144}"
                COMPRESSION="${COMPRESSION:-xz}"
            fi
        fi
    fi

    # --------------------------------------------------
    # 3. CONFIRM PARAMETERS (ALWAYS ask for confirmation)
    # --------------------------------------------------
    echo
    info "Detected parameters:"
    info "  - Offset: $(bold "${OFFSET:-<not set>}")"
    info "  - Compression: $(bold "${COMPRESSION:-<not set>}")"
    info "  - Block Size: $(bold "${BLOCK_SIZE:-<not set>}")"

    read -p "Confirm Block Size (press Enter to accept ${BLOCK_SIZE:-262144}) or enter a new one: " USER_BLOCK_SIZE
    if [[ -n "$USER_BLOCK_SIZE" ]]; then
        BLOCK_SIZE="$USER_BLOCK_SIZE"
    fi
    BLOCK_SIZE="${BLOCK_SIZE:-262144}"
    info "Block Size confirmed: $(bold "$BLOCK_SIZE")"

    # --------------------------------------------------
    # 4. RECONSTRUCTION of new SquashFS filesystem
    # --------------------------------------------------
    local NEW_SQUASHFS="$WORKDIR/NEW.squashfs"
    info "Reconstructing filesystem with new data..."
    mksquashfs "$ROOTFS_DIR" "$NEW_SQUASHFS" -comp "$COMPRESSION" -b "$BLOCK_SIZE" -noappend
    if [[ $? -ne 0 ]]; then
        error "Creation of $NEW_SQUASHFS failed."
        exit 1
    fi
    success "Filesystem recreated: $(bold "$NEW_SQUASHFS")"

    # --------------------------------------------------
    # 5. REPLACEMENT in original firmware
    # --------------------------------------------------
    info "Creating patched firmware: $(bold "$OUTPUT_FILE")..."
    cp "$ORIG_FW" "$OUTPUT_FILE"
    dd if="$NEW_SQUASHFS" of="$OUTPUT_FILE" bs=1 seek="$OFFSET" conv=notrunc 2>/dev/null
    if [[ $? -ne 0 ]]; then
        error "SquashFS block replacement failed."
        exit 1
    fi
    success "Patched firmware created successfully."

    # --------------------------------------------------
    # 6. CLEANUP and STRIPPING OPTION
    # --------------------------------------------------
    rm -f "$NEW_SQUASHFS"
    info "Temporary files removed."

    # Always create stripped version
    local STRIPPED_FILE
    STRIPPED_FILE=$(get_stripped_filename "$OUTPUT_FILE")
    info "Creating stripped firmware: $STRIPPED_FILE (skip 512 bytes)..."
    dd if="$OUTPUT_FILE" of="$STRIPPED_FILE" skip=1 bs=512 2>/dev/null || true
    success "Stripped firmware created: $(bold "$STRIPPED_FILE")"

    # --------------------------------------------------
    # 7. FINAL VERIFICATION
    # --------------------------------------------------
    echo
    bold "========================================"
    success "Operation completed!"
    info "Main patched firmware: $(bold "$OUTPUT_FILE")"
    info "Stripped firmware: $(bold "$STRIPPED_FILE")"
    info "To verify, run: $BINWALK_CMD $(bold "$OUTPUT_FILE")"
    warning "Before flashing, remember:"
    echo "  1. The firmware may have integrity checks."
    echo "  2. Try flashing an older official version to test acceptance."
    echo "  3. Look for exploits to bypass validation or use TFTP mode."
    bold "========================================"

    # Cleanup
    cleanup_workdir
}

# Run main function
main "$@"
