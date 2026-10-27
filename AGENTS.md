# Agent notes

Ferry is a mailbox between your devices over Tailscale. This repo holds its apps, its protocol (README) and both of its
servers: the Linux one (`linux/bin/ferry`), which came from Nightdrive's Ferry plugin, and the Mac app's
(`FerryKit/Sources/FerryServer`), written against `docs/protocol.md`. Nightdrive (`nightdrive-sh/nightdrive`, its own
repo and AGENTS.md) keeps its top bar menu for Ferry; its plugin still has its own copy of the server until it
installs Ferry from here.

**Where things are**
- `FerryKit/`: everything that isn't UI (models, HTTPBackend, machine list and target rule, labels, FerryModel). No
  UIKit in it, so a Mac app can use it and `swift test` runs it on the Mac.
- `FerryKit/Sources/FerryServer/`: the computer's side of the protocol, which the Mac app runs. HTTP on 127.0.0.1:47270
  (its own small HTTP/1.1 over `NWListener`, no dependency), the box, Tailscale, Web Push, the other computers. The
  system's parts are behind `FerrySystem`, `TailscaleCLI` and `Outbound`, so `swift test` drives it with fakes, and
  `ClientServerTests` runs the iPhone app's `HTTPBackend` against it. `TailscaleCommand` (macOS only) is the real
  `tailscale`, run from fixed paths, since an app opened at login has no shell PATH.
- `macos/`: the Mac app (macOS 26, bundle ID `fi.feature.ferry.mac`, no sandbox: it runs `tailscale serve`). An
  `NSStatusItem` with an `NSPopover` of SwiftUI, not `MenuBarExtra`: files are dropped on the icon, a dot on it says
  something arrived, and the popover says when it opens. `MenuModel` refreshes only while the popover is open; closed,
  its count of what is unseen follows `FerryServer.arrivals`. `macos/Ferry.xcodeproj` is hand-written like the iOS one, and uses
  `ios/Shared/Theme.swift`, `Colors.xcassets` and the fonts in place. Its state is `~/Library/Application Support/Ferry/`.
- `ios/`: the iPhone app (SwiftUI, iOS 26), its notification extension (`FerryNotifications/`), its share extension
  (`FerryShare/`) and its UI tests. `ios/Shared/` is built into both the app and the share extension: the theme
  (`Theme`, colour sets, fonts) and the share view, so the UI tests can show that view in the app. `ios/Ferry.xcodeproj` is hand-written with
  file-system-synchronized groups: a new file in `ios/Ferry/` needs no project edit, a new target does.
- **Adding a phone:** Add Device's QR code (Mac, Linux) is a link to `https://nightdrive.sh/ferry/add` with the
  computer's base URL in its fragment (`SetupAddress.link`, `add_link` in `linux/bin/ferry`). The iPhone app claims it
  as a universal link (`applinks:nightdrive.sh`; the `apple-app-site-association` is the website repo's,
  `nightdrive-sh/nightdrive-website`) and handles it in `FerryApp.opened`. The UI tests hand it to the app with
  `XCUIApplication.open`. iOS reads that file through Apple's CDN, which may answer 404 for a while after a change and
  then iOS opens the link in Safari: to try `simctl openurl` with the real link at once, build for the simulator with
  `CODE_SIGN_ENTITLEMENTS` pointing to a copy saying `applinks:nightdrive.sh?mode=developer` (read from the site itself).
- `linux/`: the Linux server, also the `ferry` command: `bin/ferry` is one Python file with no dependency beyond
  python3-cryptography (Web Push), and runs the desktop's tools (wl-clipboard, xclip, notify-send, xprintidle, gdbus,
  xdg-open). Notifications go over its own session bus connection with PyGObject's Gio where it has it (`Notifications`;
  GNOME tells only the connection that sent a notification which button was pressed, and Ubuntu 26.04's AppArmor
  profile keeps notify-send from asking for buttons at all), else through notify-send. `web/` is the page it serves to phones without the app (a PWA; `web/fonts` links to `ios/Shared/Fonts`).
  `systemd/ferry.service` is the user service, started with the session rather than the desktop, so `desktop_env()`
  finds the desktop's variables (from `systemctl --user show-environment`, else the Wayland and X11 sockets) when a tool
  needs them. Idle time comes from the compositor (ext-idle-notify, its own small Wayland client), Mutter's D-Bus
  IdleMonitor, `xprintidle` or logind, in that order. State is `~/.local/share/ferry`; `migrate()` moves Nightdrive's
  plugin's (`~/.local/share/nightdrive/ferry`) there once and turns off `nightdrive-ferry.service`. `install.sh`
  installs a release (or `--from linux`) into `~/.local/lib/ferry` and runs `ferry enable`. A desktop's own menu reads
  `ferry list --json` and hears of changes through `~/.config/ferry/hook`.
