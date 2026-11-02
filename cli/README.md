# claude-todo (Linux and anything with Python)

The same idea as the macOS app, as a dependency-free Python program: it reads Claude Code's own session files and shows what is still open in each session.

```sh
pipx install "git+https://github.com/muhammederem/claude-todo#subdirectory=cli"
# or run from a checkout: cd cli && python3 -m claude_todo
claude-todo            # interactive panel
claude-todo list       # plain text
claude-todo json       # for scripts
claude-todo waybar     # one JSON line for a status bar
```

Needs Python 3.9+ and [Claude Code](https://claude.com/claude-code), installed and **logged in**.

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

`enter` / `resume` opens a new window in the terminal the session was started from, otherwise `$CLAUDE_TODO_TERMINAL` or `$TERMINAL`, `x-terminal-emulator`, then the first of kitty, alacritty, wezterm, foot, ghostty, gnome-terminal, konsole, xfce4-terminal, tilix, terminator, xterm. If the session is still running, no second copy is opened; on X11 with `xdotool` its window is raised, elsewhere you are told where it is (Wayland offers no way to raise another app's window).

## Not included

No desktop widget and no tray icon (Linux has no common widget API). Windows is not supported yet.

## Tests

```sh
cd cli && python3 -m unittest discover -s . -t . -p "test_*.py"
```
