#requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$Scheduled,
    [switch]$CheckOnly,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$EnrollmentId
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LibrarianState.ps1')
. (Join-Path $PSScriptRoot 'LibrarianEvening.ps1')
$directory = Get-LibrarianStateDirectory
$config = Get-LibrarianConfig $directory
if ($EnrollmentId -and $config.enrollmentId -cne $EnrollmentId) {
    @{status='InactiveEnrollment';pending=$false} | ConvertTo-Json -Compress
    exit 0
}
$seat = if ($config) { Get-LibrarianSeatDirectory $directory $config.enrollmentId }
$status = Get-LibrarianEveningStatus $config $seat
if ($CheckOnly -or $config.mode -ne 'AccountSync' -or $config.schemaVersion -ne 3) {
    $status | ConvertTo-Json -Depth 5 -Compress
    exit 0
}
$lock = Open-LibrarianLock (Join-Path $seat 'collection.lock')
try {
    # A scheduled wake and a manual catch-up may have observed the same open slot.
    $active = Get-LibrarianConfig $directory
    if ($active.enrollmentId -cne $config.enrollmentId) {
        @{status='InactiveEnrollment';pending=$false} | ConvertTo-Json -Compress
        exit 0
    }
    $status = Get-LibrarianEveningStatus $active $seat
    if ($active.mode -eq 'AccountSync' -and $active.schemaVersion -eq 3) {
        # A crash can leave a pre-publication collection, an obsolete missed day,
        # or an already receipted snapshot. Delete only those owned by this seat.
        foreach ($orphan in [IO.Directory]::GetDirectories($seat,'collect-*')) { Remove-LibrarianEveningStage $seat $orphan }
        foreach ($snapshot in [IO.Directory]::GetDirectories($seat,'evening-*')) {
            $name = [IO.Path]::GetFileName($snapshot)
            if ($name -cmatch '^evening-(\d{4}-\d{2}-\d{2})$' -and
                ($Matches[1] -lt $status.latestDueDate -or ($status.lastCompleted -and $Matches[1] -le $status.lastCompleted.batchDate))) {
                Remove-LibrarianEveningStage $seat $snapshot
            }
        }
    }
    $success = $true
    if ($status.pending) {
        $success = Invoke-LibrarianEvening $active $directory $seat $status
        $current = Get-LibrarianConfig $directory
        if ($current.enrollmentId -cne $active.enrollmentId) {
            @{status='InactiveEnrollment';pending=$false} | ConvertTo-Json -Compress
            exit 0
        }
        $status = Get-LibrarianEveningStatus $current $seat
    }
    $status | ConvertTo-Json -Depth 5 -Compress
    if (!$success -and $status.pending) { exit 1 }
    exit 0
} finally {
    $lock.Dispose()
}
