#!/bin/zsh
# Builds ClaudeTodo.app (+ embedded widget) into ./build/ClaudeTodo.app
# Gerçek widget için: DEVELOPMENT_TEAM=<10 karakterli takım kimliği> scripts/build_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
# Desktop altında Finder/iCloud dosyalara özniteliği ekler ve codesign bunu reddeder; çıktıyı dışarıda üret.
DD="$HOME/Library/Caches/ClaudeTodoBuild"
SIGN=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  SIGN=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" -allowProvisioningUpdates)
fi
xcodebuild -project ClaudeTodo.xcodeproj -scheme ClaudeTodo -configuration Release \
  -derivedDataPath "$DD" "${SIGN[@]}" build | tail -1
rm -rf build/ClaudeTodo.app
ditto --noextattr --norsrc "$DD/Build/Products/Release/ClaudeTodo.app" build/ClaudeTodo.app
echo "Hazir: build/ClaudeTodo.app"
