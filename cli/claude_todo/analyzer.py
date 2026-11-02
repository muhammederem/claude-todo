"""Optional summaries through the user's own `claude -p` (no API key, no third-party service). Port of SessionAnalyzer.swift."""
import json
import shutil
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Dict, List, Optional

from .paths import state_dir
from .scanner import Scanned, read_tail, text_of

IDLE_SECONDS = 45
MAX_ITEMS = 3
PROMPT_VERSION = "-v4"
RETRY_AFTER = 10 * 60

SYSTEM_PROMPT = (
    'You read the end of a Claude Code session and write the to-do list of what is still unfinished, for a small widget. '
    'Include only real, concrete work that is still open: things the user asked for that are not done, steps Claude proposed '
    'or asked permission for and that nobody confirmed yet, and work cut short by an error or interruption. Never include '
    'finished work, politeness ("let me know"), or invented filler; if nothing is open, return an empty list. '
    'Write like a good task list: "title" is a short imperative task name (2-6 words, e.g. "Deploy the login fix"); '
    '"detail" is one plain sentence (under 90 characters) saying what exactly is left and why it is waiting '
    '(e.g. "Needs your OK before the change goes to production"). At most 3 items, most important first. '
    '"title" in the outer object names the session by its topic: 1-3 words, at most 18 characters, '
    'title case, no punctuation (e.g. "Voice cloning", "Widget polish", "Clear Good release"). '
    'Write in English, even if the conversation is in another language. '
    'Set "owner" to "you" when the item waits on the user (an approval, a decision, a key or account they must provide, '
    'something only they can do) and to "claude" when Claude can just do it. '
    'Reply with only this JSON: {"title":"session name","items":[{"title":"...","detail":"...","state":"in_progress|pending","owner":"you|claude"}]}. '
    'Use "in_progress" only for what the session is doing right now; everything else is "pending".'
)


def find_claude() -> Optional[str]:
    return shutil.which("claude") or next(
        (p for p in (str(Path.home() / ".local/bin/claude"), "/usr/local/bin/claude", "/opt/homebrew/bin/claude") if Path(p).is_file()), None)


def parse_output(raw: str):
    """`claude -p --output-format json` wraps the model text in `result`; the text itself holds our JSON."""
    try:
        outer = json.loads(raw)
        if outer.get("is_error") is True:
            return None
        text = outer["result"]
        inner = json.loads(text[text.index("{"): text.rindex("}") + 1])
    except (ValueError, KeyError, TypeError):
        return None
    items = []
    for it in inner.get("items") or []:
        title = str(it.get("title") or it.get("text") or "").strip()
        if title:
            items.append({"text": title, "detail": str(it.get("detail") or "").strip(),
                          "state": "in_progress" if it.get("state") == "in_progress" else "pending",
                          "needs_you": it.get("owner") == "you"})
    return {"title": str(inner.get("title") or "").strip(), "items": items[:MAX_ITEMS]}


def digest(s: Scanned) -> Optional[str]:
    """Compact text of the end of the conversation: what was asked, what Claude said, how it stopped."""
    data = read_tail(s.file, 3_000_000)
    if data is None:
        return None
    lines, last_stop, last_text = [], None, ""
    for raw in data.split(b"\n"):
        if not raw or len(raw) >= 200_000:
            continue
        try:
            obj = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(obj, dict) or obj.get("isSidechain") is True or obj.get("type") not in ("user", "assistant"):
            continue
        message = obj.get("message")
        if not isinstance(message, dict):
            continue
        if obj["type"] == "user":
            origin = obj.get("origin")
            if not (isinstance(origin, dict) and origin.get("kind") == "human"):
                continue    # tool results come back as "user" entries too; only real prompts count
            text = text_of(message)
            if text:
                lines.append("[user] " + text[:500])
        else:
            last_stop = message.get("stop_reason")
            text = text_of(message)
            if text:
                last_text = text
                lines.append("[claude] " + text[-700:])    # questions and offers sit at the end
            blocks = message.get("content")
            if isinstance(blocks, list) and any(isinstance(b, dict) and b.get("type") == "tool_use" for b in blocks) \
                    and not (lines and lines[-1].startswith("[claude tool]")):
                lines.append("[claude tool] working")
    if not lines:
        return None
    out = f"[project] {s.cwd}\n[last activity] {int((time.time() - s.mtime) / 60)} min ago\n"
    body = ""
    for line in reversed(lines):
        if len(body) + len(line) > 12_000:
            break
        body = line + "\n" + body
    out += body
    if last_stop == "tool_use":
        out += "[state] the session ended in the middle of a tool call; work may be unfinished\n"
    if last_text.startswith("API Error"):
        out += "[state] the session was cut off by an API error; the last request did not finish\n"
    return out


