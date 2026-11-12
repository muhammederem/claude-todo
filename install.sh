#!/bin/sh
# Leftovers installer for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/muhammederem/claude-todo/main/install.sh | sh
#
# macOS: installs the signed, notarized app from the latest release into /Applications (or ~/Applications).
# Linux: installs the latest release's .deb on Debian/Ubuntu (amd64), otherwise the Python package into its own
#        virtual environment (pipx when available), and links `leftovers` into ~/.local/bin.
#
# Environment: LEFTOVERS_VERSION=v1.2.0 picks a release instead of the latest.
set -eu

REPO="muhammederem/claude-todo"
API="https://api.github.com/repos/$REPO/releases"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have curl || fail "curl is required"

release_json() {
    if [ -n "${LEFTOVERS_VERSION:-}" ]; then
        curl -fsSL "$API/tags/$LEFTOVERS_VERSION"
    else
        curl -fsSL "$API/latest"
    fi || fail "could not reach GitHub to find the release"
}

RELEASE=$(release_json)
TAG=$(printf '%s' "$RELEASE" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$TAG" ] || fail "could not read the release tag"

# First download URL in the release whose file name matches the extended regex $1.
asset_url() {
    printf '%s' "$RELEASE" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(https[^"]*\)"$/\1/' \
        | grep -E "$1" | head -n 1
}

install_macos() {
    version=$(sw_vers -productVersion)
    [ "${version%%.*}" -ge 15 ] || fail "macOS 15 or later is required (this Mac runs $version)"
    if have brew && brew list --cask claude-todo >/dev/null 2>&1; then
        fail "Leftovers is managed by Homebrew here; update it with: brew upgrade --cask claude-todo"
    fi
    url=$(asset_url '\.dmg$')
    [ -n "$url" ] || fail "release $TAG has no macOS disk image"

    tmp=$(mktemp -d)
    trap 'hdiutil detach "$tmp/mnt" -quiet >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
    say "Downloading Leftovers $TAG"
    curl -fL --progress-bar -o "$tmp/Leftovers.dmg" "$url"
    hdiutil attach "$tmp/Leftovers.dmg" -nobrowse -readonly -mountpoint "$tmp/mnt" -quiet
    app=$(find "$tmp/mnt" -maxdepth 1 -name '*.app' | head -n 1)
    [ -n "$app" ] || fail "the disk image has no app in it"

    dest=/Applications
    [ -w "$dest" ] || dest="$HOME/Applications"
    mkdir -p "$dest"
    # quit a running copy, then replace it (also under its pre-rename name)
    osascript -e 'tell application id "com.muhammederem.claude-todo" to quit' >/dev/null 2>&1 || true
    rm -rf "$dest/Leftovers.app" "$dest/ClaudeTodo.app"
    say "Installing into $dest"
    ditto "$app" "$dest/$(basename "$app")"
    open "$dest/$(basename "$app")"
    say "Done. Leftovers is in the menu bar; add the widget with right-click on the desktop > Edit Widgets."
}

install_deb() {
    url=$1
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    say "Downloading the $TAG package"
    curl -fL --progress-bar -o "$tmp/leftovers.deb" "$url"
    chmod 644 "$tmp/leftovers.deb"
    say "Installing with apt (asks for your password)"
    sudo apt-get install -y "$tmp/leftovers.deb"
}

install_python() {
    have python3 || fail "Python 3.9 or later is required: install python3 with your package manager"
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' \
        || fail "Python 3.9 or later is required (found $(python3 -V 2>&1))"
    # a source archive instead of git+https, so git is not needed
    spec="leftovers[gui] @ https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz#subdirectory=cli"
    bin="$HOME/.local/bin"
    mkdir -p "$bin"
    if have pipx; then
        say "Installing with pipx"
        pipx install --force "$spec"
    else
        venv="${XDG_DATA_HOME:-$HOME/.local/share}/leftovers/venv"
        say "Installing into $venv"
        python3 -m venv --clear "$venv" \
            || fail "python3 cannot create virtual environments; install python3-venv (Debian/Ubuntu) or pipx"
        "$venv/bin/python" -m pip install --quiet --upgrade pip
        "$venv/bin/python" -m pip install --quiet "$spec"
        ln -sf "$venv/bin/leftovers" "$bin/leftovers"
    fi
    case ":$PATH:" in
        *":$bin:"*) ;;
        *) say "Add $bin to your PATH to run \`leftovers\` from a terminal." ;;
    esac
    # Qt needs a few system libraries a minimal desktop may lack; this names the exact package if one is missing
    "$bin/leftovers" --version >/dev/null 2>&1 || fail "installed, but \`leftovers --version\` failed"
}

install_linux() {
    url=""
    if have apt-get && have dpkg && [ "$(dpkg --print-architecture)" = amd64 ]; then
        url=$(asset_url '_amd64\.deb$')
    fi
    if [ -n "$url" ]; then
        install_deb "$url"
    else
        install_python
    fi
    say "Done. Start Leftovers from the app menu or run: leftovers gui"
}

case "$(uname -s)" in
    Darwin) install_macos ;;
    Linux) install_linux ;;
    *) fail "unsupported system $(uname -s); on Windows run install.ps1 (see the README)" ;;
esac
