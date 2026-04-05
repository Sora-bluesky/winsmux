<#
.SYNOPSIS
Evidence ledger for winsmux Orchestra audit trail.

.DESCRIPTION
Appends structured JSONL entries to .winsmux/evidence/YYYY-MM-DD.jsonl.
Each entry records an orchestra-level event (dispatch, review, merge, etc.)
with timestamp, actor, target, and detail.

Dot-source this script to load the helpers:

    . "$PSScriptRoot/evidence-ledger.ps1"
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:EvidenceDirName = '.winsmux\evidence'
$script:ValidEventTypes = @('DISPATCH', 'REVIEW_PASS', 'REVIEW_FAIL', 'MERGE', 'DENY', 'ERROR')

function New-EvidenceLedger {
    <#
    .SYNOPSIS
    Creates the evidence directory and today's JSONL ledger file. Returns the path.
    #>
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $evidenceDir = Join-Path $ProjectDir $script:EvidenceDirName
    if (-not (Test-Path $evidenceDir)) {
        New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
    }

    $dateSuffix = [System.DateTimeOffset]::Now.ToString('yyyy-MM-dd')
    $ledgerPath = Join-Path $evidenceDir ($dateSuffix + '.jsonl')
    if (-not (Test-Path $ledgerPath)) {
        Set-Content -Path $ledgerPath -Value '' -Encoding UTF8 -NoNewline
    }

    return $ledgerPath
}

function Write-EvidenceEntry {
    <#
    .SYNOPSIS
    Appends a single evidence entry as a JSON line to the ledger file.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][ValidateSet('DISPATCH', 'REVIEW_PASS', 'REVIEW_FAIL', 'MERGE', 'DENY', 'ERROR')]
        [string]$EventType,
        [Parameter(Mandatory = $true)][string]$Actor,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$Detail = ''
    )

    $entry = [ordered]@{
        timestamp  = [System.DateTimeOffset]::Now.ToString('o')
        event_type = $EventType
        actor      = $Actor
        target     = $Target
        detail     = if ($null -eq $Detail) { '' } else { $Detail }
    }

    $line = ($entry | ConvertTo-Json -Compress -Depth 10)
    Add-Content -Path $LedgerPath -Value $line -Encoding UTF8

    return [PSCustomObject]$entry
}

function Get-EvidenceSummary {
    <#
    .SYNOPSIS
    Reads the ledger and returns a hashtable of event_type counts.
    #>
    param([Parameter(Mandatory = $true)][string]$LedgerPath)

    $summary = @{}

    if (-not (Test-Path $LedgerPath -PathType Leaf)) {
        return $summary
    }

    foreach ($line in (Get-Content -Path $LedgerPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parsed = $line | ConvertFrom-Json -ErrorAction Stop
        $eventType = $parsed.event_type
        if ($summary.ContainsKey($eventType)) {
            $summary[$eventType]++
        } else {
            $summary[$eventType] = 1
        }
    }

    return $summary
}
