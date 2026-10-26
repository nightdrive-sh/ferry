#!/usr/bin/env bash
# One machine's install test, run in it by tests/containers.sh, which says where things are:
#   RELEASE   the address the release is served at from the Mac (install.sh, ferry-linux.tar.gz)
#   FIXTURE   a folder with vapid.pem, a VAPID key as Nightdrive's plugin made it
#   TESTS     this folder
# The machine is fresh: this sets up what a Nightdrive computer had (Ferry's state from the plugin, its service
# running), installs Ferry as a user does, checks the result, goes through the API (tests/api.sh) and installs again.
set -euo pipefail

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
check() { printf '  ok: %s\n' "$*"; }
die() { printf '  FAILED: %s\n' "$*" >&2; exit 1; }
same() { [[ $(sha256sum < "$1") == $(sha256sum < "$2") ]]; }   # (Arch's base has no cmp)

XDG_RUNTIME_DIR=/run/user/$(id -u)
export XDG_RUNTIME_DIR
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
# shellcheck disable=SC1091
. /etc/os-release
step "$PRETTY_NAME"

# A user session for systemd --user (a desktop login has one; a machine shell doesn't)
sudo loginctl enable-linger "$USER"
for _ in $(seq 50); do systemctl --user show-environment >/dev/null 2>&1 && break; sleep 0.2; done
systemctl --user show-environment >/dev/null || die "no systemd user session"

# An Arch user keeps the system up to date; the image's package lists are old
if [[ " $ID ${ID_LIKE:-} " == *" arch "* ]]; then sudo pacman -Syu --noconfirm >/dev/null; fi   # archarm too

sudo install -m 755 "$TESTS/fake-tailscale" /usr/local/bin/tailscale
rm -f /tmp/fake-tailscale.log /tmp/fake-tailscale-serve.json /tmp/fake-tailscale-name

step "A Nightdrive computer's Ferry"
old=$HOME/.local/share/nightdrive/ferry
rm -rf "$old" "$HOME/.local/share/ferry" "$HOME/.local/lib/ferry"
mkdir -p "$old/files/a1b2c3d4e5f6" "$HOME/.config/systemd/user"
install -m 600 "$FIXTURE/vapid.pem" "$old/vapid.pem"
echo "Hello from Nightdrive" > "$old/files/a1b2c3d4e5f6/hello.txt"
now=$(date +%s)
cat > "$old/items.json" <<EOF
{"items": [{"id": "a1b2c3d4e5f6", "to": "phone", "kind": "file", "name": "hello.txt", "size": 22, "type": "text/plain",
            "path": "$old/files/a1b2c3d4e5f6/hello.txt", "for": "iphone", "time": $now},
           {"id": "0123456789ab", "to": "computer", "kind": "text", "text": "801566", "from": "iphone", "seen": true,
            "time": $now}]}
