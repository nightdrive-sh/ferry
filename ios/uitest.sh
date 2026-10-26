#!/usr/bin/env bash
# ios/uitest.sh [-only-testing:FerryUITests/…] [mock flags…] — runs the UI tests in the simulator against a fresh
# tools/mock-ferry.py and a local push relay (relay/, handing pushes to the simulator with simctl), then prints what
# reached the fake computers and the simulator's clipboard.
#
#   ios/uitest.sh                                   every UI test
#   ios/uitest.sh -only-testing:FerryUITests/SendTests --down Nightdrive
set -euo pipefail
cd "$(dirname "$0")"

# xcode-select points to the Command Line Tools here; switching it would need sudo
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# The SDK is newer than the installed runtime, so a name= destination finds no "latest" OS: pick the device by id
SIM=${FERRY_SIM:-$(xcrun simctl list devices available | sed -n 's/^ *iPhone 17 Pro (\([0-9A-F-]*\)).*/\1/p' | head -1)}

ONLY=()
MOCK=()
for a in "$@"; do
  case "$a" in -only-testing:*) ONLY+=("$a") ;; *) MOCK+=("$a") ;; esac
done
# DownTests run only when a computer is down; TEST_RUNNER_ variables reach the test runner without the prefix
for ((i = 0; i < ${#MOCK[@]}; i++)); do [ "${MOCK[$i]}" = --down ] && export TEST_RUNNER_FERRY_DOWN="${MOCK[$((i + 1))]:-}"; done

LOG=build/mock.log
RELAY_LOG=build/relay.log
mkdir -p build
pkill -f '[m]ock-ferry.py' || true
pkill -f 'php -S 127.0.0.1:4728[0]' || true
# The relay as the app's -relay argument names it, with a database of its own each run
rm -f build/relay.sqlite*
FERRY_RELAY_DB="$PWD/build/relay.sqlite" FERRY_RELAY_ORIGIN=http://127.0.0.1:47280 FERRY_RELAY_APNS=simctl \
  FERRY_RELAY_SIMULATOR="$SIM" php -S 127.0.0.1:47280 -t ../relay/public > "$RELAY_LOG" 2>&1 &
RELAY_PID=$!
# python3-cryptography for the mock's notifications, which the Mac's Python doesn't have
uv run -q --with cryptography python3 ../tools/mock-ferry.py "${MOCK[@]+"${MOCK[@]}"}" > "$LOG" 2>&1 &
MOCK_PID=$!
trap 'kill $MOCK_PID $RELAY_PID 2>/dev/null || true' EXIT
sleep 2

xcrun simctl pbcopy "$SIM" <<< "" || true   # start from an empty clipboard
# A fresh install, so iOS asks for notifications again (NotificationTests answers it)
xcrun simctl uninstall "$SIM" fi.feature.ferry 2>/dev/null || true
status=0
xcodebuild -project Ferry.xcodeproj -scheme Ferry -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build/dd "${ONLY[@]+"${ONLY[@]}"}" test 2>&1 | grep -E "Test (Case|Suite).*(passed|failed)|error:|\*\* TEST" || status=$?

echo "==> the computers got:"
cat "$LOG"
echo "==> the simulator's clipboard: $(xcrun simctl pbpaste "$SIM")"
exit $status
