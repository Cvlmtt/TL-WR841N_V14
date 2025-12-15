class Client:
    def __init__(self, socket, address, hostname, last_seen):
        self.socket = socket
        self.address = address
        self.hostname = hostname
        self.last_seen = last_seen
        self.ip, self.port = address


    def set_time(self, last_seen):
        self.last_seen = last_seen