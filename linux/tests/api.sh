#!/usr/bin/env bash
# Every call in docs/protocol.md, with curl, against the server ferry.service runs: tests/in-container.sh runs this
# after the install, as the machine's user. tests/fake-tailscale is Tailscale: the owner tester@example.com on
# ferry-test.tail0.ts.net, asking from the iPhone (100.64.0.2); the iPad, the MacBook (asleep) and someone else's
# computer are on the tailnet too.
set -euo pipefail

B=http://127.0.0.1:47270
HOST=ferry-test.tail0.ts.net
STATE=$HOME/.local/share/ferry
DOWNLOADS=$HOME/Downloads
ferry=$HOME/.local/bin/ferry

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
check() { printf '  ok: %s\n' "$*"; }
die() { printf '  FAILED: %s\n' "$*" >&2; exit 1; }

# What tailscale serve passes on from the owner's iPhone; raw() is the same without any of it
at() {   # at HOST …: the same, naming another host (curl sends the first of two Host headers)
  local host=$1
  shift
  curl -sS --max-time 20 -H "Host: $host" -H "Tailscale-User-Login: tester@example.com" -H "X-Ferry: 1" \
    -H "X-Forwarded-For: 100.64.0.2" "$@"
}
ask() { at "$HOST" "$@"; }
raw() { curl -sS --max-time 20 "$@"; }
code() { "$@" -o /dev/null -w '%{http_code}'; }   # code ask … : the status alone
headers() { "$@" -o /dev/null -D - | tr -d '\r'; }  # headers ask … : the answer's headers
expect() {   # expect WANT WHAT CMD…: the status CMD gets
  local want=$1 what=$2 got
  shift 2
  got=$(code "$@") || true
  [[ $got == "$want" ]] || die "$what: $got, not $want"
  check "$what: $want"
}
# json EXPR: a Python expression over the JSON on stdin (d), which must be true
json() { python3 -c "import json, sys; d = json.load(sys.stdin); sys.exit(0 if ($1) else 1)" || die "${2:-$1}"; }
items() { ask -f "$B/api/items"; }
item_id() {   # item_id EXPR: the id of the first item in api/items that matches (i)
  items | python3 -c "import json, sys; print(next(i['id'] for i in json.load(sys.stdin)['items'] if ($1)))"
}
sha() { sha256sum < "$1" | cut -d' ' -f1; }

# It empties Downloads and the box: only in a test machine
grep -q "fake tailscale" "$(command -v tailscale)" 2>/dev/null || die "not a test machine (no tests/fake-tailscale)"
rm -rf "$DOWNLOADS"
mkdir -p "$DOWNLOADS"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

step "API: who may ask"
# Subscriptions of the moved state are the old relay's: notifications to them would leave the machine
for e in $(python3 -c "import json; print(' '.join(s['endpoint'] for s in json.load(open('$STATE/push.json'))))"); do
  ask -f -o /dev/null -H "Content-Type: application/json" -d "{\"endpoint\": \"$e\"}" "$B/api/unsubscribe"
done
[[ $(cat "$STATE/push.json") == "[]" ]] || die "api/unsubscribe left $(cat "$STATE/push.json")"
check "api/unsubscribe took the moved subscriptions out"
expect 200 "the owner" ask "$B/api/ping"
expect 403 "no Tailscale login" raw -H "Host: $HOST" -H "X-Ferry: 1" "$B/api/ping"
expect 403 "someone else's login" raw -H "Host: $HOST" -H "Tailscale-User-Login: someone@else.com" -H "X-Ferry: 1" "$B/api/ping"
expect 403 "a Host that isn't this computer" at localhost "$B/api/ping"
expect 403 "a Host that is another of the owner's computers" at macbook.tail0.ts.net "$B/api/ping"
expect 403 "no X-Ferry" raw -H "Host: $HOST" -H "Tailscale-User-Login: tester@example.com" "$B/api/items"
expect 403 "no X-Ferry, POST" raw -H "Host: $HOST" -H "Tailscale-User-Login: tester@example.com" \
  -H "Content-Type: application/json" -d '{"text": "x"}' "$B/api/text"
