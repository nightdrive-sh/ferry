"""What the window does: files dropped or picked, an item copied, opened or removed, a text or the clipboard sent,
updates checked and installed. The work runs off the main loop (background())."""
import os
import shutil
import subprocess
import sys
import tempfile
import time

from gi.repository import Gdk, Gio, GLib, Gtk

import look
from ferry import computers, config, desktop, install, store, tailnet, updates
from widgets import background, SETTLE, UPDATE_EVERY


class ActionsMixin:
    """Window's actions: each calls the ferry package off the main loop and shows the outcome."""

    def offer(self, paths):
        """Files from Open With: a tile per device, and a click sends them there."""
        paths = [p for p in paths if os.path.exists(p)]
        if not paths:
            return
        self.offered = paths
        self.show_page("offer")

    def tile_clicked(self, device):
        if self.page == "offer":
            files, self.offered, self.page = self.offered, [], "main"
            self.send(("files", files, False), device)

    def drag_over(self, on, controller=None):
        if on and controller is not None:
            drop = controller.get_drop()
            if not drop or not drop.get_formats().contain_gtype(Gdk.FileList):
                return
        if self.dragging != on:
            self.dragging = on
            self.render()

    def dropped(self, value, device):
        files = [f.get_path() for f in value.get_files() if f.get_path()]
        self.dragging = False
        if files:
            self.send(("files", files, False), device)
        self.render()
        return True

    def ask_clear(self, on):
        self.confirming = on
        self.render()
        if on:   # a question left unanswered goes away by itself
            GLib.timeout_add_seconds(5, lambda: self.confirming and self.ask_clear(False) and False)

    def clear(self):
        self.confirming = False

        def work():
            with store.box(write=True) as items:
                for it in [i for i in items if i.get("to") == "computer"]:
                    store.drop_file(it)
                    items.remove(it)
            desktop.changed()
        background(work, lambda _: self.refresh())

    # MARK: Received items

    def primary(self, item):
        """A link opens, another text is copied, a file opens in its app."""
        if item.get("kind") == "file":
            self.open_file(item)
        elif look.link(item.get("text")):
            self.open_uri(look.link(item["text"]))
        else:
            self.copy(item, self.rows.get(item["id"], (None,))[0])

    def copy(self, item, row):
        # A code or a password leaves the box once copied (docs/protocol.md › Codes and passwords)
        background(lambda: desktop.copy_text(item.get("text") or "", sensitive=store.secret(item)) and store.copied(item),
                   lambda _: store.secret(item) and self.refresh())
        if row is not None:
            title = row.title
            old, classes = title.get_label(), title.get_css_classes()
            title.set_label("Copied")
            title.set_css_classes(["copied"])
            GLib.timeout_add(1500, lambda: (title.set_label(old), title.set_css_classes(classes)) and False)

    def open_file(self, item):
        if not os.path.exists(item.get("path", "")):
            return self.refresh()   # moved or deleted: its row goes
        background(lambda: desktop.open_path(item["path"]))

    def open_uri(self, uri):
        try:
            Gio.AppInfo.launch_default_for_uri(uri, None)
        except GLib.Error:
            background(lambda: subprocess.run(["xdg-open", uri], env=desktop.desktop_env()))

    def remove(self, item):
        background(lambda: (store.remove(item["id"]), desktop.changed()), lambda _: self.refresh())

    # MARK: Setup

    def run_action(self, action):
        """A setup step's button: what Ferry can do by itself."""
        self.acting, self.note = True, ""
        if action == "publish":
            self.refused = None
        self.render()
        user = os.environ.get("USER") or ""

        def work():
            if action == "publish":
                return ("publish", tailnet.publish())
            if action == "enable":
                return ("enable", install.enable())
            if action == "tailscale-up":
                r = subprocess.run(["tailscale", "up"], capture_output=True, text=True, timeout=60)
                return ("up", (r.stdout + r.stderr).strip() if r.returncode else "")
            if action == "operator":
                exe = shutil.which("tailscale") or "tailscale"
                r = subprocess.run(["pkexec", exe, "set", f"--operator={user}"], capture_output=True, text=True)
                if r.returncode == 0:
                    return ("publish", tailnet.publish())
                return ("operator", (r.stdout + r.stderr).strip())
            return (action, None)

        def done(result):
            self.acting = False
            kind, value = result or (action, "failed")
            if kind == "publish":
                self.refused = value
            elif kind in ("up", "operator") and value:
                self.note = value.splitlines()[-1]
            elif kind == "enable" and value:
                self.note = "Ferry didn't start: see journalctl --user -u ferry"
            self.render()
            self.refresh()
        background(work, done)

    # MARK: Sending

    def target(self):
        data = self.data or {}
        return next((d for d in data.get("devices") or [] if d["id"] == data.get("target")), None)

    def pick(self, device):
        self.data["target"] = device["id"]
        self.send_state = ("idle",)
        self.render()
        background(lambda: computers.set_target(device["id"]))

    def compose(self):
        self.entry.set_text("")
        self.bar.set_visible_child_name("compose")
        self.entry.grab_focus()

    def send_text(self):
        text = self.entry.get_text()
        if not text.strip():
            return
        self.bar.set_visible_child_name("buttons")
        self.send(("text", text, False))

    def send_clipboard(self):
        """Try Again after a failure, else what is on the clipboard now: files copied in a file manager, an image, or a
        text, which another computer puts on its own clipboard."""
        if self.send_state[0] == "failed" and self.last_send:
            return self.send(*self.last_send)
        clip = self.get_display().get_clipboard()
        formats = clip.get_formats()

        def files_read(c, res):
            try:
                value = c.read_value_finish(res)
                paths = [f.get_path() for f in value.get_files() if f.get_path()]
            except GLib.Error:
                paths = []
            if paths:
                self.send(("files", paths, False))
            else:
                self.read_text(c)

        def image_read(c, res):
            try:
                tex = c.read_texture_finish(res)
            except GLib.Error:
                tex = None
            if not tex:
                return self.read_text(c)
            d = tempfile.mkdtemp(prefix="ferry-")
            path = os.path.join(d, time.strftime("Clipboard %Y-%m-%d %H.%M.%S.png"))
            tex.save_to_png(path)
            self.send(("files", [path], True))

        if formats.contain_gtype(Gdk.FileList):
            clip.read_value_async(Gdk.FileList, GLib.PRIORITY_DEFAULT, None, files_read)
        elif formats.contain_gtype(Gdk.Texture) or any(m.startswith("image/") for m in formats.get_mime_types() or []):
            clip.read_texture_async(None, image_read)
        else:
            self.read_text(clip)

    def read_text(self, clip):
        def read(c, res):
            try:
                text = c.read_text_finish(res)
            except GLib.Error:
                text = None
            if text and text.strip():
                self.send(("text", text, True))
            else:   # GTK saw nothing: the desktop's own tools may (and GNOME's clipboard over X11)
                background(desktop.paste_text, lambda t: self.send(("text", t, True)) if t and t.strip()
                           else self.settle(("nothing",)))
        clip.read_text_async(None, read)

    def pick_files(self):
        dialog = Gtk.FileDialog(title="Send with Ferry", accept_label="Send", modal=True)
        device = self.target()

        def chosen(d, res):
            try:
                files = d.open_multiple_finish(res)
            except GLib.Error:
                return
            paths = [files.get_item(i).get_path() for i in range(files.get_n_items())]
            paths = [p for p in paths if p]
            if paths:
                self.send(("files", paths, False), device)
        dialog.open_multiple(self, None, chosen)

    def send(self, what, device=None):
        """At once, to the device given or the one picked: a send never waits for a refresh."""
        device = device or self.target()
        if not device:
            self.last_send = None
            return self.settle(("failed", "No device to send to: add one with Add Device"))
        self.last_send = (what, device)
        self.send_state = ("sending",)
        self.render()
        kind, payload, clip = what

        def work():
            if kind == "text":
                return computers.deliver(device, text=payload, clip=clip)
            return computers.deliver(device, files=payload, clip=clip)
        background(work, lambda err: self.settle(("failed", err) if err else ("sent", device["name"])) if err is not None
                   else self.settle(("failed", "Ferry couldn't send that")))

    def settle(self, state):
        """A result shows for a moment; a failure stays until the next send, with Try Again."""
        self.send_state = state
        self.render()
        self.settling += 1
        n = self.settling
        if state[0] != "failed":
            GLib.timeout_add_seconds(SETTLE, lambda: n == self.settling and self.settle_idle() and False)
        self.refresh()

    def settle_idle(self):
        self.send_state = ("idle",)
        self.render()

    # MARK: Updates

    def check_update(self, force=False):
        self.update_checked = time.time()

        def work():
            try:
                return ("ok", updates.check_update(max_age=None if force else UPDATE_EVERY))
            except (OSError, ValueError) as e:
                return ("error", str(e))

        def done(result):
            kind, value = result or ("error", "")
            if kind == "ok":
                self.update, self.update_error = value, ""
                if force and not value:
                    who = updates.managed_by()
                    self.flash(f"{who} updates Ferry here." if who else f"Ferry {config.VERSION} is the latest.")
            elif force:
                self.flash("Couldn't check for updates.")
            self.render()
        background(work, done)

    def flash(self, text):
        self.update_error = text
        self.render()
        GLib.timeout_add_seconds(4, lambda: (setattr(self, "update_error", ""), self.render()) and False)

    def install_update(self):
        """`ferry update` (the release's install script), then this app again, as the new version."""
        self.updating, self.update_error = True, ""
        self.render()
        exe = os.path.join(config.ROOT, "bin", "ferry")

        def work():
            r = subprocess.run([sys.executable, exe, "update"], capture_output=True, text=True,
                               stdin=subprocess.DEVNULL)
            return r.returncode, (r.stdout + r.stderr).strip()

        def done(result):
            code, out = result or (1, "")
            self.updating = False
            if code == 0:
                self.app.restart()
            else:
                self.update_error = "Couldn't update: " + (out.splitlines()[-1] if out else "the install failed")
                self.render()
        background(work, done)
