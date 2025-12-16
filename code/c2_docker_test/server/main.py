from server_core.core import C2Server
from ui.console import run_console

if __name__ == "__main__":
    server = C2Server()
    server.start()
    run_console(server)
