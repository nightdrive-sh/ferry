"""Sends that wait: what this computer sent to another computer that was asleep or off, kept here until it is back.

The queue is the sender's (docs/protocol.md › Sends that wait): nothing waits on the other computer or on the push
relay, which never sees content. The server delivers a send as soon as Tailscale lists its computer online again
(run()), and drops it after WAIT unclaimed, a code or a password after SECRET_KEEP as the box does. A send of the
clipboard arrives as an ordinary text or file: put onto the other clipboard hours later, it would replace whatever
was copied there since.

Kept in STATE/outbox.json, with each send's files (a hard link, else a copy) in STATE/outbox/<id>/, so a file moved or
deleted meanwhile still goes."""
import contextlib
import fcntl
import json
import mimetypes
import os
import secrets
import shutil
import sys
import time
import urllib.error

from . import computers, config, desktop, forget, notices, store, tailnet, terminal

WAIT = 3 * 86400      # seconds a send waits for its computer (Jari, 3.11.: three days, so a weekend is covered)
EVERY = 15            # seconds between looks at Tailscale while something waits
AFTER_MISS = 60       # seconds before a computer that is online but didn't take a send is tried again


def folder():
    return os.path.join(config.STATE, "outbox")


@contextlib.contextmanager
def queue(write=False):
    """The waiting sends (oldest first), under a lock of their own; saved after a write, with the expired ones gone."""
    os.makedirs(config.STATE, mode=0o700, exist_ok=True)
    with open(os.path.join(config.STATE, "outbox.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX if write else fcntl.LOCK_SH)
        path = os.path.join(config.STATE, "outbox.json")
        try:
            with open(path) as f:
                entries = json.load(f).get("sends") or []
        except (OSError, ValueError, AttributeError):
            entries = []
        kept = [e for e in entries if alive(e)]
        yield kept
        if write:
            for e in entries:
                if e not in kept:
                    drop_files(e)
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"sends": kept}, f, ensure_ascii=False)
            os.replace(tmp, path)


def until(entry):
    """When an unclaimed send is dropped."""
    return entry.get("time", 0) + (config.SECRET_KEEP if is_secret(entry) else WAIT)


def alive(entry):
    return time.time() < until(entry) and all(os.path.exists(f.get("path", "")) for f in entry.get("files") or [])


def is_secret(entry):
    return entry.get("kind") == "text" and store.looks_secret(entry.get("text"))


def drop_files(entry):
    shutil.rmtree(os.path.join(folder(), entry.get("id", "-")), ignore_errors=True)


def add(dev, files=None, text=None):
    """Keeps a send for the computer dev (from computers.devices()) until it is back; its entry."""
    e = {"id": secrets.token_hex(6), "time": time.time(), "device": dev["id"], "name": dev["name"]}
    if files is None:
        e.update(kind="text", text=text[:config.MAX_TEXT])
    else:
        d = os.path.join(folder(), e["id"])
        os.makedirs(d, mode=0o700, exist_ok=True)
        e.update(kind="file", files=[])
        for src in files:
            dest = store.unique(os.path.join(d, store.safe_name(os.path.basename(src))))
            try:
                os.link(src, dest)
            except OSError:
                shutil.copy2(src, dest)
            e["files"].append({"path": dest, "name": os.path.basename(src), "size": os.path.getsize(dest),
                               "type": mimetypes.guess_type(src)[0] or "application/octet-stream"})
    with queue(write=True) as entries:
        entries.append(e)
    desktop.changed()
    return e


def what(entry):
    """A send in a few words, as "Sent" names one."""
    if entry.get("kind") == "text":
        return config.SECRET_NAMED if is_secret(entry) else terminal.oneline(entry.get("text", ""), 60)
    files = entry.get("files") or []
    return files[0]["name"] if len(files) == 1 else f"{len(files)} files"


def public(entry):
    """A waiting send as `ferry list --json` has it: never its files' paths, and a code or a password only as such."""
    d = {"id": entry["id"], "time": entry["time"], "until": until(entry), "device": entry["device"],
         "deviceName": entry["name"], "kind": entry["kind"]}
    if entry["kind"] == "text":
        d["text"] = entry.get("text", "")
        if is_secret(entry):
            d["secret"] = True
    else:
        files = entry.get("files") or []
        d.update(name=what(entry), files=len(files), size=sum(f.get("size", 0) for f in files))
    return d


