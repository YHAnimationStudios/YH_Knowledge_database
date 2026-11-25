# Pictures enter here only from typed user attachments and completed generation items.
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

function Read-LibrarianInlineImage([string] $Value, [switch] $Generated) {
    $mime = $null
    if ($Value.Length -gt 4*[math]::Ceiling($imageByteLimit/3)+64) { Throw-LibrarianImageUnavailable 'sizeLimit' }
    if ($Value.StartsWith('data:',[StringComparison]::OrdinalIgnoreCase)) {
        $comma = $Value.IndexOf(',')
        if ($comma -le 0 -or $comma -gt 40 -or $Value.Substring(0,$comma) -notmatch '^data:image/(png|jpeg|gif|webp);base64$') {
            Throw-LibrarianImageUnavailable 'unsupportedFormat'
        }
        $mime = $Matches[1].ToLowerInvariant()
        $Value = $Value.Substring($comma+1)
    } elseif (!$Generated) { Throw-LibrarianImageUnavailable 'remoteReference' }
    try { $bytes = [Convert]::FromBase64String($Value) }
    catch [FormatException] { Throw-LibrarianImageUnavailable 'invalidRaster' }
    if ($bytes.Length -gt $imageByteLimit) { Throw-LibrarianImageUnavailable 'sizeLimit' }
    return @{bytes=$bytes;format=$mime}
}

function Read-LibrarianLocalImage($Path, $EventTime) {
    if ($Path -isnot [string] -or $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2) -match '[:*?"<>|\x00-\x1f]' -or
        $Path -match '(?:^|[\\/])(?:[.]{1,2}|(?:aux|con|prn|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.[^\\/]*)?)(?:[\\/]|$)|[. ](?:[\\/]|$)') {
        Throw-LibrarianImageUnavailable 'unsafeLocalPath'
    }
    $info = [IO.FileInfo]::new($Path)
    if ($info.Extension -notin '.png','.jpg','.jpeg','.gif','.webp' -or [IO.DriveInfo]::new($info.Directory.Root.FullName).DriveType -ne 'Fixed') {
        Throw-LibrarianImageUnavailable 'unsafeLocalPath'
    }
    # Check from the drive downward. Looking up the leaf first would already traverse a
    # parent junction or network redirect, even if the redirected file were later rejected.
    $components = [Collections.Generic.Stack[IO.FileSystemInfo]]::new()
    $components.Push($info)
    for ($parent=$info.Directory; $parent; $parent=$parent.Parent) { $components.Push($parent) }
    foreach ($component in $components) {
        $attrs = $component.Attributes
        if ([int]$attrs -ne -1 -and ($attrs -band [IO.FileAttributes]::ReparsePoint)) { Throw-LibrarianImageUnavailable 'unsafeLocalPath' }
    }
    if (!$info.Exists) { Throw-LibrarianImageUnavailable 'absentLocalFile' }
    if (!$EventTime) { Throw-LibrarianImageUnavailable 'unverifiedLocalTime' }
    if (!('AnimTeamLibrarian.ImageHandle' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Text;
namespace AnimTeamLibrarian {
    public static class ImageHandle {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint length, uint flags);
    }
}
'@
    }
    $stream = [IO.File]::Open($info.FullName,'Open','Read','Read')
    try {
        # Re-check the opened handle to guard against a junction swap between validation and open.
        $final = [Text.StringBuilder]::new(32768)
        $length = [AnimTeamLibrarian.ImageHandle]::GetFinalPathNameByHandle($stream.SafeFileHandle,$final,$final.Capacity,0)
        if (!$length -or $length -ge $final.Capacity -or
            !($final.ToString()).Equals(('\\?\' + $info.FullName),[StringComparison]::OrdinalIgnoreCase)) {
            Throw-LibrarianImageUnavailable 'unsafeLocalPath'
        }
        $info.Refresh()
        $latest = $EventTime.UtcDateTime.AddSeconds(2)
        if ($info.LastWriteTimeUtc -gt $latest -or $info.CreationTimeUtc -gt $latest) { Throw-LibrarianImageUnavailable 'changedLocalFile' }
        if ($stream.Length -gt $imageByteLimit) { Throw-LibrarianImageUnavailable 'sizeLimit' }
        $buffer = [IO.MemoryStream]::new()
        try { $stream.CopyTo($buffer); $bytes=$buffer.ToArray() } finally { $buffer.Dispose() }
    } finally { $stream.Dispose() }
    $format = $info.Extension.Substring(1).ToLowerInvariant()
    if ($format -eq 'jpg') { $format = 'jpeg' }
    return @{bytes=$bytes;format=$format}
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

function Resolve-LibrarianChatImage($Part, $EventTime) {
    $reason = 'missingOriginal'
    if ($Part.fileId) { $reason = 'opaqueFileId' }
    $generated = $Part.type -ceq 'imageGeneration'
    $inline = if ($generated) { $Part.result } elseif ($Part.type -ceq 'image') { $Part.url }
    $path = if ($generated) { $Part.savedPath } elseif ($Part.type -ceq 'localImage') { $Part.path }
    foreach ($kind in 'inline','path') {
        try {
            if ($kind -eq 'inline') {
                if ($inline -isnot [string] -or !$inline) { continue }
                $source = Read-LibrarianInlineImage $inline -Generated:$generated
            } else {
                if (!$path) { continue }
                $source = Read-LibrarianLocalImage $path $EventTime
            }
            $bytes = ConvertTo-LibrarianRaster $source
            return @{bytes=$bytes}
        } catch {
            $reason = $_.Exception.Data['imageReason']
            if (!$reason) {
                $reason = 'unreadableImage'
            }
        }
    }
    return @{reason=$reason}
}

function Add-LibrarianImageReference($Part, [string] $TurnId, [string] $ItemId, [int] $Ordinal, $EventTime, $State) {
    $label = if ($Part.type -ceq 'imageGeneration') { 'Generated image' } else { 'Attached image' }
    # Length-prefixed identifiers avoid ambiguity without copying local identifiers into Markdown.
    $identity = "$($TurnId.Length):$TurnId$($ItemId.Length):$ItemId/$label/$Ordinal"
    $marker = Get-LibrarianImageHash ($utf8.GetBytes($identity))
    $picture = Resolve-LibrarianChatImage $Part $EventTime
    $null = $State.body.Append("<!-- anim-team-image $marker -->`n")
    if ($picture.reason) {
        $State.reasons[$picture.reason]++
        $null = $State.body.Append("*$label unavailable.*`n`n")
        return
    }
    $hash = Get-LibrarianImageHash $picture.bytes
    $name = "$hash.png"
    if (!$State.assets.Contains($name)) {
        $folder = [IO.Path]::Combine($imageRoot,$State.id)
        if (!$State.assets.Count) {
            New-LibrarianPrivateDirectory $imageRoot
            New-LibrarianPrivateDirectory $folder
        }
        $destination = [IO.Path]::Combine($folder,$name)
        $stream = [IO.File]::Open($destination,'CreateNew','Write','None')
        $null = $State.assets.Add($name)
        try { $stream.Write($picture.bytes,0,$picture.bytes.Length) } finally { $stream.Dispose() }
    }
    $State.available++
    $null = $State.body.Append("![$label](images/$($State.id)/$name)`n`n")
}

function Remove-LibrarianSessionImages($State) {
    $folder = [IO.Path]::Combine($imageRoot,$State.id)
    foreach ($name in $State.assets) { [IO.File]::Delete([IO.Path]::Combine($folder,$name)) }
    if ([IO.Directory]::Exists($folder)) { [IO.Directory]::Delete($folder) }
}
