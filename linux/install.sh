#!/usr/bin/env bash
# Installs Ferry on this Linux computer for you (not system-wide), or updates it, and starts it:
#
#   curl -fsSL https://github.com/nightdrive-sh/ferry/releases/latest/download/install.sh | bash
#
# What it does, in order:
#   1. Installs what Ferry uses with the distribution's package manager (apt, dnf or pacman, through sudo), only what
#      is missing: Python and its cryptography module (notifications), wl-clipboard and xclip (the clipboard on Wayland
#      and X11), notify-send, xprintidle (idle time on X11), qrencode (Add Device's QR code), xdg-utils, gdbus and
#      xdg-user-dirs; on a computer with a desktop also GTK 4 and its Python bindings, for Ferry's window.
#   2. Downloads Ferry's latest release from GitHub (with --beta, the latest pre-release too) into ~/.local/lib/ferry,
#      and links the ferry command into ~/.local/bin.
#   3. If Tailscale is installed, lets you publish Ferry on your tailnet without sudo: sudo tailscale set --operator=$USER
#   4. Runs `ferry enable`: Ferry's systemd user service (ferry.service) starts now and with every login, and
#      tailscale serve publishes it at https://<this computer>.<tailnet>.ts.net/ferry/ for your devices only. Ferry is
#      put in your desktop's apps, "Send with Ferry" in the file managers' menus (GNOME Files has it under Scripts),
#      and its tray icon starts with your desktop where it has a tray. A Ferry from Nightdrive's plugin is replaced, and its box, phones and notifications come
#      along.
#
# Options:
#   --beta          the latest release, pre-releases included
#   --from PATH     a release's ferry-linux.tar.gz, or a checkout's linux/ folder, instead of downloading
#   --no-packages   skip step 1
#   --no-tray       no tray icon at login (a desktop with its own Ferry menu, like Nightdrive's top bar); it stays off
#                   across updates, and `ferry tray on` brings it back
#
# Ferry's update (the button in its window, or `ferry update`) runs this script again. Without a terminal to ask for
# your password, it asks with the desktop's own dialog (pkexec), and only if a package is missing.
#
# To remove Ferry: ferry disable, then rm -r ~/.local/lib/ferry ~/.local/bin/ferry ~/.config/systemd/user/ferry.service
# ~/.local/share/applications/sh.nightdrive.Ferry.desktop ~/.config/autostart/sh.nightdrive.Ferry.desktop
# ~/.local/share/icons/hicolor/*/apps/sh.nightdrive.Ferry.png "$HOME/.local/share/nautilus/scripts/Send with Ferry"
# ~/.local/share/kio/servicemenus/sh.nightdrive.Ferry.desktop ~/.local/share/nemo/actions/ferry.nemo_action
# (its state, with the box, is ~/.local/share/ferry).
set -euo pipefail

REPO=nightdrive-sh/ferry
ASSET=ferry-linux.tar.gz
LIB=$HOME/.local/lib/ferry
BIN=$HOME/.local/bin

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf 'Ferry: %s\n' "$*" >&2; exit 1; }

# sudo where it can ask for the password (a terminal, even under curl | bash), else the desktop's dialog: Ferry's
# update button runs this script without a terminal
as_root() {
  if sudo -n true 2>/dev/null || ( : </dev/tty ) 2>/dev/null; then
    sudo "$@"
  elif command -v pkexec >/dev/null; then
    pkexec "$@"
  else
    fail "this needs root, and there's no terminal or pkexec to ask with: run it in a terminal"
  fi
}

# A desktop to show Ferry's window on: a computer without one (a server) gets the server only, without GTK
has_desktop() {
  compgen -G "/usr/share/wayland-sessions/*.desktop" >/dev/null || compgen -G "/usr/share/xsessions/*.desktop" >/dev/null
}

# The packages of $@ that aren't installed, for the package manager $1
missing_packages() {
  local manager=$1 p
  shift
  for p in "$@"; do
    case $manager in
      apt) [[ $(dpkg-query -W -f='${Status}' "$p" 2>/dev/null) == *"ok installed" ]] || echo "$p" ;;
      dnf) rpm -q --whatprovides "$p" >/dev/null 2>&1 || echo "$p" ;;
      pacman) pacman -T "$p" >/dev/null || echo "$p" ;;
    esac
  done
}

