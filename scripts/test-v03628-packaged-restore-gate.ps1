param(
    [switch]$Json,
    [switch]$RequireEvidence,
    [string]$EvidencePath = 'winsmux-app/output/playwright/desktop-packaged-restore-e2e/desktop-pane-e2e.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'test-v03628-packaged-restore-gate: failed to determine repository root.'
}

$currentGitHead = (& git -C $repoRoot rev-parse HEAD 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($currentGitHead)) {
    throw 'test-v03628-packaged-restore-gate: failed to determine current git head.'
}

function Get-RepoPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    return (Join-Path $repoRoot $RelativePath)
}

function Get-RepoContent {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Get-RepoPath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8
}

function Get-RepoJson {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $content = Get-RepoContent $RelativePath
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }
    return ($content | ConvertFrom-Json)
}

function Get-JsonPropertyValue {
    param(
        [Parameter(Mandatory = $false)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)]$Default = $null
    )

    if ($null -eq $InputObject) {
        return ,$Default
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return ,$InputObject[$Name]
        }
        return ,$Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return ,$Default
    }
    return ,$property.Value
}

function Test-BooleanTrue {
    param([Parameter(Mandatory = $false)]$Value)
    return ($Value -is [bool] -and [bool]$Value)
}

function Test-BooleanFalse {
    param([Parameter(Mandatory = $false)]$Value)
    return ($Value -is [bool] -and -not [bool]$Value)
}

function Test-NonEmptyString {
    param([Parameter(Mandatory = $false)]$Value)
    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Test-IntegerAtLeast {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $true)][int]$Minimum
    )

    if (-not ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal])) {
        return $false
    }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        return $false
    }
    return ([math]::Abs($number - [math]::Round($number)) -lt 0.0000001 -and [int64]$number -ge $Minimum)
}

function ConvertTo-JsonValueArray {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [string]) {
        return @($Value)
    }
    if ($Value -is [System.Array]) {
        return @($Value)
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value)
    }
    return @($Value)
}

function Test-JsonValuesAllEqual {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $values = @(ConvertTo-JsonValueArray $Value)
    if ($values.Count -lt 1) {
        return $false
    }
    foreach ($item in $values) {
        if ($item -isnot [string] -or $item -ne $Expected) {
            return $false
        }
    }
    return $true
}

$checks = @()

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Pass,
        [string]$Evidence = ''
    )

    $script:checks += , [pscustomobject][ordered]@{
        name     = $Name
        pass     = $Pass
        evidence = $Evidence
    }
}

function Add-ContainsAllCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string[]]$Patterns,
        [Parameter(Mandatory = $true)][string]$Evidence
    )

    $missing = @($Patterns | Where-Object { $Content -notmatch $_ })
    Add-Check $Name ($missing.Count -eq 0) ("{0}; missing={1}" -f $Evidence, ($missing -join ', '))
}

