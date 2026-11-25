# Claude Code keeps session transcripts for cleanupPeriodDays (default 30) and then deletes them.
# Enrollment raises it so a seat that was offline for a while can still be backed up.

function Read-ClaudeSettingsObject([string] $SettingsPath) {
    $text = [IO.File]::ReadAllText($SettingsPath)
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    $settings = $text | ConvertFrom-Json -ErrorAction Stop
    if ($settings -isnot [pscustomobject]) { throw "Claude settings file is not a JSON object: $SettingsPath" }
    return $settings
}

function Get-ClaudeObjectRetention($Settings) {
    $property = $Settings.PSObject.Properties['cleanupPeriodDays']
    if ($property) {
        # Any numeric value counts (5000, 5000.0 or "5000"); it must never be mistaken for absent.
        $number = 0.0
        $v = $property.Value
        $ok = $false
        if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { $number = [double]$v; $ok = $true }
        elseif ($v -is [string]) {
            $ok = [double]::TryParse($v.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)
        }
        if ($ok -and -not [double]::IsNaN($number)) {
            return [int][math]::Floor([math]::Max([math]::Min($number, [double][int]::MaxValue), [double][int]::MinValue))
        }
    }
    return 30
}

function Get-ClaudeTranscriptRetention([string] $SettingsPath) {
    if (-not [IO.File]::Exists($SettingsPath)) { return 30 }
    return (Get-ClaudeObjectRetention (Read-ClaudeSettingsObject $SettingsPath))
}

function Set-ClaudeTranscriptRetention([string] $SettingsPath, [int] $MinimumDays = 3650) {
    # An unreadable file is never overwritten; the parse error propagates.
    $settings = if ([IO.File]::Exists($SettingsPath)) { Read-ClaudeSettingsObject $SettingsPath } else { [pscustomobject]@{} }
    $before = Get-ClaudeObjectRetention $settings
    if ($settings.PSObject.Properties['cleanupPeriodDays'] -and $before -ge $MinimumDays) {
        return @{ before = $before; after = $before; changed = $false }
    }
    # Assigning to an existing property keeps its position; a new key is appended at the end.
    if ($settings.PSObject.Properties['cleanupPeriodDays']) { $settings.cleanupPeriodDays = $MinimumDays }
    else { $settings | Add-Member -NotePropertyName cleanupPeriodDays -NotePropertyValue $MinimumDays }
    $text = ($settings | ConvertTo-Json -Depth 100) + "`n"
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($SettingsPath))
    $stage = $SettingsPath + ".$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($stage, [Text.UTF8Encoding]::new($false).GetBytes($text))
        [IO.File]::Move($stage, $SettingsPath, $true)
    } finally {
        if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
    }
    return @{ before = $before; after = $MinimumDays; changed = $true }
}
