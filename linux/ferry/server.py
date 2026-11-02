"""The server: Ferry's state while it runs, the HTTP server on 127.0.0.1, and its background chores."""
import json
import os
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import ThreadingHTTPServer

from . import api, computers, config, desktop, forget, idle, notices, push, store, tailnet


STATIC = {"/manifest.webmanifest": "application/manifest+json", "/sw.js": "text/javascript",
          "/icon.svg": "image/svg+xml", "/icon-180.png": "image/png", "/icon-192.png": "image/png",
          "/icon-512.png": "image/png"}


class Ferry:
    def __init__(self):
        self.tailnet = tailnet.Tailnet()
        self.key = push.vapid_key(create=True)
        self.recent = (0.0, None)        # (when, its group): files from the phone in a row, in one notification
        self.lock = threading.Lock()
        self.notifying = threading.Lock()   # one files' notification at a time: each needs the id of the one before
        self.found = computers.Found()   # the owner's other machines running Ferry
        self.used = None                 # phones(), read once: a poll from a phone known already writes nothing
        self.back = False                # whether this computer brought itself back since its Ferry started

    def machines(self):
        """This computer and the owner's other machines that answer as Ferry, as Tailscale has them online now, without
        the forgotten ones. What they forgot is merged into this computer's list (docs/protocol.md › Forgetting a
        device)."""
        self.tailnet.load(force=True)
        found = self.found.get(self.tailnet.machines)
        if self.found.asked:
            now, ids = time.time(), {r["id"] for r in found}

            def merge(known):
                known[:] = [k for k in known if k.get("id") not in ids and k.get("id") in self.tailnet.ids] + \
                           [dict({k: v for k, v in r.items() if k != "forgotten"}, seen=now) for r in found]
            computers.known_machines(merge)
            forget.learn_forgotten([e for r in found for e in r["forgotten"]])
        self.come_back()
        gone = forget.forgotten_ids()
        return [{"url": tailnet.url(), "name": config.alias(), "self": True}] + \
            [{"url": r["url"], "name": r["name"]} for r in found if r["id"] not in gone]

    def come_back(self):
        """This computer's Ferry starting brings it back (docs/protocol.md › What forgetting does): after the first
        round of api/ping, which merged what the others forgot, if its list says it is forgotten. Once per start, so a
        forget heard of later holds until the next one; not before Tailscale names this computer (nobody was asked)."""
        own = self.tailnet.me.split(".")[0].lower()
        with self.lock:
            if self.back or not own:
                return
            self.back = True
        forget.bring_back(own)

    def heard(self, device):
        """A device's call that passed the gate: a phone or a tablet is on the device list from its first one."""
        if device not in self.tailnet.phones:
            return
        if self.used is None:
            self.used = forget.phones()
        if device not in self.used:
            self.used = forget.phones(device)

    # What the phone sends is in the box when the phone is answered; the notification comes after, in a thread of its
    # own, so a notification daemon that is slow or missing doesn't make the phone wait or give up.
    def received_text(self, text, who, clip=False):
        # The phone's Clipboard button means "onto this computer's clipboard": no Copy to press. A typed text waits
        # for one, so it doesn't replace what was just copied here. The phone's clipboard often holds a password from
        # its password manager, so what Send Clipboard puts on this one is marked sensitive, as is a code or a password
        # copied with Copy. A notification doesn't show a code or a password (a desktop may keep what one says), and
        # one leaves the box once copied, so one on the clipboard isn't kept (docs/protocol.md › Codes and passwords).
        it = store.new_item(to="computer", kind="text", text=text, seen=False, **{"from": who})
        hidden = store.looks_secret(text)
        on_clipboard = clip and desktop.copy_text(text, sensitive=True)
        if not (on_clipboard and hidden):
            with store.box(write=True) as items:
                items.append(it)
        if on_clipboard:
            later(notices.notify, f"Copied from {who}", config.SECRET_NAMED if hidden else text[:300])
        else:
            later(notices.notify, f"Text from {who}", config.SECRET_HIDDEN if hidden else text[:300],
                  {"copy": ("Copy", lambda: desktop.copy_text(text, sensitive=hidden) and store.copied(it))})
        desktop.changed()

    def received_file(self, path, size, kind, who, clip=False):
        with store.box(write=True) as items:
            items.append(store.new_item(to="computer", kind="file", name=os.path.basename(path), size=size, type=kind,
                                  path=path, seen=False, **{"from": who}))
        desktop.changed()
        # An image from the phone's clipboard goes onto this one's too, ready to paste; the file stays in Downloads
        if clip and kind.startswith("image/") and desktop.copy_file(path, kind, sensitive=True):
            return later(notices.notify, f"Copied {os.path.basename(path)}",
                         f"From {who} · {os.path.basename(os.path.dirname(path))}", {
                             "open": ("Open", lambda: desktop.open_path(path)),
                             "show": ("Show in Files", lambda: desktop.show_in_files(path))}, desktop.previewable(path, kind))
        with self.lock:
            when, group = self.recent
            if group is None or time.monotonic() - when >= config.GROUP_NOTIFY:
                group = {"paths": [], "nid": "", "shown": 0}   # the files, their notification's id, how many it says
            group["paths"].append(path)
            self.recent = (time.monotonic(), group)
        later(self.notify_files, group, kind, who)

    def notify_files(self, group, kind, who):
        """One notification for files from the phone in a row, each in place of the one before. A folder's files come
        faster than a daemon answers with a notification's id, so they're shown one at a time, each with the files
        that have come by then: one taken with the id it replaces unknown would stay, a stack of "Received N files"."""
        with self.notifying:
            with self.lock:
                paths, old = list(group["paths"]), group["nid"]
            if len(paths) <= group["shown"]:   # the files that came while the one before was shown: said already
                return
            nid = self.files_notification(paths, kind, who, old)
            if old and nid and nid != old:   # a daemon that showed a new one rather than replace it
                notices.close_notification(old)
            with self.lock:
                group["nid"], group["shown"] = nid or old, len(paths)

    def files_notification(self, paths, kind, who, replaces):
        title = f"Received {os.path.basename(paths[-1])}" if len(paths) == 1 else f"Received {len(paths)} files"
        first = paths[0]
        return notices.notify(title, f"From {who} · {os.path.basename(os.path.dirname(paths[-1]))}", {
            "open": ("Open", lambda: desktop.open_path(first if len(paths) == 1 else os.path.dirname(first))),
            "show": ("Show in Files", lambda: desktop.show_in_files(first))},
            desktop.previewable(first, kind) if len(paths) == 1 else "", replaces)


