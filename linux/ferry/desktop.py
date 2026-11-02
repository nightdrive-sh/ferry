"""The desktop Ferry runs beside: its variables, the clipboard, opening files, the hook.

The service starts with the user's session, maybe before the desktop, so the desktop's variables (Wayland's or X11's
display) are looked up whenever the clipboard needs them (desktop_env()). The clipboard is wl-clipboard's, or xclip's on
X11 and where Wayland's can't be reached. A desktop's own Ferry menu hears about changes through HOOK."""
import contextlib
import os
import re
import shutil
import subprocess
import time
import urllib.parse
import urllib.request

from . import config


# GNOME, KDE, Hyprland and others, on Wayland and X11. Each tool runs with desktop_env(): the service has no display
# variables of its own.
DESKTOP_VARS = ("WAYLAND_DISPLAY", "DISPLAY", "XAUTHORITY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE",
                "DBUS_SESSION_BUS_ADDRESS")
_manager = (0.0, {})


def manager_env():
    """The user's service manager's environment, where GNOME and KDE (and Hyprland with uwsm) put the desktop's
    variables when it starts; asked at most every few seconds."""
    global _manager
    if time.monotonic() - _manager[0] < 5:
        return _manager[1]
    try:
        out = subprocess.run(["systemctl", "--user", "show-environment"], capture_output=True, text=True,
                             timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    _manager = (time.monotonic(), dict(line.split("=", 1) for line in out.splitlines() if "=" in line))
    return _manager[1]


def desktop_env(base=None, manager=manager_env, x11="/tmp/.X11-unix"):
    """The environment for a desktop tool: a command run on the desktop has the desktop's own; the service takes them
    from the service manager, else from the sockets the desktop made (a desktop that told nobody, e.g. Hyprland started
    by hand). A WAYLAND_DISPLAY whose socket is gone belongs to a session that ended."""
    env = dict(os.environ if base is None else base)
    if env.get("WAYLAND_DISPLAY") or env.get("DISPLAY"):
        return env
    runtime = env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    m = manager()
    for k in DESKTOP_VARS:
        if m.get(k) and not env.get(k):
            env[k] = m[k]
    if env.get("WAYLAND_DISPLAY") and not os.path.exists(os.path.join(runtime, env["WAYLAND_DISPLAY"])):
        del env["WAYLAND_DISPLAY"]
    if not env.get("WAYLAND_DISPLAY"):
        with contextlib.suppress(OSError):
            found = sorted(n for n in os.listdir(runtime) if re.fullmatch(r"wayland-\d+", n))
            if found:
                env["WAYLAND_DISPLAY"] = found[0]
    if not env.get("DISPLAY"):
        with contextlib.suppress(OSError):
            found = sorted(int(n[1:]) for n in os.listdir(x11) if re.fullmatch(r"X\d+", n))
            if found:
                env["DISPLAY"] = f":{found[0]}"
    return env


def clip_tools(env, have=shutil.which):
    """The clipboards to try, in order: Wayland's, then X11's. On a Wayland desktop X11's is XWayland's, which the
    desktop shares with Wayland's: the way in on GNOME, whose Mutter has no protocol for a clipboard tool without a
    window, when wl-clipboard's own way round that fails."""
    out = []
    if env.get("WAYLAND_DISPLAY") and have("wl-copy"):
        out.append("wayland")
    if env.get("DISPLAY") and have("xclip"):
        out.append("x11")
    return out


def clip_run(cmds, data=None, env=None, run=subprocess.run, have=shutil.which, out=False):
    """Runs cmds[tool] for the first clipboard that takes it: True (or with out, its output), else False (or None).
    cmds[tool] may be a list of commands, tried in turn. A copy's tool stays behind to serve the clipboard, so its
    output isn't waited for."""
    env = desktop_env() if env is None else env
    for tool in clip_tools(env, have):
        for cmd in cmds[tool] if isinstance(cmds[tool][0], list) else [cmds[tool]]:
            try:
                r = run(cmd, input=data, env=env, stdout=subprocess.PIPE if out else subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, timeout=10)
            except (OSError, subprocess.SubprocessError):
                continue
            if r.returncode == 0:
                return r.stdout if out else True
    return None if out else False


def wl_copy(args, sensitive):
    """wl-copy's command. Sensitive: marked so a clipboard history (cliphist, Klipper) doesn't keep it, with a plain copy
    after it for a wl-copy from before --sensitive (wl-clipboard 2.3), which refuses the option. xclip serves one type
    only, so X11's copy can't carry the mark (x-kde-passwordManagerHint) beside the text."""
    plain = ["wl-copy"] + args
    return [["wl-copy", "--sensitive"] + args, plain] if sensitive else plain


def copy_text(text, sensitive=False, **kw):
    return clip_run({"wayland": wl_copy(["--type", "text/plain;charset=utf-8"], sensitive),
                     "x11": ["xclip", "-selection", "clipboard", "-in"]}, text.encode(), **kw)


def copy_file(path, kind, sensitive=False, **kw):
    """A file (an image) onto the clipboard, as its type."""
    with open(path, "rb") as f:
        data = f.read()
    return clip_run({"wayland": wl_copy(["--type", kind], sensitive),
                     "x11": ["xclip", "-selection", "clipboard", "-t", kind, "-in"]}, data, **kw)


def paste_text(**kw):
    """The clipboard's text, or "". What isn't text is no text: xclip, asked for the text of an image that another
    xclip serves (Ferry's own, from the phone, on GNOME), hands over the image's bytes."""
    out = clip_run({"wayland": ["wl-paste", "--no-newline", "--type", "text"],
                    "x11": ["xclip", "-selection", "clipboard", "-out"]}, out=True, **kw)
    try:
        text = out.decode() if out else ""
    except UnicodeDecodeError:
        return ""
    return "" if "\0" in text else text


def session_bus(env):
    """The desktop's session bus's address, where notify-send's GDBus would look: the environment's, else systemd's
    user bus; "" without one (a server)."""
    if env.get("DBUS_SESSION_BUS_ADDRESS"):
        return env["DBUS_SESSION_BUS_ADDRESS"]
    path = os.path.join(env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}", "bus")
    return f"unix:path={path}" if os.path.exists(path) else ""


def previewable(path, kind):
    """The path when the notification can show the file as a picture: the formats every desktop draws (not HEIC),
    else ""."""
    return path if config.PREVIEW.match(kind or "") else ""


def file_uri(path):
    return "file://" + urllib.parse.quote(path)   # not pathname2url: Python 3.14's adds an authority to it


def open_path(path):
    try:
        subprocess.Popen(["xdg-open", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=desktop_env())
    except OSError:
        pass


def show_in_files_cmd(path):
    return ["gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1", "--object-path",
            "/org/freedesktop/FileManager1", "--method", "org.freedesktop.FileManager1.ShowItems",
            f"['{file_uri(path)}']", ""]


def show_in_files(path):
    """The file's folder with the file selected, in any file manager that answers org.freedesktop.FileManager1 (GNOME's
    Files, Dolphin, Nemo, Thunar); just the folder otherwise."""
    try:
        if subprocess.run(show_in_files_cmd(path), capture_output=True, timeout=10, env=desktop_env()).returncode == 0:
            return
    except (OSError, subprocess.SubprocessError):
        pass
    open_path(os.path.dirname(path))


def hook(event):
    """Tells a desktop's own Ferry menu (Nightdrive's top bar) that something changed: HOOK with the event's name."""
    if not os.access(config.HOOK, os.X_OK):
        return None
    try:
        return subprocess.Popen([config.HOOK, event], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=desktop_env())
    except OSError:
        return None


def changed():
    hook("changed")
