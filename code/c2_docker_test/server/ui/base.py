# ui/base.py

class BaseUI:
    """
    Interfaccia base per tutte le UI (console, TUI, web, ecc.)
    """
    def run(self, server):
        raise NotImplementedError("UI must implement run(server)")
