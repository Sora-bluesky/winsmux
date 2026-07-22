[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Task,
    [ValidateSet('', 'start', 'resume')]
    [string]$WorkflowAction = '',
    [string]$RecipeId = '',
    [string]$WorkflowId = '',
    [string]$RunId = '',
    [string]$GenerationId = '',
    [string]$ConfigFingerprint = '',
    [string]$SourceHead = '',
    [string]$TaskFile = '',
    [string]$ProjectDir = '',
    [string]$Builder = 'worker-1',
    [string]$Researcher = '',
    [string]$Reviewer = '',
    [string]$ManifestPath,
    [string]$BuilderWorktreePath,
    [int]$PollIntervalSeconds = 10,
    [int]$StageTimeoutSeconds = 240,
    [int]$MaxFixRounds = 2,
    [switch]$SkipPlan,
    [switch]$SkipVerify,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:TeamPipelineBridgeScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\winsmux-core.ps1'))
$script:TeamPipelineLoggerScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'logger.ps1'))
$script:TeamPipelinePaneEnvScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'pane-env.ps1'))
$script:TeamPipelineDangerousApprovalPattern = '(?im)(rm\s+-rf|Remove-Item\s+.+-Recurse.+-Force|git\s+push\s+--force|git\s+reset\s+--hard|DROP\s+TABLE|DELETE\s+FROM)'

. (Join-Path $PSScriptRoot 'manifest.ps1')
. (Join-Path $PSScriptRoot 'json-compat.ps1')
. (Join-Path $PSScriptRoot 'declarative-workflow.ps1')
. (Join-Path $PSScriptRoot 'pane-control.ps1')
if (Test-Path $script:TeamPipelineLoggerScript -PathType Leaf) {
    . $script:TeamPipelineLoggerScript
}
if (Test-Path $script:TeamPipelinePaneEnvScript -PathType Leaf) {
    . $script:TeamPipelinePaneEnvScript
}

function Get-TeamPipelineValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($Name)) {
        return $InputObject[$Name]
    }

    if ($null -ne $InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }

    return $Default
}

function Test-TeamPipelineValueExists {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }

    if ($null -ne $InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $true
    }

    return $false
}

function ConvertFrom-TeamPipelineYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = $Value.ToString().Trim()
    if ($text.Length -ge 2) {
        if (($text.StartsWith('"') -and $text.EndsWith('"')) -or ($text.StartsWith("'") -and $text.EndsWith("'"))) {
            $text = $text.Substring(1, $text.Length - 2)
        }
    }

    if ($text -eq 'null') {
        return $null
    }

    return $text
}

function Get-TeamPipelineManifestPath {
    param([string]$ProjectDir = (Get-Location).Path)

    return Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
}

function ConvertFrom-TeamPipelineManifestContent {
    param([Parameter(Mandatory = $true)][string]$Content)

    $parsed = ConvertFrom-ManifestYaml -Content $Content
    return [PSCustomObject]@{
        Session = $parsed.session
        Panes   = $parsed.panes
    }
}

function Read-TeamPipelineManifest {
    param([string]$Path = (Get-TeamPipelineManifestPath))

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path -PathType Leaf)) {
        return $null
    }

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }

    return ConvertFrom-TeamPipelineManifestContent -Content $content
}

