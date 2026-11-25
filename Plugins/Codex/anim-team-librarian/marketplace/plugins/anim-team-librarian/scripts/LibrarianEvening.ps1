function Get-LibrarianLocalNow { [DateTimeOffset]::Now }

function Get-LibrarianEveningRecord([string]$Directory,[string]$Name) {
    $path = Join-Path $Directory $Name
    Assert-LibrarianPrivatePath $path
    if ([IO.File]::Exists($path)) { Read-LibrarianJson $path }
}

function Get-LibrarianEveningStatus($Config,[string]$Seat) {
    $now = Get-LibrarianLocalNow
    $format = [Globalization.CultureInfo]::InvariantCulture
    $state = [ordered]@{
        status='NotEnrolled'; email=$Config.email; eveningTime=$Config.eveningTime; includeImages=($Config.includeImages -is [bool] -and $Config.includeImages)
        firstEveningDate=$Config.firstEveningDate; checkedAtLocal=$now.ToString('o')
        latestDueDate=$null; pending=$false; overdue=$false; lastCompleted=$null
        currentReceipt=$null; lastAttempt=$null; nextDueLocal=$null
    }
    if (-not $Config) { return $state }
    if ($Config.schemaVersion -ne 3) {
        $state.status = if ($Config.mode -eq 'Disabled') { 'Disabled' } else { 'ScheduleUpgradeRequired' }
        return $state
    }
    $first = [datetime]::ParseExact($Config.firstEveningDate,'yyyy-MM-dd',$format)
    $time = [timespan]::ParseExact($Config.eveningTime,'hh\:mm',$format)
    $today = $now.Date.Add($time)
    $due = if ($now.DateTime -ge $today) { $today } else { $today.AddDays(-1) }
    $next = $due.AddDays(1)
    if ($first -gt $next.Date) { $next = $first.Add($time) }
    if ($due.Date -ge $first) { $state.latestDueDate = $due.ToString('yyyy-MM-dd',$format) }
    $complete = Get-LibrarianEveningRecord $Seat 'evening-completed.json'
    $attempt = Get-LibrarianEveningRecord $Seat 'evening-attempt.json'
    if ($complete) {
        if ($complete.enrollmentId -cne $Config.enrollmentId -or $complete.status -cne 'Completed') { throw 'Invalid evening receipt.' }
        $lastDate = [datetime]::ParseExact($complete.batchDate,'yyyy-MM-dd',$format)
        $state.lastCompleted = $complete
        if ($next.Date -le $lastDate) { $next = $lastDate.AddDays(1).Add($time) }
        if ($complete.batchDate -ceq $state.latestDueDate) { $state.currentReceipt = $complete }
    }
    $state.lastAttempt = if ($attempt -and (!$complete -or $attempt.batchDate -gt $complete.batchDate)) { $attempt } else { $complete }
    if ($Config.mode -ne 'AccountSync') { $state.status = 'Disabled'; return $state }
    $state.nextDueLocal = $next.ToString('yyyy-MM-ddTHH:mm:ss',$format)
    $state.pending = [bool]($state.latestDueDate -and (!$complete -or $state.latestDueDate -gt $complete.batchDate))
    $state.overdue = $state.pending -and $now.DateTime -gt $due
    $state.status = if ($state.pending) {
        if ($attempt -and $attempt.status -ceq 'RetryPending' -and $attempt.batchDate -le $state.latestDueDate -and
            (!$complete -or $attempt.batchDate -gt $complete.batchDate)) { 'RetryPending' } else { 'Due' }
    } elseif ($state.currentReceipt) { 'Completed' } else { 'Waiting' }
    return $state
}

