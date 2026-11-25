# Claude Team Librarians Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship five Claude Code "team librarian" plugins under `Plugins/Claude/`. They back up each enrolled seat's Claude Code sessions every evening to `Usage data/<team>/<seat-email>/Claude/`, the same way the Codex librarians do for `Codex/`.

**Architecture:** One plugin template (`Plugins/Claude/_template/`) holds the PowerShell scripts, manifests and docs with placeholders. `Build-ClaudeLibrarians.ps1` stamps the five team plugins and their release zips, and the generated output is committed. The scheduler, receipts, masking and Git publisher are ported from Codex 0.5.0. The Codex app-server collector is replaced with a reader for `~/.claude/projects/*/<session>.jsonl` that exports the active branch.

**Tech Stack:** PowerShell 7.2+, Pester 5, Git for Windows, Windows Task Scheduler, Claude Code plugin format (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`).

**Spec:** `docs/superpowers/specs/2026-11-25-claude-librarians-design.md`

## Global Constraints

- **Teams.** The template placeholders take these values, exactly:

  | `{{TEAM_SLUG}}` | `{{DISPLAY_NAME}}` | `{{TEAM_FOLDER}}` | `{{TEAM_ID}}` | `{{MEMBER_PHRASE}}` |
  | --- | --- | --- | --- | --- |
  | `anim` | `Anim Team Librarian` | `Animators team` | `YHAnimTeam` | `an animator` |
  | `3d-art` | `3D Art Team Librarian` | `3D art team` | `YH3DArtTeam` | `a member of the 3D art team` |
  | `character-art` | `Character Art Team Librarian` | `Character art team` | `YHCharacterArtTeam` | `a member of the Character art team` |
  | `directors` | `Directors Team Librarian` | `Directors team` | `YHDirectorsTeam` | `a member of the Directors team` |
  | `sound` | `Sound Team Librarian` | `Sound team` | `YHSoundTeam` | `a member of the Sound team` |

- **Derived placeholders:**
  - `{{PLUGIN_NAME}}` = `<slug>-team-librarian`
  - `{{MARKETPLACE}}` = `<slug>-team-tools`
  - `{{VERSION}}` = `0.1.0`
- **Repository and branch:** `https://github.com/YHAnimationStudios/YH_Knowledge_database.git`, branch `main`.
- **Destination:** `Usage data/{{TEAM_FOLDER}}/<lower-case email>/Claude/<session-uuid>.md`. Pictures go in `Claude/images/<session-uuid>/<sha256>.png`.
- **Isolation from Codex:**
  - state root `%LOCALAPPDATA%\{{TEAM_ID}}ClaudeLibrarian\`, with `plugin-state\` and `app\<version>\` under it
  - task name `{{DISPLAY_NAME}} (Claude) - <SID>`
  - task source `{{MARKETPLACE}}/{{PLUGIN_NAME}}-claude/<SID>`
  - C# namespace `{{TEAM_ID}}ClaudeLibrarian`
  - user agent `{{PLUGIN_NAME}}-claude`
  - Git author `{{DISPLAY_NAME}} (Claude)`
- **Commit subjects:** `Publish evening Claude sessions for <yyyy-MM-dd>` when dated, otherwise `Update Claude session documents`.
- **Schedule:** 22:00 local time by default. Catch-up runs at sign-in and every 30 minutes. `-EveningTime HH:mm` overrides it.
- **Enrollment:** raises `cleanupPeriodDays` in `~/.claude/settings.json` to at least `3650` unless `-KeepTranscriptRetention` is given.
- **Pushes are allowed only when:**
  - unauthenticated `GET https://api.github.com/repos/YHAnimationStudios/YH_Knowledge_database` returns 404
  - `Usage data/layout.json` is `{"version":2}`
- **Exported content:** only user and assistant text and user-pasted images, all text passed through `Protect-LibrarianTranscriptText`. Never tool use or results, thinking, system records, or hook and command output.
- **Shipped scripts read only the real locations:** `%USERPROFILE%\.claude.json` and `%USERPROFILE%\.claude\`. The `-ProfileRoot` parameter is the test seam. No environment-variable overrides ship.
- **Generated folders are build output** (`Plugins/Claude/<slug>-team-librarian/`). Edit `_template/` only. `Build-ClaudeLibrarians.ps1 -Check` must pass before every commit that touches `Plugins/Claude/`.
- **Tests never use real transcripts.** Fixtures are synthetic.

## Review Focus

These are inputs the spec implies but no task's main tests reach. Each one is pinned by a test in the task named.

1. **A huge transcript** (hundreds of MB, from long agentic sessions). The collector streams it line by line and memory stays flat. Pinned in Task 4 with `It 'streams a 60000-line transcript'`.
2. **Claude Code rewriting `~/.claude.json` mid-read** (a partial or locked file). Identity retries 3 times, 500 ms apart, then fails as `AccountVerificationFailed`. Nothing is pushed. Pinned in Task 2 with `It 'retries a transiently unreadable config'`.
3. **A new workstation with no `~/.claude/projects` folder**, or an empty one. The result is 0 sessions and the evening completes as `NoChanges`, not as a failure. Pinned in Task 5 with `It 'treats a missing projects folder as zero sessions'`.
4. **A session with no visible messages** (only tool activity, or only `/clear`). A document is still written with its header and no messages, so `documents == sessions` holds. Pinned in Task 5 with `It 'writes a header-only document for a session without visible messages'`.
5. **Signed out, or switched to another account between enrollment and the evening run.** Nothing is pushed, and the attempt is recorded as `AccountChanged`. Pinned in Task 7 with `It 'holds the batch when the signed-in account changed'`.

---

### Task 0: Developer prerequisites

This machine has Windows PowerShell 5.1 and Pester 3.4 only. Pester 5 and PowerShell 7 are not installed yet. **Ask the user before installing anything.**

- [ ] **Step 1: Ask the user to approve installing PowerShell 7 and Pester 5**, then run:

```powershell
winget install --id Microsoft.PowerShell --source winget
pwsh -NoProfile -Command "Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck"
```

- [ ] **Step 2: Verify the installs.** Run `pwsh -NoProfile -Command "$PSVersionTable.PSVersion; (Get-Module -ListAvailable Pester | Sort Version -Desc)[0].Version"`. Expected: `7.x` and `5.5` or higher.

---

### Task 1: Template skeleton, build script and test harness

**Files:**
- Create: `Plugins/Claude/Build-ClaudeLibrarians.ps1`
- Create: `Plugins/Claude/_template/marketplace/.claude-plugin/marketplace.json`
- Create: `Plugins/Claude/_template/marketplace/plugins/{{PLUGIN_NAME}}/.claude-plugin/plugin.json`
- Create: `Plugins/Claude/_template/marketplace/plugins/{{PLUGIN_NAME}}/hooks/hooks.json` (`{"hooks":{}}`)
- Create: `Plugins/Claude/_template/marketplace/plugins/{{PLUGIN_NAME}}/scripts/TranscriptText.ps1` (copied verbatim from `Plugins/Codex/anim-team-librarian/marketplace/plugins/anim-team-librarian/scripts/`)
- Create: `Plugins/Claude/tests/TestHelpers.ps1`
- Create: `Plugins/Claude/tests/Invoke-ClaudeLibrarianTests.ps1`
- Test: `Plugins/Claude/tests/Build.Tests.ps1`

**Interfaces:**
- Produces: `Build-ClaudeLibrarians.ps1 [-OutputRoot <string>] [-Team <string[]>] [-Check] [-NoZip]`.
  - `-OutputRoot` defaults to `Plugins/Claude`.
  - `-Team` defaults to all five slugs.
  - `-Check` renders into a temp folder and compares it byte for byte with `-OutputRoot`, ignoring `releases/`. It exits 1 and lists the differing paths on drift.
  - Placeholders are replaced in file contents and in path segments.
  - Files are written as UTF-8 without BOM, with LF line endings preserved.
  - A placeholder left over in the output is a build error.
- Produces: in `TestHelpers.ps1`, `New-LibrarianTestPlugin([string]$Team='anim') -> string`. It builds one team into `TestDrive:` with `-NoZip` and returns the rendered `scripts` folder path.
- Produces: `Invoke-ClaudeLibrarianTests.ps1`, which runs every `Plugins/Claude/tests/*.Tests.ps1` with Pester 5 and exits non-zero on failure.

`marketplace.json` content:

```json
{
  "name": "{{MARKETPLACE}}",
  "owner": { "name": "YH Animation Studios" },
  "plugins": [
    { "name": "{{PLUGIN_NAME}}", "source": "./plugins/{{PLUGIN_NAME}}",
      "description": "Evening Claude Code session backup for the {{TEAM_FOLDER}}.", "version": "{{VERSION}}" }
  ]
}
```

`plugin.json` has `name`, `version`, `description`, and `author: {"name":"YH Animation Studios"}`. The description is: `Back up an enrolled seat's Claude Code sessions and optional pictures to the team GitHub repository every evening.`

- [ ] **Step 1: Write the failing tests** in `Build.Tests.ps1`:
  - `It 'renders all five teams with no leftover placeholders'`: build into `TestDrive:` and assert five `*-team-librarian` folders exist. Assert that no file content or path under them matches `\{\{[A-Z_]+\}\}`.
  - `It 'substitutes team values'`: assert `sound-team-librarian/marketplace/.claude-plugin/marketplace.json` parses with `.name -eq 'sound-team-tools'` and `.plugins[0].source -eq './plugins/sound-team-librarian'`.
  - `It 'passes -Check on fresh output and fails after a hand edit'`: build, then `-Check` gives exit 0. Append a byte to a rendered `hooks.json`, then `-Check` gives exit 1, and the output names that path.
  - `It 'zips each team release'`: build without `-NoZip` and assert `releases/anim-team-librarian-0.1.0.zip` exists. Assert it contains `.claude-plugin/marketplace.json` and `plugins/anim-team-librarian/.claude-plugin/plugin.json` at its root.
- [ ] **Step 2: Run** `pwsh -File Plugins/Claude/tests/Invoke-ClaudeLibrarianTests.ps1`. Expected: FAIL because the build script is missing.
- [ ] **Step 3: Implement** `Build-ClaudeLibrarians.ps1` and the template files listed above.
  - The team table is a literal array in the script, using the Global Constraints values.
  - Zip with `System.IO.Compression.ZipFile`, with the `marketplace/` contents at the archive root, matching the Codex release zips.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.**

```powershell
git add Plugins/Claude docs/superpowers
git commit -m "Add Claude librarian template, build script and test harness"
```

---

### Task 2: Seat identity (`ClaudeSession.ps1`)

**Files:**
- Create: `Plugins/Claude/_template/marketplace/plugins/{{PLUGIN_NAME}}/scripts/ClaudeSession.ps1`
- Test: `Plugins/Claude/tests/ClaudeSession.Tests.ps1`

**Interfaces:**
- Produces: `Test-SeatEmailFolder([string]$Email) -> bool`. This is Codex's `Test-CodexEmailFolder` body, renamed.
- Produces: `Get-ClaudePaths([string]$ProfileRoot) -> hashtable` with keys:
  - `Config` = `<root>\.claude.json`
  - `Projects` = `<root>\.claude\projects`
  - `Settings` = `<root>\.claude\settings.json`

  An empty `$ProfileRoot` means `[Environment]::GetFolderPath('UserProfile')`.
- Produces: `Read-ClaudeIdentity([string]$ConfigPath) -> @{email=<lower-case>; userId=<accountUuid>}`. It opens the file with `FileShare.ReadWrite|Delete` and makes 3 attempts 500 ms apart on `IOException` or a JSON parse error. It throws `UnauthorizedAccessException` if `oauthAccount` is missing, the email fails `Test-SeatEmailFolder`, or the `accountUuid` is empty or contains whitespace or control characters.

- [ ] **Step 1: Write the failing tests:**
  - `It 'reads email and account id'`: the fixture has `{"oauthAccount":{"emailAddress":"Seat.One@Studio.org","accountUuid":"0b7e…"}}`. Expect `email -ceq 'seat.one@studio.org'` and the matching `userId`.
  - `It 'rejects a signed-out config'`: `{}` throws `UnauthorizedAccessException`.
  - `It 'rejects an invalid email folder name'`: `emailAddress` `"a/b@x.org"` throws `UnauthorizedAccessException`.
  - `It 'retries a transiently unreadable config'` (Review Focus 2): write `{"oauthAcc` first, start a background job that writes valid JSON after 300 ms, and expect success. A file that stays truncated throws after about 1 s.
  - `It 'resolves paths under a profile root'`: check all three keys.
- [ ] **Step 2: Run the tests.** Expected: FAIL because the file is missing.
- [ ] **Step 3: Implement** `ClaudeSession.ps1` with the three functions.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** (`Add Claude seat identity reader`). Run `Build-ClaudeLibrarians.ps1` first so the generated folders match.

---

### Task 3: Transcript parser (`ClaudeTranscript.ps1`)

**Files:**
- Create: `Plugins/Claude/_template/marketplace/plugins/{{PLUGIN_NAME}}/scripts/ClaudeTranscript.ps1`
- Create: `Plugins/Claude/tests/fixtures/transcripts/*.jsonl` (synthetic)
- Test: `Plugins/Claude/tests/ClaudeTranscript.Tests.ps1`

**Interfaces:**
- Produces: `Read-ClaudeTranscriptRecords([string]$Path) -> @{records=[Collections.Generic.List[hashtable]]; malformedLines=[int]}`.
  - It streams with `StreamReader` over a `FileShare.ReadWrite|Delete` open and keeps only records whose `type` is `user`, `assistant`, `custom-title`, `ai-title` or `summary`.
  - Each record is parsed with `ConvertFrom-Json -AsHashtable -Depth 128` and `DateKind String` where available.
  - A malformed line in any position is counted and skipped.
  - An I/O exception propagates.
- Produces: `Get-ClaudeSessionTitle($Records) -> string or $null`: the last `customTitle`, else the last `aiTitle`.
- Produces: `Select-ClaudeActiveBranch($Records) -> List[hashtable]`. It returns the root-to-leaf list of `user` and `assistant` records. See the algorithm below.
- Produces: `ConvertTo-ClaudeMessages($Branch) -> List[hashtable]`. Each item is `@{id=<uuid of first record>; role='User'|'Assistant'; time=[datetimeoffset]; parts=List}`. Each part is one of:
  - `@{type='text'; text=<string>}`
  - `@{type='image'; block=<image block hashtable>; ordinal=<int>}`
  - `@{type='command'; name='/x'}`

Active-branch algorithm. The signature doesn't determine it, so here it is:

```text
index user/assistant records by uuid (later duplicate uuid wins)
leaf := last user/assistant record in file order that is not isSidechain
walk: cur := leaf; while cur: prepend cur; next := byUuid[cur.parentUuid] ?? byUuid[cur.logicalParentUuid]; stop on missing id or a uuid already visited
if the walk stopped on a missing parent id that is not null, prepend, in file order, every earlier non-sidechain user/assistant record not yet on the branch (broken-chain fallback)
```

Message rules for `ConvertTo-ClaudeMessages`:
- **Skip** a record if it has `isMeta`, `isCompactSummary`, `isSidechain` or `isApiErrorMessage`.
- **`user` records:**
  - Content is a string, or `text` blocks joined with `"`n"`.
  - `image` blocks become image parts, in order.
  - `tool_result` blocks are dropped.
  - Remove `<system-reminder>…</system-reminder>` spans.
  - If the remaining text has a `<command-name>/x</command-name>`, the record becomes a single command part `/x`.
  - If the remaining text consists only of `<command-message>`, `<command-args>`, `<local-command-stdout>`, `<local-command-stderr>`, `<bash-input>`, `<bash-stdout>` or `<bash-stderr>` elements and whitespace, drop the record.
  - Drop a record left with no parts.
- **`assistant` records:**
  - Keep only `text` blocks.
  - Consecutive records with the same `message.id` merge into one message.
  - Drop a message with no text.
- `time` comes from the record `timestamp` (ISO-8601, UTC).

- [ ] **Step 1: Write fixtures and failing tests.** Each test names its fixture:
  - `It 'exports plain user and assistant text'` (`basic.jsonl`): 2 messages, roles `User` then `Assistant`, exact text.
  - `It 'drops tool use, tool results and thinking'` (`tools.jsonl`): an assistant message with `thinking`, `text` "Done." and `tool_use` exports one Assistant message with text `Done.`. A user record holding only a `tool_result` exports nothing.
  - `It 'drops meta, compact summary and api error records'` (`meta.jsonl`).
  - `It 'removes system reminders and renders slash commands'` (`commands.jsonl`):
    - `"<command-name>/compact</command-name><command-message>compact</command-message>"` gives a command part `/compact`.
    - `"<local-command-stdout>ok</local-command-stdout>"` is dropped.
    - `"fix it<system-reminder>x</system-reminder>"` gives the text `fix it`.
  - `It 'merges an assistant reply split across records'` (`split.jsonl`): two records with `message.id` `msg_1` and texts `A` and `B` give one message with parts `A` and `B`.
  - `It 'exports only the active branch after a rewind'` (`rewind.jsonl`): root U1 to A1, then U2a to A2a (abandoned), then U2b to A2b, where U2b's parent is A1. The result is U1, A1, U2b, A2b.
  - `It 'follows logicalParentUuid across compaction'` (`compact.jsonl`).
  - `It 'falls back to file order on a broken chain'` (`broken.jsonl`): a parent id not in the file prepends the earlier records.
  - `It 'counts and skips malformed lines anywhere'` (`malformed.jsonl`): one bad line in the middle and one truncated last line give `malformedLines -eq 2` and the remaining messages intact.
  - `It 'prefers custom title over ai title'` (`titles.jsonl`).
  - `It 'keeps image blocks as ordered image parts'` (`image.jsonl`).
  - `It 'streams a 60000-line transcript'` (Review Focus 1): generate it in `TestDrive:`. Assert it finishes in under 60 s and the process working set grows less than 200 MB.
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement** the four functions.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Build and commit** (`Add Claude transcript parser`).

---

### Task 4: Pictures (`LibrarianChatImage.ps1`)

**Files:**
- Create: `Plugins/Claude/_template/marketplace/plugins/{{PLUGIN_NAME}}/scripts/LibrarianChatImage.ps1`, ported from the Codex file. Keep `$imageByteLimit=25MB`, `$imagePixelLimit=24000000`, `Get-LibrarianImageHash`, `Get-LibrarianRasterFormat`, `ConvertTo-LibrarianRaster` (namespace `{{TEAM_ID}}ClaudeLibrarian`), `Remove-LibrarianSessionImages`, and the reason codes. Delete `Read-LibrarianLocalImage` and the generated-image paths.
- Test: `Plugins/Claude/tests/LibrarianChatImage.Tests.ps1`

**Interfaces:**
- Produces: `Add-LibrarianImageReference([hashtable]$Block, [string]$MessageId, [int]$Ordinal, $State)`.
  - `$Block` is a Claude `image` block (`source.type`, `source.media_type`, `source.data`).
  - `$State` has keys `id`, `body` (StringBuilder), `assets` (HashSet), `reasons` (hashtable), `available` (int) and `imageRoot` (string).
  - On success it writes `<imageRoot>/<session-id>/<sha256>.png` once per session and appends `![Image attachment](images/<session-id>/<sha256>.png)` plus a blank line to `body`.
  - On failure it appends `[Image attachment unavailable: <reason>]` and increments `reasons[<reason>]`.
  - A `source.type` other than `base64` gives the reason `remoteReference`.
  - A `media_type` outside `image/png|jpeg|gif|webp` gives `unsupportedFormat`.

- [ ] **Step 1: Write the failing tests:**
  - `It 'writes a PNG once per session for repeated images'`: the same 1×1 PNG block twice gives 1 file, 2 references and `available -eq 2`.
  - `It 'marks an oversize image unavailable'`: base64 decoding to more than 25 MB gives the reason `sizeLimit` and no file.
  - `It 'marks a url source unavailable'`: `remoteReference`.
  - `It 'marks an unsupported media type unavailable'`: `image/svg+xml` gives `unsupportedFormat`.
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Build and commit** (`Add Claude picture export`).

---

### Task 5: Collector (`Collect-ClaudeTeamHistory.ps1`)

**Files:**
- Create: `Plugins/Claude/_template/marketplace/plugins/{{PLUGIN_NAME}}/scripts/Collect-ClaudeTeamHistory.ps1`
- Create: `Plugins/Claude/_template/marketplace/plugins/{{PLUGIN_NAME}}/scripts/LibrarianState.ps1`, ported from Codex. Change these:
  - state folder `{{TEAM_ID}}ClaudeLibrarian\plugin-state`
  - user agent `{{PLUGIN_NAME}}-claude`
  - `Get-LibrarianIdentity` calls `Collect-ClaudeTeamHistory.ps1 -IdentityOnly`
  - error text `A signed-in Claude account is required.`
- Test: `Plugins/Claude/tests/Collector.Tests.ps1`

**Interfaces:**
- Consumes: Tasks 2 to 4.
- Produces: `Collect-ClaudeTeamHistory.ps1 [-OutputDirectory <string>] [-SessionId <string[]>] [-ExpectedEmail <string>] [-PinnedUserId <string>] [-IdentityOnly] [-InventoryOnly] [-IncludeImages] [-ProfileRoot <string>]`.
  - It writes one compressed JSON line: `{email,userId,sessions,documents,skipped,failures,malformedLines,missing,failedSessions,lastFailure}`. With `-IncludeImages` it adds `imageReferences,imagesAvailable,imagesUnavailable,imageFiles,imageUnavailableReasons`.
  - Identity is checked at start, before each document write, and at the end. A mismatch with `-ExpectedEmail` or `-PinnedUserId`, or a change mid-run, throws `UnauthorizedAccessException`.
  - On a thrown failure, all written files are deleted. Codex's `Get-StageDirectory` and atomic `Write-SessionDocument` are kept.
- Inventory:
  - `Projects\*\*.jsonl` whose basename parses as a non-empty GUID in `D` format. Others count as `skipped`.
  - It doesn't recurse, so `subagents\` is excluded.
  - Project folders or files that are reparse points are skipped.
  - A missing `Projects` folder means 0 sessions.
- Document format: Codex's exact layout with these changes:
  - header comment `<!-- {{PLUGIN_NAME}} {"schema":1,"updatedAt":<unix s of active leaf>,"messages":<n>} -->`
  - title escaped as in Codex, defaulting to `Claude Code session`
  - `Session ID`, `Created (UTC)` (first record), `Updated (UTC)` (leaf), with no Status line
  - messages as `## User|Assistant (sent <ISO>)` with four-space-indented masked text
  - command parts render as `[Command /x]`
  - image parts go through `Add-LibrarianImageReference` when `-IncludeImages` is set, and otherwise become `[Image attachment]`

- [ ] **Step 1: Write the failing tests.** Use a `TestDrive:` profile root holding `.claude.json` and `.claude/projects/p1/` with fixtures from Task 3 renamed to GUIDs.
  - `It 'returns identity only'`: `-IdentityOnly` gives the email and userId with `sessions -eq 0`.
  - `It 'counts sessions in inventory mode and skips subagents and non-guid files'`: 2 GUID files, `p1/<guid>/subagents/x.jsonl` and `notes.jsonl` give `sessions -eq 2` and `skipped -eq 1`.
  - `It 'writes one masked document per session'`: a fixture containing `ghp_` followed by 30 characters shows `[REDACTED]` in the output. Assert the document begins with `<!-- anim-team-librarian {"schema":1,` and contains `## User (sent `.
  - `It 'treats a missing projects folder as zero sessions'` (Review Focus 3).
  - `It 'writes a header-only document for a session without visible messages'` (Review Focus 4): a tools-only fixture gives a document with `"messages":0`, and `documents -eq sessions`.
  - `It 'reports malformed lines without failing the session'`: `malformedLines -eq 2` and `failures -eq 0`.
  - `It 'fails and cleans up when the account changes mid-run'`: a `Mock Read-ClaudeIdentity` returns a different `userId` on the 3rd call. Expect a throw and an empty output folder.
  - `It 'writes pictures with -IncludeImages'`: the `image.jsonl` fixture gives `images/<guid>/<sha>.png` and `imageFiles -eq 1`.
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement** the collector and `LibrarianState.ps1`.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Build and commit** (`Add Claude session collector`).

---

### Task 6: Publisher

**Files:**
- Create: `…/scripts/Publish-AnimTeamSessionsCore.ps1`, ported from Codex. Change these:
  - dot-source `ClaudeSession.ps1`, not `CodexSession.ps1`, and call `Test-SeatEmailFolder`
  - `$team='{{TEAM_FOLDER}}'` and `$folder="$seatFolder/Claude"`
  - the Global Constraints commit subjects and author
  - provision `Codex` and `Opencode` `.gitkeep` files when missing
  - in a commit that adds at least one document, delete `$seatFolder/Claude/.gitkeep` if present
  - **remove** `$legacyFolder`, `Test-AnimTeamLegacyContents`, `Assert-AnimTeamMigratedRecord`, `-VerifyRecordedPublication` and every `MigrationVerificationRequired` path
  - keep `Assert-AnimTeamLayout` and `UsageLayoutNotActive`
- Create: `…/scripts/Publish-AnimTeamSessions.ps1`, ported from Codex without `-VerifyRecordedPublication`.
- Test: `Plugins/Claude/tests/Publisher.Tests.ps1`

**Interfaces:**
- Produces: `Publish-AnimTeamSessionDocuments -DocumentDirectory -Email -StateDirectory -RemoteUrl [-RequireCompleteBatch] [-IncludeImages] [-BatchDate] [-ReceiptDirectory]`. It returns the Codex report shape with `layoutVersion=2`, `destination='Usage data/{{TEAM_FOLDER}}/<email>/Claude'`, and `provisionedTools` between 0 and 2.

- [ ] **Step 1: Write the failing tests.**
  - Setup: create a bare repo in `TestDrive:` seeded with `Usage data/layout.json` = `{"version":2}` and `Usage data/Animators team/seat@x.org/Claude/.gitkeep`.
  - In every test, `Mock Get-LibrarianRepositoryHttpStatus { 404 }` and use the remote `file:///…`.
  - `It 'publishes documents, removes Claude .gitkeep and provisions sibling folders'`: one commit, the tree contains `Claude/<guid>.md`, `Codex/.gitkeep` and `Opencode/.gitkeep`, and no `Claude/.gitkeep`. The commit subject is `Publish evening Claude sessions for 2026-11-25` and the author is `Anim Team Librarian (Claude)`.
  - `It 'reports NoChanges on an identical rerun'`: `pushed -eq 0` and `commit -eq $null`.
  - `It 'rebases onto a concurrent commit and pushes'`: between fetch and push, add a commit under `Codex/` through a hook or a second clone. The final head contains both.
  - `It 'refuses without layout.json'`: throws with `Data['reason'] -eq 'UsageLayoutNotActive'`.
  - `It 'refuses when the repository looks public'`: the mock returns 200, so it throws and nothing is pushed.
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement** the port.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Build and commit** (`Add Claude session publisher`).

---

### Task 7: Evening batch and sync

**Files:**
- Create: `…/scripts/LibrarianEvening.ps1`, ported from Codex. Change these:
  - `$destination="Usage data/{{TEAM_FOLDER}}/$($Config.email)/Claude"`
  - the counters become `sessions,documents,skipped,failures,malformedLines`, in both the attempt and the receipt
  - completeness is `failures==0 && failedSessions.Count==0 && missing.Count==0 && documents==sessions`
  - call `Collect-ClaudeTeamHistory.ps1`
  - remove `$verifyLegacy` and the old-layout recovery branch
- Create: `…/scripts/Sync-AnimTeamSessions.ps1`, ported from Codex. Remove the "old-layout candidate" recovery loop and keep the rest.
- Test: `Plugins/Claude/tests/Evening.Tests.ps1`

**Interfaces:**
- Consumes: Task 5 (collector JSON) and Task 6 (report).
- Produces: `Invoke-LibrarianEvening($Config,[string]$Directory,[string]$Seat,$Status) -> bool`, and receipts `evening-completed.json` and `evening-attempt.json` with the counters above.

- [ ] **Step 1: Write the failing tests.**
  - Setup: render the plugin with `New-LibrarianTestPlugin`. Overwrite the rendered `Publish-AnimTeamSessions.ps1` with a test copy that passes the Task 6 `file:///` remote. That is the only test seam for the remote, and nothing extra ships. Point the collector at the `TestDrive:` profile with `Mock Get-ClaudePaths`.
  - Mock `Get-LibrarianRepositoryHttpStatus { 404 }` and `Get-LibrarianLocalNow` (22:05 local).
  - `It 'completes a due evening with a commit'`: the receipt has `status -eq 'Completed'`, `outcome -eq 'Changed'`, and `commit` matching a 40-hex SHA.
  - `It 'records NoChanges on the next evening without edits'`.
  - `It 'holds the batch when the signed-in account changed'` (Review Focus 5): the config `userId` differs from the fixture. The attempt has `reason -eq 'AccountChanged'` and the remote head is unchanged.
  - `It 'completes despite malformed lines'`: the receipt has `malformedLines -eq 2` and `status -eq 'Completed'`.
  - `It 'collapses missed evenings into one batch'`: the last completed evening was 3 days ago, so there is one commit and the receipt has the latest date.
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Build and commit** (`Add Claude evening batch`).

---

### Task 8: Enrollment, stable script copy, retention and scheduled task

**Files:**
- Create: `…/scripts/ClaudeSettings.ps1`
- Create: `…/scripts/LibrarianInstall.ps1`
- Create: `…/scripts/LibrarianScheduledTask.ps1`, ported from Codex. Use the Global Constraints task name, source, author and description `Backs up the enrolled seat's Claude Code sessions to the {{TEAM_FOLDER}} folder.`, and principal id `TeamMember`. `Get-LibrarianScheduledTaskInfo` adds `entryScriptExists`.
- Create: `…/scripts/Configure-AnimLibrarian.ps1`, ported from Codex. Change these:
  - remove the `codex-runtimes` PowerShell candidate
  - "Codex account" becomes "Claude account" in messages
  - add `[Parameter(ParameterSetName='Enable')][switch]$KeepTranscriptRetention`
  - on enable, call `Install-LibrarianAppCopy` and register the task against the returned entry script
  - unless `-KeepTranscriptRetention` is given, call `Set-ClaudeTranscriptRetention`
  - status adds `transcriptRetentionDays`, and sets `status='ScriptMissing'` when an enrolled seat's task entry script is missing
  - disable also calls `Remove-LibrarianAppCopies -KeepVersion $null`
- Test: `Plugins/Claude/tests/Enrollment.Tests.ps1`

**Interfaces:**
- Produces: `Get-ClaudeTranscriptRetention([string]$SettingsPath) -> int`. It returns 30 when the file or key is absent.
- Produces: `Set-ClaudeTranscriptRetention([string]$SettingsPath,[int]$MinimumDays=3650) -> @{before=[int];after=[int];changed=[bool]}`. It preserves every other key and its order, writes through a temp file and rename, and creates the file if absent. An existing value of 3650 or more is left as-is.
- Produces: `Install-LibrarianAppCopy([string]$SourceScripts,[string]$StateRoot,[string]$Version) -> string`.
  - It copies `*.ps1` to `<StateRoot>\app\<Version>\` with a private ACL via `New-LibrarianPrivateDirectory`.
  - It returns the full path of the copied `Sync-AnimTeamSessions.ps1`.
  - It then calls `Remove-LibrarianAppCopies $StateRoot $Version`.
- Produces: `Remove-LibrarianAppCopies([string]$StateRoot,[string]$KeepVersion)`. It deletes `app\*` except `$KeepVersion`, or everything when that is `$null`.
- `$StateRoot` is the parent of `Get-LibrarianStateDirectory`.

- [ ] **Step 1: Write the failing tests:**
  - `It 'raises an unset retention to 3650 and keeps other keys'`: `{"model":"opus","permissions":{"allow":["x"]}}` keeps both keys and adds `cleanupPeriodDays: 3650`.
  - `It 'leaves a higher retention alone'`: 5000 stays 5000 and `changed -eq $false`.
  - `It 'creates settings.json when absent'`.
  - `It 'copies scripts to a versioned app folder and prunes older versions'`: install 0.1.0, then 0.1.1. Only `app\0.1.1` remains, and the returned path ends `app\0.1.1\Sync-AnimTeamSessions.ps1`.
  - `It 'reports ScriptMissing when the entry script is gone'`: `Mock Get-LibrarianScheduledTaskInfo` returns `entryScriptExists=$false`. `Configure-AnimLibrarian.ps1 -Status` returns `status -eq 'ScriptMissing'`.
  - `It 'skips retention with -KeepTranscriptRetention'`: mock `Register-LibrarianScheduledTask`, `Get-LibrarianIdentity` and the sync call. `settings.json` is unchanged.
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Build and commit** (`Add Claude librarian enrollment`).

---

### Task 9: Skill, plugin docs and manifest validation

**Files:**
- Create: `…/plugins/{{PLUGIN_NAME}}/skills/{{PLUGIN_NAME}}/SKILL.md`. Mirror the Codex skill:
  - frontmatter `name: {{PLUGIN_NAME}}`
  - description `Use when {{MEMBER_PHRASE}} asks to count their Claude Code sessions, enroll in evening GitHub backups, check whether the evening commit succeeded, retry a missed batch, or disable sync.`
  - bullets for `Collect-ClaudeTeamHistory.ps1 -InventoryOnly`, `Configure-AnimLibrarian.ps1 -EnableAccountSync [-IncludeImages]`, `-Status`, `Sync-AnimTeamSessions.ps1` and `-DisableAccountSync`
  - the line "Keep conversation text out of status reports."
  - scripts referenced via `${CLAUDE_PLUGIN_ROOT}/scripts/`
- Create: `…/plugins/{{PLUGIN_NAME}}/README.md`, adapted from the Codex plugin README. Install steps:

  ```powershell
  claude plugin marketplace add .
  claude plugin install {{PLUGIN_NAME}}@{{MARKETPLACE}}
  ```

  The scripts-path one-liner is built from `claude plugin list --json`. Read the actual field name for the install path from Claude Code 2.1.268 output and use it. The README also covers:
  - the retention note and `-KeepTranscriptRetention`
  - "only Claude Code sessions, not claude.ai Chat"
  - the status table with `ScriptMissing` added and the migration rows removed
  - disable
- Create: `Plugins/Claude/_template/README.md`, which becomes `<slug>-team-librarian/README.md`. It is the team landing page and links the current release zip and the install guide, like the Codex team README.
- Test: `Plugins/Claude/tests/Build.Tests.ps1`, with a new test.

- [ ] **Step 1: Write the failing test** `It 'passes claude plugin validate for every team'`. For each rendered team, `claude plugin validate <team>/marketplace` and `claude plugin validate <team>/marketplace/plugins/<name>` exit 0. Mark it `-Skip` when `claude` isn't on PATH.
- [ ] **Step 2: Run it.** Expected: FAIL because SKILL.md is missing.
- [ ] **Step 3: Write** the three docs.
- [ ] **Step 4: Run the full suite.** Expected: PASS.
- [ ] **Step 5: Build and commit** (`Add Claude librarian skill and docs`).

---

### Task 10: Repository docs, generated output and release zips

**Files:**
- Create: `Plugins/Claude/README.md`: a table of the five Claude librarians and their destinations, plus a "Maintainers" note. The note says to edit `_template/` and to run `Build-ClaudeLibrarians.ps1` and `tests/Invoke-ClaudeLibrarianTests.ps1`.
- Modify: `README.md`. After the Codex table, add a `| Claude Code plugin | Backup destination |` table linking `Plugins/Claude/<slug>-team-librarian/` and `Usage data/<team>/<seat-email>/Claude/`.
- Modify: `Usage data/README.md`. Replace "The empty Claude and Opencode folders reserve space for their collectors" with text saying the Claude librarian fills `Claude/` and Opencode is reserved. Add a Claude line to "Workstation setup" pointing at `../Plugins/Claude/`.
- Generated: `Plugins/Claude/<slug>-team-librarian/**` and `releases/<slug>-team-librarian-0.1.0.zip`.

- [ ] **Step 1: Run** `pwsh -File Plugins/Claude/Build-ClaudeLibrarians.ps1`, then `-Check`. Expected: exit 0.
- [ ] **Step 2: Run** `pwsh -File Plugins/Claude/tests/Invoke-ClaudeLibrarianTests.ps1`. Expected: all pass.
- [ ] **Step 3: Write** the three docs above and check that every relative link resolves: `Test-Path` for each link target.
- [ ] **Step 4: Commit** (`Publish Claude team librarians 0.1.0`).

---

### Task 11: Manual acceptance on this workstation (no GitHub push)

- [ ] **Step 1:** Make a throwaway bare clone, `git clone --bare . $env:TEMP\kb-accept.git`.
- [ ] **Step 2:** Extract `Plugins/Claude/anim-team-librarian/releases/anim-team-librarian-0.1.0.zip` to `$env:TEMP\anim-claude`. Replace its `Publish-AnimTeamSessions.ps1` with the Task 7 test copy pointing at `file:///…/kb-accept.git`.
- [ ] **Step 3:** In that folder, run `claude plugin marketplace add .` and then `claude plugin install anim-team-librarian@anim-team-tools`. Expected: installed. Run `Collect-ClaudeTeamHistory.ps1 -InventoryOnly` from the installed scripts. Expected: a session count matching `(Get-ChildItem ~\.claude\projects\*\*.jsonl).Count` minus the non-GUID files.
- [ ] **Step 4:** Back up `~\.claude\settings.json`. Run `Configure-AnimLibrarian.ps1 -EnableAccountSync -EveningTime 00:00`, then `-Status`. Expected:
  - `Completed` with `outcome` `Changed`
  - `transcriptRetentionDays` 3650 or more
  - a task named `Anim Team Librarian (Claude) - <SID>` in Task Scheduler, pointing at `%LOCALAPPDATA%\YHAnimTeamClaudeLibrarian\app\0.1.0\`

  The Codex task, if present, is untouched.
- [ ] **Step 5:** In the bare clone, spot-check 3 documents. Each should have no `tool_use` or `tool_result` text and no `<system-reminder>`, and titles should match the sessions.
- [ ] **Step 6:** Run `-DisableAccountSync`. Expected: the task and `app\` are gone. Restore `settings.json` from the backup if the user wants it back, uninstall the test plugin, and delete the temp folders.
- [ ] **Step 7:** Report the results to the user. Pushing the branch and opening a PR happens only on their go-ahead.
