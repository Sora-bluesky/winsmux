[CmdletBinding()]
param(
    [string]$SlotId = '',
    [string]$Provider = '',
    [string]$Model = '',
    [string]$ProjectDir = '',
    [string]$ReasoningEffort = 'provider-default'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$slotId = [string]$SlotId
if ([string]::IsNullOrWhiteSpace($slotId)) {
    $slotId = [string]$env:WINSMUX_SLOT_ID
}
if ([string]::IsNullOrWhiteSpace($slotId)) {
    Write-Host 'winsmux api_llm pane worker'
    Write-Host 'status: failed'
    Write-Host 'reason: missing SlotId. Start this worker through winsmux so the actual worker pane id is provided.'
    exit 2
}

$projectRoot = $ProjectDir
if ([string]::IsNullOrWhiteSpace($projectRoot)) {
    $projectRoot = [string]$env:WINSMUX_ORCHESTRA_PROJECT_DIR
}
if ([string]::IsNullOrWhiteSpace($projectRoot)) {
    $projectRoot = (Get-Location).Path
}

$coreScript = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts/winsmux-core.ps1'
if (-not (Test-Path -LiteralPath $coreScript -PathType Leaf)) {
    $coreScript = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'winsmux-core.ps1'
}

function Write-ApiLlmPanePrompt {
    Write-Host ("api_llm[{0}]> " -f $slotId) -NoNewline
}

function Invoke-ApiLlmPaneExec {
    param([Parameter(Mandatory = $true)][string[]]$Tokens)

    if ($Tokens.Count -ne 1) {
        Write-Host 'usage: exec <task-packet-path>'
        return
    }

    $packetPath = $Tokens[0]
    $args = @('workers', 'exec', $slotId, '--task-json', $packetPath, '--json', '--project-dir', $projectRoot)

    & $coreScript @args
}

function Invoke-ApiLlmPaneReviewRequest {
    param([Parameter(Mandatory = $true)][string[]]$Tokens)

    if ($Tokens.Count -ne 4 -or $Tokens[0] -ne '--state-root' -or $Tokens[2] -ne '--submission-id') {
        Write-Host 'usage: winsmux review-request --state-root <absolute-path> --submission-id <id>'
        return
    }
    if (-not [IO.Path]::IsPathRooted($Tokens[1]) -or $Tokens[1] -match '\s' -or $Tokens[3] -notmatch '^[A-Za-z0-9._-]+$') {
        Write-Host 'usage: winsmux review-request --state-root <absolute-path> --submission-id <id>'
        return
    }
    & $coreScript 'review-request' '--state-root' $Tokens[1] '--submission-id' $Tokens[3]
}

Write-Host 'winsmux api_llm pane worker'
Write-Host ("slot: {0}" -f $slotId)
Write-Host ("provider: {0}" -f $(if ([string]::IsNullOrWhiteSpace($Provider)) { 'unknown' } else { $Provider }))
Write-Host ("model: {0}" -f $(if ([string]::IsNullOrWhiteSpace($Model)) { 'provider-default' } else { $Model }))
Write-Host ("project: {0}" -f $projectRoot)
Write-Host 'status: ready'
Write-Host 'commands: exec <task-packet-path>, winsmux review-request --state-root <absolute-path> --submission-id <id>, status, help, quit'

while ($true) {
    Write-ApiLlmPanePrompt
    $line = [Console]::ReadLine()
    if ($null -eq $line) {
        break
    }

    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        continue
    }

    if ($trimmed -in @('quit', 'exit')) {
        break
    }

    if ($trimmed -eq 'status') {
        Write-Host 'status: ready'
        continue
    }

    if ($trimmed -eq 'help') {
        Write-Host 'exec <task-packet-path>'
        Write-Host 'Example: exec .winsmux/submissions/submission-123.json'
        continue
    }

    if ($trimmed -like 'exec *') {
        $rest = $trimmed.Substring(5).Trim()
        $tokens = @($rest -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        try {
            Invoke-ApiLlmPaneExec -Tokens $tokens
        } catch {
            Write-Host ("status: failed")
            Write-Host ("reason: {0}" -f ($_.Exception.Message -replace '[A-Za-z]:\\Users\\[^,"\r\n]+', '<local-path>'))
        }
        continue
    }

    if ($trimmed -like 'winsmux review-request *') {
        $rest = $trimmed.Substring('winsmux review-request '.Length).Trim()
        $tokens = @($rest -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        try { Invoke-ApiLlmPaneReviewRequest -Tokens $tokens } catch { Write-Host 'status: failed' }
        continue
    }

    Write-Host 'unknown command. Type help.'
}

Write-Host 'status: stopped'
