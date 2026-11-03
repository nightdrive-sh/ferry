"""The commands' output in a terminal: the box numbered, an item printed or saved, and sends from the shell."""
import os
import shutil
import subprocess
import sys
import time

from . import computers, config, controls, desktop, notices, store, tailnet


def ago(t):
    s = time.time() - t
    return "just now" if s < 60 else f"{s // 60:.0f} min ago" if s < 3600 else \
        f"{s // 3600:.0f} h ago" if s < 86400 else f"{s // 86400:.0f} d ago"


def fit(text, room):
    return text if len(text) <= room else text[:room - 1] + "…"


def oneline(text, room):
    """A text on one line, its controls shown as escapes (controls.py: a text from another device is no terminal's)."""
    return fit(controls.shown(" ".join(text.split())), room)


def print_list():
    items = store.numbered()
    if not items:
        print("The box is empty")
        return
    width, pad, heading = shutil.get_terminal_size().columns, len(str(len(items))), ""
    for n, it in enumerate(items, 1):
        h = "Received" if it.get("to") == "computer" else "Sent, waiting to be picked up"
        if h != heading:
            print(("\n" if heading else "") + h)
            heading = h
        head = f"  {n:>{pad}}  {ago(it.get('time', 0)):<10}  "
        who = f"  · {controls.shown(it['from'])}" if it.get("from") else \
            f"  · for {controls.shown(it['for'])}" if it.get("for") else ""
        room = max(width - len(head) - len(who), 20)
        name = controls.shown(it.get("name", ""))
        what = f"{name}  {config.human(it.get('size', 0))}" if it.get("kind") == "file" else \
            '"' + oneline(it.get("text", ""), room - 2) + '"'
        print(head + fit(what, room) + who)
    if any(i.get("to") == "computer" and not i.get("seen") for i in items):
        store.mark_seen()
        desktop.changed()


def get(it):
    """A text printed; a file copied to the current folder (its name printed, so `ferry get` works in a script too).
    To a terminal the text's controls are shown as escapes; piped, it is the text as it came."""
    if it.get("kind") == "text":
        text = it.get("text", "")
        if sys.stdout.isatty():
            text = controls.shown_text(text) + ("" if text.endswith("\n") else "\n")
        sys.stdout.write(text)
    else:
        here = os.path.join(os.getcwd(), store.safe_name(it.get("name", "file")))
        if os.path.exists(here) and os.path.samefile(here, it["path"]):   # already here (Downloads)
            dest = here
        else:
            dest = store.unique(here)
            shutil.copy2(it["path"], dest)
        print(os.path.relpath(dest))
    if it.get("to") == "computer" and not it.get("seen"):
        store.mark_seen({it["id"]})
        desktop.changed()
    store.copied(it)   # a code or a password printed is picked up (docs/protocol.md › Codes and passwords)
    return 0


def send(args, dev):
    """Files when every argument is one, a text otherwise; with no arguments, what is piped in or the clipboard."""
    if args in ([], ["-"]):
        piped = args == ["-"] or not sys.stdin.isatty()
        text = sys.stdin.read() if piped else desktop.paste_text()
        if not text.strip():
            print("Nothing to send: " + ("the input is empty" if piped else "the clipboard has no text"), file=sys.stderr)
            return 1
        err, what = computers.deliver(dev, text=text), f'"{oneline(text, 60)}"'
    elif any(os.path.exists(p) for p in args):
        missing = [p for p in args if not os.path.exists(p)]
        if missing:
            print(f"No such file: {missing[0]} (to send a text with a file's name, pipe it in)", file=sys.stderr)
            return 1
        files = store.file_paths(args)
        err = computers.deliver(dev, files=args)
        what = f"{os.path.basename(files[0]) if len(files) == 1 else f'{len(files)} files'}" + \
            (f" ({config.human(sum(os.path.getsize(f) for f in files))})" if files else "")
    else:
        text = " ".join(args)
        err, what = computers.deliver(dev, text=text), f'"{oneline(text, 60)}"'
    if err:
        print(err, file=sys.stderr)
        return 1
    print(f"Sent {what} to {dev['name']}", flush=True)
    st = tailnet.status()
    if st != "on" and dev["kind"] != "computer":      # off, or off with why and what turns it on
        print(f"Ferry is {st}, so {dev['name']} can't pick it up yet" + ("" if "(" in st else ": ferry enable"),
              file=sys.stderr)
    return 0


def pick_device(args):
    """--to DEVICE taken out of args: (the device, the rest, ""), or (None, args, why not)."""
    want = ""
    if "--to" in args:
        i = args.index("--to")
        if i + 1 >= len(args):
            return None, args, "--to needs a device: see ferry devices"
        want, args = args[i + 1], args[:i] + args[i + 2:]
    devs = computers.devices()
    dev = next((d for d in devs if want in (d["id"], d["name"])), None) if want else computers.target(devs)
    if not dev:
        return None, args, (f"No device {want}: see ferry devices" if want else
                            "No other device yet: add your phone with Add Device in Ferry's menu (or ferry qr)")
    return dev, args, ""


def failed(err):
    """A send from the menu or a drop that didn't go: nobody sees stderr there."""
    notices.notify("Couldn't send", err)
    computers.mark_sent("", "", err)
    print(err, file=sys.stderr)
    return 1


def pick_files(title):
    """Files chosen in a dialog, several at once: zenity's (GNOME's and most desktops'), else kdialog's (KDE's); None
    without either, [] when none was chosen."""
    home = os.path.expanduser("~/")
    for cmd in (["zenity", "--file-selection", "--multiple", "--separator=\n", f"--title={title}", f"--filename={home}"],
                ["kdialog", "--title", title, "--getopenfilename", home, "--multiple", "--separate-output"]):
        if shutil.which(cmd[0]):
            res = subprocess.run(cmd, capture_output=True, text=True, env=desktop.desktop_env())
            return [p for p in res.stdout.splitlines() if p]
    return None
