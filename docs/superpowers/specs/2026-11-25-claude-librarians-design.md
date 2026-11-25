# Claude Team Librarians — design

Date: 2026-11-25 · Branch: `feat/claude-librarians`

## Intent

The repository already ships five Codex "team librarian" plugins (`Plugins/Codex/<team>-team-librarian/`, v0.5.0). Each backs up an enrolled seat's Codex chats every evening to `Usage data/<team>/<seat-email>/Codex/`. The `Claude/` seat folders exist but nothing fills them. This work adds the same five librarians for **Claude Code**, under `Plugins/Claude/`, so the team's Claude Code sessions are archived the same way.

## Goals

- Five Claude Code plugins, one per team, with the same names, teams and destinations as the Codex set. The destination tool folder is `Claude/` instead of `Codex/`.

  | Plugin | Marketplace | Team folder |
  | --- | --- | --- |
  | `anim-team-librarian` | `anim-team-tools` | `Animators team` |
  | `3d-art-team-librarian` | `3d-art-team-tools` | `3D art team` |
  | `character-art-team-librarian` | `character-art-team-tools` | `Character art team` |
  | `directors-team-librarian` | `directors-team-tools` | `Directors team` |
  | `sound-team-librarian` | `sound-team-tools` | `Sound team` |

- Same behaviour the Codex 0.5.0 plugins give the user:
  - an evening batch at 22:00 local time
  - catch-up checks at sign-in and every 30 minutes
  - `-EnableAccountSync`, `-Status` and `-DisableAccountSync`, with optional `-IncludeImages` and `-EveningTime`
  - one Git commit per workstation per evening, with receipts and retry reasons
  - credential masking
  - the private-repository check before every push
- Runs alongside the Codex librarian on the same Windows user without interference.
- One source of truth for the five variants, so a fix lands once.

## Non-goals

- claude.ai web or desktop **Chat** conversations. They live on Anthropic's servers and are not on disk. Only Claude Code sessions are covered: the CLI, the desktop app's Code tab and IDE extensions. All of them write to `~/.claude/projects/`.
- Per-session account filtering. **Decided by the user:** every session on the workstation belongs to the team seat. All sessions on disk are backed up under the account signed in at enrollment.
- Hooks or slash commands. As in Codex 0.5.0, the Windows scheduled task owns publication and `hooks/hooks.json` stays empty.
- Changes to the Codex plugins.
- Non-Windows platforms. PowerShell 7.2+ and Git for Windows are required, the same as Codex.

## Anti-goals

These would make the work a failure even if it technically ran:

- Publishing tool output, file contents, thinking, or system and hook text. Codex exports only visible user and assistant messages, and Claude must do the same. Tool results routinely contain file contents and secrets.
- Pushing when the repository is publicly visible.
- A Claude task clobbering the Codex task's state, schedule or receipts, or the reverse.
- Silently losing history because Claude Code pruned transcripts before they were backed up.

## Constraints and facts found

- Transcripts are `~/.claude/projects/<encoded-project>/<session-uuid>.jsonl`, one JSON record per line. This machine has 388 top-level files. Subagent transcripts are in `<session-uuid>/subagents/` and are skipped, like Codex skips sub-agent threads.
- Record types seen include `user`, `assistant`, `system`, `attachment`, `custom-title`, `ai-title`, `summary`, `queue-operation`, `file-history-*` and `api-request*`. Only `user`, `assistant`, `custom-title` and `ai-title` matter.
- `message.content` is a string or an array of blocks:
  - `user` records hold `text`, `image` (base64 `source`) and `tool_result` blocks
  - `assistant` records hold `text`, `thinking` and `tool_use` blocks
- Records to drop include `isMeta`, `isCompactSummary`, `isApiErrorMessage` and `isSidechain`.
- Session title: the last `custom-title.customTitle` if present, else the last `ai-title.aiTitle`, else `Claude Code session`.
- Seat identity: `~/.claude.json` → `oauthAccount.emailAddress` and `oauthAccount.accountUuid`. This replaces Codex's `account/read`. If they're missing, nobody is signed in with a claude.ai account and enrollment refuses. **Decided by the user:** a person's Claude seat email is the same as their Codex seat email. Claude chats therefore land in the existing seat folder next to `Codex/`, and no seat-email override is needed.
- Claude Code deletes transcripts older than `cleanupPeriodDays` (default 30) from `~/.claude/settings.json`.
- A session being written right now can end in a partial line.
- Resuming a session can create a new session file that repeats earlier history. Each file is exported as its own document. Cross-file deduplication is out of scope.
- The publisher refuses to push unless `Usage data/layout.json` is `{"version":2}`. Keep that check.
- The publisher already accepts a `file:///` remote, which makes it testable offline.

