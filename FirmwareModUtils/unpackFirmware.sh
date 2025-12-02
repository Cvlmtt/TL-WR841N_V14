#!/bin/bash


FIRMWARE_PATH="$1"
if [ -z "$FIRMWARE_PATH" ]; then
echo "Uso: $0 <firmware.bin>"
exit 1
fi

echo "[+] Rimuovo eventuale directory fmk esistente..."
sudo rm -rf firmware-mod-kit/fmk


echo "[+] Estraggo il firmware tramite firmware-mod-kit..."
cd firmware-mod-kit/
sudo ./extract-firmware.sh "$FIRMWARE_PATH"
cd ..

echo "[+] Creo link simbolico alla directory fmk nella directory principale..."
ln -s firmware-mod-kit/fmk ./fmk


echo "[+] Unpack completato. Ora puoi modificare i file in fmk/rootfs/"
