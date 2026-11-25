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

## Install from GitHub

The repository root has a Claude Code catalogue named `yh-team-tools` (`.claude-plugin/marketplace.json`) that lists all five librarians. With Git on the PC signed in to GitHub (the repository is private), run:

```powershell
claude plugin marketplace add YHAnimationStudios/YH_Knowledge_database
claude plugin install anim-team-librarian@yh-team-tools
```

Replace `anim` with your team's slug: `3d-art`, `character-art`, `directors` or `sound`. Then enroll as described in your team's install guide. Each team folder also keeps a release zip for offline installs.

## Maintainers

The team folders and the repository-root `.claude-plugin/marketplace.json` are build output. Edit `_template/` only. Run `pwsh -File Plugins/Claude/Build-ClaudeLibrarians.ps1` to regenerate them and the release zips, then the same command with `-Check` to confirm the output matches the template.

Bump `$Version` in the build script for every change to a plugin. People who installed from GitHub only receive updates when `plugin.json`'s version changes.

Run `tests/Invoke-ClaudeLibrarianTests.ps1` to test the template (PowerShell 7.2+ and Pester 5+).
