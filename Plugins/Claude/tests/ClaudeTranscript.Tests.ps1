BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'ClaudeTranscript' {
    BeforeAll {
        $script:Scripts = New-LibrarianTestPlugin 'anim'
        . (Join-Path $script:Scripts 'ClaudeTranscript.ps1')
        $script:Fx = Join-Path $PSScriptRoot 'fixtures/transcripts'
        function script:Get-Messages([string]$Name) {
            $read = Read-ClaudeTranscriptRecords (Join-Path $script:Fx $Name)
            $branch = Select-ClaudeActiveBranch $read.records
            return @(ConvertTo-ClaudeMessages $branch)
        }
        function script:Get-Flat($Messages) {
            return @($Messages | ForEach-Object { $m = $_; $m.parts | ForEach-Object { "$($m.role):$($_.text)$($_.name)" } })
        }
    }

    It 'exports plain user and assistant text' {
        $m = Get-Messages 'basic.jsonl'
        $m.Count | Should -Be 2
        $m[0].role | Should -BeExactly 'User'
        $m[0].parts[0].text | Should -BeExactly 'hello there'
        $m[1].role | Should -BeExactly 'Assistant'
        $m[1].parts[0].text | Should -BeExactly 'Hi! How can I help?'
        $m[0].id | Should -BeExactly 'u1'
        $m[0].time | Should -BeOfType ([datetimeoffset])
        $m[0].time.UtcDateTime | Should -Be ([datetime]::new(2026, 11, 25, 10, 0, 0, [DateTimeKind]::Utc))
    }

    It 'drops tool use, tool results and thinking' {
        $m = Get-Messages 'tools.jsonl'
        $m.Count | Should -Be 2
        $m[1].role | Should -BeExactly 'Assistant'
        $m[1].parts.Count | Should -Be 1
        $m[1].parts[0].text | Should -BeExactly 'Done.'
        (ConvertTo-Json $m -Depth 8) | Should -Not -Match 'SECRET|thoughts'
    }

    It 'drops meta, compact summary and api error records' {
        $flat = Get-Flat (Get-Messages 'meta.jsonl')
        $flat | Should -Be @('User:real question', 'Assistant:real answer')
    }

    It 'removes system reminders and renders slash commands' {
        $m = Get-Messages 'commands.jsonl'
        $m.Count | Should -Be 2
        $m[0].parts.Count | Should -Be 1
        $m[0].parts[0].type | Should -BeExactly 'command'
        $m[0].parts[0].name | Should -BeExactly '/compact'
        $m[1].parts[0].type | Should -BeExactly 'text'
        $m[1].parts[0].text | Should -BeExactly 'fix it'
    }

    It 'merges an assistant reply split across records' {
        $m = Get-Messages 'split.jsonl'
        $m.Count | Should -Be 2
        $m[1].role | Should -BeExactly 'Assistant'
        @($m[1].parts | ForEach-Object text) | Should -Be @('A', 'B')
    }

    It 'exports only the active branch after a rewind' {
        $flat = Get-Flat (Get-Messages 'rewind.jsonl')
        $flat | Should -Be @('User:U1', 'Assistant:A1', 'User:U2b', 'Assistant:A2b')
    }

    It 'follows logicalParentUuid across compaction' {
        $flat = Get-Flat (Get-Messages 'compact.jsonl')
        $flat | Should -Be @('User:before compaction', 'Assistant:answer before', 'User:after compaction', 'Assistant:answer after')
        # System records are never exported.
        $read = Read-ClaudeTranscriptRecords (Join-Path $script:Fx 'compact.jsonl')
        @($read.records | Where-Object { $_.type -eq 'system' }).Count | Should -Be 0
    }

    It 'falls back to file order on a broken chain' {
        $flat = Get-Flat (Get-Messages 'broken.jsonl')
        $flat | Should -Be @('User:first', 'Assistant:second', 'User:third', 'Assistant:fourth')
    }

    It 'counts and skips malformed lines anywhere' {
        $read = Read-ClaudeTranscriptRecords (Join-Path $script:Fx 'malformed.jsonl')
        $read.malformedLines | Should -Be 2
        $flat = Get-Flat (Get-Messages 'malformed.jsonl')
        $flat | Should -Be @('User:one', 'Assistant:two', 'User:three')
    }

    It 'prefers custom title over ai title' {
        $read = Read-ClaudeTranscriptRecords (Join-Path $script:Fx 'titles.jsonl')
        Get-ClaudeSessionTitle $read.records | Should -BeExactly 'My custom title'
        $ai = @($read.records | Where-Object { $_.type -ne 'custom-title' })
        Get-ClaudeSessionTitle $ai | Should -BeExactly 'Late AI title'
        Get-ClaudeSessionTitle @() | Should -BeNullOrEmpty
    }

    It 'keeps image blocks as ordered image parts' {
        $m = Get-Messages 'image.jsonl'
        $m.Count | Should -Be 1
        @($m[0].parts | ForEach-Object type) | Should -Be @('text', 'image', 'image')
        $m[0].parts[0].text | Should -BeExactly 'look at these'
        $m[0].parts[1].block.source.data | Should -BeExactly 'AAAA'
        $m[0].parts[2].block.source.data | Should -BeExactly 'BBBB'
        @($m[0].parts[1].ordinal, $m[0].parts[2].ordinal) | Should -Be @(1, 2)
        (ConvertTo-Json $m -Depth 8) | Should -Not -Match 'LEAK'
    }

    It 'walks through attachment and stop-hook records without publishing abandoned branches' {
        $flat = Get-Flat (Get-Messages 'linked.jsonl')
        $flat | Should -Be @('User:U1', 'Assistant:A1', 'User:U2b', 'Assistant:A2b', 'User:U3', 'Assistant:A3')
        $read = Read-ClaudeTranscriptRecords (Join-Path $script:Fx 'linked.jsonl')
        (ConvertTo-Json $read.records -Depth 8) | Should -Not -Match 'ATTACH-SECRET|HOOK-SECRET'
        (ConvertTo-Json (Get-Messages 'linked.jsonl') -Depth 8) | Should -Not -Match 'SECRET'
    }

    It 'excludes the abandoned reply before a compaction boundary' {
        $flat = Get-Flat (Get-Messages 'compact.jsonl')
        $flat | Should -Not -Contain 'Assistant:abandoned reply'
    }

    It 'throws when the transcript cannot be opened, whatever the error preference' {
        $missing = Join-Path (Get-TestDriveRoot) 'nope.jsonl'
        $old = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            { Read-ClaudeTranscriptRecords $missing } | Should -Throw
        } finally { $ErrorActionPreference = $old }
    }

    It 'strips command output and unclosed reminders from mixed text' {
        $flat = Get-Flat (Get-Messages 'mixed.jsonl')
        $flat | Should -Be @('User:see this  ok', 'User:visible text', 'Assistant:fine')
        ($flat -join '|') | Should -Not -Match 'CMDOUT|LEAK|reminder'
    }

    It 'strips IDE context, task notifications and hook text, closed or unclosed' {
        $flat = Get-Flat (Get-Messages 'context.jsonl')
        $flat | Should -Be @('User:please fix', 'User:why does it fail', 'User:run', 'User:thanks next', 'Assistant:fine')
        (ConvertTo-Json (Get-Messages 'context.jsonl') -Depth 8) | Should -Not -Match 'LEAK|SECRET|secret\.ps1|ide_|task-notification|hook'
    }

    It 'renders a command name without a leading slash as a slash command' {
        $path = Join-Path (Get-TestDriveRoot) 'noslash.jsonl'
        $lines = @(
            '{"type":"user","uuid":"c1","parentUuid":null,"timestamp":"2026-11-25T10:00:00.000Z","message":{"role":"user","content":"<command-name>compact</command-name><command-message>compact</command-message>"}}'
            '{"type":"user","uuid":"c2","parentUuid":"c1","timestamp":"2026-11-25T10:00:01.000Z","message":{"role":"user","content":"<command-name>/model</command-name>"}}'
        )
        [IO.File]::WriteAllLines($path, $lines)
        $read = Read-ClaudeTranscriptRecords $path
        $m = ConvertTo-ClaudeMessages (Select-ClaudeActiveBranch $read.records)
        $m.Count | Should -Be 2
        $m[0].parts.Count | Should -Be 1
        $m[0].parts[0].type | Should -BeExactly 'command'
        $m[0].parts[0].name | Should -BeExactly '/compact'
        $m[1].parts[0].name | Should -BeExactly '/model'
    }

    It 'does not export a replaced duplicate uuid twice in the fallback' {
        $path = Join-Path (Get-TestDriveRoot) 'dup.jsonl'
        $lines = @(
            '{"type":"user","uuid":"d1","parentUuid":null,"timestamp":"2026-11-25T10:00:00.000Z","message":{"role":"user","content":"old"}}'
            '{"type":"user","uuid":"d1","parentUuid":null,"timestamp":"2026-11-25T10:00:01.000Z","message":{"role":"user","content":"new"}}'
            '{"type":"user","uuid":"d2","parentUuid":"missing","timestamp":"2026-11-25T10:00:02.000Z","message":{"role":"user","content":"tail"}}'
        )
        [IO.File]::WriteAllLines($path, $lines)
        $read = Read-ClaudeTranscriptRecords $path
        $msgs = ConvertTo-ClaudeMessages (Select-ClaudeActiveBranch $read.records)
        $flat = Get-Flat $msgs
        @($flat | Where-Object { $_ -like 'User:old' -or $_ -like 'User:new' }).Count | Should -Be 1
    }

    It 'streams a 60000-line transcript' {
        $path = Join-Path (Get-TestDriveRoot) 'big.jsonl'
        $writer = [IO.StreamWriter]::new($path, $false, [Text.UTF8Encoding]::new($false))
        try {
            $prev = 'null'
            for ($i = 1; $i -le 60000; $i++) {
                $type = if ($i % 2) { 'user' } else { 'assistant' }
                $msg = if ($i % 2) { '{"role":"user","content":"question ' + $i + '"}' }
                       else { '{"id":"m' + $i + '","role":"assistant","content":[{"type":"text","text":"answer ' + $i + '"}]}' }
                $writer.WriteLine('{"type":"' + $type + '","uuid":"r' + $i + '","parentUuid":' + $prev + ',"timestamp":"2026-11-25T10:00:00.000Z","message":' + $msg + '}')
                $prev = '"r' + $i + '"'
            }
        } finally { $writer.Dispose() }
        [GC]::Collect()
        $before = [Diagnostics.Process]::GetCurrentProcess().WorkingSet64
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $read = Read-ClaudeTranscriptRecords $path
        $branch = Select-ClaudeActiveBranch $read.records
        $messages = ConvertTo-ClaudeMessages $branch
        $sw.Stop()
        $growthMb = ([Diagnostics.Process]::GetCurrentProcess().WorkingSet64 - $before) / 1MB
        $messages.Count | Should -Be 60000
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 60
        $growthMb | Should -BeLessThan 200
    }

    It 'keeps memory flat on a tool-heavy transcript and retains no tool payloads' {
        $path = Join-Path (Get-TestDriveRoot) 'tools-big.jsonl'
        $payload = 'TOOLRESULT-' + ('x' * 100000)
        $writer = [IO.StreamWriter]::new($path, $false, [Text.UTF8Encoding]::new($false))
        try {
            $prev = 'null'
            $n = 0
            for ($i = 1; $i -le 2000; $i++) {
                $records = @(
                    ,@('user', ('{"role":"user","content":"question ' + $i + '"}'))
                    ,@('assistant', ('{"id":"t' + $i + '","role":"assistant","content":[{"type":"thinking","thinking":"THINKING-SECRET"},{"type":"tool_use","id":"tu' + $i + '","name":"Read","input":{"file_path":"C:\\x\\TOOLUSE-SECRET.txt"}}]}'))
                    ,@('user', ('{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu' + $i + '","content":"' + $payload + '"}]}'))
                    ,@('assistant', ('{"id":"a' + $i + '","role":"assistant","content":[{"type":"text","text":"answer ' + $i + '"}]}'))
                )
                foreach ($r in $records) {
                    $n++
                    $writer.WriteLine('{"type":"' + $r[0] + '","uuid":"r' + $n + '","parentUuid":' + $prev + ',"timestamp":"2026-11-25T10:00:00.000Z","toolUseResult":{"stdout":"' + $(if ($r[1].Contains('tool_result')) { $payload } else { '' }) + '"},"message":' + $r[1] + '}')
                    $prev = '"r' + $n + '"'
                }
            }
        } finally { $writer.Dispose() }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        $before = [Diagnostics.Process]::GetCurrentProcess().WorkingSet64
        $read = Read-ClaudeTranscriptRecords $path
        $branch = Select-ClaudeActiveBranch $read.records
        $messages = ConvertTo-ClaudeMessages $branch
        $growthMb = ([Diagnostics.Process]::GetCurrentProcess().WorkingSet64 - $before) / 1MB
        $messages.Count | Should -Be 4000
        $messages[1].parts[0].text | Should -BeExactly 'answer 1'
        $growthMb | Should -BeLessThan 200
        $retained = [Collections.Generic.List[string]]::new()
        foreach ($record in $read.records) {
            if ($record.ContainsKey('toolUseResult')) { $retained.Add("$($record['uuid']):toolUseResult") }
            $content = if ($record['message'] -is [hashtable]) { $record['message']['content'] }
            if ($content -is [string]) {
                if ($content -match 'TOOLRESULT|SECRET') { $retained.Add("$($record['uuid']):string") }
                continue
            }
            foreach ($block in @($content)) {
                if ($null -ne $block -and $block['type'] -notin 'text', 'image') { $retained.Add("$($record['uuid']):$($block['type'])") }
            }
        }
        $retained.Count | Should -Be 0
    }
}
