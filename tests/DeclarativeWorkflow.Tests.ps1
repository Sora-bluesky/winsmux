$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

BeforeAll {
    $script:Task659RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Task659RuntimePath = Join-Path $script:Task659RepoRoot 'winsmux-core\scripts\declarative-workflow.ps1'
    $script:Task659DispatchPath = Join-Path $script:Task659RepoRoot 'winsmux-core\scripts\control-plane-dispatch.ps1'
    $script:Task659TeamPipelinePath = Join-Path $script:Task659RepoRoot 'winsmux-core\scripts\team-pipeline.ps1'
    $script:Task659BridgePath = Join-Path $script:Task659RepoRoot 'scripts\winsmux-core.ps1'

    function Stop-WithError {
        param([Parameter(Mandatory = $true)][string]$Message)
        throw $Message
    }

    . $script:Task659DispatchPath
    if (Test-Path -LiteralPath $script:Task659RuntimePath -PathType Leaf) {
        . $script:Task659RuntimePath
    }
    if (Test-Path -LiteralPath $script:Task659TeamPipelinePath -PathType Leaf) {
        . $script:Task659TeamPipelinePath
    }

    function Assert-Task659RuntimeLoaded {
        Get-Command Invoke-DeclarativeWorkflow -CommandType Function -ErrorAction Stop | Should -Not -BeNullOrEmpty
        Get-Command Set-DeclarativeWorkflowRunState -CommandType Function -ErrorAction Stop | Should -Not -BeNullOrEmpty
        Get-Command Write-DeclarativeWorkflowMailboxResult -CommandType Function -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }

    function Get-Task659Sha256 {
        param([Parameter(Mandatory = $true)][byte[]]$Bytes)

        $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)
        return 'sha256:' + (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    }

    function New-Task659WorkflowPlan {
        param(
            [string]$RunId = 'run-dw',
            [switch]$SingleNode
        )

        $nodes = @(
            [ordered]@{
                node_id = 'build'
                pane_ref = 'builder-1'
                depends_on = @()
                action = 'operator-dispatch'
                idempotency_key = "$RunId`:build"
            }
        )
        if (-not $SingleNode) {
            $nodes += [ordered]@{
                node_id = 'verify'
                pane_ref = 'reviewer'
                depends_on = @('build')
                action = 'operator-dispatch'
                idempotency_key = "$RunId`:verify"
            }
        }

        return [ordered]@{
            schema_version = 1
            config_fingerprint = 'sha256:' + ('1' * 64)
            recipe_id = 'bugfix-two-slot'
            workflow_id = 'bugfix'
            panes = @(
                [ordered]@{ pane_key = 'implement'; slot_id = 'builder-1' },
                [ordered]@{ pane_key = 'verify'; slot_id = 'reviewer' }
            )
            resolved_bindings = [ordered]@{
                implement = 'builder-1'
                verify = 'reviewer'
            }
            workflow = [ordered]@{
                schema_version = 1
                workflow_id = 'bugfix'
                recipe_ref = 'bugfix-two-slot'
                run_id = $RunId
                topological_order = @($nodes | ForEach-Object { $_.node_id })
                nodes = $nodes
            }
        }
    }

    function New-Task659Fixture {
        param(
            [string]$Name,
            [string]$RunId = 'run-dw',
            [switch]$SingleNode
        )

        $projectDir = Join-Path $TestDrive $Name
        $winsmuxDir = Join-Path $projectDir '.winsmux'
        [IO.Directory]::CreateDirectory($winsmuxDir) | Out-Null
        $taskFile = Join-Path $projectDir 'task.txt'
        $taskText = "TASK-659 durable task $Name"
        [IO.File]::WriteAllText($taskFile, $taskText, [Text.UTF8Encoding]::new($false))
        $plan = New-Task659WorkflowPlan -RunId $RunId -SingleNode:$SingleNode
        $identity = [ordered]@{
            session_name = 'winsmux-orchestra'
            generation_id = 'generation-dw'
            server_session_id = '$659'
        }
        $dispatches = [Collections.Generic.List[object]]::new()
        $workspacePlanInvoker = {
            param(
                [string]$RecipeId,
                [string]$WorkflowId,
                [string]$RequestedRunId,
                [string]$RequestedProjectDir
            )
            return $plan
        }.GetNewClosure()
        $manifestIdentityReader = {
            param([string]$RequestedProjectDir)
            return $identity
        }.GetNewClosure()
        $sourceHeadReader = {
            param([string]$RequestedProjectDir)
            return 'a' * 40
        }.GetNewClosure()
        $dispatchNode = {
            param(
                [Parameter(Mandatory = $true)]$Node,
                [Parameter(Mandatory = $true)][string]$TaskContent,
                [Parameter(Mandatory = $true)]$Run
            )
            $statePath = Join-Path $projectDir ".winsmux\workflow-runs\$RunId.json"
            $stateAtDispatch = [IO.File]::ReadAllText(
                $statePath,
                [Text.UTF8Encoding]::new($false, $true)
            ) | ConvertFrom-Json -Depth 30
            $dispatches.Add([ordered]@{
                    node_id = [string]$Node.node_id
                    pane_ref = [string]$Node.pane_ref
                    task_content = $TaskContent
                    state_exists = Test-Path -LiteralPath $statePath
                    state_at_dispatch = [string]$stateAtDispatch.nodes.([string]$Node.node_id).state
                }) | Out-Null
            return [ordered]@{ accepted = $true }
        }.GetNewClosure()

        return [PSCustomObject]@{
            ProjectDir = $projectDir
            TaskFile = $taskFile
            TaskText = $taskText
            RunId = $RunId
            Plan = $plan
            Identity = $identity
            Dispatches = $dispatches
            WorkspacePlanInvoker = $workspacePlanInvoker
            ManifestIdentityReader = $manifestIdentityReader
            SourceHeadReader = $sourceHeadReader
            DispatchNode = $dispatchNode
        }
    }

    function Invoke-Task659Start {
        param([Parameter(Mandatory = $true)]$Fixture)

        return Invoke-DeclarativeWorkflow `
            -Action start `
            -RecipeId 'bugfix-two-slot' `
            -WorkflowId 'bugfix' `
            -RunId $Fixture.RunId `
            -TaskFile $Fixture.TaskFile `
            -ProjectDir $Fixture.ProjectDir `
            -WorkspacePlanInvoker $Fixture.WorkspacePlanInvoker `
            -ManifestIdentityReader $Fixture.ManifestIdentityReader `
            -SourceHeadReader $Fixture.SourceHeadReader `
            -DispatchNode $Fixture.DispatchNode
    }

    function Invoke-Task659Resume {
        param(
            [Parameter(Mandatory = $true)]$Fixture,
            [scriptblock]$WorkspacePlanInvoker = $Fixture.WorkspacePlanInvoker,
            [scriptblock]$ManifestIdentityReader = $Fixture.ManifestIdentityReader,
            [scriptblock]$SourceHeadReader = $Fixture.SourceHeadReader
        )

        return Invoke-DeclarativeWorkflow `
            -Action resume `
            -RunId $Fixture.RunId `
            -TaskFile $Fixture.TaskFile `
            -ProjectDir $Fixture.ProjectDir `
            -WorkspacePlanInvoker $WorkspacePlanInvoker `
            -ManifestIdentityReader $ManifestIdentityReader `
            -SourceHeadReader $SourceHeadReader `
            -DispatchNode $Fixture.DispatchNode
    }

    function New-Task659CompletionEnvelope {
        param(
            [Parameter(Mandatory = $true)]$Fixture,
            [Parameter(Mandatory = $true)]$Run,
            [string]$NodeId = 'build',
            [ValidateSet('succeeded', 'failed')][string]$Outcome = 'succeeded',
            [string]$MessageId = 'msg-dw-success',
            [int]$ExitCode = 0
        )

        $node = $Run.nodes.$NodeId
        return [ordered]@{
            mailbox_version = 2
            message_id = $MessageId
            correlation_id = $MessageId
            causation_id = $null
            idempotency_key = "mailbox:v2:$($Fixture.RunId):$NodeId"
            message_type = 'workflow_result'
            state = 'created'
            ttl_seconds = 300
            ack_required = $true
            from = [string]$node.pane_ref
            to = 'Operator'
            content = [ordered]@{
                run_id = $Fixture.RunId
                node_id = $NodeId
                node_idempotency_key = [string]$node.idempotency_key
                session_name = [string]$Run.session.session_name
                generation_id = [string]$Run.session.generation_id
                server_session_id = [string]$Run.session.server_session_id
                workflow_fingerprint = [string]$Run.workflow_fingerprint
                task_digest = [string]$Run.task_digest
                outcome = $Outcome
                exit_code = $ExitCode
                result_digest = Get-Task659Sha256 -Bytes ([Text.Encoding]::UTF8.GetBytes("$Outcome`:$ExitCode`:$NodeId"))
            }
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }

    function Write-Task659MailboxEnvelope {
        param(
            [Parameter(Mandatory = $true)]$Fixture,
            [Parameter(Mandatory = $true)]$Envelope
        )

        return Write-DeclarativeWorkflowMailboxResult `
            -ProjectDir $Fixture.ProjectDir -RunId $Fixture.RunId -Payload $Envelope
    }

    function Send-Task659InternalResult {
        param(
            [Parameter(Mandatory = $true)]$Fixture,
            [string]$NodeId = 'build',
            [string]$Outcome = 'succeeded',
            [int]$ExitCode = 0
        )

        $output = & pwsh -NoProfile -File $script:Task659TeamPipelinePath `
            -WorkflowResult `
            -RunId $Fixture.RunId `
            -WorkflowResultNodeId $NodeId `
            -WorkflowResultOutcome $Outcome `
            -WorkflowResultExitCode $ExitCode `
            -ProjectDir $Fixture.ProjectDir `
            -AsJson 2>&1
        $processExitCode = $LASTEXITCODE
        return [PSCustomObject]@{
            ExitCode = $processExitCode
            Output = ($output | Out-String).Trim()
        }
    }

    function Start-Task659InternalResultProcess {
        param(
            [Parameter(Mandatory = $true)]$Fixture,
            [Parameter(Mandatory = $true)][string]$Label,
            [Parameter(Mandatory = $true)][string]$GoPath,
            [string]$NodeId = 'build',
            [string]$Outcome = 'succeeded',
            [int]$ExitCode = 0
        )

        $scriptPath = Join-Path $Fixture.ProjectDir "$Label-result-producer.ps1"
        $readyPath = Join-Path $Fixture.ProjectDir "$Label-result-ready.marker"
        $producerScript = @'
param(
    [Parameter(Mandatory = $true)][string]$TeamPipelinePath,
    [Parameter(Mandatory = $true)][string]$ProjectDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$NodeId,
    [Parameter(Mandatory = $true)][string]$Outcome,
    [Parameter(Mandatory = $true)][int]$ExitCode,
    [Parameter(Mandatory = $true)][string]$ReadyPath,
    [Parameter(Mandatory = $true)][string]$GoPath
)

$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText(
    $ReadyPath,
    'ready',
    [Text.UTF8Encoding]::new($false)
)
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath $GoPath -PathType Leaf)) {
    if ([DateTime]::UtcNow -ge $deadline) {
        throw 'result producer start barrier timeout.'
    }
    Start-Sleep -Milliseconds 10
}
& pwsh -NoProfile -File $TeamPipelinePath `
    -WorkflowResult `
    -RunId $RunId `
    -WorkflowResultNodeId $NodeId `
    -WorkflowResultOutcome $Outcome `
    -WorkflowResultExitCode $ExitCode `
    -ProjectDir $ProjectDir `
    -AsJson
exit $LASTEXITCODE
'@
        [IO.File]::WriteAllText(
            $scriptPath,
            $producerScript,
            [Text.UTF8Encoding]::new($false)
        )

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @(
                '-NoProfile',
                '-File', $scriptPath,
                '-TeamPipelinePath', $script:Task659TeamPipelinePath,
                '-ProjectDir', $Fixture.ProjectDir,
                '-RunId', $Fixture.RunId,
                '-NodeId', $NodeId,
                '-Outcome', $Outcome,
                '-ExitCode', $ExitCode,
                '-ReadyPath', $readyPath,
                '-GoPath', $GoPath
            )) {
            $startInfo.ArgumentList.Add([string]$argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            $process.Dispose()
            throw "Failed to start TASK-659 result producer $Label."
        }
        return [PSCustomObject]@{
            Process = $process
            ReadyPath = $readyPath
            GoPath = $GoPath
        }
    }

    function Wait-Task659ResultProducerReady {
        param(
            [Parameter(Mandatory = $true)]$Child,
            [int]$TimeoutSeconds = 10
        )

        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not (Test-Path -LiteralPath $Child.ReadyPath -PathType Leaf) -and
            [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 10
        }
        return Test-Path -LiteralPath $Child.ReadyPath -PathType Leaf
    }

    function Release-Task659ResultProducers {
        param([Parameter(Mandatory = $true)][string]$GoPath)

        [IO.File]::WriteAllText(
            $GoPath,
            'go',
            [Text.UTF8Encoding]::new($false)
        )
    }

    function Complete-Task659ResultProducer {
        param(
            [Parameter(Mandatory = $true)]$Child,
            [int]$TimeoutSeconds = 10
        )

        if (-not $Child.Process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $Child.Process.Id -Force -ErrorAction SilentlyContinue
            $null = $Child.Process.WaitForExit(5000)
        }
        $result = [PSCustomObject]@{
            ExitCode = $Child.Process.ExitCode
            StdOut = $Child.Process.StandardOutput.ReadToEnd()
            StdErr = $Child.Process.StandardError.ReadToEnd()
        }
        $Child.Process.Dispose()
        return $result
    }

    function Start-Task659DispatchOwnerProcess {
        param(
            [Parameter(Mandatory = $true)]$Fixture,
            [Parameter(Mandatory = $true)]
            [ValidateSet('crash-after-effect', 'hold-after-effect')]
            [string]$Mode
        )

        $planPath = Join-Path $Fixture.ProjectDir "$Mode-plan.json"
        $identityPath = Join-Path $Fixture.ProjectDir "$Mode-identity.json"
        $scriptPath = Join-Path $Fixture.ProjectDir "$Mode-owner.ps1"
        $effectPath = Join-Path $Fixture.ProjectDir "$Mode-effect.marker"
        $releasePath = Join-Path $Fixture.ProjectDir "$Mode-release.marker"
        [IO.File]::WriteAllText(
            $planPath,
            ($Fixture.Plan | ConvertTo-Json -Depth 50 -Compress),
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText(
            $identityPath,
            ($Fixture.Identity | ConvertTo-Json -Depth 20 -Compress),
            [Text.UTF8Encoding]::new($false)
        )
        $ownerScript = @'
param(
    [Parameter(Mandatory = $true)][string]$RuntimePath,
    [Parameter(Mandatory = $true)][string]$ProjectDir,
    [Parameter(Mandatory = $true)][string]$TaskFile,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [Parameter(Mandatory = $true)][string]$IdentityPath,
    [Parameter(Mandatory = $true)][string]$EffectPath,
    [Parameter(Mandatory = $true)][string]$ReleasePath,
    [Parameter(Mandatory = $true)]
    [ValidateSet('crash-after-effect', 'hold-after-effect')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $RuntimePath
$plan = Get-Content -Raw -LiteralPath $PlanPath |
    ConvertFrom-Json -AsHashtable -Depth 50
$identity = Get-Content -Raw -LiteralPath $IdentityPath |
    ConvertFrom-Json -AsHashtable -Depth 20
$workspacePlanInvoker = {
    param($RecipeId, $WorkflowId, $RequestedRunId, $RequestedProjectDir)
    return $plan
}.GetNewClosure()
$manifestIdentityReader = {
    param($RequestedProjectDir)
    return $identity
}.GetNewClosure()
$sourceHeadReader = {
    param($RequestedProjectDir)
    return 'a' * 40
}.GetNewClosure()
$dispatchNode = {
    param($Node, $TaskContent, $Run)
    [IO.File]::WriteAllText(
        $EffectPath,
        'submission-effect-crossed',
        [Text.UTF8Encoding]::new($false)
    )
    if ($Mode -ceq 'crash-after-effect') {
        [Environment]::Exit(93)
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $ReleasePath -PathType Leaf)) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw 'DW21 release marker timeout.'
        }
        Start-Sleep -Milliseconds 25
    }
    return [ordered]@{ accepted = $true }
}.GetNewClosure()

Invoke-DeclarativeWorkflow `
    -Action start `
    -RecipeId 'bugfix-two-slot' `
    -WorkflowId 'bugfix' `
    -RunId $RunId `
    -TaskFile $TaskFile `
    -ProjectDir $ProjectDir `
    -WorkspacePlanInvoker $workspacePlanInvoker `
    -ManifestIdentityReader $manifestIdentityReader `
    -SourceHeadReader $sourceHeadReader `
    -DispatchNode $dispatchNode |
    ConvertTo-Json -Depth 50 -Compress
'@
        [IO.File]::WriteAllText(
            $scriptPath,
            $ownerScript,
            [Text.UTF8Encoding]::new($false)
        )

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @(
                '-NoProfile',
                '-File', $scriptPath,
                '-RuntimePath', $script:Task659RuntimePath,
                '-ProjectDir', $Fixture.ProjectDir,
                '-TaskFile', $Fixture.TaskFile,
                '-RunId', $Fixture.RunId,
                '-PlanPath', $planPath,
                '-IdentityPath', $identityPath,
                '-EffectPath', $effectPath,
                '-ReleasePath', $releasePath,
                '-Mode', $Mode
            )) {
            $startInfo.ArgumentList.Add([string]$argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            $process.Dispose()
            throw "Failed to start TASK-659 $Mode owner process."
        }
        return [PSCustomObject]@{
            Process = $process
            EffectPath = $effectPath
            ReleasePath = $releasePath
        }
    }

    function Wait-Task659EffectMarker {
        param(
            [Parameter(Mandatory = $true)]$Child,
            [int]$TimeoutSeconds = 10
        )

        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not (Test-Path -LiteralPath $Child.EffectPath -PathType Leaf) -and
            [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 25
        }
        return Test-Path -LiteralPath $Child.EffectPath -PathType Leaf
    }

    function Complete-Task659OwnerProcess {
        param(
            [Parameter(Mandatory = $true)]$Child,
            [switch]$Release,
            [int]$TimeoutSeconds = 10
        )

        if ($Release -and -not (Test-Path -LiteralPath $Child.ReleasePath -PathType Leaf)) {
            [IO.File]::WriteAllText(
                $Child.ReleasePath,
                'release',
                [Text.UTF8Encoding]::new($false)
            )
        }
        if (-not $Child.Process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $Child.Process.Id -Force -ErrorAction SilentlyContinue
            $null = $Child.Process.WaitForExit(5000)
        }
        $result = [PSCustomObject]@{
            ExitCode = $Child.Process.ExitCode
            StdOut = $Child.Process.StandardOutput.ReadToEnd()
            StdErr = $Child.Process.StandardError.ReadToEnd()
        }
        $Child.Process.Dispose()
        return $result
    }

    function Get-Task659StateBytes {
        param([Parameter(Mandatory = $true)]$Fixture)

        $path = Get-DeclarativeWorkflowRunStatePath -ProjectDir $Fixture.ProjectDir -RunId $Fixture.RunId
        return [IO.File]::ReadAllBytes($path)
    }

    function Get-Task659MailboxFiles {
        param(
            [Parameter(Mandatory = $true)]$Fixture,
            [ValidateSet('pending', 'consumed')][string]$State
        )

        $path = Join-Path $Fixture.ProjectDir ".winsmux\workflow-mailbox\$($Fixture.RunId)\$State"
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            return ,@()
        }
        return ,@(Get-ChildItem -LiteralPath $path -File -Filter '*.json')
    }

    function Get-Task659BridgeFunctionSource {
        param([Parameter(Mandatory = $true)][string]$Name)

        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:Task659BridgePath,
            [ref]$tokens,
            [ref]$errors
        )
        if (@($errors).Count -gt 0) {
            throw "bridge parser error: $($errors[0].Message)"
        }
        $functionAst = @(
            $ast.FindAll(
                {
                    param($candidate)
                    $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        [string]$candidate.Name -ceq $Name
                },
                $true
            )
        ) | Select-Object -First 1
        if ($null -eq $functionAst) {
            throw "bridge function missing: $Name"
        }
        return [string]$functionAst.Extent.Text
    }

    function New-Task659WorkspacePlanShim {
        param(
            [Parameter(Mandatory = $true)][string]$Directory,
            [Parameter(Mandatory = $true)][string]$FileName
        )

        [IO.Directory]::CreateDirectory($Directory) | Out-Null
        $path = Join-Path $Directory $FileName
        $source = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ([string]::IsNullOrWhiteSpace([string]$env:TASK659_WORKSPACE_PLAN_LOG)) {
    throw 'TASK659_WORKSPACE_PLAN_LOG is required.'
}
$arguments = @($args | ForEach-Object { [string]$_ })
$record = [ordered]@{
    command = [string]$MyInvocation.MyCommand.Name
    arguments = $arguments
}
[IO.File]::AppendAllText(
    $env:TASK659_WORKSPACE_PLAN_LOG,
    ($record | ConvertTo-Json -Depth 10 -Compress) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
)
if ($arguments.Count -lt 1 -or $arguments[0] -cne 'workspace-plan') {
    throw 'Expected workspace-plan.'
}
$values = [ordered]@{}
for ($index = 1; $index -lt $arguments.Count;) {
    if ($arguments[$index] -ceq '--json') {
        $values['--json'] = $true
        $index++
        continue
    }
    if ($index + 1 -ge $arguments.Count) {
        throw "Missing value for $($arguments[$index])."
    }
    $values[$arguments[$index]] = $arguments[$index + 1]
    $index += 2
}
foreach ($name in @('--recipe-id', '--workflow-id', '--run-id', '--project-dir')) {
    if (-not $values.Contains($name)) {
        throw "Missing $name."
    }
}
$runId = [string]$values['--run-id']
$plan = [ordered]@{
    schema_version = 1
    config_fingerprint = 'sha256:' + ('1' * 64)
    recipe_id = [string]$values['--recipe-id']
    workflow_id = [string]$values['--workflow-id']
    panes = @([ordered]@{ pane_key = 'implement'; slot_id = 'builder-1' })
    resolved_bindings = [ordered]@{ implement = 'builder-1' }
    workflow = [ordered]@{
        schema_version = 1
        workflow_id = [string]$values['--workflow-id']
        recipe_ref = [string]$values['--recipe-id']
        run_id = $runId
        topological_order = @('build')
        nodes = @(
            [ordered]@{
                node_id = 'build'
                pane_ref = 'builder-1'
                depends_on = @()
                action = 'operator-dispatch'
                idempotency_key = "$runId`:build"
            }
        )
    }
}
$global:LASTEXITCODE = 0
$plan | ConvertTo-Json -Depth 30 -Compress
'@
        [IO.File]::WriteAllText(
            $path,
            $source,
            [Text.UTF8Encoding]::new($false)
        )
        return $path
    }

    function Get-Task659WorkspacePlanInvocations {
        param([Parameter(Mandatory = $true)][string]$Path)

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return ,@()
        }
        return ,@(
            Get-Content -LiteralPath $Path -Encoding UTF8 |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_ | ConvertFrom-Json -Depth 20 }
        )
    }

    function Invoke-Task659PublicWorkflowProcess {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('start', 'resume')]
            [string]$Action,
            [Parameter(Mandatory = $true)][string]$RunId,
            [Parameter(Mandatory = $true)][string]$TaskFile,
            [Parameter(Mandatory = $true)][string]$ProjectDir
        )

        $arguments = @(
            '-NoProfile',
            '-File',
            $script:Task659BridgePath,
            'pipeline',
            '--workflow-action',
            $Action
        )
        if ($Action -ceq 'start') {
            $arguments += @(
                '--recipe-id',
                'bugfix-two-slot',
                '--workflow-id',
                'bugfix'
            )
        }
        $arguments += @(
            '--run-id',
            $RunId,
            '--task-file',
            $TaskFile,
            '--project-dir',
            $ProjectDir,
            '--json'
        )

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in $arguments) {
            $null = $startInfo.ArgumentList.Add([string]$argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) {
                throw 'TASK-659 public workflow process did not start.'
            }
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) {
                $process.Kill($true)
                $null = $process.WaitForExit(5000)
                throw 'TASK-659 public workflow process timed out.'
            }
            return [PSCustomObject]@{
                ExitCode = $process.ExitCode
                Output = (
                    @(
                        $stdout.GetAwaiter().GetResult()
                        $stderr.GetAwaiter().GetResult()
                    ) -join [Environment]::NewLine
                ).Trim()
            }
        } finally {
            $process.Dispose()
        }
    }
}

