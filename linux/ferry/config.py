"""Ferry's constants and paths: where its state, its config and the desktop's folders are, and the limits."""
import os
import re
import socket
import subprocess


PORT = 47270                 # the local server (127.0.0.1 only: tailscale serve is the way in)
HTTPS_PORT = 443             # tailscale serve's port on the tailnet name
MOUNT = "/ferry"             # the page's path there (tailscale serve strips it before the request reaches us)
VERSION = "1.0.0"


def state_dir(env=os.environ, home=os.path.expanduser("~")):
    return os.path.join(env.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share"), "ferry")


def config_dir(env=os.environ, home=os.path.expanduser("~")):
    return os.path.join(env.get("XDG_CONFIG_HOME") or os.path.join(home, ".config"), "ferry")


def data_home(env=os.environ, home=os.path.expanduser("~")):
    return env.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")


ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))   # ferry/.., beside bin/ (~/.local/bin/ferry links to bin/ferry)
STATE = state_dir()
OLD_STATE = os.path.expanduser("~/.local/share/nightdrive/ferry")   # Nightdrive's Ferry plugin kept it here
OLD_SERVICE = "nightdrive-ferry.service"                            # and ran this
QR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "ferry", "qr.svg")
# Add Device's QR code is this page with the address in its fragment, which the browser keeps to itself: the iPhone app
# opens it as a universal link, and without the app the page says what is needed
ADD_PAGE = "https://nightdrive.sh/ferry/add"
HOOK = os.path.join(config_dir(), "hook")
WEB = os.path.join(ROOT, "web")                    # the page
FONTS = os.path.join(WEB, "fonts")                 # Ferry's font for the page too (the apps' JetBrains Mono)
FONT_FILES = ("JetBrainsMono-Regular.ttf", "JetBrainsMono-Medium.ttf", "JetBrainsMono-Bold.ttf")
SERVICE = "ferry.service"
UNIT = os.path.join(ROOT, "systemd", SERVICE)      # copied to USER_UNITS by `ferry enable`
USER_UNITS = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "systemd", "user")
APPLICATIONS = os.path.join(data_home(), "applications")     # the app list's entry, also "Open With"
ICONS = os.path.join(data_home(), "icons", "hicolor")
AUTOSTART = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "autostart")
NO_TRAY = os.path.join(config_dir(), "no-tray")   # `ferry tray off`: no tray icon at login (Nightdrive has its own)
MANAGED = os.path.join(config_dir(), "managed")   # names what updates Ferry instead (install.sh --managed-by): updates.py
APP = "Ferry"                # the notifications' app name
ICON = os.path.realpath(os.path.join(WEB, "icon-192.png"))   # the app icon the phone has too (PNG: Qt draws no SVG glow)
KEEP_DAYS = 7                # an item leaves the box after this many days
SECRET_KEEP = 15 * 60        # seconds the box keeps a code or a password, unless it is copied sooner
SECRET_NAMED = "Code or password"   # what a notification says in a code's or a password's place…
SECRET_HIDDEN = SECRET_NAMED + " · open to see"   # …and when it waits in the box
MAX_FILE = 4 << 30           # bytes per file from the phone
MAX_TEXT = 1 << 20           # bytes of text
PUSH_PAYLOAD = 2600          # bytes of a notification: Ferry's push relay takes 2800 encrypted (APNs' 4 KB as base64)
MIN_FREE = 2 << 30           # bytes left free on the disk: an upload that would go below this is refused
PREVIEW = re.compile(r"^image/(jpeg|png|gif|webp|bmp)$")   # a received image the notification shows as a picture
INLINE = re.compile(r"^(image/(jpeg|png|gif|webp|heic|heif|avif)|video/|audio/|application/pdf$|text/plain$)")
                             # shown in the browser; any other file is a download (an HTML or SVG file would run its
                             # scripts as the Ferry page)
CHUNK = 1 << 20
GROUP_NOTIFY = 20            # seconds: files from the phone within this time share one notification
NOTIFY_WAIT = 5              # seconds for the notification daemon to answer (none: notify-send never ends)
PUSH_CONTACT = "mailto:hello@nightdrive.sh"   # the VAPID "sub": push services want a contact
IDLE_AFTER = 60              # seconds without input before the computer counts as idle (docs/protocol.md: api/items)
MACHINES_EVERY = 300         # seconds between the server's looks for the owner's other computers running Ferry
SENT_SHOWN = 5               # seconds the menu shows "Sent" for a send (STATE/sent.json), whoever sent it
TAILSCALE_DOWNLOAD = "https://tailscale.com/download/linux"
TAILSCALE_DNS = "https://login.tailscale.com/admin/dns"            # where a tailnet's HTTPS certificates are turned on
TAILSCALE_MACHINES = "https://login.tailscale.com/admin/machines"  # where a new machine is approved
RELEASES = os.environ.get("FERRY_RELEASES") or "https://api.github.com/repos/nightdrive-sh/ferry/releases?per_page=30"
TARBALL = "ferry-linux.tar.gz"                     # a release's Linux files (linux/release.sh), and its install.sh
APP_ID = "sh.nightdrive.Ferry"                     # the window's app id, its .desktop file's name and its icon's


def downloads():
    try:
        d = subprocess.run(["xdg-user-dir", "DOWNLOAD"], capture_output=True, text=True).stdout.strip()
    except OSError:
        d = ""
    return d if d and d != os.path.expanduser("~") else os.path.expanduser("~/Downloads")


def alias():
    try:
        pretty = subprocess.run(["hostnamectl", "--pretty"], capture_output=True, text=True).stdout.strip()
    except OSError:
        pretty = ""
    return pretty or socket.gethostname().split(".")[0].capitalize()


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1000 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1000
