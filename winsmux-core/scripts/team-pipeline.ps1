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
$script:TeamPipelinePaneEnvScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'pane-env.ps1'))
$script:TeamPipelineDangerousApprovalPattern = '(?im)(rm\s+-rf|Remove-Item\s+.+-Recurse.+-Force|git\s+push\s+--force|git\s+reset\s+--hard|DROP\s+TABLE|DELETE\s+FROM)'

. (Join-Path $PSScriptRoot 'manifest.ps1')
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
        [int]$Attempt = 0
    )

    $violation = Find-TeamPipelineSecurityViolation -StageName $StageName -Text $Prompt
    if ($null -eq $violation) {
        Invoke-TeamPipelineBridge -Arguments @('send', $Target, $Prompt) | Out-Null
        return $null
    }

    $securityVerdict = New-TeamPipelineSecurityVerdict -StageName $StageName -Target $Target -Reason ([string]$violation['reason']) -ActionKind 'pre_dispatch' -ActionValue ([string]$violation['line']) -PromptText $Prompt
    Write-TeamPipelineEvent -ProjectDir $ProjectDir -SessionName $SessionName -Event 'pipeline.security.blocked' -Message "Security monitor blocked $StageName on $Target before dispatch." -Role $Role -Target $Target -Data ([ordered]@{
        stage         = $securityVerdict.stage
        attempt       = $Attempt
        task          = $Task
        verdict       = $securityVerdict.verdict
        reason        = $securityVerdict.reason
        advisory_mode = $securityVerdict.advisory_mode
        allow         = @($securityVerdict.allow)
        block         = @($securityVerdict.block)
        next_action   = $securityVerdict.next_action
        action_kind   = 'pre_dispatch'
        action_value  = [string]$violation['line']
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

    return [PSCustomObject]@{
        packet_type        = 'verification_packet'
        verification_contract = [PSCustomObject](New-TeamPipelineVerificationContract)
        verification_result = if ($null -ne $verificationResult) { [PSCustomObject]$verificationResult } else { $null }
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
        [int]$Attempt = 0
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
                    reason         = $securityVerdict.reason
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
            if (-not [string]::IsNullOrWhiteSpace($consultTarget)) {
                $attempt.StuckConsult = Invoke-TeamPipelineConsultStage -Mode 'stuck' -Task $Task -BuilderLabel $Builder -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -TargetLabel $consultTarget -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -BuilderWorktreePath $builderContext.BuilderWorktreePath -PlanSummary $planSummary -BuildSummary $buildStage.Summary -VerificationSummary '' -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds -Attempt $attemptIndex
                if ($null -ne $attempt.StuckConsult) {
                    $result.StuckConsults += $attempt.StuckConsult
                }
            }
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
                if (-not [string]::IsNullOrWhiteSpace($consultTarget)) {
                    $attempt.StuckConsult = Invoke-TeamPipelineConsultStage -Mode 'stuck' -Task $Task -BuilderLabel $Builder -ProjectDir $builderContext.ProjectDir -SessionName $sessionName -TargetLabel $consultTarget -ResearcherLabel $Researcher -ReviewerLabel $Reviewer -BuilderWorktreePath $builderContext.BuilderWorktreePath -PlanSummary $planSummary -BuildSummary $buildStage.Summary -VerificationSummary $verifyStage.Summary -TimeoutSeconds $StageTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds -Attempt $attemptIndex
                    if ($null -ne $attempt.StuckConsult) {
                        $result.StuckConsults += $attempt.StuckConsult
                    }
                }
                $result.FinalStatus = 'VERIFY_BLOCKED'
                return [PSCustomObject]$result
            }
            'VERIFY_PARTIAL' {
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
