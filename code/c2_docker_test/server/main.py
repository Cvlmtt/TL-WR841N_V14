from server_core.core import C2Server
from ui.console import ConsoleUI
from ui.tui import TUI

def main():
    server = C2Server()
    ui = TUI()
    server.start(ui)

if __name__ == "__main__":
    main()
