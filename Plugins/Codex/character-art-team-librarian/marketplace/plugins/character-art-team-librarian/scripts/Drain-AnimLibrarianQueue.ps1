#requires -Version 7.2
# Compatibility for callers of the 0.2 retry command. Observe the same evening deadline.
[CmdletBinding()] param(
    [ValidatePattern('^[a-f0-9]{32}$')][string]$EnrollmentId,
    [switch]$Background,
    [switch]$RequestFull
)
$arguments = @{}
if ($EnrollmentId) { $arguments.EnrollmentId=$EnrollmentId }
& (Join-Path $PSScriptRoot 'Sync-AnimTeamSessions.ps1') @arguments
