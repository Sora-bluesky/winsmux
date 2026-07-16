Describe 'TASK781 Windows PowerShell runtime compatibility' -Tag @('Integration', 'Stateful') {
    BeforeAll {
        $script:Task781RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:Task781RuntimeScriptsDir = Join-Path $script:Task781RepoRoot 'winsmux-core\scripts'
    }

    It 'accepts valid managed runtime evidence through every PS5.1 JSON boundary' {
        $caseRoot = Join-Path $TestDrive 'task781-ps51-runtime'
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $childScriptPath = Join-Path $caseRoot 'validate-runtime.ps1'
        $projectDir = Join-Path $caseRoot 'project'

        $childScript = @'
param(
    [Parameter(Mandatory = $true)][string]$ScriptsDir,
    [Parameter(Mandatory = $true)][string]$ProjectDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-Utf8ProductionScriptBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RemoveDotSourcePrelude
    )

    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($RemoveDotSourcePrelude) {
        $content = (@($content -split "\r?\n") |
            Where-Object { $_ -cnotmatch '^\. \(Join-Path \$PSScriptRoot ' }) -join "`n"
    }
    return [scriptblock]::Create($content)
}

function Get-Utf8ProductionFunctionBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $content,
        $Path,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -ne 0) { throw "UTF-8 parse failed for $Path" }
    $function = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true)
    if ($null -eq $function) { throw "Function $Name not found in $Path" }
    return [scriptblock]::Create($function.Extent.Text)
}

$jsonCompatBlock = Get-Utf8ProductionScriptBlock -Path (Join-Path $ScriptsDir 'json-compat.ps1')
. $jsonCompatBlock
$clmSafeIoBlock = Get-Utf8ProductionScriptBlock -Path (Join-Path $ScriptsDir 'clm-safe-io.ps1')
. $clmSafeIoBlock
$manifestBlock = Get-Utf8ProductionScriptBlock -Path (Join-Path $ScriptsDir 'manifest.ps1') -RemoveDotSourcePrelude
. $manifestBlock
$paneControlBlock = Get-Utf8ProductionScriptBlock -Path (Join-Path $ScriptsDir 'pane-control.ps1') -RemoveDotSourcePrelude
. $paneControlBlock

New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
$markerPath = Join-Path $ProjectDir 'worker-1-bootstrap.json'
$supervisorStartedAt = '2026-07-15T00:00:00.0000000Z'
$bootstrapStartedAt = '2026-07-15T00:00:01.0000000Z'
$marker = [PSCustomObject][ordered]@{
                state                        = 'bootstrap_pending'
    generation_id                = 'generation-ps51'
    server_session_id            = '$9'
    slot_id                      = 'worker-1'
    pane_id                      = '%2'
    backend                      = 'codex'
    role                         = 'reviewer'
    title                        = 'W1 Codex Reviewer'
    bootstrap_pid                = 4200
    bootstrap_process_started_at = $bootstrapStartedAt
}
[System.IO.File]::WriteAllText(
    $markerPath,
    ($marker | ConvertTo-Json -Depth 8),
    [System.Text.UTF8Encoding]::new($false)
)

$manifest = [PSCustomObject][ordered]@{
    version  = 2
    saved_at = '2026-07-15T00:00:02.0000000Z'
    session  = [PSCustomObject][ordered]@{
        name                = 'winsmux-task781-ps51'
        generation_id       = 'generation-ps51'
        server_session_id   = '$9'
        bootstrap_pane_id   = '%1'
        expected_pane_count = 1
        session_ready       = $true
    }
    panes = [ordered]@{
        'worker-1' = [ordered]@{
            slot_id               = 'worker-1'
            pane_id               = '%2'
            worker_backend        = 'codex'
            worker_role           = 'reviewer'
            role                  = 'Reviewer'
            title                 = 'W1 Codex Reviewer'
            status                = 'starting'
            runtime_ready         = $false
            bootstrap_marker_path = $markerPath
        }
    }
    tasks = [PSCustomObject][ordered]@{
        queued      = @()
        in_progress = @()
        completed   = @()
    }
    worktrees = [ordered]@{}
}
Save-WinsmuxManifest -ProjectDir $ProjectDir -Manifest $manifest | Out-Null

        $runtimePane = [PSCustomObject][ordered]@{
    label                        = 'worker-1'
    slot_id                      = 'worker-1'
    pane_id                      = '%2'
    backend                      = 'codex'
    role                         = 'reviewer'
    title                        = 'W1 Codex Reviewer'
            state                        = 'live'
    bootstrap_pid                = 4200
    bootstrap_process_started_at = $bootstrapStartedAt
    marker_path                  = $markerPath
}
$registry = New-WinsmuxRuntimeRegistryDocument `
    -SessionName 'winsmux-task781-ps51' `
    -ServerSessionId '$9' `
    -BootstrapPaneId '%1' `
    -GenerationId 'generation-ps51' `
    -SupervisorPid 4100 `
    -SupervisorProcessStartedAt $supervisorStartedAt `
    -ExpectedPaneCount 1 `
    -Panes @($runtimePane) `
    -Now (Get-Date) `
    -LeaseSeconds 300
