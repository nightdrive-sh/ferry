"""The window's look and words, without GTK (app/look.py). Run from linux/:

    python3 -m unittest discover -s tests -p test_look.py
"""
import json
import os
import re
import shutil
import tempfile
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app"))
import look  # noqa: E402


class Words(unittest.TestCase):
    def test_meta_line(self):
        item = {"kind": "file", "size": 5_700_000, "time": 1000, "from": "iphone"}
        self.assertEqual(look.meta(item, now=1000 + 720), "5.7 MB · 12 min · iphone")
        self.assertEqual(look.meta({"kind": "text", "time": 50}, now=60), "now")

    def test_sizes_and_ages_as_the_apps_say_them(self):
        self.assertEqual(look.human(240), "240 B")
        self.assertEqual(look.human(1_234), "1.2 KB")
        self.assertEqual(look.human(3_000_000_000_000), "3000.0 GB")
        self.assertEqual(look.age(3 * 3600 + 5), "3 h")
        self.assertEqual(look.age(2 * 86400), "2 d")

    def test_a_link_is_one_address_and_nothing_else(self):
        self.assertEqual(look.link(" https://nightdrive.sh/ferry \n"), "https://nightdrive.sh/ferry")
        self.assertIsNone(look.link("see https://nightdrive.sh"))
        self.assertIsNone(look.link("ftp://x"))
        self.assertIsNone(look.link("https://"))

    def test_a_code(self):
        self.assertEqual(look.code(" 123456\n"), "123456")
        self.assertIsNone(look.code("123"))
        self.assertIsNone(look.code("12a456"))

    def test_icons(self):
        self.assertEqual(look.item_icon({"kind": "file", "type": "image/png"}), "image")
        self.assertEqual(look.item_icon({"kind": "file", "type": "application/pdf"}), "file")
        self.assertEqual(look.item_icon({"kind": "text", "text": "https://a.b"}), "link")
        self.assertEqual(look.item_icon({"kind": "text", "text": "hi"}), "text")
        for name in set(look.STEP_ICONS.values()):
            self.assertIn(name, look.ICONS)

    def test_received_newest_first(self):
        items = [{"id": "a", "to": "computer", "time": 1}, {"id": "b", "to": "phone", "time": 3},
                 {"id": "c", "to": "computer", "time": 2}]
        self.assertEqual([i["id"] for i in look.received(items)], ["c", "a"])

    def test_tiles_online_first_and_who_takes_a_send(self):
        devs = [{"id": "mac", "kind": "computer", "online": False}, {"id": "pc", "kind": "computer", "online": True},
                {"id": "iphone", "kind": "phone", "online": False}]
        self.assertEqual([d["id"] for d in look.tiles(devs)], ["pc", "mac", "iphone"])
        self.assertFalse(look.can_take(devs[0]))
        self.assertTrue(look.can_take(devs[2]))   # a phone picks it up when it wakes

    def test_words(self):
        self.assertEqual(look.what(["/a/b.pdf"]), "b.pdf")
        self.assertEqual(look.what(["a", "b"]), "2 files")
        self.assertEqual(look.clear_question(1), "Clear 1 item?")
        self.assertEqual(look.clear_question(3), "Clear 3 items?")