def listed():
    """The waiting sends, newest first (as `ferry list` numbers them, after the box)."""
    with queue() as entries:
        return entries[::-1]


def cancel(entry_id):
    """A waiting send dropped; whether there was one."""
    with queue(write=True) as entries:
        found = [e for e in entries if e["id"] == entry_id]
        for e in found:
            entries.remove(e)
            drop_files(e)
    if found:
        desktop.changed()
    return bool(found)


def clear():
    with queue(write=True) as entries:
        for e in entries:
            drop_files(e)
        entries.clear()
    desktop.changed()


def deliver(entry, base):
    """One waiting send to its computer at base: "sent" once it took all of it, "missed" when it didn't answer (try
    again), "refused" when it said no (no room, too big): that one is dropped and the user told. A file it took is
    crossed off, so a send of many files that breaks off goes on from there next time."""
    try:
        if entry["kind"] == "text":
            computers.post_text(base, entry.get("text", ""), clip=False)
            return "sent"
        for f in list(entry.get("files") or []):
            computers.post_file(base, f["path"], name=f["name"], kind=f["type"], clip=False)
            with queue(write=True) as entries:
                for e in entries:
                    if e["id"] == entry["id"]:
                        e["files"] = [x for x in e["files"] if x["path"] != f["path"]]
            entry["files"].remove(f)
        return "sent"
    except urllib.error.HTTPError as e:
        if e.code >= 500 and e.code != 507:   # tailscale serve's 502 while the computer's Ferry isn't up yet
            print(f"waiting send to {base} not taken yet: {e.code}", file=sys.stderr)
            return "missed"
        notices.notify(f"Couldn't send to {entry['name']}", f"{what(entry)}: {e.read()[:200].decode(errors='replace')}")
        return "refused"
    except (OSError, ValueError) as e:
        print(f"waiting send to {base} not taken yet: {e!r}", file=sys.stderr)
        return "missed"


def flush(online, missed, now=None):
    """Delivers what waits for the computers in online (their short tailnet names); missed: {device: when} the ones
    that didn't take it last time, asked again only after AFTER_MISS. Returns the sends delivered (refused ones
    leave the queue too, but aren't among them)."""
    now = now or time.time()
    gone = forget.forgotten_ids()
    with queue(write=True) as entries:
        for e in [e for e in entries if e["device"] in gone]:   # nothing is sent to a forgotten computer
            entries.remove(e)
            drop_files(e)
        due = [dict(e) for e in entries if e["device"] in online and now - missed.get(e["device"], 0) >= AFTER_MISS]
    done, answered = [], []
    for e in due:
        if e["device"] in missed and now - missed[e["device"]] < AFTER_MISS:   # it missed one already this round
            continue
        base = computers.machine_url(e["device"])
        result = deliver(e, base) if base else "missed"
        if result == "missed":
            missed[e["device"]] = now
            continue
        answered.append(e)
        missed.pop(e["device"], None)
        if result == "sent":
            done.append(e)
    if answered:
        ids = {e["id"] for e in answered}
        with queue(write=True) as entries:
            for e in [e for e in entries if e["id"] in ids]:
                entries.remove(e)
                drop_files(e)
        for e in done:
            notices.notify(f"Delivered to {e['name']}", f"{what(e)} · sent {terminal.ago(e['time'])}")
        desktop.changed()
    return done


def online_devices(st=None):
    """The short tailnet names of the owner's machines Tailscale has online now."""
    st = st if st is not None else tailnet.tailscale_status()
    uid = (st.get("Self") or {}).get("UserID")
    return {(p.get("DNSName") or "").split(".")[0] for p in (st.get("Peer") or {}).values()
            if p.get("UserID") == uid and p.get("Online") and p.get("DNSName")}


def run():
    """The server's thread: while anything waits, every EVERY seconds, the ones whose computer is back go."""
    missed = {}
    while True:
        try:
            if listed():
                flush(online_devices(), missed)
        except Exception as e:   # a thread that dies would leave every waiting send waiting for good
            print(f"delivering waiting sends failed: {e!r}", flush=True)
        time.sleep(EVERY)
