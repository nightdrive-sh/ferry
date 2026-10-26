"""Add Device's QR code: the link to nightdrive.sh's add page, with the computer's address in its fragment. Run from
linux/:

    python3 -m unittest discover -s tests -p test_qr.py
"""
import os
import tempfile
import unittest
from unittest import mock

from load import ferry

ADDRESS = "https://pc.tail0.ts.net/ferry/"
LINK = "https://nightdrive.sh/ferry/add#https://pc.tail0.ts.net/ferry/"


class AddLink(unittest.TestCase):
    def test_the_address_is_in_the_fragment(self):
        self.assertEqual(ferry.add_link(ADDRESS), LINK)

    def test_no_address_no_link(self):
        self.assertEqual(ferry.add_link(""), "")


class Qr(unittest.TestCase):
    def setUp(self):
        self.runs = []
        tmp = tempfile.mkdtemp()
        for p in [mock.patch.object(ferry, "url", return_value=ADDRESS),
                  mock.patch.object(ferry, "QR", os.path.join(tmp, "qr.svg")),
                  mock.patch.object(ferry.shutil, "which", return_value="/usr/bin/qrencode"),
                  mock.patch.object(ferry.subprocess, "run", side_effect=self.run_)]:
            p.start()
            self.addCleanup(p.stop)

    def run_(self, cmd, **_):
        self.runs.append(cmd)
        return mock.Mock(returncode=0)

    def test_terminal_code_holds_the_link(self):
        with mock.patch("sys.stdout"):
            self.assertEqual(ferry.qr(svg=False), 0)
        self.assertEqual(self.runs[-1][-1], LINK)

    def test_menu_svg_holds_the_link(self):
        with mock.patch("sys.stdout"):
            self.assertEqual(ferry.qr(svg=True), 0)
        self.assertEqual(self.runs[-1][-1], LINK)


if __name__ == "__main__":
    unittest.main()
