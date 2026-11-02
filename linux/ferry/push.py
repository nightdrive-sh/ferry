"""Web Push (RFC 8030 / 8291 / 8292) to the phones, directly or through the computer a phone subscribed on.

A phone's push subscription belongs to the computer it added the page from, so the others ask that one to pass their
notifications on (api/relay, api/relay-push). The VAPID key is made on the first run (python3-cryptography)."""
import base64
import hashlib
import hmac
import json
import os
import struct
import sys
import threading
import time
import urllib.parse
import urllib.request

from . import config, forget, store, tailnet


# python3-cryptography does the elliptic curves and AES-GCM; the rest (aes128gcm framing, VAPID's JWT) is small enough to
# write here. Fedora has no pywebpush. Without the module everything else still works, only without notifications.
def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def vapid_key(create=False):
    """The VAPID key (P-256), made on the first run; None without python3-cryptography."""
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec
    except ImportError:
        return None
    path = os.path.join(config.STATE, "vapid.pem")
    if not os.path.exists(path):
        if not create:
            return None
        os.makedirs(config.STATE, mode=0o700, exist_ok=True)
        pem = ec.generate_private_key(ec.SECP256R1()).private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(pem)
    with open(path, "rb") as f:
        return serialization.load_pem_private_key(f.read(), None)


def point(key):
    from cryptography.hazmat.primitives import serialization
    return key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def hkdf(salt, ikm, info, n):
    """HKDF-SHA256 with one output block, which is all Web Push needs."""
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()[:n]


def encrypt(payload, p256dh, auth):
    """The push message encrypted for one subscription (RFC 8291, aes128gcm with a single record)."""
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    ua_pub, secret = unb64u(p256dh), unb64u(auth)
    ua = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), ua_pub)
    eph = ec.generate_private_key(ec.SECP256R1())
    as_pub = point(eph)
    ikm = hkdf(secret, eph.exchange(ec.ECDH(), ua), b"WebPush: info\x00" + ua_pub + as_pub, 32)
    salt = os.urandom(16)
    cek = hkdf(salt, ikm, b"Content-Encoding: aes128gcm\x00", 16)
    nonce = hkdf(salt, ikm, b"Content-Encoding: nonce\x00", 12)
    body = AESGCM(cek).encrypt(nonce, payload + b"\x02", None)   # \x02: the last (only) record's padding delimiter
    return salt + struct.pack("!IB", 4096, len(as_pub)) + as_pub + body