Describe 'TASK-659 v0.36.30 production-path closure' {
    It 'DW01 preserves legacy pipeline bytes while only an enabled pipeline route accepts the exact declarative marker' {
        $script:capturedLegacyArgs = $null
        Mock Invoke-WinsmuxControlPlaneScript {
            param([string]$ScriptPath, [string[]]$Arguments)
            $script:capturedLegacyArgs = @($Arguments)
        }

        Invoke-WinsmuxTeamPipelineCommand `
            -BridgeScriptRoot (Join-Path $script:Task659RepoRoot 'scripts') `
            -CommandTarget 'legacy task' `
            -CommandRest @('--workflow-action', 'start') `
            -AllowDeclarativeWorkflow

        $script:capturedLegacyArgs | Should -Be @('-Task', 'legacy task --workflow-action start')
        $parsed = ConvertTo-WinsmuxDeclarativePipelineArguments `
            -CommandTarget '--workflow-action' `
            -CommandRest @(
                'start', '--recipe-id', 'bugfix-two-slot', '--workflow-id', 'bugfix',
                '--run-id', 'run-dw01', '--task-file', 'task.txt', '--project-dir', 'C:\repo', '--json'
            )
        $parsed.workflow_action | Should -Be 'start'
        $parsed.run_id | Should -Be 'run-dw01'
        Should -Invoke Invoke-WinsmuxControlPlaneScript -Times 1 -Exactly
    }

    It 'DW02 persists start intent before one guarded dispatch and stores only content-derived identity' {
        Assert-Task659RuntimeLoaded
        $fixture = New-Task659Fixture -Name 'dw02' -RunId 'run-dw02'

        $result = Invoke-Task659Start -Fixture $fixture
        $state = Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
        $statePath = Get-DeclarativeWorkflowRunStatePath -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
        $stateText = [IO.File]::ReadAllText($statePath, [Text.UTF8Encoding]::new($false, $true))

        $result.state | Should -Be 'running'
        $state.nodes.build.state | Should -Be 'running'
        $state.nodes.verify.state | Should -Be 'pending'
        $fixture.Dispatches.Count | Should -Be 1
        $fixture.Dispatches[0].state_exists | Should -BeTrue
        $fixture.Dispatches[0].state_at_dispatch | Should -Be 'dispatching'
        $state.session.session_name | Should -Be 'winsmux-orchestra'
        $state.workflow_fingerprint | Should -Be (Get-DeclarativeWorkflowContentDigest -Workflow $state.workflow)
        $state.task_digest | Should -Be (Get-Task659Sha256 -Bytes ([IO.File]::ReadAllBytes($fixture.TaskFile)))
        $stateText | Should -Not -Match ([regex]::Escape($fixture.TaskText))
    }

    It 'DW03 resumes from a durable internal result in a new invocation and releases one dependent' {
        Assert-Task659RuntimeLoaded
        $fixture = New-Task659Fixture -Name 'dw03' -RunId 'run-dw03'
        $null = Invoke-Task659Start -Fixture $fixture

        $send = Send-Task659InternalResult -Fixture $fixture
        $pendingAfterSenderReturn = Get-Task659MailboxFiles -Fixture $fixture -State pending
        $send.ExitCode | Should -Be 0 -Because $send.Output
        $pendingAfterSenderReturn.Count | Should -Be 1

        $result = Invoke-Task659Resume -Fixture $fixture
        $state = Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
        $consumed = Get-Task659MailboxFiles -Fixture $fixture -State consumed

        $result.state | Should -Be 'running'
        $state.nodes.build.state | Should -Be 'succeeded'
        $state.nodes.verify.state | Should -Be 'running'
        $state.session.server_session_id | Should -Be '$659'
        $fixture.Dispatches.Count | Should -Be 2
        $fixture.Dispatches[1].node_id | Should -Be 'verify'
        $consumed.Count | Should -Be 1
    }

    It 'DW04 keeps failure resumable until every dispatched sibling settles and never releases a dependent' {
        Assert-Task659RuntimeLoaded
        $fixture = New-Task659Fixture -Name 'dw04' -RunId 'run-dw04'
        $null = Invoke-Task659Start -Fixture $fixture

        $send = Send-Task659InternalResult -Fixture $fixture -Outcome failed -ExitCode 23
        $send.ExitCode | Should -Be 0
        (Get-Task659MailboxFiles -Fixture $fixture -State pending).Count | Should -Be 1
        $result = Invoke-Task659Resume -Fixture $fixture
        $state = Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId

        $result.state | Should -Be 'failed'
        $state.nodes.build.state | Should -Be 'failed'
        $state.nodes.build.exit_code | Should -Be 23
        $state.nodes.verify.state | Should -Be 'pending'
        $fixture.Dispatches.Count | Should -Be 1

        $parallelCases = @(
            [ordered]@{
                name = 'failure-first'
                first_outcome = 'failed'
                first_exit_code = 23
                second_outcome = 'succeeded'
                second_exit_code = 0
            },
            [ordered]@{
                name = 'success-first'
                first_outcome = 'succeeded'
                first_exit_code = 0
                second_outcome = 'failed'
                second_exit_code = 29
            }
        )
        foreach ($case in $parallelCases) {
            $parallel = New-Task659Fixture `
                -Name "dw04-$($case.name)" `
                -RunId "run-dw04-$($case.name)"
            $parallel.Plan.workflow.nodes[1].depends_on = @()
            $null = Invoke-Task659Start -Fixture $parallel
            $parallel.Dispatches.Count | Should -Be 2
            $parallelState = Read-DeclarativeWorkflowRunState `
                -ProjectDir $parallel.ProjectDir -RunId $parallel.RunId
            $parallelState.nodes.build.state | Should -BeExactly 'running'
            $parallelState.nodes.verify.state | Should -BeExactly 'running'

            $first = Send-Task659InternalResult `
                -Fixture $parallel `
                -NodeId build `
                -Outcome $case.first_outcome `
                -ExitCode $case.first_exit_code
            $first.ExitCode | Should -Be 0 -Because $first.Output
            $waiting = Invoke-Task659Resume -Fixture $parallel
            $waiting.state | Should -BeExactly 'blocked'
            $waiting.nodes.build.state | Should -BeExactly $case.first_outcome
            $waiting.nodes.verify.state | Should -BeExactly 'blocked'
            $parallel.Dispatches.Count | Should -Be 2
            (Get-Task659MailboxFiles -Fixture $parallel -State consumed).Count |
                Should -Be 1

            $late = Send-Task659InternalResult `
                -Fixture $parallel `
                -NodeId verify `
                -Outcome $case.second_outcome `
                -ExitCode $case.second_exit_code
            $late.ExitCode | Should -Be 0 -Because $late.Output
            $settled = Invoke-Task659Resume -Fixture $parallel
            $settled.state | Should -BeExactly 'failed'
            $settled.nodes.build.state | Should -BeExactly $case.first_outcome
            $settled.nodes.verify.state | Should -BeExactly $case.second_outcome
            $parallel.Dispatches.Count | Should -Be 2
            (Get-Task659MailboxFiles -Fixture $parallel -State consumed).Count |
                Should -Be 2
        }
    }

    It 'DW05 rejects cancel retry rollback and unknown actions before any product subprocess or mutable sink' {
        $sentinelDir = Join-Path $TestDrive 'dw05\.winsmux'
        [IO.Directory]::CreateDirectory($sentinelDir) | Out-Null
        $statePath = Join-Path $sentinelDir 'state.sentinel'
        $mailboxPath = Join-Path $sentinelDir 'mailbox.sentinel'
        [IO.File]::WriteAllText($statePath, 'state-before', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($mailboxPath, 'mailbox-before', [Text.UTF8Encoding]::new($false))
        $stateBefore = [IO.File]::ReadAllBytes($statePath)
        $mailboxBefore = [IO.File]::ReadAllBytes($mailboxPath)
        Mock Invoke-WinsmuxControlPlaneScript { throw 'mutable sink must not run' }

        foreach ($action in @('cancel', 'retry', 'rollback', 'unknown')) {
            {
                ConvertTo-WinsmuxDeclarativePipelineArguments `
                    -CommandTarget '--workflow-action' `
                    -CommandRest @(
                        $action, '--run-id', 'run-dw05', '--task-file', 'task.txt',
                        '--project-dir', 'C:\repo', '--json'
                    )
            } | Should -Throw '*start or resume*'
        }

        [IO.File]::ReadAllBytes($statePath) | Should -Be $stateBefore
        [IO.File]::ReadAllBytes($mailboxPath) | Should -Be $mailboxBefore
        Should -Invoke Invoke-WinsmuxControlPlaneScript -Times 0 -Exactly
    }

    It 'DW06 rejects missing duplicate empty unknown and caller-owned identity arguments with byte-exact pre-state' {
        Assert-Task659RuntimeLoaded
        $sentinel = Join-Path $TestDrive 'dw06-sentinel'
        [IO.File]::WriteAllText($sentinel, 'unchanged', [Text.UTF8Encoding]::new($false))
        $stateBefore = [IO.File]::ReadAllBytes($sentinel)
        Mock Invoke-WinsmuxControlPlaneScript { throw 'mutable sink must not run' }
        $cases = @(
            @('start', '--run-id', 'run-dw06', '--task-file', 'task.txt', '--project-dir', 'C:\repo', '--json'),
            @('start', '--recipe-id', 'r', '--recipe-id', 'r', '--workflow-id', 'w', '--run-id', 'run-dw06', '--task-file', 'task.txt', '--project-dir', 'C:\repo', '--json'),
            @('resume', '--run-id', '', '--task-file', 'task.txt', '--project-dir', 'C:\repo', '--json'),
            @('resume', '--run-id', 'run-dw06', '--task-file', 'task.txt', '--project-dir', 'C:\repo', '--unknown', 'x', '--json'),
            @('resume', '--run-id', 'run-dw06', '--task-file', 'task.txt', '--project-dir', 'C:\repo', '--source-head', ('a' * 40), '--json'),
            @('resume', '--run-id', 'run-dw06', '--task-file', 'task.txt', '--project-dir', 'C:\repo', '--config-fingerprint', ('sha256:' + ('1' * 64)), '--json')
        )

        foreach ($arguments in $cases) {
            {
                ConvertTo-WinsmuxDeclarativePipelineArguments `
                    -CommandTarget '--workflow-action' `
                    -CommandRest $arguments
            } | Should -Throw
        }

        [IO.File]::ReadAllBytes($sentinel) | Should -Be $stateBefore
        Should -Invoke Invoke-WinsmuxControlPlaneScript -Times 0 -Exactly
    }

    It 'DW07 rejects a noncanonical DAG or mismatched recipe binding before the lease state mailbox or dispatch sinks' {
        Assert-Task659RuntimeLoaded
        $fixture = New-Task659Fixture -Name 'dw07' -RunId 'run-dw07'
        $workspacePlanProbe = [PSCustomObject]@{ Count = 0 }
        $invalidPlanInvoker = {
            param([string]$RecipeId, [string]$WorkflowId, [string]$RunId, [string]$ProjectDir)
            $workspacePlanProbe.Count++
            throw 'workflow_cycle'
        }.GetNewClosure()
        $statePath = Get-DeclarativeWorkflowRunStatePath -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId

        {
            Invoke-DeclarativeWorkflow `
                -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                -RunId $fixture.RunId -TaskFile $fixture.TaskFile -ProjectDir $fixture.ProjectDir `
                -WorkspacePlanInvoker $invalidPlanInvoker `
                -ManifestIdentityReader $fixture.ManifestIdentityReader `
                -SourceHeadReader $fixture.SourceHeadReader `
                -DispatchNode $fixture.DispatchNode
        } | Should -Throw '*workflow_cycle*'

        $workspacePlanProbe.Count | Should -Be 1
        Test-Path -LiteralPath $statePath | Should -BeFalse
        (Get-Task659MailboxFiles -Fixture $fixture -State pending).Count | Should -Be 0
        $fixture.Dispatches.Count | Should -Be 0

        $binding = New-Task659Fixture -Name 'dw07-binding' -RunId 'run-dw07-binding'
        $binding.Plan.workflow.recipe_ref = 'review-one-slot'
        $bindingPlanInvoker = {
            param([string]$RecipeId, [string]$WorkflowId, [string]$RunId, [string]$ProjectDir)
            return $binding.Plan
        }.GetNewClosure()
        $bindingStatePath = Get-DeclarativeWorkflowRunStatePath `
            -ProjectDir $binding.ProjectDir -RunId $binding.RunId
        {
            Invoke-DeclarativeWorkflow `
                -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                -RunId $binding.RunId -TaskFile $binding.TaskFile -ProjectDir $binding.ProjectDir `
                -WorkspacePlanInvoker $bindingPlanInvoker `
                -ManifestIdentityReader $binding.ManifestIdentityReader `
                -SourceHeadReader $binding.SourceHeadReader `
                -DispatchNode $binding.DispatchNode
        } | Should -Throw '*recipe*'
        Test-Path -LiteralPath $bindingStatePath | Should -BeFalse
        (Get-Task659MailboxFiles -Fixture $binding -State pending).Count | Should -Be 0
        $binding.Dispatches.Count | Should -Be 0
    }

    It 'DW08 rejects task source and manifest identity drift before mailbox consume state write or dispatch' {
        Assert-Task659RuntimeLoaded
        $fixture = New-Task659Fixture -Name 'dw08' -RunId 'run-dw08'
        $null = Invoke-Task659Start -Fixture $fixture
        $stateBefore = Get-Task659StateBytes -Fixture $fixture
        $dispatchBefore = $fixture.Dispatches.Count

        [IO.File]::WriteAllText($fixture.TaskFile, 'changed task bytes', [Text.UTF8Encoding]::new($false))
        { Invoke-Task659Resume -Fixture $fixture } | Should -Throw '*task*'
        [IO.File]::WriteAllText($fixture.TaskFile, $fixture.TaskText, [Text.UTF8Encoding]::new($false))

        $changedHeadReader = { param([string]$ProjectDir) return 'b' * 40 }
        { Invoke-Task659Resume -Fixture $fixture -SourceHeadReader $changedHeadReader } | Should -Throw '*source*'

        $changedManifestReader = {
            param([string]$ProjectDir)
            return [ordered]@{
                session_name = 'winsmux-orchestra'
                generation_id = 'generation-other'
                server_session_id = '$659'
            }
        }
        { Invoke-Task659Resume -Fixture $fixture -ManifestIdentityReader $changedManifestReader } | Should -Throw '*session*'

        Get-Task659StateBytes -Fixture $fixture | Should -Be $stateBefore
        (Get-Task659MailboxFiles -Fixture $fixture -State consumed).Count | Should -Be 0
        $fixture.Dispatches.Count | Should -Be $dispatchBefore
    }

    It 'DW09 recomputes persisted and current workflow identity instead of trusting copied fingerprint strings' {
        Assert-Task659RuntimeLoaded
        $persistedFixture = New-Task659Fixture -Name 'dw09-persisted' -RunId 'run-dw09-a'
        $null = Invoke-Task659Start -Fixture $persistedFixture
        $statePath = Get-DeclarativeWorkflowRunStatePath -ProjectDir $persistedFixture.ProjectDir -RunId $persistedFixture.RunId
        $corrupt = [IO.File]::ReadAllText($statePath, [Text.UTF8Encoding]::new($false, $true)) |
            ConvertFrom-Json -AsHashtable -Depth 30
        $corrupt['workflow']['nodes'][0]['pane_ref'] = 'attacker-slot'
        $corruptText = $corrupt | ConvertTo-Json -Compress -Depth 30
        [IO.File]::WriteAllText($statePath, $corruptText, [Text.UTF8Encoding]::new($false))
        $corruptBefore = [IO.File]::ReadAllBytes($statePath)

        { Invoke-Task659Resume -Fixture $persistedFixture } | Should -Throw '*workflow*fingerprint*'
        [IO.File]::ReadAllBytes($statePath) | Should -Be $corruptBefore
        $persistedFixture.Dispatches.Count | Should -Be 1

        $currentFixture = New-Task659Fixture -Name 'dw09-current' -RunId 'run-dw09-b'
        $null = Invoke-Task659Start -Fixture $currentFixture
        $stateBefore = Get-Task659StateBytes -Fixture $currentFixture
        $currentFixture.Plan.workflow.nodes[0].pane_ref = 'changed-current-slot'

        { Invoke-Task659Resume -Fixture $currentFixture } | Should -Throw '*workflow*fingerprint*'
        Get-Task659StateBytes -Fixture $currentFixture | Should -Be $stateBefore
        $currentFixture.Dispatches.Count | Should -Be 1
    }

    It 'DW10 rejects automatic resume for succeeded failed and cancelled terminal runs without effect' {
        Assert-Task659RuntimeLoaded
        foreach ($terminalState in @('succeeded', 'failed', 'cancelled')) {
            $fixture = New-Task659Fixture -Name "dw10-$terminalState" -RunId "run-dw10-$terminalState" -SingleNode
            $null = Invoke-Task659Start -Fixture $fixture
            $statePath = Get-DeclarativeWorkflowRunStatePath -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
            $state = [IO.File]::ReadAllText($statePath, [Text.UTF8Encoding]::new($false, $true)) |
                ConvertFrom-Json -AsHashtable -Depth 30
            $state['state'] = $terminalState
            $state['nodes']['build']['state'] = if ($terminalState -eq 'succeeded') { 'succeeded' } else { 'failed' }
            $terminalText = $state | ConvertTo-Json -Compress -Depth 30
            [IO.File]::WriteAllText($statePath, $terminalText, [Text.UTF8Encoding]::new($false))
            $stateBefore = [IO.File]::ReadAllBytes($statePath)
            $dispatchBefore = $fixture.Dispatches.Count

            { Invoke-Task659Resume -Fixture $fixture } | Should -Throw '*terminal*'

            [IO.File]::ReadAllBytes($statePath) | Should -Be $stateBefore
            (Get-Task659MailboxFiles -Fixture $fixture -State consumed).Count | Should -Be 0
            $fixture.Dispatches.Count | Should -Be $dispatchBefore
        }
    }

    It 'DW11 admits exactly one same-run public owner while allowing a different run lease' {
        Assert-Task659RuntimeLoaded
        $fixture = New-Task659Fixture -Name 'dw11' -RunId 'run-dw11'
        $null = Invoke-Task659Start -Fixture $fixture
        $stateBefore = Get-Task659StateBytes -Fixture $fixture
        $readyPath = Join-Path $fixture.ProjectDir 'lease-ready'
        $holderPath = Join-Path $fixture.ProjectDir 'hold-lease.ps1'
        $holderText = @"
`$ErrorActionPreference = 'Stop'
. '$($script:Task659RuntimePath.Replace("'", "''"))'
`$lease = Enter-DeclarativeWorkflowInvocationLease -ProjectDir '$($fixture.ProjectDir.Replace("'", "''"))' -RunId '$($fixture.RunId)'
[IO.File]::WriteAllText('$($readyPath.Replace("'", "''"))', 'ready', [Text.UTF8Encoding]::new(`$false))
try { Start-Sleep -Seconds 10 } finally { `$lease.Dispose() }
"@
        [IO.File]::WriteAllText($holderPath, $holderText, [Text.UTF8Encoding]::new($false))
        $holder = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $holderPath) -WindowStyle Hidden -PassThru
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(8)
            while (-not (Test-Path -LiteralPath $readyPath) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            Test-Path -LiteralPath $readyPath | Should -BeTrue

            { Invoke-Task659Resume -Fixture $fixture } | Should -Throw '*workflow_run_busy*'
            $differentRunLease = Enter-DeclarativeWorkflowInvocationLease `
                -ProjectDir $fixture.ProjectDir -RunId 'run-dw11-other'
            $differentRunLease | Should -Not -BeNullOrEmpty
            $differentRunLease.Dispose()
        } finally {
            if (-not $holder.HasExited) {
                Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
                $holder.WaitForExit(5000)
            }
            $holder.Dispose()
        }

        Get-Task659StateBytes -Fixture $fixture | Should -Be $stateBefore
        $fixture.Dispatches.Count | Should -Be 1
        (Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId).state |
            Should -Be 'running'
    }

    It 'DW12 blocks missing malformed contradictory wrong-tuple and ambiguous mailbox evidence without dependent release' {
        Assert-Task659RuntimeLoaded
        $missing = New-Task659Fixture -Name 'dw12-missing' -RunId 'run-dw12-missing'
        $null = Invoke-Task659Start -Fixture $missing
        $missingResult = Invoke-Task659Resume -Fixture $missing
        $missingState = Read-DeclarativeWorkflowRunState -ProjectDir $missing.ProjectDir -RunId $missing.RunId
        $missingResult.state | Should -Be 'blocked'
        $missingState.nodes.build.state | Should -Be 'blocked'
        $missingState.nodes.verify.state | Should -Be 'pending'
        $missing.Dispatches.Count | Should -Be 1

        $malformed = New-Task659Fixture -Name 'dw12-malformed' -RunId 'run-dw12-malformed'
        $null = Invoke-Task659Start -Fixture $malformed
        $malformedBefore = Get-Task659StateBytes -Fixture $malformed
        $pendingDir = Join-Path $malformed.ProjectDir ".winsmux\workflow-mailbox\$($malformed.RunId)\pending"
        [IO.Directory]::CreateDirectory($pendingDir) | Out-Null
        [IO.File]::WriteAllText((Join-Path $pendingDir 'msg-malformed.json'), '{', [Text.UTF8Encoding]::new($false))
        { Invoke-Task659Resume -Fixture $malformed } | Should -Throw '*mailbox*'
        Get-Task659StateBytes -Fixture $malformed | Should -Be $malformedBefore
        $malformed.Dispatches.Count | Should -Be 1

        $contradictory = New-Task659Fixture -Name 'dw12-contradictory' -RunId 'run-dw12-contradictory'
        $null = Invoke-Task659Start -Fixture $contradictory
        $contradictoryState = Read-DeclarativeWorkflowRunState -ProjectDir $contradictory.ProjectDir -RunId $contradictory.RunId
        $badEnvelope = New-Task659CompletionEnvelope `
            -Fixture $contradictory -Run $contradictoryState -Outcome succeeded -ExitCode 9 -MessageId 'msg-contradictory'
        {
            Write-Task659MailboxEnvelope -Fixture $contradictory -Envelope $badEnvelope
        } | Should -Throw '*contradictory*'
        (Get-Task659MailboxFiles -Fixture $contradictory -State pending).Count | Should -Be 0
        $contradictory.Dispatches.Count | Should -Be 1

        $wrongTuple = New-Task659Fixture -Name 'dw12-wrong-tuple' -RunId 'run-dw12-wrong-tuple'
        $null = Invoke-Task659Start -Fixture $wrongTuple
        $wrongTupleState = Read-DeclarativeWorkflowRunState `
            -ProjectDir $wrongTuple.ProjectDir -RunId $wrongTuple.RunId
        $wrongTupleEnvelope = New-Task659CompletionEnvelope `
            -Fixture $wrongTuple -Run $wrongTupleState -MessageId 'msg-wrong-tuple'
        $wrongTupleEnvelope['content']['run_id'] = 'run-other'
        {
            Write-Task659MailboxEnvelope -Fixture $wrongTuple -Envelope $wrongTupleEnvelope
        } | Should -Throw '*contradictory*'
        (Get-Task659MailboxFiles -Fixture $wrongTuple -State pending).Count | Should -Be 0
        $wrongTuple.Dispatches.Count | Should -Be 1

        $ambiguous = New-Task659Fixture -Name 'dw12-ambiguous' -RunId 'run-dw12-ambiguous'
        $null = Invoke-Task659Start -Fixture $ambiguous
        $ambiguousState = Read-DeclarativeWorkflowRunState -ProjectDir $ambiguous.ProjectDir -RunId $ambiguous.RunId
        $first = New-Task659CompletionEnvelope -Fixture $ambiguous -Run $ambiguousState -MessageId 'msg-ambiguous-a'
        $second = New-Task659CompletionEnvelope -Fixture $ambiguous -Run $ambiguousState -MessageId 'msg-ambiguous-b'
        (Write-Task659MailboxEnvelope -Fixture $ambiguous -Envelope $first).accepted | Should -BeTrue
        (Write-Task659MailboxEnvelope -Fixture $ambiguous -Envelope $second).accepted | Should -BeTrue
        $ambiguousBefore = Get-Task659StateBytes -Fixture $ambiguous
        { Invoke-Task659Resume -Fixture $ambiguous } | Should -Throw '*ambiguous*'
        Get-Task659StateBytes -Fixture $ambiguous | Should -Be $ambiguousBefore
        $ambiguous.Dispatches.Count | Should -Be 1

        $concurrent = New-Task659Fixture `
            -Name 'dw12-concurrent-conflict' -RunId 'run-dw12-concurrent-conflict'
        $null = Invoke-Task659Start -Fixture $concurrent
        $concurrentGo = Join-Path $concurrent.ProjectDir 'conflict-go.marker'
        $successProducer = $null
        $failureProducer = $null
        $successResult = $null
        $failureResult = $null
        try {
            $successProducer = Start-Task659InternalResultProcess `
                -Fixture $concurrent -Label 'success' -GoPath $concurrentGo
            $failureProducer = Start-Task659InternalResultProcess `
                -Fixture $concurrent -Label 'failure' -GoPath $concurrentGo `
                -Outcome failed -ExitCode 17
            (Wait-Task659ResultProducerReady -Child $successProducer) |
                Should -BeTrue
            (Wait-Task659ResultProducerReady -Child $failureProducer) |
                Should -BeTrue
            Release-Task659ResultProducers -GoPath $concurrentGo
            $successResult = Complete-Task659ResultProducer `
                -Child $successProducer
            $successProducer = $null
            $failureResult = Complete-Task659ResultProducer `
                -Child $failureProducer
            $failureProducer = $null
        } finally {
            Release-Task659ResultProducers -GoPath $concurrentGo
            if ($null -ne $successProducer) {
                $null = Complete-Task659ResultProducer -Child $successProducer
            }
            if ($null -ne $failureProducer) {
                $null = Complete-Task659ResultProducer -Child $failureProducer
            }
        }
        $successResult.ExitCode | Should -Be 0 `
            -Because "$($successResult.StdOut) $($successResult.StdErr)"
        $failureResult.ExitCode | Should -Be 0 `
            -Because "$($failureResult.StdOut) $($failureResult.StdErr)"
        (Get-Task659MailboxFiles -Fixture $concurrent -State pending).Count |
            Should -Be 2
        $concurrentBefore = Get-Task659StateBytes -Fixture $concurrent
        { Invoke-Task659Resume -Fixture $concurrent } |
            Should -Throw '*ambiguous*'
        Get-Task659StateBytes -Fixture $concurrent |
            Should -Be $concurrentBefore
        $concurrent.Dispatches.Count | Should -Be 1
    }

    It 'DW13 makes the same mailbox message byte-idempotent and never repeats its state transition or dispatch' {
        Assert-Task659RuntimeLoaded
        $fixture = New-Task659Fixture -Name 'dw13' -RunId 'run-dw13'
        $null = Invoke-Task659Start -Fixture $fixture

        $exactGo = Join-Path $fixture.ProjectDir 'exact-go.marker'
        $exactFirst = $null
        $exactSecond = $null
        $exactFirstResult = $null
        $exactSecondResult = $null
        try {
            $exactFirst = Start-Task659InternalResultProcess `
                -Fixture $fixture -Label 'exact-first' -GoPath $exactGo
            $exactSecond = Start-Task659InternalResultProcess `
                -Fixture $fixture -Label 'exact-second' -GoPath $exactGo
            (Wait-Task659ResultProducerReady -Child $exactFirst) |
                Should -BeTrue
            (Wait-Task659ResultProducerReady -Child $exactSecond) |
                Should -BeTrue
            Release-Task659ResultProducers -GoPath $exactGo
            $exactFirstResult = Complete-Task659ResultProducer -Child $exactFirst
            $exactFirst = $null
            $exactSecondResult = Complete-Task659ResultProducer -Child $exactSecond
            $exactSecond = $null
        } finally {
            Release-Task659ResultProducers -GoPath $exactGo
            if ($null -ne $exactFirst) {
                $null = Complete-Task659ResultProducer -Child $exactFirst
            }
            if ($null -ne $exactSecond) {
                $null = Complete-Task659ResultProducer -Child $exactSecond
            }
        }
        $exactFirstResult.ExitCode | Should -Be 0 `
            -Because "$($exactFirstResult.StdOut) $($exactFirstResult.StdErr)"
        $exactSecondResult.ExitCode | Should -Be 0 `
            -Because "$($exactSecondResult.StdOut) $($exactSecondResult.StdErr)"
        $pending = Get-Task659MailboxFiles -Fixture $fixture -State pending
        $pending.Count | Should -Be 1
        $pendingBytes = [IO.File]::ReadAllBytes($pending[0].FullName)
        [IO.File]::ReadAllBytes($pending[0].FullName) | Should -Be $pendingBytes

        $replayGo = Join-Path $fixture.ProjectDir 'replay-go.marker'
        $replayProducer = $null
        $replayResult = $null
        try {
            $replayProducer = Start-Task659InternalResultProcess `
                -Fixture $fixture -Label 'consume-overlap' -GoPath $replayGo
            (Wait-Task659ResultProducerReady -Child $replayProducer) |
                Should -BeTrue
            Release-Task659ResultProducers -GoPath $replayGo
            $null = Invoke-Task659Resume -Fixture $fixture
            $replayResult = Complete-Task659ResultProducer `
                -Child $replayProducer
            $replayProducer = $null
        } finally {
            Release-Task659ResultProducers -GoPath $replayGo
            if ($null -ne $replayProducer) {
                $replayResult = Complete-Task659ResultProducer `
                    -Child $replayProducer
            }
        }
        $replayResult.ExitCode | Should -Be 0 `
            -Because "$($replayResult.StdOut) $($replayResult.StdErr)"
        $afterFirstResume = Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
        $afterFirstResume.nodes.build.state | Should -Be 'succeeded'
        $afterFirstResume.nodes.verify.state | Should -Be 'running'
        $fixture.Dispatches.Count | Should -Be 2
        (Get-Task659MailboxFiles -Fixture $fixture -State pending).Count |
            Should -Be 0
        (Get-Task659MailboxFiles -Fixture $fixture -State consumed).Count | Should -Be 1

        (Send-Task659InternalResult -Fixture $fixture).ExitCode | Should -Be 0
        (Get-Task659MailboxFiles -Fixture $fixture -State pending).Count | Should -Be 0
        $afterReplay = Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
        @($afterReplay.admitted_messages).Count | Should -Be 1
        $afterReplay.nodes.build.message_id | Should -Match '^result-[0-9a-f]{32}$'
        $fixture.Dispatches.Count | Should -Be 2
    }

    It 'DW14 rejects proofless terminal node state before releasing a dependent or mutating durable evidence' {
        Assert-Task659RuntimeLoaded
        $observations = [Collections.Generic.List[object]]::new()
        foreach ($outcome in @('succeeded', 'failed')) {
            $fixture = New-Task659Fixture -Name "dw14-$outcome" -RunId "run-dw14-$outcome"
            $null = Invoke-Task659Start -Fixture $fixture
            $statePath = Get-DeclarativeWorkflowRunStatePath `
                -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
            $forged = [IO.File]::ReadAllText(
                $statePath,
                [Text.UTF8Encoding]::new($false, $true)
            ) | ConvertFrom-Json -AsHashtable -Depth 30
            $forged['nodes']['build']['state'] = $outcome
            $forged['nodes']['build']['message_id'] = "msg-dw14-$outcome"
            $forged['nodes']['build']['result_digest'] = Get-Task659Sha256 -Bytes (
                [Text.Encoding]::UTF8.GetBytes("$outcome`:0:build")
            )
            $forged['nodes']['build']['exit_code'] = if ($outcome -ceq 'succeeded') { 0 } else { 17 }
            $forged['admitted_messages'] = @("msg-dw14-$outcome")
            [IO.File]::WriteAllText(
                $statePath,
                ($forged | ConvertTo-Json -Compress -Depth 30),
                [Text.UTF8Encoding]::new($false)
            )
            $stateBefore = [IO.File]::ReadAllBytes($statePath)
            $dispatchBefore = $fixture.Dispatches.Count
            $resumeError = ''

            try {
                $null = Invoke-Task659Resume -Fixture $fixture
            } catch {
                $resumeError = [string]$_.Exception.Message
            }

            $stateAfter = [IO.File]::ReadAllBytes($statePath)
            $observations.Add([PSCustomObject]@{
                    outcome = $outcome
                    error = $resumeError
                    state_unchanged = [Linq.Enumerable]::SequenceEqual[byte]($stateBefore, $stateAfter)
                    pending = (Get-Task659MailboxFiles -Fixture $fixture -State pending).Count
                    consumed = (Get-Task659MailboxFiles -Fixture $fixture -State consumed).Count
                    dispatch_before = $dispatchBefore
                    dispatch_after = $fixture.Dispatches.Count
                }) | Out-Null
        }

        foreach ($observation in $observations) {
            $observation.error | Should -Match 'workflow_(state_proof|mailbox)_invalid'
            $observation.state_unchanged | Should -BeTrue
            $observation.pending | Should -Be 0
            $observation.consumed | Should -Be 0
            $observation.dispatch_after | Should -Be $observation.dispatch_before
        }
    }

    It 'DW15 carries selected project and exact session authority to the child and rechecks it before each pane submission' {
        $callerDir = Join-Path $TestDrive 'dw15-caller'
        $selectedProject = Join-Path $TestDrive 'dw15-selected'
        [IO.Directory]::CreateDirectory($callerDir) | Out-Null
        [IO.Directory]::CreateDirectory($selectedProject) | Out-Null
        $probePath = Join-Path $TestDrive 'dw15-bridge-probe.ps1'
        $probeText = @'
$ErrorActionPreference = 'Stop'
[ordered]@{
    cwd = (Get-Location).Path
    project_dir = [string]$env:WINSMUX_INTERNAL_WORKFLOW_PROJECT_DIR
    session_name = [string]$env:WINSMUX_INTERNAL_WORKFLOW_SESSION_NAME
    generation_id = [string]$env:WINSMUX_INTERNAL_WORKFLOW_GENERATION_ID
    server_session_id = [string]$env:WINSMUX_INTERNAL_WORKFLOW_SERVER_SESSION_ID
} | ConvertTo-Json -Compress
'@
        [IO.File]::WriteAllText($probePath, $probeText, [Text.UTF8Encoding]::new($false))
        $originalBridge = $script:TeamPipelineBridgeScript
        $originalEnvironment = [ordered]@{
            project_dir = [string]$env:WINSMUX_INTERNAL_WORKFLOW_PROJECT_DIR
            session_name = [string]$env:WINSMUX_INTERNAL_WORKFLOW_SESSION_NAME
            generation_id = [string]$env:WINSMUX_INTERNAL_WORKFLOW_GENERATION_ID
            server_session_id = [string]$env:WINSMUX_INTERNAL_WORKFLOW_SERVER_SESSION_ID
        }
        $env:WINSMUX_INTERNAL_WORKFLOW_PROJECT_DIR = 'parent-project-sentinel'
        $env:WINSMUX_INTERNAL_WORKFLOW_SESSION_NAME = 'parent-session-sentinel'
        $env:WINSMUX_INTERNAL_WORKFLOW_GENERATION_ID = 'parent-generation-sentinel'
        $env:WINSMUX_INTERNAL_WORKFLOW_SERVER_SESSION_ID = 'parent-server-sentinel'
        $bridgeError = ''
        $bridgeReceipt = $null
        try {
            $script:TeamPipelineBridgeScript = $probePath
            Push-Location $callerDir
            try {
                $bridgeReceipt = Invoke-TeamPipelineBridge `
                    -Arguments @('send', 'builder-1', 'payload') `
                    -ProjectDir $selectedProject `
                    -ExpectedSessionName 'winsmux-orchestra' `
                    -ExpectedGenerationId 'generation-dw15' `
                    -ExpectedServerSessionId '$659'
            } catch {
                $bridgeError = [string]$_.Exception.Message
            } finally {
                Pop-Location
            }

            $env:WINSMUX_INTERNAL_WORKFLOW_PROJECT_DIR | Should -BeExactly 'parent-project-sentinel'
            $env:WINSMUX_INTERNAL_WORKFLOW_SESSION_NAME | Should -BeExactly 'parent-session-sentinel'
            $env:WINSMUX_INTERNAL_WORKFLOW_GENERATION_ID | Should -BeExactly 'parent-generation-sentinel'
            $env:WINSMUX_INTERNAL_WORKFLOW_SERVER_SESSION_ID | Should -BeExactly 'parent-server-sentinel'
        } finally {
            $script:TeamPipelineBridgeScript = $originalBridge
            $env:WINSMUX_INTERNAL_WORKFLOW_PROJECT_DIR = $originalEnvironment.project_dir
            $env:WINSMUX_INTERNAL_WORKFLOW_SESSION_NAME = $originalEnvironment.session_name
            $env:WINSMUX_INTERNAL_WORKFLOW_GENERATION_ID = $originalEnvironment.generation_id
            $env:WINSMUX_INTERNAL_WORKFLOW_SERVER_SESSION_ID = $originalEnvironment.server_session_id
        }

        $probe = $null
        if ($null -ne $bridgeReceipt -and
            -not [string]::IsNullOrWhiteSpace([string]$bridgeReceipt.Output)) {
            $probe = $bridgeReceipt.Output | ConvertFrom-Json
        }

        $bridgeSource = [IO.File]::ReadAllText(
            $script:Task659BridgePath,
            [Text.UTF8Encoding]::new($false, $true)
        )
        $invokeSendSource = [regex]::Match(
            $bridgeSource,
            '(?s)function Invoke-Send \{.*?\r?\n\}\r?\n\r?\nfunction Invoke-Name'
        ).Value
        $authorityCallCount = (
            [regex]::Matches($invokeSendSource, 'Assert-WinsmuxWorkflowDispatchAuthority')
        ).Count
        $authorityBeforeEverySink = $true
        foreach ($sinkToken in @('Send-TextToPane -PaneId', 'Send-ResolvedTransportPlan')) {
            $sinkIndex = $invokeSendSource.IndexOf($sinkToken, [StringComparison]::Ordinal)
            if ($sinkIndex -le 0) {
                $authorityBeforeEverySink = $false
                continue
            }
            $authorityIndex = $invokeSendSource.LastIndexOf(
                'Assert-WinsmuxWorkflowDispatchAuthority',
                $sinkIndex,
                [StringComparison]::Ordinal
            )
            if ($authorityIndex -le 0) {
                $authorityBeforeEverySink = $false
            }
        }

        $sinkValidationError = ''
        $sinkEnvironment = [ordered]@{
            project_dir = [string]$env:WINSMUX_INTERNAL_WORKFLOW_PROJECT_DIR
            session_name = [string]$env:WINSMUX_INTERNAL_WORKFLOW_SESSION_NAME
            generation_id = [string]$env:WINSMUX_INTERNAL_WORKFLOW_GENERATION_ID
            server_session_id = [string]$env:WINSMUX_INTERNAL_WORKFLOW_SERVER_SESSION_ID
        }
        try {
            $validatorSource = Get-Task659BridgeFunctionSource `
                -Name 'Assert-WinsmuxWorkflowDispatchAuthority'
            . ([scriptblock]::Create($validatorSource))
            $env:WINSMUX_INTERNAL_WORKFLOW_PROJECT_DIR = [IO.Path]::GetFullPath($selectedProject)
            $env:WINSMUX_INTERNAL_WORKFLOW_SESSION_NAME = 'winsmux-orchestra'
            $env:WINSMUX_INTERNAL_WORKFLOW_GENERATION_ID = 'generation-dw15'
            $env:WINSMUX_INTERNAL_WORKFLOW_SERVER_SESSION_ID = '$659'
            Mock Get-WinsmuxVerifiedManifestIdentity {
                [PSCustomObject]@{
                    session_name = 'winsmux-orchestra'
                    generation_id = 'generation-dw15-changed'
                    server_session_id = '$659'
                }
            }
            try {
                Assert-WinsmuxWorkflowDispatchAuthority -ProjectDir $selectedProject
            } catch {
                $sinkValidationError = [string]$_.Exception.Message
            }
        } catch {
            $sinkValidationError = [string]$_.Exception.Message
        } finally {
            $env:WINSMUX_INTERNAL_WORKFLOW_PROJECT_DIR = $sinkEnvironment.project_dir
            $env:WINSMUX_INTERNAL_WORKFLOW_SESSION_NAME = $sinkEnvironment.session_name
            $env:WINSMUX_INTERNAL_WORKFLOW_GENERATION_ID = $sinkEnvironment.generation_id
            $env:WINSMUX_INTERNAL_WORKFLOW_SERVER_SESSION_ID = $sinkEnvironment.server_session_id
        }

        $rollbackProject = Join-Path $TestDrive 'dw15-rollback-project'
        $rollbackProbePath = Join-Path $TestDrive 'dw15-rollback-probe.ps1'
        $rollbackProbeSource = @'
param(
    [Parameter(Mandatory = $true)][string]$CorePath,
    [Parameter(Mandatory = $true)][string]$ProjectDir
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. $CorePath 'version' *> $null

[IO.Directory]::CreateDirectory((Join-Path $ProjectDir '.winsmux')) | Out-Null
$manifest = [ordered]@{
    version = 2
    session = [ordered]@{
        name = 'winsmux-orchestra'
        generation_id = 'generation-dw15-current'
        server_session_id = '$659'
        session_ready = $true
    }
    panes = [ordered]@{
        'worker-1' = [ordered]@{
            slot_id = 'worker-1'
            pane_id = '%2'
            worker_backend = 'codex'
            role = 'Worker'
            title = 'W1'
            status = 'ready'
            runtime_ready = $true
            exec_mode = $false
        }
    }
    tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
    worktrees = [ordered]@{}
}
Save-WinsmuxManifest -ProjectDir $ProjectDir -Manifest $manifest
$manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
$script:rollbackProjectDir = $ProjectDir
$script:rollbackContext = [PSCustomObject]@{
    ManifestPath = $manifestPath
    ProjectDir = $ProjectDir
    SessionName = 'winsmux-orchestra'
    Label = 'worker-1'
    PaneId = '%2'
    Role = 'Worker'
    Status = 'ready'
    SecurityPolicy = $null
    LaunchDir = $ProjectDir
    GitWorktreeDir = (Join-Path $ProjectDir '.git')
    Branch = 'codex/task-659-red'
    HeadSha = 'red659'
}
$script:rollbackManifest = $manifest
$script:rollbackSubmissionCount = 0

function Resolve-Target { return '%2' }
function Resolve-TerminalBackend { return 'tauri' }
function Get-SlotAgentConfig {
    return [PSCustomObject]@{
        Agent = 'codex'
        Model = 'gpt-5.5'
        PromptTransport = 'argv'
        CapabilityAdapter = 'codex'
        CapabilityCommand = 'codex'
    }
}
function Get-RoleAgentConfig { return Get-SlotAgentConfig }
function Assert-WinsmuxTargetRuntimeWriteAllowed {
    return [PSCustomObject]@{
        Managed = $true
        ProjectDir = $script:rollbackProjectDir
        Context = $script:rollbackContext
        Operation = 'dispatch'
        GenerationId = 'generation-dw15-current'
    }
}
function Start-DeferredPaneFromManifestEntry { return $false }
function Get-WinsmuxManifest { return $script:rollbackManifest }
function Get-WinsmuxVerifiedManifestIdentity {
    return [PSCustomObject]@{
        session_name = 'winsmux-orchestra'
        generation_id = 'generation-dw15-current'
        server_session_id = '$659'
    }
}
function Send-TextToPane {
    $script:rollbackSubmissionCount++
    throw 'pane submission must not occur'
}

$env:WINSMUX_INTERNAL_WORKFLOW_PROJECT_DIR = [IO.Path]::GetFullPath($ProjectDir)
$env:WINSMUX_INTERNAL_WORKFLOW_SESSION_NAME = 'winsmux-orchestra'
$env:WINSMUX_INTERNAL_WORKFLOW_GENERATION_ID = 'generation-dw15-planned'
$env:WINSMUX_INTERNAL_WORKFLOW_SERVER_SESSION_ID = '$659'
$marker = 'private-task-callback-dw15'
$prompt = $marker + ' ' + ('x' * 5000)
$errorText = ''
Push-Location $ProjectDir
try {
    try {
        Invoke-Send -SendTarget '%2' -SendArguments @($prompt)
    } catch {
        $errorText = [string]$_.Exception.Message
    }
} finally {
    Pop-Location
}

$promptDir = Join-Path (Join-Path $ProjectDir '.winsmux') 'dispatch-prompts'
$promptFiles = @(
    if (Test-Path -LiteralPath $promptDir -PathType Container) {
        Get-ChildItem -LiteralPath $promptDir -File
    }
)
$containsMarker = @(
    $promptFiles |
        Where-Object {
            [IO.File]::ReadAllText(
                $_.FullName,
                [Text.UTF8Encoding]::new($false, $true)
            ).Contains($marker)
        }
).Count -gt 0
[ordered]@{
    error = $errorText
    prompt_file_count = $promptFiles.Count
    prompt_contains_private_marker = $containsMarker
    submission_count = $script:rollbackSubmissionCount
} | ConvertTo-Json -Compress
'@
        [IO.File]::WriteAllText(
            $rollbackProbePath,
            $rollbackProbeSource,
            [Text.UTF8Encoding]::new($false)
        )
        [IO.Directory]::CreateDirectory($rollbackProject) | Out-Null
        $rollbackOutput = & pwsh -NoProfile -File $rollbackProbePath `
            -CorePath $script:Task659BridgePath `
            -ProjectDir $rollbackProject 2>&1
        $rollbackExitCode = $LASTEXITCODE
        $rollbackText = ($rollbackOutput | Out-String).Trim()
        $rollbackExitCode | Should -Be 0 -Because $rollbackText
        $rollbackProbe = $rollbackText | ConvertFrom-Json

        $authorityDefects = [Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($bridgeError)) {
            $authorityDefects.Add("transport: $bridgeError") | Out-Null
        }
        if ($authorityCallCount -lt 2 -or -not $authorityBeforeEverySink) {
            $authorityDefects.Add(
                "sink guards: calls=$authorityCallCount before_every_sink=$authorityBeforeEverySink"
            ) | Out-Null
        }
        if ($sinkValidationError -cnotmatch 'workflow_dispatch_authority_changed') {
            $authorityDefects.Add("sink validation: $sinkValidationError") | Out-Null
        }
        $authorityDefects | Should -BeNullOrEmpty
        $bridgeError | Should -BeNullOrEmpty
        $probe | Should -Not -BeNullOrEmpty
        [IO.Path]::GetFullPath([string]$probe.cwd) | Should -BeExactly ([IO.Path]::GetFullPath($selectedProject))
        $probe.project_dir | Should -BeExactly ([IO.Path]::GetFullPath($selectedProject))
        $probe.session_name | Should -BeExactly 'winsmux-orchestra'
        $probe.generation_id | Should -BeExactly 'generation-dw15'
        $probe.server_session_id | Should -BeExactly '$659'
        $invokeSendSource | Should -Not -BeNullOrEmpty
        $authorityCallCount | Should -BeGreaterOrEqual 2
        $authorityBeforeEverySink | Should -BeTrue
        $sinkValidationError | Should -Match 'workflow_dispatch_authority_changed'
        $rollbackProbe.error | Should -Match 'workflow_dispatch_authority_changed'
        $rollbackProbe.prompt_file_count | Should -Be 0
        $rollbackProbe.prompt_contains_private_marker | Should -BeFalse
        $rollbackProbe.submission_count | Should -Be 0
    }

    It 'DW16 gives normal and extended path spellings one machine-wide run-adjacent file lease' {
        Assert-Task659RuntimeLoaded
        $fixture = New-Task659Fixture -Name 'dw16' -RunId 'run-dw16'
        $null = Invoke-Task659Start -Fixture $fixture
        $stateBefore = Get-Task659StateBytes -Fixture $fixture
        $readyPath = Join-Path $fixture.ProjectDir 'dw16-ready'
        $holderPath = Join-Path $fixture.ProjectDir 'dw16-hold-lease.ps1'
        $extendedProject = '\\?\' + [IO.Path]::GetFullPath($fixture.ProjectDir)
        $holderText = @"
`$ErrorActionPreference = 'Stop'
. '$($script:Task659RuntimePath.Replace("'", "''"))'
`$lease = Enter-DeclarativeWorkflowInvocationLease -ProjectDir '$($extendedProject.Replace("'", "''"))' -RunId '$($fixture.RunId)'
[IO.File]::WriteAllText('$($readyPath.Replace("'", "''"))', 'ready', [Text.UTF8Encoding]::new(`$false))
try { Start-Sleep -Seconds 10 } finally { `$lease.Dispose() }
"@
        [IO.File]::WriteAllText($holderPath, $holderText, [Text.UTF8Encoding]::new($false))
        $holder = Start-Process (Get-Command pwsh).Source `
            -ArgumentList @('-NoProfile', '-File', $holderPath) `
            -WindowStyle Hidden -PassThru
        $busyError = ''
        $unexpectedLease = $null
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(8)
            while (-not (Test-Path -LiteralPath $readyPath) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            Test-Path -LiteralPath $readyPath | Should -BeTrue
            try {
                $unexpectedLease = Enter-DeclarativeWorkflowInvocationLease `
                    -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
            } catch {
                $busyError = [string]$_.Exception.Message
            }
            if ($null -ne $unexpectedLease) {
                $unexpectedLease.Dispose()
                $unexpectedLease = $null
            }

            $differentRunLease = Enter-DeclarativeWorkflowInvocationLease `
                -ProjectDir $fixture.ProjectDir -RunId 'run-dw16-other'
            $differentRunLease | Should -Not -BeNullOrEmpty
            $differentRunLease.Dispose()
        } finally {
            if ($null -ne $unexpectedLease) {
                $unexpectedLease.Dispose()
            }
            if (-not $holder.HasExited) {
                Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
                $holder.WaitForExit(5000)
            }
            $holder.Dispose()
        }

        $busyError | Should -Match 'workflow_run_busy'
        Get-Task659StateBytes -Fixture $fixture | Should -Be $stateBefore
        $fixture.Dispatches.Count | Should -Be 1
        $leasePath = Join-Path $fixture.ProjectDir ".winsmux\workflow-runs\$($fixture.RunId).lease"
        Test-Path -LiteralPath $leasePath -PathType Leaf | Should -BeTrue
    }

    It 'DW17 rejects mixed-case action and outcome enums before state mailbox or dispatch mutation' {
        Assert-Task659RuntimeLoaded
        $parserError = ''
        try {
            $null = ConvertTo-WinsmuxDeclarativePipelineArguments `
                -CommandTarget '--workflow-action' `
                -CommandRest @(
                    'RESUME', '--run-id', 'run-dw17-parser', '--task-file', 'task.txt',
                    '--project-dir', 'C:\repo', '--json'
                )
        } catch {
            $parserError = [string]$_.Exception.Message
        }

        $runtime = New-Task659Fixture -Name 'dw17-runtime' -RunId 'run-dw17-runtime'
        $null = Invoke-Task659Start -Fixture $runtime
        $runtimeStateBefore = Get-Task659StateBytes -Fixture $runtime
        $runtimeDispatchBefore = $runtime.Dispatches.Count
        $runtimeError = ''
        try {
            $null = Invoke-DeclarativeWorkflow `
                -Action 'RESUME' `
                -RunId $runtime.RunId `
                -TaskFile $runtime.TaskFile `
                -ProjectDir $runtime.ProjectDir `
                -WorkspacePlanInvoker $runtime.WorkspacePlanInvoker `
                -ManifestIdentityReader $runtime.ManifestIdentityReader `
                -SourceHeadReader $runtime.SourceHeadReader `
                -DispatchNode $runtime.DispatchNode
        } catch {
            $runtimeError = [string]$_.Exception.Message
        }

        $outcome = New-Task659Fixture -Name 'dw17-outcome' -RunId 'run-dw17-outcome'
        $null = Invoke-Task659Start -Fixture $outcome
        $outcomeStateBefore = Get-Task659StateBytes -Fixture $outcome
        $outcomeRun = Read-DeclarativeWorkflowRunState `
            -ProjectDir $outcome.ProjectDir -RunId $outcome.RunId
        $mixedEnvelope = New-Task659CompletionEnvelope `
            -Fixture $outcome -Run $outcomeRun -Outcome 'SUCCEEDED' -ExitCode 0 -MessageId 'msg-dw17-outcome'
        $outcomeError = ''
        try {
            $null = Write-Task659MailboxEnvelope -Fixture $outcome -Envelope $mixedEnvelope
        } catch {
            $outcomeError = [string]$_.Exception.Message
        }

        $enumDefects = [Collections.Generic.List[string]]::new()
        if ($parserError -cnotmatch 'start or resume') {
            $enumDefects.Add("parser accepted RESUME: $parserError") | Out-Null
        }
        if ($runtimeError -cnotmatch 'workflow_action_invalid') {
            $enumDefects.Add("runtime accepted RESUME: $runtimeError") | Out-Null
        }
        if ($outcomeError -cnotmatch 'workflow_mailbox_invalid') {
            $enumDefects.Add("writer accepted SUCCEEDED: $outcomeError") | Out-Null
        }
        $enumDefects | Should -BeNullOrEmpty
        $parserError | Should -Match 'start or resume'
        $runtimeError | Should -Match 'workflow_action_invalid'
        $outcomeError | Should -Match 'workflow_mailbox_invalid'
        Get-Task659StateBytes -Fixture $runtime | Should -Be $runtimeStateBefore
        $runtime.Dispatches.Count | Should -Be $runtimeDispatchBefore
        Get-Task659StateBytes -Fixture $outcome | Should -Be $outcomeStateBefore
        (Get-Task659MailboxFiles -Fixture $outcome -State pending).Count | Should -Be 0
        $outcome.Dispatches.Count | Should -Be 1
    }

    It 'DW18 keeps task-run and every workflow-named mailbox channel on their legacy public contracts' {
        $script:capturedLegacyArgs = $null
        Mock Invoke-WinsmuxControlPlaneScript {
            param([string]$ScriptPath, [string[]]$Arguments)
            $script:capturedLegacyArgs = @($Arguments)
        }
        $legacyTokens = @(
            'start', '--recipe-id', 'bugfix-two-slot', '--workflow-id', 'bugfix',
            '--run-id', 'run-dw18-task', '--task-file', 'task.txt',
            '--project-dir', 'C:\repo', '--json'
        )
        $legacyRouteError = ''
        try {
            Invoke-WinsmuxTeamPipelineCommand `
                -BridgeScriptRoot (Join-Path $script:Task659RepoRoot 'scripts') `
                -CommandTarget '--workflow-action' `
                -CommandRest $legacyTokens `
                -AllowDeclarativeWorkflow:$false
        } catch {
            $legacyRouteError = [string]$_.Exception.Message
        }

        $channel = 'workflow-dw18-' + [guid]::NewGuid().ToString('N')
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh).Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @(
                '-NoProfile',
                '-File',
                $script:Task659BridgePath,
                'mailbox-create',
                $channel
            )) {
            $null = $startInfo.ArgumentList.Add($argument)
        }
        $server = [Diagnostics.Process]::new()
        $server.StartInfo = $startInfo
        $null = $server.Start()
        $sendExitCode = -1
        $sendOutput = ''
        $listenerText = ''
        try {
            $readyRead = $server.StandardOutput.ReadLineAsync()
            if ($readyRead.Wait(8000)) {
                $listenerText = [string]$readyRead.Result
            }

            $payload = [ordered]@{
                from = 'dw18-sender'
                to = 'dw18-receiver'
                content = 'dw18-exact-content'
                timestamp = '2026-07-25T00:00:00Z'
            } | ConvertTo-Json -Compress
            $sendLines = & pwsh -NoProfile -File $script:Task659BridgePath `
                mailbox-send $channel $payload 2>&1
            $sendExitCode = $LASTEXITCODE
            $sendOutput = ($sendLines | Out-String).Trim()

            $receiveRead = $server.StandardOutput.ReadLineAsync()
            if ($receiveRead.Wait(8000)) {
                $listenerText += "`n$([string]$receiveRead.Result)"
            }
        } finally {
            if (-not $server.HasExited) {
                $server.Kill($true)
                $null = $server.WaitForExit(5000)
            }
            $server.Dispose()
        }

        $expectedLegacyArgs = @(
            '-Task',
            '--workflow-action start --recipe-id bugfix-two-slot --workflow-id bugfix --run-id run-dw18-task --task-file task.txt --project-dir C:\repo --json'
        )
        $surfaceDefects = [Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($legacyRouteError)) {
            $surfaceDefects.Add("task-run route: $legacyRouteError") | Out-Null
        }
        if ((@($script:capturedLegacyArgs) -join "`u{1f}") -cne ($expectedLegacyArgs -join "`u{1f}")) {
            $surfaceDefects.Add(
                "task-run bytes: $(@($script:capturedLegacyArgs) -join ' | ')"
            ) | Out-Null
        }
        if ($listenerText -cnotmatch 'mailbox listening') {
            $surfaceDefects.Add('workflow-named pipe listener did not become live') | Out-Null
        }
        if ($sendExitCode -ne 0) {
            $surfaceDefects.Add("workflow-named pipe send exit=$sendExitCode output=$sendOutput") | Out-Null
        }
        if ($listenerText -cnotmatch 'dw18-exact-content') {
            $surfaceDefects.Add('workflow-named pipe did not receive exact content') | Out-Null
        }
        $surfaceDefects | Should -BeNullOrEmpty
        $listenerText | Should -Match 'mailbox listening'
        $legacyRouteError | Should -BeNullOrEmpty
        $script:capturedLegacyArgs | Should -Be $expectedLegacyArgs
        $sendExitCode | Should -Be 0 -Because $sendOutput
        $receivedLine = @(
            $listenerText -split '\r?\n' |
                Where-Object { $_ -match '^\{' -and $_ -match 'dw18-exact-content' }
        ) | Select-Object -Last 1
        $received = $receivedLine | ConvertFrom-Json
        $received.from | Should -BeExactly 'dw18-sender'
        $received.to | Should -BeExactly 'dw18-receiver'
        $received.content | Should -BeExactly 'dw18-exact-content'
        $bridgeSource = [IO.File]::ReadAllText(
            $script:Task659BridgePath,
            [Text.UTF8Encoding]::new($false, $true)
        )
        $bridgeSource | Should -Not -Match "(?m)^\s*'workflow-result'\s*\{"
    }

    It 'DW19 carries an executable internal result contract through default guarded dispatch and exposes no public result command' {
        Assert-Task659RuntimeLoaded
        $fixture = New-Task659Fixture -Name 'dw19' -RunId 'run-dw19'
        $planPath = Join-Path $fixture.ProjectDir 'dw19-plan.json'
        $runnerPath = Join-Path $fixture.ProjectDir 'dw19-default-dispatch.ps1'
        $teamPipelinePath = [IO.Path]::GetFullPath($script:Task659TeamPipelinePath)
        $fixtureProjectDir = [IO.Path]::GetFullPath($fixture.ProjectDir)
        $fixtureRunId = [string]$fixture.RunId
        $fixtureTaskFile = [IO.Path]::GetFullPath($fixture.TaskFile)
        [IO.File]::WriteAllText(
            $planPath,
            ($fixture.Plan | ConvertTo-Json -Depth 50 -Compress),
            [Text.UTF8Encoding]::new($false)
        )
        $runnerSource = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TeamPipelinePath,
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [Parameter(Mandatory = $true)][string]$ProjectDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$TaskFile,
    [ValidateSet('start', 'resume')][string]$Action
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$requestedTeamPipelinePath = $TeamPipelinePath
$requestedPlanPath = $PlanPath
$requestedProjectDir = $ProjectDir
$requestedRunId = $RunId
$requestedTaskFile = $TaskFile
$requestedAction = $Action

. $requestedTeamPipelinePath

$script:CapturedWorkflowDispatches = [Collections.Generic.List[object]]::new()
function Invoke-TeamPipelineBridge {
    param(
        [string[]]$Arguments,
        [AllowNull()][string]$InputText,
        [switch]$AllowFailure,
        [string]$ProjectDir,
        [string]$ExpectedSessionName,
        [string]$ExpectedGenerationId,
        [string]$ExpectedServerSessionId
    )

    $script:CapturedWorkflowDispatches.Add([ordered]@{
            arguments = @($Arguments)
            input_text = $InputText
            project_dir = $ProjectDir
            session_name = $ExpectedSessionName
            generation_id = $ExpectedGenerationId
            server_session_id = $ExpectedServerSessionId
        }) | Out-Null
    return [PSCustomObject]@{ ExitCode = 0; Output = '' }
}

$plan = Get-Content -Raw -LiteralPath $requestedPlanPath |
    ConvertFrom-Json -AsHashtable -Depth 50
$identity = [ordered]@{
    session_name = 'winsmux-orchestra'
    generation_id = 'generation-dw'
    server_session_id = '$659'
}
$workspacePlanInvoker = {
    param(
        [string]$RecipeId,
        [string]$WorkflowId,
        [string]$RequestedRunId,
        [string]$RequestedProjectDir
    )
    return $plan
}.GetNewClosure()
$manifestIdentityReader = {
    param([string]$RequestedProjectDir)
    return $identity
}.GetNewClosure()
$sourceHeadReader = {
    param([string]$RequestedProjectDir)
    return 'a' * 40
}.GetNewClosure()
$invokeParameters = @{
    Action = $requestedAction
    RunId = $requestedRunId
    TaskFile = $requestedTaskFile
    ProjectDir = $requestedProjectDir
    WorkspacePlanInvoker = $workspacePlanInvoker
    ManifestIdentityReader = $manifestIdentityReader
    SourceHeadReader = $sourceHeadReader
}
if ($requestedAction -ceq 'start') {
    $invokeParameters['RecipeId'] = 'bugfix-two-slot'
    $invokeParameters['WorkflowId'] = 'bugfix'
}
$result = Invoke-DeclarativeWorkflow @invokeParameters
[ordered]@{
    result = $result
    calls = @($script:CapturedWorkflowDispatches)
} | ConvertTo-Json -Depth 50 -Compress
'@
        [IO.File]::WriteAllText(
            $runnerPath,
            $runnerSource,
            [Text.UTF8Encoding]::new($false)
        )
        $invokeDefaultRuntime = {
            param([ValidateSet('start', 'resume')][string]$Action)

            $output = & pwsh -NoProfile -File $runnerPath `
                -TeamPipelinePath $teamPipelinePath `
                -PlanPath $planPath `
                -ProjectDir $fixtureProjectDir `
                -RunId $fixtureRunId `
                -TaskFile $fixtureTaskFile `
                -Action $Action 2>&1
            $exitCode = $LASTEXITCODE
            $text = ($output | Out-String).Trim()
            $exitCode | Should -Be 0 -Because $text
            return $text | ConvertFrom-Json -Depth 50
        }.GetNewClosure()

        $startCapture = & $invokeDefaultRuntime -Action start
        $run = Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
        @($startCapture.calls).Count | Should -Be 1
        $firstDispatch = $startCapture.calls[0]
        $firstDispatch.arguments[0] | Should -BeExactly 'send'
        $firstDispatch.arguments[1] | Should -BeExactly 'builder-1'
        $firstDispatch.arguments[2] | Should -BeExactly '--workflow-prompt-stdin'
        $prompt = [string]$firstDispatch.input_text
        $prompt.Substring(0, $fixture.TaskText.Length) |
            Should -BeExactly $fixture.TaskText
        $callbackMatch = [regex]::Match(
            $prompt,
            '(?s)<winsmux-workflow-result-v1>\r?\n(?<json>\{[^\r\n]+\})\r?\n'
        )
        $callbackMatch.Success | Should -BeTrue -Because $prompt
        $callback = $callbackMatch.Groups['json'].Value |
            ConvertFrom-Json
        [int]$callback.schema_version | Should -Be 1
        [string]$callback.adapter_path |
            Should -BeExactly ([IO.Path]::GetFullPath($script:Task659TeamPipelinePath))
        [string]$callback.project_dir |
            Should -BeExactly ([IO.Path]::GetFullPath($fixture.ProjectDir))
        [string]$callback.run_id | Should -BeExactly $fixture.RunId
        [string]$callback.node_id | Should -BeExactly 'build'
        [string]$callback.task_digest | Should -BeExactly ([string]$run.task_digest)
        [string]$callback.workflow_fingerprint |
            Should -BeExactly ([string]$run.workflow_fingerprint)
        $prompt | Should -Match '(?m)^Success command: .* -WorkflowResultOutcome succeeded -WorkflowResultExitCode 0 -AsJson$'
        $prompt | Should -Match '(?m)^Failure command: .* -WorkflowResultOutcome failed -WorkflowResultExitCode 1 -AsJson$'

        $adapterOutput = & pwsh -NoProfile -File ([string]$callback.adapter_path) `
            -WorkflowResult `
            -RunId ([string]$callback.run_id) `
            -WorkflowResultNodeId ([string]$callback.node_id) `
            -WorkflowResultOutcome succeeded `
            -WorkflowResultExitCode 0 `
            -ProjectDir ([string]$callback.project_dir) `
            -AsJson 2>&1
        $adapterExitCode = $LASTEXITCODE
        $adapterText = ($adapterOutput | Out-String).Trim()
        $adapterExitCode | Should -Be 0 -Because $adapterText
        $receipt = $adapterText | ConvertFrom-Json
        $receipt.accepted | Should -BeTrue
        $pending = Get-Task659MailboxFiles -Fixture $fixture -State pending
        $pending.Count | Should -Be 1
        $envelope = [IO.File]::ReadAllText(
            $pending[0].FullName,
            [Text.UTF8Encoding]::new($false, $true)
        ) | ConvertFrom-Json -AsHashtable -Depth 30
        [string]$envelope['message_id'] | Should -Match '^result-[0-9a-f]{32}$'
        [string]$envelope['from'] | Should -BeExactly 'builder-1'
        [string]$envelope['to'] | Should -BeExactly 'Operator'
        [string]$envelope['content']['run_id'] | Should -BeExactly $fixture.RunId
        [string]$envelope['content']['node_id'] | Should -BeExactly 'build'
        [string]$envelope['content']['node_idempotency_key'] |
            Should -BeExactly ([string]$run.nodes.build.idempotency_key)
        [string]$envelope['content']['session_name'] |
            Should -BeExactly ([string]$run.session.session_name)
        [string]$envelope['content']['generation_id'] |
            Should -BeExactly ([string]$run.session.generation_id)
        [string]$envelope['content']['server_session_id'] |
            Should -BeExactly ([string]$run.session.server_session_id)
        [string]$envelope['content']['workflow_fingerprint'] |
            Should -BeExactly ([string]$run.workflow_fingerprint)
        [string]$envelope['content']['task_digest'] |
            Should -BeExactly ([string]$run.task_digest)
        [string]$envelope['content']['result_digest'] | Should -BeExactly (
            Get-Task659Sha256 -Bytes ([Text.Encoding]::UTF8.GetBytes('succeeded:0:build'))
        )

        $bridgeSource = [IO.File]::ReadAllText(
            $script:Task659BridgePath,
            [Text.UTF8Encoding]::new($false, $true)
        )
        $bridgeSource | Should -Not -Match "(?m)^\s*'workflow-result'\s*\{"
        $resumeCapture = & $invokeDefaultRuntime -Action resume
        $after = Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
        $after.nodes.build.state | Should -BeExactly 'succeeded'
        $after.nodes.verify.state | Should -BeExactly 'running'
        @($resumeCapture.calls).Count | Should -Be 1
        [string]$resumeCapture.calls[0].arguments[2] |
            Should -BeExactly '--workflow-prompt-stdin'
        [string]$resumeCapture.calls[0].input_text |
            Should -Match '"node_id":"verify"'
    }

    It 'DW20 preserves one exact result when the dispatch owner exits after the submission effect but before running is durable' {
        Assert-Task659RuntimeLoaded
        $fixture = New-Task659Fixture -Name 'dw20' -RunId 'run-dw20'
        $child = Start-Task659DispatchOwnerProcess `
            -Fixture $fixture -Mode crash-after-effect
        $childResult = $null
        try {
            (Wait-Task659EffectMarker -Child $child) | Should -BeTrue
            $childResult = Complete-Task659OwnerProcess -Child $child
            $child = $null
        } finally {
            if ($null -ne $child -and -not $child.Process.HasExited) {
                $childResult = Complete-Task659OwnerProcess -Child $child
                $child = $null
            }
        }

        $childResult.ExitCode | Should -Be 93 -Because $childResult.StdErr
        $beforeProducer = Get-Task659StateBytes -Fixture $fixture
        $beforeState = Read-DeclarativeWorkflowRunState `
            -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
        $beforeState.nodes.build.state | Should -BeExactly 'dispatching'

        $send = Send-Task659InternalResult `
            -Fixture $fixture -Outcome succeeded -ExitCode 0
        $afterProducer = Get-Task659StateBytes -Fixture $fixture
        $send.ExitCode | Should -Be 0 -Because $send.Output
        [Linq.Enumerable]::SequenceEqual[byte](
            [byte[]]$beforeProducer,
            [byte[]]$afterProducer
        ) | Should -BeTrue
        (Get-Task659MailboxFiles -Fixture $fixture -State pending).Count |
            Should -Be 1

        $result = Invoke-Task659Resume -Fixture $fixture
        $after = Read-DeclarativeWorkflowRunState `
            -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
        $result.state | Should -BeExactly 'running'
        $after.nodes.build.state | Should -BeExactly 'succeeded'
        $after.nodes.verify.state | Should -BeExactly 'running'
        $fixture.Dispatches.Count | Should -Be 1
        $fixture.Dispatches[0].node_id | Should -BeExactly 'verify'
        (Get-Task659MailboxFiles -Fixture $fixture -State consumed).Count |
            Should -Be 1

        $consumerFirst = New-Task659Fixture `
            -Name 'dw20-consumer-first' -RunId 'run-dw20-consumer-first'
        $null = Invoke-Task659Start -Fixture $consumerFirst
        $blocked = Invoke-Task659Resume -Fixture $consumerFirst
        $blocked.state | Should -BeExactly 'blocked'
        $blocked.nodes.build.state | Should -BeExactly 'blocked'
        $blockedBytes = Get-Task659StateBytes -Fixture $consumerFirst
        $lateProducer = Send-Task659InternalResult -Fixture $consumerFirst
        $lateProducer.ExitCode | Should -Be 0 -Because $lateProducer.Output
        [Linq.Enumerable]::SequenceEqual[byte](
            [byte[]]$blockedBytes,
            [byte[]](Get-Task659StateBytes -Fixture $consumerFirst)
        ) | Should -BeTrue
        (Get-Task659MailboxFiles -Fixture $consumerFirst -State pending).Count |
            Should -Be 1
        $lateResume = Invoke-Task659Resume -Fixture $consumerFirst
        $lateResume.nodes.build.state | Should -BeExactly 'succeeded'
        $lateResume.nodes.verify.state | Should -BeExactly 'running'
        $consumerFirst.Dispatches.Count | Should -Be 2
        (Get-Task659MailboxFiles -Fixture $consumerFirst -State consumed).Count |
            Should -Be 1
    }

    It 'DW21 lets an exact result finish while a live dispatch owner holds the state lease without mutating run bytes' {
        Assert-Task659RuntimeLoaded
        $fixture = New-Task659Fixture -Name 'dw21' -RunId 'run-dw21'
        $child = Start-Task659DispatchOwnerProcess `
            -Fixture $fixture -Mode hold-after-effect
        $childResult = $null
        $send = $null
        $beforeProducer = $null
        $afterProducer = $null
        $ownerAliveAfterProducer = $false
        try {
            (Wait-Task659EffectMarker -Child $child) | Should -BeTrue
            $child.Process.HasExited | Should -BeFalse
            $beforeProducer = Get-Task659StateBytes -Fixture $fixture
            $send = Send-Task659InternalResult `
                -Fixture $fixture -Outcome succeeded -ExitCode 0
            $ownerAliveAfterProducer = -not $child.Process.HasExited
            $afterProducer = Get-Task659StateBytes -Fixture $fixture
        } finally {
            if ($null -ne $child.Process -and -not $child.Process.HasExited) {
                $childResult = Complete-Task659OwnerProcess -Child $child -Release
            } elseif ($null -eq $childResult) {
                $childResult = Complete-Task659OwnerProcess -Child $child
            }
        }

        $send.ExitCode | Should -Be 0 -Because $send.Output
        $ownerAliveAfterProducer | Should -BeTrue
        [Linq.Enumerable]::SequenceEqual[byte](
            [byte[]]$beforeProducer,
            [byte[]]$afterProducer
        ) | Should -BeTrue
        (Get-Task659MailboxFiles -Fixture $fixture -State pending).Count |
            Should -Be 1
        $childResult.ExitCode | Should -Be 0 -Because $childResult.StdErr
        $running = Read-DeclarativeWorkflowRunState `
            -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
        $running.nodes.build.state | Should -BeExactly 'running'

        $result = Invoke-Task659Resume -Fixture $fixture
        $after = Read-DeclarativeWorkflowRunState `
            -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
        $result.state | Should -BeExactly 'running'
        $after.nodes.build.state | Should -BeExactly 'succeeded'
        $after.nodes.verify.state | Should -BeExactly 'running'
        $fixture.Dispatches.Count | Should -Be 1
        $fixture.Dispatches[0].node_id | Should -BeExactly 'verify'
        (Get-Task659MailboxFiles -Fixture $fixture -State consumed).Count |
            Should -Be 1
    }

    It 'TB01 acknowledges only already-admitted terminal pending proofs across every adjacent move crash cut' {
        Assert-Task659RuntimeLoaded
        $cases = @(
            [ordered]@{
                name = 'succeeded'
                outcome = 'succeeded'
                exit_code = 0
            },
            [ordered]@{
                name = 'failed'
                outcome = 'failed'
                exit_code = 23
            }
        )

        foreach ($case in $cases) {
            $fixture = New-Task659Fixture `
                -Name "tb01-$($case.name)" `
                -RunId "run-tb01-$($case.name)" `
                -SingleNode
            $null = Invoke-Task659Start -Fixture $fixture
            $send = Send-Task659InternalResult `
                -Fixture $fixture `
                -Outcome ([string]$case.outcome) `
                -ExitCode ([int]$case.exit_code)
            $send.ExitCode | Should -Be 0 -Because $send.Output
            (Get-Task659MailboxFiles -Fixture $fixture -State pending).Count |
                Should -Be 1

            $consumedPath = Join-Path $fixture.ProjectDir (
                ".winsmux\workflow-mailbox\$($fixture.RunId)\consumed"
            )
            if (Test-Path -LiteralPath $consumedPath -PathType Container) {
                Remove-Item -LiteralPath $consumedPath
            }
            [IO.File]::WriteAllText(
                $consumedPath,
                'TB01 injected adjacent-cut blocker',
                [Text.UTF8Encoding]::new($false)
            )

            { Invoke-Task659Resume -Fixture $fixture } | Should -Throw
            $terminal = Read-DeclarativeWorkflowRunState `
                -ProjectDir $fixture.ProjectDir -RunId $fixture.RunId
            $terminal.state | Should -BeExactly ([string]$case.outcome)
            $terminal.nodes.build.state | Should -BeExactly ([string]$case.outcome)
            @($terminal.admitted_messages).Count | Should -Be 1
            (Get-Task659MailboxFiles -Fixture $fixture -State pending).Count |
                Should -Be 1
            (Test-Path -LiteralPath $consumedPath -PathType Container) |
                Should -BeFalse
            $fixture.Dispatches.Count | Should -Be 1
            $stateAfterPersist = Get-Task659StateBytes -Fixture $fixture

            Remove-Item -LiteralPath $consumedPath -Force
            $reconciled = Invoke-Task659Resume -Fixture $fixture
            $reconciled.state | Should -BeExactly ([string]$case.outcome)
            [Linq.Enumerable]::SequenceEqual[byte](
                [byte[]]$stateAfterPersist,
                [byte[]](Get-Task659StateBytes -Fixture $fixture)
            ) | Should -BeTrue
            (Get-Task659MailboxFiles -Fixture $fixture -State pending).Count |
                Should -Be 0
            (Get-Task659MailboxFiles -Fixture $fixture -State consumed).Count |
                Should -Be 1
            $fixture.Dispatches.Count | Should -Be 1

            $stateAfterReconciliation = Get-Task659StateBytes -Fixture $fixture
            { Invoke-Task659Resume -Fixture $fixture } | Should -Throw '*terminal*'
            [Linq.Enumerable]::SequenceEqual[byte](
                [byte[]]$stateAfterReconciliation,
                [byte[]](Get-Task659StateBytes -Fixture $fixture)
            ) | Should -BeTrue
            (Get-Task659MailboxFiles -Fixture $fixture -State consumed).Count |
                Should -Be 1
            $fixture.Dispatches.Count | Should -Be 1
        }
    }

    It 'TB02 carries an unbounded internal workflow payload through real child stdin with metadata-only argv' {
        Assert-Task659RuntimeLoaded
        $fixture = New-Task659Fixture -Name 'tb02' -RunId 'run-tb02'
        $privateMarker = 'TB02-private-task-marker'
        $largeTask = $privateMarker + "`n" + ('x' * 70000)
        [IO.File]::WriteAllText(
            $fixture.TaskFile,
            $largeTask,
            [Text.UTF8Encoding]::new($false)
        )
        $fixture.TaskText = $largeTask
        $expectedPayloadBytes = [Text.UTF8Encoding]::new($false).GetByteCount($largeTask)
        $expectedPayloadBytes | Should -BeGreaterThan 65536

        $probePath = Join-Path $fixture.ProjectDir 'tb02-child-probe.ps1'
        $corePathLiteral = $script:Task659BridgePath.Replace("'", "''")
        $probeSource = @'
param()
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$requestedArguments = @($args)
trap {
    try {
        $null = [Console]::In.ReadToEnd()
    } catch {
    }
    [Console]::Error.WriteLine(
        'TB02_CHILD_ERROR: ' + [string]$_.Exception.Message
    )
    [Console]::Error.WriteLine(
        'TB02_CHILD_PROJECT: expected=' +
        [string]$env:WINSMUX_INTERNAL_WORKFLOW_PROJECT_DIR +
        '; current=' +
        [string](Get-Location).Path
    )
    exit 97
}
. '__TASK659_CORE_PATH__' 'version' *> $null

$script:tb02CapturedText = $null
$script:tb02Identity = [PSCustomObject]@{
    session_name = [string]$env:WINSMUX_INTERNAL_WORKFLOW_SESSION_NAME
    generation_id = [string]$env:WINSMUX_INTERNAL_WORKFLOW_GENERATION_ID
    server_session_id = [string]$env:WINSMUX_INTERNAL_WORKFLOW_SERVER_SESSION_ID
}
function Get-WinsmuxManifest {
    param([string]$ProjectDir)
    return [ordered]@{}
}
function Get-WinsmuxVerifiedManifestIdentity {
    param($Manifest)
    return $script:tb02Identity
}
function Resolve-Target {
    param([string]$Label)
    return '%2'
}
function Resolve-TerminalBackend { return 'tauri' }
function Assert-WinsmuxTargetRuntimeWriteAllowed {
    param(
        [string]$PaneId,
        [string]$CurrentProjectDir,
        [string]$Operation,
        [string]$ExpectedGenerationId
    )
    return [PSCustomObject]@{
        Managed = $false
        ProjectDir = $CurrentProjectDir
        Context = $null
        Operation = 'dispatch'
        GenerationId = ''
    }
}
function Resolve-SendTransportIntent {
    param(
        [string]$Text,
        [string]$ProjectDir,
        [int]$LengthLimit,
        [string]$PromptTransport,
        [string]$TaskSlug,
        [bool]$ExecMode,
        [string]$LaunchDir,
        [string]$GitWorktreeDir,
        [string]$Model,
        [string]$ExecCommand
    )
    $script:tb02CapturedText = $Text
    throw 'TB02_CAPTURED_AFTER_STDIN'
}

$captureError = ''
try {
    Invoke-Send `
        -SendTarget ([string]$requestedArguments[1]) `
        -SendArguments @([string]$requestedArguments[2])
} catch {
    $captureError = [string]$_.Exception.Message
}
if ($captureError -cne 'TB02_CAPTURED_AFTER_STDIN' -or
    $null -eq $script:tb02CapturedText) {
    throw "TB02 child consumer did not capture stdin: $captureError"
}
$payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes(
    [string]$script:tb02CapturedText
)
$hash = [Security.Cryptography.SHA256]::Create().ComputeHash($payloadBytes)
[ordered]@{
    arguments = @($requestedArguments)
    payload_bytes = $payloadBytes.Length
    payload_sha256 = 'sha256:' + (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    contains_private_marker = ([string]$script:tb02CapturedText).Contains('TB02-private-task-marker')
} | ConvertTo-Json -Depth 10 -Compress
'@.Replace('__TASK659_CORE_PATH__', $corePathLiteral)
        [IO.File]::WriteAllText(
            $probePath,
            $probeSource,
            [Text.UTF8Encoding]::new($false)
        )

        $originalBridgeScript = $script:TeamPipelineBridgeScript
        try {
            $script:TeamPipelineBridgeScript = $probePath
            $bridgeReceipt = Invoke-TeamPipelineBridge `
                -Arguments @('send', 'builder-1', '--workflow-prompt-stdin') `
                -InputText $largeTask `
                -ProjectDir $fixture.ProjectDir `
                -ExpectedSessionName ([string]$fixture.Identity.session_name) `
                -ExpectedGenerationId ([string]$fixture.Identity.generation_id) `
                -ExpectedServerSessionId ([string]$fixture.Identity.server_session_id)
        } finally {
            $script:TeamPipelineBridgeScript = $originalBridgeScript
        }
        $bridgeReceipt.ExitCode | Should -Be 0 -Because $bridgeReceipt.Output
        $probe = $bridgeReceipt.Output | ConvertFrom-Json
        @($probe.arguments).Count | Should -Be 3
        [string]$probe.arguments[0] | Should -BeExactly 'send'
        [string]$probe.arguments[1] | Should -BeExactly 'builder-1'
        [string]$probe.arguments[2] | Should -BeExactly '--workflow-prompt-stdin'
        (@($probe.arguments) -join ' ') | Should -Not -Match $privateMarker
        [int64]$probe.payload_bytes | Should -Be $expectedPayloadBytes
        [string]$probe.payload_sha256 | Should -BeExactly (
            Get-Task659Sha256 -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($largeTask))
        )
        $probe.contains_private_marker | Should -BeTrue
    }

    It 'DW22 carries command-valued RAW and BIN overrides through public start and resume to one exact child planner' {
        Assert-Task659RuntimeLoaded
        $shimDir = Join-Path $TestDrive 'dw22-path'
        $logPath = Join-Path $TestDrive 'dw22-workspace-plan.jsonl'
        $rawPath = New-Task659WorkspacePlanShim `
            -Directory $shimDir -FileName 'task659-dw22-raw.ps1'
        $binPath = New-Task659WorkspacePlanShim `
            -Directory $shimDir -FileName 'task659-dw22-bin.ps1'
        $rawCommandName = [IO.Path]::GetFileName($rawPath)
        $binCommandName = [IO.Path]::GetFileName($binPath)
        $previousPath = $env:PATH
        $previousRaw = $env:WINSMUX_RAW_EXE
        $previousBin = $env:WINSMUX_BIN
        $previousLog = $env:TASK659_WORKSPACE_PLAN_LOG

        try {
            $env:PATH = $shimDir + [IO.Path]::PathSeparator + $previousPath
            $env:TASK659_WORKSPACE_PLAN_LOG = $logPath
            $env:WINSMUX_RAW_EXE = $rawCommandName
            $env:WINSMUX_BIN = $binCommandName

            $startProject = Join-Path $TestDrive 'dw22-start'
            [IO.Directory]::CreateDirectory((Join-Path $startProject '.winsmux')) | Out-Null
            $startTaskFile = Join-Path $startProject 'task.txt'
            [IO.File]::WriteAllText(
                $startTaskFile,
                'DW22 public start task',
                [Text.UTF8Encoding]::new($false)
            )
            $startStatePath = Get-DeclarativeWorkflowRunStatePath `
                -ProjectDir $startProject -RunId 'run-dw22-start'
            $startResult = Invoke-Task659PublicWorkflowProcess `
                -Action start -RunId 'run-dw22-start' `
                -TaskFile $startTaskFile -ProjectDir $startProject

            Remove-Item Env:\WINSMUX_RAW_EXE -ErrorAction SilentlyContinue
            $resumeFixture = New-Task659Fixture `
                -Name 'dw22-resume' -RunId 'run-dw22-resume'
            $null = Invoke-Task659Start -Fixture $resumeFixture
            $resumeStateBefore = Get-Task659StateBytes -Fixture $resumeFixture
            $resumeResult = Invoke-Task659PublicWorkflowProcess `
                -Action resume -RunId $resumeFixture.RunId `
                -TaskFile $resumeFixture.TaskFile -ProjectDir $resumeFixture.ProjectDir

            $invocations = Get-Task659WorkspacePlanInvocations -Path $logPath
            @($invocations).Count | Should -Be 2
            $startInvocation = $invocations[0]
            $resumeInvocation = $invocations[1]
            $startInvocation.command | Should -BeExactly $rawCommandName
            $resumeInvocation.command | Should -BeExactly $binCommandName

            $startArguments = @($startInvocation.arguments | ForEach-Object { [string]$_ })
            $resumeArguments = @($resumeInvocation.arguments | ForEach-Object { [string]$_ })
            $startArguments[0] | Should -BeExactly 'workspace-plan'
            $resumeArguments[0] | Should -BeExactly 'workspace-plan'
            $startArgumentMap = [ordered]@{}
            for ($index = 1; $index + 1 -lt $startArguments.Count; $index += 2) {
                $startArgumentMap[$startArguments[$index]] = $startArguments[$index + 1]
            }
            $resumeArgumentMap = [ordered]@{}
            for ($index = 1; $index + 1 -lt $resumeArguments.Count; $index += 2) {
                $resumeArgumentMap[$resumeArguments[$index]] = $resumeArguments[$index + 1]
            }
            $startArgumentMap['--recipe-id'] | Should -BeExactly 'bugfix-two-slot'
            $startArgumentMap['--workflow-id'] | Should -BeExactly 'bugfix'
            $startArgumentMap['--run-id'] | Should -BeExactly 'run-dw22-start'
            $startArgumentMap['--project-dir'] |
                Should -BeExactly ([IO.Path]::GetFullPath($startProject))
            $resumeArgumentMap['--run-id'] | Should -BeExactly $resumeFixture.RunId
            $resumeArgumentMap['--project-dir'] |
                Should -BeExactly ([IO.Path]::GetFullPath($resumeFixture.ProjectDir))

            $startResult.ExitCode | Should -Not -Be 0
            $resumeResult.ExitCode | Should -Not -Be 0
            $startResult.Output | Should -Not -Match 'workflow_plan_unavailable'
            $resumeResult.Output | Should -Not -Match 'workflow_plan_unavailable'
            Test-Path -LiteralPath $startStatePath | Should -BeFalse
            Get-Task659StateBytes -Fixture $resumeFixture | Should -Be $resumeStateBefore
            (Get-Task659MailboxFiles -Fixture $resumeFixture -State pending).Count |
                Should -Be 0
        } finally {
            $env:PATH = $previousPath
            if ($null -eq $previousRaw) {
                Remove-Item Env:\WINSMUX_RAW_EXE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_RAW_EXE = $previousRaw
            }
            if ($null -eq $previousBin) {
                Remove-Item Env:\WINSMUX_BIN -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BIN = $previousBin
            }
            if ($null -eq $previousLog) {
                Remove-Item Env:\TASK659_WORKSPACE_PLAN_LOG -ErrorAction SilentlyContinue
            } else {
                $env:TASK659_WORKSPACE_PLAN_LOG = $previousLog
            }
        }
    }

    It 'DW23 rejects an invalid RAW override before child launch without BIN fallback or state mutation' {
        Assert-Task659RuntimeLoaded
        $shimDir = Join-Path $TestDrive 'dw23-path'
        $logPath = Join-Path $TestDrive 'dw23-workspace-plan.jsonl'
        $binPath = New-Task659WorkspacePlanShim `
            -Directory $shimDir -FileName 'task659-dw23-bin.ps1'
        $binCommandName = [IO.Path]::GetFileName($binPath)
        $missingCommand = 'task659-dw23-missing-' + [guid]::NewGuid().ToString('N') + '.ps1'
        $previousPath = $env:PATH
        $previousRaw = $env:WINSMUX_RAW_EXE
        $previousBin = $env:WINSMUX_BIN
        $previousLog = $env:TASK659_WORKSPACE_PLAN_LOG

        try {
            $env:PATH = $shimDir + [IO.Path]::PathSeparator + $previousPath
            $env:TASK659_WORKSPACE_PLAN_LOG = $logPath
            $env:WINSMUX_RAW_EXE = $missingCommand
            $env:WINSMUX_BIN = $binCommandName

            $startProject = Join-Path $TestDrive 'dw23-start'
            [IO.Directory]::CreateDirectory((Join-Path $startProject '.winsmux')) | Out-Null
            $startTaskFile = Join-Path $startProject 'task.txt'
            [IO.File]::WriteAllText(
                $startTaskFile,
                'DW23 public start task',
                [Text.UTF8Encoding]::new($false)
            )
            $startStatePath = Get-DeclarativeWorkflowRunStatePath `
                -ProjectDir $startProject -RunId 'run-dw23-start'
            $startResult = Invoke-Task659PublicWorkflowProcess `
                -Action start -RunId 'run-dw23-start' `
                -TaskFile $startTaskFile -ProjectDir $startProject

            $resumeFixture = New-Task659Fixture `
                -Name 'dw23-resume' -RunId 'run-dw23-resume'
            $null = Invoke-Task659Start -Fixture $resumeFixture
            $resumeStateBefore = Get-Task659StateBytes -Fixture $resumeFixture
            $resumeResult = Invoke-Task659PublicWorkflowProcess `
                -Action resume -RunId $resumeFixture.RunId `
                -TaskFile $resumeFixture.TaskFile -ProjectDir $resumeFixture.ProjectDir

            $startResult.ExitCode | Should -Not -Be 0
            $resumeResult.ExitCode | Should -Not -Be 0
            $startResult.Output | Should -Match 'configured winsmux executable is missing'
            $resumeResult.Output | Should -Match 'configured winsmux executable is missing'
            Test-Path -LiteralPath $startStatePath | Should -BeFalse
            Get-Task659StateBytes -Fixture $resumeFixture | Should -Be $resumeStateBefore
            Test-Path -LiteralPath $logPath | Should -BeFalse
            Test-Path -LiteralPath (
                Join-Path $startProject '.winsmux\workflow-mailbox\run-dw23-start'
            ) | Should -BeFalse
        } finally {
            $env:PATH = $previousPath
            if ($null -eq $previousRaw) {
                Remove-Item Env:\WINSMUX_RAW_EXE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_RAW_EXE = $previousRaw
            }
            if ($null -eq $previousBin) {
                Remove-Item Env:\WINSMUX_BIN -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BIN = $previousBin
            }
            if ($null -eq $previousLog) {
                Remove-Item Env:\TASK659_WORKSPACE_PLAN_LOG -ErrorAction SilentlyContinue
            } else {
                $env:TASK659_WORKSPACE_PLAN_LOG = $previousLog
            }
        }
    }
}
