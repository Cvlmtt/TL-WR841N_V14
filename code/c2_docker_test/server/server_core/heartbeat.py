import socket
import time


def heartbeat_sender(server):
    hb_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.log(f"[*] Heartbeat thread started (interval {server.heartbeat_interval}s)")

    while server.running:
        try:
            with server.lock:
                snapshot = list(server.clients.values())

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
                    server.log(f"[!] Heartbeat failed to {ip}:{port} ({client.unique_id[:8]}...): {e}")
                    failed.append(client)

            for client in failed:
                client.close()

            time.sleep(server.heartbeat_interval)

        except Exception as e:
            server.log(f"[!] Heartbeat thread error: {e}")
            time.sleep(5)

    hb_socket.close()
    server.log("[*] Heartbeat thread exiting")
