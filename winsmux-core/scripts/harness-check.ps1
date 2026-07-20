[CmdletBinding()]
param(
    [string]$ProjectDir = '',
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
    $ProjectDir = (Get-Location).Path
}

$ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)
$scriptsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptsRoot 'json-compat.ps1')
. (Join-Path $scriptsRoot 'orchestra-ui-attach.ps1')

function New-HarnessCheckRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()]$Data = $null
    )

    return [ordered]@{
        name    = $Name
        passed  = $Passed
        message = $Message
        data    = $Data
    }
}

function Test-HarnessWritableFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $parent = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        $probe = [ordered]@{
            checked_at = (Get-Date).ToString('o')
            probe      = [guid]::NewGuid().ToString('N')
        } | ConvertTo-Json -Depth 4

        Write-WinsmuxTextFile -Path $Path -Content $probe
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-HarnessSettingsObject {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    return ($raw | ConvertFrom-WinsmuxJson -Depth 32)
}

function Test-HarnessHasProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }

    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Test-HarnessSettingsLocalTracked {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $output = & git -C $RepoRoot ls-files --error-unmatch .claude/settings.local.json 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Resolve-HarnessRuntimeProjectDir {
    param([Parameter(Mandatory = $true)][string]$CodeRoot)

    $localManifestPath = Join-Path $CodeRoot '.winsmux\manifest.yaml'
    if (Test-Path -LiteralPath $localManifestPath -PathType Leaf) {
        return $CodeRoot
    }

    $commonGitDirOutput = & git -C $CodeRoot rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $CodeRoot
    }

    $commonGitDir = ($commonGitDirOutput | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($commonGitDir)) {
        return $CodeRoot
    }

    $commonProjectDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($commonGitDir))
    $commonManifestPath = Join-Path $commonProjectDir '.winsmux\manifest.yaml'
    if (Test-Path -LiteralPath $commonManifestPath -PathType Leaf) {
        return $commonProjectDir
    }

    return $CodeRoot
}

function Test-HarnessSettingsHasHookCommand {
    param(
        [AllowNull()]$SettingsObject,
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$Matcher = ''
    )

    if ($null -eq $SettingsObject -or -not (Test-HarnessHasProperty -Object $SettingsObject -Name 'hooks')) {
        return $false
    }

    $hooksRoot = $SettingsObject.hooks
    if (-not (Test-HarnessHasProperty -Object $hooksRoot -Name $EventName)) {
        return $false
    }

    $eventHooks = @($hooksRoot.$EventName)
    foreach ($group in $eventHooks) {
        if (-not (Test-HarnessHasProperty -Object $group -Name 'hooks')) {
            continue
        }

        $groupMatcher = if (Test-HarnessHasProperty -Object $group -Name 'matcher') { [string]$group.matcher } else { '' }
        if ($groupMatcher -ne $Matcher) {
            continue
        }

        foreach ($hook in @($group.hooks)) {
            if ((Test-HarnessHasProperty -Object $hook -Name 'command') -and $hook.command -eq $Command) {
                return $true
            }
        }
    }

    return $false
}

function Get-HarnessJsFunctionBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$FunctionName
    )

    $functionMatches = [regex]::Matches($Source, '(?m)^\s*function\s+[A-Za-z0-9_]+\s*\(')
    if ($functionMatches.Count -eq 0) {
        return ''
    }

    $targetPattern = '(?m)^\s*function\s+' + [regex]::Escape($FunctionName) + '\s*\('
    $targetMatch = [regex]::Match($Source, $targetPattern)
    if (-not $targetMatch.Success) {
        return ''
    }

    $startIndex = $targetMatch.Index
    $endIndex = $Source.Length
    foreach ($match in $functionMatches) {
        if ($match.Index -gt $startIndex) {
            $endIndex = $match.Index
            break
        }
    }

    return $Source.Substring($startIndex, $endIndex - $startIndex)
}

