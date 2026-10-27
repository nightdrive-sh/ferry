# Testing Ferry on a real iPhone

The simulator covers the app against `tools/mock-ferry.py` (`ios/uitest.sh`). This list is what only a real iPhone with
Tailscale can show. Run it against a Nightdrive computer (`nightdrive/plugins/ferry`, `dev` at `7c97544` or later) for each
TestFlight build that changes sending, setup or the list.

**Before the first build:** App Groups must be on for `fi.feature.ferry` at developer.apple.com (Identifiers ›
fi.feature.ferry › App Groups, with `group.fi.feature.ferry`) if the export's automatic provisioning doesn't add it.
`ios/build.sh` stops before the upload if the exported app lacks it. Associated Domains likewise (`applinks:nightdrive.sh`,
for Add Device's QR code in the Camera).

## Setup

- [ ] A fresh install opens to setup. **Scan QR Code** reads the code from Add Device in the computer's Ferry menu, and the
      list appears.
- [ ] With nightdrive.sh serving `apple-app-site-association`: Add Device's QR code in the **Camera** offers to open
      Ferry, and Ferry sets up with that computer (a fresh install) or adds it (Settings shows it). In the demo, it leaves
      the demo first. The same code with Ferry not installed opens nightdrive.sh's add page, which names the computer.
- [ ] A computer new to the tailnet (a name with no certificate yet), its Add Device QR code scanned at once after
      Ferry is published: "Waiting for <name>…" with the certificate's explanation, and it is set up within a minute
      (the certificate takes about 37 s). **Cancel** goes back to the buttons. A name that isn't in the tailnet says
      "Can't reach that computer" at once, without waiting.
- [ ] Add Device on the computer (Mac or Linux) goes back to its list by itself once the phone has added it, and its
      QR code doesn't flicker while it waits.
- [ ] An old computer's QR code (the bare address, before the nightdrive.sh link) still sets up in **Scan QR Code**.
- [ ] **Type a Computer's Name** with the bare name (`nightdrive`) completes to the full tailnet name. If it doesn't,
      the app asks for the full name; note which happened.
- [ ] With two computers running Ferry, the second appears by itself (in Settings, and in the Send to menu).

## Send Clipboard

- [ ] The first Send Clipboard shows iOS's Paste prompt, and then Ferry's paste help. After **Settings › Apps › Ferry ›
      Paste from Other Apps › Allow**, it sends with no prompt.
- [ ] A code copied in Authenticator is on the computer's clipboard right away (`wl-paste` on Nightdrive), and the button
      says "Sent to Nightdrive".
- [ ] **Kept out of clipboard histories:** Send Clipboard with a text, on a Mac running Maccy (or Raycast's clipboard
      history): it pastes, and the history doesn't list it. On Nightdrive (cliphist, wl-clipboard 2.3+): `cliphist list`
      doesn't list it. A code copied from Received on the iPhone doesn't reach the Mac's clipboard (Universal
      Clipboard).
- [ ] A screenshot copied to the clipboard lands as an image: on the clipboard and in Downloads.
- [ ] A photo copied in Photos (Copy Photo; a HEIC one and a JPEG one) lands as `clipboard.jpg` of a few MB, not a PNG
      of 20: on the Mac's clipboard (pastes in Preview › New from Clipboard) and on Nightdrive's (`wl-paste --list-types`
      says `image/jpeg`, and it pastes in a browser). A screenshot still lands as `clipboard.png`.
- [ ] Ferry opened from the background after a while sends at once, to the computer last known to be in use.
- [ ] With one computer asleep, leave Ferry (home screen) during a poll and reopen it: the header doesn't fall to "0/2
      online", and Send Clipboard goes to the computer in use.
- [ ] Pull down Control Center over Ferry and back: the list keeps updating.

## Other sends

- [ ] **Aa (T):** a typed text arrives as a notification with Copy, and doesn't replace the computer's clipboard.
- [ ] **Aa (T)** with a password (`Tr0ub4dor&3`), on the Mac and on Linux: the notification says **Code or password ·
      open to see**, also in the Mac's Notification Center afterwards, and its Copy copies the password. Send Clipboard
      with a code: **Copied from iPhone**, **Code or password**.
- [ ] With Tailscale off, a typed text fails; turn Tailscale on and tap Try again: that text arrives, not the clipboard.
- [ ] **+ › Photos:** several photos at once arrive in Downloads, with the progress bar while they upload.
- [ ] **+ › Files:** a file named with an `ä` and an `&` (e.g. `Lasku & kuitti ä.pdf`) arrives under that exact name.

## The computer in use

