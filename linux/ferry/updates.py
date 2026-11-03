"""Updates: Ferry's releases on GitHub, the newest one for this install (a beta install follows pre-releases too).

An update runs code, the release's install.sh (and that asks for root for packages), so nothing runs unchecked: both
the script and the tarball are downloaded here and must match the sha256 GitHub's releases API gives for them, and the
script then installs that tarball (--from) rather than fetching its own. That guards the download, not the release
itself: a release made by someone with the repo's keys passes (signed releases are FER-02's).

An install another tool updates (Nightdrive pins Ferry's release and its sha256, and `nightdrive update` installs it)
says so in MANAGED, and then Ferry neither checks for updates nor installs one: it would go round that pin."""
import hashlib
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


MANAGED_NAME = re.compile(r"[^\w .+-]")   # what of MANAGED's text is shown: a name, not a terminal's escapes


def managed_by():
    """What updates this Ferry instead of it (MANAGED's first line: "Nightdrive"), or None: Ferry updates itself."""
    try:
        with open(config.MANAGED, errors="replace") as f:
            line = f.readline(200)
    except OSError:
        return None
    return MANAGED_NAME.sub("", line).strip()[:40] or "another app"


def sha256_of(asset):
    """An asset's sha256 from GitHub's "digest" ("sha256:<hex>"), or None: then it can't be checked."""
    algo, _, hexdigest = (asset.get("digest") or "").partition(":")
    return hexdigest.lower() if algo == "sha256" and re.fullmatch(r"[0-9a-fA-F]{64}", hexdigest) else None


def newest_release(releases, beta):
    """The newest release with Linux files whose sha256 GitHub gives (its releases API's list), pre-releases only for
    a beta: {version, tag, tarball, tarball_sha256, script, script_sha256}, or None."""
    found = []
    for r in releases:
        if r.get("draft") or (r.get("prerelease") and not beta):
            continue
        assets = {a.get("name"): a for a in r.get("assets") or []}
        tarball, script = assets.get(config.TARBALL) or {}, assets.get("install.sh") or {}
        if tarball.get("browser_download_url") and script.get("browser_download_url") \
                and sha256_of(tarball) and sha256_of(script):
            tag = r.get("tag_name", "")
            found.append({"version": tag.lstrip("v"), "tag": tag,
                          "tarball": tarball["browser_download_url"], "tarball_sha256": sha256_of(tarball),
                          "script": script["browser_download_url"], "script_sha256": sha256_of(script)})
    return max(found, key=lambda r: version_key(r["version"]), default=None)


def fetch_releases():
    req = urllib.request.Request(config.RELEASES, headers={"Accept": "application/vnd.github+json",
                                                    "User-Agent": f"Ferry/{config.VERSION}"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def check_update(fetch=fetch_releases, max_age=None):
    """A release newer than this Ferry, or None; asks GitHub unless it was asked in the last max_age seconds. The
    answer is kept in STATE/update.json for available_update(). A failed check raises (OSError, ValueError). An
    install another tool updates asks nothing."""
    if managed_by():
        return None
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
    if managed_by():
        return None
    if cached is None:
        try:
            with open(os.path.join(config.STATE, "update.json")) as f:
                cached = json.load(f)
        except (OSError, ValueError):
            return None
    latest = cached.get("latest")
    return latest if latest and version_key(latest["version"]) > version_key(config.VERSION) else None


def download(url, path):
    """url into path; its sha256."""
    digest = hashlib.sha256()
    req = urllib.request.Request(url, headers={"User-Agent": f"Ferry/{config.VERSION}"})
    with urllib.request.urlopen(req, timeout=30) as r, open(path, "wb") as f:
        while chunk := r.read(1 << 16):
            digest.update(chunk)
            f.write(chunk)
    return digest.hexdigest()


def update(check_only=False, fetch=fetch_releases):
    """`ferry update`: the newer release's own install script, run with that release's tarball, as a first install
    does (the packages it needs, the service restarted); both checked against GitHub's sha256 before anything runs."""
    who = managed_by()
    if who:
        print(f"{who} updates Ferry on this computer: update it there"
              f" (or remove {config.MANAGED} to let Ferry update itself)", file=sys.stderr)
        return 0 if check_only else 1
    try:
        new = check_update(fetch=fetch)
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
        script, tarball = os.path.join(tmp, "install.sh"), os.path.join(tmp, config.TARBALL)
        for url, path, want in ((new["script"], script, new["script_sha256"]),
                                (new["tarball"], tarball, new["tarball_sha256"])):
            if download(url, path) != want:
                print(f"Ferry {new['version']}'s {os.path.basename(path)} isn't the file GitHub has for the release"
                      " (its sha256 differs): not installed", file=sys.stderr)
                return 1
        return subprocess.run(["bash", script, "--from", tarball]).returncode
    except OSError as e:
        print(f"Couldn't download the update: {e}", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
