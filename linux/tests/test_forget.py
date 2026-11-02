"""Forgetting a device on every computer (docs/protocol.md › Forgetting a device), and one direct subscription per
device. Run from linux/:

    python3 -m unittest discover -s tests -p test_forget.py
"""
import io
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from unittest import mock

from load import bin_ferry, config, desktop, forget, owner, push, tailnet
from test_devices import STATUS


def entry(device, t, forgotten=True):
    return {"device": device, "time": t, "forgotten": forgotten}


class Merge(unittest.TestCase):
    def test_the_later_decision_wins(self):
        mine = [entry("studio", 10.0), entry("iphone", 30.0, False)]
        theirs = [entry("studio", 20.0, False), entry("iphone", 20.0)]
        self.assertEqual(forget.merge_forgotten(mine, theirs), [entry("iphone", 30.0, False), entry("studio", 20.0, False)])

    def test_forgetting_wins_a_tie(self):
        self.assertEqual(forget.merge_forgotten([entry("studio", 5.0, False)], [entry("studio", 5.0)]),
                         [entry("studio", 5.0)])
        self.assertEqual(forget.merge_forgotten([entry("studio", 5.0)], [entry("studio", 5.0, False)]),
                         [entry("studio", 5.0)])

    def test_new_devices_are_taken_in(self):
        self.assertEqual(forget.merge_forgotten([], [entry("ipad", 1.0)]), [entry("ipad", 1.0)])

    def test_what_isnt_an_entry_is_left_out(self):   # another computer's answer is not to be trusted with our state
        theirs = [entry("ok", 1.0), "x", None, {"device": "no time", "time": 1.0, "forgotten": True},
                  {"device": "studio", "time": "1", "forgotten": True}, {"device": "studio", "time": 1.0},
                  {"device": "studio", "time": 1.0, "forgotten": 1}, {"device": "a" * 64, "time": 1.0, "forgotten": True},
                  {"device": "studio", "time": float("nan"), "forgotten": True}, {"device": "x", "time": True, "forgotten": True}]
        self.assertEqual(forget.merge_forgotten([], theirs), [entry("ok", 1.0)])
        self.assertEqual(forget.merge_forgotten([], {"not": "a list"}), [])
        self.assertEqual(forget.merge_forgotten([], None), [])

    def test_a_time_too_big_for_a_float_is_left_out(self):   # json.loads takes a 400-digit integer
        self.assertEqual(forget.merge_forgotten([], [entry("studio", 10 ** 400)]), [])

    def test_extra_fields_are_dropped(self):
        self.assertEqual(forget.merge_forgotten([], [dict(entry("studio", 2), name="x")]), [entry("studio", 2.0)])


