BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Build = $script:BuildScript
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Slugs = 'anim', '3d-art', 'character-art', 'directors', 'sound'
}

Describe 'Build-ClaudeLibrarians' {
    It 'renders all five teams with no leftover placeholders' {
        $out = Join-Path $TestDrive 'all'
        & $script:Build -OutputRoot $out -NoZip | Out-Null
        $dirs = Get-ChildItem -LiteralPath $out -Directory -Filter '*-team-librarian'
        $dirs.Count | Should -Be 5
        $items = Get-ChildItem -LiteralPath $out -Recurse -Force
        $items.Count | Should -BeGreaterThan 10
        foreach ($i in $items) {
            $i.FullName.Substring($out.Length) | Should -Not -Match '\{\{[A-Z_]+\}\}'
            if (-not $i.PSIsContainer) {
                [IO.File]::ReadAllText($i.FullName) | Should -Not -Match '\{\{[A-Z_]+\}\}'
            }
        }
    }

    It 'substitutes team values' {
        $out = Join-Path $TestDrive 'subst'
        & $script:Build -OutputRoot $out -Team sound -NoZip | Out-Null
        $m = Get-Content -Raw (Join-Path $out 'sound-team-librarian/marketplace/.claude-plugin/marketplace.json') | ConvertFrom-Json
        $m.name | Should -Be 'sound-team-tools'
        $m.plugins[0].source | Should -Be './plugins/sound-team-librarian'
        $m.plugins[0].description | Should -Match 'Sound team\.$'
    }

    It 'writes UTF-8 without BOM and keeps LF endings' {
        $out = Join-Path $TestDrive 'enc'
        & $script:Build -OutputRoot $out -Team anim -NoZip | Out-Null
        $f = Join-Path $out 'anim-team-librarian/marketplace/.claude-plugin/marketplace.json'
        $bytes = [IO.File]::ReadAllBytes($f)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        $bytes -contains 13 | Should -BeFalse
    }

    It 'passes -Check on fresh output and fails after a hand edit' {
        $out = Join-Path $TestDrive 'check'
        & $script:Build -OutputRoot $out -NoZip | Out-Null
        $null = & $script:Pwsh -NoProfile -File $script:Build -OutputRoot $out -Check
        $LASTEXITCODE | Should -Be 0
        $hooks = Join-Path $out 'anim-team-librarian/marketplace/plugins/anim-team-librarian/hooks/hooks.json'
        $fs = [IO.File]::Open($hooks, 'Append'); $fs.WriteByte(0x20); $fs.Close()
        $text = (& $script:Pwsh -NoProfile -File $script:Build -OutputRoot $out -Check) -join "`n"
        $LASTEXITCODE | Should -Be 1
        $text | Should -Match 'anim-team-librarian/marketplace/plugins/anim-team-librarian/hooks/hooks\.json'
    }

    It 'zips each team release' {
        $out = Join-Path $TestDrive 'zip'
        & $script:Build -OutputRoot $out -Team anim | Out-Null
        $zip = Join-Path $out 'anim-team-librarian/releases/anim-team-librarian-0.1.1.zip'
        $zip | Should -Exist
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try { $names = $z.Entries.FullName } finally { $z.Dispose() }
        $names | Should -Contain '.claude-plugin/marketplace.json'
        $names | Should -Contain 'plugins/anim-team-librarian/.claude-plugin/plugin.json'
    }

    It 'provides New-LibrarianTestPlugin returning the scripts folder' {
        $scripts = New-LibrarianTestPlugin -Team 'directors'
        Join-Path $scripts 'TranscriptText.ps1' | Should -Exist
    }

    It 'passes claude plugin validate for every team' -Skip:(-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        $out = Join-Path $TestDrive 'validate'
        & $script:Build -OutputRoot $out -NoZip | Out-Null
        foreach ($slug in $script:Slugs) {
            $team = Join-Path $out "$slug-team-librarian"
            $market = Join-Path $team 'marketplace'
            $plugin = Join-Path $market "plugins/$slug-team-librarian"
            $o1 = (& claude plugin validate $market 2>&1) -join "`n"
            "$slug marketplace ($LASTEXITCODE): $o1" | Should -Match "^$slug marketplace \(0\)"
            $o2 = (& claude plugin validate $plugin 2>&1) -join "`n"
            "$slug plugin ($LASTEXITCODE): $o2" | Should -Match "^$slug plugin \(0\)"
            Join-Path $plugin "skills/$slug-team-librarian/SKILL.md" | Should -Exist
        }
    }

    It 'tells Claude to run every bundled script with PowerShell 7' {
        $out = Join-Path $TestDrive 'skill'
        & $script:Build -OutputRoot $out -Team anim -NoZip | Out-Null
        $skill = [IO.File]::ReadAllText((Join-Path $out 'anim-team-librarian/marketplace/plugins/anim-team-librarian/skills/anim-team-librarian/SKILL.md'))
        $skill | Should -Match ([regex]::Escape('pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/'))
        # Every script reference is a pwsh -File invocation, never a bare path Windows PowerShell 5.1 could pick up.
        $refs = [regex]::Matches($skill, '`[^`]*\$\{CLAUDE_PLUGIN_ROOT\}/scripts/[^`]*`')
        $refs.Count | Should -BeGreaterThan 0
        foreach ($ref in $refs) { $ref.Value | Should -Match '^`pwsh -NoProfile -File "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/[A-Za-z-]+\.ps1"' }
    }

    It 'links the team README to the team usage folder' {
        $out = Join-Path $TestDrive 'link'
        & $script:Build -OutputRoot $out -Team anim -NoZip | Out-Null
        $readme = [IO.File]::ReadAllText((Join-Path $out 'anim-team-librarian/README.md'))
        $readme | Should -Match ([regex]::Escape('](../../../Usage%20data/Animators%20team/)'))
        # Resolve the link from the README's real location in the repo.
        $repoRoot = Split-Path -Parent (Split-Path -Parent $script:ClaudeRoot)
        $target = Join-Path $repoRoot 'Plugins/Claude/anim-team-librarian/../../../Usage data/Animators team'
        [IO.Path]::GetFullPath($target) | Should -Exist
    }

    Context 'whole-template rendering' {
        BeforeAll {
            # Copy of the real template plus a team-root file (as Task 9's README.md will be).
            $script:Tpl = Join-Path $TestDrive 'tpl'
            Copy-Item -LiteralPath (Join-Path $script:ClaudeRoot '_template') -Destination $script:Tpl -Recurse
            Set-Content -LiteralPath (Join-Path $script:Tpl 'README.md') -Value 'Docs for {{DISPLAY_NAME}}' -NoNewline
        }

        It 'renders files directly under _template/ to the team root and -Check covers them' {
            $out = Join-Path $TestDrive 'root-file'
            & $script:Build -OutputRoot $out -Team anim -NoZip -TemplateRoot $script:Tpl | Out-Null
            $readme = Join-Path $out 'anim-team-librarian/README.md'
            [IO.File]::ReadAllText($readme) | Should -Be 'Docs for Anim Team Librarian'
            $null = & $script:Pwsh -NoProfile -File $script:Build -OutputRoot $out -Team anim -Check -TemplateRoot $script:Tpl
            $LASTEXITCODE | Should -Be 0
            [IO.File]::AppendAllText($readme, 'x')
            $text = (& $script:Pwsh -NoProfile -File $script:Build -OutputRoot $out -Team anim -Check -TemplateRoot $script:Tpl) -join "`n"
            $LASTEXITCODE | Should -Be 1
            $text | Should -Match 'anim-team-librarian/README\.md'
        }

        It '-Check ignores changes under releases/ and the build keeps them' {
            $out = Join-Path $TestDrive 'releases-ignored'
            & $script:Build -OutputRoot $out -Team anim | Out-Null
            $rel = Join-Path $out 'anim-team-librarian/releases'
            Set-Content -LiteralPath (Join-Path $rel 'junk.txt') -Value 'junk'
            [IO.File]::AppendAllText((Join-Path $rel 'anim-team-librarian-0.1.1.zip'), 'x')
            $null = & $script:Pwsh -NoProfile -File $script:Build -OutputRoot $out -Team anim -Check
            $LASTEXITCODE | Should -Be 0
            & $script:Build -OutputRoot $out -Team anim -NoZip | Out-Null
            Join-Path $rel 'junk.txt' | Should -Exist
        }

        It '-Check reports an extra file in the team folder' {
            $out = Join-Path $TestDrive 'extra'
            & $script:Build -OutputRoot $out -Team anim -NoZip | Out-Null
            Set-Content -LiteralPath (Join-Path $out 'anim-team-librarian/stray.txt') -Value 'x'
            $text = (& $script:Pwsh -NoProfile -File $script:Build -OutputRoot $out -Team anim -Check) -join "`n"
            $LASTEXITCODE | Should -Be 1
            $text | Should -Match 'extra: anim-team-librarian/stray\.txt'
        }
    }
}

