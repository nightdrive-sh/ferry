# Ferry

A mailbox between your devices, over [Tailscale](https://tailscale.com).

Send texts, links, photos, files and the clipboard between your phone and your computers. Copy a code on the phone, press Send Clipboard, paste it on the computer. What a computer sends waits in its box until your phone or another computer picks it up, and the phone is notified when a computer sends it something.

Tailscale connects the devices, encrypts the traffic and keeps Ferry off the internet. Each computer answers only its owner, and only on the tailnet (`tailscale serve`, not Funnel). Your texts and files never pass through a server of ours: only a notification does, encrypted for the phone, on its way to Apple. Ferry trusts everyone who can use the computer it runs on, so it suits a computer that is yours alone. A computer's tailnet name shows in public certificate logs, as every Tailscale HTTPS name does.

Ferry is made by [Nightdrive](https://nightdrive.sh). More, and the privacy policy: [nightdrive.sh/ferry](https://nightdrive.sh/ferry).

**Ferry is in public beta.** The iPhone app is on [TestFlight](https://testflight.apple.com/join/qSG41FTp), and the Mac and Linux versions are on the [releases](https://github.com/nightdrive-sh/ferry/releases) page. Tell us what works and what doesn't: [Feedback and support](#feedback-and-support).

## Getting it

You need Tailscale on every device, signed in as the same user, with **MagicDNS and HTTPS certificates** turned on for your tailnet (the admin console's DNS page). Then a computer running Ferry, and the iPhone app.

- **iPhone** (iOS 26): "Ferry: Device Mailbox", a public beta on [TestFlight](https://testflight.apple.com/join/qSG41FTp); on the App Store at 1.0. It finds your computers running Ferry by itself; Add Device on one of them shows a QR code that adds it.
- **Mac** (macOS 26): the `.dmg` from [nightdrive.sh/ferry](https://nightdrive.sh/ferry) or the [releases](https://github.com/nightdrive-sh/ferry/releases). A menu bar app: drop files on its icon to send them, and its popover shows what arrived. It keeps itself up to date, and works with Tailscale from the App Store, the standalone app or the open-source `tailscaled`.
- **Linux**: one line, below ([On Linux](#on-linux)).

**Adding a phone:** Add Device on a computer shows a QR code of a link to `https://nightdrive.sh/ferry/add`, with the computer's address in the link's fragment, which a browser never sends, so the site doesn't learn the computer's name. The iPhone's Camera opens the link in the Ferry app, which adds the computer, and the app's own scanner reads it too. Without the app, the page says what is needed.

## On Linux

```sh
curl -fsSL https://nightdrive.sh/ferry/install | bash
```

The script ([`linux/install.sh`](linux/install.sh), meant to be read) installs what Ferry uses with apt, dnf or pacman (Ubuntu 24.04 and Debian 13 or later, Fedora, Arch), puts Ferry in `~/.local/lib/ferry` with the `ferry` command in `~/.local/bin`, and starts it as a systemd user service, `ferry.service`, published on the tailnet with `tailscale serve` at `https://<computer>.<tailnet>.ts.net/ferry/`. Run again, it updates Ferry. `--beta` takes pre-releases too, `--from linux` installs a checkout's `linux/` folder instead of downloading, and `--no-tray` leaves out the tray icon.

**Ferry's window** is in the desktop's apps as "Ferry": what your devices sent (click a text to copy it, a file to open it, or drag it out), the device sends go to, and **Aa** (type a text), **Send Clipboard** and **+** (files). Files dropped on the window go to the device you drop them on, and Add Device shows the QR code for a phone. Until Ferry can be reached, the window says what's missing (Tailscale, its login, HTTPS certificates, the right to publish, the server) and does what it can by itself. Where the desktop has a tray (KDE, Ubuntu's GNOME, Cinnamon, XFCE, Waybar), Ferry's icon sits there from login with a count of what arrived; a click opens the window. "Send with Ferry" in the file manager (GNOME Files: Scripts; Dolphin; Nemo) and Open With in KDE send the files you picked. When a newer release is out, the window says so and installs it with one button, as `ferry update` does; a beta install follows betas.

It needs Tailscale with MagicDNS and HTTPS certificates turned on for the tailnet (the admin console's DNS page), and the right to publish without sudo, which the script gives if Tailscale is there (`sudo tailscale set --operator=$USER`).

A computer that ran Nightdrive's Ferry plugin keeps everything: its state (the box, the phones' notifications, the computers it knows) moves from `~/.local/share/nightdrive/ferry` to `~/.local/share/ferry`, and the plugin's `nightdrive-ferry.service` is turned off.

**The `ferry` command** does what the apps do, and `ferry help` lists all of it:

| Command | What it does |
| --- | --- |
| `ferry send [file…]` | Sends files, or a text; with nothing, the clipboard. `--to DEVICE` for another device than the picked one |
| `ferry devices` | Your other computers running Ferry and your phones, the picked one marked |
| `ferry target [DEVICE]` | The device sends go to, or picks another |
| `ferry list` | What's in the box, numbered |
| `ferry get [n]` | An item from the phone (the newest without a number): a text printed, a file saved here |
| `ferry open <n>` / `ferry copy <n>` | Opens a file, copies a text |
| `ferry qr` | Add Device's QR code, for adding a phone (`ferry url` is the address itself) |
| `ferry enable` / `ferry disable` | The service on or off, with its address on the tailnet |
| `ferry app [file…]` | Ferry's window; with files, it sends them to the device you pick |
| `ferry update [--check]` | Installs the newest release, or says whether there is one |
| `ferry tray [on\|off]` | Whether the tray icon starts with your desktop |
| `ferry status`, `ferry version` | Whether it runs, and which Ferry it is |

Files from your devices go to Downloads, with a notification. What a phone sends with Send Clipboard lands on the computer's clipboard (wl-clipboard on Wayland, xclip on X11). A phone without the app (an Android phone) can use the page a Linux computer serves, which does in the browser what the app does: the QR code's page leads to it, and it can be added to the Home Screen. The Mac app serves no such page. Ferry sends to the computer you're using: on GNOME it asks Mutter how long the computer has been idle, on KDE, Hyprland and other Wayland desktops the compositor, on X11 the X server.

**For a desktop's own Ferry menu** (Nightdrive's top bar is one): `ferry list --json` is the box and Ferry's state (with `setup`, what stands in the way and what to do, and `update`, a newer release), and an executable `~/.config/ferry/hook` runs with `changed` when the box changes or a send goes, and with `picked` after `ferry pick`'s dialog.

To remove Ferry: `ferry disable`, then remove `~/.local/lib/ferry`, `~/.local/bin/ferry`, `~/.config/systemd/user/ferry.service` and the files named `sh.nightdrive.Ferry*` and `*ferry*` that the install script's header lists (the app's entry, icons, autostart and file manager menus). Its state stays in `~/.local/share/ferry`.

## Feedback and support

Ferry is in beta, so every report helps: say which devices and systems you use.

- **Questions, help with setup, ideas:** [hello@nightdrive.sh](mailto:hello@nightdrive.sh).
- **Something broken:** [an issue](https://github.com/nightdrive-sh/ferry/issues) on GitHub.
- **On the iPhone:** take a screenshot in Ferry and send it from TestFlight.

## What's here

- **`docs/protocol.md`**: how the apps talk to a computer running Ferry. Both servers answer it, and anything else that answers it is a Ferry too.
- **`FerryKit/`**: the Swift package with everything that isn't UI: the client, the machine list, the app's state. **`FerryKit/Sources/FerryServer/`** is a computer's side of the protocol in Swift, which the Mac app runs.
- **`ios/`**: the iPhone app, its notification extension and its share extension.
- **`macos/`**: the Mac app.
- **`linux/`**: the Linux server and `ferry` command (`linux/bin/ferry`, one Python file), its window and tray icon (`linux/app/`, GTK 4), the page it serves to phones without the app (`linux/web/`), its systemd user service and its install script.
- **`relay/`**: the push relay at `push.nightdrive.sh` (PHP and SQLite), which holds Apple's push key and passes on the notifications it can't read (its README has the API).
- **`tools/`**: fake computers for the simulator (`mock-ferry.py`), which can't run Tailscale, and the build number.

## Development

On a Mac with Xcode 27. If `xcode-select` points to the Command Line Tools, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the scripts do it themselves).

- `cd FerryKit && swift test`: the package's tests, the Mac's server too.
- `cd linux && python3 -m unittest discover -s tests`: the Linux server's and window's tests. On a Mac, `uv run --no-project --with cryptography python3 -m unittest discover -s tests` brings the module notifications need.
- `cd relay && composer install && vendor/bin/phpunit`: the relay's tests.
- `linux/tests/containers.sh [ubuntu] [debian] [fedora] [arch]`: installs Ferry with its install script in fresh [OrbStack](https://orbstack.dev) machines, the way a user does, and checks that it runs and answers.
- `macos/build.sh --debug` builds the Mac app and runs it; `macos/shot.sh` takes a picture of its popover.
- `ios/uitest.sh` runs the iPhone app's UI tests in the simulator against `tools/mock-ferry.py`. For a look by hand: `python3 tools/mock-ferry.py`, then the app launched with `-mock`.
- `docs/testing-on-device.md` is the checklist for a real iPhone with Tailscale.

The signing identity (team, bundle IDs, App Group) is Ferry's own: to run the apps on your own devices, change them in the Xcode projects.

**Releases** are GitHub Releases tagged `v<version>` (`v<version>-beta.N` for a pre-release), with the same version on every platform:
- `linux/release.sh [--beta N]` makes the Linux files, `ferry-linux.tar.gz` and `install.sh`. Their names carry no version, so `releases/latest/download/<name>` always finds the latest.
- `macos/build.sh --release [--beta N]` makes the Mac's `.dmg`, Developer ID signed, notarized and stapled, and its item for the update feed (`docs/mac-releases.md`). `--dry-run` sends nothing to Apple.
- `ios/build.sh` uploads the iPhone app to TestFlight; `--archive-only` checks that it archives.
- Build numbers come from `tools/build-number.sh`: a base plus the commit count, so they only grow.

## Licence

MIT (see [LICENSE](LICENSE)): free to use, read and reuse, and what is released stays that way.

Ferry is made by [Nightdrive](https://nightdrive.sh), sponsored by Feature Design Oy.
