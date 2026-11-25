#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DocumentDirectory,
    [Parameter(Mandatory)][string]$Email,
    [Parameter(Mandatory)][string]$StateDirectory,
    [switch]$RequireCompleteBatch,
    [switch]$IncludeImages,
    [string]$BatchDate,
    [string]$ReceiptDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LibrarianState.ps1')
. (Join-Path $PSScriptRoot 'Publish-AnimTeamSessionsCore.ps1')
Publish-AnimTeamSessionDocuments @PSBoundParameters -RemoteUrl 'https://github.com/YHAnimationStudios/YH_Knowledge_database.git'
