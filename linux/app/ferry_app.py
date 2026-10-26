"""Ferry's window and tray icon on Linux: the Mac app's popover as a GTK 4 window, in Ferry's own colours.

`ferry app` runs it with bin/ferry as `core`: everything the window shows and does is core's (the box, the devices, the
setup steps, sending, updates), so a desktop's own menu (`ferry list --json`) and the `ferry` command say and do the
same. This file only draws it and runs it off the main loop.

One instance per user (a GtkApplication): Open With, the app list and the tray all reach the running one. With a tray
(a StatusNotifierWatcher on the session bus: KDE, Ubuntu's GNOME, Cinnamon, XFCE, Waybar) closing the window hides it;
without one, it quits, and `--background` (the login item) quits at once."""
import ctypes
import ctypes.util
import os
import subprocess
import sys
import tempfile
import threading
import time
import traceback

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk, Pango  # noqa: E402

import devices_page  # noqa: E402
import look  # noqa: E402

core = None              # bin/ferry, as a module (main())
REFRESH = 5              # seconds between looks at the box and the devices while the window shows
UPDATE_EVERY = 6 * 3600  # seconds between checks for a newer Ferry
SETTLE = 2               # seconds "Sent to … ✓" shows
HYPRLAND = look.hyprland(os.environ.get("XDG_CURRENT_DESKTOP", ""))   # Nightdrive's look (look.hyprland())


def later(fn, *args):
    """fn on the main loop, once."""
    GLib.idle_add(lambda: fn(*args) and False)


def background(work, done=None):
    """work() off the main loop, done(result) back on it; done(None) after an exception, which is printed."""
    def run():
        try:
            result = work()
        except Exception:
            traceback.print_exc()
            result = None
        if done:
            later(done, result)
    threading.Thread(target=run, daemon=True).start()


def load_fonts():
    """Ferry's JetBrains Mono for this process only, without installing it: fontconfig's app fonts, which Pango sees."""
    try:
        fc = ctypes.CDLL(ctypes.util.find_library("fontconfig") or "libfontconfig.so.1")
        fc.FcConfigAppFontAddDir.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        fc.FcConfigAppFontAddDir(None, core.FONTS.encode())
    except (OSError, AttributeError):
        pass


def texture(svg_text, size):
    """An SVG drawn at size pixels (twice that for HiDPI, GTK scales it down)."""
    loader = GdkPixbuf.PixbufLoader.new_with_type("svg")
    loader.set_size(size, size)
    loader.write(svg_text.encode())
    loader.close()
    return Gdk.Texture.new_for_pixbuf(loader.get_pixbuf())


class Icons:
    """Lucide icons in the palette's colours, made once per colour and size."""
    def __init__(self):
        self.palette = look.PALETTE["light"]
        self.cache = {}

    def get(self, name, color="accent", size=16, stroke=2.0):
        key = (name, self.palette[color], size, stroke)
        if key not in self.cache:
            self.cache[key] = texture(look.svg(name, self.palette[color], size * 2, stroke), size * 2)
        return self.cache[key]

    def image(self, name, color="accent", size=16, stroke=2.0):
        img = Gtk.Image.new_from_paintable(self.get(name, color, size, stroke))
        img.set_pixel_size(size)
        img._icon = (name, color, size, stroke)   # redrawn when the palette changes
        return img

    def recolor(self, widget):
        """Every icon under widget again, in the palette now in use."""
        if isinstance(widget, Gtk.Image) and hasattr(widget, "_icon"):
            widget.set_from_paintable(self.get(*widget._icon))
        child = widget.get_first_child()
        while child:
            self.recolor(child)
            child = child.get_next_sibling()


ICONS = Icons()


def label(text="", *classes, xalign=0.0, wrap=False, ellipsize=False, selectable=False):
    lbl = Gtk.Label(label=text, xalign=xalign)
    for c in classes:
        lbl.add_css_class(c)
    if wrap:   # the window's width decides where it breaks, not the text's length
        lbl.set_max_width_chars(36)
        lbl.set_wrap(True)
        lbl.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
        lbl.set_justify(Gtk.Justification.CENTER if xalign == 0.5 else Gtk.Justification.LEFT)
    if ellipsize:
        lbl.set_ellipsize(Pango.EllipsizeMode.END)
        lbl.set_single_line_mode(True)
    lbl.set_selectable(selectable)
    return lbl


def button(text=None, icon=None, *classes, tooltip=None, on=None):
    b = Gtk.Button()
    b.add_css_class("fb")   # Ferry's own buttons: the window's title bar keeps the desktop's
    if icon and text:
        box = Gtk.Box(spacing=6, halign=Gtk.Align.CENTER)
        box.append(ICONS.image(icon, "on_primary" if "primary" in classes else "accent"))
        box.append(label(text))
        b.set_child(box)
    elif icon:
        b.set_child(ICONS.image(icon, "accent"))
    else:
        b.set_label(text)
    for c in classes:
        b.add_css_class(c)
    if tooltip:
        b.set_tooltip_text(tooltip)
    if on:
        b.connect("clicked", lambda *_: on())
    return b


def faded(scroller, child):
    """The list's rows fade out under the device and the buttons while it scrolls, as in Nightdrive's menu, and the
    last one can scroll out from under the fade."""
    fade = Gtk.Box(valign=Gtk.Align.END, can_target=False, visible=False)
    fade.add_css_class("fade")
    over = Gtk.Overlay(child=scroller)
    over.add_overlay(fade)

    def changed(a):
        scrolls = a.get_upper() > a.get_page_size() + 1
        fade.set_visible(scrolls)
        # After this allocation: a margin changed in the middle of one upsets GTK's (Gtk-CRITICAL)
        GLib.idle_add(lambda: child.set_margin_bottom(40 if scrolls else 0) and False)
    scroller.get_vadjustment().connect("changed", changed)
    return over