function Remove-LibrarianEveningStage([string]$Seat,[string]$Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($absolute) -ne [IO.Path]::GetFullPath($Seat) -or
        [IO.Path]::GetFileName($absolute) -cnotmatch '^(collect-[a-f0-9]{32}|evening-\d{4}-\d{2}-\d{2})$') {
        throw 'Invalid evening staging location.'
    }
    Assert-LibrarianPrivatePath $absolute -Protected
    if (-not [IO.Directory]::Exists($absolute)) { return }
    Remove-LibrarianStageContents ([IO.DirectoryInfo]::new($absolute)) 0
    [IO.Directory]::Delete($absolute)
}

function Remove-LibrarianStageContents([IO.DirectoryInfo]$Directory,[int]$Depth) {
    foreach ($entry in $Directory.GetFileSystemInfos()) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            # Delete the link itself, even if its target is missing or outside this seat.
            $entry.Delete()
            continue
        }
        if ($entry -is [IO.DirectoryInfo]) {
            if (!(($Depth -eq 0 -and $entry.Name -ceq 'documents') -or ($Depth -eq 1 -and $entry.Name -ceq 'images') -or
                ($Depth -eq 2 -and $entry.Name -cmatch '\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z'))) {
                throw 'Unexpected evening staging directory.'
            }
            Assert-LibrarianPrivatePath $entry.FullName -Protected
            Remove-LibrarianStageContents $entry ($Depth+1)
        } else {
            Assert-LibrarianPrivatePath $entry.FullName
        }
        $entry.Delete()
    }
}

function Assert-LibrarianCounts($Record,[string[]]$Names) {
    foreach ($name in $Names) {
        $count = $Record.$name
        if (($count -isnot [int] -and $count -isnot [long]) -or $count -lt 0) { throw 'Invalid component counts.' }
    }
}

function Get-LibrarianSnapshotCounts([string]$Directory,[bool]$IncludeImages) {
    Assert-LibrarianPrivatePath $Directory -Protected
    $uuid = '[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}'
    $counts = @{documents=0;imageFiles=0}
    $images = $null
    foreach ($entry in ([IO.DirectoryInfo]::new($Directory)).GetFileSystemInfos()) {
        if ($entry -is [IO.DirectoryInfo] -and $IncludeImages -and $entry.Name -ceq 'images') {
            Assert-LibrarianPrivatePath $entry.FullName -Protected
            $images = $entry
            continue
        }
        Assert-LibrarianPrivatePath $entry.FullName
        if ($entry -isnot [IO.FileInfo] -or $entry.Name -cnotmatch "\A$uuid\.md\z") {
            throw 'Invalid evening snapshot document.'
        }
        $counts.documents++
    }
    if ($images) {
        foreach ($owner in $images.GetFileSystemInfos()) {
            if ($owner -isnot [IO.DirectoryInfo] -or $owner.Name -cnotmatch "\A$uuid\z" -or
                ![IO.File]::Exists((Join-Path $Directory ($owner.Name + '.md')))) { throw 'Invalid evening picture session.' }
            Assert-LibrarianPrivatePath $owner.FullName -Protected
            foreach ($file in $owner.GetFileSystemInfos()) {
                Assert-LibrarianPrivatePath $file.FullName
                if ($file -isnot [IO.FileInfo] -or $file.Name -cnotmatch '\A[a-f0-9]{64}\.(png|jpg|gif|webp)\z') {
                    throw 'Invalid evening snapshot picture.'
                }
                $counts.imageFiles++
            }
        }
    }
    return $counts
}

