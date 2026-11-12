# Leftovers

[![cli](https://github.com/muhammederem/claude-todo/actions/workflows/cli.yml/badge.svg)](https://github.com/muhammederem/claude-todo/actions/workflows/cli.yml)
[![packages](https://github.com/muhammederem/claude-todo/actions/workflows/packages.yml/badge.svg)](https://github.com/muhammederem/claude-todo/actions/workflows/packages.yml)
[![release](https://img.shields.io/github/v/release/muhammederem/claude-todo)](https://github.com/muhammederem/claude-todo/releases/latest)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Leftovers tracks the unfinished work across your [Claude Code](https://claude.com/claude-code) sessions. It reads Claude Code's local session files, extracts the open tasks of each session, and marks the ones that are waiting on you. It runs as a menu bar app with a desktop widget on macOS, and as a window with a tray icon on Linux and Windows.

<p align="center">
  <img src="docs/widgets.png" alt="Small, medium and large desktop widgets" width="640"><br>
  <img src="docs/panel.png" alt="Menu bar panel" width="300">
</p>

<sub>Screenshots use made-up sample sessions.</sub>

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Privacy](#privacy)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Building from source](#building-from-source)
- [License](#license)

## Features

| | macOS | Linux | Windows |
| --- | :---: | :---: | :---: |
| One tab per session, open tasks with a one-line explanation | ✓ | ✓ | ✓ |
| Tasks waiting on you (approval, decision, credentials) marked and listed first | ✓ | ✓ | ✓ |
| Live status of a busy session ("Editing panel.py") | ✓ | ✓ | ✓ |
| Click a task to send it to its session | ✓ | ✓ | ✓ |
| AI-suggested reply with Approve / Edit | ✓ | | |
| Desktop widget (small, medium, large) | ✓ | | |
| Menu bar panel / tray icon | ✓ | ✓ | ✓ |
| Terminal panel and status-bar output (waybar, polybar) | | ✓ | |
| Notification after a task has waited on you for 15 minutes | ✓ | ✓ | ✓ |
| Personal tasks ("Mine" tab), hide, mark done, start at login | ✓ | ✓ | ✓ |

No configuration and no hooks are needed: everything comes from the files Claude Code already writes under `~/.claude`.

## Requirements

- [Claude Code](https://claude.com/claude-code), installed and **logged in** (run `claude` once in a terminal). Without it, Leftovers still lists sessions using simple rules and reports why the AI summaries are missing.
- **macOS** 15 or later.
- **Linux**: Python 3.9 or later, or Debian/Ubuntu on amd64 for the `.deb` package. The tray icon needs a system-tray host (built in on KDE, XFCE and Cinnamon; GNOME needs the AppIndicator extension).
- **Windows** 10 or later with Python 3.9 or later.

## Installation

### One-line install

macOS and Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/muhammederem/claude-todo/main/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/muhammederem/claude-todo/main/install.ps1 | iex
```

What the installer does:

| System | Result |
| --- | --- |
| macOS | Downloads the signed, notarized app from the latest release into `/Applications` (or `~/Applications`) and starts it. |
| Debian / Ubuntu (amd64) | Installs the release's `.deb` with apt, which also pulls in the system libraries Qt needs. |
| Other Linux | Installs the Python package with pipx, or into its own virtual environment under `~/.local/share/leftovers`, and links `leftovers` into `~/.local/bin`. |
| Windows | Installs the Python package into `%LOCALAPPDATA%\Leftovers`, adds a Start menu entry and starts the app. |

Set `LEFTOVERS_VERSION=v1.2.0` to install a specific release instead of the latest. Both scripts are short; read them before piping them to a shell if you prefer: [install.sh](install.sh), [install.ps1](install.ps1).

### Other ways

- **Homebrew (macOS)**
  ```sh
  brew tap muhammederem/claude-todo
  brew install claude-todo
  ```
- **Manual download**: `.dmg` (macOS) and `.deb` (Debian/Ubuntu) from the [releases page](https://github.com/muhammederem/claude-todo/releases).
- **pip / pipx**
  ```sh
  pipx install "leftovers[gui] @ git+https://github.com/muhammederem/claude-todo#subdirectory=cli"
  ```

On macOS, add the widget with a right-click on the desktop → **Edit Widgets** → search "Leftovers".

### Uninstall

| Installed with | Remove with |
| --- | --- |
| macOS installer or `.dmg` | Quit the app and delete `Leftovers.app` from Applications |
| Homebrew | `brew uninstall --cask claude-todo` |
| `.deb` | `sudo apt remove leftovers` |
| Linux installer | `pipx uninstall leftovers`, or `rm -rf ~/.local/share/leftovers ~/.local/bin/leftovers` |
| Windows installer | Delete `%LOCALAPPDATA%\Leftovers` and the Start menu entry |

Cached summaries live in `~/Library/Application Support/ClaudeTodo` (macOS), `~/.local/state/claude-todo` (Linux) and `%LOCALAPPDATA%\claude-todo` (Windows).

## Usage

### Panel and widget

Each Claude Code session gets a tab. A tab shows the session's state (working, open, closed) and up to three open tasks; tasks that are waiting on you come first and are marked with a hand icon.

- **Click a task** to send it to its session as your next message.
- **Resume** reopens the session, or brings its terminal to the front if it is already running.
- **✓** marks a task done; **Hide** hides the tab until the session changes again.
- **Mine** holds tasks you add yourself.

### Where a clicked task goes

| Session state | Terminal | Result |
| --- | --- | --- |
| Running | Terminal, iTerm | The task is typed into the session's own tab and submitted. Claude Code queues it if it is still working. |
| Running | Warp | Leftovers switches to the session's tab (⌘1–⌘8), checks that the tab shows the session's title, then pastes the task and presses Return. Needs the Accessibility permission. |
| Running | Ghostty, other | These terminals cannot be scripted to type into one tab, so a new window continues a fork of the session (`claude --resume <id> --fork-session`) with the task. The open tab's conversation is left intact. |
| Closed | Any | The session reopens in your terminal (`claude --resume <id> "<task>"`). |

If the Warp tab cannot be identified with certainty (no Accessibility permission, a custom tab title, or more than eight tabs in the window), nothing is typed and the fork in a new window is used instead. Linux and Windows always use a new terminal window, as in the last two rows.

### Suggested replies (macOS)

When a session is waiting on a decision, the AI drafts the reply you would most likely send, with the options spelled out (for example *"Use the short headline: 'Pay once, keep it forever'"*). **Approve** sends it as is; **Edit** opens it in a small window together with Claude's last message. Swipe left and right in the panel, or use ‹ › on the widget, to move between suggestions.

### Command line (Linux)

```sh
leftovers            # interactive terminal panel
leftovers gui        # window + tray icon
leftovers list       # plain text; tasks are numbered
leftovers json       # machine-readable
leftovers waybar     # one JSON line for waybar / polybar
```

See [cli/README.md](cli/README.md) for every command, the panel's key bindings and status-bar setup. `claude-todo` remains available as an alias of `leftovers`.

## How it works

```
~/.claude/projects/*.jsonl ──► scanner ──► analyzer (claude -p --model haiku) ──► state.json ──► panel / widget
~/.claude/sessions/*.json  ──┘   (live sessions, PIDs)                             (cached per session)
```

1. **Scanner** reads recent session transcripts in `~/.claude/projects` and the live-session registry in `~/.claude/sessions`, which gives each running session's process, and from it its terminal.
2. **Analyzer**: when a session goes idle, your own `claude` CLI summarizes the end of the conversation into at most three open tasks, each with a one-line explanation, a waiting-on-you flag and, where it fits, a suggested reply. Results are cached and recomputed only when the session changes.
3. **Publisher** writes the result to a small JSON file that the widget extension reads. The panel, widget and Linux/Windows window render the same data.

## Privacy

Leftovers has no server and sends no telemetry. The only network traffic is what Claude Code itself sends: the AI summary passes the tail of a conversation to the model **through your own `claude` CLI and login** (a few tenths of a cent per summary; no API key and no third-party service). Turn summaries off with **AI summary: off** in the panel footer (or `--no-ai` on Linux); Leftovers then falls back to simple rules.

## Configuration

Leftovers needs no configuration. These environment variables change its defaults:

| Variable | Effect |
| --- | --- |
| `CLAUDE_CONFIG_DIR` | Claude Code's data directory, if it is not `~/.claude` (Linux, Windows) |
| `CLAUDE_TODO_TERMINAL` / `TERMINAL` | Terminal used to open sessions (Linux) |
| `CLAUDE_TODO_STATE` | Where cached summaries are stored (Linux, Windows) |
| `LEFTOVERS_VERSION` | Release the installer installs |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| "AI summaries are missing" in the panel | Run `claude` once in a terminal and log in. |
| A clicked task does nothing in Terminal or iTerm | Allow Leftovers under System Settings → Privacy & Security → Automation. |
| A clicked task opens a new Warp window instead of the session's tab | Allow Leftovers under System Settings → Privacy & Security → Accessibility. |
| `leftovers gui` reports a missing library (Linux) | Install the package it names, usually `sudo apt install libxcb-cursor0`. |
| No tray icon on GNOME | Install the AppIndicator extension, or use the window directly. |
| The widget shows old data | Open the menu bar panel once; the widget refreshes within a few seconds. |

## Building from source

macOS (needs Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

```sh
brew install xcodegen
DEVELOPMENT_TEAM=<team id> scripts/build_app.sh   # build/Leftovers.app
TEAM_ID=<team id> scripts/release.sh              # signed, notarized build/release/Leftovers.dmg
```

Linux and Windows:

```sh
cd cli
python3 -m unittest discover -s . -t . -p "test_*.py"
python3 -m claude_todo gui
packaging/linux/build_deb.sh                      # from the repository root, on Debian/Ubuntu
```

If you build under your own Apple team, change the bundle identifiers in `project.yml`.

### Repository layout

| Path | Contents |
| --- | --- |
| `App/` | macOS menu bar app: scanner, analyzer, panel, terminal launcher |
| `Widget/`, `Shared/` | WidgetKit extension and the views and models it shares with the app |
| `cli/` | Python implementation for Linux and Windows (window, terminal panel, CLI) |
| `packaging/linux/` | `.deb` build script and desktop entry |
| `scripts/` | macOS build and release scripts |
| `install.sh`, `install.ps1` | One-line installers |

## License

[MIT](LICENSE)
