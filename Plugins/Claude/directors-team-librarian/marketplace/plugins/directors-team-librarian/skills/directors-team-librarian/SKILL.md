---
name: directors-team-librarian
description: Use when a member of the Directors team asks to count their Claude Code sessions, enroll in evening GitHub backups, check whether the evening commit succeeded, retry a missed batch, or disable sync.
---

# Directors Team Librarian

The bundled Windows scripts maintain `YHAnimationStudios/YH_Knowledge_database`, branch `main`, under `Usage data/Directors team/<seat-email>/Claude/<session-id>.md`. Pictures live inside the same Claude folder. Only Claude Code sessions (CLI, desktop Code tab, IDE) are exported, not claude.ai Chat conversations. The Windows scheduled task batches changed conversations at **22:00 local time**. It checks again at sign-in and every 30 minutes to catch missed evenings.

Run the bundled scripts with PowerShell 7 (`pwsh`), exactly as shown below. Windows PowerShell 5.1 (`powershell.exe`) cannot run them because they require PowerShell 7.2.

- For inventory counts, use `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/Collect-ClaudeTeamHistory.ps1" -InventoryOnly`.
- When a member of the Directors team asks to share their sessions with the team repository, use `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/Configure-AnimLibrarian.ps1" -EnableAccountSync [-IncludeImages]` to enroll that Windows user. Add `-IncludeImages` when they request pictures or picture backfill. Enrollment copies the scripts to a stable per-user folder and raises Claude Code's `cleanupPeriodDays` to at least 3650 unless `-KeepTranscriptRetention` is passed. Updating the plugin requires re-running `-EnableAccountSync` to move the task to the new version.
- To check whether an evening succeeded, use `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/Configure-AnimLibrarian.ps1" -Status`. Report the due evening, last completed evening, Git commit or unchanged result, and any retry reason. Keep conversation text out of status reports.
- To retry the latest due evening, use `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/Sync-AnimTeamSessions.ps1"`. All triggers use the same deadline and receipt.
- To stop future uploads and remove the Windows scheduled task, use `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/Configure-AnimLibrarian.ps1" -DisableAccountSync`.

See [setup and recovery](../../README.md).
