"""The page as it is served: its Content-Security-Policy keeps it out of other sites' frames (clickjacking) and to its
own script, style and the owner's computers. Run from linux/:

    python3 -m unittest discover -s tests -p test_page.py
"""
import base64
import hashlib
import io
import re
import sys
import threading
import unittest
import urllib.request
from unittest import mock

import test_forget
from load import api, page, server


def sha256(text):
    return "'sha256-" + base64.b64encode(hashlib.sha256(text.encode()).digest()).decode() + "'"


class Policy(unittest.TestCase):
    def test_no_frames(self):
        self.assertIn("frame-ancestors 'none'", page.policy(page.html()))
        self.assertEqual(page.headers(page.html())["X-Frame-Options"], "DENY")

    def test_the_pages_own_script_and_style_by_their_hashes(self):
        html = page.html()
        script = re.search(r"<script>(.*?)</script>", html, re.S).group(1)
        style = re.search(r"<style>(.*?)</style>", html, re.S).group(1)
        rules = dict(r.split(" ", 1) for r in page.policy(html).split("; "))
        self.assertEqual(rules["script-src"], "'self' " + sha256(script))
        self.assertEqual(rules["style-src"], sha256(style))
        self.assertNotIn("unsafe-inline", page.policy(html))

    def test_follows_an_edit_of_the_page(self):   # no hash to keep up by hand
        rules = dict(r.split(" ", 1) for r in page.policy("<style>a{}</style><script>go()</script>").split("; "))
        self.assertEqual(rules["script-src"], "'self' " + sha256("go()"))
        self.assertEqual(rules["style-src"], sha256("a{}"))

    def test_no_style_attributes_in_the_page(self):   # the policy has no 'unsafe-inline' for them
        self.assertNotRegex(page.html(), r"<[^>!]*\sstyle=")

    def test_the_other_computers_api(self):   # the page lists and sends to the owner's other computers
        rules = dict(r.split(" ", 1) for r in page.policy(page.html()).split("; "))
        self.assertEqual(rules["connect-src"], "'self' https://*.ts.net")
        self.assertEqual(rules["default-src"], "'none'")


class Served(test_forget.App):
    def setUp(self):
        super().setUp()
        out = mock.patch.object(sys, "stdout", io.StringIO())   # the journal's line for every request
        out.start()
        self.addCleanup(out.stop)
        self.server = server.Server(("127.0.0.1", 0), api.handler(self.app))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def test_the_page_comes_with_its_policy(self):
        req = urllib.request.Request(f"http://127.0.0.1:{self.server.server_address[1]}/", headers={
            "Host": "nightdrive.tail0.ts.net", "Tailscale-User-Login": "owner@example.com"})
        with urllib.request.urlopen(req, timeout=10) as r:
            html = r.read().decode()
            self.assertEqual(r.headers["Content-Security-Policy"], page.policy(html))
            self.assertEqual(r.headers["X-Frame-Options"], "DENY")
        self.assertIn('<base href="/ferry/">', html)


if __name__ == "__main__":
    unittest.main()