function Invoke-LibrarianEvening($Config,[string]$Directory,[string]$Seat,$Status) {
    # Caller holds collection.lock. Only the outbound transaction holds enrollment.lock,
    # allowing disable/replacement while the account's history is being read.
    $date = $Status.latestDueDate
    $stage = $null
    $frozen = Join-Path $Seat ('evening-' + $date)
    $requestedImages = $Config.includeImages -is [bool] -and $Config.includeImages
    $destination = "Usage data/Animators team/$($Config.email)/Codex"
    $includeImages = $requestedImages
    $imageCounters = @('imageReferences','imagesAvailable','imagesUnavailable','imageFiles')
    $attempt = [ordered]@{enrollmentId=$Config.enrollmentId;batchDate=$date;checkedAtLocal=$Status.checkedAtLocal
        status='RetryPending';reason='AccountVerificationFailed';activeThreads=0;archivedThreads=0;documents=0
        includeImages=$includeImages;imageReferences=$null;imagesAvailable=$null;imagesUnavailable=$null;imageFiles=$null;pushedImages=$null
        layoutVersion=2;destination=$destination;provisionedTools=$null
        skipped=0;failures=0;changed=$null;unchanged=0;older=0;conflicts=0;commit=$null;head=$null;outcome=$null}
    try {
        if (-not (Test-LibrarianBinding $Config (Get-LibrarianIdentity))) { $attempt.reason='AccountChanged'; throw 'Hold' }
        $attempt.reason = 'DestinationVisibilityUnverified'
        if ((Get-LibrarianRepositoryHttpStatus) -ne 404) { throw 'Hold' }
        $attempt.reason = 'CollectionFailed'
        Assert-LibrarianPrivatePath $frozen -Protected
        $recovering = [IO.Directory]::Exists($frozen)
        $published = $null
        $publicationStarted = $false
        $verifyLegacy = $false
        if ($recovering) {
            $collection = Get-LibrarianEveningRecord $frozen 'collection.json'
            if (!$collection -or ($collection.PSObject.Properties['layoutVersion'] -and $collection.layoutVersion -ne 2) -or
                ($collection.PSObject.Properties['includeImages'] -and $collection.includeImages -isnot [bool]) -or
                ($collection.PSObject.Properties['publicationStarted'] -and $collection.publicationStarted -isnot [bool])) {
                throw 'Invalid frozen evening scope.'
            }
            $includeImages = [bool]$collection.includeImages
            $published = Get-LibrarianEveningRecord $frozen 'publication.json'
            $candidatePath = Join-Path $frozen 'publish-candidate.json'
            Assert-LibrarianPrivatePath $candidatePath
            $hasCandidate = [IO.File]::Exists($candidatePath)
            $publicationStarted = [bool]$collection.publicationStarted -or $hasCandidate
            # 0.4 text batches did not journal entry into the publisher. A missing
            # candidate alone cannot prove that a recovered snapshot was never pushed.
            if ($published) {
                $verifyLegacy = !$published.PSObject.Properties['layoutVersion']
            } elseif (!$collection.PSObject.Properties['layoutVersion']) {
                $uncertainWithoutCandidate = !$hasCandidate -and (!$includeImages -or $publicationStarted)
                $revokedCandidate = $hasCandidate -and $includeImages -and !$requestedImages
                $verifyLegacy = $uncertainWithoutCandidate -or $revokedCandidate
            }
            if ($includeImages -and !$requestedImages -and !$published -and !$publicationStarted) {
                # Recollect only if the snapshot never entered the publisher.
                Remove-LibrarianEveningStage $Seat $frozen
                $recovering = $false
                $includeImages = $false
            }
        }
        $attempt.includeImages = $includeImages
        if (!$publicationStarted -and !$published) { $attempt.changed = 0; $attempt.pushedImages = 0 }
        if (!$includeImages) { $attempt.pushedImages = 0 }
        if (!$recovering) {
            $stage = Join-Path $Seat ('collect-' + [guid]::NewGuid().ToString('N'))
            New-LibrarianPrivateDirectory $stage
            $docs = Join-Path $stage 'documents'
            New-LibrarianPrivateDirectory $docs
            $collectArgs = @{OutputDirectory=$docs;ExpectedEmail=$Config.email;PinnedUserId=$Config.userId}
            if ($includeImages) { $collectArgs.IncludeImages = $true }
            $collection = & (Join-Path $PSScriptRoot 'Collect-AnimTeamHistory.ps1') @collectArgs 2>$null | ConvertFrom-Json
            if (-not (Test-LibrarianBinding $Config $collection)) { $attempt.reason='AccountChanged'; throw 'Hold' }
        } else {
            $docs = Join-Path $frozen 'documents'
        }
        $counters = @('activeThreads','archivedThreads','documents','skipped','failures')
        if ($includeImages) { $counters += $imageCounters }
        Assert-LibrarianCounts $collection $counters
        foreach ($name in $counters) { $attempt[$name] = $collection.$name }
        $attempt.reason = 'CollectionIncomplete'
        if ($attempt.failures -or $collection.failedSessions.Count -or $collection.missing.Count -or
            $attempt.documents -ne ($attempt.activeThreads + $attempt.archivedThreads)) { throw 'Hold' }
        $counts = Get-LibrarianSnapshotCounts $docs $includeImages
        if ($attempt.documents -ne $counts.documents -or ($includeImages -and
            ($attempt.imageFiles -ne $counts.imageFiles -or $attempt.imageFiles -gt $attempt.imagesAvailable -or
            $attempt.imageReferences -ne ($attempt.imagesAvailable + $attempt.imagesUnavailable)))) { throw 'Hold' }
        if ($includeImages -and !$requestedImages -and !$published -and !$verifyLegacy) { $attempt.reason='SnapshotImageSettingChanged'; throw 'Hold' }
        $attempt.reason = 'EnrollmentVerificationFailed'
        $gate = Open-LibrarianLock (Join-Path $Directory 'enrollment.lock')
        try {
            $active = Get-LibrarianConfig $Directory
            if ($active.mode -ne 'AccountSync' -or $active.schemaVersion -ne 3 -or $active.enrollmentId -cne $Config.enrollmentId -or
                ([bool]$active.includeImages -ne $requestedImages) -or
                $active.eveningTime -cne $Config.eveningTime -or $active.firstEveningDate -cne $Config.firstEveningDate -or
                -not (Test-LibrarianBinding $Config $active)) { $attempt.reason='EnrollmentChanged'; throw 'Hold' }
            $attempt.reason = 'AccountVerificationFailed'
            if (-not (Test-LibrarianBinding $Config (Get-LibrarianIdentity))) { $attempt.reason='AccountChanged'; throw 'Hold' }
            $attempt.reason = 'SnapshotFailed'
            $summary = @{layoutVersion=2;includeImages=$includeImages}
            if ($recovering -and !$collection.PSObject.Properties['layoutVersion']) { $summary.Remove('layoutVersion') }
            foreach ($name in $counters) { $summary[$name] = $attempt[$name] }
            if (!$recovering) {
                Write-LibrarianJson (Join-Path $stage 'collection.json') $summary
                [IO.Directory]::Move($stage,$frozen)
                $stage = $null
                $docs = Join-Path $frozen 'documents'
            }
            $recorded = $null -ne $published
            if (!$recorded -and !$verifyLegacy -and !$collection.publicationStarted) {
                # The Git candidate can be lost after an accepted push. This independent
                # boundary prevents a scope change from turning a retry into a new batch.
                $summary.publicationStarted = $true
                Write-LibrarianJson (Join-Path $frozen 'collection.json') $summary -Replace
            }
            $attempt.reason = 'PublishFailed'
            if (!$recorded -or $verifyLegacy) {
                $publishArgs = @{DocumentDirectory=$docs; Email=$Config.email; StateDirectory=$Seat
                    RequireCompleteBatch=$true; BatchDate=$date; ReceiptDirectory=$frozen}
                if ($verifyLegacy) { $publishArgs.VerifyRecordedPublication = $true }
                if ($includeImages) { $publishArgs.IncludeImages = $true; $attempt.pushedImages = $null }
                $attempt.changed = $null
                $published = & (Join-Path $PSScriptRoot 'Publish-AnimTeamSessions.ps1') @publishArgs 2>$null | ConvertFrom-Json
            }
            if ($published.layoutVersion -ne 2 -or $published.destination -cne $destination) { throw 'Unverified usage destination.' }
            Assert-LibrarianCounts $published @('pushed','unchanged','older','conflicts','deferred')
            $pushedImages = 0
            if ($published.PSObject.Properties['pushedImages']) {
                Assert-LibrarianCounts $published @('pushedImages')
                $pushedImages = $published.pushedImages
            } elseif ($includeImages) { throw 'Missing image publication count.' }
            $tools = 0
            if ($published.PSObject.Properties['provisionedTools']) {
                Assert-LibrarianCounts $published @('provisionedTools')
                $tools=$published.provisionedTools
                if ($tools -gt 2) { throw 'Invalid tool directory count.' }
            }
            if ($pushedImages -gt $counts.imageFiles) { throw 'Invalid image publication total.' }
            if (($published.pushed + $published.unchanged + $published.older + $published.conflicts + $published.deferred) -ne $attempt.documents) { throw 'Invalid publication totals.' }
            if ($published.conflicts -or $published.deferred) {
                if ($published.pushed -or $pushedImages -or $tools) { throw 'Invalid atomic conflict receipt.' }
                if (!$recovering) { $attempt.changed = 0; $attempt.pushedImages = 0 }
                $attempt.conflicts = $published.conflicts
                $attempt.reason = 'ConflictingSessionVersions'
                # A fresh, atomic rejection made no remote change. A later collection can
                # resolve it. Keep a retried snapshot if an earlier push result was lost.
                if (!$recovering -and !$published.pushed) { Remove-LibrarianEveningStage $Seat $frozen }
                throw 'Hold'
            }
            $objectId = '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'
            $changed = $published.pushed -or $pushedImages -or $tools
            if ($published.head -cnotmatch $objectId -or ($changed -and $published.commit -cnotmatch $objectId) -or
                (!$changed -and ($published.commit -or $published.recovered))) { throw 'Invalid publication receipt.' }
            $attempt.reason = 'CheckpointFailed'
            if (!$recorded) { $published | Add-Member -Force -NotePropertyName verifiedAfterRetry -NotePropertyValue $recovering }
            $attempt.changed = $published.pushed
            $attempt.pushedImages = $pushedImages
            $attempt.provisionedTools = $tools
            foreach ($name in 'unchanged','older','commit','head') { $attempt[$name] = $published.$name }
            if ($published.recovered) { $attempt.outcome = 'RecoveredCommit' }
            elseif ($changed) { $attempt.outcome = 'Changed' }
            elseif ($attempt.documents -gt 0 -and ($published.verifiedAfterRetry -or $published.uncertain)) {
                # Identical/superseded content proves the frozen snapshot is covered.
                # The fetched head alone does not prove who originally published it.
                $attempt.changed = $null
                if ($includeImages) { $attempt.pushedImages = $null }
                $attempt.outcome = 'VerifiedAfterRetry'
            } else { $attempt.outcome = 'NoChanges' }
            if (!$recorded -or $verifyLegacy) { Write-LibrarianJson (Join-Path $frozen 'publication.json') $published -Replace }
            $attempt.checkedAtLocal = (Get-LibrarianLocalNow).ToString('o')
            $complete = [ordered]@{}
            foreach ($name in $attempt.Keys) { $complete[$name] = $attempt[$name] }
            $complete.status = 'Completed'
            $complete.reason = $null
            Write-LibrarianJson (Join-Path $Seat 'evening-completed.json') $complete -Replace
        } finally { $gate.Dispose() }
    } catch {
        # Persist only classified reasons. Collector and Git exceptions can contain private data.
        if ($_.Exception.Data['reason'] -cin 'UsageLayoutNotActive','MigrationVerificationRequired') {
            $attempt.reason = $_.Exception.Data['reason']
        }
        Write-LibrarianJson (Join-Path $Seat 'evening-attempt.json') $attempt -Replace
        return $false
    } finally {
        if ($stage) { Remove-LibrarianEveningStage $Seat $stage }
    }
    Remove-LibrarianEveningStage $Seat $frozen
    return $true
}
