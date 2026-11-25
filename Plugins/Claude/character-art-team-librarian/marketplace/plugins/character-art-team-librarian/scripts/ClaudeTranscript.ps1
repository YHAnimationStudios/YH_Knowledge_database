# Parses a Claude Code session transcript (~/.claude/projects/<project>/<session>.jsonl) into the visible
# User/Assistant messages. Tool use and results, thinking, system and hook text are never returned.

$script:TranscriptKeepTypes = @('user', 'assistant', 'custom-title', 'ai-title', 'summary')
$script:TranscriptHasDateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')

function Read-ClaudeTranscriptRecords([string] $Path) {
    $records = [Collections.Generic.List[hashtable]]::new()
    $malformed = 0
    # compact_boundary records are not exported, but the first record after one has parentUuid = the boundary's
    # uuid. Remember uuid -> logicalParentUuid so the active-branch walk can bridge the compaction.
    $boundaries = @{}
    $stream = [IO.File]::Open($Path, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true, 65536)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $record = $null
                try {
                    if ($script:TranscriptHasDateKind) {
                        $record = ConvertFrom-Json -InputObject $line -AsHashtable -Depth 128 -DateKind String -ErrorAction Stop
                    } else {
                        $record = ConvertFrom-Json -InputObject $line -AsHashtable -Depth 128 -ErrorAction Stop
                    }
                } catch {
                    $malformed++
                    continue
                }
                if ($record -isnot [hashtable]) { $malformed++; continue }
                $type = $record['type']
                if ($type -is [string] -and $type -ceq 'system' -and $record['subtype'] -ceq 'compact_boundary') {
                    if ($record['uuid'] -is [string] -and $record['logicalParentUuid'] -is [string]) {
                        $boundaries[$record['uuid']] = $record['logicalParentUuid']
                    }
                    continue
                }
                if ($type -isnot [string] -or $script:TranscriptKeepTypes -cnotcontains $type) { continue }
                if (($type -ceq 'user' -or $type -ceq 'assistant') -and
                    $record['parentUuid'] -is [string] -and $boundaries.ContainsKey($record['parentUuid']) -and
                    -not $record.ContainsKey('logicalParentUuid')) {
                    $record['logicalParentUuid'] = $boundaries[$record['parentUuid']]
                }
                $records.Add($record)
            }
        } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
    return @{ records = $records; malformedLines = $malformed }
}

function Get-ClaudeSessionTitle($Records) {
    $custom = $null
    $ai = $null
    foreach ($record in $Records) {
        if ($record['type'] -ceq 'custom-title' -and $record['customTitle'] -is [string] -and $record['customTitle'].Trim()) {
            $custom = $record['customTitle']
        } elseif ($record['type'] -ceq 'ai-title' -and $record['aiTitle'] -is [string] -and $record['aiTitle'].Trim()) {
            $ai = $record['aiTitle']
        }
    }
    if ($null -ne $custom) { return $custom }
    return $ai
}