expect 200 "Host with the port" at "$HOST:443" "$B/api/ping"
expect 200 "Sec-Fetch-Site: same-origin" ask -H "Sec-Fetch-Site: same-origin" "$B/api/ping"
expect 200 "Sec-Fetch-Site: none" ask -H "Sec-Fetch-Site: none" "$B/api/ping"
expect 403 "another site's page" ask -H "Sec-Fetch-Site: cross-site" "$B/api/ping"
expect 403 "another site's page with its Origin" ask -H "Sec-Fetch-Site: cross-site" -H "Origin: https://evil.example" "$B/api/ping"
expect 403 "someone else's computer's page" ask -H "Sec-Fetch-Site: same-site" -H "Origin: https://other.tail0.ts.net" "$B/api/ping"
expect 404 "an unknown call" ask "$B/api/nothing"
expect 404 "an unknown POST" ask -X POST "$B/api/nothing"

step "API: CORS for the owner's other computers"
mac=https://macbook.tail0.ts.net
h=$(headers ask -H "Sec-Fetch-Site: same-site" -H "Origin: $mac" "$B/api/ping")
grep -q "^HTTP/1.1 200" <<<"$h" || die "the MacBook's page: $(head -1 <<<"$h")"
grep -qi "^Access-Control-Allow-Origin: $mac$" <<<"$h" || die "no Access-Control-Allow-Origin for the MacBook: $h"
grep -qi "^Vary: Origin$" <<<"$h" || die "no Vary: Origin"
check "the MacBook's page gets its origin back, and Vary: Origin"
h=$(headers ask -X OPTIONS -H "Origin: $mac" -H "Access-Control-Request-Method: POST" "$B/api/text")
grep -q "^HTTP/1.1 204" <<<"$h" || die "preflight: $(head -1 <<<"$h")"
grep -qi "^Access-Control-Allow-Methods: GET, POST$" <<<"$h" || die "preflight methods: $h"
grep -qi "^Access-Control-Allow-Headers: X-Ferry, Content-Type$" <<<"$h" || die "preflight headers: $h"
grep -qi "^Access-Control-Max-Age: 600$" <<<"$h" || die "preflight max age: $h"
grep -qi "^Access-Control-Allow-Origin: $mac$" <<<"$h" || die "preflight origin: $h"
check "a preflight from the MacBook's page: 204, methods, headers, max age"
expect 403 "a preflight from another site" ask -X OPTIONS -H "Origin: https://evil.example" "$B/api/text"
expect 403 "a preflight from someone else's computer" ask -X OPTIONS -H "Origin: https://other.tail0.ts.net" "$B/api/text"
expect 403 "a preflight over http" ask -X OPTIONS -H "Origin: http://macbook.tail0.ts.net" "$B/api/text"
expect 403 "a preflight by someone else" raw -X OPTIONS -H "Host: $HOST" -H "Tailscale-User-Login: someone@else.com" \
  -H "Origin: $mac" "$B/api/text"
h=$(headers ask -H "Origin: https://evil.example" "$B/api/ping")
! grep -qi "^Access-Control-Allow-Origin" <<<"$h" || die "another site got Access-Control-Allow-Origin"
check "another site's origin isn't echoed"

step "API: ping, items, machines"
ask -f "$B/api/ping" | json 'isinstance(d["computer"], str) and d["computer"] and "idle" in d and \
  (d["idle"] is None or isinstance(d["idle"], int)) and d["forgotten"] == []' "api/ping: computer, idle, forgotten"
check "api/ping: $(ask -f "$B/api/ping")"
items | json 'd["keep"] == 7 and isinstance(d["push"], str) and len(d["push"]) == 87 and isinstance(d["items"], list) \
  and isinstance(d["computer"], str) and "idle" in d' "api/items: keep 7 and a VAPID key"
check "api/items: keep 7, push a P-256 key"
ask -f "$B/api/machines" | json 'd["machines"] == [{"url": "https://'$HOST'/ferry/", "name": d["machines"][0]["name"], \
  "self": True}] and d["push"] == '"\"$(items | python3 -c 'import json,sys; print(json.load(sys.stdin)["push"])')\"" \
  "api/machines: only this computer (the MacBook is asleep), at its tailnet address"
check "api/machines: this computer alone, its address and key"

