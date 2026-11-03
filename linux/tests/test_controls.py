"""What another device sent reaches a terminal and a file name without its controls: `ferry list` and `ferry get` show
them as escapes, `ferry list --json` writes them as JSON escapes, and a received file's name has none. Run from linux/:

    python3 -m unittest discover -s tests -p test_controls.py

The characters are made with chr(): typed in, they would be as invisible here as they are in a terminal."""
import contextlib
import io
import json
import unittest
from unittest import mock

from load import cli, controls, install, store, terminal

ESC, BEL, DEL, CSI = chr(0x1B), chr(0x07), chr(0x7F), chr(0x9B)   # CSI: C1's ESC [
RLO, LRI, RLM = chr(0x202E), chr(0x2066), chr(0x200F)
OSC52 = ESC + "]52;c;aGk=" + BEL   # sets the terminal's clipboard


def visible(text):
    """No C0 but line breaks and tabs, no C1, DEL or bidi control: nothing a terminal acts on."""
    return not controls.TEXT.search(text)


class Shown(unittest.TestCase):
    def test_controls_become_escapes(self):
        self.assertEqual(controls.shown("a" + OSC52 + "b"), "a\\x1b]52;c;aGk=\\x07b")
        self.assertEqual(controls.shown(DEL + CSI + RLO + LRI + RLM), "\\x7f\\x9b\\u202e\\u2066\\u200f")

    def test_plain_text_is_left_alone(self):
        for text in ("Hyvää päivää", "日本語", "emoji 🚢", "Ünïcödé — · …"):
            self.assertEqual(controls.shown(text), text)

    def test_a_text_keeps_its_lines_and_tabs(self):
        self.assertEqual(controls.shown_text("one\r\ntwo\tthree\n"), "one\ntwo\tthree\n")
        self.assertEqual(controls.shown_text("pay 10\rpay 99" + ESC + "[2K"), "pay 10\\x0dpay 99\\x1b[2K")

    def test_json_keeps_the_text_and_shows_no_control(self):
        item = {"text": "x" + OSC52 + CSI + RLO + DEL}
        out = controls.json_text(json.dumps(item, ensure_ascii=False))
        self.assertTrue(visible(out))
        self.assertEqual(json.loads(out), item)


class Names(unittest.TestCase):
    def test_bidi_cant_turn_a_name_around(self):
        self.assertEqual(store.safe_name("photo" + RLO + "gpj.exe"), "photogpj.exe")

    def test_c1_del_and_c0_go(self):
        self.assertEqual(store.safe_name("a" + CSI + "b" + DEL + "c" + ESC + "d" + chr(0) + ".pdf"), "abcd.pdf")

    def test_isolates_and_marks_go(self):
        self.assertEqual(store.safe_name(LRI + "report" + RLM + ".txt"), "report.txt")

    def test_what_was_kept_before(self):
        self.assertEqual(store.safe_name("../../.bashrc"), "bashrc")
        self.assertEqual(store.safe_name("C:\\Users\\x\\kuva ä.jpg"), "kuva ä.jpg")
        self.assertEqual(store.safe_name(RLO), "file")


class Terminal(unittest.TestCase):
    TEXT = {"id": "t", "to": "computer", "kind": "text", "text": "hi " + OSC52 + " " + RLO + "there", "time": 0,
            "from": "iPhone" + ESC + "]0;pwned" + BEL, "seen": True}
    FILE = {"id": "f", "to": "computer", "kind": "file", "name": "a" + RLO + "fdp.exe", "size": 3, "time": 0,
            "seen": True}

    def run_out(self, fn, *args, tty=True):
        out = io.StringIO()
        out.isatty = lambda: tty
        with contextlib.redirect_stdout(out), mock.patch.object(store, "copied"), \
                mock.patch.object(store, "mark_seen"):
            fn(*args)
        return out.getvalue()

    def test_list_shows_no_control(self):
        with mock.patch.object(store, "numbered", lambda: [self.TEXT, self.FILE]):
            out = self.run_out(terminal.print_list)
        self.assertTrue(visible(out), repr(out))
        self.assertIn("\\x1b]52;c;aGk=\\x07", out)
        self.assertIn("a\\u202efdp.exe", out)
        self.assertIn("iPhone\\x1b]0;pwned\\x07", out)

    def test_get_shows_escapes_to_a_terminal(self):
        out = self.run_out(terminal.get, dict(self.TEXT, text="code 1234\n" + OSC52 + "\n"))
        self.assertEqual(out, "code 1234\n\\x1b]52;c;aGk=\\x07\n")

    def test_get_piped_gives_the_text_as_it_came(self):
        text = "bytes " + OSC52 + RLO
        self.assertEqual(self.run_out(terminal.get, dict(self.TEXT, text=text), tty=False), text)

    def test_list_json(self):
        with mock.patch.object(cli, "listing", lambda: {"items": [store.public(self.TEXT)]}), \
                mock.patch.object(install, "migrate", lambda: False), \
                mock.patch.object(cli.sys, "argv", ["ferry", "list", "--json"]):
            out = self.run_out(cli.main)
        self.assertTrue(visible(out), repr(out))
        self.assertEqual(json.loads(out)["items"][0]["text"], self.TEXT["text"])


if __name__ == "__main__":
    unittest.main()
