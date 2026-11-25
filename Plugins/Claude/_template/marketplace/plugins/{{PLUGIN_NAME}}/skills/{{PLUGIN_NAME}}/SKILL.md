---
name: {{PLUGIN_NAME}}
description: Use when {{MEMBER_PHRASE}} asks to count their Claude Code sessions, enroll in evening GitHub backups, check whether the evening commit succeeded, retry a missed batch, or disable sync.
---

# {{DISPLAY_NAME}}

The bundled Windows scripts maintain `YHAnimationStudios/YH_Knowledge_database`, branch `main`, under `Usage data/{{TEAM_FOLDER}}/<seat-email>/Claude/<session-id>.md`. Pictures live inside the same Claude folder. Only Claude Code sessions (CLI, desktop Code tab, IDE) are exported, not claude.ai Chat conversations. The Windows scheduled task batches changed conversations at **22:00 local time**. It checks again at sign-in and every 30 minutes to catch missed evenings.

- For inventory counts, use `${CLAUDE_PLUGIN_ROOT}/scripts/Collect-ClaudeTeamHistory.ps1 -InventoryOnly`.
- When {{MEMBER_PHRASE}} asks to share their sessions with the team repository, use `${CLAUDE_PLUGIN_ROOT}/scripts/Configure-AnimLibrarian.ps1 -EnableAccountSync [-IncludeImages]` to enroll that Windows user. Add `-IncludeImages` when they request pictures or picture backfill. Enrollment copies the scripts to a stable per-user folder and raises Claude Code's `cleanupPeriodDays` to at least 3650 unless `-KeepTranscriptRetention` is passed. Updating the plugin requires re-running `-EnableAccountSync` to move the task to the new version.
- To check whether an evening succeeded, use `${CLAUDE_PLUGIN_ROOT}/scripts/Configure-AnimLibrarian.ps1 -Status`. Report the due evening, last completed evening, Git commit or unchanged result, and any retry reason. Keep conversation text out of status reports.
- To retry the latest due evening, use `${CLAUDE_PLUGIN_ROOT}/scripts/Sync-AnimTeamSessions.ps1`. All triggers use the same deadline and receipt.
- To stop future uploads and remove the Windows scheduled task, use `${CLAUDE_PLUGIN_ROOT}/scripts/Configure-AnimLibrarian.ps1 -DisableAccountSync`.

See [setup and recovery](../../README.md).