package_manager() {
  local id=""
  # shellcheck disable=SC1091
  [[ -r /etc/os-release ]] && id=$(. /etc/os-release; echo " ${ID:-} ${ID_LIKE:-} ")
  case $id in
    *" debian "*|*" ubuntu "*) echo apt ;;
    *" fedora "*|*" rhel "*) echo dnf ;;
    *" arch "*) echo pacman ;;
    *) for m in apt-get dnf pacman; do command -v $m >/dev/null && { echo "${m%-get}"; return; }; done ;;
  esac
}

install_packages() {
  local manager missing pkgs app
  manager=$(package_manager)
  case $manager in
    apt)
      pkgs="python3 python3-cryptography wl-clipboard xclip xprintidle libnotify-bin qrencode xdg-utils libglib2.0-bin
        xdg-user-dirs curl ca-certificates"
      app="python3-gi gir1.2-gtk-4.0 librsvg2-common" ;;
    dnf)
      # No xprintidle: Fedora hasn't packaged it, and its GNOME and KDE have no X11 session any more
      pkgs="python3 python3-cryptography wl-clipboard xclip libnotify qrencode xdg-utils glib2 xdg-user-dirs curl"
      app="python3-gobject gtk4 librsvg2" ;;
    pacman)
      pkgs="python python-cryptography wl-clipboard xclip xprintidle libnotify qrencode xdg-utils glib2 xdg-user-dirs curl"
      app="python-gobject gtk4 librsvg" ;;
    *)
      fail "no apt, dnf or pacman here. Install Python 3 with cryptography, wl-clipboard, xclip, xprintidle, notify-send,
qrencode, xdg-utils and gdbus (and for the window PyGObject with GTK 4) yourself, then run this again with --no-packages" ;;
  esac
  has_desktop || app=""
  # shellcheck disable=SC2086
  missing=$(missing_packages "$manager" $pkgs $app | xargs)
  [[ -n $missing ]] || return 0
  say "Installing what Ferry uses ($manager): $missing"
  case $manager in
    apt)
      # Ubuntu's unattended upgrades hold the lock for a while after a computer starts: wait for them, as apt does
      # when asked (it says "Waiting for cache lock"), rather than stop
      as_root apt-get -o DPkg::Lock::Timeout=600 update -qq </dev/null
      # shellcheck disable=SC2086
      as_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq \
        --no-install-recommends $missing </dev/null ;;
    dnf)
      # shellcheck disable=SC2086
      as_root dnf install -y -q $missing </dev/null ;;
    pacman)
      # Only what's missing: on Arch, upgrading one installed package without the rest (pacman -S curl on a system a
      # little behind) can break the others
      # shellcheck disable=SC2086
      as_root pacman -S --noconfirm $missing </dev/null \
        || fail "pacman couldn't install them: update the system first (sudo pacman -Syu), then run this again" ;;
  esac
}

# The download address of the latest release's tarball. GitHub's "latest" skips pre-releases, so with --beta it is
# the newest release that has the tarball, whatever it is.
release_url() {
  local beta=$1
  if [[ -n ${FERRY_DOWNLOAD_URL:-} ]]; then
    echo "$FERRY_DOWNLOAD_URL"
  elif (( ! beta )); then
    echo "https://github.com/$REPO/releases/latest/download/$ASSET"
  else
    curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=20" | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    for a in r.get("assets", []):
        if not r.get("draft") and a.get("name") == sys.argv[1]:
            print(a["browser_download_url"])
            sys.exit()
sys.exit("no release has " + sys.argv[1])' "$ASSET"
  fi
}

# Ferry's files from a checkout's linux/, a tarball or the release, into the folder $2
fetch() {
  local from=$1 dest=$2 beta=$3 url
  mkdir "$dest/ferry"
  if [[ -d $from ]]; then
    say "Installing Ferry from $from"
    cp -RL "$from/bin" "$from/web" "$from/systemd" "$from/app" "$dest/ferry/"
  else
    if [[ -n $from ]]; then
      [[ -f $from ]] || fail "no such file: $from"
      cp "$from" "$dest/$ASSET"
    else
      url=$(release_url "$beta") || fail "couldn't find a release of Ferry"
      say "Downloading Ferry: $url"
      curl -fL --progress-bar -o "$dest/$ASSET" "$url" || fail "couldn't download $url"
    fi
    tar -xzf "$dest/$ASSET" -C "$dest" 2>/dev/null || fail "$ASSET isn't a Ferry release"
  fi
  [[ -f $dest/ferry/bin/ferry && -d $dest/ferry/web && -f $dest/ferry/systemd/ferry.service ]] \
    || fail "that isn't a Ferry release (bin/ferry, web/ and systemd/ferry.service)"
  find "$dest/ferry" -name __pycache__ -prune -exec rm -rf {} +
  chmod +x "$dest/ferry/bin/ferry"
}

