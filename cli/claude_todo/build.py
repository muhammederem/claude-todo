"""Merges scan results (and the optional model summary) into the sessions shown to the user. Port of buildSessions."""
import json
import re
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set

from .analyzer import MAX_ITEMS, Analyzer
from .openwork import Item, items_for
from .paths import state_dir
from .scanner import Scanned

CLOSED_WINDOW = 7 * 24 * 3600     # closed sessions with nothing pending fade out of the list
MANUAL_ID = "manual"


@dataclass
class Session:
    id: str
    title: str
    cwd: str
    items: List[Item]
    updated_at: float
    live: bool = True
    busy: bool = False
    analyzing: bool = False
    now_doing: str = ""
    pid: Optional[int] = None

    @property
    def open_count(self) -> int:
        return sum(1 for i in self.items if i.status != "completed")

    def to_dict(self):
        return {"id": self.id, "title": self.title, "cwd": self.cwd, "live": self.live, "busy": self.busy,
                "analyzing": self.analyzing, "now_doing": self.now_doing, "updated_at": self.updated_at,
                "open": self.open_count, "items": [i.to_dict() for i in self.items]}


def item_key(session_id: str, title: str) -> str:
    return session_id + "|" + "".join(c for c in title.lower() if c.isalnum())


class Hidden:
    """Tabs and tasks the user hid; they come back when a session changes (tabs) or via `restore`."""

    def __init__(self):
        self.path = state_dir() / "hidden.json"
        self.tabs: Dict[str, str] = {}
        self.items: Set[str] = set()
        try:
            data = json.loads(self.path.read_text())
            self.tabs, self.items = dict(data.get("tabs", {})), set(data.get("items", []))
        except (OSError, ValueError):
            pass

    def save(self):
        self.path.write_text(json.dumps({"tabs": self.tabs, "items": sorted(self.items)}))

    @property
    def count(self) -> int:
        return len(self.tabs) + len(self.items)

    def clear(self):
        self.tabs, self.items = {}, set()
        self.save()


class Manual:
    """Tasks typed in by hand, kept in the "Mine" tab."""

    def __init__(self):
        self.path = state_dir() / "mine.json"
        try:
            self.tasks: List[dict] = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.tasks = []

    def save(self):
        self.path.write_text(json.dumps(self.tasks))

    def add(self, text: str):
        text = text.strip()
        if text:
            self.tasks.append({"id": str(int(time.time() * 1000)), "text": text, "done": False})
            self.save()

    def toggle(self, task_id: str):
        for t in self.tasks:
            if t["id"] == task_id:
                t["done"] = not t["done"]
        self.save()

    def remove(self, task_id: str):
        self.tasks = [t for t in self.tasks if t["id"] != task_id]
        self.save()

    def session(self) -> Session:
        items = [Item(t["id"], t["text"], "completed" if t["done"] else "pending") for t in self.tasks]
        return Session(MANUAL_ID, "Mine", "", items, time.time())


def build_sessions(scanned: List[Scanned], analyzer: Optional[Analyzer], hidden: Optional[Hidden] = None) -> List[Session]:
    hidden = hidden or Hidden()
    out: List[Session] = []
    for s in scanned:
        if hidden.tabs.get(s.id) == s.fingerprint:
            continue
        analyzing = False
        title = s.name or s.fallback_title
        items = items_for(s.turn, s.live, s.busy)
        explicit = bool(s.turn.todos) and any(t.get("status") != "completed" for t in s.turn.todos)
        if not explicit and analyzer is not None:
            analyzing = analyzer.is_analyzing(s.id)
            ai = analyzer.analysis(s.id)
            if ai:
                if ai.get("title"):
                    title = ai["title"][:22]
                # the model's list replaces the rule-based guesses; an empty list means nothing is open
                items = [Item(f"ai-{i}", it["text"], it["state"], "todo", it.get("detail", ""), it.get("needs_you", False))
                         for i, it in enumerate(ai["items"][:MAX_ITEMS])]
                items = [i for i in items if i.needs_you] + [i for i in items if not i.needs_you]
            elif analyzer.is_pending(s.id):
                items, analyzing = [], True      # raw sentences from the chat read badly; wait for the real summary
        items = [i for i in items if item_key(s.id, i.content) not in hidden.items]     # ✓ works with or without AI summaries
        only_resume = all(i.kind == "resume" for i in items)
        if not items and not analyzing and not s.busy:
            continue
        if not s.live and only_resume and time.time() - s.mtime > CLOSED_WINDOW:
            continue
        out.append(Session(s.id, title, s.cwd, items, s.mtime, s.live, s.busy, analyzing,
                           s.turn.activity if s.busy else "", s.pid))
    out.sort(key=lambda x: (x.live, x.updated_at), reverse=True)    # running sessions first, then by recency
    seen: Dict[str, int] = {}
    for sess in out:
        seen[sess.title] = seen.get(sess.title, 0) + 1
        if seen[sess.title] > 1:
            sess.title = f"{sess.title} {seen[sess.title]}"
    return out
