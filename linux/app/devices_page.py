"""The window's Devices page (More › Devices…): the owner's other devices, each forgotten on all of them with Forget
(docs/protocol.md › Forgetting a device). Nothing here brings one back: adding it again does. It gets ferry_app as `ui`,
as ferry_app gets bin/ferry as `core`: the helpers and the look are the window's, the forgetting is the server's."""
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
        devices = (data or {}).get("devices") or []
        shown = [(d["id"], d.get("name"), d.get("kind")) for d in devices]
        if shown == self.shown:   # a refresh that changes nothing leaves the buttons be
            return
        self.shown = shown
        while self.list.get_first_child():
            self.list.remove(self.list.get_first_child())
        self.empty.set_visible(not devices)
        for device in devices:
            self.list.append(self.row(device))

    def row(self, device):
        ui = self.ui
        row = Gtk.ListBoxRow(activatable=False)
        box = Gtk.Box(spacing=10)
        tile = Gtk.Box(halign=Gtk.Align.START, valign=Gtk.Align.CENTER)
        tile.set_size_request(36, 36)
        tile.add_css_class("tile")
        icon = ui.ICONS.image(look.device_icon(device), "accent", 16)
        icon.set_halign(Gtk.Align.CENTER)
        icon.set_valign(Gtk.Align.CENTER)
        icon.set_size_request(36, 36)
        tile.append(icon)
        box.append(tile)
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, valign=Gtk.Align.CENTER)
        text.set_hexpand(True)
        name = ui.label(device.get("name") or device["id"], "item", ellipsize=True)
        name.set_max_width_chars(1)   # the row's width, not the name's, decides
        text.append(name)
        box.append(text)
        action = ui.button("Forget", None, "pill", tooltip=f"Forget {device.get('name') or device['id']}",
                           on=lambda: self.forget(device, action))
        action.set_valign(Gtk.Align.CENTER)
        box.append(action)
        row.set_child(box)
        return row

    def forget(self, device, action):
        action.set_sensitive(False)
        self.ui.background(lambda: self.ui.core.decide(device["id"], True), lambda _: self.refresh())
