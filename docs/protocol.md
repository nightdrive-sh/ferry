# Ferry's protocol

How Ferry's apps talk to a computer running Ferry. Written from the first server, the Linux one (`linux/bin/ferry`,
then Nightdrive's Ferry plugin, at Nightdrive's commit `7c97544` of 2026-10-19, with notifications as of `8a186df`). The
second server, the Mac's (`FerryKit/Sources/FerryServer`), was written against this document, and what it needed is in
it too. Any other Ferry answers the same way, and a client may rely on nothing that isn't written here.

## Network and trust

Ferry runs only inside a [Tailscale](https://tailscale.com) tailnet, and Tailscale is its security layer.

- **The address.** Each computer listens on localhost only. `tailscale serve` publishes it on the tailnet at
  **`https://<machine>.<tailnet>.ts.net/ferry/`**, with the tailnet's real certificate. That address, with its trailing
  slash, is the computer's **base URL**, and every path below is relative to it. The QR code a computer shows under Add
  Device carries it inside a link to nightdrive.sh (› Clients › Adding a phone).
- **Not on the internet.** The address is `tailscale serve`, not Funnel, so only the tailnet can reach it.
- **Only the owner.** `tailscale serve` adds `Tailscale-User-Login` to every request, and a client can't set it. A computer
  answers only the Tailscale user who owns it. Anyone else gets **403**.
- **The Host must name the computer** (its tailnet name), otherwise **403**. This keeps a page that rebinds its own name
  to 127.0.0.1 out.
- **`X-Ferry: 1`** must be on every `api/` request except `api/file/<id>`, otherwise **403**. The header exists for web
  pages: a cross-site request carrying it would need a CORS preflight, which a computer answers only for a Ferry page on
  another of the owner's computers. A native app sends it and needs no CORS.
- **CORS, for a Ferry page on another of the owner's computers** (the Linux PWA lists every computer and talks to each
  directly):
  - **An `Origin`** that is `https://` and names one of the owner's machines gets `Access-Control-Allow-Origin` with
    that origin, and `Vary: Origin`, on every answer.
  - **A preflight (`OPTIONS`)** from such an origin, by the owner and naming this computer, is answered 204 with
    `Access-Control-Allow-Methods: GET, POST`, `Access-Control-Allow-Headers: X-Ferry, Content-Type` and
    `Access-Control-Max-Age: 600`. Any other preflight gets **403**.
  - **An `api/` request from another site** (`Sec-Fetch-Site` other than `same-origin` or `none`, a missing one counting
    as `same-origin`) gets **403** unless its origin is answered as above.
- **Mutual trust.** Computers of the same owner trust each other: one may ask another to pass a notification on
  (`api/relay-push`).

## Items

A computer keeps a **box** of items in both directions. An item:

| Field | |
| --- | --- |
| `id` | 12 hex characters, unique in that computer's box |
| `to` | `"phone"`: left for the phone. `"computer"`: received from a phone |
| `kind` | `"text"` or `"file"` |
| `time` | when it was left, Unix seconds (a float) |
| `text` | a text's content (up to 1 MiB) |
| `name`, `size`, `type` | a file's name, size in bytes and MIME type |
| `from` | the sending device's tailnet name. Only on items `to: "computer"`; what a computer leaves for the phone has no `from`, and its sender is the computer itself |
| `for` | on items `to: "phone"`: the one device (its short tailnet name) the item was left for. Missing: for any device |
| `seen` | on items `to: "computer"`: whether the computer's user has seen it |
| `secret` | `true` on a text that looks like a code or a password (› Codes and passwords). Missing otherwise |

Items leave the box after `keep` days (7), a code or a password after 15 minutes or once copied (› Codes and passwords).
Removing a received file from the box doesn't delete it from the computer's Downloads.

## Codes and passwords

A text sent to copy is often a one-time code or a password. Every Ferry tells one by the same rule, and keeps it out of
sight:

