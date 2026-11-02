# Claude To-Do

Shows what is still unfinished across your Claude Code sessions, one tab per session: a menu bar app and desktop widget on **macOS**, a window with a tray icon on **Linux** and **Windows**.

- **Zero setup.** It reads Claude Code's own session files (`~/.claude`); no hooks, no config, nothing to type in.
- **Real to-dos, not chat snippets.** Each open item has a short title and a one-line explanation, and the ones waiting on *you* (an approval, a decision, a key) are marked and listed first.
- **Menu bar panel and a small/medium/large desktop widget**, with a tab per session. Tap a task to reopen that session with `claude --resume` in the terminal you use (Terminal, iTerm, Warp, Ghostty, …).
- **Live view.** A session that is busy shows what it is doing right now ("Editing panel.py"). Opening a task of a session that is already running brings its terminal forward instead of starting a second copy.
- Mark a task done, hide a tab, and add your own tasks in the "Mine" tab.
- Optional notification when something has been waiting on you for 15 minutes.

<p align="center">
  <img src="docs/widgets.png" alt="Small, medium and large desktop widgets" width="640"><br>
  <img src="docs/panel.png" alt="Menu bar panel" width="300">
</p>

*Screenshots use made-up sample sessions.*

## Install

### macOS 15+

Homebrew:

```sh
brew tap muhammederem/claude-todo
brew trust muhammederem/claude-todo   # newer Homebrew only loads casks from third-party taps you trust
brew install claude-todo
```

or download `ClaudeTodo.dmg` from the Releases page and drag the app to Applications. Then add the widget: right-click the desktop, **Edit Widgets**, search "Claude To-Do".

Requires [Claude Code](https://claude.com/claude-code), installed and **logged in** (run `claude` once in a terminal). Without it the app still lists sessions with simple rules, and the panel tells you why the AI summaries are missing.

### Linux and Windows

A window with a tray icon, like the macOS panel (tabs per session, waiting-on-you marking, live view, resume, notifications, start at login):

```sh
pipx install "claude-todo[gui] @ git+https://github.com/muhammederem/claude-todo#subdirectory=cli"
claude-todo gui
```

Needs Python 3.9+. On Windows use `py -m pip install ...` instead of pipx if you do not have it, then run `claude-todo-gui` (no console window). There is also a terminal panel and a status-bar module (waybar, polybar) on Linux; details in [cli/README.md](cli/README.md). There is no desktop widget on Linux or Windows.

<p align="center"><img src="docs/window.png" alt="Linux and Windows window" width="300"></p>

## How it works

1. A scanner reads the recent session transcripts in `~/.claude/projects` and the live-session registry in `~/.claude/sessions`.
2. When a session goes idle, your own `claude -p --model haiku` summarizes the end of the conversation into at most three open tasks. Results are cached and re-run only when the session changes.
3. The app publishes the result to a small JSON file that the widget reads.

## Privacy

Nothing leaves your machine except what Claude Code itself sends. The AI summary passes the tail of a conversation to the model **through your own `claude` CLI and login** (a few tenths of a cent per summary; no API key, no third-party service). Turn it off with **AI summary** in the panel footer; the app then falls back to simple rules and shows rougher results.

## Build from source

```sh
brew install xcodegen
DEVELOPMENT_TEAM=<your team id> scripts/build_app.sh   # build/ClaudeTodo.app
TEAM_ID=<id> scripts/release.sh                         # signed, notarized DMG (needs a Developer ID certificate)
```

Change the bundle identifiers in `project.yml` if you build it under your own team.

## License

MIT
