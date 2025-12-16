# ui/tui.py

from ui.base import BaseUI

from textual.app import App, ComposeResult
from textual.widgets import (
    Header, Footer, RichLog, Input, Static,
    ListView, ListItem, Label, Pretty
)
from textual.containers import Horizontal, Vertical, Container
from textual.events import Key

import threading
import queue as pyqueue
import time
import json


HELP_TEXT = (
    "Commands:\n"
    "  help\n"
    "  list                      (delegated to server.list_command())\n"
    "  broadcast <cmd>\n"
    "  client <idprefix|uid> <cmd>\n"
    "  push <source> <dest>\n"
    "  note <idprefix|uid> <note>\n"
    "  clear\n"
    "  <cmd>                     (sends to current TARGET mode)\n"
    "  exit\n"
    "\n"
    "Shortcuts:\n"
    "  F1        help\n"
    "  Ctrl+S    target: SELECTED\n"
    "  Ctrl+B    target: BROADCAST\n"
    "  Ctrl+L    list\n"
    "  Ctrl+R    refresh clients\n"
    "  Ctrl+T    toggle sort mode\n"
    "  Ctrl+D    toggle detail view\n"
    "  Ctrl+Q    exit\n"
    "\n"
    "History:\n"
    "  Up/Down in input for command history\n"
)


class ClientListItem(ListItem):
    """ListItem with attached unique_id."""
    def __init__(self, uid: str, text: str):
        super().__init__(Label(text))
        self.uid = uid


