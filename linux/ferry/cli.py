"""Ferry: a mailbox between your devices, over Tailscale. This is a Linux computer's side of it.

    ferry send [FILE…|TEXT]       files, or a text; with nothing: what is piped in, or the clipboard (--to DEVICE: see below)
    ferry list                    what's in the box, numbered: what was received (1 is the newest), then what was sent
    ferry get [N]                 an item (1, the newest received, by default): a text printed, a file copied here
    ferry open | copy N           a file opened, a text to the clipboard
    ferry rm N…                   items out of the box (a received file stays in Downloads)
    ferry clear [received|sent]   everything, or one direction, out of the box
    ferry url | qr                the phone's address (https://<this machine>.<tailnet>.ts.net/ferry/), or Add Device's QR code
    ferry status                  on, or off and why (the server not running)
    ferry enable | disable        the server on/off (ferry.service) and its address on the tailnet
    ferry run                     the server itself (the service)
    ferry app [FILE…]             Ferry's window (files: sends them, after picking the device); --background: the tray
    ferry update [--check]        installs Ferry's newest release (a beta install: the newest pre-release too)
    ferry tray [on|off]           whether the tray icon starts at login (`ferry enable` puts it there)
    ferry version                 this Ferry's version
    ferry list --json             the box and Ferry's state, for a desktop's menu
    ferry qr --svg                the QR code as an SVG file (prints its path), for the menu
    ferry add FILE…               sends files (or a folder's files) without a word (the menu's drop)
    ferry pick                    the same, files chosen in a file dialog (several at once); then the menu says "Sent"
    ferry text TEXT               sends a text
    ferry send-clipboard          sends the clipboard's text (a notification if it has none); to a computer, onto its clipboard
    ferry devices                 the owner's other devices (computers running Ferry, phones that used it), the picked one marked
    ferry target [DEVICE]         the device sends go to (the last one picked), or picks one
    ferry forget DEVICE           a device off every computer's and phone's lists, until it is added again
    ferry seen                    marks what came from the phone as seen (the bar's count goes)
    N is a number from `ferry list`, or an item's id (the menu uses those: numbers change as the box does).
    send, add, pick, text and send-clipboard take --to DEVICE (its name in `ferry devices`) for one send, else the target.

How it works: ferry/__init__.py."""
import json
import os
import shutil
import subprocess
import sys

from . import computers, config, desktop, forget, install, notices, push, server, store, tailnet, terminal, updates


def listing():
    st = tailnet.tailscale_status()
    with store.box() as items:
        out = [dict(store.public(i), path=i.get("path", "")) for i in items]
    subs = push.subscriptions() if os.path.exists(os.path.join(config.STATE, "push.json")) else []
    devs = computers.devices(st)
    t = computers.target(devs)
    on = tailnet.systemctl("is-active", "-q", config.SERVICE).returncode == 0
    have = bool(shutil.which("tailscale"))
    served = have and bool(st) and tailnet.serving()
    return {"on": on, "tailscale": st.get("BackendState") == "Running", "url": tailnet.url(st), "serving": served,
            "setup": tailnet.setup_step(st, have, on, served), "push": len(subs), "items": out, "devices": devs,
            "target": t["id"] if t else "", "sent": computers.last_sent(), "version": config.VERSION, "update": updates.available_update()}


def add_link(u):
    """What Add Device's QR code holds for the address `u` (docs/protocol.md › Clients › Adding a phone)."""
    return f"{config.ADD_PAGE}#{u}" if u else ""


def qr(svg):
    u = tailnet.url()
    if not u or not shutil.which("qrencode"):
        print("No address: Tailscale is off" if not u else "qrencode is needed: install it with your package manager",
              file=sys.stderr)
        return 1
    if not svg:
        return subprocess.run(["qrencode", "-t", "ANSIUTF8", "-m", "2", add_link(u)]).returncode
    os.makedirs(os.path.dirname(config.QR), exist_ok=True)
    subprocess.run(["qrencode", "-t", "SVG", "-m", "2", "--foreground=000000", "--background=FFFFFF", "-o", config.QR,
                    add_link(u)], check=True)
    print(config.QR)
    return 0


