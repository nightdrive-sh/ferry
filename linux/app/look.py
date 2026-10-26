"""Ferry's look on Linux, without GTK: the colours, the style sheet, the icons and how an item is described. The window
(ferry_app.py) draws with these, and the tests check them on any computer.

The colours are the iPhone and Mac apps' (ios/Shared/Colors.xcassets), light and dark: Ferry's own look rather than
the desktop's theme, as on the Mac. Content is in JetBrains Mono, chrome in the desktop's own font."""
import json
import os
import re
import time

# The asset catalog's colour sets, light then dark (Nightdrive's violet)
PALETTE = {
    "light": {"background": "#F6F2F9", "card": "#FFFFFF", "tile": "#F0E4F8", "hairline": "#EBE2F1",
              "border": "#E2D5EA", "text": "#2A1F33", "dim": "#7A6B88", "accent": "#7B2FB0", "primary": "#9C3FD6",
              "on_primary": "#FFFFFF", "online": "#3F9A36", "away": "#D6365A"},
    "dark": {"background": "#0B0B0D", "card": "#16121B", "tile": "#35253D", "hairline": "#2A2233",
             "border": "#3A2F45", "text": "#C9BDD3", "dim": "#9486A3", "accent": "#E0BFF2", "primary": "#C071EB",
             "on_primary": "#12081A", "online": "#9ECE6A", "away": "#F7768E"},
}

MONO = '"JetBrains Mono", monospace'

# Nightdrive's theme, as its `theme apply` writes it for its own apps (Quickshell's Theme.qml)
NIGHTDRIVE_THEME = os.path.expanduser("~/.cache/nightdrive/theme.json")


def hyprland(desktop):
    """Whether Ferry runs on Hyprland (desktop: XDG_CURRENT_DESKTOP), as on Nightdrive. There the window is drawn as
    Nightdrive's own apps are: it may be tiled, its list fades out under the device, and Aa and + are round. GNOME
    and KDE keep the Mac popover's look."""
    return "hyprland" in desktop.lower().split(":")


def nightdrive_palette(path=NIGHTDRIVE_THEME):
    """Nightdrive's theme as Ferry's dark palette, or None without one: the background its apps have (the terminals',
    a touch see-through, the window's border and blur showing through), its rows, lines and text in the theme's colour.
    The state colours stay Ferry's."""
    try:
        with open(path) as f:
            t = json.load(f)
        argb = t["launcherBg"]                  # Qt's #AARRGGBB
        a, r, g, b = (int(argb[i:i + 2], 16) for i in (1, 3, 5, 7))
        p = dict(PALETTE["dark"], card=t["card"], tile=t["sel"], border=t["border"], text=t["text"], dim=t["dim"],
                 accent=t["accent"], primary=t["primary"])
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        return None
    if not all(re.fullmatch(r"#[0-9a-fA-F]{6}", v) for v in p.values()):
        return None
    p["background"] = f"rgba({r}, {g}, {b}, {a / 255:.2f})"
    # The kit's line between parts (AppLook.qml): the background, lighter
    p["hairline"] = "#" + "".join(f"{min(255, round(c * 1.45)):02x}" for c in (r, g, b))
    return p

