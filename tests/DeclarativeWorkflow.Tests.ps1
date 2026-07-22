#pester:parallel-safe

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'winsmux-core\scripts\declarative-workflow.ps1')
    . (Join-Path $script:RepoRoot 'winsmux-core\scripts\manifest.ps1')
    . (Join-Path $script:RepoRoot 'winsmux-core\scripts\control-plane-dispatch.ps1')
    . (Join-Path $script:RepoRoot 'winsmux-core\scripts\team-pipeline.ps1')

    function New-TestWorkflowPlan {
        [PSCustomObject]@{
            schema_version = 1
            workflow_id = 'bugfix'
            recipe_ref = 'bugfix-two-slot'
            config_fingerprint = ('sha256:' + ('a' * 64))
            workflow_fingerprint = ('sha256:' + ('d' * 64))
            resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
            nodes = @(
                [PSCustomObject]@{ node_id = 'inspect'; pane_ref = 'implement'; action = 'operator-dispatch'; depends_on = @(); idempotency_key = 'run-123:inspect'; cleanup = 'retain' },
                [PSCustomObject]@{ node_id = 'verify'; pane_ref = 'verify'; action = 'verification'; depends_on = @('inspect'); idempotency_key = 'run-123:verify'; cleanup = 'retain'; context_pack_ref = 'review-pack' }
            )
            cleanup_actions = @('release-run-lock')
        }
    }

    function New-TestConfirmation {
        [ordered]@{
            run_id = 'run-123'
            generation_id = 'generation-123'
            config_fingerprint = ('sha256:' + ('a' * 64))
            source_head = ('b' * 40)
        }
    }

    function New-TestTaskInput {
        param([string]$Text = 'Implement TASK-659 safely.')
        $bytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes($Text)
        [PSCustomObject]@{
            Text = $Text
            ByteCount = $bytes.Length
            Sha256 = Get-DeclarativeWorkflowSha256Digest -Bytes $bytes
        }
    }

    function New-TestRun {
        $taskInput = New-TestTaskInput
        New-DeclarativeWorkflowRun `
            -Plan (New-TestWorkflowPlan) `
            -RunId 'run-123' `
            -GenerationId 'generation-123' `
            -SourceHead ('b' * 40) `
            -TaskInput $taskInput
    }

    function New-TestAcknowledgement {
        param(
            [Parameter(Mandatory = $true)][string]$NodeId,
            [Parameter(Mandatory = $true)][string]$PaneId
        )
        [ordered]@{
            schema_version      = 1
            run_id              = 'run-123'
            node_id             = $NodeId
            idempotency_key     = "run-123:$NodeId"
            generation_id       = 'generation-123'
            config_fingerprint  = ('sha256:' + ('a' * 64))
            workflow_fingerprint = ('sha256:' + ('d' * 64))
            source_head         = ('b' * 40)
            pane_id             = $PaneId
            status              = 'succeeded'
            evidence_ref        = "workflow-ack:run-123:$NodeId"
        }
    }

    function New-TestAcceptedReceipt {
        param(
            [Parameter(Mandatory = $true)][string]$NodeId,
            [Parameter(Mandatory = $true)][string]$PaneId
        )
        $acknowledgement = New-TestAcknowledgement -NodeId $NodeId -PaneId $PaneId
        [PSCustomObject]@{
            status          = 'accepted'
            target          = [PSCustomObject]@{ pane_id = $PaneId }
            evidence_refs   = @($acknowledgement.evidence_ref)
            acknowledgement = $acknowledgement
        }
    }
}

Describe 'TASK-659 declarative workflow runtime' -Tag 'unit' {
    BeforeEach {
        $script:testDeclarativeSessionName = 'winsmux-orchestra'
        Mock Get-PaneControlManifestEntries {
            @(
                [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%2'; GenerationId = 'generation-123'; Role = 'Builder' }
                [PSCustomObject]@{ Label = 'worker-2'; PaneId = '%3'; GenerationId = 'generation-123'; Role = 'Reviewer' }
            )
        }
        Mock Get-PaneControlManifestContext {
            param($ProjectDir, $PaneId)
            Get-PaneControlManifestEntries -ProjectDir $ProjectDir | Where-Object { $_.PaneId -ceq $PaneId } | Select-Object -First 1
        }
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation)
            [PSCustomObject]@{
                valid = $true
                context = [PSCustomObject]@{
                    session_name = $script:testDeclarativeSessionName
                    generation_id = [string]$ManifestEntry.GenerationId
                    label = [string]$ManifestEntry.Label
                    pane_id = [string]$ManifestEntry.PaneId
                }
            }
        }
    }

    It 'L01 L02 selects declarative mode only for the leading marker' {
        (ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget 'legacy task' -CommandRest @('--workflow-action', 'start')) | Should -BeNullOrEmpty
        (Join-WinsmuxControlPlaneText -Arguments (Get-WinsmuxControlPlaneArguments -CommandTarget 'legacy task' -CommandRest @('--workflow-action', 'start'))) | Should -Be 'legacy task --workflow-action start'
    }

    It 'A01 accepts only the closed start and resume argument sets' {
        $common = @('--run-id', 'run-123', '--generation-id', 'generation-123', '--config-fingerprint', ('sha256:' + ('a' * 64)), '--source-head', ('b' * 40), '--task-file', 'task.txt', '--json')
        $start = ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget '--workflow-action' -CommandRest (@('start', '--recipe-id', 'bugfix-two-slot', '--workflow-id', 'bugfix') + $common)
        $resume = ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget '--workflow-action' -CommandRest (@('resume') + $common)
        $start.workflow_action | Should -Be 'start'
        $resume.workflow_action | Should -Be 'resume'
        { ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget '--workflow-action' -CommandRest (@('start', '--recipe-id', 'bugfix-two-slot', '--workflow-id', 'bugfix') + $common + @('--run-id', 'other')) } | Should -Throw '*Duplicate*'
        { ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget '--workflow-action' -CommandRest (@('resume') + $common + @('positional')) } | Should -Throw '*Unknown or positional*'
        { ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget '--workflow-action' -CommandRest (@('resume') + $common + @('--unknown', 'x')) } | Should -Throw '*Unknown*'

        $bridge = Join-Path $script:RepoRoot 'scripts\winsmux-core.ps1'
        $invalidCases = [Collections.Generic.List[object]]::new()
        $invalidCases.Add([string[]]@('pipeline', '--workflow-action', 'resume', '--run-id', 'run-123', '--generation-id', 'generation-123', '--config-fingerprint', ('sha256:' + ('a' * 64)), '--source-head', ('b' * 40), '--json')) | Out-Null
        $invalidCases.Add([string[]](@('pipeline', '--workflow-action', 'resume') + $common + @('--run-id', 'other'))) | Out-Null
        $invalidCases.Add([string[]](@('pipeline', '--workflow-action', 'resume') + $common + @('--unknown', 'x'))) | Out-Null
        foreach ($invalidArguments in $invalidCases) {
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile', '-File', $bridge) + $invalidArguments) { $startInfo.ArgumentList.Add([string]$argument) }
            $process = [Diagnostics.Process]::Start($startInfo)
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $output = @($stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $exitCode = $process.ExitCode
            $output.Count | Should -Be 1 -Because $stderr
            $payload = $output[0] | ConvertFrom-Json -ErrorAction Stop
            $payload.status | Should -Be 'rejected'
            $exitCode | Should -Be 1
        }
    }

    It 'A02 invokes workspace-plan exactly once and consumes its one strict JSON object' {
        Mock Invoke-TeamPipelineBridge {
            [PSCustomObject]@{
                ExitCode = 0
                Output = '{"schema_version":1,"config_fingerprint":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","resolved_bindings":{},"workflow":{}}'
            }
        }

        $plan = Invoke-TeamPipelineWorkspacePlanOnce -ProjectDir $TestDrive -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' -RunId 'run-123'

        $plan.schema_version | Should -Be 1
        $plan.workflow | Should -BeOfType ([System.Collections.IDictionary])
        Should -Invoke Invoke-TeamPipelineBridge -Times 1 -Exactly
    }

    It 'A03 rejects nonzero, malformed, or extra workspace-plan output' {
        Mock Invoke-TeamPipelineBridge { $script:WorkspacePlanResult }
        $cases = @(
            [PSCustomObject]@{ ExitCode = 1; Output = '{}' },
            [PSCustomObject]@{ ExitCode = 0; Output = '{invalid' },
            [PSCustomObject]@{ ExitCode = 0; Output = '{"workflow":{}} trailing' }
        )

        foreach ($case in $cases) {
            $script:WorkspacePlanResult = $case
            { Invoke-TeamPipelineWorkspacePlanOnce -ProjectDir $TestDrive -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' -RunId 'run-123' } | Should -Throw 'workspace_plan_*'
        }
        Should -Invoke Invoke-TeamPipelineBridge -Times 3 -Exactly
    }

    It 'W16 reads BOM-free UTF-8 once and persists only digest metadata' {
        $path = Join-Path $TestDrive 'task.txt'
        [System.IO.File]::WriteAllBytes($path, [System.Text.UTF8Encoding]::new($false).GetBytes('日本語 task'))

        $input = Read-DeclarativeWorkflowTaskFile -Path $path
        $run = New-DeclarativeWorkflowRun -Plan (New-TestWorkflowPlan) -RunId 'run-123' -GenerationId 'generation-123' -SourceHead ('b' * 40) -TaskInput $input
        $json = $run | ConvertTo-Json -Depth 20

        $input.Text | Should -Be '日本語 task'
        $run.task_byte_count | Should -Be 14
        $run.task_sha256 | Should -Match '^sha256:[0-9a-f]{64}$'
        $json | Should -Not -Match '日本語 task'
        $json | Should -Not -Match ([regex]::Escape($path))
    }

    It 'W16 uses the shared SHA-256 boundary for task input and completion envelopes under Windows PowerShell 5.1' {
        $caseRoot = Join-Path $TestDrive 'task659-ps51-digest-boundary'
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $taskPath = Join-Path $caseRoot 'task.txt'
        $childScriptPath = Join-Path $caseRoot 'validate-digest-boundary.ps1'
        [System.IO.File]::WriteAllBytes($taskPath, [System.Text.UTF8Encoding]::new($false).GetBytes('PS5.1 digest boundary'))

        $childScript = @'
param(
    [Parameter(Mandatory = $true)][string]$DeclarativeScript,
    [Parameter(Mandatory = $true)][string]$TeamPipelineScript,
    [Parameter(Mandatory = $true)][string]$TaskPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. $DeclarativeScript
. $TeamPipelineScript
$Error.Clear()

$taskInput = Read-DeclarativeWorkflowTaskFile -Path $TaskPath
$plan = [ordered]@{
    schema_version = 1
    workflow_id = 'bugfix'
    recipe_ref = 'bugfix-two-slot'
    config_fingerprint = ('sha256:' + ('a' * 64))
    workflow_fingerprint = ('sha256:' + ('d' * 64))
    resolved_bindings = [ordered]@{ implement = 'worker-1' }
    nodes = @(
        [ordered]@{ node_id = 'inspect'; pane_ref = 'implement'; action = 'operator-dispatch'; depends_on = @(); idempotency_key = 'run-ps51:inspect'; cleanup = 'retain' }
    )
    cleanup_actions = @('release-run-lock')
}
$run = New-DeclarativeWorkflowRun -Plan $plan -RunId 'run-ps51' -GenerationId 'generation-ps51' -SourceHead ('b' * 40) -TaskInput $taskInput
$instruction = New-TeamPipelineDeclarativeCompletionInstruction -Run $run -NodeId 'inspect' -SessionName 'workflow-ps51' -Target 'worker-1' -PaneId '%2' -Role 'implement'
$mailboxCommand = @($instruction -split '\r?\n' | Where-Object { $_ -like 'winsmux mailbox-send *' })
if ($mailboxCommand.Count -ne 1 -or $mailboxCommand[0] -notmatch "^winsmux mailbox-send '[^']+' '(?<payload>.+)'$") {
    throw 'completion instruction did not contain exactly one mailbox envelope command.'
}
$envelope = $matches['payload'] | ConvertFrom-Json -ErrorAction Stop

[PSCustomObject][ordered]@{
    host_version = $PSVersionTable.PSVersion.ToString()
    error_count = @($Error).Count
    task = [ordered]@{
        text = $taskInput.Text
        byte_count = $taskInput.ByteCount
        sha256 = $taskInput.Sha256
    }
    envelope = [ordered]@{
        mailbox_version = $envelope.mailbox_version
        message_id = $envelope.message_id
        correlation_id = $envelope.correlation_id
        idempotency_key = $envelope.idempotency_key
        message_type = $envelope.message_type
        state = $envelope.state
        ack_required = $envelope.ack_required
        from = $envelope.from
        to = $envelope.to
        timestamp = $envelope.timestamp
        content = [ordered]@{
            event = $envelope.content.event
            status = $envelope.content.status
            pane_id = $envelope.content.pane_id
            role = $envelope.content.role
            data = $envelope.content.data
        }
    }
} | ConvertTo-Json -Compress -Depth 12
'@
        [System.IO.File]::WriteAllText($childScriptPath, $childScript, [System.Text.UTF8Encoding]::new($false))

        $declarativeScript = Join-Path $script:RepoRoot 'winsmux-core\scripts\declarative-workflow.ps1'
        $teamPipelineScript = Join-Path $script:RepoRoot 'winsmux-core\scripts\team-pipeline.ps1'
        $output = @(& powershell.exe -NoProfile -File $childScriptPath -DeclarativeScript $declarativeScript -TeamPipelineScript $teamPipelineScript -TaskPath $taskPath 2>&1)
        $exitCode = $LASTEXITCODE
        $jsonLine = @($output | Where-Object { ([string]$_).TrimStart().StartsWith('{') } | Select-Object -Last 1)

        $jsonLine.Count | Should -Be 1 -Because (($output | Out-String).Trim())
        $result = ([string]$jsonLine[0]) | ConvertFrom-Json
        $result.host_version | Should -Match '^5\.1\.'
        $result.error_count | Should -Be 0
        $result.task.text | Should -Be 'PS5.1 digest boundary'
        $result.task.byte_count | Should -Be 21
        $result.task.sha256 | Should -Be 'sha256:f960845f68f1ab41d39e591c0280d872b2bf4ed2141a35646a4c81810f4e1141'
        $result.envelope.mailbox_version | Should -Be 2
        $result.envelope.message_id | Should -Be 'workflow-ack-2ba826611c05107ef2c4af13'
        $result.envelope.correlation_id | Should -Be $result.envelope.message_id
        $result.envelope.idempotency_key | Should -Be ('workflow-completion-' + $result.envelope.message_id.Substring('workflow-ack-'.Length))
        $result.envelope.message_type | Should -Be 'workflow-completion'
        $result.envelope.state | Should -Be 'created'
        $result.envelope.ack_required | Should -BeTrue
        $result.envelope.from | Should -Be 'worker-1'
        $result.envelope.to | Should -Be 'Operator'
        $result.envelope.timestamp | Should -BeNullOrEmpty
        $result.envelope.content.event | Should -Be 'workflow.node.acknowledged'
        $result.envelope.content.status | Should -Be 'succeeded'
        $result.envelope.content.pane_id | Should -Be '%2'
        $result.envelope.content.role | Should -Be 'implement'
        $result.envelope.content.data.run_id | Should -Be 'run-ps51'
        $result.envelope.content.data.node_id | Should -Be 'inspect'
        $result.envelope.content.data.idempotency_key | Should -Be 'run-ps51:inspect'
        $result.envelope.content.data.generation_id | Should -Be 'generation-ps51'
        $result.envelope.content.data.config_fingerprint | Should -Be ('sha256:' + ('a' * 64))
        $result.envelope.content.data.workflow_fingerprint | Should -Be ('sha256:' + ('d' * 64))
        $result.envelope.content.data.source_head | Should -Be ('b' * 40)
        $result.envelope.content.data.pane_id | Should -Be '%2'
        $result.envelope.content.data.status | Should -Be 'succeeded'
        $result.envelope.content.data.evidence_ref | Should -Be 'workflow-ack:run-ps51:inspect'
        $exitCode | Should -Be 0
    }

    It 'W16 rejects BOM NUL invalid UTF-8 and oversized files' {
        $cases = @(
            [byte[]](0xEF, 0xBB, 0xBF, 0x61),
            [byte[]](0x61, 0x00, 0x62),
            [byte[]](0xC3, 0x28),
            [byte[]](New-Object byte[] 262145)
        )
        for ($index = 0; $index -lt $cases.Count; $index++) {
            $path = Join-Path $TestDrive "invalid-$index.bin"
            [IO.File]::WriteAllBytes($path, $cases[$index])
            { Read-DeclarativeWorkflowTaskFile -Path $path } | Should -Throw
        }
    }

    It 'W05 W06 persists intent before one effect and ACK before dependency release' {
        $script:testDeclarativeSessionName = 'workflow-test'
        $run = New-TestRun
        $events = [Collections.Generic.List[string]]::new()
        Mock Invoke-TeamPipelineGuardedSend { [PSCustomObject]@{ Status = 'EXEC_DONE' } }
        Mock Wait-TeamPipelineDeclarativeCompletion {
            $acknowledgement = New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'
            $acknowledgement['transport'] = 'mailbox'
            return $acknowledgement
        }
        Mock Write-TeamPipelineEvent { throw 'declarative completion must not be synthesized from pane text' }
        $manifest = [PSCustomObject]@{ Panes = [ordered]@{ 'worker-1' = [ordered]@{ pane_id = '%2' } } }
        $request = [PSCustomObject]@{ stage = 'EXEC'; node_id = 'inspect'; pane_ref = 'implement'; task = 'Implement TASK-659 safely.' }
        $productionReceipt = Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $run -Manifest $manifest -ProjectDir $TestDrive -SessionName 'workflow-test'

        $productionReceipt.acknowledgement.run_id | Should -Be 'run-123'
        $productionReceipt.acknowledgement.node_id | Should -Be 'inspect'
        $productionReceipt.acknowledgement.pane_id | Should -Be '%2'
        $productionReceipt.acknowledgement.transport | Should -Be 'mailbox'
        $productionReceipt.acknowledgement.evidence_ref | Should -Be 'workflow-ack:run-123:inspect'
        Should -Invoke Write-TeamPipelineEvent -Times 0 -Exactly
        Write-OrchestraLog -ProjectDir $TestDrive -SessionName 'workflow-test' -Event 'workflow.node.acknowledged' -PaneId '%2' -Data $productionReceipt.acknowledgement -MaxBytes 1 -RetentionCount 5 | Out-Null
        Write-OrchestraLog -ProjectDir $TestDrive -SessionName 'workflow-test' -Event 'workflow.node.acknowledged' -PaneId '%2' -Data $productionReceipt.acknowledgement -MaxBytes 1 -RetentionCount 5 | Out-Null
        $resolvedAcknowledgements = @(Resolve-TeamPipelineDeclarativeAcknowledgement -Run $run -NodeId 'inspect' -ProjectDir $TestDrive -SessionName 'workflow-test')
        $resolvedAcknowledgements.Count | Should -Be 1
        $resolvedAcknowledgements[0].pane_id | Should -Be '%2'

        Write-OrchestraLog -ProjectDir $TestDrive -SessionName 'workflow-noise-test' -Event 'workflow.node.acknowledged' -PaneId '%2' -Data $productionReceipt.acknowledgement | Out-Null
        $noiseLogPath = Get-OrchestraLogPath -ProjectDir $TestDrive -SessionName 'workflow-noise-test'
        $noiseWriter = [IO.StreamWriter]::new($noiseLogPath, $true, [Text.UTF8Encoding]::new($false))
        try {
            foreach ($index in 1..4100) { $noiseWriter.WriteLine('{"event":"workflow.noise","data":{"index":' + $index + '}}') }
        } finally {
            $noiseWriter.Dispose()
        }
        $ackBeforeNoise = @(Resolve-TeamPipelineDeclarativeAcknowledgement -Run $run -NodeId 'inspect' -ProjectDir $TestDrive -SessionName 'workflow-noise-test')
        $ackBeforeNoise.Count | Should -Be 1
        $ackBeforeNoise[0].pane_id | Should -Be '%2'

        $conflictingAcknowledgement = Copy-DeclarativeWorkflowValue $productionReceipt.acknowledgement
        $conflictingAcknowledgement.pane_id = '%3'
        Write-OrchestraLog -ProjectDir $TestDrive -SessionName 'workflow-test' -Event 'workflow.node.acknowledged' -PaneId '%3' -Data $conflictingAcknowledgement -MaxBytes 1 -RetentionCount 5 | Out-Null
        $ambiguousAcknowledgements = @(Resolve-TeamPipelineDeclarativeAcknowledgement -Run $run -NodeId 'inspect' -ProjectDir $TestDrive -SessionName 'workflow-test')
        $ambiguousAcknowledgements.Count | Should -Be 2
        @($ambiguousAcknowledgements.pane_id | Sort-Object) | Should -Be @('%2', '%3')
        $ambiguousRun = New-TestRun
        $ambiguousRun.state = 'running'
        $ambiguousRun.nodes.inspect.state = 'dispatching'
        $ambiguousRun.nodes.inspect.attempt = 1
        $script:ambiguousDispatches = 0
        $ambiguousResult = Invoke-DeclarativeWorkflowResume -Run $ambiguousRun -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) } `
            -Dispatch { $script:ambiguousDispatches++ } `
            -ResolveSession { param($paneId) $paneId } `
            -ResolveAcknowledgement { $ambiguousAcknowledgements }
        $ambiguousResult.nodes.inspect.state | Should -Be 'blocked'
        $script:ambiguousDispatches | Should -Be 0

        $result = Invoke-DeclarativeWorkflowNode `
            -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput) `
            -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) $events.Add("save:$($candidate.nodes.inspect.state):$($candidate.nodes.verify.state)") | Out-Null } `
            -Dispatch { param($request) $events.Add("dispatch:$($request.stage)") | Out-Null; New-TestAcceptedReceipt -NodeId 'inspect' -PaneId '%2' } `
            -ResolveSession { param($paneId) $events.Add("session:$paneId") | Out-Null; '%2' }

        $events[0] | Should -Be 'save:dispatching:pending'
        $events[1] | Should -Be 'dispatch:EXEC'
        $events[2] | Should -Be 'session:%2'
        $events[3] | Should -Be 'save:succeeded:pending'
        $events[4] | Should -Be 'save:succeeded:ready'
        @($events | Where-Object { $_ -like 'dispatch:*' }).Count | Should -Be 1
        $result.nodes.inspect.state | Should -Be 'succeeded'
        $result.nodes.inspect.attempt | Should -Be 1
        $result.nodes.inspect.agent_cli_session_id | Should -Be '%2'
        $result.nodes.verify.state | Should -Be 'ready'
    }

    It 'W05 does not call the adapter when intent persistence fails' {
        $script:dispatches = 0
        {
            Invoke-DeclarativeWorkflowNode `
                -Run (New-TestRun) -NodeId 'inspect' -TaskInput (New-TestTaskInput) `
                -Confirmation (New-TestConfirmation) `
                -SaveRun { throw 'injected save failure' } `
                -Dispatch { $script:dispatches++; [PSCustomObject]@{ status = 'accepted' } } `
                -ResolveSession { '%2' }
        } | Should -Throw '*injected save failure*'
        $script:dispatches | Should -Be 0
    }

    It 'W08 W15 blocks ambiguous acknowledgement or missing registry session without redispatch' {
        foreach ($receipt in @($null, [PSCustomObject]@{ status = 'accepted'; target = [PSCustomObject]@{ pane_id = '%2' } })) {
            $script:dispatches = 0
            $run = New-TestRun
            $result = Invoke-DeclarativeWorkflowNode `
                -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput) `
                -Confirmation (New-TestConfirmation) `
                -SaveRun { param($candidate) } `
                -Dispatch { $script:dispatches++; $receipt } `
                -ResolveSession { '' }
            $result.nodes.inspect.state | Should -Be 'blocked'
            $result.nodes.verify.state | Should -Be 'pending'
            $script:dispatches | Should -Be 1
        }

        $secretInput = New-TestTaskInput -Text 'git reset --hard SECRET_MARKER'
        $script:testDeclarativeSessionName = 'privacy-test'
        $secretRun = New-DeclarativeWorkflowRun -Plan (New-TestWorkflowPlan) -RunId 'run-123' -GenerationId 'generation-123' -SourceHead ('b' * 40) -TaskInput $secretInput
        $manifest = [PSCustomObject]@{ Panes = [ordered]@{ 'worker-1' = [ordered]@{ pane_id = '%2' } } }
        $capturedEvents = [Collections.Generic.List[object]]::new()
        $savedRuns = [Collections.Generic.List[string]]::new()
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $capturedEvents.Add([PSCustomObject]@{ event = $Event; data = $Data }) | Out-Null
            return [PSCustomObject]@{ event = $Event; data = $Data }
        }
        $secretResult = Invoke-DeclarativeWorkflowNode -Run $secretRun -NodeId 'inspect' -TaskInput $secretInput -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) $savedRuns.Add(($candidate | ConvertTo-Json -Depth 20 -Compress)) | Out-Null } `
            -Dispatch { param($request) Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $secretRun -Manifest $manifest -ProjectDir $TestDrive -SessionName 'privacy-test' } `
            -ResolveSession { '' }
        $secretResult.nodes.inspect.state | Should -Be 'blocked'
        ($capturedEvents | ConvertTo-Json -Depth 20 -Compress) | Should -Not -Match 'SECRET_MARKER'
        ($savedRuns -join "`n") | Should -Not -Match 'SECRET_MARKER'
    }

    It 'W09 W12 skips succeeded nodes and rejects terminal run resume' {
        $run = New-TestRun
        $run.nodes.inspect.state = 'succeeded'
        $script:dispatches = 0
        $same = Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun { } -Dispatch { $script:dispatches++ } -ResolveSession { 'x' }
        $same.nodes.inspect.state | Should -Be 'succeeded'
        $script:dispatches | Should -Be 0

        foreach ($terminal in @('succeeded', 'cancelled', 'rolled_back')) {
            $run.state = $terminal
            { Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'verify' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun { } -Dispatch { } -ResolveSession { 'x' } } | Should -Throw '*terminal*'
        }
        $run = New-TestRun
        $run.state = 'failed'
        { Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun { } -Dispatch { $script:dispatches++ } -ResolveSession { '%2' } } | Should -Throw '*new operator-approved run*'
        $script:dispatches | Should -Be 0
    }

    It 'W10 W13 W16 rejects stale confirmation and task mismatch before effects' {
        $run = New-TestRun
        $script:effects = 0
        $badConfirmation = New-TestConfirmation
        $badConfirmation.source_head = 'c' * 40
        { Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput) -Confirmation $badConfirmation -SaveRun { $script:effects++ } -Dispatch { $script:effects++ } -ResolveSession { 'x' } } | Should -Throw '*confirmation*'
        { Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput -Text 'changed') -Confirmation (New-TestConfirmation) -SaveRun { $script:effects++ } -Dispatch { $script:effects++ } -ResolveSession { 'x' } } | Should -Throw '*task*'
        $script:effects | Should -Be 0
    }

    It 'W11 persists terminal run state after the final node succeeds' {
        $project = Join-Path $TestDrive 'terminal-run-project'
        $saved = [Collections.Generic.List[object]]::new()
        $save = {
            param($candidate)
            $saved.Add((Copy-DeclarativeWorkflowValue $candidate)) | Out-Null
            Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $candidate | Out-Null
        }
        $dispatch = {
            param($request)
            $paneId = if ($request.node_id -ceq 'inspect') { '%2' } else { '%3' }
            New-TestAcceptedReceipt -NodeId $request.node_id -PaneId $paneId
        }
        $resolveSession = { param($paneId) $paneId }

        $afterInspect = Invoke-DeclarativeWorkflowNode -Run (New-TestRun) -NodeId 'inspect' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun $save -Dispatch $dispatch -ResolveSession $resolveSession
        $afterVerify = Invoke-DeclarativeWorkflowNode -Run $afterInspect -NodeId 'verify' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun $save -Dispatch $dispatch -ResolveSession $resolveSession
        $reloaded = Read-DeclarativeWorkflowRunState -ProjectDir $project -RunId 'run-123'

        $afterVerify.state | Should -Be 'succeeded'
        $saved[$saved.Count - 1].state | Should -Be 'succeeded'
        $reloaded.state | Should -Be 'succeeded'
    }

    It 'W11 reconciles a durable ACK after the ACK-event cut without redispatch and advances only unfinished nodes' {
        $run = New-TestRun
        $run.state = 'running'
        $run.nodes.inspect.state = 'dispatching'
        $run.nodes.inspect.attempt = 1
        $saved = [Collections.Generic.List[object]]::new()
        $requests = [Collections.Generic.List[object]]::new()

        $result = Invoke-DeclarativeWorkflowResume -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) $saved.Add((Copy-DeclarativeWorkflowValue $candidate)) | Out-Null } `
            -Dispatch { param($request) $requests.Add($request) | Out-Null; New-TestAcceptedReceipt -NodeId $request.node_id -PaneId '%3' } `
            -ResolveSession { param($paneId) $paneId } `
            -ResolveAcknowledgement { param($candidate, $nodeId) New-TestAcknowledgement -NodeId $nodeId -PaneId '%2' }

        $result.state | Should -Be 'succeeded'
        $result.nodes.inspect.state | Should -Be 'succeeded'
        $result.nodes.inspect.attempt | Should -Be 1
        $result.nodes.inspect.agent_cli_session_id | Should -Be '%2'
        $result.nodes.inspect.evidence_refs | Should -Contain 'workflow-ack:run-123:inspect'
        $result.nodes.inspect.idempotency_key | Should -Be 'run-123:inspect'
        @($requests | Where-Object { $_.node_id -ceq 'inspect' }).Count | Should -Be 0
        @($requests | Where-Object { $_.node_id -ceq 'verify' }).Count | Should -Be 1
        $saved[$saved.Count - 1].state | Should -Be 'succeeded'
    }

    It 'W11 keeps a blocked node without ACK or registry evidence blocked with zero dispatches' {
        $run = New-TestRun
        $run.state = 'blocked'
        $run.nodes.inspect.state = 'blocked'
        $run.nodes.inspect.attempt = 1
        $run.nodes.inspect.evidence_refs = @()
        $saved = [Collections.Generic.List[object]]::new()
        $script:w11Dispatches = 0

        $result = Invoke-DeclarativeWorkflowResume -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) $saved.Add((Copy-DeclarativeWorkflowValue $candidate)) | Out-Null } `
            -Dispatch { $script:w11Dispatches++; throw 'dispatch must not be called without reconciliation evidence' } `
            -ResolveSession { '' } `
            -ResolveAcknowledgement { $null }

        $result.state | Should -Be 'blocked'
        $result.nodes.inspect.state | Should -Be 'blocked'
        $script:w11Dispatches | Should -Be 0
        $saved[$saved.Count - 1].state | Should -Be 'blocked'
        $saved[$saved.Count - 1].nodes.inspect.attempt | Should -Be 1

        $conflict = New-TestRun
        $conflict.state = 'blocked'
        $conflict.nodes.inspect.state = 'blocked'
        $conflict.nodes.inspect.attempt = 1
        $conflict.nodes.inspect.agent_cli_session_id = '%2'
        $conflict.nodes.inspect.evidence_refs = @('workflow-ack:run-123:inspect')
        $conflictResult = Invoke-DeclarativeWorkflowResume -Run $conflict -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) } `
            -Dispatch { $script:w11Dispatches++; throw 'conflicting acknowledgement must not redispatch' } `
            -ResolveSession { param($paneId) $paneId } `
            -ResolveAcknowledgement { New-TestAcknowledgement -NodeId 'inspect' -PaneId '%3' }
        $conflictResult.nodes.inspect.state | Should -Be 'blocked'
        $script:w11Dispatches | Should -Be 0
    }

    It 'W11 skips a succeeded sibling without an additional effect when another node remains blocked' {
        $run = New-TestRun
        $run.state = 'blocked'
        $run.nodes.inspect.state = 'blocked'
        $run.nodes.inspect.attempt = 1
        $run.nodes.inspect.evidence_refs = @()
        $run.nodes.verify.depends_on = @()
        $run.nodes.verify.state = 'succeeded'
        $run.nodes.verify.attempt = 1
        $run.nodes.verify.agent_cli_session_id = 'cli-session:verify-pane'
        $run.nodes.verify.evidence_refs = @('evidence:verify')
        $script:w11Effects = 0

        $result = Invoke-DeclarativeWorkflowResume -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) } `
            -Dispatch { $script:w11Effects++; throw 'succeeded sibling must be skipped' } `
            -ResolveSession { '' } `
            -ResolveAcknowledgement { $null }

        $result.state | Should -Be 'blocked'
        $result.nodes.inspect.state | Should -Be 'blocked'
        $result.nodes.verify.state | Should -Be 'succeeded'
        $script:w11Effects | Should -Be 0
    }

    It 'W11 wires resume through the reconciliation choke point for blocked evidence-free runs' {
        $script:w11ResumeCalls = 0
        $script:w11WiredRun = New-TestRun
        $script:w11WiredRun.state = 'blocked'
        $script:w11WiredRun.nodes.inspect.state = 'blocked'
        $script:w11WiredRun.nodes.inspect.attempt = 1
        $script:w11WiredRun.nodes.inspect.evidence_refs = @()
        $taskFile = Join-Path $TestDrive 'resume-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))

        Mock Read-DeclarativeWorkflowRunState { Copy-DeclarativeWorkflowValue $script:w11WiredRun }
        Mock Invoke-TeamPipelineWorkspacePlanOnce { [ordered]@{ config_fingerprint = ('sha256:' + ('a' * 64)); resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }; workflow = (New-TestWorkflowPlan) } }
        Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'w11-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
        Mock Get-TeamPipelineSessionName { 'w11-session' }
        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Mock Assert-TeamPipelineDeclarativeRunLockAdmission { }
        Mock Save-DeclarativeWorkflowRunState { }
        Mock Invoke-DeclarativeWorkflowResume {
            param($Run, $TaskInput, $Confirmation, $SaveRun, $Dispatch, $ResolveSession, $ResolveAcknowledgement, $ValidateSnapshot)
            $script:w11ResumeCalls++
            & $SaveRun $Run
            return $Run
        }

        $result = Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $TestDrive

        $result.status | Should -Be 'blocked'
        $result.state | Should -Be 'blocked'
        $script:w11ResumeCalls | Should -Be 1
        Should -Invoke Invoke-DeclarativeWorkflowResume -Times 1 -Exactly
    }

    It 'C07 advances a start run through every ready node and releases the terminal lock exactly once' {
        $project = Join-Path $TestDrive 'start-run-advancement'
        $run = New-TestRun
        $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
        $effects = [Collections.Generic.List[string]]::new()
        $releases = [Collections.Generic.List[string]]::new()

        $after = Invoke-TeamPipelineDeclarativeRunAdvancement -ProjectDir $project -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) } `
            -Dispatch {
                param($request)
                $effects.Add([string]$request.node_id) | Out-Null
                $paneId = if ([string]$request.node_id -ceq 'inspect') { '%2' } else { '%3' }
                New-TestAcceptedReceipt -NodeId $request.node_id -PaneId $paneId
            } `
            -ResolveSession { param($paneId) $paneId } `
            -ResolveAcknowledgement { throw 'a fresh start must not reconcile an in-flight node' } `
            -ReleaseLock {
                param($path)
                $releases.Add($path) | Out-Null
                Remove-Item -LiteralPath $path -Force
            }

        $after.state | Should -Be 'succeeded'
        $after.nodes.inspect.state | Should -Be 'succeeded'
        $after.nodes.verify.state | Should -Be 'succeeded'
        [string]::Join(',', @($effects)) | Should -Be 'inspect,verify'
        $releases.Count | Should -Be 1
        Test-Path -LiteralPath $lock | Should -BeFalse
    }

    It 'D01 rejects a fresh manifest generation mismatch before workspace planning, state, lock, or dispatch effects' {
        $taskFile = Join-Path $TestDrive 'manifest-generation-mismatch-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        $script:manifestGenerationMismatchWorkspacePlans = 0
        $script:manifestGenerationMismatchStateWrites = 0
        $script:manifestGenerationMismatchLocks = 0
        $script:manifestGenerationMismatchAdvances = 0

        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Mock Read-TeamPipelineManifest {
            [PSCustomObject]@{
                Session = [ordered]@{ name = 'workflow-session'; generation_id = 'generation-replaced' }
                Panes = [ordered]@{}
            }
        }
        Mock Invoke-TeamPipelineWorkspacePlanOnce { $script:manifestGenerationMismatchWorkspacePlans++ }
        Mock Save-DeclarativeWorkflowRunState { $script:manifestGenerationMismatchStateWrites++ }
        Mock New-DeclarativeWorkflowRunLock { $script:manifestGenerationMismatchLocks++ }
        Mock Invoke-TeamPipelineDeclarativeRunAdvancement { $script:manifestGenerationMismatchAdvances++ }

        {
            Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
                -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $TestDrive
        } | Should -Throw '*workflow_manifest_generation_mismatch*'

        $script:manifestGenerationMismatchWorkspacePlans | Should -Be 0
        $script:manifestGenerationMismatchStateWrites | Should -Be 0
        $script:manifestGenerationMismatchLocks | Should -Be 0
        $script:manifestGenerationMismatchAdvances | Should -Be 0
    }

    It 'W11 routes start through the one run-advancement choke point' {
        $taskFile = Join-Path $TestDrive 'start-route-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        $script:startRouteRun = New-TestRun

        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Mock Invoke-TeamPipelineWorkspacePlanOnce {
            $workflow = [ordered]@{}
            (New-TestWorkflowPlan).PSObject.Properties | ForEach-Object { $workflow[$_.Name] = $_.Value }
            [ordered]@{
                config_fingerprint = ('sha256:' + ('a' * 64))
                resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
                workflow = $workflow
            }
        }
        Mock New-DeclarativeWorkflowRun { Copy-DeclarativeWorkflowValue $script:startRouteRun }
        Mock New-DeclarativeWorkflowRunLock { Join-Path $TestDrive 'synthetic-start.lock' }
        Mock Save-DeclarativeWorkflowRunState { }
        Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'start-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
        Mock Get-TeamPipelineSessionName { 'start-session' }
        Mock Invoke-TeamPipelineDeclarativeRunAdvancement {
            $completed = Copy-DeclarativeWorkflowValue $script:startRouteRun
            $completed.state = 'succeeded'
            return $completed
        }
        Mock Invoke-DeclarativeWorkflowNode { throw 'start must not retain a second direct node-dispatch path' }

        $result = Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
            -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
            -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $TestDrive

        $result.status | Should -Be 'accepted'
        $result.state | Should -Be 'succeeded'
        Should -Invoke Invoke-TeamPipelineDeclarativeRunAdvancement -Times 1 -Exactly
        Should -Invoke Invoke-DeclarativeWorkflowNode -Times 0 -Exactly
    }

    It 'C07 recovers one pending terminal action after validation and preserves its terminal outcome' {
        foreach ($terminalState in @('succeeded', 'failed', 'cancelled')) {
            $project = Join-Path $TestDrive "terminal-recovery-$terminalState"
            $run = New-TestRun
            $run.state = $terminalState
            $run.nodes.inspect.state = if ($terminalState -eq 'failed') { 'failed' } else { 'succeeded' }
            $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
            $script:terminalRecoverySnapshotCalls = 0
            $releases = [Collections.Generic.List[string]]::new()

            $after = Invoke-TeamPipelineDeclarativeTerminalRecovery -ProjectDir $project -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
                -ValidateSnapshot { param($candidate) $script:terminalRecoverySnapshotCalls++ } `
                -SaveRun { param($candidate) } `
                -ReleaseLock {
                    param($path)
                    $releases.Add($path) | Out-Null
                    Remove-Item -LiteralPath $path -Force
                }

            $after.state | Should -Be $terminalState
            $after.cleanup_journal[0].state | Should -Be 'succeeded'
            $script:terminalRecoverySnapshotCalls | Should -Be 1
            $releases.Count | Should -Be 1
            Test-Path -LiteralPath $lock | Should -BeFalse
        }
    }

    It 'C07 permits terminal resume recovery only for one pending typed cleanup action' {
        $project = Join-Path $TestDrive 'terminal-recovery-admission'
        $taskInput = New-TestTaskInput
        $confirmation = New-TestConfirmation

        foreach ($case in @(
                [PSCustomObject]@{ Name = 'succeeded'; Configure = { param($run) $run.cleanup_journal[0].state = 'succeeded' } },
                [PSCustomObject]@{ Name = 'running'; Configure = { param($run) $run.cleanup_journal[0].state = 'running' } },
                [PSCustomObject]@{ Name = 'blocked'; Configure = { param($run) $run.cleanup_journal[0].state = 'blocked' } },
                [PSCustomObject]@{ Name = 'unknown'; Configure = { param($run) $run.cleanup_journal[0].state = 'unknown' } },
                [PSCustomObject]@{ Name = 'malformed'; Configure = { param($run) $run.cleanup_journal = @([ordered]@{ state = 'pending' }) } },
                [PSCustomObject]@{ Name = 'multiple'; Configure = { param($run) $run.cleanup_journal = @($run.cleanup_journal[0], (Copy-DeclarativeWorkflowValue $run.cleanup_journal[0])) } }
            )) {
            $run = New-TestRun
            $run.state = 'failed'
            $run.nodes.inspect.state = 'failed'
            & $case.Configure $run
            $before = $run | ConvertTo-Json -Depth 40 -Compress
            $script:terminalRecoveryEffects = 0

            {
                Invoke-TeamPipelineDeclarativeTerminalRecovery -ProjectDir $project -Run $run -TaskInput $taskInput -Confirmation $confirmation `
                    -ValidateSnapshot { param($candidate) } `
                    -SaveRun { $script:terminalRecoveryEffects++ } `
                    -ReleaseLock { $script:terminalRecoveryEffects++ }
            } | Should -Throw -Because "terminal cleanup state '$($case.Name)' is not a recoverable pending action"

            $script:terminalRecoveryEffects | Should -Be 0
            ($run | ConvertTo-Json -Depth 40 -Compress) | Should -Be $before
        }
    }

    It 'C07 rejects every non-pending terminal resume recovery before save release or dispatch' {
        $taskFile = Join-Path $TestDrive 'terminal-recovery-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))

        foreach ($case in @(
                [PSCustomObject]@{ Name = 'succeeded'; Configure = { param($run) $run.cleanup_journal[0].state = 'succeeded' } },
                [PSCustomObject]@{ Name = 'running'; Configure = { param($run) $run.cleanup_journal[0].state = 'running' } },
                [PSCustomObject]@{ Name = 'blocked'; Configure = { param($run) $run.cleanup_journal[0].state = 'blocked' } },
                [PSCustomObject]@{ Name = 'unknown'; Configure = { param($run) $run.cleanup_journal[0].state = 'unknown' } },
                [PSCustomObject]@{ Name = 'malformed'; Configure = { param($run) $run.cleanup_journal = @([ordered]@{ state = 'pending' }) } },
                [PSCustomObject]@{ Name = 'multiple'; Configure = { param($run) $run.cleanup_journal = @($run.cleanup_journal[0], (Copy-DeclarativeWorkflowValue $run.cleanup_journal[0])) } }
            )) {
            $script:terminalResumeRun = New-TestRun
            $script:terminalResumeRun.state = 'failed'
            $script:terminalResumeRun.nodes.inspect.state = 'failed'
            & $case.Configure $script:terminalResumeRun
            $before = $script:terminalResumeRun | ConvertTo-Json -Depth 40 -Compress
            $script:terminalResumeSaveCount = 0
            $script:terminalResumeDispatchCount = 0
            $script:terminalResumeSnapshotCount = 0

            Mock Read-DeclarativeWorkflowRunState { Copy-DeclarativeWorkflowValue $script:terminalResumeRun }
            Mock Invoke-TeamPipelineWorkspacePlanOnce {
                $script:terminalResumeSnapshotCount++
                [ordered]@{
                    config_fingerprint = ('sha256:' + ('a' * 64))
                    resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
                    workflow = (New-TestWorkflowPlan)
                }
            }
            Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'terminal-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
            Mock Get-TeamPipelineSessionName { 'terminal-session' }
            Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
            Mock Save-DeclarativeWorkflowRunState { $script:terminalResumeSaveCount++ }
            Mock Invoke-TeamPipelineDeclarativeDispatch { $script:terminalResumeDispatchCount++; throw 'terminal recovery must not dispatch' }

            {
                Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId 'generation-123' `
                    -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $TestDrive
            } | Should -Throw -Because "terminal cleanup state '$($case.Name)' is not admissible for recovery"

            $script:terminalResumeSnapshotCount | Should -Be 1
            $script:terminalResumeSaveCount | Should -Be 0
            $script:terminalResumeDispatchCount | Should -Be 0
            ($script:terminalResumeRun | ConvertTo-Json -Depth 40 -Compress) | Should -Be $before
        }
    }

    It 'C01 C02 C04 releases only an owned run lock once after persisted intent' {
        $project = Join-Path $TestDrive 'project'
        $run = New-TestRun
        $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
        $events = [Collections.Generic.List[string]]::new()
        $first = Invoke-DeclarativeWorkflowCleanup -ProjectDir $project -Run $run -SaveRun { param($candidate) $events.Add("save:$($candidate.cleanup_journal[0].state)") | Out-Null } -ReleaseLock { param($path) $events.Add("release:$path") | Out-Null; Remove-Item -LiteralPath $path }
        $second = Invoke-DeclarativeWorkflowCleanup -ProjectDir $project -Run $first -SaveRun { param($candidate) $events.Add("save:$($candidate.cleanup_journal[0].state)") | Out-Null } -ReleaseLock { $events.Add('release:again') | Out-Null }

        $events[0] | Should -Be 'save:running'
        @($events | Where-Object { $_ -like 'release:*' }).Count | Should -Be 1
        $second.cleanup_journal[0].state | Should -Be 'succeeded'
        Test-Path -LiteralPath $lock | Should -BeFalse
    }

    It 'C03 C05 blocks ambiguous or mismatched cleanup without repeating release' {
        $project = Join-Path $TestDrive 'blocked-project'
        $run = New-TestRun
        $run.cleanup_journal[0].state = 'running'
        $script:releases = 0
        $ambiguous = Invoke-DeclarativeWorkflowCleanup -ProjectDir $project -Run $run -SaveRun { } -ReleaseLock { $script:releases++ }
        $ambiguous.cleanup_journal[0].state | Should -Be 'blocked'
        $script:releases | Should -Be 0

        $run = New-TestRun
        $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
        $payload = Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json
        $payload.source_head = 'c' * 40
        [IO.File]::WriteAllText($lock, ($payload | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $blocked = Invoke-DeclarativeWorkflowCleanup -ProjectDir $project -Run $run -SaveRun { } -ReleaseLock { $script:releases++ }
        $blocked.cleanup_journal[0].state | Should -Be 'blocked'
        $script:releases | Should -Be 0
        Test-Path -LiteralPath $lock | Should -BeTrue

        $junctionProject = Join-Path $TestDrive 'junction-project'
        $runsRoot = Join-Path $junctionProject '.winsmux\workflow-runs'
        $externalRunRoot = Join-Path $TestDrive 'external-run-root'
        [IO.Directory]::CreateDirectory($runsRoot) | Out-Null
        [IO.Directory]::CreateDirectory($externalRunRoot) | Out-Null
        $externalLock = Join-Path $externalRunRoot 'run.lock'
        $junctionRun = New-TestRun
        $junctionPayload = [ordered]@{
            run_id = $junctionRun.run_id
            generation_id = $junctionRun.generation_id
            config_fingerprint = $junctionRun.config_fingerprint
            source_head = $junctionRun.source_head
        }
        [IO.File]::WriteAllText($externalLock, ($junctionPayload | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $junctionPath = Join-Path $runsRoot 'run-123'
        try {
            try {
                $junction = New-Item -ItemType Junction -Path $junctionPath -Target $externalRunRoot -ErrorAction Stop
            } catch {
                throw "Junction fixture creation failed explicitly: $($_.Exception.Message)"
            }
            [bool]($junction.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -BeTrue
            $junctionBlocked = Invoke-DeclarativeWorkflowCleanup -ProjectDir $junctionProject -Run $junctionRun -SaveRun { } -ReleaseLock { $script:releases++; Remove-Item -LiteralPath $args[0] }
            $junctionBlocked.cleanup_journal[0].state | Should -Be 'blocked'
            $script:releases | Should -Be 0
            Test-Path -LiteralPath $externalLock -PathType Leaf | Should -BeTrue
        } finally {
            if ([IO.Directory]::Exists($junctionPath)) { [IO.Directory]::Delete($junctionPath) }
        }
        Test-Path -LiteralPath $externalLock -PathType Leaf | Should -BeTrue
    }

    It 'W18 treats pane completion text as non-evidence until a typed mailbox completion is durable' {
        $run = New-TestRun
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; role = 'Worker' }
            }
        }
        Mock Invoke-TeamPipelineGuardedSend {
            [PSCustomObject]@{ Status = 'EXEC_DONE'; Target = 'worker-1' }
        }
        Mock Wait-TeamPipelineStage {
            throw 'pane output must not be polled for declarative completion'
        }
        Mock Wait-TeamPipelineDeclarativeCompletion { $null }
        Mock Write-TeamPipelineEvent { throw 'the dispatcher must not synthesize an acknowledgement' }

        $result = Invoke-TeamPipelineDeclarativeDispatch -Request ([PSCustomObject]@{
                stage = 'EXEC'; node_id = 'inspect'; pane_ref = 'implement'; task = 'safe task body'
            }) -Run $run -Manifest $manifest -ProjectDir $TestDrive -SessionName 'winsmux-orchestra'

        $result.status | Should -Be 'blocked'
        Should -Invoke Wait-TeamPipelineStage -Times 0 -Exactly
        Should -Invoke Wait-TeamPipelineDeclarativeCompletion -Times 1 -Exactly
        Should -Invoke Write-TeamPipelineEvent -Times 0 -Exactly
    }

    It 'W06 accepts only a durable typed mailbox completion and retains its exact tuple' {
        $run = New-TestRun
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; role = 'Worker' }
            }
        }
        $ack = New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'
        $ack['transport'] = 'mailbox'
        Mock Invoke-TeamPipelineGuardedSend { [PSCustomObject]@{ Status = 'SENT'; Target = 'worker-1' } }
        Mock Wait-TeamPipelineStage { throw 'pane output must not be polled for declarative completion' }
        Mock Wait-TeamPipelineDeclarativeCompletion { $ack }

        $result = Invoke-TeamPipelineDeclarativeDispatch -Request ([PSCustomObject]@{
                stage = 'EXEC'; node_id = 'inspect'; pane_ref = 'implement'; task = 'safe task body'
            }) -Run $run -Manifest $manifest -ProjectDir $TestDrive -SessionName 'winsmux-orchestra'

        $result.status | Should -Be 'accepted'
        $result.acknowledgement.workflow_fingerprint | Should -Be ('sha256:' + ('d' * 64))
        $result.acknowledgement.pane_id | Should -Be '%2'
        Should -Invoke Wait-TeamPipelineStage -Times 0 -Exactly
    }

    It 'W17 blocks conflicting or unknown durable ACK candidates for the same identity' {
        $run = New-TestRun
        $first = New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'
        $first['transport'] = 'mailbox'
        $conflict = Copy-DeclarativeWorkflowValue $first
        $conflict.source_head = ('c' * 40)
        $unknown = Copy-DeclarativeWorkflowValue $first
        $unknown['unexpected'] = 'field'

        @(Resolve-DeclarativeWorkflowAcknowledgementCandidates -Run $run -NodeId 'inspect' -Acknowledgements @($first, $first)).Count | Should -Be 1
        @(Resolve-DeclarativeWorkflowAcknowledgementCandidates -Run $run -NodeId 'inspect' -Acknowledgements @($first, $conflict)).Count | Should -Be 2
        @(Resolve-DeclarativeWorkflowAcknowledgementCandidates -Run $run -NodeId 'inspect' -Acknowledgements @($unknown)).Count | Should -Be 1

        $blocked = Invoke-DeclarativeWorkflowResume -Run ([ordered]@{
                schema_version = $run.schema_version; workflow_id = $run.workflow_id; recipe_ref = $run.recipe_ref; run_id = $run.run_id
                state = 'blocked'; generation_id = $run.generation_id; config_fingerprint = $run.config_fingerprint; workflow_fingerprint = $run.workflow_fingerprint
                source_head = $run.source_head; task_sha256 = $run.task_sha256; task_byte_count = $run.task_byte_count; resolved_bindings = $run.resolved_bindings
                normalized_snapshot = $run.normalized_snapshot; nodes = $run.nodes; cleanup_journal = $run.cleanup_journal; rollback_state = $run.rollback_state
            }) -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun { } -Dispatch { throw 'must not dispatch' } -ResolveSession { param($paneId) $paneId } `
            -ResolveAcknowledgement { @($first, $conflict) }
        $blocked.state | Should -Be 'blocked'
    }

    It 'W19 observes the actual project HEAD exactly once and rejects mismatch or probe failure before state mutation' {
        $expectedHead = ('b' * 40)
        $observed = Get-TeamPipelineDeclarativeProjectHead -ProjectDir $script:RepoRoot
        $observed | Should -Match '^[0-9a-f]{40}$'
        $expectedHead | Should -Not -Be $observed

        { Assert-TeamPipelineDeclarativeSourceHead -ExpectedSourceHead $expectedHead -ObservedSourceHead $observed } | Should -Throw '*source head*'
        { Get-TeamPipelineDeclarativeProjectHead -ProjectDir (Join-Path $TestDrive 'not-a-git-project') } | Should -Throw '*source head*'
    }

    It 'W20 persists workflow fingerprint and rejects a workflow-only resume mismatch before dispatch' {
        $run = New-TestRun
        $run.state = 'blocked'
        $run.nodes.inspect.state = 'blocked'
        $run.nodes.inspect.attempt = 1
        $before = $run | ConvertTo-Json -Depth 40 -Compress
        $script:workflowEffects = 0

        {
            Invoke-DeclarativeWorkflowResume -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun { $script:workflowEffects++ } `
                -Dispatch { $script:workflowEffects++ } -ResolveSession { '' } -ResolveAcknowledgement { $null } `
                -ValidateSnapshot { param($candidate) Assert-DeclarativeWorkflowSnapshot -Run $candidate -WorkflowFingerprint ('sha256:' + ('e' * 64)) -ConfigFingerprint $candidate.config_fingerprint -ResolvedBindings $candidate.resolved_bindings }
        } | Should -Throw '*snapshot*'
        $script:workflowEffects | Should -Be 0
        ($run | ConvertTo-Json -Depth 40 -Compress) | Should -Be $before
    }

    It 'A21 structurally binds the persisted DAG projection before reconciliation, save, dispatch, or cleanup' {
        $plan = New-TestWorkflowPlan
        $taskInput = New-TestTaskInput
        $confirmation = New-TestConfirmation

        { Assert-DeclarativeWorkflowExecutionProjection -Run (New-TestRun) -Plan $plan } | Should -Not -Throw

        $cases = @(
            [PSCustomObject]@{
                Name = 'extra-normalized-node'
                Mutate = {
                    param($candidate)
                    $candidate.normalized_snapshot.nodes += [ordered]@{
                        node_id = 'extra'; pane_ref = 'implement'; action = 'operator-dispatch'; depends_on = @()
                        idempotency_key = 'run-123:extra'; cleanup = 'retain'
                    }
                }
            },
            [PSCustomObject]@{
                Name = 'missing-normalized-node'
                Mutate = { param($candidate) $candidate.normalized_snapshot.nodes = @($candidate.normalized_snapshot.nodes | Select-Object -First 1) }
            },
            [PSCustomObject]@{
                Name = 'reordered-normalized-nodes'
                Mutate = { param($candidate) $candidate.normalized_snapshot.nodes = @($candidate.normalized_snapshot.nodes[1], $candidate.normalized_snapshot.nodes[0]) }
            },
            [PSCustomObject]@{
                Name = 'runtime-node-order'
                Mutate = { param($candidate) $candidate.node_order = @('verify', 'inspect') }
            }
        )

        foreach ($field in @('node_id', 'action', 'pane_ref', 'depends_on', 'idempotency_key', 'cleanup', 'context_pack_ref')) {
            $cases += [PSCustomObject]@{
                Name = "mutated-runtime-$field"
                Mutate = {
                    param($candidate)
                    switch ($field) {
                        'node_id' { $candidate.nodes.inspect.node_id = 'verify' }
                        'action' { $candidate.nodes.inspect.action = 'verification' }
                        'pane_ref' { $candidate.nodes.inspect.pane_ref = 'verify' }
                        'depends_on' { $candidate.nodes.inspect.depends_on = @('verify') }
                        'idempotency_key' { $candidate.nodes.inspect.idempotency_key = 'run-123:other' }
                        'cleanup' { $candidate.nodes.inspect.cleanup = 'delete-everything' }
                        'context_pack_ref' { $candidate.nodes.inspect.context_pack_ref = 'different-pack' }
                    }
                }.GetNewClosure()
            }
        }

        foreach ($case in $cases) {
            $candidate = New-TestRun
            & $case.Mutate $candidate
            $script:projectionSaves = 0
            $script:projectionDispatches = 0
            $script:projectionReconciles = 0
            $script:projectionCleanups = 0

            {
                Invoke-TeamPipelineDeclarativeRunAdvancement -ProjectDir $TestDrive -Run $candidate -TaskInput $taskInput -Confirmation $confirmation `
                    -SaveRun { $script:projectionSaves++ } `
                    -Dispatch { $script:projectionDispatches++; throw 'projection validation must happen before dispatch' } `
                    -ResolveSession { throw 'projection validation must happen before session lookup' } `
                    -ResolveAcknowledgement { $script:projectionReconciles++; throw 'projection validation must happen before reconciliation' } `
                    -ReleaseLock { $script:projectionCleanups++ } `
                    -ValidateSnapshot { param($runToValidate) Assert-DeclarativeWorkflowExecutionProjection -Run $runToValidate -Plan $plan }
            } | Should -Throw '*projection*' -Because $case.Name

            $script:projectionSaves | Should -Be 0 -Because $case.Name
            $script:projectionDispatches | Should -Be 0 -Because $case.Name
            $script:projectionReconciles | Should -Be 0 -Because $case.Name
            $script:projectionCleanups | Should -Be 0 -Because $case.Name
        }
    }

    It 'C07 preserves terminal success failure and cancel outcomes while releasing the lock exactly once' {
        foreach ($terminalState in @('succeeded', 'failed', 'cancelled')) {
            $project = Join-Path $TestDrive "terminal-cleanup-$terminalState"
            $run = New-TestRun
            $run.state = $terminalState
            $run.nodes.inspect.state = if ($terminalState -eq 'failed') { 'failed' } else { 'succeeded' }
            $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
            $releases = [Collections.Generic.List[string]]::new()
            $after = Invoke-DeclarativeWorkflowTerminalCleanup -ProjectDir $project -Run $run -SaveRun { } -ReleaseLock {
                param($path)
                $releases.Add($path) | Out-Null
                Remove-Item -LiteralPath $path
            }

            $after.state | Should -Be $terminalState
            $after.cleanup_journal[0].state | Should -Be 'succeeded'
            $releases.Count | Should -Be 1
            Test-Path -LiteralPath $lock | Should -BeFalse
        }
    }

    It 'C07 resumes a terminal crash-cut cleanup once and blocks an ambiguous running cleanup without rewriting terminal outcome' {
        $project = Join-Path $TestDrive 'terminal-cleanup-crash-cut'
        $run = New-TestRun
        $run.state = 'failed'
        $run.nodes.inspect.state = 'failed'
        $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
        $resumeReleases = [Collections.Generic.List[string]]::new()
        $afterCrash = Invoke-DeclarativeWorkflowTerminalCleanup -ProjectDir $project -Run $run -SaveRun { } -ReleaseLock {
            param($path)
            $resumeReleases.Add($path) | Out-Null
            Remove-Item -LiteralPath $path
        }
        $afterCrash.state | Should -Be 'failed'
        $resumeReleases.Count | Should -Be 1

        $ambiguous = New-TestRun
        $ambiguous.state = 'failed'
        $ambiguous.nodes.inspect.state = 'failed'
        $ambiguous.cleanup_journal[0].state = 'running'
        $blocked = Invoke-DeclarativeWorkflowTerminalCleanup -ProjectDir $project -Run $ambiguous -SaveRun { } -ReleaseLock { throw 'must not repeat' }
        $blocked.state | Should -Be 'failed'
        $blocked.cleanup_journal[0].state | Should -Be 'blocked'
    }

    It 'V01 carries an ordered bounded verification envelope from durable dependency evidence into the existing verify prompt' {
        $script:testDeclarativeSessionName = 'verification-session'
        $run = New-TestRun
        $run.state = 'running'
        $run.nodes.inspect.state = 'succeeded'
        $run.nodes.inspect.attempt = 1
        $run.nodes.inspect.agent_cli_session_id = '%2'
        $run.nodes.inspect.evidence_refs = @('workflow-ack:run-123:inspect')
        $run.nodes.verify.state = 'ready'
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\\builder-worktree' }
                'worker-2' = [ordered]@{ pane_id = '%3'; role = 'Reviewer' }
            }
        }
        $acknowledgement = New-TestAcknowledgement -NodeId 'verify' -PaneId '%3'
        $acknowledgement['transport'] = 'mailbox'
        $script:verificationRequest = $null
        $script:verificationPrompt = ''
        Mock Invoke-TeamPipelineGuardedSend {
            param($StageName, $Target, $Prompt)
            $script:verificationPrompt = $Prompt
            [PSCustomObject]@{ Status = 'SENT'; Target = $Target }
        }
        Mock Wait-TeamPipelineDeclarativeCompletion { $acknowledgement }

        $after = Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'verify' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) } `
            -Dispatch {
                param($request, $candidateRun)
                $script:verificationRequest = Copy-DeclarativeWorkflowValue $request
                Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $candidateRun -Manifest $manifest -ProjectDir $TestDrive -SessionName 'verification-session'
            } `
            -ResolveSession { param($paneId) $paneId }

        $after.nodes.verify.state | Should -Be 'succeeded'
        $script:verificationRequest.context_pack_ref | Should -Be 'review-pack'
        @($script:verificationRequest.dependency_node_ids) | Should -Be @('inspect')
        @($script:verificationRequest.evidence_refs) | Should -Be @('workflow-ack:run-123:inspect')
        $script:verificationPrompt | Should -Match 'Builder label: worker-1'
        $script:verificationPrompt | Should -Match ([regex]::Escape('Builder worktree: C:\\builder-worktree'))
        $script:verificationPrompt | Should -Match 'Context package reference: review-pack'
        $script:verificationPrompt | Should -Match 'workflow-ack:run-123:inspect'
        $script:verificationPrompt | Should -Not -Match 'RAW_OUTPUT_MARKER'
    }

    It 'V01 blocks a verification dispatch before acknowledgement when the dependency producer binding or bounded context is missing' {
        $run = New-TestRun
        $run.nodes.inspect.state = 'succeeded'
        $run.nodes.inspect.evidence_refs = @('workflow-ack:run-123:inspect')
        $run.resolved_bindings.Remove('implement')
        $manifest = [PSCustomObject]@{ Panes = [ordered]@{ 'worker-2' = [ordered]@{ pane_id = '%3'; role = 'Reviewer' } } }
        $request = [PSCustomObject]@{
            stage = 'VERIFY'; node_id = 'verify'; pane_ref = 'verify'; task = 'safe task body'
            context_pack_ref = 'review-pack'; dependency_node_ids = @('inspect'); evidence_refs = @('workflow-ack:run-123:inspect')
        }
        Mock Invoke-TeamPipelineGuardedSend { throw 'verification must not be sent without a producer binding' }
        Mock Wait-TeamPipelineDeclarativeCompletion { throw 'verification must not await an acknowledgement without a producer binding' }

        $result = Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $run -Manifest $manifest -ProjectDir $TestDrive -SessionName 'verification-session'

        $result | Should -BeNullOrEmpty
        Should -Invoke Invoke-TeamPipelineGuardedSend -Times 0 -Exactly
        Should -Invoke Wait-TeamPipelineDeclarativeCompletion -Times 0 -Exactly
    }

    It 'V01 blocks an unbounded context value before it can become verification prompt content' {
        $run = New-TestRun
        $run.nodes.inspect.state = 'succeeded'
        $run.nodes.inspect.evidence_refs = @('workflow-ack:run-123:inspect')
        $run.nodes.verify.context_pack_ref = "context-pack:RAW_OUTPUT_MARKER`nnot-a-reference"
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\\builder-worktree' }
                'worker-2' = [ordered]@{ pane_id = '%3'; role = 'Reviewer' }
            }
        }
        $request = [PSCustomObject]@{
            stage = 'VERIFY'; node_id = 'verify'; pane_ref = 'verify'; task = 'safe task body'
            context_pack_ref = $run.nodes.verify.context_pack_ref; dependency_node_ids = @('inspect'); evidence_refs = @('workflow-ack:run-123:inspect')
        }
        Mock Invoke-TeamPipelineGuardedSend { throw 'raw producer output must not be forwarded as a context reference' }
        Mock Wait-TeamPipelineDeclarativeCompletion { throw 'raw producer output must not reach acknowledgement polling' }

        $result = Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $run -Manifest $manifest -ProjectDir $TestDrive -SessionName 'verification-session'

        $result | Should -BeNullOrEmpty
        Should -Invoke Invoke-TeamPipelineGuardedSend -Times 0 -Exactly
        Should -Invoke Wait-TeamPipelineDeclarativeCompletion -Times 0 -Exactly
    }

    It 'V01 rejects unbounded context content while constructing the durable run state' {
        $plan = New-TestWorkflowPlan
        $plan.nodes[1].context_pack_ref = "context-pack:RAW_OUTPUT_MARKER`nnot-a-reference"

        {
            New-DeclarativeWorkflowRun -Plan $plan -RunId 'run-123' -GenerationId 'generation-123' -SourceHead ('b' * 40) -TaskInput (New-TestTaskInput)
        } | Should -Throw '*bounded reference*'
    }

    It 'V01 blocks an ambiguous multi-producer verification context before acknowledgement' {
        $run = New-TestRun
        $run.nodes.inspect.state = 'succeeded'
        $run.nodes.inspect.evidence_refs = @('workflow-ack:run-123:inspect')
        $run.nodes['second'] = [ordered]@{
            state = 'succeeded'; attempt = 1; idempotency_key = 'run-123:second'; pane_ref = 'implement-two'
            action = 'operator-dispatch'; depends_on = @(); cleanup = 'retain'; evidence_refs = @('workflow-ack:run-123:second')
        }
        $run.nodes.verify.depends_on = @('inspect', 'second')
        $run.resolved_bindings['implement-two'] = 'worker-3'
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\\builder-one' }
                'worker-2' = [ordered]@{ pane_id = '%3'; role = 'Reviewer' }
                'worker-3' = [ordered]@{ pane_id = '%4'; role = 'Builder'; builder_worktree_path = 'C:\\builder-two' }
            }
        }
        $request = [PSCustomObject]@{
            stage = 'VERIFY'; node_id = 'verify'; pane_ref = 'verify'; task = 'safe task body'
            context_pack_ref = 'review-pack'; dependency_node_ids = @('inspect', 'second')
            evidence_refs = @('workflow-ack:run-123:inspect', 'workflow-ack:run-123:second')
        }
        Mock Invoke-TeamPipelineGuardedSend { throw 'verification must not be sent for an ambiguous producer context' }
        Mock Wait-TeamPipelineDeclarativeCompletion { throw 'verification must not await acknowledgement for an ambiguous producer context' }

        $result = Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $run -Manifest $manifest -ProjectDir $TestDrive -SessionName 'verification-session'

        $result | Should -BeNullOrEmpty
        Should -Invoke Invoke-TeamPipelineGuardedSend -Times 0 -Exactly
        Should -Invoke Wait-TeamPipelineDeclarativeCompletion -Times 0 -Exactly
    }

    It 'S01 rejects missing or malformed start manifests before creating a workflow-run state lock dispatch or cleanup effect' {
        $taskFile = Join-Path $TestDrive 'manifest-precondition-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        foreach ($case in @(
                [PSCustomObject]@{ Name = 'missing'; ReadManifest = { $null } },
                [PSCustomObject]@{ Name = 'malformed'; ReadManifest = { throw 'manifest parse rejected' } },
                [PSCustomObject]@{ Name = 'missing-session-identity'; ReadManifest = { [PSCustomObject]@{ Session = [ordered]@{}; Panes = [ordered]@{} } } }
            )) {
            $project = Join-Path $TestDrive ("manifest-precondition-" + $case.Name)
            $plan = [ordered]@{
                config_fingerprint = ('sha256:' + ('a' * 64))
                resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
                workflow = (New-TestWorkflowPlan)
            }
            Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
            Mock Read-TeamPipelineManifest $case.ReadManifest
            Mock Invoke-TeamPipelineWorkspacePlanOnce { Copy-DeclarativeWorkflowValue $plan }
            Mock Invoke-TeamPipelineDeclarativeRunAdvancement { throw 'start must not dispatch without a manifest identity' }

            {
                Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                    -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
                    -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $project
            } | Should -Throw

            Test-Path -LiteralPath (Join-Path $project '.winsmux\workflow-runs\run-123') | Should -BeFalse
            Should -Invoke Invoke-TeamPipelineWorkspacePlanOnce -Times 0 -Exactly
            Should -Invoke Invoke-TeamPipelineDeclarativeRunAdvancement -Times 0 -Exactly
        }
    }

    It 'M02 structurally rejects task-body fields without rejecting identifier-map keys and preserves existing state bytes' {
        $project = Join-Path $TestDrive 'structural-privacy-project'
        $run = New-TestRun
        $run.nodes.inspect.pane_ref = 'task'
        $run.resolved_bindings['task'] = 'worker-1'
        $run.nodes['task'] = Copy-DeclarativeWorkflowValue $run.nodes.inspect
        Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run | Out-Null
        $statePath = Join-Path $project '.winsmux\workflow-runs\run-123\state.json'
        $baseline = [IO.File]::ReadAllBytes($statePath)

        foreach ($field in @('Text', 'task', 'task_file', 'task_path')) {
            $topLevel = Copy-DeclarativeWorkflowValue $run
            $topLevel[$field] = 'PRIVATE_TASK_BODY'
            { Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $topLevel } | Should -Throw '*must not persist*'
            [Convert]::ToHexString([IO.File]::ReadAllBytes($statePath)) | Should -Be ([Convert]::ToHexString($baseline))

            $nodeRecord = Copy-DeclarativeWorkflowValue $run
            $nodeRecord.nodes.inspect[$field] = 'PRIVATE_TASK_BODY'
            { Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $nodeRecord } | Should -Throw '*must not persist*'
            [Convert]::ToHexString([IO.File]::ReadAllBytes($statePath)) | Should -Be ([Convert]::ToHexString($baseline))
        }

        $untypedNode = Copy-DeclarativeWorkflowValue $run
        $untypedNode.nodes['task'] = 'PRIVATE_TASK_BODY'
        { Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $untypedNode } | Should -Throw '*typed records*'
        [Convert]::ToHexString([IO.File]::ReadAllBytes($statePath)) | Should -Be ([Convert]::ToHexString($baseline))
    }

    It 'M01 atomically projects workflow state while preserving unknown manifest sections' {
        $project = Join-Path $TestDrive 'manifest-project'
        $winsmuxDir = Join-Path $project '.winsmux'
        [IO.Directory]::CreateDirectory($winsmuxDir) | Out-Null
        $manifestPath = Join-Path $winsmuxDir 'manifest.yaml'
        $manifest = @"
version: 2
saved_at: 2026-07-22T00:00:00Z
session:
  name: winsmux-orchestra
  generation_id: generation-123
  server_session_id: `$9
  bootstrap_pane_id: "%1"
panes: {}
tasks:
  queued: []
  in_progress: []
  completed: []
worktrees: {}
future_state:
  keep: true
"@
        [IO.File]::WriteAllText($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))
        $run = New-TestRun
        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run | Out-Null
        $after = [IO.File]::ReadAllText($manifestPath)
        $after | Should -Match '(?m)^workflow_runs:'
        $after | Should -Match '(?m)^future_state:'
        $after | Should -Match '(?m)^  keep: true\r?$'
        $after | Should -Not -Match 'Implement TASK-659 safely'

        $stateBefore = [IO.File]::ReadAllBytes((Join-Path $winsmuxDir 'workflow-runs\run-123\state.json'))
        $manifestBefore = [IO.File]::ReadAllBytes($manifestPath)
        $badRun = Copy-DeclarativeWorkflowValue $run
        $badRun.generation_id = 'generation-other'
        { Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $badRun } | Should -Throw '*generation*'
        [Convert]::ToHexString([IO.File]::ReadAllBytes($manifestPath)) | Should -Be ([Convert]::ToHexString($manifestBefore))
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $winsmuxDir 'workflow-runs\run-123\state.json'))) | Should -Be ([Convert]::ToHexString($stateBefore))

        $junctionProject = Join-Path $TestDrive 'state-junction-project'
        $junctionRunsRoot = Join-Path $junctionProject '.winsmux\workflow-runs'
        $externalRunRoot = Join-Path $TestDrive 'external-state-run'
        [IO.Directory]::CreateDirectory($junctionRunsRoot) | Out-Null
        [IO.Directory]::CreateDirectory($externalRunRoot) | Out-Null
        $externalState = Join-Path $externalRunRoot 'state.json'
        [IO.File]::WriteAllText($externalState, 'external-state-sentinel', [Text.UTF8Encoding]::new($false))
        $externalBefore = [IO.File]::ReadAllBytes($externalState)
        $junctionPath = Join-Path $junctionRunsRoot 'run-123'
        $taskFile = Join-Path $TestDrive 'junction-state-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'm01-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
        Mock Get-TeamPipelineSessionName { 'm01-session' }
        try {
            try {
                $stateJunction = New-Item -ItemType Junction -Path $junctionPath -Target $externalRunRoot -ErrorAction Stop
            } catch {
                throw "State junction fixture creation failed explicitly: $($_.Exception.Message)"
            }
            [bool]($stateJunction.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -BeTrue
            { Read-DeclarativeWorkflowRunState -ProjectDir $junctionProject -RunId 'run-123' } | Should -Throw '*reparse*'
            { Save-DeclarativeWorkflowRunState -ProjectDir $junctionProject -Run $run } | Should -Throw '*reparse*'
            {
                Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                    -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
                    -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $junctionProject
            } | Should -Throw '*reparse*'
            [Convert]::ToHexString([IO.File]::ReadAllBytes($externalState)) | Should -Be ([Convert]::ToHexString($externalBefore))
        } finally {
            if ([IO.Directory]::Exists($junctionPath)) { [IO.Directory]::Delete($junctionPath) }
        }
        [Convert]::ToHexString([IO.File]::ReadAllBytes($externalState)) | Should -Be ([Convert]::ToHexString($externalBefore))

        $transactionWorkflow = (New-TestWorkflowPlan | ConvertTo-Json -Depth 20) | ConvertFrom-Json -AsHashtable
        $transactionPlan = [ordered]@{
            config_fingerprint = ('sha256:' + ('a' * 64))
            resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
            workflow = $transactionWorkflow
        }
        Mock Invoke-TeamPipelineWorkspacePlanOnce { Copy-DeclarativeWorkflowValue $transactionPlan }
        $existingLockProject = Join-Path $TestDrive 'existing-lock-project'
        $existingRunRoot = Join-Path $existingLockProject '.winsmux\workflow-runs\run-123'
        [IO.Directory]::CreateDirectory($existingRunRoot) | Out-Null
        $existingLockPath = Join-Path $existingRunRoot 'run.lock'
        [IO.File]::WriteAllText($existingLockPath, 'existing-lock-sentinel', [Text.UTF8Encoding]::new($false))
        $existingLockBefore = [IO.File]::ReadAllBytes($existingLockPath)
        {
            Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
                -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $existingLockProject
        } | Should -Throw
        [Convert]::ToHexString([IO.File]::ReadAllBytes($existingLockPath)) | Should -Be ([Convert]::ToHexString($existingLockBefore))
        Test-Path -LiteralPath (Join-Path $existingRunRoot 'state.json') -PathType Leaf | Should -BeFalse

        $saveFailureProject = Join-Path $TestDrive 'save-failure-project'
        $saveFailureLock = Join-Path $saveFailureProject '.winsmux\workflow-runs\run-123\run.lock'
        $script:lockObservedBeforeStateSave = $false
        Mock Save-DeclarativeWorkflowRunState {
            $script:lockObservedBeforeStateSave = Test-Path -LiteralPath $saveFailureLock -PathType Leaf
            throw 'injected state save failure'
        }
        {
            Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
                -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $saveFailureProject
        } | Should -Throw '*injected state save failure*'
        $script:lockObservedBeforeStateSave | Should -BeFalse
        Test-Path -LiteralPath $saveFailureLock -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $saveFailureProject '.winsmux\workflow-runs\run-123\state.json') -PathType Leaf | Should -BeFalse
    }

    It 'C21 admits only a pristine state-only bootstrap, reuses a matching lock, and blocks a missing or mismatched lock after an effect' {
        $taskFile = Join-Path $TestDrive 'bootstrap-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        $workspacePlan = [ordered]@{
            config_fingerprint = ('sha256:' + ('a' * 64))
            resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
            workflow = (New-TestWorkflowPlan)
        }

        foreach ($case in @(
                [PSCustomObject]@{ Name = 'state-only-pristine'; Setup = { param($project, $run) } ; ExpectedAdvance = 1; ExpectedLock = $true },
                [PSCustomObject]@{ Name = 'matching-lock'; Setup = { param($project, $run) New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run | Out-Null } ; ExpectedAdvance = 1; ExpectedLock = $true },
                [PSCustomObject]@{
                    Name = 'missing-lock-after-effect'
                    Setup = { param($project, $run) $run.nodes.inspect.attempt = 1; $run.nodes.inspect.state = 'dispatching'; Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run | Out-Null }
                    ExpectedAdvance = 0; ExpectedLock = $false
                },
                [PSCustomObject]@{
                    Name = 'mismatched-lock-after-effect'
                    Setup = {
                        param($project, $run)
                        $run.nodes.inspect.attempt = 1
                        $run.nodes.inspect.state = 'dispatching'
                        Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run | Out-Null
                        $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
                        $payload = [IO.File]::ReadAllText($lock) | ConvertFrom-Json
                        $payload.source_head = ('c' * 40)
                        [IO.File]::WriteAllText($lock, ($payload | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
                    }
                    ExpectedAdvance = 0; ExpectedLock = $true
                }
            )) {
            $project = Join-Path $TestDrive ("bootstrap-" + $case.Name)
            $run = New-TestRun
            Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run -CreateNew | Out-Null
            & $case.Setup $project $run
            $statePath = Join-Path $project '.winsmux\workflow-runs\run-123\state.json'
            $stateBefore = [IO.File]::ReadAllBytes($statePath)
            $script:bootstrapAdvances = 0
            $script:bootstrapDispatches = 0
            Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
            Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'bootstrap-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
            Mock Get-TeamPipelineSessionName { 'bootstrap-session' }
            Mock Invoke-TeamPipelineWorkspacePlanOnce { Copy-DeclarativeWorkflowValue $workspacePlan }
            Mock Invoke-TeamPipelineDeclarativeRunAdvancement {
                param($ProjectDir, $Run)
                $script:bootstrapAdvances++
                return $Run
            }
            Mock Invoke-TeamPipelineDeclarativeDispatch { $script:bootstrapDispatches++; throw 'bootstrap rejection must not dispatch' }

            if ($case.ExpectedAdvance -eq 0) {
                {
                    Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId 'generation-123' `
                        -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $project
                } | Should -Throw -Because $case.Name
            } else {
                $result = Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId 'generation-123' `
                    -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $project
                $result.status | Should -Be 'accepted'
            }

            $script:bootstrapAdvances | Should -Be $case.ExpectedAdvance -Because $case.Name
            $script:bootstrapDispatches | Should -Be 0 -Because $case.Name
            $lockPath = Join-Path $project '.winsmux\workflow-runs\run-123\run.lock'
            (Test-Path -LiteralPath $lockPath -PathType Leaf) | Should -Be $case.ExpectedLock -Because $case.Name
            if ($case.ExpectedAdvance -eq 0) {
                [Convert]::ToHexString([IO.File]::ReadAllBytes($statePath)) | Should -Be ([Convert]::ToHexString($stateBefore)) -Because $case.Name
            }
        }
    }

    It 'C22 removes the create-new state when initial manifest projection fails before any lock exists' {
        $project = Join-Path $TestDrive 'bootstrap-projection-failure'
        $winsmuxDir = Join-Path $project '.winsmux'
        [IO.Directory]::CreateDirectory($winsmuxDir) | Out-Null
        [IO.File]::WriteAllText((Join-Path $winsmuxDir 'manifest.yaml'), @"
version: 2
session:
  name: bootstrap-projection
  generation_id: generation-123
panes: {}
worktrees: {}
"@, [Text.UTF8Encoding]::new($false))
        $run = New-TestRun
        Mock Save-WinsmuxManifest { throw 'injected initial manifest projection failure' }

        { Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run -CreateNew } | Should -Throw '*injected initial manifest projection failure*'

        Test-Path -LiteralPath (Join-Path $project '.winsmux\workflow-runs\run-123\state.json') -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $project '.winsmux\workflow-runs\run-123\run.lock') -PathType Leaf | Should -BeFalse
    }

    It 'F03 admits one invocation lease per run, permits different runs, and recovers after owner exit without deleting the marker' {
        $project = Join-Path $TestDrive 'invocation-lease'
        $run = New-TestRun
        $otherRun = Copy-DeclarativeWorkflowValue $run
        $otherRun.run_id = 'run-456'

        $owner = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123'
        $otherOwner = $null
        try {
            { Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123' } |
                Should -Throw '*workflow_run_invocation_busy*'
            $otherOwner = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-456'
        } finally {
            if ($null -ne $otherOwner) { $otherOwner.Dispose() }
            $owner.Dispose()
        }

        $marker = Join-Path $project '.winsmux\workflow-runs\run-123\invocation.lock'
        Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
        $recovered = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123'
        $recovered.Dispose()
        Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
    }

    It 'F03 releases the kernel invocation lease after an owning pwsh process is terminated' {
        $project = Join-Path $TestDrive 'invocation-crash-recovery'
        $readyPath = Join-Path $TestDrive 'invocation-owner-ready.txt'
        $workflowScript = Join-Path $script:RepoRoot 'winsmux-core\scripts\declarative-workflow.ps1'
        $escapedWorkflowScript = $workflowScript.Replace("'", "''")
        $escapedProject = $project.Replace("'", "''")
        $escapedReadyPath = $readyPath.Replace("'", "''")
        $childCommand = @"
. '$escapedWorkflowScript'
`$lease = Enter-DeclarativeWorkflowInvocationLease -ProjectDir '$escapedProject' -RunId 'run-123'
[IO.File]::WriteAllText('$escapedReadyPath', 'ready', [Text.UTF8Encoding]::new(`$false))
while (`$true) { Start-Sleep -Seconds 1 }
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
        $pwsh = (Get-Process -Id $PID).Path
        $owner = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WindowStyle Hidden -PassThru
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
                if ($owner.HasExited) { throw "invocation lease child exited early with code $($owner.ExitCode)" }
                Start-Sleep -Milliseconds 50
            }
            Test-Path -LiteralPath $readyPath -PathType Leaf | Should -BeTrue
            { Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123' } |
                Should -Throw '*workflow_run_invocation_busy*'
        } finally {
            if (-not $owner.HasExited) { Stop-Process -Id $owner.Id -Force -ErrorAction SilentlyContinue }
            $owner.WaitForExit(10000) | Out-Null
            $owner.Dispose()
        }

        $marker = Join-Path $project '.winsmux\workflow-runs\run-123\invocation.lock'
        Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
        $recovered = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123'
        $recovered.Dispose()
        Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
    }

    It 'F03 holds the invocation lease across start planning and releases it after the invocation returns' {
        $project = Join-Path $TestDrive 'invocation-lifetime'
        $taskFile = Join-Path $TestDrive 'invocation-lifetime-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        $workspacePlan = [ordered]@{
            config_fingerprint = ('sha256:' + ('a' * 64))
            resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
            workflow = (New-TestWorkflowPlan)
        }
        $script:invocationBusyObserved = $false
        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'lease-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
        Mock Get-TeamPipelineSessionName { 'lease-session' }
        Mock Invoke-TeamPipelineWorkspacePlanOnce {
            try {
                $contender = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123'
                $contender.Dispose()
            } catch {
                $script:invocationBusyObserved = $_.Exception.Message -like '*workflow_run_invocation_busy*'
            }
            Copy-DeclarativeWorkflowValue $workspacePlan
        }
        Mock Invoke-TeamPipelineDeclarativeRunAdvancement { param($ProjectDir, $Run) $Run }

        $result = Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
            -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
            -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $project

        $result.status | Should -Be 'accepted'
        $script:invocationBusyObserved | Should -BeTrue
        $after = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123'
        $after.Dispose()
    }
}
