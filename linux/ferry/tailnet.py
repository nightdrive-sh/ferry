"""Tailscale: this machine's address, `tailscale serve`, and the setup steps between Ferry and the owner's devices."""
import json
import os
import re
import shutil
import subprocess
import time
import urllib.parse
import urllib.request

from . import config


def tailscale_status():
    try:
        out = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=5).stdout
        return json.loads(out)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}


def origin(host):
    """A machine's origin where Ferry is published: https://<its tailnet name>, with no port when it is HTTPS's own."""
    return f"https://{host}{'' if config.HTTPS_PORT == 443 else f':{config.HTTPS_PORT}'}"


def url(st=None):
    """The page's address on the tailnet, or "" when Tailscale is off."""
    st = st or tailscale_status()
    name = ((st.get("Self") or {}).get("DNSName") or "").rstrip(".")
    if st.get("BackendState") != "Running" or not name:
        return ""
    return f"{origin(name)}{config.MOUNT}/"


def serving():
    """Whether tailscale serve publishes this server at MOUNT."""
    try:
        out = subprocess.run(["tailscale", "serve", "status", "--json"], capture_output=True, text=True, timeout=5).stdout
        cfg = json.loads(out or "{}")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False
    for host, web in (cfg.get("Web") or {}).items():
        h = (web.get("Handlers") or {}).get(config.MOUNT) or {}
        if host.endswith(f":{config.HTTPS_PORT}") and h.get("Proxy", "").rstrip("/").endswith(f"127.0.0.1:{config.PORT}"):
            return True
    return False


class Tailnet:
    """Who may use the page (this machine's owner) and the names of the devices asking, refreshed now and then."""
    def __init__(self):
        self.owner, self.names, self.when = "", {}, 0.0
        self.hosts = set()      # the owner's machines' tailnet names (this one too)
        self.me = ""            # this machine's tailnet name
        self.machines = []      # the owner's other machines that are online and could run Ferry: their tailnet names
        self.ids = set()        # the owner's other machines' short tailnet names, online or not
        self.phones = set()     # the owner's phones' and tablets' short tailnet names

    def load(self, force=False):
        if not force and time.monotonic() - self.when < 60:
            return
        st = tailscale_status()
        self.when = time.monotonic()
        users = st.get("User") or {}
        uid = (st.get("Self") or {}).get("UserID")
        self.owner = (users.get(str(uid)) or {}).get("LoginName", "") if uid is not None else ""
        me = st.get("Self") or {}
        self.me = (me.get("DNSName") or "").rstrip(".")
        self.hosts = {(p.get("DNSName") or "").rstrip(".") for p in list((st.get("Peer") or {}).values()) + [me]
                      if p.get("UserID") == uid and p.get("DNSName")}
        self.machines = [p["DNSName"].rstrip(".") for p in (st.get("Peer") or {}).values()
                         if p.get("UserID") == uid and p.get("Online") and p.get("DNSName")
                         and p.get("OS") not in ("iOS", "android")]
        self.ids = {p["DNSName"].split(".")[0] for p in (st.get("Peer") or {}).values()
                    if p.get("UserID") == uid and p.get("DNSName")}
        self.phones = {p["DNSName"].split(".")[0] for p in (st.get("Peer") or {}).values()
                       if p.get("UserID") == uid and p.get("DNSName") and p.get("OS") in ("iOS", "android")}
        names = {}
        for p in list((st.get("Peer") or {}).values()) + [me]:
            # The tailnet name: an iPhone's HostName is "localhost"
            name = (p.get("DNSName") or "").split(".")[0] or p.get("HostName") or ""
            for ip in p.get("TailscaleIPs") or []:
                names[ip] = name
        self.names = names

    def allowed(self, login):
        self.load()
        if login and login != self.owner:
            self.load(force=True)   # the owner may have just logged in
        return bool(login) and login == self.owner

    def for_me(self, host):
        """Whether a request's Host names this machine (tailscale serve passes the name the phone used)."""
        host = host.rsplit(":", 1)[0] if host.count(":") == 1 else host
        self.load()
        if host != self.me:
            self.load(force=True)
        return bool(host) and host == self.me

    def owners(self, url, path=""):
        """Whether url is exactly https://<one of the owner's machines> (on HTTPS_PORT, where Ferry is) followed by
        path: no other port, no user, no other path, so another web app on one of those machines isn't taken for
        Ferry. (One at another path of Ferry's own port is the same origin to a browser, which no check here can tell
        apart: docs/protocol.md › Network and trust.)"""
        try:
            host = urllib.parse.urlsplit(url).hostname or ""
        except ValueError:
            return False
        if url != origin(host) + path:
            return False
        self.load()
        if host not in self.hosts:
            self.load(force=True)
        return host in self.hosts

    def same_origin(self, origin):
        """Whether an Origin is a Ferry page on one of the owner's machines (CORS, Sec-Fetch-Site)."""
        return self.owners(origin)

    def same_base(self, url):
        """Whether url is the base URL of Ferry on one of the owner's machines (api/relay's via, api/relay-push's
        machine)."""
        return self.owners(url, config.MOUNT + "/")

    def device(self, ip):
        self.load()
        if ip not in self.names:
            self.load(force=True)
        return self.names.get(ip, "")


