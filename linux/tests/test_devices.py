"""Ferry's devices, the picked target and what each phone's page lists. Run from linux/:

    python3 -m unittest discover -s tests -p test_devices.py
"""
import json
import os
import tempfile
import unittest

from load import computers, config, forget, push, store, terminal


def peer(name, os_, online=True, uid=1):
    return {"DNSName": f"{name}.tail0.ts.net.", "OS": os_, "Online": online, "UserID": uid, "HostName": name}


STATUS = {"Self": {"UserID": 1, "DNSName": "nightdrive.tail0.ts.net."},
          "Peer": {"a": peer("nightdrive-pc", "linux"), "b": peer("studio", "linux", online=False),
                   "c": peer("iphone", "iOS"), "d": peer("ipad", "iOS", online=False),
                   "e": peer("server", "linux"), "f": peer("someone-elses", "iOS", uid=2)}}


class Devices(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state, config.STATE = config.STATE, self.tmp.name
        with open(os.path.join(self.tmp.name, "machines.json"), "w") as f:
            json.dump([{"id": "nightdrive-pc", "name": "Nightdrive PC", "url": "https://pc/ferry/", "idle": 0},
                       {"id": "studio", "name": "Studio", "url": "https://studio/ferry/", "idle": 900},
                       {"id": "gone", "name": "Gone", "url": "https://gone/ferry/"}], f)
        with open(os.path.join(self.tmp.name, "phones.json"), "w") as f:
            json.dump(["iphone", "ipad", "someone-elses"], f)

    def tearDown(self):
        config.STATE = self.state
        self.tmp.cleanup()

    def test_lists_ferry_computers_then_the_owners_phones(self):
        d = computers.devices(STATUS)
        self.assertEqual([(x["id"], x["kind"], x["online"]) for x in d], [
            ("nightdrive-pc", "computer", True), ("studio", "computer", False),
            ("ipad", "tablet", False), ("iphone", "phone", True)])
        self.assertTrue(d[0]["inUse"])
        self.assertEqual(d[0]["name"], "Nightdrive PC")

    def test_a_device_not_there_is_named_in_the_reason(self):   # not "no device yet" (ferry text --to x)
        devices, computers.devices = computers.devices, lambda: devices(STATUS)
        try:
            self.assertEqual(terminal.pick_device(["--to", "toaster", "hi"]),
                             (None, ["hi"], "No device toaster: see ferry devices"))
            self.assertEqual(terminal.pick_device(["--to"])[2], "--to needs a device: see ferry devices")
            dev, rest, why = terminal.pick_device(["--to", "iphone", "hi"])
            self.assertEqual((dev["id"], rest, why), ("iphone", ["hi"], ""))
        finally:
            computers.devices = devices

    def test_a_phone_is_listed_once_it_has_used_ferry(self):   # docs/protocol.md › Forgetting a device
        os.remove(os.path.join(self.tmp.name, "phones.json"))
        self.assertEqual([x["id"] for x in computers.devices(STATUS)], ["nightdrive-pc", "studio"])
        forget.phones("ipad")
        self.assertEqual([x["id"] for x in computers.devices(STATUS)], ["nightdrive-pc", "studio", "ipad"])

    def test_a_push_subscription_counts_as_having_used_it(self):   # an install from before phones.json
        os.remove(os.path.join(self.tmp.name, "phones.json"))
        with open(os.path.join(self.tmp.name, "push.json"), "w") as f:
            json.dump([{"endpoint": "https://p/1", "keys": {}, "device": "iphone"},
                       {"endpoint": "https://p/2", "keys": {}, "device": "your phone"}], f)
        self.assertEqual([x["id"] for x in computers.devices(STATUS)], ["nightdrive-pc", "studio", "iphone"])

    def test_phones_json_keeps_names_only(self):   # a file edited by hand
        with open(os.path.join(self.tmp.name, "phones.json"), "w") as f:
            json.dump(["iphone", "your phone", 5, None, "a.b"], f)
        self.assertEqual(forget.phones(), {"iphone"})
        with open(os.path.join(self.tmp.name, "phones.json"), "w") as f:
            json.dump({"not": "a list"}, f)
        self.assertEqual(forget.phones(), set())

    def test_target_defaults_to_a_phone_online(self):
        self.assertEqual(computers.target(computers.devices(STATUS))["id"], "iphone")

    def test_target_is_the_one_picked(self):
        computers.set_target("studio")
        self.assertEqual(computers.target(computers.devices(STATUS))["id"], "studio")

    def test_a_picked_device_that_went_falls_back(self):
        computers.set_target("gone")
        self.assertEqual(computers.target(computers.devices(STATUS))["id"], "iphone")

    def test_no_devices_no_target(self):
        self.assertIsNone(computers.target([]))

    def test_sent_shows_for_a_few_seconds(self):
        computers.mark_sent("x.pdf", "iphone")
        self.assertEqual(computers.last_sent()["to"], "iphone")


class ForDevice(unittest.TestCase):
    def test_a_phone_sees_what_is_for_it_or_for_any(self):
        self.assertTrue(store.for_device({"to": "phone", "for": "iphone"}, "iphone"))
        self.assertFalse(store.for_device({"to": "phone", "for": "ipad"}, "iphone"))
        self.assertTrue(store.for_device({"to": "phone"}, "iphone"))           # sent before "for" existed
        self.assertTrue(store.for_device({"to": "computer", "from": "ipad"}, "iphone"))

    def test_push_only_to_that_phone(self):
        subs = [{"endpoint": "https://p/1", "device": "iphone"}, {"endpoint": "https://p/2", "device": "ipad"}]
        self.assertEqual([s["device"] for s in push.recipients(subs, False, "ipad")], ["ipad"])
        self.assertEqual(len(push.recipients(subs, False)), 2)


if __name__ == "__main__":
    unittest.main()
