"""The local server answers only tailscaled (root) and this user (peers.py), whatever the headers say. Run from linux/:

    python3 -m unittest discover -s tests -p test_peers.py
"""
import io
import os
import socket
import sys
import tempfile
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from load import peers, server  # noqa: E402

LITTLE = sys.byteorder == "little"
CLIENT, SERVER = ("127.0.0.1", 51000), ("127.0.0.1", 47270)
HEADER = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"


def row(local, remote, state, uid):
    return f"   0: {local} {remote} {state} 00000000:00000000 00:00000000 00000000 {uid:>5}        0 1 1 0\n"


class Table(unittest.TestCase):
    def table(self, *rows):
        f = tempfile.NamedTemporaryFile("w", suffix=".tcp", delete=False)
        f.write(HEADER + "".join(rows))
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_addresses_are_written_as_the_kernel_does(self):
        self.assertEqual(peers.hex_address("127.0.0.1", 47270), "0100007F:B8A6" if LITTLE else "7F000001:B8A6")

    def test_the_client_end_of_the_connection_says_whose_it_is(self):
        c, s = peers.hex_address(*CLIENT), peers.hex_address(*SERVER)
        t = self.table(row(s, "00000000:0000", "0A", 1000),   # the server's own listening socket and its end
                       row(s, c, "01", 1000),
                       row(c, s, "01", 1001))
        self.assertEqual(peers.uid_of(CLIENT, SERVER, t), 1001)
        self.assertFalse(peers.trusted(CLIENT, SERVER, t, me=1000))
        self.assertTrue(peers.trusted(CLIENT, SERVER, t, me=1001))

    def test_root_is_tailscaled(self):
        c, s = peers.hex_address(*CLIENT), peers.hex_address(*SERVER)
        self.assertTrue(peers.trusted(CLIENT, SERVER, self.table(row(c, s, "01", 0)), me=1000))

    def test_only_an_open_connection_counts(self):
        # A closed connection's leftover (TIME_WAIT) shows uid 0 whoever had it
        c, s = peers.hex_address(*CLIENT), peers.hex_address(*SERVER)
        t = self.table(row(c, s, "06", 0), row(c, s, "01", 1001))
        self.assertFalse(peers.trusted(CLIENT, SERVER, t, me=1000))

    def test_nobody_is_trusted_without_the_table(self):
        self.assertIsNone(peers.uid_of(CLIENT, SERVER, "/nonexistent/tcp"))
        self.assertFalse(peers.trusted(CLIENT, SERVER, "/nonexistent/tcp", me=0))


class Hello(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "5")
        self.end_headers()
        self.wfile.write(b"hello")

    def log_message(self, *a):
        pass


@unittest.skipUnless(os.path.exists("/proc/net/tcp"), "the kernel's table is Linux's")
class RealServer(unittest.TestCase):
    def setUp(self):
        out = mock.patch.object(sys, "stdout", io.StringIO())
        out.start()
        self.addCleanup(out.stop)
        self.server = server.Server(("127.0.0.1", 0), Hello)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/"

    def test_this_user_is_answered(self):
        with urllib.request.urlopen(self.url, timeout=10) as r:
            self.assertEqual(r.read(), b"hello")

    @unittest.skipIf(os.getuid() == 0, "root is trusted as tailscaled")
    def test_another_user_gets_the_connection_closed(self):
        someone_else = os.getuid() + 1
        with mock.patch.object(peers.os, "getuid", lambda: someone_else):
            with self.assertRaises((ConnectionError, OSError, urllib.error.URLError)):
                urllib.request.urlopen(self.url, timeout=10).read()
        self.assertIn("refused a local connection", sys.stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
