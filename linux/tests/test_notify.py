"""Notifications: sent over Ferry's own connection to the session bus, whose daemon tells that connection alone which
button was pressed, else notify-send's. Where nothing shows them (a server, a window manager without a notification
daemon) Ferry goes on without them, and the phone's send is answered without waiting for one. Run from linux/:

    python3 -m unittest discover -s tests -p test_notify.py
"""
import os
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

from load import ferry


class NotifySend(unittest.TestCase):
    """notify() against a pretend notify-send on PATH."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pids = os.path.join(self.tmp.name, "pids")
        env = {"PATH": self.tmp.name + os.pathsep + os.environ.get("PATH", ""), "WAYLAND_DISPLAY": "wayland-0"}
        patch = mock.patch.dict(os.environ, env)
        patch.start()
        self.addCleanup(patch.stop)
        wait = mock.patch.object(ferry, "NOTIFY_WAIT", 0.5)
        wait.start()
        self.addCleanup(wait.stop)
        bus = mock.patch.object(ferry, "notifications", ferry.Notifications(connect=None))   # no PyGObject
        bus.start()
        self.addCleanup(bus.stop)

    def fake(self, script):
        path = os.path.join(self.tmp.name, "notify-send")
        with open(path, "w") as f:
            f.write(f"#!/bin/sh\necho $$ >> {self.pids}\n{script}\n")
        os.chmod(path, 0o755)

    def running(self):
        with open(self.pids) as f:
            pid = int(f.read().split()[0])
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def test_the_notifications_id(self):   # a desktop: the daemon answers at once, then notify-send waits for a button
        self.fake("echo 42\nexec sleep 30")
        self.assertEqual(ferry.notify("Text from iphone", "hello", {"copy": ("Copy", lambda: None)}), "42")
        self.assertTrue(self.running())
        with open(self.pids) as f:
            os.kill(int(f.read().split()[0]), 9)

    def test_no_daemon_with_buttons(self):   # libnotify 0.8's notify-send then prints nothing and never ends
        self.fake("exec sleep 30")
        start = time.monotonic()
        self.assertEqual(ferry.notify("Text from iphone", "hello", {"copy": ("Copy", lambda: None)}), "")
        self.assertLess(time.monotonic() - start, 5)
        time.sleep(0.2)
        self.assertFalse(self.running())   # not left behind, one for every text from the phone

    def test_names_the_app(self):   # GNOME draws the app's own icon and name over the notification from its .desktop
        args = os.path.join(self.tmp.name, "args")
        self.fake(f'printf "%s\\n" "$@" > {args}\necho 7')
        ferry.notify("Copied from iphone", "hello")
        with open(args) as f:
            self.assertIn("string:desktop-entry:sh.nightdrive.Ferry", f.read().splitlines())

    def test_in_place_of_another(self):
        args = os.path.join(self.tmp.name, "args")
        self.fake(f'printf "%s\\n" "$@" > {args}\necho 7')
        ferry.notify("Received 2 files", "", replaces="7")
        with open(args) as f:
            lines = f.read().splitlines()
        self.assertEqual(lines[lines.index("-r") + 1], "7")

    def test_no_daemon(self):   # without buttons it says so and ends
        self.fake("echo 'GDBus.Error: The name org.freedesktop.Notifications was not provided' >&2\nexit 1")
        self.assertEqual(ferry.notify("Copied from iphone", "hello"), "")


class FakeBus:
    """The session bus as Notifications sees it: what was sent, and the daemon's signals sent back by hand."""

    def __init__(self, address, on_signal):
        self.address, self.on_signal, self.fail = address, on_signal, 0
        self.sent, self.closes, self.dead, self.dropped, self.replaced = [], [], False, False, []

    def notify(self, app_icon, summary, body, actions, hints, replaces=0):
        if self.fail:
            self.fail -= 1
            raise RuntimeError("The connection is closed")
        self.sent.append((app_icon, summary, body, actions, hints))
        self.replaced.append(replaces)
        return replaces or 6 + len(self.sent)

    def close(self, nid):
        self.closes.append(nid)

    def closed(self):
        return self.dead

    def drop(self):
        self.dropped = True


