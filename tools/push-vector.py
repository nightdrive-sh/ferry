#!/usr/bin/env python3
"""Writes FerryKit's push test vector: a message encrypted by bin/ferry's own encrypt(), so the app is tested against
what a computer really sends, not against a second implementation of RFC 8291.

    uv run --with cryptography python3 tools/push-vector.py > FerryKit/Tests/FerryKitTests/Fixtures/push-vector.json
"""
import base64
import importlib.machinery
import json
import os
import sys

from cryptography.hazmat.primitives.asymmetric import ec

FERRY = os.path.expanduser(os.environ.get("FERRY_BIN") or
                           os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "linux", "bin", "ferry"))


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def main():
    ferry = importlib.machinery.SourceFileLoader("ferry", FERRY).load_module()   # main() is guarded by __name__
    key = ec.generate_private_key(ec.SECP256R1())
    auth = os.urandom(16)
    p256dh = b64u(ferry.point(key))
    plaintext = json.dumps({"title": "Nightdrive", "body": "801566", "machine": "", "id": "a1b2c3d4e5f6",
                            "kind": "text", "text": "801566 ä"}, ensure_ascii=False)
    body = ferry.encrypt(plaintext.encode(), p256dh, b64u(auth))
    json.dump({"privateKey": b64u(key.private_numbers().private_value.to_bytes(32, "big")), "auth": b64u(auth),
               "p256dh": p256dh, "plaintext": plaintext, "body": b64u(body)}, sys.stdout, ensure_ascii=False, indent=1)
    print()


if __name__ == "__main__":
    main()
