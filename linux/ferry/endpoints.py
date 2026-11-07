"""Where a push subscription may point: the push services browsers subscribe with, and Ferry's relay.

An api/subscribe's endpoint is where this computer later POSTs, so any https address would let whatever can subscribe
here have the computer post to an address of its choosing, one on its own network included (docs/protocol.md ›
Notifications). Only these hosts are taken, on https's own port, and a push service's redirect is not followed: a
service answers a push itself, so a redirect is no service's answer."""
import os
import urllib.parse
import urllib.request

# A host, or with a leading dot every host under that domain (Firefox's and Edge's endpoints are on numbered hosts).
SERVICES = (
    "push.nightdrive.sh",            # Ferry's relay: the iPhone app's subscriptions (relay/README.md)
    "web.push.apple.com",            # Safari, and a page added to an iPhone's Home Screen
    "fcm.googleapis.com",            # Chrome, Android's browsers
    "android.googleapis.com",        # Chrome's older endpoints, still answered
    ".push.services.mozilla.com",    # Firefox (updates.push.services.mozilla.com)
    ".notify.windows.com",           # Edge (wns2-….notify.windows.com)
)
EXTRA = "FERRY_PUSH_HOSTS"   # more hosts, comma-separated, as above: a relay of one's own to test the app against


def hosts():
    extra = [h.strip().lower() for h in os.environ.get(EXTRA, "").split(",") if h.strip()]
    return SERVICES + tuple(extra)


def allowed(endpoint):
    """Whether endpoint is a push service's address this computer will post to."""
    try:
        u = urllib.parse.urlsplit(str(endpoint))
        port = u.port
    except ValueError:   # a port that isn't a number
        return False
    host = (u.hostname or "").lower()
    if u.scheme != "https" or not host or u.username is not None or port not in (None, 443):
        return False
    return any(host == h or (h.startswith(".") and host.endswith(h)) for h in hosts())


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None   # urllib then raises the 3xx as an HTTPError


_opener = urllib.request.build_opener(_NoRedirect)


def post(req, timeout):
    """urlopen(req) without following a redirect."""
    return _opener.open(req, timeout=timeout)
