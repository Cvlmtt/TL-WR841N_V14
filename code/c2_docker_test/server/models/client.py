import time
import threading
import socket


class Client:
    def __init__(self, cmd_socket, stream_socket, address, hostname, last_seen,
                 unique_id=None, heartbeat_port=4445):
        self.cmd_socket = cmd_socket
        self.address = address
        self.ip, self.cmd_port = address
        self.hostname = hostname
        self.last_seen = last_seen
        self.unique_id = unique_id
        self.heartbeat_port = heartbeat_port
        self.stream_socket = stream_socket
        self.first_seen = time.time()
        self.note = ""

        self.active = True
        self.lock = threading.Lock()

    def set_time(self, new_time):
        # Il chiamante deve già avere il lock se necessario
        self.last_seen = new_time

    def close(self):
        with self.lock:
            if not self.active:
                return
            self.active = False
            cmd_sock = self.cmd_socket
            stream_sock = self.stream_socket

        # Chiudi fuori dal lock
        for s in [cmd_sock, stream_sock, getattr(self, 'socket', None)]:
            if s:
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except:
                    pass
                try:
                    s.close()
                except:
                    pass

    def update_connection(self, new_socket, new_address, new_heartbeat_port=None):
        old_socket = None
        with self.lock:
            old_socket = self.cmd_socket
            self.cmd_socket = new_socket
            self.cmd_socket = new_socket
            self.address = new_address
            self.ip, self.cmd_port = new_address
            if new_heartbeat_port is not None:
                self.heartbeat_port = new_heartbeat_port
            self.active = True
            self.last_seen = time.time()

        try:
            old_socket.close()
        except:
            pass
