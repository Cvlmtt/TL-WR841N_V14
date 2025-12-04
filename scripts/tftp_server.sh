#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script per avviare un server TFTP di laboratorio su Fedora e sniffare il
# traffico con tcpdump, ripristinando l'ambiente al termine.
#
# Uso:
#   ./tftp_server.sh <interfaccia_di_rete> <firmware.bin>
#
# Esempio:
#   ./tftp_server.sh enp3s0 TL-WR841N_v14_0.9.1_4.18_up_boot(190115).bin
###############################################################################

IFACE="${1:-}"
FW_SRC="${2:-}"

if [[ -z "$IFACE" || -z "$FW_SRC" ]]; then
    echo "Uso: $0 <interfaccia_di_rete> <firmware.bin>"
    exit 1
fi

if [[ ! -f "$FW_SRC" ]]; then
    echo "[ERRORE] File firmware non trovato: $FW_SRC"
    exit 1
fi

# Variabili di stato per il ripristino
FIREWALL_TFTP_WAS_ENABLED="no"
FIREWALL_TFTP_CHANGED="no"

SELINUX_MODE=""
SELINUX_CHANGED=0

TFTP_SERVICE_PRESENT_BEFORE=0
TFTP_SERVICE_BACKUP=""
TFTP_SOCKET_PRESENT_BEFORE=0
TFTP_SOCKET_BACKUP=""

TFTP_SOCKET_ENABLED_BEFORE="unknown"
TFTP_SOCKET_ENABLED_CHANGED="no"

# Gestione IP / NetworkManager
USE_NM=0
NM_CONNECTION=""
NM_PREV_IPV4_METHOD=""
NM_PREV_IPV4_ADDRS=""

IPV4_LAB_ADDR="192.168.0.66/24"

# Percorsi unit file
SERVICE_PATH="/etc/systemd/system/tftp.service"
SOCKET_PATH="/etc/systemd/system/tftp.socket"
TFTP_ROOT="/var/lib/tftpboot"

cleanup() {
    local exit_code=$?
    echo
    echo "[INFO] Avvio cleanup (exit code: $exit_code)..."

    # Ripristino IP / NetworkManager
    if (( USE_NM == 1 )) && [[ -n "$NM_CONNECTION" ]]; then
        echo "[INFO] Ripristino configurazione IP NetworkManager per '$NM_CONNECTION'..."
        if [[ -n "$NM_PREV_IPV4_METHOD" ]]; then
            sudo nmcli connection modify "$NM_CONNECTION" ipv4.method "$NM_PREV_IPV4_METHOD"
        fi

        # Ripristino indirizzi
        if [[ -n "$NM_PREV_IPV4_ADDRS" ]]; then
            sudo nmcli connection modify "$NM_CONNECTION" ipv4.addresses "$NM_PREV_IPV4_ADDRS"
        else
            # se prima non c'erano indirizzi (es. metodo 'auto') li svuoto
            sudo nmcli connection modify "$NM_CONNECTION" ipv4.addresses ""
        fi

        sudo nmcli connection up "$NM_CONNECTION" >/dev/null 2>&1 || true
    else
        echo "[INFO] Ripristino IP manuale dell'interfaccia (flush + dhclient se presente)..."
        sudo ip addr flush dev "$IFACE" || true
        if command -v dhclient &>/dev/null; then
            sudo dhclient "$IFACE" || true
        fi
    fi

    # Ripristino SELinux
    if (( SELINUX_CHANGED == 1 )) && [[ -n "${SELINUX_MODE}" ]]; then
        echo "[INFO] Ripristino SELinux allo stato: ${SELINUX_MODE}"
        sudo setenforce "${SELINUX_MODE}" 2>/dev/null || true
    fi

    # Ripristino firewall
    if [[ "${FIREWALL_TFTP_CHANGED}" == "yes" ]] && command -v firewall-cmd &>/dev/null; then
        echo "[INFO] Rimozione eccezione TFTP dal firewall (permanent)..."
        sudo firewall-cmd --remove-service=tftp --permanent >/dev/null 2>&1 || true
        sudo firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    # Ripristino stato di tftp.socket (e tftp.service)
    if [[ "${TFTP_SOCKET_ENABLED_CHANGED}" == "yes" ]]; then
        echo "[INFO] Disabilito e fermo tftp.socket (e tftp.service se attivo)..."
        sudo systemctl disable --now tftp.socket >/dev/null 2>&1 || true
    else
        echo "[INFO] Fermo tftp.socket (se in esecuzione)..."
        sudo systemctl stop tftp.socket >/dev/null 2>&1 || true
    fi

    # Per sicurezza fermo anche il servizio tftp
    sudo systemctl stop tftp.service >/dev/null 2>&1 || true

    # Ripristino / rimozione unit file creati
    if (( TFTP_SERVICE_PRESENT_BEFORE == 0 )); then
        echo "[INFO] Rimuovo ${SERVICE_PATH} creato dallo script..."
        sudo rm -f "${SERVICE_PATH}" >/dev/null 2>&1 || true
    else
        if [[ -n "${TFTP_SERVICE_BACKUP}" && -f "${TFTP_SERVICE_BACKUP}" ]]; then
            echo "[INFO] Ripristino unit file originale ${SERVICE_PATH}..."
            sudo mv -f "${TFTP_SERVICE_BACKUP}" "${SERVICE_PATH}" >/dev/null 2>&1 || true
        fi
    fi

    if (( TFTP_SOCKET_PRESENT_BEFORE == 0 )); then
        echo "[INFO] Rimuovo ${SOCKET_PATH} creato dallo script..."
        sudo rm -f "${SOCKET_PATH}" >/dev/null 2>&1 || true
    else
        if [[ -n "${TFTP_SOCKET_BACKUP}" && -f "${TFTP_SOCKET_BACKUP}" ]]; then
            echo "[INFO] Ripristino unit file originale ${SOCKET_PATH}..."
            sudo mv -f "${TFTP_SOCKET_BACKUP}" "${SOCKET_PATH}" >/dev/null 2>&1 || true
        fi
    fi

    # Ricarico systemd
    sudo systemctl daemon-reload >/dev/null 2>&1 || true

    # Rimozione root TFTP
    echo "[INFO] Rimuovo la cartella ${TFTP_ROOT}..."
    sudo rm -rf "${TFTP_ROOT}" >/dev/null 2>&1 || true

    echo "[INFO] Cleanup completato."
}