# Lucide's icons (lucide.dev, ISC licence), as Nightdrive and Ferry's page use them: stroke paths on a 24 px grid
ICONS = {
    "inbox": '<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 '
             '2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
    "text": '<path d="M17 6.1H3M21 12.1H3M15.1 18H3"/>',
    "link": '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 '
            '0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
    "file": '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>',
    "image": '<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 '
             '15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>',
    "copy": '<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 '
            '2-2h10c1.1 0 2 .9 2 2"/>',
    "external-link": '<path d="M15 3h6v6m-11 5L21 3m-3 10v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>',
    "clipboard-paste": '<path d="M11 14h10M16 4h2a2 2 0 0 1 2 2v1.344M17 18l4-4l-4-4"/><path d="M8 4H6a2 2 0 0 '
                       '0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 1.793-1.113"/><rect width="8" height="4" x="8" y="2" '
                       'rx="1"/>',
    "plus": '<path d="M5 12h14M12 5v14"/>',
    "type": '<polyline points="4 7 4 4 20 4 20 7"/><line x1="9" x2="15" y1="20" y2="20"/><line x1="12" x2="12" '
            'y1="4" y2="20"/>',
    "refresh-cw": '<path d="M3 12a9 9 0 0 1 9-9a9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5m5 4a9 9 0 0 '
                  '1-9 9a9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>',
    "chevrons-up-down": '<path d="m7 15 5 5 5-5"/><path d="m7 9 5-5 5 5"/>',
    "chevron-left": '<path d="m15 18-6-6 6-6"/>',
    "ellipsis": '<circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/><circle cx="5" cy="12" r="1"/>',
    "monitor": '<rect width="20" height="14" x="2" y="3" rx="2"/><line x1="8" x2="16" y1="21" y2="21"/><line '
               'x1="12" x2="12" y1="17" y2="21"/>',
    "smartphone": '<rect width="14" height="20" x="5" y="2" rx="2" ry="2"/><path d="M12 18h.01"/>',
    "tablet": '<rect width="16" height="20" x="4" y="2" rx="2" ry="2"/><line x1="12" x2="12.01" y1="18" y2="18"/>',
    "triangle-alert": '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path '
                      'd="M12 9v4"/><path d="M12 17h.01"/>',
    "circle-arrow-down": '<circle cx="12" cy="12" r="10"/><path d="M12 8v8"/><path d="m8 12 4 4 4-4"/>',
    "power": '<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.77.04"/>',
    "log-in": '<path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4"/><polyline points="10 17 15 12 10 7"/><line '
              'x1="15" x2="3" y1="12" y2="12"/>',
    "lock": '<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
    "shield-check": '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 '
                    '4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 '
                    '12 2 2 4-4"/>',
    "globe": '<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path '
             'd="M2 12h20"/>',
    "folder-open": '<path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 '
                   '2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/>',
    "trash-2": '<path d="M10 11v6m4-6v6m5-11v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 '
               '0 1 2 2v2"/>',
    "check": '<path d="M20 6L9 17l-5-5"/>',
}

# Each setup step's icon (bin/ferry's setup_step())
STEP_ICONS = {"tailscale-missing": "circle-arrow-down", "tailscale-off": "power", "logged-out": "log-in",
              "needs-approval": "shield-check", "tailscale-stopped": "power", "stopped": "power",
              "https-off": "lock", "not-published": "globe", "operator": "shield-check", "problem": "triangle-alert"}

# What the step's link button says
LINK_TITLES = {"tailscale-missing": "Get Tailscale", "logged-out": "Log In", "needs-approval": "Open Admin Console",
               "https-off": "Open DNS Settings"}

# What the step's own button does, and says
ACTION_TITLES = {"enable": "Turn On", "tailscale-up": "Turn On Tailscale", "publish": "Try Again",
                 "operator": "Allow…"}


def svg(name, color, size=24, stroke=2.0):
    """A Lucide icon as an SVG document in one colour, size pixels square."""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" '
            f'stroke="{color}" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round">'
            f'{ICONS[name]}</svg>')


def tray_white(desktop, home=None, config_dirs=""):
    """Whether the tray icon is drawn white, as the panel's own icons are: GNOME's top bar is dark whatever the theme,
    Plasma's panel is its Plasma theme's (plasma_panel_dark()); others may be light. desktop: XDG_CURRENT_DESKTOP, e.g.
    "ubuntu:GNOME"; home and config_dirs (XDG_CONFIG_DIRS) where KDE's settings are."""
    names = desktop.lower().split(":")
    if "gnome" in names:
        return True
    if "kde" in names:
        home = home or os.path.expanduser("~")
        dirs = [os.path.join(home, ".config"), os.path.join(home, ".config", "kdedefaults")]
        return plasma_panel_dark(dirs + [d for d in (config_dirs or "/etc/xdg").split(":") if d and d not in dirs])
    return False


def plasma_panel_dark(dirs):
    """Whether Plasma's panel is dark: a dark Plasma theme (Fedora's KDE has Breeze Dark's panel over light apps), or
    Breeze's own ("default"), which takes the colour scheme's. Another theme keeps the colour icon, which reads on
    either."""
    theme = kde_setting(dirs, "plasmarc", "Theme", "name") or "default"
    if "dark" in theme.lower():
        return True
    if theme != "default":
        return False
    rgb = kde_setting(dirs, "kdeglobals", "Colors:Header", "BackgroundNormal") or \
        kde_setting(dirs, "kdeglobals", "Colors:Window", "BackgroundNormal")
    try:
        r, g, b = (int(c) for c in rgb.split(",")[:3])
    except ValueError:
        return False
    return 0.2126 * r + 0.7152 * g + 0.0722 * b < 128