function Get-WorkerAssignment {
    param(
        [Parameter(Mandatory = $false)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$SlotId
    )

    $assignmentsRaw = Get-JsonPropertyValue -InputObject $Snapshot -Name 'workerAssignments' -Default @()
    $assignments = @()
    if ($null -ne $assignmentsRaw) {
        foreach ($assignment in $assignmentsRaw) {
            $assignments += ,$assignment
        }
    }
    foreach ($assignment in $assignments) {
        if ((Get-JsonPropertyValue -InputObject $assignment -Name 'slotId' -Default '') -eq $SlotId) {
            return $assignment
        }
    }
    return $null
}

function Test-RestoreSnapshot {
    param(
        [Parameter(Mandatory = $false)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    $activeProjectMatches = Get-JsonPropertyValue -InputObject $Snapshot -Name 'activeProjectMatches' -Default $null
    $projectSessionRecorded = Get-JsonPropertyValue -InputObject $Snapshot -Name 'projectSessionRecorded' -Default $null
    $runtimeAssignmentMode = Get-JsonPropertyValue -InputObject $Snapshot -Name 'runtimeAssignmentMode' -Default $null
    $shellLayout = Get-JsonPropertyValue -InputObject $Snapshot -Name 'shellLayout' -Default $null
    $shellFocusedPaneId = Get-JsonPropertyValue -InputObject $Snapshot -Name 'shellFocusedPaneId' -Default $null
    $restoreCandidateCount = Get-JsonPropertyValue -InputObject $Snapshot -Name 'restoreCandidateCount' -Default $null
    $restoreCandidateTransport = Get-JsonPropertyValue -InputObject $Snapshot -Name 'restoreCandidateTransport' -Default ''
    $candidate = Get-JsonPropertyValue -InputObject $Snapshot -Name 'restoreCandidate' -Default $null
    $candidateRestoreState = Get-JsonPropertyValue -InputObject $candidate -Name 'restoreState' -Default ''
    $setupRequiredCandidateCount = Get-JsonPropertyValue -InputObject $Snapshot -Name 'setupRequiredCandidateCount' -Default $null
    $setupRequiredCandidate = Get-JsonPropertyValue -InputObject $Snapshot -Name 'setupRequiredCandidate' -Default $null
    $setupRequiredRestoreState = Get-JsonPropertyValue -InputObject $setupRequiredCandidate -Name 'restoreState' -Default ''
    $setupRequiredReason = Get-JsonPropertyValue -InputObject $setupRequiredCandidate -Name 'setupRequiredReason' -Default ''
    $setupRequiredPaneStates = Get-JsonPropertyValue -InputObject $setupRequiredCandidate -Name 'paneRestoreStates' -Default @()
    $setupRequiredPaneReasons = Get-JsonPropertyValue -InputObject $setupRequiredCandidate -Name 'setupRequiredReasons' -Default @()
    $transcriptRing = Get-JsonPropertyValue -InputObject $candidate -Name 'transcriptRingSummary' -Default $null
    $privacy = Get-JsonPropertyValue -InputObject $candidate -Name 'privacy' -Default $null
    $workerOne = Get-WorkerAssignment -Snapshot $Snapshot -SlotId 'worker-1'
    $workerTwo = Get-WorkerAssignment -Snapshot $Snapshot -SlotId 'worker-2'
    $workerOneModel = "{0} {1}" -f (Get-JsonPropertyValue -InputObject $workerOne -Name 'provider' -Default ''), (Get-JsonPropertyValue -InputObject $workerOne -Name 'model' -Default '')
    $workerTwoModel = "{0} {1}" -f (Get-JsonPropertyValue -InputObject $workerTwo -Name 'provider' -Default ''), (Get-JsonPropertyValue -InputObject $workerTwo -Name 'model' -Default '')
    $contextCapsule = Get-JsonPropertyValue -InputObject $candidate -Name 'contextCapsuleRef' -Default ''
    $checkpoint = Get-JsonPropertyValue -InputObject $candidate -Name 'checkpointRef' -Default ''
    $sha = Get-JsonPropertyValue -InputObject $transcriptRing -Name 'sha256' -Default ''
    $byteCount = Get-JsonPropertyValue -InputObject $transcriptRing -Name 'byte_count' -Default $null

    Add-Check "$Phase snapshot keeps the active project selected" (Test-BooleanTrue $activeProjectMatches) 'packagedRestore'
    Add-Check "$Phase snapshot keeps the project session recorded" (Test-BooleanTrue $projectSessionRecorded) 'packagedRestore'
    Add-Check "$Phase snapshot keeps per-pane model assignment mode" ($runtimeAssignmentMode -eq 'per-pane') 'packagedRestore'
    Add-Check "$Phase snapshot keeps focus layout and focused pane" ($shellLayout -eq 'focus' -and $shellFocusedPaneId -eq 'worker-2') 'packagedRestore'
    Add-Check "$Phase snapshot keeps a typed restore candidate" (Test-IntegerAtLeast $restoreCandidateCount 1) 'packagedRestore'
    Add-Check "$Phase snapshot reads restore candidate through desktop JSON-RPC" ($restoreCandidateTransport -eq 'desktop.session.restore_candidates' -and (Get-JsonPropertyValue -InputObject $candidate -Name 'source' -Default '') -eq 'desktop.session.restore_candidates') 'packagedRestore'
    Add-Check "$Phase snapshot keeps the normal restore candidate in candidate state" ($candidateRestoreState -eq 'candidate') 'packagedRestore'
    Add-Check "$Phase snapshot marks expired restore candidates as setup-required" ((Test-IntegerAtLeast $setupRequiredCandidateCount 1) -and $setupRequiredRestoreState -eq 'setup-required' -and $setupRequiredReason -eq 'agent-session-expired' -and (Test-JsonValuesAllEqual $setupRequiredPaneStates 'setup-required') -and (Test-JsonValuesAllEqual $setupRequiredPaneReasons 'agent-session-expired')) 'packagedRestore'
    Add-Check "$Phase snapshot does not show expired restore candidates as ready" ($setupRequiredRestoreState -ne 'ready' -and $setupRequiredRestoreState -ne 'candidate') 'packagedRestore'
    Add-Check "$Phase snapshot keeps worker-1 model assignment" ($workerOneModel -match 'gpt-5\.4') 'packagedRestore'
    Add-Check "$Phase snapshot keeps worker-2 Grok model assignment" ($workerTwoModel -match 'grok-4\.5') 'packagedRestore'
    Add-Check "$Phase restore candidate carries context and checkpoint refs" ((Test-NonEmptyString $contextCapsule) -and (Test-NonEmptyString $checkpoint)) 'packagedRestore'
    Add-Check "$Phase restore candidate stores transcript ring metadata only" ((Test-IntegerAtLeast $byteCount 1) -and ($sha -match '^[0-9a-f]{64}$')) 'packagedRestore'
    Add-Check "$Phase restore candidate does not store raw transcript" ((Test-BooleanFalse (Get-JsonPropertyValue -InputObject $transcriptRing -Name 'raw_transcript_stored' -Default $null)) -and (Test-BooleanFalse (Get-JsonPropertyValue -InputObject $privacy -Name 'raw_transcript_stored' -Default $null))) 'packagedRestore'
    Add-Check "$Phase restore candidate does not store local reference paths" (Test-BooleanFalse (Get-JsonPropertyValue -InputObject $privacy -Name 'local_reference_paths_stored' -Default $null)) 'packagedRestore'
}

$desktopE2E = Get-RepoContent 'winsmux-app/scripts/desktop-pane-e2e.mjs'
$desktopBackend = Get-RepoContent 'winsmux-app/src-tauri/src/desktop_backend.rs'
$desktopSessionRestore = Get-RepoContent 'winsmux-app/src-tauri/src/desktop_session_restore.rs'
$package = Get-RepoJson 'winsmux-app/package.json'
$workflow = Get-RepoContent '.github/workflows/test.yml'
$whitelist = Get-RepoContent '.githooks/pre-commit-whitelist.ps1'
$gitignore = Get-RepoContent '.gitignore'

$scripts = Get-JsonPropertyValue -InputObject $package -Name 'scripts' -Default $null
Add-ContainsAllCheck 'desktop E2E exposes packaged restore mode' $desktopE2E @(
    'PACKAGED_RESTORE_ONLY',
    '--packaged-restore-only',
    'desktop-packaged-restore-e2e',
    'exercisePackagedRestartRestore',
    'desktop.session.restore_candidates',
    'startPackagedDesktopApp',
    'stopProcessTree',
    'writeEvidence\(false'
) 'winsmux-app/scripts/desktop-pane-e2e.mjs'
Add-ContainsAllCheck 'desktop E2E records restart restore metadata without raw output tails' $desktopE2E @(
    'preRestart',
    'postRestart',
    'restoreCandidate',
    'setupRequiredCandidate',
    'setup-required',
    'agent-session-expired',
    '.psmux',
    'transcriptRingSummary',
    'raw_transcript_stored',
    'omitted-for-packaged-restore-privacy'
) 'winsmux-app/scripts/desktop-pane-e2e.mjs'
Add-ContainsAllCheck 'desktop E2E covers fast Grok assignment in packaged restore evidence' $desktopE2E @(
    'grok-build',
    'grok-4\.5',
    'worker-2'
) 'winsmux-app/scripts/desktop-pane-e2e.mjs'
Add-ContainsAllCheck 'desktop backend exposes session restore candidates through JSON-RPC' $desktopBackend @(
    'desktop.session.restore_candidates',
    'desktop_session_restore::json_rpc'
) 'winsmux-app/src-tauri/src/desktop_backend.rs'
Add-ContainsAllCheck 'desktop session restore module reads SessionRegistry restore metadata' $desktopSessionRestore @(
    'DesktopSessionRestoreCandidatePayload',
    '.psmux',
    'USERPROFILE',
    'HOME',
    'allow_outside_project',
    'restore_metadata_version',
    'raw_transcript_stored'
) 'winsmux-app/src-tauri/src/desktop_session_restore.rs'

Add-Check 'npm script runs the packaged restore E2E mode' ([string](Get-JsonPropertyValue -InputObject $scripts -Name 'test:desktop-packaged-restore-e2e' -Default '') -match 'desktop-pane-e2e\.mjs --packaged-restore-only') 'winsmux-app/package.json'
Add-Check 'npm script exposes packaged restore static gate' ([string](Get-JsonPropertyValue -InputObject $scripts -Name 'test:v03628-packaged-restore-static' -Default '') -match 'test-v03628-packaged-restore-gate\.ps1' -and [string](Get-JsonPropertyValue -InputObject $scripts -Name 'test:v03628-packaged-restore-static' -Default '') -notmatch '-RequireEvidence') 'winsmux-app/package.json'
Add-Check 'npm script exposes packaged restore release gate' ([string](Get-JsonPropertyValue -InputObject $scripts -Name 'test:v03628-packaged-restore-gate' -Default '') -match 'test-v03628-packaged-restore-gate\.ps1' -and [string](Get-JsonPropertyValue -InputObject $scripts -Name 'test:v03628-packaged-restore-gate' -Default '') -match '-RequireEvidence') 'winsmux-app/package.json'
Add-Check 'CI Pester matrix includes the packaged restore gate' ($workflow -match 'packaged-restore-v03628' -and $workflow -match 'tests/V03628PackagedRestoreGate\.Tests\.ps1') '.github/workflows/test.yml'
Add-Check 'pre-commit whitelist allows the packaged restore gate script' ($whitelist -match [regex]::Escape('scripts/test-v03628-packaged-restore-gate.ps1')) '.githooks/pre-commit-whitelist.ps1'
Add-Check 'pre-commit whitelist allows the packaged restore gate test' ($whitelist -match [regex]::Escape('tests/V03628PackagedRestoreGate.Tests.ps1')) '.githooks/pre-commit-whitelist.ps1'
Add-Check 'pre-commit whitelist allows the desktop session restore module' ($whitelist -match [regex]::Escape('winsmux-app/src-tauri/src/desktop_session_restore.rs')) '.githooks/pre-commit-whitelist.ps1'
Add-Check 'gitignore allows the packaged restore Pester wrapper' ($gitignore -match [regex]::Escape('!tests/V03628PackagedRestoreGate.Tests.ps1')) '.gitignore'

$evidenceMode = if ($RequireEvidence) { 'required' } else { 'static-wiring' }
$evidence = $null
if ($RequireEvidence) {
    $evidence = Get-RepoJson $EvidencePath
    Add-Check 'packaged restore evidence file exists and is valid JSON' ($null -ne $evidence) $EvidencePath
    Add-Check 'packaged restore evidence reports ok true' (Test-BooleanTrue (Get-JsonPropertyValue -InputObject $evidence -Name 'ok' -Default $null)) $EvidencePath
    Add-Check 'packaged restore evidence records the packaged restore mode' ((Get-JsonPropertyValue -InputObject $evidence -Name 'mode' -Default '') -eq 'packaged-restore-only') $EvidencePath
    $evidenceSource = Get-JsonPropertyValue -InputObject $evidence -Name 'source' -Default $null
    Add-Check 'packaged restore evidence was generated from the current git head' ((Get-JsonPropertyValue -InputObject $evidenceSource -Name 'git_head' -Default '') -eq $currentGitHead) $EvidencePath
    Add-Check 'packaged restore evidence records the E2E command that generated it' ((Get-JsonPropertyValue -InputObject $evidenceSource -Name 'command' -Default '') -eq 'npm --prefix winsmux-app run test:desktop-packaged-restore-e2e') $EvidencePath
    Add-Check 'packaged restore evidence omits native output tails' ((Get-JsonPropertyValue -InputObject $evidence -Name 'tauriOutputTail' -Default '') -eq '<omitted-for-packaged-restore-privacy>' -and (Get-JsonPropertyValue -InputObject $evidence -Name 'tauriErrorTail' -Default '') -eq '<omitted-for-packaged-restore-privacy>') $EvidencePath

    $packagedRestore = Get-JsonPropertyValue -InputObject $evidence -Name 'packagedRestore' -Default $null
    Test-RestoreSnapshot -Snapshot (Get-JsonPropertyValue -InputObject $packagedRestore -Name 'preRestart' -Default $null) -Phase 'pre-restart'
    Test-RestoreSnapshot -Snapshot (Get-JsonPropertyValue -InputObject $packagedRestore -Name 'postRestart' -Default $null) -Phase 'post-restart'

    $packagedRestoreJson = if ($null -eq $packagedRestore) { '' } else { $packagedRestore | ConvertTo-Json -Depth 20 }
    Add-Check 'packaged restore evidence redacts local filesystem paths' ($packagedRestoreJson -notmatch '([A-Za-z]:\\\\|/Users/|\\\\Users\\\\)') $EvidencePath
}

$requiredEvidenceClasses = @(
    'packaged-restore-e2e',
    'restart-state',
    'model-assignment',
    'restore-candidate',
    'setup-required-restore',
    'privacy'
)

$releaseGateInputs = @(
    [ordered]@{
        class                 = 'packaged-restore-e2e'
        command               = 'npm --prefix winsmux-app run test:desktop-packaged-restore-e2e'
        evidence              = 'winsmux-app/output/playwright/desktop-packaged-restore-e2e/desktop-pane-e2e.json'
        required_for_release  = $true
        validated_in_this_run = [bool]$RequireEvidence
    },
    [ordered]@{
        class                 = 'restart-state'
        command               = 'pwsh -NoProfile -File scripts/test-v03628-packaged-restore-gate.ps1 -Json -RequireEvidence'
        evidence              = 'preRestart and postRestart snapshots'
        required_for_release  = $true
        validated_in_this_run = [bool]$RequireEvidence
    },
    [ordered]@{
        class                 = 'model-assignment'
        command               = 'pwsh -NoProfile -File scripts/test-v03628-packaged-restore-gate.ps1 -Json -RequireEvidence'
        evidence              = 'workerAssignments include gpt-5.4 and grok-4.5'
        required_for_release  = $true
        validated_in_this_run = [bool]$RequireEvidence
    },
    [ordered]@{
        class                 = 'restore-candidate'
        command               = 'pwsh -NoProfile -File scripts/test-v03628-packaged-restore-gate.ps1 -Json -RequireEvidence'
        evidence              = 'desktop.session.restore_candidates typed candidate payload'
        required_for_release  = $true
        validated_in_this_run = [bool]$RequireEvidence
    },
    [ordered]@{
        class                 = 'setup-required-restore'
        command               = 'pwsh -NoProfile -File scripts/test-v03628-packaged-restore-gate.ps1 -Json -RequireEvidence'
        evidence              = 'expired restore candidate is setup-required and not ready'
        required_for_release  = $true
        validated_in_this_run = [bool]$RequireEvidence
    },
    [ordered]@{
        class                 = 'privacy'
        command               = 'pwsh -NoProfile -File scripts/test-v03628-packaged-restore-gate.ps1 -Json -RequireEvidence'
        evidence              = 'raw transcript and local path storage flags'
        required_for_release  = $true
        validated_in_this_run = [bool]$RequireEvidence
    }
)

$failedChecks = @($checks | Where-Object { -not $_.pass })
$allPass = ($failedChecks.Count -eq 0)
$releaseReady = ([bool]$RequireEvidence -and $allPass)
$missingReleaseInputs = @()
if (-not $RequireEvidence) {
    $missingReleaseInputs = @($requiredEvidenceClasses)
}

$result = [pscustomobject][ordered]@{
    gate_id                      = 'v03628-packaged-restore-gate'
    evidence_mode                = $evidenceMode
    release_ready                = $releaseReady
    release_gate_inputs_complete = ($RequireEvidence -and $allPass)
    missing_release_gate_inputs  = $missingReleaseInputs
    all_pass                     = $allPass
    failed_count                 = $failedChecks.Count
    check_count                  = $checks.Count
    required_evidence_classes    = $requiredEvidenceClasses
    release_gate_inputs          = $releaseGateInputs
    evidence_path                = $EvidencePath
    source                       = [ordered]@{
        git_head         = $currentGitHead
        command          = if ($RequireEvidence) {
            'pwsh -NoProfile -File scripts/test-v03628-packaged-restore-gate.ps1 -Json -RequireEvidence'
        } else {
            'pwsh -NoProfile -File scripts/test-v03628-packaged-restore-gate.ps1 -Json'
        }
        generated_at_utc = [datetime]::UtcNow.ToString('o')
    }
    checks                       = $checks
}

if ($Json) {
    $result | ConvertTo-Json -Depth 12
} else {
    $result | Format-List
}

if (-not $allPass) {
    exit 1
}
