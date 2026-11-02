"""Updates: Ferry's releases on GitHub, the newest one for this install (a beta install follows pre-releases too)."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

from . import config


def version_key(v):
    """1.0.0-beta.2 sorts before 1.0.0, which sorts before 1.0.1-beta.1."""
    base, _, pre = v.lstrip("v").partition("-")
    nums = tuple(int(n) for n in re.findall(r"\d+", base)[:3])
    return nums + ((0, int((re.findall(r"\d+", pre) or ["0"])[-1])) if pre else (1, 0))


def is_beta(v=None):
    """A beta install is one running a pre-release: it follows pre-releases, until it updates to a full release."""
    return "-" in (config.VERSION if v is None else v)


def newest_release(releases, beta):
    """The newest release with Linux files (GitHub's releases API's list), pre-releases only for a beta:
    {version, tag, tarball, script}, or None."""
    found = []
    for r in releases:
        if r.get("draft") or (r.get("prerelease") and not beta):
            continue
        assets = {a.get("name"): a.get("browser_download_url") for a in r.get("assets") or []}
        if assets.get(config.TARBALL) and assets.get("install.sh"):
            tag = r.get("tag_name", "")
            found.append({"version": tag.lstrip("v"), "tag": tag, "tarball": assets[config.TARBALL],
                          "script": assets["install.sh"]})
    return max(found, key=lambda r: version_key(r["version"]), default=None)


def fetch_releases():
    req = urllib.request.Request(config.RELEASES, headers={"Accept": "application/vnd.github+json",
                                                    "User-Agent": f"Ferry/{config.VERSION}"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def check_update(fetch=fetch_releases, max_age=None):
    """A release newer than this Ferry, or None; asks GitHub unless it was asked in the last max_age seconds. The
    answer is kept in STATE/update.json for available_update(). A failed check raises (OSError, ValueError)."""
    path = os.path.join(config.STATE, "update.json")
    try:
        with open(path) as f:
            cached = json.load(f)
    except (OSError, ValueError):
        cached = {}
    if max_age is None or time.time() - cached.get("checked", 0) > max_age:
        latest = newest_release(fetch(), is_beta())
        cached = {"checked": time.time(), "latest": latest}
        os.makedirs(config.STATE, mode=0o700, exist_ok=True)
        with open(path + ".tmp", "w") as f:
            json.dump(cached, f)
        os.replace(path + ".tmp", path)
    return available_update(cached)


def available_update(cached=None):
    """The last check's newer release, without asking GitHub."""
    if cached is None:
        try:
            with open(os.path.join(config.STATE, "update.json")) as f:
                cached = json.load(f)
        except (OSError, ValueError):
            return None
    latest = cached.get("latest")
    return latest if latest and version_key(latest["version"]) > version_key(config.VERSION) else None


def update(check_only=False):
    """`ferry update`: the newer release's own install script, run with that release's files, as a first install
    does (the packages it needs, the service restarted)."""
    try:
        new = check_update()
    except (OSError, ValueError) as e:
        print(f"Couldn't check for updates: {e}", file=sys.stderr)
        return 1
    if not new:
        print(f"Ferry {config.VERSION} is the latest" + (" (beta)" if is_beta() else ""))
        return 0
    if check_only:
        print(f"Ferry {new['version']} is out: ferry update installs it")
        return 0
    print(f"Updating Ferry {config.VERSION} to {new['version']}", flush=True)
    tmp = tempfile.mkdtemp()
    try:
        script = os.path.join(tmp, "install.sh")
        req = urllib.request.Request(new["script"], headers={"User-Agent": f"Ferry/{config.VERSION}"})
        with urllib.request.urlopen(req, timeout=30) as r, open(script, "wb") as f:
            shutil.copyfileobj(r, f)
        env = dict(os.environ, FERRY_DOWNLOAD_URL=new["tarball"])
        return subprocess.run(["bash", script] + (["--beta"] if is_beta(new["version"]) else []), env=env).returncode
    except OSError as e:
        print(f"Couldn't download the update: {e}", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