class Bus(unittest.TestCase):
    """notify() over Ferry's own connection: on Ubuntu 26.04 AppArmor keeps notify-send from asking for buttons and
    from hearing them pressed."""

    def setUp(self):
        self.buses = []
        self.address = "unix:path=/run/user/1000/bus"
        self.fails = 0
        self.notifications = ferry.Notifications(connect=self.connect, env=lambda: {
            "DBUS_SESSION_BUS_ADDRESS": self.address, "XDG_RUNTIME_DIR": "/nonexistent"})
        for name, value in (("notifications", self.notifications), ("ICON", "/ferry/icon-192.png")):
            p = mock.patch.object(ferry, name, value)
            p.start()
            self.addCleanup(p.stop)
        send = mock.patch.object(ferry, "notify_send", side_effect=AssertionError("notify-send"))
        self.notify_send = send.start()
        self.addCleanup(send.stop)

    def connect(self, address, on_signal):
        if self.fails:
            self.fails -= 1
            raise RuntimeError("Could not connect: No such file or directory")
        self.buses.append(FakeBus(address, on_signal))
        return self.buses[-1]

    def test_buttons_go_as_the_actions(self):
        nid = ferry.notify("Text from iphone", "hello", {"copy": ("Copy", lambda: None)})
        self.assertEqual(nid, "7")
        self.assertEqual(self.buses[0].sent, [("", "Text from iphone", "hello", ["copy", "Copy"], {
            "desktop-entry": "sh.nightdrive.Ferry", "image-path": "/ferry/icon-192.png"})])
        self.assertEqual(self.buses[0].address, "unix:path=/run/user/1000/bus")

    def test_a_preview(self):   # the image is the picture, Ferry's icon the app's
        ferry.notify("Received a.jpg", "From iphone · Downloads", {
            "open": ("Open", lambda: None), "show": ("Show in Files", lambda: None)}, "/home/j/Downloads/a b.jpg")
        self.assertEqual(self.buses[0].sent, [("/ferry/icon-192.png", "Received a.jpg", "From iphone · Downloads",
                                               ["open", "Open", "show", "Show in Files"], {
                                                   "desktop-entry": "sh.nightdrive.Ferry",
                                                   "category": "transfer.complete",
                                                   "image-path": "file:///home/j/Downloads/a%20b.jpg"})])

    def test_a_received_files_buttons(self):   # no "default" action: a click on it opens Ferry's window
        app = ferry.Ferry.__new__(ferry.Ferry)
        app.lock, app.notifying = threading.Lock(), threading.Lock()
        app.notify_files({"paths": ["/home/j/Downloads/a.pdf"], "nid": "", "shown": 0}, "application/pdf", "iphone")
        self.assertEqual(self.buses[0].sent[0][3], ["open", "Open", "show", "Show in Files"])

    def test_in_place_of_another(self):   # the daemon updates the one shown rather than adding one
        nid = ferry.notify("Received a.jpg", "")
        self.assertEqual(ferry.notify("Received 2 files", "", replaces=nid), nid)
        self.assertEqual(self.buses[0].replaced, [0, int(nid)])

    def test_one_connection(self):
        ferry.notify("Copied from iphone", "hello")
        ferry.notify("Copied from iphone", "again")
        self.assertEqual(len(self.buses), 1)
        self.assertEqual(len(self.buses[0].sent), 2)

    def test_a_pressed_button_runs_its_function_once(self):
        pressed = []
        done = threading.Event()

        def press(key):
            pressed.append(key)
            done.set()
        nid = ferry.notify("Received a.jpg", "", {"open": ("Open", lambda: press("open")),
                                                  "show": ("Show in Files", lambda: press("show"))})
        other = ferry.notify("Text from iphone", "", {"copy": ("Copy", lambda: press("copy"))})
        self.buses[0].on_signal("ActionInvoked", (int(nid), "show"))
        self.assertTrue(done.wait(5))
        time.sleep(0.1)
        self.assertEqual(pressed, ["show"])
        self.buses[0].on_signal("ActionInvoked", (int(nid) + 100, "copy"))   # another app's
        self.buses[0].on_signal("ActionInvoked", (int(other), "show"))       # not this one's button
        time.sleep(0.1)
        self.assertEqual(pressed, ["show"])

    def test_a_closed_notification_is_forgotten(self):
        pressed = []
        nid = ferry.notify("Text from iphone", "", {"copy": ("Copy", lambda: pressed.append("copy"))})
        self.buses[0].on_signal("NotificationClosed", (int(nid), 2))
        self.buses[0].on_signal("ActionInvoked", (int(nid), "copy"))
        time.sleep(0.1)
        self.assertEqual(pressed, [])
        self.assertEqual(self.notifications.actions, {})

    def test_without_buttons_nothing_is_kept(self):
        ferry.notify("Copied from iphone", "hello")
        self.assertEqual(self.notifications.actions, {})

    def test_only_the_newest_buttons_are_kept(self):   # a daemon that restarted never says the old ones closed
        for _ in range(ferry.Notifications.KEEP + 5):
            ferry.notify("Text from iphone", "", {"copy": ("Copy", lambda: None)})
        self.assertEqual(len(self.notifications.actions), ferry.Notifications.KEEP)
        self.assertIn(6 + ferry.Notifications.KEEP + 5, self.notifications.actions)
        self.assertNotIn(7, self.notifications.actions)

    def test_a_failed_send_reconnects(self):   # the desktop logged out and in while the service ran
        ferry.notify("Copied from iphone", "hello")
        self.buses[0].fail = 1
        self.assertEqual(ferry.notify("Copied from iphone", "again"), "7")
        self.assertEqual(len(self.buses), 2)
        self.assertTrue(self.buses[0].dropped)
        self.assertEqual([s[2] for s in self.buses[1].sent], ["again"])

    def test_a_closed_connection_reconnects(self):
        ferry.notify("Copied from iphone", "hello")
        self.buses[0].dead = True
        ferry.notify("Copied from iphone", "again")
        self.assertEqual(len(self.buses), 2)
        self.assertTrue(self.buses[0].dropped)
        self.assertEqual([s[2] for s in self.buses[1].sent], ["again"])

    def test_a_moved_bus_reconnects(self):
        ferry.notify("Copied from iphone", "hello")
        self.address = "unix:path=/tmp/dbus-other"
        ferry.notify("Copied from iphone", "again")
        self.assertEqual([b.address for b in self.buses], ["unix:path=/run/user/1000/bus", "unix:path=/tmp/dbus-other"])
        self.assertTrue(self.buses[0].dropped)

    def test_a_failed_connection_is_tried_again_next_time(self):
        self.notify_send.side_effect = None
        self.notify_send.return_value = ""
        self.fails = 1
        self.assertEqual(ferry.notify("Copied from iphone", "hello"), "")
        self.notify_send.assert_called_once()
        self.assertEqual(ferry.notify("Copied from iphone", "again"), "7")

    def test_no_daemon_falls_back_to_notify_send(self):
        self.notify_send.side_effect = None
        self.notify_send.return_value = ""
        ferry.notify("Copied from iphone", "hello")
        self.buses[0].fail = 2
        self.fails = 1
        self.assertEqual(ferry.notify("Text from iphone", "hi", {"copy": ("Copy", print)}), "")
        self.notify_send.assert_called_once_with("Text from iphone", "hi", {"copy": ("Copy", print)}, "", "")

    def test_no_bus_falls_back_to_notify_send(self):
        self.notify_send.side_effect = None
        self.notify_send.return_value = "3"
        self.address = ""
        self.assertEqual(ferry.notify("Copied from iphone", "hello"), "3")
        self.assertEqual(self.buses, [])

    def test_close_on_the_same_connection(self):
        nid = ferry.notify("Received 2 files", "", {"copy": ("Copy", lambda: None)})
        with mock.patch.object(ferry.subprocess, "run", side_effect=AssertionError("gdbus")):
            ferry.close_notification(nid)
        self.assertEqual(self.buses[0].closes, [int(nid)])

    def test_close_without_a_connection_uses_gdbus(self):   # the notification was notify-send's
        with mock.patch.object(ferry.subprocess, "run") as run:
            ferry.close_notification("5")
        self.assertIn("org.freedesktop.Notifications.CloseNotification", run.call_args[0][0])
        self.assertEqual(self.buses, [])


