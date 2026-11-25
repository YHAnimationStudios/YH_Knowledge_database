# Only called for text that will appear in a shared session document.
# Keep the patterns precompiled across messages in a long backfill.
$privateKeyPattern = '(?s)-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----.*?(?:-----END \1-----|\z)'
$transcriptPatterns = @(
    @($privateKeyPattern, '[REDACTED]'),
    @('(?i)(\b(?:proxy-)?authorization\s*:\s*(?:bearer|basic)\s+)[^\s"'']+', '${1}[REDACTED]'),
    @('(?im)^(\s*(?:set-cookie|cookie)\s*:\s*)[^\r\n]+', '${1}[REDACTED]'),
    @('(?i)(\b[a-z][a-z0-9+.-]*://)[^\s/@]+:[^\s/@]+@', '${1}[REDACTED]@'),
    @('\b(?:github_pat_[a-zA-Z0-9_]{20,}|gh[pousr]_[a-zA-Z0-9]{20,}|sk-(?:[\w]+-)*[a-zA-Z0-9_-]{20,}|xox[bpars]-[a-zA-Z0-9-]{10,}|AIza[\w-]{30,}|eyJ[\w-]+\.eyJ[\w-]+\.[\w-]+)', '[REDACTED]'),
    @('(?i)(["'']?\b(?:[\w-]+[_-])?(?:password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|client[_-]?secret|secret[_-]?key|private[_-]?token|personal[_-]?access[_-]?token|secret[_-]?access[_-]?key)\b["'']?\s*[:=]\s*)(?:"[^"\r\n]*"|''[^''\r\n]*''|[^\s,;&}]+)', '${1}[REDACTED]')
) | ForEach-Object {
    [pscustomobject]@{
        Regex = [regex]::new($_[0], [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(4))
        Replacement = $_[1]
    }
}

function Protect-LibrarianTranscriptText([string] $Text, [hashtable] $AcrossImages) {
    foreach ($pattern in $transcriptPatterns) {
        if ($null -ne $AcrossImages -and $pattern.Regex.ToString() -ceq $privateKeyPattern) {
            if ($AcrossImages.openKey) { $Text = $AcrossImages.openKey + "`n" + $Text }
            $AcrossImages.openKey = $null
            # A pasted key can span text parts separated by a real image. Carry its
            # redaction up to the closing delimiter without suppressing the picture.
            foreach ($key in $pattern.Regex.Matches($Text)) {
                $kind = $key.Groups[1].Value
                if (!$key.Value.EndsWith("-----END $kind-----",[StringComparison]::Ordinal)) {
                    $AcrossImages.openKey = "-----BEGIN $kind-----"
                }
            }
        }
        $Text = $pattern.Regex.Replace($Text, $pattern.Replacement)
    }
    return $Text
}