def systemctl(*a):
    return subprocess.run(["systemctl", "--user", *a], capture_output=True, text=True)


def status():
    """on, or off and why: enabled alone isn't on (a desktop may stop the unit and leave it enabled), the server has to
    be running too."""
    if systemctl("is-enabled", "-q", config.SERVICE).returncode:
        return "off"
    if systemctl("is-active", "-q", config.SERVICE).returncode:
        return "off (not running: ferry enable starts it)"
    return "on"


def serve(on):
    """Publishes the server on the tailnet (tailscale serve; kept across reboots by tailscaled), or stops that: "", or
    what Tailscale said when it refused (serve_message() for a terminal, publish_problem() for the window)."""
    args = [f"--https={config.HTTPS_PORT}", f"--set-path={config.MOUNT}"]
    cmd = ["tailscale", "serve", "--bg", *args, f"http://127.0.0.1:{config.PORT}"] if on else \
        ["tailscale", "serve", *args, "off"]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        return str(e)
    out = (res.stdout + res.stderr).strip()
    return "" if res.returncode == 0 else out or f"tailscale serve failed ({res.returncode})"


def needs_operator(out):
    return bool(re.search(r"denied|operator", out, re.I))


def serve_message(out):
    if needs_operator(out):
        return "Tailscale needs permission once: sudo tailscale set --operator=$USER, then: ferry enable"
    return out.splitlines()[-1] if out else ""


def setup_step(st, have_tailscale, running, served):
    """The first thing in the way, for the window and a desktop's menu (`ferry list --json`): None when nothing is,
    else {step, title, text} with what to do: a command to run, a link to open, an action the window can take itself
    ("enable", "tailscale-up", "publish", "operator"). Tailscale's own steps come first, since Ferry's need it.
    st is `tailscale status --json`'s ({} when tailscaled doesn't answer)."""
    state = st.get("BackendState")
    if not have_tailscale:
        return {"step": "tailscale-missing", "title": "Install Tailscale",
                "text": "Ferry sends between your devices over Tailscale. Install it, and log in with the same "
                        "account as your other devices.", "link": config.TAILSCALE_DOWNLOAD}
    if not st:
        return {"step": "tailscale-off", "title": "Start Tailscale",
                "text": "Tailscale is installed, but it isn't running. Start it, then log in:",
                "command": "sudo systemctl enable --now tailscaled"}
    if state == "NeedsLogin":
        s = {"step": "logged-out", "title": "Log in to Tailscale",
             "text": "Log in with the same account as your other devices.", "command": "sudo tailscale up"}
        if st.get("AuthURL"):
            s["link"] = st["AuthURL"]
        return s
    if state == "NeedsMachineAuth":
        return {"step": "needs-approval", "title": "Approve this computer",
                "text": "Your tailnet's admin approves new machines: approve this one in Tailscale's admin console.",
                "link": config.TAILSCALE_MACHINES}
    if state != "Running":
        return {"step": "tailscale-stopped", "title": "Turn on Tailscale",
                "text": "Tailscale is turned off on this computer, so your devices can't reach it.",
                "command": "tailscale up", "action": "tailscale-up"}
    if not running:
        return {"step": "stopped", "title": "Ferry is off on this computer",
                "text": "Your devices can't reach it until you turn it on.", "action": "enable"}
    if served:
        return None
    if not st.get("CertDomains"):
        return {"step": "https-off", "title": "Turn on HTTPS certificates",
                "text": "Ferry needs your tailnet's HTTPS certificates. Turn them on at the bottom of the DNS page in "
                        "Tailscale's admin console, then try again.", "link": config.TAILSCALE_DNS, "action": "publish"}
    return {"step": "not-published", "title": "Putting Ferry on your tailnet…",
            "text": "Ferry publishes itself with tailscale serve, for your devices only.", "action": "publish"}


def publish_problem(out, user=None):
    """Why tailscale serve refused, as a setup step: Tailscale's own words and the link it gave (e.g. to turn on Serve
    for the tailnet), or the operator right it needs to publish without sudo."""
    user = user or os.environ.get("USER") or ""
    if needs_operator(out):
        return {"step": "operator", "title": "Let Ferry publish on your tailnet",
                "text": "Tailscale lets only root publish unless it is told otherwise. Allow it once for this user:",
                "command": f"sudo tailscale set --operator={user}", "action": "operator"}
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    link = next((w for w in out.split() if w.startswith("https://")), "")
    s = {"step": "problem", "title": "Tailscale said no", "text": lines[0] if lines else "tailscale serve failed",
         "action": "publish"}
    if link:
        s["link"] = link
    return s


def publish():
    """Ferry on the tailnet: None, or the step that says why not."""
    out = serve(True)
    return publish_problem(out) if out else None


def setup(st=None):
    st = tailscale_status() if st is None else st
    have = bool(shutil.which("tailscale"))
    return setup_step(st, have, systemctl("is-active", "-q", config.SERVICE).returncode == 0, have and bool(st) and serving())