class State(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state, config.STATE = config.STATE, self.tmp.name
        self.hooks = []
        self.hook, desktop.changed = desktop.changed, lambda: self.hooks.append(1)
        with open(os.path.join(self.tmp.name, "machines.json"), "w") as f:
            json.dump([{"id": "nightdrive-pc", "name": "Nightdrive PC", "url": "https://pc/ferry/", "idle": 0},
                       {"id": "studio", "name": "Studio", "url": "https://studio/ferry/", "idle": 900}], f)
        forget.phones("iphone")
        forget.phones("ipad")

    def tearDown(self):
        config.STATE = self.state
        desktop.changed = self.hook
        self.tmp.cleanup()

    def subscribe(self, endpoint, device, direct=True):
        sub = {"endpoint": endpoint, "keys": {"p256dh": "k", "auth": "a"}, "direct": direct}
        return push.subscribe(push.subscription(sub, device))

    def endpoints(self):
        return [s["endpoint"] for s in push.subscriptions()]

    def test_nothing_forgotten_at_first(self):
        self.assertEqual(forget.forgotten(), [])
        self.assertEqual(forget.forgotten_ids(), set())

    def test_forget_leaves_the_device_lists(self):
        forget.decide("studio", True)
        forget.decide("iphone", True)
        self.assertEqual([d["id"] for d in bin_ferry.devices(STATUS)], ["nightdrive-pc", "ipad"])
        self.assertEqual(forget.forgotten_ids(), {"studio", "iphone"})
        self.assertTrue(self.hooks)   # the desktop's menu hears of it

    def test_unforget_brings_it_back_and_keeps_the_entry(self):   # api/unforget {"device"}: a computer added again
        forget.decide("studio", True, now=lambda: 100.0)
        forget.decide("studio", False, now=lambda: 200.0)
        self.assertIn("studio", [d["id"] for d in bin_ferry.devices(STATUS)])
        self.assertEqual(forget.forgotten(), [entry("studio", 200.0, False)])

    def test_a_decision_here_beats_what_is_known_here(self):   # another computer's clock may be ahead of this one's
        forget.learn_forgotten([entry("studio", 5000.0)])
        forget.decide("studio", False, now=lambda: 100.0)
        self.assertEqual(forget.forgotten_ids(), set())
        self.assertGreater(forget.forgotten()[0]["time"], 5000.0)

    def test_the_target_moves_off_a_forgotten_device(self):
        bin_ferry.set_target("iphone")
        forget.decide("iphone", True)
        self.assertEqual(bin_ferry.target(bin_ferry.devices(STATUS))["id"], "ipad")

    def test_forgetting_a_phone_drops_its_subscriptions(self):
        self.subscribe("https://p/old", "iphone", direct=False)
        self.subscribe("https://p/app", "iphone")
        self.subscribe("https://p/ipad", "ipad")
        forget.decide("iphone", True)
        self.assertEqual(self.endpoints(), ["https://p/ipad"])

    def test_a_forgotten_phone_subscribes_in_vain(self):
        forget.decide("iphone", True)
        self.assertTrue(self.subscribe("https://p/app", "iphone"))   # answered 200 all the same
        self.assertEqual(self.endpoints(), [])

    def test_brought_back_it_subscribes_again(self):
        forget.decide("iphone", True, now=lambda: 1.0)
        forget.decide("iphone", False, now=lambda: 2.0)
        self.subscribe("https://p/app", "iphone")
        self.assertEqual(self.endpoints(), ["https://p/app"])

    def test_a_forget_while_subscribing_wins(self):   # the check and the write are apart: the forget lands between
        real = push.subscriptions

        def racing(change=None):
            if change:
                push.subscriptions = real
                forget.decide("iphone", True)
            return real(change)
        push.subscriptions = racing
        try:
            self.subscribe("https://p/app", "iphone")
        finally:
            push.subscriptions = real
        self.assertEqual(self.endpoints(), [])

    def test_learning_from_another_computer(self):
        self.subscribe("https://p/app", "iphone")
        self.assertTrue(forget.learn_forgotten([entry("iphone", 50.0), entry("studio", 50.0)]))
        self.assertEqual(forget.forgotten_ids(), {"iphone", "studio"})
        self.assertEqual(self.endpoints(), [])   # learnt elsewhere, the subscriptions go here too
        self.assertFalse(forget.learn_forgotten([entry("iphone", 10.0, False)]))   # older: nothing new
        self.assertEqual(forget.forgotten_ids(), {"iphone", "studio"})

    def test_learning_nothing_new_writes_nothing(self):
        forget.learn_forgotten([entry("studio", 50.0)])
        before = os.stat(os.path.join(self.tmp.name, "forgotten.json")).st_mtime_ns
        self.hooks.clear()
        self.assertFalse(forget.learn_forgotten([entry("studio", 50.0)]))
        self.assertEqual(os.stat(os.path.join(self.tmp.name, "forgotten.json")).st_mtime_ns, before)
        self.assertEqual(self.hooks, [])

    def test_a_forgotten_phone_that_asks_comes_back(self):   # api/unforget {"self": true}: added again
        forget.decide("iphone", True, now=lambda: 1.0)
        forget.bring_back("iphone")
        self.assertEqual(forget.forgotten_ids(), set())
        self.assertIn("iphone", [d["id"] for d in bin_ferry.devices(STATUS)])

    def test_one_not_forgotten_that_asks_changes_nothing(self):   # no entry for a device never forgotten
        forget.bring_back("ipad")
        forget.bring_back("your phone")
        self.assertEqual(forget.forgotten(), [])
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "forgotten.json")))

    def test_a_name_is_a_name_however_it_is_written(self):   # Tailscale's names are lowercase
        forget.decide("Studio", True)
        self.assertEqual(forget.forgotten_ids(), {"studio"})

    def test_device_names(self):
        for good in ("iphone", "nightdrive-pc", "a" * 63, "MacBook-Pro-2"):
            self.assertTrue(forget.device_name(good), good)
        for bad in ("", "a" * 64, "mac.tail0.ts.net", "../x", "x y", None, 5):
            self.assertFalse(forget.device_name(bad), bad)


