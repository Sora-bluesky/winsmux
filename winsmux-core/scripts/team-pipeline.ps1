[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Task,
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
$script:TeamPipelineDangerousApprovalPattern = '(?im)(rm\s+-rf|Remove-Item\s+.+-Recurse.+-Force|git\s+push\s+--force|git\s+reset\s+--hard|DROP\s+TABLE|DELETE\s+FROM)'

. (Join-Path $PSScriptRoot 'manifest.ps1')
if (Test-Path $script:TeamPipelineLoggerScript -PathType Leaf) {
    . $script:TeamPipelineLoggerScript
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
    if (-not $SkipVerify) {
        if (-not [string]::IsNullOrWhiteSpace($ReviewerLabel)) {
            $verifyTarget = $ReviewerLabel
        } elseif (-not [string]::IsNullOrWhiteSpace($ResearcherLabel)) {
            $verifyTarget = $ResearcherLabel
        } else {
            $verifyTarget = $BuilderLabel
        }
    }

    return [PSCustomObject]@{
        PlanTarget   = $planTarget
        BuildTarget  = $BuilderLabel
        VerifyTarget = $verifyTarget
    }
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

function Wait-TeamPipelineStage {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$StageName,
        [int]$TimeoutSeconds = 240,
        [int]$PollIntervalSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastOutput = ''

    while ((Get-Date) -lt $deadline) {
        $readResult = Invoke-TeamPipelineBridge -Arguments @('read', $Target, '120')
        $lastOutput = $readResult.Output

        $status = Get-TeamPipelineStatusFromOutput -Text $lastOutput
        if ($null -ne $status) {
            return [PSCustomObject]@{
                Stage      = $StageName
                Target     = $Target
                Status     = $status
                Summary    = Get-TeamPipelineSummaryFromOutput -Text $lastOutput
                Transcript = $lastOutput
            }
        }

        $approvalAction = Get-TeamPipelineApprovalAction -Text $lastOutput
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
        [string]$BuilderCompletionMessage
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

    return @"
Verify the latest builder result without editing code.

This review was auto-dispatched after the builder reported completion.

Task:
$Task

Builder label: $BuilderLabel
Builder worktree: $BuilderWorktreePath

Builder completion notification:
$completionBlock

Plan guidance:
$planBlock

Please inspect the builder workspace, review the current diff, and run focused verification where useful.
If fixes are needed, provide concrete findings the builder can act on.

End with exactly one line:
STATUS: VERIFY_PASS

If changes need fixes, end with:
STATUS: VERIFY_FAIL

If blocked, end with:
STATUS: BLOCKED
"@
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
    $targets = Get-TeamPipelineStageTargets -BuilderLabel $Builder -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -SkipPlan:$SkipPlan -SkipVerify:$SkipVerify

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
        Attempts            = @()
        Success             = $false
        FinalStatus         = 'NOT_STARTED'
    }

    $planSummary = ''
    if (-not [string]::IsNullOrWhiteSpace($targets.PlanTarget)) {
        $planPrompt = New-TeamPipelinePlanPrompt -Task $Task
        Invoke-TeamPipelineBridge -Arguments @('send', $targets.PlanTarget, $planPrompt) | Out-Null
        $planStage = Wait-TeamPipelineStage -Target $targets.PlanTarget -StageName 'PLAN' -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds
        $result.Plan = $planStage
        if ($planStage.Status -eq 'BLOCKED') {
            $result.FinalStatus = 'PLAN_BLOCKED'
            return [PSCustomObject]$result
        }

        $planSummary = $planStage.Summary
    }

    $attemptLimit = 1 + [Math]::Max(0, $MaxFixRounds)
    for ($attemptIndex = 1; $attemptIndex -le $attemptLimit; $attemptIndex++) {
        $attempt = [ordered]@{
            Attempt           = $attemptIndex
            Build             = $null
            BuildNotification = $null
            VerifyDispatch    = $null
            Verify            = $null
        }

        $buildPrompt = if ($attemptIndex -eq 1) {
            New-TeamPipelineExecPrompt -Task $Task -PlanSummary $planSummary
        } else {
            $previousVerify = [string]$result.Attempts[-1].Verify.Summary
            New-TeamPipelineFixPrompt -Task $Task -PlanSummary $planSummary -VerificationSummary $previousVerify
        }

        Invoke-TeamPipelineBridge -Arguments @('send', $Builder, $buildPrompt) | Out-Null
        $buildStage = Wait-TeamPipelineStage -Target $Builder -StageName 'EXEC' -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds
        $attempt.Build = $buildStage

        if ($buildStage.Status -eq 'BLOCKED') {
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

        if ([string]::IsNullOrWhiteSpace($targets.VerifyTarget)) {
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

        Write-TeamPipelineEvent -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -Event 'pipeline.reviewer.dispatched' -Message "Auto-dispatched review to $($targets.VerifyTarget) after builder completion." -Role $verifyRole -Target $targets.VerifyTarget -Data ([ordered]@{
            attempt              = $attemptIndex
            task                 = $Task
            builder              = $Builder
            builder_worktree_path = $builderContext.BuilderWorktreePath
            summary              = $buildNotification.Summary
        }) | Out-Null
        Invoke-TeamPipelineBridge -Arguments @('send', $targets.VerifyTarget, $verifyPrompt) | Out-Null
        $verifyStage = Wait-TeamPipelineStage -Target $targets.VerifyTarget -StageName 'VERIFY' -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds
        $attempt.Verify = $verifyStage
        $result.Attempts += [PSCustomObject]$attempt

        switch ($verifyStage.Status) {
            'VERIFY_PASS' {
                $result.Success = $true
                $result.FinalStatus = 'VERIFY_PASS'
                return [PSCustomObject]$result
            }
            'BLOCKED' {
                $result.FinalStatus = 'VERIFY_BLOCKED'
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
    return [PSCustomObject]$result
}

if ($MyInvocation.InvocationName -ne '.') {
    $pipelineResult = Invoke-TeamPipeline -Task $Task -Builder $Builder -Researcher $Researcher -Reviewer $Reviewer -ManifestPath $ManifestPath -BuilderWorktreePath $BuilderWorktreePath -PollIntervalSeconds $PollIntervalSeconds -StageTimeoutSeconds $StageTimeoutSeconds -MaxFixRounds $MaxFixRounds -SkipPlan:$SkipPlan -SkipVerify:$SkipVerify
    if ($AsJson) {
        $pipelineResult | ConvertTo-Json -Depth 8
    } else {
        $pipelineResult
    }
}
