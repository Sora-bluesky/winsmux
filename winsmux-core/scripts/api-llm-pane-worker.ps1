[CmdletBinding()]
param(
    [string]$Provider = '',
    [string]$Model = '',
    [string]$ProjectDir = '',
    [string]$ReasoningEffort = 'provider-default'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$slotId = [string]$env:WINSMUX_SLOT_ID
if ([string]::IsNullOrWhiteSpace($slotId)) {
    $slotId = 'worker'
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

    if ($Tokens.Count -lt 1) {
        Write-Host 'usage: exec <task-packet-path> [task-id] [run-id]'
        return
    }

    $scriptPath = $Tokens[0]
    $taskId = if ($Tokens.Count -ge 2) { $Tokens[1] } else { '' }
    $runId = if ($Tokens.Count -ge 3) { $Tokens[2] } else { '' }
    $args = @('workers', 'exec', $slotId, '--script', $scriptPath, '--json', '--project-dir', $projectRoot)
    if (-not [string]::IsNullOrWhiteSpace($taskId)) {
        $args += @('--task-id', $taskId)
    }
    if (-not [string]::IsNullOrWhiteSpace($runId)) {
        $args += @('--run-id', $runId)
    }

    & $coreScript @args
}

Write-Host 'winsmux api_llm pane worker'
Write-Host ("slot: {0}" -f $slotId)
Write-Host ("provider: {0}" -f $(if ([string]::IsNullOrWhiteSpace($Provider)) { 'unknown' } else { $Provider }))
Write-Host ("model: {0}" -f $(if ([string]::IsNullOrWhiteSpace($Model)) { 'provider-default' } else { $Model }))
Write-Host ("project: {0}" -f $projectRoot)
Write-Host 'status: ready'
Write-Host 'commands: exec <task-packet-path> [task-id] [run-id], status, help, quit'

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
        Write-Host 'exec <task-packet-path> [task-id] [run-id]'
        Write-Host 'Example: exec tasks/cli-bakeoff/v1/WB-010-openrouter-api-worker-readiness.md WB-010 v03617-w5-wb010'
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

    Write-Host 'unknown command. Type help.'
}

Write-Host 'status: stopped'
