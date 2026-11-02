import os
import time
import unittest

from claude_todo import scanner as sc
from .helpers import Home, assistant, line, user


class Scan(unittest.TestCase):
    def setUp(self):
        self.h = Home()
        self.addCleanup(self.h.close)

    def scan(self):
        return sc.Scanner(self.h.claude).scan()

    def test_reads_last_turn(self):
        self.h.transcript("aaaa1111", [user("first ask"), assistant("ok"), user("second ask"), assistant("Want me to deploy?")])
        (s,) = self.scan()
        self.assertEqual((s.turn.first_prompt, s.turn.last_prompt), ("first ask", "second ask"))
        self.assertEqual(s.turn.last_assistant, "Want me to deploy?")
        self.assertEqual(s.cwd, "/home/u/proj")
        self.assertEqual(s.fallback_title, "proj")

    def test_tool_results_and_reminders_are_not_prompts(self):
        tool_result = line("user", [{"type": "tool_result", "content": "x"}])
        reminder = user("<system-reminder>hi</system-reminder>")
        self.h.transcript("bbbb2222", [user("real ask"), assistant(tools=[("Bash", {"command": "ls"})], stop="tool_use"), tool_result, reminder])
        (s,) = self.scan()
        self.assertEqual(s.turn.last_prompt, "real ask")

    def test_sidechain_is_ignored(self):
        self.h.transcript("cccc3333", [user("main ask"), user("sub ask", isSidechain=True)])
        (s,) = self.scan()
        self.assertEqual(s.turn.last_prompt, "main ask")

    def test_new_prompt_resets_the_turn(self):
        self.h.transcript("dddd4444", [user("a"), assistant("Shall I?"), user("b")])
        (s,) = self.scan()
        self.assertEqual((s.turn.last_assistant, s.turn.activity), ("", ""))

    def test_todowrite_is_picked_up(self):
        todos = [{"content": "one", "status": "in_progress", "activeForm": "Doing one"}, {"content": "two", "status": "pending"}]
        self.h.transcript("eeee5555", [user("go"), assistant(tools=[("TodoWrite", {"todos": todos})])])
        (s,) = self.scan()
        self.assertEqual([t["content"] for t in s.turn.todos], ["one", "two"])
        self.assertEqual(s.turn.activity, "Doing one")

    def test_activity_lines(self):
        cases = [
            (("Edit", {"file_path": "/a/b/panel.py"}), "Editing panel.py"),
            (("Read", {"file_path": "/a/b/x.md"}), "Reading x.md"),
            (("Grep", {"pattern": "x"}), "Searching the code"),
            (("Bash", {"command": "make test", "description": "Run the tests"}), "Run the tests"),
            (("Bash", {"command": "make test"}), "Running make test"),
            (("Task", {"description": "audit deps"}), "Sub-agent: audit deps"),
            (("WebSearch", {}), "Searching the web"),
            (("mcp__gh__create_issue", {}), "Using issue"),
        ]
        for tool, want in cases:
            with self.subTest(tool=tool[0]):
                self.assertEqual(sc.activity_of({"content": [{"type": "tool_use", "name": tool[0], "input": tool[1]}]}), want)
        self.assertEqual(sc.activity_of({"content": [{"type": "text", "text": "hi"}]}), "Writing a reply")

    def test_old_sessions_are_skipped(self):
        self.h.transcript("ffff6666", [user("old")], age=40 * 24 * 3600)
        self.assertEqual(self.scan(), [])

    def test_empty_and_garbage_lines(self):
        self.h.transcript("0000aaaa", ["", "not json", "{", user("fine")])
        (s,) = self.scan()
        self.assertEqual(s.turn.last_prompt, "fine")

    def test_big_file_reads_only_the_tail(self):
        filler = [assistant("x" * 1000) for _ in range(7000)]    # > 6 MB
        self.h.transcript("1111bbbb", [user("ancient")] + filler + [user("recent ask")])
        (s,) = self.scan()
        self.assertEqual(s.turn.last_prompt, "recent ask")
        self.assertEqual(s.turn.first_prompt, "recent ask")      # the head was never read

    def test_registry_live_busy_name(self):
        self.h.transcript("2222cccc", [user("hi")])
        self.h.register("2222cccc", status="busy", name="Voice work")
        (s,) = self.scan()
        self.assertTrue(s.live and s.busy)
        self.assertEqual(s.name, "Voice work")
        self.assertEqual(s.pid, os.getpid())

    def test_dead_pid_means_closed(self):
        self.h.transcript("3333dddd", [user("hi")])
        self.h.register("3333dddd", pid=2_999_999, status="busy", name="Gone")
        (s,) = self.scan()
        self.assertFalse(s.live or s.busy)
        self.assertEqual(s.name, "Gone")

    def test_cache_reparses_on_change(self):
        f = self.h.transcript("4444eeee", [user("one")])
        scanner = sc.Scanner(self.h.claude)
        self.assertEqual(scanner.scan()[0].turn.last_prompt, "one")
        f.write_text(user("two") + "\n")
        os.utime(f, (time.time() + 5, time.time() + 5))
        self.assertEqual(scanner.scan()[0].turn.last_prompt, "two")

    def test_missing_dirs_do_not_crash(self):
        self.assertEqual(sc.Scanner(self.h.root / "nope").scan(), [])


if __name__ == "__main__":
    unittest.main()
