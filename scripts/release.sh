#!/bin/bash
# Paylaşılabilir sürüm: Developer ID ile imzala, Apple'a notarize ettir, DMG üret.
#   TEAM_ID=XXXXXXXXXX scripts/release.sh
# Bir kerelik hazırlık (README'de de var):
#   1) Keychain'de "Developer ID Application: ..." sertifikası olmalı (Xcode > Settings > Accounts > Manage Certificates).
#   2) xcrun notarytool store-credentials claude-todo-notary --apple-id <mail> --team-id <TEAM_ID> --password <uygulamaya özel şifre>
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEAM_ID:?TEAM_ID=<10 karakterli takım kimliği> ver}"
PROFILE="${NOTARY_PROFILE:-claude-todo-notary}"
DD="$HOME/Library/Caches/ClaudeTodoRelease"
OUT="build/release"

security find-identity -v -p codesigning | grep -q "Developer ID Application.*($TEAM_ID)" \
  || { echo "Developer ID Application sertifikası ($TEAM_ID) bulunamadı."; exit 1; }

xcodegen generate >/dev/null
rm -rf "$DD" "$OUT"; mkdir -p "$OUT"
xcodebuild -project ClaudeTodo.xcodeproj -scheme ClaudeTodo -configuration Release -derivedDataPath "$DD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="" ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" build | tail -1

ditto --noextattr --norsrc "$DD/Build/Products/Release/ClaudeTodo.app" "$OUT/ClaudeTodo.app"
codesign --verify --deep --strict --verbose=2 "$OUT/ClaudeTodo.app"

# 1) uygulamayı notarize et ve mühürle
ditto -c -k --keepParent "$OUT/ClaudeTodo.app" "$OUT/ClaudeTodo.zip"
xcrun notarytool submit "$OUT/ClaudeTodo.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/ClaudeTodo.app"

# 2) DMG: uygulama + Applications kısayolu
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
ditto --noextattr --norsrc "$OUT/ClaudeTodo.app" "$STAGE/ClaudeTodo.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Claude To-Do" -srcfolder "$STAGE" -ov -format UDZO "$OUT/ClaudeTodo.dmg" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$OUT/ClaudeTodo.dmg"
xcrun notarytool submit "$OUT/ClaudeTodo.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/ClaudeTodo.dmg"

spctl --assess --type open --context context:primary-signature -v "$OUT/ClaudeTodo.dmg"
echo "Hazir: $OUT/ClaudeTodo.dmg"
