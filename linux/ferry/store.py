"""The box: what was received and sent, in STATE/items.json, and the codes and passwords among it.

Items go after KEEP_DAYS days, a code or a password after SECRET_KEEP or once copied; removing one from the box doesn't
delete a file in Downloads."""
import contextlib
import fcntl
import json
import mimetypes
import os
import re
import secrets
import shutil
import time

from . import config, controls, desktop, push


# Unicode's White_Space, as Swift's isWhitespace has it (Python's isspace() adds U+001C to U+001F)
WHITESPACE = "\t\n\v\f\r \x85\xa0\u1680" + "".join(map(chr, range(0x2000, 0x200b))) + "\u2028\u2029\u202f\u205f\u3000"
WORD_JOINERS = "-'\u2019"


def looks_secret(text):
    """docs/protocol.md › Codes and passwords: a code (4 to 8 digits, maybe in groups: "123 456"), or one word of 6 to
    256 characters that mixes letters, digits and other characters and isn't a number, an address, a path or words
    joined by hyphens. FerryKit's Secret.looksLike is the same rule; both run the vectors in
    FerryKit/Tests/FerryKitTests/Fixtures/secrets.json."""
    t = (text or "").strip(WHITESPACE)
    if re.fullmatch(r"[0-9 ()+-]+", t):   # a code, or a number (a phone number) that isn't one
        return bool(re.fullmatch(r"[0-9]+(?:[ -][0-9]+)*", t)) and 4 <= sum(c in "0123456789" for c in t) <= 8
    if not 6 <= len(t) <= 256 or any(c in WHITESPACE for c in t):
        return False
    if "://" in t or t.lower().startswith("www.") or t.startswith(("/", "~/")) or \
            re.fullmatch(r"[^@]+@[^@]+\.[A-Za-z]{2,}", t) or \
            re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(?:/.*)?", t):   # a host (a file) name
        return False
    if t[0].isalpha() and t[-1].isalpha() and all(c.isalpha() or c in WORD_JOINERS for c in t):   # well-known
        return False
    return len({"letter" if c.isalpha() else "digit" if c in "0123456789" else "other" for c in t}) >= 2


def secret(item):
    """An item that is a code or a password: never shown in a notification, kept SECRET_KEEP, gone once copied."""
    return item.get("kind") == "text" and looks_secret(item.get("text"))


@contextlib.contextmanager
def box(write=False):
    """The items (newest last), under a lock shared by the server and the commands; saved after a write."""
    os.makedirs(config.STATE, mode=0o700, exist_ok=True)
    with open(os.path.join(config.STATE, "lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX if write else fcntl.LOCK_SH)
        path = os.path.join(config.STATE, "items.json")
        try:
            with open(path) as f:
                items = json.load(f).get("items") or []
        except (OSError, ValueError, AttributeError):
            items = []
        kept = prune(items) if write else [i for i in items if alive(i)]
        yield kept
        if write:
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"items": kept}, f, ensure_ascii=False)
            os.replace(tmp, path)


def alive(item):
    """Kept KEEP_DAYS days, a code or a password SECRET_KEEP (docs/protocol.md › Codes and passwords)."""
    return time.time() - item.get("time", 0) < (config.SECRET_KEEP if secret(item) else config.KEEP_DAYS * 86400) and \
        (item.get("kind") != "file" or os.path.exists(item.get("path", "")))


def prune(items):
    """Drops old items and those whose file is gone, in place; a file left for the phone goes with its item."""
    for it in [i for i in items if not alive(i)]:
        drop_file(it)
        items.remove(it)
    return items


def drop_file(item):
    """The copy of a file left for the phone (a file from the phone stays in Downloads)."""
    if item.get("kind") == "file" and item.get("to") == "phone":
        shutil.rmtree(os.path.dirname(item["path"]), ignore_errors=True)


def new_item(**kw):
    return dict(kw, id=secrets.token_hex(6), time=time.time())


