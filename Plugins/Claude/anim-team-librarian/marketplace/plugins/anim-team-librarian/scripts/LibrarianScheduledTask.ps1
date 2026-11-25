#requires -Version 7.2
function Connect-LibrarianTaskService {
    $service = New-Object -ComObject Schedule.Service -ErrorAction Stop
    $service.Connect()
    return $service
}

function Get-LibrarianTaskContext {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $name = "Anim Team Librarian (Claude) - $sid"
    $source = "anim-team-tools/anim-team-librarian-claude/$sid"
    $service = Connect-LibrarianTaskService
    $folder = $service.GetFolder('\')
    $task = $null
    try {
        $task = $folder.GetTask($name)
    } catch {
        # ERROR_FILE_NOT_FOUND for this particular task. Propagate service, folder and access errors.
        if ($_.Exception.GetBaseException().HResult -ne -2147024894) { throw }
    }
    if ($null -ne $task) {
        $definition = $task.Definition
        $owner = [string]$definition.Principal.UserId
        if ($owner -and $owner -notlike 'S-1-*') {
            $owner = [Security.Principal.NTAccount]::new($owner).Translate([Security.Principal.SecurityIdentifier]).Value
        }
        if ($definition.RegistrationInfo.Source -cne $source -or $owner -ne $sid) {
            throw "The scheduled task '$name' belongs to another application or account."
        }
    }
    [pscustomobject]@{ Sid=$sid; Name=$name; Source=$source; Service=$service; Folder=$folder; Task=$task }
}

function Resolve-LibrarianTaskFile([string]$Path, [string]$ExpectedName) {
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or -not [IO.File]::Exists($Path) -or
        [IO.Path]::GetFileName($Path) -ne $ExpectedName) {
        throw "Specify an existing absolute path to $ExpectedName."
    }
    # The Task Scheduler expands environment variable references in its Exec action at run time.
    if ($Path -match '%[^%]+%') { throw "Use a path to $ExpectedName without environment variable references." }
    $full = [IO.Path]::GetFullPath($Path)
    # Never schedule a path that disappears: a versioned Store PowerShell folder or the Claude Code plugin cache.
    if ($full -match '(?i)[\\/]WindowsApps[\\/][^\\/]+[\\/]' -or $full -match '(?i)[\\/]\.claude[\\/]plugins[\\/]') {
        throw "Use a stable path for $ExpectedName, not '$full'."
    }
    return $full
}

function Register-LibrarianScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Runtime,
        [Parameter(Mandatory)][string]$EntryPoint,
        [Parameter(Mandatory)][ValidatePattern('\A(?:[01][0-9]|2[0-3]):[0-5][0-9]\z')][string]$EveningTime
    )
    $command = [Security.SecurityElement]::Escape((Resolve-LibrarianTaskFile $Runtime 'pwsh.exe'))
    $scriptPath = [Security.SecurityElement]::Escape((Resolve-LibrarianTaskFile $EntryPoint 'Sync-AnimTeamSessions.ps1'))
    $context = Get-LibrarianTaskContext

    # A fixed past date keeps catch-up active on the installation day. Omitting a UTC offset
    # anchors the calendar to the machine's local time across DST and time zone changes.
    $xml = @"
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>Anim Team Librarian (Claude)</Author>
    <Description>Backs up the enrolled seat's Claude Code sessions to the Animators team folder.</Description>
    <URI>\$($context.Name)</URI>
    <Source>$($context.Source)</Source>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <Repetition><Interval>PT30M</Interval><Duration>P1D</Duration><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <StartBoundary>2020-01-01T${EveningTime}:00</StartBoundary>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
    <LogonTrigger><UserId>$($context.Sid)</UserId></LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="TeamMember"><UserId>$($context.Sid)</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Enabled>true</Enabled><Hidden>false</Hidden><WakeToRun>false</WakeToRun>
  </Settings>
  <Actions Context="TeamMember">
    <Exec><Command>$command</Command><Arguments>-NoProfile -NonInteractive -WindowStyle Hidden -File "$scriptPath" -Scheduled</Arguments></Exec>
  </Actions>
</Task>
"@
    $desired = $context.Service.NewTask(0)
    $desired.XmlText = $xml
    if ($null -ne $context.Task -and $context.Task.Definition.XmlText -ceq $desired.XmlText) { return }
    # TASK_CREATE never overwrites a task that appeared since lookup. TASK_UPDATE is only
    # used after checking the existing task's registration source and principal.
    $flags = if ($null -eq $context.Task) { 2 } else { 4 }
    try {
        $null = $context.Folder.RegisterTaskDefinition($context.Name, $desired, $flags, $context.Sid, $null, 3, $null)
    } catch {
        if ($flags -ne 2 -or $_.Exception.GetBaseException().HResult -ne -2147024713) { throw }
        $winningTask = (Get-LibrarianTaskContext).Task
        if ($null -eq $winningTask -or $winningTask.Definition.XmlText -cne $desired.XmlText) { throw }
    }
}

function Unregister-LibrarianScheduledTask {
    $context = Get-LibrarianTaskContext
    if ($null -ne $context.Task) {
        try { $context.Folder.DeleteTask($context.Name, 0) }
        catch { if ($_.Exception.GetBaseException().HResult -ne -2147024894) { throw } }
    }
}

function Get-LibrarianScheduledTaskInfo {
    $task = (Get-LibrarianTaskContext).Task
    if ($null -eq $task) { return $null }
    $states = @('Unknown','Disabled','Queued','Ready','Running')
    $entryScriptExists = $false
    try {
        $arguments = [string]$task.Definition.Actions.Item(1).Arguments
        if ($arguments -match '-File "([^"]+)"') { $entryScriptExists = [IO.File]::Exists($Matches[1]) }
    } catch { $entryScriptExists = $false }
    $next = [datetime]$task.NextRunTime
    [pscustomobject]@{
        taskName = [string]$task.Name
        state = $states[[int]$task.State]
        nextRunTime = if ($next -gt [datetime]'1900-01-01') { $next.ToString('o') }
        lastTaskResult = $task.LastTaskResult
        entryScriptExists = $entryScriptExists
    }
}
