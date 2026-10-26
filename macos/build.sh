#!/usr/bin/env bash
# macos/build.sh --debug [-- <launch arguments>] — builds the Mac app and runs it from DerivedData (quitting a Ferry
# already running first). Arguments after -- go to the app, e.g. `-- -openPopover YES -appearance dark`.
#
# macos/build.sh --release [--beta N] [--dry-run] [--local-feed URL] — what a release of the Mac app needs, in build/:
# Ferry-<version>-<build>.dmg, Developer ID signed, notarized and stapled (the GitHub Release's asset), and
# Ferry-<version>-<build>.appcast-item.xml, its item for the appcast at nightdrive.sh/ferry/appcast.xml, signed with
# Ferry's Sparkle key (docs/mac-releases.md).
# Needs the team's Developer ID Application certificate and Ferry's Sparkle key in the keychain, and an App Store
# Connect API key in ~/.appstoreconnect/private_keys/ with ASC_KEY_ID and ASC_ISSUER_ID in the environment or in
# ios/.env (git-ignored). Nothing is published: the files stay here.
#   --beta N        the release is v<version>-beta.N: the build follows Sparkle's beta channel, and its item is on it
#   --dry-run       nothing goes to Apple: the .dmg isn't notarized, and it and its item go to build/dry-run/
#   --local-feed U  for trying an update: the app reads U/appcast.xml instead of nightdrive.sh's, the item points to
#                   U/<the .dmg>, and build/local-feed/ gets the .dmg, the item and an appcast.xml of every item there
set -euo pipefail
cd "$(dirname "$0")"

# xcode-select points to the Command Line Tools; switching it would need sudo
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# spctl is in /usr/sbin, which a PATH set up for an agent or a launchd job may lack: without it, every release would
# stop at "Gatekeeper doesn't accept the app"
export PATH="$PATH:/usr/sbin"

usage() {
  echo "usage: macos/build.sh --debug [-- <launch arguments>]" >&2
  echo "       macos/build.sh --release [--beta N] [--dry-run] [--local-feed URL]" >&2
  exit 2
}

debug() {
  echo "==> building"
  xcodebuild -project Ferry.xcodeproj -scheme Ferry -configuration Debug -derivedDataPath build/DerivedData \
    -clonedSourcePackagesDirPath build/SourcePackages build -quiet

  APP="$PWD/build/DerivedData/Build/Products/Debug/Ferry.app"
  # The server holds 127.0.0.1:47270: the old one has to be gone before the new one listens
  pkill -x Ferry 2>/dev/null && sleep 1 || true
  echo "==> opening $APP"
  open "$APP" --args "$@"
}

# What a release leaves while it works. Run on any exit; the trap runs under set -e, so nothing in it may fail.
cleanup() {
  [ -n "${MOUNT:-}" ] && { hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; }
  [ -n "${LAYOUT_MOUNT:-}" ] && { hdiutil detach -quiet "$LAYOUT_MOUNT" 2>/dev/null || true; }
  rm -rf "${UNFINISHED:-}" build/dmg build/Ferry.zip build/Ferry-rw.dmg || true
}

# The .dmg's window: Ferry's background (macos/dmg/), the app and Applications side by side with an arrow between.
# Finder writes that into the volume's .DS_Store, so it is laid out on a writable image, then compressed into $1. The
# background is found by the volume's name, which is why no other "Ferry" disk may be mounted meanwhile.
make_dmg() {
  local out="$1" rw="$PWD/build/Ferry-rw.dmg" size
  mkdir -p build/dmg/.background
  tiffutil -cathidpicheck dmg/background.png dmg/background@2x.png -out build/dmg/.background/background.tiff >/dev/null
  # Room for the .DS_Store Finder adds
  size=$(( $(du -sm build/dmg | cut -f1) + 20 ))
  hdiutil create -quiet -volname Ferry -srcfolder build/dmg -fs HFS+ -format UDRW -size "${size}m" -ov "$rw"
  hdiutil attach -quiet -noautoopen "$rw"
  LAYOUT_MOUNT=/Volumes/Ferry
  osascript >/dev/null <<'APPLESCRIPT' || fail "Finder couldn't lay out the .dmg's window" \
    "Let your terminal control Finder: System Settings › Privacy & Security › Automation."
tell application "Finder"
  tell disk "Ferry"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {300, 200, 960, 628}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Ferry.app" of container window to {170, 235}
    set position of item "Applications" of container window to {490, 235}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
  # Finder writes the .DS_Store when it gets round to it
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$LAYOUT_MOUNT/.DS_Store" ] && break; sleep 1; done
  [ -f "$LAYOUT_MOUNT/.DS_Store" ] || fail "Finder didn't save the .dmg's window layout"
  rm -rf "$LAYOUT_MOUNT/.fseventsd"
  sync
  hdiutil detach -quiet "$LAYOUT_MOUNT"
  LAYOUT_MOUNT=
  hdiutil convert -quiet "$rw" -format UDZO -o "$out"
  rm -f "$rw"
}