function Get-HarnessHookSignatureViolations {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $violations = [System.Collections.Generic.List[string]]::new()
    $hookFiles = @(
        '.claude/hooks/lib/sh-utils.js',
        '.claude/hooks/sh-channel-detect.js',
        '.claude/hooks/sh-invisible-char-scan.js',
        '.claude/hooks/sh-permission.js',
        '.claude/hooks/sh-gate.js',
        '.claude/hooks/sh-elicitation.js',
        '.claude/hooks/sh-orchestra-gate.js',
        '.claude/hooks/sh-operator-playbook.js'
    )

    foreach ($relativePath in $hookFiles) {
        $fullPath = Join-Path $RepoRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            $violations.Add("Missing hook file: $relativePath") | Out-Null
            continue
        }

        $content = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
        if ($content -match 'process\.stderr\.write\(JSON\.stringify') {
            $violations.Add("$relativePath emits JSON to stderr.") | Out-Null
        }
    }

    $utilsPath = Join-Path $RepoRoot '.claude/hooks/lib/sh-utils.js'
    if (Test-Path -LiteralPath $utilsPath -PathType Leaf) {
        $utilsContent = Get-Content -LiteralPath $utilsPath -Raw -Encoding UTF8
        if ($utilsContent -notmatch 'permissionDecision:\s*"deny"') {
            $violations.Add('.claude/hooks/lib/sh-utils.js does not emit a structured deny decision for PreToolUse.') | Out-Null
        }
        if ($utilsContent -notmatch 'process\.exit\(0\)') {
            $violations.Add('.claude/hooks/lib/sh-utils.js does not keep successful structured hook replies on exit 0.') | Out-Null
        }
        if ($utilsContent -notmatch 'function\s+buildHookSpecificOutput\s*\(') {
            $violations.Add('.claude/hooks/lib/sh-utils.js does not define a shared hookSpecificOutput builder.') | Out-Null
        }
        foreach ($functionName in @('allow', 'allowWithUpdate', 'allowWithResult')) {
            $functionBlock = Get-HarnessJsFunctionBlock -Source $utilsContent -FunctionName $functionName
            if ([string]::IsNullOrWhiteSpace($functionBlock) -or $functionBlock -notmatch 'buildHookSpecificOutput\s*\(') {
                $violations.Add(".claude/hooks/lib/sh-utils.js $functionName reply does not include hookEventName via buildHookSpecificOutput.") | Out-Null
            }
        }
    }

    return @($violations)
}

function Test-HarnessSmokeContract {
    param(
        [Parameter(Mandatory = $true)][string]$CodeRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeProjectDir
    )

    $smokeScript = Join-Path $CodeRoot 'winsmux-core\scripts\orchestra-smoke.ps1'
    $stdout = & pwsh -NoProfile -File $smokeScript -ProjectDir $RuntimeProjectDir -AsJson 2>&1
    $exitCode = $LASTEXITCODE
    $raw = ($stdout | Out-String).Trim()
    $parsed = $null
    $error = ''

    try {
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $parsed = $raw | ConvertFrom-WinsmuxJson -Depth 16
        }
    } catch {
        $rawPreview = $raw -replace '[\r\n]+', ' '
        if ($rawPreview.Length -gt 512) {
            $rawPreview = $rawPreview.Substring(0, 512)
        }
        $error = "{0} Raw output prefix: {1}" -f $_.Exception.Message, $rawPreview
    }

    return [ordered]@{
        exit_code = $exitCode
        raw       = $raw
        parsed    = $parsed
        error     = $error
    }
}

