function Test-CodexEmailFolder($Email) {
    $address = $null
    return $Email -is [string] -and $Email.Length -le 254 -and
        $Email -notmatch '[\x00-\x20<>:"/\\|?*\x7f]|[.]$' -and
        $Email -notmatch '^(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])\.' -and
        [Net.Mail.MailAddress]::TryCreate($Email,[ref]$address) -and $Email -ceq $address.Address
}

function Assert-CodexListCapabilities([string] $Binary) {
    # Prove the installed executable recognizes account scoping without issuing
    # any trial thread/list request. Only public protocol schemas go in temp.
    $temporaryRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))
    $directory = [IO.Path]::Combine($temporaryRoot, 'character-art-team-librarian-protocol-' + [guid]::NewGuid().ToString('N'))
    New-LibrarianPrivateDirectory $directory
    try {
        $start = [Diagnostics.ProcessStartInfo]::new($Binary)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('app-server','generate-json-schema','--experimental','--out',$directory)) {
            $start.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::Start($start)
        try {
            $outDrain = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
            $errDrain = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
            if (!$process.WaitForExit(60000)) { $process.Kill($true); throw [TimeoutException]::new() }
            if ($process.ExitCode -ne 0) { throw [NotSupportedException]::new() }
        } finally { $process.Dispose() }
        $schema = [IO.File]::ReadAllText([IO.Path]::Combine($directory,'v2','ThreadListParams.json')) | ConvertFrom-Json
        if ($schema.properties.currentAccountOnly.type -cne 'boolean' -or
            'array' -cnotin $schema.properties.includedThreadIds.type -or
            $schema.properties.includedThreadIds.items.type -cne 'string') { throw [NotSupportedException]::new() }
    } finally {
        $leaf = [IO.Path]::GetFileName($directory)
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($directory)) -ceq $temporaryRoot -and
            $leaf -cmatch '^character-art-team-librarian-protocol-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
    }
}

function Open-CodexSession {
    $package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
    if (!$package) { throw [IO.FileNotFoundException]::new() }
    $binary = [IO.Path]::Combine($package.InstallLocation, 'app', 'resources', 'codex.exe')
    if (!$IdentityOnly) { Assert-CodexListCapabilities $binary }
    $start = [Diagnostics.ProcessStartInfo]::new($binary)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardInputEncoding = $utf8
    $start.StandardOutputEncoding = $utf8
    foreach ($argument in @('app-server', '--listen', 'stdio://', '-c', 'analytics.enabled=false')) {
        $start.ArgumentList.Add($argument)
    }
    $script:server = [Diagnostics.Process]::Start($start)
    $script:stderrDrain = $server.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    $null = Invoke-CodexRpc 'initialize' @{
        clientInfo = @{name='character_art_team_librarian'; title='Character Art Team Librarian'; version='0.4.0'}
        capabilities = @{experimentalApi=$true}
    }
    Send-CodexRpc @{method='initialized';params=@{}}
}

function Close-CodexSession {
    if ($server) {
        try { $server.StandardInput.Close() } catch {}
        try { if (!$server.WaitForExit(2000)) { $server.Kill($true) } } catch {}
        $server.Dispose()
        $script:server = $null
    }
}

function Send-CodexRpc($Message) {
    $server.StandardInput.WriteLine((ConvertTo-Json -InputObject $Message -Depth 12 -Compress))
    $server.StandardInput.Flush()
}

function Invoke-CodexRpc([string] $Method, [hashtable] $Parameters) {
    $script:rpcMethod = $Method
    $script:rpcCode = $null
    $script:requestId++
    # A failed write, timed-out ReadLineAsync, malformed frame, or EOF can leave
    # this transport unable to match another request. Only a matched frame clears it.
    $script:rpcInFlight = $true
    Send-CodexRpc @{id=$requestId; method=$Method; params=$Parameters}
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while ([DateTime]::UtcNow -lt $deadline) {
        $read = $server.StandardOutput.ReadLineAsync()
        $milliseconds = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (!$read.Wait($milliseconds)) { throw [TimeoutException]::new() }
        if ($null -eq $read.Result) { throw [IO.EndOfStreamException]::new() }
        $response = ConvertFrom-Json -InputObject $read.Result -AsHashtable -Depth 128 @jsonOptions
        if ($response.Contains('method')) {
            if ($identityPinned -and $response.method -in @('account/updated','account/login/completed') -and
                $response.params.reason -ne 'workspaceRoutingReady') { $script:accountChanged = $true }
            continue
        }
        if ($response.id -ne $requestId) { continue }
        $script:rpcInFlight = $false
        if ($response.Contains('error')) {
            if ($response.error.code -is [long] -or $response.error.code -is [int]) { $script:rpcCode = $response.error.code }
            throw [InvalidOperationException]::new()
        }
        if (!$response.Contains('result')) { throw [IO.InvalidDataException]::new() }
        return $response.result
    }
    throw [TimeoutException]::new()
}

function Get-CodexRows([string] $Method, [hashtable] $Filters) {
    $cursors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    do {
        $page = Invoke-CodexRpc $Method $Filters
        if ($page.data -isnot [array] -or !$page.Contains('nextCursor')) { throw [IO.InvalidDataException]::new() }
        foreach ($row in $page.data) { $row }
        $cursor = $page.nextCursor
        if ($null -ne $cursor) {
            if (!$cursor -or !$cursors.Add($cursor)) { throw [IO.InvalidDataException]::new() }
            $Filters.cursor = $cursor
        }
    } while ($null -ne $cursor)
}
