import json
import os
import stat
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from claude_todo import analyzer as an
from claude_todo import build, cli
from claude_todo import scanner as sc
from .helpers import Home, assistant, user

FAKE_REPLY = json.dumps({"is_error": False, "result": "```json\n" + json.dumps({
    "title": "Checkout flow",
    "items": [{"title": "Approve the pricing copy", "detail": "Waiting for your pick.", "state": "pending", "owner": "you"},
              {"title": "Fix the webhook test", "detail": "Times out after the new check.", "state": "in_progress", "owner": "claude"}]}) + "\n```"})


def fake_claude(directory: Path, body: str) -> str:
    path = directory / "claude"
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return str(directory)


class ParseOutput(unittest.TestCase):
    def test_wrapped_json(self):
        out = an.parse_output(FAKE_REPLY)
        self.assertEqual(out["title"], "Checkout flow")
        self.assertEqual([i["needs_you"] for i in out["items"]], [True, False])
        self.assertEqual(out["items"][1]["state"], "in_progress")

    def test_garbage_and_errors(self):
        self.assertIsNone(an.parse_output("nope"))
        self.assertIsNone(an.parse_output(json.dumps({"is_error": True, "result": "{}"})))
        self.assertIsNone(an.parse_output(json.dumps({"result": "no json here"})))

    def test_empty_list_is_valid(self):
        self.assertEqual(an.parse_output(json.dumps({"result": '{"title":"x","items":[]}'}))["items"], [])

    def test_caps_at_three_items(self):
        items = [{"title": f"t{i}", "detail": "", "state": "pending", "owner": "claude"} for i in range(6)]
        self.assertEqual(len(an.parse_output(json.dumps({"result": json.dumps({"title": "x", "items": items})}))["items"]), 3)


