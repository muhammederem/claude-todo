import unittest

from claude_todo import openwork as ow
from claude_todo.openwork import TurnInfo


class OpenWork(unittest.TestCase):
    def items(self, assistant, live=True, busy=False, prompt="do the thing please", stop="end_turn", todos=None):
        return ow.items_for(TurnInfo(last_prompt=prompt, last_assistant=assistant, stop_reason=stop, todos=todos), live, busy)

    def test_offer_at_end_of_answer(self):
        got = self.items("Done with the refactor.\n\nWould you like me to deploy it to staging?")
        self.assertEqual([i.kind for i in got], ["offer"])
        self.assertIn("deploy it to staging", got[0].content)

    def test_only_the_last_offer_is_kept(self):
        got = self.items("Want me to add tests? Also, shall I update the docs?")
        self.assertEqual(len(got), 1)
        self.assertIn("docs", got[0].content)

    def test_turkish_capital_dotted_i(self):
        # "İstersen" must match: Swift's regex missed it once
        got = self.items("Bitti.\n\nİstersen o bölümü detaylandırırım.")
        self.assertEqual(len(got), 1)

    def test_turkish_lowercase_trigger(self):
        self.assertEqual(len(self.items("Hazır. istersen yarın devam ederiz.")), 1)

    def test_url_dots_do_not_split_sentences(self):
        got = self.items("Open dashboard.ngrok.com/foo and tell me if it works. Want me to continue?")
        self.assertEqual(got[0].content, "Want me to continue?")

    def test_unchecked_boxes(self):
        got = self.items("Status:\n- [x] done thing\n- [ ] write the migration script\n- [ ] update changelog entry")
        self.assertEqual([i.content for i in got], ["write the migration script", "update changelog entry"])

    def test_next_steps_heading(self):
        got = self.items("Finished part one.\n\nNext steps:\n- wire the webhook handler\n- add retry tests\n")
        self.assertEqual([i.content for i in got], ["wire the webhook handler", "add retry tests"])

    def test_plain_statement_is_not_a_task(self):
        self.assertEqual(self.items("I fixed the bug and all tests pass."), [])

    def test_todowrite_is_authoritative(self):
        todos = [{"content": "ship it", "status": "pending"}, {"content": "old", "status": "completed"}]
        got = self.items("Want me to also do something else?", todos=todos)
        self.assertEqual([i.content for i in got], ["ship it"])

    def test_completed_todowrite_falls_back_to_rules(self):
        todos = [{"content": "old", "status": "completed"}]
        got = self.items("Should I push it?", todos=todos)
        self.assertEqual(len(got), 1)

    def test_closed_session_gets_resume_item_first(self):
        got = self.items("Shall I continue?", live=False, prompt="fix the login page")
        self.assertEqual(got[0].kind, "resume")
        self.assertTrue(got[0].content.startswith("Left off: fix the login page"))

    def test_interrupted_closed_session(self):
        got = self.items("", live=False, stop="tool_use", prompt="run the build")
        self.assertTrue(got[0].content.startswith("Interrupted: "))

    def test_interrupted_live_session_lists_the_prompt(self):
        got = self.items("API Error: overloaded", live=True, prompt="refactor the parser")
        self.assertEqual(got[0].kind, "interrupted")

    def test_busy_session_with_tool_use_is_not_interrupted(self):
        self.assertEqual(self.items("", live=True, busy=True, stop="tool_use"), [])

    def test_cap_and_dedupe(self):
        text = "\n".join(f"- [ ] {w}" for w in ("write migration", "rotate credentials", "update changelog", "tag release", "notify customers"))
        self.assertEqual(len(self.items(text)), ow.MAX_ITEMS)
        got = self.items("- [ ] update the changelog file\n- [ ] Update the changelog file!")
        self.assertEqual(len(got), 1)

    def test_code_blocks_are_ignored(self):
        got = self.items("```\nWould you like a pony?\n```\nAll good.")
        self.assertEqual(got, [])

    def test_shorten(self):
        self.assertEqual(ow.shorten("short"), "short")
        self.assertTrue(ow.shorten("word " * 40).endswith("…"))
        self.assertLessEqual(len(ow.shorten("word " * 40)), 73)


if __name__ == "__main__":
    unittest.main()
