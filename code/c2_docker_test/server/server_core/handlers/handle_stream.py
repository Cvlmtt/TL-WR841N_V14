import time
import socket
import select
import errno

STREAM_HDR_SIZE = 4  # dimensione header 4 byte per lo stream

def recv_exact(sock, n):
    data = b''
    while len(data) < n:
        try:
            chunk = sock.recv(n - len(data))
            if not chunk:
                return None  # Connection closed
            data += chunk
        except (BlockingIOError, socket.error) as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                # Wait for data to be available
                select.select([sock], [], [])
                continue
            raise
    return data

def handle_stream(server, client_obj):
    while server.running:
        with client_obj.lock:
            if not client_obj.active:
                break
            stream_sock = client_obj.stream_socket

        try:
            # Check if readable with a small timeout to avoid busy loop
            ready, _, _ = select.select([stream_sock], [], [], 0.5)
            if not ready:
                continue

            # Read header
            hdr = recv_exact(stream_sock, STREAM_HDR_SIZE)
            if hdr is None:
                server.log(f"[-] Stream socket closed by client {client_obj.unique_id[:8]}")
                break

            length = int.from_bytes(hdr, "big")
            if length == 0:
                continue

            # Read payload
            payload = recv_exact(stream_sock, length)
            if payload is None:
                server.log(f"[-] Stream socket closed during payload by client {client_obj.unique_id[:8]}")
                break

            if payload:
                # server.log(f"Logging to file")
                # scrivi pacchetto in append
                with open(f'/tmp/{client_obj.unique_id}.pcap', "ab") as pcap_file:
                    pcap_file.write(payload)
                # server.log(f"Closing pcap file")

        except (socket.error, OSError) as e:
            # Ignore EAGAIN if it bubbles up (though recv_exact handles it)
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                continue
            server.log(f"[!] Socket error with {client_obj.unique_id[:8]}: {e}")
            break
        except Exception as e:
            server.log(f"[!] Unexpected error in client loop {client_obj.unique_id[:8]}: {e}")
            break
