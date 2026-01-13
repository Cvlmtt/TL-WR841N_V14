import socket
import time


def handle_command(server, client_obj):
    # loop principale: comandi + stream
    while server.running:
        with client_obj.lock:
            if not client_obj.active:
                break
            cmd_sock = client_obj.cmd_socket

        try:
            # -------------------------
            # 1) Legge i comandi
            # -------------------------
            data = cmd_sock.recv(8192)
            if not data:
                server.log(f"[-] Client {client_obj.unique_id[:8]}... disconnected gracefully.")
                break

            output = data.decode(errors='ignore').rstrip()

            # Format output for RichLog
            log_message = (
                f"[b]Response from {client_obj.unique_id[:8]}[/b] ({client_obj.ip}):\n"
                f"```\n"
                f"{output}\n"
                f"```"
            )
            server.log(log_message)

            with client_obj.lock:
                client_obj.set_time(time.time())

        except socket.timeout:
            continue

        except (socket.error, OSError) as e:
            server.log(f"[!] Socket error with {client_obj.unique_id[:8]}: {e}")
            break
        except Exception as e:
            server.log(f"[!] Unexpected error in client loop {client_obj.unique_id[:8]}: {e}")
            break