class NoPyGObject(unittest.TestCase):
    """Without PyGObject (a server, a desktop installed without Ferry's window) notifications are notify-send's."""

    def test_falls_back_to_notify_send(self):
        notifications = ferry.Notifications(env=lambda: {"DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"})
        with mock.patch.dict(sys.modules, {"gi": None, "gi.repository": None}), \
                mock.patch.object(ferry, "notifications", notifications), \
                mock.patch.object(ferry, "notify_send", return_value="9") as send:
            self.assertEqual(ferry.notify("Copied from iphone", "hello"), "9")
            self.assertEqual(ferry.notify("Copied from iphone", "again"), "9")
        self.assertEqual(send.call_count, 2)
        self.assertIsNone(notifications.connect)   # not looked for again


class SessionBus(unittest.TestCase):
    """The bus's address, found where notify-send's GDBus would find it."""

    def test_from_the_environment(self):
        self.assertEqual(ferry.session_bus({"DBUS_SESSION_BUS_ADDRESS": "unix:path=/x/bus"}), "unix:path=/x/bus")

    def test_systemds_user_bus(self):
        with tempfile.TemporaryDirectory() as runtime:
            self.assertEqual(ferry.session_bus({"XDG_RUNTIME_DIR": runtime}), "")
            open(os.path.join(runtime, "bus"), "w").close()
            self.assertEqual(ferry.session_bus({"XDG_RUNTIME_DIR": runtime}), f"unix:path={runtime}/bus")