def vapid_auth(key, endpoint):
    """The Authorization header: a JWT signed with the VAPID key for the push service's origin (RFC 8292)."""
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    u = urllib.parse.urlsplit(endpoint)
    head = b64u(json.dumps({"typ": "JWT", "alg": "ES256"}).encode())
    claims = b64u(json.dumps({"aud": f"{u.scheme}://{u.netloc}", "exp": int(time.time()) + 3600,
                              "sub": config.PUSH_CONTACT}).encode())
    signing = f"{head}.{claims}".encode()
    r, s = decode_dss_signature(key.sign(signing, ec.ECDSA(hashes.SHA256())))
    jwt = signing.decode() + "." + b64u(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
    return f"vapid t={jwt}, k={b64u(point(key))}"


def subscriptions(change=None):
    """The phone's push subscriptions; change(list) edits them under the box's lock."""
    path = os.path.join(config.STATE, "push.json")
    with store.box(write=change is not None):
        try:
            with open(path) as f:
                subs = json.load(f)
        except (OSError, ValueError):
            subs = []
        if change:
            change(subs)
            tmp = path + ".tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(subs, f)
            os.replace(tmp, path)
        return subs


def relays(change=None):
    """The computers whose pages the phone was added from (their addresses): they pass this one's notifications on."""
    path = os.path.join(config.STATE, "relays.json")
    with store.box(write=change is not None):
        try:
            with open(path) as f:
                out = json.load(f)
        except (OSError, ValueError):
            out = []
        if change:
            change(out)
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(out, f)
            os.replace(tmp, path)
        return out


def subscribe(entry):
    """Keeps an api/subscribe's subscription: the same endpoint again replaces it, and a direct one (the app's) the
    same device's earlier direct ones, so an app installed again doesn't leave its old address getting every
    notification. A forgotten device's isn't kept. Always True: the device is answered 200 either way."""
    if entry["device"] in forget.forgotten_ids():
        return True
    named = entry["device"] != "your phone"   # one the computer can't name could be anyone's

    def change(s):
        s[:] = [x for x in s if x["endpoint"] != entry["endpoint"] and not (
            named and entry.get("direct") and x.get("direct") and x.get("device") == entry["device"])] + [entry]
    subscriptions(change)
    # Forgotten meanwhile (the check above and the write are apart): the forget's own drop may have come first
    if entry["device"] in forget.forgotten_ids():
        forget.drop_subscriptions({entry["device"]})
    return True


def payload(title, body, machine="", item=None):
    """A notification's content: what the page's service worker shows, and for the iPhone app also the item, so a tap
    opens it and copies a text. The whole text goes along when it fits, never a cut one (the app fetches a long one);
    title and body are cut by characters, so the JSON and its UTF-8 stay whole."""
    d = {"title": title[:200], "body": body[:300], "machine": machine}
    if item:
        d.update(id=item["id"], kind=item["kind"])
        if store.secret(item):   # the lock screen shows the body; the text goes along for a tap to copy
            d.update(body=config.SECRET_HIDDEN, secret=True)
    out = json.dumps(d, ensure_ascii=False).encode()
    if item and item["kind"] == "text":
        whole = json.dumps(dict(d, text=item.get("text", "")), ensure_ascii=False).encode()
        if len(whole) <= config.PUSH_PAYLOAD:
            return whole
    while len(out) > config.PUSH_PAYLOAD and (d["title"] or d["body"]):   # only absurdly long names get here
        d["body"] = d["body"][:len(d["body"]) // 2]
        d["title"] = d["title"][:len(d["title"]) // 2]
        out = json.dumps(d, ensure_ascii=False).encode()
    if len(out) > config.PUSH_PAYLOAD:   # a machine address no computer has (api/relay-push takes it from the request)
        d["machine"] = ""
        out = json.dumps(d, ensure_ascii=False).encode()
    return out


def targets(subs, relayed):
    """The subscriptions a notification goes to. The iPhone app subscribes "direct" on every computer: it hears about each
    computer's own items from that computer, so one passed on by another computer (relayed, api/relay-push) isn't for
    it, and the same phone's PWA subscription stays quiet beside it. A device named "your phone" (its tailnet name
    unknown) could be anyone's, so it replaces nothing."""
    direct = {s.get("device") for s in subs if s.get("direct") and s.get("device") != "your phone"}
    return [s for s in subs if not (relayed and s.get("direct")) and (s.get("direct") or s.get("device") not in direct)]


def recipients(subs, relayed, device=""):
    """targets(), and of those only the named phone's when a send is for one device."""
    return [s for s in targets(subs, relayed) if not device or s.get("device") == device]


def subscription(sub, device):
    """The stored form of an api/subscribe body, or None when it isn't a push subscription."""
    if not (isinstance(sub, dict) and str(sub.get("endpoint", "")).startswith("https://") and
            (sub.get("keys") or {}).get("p256dh") and (sub.get("keys") or {}).get("auth")):
        return None
    entry = {"endpoint": sub["endpoint"], "keys": {"p256dh": sub["keys"]["p256dh"], "auth": sub["keys"]["auth"]},
             "device": device, "time": time.time()}
    if sub.get("direct") is True:
        entry["direct"] = True
    return entry


def push_all(title, body, machine="", item=None, device=""):
    """A notification on every subscribed phone, and through the relays on the phones that added another computer's
    page. machine: the address of the computer it is about ("" = this one), so a tap opens the page on it. item: the
    item it is about. device: only that phone (its tailnet name), "" for all. A subscription the push service no longer
    knows (404/410) goes."""
    if item and store.secret(item):   # a page shows the body as it is, also one this goes to through a relay
        body = config.SECRET_HIDDEN
    if not machine:
        own = tailnet.url()
        for via in relays():
            if via != own:
                threading.Thread(target=relay_push, args=(via, title, body, own, device), daemon=True).start()
    key = vapid_key()
    subs = recipients(subscriptions(), bool(machine), device) if key else []
    gone = []
    content = payload(title, body, machine, item)
    for sub in subs:
        try:
            data = encrypt(content, sub["keys"]["p256dh"], sub["keys"]["auth"])
            req = urllib.request.Request(sub["endpoint"], data, method="POST", headers={
                "Authorization": vapid_auth(key, sub["endpoint"]), "TTL": str(config.KEEP_DAYS * 86400),
                "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream", "Urgency": "high"})
            urllib.request.urlopen(req, timeout=10).read()
        except urllib.error.HTTPError as e:
            print(f"push to {urllib.parse.urlsplit(sub['endpoint']).netloc}: {e.code} {e.read()[:200]!r}",
                  file=sys.stderr)
            if e.code in (404, 410):
                gone.append(sub["endpoint"])
        except (OSError, KeyError, ValueError) as e:
            print(f"push failed: {e!r}", file=sys.stderr)
    if gone:
        subscriptions(lambda s: s.__setitem__(slice(None), [x for x in s if x["endpoint"] not in gone]))
    for t in threading.enumerate():   # a command waits for its relays before it exits
        if t.name == "relay":
            t.join(10)


def relay_push(via, title, body, own, device=""):
    """Asks the computer at via to notify its phones (or the one named device) about this one (through Tailscale: it
    knows who asks)."""
    threading.current_thread().name = "relay"
    data = json.dumps({"title": title, "body": body, "machine": own, "device": device}, ensure_ascii=False).encode()
    req = urllib.request.Request(via + "api/relay-push", data, method="POST",
                                 headers={"X-Ferry": "1", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except (OSError, ValueError) as e:
        print(f"relay through {via} failed: {e!r}", file=sys.stderr)
