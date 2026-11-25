---
name: character-art-team-librarian
description: Use when a member of the Character art team asks to count their Codex chats, enroll in evening GitHub backups, check whether the evening commit succeeded, retry a missed batch, or disable sync.
---

# Character Art Team Librarian

The bundled Windows scripts maintain `YHAnimationStudios/YH_Knowledge_database`, branch `main`, under `Character art team/Codex usage data/<seat-email>/<session-id>.md`. The Windows scheduled task batches changed conversations at **22:00 local time**. It checks again at sign-in and every 30 minutes to catch missed evenings.

- For inventory counts, use `scripts/Collect-AnimTeamHistory.ps1 -InventoryOnly`.
- When a member of the Character art team asks to share their sessions with the team repository, use `scripts/Configure-AnimLibrarian.ps1 -EnableAccountSync` from the installed plugin to enroll that Windows user. Add `-IncludeImages` when they request pictures or picture backfill. The next due batch checks all saved chats for attached and generated pictures and writes each recovered image under the seat’s `images/<session-id>/` folder. The plugin creates the folders. Report receipt counts for unavailable originals when applicable.
- To check whether an evening succeeded, use `scripts/Configure-AnimLibrarian.ps1 -Status`. Report the due evening, last completed evening, Git commit or unchanged result, and any retry reason. Keep conversation text out of status reports.
- To retry the latest due evening, use `scripts/Sync-AnimTeamSessions.ps1`. All triggers use the same deadline and receipt.
- To stop future uploads and remove the Windows scheduled task, use `scripts/Configure-AnimLibrarian.ps1 -DisableAccountSync`.

See [setup and recovery](../../README.md).