class C2TUI(App):
    # Key bindings (work well with Input focus since they are Ctrl/F keys)
    BINDINGS = [
        ("f1", "help", "Help"),
        ("ctrl+s", "target_selected", "Target Selected"),
        ("ctrl+b", "target_broadcast", "Target Broadcast"),
        ("ctrl+l", "do_list", "List"),
        ("ctrl+r", "refresh", "Refresh"),
        ("ctrl+t", "toggle_sort", "Toggle Sort"),
        ("ctrl+d", "toggle_detail_view", "Toggle Detail View"),
        ("ctrl+q", "quit", "Quit"),
    ]

    CSS = """
    #root {
        height: 1fr;
    }

    #status {
        height: 1;
    }

    #main-pane {
        height: 1fr;
    }

    #clients {
        width: 40;
        height: 1fr;
        border: solid $primary;
    }

    #log {
        height: 1fr;
        border: solid $primary;
    }

    #detail-view {
        height: 1fr;
        border: solid $primary;
        display: none; /* Initially hidden */
    }

    #input {
        height: 3;
    }
    """

    def __init__(self, server):
        super().__init__()
        self.server = server
        self._log_queue = None

        # Widgets
        self.status = Static("Ready", id="status")
        self.clients_view = ListView(id="clients")
        self.log_widget = RichLog(id="log", markup=True, auto_scroll=True)
        self.detail_view = Pretty("", id="detail-view")
        self.cmd_input = Input(
            placeholder="Type a command (F1 help). Default sends to TARGET.",
            id="input"
        )

        # Selection / target
        self.selected_uid: str | None = None
        self.target_mode: str = "SELECTED"  # or "BROADCAST"

        # Input history
        self._history: list[str] = []
        self._hist_idx: int = -1

        # Sorting
        self._sort_cycle = ["id", "status", "ip", "idle"]
        self._sort_mode = self._sort_cycle[0]
        self._sort_reverse = False
        self._detail_view_visible = False

        # Timer handle
        self._client_refresh_timer = None

    def compose(self) -> ComposeResult:
        yield Header()
        yield Vertical(
            self.status,
            Horizontal(
                self.clients_view,
                Container(
                    self.log_widget,
                    self.detail_view,
                ),
                id="main-pane",
            ),
            self.cmd_input,
        )
        yield Footer()

    def on_mount(self) -> None:
        # Choose queue used by server logging
        if hasattr(self.server, "print_queue"):
            self._log_queue = self.server.print_queue
        elif hasattr(self.server, "logger") and hasattr(self.server.logger, "queue"):
            self._log_queue = self.server.logger.queue
        else:
            self.log_widget.write("ERROR: no log queue found on server")
            return

        self.log_widget.write("TUI attached. Press F1 for help.")
        self.cmd_input.focus()

        # Start log consumer thread
        self.log_thread = threading.Thread(target=self.consume_logs, daemon=True)
        self.log_thread.start()

        # Initial + periodic refresh (UI thread)
        self.refresh_client_list()
        self._client_refresh_timer = self.set_interval(2.0, self.refresh_client_list)

        # Initial status
        self.update_status()

    # ---------------- actions (bindings) ----------------
    def action_help(self) -> None:
        self.log_widget.write(HELP_TEXT)

    def action_target_selected(self) -> None:
        self.target_mode = "SELECTED"
        self.update_status()
        self.log_widget.write("[i]Target mode set to SELECTED[/i]")

    def action_target_broadcast(self) -> None:
        self.target_mode = "BROADCAST"
        self.update_status()
        self.log_widget.write("[i]Target mode set to BROADCAST[/i]")

    def action_do_list(self) -> None:
        self.status.update("Listing clients...")
        try:
            self.server.list_command()
        finally:
            self.update_status()

    def action_refresh(self) -> None:
        self.refresh_client_list()
        self.log_widget.write("[i]Client list refreshed[/i]")

    def action_toggle_sort(self) -> None:
        """Cycles through sort modes."""
        current_idx = self._sort_cycle.index(self._sort_mode)
        next_idx = (current_idx + 1) % len(self._sort_cycle)
        self._sort_mode = self._sort_cycle[next_idx]
        self.log_widget.write(f"[i]Sort mode set to: {self._sort_mode.upper()}[/i]")
        self.refresh_client_list()

    def action_toggle_detail_view(self) -> None:
        """Toggles the detail view."""
        self._detail_view_visible = not self._detail_view_visible
        if self._detail_view_visible:
            self.update_detail_view()
        else:
            self.detail_view.display = False
            self.log_widget.display = True


    def action_quit(self) -> None:
        self.status.update("Stopping...")
        self.server.running = False
        self.exit()

    # ---------------- logs ----------------
    def consume_logs(self):
        while self.server.running:
            try:
                msg = self._log_queue.get(timeout=1)
                self.call_from_thread(self.log_widget.write, str(msg))
            except pyqueue.Empty:
                continue
            except Exception as e:
                self.call_from_thread(self.log_widget.write, f"[consume_logs error] {e!r}")

    # ---------------- client list ----------------
    def refresh_client_list(self) -> None:
        try:
            now = time.time()

            with self.server.lock:
                clients = list(self.server.clients.values())

            # Sorting logic
            if self._sort_mode == "id":
                clients.sort(key=lambda c: c.unique_id, reverse=self._sort_reverse)
            elif self._sort_mode == "status":
                clients.sort(key=lambda c: c.active, reverse=self._sort_reverse)
            elif self._sort_mode == "ip":
                clients.sort(key=lambda c: c.ip, reverse=self._sort_reverse)
            elif self._sort_mode == "idle":
                clients.sort(key=lambda c: (now - c.last_seen), reverse=self._sort_reverse)

            items: list[ClientListItem] = []
            active_uids = set()

            for c in clients:
                with c.lock:
                    uid = c.unique_id
                    state = "A" if c.active else "I"
                    idle = int(now - c.last_seen)
                    text = f"{uid[:8]}  {state}  {c.ip}:{c.port}  idle:{idle}s"
                    items.append(ClientListItem(uid, text))
                    if c.active:
                        active_uids.add(uid)

            # UI-thread update
            self.clients_view.clear()
            for it in items:
                self.clients_view.append(it)

            # preserve selection if still present; otherwise pick first item if any
            if self.selected_uid and any(isinstance(it, ClientListItem) and it.uid == self.selected_uid for it in self.clients_view.children):
                for idx, it in enumerate(self.clients_view.children):
                    if isinstance(it, ClientListItem) and it.uid == self.selected_uid:
                        self.clients_view.index = idx
                        break
            else:
                self.selected_uid = None
                for idx, it in enumerate(self.clients_view.children):
                    if isinstance(it, ClientListItem):
                        self.selected_uid = it.uid
                        self.clients_view.index = idx
                        break
            
            if not self.selected_uid:
                self.update_detail_view()

            self.update_status()
            self.clients_view.refresh()

        except Exception as e:
            self.log_widget.write(f"[refresh_client_list error] {e!r}")

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        item = event.item
        if isinstance(item, ClientListItem):
            self.selected_uid = item.uid
            self.update_status()
            self.update_detail_view()

    def update_detail_view(self) -> None:
        """Updates the detail view with info on the selected client."""
        if not self.selected_uid or not self._detail_view_visible:
            self.detail_view.update("")
            self.detail_view.display = False
            self.log_widget.display = True
            return

        with self.server.lock:
            client = self.server.clients.get(self.selected_uid)

        if not client:
            self.detail_view.update("")
            self.detail_view.display = False
            self.log_widget.display = True
            return

        with client.lock:
            now = time.time()
            data = {
                "unique_id": client.unique_id,
                "ip": client.ip,
                "port": client.port,
                "active": client.active,
                "last_seen": f"{int(now - client.last_seen)}s ago",
                "first_seen": time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(client.first_seen)),
                "note": client.note,
            }

        self.detail_view.update(json.dumps(data, indent=2))
        self.detail_view.display = True
        self.log_widget.display = False


    # ---------------- input / history ----------------
    def on_key(self, event: Key) -> None:
        # History only when input has focus
        if not self.cmd_input.has_focus:
            return

        if event.key == "up":
            if not self._history:
                return
            if self._hist_idx == -1:
                self._hist_idx = len(self._history) - 1
            else:
                self._hist_idx = max(0, self._hist_idx - 1)
            self.cmd_input.value = self._history[self._hist_idx]
            self.cmd_input.cursor_position = len(self.cmd_input.value)
            event.stop()
            return

        if event.key == "down":
            if not self._history or self._hist_idx == -1:
                return
            self._hist_idx += 1
            if self._hist_idx >= len(self._history):
                self._hist_idx = -1
                self.cmd_input.value = ""
            else:
                self.cmd_input.value = self._history[self._hist_idx]
            self.cmd_input.cursor_position = len(self.cmd_input.value)
            event.stop()
            return

    def on_input_submitted(self, event: Input.Submitted) -> None:
        raw = (event.value or "").strip()
        event.input.value = ""
        self._hist_idx = -1

        if not raw:
            return

        if not self._history or self._history[-1] != raw:
            self._history.append(raw)

        self.log_widget.write(f"[b]C2>[/b] {raw}")

        try:
            self.handle_command(raw)
        except Exception as e:
            self.log_widget.write(f"[!] UI error: {e!r}")

    # ---------------- command parsing ----------------
    def handle_command(self, raw: str) -> None:
        if raw == "help":
            self.action_help()
            return

        if raw == "exit":
            self.action_quit()
            return

        if raw == "list":
            self.action_do_list()
            return

        if raw == "clear":
            self.log_widget.clear()
            self.log_widget.write("Log cleared.")
            return

        if raw.startswith("broadcast "):
            cmd = raw[len("broadcast "):].strip()
            if not cmd:
                self.log_widget.write("[!] Usage: broadcast <cmd>")
                return
            self.status.update(f"Broadcasting: {cmd}")
            self.server.broadcast_command(cmd)
            self.update_status()
            return

        if raw.startswith("client "):
            rest = raw[len("client "):].strip()
            parts = rest.split(" ", 1)
            if len(parts) != 2:
                self.log_widget.write("[!] Usage: client <idprefix|uid> <cmd>")
                return
            uid_prefix, cmd = parts[0].strip(), parts[1].strip()
            if not uid_prefix or not cmd:
                self.log_widget.write("[!] Usage: client <idprefix|uid> <cmd>")
                return
            self.status.update(f"Sending to {uid_prefix[:8]}...: {cmd}")
            self.server.client_command(uid_prefix, cmd)
            self.update_status()
            return

        if raw.startswith("note "):
            rest = raw[len("note "):].strip()
            parts = rest.split(" ", 1)
            if len(parts) != 2:
                self.log_widget.write("[!] Usage: note <idprefix|uid> <note>")
                return
            uid_prefix, note = parts[0].strip(), parts[1].strip()
            if not uid_prefix or not note:
                self.log_widget.write("[!] Usage: note <idprefix|uid> <note>")
                return
            
            with self.server.lock:
                client = self.server.find_client_by_prefix(uid_prefix)

            if not client:
                self.log_widget.write(f"[!] No client found with prefix: {uid_prefix}")
                return

            with client.lock:
                client.note = note
            
            self.log_widget.write(f"Note added to client {client.unique_id[:8]}")
            self.update_detail_view()
            return

        if raw.startswith("push "):
            parts = raw.split(" ")
            if len(parts) != 3:
                self.log_widget.write("[!] Usage: push <source_path> <dest_path>")
                return

            source_path = parts[1]
            dest_path = parts[2]

            if self.target_mode == "BROADCAST":
                self.server.push_file_to_all_clients(source_path, dest_path)
                self.log_widget.write(f"Broadcasting file {source_path} to all clients.")
            else: # SELECTED
                if not self.selected_uid:
                    self.log_widget.write("[!] No client selected.")
                    return
                self.server.push_file_to_client(self.selected_uid, source_path, dest_path)
                self.log_widget.write(f"Pushing file {source_path} to {self.selected_uid[:8]}...")
            return

        # Default: send to target mode
        if self.target_mode == "BROADCAST":
            self.status.update(f"Broadcasting: {raw}")
            self.server.broadcast_command(raw)
            self.update_status()
            return

        # SELECTED mode
        if not self.selected_uid:
            self.log_widget.write("[!] No client selected. Select one or use 'client <idprefix> <cmd>'.")
            return

        self.status.update(f"Sending to selected {self.selected_uid[:8]}...: {raw}")
        # send full uid to avoid prefix collision
        self.server.client_command(self.selected_uid, raw)
        self.update_status()

    # ---------------- status ----------------
    def update_status(self) -> None:
        # Count active clients
        with self.server.lock:
            clients = list(self.server.clients.values())

        active = 0
        for c in clients:
            with c.lock:
                if c.active:
                    active += 1

        sel = self.selected_uid[:8] + "..." if self.selected_uid else "(none)"
        sort = self._sort_mode.upper()
        self.status.update(f"TARGET={self.target_mode} | Selected={sel} | Active={active} | Sort={sort}")

        if self.target_mode == "BROADCAST":
            self.cmd_input.placeholder = "TARGET=BROADCAST — type command to broadcast (F1 help)"
        else:
            self.cmd_input.placeholder = f"TARGET=SELECTED ({sel}) — type command to send (F1 help)"


class TUI(BaseUI):
    handles_logs = True

    def run(self, server):
        app = C2TUI(server)
        app.run()
