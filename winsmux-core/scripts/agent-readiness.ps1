$script:AgentReadinessPromptMarkers = @(
    '>',
    ([string][char]8250),
    ([string][char]0x258C),
    ([string][char]0x276F)
)

function Get-LastNonEmptyLine {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $lines = $Text -split "\r?\n"
    for ($index = $lines.Length - 1; $index -ge 0; $index--) {
        $line = $lines[$index]
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            return $line
        }
    }

    return $null
}

function Get-RecentNonEmptyLines {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxCount = 8
    )

    if ([string]::IsNullOrWhiteSpace($Text) -or $MaxCount -lt 1) {
        return @()
    }

    $lines = $Text -split "\r?\n"
    $recent = [System.Collections.Generic.List[string]]::new()

    for ($index = $lines.Length - 1; $index -ge 0 -and $recent.Count -lt $MaxCount; $index--) {
        $line = $lines[$index]
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $recent.Insert(0, $line)
        }
    }

    return @($recent)
}

function ConvertTo-ReadinessAgentName {
    param([AllowNull()][string]$Value)

    $lowered = if ($null -eq $Value) { '' } else { $Value.Trim().ToLowerInvariant() }
    foreach ($name in @('codex', 'claude', 'gemini')) {
        if ($lowered -eq $name `
            -or $lowered.StartsWith("${name}:") `
            -or $lowered.StartsWith("${name}-") `
            -or $lowered.StartsWith("${name}_") `
            -or $lowered.StartsWith("${name}/")) {
            return $name
        }
    }

    return ''
}

function Test-AgentPromptText {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Agent
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $agentName = $Agent.Trim().ToLowerInvariant()
    $recentLines = @(Get-RecentNonEmptyLines -Text $Text -MaxCount 8)
    if ($recentLines.Count -eq 0) {
        return $false
    }

    $tailText = $recentLines -join [Environment]::NewLine
    $blockedPatterns = @(
        '(?im)\bmissing api key\b',
        '(?im)\brun /login\b',
        '(?im)\bunable to connect\b',
        '(?im)\bfailed to connect\b'
    )

    foreach ($pattern in $blockedPatterns) {
        if ($tailText -match $pattern) {
            return $false
        }
    }

    foreach ($line in $recentLines) {
        $trimmed = $line.TrimStart()
        foreach ($marker in $script:AgentReadinessPromptMarkers) {
            if ($trimmed.StartsWith($marker)) {
                return $true
            }
        }
    }

    switch ($agentName) {
        'codex' {
            if ($tailText -match '(?im)\b(?:gpt|codex|gpt-oss|o[0-9])[A-Za-z0-9._/-]*\b.*\b\d+%\s+(?:context\s+)?left\b') {
                return $true
            }

            if ($tailText -match '(?im)\b(?:tokens used|context left)\b' -and $tailText -match '⏎\s*send') {
                return $true
            }
        }
        'claude' {
            if ($tailText -match '(?im)\bWelcome to Claude Code!?') {
                return $true
            }

            if ($tailText -match '(?im)/help for help,\s*/status for your current setup') {
                return $true
            }

            if ($tailText -match '(?im)\?\s+for shortcuts\b') {
                return $true
            }
        }
        'gemini' {
            if ($tailText -match '(?im)\bType your message(?:\s+or\s+@path/to/file)?\b') {
                return $true
            }

            if ($tailText -match '(?im)\bUsing:\s+\d+\s+GEMINI\.md\s+file') {
                return $true
            }

            if ($tailText -match '(?im)\bgemini-[A-Za-z0-9._-]+\b.*\b\d+%\s+context\s+left\b') {
                return $true
            }
        }
    }

    return $false
}