function Get-TeamPipelinePaneInfo {
    param(
        [AllowNull()]$Manifest,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($null -eq $Manifest -or $null -eq $Manifest.Panes) {
        return $null
    }

    if (-not $Manifest.Panes.Contains($Label)) {
        return $null
    }

    return $Manifest.Panes[$Label]
}

function Get-TeamPipelinePaneCapabilityFlag {
    param(
        [AllowNull()]$Pane,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = Get-TeamPipelineValue -InputObject $Pane -Name $Name -Default $false
    if ($value -is [bool]) {
        return [bool]$value
    }

    $text = ([string]$value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    if ([string]::Equals($text, 'true', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    if ([string]::Equals($text, 'false', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    return $false
}

function Test-TeamPipelineBuildTargetAvailable {
    param(
        [AllowNull()]$Manifest,
        [Parameter(Mandatory = $true)][string]$BuilderLabel
    )

    if ($null -eq $Manifest -or $null -eq $Manifest.Panes) {
        return $true
    }

    $pane = Get-TeamPipelinePaneInfo -Manifest $Manifest -Label $BuilderLabel
    if ($null -eq $pane) {
        return $true
    }

    if (-not (Test-TeamPipelineValueExists -InputObject $pane -Name 'supports_file_edit')) {
        return $true
    }

    $capabilityAdapter = [string](Get-TeamPipelineValue -InputObject $pane -Name 'capability_adapter' -Default '')
    $capabilityCommand = [string](Get-TeamPipelineValue -InputObject $pane -Name 'capability_command' -Default '')
    if ([string]::IsNullOrWhiteSpace($capabilityAdapter) -and [string]::IsNullOrWhiteSpace($capabilityCommand)) {
        return $true
    }

    return (Get-TeamPipelinePaneCapabilityFlag -Pane $pane -Name 'supports_file_edit')
}

function Get-TeamPipelineCapabilityTarget {
    param(
        [AllowNull()]$Manifest,
        [string]$CapabilityName = '',
        [string[]]$CapabilityNames = @(),
        [Parameter(Mandatory = $true)][string]$BuilderLabel
    )

    if ($null -eq $Manifest -or $null -eq $Manifest.Panes) {
        return $null
    }

    $requiredCapabilities = @()
    if (-not [string]::IsNullOrWhiteSpace($CapabilityName)) {
        $requiredCapabilities += $CapabilityName
    }
    $requiredCapabilities += @($CapabilityNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($requiredCapabilities.Count -lt 1) {
        return $null
    }

    foreach ($roleName in @('Reviewer', 'Researcher', 'Worker', 'Builder')) {
        foreach ($label in @($Manifest.Panes.Keys)) {
            $labelText = [string]$label
            if ([string]::Equals($labelText, $BuilderLabel, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $pane = $Manifest.Panes[$label]
            $hasRequiredCapabilities = $true
            foreach ($requiredCapability in $requiredCapabilities) {
                if (-not (Get-TeamPipelinePaneCapabilityFlag -Pane $pane -Name $requiredCapability)) {
                    $hasRequiredCapabilities = $false
                    break
                }
            }

            if (-not $hasRequiredCapabilities) {
                continue
            }

            $role = [string](Get-TeamPipelineValue -InputObject $pane -Name 'role' -Default '')
            if ($roleName -eq 'Builder') {
                if ([string]::IsNullOrWhiteSpace($role) -or [string]::Equals($role, 'Builder', [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $labelText
                }

                continue
            }

            if ([string]::Equals($role, $roleName, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $labelText
            }
        }
    }

    return $null
}

function Test-TeamPipelineTargetCapabilities {
    param(
        [AllowNull()]$Manifest,
        [Parameter(Mandatory = $true)][string]$Label,
        [string[]]$CapabilityNames = @()
    )

    if ([string]::IsNullOrWhiteSpace($Label)) {
        return $false
    }

    if ($null -eq $Manifest -or $null -eq $Manifest.Panes) {
        return $true
    }

    $pane = Get-TeamPipelinePaneInfo -Manifest $Manifest -Label $Label
    if ($null -eq $pane) {
        return $true
    }

    foreach ($capabilityName in @($CapabilityNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        if (-not (Get-TeamPipelinePaneCapabilityFlag -Pane $pane -Name $capabilityName)) {
            return $false
        }
    }

    return $true
}

function Resolve-TeamPipelineBuilderContext {
    param(
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [AllowNull()]$Manifest,
        [string]$OverrideWorktreePath
    )

    $pane = Get-TeamPipelinePaneInfo -Manifest $Manifest -Label $BuilderLabel
    $projectDir = [string](Get-TeamPipelineValue -InputObject $Manifest.Session -Name 'project_dir' -Default '')

    if ([string]::IsNullOrWhiteSpace($projectDir)) {
        $projectDir = (Get-Location).Path
    }

    $worktreePath = $OverrideWorktreePath
    if ([string]::IsNullOrWhiteSpace($worktreePath) -and $null -ne $pane) {
        foreach ($candidateKey in @('builder_worktree_path', 'launch_dir')) {
            $candidate = [string](Get-TeamPipelineValue -InputObject $pane -Name $candidateKey -Default '')
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $worktreePath = $candidate
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($worktreePath)) {
        $worktreePath = $projectDir
    }

    return [PSCustomObject]@{
        BuilderLabel      = $BuilderLabel
        BuilderPaneId     = if ($null -ne $pane) { [string](Get-TeamPipelineValue -InputObject $pane -Name 'pane_id' -Default $null) } else { $null }
        ProjectDir        = $projectDir
        BuilderWorktreePath = $worktreePath
    }
}

function Get-TeamPipelineSessionName {
    param([AllowNull()]$Manifest)

    $sessionName = [string](Get-TeamPipelineValue -InputObject $Manifest.Session -Name 'name' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($sessionName)) {
        return $sessionName
    }

    return 'winsmux-orchestra'
}

function Get-TeamPipelineStageTargets {
    param(
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [string]$ResearcherLabel,
        [string]$ReviewerLabel,
        [AllowNull()]$Manifest,
        [switch]$SkipPlan,
        [switch]$SkipVerify
    )

    $planTarget = $null
    if (-not $SkipPlan) {
        if (-not [string]::IsNullOrWhiteSpace($ResearcherLabel)) {
            $planTarget = $ResearcherLabel
        } else {
            $planTarget = $BuilderLabel
        }
    }

    $verifyTarget = $null
    $requiredVerifyCapabilities = @('supports_verification', 'supports_structured_result')
    if (-not $SkipVerify) {
        if (-not [string]::IsNullOrWhiteSpace($ReviewerLabel)) {
            $verifyTarget = $ReviewerLabel
        } elseif ($null -ne $Manifest) {
            $verifyTarget = Get-TeamPipelineCapabilityTarget -Manifest $Manifest -CapabilityNames $requiredVerifyCapabilities -BuilderLabel $BuilderLabel
        }

        if (
            [string]::IsNullOrWhiteSpace($verifyTarget) -and
            -not [string]::IsNullOrWhiteSpace($ResearcherLabel) -and
            (Test-TeamPipelineTargetCapabilities -Manifest $Manifest -Label $ResearcherLabel -CapabilityNames $requiredVerifyCapabilities)
        ) {
            $verifyTarget = $ResearcherLabel
        } elseif (
            [string]::IsNullOrWhiteSpace($verifyTarget) -and
            (Test-TeamPipelineTargetCapabilities -Manifest $Manifest -Label $BuilderLabel -CapabilityNames $requiredVerifyCapabilities)
        ) {
            $verifyTarget = $BuilderLabel
        }
    }

    return [PSCustomObject]@{
        PlanTarget   = $planTarget
        BuildTarget  = $BuilderLabel
        VerifyTarget = $verifyTarget
    }
}

function Get-TeamPipelineConsultTarget {
    param(
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [string]$ResearcherLabel,
        [string]$ReviewerLabel,
        [AllowNull()]$Manifest
    )

    if (-not [string]::IsNullOrWhiteSpace($ReviewerLabel) -and $ReviewerLabel -ne $BuilderLabel) {
        return $ReviewerLabel
    }

    if (-not [string]::IsNullOrWhiteSpace($ResearcherLabel) -and $ResearcherLabel -ne $BuilderLabel) {
        return $ResearcherLabel
    }

    $capabilityTarget = Get-TeamPipelineCapabilityTarget -Manifest $Manifest -CapabilityName 'supports_consultation' -BuilderLabel $BuilderLabel
    if (-not [string]::IsNullOrWhiteSpace($capabilityTarget)) {
        return $capabilityTarget
    }

    return $null
}

function Get-TeamPipelineCanonicalRole {
    param([AllowNull()][string]$Label)

    if ([string]::IsNullOrWhiteSpace($Label)) {
        return ''
    }

    switch -Regex ($Label.Trim()) {
        '^(?i)worker(?:$|[-_:/\s])' { return 'Worker' }
        '^(?i)builder(?:$|[-_:/\s])' { return 'Builder' }
        '^(?i)researcher(?:$|[-_:/\s])' { return 'Researcher' }
        '^(?i)reviewer(?:$|[-_:/\s])' { return 'Reviewer' }
        default { return '' }
    }
}

function Get-TeamPipelineConsultRole {
    param(
        [Parameter(Mandatory = $true)][string]$TargetLabel,
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [string]$ResearcherLabel,
        [string]$ReviewerLabel
    )

    if (-not [string]::IsNullOrWhiteSpace($ReviewerLabel) -and $TargetLabel -eq $ReviewerLabel) {
        return 'Reviewer'
    }

    if (-not [string]::IsNullOrWhiteSpace($ResearcherLabel) -and $TargetLabel -eq $ResearcherLabel) {
        return 'Researcher'
    }

    if ($TargetLabel -eq $BuilderLabel) {
        return 'Builder'
    }

    $canonical = Get-TeamPipelineCanonicalRole -Label $TargetLabel
    if (-not [string]::IsNullOrWhiteSpace($canonical)) {
        return $canonical
    }

    return 'Worker'
}

function Invoke-TeamPipelineBridge {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & pwsh -NoProfile -File $script:TeamPipelineBridgeScript @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).TrimEnd()

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = 'unknown winsmux error'
        }

        throw "winsmux $($Arguments -join ' ') failed: $text"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $text
    }
}

function Get-TeamPipelineStatusFromOutput {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $matches = [regex]::Matches($Text, '(?im)^\s*STATUS:\s*([A-Z_]+)\s*$')
    if ($matches.Count -lt 1) {
        return $null
    }

    return $matches[$matches.Count - 1].Groups[1].Value.ToUpperInvariant()
}

function Get-TeamPipelineSummaryFromOutput {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $cleaned = [regex]::Replace($Text, '(?im)^\s*STATUS:\s*[A-Z_]+\s*$', '').Trim()
    return $cleaned
}

function Get-TeamPipelineVerificationResultFromOutput {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $status = Get-TeamPipelineStatusFromOutput -Text $Text
    if ([string]::IsNullOrWhiteSpace($status)) {
        return $null
    }

    $summary = ''
    $summaryMatches = [regex]::Matches($Text, '(?im)^\s*SUMMARY:\s*(.+?)\s*$')
    if ($summaryMatches.Count -gt 0) {
        $summary = $summaryMatches[$summaryMatches.Count - 1].Groups[1].Value.Trim()
    } else {
        $summary = Get-TeamPipelineSummaryFromOutput -Text $Text
    }

    $checks = @()
    foreach ($match in [regex]::Matches($Text, '(?im)^\s*CHECK:\s*([^|]+)\|([^|]+)\|(.+?)\s*$')) {
        $checks += [ordered]@{
            name   = $match.Groups[1].Value.Trim()
            status = $match.Groups[2].Value.Trim().ToUpperInvariant()
            detail = $match.Groups[3].Value.Trim()
        }
    }

    $nextAction = ''
    $nextActionMatches = [regex]::Matches($Text, '(?im)^\s*NEXT_ACTION:\s*(.+?)\s*$')
    if ($nextActionMatches.Count -gt 0) {
        $nextAction = $nextActionMatches[$nextActionMatches.Count - 1].Groups[1].Value.Trim()
    }

    $contextBudget = $null
    $contextBudgetMatches = [regex]::Matches($Text, '(?im)^\s*CONTEXT_BUDGET:\s*(\d+)\s*$')
    if ($contextBudgetMatches.Count -gt 0) {
        $contextBudget = [int64]$contextBudgetMatches[$contextBudgetMatches.Count - 1].Groups[1].Value
    }

    $contextEstimate = $null
    $contextEstimateMatches = [regex]::Matches($Text, '(?im)^\s*CONTEXT_ESTIMATE:\s*(\d+)\s*$')
    if ($contextEstimateMatches.Count -gt 0) {
        $contextEstimate = [int64]$contextEstimateMatches[$contextEstimateMatches.Count - 1].Groups[1].Value
    }

    $contextPackId = $null
    $contextPackMatches = [regex]::Matches($Text, '(?im)^\s*CONTEXT_PACK_ID:\s*(.+?)\s*$')
    if ($contextPackMatches.Count -gt 0) {
        $contextPackId = $contextPackMatches[$contextPackMatches.Count - 1].Groups[1].Value.Trim()
    }

    $toolOutputPrunedCount = $null
    $toolOutputPrunedMatches = [regex]::Matches($Text, '(?im)^\s*TOOL_OUTPUT_PRUNED_COUNT:\s*(\d+)\s*$')
    if ($toolOutputPrunedMatches.Count -gt 0) {
        $toolOutputPrunedCount = [int64]$toolOutputPrunedMatches[$toolOutputPrunedMatches.Count - 1].Groups[1].Value
    }

    $contextPressure = $null
    $contextPressureMatches = [regex]::Matches($Text, '(?im)^\s*CONTEXT_PRESSURE:\s*(.+?)\s*$')
    if ($contextPressureMatches.Count -gt 0) {
        $contextPressure = $contextPressureMatches[$contextPressureMatches.Count - 1].Groups[1].Value.Trim()
    }

    $outcome = switch ($status) {
        'VERIFY_PASS' { 'PASS' }
        'VERIFY_FAIL' { 'FAIL' }
        'VERIFY_PARTIAL' { 'PARTIAL' }
        'BLOCKED' { 'PARTIAL' }
        default { 'PARTIAL' }
    }

    return [ordered]@{
        outcome     = $outcome
        summary     = $summary
        checks      = @($checks)
        next_action = $nextAction
        adversarial = $true
        context_budget = $contextBudget
        context_estimate = $contextEstimate
        context_pack_id = $contextPackId
        tool_output_pruned_count = $toolOutputPrunedCount
        context_pressure = $contextPressure
    }
}

function Get-TeamPipelineVerificationSurface {
    param(
        [AllowNull()]$VerificationResult = $null,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $VerificationResult) {
        return $null
    }

    $checks = @(Get-TeamPipelineVerificationResultField -VerificationResult $VerificationResult -Name 'checks')
    $matches = @($checks | Where-Object {
            $checkName = if ($_ -is [System.Collections.IDictionary] -and $_.Contains('name')) { [string]$_['name'] } else { [string]$_.name }
            $checkName.Trim().ToLowerInvariant() -eq $Name
        })
    if ($matches.Count -lt 1) {
        return $null
    }
    $match = $matches[0]

    $matchName = if ($match -is [System.Collections.IDictionary] -and $match.Contains('name')) { [string]$match['name'] } else { [string]$match.name }
    $matchStatus = if ($match -is [System.Collections.IDictionary] -and $match.Contains('status')) { [string]$match['status'] } else { [string]$match.status }
    $matchDetail = if ($match -is [System.Collections.IDictionary] -and $match.Contains('detail')) { [string]$match['detail'] } else { [string]$match.detail }

    return [PSCustomObject][ordered]@{
        name = $matchName
        outcome = $matchStatus
        detail = $matchDetail
    }
}

function Get-TeamPipelineVerificationResultField {
    param(
        [AllowNull()]$VerificationResult = $null,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $VerificationResult) {
        return $null
    }

    if ($VerificationResult -is [System.Collections.IDictionary] -and $VerificationResult.Contains($Name)) {
        return $VerificationResult[$Name]
    }

    return $VerificationResult.$Name
}

function New-TeamPipelineVerificationEvidenceEnvelope {
    param([AllowNull()]$VerificationResult = $null)

    return [ordered]@{
        build                    = Get-TeamPipelineVerificationSurface -VerificationResult $VerificationResult -Name 'build'
        test                     = Get-TeamPipelineVerificationSurface -VerificationResult $VerificationResult -Name 'test'
        browser                  = Get-TeamPipelineVerificationSurface -VerificationResult $VerificationResult -Name 'browser'
        screenshot               = Get-TeamPipelineVerificationSurface -VerificationResult $VerificationResult -Name 'screenshot'
        recording                = Get-TeamPipelineVerificationSurface -VerificationResult $VerificationResult -Name 'recording'
        context_budget           = Get-TeamPipelineVerificationResultField -VerificationResult $VerificationResult -Name 'context_budget'
        context_estimate         = Get-TeamPipelineVerificationResultField -VerificationResult $VerificationResult -Name 'context_estimate'
        context_pack_id          = Get-TeamPipelineVerificationResultField -VerificationResult $VerificationResult -Name 'context_pack_id'
        tool_output_pruned_count = Get-TeamPipelineVerificationResultField -VerificationResult $VerificationResult -Name 'tool_output_pruned_count'
        context_pressure         = Get-TeamPipelineVerificationResultField -VerificationResult $VerificationResult -Name 'context_pressure'
    }
}

function New-TeamPipelineVerificationContract {
    return [ordered]@{
        version          = 1
        source_task      = 'TASK-272'
        mode             = 'adversarial_verify'
        style            = 'utility_first'
        allowed_outcomes = @('PASS', 'FAIL', 'PARTIAL')
        required_fields  = @('summary', 'checks', 'next_action')
        evidence_surfaces = @('build', 'test', 'browser', 'screenshot', 'recording')
        context_fields    = @('context_budget', 'context_estimate', 'context_pack_id', 'tool_output_pruned_count', 'context_pressure')
        rationale        = 'Verification specialists must return concise structured evidence instead of decorative prose.'
    }
}

function Get-TeamPipelineApprovalAction {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    if ($Text -match $script:TeamPipelineDangerousApprovalPattern) {
        throw 'Dangerous approval request detected. Manual intervention is required.'
    }

    if ($Text -match "(?im)^\s*2\.\s*Yes,\s*and don't ask again") {
        return [PSCustomObject]@{
            Kind   = 'TypeEnter'
            Value  = '2'
            Reason = 'persistent approval prompt'
        }
    }

    if ($Text -match '(?im)^\s*1\.\s*Yes\b' -or $Text -match '(?im)Do you want to proceed\?') {
        return [PSCustomObject]@{
            Kind   = 'TypeEnter'
            Value  = '1'
            Reason = 'numbered approval prompt'
        }
    }

    if ($Text -match '(?im)\[(?:Y/n|y/N)\]') {
        return [PSCustomObject]@{
            Kind   = 'TypeEnter'
            Value  = 'y'
            Reason = 'shell confirmation prompt'
        }
    }

    if ($Text -match '(?im)Esc to cancel') {
        return [PSCustomObject]@{
            Kind   = 'Enter'
            Value  = $null
            Reason = 'enter-to-confirm prompt'
        }
    }

    return $null
}

function Invoke-TeamPipelineApproval {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$Action
    )

    Invoke-TeamPipelineBridge -Arguments @('read', $Target, '40') | Out-Null

    switch ($Action.Kind) {
        'TypeEnter' {
            Invoke-TeamPipelineBridge -Arguments @('type', $Target, $Action.Value) | Out-Null
            Invoke-TeamPipelineBridge -Arguments @('read', $Target, '20') | Out-Null
            Invoke-TeamPipelineBridge -Arguments @('keys', $Target, 'Enter') | Out-Null
        }
        'Enter' {
            Invoke-TeamPipelineBridge -Arguments @('keys', $Target, 'Enter') | Out-Null
        }
        default {
            throw "Unsupported approval action: $($Action.Kind)"
        }
    }
}

function Get-TeamPipelineRunPolicy {
    param([Parameter(Mandatory = $true)][string]$StageName)

    $upperStage = $StageName.ToUpperInvariant()
    switch -Regex ($upperStage) {
        '^PLAN$' {
            return [ordered]@{
                stage         = $upperStage
                advisory_mode = $false
                allow         = @('read', 'analysis')
                block         = @('write', 'git', 'network', 'destructive')
            }
        }
        '^EXEC$' {
            return [ordered]@{
                stage         = $upperStage
                advisory_mode = $false
                allow         = @('read', 'write', 'git', 'build', 'test', 'lint')
                block         = @('force_push', 'hard_reset', 'recursive_delete', 'schema_drop')
            }
        }
        '^VERIFY$' {
            return [ordered]@{
                stage         = $upperStage
                advisory_mode = $false
                allow         = @('read', 'build', 'test', 'lint')
                block         = @('write', 'git', 'network', 'destructive')
            }
        }
        '^CONSULT_' {
            return [ordered]@{
                stage         = $upperStage
                advisory_mode = $true
                allow         = @('read', 'analysis')
                block         = @('write', 'git', 'network', 'destructive')
            }
        }
        default {
            return [ordered]@{
                stage         = $upperStage
                advisory_mode = $false
                allow         = @('read')
                block         = @('destructive')
            }
        }
    }
}

function Get-TeamPipelineExplicitCommandLines {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($rawLine in ($Text -split "\r?\n")) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $line = ($line -replace '^(?:[-*+]|\d+\.)\s*', '').Trim()
        if ($line -match '^(?:pwsh|powershell|git|winsmux|apply_patch|Set-Content|Out-File|Add-Content|New-Item|Copy-Item|Move-Item|Remove-Item|curl|wget|Invoke-WebRequest|Invoke-RestMethod|npm|pnpm|yarn|pip|uv|cargo|winget|choco|scoop)\b') {
            $result.Add($line) | Out-Null
        }
    }

    return @($result)
}

function Find-TeamPipelineSecurityViolation {
    param(
        [Parameter(Mandatory = $true)][string]$StageName,
        [AllowNull()][string]$Text
    )

    $commandLines = @(Get-TeamPipelineExplicitCommandLines -Text $Text)
    if ($commandLines.Count -lt 1) {
        return $null
    }

    $policy = Get-TeamPipelineRunPolicy -StageName $StageName
    $categoryPatterns = [ordered]@{
        write          = '(?i)\b(?:apply_patch|Set-Content|Out-File|Add-Content|New-Item|Copy-Item|Move-Item|Remove-Item)\b'
        git            = '(?i)\bgit\s+(?:add|commit|push|merge|rebase|checkout|switch|tag|stash|reset|cherry-pick)\b'
        network        = '(?i)\b(?:curl|wget|Invoke-WebRequest|Invoke-RestMethod|npm\s+install|pnpm\s+add|yarn\s+add|pip\s+install|uv\s+pip|cargo\s+add|winget\s+install|choco\s+install|scoop\s+install)\b'
        destructive    = '(?im)(rm\s+-rf|Remove-Item\s+.+-Recurse.+-Force|DROP\s+TABLE|DELETE\s+FROM)'
        force_push     = '(?i)\bgit\s+push\s+--force(?:-with-lease)?\b'
        hard_reset     = '(?i)\bgit\s+reset\s+--hard\b'
        recursive_delete = '(?i)\bRemove-Item\b.+-Recurse.+-Force'
        schema_drop    = '(?i)\bDROP\s+TABLE\b'
    }

    foreach ($line in $commandLines) {
        foreach ($blockedCategory in @($policy.block)) {
            if (-not $categoryPatterns.Contains($blockedCategory)) {
                continue
            }

            if ($line -match $categoryPatterns[$blockedCategory]) {
                return [ordered]@{
                    line = $line
                    category = $blockedCategory
                    reason = "stage $($policy.stage) blocks explicit $blockedCategory commands before dispatch"
                    policy = $policy
                }
            }
        }
    }

    return $null
}

function Get-TeamPipelineChangedPaths {
    param([string]$BuilderWorktreePath)

    if ([string]::IsNullOrWhiteSpace($BuilderWorktreePath) -or -not (Test-Path -LiteralPath $BuilderWorktreePath -PathType Container)) {
        return @()
    }

    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $gitExe) {
        return @()
    }

    try {
        $changed = & $gitExe.Source -C $BuilderWorktreePath diff --name-only --relative 2>$null
        if ($LASTEXITCODE -ne 0) {
            return @()
        }
    } catch {
        return @()
    }

    return @($changed | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function New-TeamPipelineSecurityVerdict {
    param(
        [Parameter(Mandatory = $true)][string]$StageName,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$ActionKind = '',
        [string]$ActionValue = '',
        [string]$PromptText = ''
    )

    $policy = Get-TeamPipelineRunPolicy -StageName $StageName
    return [PSCustomObject]@{
        packet_type   = 'security_verdict'
        scope         = 'run'
        stage         = $policy.stage
        target        = $Target
        verdict       = 'BLOCK'
        reason        = $Reason
        action_kind   = $ActionKind
        action_value  = $ActionValue
        prompt_text   = $PromptText
        advisory_mode = [bool]$policy.advisory_mode
        allow         = @($policy.allow)
        block         = @($policy.block)
        next_action   = 'revise_request_or_override'
    }
}

function Invoke-TeamPipelineGuardedSend {
    param(
        [Parameter(Mandatory = $true)][string]$StageName,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [string]$Role = '',
        [string]$Task = '',
        [int]$Attempt = 0,
        [AllowEmptyString()][string]$ExpectedGenerationId = '',
        [switch]$RedactEventPayload
    )

    $violation = Find-TeamPipelineSecurityViolation -StageName $StageName -Text $Prompt
    if ($null -eq $violation) {
        $sendArguments = @('send', $Target)
        if (-not [string]::IsNullOrWhiteSpace($ExpectedGenerationId)) {
            $sendArguments += @('--expected-generation-id', $ExpectedGenerationId)
        }
        $sendArguments += @($Prompt)
        Invoke-TeamPipelineBridge -Arguments $sendArguments | Out-Null
        return $null
    }

    $securityVerdict = New-TeamPipelineSecurityVerdict -StageName $StageName -Target $Target -Reason ([string]$violation['reason']) -ActionKind 'pre_dispatch' -ActionValue ([string]$violation['line']) -PromptText $Prompt
    $eventReason = if ($RedactEventPayload) { 'Security policy rejected declarative workflow input.' } else { $securityVerdict.reason }
    $eventActionValue = if ($RedactEventPayload) { '' } else { [string]$violation['line'] }
    Write-TeamPipelineEvent -ProjectDir $ProjectDir -SessionName $SessionName -Event 'pipeline.security.blocked' -Message "Security monitor blocked $StageName on $Target before dispatch." -Role $Role -Target $Target -Data ([ordered]@{
        stage         = $securityVerdict.stage
        attempt       = $Attempt
        task          = $Task
        verdict       = $securityVerdict.verdict
        reason        = $eventReason
        advisory_mode = $securityVerdict.advisory_mode
        allow         = @($securityVerdict.allow)
        block         = @($securityVerdict.block)
        next_action   = $securityVerdict.next_action
        action_kind   = 'pre_dispatch'
        action_value  = $eventActionValue
        category      = [string]$violation['category']
    }) | Out-Null

    return [PSCustomObject]@{
        Stage      = $StageName
        Target     = $Target
        Status     = 'BLOCKED'
        Summary    = "Security monitor blocked $StageName before dispatch. $([string]$violation['reason'])"
        Transcript = $Prompt
        Policy     = [PSCustomObject]$violation['policy']
        SecurityVerdict = $securityVerdict
        VerificationResult = $null
    }
}

function New-TeamPipelineVerificationPacket {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][string]$VerifyStatus,
        [Parameter(Mandatory = $true)][string]$VerifierLabel,
        [string]$BuilderLabel = '',
        [string]$BuilderWorktreePath = '',
        [string]$Summary = ''
    )

    $verdict = switch ($VerifyStatus) {
        'VERIFY_PASS' { 'PASS' }
        'VERIFY_FAIL' { 'FAIL' }
        'BLOCKED' { 'PARTIAL' }
        default { 'PARTIAL' }
    }

    $nextAction = switch ($verdict) {
        'PASS' { 'ready_for_done' }
        'FAIL' { 'fix_and_rerun_verify' }
        default { 'unblock_verify' }
    }

    $verificationResult = Get-TeamPipelineVerificationResultFromOutput -Text $Summary
    $trimmedSummary = [string]$Summary
    if ($null -ne $verificationResult -and -not [string]::IsNullOrWhiteSpace([string]$verificationResult.summary)) {
        $trimmedSummary = [string]$verificationResult.summary
    }
    $changedPaths = Get-TeamPipelineChangedPaths -BuilderWorktreePath $BuilderWorktreePath
    $policy = Get-TeamPipelineRunPolicy -StageName 'VERIFY'
    $verificationEvidence = New-TeamPipelineVerificationEvidenceEnvelope -VerificationResult $verificationResult

    return [PSCustomObject]@{
        packet_type        = 'verification_packet'
        verification_contract = [PSCustomObject](New-TeamPipelineVerificationContract)
        verification_result = if ($null -ne $verificationResult) { [PSCustomObject]$verificationResult } else { $null }
        verification_evidence = [PSCustomObject]$verificationEvidence
        style              = 'utility_first'
        task               = $Task
        verifier           = $VerifierLabel
        builder            = $BuilderLabel
        builder_worktree   = $BuilderWorktreePath
        verify_status      = $VerifyStatus
        verdict            = $verdict
        changed_paths      = @($changedPaths)
        changed_path_count = @($changedPaths).Count
        evidence_refs      = @($changedPaths)
        failing_probe      = if ($verdict -eq 'PASS') { '' } else { $trimmedSummary }
        next_action        = if ($null -ne $verificationResult -and -not [string]::IsNullOrWhiteSpace([string]$verificationResult.next_action)) { [string]$verificationResult.next_action } else { $nextAction }
        summary            = $trimmedSummary
        policy             = [PSCustomObject]$policy
    }
}

function Wait-TeamPipelineStage {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$StageName,
        [int]$TimeoutSeconds = 240,
        [int]$PollIntervalSeconds = 10,
        [string]$ProjectDir = '',
        [string]$SessionName = '',
        [string]$Role = '',
        [string]$Task = '',
        [int]$Attempt = 0,
        [switch]$RedactEventPayload
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastOutput = ''
    $policy = [PSCustomObject](Get-TeamPipelineRunPolicy -StageName $StageName)

    while ((Get-Date) -lt $deadline) {
        $readResult = Invoke-TeamPipelineBridge -Arguments @('read', $Target, '120')
        $lastOutput = $readResult.Output

        $status = Get-TeamPipelineStatusFromOutput -Text $lastOutput
        if ($null -ne $status) {
            $verificationResult = $null
            $summary = Get-TeamPipelineSummaryFromOutput -Text $lastOutput
            if ($StageName.ToUpperInvariant() -eq 'VERIFY') {
                $verificationResult = Get-TeamPipelineVerificationResultFromOutput -Text $lastOutput
                if ($null -ne $verificationResult -and -not [string]::IsNullOrWhiteSpace([string]$verificationResult.summary)) {
                    $summary = [string]$verificationResult.summary
                }
            }

            return [PSCustomObject]@{
                Stage      = $StageName
                Target     = $Target
                Status     = $status
                Summary    = $summary
                Transcript = $lastOutput
                Policy     = $policy
                SecurityVerdict = $null
                VerificationResult = $verificationResult
            }
        }

        $approvalAction = $null
        try {
            $approvalAction = Get-TeamPipelineApprovalAction -Text $lastOutput
        } catch {
            $securityVerdict = New-TeamPipelineSecurityVerdict -StageName $StageName -Target $Target -Reason $_.Exception.Message -PromptText $lastOutput
            if (-not [string]::IsNullOrWhiteSpace($ProjectDir) -and -not [string]::IsNullOrWhiteSpace($SessionName)) {
                Write-TeamPipelineEvent -ProjectDir $ProjectDir -SessionName $SessionName -Event 'pipeline.security.blocked' -Message "Security monitor blocked $StageName on $Target." -Role $Role -Target $Target -Data ([ordered]@{
                    stage          = $securityVerdict.stage
                    attempt        = $Attempt
                    task           = $Task
                    verdict        = $securityVerdict.verdict
                    reason         = if ($RedactEventPayload) { 'Security policy rejected declarative workflow output.' } else { $securityVerdict.reason }
                    advisory_mode  = $securityVerdict.advisory_mode
                    allow          = @($securityVerdict.allow)
                    block          = @($securityVerdict.block)
                    next_action    = $securityVerdict.next_action
                }) | Out-Null
            }

            return [PSCustomObject]@{
                Stage      = $StageName
                Target     = $Target
                Status     = 'BLOCKED'
                Summary    = "Security monitor blocked approval. $($_.Exception.Message)"
                Transcript = $lastOutput
                Policy     = $policy
                SecurityVerdict = $securityVerdict
                VerificationResult = $null
            }
        }
        if ($null -ne $approvalAction) {
            Invoke-TeamPipelineApproval -Target $Target -Action $approvalAction
            Start-Sleep -Seconds 1
            continue
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out waiting for $StageName on target '$Target'. Last output:`n$lastOutput"
}

function Write-TeamPipelineEvent {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Message,
        [string]$Role,
        [string]$PaneId,
        [string]$Target,
        [AllowNull()]$Data
    )

    if (-not (Get-Command -Name 'Write-OrchestraLog' -ErrorAction SilentlyContinue)) {
        return $null
    }

    return Write-OrchestraLog -ProjectDir $ProjectDir -SessionName $SessionName -Event $Event -Level 'info' -Message $Message -Role $Role -PaneId $PaneId -Target $Target -Data $Data
}

function New-TeamPipelinePlanPrompt {
    param([Parameter(Mandatory = $true)][string]$Task)

    return @"
Plan this engineering task before implementation.

Task:
$Task

Reply with:
- scope
- likely files
- tests or checks to run
- decomposition: 1-4 concrete subtasks the operator can assign or track
- dispatch hints: which worker role should own each subtask and why

End with exactly one line:
STATUS: PLAN_READY

If you cannot produce a plan, end with:
STATUS: BLOCKED
"@
}

function New-TeamPipelineExecPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [string]$PlanSummary
    )

    $planBlock = if ([string]::IsNullOrWhiteSpace($PlanSummary)) {
        'No separate planning notes were provided.'
    } else {
        $PlanSummary
    }

    return @"
Implement this task in your assigned workspace.

Task:
$Task

Plan guidance:
$planBlock

Before finishing:
- run relevant checks or tests
- summarize changed files
- summarize verification performed

End with exactly one line:
STATUS: EXEC_DONE

If blocked, end with:
STATUS: BLOCKED
"@
}

function New-TeamPipelineBuilderCompletionNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [Parameter(Mandatory = $true)][string]$BuilderWorktreePath,
        [Parameter(Mandatory = $true)][int]$Attempt,
        [string]$BuildSummary,
        [string]$VerifyTarget
    )

    $summaryBlock = if ([string]::IsNullOrWhiteSpace($BuildSummary)) {
        'Builder did not provide a summary.'
    } else {
        $BuildSummary.Trim()
    }

    $nextStep = if ([string]::IsNullOrWhiteSpace($VerifyTarget)) {
        'Next step: no reviewer target is configured.'
    } else {
        "Next step: auto-dispatch review to $VerifyTarget."
    }

    $message = @"
Builder completed implementation and is ready for review.

Task:
$Task

Builder label: $BuilderLabel
Builder worktree: $BuilderWorktreePath
Attempt: $Attempt

Builder summary:
$summaryBlock

$nextStep
"@

    return [PSCustomObject]@{
        Attempt            = $Attempt
        BuilderLabel       = $BuilderLabel
        BuilderWorktreePath = $BuilderWorktreePath
        VerifyTarget       = $VerifyTarget
        Summary            = $summaryBlock
        Message            = $message.Trim()
    }
}

function New-TeamPipelineVerifyPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [Parameter(Mandatory = $true)][string]$BuilderWorktreePath,
        [string]$PlanSummary,
        [string]$BuilderCompletionMessage,
        [string]$ContextPackRef = '',
        [string[]]$DependencyNodeIds = @(),
        [string[]]$DependencyEvidenceRefs = @()
    )

    $planBlock = if ([string]::IsNullOrWhiteSpace($PlanSummary)) {
        'No separate planning notes were provided.'
    } else {
        $PlanSummary
    }

    $completionBlock = if ([string]::IsNullOrWhiteSpace($BuilderCompletionMessage)) {
        'No explicit builder completion notification was recorded.'
    } else {
        $BuilderCompletionMessage.Trim()
    }

    $declarativeEvidenceBlock = @()
    if (-not [string]::IsNullOrWhiteSpace($ContextPackRef)) {
        $declarativeEvidenceBlock = @(
            '',
            'Declarative workflow evidence boundary:',
            ('Context package reference: {0}' -f $ContextPackRef),
            ('Dependency node IDs: {0}' -f (@($DependencyNodeIds) -join ', ')),
            'Durable dependency evidence references:'
        ) + @($DependencyEvidenceRefs | ForEach-Object { '- ' + [string]$_ }) + @(
            'Use only these bounded references. Do not request, paste, or rely on raw producer output.'
        )
    }

    return (@(
        'Verify the latest builder result without editing code.'
        ''
        'This review was auto-dispatched after the builder reported completion.'
        ''
        'Task:'
        $Task
        ''
        ('Builder label: {0}' -f $BuilderLabel)
        ('Builder worktree: {0}' -f $BuilderWorktreePath)
        ''
        'Builder completion notification:'
        $completionBlock
        ''
        'Plan guidance:'
        $planBlock
        $declarativeEvidenceBlock
        ''
        'Please inspect the builder workspace, review the current diff, and run focused verification where useful.'
        'If fixes are needed, provide concrete findings the builder can act on.'
        ''
        'End with exactly one line:'
        'STATUS: VERIFY_PASS'
        ''
        'If changes need fixes, end with:'
        'STATUS: VERIFY_FAIL'
        ''
        'If verification is incomplete but actionable evidence exists, end with:'
        'STATUS: VERIFY_PARTIAL'
        ''
        'If blocked, end with:'
        'STATUS: BLOCKED'
        ''
        'Also include:'
        '- one line SUMMARY: ...'
        '- 1-4 lines CHECK: name|PASS|detail or CHECK: name|FAIL|detail'
        '- one line NEXT_ACTION: ...'
    ) -join "`n")
}

function New-TeamPipelineFixPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][string]$VerificationSummary,
        [string]$PlanSummary
    )

    $planBlock = if ([string]::IsNullOrWhiteSpace($PlanSummary)) {
        'No separate planning notes were provided.'
    } else {
        $PlanSummary
    }

    return @"
The verifier found issues. Apply a fix pass in your assigned workspace.

Task:
$Task

Plan guidance:
$planBlock

Verification findings:
$VerificationSummary

After fixing:
- run the relevant checks again
- summarize what changed
- summarize the checks you ran

End with exactly one line:
STATUS: EXEC_DONE

If blocked, end with:
STATUS: BLOCKED
"@
}

function New-TeamPipelineConsultPrompt {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('early', 'stuck', 'final')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Task,
        [string]$PlanSummary = '',
        [string]$BuildSummary = '',
        [string]$VerificationSummary = '',
        [string]$BuilderLabel = '',
        [string]$BuilderWorktreePath = ''
    )

    $modeInstruction = switch ($Mode) {
        'early' { 'Provide a short second opinion before substantive work starts. Focus on likely failure modes, missing evidence, and the best next experiment.' }
        'stuck' { 'The run is blocked. Diagnose the block, propose the safest next test, and identify the smallest unblock path.' }
        'final' { 'The run appears ready to conclude. Sanity-check the result, residual risks, and the single best next validation step before done.' }
    }

    return @"
You are acting in advisory mode for winsmux one-shot orchestration.

Task:
$Task

Consult mode:
$Mode

Builder:
$BuilderLabel

Builder worktree:
$BuilderWorktreePath

Plan summary:
$PlanSummary

Build summary:
$BuildSummary

Verification summary:
$VerificationSummary

$modeInstruction

Constraints:
- Do not edit files.
- Do not run destructive commands.
- Keep the response concise and operational.

Return:
- 2-4 bullet points with advice
- one line `NEXT_TEST: ...`

End with exactly one line:
STATUS: CONSULT_DONE

If you cannot advise safely, end with:
STATUS: BLOCKED
"@
}

function Invoke-TeamPipelineConsultStage {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [string]$TargetLabel = '',
        [string]$ResearcherLabel = '',
        [string]$ReviewerLabel = '',
        [string]$BuilderWorktreePath = '',
        [string]$PlanSummary = '',
        [string]$BuildSummary = '',
        [string]$VerificationSummary = '',
        [int]$TimeoutSeconds = 240,
        [int]$PollIntervalSeconds = 10,
        [int]$Attempt = 0
    )

    if ([string]::IsNullOrWhiteSpace($TargetLabel)) {
        return $null
    }

    $consultRole = Get-TeamPipelineConsultRole -TargetLabel $TargetLabel -BuilderLabel $BuilderLabel -ResearcherLabel $ResearcherLabel -ReviewerLabel $ReviewerLabel
    $prompt = New-TeamPipelineConsultPrompt -Mode $Mode -Task $Task -PlanSummary $PlanSummary -BuildSummary $BuildSummary -VerificationSummary $VerificationSummary -BuilderLabel $BuilderLabel -BuilderWorktreePath $BuilderWorktreePath
    $costUnit = New-WinsmuxGovernanceCostUnit -Kind 'consult' -Mode $Mode -Task $Task -Stage ("CONSULT_{0}" -f $Mode.ToUpperInvariant()) -Role $consultRole -Target $TargetLabel -Attempt $Attempt -Source 'team-pipeline'
    $eventData = [ordered]@{
        mode                 = $Mode
        attempt              = $Attempt
        task                 = $Task
        builder              = $BuilderLabel
        builder_worktree_path = $BuilderWorktreePath
        verify_summary       = $VerificationSummary
        governance_cost_units = @($costUnit)
    }

    $dispatchResult = Invoke-TeamPipelineGuardedSend -StageName ("CONSULT_{0}" -f $Mode.ToUpperInvariant()) -Target $TargetLabel -Prompt $prompt -ProjectDir $ProjectDir -SessionName $SessionName -Role $consultRole -Task $Task -Attempt $Attempt
    if ($null -ne $dispatchResult) {
        return $dispatchResult
    }
    Write-TeamPipelineEvent -ProjectDir $ProjectDir -SessionName $SessionName -Event 'pipeline.consult.dispatched' -Message "Dispatched $Mode consult to $TargetLabel." -Role $consultRole -Target $TargetLabel -Data $eventData | Out-Null
    $stage = Wait-TeamPipelineStage -Target $TargetLabel -StageName ("CONSULT_{0}" -f $Mode.ToUpperInvariant()) -TimeoutSeconds $TimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds -ProjectDir $ProjectDir -SessionName $SessionName -Role $consultRole -Task $Task -Attempt $Attempt

    $completedEvent = if ($stage.Status -eq 'BLOCKED') { 'pipeline.consult.blocked' } else { 'pipeline.consult.completed' }
    Write-TeamPipelineEvent -ProjectDir $ProjectDir -SessionName $SessionName -Event $completedEvent -Message "$Mode consult on $TargetLabel completed with status $($stage.Status)." -Role $consultRole -Target $TargetLabel -Data ([ordered]@{
        mode                  = $Mode
        attempt               = $Attempt
        task                  = $Task
        status                = $stage.Status
        summary               = $stage.Summary
        builder               = $BuilderLabel
        builder_worktree_path = $BuilderWorktreePath
        cost_unit_refs        = @([string]$costUnit.unit_id)
    }) | Out-Null

    return $stage
}

function New-TeamPipelineManagedLoopData {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][ValidateSet('decompose', 'dispatch', 'collect', 'escalate')][string]$Stage,
        [string]$State = '',
        [string]$BuilderLabel = '',
        [string]$ResearcherLabel = '',
        [string]$ReviewerLabel = '',
        [string]$TargetLabel = '',
        [string]$Summary = '',
        [string]$Reason = '',
        [int]$Attempt = 0
    )

    $data = [ordered]@{
        task                 = $Task
        stage                = $Stage
        state                = $State
        upper_operator       = 'claude_code'
        aggregation_point    = 'claude_code_operator'
        worker_topology      = 'operator_managed_panes'
        peer_to_peer_allowed = $false
        builder              = $BuilderLabel
        researcher           = $ResearcherLabel
        reviewer             = $ReviewerLabel
        target               = $TargetLabel
        summary              = $Summary
        reason               = $Reason
    }
    if ($Attempt -gt 0) {
        $data['attempt'] = $Attempt
    }

    return $data
}

function Get-TeamPipelineEscalationTarget {
    param([string]$ConsultTarget = '')

    if ([string]::IsNullOrWhiteSpace($ConsultTarget)) {
        return 'claude_code_operator'
    }

    return $ConsultTarget
}

function Invoke-TeamPipeline {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][string]$Builder,
        [string]$Researcher,
        [string]$Reviewer,
        [string]$ManifestPath,
        [string]$BuilderWorktreePath,
        [int]$PollIntervalSeconds = 10,
        [int]$StageTimeoutSeconds = 240,
        [int]$MaxFixRounds = 2,
        [switch]$SkipPlan,
        [switch]$SkipVerify
    )

    if (-not (Test-Path $script:TeamPipelineBridgeScript -PathType Leaf)) {
        throw "Bridge CLI script not found: $script:TeamPipelineBridgeScript"
    }

    $resolvedManifestPath = $ManifestPath
    if ([string]::IsNullOrWhiteSpace($resolvedManifestPath)) {
        $resolvedManifestPath = Get-TeamPipelineManifestPath
    }

    $manifest = Read-TeamPipelineManifest -Path $resolvedManifestPath
    $builderContext = Resolve-TeamPipelineBuilderContext -BuilderLabel $Builder -Manifest $manifest -OverrideWorktreePath $BuilderWorktreePath
    $sessionName = Get-TeamPipelineSessionName -Manifest $manifest
    $targets = Get-TeamPipelineStageTargets -BuilderLabel $Builder -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -Manifest $manifest -SkipPlan:$SkipPlan -SkipVerify:$SkipVerify

    $result = [ordered]@{
        Task                = $Task
        ManifestPath        = if ($manifest) { $resolvedManifestPath } else { $null }
        ProjectDir          = $builderContext.ProjectDir
        SessionName         = $sessionName
        Builder             = $Builder
        BuilderPaneId       = $builderContext.BuilderPaneId
        BuilderWorktreePath = $builderContext.BuilderWorktreePath
        PlanTarget          = $targets.PlanTarget
        VerifyTarget        = $targets.VerifyTarget
        Plan                = $null
        PreWorkConsult      = $null
        FinalConsult        = $null
        StuckConsults       = @()
        VerificationPackets = @()
        BuildUnavailableReason = ''
        VerificationUnavailableReason = ''
        SecurityVerdicts    = @()
        Attempts            = @()
        Success             = $false
        FinalStatus         = 'NOT_STARTED'
    }

    if (-not (Test-TeamPipelineBuildTargetAvailable -Manifest $manifest -BuilderLabel $Builder)) {
        $result.BuildUnavailableReason = 'Build target does not support file edits.'
        $result.FinalStatus = 'EXEC_UNAVAILABLE'
        return [PSCustomObject]$result
    }

    if (-not $SkipVerify -and [string]::IsNullOrWhiteSpace($targets.VerifyTarget)) {
        $result.VerificationUnavailableReason = 'No verification target supports both verification and structured results.'
        $result.FinalStatus = 'VERIFY_UNAVAILABLE'
        return [PSCustomObject]$result
    }

    $planSummary = ''
    $consultTarget = Get-TeamPipelineConsultTarget -BuilderLabel $Builder -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -Manifest $manifest
    if (-not [string]::IsNullOrWhiteSpace($targets.PlanTarget)) {
        $planPrompt = New-TeamPipelinePlanPrompt -Task $Task
        $planDispatchResult = Invoke-TeamPipelineGuardedSend -StageName 'PLAN' -Target $targets.PlanTarget -Prompt $planPrompt -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Role 'Researcher' -Task $Task
        if ($null -ne $planDispatchResult) {
            $planStage = $planDispatchResult
        } else {
            $planStage = Wait-TeamPipelineStage -Target $targets.PlanTarget -StageName 'PLAN' -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Role 'Researcher' -Task $Task
        }
        $result.Plan = $planStage
        if ($planStage.Status -eq 'BLOCKED') {
        $planSecurityVerdict = Get-TeamPipelineValue -InputObject $planStage -Name 'SecurityVerdict' -Default $null
        if ($null -ne $planSecurityVerdict) {
            $result.SecurityVerdicts += $planSecurityVerdict
        }
            $result.FinalStatus = 'PLAN_BLOCKED'
            return [PSCustomObject]$result
        }

        $planSummary = $planStage.Summary
        Write-TeamPipelineEvent -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Event 'pipeline.decompose.completed' -Message 'Claude Code operator decomposed the task for managed pane assignment.' -Role 'Operator' -Target $targets.PlanTarget -Data (New-TeamPipelineManagedLoopData -Task $Task -Stage 'decompose' -State 'completed' -BuilderLabel $Builder -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -TargetLabel $targets.PlanTarget -Summary $planSummary) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($consultTarget)) {
        $result.PreWorkConsult = Invoke-TeamPipelineConsultStage -Mode 'early' -Task $Task -BuilderLabel $Builder -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -TargetLabel $consultTarget -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -BuilderWorktreePath $builderContext.BuilderWorktreePath -PlanSummary $planSummary -BuildSummary '' -VerificationSummary '' -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds
    }

    $attemptLimit = 1 + [Math]::Max(0, $MaxFixRounds)
    for ($attemptIndex = 1; $attemptIndex -le $attemptLimit; $attemptIndex++) {
        $attempt = [ordered]@{
            Attempt           = $attemptIndex
            Build             = $null
            BuildNotification = $null
            VerifyDispatch    = $null
            Verify            = $null
            VerifyPacket      = $null
            StuckConsult      = $null
        }

        $buildPrompt = if ($attemptIndex -eq 1) {
            New-TeamPipelineExecPrompt -Task $Task -PlanSummary $planSummary
        } else {
            $previousVerify = [string]$result.Attempts[-1].Verify.Summary
            New-TeamPipelineFixPrompt -Task $Task -PlanSummary $planSummary -VerificationSummary $previousVerify
        }

        Write-TeamPipelineEvent -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Event 'pipeline.dispatch.assigned' -Message "Claude Code operator assigned attempt $attemptIndex to $Builder." -Role 'Operator' -Target $Builder -Data (New-TeamPipelineManagedLoopData -Task $Task -Stage 'dispatch' -State 'assigned' -BuilderLabel $Builder -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -TargetLabel $Builder -Summary "Attempt $attemptIndex assigned to $Builder." -Attempt $attemptIndex) | Out-Null
        $buildDispatchResult = Invoke-TeamPipelineGuardedSend -StageName 'EXEC' -Target $Builder -Prompt $buildPrompt -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Role 'Builder' -Task $Task -Attempt $attemptIndex
        if ($null -ne $buildDispatchResult) {
            $buildStage = $buildDispatchResult
        } else {
            $buildStage = Wait-TeamPipelineStage -Target $Builder -StageName 'EXEC' -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Role 'Builder' -Task $Task -Attempt $attemptIndex
        }
        $attempt.Build = $buildStage

        if ($buildStage.Status -eq 'BLOCKED') {
            $buildSecurityVerdict = Get-TeamPipelineValue -InputObject $buildStage -Name 'SecurityVerdict' -Default $null
            if ($null -ne $buildSecurityVerdict) {
                $result.SecurityVerdicts += $buildSecurityVerdict
            }
            $escalationTarget = Get-TeamPipelineEscalationTarget -ConsultTarget $consultTarget
            if (-not [string]::IsNullOrWhiteSpace($consultTarget)) {
                $attempt.StuckConsult = Invoke-TeamPipelineConsultStage -Mode 'stuck' -Task $Task -BuilderLabel $Builder -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -TargetLabel $consultTarget -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -BuilderWorktreePath $builderContext.BuilderWorktreePath -PlanSummary $planSummary -BuildSummary $buildStage.Summary -VerificationSummary '' -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds -Attempt $attemptIndex
                if ($null -ne $attempt.StuckConsult) {
                    $result.StuckConsults += $attempt.StuckConsult
                }
            }
            Write-TeamPipelineEvent -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Event 'pipeline.escalate.required' -Message "Claude Code operator escalation required after blocked execution attempt $attemptIndex." -Role 'Operator' -Target $escalationTarget -Data (New-TeamPipelineManagedLoopData -Task $Task -Stage 'escalate' -State 'required' -BuilderLabel $Builder -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -TargetLabel $escalationTarget -Summary $buildStage.Summary -Reason 'EXEC_BLOCKED' -Attempt $attemptIndex) | Out-Null
            $result.Attempts += [PSCustomObject]$attempt
            $result.FinalStatus = 'EXEC_BLOCKED'
            return [PSCustomObject]$result
        }

        $buildNotification = New-TeamPipelineBuilderCompletionNotification -Task $Task -BuilderLabel $Builder -BuilderWorktreePath $builderContext.BuilderWorktreePath -Attempt $attemptIndex -BuildSummary $buildStage.Summary -VerifyTarget $targets.VerifyTarget
        $attempt.BuildNotification = $buildNotification
        Write-TeamPipelineEvent -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Event 'pipeline.builder.completed' -Message "Builder $Builder completed attempt $attemptIndex." -Role 'Builder' -PaneId $builderContext.BuilderPaneId -Target $Builder -Data ([ordered]@{
            attempt              = $attemptIndex
            task                 = $Task
            status               = $buildStage.Status
            builder_worktree_path = $builderContext.BuilderWorktreePath
            verify_target        = $targets.VerifyTarget
            summary              = $buildNotification.Summary
        }) | Out-Null
        Write-TeamPipelineEvent -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Event 'pipeline.collect.completed' -Message "Claude Code operator collected builder result for attempt $attemptIndex." -Role 'Operator' -Target $Builder -Data (New-TeamPipelineManagedLoopData -Task $Task -Stage 'collect' -State 'builder_result_collected' -BuilderLabel $Builder -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -TargetLabel $Builder -Summary $buildNotification.Summary -Attempt $attemptIndex) | Out-Null

        if ([string]::IsNullOrWhiteSpace($targets.VerifyTarget)) {
            if (-not [string]::IsNullOrWhiteSpace($consultTarget)) {
                $result.FinalConsult = Invoke-TeamPipelineConsultStage -Mode 'final' -Task $Task -BuilderLabel $Builder -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -TargetLabel $consultTarget -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -BuilderWorktreePath $builderContext.BuilderWorktreePath -PlanSummary $planSummary -BuildSummary $buildStage.Summary -VerificationSummary '' -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds -Attempt $attemptIndex
            }
            $result.Attempts += [PSCustomObject]$attempt
            $result.Success = $true
            $result.FinalStatus = 'EXEC_DONE'
            return [PSCustomObject]$result
        }

        $verifyPrompt = New-TeamPipelineVerifyPrompt -Task $Task -BuilderLabel $Builder -BuilderWorktreePath $builderContext.BuilderWorktreePath -PlanSummary $planSummary -BuilderCompletionMessage $buildNotification.Message
        $attempt.VerifyDispatch = [PSCustomObject]@{
            Target            = $targets.VerifyTarget
            Automatic         = $true
            Prompt            = $verifyPrompt
            Notification      = $buildNotification.Message
        }
        $verifyRole = 'Worker'
        if (-not [string]::IsNullOrWhiteSpace($Reviewer) -and $targets.VerifyTarget -eq $Reviewer) {
            $verifyRole = 'Reviewer'
        } elseif (-not [string]::IsNullOrWhiteSpace($Researcher) -and $targets.VerifyTarget -eq $Researcher) {
            $verifyRole = 'Researcher'
        }

        $verifyCostUnit = New-WinsmuxGovernanceCostUnit -Kind 'verify' -Mode 'review' -Task $Task -Stage 'VERIFY' -Role $verifyRole -Target $targets.VerifyTarget -Attempt $attemptIndex -Source 'team-pipeline'
        $verifyCostUnitDispatched = $false
        $verifyDispatchResult = Invoke-TeamPipelineGuardedSend -StageName 'VERIFY' -Target $targets.VerifyTarget -Prompt $verifyPrompt -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Role $verifyRole -Task $Task -Attempt $attemptIndex
        if ($null -ne $verifyDispatchResult) {
            $verifyStage = $verifyDispatchResult
        } else {
            $verifyCostUnitDispatched = $true
            Write-TeamPipelineEvent -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Event 'pipeline.review.dispatched' -Message "Auto-dispatched review to $($targets.VerifyTarget) after builder completion." -Role $verifyRole -Target $targets.VerifyTarget -Data ([ordered]@{
                attempt              = $attemptIndex
                task                 = $Task
                builder              = $Builder
                builder_worktree_path = $builderContext.BuilderWorktreePath
                verify_role          = $verifyRole
                summary              = $buildNotification.Summary
                governance_cost_units = @($verifyCostUnit)
            }) | Out-Null
            $verifyStage = Wait-TeamPipelineStage -Target $targets.VerifyTarget -StageName 'VERIFY' -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Role $verifyRole -Task $Task -Attempt $attemptIndex
        }
        $attempt.Verify = $verifyStage
        $attempt.VerifyPacket = New-TeamPipelineVerificationPacket -Task $Task -VerifyStatus $verifyStage.Status -VerifierLabel $targets.VerifyTarget -BuilderLabel $Builder -BuilderWorktreePath $builderContext.BuilderWorktreePath -Summary $verifyStage.Summary
        $result.VerificationPackets += $attempt.VerifyPacket
        $verifySecurityVerdict = Get-TeamPipelineValue -InputObject $verifyStage -Name 'SecurityVerdict' -Default $null
        if ($null -ne $verifySecurityVerdict) {
            $result.SecurityVerdicts += $verifySecurityVerdict
        }
        $verifyEventName = switch ($attempt.VerifyPacket.verdict) {
            'PASS' { 'pipeline.verify.pass' }
            'FAIL' { 'pipeline.verify.fail' }
            default { 'pipeline.verify.partial' }
        }
        $verifyEventData = [ordered]@{
            attempt           = $attemptIndex
            task              = $Task
            verifier          = $targets.VerifyTarget
            verdict           = $attempt.VerifyPacket.verdict
            verify_status     = $attempt.VerifyPacket.verify_status
            changed_paths     = @($attempt.VerifyPacket.changed_paths)
            evidence_refs     = @($attempt.VerifyPacket.evidence_refs)
            failing_probe     = $attempt.VerifyPacket.failing_probe
            next_action       = $attempt.VerifyPacket.next_action
            style             = $attempt.VerifyPacket.style
            verification_contract = $attempt.VerifyPacket.verification_contract
            verification_result = $attempt.VerifyPacket.verification_result
            verification_evidence = $attempt.VerifyPacket.verification_evidence
        }
        if ($verifyCostUnitDispatched) {
            $verifyEventData['cost_unit_refs'] = @([string]$verifyCostUnit.unit_id)
        }
        Write-TeamPipelineEvent -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Event $verifyEventName -Message "Verification returned $($attempt.VerifyPacket.verdict) on $($targets.VerifyTarget)." -Role $verifyRole -Target $targets.VerifyTarget -Data $verifyEventData | Out-Null
        $result.Attempts += [PSCustomObject]$attempt

        switch ($verifyStage.Status) {
            'VERIFY_PASS' {
                if (-not [string]::IsNullOrWhiteSpace($consultTarget)) {
                    $result.FinalConsult = Invoke-TeamPipelineConsultStage -Mode 'final' -Task $Task -BuilderLabel $Builder -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -TargetLabel $consultTarget -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -BuilderWorktreePath $builderContext.BuilderWorktreePath -PlanSummary $planSummary -BuildSummary $buildStage.Summary -VerificationSummary $verifyStage.Summary -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds -Attempt $attemptIndex
                }
                $result.Success = $true
                $result.FinalStatus = 'VERIFY_PASS'
                return [PSCustomObject]$result
            }
            'BLOCKED' {
                $escalationTarget = Get-TeamPipelineEscalationTarget -ConsultTarget $consultTarget
                if (-not [string]::IsNullOrWhiteSpace($consultTarget)) {
                    $attempt.StuckConsult = Invoke-TeamPipelineConsultStage -Mode 'stuck' -Task $Task -BuilderLabel $Builder -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -TargetLabel $consultTarget -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -BuilderWorktreePath $builderContext.BuilderWorktreePath -PlanSummary $planSummary -BuildSummary $buildStage.Summary -VerificationSummary $verifyStage.Summary -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds -Attempt $attemptIndex
                    if ($null -ne $attempt.StuckConsult) {
                        $result.StuckConsults += $attempt.StuckConsult
                    }
                }
                Write-TeamPipelineEvent -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Event 'pipeline.escalate.required' -Message "Claude Code operator escalation required after blocked verification attempt $attemptIndex." -Role 'Operator' -Target $escalationTarget -Data (New-TeamPipelineManagedLoopData -Task $Task -Stage 'escalate' -State 'required' -BuilderLabel $Builder -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -TargetLabel $escalationTarget -Summary $verifyStage.Summary -Reason 'VERIFY_BLOCKED' -Attempt $attemptIndex) | Out-Null
                $result.FinalStatus = 'VERIFY_BLOCKED'
                return [PSCustomObject]$result
            }
            'VERIFY_PARTIAL' {
                $escalationTarget = Get-TeamPipelineEscalationTarget -ConsultTarget $consultTarget
                Write-TeamPipelineEvent -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Event 'pipeline.escalate.required' -Message "Claude Code operator escalation required after partial verification attempt $attemptIndex." -Role 'Operator' -Target $escalationTarget -Data (New-TeamPipelineManagedLoopData -Task $Task -Stage 'escalate' -State 'required' -BuilderLabel $Builder -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -TargetLabel $escalationTarget -Summary $verifyStage.Summary -Reason 'VERIFY_PARTIAL' -Attempt $attemptIndex) | Out-Null
                $result.FinalStatus = 'VERIFY_PARTIAL'
                return [PSCustomObject]$result
            }
            'VERIFY_FAIL' {
                continue
            }
            default {
                throw "Unexpected verification status: $($verifyStage.Status)"
            }
        }
    }

    $result.FinalStatus = 'VERIFY_FAIL'
    $escalationTarget = Get-TeamPipelineEscalationTarget -ConsultTarget $consultTarget
    Write-TeamPipelineEvent -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Event 'pipeline.escalate.required' -Message 'Claude Code operator escalation required after verification fixes were exhausted.' -Role 'Operator' -Target $escalationTarget -Data (New-TeamPipelineManagedLoopData -Task $Task -Stage 'escalate' -State 'required' -BuilderLabel $Builder -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -TargetLabel $escalationTarget -Summary 'Verification failed after all fix attempts.' -Reason 'VERIFY_FAIL' -Attempt $attemptLimit) | Out-Null
    return [PSCustomObject]$result
}

function Resolve-TeamPipelineDeclarativeRuntimeLease {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $generationId = [string](Get-DeclarativeWorkflowValue $Run 'generation_id' '')
    try {
        $matches = @(Get-PaneControlManifestEntries -ProjectDir $ProjectDir | Where-Object {
                [string](Get-TeamPipelineValue $_ 'Label' '') -ceq $Label
            })
        if ($matches.Count -ne 1) { return $null }
        $paneId = [string](Get-TeamPipelineValue $matches[0] 'PaneId' '')
        if ([string]::IsNullOrWhiteSpace($paneId)) { return $null }
        $manifestEntry = Get-PaneControlManifestContext -ProjectDir $ProjectDir -PaneId $paneId
        if ([string](Get-TeamPipelineValue $manifestEntry 'Label' '') -cne $Label -or
            [string](Get-TeamPipelineValue $manifestEntry 'PaneId' '') -cne $paneId -or
            -not [string]::Equals([string](Get-TeamPipelineValue $manifestEntry 'GenerationId' ''), $generationId, [StringComparison]::Ordinal)) {
            return $null
        }
        $validation = Test-PaneControlRuntimeContext -ProjectDir $ProjectDir -ManifestEntry $manifestEntry -Operation dispatch
        if ($null -eq $validation -or -not [bool](Get-TeamPipelineValue $validation 'valid' $false)) { return $null }
        $runtime = Get-TeamPipelineValue $validation 'context' $null
        if ($null -eq $runtime -or
            [string](Get-TeamPipelineValue $runtime 'session_name' '') -cne $SessionName -or
            -not [string]::Equals([string](Get-TeamPipelineValue $runtime 'generation_id' ''), $generationId, [StringComparison]::Ordinal) -or
            [string](Get-TeamPipelineValue $runtime 'pane_id' '') -cne $paneId -or
            [string](Get-TeamPipelineValue $runtime 'label' '') -cne $Label) {
            return $null
        }
        return [PSCustomObject]@{ manifest_entry = $manifestEntry; runtime = $runtime; pane_id = $paneId; label = $Label }
    } catch {
        return $null
    }
}

function Invoke-TeamPipelineWorkspacePlanOnce {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RecipeId,
        [Parameter(Mandatory = $true)][string]$WorkflowId,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $result = Invoke-TeamPipelineBridge -Arguments @(
        'workspace-plan', '--recipe-id', $RecipeId, '--workflow-id', $WorkflowId,
        '--run-id', $RunId, '--project-dir', $ProjectDir, '--json'
    ) -AllowFailure
    if ($result.ExitCode -ne 0) { throw 'workspace_plan_rejected' }
    $text = [string]$result.Output
    if ([string]::IsNullOrWhiteSpace($text) -or -not $text.Trim().StartsWith('{') -or -not $text.Trim().EndsWith('}')) {
        throw 'workspace_plan_invalid_json'
    }
    try {
        $plan = $text | ConvertFrom-WinsmuxJson -AsHashtable -Depth 100 -ErrorAction Stop
    } catch {
        throw 'workspace_plan_invalid_json'
    }
    if ($plan -isnot [Collections.IDictionary] -or $null -eq (Get-DeclarativeWorkflowValue $plan 'workflow' $null)) {
        throw 'workspace_plan_missing_workflow'
    }
    return $plan
}

function ConvertTo-TeamPipelineDeclarativeWorkflowPlan {
    param([Parameter(Mandatory = $true)]$WorkspacePlan)

    $rawWorkflow = Get-DeclarativeWorkflowValue $WorkspacePlan 'workflow' $null
    if ($null -eq $rawWorkflow) { throw 'workspace_plan_missing_workflow' }
    $workflowPlan = Copy-DeclarativeWorkflowValue $rawWorkflow
    if ($workflowPlan -isnot [Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($property in @($workflowPlan.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') })) {
            $copy[[string]$property.Name] = $property.Value
        }
        $workflowPlan = $copy
    }

    $workflowPlan['resolved_bindings'] = Copy-DeclarativeWorkflowValue (Get-DeclarativeWorkflowValue $WorkspacePlan 'resolved_bindings' ([ordered]@{}))
    return $workflowPlan
}

function Assert-TeamPipelineDeclarativeAdmission {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$Confirmation,
        [Parameter(Mandatory = $true)]$TaskInput,
        [Parameter(Mandatory = $true)]$WorkspacePlan,
        [Parameter(Mandatory = $true)][string]$ManifestGenerationId,
        [Parameter(Mandatory = $true)][string]$ObservedSourceHead,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    Assert-DeclarativeWorkflowTaskIdentity -Run $Run -TaskInput $TaskInput
    Assert-DeclarativeWorkflowConfirmation -Run $Run -Confirmation $Confirmation
    if (-not [string]::Equals([string](Get-DeclarativeWorkflowValue $Run 'generation_id' ''), $ManifestGenerationId, [StringComparison]::Ordinal)) {
        throw 'workflow_manifest_generation_mismatch'
    }
    Assert-TeamPipelineDeclarativeSourceHead -ExpectedSourceHead ([string](Get-DeclarativeWorkflowValue $Run 'source_head' '')) -ObservedSourceHead $ObservedSourceHead
    $freshConfigFingerprint = [string](Get-DeclarativeWorkflowValue $WorkspacePlan 'config_fingerprint' '')
    if (-not [string]::Equals([string](Get-DeclarativeWorkflowValue $Run 'config_fingerprint' ''), $freshConfigFingerprint, [StringComparison]::Ordinal)) {
        throw 'workflow_fresh_config_mismatch'
    }
    $freshWorkflowPlan = ConvertTo-TeamPipelineDeclarativeWorkflowPlan -WorkspacePlan $WorkspacePlan
    Assert-DeclarativeWorkflowExecutionProjection -Run $Run -Plan $freshWorkflowPlan
    $bindings = Get-DeclarativeWorkflowValue $Run 'resolved_bindings' $null
    if ($null -eq $bindings -or $bindings -isnot [Collections.IDictionary] -or $bindings.Count -lt 1) {
        throw 'workflow_live_binding_unavailable'
    }
    $validatedLabels = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $bindings.GetEnumerator()) {
        $label = [string]$entry.Value
        if ([string]::IsNullOrWhiteSpace($label)) { throw 'workflow_live_binding_unavailable' }
        if (-not $validatedLabels.Add($label)) { continue }
        $lease = Resolve-TeamPipelineDeclarativeRuntimeLease -ProjectDir $ProjectDir -Run $Run -SessionName $SessionName -Label $label
        if ($null -eq $lease) { throw 'workflow_live_binding_unavailable' }
    }
}

function Assert-TeamPipelineDeclarativeRunLockAdmission {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Run
    )

    if (Test-DeclarativeWorkflowRunningCleanupRecovery -Run $Run) {
        try { return Resolve-DeclarativeWorkflowOwnedLock -ProjectDir $ProjectDir -Run $Run } catch { return $null }
    }
    $lockPath = Resolve-DeclarativeWorkflowOwnedLock -ProjectDir $ProjectDir -Run $Run
    if ([IO.File]::Exists($lockPath)) {
        if (-not (Test-DeclarativeWorkflowRunLockOwnership -ProjectDir $ProjectDir -Run $Run)) {
            throw 'workflow_run_lock_mismatch'
        }
        return $lockPath
    }
    if (-not (Test-DeclarativeWorkflowPristineBootstrap -Run $Run)) {
        throw 'workflow_run_lock_missing_after_effect'
    }

    $createdPath = New-DeclarativeWorkflowRunLock -ProjectDir $ProjectDir -Run $Run
    if (-not (Test-DeclarativeWorkflowRunLockOwnership -ProjectDir $ProjectDir -Run $Run)) {
        throw 'workflow_run_lock_create_unverified'
    }
    return $createdPath
}

function Get-TeamPipelineDeclarativeSessionId {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [Parameter(Mandatory = $true)][string]$PaneId
    )
    if ([string]::IsNullOrWhiteSpace($PaneId)) { return '' }
    $registry = Read-WinsmuxRuntimeRegistry -ProjectDir $ProjectDir
    if ($null -eq $registry -or
        [string](Get-WinsmuxRuntimeValue $registry 'status' '') -cne 'active' -or
        -not [string]::Equals([string](Get-WinsmuxRuntimeValue $registry 'generation_id' ''), $GenerationId, [StringComparison]::Ordinal)) {
        return ''
    }
    $matches = @(@(Get-WinsmuxRuntimeValue $registry 'panes' @()) | Where-Object {
        [string](Get-WinsmuxRuntimeValue $_ 'pane_id' '') -ceq $PaneId -and
        [string]::Equals([string](Get-WinsmuxRuntimeValue $_ 'generation_id' $GenerationId), $GenerationId, [StringComparison]::Ordinal)
    })
    if ($matches.Count -ne 1) { return '' }
    return $PaneId
}

function New-TeamPipelineDeclarativeAcknowledgement {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [Parameter(Mandatory = $true)][string]$PaneId
    )
    $node = Get-DeclarativeWorkflowNode -Run $Run -NodeId $NodeId
    $runId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
    return [ordered]@{
        schema_version     = 1
        run_id             = $runId
        node_id            = $NodeId
        idempotency_key    = [string](Get-DeclarativeWorkflowValue $node 'idempotency_key' '')
        generation_id      = [string](Get-DeclarativeWorkflowValue $Run 'generation_id' '')
        config_fingerprint = [string](Get-DeclarativeWorkflowValue $Run 'config_fingerprint' '')
        workflow_fingerprint = [string](Get-DeclarativeWorkflowValue $Run 'workflow_fingerprint' '')
        source_head        = [string](Get-DeclarativeWorkflowValue $Run 'source_head' '')
        pane_id            = $PaneId
        status             = 'succeeded'
        evidence_ref       = "workflow-ack:$runId`:$NodeId"
    }
}

