# Pictures enter here only as inline base64 bytes of user-pasted `image` blocks.
# Never read a path or URL discovered in conversation text, tool output or a filename hint.
$imageByteLimit = 25MB
$imagePixelLimit = 24000000

function Throw-LibrarianImageUnavailable([string] $Reason) {
    $errorInfo = [IO.InvalidDataException]::new('Image unavailable.')
    $errorInfo.Data['imageReason'] = $Reason
    throw $errorInfo
}

function Get-LibrarianImageHash([byte[]] $Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Read-LibrarianClaudeImage($Block) {
    $source = $Block.source
    if ($source -isnot [System.Collections.IDictionary] -or $source.type -cne 'base64') { Throw-LibrarianImageUnavailable 'remoteReference' }
    $mediaType = $source.media_type
    if ($mediaType -isnot [string] -or $mediaType.ToLowerInvariant() -notmatch '^image/(png|jpeg|gif|webp)$') {
        Throw-LibrarianImageUnavailable 'unsupportedFormat'
    }
    $mime = $Matches[1]
    $value = $source.data
    if ($value -isnot [string] -or !$value) { Throw-LibrarianImageUnavailable 'invalidRaster' }
    if ($value.Length -gt 4*[math]::Ceiling($imageByteLimit/3)+64) { Throw-LibrarianImageUnavailable 'sizeLimit' }
    try { $bytes = [Convert]::FromBase64String($value) }
    catch [FormatException] { Throw-LibrarianImageUnavailable 'invalidRaster' }
    if ($bytes.Length -gt $imageByteLimit) { Throw-LibrarianImageUnavailable 'sizeLimit' }
    return @{bytes=$bytes;format=$mime}
}

function Get-LibrarianRasterFormat([byte[]] $Bytes) {
    if ($Bytes.Length -lt 14) { Throw-LibrarianImageUnavailable 'invalidRaster' }
    $prefix = [Convert]::ToHexString($Bytes,0,8)
    if ($prefix -ceq '89504E470D0A1A0A') {
        # WIC displays only the first frame of an APNG. Check actual PNG chunk boundaries.
        $offset = 8
        while ($offset + 12 -le $Bytes.Length) {
            $length = ([long]$Bytes[$offset] -shl 24) + ([int]$Bytes[$offset+1] -shl 16) +
                ([int]$Bytes[$offset+2] -shl 8) + $Bytes[$offset+3]
            $chunk = [Text.Encoding]::ASCII.GetString($Bytes,$offset+4,4)
            $offset += 12 + $length
            if ($offset -gt $Bytes.Length) { break }
            if ($chunk -ceq 'acTL') { Throw-LibrarianImageUnavailable 'multiFrameImage' }
            if ($chunk -ceq 'IEND') {
                if ($length -eq 0 -and $offset -eq $Bytes.Length) { return 'png' }
                break
            }
        }
    } elseif ($prefix.StartsWith('FFD8FF') -and $Bytes[-2] -eq 255 -and $Bytes[-1] -eq 217) { return 'jpeg' }
    elseif ($prefix.Substring(0,12) -in '474946383761','474946383961' -and $Bytes[-1] -eq 59) { return 'gif' }
    elseif ($prefix.StartsWith('52494646') -and [Text.Encoding]::ASCII.GetString($Bytes,8,4) -ceq 'WEBP' -and
        [BitConverter]::ToUInt32($Bytes,4) -eq ($Bytes.Length-8)) {
        if ($Bytes.Length -ge 21 -and [Text.Encoding]::ASCII.GetString($Bytes,12,4) -ceq 'VP8X' -and ($Bytes[20] -band 2)) {
            Throw-LibrarianImageUnavailable 'multiFrameImage'
        }
        return 'webp'
    }
    Throw-LibrarianImageUnavailable 'invalidRaster'
}

function ConvertTo-LibrarianRaster($Source) {
    $format = Get-LibrarianRasterFormat $Source.bytes
    if ($Source.format -and $Source.format -cne $format) { Throw-LibrarianImageUnavailable 'invalidRaster' }
    Add-Type -AssemblyName PresentationCore
    $inputBytes = [IO.MemoryStream]::new($Source.bytes,$false)
    $output = [IO.MemoryStream]::new()
    try {
        try { $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create($inputBytes,'IgnoreColorProfile','OnDemand') }
        catch [NotSupportedException] { Throw-LibrarianImageUnavailable 'unsupportedCodec' }
        if ($decoder.Frames.Count -ne 1) { Throw-LibrarianImageUnavailable 'multiFrameImage' }
        $frame = $decoder.Frames[0]
        $width = $frame.PixelWidth
        $height = $frame.PixelHeight
        if ($width -le 0 -or $height -le 0 -or [long]$width*$height -gt $imagePixelLimit) { Throw-LibrarianImageUnavailable 'sizeLimit' }
        # Bake EXIF display orientation into the pixels before dropping camera metadata.
        if ($format -eq 'jpeg' -and $frame.Metadata) {
            $orientation = $frame.Metadata.GetQuery('/app1/ifd/{ushort=274}')
            $matrix = switch ($orientation) {
                2 { [Windows.Media.Matrix]::new(-1,0,0,1,0,0) }
                3 { [Windows.Media.Matrix]::new(-1,0,0,-1,0,0) }
                4 { [Windows.Media.Matrix]::new(1,0,0,-1,0,0) }
                5 { [Windows.Media.Matrix]::new(0,1,1,0,0,0) }
                6 { [Windows.Media.Matrix]::new(0,1,-1,0,0,0) }
                7 { [Windows.Media.Matrix]::new(0,-1,-1,0,0,0) }
                8 { [Windows.Media.Matrix]::new(0,-1,1,0,0,0) }
            }
            if ($null -ne $matrix) {
                $frame = [Windows.Media.Imaging.TransformedBitmap]::new($frame,[Windows.Media.MatrixTransform]::new($matrix))
                $width = $frame.PixelWidth
                $height = $frame.PixelHeight
            }
        }
        # Materialize the pixels and start a new image. Source metadata, comments and padding
        # must never make it into Git, even if the source is a technically valid polyglot.
        $bgra = [Windows.Media.PixelFormats]::Bgra32
        $converted = [Windows.Media.Imaging.FormatConvertedBitmap]::new($frame,$bgra,$null,0)
        $stride = $width*4
        $pixels = [byte[]]::new($stride*$height)
        $converted.CopyPixels($pixels,$stride,0)
        $clean = [Windows.Media.Imaging.BitmapSource]::Create($width,$height,96,96,$bgra,$null,$pixels,$stride)
        $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($clean))
        $encoder.Save($output)
        if ($output.Length -gt $imageByteLimit) { Throw-LibrarianImageUnavailable 'sizeLimit' }
        return ,$output.ToArray()
    } finally { $output.Dispose(); $inputBytes.Dispose() }
}

