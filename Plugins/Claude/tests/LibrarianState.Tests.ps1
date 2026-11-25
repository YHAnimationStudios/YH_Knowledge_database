BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Scripts = New-LibrarianTestPlugin 'anim'
    . (Join-Path $script:Scripts 'LibrarianState.ps1')
}

Describe 'LibrarianState' {
    It 'uses the Claude-specific state folder' {
        $dir = Get-LibrarianStateDirectory
        $dir | Should -BeLike '*\YHAnimTeamClaudeLibrarian\plugin-state'
    }

    It 'creates a private directory' {
        $d = Join-Path $TestDrive 'private-dir'
        New-LibrarianPrivateDirectory $d
        [IO.Directory]::Exists($d) | Should -BeTrue
    }
}
