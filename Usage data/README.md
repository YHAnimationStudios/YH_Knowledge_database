# Usage data

Open your team, your team-seat email, and the tool whose sessions you want to read. The Librarian creates these folders for each seat. The Claude librarian fills `Claude/`; `Opencode/` remains reserved for its collector. A `.gitkeep` file represents an empty folder in Git.

| Team | Team folder |
| --- | --- |
| Animators team | [Open folder](Animators%20team/) |
| 3D art team | [Open folder](3D%20art%20team/) |
| Character art team | [Open folder](Character%20art%20team/) |
| Directors team | [Open folder](Directors%20team/) |
| Sound team | [Open folder](Sound%20team/) |

```text
<team>/<seat-email>/
  Codex/
    <session-id>.md
    images/<session-id>/<sha256>.png
  Claude/
    <session-id>.md
    images/<session-id>/<sha256>.png
  Opencode/
```

For Codex and Claude, open the Markdown document to read a chat with its available pictures in place. The name of each picture folder matches its session ID. Repository readers can see the documents and images.

## Workstation setup

Install [your team’s Codex Librarian](../Plugins/Codex/) and run `Configure-AnimLibrarian.ps1 -EnableAccountSync` from the installed scripts folder. On upgrade, this rebinds the workstation’s scheduled task and retains its existing picture choice and evening time. Add `-IncludeImages` to enable pictures and backfill recoverable ones.

For Claude Code, install [your team’s Claude librarian](../Plugins/Claude/), from GitHub with `claude plugin marketplace add YHAnimationStudios/YH_Knowledge_database` or from its release zip, and run `Configure-AnimLibrarian.ps1 -EnableAccountSync` from its installed scripts folder. Add `-IncludeImages` for pictures. The Claude librarian uses the same 22:00 default and `-Status`.

The default batch runs at **22:00 local time**. It checks for missed evenings at sign-in and every 30 minutes. Use `Configure-AnimLibrarian.ps1 -Status` to see the deadline, the latest result, and the commit for a changed evening.
