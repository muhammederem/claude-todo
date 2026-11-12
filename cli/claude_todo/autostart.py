"""Start the app at login: an XDG autostart entry on Linux, the Run registry key on Windows."""
import os
import sys
from pathlib import Path

NAME = "claude-todo"


def _command() -> list:
    # packaged builds: the .deb wrapper and AppImage say how to start them; a frozen .exe starts itself
    launcher = os.environ.get("CLAUDE_TODO_LAUNCHER") or os.environ.get("APPIMAGE")
    if launcher:
        return [launcher, "gui", "--tray"]
    if getattr(sys, "frozen", False):
        return [sys.executable, "gui", "--tray"]
    exe = sys.executable
    if sys.platform == "win32" and exe.lower().endswith("python.exe"):
        exe = exe[:-len("python.exe")] + "pythonw.exe"       # no console window
    return [exe, "-m", "claude_todo", "gui", "--tray"]


def _desktop_file() -> Path:
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "autostart" / f"{NAME}.desktop"


def is_enabled() -> bool:
    if sys.platform == "win32":
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run") as k:
                winreg.QueryValueEx(k, NAME)
            return True
        except OSError:
            return False
    return _desktop_file().exists()


def set_enabled(on: bool) -> None:
    if sys.platform == "win32":
        import subprocess
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run", 0, winreg.KEY_SET_VALUE) as k:
            if on:
                winreg.SetValueEx(k, NAME, 0, winreg.REG_SZ, subprocess.list2cmdline(_command()))
            else:
                try:
                    winreg.DeleteValue(k, NAME)
                except OSError:
                    pass
        return
    f = _desktop_file()
    if on:
        f.parent.mkdir(parents=True, exist_ok=True)
        exec_line = " ".join('"%s"' % a.replace('"', '\\"') if " " in a else a for a in _command())
        f.write_text("[Desktop Entry]\nType=Application\nName=Leftovers\nComment=Open work across your Claude Code sessions\n"
                     f"Exec={exec_line}\nX-GNOME-Autostart-enabled=true\nTerminal=false\n")
    else:
        try:
            f.unlink()
        except OSError:
            pass