fail() {
  echo "ERROR: $1" >&2
  [ -n "${2:-}" ] && echo "       $2" >&2
  exit 1
}

# Sends a zip or a .dmg to Apple and waits, at most half an hour; stops with Apple's log when it isn't accepted. The
# JSON decides, not the exit code: notarytool may exit non-zero for an Invalid result that still has a log.
notarize() {
  local file="$1" out id status
  local auth=(--key "$KEY_FILE" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  echo "==> notarizing $(basename "$file") (a few minutes)"
  out=$(xcrun notarytool submit "$file" "${auth[@]}" --wait --timeout 30m --output-format json 2>&1) || true
  id=$(plutil -extract id raw -o - - <<<"$out" 2>/dev/null || true)
  status=$(plutil -extract status raw -o - - <<<"$out" 2>/dev/null || true)
  [ "$status" = "Accepted" ] && return
  echo "$out" >&2
  [ -n "$id" ] || fail "notarytool couldn't submit $(basename "$file")" "Its answer is above."
  # Still in progress after the timeout: what Apple says about it; otherwise its log of what it rejected
  xcrun notarytool info "$id" "${auth[@]}" >&2 || true
  xcrun notarytool log "$id" "${auth[@]}" >&2 || true
  fail "Apple didn't accept $(basename "$file") (status: ${status:-still waiting})" "Submission $id; its log is above."
}

# Sparkle's own helpers sit in an embedded framework that Xcode signs, but not inside it: Autoupdate and Updater.app
# keep Sparkle's ad hoc signature, which notarization refuses. Signed here innermost first, then the app around them.
sign_sparkle() {
  local app="$1" devid="$2" fw="$1/Contents/Frameworks/Sparkle.framework"
  # The XPC services are for sandboxed apps; Ferry isn't one, so Sparkle installs from the app itself
  rm -rf "$fw/XPCServices" "$fw/Versions/B/XPCServices"
  local code out
  for code in "$fw/Versions/B/Autoupdate" "$fw/Versions/B/Updater.app" "$fw"; do
    out=$(codesign --force --sign "$devid" --options runtime --timestamp "$code" 2>&1) || fail "couldn't sign $code" "$out"
  done
  out=$(codesign --force --sign "$devid" --options runtime --timestamp --preserve-metadata=entitlements "$app" 2>&1) ||
    fail "couldn't sign the app again around Sparkle" "$out"
}

# The feed of a local try: every item in $1, newest build first
write_appcast() {
  local dir="$1" item
  {
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    echo '  <channel>'
    echo '    <title>Ferry</title>'
    for item in $(cd "$dir" && ls ./*.appcast-item.xml | sort -t- -k3 -rn); do cat "$dir/$item"; done
    echo '  </channel>'
    echo '</rss>'
  } >"$dir/appcast.xml"
}

release() {
  local dry_run=false beta="" feed=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=true ;;
      --beta) beta="${2:-}"; shift ;;
      --local-feed) feed="${2:-}"; feed="${feed%/}"; shift ;;
      *) usage ;;
    esac
    shift
  done
  [[ -z "$beta" || "$beta" =~ ^[1-9][0-9]*$ ]] || fail "--beta takes the beta's number, e.g. --beta 1"
  [[ -z "$feed" || "$feed" =~ ^https?://[^/]+ ]] || fail "--local-feed takes the URL its folder is served at, e.g. http://127.0.0.1:8484"
  local team=279G2UNHPN
  # DEVID_NAME exists so the missing-certificate message can be tried without removing the certificate
  local devid="${DEVID_NAME:-Developer ID Application}"

  # Everything that can stop the build is checked before it starts
  echo "==> checking the certificate and the API key"
  security find-identity -v -p codesigning | grep -q "\"$devid: .*($team)\"" ||
    fail "no \"$devid\" certificate for team $team in the keychain" \
      "Make one in Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application."
  ENV_FILE="$PWD/../ios/.env"
  env_value() { [ -r "$ENV_FILE" ] && sed -n "s/^$1=//p" "$ENV_FILE" | tr -d '"' | head -1; }
  : "${ASC_KEY_ID:=$(env_value ASC_KEY_ID || true)}"
  : "${ASC_ISSUER_ID:=$(env_value ASC_ISSUER_ID || true)}"
  [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] ||
    fail "ASC_KEY_ID or ASC_ISSUER_ID missing" "Put them in ios/.env or the environment (the App Store Connect API key notarizes)."
  KEY_FILE="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
  [ -f "$KEY_FILE" ] || fail "no $KEY_FILE" "Download the key from App Store Connect › Users and Access › Integrations."
  [ ! -e /Volumes/Ferry ] ||
    fail "a disk named Ferry is mounted (/Volumes/Ferry)" "Eject it first: the new .dmg is laid out under that name."
  # Sparkle's tools come with its package; the key in the keychain must be the one the app trusts
  xcodebuild -resolvePackageDependencies -project Ferry.xcodeproj -scheme Ferry \
    -clonedSourcePackagesDirPath build/SourcePackages -quiet >/dev/null
  local sparkle_bin="$PWD/build/SourcePackages/artifacts/sparkle/Sparkle/bin" public_key
  public_key=$("$sparkle_bin/generate_keys" --account ferry -p 2>/dev/null) ||
    fail "Ferry's Sparkle key isn't in the keychain" "docs/mac-releases.md says how to import it (or make the first one)."
  [ "$public_key" = "$(plutil -extract SUPublicEDKey raw -o - Info.plist)" ] ||
    fail "the Sparkle key in the keychain isn't the one in macos/Info.plist (SUPublicEDKey)" \
      "Updates signed with it would be refused by every copy handed out. docs/mac-releases.md"

  # A new build number for every build, above the last one, as on iOS (tools/build-number.sh)
  local build version settings minimum_os archive app
  build=$(../tools/build-number.sh)
  settings=$(xcodebuild -project Ferry.xcodeproj -scheme Ferry -configuration Release -showBuildSettings 2>/dev/null)
  version=$(sed -n 's/^ *MARKETING_VERSION = //p' <<<"$settings" | head -1)
  minimum_os=$(sed -n 's/^ *MACOSX_DEPLOYMENT_TARGET = //p' <<<"$settings" | head -1)

  # The release's tag, which names its GitHub Release and so where the .dmg is downloaded from
  local tag="v$version" channel="" title="Ferry $version" feed_url="https://nightdrive.sh/ferry/appcast.xml"
  local out="$PWD/build" download
  [ -n "$beta" ] && { tag="v$version-beta.$beta"; channel=beta; title="Ferry $version beta $beta"; }
  [ "$dry_run" = true ] && out="$PWD/build/dry-run"
  [ -n "$feed" ] && { out="$PWD/build/local-feed"; feed_url="$feed/appcast.xml"; }
  mkdir -p "$out"
  local name="Ferry-$version-$build"
  if [ -n "$feed" ]; then download="$feed/$name.dmg"; else
    download="https://github.com/nightdrive-sh/ferry/releases/download/$tag/$name.dmg"
  fi
  echo "==> $title ($build), $tag${channel:+, on the $channel channel}, reads $feed_url"

  archive="$PWD/build/Ferry.xcarchive"
  # Earlier releases stay: each has its own build number, and a dry run must not take the last one away
  rm -rf "$archive" build/Ferry.zip build/dmg
  echo "==> archiving, signed with Developer ID"
  xcodebuild -project Ferry.xcodeproj -scheme Ferry -configuration Release -destination "generic/platform=macOS" \
    -archivePath "$archive" -clonedSourcePackagesDirPath build/SourcePackages \
    CURRENT_PROJECT_VERSION="$build" CODE_SIGN_IDENTITY="$devid" \
    FERRY_FEED_URL="$feed_url" FERRY_UPDATE_CHANNEL="$channel" archive -quiet
  app="$archive/Products/Applications/Ferry.app"
  sign_sparkle "$app" "$devid"

  # What Apple would reject, caught here, before anything is sent
  echo "==> checking the signature"
  codesign --verify --strict --deep "$app" || fail "the app's signature doesn't verify"
  local info
  info=$(codesign -dvvv "$app" 2>&1)
  grep -q "^Authority=Developer ID Application" <<<"$info" || fail "the app isn't signed with Developer ID" "$info"
  grep -q "^TeamIdentifier=$team" <<<"$info" || fail "the app isn't signed by team $team"
  grep -q "flags=.*(runtime)" <<<"$info" || fail "the app has no hardened runtime" "ENABLE_HARDENED_RUNTIME in the Release configuration."
  grep -q "^Timestamp=" <<<"$info" || fail "the app's signature has no secure timestamp" "OTHER_CODE_SIGN_FLAGS = --timestamp in Release."
  ! codesign -d --entitlements - "$app" 2>/dev/null | grep -q get-task-allow ||
    fail "the app carries get-task-allow, a debug entitlement Apple rejects"
  local code
  for code in Autoupdate Updater.app .; do
    info=$(codesign -dvvv "$app/Contents/Frameworks/Sparkle.framework/Versions/B/$code" 2>&1)
    grep -q "^Authority=Developer ID Application" <<<"$info" && grep -q "flags=.*(runtime)" <<<"$info" &&
      grep -q "^Timestamp=" <<<"$info" || fail "Sparkle's $code isn't signed with Developer ID, hardened, timestamped" "$info"
  done
  # What every copy of this build will ask for its updates, and which of them it takes
  local plist="$app/Contents/Info.plist"
  [ "$(plutil -extract SUFeedURL raw -o - "$plist")" = "$feed_url" ] || fail "the app's SUFeedURL isn't $feed_url"
  [ "$(plutil -extract FerryUpdateChannel raw -o - "$plist")" = "$channel" ] || fail "the app's FerryUpdateChannel isn't \"$channel\""

  if [ "$dry_run" = false ]; then
    # The app first, stapled, so it opens offline once it is copied out of the .dmg
    ditto -c -k --keepParent "$app" build/Ferry.zip
    notarize build/Ferry.zip
    xcrun stapler staple -q "$app"
  fi

  # The .dmg takes its real name only once everything below has passed: a failure or Ctrl-C leaves nothing that looks
  # like a release
  local dmg="$out/$name.dmg" item="$out/$name.appcast-item.xml"
  UNFINISHED="$out/$name.unfinished.dmg"
  MOUNT="$PWD/build/mnt"
  trap cleanup EXIT
  # Ctrl-C would otherwise end the shell without running the EXIT trap
  trap 'exit 130' INT TERM
  echo "==> making $(basename "$dmg")"
  mkdir -p build/dmg
  ditto "$app" build/dmg/Ferry.app
  ln -s /Applications build/dmg/Applications
  make_dmg "$UNFINISHED"
  codesign --sign "$devid" --timestamp "$UNFINISHED"
  if [ "$dry_run" = false ]; then check_notarized "$app" "$UNFINISHED"; fi

  # Sparkle's EdDSA signature is of the finished file, stapled ticket included: it is what an update is checked against
  echo "==> signing the update for Sparkle"
  local signature
  signature=$("$sparkle_bin/sign_update" --account ferry "$UNFINISHED") || fail "sign_update couldn't sign the .dmg"
  local notes=""
  [ -z "$feed" ] && notes="
      <sparkle:fullReleaseNotesLink>https://github.com/nightdrive-sh/ferry/releases/tag/$tag</sparkle:fullReleaseNotesLink>"
  cat >"$item" <<ITEM
    <item>
      <title>$title</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>${channel:+
      <sparkle:channel>$channel</sparkle:channel>}
      <sparkle:minimumSystemVersion>$minimum_os</sparkle:minimumSystemVersion>$notes
      <enclosure url="$download" type="application/x-apple-diskimage" $signature/>
    </item>
ITEM

  mv "$UNFINISHED" "$dmg"
  [ -n "$feed" ] && write_appcast "$out"
  if [ "$dry_run" = true ]; then
    echo "==> dry run, nothing sent to Apple: ${out#"$PWD/"}/$name.dmg (not notarized) and its appcast item"
  else
    echo "==> done: ${out#"$PWD/"}/$name.dmg (notarized, stapled) and ${out#"$PWD/"}/$name.appcast-item.xml"
  fi
  [ -z "$feed" ] || echo "    the feed: ${out#"$PWD/"}/appcast.xml, to be served at $feed"
}

# Apple's ticket on the .dmg, then Gatekeeper's view of both, as a downloaded copy would get it
check_notarized() {
  local app="$1" dmg="$2"
  notarize "$dmg"
  xcrun stapler staple -q "$dmg"

  # Gatekeeper on the app and the .dmg, and Apple's own pre-distribution check on the app as it comes out of the .dmg
  echo "==> checking with Gatekeeper"
  spctl -a -vvv -t exec "$app" 2>&1 | grep -q "source=Notarized Developer ID" || fail "Gatekeeper doesn't accept the app"
  spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null || fail "Gatekeeper doesn't accept the .dmg"
  xcrun stapler validate -q "$app" && xcrun stapler validate -q "$dmg" || fail "a notarization ticket isn't stapled"
  mkdir -p "$MOUNT"
  hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$dmg"
  syspolicy_check distribution "$MOUNT/Ferry.app" >/dev/null 2>&1 ||
    fail "the app in the .dmg doesn't pass Apple's pre-distribution check" "Run: syspolicy_check distribution on it."
  hdiutil detach -quiet "$MOUNT"
}

case "${1:-}" in
  --debug)
    shift
    [ "${1:-}" = "--" ] && shift
    debug "$@"
    ;;
  --release)
    shift
    release "$@"
    ;;
  *) usage ;;
esac
