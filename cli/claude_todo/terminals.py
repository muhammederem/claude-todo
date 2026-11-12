"""Reopens a session in the terminal the user actually uses (Linux first; works on macOS for the common cases)."""
import os
import shlex
import shutil
import subprocess
import re
import sys
from typing import List, Optional

# executable name -> command prefix that runs the following argv in a new window
_TERMINALS = [
    ("kitty", ["kitty"]),
    ("alacritty", ["alacritty", "-e"]),
    ("wezterm", ["wezterm", "start", "--"]),
    ("foot", ["foot"]),
    ("ghostty", ["ghostty", "-e"]),
    ("gnome-terminal", ["gnome-terminal", "--"]),
    ("kgx", ["kgx", "-e"]),
    ("konsole", ["konsole", "-e"]),
    ("xfce4-terminal", ["xfce4-terminal", "-x"]),
    ("tilix", ["tilix", "-e"]),
    ("terminator", ["terminator", "-x"]),
    ("xterm", ["xterm", "-e"]),
]
_NAMES = [n for n, _ in _TERMINALS]


def _proc_stat(pid: int):
    """(parent pid, command name) from /proc, or None where there is no procfs."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            data = f.read()
    except OSError:
        return None
    # the command name is in parentheses and may contain spaces or parentheses itself
    left, right = data.index("("), data.rindex(")")
    rest = data[right + 2:].split()
    return int(rest[1]), data[left + 1:right]


def host_terminal(pid: int) -> Optional[str]:
    """Walks up the process tree until it meets a known terminal emulator."""
    for _ in range(15):
        st = _proc_stat(pid)
        if st is None:
            return None
        ppid, comm = st
        for name in _NAMES:
            if comm.lower().startswith(name[:15]):
                return name
        if ppid <= 1:
            return None
        pid = ppid
    return None


def _is_windows() -> bool:
    return sys.platform == "win32"


_CMD_UNSAFE = set('&|<>^%"\n\r')


def _one_line(text: str) -> str:
    return " ".join(part.strip() for part in text.splitlines() if part.strip())


def _claude_args(session_id: str, prompt: Optional[str], fork: bool) -> List[str]:
    """`--fork-session` continues a copy of a session that is still open elsewhere, leaving that one intact."""
    args = ["claude", "--resume", session_id] + (["--fork-session"] if fork else [])
    return args + ([_one_line(prompt)] if prompt and _one_line(prompt) else [])


def _windows_resume_argv(session_id: str, cwd: str, prompt: Optional[str] = None, fork: bool = False) -> List[str]:
    """Windows Terminal if present, otherwise a new cmd window. The id is validated hex, and a folder that cmd could
    misread (& | < > ^ % ") is replaced by the home folder, since cmd re-parses its command line."""
    if not re.fullmatch(r"[0-9a-fA-F-]{8,64}", session_id):
        raise ValueError("bad session id")
    folder = cwd if cwd and os.path.isdir(cwd) and not (set(cwd) & _CMD_UNSAFE) else os.path.expanduser("~")
    if shutil.which("wt"):
        return ["wt", "-d", folder, "--"] + _claude_args(session_id, prompt, fork)
    # cmd re-parses the line, so the prompt loses the characters it would misread
    safe = "".join(c for c in prompt or "" if c not in _CMD_UNSAFE)
    return ["cmd", "/c", "start", "", "/D", folder, "cmd", "/k"] + _claude_args(session_id, safe, fork)


def resume_command(session_id: str, cwd: str, prompt: Optional[str] = None, fork: bool = False) -> List[str]:
    if not re.fullmatch(r"[0-9a-fA-F-]{8,64}", session_id):
        raise ValueError("bad session id")
    shell = os.environ.get("SHELL") or "/bin/sh"
    folder = cwd if cwd and os.path.isdir(cwd) else os.path.expanduser("~")
    claude = " ".join(shlex.quote(a) for a in _claude_args(session_id, prompt, fork))
    script = f"cd {shlex.quote(folder)} && {claude}; exec {shlex.quote(shell)}"
    return ["sh", "-c", script]


def pick_terminal(pid: Optional[int] = None) -> Optional[str]:
    if pid is not None:
        host = host_terminal(pid)
        if host and shutil.which(host):
            return host
    configured = os.environ.get("CLAUDE_TODO_TERMINAL") or os.environ.get("TERMINAL")
    if configured and shutil.which(configured.split()[0]):
        return configured.split()[0]
    if shutil.which("x-terminal-emulator"):
        return "x-terminal-emulator"
    return next((n for n in _NAMES if shutil.which(n)), None)


def terminal_argv(terminal: str, inner: List[str]) -> List[str]:
    for name, prefix in _TERMINALS:
        if terminal == name:
            return prefix + inner
    # x-terminal-emulator and custom $TERMINAL values accept -e
    return [terminal, "-e"] + inner


def resume(session_id: str, cwd: str, pid: Optional[int] = None, dry_run: bool = False,
           prompt: Optional[str] = None, fork: bool = False) -> List[str]:
    """Opens `claude --resume` in a new terminal window, with `prompt` as the first message; returns the command."""
    if _is_windows():
        argv = _windows_resume_argv(session_id, cwd, prompt, fork)
        if not dry_run:
            subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        return argv
    inner = resume_command(session_id, cwd, prompt, fork)
    terminal = pick_terminal(pid)
    if terminal is None:
        raise RuntimeError("No terminal emulator found. Set $TERMINAL or CLAUDE_TODO_TERMINAL.")
    argv = terminal_argv(terminal, inner)
    if not dry_run:
        subprocess.Popen(argv, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return argv


def focus(pid: int) -> str:
    if _is_windows():
        return f"Already running (pid {pid}); switch to that window."
    """Best effort for a session that is already running: raise its terminal window (X11 only), else say where it is."""
    host = host_terminal(pid) or "its terminal"
    tool = shutil.which("xdotool")
    if tool and os.environ.get("DISPLAY"):
        # the terminal emulator process owns the window; walk up from the session to it
        cur = pid
        for _ in range(15):
            st = _proc_stat(cur)
            if st is None or st[0] <= 1:
                break
            cur = st[0]
            if st[1].lower().startswith(host[:15]):
                r = subprocess.run([tool, "search", "--pid", str(cur)], capture_output=True, text=True)
                ids = r.stdout.split()
                if ids:
                    subprocess.run([tool, "windowactivate", ids[-1]], capture_output=True)
                    return f"Brought {host} forward."
                break
    return f"Already running in {host} (pid {pid}); switch to that window."