def main():
    a = sys.argv[1:]
    cmd = a[0] if a else "status"
    try:
        if cmd not in ("version", "--version", "help", "-h", "--help") and install.migrate():
            print(f"Ferry's state moved from {config.OLD_STATE} to {config.STATE}", file=sys.stderr)
    except OSError as e:   # nothing may start over with a new state (and VAPID key) beside a half-moved one
        print(f"Couldn't move Ferry's state from {config.OLD_STATE} to {config.STATE}: {e}", file=sys.stderr)
        return 1
    if cmd == "status":
        print(tailnet.status())
    elif cmd == "enable":
        return install.enable()
    elif cmd == "disable":
        tailnet.systemctl("disable", "--now", config.SERVICE)
        err = tailnet.serve(False)
        if err:
            print(tailnet.serve_message(err), file=sys.stderr)
    elif cmd == "run":
        server.run()
    elif cmd == "app":
        sys.path.insert(0, os.path.join(config.ROOT, "app"))
        import ferry_app
        return ferry_app.main(a[1:])
    elif cmd == "update" and a[1:] in ([], ["--check"]):
        return updates.update(check_only=a[1:] == ["--check"])
    elif cmd == "tray" and a[1:] in ([], ["on"], ["off"]):
        if len(a) == 1:
            print("on" if install.tray_wanted() else "off")
        else:
            install.set_tray(a[1] == "on")
    elif cmd in ("version", "--version"):
        print(config.VERSION)
    elif cmd == "url":
        u = tailnet.url()
        print(u)
        return 0 if u else 1
    elif cmd == "list" and a[1:] == ["--json"]:
        print(json.dumps(listing(), ensure_ascii=False))
    elif cmd == "list":
        terminal.print_list()
    elif cmd in ("send", "add", "pick", "text", "send-clipboard"):
        dev, rest, why = terminal.pick_device(a[1:])
        if not dev:
            # A device named with --to that isn't there is that, not "no device yet"
            if cmd == "send":
                print(why, file=sys.stderr)
                return 1
            return terminal.failed(why)
        if cmd == "send":
            return terminal.send(rest, dev)
        if cmd == "add":
            if not rest:
                return 1
            err = computers.deliver(dev, files=rest)
            return terminal.failed(err) if err else 0
        if cmd == "pick":
            paths = terminal.pick_files(f"Send to {dev['name']} with Ferry")
            if paths is None:
                return terminal.failed("No file dialog here (zenity or kdialog): ferry send FILE sends files")
            if not paths:
                return 1
            err = computers.deliver(dev, files=paths)
            # A menu that closed for the dialog may open again to show what was just sent
            desktop.hook("picked")
            return terminal.failed(err) if err else 0
        if cmd == "text":
            if not " ".join(rest).strip():
                return 1
            err = computers.deliver(dev, text=" ".join(rest))
            return terminal.failed(err) if err else 0
        text = desktop.paste_text()
        if not text.strip():
            notices.notify("The clipboard has no text", "Copy a text or a link first")
            computers.mark_sent("", "", "The clipboard has no text")
            return 1
        err = computers.deliver(dev, text=text, clip=True)
        return terminal.failed(err) if err else 0
    elif cmd == "devices":
        devs = computers.devices()
        t = computers.target(devs)
        for d in devs:
            state = "in use" if d["inUse"] else "online" if d["online"] else \
                "asleep" if d["kind"] == "computer" else "offline"
            print(f"{'*' if t and d['id'] == t['id'] else ' '} {d['id']:<24} {d['kind']:<9} {state}" +
                  (f"  ({d['name']})" if d["name"] != d["id"] else ""))
        if not devs:
            print("No other device yet: add your phone with Add Device in Ferry's menu (or ferry qr)", file=sys.stderr)
    elif cmd == "forget" and len(a) == 2:
        dev = next((d for d in computers.devices() if a[1] in (d["id"], d["name"])), None)
        if not dev:
            print(f"No device {a[1]}: see ferry devices", file=sys.stderr)
            return 1
        forget.decide(dev["id"], True)
    elif cmd == "target":
        devs = computers.devices()
        if len(a) == 1:
            t = computers.target(devs)
            print(t["id"] if t else "")
            return 0 if t else 1
        dev = next((d for d in devs if a[1] in (d["id"], d["name"])), None)
        if not dev:
            print(f"No device {a[1]}: see ferry devices", file=sys.stderr)
            return 1
        computers.set_target(dev["id"])
    elif cmd == "get" and len(a) <= 2:
        it = store.item(a[1] if len(a) > 1 else "1")
        if not it or (len(a) == 1 and it.get("to") != "computer"):
            print("Nothing from the phone" if len(a) == 1 else f"No item {a[1]}: see ferry list", file=sys.stderr)
            return 1
        return terminal.get(it)
    elif cmd in ("copy", "open", "rm", "remove") and len(a) > 1:
        items = store.numbered()
        found = [store.item(r, items) for r in a[1:]]   # all first: numbers would change as items go
        if None in found:
            print(f"No item {a[1 + found.index(None)]}: see ferry list", file=sys.stderr)
            return 1
        for it in found:
            if cmd in ("rm", "remove"):
                store.remove(it["id"])
            elif cmd == "copy" and it.get("kind") == "text":
                if not desktop.copy_text(it["text"], sensitive=store.secret(it)):
                    print("No clipboard to copy to: this needs a desktop", file=sys.stderr)
                    return 1
                store.copied(it)
            elif cmd == "open" and it.get("kind") == "file":
                desktop.open_path(it["path"])
            else:
                print(f"{'Copy' if cmd == 'copy' else 'Open'} is for a {'text' if cmd == 'copy' else 'file'}: "
                      f"ferry get {a[1 + found.index(it)]}", file=sys.stderr)
                return 1
        if cmd in ("rm", "remove"):
            desktop.changed()
    elif cmd == "clear" and len(a) <= 2:
        to = {"": None, "received": "computer", "sent": "phone"}.get(a[1] if len(a) > 1 else "", "?")
        if to == "?":
            print("ferry clear [received|sent]", file=sys.stderr)
            return 1
        with store.box(write=True) as items:
            for it in [i for i in items if to is None or i.get("to") == to]:
                store.drop_file(it)
                items.remove(it)
        desktop.changed()
    elif cmd == "seen":
        store.mark_seen()
    elif cmd == "qr":
        return qr(a[1:] == ["--svg"])
    elif cmd in ("help", "-h", "--help"):
        print(__doc__.split("\n\n")[1])
    else:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 1
    return 0
