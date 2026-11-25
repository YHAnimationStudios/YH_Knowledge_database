# Codex usage data

Anim Team Librarian creates a folder for each signed-in animator’s seat email. Each Markdown filename is a session ID. When the animator enables pictures, the matching image folder uses that same ID.

```text
<seat-email>/<session-id>.md
<seat-email>/images/<session-id>/<sha256>.png
```

The Markdown links each attached or generated picture at its original position. Repeated pictures share a file within a session. A picture used in two sessions has a path under each session. Repository readers can read the chats and see their pictures.

At **10:00 PM local time**, each enrolled workstation checks its saved active and archived chats and commits changed documents and pictures together. The first picture-enabled batch also backfills recoverable pictures from older sessions. Unavailable originals are marked in the chat and counted in the receipt. A missed evening is retried after sign-in or at the next half-hour check. An unchanged evening gets a local completion receipt.

## Enroll or upgrade a workstation

Download [Anim Team Librarian](../../Plugins/anim-team-librarian/) and follow its installation instructions. To include pictures, run `Configure-AnimLibrarian.ps1 -EnableAccountSync -IncludeImages` from the installed scripts folder. Use `Configure-AnimLibrarian.ps1 -Status` to check the latest evening receipt and commit.
