"""Ferry in the desktop's app list, in Open With, and its tray icon started at login. Run from linux/:

    python3 -m unittest discover -s tests -p test_launcher.py
"""
import os
import tempfile
import unittest

from load import ferry


class Launcher(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.saved = {k: getattr(ferry, k) for k in ("APPLICATIONS", "ICONS", "AUTOSTART", "NO_TRAY", "ROOT")}
        ferry.APPLICATIONS = os.path.join(t, "share", "applications")
        ferry.ICONS = os.path.join(t, "share", "icons", "hicolor")
        ferry.AUTOSTART = os.path.join(t, "config", "autostart")
        ferry.NO_TRAY = os.path.join(t, "config", "ferry", "no-tray")
        self.data_home = ferry.data_home
        ferry.data_home = lambda: os.path.join(t, "share")
        self.ran = []
        self.run = ferry.quietly
        ferry.quietly = lambda *cmd: self.ran.append(cmd)

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(ferry, k, v)
        ferry.quietly = self.run
        ferry.data_home = self.data_home
        self.tmp.cleanup()

    def read(self, path):
        with open(path) as f:
            return f.read()

    def entry(self):
        return self.read(os.path.join(ferry.APPLICATIONS, ferry.APP_ID + ".desktop"))

    def autostart(self):
        return os.path.join(ferry.AUTOSTART, ferry.APP_ID + ".desktop")

    def test_the_app_entry_runs_this_ferry_and_takes_any_file(self):
        ferry.install_launcher()
        e = self.entry()
        exe = os.path.join(ferry.ROOT, "bin", "ferry")
        self.assertIn(f"Exec={exe} app %F\n", e)
        self.assertIn("Name=Ferry\n", e)
        # Not the types themselves: Ferry would become the default app for them
        self.assertIn("MimeType=application/octet-stream;\n", e)
        self.assertIn(f"Icon={ferry.APP_ID}\n", e)
        self.assertTrue(os.path.exists(os.path.join(ferry.ICONS, "512x512", "apps", ferry.APP_ID + ".png")))
        self.assertIn(("update-desktop-database", ferry.APPLICATIONS), self.ran)

    def test_send_with_ferry_in_the_file_managers_menus(self):
        ferry.install_launcher()
        menus = ferry.file_manager_menus()
        self.assertEqual(len(menus), 3)
        for path, (text, executable) in menus.items():
            self.assertIn(" app ", self.read(path))
            self.assertEqual(os.access(path, os.X_OK), executable)

    def test_a_path_with_a_space_is_quoted(self):
        ferry.ROOT = "/home/a b/ferry"
        self.assertIn('Exec="/home/a b/ferry/bin/ferry" app %F', ferry.desktop_entry())

    def test_the_tray_starts_at_login(self):
        ferry.install_launcher()
        e = self.read(self.autostart())
        self.assertIn(" app --background\n", e)
        self.assertIn("NoDisplay=true", e)

    def test_tray_off_holds_across_installs(self):
        ferry.install_launcher()
        ferry.set_tray(False)
        self.assertFalse(os.path.exists(self.autostart()))
        ferry.install_launcher()   # an update
        self.assertFalse(os.path.exists(self.autostart()))
        self.assertFalse(ferry.tray_wanted())
        ferry.set_tray(True)
        self.assertTrue(os.path.exists(self.autostart()))
        self.assertTrue(ferry.tray_wanted())


class ClipboardImage(unittest.TestCase):
    """An image from the clipboard goes onto another computer's clipboard too (api/upload's clip=1)."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state, ferry.STATE = ferry.STATE, self.tmp.name
        self.post, self.machine_url = ferry.post, ferry.machine_url
        self.posted = []
        ferry.post = lambda u, data, headers: self.posted.append(u)
        ferry.machine_url = lambda _id: "https://studio/ferry/"
        ferry.refresh_bar = lambda: None
        self.png = os.path.join(self.tmp.name, "Clipboard.png")
        with open(self.png, "wb") as f:
            f.write(b"\x89PNG")

    def tearDown(self):
        ferry.STATE, ferry.post, ferry.machine_url = self.state, self.post, self.machine_url
        self.tmp.cleanup()

    def test_clip_marks_the_upload(self):
        dev = {"id": "studio", "name": "Studio", "kind": "computer"}
        self.assertEqual(ferry.deliver(dev, files=[self.png], clip=True), "")
        self.assertIn("clip=1", self.posted[0])

    def test_files_without_clip(self):
        dev = {"id": "studio", "name": "Studio", "kind": "computer"}
        ferry.deliver(dev, files=[self.png])
        self.assertNotIn("clip", self.posted[0])


if __name__ == "__main__":
    unittest.main()
