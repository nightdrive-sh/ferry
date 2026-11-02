"""The window's parts and helpers, shared by its pages: work off the main loop and back, Ferry's fonts and icons,
labels and buttons, popover menus, Add Device's QR code. Nothing here knows Ferry's state."""
import ctypes.util
import os
import subprocess
import threading
import traceback

from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, Pango

import look
from ferry import config


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
        fc.FcConfigAppFontAddDir(None, config.FONTS.encode())
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


def qr_texture(text):
    """Add Device's QR code (qrencode, which the install script brings), black on white for any camera."""
    try:
        png = subprocess.run(["qrencode", "-t", "PNG", "-s", "8", "-m", "0", "-o", "-", text],
                             capture_output=True, timeout=10, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return Gdk.Texture.new_from_bytes(GLib.Bytes.new(png))
