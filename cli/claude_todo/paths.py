import os
from pathlib import Path


def claude_dir() -> Path:
    override = os.environ.get("CLAUDE_DIR") or os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(override) if override else Path.home() / ".claude"


def state_dir() -> Path:
    override = os.environ.get("CLAUDE_TODO_STATE")
    base = Path(override) if override else Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "claude-todo"
    base.mkdir(parents=True, exist_ok=True)
    return base
