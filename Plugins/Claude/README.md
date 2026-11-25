# Claude Code plugins

Choose your team’s librarian for its installer, setup instructions, and source. Each plugin sends enrolled seats’ Claude Code sessions to its preset team folder.

| Claude Code plugin | Backup destination |
| --- | --- |
| [Anim Team Librarian](anim-team-librarian/) | `Usage data/Animators team/<seat-email>/Claude/` |
| [3D Art Team Librarian](3d-art-team-librarian/) | `Usage data/3D art team/<seat-email>/Claude/` |
| [Character Art Team Librarian](character-art-team-librarian/) | `Usage data/Character art team/<seat-email>/Claude/` |
| [Directors Team Librarian](directors-team-librarian/) | `Usage data/Directors team/<seat-email>/Claude/` |
| [Sound Team Librarian](sound-team-librarian/) | `Usage data/Sound team/<seat-email>/Claude/` |

These plugins back up Claude Code sessions only (CLI, desktop Code tab, and IDE), not claude.ai Chat.

## Maintainers

The team folders are build output. Edit `_template/` only, then run `Build-ClaudeLibrarians.ps1` to regenerate them and the release zips, and `Build-ClaudeLibrarians.ps1 -Check` to confirm the output matches the template.

Run `tests/Invoke-ClaudeLibrarianTests.ps1` to test the template (PowerShell 7.2+ and Pester 5+).
