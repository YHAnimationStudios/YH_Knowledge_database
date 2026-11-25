#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [AllowEmptyCollection()] [string[]] $SessionId = @(),
    [string] $ExpectedEmail,
    [string] $PinnedUserId,
    [switch] $IdentityOnly,
    [switch] $InventoryOnly,
    [switch] $IncludeImages,
    [string] $ProfileRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LibrarianState.ps1')
. (Join-Path $PSScriptRoot 'TranscriptText.ps1')
. (Join-Path $PSScriptRoot 'ClaudeSession.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTranscript.ps1')
if ($IncludeImages) { . (Join-Path $PSScriptRoot 'LibrarianChatImage.ps1') }
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$invariant = [Globalization.CultureInfo]::InvariantCulture
$identityPinned = $false
$written = [Collections.Generic.List[string]]::new()
$imageSessions = @{}
$imageRoot = $null
$paths = Get-ClaudePaths $ProfileRoot
$dateFormat = "yyyy-MM-ddTHH:mm:ss.FFFFFFF'Z'"

function Get-VerifiedIdentity {
    $found = Read-ClaudeIdentity $paths.Config
    $email = [string]$found.email
    $userId = $found.userId
    if (!(Test-SeatEmailFolder $email) -or $userId -isnot [string] -or [string]::IsNullOrWhiteSpace($userId) -or
        $userId -match '[\x00-\x20\x7f]') {
        throw [UnauthorizedAccessException]::new()
    }
    $email = $email.ToLowerInvariant()
    if (($ExpectedEmail -and $email -ine $ExpectedEmail) -or ($PinnedUserId -and $userId -cne $PinnedUserId) -or
        ($identityPinned -and ($email -cne $account.email -or $userId -cne $account.userId))) {
        throw [UnauthorizedAccessException]::new()
    }
    return @{email=$email;userId=$userId}
}

function Get-SessionKey([string] $Id) {
    $guid = [guid]::Empty
    if (![guid]::TryParseExact($Id,'D',[ref]$guid) -or $guid -eq [guid]::Empty) { throw [FormatException]::new() }
    return $guid.ToString('D')
}

