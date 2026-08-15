<#
.SYNOPSIS
Wrap-tolerant pane echo matching and shell-prompt detection for dispatch.

.DESCRIPTION
Narrow worker panes wrap long startup commands, task text, and the PowerShell
prompt itself. Capture-pane -J does not join ConPTY hard wraps, so last-line
`^PS ` checks and suffix-only echo contains checks become silent misses.
These helpers collapse wrap seams (newlines and line-leading prompt/box
decorations) before matching. Dot-source from the send/wait/startup paths;
do not treat this file as a public command surface.
#>

Set-StrictMode -Version Latest

function ConvertTo-DispatchEchoFingerprint {
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [switch]$StripWrapDecorations
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($rawLine in @($Text -split "\r?\n")) {
        $line = [string]$rawLine
        if ($StripWrapDecorations) {
            $line = $line.Trim()
            $line = $line -replace '^[\u2500-\u259F]+', ''
            $line = $line -replace '^[>›❯]{1,2}\s*', ''
            $line = $line -replace '^PS\s+\S*>\s*', ''
        }
        $parts.Add($line) | Out-Null
    }

    return (($parts -join '') -replace '\s+', '').ToLowerInvariant()
}

function Test-PaneContainsCommandFragment {
    param(
        [AllowEmptyString()][string]$PaneText,
        [AllowEmptyString()][string]$CommandText,
        [ValidateRange(8, 256)][int]$FragmentLength = 64
    )

    if ([string]::IsNullOrWhiteSpace($PaneText) -or [string]::IsNullOrWhiteSpace($CommandText)) {
        return $false
    }

    $normalizedPaneText = ConvertTo-DispatchEchoFingerprint -Text $PaneText -StripWrapDecorations
    $normalizedCommandText = ConvertTo-DispatchEchoFingerprint -Text $CommandText
    if ([string]::IsNullOrWhiteSpace($normalizedPaneText) -or [string]::IsNullOrWhiteSpace($normalizedCommandText)) {
        return $false
    }

    if ($normalizedPaneText.Contains($normalizedCommandText)) {
        return $true
    }

    $effectiveLength = [Math]::Min($FragmentLength, $normalizedCommandText.Length)
    $prefix = $normalizedCommandText.Substring(0, $effectiveLength)
    $suffix = $normalizedCommandText.Substring($normalizedCommandText.Length - $effectiveLength)
    return $normalizedPaneText.Contains($prefix) -or $normalizedPaneText.Contains($suffix)
}

function Test-ShellPromptText {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($rawLine in @($Text -split "\r?\n")) {
        $trimmed = ([string]$rawLine).Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $lines.Add($trimmed) | Out-Null
        }
    }

    if ($lines.Count -eq 0) {
        return $false
    }

    if ($lines[$lines.Count - 1] -match '^PS\s+') {
        return $true
    }

    $tailStart = [Math]::Max(0, $lines.Count - 6)
    $collapsed = ''
    for ($index = $tailStart; $index -lt $lines.Count; $index++) {
        $collapsed += $lines[$index]
    }
    $collapsed = $collapsed -replace '\s+', ''
    if ([string]::IsNullOrWhiteSpace($collapsed)) {
        return $false
    }

    return [bool]($collapsed -match '(?i)PS.{2,}>$')
}
