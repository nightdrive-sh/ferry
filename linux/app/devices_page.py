"""The window's Devices page (More › Devices…): the owner's other devices, each forgotten on all of them with Forget, and
the forgotten ones brought back (docs/protocol.md › Forgetting a device). It gets ferry_app as `ui`, as ferry_app gets
bin/ferry as `core`: the helpers and the look are the window's, the forgetting is the server's."""
from gi.repository import Gtk

import look


class DevicesPage:
    def __init__(self, ui, refresh):
        self.ui, self.refresh = ui, refresh
        self.shown = None
        self.list = Gtk.ListBox()
        self.list.set_selection_mode(Gtk.SelectionMode.NONE)
        self.empty = ui.label("No other device yet: add one with Add Device.", "dim", xalign=0.5, wrap=True)
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.set_child(self.list)
        scroller.set_vexpand(True)
        ui.gutter(scroller, self.list)
        self.widget = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.widget.append(self.empty)
        self.widget.append(scroller)
        note = ui.label(look.FORGET_NOTE, "dim", wrap=True)
        note.set_margin_start(8)
        note.set_margin_end(8)
        self.widget.append(note)

    def fill(self, data):
        rows = look.device_rows(data or {})
        shown = [(d["id"], d.get("name"), d.get("kind"), forgotten) for d, forgotten in rows]
        if shown == self.shown:   # a refresh that changes nothing leaves the buttons be
            return
        self.shown = shown
        while self.list.get_first_child():
            self.list.remove(self.list.get_first_child())
        self.empty.set_visible(not rows)
        for device, forgotten in rows:
            self.list.append(self.row(device, forgotten))

    def row(self, device, forgotten):
        ui = self.ui
        row = Gtk.ListBoxRow(activatable=False)
        box = Gtk.Box(spacing=10)
        tile = Gtk.Box(halign=Gtk.Align.START, valign=Gtk.Align.CENTER)
        tile.set_size_request(36, 36)
        tile.add_css_class("tile")
        icon = ui.ICONS.image(look.device_icon(device), "dim" if forgotten else "accent", 16)
        icon.set_halign(Gtk.Align.CENTER)
        icon.set_valign(Gtk.Align.CENTER)
        icon.set_size_request(36, 36)
        tile.append(icon)
        box.append(tile)
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, valign=Gtk.Align.CENTER)
        text.set_hexpand(True)
        name = ui.label(device.get("name") or device["id"], "item", *(("dim",) if forgotten else ()), ellipsize=True)
        name.set_max_width_chars(1)   # the row's width, not the name's, decides
        text.append(name)
        if forgotten:
            text.append(ui.label("Forgotten", "meta"))
        box.append(text)
        action = ui.button("Bring Back" if forgotten else "Forget", None, "pill",
                           tooltip=f"{'Bring back' if forgotten else 'Forget'} {device.get('name') or device['id']}",
                           on=lambda: self.decide(device, not forgotten, action))
        action.set_valign(Gtk.Align.CENTER)
        box.append(action)
        row.set_child(box)
        return row

    def decide(self, device, forget, action):
        action.set_sensitive(False)
        self.ui.background(lambda: self.ui.core.decide(device["id"], forget), lambda _: self.refresh())
