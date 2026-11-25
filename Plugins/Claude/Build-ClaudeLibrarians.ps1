#requires -Version 7.0
<#
Stamps the five Claude team librarian plugins from _template/ and zips each release.
  -OutputRoot  where the <slug>-team-librarian folders go (default: this folder)
  -Team        subset of team slugs (default: all five)
  -Check       render to a temp folder and compare byte for byte with -OutputRoot
               (releases/ ignored); exit 1 and list differing paths on drift
  -NoZip       skip release zips
  -CatalogPath where the repo-root Claude Code catalogue (.claude-plugin/marketplace.json) goes.
               Defaults to the repository root only when -OutputRoot is the default; a build into a
               custom -OutputRoot writes no catalogue unless -CatalogPath is given.
Generated folders and the root catalogue are build output. Edit _template/ only.
#>
[CmdletBinding()]
param(
    [string]$OutputRoot = $PSScriptRoot,
    [string[]]$Team,
    [switch]$Check,
    [switch]$NoZip,
    [string]$TemplateRoot = (Join-Path $PSScriptRoot '_template'),   # test seam
    [string]$CatalogPath
)
$ErrorActionPreference = 'Stop'

$Version = '0.1.1'
$CatalogName = 'yh-team-tools'
$Teams = @(
    @{ Slug = 'anim';          Display = 'Anim Team Librarian';          Folder = 'Animators team';         Id = 'YHAnimTeam';         Member = 'an animator' }
    @{ Slug = '3d-art';        Display = '3D Art Team Librarian';        Folder = '3D art team';            Id = 'YH3DArtTeam';        Member = 'a member of the 3D art team' }
    @{ Slug = 'character-art'; Display = 'Character Art Team Librarian'; Folder = 'Character art team';     Id = 'YHCharacterArtTeam'; Member = 'a member of the Character art team' }
    @{ Slug = 'directors';     Display = 'Directors Team Librarian';     Folder = 'Directors team';         Id = 'YHDirectorsTeam';    Member = 'a member of the Directors team' }
    @{ Slug = 'sound';         Display = 'Sound Team Librarian';         Folder = 'Sound team';             Id = 'YHSoundTeam';        Member = 'a member of the Sound team' }
)
$LeftoverPattern = '\{\{[A-Z_]+\}\}'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if (-not $Team) { $Team = $Teams.Slug }
$unknown = @($Team | Where-Object { $_ -notin $Teams.Slug })
if ($unknown) { throw "Unknown team(s): $($unknown -join ', '). Valid: $($Teams.Slug -join ', ')" }
$defaultOutput = -not $PSBoundParameters.ContainsKey('OutputRoot')
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$TemplateRoot = [IO.Path]::GetFullPath($TemplateRoot)
if (-not $CatalogPath -and $defaultOutput) {
    $CatalogPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.claude-plugin/marketplace.json'
}
if ($CatalogPath) { $CatalogPath = [IO.Path]::GetFullPath($CatalogPath) }

# The repo-root catalogue lets people run `claude plugin marketplace add YHAnimationStudios/YH_Knowledge_database`.
# It always lists all five plugins; sources are relative to the repository root. No version here: plugin.json owns it.
function Get-CatalogText {
    $plugins = foreach ($t in $Teams) {
        $name = "$($t.Slug)-team-librarian"
        [ordered]@{
            name        = $name
            source      = "./Plugins/Claude/$name/marketplace/plugins/$name"
            description = "Evening Claude Code session backup for the $($t.Folder)."
        }
    }
    $catalog = [ordered]@{
        name        = $CatalogName
        owner       = [ordered]@{ name = 'YH Animation Studios' }
        description = 'YH Animation Studios team librarians: evening backups of Claude Code sessions to the team knowledge repository.'
        plugins     = @($plugins)
    }
    ((ConvertTo-Json -InputObject $catalog -Depth 6) -replace "`r`n", "`n") + "`n"
}

function Get-TeamTokens($t) {
    @{
        '{{TEAM_SLUG}}'     = $t.Slug
        '{{DISPLAY_NAME}}'  = $t.Display
        '{{TEAM_FOLDER}}'   = $t.Folder
        '{{TEAM_FOLDER_URL}}' = $t.Folder.Replace(' ', '%20')
        '{{TEAM_ID}}'       = $t.Id
        '{{MEMBER_PHRASE}}' = $t.Member
        '{{PLUGIN_NAME}}'   = "$($t.Slug)-team-librarian"
        '{{MARKETPLACE}}'   = "$($t.Slug)-team-tools"
        '{{VERSION}}'       = $Version
        '{{CATALOG}}'       = $CatalogName
    }
}

function Expand-Tokens([string]$Text, [hashtable]$Tokens) {
    foreach ($k in $Tokens.Keys) { $Text = $Text.Replace($k, $Tokens[$k]) }
    $Text
}