step "API: texts from the phone"
ask -f -H "Content-Type: application/json" -d '{"text": "801566", "clip": true}' "$B/api/text" | json 'd == {"ok": True}'
ask -f -H "Content-Type: application/json" -d '{"text": "Hei ä ö 🚢\nline two"}' "$B/api/text" >/dev/null
items | json 'any(i["kind"] == "text" and i["text"] == "Hei ä ö 🚢\nline two" and i["to"] == "computer" and \
  i["from"] == "iphone" and i["seen"] is False and len(i["id"]) == 12 and isinstance(i["time"], float) \
  for i in d["items"])' "a text from the phone isn't in api/items as sent"
check "api/text: in the box, from the iPhone, not seen, UTF-8 whole"
expect 400 "an empty text" ask -H "Content-Type: application/json" -d '{"text": "  \n"}' "$B/api/text"
expect 400 "no text" ask -H "Content-Type: application/json" -d '{}' "$B/api/text"
expect 400 "not JSON" ask -H "Content-Type: application/json" -d 'hello' "$B/api/text"
python3 -c 'import json; print(json.dumps({"text": "x" * (1 << 20) + "tail"}))' > "$work/long.json"
ask -f -H "Content-Type: application/json" --data-binary "@$work/long.json" "$B/api/text" >/dev/null
items | json 'any(i.get("text", "").startswith("xxx") and len(i["text"]) == 1 << 20 for i in d["items"])' \
  "a text over 1 MiB isn't cut to 1 MiB"
check "api/text: over 1 MiB is cut to 1 MiB"
ask -f -o /dev/null -X POST "$B/api/remove?id=$(item_id 'i.get("text", "").startswith("xxx")')"

step "API: files from the phone"
head -c 300000 /dev/urandom > "$work/photo.jpg"
name='Lasku & kuitti #2 + 50%.jpg'
enc=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$name")
ask -f -H "Content-Type: application/octet-stream" --data-binary "@$work/photo.jpg" \
  "$B/api/upload?name=$enc&type=image%2Fjpeg" | json "d == {'ok': True, 'name': '''$name'''}" "api/upload's answer"
[[ $(sha "$DOWNLOADS/$name") == $(sha "$work/photo.jpg") ]] || die "the upload isn't in Downloads whole"
check "api/upload: $name in Downloads, whole"
ask -f -H "Content-Type: application/octet-stream" --data-binary "@$work/photo.jpg" \
  "$B/api/upload?name=$enc&type=image%2Fjpeg" | json "d['name'] == 'Lasku & kuitti #2 + 50% (2).jpg'" "a second upload's name"
check "api/upload: the same name again is made unique"
id=$(item_id "i.get('name') == '''$name'''")
items | json "any(i['id'] == '$id' and i['to'] == 'computer' and i['kind'] == 'file' and i['size'] == 300000 and \
  i['type'] == 'image/jpeg' and i['from'] == 'iphone' and 'path' not in i for i in d['items'])" "the upload's item"
check "the upload's item: size, type, from the iPhone, no path"
ask -f -H "Transfer-Encoding: chunked" -H "Content-Type: application/octet-stream" --data-binary "@$work/photo.jpg" \
  "$B/api/upload?name=chunked.bin&type=application%2Foctet-stream" | json 'd["name"] == "chunked.bin"'
[[ $(sha "$DOWNLOADS/chunked.bin") == $(sha "$work/photo.jpg") ]] || die "a chunked upload isn't whole"
check "api/upload: chunked"
ask -f --data-binary "evil" "$B/api/upload?name=..%2F..%2F.bashrc" | json 'd["name"] == "bashrc"' \
  "a name with a path isn't made safe"
[[ -f "$DOWNLOADS/bashrc" ]] || die "the safe name isn't in Downloads"
check "api/upload: ../../.bashrc is saved as bashrc in Downloads"
ask -f --data-binary "x" "$B/api/upload" | json 'd["name"] == "file"' "no name"
check "api/upload: no name is saved as file"
printf 'PNG' > "$work/shot.png"
ask -f --data-binary "@$work/shot.png" "$B/api/upload?name=shot.png&type=image%2Fpng&clip=1" | json 'd["ok"]'
check "api/upload: clip=1 with an image (no clipboard here: kept in Downloads)"
expect 413 "over 4 GiB" ask -H "Content-Length: $(( (4 << 30) + 1 ))" -H "Content-Type: application/octet-stream" \
  -X POST "$B/api/upload?name=big.bin"
