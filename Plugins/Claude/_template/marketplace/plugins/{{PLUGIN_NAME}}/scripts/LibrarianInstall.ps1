# The scheduled task must never point into the Claude Code plugin cache (old versions are deleted
# after an update) or at a versioned Microsoft Store PowerShell folder. Everything the task runs
# lives under <state root>\app\<version>\.

function Test-LibrarianVersionedStorePath([string] $Path) {
    # <...>\WindowsApps\<package folder>\... is versioned; <...>\WindowsApps\pwsh.exe is the stable alias.
    return $Path -match '(?i)[\\/]WindowsApps[\\/][^\\/]+[\\/]'
}

function Get-LibrarianPowerShellVersion([string] $Path) {
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    if ($info.ProductMajorPart -ge 1) { return [version]::new($info.ProductMajorPart, $info.ProductMinorPart) }
    # An app-execution alias carries no version resource; ask the runtime itself.
    $text = & $Path -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
    $parsed = $null
    if ($LASTEXITCODE -eq 0 -and [version]::TryParse((($text | Select-Object -First 1) -replace '[-+].*$', ''), [ref]$parsed)) { return $parsed }
    return [version]'0.0'
}

function Select-LibrarianPowerShell([string[]] $Candidates, [string] $Running) {
    foreach ($candidate in @($Candidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or (Test-LibrarianVersionedStorePath $candidate) -or
            -not [IO.File]::Exists($candidate)) { continue }
        try { $version = Get-LibrarianPowerShellVersion $candidate } catch { continue }
        if ($version -ge [version]'7.2') { return $candidate }
    }
    if ($Running -and -not (Test-LibrarianVersionedStorePath $Running)) { return $Running }
    throw 'No stable PowerShell 7.2+ path was found. Install PowerShell 7 (the Store app execution alias or the MSI) and run enrollment again.'
}

function Get-LibrarianPowerShellCandidates {
    $programFiles = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell\7\pwsh.exe'
    $alias = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\WindowsApps\pwsh.exe'
    return @($programFiles, $alias)
}

function Remove-LibrarianAppCopies([string] $StateRoot, [string] $KeepVersion) {
    $app = Join-Path $StateRoot 'app'
    if (-not [IO.Directory]::Exists($app)) { return }
    foreach ($entry in [IO.Directory]::GetFileSystemEntries($app)) {
        $name = [IO.Path]::GetFileName($entry)
        if ($KeepVersion -and $name -ieq $KeepVersion) { continue }
        try {
            if ([IO.Directory]::Exists($entry)) { [IO.Directory]::Delete($entry, $true) } else { [IO.File]::Delete($entry) }
        } catch {
            # A copy may still be running from this folder; the next enrollment prunes it.
            Write-Warning "Could not remove old Librarian copy '$entry': $($_.Exception.Message)"
        }
    }
}

function Install-LibrarianAppCopy([string] $SourceScripts, [string] $StateRoot, [string] $Version) {
    if ($Version -cnotmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$' -or $Version.Contains('..')) { throw "Invalid Librarian version '$Version'." }
    $entry = Join-Path $SourceScripts 'Sync-AnimTeamSessions.ps1'
    if (-not [IO.File]::Exists($entry)) { throw 'Sync-AnimTeamSessions.ps1 was not found next to the enrollment script.' }
    $app = Join-Path $StateRoot 'app'
    $target = Join-Path $app $Version
    New-LibrarianPrivateDirectory $app
    New-LibrarianPrivateDirectory $target
    foreach ($file in [IO.Directory]::GetFiles($SourceScripts, '*.ps1')) {
        $destination = Join-Path $target ([IO.Path]::GetFileName($file))
        $stage = $destination + ".$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::Copy($file, $stage, $true)
            [IO.File]::Move($stage, $destination, $true)
        } finally {
            if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
        }
    }
    Remove-LibrarianAppCopies $StateRoot $Version
    return (Join-Path $target 'Sync-AnimTeamSessions.ps1')
}
