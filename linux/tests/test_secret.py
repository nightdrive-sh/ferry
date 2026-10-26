"""Texts that look like a code or a password (docs/protocol.md › Codes and passwords). Run from linux/:

    python3 -m unittest discover -s tests -p test_secret.py
"""
import io
import json
import os
import tempfile
import threading
import unittest
from unittest import mock

from load import ferry

# The vectors FerryKit's SecretTests runs too: one rule on every platform
VECTORS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "FerryKit", "Tests", "FerryKitTests",
                       "Fixtures", "secrets.json")


class LooksSecret(unittest.TestCase):
    def test_the_shared_vectors(self):
        with open(VECTORS) as f:
            v = json.load(f)
        for text in v["secret"]:
            self.assertTrue(ferry.looks_secret(text), f"{text!r} is a code or a password")
        for text in v["not"]:
            self.assertFalse(ferry.looks_secret(text), f"{text!r} isn't")

    def test_only_a_text_is_one(self):   # a file's name may look like one (IMG_1234.jpg)
        self.assertTrue(ferry.secret({"kind": "text", "text": "801566"}))
        self.assertFalse(ferry.secret({"kind": "file", "name": "IMG_1234.jpg"}))
        self.assertFalse(ferry.secret({"kind": "text", "text": "See you at eight"}))


class PhoneNotification(unittest.TestCase):
    def test_a_code_isnt_shown(self):
        it = {"id": "abc", "kind": "text", "text": "801566"}
        d = json.loads(ferry.payload("Nightdrive", "801566", item=it))
        self.assertEqual(d["body"], "Code or password · open to see")
        self.assertIs(d["secret"], True)
        self.assertEqual(d["text"], "801566")   # a tap on it still copies it

    def test_another_text_is(self):
        it = {"id": "abc", "kind": "text", "text": "See you at eight"}
        d = json.loads(ferry.payload("Nightdrive", "See you at eight", item=it))
        self.assertEqual(d["body"], "See you at eight")
        self.assertNotIn("secret", d)

    def test_a_code_goes_on_hidden(self):   # another computer passes it on to a page, which shows the body as it is
        relayed = []
        with mock.patch.object(ferry, "relays", lambda: ["https://nightdrive.tail1234.ts.net/ferry/"]), \
                mock.patch.object(ferry, "url", lambda: "https://macbook.tail1234.ts.net/ferry/"), \
                mock.patch.object(ferry, "relay_push", lambda via, title, body, *a: relayed.append(body)), \
                mock.patch.object(ferry, "vapid_key", lambda: None):
            ferry.push_all("MacBook", "801566", item={"id": "c", "kind": "text", "text": "801566"})
            ferry.push_all("MacBook", "See you at eight", item={"id": "t", "kind": "text", "text": "See you at eight"})
        self.assertEqual(relayed, ["Code or password · open to see", "See you at eight"])

    def test_a_files_name_is(self):
        it = {"id": "abc", "kind": "file", "name": "IMG_1234.jpg"}
        self.assertEqual(json.loads(ferry.payload("Nightdrive", "IMG_1234.jpg", item=it))["body"], "IMG_1234.jpg")


