"""Ferry's notification payload and who gets a notification. Run from linux/:

    python3 -m unittest discover -s tests -p test_push.py

(On a machine without python3-cryptography: uv run --no-project --with cryptography python3 -m unittest discover -s tests.)
"""
import json
import os
import unittest
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

from load import config, endpoints, push


def sub(device, direct=False, endpoint=None):
    s = {"endpoint": endpoint or f"https://push.example/{device}-{direct}", "keys": {"p256dh": "k", "auth": "a"},
         "device": device, "time": 0}
    if direct:
        s["direct"] = True
    return s


class Payload(unittest.TestCase):
    def test_keeps_short_text(self):
        p = push.payload("Nightdrive", "See you at eight", item={"id": "a1", "kind": "text", "text": "See you at eight"})
        self.assertEqual(json.loads(p), {"title": "Nightdrive", "body": "See you at eight", "machine": "", "id": "a1",
                                         "kind": "text", "text": "See you at eight"})

    def test_drops_text_that_does_not_fit(self):
        text = "ä" * 1500   # 3000 bytes
        p = push.payload("Nightdrive", text[:180], item={"id": "a1", "kind": "text", "text": text})
        self.assertLessEqual(len(p), config.PUSH_PAYLOAD)
        d = json.loads(p)
        self.assertNotIn("text", d)
        self.assertEqual(d["body"], "ä" * 180)
        self.assertEqual(d["kind"], "text")

    def test_never_cuts_utf8(self):   # Review Focus 2
        text = "😀" * 900   # 3600 bytes
        p = push.payload("😀" * 300, "😀" * 300, item={"id": "a1", "kind": "text", "text": text})
        self.assertLessEqual(len(p), config.PUSH_PAYLOAD)
        d = json.loads(p.decode("utf-8"))   # valid UTF-8 and valid JSON
        self.assertNotIn("text", d)

    def test_text_that_just_fits_is_kept_whole(self):
        base = len(push.payload("N", "x", item={"id": "a1", "kind": "text", "text": ""}))
        text = "x" * (config.PUSH_PAYLOAD - base)
        d = json.loads(push.payload("N", "x", item={"id": "a1", "kind": "text", "text": text}))
        self.assertEqual(d["text"], text)

    def test_for_files(self):
        d = json.loads(push.payload("N", "x.pdf", item={"id": "f1", "kind": "file", "name": "x.pdf"}))
        self.assertEqual((d["id"], d["kind"]), ("f1", "file"))
        self.assertNotIn("text", d)

    def test_ends_with_a_huge_machine(self):   # api/relay-push takes machine from the request
        p = push.payload("N", "x", "https://m/" + "a" * 2700)
        self.assertLessEqual(len(p), config.PUSH_PAYLOAD)
        json.loads(p)

    def test_without_item(self):   # api/test-push, api/relay-push
        self.assertEqual(json.loads(push.payload("N", "Notifications work", "https://m/ferry/")),
                         {"title": "N", "body": "Notifications work", "machine": "https://m/ferry/"})


class Targets(unittest.TestCase):
    def test_relayed_skips_direct_and_the_same_phones_pwa(self):   # Review Focus 3
        pwa, app = sub("iphone"), sub("iphone", direct=True)
        self.assertEqual(push.targets([pwa, app], relayed=True), [])
        self.assertEqual(push.targets([pwa, app], relayed=False), [app])

    def test_other_devices_pwa_kept(self):
        pwa, app = sub("ipad"), sub("iphone", direct=True)
        self.assertEqual(push.targets([pwa, app], relayed=False), [pwa, app])
        self.assertEqual(push.targets([pwa, app], relayed=True), [pwa])

    def test_fallback_device_not_replaced(self):   # "your phone" could be anyone's
        pwa, app = sub("your phone"), sub("your phone", direct=True)
        self.assertEqual(push.targets([pwa, app], relayed=False), [pwa, app])

    def test_pwa_alone_unchanged(self):
        pwa = sub("iphone")
        self.assertEqual(push.targets([pwa], relayed=False), [pwa])
        self.assertEqual(push.targets([pwa], relayed=True), [pwa])