function Get-HarnessSmokeContractEvaluation {
    param([Parameter(Mandatory = $true)]$SmokeProbe)

    if (-not (Test-HarnessHasProperty -Object $SmokeProbe -Name 'parsed') -or $null -eq $SmokeProbe.parsed) {
        $parseError = if (Test-HarnessHasProperty -Object $SmokeProbe -Name 'error') { [string]$SmokeProbe.error } else { '' }
        $message = if ([string]::IsNullOrWhiteSpace($parseError)) {
            'orchestra-smoke did not return JSON.'
        } else {
            "orchestra-smoke JSON parse failed: $parseError"
        }
        return [ordered]@{ passed = $false; message = $message }
    }

    $parsed = $SmokeProbe.parsed
    $contract = if (Test-HarnessHasProperty -Object $parsed -Name 'operator_contract') { $parsed.operator_contract } else { $null }
    $hasContract = $null -ne $contract -and
        (Test-HarnessHasProperty -Object $contract -Name 'operator_state') -and
        (Test-HarnessHasProperty -Object $contract -Name 'can_dispatch') -and
        (Test-HarnessHasProperty -Object $contract -Name 'requires_startup')
    if (-not $hasContract) {
        return [ordered]@{ passed = $false; message = 'orchestra-smoke result is missing operator_contract fields.' }
    }

    if (-not (Test-HarnessHasProperty -Object $parsed -Name 'smoke_ok')) {
        return [ordered]@{ passed = $false; message = 'orchestra-smoke result is missing smoke_ok.' }
    }
    if (-not (Test-HarnessHasProperty -Object $parsed -Name 'runtime_valid') -or
        -not (Test-HarnessHasProperty -Object $parsed -Name 'runtime_identity')) {
        return [ordered]@{ passed = $false; message = 'orchestra-smoke did not expose the supervisor-owned runtime identity registry.' }
    }

    $exitCode = if (Test-HarnessHasProperty -Object $SmokeProbe -Name 'exit_code') { [int]$SmokeProbe.exit_code } else { 1 }
    $smokeOk = [bool]$parsed.smoke_ok
    $runtimeValid = [bool]$parsed.runtime_valid
    $operatorState = [string]$contract.operator_state
    $canDispatch = [bool]$contract.can_dispatch
    $requiresStartup = [bool]$contract.requires_startup
    $runtimeIdentity = $parsed.runtime_identity
    $runtimeReasonCode = if ($null -ne $runtimeIdentity -and (Test-HarnessHasProperty -Object $runtimeIdentity -Name 'reason_code')) {
        [string]$runtimeIdentity.reason_code
    } else {
        ''
    }
    $knownPreStartReasonCodes = @(
        'manifest_regeneration_required'
        'invalid_supervisor_identity'
        'caller_identity_mismatch'
        'runtime_target_mismatch'
    )
    $hasTypedRuntimeRefusal = $null -ne $runtimeIdentity -and
        (Test-HarnessHasProperty -Object $runtimeIdentity -Name 'valid') -and
        -not [bool]$runtimeIdentity.valid -and
        $knownPreStartReasonCodes -ccontains $runtimeReasonCode
    $safePreStart = $exitCode -eq 1 -and
        -not $smokeOk -and
        -not $runtimeValid -and
        $hasTypedRuntimeRefusal -and
        $operatorState -ceq 'blocked' -and
        -not $canDispatch -and
        $requiresStartup

    if ($safePreStart) {
        return [ordered]@{
            passed  = $true
            message = 'orchestra-smoke reported a safe pre-start blocked state; runtime regeneration is required before dispatch.'
        }
    }
    if ($exitCode -ne 0) {
        return [ordered]@{ passed = $false; message = "orchestra-smoke exited with code $exitCode and the result was not a safe pre-start blocked state." }
    }
    if (-not $smokeOk) {
        return [ordered]@{ passed = $false; message = 'orchestra-smoke reported smoke_ok=false.' }
    }
    if (-not $runtimeValid) {
        return [ordered]@{ passed = $false; message = 'orchestra-smoke did not verify the supervisor-owned runtime identity registry.' }
    }
    if ($requiresStartup) {
        return [ordered]@{ passed = $false; message = 'operator_contract.requires_startup must be false after a successful orchestra smoke.' }
    }
    if ($operatorState -ceq 'blocked' -and $canDispatch) {
        return [ordered]@{ passed = $false; message = 'operator_state=blocked must not allow dispatch.' }
    }

    $externalOperatorMode = (Test-HarnessHasProperty -Object $parsed -Name 'external_operator_mode') -and [bool]$parsed.external_operator_mode
    $sessionReady = (Test-HarnessHasProperty -Object $parsed -Name 'session_ready') -and [bool]$parsed.session_ready
    $uiAttached = (Test-HarnessHasProperty -Object $parsed -Name 'ui_attached') -and [bool]$parsed.ui_attached
    if ($externalOperatorMode -and $sessionReady -and -not $uiAttached -and [bool]$contract.can_dispatch) {
        return [ordered]@{ passed = $false; message = 'operator_contract.can_dispatch must stay false until attached-client confirmation is recorded.' }
    }

    return [ordered]@{ passed = $true; message = 'orchestra-smoke contract is structurally consistent.' }
}