function Test-ReparsePoint([IO.FileSystemInfo] $Item) {
    return [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-SessionInventory {
    # Projects\<project>\<guid>.jsonl only. No recursion, so subagents\ is never read.
    $result = @{sessions=@{};skipped=0}
    if (![IO.Directory]::Exists($paths.Projects)) { return $result }
    foreach ($project in ([IO.DirectoryInfo]::new($paths.Projects)).GetDirectories() | Sort-Object FullName) {
        if (Test-ReparsePoint $project) { $result.skipped++; continue }
        foreach ($file in $project.GetFiles('*.jsonl') | Sort-Object FullName) {
            if ($file.Extension -cne '.jsonl' -or (Test-ReparsePoint $file)) { $result.skipped++; continue }
            try { $id = Get-SessionKey ([IO.Path]::GetFileNameWithoutExtension($file.Name)) }
            catch [FormatException] { $result.skipped++; continue }
            $known = $result.sessions[$id]
            if ($known) {
                # Same session id in two project folders: keep the most recently written file.
                $result.skipped++
                if ($file.LastWriteTimeUtc -le $known.LastWriteTimeUtc) { continue }
            }
            $result.sessions[$id] = $file
        }
    }
    return $result
}

function Get-MessageText($Message) {
    $texts = foreach ($part in $Message.parts) {
        switch ($part.type) {
            'text' { $part.text }
            'command' { "[Command $($part.name)]" }
            'image' { '[Image attachment]' }
        }
    }
    $separator = if ($Message.role -ceq 'Assistant') { "`n`n" } else { "`n" }
    return @($texts) -join $separator
}

function Add-IndentedText($State, [string] $Text, $Redaction) {
    $masked = (Protect-LibrarianTranscriptText $Text $Redaction).Replace("`r`n","`n").Replace("`r","`n")
    # Markdown indented blocks preserve arbitrary pasted fences, HTML and links.
    $null = $State.body.Append('    ' + $masked.Replace("`n","`n    ") + "`n`n")
}

function Add-Message($Message, $State) {
    $when = $Message.time.ToUniversalTime().ToString($dateFormat, $invariant)
    $null = $State.body.Append("## $($Message.role) (sent $when)`n`n")
    $hasImages = $IncludeImages -and @($Message.parts | Where-Object { $_.type -ceq 'image' }).Count -gt 0
    if (!$hasImages) {
        Add-IndentedText $State (Get-MessageText $Message) $null
        return
    }
    $pending = [Collections.Generic.List[string]]::new()
    $redaction = @{}
    foreach ($part in $Message.parts) {
        switch ($part.type) {
            'text' { $pending.Add($part.text) }
            'command' { $pending.Add("[Command $($part.name)]") }
            'image' {
                if ($pending.Count) { Add-IndentedText $State ($pending -join "`n") $redaction; $pending.Clear() }
                Add-LibrarianImageReference $part.block $Message.id $part.ordinal $State
            }
        }
    }
    if ($pending.Count) { Add-IndentedText $State ($pending -join "`n") $redaction }
}

function Read-SessionDocument([string] $Id, [IO.FileInfo] $File, $State) {
    $parsed = Read-ClaudeTranscriptRecords $File.FullName
    $records = $parsed.records
    $branch = Select-ClaudeActiveBranch $records
    $messages = ConvertTo-ClaudeMessages $branch
    $count = 0
    foreach ($message in $messages) { Add-Message $message $State; $count++ }
    $first = $records | Where-Object { $_['timestamp'] -is [string] } | Select-Object -First 1
    $created = if ($first) { ConvertTo-ClaudeTime $first['timestamp'] } else { [datetimeoffset]::new($File.CreationTimeUtc) }
    $updated = if ($branch.Count -and $branch[$branch.Count - 1]['timestamp'] -is [string]) {
        ConvertTo-ClaudeTime $branch[$branch.Count - 1]['timestamp']
    } else { $created }
    $header = [ordered]@{schema=1;updatedAt=$updated.ToUnixTimeSeconds();messages=$count} | ConvertTo-Json -Compress
    $rawTitle = Get-ClaudeSessionTitle $records
    $title = if ([string]::IsNullOrWhiteSpace($rawTitle)) { 'Claude Code session' }
        else {
            $singleLine = (Protect-LibrarianTranscriptText $rawTitle) -replace '[\r\n\t]+', ' '
            [regex]::Replace($singleLine, '[\\`*_{}\[\]()#!<>|~&]', '\$0')
        }
    $dates = "Created (UTC): $($created.ToString($dateFormat,$invariant))`n`nUpdated (UTC): $($updated.ToString($dateFormat,$invariant))"
    $document = "<!-- anim-team-librarian $header -->`n# $title`n`nSession ID: $Id`n`n$dates`n`n" + $State.body.ToString()
    return @{text=$document.TrimEnd("`n") + "`n"; malformed=$parsed.malformedLines}
}

function Get-StageDirectory([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':') -or
        $Path -match '(?:^|[\\/])\.\.(?:[\\/]|$)') { throw [ArgumentException]::new() }
    $directory = [IO.DirectoryInfo]::new($Path)
    if (!$directory.Parent -or [IO.DriveInfo]::new($directory.Root.FullName).DriveType -ne 'Fixed') {
        throw [UnauthorizedAccessException]::new()
    }
    for ($parent=$directory; $parent; $parent=$parent.Parent) {
        if ($parent.Exists -and ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw [UnauthorizedAccessException]::new()
        }
    }
    $null = New-LibrarianPrivateDirectory $directory.FullName
    if (!(Test-LibrarianPrivateAcl $directory.FullName -RequireProtected) -or
        [IO.Directory]::GetFileSystemEntries($directory.FullName).Length) { throw [UnauthorizedAccessException]::new() }
    return $directory.FullName
}

function Write-SessionDocument([string]$Directory,[string]$Id,[string]$Content) {
    $path = [IO.Path]::Combine($Directory, "$Id.md")
    $partial = [IO.Path]::Combine($Directory, "$([guid]::NewGuid()).partial")
    $file = [IO.File]::Open($partial,'CreateNew','Write','None')
    try {
        try {
            $bytes = $utf8.GetBytes($Content)
            $file.Write($bytes,0,$bytes.Length)
        } finally { $file.Dispose() }
        [IO.File]::Move($partial,$path)
        $written.Add($path)
    } finally { if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) } }
}

