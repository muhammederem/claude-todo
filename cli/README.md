# claude-todo (Linux and Windows)

The same idea as the macOS app: it reads Claude Code's own session files and shows what is still open in each session. The core is plain Python; only the window needs PySide6.

```sh
pipx install "claude-todo[gui] @ git+https://github.com/muhammederem/claude-todo#subdirectory=cli"
claude-todo gui        # window + tray icon (Linux, Windows)
claude-todo            # terminal panel (Linux, macOS)
claude-todo list       # plain text
claude-todo json       # for scripts
claude-todo waybar     # one JSON line for a status bar
```

On Ubuntu/Debian the easiest way is the `.deb` from the [Releases page](https://github.com/muhammederem/claude-todo/releases) (`sudo apt install ./claude-todo_*_amd64.deb`): it bundles PySide6 and makes apt install the system libraries Qt needs, adds an app-menu entry, and `claude-todo` to your PATH.

Without pipx: `python3 -m pip install --user "claude-todo[gui] @ git+https://github.com/muhammederem/claude-todo#subdirectory=cli"`, or from a checkout `cd cli && python3 -m claude_todo gui`. On Windows use `py -m pip install ...` and start `claude-todo-gui` (no console window). Without the `[gui]` extra there are no dependencies at all and everything except the window works.

With pip, Qt's X11 plugin needs a few system libraries that are not always installed. `claude-todo gui` checks for them first and prints the command to run instead of letting Qt crash; on Ubuntu it is usually `sudo apt install libxcb-cursor0`. In a Wayland session Qt uses its Wayland plugin and the check is skipped.

Needs Python 3.9+ and [Claude Code](https://claude.com/claude-code), installed and **logged in**.

## The window

One tab per session (green dot = running, amber = busy), "N waiting · M on you", the live line of a busy session, ✓ to mark a task done, Resume to reopen the session, Hide, a box for your own tasks, and a tray icon that shows the number waiting. It notifies once when something has waited on you for 15 minutes. Closing the window keeps it in the tray; **Login: on** starts it with the computer (an autostart entry on Linux, the Run key on Windows). The tray needs a system-tray host: KDE, XFCE and Cinnamon have one, GNOME needs the AppIndicator extension; without one the window just stays a normal window.

## Panel keys

`←/→` switch session tab · `↑/↓` select task · `enter` reopen the session (`claude --resume`) in your terminal, or tell you where it is already running · `d` mark the task done · `h` hide the tab · `a` add your own task to **Mine** · `u` undo all hides · `r` refresh · `q` quit.

## Commands

| command | what it does |
| --- | --- |
| `claude-todo` | interactive panel |
| `claude-todo list` | sessions and tasks as text; tasks are numbered |
| `claude-todo json` | everything as JSON |
| `claude-todo waybar` | `{"text","tooltip","class"}` for waybar / polybar / i3blocks |
| `claude-todo resume SESSION` | reopen a session (its name, or the start of its id) |
| `claude-todo done SESSION N` | mark task N done (numbers come from `list`) |
| `claude-todo hide SESSION` | hide a tab until that session changes |
| `claude-todo add TEXT...` | add a task to **Mine** |
| `claude-todo restore` | bring back everything you hid |
| `claude-todo reset` | forget cached summaries |

Add `--no-ai` to skip the summaries, or `--wait` to make `list`/`json`/`waybar` wait until summaries are ready.

## Status bar

waybar:

```jsonc
"custom/claude-todo": {
  "exec": "claude-todo waybar --no-ai",
  "return-type": "json",
  "interval": 30,
  "on-click": "kitty claude-todo"
}
```

The `class` is `you` (something waits on you), `busy`, `waiting`, or `clear`, so you can colour each.

## How it decides

1. Recent transcripts in `~/.claude/projects` and the running-session registry in `~/.claude/sessions` (a session whose process is gone is "closed").
2. Simple rules first: an explicit task list if Claude kept one, otherwise unchecked boxes, "next steps" lists, and the question or offer at the end of the last answer. A closed session gets a "Left off: …" item.
3. When a session has been idle for 45 seconds, your own `claude -p --model haiku` rewrites that into at most three tasks with a one-line explanation, marks the ones waiting on you, and names the tab. Results are cached in `~/.local/state/claude-todo` and refreshed only when the session changes.

The summaries send the tail of a conversation to the model through your own `claude` login. Nothing else leaves your machine. Use `--no-ai` to keep it fully local.

## Reopening sessions

On Windows a session reopens in Windows Terminal (`wt`) or a new `cmd` window. On Linux `enter` / `resume` opens a new window in the terminal the session was started from, otherwise `$CLAUDE_TODO_TERMINAL` or `$TERMINAL`, `x-terminal-emulator`, then the first of kitty, alacritty, wezterm, foot, ghostty, gnome-terminal, konsole, xfce4-terminal, tilix, terminator, xterm. If the session is still running, no second copy is opened; on X11 with `xdotool` its window is raised, elsewhere you are told where it is (Wayland offers no way to raise another app's window).

## Not included

No desktop widget on Linux or Windows (no common widget API). The terminal panel needs `curses`, which Windows lacks; use the window there.

## Tests

```sh
cd cli && python3 -m unittest discover -s . -t . -p "test_*.py"
```
