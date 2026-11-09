# Claude To-Do

Shows what is still unfinished across your Claude Code sessions, one tab per session: a menu bar app and desktop widget on **macOS**, a window with a tray icon on **Linux** and **Windows**.

- **Zero setup.** It reads Claude Code's own session files (`~/.claude`); no hooks, no config, nothing to type in.
- **Real to-dos, not chat snippets.** Each open item has a short title and a one-line explanation, and the ones waiting on *you* (an approval, a decision, a key) are marked and listed first.
- **Menu bar panel and a small/medium/large desktop widget**, with a tab per session. Tap a task to reopen that session with `claude --resume` in the terminal you use (Terminal, iTerm, Warp, Ghostty, …).
- **Live view.** A session that is busy shows what it is doing right now ("Editing panel.py"). Opening a task of a session that is already running brings its terminal forward instead of starting a second copy.
- **Suggested replies (macOS).** When a session is waiting on you, the AI drafts the reply you would likely send, with the options spelled out ("Use the short headline: 'Pay once, keep it forever'"). Approve it from the widget or panel, or edit it first; swipe left and right in the panel (‹ › in the widget) to move between them. A closed session is reopened with the reply; for a running one the reply is copied and its terminal brought forward.
- **iPhone companion (optional, off by default).** Home Screen and Lock Screen widgets show the same board; approve or edit a reply there, or answer straight from the "waiting on you" notification, and your Mac types it into the session. See [iPhone](#iphone).
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

### iPhone

The iPhone app is a widget with a small setup screen. It talks only to your Mac, through your own private iCloud database: no server of ours, and the Claude app is not needed on the phone.

1. On the Mac, switch **iPhone: on** in the panel footer (the Mac must be signed in to iCloud).
2. Install the iPhone app (not on the App Store yet; build `ClaudeTodoPhone` from source, see below) and sign in to the same Apple Account.
3. Add the **Claude To-Do** widget to the Home Screen (medium or large shows the suggested reply) and, if you like, the Lock Screen.

A reply sent from the phone goes to the session on your Mac:

- the session is running in **Terminal** or **iTerm**: typed into that tab once Claude has finished its turn;
- otherwise, **Claude Desktop** if it is installed;
- otherwise a new terminal window (Terminal, iTerm, Warp, Ghostty, …) resumes the session with your reply.

The Mac has to be awake; replies sent while it sleeps wait in iCloud and go through when it wakes. The setup screen shows whether each reply was delivered.

### Linux

A window with a tray icon, like the macOS panel (tabs per session, waiting-on-you marking, live view, resume, notifications, start at login).

**Ubuntu / Debian (amd64):** download `claude-todo_<version>_amd64.deb` from the [Releases page](https://github.com/muhammederem/claude-todo/releases) and install it; apt pulls in every system library Qt needs:

```sh
sudo apt install ./claude-todo_*_amd64.deb
```

Then start **Claude To-Do** from the app menu, or run `claude-todo gui`.

**Other distributions, or from source** (needs Python 3.9+):

```sh
pipx install "claude-todo[gui] @ git+https://github.com/muhammederem/claude-todo#subdirectory=cli"
claude-todo gui
```

With pip you install Qt's system libraries yourself; if one is missing, `claude-todo gui` tells you the exact command instead of crashing (on Ubuntu usually `sudo apt install libxcb-cursor0`).

### Windows

```sh
py -m pip install "claude-todo[gui] @ git+https://github.com/muhammederem/claude-todo#subdirectory=cli"
claude-todo-gui
```

A packaged installer is planned.

There is also a terminal panel and a status-bar module (waybar, polybar) on Linux; see [cli/README.md](cli/README.md). There is no desktop widget on Linux or Windows.

<p align="center"><img src="docs/window.png" alt="Linux and Windows window" width="300"></p>

## How it works

1. A scanner reads the recent session transcripts in `~/.claude/projects` and the live-session registry in `~/.claude/sessions`.
2. When a session goes idle, your own `claude -p --model haiku` summarizes the end of the conversation into at most three open tasks. Results are cached and re-run only when the session changes.
3. The app publishes the result to a small JSON file that the widget reads.
4. With **iPhone: on**, the same board is written to a record in your private iCloud database (CloudKit). The phone reads it and leaves replies there; the Mac checks for them every 10 seconds.

## Privacy

Nothing leaves your machine except what Claude Code itself sends. The AI summary passes the tail of a conversation to the model **through your own `claude` CLI and login** (a few tenths of a cent per summary; no API key, no third-party service). Turn it off with **AI summary** in the panel footer; the app then falls back to simple rules and shows rougher results.

**iPhone sync** is off until you turn it on. It then stores session titles, open tasks, suggested replies and the last Claude message of sessions waiting on you in **your own private iCloud database**, readable only by your Apple Account; the developer cannot see it. Settled replies are deleted after 3 days, alerts after a day.

## Build from source

```sh
brew install xcodegen
DEVELOPMENT_TEAM=<your team id> scripts/build_app.sh   # build/ClaudeTodo.app
xcodegen && open ClaudeTodo.xcodeproj                   # iPhone: run the ClaudeTodoPhone scheme on your device
TEAM_ID=<id> scripts/release.sh                         # signed, notarized DMG (needs a Developer ID certificate)
```

Change the bundle identifiers, the app group and the iCloud container (`iCloud.com.muhammederem.claude-todo`) in `project.yml` and `Shared/Cloud.swift` if you build it under your own team. The iPhone icon is drawn by `scripts/make_ios_icon.swift`.

## License

MIT
