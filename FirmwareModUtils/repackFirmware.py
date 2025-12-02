#!/usr/bin/env python3
"""
repackFirmware.py
Ricompatta firmware TP-Link preservando rootfs, device nodes e tmpfs critici.
"""

import os, sys, struct, zlib, subprocess, shutil
from pathlib import Path

# ------------------------------#
# Funzioni colore terminale
# ------------------------------#
def cprint(text, color="white"):
    colors = {
        "red": "\033[91m", "green": "\033[92m",
        "yellow": "\033[93m", "blue": "\033[94m",
        "cyan": "\033[96m", "white": "\033[0m"
    }
    end = "\033[0m"
    print(f"{colors.get(color,'')}{text}{end}")

# ------------------------------#
# Parametri input/output
# ------------------------------#
if len(sys.argv) != 2:
    cprint(f"Uso: {sys.argv[0]} <firmware_originale.bin>", "red")
    sys.exit(1)

firmware_path = Path(sys.argv[1])
if not firmware_path.is_file():
    cprint(f"Errore: file {firmware_path} inesistente", "red")
    sys.exit(1)

rootfs_dir = Path("./fmk/rootfs")
if not rootfs_dir.is_dir():
    cprint(f"Errore: directory {rootfs_dir} non trovata", "red")
    sys.exit(1)

output_path = Path(f"{firmware_path.stem}-repacked.bin")
backup_path = Path(f"{firmware_path.name}.bak")

# Backup firmware originale
if not backup_path.exists():
    shutil.copy2(firmware_path, backup_path)
    cprint(f"[+] Backup creato: {backup_path}", "green")

# Carica firmware originale
firmware = bytearray(firmware_path.read_bytes())
firmware_len = len(firmware)
cprint(f"[*] Firmware originale caricato ({firmware_len} bytes)", "cyan")

# ------------------------------#
# Rilevamento HDR0
# ------------------------------#
hdr0_present = firmware[:4] == b'HDR0'
if hdr0_present:
    cprint("[+] Header TP-Link HDR0 rilevato", "green")
else:
    cprint("[*] Firmware senza HDR0, HDR0 fix ignorato", "yellow")

# ------------------------------#
# Rilevamento partizione SquashFS
# ------------------------------#
SQUASH_MAGIC = b"hsqs"
offset = firmware.find(SQUASH_MAGIC)
if offset == -1:
    cprint("Errore: partizione SquashFS non trovata", "red")
    sys.exit(1)

next_offset = firmware.find(b"hsqs", offset + 4)
if next_offset == -1:
    next_offset = firmware_len
orig_rootfs_size = next_offset - offset
cprint(f"[+] SquashFS rilevato: offset={offset} size_approx={orig_rootfs_size}", "green")

# ------------------------------#
# Preservazione device nodes e tmpfs
# ------------------------------#
dev_dir = rootfs_dir / "dev"
dev_dir.mkdir(parents=True, exist_ok=True)
tmp_dirs = ["tmp", "var/run", "var/lock", "dev/shm", "dev/pts"]
for d in tmp_dirs:
    p = rootfs_dir / d
    p.mkdir(parents=True, exist_ok=True)
    os.chmod(p, 0o1777 if d in ["tmp", "dev/shm"] else 0o755)

# Copia device nodes dall’originale (solo char/block/socket/fifo)
for entry in Path("/dev").iterdir():
    if entry.is_char_device() or entry.is_block_device() or entry.is_socket() or entry.is_fifo():
        dest = dev_dir / entry.name
        if not dest.exists():
            try:
                mode = entry.stat().st_mode
                major = os.major(entry.stat().st_rdev)
                minor = os.minor(entry.stat().st_rdev)
                os.mknod(dest, mode, os.makedev(major, minor))
            except PermissionError:
                cprint(f"[!] Impossibile creare {dest}, esegui come root", "yellow")
cprint("[+] Device nodes e tmpfs preservati nel rootfs", "green")

# ------------------------------#
# Patch specifica per httpd e NVRAM
# ------------------------------#
cprint("[*] Applico patch per NVRAM e shared memory...", "cyan")

# Copia libnvram-faker.so in /firmadyne/libnvram.so (per compatibilità Firmadyne/FAT)
libnvram_src = Path("libnvram-faker.so")  # Cambia se in altro percorso
if libnvram_src.exists():
    firmadyne_dir = rootfs_dir / "firmadyne"
    firmadyne_dir.mkdir(parents=True, exist_ok=True)
    lib_dest = firmadyne_dir / "libnvram.so"
    shutil.copy2(libnvram_src, lib_dest)
    cprint(f"[+] Copiata {libnvram_src} in {lib_dest}", "green")