def kde_setting(dirs, name, group, key):
    """A KDE setting from the first of dirs whose file has it (the user's, then the look-and-feel's defaults, then the
    system's, as KConfig cascades), "" when none does."""
    for d in dirs:
        try:
            with open(os.path.join(d, name), encoding="utf-8", errors="replace") as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        here = False
        for line in lines:
            line = line.strip()
            if line.startswith("["):
                here = line == f"[{group}]"
            elif here and "=" in line:
                k, v = line.split("=", 1)
                if k.strip() == key:
                    return v.strip()
    return ""


def without_icon(layout):
    """GTK's decoration layout ("icon:minimize,close") without the window's icon: KDE's settings put the app icon, a
    violet square, in the header's corner, and Ferry's own mark is by its title on every desktop."""
    return ":".join(",".join(b for b in side.split(",") if b and b != "icon") for side in layout.split(":")) \
        if layout else ""


def tray_svg(count, size=22, white=False, thin=False):
    """The tray icon: Ferry's inbox in the app icon's sunset colours, which read on a light panel and a dark one, or
    white (tray_white()), and the count of what arrived unseen on a violet badge. thin: finer and a little smaller,
    among Plasma's Breeze icons, which are drawn with fine lines."""
    badge, shift = "", ""
    if count:   # large: a panel draws the icon at 16 px
        text = "9+" if count > 9 else str(count)
        badge = (f'<circle cx="16.5" cy="16.5" r="7.5" fill="#9C3FD6" stroke="#ffffff" stroke-width="1"/>'
                 f'<text x="16.5" y="20.6" font-family="sans-serif" font-weight="700" '
                 f'font-size="{12 if len(text) == 1 else 9.5}" fill="#ffffff" text-anchor="middle">{text}</text>')
        shift = "translate(-2 -3)"   # the inbox up and left, out of the badge's way
    if thin:
        shift = (shift + " translate(1.2 1.2) scale(.9)").strip()   # about its middle
    defs = "" if white else (
        '<defs><linearGradient id="n" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffb35c"/>'
        '<stop offset=".45" stop-color="#ff4f9a"/><stop offset="1" stop-color="#b56bff"/></linearGradient></defs>')
    transform = f' transform="{shift}"' if shift else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 24 24">{defs}'
            f'<g fill="none" stroke="{"#ffffff" if white else "url(#n)"}" stroke-width="{1.6 if thin else 2.1}" '
            f'stroke-linecap="round" stroke-linejoin="round"{transform}>{ICONS["inbox"]}</g>{badge}</svg>')


def phone_added(before, data):
    """Whether a phone was added while Add Device showed: a new push subscription, which the iPhone app makes as soon
    as it has the computer. before: the listing's count when the page opened (None: no listing yet)."""
    return before is not None and data.get("push", 0) > before


