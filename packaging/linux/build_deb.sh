#!/bin/bash
# Builds build/deb/claude-todo_<version>_<arch>.deb on Debian/Ubuntu.
# PySide6 is bundled (Ubuntu 22.04 has no packaged PySide6); apt installs the system libraries Qt needs.
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' cli/pyproject.toml)
ARCH=$(dpkg --print-architecture)
NAME="claude-todo_${VERSION}_${ARCH}"
ROOT="build/deb/$NAME"
LIB="$ROOT/opt/claude-todo/lib"

rm -rf build/deb
mkdir -p "$ROOT/DEBIAN" "$LIB" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
         "$ROOT/usr/share/icons/hicolor/256x256/apps" "$ROOT/usr/share/doc/claude-todo"

python3 -m pip install --quiet --no-compile --target "$LIB" "PySide6-Essentials>=6.5"
cp -r cli/claude_todo "$LIB/"
find "$ROOT" -name "__pycache__" -prune -exec rm -rf {} +

cat > "$ROOT/usr/bin/claude-todo" <<'SH'
#!/bin/sh
# -s: ignore the user's site-packages so a pip-installed PySide6 cannot shadow the bundled one
export CLAUDE_TODO_LAUNCHER=/usr/bin/claude-todo
export PYTHONPATH=/opt/claude-todo/lib
exec /usr/bin/python3 -s -m claude_todo "$@"
SH
chmod 755 "$ROOT/usr/bin/claude-todo"
install -m 644 packaging/linux/claude-todo.desktop "$ROOT/usr/share/applications/claude-todo.desktop"
install -m 644 LICENSE "$ROOT/usr/share/doc/claude-todo/copyright"

QT_QPA_PLATFORM=offscreen PYTHONPATH="$LIB" python3 -s -c "
from PySide6.QtWidgets import QApplication
app = QApplication([])
from claude_todo.gui import app_icon
app_icon().pixmap(256, 256).save('$ROOT/usr/share/icons/hicolor/256x256/apps/claude-todo.png')
"

SIZE=$(du -sk "$ROOT" | cut -f1)
cat > "$ROOT/DEBIAN/control" <<CTRL
Package: claude-todo
Version: $VERSION
Architecture: $ARCH
Maintainer: muhammederem <muhammederemm@gmail.com>
Installed-Size: $SIZE
Section: utils
Priority: optional
Homepage: https://github.com/muhammederem/claude-todo
Depends: python3 (>= 3.9), libxcb-cursor0, libxkbcommon-x11-0, libxkbcommon0, libxcb-icccm4, libxcb-keysyms1,
 libxcb-shape0, libxcb-render-util0, libxcb-randr0, libxcb-image0, libxcb-sync1, libxcb-xfixes0, libxcb-shm0,
 libxcb-xkb1, libxcb-render0, libxcb1, libx11-xcb1, libegl1, libgl1, libfontconfig1, libdbus-1-3, libglib2.0-0,
 libwayland-client0, libwayland-cursor0, libwayland-egl1
Suggests: claude-code, xdotool, gnome-shell-extension-appindicator
Description: what is still open across your Claude Code sessions
 A window with a tray icon that reads Claude Code's own session files and
 lists the unfinished work of each session, marks what waits on you, shows
 what a busy session is doing, and reopens sessions in your terminal.
CTRL

dpkg-deb --build --root-owner-group "$ROOT" "build/deb/$NAME.deb" >/dev/null
echo "build/deb/$NAME.deb"
