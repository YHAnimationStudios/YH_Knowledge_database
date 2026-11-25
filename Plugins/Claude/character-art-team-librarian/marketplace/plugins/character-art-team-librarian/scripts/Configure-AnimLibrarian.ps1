#requires -Version 7.2
[CmdletBinding(DefaultParameterSetName='Inspect')]
param(
    [Parameter(Mandatory,ParameterSetName='Enable')] [switch] $EnableAccountSync,
    [Parameter(ParameterSetName='Enable')] [switch] $ReplaceEnrollment,
    [Parameter(ParameterSetName='Enable')] [switch] $IncludeImages,
    [Parameter(ParameterSetName='Enable')] [switch] $KeepTranscriptRetention,
    [Parameter(ParameterSetName='Enable')] [ValidatePattern('^(?:[01][0-9]|2[0-3]):[0-5][0-9]$')] [string] $EveningTime,
    [Parameter(Mandatory,ParameterSetName='Disable')] [switch] $DisableAccountSync,
    [Parameter(ParameterSetName='Inspect')] [switch] $Status
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LibrarianState.ps1')
. (Join-Path $PSScriptRoot 'LibrarianEvening.ps1')
. (Join-Path $PSScriptRoot 'LibrarianScheduledTask.ps1')
. (Join-Path $PSScriptRoot 'LibrarianInstall.ps1')
. (Join-Path $PSScriptRoot 'ClaudeSession.ps1')
. (Join-Path $PSScriptRoot 'ClaudeSettings.ps1')
$directory = Get-LibrarianStateDirectory
$stateRoot = Split-Path -Parent $directory
$settingsPath = (Get-ClaudePaths).Settings

if ($PSCmdlet.ParameterSetName -eq 'Inspect') {
    $config = Get-LibrarianConfig $directory
    if (!$config) { $statusRecord = @{status='NotEnrolled'} }
    elseif ($config.mode -eq 'Disabled') { $statusRecord = @{status='Disabled';email=$config.email} }
    elseif ($config.schemaVersion -eq 2) { $statusRecord = @{status='ScheduleUpgradeRequired';email=$config.email} }
    else {
        $seat = Get-LibrarianSeatDirectory $directory $config.enrollmentId
        $statusRecord = Get-LibrarianEveningStatus $config $seat
    }
    $taskInfo = Get-LibrarianScheduledTaskInfo
    $statusRecord['scheduledTask'] = $taskInfo
    $statusRecord['transcriptRetentionDays'] = try { Get-ClaudeTranscriptRetention $settingsPath } catch { $null }
    # The task runs a stable copy of the scripts; if that copy was deleted the seat silently stops backing up.
    if ($config -and $config.mode -eq 'AccountSync' -and $config.schemaVersion -eq 3 -and $taskInfo -and $taskInfo.entryScriptExists -eq $false) {
        $statusRecord['status'] = 'ScriptMissing'
    }
    $statusRecord | ConvertTo-Json -Depth 8 -Compress
    return
}

function Enable-LibrarianEveningEnrollment([string]$directory,[string]$path,$previous,[string]$RequestedTime,[bool]$AllowReplacement,[Nullable[bool]]$RequestedImages,[bool]$KeepRetention) {
    $running = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([IO.Path]::GetFileName($running) -ne 'pwsh.exe') { throw 'Run enrollment from PowerShell 7.' }
    $runtime = Select-LibrarianPowerShell (Get-LibrarianPowerShellCandidates) $running
    $identity = Get-LibrarianIdentity
    $sameAccount = Test-LibrarianBinding $previous $identity
    if ($previous -and !$sameAccount -and !$AllowReplacement) {
        throw 'This Windows user enrolled another Claude account. To replace it, specify -ReplaceEnrollment.'
    }
    if (-not $KeepRetention) { $null = Set-ClaudeTranscriptRetention $settingsPath }
    $today = (Get-LibrarianLocalNow).ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
    $firstEveningDate = $today
    if ($previous.mode -eq 'AccountSync' -and $sameAccount) {
        $enrollment = $previous.enrollmentId
        $seat = Get-LibrarianSeatDirectory $directory $enrollment
        if ($previous.schemaVersion -eq 3) { $firstEveningDate = $previous.firstEveningDate }
    } else {
        $enrollment = [guid]::NewGuid().ToString('N')
        $newSeat = Join-Path $directory ('seat-' + $enrollment)
        New-LibrarianPrivateDirectory $newSeat
        if ($sameAccount -and $previous.schemaVersion -eq 3) {
            # A fresh enrollment fences stale workers. Carry the completed evening and
            # previously confirmed Git hashes forward for this same verified account.
            $oldSeat = Get-LibrarianSeatDirectory $directory $previous.enrollmentId
            $receipt = Get-LibrarianEveningRecord $oldSeat 'evening-completed.json'
            if ($receipt) {
                if ($receipt.enrollmentId -cne $previous.enrollmentId -or $receipt.status -cne 'Completed') { throw 'Invalid previous evening receipt.' }
                $receipt.enrollmentId = $enrollment
                Write-LibrarianJson (Join-Path $newSeat 'evening-completed.json') $receipt
            }
            $filename = 'confirmed-' + (Get-LibrarianKey $identity.email) + '.json'
            $confirmed = Get-LibrarianEveningRecord $oldSeat $filename
            if ($confirmed) { Write-LibrarianJson (Join-Path $newSeat $filename) $confirmed }
        }
    }
    if (!$RequestedTime) {
        $RequestedTime = if ($sameAccount -and $previous.eveningTime) { $previous.eveningTime } else { '22:00' }
    }
    $imageMode = if ($null -ne $RequestedImages) { $RequestedImages } else { $sameAccount -and $previous.mode -eq 'AccountSync' -and $previous.includeImages -eq $true }
    $configuration = [ordered]@{
        schemaVersion=3; mode='AccountSync'; email=$identity.email; userId=$identity.userId
        enrollmentId=$enrollment; powerShellPath=$runtime; eveningTime=$RequestedTime; firstEveningDate=$firstEveningDate
        includeImages=$imageMode
    }
    # Copy the scripts out of the plugin cache (old versions are deleted on update) before scheduling them.
    $entry = Install-LibrarianAppCopy $PSScriptRoot (Split-Path -Parent $directory) '0.1.0'
    # Publish the configuration first, while the enrollment lock prevents outbound work.
    # A failed native registration restores the previous configuration before releasing it.
    Write-LibrarianJson $path $configuration -Replace
    try {
        $null = Register-LibrarianScheduledTask -Runtime $runtime -EntryPoint $entry -EveningTime $RequestedTime
    } catch {
        if ($previous) { Write-LibrarianJson $path $previous -Replace } else { [IO.File]::Delete($path) }
        throw
    }
    return $enrollment
}

function Clear-RetiredEveningSnapshots([string] $directory, [string] $id) {
    $seat = Get-LibrarianSeatDirectory $directory $id
    $collectionLock = Open-LibrarianLock (Join-Path $seat 'collection.lock')
    try {
        $active = Get-LibrarianConfig $directory
        if ($active.mode -eq 'AccountSync' -and $active.enrollmentId -ceq $id) { return }
        foreach ($stage in [IO.Directory]::GetDirectories($seat)) {
            if ([IO.Path]::GetFileName($stage) -cmatch '^(collect-[a-f0-9]{32}|evening-\d{4}-\d{2}-\d{2})$') {
                Remove-LibrarianEveningStage $seat $stage
            }
        }
    } finally { $collectionLock.Dispose() }
}

New-LibrarianPrivateDirectory $directory
$path = Join-Path $directory 'account-sync.json'
$retired = $null
$lock = Open-LibrarianLock (Join-Path $directory 'enrollment.lock')
try {
    $previous = Get-LibrarianConfig $directory
    if ($DisableAccountSync) {
        if ($previous) {
            $previous.mode = 'Disabled'
            Write-LibrarianJson $path $previous -Replace
            $retired = $previous.enrollmentId
        }
        Unregister-LibrarianScheduledTask
        Remove-LibrarianAppCopies $stateRoot $null
    } else {
        $requestedImages = if ($PSBoundParameters.ContainsKey('IncludeImages')) { $IncludeImages.IsPresent }
        $enrollment = Enable-LibrarianEveningEnrollment $directory $path $previous $EveningTime $ReplaceEnrollment.IsPresent $requestedImages $KeepTranscriptRetention.IsPresent
        if ($previous -and $previous.enrollmentId -cne $enrollment) { $retired = $previous.enrollmentId }
    }
} finally {
    $lock.Dispose()
    if ($retired) { Clear-RetiredEveningSnapshots $directory $retired }
}
if ($DisableAccountSync) { @{status='Disabled'} | ConvertTo-Json -Compress; return }
& (Join-Path $PSScriptRoot 'Sync-AnimTeamSessions.ps1') -EnrollmentId $enrollment
