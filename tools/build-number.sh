#!/usr/bin/env bash
# tools/build-number.sh — the build number of the commit checked out, for ios/build.sh and macos/build.sh: a base plus
# the commit count. App Store Connect and Sparkle both want every build's number above the last one's, and the count
# only grows and names the tree a build came from. The base is above every number spent before the public repo's history
# began at its first commit (TestFlight's highest was 118, the Mac's 129), so the count could start again from 1.
set -euo pipefail
BASE=200
echo $((BASE + $(git -C "$(dirname "$0")" rev-list --count HEAD)))