- [ ] With two computers, the chip follows the one with the latest key press or mouse move.
- [ ] A hand pick in the Send to menu lasts one send, then the chip returns to the computer in use.
- [ ] Put the computer in use to sleep and tap Send Clipboard before the app notices: "Can't reach …". Pick the other
      computer: the button reads Send Clipboard again, and a tap sends there. After a typed text instead, the pick
      leaves "Not sent / Try again", and Try again sends that text to the computer picked.
- [ ] A computer put to sleep shows "can't reach" in the menu and can't be picked, and the header says "1/2 online".

## Received

- [ ] What the computer sends (Send Clipboard in its menu, a dropped file) appears within a few seconds while Ferry is open.
- [ ] A tap copies a text. **Save** puts a photo in Photos (asking for add access once) and a file in Files. **Share**
      and Quick Look work.
- [ ] Swipe to remove, and Clear, empty the computer's box too (its menu shows it).

## Network and look

- [ ] With Tailscale off, sending fails within about 8 seconds with "Can't reach …", and the bar says "Can't reach your
      computers. Is Tailscale on?"
- [ ] **No Local Network permission prompt appears** (Tailscale's addresses aren't the local network). If one does,
      note it: the app would then need `NSLocalNetworkUsageDescription`.
- [ ] Light and dark appearance both follow the system. Large text (Settings › Display & Brightness › Text Size) keeps
      everything readable, and Send Clipboard shortens to "Send".

## Notifications

Needs the relay at `push.nightdrive.sh` running. The simulator runs no notification service extension, so what the
notification itself shows can only be seen here.

- [ ] After setup (or on the first launch after updating), Ferry offers notifications once; **Turn On Notifications**
      brings iOS's question. Within a few seconds Settings › Notifications is on and the footer names no computer.
- [ ] Phone locked: `ferry send "See you at eight"` on Nightdrive shows a notification titled **Nightdrive** with **See
      you at eight** in it, not "Something arrived from a computer running Ferry". (The fallback line means the extension couldn't read the
      keys: check the App Group and keychain group in `ios/build.sh`'s output.)
- [ ] **A code** (`ferry send "801566"`, and a password like `Tr0ub4dor&3`), phone locked, with iOS Settings ›
      Notifications › Show Previews on **Always**: the notification says **Code or password · open to see**, not the
      code, also in Notification Center. Tapping it copies the code all the same, and the code leaves Received (and
      `ferry list` on the computer). A code not copied leaves both after 15 minutes; a code copied from Received in the
      app, or in the PWA, leaves at once.
- [ ] An image and a file (`ferry send photo.jpg`) each notify with the file's name.
- [ ] A tap on the text's notification opens Ferry with the item highlighted, says "Copied", and the code is on the
      clipboard. The same with a long text (over ~2,500 characters): the whole text is copied, not the preview.
- [ ] A long text sent while Nightdrive then sleeps: the tap says "Couldn't reach Nightdrive" and copies nothing.
- [ ] With Ferry open, a send shows no banner; the item appears in Received at once.
- [ ] With the PWA's notifications also on (Safari's Home Screen Ferry) and two computers, an item from either computer
      notifies once, from the app.
- [ ] Settings › Notifications off: no more notifications. Forget a computer: no more from it.
- [ ] **Forgetting on every device** (docs/protocol.md › Forgetting a device), with the Mac, a Linux computer and the
      iPhone: Forget the Linux computer in the iPhone's Settings, and within about a minute it is gone from the Mac's
      Settings › Devices and from `ferry devices` on the other computers, and stays gone. Restart Ferry on it
      (`systemctl --user restart ferry`): within about a minute it is back on the Mac and the iPhone finds it again.
      Forget the iPhone on the Mac: it leaves the Linux window's Devices page, neither computer's `push.json` has its
      subscription, `ferry send --to iphone` no longer notifies, and using the app doesn't bring it back. Scan the Mac's
      Add Device QR code with the Camera: the iPhone is back on both computers' lists within about a minute, and a send
      from either notifies again without waiting for the app's daily check.
