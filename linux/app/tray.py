"""The tray icon: a StatusNotifierItem with a dbusmenu, over Gio's D-Bus (GTK 4 has no tray), registered where a
StatusNotifierWatcher runs (KDE, Ubuntu's GNOME, Waybar…). Its count is what came in unseen; its menu opens the
window's pages."""
import os
import sys
import time
import traceback

from gi.repository import GdkPixbuf, Gio, GLib

import look
from ferry import desktop
from widgets import later


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
    current = os.environ.get("XDG_CURRENT_DESKTOP") or desktop.manager_env().get("XDG_CURRENT_DESKTOP", "")
    loader = GdkPixbuf.PixbufLoader.new_with_type("svg")
    loader.set_size(size, size)
    white = look.tray_white(current, config_dirs=os.environ.get("XDG_CONFIG_DIRS", ""))
    loader.write(look.tray_svg(count, size, white=white, thin="kde" in current.lower().split(":")).encode())
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