## Approaches considered

1. **Shared template plus a build script (chosen).**
   - `Plugins/Claude/_template/` holds one copy of the plugin with placeholders.
   - `Plugins/Claude/Build-ClaudeLibrarians.ps1` stamps the five team folders and their release zips.
   - Generated output is committed, so users still download a ready zip.
   - Trade-off: adds a build step and contributors must not hand-edit the generated folders. The build script can check for drift (`-Check`).
2. **Five hand-made copies, as Codex does.** Matches the existing pattern exactly, but every fix has to be made five times. The Codex copies already differ in incidental ways, such as `AnimTeamLibrarian` vs `YHSoundTeamLibrarian` names. Rejected for drift.
3. **One plugin with a `-Team` switch.** Smallest code, but it breaks the "choose your team's librarian" model the README and the team installers use. A seat could also enroll in the wrong team. Rejected.

## Design

### Layout (per team, generated)

```text
Plugins/Claude/
  _template/                        # single source (placeholders)
  Build-ClaudeLibrarians.ps1        # stamps teams + zips; -Check verifies no drift
  tests/                            # Pester tests (parser, publisher, build)
  README.md                         # index of the five Claude librarians
  <team>-team-librarian/
    README.md                       # current release + link to install guide
    releases/<team>-team-librarian-0.1.0.zip
    marketplace/
      .claude-plugin/marketplace.json
      plugins/<team>-team-librarian/
        .claude-plugin/plugin.json
        README.md                   # install, enroll, status, disable
        hooks/hooks.json            # {"hooks":{}}
        skills/<team>-team-librarian/SKILL.md
        scripts/*.ps1
```

`marketplace.json` follows Claude Code's format. It has `name` (`<team>-team-tools`), `owner`, and a `plugins` entry with `"source": "./plugins/<team>-team-librarian"`. `plugin.json` has `name`, `version` (`0.1.0`), `description` and `author`. Skills and hooks are found in their default locations.

Install steps for the README:

```powershell
claude plugin marketplace add .
claude plugin install <team>-team-librarian@<team>-team-tools
```

The installed path is under `~/.claude/plugins/`. Enrollment is run from that path's `scripts` folder. If `claude plugin` can't report the installed path as JSON, the README gives a one-liner that finds it.

### Scripts

The files keep their Codex names wherever they are unchanged. Codex-specific files are replaced.

| Codex file | Claude version |
| --- | --- |
| `CodexSession.ps1` | **Removed.** Its email-folder validator moves to `ClaudeSession.ps1` as `Test-SeatEmailFolder` (renamed from `Test-CodexEmailFolder`). The app-server RPC code is gone. |
| `Collect-AnimTeamHistory.ps1` | **Rewritten** as `Collect-ClaudeTeamHistory.ps1`, with the same parameters and the same JSON result shape. See Collector. |
| `LibrarianChatImage.ps1` | Reduced to inline base64 images from `user` `image` blocks, keeping the same size, pixel, format and PNG-conversion rules and reason codes. Codex local-path and generated-image sources are dropped. |
| `TranscriptText.ps1` | Unchanged (credential masking). |
| `LibrarianState.ps1` | Unchanged apart from the state folder name, user agent and identity source. `Get-LibrarianIdentity` calls the collector with `-IdentityOnly`, as before. |
| `LibrarianEvening.ps1` | Destination becomes `Usage data/<team>/<email>/Claude`. `activeThreads`/`archivedThreads` become `sessions`, and the completeness check uses `documents == sessions`. |
| `Publish-AnimTeamSessionsCore.ps1` | Tool folder `Claude`. Commit subjects say "Claude". Author is `<Display name> (Claude)`, e.g. `Anim Team Librarian (Claude)`. It provisions `Codex/` and `Opencode/` `.gitkeep` if missing and deletes `Claude/.gitkeep` in the same commit as the first documents. **Legacy migration code is removed** (the `Codex usage data` path and `MigrationVerificationRequired`), because Claude has no legacy layout. The `layout.json` check stays. |
| `Configure-AnimLibrarian.ps1` | Error text says "Claude account". The Codex-bundled PowerShell lookup is removed. Adds the transcript-retention step below. |
| `LibrarianScheduledTask.ps1` | Task name `<Display name> (Claude) - <SID>`, source `<team>-team-tools/<team>-team-librarian-claude/<SID>`, and a description that mentions Claude Code. |
| `Sync-AnimTeamSessions.ps1`, `Publish-AnimTeamSessions.ps1` | Unchanged. |
| `Drain-AnimLibrarianQueue.ps1`, `Invoke-AnimLibrarianHook.ps1` | **Dropped.** They exist only for Codex 0.2 compatibility. |

