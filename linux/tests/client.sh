#!/usr/bin/env bash
# The iPhone app's client (FerryKit's HTTPBackend) against the Linux server that tests/containers.sh installed in a
# test machine: FerryKitTests' LinuxServerTests, run on this Mac through an SSH tunnel to the machine's 127.0.0.1:47270.
#
#   linux/tests/client.sh ferry-test-<distro>   (a machine left by containers.sh --keep, or one it is testing)
#
# For the run the machine's tests/fake-tailscale names it 127.0.0.1, the address the client reaches it at, and xclip
# is a pretend clipboard on a pretend X11 display; both are put back afterwards.
set -euo pipefail
m=${1:?usage: client.sh <machine>}
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

as_root() { orb -m "$m" -u root bash -s; }
as_user() { orb -m "$m" bash -s; }

as_root <<'EOF'
grep -q "fake tailscale" /usr/local/bin/tailscale || { echo "$(hostname) isn't a test machine" >&2; exit 1; }
echo 127.0.0.1 > /tmp/fake-tailscale-name
chmod 644 /tmp/fake-tailscale-name
cat > /usr/local/bin/xclip <<'XCLIP'
#!/bin/sh
# xclip for tests/client.sh: keeps what goes onto the clipboard in /tmp/fake-clipboard
echo "$*" > /tmp/fake-clipboard.args
cat > /tmp/fake-clipboard
XCLIP
chmod 755 /usr/local/bin/xclip
mkdir -p /tmp/.X11-unix
touch /tmp/.X11-unix/X0   # a display for desktop_env() to find; nothing draws on it
EOF

# A port free on this Mac for the tunnel (Ferry for Mac may have 47270)
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
ssh -F ~/.orbstack/ssh/config -o ExitOnForwardFailure=yes -N -L "$port:127.0.0.1:47270" "$m@orb" &
tunnel=$!
cleanup() {
  kill "$tunnel" 2>/dev/null || true
  as_root <<'EOF' || true
rm -f /tmp/fake-tailscale-name /usr/local/bin/xclip /tmp/.X11-unix/X0 /tmp/fake-clipboard /tmp/fake-clipboard.args
EOF
}
trap cleanup EXIT
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.2; done

FERRY_LINUX_URL="http://127.0.0.1:$port/ferry/" FERRY_LINUX_SHELL="orb -m $m bash -s" \
  swift test --package-path FerryKit --filter LinuxServerTests 2>&1 | grep -v "^\[[0-9]*/[0-9]*\]"
