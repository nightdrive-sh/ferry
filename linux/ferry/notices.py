"""Notifications: over a session bus connection of Ferry's own, through PyGObject's Gio, else notify-send's.

GNOME tells only the connection that sent a notification which of its buttons was pressed, and Ubuntu's AppArmor profile
keeps notify-send from asking for buttons at all, hence a connection of our own (Notifications)."""
import contextlib
import select
import subprocess
import threading

from . import config, desktop


NOTIFICATIONS = ("org.freedesktop.Notifications", "/org/freedesktop/Notifications")   # the daemon's name, its path


class GioBus:
    """A connection of Ferry's own to the session bus at address, through PyGObject's Gio (ImportError where there is
    none), whose notification daemon's signals go to on_signal(name, args) from a GLib main loop in a thread of its
    own."""

    def __init__(self, address, on_signal):
        from gi.repository import Gio, GLib
        self.Gio, self.GLib = Gio, GLib
        # Not Gio.bus_get_sync's shared connection: that one ends the process when the bus goes (a logout), and it
        # reads the bus's address from this process's environment, which the service's may not have.
        ctx = GLib.MainContext.new()
        ctx.push_thread_default()   # a subscription's signals come to the context that is the default where it's made
        try:
            self.conn = Gio.DBusConnection.new_for_address_sync(
                address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                None, None)
            self.conn.signal_subscribe(None, NOTIFICATIONS[0], None, NOTIFICATIONS[1], None, Gio.DBusSignalFlags.NONE,
                                       lambda _c, _s, _p, _i, name, args: on_signal(name, args.unpack()))
        finally:
            ctx.pop_thread_default()
        self.loop = GLib.MainLoop.new(ctx, False)
        threading.Thread(target=self.loop.run, daemon=True).start()

    def call(self, method, args, reply):
        return self.conn.call_sync(NOTIFICATIONS[0], NOTIFICATIONS[1], NOTIFICATIONS[0], method, args,
                                   self.GLib.VariantType.new(reply), self.Gio.DBusCallFlags.NONE, int(config.NOTIFY_WAIT * 1000),
                                   None).unpack()

    def notify(self, app_icon, summary, body, actions, hints, replaces=0):
        """The Notify call (its id): actions are [key, label, …], hints strings, replaces the id of the one shown in its
        place (0: none)."""
        V = self.GLib.Variant
        return self.call("Notify", V("(susssasa{sv}i)", (config.APP, replaces, app_icon, summary, body, actions,
                                                         {k: V("s", v) for k, v in hints.items()}, -1)), "(u)")[0]

    def close(self, nid):
        self.call("CloseNotification", self.GLib.Variant("(u)", (nid,)), "()")

    def closed(self):
        return self.conn.is_closed()

    def drop(self):
        self.loop.quit()
        with contextlib.suppress(Exception):
            self.conn.close_sync(None)


class Notifications:
    """Ferry's notifications over its own connection to the session bus (connect(address, on_signal): GioBus), made
    on the first one and kept for the process's life, so that the connection that sent a notification hears its
    buttons pressed: GNOME's daemon tells that connection alone, so neither gdbus nor another process could listen.
    Made again when it fails, closes or the desktop's bus moves (a logout and login while the service runs)."""
    KEEP = 50   # notifications whose buttons are remembered: a daemon that restarted never says the old ones closed

    def __init__(self, connect=GioBus, env=None):
        self.connect = connect
        self.env = env or desktop.desktop_env
        self.bus, self.address = None, ""
        self.actions = {}                  # a notification's id: its {key: (label, function)}
        self.lock = threading.Lock()       # the actions
        self.busy = threading.Lock()       # the connection

    def _connected(self, fresh=False):
        address = desktop.session_bus(self.env())
        if self.bus and (fresh or address != self.address or self.bus.closed()):
            self.bus.drop()
            self.bus = None
        if self.bus is None and address and self.connect:
            try:
                self.bus, self.address = self.connect(address, self.signal), address
            except ImportError:
                self.connect = None   # no PyGObject: notify-send's for as long as this process runs
            except Exception:   # GLib.Error: no bus there (any more), or it wouldn't have us
                pass
        return self.bus

    def send(self, app_icon, summary, body, actions, hints, replaces=0):
        """The notification's id, or None when it couldn't be sent this way."""
        with self.busy:
            for fresh in (False, True):   # once more on a new connection: the old one may be a bus that went away
                bus = self._connected(fresh)
                if bus is None:
                    return None
                try:
                    nid = bus.notify(app_icon, summary, body, [s for k in actions for s in (k, actions[k][0])], hints,
                                     replaces)
                    break
                except Exception:   # GLib.Error: the bus went, or no daemon answers on it
                    continue
            else:
                return None
        if actions:
            with self.lock:
                self.actions[nid] = dict(actions)
                for old in list(self.actions)[:-self.KEEP]:
                    del self.actions[old]
        return str(nid)

    def close(self, nid):
        """False when it couldn't be closed this way (the notification wasn't sent this way)."""
        with self.busy:
            if self.bus is None:
                return False
            try:
                self.bus.close(int(nid))
                return True
            except Exception:
                return False

    def signal(self, name, args):
        if name == "ActionInvoked":
            with self.lock:
                action = self.actions.get(args[0], {}).get(args[1])
            if action:   # in a thread: a function that waits (the clipboard's tool) would hold up the main loop
                threading.Thread(target=action[1], daemon=True).start()
        elif name == "NotificationClosed":
            with self.lock:
                self.actions.pop(args[0], None)