function Get-TeamPipelineDeclarativeProjectHead {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $output = @(& git -C $ProjectDir rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
        throw 'Declarative workflow source head could not be observed exactly once.'
    }
    $head = ([string]$output[0]).Trim()
    if ($head -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Declarative workflow source head is malformed.'
    }
    return $head
}

function Assert-TeamPipelineDeclarativeSourceHead {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedSourceHead,
        [Parameter(Mandatory = $true)][string]$ObservedSourceHead
    )

    if ($ExpectedSourceHead -cnotmatch '^[0-9a-f]{40}$' -or $ObservedSourceHead -cnotmatch '^[0-9a-f]{40}$' -or
        $ExpectedSourceHead -cne $ObservedSourceHead) {
        throw 'Declarative workflow confirmation source head does not match the actual project source head.'
    }
}

function New-TeamPipelineDeclarativeCompletionInstruction {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $acknowledgement = New-TeamPipelineDeclarativeAcknowledgement -Run $Run -NodeId $NodeId -PaneId $PaneId
    $canonical = $acknowledgement | ConvertTo-Json -Compress -Depth 8
    $digest = Get-DeclarativeWorkflowSha256Digest -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($canonical))
    $suffix = $digest.Substring(('sha256:').Length, 24)
    $safeSession = [regex]::Replace($SessionName, '[^A-Za-z0-9_-]', '-')
    $envelope = [ordered]@{
        mailbox_version = 2
        message_id      = "workflow-ack-$suffix"
        correlation_id  = "workflow-ack-$suffix"
        causation_id    = $null
        idempotency_key = "workflow-completion-$suffix"
        message_type    = 'workflow-completion'
        state           = 'created'
        ttl_seconds     = 300
        ack_required    = $true
        from            = $Target
        to              = 'Operator'
        # The durable publisher owns freshness. A dispatch-time timestamp would
        # consume the TTL while the worker is still doing the requested work.
        timestamp       = $null
        content         = [ordered]@{
            session     = $SessionName
            event       = 'workflow.node.acknowledged'
            message     = 'Declarative workflow completion.'
            label       = $Target
            pane_id     = $PaneId
            role        = $Role
            status      = 'succeeded'
            exit_reason = ''
            data        = $acknowledgement
        }
    }
    $payload = $envelope | ConvertTo-Json -Compress -Depth 12
    $quotedChannel = "'$($safeSession + '-operator')'"
    $escapedPayload = $payload.Replace("'", "''")
    $quotedPayload = "'" + $escapedPayload + "'"
    return @"

