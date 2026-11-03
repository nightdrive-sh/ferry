"""The HTTP API (docs/protocol.md) and the page's files: one handler class, made for the running server.

A request is answered only for the Tailscale user who owns this machine (Tailscale-User-Login, which tailscale serve sets
and a client can't), and must name this machine (Host), so a web page that rebinds its own name to 127.0.0.1 gets
nothing. A custom header on every API call keeps other web pages on the phone from posting here."""
import contextlib
import json
import mimetypes
import os
import re
import shutil
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler

from . import bodies, config, desktop, forget, idle, push, server, store, tailnet


def handler(app):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "Ferry"

        def log_message(self, fmt, *a):
            """The journal's line for a request, without its query: an upload's carries the file's name
            (docs/protocol.md › api/upload), which isn't the journal's to keep."""
            line = re.sub(r"\?[^\s'\"]*", "", fmt % a)
            print(f"{self.headers.get('X-Forwarded-For', '-') if self.headers else '-'} {line}", flush=True)

        def unread(self):
            """A request body not read yet: answering without it, the connection has to close, or tailscale serve,
            which keeps its connection to us open, would send the next request after the leftover body."""
            if getattr(self, "consumed", False):
                return False
            return bodies.unread(self.headers)

        def send(self, code, body=b"", kind="application/json", headers=None):
            if self.unread():
                self.close_connection = True
                headers = dict(headers or {}, Connection="close")
            if isinstance(body, (dict, list)):
                body = json.dumps(body, ensure_ascii=False).encode()
            elif isinstance(body, str):
                body, kind = body.encode(), "text/plain; charset=utf-8"
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            headers = dict({"Cache-Control": "no-cache"}, **(headers or {}))
            origin = self.cors()
            if origin:
                headers.update({"Access-Control-Allow-Origin": origin, "Vary": "Origin"})
            self.send_header("X-Content-Type-Options", "nosniff")
            for k, v in headers.items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def who(self):
            """The asking device's name on the tailnet (tailscale serve gives its address)."""
            ip = (self.headers.get("X-Forwarded-For") or "").split(",")[0].strip()
            return app.tailnet.device(ip) or "your phone"

        def heard(self):
            """The asking device has used Ferry here (docs/protocol.md › Forgetting a device). Only a request through
            tailscale serve names one: a local one with no address would look Tailscale up again every time."""
            if self.headers.get("X-Forwarded-For"):
                app.heard(self.who())

        def cors(self):
            """The asking page's origin if it is another of the owner's machines (its Ferry page switched to this one)."""
            origin = self.headers.get("Origin") or ""
            return origin if origin and app.tailnet.same_owner(origin) else ""

        def gate(self, api):
            """Only the machine's owner, and for the API only a Ferry page: this one, or one on another of the owner's
            machines (see the module's notes)."""
            if not app.tailnet.allowed(self.headers.get("Tailscale-User-Login", "")) or \
                    not app.tailnet.for_me(self.headers.get("Host", "")):
                self.send(403, "Ferry answers only its computer's owner, through Tailscale.")
                return False
            site = self.headers.get("Sec-Fetch-Site", "same-origin")
            if api and (self.headers.get("X-Ferry") != "1" or (site not in ("same-origin", "none") and not self.cors())):
                self.send(403, "Not from the Ferry page")
                return False
            return True

        def do_OPTIONS(self):
            """A CORS preflight from the Ferry page on another of the owner's machines."""
            self.route()
            origin = self.cors()
            if not origin or not app.tailnet.allowed(self.headers.get("Tailscale-User-Login", "")) or \
                    not app.tailnet.for_me(self.headers.get("Host", "")):
                return self.send(403, "Not allowed")
            self.send(204, b"", "text/plain", {"Access-Control-Allow-Methods": "GET, POST",
                                              "Access-Control-Allow-Headers": "X-Ferry, Content-Type",
                                              "Access-Control-Max-Age": "600"})

        def route(self):
            self.consumed = False   # per request: the handler serves every request of a kept-alive connection
            u = urllib.parse.urlsplit(self.path)
            path = u.path
            if path == config.MOUNT or path.startswith(config.MOUNT + "/"):   # in case tailscale serve leaves the mount point on
                path = path[len(config.MOUNT):] or "/"
            return path, dict(urllib.parse.parse_qsl(u.query))

        def read_body(self, limit):
            n = bodies.length(self.headers)
            if n > limit:
                raise ValueError("too big")
            self.consumed = True
            return self.rfile.read(n)

        def body(self, limit):
            """The request body in pieces (bodies.pieces): a Content-Length, or chunked."""
            self.consumed = True   # partly read is unread too: an error ends the connection (upload())
            yield from bodies.pieces(self.rfile, self.headers, limit, config.CHUNK)

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            path, q = self.route()
            if not self.gate(api=path.startswith("/api/") and not path.startswith("/api/file/")):
                return
            if path.startswith("/api/"):
                self.heard()
            if path == "/":
                with open(os.path.join(config.WEB, "index.html"), encoding="utf-8") as f:
                    page = f.read().replace("%BASE%", config.MOUNT + "/")
                self.send(200, page.encode(), "text/html; charset=utf-8")
            elif path in server.STATIC:
                try:
                    with open(os.path.join(config.WEB, path.lstrip("/")), "rb") as f:
                        self.send(200, f.read(), server.STATIC[path])
                except OSError:
                    self.send(404, "Not found")
            elif path == "/api/items":
                who = self.who()
                with store.box() as items:
                    out = [store.public(i) for i in items if store.for_device(i, who)]
                self.send(200, {"computer": config.alias(), "items": out, "keep": config.KEEP_DAYS, "idle": idle.idle_for(),
                                "push": push.b64u(push.point(app.key)) if app.key else None})
            elif path.startswith("/font/") and path[6:] in config.FONT_FILES:
                try:
                    with open(os.path.join(config.FONTS, path[6:]), "rb") as f:
                        self.send(200, f.read(), "font/ttf", {"Cache-Control": "max-age=604800"})
                except OSError:
                    self.send(404, "Not found")   # the page falls back to the system font
            elif path == "/api/ping":
                self.send(200, {"computer": config.alias(), "idle": idle.idle_for(), "forgotten": forget.forgotten()})
            elif path == "/api/machines":
                self.send(200, {"machines": app.machines(), "push": push.b64u(push.point(app.key)) if app.key else None,
                                "forgotten": forget.forgotten()})
            elif path.startswith("/api/file/"):
                it = store.find(path.rsplit("/", 1)[1])
                if not it or it.get("kind") != "file":
                    return self.send(404, "Not in the box any more")
                self.file(it, q.get("download") == "1")
            else:
                self.send(404, "Not found")

        def file(self, it, attachment):
            try:
                f = open(it["path"], "rb")
            except OSError:
                return self.send(404, "The file is gone")
            with f:
                size = os.fstat(f.fileno()).st_size
                quoted = urllib.parse.quote(it["name"])
                kind = it.get("type") or ""
                inline = bool(config.INLINE.match(kind)) and not attachment
                self.send_response(200)
                self.send_header("Content-Type", kind if config.INLINE.match(kind) else "application/octet-stream")
                self.send_header("Content-Length", str(size))
                self.send_header("Content-Disposition", f"{'inline' if inline else 'attachment'}; filename*=UTF-8''{quoted}")
                self.send_header("X-Content-Type-Options", "nosniff")
                if kind != "application/pdf":   # Safari's PDF viewer doesn't open in a sandbox
                    self.send_header("Content-Security-Policy", "sandbox; default-src 'none'; img-src 'self'; media-src 'self'")
                origin = self.cors()
                if origin:
                    self.send_header("Access-Control-Allow-Origin", origin)
                    self.send_header("Vary", "Origin")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                if self.command == "HEAD":
                    return
                shutil.copyfileobj(f, self.wfile, config.CHUNK)

        def do_POST(self):
            path, q = self.route()
            if not self.gate(api=True):
                return
            self.heard()
            try:
                if path == "/api/text":
                    body = json.loads(self.read_body(config.MAX_TEXT * 2) or b"{}")
                    text = str(body.get("text") or "")
                    if not text.strip():
                        return self.send(400, "Empty text")
                    app.received_text(text[:config.MAX_TEXT], self.who(), clip=bool(body.get("clip")))
                    self.send(200, {"ok": True})
                elif path == "/api/upload":
                    self.upload(q)
                elif path == "/api/clear":
                    # Everything in one direction out of the box (the page's Clear)
                    to = q.get("to", "")
                    with store.box(write=True) as items:
                        for it in [i for i in items if i.get("to") == to]:
                            store.drop_file(it)
                            items.remove(it)
                    desktop.changed()
                    self.send(200, {"ok": True})
                elif path == "/api/remove":
                    store.remove(q.get("id", ""))
                    desktop.changed()
                    self.send(200, {"ok": True})
                elif path == "/api/subscribe":
                    entry = push.subscription(json.loads(self.read_body(8192) or b"{}"), self.who())
                    if not entry:
                        return self.send(400, "Not a push subscription")
                    push.subscribe(entry)
                    self.send(200, {"ok": True})
                elif path in ("/api/forget", "/api/unforget"):
                    # Forgotten on every computer: the others merge this one's list from its api/ping
                    body = json.loads(self.read_body(8192) or b"{}")
                    if path == "/api/unforget" and isinstance(body, dict) and body.get("self") is True:
                        forget.bring_back(self.who())   # a phone just added again with Add Device
                        return self.send(200, {"ok": True})
                    device = body.get("device") if isinstance(body, dict) else None
                    if not forget.device_name(device):
                        return self.send(400, "Not a device's tailnet name")
                    forget.decide(device, path == "/api/forget")
                    self.send(200, {"ok": True})
                elif path == "/api/unsubscribe":
                    end = str(json.loads(self.read_body(8192) or b"{}").get("endpoint", ""))
                    push.subscriptions(lambda s: s.__setitem__(slice(None), [x for x in s if x["endpoint"] != end]))
                    self.send(200, {"ok": True})
                elif path == "/api/relay":
                    # The page from the computer at via, switched to this one: notifications go through via
                    via = str(json.loads(self.read_body(8192) or b"{}").get("via", ""))
                    if not (app.tailnet.same_owner(via) and via.endswith(config.MOUNT + "/")) or via == tailnet.url():
                        return self.send(400, "Not a Ferry page of yours")
                    push.relays(lambda r: r.append(via) if via not in r else None)
                    self.send(200, {"ok": True})
                elif path == "/api/relay-push":
                    # Another of the owner's computers (Tailscale says who asks) notifies this one's phones about itself
                    msg = json.loads(self.read_body(8192) or b"{}")
                    machine = str(msg.get("machine", ""))
                    if not app.tailnet.same_owner(machine):
                        return self.send(400, "Not a Ferry page of yours")
                    push.push_all(str(msg.get("title", ""))[:200], str(msg.get("body", ""))[:300], machine,
                             device=str(msg.get("device", ""))[:100])
                    self.send(200, {"ok": True})
                elif path == "/api/test-push":
                    if not app.key:
                        return self.send(503, "Notifications need python3-cryptography on the computer")
                    push.push_all(config.alias(), "Notifications work")
                    self.send(200, {"ok": True})
                else:
                    self.send(404, "Not found")
            except ValueError:
                self.send(400, "Bad request")

        def upload(self, q):
            n = bodies.length(self.headers)
            if n > config.MAX_FILE:
                return self.send(413, f"Too big: {config.human(config.MAX_FILE)} at most")
            dest = config.downloads()
            os.makedirs(dest, exist_ok=True)
            if shutil.disk_usage(dest).free - n < config.MIN_FREE:
                return self.send(507, "Not enough space on the computer")
            while True:   # a name no other upload is writing to at the same time
                path = store.unique(os.path.join(dest, store.safe_name(q.get("name", "file"))))
                part, size = path + ".part", 0
                try:
                    out = open(part, "xb")
                    break
                except FileExistsError:
                    continue
            try:
                with out:
                    checked = 0
                    for chunk in self.body(config.MAX_FILE):
                        out.write(chunk)
                        size += len(chunk)
                        # A chunked upload says no size at the start, and uploads run side by side: the free space
                        # is looked at again as the file grows
                        if size - checked >= config.FREE_CHECK:
                            checked = size
                            if shutil.disk_usage(dest).free < config.MIN_FREE:
                                raise bodies.NoSpace("disk full")
            except (OSError, ValueError) as e:
                # Not the path: the file's name stays out of the journal too
                print(f"an upload failed: {e.strerror or e if isinstance(e, OSError) else e}", flush=True)
                with contextlib.suppress(OSError):
                    os.remove(part)
                self.consumed = False
                if isinstance(e, bodies.TooBig):
                    return self.send(413, f"Too big: {config.human(config.MAX_FILE)} at most")
                if isinstance(e, bodies.NoSpace):
                    return self.send(507, "Not enough space on the computer")
                return self.send(400, "Upload failed")
            if os.path.exists(path):   # taken meanwhile
                path = store.unique(path)
            os.replace(part, path)
            kind = q.get("type") or mimetypes.guess_type(path)[0] or "application/octet-stream"
            app.received_file(path, size, kind, self.who(), clip=q.get("clip") == "1")
            self.send(200, {"ok": True, "name": os.path.basename(path)})
    return Handler
