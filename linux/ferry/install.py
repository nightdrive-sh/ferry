"""Ferry in the desktop: the user service, the app list's entry and icons, the file managers' menus, the tray's
autostart, and the move from Nightdrive's plugin's state (migrate())."""
import contextlib
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys

from . import config, push, tailnet


def quietly(*cmd):
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)


def desktop_entry(background=False):
    """Ferry's .desktop file: the window in the app list, and "Open With → Ferry" for any file, which sends it; or
    (background) the tray icon, started at login. It runs this copy of ferry."""
    exe = os.path.join(config.ROOT, "bin", "ferry")
    exe = f'"{exe}"' if re.search(r"[\s\"'\\]", exe) else exe
    lines = ["[Desktop Entry]", "Type=Application", "Name=Ferry", "GenericName=Device Mailbox",
             "Comment=Send texts, the clipboard and files to your other devices over Tailscale",
             f"Icon={config.APP_ID}", "Terminal=false"]
    if background:
        lines += [f"Exec={exe} app --background", "NoDisplay=true", "X-GNOME-Autostart-enabled=true"]
    else:
        lines += [f"Exec={exe} app %F", "Categories=Network;FileTransfer;Utility;",
                  "Keywords=send;share;clipboard;phone;iPhone;Tailscale;",
                  # Open With for any file in KDE, which takes every type as a kind of application/octet-stream. Not
                  # the types themselves: a desktop file in the user's own folder would become their default app
                  # (GNOME's PDFs would open Ferry); the file managers' own menus have "Send with Ferry" instead
                  "MimeType=application/octet-stream;", "StartupNotify=true", "SingleMainWindow=true"]
    return "\n".join(lines) + "\n"


