#!/bin/zsh
# Builds Leftovers.app with its embedded widget into ./build/Leftovers.app.
# Unsigned by default; the widget only loads when signed: DEVELOPMENT_TEAM=<team id> scripts/build_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
# Build outside the checkout: Finder/iCloud add extended attributes there that codesign rejects.
DD="$HOME/Library/Caches/LeftoversBuild"
SIGN=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  SIGN=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" -allowProvisioningUpdates)
fi
xcodebuild -project ClaudeTodo.xcodeproj -scheme ClaudeTodo -configuration Release \
  -derivedDataPath "$DD" "${SIGN[@]}" build | tail -1
rm -rf build/Leftovers.app
ditto --noextattr --norsrc "$DD/Build/Products/Release/Leftovers.app" build/Leftovers.app
echo "Built build/Leftovers.app"
