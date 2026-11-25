# {{DISPLAY_NAME}}

{{DISPLAY_NAME}} backs up a team member's saved Claude Code sessions to their seat-email folder in [Usage data](../../../Usage%20data/{{TEAM_FOLDER_URL}}/). The Windows task commits changed sessions and optional session pictures together at 10:00 PM local time and checks for missed evenings.

## Install from GitHub

With Git on this PC signed in to GitHub (the repository is private), run:

```powershell
claude plugin marketplace add YHAnimationStudios/YH_Knowledge_database
claude plugin install {{PLUGIN_NAME}}@{{CATALOG}}
```

Then follow the [enrollment instructions](marketplace/plugins/{{PLUGIN_NAME}}/README.md).

## Current release

Alternatively, download [{{DISPLAY_NAME}} {{VERSION}}](releases/{{PLUGIN_NAME}}-{{VERSION}}.zip) and follow the [installation and enrollment instructions](marketplace/plugins/{{PLUGIN_NAME}}/README.md). The [marketplace source](marketplace/) corresponds to this release.
