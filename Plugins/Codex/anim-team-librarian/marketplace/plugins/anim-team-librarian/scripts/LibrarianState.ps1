function Get-LibrarianStateDirectory {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $local -or [IO.DriveInfo]::new([IO.Path]::GetPathRoot($local)).DriveType -ne 'Fixed') {
        throw 'Local application data is unavailable.'
    }
    $directory = Join-Path $local 'AnimTeamLibrarian\plugin-state'
    for ($parent = [IO.DirectoryInfo]::new($directory); $parent; $parent = $parent.Parent) {
        $attributes = $parent.Attributes
        if ([int]$attributes -ne -1 -and ($attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'The Librarian state path is redirected.'
        }
    }
    return $directory
}

function Get-LibrarianKey([string] $Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-', '')
    } finally { $sha.Dispose() }
}

function Test-LibrarianPrivateAcl([string] $Path, [switch] $RequireProtected) {
    $section = [Security.AccessControl.AccessControlSections]::Access
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $acl = if ([IO.Directory]::Exists($Path)) { [IO.Directory]::GetAccessControl($Path, $section) }
        else { [IO.File]::GetAccessControl($Path, $section) }
    } else {
        $item = if ([IO.Directory]::Exists($Path)) { [IO.DirectoryInfo]::new($Path) }
        else { [IO.FileInfo]::new($Path) }
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl($item, $section)
    }
    if ($RequireProtected -and -not $acl.AreAccessRulesProtected) { return $false }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowed = @($user, 'S-1-5-18', 'S-1-5-32-544')
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed) {
            return $false
        }
    }
    return $true
}

function Write-LibrarianJson([string] $Path, $Value, [switch] $Replace) {
    Assert-LibrarianPrivatePath $Path
    $stage = $Path + ".$([guid]::NewGuid()).partial"
    $stream = [IO.File]::Open($stage, 'CreateNew')
    try {
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 6 -Compress))
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }

        if (-not [IO.File]::Exists($Path)) {
            try {
                [IO.File]::Move($stage, $Path)
                return
            } catch {
                if (-not [IO.File]::Exists($Path)) { throw }
            }
        }
        if ($Replace) { [IO.File]::Replace($stage, $Path, [NullString]::Value) }
    } finally {
        if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
    }
}

function Read-LibrarianJson([string] $Path) {
    Assert-LibrarianPrivatePath $Path
    # Readers can retain the old snapshot while a concurrent writer atomically replaces the name.
    $stream = [IO.File]::Open($Path,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true))
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Assert-LibrarianPrivatePath([string] $Path, [switch] $Protected) {
    # Use the file attributes even for a dangling reparse point.
    $attributes = [IO.FileInfo]::new($Path).Attributes
    if ([int]$attributes -eq -1) { return }
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -or
        -not (Test-LibrarianPrivateAcl $Path -RequireProtected:$Protected)) {
        throw 'The Librarian path is redirected or its permissions are too broad.'
    }
}

function New-LibrarianPrivateDirectory([string] $Path) {
    Assert-LibrarianPrivatePath $Path -Protected
    if (-not [IO.Directory]::Exists($Path)) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($value in @($user, 'S-1-5-18', 'S-1-5-32-544') | Select-Object -Unique) {
            $sid = [Security.Principal.SecurityIdentifier]::new($value)
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        }
        $null = [IO.FileSystemAclExtensions]::CreateDirectory($acl, $Path)
    }
    Assert-LibrarianPrivatePath $Path -Protected
}

function Get-LibrarianConfig([string] $Directory) {
    $path = Join-Path $Directory 'account-sync.json'
    Assert-LibrarianPrivatePath $Directory -Protected
    Assert-LibrarianPrivatePath $path
    if (-not [IO.File]::Exists($path)) { return }
    $config = Read-LibrarianJson $path
    if ($config.schemaVersion -notin @(2,3) -or $config.mode -notin @('AccountSync','Disabled') -or
        $config.enrollmentId -cnotmatch '^[0-9a-f]{32}$' -or
        [string]::IsNullOrWhiteSpace($config.email) -or [string]::IsNullOrWhiteSpace($config.userId) -or
        ($config.PSObject.Properties['includeImages'] -and $config.includeImages -isnot [bool])) {
        throw 'The account sync enrollment is invalid.'
    }
    if ($config.schemaVersion -eq 3) {
        $date = [datetime]::MinValue
        if ($config.eveningTime -cnotmatch '^(?:[01]\d|2[0-3]):[0-5]\d$' -or
            -not [datetime]::TryParseExact([string]$config.firstEveningDate,'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)) {
            throw 'The local evening schedule is invalid.'
        }
    }
    return $config
}

function Get-LibrarianSeatDirectory([string] $Directory, [string] $EnrollmentId) {
    if ($EnrollmentId -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid enrollment ID.' }
    $seat = Join-Path $Directory ('seat-' + $EnrollmentId)
    Assert-LibrarianPrivatePath $seat -Protected
    if (-not [IO.Directory]::Exists($seat)) { throw 'Enrollment state directory missing.' }
    return $seat
}

function Open-LibrarianLock([string] $Path) {
    Assert-LibrarianPrivatePath $Path
    while ($true) {
        try { return [IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch {
            $cause = $_.Exception.GetBaseException()
            if (($cause.HResult -band 65535) -notin @(32,33)) { throw }
            Start-Sleep -Milliseconds 75
        }
    }
}

function Test-LibrarianBinding($Configuration, $Identity) {
    return ($null -ne $Configuration -and $null -ne $Identity -and
        ([string]$Configuration.email).Equals([string]$Identity.email, [StringComparison]::OrdinalIgnoreCase) -and
        ([string]$Configuration.userId).Equals([string]$Identity.userId, [StringComparison]::Ordinal))
}

function Get-LibrarianIdentity {
    $identity = & (Join-Path $PSScriptRoot 'Collect-AnimTeamHistory.ps1') -IdentityOnly 2>$null | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($identity.email) -or [string]::IsNullOrWhiteSpace($identity.userId)) {
        throw 'A signed-in ChatGPT account with a stable user ID is required.'
    }
    return $identity
}

function Get-LibrarianRepositoryHttpStatus {
    # Never attach seat/Git credentials to the visibility probe or follow a redirect.
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseDefaultCredentials = $false
    $handler.UseCookies = $false
    $client = [Net.Http.HttpClient]::new($handler)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('Anim-Team-Librarian')
        $response = $client.GetAsync(
            'https://api.github.com/repos/YHAnimationStudios/YH_Knowledge_database',
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try { return [int]$response.StatusCode } finally { $response.Dispose() }
    } finally { $client.Dispose() }
}
