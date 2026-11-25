BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'ClaudeSession' {
    BeforeAll {
        $script:Scripts = New-LibrarianTestPlugin 'anim'
        . (Join-Path $script:Scripts 'ClaudeSession.ps1')
        $script:Uuid = '0b7e4c1a-2d3f-4a5b-8c9d-0e1f2a3b4c5d'
        function script:Write-Config([string]$Name, [string]$Json) {
            $p = Join-Path $TestDrive $Name
            [IO.File]::WriteAllText($p, $Json)
            return $p
        }
    }

    It 'reads email and account id' {
        $p = Write-Config 'ok.json' ('{"oauthAccount":{"emailAddress":"Seat.One@Studio.org","accountUuid":"' + $script:Uuid + '"}}')
        $id = Read-ClaudeIdentity $p
        ($id.email -ceq 'seat.one@studio.org') | Should -BeTrue
        $id.userId | Should -BeExactly $script:Uuid
    }

    It 'rejects a signed-out config' {
        $p = Write-Config 'out.json' '{}'
        { Read-ClaudeIdentity $p } | Should -Throw -ExceptionType ([UnauthorizedAccessException])
    }

    It 'rejects an invalid email folder name' {
        $p = Write-Config 'bad.json' ('{"oauthAccount":{"emailAddress":"a/b@x.org","accountUuid":"' + $script:Uuid + '"}}')
        { Read-ClaudeIdentity $p } | Should -Throw -ExceptionType ([UnauthorizedAccessException])
    }

    It 'rejects an account id with whitespace or empty' {
        foreach ($u in @('', 'a b')) {
            $p = Write-Config 'uuid.json' ('{"oauthAccount":{"emailAddress":"a@x.org","accountUuid":"' + $u + '"}}')
            { Read-ClaudeIdentity $p } | Should -Throw -ExceptionType ([UnauthorizedAccessException])
        }
    }

    It 'retries a transiently unreadable config' {
        $p = Write-Config 'retry.json' '{"oauthAcc'
        $json = '{"oauthAccount":{"emailAddress":"a@x.org","accountUuid":"' + $script:Uuid + '"}}'
        $job = Start-ThreadJob { param($path, $text) Start-Sleep -Milliseconds 300; [IO.File]::WriteAllText($path, $text) } -ArgumentList $p, $json
        try { $id = Read-ClaudeIdentity $p } finally { Wait-Job $job | Out-Null; Remove-Job $job -Force }
        $id.email | Should -BeExactly 'a@x.org'
    }

    It 'throws after about a second when the config stays truncated' {
        $p = Write-Config 'trunc.json' '{"oauthAcc'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        { Read-ClaudeIdentity $p } | Should -Throw
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeGreaterThan 900
        $sw.ElapsedMilliseconds | Should -BeLessThan 3000
    }

    It 'resolves paths under a profile root' {
        $p = Get-ClaudePaths 'C:\Seat'
        $p.Config | Should -Be 'C:\Seat\.claude.json'
        $p.Projects | Should -Be 'C:\Seat\.claude\projects'
        $p.Settings | Should -Be 'C:\Seat\.claude\settings.json'
        (Get-ClaudePaths '').Config | Should -Be (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude.json')
    }
}

Describe 'Test-SeatEmailFolder' {
    BeforeAll {
        $script:Scripts = New-LibrarianTestPlugin 'anim'
        . (Join-Path $script:Scripts 'ClaudeSession.ps1')
    }

    It 'accepts a valid lower-case address' {
        Test-SeatEmailFolder 'seat.one@studio.org' | Should -BeTrue
    }

    It 'rejects <Email>' -ForEach @(
        @{ Email = 'a\b@x.org' }
        @{ Email = 'a/b@x.org' }
        @{ Email = 'CON.x@x.org' }
        @{ Email = 'a@x.org.' }
    ) {
        Test-SeatEmailFolder $Email | Should -BeFalse
    }
}
