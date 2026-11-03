import os
import unittest
from unittest import mock

from claude_todo import autostart, preflight


class Preflight(unittest.TestCase):
    X11 = {"XDG_SESSION_TYPE": "x11", "DISPLAY": ":0"}

    def test_reports_missing_xcb_libs_with_apt_names(self):
        have = {"EGL", "fontconfig", "xkbcommon-x11", "xcb-icccm", "xcb-keysyms", "xcb-shape", "xcb-render-util"}
        got = preflight.missing_packages(find=lambda lib: lib in have and "lib" + lib, platform="linux", env=self.X11)
        self.assertEqual(got, ["libxcb-cursor0"])
        self.assertIn("sudo apt install libxcb-cursor0", preflight.advice(got))

    def test_nothing_missing(self):
        self.assertEqual(preflight.missing_packages(find=lambda lib: "x", platform="linux", env=self.X11), [])

    def test_only_linux_is_checked(self):
        for plat in ("win32", "darwin"):
            self.assertEqual(preflight.missing_packages(find=lambda lib: None, platform=plat, env=self.X11), [])

    def test_wayland_session_skips_the_xcb_check(self):
        env = {"XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "wayland-0"}
        self.assertEqual(preflight.missing_packages(find=lambda lib: None, platform="linux", env=env), [])

    def test_forced_xcb_on_wayland_is_checked(self):
        env = {"XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "wayland-0", "QT_QPA_PLATFORM": "xcb"}
        self.assertIn("libxcb-cursor0", preflight.missing_packages(find=lambda lib: None, platform="linux", env=env))

    def test_offscreen_and_skip_variable(self):
        self.assertEqual(preflight.missing_packages(find=lambda lib: None, platform="linux", env={"QT_QPA_PLATFORM": "offscreen"}), [])
        self.assertEqual(preflight.missing_packages(find=lambda lib: None, platform="linux", env={"CLAUDE_TODO_SKIP_CHECK": "1"}), [])

    def test_gui_command_stops_with_advice_instead_of_crashing(self):
        from .test_cli import run
        with mock.patch("claude_todo.preflight.missing_packages", return_value=["libxcb-cursor0"]):
            code, _, err = run("--no-ai", "gui")
        self.assertEqual(code, 1)
        self.assertIn("sudo apt install libxcb-cursor0", err)


class Launchers(unittest.TestCase):
    def test_deb_wrapper(self):
        with mock.patch.dict(os.environ, {"CLAUDE_TODO_LAUNCHER": "/usr/bin/claude-todo"}):
            self.assertEqual(autostart._command(), ["/usr/bin/claude-todo", "gui", "--tray"])

    def test_appimage(self):
        with mock.patch.dict(os.environ, {"APPIMAGE": "/home/u/Claude_To-Do.AppImage"}):
            os.environ.pop("CLAUDE_TODO_LAUNCHER", None)
            self.assertEqual(autostart._command()[0], "/home/u/Claude_To-Do.AppImage")

    def test_frozen_exe(self):
        env = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_TODO_LAUNCHER", "APPIMAGE")}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(autostart.sys, "frozen", True, create=True), \
                mock.patch.object(autostart.sys, "executable", r"C:\Apps\ClaudeTodo.exe"):
            self.assertEqual(autostart._command(), [r"C:\Apps\ClaudeTodo.exe", "gui", "--tray"])


if __name__ == "__main__":
    unittest.main()
