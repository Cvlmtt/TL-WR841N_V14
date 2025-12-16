import threading
from server_core.handler import handle_client


def accept_loop(server, server_socket):
    while server.running:
        try:
            sock, addr = server_socket.accept()
            t = threading.Thread(
                target=handle_client,
                args=(server, sock, addr),
                daemon=True
            )
            t.start()
        except:
            break