**Isolation from the Codex librarian** (template placeholders):

- state folder `%LOCALAPPDATA%\YH<Team>ClaudeLibrarian\plugin-state`
- scheduled task name and source as in the table above
- C# type namespace `YH<Team>ClaudeLibrarian`
- user agent `<team>-team-librarian-claude`
- Git author name `<Display name> (Claude)`

### Collector (`Collect-ClaudeTeamHistory.ps1`)

- **Identity.** Read `~/.claude.json` with a shared-read open, so a concurrent Claude Code write doesn't fail it. Take `oauthAccount.emailAddress` (lower-cased, validated with `Test-SeatEmailFolder`) and `oauthAccount.accountUuid` as `userId`. It is checked at start, before writing, and at the end, as in Codex. A change means `UnauthorizedAccessException`, which is reported as `AccountChanged`.
- **Inventory.** Every `~/.claude/projects/*/*.jsonl` whose basename is a GUID. Subdirectories are not followed, so `subagents/` is skipped. Reparse points are skipped. `-SessionId` limits it to the listed sessions. `-InventoryOnly` returns counts only.
- **Per session.** Read the file with shared read/write access and parse line by line. A malformed line in any position is dropped and counted in a new result and receipt counter, `malformedLines`. It never fails the session. A transcript that is broken for good must not hold the seat's batch every evening, because Codex's `CollectionIncomplete` rule was meant for temporary RPC failures. Only an I/O failure fails a session (`failedSessions`, which leaves the batch due for retry), for example a file that is locked or vanishes mid-read.
- **Branches.** A transcript is a tree linked by `uuid` and `parentUuid`, and rewinds or edits leave abandoned branches. The export is the **active branch**: start from the last `user` or `assistant` record in the file and walk `parentUuid` back to the root, following `logicalParentUuid` across compaction boundaries. If the chain breaks, fall back to file order for the part that can't be linked. This is what the person sees when they resume the session. `messages` in the header counts the exported messages, and `updatedAt` is the active leaf's timestamp.
- Records:
  - `user` with neither `isMeta`, `isCompactSummary` nor `isSidechain` → **User**. String content, or the concatenated `text` blocks. `image` blocks become `[Image attachment]`, or a picture when `-IncludeImages` is set. `tool_result` blocks are dropped. A user record that ends up with no text and no image is skipped.
  - Text that is only Claude Code wrapper markup is skipped: `<command-name>`, `<command-message>`, `<command-args>`, `<local-command-stdout>`, `<local-command-stderr>`, `<bash-input>`, `<bash-stdout>`, `<bash-stderr>` and `<system-reminder>` blocks. `<system-reminder>` blocks embedded in otherwise real text are removed.
  - A slash command is rendered as `[Command /name]`, without its output.
  - `assistant` without `isApiErrorMessage` or `isSidechain` → **Assistant**. Only the `text` blocks are kept. Records with the same `message.id` (Claude Code splits one reply across records) are merged in order.
  - Everything else is ignored.
- **Document format.** Same as Codex: an `<!-- <team>-team-librarian {"schema":1,"updatedAt":…,"messages":…} -->` header, then the title, `Session ID`, `Created (UTC)` (first record timestamp) and `Updated (UTC)` (last record timestamp). There is no Status line. Each message is `## User|Assistant (sent <ISO>)` with a four-space indented body masked by `Protect-LibrarianTranscriptText`. Pictures are `images/<session-id>/<sha256>.png`, referenced in place.
- **Result JSON.** Codex's shape, with `sessions` replacing `activeThreads`/`archivedThreads`: `email`, `userId`, `sessions`, `documents`, `skipped`, `failures`, `missing`, `failedSessions`, `lastFailure`, plus the image counters.

