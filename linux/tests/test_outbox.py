"""Sends that wait for a computer that is asleep or off, and the "awake" push. Run from linux/:

    python3 -m unittest discover -s tests -p test_outbox.py
"""
import io
import json
import os
import tempfile
import time
import unittest
import urllib.error
from unittest import mock

from load import computers, notices, outbox, push, wake

STUDIO = {"id": "studio", "name": "Studio", "kind": "computer", "online": False, "inUse": False}


def refused(code):
    return urllib.error.HTTPError("https://studio/ferry/api/text", code, "no", {}, io.BytesIO(b"Not enough room"))


class Outbox(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = mock.patch("ferry.config.STATE", self.tmp.name)
        self.state.start()
        with open(os.path.join(self.tmp.name, "machines.json"), "w") as f:
            json.dump([{"id": "studio", "name": "Studio", "url": "https://studio/ferry/"}], f)
        self.notes = []
        self.posts = []
        for target, name, fake in ((notices, "notify", lambda *a, **k: self.notes.append(a)),
                                   (computers.desktop, "changed", lambda: None), (computers.desktop, "hook", lambda e: None)):
            p = mock.patch.object(target, name, fake)
            p.start()
            self.addCleanup(p.stop)
        p = mock.patch.object(computers, "post", lambda u, data, headers: self.posts.append((u, data)))
        p.start()
        self.addCleanup(p.stop)

    def tearDown(self):
        self.state.stop()
        self.tmp.cleanup()

    def file(self, name, data=b"hello"):
        path = os.path.join(self.tmp.name, name)
        with open(path, "wb") as f:
            f.write(data)
        return path

    def test_a_send_to_a_computer_tailscale_has_offline_waits_without_a_try(self):
        self.assertEqual(computers.send(STUDIO, text="https://example.com"), ("waiting", "https://example.com"))
        self.assertEqual(self.posts, [])
        [w] = [outbox.public(e) for e in outbox.listed()]
        self.assertEqual((w["device"], w["deviceName"], w["kind"], w["text"]), ("studio", "Studio", "text",
                                                                              "https://example.com"))
        self.assertAlmostEqual(w["until"] - w["time"], 3 * 86400)
        with open(os.path.join(self.tmp.name, "sent.json")) as f:
            self.assertTrue(json.load(f)["waiting"])
        self.assertEqual(computers.deliver(STUDIO, text="again"), "")   # the old callers see it as gone

    def test_a_computer_that_doesnt_answer_gets_it_later_but_one_that_refuses_is_a_failure(self):
        online = dict(STUDIO, online=True)
        with mock.patch.object(computers, "post", side_effect=urllib.error.URLError("timed out")):
            self.assertEqual(computers.send(online, text="hi")[0], "waiting")
        with mock.patch.object(computers, "post", side_effect=refused(507)):
            self.assertEqual(computers.send(online, text="hi"), ("failed", "Studio refused it: Not enough room"))
        self.assertEqual(len(outbox.listed()), 1)

    def test_files_wait_as_copies_and_the_public_form_has_no_paths(self):
        src = self.file("photo.jpg")
        computers.send(STUDIO, files=[src])
        os.remove(src)   # moved or deleted meanwhile: the copy still goes
        [e] = outbox.listed()
        self.assertTrue(os.path.exists(e["files"][0]["path"]))
        w = outbox.public(e)
        self.assertEqual((w["name"], w["files"], w["size"]), ("photo.jpg", 1, 5))
        self.assertNotIn("path", json.dumps(w))

    def test_it_goes_once_the_computer_is_online_and_says_so(self):
        computers.send(STUDIO, text="see you", clip=True)
        self.assertEqual(outbox.flush(set(), {}), [])
        self.assertEqual(len(outbox.flush({"studio"}, {})), 1)
        [(u, data)] = self.posts
        self.assertEqual(u, "https://studio/ferry/api/text")
        self.assertEqual(json.loads(data), {"text": "see you", "clip": False})   # into the box, not the clipboard
        self.assertEqual(outbox.listed(), [])
        self.assertEqual(self.notes[-1][0], "Delivered to Studio")

    def test_a_computer_online_but_not_taking_it_yet_is_asked_again_after_a_minute(self):
        computers.send(STUDIO, text="later")
        missed = {}
        with mock.patch.object(computers, "post", side_effect=refused(502)):   # tailscale serve, Ferry not up yet
            self.assertEqual(outbox.flush({"studio"}, missed, now=1000.0), [])
        self.assertEqual(missed, {"studio": 1000.0})
        self.assertEqual(outbox.flush({"studio"}, missed, now=1030.0), [])
        self.assertEqual(self.posts, [])
        self.assertEqual(len(outbox.flush({"studio"}, missed, now=1061.0)), 1)
        self.assertEqual(missed, {})

    def test_a_computer_that_refuses_a_waiting_send_drops_it_and_the_user_hears(self):
        computers.send(STUDIO, text="too much")
        with mock.patch.object(computers, "post", side_effect=refused(413)):
            outbox.flush({"studio"}, {})
        self.assertEqual(outbox.listed(), [])
        self.assertEqual(self.notes[-1][0], "Couldn't send to Studio")

    def test_files_that_broke_off_go_on_from_the_first_one_not_taken(self):
        computers.send(STUDIO, files=[self.file("a.txt"), self.file("b.txt")])
        calls = []

        def second_fails(u, data, headers):
            calls.append(u)
            if len(calls) == 2:
                raise ConnectionResetError()
        with mock.patch.object(computers, "post", second_fails):
            outbox.flush({"studio"}, {}, now=100.0)
        [e] = outbox.listed()
        self.assertEqual([f["name"] for f in e["files"]], ["b.txt"])
        outbox.flush({"studio"}, {}, now=200.0)
        self.assertIn("name=b.txt", self.posts[0][0])
        self.assertEqual(outbox.listed(), [])

    def test_a_send_waits_three_days_a_code_fifteen_minutes(self):
        computers.send(STUDIO, text="see you")
        computers.send(STUDIO, text="801566")
        self.assertEqual(len(outbox.listed()), 2)
        with mock.patch("time.time", return_value=time.time() + 16 * 60):
            self.assertEqual([e["text"] for e in outbox.listed()], ["see you"])
        with mock.patch("time.time", return_value=time.time() + 3 * 86400 + 1):
            self.assertEqual(outbox.listed(), [])

    def test_cancel_and_clear_take_the_files_too(self):
        computers.send(STUDIO, files=[self.file("a.txt")])
        computers.send(STUDIO, text="x")
        first = outbox.listed()[-1]
        self.assertTrue(outbox.cancel(first["id"]))
        self.assertFalse(os.path.exists(os.path.join(outbox.folder(), first["id"])))
        self.assertFalse(outbox.cancel(first["id"]))
        outbox.clear()
        self.assertEqual(outbox.listed(), [])

    def test_nothing_goes_to_a_forgotten_computer(self):
        computers.send(STUDIO, text="x")
        with mock.patch.object(outbox.forget, "forgotten_ids", return_value={"studio"}):
            self.assertEqual(outbox.flush({"studio"}, {}), [])
        self.assertEqual(outbox.listed(), [])
        self.assertEqual(self.posts, [])

    def test_online_devices_are_the_owners_online_peers(self):
        st = {"Self": {"UserID": 1}, "Peer": {
            "a": {"DNSName": "studio.tail0.ts.net.", "UserID": 1, "Online": True},
            "b": {"DNSName": "macbook.tail0.ts.net.", "UserID": 1, "Online": False},
            "c": {"DNSName": "theirs.tail0.ts.net.", "UserID": 2, "Online": True}}}
        self.assertEqual(outbox.online_devices(st), {"studio"})


class Awake(unittest.TestCase):
    def test_told_at_start_and_after_each_sleep(self):
        gaps = iter([0, 0, 5, 3605, 3606])
        told = []

        class Stop(Exception):
            pass

        def gap():
            try:
                return next(gaps)
            except StopIteration:
                raise Stop()
        with self.assertRaises(Stop):
            wake.run(gap=gap, sleep=lambda s: None, tell=lambda: told.append(1))
        self.assertEqual(len(told), 2)   # at start, and after the hour asleep (not after 5 s)

    def test_announce_waits_for_the_network_and_gives_up(self):
        clock = iter(range(0, 1000, 15))
        ready = iter([False, False, True])
        sent = []
        went = wake.announce(is_ready=lambda: next(ready), send=lambda: sent.append(1) or True,
                             clock=lambda: next(clock), sleep=lambda s: None)
        self.assertTrue(went)
        self.assertEqual(sent, [1])
        self.assertIsNone(wake.announce(is_ready=lambda: True, send=lambda: None, clock=lambda: 0,
                                        sleep=lambda s: None))   # no app to tell: nothing to wait for
        clock = iter(range(0, 1000, 15))
        self.assertFalse(wake.announce(is_ready=lambda: False, send=lambda: True, clock=lambda: next(clock),
                                       sleep=lambda s: None))

    def test_the_awake_push_goes_to_the_apps_only_quietly(self):
        subs = [{"endpoint": "https://push.nightdrive.sh/push/a", "direct": True, "keys": {}},
                {"endpoint": "https://web.push.apple.com/b", "keys": {}}]
        with mock.patch.object(push, "vapid_key", return_value="key"), \
                mock.patch.object(push, "subscriptions", return_value=subs), \
                mock.patch.object(push, "send", return_value=True) as send:
            self.assertTrue(push.wake())
        to, content, _key, ttl, urgency = send.call_args.args
        self.assertEqual([s["endpoint"] for s in to], ["https://push.nightdrive.sh/push/a"])
        self.assertTrue(json.loads(content)["awake"])
        self.assertEqual((ttl, urgency), (3600, "very-low"))
        with mock.patch.object(push, "vapid_key", return_value="key"), \
                mock.patch.object(push, "subscriptions", return_value=subs[1:]):
            self.assertIsNone(push.wake())


if __name__ == "__main__":
    unittest.main()
