# 3D Art Team Librarian

This Codex plugin backs up enrolled seats to `Usage data/3D art team/<seat-email>/Codex/` in this repository. It creates the seat and tool folders automatically when it first publishes their files.

Download [3D Art Team Librarian 0.5.0](releases/3d-art-team-librarian-0.5.0.zip) and follow the [installation and enrollment instructions](marketplace/plugins/3d-art-team-librarian/README.md). The [marketplace source](marketplace/) is included with this release.

Each enrolled workstation commits changed chats and optional pictures together at **10:00 PM local time**. It checks for missed evenings at sign-in and every 30 minutes. Each session has one Markdown document. Its pictures use the same session ID under `images/<session-id>/`.

On a workstation already enrolled with 0.4.0, install 0.5.0 and run `Configure-AnimLibrarian.ps1 -EnableAccountSync` from the new release to retain the current schedule and picture setting.