class OneDirectSubscription(unittest.TestCase):   # 1644: an app installed again leaves its old address behind
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state, config.STATE = config.STATE, self.tmp.name

    def tearDown(self):
        config.STATE = self.state
        self.tmp.cleanup()

    def subscribe(self, endpoint, device, direct=True):
        sub = {"endpoint": endpoint, "keys": {"p256dh": "k", "auth": "a"}, "direct": direct}
        push.subscribe(push.subscription(sub, device))

    def test_a_new_direct_one_replaces_the_devices_old_one(self):
        self.subscribe("https://relay/1", "iphone")
        self.subscribe("https://web/pwa", "iphone", direct=False)
        self.subscribe("https://relay/ipad", "ipad")
        self.subscribe("https://relay/2", "iphone")
        self.assertEqual([s["endpoint"] for s in push.subscriptions()],
                         ["https://web/pwa", "https://relay/ipad", "https://relay/2"])

    def test_the_same_endpoint_again_replaces_it(self):
        self.subscribe("https://relay/1", "iphone")
        self.subscribe("https://relay/1", "iphone")
        self.assertEqual(len(push.subscriptions()), 1)

    def test_a_page_replaces_no_direct_one(self):
        self.subscribe("https://relay/1", "iphone")
        self.subscribe("https://web/pwa", "iphone", direct=False)
        self.assertEqual(len(push.subscriptions()), 2)

    def test_an_unnamed_device_replaces_nothing(self):   # "your phone" could be anyone's
        self.subscribe("https://relay/1", "your phone")
        self.subscribe("https://relay/2", "your phone")
        self.assertEqual(len(push.subscriptions()), 2)


class Found(unittest.TestCase):
    def test_the_ping_carries_the_list(self):
        answers = {"studio.tail0.ts.net": {"computer": "Studio", "idle": 5, "forgotten": [entry("iphone", 1.0)]}}

        def probe(host):
            j = answers[host]
            return bin_ferry.pinged(host, "https://" + host + "/ferry/", j)
        r = probe("studio.tail0.ts.net")
        self.assertEqual(r["forgotten"], [entry("iphone", 1.0)])
        self.assertEqual((r["id"], r["name"], r["idle"]), ("studio", "Studio", 5))

    def test_a_ping_without_a_list(self):   # an older Ferry
        r = bin_ferry.pinged("old.tail0.ts.net", "https://old.tail0.ts.net/ferry/", {"computer": "Old"})
        self.assertEqual(r["forgotten"], [])


class Tailnet:
    """tailnet.Tailnet as the handler and Ferry.machines() use it, without Tailscale: the owner on nightdrive, an iPhone
    and an iPad asking, the computer studio online."""
    def __init__(self):
        self.me = "nightdrive.tail0.ts.net"
        self.names = {"100.64.0.2": "iphone", "100.64.0.3": "ipad", "100.64.0.4": "studio"}
        self.phones = {"iphone", "ipad"}
        self.machines = ["studio.tail0.ts.net"]
        self.ids = {"studio"}

    def load(self, force=False):
        pass

    def allowed(self, login):
        return login == "owner@example.com"

    def for_me(self, host):
        return host == self.me

    def same_owner(self, url):
        return False

    def device(self, ip):
        return self.names.get(ip, "")


class App(unittest.TestCase):
    """The server's side, with a Ferry made without Tailscale or a VAPID key."""
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.state = tmp.name
        for name, value in (("STATE", tmp.name), ("changed", lambda: None), ("alias", lambda: "Nightdrive"),
                            ("idle_for", lambda: 0), ("url", lambda st=None: "https://nightdrive.tail0.ts.net/ferry/")):
            p = mock.patch.object(owner(name), name, value)
            p.start()
            self.addCleanup(p.stop)
        self.app = bin_ferry.Ferry.__new__(bin_ferry.Ferry)
        self.app.tailnet = Tailnet()
        self.app.key = None
        self.app.lock = threading.Lock()
        self.app.used = None
        self.app.back = False
        self.answers = {}   # host: its api/ping
        self.app.found = bin_ferry.Found(probe=lambda h: bin_ferry.pinged(h, f"https://{h}/ferry/", self.answers[h])
                                     if h in self.answers else None)

    def listed(self):
        st = {"Self": {"UserID": 1, "DNSName": "nightdrive.tail0.ts.net."},
              "Peer": {"p": {"DNSName": "iphone.tail0.ts.net.", "OS": "iOS", "UserID": 1, "Online": True},
                       "t": {"DNSName": "ipad.tail0.ts.net.", "OS": "iOS", "UserID": 1, "Online": True}}}
        return [d["id"] for d in bin_ferry.devices(st)]


