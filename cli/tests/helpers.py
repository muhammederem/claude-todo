import json
import os
import sys
import unittest
import tempfile
import time
from pathlib import Path


posix_only = unittest.skipIf(sys.platform == "win32", "uses POSIX shell scripts, ptys or /proc")


def line(kind, content, **extra):
    msg = {"role": kind, "content": content}
    msg.update(extra.pop("message", {}))
    obj = {"type": kind, "message": msg, "cwd": extra.pop("cwd", "/home/u/proj")}
    obj.update(extra)
    return json.dumps(obj, separators=(",", ":"))    # real transcripts are compact JSON


def user(text, **kw):
    return line("user", text, origin={"kind": "human"}, **kw)


def assistant(text=None, tools=None, stop="end_turn", **kw):
    blocks = ([{"type": "text", "text": text}] if text else []) + [
        {"type": "tool_use", "name": n, "input": i} for n, i in (tools or [])]
    return line("assistant", blocks, message={"stop_reason": stop}, **kw)


class Home:
    """A throwaway ~/.claude with projects/ and sessions/."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.claude = self.root / "claude"
        (self.claude / "projects" / "-home-u-proj").mkdir(parents=True)
        (self.claude / "sessions").mkdir()
        self.state = self.root / "state"
        os.environ["CLAUDE_DIR"] = str(self.claude)
        os.environ["CLAUDE_TODO_STATE"] = str(self.state)

    def transcript(self, sid, lines, age=0):
        f = self.claude / "projects" / "-home-u-proj" / f"{sid}.jsonl"
        f.write_text("\n".join(lines) + "\n")
        if age:
            t = time.time() - age
            os.utime(f, (t, t))
        return f

    def register(self, sid, pid=None, **extra):
        pid = pid if pid is not None else os.getpid()
        (self.claude / "sessions" / f"{pid}.json").write_text(json.dumps({"pid": pid, "sessionId": sid, **extra}))

    def close(self):
        for k in ("CLAUDE_DIR", "CLAUDE_TODO_STATE"):
            os.environ.pop(k, None)
        self.tmp.cleanup()
