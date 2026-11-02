"""The phones that used Ferry here (phones.json) and the devices the owner forgot (forgotten.json).

A forgotten device leaves every computer's and phone's lists until it is added again: the list reaches the other
computers through api/ping, merged by time."""
import json
import math
import os
import re
import time

from . import config, desktop, push, store


DEVICE_NAME = re.compile(r"[A-Za-z0-9-]{1,63}")


def device_name(name):
    """Whether name is a device's short tailnet name, as api/forget takes it."""
    return isinstance(name, str) and bool(DEVICE_NAME.fullmatch(name))


def phones(new=None):
    """The phones and tablets that have used Ferry here (their short tailnet names), the ones the device list shows
    (docs/protocol.md › Forgetting a device): the server adds one (new) the first time it calls, under the box's
    lock."""
    path = os.path.join(config.STATE, "phones.json")
    with store.box(write=new is not None):
        try:
            with open(path) as f:
                out = json.load(f)
        except (OSError, ValueError):
            out = []
        out = {n for n in out if device_name(n)} if isinstance(out, list) else set()   # a file edited by hand
        if new is not None and new not in out:
            out.add(new)
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(sorted(out), f)
            os.replace(tmp, path)
        return out


def forgotten(change=None):
    """The devices the owner forgot, or brought back ({device, time, forgotten}: docs/protocol.md › Forgetting a
    device); change(list) edits them under the box's lock, and returns whether it changed anything (only then is it
    written)."""
    path = os.path.join(config.STATE, "forgotten.json")
    with store.box(write=change is not None):
        try:
            with open(path) as f:
                out = json.load(f)
        except (OSError, ValueError):
            out = []
        out = merge_forgotten([], out)   # a file edited by hand keeps only what is an entry
        if change and change(out):
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(out, f)
            os.replace(tmp, path)
        return out


def merge_forgotten(mine, theirs):
    """mine with theirs merged in, device by device: the later decision wins, forgetting on a tie, so every computer
    ends up with the same list whatever order it hears things in. What isn't an entry is left out (theirs comes from
    another computer's answer)."""
    by = {e["device"]: e for e in mine}
    for e in theirs if isinstance(theirs, list) else []:
        if not (isinstance(e, dict) and device_name(e.get("device")) and isinstance(e.get("forgotten"), bool)
                and isinstance(e.get("time"), (int, float)) and not isinstance(e.get("time"), bool)):
            continue
        try:
            t = float(e["time"])   # an integer too big for a float (json.loads takes any) raises
        except OverflowError:
            continue
        if not math.isfinite(t):
            continue
        new = {"device": e["device"], "time": t, "forgotten": e["forgotten"]}
        old = by.get(new["device"])
        if old is None or (new["time"], new["forgotten"]) > (old["time"], old["forgotten"]):
            by[new["device"]] = new
    return sorted(by.values(), key=lambda e: e["device"])


def forgotten_ids(entries=None):
    """The short tailnet names of the devices forgotten now."""
    return {e["device"] for e in (forgotten() if entries is None else entries) if e["forgotten"]}


def drop_subscriptions(ids):
    """A forgotten phone's push subscriptions go: it gets no more notifications from here."""
    if ids:
        push.subscriptions(lambda s: s.__setitem__(slice(None), [x for x in s if x.get("device") not in ids]))


def decide(device, forget, now=time.time):
    """Forgets a device (api/forget, ferry forget), or brings it back (api/unforget, this computer's Ferry starting):
    decided now, and later than anything this computer knows of it, so it wins here even over a computer whose clock is
    ahead. The others learn it from api/ping."""
    device = device.lower()   # Tailscale's names are lowercase, however a request writes one

    def change(entries):
        old = next((e for e in entries if e["device"] == device), None)
        t = now() if old is None else max(now(), old["time"] + 0.001)
        entries[:] = merge_forgotten([e for e in entries if e["device"] != device],
                                     [{"device": device, "time": t, "forgotten": forget}])
        return True
    gone = forgotten_ids(forgotten(change))
    drop_subscriptions(gone)
    desktop.changed()


def bring_back(device):
    """api/unforget {"self": true}: the asking device, just added again, back if it is forgotten here. One that isn't
    gets no entry, and nothing is written."""
    if device.lower() in forgotten_ids():
        decide(device, False)


def learn_forgotten(theirs):
    """Another computer's list (from its api/ping) merged into this one's. True when it changed anything."""
    news = []

    def change(entries):
        merged = merge_forgotten(entries, theirs)
        if merged != entries:
            entries[:] = merged
            news.append(True)
        return bool(news)
    gone = forgotten_ids(forgotten(change))
    if news:
        drop_subscriptions(gone)
        desktop.changed()
    return bool(news)
