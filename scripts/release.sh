#!/bin/bash
# Release build: signs with Developer ID, notarizes, and produces build/release/Leftovers.dmg.
#   TEAM_ID=XXXXXXXXXX scripts/release.sh
# One-time setup:
#   1) A "Developer ID Application: ..." certificate in the keychain (Xcode > Settings > Accounts > Manage Certificates).
#   2) xcrun notarytool store-credentials claude-todo-notary --apple-id <email> --team-id <TEAM_ID> --password <app-specific password>
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEAM_ID:?set TEAM_ID to your 10-character Apple team id}"
PROFILE="${NOTARY_PROFILE:-claude-todo-notary}"
DD="$HOME/Library/Caches/LeftoversRelease"
OUT="build/release"

security find-identity -v -p codesigning | grep -q "Developer ID Application.*($TEAM_ID)" \
  || { echo "No Developer ID Application certificate for team $TEAM_ID in the keychain."; exit 1; }

xcodegen generate >/dev/null
rm -rf "$DD" "$OUT"; mkdir -p "$OUT"
xcodebuild -project ClaudeTodo.xcodeproj -scheme ClaudeTodo -configuration Release -derivedDataPath "$DD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="" ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" build | tail -1

ditto --noextattr --norsrc "$DD/Build/Products/Release/Leftovers.app" "$OUT/Leftovers.app"
codesign --verify --deep --strict --verbose=2 "$OUT/Leftovers.app"

# 1) notarize and staple the app
ditto -c -k --keepParent "$OUT/Leftovers.app" "$OUT/Leftovers.zip"
xcrun notarytool submit "$OUT/Leftovers.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Leftovers.app"

# 2) DMG with the app and an Applications shortcut
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
ditto --noextattr --norsrc "$OUT/Leftovers.app" "$STAGE/Leftovers.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Leftovers" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Leftovers.dmg" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$OUT/Leftovers.dmg"
xcrun notarytool submit "$OUT/Leftovers.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Leftovers.dmg"

spctl --assess --type open --context context:primary-signature -v "$OUT/Leftovers.dmg"
echo "Built $OUT/Leftovers.dmg"
