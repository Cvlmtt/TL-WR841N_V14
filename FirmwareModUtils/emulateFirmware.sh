#!/bin/zsh

NEWFIRM="$1"

if [ -z "$NEWFIRM" ]; then
    echo "Uso: $0 <firmware_modificato.bin>"
    exit 1
fi

# Converte in path assoluto
NEWFIRM_ABS=$(realpath "$NEWFIRM")
if [ ! -f "$NEWFIRM_ABS" ]; then
    echo "ERRORE: file firmware non trovato: $NEWFIRM_ABS"
    exit 1
fi

echo "[+] Resetto FAT..."
cd firmware-analysis-toolkit || {
    echo "ERRORE: directory firmware-analysis-toolkit non trovata!"
    exit 1
}

sudo ./reset.py

echo "[+] Avvio emulazione con FAT..."
sudo ./fat.py "$NEWFIRM_ABS"