function Resolve-LibrarianChatImage($Block) {
    try {
        $source = Read-LibrarianClaudeImage $Block
        return @{bytes = (ConvertTo-LibrarianRaster $source)}
    } catch {
        $reason = $_.Exception.Data['imageReason']
        if (!$reason) { $reason = 'unreadableImage' }
        return @{reason=$reason}
    }
}

function Add-LibrarianImageReference([hashtable] $Block, [string] $MessageId, [int] $Ordinal, $State) {
    $picture = Resolve-LibrarianChatImage $Block
    if ($picture.reason) {
        $State.reasons[$picture.reason]++
        $null = $State.body.Append("[Image attachment unavailable: $($picture.reason)]`n`n")
        return
    }
    $hash = Get-LibrarianImageHash $picture.bytes
    $name = "$hash.png"
    if (!$State.assets.Contains($name)) {
        $folder = [IO.Path]::Combine($State.imageRoot,$State.id)
        if (!$State.assets.Count) {
            New-LibrarianPrivateDirectory $State.imageRoot
            New-LibrarianPrivateDirectory $folder
        }
        $destination = [IO.Path]::Combine($folder,$name)
        $stream = [IO.File]::Open($destination,'CreateNew','Write','None')
        $null = $State.assets.Add($name)
        try { $stream.Write($picture.bytes,0,$picture.bytes.Length) } finally { $stream.Dispose() }
    }
    $State.available++
    $null = $State.body.Append("![Image attachment](images/$($State.id)/$name)`n`n")
}

function Remove-LibrarianSessionImages($State) {
    $folder = [IO.Path]::Combine($State.imageRoot,$State.id)
    foreach ($name in $State.assets) { [IO.File]::Delete([IO.Path]::Combine($folder,$name)) }
    if ([IO.Directory]::Exists($folder)) { [IO.Directory]::Delete($folder) }
}
