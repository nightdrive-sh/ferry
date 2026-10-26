#!/usr/bin/env python3
"""Fake Ferry computers for the simulator, which can't run Tailscale (docs/protocol.md).

    tools/mock-ferry.py [--idle MacBook=0,Nightdrive=1200] [--down Nightdrive] [--slow SECONDS] [--late SECONDS]
    uv run --with cryptography python3 tools/mock-ferry.py …   (with notifications)

MacBook answers at http://127.0.0.1:47271/ferry/ and Nightdrive at http://127.0.0.1:47272/ferry/. Each starts with a
one-time code, a link and a PNG for the phone, and logs every send to stdout (with its clip flag), so a test can see
what arrived. --down leaves a computer's port closed ("can't reach"); --slow delays every answer. There is no Tailscale
here, so no owner or Host check: X-Ferry is checked as a real computer does.

A third computer, Studio at http://127.0.0.1:47273/ferry/, is one just set up: as tailscaled holds the first TLS
handshakes until it has the HTTPS certificate (about 37 s), Studio holds every request until --late seconds (default 40)
after its first one. DELETE /mock/cert on its port makes it new again. It knows of no other computer, nor they of it.

Notifications work as on a real computer, with bin/ferry's own payload(), encrypt() and vapid_auth() (FERRY_BIN, default
this repo's linux/bin/ferry), when python3-cryptography is there. The app subscribes as usual (an http:// endpoint is
accepted here, for the local relay), and a test leaves something for the phone with
POST /mock/leave {"text": …} or {"file": "name.png"} on a computer's port. GET /mock/subs lists its subscriptions,
DELETE /mock/subs forgets them.
"""
import argparse
import importlib.machinery
import json
import os
import secrets
import struct
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MACHINES = {"MacBook": 47271, "Nightdrive": 47272}
LATE = ("Studio", 47273)
MOUNT = "/ferry/"
FERRY_BIN = os.path.expanduser(os.environ.get("FERRY_BIN") or
                               os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "linux", "bin", "ferry"))


def load_ferry():
    """bin/ferry as a module, for its push code; None without python3-cryptography (then no notifications)."""
    try:
        import cryptography  # noqa: F401
        return importlib.machinery.SourceFileLoader("ferry", FERRY_BIN).load_module()
    except (ImportError, OSError) as e:
        print(f"no notifications: {e}", flush=True)
        return None


FERRY = load_ferry()


def png(w=64, h=64):
    """A small violet-to-pink gradient, so the list has a thumbnail to show."""
    rows = b"".join(b"\x00" + b"".join(bytes((90 + x * 2, 30 + y, 200 - x)) for x in range(w)) for y in range(h))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def item(**kw):
    return dict(kw, id=secrets.token_hex(6), time=time.time())


class Computer:
    def __init__(self, name, port, idle, late=None):
        self.name, self.port, self.idle = name, port, idle
        self.late = late          # seconds from the first request before it answers, None to answer at once
        self.ready_at = None
        self.files = {}
        now = time.time()
        pic = item(to="phone", kind="file", name="night-waves.png", type="image/png")
        self.files[pic["id"]] = png()
        pic["size"] = len(self.files[pic["id"]])
        self.items = [dict(item(to="phone", kind="text", text="801566"), time=now - 60),
                      dict(item(to="phone", kind="text", text="https://nightdrive.sh/docs"), time=now - 720),
                      dict(pic, time=now - 5)]
        self.lock = threading.Lock()
        self.subs = []
        self.vapid = None
        if FERRY:
            from cryptography.hazmat.primitives.asymmetric import ec
            self.vapid = ec.generate_private_key(ec.SECP256R1())

    def url(self):
        return f"http://127.0.0.1:{self.port}{MOUNT}"

    def hold(self):
        """Until the certificate would be there, as tailscaled holds a new name's first handshakes."""
        if self.late is None:
            return
        with self.lock:
            if self.ready_at is None:
                self.ready_at = time.time() + self.late
                print(f"{self.name}: getting its certificate, {self.late:g} s", flush=True)
            wait = self.ready_at - time.time()
        if wait > 0:
            time.sleep(wait)

    def push_key(self):
        return FERRY.b64u(FERRY.point(self.vapid)) if self.vapid else None

    def push(self, it):
        """As bin/ferry's push_all() for the computer's own item, in the background."""
        if not self.vapid:
            return
        body = it.get("text", "")[:180] if it["kind"] == "text" else it["name"]
        content = FERRY.payload(self.name, body, item=it)
        with self.lock:
            subs = FERRY.targets(list(self.subs), relayed=False)
        for sub in subs:
            threading.Thread(target=self.push_one, args=(sub, content), daemon=True).start()

    def push_one(self, sub, content):
        data = FERRY.encrypt(content, sub["keys"]["p256dh"], sub["keys"]["auth"])
        req = urllib.request.Request(sub["endpoint"], data, method="POST", headers={
            "Authorization": FERRY.vapid_auth(self.vapid, sub["endpoint"]), "TTL": "604800",
            "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream", "Urgency": "high"})
        try:
            status = urllib.request.urlopen(req, timeout=10).status
        except urllib.error.HTTPError as e:
            status = e.code
            if e.code in (404, 410):
                with self.lock:
                    self.subs = [s for s in self.subs if s["endpoint"] != sub["endpoint"]]
        except OSError as e:
            status = repr(e)
        print(f"{self.name}: push → {status}", flush=True)


