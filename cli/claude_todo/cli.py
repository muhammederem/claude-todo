"""`leftovers` (also installed as `claude-todo`): terminal panel plus plain, JSON and status-bar outputs."""
import argparse
import json
import sys
import time
from typing import List, Optional

from . import __version__, terminals
from .analyzer import Analyzer
from .build import MANUAL_ID, Hidden, Manual, Session, build_sessions, item_key
from .paths import claude_dir
from .scanner import Scanner


def collect(scanner: Scanner, analyzer: Optional[Analyzer], hidden: Hidden, manual: Manual, wait: bool = False) -> List[Session]:
    scanned = scanner.scan()
    if analyzer:
        analyzer.consider(scanned)
        if wait:
            analyzer.wait()
    return [manual.session()] + build_sessions(scanned, analyzer, hidden)


def ago(ts: float, now: Optional[float] = None) -> str:
    d = max(0, (now or time.time()) - ts)
    if d < 90:
        return "just now"
    if d < 3600:
        return f"{int(d // 60)}m ago"
    if d < 86400:
        return f"{int(d // 3600)}h ago"
    return f"{int(d // 86400)}d ago"


def render_text(sessions: List[Session], now: Optional[float] = None) -> str:
    lines = []
    for s in sessions:
        if s.id == MANUAL_ID and not s.items:
            continue
        state = "" if s.id == MANUAL_ID else (" · working" if s.busy else " · open" if s.live else " · closed")
        lines.append(f"{s.title}  [{s.open_count}]{state}" + ("" if s.id == MANUAL_ID else f" · {ago(s.updated_at, now)}"))
        if s.busy and s.now_doing:
            lines.append(f"  ⚡ {s.now_doing}")
        if s.analyzing:
            lines.append("  … reading session")
        for n, i in enumerate(s.items, 1):
            mark = "✋" if i.needs_you else ("✓" if i.status == "completed" else "◐" if i.status == "in_progress" else "○")
            lines.append(f"  {n}. {mark} {i.content}")
            if i.detail:
                lines.append(f"       {i.detail}")
        lines.append("")
    return "\n".join(lines).rstrip() or "Nothing waiting."


def waybar(sessions: List[Session]) -> dict:
    """JSON for waybar's custom module (`return-type: json`); polybar/i3blocks can use the same `text`."""
    real = [s for s in sessions if s.id != MANUAL_ID]
    total = sum(s.open_count for s in sessions)
    you = sum(1 for s in sessions for i in s.items if i.needs_you and i.status != "completed")
    working = sum(1 for s in real if s.busy)
    tip = []
    for s in sessions:
        if s.open_count or s.busy:
            tip.append(f"{s.title}: {s.open_count} open" + (f" · {s.now_doing}" if s.busy and s.now_doing else ""))
    cls = "you" if you else "busy" if working else "waiting" if total else "clear"
    return {"text": (f"{total}" if total else "✓") + (f" ✋{you}" if you else ""),
            "tooltip": "\n".join(tip) or "Nothing waiting", "class": cls, "alt": cls}


def dump_json(sessions: List[Session]) -> str:
    return json.dumps({"version": __version__, "generated_at": time.time(), "sessions": [s.to_dict() for s in sessions]}, indent=2)


def find_session(sessions: List[Session], ref: str) -> Optional[Session]:
    ref = ref.lower()
    exact = [s for s in sessions if s.id.lower() == ref or s.title.lower() == ref]
    if exact:
        return exact[0]
    partial = [s for s in sessions if s.id.lower().startswith(ref) or ref in s.title.lower()]
    return partial[0] if len(partial) == 1 else None


def open_session(s: Session) -> str:
    if s.id == MANUAL_ID:
        return "That tab is yours; nothing to resume."
    if s.live and s.pid:
        return terminals.focus(s.pid)
    argv = terminals.resume(s.id, s.cwd, s.pid)
    return "Opened in " + argv[0] + "."


def task_prompt(item) -> str:
    if getattr(item, "kind", "") == "resume":
        return "Continue where you left off."
    return f"{item.content}: {item.detail}" if item.detail else item.content


