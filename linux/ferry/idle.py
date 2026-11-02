"""How long the computer has been idle: the compositor (ext-idle-notify), Mutter, X11 or logind, in that order."""
import os
import re
import socket
import struct
import subprocess
import threading
import time

from . import config, desktop


def idle_seconds(ms):
    """api/items' idle from milliseconds since the last key press or mouse move: 0 within the last minute."""
    return 0 if ms < config.IDLE_AFTER * 1000 else int(ms // 1000)


class WaylandIdle:
    """Idle time from a Wayland compositor that has ext-idle-notify-v1 (KDE, Hyprland, Sway and others): it says when the
    user has been idle IDLE_AFTER seconds and when they're back. A small Wayland client of its own, since Python has
    none built in and this needs only the registry, a seat and the notifier. GNOME's Mutter has no such protocol; its
    D-Bus IdleMonitor answers instead (mutter_idle)."""
    NOTIFIER, SEAT = "ext_idle_notifier_v1", "wl_seat"
    REGISTRY, SYNC, SEAT_ID, NOTIFIER_ID, NOTIFICATION = 2, 3, 4, 5, 6   # the object ids this client makes

    def __init__(self, connect=None, clock=time.time):
        self.connect, self.clock = connect or self.open, clock
        self.lock = threading.Lock()
        self.since = None      # when the watch began (None: no watch)
        self.idled = None      # when the user went idle (None: in use, as far as the watch knows)

    def seconds(self):
        """Seconds idle; None when no compositor answers, or for the first minute of a watch (it can't tell yet)."""
        with self.lock:
            since, idled = self.since, self.idled
        if since is None:
            return None
        now = self.clock()
        if idled is not None:
            return max(config.IDLE_AFTER, int(now - idled))
        return 0 if now - since >= config.IDLE_AFTER else None

    @staticmethod
    def open():
        env = desktop.desktop_env()
        name = env.get("WAYLAND_DISPLAY")
        if not name:
            return None
        path = name if name.startswith("/") else os.path.join(env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}",
                                                              name)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.settimeout(5)
            s.connect(path)
            s.settimeout(None)
        except OSError:
            s.close()
            raise
        return s

    @staticmethod
    def send(s, obj, op, args=b""):
        s.sendall(struct.pack("=II", obj, (8 + len(args)) << 16 | op) + args)

    @staticmethod
    def string(text):
        b = text.encode() + b"\0"
        return struct.pack("=I", len(b)) + b + b"\0" * (-len(b) % 4)

    @staticmethod
    def receive(f):
        head = f.read(8)
        if len(head) < 8:
            raise EOFError
        obj, size_op = struct.unpack("=II", head)
        args = f.read((size_op >> 16) - 8)
        return obj, size_op & 0xFFFF, args

    def watch(self):
        """One connection, until the session ends: False when there is no compositor or it has no notifier."""
        s = self.connect()
        if not s:
            return False
        with s, s.makefile("rb") as f:
            self.send(s, 1, 1, struct.pack("=I", self.REGISTRY))     # wl_display.get_registry
            self.send(s, 1, 0, struct.pack("=I", self.SYNC))         # wl_display.sync: done after every global
            found = {}
            while True:
                obj, op, args = self.receive(f)
                if (obj, op) == (self.REGISTRY, 0):                  # wl_registry.global: name, interface, version
                    name, n = struct.unpack_from("=II", args)
                    iface = args[8:8 + n - 1].decode(errors="replace")
                    found[iface] = (name, struct.unpack_from("=I", args, 8 + n + (-n % 4))[0])
                elif (obj, op) == (self.SYNC, 0):
                    break
                elif (obj, op) == (1, 0):                            # wl_display.error
                    return False
            if self.NOTIFIER not in found or self.SEAT not in found:
                return False
            version = min(found[self.NOTIFIER][1], 2)
            self.send(s, self.REGISTRY, 0, struct.pack("=I", found[self.SEAT][0]) + self.string(self.SEAT) +
                      struct.pack("=II", 1, self.SEAT_ID))
            self.send(s, self.REGISTRY, 0, struct.pack("=I", found[self.NOTIFIER][0]) + self.string(self.NOTIFIER) +
                      struct.pack("=II", version, self.NOTIFIER_ID))
            with self.lock:   # before the request, so a compositor that has it has a watch that began
                self.since, self.idled = self.clock(), None
            # v2's get_input_idle_notification counts only input: a video that keeps the screen on isn't someone there
            self.send(s, self.NOTIFIER_ID, 2 if version >= 2 else 1,
                      struct.pack("=III", self.NOTIFICATION, config.IDLE_AFTER * 1000, self.SEAT_ID))
            try:
                while True:
                    obj, op, _ = self.receive(f)
                    if obj == self.NOTIFICATION:
                        with self.lock:
                            self.idled = self.clock() - config.IDLE_AFTER if op == 0 else None   # 0: idled, 1: resumed
                    elif (obj, op) == (1, 0):
                        break
            except (EOFError, OSError, struct.error):
                pass
            finally:
                with self.lock:
                    self.since = self.idled = None
        return True

    def run(self):
        """Watches for as long as the server runs, through sessions that end and begin."""
        while True:
            try:
                watched = self.watch()
            except (EOFError, OSError, ValueError, struct.error):
                watched = False
            time.sleep(5 if watched else 30)


