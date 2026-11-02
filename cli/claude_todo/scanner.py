"""Reads Claude Code transcripts and the live-session registry. Port of TranscriptScanner.swift; no model calls."""
import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

from .openwork import TurnInfo

TAIL_BYTES = 6_000_000      # transcripts reach 40 MB+; only the end matters
MAX_AGE = 30 * 24 * 3600


@dataclass
class Scanned:
    id: str
    file: Path
    mtime: float
    size: int
    cwd: str
    fallback_title: str
    turn: TurnInfo
    name: Optional[str] = None
    live: bool = False
    busy: bool = False
    pid: Optional[int] = None

    @property
    def fingerprint(self) -> str:
        return f"{int(self.mtime)}-{self.size}"


def read_tail(path: Path, nbytes: int) -> Optional[bytes]:
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            end = f.tell()
            start = max(0, end - nbytes)
            f.seek(start)
            data = f.read()
    except OSError:
        return None
    if start > 0:
        nl = data.find(b"\n")
        if nl >= 0:
            data = data[nl + 1:]      # drop the partial first line
    return data


def text_of(message: dict) -> Optional[str]:
    content = message.get("content")
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return None
    return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text").strip()


def human_text(obj: dict, message: dict) -> Optional[str]:
    origin = obj.get("origin")
    if isinstance(origin, dict) and origin.get("kind") != "human":
        return None
    text = text_of(message)
    if not text or text.startswith("<"):
        return None
    return text


def _clip(s: str, n: int = 48) -> str:
    one = " ".join(s.split())
    return one[:n] + "…" if len(one) > n else one


def activity_of(message: dict) -> Optional[str]:
    """A short "what is it doing" line from the last tool call in an assistant message."""
    blocks = message.get("content")
    if not isinstance(blocks, list):
        return None

    def name(path):
        return (str(path or "").rstrip("/").split("/")[-1]) or "a file"

    tools = [b for b in blocks if isinstance(b, dict) and b.get("type") == "tool_use"]
    if tools:
        tool = tools[-1]
        tn, inp = tool.get("name", ""), tool.get("input") or {}
        if tn in ("Edit", "MultiEdit", "Write", "NotebookEdit"):
            return "Editing " + name(inp.get("file_path") or inp.get("notebook_path"))
        if tn == "Read":
            return "Reading " + name(inp.get("file_path"))
        if tn in ("Grep", "Glob"):
            return "Searching the code"
        if tn == "Bash":
            if inp.get("description"):
                return _clip(inp["description"])
            return "Running " + _clip(inp.get("command") or "a command", 40)
        if tn in ("Task", "Agent"):
            return "Sub-agent: " + _clip(inp.get("description") or "working", 38)
        if tn in ("WebFetch", "WebSearch"):
            return "Searching the web"
        if tn == "TodoWrite":
            for t in inp.get("todos") or []:
                if t.get("status") == "in_progress":
                    return _clip(t.get("activeForm") or t.get("content") or "")
            return "Planning the next steps"
        return "Using " + (tn.split("_")[-1] if tn.startswith("mcp__") else tn)
    if any(isinstance(b, dict) and b.get("type") == "text" for b in blocks):
        return "Writing a reply"
    return None


def todo_list(message: dict) -> Optional[list]:
    content = message.get("content")
    if not isinstance(content, list):
        return None
    latest = None
    for b in content:
        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "TodoWrite":
            todos = (b.get("input") or {}).get("todos")
            if isinstance(todos, list):
                latest = [{"content": t.get("content", ""), "status": t.get("status", "pending")} for t in todos if isinstance(t, dict)]
    return latest


def parse(path: Path, mtime: float, size: int, project_dir: str) -> Optional[Scanned]:
    data = read_tail(path, TAIL_BYTES)
    if data is None:
        return None
    turn, cwd = TurnInfo(), ""
    for line in data.split(b"\n"):
        if not line:
            continue
        has_todo = b'"TodoWrite"' in line
        is_user = b'"type":"user"' in line
        is_assistant = not is_user and b'"type":"assistant"' in line
        if not (has_todo or is_user or is_assistant) or (not has_todo and len(line) >= 200_000):
            continue    # skip huge tool results
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if not isinstance(obj, dict) or obj.get("isSidechain") is True:
            continue
        if isinstance(obj.get("cwd"), str):
            cwd = obj["cwd"]
        message = obj.get("message")
        if not isinstance(message, dict):
            continue
        if is_user:
            text = human_text(obj, message)
            if text is None:
                continue
            if not turn.first_prompt:
                turn.first_prompt = text
            turn.last_prompt = text
            turn.last_assistant = ""       # a new request starts a new turn
            turn.stop_reason = None
            turn.activity = ""
        elif is_assistant:
            turn.stop_reason = message.get("stop_reason")
            text = text_of(message)
            if text:
                turn.last_assistant = text
            now = activity_of(message)
            if now:
                turn.activity = now
        if has_todo:
            items = todo_list(message)
            if items is not None:
                turn.todos = items
    if not turn.last_prompt and turn.todos is None:
        return None
    fallback = os.path.basename(cwd.rstrip("/")) if cwd else project_dir
    return Scanned(path.stem, path, mtime, size, cwd, fallback, turn)


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def read_registry(sessions_dir: Path) -> Dict[str, dict]:
    """~/.claude/sessions/<pid>.json describes every running Claude Code process; a session without one is closed."""
    reg: Dict[str, dict] = {}
    if not sessions_dir.is_dir():
        return reg
    for f in sessions_dir.glob("*.json"):
        try:
            obj = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        sid = obj.get("sessionId") if isinstance(obj, dict) else None
        if not sid:
            continue
        entry = reg.setdefault(sid, {"name": None, "live": False, "busy": False, "pid": None})
        if obj.get("name"):
            entry["name"] = obj["name"]
        pid = obj.get("pid")
        if isinstance(pid, int) and pid_alive(pid):
            entry["live"] = True
            entry["pid"] = pid
            entry["busy"] = entry["busy"] or obj.get("status") == "busy"
    return reg


class Scanner:
    def __init__(self, claude_dir: Path, max_age: float = MAX_AGE):
        self.projects = claude_dir / "projects"
        self.sessions = claude_dir / "sessions"
        self.max_age = max_age
        self._cache: Dict[str, tuple] = {}

    def scan(self) -> List[Scanned]:
        registry = read_registry(self.sessions)
        result: List[Scanned] = []
        seen = set()
        now = time.time()
        if self.projects.is_dir():
            for d in self.projects.iterdir():
                if not d.is_dir():
                    continue
                for f in d.glob("*.jsonl"):
                    try:
                        st = f.stat()
                    except OSError:
                        continue
                    if now - st.st_mtime >= self.max_age:
                        continue
                    key = str(f)
                    seen.add(key)
                    hit = self._cache.get(key)
                    if hit and hit[0] == st.st_mtime and hit[1] == st.st_size:
                        session = hit[2]
                    else:
                        session = parse(f, st.st_mtime, st.st_size, d.name)
                        if session is None:
                            continue
                        self._cache[key] = (st.st_mtime, st.st_size, session)
                    r = registry.get(session.id)
                    if r:
                        session = Scanned(**{**session.__dict__, "name": r["name"], "live": r["live"], "busy": r["busy"], "pid": r["pid"]})
                    result.append(session)
        self._cache = {k: v for k, v in self._cache.items() if k in seen}
        return sorted(result, key=lambda s: s.mtime, reverse=True)
