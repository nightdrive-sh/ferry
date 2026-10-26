#!/usr/bin/env bash
# macos/shot.sh <out.png> — a screenshot of Ferry's popover (its largest window above the desktop), for checking the
# UI without driving it. Needs the Screen Recording permission for the terminal: without it the image is only the
# wallpaper.
set -euo pipefail
OUT="${1:?usage: macos/shot.sh <out.png>}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

ID=$(swift -e '
import CoreGraphics
let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
let ferry = windows.filter { $0[kCGWindowOwnerName as String] as? String == "Ferry" && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }
func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
if let w = ferry.max(by: { area($0) < area($1) }) { print(w[kCGWindowNumber as String] as? Int ?? 0) }
')
if [ -z "$ID" ]; then
  echo "no Ferry window on screen: is the popover open?" >&2
  exit 1
fi
screencapture -x -o -l "$ID" "$OUT"
echo "$OUT"
