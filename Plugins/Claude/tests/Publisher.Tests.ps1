BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Scripts = New-LibrarianTestPlugin 'anim'
    . (Join-Path $script:Scripts 'LibrarianState.ps1')
    . (Join-Path $script:Scripts 'Publish-AnimTeamSessionsCore.ps1')
    $script:Email = 'seat@x.org'
    $script:Seat = "Usage data/Animators team/$($script:Email)"

    function script:Invoke-TestGit {
        param([string]$GitDir, [string[]]$Arguments)
        $out = & git "--git-dir=$GitDir" @Arguments
        if ($LASTEXITCODE) { throw "git $($Arguments[0]) failed" }
        return $out
    }
    function script:New-Remote {
        # Bare repo seeded through a scratch clone. Returns @{Bare; Url; Work}.
        param([switch]$NoLayout)
        $root = Join-Path (Get-TestDriveRoot) ('remote-' + [guid]::NewGuid().ToString('N'))
        $bare = Join-Path $root 'bare.git'
        $work = Join-Path $root 'work'
        New-Item -ItemType Directory -Path $root | Out-Null
        & git init --quiet --bare -b main $bare
        & git clone --quiet $bare $work 2>$null
        if (-not $NoLayout) {
            New-Item -ItemType Directory -Path (Join-Path $work 'Usage data') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $work 'Usage data/layout.json'), '{"version":2}')
        }
        $claude = Join-Path $work "$($script:Seat)/Claude"
        New-Item -ItemType Directory -Path $claude -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $claude '.gitkeep') | Out-Null
        & git -C $work add -A
        & git -C $work -c user.name=seed -c user.email=seed@x.org commit --quiet -m seed
        & git -C $work push --quiet origin HEAD:refs/heads/main 2>$null
        return @{ Bare = $bare; Work = $work; Url = 'file:///' + ($bare -replace '\\', '/') }
    }
    function script:New-Documents {
        param([int]$Count = 1)
        $dir = Join-Path (Get-TestDriveRoot) ('docs-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $ids = foreach ($i in 1..$Count) {
            $id = [guid]::NewGuid().ToString()
            $text = "<!-- anim-team-librarian {`"schema`":1,`"updatedAt`":1000,`"messages`":2} -->`n# Session`n`nSession ID: $id`n`nhello`n"
            [IO.File]::WriteAllText((Join-Path $dir "$id.md"), $text)
            $id
        }
        return @{ Dir = $dir; Ids = @($ids) }
    }
    function script:New-State { Join-Path (Get-TestDriveRoot) ('state-' + [guid]::NewGuid().ToString('N')) }
    function script:Invoke-Publish {
        param($Remote, $Docs, [string]$State = (New-State), [string]$BatchDate = '2026-11-25')
        $splat = @{ DocumentDirectory = $Docs.Dir; Email = $script:Email; StateDirectory = $State; RemoteUrl = $Remote.Url }
        if ($BatchDate) { $splat.BatchDate = $BatchDate }
        return (Publish-AnimTeamSessionDocuments @splat | ConvertFrom-Json)
    }
}