class Subscription(unittest.TestCase):
    def test_stores_direct(self):
        e = push.subscription({"endpoint": "https://push.nightdrive.sh/push/x", "keys": {"p256dh": "k", "auth": "a"},
                                "direct": True}, "iphone")
        self.assertTrue(e["direct"])
        self.assertEqual(e["device"], "iphone")

    def test_without_direct(self):
        e = push.subscription({"endpoint": "https://web.push.apple.com/x", "keys": {"p256dh": "k", "auth": "a"}}, "iphone")
        self.assertNotIn("direct", e)

    def test_rejects_non_subscriptions(self):
        self.assertIsNone(push.subscription({"endpoint": "http://x/", "keys": {"p256dh": "k", "auth": "a"}}, "d"))
        self.assertIsNone(push.subscription({"endpoint": "https://x/", "keys": {"p256dh": "k"}}, "d"))
        self.assertIsNone(push.subscription([], "d"))

    def test_rejects_an_address_that_isnt_a_push_service(self):   # the computer would post wherever it was told
        for endpoint in ("https://192.168.1.1/x", "https://127.0.0.1:8080/", "https://router.local/admin",
                         "https://nightdrive.tail1234.ts.net/ferry/api/clear"):
            self.assertIsNone(push.subscription({"endpoint": endpoint, "keys": {"p256dh": "k", "auth": "a"}}, "d"))


class Endpoints(unittest.TestCase):
    """The push services an endpoint may be at (endpoints.allowed)."""

    def test_the_browsers_and_the_relay(self):
        for endpoint in ("https://push.nightdrive.sh/push/x", "https://web.push.apple.com/QGx",
                         "https://fcm.googleapis.com/fcm/send/abc", "https://updates.push.services.mozilla.com/wpush/v2/a",
                         "https://wns2-par02p.notify.windows.com/w/?token=a", "https://WEB.PUSH.APPLE.COM/x"):
            self.assertTrue(endpoints.allowed(endpoint), endpoint)

    def test_nothing_else(self):
        for endpoint in ("http://web.push.apple.com/x", "https://web.push.apple.com:8443/x",
                         "https://user@web.push.apple.com/x", "https://web.push.apple.com.evil.example/x",
                         "https://evilpush.nightdrive.sh/x", "https://push.services.mozilla.com.example/x",
                         "https://notify.windows.com/x", "https://web.push.apple.com:port/x", "https:///x", "", None, 5):
            self.assertFalse(endpoints.allowed(endpoint), endpoint)

    def test_a_relay_of_ones_own(self):
        with mock.patch.dict(os.environ, {endpoints.EXTRA: "relay.example, .test.example"}):
            self.assertTrue(endpoints.allowed("https://relay.example/push/x"))
            self.assertTrue(endpoints.allowed("https://a.test.example/push/x"))
            self.assertFalse(endpoints.allowed("https://other.example/push/x"))


class Send(unittest.TestCase):
    """What send() posts to."""

    def test_a_stored_address_that_isnt_a_push_service_goes(self):   # subscribed before the services were checked
        kept = [sub("iphone", endpoint="https://192.168.1.1/x")]
        with mock.patch.object(endpoints, "post", side_effect=AssertionError("posted")), \
                mock.patch.object(push, "subscriptions", lambda change: change(kept)), \
                mock.patch("sys.stderr"):
            self.assertFalse(push.send(list(kept), b"{}", None, 60, "high"))
        self.assertEqual(kept, [])

    def test_a_redirect_isnt_followed(self):   # a push service answers itself; urllib would follow a 302 elsewhere
        asked = []

        class Redirect(BaseHTTPRequestHandler):
            def do_POST(self):
                asked.append(self.path)
                self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(302)
                self.send_header("Location", "/elsewhere")
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *a):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Redirect)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        req = urllib.request.Request(f"http://127.0.0.1:{server.server_port}/push", b"x", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as e:
            endpoints.post(req, timeout=5)
        self.assertEqual(e.exception.code, 302)
        e.exception.close()
        self.assertEqual(asked, ["/push"])


if __name__ == "__main__":
    unittest.main()