class Api(App):
    def setUp(self):
        super().setUp()
        out = mock.patch.object(sys, "stdout", io.StringIO())   # the journal's line for every request
        out.start()
        self.addCleanup(out.stop)
        self.server = bin_ferry.Server(("127.0.0.1", 0), bin_ferry.handler(self.app))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def call(self, path, body=None, ip="100.64.0.2"):
        """A call as tailscale serve passes it on from the owner's device at ip ("": none named)."""
        headers = {"Host": "nightdrive.tail0.ts.net", "Tailscale-User-Login": "owner@example.com", "X-Ferry": "1",
                   "Content-Type": "application/json"}
        if ip:
            headers["X-Forwarded-For"] = ip
        req = urllib.request.Request(f"http://127.0.0.1:{self.server.server_address[1]}/{path}",
                                     None if body is None else json.dumps(body).encode(), headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError as e:
            with e:
                return e.code, None

    def test_a_phone_is_listed_once_it_calls(self):
        self.assertEqual(self.listed(), [])
        self.assertEqual(self.call("api/ping")[0], 200)
        self.assertEqual(self.listed(), ["iphone"])
        self.call("api/remove?id=x", {}, ip="100.64.0.3")   # a POST too
        self.assertEqual(self.listed(), ["ipad", "iphone"])

    def test_a_poll_writes_nothing(self):   # a page asks every few seconds
        self.call("api/ping")
        before = os.stat(os.path.join(self.state, "phones.json")).st_mtime_ns
        with mock.patch.object(forget, "phones", side_effect=AssertionError("written again")):
            self.assertEqual(self.call("api/ping")[0], 200)
        self.assertEqual(os.stat(os.path.join(self.state, "phones.json")).st_mtime_ns, before)

    def test_a_computer_or_an_unnamed_device_isnt_kept(self):
        self.call("api/ping", ip="100.64.0.4")
        self.call("api/ping", ip="100.64.0.9")
        self.call("api/ping", ip="")
        self.assertFalse(os.path.exists(os.path.join(self.state, "phones.json")))

    def test_a_refused_call_isnt_use(self):
        req = urllib.request.Request(f"http://127.0.0.1:{self.server.server_address[1]}/api/ping", headers={
            "Host": "nightdrive.tail0.ts.net", "Tailscale-User-Login": "owner@example.com", "X-Forwarded-For": "100.64.0.2"})
        with self.assertRaises(urllib.error.HTTPError) as refused:   # no X-Ferry: not from a Ferry page
            urllib.request.urlopen(req, timeout=10)
        refused.exception.close()
        self.assertEqual(self.listed(), [])

    def test_unforget_self_brings_the_asking_phone_back(self):
        self.call("api/ping")
        forget.decide("iphone", True)
        self.assertEqual(self.listed(), [])
        self.assertEqual(self.call("api/unforget", {"self": True}), (200, {"ok": True}))
        self.assertEqual(forget.forgotten_ids(), set())
        self.assertEqual(self.listed(), ["iphone"])

    def test_unforget_self_of_one_not_forgotten_adds_nothing(self):
        forget.decide("studio", True)
        self.assertEqual(self.call("api/unforget", {"self": True}, ip="100.64.0.3"), (200, {"ok": True}))
        self.assertEqual(self.call("api/unforget", {"self": True}, ip="100.64.0.9"), (200, {"ok": True}))   # unnamed
        self.assertEqual([e["device"] for e in forget.forgotten()], ["studio"])

    def test_unforget_of_a_device_still_works(self):
        forget.decide("studio", True)
        self.assertEqual(self.call("api/unforget", {"device": "studio"}), (200, {"ok": True}))
        self.assertEqual(forget.forgotten_ids(), set())
        self.assertEqual(self.call("api/unforget", {"self": False})[0], 400)
        self.assertEqual(self.call("api/unforget", {"self": "yes"})[0], 400)
        self.assertEqual(self.call("api/forget", {"self": True})[0], 400)   # nothing forgets itself


class ComingBack(App):   # docs/protocol.md › What forgetting does: a computer's Ferry starting brings it back
    def test_forgotten_before_it_started(self):
        forget.decide("nightdrive", True, now=lambda: 10.0)
        self.answers["studio.tail0.ts.net"] = {"computer": "Studio", "forgotten": forget.forgotten()}
        self.app.machines()
        self.assertEqual(forget.forgotten_ids(), set())

    def test_forgotten_while_it_was_off(self):   # learned from the others in the first round, then undone
        self.answers["studio.tail0.ts.net"] = {"computer": "Studio", "forgotten": [entry("nightdrive", 5000.0)]}
        self.app.machines()
        self.assertEqual(forget.forgotten_ids(), set())
        self.assertGreater(forget.forgotten()[0]["time"], 5000.0)   # so it wins on the others too

    def test_no_other_computer_answers(self):
        forget.decide("nightdrive", True)
        self.app.machines()
        self.assertEqual(forget.forgotten_ids(), set())

    def test_a_forget_after_the_start_holds(self):
        self.app.machines()
        forget.decide("nightdrive", True)
        self.app.machines()
        self.assertEqual(forget.forgotten_ids(), {"nightdrive"})

    def test_not_before_it_knows_its_name(self):   # Tailscale not up yet: nobody was asked
        self.app.tailnet.me = ""
        forget.decide("nightdrive", True)
        self.app.machines()
        self.assertEqual(forget.forgotten_ids(), {"nightdrive"})
        self.app.tailnet.me = "nightdrive.tail0.ts.net"
        self.app.machines()
        self.assertEqual(forget.forgotten_ids(), set())

    def test_others_stay_forgotten(self):
        forget.decide("studio", True)
        self.app.machines()
        self.assertEqual(forget.forgotten_ids(), {"studio"})


class Commands(App):   # Forget is final: nothing but adding a device again brings it back
    def run_ferry(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["ferry", *args]), mock.patch.object(bin_ferry, "migrate", lambda: False), \
                mock.patch.object(tailnet, "tailscale_status", lambda: STATUS), \
                mock.patch.object(sys, "stdout", out), mock.patch.object(sys, "stderr", err):
            return bin_ferry.main(), out.getvalue(), err.getvalue()

    def test_no_unforget_command(self):
        forget.decide("studio", True)
        code, _, err = self.run_ferry("unforget", "studio")
        self.assertEqual(code, 1)
        self.assertIn("ferry forget DEVICE", err)   # the usage
        self.assertNotIn("unforget", err)
        self.assertEqual(forget.forgotten_ids(), {"studio"})

    def test_forget(self):
        with open(os.path.join(self.state, "machines.json"), "w") as f:
            json.dump([{"id": "studio", "name": "Studio", "url": "https://studio/ferry/"}], f)
        self.assertEqual(self.run_ferry("forget", "Studio")[0], 0)
        self.assertEqual(forget.forgotten_ids(), {"studio"})
        self.assertEqual(self.run_ferry("forget", "Studio")[0], 1)   # not listed any more

    def test_devices_doesnt_list_the_forgotten(self):
        forget.phones("iphone")
        forget.decide("iphone", True)
        code, out, _ = self.run_ferry("devices")
        self.assertEqual(code, 0)
        self.assertNotIn("iphone", out)

    def test_the_listing_has_no_forgotten(self):   # what Nightdrive's menu reads
        forget.phones("iphone")
        forget.phones("ipad")
        forget.decide("iphone", True)
        with mock.patch.object(tailnet, "tailscale_status", lambda: STATUS), \
                mock.patch.object(tailnet, "systemctl", lambda *a: mock.Mock(returncode=0)), \
                mock.patch.object(tailnet, "serving", lambda: True), mock.patch.object(bin_ferry, "available_update", lambda: None):
            d = bin_ferry.listing()
        self.assertEqual([x["id"] for x in d["devices"]], ["ipad"])
        self.assertNotIn("forgotten", d)


if __name__ == "__main__":
    unittest.main()
