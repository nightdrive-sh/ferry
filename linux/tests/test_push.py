"""Ferry's notification payload and who gets a notification. Run from linux/:

    python3 -m unittest discover -s tests -p test_push.py

(On a machine without python3-cryptography: uv run --no-project --with cryptography python3 -m unittest discover -s tests.)
"""
import json
import unittest

from load import bin_ferry, config


def sub(device, direct=False, endpoint=None):
    s = {"endpoint": endpoint or f"https://push.example/{device}-{direct}", "keys": {"p256dh": "k", "auth": "a"},
         "device": device, "time": 0}
    if direct:
        s["direct"] = True
    return s


class Payload(unittest.TestCase):
    def test_keeps_short_text(self):
        p = bin_ferry.payload("Nightdrive", "See you at eight", item={"id": "a1", "kind": "text", "text": "See you at eight"})
        self.assertEqual(json.loads(p), {"title": "Nightdrive", "body": "See you at eight", "machine": "", "id": "a1",
                                         "kind": "text", "text": "See you at eight"})

    def test_drops_text_that_does_not_fit(self):
        text = "ä" * 1500   # 3000 bytes
        p = bin_ferry.payload("Nightdrive", text[:180], item={"id": "a1", "kind": "text", "text": text})
        self.assertLessEqual(len(p), config.PUSH_PAYLOAD)
        d = json.loads(p)
        self.assertNotIn("text", d)
        self.assertEqual(d["body"], "ä" * 180)
        self.assertEqual(d["kind"], "text")

    def test_never_cuts_utf8(self):   # Review Focus 2
        text = "😀" * 900   # 3600 bytes
        p = bin_ferry.payload("😀" * 300, "😀" * 300, item={"id": "a1", "kind": "text", "text": text})
        self.assertLessEqual(len(p), config.PUSH_PAYLOAD)
        d = json.loads(p.decode("utf-8"))   # valid UTF-8 and valid JSON
        self.assertNotIn("text", d)

    def test_text_that_just_fits_is_kept_whole(self):
        base = len(bin_ferry.payload("N", "x", item={"id": "a1", "kind": "text", "text": ""}))
        text = "x" * (config.PUSH_PAYLOAD - base)
        d = json.loads(bin_ferry.payload("N", "x", item={"id": "a1", "kind": "text", "text": text}))
        self.assertEqual(d["text"], text)

    def test_for_files(self):
        d = json.loads(bin_ferry.payload("N", "x.pdf", item={"id": "f1", "kind": "file", "name": "x.pdf"}))
        self.assertEqual((d["id"], d["kind"]), ("f1", "file"))
        self.assertNotIn("text", d)

    def test_ends_with_a_huge_machine(self):   # api/relay-push takes machine from the request
        p = bin_ferry.payload("N", "x", "https://m/" + "a" * 2700)
        self.assertLessEqual(len(p), config.PUSH_PAYLOAD)
        json.loads(p)

    def test_without_item(self):   # api/test-push, api/relay-push
        self.assertEqual(json.loads(bin_ferry.payload("N", "Notifications work", "https://m/ferry/")),
                         {"title": "N", "body": "Notifications work", "machine": "https://m/ferry/"})


class Targets(unittest.TestCase):
    def test_relayed_skips_direct_and_the_same_phones_pwa(self):   # Review Focus 3
        pwa, app = sub("iphone"), sub("iphone", direct=True)
        self.assertEqual(bin_ferry.targets([pwa, app], relayed=True), [])
        self.assertEqual(bin_ferry.targets([pwa, app], relayed=False), [app])

    def test_other_devices_pwa_kept(self):
        pwa, app = sub("ipad"), sub("iphone", direct=True)
        self.assertEqual(bin_ferry.targets([pwa, app], relayed=False), [pwa, app])
        self.assertEqual(bin_ferry.targets([pwa, app], relayed=True), [pwa])

    def test_fallback_device_not_replaced(self):   # "your phone" could be anyone's
        pwa, app = sub("your phone"), sub("your phone", direct=True)
        self.assertEqual(bin_ferry.targets([pwa, app], relayed=False), [pwa, app])

    def test_pwa_alone_unchanged(self):
        pwa = sub("iphone")
        self.assertEqual(bin_ferry.targets([pwa], relayed=False), [pwa])
        self.assertEqual(bin_ferry.targets([pwa], relayed=True), [pwa])


class Subscription(unittest.TestCase):
    def test_stores_direct(self):
        e = bin_ferry.subscription({"endpoint": "https://push.nightdrive.sh/push/x", "keys": {"p256dh": "k", "auth": "a"},
                                "direct": True}, "iphone")
        self.assertTrue(e["direct"])
        self.assertEqual(e["device"], "iphone")

    def test_without_direct(self):
        e = bin_ferry.subscription({"endpoint": "https://web.push.apple.com/x", "keys": {"p256dh": "k", "auth": "a"}}, "iphone")
        self.assertNotIn("direct", e)

    def test_rejects_non_subscriptions(self):
        self.assertIsNone(bin_ferry.subscription({"endpoint": "http://x/", "keys": {"p256dh": "k", "auth": "a"}}, "d"))
        self.assertIsNone(bin_ferry.subscription({"endpoint": "https://x/", "keys": {"p256dh": "k"}}, "d"))
        self.assertIsNone(bin_ferry.subscription([], "d"))


if __name__ == "__main__":
    unittest.main()
