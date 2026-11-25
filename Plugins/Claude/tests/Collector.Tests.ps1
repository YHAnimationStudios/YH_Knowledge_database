BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures/transcripts'
    $script:Pwsh = (Get-Process -Id $PID).Path
}

Describe 'Collect-ClaudeTeamHistory' {
    BeforeAll {
        $script:Scripts = New-LibrarianTestPlugin 'anim'
        $script:Collector = Join-Path $script:Scripts 'Collect-ClaudeTeamHistory.ps1'

        function script:New-Profile {
            # Synthetic profile root: .claude.json plus .claude/projects/p1. Never the real profile.
            param([switch]$NoProjects)
            $root = Join-Path (Get-TestDriveRoot) ('profile-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root | Out-Null
            @{ oauthAccount = @{ emailAddress = 'Artist@Example.com'; accountUuid = 'acct-1' } } |
                ConvertTo-Json | Set-Content (Join-Path $root '.claude.json')
            $projects = Join-Path $root '.claude/projects/p1'
            if (-not $NoProjects) { New-Item -ItemType Directory -Path $projects | Out-Null }
            return $root
        }
        function script:Add-Session {
            param($Root, $Fixture, [string]$Guid = ([guid]::NewGuid().ToString()))
            Copy-Item (Join-Path $script:Fixtures "$Fixture.jsonl") (Join-Path $Root ".claude/projects/p1/$Guid.jsonl")
            return $Guid
        }
        function script:New-Out { Join-Path (Get-TestDriveRoot) ('out-' + [guid]::NewGuid().ToString('N')) }
        function script:Invoke-Collector {
            param([hashtable]$Arguments)
            $json = & $script:Collector @Arguments
            return ($json | ConvertFrom-Json)
        }
    }

    It 'returns identity only' {
        $root = New-Profile
        $r = Invoke-Collector @{ ProfileRoot = $root; IdentityOnly = $true }
        $r.email | Should -Be 'artist@example.com'
        $r.userId | Should -Be 'acct-1'
        $r.sessions | Should -Be 0
    }

    It 'counts sessions in inventory mode and skips subagents and non-guid files' {
        $root = New-Profile
        Add-Session $root 'basic' | Out-Null
        Add-Session $root 'tools' | Out-Null
        $sub = Join-Path $root ".claude/projects/p1/$([guid]::NewGuid())/subagents"
        New-Item -ItemType Directory -Path $sub | Out-Null
        Copy-Item (Join-Path $script:Fixtures 'basic.jsonl') (Join-Path $sub 'x.jsonl')
        Copy-Item (Join-Path $script:Fixtures 'basic.jsonl') (Join-Path $root '.claude/projects/p1/notes.jsonl')
        $r = Invoke-Collector @{ ProfileRoot = $root; InventoryOnly = $true }
        $r.sessions | Should -Be 2
        $r.skipped | Should -Be 1
        $r.documents | Should -Be 0
    }

    It 'writes one masked document per session' {
        $root = New-Profile
        $line = '{"type":"user","uuid":"u1","parentUuid":null,"timestamp":"2026-11-25T10:00:00.000Z","message":{"role":"user","content":"token ghp_' + ('a' * 30) + ' here"}}'
        $guid = [guid]::NewGuid().ToString()
        Set-Content (Join-Path $root ".claude/projects/p1/$guid.jsonl") $line
        $out = New-Out
        $r = Invoke-Collector @{ ProfileRoot = $root; OutputDirectory = $out }
        $r.documents | Should -Be 1
        $text = Get-Content (Join-Path $out "$guid.md") -Raw
        $text | Should -BeLike '<!-- anim-team-librarian {"schema":1,*'
        $text | Should -Match '## User \(sent '
        $text | Should -Match '\[REDACTED\]'
        $text | Should -Not -Match 'ghp_a'
        $text | Should -Match "Session ID: $guid"
        $text | Should -Not -Match 'Status:'
    }

    It 'treats a missing projects folder as zero sessions' {
        $root = New-Profile -NoProjects
        $r = Invoke-Collector @{ ProfileRoot = $root; InventoryOnly = $true }
        $r.sessions | Should -Be 0
        $r.skipped | Should -Be 0
    }

    It 'writes a header-only document for a session without visible messages' {
        $root = New-Profile
        $line = '{"type":"user","uuid":"u1","parentUuid":null,"timestamp":"2026-11-25T10:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"SECRET-OUTPUT"}]}}'
        $guid = [guid]::NewGuid().ToString()
        Set-Content (Join-Path $root ".claude/projects/p1/$guid.jsonl") $line
        Add-Session $root 'tools' | Out-Null
        $out = New-Out
        $r = Invoke-Collector @{ ProfileRoot = $root; OutputDirectory = $out }
        $r.documents | Should -Be $r.sessions
        $text = Get-Content (Join-Path $out "$guid.md") -Raw
        $text | Should -Match '"messages":0'
        $text | Should -Match '# Claude Code session'
        $text | Should -Not -Match 'SECRET'
    }

    It 'excludes tool, thinking and result content from documents' {
        $root = New-Profile
        $guid = Add-Session $root 'tools'
        $out = New-Out
        Invoke-Collector @{ ProfileRoot = $root; OutputDirectory = $out } | Out-Null
        $text = Get-Content (Join-Path $out "$guid.md") -Raw
        $text | Should -Match '## Assistant \(sent '
        $text | Should -Not -Match 'SECRET|secret thoughts'
        $text | Should -Match '    Done\.'
    }

    It 'reports malformed lines without failing the session' {
        $root = New-Profile
        Add-Session $root 'malformed' | Out-Null
        $out = New-Out
        $r = Invoke-Collector @{ ProfileRoot = $root; OutputDirectory = $out }
        $r.malformedLines | Should -Be 2
        $r.failures | Should -Be 0
        $r.documents | Should -Be 1
    }

    It 'rejects an expected email that does not match' {
        $root = New-Profile
        { Invoke-Collector @{ ProfileRoot = $root; IdentityOnly = $true; ExpectedEmail = 'other@example.com' } } |
            Should -Throw -ExceptionType ([UnauthorizedAccessException])
    }

    It 'fails and cleans up when the account changes mid-run' {
        # Mock-equivalent: wrap Read-ClaudeIdentity in a copy of the scripts folder so the 3rd read
        # returns another account. (The collector dot-sources ClaudeSession.ps1, which would shadow a Pester mock.)
        $copy = Join-Path (Get-TestDriveRoot) ('copy-' + [guid]::NewGuid().ToString('N'))
        Copy-Item $script:Scripts $copy -Recurse
        $counter = Join-Path $copy 'calls.txt'
        Add-Content (Join-Path $copy 'ClaudeSession.ps1') @"

`$script:RealReadClaudeIdentity = `${function:Read-ClaudeIdentity}
function Read-ClaudeIdentity([string] `$ConfigPath) {
    Add-Content '$counter' 'x'
    `$identity = & `$script:RealReadClaudeIdentity `$ConfigPath
    if ((Get-Content '$counter').Count -ge 3) { `$identity.userId = 'acct-2' }
    return `$identity
}
"@
        $root = New-Profile
        Add-Session $root 'basic' | Out-Null
        Add-Session $root 'tools' | Out-Null
        $out = New-Out
        { & (Join-Path $copy 'Collect-ClaudeTeamHistory.ps1') -ProfileRoot $root -OutputDirectory $out } |
            Should -Throw -ExceptionType ([UnauthorizedAccessException])
        @(Get-ChildItem $out -Force).Count | Should -Be 0
    }

    It 'writes pictures with -IncludeImages' {
        Add-Type -AssemblyName PresentationCore
        $src = [Windows.Media.Imaging.BitmapSource]::Create(1, 1, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, [byte[]](10, 20, 30, 255), 4)
        $enc = [Windows.Media.Imaging.PngBitmapEncoder]::new()
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($src))
        $ms = [IO.MemoryStream]::new(); $enc.Save($ms)
        $b64 = [Convert]::ToBase64String($ms.ToArray())
        $root = New-Profile
        $guid = [guid]::NewGuid().ToString()
        $fixture = (Get-Content (Join-Path $script:Fixtures 'image.jsonl') -Raw) -replace '"data":"AAAA"', "`"data`":`"$b64`"" -replace '"data":"BBBB"', "`"data`":`"$b64`""
        Set-Content (Join-Path $root ".claude/projects/p1/$guid.jsonl") $fixture
        $out = New-Out
        $r = Invoke-Collector @{ ProfileRoot = $root; OutputDirectory = $out; IncludeImages = $true }
        $r.imageFiles | Should -Be 1
        $r.imagesAvailable | Should -Be 2
        $r.imageReferences | Should -Be 2
        $png = @(Get-ChildItem (Join-Path $out "images/$guid") -Filter *.png)
        $png.Count | Should -Be 1
        $text = Get-Content (Join-Path $out "$guid.md") -Raw
        $text | Should -Match ([regex]::Escape("![Image attachment](images/$guid/$($png[0].Name))"))
        $text | Should -Not -Match 'LEAK'
    }

    It 'marks pictures as placeholders without -IncludeImages' {
        $root = New-Profile
        $guid = Add-Session $root 'image'
        $out = New-Out
        Invoke-Collector @{ ProfileRoot = $root; OutputDirectory = $out } | Out-Null
        $text = Get-Content (Join-Path $out "$guid.md") -Raw
        $text | Should -Match '\[Image attachment\]'
        Test-Path (Join-Path $out 'images') | Should -BeFalse
    }

    It 'uses transcript timestamps when ConvertFrom-Json has no -DateKind (PowerShell 7.2-7.4)' {
        $copy = Join-Path (Get-TestDriveRoot) ('nodk-' + [guid]::NewGuid().ToString('N'))
        Copy-Item $script:Scripts $copy -Recurse
        $transcript = Join-Path $copy 'ClaudeTranscript.ps1'
        $source = Get-Content $transcript -Raw
        $patched = $source -replace '(?m)^\$script:TranscriptHasDateKind = .*$', '$script:TranscriptHasDateKind = $false'
        $patched | Should -Not -Be $source
        Set-Content $transcript $patched
        $root = New-Profile
        $guid = Add-Session $root 'basic'
        $stamps = @(Select-String -Path (Join-Path $root ".claude/projects/p1/$guid.jsonl") -Pattern '"timestamp":"([^"]*)"' |
            ForEach-Object { $_.Matches[0].Groups[1].Value })
        $first = [datetimeoffset]::Parse($stamps[0], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        $last = [datetimeoffset]::Parse($stamps[-1], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        $out = New-Out
        & (Join-Path $copy 'Collect-ClaudeTeamHistory.ps1') -ProfileRoot $root -OutputDirectory $out | Out-Null
        $text = Get-Content (Join-Path $out "$guid.md") -Raw
        $fmt = "yyyy-MM-ddTHH:mm:ss.FFFFFFF'Z'"
        $text | Should -Match ([regex]::Escape("Created (UTC): $($first.UtcDateTime.ToString($fmt, [Globalization.CultureInfo]::InvariantCulture))"))
        $text | Should -Match ([regex]::Escape("Updated (UTC): $($last.UtcDateTime.ToString($fmt, [Globalization.CultureInfo]::InvariantCulture))"))
        $text | Should -Match ([regex]::Escape("`"updatedAt`":$($last.ToUnixTimeSeconds()),"))
    }

    It 'throws for a blank -ProfileRoot instead of using the real profile' {
        foreach ($blank in '', '   ') {
            { & $script:Collector -ProfileRoot $blank -IdentityOnly } | Should -Throw -ExceptionType ([ArgumentException])
        }
    }
}