def write_file(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w") as f:
        f.write(text)
    os.replace(path + ".tmp", path)


def file_manager_menus():
    """"Send with Ferry" in the file managers' own menus, for the selected files: {path: (text, executable)}. GNOME
    Files has it under Scripts, Dolphin (KDE) and Nemo (Cinnamon) in the menu itself."""
    exe = os.path.join(config.ROOT, "bin", "ferry")
    quoted = f'"{exe}"' if re.search(r"[\s\"'\\]", exe) else exe
    data, home = config.data_home(), os.path.expanduser("~")
    return {
        os.path.join(data, "nautilus", "scripts", "Send with Ferry"):
            (f'#!/bin/sh\n# Ferry\'s "Send with Ferry" in GNOME Files (Scripts): the selected files, after picking the device\n'
             f'exec "{exe}" app "$@"\n', True),
        os.path.join(data, "kio", "servicemenus", config.APP_ID + ".desktop"):
            ("[Desktop Entry]\nType=Service\nMimeType=all/allfiles;\nActions=send;\nX-KDE-Priority=TopLevel\n\n"
             f"[Desktop Action send]\nName=Send with Ferry\nIcon={config.APP_ID}\nExec={quoted} app %F\n", True),
        os.path.join(data, "nemo", "actions", "ferry.nemo_action"):
            ("[Nemo Action]\nName=Send with Ferry\nComment=Send the selected files to one of your devices\n"
             f"Exec={quoted} app %F\nIcon-Name={config.APP_ID}\nSelection=notnone\nExtensions=nodirs;\n", False),
    }


def install_launcher():
    """Ferry in the app list and the file managers' menus, its icon, and its tray icon at login unless
    `ferry tray off`."""
    write_file(os.path.join(config.APPLICATIONS, config.APP_ID + ".desktop"), desktop_entry())
    for path, (text, executable) in file_manager_menus().items():
        write_file(path, text)
        if executable:   # Dolphin runs a service menu only if it is
            os.chmod(path, 0o755)
    for size in (192, 512):
        d = os.path.join(config.ICONS, f"{size}x{size}", "apps")
        os.makedirs(d, exist_ok=True)
        shutil.copyfile(os.path.join(config.WEB, f"icon-{size}.png"), os.path.join(d, config.APP_ID + ".png"))
    set_tray(tray_wanted())
    quietly("update-desktop-database", config.APPLICATIONS)
    quietly("gtk-update-icon-cache", "-q", "-t", config.ICONS)


def tray_wanted():
    return not os.path.exists(config.NO_TRAY)


def set_tray(on):
    """The tray icon at login, or not (remembered across updates)."""
    path = os.path.join(config.AUTOSTART, config.APP_ID + ".desktop")
    if on:
        with contextlib.suppress(OSError):
            os.remove(config.NO_TRAY)
        write_file(path, desktop_entry(background=True))
    else:
        write_file(config.NO_TRAY, "")
        with contextlib.suppress(OSError):
            os.remove(path)


def install_unit():
    """The unit into the user's units, its ExecStart naming this copy of ferry (the installed one, or a checkout's)."""
    with open(config.UNIT) as f:
        unit = f.read()
    exe = os.path.realpath(os.path.join(config.ROOT, "bin", "ferry")).replace("%", "%%")
    exe = f'"{exe}"' if re.search(r"\s", exe) else exe
    unit = re.sub(r"(?m)^ExecStart=.*$", lambda _: f"ExecStart={exe} run", unit)
    os.makedirs(config.USER_UNITS, exist_ok=True)
    tmp = os.path.join(config.USER_UNITS, config.SERVICE + ".tmp")
    with open(tmp, "w") as f:
        f.write(unit)
    os.replace(tmp, os.path.join(config.USER_UNITS, config.SERVICE))


def enable():
    """The server on: its unit installed and (re)started, so an update runs the new copy, published on the tailnet,
    and the app in the desktop's app list."""
    if not push.vapid_key(create=True):
        print("No python3-cryptography: Ferry works, but without notifications on the phone", file=sys.stderr)
    stop_old()   # its port is this one's
    install_unit()
    install_launcher()
    tailnet.systemctl("daemon-reload")
    for args in (("enable", config.SERVICE), ("restart", config.SERVICE)):
        res = tailnet.systemctl(*args)
        if res.returncode:
            print(res.stderr.strip() or f"systemctl --user {' '.join(args)} failed", file=sys.stderr)
            return 1
    if not shutil.which("tailscale"):
        print("Ferry is on, and needs Tailscale to be reached: https://tailscale.com/download/linux, then: ferry enable",
              file=sys.stderr)
        return 1
    err = tailnet.serve(True)
    if err:
        print(tailnet.serve_message(err), file=sys.stderr)
        return 1
    print(tailnet.url() or "Ferry is on; Tailscale is off, so the page has no address yet")
    return 0


def stop_old():
    """Nightdrive's Ferry plugin's server, off for good: this one takes its port and its state."""
    tailnet.systemctl("disable", "--now", config.OLD_SERVICE)


def migrate(old=config.OLD_STATE, new=config.STATE, stop=stop_old):
    """Moves the state of Nightdrive's Ferry plugin here, once: the VAPID key the phones' subscriptions are bound to,
    the subscriptions, the computers found and the box, so the phones keep their notifications and the box its items.
    True when it moved.

    Under a lock on new's parent folder, so that two commands starting at once neither both move it nor one makes a new
    state (and a new VAPID key) while the other moves the old. The box's paths to files left for the phone are rewritten
    before the move, so no reader ever finds them gone (a write drops items whose file is gone)."""
    if os.path.exists(new) or not os.path.isdir(old):
        return False
    parent = os.path.dirname(new)
    os.makedirs(parent, exist_ok=True)
    fd = os.open(parent, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        if os.path.exists(new) or not os.path.isdir(old):
            return False
        stop()
        path = os.path.join(old, "items.json")
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, ValueError):
            data = None
        if isinstance(data, dict) and isinstance(data.get("items"), list):
            for it in data["items"]:
                p = it.get("path") if isinstance(it, dict) else None
                if isinstance(p, str) and p.startswith(old + os.sep):
                    it["path"] = new + p[len(old):]
            with open(path + ".tmp", "w") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(path + ".tmp", path)
        try:
            os.rename(old, new)
        except OSError:   # on another file system
            shutil.copytree(old, new, symlinks=True)
            shutil.rmtree(old)
        os.chmod(new, 0o700)
        return True
    finally:
        os.close(fd)
