"""Ferry: a mailbox between your devices, over Tailscale. This is a Linux computer's side of it.

Either end leaves files or text in the box, and they wait there until the other end picks them up. The phone needs no
app: a web page served by this script, which it can add to its Home Screen (a PWA with Web Push notifications). The
devices don't have to be on the same network, only on the same tailnet.

The server listens on localhost only. `tailscale serve` publishes it on the tailnet at MOUNT with the tailnet's real
certificate (iOS writes to the clipboard and allows a PWA and Web Push only on HTTPS), and tells it who is asking: a
request is answered only for the Tailscale user who owns this machine (Tailscale-User-Login, which tailscale serve sets
and a client can't). A custom header on every API call keeps other web pages on the phone from posting here (their
cross-site request would need a CORS preflight, which isn't answered).

Every send goes to one device. For a phone it waits in this computer's box, marked for that phone ("for"): only that
phone's page lists it (the page asks every computer, and each answers with what is for the device asking) and only it
gets the notification. For another computer it goes straight there, as the phone's page sends: it lands in that
computer's box and menu, and Send Clipboard onto its clipboard. The server keeps the owner's computers that answer as
Ferry in STATE/machines.json for the commands and the menu (`ferry devices`).

Several computers: each runs its own Ferry, and the page shows them as one. It asks its own computer which of the owner's
other machines answer at MOUNT (/api/machines), lists what all of them hold, and sends to the one picked above the form,
talking to each directly: a computer answers another one's page (CORS) only if that one belongs to the same owner. A phone's push
subscription belongs to the computer it added the page from, so the others ask that one to pass their notifications on
(/api/relay, /api/relay-push).

A request must name this machine (Host: its tailnet name), so a web page that rebinds its own name to 127.0.0.1 in a
browser here gets nothing. Anyone logged in to this computer could still reach the local port with made-up headers:
Ferry trusts the computer's own users, as a single-user desktop does.

Kept in STATE: items.json (the box), the files left for the phone (files/), the VAPID key for Web Push (made on the first
run; python3-cryptography), the phone's push subscriptions, the phones that have used Ferry here (phones.json: the
device list shows only those) and the devices the owner forgot (forgotten.json, which reaches the other computers
through api/ping). Files from the phone go to Downloads. Items go after
KEEP_DAYS days, a code or a password after SECRET_KEEP or once copied; removing one from the box doesn't delete a file in
Downloads. Nightdrive's Ferry plugin, where this
server came from, kept the same state in OLD_STATE: the first run moves it here (migrate()).

The desktop: the service starts with the user's session, maybe before the desktop, so the desktop's variables (Wayland's
or X11's display) are looked up whenever the clipboard or a notification needs them (desktop_env()). The clipboard is
wl-clipboard's, or xclip's on X11 and where Wayland's can't be reached; notifications go over a session bus connection
of the process's own, through PyGObject, which hears their buttons pressed (Notifications), else they are notify-send's;
how long the computer has been idle comes from the compositor, Mutter, X11 or logind (idle_for()). A desktop's own Ferry
menu hears about changes through HOOK, run with the event's name ("changed": the box or a send; "picked": files sent
from `ferry pick`'s dialog).
"""
