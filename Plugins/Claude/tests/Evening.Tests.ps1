BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures/transcripts'
    $script:Scripts = New-LibrarianTestPlugin 'anim'
    $script:Email = 'artist@example.com'
    $script:UserId = 'acct-1'

    # Test seams live only in the rendered copies inside TestDrive; shipped scripts are untouched.
    $script:ProfileRoot = Join-Path (Get-TestDriveRoot) 'evening-profile'
    New-Item -ItemType Directory -Path (Join-Path $script:ProfileRoot '.claude/projects/p1') -Force | Out-Null
    @{ oauthAccount = @{ emailAddress = 'Artist@Example.com'; accountUuid = $script:UserId } } |
        ConvertTo-Json | Set-Content (Join-Path $script:ProfileRoot '.claude.json')
    $sessionFile = Join-Path $script:Scripts 'ClaudeSession.ps1'
    $text = [IO.File]::ReadAllText($sessionFile)
    $needle = "[Environment]::GetFolderPath('UserProfile')"
    if (-not $text.Contains($needle)) { throw 'Profile seam not found.' }
    [IO.File]::WriteAllText($sessionFile, $text.Replace($needle, "'$($script:ProfileRoot)'"))
    $script:PublishCopy = Join-Path $script:Scripts 'Publish-AnimTeamSessions.ps1'
    $script:PublishOriginal = [IO.File]::ReadAllText($script:PublishCopy)

    . (Join-Path $script:Scripts 'LibrarianState.ps1')
    . (Join-Path $script:Scripts 'LibrarianEvening.ps1')

    function script:Set-Remote {
        # Test copy of the wrapper: file:/// remote and no network visibility probe.
        param($Remote)
        $line = "-RemoteUrl 'https://github.com/YHAnimationStudios/YH_Knowledge_database.git'"
        if (-not $script:PublishOriginal.Contains($line)) { throw 'Remote seam not found.' }
        $body = $script:PublishOriginal.Replace($line, "-RemoteUrl '$($Remote.Url)'")
        $body = $body.Replace('Publish-AnimTeamSessionDocuments @PSBoundParameters', "function Get-LibrarianRepositoryHttpStatus { 404 }`r`nPublish-AnimTeamSessionDocuments @PSBoundParameters")
        [IO.File]::WriteAllText($script:PublishCopy, $body)
    }
    function script:New-Remote {
        $root = Join-Path (Get-TestDriveRoot) ('remote-' + [guid]::NewGuid().ToString('N'))
        $bare = Join-Path $root 'bare.git'
        $work = Join-Path $root 'work'
        New-Item -ItemType Directory -Path $root | Out-Null
        & git init --quiet --bare -b main $bare
        & git clone --quiet $bare $work 2>$null
        New-Item -ItemType Directory -Path (Join-Path $work 'Usage data') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $work 'Usage data/layout.json'), '{"version":2}')
        $claude = Join-Path $work "Usage data/Animators team/$($script:Email)/Claude"
        New-Item -ItemType Directory -Path $claude -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $claude '.gitkeep') | Out-Null
        & git -C $work add -A
        & git -C $work -c user.name=seed -c user.email=seed@x.org commit --quiet -m seed
        & git -C $work push --quiet origin HEAD:refs/heads/main 2>$null
        return @{ Bare = $bare; Url = 'file:///' + ($bare -replace '\\', '/') }
    }
    function script:Get-RemoteHead($Remote) { (& git "--git-dir=$($Remote.Bare)" rev-parse main) }
    function script:Get-RemoteCount($Remote) { [int](& git "--git-dir=$($Remote.Bare)" rev-list --count main) }
    function script:Add-Session([string]$Fixture) {
        $dest = Join-Path $script:ProfileRoot ".claude/projects/p1/$([guid]::NewGuid()).jsonl"
        Copy-Item (Join-Path $script:Fixtures "$Fixture.jsonl") $dest
    }
    function script:Clear-Sessions {
        Get-ChildItem (Join-Path $script:ProfileRoot '.claude/projects/p1') -Filter *.jsonl | Remove-Item
    }
    function script:New-Enrollment([string]$UserId = $script:UserId) {
        $dir = Join-Path (Get-TestDriveRoot) ('state-' + [guid]::NewGuid().ToString('N'))
        New-LibrarianPrivateDirectory $dir
        $id = [guid]::NewGuid().ToString('N')
        $config = [ordered]@{ schemaVersion = 3; mode = 'AccountSync'; enrollmentId = $id; email = $script:Email
            userId = $UserId; includeImages = $false; eveningTime = '22:00'; firstEveningDate = '2026-11-01' }
        Write-LibrarianJson (Join-Path $dir 'account-sync.json') $config
        $seat = Join-Path $dir "seat-$id"
        New-LibrarianPrivateDirectory $seat
        return @{ Dir = $dir; Seat = $seat; Id = $id }
    }
    function script:Invoke-Due($Enrollment) {
        $config = Get-LibrarianConfig $Enrollment.Dir
        $status = Get-LibrarianEveningStatus $config $Enrollment.Seat
        return (Invoke-LibrarianEvening $config $Enrollment.Dir $Enrollment.Seat $status)
    }
    function script:Read-Receipt($Enrollment, [string]$Name) {
        Read-LibrarianJson (Join-Path $Enrollment.Seat $Name)
    }
}