A text **looks like a code or a password** when, without the whitespace around it (Unicode's White_Space), it is
- **a code:** 4 to 8 digits (`0`–`9`), maybe in groups split by single spaces or hyphens (`801566`, `123 456`), or
- **one word that mixes:** 6 to 256 characters (Unicode code points), none of them whitespace, of at least two kinds out of
  letters (Unicode's), digits and anything else (`hunter2`, `Tr0ub4dor&3`, `sk-ant-…`), and none of these:
  - **a number:** only digits, spaces, `+`, `-`, `(` and `)` that isn't a code (`+358401234567`, `(040) 1234`)
  - **an address:** a web address (`://` in it, or starting with `www.`), a mail address (`name@host.tld`), or a host
    name with or without a path (`nightdrive.sh`, `github.com/nightdrive-sh/ferry`; a file's name like `README.md`
    is one too)
  - **a path:** starting with `/` or `~/`
  - **words joined** by hyphens or apostrophes, letters only between them (`well-known`, `rock'n'roll`)

Only a text is ever one: a file's name is shown whatever it looks like. The rule's test cases are
`FerryKit/Tests/FerryKitTests/Fixtures/secrets.json`, which both servers' tests run, and every comparison is by code
point, not by what a person would see as one character.

**In the box** one is kept 15 minutes, not `keep` days, or until it is copied, whichever comes first:
- **On the computer:** its own Copy (a notification's, its list's, `ferry copy`, and `ferry get`, which prints it)
  takes it out of the box. One that Send Clipboard put on the clipboard is copied already, so the box doesn't keep it at
  all. It leaves the computer's disk too within a minute of its 15.
- **A client** that copies one (a tap on its row or its notification) removes it with `api/remove`, after the copy, not
  before it. A notification of one that has left the box copies nothing. Items carry
  `secret: true` for a client without the rule (a web page); one with it may use it instead. A client that keeps its own
  list of what it saw drops one after 15 minutes too, also while its computer can't be reached.

**In a notification on the phone** (› Notifications) a code or a password isn't shown: the body says
`Code or password · open to see`, and `secret: true` says why. The text still goes along, for the tap that copies it.
The body that `api/relay-push` passes on to a page is the placeholder too. The iPhone app shows the placeholder also for
a text notification without `secret` whose text (or body) looks like one: a computer from before the rule sends the
text itself.

**In the computer's own notification** of a text that arrived, the same: `Code or password · open to see` while it
waits for Copy (which still copies it), `Code or password` once it is on the clipboard (Send Clipboard). A desktop keeps
what its notifications said (macOS's Notification Center, on disk too), so the Mac's notification doesn't carry the text
either: its Copy reads it from the box, while it is there.

**On the clipboard**, clipboard histories (Maccy, Raycast, cliphist, Klipper) are told to leave it out:
- **What Send Clipboard brings** (`clip`: a text or an image) is always marked, whatever it looks like: the phone's
  clipboard often holds a password from its password manager.
- **A code or a password copied** with Copy (a notification's, the computer's list, `ferry copy`) is marked too.
- **The marks:** macOS's `org.nspasteboard.ConcealedType` beside the text; on Wayland `wl-copy --sensitive` (wl-clipboard
  2.3 and later; an older one copies without the mark). X11's `xclip` serves one type only, so there it goes unmarked.
- **On the iPhone** a copied code or password is `localOnly`: Universal Clipboard doesn't hand it to a Mac.

## Calls

All answers are JSON unless noted. An error is a plain-text body with the status, written for a person to read, e.g.
404 `Not in the box any more`.

### `GET api/ping`

`{"computer": "Nightdrive", "idle": 0, "forgotten": [ … ]}`: the computer's display name, `idle` as in `api/items`,
and its list of forgotten devices (› Forgetting a device). Used to check a computer answers, and by computers to find
each other (they read `idle` for their device lists, and merge `forgotten` into their own).

### `GET api/items`

```json
{"computer": "Nightdrive", "items": [ … ], "keep": 7, "idle": 0, "push": "<VAPID public key>"}
```

- **`idle`:** seconds since the computer was last used (a key press or mouse move). `0` means it is in use: used within
  the last minute, on every system, so a Mac and a Linux computer compare fairly. `null` means it can't tell (its
  desktop doesn't report it). Clients send to the reachable computer with the smallest `idle`.
- **`items`:** what the asking device (named by Tailscale from its address) may see: every item `to: "computer"`, and the
  items `to: "phone"` without `for` or with `for` naming it.
- **`push`:** the computer's VAPID public key, or `null` when it can't notify (no python3-cryptography). Web pages subscribe with it, and the app binds its relay address to it.

### `GET api/machines`

```json
{"machines": [{"url": "https://nightdrive.tail1234.ts.net/ferry/", "name": "Nightdrive", "self": true},
              {"url": "https://macbook.tail1234.ts.net/ferry/", "name": "MacBook"}], "push": "…",
 "forgotten": [{"device": "studio", "time": 1761500000.5, "forgotten": true}]}
```

The answering computer (`self: true`), plus the owner's other online computers on the tailnet (not phones) that answer
`api/ping` at `/ferry/` and aren't forgotten. A computer that is asleep or not running Ferry isn't listed, so a client
that wants to show it as "can't reach" keeps its own memory of computers it has seen. `forgotten` is the computer's list
of forgotten devices (› Forgetting a device): a client drops the computers forgotten there from its memory.

The list follows Tailscale's own view of which machines are online, read on every call: a computer that wakes is listed
within seconds, and one that goes to sleep leaves at once. Only a machine that just came online is asked `api/ping` (one
listed is asked again after a minute, one that didn't answer as Ferry after 10 s), so such a call can take up to about 6
seconds. This is how a client finds a sleeping computer awake again: it asks a computer that answers for this list,
rather than trying the sleeping one, since on an iPhone, Tailscale's tries to reach a machine that is off jammed its
tunnel to the others too.

### `GET api/file/<id>`

The file's bytes. With `?download=1`, it is served as an attachment.
- **Inline types** (images, video, audio, PDF, plain text) are served with their own type. Anything else is
  `application/octet-stream`, so an HTML or SVG file never runs as a page.
- **Headers:** `Content-Disposition` carries the name as `filename*=UTF-8''…`.
- **Errors:** 404 when the item or the file is gone.

### `POST api/text`

Body `{"text": "…", "clip": true}`, `Content-Type: application/json`.
- **`clip: true`** means the sender's clipboard. The text goes straight onto the computer's clipboard, ready to paste,
  marked for clipboard histories to leave out (› Codes and passwords).
- **Without `clip`** it waits in the computer's box and notification for its user to copy it.
- **Errors:** 400 for an empty text. A text over 1 MiB is cut.

### `POST api/upload?name=<name>&type=<mime>[&clip=1]`

- **The body** is the file's raw bytes, with a `Content-Length` or chunked.
- **The query values** are percent-encoded (`&`, `+`, `#` included). A computer doesn't log them: a log of requests
  names the path only, never the file.
- **The name** is made safe (no path, no leading dot) and unique in Downloads.
- **`clip=1` with an image** also puts the image on the computer's clipboard, marked as a text with `clip` is.
- **The answer:** `{"ok": true, "name": "<the name it was saved as>"}`.
- **Errors:**
  - 413 over 4 GiB
  - 507 when the computer would have less than 2 GiB free
  - 400 when the upload broke off

### `POST api/remove?id=<id>`

One item out of the box. An unknown id is not an error.

### `POST api/clear?to=phone` (or `to=computer`)

Every item in that direction out of the box.

### Notifications

A computer notifies a phone with Web Push (RFC 8030, encrypted per RFC 8291, signed with its VAPID key per RFC 8292),
whatever the phone is: a web page subscribes with its browser's push service, the iPhone app with Ferry's push relay.

**`POST api/subscribe`** with `{"endpoint", "keys": {"p256dh", "auth"}, "direct"}`.
- **`endpoint`** must be `https://`. Subscribing the same endpoint again replaces it, so a client may repeat it at any time.
- **`direct: true`** is the app's: it subscribes on every computer, so it hears about each computer's own items from that
  computer. A direct subscription gets no notification passed on by another computer (`api/relay-push`), and while a
  device has one, the computer leaves that device's other subscriptions (the same phone's PWA) quiet. The device is the
  asking device's tailnet name; one the computer can't name ("your phone") replaces nothing.
- **One direct subscription per device.** A direct subscription replaces the same device's earlier direct ones: an app
  installed again subscribes with a new address, and the old app's address would go on getting every notification
  until its push service gave up on it. A device the computer can't name replaces nothing here either.
- **A forgotten device** (› Forgetting a device) is answered 200, but its subscription isn't kept.
- 400 for anything that isn't a subscription.
- **A computer that serves no page** (the Mac) may refuse a subscription without `direct: true` with 400: no page there
  could show its notifications.

**`POST api/unsubscribe`** with `{"endpoint"}`.

**What a notification carries**, encrypted, as JSON of at most 2600 bytes:

| Field | |
| --- | --- |
| `title` | the computer's name |
| `body` | the text's first 180 characters, the file's name, or "N files"; `Code or password · open to see` for a code or a password (› Codes and passwords) |
| `machine` | the address of the computer the item is on when another computer passed it on; `""` otherwise |
| `id` | the item's id (the first one for several files). Missing on a test notification |
| `kind` | `"text"` or `"file"`. Missing on a test notification |
| `text` | the whole text, when it fits in the 2600 bytes; otherwise missing, and a client that wants it reads `api/items` |
| `secret` | `true` when the text is a code or a password, and the body says so in its place. Missing otherwise |

**Sending:** a computer POSTs the encrypted body to the endpoint with `Authorization: vapid t=<JWT>, k=<its key>`
(the JWT's `aud` is the endpoint's origin), `Content-Encoding: aes128gcm`, `TTL` (7 days) and `Urgency: high`. An endpoint
that answers 404 or 410 is gone, and the computer drops its subscription.

**For web pages only:**
- `POST api/test-push`: a test notification to this computer's subscriptions. A computer without a page needn't have it
  (404).
- `POST api/relay {"via": "<base URL>"}`: the page from the computer at `via` switched to this one. `via` must be one of
  the owner's machines and end in `/ferry/`, and not be this computer, else 400. The computer keeps it.
- `POST api/relay-push {"title", "body", "machine", "device"}`: another of the owner's computers asks this one to notify
  its subscriptions about an item on `machine` (its base URL, one of the owner's machines, else 400). `device`, when set,
  limits it to that phone. Only subscriptions that aren't `direct` get it: the app hears from that computer itself.

A web page's subscription belongs to the computer it subscribed on, and the owner's other computers ask that one to pass
their notifications on. **When a computer leaves something for a phone**, it notifies its own subscriptions and sends
`api/relay-push` to every `via` it keeps (with `machine` its own base URL), not to itself. A notification that came in
through `api/relay-push` goes no further.

### Forgetting a device

The owner forgets a device (a computer, a phone) on any of their devices, and it is forgotten on all of them: it leaves
every computer's device list and the phones' lists of computers, until the owner brings it back by hand. A forgotten
device that is still on the tailnet doesn't come back by itself.

**`POST api/forget`** and **`POST api/unforget`** with `{"device": "<short tailnet name>"}`, from any of the owner's
devices (the gate above, like every call). The computer records the decision with the time now (later than any it
already holds for that device), carries it out at once and answers `{"ok": true}`. 400 for a device that isn't a tailnet
name (letters, digits and `-`, at most 63).

**The list.** A computer keeps one entry per device ever forgotten, and `api/ping` and `api/machines` carry all of them as
`forgotten`:

| Field | |
| --- | --- |
| `device` | the device's short tailnet name (`macbook` of `macbook.tail1234.ts.net`) |
| `time` | when it was decided, Unix seconds (a float) |
| `forgotten` | `true`: forgotten. `false`: brought back, kept so that an older `true` elsewhere can't win over it |

**How it spreads.** When a computer asks another `api/ping` (finding the owner's computers, › `api/machines`: when it comes
online, then every minute), it merges the other's list into its own, device by device: the entry with the later `time`
wins, `forgotten: true` on equal times. Entries that aren't of this form are left out. So a decision reaches the owner's
other computers within about a minute, a computer that slept learns it when it wakes, and it passes through a third
computer. There is no call between computers for it.

**What forgetting does:**
- **A forgotten computer** is left out of the others' `api/machines` and device lists, so nothing is sent to it. It is
  still asked `api/ping`, to merge its list. A computer never forgets itself: its own name in the list changes nothing
  there, and its `api/machines` still lists it as `self`.
- **A forgotten phone** leaves the device lists, and every push subscription it has on the computer goes (also when the
  computer learns of it from another one). `api/subscribe` from it answers 200 but keeps nothing. Everything else still
  works for it: forgetting tidies the lists, it is not a security boundary (Tailscale is). Brought back, it gets its
  notifications again once it subscribes again (the app does so at least daily).
- **A client** drops from its memory the computers forgotten in `api/machines`'s list (the first label of a base URL's
  host is its device name), after taking in the list of machines. Its own Forget sends `api/forget` to a computer that
  answers, the forgotten one itself when no other does, and keeps the computer hidden until an `api/machines` answer
  lists it as forgotten (another computer may not have heard yet; the iPhone app waits 10 minutes at most, for a Ferry
  that doesn't forget). Setting up a computer again by hand (its QR code, its name) brings it back: the client sends it
  `api/unforget` when its `api/machines` says it is forgotten.
- **The device name** is lowercased, as Tailscale writes it, whatever case `api/forget` gets.

### Ferry's push relay

The iPhone app can't use a browser's push service, and Apple's push key can't be on every computer, so the app's
endpoints are addresses at Ferry's push relay, `https://push.nightdrive.sh/push/<id>`. To a computer the relay is a Web
Push service like any other (above):
- it accepts a push only when it is signed by the VAPID key the address was made for (`push` in `api/items`), else 403
- a body may be 2800 bytes at most, else 413
- 30 pushes a minute per address, 600 an hour per sending computer, else 429
- 201 when Apple has the notification; 404 for an address it doesn't know and 410 for a phone that is gone, which drop the
  subscription; 502 when Apple refuses it otherwise

The relay never sees the content. Its API for the app: `relay/README.md`.

## Clients

A client knows one computer to start with: the setup one, from its QR code or a typed name. It finds the rest with
`api/machines`, and talks to each computer directly at its own base URL. Over all the computers, the phone's *Received*
is every computer's `to: "phone"` items.

### Adding a phone

Add Device's QR code encodes exactly this URL: nightdrive.sh's add page, with the computer's base URL as the fragment,
as it is (not percent-encoded):

```
https://nightdrive.sh/ferry/add#https://<machine>.<tailnet>.ts.net/ferry/
```

- **The site never sees the address.** A browser doesn't send the fragment, so nightdrive.sh learns no tailnet name. Its
  page reads the fragment itself.
- **The iPhone app** claims the page as a universal link: `applinks:nightdrive.sh` in the app, and the site's
  `/.well-known/apple-app-site-association` naming app ID `279G2UNHPN.fi.feature.ferry` for `/ferry/add` (and
  `/ferry/add/`). The Camera then opens the app, which sets up with that computer, or adds it beside the others.
- **Without the app**, the page says what is needed (the iPhone app, Tailscale on the phone, signed in as the same user)
  and, on other phones, links to the base URL: the computer's own web page.
- **A client's scanner** takes the link, or a bare base URL as computers showed it before the link: an old computer
  still adds a phone. It also takes a percent-encoded fragment and `www.nightdrive.sh`. A link without a base URL in its
  fragment is no address.
- `ferry url` (Linux) is the base URL itself, and `ferry qr` the code of the link.