Completion evidence is not inferred from pane text. After the requested work and checks actually finish, run this exact command once, then report your normal summary:

winsmux mailbox-send $quotedChannel $quotedPayload

Do not send the command before the work is complete. `STATUS: EXEC_DONE` and `VERIFY_PASS` alone do not complete this workflow node.
"@
}

function Resolve-TeamPipelineDeclarativeAcknowledgement {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName
    )
    $proof = Read-DeclarativeWorkflowDurableProof -ProjectDir $ProjectDir -Run $Run -Kind Completion -NodeId $NodeId
    if ($null -eq $proof) { return @() }
    return Resolve-DeclarativeWorkflowAcknowledgementCandidates -Run $Run -NodeId $NodeId -Acknowledgements @($proof)
}

function Resolve-TeamPipelineDeclarativeCancellation {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName
    )
    $proof = Read-DeclarativeWorkflowDurableProof -ProjectDir $ProjectDir -Run $Run -Kind Cancellation
    if ($null -eq $proof) { return @() }
    return @($proof)
}

function Wait-TeamPipelineDeclarativeCompletion {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [int]$PollIntervalSeconds = 10,
        [int]$TimeoutSeconds = 240
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $candidates = @(Resolve-TeamPipelineDeclarativeAcknowledgement -Run $Run -NodeId $NodeId -ProjectDir $ProjectDir -SessionName $SessionName)
        if ($candidates.Count -gt 1) { return $null }
        if ($candidates.Count -eq 1) {
            $acknowledgement = $candidates[0]
            if (
                [string](Get-DeclarativeWorkflowValue $acknowledgement 'transport' '') -ceq 'mailbox' -and
                [string](Get-DeclarativeWorkflowValue $acknowledgement 'pane_id' '') -ceq $PaneId -and
                (Test-DeclarativeWorkflowAcknowledgement -Run $Run -NodeId $NodeId -Acknowledgement $acknowledgement)
            ) {
                return $acknowledgement
            }
            return $null
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds ([Math]::Max(1, $PollIntervalSeconds))
    } while ($true)
    return $null
}