- `linux/app/`: the Linux app, the Mac popover's content as a GTK 4 window (`ferry app`, PyGObject, no libadwaita), in
  Ferry's own colours and JetBrains Mono. `ferry_app.py` gets `bin/ferry` as its `core` and only draws and runs things
  off the main loop: what it shows and does (setup steps `setup_step()`, sending `deliver()`, updates
  `check_update()`) is the server's, so `ferry list --json` says the same. `look.py` is what needs no GTK (the palette
  from `ios/Shared/Colors.xcassets`, the style sheet, Lucide icons, the words), tested on the Mac. The tray icon is a
  StatusNotifierItem with a dbusmenu, over Gio's D-Bus (GTK 4 has no tray), registered where a
  StatusNotifierWatcher runs (KDE, Ubuntu's GNOME, Waybar…); the login item (`app --background`) quits where none
  does. `ferry enable` installs the app entry (`sh.nightdrive.Ferry`), its icons, "Send with Ferry" in GNOME Files'
  Scripts, Dolphin's and Nemo's menus, and the tray's autostart unless `ferry tray off` (Nightdrive, whose top bar has
  Ferry's menu; `install.sh --no-tray`). The `.desktop` names only `application/octet-stream`: naming types from the
  user's own folder would make Ferry their default app. Updates: `ferry update` runs the newer release's own
  `install.sh` (GitHub's releases API, `FERRY_RELEASES` to test against a local one); a pre-release install follows
  pre-releases.
- `relay/`: the push relay at `https://push.nightdrive.sh` (plain PHP and SQLite), which holds Apple's push key and
  passes on the notifications it can't read. Its API is in `relay/README.md`, its tests: `cd relay && vendor/bin/phpunit`.
  The app moves a computer's subscription by itself when its address is at another relay (`PushPlanner`).
- `tools/mock-ferry.py`: fake computers (MacBook :47271, Nightdrive :47272, and Studio :47273, which answers only
  40 s after its first request, as a computer just set up does), because the simulator can't run
  Tailscale.
- `docs/protocol.md` is the contract between the apps and the computers. A change to either server's API updates it in
  the same piece of work, and the apps are built against it, not against `linux/bin/ferry`'s code.
- **Designs and plans are not in this repo.** `docs/superpowers/` is a private git repo of its own inside the working
  tree (ignored here; meant for `nightdrive-sh/ferry-design` on GitHub): `specs/`, `plans/`, `design/`, `app-store/`,
  and `internal.md`, what this file leaves out because it isn't public (where the relay runs and how it is deployed,
  how the test machines are reached, how the build number's base was chosen). Where it is checked out, read it: Phase
  1's spec says what the product is and why, so read it before changing behaviour. Commit there with
  `git -C docs/superpowers`; nothing in it may be quoted into this repo's files.

**Build and test**
- `xcode-select` points to the Command Line Tools: prefix `xcodebuild`, `xcrun` and `swift` with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the scripts do it themselves).
- `cd FerryKit && swift test`: the unit tests (Swift Testing), FerryKit's and FerryServer's. FerryKit work is test-first.
- `macos/build.sh --debug [-- <launch arguments>]`: builds the Mac app and runs it (quitting one already running). Its
  debug arguments: `-openPopover YES`, `-appearance dark|light`, `-setupState missing|off|notPublished|problem|stopped|starting|failed`,
  `-notifications denied|notDetermined`, `-showDropTiles YES`. `macos/shot.sh <out.png>` takes a picture of the popover
  (the terminal needs Screen Recording). Debug builds are signed with the team's Apple Development certificate, not
  ad hoc, so a permission given once (Downloads, notifications) holds across rebuilds. On launch the app publishes
  itself with `tailscale serve --bg --https=443 --set-path=/ferry http://127.0.0.1:47270`, which stays on after it
  quits; `tailscale serve --https=443 --set-path=/ferry off` takes it off.
- `cd linux && python3 -m unittest discover -s tests`: the Linux server's tests (stdlib unittest). On the Mac, with
  `uv run --no-project --with cryptography` in front, for the push tests. Desktop parts are tested against fakes (a
  pretend Wayland compositor, recorded commands); real desktops are for the Parallels VMs.
- **The Linux app in a VM** (Parallels: "Ubuntu 26.04 ARM64" GNOME, "Ferry KDE"; the Mac's home is
  `/media/psf/Home` there, so `install.sh --from /media/psf/Home/Projects/ferry/linux`): `prlctl exec` as the desktop
  user with the session's `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS` and `WAYLAND_DISPLAY`, pictures with
  `prlctl capture`. Nothing clicks there, so `ferry app --show=add|devices|device-list|more|compose|tiles|clipboard|update|setup|type=TEXT`
  opens that page or menu, or does that. `prlctl exec` fails ("Invalid argument") on some quoting: pass a script.
  Start the window with `systemd-run --user … ~/.local/bin/ferry app` (the user manager's PATH has no `~/.local/bin`):
  started straight from `prlctl exec` it is outside the desktop's session, and pkexec finds no password dialog for it.
  A VM switched to its snapshot keeps the snapshot's clock, and apt then refuses the archive as "not valid yet": set
  the time first. `ferry app --show=…` acts 1.5 s after it returns, so a picture taken at once shows the page before.
  By hand: GNOME shows a notification's buttons only once it is expanded (the arrow in its header); Ubuntu's
  AppIndicator opens the tray's menu on a click and the window on a double click; GNOME Files' Scripts give no
  activation token, so the window they open comes with GNOME's "Ferry is ready".
  A release to update from can be served without a web server: `FERRY_DOWNLOAD_URL` and `FERRY_RELEASES` take
  `file:///media/psf/Home/…` addresses. A GNOME polkit dialog doesn't show in `prlctl capture`, and KDE's pictures
  catch frames half drawn (black): take KDE's with `spectacle -b -n -f -o FILE` inside the session. GDM 50 starts no
  X11 session: for KDE on X11, stop gdm and `startx /usr/bin/startplasma-x11 -- :1 vt3` (with
  `/etc/X11/Xwrapper.config` saying `allowed_users=anybody`, `needs_root_rights=yes`). "Nightdrive Test" (Hyprland, no
  Parallels Tools) is reached over SSH (`internal.md`), behind Nightdrive's lock screen. A machine name new to the
  tailnet waits about half a minute for its certificate on the first request (`keep_warm()` asks it at once).
  Without a desktop, GTK 4.14 (Ubuntu 24.04's) runs under Broadway in an OrbStack machine (`gtk4-broadwayd`).
- `linux/tests/containers.sh [ubuntu] [debian] [fedora] [arch]`: the install script in fresh OrbStack machines
  (`ferry-test-<distro>`, deleted afterwards unless `--keep`): a Nightdrive computer's Ferry is set up, Ferry is
  installed with `curl … | bash` from a release `linux/release.sh` made and this Mac serves, and `tests/in-container.sh`
  checks the service, `api/items` with curl, the moved state and an update. `tests/fake-tailscale` stands in for
  Tailscale there. A few minutes per distribution.
- **The Mac app on a clean Mac** (Parallels "macOS", user `ferry`, over SSH as `internal.md` says; snapshot
  `clean` never ran Ferry or Tailscale, `clean-vnc` is the same with Screen Sharing on): a release build with
  `--local-feed http://127.0.0.1:8484`, its folder served on this Mac and `ssh -R 8484:127.0.0.1:8484` into the VM, so
  Safari downloads it with a real quarantine and Sparkle updates from it. Clicks over VNC (vncdotool, the VM user's
  password) work in ordinary windows, but security dialogs (Gatekeeper, VPN configurations) and the menu bar ignore
  them, and none arrive while the VM's window is open in Parallels. Keys from `prlctl send-key-event` are real: `-s`
  takes PC scancodes, `-k` XFree86 keycodes (arrows 98/100/102/104, ⌘ 115); Gatekeeper's Open is Return, and
  Control-F8, arrows and space open Ferry's popover. The login window doesn't type `-` from either layout's key.
- `ios/uitest.sh`: builds the app, starts the mock and runs the UI tests, then prints what reached the fake computers
  and the simulator's clipboard. Tests for computers that don't answer run only with
  `ios/uitest.sh --down Nightdrive` (DownTests) and `--down MacBook,Nightdrive` (OfflineTests).
- **The simulator** is picked by id, not by name: the SDK is newer than the installed runtime, so `name=` finds no
  "latest" OS.
- **Debug launch arguments** used by the tests: `-reset`, `-mock`, `-seedClipboard TEXT`, `-seedClipboardImage`, `-seedClipboardPhoto jpeg|heic`,
  `-seedMachines`, `-pasteHelpSeen YES`, and `-shareText TEXT` / `-shareImage`, which show the share view over the app. The test runner must not write the clipboard itself: the app's read would stop
  at iOS's Paste prompt, which blocks its main thread.
- **Screenshots:** `xcrun simctl io <id> screenshot`. Don't drive the Simulator window: XCUITest runs headless, and the
  user may be working on this Mac.
- `docs/testing-on-device.md` is the checklist for a real iPhone: add a line when a change needs one.

**Branches and releases**
- Work happens in `dev`, and `main` is an earlier point of it (`git merge --ff-only dev` at a release). Check the branch
  before committing. The remote is `nightdrive-sh/ferry` on GitHub; pushing is the user's decision.
- `linux/release.sh [--beta N]` makes a GitHub Release's Linux files in `linux/build/` (`ferry-linux.tar.gz`,
  `install.sh`); the version is `VERSION` in `linux/bin/ferry`, with `-beta.N` added in the tarball for a pre-release.
- Every platform has the same version (1.0.0), and a release is tagged `v<version>` or `v<version>-beta.N` with the
  Mac `.dmg` and the Linux files as its GitHub Release's assets.
- `ios/build.sh` uploads to TestFlight and spends a build number (`tools/build-number.sh`: a base
  above every number spent before the public history, plus the commit count). Run it only when asked.
  `ios/build.sh --archive-only` checks the archive without signing or uploading.
- `macos/build.sh --release` makes `macos/build/Ferry-<version>-<build number>.dmg`: Developer ID signed (hardened
  runtime, secure timestamp), the app and the `.dmg` notarized and stapled, and checked with Gatekeeper, also as a
  quarantined download. It needs the team's Developer ID Application certificate and `ios/.env`'s App Store Connect API
  key, and it publishes nothing: the `.dmg` is handed out by Jari. `--dry-run` stops before anything goes to Apple.
  The `.dmg`'s window (background in `macos/dmg/`, rendered from its SVG) is laid out by Finder during the build, so a
  Finder window flashes up, the terminal needs Automation access to Finder, and no other "Ferry" disk may be mounted.
- **Before a Mac build goes to anyone but Jari:** the App Store version of Tailscale checked (a Mac VM's App Store
  wouldn't sign in). Done in phase 4 on a clean Mac: Sparkle's update, the standalone and open-source Tailscale, and
  Open at Login on by default and opening Ferry at login.
- App Store identity: "Ferry: Device Mailbox", bundle ID `fi.feature.ferry`, App Group `group.fi.feature.ferry`, team
  279G2UNHPN.

**Conventions**
- English comments that explain why. Commit messages are English sentences saying what the user gets, e.g. "Ferry for
  iOS: the machine list remembers computers that sleep".
- Colours come only from `Theme` (the asset catalog's colour sets, light and dark), content text in JetBrains Mono
  (`Font.mono`), chrome in the system font.
- Copy is English, and setup texts say "a computer running Ferry", not Nightdrive: Ferry is meant for anyone on
  Tailscale.
- Tailscale is the security layer: nothing may expose a computer to the internet or let another tailnet user in.
