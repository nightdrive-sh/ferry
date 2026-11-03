"""The owner's other computers running Ferry, the device list, and sending to a device.

The server keeps the owner's computers that answer as Ferry in STATE/machines.json for the commands and the menu."""
import json
import mimetypes
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from . import config, desktop, forget, outbox, push, store, tailnet, terminal


def probe(host):
    """Ferry on one of the owner's machines: its address, name, tailnet name (id), seconds idle and forgotten devices, or
    None (not running, asleep)."""
    u = f"https://{host}{'' if config.HTTPS_PORT == 443 else f':{config.HTTPS_PORT}'}{config.MOUNT}/"
    try:
        req = urllib.request.Request(u + "api/ping", headers={"X-Ferry": "1"})
        return pinged(host, u, json.loads(urllib.request.urlopen(req, timeout=4).read()))
    except (OSError, ValueError, AttributeError):
        return None


def pinged(host, u, j):
    """probe()'s answer from a computer's api/ping: with its list of forgotten devices, to merge into this one's."""
    return {"url": u, "name": j.get("computer") or host.split(".")[0], "id": host.split(".")[0], "idle": j.get("idle"),
            "forgotten": j.get("forgotten") if isinstance(j.get("forgotten"), list) else []}


def known_machines(change=None):
    """The owner's computers that answered as Ferry ({id, name, url, idle, seen}), kept by the server for the commands
    and the menu; one that stops answering stays, asleep, while Tailscale still lists it."""
    path = os.path.join(config.STATE, "machines.json")
    try:
        with open(path) as f:
            out = json.load(f)
    except (OSError, ValueError):
        out = []
    if change:
        change(out)
        os.makedirs(config.STATE, mode=0o700, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(out, f, ensure_ascii=False)
        os.replace(tmp, path)
    return out


class Found:
    """The owner's other machines running Ferry, from the ones Tailscale has online. A machine is asked whether it runs
    Ferry when it comes online, again after a minute, and after 10 s if it didn't answer as Ferry (it may have come
    online before its Ferry started). One that goes offline leaves the list at once, and nothing is sent to it: a phone
    asks for this list every 10 s while one of its computers sleeps, instead of trying the sleeping one itself, which
    jammed the phone's Tailscale."""
    AGAIN, MISSED_AGAIN = 60, 10

    def __init__(self, probe=probe, clock=time.monotonic):
        self.probe, self.clock = probe, clock
        self.probed = {}    # host: (when, probe()'s answer or None)
        self.asked = []     # the hosts the last get() asked: only then is there news for known_machines

    def get(self, online):
        now = self.clock()
        due = [h for h in online if h not in self.probed
               or now - self.probed[h][0] > (self.AGAIN if self.probed[h][1] else self.MISSED_AGAIN)]
        self.asked = due
        results = [None] * len(due)

        def one(i, h):
            results[i] = self.probe(h)
        threads = [threading.Thread(target=one, args=(i, h), daemon=True) for i, h in enumerate(due)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(6)
        probed = {h: v for h, v in self.probed.items() if h in online}
        probed.update((h, (now, r)) for h, r in zip(due, results))
        self.probed = probed
        return sorted((r for _, r in probed.values() if r), key=lambda r: r["name"].lower())


def devices(st=None):
    """The owner's other devices, computers first, without the ones the owner forgot: {id (the short tailnet name),
    name, kind (computer, phone, tablet), online, inUse (a computer in use when last asked)}. Computers are the ones the
    server found running Ferry (machines.json), asleep while Tailscale says they're offline; phones and tablets are
    Tailscale's that have used Ferry here (docs/protocol.md › Forgetting a device)."""
    st = st or tailnet.tailscale_status()
    gone = forget.forgotten_ids()
    me = st.get("Self") or {}
    uid = me.get("UserID")
    peers = {(p.get("DNSName") or "").split(".")[0]: p for p in (st.get("Peer") or {}).values()
             if p.get("UserID") == uid and p.get("DNSName")}
    out = []
    for m in sorted(known_machines(), key=lambda m: m.get("name", "").lower()):
        p = peers.get(m.get("id"))
        if not p or p.get("OS") in ("iOS", "android") or m["id"] in gone:
            continue
        online = bool(p.get("Online"))
        out.append({"id": m["id"], "name": m.get("name") or m["id"], "kind": "computer", "online": online,
                    "inUse": online and m.get("idle") == 0})
    # A phone with a push subscription has used Ferry, also one that did before phones.json was kept (an update)
    used = forget.phones() | {s.get("device") for s in push.subscriptions()}
    for pid, p in sorted(peers.items()):
        if p.get("OS") in ("iOS", "android") and pid in used and pid not in gone:
            tablet = "ipad" in (pid + (p.get("HostName") or "")).lower() or "tablet" in pid.lower()
            out.append({"id": pid, "name": pid, "kind": "tablet" if tablet else "phone", "online": bool(p.get("Online")),
                        "inUse": False})
    return out


def target(devs=None):
    """The device sends go to: the one picked last (STATE/target) while it's still one of the owner's devices, else a
    phone (one online first), else another computer; None when there's no other device."""
    devs = devices() if devs is None else devs
    try:
        with open(os.path.join(config.STATE, "target")) as f:
            picked = f.read().strip()
    except OSError:
        picked = ""
    by_id = {d["id"]: d for d in devs}
    if picked in by_id:
        return by_id[picked]
    phones = [d for d in devs if d["kind"] != "computer"]
    return (sorted(phones, key=lambda d: not d["online"]) or devs or [None])[0]


def set_target(device_id):
    os.makedirs(config.STATE, mode=0o700, exist_ok=True)
    with open(os.path.join(config.STATE, "target"), "w") as f:
        f.write(device_id + "\n")


def mark_sent(what, to, error="", waiting=False):
    """What was just sent and to whom, for the menu's "Sent" (it shows the newest for a few seconds), or why a send
    didn't go (error), so the menu's button stops waiting. waiting: it waits for its computer (outbox)."""
    os.makedirs(config.STATE, mode=0o700, exist_ok=True)
    tmp = os.path.join(config.STATE, "sent.json.tmp")
    with open(tmp, "w") as f:
        json.dump(dict({"time": time.time(), "what": what, "to": to}, **({"error": error} if error else {}),
                       **({"waiting": True} if waiting else {})), f,
                  ensure_ascii=False)
    os.replace(tmp, os.path.join(config.STATE, "sent.json"))
    desktop.changed()


def last_sent():
    try:
        with open(os.path.join(config.STATE, "sent.json")) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    return d if time.time() - d.get("time", 0) < config.SENT_SHOWN else None


def machine_url(device_id):
    m = next((k for k in known_machines() if k.get("id") == device_id), None)
    return m.get("url", "") if m else ""


def post(u, data, headers):
    req = urllib.request.Request(u, data, method="POST", headers=dict({"X-Ferry": "1"}, **headers))
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def post_text(base, text, clip=False):
    post(base + "api/text", json.dumps({"text": text[:config.MAX_TEXT], "clip": clip}, ensure_ascii=False).encode(),
         {"Content-Type": "application/json"})


def post_file(base, path, name=None, kind=None, clip=False):
    kind = kind or mimetypes.guess_type(path)[0] or "application/octet-stream"
    q = urllib.parse.urlencode(dict({"name": name or os.path.basename(path), "type": kind},
                                    **({"clip": "1"} if clip else {})))
    with open(path, "rb") as f:
        post(base + "api/upload?" + q, f, {"Content-Type": "application/octet-stream",
                                           "Content-Length": str(os.path.getsize(path))})


def deliver(dev, files=None, text=None, clip=False):
    """Sends files or a text to one device (from devices()): into the box for a phone, straight to another computer.
    clip: it is the clipboard, which another computer puts on its own (a text, or an image file). Returns "" or why it
    failed; a send that waits for its computer counts as sent (send() tells them apart)."""
    state, detail = send(dev, files=files, text=text, clip=clip)
    return detail if state == "failed" else ""


def send(dev, files=None, text=None, clip=False):
    """deliver(), saying how it went: ("sent", what), ("waiting", what): the computer is asleep or off, and the send
    waits here until it is back (outbox), or ("failed", why)."""
    if files is not None:
        files = store.file_paths(files)
        if not files:
            return "failed", "No files to send there"
        what = os.path.basename(files[0]) if len(files) == 1 else f"{len(files)} files"
    else:
        if not (text or "").strip():
            return "failed", "Nothing to send"
        what = terminal.oneline(text, 60)
    if dev["kind"] != "computer":
        if files is not None:
            store.add_files(files, dev["id"])
        else:
            store.add_text(text, dev["id"])
        mark_sent(what, dev["name"])
        return "sent", what
    base = machine_url(dev["id"])
    if not base:
        return "failed", f"{dev['name']} isn't running Ferry"
    try:
        # One Tailscale has offline isn't tried: the try would only wait for its timeout
        if not dev.get("online", True):
            raise ConnectionError("offline")
        if files is None:
            post_text(base, text, clip)
        while files:
            post_file(base, files[0], clip=clip)
            files = files[1:]
    except urllib.error.HTTPError as e:
        print(f"send to {base} refused: {e.code}", file=sys.stderr)
        return "failed", f"{dev['name']} refused it: {e.read()[:200].decode(errors='replace')}"
    except (OSError, ValueError) as e:
        if dev.get("online", True):
            print(f"send to {base} failed: {e!r}, so it waits", file=sys.stderr)
        outbox.add(dev, files=files, text=text)   # the files it hasn't taken yet
        mark_sent(what, dev["name"], waiting=True)
        return "waiting", what
    mark_sent(what, dev["name"])
    return "sent", what