function Resolve-TeamPipelineDeclarativeVerificationContext {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $contextPackRef = [string](Get-DeclarativeWorkflowValue $Request 'context_pack_ref' '')
    $dependencyNodeIds = @((Get-DeclarativeWorkflowValue $Request 'dependency_node_ids' @()) | ForEach-Object { [string]$_ })
    $requestedEvidenceRefs = @((Get-DeclarativeWorkflowValue $Request 'evidence_refs' @()) | ForEach-Object { [string]$_ })
    if (-not (Test-DeclarativeWorkflowBoundedReference -Value $contextPackRef) -or $dependencyNodeIds.Count -lt 1) { return $null }

    $nodes = Get-DeclarativeWorkflowValue $Run 'nodes' $null
    $bindings = Get-DeclarativeWorkflowValue $Run 'resolved_bindings' $null
    $verificationNodeId = [string](Get-DeclarativeWorkflowValue $Request 'node_id' '')
    if ($null -eq $nodes -or $null -eq $bindings -or -not $nodes.Contains($verificationNodeId)) { return $null }
    $verificationNode = $nodes[$verificationNodeId]
    if ([string](Get-DeclarativeWorkflowValue $verificationNode 'action' '') -cne 'verification' -or
        [string](Get-DeclarativeWorkflowValue $verificationNode 'context_pack_ref' '') -cne $contextPackRef) {
        return $null
    }
    $persistedDependencyNodeIds = @((Get-DeclarativeWorkflowValue $verificationNode 'depends_on' @()) | ForEach-Object { [string]$_ })
    if ($persistedDependencyNodeIds.Count -ne $dependencyNodeIds.Count) { return $null }
    for ($index = 0; $index -lt $dependencyNodeIds.Count; $index++) {
        if ($dependencyNodeIds[$index] -cne $persistedDependencyNodeIds[$index]) { return $null }
    }

    $runId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
    $expectedEvidenceRefs = [Collections.Generic.List[string]]::new()
    $producerContexts = [Collections.Generic.List[object]]::new()
    $seenDependencyIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($dependencyNodeId in $dependencyNodeIds) {
        if ([string]::IsNullOrWhiteSpace($dependencyNodeId) -or -not $seenDependencyIds.Add($dependencyNodeId) -or -not $nodes.Contains($dependencyNodeId)) {
            return $null
        }
        $dependencyNode = $nodes[$dependencyNodeId]
        if ([string](Get-DeclarativeWorkflowValue $dependencyNode 'state' '') -cne 'succeeded') { return $null }
        $producerPaneRef = [string](Get-DeclarativeWorkflowValue $dependencyNode 'pane_ref' '')
        if ([string]::IsNullOrWhiteSpace($producerPaneRef) -or -not $bindings.Contains($producerPaneRef)) { return $null }
        $producerLabel = [string]$bindings[$producerPaneRef]
        $producerPane = Get-TeamPipelinePaneInfo -Manifest $Manifest -Label $producerLabel
        if ($null -eq $producerPane) { return $null }
        $producerWorktree = ''
        foreach ($candidateKey in @('builder_worktree_path', 'launch_dir')) {
            $candidatePath = [string](Get-TeamPipelineValue -InputObject $producerPane -Name $candidateKey -Default '')
            if (-not [string]::IsNullOrWhiteSpace($candidatePath)) {
                $producerWorktree = $candidatePath
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($producerLabel) -or [string]::IsNullOrWhiteSpace($producerWorktree) -or
            [string]::IsNullOrWhiteSpace([string](Get-TeamPipelineValue -InputObject $producerPane -Name 'pane_id' -Default ''))) {
            return $null
        }
        $producerContexts.Add([PSCustomObject]@{ label = $producerLabel; worktree = $producerWorktree }) | Out-Null

        $expectedEvidenceRef = "workflow-ack:$runId`:$dependencyNodeId"
        $dependencyEvidenceRefs = @((Get-DeclarativeWorkflowValue $dependencyNode 'evidence_refs' @()) | ForEach-Object { [string]$_ })
        if ($dependencyEvidenceRefs.Count -lt 1) { return $null }
        foreach ($evidenceRef in $dependencyEvidenceRefs) {
            if ($evidenceRef -cne $expectedEvidenceRef) { return $null }
            $expectedEvidenceRefs.Add($evidenceRef) | Out-Null
        }
    }

    if ($requestedEvidenceRefs.Count -ne $expectedEvidenceRefs.Count) { return $null }
    for ($index = 0; $index -lt $expectedEvidenceRefs.Count; $index++) {
        if ($requestedEvidenceRefs[$index] -cne $expectedEvidenceRefs[$index]) { return $null }
    }

    $producer = $producerContexts[0]
    foreach ($candidateProducer in @($producerContexts | Select-Object -Skip 1)) {
        if ([string]$candidateProducer.label -cne [string]$producer.label -or
            [string]$candidateProducer.worktree -cne [string]$producer.worktree) {
            return $null
        }
    }
    return [PSCustomObject]@{
        builder_label = [string]$producer.label
        builder_worktree_path = [string]$producer.worktree
        context_pack_ref = $contextPackRef
        dependency_node_ids = @($dependencyNodeIds)
        evidence_refs = @($expectedEvidenceRefs)
    }
}

function Invoke-TeamPipelineDeclarativeDispatch {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [int]$PollIntervalSeconds = 10,
        [int]$StageTimeoutSeconds = 240
    )
    $bindings = Get-DeclarativeWorkflowValue $Run 'resolved_bindings' $null
    $paneRef = [string](Get-DeclarativeWorkflowValue $Request 'pane_ref' '')
    if ($null -eq $bindings -or -not $bindings.Contains($paneRef)) { return $null }
    $target = [string]$bindings[$paneRef]
    $runtimeLease = Resolve-TeamPipelineDeclarativeRuntimeLease -ProjectDir $ProjectDir -Run $Run -SessionName $SessionName -Label $target
    if ($null -eq $runtimeLease) { return $null }
    $pane = $runtimeLease.manifest_entry
    $paneId = [string]$runtimeLease.pane_id
    $generationId = [string](Get-DeclarativeWorkflowValue $Run 'generation_id' '')
    $stage = [string](Get-DeclarativeWorkflowValue $Request 'stage' '')
    $taskText = [string](Get-DeclarativeWorkflowValue $Request 'task' '')
    $nodeId = [string](Get-DeclarativeWorkflowValue $Request 'node_id' '')
    $runId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
    $eventTaskRef = "workflow:$runId`:$nodeId"
    $role = [string](Get-TeamPipelineValue $pane 'role' 'Worker')
    if ([string]::IsNullOrWhiteSpace($role)) { $role = 'Worker' }
    $verificationContext = $null
    if ($stage -ceq 'VERIFY') {
        $verificationContext = Resolve-TeamPipelineDeclarativeVerificationContext -Request $Request -Run $Run -Manifest $Manifest
        if ($null -eq $verificationContext) { return $null }
    }
    $completionInstruction = New-TeamPipelineDeclarativeCompletionInstruction -Run $Run -NodeId $nodeId -SessionName $SessionName -Target $target -PaneId $paneId -Role $role
    $prompt = if ($stage -ceq 'VERIFY') {
        New-TeamPipelineVerifyPrompt -Task $taskText -BuilderLabel $verificationContext.builder_label -BuilderWorktreePath $verificationContext.builder_worktree_path -PlanSummary '' `
            -BuilderCompletionMessage 'Dependencies completed with durable acknowledgement evidence.' -ContextPackRef $verificationContext.context_pack_ref `
            -DependencyNodeIds $verificationContext.dependency_node_ids -DependencyEvidenceRefs $verificationContext.evidence_refs
    } else {
        New-TeamPipelineExecPrompt -Task $taskText -PlanSummary ''
    }
    $prompt = $prompt + $completionInstruction
    $dispatchResult = Invoke-TeamPipelineGuardedSend -StageName $stage -Target $paneId -Prompt $prompt -ProjectDir $ProjectDir -SessionName $SessionName -Role 'Worker' -Task $eventTaskRef -Attempt 1 -ExpectedGenerationId $generationId -RedactEventPayload
    $status = [string](Get-TeamPipelineValue $dispatchResult 'Status' '')
    if ($status -ceq 'BLOCKED') {
        return [PSCustomObject]@{ status = 'blocked'; target = [PSCustomObject]@{ label = $target; pane_id = $paneId }; evidence_refs = @() }
    }
    $acknowledgement = Wait-TeamPipelineDeclarativeCompletion -Run $Run -NodeId $nodeId -ProjectDir $ProjectDir -SessionName $SessionName -PaneId $paneId -PollIntervalSeconds $PollIntervalSeconds -TimeoutSeconds $StageTimeoutSeconds
    if ($null -ne $acknowledgement) {
        return [PSCustomObject]@{
            status          = 'accepted'
            target          = [PSCustomObject]@{ label = $target; pane_id = $paneId }
            evidence_refs   = @([string]$acknowledgement.evidence_ref)
            acknowledgement = $acknowledgement
        }
    }
    return [PSCustomObject]@{
        status = 'blocked'
        target = [PSCustomObject]@{ label = $target; pane_id = $paneId }
        evidence_refs = @()
    }
}

