"""Ferry's updates: which release a computer moves to, and the check's cache. Run from linux/:

    python3 -m unittest discover -s tests -p test_update.py
"""
import json
import os
import tempfile
import unittest

from load import ferry


def release(tag, pre=False, draft=False, assets=("ferry-linux.tar.gz", "install.sh")):
    return {"tag_name": tag, "prerelease": pre, "draft": draft,
            "assets": [{"name": a, "browser_download_url": f"https://example/{tag}/{a}"} for a in assets]}


RELEASES = [release("v1.1.0-beta.1", pre=True), release("v1.0.1"), release("v1.0.0"),
            release("v1.0.0-beta.2", pre=True), release("v2.0.0", draft=True),
            release("v1.2.0", assets=("Ferry-1.2.0-130.dmg",))]   # a Mac-only release


class Versions(unittest.TestCase):
    def test_a_pre_release_comes_before_its_release(self):
        k = ferry.version_key
        self.assertLess(k("1.0.0-beta.2"), k("1.0.0"))
        self.assertLess(k("1.0.0-beta.2"), k("1.0.0-beta.10"))
        self.assertLess(k("1.0.0"), k("1.0.1-beta.1"))
        self.assertLess(k("0.9.12"), k("1.0.0"))
        self.assertEqual(k("v1.0.0"), k("1.0.0"))

    def test_a_beta_install_is_one_running_a_pre_release(self):
        self.assertTrue(ferry.is_beta("1.0.0-beta.1"))
        self.assertFalse(ferry.is_beta("1.0.0"))


class Newest(unittest.TestCase):
    def test_a_full_install_follows_full_releases_with_linux_files(self):
        self.assertEqual(ferry.newest_release(RELEASES, beta=False)["version"], "1.0.1")

    def test_a_beta_install_follows_pre_releases_too(self):
        r = ferry.newest_release(RELEASES, beta=True)
        self.assertEqual(r["version"], "1.1.0-beta.1")
        self.assertEqual(r["tarball"], "https://example/v1.1.0-beta.1/ferry-linux.tar.gz")
        self.assertEqual(r["script"], "https://example/v1.1.0-beta.1/install.sh")

    def test_none(self):
        self.assertIsNone(ferry.newest_release([], beta=False))
        self.assertIsNone(ferry.newest_release([release("v1.0.0", draft=True)], beta=True))


class Check(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state, ferry.STATE = ferry.STATE, self.tmp.name
        self.version = ferry.VERSION
        self.asked = 0

    def tearDown(self):
        ferry.STATE, ferry.VERSION = self.state, self.version
        self.tmp.cleanup()

    def fetch(self):
        self.asked += 1
        return RELEASES

    def test_finds_a_newer_release(self):
        ferry.VERSION = "1.0.0"
        self.assertEqual(ferry.check_update(fetch=self.fetch)["version"], "1.0.1")

    def test_nothing_newer(self):
        ferry.VERSION = "1.0.1"
        self.assertIsNone(ferry.check_update(fetch=self.fetch))

    def test_a_beta_moves_to_the_full_release_after_it(self):
        ferry.VERSION = "1.0.0-beta.2"
        self.assertEqual(ferry.check_update(fetch=self.fetch)["version"], "1.1.0-beta.1")
        ferry.VERSION = "1.0.0-beta.2"
        only_full = [r for r in RELEASES if not r["prerelease"] or r["tag_name"] == "v1.0.0-beta.2"]
        self.assertEqual(ferry.check_update(fetch=lambda: only_full)["version"], "1.0.1")

    def test_a_recent_check_is_reused(self):
        ferry.VERSION = "1.0.0"
        ferry.check_update(fetch=self.fetch)
        self.assertEqual(ferry.check_update(fetch=self.fetch, max_age=3600)["version"], "1.0.1")
        self.assertEqual(self.asked, 1)
        ferry.check_update(fetch=self.fetch)   # no max_age: asks again
        self.assertEqual(self.asked, 2)

    def test_the_cache_says_nothing_after_the_update(self):
        ferry.VERSION = "1.0.0"
        ferry.check_update(fetch=self.fetch)
        ferry.VERSION = "1.0.1"
        self.assertIsNone(ferry.available_update())

    def test_a_failed_check_raises_and_keeps_the_last_answer(self):
        ferry.VERSION = "1.0.0"
        ferry.check_update(fetch=self.fetch)

        def down():
            raise OSError("no network")
        with self.assertRaises(OSError):
            ferry.check_update(fetch=down)
        self.assertEqual(ferry.available_update()["version"], "1.0.1")

    def test_the_cache_is_json_in_state(self):
        ferry.VERSION = "1.0.0"
        ferry.check_update(fetch=self.fetch)
        with open(os.path.join(self.tmp.name, "update.json")) as f:
            self.assertEqual(json.load(f)["latest"]["version"], "1.0.1")


if __name__ == "__main__":
    unittest.main()
