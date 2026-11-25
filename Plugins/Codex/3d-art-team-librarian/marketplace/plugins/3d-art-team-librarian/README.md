# 3D Art Team Librarian

At **22:00 (10:00 PM) in each workstation’s local time zone**, 3D Art Team Librarian checks the enrolled team member’s active and archived Codex chats across all projects. It commits changed documents together to `main` in the team repository. Each session has a stable Markdown filename.

```text
YHAnimationStudios/YH_Knowledge_database
└── Usage data/3D art team/<seat-email>/
    ├── Codex/
    │   ├── <session-id>.md
    │   └── images/<session-id>/<sha256>.png
    ├── Claude/
    └── Opencode/
```

The plugin creates the folders automatically. Claude and Opencode are reserved for their respective collectors. A team member using multiple workstations can enroll each one into the same seat folder. It exports visible user and assistant messages and masks common credential formats in text. Repository readers can read the chats and see everything visible in shared pictures.

With pictures enabled, the next due batch checks existing active and archived chats as well as new ones. An attached or generated picture appears at its original position in the Markdown. The folder immediately above the picture matches the session filename without the extension. A repeated picture uses one file within a session and gets a separate path in every other session where it appears.

The exporter saves a PNG of each recoverable still image. It can use image data saved in the chat or an unchanged local picture referenced by the chat. It supports static PNG, JPEG and GIF, and static WebP when the Windows decoder is available. Animated images, images over 24 million pixels, source or exported images over 25 MiB, missing originals and file identifiers without recoverable bytes get an unavailable marker. Previously archived pictures can still be linked. The evening receipt includes availability counts for this workstation.

## Install or upgrade

1. Sign in to Codex with your team seat. Use Git for Windows with write access to the team repository’s `main` branch and PowerShell 7.2 or later.
2. Extract this release to its own permanent "3d-art-team-librarian" folder with its `.agents` and `plugins` directories. For an existing local marketplace, replace its release files in its registered folder.
3. In PowerShell 7, open that marketplace folder and run the following commands. On an existing registration you can skip `marketplace add`.

   ```powershell
   codex plugin marketplace add .
   $release = codex plugin add 3d-art-team-librarian@3d-art-team-tools --json | ConvertFrom-Json
   $scripts = Join-Path $release.installedPath 'scripts'
   & "$scripts\Collect-AnimTeamHistory.ps1" -InventoryOnly
   & "$scripts\Configure-AnimLibrarian.ps1" -EnableAccountSync
   ```

Run enrollment on each workstation after installing or upgrading. On an existing active seat, this points the Windows task at version 0.5.0 and preserves the configured time, picture setting, and completed evening receipts. On first enrollment the default is 22:00 local, with text-only sharing. Add `-IncludeImages` to include pictures and backfill eligible older chats. Pass `-IncludeImages:$false` to turn picture sharing off. Enrolling after the deadline checks that evening immediately.

## Evening batches and missed runs

The task runs with Codex open or closed while the enrolled Windows user is signed in. It checks at 22:00, at sign-in, and every 30 minutes. At each check it compares the most recent evening deadline with the last successful batch. After several missed evenings, it reconciles the saved chats together on the next available check. Changes made after a completed evening batch wait for the following evening.

A successful upload records the Git commit. An evening with no changes records a successful check locally. An offline workstation, unavailable seat identity, incomplete collection or conflicting session versions leaves work due for retry. Session documents and their pictures share a single commit per workstation.

## Check the result

```powershell
& "$scripts\Configure-AnimLibrarian.ps1" -Status
```

The status shows the local deadline, most recent due evening, completion receipt and last attempt. The Windows task’s next wake-up may be a routine 30-minute check. Run `Sync-AnimTeamSessions.ps1` to retry a due batch immediately. It uses the same evening deadline.

| Status | Meaning |
| --- | --- |
| `Waiting` | The first scheduled evening is still ahead. |
| `Due` or `RetryPending` | A deadline has passed. Check `lastAttempt.reason` for a failed attempt. |
| `Completed` | `currentReceipt.batchDate` identifies the completed evening. `Changed` and `RecoveredCommit` include the commit SHA. `NoChanges` means the check succeeded without a new commit. `VerifiedAfterRetry` means Git already covers that batch, but the exact original commit could not be established. |

During the storage upgrade, `UsageLayoutNotActive` means the workstation is waiting for the repository’s new layout. It will retry on its normal schedule. `MigrationVerificationRequired` means an interrupted batch needs reconciliation. Keep its local receipt and staged batch, and have the repository maintainer compare the recorded commit with the migrated files before retrying.

To stop this workstation’s future uploads and remove its scheduled task, run the following command before uninstalling. Documents already committed stay in GitHub.

```powershell
& "$scripts\Configure-AnimLibrarian.ps1" -DisableAccountSync
```
