# Codex usage data

Anim Team Librarian saves an animator’s Codex chats in a folder named for their signed-in seat email. Each Markdown filename is a session ID. Repository readers can read these documents.

At **10:00 PM local time**, each enrolled workstation checks its saved active and archived chats and commits all changed documents together. A missed evening is retried after sign-in or at the next half-hour check. An unchanged evening gets a local completion receipt.

## Enroll or upgrade a workstation

Download [Anim Team Librarian 0.3.0](../anim-team-librarian-0.3.0.zip) and follow `plugins/anim-team-librarian/README.md` inside the package. Existing 0.2.0 installations must also rerun enrollment to register their evening task. To see whether the latest evening completed, run `Configure-AnimLibrarian.ps1 -Status` from the installed plugin scripts.
