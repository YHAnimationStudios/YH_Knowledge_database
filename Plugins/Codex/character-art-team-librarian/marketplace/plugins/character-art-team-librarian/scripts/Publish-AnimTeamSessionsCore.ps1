#requires -Version 7.2
. (Join-Path $PSScriptRoot 'CodexSession.ps1')

function Get-AnimTeamPublishMetadata([string]$Line) {
    if ($Line -cnotmatch '^<!-- anim-team-librarian (\{.{1,400}\}) -->$') { throw 'Invalid session publication header.' }
    try { $header = $Matches[1] | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'Invalid session publication header.' }
    foreach ($field in 'schema','updatedAt','messages') {
        if (($header[$field] -isnot [long] -and $header[$field] -isnot [int]) -or $header[$field] -lt 0) {
            throw 'Invalid session publication version.'
        }
    }
    if ($header.schema -ne 1) { throw 'Unknown session publication format.' }
    if ($header.Contains('legacyOid') -and ($header.legacyOid -isnot [string] -or $header.legacyOid -cnotmatch '\A[0-9a-f]{40}\z')) { throw 'Invalid legacy publication digest.' }
    return $header
}

function Invoke-AnimTeamPublishGit {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [AllowNull()][string]$InputText,
        [IO.Stream]$InputStream,
        [switch]$HeaderOnly,
        [switch]$HashOutput,
        [switch]$AllowFailure
    )
    # All settings are child-process scoped. In-process callers may themselves be
    # running within a Git hook/worktree with a different index or object store.
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $gitExecutable
    $info.WorkingDirectory = $documentRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    foreach ($key in @($info.Environment.Keys)) {
        if ($key -match '^GIT_(TRACE.*|CURL_VERBOSE|DIR|WORK_TREE|COMMON_DIR|INDEX_FILE|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|NAMESPACE|SHALLOW_FILE|REPLACE_REF_BASE|GRAFT_FILE|QUARANTINE_PATH|REDIRECT_STD.*)$') {
            $null = $info.Environment.Remove($key)
        }
    }
    $info.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $info.Environment['GCM_INTERACTIVE'] = 'never'
    $info.Environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    foreach ($arg in @("--git-dir=$repository",'-c','core.longpaths=true','-c','http.followRedirects=false','-c',"http.$RemoteUrl.followRedirects=false",'-c','protocol.allow=never','-c',"protocol.$transport.allow=always",'-c','maintenance.auto=false','-c','gc.auto=0') + $Arguments) {
        $info.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Git could not start.' }
        $errors = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        if ($HashOutput) {
            $sha = [Security.Cryptography.SHA256]::Create()
            $read = $sha.ComputeHashAsync($process.StandardOutput.BaseStream)
        } elseif ($HeaderOnly) { $read = $process.StandardOutput.ReadLineAsync() }
        else { $read = $process.StandardOutput.ReadToEndAsync() }
        if ($InputStream) { $InputStream.CopyTo($process.StandardInput.BaseStream) }
        elseif ($InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        if ($HeaderOnly) {
            if (-not $read.Wait(120000)) { throw 'Timed out reading repository session metadata.' }
            $drain = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
        }
        if (-not $process.WaitForExit(120000)) { throw 'Git operation timed out.' }
        if ($HeaderOnly) { $drain.GetAwaiter().GetResult() | Out-Null }
        $null = $errors.GetAwaiter().GetResult()
        if (-not $AllowFailure -and $process.ExitCode) {
            throw "Git $($Arguments[0]) failed (exit $($process.ExitCode))."
        }
        $output = if ($HashOutput) { [Convert]::ToHexString($read.GetAwaiter().GetResult()).ToLowerInvariant() }
            else { $read.GetAwaiter().GetResult() }
        [pscustomobject]@{Code=$process.ExitCode; Text=$output}
    } finally {
        if ($HashOutput -and $sha) { $sha.Dispose() }
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

function Get-AnimTeamTreeEntries([string]$Tree) {
    if (!$treeListings.ContainsKey($Tree)) {
        $treeListings[$Tree] = (Invoke-AnimTeamPublishGit @('ls-tree','-z',$Tree)).Text.Split([char]0)
    }
    return $treeListings[$Tree]
}

function Get-AnimTeamPublishTree([string]$Base, [string]$Folder, [switch]$Images) {
    # Check every ancestor before update-index. A file/symlink or a directory
    # at a document path must never be replaced by an upsert.
    $tree = $Base
    foreach ($part in $Folder.Split('/')) {
        $nextTree = $null
        foreach ($entry in (Get-AnimTeamTreeEntries $tree)) {
            $pair = $entry.Split("`t",2)
            if ($pair.Count -ne 2 -or -not $part.Equals($pair[1],[StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($nextTree -or $part -cne $pair[1] -or $pair[0] -cnotmatch '^040000 tree ([0-9a-f]{40,64})$') {
                throw 'A destination directory conflicts with a repository entry.'
            }
            $nextTree = $Matches[1]
        }
        if (-not $nextTree) { return @{} }
        $tree = $nextTree
    }
    $files = @{}
    $pattern = if ($Images) { '[0-9a-f]{64}\.(?:png|jpg|gif|webp)' } else { '[a-f0-9-]{36}\.md' }
    foreach ($entry in (Get-AnimTeamTreeEntries $tree)) {
        if ($entry -imatch "^(\d{6}) [a-z]+ ([0-9a-f]{40,64})\t($pattern)$") {
            $name = $Matches[3]
            if ($files.ContainsKey($name)) { throw 'Ambiguous filenames in repository.' }
            $files[$name] = @{Mode=$Matches[1]; Object=$Matches[2]; Name=$name}
        }
    }
    return $files
}

function Get-AnimTeamPublishPictures([string]$Text,[string]$Session) {
    # Transcript text is indented and cannot introduce a publisher-owned image line.
    foreach ($match in [regex]::Matches($Text,'(?m)^!\[(?:Attached|Generated) image\][^\r\n]*')) {
        if ($match.Value -cnotmatch '\A!\[(?:Attached|Generated) image\]\((images/([0-9a-f-]{36})/[0-9a-f]{64}\.(?:png|jpg|gif|webp))\)\z' -or
            $Matches[2] -cne $Session) { throw 'Invalid session image reference.' }
        $Matches[1]
    }
}

function Restore-AnimTeamPublishPictures([string]$Local,[string]$Existing,[string]$Session,[hashtable]$Stored) {
    # A missing source on this machine can use the same visible item's previously archived link.
    # Scope by session, stable item marker and role. Removed or moderated slots cannot reappear.
    $marker = '(?m)^<!-- anim-team-image ([0-9a-f]{64}) -->\r?\n'
    $archived = @{}
    foreach ($match in [regex]::Matches($Existing, $marker + '(!\[(Attached|Generated) image\]\(images/([0-9a-f-]{36})/([0-9a-f]{64}\.(?:png|jpg|gif|webp))\))(?=\r?$)')) {
        if ($match.Groups[4].Value -cne $Session) { throw 'Invalid archived session image reference.' }
        $leaf = $match.Groups[5].Value
        if ($null -ne $Stored -and !$Stored.ContainsKey($leaf) -and !$stagedImages.ContainsKey("images/$Session/$leaf")) { continue }
        $key = $match.Groups[1].Value + $match.Groups[3].Value
        if ($archived.ContainsKey($key)) { throw 'Ambiguous archived image marker.' }
        $archived[$key] = $match.Groups[2].Value
    }
    return [regex]::Replace($Local, $marker + '(\*(Attached|Generated) image unavailable\.\*)(?=\r?$)', {
        param($match)
        $link = $archived[$match.Groups[1].Value + $match.Groups[3].Value]
        if ($link) { return $match.Value.Substring(0,$match.Value.Length - $match.Groups[2].Length) + $link }
        return $match.Value
    })
}

function Read-AnimTeamStagedImage([string]$Relative) {
    $path = $documentRoot
    foreach ($part in $Relative.Split('/')) {
        $entry = [IO.DirectoryInfo]::new($path).GetFileSystemInfos($part)
        if (!$entry.Count) { return }
        if ($entry.Count -ne 1 -or $entry[0].Name -cne $part -or $entry[0].Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Invalid staged image path.'
        }
        $path = $entry[0].FullName
    }
    $file = $entry[0]
    if ($file -isnot [IO.FileInfo]) { throw 'Invalid staged image file.' }
    # Windows denies concurrent writes/deletes while this handle hashes and supplies the same bytes to Git.
    $stream = $file.Open('Open','Read','Read')
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = [Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant() }
        finally { $sha.Dispose() }
        $stream.Position = 0
        $oid = (Invoke-AnimTeamPublishGit @('hash-object','--no-filters','-w','--stdin') -InputStream $stream).Text.Trim()
        if ($oid -cnotmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z') { throw 'Invalid Git image hash.' }
        return @{object=$oid; digest=$digest}
    } finally { $stream.Dispose() }
}

function Publish-AnimTeamSessionDocuments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DocumentDirectory,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$StateDirectory,
        [Parameter(Mandatory)][string]$RemoteUrl,
        [switch]$RequireCompleteBatch,
        [switch]$IncludeImages,
        [string]$BatchDate,
        [string]$ReceiptDirectory
    )
    $ErrorActionPreference = 'Stop'
    $subject = 'Update Codex session documents'
    if ($PSBoundParameters.ContainsKey('BatchDate')) {
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($BatchDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None,[ref]$parsed)) { throw 'Invalid evening batch date. Use yyyy-MM-dd.' }
        $subject = "Publish evening Codex sessions for $BatchDate"
    }
    $official = 'https://github.com/YHAnimationStudios/YH_Knowledge_database.git'
    if ($RemoteUrl -ceq $official) { $transport = 'https' }
    elseif (([Uri]$RemoteUrl).IsFile -and $RemoteUrl.StartsWith('file:///',[StringComparison]::Ordinal)) { $transport = 'file' }
    else { throw 'Invalid publication destination.' }
    if (-not (Test-CodexEmailFolder $Email) -or $Email -cne $Email.ToLowerInvariant()) {
        throw 'Invalid canonical seat email.'
    }
    $folder = "Character art team/Codex usage data/$Email"
    $rootInfo = Get-Item -LiteralPath $DocumentDirectory -Force
    if ($rootInfo -isnot [IO.DirectoryInfo]) { throw 'Invalid document directory.' }
    for ($ancestor = $rootInfo; $ancestor; $ancestor = $ancestor.Parent) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Redirected document directory.' }
    }
    $documentRoot = $rootInfo.FullName
    $documents = @(Get-ChildItem -LiteralPath $documentRoot -File -Force -Filter '*.md' | Sort-Object Name)
    $candidatePath = $null
    if ($PSBoundParameters.ContainsKey('ReceiptDirectory')) {
        if (!$RequireCompleteBatch -or !$BatchDate -or ![IO.Directory]::Exists($ReceiptDirectory)) { throw 'A dated complete batch requires an existing private receipt directory.' }
        Assert-LibrarianPrivatePath $ReceiptDirectory -Protected
        $candidatePath = Join-Path $ReceiptDirectory 'publish-candidate.json'
        Assert-LibrarianPrivatePath $candidatePath
        if (!$documents.Count -and [IO.File]::Exists($candidatePath)) { throw 'The pending publication snapshot changed.' }
    }
    $report = [ordered]@{pushed=0; pushedImages=0; unchanged=0; older=0; conflicts=0; conflictSessions=@(); deferred=0; commit=$null; head=$null; recovered=$false; uncertain=$false}
    if (-not $documents.Count) { return ($report | ConvertTo-Json -Compress) }
    $versions = @{}
    $pictures = @{}
    $hasMissing = @{}
    $stagedImages = @{}
    foreach ($doc in $documents) {
        if ($doc.Name -cnotmatch '\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\.md\z' -or ($doc.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Invalid session document filename or file type.'
        }
    }
    $gitExecutable = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $state = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StateDirectory)
    New-LibrarianPrivateDirectory $state
    $cachePath = Join-Path $state ("confirmed-" + (Get-LibrarianKey $Email) + '.json')
    $repository = Join-Path $state ('publish-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($repository)
    $cacheLock = $null
    try {
        $cacheLock = Open-LibrarianLock ($cachePath + '.lock')
        $known = @{}
        Assert-LibrarianPrivatePath $cachePath
        if ([IO.File]::Exists($cachePath)) {
            $saved = Read-LibrarianJson $cachePath
            if ($saved.schemaVersion -ne 1 -or $saved.email -cne $Email -or $saved.sessions -isnot [pscustomobject]) {
                throw 'Invalid confirmed publication state.'
            }
            foreach ($item in $saved.sessions.PSObject.Properties) {
                if ($item.Name -cnotmatch '\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\.md\z' -or
                    $item.Value -isnot [string] -or $item.Value -cnotmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z') {
                    throw 'Invalid confirmed publication entry.'
                }
                $known[$item.Name] = $item.Value
            }
        }
        $null = Invoke-AnimTeamPublishGit @('init','--quiet','--bare','--template=',$repository)
        $null = Invoke-AnimTeamPublishGit @('config','--local','core.hooksPath',(Join-Path $repository 'disabled-hooks'))
        $null = Invoke-AnimTeamPublishGit @('remote','add','origin',$RemoteUrl)
        foreach ($query in @(@('remote','get-url','--all','origin'),@('remote','get-url','--push','--all','origin'))) {
            if ((Invoke-AnimTeamPublishGit $query).Text.TrimEnd("`r","`n") -cne $RemoteUrl) { throw 'Git configuration changes the publication destination.' }
        }
        $null = Invoke-AnimTeamPublishGit @('config','--local','remote.origin.promisor','true')
        $null = Invoke-AnimTeamPublishGit @('config','--local','remote.origin.partialclonefilter','blob:none')
        $hashes = [Collections.Generic.List[string]]::new()
        for ($start = 0; $start -lt $documents.Count; $start += 128) {
            $chunk = @($documents[$start..([math]::Min($start + 127,$documents.Count - 1))])
            $readers = [Collections.Generic.List[IO.StreamReader]]::new()
            try {
                foreach ($doc in $chunk) {
                    # Keep the Windows read handle until Git has captured the same bytes. This
                    # also protects direct callers publishing a directory still being edited.
                    $doc.Refresh()
                    if ($doc.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Redirected session document.' }
                    $reader = $doc.OpenText()
                    $readers.Add($reader)
                    $versions[$doc.Name] = Get-AnimTeamPublishMetadata $reader.ReadLine()
                    $body = $reader.ReadToEnd()
                    $pictures[$doc.Name] = @(Get-AnimTeamPublishPictures $body $doc.BaseName)
                    if ($pictures[$doc.Name].Count -and !$IncludeImages) { throw 'Session picture publication requires enrollment consent.' }
                    foreach ($rel in $pictures[$doc.Name]) { $stagedImages[$rel] = $null }
                    $hasMissing[$doc.Name] = $IncludeImages -and $body.Contains(' image unavailable.*')
                }
                $oids = (Invoke-AnimTeamPublishGit @('hash-object','--no-filters','-w','--stdin-paths') -InputText (($chunk.Name -join "`n") + "`n")).Text.TrimEnd().Split("`n")
                if ($oids.Count -ne $chunk.Count) { throw 'Git returned an incomplete document hash list.' }
                $hashes.AddRange($oids)
            } finally { foreach ($reader in $readers) { $reader.Dispose() } }
        }
        # Snapshot locally supplied picture bytes along with the Markdown. Only paths referenced
        # by accepted documents are placed in the Git index or reachable from a new commit.
        $candidate = $null
        if ($candidatePath) {
            foreach ($rel in @($stagedImages.Keys)) { $stagedImages[$rel] = Read-AnimTeamStagedImage $rel }
            $manifest = @(
                for ($i = 0; $i -lt $documents.Count; $i++) { "$($documents[$i].Name) $($hashes[$i].Trim())" }
                foreach ($rel in ($stagedImages.Keys | Sort-Object)) { "$rel $($stagedImages[$rel].digest)" }
            )
            $snapshot = Get-LibrarianKey ($manifest -join "`n")
            if ([IO.File]::Exists($candidatePath)) {
                $candidate = Read-LibrarianJson $candidatePath
                if ($candidate.schemaVersion -notin 1,2 -or $candidate.email -cne $Email -or $candidate.batchDate -cne $BatchDate -or
                    $candidate.snapshot -cne $snapshot -or $candidate.commit -cnotmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z' -or
                    $candidate.base -cnotmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z') { throw 'Invalid candidate for the pending publication snapshot.' }
                foreach ($key in 'pushed','unchanged','older') {
                    $n = $candidate.$key
                    if (($n -isnot [long] -and $n -isnot [int]) -or $n -lt 0 -or $n -gt $documents.Count) { throw 'Invalid candidate counts.' }
                }
                if ($candidate.schemaVersion -eq 1) {
                    if ($stagedImages.Count -or $candidate.PSObject.Properties['pushedImages']) { throw 'Invalid legacy candidate.' }
                    $candidate | Add-Member -NotePropertyName pushedImages -NotePropertyValue 0
                }
                $imageCount = $candidate.pushedImages
                $suppliedPictures = @($stagedImages.Values | Where-Object { $_ }).Count
                if (($imageCount -isnot [long] -and $imageCount -isnot [int]) -or $imageCount -lt 0 -or $imageCount -gt $suppliedPictures) { throw 'Invalid candidate image count.' }
                if ((!$candidate.pushed -and !$imageCount) -or $candidate.pushed + $candidate.unchanged + $candidate.older -ne $documents.Count) { throw 'Invalid candidate totals.' }
            }
        }
        $previousBase = ''
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            # On recovery fetch bounded commit ancestry without downloading old document trees.
            $fetchLimits = if ($candidate) { @('--depth=256','--filter=tree:0') } else { @('--depth=1','--filter=blob:none') }
            $null = Invoke-AnimTeamPublishGit (@('fetch','--quiet') + $fetchLimits + @('--no-tags','origin','refs/heads/main'))
            $base = (Invoke-AnimTeamPublishGit @('rev-parse','--verify','FETCH_HEAD^{commit}')).Text.Trim()
            $report.head = $base
            $accepted = $false
            $parentSeen = $false
            if ($candidate) {
                $history = (Invoke-AnimTeamPublishGit @('rev-list',$base)).Text.Split([char[]]"`r`n",[StringSplitOptions]::RemoveEmptyEntries)
                $accepted = $history -ccontains $candidate.commit
                $parentSeen = $history -ccontains $candidate.base
            }
            # A rejected push with the same server tip is a permissions, policy or
            # transport failure. Retrying an identical commit cannot reconcile it.
            if ($base -ceq $previousBase) { throw 'Publish rejected. Check Git authentication, write access, and main branch rules.' }
            $report.unchanged = 0
            $report.older = 0
            $changes = [Text.StringBuilder]::new()
            $conflicts = [Collections.Generic.List[string]]::new()
            $confirm = @{}
            $treeListings = @{}
            $files = Get-AnimTeamPublishTree $base $folder
            $requiredPictures = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $changedCount = 0
            for ($i = 0; $i -lt $documents.Count; $i++) {
                $name = $documents[$i].Name
                $oid = $hashes[$i].Trim()
                $docPictures = $pictures[$name]
                $mode = '100644'
                if ($oid -cnotmatch '^[0-9a-f]{40,64}$') { throw 'Invalid Git document hash.' }
                # A proven commit already completed this batch. Only seed exact current matches
                # in the local cache; another writer may since have replaced or deleted a session.
                if ($accepted -and (!$files.ContainsKey($name) -or $files[$name].Object -cne $oid)) { continue }
                if ($files.ContainsKey($name)) {
                    $existing = $files[$name]
                    if ($existing.Name -cne $name -or $existing.Mode -notin '100644','100755') { throw 'A conflicting entry occupies the document path.' }
                    $mode = $existing.Mode
                    if ($existing.Object -cne $oid) {
                        $line = (Invoke-AnimTeamPublishGit @('cat-file','blob',$existing.Object) -HeaderOnly).Text
                        $old = Get-AnimTeamPublishMetadata $line
                        $new = $versions[$name]
                        $onlyMissingFiles = $false
                        if ($new.updatedAt -lt $old.updatedAt -or $new.messages -lt $old.messages) { $report.older++; continue }
                        if ($hasMissing[$name]) {
                            $localText = (Invoke-AnimTeamPublishGit @('cat-file','blob',$oid)).Text
                            $remoteText = (Invoke-AnimTeamPublishGit @('cat-file','blob',$existing.Object)).Text
                            $id = $documents[$i].BaseName
                            $withAllLinks = Restore-AnimTeamPublishPictures $localText $remoteText $id
                            if ($withAllLinks -cne $localText) {
                                $stored = Get-AnimTeamPublishTree $base "$folder/images/$id" -Images
                                $merged = Restore-AnimTeamPublishPictures $localText $remoteText $id $stored
                                $onlyMissingFiles = $withAllLinks -ceq $remoteText -and $merged -cne $withAllLinks
                                if ($merged -cne $localText) {
                                    $oid = (Invoke-AnimTeamPublishGit @('hash-object','--no-filters','-w','--stdin') -InputText $merged).Text.Trim()
                                    $docPictures = @(Get-AnimTeamPublishPictures $merged $id)
                                }
                            }
                        }
                        if ($oid -cne $existing.Object -and $new.updatedAt -eq $old.updatedAt -and $new.messages -eq $old.messages) {
                            # An exact legacy projection can prove a pure picture backfill even for a
                            # newly enrolled device. Tied independent edits still require a common base.
                            if ($known[$name] -ceq $oid -or $old.legacyOid -ceq $oid) { $report.older++; continue }
                            if ($known[$name] -cne $existing.Object) {
                                $pureBackfill = $onlyMissingFiles -or ($IncludeImages -and $new.legacyOid -ceq $existing.Object)
                                if (!$pureBackfill -and $IncludeImages -and $docPictures.Count -and $new.legacyOid -and $new.legacyOid -ceq $old.legacyOid) {
                                    # Two devices may have different access to the same visible image.
                                    # Verify that filling matching empty slots accounts for the entire diff.
                                    $remoteText = (Invoke-AnimTeamPublishGit @('cat-file','blob',$existing.Object)).Text
                                    $localText = (Invoke-AnimTeamPublishGit @('cat-file','blob',$oid)).Text
                                    $pureBackfill = (Restore-AnimTeamPublishPictures $remoteText $localText $documents[$i].BaseName) -ceq $localText
                                }
                                if (!$pureBackfill) {
                                    $conflicts.Add($documents[$i].BaseName)
                                    continue
                                }
                            }
                        }
                    }
                    if ($existing.Object -ceq $oid) {
                        $report.unchanged++
                        if ($known[$name] -cne $oid) { $confirm[$name] = $oid }
                        foreach ($rel in $docPictures) { $null = $requiredPictures.Add($rel) }
                        continue
                    }
                }
                $null = $changes.Append("$mode $oid`t$folder/$name`n")
                foreach ($rel in $docPictures) { $null = $requiredPictures.Add($rel) }
                $confirm[$name] = $oid
                $changedCount++
            }
            $report.conflicts = $conflicts.Count
            $report.conflictSessions = $conflicts.ToArray()
            if ($RequireCompleteBatch -and $conflicts.Count) {
                $report.deferred = $changedCount
                return ($report | ConvertTo-Json -Compress)
            }
            $changedImages = 0
            if (!$accepted) {
                $sessionTrees = @{}
                foreach ($rel in ($requiredPictures | Sort-Object)) {
                    $parts = $rel.Split('/')
                    $session = $parts[1]
                    $leaf = $parts[2]
                    if (!$sessionTrees.ContainsKey($session)) {
                        $sessionTrees[$session] = Get-AnimTeamPublishTree $base "$folder/images/$session" -Images
                    }
                    $existing = $sessionTrees[$session][$leaf]
                    if (!$candidatePath -and $stagedImages.ContainsKey($rel) -and !$stagedImages[$rel]) {
                        $stagedImages[$rel] = Read-AnimTeamStagedImage $rel
                    }
                    $localImage = $stagedImages[$rel]
                    $localOid = $localImage.object
                    if ($localImage -and $localImage.digest -cne $leaf.Split('.')[0]) { throw 'Staged image content does not match its address.' }
                    if ($existing) {
                        if ($existing.Name -cne $leaf -or $existing.Mode -cne '100644') { throw 'A conflicting entry occupies the image path.' }
                        if ($localOid) {
                            if ($localOid -cne $existing.Object) { throw 'Existing image content does not match its address.' }
                        } else {
                            $digest = (Invoke-AnimTeamPublishGit @('cat-file','blob',$existing.Object) -HashOutput).Text
                            if ($digest -cne $leaf.Split('.')[0]) { throw 'Archived image content does not match its address.' }
                        }
                    } elseif ($localOid) {
                        $null = $changes.Append("100644 $localOid`t$folder/$rel`n")
                        $changedImages++
                    } else { throw 'Missing session image content.' }
                }
            }
            if ($accepted) {
                foreach ($key in 'pushed','pushedImages','unchanged','older','commit') { $report[$key] = $candidate.$key }
                $report.recovered = $true
            } elseif ($candidate -and !$changedCount -and !$changedImages) {
                $report.uncertain = $true
            }
            if ($changedCount -or $changedImages) {
                if ($candidate -and !$parentSeen) { throw 'Cannot establish the outcome of the previous evening push from available repository history.' }
                $null = Invoke-AnimTeamPublishGit @('read-tree',$base)
                $null = Invoke-AnimTeamPublishGit @('update-index','--index-info') -InputText $changes.ToString()
                $tree = (Invoke-AnimTeamPublishGit @('write-tree')).Text.Trim()
                $commit = (Invoke-AnimTeamPublishGit @('-c','user.name=Character Art Team Librarian','-c',"user.email=$Email",'-c','commit.gpgSign=false','commit-tree',$tree,'-p',$base,'-m',$subject)).Text.Trim()
                if ((Get-LibrarianRepositoryHttpStatus) -ne 404) { throw 'Repository visibility could not be verified. Publication stopped.' }
                if ($candidatePath) {
                    $candidate = @{schemaVersion=2; email=$Email; batchDate=$BatchDate; snapshot=$snapshot; base=$base; commit=$commit
                        pushed=$changedCount; pushedImages=$changedImages; unchanged=$report.unchanged; older=$report.older}
                    Write-LibrarianJson $candidatePath $candidate -Replace
                }
                $push = Invoke-AnimTeamPublishGit @('push','--quiet','--no-follow-tags','--recurse-submodules=no','origin',"${commit}:refs/heads/main") -AllowFailure
                if ($push.Code) { $previousBase = $base; continue }
                $report.pushed = $changedCount
                $report.pushedImages = $changedImages
                $report.commit = $commit
                $report.head = $commit
            }
            if ($confirm.Count) {
                foreach ($name in $confirm.Keys) { $known[$name] = $confirm[$name] }
                Write-LibrarianJson $cachePath @{schemaVersion=1; email=$Email; sessions=$known} -Replace
            }
            return ($report | ConvertTo-Json -Compress)
        }
        throw 'Concurrent publication did not settle. Retry this collection.'
    } finally {
        if ($cacheLock) { $cacheLock.Dispose() }
        $absolute = [IO.Path]::GetFullPath($repository)
        if ([IO.Path]::GetDirectoryName($absolute) -eq [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($state)) -and
            [IO.Path]::GetFileName($absolute) -match '^publish-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $absolute -Force -Recurse
        }
    }
}
