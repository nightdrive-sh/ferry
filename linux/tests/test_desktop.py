"""The parts that depend on the desktop: finding it from a service, the clipboard, Show in Files and the hook. Run from
linux/:

    python3 -m unittest discover -s tests -p test_desktop.py
"""
import os
import stat
import subprocess
import tempfile
import unittest

from load import ferry


class DesktopEnv(unittest.TestCase):
    """The service starts with the user's session, maybe before the desktop: the desktop's variables are found when a
    clipboard tool or a notification needs them."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runtime = os.path.join(self.tmp.name, "run")
        self.x11 = os.path.join(self.tmp.name, "X11-unix")
        os.makedirs(self.runtime)
        os.makedirs(self.x11)

    def tearDown(self):
        self.tmp.cleanup()

    def touch(self, *path):
        open(os.path.join(*path), "w").close()

    def env(self, base, manager=None):
        def ask():
            if manager is None:
                raise AssertionError("the service manager wasn't to be asked")
            return manager
        return ferry.desktop_env(dict(base, XDG_RUNTIME_DIR=self.runtime), manager=ask, x11=self.x11)

    def test_a_command_run_on_the_desktop_keeps_its_own(self):
        env = self.env({"WAYLAND_DISPLAY": "wayland-0", "XDG_CURRENT_DESKTOP": "Hyprland"})
        self.assertEqual((env["WAYLAND_DISPLAY"], env["XDG_CURRENT_DESKTOP"]), ("wayland-0", "Hyprland"))

    def test_the_service_takes_them_from_the_service_manager(self):   # GNOME and KDE put them there
        self.touch(self.runtime, "wayland-1")
        env = self.env({}, {"WAYLAND_DISPLAY": "wayland-1", "DISPLAY": ":1", "XAUTHORITY": "/run/user/1/xauth",
                            "XDG_CURRENT_DESKTOP": "KDE", "PATH": "/elsewhere"})
        self.assertEqual({k: env.get(k) for k in ("WAYLAND_DISPLAY", "DISPLAY", "XAUTHORITY", "XDG_CURRENT_DESKTOP")},
                         {"WAYLAND_DISPLAY": "wayland-1", "DISPLAY": ":1", "XAUTHORITY": "/run/user/1/xauth",
                          "XDG_CURRENT_DESKTOP": "KDE"})
        self.assertNotEqual(env.get("PATH"), "/elsewhere")   # only the desktop's own variables

    def test_a_wayland_display_whose_socket_is_gone_is_dropped(self):   # a session that ended, a new one on another
        self.touch(self.runtime, "wayland-0")
        env = self.env({}, {"WAYLAND_DISPLAY": "wayland-1"})
        self.assertEqual(env["WAYLAND_DISPLAY"], "wayland-0")

    def test_found_from_the_sockets_when_the_desktop_told_nobody(self):   # e.g. Hyprland started without uwsm
        self.touch(self.runtime, "wayland-1")
        self.touch(self.runtime, "wayland-1.lock")
        self.touch(self.x11, "X0")
        env = self.env({}, {})
        self.assertEqual((env["WAYLAND_DISPLAY"], env["DISPLAY"]), ("wayland-1", ":0"))

    def test_no_desktop(self):   # a server without one: Ferry works, without the clipboard and notifications
        env = self.env({}, {})
        self.assertNotIn("WAYLAND_DISPLAY", env)
        self.assertNotIn("DISPLAY", env)


class Run:
    """subprocess.run as the clipboard calls it: records the commands, fails the tools named in fail."""

    def __init__(self, fail=(), out=b""):
        self.fail, self.out, self.calls = set(fail), out, []

    def __call__(self, cmd, input=None, **kw):
        self.calls.append((cmd, input, kw.get("env")))
        return subprocess.CompletedProcess(cmd, 1 if cmd[0] in self.fail else 0, self.out)


def have(*tools):
    return lambda name: f"/usr/bin/{name}" if name in tools else None


WAYLAND = {"WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"}   # a Wayland desktop with XWayland
X11 = {"DISPLAY": ":0"}


class Clipboard(unittest.TestCase):
    def test_wayland_first(self):
        run = Run()
        self.assertTrue(ferry.copy_text("801566", env=WAYLAND, run=run, have=have("wl-copy", "xclip")))
        self.assertEqual([c[0][0] for c in run.calls], ["wl-copy"])

    def test_the_text_goes_in_on_stdin(self):   # a 1 MiB text is too long for one argument
        run = Run()
        ferry.copy_text("x" * 300000, env=WAYLAND, run=run, have=have("wl-copy"))
        cmd, data, _ = run.calls[0]
        self.assertEqual(data, b"x" * 300000)
        self.assertTrue(all(len(a) < 100 for a in cmd))

    def test_x11s_clipboard_when_wayland_cant(self):   # GNOME has no data-control protocol; XWayland shares the clipboard
        run = Run(fail={"wl-copy"})
        self.assertTrue(ferry.copy_text("801566", env=WAYLAND, run=run, have=have("wl-copy", "xclip")))
        self.assertEqual([c[0][0] for c in run.calls], ["wl-copy", "xclip"])

    def test_x11(self):
        run = Run()
        self.assertTrue(ferry.copy_text("801566", env=X11, run=run, have=have("wl-copy", "xclip")))
        self.assertEqual(run.calls[0][0][:3], ["xclip", "-selection", "clipboard"])

    def test_the_desktops_variables_reach_the_tool(self):
        run = Run()
        ferry.copy_text("801566", env=WAYLAND, run=run, have=have("wl-copy"))
        self.assertEqual(run.calls[0][2]["WAYLAND_DISPLAY"], "wayland-0")

    def test_no_clipboard(self):
        self.assertFalse(ferry.copy_text("801566", env={}, run=Run(), have=have("wl-copy", "xclip")))
        self.assertFalse(ferry.copy_text("801566", env=WAYLAND, run=Run(), have=have()))

    def test_sensitive(self):   # Send Clipboard's text, a code: cliphist and Klipper keep no copy (wl-clipboard 2.3)
        run = Run()
        self.assertTrue(ferry.copy_text("801566", sensitive=True, env=WAYLAND, run=run, have=have("wl-copy", "xclip")))
        self.assertEqual([c[0][:2] for c in run.calls], [["wl-copy", "--sensitive"]])
        run = Run()
        ferry.copy_text("Milk, coffee", env=WAYLAND, run=run, have=have("wl-copy"))
        self.assertNotIn("--sensitive", run.calls[0][0])

    def test_a_wl_copy_without_sensitive_still_copies(self):   # before 2.3 it refuses the option
        class Old(Run):
            def __call__(self, cmd, input=None, **kw):
                r = super().__call__(cmd, input, **kw)
                return subprocess.CompletedProcess(cmd, 1 if "--sensitive" in cmd else r.returncode)
        run = Old()
        self.assertTrue(ferry.copy_text("801566", sensitive=True, env=WAYLAND, run=run, have=have("wl-copy", "xclip")))
        self.assertEqual([c[0][:2] for c in run.calls], [["wl-copy", "--sensitive"], ["wl-copy", "--type"]])

    def test_a_sensitive_image(self):
        with tempfile.NamedTemporaryFile(suffix=".png") as f:
            run = Run()
            self.assertTrue(ferry.copy_file(f.name, "image/png", sensitive=True, env=WAYLAND, run=run, have=have("wl-copy")))
            self.assertEqual(run.calls[0][0], ["wl-copy", "--sensitive", "--type", "image/png"])

    def test_an_image_with_its_type(self):
        with tempfile.NamedTemporaryFile(suffix=".png") as f:
            f.write(b"\x89PNG")
            f.flush()
            for env, tool in ((WAYLAND, "wl-copy"), (X11, "xclip")):
                run = Run()
                self.assertTrue(ferry.copy_file(f.name, "image/png", env=env, run=run, have=have("wl-copy", "xclip")))
                cmd, data, _ = run.calls[0]
                self.assertEqual((cmd[0], data), (tool, b"\x89PNG"))
                self.assertIn("image/png", cmd)

    def test_paste(self):
        run = Run(out="Grüße".encode())
        self.assertEqual(ferry.paste_text(env=WAYLAND, run=run, have=have("wl-paste", "wl-copy", "xclip")), "Grüße")
        self.assertEqual(run.calls[0][0][0], "wl-paste")

    def test_paste_from_x11_when_wayland_has_no_text(self):
        run = Run(fail={"wl-paste"}, out=b"code")
        self.assertEqual(ferry.paste_text(env=WAYLAND, run=run, have=have("wl-paste", "wl-copy", "xclip")), "code")
        self.assertEqual([c[0][0] for c in run.calls], ["wl-paste", "xclip"])

    def test_an_image_is_no_text(self):   # xclip, asked for the text of an image another xclip serves, gives its bytes
        run = Run(out=b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR")
        self.assertEqual(ferry.paste_text(env=X11, run=run, have=have("xclip")), "")

    def test_nothing_to_paste(self):
        self.assertEqual(ferry.paste_text(env=X11, run=Run(fail={"xclip"}), have=have("xclip")), "")


class ShowInFiles(unittest.TestCase):
    def test_asks_the_file_manager_to_select_it(self):   # Files, Dolphin, Nemo, Thunar: org.freedesktop.FileManager1
        cmd = ferry.show_in_files_cmd("/home/u/Downloads/it's a photo.jpg")
        self.assertIn("org.freedesktop.FileManager1.ShowItems", cmd)
        self.assertIn("['file:///home/u/Downloads/it%27s%20a%20photo.jpg']", cmd)


class Hook(unittest.TestCase):
    """A desktop's own Ferry UI (Nightdrive's top bar) hears about changes through ~/.config/ferry/hook."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.hook, ferry.HOOK = ferry.HOOK, os.path.join(self.tmp.name, "hook")

    def tearDown(self):
        ferry.HOOK = self.hook
        self.tmp.cleanup()

    def test_runs_with_the_event(self):
        out = os.path.join(self.tmp.name, "out")
        with open(ferry.HOOK, "w") as f:
            f.write(f"#!/bin/sh\necho \"$1\" > '{out}'\n")
        os.chmod(ferry.HOOK, stat.S_IRWXU)
        ferry.hook("changed").wait(5)
        with open(out) as f:
            self.assertEqual(f.read(), "changed\n")

    def test_none(self):
        self.assertIsNone(ferry.hook("changed"))


if __name__ == "__main__":
    unittest.main()
