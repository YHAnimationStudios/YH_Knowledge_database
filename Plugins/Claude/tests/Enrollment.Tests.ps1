BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Root = Get-TestDriveRoot
    $script:RealRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'YHAnimTeamClaudeLibrarian'
    $script:RealRootExisted = [IO.Directory]::Exists($script:RealRoot)

    # Pure helpers are tested straight from a rendered copy (only TestDrive paths are ever passed in).
    $script:Rendered = New-LibrarianTestPlugin 'anim'
    . (Join-Path $script:Rendered 'LibrarianState.ps1')
    . (Join-Path $script:Rendered 'ClaudeSettings.ps1')
    . (Join-Path $script:Rendered 'LibrarianInstall.ps1')

    # Configure runs child scripts with &, which re-dot-sources helpers and defeats Pester mocks. So the
    # seams are patched into a TestDrive copy of the rendered scripts; shipped scripts are untouched.
    $script:Copy = Join-Path $script:Root 'configure-scripts'
    Copy-Item -LiteralPath $script:Rendered -Destination $script:Copy -Recurse
    $script:StateHook = Join-Path $script:Root 'cfg-state-hook.txt'
    $script:IdentityHook = Join-Path $script:Root 'cfg-identity-hook.json'
    $script:TaskInfoHook = Join-Path $script:Root 'cfg-taskinfo-hook.json'
    $script:TaskCalls = Join-Path $script:Root 'cfg-task-calls.txt'
    $script:RegisterFail = Join-Path $script:Root 'cfg-register-fail.txt'
    $script:ProfileRoot = Join-Path $script:Root 'cfg-profile'
    $script:FakePwsh = Join-Path $script:Root 'fake-runtime\pwsh.exe'
    New-Item -ItemType Directory -Path (Split-Path $script:FakePwsh) -Force | Out-Null
    Set-Content $script:FakePwsh 'x'

    function script:Edit-Copy([string]$Name, [string]$Needle, [string]$Replacement) {
        $file = Join-Path $script:Copy $Name
        $text = [IO.File]::ReadAllText($file)
        if (-not $text.Contains($Needle)) { throw "Seam '$Needle' not found in $Name." }
        [IO.File]::WriteAllText($file, $text.Replace($Needle, $Replacement))
    }
    Edit-Copy 'LibrarianState.ps1' 'function Get-LibrarianStateDirectory {' "function Get-LibrarianStateDirectory {`r`n    return [IO.File]::ReadAllText('$($script:StateHook)')"
    Edit-Copy 'LibrarianState.ps1' 'function Get-LibrarianIdentity {' "function Get-LibrarianIdentity {`r`n    return [IO.File]::ReadAllText('$($script:IdentityHook)') | ConvertFrom-Json"
    Edit-Copy 'ClaudeSession.ps1' "[Environment]::GetFolderPath('UserProfile')" "'$($script:ProfileRoot)'"
    Edit-Copy 'LibrarianInstall.ps1' 'function Get-LibrarianPowerShellCandidates {' "function Get-LibrarianPowerShellCandidates {`r`n    return @('$($script:FakePwsh)')"
    Edit-Copy 'LibrarianInstall.ps1' 'function Get-LibrarianPowerShellVersion([string] $Path) {' "function Get-LibrarianPowerShellVersion([string] `$Path) {`r`n    return [version]'7.5'"
    $taskStub = @"
