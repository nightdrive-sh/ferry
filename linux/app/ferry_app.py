"""Ferry's window and tray icon on Linux: the Mac app's popover as a GTK 4 window, in Ferry's own colours.

`ferry app` runs it: everything the window shows and does is the ferry package's (the box, the devices, the setup
steps, sending, updates), so a desktop's own menu (`ferry list --json`) and the `ferry` command say and do the same.
These files only draw it and run it off the main loop: this one is the app (one instance, the tray, the look),
window.py the window (its pages in pages.py, what they do in actions.py), widgets.py its parts, tray.py the tray icon.

One instance per user (a GtkApplication): Open With, the app list and the tray all reach the running one. With a tray
(a StatusNotifierWatcher on the session bus: KDE, Ubuntu's GNOME, Cinnamon, XFCE, Waybar) closing the window hides it;
without one, it quits, and `--background` (the login item) quits at once."""
import os
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, Gio, GLib, Gtk  # noqa: E402

import look  # noqa: E402
from ferry import computers, config, desktop, install, notices, store  # noqa: E402
from tray import Tray  # noqa: E402
from widgets import background, HYPRLAND, ICONS, load_fonts  # noqa: E402
from window import Window  # noqa: E402


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=config.APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
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
        Gtk.Window.set_default_icon_name(config.APP_ID)
        # The box's changes, for the tray's count: items.json is replaced on every write
        os.makedirs(config.STATE, mode=0o700, exist_ok=True)
        self.monitor = Gio.File.new_for_path(config.STATE).monitor_directory(Gio.FileMonitorFlags.NONE, None)
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
        """From the tray's menu, without the window in front: the desktop's clipboard tools (the package's), a text."""
        def work():
            text = desktop.paste_text()
            if not (text or "").strip():
                notices.notify("The clipboard has no text", "Copy a text or a link first")
                return
            devs = computers.devices()
            dev = computers.target(devs)
            if not dev:
                notices.notify("Couldn't send", "No device to send to: add one with Add Device")
                return
            err = computers.deliver(dev, text=text, clip=True)
            notices.notify("Couldn't send" if err else f"Sent to {dev['name']}", err or look.oneline(text)[:120])
        background(work)

    # MARK: The tray

    def start_tray(self):
        """The tray icon, if the desktop has a tray. In the background (the login item) the app holds on only while
        the icon is in a tray: give the panel a few seconds to appear at login."""
        if self.tray or self.trying_tray:
            return
        if not install.tray_wanted():   # `ferry tray off`: e.g. Nightdrive, whose top bar has Ferry's menu
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
            with store.box() as items:
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
        exe = os.path.join(config.ROOT, "bin", "ferry")
        if self.tray:
            self.tray.close()
        os.execv(sys.executable, [sys.executable, exe, "app"])


def main(args):
    GLib.set_prgname(config.APP_ID)
    GLib.set_application_name("Ferry")
    if not Gtk.init_check() or Gdk.Display.get_default() is None:
        print("Ferry's window needs a desktop: in a terminal, `ferry help` says what the ferry command does",
              file=sys.stderr)
        return 1
    return App().run([sys.argv[0]] + args)
