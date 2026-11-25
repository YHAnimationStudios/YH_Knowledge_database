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
        $zip = Join-Path $out 'anim-team-librarian/releases/anim-team-librarian-0.1.0.zip'
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
            [IO.File]::AppendAllText((Join-Path $rel 'anim-team-librarian-0.1.0.zip'), 'x')
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
