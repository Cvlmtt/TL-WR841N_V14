import time
import socket
import select

STREAM_HDR_SIZE = 4  # dimensione header 4 byte per lo stream

def handle_stream(server, client_obj):
    while server.running:
        with client_obj.lock:
            if not client_obj.active:
                break
            stream_sock = client_obj.stream_socket

        try:
            ready, _, _ = select.select([stream_sock], [], [], 0)
            if ready:
                # legge header 4 byte
                hdr = stream_sock.recv(STREAM_HDR_SIZE)
                if len(hdr) < STREAM_HDR_SIZE:
                    if len(hdr) == 0:
                        server.log(f"[-] Stream socket closed by client {client_obj.unique_id[:8]}")
                        break
                    continue  # dati incompleti, salta questo giro

                length = int.from_bytes(hdr, "big")
                if length == 0:
                    continue

                # legge payload completo
                payload = b''
                while len(payload) < length:
                    chunk = stream_sock.recv(length - len(payload))
                    if not chunk:
                        break
                    payload += chunk

                if payload:
                    server.log(f"Logging to file")
                    # scrivi pacchetto in append
                    with open(f'/tmp/{client_obj.unique_id}.pcap', "ab") as pcap_file:
                        pcap_file.write(payload)
                    server.log(f"Closing pcap file")

        except socket.timeout:
            continue

        except (socket.error, OSError) as e:
            server.log(f"[!] Socket error with {client_obj.unique_id[:8]}: {e}")
            continue
            #break
        except Exception as e:
            server.log(f"[!] Unexpected error in client loop {client_obj.unique_id[:8]}: {e}")
            break