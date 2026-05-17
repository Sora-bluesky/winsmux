[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('collect', 'summarize', 'assess', 'prune', 'plan', 'apply')]
    [string]$Command,

    [string]$ProjectDir = '',

    [string]$RecordId = '',

    [ValidateSet('official-docs', 'release-notes', 'cli-help', 'policy-checklist', 'public-issue-pr')]
    [string]$SourceType = 'official-docs',

    [string[]]$Source = @(),

    [string[]]$AcceptedPattern = @(),

    [string[]]$RejectedPattern = @(),

    [string]$LandingZone = '',

    [string[]]$Task = @(),

    [string[]]$Issue = @(),

    [string]$Notes = '',

    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-UpstreamProjectDir {
    param([string]$RequestedProjectDir)

    if (-not [string]::IsNullOrWhiteSpace($RequestedProjectDir)) {
        return (Resolve-Path -LiteralPath $RequestedProjectDir).Path
    }

    $gitRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitRoot)) {
        return (Resolve-Path -LiteralPath $gitRoot).Path
    }

    return (Resolve-Path -LiteralPath (Get-Location)).Path
}

function ConvertTo-UpstreamStringList {
    param([AllowNull()][string[]]$Values)

    $result = @()
    foreach ($value in @($Values)) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $result += $value.Trim()
        }
    }

    return @($result)
}

function New-UpstreamRecordId {
    param([string]$CommandName)

    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    return "$stamp-$CommandName-$suffix"
}

function Assert-UpstreamRecordId {
    param([string]$Value)

    if ($Value -notmatch '^[A-Za-z0-9._-]+$') {
        throw "RecordId may only contain letters, numbers, dot, underscore, and dash: $Value"
    }
}

function Assert-UpstreamLandingZone {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'LandingZone is required for apply.'
    }

    $allowed = @(
        'public-docs',
        'contributor-docs',
        'external-planning',
        'private-maintainer-assets'
    )

    if ($Value -notin $allowed) {
        throw "Unsupported LandingZone '$Value'. Allowed values: $($allowed -join ', ')"
    }
}

function Assert-UpstreamCommandInput {
    param(
        [string]$CommandName,
        [string[]]$Sources,
        [string[]]$AcceptedPatterns,
        [string[]]$RejectedPatterns,
        [string]$RequestedLandingZone,
        [string[]]$Tasks,
        [string[]]$Issues,
        [string]$RequestedNotes
    )

    switch ($CommandName) {
        'collect' {
            if ($Sources.Count -eq 0) {
                throw 'collect requires at least one Source.'
            }
        }
        'summarize' {
            if ($Sources.Count -eq 0 -and [string]::IsNullOrWhiteSpace($RequestedNotes)) {
                throw 'summarize requires Source or Notes.'
            }
        }
        'assess' {
            if (($AcceptedPatterns.Count + $RejectedPatterns.Count) -eq 0) {
                throw 'assess requires AcceptedPattern or RejectedPattern.'
            }
        }
        'prune' {
            if ($RejectedPatterns.Count -eq 0) {
                throw 'prune requires at least one RejectedPattern.'
            }
        }
        'plan' {
            if (($Tasks.Count + $Issues.Count) -eq 0) {
                throw 'plan requires Task or Issue.'
            }
        }
        'apply' {
            Assert-UpstreamLandingZone -Value $RequestedLandingZone
            if ($AcceptedPatterns.Count -eq 0) {
                throw 'apply requires at least one AcceptedPattern.'
            }
            if ($Tasks.Count -eq 0) {
                throw 'apply requires at least one Task.'
            }
            if ($Issues.Count -eq 0) {
                throw 'apply requires at least one Issue.'
            }
        }
    }
}

function Write-UpstreamJsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $jsonText = $Value | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $Path -Value $jsonText -Encoding utf8
}

$resolvedProjectDir = Resolve-UpstreamProjectDir -RequestedProjectDir $ProjectDir
$recordIdValue = if ([string]::IsNullOrWhiteSpace($RecordId)) {
    New-UpstreamRecordId -CommandName $Command
}
else {
    $RecordId.Trim()
}

Assert-UpstreamRecordId -Value $recordIdValue

$sources = @(ConvertTo-UpstreamStringList -Values $Source)
$acceptedPatterns = @(ConvertTo-UpstreamStringList -Values $AcceptedPattern)
$rejectedPatterns = @(ConvertTo-UpstreamStringList -Values $RejectedPattern)
$tasks = @(ConvertTo-UpstreamStringList -Values $Task)
$issues = @(ConvertTo-UpstreamStringList -Values $Issue)

Assert-UpstreamCommandInput `
    -CommandName $Command `
    -Sources $sources `
    -AcceptedPatterns $acceptedPatterns `
    -RejectedPatterns $rejectedPatterns `
    -RequestedLandingZone $LandingZone `
    -Tasks $tasks `
    -Issues $issues `
    -RequestedNotes $Notes

$cacheRoot = Join-Path (Join-Path $resolvedProjectDir '.winsmux') 'evolution'
$sourceSetRoot = Join-Path $cacheRoot 'source-sets'
$ledgerPath = Join-Path $cacheRoot 'reevaluation-records.jsonl'
New-Item -ItemType Directory -Force -Path $sourceSetRoot | Out-Null

$sourceSetPath = $null
if ($Command -eq 'collect') {
    $sourceSetPath = Join-Path $sourceSetRoot "$recordIdValue.json"
    $sourceSet = [ordered]@{
        schema_version = 1
        record_id      = $recordIdValue
        source_type    = $SourceType
        sources        = @($sources)
        collected_at   = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-UpstreamJsonFile -Path $sourceSetPath -Value $sourceSet
}

$record = [ordered]@{
    schema_version        = 1
    record_id             = $recordIdValue
    command               = $Command
    generated_at          = [DateTimeOffset]::UtcNow.ToString('o')
    source_type           = $SourceType
    sources               = @($sources)
    accepted_patterns     = @($acceptedPatterns)
    rejected_patterns     = @($rejectedPatterns)
    landing_zone          = if ([string]::IsNullOrWhiteSpace($LandingZone)) { $null } else { $LandingZone }
    tasks                 = @($tasks)
    issues                = @($issues)
    notes                 = $Notes
    cache_root            = $cacheRoot
    ledger_path           = $ledgerPath
    source_set_path       = $sourceSetPath
    human_merge_required  = $true
}

($record | ConvertTo-Json -Depth 12 -Compress) | Add-Content -LiteralPath $ledgerPath -Encoding utf8

if ($Json) {
    $record | ConvertTo-Json -Depth 12
}
else {
    Write-Output "recorded $Command reevaluation record $recordIdValue"
}
