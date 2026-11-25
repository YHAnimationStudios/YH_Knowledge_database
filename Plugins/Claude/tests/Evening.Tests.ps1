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
    # Hook files let child scripts (which re-dot-source helpers, defeating Pester mocks) be steered.
    $script:IdentityHook = Join-Path (Get-TestDriveRoot) 'identity-hook.json'
    $script:NowHook = Join-Path (Get-TestDriveRoot) 'now-hook.txt'
    $script:StateHook = Join-Path (Get-TestDriveRoot) 'state-hook.txt'
    $hookCode = "if ([IO.File]::Exists('$($script:IdentityHook)')) { `$h = [IO.File]::ReadAllText('$($script:IdentityHook)') | ConvertFrom-Json; `$h.count = [int]`$h.count + 1; [IO.File]::WriteAllText('$($script:IdentityHook)', (`$h | ConvertTo-Json -Compress)); if (`$h.count -ge `$h.after) { `$ConfigPath = `$h.alt } }"
    $sig = 'function Read-ClaudeIdentity([string] $ConfigPath) {'
    $text = [IO.File]::ReadAllText($sessionFile)
    if (-not $text.Contains($sig)) { throw 'Identity seam not found.' }
    [IO.File]::WriteAllText($sessionFile, $text.Replace($sig, "$sig`r`n    $hookCode"))
    $stateFile = Join-Path $script:Scripts 'LibrarianState.ps1'
    $text = [IO.File]::ReadAllText($stateFile)
    $sig = 'function Get-LibrarianStateDirectory {'
    $probe = 'function Get-LibrarianRepositoryHttpStatus {'
    if (-not $text.Contains($sig) -or -not $text.Contains($probe)) { throw 'State seam not found.' }
    $text = $text.Replace($sig, "$sig`r`n    return [IO.File]::ReadAllText('$($script:StateHook)')")
    [IO.File]::WriteAllText($stateFile, $text.Replace($probe, "$probe`r`n    return 404"))
    $eveningFile = Join-Path $script:Scripts 'LibrarianEvening.ps1'
    $text = [IO.File]::ReadAllText($eveningFile)
    $sig = 'function Get-LibrarianLocalNow { [DateTimeOffset]::Now }'
    if (-not $text.Contains($sig)) { throw 'Clock seam not found.' }
    [IO.File]::WriteAllText($eveningFile, $text.Replace($sig, "function Get-LibrarianLocalNow { if ([IO.File]::Exists('$($script:NowHook)')) { [DateTimeOffset]::Parse([IO.File]::ReadAllText('$($script:NowHook)')) } else { [DateTimeOffset]::Now } }"))
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
    function script:Set-Profile([bool]$SignedIn = $true) {
        $account = if ($SignedIn) { @{ oauthAccount = @{ emailAddress = 'Artist@Example.com'; accountUuid = $script:UserId } } } else { @{} }
        $account | ConvertTo-Json | Set-Content (Join-Path $script:ProfileRoot '.claude.json')
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
        Remove-Item $script:IdentityHook -ErrorAction SilentlyContinue
        Set-Profile
        Set-Content $script:NowHook '2026-11-25T22:05:00+00:00'
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

    It 'holds the batch as AccountChanged when signed out' {
        Set-Profile $false
        $e = New-Enrollment
        $head = Get-RemoteHead $script:Remote
        Invoke-Due $e | Should -BeFalse
        (Read-Receipt $e 'evening-attempt.json').reason | Should -Be 'AccountChanged'
        Get-RemoteHead $script:Remote | Should -Be $head
    }

    It 'holds the batch as AccountChanged when the account switches mid-collection' {
        $alt = Join-Path (Get-TestDriveRoot) 'alt-claude.json'
        @{ oauthAccount = @{ emailAddress = 'Artist@Example.com'; accountUuid = 'acct-2' } } | ConvertTo-Json | Set-Content $alt
        @{ count = 0; after = 2; alt = $alt } | ConvertTo-Json -Compress | Set-Content $script:IdentityHook
        $e = New-Enrollment
        $head = Get-RemoteHead $script:Remote
        Invoke-Due $e | Should -BeFalse
        (Read-Receipt $e 'evening-attempt.json').reason | Should -Be 'AccountChanged'
        Get-RemoteHead $script:Remote | Should -Be $head
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
            (Read-Receipt $e 'evening-attempt.json').reason | Should -Be 'CollectionIncomplete'
            $config = Get-LibrarianConfig $e.Dir
            (Get-LibrarianEveningStatus $config $e.Seat).status | Should -Be 'RetryPending'
            Test-Path (Join-Path $e.Seat 'evening-completed.json') | Should -BeFalse
        } finally { $stream.Dispose() }
    }
}

Describe 'Sync-AnimTeamSessions' {
    It 'removes a stale snapshot and publishes one batch for the latest due date' {
        Clear-Sessions
        Add-Session 'basic'
        Remove-Item $script:IdentityHook -ErrorAction SilentlyContinue
        Set-Profile
        Set-Content $script:NowHook '2026-11-25T22:05:00+00:00'
        $remote = New-Remote
        Set-Remote $remote
        $e = New-Enrollment
        Set-Content $script:StateHook $e.Dir -NoNewline
        Write-LibrarianJson (Join-Path $e.Seat 'evening-completed.json') ([ordered]@{
            enrollmentId = $e.Id; batchDate = '2026-11-22'; status = 'Completed' })
        $stale = Join-Path $e.Seat 'evening-2026-11-23'
        New-LibrarianPrivateDirectory $stale
        New-LibrarianPrivateDirectory (Join-Path $stale 'documents')
        Write-LibrarianJson (Join-Path $stale 'collection.json') @{ layoutVersion = 2; publicationStarted = $true; includeImages = $false }
        $before = Get-RemoteCount $remote
        $out = & (Join-Path $script:Scripts 'Sync-AnimTeamSessions.ps1') -Scheduled | ConvertFrom-Json
        $LASTEXITCODE | Should -BeIn @($null, 0)
        Test-Path $stale | Should -BeFalse
        Get-RemoteCount $remote | Should -Be ($before + 1)
        $out.status | Should -Be 'Completed'
        (Read-Receipt $e 'evening-completed.json').batchDate | Should -Be '2026-11-25'
        (& git "--git-dir=$($remote.Bare)" log -1 --format=%s main) | Should -Be 'Publish evening Claude sessions for 2026-11-25'
    }
}
