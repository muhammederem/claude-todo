"""Terminal panel (curses, standard library only)."""
import curses
import time
from typing import List, Optional

from . import terminals
from .analyzer import Analyzer
from .build import MANUAL_ID, Hidden, Manual, Session, item_key
from .cli import ago, collect, open_session
from .scanner import Scanner

HELP = "←/→ tab  ↑/↓ task  enter resume  d done  h hide tab  a add  u undo hides  r refresh  q quit"


def _put(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if 0 <= y < h and x < w:
        try:
            win.addnstr(y, x, text, max(0, w - x - 1), attr)
        except curses.error:
            pass


def _loop(stdscr, scanner: Scanner, analyzer: Optional[Analyzer], hidden: Hidden, manual: Manual):
    curses.curs_set(0)
    curses.use_default_colors()
    for i, color in enumerate((curses.COLOR_GREEN, curses.COLOR_YELLOW, curses.COLOR_BLACK), 1):
        curses.init_pair(i, color, curses.COLOR_GREEN if i == 3 else -1)
    green, amber, selected = curses.color_pair(1), curses.color_pair(2), curses.color_pair(3)
    stdscr.timeout(500)

    sessions: List[Session] = []
    tab, row, last, message, first = 0, 0, 0.0, "", True
    while True:
        if time.time() - last > 3:
            sessions, last = collect(scanner, analyzer, hidden, manual), time.time()
            if first:     # open on the first real session; "Mine" is the empty tab before it
                tab, first = (1 if len(sessions) > 1 else 0), False
            tab = min(tab, len(sessions) - 1)
        s = sessions[tab]
        row = max(0, min(row, len(s.items) - 1))

        stdscr.erase()
        x = 1
        for i, t in enumerate(sessions):
            label = f" {t.title} {t.open_count or ''} ".replace("  ", " ")
            dot = "" if t.id == MANUAL_ID else ("● " if t.live else "○ ")
            attr = selected if i == tab else (amber if t.busy else green if t.live else curses.A_DIM)
            _put(stdscr, 0, x, dot + label, attr)
            x += len(dot + label) + 1
        n = s.open_count
        head = "All clear" if n == 0 else f"{n} waiting" + (f" · {sum(1 for i in s.items if i.needs_you)} on you" if any(i.needs_you for i in s.items) else "")
        _put(stdscr, 2, 1, head, curses.A_BOLD)
        if s.id != MANUAL_ID:
            _put(stdscr, 2, len(head) + 4, ("working" if s.busy else "open" if s.live else "closed") + " · " + ago(s.updated_at), curses.A_DIM)
        y = 4
        if s.busy and s.now_doing:
            _put(stdscr, y, 1, "⚡ " + s.now_doing, amber)
            y += 2
        if s.analyzing:
            _put(stdscr, y, 1, "… reading session", curses.A_DIM)
            y += 2
        for i, it in enumerate(s.items):
            mark = "✋" if it.needs_you else "✓" if it.status == "completed" else "◐" if it.status == "in_progress" else "○"
            attr = (amber if it.needs_you else green) | (curses.A_REVERSE if i == row else 0)
            _put(stdscr, y, 1, f"{mark} {it.content}", attr | curses.A_BOLD)
            if it.detail:
                _put(stdscr, y + 1, 4, it.detail, curses.A_DIM)
            y += 3 if it.detail else 2
        if not s.items and not s.analyzing:
            _put(stdscr, y, 1, "Nothing yet. Press a to add a task." if s.id == MANUAL_ID else "Nothing waiting.", curses.A_DIM)
        h, _ = stdscr.getmaxyx()
        if message:
            _put(stdscr, h - 2, 1, message, amber)
        _put(stdscr, h - 1, 1, HELP + (f"  [{hidden.count} hidden]" if hidden.count else ""), curses.A_DIM)
        stdscr.refresh()

        key = stdscr.getch()
        if key == -1:
            continue
        message = ""
        if key in (ord("q"), 27):
            return
        elif key in (curses.KEY_RIGHT, ord("l"), 9):
            tab, row = (tab + 1) % len(sessions), 0
        elif key in (curses.KEY_LEFT, ord("j")):
            tab, row = (tab - 1) % len(sessions), 0
        elif key in (curses.KEY_DOWN,):
            row += 1
        elif key in (curses.KEY_UP,):
            row -= 1
        elif key == ord("r"):
            last = 0
        elif key == ord("u"):
            hidden.clear()
            last = 0
        elif key == ord("a"):
            curses.curs_set(1)
            curses.echo()
            stdscr.timeout(-1)
            _put(stdscr, h - 2, 1, "New task: ", green)
            stdscr.refresh()
            text = stdscr.getstr(h - 2, 11, 200).decode("utf-8", "ignore")
            curses.noecho()
            curses.curs_set(0)
            stdscr.timeout(500)
            manual.add(text)
            last = 0
        elif key == ord("d") and s.items:
            it = s.items[row]
            if s.id == MANUAL_ID:
                manual.toggle(it.id)
            else:
                hidden.items.add(item_key(s.id, it.content))
                hidden.save()
            last = 0
        elif key == ord("h") and s.id != MANUAL_ID:
            fp = next((x.fingerprint for x in scanner.scan() if x.id == s.id), None)
            if fp:
                hidden.tabs[s.id] = fp
                hidden.save()
            last = 0
        elif key in (10, 13, curses.KEY_ENTER):
            try:
                message = open_session(s)
            except (RuntimeError, ValueError) as e:
                message = str(e)


def run(scanner, analyzer, hidden, manual) -> int:
    curses.wrapper(_loop, scanner, analyzer, hidden, manual)
    return 0