[[ ! -e "$DOWNLOADS/big.bin" ]] || die "the refused upload left a file"
expect 200 "api/ping on a new connection after the refused upload" ask "$B/api/ping"

step "API: files and texts left for the phone"
printf 'Hello from Linux\n' > "$work/note.txt"
printf '<script>alert(1)</script>' > "$work/page.html"
printf 'only the iPad' > "$work/ipad.txt"
cp "$work/photo.jpg" "$work/Kuva ä #1.jpg"
ask -f -o /dev/null -X POST "$B/api/clear?to=phone"   # hello.txt, from the moved state, has been checked
# A phone is on the device list once it has used Ferry here: the iPhone has, the iPad not yet
ipad() { curl -sS --max-time 20 -H "Host: $HOST" -H "Tailscale-User-Login: tester@example.com" -H "X-Ferry: 1" \
  -H "X-Forwarded-For: 100.64.0.3" "$@"; }
[[ $("$ferry" devices) == *iphone* && $("$ferry" devices) != *ipad* ]] || die "ferry devices before the iPad's call: $("$ferry" devices)"
ipad -f -o /dev/null "$B/api/ping"
[[ $("$ferry" devices) == *ipad* ]] || die "the iPad isn't listed after its call: $("$ferry" devices)"
json 'sorted(d) == ["ipad", "iphone"]' "phones.json: $(cat "$STATE/phones.json")" < "$STATE/phones.json"
check "ferry devices: a phone is listed once it has made a call (phones.json)"
"$ferry" send --to iphone "$work/note.txt" >/dev/null
"$ferry" send --to iphone "$work/page.html" >/dev/null
"$ferry" send --to iphone "$work/Kuva ä #1.jpg" >/dev/null
"$ferry" send --to iphone "for the iPhone" >/dev/null
"$ferry" send --to ipad "$work/ipad.txt" >/dev/null
"$ferry" send --to ipad "for the iPad" >/dev/null
items | json 'not any(i.get("for") == "ipad" or i.get("text") == "for the iPad" or i.get("name") == "ipad.txt" \
  for i in d["items"])' "the iPhone sees what was left for the iPad"
items | json 'sum(i["to"] == "phone" for i in d["items"]) == 4 and \
  all("from" not in i and i["for"] == "iphone" for i in d["items"] if i["to"] == "phone")' "what was left for the iPhone"
check "api/items: the iPhone sees what was left for it (for: iphone, no from), not the iPad's"
ipad=$(ipad "$B/api/items")
python3 -c 'import json, sys; d = json.loads(sys.argv[1]); assert sorted(i.get("name") or i.get("text") \
  for i in d["items"] if i["to"] == "phone") == ["for the iPad", "ipad.txt"], d' "$ipad" || die "the iPad's items"
check "api/items: the iPad sees its own two"

note=$(item_id 'i.get("name") == "note.txt"')
h=$(headers ask "$B/api/file/$note")
grep -q "^HTTP/1.1 200" <<<"$h" && grep -qi "^Content-Type: text/plain$" <<<"$h" \
  && grep -qi "^Content-Disposition: inline; filename\*=UTF-8''note.txt$" <<<"$h" \
  && grep -qi "^Content-Length: 17$" <<<"$h" && grep -qi "^X-Content-Type-Options: nosniff$" <<<"$h" \
  || die "api/file of a text file: $h"
[[ $(ask -f "$B/api/file/$note") == "Hello from Linux" ]] || die "api/file's bytes"
check "api/file: a text file inline as text/plain, its name, its bytes"
h=$(headers raw -H "Host: $HOST" -H "Tailscale-User-Login: tester@example.com" "$B/api/file/$note")
grep -q "^HTTP/1.1 200" <<<"$h" || die "api/file without X-Ferry: $(head -1 <<<"$h")"
check "api/file needs no X-Ferry"
expect 403 "api/file for someone else" raw -H "Host: $HOST" -H "Tailscale-User-Login: someone@else.com" "$B/api/file/$note"
h=$(headers ask "$B/api/file/$note?download=1")
grep -qi "^Content-Disposition: attachment; filename\*=UTF-8''note.txt$" <<<"$h" || die "?download=1: $h"
check "api/file?download=1: an attachment"
h=$(headers ask "$B/api/file/$(item_id 'i.get("name") == "page.html"')")
grep -qi "^Content-Type: application/octet-stream$" <<<"$h" && grep -qi "^Content-Disposition: attachment" <<<"$h" \
  || die "an HTML file: $h"
