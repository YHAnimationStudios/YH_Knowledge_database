function Test-SeatEmailFolder($Email) {
    $address = $null
    return $Email -is [string] -and $Email.Length -le 254 -and
        $Email -notmatch '[\x00-\x20<>:"/\|?*\x7f]|[.]$' -and
        $Email -notmatch '^(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])\.' -and
        [Net.Mail.MailAddress]::TryCreate($Email,[ref]$address) -and $Email -ceq $address.Address
}

function Get-ClaudePaths([string] $ProfileRoot) {
    if ([string]::IsNullOrWhiteSpace($ProfileRoot)) { $ProfileRoot = [Environment]::GetFolderPath('UserProfile') }
    return @{
        Config   = Join-Path $ProfileRoot '.claude.json'
        Projects = Join-Path $ProfileRoot '.claude\projects'
        Settings = Join-Path $ProfileRoot '.claude\settings.json'
    }
}

function Read-ClaudeIdentity([string] $ConfigPath) {
    # Claude Code rewrites .claude.json in place, so a read can hit a partial file; retry briefly.
    $config = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $stream = [IO.File]::Open($ConfigPath, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true))
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $stream.Dispose() }
            $config = $text | ConvertFrom-Json -ErrorAction Stop
            break
        } catch [IO.IOException], [ArgumentException], [Text.DecoderFallbackException], [InvalidOperationException] {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
    $account = if ($config) { $config.oauthAccount } else { $null }
    if ($null -eq $account) { throw [UnauthorizedAccessException]::new('A signed-in Claude account is required.') }
    $email = ([string]$account.emailAddress).ToLowerInvariant()
    $userId = [string]$account.accountUuid
    if (-not (Test-SeatEmailFolder $email)) {
        throw [UnauthorizedAccessException]::new('The Claude account email is not usable.')
    }
    if ([string]::IsNullOrEmpty($userId) -or $userId -match '[\s\x00-\x1f\x7f]') {
        throw [UnauthorizedAccessException]::new('The Claude account has no stable user ID.')
    }
    return @{ email = $email; userId = $userId }
}