def css(p):
    """The style sheet for one palette. GTK's own theme still draws what isn't named here; this takes its colours,
    borders and shadows away where Ferry has its own."""
    return f"""
window.ferry, window.ferry > .background {{ background-color: {p["background"]}; color: {p["text"]}; }}
window.ferry headerbar {{ background: {p["background"]}; color: {p["text"]}; box-shadow: none;
    border-bottom: 1px solid {p["hairline"]}; min-height: 40px; }}
window.ferry .title {{ font-weight: 600; padding: 0; }}
.ferry label {{ color: {p["text"]}; }}
.ferry .mono {{ font-family: {MONO}; }}
.ferry .dim, .ferry label.dim {{ color: {p["dim"]}; }}
.ferry label.section {{ font-family: {MONO}; font-weight: 700; font-size: 0.78em; letter-spacing: 1.5px;
    color: {p["primary"]}; }}
.ferry label.away {{ color: {p["away"]}; }}
.ferry label.code {{ font-family: {MONO}; font-weight: 600; font-size: 1.35em; letter-spacing: 3px;
    color: {p["accent"]}; }}
.ferry label.copied {{ color: {p["primary"]}; font-family: {MONO}; font-weight: 500; }}
.ferry label.title-step {{ font-weight: 700; font-size: 1.1em; }}
.ferry label.meta {{ font-family: {MONO}; font-size: 0.82em; color: {p["dim"]}; }}
.ferry label.item {{ font-family: {MONO}; font-size: 0.92em; }}

.ferry button.fb, .ferry menubutton.fb > button {{ background: {p["card"]}; background-image: none; color: {p["text"]}; border: 1px solid {p["border"]};
    box-shadow: none; text-shadow: none; border-radius: 999px; padding: 4px 14px; min-height: 26px; outline: none; }}
.ferry button.fb:hover, .ferry menubutton.fb > button:hover {{ background: {p["tile"]}; }}
.ferry button.fb:active, .ferry menubutton.fb > button:active {{ background: {p["border"]}; }}
.ferry button.fb:disabled, .ferry menubutton.fb > button:disabled {{ opacity: 0.45; }}
.ferry button.fb:focus-visible, .ferry menubutton.fb > button:focus-visible {{ box-shadow: 0 0 0 2px {p["primary"]}; }}
.ferry button.fb.flat, .ferry menubutton.fb.flat > button {{ background: transparent; border-color: transparent; color: {p["dim"]}; padding: 2px 8px; }}
.ferry button.fb.flat:hover, .ferry menubutton.fb.flat > button:hover {{ background: {p["tile"]}; color: {p["text"]}; }}
.ferry button.fb.flat.back {{ padding-left: 2px; }}
.ferry button.fb.primary, .ferry menubutton.fb.primary > button {{ background: {p["primary"]}; color: {p["on_primary"]}; border-color: {p["primary"]};
    font-weight: 600; min-height: 34px; }}
.ferry button.primary label {{ color: {p["on_primary"]}; }}
.ferry button.fb.primary:hover, .ferry menubutton.fb.primary > button:hover {{ background: shade({p["primary"]}, 1.08); }}
.ferry button.fb.destructive, .ferry menubutton.fb.destructive > button {{ color: {p["away"]}; }}
.ferry button.fb.circle, .ferry menubutton.fb.circle > button {{ padding: 0; min-width: 34px; min-height: 34px; color: {p["accent"]}; }}
.ferry button.fb.circle.round {{ min-width: 42px; }}   /* as tall as Send Clipboard: a circle, not a pill */
.ferry .fade {{ min-height: 48px; background-image: linear-gradient(to bottom, alpha({p["background"]}, 0), {p["background"]} 70%); }}
.ferry button.fb.small-circle, .ferry menubutton.fb.small-circle > button {{ padding: 0; min-width: 28px; min-height: 28px; border: none; background: {p["tile"]};
    color: {p["accent"]}; }}
.ferry button.fb.small-circle:hover, .ferry menubutton.fb.small-circle > button:hover {{ background: {p["border"]}; }}
.ferry button.fb.pill, .ferry menubutton.fb.pill > button {{ padding: 0 12px; min-height: 28px; }}
.ferry button.fb.menuitem, .ferry menubutton.fb.menuitem > button {{ background: transparent; border: none; border-radius: 8px; padding: 6px 10px;
    min-height: 0; }}
.ferry button.fb.menuitem:hover, .ferry menubutton.fb.menuitem > button:hover {{ background: {p["tile"]}; }}
.ferry button.fb.menuitem:disabled, .ferry menubutton.fb.menuitem > button:disabled {{ opacity: 0.4; }}

.ferry .dot {{ min-width: 8px; min-height: 8px; border-radius: 999px; background: {p["online"]}; }}
.ferry .dot.away {{ background: {p["away"]}; }}
.ferry .tile {{ background: {p["tile"]}; border-radius: 8px; min-width: 36px; min-height: 36px; }}
.ferry list, .ferry list > row {{ background: transparent; }}
.ferry list > row {{ border-radius: 10px; padding: 0 8px; min-height: 50px; outline: none; }}
.ferry list > row:hover {{ background: alpha({p["tile"]}, 0.7); }}
.ferry list > row:selected {{ background: alpha({p["tile"]}, 0.7); }}
.ferry .device {{ background: {p["tile"]}; border-radius: 12px; min-height: 96px; }}
.ferry .device:hover {{ background: {p["border"]}; }}
.ferry .device.over {{ box-shadow: inset 0 0 0 2px {p["primary"]}; }}
.ferry .device.closed {{ opacity: 0.4; }}
.ferry .qr {{ background: #ffffff; border-radius: 12px; padding: 12px; }}
.ferry .banner {{ background: {p["tile"]}; border-radius: 10px; padding: 6px 6px 6px 12px; }}
.ferry .command {{ background: {p["tile"]}; border-radius: 8px; padding: 6px 6px 6px 10px; }}
.ferry entry {{ background: {p["card"]}; color: {p["text"]}; border: 1px solid {p["border"]}; border-radius: 10px;
    box-shadow: none; font-family: {MONO}; min-height: 32px; caret-color: {p["primary"]}; }}
.ferry entry:focus-within {{ border-color: {p["primary"]}; outline: none; }}
.ferry entry selection {{ background: alpha({p["primary"]}, 0.35); }}
popover.ferry > contents {{ background: {p["card"]}; color: {p["text"]}; border: 1px solid {p["border"]};
    border-radius: 12px; padding: 4px; box-shadow: 0 6px 20px alpha(black, 0.25); }}
popover.ferry > arrow {{ background: {p["card"]}; border-color: {p["border"]}; }}
popover.ferry separator {{ background: {p["hairline"]}; margin: 4px 6px; }}
.ferry scrollbar slider {{ background: {p["border"]}; }}
.ferry scrollbar {{ background: transparent; }}
.ferry spinner {{ color: {p["primary"]}; }}
"""