class Analyzer:
    def __init__(self, enabled: bool = True):
        self.enabled = enabled
        self._lock = threading.Lock()
        self._cache: Dict[str, dict] = {}
        self._running = set()
        self._failed: Dict[str, float] = {}
        self._pool = ThreadPoolExecutor(max_workers=3)
        self._store = state_dir() / "analysis.json"
        try:
            self._cache = json.loads(self._store.read_text())
        except (OSError, ValueError):
            pass

    def analysis(self, sid: str) -> Optional[dict]:
        with self._lock:
            return self._cache.get(sid)

    def is_analyzing(self, sid: str) -> bool:
        with self._lock:
            return sid in self._running

    def is_pending(self, sid: str) -> bool:
        with self._lock:
            return self.enabled and find_claude() is not None and sid not in self._cache and self._failed.get(sid, 0) <= time.time()

    @property
    def problem(self) -> Optional[str]:
        if not self.enabled:
            return None
        if find_claude() is None:
            return "Claude Code not found: AI summaries are off."
        with self._lock:
            failing = any(t > time.time() for t in self._failed.values())
        return "Summaries failed. Is Claude Code logged in? Run `claude` once in a terminal." if failing else None

    def consider(self, sessions: List[Scanned]):
        if not self.enabled:
            return
        week = 7 * 24 * 3600
        for s in sorted(sessions, key=lambda s: (s.live, s.mtime), reverse=True):
            if s.turn.todos is not None or time.time() - s.mtime < IDLE_SECONDS:
                continue
            if not s.live and time.time() - s.mtime > week:
                continue
            with self._lock:
                cached = self._cache.get(s.id)
                if s.id in self._running or (cached and cached.get("fingerprint") == s.fingerprint + PROMPT_VERSION) \
                        or self._failed.get(s.id, 0) > time.time():
                    continue
                self._running.add(s.id)
            self._pool.submit(self._analyze, s)

    def wait(self):
        while True:
            with self._lock:
                if not self._running:
                    return
            time.sleep(0.2)

    def _analyze(self, s: Scanned):
        try:
            text = digest(s)
            out = self._run(text) if text else None
            parsed = parse_output(out) if out else None
            with self._lock:
                if parsed is None:
                    self._failed[s.id] = time.time() + RETRY_AFTER
                else:
                    self._cache[s.id] = {**parsed, "fingerprint": s.fingerprint + PROMPT_VERSION, "at": time.time()}
            if parsed is not None:
                self._save()
        finally:
            with self._lock:
                self._running.discard(s.id)

    def _run(self, text: str) -> Optional[str]:
        exe = find_claude()
        if not exe:
            return None
        try:
            # --no-session-persistence keeps these runs out of ~/.claude/projects (otherwise we would analyze ourselves)
            r = subprocess.run([exe, "-p", "--model", "haiku", "--no-session-persistence", "--output-format", "json",
                                "--tools", "", "--disable-slash-commands", "--system-prompt", SYSTEM_PROMPT],
                               input=text, capture_output=True, text=True, timeout=120, cwd="/tmp")
        except (OSError, subprocess.TimeoutExpired):
            return None
        return r.stdout if r.returncode == 0 else None

    def _save(self):
        with self._lock:
            snapshot = dict(self._cache)
        tmp = self._store.with_suffix(".tmp")
        tmp.write_text(json.dumps(snapshot))
        tmp.replace(self._store)

    def reset(self):
        with self._lock:
            self._cache, self._failed = {}, {}
        try:
            self._store.unlink()
        except OSError:
            pass