$stage = 'inputs'
try {
    $requested = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $SessionId) { $null = $requested.Add((Get-SessionKey $key)) }
    $targeted = $PSBoundParameters.ContainsKey('SessionId')
    $stage = 'identity'
    $account = Get-VerifiedIdentity
    $identityPinned = $true
    $result = [ordered]@{email=$account.email;userId=$account.userId;sessions=0;documents=0;skipped=0;failures=0
        malformedLines=0;missing=@();failedSessions=@();lastFailure=$null}
    if ($IncludeImages) {
        foreach ($key in 'imageReferences','imagesAvailable','imagesUnavailable','imageFiles') { $result[$key]=0 }
        $result.imageUnavailableReasons=@{}
    }
    if (!$IdentityOnly) {
        $stage = 'inventory'
        $found = Get-SessionInventory
        $inventory = @{}
        foreach ($id in $found.sessions.Keys) {
            if (!$targeted -or $requested.Contains($id)) { $inventory[$id] = $found.sessions[$id] }
        }
        $result.skipped = $found.skipped
        $result.sessions = $inventory.Count
        $result.missing = @($requested | Where-Object { !$inventory.ContainsKey($_) } | Sort-Object)
        if ($OutputDirectory -and !$InventoryOnly) {
            $stage = 'private-staging'
            $directory = Get-StageDirectory $OutputDirectory
            if ($IncludeImages) { $imageRoot = [IO.Path]::Combine($directory,'images') }
            $stage = 'session-export'
            $failed = [Collections.Generic.List[string]]::new()
            foreach ($id in ($inventory.Keys | Sort-Object)) {
                $state = @{id=$id;body=[Text.StringBuilder]::new()}
                if ($IncludeImages) {
                    $state.assets=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    $state.reasons=@{}
                    $state.available=0
                    $state.imageRoot=$imageRoot
                    $imageSessions[$id]=$state.assets
                }
                try { $doc = Read-SessionDocument $id $inventory[$id] $state }
                catch {
                    $failure = $_
                    if ($IncludeImages) { Remove-LibrarianSessionImages $state; $imageSessions.Remove($id) }
                    $failed.Add($id)
                    $result.lastFailure = @{stage='session-read';reason=$failure.Exception.GetType().Name}
                    continue
                }
                $null = Get-VerifiedIdentity
                try { Write-SessionDocument $directory $id $doc.text }
                catch {
                    $failure = $_
                    if ($IncludeImages) { Remove-LibrarianSessionImages $state; $imageSessions.Remove($id) }
                    $failed.Add($id)
                    $result.lastFailure = @{stage='session-write';reason=$failure.Exception.GetType().Name}
                    continue
                }
                $result.malformedLines += $doc.malformed
                if ($IncludeImages) {
                    $result.imagesAvailable += $state.available
                    $result.imageFiles += $state.assets.Count
                    foreach ($reason in $state.reasons.Keys) {
                        $result.imagesUnavailable += $state.reasons[$reason]
                        $result.imageUnavailableReasons[$reason] += $state.reasons[$reason]
                    }
                }
            }
            $result.documents = $written.Count
            $result.failures = $failed.Count
            $result.failedSessions = $failed.ToArray()
            if ($IncludeImages) {
                $result.imageReferences = $result.imagesAvailable + $result.imagesUnavailable
                if (!$result.imageFiles -and [IO.Directory]::Exists($imageRoot)) { [IO.Directory]::Delete($imageRoot) }
            }
        }
    }
    $stage = 'final-identity'
    $null = Get-VerifiedIdentity
    ConvertTo-Json -InputObject $result -Depth 5 -Compress
} catch {
    $failure = $_
    foreach ($path in $written) { [IO.File]::Delete($path) }
    if ($imageRoot -and [IO.Directory]::Exists($imageRoot)) {
        foreach ($id in $imageSessions.Keys) { Remove-LibrarianSessionImages @{id=$id;assets=$imageSessions[$id];imageRoot=$imageRoot} }
        [IO.Directory]::Delete($imageRoot)
    }
    if ($failure.Exception -is [UnauthorizedAccessException]) { throw $failure.Exception }
    $reason = $failure.Exception.GetType().Name
    $errorInfo = [InvalidOperationException]::new("Collector stopped at $stage ($reason).")
    $errorInfo.Data['stage'] = $stage
    throw $errorInfo
}