Save-WinsmuxRuntimeRegistry -ProjectDir $ProjectDir -Registry $registry | Out-Null

$processResolver = {
    param([int]$Id)
    switch ($Id) {
        4100 { return [PSCustomObject]@{ Id = 4100; StartTime = [datetime]'2026-07-15T00:00:00Z'; ParentProcessId = 1; Name = 'powershell.exe' } }
        4200 { return [PSCustomObject]@{ Id = 4200; StartTime = [datetime]'2026-07-15T00:00:01Z'; ParentProcessId = 1; Name = 'powershell.exe' } }
        default { return $null }
    }
}

$results = [System.Collections.Generic.List[object]]::new()
try {
    $read = Read-WinsmuxRuntimeRegistry -ProjectDir $ProjectDir
    if ([string]$read.generation_id -cne 'generation-ps51') { throw 'registry generation mismatch' }
    $results.Add([PSCustomObject]@{ surface = 'registry'; passed = $true; diagnostic = '' }) | Out-Null
} catch {
    $results.Add([PSCustomObject]@{ surface = 'registry'; passed = $false; diagnostic = $_.Exception.Message }) | Out-Null
}

function Invoke-PaneControlWinsmux {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    return @(
        ('$9' + "`t" + 'winsmux-task781-ps51' + "`t" + '%1' + "`t" + 'winsmux-orchestra-bootstrap'),
        ('$9' + "`t" + 'winsmux-task781-ps51' + "`t" + '%2' + "`t" + 'W1 Codex Reviewer')
    )
}
$manifestEntry = [PSCustomObject][ordered]@{
    Label               = 'worker-1'
    SlotId              = 'worker-1'
    PaneId              = '%2'
    WorkerBackend       = 'codex'
    WorkerRole          = 'reviewer'
    Role                = 'Reviewer'
    Title               = 'W1 Codex Reviewer'
    Status              = 'starting'
    BootstrapMarkerPath = $markerPath
}
try {
    $validation = Test-PaneControlRuntimeContext -ProjectDir $ProjectDir -ManifestEntry $manifestEntry `
        -Operation dispatch -ProcessResolver $processResolver
    if (-not $validation.valid) { throw $validation.diagnostic }
    $results.Add([PSCustomObject]@{ surface = 'pane-control'; passed = $true; diagnostic = '' }) | Out-Null
} catch {
    $results.Add([PSCustomObject]@{ surface = 'pane-control'; passed = $false; diagnostic = $_.Exception.Message }) | Out-Null
}

try {
    $policy = ConvertFrom-PaneControlSecurityPolicy -Value '{"allow":["send"]}'
    if ($policy -isnot [System.Collections.IDictionary] -or
        @($policy['allow']).Count -ne 1 -or [string]@($policy['allow'])[0] -cne 'send') {
        throw 'pane-control policy projection mismatch'
    }
    $results.Add([PSCustomObject]@{ surface = 'pane-control-policy'; passed = $true; diagnostic = '' }) | Out-Null
} catch {
    $results.Add([PSCustomObject]@{ surface = 'pane-control-policy'; passed = $false; diagnostic = $_.Exception.Message }) | Out-Null
}

$supervisorFunctionBlock = Get-Utf8ProductionFunctionBlock `
    -Path (Join-Path $ScriptsDir 'orchestra-supervisor.ps1') `
    -Name 'New-OrchestraSupervisorRuntimePanes'
. $supervisorFunctionBlock
try {
    $supervisorPanes = @(New-OrchestraSupervisorRuntimePanes -Manifest $manifest `
        -GenerationId 'generation-ps51' -ServerSessionId '$9' -ProcessResolver $processResolver)
    if ($supervisorPanes.Count -ne 1 -or [string]$supervisorPanes[0].pane_id -cne '%2') {
        throw 'supervisor pane projection mismatch'
    }
    $results.Add([PSCustomObject]@{ surface = 'supervisor'; passed = $true; diagnostic = '' }) | Out-Null
} catch {
    $results.Add([PSCustomObject]@{ surface = 'supervisor'; passed = $false; diagnostic = $_.Exception.Message }) | Out-Null
}

