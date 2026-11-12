"""Windows-specific behaviour, tested everywhere by faking the platform; the real thing also runs on windows-latest in CI."""
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from claude_todo import analyzer, paths, scanner, terminals

SID = "0123abcd-4567-89ef-0123-456789abcdef"


class WindowsLaunch(unittest.TestCase):
    def setUp(self):
        p = mock.patch.object(terminals, "_is_windows", return_value=True)
        p.start()
        self.addCleanup(p.stop)
        self.folder = tempfile.mkdtemp()

    def test_windows_terminal_when_available(self):
        with mock.patch.object(terminals.shutil, "which", return_value="wt.exe"):
            argv = terminals.resume(SID, self.folder, dry_run=True)
        self.assertEqual(argv, ["wt", "-d", self.folder, "--", "claude", "--resume", SID])

    def test_plain_cmd_window_otherwise(self):
        with mock.patch.object(terminals.shutil, "which", return_value=None):
            argv = terminals.resume(SID, self.folder, dry_run=True)
        self.assertEqual(argv[:4], ["cmd", "/c", "start", ""])
        self.assertEqual(argv[-3:], ["claude", "--resume", SID])
        self.assertIn(self.folder, argv)

    def test_task_prompt_and_fork(self):
        with mock.patch.object(terminals.shutil, "which", return_value="wt.exe"):
            argv = terminals.resume(SID, self.folder, dry_run=True, prompt="Fix it\nnow", fork=True)
        self.assertEqual(argv[-4:], ["--resume", SID, "--fork-session", "Fix it now"])

    def test_cmd_prompt_loses_characters_cmd_would_misread(self):
        with mock.patch.object(terminals.shutil, "which", return_value=None):
            argv = terminals.resume(SID, self.folder, dry_run=True, prompt='a & calc | "x" 100%')
        self.assertEqual(argv[-1], "a  calc  x 100")

    def test_folders_cmd_could_misread_fall_back_to_home(self):
        for nasty in ("C:\\a&calc", "C:\\a|b", 'C:\\a"b', "C:\\100%", "C:\\a^b"):
            with self.subTest(nasty=nasty), mock.patch.object(terminals.shutil, "which", return_value=None), \
                    mock.patch.object(terminals.os.path, "isdir", return_value=True):
                argv = terminals.resume(SID, nasty, dry_run=True)
                self.assertNotIn(nasty, argv)
                self.assertIn(os.path.expanduser("~"), argv)

    def test_bad_id_rejected(self):
        with self.assertRaises(ValueError):
            terminals.resume("x; calc", self.folder, dry_run=True)

    def test_launch_uses_popen_without_a_shell(self):
        with mock.patch.object(terminals.shutil, "which", return_value="wt.exe"), \
                mock.patch.object(terminals.subprocess, "Popen") as popen:
            terminals.resume(SID, self.folder)
        self.assertIsInstance(popen.call_args[0][0], list)
        self.assertNotIn("shell", popen.call_args[1])

    def test_focus_message(self):
        self.assertIn("pid 42", terminals.focus(42))


class WindowsPaths(unittest.TestCase):
    def test_state_dir_uses_localappdata(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(paths, "IS_WINDOWS", True), \
                mock.patch.dict(os.environ, {"LOCALAPPDATA": d}), mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CLAUDE_TODO_STATE", None)
            self.assertEqual(paths.state_dir(), Path(d) / "claude-todo")

    def test_no_console_window_flag_only_on_windows(self):
        with mock.patch.object(analyzer.sys, "platform", "win32"):
            self.assertEqual(analyzer._no_window(), {"creationflags": 0x08000000})
        with mock.patch.object(analyzer.sys, "platform", "linux"):
            self.assertEqual(analyzer._no_window(), {})

    def test_pid_alive_never_calls_os_kill_on_windows(self):
        with mock.patch.object(scanner.sys, "platform", "win32"), \
                mock.patch.object(scanner, "_pid_alive_windows", return_value=True) as w, \
                mock.patch.object(scanner.os, "kill", side_effect=AssertionError("os.kill sends CTRL_C on Windows")):
            self.assertTrue(scanner.pid_alive(1234))
        w.assert_called_once_with(1234)


@unittest.skipUnless(sys.platform == "win32", "needs real Windows")
class RealWindows(unittest.TestCase):
    def test_own_process_is_alive_and_nonsense_pid_is_not(self):
        self.assertTrue(scanner.pid_alive(os.getpid()))
        self.assertFalse(scanner.pid_alive(2_999_999))

    def test_state_dir_exists(self):
        self.assertTrue(paths.state_dir().is_dir())


if __name__ == "__main__":
    unittest.main()
