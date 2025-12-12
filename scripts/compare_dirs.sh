#!/bin/bash

# Script: diff_dirs.sh
# Uso: ./diff_dirs.sh <dir1> <dir2>

set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <directory1> <directory2>"
    echo "Example: $0 /path/to/firmware1 /path/to/firmware2"
    exit 1
fi

DIR1="$1"
DIR2="$2"

if [ ! -d "$DIR1" ]; then
    echo "Error: $DIR1 is not a directory"
    exit 1
fi

if [ ! -d "$DIR2" ]; then
    echo "Error: $DIR2 is not a directory"
    exit 1
fi

echo "=========================================="
echo "Comparing directories:"
echo "DIR1: $DIR1"
echo "DIR2: $DIR2"
echo "=========================================="
echo

# 1. Trova file presenti solo in DIR1
echo "=== Files only in $DIR1 ==="
find "$DIR1" -type f | sed "s|^$DIR1/||" | sort > /tmp/dir1_files.txt
find "$DIR2" -type f | sed "s|^$DIR2/||" | sort > /tmp/dir2_files.txt
comm -23 /tmp/dir1_files.txt /tmp/dir2_files.txt | while read file; do
    echo "  ONLY in DIR1: $file"
done
echo

# 2. Trova file presenti solo in DIR2
echo "=== Files only in $DIR2 ==="
comm -13 /tmp/dir1_files.txt /tmp/dir2_files.txt | while read file; do
    echo "  ONLY in DIR2: $file"
done
echo

# 3. Confronta file comuni
echo "=== Comparing common files ==="
comm -12 /tmp/dir1_files.txt /tmp/dir2_files.txt > /tmp/common_files.txt
TOTAL_FILES=$(wc -l < /tmp/common_files.txt)
COUNT=0
DIFF_FOUND=0

while read file; do
    COUNT=$((COUNT + 1))
    FILE1="$DIR1/$file"
    FILE2="$DIR2/$file"
    
    # Controlla se entrambi i file esistono
    if [ ! -f "$FILE1" ] || [ ! -f "$FILE2" ]; then
        continue
    fi
    
    # Controlla se sono file di testo o binari
    if file "$FILE1" | grep -q "text"; then
        # File di testo
        if ! cmp -s "$FILE1" "$FILE2"; then
            DIFF_FOUND=1
            echo "=========================================="
            echo "[$COUNT/$TOTAL_FILES] DIFF in: $file"
            echo "------------------------------------------"
            
            # Calcola dimensioni
            SIZE1=$(stat -c%s "$FILE1")
            SIZE2=$(stat -c%s "$FILE2")
            echo "Sizes: DIR1: $SIZE1 bytes, DIR2: $SIZE2 bytes"
            
            # Se le dimensioni sono diverse o se si tratta di file piccoli, mostra il diff
            if [ "$SIZE1" -ne "$SIZE2" ] || [ "$SIZE1" -lt 10000 ]; then
                # Mostra diff con contesto
                diff -u "$FILE1" "$FILE2" | head -50
                if [ $(diff -u "$FILE1" "$FILE2" | wc -l) -gt 50 ]; then
                    echo "... (output truncated, diff too long)"
                fi
            else
                echo "Files are text but large, showing first difference only:"
                diff -u "$FILE1" "$FILE2" | head -20
            fi
            echo
        fi
    else
        # File binario - confronta hash
        HASH1=$(md5sum "$FILE1" | cut -d' ' -f1)
        HASH2=$(md5sum "$FILE2" | cut -d' ' -f1)
        
        if [ "$HASH1" != "$HASH2" ]; then
            DIFF_FOUND=1
            echo "=========================================="
            echo "[$COUNT/$TOTAL_FILES] BINARY DIFF in: $file"
            echo "------------------------------------------"
            echo "MD5: DIR1: $HASH1, DIR2: $HASH2"
            SIZE1=$(stat -c%s "$FILE1")
            SIZE2=$(stat -c%s "$FILE2")
            echo "Sizes: DIR1: $SIZE1 bytes, DIR2: $SIZE2 bytes"
            
            # Per file binari piccoli, mostra differenze in esadecimale
            if [ "$SIZE1" -lt 100000 ] && [ "$SIZE1" -eq "$SIZE2" ]; then
                echo "Hex dump of first difference:"
                cmp -l "$FILE1" "$FILE2" | head -10
            fi
            echo
        fi
    fi
    
    # Mostra progresso
    if [ $((COUNT % 100)) -eq 0 ]; then
        echo "Progress: $COUNT/$TOTAL_FILES files checked..."
    fi
done < /tmp/common_files.txt

# 4. Controlla differenze in permessi e proprietà
echo "=== Checking permissions and ownership ==="
while read file; do
    FILE1="$DIR1/$file"
    FILE2="$DIR2/$file"
    
    if [ -f "$FILE1" ] && [ -f "$FILE2" ]; then
        PERM1=$(stat -c "%A %U %G" "$FILE1" 2>/dev/null || echo "N/A")
        PERM2=$(stat -c "%A %U %G" "$FILE2" 2>/dev/null || echo "N/A")
        
        if [ "$PERM1" != "$PERM2" ]; then
            echo "Permissions differ for: $file"
            echo "  DIR1: $PERM1"
            echo "  DIR2: $PERM2"
        fi
    fi
done < /tmp/common_files.txt | head -20

# 5. Riepilogo
echo
echo "=========================================="
echo "SUMMARY"
echo "=========================================="
ONLY_DIR1=$(comm -23 /tmp/dir1_files.txt /tmp/dir2_files.txt | wc -l)
ONLY_DIR2=$(comm -13 /tmp/dir1_files.txt /tmp/dir2_files.txt | wc -l)
TOTAL_DIR1=$(wc -l < /tmp/dir1_files.txt)
TOTAL_DIR2=$(wc -l < /tmp/dir2_files.txt)

echo "Total files in DIR1: $TOTAL_DIR1"
echo "Total files in DIR2: $TOTAL_DIR2"
echo "Files only in DIR1: $ONLY_DIR1"
echo "Files only in DIR2: $ONLY_DIR2"
echo "Common files: $TOTAL_FILES"

if [ $DIFF_FOUND -eq 0 ]; then
    echo "No differences found in common files!"
else
    echo "Differences found in common files (see above for details)"
fi

# 6. File critici da controllare per firmware
echo
echo "=========================================="
echo "Checking critical firmware files:"
echo "=========================================="

CRITICAL_FILES="etc/init.d/rcS etc/fstab etc/inittab etc/passwd etc/shadow etc/config/network etc/config/system"
for critfile in $CRITICAL_FILES; do
    if [ -f "$DIR1/$critfile" ] || [ -f "$DIR2/$critfile" ]; then
        echo
        echo "--- $critfile ---"
        if [ -f "$DIR1/$critfile" ] && [ -f "$DIR2/$critfile" ]; then
            if cmp -s "$DIR1/$critfile" "$DIR2/$critfile"; then
                echo "  No differences"
            else
                echo "  DIFFERENCES FOUND:"
                diff -u "$DIR1/$critfile" "$DIR2/$critfile" | head -30
            fi
        elif [ -f "$DIR1/$critfile" ]; then
            echo "  Only in DIR1"
        else
            echo "  Only in DIR2"
        fi
    fi
done

# 7. Controlla dimensioni totali
echo
echo "=========================================="
echo "Directory sizes:"
echo "=========================================="
du -sh "$DIR1" "$DIR2"

# Pulizia
rm -f /tmp/dir1_files.txt /tmp/dir2_files.txt /tmp/common_files.txt

echo
echo "Comparison complete!"