class ComputerNotification(unittest.TestCase):
    """The computer's own notification doesn't show one either (a desktop may keep notifications); Copy copies it."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.shown, self.copied, self.done = [], [], threading.Event()

        def notify(summary, body="", actions=(), *a, **kw):
            self.shown.append((summary, body, dict(actions)))
            self.done.set()
            return "1"

        def copy_text(text, sensitive=False, **kw):
            self.copied.append((text, sensitive))
            return True
        for name, value in (("STATE", tmp.name), ("notify", notify), ("copy_text", copy_text),
                            ("changed", lambda: None)):
            p = mock.patch.object(ferry, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.app = ferry.Ferry.__new__(ferry.Ferry)

    def received(self, text, clip=False):
        self.done.clear()
        self.app.received_text(text, "iphone", clip)
        self.assertTrue(self.done.wait(5))
        return self.shown[-1]

    def test_a_code_waiting_for_copy(self):
        summary, body, actions = self.received("Tr0ub4dor&3")
        self.assertEqual((summary, body), ("Text from iphone", "Code or password · open to see"))
        actions["copy"][1]()
        self.assertEqual(self.copied, [("Tr0ub4dor&3", True)])   # copied, and kept out of a clipboard history

    def test_a_code_on_the_clipboard(self):
        summary, body, _ = self.received("801566", clip=True)
        self.assertEqual((summary, body), ("Copied from iphone", "Code or password"))

    def test_another_text(self):
        _, body, actions = self.received("Milk, coffee")
        self.assertEqual(body, "Milk, coffee")
        actions["copy"][1]()
        self.assertEqual(self.copied, [("Milk, coffee", False)])

    def items(self):
        with ferry.box() as items:
            return items

    def test_a_code_waits_in_the_box_until_copied(self):   # docs/protocol.md › Codes and passwords
        _, _, actions = self.received("Tr0ub4dor&3")
        self.assertEqual([i["text"] for i in self.items()], ["Tr0ub4dor&3"])
        actions["copy"][1]()
        self.assertEqual(self.items(), [])

    def test_a_code_on_the_clipboard_isnt_kept(self):   # it is copied already
        self.received("801566", clip=True)
        self.assertEqual(self.items(), [])

    def test_another_text_stays(self):
        _, _, actions = self.received("Milk, coffee")
        actions["copy"][1]()
        self.received("See you at eight", clip=True)
        self.assertEqual([i["text"] for i in self.items()], ["Milk, coffee", "See you at eight"])

    def test_send_clipboard_is_always_sensitive(self):   # the phone's clipboard often holds a password manager's copy
        self.received("See you at eight", clip=True)
        self.assertEqual(self.copied, [("See you at eight", True)])


class Box(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        for name, value in (("STATE", tmp.name), ("changed", lambda: None)):
            p = mock.patch.object(ferry, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.now = 1_800_000_000.0
        clock = mock.patch.object(ferry.time, "time", lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)

    def texts(self):
        with ferry.box(write=True) as items:
            return [i["text"] for i in items]

    def test_a_code_leaves_after_fifteen_minutes(self):
        ferry.add_text("801566")
        ferry.add_text("Milk, coffee")
        self.now += 14 * 60
        self.assertEqual(self.texts(), ["801566", "Milk, coffee"])
        self.now += 2 * 60
        self.assertEqual(self.texts(), ["Milk, coffee"])

    def test_a_code_leaves_the_disk_too(self):   # read without a write, the box would keep it in items.json
        ferry.add_text("801566")
        self.now += 16 * 60
        self.assertTrue(ferry.tidy_once())
        with open(os.path.join(ferry.STATE, "items.json")) as f:
            self.assertEqual(json.load(f)["items"], [])
        self.assertFalse(ferry.tidy_once())   # nothing to drop: not written

    def test_ferry_get_takes_a_code(self):   # a printed code was picked up
        ferry.add_text("801566")
        with ferry.box() as items:
            code = items[0]
        with mock.patch("sys.stdout", io.StringIO()) as out:
            ferry.get(code)
        self.assertEqual(out.getvalue(), "801566")
        self.assertEqual(self.texts(), [])

    def test_a_copied_code_leaves(self):   # ferry copy, the window's Copy
        ferry.add_text("801566")
        ferry.add_text("Milk, coffee")
        with ferry.box() as items:
            code, other = items
        ferry.copied(other)
        ferry.copied(code)
        self.assertEqual(self.texts(), ["Milk, coffee"])

    def test_the_list_marks_a_code(self):
        self.assertIs(ferry.public({"id": "a", "to": "phone", "kind": "text", "time": 0, "text": "801566"})["secret"], True)
        self.assertNotIn("secret", ferry.public({"id": "a", "to": "phone", "kind": "text", "time": 0, "text": "Milk"}))


if __name__ == "__main__":
    unittest.main()
