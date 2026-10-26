#!/usr/bin/env bash
# ios/appstore-shots.sh [--appearance dark|light] [out-folder] — the App Store's screenshots, in the demo, on simulators
# of their own (made here, deleted afterwards), so a simulator another run uses is left alone. FerryUITests/AppStoreShots
# walks the demo and asks for each picture; this script takes it with `simctl io screenshot`, under a 9:41 status bar.
#
#   ios/appstore-shots.sh                  → build/appstore-shots/dark/{6.9,6.3}/1-arrived.png …
set -euo pipefail
cd "$(dirname "$0")"
# App Store Connect refuses a screenshot with an alpha channel, which simctl's PNGs have
command -v magick > /dev/null || { echo "needs ImageMagick (brew install imagemagick)" >&2; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

APPEARANCE=dark
if [ "${1:-}" = --appearance ]; then APPEARANCE=$2; shift 2; fi
OUT=$(mkdir -p "${1:-build/appstore-shots}/$APPEARANCE" && cd "${1:-build/appstore-shots}/$APPEARANCE" && pwd)
RUNTIME=$(xcrun simctl list runtimes available | sed -n 's/^iOS 26.* - \(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]*\).*/\1/p' | tail -1)

# The App Store's sizes: 6.9" (1320×2868, the one required) and 6.3" (1206×2622)
SIZES=("6.9:iPhone 17 Pro Max" "6.3:iPhone 17 Pro")
MADE=()
trap 'for d in "${MADE[@]+"${MADE[@]}"}"; do xcrun simctl shutdown "$d" 2>/dev/null || true; xcrun simctl delete "$d" || true; done' EXIT

for entry in "${SIZES[@]}"; do
  size=${entry%%:*} model=${entry#*:}
  dir="$OUT/$size"
  rm -rf "$dir" && mkdir -p "$dir"
  sim=$(xcrun simctl create "Ferry Shots $size" "$model" "$RUNTIME")
  MADE+=("$sim")
  # In English with a US clock and keyboard, whatever the Mac speaks: set, then booted again for SpringBoard to read
  xcrun simctl boot "$sim"
  xcrun simctl bootstatus "$sim" > /dev/null
  xcrun simctl spawn "$sim" defaults write -g AppleLanguages -array en
  xcrun simctl spawn "$sim" defaults write -g AppleLocale en_US
  xcrun simctl spawn "$sim" defaults write -g AppleKeyboards -array "en_US@sw=QWERTY;hw=Automatic"
  xcrun simctl shutdown "$sim"
  xcrun simctl boot "$sim"
  xcrun simctl bootstatus "$sim" > /dev/null
  xcrun simctl ui "$sim" appearance "$APPEARANCE"
  xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

  echo "==> $size\" ($model, $APPEARANCE)"
  TEST_RUNNER_FERRY_APPSTORE_SHOTS="$dir" xcodebuild -project Ferry.xcodeproj -scheme Ferry \
    -destination "platform=iOS Simulator,id=$sim" -derivedDataPath build/shots-dd \
    -only-testing:FerryUITests/AppStoreShots test > "$dir/xcodebuild.log" 2>&1 &
  test_pid=$!
  # The test writes <name>.want and waits for <name>.png, which appears whole (taken aside, then moved)
  while kill -0 $test_pid 2>/dev/null; do
    for want in "$dir"/*.want; do
      [ -e "$want" ] || continue
      name=$(basename "$want" .want)
      xcrun simctl io "$sim" screenshot --type=png "$dir/.$name.png" > /dev/null 2>&1
      magick "$dir/.$name.png" -alpha off "$dir/$name.png" && rm "$dir/.$name.png"
      rm -f "$want"
      echo "    $name.png $(sips -g pixelWidth -g pixelHeight "$dir/$name.png" | awk '/pixel/ {printf "%s ", $2}')"
    done
    sleep 0.2
  done
  if ! wait $test_pid; then
    grep -E "error:|failed|\*\* TEST" "$dir/xcodebuild.log" || tail -20 "$dir/xcodebuild.log"
    exit 1
  fi
  rm -f "$dir/xcodebuild.log"
done
echo "==> $OUT"