check "api/file: an HTML file is application/octet-stream, an attachment"
pic=$(item_id 'i.get("name") == "Kuva ä #1.jpg"')
h=$(headers ask "$B/api/file/$pic")
grep -qi "^Content-Type: image/jpeg$" <<<"$h" \
  && grep -qi "^Content-Disposition: inline; filename\*=UTF-8''Kuva%20%C3%A4%20%231.jpg$" <<<"$h" || die "an image: $h"
[[ $(ask -f "$B/api/file/$pic" | sha256sum | cut -d' ' -f1) == $(sha "$work/photo.jpg") ]] || die "the image's bytes"
check "api/file: an image inline as image/jpeg, its name percent-encoded, its bytes"
h=$(headers ask -I "$B/api/file/$pic")
grep -qi "^Content-Length: 300000$" <<<"$h" || die "HEAD api/file: $h"
check "HEAD api/file: the length, no body"
upload=$(item_id "i.get('name') == '''$name'''")
[[ $(ask -f "$B/api/file/$upload" | sha256sum | cut -d' ' -f1) == $(sha "$work/photo.jpg") ]] \
  || die "api/file of a file from the phone"
check "api/file: a file from the phone too"
expect 404 "api/file of an unknown id" ask "$B/api/file/000000000000"
expect 404 "api/file of a text" ask "$B/api/file/$(item_id 'i.get("text") == "for the iPhone"')"
gone=$(item_id 'i.get("name") == "page.html"')
rm -f "$STATE/files/$gone/page.html"
expect 404 "api/file of a file that's gone" ask "$B/api/file/$gone"
items | json "'$gone' not in [i['id'] for i in d['items']]" "an item whose file is gone is still listed"
check "an item whose file is gone leaves api/items"

step "API: remove and clear"
expect 200 "api/remove of an unknown id" ask -X POST "$B/api/remove?id=000000000000"
expect 200 "api/remove with no id" ask -X POST "$B/api/remove"
ask -f -o /dev/null -X POST "$B/api/remove?id=$note"
items | json "'$note' not in [i['id'] for i in d['items']]" "api/remove left the item"
[[ ! -e "$STATE/files/$note" ]] || die "api/remove left the file for the phone"
check "api/remove: the item and its copy for the phone"
ask -f -o /dev/null -X POST "$B/api/remove?id=$upload"
[[ -f "$DOWNLOADS/$name" ]] || die "api/remove deleted a received file from Downloads"
check "api/remove: a received file stays in Downloads"
ask -f -o /dev/null -X POST "$B/api/clear?to=computer"
items | json 'not any(i["to"] == "computer" for i in d["items"]) and any(i["to"] == "phone" for i in d["items"])' \
  "api/clear?to=computer"
[[ -f "$DOWNLOADS/chunked.bin" ]] || die "api/clear deleted a received file from Downloads"
check "api/clear?to=computer: what came from the phone, and Downloads kept"
ask -f -o /dev/null -X POST "$B/api/clear?to=phone"
items | json 'd["items"] == []' "api/clear?to=phone"
[[ -z $(ls -A "$STATE/files") ]] || die "api/clear left files for the phone: $(ls "$STATE/files")"
check "api/clear?to=phone: what was left for the phones (the iPad's too) and their files"
expect 200 "api/clear with no direction" ask -X POST "$B/api/clear"

step "API: notifications"
ep=https://127.0.0.1:9/push/one   # nothing listens: a notification fails at once, and stays here
sub='"keys": {"p256dh": "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM", "auth": "tBHItJI5svbpez7KI4CCXg"}'
expect 400 "api/subscribe over http" ask -H "Content-Type: application/json" \
  -d "{\"endpoint\": \"http://127.0.0.1:9/push/one\", $sub}" "$B/api/subscribe"