function Invoke-TeamPipelineDeclarativeRunAdvancement {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$TaskInput,
        [Parameter(Mandatory = $true)]$Confirmation,
        [Parameter(Mandatory = $true)][scriptblock]$SaveRun,
        [Parameter(Mandatory = $true)][scriptblock]$Dispatch,
        [Parameter(Mandatory = $true)][scriptblock]$ResolveSession,
        [Parameter(Mandatory = $true)][scriptblock]$ResolveAcknowledgement,
        [scriptblock]$ResolveCancellation,
        [Parameter(Mandatory = $true)][scriptblock]$ReleaseLock,
        [scriptblock]$ValidateSnapshot,
        [switch]$SnapshotValidated
    )

    $durableProofs = Resolve-DeclarativeWorkflowDurableProofs -Run $Run -ResolveAcknowledgement $ResolveAcknowledgement -ResolveCancellation $ResolveCancellation
    $Run = Invoke-DeclarativeWorkflowTransition -Run $Run -Event ([ordered]@{ type = 'validate' }) -DurableProofs $durableProofs
    $initialState = [string](Get-DeclarativeWorkflowValue $Run 'state' '')
    if ($initialState -in @('succeeded', 'failed', 'cancelled')) {
        throw "Declarative workflow terminal run '$initialState' requires terminal cleanup recovery."
    }

    $resumeSnapshotValidator = if ($SnapshotValidated) { $null } else { $ValidateSnapshot }
    $advanced = Invoke-DeclarativeWorkflowResume -Run $Run -TaskInput $TaskInput -Confirmation $Confirmation `
        -SaveRun $SaveRun -Dispatch $Dispatch -ResolveSession $ResolveSession `
        -ResolveAcknowledgement $ResolveAcknowledgement -ResolveCancellation $ResolveCancellation -ValidateSnapshot $resumeSnapshotValidator

    if ([string](Get-DeclarativeWorkflowValue $advanced 'state' '') -in @('succeeded', 'failed', 'cancelled')) {
        return Invoke-DeclarativeWorkflowTerminalCleanup -ProjectDir $ProjectDir -Run $advanced -SaveRun $SaveRun -ReleaseLock $ReleaseLock `
            -ResolveAcknowledgement $ResolveAcknowledgement -ResolveCancellation $ResolveCancellation
    }

    return $advanced
}

function Invoke-TeamPipelineDeclarativeTerminalRecovery {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$TaskInput,
        [Parameter(Mandatory = $true)]$Confirmation,
        [Parameter(Mandatory = $true)][scriptblock]$SaveRun,
        [Parameter(Mandatory = $true)][scriptblock]$ReleaseLock,
        [scriptblock]$ResolveAcknowledgement,
        [scriptblock]$ResolveCancellation,
        [scriptblock]$ValidateSnapshot,
        [switch]$SnapshotValidated
    )

    Assert-DeclarativeWorkflowTaskIdentity -Run $Run -TaskInput $TaskInput
    Assert-DeclarativeWorkflowConfirmation -Run $Run -Confirmation $Confirmation
    $durableProofs = Resolve-DeclarativeWorkflowDurableProofs -Run $Run -ResolveAcknowledgement $ResolveAcknowledgement -ResolveCancellation $ResolveCancellation
    $Run = Invoke-DeclarativeWorkflowTransition -Run $Run -Event ([ordered]@{ type = 'validate' }) -DurableProofs $durableProofs
    if (-not $SnapshotValidated -and $null -ne $ValidateSnapshot) { & $ValidateSnapshot $Run }

    $terminalState = [string](Get-DeclarativeWorkflowValue $Run 'state' '')
    if ($terminalState -notin @('succeeded', 'failed', 'cancelled')) {
        throw "Declarative workflow terminal recovery requires a terminal run, not '$terminalState'."
    }

    Get-DeclarativeWorkflowCleanupActionState -Run $Run -AllowedStates @('pending', 'running') | Out-Null

    return Invoke-DeclarativeWorkflowTerminalCleanup -ProjectDir $ProjectDir -Run $Run -SaveRun $SaveRun -ReleaseLock $ReleaseLock `
        -ResolveAcknowledgement $ResolveAcknowledgement -ResolveCancellation $ResolveCancellation
}