# All in functions, so that bash has read the whole script before it runs any of it (curl … | bash)
main() {
  local beta=0 from="" packages=1 tray=1 tmp version
  while (( $# )); do
    case $1 in
      --beta) beta=1 ;;
      --from) from=${2:?--from needs a path}; shift ;;
      --no-packages) packages=0 ;;
      --no-tray) tray=0 ;;
      -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
      *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
  done

  (( EUID != 0 )) || fail "run this as yourself, not as root: Ferry is installed for one user, and asks sudo for what needs it"
  command -v systemctl >/dev/null || fail "Ferry runs as a systemd user service, and this system has no systemd"

  # 1. Packages
  (( ! packages )) || install_packages

  # 2. Ferry. The new copy goes in whole, then replaces the old one, so a failed copy leaves the old one working.
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064   # expanded now on purpose: tmp is main's own, gone when the trap runs
  trap "rm -rf '$tmp'" EXIT
  fetch "$from" "$tmp" "$beta"
  version=$(python3 "$tmp/ferry/bin/ferry" version) || fail "this Ferry doesn't run here (python3 bin/ferry version)"
  mkdir -p "$(dirname "$LIB")" "$BIN"
  rm -rf "$LIB.new" "$LIB.old"
  cp -R "$tmp/ferry" "$LIB.new"
  [[ ! -e $LIB ]] || mv "$LIB" "$LIB.old"
  mv "$LIB.new" "$LIB"
  rm -rf "$LIB.old"
  ln -sfn "$LIB/bin/ferry" "$BIN/ferry"   # also over Nightdrive's plugin's ferry
  say "Ferry $version is in $LIB"

  # 3. Tailscale's permission, unless this user has it already (an update)
  if command -v tailscale >/dev/null \
      && ! tailscale debug prefs 2>/dev/null | grep -q "\"OperatorUser\": \"$USER\""; then
    say "Letting $USER publish Ferry on the tailnet: sudo tailscale set --operator=$USER"
    as_root tailscale set --operator="$USER" </dev/null \
      || echo "That didn't work. Once Tailscale is running, run it yourself, then: ferry enable" >&2
  fi
  (( tray )) || "$LIB/bin/ferry" tray off

  # 4. The service
  systemctl --user show-environment >/dev/null 2>&1 \
    || fail "no systemd user session to run Ferry in. Log in to this computer (or: sudo loginctl enable-linger $USER), then run this again"
  say "Starting Ferry"
  echo
  if "$LIB/bin/ferry" enable </dev/null; then
    echo
    # An update (or a move from Nightdrive's plugin) already has its phones: asking to add one again would mislead
    phones=$("$LIB/bin/ferry" list --json 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin).get("push") or 0)' 2>/dev/null) || phones=0
    if (( ${phones:-0} > 0 )); then
      say "Ferry is on, and in your apps."
    else
      say "Ferry is on, and in your apps. Add your phone: Add Device in Ferry's window, or ferry qr in a terminal."
    fi
  elif ! command -v tailscale >/dev/null; then
    echo
    say "Ferry is running. Your devices reach it over Tailscale, which isn't installed:"
    echo "  1. Install Tailscale: https://tailscale.com/download/linux"
    echo "  2. Log in: sudo tailscale up"
    echo "  3. Turn on HTTPS certificates for your tailnet: https://login.tailscale.com/admin/dns"
    echo "  4. Run: sudo tailscale set --operator=\$USER, then: ferry enable"
  else
    echo
    say "Ferry is running, but not on your tailnet yet: see above, then run: ferry enable"
  fi
  case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "Note: $BIN isn't in your PATH, so the ferry command needs its full path ($BIN/ferry) until you add it." ;;
  esac
}

main "$@"
