# Focus Island

[![Focus Island: one pomodoro, three Claude Code sessions in Ghostty, Claude and PyCharm](docs/media/focus-island-demo.gif)](docs/media/focus-island-demo.mp4)

**Focus Island** is a macOS companion for **Claude Code and Codex** that turns the time you spend waiting on coding agents into something useful. While an agent works on a task, the app suggests your next step: a new task from a simple kanban board, a session that is waiting for you, or a nudge to get back to work if you drifted off to social media. Codex monitoring is an opt-in preview; see the [setup and support matrix](#codex-monitoring-opt-in-preview).

> [!NOTE]
> Available in **English** (default), **Spanish**, and **Russian**. Change the interface language in Settings → General → Language.

## Installation

1. Download `Focus.Island.dmg` from this fork's [Releases](https://github.com/mpakus/focus-island/releases/latest) page. The DMG and alternative `Focus.Island.zip` contain the same universal app, compiled natively for **Apple Silicon (`arm64`) and Intel (`x86_64`)**, on macOS 14 or later.
2. Open the DMG and drag **Focus Island** into Applications.
3. On first launch, right-click the app → Open.
4. In the island under the notch, click "Connect" to open Setup, then install hooks for Claude Code, Codex, or both. For Codex, also complete the hook trust step below.

> [!NOTE]
> The v0.5.1 binaries use ad-hoc signing and are **not notarized by Apple**. macOS may block the first launch. After attempting to open the app, use System Settings → Privacy & Security → Open Anyway if needed. Only open a download you trust.

## Features

**Start of day and binding sessions to tasks**
- "Start of day" — a morning card: what was left open yesterday, last night's note, and a pick of 1–3 tasks for today.
- A new Claude Code or connected Codex session offers to bind itself to a task (from this project or others), create a task from the first prompt, or skip.

**Focus timer**
- "Pick a task · Todo N" in the closed island and a "What are you working on now?" card; starting a task (dragging it to In progress or clicking "Start") opens the "Start task" sheet.
- The sheet binds open sessions (same project first) and optionally starts a pomodoro: 25 min, 50 min or a custom length (5–120), followed by a break.
- The timer lives in the island's left ear and in the panel header, with pause and stop; the task card shows the same timer and "+ Add session".
- Defaults are 50 minutes of focus and 10 of rest (Settings → Focus → "Focus timer"); for a one-off change use "Timer 50 min ▾" in the panel (25/50/90/custom) and the break-length menu on the "Pomodoro done" card.
- End of focus: a sound and a 5-second countdown, then the break starts on its own (5/10/15/20 min, can be cancelled or started right away; can be turned off in settings); the interval's KPIs and the next step go into the task note. After the break — "▶ Start focus · N min"; focus never starts by itself.
- When a session has done its part — "✓ Done": it stays in the task (time, summary) but moves to the collapsed "Done" group and stays quiet; "Undo" or a new prompt brings it back. "Unbind" and "Move to another task" are in the "⋯" menu.
- When Claude finishes, the island shows a short summary (for Claude.app sessions — Claude's own turn summary, for terminal sessions — the first sentence of the reply); the full reply is behind "Full reply ▾".
- Without a task, the island only offers to pick one; a new session does not pop the island open — there is a hint in the pill, and during focus a quiet "Into this task / ✕" line at the bottom of the panel.
- The number of pomodoros per day appears in the "Today" summary.
- "Take" on the pick card brings a task from "In progress" into focus; if it has no sessions, the "Task sessions" screen opens right away with checkboxes (bound sessions first, then the project's sessions). While a task is in focus, the panel shows only its sessions: "Unbind", "+ Add session", "Timer", "✓ Close task" (goes straight to Done, with an 8-second "Undo").

**While an agent is working**
- Every session is labelled with its task; Claude Code also shows its current plan step (from TodoWrite): "Step k of n", progress and a time estimate.
- "What's next?" — stay in the task: queue the next prompt, review changed files (git diff), tick off the definition of done; or, as a second option, switch to a waiting session or another task.
- Prompt queue: when Claude finishes, "Send and go back" pastes the prompt into the session's terminal and takes you there. Sending works in Ghostty, iTerm2, Terminal.app and tmux; in other terminals the prompt is copied to the clipboard (⌘V).
- Distraction nudge: if you wander off to Telegram, YouTube and the like, the island reminds you to go back to the terminal (snooze for 5 minutes or "I need this").
- Coming back: when Claude is done, the card shows what was done, the definition of done and the queued prompt.

**Multiple sessions**
- Session panel: "Waiting for you", "Done, review", "Working", "No task", "Paused".
- Overload: when the task in focus gets more sessions than your limit, the island suggests answering a waiting one first or pausing a working one. Sessions of other tasks and unbound sessions do not count.
- Waiting sessions from other tasks: the "Waiting outside task · N" button in the panel expands a list (age, which session, "Open", "⋯" — add to the current task or snooze); they never pop the island open on their own, there is just a quiet "N waiting" counter on the left of the pill.
- Re-entry: when you switch to another task, you get a short "where you left off" and "what Claude did" summary.
- Collapsed island ears: a summary on the left (working, waiting, done), the task in focus on the right; an orange "waiting Nm" when something has been waiting a long time.

**Board and task card** (⌥⌘B)
- Kanban Backlog → Todo → In progress → Done with drag & drop; badges for progress, definition of done and "prompt queued".
- Task card: description, definition of done, "Where you left off", queued prompt, all task sessions with "Open" / "Resume" / "Unbind", "+ Add session" (same picker screen), "Close task".

**Jira tasks (opt-in preview)**
- Import selected assigned issues into Backlog or Todo, then use the same sessions, timers, notes, criteria, and reports.
- Issue keys link to Jira; remote status appears separately from the local column. Closing a local task never changes Jira.
- Manual refresh preserves local work. Imported tasks remain usable offline; disconnect keeps their history.
- Requires a separately installed and signed-in Atlassian CLI. See [Jira setup](#jira-setup-opt-in-preview).

**Reports**
- "Today" — a daily summary: "You were working", "Agents were working", "Sessions waited for you", distractions, a time strip by task, "Done", "Still open", "Start tomorrow with"; "Copy to note" puts a markdown summary on the clipboard.
- "Week" — tasks, sessions, distractions, hours per day and "Where the time went".
- "History" — a searchable session archive; "Open" jumps to a live session and "Resume" continues one via `claude --resume` or `codex resume` with its native session ID.

**Settings**
- Settings → General → Language: **English** (default), **Spanish**, or **Russian**. The interface, generated session messages, dates, and exported summaries follow this choice. Your task names, prompts, and agent replies stay as written.
- Settings → Setup: independent Claude Code and Codex hook status, paths, install and uninstall, plus Codex trust instructions and reinstall controls.
- "Sessions": parallel session limit (1–6), waiting-session reminder (5–60 min), the "Start of day" morning screen.
- "What's next?", "Distractions" (threshold, blocklist of domains and apps), terminal used for Resume, board hotkey.
- Settings → General → "Open island on hover": turn it off to open the island only by clicking the notch.

## Codex monitoring (opt-in preview)

Focus Island supports local Codex command-hook monitoring alongside Claude Code. The adapter and UI have been verified with synthetic documented-contract fixtures. Native hook trust/emission and desktop lifecycle acceptance are still pending; no minimum supported Codex release is certified yet. The inspected CLI was `0.163.0-alpha.11.1`.

1. Install and launch **Focus Island v0.4.0 or later** from [Releases](https://github.com/mpakus/focus-island/releases/latest), or build it from source.
2. Open **Settings → Setup → CLI Hooks → Codex → Install**. **Install All** includes Codex and Claude Code; Codex can also be installed on its own.
3. In the Codex CLI, open `/hooks` and review/trust the installed hooks using its own controls ([hook trust guide](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks)).
4. Send a prompt. Setup diagnostics must show **Receiving Codex events** and the island must show a Codex session before treating monitoring as connected. **Configured** confirms installation only; use **Reinstall Codex hooks** and **Re-check** in diagnostics when repairing setup.

CLI alternative from the repository:

```bash
swift build -c release --product OpenIslandHooks
swift run OpenIslandSetup installCodex --hooks-binary .build/release/OpenIslandHooks
swift run OpenIslandSetup statusCodex
# Disconnect later; history and the shared Claude helper remain intact:
swift run OpenIslandSetup uninstallCodex
```

Configuration uses `$CODEX_HOME/hooks.json` or `~/.codex/hooks.json`; the setup CLI also accepts `--codex-dir /path/to/home`. Existing hooks are preserved, changed configuration is backed up, and the installer never writes Codex trust records. If Focus Island entries already appear in `config.toml`, resolve those duplicates before installing.

| Capability | Claude Code | Codex preview |
| --- | --- | --- |
| Running, idle, completion, interruption | Existing support | Hook adapter; native-client acceptance pending |
| Task binding, timers, history, provider labels | Yes | Yes |
| Approval attention | Existing inline flow | Observe and open app; decide in Codex |
| Questions, plan steps, subagents, usage | Existing support | Not mapped |
| Navigation | Supported terminal/session routes below | App activation for Terminal, iTerm and Ghostty when hinted; select the conversation yourself |
| Queued prompt / completion reply | Existing supported sending routes | Copy queued prompt and open app; direct sending disabled |
| Resume / new session | `claude --resume` / `claude` | `codex resume` / `codex`; task card has an agent choice |
| Restart recovery | Registry and transcript discovery | Own registry; restored sessions stay unconfirmed until a fresh hook |
| Local desktop, cloud, remote | Existing Claude routes | Not certified / not supported |

Codex hooks have no heartbeat. After 15 minutes without a signal, the session becomes **unconfirmed**, stops accumulating work/wait time, and remains dismissible. This does not mean the turn succeeded or the process died. Optional Codex transcript discovery is not included. Final replies come from hook payloads when supplied.

Daily, weekly and task work totals use the union of Claude and Codex intervals; overlapping sessions are not added twice. Daily exports and the timeline retain provider subtotals. SQLite migration `v6` saves a consistent `before-codex-*.sqlite` snapshot before upgrading existing data. Prefer disconnecting Codex to downgrading the app; older builds do not understand the new provider/activity values. Preserve the current database before restoring any older backup.

## Jira setup (opt-in preview)

1. Install [Atlassian CLI](https://developer.atlassian.com/cloud/acli/guides/install-macos/) and sign in from Terminal:

   ```bash
   brew tap atlassian/homebrew-acli
   brew install acli
   acli jira auth login --web
   ```

2. Open **Settings → Focus → Jira → Connect signed-in account**. Focus Island verifies the CLI account and reads its assigned, unfinished issues.
3. Open the board (⌥⌘B), choose **Jira → Add from Jira**, select issues, choose Backlog or Todo and optionally a local project folder, then import.
4. Use **Jira → Refresh linked tasks** to fetch current issue text/status. **Reload issues** in the import sheet refreshes the list of available assignments.

Focus Island uses the official CLI's read commands; it never collects API tokens, reads CLI credential files, or writes Jira issues. The CLI is not bundled. It must be installed at `/opt/homebrew/bin/acli`, `/usr/local/bin/acli`, or `~/.local/bin/acli`. Changing the CLI account requires disconnecting and reconnecting in Focus Island. Disconnect does not sign the CLI out or remove existing tasks. **Detach from Jira** makes a card's title and description locally editable.

Supported scope: one Jira Cloud account/site at a time, ordinary `*.atlassian.net` sites, assigned issues of all types, selected import, and manual refresh. Jira Data Center, custom domains, automatic polling, workflow transitions, comments, attachments, and worklogs are not included. Descriptions are converted from ADF to plain text; formatting and embedded media may be omitted. Follow the issue link for the original.

The verified CLI is `1.3.39-stable`. Live authentication, assigned-issue search, detail retrieval, and import/refresh passed on one Jira Cloud account using a disposable board; local notes and completion survived refresh. Use **v0.5.1 or later**: v0.5.0 requested search fields that ACLI rejects. Migration, cancellation, malformed responses, and UI rendering also have automated coverage. The in-app connection requires a successful search; errors leave cached tasks available. Other tenants and CLI versions still need verification.

Migration `v7` saves a consistent `before-jira-*.sqlite` snapshot before updating an existing database. It preserves tasks, Claude/Codex sessions, notes, criteria, prompts, activity, and timers. Prefer disconnecting Jira to restoring an old database; restoring a backup would discard later local work.

## Releasing

```bash
OPEN_ISLAND_SIGN_IDENTITY=- zsh scripts/release.sh 0.5.1
```

Requirements: a clean `main` that matches `origin/main`, the same version in `VERSION`, release notes in `docs/releases/v0.5.1.md` (the first line is the release title), and an authenticated `gh` CLI with permission to publish to the origin repository. The script runs the tests, builds and verifies a universal DMG and ZIP, tags `v0.5.1`, and publishes the GitHub Release.

`OPEN_ISLAND_SIGN_IDENTITY=-` selects ad-hoc signing. To use the local certificate instead, run `zsh scripts/setup-dev-signing.sh` once and omit that variable. Neither option provides Apple notarization. `VERSION` also supplies the version shown in packaged and development app bundles; `OPEN_ISLAND_VERSION` can override it for local builds.

## Building and running the dev version

Run the tests and compile the debug app and both helpers:

```bash
bin/test.dev
```

The script prints the build directory and stops on any test or build failure. On Command Line Tools setups with the macOS 27 SDK, it uses the installed macOS 26.5 SDK to work around missing SwiftUI macros. Set `SDKROOT` to select a different SDK. It does not install or launch the app.

To build, install and launch the dev app bundle:

```bash
zsh scripts/launch-dev-app.sh
```

Agent integration hooks are installed from Settings → Setup. Claude Code uses `~/.claude/settings.json`; Codex uses `CODEX_HOME/hooks.json` or `~/.codex/hooks.json` and requires review/trust in Codex.

App data is stored in `~/Library/Application Support/FocusIsland/`.

Checks: `zsh scripts/harness.sh ci`, tests: `zsh scripts/test-clt.sh`.

Implementation and validation: [Codex monitoring plan and evidence](docs/CODEX-MONITORING-PLAN.md).

Jira implementation and limitations: [Jira import plan and evidence](docs/JIRA-INTEGRATION-PLAN.md), with [API and authentication research](docs/JIRA-API-RESEARCH.md).

## About

This fork is maintained by **Renat "MpaK" Ibragimov** — [@mpakus on GitHub](https://github.com/mpakus) · [aomega.co](https://aomega.co). It adds Codex monitoring alongside Claude Code and an English, Spanish, and Russian interface.

Focus Island builds on [Dias Zhanabayev's Focus Island](https://github.com/dias-zhanabayev/focus-island), which was forked from [open-vibe-island](https://github.com/Octane0411/open-vibe-island). Thanks to the original authors and contributors. This fork remains licensed under [GPL v3](LICENSE).

## Supported terminals

Terminal.app, iTerm2, Ghostty, tmux, Zellij, WezTerm, Warp, cmux, VS Code, Cursor, Windsurf, Trae, Qoder, CodeBuddy, JetBrains IDEs (jump-to-terminal for Claude Code sessions).

## Requirements

- **Run the app:** macOS 14 or later, on Apple Silicon or Intel. The release downloads include the app and both hook/setup helpers; no Swift toolchain is needed.
- **Build from source:** Swift 6.2 or later with Xcode or Command Line Tools. Run `bin/test.dev` for tests and a debug build.

---

## License

[GPL v3](LICENSE)
