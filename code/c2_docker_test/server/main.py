import argparse
from server_core.core import C2Server
from ui.console import ConsoleUI
from ui.tui import TUI

def main():
    parser = argparse.ArgumentParser(description="C2 Server")
    parser.add_argument("--ui", choices=["console", "tui"], default="tui", help="Select the user interface")
    args = parser.parse_args()

    server = C2Server()

    if args.ui == "console":
        ui = ConsoleUI()
    else:
        ui = TUI()

    server.start(ui)

if __name__ == "__main__":
    main()
