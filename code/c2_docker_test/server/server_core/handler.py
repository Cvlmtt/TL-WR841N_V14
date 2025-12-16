import time
import socket
from models.client import Client


def handle_client(server, client_socket, address):
    ip, port = address
    client_id = f"{ip}:{port}"
    client_obj = None

    try:
        server.log(f"[+] Incoming connection from {client_id}")
        client_socket.settimeout(10.0)

        data = client_socket.recv(1024).decode().strip()
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
            client_socket.send(b"ERROR: Invalid client ID\n")
            return

        with server.lock:
            existing = server.clients.get(unique_id)

        if existing:
            with existing.lock:
                if existing.active:
                    server.log(f"[!] Duplicate active client {unique_id[:8]}...")
                    client_socket.send(b"ERROR: Duplicate connection\n")
                    return

            existing.update_connection(client_socket, address, heartbeat_port)
            with existing.lock:
                existing.hostname = hostname
            client_obj = existing
            server.log(f"[*] Client reconnected {unique_id[:8]}...")

        else:
            client_obj = Client(
                client_socket, address, hostname,
                time.time(), unique_id, heartbeat_port
            )
            with server.lock:
                server.clients[unique_id] = client_obj
            server.log(f"[+] Registered new client {unique_id[:8]}...")

        with client_obj.lock:
            client_obj.socket.send(b"READY\n")

        client_obj.socket.settimeout(1.0)

        while server.running:
            with client_obj.lock:
                if not client_obj.active:
                    break
                sock = client_obj.socket

            try:
                data = sock.recv(8192)
                if not data:
                    break

                output = data.decode(errors='ignore').rstrip()
                server.log(f"[{client_obj.unique_id[:8]}...] {output[:200]}")
                client_obj.set_time(time.time())

            except socket.timeout:
                continue
            except Exception:
                break

    finally:
        if client_obj:
            client_obj.close()
        try:
            client_socket.close()
        except:
            pass
        server.log(f"[-] Connection closed {client_id}")