expect 400 "api/subscribe without keys" ask -H "Content-Type: application/json" -d "{\"endpoint\": \"$ep\"}" "$B/api/subscribe"
expect 400 "api/subscribe of a list" ask -H "Content-Type: application/json" -d '[]' "$B/api/subscribe"
ask -f -H "Content-Type: application/json" -d "{\"endpoint\": \"$ep\", $sub, \"direct\": true}" "$B/api/subscribe" \
  | json 'd == {"ok": True}'
ask -f -o /dev/null -H "Content-Type: application/json" -d "{\"endpoint\": \"$ep\", $sub, \"direct\": true}" "$B/api/subscribe"
json 'len(d) == 1 and d[0]["endpoint"] == "'$ep'" and d[0]["device"] == "iphone" and d[0]["direct"] is True' \
  "api/subscribe: $(cat "$STATE/push.json")" < "$STATE/push.json"
[[ $(stat -c %a "$STATE/push.json") == 600 ]] || die "push.json isn't private"
check "api/subscribe: one direct subscription for the iPhone, kept privately, the same endpoint replaced"
expect 200 "api/test-push" ask -X POST "$B/api/test-push"
ask -f -o /dev/null -H "Content-Type: application/json" -d "{\"endpoint\": \"$ep\"}" "$B/api/unsubscribe"
expect 200 "api/unsubscribe of an unknown endpoint" ask -H "Content-Type: application/json" \
  -d '{"endpoint": "https://example.com/x"}' "$B/api/unsubscribe"
[[ $(cat "$STATE/push.json") == "[]" ]] || die "api/unsubscribe left $(cat "$STATE/push.json")"
check "api/unsubscribe"
ask -f -o /dev/null -H "Content-Type: application/json" -d "{\"endpoint\": \"$ep\", $sub, \"direct\": true}" "$B/api/subscribe"
ask -f -o /dev/null -H "Content-Type: application/json" -d "{\"endpoint\": \"$ep/2\", $sub, \"direct\": true}" "$B/api/subscribe"
json 'len(d) == 1 and d[0]["endpoint"] == "'$ep/2'"' "api/subscribe again: $(cat "$STATE/push.json")" < "$STATE/push.json"
check "api/subscribe: a new direct subscription replaces the device's old one (an app installed again)"

step "API: forgetting a device"
expect 400 "api/forget without a device" ask -H "Content-Type: application/json" -d '{}' "$B/api/forget"
expect 400 "api/forget of a list" ask -H "Content-Type: application/json" -d '[]' "$B/api/forget"
expect 400 "api/forget of a full name" ask -H "Content-Type: application/json" -d '{"device": "ipad.tail0.ts.net"}' "$B/api/forget"
ask -f -H "Content-Type: application/json" -d '{"device": "iphone"}' "$B/api/forget" | json 'd == {"ok": True}'
[[ $(cat "$STATE/push.json") == "[]" ]] || die "api/forget left the iPhone's subscription: $(cat "$STATE/push.json")"
ask -f -o /dev/null -H "Content-Type: application/json" -d "{\"endpoint\": \"$ep\", $sub, \"direct\": true}" "$B/api/subscribe"
[[ $(cat "$STATE/push.json") == "[]" ]] || die "a forgotten iPhone's subscription was kept: $(cat "$STATE/push.json")"
check "api/forget: the iPhone's subscription went, and a new one isn't kept"
ask -f "$B/api/ping" | json '[(e["device"], e["forgotten"]) for e in d["forgotten"]] == [("iphone", True)]' "api/ping: forgotten"
ask -f "$B/api/machines" | json '[e["device"] for e in d["forgotten"]] == ["iphone"]' "api/machines: forgotten"
"$ferry" list --json | json '"forgotten" not in d and "iphone" not in [x["id"] for x in d["devices"]]' \
  "ferry list --json: the iPhone forgotten"
