"""Qt kills the process outright when a system library of its X11 plugin is missing, so check before importing it."""
import ctypes.util
import os
import sys
from typing import List

# library soname stem -> Debian/Ubuntu package that provides it (what Qt 6.5+'s xcb plugin loads)
XCB_LIBS = [
    ("xcb-cursor", "libxcb-cursor0"),
    ("xkbcommon-x11", "libxkbcommon-x11-0"),
    ("xcb-icccm", "libxcb-icccm4"),
    ("xcb-keysyms", "libxcb-keysyms1"),
    ("xcb-shape", "libxcb-shape0"),
    ("xcb-render-util", "libxcb-render-util0"),
    ("EGL", "libegl1"),
    ("fontconfig", "libfontconfig1"),
]


def uses_xcb(env=os.environ) -> bool:
    forced = env.get("QT_QPA_PLATFORM", "")
    if forced:
        return forced.split(";")[0] == "xcb"
    # Qt picks its Wayland plugin in a Wayland session; X11 (or XWayland-only) sessions use xcb
    return not (env.get("WAYLAND_DISPLAY") and env.get("XDG_SESSION_TYPE", "wayland") == "wayland")


def missing_packages(find=ctypes.util.find_library, platform: str = sys.platform, env=os.environ) -> List[str]:
    if not platform.startswith("linux") or env.get("CLAUDE_TODO_SKIP_CHECK") or not uses_xcb(env):
        return []
    return [pkg for lib, pkg in XCB_LIBS if not find(lib)]


def advice(packages: List[str]) -> str:
    return ("The window cannot start: Qt needs system libraries that are not installed.\n"
            f"  sudo apt install {' '.join(packages)}\n"
            "(Fedora: sudo dnf install xcb-util-cursor xcb-util-wm xcb-util-keysyms libxkbcommon-x11; "
            "Arch: sudo pacman -S xcb-util-cursor)\n"
            "The .deb from the Releases page installs these for you. Set CLAUDE_TODO_SKIP_CHECK=1 to try anyway.")
