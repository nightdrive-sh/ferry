"""Another of the owner's machines is trusted only as Ferry: its origin on Ferry's port, its base URL at /ferry/, and
not another web app on another port of it (FER-08). Run from linux/:

    python3 -m unittest discover -s tests -p test_origins.py
"""
import io
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from load import api, server, tailnet  # noqa: E402
from test_forget import App  # noqa: E402

STATUS = {"User": {"1": {"LoginName": "owner@example.com"}, "2": {"LoginName": "them@example.com"}},
          "Self": {"UserID": 1, "DNSName": "nightdrive.tail0.ts.net."},
          "Peer": {"s": {"DNSName": "studio.tail0.ts.net.", "UserID": 1, "Online": True},
                   "x": {"DNSName": "theirs.tail0.ts.net.", "UserID": 2, "Online": True}}}


def owners_tailnet(test):
    p = mock.patch.object(tailnet, "tailscale_status", lambda: STATUS)
    p.start()
    test.addCleanup(p.stop)
    return tailnet.Tailnet()


class Origins(unittest.TestCase):
    def setUp(self):
        self.tailnet = owners_tailnet(self)

    def test_a_ferry_page_on_another_of_the_owners_machines(self):
        self.assertTrue(self.tailnet.same_origin("https://studio.tail0.ts.net"))
        self.assertTrue(self.tailnet.same_origin("https://nightdrive.tail0.ts.net"))

    def test_another_port_user_or_scheme_is_another_app(self):
        for o in ("https://studio.tail0.ts.net:8443", "https://studio.tail0.ts.net:443", "http://studio.tail0.ts.net",
                  "https://me@studio.tail0.ts.net", "https://studio.tail0.ts.net/", "https://STUDIO.tail0.ts.net",
                  "https://studio.tail0.ts.net:bad", "https://[studio", "", "null"):
            self.assertFalse(self.tailnet.same_origin(o), o)

    def test_another_users_machine_isnt_the_owners(self):
        self.assertFalse(self.tailnet.same_origin("https://theirs.tail0.ts.net"))
        self.assertFalse(self.tailnet.same_base("https://theirs.tail0.ts.net/ferry/"))

    def test_a_base_url_is_ferrys_own(self):
        self.assertTrue(self.tailnet.same_base("https://studio.tail0.ts.net/ferry/"))
        for u in ("https://studio.tail0.ts.net/ferry", "https://studio.tail0.ts.net/other/ferry/",
                  "https://studio.tail0.ts.net:8443/ferry/", "https://studio.tail0.ts.net/ferry/?x",
                  "https://studio.tail0.ts.net"):
            self.assertFalse(self.tailnet.same_base(u), u)


class Requests(App):
    """The API as a page on another machine reaches it through the browser."""
    def setUp(self):
        super().setUp()
        self.app.tailnet = owners_tailnet(self)
        out = mock.patch.object(sys, "stdout", io.StringIO())   # the journal's line for every request
        out.start()
        self.addCleanup(out.stop)
        self.server = server.Server(("127.0.0.1", 0), api.handler(self.app))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def ask(self, method, origin, site="cross-site"):
        headers = {"Host": "nightdrive.tail0.ts.net", "Tailscale-User-Login": "owner@example.com", "X-Ferry": "1",
                   "Origin": origin, "Sec-Fetch-Site": site}
        req = urllib.request.Request(f"http://127.0.0.1:{self.server.server_address[1]}/api/items", None, headers,
                                     method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, r.headers.get("Access-Control-Allow-Origin")
        except urllib.error.HTTPError as e:
            with e:
                return e.code, e.headers.get("Access-Control-Allow-Origin")

    def test_the_ferry_page_on_another_machine_is_answered(self):
        self.assertEqual(self.ask("OPTIONS", "https://studio.tail0.ts.net"), (204, "https://studio.tail0.ts.net"))
        self.assertEqual(self.ask("GET", "https://studio.tail0.ts.net"), (200, "https://studio.tail0.ts.net"))

    def test_another_app_on_that_machine_is_not(self):
        for site in ("same-site", "cross-site"):
            self.assertEqual(self.ask("OPTIONS", "https://studio.tail0.ts.net:8443", site), (403, None))
            self.assertEqual(self.ask("GET", "https://studio.tail0.ts.net:8443", site), (403, None))


if __name__ == "__main__":
    unittest.main()