check "api/ping and api/machines say the iPhone is forgotten, ferry list --json no longer lists it"
ask -f "$B/api/ping" >/dev/null
"$ferry" list --json | json '"iphone" not in [x["id"] for x in d["devices"]]' "a forgotten iPhone's call brought it back"
! "$ferry" unforget iphone 2>/dev/null || die "ferry unforget brought a device back"
ipad -f -H "Content-Type: application/json" -d '{"self": true}' "$B/api/unforget" | json 'd == {"ok": True}'
ask -f "$B/api/ping" | json '[e["device"] for e in d["forgotten"]] == ["iphone"]' "api/unforget self of the iPad, not forgotten"
check "the iPhone's own calls and ferry unforget don't bring it back; the iPad's unforget of itself adds nothing"
ask -f -H "Content-Type: application/json" -d '{"self": true}' "$B/api/unforget" | json 'd == {"ok": True}'
ask -f "$B/api/ping" | json '[(e["device"], e["forgotten"]) for e in d["forgotten"]] == [("iphone", False)]' "unforget self"
"$ferry" list --json | json '"iphone" in [x["id"] for x in d["devices"]]' "api/unforget self: the iPhone listed"
ask -f -o /dev/null -H "Content-Type: application/json" -d "{\"endpoint\": \"$ep\", $sub, \"direct\": true}" "$B/api/subscribe"
json 'len(d) == 1' "the iPhone brought back subscribes: $(cat "$STATE/push.json")" < "$STATE/push.json"
ask -f -o /dev/null -H "Content-Type: application/json" -d "{\"endpoint\": \"$ep\"}" "$B/api/unsubscribe"
check "api/unforget {self: true}: the iPhone added again is back, with a tombstone, and subscribes again"

expect 400 "api/relay via someone else's computer" ask -H "Content-Type: application/json" \
  -d '{"via": "https://other.tail0.ts.net/ferry/"}' "$B/api/relay"
expect 400 "api/relay via this computer" ask -H "Content-Type: application/json" -d "{\"via\": \"https://$HOST/ferry/\"}" "$B/api/relay"
expect 400 "api/relay via an address not at /ferry/" ask -H "Content-Type: application/json" \
  -d "{\"via\": \"$mac/\"}" "$B/api/relay"
expect 200 "api/relay via the MacBook" ask -H "Content-Type: application/json" -d "{\"via\": \"$mac/ferry/\"}" "$B/api/relay"
expect 200 "api/relay via the MacBook again" ask -H "Content-Type: application/json" -d "{\"via\": \"$mac/ferry/\"}" "$B/api/relay"
json 'd == ["'$mac'/ferry/"]' "relays.json: $(cat "$STATE/relays.json")" < "$STATE/relays.json"
check "api/relay: kept once"
rm "$STATE/relays.json"   # the MacBook is asleep: no sends through it in the rest of the run
expect 400 "api/relay-push about someone else's computer" ask -H "Content-Type: application/json" \
  -d '{"title": "t", "body": "b", "machine": "https://other.tail0.ts.net/ferry/"}' "$B/api/relay-push"
expect 200 "api/relay-push about the MacBook" ask -H "Content-Type: application/json" \
  -d "{\"title\": \"MacBook\", \"body\": \"photo.jpg\", \"machine\": \"$mac/ferry/\", \"device\": \"iphone\"}" "$B/api/relay-push"

step "The page"
h=$(headers ask "$B/")
grep -qi "^Content-Type: text/html; charset=utf-8$" <<<"$h" || die "the page: $h"
ask -f "$B/" | grep -q 'href="/ferry/' || die "the page's base isn't /ferry/"
ask -f "$B/ferry/" | grep -q '<title>Ferry' || die "the page at /ferry/ (tailscale serve leaving the mount on)"
check "the page, with /ferry/ as its base, also when the mount is left on"
for f in manifest.webmanifest:application/manifest+json sw.js:text/javascript icon.svg:image/svg+xml \
         icon-180.png:image/png icon-192.png:image/png icon-512.png:image/png; do
  h=$(headers ask "$B/${f%%:*}")
  grep -q "^HTTP/1.1 200" <<<"$h" && grep -qi "^Content-Type: ${f#*:}$" <<<"$h" || die "/${f%%:*}: $h"
done
check "manifest, service worker and icons, with their types"
expect 403 "the page for someone else" raw -H "Host: $HOST" -H "Tailscale-User-Login: someone@else.com" "$B/"
expect 404 "a file that isn't the page's" ask "$B/../bin/ferry"
expect 404 "a font that isn't the page's" ask "$B/font/..%2F..%2Fbin%2Fferry"

printf '\n\033[1mAPI: PASS\033[0m\n'