else:
    cprint("[!] libnvram-faker.so non trovato – copio originale nel rootfs", "yellow")
    firmadyne_dir = rootfs_dir / "firmadyne"
    firmadyne_dir.mkdir(parents=True, exist_ok=True)
    lib_dest = firmadyne_dir / "libnvram.so"
    shutil.copy2(Path("./firmware-analysis-toolkit/firmadyne/binaries/libnvram.so.mipsel"), lib_dest)
    cprint(f"[+] Copiata {libnvram_src} in {lib_dest}", "green")


# Crea /firmadyne/libnvram.override con valori minimi obbligatori
override_path = firmadyne_dir / "libnvram.override"
overrides = [
    "lan_ipaddr=192.168.0.1",
    "lan_netmask=255.255.255.0",
    "wan_proto=dhcp",
    "http_username=admin",
    "http_passwd=admin",
    "wl0_ssid=TP-LINK_XXXX",
    "modelName=TL-WR841N",
    "hw_ver=14.0"
]
override_path.write_text("\n".join(overrides) + "\n")
cprint(f"[+] Creato {override_path} con valori NVRAM di default", "green")

# Riscrivi rcS da zero con patch per /dev/shm e shmmax
rcs_path = rootfs_dir / "etc" / "init.d" / "rcS"
new_rcs_content = """#!/bin/sh

# --- Preparazione directory temporanee sul rootfs emulato ---
mkdir -p /var/tmp /var/run /var/dev /var/l2tp /var/tmp/wsc_upnp
mkdir -p /var/tmp/dropbear
mkdir -p /var/Wireless/RT2860AP
cp -f /etc/SingleSKU_FCC.dat /var/Wireless/RT2860AP/SingleSKU.dat 2>/dev/null
cp -f /etc/passwd.bak /var/passwd 2>/dev/null

# --- Configura loopback ---
ifconfig lo 127.0.0.1 netmask 255.0.0.0 up

# --- Configura interfacce emulabili ---
ifconfig eth0 192.168.0.2 netmask 255.255.255.0 up
# Default route via eth0
route add default gw 192.168.0.1

# --- Avvio servizi “userland” sicuri ---
# qui puoi avviare httpd, dropbear o altre utility userland
# ad esempio:
# /usr/sbin/httpd -p 8080 /web &

# Lancia shell interattiva per debug
/bin/sh

"""
rcs_path.write_text(new_rcs_content)
cprint(f"[+] rcS riscritto da zero con patch NVRAM/SHM", "green")

# ------------------------------#
# Genera nuovo SquashFS
# ------------------------------#
tmp_sqfs_path = Path("./tmp_rootfs.sqfs")
cprint("[*] Creo nuova immagine SquashFS...", "cyan")
subprocess.run([
    "mksquashfs", str(rootfs_dir), str(tmp_sqfs_path),
    "-comp", "xz", "-noappend"
], check=True)
new_rootfs_bytes = tmp_sqfs_path.read_bytes()
tmp_sqfs_path.unlink()
new_rootfs_size = len(new_rootfs_bytes)
cprint(f"[+] Nuova rootfs: {new_rootfs_size} bytes", "green")

# ------------------------------#
# Creazione nuovo firmware
# ------------------------------#
shutil.copy2(firmware_path, output_path)
firmware = bytearray(output_path.read_bytes())
end_offset = offset + new_rootfs_size
if end_offset > len(firmware):
    firmware.extend(b'\xFF' * (end_offset - len(firmware)))
firmware[offset:end_offset] = new_rootfs_bytes
cprint(f"[+] Rootfs scritta in offset {offset}", "green")

# ------------------------------#
# Aggiornamento HDR0
# ------------------------------#
if hdr0_present:
    struct.pack_into("<I", firmware, 0x14, len(firmware))
    payload_crc = zlib.crc32(firmware[0x200:]) & 0xFFFFFFFF
    struct.pack_into("<I", firmware, 0x1FC, payload_crc)
    header_crc = zlib.crc32(firmware[:0x1F8]) & 0xFFFFFFFF
    struct.pack_into("<I", firmware, 0x1F8, header_crc)
    cprint(f"[+] HDR0 aggiornato: payload_crc=0x{payload_crc:08X} header_crc=0x{header_crc:08X}", "green")

# ------------------------------#
# Salvataggio finale
# ------------------------------#
output_path.write_bytes(firmware)
cprint(f"[✓] Firmware ricostruito: {output_path}", "green")
cprint(f"[✓] Firmware originale intatto: {firmware_path}", "cyan")
