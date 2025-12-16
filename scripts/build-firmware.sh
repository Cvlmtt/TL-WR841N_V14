#!/usr/bin/env bash
# ============================================
# TP-Link Firmware Patching Tool - SIMPLIFIED
# ============================================

set -euo pipefail

# --- CONSTANTS ---
FINAL_FW_SIZE=4063744
TARGET_SQFS_SIZE=3002156
DEFAULT_BLOCK_SIZE=1048576 #262144

# --- COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[*]${NC} $1"; }
success() { echo -e "${GREEN}[+]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[-]${NC} $1"; }
bold()    { echo -e "${BOLD}$1${NC}"; }

# --- ARGS ---
STRICT=0
ORIG_FW=""
ROOTFS_DIR=""
OUTPUT_FILE=""
WORKDIR="/tmp/rebuild"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--firmware) ORIG_FW="$2"; shift 2 ;;
        -r|--rootfs) ROOTFS_DIR="$2"; shift 2 ;;
        -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
        --strict) STRICT=1; shift ;;
        -h|--help)
            echo "Usage: $0 -f firmware.bin -r rootfs/ -o out.bin [--strict]"
            exit 0
            ;;
        *) error "Unknown option $1"; exit 1 ;;
    esac
done

[[ -f "$ORIG_FW" ]] || error "Firmware not found" || exit 1
[[ -d "$ROOTFS_DIR" ]] || error "Rootfs dir not found" || exit 1

mkdir -p "$WORKDIR"

# --- BINWALK ---
BINWALK_CMD=$(command -v binwalk || command -v binwalk3)

bold "========================================"
bold " Binwalk analysis"
bold "========================================"
$BINWALK_CMD "$ORIG_FW"
echo

read -r -p "Enter SquashFS OFFSET (decimal or 0xhex): " OFFSET
[[ $OFFSET == 0x* ]] && OFFSET=$((OFFSET))

read -r -p "Block size [default ${DEFAULT_BLOCK_SIZE}]: " BLOCK_SIZE
BLOCK_SIZE="${BLOCK_SIZE:-$DEFAULT_BLOCK_SIZE}"

info "Using block size: $BLOCK_SIZE"

# --- CREATE SQUASHFS ---
NEW_SQFS="$WORKDIR/new.squashfs"
info "Creating SquashFS..."
mksquashfs "$ROOTFS_DIR" "$NEW_SQFS" -comp xz -Xdict-size 100% -b "$BLOCK_SIZE" -noappend >/dev/null

NEW_SQFS_SIZE=$(stat -c%s "$NEW_SQFS")
info "New SquashFS size: $NEW_SQFS_SIZE bytes"

# --- PAD SQUASHFS TO TARGET ---
if (( NEW_SQFS_SIZE < TARGET_SQFS_SIZE )); then
    PAD=$(( TARGET_SQFS_SIZE - NEW_SQFS_SIZE ))
    info "Padding SquashFS with $PAD bytes (0xFF)..."
    printf '\377%.0s' $(seq 1 "$PAD") >> "$NEW_SQFS"
    NEW_SQFS_SIZE=$TARGET_SQFS_SIZE
elif (( NEW_SQFS_SIZE > TARGET_SQFS_SIZE )); then
    echo -e "${RED}[-] WARNING:${NC} SquashFS exceeds target by $((NEW_SQFS_SIZE - TARGET_SQFS_SIZE)) bytes"
fi

# --- BUILD FIRMWARE ---
info "Building firmware..."
dd if="$ORIG_FW" of="$OUTPUT_FILE" bs=1 count="$OFFSET" 2>/dev/null
dd if="$NEW_SQFS" of="$OUTPUT_FILE" bs=1 seek="$OFFSET" conv=notrunc 2>/dev/null

CURRENT_SIZE=$(( OFFSET + NEW_SQFS_SIZE ))

if (( CURRENT_SIZE < FINAL_FW_SIZE )); then
    PAD=$(( FINAL_FW_SIZE - CURRENT_SIZE ))
    info "Adding final padding: $PAD bytes (0xFF)..."
    printf '\377%.0s' $(seq 1 "$PAD") >> "$OUTPUT_FILE"
fi

truncate -s "$FINAL_FW_SIZE" "$OUTPUT_FILE"

# --- CREATE STRIPPED VERSION (512 bytes) ---
STRIPPED_FILE="${OUTPUT_FILE%.bin}-stripped.bin"

info "Creating stripped firmware (removing first 512 bytes)..."

if (( FINAL_FW_SIZE > 512 )); then
    dd if="$OUTPUT_FILE" of="$STRIPPED_FILE" bs=1 skip=512 2>/dev/null
    success "Stripped firmware created: $STRIPPED_FILE"
    info "Stripped firmware size: $(stat -c%s "$STRIPPED_FILE") bytes"
else
    warning "Firmware too small to create stripped version."
fi

# --- FINAL CHECKS ---
FINAL_SIZE=$(stat -c%s "$OUTPUT_FILE")

bold "========================================"
info "FINAL CHECK"
info "SquashFS size: $NEW_SQFS_SIZE (target $TARGET_SQFS_SIZE)"
info "Firmware size: $FINAL_SIZE (target $FINAL_FW_SIZE)"

if (( NEW_SQFS_SIZE > TARGET_SQFS_SIZE )); then
    echo -e "${RED}[-] WARNING:${NC} SquashFS size is larger than expected!"
fi

if (( FINAL_SIZE > FINAL_FW_SIZE )); then
    echo -e "${RED}[-] WARNING:${NC} Firmware size is larger than expected!"
fi

success "Firmware created: $OUTPUT_FILE"
bold "========================================"

rm -rf "$WORKDIR"
