[CmdletBinding()]
param(
    [string]$Task,
    [string[]]$Files,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function ConvertTo-TaskSplitterPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = $Path.Trim()
    $candidate = $candidate.Trim("'`"[](){}.,;:")
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    $candidate = $candidate -replace '\\', '/'
    if ($candidate.StartsWith('./')) {
        $candidate = $candidate.Substring(2)
    }

    while ($candidate.StartsWith('/')) {
        $candidate = $candidate.Substring(1)
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    return $candidate
}

function Get-TaskFileTargets {
    param([Parameter(Mandatory = $true)][string]$TaskDescription)

    $matches = [regex]::Matches($TaskDescription, '(?<![\w.-])(?:[A-Za-z0-9_.-]+[\\/])+[A-Za-z0-9_.-]+')
    $files = [System.Collections.Generic.List[string]]::new()
    $seen = @{}

    foreach ($match in $matches) {
        $normalized = ConvertTo-TaskSplitterPath -Path $match.Value
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }

        $key = $normalized.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $files.Add($normalized)
    }

    return @($files)
}

function Get-TaskSplitGroupKey {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $normalized = ConvertTo-TaskSplitterPath -Path $FilePath
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return 'general'
    }

    $segments = @($normalized -split '/')
    if ($segments.Count -ge 3) {
        return ($segments[0..1] -join '/')
    }

    if ($segments.Count -ge 1) {
        return $segments[0]
    }

    return 'general'
}

function New-BuilderSubTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskDescription,
        [Parameter(Mandatory = $true)][string[]]$Files,
        [string]$GroupKey = 'general'
    )

    $normalizedFiles = @($Files | ForEach-Object { ConvertTo-TaskSplitterPath -Path ([string]$_) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $fileBlock = if ($normalizedFiles.Count -gt 0) {
        ($normalizedFiles | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    } else {
        '- No explicit files identified'
    }

    $prompt = @"
Implement the scoped portion of this task.

Overall task:
$TaskDescription

Focus area:
$GroupKey

Files in scope:
$fileBlock

Keep changes focused to these files unless a small adjacent edit is required to keep the work correct.
Before finishing, summarize changed files and the verification you ran.
"@

    return [PSCustomObject]@{
        GroupKey = $GroupKey
        Files    = @($normalizedFiles)
        Prompt   = $prompt.Trim()
    }
}

function Split-TaskForBuilders {
    param(
        [Parameter(Mandatory = $true)][string]$TaskDescription,
        [string[]]$FileList
    )

    $normalizedFiles = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($file in @($FileList)) {
        $normalized = ConvertTo-TaskSplitterPath -Path ([string]$file)
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }

        $key = $normalized.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $normalizedFiles.Add($normalized)
    }

    if ($normalizedFiles.Count -eq 0) {
        $fallbackFiles = @(Get-TaskFileTargets -TaskDescription $TaskDescription)
        foreach ($file in $fallbackFiles) {
            $key = $file.ToLowerInvariant()
            if ($seen.ContainsKey($key)) {
                continue
            }

            $seen[$key] = $true
            $normalizedFiles.Add($file)
        }
    }

    if ($normalizedFiles.Count -eq 0) {
        return @(
            New-BuilderSubTask -TaskDescription $TaskDescription -Files @() -GroupKey 'general'
        )
    }

    $groups = [ordered]@{}
    foreach ($file in $normalizedFiles) {
        $groupKey = Get-TaskSplitGroupKey -FilePath $file
        if (-not $groups.Contains($groupKey)) {
            $groups[$groupKey] = [System.Collections.Generic.List[string]]::new()
        }

        $groups[$groupKey].Add($file) | Out-Null
    }

    $subTasks = foreach ($groupKey in $groups.Keys) {
        New-BuilderSubTask -TaskDescription $TaskDescription -Files @($groups[$groupKey]) -GroupKey $groupKey
    }

    return @($subTasks)
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($Task)) {
        throw 'task-splitter.ps1 requires -Task when run directly.'
    }

    $result = Split-TaskForBuilders -TaskDescription $Task -FileList $Files
    if ($AsJson) {
        $result | ConvertTo-Json -Depth 8
    } else {
        $result
    }
}