WAYLAND_IDLE = WaylandIdle()


def mutter_ms(out):
    m = re.search(r"uint64 (\d+)", out or "")
    return int(m.group(1)) if m else None


def mutter_idle(env):
    """GNOME's (Wayland and X11): Mutter's IdleMonitor on D-Bus."""
    if env.get("XDG_CURRENT_DESKTOP") and "GNOME" not in env["XDG_CURRENT_DESKTOP"]:
        return None
    try:
        out = subprocess.run(["gdbus", "call", "--session", "--dest", "org.gnome.Mutter.IdleMonitor", "--object-path",
                              "/org/gnome/Mutter/IdleMonitor/Core", "--method",
                              "org.gnome.Mutter.IdleMonitor.GetIdletime"], capture_output=True, text=True, timeout=3,
                             env=env).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    ms = mutter_ms(out)
    return None if ms is None else idle_seconds(ms)


def x11_idle(env):
    """An X11 desktop's (KDE's and others' on X11): the X server's screensaver extension. Not on a Wayland desktop,
    where XWayland sees only its own windows' input."""
    if not env.get("DISPLAY") or env.get("WAYLAND_DISPLAY"):
        return None
    try:
        out = subprocess.run(["xprintidle"], capture_output=True, text=True, timeout=3, env=env).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return idle_seconds(int(out)) if out.isdigit() else None


def logind_idle(env):
    """logind's idle hint, for a desktop that sets it (Nightdrive's hypridle sets it a minute after the last input;
    others later, which makes the answer smaller than it is)."""
    try:
        sid = subprocess.run(["loginctl", "show-user", str(os.getuid()), "-p", "Display", "--value"],
                             capture_output=True, text=True, timeout=3).stdout.strip()
        if not sid:
            return None
        out = subprocess.run(["loginctl", "show-session", sid, "-p", "IdleHint", "-p", "IdleSinceHint"],
                             capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    v = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    since = int(v.get("IdleSinceHint") or 0) / 1e6
    if not since:   # never set: a desktop that doesn't tell logind (always "no" there would always win)
        return None
    if v.get("IdleHint") != "yes":
        return 0
    return max(0, int(time.time() - since + config.IDLE_AFTER))


def idle_for(env=None, sources=None):
    """Seconds since this computer was last used (0: in use), from the first source that knows; None when none does.
    The phone sends to the computer in use."""
    sources = sources or (lambda e: WAYLAND_IDLE.seconds(), mutter_idle, x11_idle, logind_idle)
    env = desktop.desktop_env() if env is None else env
    for source in sources:
        s = source(env)
        if s is not None:
            return s
    return None
