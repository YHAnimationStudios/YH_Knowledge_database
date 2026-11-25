BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'LibrarianChatImage' {
    BeforeAll {
        $script:Scripts = New-LibrarianTestPlugin 'anim'
        . (Join-Path $script:Scripts 'LibrarianState.ps1')
        . (Join-Path $script:Scripts 'LibrarianChatImage.ps1')
        function script:New-PngBlock {
            Add-Type -AssemblyName PresentationCore
            $px = [byte[]](10, 20, 30, 255)
            $src = [Windows.Media.Imaging.BitmapSource]::Create(1, 1, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, $px, 4)
            $enc = [Windows.Media.Imaging.PngBitmapEncoder]::new()
            $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($src))
            $ms = [IO.MemoryStream]::new(); $enc.Save($ms)
            return @{ type = 'image'; source = @{ type = 'base64'; media_type = 'image/png'; data = [Convert]::ToBase64String($ms.ToArray()) } }
        }
        function script:New-State {
            @{ id = 'sess-1'; body = [Text.StringBuilder]::new(); assets = [Collections.Generic.HashSet[string]]::new()
               reasons = @{}; available = 0; imageRoot = (Join-Path (Get-TestDriveRoot) ('img-' + [guid]::NewGuid().ToString('N'))) }
        }
    }

    It 'writes a PNG once per session for repeated images' {
        $st = New-State; $b = New-PngBlock
        Add-LibrarianImageReference $b 'm1' 1 $st
        Add-LibrarianImageReference $b 'm2' 1 $st
        @(Get-ChildItem (Join-Path $st.imageRoot 'sess-1') -Filter *.png).Count | Should -Be 1
        $st.available | Should -Be 2
        ([regex]::Matches($st.body.ToString(), [regex]::Escape('![Image attachment](images/sess-1/'))).Count | Should -Be 2
        $st.reasons.Count | Should -Be 0
    }

    It 'marks an oversize image unavailable' {
        $st = New-State
        $b = @{ type = 'image'; source = @{ type = 'base64'; media_type = 'image/png'; data = [Convert]::ToBase64String([byte[]]::new(26MB)) } }
        Add-LibrarianImageReference $b 'm1' 1 $st
        $st.reasons['sizeLimit'] | Should -Be 1
        $st.body.ToString() | Should -Match '\[Image attachment unavailable: sizeLimit\]'
        Test-Path $st.imageRoot | Should -BeFalse
        $st.available | Should -Be 0
    }

    It 'marks a url source unavailable' {
        $st = New-State
        $b = @{ type = 'image'; source = @{ type = 'url'; url = 'https://example.com/a.png' } }
        Add-LibrarianImageReference $b 'm1' 1 $st
        $st.reasons['remoteReference'] | Should -Be 1
        $st.body.ToString() | Should -Match '\[Image attachment unavailable: remoteReference\]'
    }

    It 'marks an unsupported media type unavailable' {
        $st = New-State
        $b = @{ type = 'image'; source = @{ type = 'base64'; media_type = 'image/svg+xml'; data = 'PHN2Zy8+' } }
        Add-LibrarianImageReference $b 'm1' 1 $st
        $st.reasons['unsupportedFormat'] | Should -Be 1
    }
}