$failed = @($results | Where-Object { -not $_.passed }).Count
[PSCustomObject][ordered]@{
    host_version = $PSVersionTable.PSVersion.ToString()
    passed       = ($failed -eq 0)
    results      = @($results)
} | ConvertTo-Json -Depth 6 -Compress
if ($failed -ne 0) { exit 1 }
'@
        [System.IO.File]::WriteAllText($childScriptPath, $childScript, [System.Text.UTF8Encoding]::new($false))

        $output = @(& powershell.exe -NoProfile -File $childScriptPath `
            -ScriptsDir $script:Task781RuntimeScriptsDir -ProjectDir $projectDir 2>&1)
        $exitCode = $LASTEXITCODE
        $jsonLine = @($output | Where-Object { ([string]$_).TrimStart().StartsWith('{') } | Select-Object -Last 1)
        $jsonLine.Count | Should -Be 1 -Because (($output | Out-String).Trim())
        $result = ([string]$jsonLine[0]) | ConvertFrom-Json

        $result.host_version | Should -Match '^5\.1\.'
        $result.passed | Should -BeTrue -Because (($result.results | ConvertTo-Json -Depth 6) + "`nexit=$exitCode")
        @($result.results | Where-Object passed).Count | Should -Be 4
        $exitCode | Should -Be 0
    }

    It 'accepts a valid production deferred-start plan under PowerShell 5.1' {
        $caseRoot = Join-Path $TestDrive 'task781-ps51-deferred-plan'
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $childScriptPath = Join-Path $caseRoot 'validate-deferred-plan.ps1'
        $bridgePath = Join-Path $script:Task781RepoRoot 'scripts\winsmux-core.ps1'
        $planPath = Join-Path $caseRoot 'deferred-plan.json'

        [System.IO.File]::WriteAllText(
            $planPath,
            (([ordered]@{
                approved_launch  = [ordered]@{ agent = 'codex'; command = @('codex') }
                ready_marker_path = (Join-Path $caseRoot 'ready.json')
                agent             = 'codex'
            }) | ConvertTo-Json -Depth 6),
            [System.Text.UTF8Encoding]::new($false)
        )

        $childScript = @'
param(
    [Parameter(Mandatory = $true)][string]$BridgePath,
    [Parameter(Mandatory = $true)][string]$JsonCompatPath,
    [Parameter(Mandatory = $true)][string]$ProjectDir,
    [Parameter(Mandatory = $true)][string]$PlanPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. $JsonCompatPath

function Get-SendConfigValue {
    param($InputObject, [string]$Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($Name)) {
        return $InputObject[$Name]
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}
function Test-DeferredPaneStartManifestEntry { return $true }
function Get-WinsmuxRuntimeStatusClassification {
    [PSCustomObject]@{ NormalizedStatus = 'deferred_starting'; CanStartDeferred = $false; IsStarting = $true }
}
function ConvertTo-ReadinessAgentName { param([string]$Agent) return $Agent }
function Get-WorkersLaunchApprovalDifferences { return @() }
function Format-WorkersLaunchApprovalMismatch { return 'unexpected mismatch' }
function Wait-DeferredPaneReady { }
function Assert-WinsmuxTargetRuntimeWriteAllowed {
    [PSCustomObject]@{ GenerationId = 'generation-ps51' }
}
function Get-PaneControlManifestContext { return $script:ManifestEntry }
function Wait-PaneControlRuntimeContext {
    [PSCustomObject]@{ valid = $true; reason_code = ''; diagnostic = '' }
}
function Set-DeferredPaneStartStatus {
    param([string]$Status)
    $script:LastDeferredStatus = $Status
}

$content = [System.IO.File]::ReadAllText($BridgePath, [System.Text.Encoding]::UTF8)
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput(
    $content,
    $BridgePath,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -ne 0) { throw 'bridge UTF-8 parse failed' }
$function = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Start-DeferredPaneFromManifestEntry'
}, $true)
if ($null -eq $function) { throw 'production deferred-start function not found' }
. ([scriptblock]::Create($function.Extent.Text))

$script:LastDeferredStatus = ''
$script:ManifestEntry = [PSCustomObject][ordered]@{
    Label             = 'worker-1'
    PaneId            = '%2'
    Status            = 'deferred_starting'
    BootstrapPlanPath = $PlanPath
    CapabilityAdapter = 'codex'
    ApprovedLaunch    = [PSCustomObject][ordered]@{ agent = 'codex'; command = @('codex') }
}
$started = Start-DeferredPaneFromManifestEntry `
    -ProjectDir $ProjectDir `
    -ManifestEntry $script:ManifestEntry `
    -ExpectedGenerationId 'generation-ps51'

[PSCustomObject]@{
    host_version = $PSVersionTable.PSVersion.ToString()
    started = $started
    final_status = $script:LastDeferredStatus
} | ConvertTo-Json -Compress
if (-not $started -or $script:LastDeferredStatus -cne 'ready') { exit 1 }
'@
        [System.IO.File]::WriteAllText($childScriptPath, $childScript, [System.Text.UTF8Encoding]::new($false))
        $output = @(& powershell.exe -NoProfile -File $childScriptPath `
            -BridgePath $bridgePath `
            -JsonCompatPath (Join-Path $script:Task781RuntimeScriptsDir 'json-compat.ps1') `
            -ProjectDir $caseRoot `
            -PlanPath $planPath 2>&1)
        $exitCode = $LASTEXITCODE
        $jsonLine = @($output | Where-Object { ([string]$_).TrimStart().StartsWith('{') } | Select-Object -Last 1)
        $jsonLine.Count | Should -Be 1 -Because (($output | Out-String).Trim())
        $result = ([string]$jsonLine[0]) | ConvertFrom-Json
        $result.host_version | Should -Match '^5\.1\.'
        $result.started | Should -BeTrue -Because (($output | Out-String).Trim())
        $result.final_status | Should -Be 'ready'
        $exitCode | Should -Be 0
    }

    It 'accepts a valid orchestra-start bootstrap marker under PowerShell 5.1' {
        $caseRoot = Join-Path $TestDrive 'task781-ps51-orchestra-start'
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $childScriptPath = Join-Path $caseRoot 'validate-orchestra-start.ps1'
        $childScript = @'
param(
    [Parameter(Mandatory = $true)][string]$ScriptsDir,
    [Parameter(Mandatory = $true)][string]$CaseRoot
)
$ErrorActionPreference = 'Stop'
. (Join-Path $ScriptsDir 'json-compat.ps1')
$path = Join-Path $ScriptsDir 'orchestra-start.ps1'
$text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput(
    $text,
    $path,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -ne 0) { throw 'orchestra-start UTF-8 parse failed' }
$function = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Test-OrchestraBootstrapMarker'
}, $true)
if ($null -eq $function) { throw 'orchestra-start marker function not found' }
. ([scriptblock]::Create($function.Extent.Text))

$markerPath = Join-Path $CaseRoot 'marker.json'
[System.IO.File]::WriteAllText(
    $markerPath,
    (([ordered]@{ launch_dir = $CaseRoot }) | ConvertTo-Json),
    [System.Text.UTF8Encoding]::new($false)
)
$valid = Test-OrchestraBootstrapMarker `
    -BootstrapMarkerPath $markerPath `
    -ExpectedLaunchDir $CaseRoot
[PSCustomObject]@{
    host_version = $PSVersionTable.PSVersion.ToString()
    valid = $valid
} | ConvertTo-Json -Compress
if (-not $valid) { exit 1 }
'@
        [System.IO.File]::WriteAllText($childScriptPath, $childScript, [System.Text.UTF8Encoding]::new($false))
        $output = @(& powershell.exe -NoProfile -File $childScriptPath `
            -ScriptsDir $script:Task781RuntimeScriptsDir -CaseRoot $caseRoot 2>&1)
        $exitCode = $LASTEXITCODE
        $jsonLine = @($output | Where-Object { ([string]$_).TrimStart().StartsWith('{') } | Select-Object -Last 1)
        $jsonLine.Count | Should -Be 1 -Because (($output | Out-String).Trim())
        $result = ([string]$jsonLine[0]) | ConvertFrom-Json
        $result.host_version | Should -Match '^5\.1\.'
        $result.valid | Should -BeTrue -Because (($output | Out-String).Trim())
        $exitCode | Should -Be 0
    }

    It 'accepts a valid production submission acknowledgement under PowerShell 5.1' {
        $caseRoot = Join-Path $TestDrive 'task781-ps51-submission-ack'
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $childScriptPath = Join-Path $caseRoot 'validate-submission-ack.ps1'
        $projectDir = Join-Path $caseRoot 'project'
        $submissionContractPath = Join-Path $script:Task781RuntimeScriptsDir 'submission-contract.ps1'

        $childScript = @'
param(
    [Parameter(Mandatory = $true)][string]$SubmissionContractPath,
    [Parameter(Mandatory = $true)][string]$ProjectDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. $SubmissionContractPath

function Get-PaneControlManifestEntries {
    return @([PSCustomObject][ordered]@{
        Label         = 'worker-1'
        SlotId        = 'worker-1'
        PaneId        = '%2'
        Role          = 'Worker'
        WorkerRole    = 'worker'
        WorkerBackend = 'codex'
        Title         = 'W1 Codex Worker'
        Status        = 'ready'
    })
}

function Test-PaneControlRuntimeContext {
    return [PSCustomObject][ordered]@{
        valid       = $true
        reason_code = 'live_runtime_verified'
        diagnostic = 'verified by the PS5.1 boundary fixture'
    }
}

New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
$submissionId = 'submission-task781-ps51-ack'
New-WinsmuxSubmissionPacket `
    -ProjectDir $ProjectDir `
    -Kind task `
    -Content ([ordered]@{
        title = 'TASK781 PS5.1 acknowledgement'
        request = 'Exercise the production acknowledgement JSON boundary.'
    }) `
    -SubmissionId $submissionId `
    -TargetLabel worker-1 | Out-Null

$receipt = Invoke-WinsmuxSubmissionAcknowledge `
    -ProjectDir $ProjectDir `
    -SlotId worker-1 `
    -SubmissionId $submissionId `
    -RunId $submissionId `
    -Kind task `
    -Backend codex

[PSCustomObject][ordered]@{
    host_version = $PSVersionTable.PSVersion.ToString()
    status       = [string]$receipt.status
    reason_code  = [string]$receipt.reason_code
} | ConvertTo-Json -Compress
if ([string]$receipt.status -cne 'accepted') { exit 1 }
'@
        [System.IO.File]::WriteAllText($childScriptPath, $childScript, [System.Text.UTF8Encoding]::new($false))

        $output = @(& powershell.exe -NoProfile -File $childScriptPath `
            -SubmissionContractPath $submissionContractPath -ProjectDir $projectDir 2>&1)
        $exitCode = $LASTEXITCODE
        $jsonLine = @($output | Where-Object { ([string]$_).TrimStart().StartsWith('{') } | Select-Object -Last 1)
        $jsonLine.Count | Should -Be 1 -Because (($output | Out-String).Trim())
        $result = ([string]$jsonLine[0]) | ConvertFrom-Json

        $result.host_version | Should -Match '^5\.1\.'
        $result.status | Should -Be 'accepted' -Because (($output | Out-String).Trim())
        $result.reason_code | Should -Be ''
        $exitCode | Should -Be 0
    }

    It 'has no PS5.1-incompatible native JSON parameters outside the shared boundary' {
        $productionPaths = @(
            (Join-Path $script:Task781RepoRoot 'scripts\winsmux-core.ps1')
            (Get-ChildItem -LiteralPath $script:Task781RuntimeScriptsDir -Filter '*.ps1' -File |
                Select-Object -ExpandProperty FullName)
        )
        $incompatible = [System.Collections.Generic.List[string]]::new()
        foreach ($path in $productionPaths) {
            $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput(
                $content,
                $path,
                [ref]$tokens,
                [ref]$parseErrors
            )
            @($parseErrors).Count | Should -Be 0 -Because $path
            foreach ($command in @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -ceq 'ConvertFrom-Json'
            }, $true))) {
                $unsupported = @($command.CommandElements |
                    Where-Object {
                        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                        $_.ParameterName -in @('Depth', 'AsHashtable')
                    })
                if ($unsupported.Count -gt 0) {
                    $incompatible.Add(('{0}:{1}' -f $path, $command.Extent.StartLineNumber)) | Out-Null
                }
            }
        }
        @($incompatible) | Should -Be @()

        $submissionContent = [System.IO.File]::ReadAllText(
            (Join-Path $script:Task781RuntimeScriptsDir 'submission-contract.ps1'),
            [System.Text.Encoding]::UTF8
        )
        $submissionContent | Should -Not -Match '\|\s*ConvertFrom-Json'
        $submissionContent | Should -Match 'ConvertFrom-WinsmuxJson -Depth 16'
    }

    It 'uses explicit ordinal equality for every production generation identity comparison' {
        $productionPaths = @(
            (Join-Path $script:Task781RepoRoot 'scripts\winsmux-core.ps1')
            (Get-ChildItem -LiteralPath $script:Task781RuntimeScriptsDir -Filter '*.ps1' -File |
                Select-Object -ExpandProperty FullName)
        )
        $implicitComparisons = [System.Collections.Generic.List[string]]::new()
        foreach ($path in $productionPaths) {
            $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput(
                $content,
                $path,
                [ref]$tokens,
                [ref]$parseErrors
            )
            @($parseErrors).Count | Should -Be 0 -Because $path
            foreach ($comparison in @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                    $node.Operator -in @('Ieq', 'Ceq', 'Ine', 'Cne') -and
                    $node.Extent.Text -match '(?i)generation'
            }, $true))) {
                $implicitComparisons.Add(('{0}:{1}:{2}' -f
                    $path,
                    $comparison.Extent.StartLineNumber,
                    $comparison.Extent.Text.Trim())) | Out-Null
            }
        }

        @($implicitComparisons) | Should -Be @() `
            -Because 'generation IDs are exact identity tokens and must use StringComparison.Ordinal'
    }

    It 'provides nested hashtables through the shared JSON boundary on PowerShell 5.1' {
        $jsonCompatPath = Join-Path $script:Task781RuntimeScriptsDir 'json-compat.ps1'
        $childScriptPath = Join-Path $TestDrive 'validate-json-compat.ps1'
        $childScript = @'
param([string]$JsonCompatPath)
. $JsonCompatPath
$value = '{"outer":{"items":[{"name":"one"}]}}' | ConvertFrom-WinsmuxJson -AsHashtable -Depth 8
[PSCustomObject]@{
    host = $PSVersionTable.PSVersion.ToString()
    root_dictionary = ($value -is [System.Collections.IDictionary])
    nested_dictionary = ($value['outer'] -is [System.Collections.IDictionary])
    name = [string]$value['outer']['items'][0]['name']
} | ConvertTo-Json -Compress
'@
        [System.IO.File]::WriteAllText($childScriptPath, $childScript, [System.Text.UTF8Encoding]::new($false))
        $output = @(& powershell.exe -NoProfile -File $childScriptPath -JsonCompatPath $jsonCompatPath 2>&1)
        $exitCode = $LASTEXITCODE
        $jsonLine = @($output | Where-Object { ([string]$_).TrimStart().StartsWith('{') } | Select-Object -Last 1)
        $jsonLine.Count | Should -Be 1 -Because (($output | Out-String).Trim())
        $result = ([string]$jsonLine[0]) | ConvertFrom-Json
        $result.host | Should -Match '^5\.1\.'
        $result.root_dictionary | Should -BeTrue
        $result.nested_dictionary | Should -BeTrue
        $result.name | Should -Be 'one'
        $exitCode | Should -Be 0
    }

    It 'loads orchestra-start Vault preflight through the modular native type in a fresh process' {
        $caseRoot = Join-Path $TestDrive 'task781-fresh-vault-preflight'
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $childScriptPath = Join-Path $caseRoot 'fresh-vault-preflight.ps1'
        $childScript = @'
param([Parameter(Mandatory = $true)][string]$ScriptsDir)
$ErrorActionPreference = 'Stop'
. (Join-Path $ScriptsDir 'orchestra-start.ps1')

if (-not ('Task781VaultCleanupNative' -as [type])) {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;

public static class Task781VaultCleanupNative {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredDelete(string target, uint type, uint flags);
}
"@
}

$key = 'winsmux-test:task781-fresh-{0}' -f [guid]::NewGuid().ToString('N')
$target = 'winsmux:{0}' -f $key
$before = Test-VaultKeyExists -Key $key
$afterSet = $false
$deleted = $false
try {
    Set-VaultKey -Key $key -Value 'fresh-process-value'
    $afterSet = Test-VaultKeyExists -Key $key
} finally {
    $deleted = [Task781VaultCleanupNative]::CredDelete($target, 1, 0)
}
$afterDelete = Test-VaultKeyExists -Key $key

[PSCustomObject]@{
    modular_type = ('WinsmuxVaultCredentialNative' -as [type]).FullName
    legacy_type_absent = ($null -eq ('WinCred' -as [type]))
    before = $before
    after_set = $afterSet
    deleted = $deleted
    after_delete = $afterDelete
} | ConvertTo-Json -Compress
'@
        [System.IO.File]::WriteAllText($childScriptPath, $childScript, [System.Text.UTF8Encoding]::new($false))

        $output = @(& pwsh.exe -NoProfile -File $childScriptPath -ScriptsDir $script:Task781RuntimeScriptsDir 2>&1)
        $exitCode = $LASTEXITCODE
        $jsonLine = @($output | Where-Object { ([string]$_).TrimStart().StartsWith('{') } | Select-Object -Last 1)
        $jsonLine.Count | Should -Be 1 -Because (($output | Out-String).Trim())
        $result = ([string]$jsonLine[0]) | ConvertFrom-Json
        $result.modular_type | Should -Be 'WinsmuxVaultCredentialNative'
        $result.legacy_type_absent | Should -BeTrue
        $result.before | Should -BeFalse
        $result.after_set | Should -BeTrue
        $result.deleted | Should -BeTrue
        $result.after_delete | Should -BeFalse
        $exitCode | Should -Be 0
    }

    It 'enumerates Vault names through a metadata-only boundary' {
        $metadataPath = Join-Path $script:Task781RuntimeScriptsDir 'credential-metadata.ps1'
        . $metadataPath
        Mock Invoke-WinsmuxCredentialMetadataCommand {
            @(
                'Target: LegacyGeneric:target=winsmux:BETA'
                'ターゲット: LegacyGeneric:target=winsmux:ALPHA'
                'User: private-user'
                'Target: LegacyGeneric:target=other:IGNORED'
            )
        }
        @(Get-WinsmuxCredentialTargetNames) | Should -Be @('ALPHA', 'BETA')

        $metadataContent = [System.IO.File]::ReadAllText($metadataPath, [System.Text.Encoding]::UTF8)
        $metadataContent | Should -Not -Match 'CredEnumerate|CredRead|CredentialBlob'

        $bridgePath = Join-Path $script:Task781RepoRoot 'scripts\winsmux-core.ps1'
        $bridgeContent = [System.IO.File]::ReadAllText($bridgePath, [System.Text.Encoding]::UTF8)
        $tokens = $null
        $parseErrors = $null
        $bridgeAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $bridgeContent,
            $bridgePath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $nameReader = $bridgeAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Get-WinsmuxVaultCredentialNamesInternal'
        }, $true)
        $nameReader.Extent.Text | Should -Match 'Get-WinsmuxCredentialTargetNames'
        $nameReader.Extent.Text | Should -Not -Match 'CredEnumerate|CredRead|CredentialBlob'

        $vaultModulePath = Join-Path $script:Task781RuntimeScriptsDir 'vault.ps1'
        $vaultModuleContent = [System.IO.File]::ReadAllText($vaultModulePath, [System.Text.Encoding]::UTF8)
        $vaultModuleContent | Should -Not -Match 'CredEnumerate|CredentialBlob.*foreach|foreach.*CredentialBlob'
        $vaultTokens = $null
        $vaultParseErrors = $null
        $vaultAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $vaultModuleContent,
            $vaultModulePath,
            [ref]$vaultTokens,
            [ref]$vaultParseErrors
        )
        $vaultInject = $vaultAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Invoke-VaultInject'
        }, $true)
        $vaultInject.Extent.Text | Should -Match 'Get-WinsmuxCredentialTargetNames'
        $vaultInject.Extent.Text | Should -Match '(?s)foreach.*credentialNames'
        $vaultInject.Extent.Text | Should -Match 'Get-WinsmuxVaultCredentialValue'
    }
}

Describe 'TASK782 verified review identity' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\pane-control.ps1')
    }

    BeforeEach {
        Mock Get-PaneControlManifestContext {
            [PSCustomObject][ordered]@{
                ManifestPath = 'C:\repo\.winsmux\manifest.yaml'; GenerationId = 'generation-current'; ProjectDir = 'C:\repo'
                Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; WorkerBackend = 'codex'; WorkerRole = 'reviewer'
                Role = 'Worker'; Title = 'W1 Codex Reviewer'
                ApprovedLaunch = [ordered]@{ agent = 'codex'; worker_backend = 'codex'; worker_role = 'reviewer' }
            }
        }
        Mock Test-PaneControlRuntimeContext {
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' -Diagnostic 'verified' -Context ([PSCustomObject][ordered]@{
                generation_id = 'generation-current'; server_session_id = '$1'; slot_id = 'worker-1'; pane_id = '%2'
                backend = 'codex'; role = 'reviewer'; title = 'W1 Codex Reviewer'
            })
        }
    }

    It 'binds the manifest-selected reviewer agent to the live runtime generation' {
        $identity = Get-PaneControlVerifiedReviewIdentity -ProjectDir 'C:\repo' -PaneId '%2'
        $identity.PaneId | Should -Be '%2'
        $identity.Role | Should -Be 'reviewer'
        $identity.AgentName | Should -Be 'codex'
        $identity.Backend | Should -Be 'codex'
        $identity.GenerationId | Should -Be 'generation-current'
        $identity.ServerSessionId | Should -Be '$1'
        Should -Invoke Test-PaneControlRuntimeContext -Times 1 -Exactly -ParameterFilter { $Operation -eq 'caller_ack' }
    }

    It 'rejects a mutable pane claim when caller ancestry is not verified' {
        Mock Test-PaneControlRuntimeContext {
            New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'caller_identity_mismatch' -Diagnostic 'unrelated caller'
        }
        { Get-PaneControlVerifiedReviewIdentity -ProjectDir 'C:\repo' -PaneId '%2' } | Should -Throw '*caller_identity_mismatch*'
    }

    It 'rejects a live pane that is not review-capable' {
        Mock Test-PaneControlRuntimeContext {
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' -Diagnostic 'verified' -Context ([PSCustomObject][ordered]@{
                generation_id = 'generation-current'; server_session_id = '$1'; slot_id = 'worker-1'; pane_id = '%2'
                backend = 'codex'; role = 'builder'; title = 'Builder'
            })
        }
        { Get-PaneControlVerifiedReviewIdentity -ProjectDir 'C:\repo' -PaneId '%2' } | Should -Throw '*not review-capable*'
    }

    It 'rejects a backend without authenticated caller ancestry' {
        Mock Get-PaneControlManifestContext {
            [PSCustomObject][ordered]@{
                ManifestPath = 'C:\repo\.winsmux\manifest.yaml'; GenerationId = 'generation-current'; ProjectDir = 'C:\repo'
                Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; WorkerBackend = 'api_llm'; WorkerRole = 'reviewer'
                Role = 'Worker'; Title = 'API Reviewer'
                ApprovedLaunch = [ordered]@{ agent = 'api-reviewer'; worker_backend = 'api_llm'; worker_role = 'reviewer' }
            }
        }
        Mock Test-PaneControlRuntimeContext {
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' -Diagnostic 'verified' -Context ([PSCustomObject][ordered]@{
                generation_id = 'generation-current'; server_session_id = '$1'; slot_id = 'worker-1'; pane_id = '%2'
                backend = 'api_llm'; role = 'reviewer'; title = 'API Reviewer'
            })
        }
        { Get-PaneControlVerifiedReviewIdentity -ProjectDir 'C:\repo' -PaneId '%2' } | Should -Throw '*no authenticated caller-ancestry contract*'
    }

    It 'rejects approved-launch metadata without an agent identity' {
        Mock Get-PaneControlManifestContext {
            [PSCustomObject][ordered]@{
                ManifestPath = 'C:\repo\.winsmux\manifest.yaml'; GenerationId = 'generation-current'; ProjectDir = 'C:\repo'
                Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; WorkerBackend = 'codex'; WorkerRole = 'reviewer'
                Role = 'Worker'; Title = 'W1 Codex Reviewer'; ApprovedLaunch = [ordered]@{}
            }
        }
        { Get-PaneControlVerifiedReviewIdentity -ProjectDir 'C:\repo' -PaneId '%2' } | Should -Throw '*agent identity*'
    }

    It 'rejects a generation change before the review-state write' {
        { Get-PaneControlVerifiedReviewIdentity -ProjectDir 'C:\repo' -PaneId '%2' -ExpectedGenerationId 'generation-old' } |
            Should -Throw '*generation changed*'
    }
}

Describe 'TASK782 review-state compare-and-swap' {
    BeforeAll {
        $corePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $content = [IO.File]::ReadAllText($corePath, [Text.Encoding]::UTF8)
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($content, $corePath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        foreach ($name in @('Get-ReviewStateEntryFingerprint', 'Save-VerifiedReviewStateTransition')) {
            $functionAst = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $true)
            $functionAst | Should -Not -BeNullOrEmpty
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }
        function Stop-WithError { param([string]$Message) throw $Message }
        function Invoke-WithReviewStateLock { param([string]$ProjectDir, [scriptblock]$Action) & $Action }
        function Get-ReviewState { param([string]$ProjectDir) [ordered]@{} }
        function Confirm-ReviewWriteContext {
            param($Context, [string]$ProjectDir, [string]$Branch, [string]$HeadSha)
            $Context
        }
        function Save-ReviewState { param($State, [string]$ProjectDir) }
    }

    BeforeEach {
        $script:lockedState = [ordered]@{}
        Mock Invoke-WithReviewStateLock { & $Action }
        Mock Get-ReviewState { $script:lockedState }
        Mock Confirm-ReviewWriteContext { $Context }
        Mock Save-ReviewState {}
    }

    It 'refuses a concurrent same-branch update before validation or save' {
        $script:lockedState['feature/review-gate'] = [ordered]@{ status = 'PENDING'; updatedAt = 'rival' }
        $newRecord = [ordered]@{ status = 'PASS'; updatedAt = 'candidate' }

        { Save-VerifiedReviewStateTransition -ProjectDir 'C:\repo' -Branch 'feature/review-gate' -HeadSha ('a' * 40) `
                -Context ([pscustomobject]@{}) -ExpectedEntryFingerprint '<absent>' -NewRecord $newRecord } |
            Should -Throw '*changed concurrently*'
        Should -Invoke Confirm-ReviewWriteContext -Times 0 -Exactly
        Should -Invoke Save-ReviewState -Times 0 -Exactly
        $script:lockedState['feature/review-gate'].updatedAt | Should -Be 'rival'
    }

    It 'preserves concurrent entries for other branches during a verified transition' {
        $script:lockedState['feature/other'] = [ordered]@{ status = 'PASS'; updatedAt = 'other' }
        $newRecord = [ordered]@{ status = 'PENDING'; updatedAt = 'candidate' }

        Save-VerifiedReviewStateTransition -ProjectDir 'C:\repo' -Branch 'feature/review-gate' -HeadSha ('a' * 40) `
            -Context ([pscustomobject]@{}) -ExpectedEntryFingerprint '<absent>' -NewRecord $newRecord | Out-Null

        Should -Invoke Confirm-ReviewWriteContext -Times 1 -Exactly
        Should -Invoke Save-ReviewState -Times 1 -Exactly -ParameterFilter {
            $State.Contains('feature/other') -and $State.Contains('feature/review-gate')
        }
        $script:lockedState['feature/other'].updatedAt | Should -Be 'other'
        $script:lockedState['feature/review-gate'].status | Should -Be 'PENDING'
    }
}