class Look(unittest.TestCase):
    def test_both_palettes_have_every_colour(self):
        self.assertEqual(set(look.PALETTE["light"]), set(look.PALETTE["dark"]))
        for p in look.PALETTE.values():
            for v in p.values():
                self.assertRegex(v, r"^#[0-9A-F]{6}$")

    def test_the_style_sheet_names_only_the_palette_s_colours(self):
        sheet = look.css(look.PALETTE["dark"])
        self.assertNotIn("{p[", sheet)
        self.assertIn("#C071EB", sheet)
        self.assertEqual(sheet.count("{"), sheet.count("}"))

    def test_nightdrive_s_look_only_on_hyprland(self):
        self.assertTrue(look.hyprland("Hyprland"))
        self.assertFalse(look.hyprland("ubuntu:GNOME"))
        self.assertFalse(look.hyprland("KDE"))
        self.assertFalse(look.hyprland(""))

    def test_nightdrive_s_theme_as_the_palette(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        path = os.path.join(d, "theme.json")
        theme = {"primary": "#4d9bf0", "accent": "#bfd8f2", "sel": "#25303d", "card": "#12161b", "border": "#2f3a45",
                 "text": "#bdc9d3", "dim": "#8696a3", "name": "blue", "launcherBg": "#f7181722"}
        with open(path, "w") as f:
            json.dump(theme, f)
        p = look.nightdrive_palette(path)
        self.assertEqual(set(p), set(look.PALETTE["dark"]))
        self.assertEqual(p["background"], "rgba(24, 23, 34, 0.97)")
        self.assertEqual((p["primary"], p["tile"], p["hairline"]), ("#4d9bf0", "#25303d", "#232131"))
        self.assertEqual(p["away"], look.PALETTE["dark"]["away"])
        self.assertIn("rgba(24, 23, 34, 0.97)", look.css(p))
        with open(path, "w") as f:
            f.write("{")
        self.assertIsNone(look.nightdrive_palette(path))
        self.assertIsNone(look.nightdrive_palette(os.path.join(d, "none.json")))

    def test_svg(self):
        s = look.svg("copy", "#7B2FB0", 32)
        self.assertIn('stroke="#7B2FB0"', s)
        self.assertIn('width="32"', s)

    def test_tray_icon_shows_a_count(self):
        self.assertNotIn("<text", look.tray_svg(0))
        self.assertIn(">3</text>", look.tray_svg(3))
        self.assertIn(">9+</text>", look.tray_svg(12))
        self.assertTrue(re.search(r"<svg[^>]+width=\"44\"", look.tray_svg(1, 44)))

    def test_tray_icon_is_white_on_gnome_s_dark_top_bar(self):
        white = look.tray_svg(0, white=True)
        self.assertIn('stroke="#ffffff"', white)
        self.assertNotIn("linearGradient", white)
        self.assertIn(">2</text>", look.tray_svg(2, white=True))   # the badge stays violet
        self.assertIn("linearGradient", look.tray_svg(0))
        self.assertTrue(look.tray_white("ubuntu:GNOME"))
        self.assertTrue(look.tray_white("GNOME"))
        self.assertFalse(look.tray_white(""))

    def test_the_header_s_layout_without_the_window_icon(self):
        # KDE's GTK settings put the app icon in the header's corner: Ferry's own mark is by its title instead
        self.assertEqual(look.without_icon("icon:minimize,maximize,close"), ":minimize,maximize,close")
        self.assertEqual(look.without_icon("close,icon:menu"), "close:menu")
        self.assertEqual(look.without_icon("appmenu:close"), "appmenu:close")
        self.assertEqual(look.without_icon(""), "")

    def test_tray_icon_is_thinner_among_plasma_s_icons(self):   # Breeze's are drawn with fine lines
        thin = look.tray_svg(2, white=True, thin=True)
        self.assertIn('stroke-width="1.6"', thin)
        self.assertIn('stroke-width="2.1"', look.tray_svg(2, white=True))
        self.assertIn(">2</text>", thin)

    def plasma(self, files):
        home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, home)
        for path, text in files.items():
            os.makedirs(os.path.dirname(os.path.join(home, path)), exist_ok=True)
            with open(os.path.join(home, path), "w") as f:
                f.write(text)
        return home

    def test_tray_icon_is_white_on_plasma_s_dark_panel(self):
        # Fedora's KDE: light apps under a Breeze Dark panel, said by the look-and-feel's defaults
        home = self.plasma({".config/kdedefaults/plasmarc": "[Theme]\nname=breeze-dark\n",
                            ".config/kdeglobals": "[Colors:Window]\nBackgroundNormal=239,240,241\n"})
        self.assertTrue(look.tray_white("KDE", home))
        self.assertFalse(look.tray_white("KDE", self.plasma({".config/plasmarc": "[Theme]\nname=breeze-light\n"})))

    def test_the_users_plasma_theme_comes_first(self):
        home = self.plasma({".config/kdedefaults/plasmarc": "[Theme]\nname=breeze-dark\n",
                            ".config/plasmarc": "[Theme]\nname=breeze-light\n"})
        self.assertFalse(look.tray_white("KDE", home))

    def test_breeze_follows_the_colour_scheme(self):   # the "default" Plasma theme is the colour scheme's
        dark = self.plasma({".config/kdeglobals": "[General]\nColorScheme=BreezeDark\n\n"
                                                  "[Colors:Header]\nBackgroundNormal=41,44,48\n"
                                                  "[Colors:Window]\nBackgroundNormal=32,35,38\n"})
        self.assertTrue(look.tray_white("KDE", dark))
        light = self.plasma({".config/kdeglobals": "[Colors:Window]\nBackgroundNormal=239,240,241\n"})
        self.assertFalse(look.tray_white("KDE", light))
        self.assertFalse(look.tray_white("KDE", self.plasma({})))   # nothing to go by: the colours read on either

    def test_a_theme_of_its_own_keeps_the_colours(self):
        home = self.plasma({".config/plasmarc": "[Theme]\nname=Sweet\n",
                            ".config/kdeglobals": "[Colors:Window]\nBackgroundNormal=32,35,38\n"})
        self.assertFalse(look.tray_white("KDE", home))

    def test_the_sessions_config_dirs(self):
        home = self.plasma({"xdg/plasmarc": "[Theme]\nname=breeze-dark\n"})
        self.assertTrue(look.tray_white("KDE", home, os.path.join(home, "xdg")))


class Pages(unittest.TestCase):
    def test_add_device_closes_once_a_phone_subscribes(self):
        self.assertTrue(look.phone_added(0, {"push": 1}))
        self.assertTrue(look.phone_added(1, {"push": 2}))
        self.assertFalse(look.phone_added(1, {"push": 1}))   # the same phone scanning again changes nothing
        self.assertFalse(look.phone_added(1, {"push": 0}))
        self.assertFalse(look.phone_added(None, {"push": 1}))   # the page opened before the first listing
        self.assertFalse(look.phone_added(0, {}))


if __name__ == "__main__":
    unittest.main()