def handler(c, everyone, slow):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *a):
            pass

        def handle(self):
            try:
                super().handle()
            except (BrokenPipeError, ConnectionResetError):
                pass   # the app stopped waiting for a held answer (its 8 s) and asked again

        def log(self, what):
            print(f"{c.name}: {what}", flush=True)

        def send(self, code, body=b"", kind="application/json"):
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode()
            elif isinstance(body, str):
                body, kind = body.encode(), "text/plain; charset=utf-8"
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def route(self):
            c.hold()
            time.sleep(slow)
            u = urllib.parse.urlsplit(self.path)
            if not u.path.startswith(MOUNT):
                self.send(404, "Not found")
                return None, None
            path = u.path[len(MOUNT):]
            if not path.startswith("api/file/") and self.headers.get("X-Ferry") != "1":
                self.send(403, "Not from the Ferry page")
                return None, None
            return path, dict(urllib.parse.parse_qsl(u.query))

        def body(self):
            n = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(n)

        def mock(self):
            """The test's side door, outside /ferry/: True when it answered."""
            if self.path == "/mock/subs" and self.command == "GET":
                with c.lock:
                    self.send(200, {"subs": [s["endpoint"] for s in c.subs]})
            elif self.path == "/mock/subs" and self.command == "DELETE":   # a test's fresh start: nothing subscribed
                with c.lock:
                    c.subs = []
                self.send(200, {"ok": True})
            elif self.path == "/mock/cert" and self.command == "DELETE":   # a test's fresh start: no certificate yet
                with c.lock:
                    c.ready_at = None
                self.send(200, {"ok": True})
            elif self.path == "/mock/leave" and self.command == "POST":
                b = json.loads(self.body() or b"{}")
                if b.get("file"):
                    it = item(to="phone", kind="file", name=b["file"], type="image/png")
                    c.files[it["id"]] = png()
                    it["size"] = len(c.files[it["id"]])
                else:
                    it = item(to="phone", kind="text", text=str(b.get("text") or "hello"))
                with c.lock:
                    c.items.append(it)
                self.log(f"left {it.get('text', it.get('name'))!r}")
                c.push(it)
                self.send(200, {"ok": True, "id": it["id"]})
            else:
                return False
            return True

        def do_GET(self):
            if self.mock():
                return
            path, q = self.route()
            if path is None:
                return
            if path == "api/ping":
                self.send(200, {"computer": c.name})
            elif path == "api/items":
                with c.lock:
                    # The code stays a minute old: the app drops one after 15 minutes, and a run of the UI tests may
                    # take longer (docs/protocol.md › Codes and passwords)
                    items = [dict(i, time=max(i["time"], time.time() - 60)) if i.get("text") == "801566" else i
                             for i in c.items]
                    self.send(200, {"computer": c.name, "items": items, "keep": 7, "idle": c.idle, "push": c.push_key()})
            elif path == "api/machines":
                self.send(200, {"machines": [{"url": o.url(), "name": o.name, **({"self": True} if o is c else {})}
                                             for o in everyone], "push": c.push_key()})
            elif path.startswith("api/file/"):
                data = c.files.get(path.rsplit("/", 1)[1])
                if data is None:
                    return self.send(404, "Not in the box any more")
                self.send(200, data, "image/png")
            else:
                self.send(404, "Not found")

        def do_DELETE(self):
            if not self.mock():
                self.send(404, "Not found")

        def do_POST(self):
            if self.mock():
                return
            path, q = self.route()
            if path is None:
                return
            if path == "api/subscribe":
                b = json.loads(self.body() or b"{}")
                keys = b.get("keys") or {}
                if not (str(b.get("endpoint", "")).startswith(("https://", "http://")) and keys.get("p256dh") and keys.get("auth")):
                    return self.send(400, "Not a push subscription")
                entry = {"endpoint": b["endpoint"], "keys": {"p256dh": keys["p256dh"], "auth": keys["auth"]},
                         "device": "iphone", "time": time.time(), **({"direct": True} if b.get("direct") is True else {})}
                with c.lock:
                    c.subs = [s for s in c.subs if s["endpoint"] != entry["endpoint"]] + [entry]
                self.log(f"subscribe {entry['endpoint']} direct={entry.get('direct', False)}")
                self.send(200, {"ok": True})
            elif path == "api/unsubscribe":
                end = str(json.loads(self.body() or b"{}").get("endpoint", ""))
                with c.lock:
                    c.subs = [s for s in c.subs if s["endpoint"] != end]
                self.log(f"unsubscribe {end}")
                self.send(200, {"ok": True})
            elif path == "api/text":
                b = json.loads(self.body() or b"{}")
                text = str(b.get("text") or "")
                if not text.strip():
                    return self.send(400, "Empty text")
                with c.lock:
                    c.items.append(item(to="computer", kind="text", text=text, **{"from": "iphone"}, seen=False))
                self.log(f"text {text!r} clip={bool(b.get('clip'))}")
                self.send(200, {"ok": True})
            elif path == "api/upload":
                data = self.body()
                name, kind = q.get("name", "file"), q.get("type", "application/octet-stream")
                with c.lock:
                    c.items.append(item(to="computer", kind="file", name=name, size=len(data), type=kind,
                                        **{"from": "iphone"}, seen=False))
                self.log(f"upload {name!r} {kind} {len(data)} B clip={q.get('clip') == '1'}")
                self.send(200, {"ok": True, "name": name})
            elif path == "api/remove":
                with c.lock:
                    c.items = [i for i in c.items if i["id"] != q.get("id")]
                self.log(f"remove {q.get('id')}")
                self.send(200, {"ok": True})
            elif path == "api/clear":
                with c.lock:
                    c.items = [i for i in c.items if i["to"] != q.get("to")]
                self.log(f"clear to={q.get('to')}")
                self.send(200, {"ok": True})
            else:
                self.send(404, "Not found")
    return H