Describe 'Root catalogue' {
    BeforeAll {
        function script:New-CatalogBuild([string]$Name) {
            $root = Join-Path $TestDrive $Name
            $out = Join-Path $root 'Plugins/Claude'
            $cat = Join-Path $root '.claude-plugin/marketplace.json'
            & $script:Build -OutputRoot $out -CatalogPath $cat -NoZip | Out-Null
            @{ Root = $root; Out = $out; Catalog = $cat }
        }
    }

    It 'lists all five plugins with sources that resolve from the catalogue root' {
        $b = New-CatalogBuild 'cat-list'
        $b.Catalog | Should -Exist
        $c = Get-Content -Raw $b.Catalog | ConvertFrom-Json
        $c.name | Should -BeExactly 'yh-team-tools'
        $c.owner.name | Should -BeExactly 'YH Animation Studios'
        $c.description | Should -Not -BeNullOrEmpty
        @($c.plugins).Count | Should -Be 5
        foreach ($slug in $script:Slugs) {
            $name = "$slug-team-librarian"
            $e = @($c.plugins | Where-Object name -eq $name)
            $e.Count | Should -Be 1
            $e[0].source | Should -BeExactly "./Plugins/Claude/$name/marketplace/plugins/$name"
            $e[0].PSObject.Properties['version'] | Should -BeNullOrEmpty
            $manifest = Join-Path $b.Root ($e[0].source.Substring(2) + '/.claude-plugin/plugin.json')
            $manifest | Should -Exist
            (Get-Content -Raw $manifest | ConvertFrom-Json).name | Should -BeExactly $name
        }
        $bytes = [IO.File]::ReadAllBytes($b.Catalog)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        $bytes -contains 13 | Should -BeFalse
    }

    It 'writes no catalogue for a custom -OutputRoot without -CatalogPath' {
        $root = Join-Path $TestDrive 'cat-none'
        & $script:Build -OutputRoot (Join-Path $root 'Plugins/Claude') -NoZip | Out-Null
        @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force -Filter 'marketplace.json' |
            Where-Object { $_.FullName -like '*cat-none*' -and $_.Directory.Parent.FullName -eq $root }).Count | Should -Be 0
        Join-Path $root '.claude-plugin' | Should -Not -Exist
    }

    It '-Check fails when the catalogue drifts' {
        $b = New-CatalogBuild 'cat-check'
        $null = & $script:Pwsh -NoProfile -File $script:Build -OutputRoot $b.Out -CatalogPath $b.Catalog -Check
        $LASTEXITCODE | Should -Be 0
        [IO.File]::AppendAllText($b.Catalog, ' ')
        $text = (& $script:Pwsh -NoProfile -File $script:Build -OutputRoot $b.Out -CatalogPath $b.Catalog -Check) -join "`n"
        $LASTEXITCODE | Should -Be 1
        $text | Should -Match 'marketplace\.json'
    }

    It 'per-team catalogue entries carry no version' {
        $out = Join-Path $TestDrive 'cat-team'
        & $script:Build -OutputRoot $out -Team anim -NoZip | Out-Null
        $m = Get-Content -Raw (Join-Path $out 'anim-team-librarian/marketplace/.claude-plugin/marketplace.json') | ConvertFrom-Json
        $m.plugins[0].PSObject.Properties['version'] | Should -BeNullOrEmpty
        $p = Get-Content -Raw (Join-Path $out 'anim-team-librarian/marketplace/plugins/anim-team-librarian/.claude-plugin/plugin.json') | ConvertFrom-Json
        $p.version | Should -BeExactly '0.1.1'
    }

    It 'removes release zips from other versions' {
        $out = Join-Path $TestDrive 'cat-zips'
        $rel = Join-Path $out 'anim-team-librarian/releases'
        New-Item -ItemType Directory -Path $rel -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $rel 'anim-team-librarian-0.1.0.zip'), 'old')
        & $script:Build -OutputRoot $out -Team anim | Out-Null
        Join-Path $rel 'anim-team-librarian-0.1.0.zip' | Should -Not -Exist
        Join-Path $rel 'anim-team-librarian-0.1.1.zip' | Should -Exist
    }

    It 'passes claude plugin validate for the root catalogue' -Skip:(-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        $b = New-CatalogBuild 'cat-validate'
        $o = (& claude plugin validate $b.Root 2>&1) -join "`n"
        "root ($LASTEXITCODE): $o" | Should -Match '^root \(0\)'
        $o | Should -Not -Match '(?i)warning'
    }
}
