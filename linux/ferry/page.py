"""The page (web/index.html) as it is served, and the Content-Security-Policy it is served with.

The policy's point is frame-ancestors 'none': another site could otherwise show the page in a frame in the owner's
browser, where the owner's own Tailscale identity lets it in, and trick a tap onto Clear or Send. The rest keeps the
page to what it does: its own script and style (inline, allowed by their hashes, worked out from the file so an edit
of it needs no edit here), its own files, and the API of the owner's other computers, which are on the tailnet's
MagicDNS names (docs/protocol.md › api/machines)."""
import base64
import hashlib
import os
import re

from . import config

OTHERS = "https://*.ts.net"   # the other computers' pages and API: tailscale serve's names are always the tailnet's
INLINE = re.compile(r"<(script|style)>(.*?)</\1>", re.S)


def html():
    """The page, with its base address in place."""
    with open(os.path.join(config.WEB, "index.html"), encoding="utf-8") as f:
        return f.read().replace("%BASE%", config.MOUNT + "/")


def digest(text):
    return "'sha256-" + base64.b64encode(hashlib.sha256(text.encode()).digest()).decode() + "'"


def policy(page):
    """The page's Content-Security-Policy: its inline <script> and <style> elements by their hashes."""
    found = {"script": [], "style": []}
    for tag, body in INLINE.findall(page):
        found[tag].append(digest(body))
    return "; ".join([
        "default-src 'none'",
        # 'self' too: a browser without worker-src takes the service worker's script from script-src
        "script-src 'self' " + " ".join(found["script"]),
        "style-src " + " ".join(found["style"] or ["'none'"]),
        f"img-src 'self' {OTHERS}",   # a picture's preview comes from the computer it is on
        "font-src 'self'",
        f"connect-src 'self' {OTHERS}",
        "manifest-src 'self'",
        "worker-src 'self'",
        "base-uri 'self'",
        "form-action 'none'",
        "frame-ancestors 'none'",
    ])


def headers(page):
    # X-Frame-Options for the browsers that don't know frame-ancestors
    return {"Content-Security-Policy": policy(page), "X-Frame-Options": "DENY"}
