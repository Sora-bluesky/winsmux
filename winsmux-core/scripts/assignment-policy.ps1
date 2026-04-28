[CmdletBinding()]
param(
    [string]$TaskId = '',
    [string]$Text = '',
    [string]$BacklogPath = '',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AssignmentBacklogPath {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $planningPaths = Join-Path $PSScriptRoot 'planning-paths.ps1'
    if (Test-Path -LiteralPath $planningPaths -PathType Leaf) {
        . $planningPaths
        return Resolve-WinsmuxPlanningFilePath -RepoRoot $repoRoot -LocalRelativePath 'tasks/backlog.yaml' -EnvironmentVariable 'WINSMUX_BACKLOG_PATH' -DefaultFileName 'backlog.yaml'
    }

    return Join-Path $repoRoot 'tasks\backlog.yaml'
}

function Get-BacklogTaskBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Id
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    $start = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match "^\s*-\s+id:\s+$([regex]::Escape($Id))\s*$") {
            $start = $index
            break
        }
    }

    if ($start -lt 0) {
        return $null
    }

    $end = $lines.Count
    for ($index = $start + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*-\s+id:\s+TASK-') {
            $end = $index
            break
        }
    }

    return ($lines[$start..($end - 1)] -join "`n")
}

function Get-BacklogScalar {
    param(
        [Parameter(Mandatory = $true)][string]$Block,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $match = [regex]::Match($Block, "(?m)^\s*$([regex]::Escape($Name)):\s*(?<value>.+?)\s*$")
    if (-not $match.Success) {
        return ''
    }

    return $match.Groups['value'].Value.Trim().Trim('"')
}

function Get-AssignmentInputText {
    param(
        [string]$TaskBlock,
        [string]$FreeText
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($TaskBlock)) {
        $parts.Add($TaskBlock) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($FreeText)) {
        $parts.Add($FreeText) | Out-Null
    }
    return ($parts -join "`n")
}

function Test-AssignmentKeyword {
    param(
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][string[]]$Keywords
    )

    foreach ($keyword in $Keywords) {
        if ($InputText -match [regex]::Escape($keyword)) {
            return $true
        }
    }
    return $false
}

function Get-AssignmentCapabilityTier {
    param([Parameter(Mandatory = $true)][string]$InputText)

    if (Test-AssignmentKeyword -InputText $InputText -Keywords @('review', 'audit', 'security', 'release-blocker', '監査', 'レビュー')) {
        return 'deep_review'
    }

    if (Test-AssignmentKeyword -InputText $InputText -Keywords @('implement', 'fix', 'bug', 'feature', 'code', 'Rust', 'Tauri', '実装', '修正')) {
        return 'frontier_coding'
    }

    if (Test-AssignmentKeyword -InputText $InputText -Keywords @('research', 'investigate', 'planning', 'docs', '調査', '計画')) {
        return 'fast_coding'
    }

    return 'cheap_summary'
}

function New-ProviderCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$CapabilityTier,
        [Parameter(Mandatory = $true)][string]$ModelResolution,
        [Parameter(Mandatory = $true)][string]$PromptTransport,
        [Parameter(Mandatory = $true)][string]$AuthMode,
        [Parameter(Mandatory = $true)][string]$Rationale
    )

    $effort = switch ($CapabilityTier) {
        'deep_review' { 'high' }
        'frontier_coding' { 'high' }
        'fast_coding' { 'medium' }
        default { 'low' }
    }

    [ordered]@{
        provider                           = $Provider
        role                               = $Role
        personality                        = $Role
        capability_tier                    = $CapabilityTier
        model                              = $ModelResolution
        model_resolution                   = $ModelResolution
        model_reasoning_effort             = $effort
        model_reasoning_summary            = 'none'
        prompt_transport                   = $PromptTransport
        auth_mode                          = $AuthMode
        credential_store                   = 'official_cli_store'
        suppress_unstable_features_warning = $true
        approvals_reviewer                 = 'operator'
        rationale                          = $Rationale
    }
}

