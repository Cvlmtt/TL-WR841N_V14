import time
import threading

from models.client import Client
from server_core.handlers.handle_command import handle_command
from server_core.handlers.handle_stream import handle_stream



def handle_client(server, cmd_socket, cmd_address, stream_socket, stream_address):
    ip, cmd_port = cmd_address
    client_id = f"{ip}:{cmd_port}"
    client_obj = None

    try:
        server.log(f"[+] Incoming connection from {client_id}")
        cmd_socket.settimeout(10.0)

        # handshake
        data = cmd_socket.recv(1024).decode(errors='ignore').strip()
        if not data.startswith("HELLO|"):
            server.log(f"[-] Bad handshake from {client_id}")
            return

        parts = data.split('|')
        if len(parts) < 4:
            server.log(f"[-] Malformed handshake from {client_id}")
            return

        hostname = parts[1]
        unique_id = parts[3]
        heartbeat_port = server.heartbeat_port

        if len(parts) >= 5:
            try:
                heartbeat_port = int(parts[4])
            except:
                pass

        if len(unique_id) != 32:
            cmd_socket.send(b"ERROR: Invalid client ID\n")
            return

        # registra o aggiorna client
        with server.lock:
            existing = server.clients.get(unique_id)

        if existing:
            with existing.lock:
                if existing.active:
                    server.log(f"[!] Duplicate active client {unique_id[:8]}...")
                    cmd_socket.send(b"ERROR: Duplicate connection\n")
                    return

            existing.update_connection(cmd_socket, cmd_address, heartbeat_port)
            with existing.lock:
                existing.hostname = hostname
            client_obj = existing
            server.log(f"[*] Client reconnected {unique_id[:8]}...")
        else:
            client_obj = Client(
                cmd_socket, stream_socket, cmd_address, hostname,
                time.time(), unique_id, heartbeat_port
            )
            with server.lock:
                server.clients[unique_id] = client_obj
            server.log(f"[+] Registered new client {unique_id[:8]}...")

        with client_obj.lock:
            client_obj.cmd_socket.send(b"READY\n")

        # Imposta stream non bloccante
        stream_socket.setblocking(False)

        c = threading.Thread(
            target=handle_command,
            args=(server, client_obj),
            daemon=True
        )
        c.start()

        s = threading.Thread(
            target=handle_stream,
            args=(server, client_obj),
            daemon=True
        )
        s.start()

        c.join()
        s.join()

    finally:
        if client_obj:
            client_obj.close()
        server.log(f"[-] Connection closed for {client_id}")