class Pipeline(unittest.TestCase):
    def setUp(self):
        self.h = Home()
        self.addCleanup(self.h.close)
        self.bin = tempfile.TemporaryDirectory()
        self.addCleanup(self.bin.cleanup)

    def sessions(self, analyzer=None, hidden=None):
        return build.build_sessions(sc.Scanner(self.h.claude).scan(), analyzer, hidden or build.Hidden())

    def test_digest_contains_the_conversation(self):
        self.h.transcript("aaaa1111", [user("add dark mode"), assistant("Sure. Want me to start with the settings page?")], age=600)
        (s,) = sc.Scanner(self.h.claude).scan()
        text = an.digest(s)
        self.assertIn("[user] add dark mode", text)
        self.assertIn("[claude] Sure. Want me", text)
        self.assertIn("/home/u/proj", text)

    def test_end_to_end_with_a_fake_claude_cli(self):
        argsfile = Path(self.bin.name) / "args.txt"
        stdinfile = Path(self.bin.name) / "stdin.txt"
        reply = Path(self.bin.name) / "reply.json"
        reply.write_text(FAKE_REPLY)
        d = fake_claude(Path(self.bin.name), f'printf "%s\\n" "$@" > {argsfile}\ncat > {stdinfile}\ncat {reply}\n')
        self.h.transcript("aaaa1111", [user("redo checkout"), assistant("Want me to ship the new copy?")], age=600)
        with mock.patch.dict(os.environ, {"PATH": d + os.pathsep + os.environ["PATH"]}):
            a = an.Analyzer(True)
            (before,) = self.sessions(a)
            self.assertTrue(before.analyzing and before.items == [])      # waiting for the summary
            cli.collect(sc.Scanner(self.h.claude), a, build.Hidden(), build.Manual(), wait=True)
            (after,) = self.sessions(a)
        self.assertEqual(after.title, "Checkout flow")
        self.assertEqual([i.content for i in after.items], ["Approve the pricing copy", "Fix the webhook test"])
        self.assertTrue(after.items[0].needs_you)
        self.assertFalse(after.analyzing)
        args = argsfile.read_text().split("\n")
        for flag in ("-p", "haiku", "--no-session-persistence", "--tools", "--disable-slash-commands"):
            self.assertIn(flag, args)
        self.assertIn("redo checkout", stdinfile.read_text())
        self.assertTrue((self.h.state / "analysis.json").exists())

    def test_cached_summary_is_reused_and_survives_restart(self):
        d = fake_claude(Path(self.bin.name), "cat > /dev/null\n" + "cat <<'EOF'\n" + FAKE_REPLY + "\nEOF\n")
        self.h.transcript("aaaa1111", [user("redo checkout"), assistant("ok")], age=600)
        with mock.patch.dict(os.environ, {"PATH": d + os.pathsep + os.environ["PATH"]}):
            cli.collect(sc.Scanner(self.h.claude), an.Analyzer(True), build.Hidden(), build.Manual(), wait=True)
        os.remove(Path(self.bin.name) / "claude")       # the CLI is gone; the cache must still serve
        with mock.patch.dict(os.environ, {"PATH": "/nonexistent"}):
            (s,) = self.sessions(an.Analyzer(True))
        self.assertEqual(s.title, "Checkout flow")

    def test_missing_cli_falls_back_to_rules_and_reports_it(self):
        self.h.transcript("aaaa1111", [user("x"), assistant("Should I push it?")], age=600)
        with mock.patch.dict(os.environ, {"PATH": "/nonexistent"}), mock.patch.object(an, "find_claude", return_value=None):
            a = an.Analyzer(True)
            (s,) = self.sessions(a)
            self.assertEqual([i.kind for i in s.items], ["resume", "offer"])      # closed session: resume item + the offer
            self.assertIn("not found", a.problem)

    def test_failing_cli_is_reported_and_not_retried_at_once(self):
        d = fake_claude(Path(self.bin.name), "cat > /dev/null\necho 'Not logged in' >&2\nexit 1\n")
        self.h.transcript("aaaa1111", [user("x"), assistant("Should I push it?")], age=600)
        with mock.patch.dict(os.environ, {"PATH": d + os.pathsep + os.environ["PATH"]}):
            a = an.Analyzer(True)
            cli.collect(sc.Scanner(self.h.claude), a, build.Hidden(), build.Manual(), wait=True)
            self.assertIn("logged in", a.problem)
            (s,) = self.sessions(a)
            self.assertEqual([i.kind for i in s.items], ["resume", "offer"])  # rules take over
            self.assertFalse(a.is_pending("aaaa1111"))

    def test_recently_active_session_is_not_summarized_yet(self):
        d = fake_claude(Path(self.bin.name), "exit 1\n")
        self.h.transcript("aaaa1111", [user("x"), assistant("hi")])       # modified just now
        with mock.patch.dict(os.environ, {"PATH": d + os.pathsep + os.environ["PATH"]}):
            a = an.Analyzer(True)
            a.consider(sc.Scanner(self.h.claude).scan())
            self.assertFalse(a.is_analyzing("aaaa1111"))

    def test_hidden_tab_returns_when_the_session_changes(self):
        f = self.h.transcript("aaaa1111", [user("x"), assistant("Should I push it?")])
        scanned = sc.Scanner(self.h.claude).scan()
        hidden = build.Hidden()
        hidden.tabs["aaaa1111"] = scanned[0].fingerprint
        self.assertEqual(build.build_sessions(scanned, None, hidden), [])
        f.write_text(f.read_text() + user("more") + "\n")
        os.utime(f, (time.time() + 9, time.time() + 9))
        self.assertEqual(len(self.sessions(None, hidden)), 1)

    def test_hidden_state_persists_and_restores(self):
        hidden = build.Hidden()
        hidden.items.add("s|abc")
        hidden.tabs["s"] = "1-2"
        hidden.save()
        again = build.Hidden()
        self.assertEqual(again.count, 2)
        again.clear()
        self.assertEqual(build.Hidden().count, 0)

    def test_busy_session_is_listed_without_tasks(self):
        self.h.transcript("aaaa1111", [user("go"), assistant(tools=[("Edit", {"file_path": "/x/app.py"})], stop="tool_use")])
        self.h.register("aaaa1111", status="busy")
        (s,) = self.sessions()
        self.assertTrue(s.busy)
        self.assertEqual(s.now_doing, "Editing app.py")

    def test_old_closed_session_with_only_resume_fades(self):
        self.h.transcript("aaaa1111", [user("x"), assistant("done")], age=8 * 24 * 3600)
        self.assertEqual(self.sessions(), [])
        self.h.transcript("bbbb2222", [user("y"), assistant("done")], age=2 * 24 * 3600)
        self.assertEqual(len(self.sessions()), 1)

    def test_running_sessions_sort_first_and_duplicate_titles_get_numbers(self):
        self.h.transcript("aaaa1111", [user("x"), assistant("Should I update the docs?")], age=100)
        self.h.transcript("bbbb2222", [user("y"), assistant("Should I update the docs?")], age=50)
        self.h.register("aaaa1111")
        got = self.sessions()
        self.assertEqual([s.id for s in got], ["aaaa1111", "bbbb2222"])
        self.assertEqual([s.title for s in got], ["proj", "proj 2"])

    def test_manual_tasks(self):
        m = build.Manual()
        m.add("  call the dentist ")
        m.add("")
        self.assertEqual([t["text"] for t in build.Manual().tasks], ["call the dentist"])
        tid = m.tasks[0]["id"]
        m.toggle(tid)
        self.assertEqual(m.session().open_count, 0)
        m.remove(tid)
        self.assertEqual(build.Manual().tasks, [])


if __name__ == "__main__":
    unittest.main()
