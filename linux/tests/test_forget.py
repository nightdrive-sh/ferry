"""Forgetting a device on every computer (docs/protocol.md › Forgetting a device), and one direct subscription per
device. Run from linux/:

    python3 -m unittest discover -s tests -p test_forget.py
"""
import json
import os
import tempfile
import unittest

from load import ferry
from test_devices import STATUS


def entry(device, t, forgotten=True):
    return {"device": device, "time": t, "forgotten": forgotten}


class Merge(unittest.TestCase):
    def test_the_later_decision_wins(self):
        mine = [entry("studio", 10.0), entry("iphone", 30.0, False)]
        theirs = [entry("studio", 20.0, False), entry("iphone", 20.0)]
        self.assertEqual(ferry.merge_forgotten(mine, theirs), [entry("iphone", 30.0, False), entry("studio", 20.0, False)])

    def test_forgetting_wins_a_tie(self):
        self.assertEqual(ferry.merge_forgotten([entry("studio", 5.0, False)], [entry("studio", 5.0)]),
                         [entry("studio", 5.0)])
        self.assertEqual(ferry.merge_forgotten([entry("studio", 5.0)], [entry("studio", 5.0, False)]),
                         [entry("studio", 5.0)])

    def test_new_devices_are_taken_in(self):
        self.assertEqual(ferry.merge_forgotten([], [entry("ipad", 1.0)]), [entry("ipad", 1.0)])

    def test_what_isnt_an_entry_is_left_out(self):   # another computer's answer is not to be trusted with our state
        theirs = [entry("ok", 1.0), "x", None, {"device": "no time", "time": 1.0, "forgotten": True},
                  {"device": "studio", "time": "1", "forgotten": True}, {"device": "studio", "time": 1.0},
                  {"device": "studio", "time": 1.0, "forgotten": 1}, {"device": "a" * 64, "time": 1.0, "forgotten": True},
                  {"device": "studio", "time": float("nan"), "forgotten": True}, {"device": "x", "time": True, "forgotten": True}]
        self.assertEqual(ferry.merge_forgotten([], theirs), [entry("ok", 1.0)])
        self.assertEqual(ferry.merge_forgotten([], {"not": "a list"}), [])
        self.assertEqual(ferry.merge_forgotten([], None), [])

    def test_a_time_too_big_for_a_float_is_left_out(self):   # json.loads takes a 400-digit integer
        self.assertEqual(ferry.merge_forgotten([], [entry("studio", 10 ** 400)]), [])

    def test_extra_fields_are_dropped(self):
        self.assertEqual(ferry.merge_forgotten([], [dict(entry("studio", 2), name="x")]), [entry("studio", 2.0)])