$results = [System.Collections.Generic.List[object]]::new()
$runtimeProjectDir = Resolve-HarnessRuntimeProjectDir -CodeRoot $ProjectDir

$settingsPath = Join-Path $ProjectDir '.claude\settings.json'
$settingsLocalPath = Join-Path $ProjectDir '.claude\settings.local.json'
$settings = Get-HarnessSettingsObject -Path $settingsPath
$settingsLocal = Get-HarnessSettingsObject -Path $settingsLocalPath

$settingsExists = Test-Path -LiteralPath $settingsPath -PathType Leaf
$settingsMessage = if ($settingsExists) { 'Project settings.json found.' } else { 'Missing .claude/settings.json.' }
$results.Add((New-HarnessCheckRecord -Name 'settings-json-exists' -Passed $settingsExists -Message $settingsMessage -Data $settingsPath)) | Out-Null

$operatorPlaybookHook = Test-HarnessSettingsHasHookCommand -SettingsObject $settings -EventName 'SessionStart' -Matcher '' -Command 'node .claude/hooks/sh-operator-playbook.js'
$operatorPlaybookHookMessage = if ($operatorPlaybookHook) { 'Project settings.json registers the operator playbook SessionStart hook.' } else { 'settings.json must register node .claude/hooks/sh-operator-playbook.js in the empty-matcher SessionStart group.' }
$results.Add((New-HarnessCheckRecord -Name 'settings-registers-operator-playbook' -Passed $operatorPlaybookHook -Message $operatorPlaybookHookMessage -Data $settingsPath)) | Out-Null

$sharedOrchestraGate = Test-HarnessSettingsHasHookCommand -SettingsObject $settings -EventName 'PreToolUse' -Matcher '' -Command 'node .claude/hooks/sh-orchestra-gate.js'
$sharedOrchestraGateMessage = if ($sharedOrchestraGate) { 'Project settings.json registers the orchestra gate hook in the empty-matcher PreToolUse group.' } else { 'settings.json must register node .claude/hooks/sh-orchestra-gate.js in the empty-matcher PreToolUse group.' }
$results.Add((New-HarnessCheckRecord -Name 'settings-shared-registers-orchestra-gate' -Passed $sharedOrchestraGate -Message $sharedOrchestraGateMessage -Data $settingsPath)) | Out-Null

$localHasHooks = $false
if ($null -ne $settingsLocal) {
    if ($settingsLocal -is [System.Collections.IDictionary]) {
        if ($settingsLocal.Contains('hooks')) {
            $localHasHooks = ($null -ne $settingsLocal['hooks'])
        }
    } elseif (Test-HarnessHasProperty -Object $settingsLocal -Name 'hooks') {
        $localHasHooks = ($null -ne $settingsLocal.hooks)
    }
}
$settingsLocalMessage = if (-not $localHasHooks) { 'settings.local.json does not register hooks.' } else { 'settings.local.json must not register hooks.' }
$results.Add((New-HarnessCheckRecord -Name 'settings-local-has-no-hooks' -Passed (-not $localHasHooks) -Message $settingsLocalMessage -Data $settingsLocalPath)) | Out-Null