function Register-LibrarianScheduledTask {
    param([string]`$Runtime,[string]`$EntryPoint,[string]`$EveningTime)
    Add-Content '$($script:TaskCalls)' ('register|' + `$Runtime + '|' + `$EntryPoint + '|' + `$EveningTime)
    if ([IO.File]::Exists('$($script:RegisterFail)')) { throw 'registration failed' }
}
function Unregister-LibrarianScheduledTask { Add-Content '$($script:TaskCalls)' 'unregister' }
function Get-LibrarianScheduledTaskInfo {
    if ([IO.File]::Exists('$($script:TaskInfoHook)')) { return ([IO.File]::ReadAllText('$($script:TaskInfoHook)') | ConvertFrom-Json) }
    return `$null
}
"@
    Set-Content (Join-Path $script:Copy 'LibrarianScheduledTask.ps1') $taskStub
    $syncStub = @"
param([switch]`$Scheduled,[switch]`$CheckOnly,[string]`$EnrollmentId)
@{ status = 'SyncStub'; enrollmentId = `$EnrollmentId } | ConvertTo-Json -Compress
"@
    Set-Content (Join-Path $script:Copy 'Sync-AnimTeamSessions.ps1') $syncStub
    $script:Configure = Join-Path $script:Copy 'Configure-AnimLibrarian.ps1'

    function script:New-CfgState {
        $root = Join-Path $script:Root ('cfg-root-' + [guid]::NewGuid().ToString('N'))
        $state = Join-Path $root 'plugin-state'
        Set-Content $script:StateHook $state -NoNewline
        Remove-Item $script:TaskCalls, $script:TaskInfoHook, $script:RegisterFail -ErrorAction SilentlyContinue
        Remove-Item $script:ProfileRoot -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path (Join-Path $script:ProfileRoot '.claude') -Force | Out-Null
        @{ email = 'artist@example.com'; userId = 'acct-1' } | ConvertTo-Json | Set-Content $script:IdentityHook
        return @{ Root = $root; State = $state; Settings = Join-Path $script:ProfileRoot '.claude\settings.json' }
    }
}

Describe 'Claude transcript retention' {
    It 'raises an unset retention to 3650 and keeps other keys' {
        $path = Join-Path $script:Root 'ret1\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        Set-Content $path '{"model":"opus","permissions":{"allow":["x"]}}'
        $r = Set-ClaudeTranscriptRetention $path
        $r.before | Should -Be 30
        $r.after | Should -Be 3650
        $r.changed | Should -BeTrue
        $json = Get-Content $path -Raw | ConvertFrom-Json
        $json.model | Should -Be 'opus'
        @($json.permissions.allow) | Should -Be @('x')
        $json.cleanupPeriodDays | Should -Be 3650
        @($json.PSObject.Properties.Name) | Should -Be @('model', 'permissions', 'cleanupPeriodDays')
        Get-ClaudeTranscriptRetention $path | Should -Be 3650
    }

    It 'raises a lower value in place without moving keys' {
        $path = Join-Path $script:Root 'ret2\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        Set-Content $path '{"a":1,"cleanupPeriodDays":90,"z":[1,2]}'
        (Set-ClaudeTranscriptRetention $path).before | Should -Be 90
        $json = Get-Content $path -Raw | ConvertFrom-Json
        @($json.PSObject.Properties.Name) | Should -Be @('a', 'cleanupPeriodDays', 'z')
        $json.cleanupPeriodDays | Should -Be 3650
        @($json.z) | Should -Be @(1, 2)
    }

    It 'leaves a higher retention alone' {
        $path = Join-Path $script:Root 'ret3\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        $original = '{"cleanupPeriodDays":5000}'
        [IO.File]::WriteAllText($path, $original)
        $r = Set-ClaudeTranscriptRetention $path
        $r.changed | Should -BeFalse
        $r.before | Should -Be 5000
        $r.after | Should -Be 5000
        [IO.File]::ReadAllText($path) | Should -Be $original
    }

    It 'creates settings.json when absent' {
        $path = Join-Path $script:Root 'ret4\.claude\settings.json'
        Get-ClaudeTranscriptRetention $path | Should -Be 30
        $r = Set-ClaudeTranscriptRetention $path
        $r.changed | Should -BeTrue
        (Get-Content $path -Raw | ConvertFrom-Json).cleanupPeriodDays | Should -Be 3650
        @(Get-ChildItem (Split-Path $path) -Filter '*.tmp').Count | Should -Be 0
    }

    It 'never overwrites an unreadable settings file' {
        $path = Join-Path $script:Root 'ret5\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, '{ not json')
        { Set-ClaudeTranscriptRetention $path } | Should -Throw
        [IO.File]::ReadAllText($path) | Should -Be '{ not json'
    }

    It 'treats <Raw> as 5000 and leaves it alone' -ForEach @(@{ Raw = '5000.0' }, @{ Raw = '"5000"' }, @{ Raw = '5000' }) {
        $path = Join-Path $script:Root ('ret7-' + [guid]::NewGuid().ToString('N') + '\settings.json')
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        $original = '{"cleanupPeriodDays":' + $Raw + '}'
        [IO.File]::WriteAllText($path, $original)
        Get-ClaudeTranscriptRetention $path | Should -Be 5000
        $r = Set-ClaudeTranscriptRetention $path
        $r.changed | Should -BeFalse
        $r.after | Should -Be 5000
        [IO.File]::ReadAllText($path) | Should -Be $original
    }

    It 'raises a numeric string below the minimum' {
        $path = Join-Path $script:Root 'ret8\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        Set-Content $path '{"cleanupPeriodDays":"90.0"}'
        $r = Set-ClaudeTranscriptRetention $path
        $r.before | Should -Be 90
        $r.changed | Should -BeTrue
        (Get-Content $path -Raw | ConvertFrom-Json).cleanupPeriodDays | Should -Be 3650
    }

    It 'reports 30 when the key is absent' {
        $path = Join-Path $script:Root 'ret6\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        Set-Content $path '{"model":"opus"}'
        Get-ClaudeTranscriptRetention $path | Should -Be 30
    }
}

Describe 'Install-LibrarianAppCopy' {
    It 'copies scripts to a versioned app folder and prunes older versions' {
        $source = Join-Path $script:Root 'app-src'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        foreach ($n in 'Sync-AnimTeamSessions.ps1', 'Other.ps1') { Set-Content (Join-Path $source $n) "# $n" }
        Set-Content (Join-Path $source 'notes.txt') 'skip me'
        $stateRoot = Join-Path $script:Root 'app-root'
        New-Item -ItemType Directory -Path $stateRoot | Out-Null

        $first = Install-LibrarianAppCopy $source $stateRoot '0.1.0'
        $first | Should -BeLike '*app\0.1.0\Sync-AnimTeamSessions.ps1'
        Test-Path (Join-Path $stateRoot 'app\0.1.0\Other.ps1') | Should -BeTrue
        Test-Path (Join-Path $stateRoot 'app\0.1.0\notes.txt') | Should -BeFalse

        $second = Install-LibrarianAppCopy $source $stateRoot '0.1.1'
        $second | Should -BeLike '*app\0.1.1\Sync-AnimTeamSessions.ps1'
        Test-Path $second | Should -BeTrue
        # Install never prunes; the caller does so once the task points at the new copy.
        @(Get-ChildItem (Join-Path $stateRoot 'app') | Select-Object -ExpandProperty Name | Sort-Object) | Should -Be @('0.1.0', '0.1.1')
        Remove-LibrarianAppCopies $stateRoot '0.1.1'
        @(Get-ChildItem (Join-Path $stateRoot 'app') | Select-Object -ExpandProperty Name) | Should -Be @('0.1.1')
        Test-LibrarianPrivateAcl (Join-Path $stateRoot 'app\0.1.1') -RequireProtected | Should -BeTrue
    }

    It 'reinstalls the same version over itself' {
        $source = Join-Path $script:Root 'app-src'
        $stateRoot = Join-Path $script:Root 'app-root'
        Set-Content (Join-Path $source 'Other.ps1') '# changed'
        $null = Install-LibrarianAppCopy $source $stateRoot '0.1.1'
        Get-Content (Join-Path $stateRoot 'app\0.1.1\Other.ps1') -Raw | Should -Match 'changed'
    }

    It 'rejects a version that could escape the app folder' {
        { Install-LibrarianAppCopy (Join-Path $script:Root 'app-src') (Join-Path $script:Root 'app-root') '..\x' } | Should -Throw
    }

    It 'removes every copy when no version is kept' {
        $stateRoot = Join-Path $script:Root 'app-root'
        Remove-LibrarianAppCopies $stateRoot $null
        @(Get-ChildItem (Join-Path $stateRoot 'app')).Count | Should -Be 0
    }
}

Describe 'Remove-LibrarianAppCopies link safety' {
    It 'refuses to delete through an app folder that is a junction' {
        $stateRoot = Join-Path $script:Root 'junc-root'
        $outside = Join-Path $script:Root 'junc-outside'
        New-Item -ItemType Directory -Path $stateRoot, (Join-Path $outside 'victimdir') -Force | Out-Null
        Set-Content (Join-Path $outside 'victimdir\keep.txt') 'x'
        New-Item -ItemType Junction -Path (Join-Path $stateRoot 'app') -Target $outside | Out-Null
        { Remove-LibrarianAppCopies $stateRoot $null } | Should -Throw
        Test-Path (Join-Path $outside 'victimdir\keep.txt') | Should -BeTrue
    }

    It 'removes a junction child as a link without touching its target' {
        $stateRoot = Join-Path $script:Root 'junc2-root'
        $outside = Join-Path $script:Root 'junc2-outside'
        New-Item -ItemType Directory -Path $stateRoot, (Join-Path $outside 'victimdir') -Force | Out-Null
        Set-Content (Join-Path $outside 'victimdir\keep.txt') 'x'
        New-LibrarianPrivateDirectory (Join-Path $stateRoot 'app')
        New-Item -ItemType Junction -Path (Join-Path $stateRoot 'app\0.0.1') -Target $outside | Out-Null
        Remove-LibrarianAppCopies $stateRoot $null
        Test-Path (Join-Path $stateRoot 'app\0.0.1') | Should -BeFalse
        Test-Path (Join-Path $outside 'victimdir\keep.txt') | Should -BeTrue
    }
}

Describe 'Select-LibrarianPowerShell' {
    BeforeAll {
        $script:Pf = Join-Path $script:Root 'sel\Program Files\PowerShell\7\pwsh.exe'
        $script:Alias = Join-Path $script:Root 'sel\Local\Microsoft\WindowsApps\pwsh.exe'
        $script:Versioned = Join-Path $script:Root 'sel\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe'
        $script:Plain = Join-Path $script:Root 'sel\Other\pwsh.exe'
        foreach ($p in $script:Pf, $script:Alias, $script:Versioned, $script:Plain) {
            New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
            Set-Content $p 'x'
        }
    }
    BeforeEach { Mock Get-LibrarianPowerShellVersion { [version]'7.5' } }

    It 'never returns a versioned WindowsApps running path when the alias exists' {
        Select-LibrarianPowerShell @(($script:Pf + '.missing'), $script:Alias) $script:Versioned | Should -Be $script:Alias
    }

    It 'skips a versioned WindowsApps candidate' {
        Select-LibrarianPowerShell @($script:Versioned, $script:Alias) $script:Plain | Should -Be $script:Alias
    }

    It 'prefers the Program Files install over the alias' {
        Select-LibrarianPowerShell @($script:Pf, $script:Alias) $script:Versioned | Should -Be $script:Pf
    }

    It 'falls back to a stable running path' {
        Select-LibrarianPowerShell @(($script:Pf + '.missing')) $script:Plain | Should -Be $script:Plain
    }

    It 'throws instead of returning a versioned path when nothing stable exists' {
        { Select-LibrarianPowerShell @(($script:Pf + '.missing')) $script:Versioned } | Should -Throw
    }

    It 'skips a candidate older than 7.2' {
        Mock Get-LibrarianPowerShellVersion { [version]'7.1' } -ParameterFilter { $Path -eq $script:Pf }
        Select-LibrarianPowerShell @($script:Pf, $script:Alias) $script:Versioned | Should -Be $script:Alias
    }

    It 'treats only package folders under WindowsApps as versioned' {
        Test-LibrarianVersionedStorePath $script:Versioned | Should -BeTrue
        Test-LibrarianVersionedStorePath $script:Alias | Should -BeFalse
    }
}

Describe 'Configure-AnimLibrarian' {
    It 'seams point only at TestDrive locations' {
        (Get-Content (Join-Path $script:Copy 'LibrarianState.ps1') -Raw) | Should -Match ([regex]::Escape($script:StateHook))
        (Get-Content (Join-Path $script:Copy 'ClaudeSession.ps1') -Raw) | Should -Match ([regex]::Escape($script:ProfileRoot))
        (Get-Content (Join-Path $script:Copy 'LibrarianScheduledTask.ps1') -Raw) | Should -Not -Match 'Schedule\.Service'
    }

    It 'reports ScriptMissing when the entry script is gone' {
        $s = New-CfgState
        & $script:Configure -EnableAccountSync | Out-Null
        @{ taskName = 't'; state = 'Ready'; entryScriptExists = $false } | ConvertTo-Json | Set-Content $script:TaskInfoHook
        $status = (& $script:Configure -Status) | ConvertFrom-Json
        $status.status | Should -Be 'ScriptMissing'
        $status.transcriptRetentionDays | Should -Be 3650
    }

    It 'keeps the normal status when the entry script exists' {
        $s = New-CfgState
        & $script:Configure -EnableAccountSync | Out-Null
        @{ taskName = 't'; state = 'Ready'; entryScriptExists = $true } | ConvertTo-Json | Set-Content $script:TaskInfoHook
        $status = (& $script:Configure -Status) | ConvertFrom-Json
        $status.status | Should -Not -Be 'ScriptMissing'
        $status.scheduledTask.entryScriptExists | Should -BeTrue
    }

    It 'enrolls against the stable app copy and raises retention' {
        $s = New-CfgState
        Set-Content $s.Settings '{"model":"opus"}'
        $out = (& $script:Configure -EnableAccountSync -EveningTime '21:30') | ConvertFrom-Json
        $out.status | Should -Be 'SyncStub'
        $call = (Get-Content $script:TaskCalls) | Where-Object { $_ -like 'register|*' }
        $call | Should -Be ('register|' + $script:FakePwsh + '|' + (Join-Path $s.Root 'app\0.1.0\Sync-AnimTeamSessions.ps1') + '|21:30')
        Test-Path (Join-Path $s.Root 'app\0.1.0\Sync-AnimTeamSessions.ps1') | Should -BeTrue
        $settings = Get-Content $s.Settings -Raw | ConvertFrom-Json
        $settings.cleanupPeriodDays | Should -Be 3650
        $settings.model | Should -Be 'opus'
    }

    It 'skips retention with -KeepTranscriptRetention' {
        $s = New-CfgState
        $original = '{"model":"opus"}'
        [IO.File]::WriteAllText($s.Settings, $original)
        & $script:Configure -EnableAccountSync -KeepTranscriptRetention | Out-Null
        [IO.File]::ReadAllText($s.Settings) | Should -Be $original
        (Get-Content $script:TaskCalls) | Should -Contain ('register|' + $script:FakePwsh + '|' + (Join-Path $s.Root 'app\0.1.0\Sync-AnimTeamSessions.ps1') + '|22:00')
    }

    It 'does not create settings.json with -KeepTranscriptRetention when absent' {
        $s = New-CfgState
        & $script:Configure -EnableAccountSync -KeepTranscriptRetention | Out-Null
        Test-Path $s.Settings | Should -BeFalse
    }

    It 'prunes older app copies only after registration succeeds' {
        $s = New-CfgState
        New-Item -ItemType Directory -Path $s.Root -Force | Out-Null
        New-LibrarianPrivateDirectory (Join-Path $s.Root 'app')
        New-Item -ItemType Directory -Path (Join-Path $s.Root 'app\0.0.9') -Force | Out-Null
        & $script:Configure -EnableAccountSync | Out-Null
        Test-Path (Join-Path $s.Root 'app\0.0.9') | Should -BeFalse
        Test-Path (Join-Path $s.Root 'app\0.1.0\Sync-AnimTeamSessions.ps1') | Should -BeTrue
    }

    It 'keeps the previous app copy when registration fails during an upgrade' {
        $s = New-CfgState
        $old = Join-Path $s.Root 'app\0.0.9'
        New-Item -ItemType Directory -Path $s.Root -Force | Out-Null
        New-LibrarianPrivateDirectory (Join-Path $s.Root 'app')
        New-Item -ItemType Directory -Path $old -Force | Out-Null
        Set-Content (Join-Path $old 'Sync-AnimTeamSessions.ps1') '# old'
        Set-Content $script:RegisterFail 'fail'
        { & $script:Configure -EnableAccountSync } | Should -Throw '*registration failed*'
        Test-Path (Join-Path $old 'Sync-AnimTeamSessions.ps1') | Should -BeTrue
    }

    It 'removes the app copies and unregisters on disable' {
        $s = New-CfgState
        & $script:Configure -EnableAccountSync | Out-Null
        Test-Path (Join-Path $s.Root 'app\0.1.0') | Should -BeTrue
        $out = (& $script:Configure -DisableAccountSync) | ConvertFrom-Json
        $out.status | Should -Be 'Disabled'
        (Get-Content $script:TaskCalls) | Should -Contain 'unregister'
        @(Get-ChildItem (Join-Path $s.Root 'app')).Count | Should -Be 0
    }

    It 'refuses another account without -ReplaceEnrollment and mentions Claude' {
        $s = New-CfgState
        & $script:Configure -EnableAccountSync | Out-Null
        @{ email = 'other@example.com'; userId = 'acct-2' } | ConvertTo-Json | Set-Content $script:IdentityHook
        { & $script:Configure -EnableAccountSync } | Should -Throw '*another Claude account*'
    }

    It 'never touched the real state root' {
        if (-not $script:RealRootExisted) { Test-Path $script:RealRoot | Should -BeFalse }
    }
}