def gutter(scroller, child):
    """Room on the right for the scrollbar while the list scrolls: inside the window's margin it would lie over the
    rows' buttons. Without scrolling the rows line up with what's above and below them."""
    adj = scroller.get_vadjustment()
    adj.connect("changed", lambda a: child.set_margin_end(10 if a.get_upper() > a.get_page_size() + 1 else 0))


def menu_popover(entries, parent=None):
    """A popover of plain rows (title, action or None for a dim line, or "-" for a line between), in Ferry's look."""
    pop = Gtk.Popover()
    pop.add_css_class("ferry")
    pop.set_has_arrow(False)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
    for entry in entries:
        if entry == "-":
            box.append(Gtk.Separator())
            continue
        title, action = entry[0], entry[1]
        b = Gtk.Button()
        b.add_css_class("fb")
        b.add_css_class("menuitem")
        b.set_child(label(title, *(entry[2:] if len(entry) > 2 else ())))
        if action is None:
            b.set_sensitive(False)
        else:
            b.connect("clicked", lambda _b, a=action: (pop.popdown(), a()))
        box.append(b)
    pop.set_child(box)
    if parent:
        pop.set_parent(parent)
    return pop


def fresh_popover(menu_button, make):
    """A menu button's popover made anew each time it opens, so it shows what is true now."""
    def create(mb):
        pop = make()
        pop.connect("closed", lambda *_: GLib.idle_add(lambda: mb.set_popover(None) and False))
        mb.set_popover(pop)
    menu_button.set_create_popup_func(create)


