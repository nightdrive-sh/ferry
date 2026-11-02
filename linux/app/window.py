"""Ferry's window: the Mac popover's content, built once (build()), refreshed while it shows, its pages shown by
name. What a page holds is pages.py's, what its buttons do actions.py's."""
import time

from gi.repository import Gdk, GLib, Gtk

import devices_page
import look
from ferry import cli, config, desktop, store, tailnet
from actions import ActionsMixin
from pages import PagesMixin
from widgets import (
    background, button, faded, fresh_popover, gutter, HYPRLAND, ICONS, label, menu_popover, REFRESH, texture,
    UPDATE_EVERY,
)


class Window(PagesMixin, ActionsMixin, Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Ferry")
        self.app = app
        self.add_css_class("ferry")
        # A panel of the Mac popover's size, not a window to stretch: a tiling compositor (Sway) floats a window whose
        # least and greatest sizes are the same, at that size in the middle, where one it may resize would be tiled to
        # fill the screen. Long lists scroll inside it. On Hyprland (Nightdrive) it may be tiled too: Nightdrive's
        # window rule floats it at this size in the middle, and its ⌘⇧T tiles it.
        self.set_default_size(400, 620)
        self.set_resizable(HYPRLAND)
        self.set_icon_name(config.APP_ID)
        self.data = None             # cli.listing(), the last one
        self.refused = None          # tailscale serve's refusal: not asked again until Try Again
        self.acting = False          # a setup step's button is at work
        self.retrying = False        # publishing again quietly, after the operator right was missing
        self.note = ""               # why that didn't work, under the step
        self.page = "main"           # main, add (Add Device), devices (forgetting one) or offer (files from Open With)
        self.add_push = None         # the push count Add Device first listed: one more closes it (None: not yet)
        self.shown = {}              # what each rebuilt page shows, so a refresh that changes nothing leaves it be
        self.offered = []            # those files
        self.dragging = False
        self.confirming = False      # Clear asked
        self.send_state = ("idle",)  # idle, sending, sent NAME, failed REASON, nothing
        self.last_send = None        # (what, device) for Try Again
        self.settling = 0
        self.update = None           # a newer release, from updates.check_update()
        self.updating = False
        self.update_error = ""
        self.update_checked = 0
        self.thumbs = {}
        self.rows = {}               # item id: (row, meta label)
        self.refreshing = False
        self.timer = 0
        self.build()
        self.connect("notify::visible", lambda *_: self.on_visible())
        self.connect("notify::is-active", lambda *_: self.mark_seen())

    # MARK: Building

    def build(self):
        header = Gtk.HeaderBar()
        title = Gtk.Box(spacing=8, halign=Gtk.Align.CENTER)
        mark = Gtk.Image.new_from_paintable(texture(look.tray_svg(0, 40), 40))   # the inbox in Ferry's colours
        mark.set_pixel_size(20)
        title.append(mark)
        title.append(label("Ferry", "title"))
        header.set_title_widget(title)
        settings = Gtk.Settings.get_default()

        def layout(*_):
            header.set_decoration_layout(look.without_icon(settings.get_property("gtk-decoration-layout") or ""))
        layout()
        settings.connect("notify::gtk-decoration-layout", layout)
        self.more = Gtk.MenuButton()
        self.more.set_child(ICONS.image("ellipsis", "dim", 18))
        self.more.add_css_class("fb")
        self.more.add_css_class("flat")
        self.more.set_tooltip_text("More")
        fresh_popover(self.more, self.more_menu)
        header.pack_end(self.more)
        self.set_titlebar(header)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        for side in ("top", "bottom", "start", "end"):
            getattr(root, f"set_margin_{side}")(12)
        self.set_child(root)

        # A newer Ferry
        self.banner = Gtk.Box(spacing=8)
        self.banner.add_css_class("banner")
        self.banner_text = label("", wrap=True)
        self.banner_text.set_hexpand(True)
        self.banner_button = button("Update", None, "primary", on=self.install_update)
        self.banner.append(self.banner_text)
        self.banner.append(self.banner_button)
        self.banner.set_visible(False)
        root.append(self.banner)

        # The section's title, and Clear or the way back
        bar = self.title_bar = Gtk.Box(spacing=8)
        bar.set_margin_start(8)
        bar.set_margin_end(4)
        self.back = button(None, "chevron-left", "flat", tooltip="Back", on=self.go_back)
        self.back.add_css_class("back")
        self.section = label("RECEIVED", "section")
        self.section.set_hexpand(True)
        self.question = label("", "dim")
        self.clear_cancel = button("Cancel", None, "flat", on=lambda: self.ask_clear(False))
        self.clear_yes = button("Clear", None, "flat", "destructive", on=self.clear)
        self.clear_button = button("Clear", None, "flat", on=lambda: self.ask_clear(True))
        for w in (self.back, self.section, self.question, self.clear_cancel, self.clear_yes, self.clear_button):
            bar.append(w)
        root.append(bar)

        self.stack = Gtk.Stack()
        self.stack.set_vexpand(True)
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self.stack.set_transition_duration(120)
        root.append(self.stack)

        # Received
        self.list = Gtk.ListBox()
        self.list.set_selection_mode(Gtk.SelectionMode.NONE)
        self.list.connect("row-activated", lambda _l, row: self.primary(row.item))
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.set_child(self.list)
        gutter(scroller, self.list)
        self.stack.add_named(faded(scroller, self.list) if HYPRLAND else scroller, "list")

        empty = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, valign=Gtk.Align.CENTER)
        empty.append(label("Things your devices send appear here.", "dim", xalign=0.5, wrap=True))
        empty.append(label("On your phone, Send Clipboard sends what you copied to this computer.", "dim",
                           xalign=0.5, wrap=True))
        self.stack.add_named(empty, "empty")

        self.step_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, valign=Gtk.Align.CENTER)
        self.step_box.set_margin_start(16)
        self.step_box.set_margin_end(16)
        self.stack.add_named(self.step_box, "setup")

        self.tiles = Gtk.FlowBox()
        self.tiles.set_selection_mode(Gtk.SelectionMode.NONE)
        self.tiles.set_homogeneous(True)
        self.tiles.set_min_children_per_line(2)
        self.tiles.set_max_children_per_line(2)
        self.tiles.set_row_spacing(8)
        self.tiles.set_column_spacing(8)
        self.tiles.set_valign(Gtk.Align.START)
        tiles_scroller = Gtk.ScrolledWindow()
        tiles_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        tiles_scroller.set_child(self.tiles)
        gutter(tiles_scroller, self.tiles)
        tiles_scroller.set_vexpand(True)
        tiles_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.offered_label = label("", "item", ellipsize=True)   # what Open With gave: the one name, or how many
        self.offered_label.set_max_width_chars(1)
        self.offered_label.set_margin_start(8)
        tiles_page.append(self.offered_label)
        tiles_page.append(tiles_scroller)
        self.stack.add_named(tiles_page, "tiles")

        self.add_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, valign=Gtk.Align.CENTER)
        self.stack.add_named(self.add_box, "add")

        self.devices_page = devices_page.DevicesPage(self.refresh)
        self.stack.add_named(self.devices_page.widget, "devices")

        # Sending: the reason a send failed, the device, the bar
        self.error = label("", "away", xalign=0.5, wrap=True)
        self.error.set_visible(False)
        root.append(self.error)

        self.pill = Gtk.MenuButton()
        self.pill.add_css_class("fb")
        self.pill.add_css_class("pill")
        self.pill.set_halign(Gtk.Align.CENTER)
        pill_box = Gtk.Box(spacing=7)
        self.pill_dot = Gtk.Box(valign=Gtk.Align.CENTER)
        self.pill_dot.add_css_class("dot")
        self.pill_name = label("No devices yet", "mono")
        pill_box.append(self.pill_dot)
        pill_box.append(self.pill_name)
        pill_box.append(ICONS.image("chevrons-up-down", "dim", 12))
        self.pill.set_child(pill_box)
        fresh_popover(self.pill, self.devices_menu)
        self.pill.set_margin_top(6)
        root.append(self.pill)

        self.bar = Gtk.Stack()
        self.bar.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        buttons = Gtk.Box(spacing=8)
        self.aa = button(None, "type", "circle", tooltip="Type a text", on=self.compose)
        self.clip = Gtk.Button()
        self.clip.add_css_class("fb")
        self.clip.add_css_class("primary")
        self.clip.set_hexpand(True)
        clip_box = Gtk.Box(spacing=6, halign=Gtk.Align.CENTER)
        self.clip_icon = ICONS.image("clipboard-paste", "on_primary")
        self.clip_label = label("Send Clipboard")
        clip_box.append(self.clip_icon)
        clip_box.append(self.clip_label)
        self.clip.set_child(clip_box)
        self.clip.connect("clicked", lambda *_: self.send_clipboard())
        self.plus = button(None, "plus", "circle", tooltip="Send files", on=self.pick_files)
        for w in (self.aa, self.clip, self.plus):
            buttons.append(w)
        if HYPRLAND:
            self.aa.add_css_class("round")
            self.plus.add_css_class("round")
        self.bar.add_named(buttons, "buttons")

        compose = Gtk.Box(spacing=8)
        self.entry = Gtk.Entry(placeholder_text="Type a text")
        self.entry.set_hexpand(True)
        self.entry.connect("activate", lambda *_: self.send_text())
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", lambda _c, key, _code, _mods:
                     key == Gdk.KEY_Escape and (self.bar.set_visible_child_name("buttons") or True))
        self.entry.add_controller(keys)
        compose.append(self.entry)
        compose.append(button("Cancel", None, "flat", on=lambda: self.bar.set_visible_child_name("buttons")))
        compose.append(button("Send", None, "primary", on=self.send_text))
        self.bar.add_named(compose, "compose")
        root.append(self.bar)

        # Files dragged over the window turn the list into a tile per device
        motion = Gtk.DropControllerMotion()
        motion.connect("enter", lambda c, *_: self.drag_over(True, c))
        motion.connect("leave", lambda c: self.drag_over(False, c))
        self.add_controller(motion)
        # Dropped anywhere but on a tile: nothing, so the tiles stay the way to pick
        catch = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.COPY)
        catch.connect("drop", lambda *_: self.drag_over(False) or False)
        self.add_controller(catch)

        self.render()

    # MARK: The menus

    def more_menu(self):
        entries = [("Add Device…", lambda: self.show_page("add")), ("Devices…", lambda: self.show_page("devices")),
                   ("Check for Updates", lambda: self.check_update(force=True)), "-",
                   (f"Ferry {config.VERSION}", None, "dim")]
        if self.app.tray:
            entries += ["-", ("Quit Ferry", self.app.quit)]
        return menu_popover(entries)

    def devices_menu(self):
        devices = (self.data or {}).get("devices") or []
        target = (self.data or {}).get("target")
        pop = Gtk.Popover()
        pop.add_css_class("ferry")
        pop.set_has_arrow(False)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        for d in devices:
            b = Gtk.Button()
            b.add_css_class("fb")
            b.add_css_class("menuitem")
            row = Gtk.Box(spacing=8)
            check = ICONS.image("check", "primary", 14, 2.5)
            check.set_opacity(1 if d["id"] == target else 0)
            row.append(check)
            dot = Gtk.Box(valign=Gtk.Align.CENTER)
            dot.add_css_class("dot")
            if not d.get("online"):
                dot.add_css_class("away")
            row.append(dot)
            name = label(d["name"], "mono")
            name.set_hexpand(True)
            row.append(name)
            row.append(ICONS.image(look.device_icon(d), "dim", 14))
            b.set_child(row)
            b.set_sensitive(look.can_take(d))
            b.connect("clicked", lambda _b, d=d: (pop.popdown(), self.pick(d)))
            box.append(b)
        if devices:
            box.append(Gtk.Separator())
        add = Gtk.Button(label="Add Device…")
        add.add_css_class("fb")
        add.add_css_class("menuitem")
        add.get_child().set_xalign(0)
        add.connect("clicked", lambda *_: (pop.popdown(), self.show_page("add")))
        box.append(add)
        pop.set_child(box)
        return pop

    # MARK: Refreshing

    def on_visible(self):
        if self.get_visible():
            self.refresh()
            if not self.timer:
                self.timer = GLib.timeout_add_seconds(REFRESH, self.tick)
            if time.time() - self.update_checked > UPDATE_EVERY:
                self.check_update()
        elif self.timer:
            GLib.source_remove(self.timer)
            self.timer = 0
            self.go_back()

    def tick(self):
        self.refresh()
        return True

    def refresh(self):
        if self.refreshing:
            return
        self.refreshing = True

        def done(data):
            self.refreshing = False
            if data is not None:
                if self.page == "add" and look.phone_added(self.add_push, data):
                    self.page = "main"
                elif self.page == "add" and self.add_push is None:
                    self.add_push = data.get("push", 0)
                self.data = data
                self.publish_if_needed()
                self.render()
                self.mark_seen()
        background(cli.listing, done)

    def publish_if_needed(self):
        """Not on the tailnet, and neither its user nor Tailscale said no: put it there, as `ferry enable` does. Refused
        for want of the operator right, it tries again quietly, since the step shows the command to run in a terminal
        and nothing would tell the window it was run."""
        step = self.data.get("setup")
        if not step or step["step"] != "not-published" or self.acting:
            return
        if not self.refused:
            self.run_action("publish")
        elif self.refused["step"] == "operator" and not self.retrying:
            self.retrying = True

            def done(refusal):
                self.retrying = False
                if not refusal or refusal["step"] != "operator":
                    self.refused = refusal
                    self.refresh()
            background(tailnet.publish, done)

    def mark_seen(self):
        """What arrived is seen once the window shows it: the tray's count goes, and a desktop's menu hears of it."""
        if not (self.data and self.is_active() and self.get_visible() and self.page == "main"):
            return
        if any(i.get("to") == "computer" and not i.get("seen") for i in self.data.get("items") or []):
            for i in self.data["items"]:
                i["seen"] = True
            background(lambda: (store.mark_seen(), desktop.changed()), lambda _: self.app.recount())

    # MARK: Drawing

    def step(self):
        step = (self.data or {}).get("setup")
        if step and step["step"] == "not-published" and self.refused:
            return self.refused
        return step

    # MARK: Pages

    def show_for_test(self, what):
        """`ferry app --show=add|devices|device-list|more|compose|tiles|clipboard|update|setup|type=TEXT`: that page or
        menu open (or Send Clipboard, or the setup step's button, pressed), for screenshots in a VM, where nothing
        clicks. devices is the device menu, device-list the Devices page."""
        if what == "add":
            self.show_page("add")
        elif what == "device-list":
            self.show_page("devices")
        elif what == "devices":
            self.pill.popup()
        elif what == "more":
            self.more.popup()
        elif what == "compose":
            self.compose()
        elif what == "tiles":
            self.dragging = True
            self.render()
        elif what == "clipboard":
            self.send_clipboard()
        elif what.startswith("type="):   # Aa, the text typed, Return
            self.compose()
            self.entry.set_text(what[5:])
            self.send_text()
        elif what == "setup":   # the setup step's own button (Turn On, Allow…), not its link
            step = self.step()
            if step and step.get("action"):
                self.run_action(step["action"])
        elif what == "update":   # the check, then the banner's Update pressed
            self.check_update(force=True)
            GLib.timeout_add_seconds(4, lambda: self.update and self.install_update() and False)

    def show_page(self, page):
        self.page = page
        if page == "add":   # counted afresh: a phone added while the window was hidden isn't this one
            self.add_push = None
            self.refresh()
        self.confirming = False
        self.present()
        self.render()

    def go_back(self):
        self.page, self.offered = "main", []
        self.render()
