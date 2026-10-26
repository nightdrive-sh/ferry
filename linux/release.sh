#!/usr/bin/env bash
# Makes the Linux files of a GitHub Release in linux/build:
#   ferry-linux.tar.gz   ferry/ with bin/, app/ (the window), web/ (the fonts in it, not linked) and systemd/
#   install.sh           the install script, which downloads the tarball
# Their names carry no version, so https://github.com/nightdrive-sh/ferry/releases/latest/download/<name> always finds
# the latest. The version is bin/ferry's VERSION.
#
#   linux/release.sh [--beta N]
#   --beta N   the release is v<VERSION>-beta.N, a pre-release: the tarball's bin/ferry says that version, so the install
#              follows pre-releases until it updates to the full release (as the Mac's build.sh --beta does)
set -euo pipefail
cd "$(dirname "$0")"

beta=""
case "${1:-}" in
  --beta) [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "usage: linux/release.sh [--beta N]" >&2; exit 1; }; beta=$2 ;;
  "") ;;
  *) echo "usage: linux/release.sh [--beta N]" >&2; exit 1 ;;
esac

version=$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' bin/ferry)
[[ -n $version ]] || { echo "No VERSION in bin/ferry" >&2; exit 1; }
[[ $version != *-* ]] || { echo "bin/ferry's VERSION ($version) should be a plain version: --beta N adds the suffix" >&2; exit 1; }
rm -rf build
mkdir -p build/ferry
cp -RL bin app web systemd build/ferry/
if [[ -n $beta ]]; then
  version="$version-beta.$beta"
  sed -i.orig "s/^VERSION = \".*\"$/VERSION = \"$version\"/" build/ferry/bin/ferry && rm build/ferry/bin/ferry.orig
fi
find build -name __pycache__ -prune -exec rm -rf {} +
# No macOS metadata (._ files, extended attributes) for GNU tar to trip over
COPYFILE_DISABLE=1 tar --no-xattrs --uid 0 --gid 0 -czf build/ferry-linux.tar.gz -C build ferry
rm -rf build/ferry
cp install.sh build/install.sh
echo "Ferry for Linux $version: linux/build/ferry-linux.tar.gz and linux/build/install.sh (tag v$version${beta:+, a pre-release})"
