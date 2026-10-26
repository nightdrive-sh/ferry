"""Where Ferry keeps its state, and the move of a Nightdrive install's state (the plugin this server came from) to it.
Run from linux/:

    python3 -m unittest discover -s tests -p test_state.py
"""
import json
import os
import tempfile
import unittest

from load import ferry


class StateDir(unittest.TestCase):
    def test_follows_xdg_data_home(self):
        self.assertEqual(ferry.state_dir({"XDG_DATA_HOME": "/data"}, "/home/u"), "/data/ferry")

    def test_defaults_to_local_share(self):
        self.assertEqual(ferry.state_dir({}, "/home/u"), "/home/u/.local/share/ferry")


class Migrate(unittest.TestCase):
    """A state folder as Nightdrive's plugin left it: the VAPID key, the phones' subscriptions, the computers it found,
    the computers that pass its notifications on, the picked device and the box, with a file left for a phone."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.old = os.path.join(root, "share", "nightdrive", "ferry")
        self.new = os.path.join(root, "share", "ferry")
        downloads = os.path.join(root, "Downloads")
        os.makedirs(os.path.join(self.old, "files", "a1b2c3d4e5f6"))
        os.makedirs(downloads)
        self.phone_file = os.path.join(self.old, "files", "a1b2c3d4e5f6", "photo.jpg")
        self.received = os.path.join(downloads, "notes.pdf")
        self.files = {
            "vapid.pem": "-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n",
            "push.json": json.dumps([{"endpoint": "https://push.nightdrive.sh/push/x", "keys": {"p256dh": "k", "auth": "a"},
                                      "device": "iphone", "time": 1, "direct": True}]),
            "machines.json": json.dumps([{"id": "macbook", "name": "MacBook", "url": "https://macbook.t.ts.net/ferry/"}]),
            "relays.json": json.dumps(["https://studio.t.ts.net/ferry/"]),
            "target": "iphone\n",
            "lock": "",
        }
        for name, content in self.files.items():
            with open(os.path.join(self.old, name), "w") as f:
                f.write(content)
        for path in (self.phone_file, self.received):
            with open(path, "w") as f:
                f.write("bytes")
        now = ferry.time.time()
        self.items = [
            {"id": "a1b2c3d4e5f6", "to": "phone", "kind": "file", "name": "photo.jpg", "size": 5, "type": "image/jpeg",
             "path": self.phone_file, "for": "iphone", "time": now},
            {"id": "0123456789ab", "to": "computer", "kind": "file", "name": "notes.pdf", "size": 5,
             "type": "application/pdf", "path": self.received, "from": "iphone", "seen": False, "time": now},
            {"id": "ba9876543210", "to": "computer", "kind": "text", "text": "801566", "from": "iphone", "seen": True,
             "time": now},
        ]
        with open(os.path.join(self.old, "items.json"), "w") as f:
            json.dump({"items": self.items}, f)
        self.stopped = []

    def tearDown(self):
        self.tmp.cleanup()

    def migrate(self):
        # The old server is stopped first, while its state is still where it left it
        return ferry.migrate(self.old, self.new, stop=lambda: self.stopped.append(os.path.isdir(self.old)))

    def test_moves_everything(self):
        self.assertTrue(self.migrate())
        for name, content in self.files.items():
            with open(os.path.join(self.new, name)) as f:
                self.assertEqual(f.read(), content, name)
        self.assertTrue(os.path.exists(os.path.join(self.new, "files", "a1b2c3d4e5f6", "photo.jpg")))
        self.assertFalse(os.path.exists(self.old))

    def test_the_old_server_is_stopped_first(self):
        self.migrate()
        self.assertEqual(self.stopped, [True])

    def test_files_left_for_a_phone_point_to_the_new_place(self):
        self.migrate()
        with open(os.path.join(self.new, "items.json")) as f:
            paths = [i.get("path") for i in json.load(f)["items"]]
        self.assertEqual(paths, [os.path.join(self.new, "files", "a1b2c3d4e5f6", "photo.jpg"), self.received, None])

    def test_the_box_is_whole_afterwards(self):   # a write prunes items whose file is gone: none may look gone
        self.migrate()
        state, ferry.STATE = ferry.STATE, self.new
        try:
            with ferry.box(write=True) as items:
                self.assertEqual([i["id"] for i in items], [i["id"] for i in self.items])
        finally:
            ferry.STATE = state

    def test_the_state_stays_private(self):
        os.chmod(self.old, 0o755)
        self.migrate()
        self.assertEqual(os.stat(self.new).st_mode & 0o777, 0o700)

    def test_nothing_to_move(self):
        empty = os.path.join(self.tmp.name, "none")
        self.assertFalse(ferry.migrate(empty, self.new, stop=lambda: self.stopped.append(True)))
        self.assertFalse(os.path.exists(self.new))
        self.assertEqual(self.stopped, [])

    def test_never_over_ferrys_own_state(self):   # Ferry already ran here: the old folder is left alone
        os.makedirs(self.new)
        self.assertFalse(self.migrate())
        self.assertTrue(os.path.exists(os.path.join(self.old, "vapid.pem")))
        self.assertEqual(os.listdir(self.new), [])


if __name__ == "__main__":
    unittest.main()