def human(n):
    """A file's size, 1000-based as the page and the apps say it: "240 B", "5.7 MB"."""
    if n < 1000:
        return f"{n} B"
    for unit in ("KB", "MB", "GB"):
        n /= 1000
        if n < 1000 or unit == "GB":
            return f"{n:.1f} {unit}"


def age(seconds):
    """How long ago, as the apps say it: "now", "12 min", "3 h", "2 d"."""
    if seconds < 60:
        return "now"
    if seconds < 3600:
        return f"{int(seconds // 60)} min"
    if seconds < 86400:
        return f"{int(seconds // 3600)} h"
    return f"{int(seconds // 86400)} d"


def meta(item, now=None):
    """The line under an item: size · age · the device it came from."""
    now = time.time() if now is None else now
    parts = []
    if item.get("kind") == "file" and item.get("size") is not None:
        parts.append(human(item["size"]))
    parts.append(age(now - item.get("time", now)))
    if item.get("from"):
        parts.append(item["from"])
    return " · ".join(parts)


def link(text):
    """The address, when a text is one web address and nothing else (the list opens it)."""
    t = (text or "").strip()
    if not t or re.search(r"\s", t) or not re.match(r"(?i)^https?://[^/?#\s]+", t):
        return None
    return t


def code(text):
    """A one-time code: 4 to 8 digits, alone, shown large."""
    t = (text or "").strip()
    return t if 4 <= len(t) <= 8 and t.isdigit() else None


def oneline(text):
    return " ".join((text or "").split())


def is_image(item):
    return item.get("kind") == "file" and (item.get("type") or "").startswith("image/")


def item_icon(item):
    if item.get("kind") == "file":
        return "image" if is_image(item) else "file"
    return "link" if link(item.get("text")) else "text"


def device_icon(device):
    return {"computer": "monitor", "tablet": "tablet"}.get(device.get("kind"), "smartphone")


FORGET_NOTE = ("Forget takes a device off the lists on all your devices, and a phone gets no more notifications. "
               "It stays forgotten until you bring it back.")


def device_rows(data):
    """The Devices page: the owner's devices, to forget, then the forgotten ones, to bring back ((device, forgotten))."""
    return [(d, False) for d in data.get("devices") or []] + [(d, True) for d in data.get("forgotten") or []]


def can_take(device):
    """A phone takes what waits in the box when it wakes; a computer has to answer now."""
    return device.get("kind") != "computer" or bool(device.get("online"))


def tiles(devices):
    """The devices as the drop tiles show them: online ones first, each group in the device list's order."""
    return [d for d in devices if d.get("online")] + [d for d in devices if not d.get("online")]


def what(paths):
    """Files to send, in a header: the one name, or how many."""
    return os.path.basename(paths[0]) if len(paths) == 1 else f"{len(paths)} files"


def received(items):
    """The box's items from the other devices, newest first."""
    return sorted((i for i in items if i.get("to") == "computer"), key=lambda i: i.get("time", 0), reverse=True)


def clear_question(n):
    return f"Clear {n} item{'' if n == 1 else 's'}?"
