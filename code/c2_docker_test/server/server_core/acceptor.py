import threading
from server_core.handlers.handler import handle_client


def accept_loop(server, server_socket, stream_socket):
    while server.running:
        try:
            stream_sock, stream_addr = stream_socket.accept()
            cmd_sock, cmd_addr = server_socket.accept()
            t = threading.Thread(
                target=handle_client,
                args=(server, cmd_sock, cmd_addr, stream_sock, stream_addr),
                daemon=True
            )
            t.start()
        except:
            break
