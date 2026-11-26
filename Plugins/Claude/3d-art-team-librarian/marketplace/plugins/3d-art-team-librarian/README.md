# 3D Art Team Librarian

At **22:00 (10:00 PM) in each workstation's local time zone**, 3D Art Team Librarian checks the enrolled member's Claude Code sessions across all projects. It commits changed documents together to `main` in the team repository. Each session has a stable Markdown filename.

```text
YHAnimationStudios/YH_Knowledge_database
└── Usage data/3D art team/<seat-email>/
    └── Claude/
        ├── <session-id>.md
        └── images/<session-id>/<sha256>.png
```

The plugin creates the folders automatically. A member using multiple workstations can enroll each one into the same seat folder.

## What is exported

Only Claude Code sessions are exported (CLI, desktop Code tab and IDE), not claude.ai Chat conversations.

- Only user and assistant text and pasted pictures are exported. Common credential formats in text are masked.
- Tool calls and results, thinking and command output are never exported.
- When a session was rewound or edited, only the current conversation is kept.

Repository readers can read the sessions and see everything visible in shared pictures. With pictures enabled, the next due batch also checks existing sessions. A repeated picture uses one file within a session and gets a separate path in every other session where it appears.

## Install or upgrade

1. Sign in to Claude Code with your team seat (claude.ai account). Use Git for Windows with write access to the team repository's `main` branch and PowerShell 7.2 or later.
2. Install the plugin. Use **one** of these routes.

   **From GitHub (recommended).** The repository is private, so Git on this PC must already be signed in to GitHub. Claude Code does not prompt for a password. Git Credential Manager, which comes with Git for Windows, or `gh auth login` followed by `gh auth setup-git`, provides the sign-in. Then run:

   ```powershell
   claude plugin marketplace add YHAnimationStudios/YH_Knowledge_database
   claude plugin install 3d-art-team-librarian@yh-team-tools
   ```

   To upgrade later, run `claude plugin marketplace update yh-team-tools` and `claude plugin update 3d-art-team-librarian@yh-team-tools`.

   **From the release zip.** Extract the release to a permanent folder with its `.claude-plugin` and `plugins` directories, open that folder in PowerShell 7, and run the commands below. On an existing registration, replace the release files in the registered folder and skip `marketplace add`.

   ```powershell
   claude plugin marketplace add .
   claude plugin install 3d-art-team-librarian@3d-art-team-tools
   ```

3. Find the installed scripts and enroll this workstation. `claude plugin list --json` reports the plugin folder in `installPath`.

   ```powershell
   $p = (claude plugin list --json | ConvertFrom-Json) | Where-Object { $_.id -like '3d-art-team-librarian@*' } | Select-Object -First 1
   $scripts = Join-Path $p.installPath 'scripts'
   & "$scripts\Collect-ClaudeTeamHistory.ps1" -InventoryOnly
   & "$scripts\Configure-AnimLibrarian.ps1" -EnableAccountSync
   ```

Run enrollment on each workstation after installing or upgrading. Enrollment copies the scripts to `%LOCALAPPDATA%\YH3DArtTeamClaudeLibrarian\app\<version>\` and points the Windows task there, so updating the plugin requires re-running `-EnableAccountSync` to move the task to the new version. On an existing active seat this preserves the configured time, picture setting and completed evening receipts. On first enrollment the default is 22:00 local, with text-only sharing. Add `-IncludeImages` to include pictures and backfill eligible older sessions, or pass `-IncludeImages:$false` to turn picture sharing off. Use `-EveningTime HH:mm` to choose another time, and `-ReplaceEnrollment` to move this workstation to a different signed-in account. Enrolling after the deadline checks that evening immediately.

### Transcript retention

Claude Code deletes old session files after `cleanupPeriodDays` (30 days by default). Enrollment raises that setting in `~/.claude/settings.json` to at least 3650 so sessions are still there when the evening batch runs. Pass `-KeepTranscriptRetention` to leave your setting unchanged. Sessions deleted by Claude Code before a batch cannot be backed up.

## Evening batches and missed runs

The task runs with Claude Code open or closed while the enrolled Windows user is signed in. It checks at 22:00, at sign-in, and every 30 minutes. At each check it compares the most recent evening deadline with the last successful batch. After several missed evenings, it reconciles the saved sessions together on the next available check. Changes made after a completed evening batch wait for the following evening.

A successful upload records the Git commit. An evening with no changes records a successful check locally. An offline workstation, a different or signed-out Claude account, incomplete collection or conflicting session versions leaves work due for retry. Session documents and their pictures share a single commit per workstation.

## Check the result

Open a new PowerShell 7 window and look up the scripts folder again (the same lookup as install step 3), then run the status command.

```powershell
$p = (claude plugin list --json | ConvertFrom-Json) | Where-Object { $_.id -like '3d-art-team-librarian@*' } | Select-Object -First 1
$scripts = Join-Path $p.installPath 'scripts'
```

```powershell
& "$scripts\Configure-AnimLibrarian.ps1" -Status
```

The status shows the local deadline, most recent due evening, completion receipt, last attempt, the Windows task and the transcript retention. The task's next wake-up may be a routine 30-minute check. Run `Sync-AnimTeamSessions.ps1` to retry a due batch immediately. It uses the same evening deadline.

| Status | Meaning |
| --- | --- |
| `Waiting` | The first scheduled evening is still ahead. |
| `Due` or `RetryPending` | A deadline has passed. Check `lastAttempt.reason` for a failed attempt. |
| `Completed` | `currentReceipt.batchDate` identifies the completed evening. `Changed` and `RecoveredCommit` include the commit SHA. `NoChanges` means the check succeeded without a new commit. `VerifiedAfterRetry` means Git already covers that batch, but the exact original commit could not be established. |
| `ScriptMissing` | The Windows task points at a script copy that no longer exists, so nothing is being backed up. Re-run `-EnableAccountSync`. |
| `ScheduleUpgradeRequired` | The enrollment predates the current schedule. Re-run `-EnableAccountSync`. |
| `NotEnrolled` | This workstation has no enrollment. Run `-EnableAccountSync`. |
| `Disabled` | Sync was turned off with `-DisableAccountSync`. |

Common `lastAttempt.reason` values:

- `PublishFailed`: the upload to GitHub failed, most often because the workstation is offline or the push was rejected.
- `AccountChanged`: Claude Code is signed out or signed in as a different account than the enrolled seat.
- `CollectionIncomplete` or `CollectionFailed`: the sessions could not be read completely.
- `ConflictingSessionVersions`: two different versions of one session were found.
- `DestinationVisibilityUnverified`: the repository's visibility could not be confirmed, so nothing is pushed.
- `UsageLayoutNotActive`: the repository's storage layout is not active yet.

All of them retry on the normal schedule. Running `Sync-AnimTeamSessions.ps1` may also report `InactiveEnrollment`, which means sync is disabled or the enrollment was replaced by another account, so nothing is retried.

## Disable

To stop this workstation's future uploads and remove its scheduled task, run the following commands before uninstalling. In a fresh shell, the first two lines look up the scripts folder. Documents already committed stay in GitHub.

```powershell
$p = (claude plugin list --json | ConvertFrom-Json) | Where-Object { $_.id -like '3d-art-team-librarian@*' } | Select-Object -First 1
$scripts = Join-Path $p.installPath 'scripts'
& "$scripts\Configure-AnimLibrarian.ps1" -DisableAccountSync
```