Describe 'Publish-AnimTeamSessionDocuments' {
    BeforeEach { Mock Get-LibrarianRepositoryHttpStatus { 404 } }

    It 'publishes documents, removes Claude .gitkeep and provisions sibling folders' {
        $remote = New-Remote
        $docs = New-Documents
        $before = Invoke-TestGit $remote.Bare @('rev-list', '--count', 'main')
        $r = Invoke-Publish $remote $docs
        $r.pushed | Should -Be 1
        $r.layoutVersion | Should -Be 2
        $r.destination | Should -Be "$($script:Seat)/Claude"
        $r.provisionedTools | Should -Be 2
        ([int](Invoke-TestGit $remote.Bare @('rev-list', '--count', 'main'))) | Should -Be ([int]$before + 1)
        $files = @(Invoke-TestGit $remote.Bare @('ls-tree', '-r', '--name-only', 'main'))
        $files | Should -Contain "$($script:Seat)/Claude/$($docs.Ids[0]).md"
        $files | Should -Contain "$($script:Seat)/Codex/.gitkeep"
        $files | Should -Contain "$($script:Seat)/Opencode/.gitkeep"
        $files | Should -Not -Contain "$($script:Seat)/Claude/.gitkeep"
        (Invoke-TestGit $remote.Bare @('log', '-1', '--format=%s', 'main')) | Should -Be 'Publish evening Claude sessions for 2026-11-25'
        (Invoke-TestGit $remote.Bare @('log', '-1', '--format=%an', 'main')) | Should -Be 'Anim Team Librarian (Claude)'
    }

    It 'reports NoChanges on an identical rerun' {
        $remote = New-Remote
        $docs = New-Documents
        $state = New-State
        Invoke-Publish $remote $docs $state | Out-Null
        $head = Invoke-TestGit $remote.Bare @('rev-parse', 'main')
        $r = Invoke-Publish $remote $docs $state
        $r.pushed | Should -Be 0
        $r.commit | Should -BeNullOrEmpty
        $r.unchanged | Should -Be 1
        (Invoke-TestGit $remote.Bare @('rev-parse', 'main')) | Should -Be $head
    }

    It 'rebases onto a concurrent commit and pushes' {
        $remote = New-Remote
        $docs = New-Documents
        $script:Competed = $false
        $script:CompeteRemote = $remote
        # The visibility probe runs after the local commit is built and just before the push,
        # so a competing push injected here makes the first push non-fast-forward.
        Mock Get-LibrarianRepositoryHttpStatus {
            if (-not $script:Competed) {
                $script:Competed = $true
                $other = Join-Path (Get-TestDriveRoot) ('other-' + [guid]::NewGuid().ToString('N'))
                & git clone --quiet $script:CompeteRemote.Bare $other 2>$null
                $dir = Join-Path $other "$($script:Seat)/Codex"
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Set-Content (Join-Path $dir 'competing.txt') 'x'
                & git -C $other add -A
                & git -C $other -c user.name=other -c user.email=o@x.org commit --quiet -m 'competing commit'
                & git -C $other push --quiet origin HEAD:refs/heads/main 2>$null
            }
            404
        }
        $r = Invoke-Publish $remote $docs
        $script:Competed | Should -BeTrue
        $r.pushed | Should -Be 1
        $files = @(Invoke-TestGit $remote.Bare @('ls-tree', '-r', '--name-only', 'main'))
        $files | Should -Contain "$($script:Seat)/Codex/competing.txt"
        $files | Should -Contain "$($script:Seat)/Claude/$($docs.Ids[0]).md"
        $subjects = @(Invoke-TestGit $remote.Bare @('log', '--format=%s', 'main'))
        $subjects | Should -Contain 'competing commit'
        $subjects | Should -Contain 'Publish evening Claude sessions for 2026-11-25'
    }

    It 'refuses without layout.json' {
        $remote = New-Remote -NoLayout
        $docs = New-Documents
        $head = Invoke-TestGit $remote.Bare @('rev-parse', 'main')
        $caught = $null
        try { Invoke-Publish $remote $docs | Out-Null } catch { $caught = $_.Exception }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Data['reason'] | Should -Be 'UsageLayoutNotActive'
        (Invoke-TestGit $remote.Bare @('rev-parse', 'main')) | Should -Be $head
    }

    It 'refuses when the repository looks public' {
        Mock Get-LibrarianRepositoryHttpStatus { 200 }
        $remote = New-Remote
        $docs = New-Documents
        $head = Invoke-TestGit $remote.Bare @('rev-parse', 'main')
        { Invoke-Publish $remote $docs } | Should -Throw '*visibility*'
        (Invoke-TestGit $remote.Bare @('rev-parse', 'main')) | Should -Be $head
    }
}