Describe 'Invoke-LibrarianEvening' {
    BeforeEach {
        Clear-Sessions
        Add-Session 'basic'
        $script:Remote = New-Remote
        Set-Remote $script:Remote
        Mock Get-LibrarianRepositoryHttpStatus { 404 }
        Mock Get-LibrarianLocalNow { [DateTimeOffset]::new(2026, 11, 25, 22, 5, 0, [TimeSpan]::Zero) }
    }

    It 'completes a due evening with a commit' {
        $e = New-Enrollment
        Invoke-Due $e | Should -BeTrue
        $r = Read-Receipt $e 'evening-completed.json'
        $r.status | Should -Be 'Completed'
        $r.outcome | Should -Be 'Changed'
        $r.commit | Should -Match '^[a-f0-9]{40}$'
        $r.batchDate | Should -Be '2026-11-25'
        $r.destination | Should -Be "Usage data/Animators team/$($script:Email)/Claude"
        $r.sessions | Should -Be 1
        $r.documents | Should -Be 1
        $r.malformedLines | Should -Be 0
        Test-Path (Join-Path $e.Seat 'evening-2026-11-25') | Should -BeFalse
    }

    It 'records NoChanges on the next evening without edits' {
        $e = New-Enrollment
        Invoke-Due $e | Should -BeTrue
        Mock Get-LibrarianLocalNow { [DateTimeOffset]::new(2026, 11, 26, 22, 5, 0, [TimeSpan]::Zero) }
        $before = Get-RemoteCount $script:Remote
        Invoke-Due $e | Should -BeTrue
        $r = Read-Receipt $e 'evening-completed.json'
        $r.batchDate | Should -Be '2026-11-26'
        $r.outcome | Should -Be 'NoChanges'
        Get-RemoteCount $script:Remote | Should -Be $before
    }

    It 'holds the batch when the signed-in account changed' {
        $e = New-Enrollment 'someone-else'
        $head = Get-RemoteHead $script:Remote
        Invoke-Due $e | Should -BeFalse
        $a = Read-Receipt $e 'evening-attempt.json'
        $a.status | Should -Be 'RetryPending'
        $a.reason | Should -Be 'AccountChanged'
        Get-RemoteHead $script:Remote | Should -Be $head
        Test-Path (Join-Path $e.Seat 'evening-completed.json') | Should -BeFalse
    }

    It 'completes despite malformed lines' {
        Add-Session 'malformed'
        $e = New-Enrollment
        Invoke-Due $e | Should -BeTrue
        $r = Read-Receipt $e 'evening-completed.json'
        $r.status | Should -Be 'Completed'
        $r.malformedLines | Should -Be 2
        $r.sessions | Should -Be 2
    }

    It 'collapses missed evenings into one batch' {
        $e = New-Enrollment
        Write-LibrarianJson (Join-Path $e.Seat 'evening-completed.json') ([ordered]@{
            enrollmentId = $e.Id; batchDate = '2026-11-22'; status = 'Completed' })
        $before = Get-RemoteCount $script:Remote
        Invoke-Due $e | Should -BeTrue
        Get-RemoteCount $script:Remote | Should -Be ($before + 1)
        $r = Read-Receipt $e 'evening-completed.json'
        $r.batchDate | Should -Be '2026-11-25'
        $r.outcome | Should -Be 'Changed'
    }

    It 'leaves the batch due when a session cannot be read' {
        $dir = Join-Path $script:ProfileRoot '.claude/projects/p1'
        $bad = Join-Path $dir "$([guid]::NewGuid()).jsonl"
        $stream = [IO.File]::Open($bad, 'Create', 'ReadWrite', 'None')
        try {
            $e = New-Enrollment
            Invoke-Due $e | Should -BeFalse
            (Read-Receipt $e 'evening-attempt.json').reason | Should -BeIn @('CollectionIncomplete','CollectionFailed')
            Test-Path (Join-Path $e.Seat 'evening-completed.json') | Should -BeFalse
        } finally { $stream.Dispose() }
    }
}