function Get-AssignmentPolicy {
    param(
        [string]$TaskId,
        [string]$Text,
        [string]$BacklogPath
    )

    $resolvedBacklog = Resolve-AssignmentBacklogPath -Path $BacklogPath
    $taskBlock = ''
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $taskBlock = Get-BacklogTaskBlock -Path $resolvedBacklog -Id $TaskId
        if ($null -eq $taskBlock) {
            throw "task not found in backlog: $TaskId"
        }
    }

    $inputText = Get-AssignmentInputText -TaskBlock $taskBlock -FreeText $Text
    if ([string]::IsNullOrWhiteSpace($inputText)) {
        throw 'usage: winsmux assign --task <TASK-ID> [--json] [--text <text>]'
    }

    $title = if (-not [string]::IsNullOrWhiteSpace($taskBlock)) {
        Get-BacklogScalar -Block $taskBlock -Name 'title'
    } else {
        ''
    }
    $priority = if (-not [string]::IsNullOrWhiteSpace($taskBlock)) {
        Get-BacklogScalar -Block $taskBlock -Name 'priority'
    } else {
        ''
    }

    $tier = Get-AssignmentCapabilityTier -InputText $inputText
    $worktreeRequired = Test-AssignmentKeyword -InputText $inputText -Keywords @('code', 'implement', 'fix', 'Rust', 'Tauri', 'PowerShell', '実装', '修正', '変更')
    $secretSensitive = Test-AssignmentKeyword -InputText $inputText -Keywords @('token', 'credential', 'OAuth', 'secret', 'auth', '資格情報', '機密')

    $primary = switch ($tier) {
        'deep_review' {
            New-ProviderCandidate -Provider 'claude' -Role 'reviewer' -CapabilityTier $tier -ModelResolution 'alias:opus' -PromptTransport 'file' -AuthMode 'claude-official-cli' -Rationale 'Use Claude Code review strength while keeping Claude Code as the upper operator.'
        }
        'frontier_coding' {
            New-ProviderCandidate -Provider 'codex' -Role 'builder' -CapabilityTier $tier -ModelResolution 'provider_recommended_default' -PromptTransport 'file' -AuthMode 'codex-official-cli' -Rationale 'Use Codex for implementation and verification without pinning a stale model id.'
        }
        'fast_coding' {
            New-ProviderCandidate -Provider 'gemini' -Role 'researcher' -CapabilityTier $tier -ModelResolution 'alias:auto' -PromptTransport 'file' -AuthMode 'gemini-official-cli' -Rationale 'Use Gemini for fast investigation and context shaping before implementation.'
        }
        default {
            New-ProviderCandidate -Provider 'claude' -Role 'researcher' -CapabilityTier $tier -ModelResolution 'alias:haiku' -PromptTransport 'file' -AuthMode 'claude-official-cli' -Rationale 'Use a low-cost summary-capable worker for small context packets.'
        }
    }

    $fallbacks = @(
        New-ProviderCandidate -Provider 'claude' -Role 'worker' -CapabilityTier $tier -ModelResolution 'alias:sonnet' -PromptTransport 'file' -AuthMode 'claude-official-cli' -Rationale 'Fallback to Claude Sonnet alias when the primary provider is unavailable.'
        New-ProviderCandidate -Provider 'codex' -Role 'worker' -CapabilityTier 'fast_coding' -ModelResolution 'provider_recommended_default' -PromptTransport 'file' -AuthMode 'codex-official-cli' -Rationale 'Fallback to Codex default when coding help is still needed and local Codex auth is healthy.'
        New-ProviderCandidate -Provider 'gemini' -Role 'worker' -CapabilityTier 'cheap_summary' -ModelResolution 'alias:flash' -PromptTransport 'file' -AuthMode 'gemini-official-cli' -Rationale 'Fallback to Gemini Flash alias for summarization or broad context reduction.'
    )

    [pscustomobject][ordered]@{
        version = 1
        dry_run = $true
        task_id = $TaskId
        task_title = $title
        priority = $priority
        upper_operator = [ordered]@{
            provider = 'claude'
            product = 'Claude Code'
            owns_final_judgment = $true
        }
        assignment = [ordered]@{
            selected = $primary
            fallback = @($fallbacks)
            approval_policy = if ($secretSensitive) { 'operator_review_required' } else { 'standard' }
            sandbox_mode = if ($worktreeRequired) { 'workspace-write' } else { 'read-only' }
            project_doc_max_bytes = if ($tier -eq 'deep_review') { 200000 } elseif ($tier -eq 'frontier_coding') { 160000 } else { 80000 }
            worktree_required = $worktreeRequired
        }
        security = [ordered]@{
            stores_provider_tokens = $false
            brokers_oauth = $false
            credential_boundary = 'Each provider keeps credentials in its official CLI store.'
            auth_health = 'probe_only'
            secret_safe = -not $secretSensitive
        }
        context_packet = [ordered]@{
            purpose = 'Decompose the task into the smallest worker-owned packet that matches the selected role.'
            non_goals = @('Do not store provider tokens.', 'Do not hard-code dated model ids.', 'Do not bypass the Claude Code operator final judgment.')
            target_files = @()
            stop_conditions = @('provider auth is unhealthy', 'task scope needs user approval', 'worktree isolation is unavailable for write work')
        }
        rationale = @(
            'Claude Code remains the upper operator.',
            'Model selection is expressed as capability tiers and provider aliases instead of fixed model ids.',
            'The dry-run output explains provider fallback before any pane or registry mutation.'
        )
        generated_outputs = @(
            'provider_capability_catalog.generated.json',
            'model_resolution_report.json'
        )
    }
}

$result = Get-AssignmentPolicy -TaskId $TaskId -Text $Text -BacklogPath $BacklogPath
if ($Json) {
    $result | ConvertTo-Json -Depth 16
} else {
    Write-Output "assignment: $($result.assignment.selected.provider) / $($result.assignment.selected.model_resolution)"
    Write-Output "role: $($result.assignment.selected.role)"
    Write-Output "tier: $($result.assignment.selected.capability_tier)"
    Write-Output "approval: $($result.assignment.approval_policy)"
    Write-Output "sandbox: $($result.assignment.sandbox_mode)"
}
