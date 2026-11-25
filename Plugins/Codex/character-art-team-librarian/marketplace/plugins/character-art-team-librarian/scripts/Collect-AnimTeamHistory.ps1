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
    [AllowEmptyCollection()] [string[]] $TrackedTurns = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LibrarianState.ps1')
. (Join-Path $PSScriptRoot 'TranscriptText.ps1')
. (Join-Path $PSScriptRoot 'CodexSession.ps1')
if ($IncludeImages) { . (Join-Path $PSScriptRoot 'LibrarianChatImage.ps1') }
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$invariant = [Globalization.CultureInfo]::InvariantCulture
$server = $null
$requestId = 0
$identityPinned = $false
$accountChanged = $false
$rpcMethod = $null
$rpcCode = $null
$rpcInFlight = $false
$jsonOptions = @{}
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind = 'String' }
$written = [Collections.Generic.List[string]]::new()
$imageSessions = @{}
$imageRoot = $null
$sources = @('cli','vscode','exec','appServer','unknown')

function Get-VerifiedIdentity {
    try { $reply = Invoke-CodexRpc 'account/read' @{refreshToken=$false} }
    catch {
        if (!$identityPinned -or !$rpcInFlight -or $accountChanged) { throw }
        Close-CodexSession
        Open-CodexSession
        $reply = Invoke-CodexRpc 'account/read' @{refreshToken=$false}
    }
    $email = $reply.account.email
    $userId = $reply.userId
    if ($accountChanged -or $reply.account.type -cne 'chatgpt' -or !(Test-CodexEmailFolder $email) -or
        $userId -isnot [string] -or [string]::IsNullOrWhiteSpace($userId) -or $userId -match '[\x00-\x20\x7f]') {
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

function Get-SessionTime($Value, [switch] $Milliseconds) {
    if ($null -eq $Value) { throw [FormatException]::new() }
    if ($Value -is [datetime]) { return [datetimeoffset]::new($Value).ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [long] -or $Value -is [int] -or $Value -match '^-?[0-9]+$') {
        if ($Milliseconds) { return [datetimeoffset]::FromUnixTimeMilliseconds([long]$Value) }
        return [datetimeoffset]::FromUnixTimeSeconds([long]$Value)
    }
    return [datetimeoffset]::Parse($Value, $invariant, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
}

function Get-UserText($Part) {
    if (!$Part.text_elements) { return [string]$Part.text }
    $bytes = $utf8.GetBytes([string]$Part.text)
    $position = 0
    $text = [Text.StringBuilder]::new()
    foreach ($element in ($Part.text_elements | Sort-Object { $_.byteRange.start })) {
        $range = $element.byteRange
        if ($null -eq $range.start -or $null -eq $range.end -or $range.start -lt $position -or
            $range.end -lt $range.start -or $range.end -gt $bytes.Length) { throw [IO.InvalidDataException]::new() }
        $null = $text.Append($utf8.GetString($bytes,$position,$range.start-$position))
        $null = $text.Append('[embedded content]')
        $position = $range.end
    }
    return $text.Append($utf8.GetString($bytes,$position,$bytes.Length-$position)).ToString()
}

function Add-TextMessage($Item, $TurnId, $Time, [string]$TimeLabel, $State) {
    switch ($Item.type) {
        'userMessage' {
            $role = 'User'
            $parts = @(foreach ($part in $Item.content) {
                switch ($part.type) {
                    'text' { Get-UserText $part }
                    { $_ -in @('image','localImage') } { '[Image attachment]' }
                    { $_ -in @('audio','localAudio') } { '[Audio attachment]' }
                    'skill' { '[Skill reference]' }
                    'mention' { '[Mention]' }
                }
            })
            $text = $parts -join "`n"
        }
        'agentMessage' {
            $display = $Item.moderation.display.mode
            if (($display -and $display -cne 'show') -or ($Item.moderation.moderated -and !$display)) { return }
            $role = 'Assistant'
            $text = [string]$Item.text
        }
        default { return }
    }
    if (!$text) { return }
    if (!$TurnId -or !$Item.id) { throw [IO.InvalidDataException]::new() }
    if (!$State.seen.Add([Tuple[string,string]]::new($TurnId,$Item.id))) { return }
    $when = if ($Time) { " ($TimeLabel " + $Time.ToString("yyyy-MM-ddTHH:mm:ss.FFFFFFF'Z'", $invariant) + ')' }
    $text = (Protect-LibrarianTranscriptText $text).Replace("`r`n","`n").Replace("`r","`n")
    # Markdown indented blocks preserve arbitrary pasted fences, HTML and links.
    $literal = '    ' + $text.Replace("`n", "`n    ")
    $null = $State.body.Append("## $role$when`n`n$literal`n`n")
}

function Add-VisibleMessage($Item, $TurnId, $Time, [string]$TimeLabel, $State, $ImageTime) {
    $hasImages = $false
    if ($IncludeImages) {
        if ($Item.type -ceq 'userMessage') {
            foreach ($part in $Item.content) { if ($part.type -cin @('image','localImage')) { $hasImages=$true; break } }
        } elseif ($Item.type -ceq 'imageGeneration' -and $Item.status -ceq 'completed' -and !$Item.failure) {
            $hasImages=$true
        }
        if ($hasImages -and !$State.classic) {
            # Preserve the exact 0.3 projection for a provable, same-timestamp first migration.
            $State.classic = @{seen=[Collections.Generic.HashSet[Tuple[string,string]]]::new($State.seen)
                body=[Text.StringBuilder]::new($State.body.ToString())}
        }
        if ($State.classic) { Add-TextMessage $Item $TurnId $Time $TimeLabel $State.classic }
    }
    if (!$hasImages) { Add-TextMessage $Item $TurnId $Time $TimeLabel $State; return }
    if (!$TurnId -or !$Item.id) { throw [IO.InvalidDataException]::new() }
    $generated = $Item.type -ceq 'imageGeneration'
    if ($generated) {
        if (!$State.generated.Add([Tuple[string,string]]::new($TurnId,$Item.id))) { return }
        $role = 'Assistant'
    } else {
        if (!$State.seen.Add([Tuple[string,string]]::new($TurnId,$Item.id))) { return }
        $role = 'User'
    }
    $when = if ($Time) { " ($TimeLabel " + $Time.ToString("yyyy-MM-ddTHH:mm:ss.FFFFFFF'Z'", $invariant) + ')' }
    $null = $State.body.Append("## $role$when`n`n")
    if ($generated) {
        Add-LibrarianImageReference $Item $TurnId $Item.id 0 $ImageTime $State
        return
    }
    $pending = [Collections.Generic.List[string]]::new()
    $redaction = @{}
    $ordinal = 0
    foreach ($part in $Item.content) {
        switch -CaseSensitive ($part.type) {
            'text' { $pending.Add((Get-UserText $part)) }
            { $_ -cin @('audio','localAudio') } { $pending.Add('[Audio attachment]') }
            'skill' { $pending.Add('[Skill reference]') }
            'mention' { $pending.Add('[Mention]') }
            { $_ -cin @('image','localImage') } {
                Add-ImageMessageText $State $pending $redaction
                Add-LibrarianImageReference $part $TurnId $Item.id $ordinal $ImageTime $State
                $ordinal++
            }
        }
    }
    Add-ImageMessageText $State $pending $redaction
}

function Add-ImageMessageText($State, $Parts, $Redaction) {
    if (!$Parts.Count) { return }
    $text = (Protect-LibrarianTranscriptText ($Parts -join "`n") $Redaction).Replace("`r`n","`n").Replace("`r","`n")
    $null = $State.body.Append('    ' + $text.Replace("`n","`n    ") + "`n`n")
    $Parts.Clear()
}

function Read-SessionDocument($Thread, $RequestedTurns, $State) {
    if ($IncludeImages) {
        $State.generated=[Collections.Generic.HashSet[Tuple[string,string]]]::new()
    }
    $terminal = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $id = $Thread.id
    if ($Thread.historyMode -eq 'paginated') {
        # Snapshot terminal status first, so Stop cannot acknowledge a turn that
        # only finished after the captured item pages.
        if ($RequestedTurns -and $RequestedTurns.Count) {
            Get-CodexRows 'thread/turns/list' @{threadId=$id;sortDirection='asc';itemsView='notLoaded';limit=50} |
                ForEach-Object {
                    if ($_.status -in @('completed','failed','interrupted') -and $RequestedTurns.Contains($_.id)) {
                        $null = $terminal.Add("$id|$($_.id)")
                    }
                }
        }
        Get-CodexRows 'thread/items/list' @{threadId=$id;sortDirection='asc';limit=50} | ForEach-Object {
            $time = $null
            $timeLabel = 'started'
            if ($null -ne $_.startedAtMs) { $time = Get-SessionTime $_.startedAtMs -Milliseconds }
            elseif ($null -ne $_.completedAtMs) {
                $time = Get-SessionTime $_.completedAtMs -Milliseconds
                $timeLabel = 'completed'
            }
            $imageTime = $time
            if ($IncludeImages -and $_.item.type -ceq 'imageGeneration' -and $null -ne $_.completedAtMs) {
                $imageTime = Get-SessionTime $_.completedAtMs -Milliseconds
            }
            Add-VisibleMessage $_.item $_.turnId $time $timeLabel $state $imageTime
        }
    } elseif (!$Thread.historyMode -or $Thread.historyMode -eq 'legacy') {
        Get-CodexRows 'thread/turns/list' @{threadId=$id;sortDirection='asc';itemsView='full';limit=10} |
            ForEach-Object {
                $turn = $_
                if ($turn.itemsView -and $turn.itemsView -ne 'full') { throw [IO.InvalidDataException]::new() }
                if ($turn.items -isnot [array]) { throw [IO.InvalidDataException]::new() }
                $time = if ($null -ne $turn.startedAt) { Get-SessionTime $turn.startedAt }
                foreach ($item in $turn.items) {
                    $imageTime=$time
                    if ($IncludeImages -and $item.type -cin 'userMessage','imageGeneration') {
                        if ($item.type -ceq 'imageGeneration' -and $null -ne $item.completedAtMs) { $imageTime = Get-SessionTime $item.completedAtMs -Milliseconds }
                        elseif ($null -ne $item.startedAtMs) { $imageTime = Get-SessionTime $item.startedAtMs -Milliseconds }
                        elseif ($item.type -ceq 'imageGeneration' -and $null -ne $turn.completedAt) { $imageTime = Get-SessionTime $turn.completedAt }
                    }
                    Add-VisibleMessage $item $turn.id $time 'turn started' $state $imageTime
                }
                if ($RequestedTurns -and $RequestedTurns.Contains($turn.id) -and $turn.status -in @('completed','failed','interrupted')) {
                    $null = $terminal.Add("$id|$($turn.id)")
                }
            }
    } else { throw [NotSupportedException]::new() }
    $created = Get-SessionTime $Thread.createdAt
    $updated = Get-SessionTime $Thread.updatedAt
    $header = [ordered]@{schema=1;updatedAt=$updated.ToUnixTimeSeconds();messages=$state.seen.Count} | ConvertTo-Json -Compress
    $title = if ([string]::IsNullOrWhiteSpace($Thread.name)) { 'Codex session' }
        else {
            $singleLine = (Protect-LibrarianTranscriptText $Thread.name) -replace '[\r\n\t]+', ' '
            [regex]::Replace($singleLine, '[\\`*_{}\[\]()#!<>|~&]', '\$0')
        }
    $status = if ($Thread.archived) { 'Archived' } else { 'Active' }
    $dateFormat = "yyyy-MM-ddTHH:mm:ss.FFFFFFF'Z'"
    $dates = "Created (UTC): $($created.ToString($dateFormat,$invariant))`n`nUpdated (UTC): $($updated.ToString($dateFormat,$invariant))"
    $documentHead = "`n# $title`n`nSession ID: $id`n`nStatus: $status`n`n$dates`n`n"
    if ($State.classic) {
        $classicHeader = [ordered]@{schema=1;updatedAt=$updated.ToUnixTimeSeconds();messages=$State.classic.seen.Count} | ConvertTo-Json -Compress
        $classicText = ("<!-- anim-team-librarian $classicHeader -->" + $documentHead + $State.classic.body.ToString()).TrimEnd("`n") + "`n"
        $gitInput = "blob $($utf8.GetByteCount($classicText))`0" + $classicText
        $legacyOid = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($utf8.GetBytes($gitInput))).ToLowerInvariant()
        $header = [ordered]@{schema=1;updatedAt=$updated.ToUnixTimeSeconds();messages=$state.seen.Count;legacyOid=$legacyOid} | ConvertTo-Json -Compress
    }
    $document = "<!-- anim-team-librarian $header -->" + $documentHead + $state.body.ToString()
    return @{text=$document.TrimEnd("`n") + "`n"; observed=$terminal}
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
    $tracking = @{}
    foreach ($key in $TrackedTurns) {
        if ($key -notmatch '^([^|]+)\|([a-zA-Z0-9_.-]{1,160})$') { throw [ArgumentException]::new() }
        $id = Get-SessionKey $Matches[1]
        $turn = $Matches[2]
        if (!$tracking.ContainsKey($id)) { $tracking[$id] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
        $null = $tracking[$id].Add($turn)
    }
    $stage = 'app-server'
    Open-CodexSession
    $stage = 'identity'
    $account = Get-VerifiedIdentity
    $identityPinned = $true
    $result = [ordered]@{email=$account.email;userId=$account.userId;activeThreads=0;archivedThreads=0
        documents=0;skipped=0;failures=0;missing=@();failedSessions=@();observedTurns=@();lastFailure=$null}
    if ($IncludeImages) {
        foreach ($key in 'imageReferences','imagesAvailable','imagesUnavailable','imageFiles') { $result[$key]=0 }
        $result.imageUnavailableReasons=@{}
    }
    if (!$IdentityOnly) {
        $stage = 'account-inventory'
        $inventory = @{}
        $wanted = @($requested | Sort-Object)
        $scanCount = if ($targeted) { $wanted.Length } else { 1 }
        for ($i=0; $i -lt $scanCount; $i+=100) {
            foreach ($archived in @($false,$true)) {
                $filters = @{archived=$archived;sourceKinds=$sources;currentAccountOnly=$true;modelProviders=@()
                    useStateDbOnly=$false;sortKey='created_at';limit=50}
                if ($targeted) { $filters.includedThreadIds = @($wanted[$i..([math]::Min($i+99,$wanted.Length-1))]) }
                Get-CodexRows 'thread/list' $filters | ForEach-Object {
                    $row = $_
                    if ($row.ephemeral -isnot [bool] -or $row.ephemeral -or $row.parentThreadId -or $row.agentRole -or
                        $row.agentNickname -or (!$row.source) -or
                        ($row.source -is [string] -and $row.source -notin $sources) -or
                        ($row.source -isnot [string] -and !$row.source.custom)) {
                        $result.skipped++
                        return
                    }
                    try { $id = Get-SessionKey $row.id }
                    catch [FormatException] { $result.skipped++; return }
                    if ($targeted -and !$requested.Contains($id)) { throw [IO.InvalidDataException]::new() }
                    $inventory[$id] = @{id=$id;archived=$archived;historyMode=$row.historyMode;createdAt=$row.createdAt
                        updatedAt=$row.updatedAt;name=$row.name}
                }
            }
        }
        $null = Get-VerifiedIdentity
        $result.activeThreads = @($inventory.Values | Where-Object { !$_.archived }).Count
        $result.archivedThreads = $inventory.Count - $result.activeThreads
        $result.missing = @($wanted | Where-Object { !$inventory.ContainsKey($_) })
        if ($OutputDirectory -and !$InventoryOnly) {
            $stage = 'private-staging'
            $directory = Get-StageDirectory $OutputDirectory
            if ($IncludeImages) { $imageRoot = [IO.Path]::Combine($directory,'images') }
            $stage = 'session-export'
            $failed = [Collections.Generic.List[string]]::new()
            $observed = [Collections.Generic.List[string]]::new()
            foreach ($id in ($inventory.Keys | Sort-Object)) {
                $null = Get-VerifiedIdentity
                $state = @{id=$id;seen=[Collections.Generic.HashSet[Tuple[string,string]]]::new()
                    body=[Text.StringBuilder]::new()}
                if ($IncludeImages) {
                    $state.assets=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    $state.reasons=@{}
                    $state.available=0
                    $imageSessions[$id]=$state.assets
                }
                try { $doc = Read-SessionDocument $inventory[$id] $tracking[$id] $state }
                catch {
                    $failure = $_
                    if ($IncludeImages) { Remove-LibrarianSessionImages $state; $imageSessions.Remove($id) }
                    $failed.Add($id)
                    $result.lastFailure = @{stage='session-read';rpcMethod=$rpcMethod;rpcCode=$rpcCode;reason=$failure.Exception.GetType().Name}
                    if ($rpcInFlight) {
                        Close-CodexSession
                        Open-CodexSession
                        # Retain the inventory's original identity pin across the new connection.
                        $null = Get-VerifiedIdentity
                    }
                    continue
                }
                $null = Get-VerifiedIdentity
                try { Write-SessionDocument $directory $id $doc.text }
                catch {
                    $failure = $_
                    if ($IncludeImages) { Remove-LibrarianSessionImages $state; $imageSessions.Remove($id) }
                    $failed.Add($id)
                    $result.lastFailure = @{stage='session-write';rpcMethod=$null;rpcCode=$null;reason=$failure.Exception.GetType().Name}
                    continue
                }
                if ($IncludeImages) {
                    $result.imagesAvailable += $state.available
                    $result.imageFiles += $state.assets.Count
                    foreach ($reason in $state.reasons.Keys) {
                        $result.imagesUnavailable += $state.reasons[$reason]
                        $result.imageUnavailableReasons[$reason] += $state.reasons[$reason]
                    }
                }
                foreach ($key in $doc.observed) { $observed.Add($key) }
            }
            $result.documents = $written.Count
            $result.failures = $failed.Count
            $result.failedSessions = $failed.ToArray()
            $result.observedTurns = @($observed | Sort-Object)
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
        foreach ($id in $imageSessions.Keys) { Remove-LibrarianSessionImages @{id=$id;assets=$imageSessions[$id]} }
        [IO.Directory]::Delete($imageRoot)
    }
    $reason = $failure.Exception.GetType().Name
    $errorInfo = [InvalidOperationException]::new("Collector stopped at $stage ($reason, RPC=$rpcMethod, code=$rpcCode).")
    $errorInfo.Data['stage'] = $stage
    $errorInfo.Data['rpcMethod'] = $rpcMethod
    $errorInfo.Data['rpcCode'] = $rpcCode
    throw $errorInfo
} finally { Close-CodexSession }
