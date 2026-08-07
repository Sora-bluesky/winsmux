$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Task839RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Task839CorePath = Join-Path $script:Task839RepoRoot 'scripts\winsmux-core.ps1'
    . $script:Task839CorePath 'version' *> $null

    function New-Task839WorktreeFixture {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("winsmux task839 'root' " + [guid]::NewGuid().ToString('N'))
        $mainRoot = Join-Path $root 'main'
        $targetRoot = Join-Path $root 'target worktree'
        $siblingRoot = Join-Path $root 'reviewer sibling'
        $unrelatedRoot = Join-Path $root 'unrelated cwd'
        New-Item -ItemType Directory -Path $mainRoot, $unrelatedRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $mainRoot 'README.md'), 'task839 fixture', [Text.UTF8Encoding]::new($false))

        & git -C $mainRoot init | Out-Null
        & git -C $mainRoot config user.name 'Task839 Test'
        & git -C $mainRoot config user.email 'task839@example.invalid'
        & git -C $mainRoot add README.md
        & git -C $mainRoot commit -m 'task839 fixture' | Out-Null
        & git -C $mainRoot branch -M main
        & git -C $mainRoot worktree add -b feature/task839-target $targetRoot | Out-Null
        & git -C $mainRoot worktree add -b feature/task839-sibling $siblingRoot | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'unable to create TASK839 worktree fixture' }

        $headSha = (& git -C $targetRoot rev-parse HEAD | Select-Object -First 1).Trim()
        $submissionId = 'submission-task839-sibling-cwd'
        $packet = New-WinsmuxSubmissionPacket -ProjectDir $mainRoot -Kind review -SubmissionId $submissionId `
            -TargetLabel 'reviewer-1' -Content ([ordered]@{
                title       = 'Review TASK839 target'
                request     = 'Review the target worktree binding.'
                files       = @('scripts/winsmux-core.ps1')
                tests       = @('tests/Task839WorktreeReviewState.Tests.ps1')
                constraints = @('Do not infer roots from reviewer CWD.')
                branch      = 'feature/task839-target'
                head_sha    = $headSha
            })

        $poisonPath = Join-Path $siblingRoot ".winsmux\submissions\$submissionId.json"
        New-Item -ItemType Directory -Path (Split-Path -Parent $poisonPath) -Force | Out-Null
        [IO.File]::WriteAllText($poisonPath, '{"kind":"review","poisoned":true}', [Text.UTF8Encoding]::new($false))

        return [pscustomobject]@{
            Root          = $root
            MainRoot      = [IO.Path]::GetFullPath($mainRoot).TrimEnd('\')
            TargetRoot    = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
            SiblingRoot   = [IO.Path]::GetFullPath($siblingRoot).TrimEnd('\')
            UnrelatedRoot = [IO.Path]::GetFullPath($unrelatedRoot).TrimEnd('\')
            HeadSha       = $headSha
            SubmissionId  = $submissionId
            PacketPath    = [string]$packet.FullPath
            PoisonPath    = $poisonPath
        }
    }

    function Remove-Task839WorktreeFixture {
        param([AllowNull()]$Fixture)

        if ($null -eq $Fixture) { return }
        if (Test-Path -LiteralPath $Fixture.MainRoot -PathType Container) {
            & git -C $Fixture.MainRoot worktree remove --force $Fixture.TargetRoot 2>$null
            & git -C $Fixture.MainRoot worktree remove --force $Fixture.SiblingRoot 2>$null
            & git -C $Fixture.MainRoot worktree prune 2>$null
        }
        Remove-Item -LiteralPath $Fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'TASK839 dual-root review binding' {
    BeforeEach {
        $script:Task839Fixture = New-Task839WorktreeFixture
        $script:Task839Context = [pscustomobject][ordered]@{
            ManifestPath    = Join-Path $script:Task839Fixture.MainRoot '.winsmux\manifest.yaml'
            GenerationId   = 'generation-task839'
            ServerSessionId = '$task839'
            SlotId         = 'reviewer-1'
            PaneId         = '%9'
            Label          = 'reviewer-1'
            Role           = 'Reviewer'
            Backend        = 'codex'
            AgentName      = 'codex'
        }
    }

    AfterEach {
        Remove-Task839WorktreeFixture -Fixture $script:Task839Fixture
    }

    It 'resolves main, target, sibling, and unrelated reviewer CWDs from the carried locator only' {
        Mock Get-CurrentReviewPaneManifestContext { $script:Task839Context }
        $poisonBefore = [IO.File]::ReadAllBytes($script:Task839Fixture.PoisonPath)

        foreach ($cwd in @(
            $script:Task839Fixture.MainRoot,
            $script:Task839Fixture.TargetRoot,
            $script:Task839Fixture.SiblingRoot,
            $script:Task839Fixture.UnrelatedRoot
        )) {
            Push-Location -LiteralPath $cwd
            try {
                $binding = Resolve-ReviewSubmissionBinding -StateRoot $script:Task839Fixture.MainRoot `
                    -SubmissionId $script:Task839Fixture.SubmissionId
            } finally {
                Pop-Location
            }
            $binding.WorkRoot | Should -BeExactly $script:Task839Fixture.TargetRoot
            $binding.StateRoot | Should -BeExactly $script:Task839Fixture.MainRoot
            $binding.Branch | Should -BeExactly 'feature/task839-target'
            $binding.HeadSha | Should -BeExactly $script:Task839Fixture.HeadSha
            $binding.PacketPath | Should -BeExactly $script:Task839Fixture.PacketPath
        }

        [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:Task839Fixture.PoisonPath)) |
            Should -BeExactly ([Convert]::ToBase64String($poisonBefore))
    }

    It 'rejects a packet whose target worktree advanced after dispatch without writing state' {
        Mock Get-CurrentReviewPaneManifestContext { $script:Task839Context }
        Mock Stop-WithError { param($Message) throw $Message }
        [IO.File]::WriteAllText((Join-Path $script:Task839Fixture.TargetRoot 'advanced.txt'), 'advanced', [Text.UTF8Encoding]::new($false))
        & git -C $script:Task839Fixture.TargetRoot add advanced.txt
        & git -C $script:Task839Fixture.TargetRoot -c user.name='Task839 Test' -c user.email='task839@example.invalid' commit -m 'advance target' | Out-Null

        {
            Resolve-ReviewSubmissionBinding -StateRoot $script:Task839Fixture.MainRoot `
                -SubmissionId $script:Task839Fixture.SubmissionId
        } | Should -Throw '*exactly one attached worktree; found 0*'
        Test-Path -LiteralPath (Join-Path $script:Task839Fixture.MainRoot '.winsmux\review-state.json') |
            Should -BeFalse
    }

    It 'stores a direct linked-worktree request only at the common StateRoot' {
        Mock Assert-WinsmuxRolePermission { }
        Mock Get-CurrentReviewPaneManifestContext { $script:Task839Context }
        Mock Get-PaneControlVerifiedReviewIdentity { $script:Task839Context }
        Mock Update-ReviewPaneManifestState { }

        Push-Location -LiteralPath $script:Task839Fixture.TargetRoot
        try {
            $requestOutput = & { $Target = $null; $Rest = @(); Invoke-ReviewRequest }
            $requestOutput | Should -BeExactly 'review request recorded for feature/task839-target'
            $state = Get-ReviewState -StateRoot $script:Task839Fixture.MainRoot
            $state['feature/task839-target']['request']['target_work_root'] |
                Should -BeExactly $script:Task839Fixture.TargetRoot
            $state['feature/task839-target']['request'].Contains('source_submission_id') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:Task839Fixture.TargetRoot '.winsmux\review-state.json') |
                Should -BeFalse

            $resetOutput = & { $Target = $null; $Rest = @(); Invoke-ReviewReset }
            $resetOutput | Should -BeExactly 'review PASS cleared for feature/task839-target'
        } finally {
            Pop-Location
        }
    }

    It 'never calls Get-Location during the bound request, approve, and reset lifecycle' {
        Mock Assert-WinsmuxRolePermission { }
        Mock Get-CurrentReviewPaneManifestContext { $script:Task839Context }
        Mock Get-PaneControlVerifiedReviewIdentity { $script:Task839Context }
        Mock Update-ReviewPaneManifestState { }
        Mock Get-Location { throw 'bound review consumer consulted process CWD' }

        foreach ($cwd in @(
            $script:Task839Fixture.MainRoot,
            $script:Task839Fixture.TargetRoot,
            $script:Task839Fixture.SiblingRoot,
            $script:Task839Fixture.UnrelatedRoot
        )) {
            Push-Location -LiteralPath $cwd
            try {
                $requestOutput = & {
                    $Target = '--state-root'
                    $Rest = @($script:Task839Fixture.MainRoot, '--submission-id', $script:Task839Fixture.SubmissionId)
                    Invoke-ReviewRequest
                }
                $requestOutput | Should -BeExactly 'review request recorded for feature/task839-target'
                $state = Get-ReviewState -StateRoot $script:Task839Fixture.MainRoot
                $state['feature/task839-target']['request']['target_work_root'] |
                    Should -BeExactly $script:Task839Fixture.TargetRoot
                $state['feature/task839-target']['request']['source_submission_id'] |
                    Should -BeExactly $script:Task839Fixture.SubmissionId

                $approveOutput = & {
                    $Target = '--state-root'
                    $Rest = @($script:Task839Fixture.MainRoot, '--submission-id', $script:Task839Fixture.SubmissionId)
                    Invoke-ReviewApprove
                }
                $approveOutput | Should -BeExactly 'review PASS recorded for feature/task839-target'

                $resetOutput = & {
                    $Target = '--state-root'
                    $Rest = @($script:Task839Fixture.MainRoot, '--submission-id', $script:Task839Fixture.SubmissionId)
                    Invoke-ReviewReset
                }
                $resetOutput | Should -BeExactly 'review PASS cleared for feature/task839-target'
            } finally {
                Pop-Location
            }
            (Get-ReviewState -StateRoot $script:Task839Fixture.MainRoot).Contains('feature/task839-target') |
                Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:Task839Fixture.TargetRoot '.winsmux\review-state.json') |
                Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:Task839Fixture.SiblingRoot '.winsmux\review-state.json') |
                Should -BeFalse
        }
    }

    It 'renders an argument-safe absolute review instruction and keeps task delivery relative' {
        Mock Test-PaneControlRuntimeContext {
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'dispatch_verified' -Diagnostic 'verified' `
                -Context ([ordered]@{ generation_id = 'generation-task839' })
        }
        Mock New-WinsmuxSubmissionAcknowledgementServer {
            [pscustomobject]@{ pipe_name = 'winsmux-task839-ack'; challenge = ('a' * 64); server = $null }
        }
        Mock Receive-WinsmuxSubmissionAcknowledgement { throw 'synthetic acknowledgement absent' }
        Mock Complete-WinsmuxSubmissionAcknowledgement { $true }

        $script:Task839ReviewInstruction = ''
        $entry = [pscustomobject]@{ Label = 'reviewer-1'; PaneId = '%9'; Role = 'Reviewer'; WorkerBackend = 'codex' }
        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:Task839Fixture.MainRoot -ManifestEntry $entry `
            -Kind review -Content 'review bounded input' -SubmissionId 'submission-task839-delivery' `
            -ReviewStateRoot $script:Task839Fixture.MainRoot `
            -SendAction { param($paneId, $commandText) $script:Task839ReviewInstruction = $commandText }

        $receipt.status | Should -Be 'rejected'
        $quotedRoot = "'" + $script:Task839Fixture.MainRoot.Replace("'", "''") + "'"
        $absolutePacket = [IO.Path]::GetFullPath((Join-Path $script:Task839Fixture.MainRoot '.winsmux\submissions\submission-task839-delivery.json'))
        $quotedPacket = "'" + $absolutePacket.Replace("'", "''") + "'"
        $script:Task839ReviewInstruction | Should -Match ([regex]::Escape("at $quotedPacket"))
        $script:Task839ReviewInstruction | Should -Match ([regex]::Escape("winsmux review-request --state-root $quotedRoot --submission-id submission-task839-delivery"))
        $script:Task839ReviewInstruction | Should -Not -Match "at '\.winsmux[\\/]submissions"

        $script:Task839TaskInstruction = ''
        Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:Task839Fixture.MainRoot -ManifestEntry $entry `
            -Kind task -Content 'implement bounded input' -SubmissionId 'submission-task839-task' `
            -SendAction { param($paneId, $commandText) $script:Task839TaskInstruction = $commandText } | Out-Null
        $script:Task839TaskInstruction | Should -Match "at '\.winsmux[\\/]submissions[\\/]submission-task839-task\.json'"
        $script:Task839TaskInstruction | Should -Not -Match ([regex]::Escape($script:Task839Fixture.MainRoot))

        $script:Task839ApiInstruction = ''
        $apiEntry = [pscustomobject]@{ Label = 'api-reviewer'; PaneId = '%10'; Role = 'Reviewer'; WorkerBackend = 'api_llm' }
        $apiReceipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:Task839Fixture.MainRoot -ManifestEntry $apiEntry `
            -Kind task -Content 'api llm bounded input' -SubmissionId 'submission-task839-api' `
            -SendAction { param($paneId, $commandText) $script:Task839ApiInstruction = $commandText } `
            -RunResultAction { [ordered]@{ status = 'unavailable'; reason = 'api_llm_api_key_env_missing' } }
        $apiReceipt.status | Should -Be 'unavailable'
        $apiReceipt.reason_code | Should -BeExactly 'api_llm_api_key_env_missing'
        $script:Task839ApiInstruction | Should -BeExactly "exec .winsmux\submissions\submission-task839-api.json"
    }
}