### Stable script location

Claude Code keeps installed plugins in a cache folder per version and removes old versions after an update or uninstall. A scheduled task pointing at that folder would stop silently after an upgrade. So `-EnableAccountSync` copies the plugin's `scripts/` into `%LOCALAPPDATA%\YH<Team>ClaudeLibrarian\app\<version>\` and points the task at the copy there. Re-enrolling after an upgrade replaces the copy and removes older copies. `-Status` reports `scheduledTask.entryScriptExists`, and reports `ScriptMissing` if the copy is gone. `-DisableAccountSync` removes the task and the copy.

### Transcript retention

`Configure-…Librarian.ps1 -EnableAccountSync` reads `~/.claude/settings.json`. If `cleanupPeriodDays` is unset or under 3650, it sets it to 3650, keeping every other key and writing atomically. The status output reports `transcriptRetentionDays`. `-KeepTranscriptRetention` skips the change for people who don't want it. `-DisableAccountSync` does not revert it.

### Concurrency with Codex

Both tasks run at 22:00 by default and may push to `main` at the same moment. The publisher's existing loop (fetch, rebuild the tree on the new base, push, retry on failure) already handles a non-fast-forward. The two write disjoint paths (`Codex/` vs `Claude/`). Both may try to add the missing `Opencode/.gitkeep`. The second one sees it already exists after refetching and skips it.

### Docs

- Root `README.md`: add a "Claude Code plugin" table next to the Codex one.
- `Usage data/README.md`: say that `Claude/` is filled by the Claude librarian, and add a workstation-setup line.
- `Plugins/Claude/README.md`: an index of the five plugins.
- Each generated plugin README is adapted from the Codex one: prerequisites (a signed-in Claude Code team seat, Git with write access to `main`, PowerShell 7.2+), install, enroll, status table, retry and disable.
- The skill text mirrors the Codex skill: count, enroll, status, retry and disable through the scripts. Conversation text stays out of status reports.

### Testing

Pester 5 tests in `Plugins/Claude/tests/`:

- **Parser fixtures.** Small synthetic `.jsonl` files, never real transcripts, covering:
  - plain and block content
  - tool use and tool results being dropped
  - thinking being dropped
  - meta and compact-summary records
  - wrapper-only messages and embedded system reminders
  - split assistant replies
  - titles
  - a partial last line
  - images: a valid PNG, an oversize image and an unsupported format
  - credential masking
  - a mid-file malformed line
- **Identity.** A fixture `.claude.json` with missing or changed accounts. The collector takes a test-only `-ProfileRoot` parameter (the folder that holds `.claude.json` and `.claude`).
- **Publisher.** Against a temporary bare repo through `file:///`:
  - first publish deletes `Claude/.gitkeep` and provisions the sibling folders
  - unchanged rerun gives `NoChanges`
  - a concurrent commit on `main` is retried
  - a missing `layout.json` gives `UsageLayoutNotActive`
- **Build.** `Build-ClaudeLibrarians.ps1 -Check` passes on committed output and fails after a hand edit of a generated file.
- **Manual acceptance on one workstation.** Install the anim plugin, `-InventoryOnly`, enroll against a throwaway `file:///` remote copy of the repo, then `-Status`, then disable. This needs a temporary override that is not shipped, such as an environment variable read only by tests. A real push to GitHub is done once, by the maintainer, after review.

## Left to the builder

- Exact placeholder syntax and the build script internals.
- How to locate the installed plugin path for the README one-liner, after checking `claude plugin` output on a current Claude Code.
- Internal function names, as long as the user-facing script names and switches in this document hold.

## Calls made without explicit sign-off (review these)

- Version 0.1.0 for the Claude plugins.
- Template plus build script rather than hand copies.
- Only the default `~/.claude` location is supported, so `CLAUDE_CONFIG_DIR` is not.
- No Status line in documents.
- Enrollment raises `cleanupPeriodDays` to 3650 by default, with an opt-out switch.
- Legacy-migration code is removed from the Claude publisher.
- Codex 0.2 compatibility shims are dropped.
- Malformed transcript lines are dropped and counted, and never hold the batch.
- Branched transcripts export the active branch only.
- Enrollment copies the scripts to a stable `%LOCALAPPDATA%` folder for the scheduled task.
