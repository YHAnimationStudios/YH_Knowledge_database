# Shared helpers for the Claude librarian Pester tests. Dot-source from BeforeAll.

$script:ClaudeRoot = Split-Path -Parent $PSScriptRoot
$script:BuildScript = Join-Path $script:ClaudeRoot 'Build-ClaudeLibrarians.ps1'

function Get-TestDriveRoot {
    if ($TestDrive) { return $TestDrive }
    return (Get-PSDrive TestDrive).Root
}

function New-LibrarianTestPlugin {
    # Builds one team into the Pester test drive (no zip) and returns the rendered scripts folder.
    param([string]$Team = 'anim')
    $out = Join-Path (Get-TestDriveRoot) ('plugin-' + [guid]::NewGuid().ToString('N'))
    & $script:BuildScript -OutputRoot $out -Team $Team -NoZip | Out-Null
    $name = "$Team-team-librarian"
    return (Join-Path $out "$name/marketplace/plugins/$name/scripts")
}
