# Focus workflow improvements

Base: `95b2f7f` (v0.7.0). Scope approved: command palette, review handoff,
context-aware next actions, local backup and restore. Integration certification
is not part of this change.

## Implementation plan

- Add a searchable keyboard palette using existing task, session, and timer actions.
  Keep the board shortcut; add a separate configurable palette shortcut.
- Add a review window with the completion summary, branch/worktree, selectable
  files and bounded local diffs, and the task's existing completion criteria.
- Rank approvals and questions together by actual waiting age; favor the current
  task except when another session has waited past the reminder threshold.
  Explain the recommendation in the existing next-action card.
- Add consistent SQLite backups, daily local snapshots, a validated restore
  preview, and a staged restart restore with a mandatory recovery copy.
  Preserve the existing schema and keep credentials out of backup exports.
- Cover ranking, command routing, real temporary Git repositories, and backup
  round trips/failure paths with tests. Render the new UI using synthetic data.
  Run the full development checks and localization validation.

## Evidence

Implemented all four workflows without a database schema change or new dependency.
New UI text is translated into English, Spanish, and Russian. README documents
the shortcuts, review scope, backup retention, and restore behavior.

- `rtk proxy bash bin/test.dev`: **974 tests in 99 suites passed**; debug app,
  hooks, and setup helpers built using the macOS 26.5 SDK.
- `rtk proxy python3 scripts/check-localizations.py`: **1,101 keys** validated
  across all three catalogs. `rtk git diff --check` passed.
- Real temporary Git repositories cover staged/unstaged/untracked/deleted files,
  filenames containing spaces, tabs, newlines and a leading dash, unborn and
  detached HEAD, clean/missing repositories, symlinks, and oversized previews.
- SQLite tests cover every table across a restore, frozen previews, migration of
  an older backup without changing its source, schema rejection, failed pending
  restore, seven-snapshot retention, export replacement, and protected paths.
- The WAL-mode round trip initially exposed a non-portable snapshot. Snapshot
  creation now switches the destination to DELETE journal mode before closing.
  The regression copies only the database file, restores it, checks the full
  contents, verifies the pre-restore recovery copy, and verifies reopening does
  not replay the restore over later work.
- Command tests cover search/capture, timer actions, stale session targets,
  preference compatibility, and independent Carbon dispatch for the board and
  palette shortcuts. Coordinator tests verify that repeated events do not reset
  waiting age and that an overdue session outranks the currently focused task.
- Synthetic palette, review, and restore screens passed OCR assertions and were
  visually inspected. Local evidence is in `output/focus-workflows/`; the full
  verification log is saved there too. No user database was used by the new tests.

## Validation limits

The installed app was not replaced or manually exercised with a physical global
shortcut. This is a local debug build, not a universal release/package check.
Live Jira, ClickUp, and Codex acceptance was intentionally outside the selected
scope. Existing ClickUp decoder and native-build-system deprecation warnings
remain. These limits describe implementation validation before release packaging.

## v0.8.0 release preparation — 2026-10-26

The user requested the version update, main merge, GitHub publication, and cleanup.
The release includes the complete feature commit `e07da3c`. `VERSION`, README
release commands, and English release notes now target v0.8.0. GitHub write access
and the existing Sparkle signing key were verified before publication. The host
has no Apple signing identity, so the established ad-hoc signing mode is used.

Release verification must run the repository release script from clean main,
confirm universal slices and bundle/package integrity, compare published asset
digests, check the latest signed appcast, and preserve local evidence before
archiving the implementation worktree. Publication evidence is retained in the
main checkout's ignored `output/release-0.8.0/` directory.