def send_task(s: Session, item) -> str:
    """A click on a task: the session gets it as its next message. A session still open in a terminal can't be typed
    into from here, so a new window continues a fork of it."""
    if s.id == MANUAL_ID:
        return "That tab is yours; nothing to send."
    running = bool(s.live and s.pid)
    argv = terminals.resume(s.id, s.cwd, s.pid, prompt=task_prompt(item), fork=running)
    return ("Continued a copy in " if running else "Sent to the session in ") + argv[0] + "."


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(prog="leftovers", description="What is still open across your Claude Code sessions.")
    p.add_argument("command", nargs="?", default="ui",
                   choices=["ui", "gui", "list", "json", "waybar", "add", "done", "hide", "restore", "resume", "reset"],
                   help="ui (default, terminal) | gui (window + tray) | list | json | waybar | add TEXT | done SESSION N | hide SESSION | restore | resume SESSION | reset")
    p.add_argument("args", nargs="*")
    p.add_argument("--no-ai", action="store_true", help="skip the `claude -p` summaries; use simple rules only")
    p.add_argument("--tray", action="store_true", help="gui: start hidden in the tray")
    p.add_argument("--smoke", metavar="FILE", help=argparse.SUPPRESS)    # packaging tests: build the window, write FILE, exit
    p.add_argument("--wait", action="store_true", help="wait for the summaries before printing (list/json/waybar)")
    p.add_argument("--version", action="version", version=__version__)
    a = p.parse_args(argv)

    scanner, hidden, manual = Scanner(claude_dir()), Hidden(), Manual()
    analyzer = None if a.no_ai else Analyzer(True)
    if a.command == "reset":
        if analyzer:
            analyzer.reset()
        print("Summaries cleared.")
        return 0
    if a.command == "restore":
        hidden.clear()
        print("Hidden tabs and tasks restored.")
        return 0
    if a.command == "add":
        manual.add(" ".join(a.args))
        print("Added to Mine.")
        return 0

    sessions = collect(scanner, analyzer, hidden, manual, wait=a.wait or a.command in ("done", "hide", "resume"))
    if a.command == "list":
        print(render_text(sessions))
    elif a.command == "json":
        print(dump_json(sessions))
    elif a.command == "waybar":
        print(json.dumps(waybar(sessions)))
    elif a.command in ("done", "hide", "resume"):
        if not a.args:
            p.error(f"{a.command} needs a session name or id")
        s = find_session(sessions, a.args[0])
        if s is None:
            print(f"No single session matches '{a.args[0]}'.", file=sys.stderr)
            return 1
        if a.command == "resume":
            try:
                print(open_session(s))
            except (RuntimeError, ValueError) as e:
                print(e, file=sys.stderr)
                return 1
        elif a.command == "hide":
            fp = next((x.fingerprint for x in scanner.scan() if x.id == s.id), None)
            if fp:
                hidden.tabs[s.id] = fp
                hidden.save()
            print(f"Hid {s.title}.")
        else:
            idx = int(a.args[1]) - 1 if len(a.args) > 1 and a.args[1].isdigit() else -1
            if not 0 <= idx < len(s.items):
                print("done needs the task number from `leftovers list`: leftovers done SESSION N", file=sys.stderr)
                return 1
            if s.id == MANUAL_ID:
                manual.toggle(s.items[idx].id)
            else:
                hidden.items.add(item_key(s.id, s.items[idx].content))
                hidden.save()
            print("Done.")
    elif a.command == "gui":
        from .preflight import advice, missing_packages
        missing = missing_packages()
        if missing:
            print(advice(missing), file=sys.stderr)
            return 1
        try:
            from .gui import run as run_gui
        except ImportError:
            print("The window needs PySide6: pip install \"leftovers[gui]\"", file=sys.stderr)
            return 1
        return run_gui(scanner, analyzer, hidden, manual, start_hidden=a.tray, smoke=a.smoke)
    else:
        try:
            from .tui import run
        except ImportError:        # no curses on Windows
            print("The terminal panel needs curses, which Windows lacks. Use `leftovers gui`, or `leftovers list`.", file=sys.stderr)
            return 1
        return run(scanner, analyzer, hidden, manual)
    return 0


if __name__ == "__main__":
    sys.exit(main())