EOF
echo '[{"endpoint": "https://push.nightdrive.sh/push/abc", "keys": {"p256dh": "k", "auth": "a"}, "device": "iphone", "time": 1, "direct": true}]' > "$old/push.json"
echo '[{"id": "macbook", "name": "MacBook", "url": "https://macbook.tail0.ts.net/ferry/", "idle": 0, "seen": 1}]' > "$old/machines.json"
echo iphone > "$old/target"
# The plugin's service, which holds Ferry's port: it has to be off when the new one starts
cat > "$HOME/.config/systemd/user/nightdrive-ferry.service" <<'EOF'
[Service]
ExecStart=/bin/sleep infinity
[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now nightdrive-ferry.service 2>/dev/null
mkdir -p "$HOME/.local/bin"
ln -sfn /nonexistent/plugins/ferry/bin/ferry "$HOME/.local/bin/ferry"   # the plugin's link
check "state in $old, nightdrive-ferry.service $(systemctl --user is-active nightdrive-ferry.service)"

step "curl -fsSL …/install.sh | bash"
curl -fsSL "$RELEASE/install.sh" | FERRY_DOWNLOAD_URL="$RELEASE/ferry-linux.tar.gz" bash

step "Checks"
ferry=$HOME/.local/bin/ferry
[[ $(readlink "$ferry") == "$HOME/.local/lib/ferry/bin/ferry" ]] || die "ferry isn't linked to the install"
check "ferry $("$ferry" version) in ~/.local/lib/ferry"
systemctl --user is-active -q ferry.service || die "ferry.service isn't running"
systemctl --user is-enabled -q ferry.service || die "ferry.service isn't enabled"
check "ferry.service enabled and running"
! systemctl --user is-enabled -q nightdrive-ferry.service 2>/dev/null || die "the plugin's service is still enabled"
! systemctl --user is-active -q nightdrive-ferry.service || die "the plugin's service is still running"
check "nightdrive-ferry.service off"
[[ $("$ferry" status) == on ]] || die "ferry status: $("$ferry" status)"
check "ferry status: on"
grep -q -- "serve --bg --https=443 --set-path=/ferry http://127.0.0.1:47270" /tmp/fake-tailscale.log \
  || die "tailscale serve wasn't asked to publish Ferry"
check "published with tailscale serve at /ferry"

new=$HOME/.local/share/ferry
[[ ! -e $old && -d $new ]] || die "the state wasn't moved to $new"
[[ $(stat -c %a "$new") == 700 ]] || die "$new isn't private"
same "$FIXTURE/vapid.pem" "$new/vapid.pem" || die "the VAPID key changed"
grep -q push.nightdrive.sh/push/abc "$new/push.json" || die "the subscriptions didn't come along"
grep -q macbook "$new/machines.json" || die "the known computers didn't come along"
check "state moved to $new: VAPID key, subscriptions, computers"

ask() {   # what tailscale serve passes on from the owner's iPhone
  curl -sS -H "Host: ferry-test.tail0.ts.net" -H "Tailscale-User-Login: tester@example.com" -H "X-Ferry: 1" \
    -H "X-Forwarded-For: 100.64.0.2" "$@"
}
for _ in $(seq 50); do ask -o /dev/null http://127.0.0.1:47270/api/ping 2>/dev/null && break; sleep 0.2; done
items=$(ask -f http://127.0.0.1:47270/api/items) || die "api/items didn't answer"
echo "  api/items: $items"
python3 - "$items" "$new/vapid.pem" <<'EOF' || die "api/items isn't what the old state had"
import base64, json, sys
from cryptography.hazmat.primitives import serialization
answer = json.loads(sys.argv[1])
key = serialization.load_pem_private_key(open(sys.argv[2], "rb").read(), None)
point = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
assert answer["push"] == base64.urlsafe_b64encode(point).rstrip(b"=").decode(), "push isn't the old VAPID key's"
assert sorted(i["id"] for i in answer["items"]) == ["0123456789ab", "a1b2c3d4e5f6"], answer["items"]
assert answer["keep"] == 7 and "computer" in answer, answer
EOF
check "api/items answers with the old box and the old VAPID key"
[[ $(ask -f http://127.0.0.1:47270/api/file/a1b2c3d4e5f6) == "Hello from Nightdrive" ]] || die "api/file didn't serve the file"
check "api/file serves the file left for the phone"
ask -f http://127.0.0.1:47270/ | grep -q '<title>Ferry' || die "the page isn't served"
[[ $(ask -f http://127.0.0.1:47270/font/JetBrainsMono-Regular.ttf 2>/dev/null | head -c 4 | od -An -tx1 | tr -d ' ') == 00010000 ]] \
  || die "the page's font isn't served"
check "the page and its font"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ferry-test.tail0.ts.net" -H "Tailscale-User-Login: someone@else.com" \
  -H "X-Ferry: 1" http://127.0.0.1:47270/api/items)
[[ $code == 403 ]] || die "someone else's request got $code"
check "someone else gets 403"
"$ferry" list | grep -q hello.txt || die "ferry list doesn't show the box"
check "ferry list shows the box"

bash "$TESTS/api.sh"

step "Installing again (an update)"
pid=$(systemctl --user show -p MainPID --value ferry.service)
curl -fsSL "$RELEASE/install.sh" | FERRY_DOWNLOAD_URL="$RELEASE/ferry-linux.tar.gz" bash -s -- --no-packages >/dev/null
systemctl --user is-active -q ferry.service || die "ferry.service isn't running after the update"
[[ $(systemctl --user show -p MainPID --value ferry.service) != "$pid" ]] || die "the update didn't restart the server"
same "$FIXTURE/vapid.pem" "$new/vapid.pem" || die "the update changed the VAPID key"
for _ in $(seq 50); do ask -o /dev/null http://127.0.0.1:47270/api/ping 2>/dev/null && break; sleep 0.2; done
ask -f -o /dev/null http://127.0.0.1:47270/api/items || die "api/items didn't answer after the update"
check "restarted with the same state, api/items answers"

printf '\n\033[1mPASS: %s\033[0m\n' "$PRETTY_NAME"