# --- The window -----------------------------------------------------------------------------------------------------
class Window(Gtk.ApplicationWindow):
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
        self.set_icon_name(core.APP_ID)
        self.data = None             # core.listing(), the last one
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
        self.update = None           # a newer release, from core.check_update()
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

        self.devices_page = devices_page.DevicesPage(sys.modules[__name__], self.refresh)
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
                   (f"Ferry {core.VERSION}", None, "dim")]
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
        background(core.listing, done)

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
            background(core.publish, done)

    def mark_seen(self):
        """What arrived is seen once the window shows it: the tray's count goes, and a desktop's menu hears of it."""
        if not (self.data and self.is_active() and self.get_visible() and self.page == "main"):
            return
        if any(i.get("to") == "computer" and not i.get("seen") for i in self.data.get("items") or []):
            for i in self.data["items"]:
                i["seen"] = True
            background(lambda: (core.mark_seen(), core.changed()), lambda _: self.app.recount())

    # MARK: Drawing

    def step(self):
        step = (self.data or {}).get("setup")
        if step and step["step"] == "not-published" and self.refused:
            return self.refused
        return step

    def render(self):
        data = self.data
        step = self.step() if data else None
        items = look.received((data or {}).get("items") or [])
        main = self.page == "main"

        # The section's title
        if self.page == "add":
            title = "ADD DEVICE"
        elif self.page == "devices":
            title = "DEVICES"
        elif self.page == "offer":
            title = "SEND TO"
        elif step or not data:
            title = "FERRY"
        elif self.dragging:
            title = "DROP TO SEND"
        else:
            title = "RECEIVED"
        self.section.set_label(title)
        self.back.set_visible(not main)
        # The back button's own padding is the bar's margin: its chevron where the section's title starts elsewhere
        self.title_bar.set_margin_start(8 if main else 0)
        clearing = main and not step and not self.dragging and bool(items)
        self.clear_button.set_visible(clearing and not self.confirming)
        for w in (self.question, self.clear_cancel, self.clear_yes):
            w.set_visible(clearing and self.confirming)
        self.question.set_label(look.clear_question(len(items)))

        # The page
        if self.page == "add":
            self.fill_add()
            self.stack.set_visible_child_name("add")
        elif self.page == "devices":
            self.devices_page.fill(data)
            self.stack.set_visible_child_name("devices")
        elif self.page == "offer" or (self.dragging and not step):
            self.fill_tiles()
            self.stack.set_visible_child_name("tiles")
        elif not data:
            self.show_step({"step": "not-published", "title": "Looking for Tailscale…", "text": ""}, spinner=True)
        elif step:
            self.show_step(step)
        elif items:
            self.fill_list(items)
            self.stack.set_visible_child_name("list")
        else:
            self.stack.set_visible_child_name("empty")

        # The update
        self.banner.set_visible(bool(self.update) or bool(self.update_error) or self.updating)
        if self.updating:
            self.banner_text.set_label(f"Updating to Ferry {self.update['version']}…")
        elif self.update_error:
            self.banner_text.set_label(self.update_error)
        elif self.update:
            self.banner_text.set_label(f"Ferry {self.update['version']} is out.")
        self.banner_button.set_visible(bool(self.update) and not self.updating)
        self.banner_button.set_label("Try Again" if self.update_error else "Update")

        # Sending
        devices = (data or {}).get("devices") or []
        target = next((d for d in devices if d["id"] == (data or {}).get("target")), None)
        self.pill_dot.set_visible(bool(target))
        if target:
            self.pill_name.set_label(target["name"])
            self.pill_name.remove_css_class("dim")
            if target.get("online"):
                self.pill_dot.remove_css_class("away")
            else:
                self.pill_dot.add_css_class("away")
            self.pill.set_tooltip_text(f"Send to {target['name']}: change device")
        else:
            self.pill_name.set_label("No devices yet")
            self.pill_name.add_css_class("dim")
            self.pill.set_tooltip_text("Add a device")
        busy = self.send_state[0] == "sending"
        blocked = bool(step) or not data
        for w in (self.pill, self.aa, self.plus):
            w.set_sensitive(not busy and not blocked)
        self.clip.set_sensitive(not busy and not blocked)
        state = self.send_state
        self.clip_label.set_label({"idle": "Send Clipboard", "sending": "Sending…", "nothing": "Nothing on the clipboard",
                                   "failed": "Try Again"}.get(state[0]) or f"Sent to {state[1]} ✓")
        self.clip_icon.set_visible(state[0] not in ("sent",))
        self.clip_icon._icon = ("refresh-cw" if state[0] == "failed" else "clipboard-paste", "on_primary", 16, 2.0)
        self.clip_icon.set_from_paintable(ICONS.get(*self.clip_icon._icon))
        self.error.set_visible(state[0] == "failed")
        if state[0] == "failed":
            self.error.set_label(state[1])

    def show_step(self, step, spinner=False):
        box = self.step_box
        self.stack.set_visible_child_name("setup")
        if self.unchanged("setup", (step, self.note, self.acting, spinner)):
            return
        while box.get_first_child():
            box.remove(box.get_first_child())
        box.append(ICONS.image(look.STEP_ICONS.get(step["step"], "triangle-alert"), "accent", 30, 1.6))
        box.append(label(step["title"], "title-step", xalign=0.5, wrap=True))
        if step.get("text"):
            box.append(label(step["text"], "dim", xalign=0.5, wrap=True, selectable=True))
        if self.note:
            box.append(label(self.note, "away", xalign=0.5, wrap=True, selectable=True))
        if step.get("command"):
            row = Gtk.Box(spacing=8)
            row.add_css_class("command")
            cmd = label(step["command"], "mono", selectable=True, wrap=True)
            cmd.set_hexpand(True)
            row.append(cmd)
            row.append(button(None, "copy", "small-circle", tooltip="Copy",
                              on=lambda c=step["command"]: background(lambda: core.copy_text(c))))
            box.append(row)
        buttons = Gtk.Box(spacing=8, halign=Gtk.Align.CENTER)
        buttons.set_margin_top(4)
        if step.get("link"):
            title = look.LINK_TITLES.get(step["step"], "Open in Browser")
            buttons.append(button(title, None, *(() if step.get("action") else ("primary",)),
                                  on=lambda u=step["link"]: self.open_uri(u)))
        action = step.get("action")
        if action and not (action == "publish" and step["step"] == "not-published"):
            buttons.append(button(look.ACTION_TITLES[action], None, "primary",
                                  on=lambda a=action: self.run_action(a)))
        if buttons.get_first_child():
            box.append(buttons)
        if spinner or self.acting or step["step"] == "not-published":
            sp = Gtk.Spinner()
            sp.start()
            box.append(sp)
        for b in self.walk(buttons):
            if isinstance(b, Gtk.Button):
                b.set_sensitive(not self.acting)

    def unchanged(self, page, what):
        """Whether the page already shows what: refreshes come every few seconds, and building a page again flickers
        and takes the focus away from its button."""
        if self.shown.get(page) == what:
            return True
        self.shown[page] = what
        return False

    def walk(self, w):
        child = w.get_first_child()
        while child:
            yield child
            yield from self.walk(child)
            child = child.get_next_sibling()

    def fill_list(self, items):
        ids = [i["id"] for i in items]
        if ids == [getattr(r, "item", {}).get("id") for r in self.list_rows()]:
            for item in items:   # only the ages move
                self.rows[item["id"]][1].set_label(look.meta(item))
            return
        while self.list.get_first_child():
            self.list.remove(self.list.get_first_child())
        self.rows = {}
        for item in items:
            self.list.append(self.make_row(item))

    def list_rows(self):
        child = self.list.get_first_child()
        while child:
            yield child
            child = child.get_next_sibling()

    def make_row(self, item):
        row = Gtk.ListBoxRow()
        row.item = item
        box = Gtk.Box(spacing=10)
        is_file = item.get("kind") == "file"

        tile = Gtk.Box(halign=Gtk.Align.START, valign=Gtk.Align.CENTER)
        tile.set_size_request(36, 36)
        tile.set_overflow(Gtk.Overflow.HIDDEN)   # a thumbnail's corners too
        tile.add_css_class("tile")
        icon = ICONS.image(look.item_icon(item), "accent", 16)
        icon.set_halign(Gtk.Align.CENTER)
        icon.set_valign(Gtk.Align.CENTER)
        icon.set_size_request(36, 36)
        tile.append(icon)
        box.append(tile)
        if look.is_image(item) and item.get("path"):
            self.thumbnail(item, tile)

        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, valign=Gtk.Align.CENTER)
        text.set_hexpand(True)
        code = None if is_file else look.code(item.get("text"))
        title = label(code or (item.get("name") or "file" if is_file else look.oneline(item.get("text"))),
                      "code" if code else "item", ellipsize=True)
        title.set_max_width_chars(1)   # the row's width, not the text's, decides
        title.set_hexpand(True)
        row.title = title
        meta = label(look.meta(item), "meta", ellipsize=True)
        meta.set_max_width_chars(1)
        text.append(title)
        text.append(meta)
        box.append(text)

        action = button(None, "external-link" if is_file else "copy", "small-circle",
                        tooltip="Open" if is_file else "Copy",
                        on=lambda: self.open_file(item) if is_file else self.copy(item, row))
        action.set_valign(Gtk.Align.CENTER)
        box.append(action)
        row.set_child(box)
        row.set_tooltip_text(None if is_file else (item.get("text") or "")[:400])

        menu_click = Gtk.GestureClick(button=Gdk.BUTTON_SECONDARY)
        menu_click.connect("pressed", lambda g, _n, x, y: self.row_menu(row, item, x, y))
        row.add_controller(menu_click)

        drag = Gtk.DragSource(actions=Gdk.DragAction.COPY)
        drag.connect("prepare", lambda *_: self.drag_out(item))
        drag.connect("drag-begin", lambda src, _d: src.set_icon(Gtk.WidgetPaintable.new(tile), 18, 18))
        row.add_controller(drag)

        self.rows[item["id"]] = (row, meta)
        return row

    def thumbnail(self, item, tile):
        def show(tex):
            if tex is None:
                return
            self.thumbs[item["id"]] = tex
            while tile.get_first_child():
                tile.remove(tile.get_first_child())
            pic = Gtk.Image.new_from_paintable(tex)
            pic.set_pixel_size(36)
            tile.append(pic)
        if item["id"] in self.thumbs:
            return show(self.thumbs[item["id"]])

        def make():
            """The image's middle square, at twice the tile's size for HiDPI."""
            pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(item["path"], 256, 256, True)   # not a whole photo in memory
            side = min(pb.get_width(), pb.get_height())
            square = pb.new_subpixbuf((pb.get_width() - side) // 2, (pb.get_height() - side) // 2, side, side)
            return Gdk.Texture.new_for_pixbuf(square.scale_simple(72, 72, GdkPixbuf.InterpType.BILINEAR))
        background(make, show)

    def row_menu(self, row, item, x, y):
        if item.get("kind") == "file":
            entries = [("Open", lambda: self.open_file(item)),
                       ("Show in Files", lambda: background(lambda: core.show_in_files(item["path"])))]
        else:
            entries = [("Copy", lambda: self.copy(item, row))]
            if look.link(item.get("text")):
                entries.append(("Open Link", lambda: self.open_uri(look.link(item["text"]))))
        entries += ["-", ("Remove", lambda: self.remove(item), "away")]
        pop = menu_popover(entries, row)
        rect = Gdk.Rectangle()
        rect.x, rect.y, rect.width, rect.height = int(x), int(y), 1, 1
        pop.set_pointing_to(rect)
        pop.connect("closed", lambda p: GLib.idle_add(p.unparent))
        pop.popup()

    def drag_out(self, item):
        """A file drags out into a file manager or another app; a text as text."""
        if item.get("kind") == "file":
            if not os.path.exists(item.get("path", "")):
                self.refresh()
                return None
            return Gdk.ContentProvider.new_for_value(Gdk.FileList.new_from_list([Gio.File.new_for_path(item["path"])]))
        return Gdk.ContentProvider.new_for_value(item.get("text") or "")

    def fill_tiles(self):
        self.offered_label.set_visible(self.page == "offer")
        if self.offered:
            size = sum(os.path.getsize(p) for p in self.offered if os.path.isfile(p))
            self.offered_label.set_label(f"{look.what(self.offered)} · {look.human(size)}")
        while self.tiles.get_first_child():
            self.tiles.remove(self.tiles.get_first_child())
        devices = look.tiles((self.data or {}).get("devices") or [])
        if not devices:
            self.tiles.append(label("No devices to send to yet: add one with Add Device.", "dim", xalign=0.5,
                                    wrap=True))
            return
        for d in devices:
            tile = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, valign=Gtk.Align.FILL)
            tile.add_css_class("device")
            inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, valign=Gtk.Align.CENTER, vexpand=True)
            inner.append(ICONS.image(look.device_icon(d), "accent", 26, 1.6))
            name = label(d["name"], "mono", xalign=0.5, ellipsize=True)
            name.set_max_width_chars(1)
            name.set_hexpand(True)
            inner.append(name)
            tile.append(inner)
            tile.set_size_request(-1, 96)
            open_ = look.can_take(d) and self.send_state[0] != "sending"
            if not open_:
                tile.add_css_class("closed")
            tile.set_tooltip_text(f"Send to {d['name']}")
            if open_:
                target = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.COPY)
                target.connect("enter", lambda *_ , t=tile: (t.add_css_class("over"), Gdk.DragAction.COPY)[1])
                target.connect("leave", lambda *_, t=tile: t.remove_css_class("over"))
                target.connect("drop", lambda _t, value, *_r, d=d: self.dropped(value, d))
                tile.add_controller(target)
                click = Gtk.GestureClick()
                click.connect("released", lambda *_, d=d: self.tile_clicked(d))
                tile.add_controller(click)
                tile.set_cursor(Gdk.Cursor.new_from_name("pointer"))
            self.tiles.append(tile)

    def fill_add(self):
        box = self.add_box
        address = (self.data or {}).get("url")
        if self.unchanged("add", address):
            return
        while box.get_first_child():
            box.remove(box.get_first_child())
        if not address:
            box.append(label("This computer has no address on your tailnet yet: Ferry's setup says what's missing.",
                             "dim", xalign=0.5, wrap=True))
            return
        qr = Gtk.Box(halign=Gtk.Align.CENTER)
        qr.add_css_class("qr")
        pic = Gtk.Picture()
        pic.set_size_request(200, 200)
        pic.set_can_shrink(False)
        qr.append(pic)
        box.append(qr)

        def made(tex):
            if tex:
                pic.set_paintable(tex)
            else:
                qr.set_visible(False)
        background(lambda: qr_texture(core.add_link(address)), made)
        row = Gtk.Box(spacing=8, halign=Gtk.Align.CENTER)
        addr = label(address, "mono", "dim", selectable=True)
        addr.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        row.append(addr)
        copy = button("Copy", None, "pill")
        copy.connect("clicked", lambda b: (background(lambda: core.copy_text(address)), b.set_label("Copied"),
                                           GLib.timeout_add(1500, lambda: b.set_label("Copy") and False)))
        row.append(copy)
        box.append(row)
        box.append(label("Scan this with your iPhone's Camera, or in the Ferry app (Add a Computer). On another phone, "
                         "the camera opens a page that leads to this computer's Ferry page: add that to the Home Screen.",
                         "dim", xalign=0.5, wrap=True))

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
            with core.box(write=True) as items:
                for it in [i for i in items if i.get("to") == "computer"]:
                    core.drop_file(it)
                    items.remove(it)
            core.changed()
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
        background(lambda: core.copy_text(item.get("text") or "", sensitive=core.secret(item)) and core.copied(item),
                   lambda _: core.secret(item) and self.refresh())
        if row is not None:
            title = row.title
            old, classes = title.get_label(), title.get_css_classes()
            title.set_label("Copied")
            title.set_css_classes(["copied"])
            GLib.timeout_add(1500, lambda: (title.set_label(old), title.set_css_classes(classes)) and False)

    def open_file(self, item):
        if not os.path.exists(item.get("path", "")):
            return self.refresh()   # moved or deleted: its row goes
        background(lambda: core.open_path(item["path"]))

    def open_uri(self, uri):
        try:
            Gio.AppInfo.launch_default_for_uri(uri, None)
        except GLib.Error:
            background(lambda: subprocess.run(["xdg-open", uri], env=core.desktop_env()))

    def remove(self, item):
        background(lambda: (core.remove(item["id"]), core.changed()), lambda _: self.refresh())

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
                return ("publish", core.publish())
            if action == "enable":
                return ("enable", core.enable())
            if action == "tailscale-up":
                r = subprocess.run(["tailscale", "up"], capture_output=True, text=True, timeout=60)
                return ("up", (r.stdout + r.stderr).strip() if r.returncode else "")
            if action == "operator":
                exe = core.shutil.which("tailscale") or "tailscale"
                r = subprocess.run(["pkexec", exe, "set", f"--operator={user}"], capture_output=True, text=True)
                if r.returncode == 0:
                    return ("publish", core.publish())
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
        background(lambda: core.set_target(device["id"]))

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
                background(core.paste_text, lambda t: self.send(("text", t, True)) if t and t.strip()
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
                return core.deliver(device, text=payload, clip=clip)
            return core.deliver(device, files=payload, clip=clip)
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
                return ("ok", core.check_update(max_age=None if force else UPDATE_EVERY))
            except (OSError, ValueError) as e:
                return ("error", str(e))

        def done(result):
            kind, value = result or ("error", "")
            if kind == "ok":
                self.update, self.update_error = value, ""
                if force and not value:
                    self.flash(f"Ferry {core.VERSION} is the latest.")
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
        exe = os.path.join(core.ROOT, "bin", "ferry")

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


def qr_texture(text):
    """Add Device's QR code (qrencode, which the install script brings), black on white for any camera."""
    try:
        png = subprocess.run(["qrencode", "-t", "PNG", "-s", "8", "-m", "0", "-o", "-", text],
                             capture_output=True, timeout=10, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return Gdk.Texture.new_from_bytes(GLib.Bytes.new(png))


# --- The tray icon (StatusNotifierItem) -----------------------------------------------------------------------------
SNI_XML = """<node>
<interface name="org.kde.StatusNotifierItem">
  <property name="Category" type="s" access="read"/>
  <property name="Id" type="s" access="read"/>
  <property name="Title" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="WindowId" type="i" access="read"/>
  <property name="IconName" type="s" access="read"/>
  <property name="IconPixmap" type="a(iiay)" access="read"/>
  <property name="AttentionIconName" type="s" access="read"/>
  <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
  <property name="OverlayIconName" type="s" access="read"/>
  <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
  <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/>
  <property name="Menu" type="o" access="read"/>
  <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
  <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
  <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
  <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
  <method name="ProvideXdgActivationToken"><arg name="token" type="s" direction="in"/></method>
  <signal name="NewTitle"/>
  <signal name="NewIcon"/>
  <signal name="NewToolTip"/>
  <signal name="NewStatus"><arg name="status" type="s"/></signal>
</interface>
</node>"""

MENU_XML = """<node>
<interface name="com.canonical.dbusmenu">
  <property name="Version" type="u" access="read"/>
  <property name="TextDirection" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="IconThemePath" type="as" access="read"/>
  <method name="GetLayout">
    <arg type="i" name="parentId" direction="in"/><arg type="i" name="recursionDepth" direction="in"/>
    <arg type="as" name="propertyNames" direction="in"/>
    <arg type="u" name="revision" direction="out"/><arg type="(ia{sv}av)" name="layout" direction="out"/>
  </method>
  <method name="GetGroupProperties">
    <arg type="ai" name="ids" direction="in"/><arg type="as" name="propertyNames" direction="in"/>
    <arg type="a(ia{sv})" name="properties" direction="out"/>
  </method>
  <method name="GetProperty">
    <arg type="i" name="id" direction="in"/><arg type="s" name="name" direction="in"/>
    <arg type="v" name="value" direction="out"/>
  </method>
  <method name="Event">
    <arg type="i" name="id" direction="in"/><arg type="s" name="eventId" direction="in"/>
    <arg type="v" name="data" direction="in"/><arg type="u" name="timestamp" direction="in"/>
  </method>
  <method name="EventGroup">
    <arg type="a(isvu)" name="events" direction="in"/><arg type="ai" name="idErrors" direction="out"/>
  </method>
  <method name="AboutToShow">
    <arg type="i" name="id" direction="in"/><arg type="b" name="needUpdate" direction="out"/>
  </method>
  <method name="AboutToShowGroup">
    <arg type="ai" name="ids" direction="in"/><arg type="ai" name="updatesNeeded" direction="out"/>
    <arg type="ai" name="idErrors" direction="out"/>
  </method>
  <signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
  <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
  <signal name="ItemActivationRequested"><arg type="i"/><arg type="u"/></signal>
</interface>
</node>"""

SNI_PATH = "/StatusNotifierItem"
MENU_PATH = "/MenuBar"
WATCHER = "org.kde.StatusNotifierWatcher"


def pixmap(count, size):
    """The tray icon as SNI's (width, height, ARGB32 in network byte order)."""
    desktop = os.environ.get("XDG_CURRENT_DESKTOP") or core.manager_env().get("XDG_CURRENT_DESKTOP", "")
    loader = GdkPixbuf.PixbufLoader.new_with_type("svg")
    loader.set_size(size, size)
    white = look.tray_white(desktop, config_dirs=os.environ.get("XDG_CONFIG_DIRS", ""))
    loader.write(look.tray_svg(count, size, white=white, thin="kde" in desktop.lower().split(":")).encode())
    loader.close()
    pb = loader.get_pixbuf()
    if not pb.get_has_alpha():
        pb = pb.add_alpha(False, 0, 0, 0)
    w, h, stride, pixels = pb.get_width(), pb.get_height(), pb.get_rowstride(), pb.get_pixels()
    rgba = b"".join(pixels[y * stride:y * stride + w * 4] for y in range(h))
    argb = bytearray(len(rgba))
    argb[0::4], argb[1::4], argb[2::4], argb[3::4] = rgba[3::4], rgba[0::4], rgba[1::4], rgba[2::4]
    return (w, h, bytes(argb))


class Tray:
    """Ferry's icon in the desktop's tray, over D-Bus (no GTK 3 library: GTK 4 has no tray of its own): the count of
    what arrived unseen, a click opens the window, and a menu."""
    def __init__(self, app):
        self.app = app
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION)
        # A number of its own for each start: after an update's exec the same pid would take the same name again, and
        # GNOME's tray, still holding the old icon under it, ignored the new one
        self.name = f"org.kde.StatusNotifierItem-{os.getpid()}-{time.monotonic_ns() // 1_000_000}"
        self.count = 0
        self.token = None
        self.revision = 1
        self.registered = False
        self.ids = []
        sni = Gio.DBusNodeInfo.new_for_xml(SNI_XML).interfaces[0]
        menu = Gio.DBusNodeInfo.new_for_xml(MENU_XML).interfaces[0]
        self.ids.append(self.register(SNI_PATH, sni, self.sni_call))
        self.ids.append(self.register(MENU_PATH, menu, self.menu_call))
        self.owner = Gio.bus_own_name_on_connection(self.bus, self.name, Gio.BusNameOwnerFlags.NONE, None, None)
        self.watch = Gio.bus_watch_name_on_connection(self.bus, WATCHER, Gio.BusNameWatcherFlags.NONE,
                                                      self.watcher_appeared, self.watcher_vanished)

    def register(self, path, info, handler):
        """Properties too go to handler (GDBus does that without a get_property function)."""
        def call(conn, sender, path_, iface, method, params, invocation):
            try:
                handler(iface, method, params, invocation)
            except Exception as e:
                traceback.print_exc()
                invocation.return_dbus_error("org.freedesktop.DBus.Error.Failed", str(e))
        return self.bus.register_object(path, info, call, None, None)

    def watcher_appeared(self, conn, name, owner):
        conn.call(WATCHER, "/StatusNotifierWatcher", WATCHER, "RegisterStatusNotifierItem",
                  GLib.Variant("(s)", (self.name,)), None, Gio.DBusCallFlags.NONE, -1, None, self.registered_reply)

    def registered_reply(self, conn, res):
        try:
            conn.call_finish(res)
            self.registered = True
            self.app.tray_ready(True)
        except GLib.Error as e:
            print(f"Ferry's tray icon: {e.message}", file=sys.stderr)
            self.app.tray_ready(False)

    def watcher_vanished(self, conn, name):
        """No tray yet (at login the panel may come after Ferry: the app waits a little), or the panel restarts and
        registers the icon again when it is back."""
        self.registered = False

    # MARK: The item

    def props(self):
        title = "Ferry" if not self.count else f"Ferry: {self.count} new"
        return {
            "Category": GLib.Variant("s", "Communications"),
            "Id": GLib.Variant("s", "ferry"),
            "Title": GLib.Variant("s", title),
            "Status": GLib.Variant("s", "Active"),
            "WindowId": GLib.Variant("i", 0),
            "IconName": GLib.Variant("s", ""),
            "IconPixmap": GLib.Variant("a(iiay)", [pixmap(self.count, s) for s in (22, 32, 44, 64)]),
            "AttentionIconName": GLib.Variant("s", ""),
            "AttentionIconPixmap": GLib.Variant("a(iiay)", []),
            "OverlayIconName": GLib.Variant("s", ""),
            "OverlayIconPixmap": GLib.Variant("a(iiay)", []),
            "ToolTip": GLib.Variant("(sa(iiay)ss)", ("", [], title, "")),
            "ItemIsMenu": GLib.Variant("b", False),
            "Menu": GLib.Variant("o", MENU_PATH),
        }

    def sni_call(self, iface, method, params, inv):
        if iface == "org.freedesktop.DBus.Properties":
            return self.properties(self.props(), method, params, inv)
        if method in ("Activate", "SecondaryActivate"):
            self.app.toggle_window(self.take_token())
        elif method == "ProvideXdgActivationToken":
            self.token = params.unpack()[0]
        inv.return_value(None)

    def properties(self, props, method, params, inv):
        if method == "Get":
            inv.return_value(GLib.Variant("(v)", (props[params.unpack()[1]],)))
        elif method == "GetAll":
            inv.return_value(GLib.Variant("(a{sv})", (props,)))
        else:
            inv.return_dbus_error("org.freedesktop.DBus.Error.PropertyReadOnly", "read-only")

    def take_token(self):
        token, self.token = self.token, None
        return token

    def set_count(self, n):
        if n == self.count:
            return
        self.count = n
        for signal in ("NewIcon", "NewTitle", "NewToolTip"):
            self.bus.emit_signal(None, SNI_PATH, "org.kde.StatusNotifierItem", signal, None)

    # MARK: The menu (com.canonical.dbusmenu)

    def entries(self):
        # The panel hands over an activation token before a click on its menu too (Ubuntu's AppIndicator): the items
        # that show the window present it with that, or GNOME shows "Ferry is ready" and a busy pointer instead
        return [(1, "Open Ferry", lambda: self.app.toggle_window(self.take_token())),
                (2, "Send Clipboard", self.app.send_clipboard),
                (3, "Add Device…", lambda: self.app.window_page("add", self.take_token())), (4, None, None),
                (5, "Quit Ferry", self.app.quit)]

    def item(self, id_, text):
        p = {"type": GLib.Variant("s", "separator")} if text is None else \
            {"label": GLib.Variant("s", text), "enabled": GLib.Variant("b", True), "visible": GLib.Variant("b", True)}
        return p

    def layout(self):
        children = [GLib.Variant("(ia{sv}av)", (i, self.item(i, t), [])) for i, t, _ in self.entries()]
        return (0, {"children-display": GLib.Variant("s", "submenu")}, children)

    def menu_call(self, iface, method, params, inv):
        if iface == "org.freedesktop.DBus.Properties":
            props = {"Version": GLib.Variant("u", 3), "TextDirection": GLib.Variant("s", "ltr"),
                     "Status": GLib.Variant("s", "normal"), "IconThemePath": GLib.Variant("as", [])}
            return self.properties(props, method, params, inv)
        if method == "GetLayout":
            inv.return_value(GLib.Variant("(u(ia{sv}av))", (self.revision, self.layout())))
        elif method == "GetGroupProperties":
            ids = params.unpack()[0]
            out = [(i, self.item(i, t)) for i, t, _ in self.entries() if not ids or i in ids]
            inv.return_value(GLib.Variant("(a(ia{sv}))", (out,)))
        elif method == "GetProperty":
            id_, name = params.unpack()
            props = next((self.item(i, t) for i, t, _ in self.entries() if i == id_), {})
            inv.return_value(GLib.Variant("(v)", (props.get(name, GLib.Variant("s", "")),)))
        elif method == "Event":
            id_, event = params.unpack()[:2]
            if event == "clicked":
                for i, _t, act in self.entries():
                    if i == id_ and act:
                        later(act)
            inv.return_value(None)
        elif method == "EventGroup":
            for id_, event, _d, _t in params.unpack()[0]:
                if event == "clicked":
                    for i, _t2, act in self.entries():
                        if i == id_ and act:
                            later(act)
            inv.return_value(GLib.Variant("(ai)", ([],)))
        elif method == "AboutToShow":
            inv.return_value(GLib.Variant("(b)", (False,)))
        elif method == "AboutToShowGroup":
            inv.return_value(GLib.Variant("(aiai)", ([], [])))
        else:
            inv.return_value(None)

    def close(self):
        for i in self.ids:
            self.bus.unregister_object(i)
        Gio.bus_unwatch_name(self.watch)
        Gio.bus_unown_name(self.owner)


# --- The app --------------------------------------------------------------------------------------------------------
class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=core.APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.window = None
        self.tray = None           # the tray icon, once a tray took it
        self.trying_tray = None
        self.provider = Gtk.CssProvider()
        self.dark = None
        self.theme = None          # Nightdrive's theme file, watched for a change of theme
        self.monitor = None
        self.recount_pending = False

    def do_startup(self):
        Gtk.Application.do_startup(self)
        load_fonts()
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), self.provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.follow_appearance()
        Gtk.Window.set_default_icon_name(core.APP_ID)
        # The box's changes, for the tray's count: items.json is replaced on every write
        os.makedirs(core.STATE, mode=0o700, exist_ok=True)
        self.monitor = Gio.File.new_for_path(core.STATE).monitor_directory(Gio.FileMonitorFlags.NONE, None)
        self.monitor.connect("changed", self.state_changed)

    def do_command_line(self, cmdline):
        args = cmdline.get_arguments()[1:]
        files = [cmdline.create_file_for_arg(a).get_path() for a in args if not a.startswith("--")]
        self.start_tray()
        if "--background" in args and not files:   # the login item: the tray icon only
            return 0
        self.show_window()
        if files:
            self.window.offer([f for f in files if f])
        for a in args:
            if a.startswith("--show="):
                GLib.timeout_add(1500, lambda w=a[7:]: self.window.show_for_test(w) and False)
        return 0

    # MARK: Light and dark

    def follow_appearance(self):
        """The desktop's light or dark: the settings portal's color-scheme (GNOME, KDE and others), else GTK's own.
        On Nightdrive its theme's colours, again when the theme changes."""
        if HYPRLAND:
            self.theme = Gio.File.new_for_path(look.NIGHTDRIVE_THEME).monitor_file(Gio.FileMonitorFlags.NONE, None)
            self.theme.connect("changed", lambda *_: self.restyle())
        try:
            bus = Gio.bus_get_sync(Gio.BusType.SESSION)
            self.portal = Gio.DBusProxy.new_sync(bus, Gio.DBusProxyFlags.NONE, None, "org.freedesktop.portal.Desktop",
                                                 "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings")
            self.portal.connect("g-signal", self.portal_signal)
            v = self.portal.call_sync("ReadOne", GLib.Variant("(ss)", ("org.freedesktop.appearance", "color-scheme")),
                                      Gio.DBusCallFlags.NONE, 2000, None).unpack()[0]
            self.set_dark(v == 1)
            return
        except GLib.Error:
            pass
        settings = Gtk.Settings.get_default()
        name = (settings.get_property("gtk-theme-name") or "").lower()
        self.set_dark(settings.get_property("gtk-application-prefer-dark-theme") or name.endswith("dark"))

    def portal_signal(self, proxy, sender, signal, params):
        if signal == "SettingChanged":
            ns, key, value = params.unpack()
            if (ns, key) == ("org.freedesktop.appearance", "color-scheme"):
                self.set_dark(value == 1)

    def set_dark(self, dark):
        dark = bool(dark)
        if dark == self.dark:
            return
        self.dark = dark
        self.restyle()

    def restyle(self):
        palette = (HYPRLAND and look.nightdrive_palette()) or look.PALETTE["dark" if self.dark else "light"]
        ICONS.palette = palette
        Gtk.Settings.get_default().set_property("gtk-application-prefer-dark-theme", bool(self.dark))
        if hasattr(self.provider, "load_from_string"):   # GTK 4.12
            self.provider.load_from_string(look.css(palette))
        else:
            self.provider.load_from_data(look.css(palette), -1)
        if self.window:
            ICONS.recolor(self.window)

    # MARK: The window

    def show_window(self):
        if not self.window:
            self.window = Window(self)
            self.window.set_hide_on_close(bool(self.tray))
            self.window.connect("close-request", self.window_closing)
        self.window.present()

    def window_closing(self, _w):
        if not self.tray:
            self.window = None
        return False

    def toggle_window(self, token=None):
        if self.window and self.window.get_visible() and self.window.is_active():
            self.window.set_visible(False)
            return
        self.show_window() if not token else self.present_with(token)

    def present_with(self, token):
        """The panel's activation token lets a Wayland desktop bring the window to the front."""
        if not self.window:
            self.show_window()
        self.window.set_startup_id(token)
        self.window.present()

    def window_page(self, page, token=None):
        self.show_window() if not token else self.present_with(token)
        self.window.show_page(page)

    def send_clipboard(self):
        """From the tray's menu, without the window in front: the desktop's clipboard tools (core's), a text."""
        def work():
            text = core.paste_text()
            if not (text or "").strip():
                core.notify("The clipboard has no text", "Copy a text or a link first")
                return
            devs = core.devices()
            dev = core.target(devs)
            if not dev:
                core.notify("Couldn't send", "No device to send to: add one with Add Device")
                return
            err = core.deliver(dev, text=text, clip=True)
            core.notify("Couldn't send" if err else f"Sent to {dev['name']}", err or look.oneline(text)[:120])
        background(work)

    # MARK: The tray

    def start_tray(self):
        """The tray icon, if the desktop has a tray. In the background (the login item) the app holds on only while
        the icon is in a tray: give the panel a few seconds to appear at login."""
        if self.tray or self.trying_tray:
            return
        if not core.tray_wanted():   # `ferry tray off`: e.g. Nightdrive, whose top bar has Ferry's menu
            return
        self.hold()
        try:
            self.trying_tray = Tray(self)
        except GLib.Error as e:
            print(f"Ferry's tray icon: {e.message}", file=sys.stderr)
            self.trying_tray = None
            self.release()
            return
        GLib.timeout_add_seconds(15, self.tray_timeout)

    def tray_timeout(self):
        if self.trying_tray and not self.tray:
            self.tray_ready(False)
        return False

    def tray_ready(self, ok):
        if ok and self.trying_tray:
            self.tray = self.trying_tray
            self.tray.set_count(self.unseen())
            if self.window:
                self.window.set_hide_on_close(True)
            return
        if self.tray is None and self.trying_tray:
            self.trying_tray.close()
            self.trying_tray = None
            self.release()   # no tray here: the app lives as long as its window

    def unseen(self):
        try:
            with core.box() as items:
                return sum(1 for i in items if i.get("to") == "computer" and not i.get("seen"))
        except OSError:
            return 0

    def recount(self):
        if self.tray:
            self.tray.set_count(self.unseen())

    def state_changed(self, _m, f, _other, event):
        if f.get_basename() != "items.json" or self.recount_pending:
            return
        self.recount_pending = True

        def run():
            self.recount_pending = False
            self.recount()
            if self.window and self.window.get_visible():
                self.window.refresh()
            return False
        GLib.timeout_add(300, run)

    def restart(self):
        """After an update: the new Ferry's app in this one's place, its window shown."""
        exe = os.path.join(core.ROOT, "bin", "ferry")
        if self.tray:
            self.tray.close()
        os.execv(sys.executable, [sys.executable, exe, "app"])


def main(ferry, args):
    global core
    core = ferry
    GLib.set_prgname(core.APP_ID)
    GLib.set_application_name("Ferry")
    if not Gtk.init_check() or Gdk.Display.get_default() is None:
        print("Ferry's window needs a desktop: in a terminal, `ferry help` says what the ferry command does",
              file=sys.stderr)
        return 1
    return App().run([sys.argv[0]] + args)