notifications = Notifications()


def notify(summary, body="", actions=(), preview="", replaces=""):
    """A desktop notification (its id, or "" when none is shown); with actions, {key: (label, function)} are its
    buttons, and the pressed one's function runs in a thread. A preview (an image's path) is the notification's
    picture, as a screenshot's is. replaces is the id of one shown before, which this one takes the place of. No
    "default" action: a click on the notification opens Ferry's window, which GNOME does by the desktop-entry hint when
    there is none."""
    # Over Ferry's own D-Bus connection rather than notify-send: on Ubuntu 26.04 AppArmor's profile for notify-send
    # (/etc/apparmor.d/notify-send) lets it call only GetServerInformation and Notify, so libnotify, denied
    # GetCapabilities, drops the buttons ("Actions are not supported…"), and it couldn't hear them pressed either.
    # notify-send stays where there is no PyGObject or no session bus (a server, a desktop installed without the
    # window), and where the daemon doesn't answer this way.
    # The same as libnotify 0.8 sends: the picture as image-path (the image, else Ferry's icon), Ferry's icon as the
    # app's with a preview, and the .desktop's name, from which GNOME draws Ferry's icon over it (else a generic one).
    hints = {"desktop-entry": config.APP_ID}
    if preview:
        hints.update({"category": "transfer.complete", "image-path": desktop.file_uri(preview)})
    else:
        hints["image-path"] = config.ICON
    nid = notifications.send(config.ICON if preview else "", summary, body, actions, hints, int(replaces or 0))
    return nid if nid is not None else notify_send(summary, body, actions, preview, replaces)


def notify_send(summary, body, actions, preview, replaces=""):
    # -i is the notification's picture (libnotify 0.8): with a preview the picture is the image, and the icon goes as -n
    # The .desktop's name, from which GNOME draws Ferry's icon over the notification (else a generic one)
    cmd = ["notify-send", "-a", config.APP, "-p", "-h", f"string:desktop-entry:{config.APP_ID}"]
    if preview:
        cmd += ["-n", config.ICON, "-c", "transfer.complete", "-h", f"string:image-path:{desktop.file_uri(preview)}"]
    else:
        cmd += ["-i", config.ICON]
    if replaces:
        cmd += ["-r", str(replaces)]
    for key in actions:
        cmd += ["-A", f"{key}={actions[key][0]}"]
    if actions:
        cmd.append("--wait")
    try:
        p = subprocess.Popen(cmd + ["--", summary, body], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                             env=desktop.desktop_env())
    except OSError:
        return ""
    # The daemon's answer is the notification's id. Where there is no daemon (a server, a window manager without one),
    # libnotify 0.8's notify-send with buttons prints nothing and waits for ever: one left behind for every send.
    nid = p.stdout.readline().strip() if select.select([p.stdout], [], [], config.NOTIFY_WAIT)[0] else ""
    if not nid:
        p.kill()
        p.wait()
        p.stdout.close()
        return ""

    def wait():
        out = p.communicate()[0].strip().splitlines()
        if out and out[-1] in actions:
            actions[out[-1]][1]()
    threading.Thread(target=wait, daemon=True).start()
    return nid


def close_notification(nid):
    if notifications.close(nid):   # by the connection that sent it: GNOME's daemon takes it from no other
        return
    try:
        subprocess.run(["gdbus", "call", "--session", "--dest", "org.freedesktop.Notifications", "--object-path",
                        "/org/freedesktop/Notifications", "--method",
                        "org.freedesktop.Notifications.CloseNotification", nid], capture_output=True, timeout=5,
                       env=desktop.desktop_env())
    except (OSError, subprocess.SubprocessError):
        pass
