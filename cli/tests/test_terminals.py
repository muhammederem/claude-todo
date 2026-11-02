import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from claude_todo import terminals as t

SID = "0123abcd-4567-89ef-0123-456789abcdef"


def fake_bin(directory, name, body="exit 0\n"):
    p = Path(directory) / name
    p.write_text("#!/bin/sh\n" + body)
    p.chmod(p.stat().st_mode | stat.S_IEXEC)


class Commands(unittest.TestCase):
    def test_resume_command_quotes_hostile_paths(self):
        d = tempfile.mkdtemp()
        nasty = os.path.join(d, "it's a \"dir\"; touch pwned")
        os.mkdir(nasty)
        argv = t.resume_command(SID, nasty)
        self.assertEqual(argv[:2], ["sh", "-c"])
        # run it with `claude` replaced by a stub: the directory must be entered and nothing else executed
        fake_bin(d, "claude", 'pwd > "$OUT"; echo "$@" >> "$OUT"\n')
        out = os.path.join(d, "out.txt")
        env = {**os.environ, "PATH": d + os.pathsep + os.environ["PATH"], "OUT": out, "SHELL": "/usr/bin/true"}
        import subprocess
        r = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
        self.assertEqual(r.returncode, 0, r.stderr)
        got = Path(out).read_text().split("\n")
        self.assertTrue(os.path.samefile(got[0], nasty))
        self.assertEqual(got[1], f"--resume {SID}")
        self.assertFalse(os.path.exists(os.path.join(nasty, "pwned")))

    def test_missing_cwd_falls_back_to_home(self):
        self.assertIn(shlex_home(), t.resume_command(SID, "/definitely/not/here")[2])

    def test_bad_session_ids_are_rejected(self):
        for bad in ("", "x", "abc; rm -rf /", "../../etc", "g" * 12, SID + "$(id)"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                t.resume_command(bad, "/tmp")

    def test_terminal_argv(self):
        inner = ["sh", "-c", "x"]
        self.assertEqual(t.terminal_argv("kitty", inner), ["kitty", *inner])
        self.assertEqual(t.terminal_argv("gnome-terminal", inner), ["gnome-terminal", "--", *inner])
        self.assertEqual(t.terminal_argv("konsole", inner), ["konsole", "-e", *inner])
        self.assertEqual(t.terminal_argv("wezterm", inner), ["wezterm", "start", "--", *inner])
        self.assertEqual(t.terminal_argv("x-terminal-emulator", inner), ["x-terminal-emulator", "-e", *inner])
        self.assertEqual(t.terminal_argv("mytty", inner), ["mytty", "-e", *inner])


def shlex_home():
    import shlex
    return shlex.quote(os.path.expanduser("~"))


class Picking(unittest.TestCase):
    def setUp(self):
        self.bin = tempfile.TemporaryDirectory()
        self.addCleanup(self.bin.cleanup)
        self.env = mock.patch.dict(os.environ, {"PATH": self.bin.name}, clear=False)
        self.env.start()
        self.addCleanup(self.env.stop)
        for k in ("TERMINAL", "CLAUDE_TODO_TERMINAL"):
            os.environ.pop(k, None)

    def test_no_terminal_installed(self):
        self.assertIsNone(t.pick_terminal())
        with self.assertRaises(RuntimeError):
            t.resume(SID, "/tmp")

    def test_known_terminal_is_found(self):
        fake_bin(self.bin.name, "konsole")
        self.assertEqual(t.pick_terminal(), "konsole")

    def test_x_terminal_emulator_wins_over_the_list(self):
        fake_bin(self.bin.name, "xterm")
        fake_bin(self.bin.name, "x-terminal-emulator")
        self.assertEqual(t.pick_terminal(), "x-terminal-emulator")

    def test_env_override(self):
        fake_bin(self.bin.name, "xterm")
        fake_bin(self.bin.name, "foot")
        os.environ["TERMINAL"] = "foot"
        self.assertEqual(t.pick_terminal(), "foot")
        os.environ["CLAUDE_TODO_TERMINAL"] = "xterm"
        os.environ["TERMINAL"] = "foot"
        self.assertEqual(t.pick_terminal(), "xterm")      # the app-specific variable wins over $TERMINAL

    def test_session_host_terminal_beats_default(self):
        fake_bin(self.bin.name, "kitty")
        fake_bin(self.bin.name, "xterm")
        with mock.patch.object(t, "host_terminal", return_value="kitty"):
            self.assertEqual(t.pick_terminal(1234), "kitty")

    def test_resume_launches_the_terminal_with_the_right_command(self):
        out = Path(self.bin.name) / "argv.txt"
        fake_bin(self.bin.name, "xterm", f'printf "%s\\n" "$@" > {out}\n')
        argv = t.resume(SID, "/tmp")
        for _ in range(50):
            if out.exists() and out.read_text():
                break
            import time
            time.sleep(0.05)
        self.assertEqual(argv[:2], ["xterm", "-e"])
        recorded = out.read_text().split("\n")
        self.assertEqual(recorded[0], "-e")
        self.assertIn(f"claude --resume {SID}", recorded[3])

    def test_dry_run_does_not_launch(self):
        fake_bin(self.bin.name, "xterm", "touch /tmp/claude-todo-should-not-exist\n")
        t.resume(SID, "/tmp", dry_run=True)
        self.assertFalse(os.path.exists("/tmp/claude-todo-should-not-exist"))


class ProcessTree(unittest.TestCase):
    def test_stat_parsing_handles_spaces_and_parens_in_names(self):
        raw = "4242 (my (weird) app) S 100 4242 4242 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 1 1 1\n"
        with mock.patch("builtins.open", mock.mock_open(read_data=raw)):
            self.assertEqual(t._proc_stat(4242), (100, "my (weird) app"))

    def test_stat_missing_procfs(self):
        with mock.patch("builtins.open", side_effect=FileNotFoundError):
            self.assertIsNone(t._proc_stat(1))

    def test_host_terminal_walks_up(self):
        tree = {500: (400, "claude"), 400: (300, "zsh"), 300: (200, "gnome-terminal-"), 200: (1, "systemd")}
        with mock.patch.object(t, "_proc_stat", side_effect=lambda p: tree.get(p)):
            self.assertEqual(t.host_terminal(500), "gnome-terminal")

    def test_host_terminal_none_when_chain_ends(self):
        tree = {500: (400, "claude"), 400: (1, "sshd")}
        with mock.patch.object(t, "_proc_stat", side_effect=lambda p: tree.get(p)):
            self.assertIsNone(t.host_terminal(500))

    def test_focus_without_xdotool_says_where_it_is(self):
        tree = {500: (300, "claude"), 300: (1, "kitty")}
        with mock.patch.object(t, "_proc_stat", side_effect=lambda p: tree.get(p)), mock.patch.object(t.shutil, "which", return_value=None):
            msg = t.focus(500)
        self.assertIn("kitty", msg)
        self.assertIn("500", msg)


if __name__ == "__main__":
    unittest.main()