trap cleanup EXIT

echo "[INFO] Verifica/Installazione pacchetti necessari..."

PKGS=(tftp-server tftp tcpdump iproute)
MISSING=()

for pkg in "${PKGS[@]}"; do
    if ! rpm -q "${pkg}" &>/dev/null; then
        MISSING+=("${pkg}")
    fi
done

if ((${#MISSING[@]})); then
    echo "[INFO] Installerò i seguenti pacchetti: ${MISSING[*]}"
    sudo dnf install -y "${MISSING[@]}"
else
    echo "[INFO] Tutti i pacchetti richiesti sono già installati."
fi

echo "[INFO] Verifica stato firewall per il servizio TFTP..."
if command -v firewall-cmd &>/dev/null; then
    if sudo firewall-cmd --query-service=tftp --permanent >/dev/null 2>&1; then
        FIREWALL_TFTP_WAS_ENABLED="yes"
        echo "[INFO] Firewall: servizio TFTP già abilitato (permanent)."
    else
        FIREWALL_TFTP_WAS_ENABLED="no"
        echo "[INFO] Firewall: servizio TFTP non abilitato (permanent)."
    fi
else
    echo "[WARN] firewalld non è disponibile. Nessuna modifica al firewall verrà effettuata."
fi

echo "[INFO] Verifica e gestione SELinux..."
if command -v getenforce &>/dev/null; then
    SELINUX_MODE="$(getenforce || echo "Unknown")"
    echo "[INFO] SELinux attuale: ${SELINUX_MODE}"
    if [[ "${SELINUX_MODE}" == "Enforcing" ]]; then
        echo "[INFO] Imposto SELinux temporaneamente in Permissive per il test TFTP..."
        sudo setenforce 0 || true
        SELINUX_CHANGED=1
    fi
else
    echo "[WARN] getenforce non disponibile. Non gestisco SELinux."
fi

echo "[INFO] Gestione unit file systemd per tftp.service/tftp.socket..."

# Backup se esistono già override in /etc/systemd/system
if [[ -f "${SERVICE_PATH}" ]]; then
    TFTP_SERVICE_PRESENT_BEFORE=1
    TFTP_SERVICE_BACKUP="$(mktemp /tmp/tftp.service.bak.XXXXXX)"
    sudo cp "${SERVICE_PATH}" "${TFTP_SERVICE_BACKUP}"
    echo "[INFO] Trovato ${SERVICE_PATH}, backup in ${TFTP_SERVICE_BACKUP}"
fi

if [[ -f "${SOCKET_PATH}" ]]; then
    TFTP_SOCKET_PRESENT_BEFORE=1
    TFTP_SOCKET_BACKUP="$(mktemp /tmp/tftp.socket.bak.XXXXXX)"
    sudo cp "${SOCKET_PATH}" "${TFTP_SOCKET_BACKUP}"
    echo "[INFO] Trovato ${SOCKET_PATH}, backup in ${TFTP_SOCKET_BACKUP}"
fi

# Se non abbiamo override del socket, copio quello di sistema
if (( TFTP_SOCKET_PRESENT_BEFORE == 0 )); then
    if [[ -f /usr/lib/systemd/system/tftp.socket ]]; then
        echo "[INFO] Creo ${SOCKET_PATH} da /usr/lib/systemd/system/tftp.socket..."
        sudo cp /usr/lib/systemd/system/tftp.socket "${SOCKET_PATH}"
    else
        echo "[ERRORE] /usr/lib/systemd/system/tftp.socket non trovato. Esco."
        exit 1
    fi
fi

# Scrivo il service override con la configurazione desiderata
echo "[INFO] Scrivo ${SERVICE_PATH} con la configurazione TFTP custom..."
sudo tee "${SERVICE_PATH}" >/dev/null <<'EOF'
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

# Verifico stato precedente di tftp.socket
if systemctl list-unit-files | grep -q '^tftp.socket'; then
    TFTP_SOCKET_ENABLED_BEFORE="$(systemctl is-enabled tftp.socket 2>/dev/null || echo "disabled")"
    echo "[INFO] Stato precedente di tftp.socket: ${TFTP_SOCKET_ENABLED_BEFORE}"
else
    TFTP_SOCKET_ENABLED_BEFORE="not-installed"
    echo "[INFO] tftp.socket non risultava registrato prima (molto raro)."
fi

echo "[INFO] Ricarico systemd e abilito/avvio tftp.socket..."
sudo systemctl daemon-reload
sudo systemctl enable --now tftp.socket

if [[ "${TFTP_SOCKET_ENABLED_BEFORE}" != "enabled" ]]; then
    TFTP_SOCKET_ENABLED_CHANGED="yes"
fi

echo "[INFO] Creo directory ${TFTP_ROOT} e imposto permessi..."
sudo mkdir -p "${TFTP_ROOT}"
sudo chmod 0777 "${TFTP_ROOT}"

echo "[INFO] Copio il firmware nella root TFTP come tp_recovery.bin..."
sudo cp "$FW_SRC" "${TFTP_ROOT}/tp_recovery.bin"

# Configurazione firewall
if command -v firewall-cmd &>/dev/null; then
    if [[ "${FIREWALL_TFTP_WAS_ENABLED}" == "no" ]]; then
        echo "[INFO] Aggiungo servizio TFTP al firewall (permanent)..."
        sudo firewall-cmd --add-service=tftp --permanent
        FIREWALL_TFTP_CHANGED="yes"
    fi
    echo "[INFO] Ricarico configurazione firewall..."
    sudo firewall-cmd --reload
fi

echo "[INFO] Configurazione IP dell'interfaccia ${IFACE} a ${IPV4_LAB_ADDR}..."

if command -v nmcli &>/dev/null; then
    USE_NM=1
    NM_CONNECTION="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v IFACE="$IFACE" '$2==IFACE{print $1; exit}')"
    if [[ -z "$NM_CONNECTION" ]]; then
        NM_CONNECTION="$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v IFACE="$IFACE" '$2==IFACE{print $1; exit}')"
    fi

    if [[ -z "$NM_CONNECTION" ]]; then
        echo "[WARN] Nessuna connessione NetworkManager trovata per $IFACE, passo a gestione IP manuale."
        USE_NM=0
    else
        echo "[INFO] Connessione NM per $IFACE: $NM_CONNECTION"
        NM_PREV_IPV4_METHOD="$(nmcli -g ipv4.method connection show "$NM_CONNECTION" 2>/dev/null || echo "")"
        NM_PREV_IPV4_ADDRS="$(nmcli -g ipv4.addresses connection show "$NM_CONNECTION" 2>/dev/null || echo "")"

        sudo nmcli connection modify "$NM_CONNECTION" ipv4.method manual ipv4.addresses "$IPV4_LAB_ADDR" ipv4.gateway "" ipv4.dns ""
        sudo nmcli connection up "$NM_CONNECTION"
    fi
fi

if (( USE_NM == 0 )); then
    echo "[INFO] Imposto IP manualmente con iproute2 su ${IFACE}..."
    sudo ip addr flush dev "$IFACE"
    sudo ip addr add "$IPV4_LAB_ADDR" dev "$IFACE"
fi

echo
echo "==============================================================="
echo "[INFO] Server TFTP attivo (socket-activated)."
echo "[INFO] Directory TFTP root: ${TFTP_ROOT}"
echo "[INFO] File servito: tp_recovery.bin"
echo "[INFO] Interfaccia di ascolto tcpdump: ${IFACE}"
echo "[INFO] Per interrompere ed eseguire il cleanup, premi CTRL+C."
echo "==============================================================="
echo

sudo tcpdump -ni "${IFACE}" port 69