function Invoke-TeamPipelineDeclarativeWorkflow {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('start', 'resume')][string]$Action,
        [string]$RecipeId,
        [string]$WorkflowId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [Parameter(Mandatory = $true)][string]$ConfigFingerprint,
        [Parameter(Mandatory = $true)][string]$SourceHead,
        [Parameter(Mandatory = $true)][string]$TaskFile,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [int]$PollIntervalSeconds = 10,
        [int]$StageTimeoutSeconds = 240
    )
    $taskInput = Read-DeclarativeWorkflowTaskFile -Path $TaskFile
    $observedSourceHead = Get-TeamPipelineDeclarativeProjectHead -ProjectDir $ProjectDir
    Assert-TeamPipelineDeclarativeSourceHead -ExpectedSourceHead $SourceHead -ObservedSourceHead $observedSourceHead
    $confirmation = [ordered]@{ run_id = $RunId; generation_id = $GenerationId; config_fingerprint = $ConfigFingerprint; source_head = $SourceHead }
    $manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
    $manifest = Read-TeamPipelineManifest -Path $manifestPath
    if ($null -eq $manifest) { throw 'workflow_manifest_unavailable' }
    $manifestSession = Get-TeamPipelineValue -InputObject $manifest -Name 'session' -Default $null
    $manifestSessionName = [string](Get-TeamPipelineValue -InputObject $manifestSession -Name 'name' -Default '')
    $manifestGenerationId = [string](Get-TeamPipelineValue -InputObject $manifestSession -Name 'generation_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($manifestSessionName)) { throw 'workflow_manifest_session_identity_unavailable' }
    $sessionName = Get-TeamPipelineSessionName -Manifest $manifest
    if ([string]::IsNullOrWhiteSpace($sessionName) -or
        -not [string]::Equals($sessionName, $manifestSessionName, [StringComparison]::Ordinal)) {
        throw 'workflow_manifest_session_identity_unavailable'
    }
    if ([string]::IsNullOrWhiteSpace($manifestGenerationId) -or
        -not [string]::Equals($manifestGenerationId, $GenerationId, [StringComparison]::Ordinal)) {
        throw 'workflow_manifest_generation_mismatch'
    }
    $invocationLease = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $ProjectDir -RunId $RunId
    try {
        if ($Action -ceq 'start') {
            $statePath = Resolve-DeclarativeWorkflowOwnedRunPath -ProjectDir $ProjectDir -RunId $RunId -LeafName 'state.json'
            if ([IO.File]::Exists($statePath)) { throw 'workflow_run_already_exists' }
            $workspacePlan = Invoke-TeamPipelineWorkspacePlanOnce -ProjectDir $ProjectDir -RecipeId $RecipeId -WorkflowId $WorkflowId -RunId $RunId
            $workflowPlan = ConvertTo-TeamPipelineDeclarativeWorkflowPlan -WorkspacePlan $workspacePlan
            $run = New-DeclarativeWorkflowRun -Plan $workflowPlan -RunId $RunId -GenerationId $GenerationId -ConfigFingerprint $ConfigFingerprint -SourceHead $SourceHead -TaskInput $taskInput
            Assert-TeamPipelineDeclarativeAdmission -Run $run -Confirmation $confirmation -TaskInput $taskInput -WorkspacePlan $workspacePlan `
                -ManifestGenerationId $manifestGenerationId -ObservedSourceHead $observedSourceHead -ProjectDir $ProjectDir -SessionName $sessionName
            try {
                Save-DeclarativeWorkflowRunState -ProjectDir $ProjectDir -Run $run -CreateNew | Out-Null
            } catch {
                throw
            }
            try {
                New-DeclarativeWorkflowRunLock -ProjectDir $ProjectDir -Run $run | Out-Null
            } catch {
                $lockCreateError = $_
                try {
                    Remove-DeclarativeWorkflowPristineRunState -ProjectDir $ProjectDir -Run $run
                } catch {
                    throw "workflow_lock_create_failed_state_rollback_blocked: $([string]$lockCreateError.Exception.Message); $([string]$_.Exception.Message)"
                }
                throw $lockCreateError
            }
        } else {
            $run = Read-DeclarativeWorkflowRunState -ProjectDir $ProjectDir -RunId $RunId
        }
        $save = { param($candidate) Save-DeclarativeWorkflowRunState -ProjectDir $ProjectDir -Run $candidate | Out-Null }
        $dispatch = { param($request, $candidateRun) Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $candidateRun -Manifest $manifest -ProjectDir $ProjectDir -SessionName $sessionName -PollIntervalSeconds $PollIntervalSeconds -StageTimeoutSeconds $StageTimeoutSeconds }
        $resolveSession = { param($paneId) Get-TeamPipelineDeclarativeSessionId -ProjectDir $ProjectDir -GenerationId $GenerationId -PaneId $paneId }
        $releaseLock = { param($path) Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        $resolveAcknowledgement = { param($candidateRun, $nodeId) Resolve-TeamPipelineDeclarativeAcknowledgement -Run $candidateRun -NodeId $nodeId -ProjectDir $ProjectDir -SessionName $sessionName }
        $resolveCancellation = { param($candidateRun) Resolve-TeamPipelineDeclarativeCancellation -Run $candidateRun -ProjectDir $ProjectDir -SessionName $sessionName }
        $validateSnapshot = $null
        $snapshotValidated = $false
        if ($Action -ceq 'resume') {
            $durableProofs = Resolve-DeclarativeWorkflowDurableProofs -Run $run -ResolveAcknowledgement $resolveAcknowledgement -ResolveCancellation $resolveCancellation
            $run = Invoke-DeclarativeWorkflowTransition -Run $run -Event ([ordered]@{ type = 'validate' }) -DurableProofs $durableProofs
            $workspacePlan = Invoke-TeamPipelineWorkspacePlanOnce -ProjectDir $ProjectDir -RecipeId ([string]$run.recipe_ref) -WorkflowId ([string]$run.workflow_id) -RunId $RunId
            Assert-TeamPipelineDeclarativeAdmission -Run $run -Confirmation $confirmation -TaskInput $taskInput -WorkspacePlan $workspacePlan `
                -ManifestGenerationId $manifestGenerationId -ObservedSourceHead $observedSourceHead -ProjectDir $ProjectDir -SessionName $sessionName
            Assert-TeamPipelineDeclarativeRunLockAdmission -ProjectDir $ProjectDir -Run $run | Out-Null
            $snapshotValidated = $true
            if ([string]$run.state -in @('succeeded', 'failed', 'cancelled')) {
                $run = Invoke-TeamPipelineDeclarativeTerminalRecovery -ProjectDir $ProjectDir -Run $run -TaskInput $taskInput -Confirmation $confirmation `
                    -SaveRun $save -ReleaseLock $releaseLock -ResolveAcknowledgement $resolveAcknowledgement -ResolveCancellation $resolveCancellation -ValidateSnapshot $validateSnapshot -SnapshotValidated
            } elseif ([string]$run.state -ceq 'cleanup_pending') {
                Get-DeclarativeWorkflowCleanupActionState -Run $run -AllowedStates @('running') | Out-Null
                $run = Invoke-DeclarativeWorkflowCleanup -ProjectDir $ProjectDir -Run $run -SaveRun $save -ReleaseLock $releaseLock `
                    -ResolveAcknowledgement $resolveAcknowledgement -ResolveCancellation $resolveCancellation
            }
        }
        if ($Action -ceq 'start' -or [string]$run.state -notin @('succeeded', 'failed', 'cancelled')) {
            $advanceArguments = [ordered]@{
                ProjectDir             = $ProjectDir
                Run                    = $run
                TaskInput              = $taskInput
                Confirmation           = $confirmation
                SaveRun                = $save
                Dispatch               = $dispatch
                ResolveSession         = $resolveSession
                ResolveAcknowledgement = $resolveAcknowledgement
                ResolveCancellation    = $resolveCancellation
                ReleaseLock            = $releaseLock
            }
            if ($Action -ceq 'resume') {
                $advanceArguments['ValidateSnapshot'] = $validateSnapshot
                $advanceArguments['SnapshotValidated'] = $snapshotValidated
            }
            $run = Invoke-TeamPipelineDeclarativeRunAdvancement @advanceArguments
        }
        $cleanupBlocked = @((Get-DeclarativeWorkflowValue $run 'cleanup_journal' @()) | Where-Object {
                [string](Get-DeclarativeWorkflowValue $_ 'state' '') -ceq 'blocked'
            }).Count -gt 0
        $status = if ($cleanupBlocked) {
            'blocked'
        } else {
            switch ([string]$run.state) { 'blocked' { 'blocked' }; 'failed' { 'failed' }; default { 'accepted' } }
        }
        return [PSCustomObject][ordered]@{ schema_version = 1; status = $status; run_id = $RunId; state = [string]$run.state }
    } finally {
        $invocationLease.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not [string]::IsNullOrWhiteSpace($WorkflowAction)) {
        try {
            $pipelineResult = Invoke-TeamPipelineDeclarativeWorkflow -Action $WorkflowAction -RecipeId $RecipeId -WorkflowId $WorkflowId -RunId $RunId -GenerationId $GenerationId -ConfigFingerprint $ConfigFingerprint -SourceHead $SourceHead -TaskFile $TaskFile -ProjectDir $ProjectDir -PollIntervalSeconds $PollIntervalSeconds -StageTimeoutSeconds $StageTimeoutSeconds
        } catch {
            $pipelineResult = [PSCustomObject][ordered]@{ schema_version = 1; status = 'rejected'; reason = [string]$_.Exception.Message }
        }
    } else {
        $pipelineResult = Invoke-TeamPipeline -Task $Task -Builder $Builder -Researcher $Researcher -Reviewer $Reviewer -ManifestPath $ManifestPath -BuilderWorktreePath $BuilderWorktreePath -PollIntervalSeconds $PollIntervalSeconds -StageTimeoutSeconds $StageTimeoutSeconds -MaxFixRounds $MaxFixRounds -SkipPlan:$SkipPlan -SkipVerify:$SkipVerify
    }
    if ($AsJson) {
        $pipelineResult | ConvertTo-Json -Depth 8
    } else {
        $pipelineResult
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkflowAction) -and [string]$pipelineResult.status -cne 'accepted') { exit 1 }
}
