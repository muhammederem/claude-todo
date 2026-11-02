import contextlib
import io
import json
import os
import select
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from claude_todo import cli
from .helpers import Home, assistant, user

PKG_ROOT = str(Path(__file__).resolve().parents[1])


def run(*args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = cli.main(list(args))
        except SystemExit as e:
            code = e.code
    return code, out.getvalue(), err.getvalue()


class Cli(unittest.TestCase):
    def setUp(self):
        self.h = Home()
        self.addCleanup(self.h.close)
        self.h.transcript("aaaa1111-0000-0000-0000-000000000001",
                          [user("redo checkout"), assistant("Done.\n\nWould you like me to ship the new copy?")], age=600)
        self.h.transcript("bbbb2222-0000-0000-0000-000000000002",
                          [user("fix webhook"), assistant("Which retry policy should I use?")], age=300)
        self.h.register("bbbb2222-0000-0000-0000-000000000002", name="Webhooks")

    def test_list(self):
        code, out, _ = run("--no-ai", "list")
        self.assertEqual(code, 0)
        self.assertIn("Webhooks", out)
        self.assertIn("1. ○ Which retry policy should I use?", out)
        self.assertIn("Left off: redo checkout", out)

    def test_json_is_valid_and_complete(self):
        code, out, _ = run("--no-ai", "json")
        data = json.loads(out)
        self.assertEqual(code, 0)
        titles = [s["title"] for s in data["sessions"]]
        self.assertEqual(titles[0], "Mine")
        self.assertIn("Webhooks", titles)
        web = next(s for s in data["sessions"] if s["title"] == "Webhooks")
        self.assertTrue(web["live"])
        self.assertEqual(web["items"][0]["kind"], "offer")

    def test_waybar_shape(self):
        _, out, _ = run("--no-ai", "waybar")
        w = json.loads(out)
        self.assertEqual(set(w), {"text", "tooltip", "class", "alt"})
        self.assertEqual(w["class"], "waiting")
        self.assertIn("Webhooks", w["tooltip"])

    def test_waybar_clear(self):
        for f in (self.h.claude / "projects" / "-home-u-proj").glob("*.jsonl"):
            f.unlink()
        w = json.loads(run("--no-ai", "waybar")[1])
        self.assertEqual((w["text"], w["class"]), ("✓", "clear"))

    def test_waybar_counts_tasks_waiting_on_you(self):
        sessions = [cli.Session("s", "A", "", [cli.Session and __import__("claude_todo.openwork", fromlist=["Item"]).Item("1", "x", needs_you=True)], time.time())]
        w = cli.waybar(sessions)
        self.assertEqual((w["text"], w["class"]), ("1 ✋1", "you"))

    def test_add_and_done_on_mine(self):
        self.assertEqual(run("add", "call", "the", "dentist")[0], 0)
        self.assertIn("call the dentist", run("--no-ai", "list")[1])
        self.assertEqual(run("--no-ai", "done", "mine", "1")[0], 0)
        self.assertNotIn("○ call the dentist", run("--no-ai", "list")[1])

    def test_hide_restore_and_task_done(self):
        self.assertEqual(run("--no-ai", "hide", "Webhooks")[0], 0)
        self.assertNotIn("Webhooks", run("--no-ai", "list")[1])
        run("restore")
        self.assertIn("Webhooks", run("--no-ai", "list")[1])
        run("--no-ai", "done", "Webhooks", "1")
        self.assertNotIn("Which retry policy", run("--no-ai", "list")[1])

    def test_unknown_or_ambiguous_session(self):
        code, _, err = run("--no-ai", "hide", "nope")
        self.assertEqual(code, 1)
        self.assertIn("No single session", err)

    def test_done_needs_a_valid_number(self):
        code, _, err = run("--no-ai", "done", "Webhooks", "9")
        self.assertEqual(code, 1)
        self.assertIn("task number", err)

    def test_resume_closed_session_opens_a_terminal(self):
        bindir = tempfile.mkdtemp()
        rec = Path(bindir) / "argv.txt"
        x = Path(bindir) / "xterm"
        x.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > {rec}\n')
        x.chmod(x.stat().st_mode | stat.S_IEXEC)
        with mock.patch.dict(os.environ, {"PATH": bindir}):
            code, out, _ = run("--no-ai", "resume", "proj")      # the closed one is titled "proj"
        self.assertEqual(code, 0, out)
        self.assertIn("Opened in xterm", out)
        for _ in range(60):
            if rec.exists() and rec.read_text():
                break
            time.sleep(0.05)
        self.assertIn("claude --resume aaaa1111-0000-0000-0000-000000000001", rec.read_text())

    def test_resume_running_session_does_not_open_a_second_one(self):
        with mock.patch("claude_todo.terminals.focus", return_value="Already running in kitty (pid 1).") as f, \
                mock.patch("claude_todo.terminals.resume") as r:
            code, out, _ = run("--no-ai", "resume", "Webhooks")
        self.assertEqual(code, 0)
        self.assertIn("Already running", out)
        f.assert_called_once()
        r.assert_not_called()

    def test_resume_without_any_terminal_is_a_clean_error(self):
        with mock.patch.dict(os.environ, {"PATH": "/nonexistent"}):
            code, _, err = run("--no-ai", "resume", "proj")
        self.assertEqual(code, 1)
        self.assertIn("No terminal", err)

    def test_ago(self):
        now = 1_000_000
        self.assertEqual(cli.ago(now - 10, now), "just now")
        self.assertEqual(cli.ago(now - 600, now), "10m ago")
        self.assertEqual(cli.ago(now - 7200, now), "2h ago")
        self.assertEqual(cli.ago(now - 3 * 86400, now), "3d ago")

    def test_nothing_at_all(self):
        for f in (self.h.claude / "projects" / "-home-u-proj").glob("*.jsonl"):
            f.unlink()
        self.assertEqual(run("--no-ai", "list")[1].strip(), "Nothing waiting.")


@unittest.skipUnless(hasattr(os, "fork") and sys.platform != "win32", "needs a pty")
class Tui(unittest.TestCase):
    """Runs the real curses panel in a pseudo-terminal."""

    def test_draws_and_quits(self):
        import fcntl
        import pty
        import struct
        import subprocess
        import termios
        h = Home()
        self.addCleanup(h.close)
        h.transcript("aaaa1111-0000-0000-0000-000000000001", [user("redo checkout"), assistant("Would you like me to ship it?")], age=600)
        h.register("aaaa1111-0000-0000-0000-000000000001", name="Checkout")
        env = {**os.environ, "TERM": "xterm-256color", "PYTHONPATH": PKG_ROOT}
        # openpty + subprocess instead of pty.fork(): forking a process that already has threads can deadlock
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        proc = subprocess.Popen([sys.executable, "-m", "claude_todo", "--no-ai"], stdin=slave, stdout=slave, stderr=slave,
                                env=env, close_fds=True, start_new_session=True)
        os.close(slave)
        self.addCleanup(lambda: proc.poll() is None and proc.kill())

        def drain(seconds):
            data, end = b"", time.time() + seconds
            while time.time() < end:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        data += os.read(master, 65536)
                    except OSError:
                        break
            return data

        screen = b""
        deadline = time.time() + 8
        while time.time() < deadline and b"Would you like" not in screen:
            screen += drain(0.3)
        os.write(master, b"q")
        for _ in range(40):          # a pty child cannot finish exiting until its output is read (macOS)
            drain(0.1)
            if proc.poll() is not None:
                break
        else:
            proc.kill()
            self.fail("TUI did not exit on q")
        os.close(master)
        status = proc.returncode
        self.assertIn(b"Checkout", screen)
        self.assertIn("Would you like me to ship it?".encode(), screen)
        self.assertEqual(status, 0)


if __name__ == "__main__":
    unittest.main()