def main():
    p = argparse.ArgumentParser(description="Fake Ferry computers on 127.0.0.1")
    p.add_argument("--idle", default="MacBook=0,Nightdrive=1200", help="NAME=SECONDS,… (null: unknown)")
    p.add_argument("--down", default="", help="computers to leave unreachable, comma-separated")
    p.add_argument("--slow", type=float, default=0, help="seconds before every answer")
    p.add_argument("--late", type=float, default=40, help="seconds Studio holds requests from its first one")
    a = p.parse_args()
    idle = {}
    for pair in filter(None, a.idle.split(",")):
        k, v = pair.split("=")
        idle[k] = None if v == "null" else int(v)
    down = set(filter(None, a.down.split(",")))
    everyone = [Computer(n, port, idle.get(n)) for n, port in MACHINES.items()]
    servers = []
    studio = Computer(*LATE, 0, late=a.late)
    for c, others in [(c, everyone) for c in everyone] + [(studio, [studio])]:
        if c.name in down:
            print(f"{c.name}: down", flush=True)
            continue
        s = ThreadingHTTPServer(("127.0.0.1", c.port), handler(c, others, a.slow))
        threading.Thread(target=s.serve_forever, daemon=True).start()
        servers.append(s)
        print(f"{c.name}: {c.url()} (idle {c.idle})", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
