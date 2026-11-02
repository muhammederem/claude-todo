import os
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
try:
    from PySide6.QtWidgets import QApplication, QLabel, QPushButton
    from claude_todo import gui
    HAVE_QT = True
except ImportError:
    HAVE_QT = False

from claude_todo import autostart
from claude_todo.build import Hidden, Manual
from claude_todo.scanner import Scanner
from .helpers import Home, assistant, user

SID1, SID2 = "aaaa1111-0000-0000-0000-000000000001", "bbbb2222-0000-0000-0000-000000000002"


class FakeAnalyzer:
    """Stands in for Analyzer: hands out ready-made summaries."""
    problem = None

    def __init__(self, data):
        self.data = data

    def consider(self, sessions): pass
    def is_analyzing(self, sid): return False
    def is_pending(self, sid): return False
    def analysis(self, sid): return self.data.get(sid)


def texts(widget):
    return [l.text() for l in widget.findChildren(QLabel)]


@unittest.skipUnless(HAVE_QT, "PySide6 not installed")
class PanelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.h = Home()
        self.addCleanup(self.h.close)
        self.h.transcript(SID1, [user("redo checkout"), assistant("Would you like me to ship the new copy?")], age=3600)
        self.h.transcript(SID2, [user("fix webhook"), assistant("Which retry policy should I use?")], age=1800)
        self.h.register(SID2, name="Webhooks")

    def panel(self, analysis=None):
        p = gui.Panel(Scanner(self.h.claude), FakeAnalyzer(analysis) if analysis is not None else None, Hidden(), Manual())
        self.addCleanup(p.deleteLater)
        self.addCleanup(p.timer.stop)
        return p

    def test_tabs_and_first_real_session_selected(self):
        p = self.panel()
        self.assertEqual([s.title for s in p.sessions], ["Mine", "Webhooks", "proj"])
        self.assertEqual(p.tabs.count(), 3)
        self.assertEqual(p.selected.title, "Webhooks")
        self.assertIn("1 waiting", p.head.text())
        self.assertIn("Which retry policy should I use?", texts(p))

    def test_switching_tabs_changes_the_list(self):
        p = self.panel()
        p.tabs.setCurrentIndex(2)
        self.assertEqual(p.selected.title, "proj")
        self.assertIn("Left off: redo checkout", texts(p))
        self.assertNotIn("Which retry policy should I use?", texts(p))

    def test_ai_summary_is_shown_with_details_and_you_marker(self):
        analysis = {SID2: {"title": "Webhook retries", "items": [
            {"text": "Pick a retry policy", "detail": "Needs your decision.", "state": "pending", "needs_you": True},
            {"text": "Add the retry test", "detail": "Times out today.", "state": "in_progress", "needs_you": False}]}}
        p = self.panel(analysis)
        self.assertEqual(p.selected.title, "Webhook retries")
        self.assertEqual(p.head.text(), "2 waiting · 1 on you")
        t = texts(p)
        self.assertIn("Pick a retry policy", t)
        self.assertIn("Needs your decision.", t)
        self.assertIn("✋", t)
        self.assertLess(t.index("Pick a retry policy"), t.index("Add the retry test"))     # waiting-on-you first

    def test_busy_session_shows_the_live_line(self):
        self.h.transcript(SID2, [user("go"), assistant(tools=[("Edit", {"file_path": "/x/app.py"})], stop="tool_use")])
        self.h.register(SID2, status="busy", name="Webhooks")
        p = self.panel()
        self.assertFalse(p.now.isHidden())
        self.assertIn("Editing app.py", p.now.text())

    def test_done_button_removes_the_task_and_persists(self):
        p = self.panel()
        p.findChildren(QPushButton, "done")[0].click()
        self.assertNotIn("Webhooks", [x.title for x in p.sessions])     # an empty session drops out of the tabs
        self.assertEqual(Hidden().count, 1)
        self.assertEqual(p.restore_btn.text(), "Restore hidden (1)")
        p._restore()
        self.assertEqual(Hidden().count, 0)
        p.tabs.setCurrentIndex(next(i for i, x in enumerate(p.sessions) if x.title == "Webhooks"))
        self.assertIn("Which retry policy should I use?", texts(p))

    def test_add_task_goes_to_mine(self):
        p = self.panel()
        p.entry.setText("call the dentist")
        p.entry.returnPressed.emit()
        self.assertEqual(p.selected.title, "Mine")
        self.assertIn("call the dentist", texts(p))
        self.assertEqual(p.entry.text(), "")
        p.findChildren(QPushButton, "done")[0].click()      # ✕ deletes manual tasks
        self.assertEqual(Manual().tasks, [])

    def test_hide_tab(self):
        p = self.panel()
        p._hide_tab()
        self.assertNotIn("Webhooks", [s.title for s in p.sessions])
        self.assertEqual(Hidden().count, 1)

    def test_resume_calls_the_launcher_for_the_selected_session(self):
        p = self.panel()
        with mock.patch("claude_todo.gui.open_session", return_value="Opened in xterm.") as o:
            p._resume()
        self.assertEqual(o.call_args[0][0].title, "Webhooks")
        self.assertEqual(p.state.text(), "Opened in xterm.")

    def test_resume_error_is_shown_not_raised(self):
        p = self.panel()
        with mock.patch("claude_todo.gui.open_session", side_effect=RuntimeError("No terminal emulator found.")):
            p._resume()
        self.assertEqual(p.state.text(), "No terminal emulator found.")

    def test_tray_counts_and_notifications(self):
        analysis = {SID2: {"title": "Webhooks", "items": [{"text": "Pick a policy", "detail": "d", "state": "pending", "needs_you": True}]}}
        p = self.panel(analysis)
        counts, notes = [], []
        p.on_count = lambda c, y: counts.append((c, y))
        p.on_notify = lambda t, b: notes.append((t, b))
        self.assertEqual(len(p.notified), 1)                # tasks already waiting at launch are noted but not announced
        p.notified.clear()
        p.sessions[1].updated_at = time.time() - 3600       # idle for an hour
        p._notify_waiting()
        p._notify_waiting()
        self.assertEqual(len(notes), 1)                      # once per task
        self.assertIn("Webhooks", notes[0][0])
        p.refresh()
        self.assertEqual(counts[-1], (p.sessions[1].open_count + p.sessions[2].open_count, True))

    def test_no_notification_for_recent_or_busy_sessions(self):
        analysis = {SID2: {"title": "Webhooks", "items": [{"text": "Pick a policy", "detail": "", "state": "pending", "needs_you": True}]}}
        p = self.panel(analysis)
        notes = []
        p.on_notify = lambda t, b: notes.append(t)
        p.sessions[1].updated_at = time.time()
        p._notify_waiting()
        self.assertEqual(notes, [])

    def test_icon_draws_for_every_state(self):
        for count, you in ((0, False), (3, False), (12, True)):
            pm = gui.tray_icon(count, you).pixmap(64, 64)
            self.assertFalse(pm.isNull())
            self.assertFalse(pm.toImage().allGray() and count > 0 and not you and False)

    def test_window_renders_to_an_image(self):
        p = self.panel()
        p.show()
        img = p.grab().toImage()
        self.assertGreater(img.width(), 300)
        self.assertGreater(img.height(), 400)
        out = os.environ.get("CLAUDE_TODO_SCREENSHOT")
        if out:
            img.save(out)

    def test_empty_install_does_not_crash(self):
        for f in (self.h.claude / "projects" / "-home-u-proj").glob("*.jsonl"):
            f.unlink()
        p = self.panel()
        self.assertEqual(p.selected.title, "Mine")
        self.assertIn("All clear", p.head.text())


class Autostart(unittest.TestCase):
    @unittest.skipIf(sys.platform == "win32", "uses the XDG file")
    def test_desktop_entry_roundtrip(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": d}):
            self.assertFalse(autostart.is_enabled())
            autostart.set_enabled(True)
            f = Path(d) / "autostart" / "claude-todo.desktop"
            self.assertTrue(autostart.is_enabled())
            text = f.read_text()
            self.assertIn("[Desktop Entry]", text)
            self.assertIn("-m claude_todo gui --tray", text)
            autostart.set_enabled(False)
            self.assertFalse(f.exists())
            autostart.set_enabled(False)      # already off: no error

    def test_windows_command_uses_pythonw(self):
        with mock.patch.object(autostart.sys, "platform", "win32"), mock.patch.object(autostart.sys, "executable", r"C:\Py\python.exe"):
            self.assertEqual(autostart._command()[0], r"C:\Py\pythonw.exe")


if __name__ == "__main__":
    unittest.main()
