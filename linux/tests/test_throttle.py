"""A request that isn't the owner's, or names another host, doesn't run `tailscale status --json` every time, and a
connection that sends nothing doesn't hold a thread for ever (FER-09). Run from linux/:

    python3 -m unittest discover -s tests -p test_throttle.py
"""
import io
import os
import socket
import sys
import threading
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from load import api, config, server, tailnet  # noqa: E402
from test_forget import App  # noqa: E402
from test_origins import STATUS  # noqa: E402


class Reloads(unittest.TestCase):
    """The forced reload that follows an unknown login, host, origin or address runs at most once in FORCED_RELOAD."""
    def setUp(self):
        self.calls, self.now = 0, 1000.0

        def status():
            self.calls += 1
            return STATUS
        for target, name, value in ((tailnet, "tailscale_status", status),
                                    (tailnet.time, "monotonic", lambda: self.now)):
            p = mock.patch.object(target, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.tailnet = tailnet.Tailnet()
        self.assertTrue(self.tailnet.allowed("owner@example.com"))
        self.calls = 0

    def test_a_strangers_requests_reload_once(self):
        for _ in range(50):
            self.assertFalse(self.tailnet.allowed("them@example.com"))
            self.now += 0.01
        self.assertLessEqual(self.calls, 1)

    def test_another_host_another_origin_or_address_reload_once(self):
        for _ in range(20):
            self.assertFalse(self.tailnet.for_me("evil.example"))
            self.assertFalse(self.tailnet.same_origin("https://theirs.tail0.ts.net"))
            self.assertEqual(self.tailnet.device("100.64.0.9"), "")
        self.assertLessEqual(self.calls, 1)

    def test_the_owner_who_just_logged_in_is_let_in_after_the_pause(self):
        self.now += config.FORCED_RELOAD + 1     # the last load is older than the pause
        self.assertFalse(self.tailnet.allowed("new@example.com"))
        self.assertEqual(self.calls, 1)
        self.tailnet.allowed("new@example.com")
        self.assertEqual(self.calls, 1)          # again at once: no reload
        self.now += config.FORCED_RELOAD
        self.tailnet.allowed("new@example.com")
        self.assertEqual(self.calls, 2)

    def test_the_minute_long_cache_still_holds(self):
        for _ in range(10):
            self.tailnet.allowed("owner@example.com")
            self.tailnet.for_me("nightdrive.tail0.ts.net")
        self.assertEqual(self.calls, 0)
        self.now += 61
        self.tailnet.allowed("owner@example.com")
        self.assertEqual(self.calls, 1)


class Timeout(App):
    """A connection that opens and sends nothing, or stops halfway, is closed after REQUEST_TIMEOUT."""
    def test_the_handler_has_a_timeout(self):
        self.assertEqual(config.REQUEST_TIMEOUT, 60)
        self.assertEqual(api.handler(self.app).timeout, 60)

    def test_a_silent_connection_is_closed(self):
        out = mock.patch.object(sys, "stdout", io.StringIO())
        out.start()
        self.addCleanup(out.stop)
        with mock.patch.object(config, "REQUEST_TIMEOUT", 0.3):
            srv = server.Server(("127.0.0.1", 0), api.handler(self.app))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        with socket.create_connection(srv.server_address, timeout=5) as s:
            s.sendall(b"GET / HTTP/1.1\r\nHost: nigh")   # half a request, then nothing
            self.assertEqual(s.recv(1024), b"")             # closed by the server, not by our 5 s


if __name__ == "__main__":
    unittest.main()