class State(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state, ferry.STATE = ferry.STATE, self.tmp.name
        self.hooks = []
        self.hook, ferry.changed = ferry.changed, lambda: self.hooks.append(1)
        with open(os.path.join(self.tmp.name, "machines.json"), "w") as f:
            json.dump([{"id": "nightdrive-pc", "name": "Nightdrive PC", "url": "https://pc/ferry/", "idle": 0},
                       {"id": "studio", "name": "Studio", "url": "https://studio/ferry/", "idle": 900}], f)

    def tearDown(self):
        ferry.STATE = self.state
        ferry.changed = self.hook
        self.tmp.cleanup()

    def subscribe(self, endpoint, device, direct=True):
        sub = {"endpoint": endpoint, "keys": {"p256dh": "k", "auth": "a"}, "direct": direct}
        return ferry.subscribe(ferry.subscription(sub, device))

    def endpoints(self):
        return [s["endpoint"] for s in ferry.subscriptions()]

    def test_nothing_forgotten_at_first(self):
        self.assertEqual(ferry.forgotten(), [])
        self.assertEqual(ferry.forgotten_ids(), set())

    def test_forget_leaves_the_device_lists(self):
        ferry.decide("studio", True)
        ferry.decide("iphone", True)
        self.assertEqual([d["id"] for d in ferry.devices(STATUS)], ["nightdrive-pc", "ipad"])
        self.assertEqual([(d["id"], d["kind"]) for d in ferry.devices(STATUS, forgotten=True)],
                         [("studio", "computer"), ("iphone", "phone")])
        self.assertEqual(ferry.forgotten_ids(), {"studio", "iphone"})
        self.assertTrue(self.hooks)   # the desktop's menu hears of it

    def test_unforget_brings_it_back_and_keeps_the_entry(self):
        ferry.decide("studio", True, now=lambda: 100.0)
        ferry.decide("studio", False, now=lambda: 200.0)
        self.assertIn("studio", [d["id"] for d in ferry.devices(STATUS)])
        self.assertEqual(ferry.forgotten(), [entry("studio", 200.0, False)])

    def test_a_decision_here_beats_what_is_known_here(self):   # another computer's clock may be ahead of this one's
        ferry.learn_forgotten([entry("studio", 5000.0)])
        ferry.decide("studio", False, now=lambda: 100.0)
        self.assertEqual(ferry.forgotten_ids(), set())
        self.assertGreater(ferry.forgotten()[0]["time"], 5000.0)

    def test_the_target_moves_off_a_forgotten_device(self):
        ferry.set_target("iphone")
        ferry.decide("iphone", True)
        self.assertEqual(ferry.target(ferry.devices(STATUS))["id"], "ipad")

    def test_forgetting_a_phone_drops_its_subscriptions(self):
        self.subscribe("https://p/old", "iphone", direct=False)
        self.subscribe("https://p/app", "iphone")
        self.subscribe("https://p/ipad", "ipad")
        ferry.decide("iphone", True)
        self.assertEqual(self.endpoints(), ["https://p/ipad"])

    def test_a_forgotten_phone_subscribes_in_vain(self):
        ferry.decide("iphone", True)
        self.assertTrue(self.subscribe("https://p/app", "iphone"))   # answered 200 all the same
        self.assertEqual(self.endpoints(), [])

    def test_brought_back_it_subscribes_again(self):
        ferry.decide("iphone", True, now=lambda: 1.0)
        ferry.decide("iphone", False, now=lambda: 2.0)
        self.subscribe("https://p/app", "iphone")
        self.assertEqual(self.endpoints(), ["https://p/app"])

    def test_a_forget_while_subscribing_wins(self):   # the check and the write are apart: the forget lands between
        real = ferry.subscriptions

        def racing(change=None):
            if change:
                ferry.subscriptions = real
                ferry.decide("iphone", True)
            return real(change)
        ferry.subscriptions = racing
        try:
            self.subscribe("https://p/app", "iphone")
        finally:
            ferry.subscriptions = real
        self.assertEqual(self.endpoints(), [])

    def test_learning_from_another_computer(self):
        self.subscribe("https://p/app", "iphone")
        self.assertTrue(ferry.learn_forgotten([entry("iphone", 50.0), entry("studio", 50.0)]))
        self.assertEqual(ferry.forgotten_ids(), {"iphone", "studio"})
        self.assertEqual(self.endpoints(), [])   # learnt elsewhere, the subscriptions go here too
        self.assertFalse(ferry.learn_forgotten([entry("iphone", 10.0, False)]))   # older: nothing new
        self.assertEqual(ferry.forgotten_ids(), {"iphone", "studio"})

    def test_learning_nothing_new_writes_nothing(self):
        ferry.learn_forgotten([entry("studio", 50.0)])
        before = os.stat(os.path.join(self.tmp.name, "forgotten.json")).st_mtime_ns
        self.hooks.clear()
        self.assertFalse(ferry.learn_forgotten([entry("studio", 50.0)]))
        self.assertEqual(os.stat(os.path.join(self.tmp.name, "forgotten.json")).st_mtime_ns, before)
        self.assertEqual(self.hooks, [])

    def test_a_name_is_a_name_however_it_is_written(self):   # Tailscale's names are lowercase
        ferry.decide("Studio", True)
        self.assertEqual(ferry.forgotten_ids(), {"studio"})

    def test_device_names(self):
        for good in ("iphone", "nightdrive-pc", "a" * 63, "MacBook-Pro-2"):
            self.assertTrue(ferry.device_name(good), good)
        for bad in ("", "a" * 64, "mac.tail0.ts.net", "../x", "x y", None, 5):
            self.assertFalse(ferry.device_name(bad), bad)


class OneDirectSubscription(unittest.TestCase):   # 1644: an app installed again leaves its old address behind
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state, ferry.STATE = ferry.STATE, self.tmp.name

    def tearDown(self):
        ferry.STATE = self.state
        self.tmp.cleanup()

    def subscribe(self, endpoint, device, direct=True):
        sub = {"endpoint": endpoint, "keys": {"p256dh": "k", "auth": "a"}, "direct": direct}
        ferry.subscribe(ferry.subscription(sub, device))

    def test_a_new_direct_one_replaces_the_devices_old_one(self):
        self.subscribe("https://relay/1", "iphone")
        self.subscribe("https://web/pwa", "iphone", direct=False)
        self.subscribe("https://relay/ipad", "ipad")
        self.subscribe("https://relay/2", "iphone")
        self.assertEqual([s["endpoint"] for s in ferry.subscriptions()],
                         ["https://web/pwa", "https://relay/ipad", "https://relay/2"])

    def test_the_same_endpoint_again_replaces_it(self):
        self.subscribe("https://relay/1", "iphone")
        self.subscribe("https://relay/1", "iphone")
        self.assertEqual(len(ferry.subscriptions()), 1)

    def test_a_page_replaces_no_direct_one(self):
        self.subscribe("https://relay/1", "iphone")
        self.subscribe("https://web/pwa", "iphone", direct=False)
        self.assertEqual(len(ferry.subscriptions()), 2)

    def test_an_unnamed_device_replaces_nothing(self):   # "your phone" could be anyone's
        self.subscribe("https://relay/1", "your phone")
        self.subscribe("https://relay/2", "your phone")
        self.assertEqual(len(ferry.subscriptions()), 2)


class Found(unittest.TestCase):
    def test_the_ping_carries_the_list(self):
        answers = {"studio.tail0.ts.net": {"computer": "Studio", "idle": 5, "forgotten": [entry("iphone", 1.0)]}}

        def probe(host):
            j = answers[host]
            return ferry.pinged(host, "https://" + host + "/ferry/", j)
        r = probe("studio.tail0.ts.net")
        self.assertEqual(r["forgotten"], [entry("iphone", 1.0)])
        self.assertEqual((r["id"], r["name"], r["idle"]), ("studio", "Studio", 5))

    def test_a_ping_without_a_list(self):   # an older Ferry
        r = ferry.pinged("old.tail0.ts.net", "https://old.tail0.ts.net/ferry/", {"computer": "Old"})
        self.assertEqual(r["forgotten"], [])


if __name__ == "__main__":
    unittest.main()