# Renders all of _template/ into $Dest (which is emptied first). Returns nothing.
function Write-TeamTree($t, [string]$Dest) {
    $tokens = Get-TeamTokens $t
    if (Test-Path -LiteralPath $Dest) {   # empty it, but keep releases/ (zips are not template output)
        Get-ChildItem -LiteralPath $Dest -Force | Where-Object Name -ne 'releases' | Remove-Item -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $files = Get-ChildItem -LiteralPath $TemplateRoot -Recurse -File -Force | Sort-Object FullName
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($TemplateRoot.Length).TrimStart('\', '/').Replace([char]92, '/')
        $relOut = Expand-Tokens $rel $tokens
        if ($relOut -match $LeftoverPattern) { throw "Unresolved placeholder in path: $relOut" }
        $text = Expand-Tokens ([IO.File]::ReadAllText($f.FullName, $Utf8NoBom)) $tokens
        if ($text -match $LeftoverPattern) { throw "Unresolved placeholder $($Matches[0]) in $rel" }
        $target = Join-Path $Dest $relOut
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        [IO.File]::WriteAllBytes($target, $Utf8NoBom.GetBytes($text))
    }
}

function Write-ReleaseZip([string]$MarketplaceDir, [string]$ZipPath) {
    Add-Type -AssemblyName System.IO.Compression
    New-Item -ItemType Directory -Path (Split-Path -Parent $ZipPath) -Force | Out-Null
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $zip = [IO.Compression.ZipFile]::Open($ZipPath, 'Create')
    try {
        $base = [IO.Path]::GetFullPath($MarketplaceDir)
        foreach ($f in (Get-ChildItem -LiteralPath $base -Recurse -File -Force | Sort-Object FullName)) {
            $entryName = $f.FullName.Substring($base.Length).TrimStart('\', '/').Replace([char]92, '/')
            $entry = $zip.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $in = [IO.File]::OpenRead($f.FullName); $out = $entry.Open()
            try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function Get-FileMap([string]$Dir, [string]$SkipTop) {
    $map = [ordered]@{}
    if (Test-Path -LiteralPath $Dir) {
        $base = [IO.Path]::GetFullPath($Dir)
        foreach ($f in (Get-ChildItem -LiteralPath $base -Recurse -File -Force | Sort-Object FullName)) {
            $key = $f.FullName.Substring($base.Length).TrimStart([char]92, '/').Replace([char]92, '/')
            if ($SkipTop -and ($key -eq $SkipTop -or $key.StartsWith("$SkipTop/"))) { continue }
            $map[($f.FullName.Substring($base.Length).TrimStart('\', '/').Replace([char]92, '/'))] = $f.FullName
        }
    }
    $map
}

$selected = $Teams | Where-Object { $_.Slug -in $Team }

if ($Check) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('claude-librarian-check-' + [guid]::NewGuid().ToString('N'))
    $drift = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($t in $selected) {
            $name = "$($t.Slug)-team-librarian"
            $expectedDir = Join-Path $tmp $name
            Write-TeamTree $t $expectedDir
            $expected = Get-FileMap $expectedDir
            $actual = Get-FileMap (Join-Path $OutputRoot $name) -SkipTop 'releases'
            foreach ($rel in $expected.Keys) {
                $p = "$name/$rel"
                if (-not $actual.Contains($rel)) { $drift.Add("missing: $p"); continue }
                $a = [IO.File]::ReadAllBytes($expected[$rel]); $b = [IO.File]::ReadAllBytes($actual[$rel])
                if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$a, [byte[]]$b)) { $drift.Add("differs: $p") }
            }
            foreach ($rel in $actual.Keys) {
                if (-not $expected.Contains($rel)) { $drift.Add("extra: $name/$rel") }
            }
        }
        if ($CatalogPath) {
            $want = $Utf8NoBom.GetBytes((Get-CatalogText))
            if (-not (Test-Path -LiteralPath $CatalogPath)) { $drift.Add("missing: $CatalogPath") }
            elseif (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$want, [byte[]][IO.File]::ReadAllBytes($CatalogPath))) {
                $drift.Add("differs: $CatalogPath")
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }
    if ($drift.Count) {
        Write-Output 'Generated output has drifted from _template:'
        $drift | ForEach-Object { Write-Output "  $_" }
        exit 1
    }
    Write-Output 'OK: generated output matches _template.'
    exit 0
}

foreach ($t in $selected) {
    $name = "$($t.Slug)-team-librarian"
    $teamDir = Join-Path $OutputRoot $name
    Write-TeamTree $t $teamDir
    if (-not $NoZip) {
        $current = "$name-$Version.zip"
        $releases = Join-Path $teamDir 'releases'
        if (Test-Path -LiteralPath $releases) {   # one installer per team: drop zips from other versions
            Get-ChildItem -LiteralPath $releases -File -Filter "$name-*.zip" | Where-Object Name -ne $current | Remove-Item -Force
        }
        Write-ReleaseZip (Join-Path $teamDir 'marketplace') (Join-Path $releases $current)
    }
    Write-Output "Built $name"
}

if ($CatalogPath) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $CatalogPath) -Force | Out-Null
    [IO.File]::WriteAllBytes($CatalogPath, $Utf8NoBom.GetBytes((Get-CatalogText)))
    Write-Output "Wrote catalogue $CatalogPath"
}