$settingsLocalTracked = Test-HarnessSettingsLocalTracked -RepoRoot $ProjectDir
$settingsLocalTrackedMessage = if (-not $settingsLocalTracked) { 'settings.local.json is not tracked.' } else { 'settings.local.json must stay untracked.' }
$results.Add((New-HarnessCheckRecord -Name 'settings-local-not-tracked' -Passed (-not $settingsLocalTracked) -Message $settingsLocalTrackedMessage -Data $settingsLocalPath)) | Out-Null

$hookViolations = @(Get-HarnessHookSignatureViolations -RepoRoot $ProjectDir)
$hookOutputPassed = ($hookViolations.Count -eq 0)
$hookOutputMessage = if ($hookOutputPassed) { 'Startup hook files match the expected stdout/stderr contract.' } else { 'Hook output contract violations detected.' }
$results.Add((New-HarnessCheckRecord -Name 'hook-output-contract' -Passed $hookOutputPassed -Message $hookOutputMessage -Data @($hookViolations))) | Out-Null

$profileCheckPassed = $false
$profileCheckData = $null
$profileCheckMessage = ''
try {
    $profile = Ensure-OrchestraAttachProfile -ProjectDir $runtimeProjectDir
    $profileCheckPassed = Test-Path -LiteralPath $profile.FragmentPath -PathType Leaf
    $profileCheckData = $profile
    $profileCheckMessage = if ($profileCheckPassed) { 'Windows Terminal attach profile is registered.' } else { 'Attach profile fragment was not created.' }
} catch {
    $profileCheckMessage = $_.Exception.Message
}
$results.Add((New-HarnessCheckRecord -Name 'wt-attach-profile' -Passed $profileCheckPassed -Message $profileCheckMessage -Data $profileCheckData)) | Out-Null

$attachProbePath = Get-OrchestraAttachStatePath -SessionName 'winsmux-harness-check'
$attachPathWritable = Test-HarnessWritableFile -Path $attachProbePath
$attachWritableMessage = if ($attachPathWritable) { 'Attach handshake path is writable.' } else { 'Attach handshake path is not writable.' }
$results.Add((New-HarnessCheckRecord -Name 'attach-handshake-path-writable' -Passed $attachPathWritable -Message $attachWritableMessage -Data $attachProbePath)) | Out-Null

$hostCandidates = @(Get-OrchestraVisibleAttachHostCandidates -ProjectDir $runtimeProjectDir)
$availableHostCandidates = @($hostCandidates | Where-Object { [bool]$_.Available })
$hostAdapterPassed = ($availableHostCandidates.Count -gt 0)
$hostAdapterMessage = if ($hostAdapterPassed) {
    'At least one visible attach host adapter is available.'
} else {
    'No visible attach host adapter is currently available.'
}
$results.Add((New-HarnessCheckRecord -Name 'visible-attach-host-adapters' -Passed $hostAdapterPassed -Message $hostAdapterMessage -Data @(
    $hostCandidates | ForEach-Object {
        [ordered]@{
            host_kind = [string]$_.HostKind
            available = [bool]$_.Available
            reason    = [string]$_.Reason
            path      = [string]$_.Path
        }
    }
))) | Out-Null

