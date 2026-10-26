#!/usr/bin/env bash
# ios/build.sh [--archive-only] — archives the iPhone app and uploads it to App Store Connect for TestFlight.
#
# Needs: Xcode with team 279G2UNHPN's Apple account added, and an App Store Connect API key in
# ~/.appstoreconnect/private_keys/ with ASC_KEY_ID and ASC_ISSUER_ID in the environment or in ios/.env (git-ignored).
# --archive-only builds without signing or uploading, to check the chain without any credentials.
set -euo pipefail
cd "$(dirname "$0")"

# xcode-select points to the Command Line Tools; switching it would need sudo
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

ARCHIVE_ONLY=false
[ "${1:-}" = "--archive-only" ] && ARCHIVE_ONLY=true

ARCHIVE="$PWD/build/Ferry.xcarchive"
APP_GROUP=group.fi.feature.ferry
TEAM=279G2UNHPN

# TestFlight wants a new build number on every upload, above the last one (tools/build-number.sh)
BUILD_NUMBER=$(../tools/build-number.sh)
echo "==> build number: $BUILD_NUMBER"

rm -rf build/Ferry.xcarchive build/export build/verify

# The archive is made UNSIGNED and signed on export: automatic signing at archive time asks for a development profile,
# which can't be made without devices registered to the team, and TestFlight needs none
echo "==> archiving (signed on export)"
xcodebuild -project Ferry.xcodeproj -scheme Ferry \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  archive -quiet

if [ "$ARCHIVE_ONLY" = true ]; then
  echo "==> done: $ARCHIVE (not signed, not uploaded)"
  exit 0
fi

# Credentials from ios/.env unless already in the environment, read with sed rather than sourced
ENV_FILE="$PWD/.env"
env_value() { [ -f "$ENV_FILE" ] && sed -n "s/^$1=//p" "$ENV_FILE" | tr -d '"' | head -1; }
: "${ASC_KEY_ID:=$(env_value ASC_KEY_ID)}"
: "${ASC_ISSUER_ID:=$(env_value ASC_ISSUER_ID)}"
: "${ASC_KEY_ID:?ASC_KEY_ID missing: put it in ios/.env or the environment}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID missing: put it in ios/.env or the environment}"

# Entitlements reach the export ONLY through the archived app's signature: an unsigned archive carries none, and the
# app would then run without its App Group (the share and notification extensions would see no machines). So the
# archive gets an ad hoc signature with the project's entitlements; the export replaces it with its own.
# - Xcode expands $(AppIdentifierPrefix) in a build, codesign doesn't: the release copies carry the team's prefix.
# - The push entitlement goes in as production: without it a TestFlight build launches fine and APNs registration
#   fails silently ("no valid aps-environment").
# - The notification extension is signed first (a bundle's signature covers what is inside it), with its App Group and
#   keychain group: without them it can't read the keys, and every notification shows the fallback line.
# - The share extension likewise, with its App Group: without it, it sees no computers and can't copy files into the
#   container its background uploads read from.
APP="$ARCHIVE/Products/Applications/Ferry.app"
APPEX="$APP/PlugIns/FerryNotifications.appex"
SHARE="$APP/PlugIns/FerryShare.appex"
release_entitlements() { sed "s/\$(AppIdentifierPrefix)/$TEAM./" "$1" > "$2"; }
release_entitlements FerryNotifications/FerryNotifications.entitlements build/release-notifications.entitlements
release_entitlements FerryShare/FerryShare.entitlements build/release-share.entitlements
release_entitlements Ferry/Ferry.entitlements build/release.entitlements
plutil -replace aps-environment -string production build/release.entitlements
codesign --force --sign - --entitlements build/release-notifications.entitlements "$APPEX"
codesign --force --sign - --entitlements build/release-share.entitlements "$SHARE"
codesign --force --sign - --entitlements build/release.entitlements "$APP"

# Signing and uploading use DIFFERENT credentials: Xcode's Apple account makes the distribution certificate and
# profile (-allowProvisioningUpdates); an App Store Connect API key would need the Admin role for cloud signing.
echo "==> exporting and signing (Xcode's Apple account)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$PWD/build/export" \
  -allowProvisioningUpdates

# Checked before the upload, which can't be taken back (the build number is spent): a missing entitlement shows
# nowhere until notifications simply never arrive
echo "==> checking the push, App Group, keychain and Associated Domains entitlements, and the share extension's App Group"
mkdir -p build/verify
unzip -q "$PWD/build/export/Ferry.ipa" -d build/verify
entitlements() { codesign -d --entitlements - --xml "build/verify/Payload/$1" 2>/dev/null; }
fail() {
  echo "ERROR: $1: not uploading." >&2
  echo "       $2" >&2
  exit 1
}
entitlements Ferry.app | plutil -extract aps-environment raw -o - - 2>/dev/null | grep -qx production ||
  fail "the exported app has no aps-environment=production" "Enable Push Notifications for fi.feature.ferry at developer.apple.com."
for bundle in Ferry.app Ferry.app/PlugIns/FerryNotifications.appex Ferry.app/PlugIns/FerryShare.appex; do
  [ -d "build/verify/Payload/$bundle" ] || fail "$bundle is missing from the exported app" "Check the app's Embed Foundation Extensions."
  entitlements "$bundle" | grep -q "$APP_GROUP" ||
    fail "$bundle has no $APP_GROUP entitlement" "Enable App Groups with $APP_GROUP for its App ID at developer.apple.com."
done
# Without it the Camera opens Add Device's QR code in Safari, at nightdrive.sh's add page, instead of in the app
entitlements Ferry.app | grep -q "applinks:nightdrive.sh" ||
  fail "the exported app has no applinks:nightdrive.sh" "Enable Associated Domains for fi.feature.ferry at developer.apple.com."
# The share extension needs no push keys, so only these two carry the keychain group
for bundle in Ferry.app Ferry.app/PlugIns/FerryNotifications.appex; do
  entitlements "$bundle" | grep -q "$TEAM.fi.feature.ferry.shared" ||
    fail "$bundle has no keychain group $TEAM.fi.feature.ferry.shared" "Check its entitlements file and the export's profile."
done

echo "==> uploading to App Store Connect (API key)"
xcrun altool --upload-app -f "$PWD/build/export/Ferry.ipa" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> uploaded. The build shows in TestFlight after processing (a few minutes):"
echo "    https://appstoreconnect.apple.com → Ferry: Device Mailbox → TestFlight"
