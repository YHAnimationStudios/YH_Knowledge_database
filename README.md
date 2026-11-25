# YH_Knowledge_database
Used for storing and sharing general info and AI usage results, workflow docs and other production documentation on assets, animation, infrastructure, and more

Browse [Usage data](Usage%20data/) by team, seat email and tool.

## Plugins

Choose your team’s librarian for its installer, setup instructions, and source. Each plugin sends enrolled seats’ chats or sessions to its preset team folder.

| Codex plugin | Backup destination |
| --- | --- |
| [Anim Team Librarian](Plugins/Codex/anim-team-librarian/) | `Usage data/Animators team/<seat-email>/Codex/` |
| [3D Art Team Librarian](Plugins/Codex/3d-art-team-librarian/) | `Usage data/3D art team/<seat-email>/Codex/` |
| [Character Art Team Librarian](Plugins/Codex/character-art-team-librarian/) | `Usage data/Character art team/<seat-email>/Codex/` |
| [Directors Team Librarian](Plugins/Codex/directors-team-librarian/) | `Usage data/Directors team/<seat-email>/Codex/` |
| [Sound Team Librarian](Plugins/Codex/sound-team-librarian/) | `Usage data/Sound team/<seat-email>/Codex/` |

| Claude Code plugin | Backup destination |
| --- | --- |
| [Anim Team Librarian](Plugins/Claude/anim-team-librarian/) | `Usage data/Animators team/<seat-email>/Claude/` |
| [3D Art Team Librarian](Plugins/Claude/3d-art-team-librarian/) | `Usage data/3D art team/<seat-email>/Claude/` |
| [Character Art Team Librarian](Plugins/Claude/character-art-team-librarian/) | `Usage data/Character art team/<seat-email>/Claude/` |
| [Directors Team Librarian](Plugins/Claude/directors-team-librarian/) | `Usage data/Directors team/<seat-email>/Claude/` |
| [Sound Team Librarian](Plugins/Claude/sound-team-librarian/) | `Usage data/Sound team/<seat-email>/Claude/` |

To install a Claude Code librarian straight from this repository, run `claude plugin marketplace add YHAnimationStudios/YH_Knowledge_database` and then `claude plugin install <team>-team-librarian@yh-team-tools`, for example `anim-team-librarian@yh-team-tools`. Git on that PC must already be signed in to GitHub.