$smokeProbe = Test-HarnessSmokeContract -CodeRoot $ProjectDir -RuntimeProjectDir $runtimeProjectDir
$smokeEvaluation = Get-HarnessSmokeContractEvaluation -SmokeProbe $smokeProbe
$smokePassed = [bool]$smokeEvaluation.passed
$smokeMessage = [string]$smokeEvaluation.message
$attachRegistryPassed = $false
$attachRegistryMessage = ''
$attachConsistencyPassed = $false
$attachConsistencyMessage = ''
if ($null -eq $smokeProbe.parsed) {
    $smokeMessage = if ([string]::IsNullOrWhiteSpace($smokeProbe.error)) { 'orchestra-smoke did not return JSON.' } else { "orchestra-smoke JSON parse failed: $($smokeProbe.error)" }
    $attachRegistryMessage = $smokeMessage
    $attachConsistencyMessage = $smokeMessage
} else {
    $contract = if (Test-HarnessHasProperty -Object $smokeProbe.parsed -Name 'operator_contract') { $smokeProbe.parsed.operator_contract } else { $null }
    $hasContract = $null -ne $contract -and
        (Test-HarnessHasProperty -Object $contract -Name 'operator_state') -and
        (Test-HarnessHasProperty -Object $contract -Name 'can_dispatch') -and
        (Test-HarnessHasProperty -Object $contract -Name 'requires_startup')
    $hasAttachRegistryFields = @(
        'attached_client_count',
        'attached_client_registry_count',
        'attached_client_snapshot',
        'ui_attach_source',
        'ui_host_kind',
        'ui_attach_launched',
        'ui_attached',
        'session_ready'
    ) | ForEach-Object {
        Test-HarnessHasProperty -Object $smokeProbe.parsed -Name $_
    }
    if (-not $smokePassed) {
        $attachConsistencyMessage = $smokeMessage
    }

    if ($hasAttachRegistryFields -contains $false) {
        $attachRegistryMessage = 'orchestra-smoke result is missing attached-client registry fields.'
    } else {
        $attachRegistryPassed = $true
        $attachRegistryMessage = 'orchestra-smoke exposes attached-client registry and attach-source fields.'
    }

    if (-not $hasContract) {
        $attachConsistencyMessage = 'orchestra-smoke result is missing operator_contract fields.'
    } elseif (-not (Test-HarnessHasProperty -Object $smokeProbe.parsed -Name 'session_ready') -or
        -not (Test-HarnessHasProperty -Object $smokeProbe.parsed -Name 'ui_attached') -or
        -not (Test-HarnessHasProperty -Object $smokeProbe.parsed -Name 'ui_attach_launched')) {
        $attachConsistencyMessage = 'orchestra-smoke result is missing startup/attach consistency fields.'
    } elseif (($contract.operator_state -eq 'ready') -and (-not $smokeProbe.parsed.session_ready -or -not $smokeProbe.parsed.ui_attached)) {
        $attachConsistencyMessage = 'operator_state=ready requires session_ready=true and ui_attached=true.'
    } elseif (($contract.operator_state -eq 'blocked') -and $contract.can_dispatch) {
        $attachConsistencyMessage = 'operator_state=blocked must not allow dispatch.'
    } elseif ((-not $smokeProbe.parsed.session_ready) -and $smokeProbe.parsed.ui_attached) {
        $attachConsistencyMessage = 'ui_attached=true is invalid while session_ready=false.'
    } else {
        $attachConsistencyPassed = $true
        $attachConsistencyMessage = 'Startup truth and attach truth remain internally consistent.'
    }
}
$results.Add((New-HarnessCheckRecord -Name 'orchestra-smoke-contract' -Passed $smokePassed -Message $smokeMessage -Data ([ordered]@{
    exit_code = $smokeProbe.exit_code
    smoke_ok  = $(if ($null -ne $smokeProbe.parsed) { $smokeProbe.parsed.smoke_ok } else { $null })
    runtime_valid = $(if ($null -ne $smokeProbe.parsed -and (Test-HarnessHasProperty -Object $smokeProbe.parsed -Name 'runtime_valid')) { $smokeProbe.parsed.runtime_valid } else { $null })
    runtime_reason_code = $(if ($null -ne $smokeProbe.parsed -and (Test-HarnessHasProperty -Object $smokeProbe.parsed -Name 'runtime_identity') -and $null -ne $smokeProbe.parsed.runtime_identity -and (Test-HarnessHasProperty -Object $smokeProbe.parsed.runtime_identity -Name 'reason_code')) { $smokeProbe.parsed.runtime_identity.reason_code } else { $null })
    ui_attached = $(if ($null -ne $smokeProbe.parsed) { $smokeProbe.parsed.ui_attached } else { $null })
    external_operator_mode = $(if ($null -ne $smokeProbe.parsed) { $smokeProbe.parsed.external_operator_mode } else { $null })
    operator_state = $(if ($null -ne $smokeProbe.parsed -and $null -ne $smokeProbe.parsed.operator_contract) { $smokeProbe.parsed.operator_contract.operator_state } else { $null })
    can_dispatch = $(if ($null -ne $smokeProbe.parsed -and $null -ne $smokeProbe.parsed.operator_contract) { $smokeProbe.parsed.operator_contract.can_dispatch } else { $null })
    requires_startup = $(if ($null -ne $smokeProbe.parsed -and $null -ne $smokeProbe.parsed.operator_contract) { $smokeProbe.parsed.operator_contract.requires_startup } else { $null })
})) ) | Out-Null
$results.Add((New-HarnessCheckRecord -Name 'attached-client-registry-contract' -Passed $attachRegistryPassed -Message $attachRegistryMessage -Data ([ordered]@{
    client_probe_ok = $(if ($null -ne $smokeProbe.parsed) { $smokeProbe.parsed.client_probe_ok } else { $null })
    attached_client_count = $(if ($null -ne $smokeProbe.parsed) { $smokeProbe.parsed.attached_client_count } else { $null })
    attached_client_registry_count = $(if ($null -ne $smokeProbe.parsed) { $smokeProbe.parsed.attached_client_registry_count } else { $null })
    ui_attach_source = $(if ($null -ne $smokeProbe.parsed) { $smokeProbe.parsed.ui_attach_source } else { $null })
    ui_host_kind = $(if ($null -ne $smokeProbe.parsed) { $smokeProbe.parsed.ui_host_kind } else { $null })
})) ) | Out-Null
$results.Add((New-HarnessCheckRecord -Name 'startup-attach-consistency' -Passed $attachConsistencyPassed -Message $attachConsistencyMessage -Data ([ordered]@{
    session_ready = $(if ($null -ne $smokeProbe.parsed) { $smokeProbe.parsed.session_ready } else { $null })
    ui_attach_launched = $(if ($null -ne $smokeProbe.parsed) { $smokeProbe.parsed.ui_attach_launched } else { $null })
    ui_attached = $(if ($null -ne $smokeProbe.parsed) { $smokeProbe.parsed.ui_attached } else { $null })
    operator_state = $(if ($null -ne $smokeProbe.parsed -and $null -ne $smokeProbe.parsed.operator_contract) { $smokeProbe.parsed.operator_contract.operator_state } else { $null })
    can_dispatch = $(if ($null -ne $smokeProbe.parsed -and $null -ne $smokeProbe.parsed.operator_contract) { $smokeProbe.parsed.operator_contract.can_dispatch } else { $null })
})) ) | Out-Null

$passed = (@($results | Where-Object { -not $_.passed }).Count -eq 0)
$summary = [ordered]@{
    checked_at         = (Get-Date).ToString('o')
    project_dir        = $ProjectDir
    runtime_project_dir = $runtimeProjectDir
    passed             = $passed
    results            = @($results)
}

if ($AsJson) {
    $summary | ConvertTo-Json -Depth 12
} else {
    foreach ($result in $summary.results) {
        $status = if ($result.passed) { 'PASS' } else { 'FAIL' }
        '{0} {1}: {2}' -f $status, $result.name, $result.message
    }
}

if (-not $passed) {
    exit 1
}