def safe_name(name):
    """A name for a file from another device: no path, no leading dot, and no controls (controls.py), as a bidi
    control would show a name's end reversed in a file manager."""
    name = controls.name(re.sub(r'[/\\]', "", os.path.basename(name.replace("\\", "/")))).strip().lstrip(".")
    return name[:200] or "file"


def unique(path):
    base, ext = os.path.splitext(path)
    n = 1
    while os.path.exists(path) or os.path.exists(path + ".part"):
        n += 1
        path = f"{base} ({n}){ext}"
    return path


def public(item):
    """An item as the page and the menu see it (no paths for the page)."""
    d = {k: item[k] for k in ("id", "to", "kind", "time") if k in item}
    for k in ("text", "name", "size", "type", "from", "for", "seen"):
        if k in item:
            d[k] = item[k]
    if secret(item):
        d["secret"] = True
    return d


def file_paths(paths):
    out = []
    for p in paths:
        p = os.path.abspath(p)
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = sorted(d for d in dirs if not d.startswith("."))   # no .git and the like
                out += [os.path.join(root, n) for n in sorted(names) if not n.startswith(".")]
        elif os.path.isfile(p):
            out.append(p)
    return out


def add_files(paths, device=""):
    """Leaves files in the box for a phone (device: its tailnet name; "" for any): a hard link when possible (no copy of
    a big video), a copy otherwise."""
    files = file_paths(paths)
    if not files:
        return 1
    added = []
    for src in files:
        it = new_item(to="phone", kind="file", name=safe_name(os.path.basename(src)), size=os.path.getsize(src),
                      type=mimetypes.guess_type(src)[0] or "application/octet-stream")
        if device:
            it["for"] = device
        d = os.path.join(config.STATE, "files", it["id"])
        os.makedirs(d, exist_ok=True)
        it["path"] = os.path.join(d, it["name"])
        try:
            os.link(src, it["path"])
        except OSError:
            shutil.copy2(src, it["path"])
        added.append(it)
    with box(write=True) as items:
        items += added
    what = added[0]["name"] if len(added) == 1 else f"{len(added)} files"
    push.push_all(config.alias(), what, item=added[0], device=device)   # iOS shows the title as "<title> from Ferry"
    return 0


def add_text(text, device=""):
    if not text.strip():
        return 1
    text = text[:config.MAX_TEXT]
    it = new_item(to="phone", kind="text", text=text)
    if device:
        it["for"] = device
    with box(write=True) as items:
        items.append(it)
    push.push_all(config.alias(), text[:180], item=it, device=device)
    return 0


def for_device(item, device):
    """Whether the page on device lists an item: what it sent, and what waits for it or for any phone."""
    return item.get("to") != "phone" or not item.get("for") or item["for"] == device


def find(item_id):
    with box() as items:
        return next((i for i in items if i["id"] == item_id), None)


def remove(item_id):
    with box(write=True) as items:
        for it in [i for i in items if i["id"] == item_id]:
            drop_file(it)
            items.remove(it)


def copied(item):
    """A text copied on this computer (its notification, the window, `ferry copy`): a code or a password leaves the box
    then (docs/protocol.md › Codes and passwords)."""
    if secret(item):
        remove(item["id"])
        desktop.changed()


def numbered():
    """The box as `ferry list` numbers it: what was received, then what was sent, each newest first (so 1 is the newest
    received, which `ferry get` takes)."""
    with box() as items:
        items = items[::-1]
    return [i for i in items if i.get("to") == "computer"] + [i for i in items if i.get("to") != "computer"]


def item(ref, items=None):
    """An item by its number in `ferry list`, or by its id."""
    items = numbered() if items is None else items
    if ref.isdigit() and len(ref) < 12:   # an id is 12 hex digits
        n = int(ref)
        return items[n - 1] if 0 < n <= len(items) else None
    return next((i for i in items if i["id"] == ref), None)


def mark_seen(ids=None):
    """What came from the phone as seen, all of it or the items in ids: the bar's count goes."""
    with box(write=True) as items:
        for it in items:
            if it.get("to") == "computer" and (ids is None or it["id"] in ids):
                it["seen"] = True
