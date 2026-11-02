import os
import sys
from pathlib import Path

IS_WINDOWS = sys.platform == "win32"


def claude_dir() -> Path:
    override = os.environ.get("CLAUDE_DIR") or os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(override) if override else Path.home() / ".claude"


def state_dir() -> Path:
    override = os.environ.get("CLAUDE_TODO_STATE")
    if override:
        base = Path(override)
    elif IS_WINDOWS:
        base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local") / "claude-todo"
    else:
        base = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "claude-todo"
    base.mkdir(parents=True, exist_ok=True)
    return base