- [ ] **Only phones that used Ferry are listed:** a phone or tablet on the tailnet that never opened Ferry (the app or a
      computer's page) isn't in the Mac's Settings › Devices or `ferry devices`; once it opens Ferry, it is.
- [ ] **One subscription per phone:** delete and reinstall the app, open it: each computer's `push.json` has one direct
      subscription from the iPhone, the new one.
- [ ] With notifications denied in iOS Settings, Ferry's switch is off and **Allow in Settings** opens iOS Settings.
      Allowed there and back in Ferry, the switch is on by itself.
- [ ] Settings › About: **Ferry Website** and **Privacy Policy** open nightdrive.sh, **Email Support** a mail to
      hello@nightdrive.sh.
- [ ] **Moving relays** (once, a build with notifications at the old relay updated to one at `push.nightdrive.sh`):
      with the computer reachable, the first launch moves it: the computer's `push.json` (in its state folder) has a
      `push.nightdrive.sh` endpoint and no old one, and `ferry send` notifies once. A computer that was asleep moves when
      it next answers, and notifies through the old relay until then.

## Share sheet

**Before the first build:** `fi.feature.ferry.share` needs App Groups with `group.fi.feature.ferry` at
developer.apple.com if the export's automatic provisioning doesn't add it. `ios/build.sh` stops before the upload if the
exported share extension lacks it. The simulator covers the list, the automatic send and Safari's share sheet against
the mock (`ShareTests`, `ShareDownTests`, `ShareSheetTests`); what follows needs real computers and real files.

- [ ] A photo from Photos, both computers awake: Ferry's sheet lists them, the one in use first, and a tap sends it
      ("Sent to …", then the sheet closes). It arrives in Downloads.
- [ ] Several photos at once arrive, with one progress bar.
- [ ] A link from Safari arrives as the address only (no page title) and waits for Copy; the computer's clipboard
      doesn't change.
- [ ] One computer asleep: the photo goes to the other without a tap, within about 5 s.
- [ ] A video of several GB from Photos: the sheet shows at once ("Preparing…"), and Ferry isn't closed by iOS while
      it loads. Tap **Continue in Background** mid-upload: it still arrives.
- [ ] Lock the phone during a big upload, and unlock it a minute later: the upload carries on (it isn't cancelled as
      "Can't reach").
- [ ] A big video, **Continue in Background**, then put the computer to sleep mid-upload: a "Couldn't send … to …"
      notification follows (if notifications are on), within the hour at most.
- [ ] A photo to a computer that stops answering: "Can't reach …" in the sheet; wake it and tap **Try again**: it
      arrives, once.
- [ ] Only one computer set up, a link from Safari or Firefox: the sheet rises, the whole sheet turns into a large
      "Sent to …" with a tick, which stays readable for about 2 s before the sheet closes.
- [ ] Text shared from Notes arrives as a text waiting for Copy, not as an .rtf file.
- [ ] A fresh install with no computer set up: the sheet says "Open Ferry to set up a computer first."
- [ ] Light and dark appearance in the sheet follow the system.

## A computer that is off

Tailscale on the iPhone jammed (20.10.2026, task 1394) while Ferry kept trying a computer that was off: within about
1.5 minutes the phone stopped reaching the others too, until Tailscale was turned off and on. Ferry now asks a sleeping
computer only through one that answers (`api/machines`). Needs a server with the same change (`plugins/ferry/bin/ferry`).

- [ ] One computer off for good, Ferry open on 5G for 10 minutes: the other stays green the whole time.
- [ ] Turn the off one on with Ferry open: it turns green within about 15 s.
- [ ] Put a computer to sleep with Ferry open: it shows "can't reach" within about 20 s, and the other keeps updating.
- [ ] Tailscale off on the phone, then on again and back to Ferry: the computers turn green at once.

## Demo ("Try without a computer")

What App Review sees: a fresh install, Tailscale off or not installed. DemoTests covers the flow in the simulator.

- [ ] The setup screen's **Get Ferry for your computer** opens nightdrive.sh/ferry.
- [ ] Try without a computer → the notifications prompt, then the DEMO bar, MacBook and Desktop, a picture and a link,
      and under the bar a hint of what to try. After the first send the hint says where it went, and it goes once
      MacBook has answered.
- [ ] **+** › Photos with a real photo → "Sent to MacBook"; a few seconds later MacBook's notification shows over the
      open app, and a tap copies its text ("Copied").
- [ ] The first send, then the phone locked at once: the notification shows on the Lock Screen about 3 s later (iOS
      suspends Ferry within half a second of locking, so the app holds a background task until the reply is out),
      and its tap opens Ferry at the item.
- [ ] Tap screenshot.png → it opens; Save to Photos saves it.
- [ ] The share sheet during the demo still says "Open Ferry to set up a computer first."
- [ ] Leave Demo (the bar, and Settings) → back at setup; a QR code scanned then sets up a real computer.

## Ferry for Mac

With the Mac app running (`macos/build.sh --debug`), Tailscale on the Mac and the iPhone, and Nightdrive's Ferry on:
- [ ] The Mac shows up in the iPhone app's machine list by itself.
- [ ] Send Clipboard with a code on the iPhone → it is on the Mac's clipboard, with a "Copied from iphone" notification.
- [ ] Send Clipboard with a screenshot → on the Mac's clipboard, and the file in Downloads.
- [ ] A typed text from the iPhone → a notification with Copy, and the text is copied from it.
- [ ] A photo and a file from the iPhone → Downloads, with a notification whose Open and Show in Finder work. The item
  says `from: iphone` (`X-Forwarded-For` names the phone).
- [ ] Send Clipboard in the Mac's popover, with the pill on iphone → the iPhone gets a notification, and the item is in
  its Received.
- [ ] Mac → Nightdrive: Nightdrive picked in the pill, then Send Clipboard → on Nightdrive's clipboard; Aa → a
  notification there; **+** with two files → the bar in Send Clipboard moves, and both land in Nightdrive's Downloads.
- [ ] With the popover closed, a text from the iPhone → the icon shows ` 1`; opening the popover clears it.
- [ ] A file dragged from Finder and dropped on the icon → it goes to the device in the pill, and the icon shows a
  checkmark for a moment. Another dragged over the icon and on down to a device's tile in the popover → it goes there,
  and the pill stays as it was. Dragged over the popover and back out → the list comes back.
- [ ] In Received: a click on a text copies it ("Copied" for a moment), on a link opens the browser, on a file opens it;
  a file's row drags out into Finder; the context menu's Show in Finder, Quick Look, Share… and Remove work.
- [ ] A three-line text from the iPhone: one line in the row, three lines when pasted after Copy.
- [ ] A file deleted in Finder while listed: Open on its row does nothing and the row goes.
- [ ] Clear asks "Clear N items?" first; Cancel keeps them, Clear empties the list, and the files stay in Downloads.
- [ ] Aa: Return sends, Shift-Return starts a new line, Escape gives up.
- [ ] A send to Nightdrive while its Ferry is off → "Not sent" with the reason and Try Again; copy something else,
  then Try Again → the first thing goes, not the new clipboard.
- [ ] Nightdrive → Mac: `ferry send --to macbook hello` lands in the Mac's box with a notification.
- [ ] Nightdrive's PWA on a phone lists the Mac and sends to it, and gets a notification for what the Mac left it.
- [ ] The Mac asleep, then woken: the iPhone shows it again within seconds.
- [ ] Setup on a Mac where Ferry isn't published yet, and with Tailscale quit: the popover's step says so, Open
  Tailscale opens it, and the step clears by itself once Tailscale is on.
- [ ] Settings › Stop Publishing → the icon dims and the popover says "Ferry is off on this Mac"; quit and open Ferry
  → still off; Publish → back, and the iPhone reaches the Mac again.
- [ ] Notifications turned off for Ferry in System Settings → the popover's line says so, and Turn On… opens that pane.
- [ ] Add Device's QR code, scanned in the iPhone app's Add a Computer → it adds this Mac (or says it's already there).
      Scanned with the iPhone's Camera → Ferry opens and adds it the same way.
- [ ] The popover, Add Device and Settings with the Mac in light mode, then dark.
- [ ] A Tailscale refusal (e.g. Serve not enabled for the tailnet): the popover's "Tailscale said no" step stays put
  with Open in Browser for over 10 s, and nothing flickers back to "Putting Ferry on your tailnet…".
- [ ] **+** with a file to an asleep computer → the popover opens again by itself, with "Not sent" and Try Again.
- [ ] ⌘, with Ferry's Settings window in front: no blank second window.
- [ ] After plugging in or out a display (or hiding and showing the icon in the menu bar's settings), a file dropped on
  the icon still goes.
- [ ] A file from the iPhone over 4 GiB, or one with the Mac's disk nearly full: the phone says "Too big…" or "Not enough
  space…", not a connection error (the Mac answers before reading the body, through Tailscale's proxy).
- [ ] `curl -H 'Tailscale-User-Login: someone@else' -H 'X-Ferry: 1' https://<mac>.<tailnet>.ts.net/ferry/api/ping` from
  the Mac: still answered as the owner, since tailscale serve replaces the header (Ferry's gate rests on that).
- [ ] A file from the iPhone opened from its notification: macOS treats it as downloaded (Gatekeeper asks for an app or
  script document).

### Installing a release (`macos/build.sh --release`)

- [ ] Quit the debug Ferry, open `macos/build/Ferry-<version>-<build>.dmg`, drag Ferry to Applications and open it: no
  Gatekeeper warning.
- [ ] The first launch turns Open at Login on (Settings shows it), and asks once for notifications and once for
  Downloads.
- [ ] Opened while a debug Ferry still runs: "Ferry couldn't start" with Try Again; after quitting the debug one, Try
  Again works.
- [ ] Settings shows "Version 1.0.0 (<build>)", the build being the `.dmg`'s number.
- [ ] After a restart, Ferry is in the menu bar by itself, and the iPhone reaches the Mac.