class Received(unittest.TestCase):
    """What the phone sends is in the box when the server answers, and the notification doesn't hold the answer up."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        state = mock.patch.object(ferry, "STATE", self.tmp.name)
        state.start()
        self.addCleanup(state.stop)
        self.shown = threading.Event()
        self.release = threading.Event()
        self.addCleanup(self.release.set)

        def notify(*a, **kw):   # a notification daemon that takes its time
            self.shown.set()
            self.release.wait(10)
            return "1"
        for name, value in (("notify", notify), ("changed", lambda: None), ("copy_text", lambda *a, **kw: False),
                            ("copy_file", lambda *a, **kw: False)):
            p = mock.patch.object(ferry, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.app = ferry.Ferry.__new__(ferry.Ferry)
        self.app.lock = threading.Lock()
        self.app.notifying = threading.Lock()
        self.app.recent = (0.0, None)

    def items(self):
        with ferry.box() as items:
            return items

    def test_a_text(self):
        start = time.monotonic()
        self.app.received_text("801566", "iphone")
        self.assertLess(time.monotonic() - start, 1)
        self.assertEqual([(i["text"], i["from"]) for i in self.items()], [("801566", "iphone")])
        self.assertTrue(self.shown.wait(5))

    def test_a_file(self):
        path = os.path.join(self.tmp.name, "photo.jpg")
        with open(path, "wb") as f:
            f.write(b"jpeg")
        start = time.monotonic()
        self.app.received_file(path, 4, "image/jpeg", "iphone")
        self.assertLess(time.monotonic() - start, 1)
        self.assertEqual([(i["name"], i["size"]) for i in self.items()], [("photo.jpg", 4)])
        self.assertTrue(self.shown.wait(5))

    def test_files_in_a_row_share_one_notification(self):
        # A folder from the phone: its files come faster than a daemon shows their notifications. Each must replace
        # the one before, so one is left, saying how many came, not a stack of "Received 1…14 files".
        shown = []

        def notify(title, body, actions=(), preview="", replaces=""):
            time.sleep(0.05)   # the daemon's answer, the id, comes a moment later
            shown.append((title, replaces))
            return replaces or str(len(shown))
        paths = []
        for n in range(5):
            paths.append(os.path.join(self.tmp.name, f"{n}.jpg"))
            with open(paths[-1], "wb") as f:
                f.write(b"jpeg")
        with mock.patch.object(ferry, "notify", notify), mock.patch.object(ferry, "close_notification") as close:
            for p in paths:
                self.app.received_file(p, 4, "image/jpeg", "iphone")
            for _ in range(100):
                if shown and shown[-1][0] == "Received 5 files":
                    break
                time.sleep(0.05)
            time.sleep(0.2)
        self.assertEqual(shown[0], ("Received 0.jpg", ""))
        self.assertEqual(shown[-1][0], "Received 5 files")
        self.assertTrue(all(r == "1" for _t, r in shown[1:]), shown)   # each in place of the first
        close.assert_not_called()

    def test_a_daemon_that_doesnt_replace(self):   # a new id instead: the one before is closed
        first, second = (os.path.join(self.tmp.name, n) for n in ("a.jpg", "b.jpg"))
        for p in (first, second):
            with open(p, "wb") as f:
                f.write(b"jpeg")
        ids = iter(["1", "2"])
        with mock.patch.object(ferry, "notify", lambda *a, **kw: next(ids)), \
                mock.patch.object(ferry, "close_notification") as close:
            self.app.received_file(first, 4, "image/jpeg", "iphone")
            for _ in range(50):
                if self.app.recent[1]["nid"]:
                    break
                time.sleep(0.05)
            self.app.received_file(second, 4, "image/jpeg", "iphone")
            for _ in range(50):
                if close.called:
                    break
                time.sleep(0.05)
            close.assert_called_once_with("1")

    def test_a_while_later_is_a_new_notification(self):
        first, second = (os.path.join(self.tmp.name, n) for n in ("a.jpg", "b.jpg"))
        for p in (first, second):
            with open(p, "wb") as f:
                f.write(b"jpeg")
        shown = []
        with mock.patch.object(ferry, "notify", lambda t, *a, replaces="", **kw: shown.append((t, replaces)) or "1"):
            self.app.received_file(first, 4, "image/jpeg", "iphone")
            time.sleep(0.2)
            when, group = self.app.recent
            self.app.recent = (when - ferry.GROUP_NOTIFY, group)
            self.app.received_file(second, 4, "image/jpeg", "iphone")
            time.sleep(0.2)
        self.assertEqual(shown, [("Received a.jpg", ""), ("Received b.jpg", "")])

if __name__ == "__main__":
    unittest.main()
