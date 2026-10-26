"""How long since the computer was last used (api/items' idle), on each desktop. Run from linux/:

    python3 -m unittest discover -s tests -p test_idle.py
"""
import socket
import struct
import threading
import unittest

from load import ferry


class Seconds(unittest.TestCase):
    def test_in_use_within_the_last_minute(self):   # docs/protocol.md: 0 on every system
        self.assertEqual(ferry.idle_seconds(59999), 0)

    def test_idle_after_it(self):
        self.assertEqual(ferry.idle_seconds(61500), 61)

    def test_mutters_answer(self):   # GNOME, Wayland and X11
        self.assertEqual(ferry.mutter_ms("(uint64 61234,)\n"), 61234)
        self.assertIsNone(ferry.mutter_ms(""))

    def test_the_first_source_that_knows(self):
        calls = []

        def source(answer):
            def f(env):
                calls.append(answer)
                return answer
            return f
        self.assertEqual(ferry.idle_for({}, sources=[source(None), source(120), source(0)]), 120)
        self.assertEqual(calls, [None, 120])
        self.assertIsNone(ferry.idle_for({}, sources=[source(None)]))


# --- A pretend Wayland compositor -------------------------------------------------------------------------------------
def message(obj, op, args=b""):
    return struct.pack("=II", obj, (8 + len(args)) << 16 | op) + args


def string(s):
    b = s.encode() + b"\0"
    return struct.pack("=I", len(b)) + b + b"\0" * (-len(b) % 4)


class Compositor:
    """One client's connection: the registry with the globals given, then idle events when the test sends them."""

    def __init__(self, globals_):
        self.client, self.sock = socket.socketpair()
        self.globals, self.requests, self.notification = globals_, [], None
        self.ready = threading.Event()
        threading.Thread(target=self.serve, daemon=True).start()

    def read(self, n):
        b = b""
        while len(b) < n:
            chunk = self.sock.recv(n - len(b))
            if not chunk:
                raise EOFError
            b += chunk
        return b

    def serve(self):
        try:
            while True:
                obj, size_op = struct.unpack("=II", self.read(8))
                args = self.read((size_op >> 16) - 8)
                op = size_op & 0xFFFF
                self.requests.append((obj, op, args))
                if (obj, op) == (1, 1):   # wl_display.get_registry
                    registry = struct.unpack("=I", args)[0]
                    for name, (iface, version) in enumerate(self.globals, 1):
                        self.sock.sendall(message(registry, 0, struct.pack("=I", name) + string(iface) +
                                                  struct.pack("=I", version)))
                elif (obj, op) == (1, 0):   # wl_display.sync
                    self.sock.sendall(message(struct.unpack("=I", args)[0], 0, struct.pack("=I", 0)))
                elif op in (1, 2) and len(args) == 12:   # ext_idle_notifier_v1.get_(input_)idle_notification
                    self.notification = struct.unpack("=III", args)
                    self.op = op
                    self.ready.set()
        except (EOFError, OSError):
            pass

    def event(self, op):   # 0: idled, 1: resumed
        self.sock.sendall(message(self.notification[0], op))

    def close(self):
        # shutdown first: on Linux a close alone leaves the socket open while serve() is blocked in recv on it, so the
        # client never reads the end of the session (macOS wakes the recv and closes it)
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class WaylandIdle(unittest.TestCase):
    """KDE, Hyprland and other compositors with ext-idle-notify-v1 say when the user goes idle and comes back."""

    def start(self, globals_):
        self.compositor = Compositor(globals_)
        self.clock = Clock()
        self.idle = ferry.WaylandIdle(connect=lambda: self.compositor.client, clock=self.clock)
        self.done = threading.Event()

        def watch():
            self.result = self.idle.watch()
            self.done.set()
        threading.Thread(target=watch, daemon=True).start()

    def tearDown(self):
        self.compositor.close()

    def until(self, check):
        for _ in range(200):
            if check():
                return
            threading.Event().wait(0.01)
        self.fail("timed out")

    def test_a_minute_without_idling_is_in_use(self):
        self.start([("wl_seat", 7), ("ext_idle_notifier_v1", 2)])
        self.assertTrue(self.compositor.ready.wait(2))
        self.assertIsNone(self.idle.seconds())   # it can't tell until a whole minute has gone by
        self.clock.now += 60
        self.assertEqual(self.idle.seconds(), 0)

    def test_idled_and_resumed(self):
        self.start([("wl_seat", 7), ("ext_idle_notifier_v1", 2)])
        self.assertTrue(self.compositor.ready.wait(2))
        self.clock.now += 300
        self.compositor.event(0)
        self.until(lambda: self.idle.seconds() == 60)
        self.clock.now += 40
        self.assertEqual(self.idle.seconds(), 100)
        self.compositor.event(1)
        self.until(lambda: self.idle.seconds() == 0)

    def test_asks_for_input_idleness_with_a_minute(self):   # v2: an inhibitor (a video playing) doesn't count as use
        self.start([("wl_seat", 7), ("ext_idle_notifier_v1", 2)])
        self.assertTrue(self.compositor.ready.wait(2))
        _, timeout, seat = self.compositor.notification
        self.assertEqual((self.compositor.op, timeout), (2, 60000))
        binds = [r for r in self.compositor.requests if r[1] == 0 and r[0] == 2]
        self.assertIn(b"wl_seat", binds[0][2])
        self.assertEqual(struct.unpack("=I", binds[0][2][-4:])[0], seat)

    def test_version_1_notifier(self):
        self.start([("wl_seat", 7), ("ext_idle_notifier_v1", 1)])
        self.assertTrue(self.compositor.ready.wait(2))
        self.assertEqual(self.compositor.op, 1)

    def test_a_compositor_without_it(self):   # GNOME: Mutter's IdleMonitor answers instead
        self.start([("wl_seat", 7), ("wl_compositor", 6)])
        self.assertTrue(self.done.wait(2))
        self.assertFalse(self.result)
        self.assertIsNone(self.idle.seconds())

    def test_the_session_ends(self):
        self.start([("wl_seat", 7), ("ext_idle_notifier_v1", 2)])
        self.assertTrue(self.compositor.ready.wait(2))
        self.clock.now += 60
        self.compositor.close()
        self.assertTrue(self.done.wait(2))
        self.assertIsNone(self.idle.seconds())


if __name__ == "__main__":
    unittest.main()