function Select-ClaudeActiveBranch($Records) {
    $chat = [Collections.Generic.List[hashtable]]::new()
    foreach ($record in $Records) {
        if ($record['type'] -ceq 'user' -or $record['type'] -ceq 'assistant') { $chat.Add($record) }
    }
    $branch = [Collections.Generic.List[hashtable]]::new()
    $byUuid = @{}
    $position = [Collections.Generic.Dictionary[hashtable, int]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    for ($i = 0; $i -lt $chat.Count; $i++) {
        $position[$chat[$i]] = $i
        if ($chat[$i]['uuid'] -is [string]) { $byUuid[$chat[$i]['uuid']] = $chat[$i] }
    }
    $leaf = $null
    for ($i = $chat.Count - 1; $i -ge 0; $i--) {
        if ($chat[$i]['isSidechain'] -ne $true) { $leaf = $chat[$i]; break }
    }
    if ($null -eq $leaf) { return , $branch }

    $visited = [Collections.Generic.HashSet[hashtable]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    $leafToRoot = [Collections.Generic.List[hashtable]]::new()
    $broken = $false
    $cur = $leaf
    while ($null -ne $cur) {
        if (-not $visited.Add($cur)) { break }
        $leafToRoot.Add($cur)
        $parentId = $cur['parentUuid']
        $logicalId = $cur['logicalParentUuid']
        $next = $null
        if ($parentId -is [string]) { $next = $byUuid[$parentId] }
        if ($null -eq $next -and $logicalId -is [string]) { $next = $byUuid[$logicalId] }
        if ($null -eq $next -and ($parentId -is [string] -or $logicalId -is [string])) { $broken = $true }
        $cur = $next
    }
    if ($broken) {
        # Broken chain: the branch root's parent is not in the file, so earlier records cannot be linked.
        # Include every earlier non-sidechain record in file order.
        $cut = $position[$leafToRoot[$leafToRoot.Count - 1]]
        for ($i = 0; $i -lt $cut; $i++) {
            if ($chat[$i]['isSidechain'] -ne $true -and -not $visited.Contains($chat[$i])) { $branch.Add($chat[$i]) }
        }
    }
    for ($i = $leafToRoot.Count - 1; $i -ge 0; $i--) { $branch.Add($leafToRoot[$i]) }
    return , $branch
}

function ConvertTo-ClaudeTime($Value) {
    $parsed = [datetimeoffset]::MinValue
    if ($Value -is [datetime]) { return [datetimeoffset]::new($Value.ToUniversalTime()) }
    if ($Value -is [string] -and [datetimeoffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed }
    return [datetimeoffset]::new(1970, 1, 1, 0, 0, 0, [timespan]::Zero)
}

function Get-ClaudeUserParts($Content) {
    $parts = [Collections.Generic.List[hashtable]]::new()
    $images = [Collections.Generic.List[hashtable]]::new()
    $textBlocks = [Collections.Generic.List[string]]::new()
    if ($Content -is [string]) {
        $textBlocks.Add($Content)
    } elseif ($Content -is [System.Collections.IEnumerable]) {
        foreach ($block in $Content) {
            if ($block -isnot [hashtable]) { continue }
            if ($block['type'] -ceq 'text' -and $block['text'] -is [string]) { $textBlocks.Add($block['text']) }
            elseif ($block['type'] -ceq 'image') { $images.Add($block) }
            # tool_result and every other block type is dropped.
        }
    }
    $raw = $textBlocks -join "`n"
    $text = [regex]::Replace($raw, '(?s)<system-reminder>.*?</system-reminder>', '')
    if ($text.Length -ne $raw.Length) { $text = $text.Trim() }

    if ($text -match '<command-name>\s*(/[^<\s]+)\s*</command-name>') {
        $parts.Add(@{ type = 'command'; name = $Matches[1] })
        return , $parts
    }
    $stripped = [regex]::Replace($text, '(?s)<(command-message|command-args|local-command-stdout|local-command-stderr|bash-input|bash-stdout|bash-stderr)>.*?</\1>', '')
    if ($text.Trim() -and -not $stripped.Trim()) { return , $parts }
    if ($text.Trim()) { $parts.Add(@{ type = 'text'; text = $text }) }
    $ordinal = 0
    foreach ($image in $images) {
        $ordinal++
        $parts.Add(@{ type = 'image'; block = $image; ordinal = $ordinal })
    }
    return , $parts
}

function ConvertTo-ClaudeMessages($Branch) {
    $messages = [Collections.Generic.List[hashtable]]::new()
    $lastAssistantId = $null
    $lastAssistantMessage = $null
    foreach ($record in $Branch) {
        if ($record['isMeta'] -eq $true -or $record['isCompactSummary'] -eq $true -or
            $record['isSidechain'] -eq $true -or $record['isApiErrorMessage'] -eq $true) { continue }
        $message = $record['message']
        if ($message -isnot [hashtable]) { continue }
        $content = $message['content']
        $time = ConvertTo-ClaudeTime $record['timestamp']

        if ($record['type'] -ceq 'user') {
            $parts = Get-ClaudeUserParts $content
            if ($parts.Count -eq 0) { continue }
            $messages.Add(@{ id = $record['uuid']; role = 'User'; time = $time; parts = $parts })
            $lastAssistantId = $null
            $lastAssistantMessage = $null
        } elseif ($record['type'] -ceq 'assistant') {
            $texts = [Collections.Generic.List[string]]::new()
            if ($content -is [string]) {
                if ($content.Trim()) { $texts.Add($content) }
            } elseif ($content -is [System.Collections.IEnumerable]) {
                foreach ($block in $content) {
                    if ($block -is [hashtable] -and $block['type'] -ceq 'text' -and $block['text'] -is [string] -and $block['text'].Trim()) {
                        $texts.Add($block['text'])
                    }
                }
            }
            $messageId = $message['id']
            if ($messageId -is [string] -and $messageId -ceq $lastAssistantId) {
                $target = $lastAssistantMessage
            } else {
                $target = $null
                $lastAssistantId = if ($messageId -is [string]) { $messageId } else { $null }
                $lastAssistantMessage = $null
            }
            if ($texts.Count -eq 0) { continue }
            if ($null -eq $target) {
                $target = @{ id = $record['uuid']; role = 'Assistant'; time = $time; parts = [Collections.Generic.List[hashtable]]::new() }
                $messages.Add($target)
                $lastAssistantMessage = $target
            }
            foreach ($text in $texts) { $target.parts.Add(@{ type = 'text'; text = $text }) }
        }
    }
    return , $messages
}