def later(fn, *args):
    threading.Thread(target=fn, args=args, daemon=True).start()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        print(f"connection error: {sys.exc_info()[1]!r}", flush=True)   # a phone gone mid-request


def tidy_once():
    """Old items out of the box, also from the disk: a read leaves them in items.json. Written only when one goes."""
    try:
        with open(os.path.join(config.STATE, "items.json")) as f:
            stale = not all(store.alive(i) for i in json.load(f).get("items") or [])
    except (OSError, ValueError, AttributeError):
        return False
    if stale:
        with store.box(write=True):
            pass
    return stale


def tidy():
    """Old items out of the box, now and every minute: a code or a password leaves the disk within a minute of its
    SECRET_KEEP (otherwise only a write would notice it)."""
    while True:
        tidy_once()
        time.sleep(60)


def look_around(app):
    """The owner's other computers running Ferry, found again now and then for `ferry devices` (machines.json)."""
    while True:
        try:
            app.machines()
        except Exception as e:   # a thread that dies would leave the list as it was for good
            print(f"looking for the other computers failed: {e!r}", flush=True)
        time.sleep(config.MACHINES_EVERY + 1)   # past Ferry.machines()'s minute, so it looks again


def ask_own(u):
    req = urllib.request.Request(u, headers={"X-Ferry": "1", "User-Agent": f"Ferry/{config.VERSION}"})
    try:
        urllib.request.urlopen(req, timeout=120).close()
    except urllib.error.HTTPError:
        pass   # an answer all the same: the TLS handshake, which waited for the certificate, is behind it


def warm_certificate(own=None, served=tailnet.serving, get=ask_own):
    """Asks this computer's own https address, so that tailscale serve fetches the tailnet's certificate now: it does
    so on the first request after Ferry is published (36 s for a new machine name), and the phone's first try, right
    after Add Device's QR code is scanned, gives up before that. The address asked, or "" (not published, or no
    answer: try again)."""
    u = (own or tailnet.url)()
    if not u or not served():
        return ""
    try:
        get(u + "api/ping")
    except (OSError, ValueError):
        return ""
    return u


def keep_warm():
    """warm_certificate() for each address this computer gets: at start (one quick request when the certificate is
    there already), once it is first published, and when its name changes."""
    warmed = ""
    while True:
        try:
            if tailnet.url() != warmed:
                warmed = warm_certificate()
        except Exception as e:   # a thread that dies would leave a new name's certificate to the phone's first try
            print(f"fetching the certificate failed: {e!r}", flush=True)
        time.sleep(300 if warmed else 20)


def run():
    app = Ferry()
    server = Server(("127.0.0.1", config.PORT), api.handler(app))
    threading.Thread(target=tidy, daemon=True).start()
    threading.Thread(target=look_around, args=(app,), daemon=True).start()
    threading.Thread(target=idle.WAYLAND_IDLE.run, daemon=True).start()
    threading.Thread(target=keep_warm, daemon=True).start()
    print(f"Ferry on 127.0.0.1:{config.PORT}{'' if app.key else ' (no Web Push: python3-cryptography is missing)'}",
          flush=True)
    server.serve_forever()
