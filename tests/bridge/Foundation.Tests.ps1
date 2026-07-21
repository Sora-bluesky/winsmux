$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'Assert-Role' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\role-gate.ps1')
    }

    BeforeEach {
        $script:originalRole = $env:WINSMUX_ROLE
        $script:originalPaneId = $env:WINSMUX_PANE_ID
        $script:originalRoleMap = $env:WINSMUX_ROLE_MAP
        $script:originalRoleGateLabelsFile = $script:RoleGateLabelsFile
        Mock Deny-RoleCommand { return $false }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-role-gate-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $labelsPath = Join-Path $tempRoot 'labels.json'
        @{
            self       = 'pane-self'
            operator  = 'pane-operator'
            builder    = 'pane-builder'
            worker     = 'pane-worker'
            researcher = 'pane-researcher'
            reviewer   = 'pane-reviewer'
        } | ConvertTo-Json | Set-Content -Path $labelsPath -Encoding UTF8

        $script:roleGateTempRoot = $tempRoot
        $script:RoleGateLabelsFile = $labelsPath
        $env:WINSMUX_PANE_ID = 'pane-self'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Operator","pane-operator":"Operator","pane-builder":"Builder","pane-worker":"Worker","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'
    }

    AfterEach {
        $env:WINSMUX_ROLE = $script:originalRole
        $env:WINSMUX_PANE_ID = $script:originalPaneId
        $env:WINSMUX_ROLE_MAP = $script:originalRoleMap
        $script:RoleGateLabelsFile = $script:originalRoleGateLabelsFile

        if ($script:roleGateTempRoot -and (Test-Path $script:roleGateTempRoot)) {
            Remove-Item -Path $script:roleGateTempRoot -Recurse -Force
        }
    }

    It 'allows Operator to send anywhere and denies typing into another pane' {
        $env:WINSMUX_ROLE = 'Operator'

        (Assert-Role -Command 'send' -TargetPane 'reviewer') | Should -Be $true
        (Assert-Role -Command 'status') | Should -Be $true
        (Assert-Role -Command 'board') | Should -Be $true
        (Assert-Role -Command 'inbox') | Should -Be $true
        (Assert-Role -Command 'runs') | Should -Be $true
        (Assert-Role -Command 'digest') | Should -Be $true
        (Assert-Role -Command 'explain') | Should -Be $true
        (Assert-Role -Command 'context-reset' -TargetPane 'reviewer') | Should -Be $true
        (Assert-Role -Command 'poll-events') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $true
        (Assert-Role -Command 'consult-request') | Should -Be $true
        (Assert-Role -Command 'type' -TargetPane 'reviewer') | Should -Be $false
    }

    It 'allows Builder to message Operator and denies sending to peers' {
        $env:WINSMUX_ROLE = 'Builder'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Builder","pane-operator":"Operator","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'send' -TargetPane 'operator') | Should -Be $true
        (Assert-Role -Command 'status') | Should -Be $true
        (Assert-Role -Command 'board') | Should -Be $true
        (Assert-Role -Command 'inbox') | Should -Be $true
        (Assert-Role -Command 'runs') | Should -Be $true
        (Assert-Role -Command 'digest') | Should -Be $true
        (Assert-Role -Command 'explain') | Should -Be $true
        (Assert-Role -Command 'consult-result') | Should -Be $true
        (Assert-Role -Command 'type' -TargetPane 'self') | Should -Be $true
        (Assert-Role -Command 'context-reset' -TargetPane 'operator') | Should -Be $false
        (Assert-Role -Command 'send' -TargetPane 'reviewer') | Should -Be $false
        (Assert-Role -Command 'read' -TargetPane 'reviewer') | Should -Be $false
    }

    It 'allows Researcher to message Operator and denies orchestration commands' {
        $env:WINSMUX_ROLE = 'Researcher'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Researcher","pane-operator":"Operator","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'operator') | Should -Be $true
        (Assert-Role -Command 'read' -TargetPane 'self') | Should -Be $true
        (Assert-Role -Command 'digest') | Should -Be $true
        (Assert-Role -Command 'consult-error') | Should -Be $true
        (Assert-Role -Command 'poll-events') | Should -Be $false
        (Assert-Role -Command 'signal') | Should -Be $false
        (Assert-Role -Command 'wait') | Should -Be $false
    }

    It 'allows Reviewer to message Operator and denies privileged commands' {
        $env:WINSMUX_ROLE = 'Reviewer'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Reviewer","pane-operator":"Operator","pane-builder":"Builder","pane-worker":"Worker","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'operator') | Should -Be $true
        (Assert-Role -Command 'review-request') | Should -Be $true
        (Assert-Role -Command 'review-approve') | Should -Be $true
        (Assert-Role -Command 'consult-result') | Should -Be $true
        (Assert-Role -Command 'status') | Should -Be $true
        (Assert-Role -Command 'digest') | Should -Be $true
        (Assert-Role -Command 'list') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $false
        (Assert-Role -Command 'focus') | Should -Be $false
    }

    It 'allows Worker to act as a review-capable pane while staying non-privileged' {
        $env:WINSMUX_ROLE = 'Worker'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Worker","pane-operator":"Operator","pane-builder":"Builder","pane-worker":"Worker","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'operator') | Should -Be $true
        (Assert-Role -Command 'review-request') | Should -Be $true
        (Assert-Role -Command 'review-approve') | Should -Be $true
        (Assert-Role -Command 'review-fail') | Should -Be $true
        (Assert-Role -Command 'consult-request') | Should -Be $true
        (Assert-Role -Command 'digest') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $false
        (Assert-Role -Command 'focus') | Should -Be $false
    }

    It 'denies review approval commands outside Reviewer role' {
        $env:WINSMUX_ROLE = 'Builder'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Builder","pane-operator":"Operator","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'review-request') | Should -Be $false
        (Assert-Role -Command 'review-approve') | Should -Be $false
    }
}

Describe 'reviewer.sh prompt contract' {
    It 'includes mandatory design-impact checklist items' {
        $scriptPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\agents\reviewer.sh'
        $content = Get-Content -Path $scriptPath -Raw -Encoding UTF8

        $content | Should -Match 'downstream behavior, workflow, or monitoring capability'
        $content | Should -Match 'removed or changed capability replaced elsewhere'
        $content | Should -Match 'orphaned artifacts such as dead mocks'
        $content | Should -Match 'files defining called functions'
        $content | Should -Match 'missing definition-host file'
        $content | Should -Match 'DIFF_PATHSPEC'
        $content | Should -Match 'design impact'
        $content | Should -Match 'replacement check'
        $content | Should -Match 'orphaned artifacts'
    }
}

Describe 'Get-OrchestraLayoutSettings' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-start.ps1')
    }

    It 'uses external operator mode by default' {
        $layout = Get-OrchestraLayoutSettings -Settings ([ordered]@{
            external_operator = $true
            worker_count       = 6
            legacy_role_layout = $false
            operators         = 0
            builders           = 0
            researchers        = 0
            reviewers          = 0
        })

        $layout.ExternalOperator | Should -Be $true
        $layout.LegacyRoleLayout | Should -Be $false
        $layout.Operators | Should -Be 0
        $layout.Workers | Should -Be 6
        $layout.Builders | Should -Be 0
        $layout.Researchers | Should -Be 0
        $layout.Reviewers | Should -Be 0
    }

    It 'prefers explicit agent slots over worker_count when deriving managed slot count' {
        $layout = Get-OrchestraLayoutSettings -Settings ([ordered]@{
            external_operator = $true
            worker_count       = 2
            agent_slots        = @(
                [ordered]@{ slot_id = 'worker-1'; runtime_role = 'worker'; agent = 'codex'; model = 'gpt-5.4'; worktree_mode = 'managed' },
                [ordered]@{ slot_id = 'worker-2'; runtime_role = 'worker'; agent = 'codex'; model = 'gpt-5.4'; worktree_mode = 'managed' },
                [ordered]@{ slot_id = 'worker-3'; runtime_role = 'worker'; agent = 'codex'; model = 'gpt-5.4'; worktree_mode = 'managed' }
            )
            agent             = 'codex'
            model             = 'gpt-5.4'
            legacy_role_layout = $false
            operators         = 0
            builders           = 0
            researchers        = 0
            reviewers          = 0
        })

        $layout.ExternalOperator | Should -Be $true
        $layout.LegacyRoleLayout | Should -Be $false
        $layout.Operators | Should -Be 0
        $layout.Workers | Should -Be 3
    }

    It 'allows agent slots without agent or model fields under strict mode' {
        $layout = Get-OrchestraLayoutSettings -Settings ([ordered]@{
            external_operator = $true
            worker_count       = 1
            agent_slots        = @(
                [pscustomobject]@{
                    slot_id       = 'worker-1'
                    runtime_role  = 'worker'
                    worktree_mode = 'managed'
                },
                [ordered]@{
                    slot_id       = 'worker-2'
                    runtime_role  = 'worker'
                    worktree_mode = 'managed'
                }
            )
            legacy_role_layout = $false
            operators         = 0
            builders           = 0
            researchers        = 0
            reviewers          = 0
        })

        $layout.ExternalOperator | Should -Be $true
        $layout.LegacyRoleLayout | Should -Be $false
        $layout.Operators | Should -Be 0
        $layout.Workers | Should -Be 2
    }

    It 'rejects unsupported non-worker runtime_role overrides until slot runtime wiring expands' {
        {
            Get-OrchestraLayoutSettings -Settings ([ordered]@{
                external_operator = $true
                worker_count       = 2
                agent_slots        = @(
                    [ordered]@{ slot_id = 'worker-1'; runtime_role = 'worker'; agent = 'codex'; model = 'gpt-5.4'; worktree_mode = 'managed' },
                    [ordered]@{ slot_id = 'review-1'; runtime_role = 'reviewer'; agent = 'claude'; model = 'sonnet'; worktree_mode = 'managed' }
                )
                agent              = 'codex'
                model              = 'gpt-5.4'
                legacy_role_layout = $false
                operators         = 0
                builders           = 0
                researchers        = 0
                reviewers          = 0
            })
        } | Should -Throw '*runtime_role overrides are not supported yet at runtime*'
    }

    It 'writes project settings to an explicit root path and omits worker_count when agent slots are present' {
        $saveSettingsTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-save-settings-tests-' + [guid]::NewGuid().ToString('N'))
        $projectRoot = Join-Path $saveSettingsTempRoot 'repo-root'

        try {
            New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

            Save-BridgeSettings -Scope project -RootPath $projectRoot -Settings ([ordered]@{
                agent              = 'codex'
                model              = 'gpt-5.4'
                external_operator = $true
                worker_backend     = 'local'
                execution_profile  = 'isolated-enterprise'
                worker_count       = 2
                agent_slots        = @(
                    [ordered]@{ slot_id = 'worker-1'; runtime_role = 'worker'; agent = 'codex'; model = 'gpt-5.4'; worker_backend = 'codex'; execution_profile = 'local-windows'; worker_role = 'reviewer'; fallback_model = 'gpt-5.4'; worktree_mode = 'managed' },
                    [ordered]@{ slot_id = 'worker-2'; runtime_role = 'worker'; agent = 'codex'; model = 'gpt-5.4'; worker_backend = 'antigravity'; execution_profile = 'isolated-enterprise'; worker_role = 'impl'; worktree_mode = 'managed' }
                )
                vault_keys         = @('GH_TOKEN')
            })

            $projectConfigPath = Join-Path $projectRoot '.winsmux.yaml'
            Test-Path $projectConfigPath | Should -Be $true
            $projectConfig = Get-Content -Raw -Path $projectConfigPath -Encoding UTF8
            $projectConfig | Should -Match 'agent_slots:'
            $projectConfig | Should -Not -Match 'worker_count:'
            $projectConfig | Should -Match 'execution_profile: isolated-enterprise'
            $projectConfig | Should -Match 'worker_backend: antigravity'

            Mock Get-WinsmuxOption { param($Name, $Default) return $null }

            $roundTrip = Get-BridgeSettings -RootPath $projectRoot
            $roundTrip.worker_backend | Should -Be 'local'
            $roundTrip.execution_profile | Should -Be 'isolated-enterprise'
            $roundTrip.worker_count | Should -Be 2
            $roundTrip.agent_slots[0].worker_backend | Should -Be 'codex'
            $roundTrip.agent_slots[0].execution_profile | Should -Be 'local-windows'
            $roundTrip.agent_slots[0].worker_role | Should -Be 'reviewer'
            $roundTrip.agent_slots[1].worker_backend | Should -Be 'antigravity'
            $roundTrip.agent_slots[1].execution_profile | Should -Be 'isolated-enterprise'
            $roundTrip.agent_slots[1].worker_role | Should -Be 'impl'
        } finally {
            Remove-Item -LiteralPath $saveSettingsTempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'TASK658 preserves Lane B and unknown top-level blocks when saving legacy settings' {
        $projectRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-settings-preserve-' + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
            $path = Join-Path $projectRoot '.winsmux.yaml'
            $workspaceRecipeBlock = @'
workspace-recipes: # Rust owns semantic parsing
 review:
   schema-version: 1
   panes: # collection comment
   -
     pane-key: implement
     workflow-role: implementer
     slot-ref: worker-1
     requires-capabilities: [file-edit]
     region: main
     worktree: { mode: managed, name-template: "{{workflow-id}}-implement" }
   startup-actions: []
'@
            @"
agent: codex
team-profile:
  schema-version: 1
  preset: official-balanced-v1
$workspaceRecipeBlock
future-owner:
  enabled: true
"@ | Set-Content -LiteralPath $path -Encoding UTF8

            Save-BridgeSettings -Scope project -RootPath $projectRoot -Settings ([ordered]@{ agent = 'codex'; model = 'gpt-5.4' })

            $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            $saved | Should -Match '(?m)^team-profile:'
            $saved | Should -Match '(?m)^workspace-recipes:'
            $saved | Should -Match '(?m)^future-owner:'
            $saved | Should -Match 'preset: official-balanced-v1'
            $saved | Should -Match 'schema-version: 1'
            ($saved -replace "`r`n", "`n") | Should -Match ([regex]::Escape(($workspaceRecipeBlock -replace "`r`n", "`n")))
        } finally {
            Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'preserves legacy role layouts only when explicit opt-in is enabled' {
        $layout = Get-OrchestraLayoutSettings -Settings ([ordered]@{
            external_operator = $false
            worker_count       = 0
            legacy_role_layout = $true
            operators         = 1
            builders           = 4
            researchers        = 1
            reviewers          = 1
        })

        $layout.ExternalOperator | Should -Be $false
        $layout.LegacyRoleLayout | Should -Be $true
        $layout.Operators | Should -Be 1
        $layout.Workers | Should -Be 0
        $layout.Builders | Should -Be 4
        $layout.Researchers | Should -Be 1
        $layout.Reviewers | Should -Be 1
    }

    It 'rejects implicit legacy role counts when legacy_role_layout is false' {
        {
            Get-OrchestraLayoutSettings -Settings ([ordered]@{
                external_operator = $true
                worker_count       = 6
                legacy_role_layout = $false
                operators         = 0
                builders           = 4
                researchers        = 1
                reviewers          = 1
            })
        } | Should -Throw '*legacy_role_layout=true*'
    }
}

Describe 'Vault helpers' {
    BeforeAll {
        function Stop-WithError {
            param([string]$Message)
            throw $Message
        }

        function Resolve-Target {
            param([string]$RawTarget)
            return $RawTarget
        }

        function Confirm-Target {
            param([string]$PaneId)
            return $PaneId
        }

        function Assert-ReadMark {
            param([string]$PaneId)
        }

        function Clear-ReadMark {
            param([string]$PaneId)
        }

        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\vault.ps1')

        if (-not ('WinsmuxVaultTestCleanupNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WinsmuxVaultTestCleanupNative {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredEnumerate(string filter, uint flags, out int count, out IntPtr credentials);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool CredFree(IntPtr credential);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public const uint CRED_TYPE_GENERIC = 1;
}
'@ -ErrorAction Stop
        }
    }

    BeforeEach {
        $script:originalTarget = $script:Target
        $script:originalRest = $script:Rest
        $script:originalPrefix = $script:WinCredTargetPrefix

        $script:Target = $null
        $script:Rest = @()
        $script:WinCredTargetPrefix = 'winsmux-test:{0}:' -f [guid]::NewGuid().ToString('N')
    }

    AfterEach {
        $testPrefix = $script:WinCredTargetPrefix
        $filter = '{0}*' -f $testPrefix
        $count = 0
        $credsPtr = [IntPtr]::Zero

        $ok = [WinsmuxVaultTestCleanupNative]::CredEnumerate($filter, 0, [ref]$count, [ref]$credsPtr)
        if ($ok) {
            try {
                $ptrSize = [Runtime.InteropServices.Marshal]::SizeOf([Type][IntPtr])
                for ($i = 0; $i -lt $count; $i++) {
                    $entryPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($credsPtr, $i * $ptrSize)
                    $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($entryPtr, [Type][WinsmuxVaultTestCleanupNative+CREDENTIAL])
                    [WinsmuxVaultTestCleanupNative]::CredDelete($cred.TargetName, [WinsmuxVaultTestCleanupNative]::CRED_TYPE_GENERIC, 0) | Out-Null
                }
            } finally {
                [WinsmuxVaultTestCleanupNative]::CredFree($credsPtr) | Out-Null
            }
        }

        $script:Target = $script:originalTarget
        $script:Rest = $script:originalRest
        $script:WinCredTargetPrefix = $script:originalPrefix
    }

    It 'stores, retrieves, and lists credentials inside the test prefix only' {
        $script:Target = 'alpha'
        $script:Rest = @('one')
        Invoke-VaultSet | Out-Null

        $script:Target = 'beta'
        $script:Rest = @('two')
        Invoke-VaultSet | Out-Null

        $script:Target = 'alpha'
        $script:Rest = @()
        (Invoke-VaultGet) | Should -Be 'one'

        $listedKeys = @(Invoke-VaultList | Sort-Object)
        $listedKeys | Should -Contain 'alpha'
        $listedKeys | Should -Contain 'beta'
    }
}

Describe 'team-pipeline helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\team-pipeline.ps1')
    }

    It 'parses the orchestra manifest list format and resolves builder worktree paths' {
        $manifest = ConvertFrom-TeamPipelineManifestContent -Content @'
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: C:\repo\.worktrees\builder-1
    builder_worktree_path: C:\repo\.worktrees\builder-1
  - label: reviewer
    pane_id: %4
    role: Reviewer
    launch_dir: C:\repo
'@

        $manifest.Session.project_dir | Should -Be 'C:\repo'
        $manifest.Panes['builder-1'].pane_id | Should -Be '%2'
        $manifest.Panes['builder-1'].builder_worktree_path | Should -Be 'C:\repo\.worktrees\builder-1'

        $context = Resolve-TeamPipelineBuilderContext -BuilderLabel 'builder-1' -Manifest $manifest
        $context.ProjectDir | Should -Be 'C:\repo'
        $context.BuilderWorktreePath | Should -Be 'C:\repo\.worktrees\builder-1'
    }

    It 'supports the dictionary pane format used by the manifest helper module' {
        $manifest = ConvertFrom-TeamPipelineManifestContent -Content @'
version: 1
session:
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: %2
    role: Builder
    builder_worktree_path: C:\repo\.worktrees\builder-1
  reviewer:
    pane_id: %4
    role: Reviewer
    builder_worktree_path: ""
'@

        $manifest.Panes['builder-1'].role | Should -Be 'Builder'
        $manifest.Panes['reviewer'].pane_id | Should -Be '%4'
    }

    It 'extracts the last STATUS marker and strips it from the summary' {
        $output = @'
Work finished.
STATUS: EXEC_DONE

Follow-up note.
STATUS: VERIFY_PASS
'@

        (Get-TeamPipelineStatusFromOutput -Text $output) | Should -Be 'VERIFY_PASS'
        ((Get-TeamPipelineSummaryFromOutput -Text $output) -replace "`r`n", "`n") | Should -Be "Work finished.`n`nFollow-up note."
    }

    It 'parses structured verification output including VERIFY_PARTIAL' {
        $output = @'
STATUS: VERIFY_PARTIAL
SUMMARY: verify contract incomplete but evidence is usable
CHECK: diff|PASS|changed files inspected
CHECK: tests|FAIL|missing rerun evidence
NEXT_ACTION: rerun focused verification
'@

        $result = Get-TeamPipelineVerificationResultFromOutput -Text $output

        $result.outcome | Should -Be 'PARTIAL'
        $result.summary | Should -Be 'verify contract incomplete but evidence is usable'
        $result.checks.Count | Should -Be 2
        $result.checks[0].name | Should -Be 'diff'
        $result.checks[0].status | Should -Be 'PASS'
        $result.next_action | Should -Be 'rerun focused verification'
        $result.adversarial | Should -Be $true

        $envelope = New-TeamPipelineVerificationEvidenceEnvelope -VerificationResult $result
        $envelope.context_pack_id | Should -BeNullOrEmpty
        $envelope.context_pressure | Should -BeNullOrEmpty
        $envelope.context_pack_id | Should -Be $null
        $envelope.context_pressure | Should -Be $null
    }

    It 'detects approval prompts and blocks dangerous confirmations' {
        $typeEnter = Get-TeamPipelineApprovalAction -Text "Do you want to proceed?`n1. Yes"
        $typeEnter.Kind | Should -Be 'TypeEnter'
        $typeEnter.Value | Should -Be '1'

        $shellConfirm = Get-TeamPipelineApprovalAction -Text 'Continue [Y/n]'
        $shellConfirm.Value | Should -Be 'y'

        { Get-TeamPipelineApprovalAction -Text 'Approve command: git reset --hard origin/main' } | Should -Throw
    }

    It 'returns a blocked security verdict when dangerous approval text appears during a stage wait' {
        Mock Invoke-TeamPipelineBridge {
            [PSCustomObject]@{
                ExitCode = 0
                Output = "Approve command: git reset --hard origin/main"
            }
        }
        $script:securityEventWrites = @()
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:securityEventWrites += [PSCustomObject]@{
                Event = $Event
                Target = $Target
                Data = $Data
            }
        }

        $result = Wait-TeamPipelineStage -Target 'builder-1' -StageName 'EXEC' -TimeoutSeconds 1 -PollIntervalSeconds 0 -ProjectDir 'C:\repo' -SessionName 'winsmux-orchestra' -Role 'Builder' -Task 'Investigate cache drift' -Attempt 1

        $result.Status | Should -Be 'BLOCKED'
        $result.SecurityVerdict.verdict | Should -Be 'BLOCK'
        $result.SecurityVerdict.stage | Should -Be 'EXEC'
        $script:securityEventWrites.Count | Should -Be 1
        $script:securityEventWrites[0].Event | Should -Be 'pipeline.security.blocked'
        $script:securityEventWrites[0].Data.verdict | Should -Be 'BLOCK'
    }

    It 'blocks explicit git commands in plan prompts before dispatch' {
        $script:securityEventWrites = @()
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:securityEventWrites += [PSCustomObject]@{
                Event = $Event
                Target = $Target
                Data = $Data
            }
        }

        $result = Invoke-TeamPipelineGuardedSend -StageName 'PLAN' -Target 'researcher' -Prompt "git commit -m 'oops'" -ProjectDir 'C:\repo' -SessionName 'winsmux-orchestra' -Role 'Researcher' -Task 'Investigate cache drift'

        $result.Status | Should -Be 'BLOCKED'
        $result.SecurityVerdict.verdict | Should -Be 'BLOCK'
        $result.SecurityVerdict.stage | Should -Be 'PLAN'
        $script:securityEventWrites.Count | Should -Be 1
        $script:securityEventWrites[0].Data.category | Should -Be 'git'
    }

    It 'blocks explicit destructive commands in consult prompts before dispatch' {
        $script:securityEventWrites = @()
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:securityEventWrites += [PSCustomObject]@{
                Event = $Event
                Target = $Target
                Data = $Data
            }
        }

        $result = Invoke-TeamPipelineConsultStage -Mode 'stuck' -Task 'Investigate cache drift' -BuilderLabel 'builder-1' -ProjectDir 'C:\repo' -SessionName 'winsmux-orchestra' -TargetLabel 'reviewer' -ReviewerLabel 'reviewer' -BuilderWorktreePath 'C:\repo\.worktrees\builder-1' -BuildSummary 'Remove-Item logs -Recurse -Force'

        $result.Status | Should -Be 'BLOCKED'
        $result.SecurityVerdict.verdict | Should -Be 'BLOCK'
        $result.SecurityVerdict.stage | Should -Be 'CONSULT_STUCK'
        $script:securityEventWrites.Count | Should -Be 1
        @($script:securityEventWrites | Select-Object -ExpandProperty Event) | Should -Be @('pipeline.security.blocked')
    }

    It 'does not record review dispatched when verify prompt is blocked before send' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1' }
                'reviewer'  = [PSCustomObject]@{ pane_id = '%4'; role = 'Reviewer'; launch_dir = 'C:\repo' }
            }
        }

        $script:teamPipelineBridgeCalls = @()
        $script:teamPipelineEvents = @()

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge {
            param([string[]]$Arguments, [switch]$AllowFailure)
            $script:teamPipelineBridgeCalls += ,@($Arguments)
            [PSCustomObject]@{ ExitCode = 0; Output = '' }
        }
        Mock Wait-TeamPipelineStage {
            param([string]$Target, [string]$StageName, [int]$TimeoutSeconds, [int]$PollIntervalSeconds)
            switch ($StageName) {
                'PLAN' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'PLAN_DONE'; Summary = 'plan summary'; Transcript = '' } }
                'CONSULT_EARLY' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'CONSULT_DONE'; Summary = 'early consult summary'; Transcript = '' } }
                'EXEC' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'EXEC_DONE'; Summary = "git commit -m 'oops'"; Transcript = '' } }
                default { throw "Unexpected stage $StageName" }
            }
        }
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:teamPipelineEvents += [PSCustomObject]@{
                Event = $Event
                Role = $Role
                Target = $Target
                Data = $Data
            }
        }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -Reviewer 'reviewer'

        $result.FinalStatus | Should -Be 'VERIFY_BLOCKED'
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.review.dispatched' }).Count | Should -Be 0
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.security.blocked' }).Count | Should -BeGreaterThan 0
        $verifyResult = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.verify.partial' })[0]
        $verifyResult.Data.Contains('cost_unit_refs') | Should -BeFalse
    }

    It 'selects sensible planning and verification targets from the available roles' {
        $defaultTargets = Get-TeamPipelineStageTargets -BuilderLabel 'builder-1' -ResearcherLabel 'researcher' -ReviewerLabel 'reviewer'
        $defaultTargets.PlanTarget | Should -Be 'researcher'
        $defaultTargets.BuildTarget | Should -Be 'builder-1'
        $defaultTargets.VerifyTarget | Should -Be 'reviewer'

        $workerTargets = Get-TeamPipelineStageTargets -BuilderLabel 'worker-1' -ResearcherLabel '' -ReviewerLabel ''
        $workerTargets.PlanTarget | Should -Be 'worker-1'
        $workerTargets.VerifyTarget | Should -Be 'worker-1'

        $skipTargets = Get-TeamPipelineStageTargets -BuilderLabel 'builder-1' -ResearcherLabel 'researcher' -ReviewerLabel 'reviewer' -SkipPlan -SkipVerify
        $skipTargets.PlanTarget | Should -BeNullOrEmpty
        $skipTargets.VerifyTarget | Should -BeNullOrEmpty
    }

    It 'uses manifest capability flags when no explicit verification target is supplied' {
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ role = 'Worker'; supports_verification = 'false'; supports_structured_result = 'true' }
                'worker-2' = [ordered]@{ role = 'Worker'; supports_verification = 'true'; supports_structured_result = 'true' }
                'reviewer' = [ordered]@{ role = 'Reviewer'; supports_verification = 'true'; supports_structured_result = 'true' }
            }
        }

        $targets = Get-TeamPipelineStageTargets -BuilderLabel 'worker-1' -ResearcherLabel '' -ReviewerLabel '' -Manifest $manifest

        $targets.VerifyTarget | Should -Be 'reviewer'
    }

    It 'requires structured results for automatic verification targets' {
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ role = 'Worker'; supports_verification = 'false'; supports_structured_result = 'true' }
                'reviewer' = [ordered]@{ role = 'Reviewer'; supports_verification = 'true'; supports_structured_result = 'false' }
                'worker-2' = [ordered]@{ role = 'Worker'; supports_verification = 'true'; supports_structured_result = 'true' }
            }
        }

        $targets = Get-TeamPipelineStageTargets -BuilderLabel 'worker-1' -ResearcherLabel '' -ReviewerLabel '' -Manifest $manifest

        $targets.VerifyTarget | Should -Be 'worker-2'
    }

    It 'falls back to configured researcher when no manifest verification capability is available' {
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ role = 'Worker'; supports_verification = 'false'; supports_structured_result = 'true' }
                'worker-2' = [ordered]@{ role = 'Worker'; supports_verification = 'true'; supports_structured_result = 'false' }
            }
        }

        $targets = Get-TeamPipelineStageTargets -BuilderLabel 'worker-1' -ResearcherLabel 'researcher' -ReviewerLabel '' -Manifest $manifest

        $targets.VerifyTarget | Should -Be 'researcher'
    }

    It 'does not fall back to unstructured verification targets from the manifest' {
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ role = 'Worker'; supports_verification = 'true'; supports_structured_result = 'false' }
                'researcher' = [ordered]@{ role = 'Researcher'; supports_verification = 'true'; supports_structured_result = 'false' }
            }
        }

        $targets = Get-TeamPipelineStageTargets -BuilderLabel 'worker-1' -ResearcherLabel 'researcher' -ReviewerLabel '' -Manifest $manifest

        $targets.VerifyTarget | Should -BeNullOrEmpty
    }

    It 'blocks one-shot orchestration when verification is required but no structured verifier exists' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1'; supports_verification = 'true'; supports_structured_result = 'false' }
                'researcher' = [PSCustomObject]@{ pane_id = '%3'; role = 'Researcher'; supports_verification = 'true'; supports_structured_result = 'false' }
            }
        }

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge { throw 'pipeline should not dispatch without a structured verifier' }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -Researcher 'researcher'

        $result.Success | Should -Be $false
        $result.FinalStatus | Should -Be 'VERIFY_UNAVAILABLE'
        $result.VerificationUnavailableReason | Should -Match 'structured results'
        Should -Invoke Invoke-TeamPipelineBridge -Times 0 -Exactly
    }

    It 'blocks one-shot orchestration when the build target cannot edit files' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1'; capability_adapter = 'codex'; capability_command = 'codex'; supports_file_edit = 'false'; supports_verification = 'true'; supports_structured_result = 'true' }
                'reviewer'  = [PSCustomObject]@{ pane_id = '%3'; role = 'Reviewer'; supports_file_edit = 'false'; supports_verification = 'true'; supports_structured_result = 'true' }
            }
        }

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge { throw 'pipeline should not dispatch to a build target without file edit support' }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -Reviewer 'reviewer' -SkipVerify

        $result.Success | Should -Be $false
        $result.FinalStatus | Should -Be 'EXEC_UNAVAILABLE'
        $result.BuildUnavailableReason | Should -Match 'file edits'
        Should -Invoke Invoke-TeamPipelineBridge -Times 0 -Exactly
    }

    It 'treats generated default file edit flags without capability identity as unknown' {
        $projectDir = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-team-pipeline-tests-' + [guid]::NewGuid().ToString('N'))
        $builderWorktreePath = Join-Path $projectDir '.worktrees\builder-1'

        try {
            New-Item -ItemType Directory -Path $builderWorktreePath -Force | Out-Null

            $manifest = [PSCustomObject]@{
                Session = [PSCustomObject]@{
                    name        = 'winsmux-orchestra'
                    project_dir = $projectDir
                }
                Panes = [ordered]@{
                    'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = $builderWorktreePath; supports_file_edit = 'false' }
                }
            }

            $script:teamPipelineBridgeCalls = @()

            Mock Read-TeamPipelineManifest { $manifest }
            Mock Invoke-TeamPipelineBridge {
                param([string[]]$Arguments, [switch]$AllowFailure)
                $script:teamPipelineBridgeCalls += ,@($Arguments)
                [PSCustomObject]@{ ExitCode = 0; Output = '' }
            }
            Mock Wait-TeamPipelineStage {
                [PSCustomObject]@{ Stage = 'EXEC'; Target = 'builder-1'; Status = 'EXEC_DONE'; Summary = 'build summary'; Transcript = '' }
            }

            $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -SkipPlan -SkipVerify

            $result.Success | Should -Be $true
            $result.FinalStatus | Should -Be 'EXEC_DONE'
            @($script:teamPipelineBridgeCalls | Where-Object { $_[0] -eq 'send' -and $_[1] -eq 'builder-1' }).Count | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $projectDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'prefers reviewer then researcher for consult targets and skips builder-only runs' {
        (Get-TeamPipelineConsultTarget -BuilderLabel 'builder-1' -ResearcherLabel 'researcher' -ReviewerLabel 'reviewer') | Should -Be 'reviewer'
        (Get-TeamPipelineConsultTarget -BuilderLabel 'builder-1' -ResearcherLabel 'researcher' -ReviewerLabel '') | Should -Be 'researcher'
        (Get-TeamPipelineConsultTarget -BuilderLabel 'builder-1' -ResearcherLabel '' -ReviewerLabel 'builder-1') | Should -BeNullOrEmpty
        (Get-TeamPipelineConsultTarget -BuilderLabel 'builder-1' -ResearcherLabel '' -ReviewerLabel '') | Should -BeNullOrEmpty
    }

    It 'uses manifest consultation capability when no explicit consult target is supplied' {
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ role = 'Worker'; supports_consultation = 'false' }
                'worker-2' = [ordered]@{ role = 'Worker'; supports_consultation = 'true' }
            }
        }

        $target = Get-TeamPipelineConsultTarget -BuilderLabel 'worker-1' -ResearcherLabel '' -ReviewerLabel '' -Manifest $manifest

        $target | Should -Be 'worker-2'
    }

    It 'inserts early and final consult stages into successful one-shot orchestration when a consult target exists' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1' }
                'reviewer'  = [PSCustomObject]@{ pane_id = '%4'; role = 'Reviewer'; launch_dir = 'C:\repo' }
            }
        }

        $script:teamPipelineBridgeCalls = @()
        $script:teamPipelineEvents = @()

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge {
            param([string[]]$Arguments, [switch]$AllowFailure)
            $script:teamPipelineBridgeCalls += ,@($Arguments)
            [PSCustomObject]@{ ExitCode = 0; Output = '' }
        }
        Mock Wait-TeamPipelineStage {
            param([string]$Target, [string]$StageName, [int]$TimeoutSeconds, [int]$PollIntervalSeconds)
            switch ($StageName) {
                'PLAN'          { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'PLAN_DONE'; Summary = 'plan summary'; Transcript = '' } }
                'CONSULT_EARLY' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'CONSULT_DONE'; Summary = 'early consult summary'; Transcript = '' } }
                'EXEC'          { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'EXEC_DONE'; Summary = 'build summary'; Transcript = '' } }
                'VERIFY'        {
                    return [PSCustomObject]@{
                        Stage = $StageName
                        Target = $Target
                        Status = 'VERIFY_PASS'
                        Summary = @'
SUMMARY: verify summary
STATUS: VERIFY_PASS
CHECK: build|PASS|npm run build
CHECK: test|PASS|Invoke-Pester tests/winsmux-bridge.Tests.ps1
CHECK: browser|SKIP|not a UI change
CONTEXT_BUDGET: 120000
CONTEXT_ESTIMATE: 42000
CONTEXT_PACK_ID: ctx-pipeline
TOOL_OUTPUT_PRUNED_COUNT: 2
CONTEXT_PRESSURE: medium
NEXT_ACTION: ready_for_done
'@
                        Transcript = ''
                    }
                }
                'CONSULT_FINAL' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'CONSULT_DONE'; Summary = 'final consult summary'; Transcript = '' } }
                default         { throw "Unexpected stage $StageName" }
            }
        }
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:teamPipelineEvents += [PSCustomObject]@{
                Event = $Event
                Role = $Role
                Target = $Target
                Data = $Data
            }
        }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -Reviewer 'reviewer'

        $result.FinalStatus | Should -Be 'VERIFY_PASS'
        $result.Success | Should -Be $true
        $result.PreWorkConsult.Status | Should -Be 'CONSULT_DONE'
        $result.FinalConsult.Status | Should -Be 'CONSULT_DONE'
        @($script:teamPipelineBridgeCalls | Where-Object { $_[0] -eq 'send' -and $_[1] -eq 'reviewer' }).Count | Should -Be 3
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.consult.dispatched' }).Count | Should -Be 2
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.consult.completed' }).Count | Should -Be 2
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.decompose.completed' }).Count | Should -Be 1
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.dispatch.assigned' }).Count | Should -Be 1
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.collect.completed' }).Count | Should -Be 1
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.review.dispatched' }).Count | Should -Be 1

        $managedDispatch = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.dispatch.assigned' })[0]
        $managedDispatch.Role | Should -Be 'Operator'
        $managedDispatch.Data.upper_operator | Should -Be 'claude_code'
        $managedDispatch.Data.aggregation_point | Should -Be 'claude_code_operator'
        $managedDispatch.Data.peer_to_peer_allowed | Should -Be $false
        $managedDispatch.Data.state | Should -Be 'assigned'

        $consultDispatch = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.consult.dispatched' })[0]
        $consultDispatch.Data.governance_cost_units[0].unit_type | Should -Be 'governance_invocation'
        $consultDispatch.Data.governance_cost_units[0].kind | Should -Be 'consult'
        $consultDispatch.Data.governance_cost_units[0].mode | Should -Be 'early'

        $consultComplete = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.consult.completed' })[0]
        $consultComplete.Data.cost_unit_refs[0] | Should -Be $consultDispatch.Data.governance_cost_units[0].unit_id

        $verifyDispatch = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.review.dispatched' })[0]
        $verifyDispatch.Data.governance_cost_units[0].unit_type | Should -Be 'governance_invocation'
        $verifyDispatch.Data.governance_cost_units[0].kind | Should -Be 'verify'

        $verifyResult = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.verify.pass' })[0]
        $verifyResult.Data.cost_unit_refs[0] | Should -Be $verifyDispatch.Data.governance_cost_units[0].unit_id
        $verifyResult.Data.verification_evidence.build.outcome | Should -Be 'PASS'
        $verifyResult.Data.verification_evidence.test.detail | Should -Be 'Invoke-Pester tests/winsmux-bridge.Tests.ps1'
        $verifyResult.Data.verification_evidence.browser.outcome | Should -Be 'SKIP'
        $verifyResult.Data.verification_evidence.context_budget | Should -Be 120000
        $verifyResult.Data.verification_evidence.context_estimate | Should -Be 42000
        $verifyResult.Data.verification_evidence.context_pack_id | Should -Be 'ctx-pipeline'
        $verifyResult.Data.verification_evidence.tool_output_pruned_count | Should -Be 2
        $verifyResult.Data.verification_evidence.context_pressure | Should -Be 'medium'
    }

    It 'inserts a stuck consult before returning blocked execution' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1' }
                'reviewer'  = [PSCustomObject]@{ pane_id = '%4'; role = 'Reviewer'; launch_dir = 'C:\repo' }
            }
        }

        $script:teamPipelineBridgeCalls = @()
        $script:teamPipelineEvents = @()

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge {
            param([string[]]$Arguments, [switch]$AllowFailure)
            $script:teamPipelineBridgeCalls += ,@($Arguments)
            [PSCustomObject]@{ ExitCode = 0; Output = '' }
        }
        Mock Wait-TeamPipelineStage {
            param([string]$Target, [string]$StageName, [int]$TimeoutSeconds, [int]$PollIntervalSeconds)
            switch ($StageName) {
                'PLAN'          { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'PLAN_DONE'; Summary = 'plan summary'; Transcript = '' } }
                'CONSULT_EARLY' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'CONSULT_DONE'; Summary = 'early consult summary'; Transcript = '' } }
                'EXEC'          { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'BLOCKED'; Summary = 'builder blocked summary'; Transcript = '' } }
                'CONSULT_STUCK' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'CONSULT_DONE'; Summary = 'stuck consult summary'; Transcript = '' } }
                default         { throw "Unexpected stage $StageName" }
            }
        }
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:teamPipelineEvents += [PSCustomObject]@{
                Event = $Event
                Role = $Role
                Target = $Target
                Data = $Data
            }
        }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -Reviewer 'reviewer'

        $result.FinalStatus | Should -Be 'EXEC_BLOCKED'
        $result.Success | Should -Be $false
        $result.StuckConsults.Count | Should -Be 1
        $result.StuckConsults[0].Status | Should -Be 'CONSULT_DONE'
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.consult.dispatched' }).Count | Should -Be 2
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.consult.completed' }).Count | Should -Be 2
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.escalate.required' }).Count | Should -Be 1

        $escalation = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.escalate.required' })[0]
        $escalation.Role | Should -Be 'Operator'
        $escalation.Data.state | Should -Be 'required'
        $escalation.Data.reason | Should -Be 'EXEC_BLOCKED'
        $escalation.Data.peer_to_peer_allowed | Should -Be $false
    }

    It 'keeps escalation target visible when no consult pane is configured' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1' }
                'reviewer'  = [PSCustomObject]@{ pane_id = '%4'; role = 'Reviewer'; launch_dir = 'C:\repo'; supports_structured_result = 'true'; supports_verification = 'true'; supports_consultation = 'false' }
            }
        }

        $script:teamPipelineEvents = @()

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge { [PSCustomObject]@{ ExitCode = 0; Output = '' } }
        Mock Wait-TeamPipelineStage {
            param([string]$Target, [string]$StageName)
            switch ($StageName) {
                'EXEC'   { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'EXEC_DONE'; Summary = 'build summary'; Transcript = '' } }
                'VERIFY' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'VERIFY_PARTIAL'; Summary = 'needs operator decision'; Transcript = '' } }
                default  { throw "Unexpected stage $StageName" }
            }
        }
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:teamPipelineEvents += [PSCustomObject]@{
                Event  = $Event
                Role   = $Role
                Target = $Target
                Data   = $Data
            }
        }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -SkipPlan

        $result.FinalStatus | Should -Be 'VERIFY_PARTIAL'
        $escalation = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.escalate.required' })[0]
        $escalation.Target | Should -Be 'claude_code_operator'
        $escalation.Data.target | Should -Be 'claude_code_operator'
        $escalation.Data.peer_to_peer_allowed | Should -Be $false
    }
}

Describe 'manifest worker isolation metadata' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\manifest.ps1')
    }

    It 'persists worker assignment fields in pane entries' {
        $entry = ConvertTo-ManifestPaneEntry -PaneSummary ([ordered]@{
            Label = 'worker-1'
            PaneId = '%2'
            SlotId = 'worker-1'
            Role = 'Worker'
            ProjectDir = 'C:\repo'
            BuilderBranch = 'worktree-worker-1'
            BuilderWorktreePath = 'C:\repo\.worktrees\worker-1'
            WorktreeGitDir = 'C:\repo\.git\worktrees\worker-1'
            ExpectedOrigin = 'https://github.com/example/repo.git'
        })

        $entry.pane_id | Should -Be '%2'
        $entry.slot_id | Should -Be 'worker-1'
        $entry.project_dir | Should -Be 'C:\repo'
        $entry.builder_branch | Should -Be 'worktree-worker-1'
        $entry.builder_worktree_path | Should -Be 'C:\repo\.worktrees\worker-1'
        $entry.worktree_git_dir | Should -Be 'C:\repo\.git\worktrees\worker-1'
        $entry.expected_origin | Should -Be 'https://github.com/example/repo.git'
    }

    It 'TASK658 round-trips declarative workspace and preserves unknown additive sections' {
        $content = @'
version: 1
saved_at: '2026-07-21T00:00:00Z'
session:
  name: 'winsmux-orchestra'
panes: {}
tasks:
  queued: []
  in_progress: []
  completed: []
worktrees: {}
declarative_workspace:
  schema_version: '1'
  config_fingerprint: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  recipe_id: 'review'
  resolved_bindings:
    implement: 'worker-1'
    verify: 'worker-2'
workflow_runs:
  run-1:
    state: 'blocked'
'@

        $first = ConvertFrom-ManifestYaml -Content $content
        $serialized = ConvertTo-ManifestYaml -Manifest $first
        $second = ConvertFrom-ManifestYaml -Content $serialized

        $serialized | Should -Match "(?m)^  schema_version: '1'$"
        $second.declarative_workspace.recipe_id | Should -Be 'review'
        $second.declarative_workspace.config_fingerprint | Should -Be ('sha256:' + ('a' * 64))
        $second.declarative_workspace.resolved_bindings.implement | Should -Be 'worker-1'
        $second.declarative_workspace.resolved_bindings.verify | Should -Be 'worker-2'
        $serialized | Should -Match '(?m)^workflow_runs:'
        $serialized | Should -Match "(?m)^    state: 'blocked'"
    }

    It 'TASK658 derives a deterministic declarative workspace fingerprint without writing state' {
        $plan = [ordered]@{
            recipe_id = 'review'
            config_fingerprint = ('sha256:' + ('a' * 64))
            resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
        }
        $first = New-WinsmuxDeclarativeWorkspaceProjection -Plan $plan
        $second = New-WinsmuxDeclarativeWorkspaceProjection -Plan $plan

        $first.config_fingerprint | Should -Be $second.config_fingerprint
        $first.config_fingerprint | Should -Be $plan.config_fingerprint
        $first.config_fingerprint | Should -Match '^sha256:[0-9a-f]{64}$'
        $first.resolved_bindings.verify | Should -Be 'worker-2'

        $invalid = [ordered]@{
            recipe_id = 'C:\private\recipe'
            config_fingerprint = $plan.config_fingerprint
            resolved_bindings = $plan.resolved_bindings
        }
        { New-WinsmuxDeclarativeWorkspaceProjection -Plan $invalid } |
            Should -Throw '*stable lowercase ASCII identifier*'
        { New-WinsmuxDeclarativeWorkspaceProjection -Plan $plan -DryRunPlanRef 'evidence:../private' } |
            Should -Throw '*safe evidence reference*'
    }
}

Describe 'winsmux pane env contract' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\pane-env.ps1')
    }

    BeforeEach {
        $script:paneEnvTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-pane-env-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:paneEnvTempRoot '.winsmux') -Force | Out-Null
        $script:previousHookProfile = $env:WINSMUX_HOOK_PROFILE
        $script:previousGovernanceMode = $env:WINSMUX_GOVERNANCE_MODE
    }

    AfterEach {
        if ($null -eq $script:previousHookProfile) {
            Remove-Item Env:WINSMUX_HOOK_PROFILE -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_HOOK_PROFILE = $script:previousHookProfile
        }

        if ($null -eq $script:previousGovernanceMode) {
            Remove-Item Env:WINSMUX_GOVERNANCE_MODE -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_GOVERNANCE_MODE = $script:previousGovernanceMode
        }

        if ($script:paneEnvTempRoot -and (Test-Path $script:paneEnvTempRoot)) {
            Remove-Item -Path $script:paneEnvTempRoot -Recurse -Force
        }
    }

    It 'reads hook profile and governance mode from governance.yaml when env vars are absent' {
@'
mode: enhanced
hook_profile: builder
'@ | Set-Content -Path (Join-Path $script:paneEnvTempRoot '.winsmux\governance.yaml') -Encoding UTF8

        $contract = Get-WinsmuxEnvironmentContract -ProjectDir $script:paneEnvTempRoot

        $contract.hook_profile | Should -Be 'builder'
        $contract.governance_mode | Should -Be 'enhanced'
        $contract.variable_names | Should -Contain 'WINSMUX_HOOK_PROFILE'
        $contract.variable_names | Should -Contain 'WINSMUX_GOVERNANCE_MODE'
    }

    It 'lets WINSMUX_HOOK_PROFILE and WINSMUX_GOVERNANCE_MODE override governance.yaml' {
@'
mode: core
hook_profile: ci
'@ | Set-Content -Path (Join-Path $script:paneEnvTempRoot '.winsmux\governance.yaml') -Encoding UTF8
        $env:WINSMUX_HOOK_PROFILE = 'operator'
        $env:WINSMUX_GOVERNANCE_MODE = 'standard'

        (Resolve-WinsmuxHookProfile -ProjectDir $script:paneEnvTempRoot) | Should -Be 'operator'
        (Resolve-WinsmuxGovernanceMode -ProjectDir $script:paneEnvTempRoot) | Should -Be 'standard'
    }

    It 'builds a normalized pane environment payload' {
        $env:WINSMUX_HOOK_PROFILE = 'builder'
        $env:WINSMUX_GOVERNANCE_MODE = 'enhanced'

        $payload = Get-WinsmuxPaneEnvironment -Role 'Worker' -PaneId '%4' -SessionName 'winsmux-orchestra' -ProjectDir $script:paneEnvTempRoot -RoleMapJson '{"%4":"Worker"}' -BuilderWorktreePath 'C:\repo\.worktrees\builder-1' -SlotId 'worker-1' -AssignedBranch 'worktree-worker-1' -GitWorktreeDir 'C:\repo\.git\worktrees\worker-1' -ExpectedOrigin 'https://github.com/example/repo.git'

        $payload.WINSMUX_ORCHESTRA_SESSION | Should -Be 'winsmux-orchestra'
        $payload.WINSMUX_ORCHESTRA_PROJECT_DIR | Should -Be $script:paneEnvTempRoot
        $payload.WINSMUX_ROLE | Should -Be 'Worker'
        $payload.WINSMUX_PANE_ID | Should -Be '%4'
        $payload.WINSMUX_ROLE_MAP | Should -Be '{"%4":"Worker"}'
        $payload.WINSMUX_BUILDER_WORKTREE | Should -Be 'C:\repo\.worktrees\builder-1'
        $payload.WINSMUX_ASSIGNED_WORKTREE | Should -Be 'C:\repo\.worktrees\builder-1'
        $payload.WINSMUX_SLOT_ID | Should -Be 'worker-1'
        $payload.WINSMUX_ASSIGNED_BRANCH | Should -Be 'worktree-worker-1'
        $payload.WINSMUX_WORKTREE_GITDIR | Should -Be 'C:\repo\.git\worktrees\worker-1'
        $payload.WINSMUX_EXPECTED_ORIGIN | Should -Be 'https://github.com/example/repo.git'
        $payload.WINSMUX_HOOK_PROFILE | Should -Be 'builder'
        $payload.WINSMUX_GOVERNANCE_MODE | Should -Be 'enhanced'
    }

    It 'builds a clean ConPTY boundary that scrubs stray WINSMUX variables before reinjection' {
        $env:WINSMUX_HOOK_PROFILE = 'builder'
        $env:WINSMUX_GOVERNANCE_MODE = 'enhanced'

        $payload = Get-WinsmuxPaneEnvironment -Role 'Worker' -PaneId '%4' -SessionName 'winsmux-orchestra' -ProjectDir $script:paneEnvTempRoot -RoleMapJson '{"%4":"Worker"}' -BuilderWorktreePath 'C:\repo\.worktrees\builder-1'
        $clean = Get-CleanPtyEnv -AllowedEnvironment $payload

        $clean.RemoveCommand | Should -Match 'WINSMUX_\*'
        $clean.RemoveCommand | Should -Match 'Remove-Item'
        $clean.AllowedVariableNames | Should -Contain 'WINSMUX_ROLE'
        $clean.AllowedVariableNames | Should -Contain 'WINSMUX_GOVERNANCE_MODE'
        $clean.Environment.WINSMUX_ROLE | Should -Be 'Worker'
        $clean.Environment.WINSMUX_PANE_ID | Should -Be '%4'
    }

    It 'creates a normalized governance cost unit' {
        $unit = New-WinsmuxGovernanceCostUnit -Kind 'Consult' -Mode 'Final' -Task 'TASK-310' -RunId 'task:310' -Stage 'CONSULT_FINAL' -Role 'Reviewer' -Target 'reviewer' -Attempt 1 -Source 'test'

        $unit.unit_type | Should -Be 'governance_invocation'
        $unit.kind | Should -Be 'consult'
        $unit.mode | Should -Be 'final'
        $unit.stage | Should -Be 'consult_final'
        $unit.quantity | Should -Be 1
        $unit.unit_id | Should -Match 'TASK-310'
    }
}

Describe 'pane-control helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\pane-control.ps1')
    }

    BeforeEach {
        $script:paneControlTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-pane-control-tests-' + [guid]::NewGuid().ToString('N'))
        $script:paneControlManifestDir = Join-Path $script:paneControlTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:paneControlManifestDir -Force | Out-Null
    }

    AfterEach {
        if ($script:paneControlTempRoot -and (Test-Path $script:paneControlTempRoot)) {
            Remove-Item -Path $script:paneControlTempRoot -Recurse -Force
        }
    }

    It 'prefers launch_dir over builder_worktree_path when building a restart plan' {
        @'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'builder-1'
    pane_id: '%2'
    role: 'Builder'
    exec_mode: true
    launch_dir: 'C:\repo\.worktrees\builder-2'
    builder_branch: 'worktree-builder-1'
    builder_worktree_path: 'C:\repo\.worktrees\builder-1'
    task: null
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{}
        }

        $plan = Get-PaneControlRestartPlan -ProjectDir $script:paneControlTempRoot -PaneId '%2' -Settings $settings

        $plan.LaunchDir | Should -Be 'C:\repo\.worktrees\builder-2'
        $plan.GitWorktreeDir | Should -Be 'C:\repo\.worktrees\builder-2'
        $plan.LaunchCommand | Should -Match $([regex]::Escape("-C 'C:\repo\.worktrees\builder-2'"))
    }

    It 'preserves explicit worktree_git_dir when reading a worker entry' {
@'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'worker-1'
    pane_id: '%2'
    role: 'Worker'
    exec_mode: true
    launch_dir: 'C:\repo\.worktrees\worker-1'
    builder_branch: 'worktree-worker-1'
    builder_worktree_path: 'C:\repo\.worktrees\worker-1'
    worktree_git_dir: 'C:\repo\.git\worktrees\worker-1'
    task: null
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $entries = @(Get-PaneControlManifestEntries -ProjectDir $script:paneControlTempRoot)

        $entries.Count | Should -Be 1
        $entries[0].LaunchDir | Should -Be 'C:\repo\.worktrees\worker-1'
        $entries[0].BuilderBranch | Should -Be 'worktree-worker-1'
        $entries[0].GitWorktreeDir | Should -Be 'C:\repo\.git\worktrees\worker-1'
    }

    It 'ignores stale worker worktree metadata when reading a non-worker entry' {
@'
version: 1
saved_at: '2026-04-23T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'reviewer'
    pane_id: '%4'
    role: 'Reviewer'
    exec_mode: true
    launch_dir: ''
    builder_branch: 'worktree-worker-1'
    builder_worktree_path: 'C:\repo\.worktrees\worker-1'
    worktree_git_dir: 'C:\repo\.git\worktrees\worker-1'
    task: null
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $entries = @(Get-PaneControlManifestEntries -ProjectDir $script:paneControlTempRoot)

        $entries.Count | Should -Be 1
        $entries[0].Role | Should -Be 'Reviewer'
        $entries[0].LaunchDir | Should -Be 'C:\repo'
        $entries[0].BuilderBranch | Should -Be ''
        $entries[0].BuilderWorktreePath | Should -Be ''
        $entries[0].GitWorktreeDir | Should -Be 'C:\repo\.git'
    }

    It 'uses slot-level agent and model overrides when building a restart plan' {
@'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'worker-1'
    pane_id: '%2'
    role: 'Worker'
    exec_mode: false
    launch_dir: 'C:\repo'
    task: null
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{
                worker = [ordered]@{
                    agent = 'codex'
                    model = 'gpt-5.4'
                }
            }
            agent_slots = @(
                [ordered]@{
                    slot_id = 'worker-1'
                    runtime_role = 'worker'
                    agent = 'claude'
                    model = 'sonnet'
                }
            )
        }

        $plan = Get-PaneControlRestartPlan -ProjectDir $script:paneControlTempRoot -PaneId '%2' -Settings $settings

        $plan.Agent | Should -Be 'claude'
        $plan.Model | Should -Be 'sonnet'
        $plan.PromptTransport | Should -Be 'argv'
        $plan.LaunchCommand | Should -Be "claude --model 'sonnet' --permission-mode bypassPermissions"
    }

    It 'uses provider registry overrides when building a restart plan' {
@"
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: '${script:paneControlTempRoot}'
  git_worktree_dir: '${script:paneControlTempRoot}\.git'
panes:
  - label: 'worker-1'
    pane_id: '%2'
    role: 'Worker'
    exec_mode: false
    launch_dir: '${script:paneControlTempRoot}'
    task: null
"@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        @"
agent: codex
model: gpt-5.4
agent_slots:
  - slot_id: worker-1
    runtime_role: worker
    agent: codex
    model: gpt-5.4
    prompt_transport: argv
"@ | Set-Content -Path (Join-Path $script:paneControlTempRoot '.winsmux.yaml') -Encoding UTF8

        Write-BridgeProviderRegistryEntry `
            -RootPath $script:paneControlTempRoot `
            -SlotId 'worker-1' `
            -Agent 'claude' `
            -Model 'opus' `
            -PromptTransport 'file' `
            -Reason 'operator requested provider hot-swap' | Out-Null
        $settings = Get-BridgeSettings -RootPath $script:paneControlTempRoot

        $plan = Get-PaneControlRestartPlan -ProjectDir $script:paneControlTempRoot -PaneId '%2' -Settings $settings

        $plan.Agent | Should -Be 'claude'
        $plan.Model | Should -Be 'opus'
        $plan.PromptTransport | Should -Be 'file'
        $plan.Source | Should -Be 'registry'
        $plan.LaunchCommand | Should -Be "claude --model 'opus' --permission-mode bypassPermissions"
    }

    It 'projects provider capability adapters into restart plans' {
@"
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: '${script:paneControlTempRoot}'
  git_worktree_dir: '${script:paneControlTempRoot}\.git'
panes:
  - label: 'worker-1'
    pane_id: '%2'
    role: 'Worker'
    exec_mode: false
    launch_dir: '${script:paneControlTempRoot}'
    task: null
"@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8
@'
{
  "version": 1,
  "providers": {
    "codex-nightly": {
      "adapter": "codex",
      "command": "codex-nightly",
      "prompt_transports": ["argv", "file"],
      "supports_parallel_runs": true,
      "supports_interrupt": true,
      "supports_structured_result": true,
      "supports_file_edit": true,
      "supports_subagents": true,
      "supports_verification": true,
      "supports_consultation": false,
      "supports_context_reset": true
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'provider-capabilities.json') -Encoding UTF8
        Write-BridgeProviderRegistryEntry `
            -RootPath $script:paneControlTempRoot `
            -SlotId 'worker-1' `
            -Agent 'codex-nightly' `
            -Model 'gpt-5.4-nightly' `
            -PromptTransport 'argv' `
            -Reason 'operator requested provider hot-swap' | Out-Null
        $settings = Get-BridgeSettings -RootPath $script:paneControlTempRoot

        $plan = Get-PaneControlRestartPlan -ProjectDir $script:paneControlTempRoot -PaneId '%2' -Settings $settings

        $plan.Agent | Should -Be 'codex-nightly'
        $plan.CapabilityAdapter | Should -Be 'codex'
        $plan.LaunchCommand | Should -Match "^codex-nightly -c 'model=gpt-5\.4-nightly'"
    }

    It 'includes slot-level prompt transport overrides in the restart plan' {
@'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'worker-1'
    pane_id: '%2'
    role: 'Worker'
    exec_mode: false
    launch_dir: 'C:\repo'
    task: null
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            prompt_transport = 'argv'
            roles = [ordered]@{
                worker = [ordered]@{
                    agent = 'codex'
                    model = 'gpt-5.4'
                    prompt_transport = 'file'
                }
            }
            agent_slots = @(
                [ordered]@{
                    slot_id = 'worker-1'
                    runtime_role = 'worker'
                    agent = 'claude'
                    model = 'sonnet'
                    prompt_transport = 'argv'
                }
            )
        }

        $plan = Get-PaneControlRestartPlan -ProjectDir $script:paneControlTempRoot -PaneId '%2' -Settings $settings

        $plan.Agent | Should -Be 'claude'
        $plan.Model | Should -Be 'sonnet'
        $plan.PromptTransport | Should -Be 'argv'
    }

    It 'updates launch_dir and builder_worktree_path together for builder panes' {
@'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'builder-1'
    pane_id: '%2'
    role: 'Builder'
    exec_mode: true
    launch_dir: 'C:\repo\.worktrees\builder-1'
    builder_branch: 'worktree-builder-1'
    builder_worktree_path: 'C:\repo\.worktrees\builder-1'
    task: null
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        Set-PaneControlManifestPanePaths -ProjectDir $script:paneControlTempRoot -PaneId '%2' -LaunchDir 'C:\repo\.worktrees\builder-9' -BuilderWorktreePath 'C:\repo\.worktrees\builder-9'

        $context = Get-PaneControlManifestContext -ProjectDir $script:paneControlTempRoot -PaneId '%2'
        $manifestContent = Get-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Raw -Encoding UTF8
        $context.LaunchDir | Should -Be 'C:\repo\.worktrees\builder-9'
        $context.BuilderWorktreePath | Should -Be 'C:\repo\.worktrees\builder-9'
        $manifestContent | Should -Match $([regex]::Escape("launch_dir: 'C:\repo\.worktrees\builder-9'"))
        $manifestContent | Should -Match $([regex]::Escape("builder_worktree_path: 'C:\repo\.worktrees\builder-9'"))
    }

    It 'updates the manifest label from the respawned pane title' {
@'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'builder-1'
    pane_id: '%2'
    role: 'Builder'
    exec_mode: true
    launch_dir: 'C:\repo\.worktrees\builder-1'
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        Mock Get-PaneControlPaneTitle { 'builder-2' }

        $updated = Update-PaneControlManifestPaneLabel -ProjectDir $script:paneControlTempRoot -PaneId '%2'

        $context = Get-PaneControlManifestContext -ProjectDir $script:paneControlTempRoot -PaneId '%2'
        $manifestContent = Get-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Raw -Encoding UTF8

        $updated | Should -Be $true
        $context.Label | Should -Be 'builder-2'
        $manifestContent | Should -Match $([regex]::Escape("'builder-2':"))
    }

    It 'updates the manifest label when panes are stored in dictionary format' {
@'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  builder-1:
    pane_id: '%2'
    role: 'Builder'
    exec_mode: true
    launch_dir: 'C:\repo\.worktrees\builder-1'
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        Mock Get-PaneControlPaneTitle { 'builder-2' }

        $updated = Update-PaneControlManifestPaneLabel -ProjectDir $script:paneControlTempRoot -PaneId '%2'

        $context = Get-PaneControlManifestContext -ProjectDir $script:paneControlTempRoot -PaneId '%2'
        $manifestContent = Get-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Raw -Encoding UTF8

        $updated | Should -Be $true
        $context.Label | Should -Be 'builder-2'
        $manifestContent | Should -Match $([regex]::Escape("'builder-2':"))
    }

    It 'TASK781 C19 threads the generation captured with the label context into the setter' {
        $script:capturedWrapperGeneration = ''
        Mock Get-PaneControlManifestContext {
            [pscustomobject]@{
                ManifestPath = 'C:\repo\.winsmux\manifest.yaml'
                Label = 'builder-1'
                GenerationId = 'generation-initial'
            }
        }
        Mock Get-PaneControlPaneTitle { 'builder-2' }
        Mock Get-PaneControlManifestGenerationId { 'generation-replacement' }
        Mock Set-PaneControlManifestPaneProperties {
            param($ManifestPath, $PaneId, $Properties, $ExpectedGenerationId)
            $script:capturedWrapperGeneration = [string]$ExpectedGenerationId
        }

        Update-PaneControlManifestPaneLabel -ProjectDir 'C:\repo' -PaneId '%2' | Should -BeTrue

        $script:capturedWrapperGeneration | Should -BeExactly 'generation-initial'
        Should -Invoke Get-PaneControlManifestGenerationId -Times 0 -Exactly
    }

    It 'TASK781 C19 threads the generation captured with the path context into the setter' {
        $script:capturedWrapperGeneration = ''
        Mock Get-PaneControlManifestContext {
            [pscustomobject]@{
                ManifestPath = 'C:\repo\.winsmux\manifest.yaml'
                GenerationId = 'generation-initial'
            }
        }
        Mock Get-PaneControlManifestGenerationId { 'generation-replacement' }
        Mock Set-PaneControlManifestPaneProperties {
            param($ManifestPath, $PaneId, $Properties, $ExpectedGenerationId)
            $script:capturedWrapperGeneration = [string]$ExpectedGenerationId
        }

        Set-PaneControlManifestPanePaths -ProjectDir 'C:\repo' -PaneId '%2' `
            -LaunchDir 'C:\repo\.worktrees\builder-9'

        $script:capturedWrapperGeneration | Should -BeExactly 'generation-initial'
        Should -Invoke Get-PaneControlManifestGenerationId -Times 0 -Exactly
    }

    It 'TASK781 C19 forbids generation recapture in manifest mutation callers' {
        $repoRoot = Split-Path -Parent $script:BridgeTestsRoot
        foreach ($relativePath in @(
            'scripts\winsmux-core.ps1',
            'winsmux-core\scripts\agent-monitor.ps1',
            'winsmux-core\scripts\builder-queue.ps1',
            'winsmux-core\scripts\operator-poll.ps1',
            'winsmux-core\scripts\pane-scaler.ps1'
        )) {
            $source = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw -Encoding UTF8
            $source | Should -Not -Match '\bGet-PaneControlManifestGenerationId\b' -Because "$relativePath must thread the generation captured with its manifest snapshot"
        }
    }

    It 'reads pane titles through the pane-control winsmux wrapper' {
        Mock Invoke-PaneControlWinsmux { @('ignored', 'builder-7') } -ParameterFilter {
            $Arguments.Count -eq 5 -and
            $Arguments[0] -eq 'display-message' -and
            $Arguments[1] -eq '-p' -and
            $Arguments[2] -eq '-t' -and
            $Arguments[3] -eq '%7' -and
            $Arguments[4] -eq '#{pane_title}'
        }

        $title = Get-PaneControlPaneTitle -PaneId '%7'

        $title | Should -Be 'builder-7'
        Should -Invoke Invoke-PaneControlWinsmux -Times 1 -Exactly
    }

    It 'keeps changed_files empty when the manifest stores an empty array' {
@'
version: 1
saved_at: '2026-04-09T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
panes:
  builder-1:
    pane_id: '%2'
    role: 'Builder'
    changed_file_count: '0'
    changed_files: '[]'
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $entries = @(Get-PaneControlManifestEntries -ProjectDir $script:paneControlTempRoot)

        $entries.Count | Should -Be 1
        $entries[0].ChangedFileCount | Should -Be 0
        $entries[0].ChangedFiles | Should -Be @()
    }

    It 'surfaces security_policy from the manifest entry' {
@'
version: 1
saved_at: '2026-04-09T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
panes:
  worker-1:
    pane_id: '%2'
    role: 'Worker'
    security_policy: '{\"mode\":\"blocklist\",\"allow_patterns\":[\"Invoke-Pester\"],\"block_patterns\":[\"git reset --hard\"]}'
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $entries = @(Get-PaneControlManifestEntries -ProjectDir $script:paneControlTempRoot)
        $entry = @($entries | Where-Object { $_.Label -eq 'worker-1' } | Select-Object -First 1)[0]

        $entry | Should -Not -BeNullOrEmpty
        $entry.SecurityPolicy.mode | Should -Be 'blocklist'
        @($entry.SecurityPolicy.allow_patterns) | Should -Be @('Invoke-Pester')
        @($entry.SecurityPolicy.block_patterns) | Should -Be @('git reset --hard')
    }

    It 'TASK781 C48 refuses a stale v2 manifest mutation before Save-WinsmuxManifest' {
        $manifestPath = Join-Path $script:paneControlManifestDir 'manifest.yaml'
        'synthetic v2 manifest' | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $manifest = [PSCustomObject]@{
            version = 2
            session = [PSCustomObject]@{ generation_id = 'generation-1' }
            panes = [ordered]@{
                'worker-1' = [ordered]@{
                    slot_id = 'worker-1'; pane_id = '%2'; worker_backend = 'codex'; worker_role = 'reviewer'
                    role = 'Reviewer'; title = 'W1 Codex Reviewer'; status = 'ready'
                }
            }
        }
        $entry = [PSCustomObject]@{
            Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; WorkerBackend = 'codex'
            WorkerRole = 'reviewer'; Role = 'Reviewer'; Title = 'W1 Codex Reviewer'; Status = 'ready'
        }
        Mock Get-WinsmuxManifest { $manifest }
        Mock Get-PaneControlManifestContext { $entry }
        Mock Test-PaneControlRuntimeContext {
            New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'invalid_supervisor_identity' `
                -Diagnostic 'generation expired immediately before manifest save'
        }
        Mock Save-WinsmuxManifest { throw 'save must not run after lease expiry' }

        {
            Set-PaneControlManifestPaneProperties -ManifestPath $manifestPath -PaneId '%2' `
                -Properties ([ordered]@{ status = 'ready' }) -ExpectedGenerationId 'generation-1'
        } | Should -Throw '*invalid_supervisor_identity*generation expired immediately before manifest save*'

        Assert-MockCalled Save-WinsmuxManifest -Times 0 -Exactly
    }

    It 'TASK781 C48 requires a captured generation for every v2 manifest mutation' {
        $manifestPath = Join-Path $script:paneControlManifestDir 'manifest.yaml'
        'synthetic v2 manifest' | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $manifest = [PSCustomObject]@{
            version = 2
            session = [PSCustomObject]@{ generation_id = 'generation-1' }
            panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; status = 'ready' }
            }
        }
        Mock Get-WinsmuxManifest { $manifest }
        Mock Save-WinsmuxManifest { throw 'save must not run without a captured generation' }

        {
            Set-PaneControlManifestPaneProperties -ManifestPath $manifestPath -PaneId '%2' `
                -Properties ([ordered]@{ status = 'ready' })
        } | Should -Throw '*ExpectedGenerationId is required*'

        Assert-MockCalled Save-WinsmuxManifest -Times 0 -Exactly
    }

    It 'TASK781 C52 validates the captured v2 generation and live lease in the shared document save path' {
        $manifestPath = Join-Path $script:paneControlManifestDir 'manifest.yaml'
        'synthetic v2 manifest' | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $manifest = [PSCustomObject]@{
            version = 2
            session = [PSCustomObject]@{
                name = 'winsmux-orchestra'; generation_id = 'generation-52'; server_session_id = '$52'; bootstrap_pane_id = '%1'
            }
            panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; status = 'ready' }
            }
        }
        $entry = [PSCustomObject]@{
            Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; WorkerBackend = 'codex'; Status = 'ready'
        }
        Mock Get-WinsmuxManifest { $manifest }
        Mock Get-PaneControlManifestContext { $entry }
        Mock Test-PaneControlRuntimeContext {
            [PSCustomObject]@{
                valid = $true
                reason_code = 'runtime_valid'
                diagnostic = 'synthetic live lease'
                context = [PSCustomObject]@{ generation_id = 'generation-52' }
            }
        }
        Mock Save-WinsmuxManifest {}

        Save-PaneControlManifestDocument -ManifestPath $manifestPath -Manifest $manifest -ExpectedGenerationId 'generation-52'

        Assert-MockCalled Test-PaneControlRuntimeContext -Times 1 -Exactly -ParameterFilter {
            $ProjectDir -eq $script:paneControlTempRoot -and $ManifestEntry.PaneId -eq '%2'
        }
        Assert-MockCalled Save-WinsmuxManifest -Times 1 -Exactly
    }

    It 'TASK781 C57 refuses a guarded v2 document save after current manifest becomes <Case>' -ForEach @(
        @{ Case = 'v1'; CurrentManifest = [PSCustomObject]@{ version = 1; panes = [ordered]@{} } }
        @{ Case = 'unknown schema'; CurrentManifest = [PSCustomObject]@{ version = 99; panes = [ordered]@{} } }
        @{ Case = 'empty'; CurrentManifest = $null }
    ) {
        $manifestPath = Join-Path $script:paneControlManifestDir 'manifest.yaml'
        'synthetic manifest' | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $nextManifest = [PSCustomObject]@{
            version = 2
            session = [PSCustomObject]@{
                name = 'winsmux-orchestra'; generation_id = 'generation-57'; server_session_id = '$57'; bootstrap_pane_id = '%1'
            }
            panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; status = 'ready' }
            }
        }
        $script:c57CurrentManifest = $CurrentManifest
        Mock Get-WinsmuxManifest { $script:c57CurrentManifest }
        Mock Save-WinsmuxManifest { throw 'save must not run after a guarded v2 schema transition' }

        {
            Save-PaneControlManifestDocument -ManifestPath $manifestPath -Manifest $nextManifest `
                -ExpectedGenerationId 'generation-57'
        } | Should -Throw '*manifest_regeneration_required*'

        Assert-MockCalled Save-WinsmuxManifest -Times 0 -Exactly
    }

    It 'TASK781 C57 preserves an unguarded pure v1 document save' {
        $manifestPath = Join-Path $script:paneControlManifestDir 'manifest.yaml'
        'synthetic v1 manifest' | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $v1Manifest = [PSCustomObject]@{ version = 1; panes = [ordered]@{} }
        Mock Get-WinsmuxManifest { $v1Manifest }
        Mock Save-WinsmuxManifest {}

        Save-PaneControlManifestDocument -ManifestPath $manifestPath -Manifest $v1Manifest

        Assert-MockCalled Save-WinsmuxManifest -Times 1 -Exactly
    }

    It 'TASK781 C60 rejects a guarded v2 save when the locked document becomes <Case>' -ForEach @(
        @{ Case = 'v1'; ExpectedReason = 'manifest_regeneration_required' }
        @{ Case = 'unknown schema'; ExpectedReason = 'manifest_regeneration_required' }
        @{ Case = 'empty'; ExpectedReason = 'manifest_regeneration_required' }
        @{ Case = 'deleted'; ExpectedReason = 'manifest_regeneration_required' }
        @{ Case = 'another generation'; ExpectedReason = 'invalid_supervisor_identity' }
    ) {
        $current = [ordered]@{
            version = 2
            saved_at = '2026-07-15T19:40:00+09:00'
            session = [ordered]@{
                name = 'winsmux-orchestra'
                generation_id = 'generation-1'
                server_session_id = '$60'
                bootstrap_pane_id = '%1'
                expected_pane_count = 1
            }
            panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; slot_id = 'worker-1'; status = 'ready' }
            }
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        }
        Save-WinsmuxManifest -ProjectDir $script:paneControlTempRoot -Manifest $current
        $path = Get-ManifestPath -ProjectDir $script:paneControlTempRoot
        $next = ConvertFrom-ManifestYaml -Content (ConvertTo-ManifestYaml -Manifest $current)

        switch ($Case) {
            'v1' { $script:c60CompetingContent = "version: 1`nsession:`n  name: legacy`n" }
            'unknown schema' { $script:c60CompetingContent = "version: 99`nsession:`n  name: unknown`n" }
            'empty' { $script:c60CompetingContent = '' }
            'deleted' { $script:c60CompetingContent = $null }
            'another generation' {
                $competing = ConvertFrom-ManifestYaml -Content (ConvertTo-ManifestYaml -Manifest $current)
                $competing.session.generation_id = 'generation-competing'
                $script:c60CompetingContent = ConvertTo-ManifestYaml -Manifest $competing
            }
        }

        Mock Invoke-WinsmuxWithFileLock {
            param([string]$Path, [scriptblock]$Action)
            if ($null -eq $script:c60CompetingContent) {
                Remove-Item -LiteralPath $Path -Force
            } else {
                [System.IO.File]::WriteAllText($Path, [string]$script:c60CompetingContent, [System.Text.UTF8Encoding]::new($false))
            }
            & $Action
        }

        {
            Save-WinsmuxManifest -ProjectDir $script:paneControlTempRoot -Manifest $next `
                -ExpectedGenerationId 'generation-1'
        } | Should -Throw ('*' + $ExpectedReason + '*')

        if ($null -eq $script:c60CompetingContent) {
            Test-Path -LiteralPath $path | Should -BeFalse
        } else {
            [System.IO.File]::ReadAllText($path) | Should -Be ([string]$script:c60CompetingContent)
        }
    }

    It 'TASK781 C60 atomically saves a same-generation v2 document with an explicit guard' {
        $current = [ordered]@{
            version = 2
            saved_at = '2026-07-15T19:40:00+09:00'
            session = [ordered]@{
                name = 'winsmux-orchestra'
                generation_id = 'generation-1'
                server_session_id = '$60'
                bootstrap_pane_id = '%1'
                expected_pane_count = 1
            }
            panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; slot_id = 'worker-1'; status = 'ready' }
            }
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        }
        Save-WinsmuxManifest -ProjectDir $script:paneControlTempRoot -Manifest $current
        $next = ConvertFrom-ManifestYaml -Content (ConvertTo-ManifestYaml -Manifest $current)
        $next.saved_at = '2026-07-15T19:45:00+09:00'

        Save-WinsmuxManifest -ProjectDir $script:paneControlTempRoot -Manifest $next `
            -ExpectedGenerationId 'generation-1'

        (Get-WinsmuxManifest -ProjectDir $script:paneControlTempRoot).saved_at | Should -Be '2026-07-15T19:45:00+09:00'
    }

    It 'TASK781 C60 preserves an unguarded first-write v2 diagnostic document' {
        $diagnostic = [ordered]@{
            version = 2
            saved_at = '2026-07-15T19:46:00+09:00'
            session = [ordered]@{ name = 'diagnostic-only' }
            panes = [ordered]@{}
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        }

        Save-WinsmuxManifest -ProjectDir $script:paneControlTempRoot -Manifest $diagnostic

        $saved = Get-WinsmuxManifest -ProjectDir $script:paneControlTempRoot
        $saved.version | Should -Be 2
        $saved.session.name | Should -Be 'diagnostic-only'
    }

    It 'TASK781 C54 refuses a v2 whole-document save when no managed runtime pane exists' {
        $manifestPath = Join-Path $script:paneControlManifestDir 'manifest.yaml'
        'synthetic v2 manifest' | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $manifest = [PSCustomObject]@{
            version = 2
            session = [PSCustomObject]@{
                name = 'winsmux-orchestra'; generation_id = 'generation-54'; server_session_id = '$54'; bootstrap_pane_id = '%1'
            }
            panes = [ordered]@{}
        }
        Mock Get-WinsmuxManifest { $manifest }
        Mock Get-PaneControlManifestContext { throw 'bootstrap pane must not be selected as a managed runtime pane' }
        Mock Save-WinsmuxManifest { throw 'save must not run without a managed runtime pane' }

        {
            Save-PaneControlManifestDocument -ManifestPath $manifestPath -Manifest $manifest -ExpectedGenerationId 'generation-54'
        } | Should -Throw '*managed runtime pane*'

        Assert-MockCalled Get-PaneControlManifestContext -Times 0 -Exactly
        Assert-MockCalled Save-WinsmuxManifest -Times 0 -Exactly
    }

    It 'TASK781 C52 routes every production whole-document mutation caller through the guarded save path' {
        $repoRoot = Split-Path -Parent $script:BridgeTestsRoot
        foreach ($relativePath in @(
            'winsmux-core\scripts\orchestra-state.ps1',
            'winsmux-core\scripts\builder-queue.ps1',
            'winsmux-core\scripts\pane-scaler.ps1'
        )) {
            $content = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw -Encoding UTF8
            $content | Should -Match 'Save-PaneControlManifestDocument'
            $content | Should -Not -Match '(?m)^\s*Save-WinsmuxManifest\s'
        }
    }

}

Describe 'logger helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\logger.ps1')
        $script:clmSafeIoContent = Get-Content -Path (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\clm-safe-io.ps1') -Raw -Encoding UTF8
        $script:loggerPwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    }

    BeforeEach {
        $script:loggerTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-logger-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:loggerTempRoot -Force | Out-Null
    }

    AfterEach {
        if ($script:loggerTempRoot -and (Test-Path $script:loggerTempRoot)) {
            Remove-Item -Path $script:loggerTempRoot -Recurse -Force
        }
    }

    It 'resolves the orchestra log path under .winsmux logs' {
        $path = Get-OrchestraLogPath -ProjectDir $script:loggerTempRoot -SessionName 'winsmux-orchestra'
        $path | Should -Be (Join-Path $script:loggerTempRoot '.winsmux\logs\winsmux-orchestra.jsonl')
    }

    It 'initializes the log file and appends structured jsonl records' {
        $logPath = Initialize-OrchestraLogger -ProjectDir $script:loggerTempRoot -SessionName 'session-a'
        Test-Path $logPath | Should -Be $true

        $record = Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-a' -Event 'pane.started' -Message 'builder booted' -Role 'Builder' -PaneId '%2' -Target 'builder-1' -Data ([ordered]@{ agent = 'codex'; model = 'gpt-5.4' })
        $record.session | Should -Be 'session-a'
        $record.event | Should -Be 'pane.started'
        $record.role | Should -Be 'Builder'
        $record.data.agent | Should -Be 'codex'

        $lines = @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 1
        $parsed = $lines[0] | ConvertFrom-Json
        $parsed.message | Should -Be 'builder booted'
        $parsed.target | Should -Be 'builder-1'
        $parsed.data.model | Should -Be 'gpt-5.4'
    }

    It 'reads back structured log records in order' {
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-b' -Event 'session.started' -Data ([ordered]@{ panes = 3 }) | Out-Null
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-b' -Event 'review.failed' -Level 'warn' -Data ([ordered]@{ finding_count = 2 }) | Out-Null

        $records = Read-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-b'
        $records.Count | Should -Be 2
        $records[0].event | Should -Be 'session.started'
        $records[0].data.panes | Should -Be 3
        $records[1].level | Should -Be 'warn'
        $records[1].data.finding_count | Should -Be 2
    }

    It 'rotates before append and keeps retained records as valid jsonl' {
        $logPath = Initialize-OrchestraLogger -ProjectDir $script:loggerTempRoot -SessionName 'session-rotation'

        1..8 | ForEach-Object {
            Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-rotation' -Event 'rotation.boundary' -Message ('x' * 180) -Data ([ordered]@{ index = $_; payload = ('y' * 180) }) -MaxBytes 700 -RetentionCount 20 | Out-Null
        }

        $rotatedFiles = @(Get-OrchestraLogRotatedFiles -Path $logPath)
        ($rotatedFiles.Count -gt 0) | Should -Be $true
        ((Get-Item -LiteralPath $logPath).Length -le 700) | Should -Be $true

        $allRecords = @()
        $allPaths = @($rotatedFiles | Sort-Object Name | ForEach-Object { $_.FullName }) + @($logPath)
        foreach ($path in $allPaths) {
            foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                $allRecords += ($line | ConvertFrom-Json -ErrorAction Stop)
            }
        }

        $allRecords.Count | Should -Be 8
        @($allRecords | Where-Object { $_.event -eq 'rotation.boundary' }).Count | Should -Be 8

        $readRecords = Read-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-rotation'
        $readRecords.Count | Should -Be 8
        @($readRecords | ForEach-Object { [int]$_.data.index }) | Should -Be @(1, 2, 3, 4, 5, 6, 7, 8)
    }

    It 'does not treat similarly named active session logs as rotations' {
        $baseSession = 'session-cross'
        $lookalikeSession = 'session-cross.rotated.20260707221249000.000000'
        $baseLogPath = Initialize-OrchestraLogger -ProjectDir $script:loggerTempRoot -SessionName $baseSession
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName $baseSession -Event 'base.tail' | Out-Null
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName $lookalikeSession -Event 'other.active' | Out-Null

        $lookalikeLogPath = Get-OrchestraLogPath -ProjectDir $script:loggerTempRoot -SessionName $lookalikeSession
        Invoke-OrchestraLogRetentionPrune -Path $baseLogPath -RetentionCount 0

        Test-Path -LiteralPath $lookalikeLogPath -PathType Leaf | Should -Be $true
        @(Get-OrchestraLogRotatedFiles -Path $baseLogPath | ForEach-Object { $_.FullName }) | Should -Not -Contain $lookalikeLogPath
        @(Read-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName $baseSession | ForEach-Object { $_.event }) | Should -Not -Contain 'other.active'
    }

    It 'preserves order for same-millisecond rotated logs' {
        $logPath = Initialize-OrchestraLogger -ProjectDir $script:loggerTempRoot -SessionName 'session-same-millisecond'
        $fixedTime = [datetime]'2026-07-07T22:12:49.000Z'
        $firstRotatedPath = New-OrchestraLogRotatedPath -Path $logPath -Now $fixedTime
        '{"event":"rotated.first","data":{"index":1}}' | Set-Content -Path $firstRotatedPath -Encoding UTF8
        $secondRotatedPath = New-OrchestraLogRotatedPath -Path $logPath -Now $fixedTime
        '{"event":"rotated.second","data":{"index":2}}' | Set-Content -Path $secondRotatedPath -Encoding UTF8
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-same-millisecond' -Event 'active.tail' -Data ([ordered]@{ index = 3 }) | Out-Null

        $records = Read-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-same-millisecond'
        @($records | ForEach-Object { [int]$_.data.index }) | Should -Be @(1, 2, 3)
    }

    It 'reads rotated and active logs under the writer file lock' {
        $logPath = Initialize-OrchestraLogger -ProjectDir $script:loggerTempRoot -SessionName 'session-read-lock'
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-read-lock' -Event 'read.locked' | Out-Null
        $script:readLockPath = $null
        Mock Invoke-WinsmuxWithFileLock {
            param(
                [string]$Path,
                [scriptblock]$Action
            )

            $script:readLockPath = $Path
            & $Action
        }

        $records = Read-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-read-lock'

        $records.Count | Should -Be 1
        $records[0].event | Should -Be 'read.locked'
        $script:readLockPath | Should -Be $logPath
        Assert-MockCalled Invoke-WinsmuxWithFileLock -Times 1 -Exactly
    }

    It 'skips rotated logs pruned between enumeration and read' {
        $logPath = Initialize-OrchestraLogger -ProjectDir $script:loggerTempRoot -SessionName 'session-read-pruned'
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-read-pruned' -Event 'read.tail' -Data ([ordered]@{ index = 2 }) | Out-Null

        $missingRotatedPath = New-OrchestraLogRotatedPath -Path $logPath -Now (Get-Date).AddSeconds(-1)
        '{"event":"read.rotated","data":{"index":1}}' | Set-Content -Path $missingRotatedPath -Encoding UTF8
        $missingRotatedFile = Get-Item -LiteralPath $missingRotatedPath
        Remove-Item -LiteralPath $missingRotatedPath -Force
        Mock Get-OrchestraLogRotatedFiles { @($missingRotatedFile) }

        $records = Read-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-read-pruned'
        $records.Count | Should -Be 1
        $records[0].event | Should -Be 'read.tail'
    }

    It 'prunes rotated logs to the configured retention count' {
        $logPath = Initialize-OrchestraLogger -ProjectDir $script:loggerTempRoot -SessionName 'session-retention'

        1..10 | ForEach-Object {
            Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-retention' -Event 'rotation.retention' -Message ('r' * 180) -Data ([ordered]@{ index = $_; payload = ('s' * 180) }) -MaxBytes 700 -RetentionCount 1 | Out-Null
        }

        $rotatedFiles = @(Get-OrchestraLogRotatedFiles -Path $logPath)
        $rotatedFiles.Count | Should -Be 1
        Test-Path -LiteralPath $logPath -PathType Leaf | Should -Be $true
    }

    It 'does not truncate an active log created while initialization waits for the file lock' {
        $logPath = Get-OrchestraLogPath -ProjectDir $script:loggerTempRoot -SessionName 'session-init-race'
        $logDir = Split-Path -Parent $logPath
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null

        $lockDir = Get-WinsmuxFileLockDir -Path $logPath
        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null

        $workerScriptPath = Join-Path $script:loggerTempRoot 'init-worker.ps1'
        $loggerPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\logger.ps1'
        $workerScript = (@'
param(
    [Parameter(Mandatory = $true)][string]$ProjectDir
)

. '{0}'
Initialize-OrchestraLogger -ProjectDir $ProjectDir -SessionName 'session-init-race' | Out-Null
'@) -f ($loggerPath -replace "'", "''")

        Set-Content -Path $workerScriptPath -Value $workerScript -Encoding UTF8
        $process = Start-Process -FilePath $script:loggerPwshPath -ArgumentList @('-NoProfile', '-File', $workerScriptPath, '-ProjectDir', $script:loggerTempRoot) -PassThru -WindowStyle Hidden

        Start-Sleep -Milliseconds 500
        Set-Content -Path $logPath -Value 'preserve-this-line' -Encoding UTF8
        Remove-WinsmuxFileLock -Path $logPath

        $process.WaitForExit(180000) | Should -Be $true
        $process.ExitCode | Should -Be 0

        $lines = @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be 'preserve-this-line'
    }

    It 'appends to the active log when rotation rename is blocked by a reader' {
        $logPath = Initialize-OrchestraLogger -ProjectDir $script:loggerTempRoot -SessionName 'session-rename-blocked'
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-rename-blocked' -Event 'rotation.seed' -Message ('a' * 180) -Data ([ordered]@{ index = 1 }) -MaxBytes 1000 | Out-Null

        $stream = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-rename-blocked' -Event 'rotation.rename_blocked' -Message ('b' * 180) -Data ([ordered]@{ index = 2 }) -MaxBytes 100 -RetentionCount 1 | Out-Null
        } finally {
            $stream.Dispose()
        }

        $records = Read-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-rename-blocked'
        $records.Count | Should -Be 2
        $records[1].event | Should -Be 'rotation.rename_blocked'
        @(Get-OrchestraLogRotatedFiles -Path $logPath).Count | Should -Be 0
    }

    It 'keeps the current record when retention pruning cannot delete a rotated log' {
        $logPath = Initialize-OrchestraLogger -ProjectDir $script:loggerTempRoot -SessionName 'session-prune-blocked'
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-prune-blocked' -Event 'rotation.seed' -Message ('c' * 180) -Data ([ordered]@{ index = 1 }) -MaxBytes 1000 | Out-Null

        $lockedRotatedPath = New-OrchestraLogRotatedPath -Path $logPath -Now (Get-Date).AddSeconds(-1)
        '{"event":"locked"}' | Set-Content -Path $lockedRotatedPath -Encoding UTF8
        $stream = [System.IO.File]::Open($lockedRotatedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-prune-blocked' -Event 'rotation.prune_blocked' -Message ('d' * 180) -Data ([ordered]@{ index = 2 }) -MaxBytes 100 -RetentionCount 0 | Out-Null
        } finally {
            $stream.Dispose()
        }

        $records = Read-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-prune-blocked'
        ($records.Count -ge 2) | Should -Be $true
        $records[-1].event | Should -Be 'rotation.prune_blocked'
    }

    It 'serializes concurrent jsonl appends across multiple PowerShell processes' {
        $logPath = Join-Path $script:loggerTempRoot '.winsmux\logs\concurrent.jsonl'
        $workerScriptPath = Join-Path $script:loggerTempRoot 'append-worker.ps1'
        $clmSafeIoPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\clm-safe-io.ps1'
        $workerScript = (@'
param(
    [Parameter(Mandatory = $true)][string]$TargetPath,
    [Parameter(Mandatory = $true)][int]$WorkerId
)

. '{0}'

1..20 | ForEach-Object {{
    Write-WinsmuxTextFile -Path $TargetPath -Content ("worker=$WorkerId seq=$_") -Append
}}
'@) -f ($clmSafeIoPath -replace "'", "''")

        Set-Content -Path $workerScriptPath -Value $workerScript -Encoding UTF8

        $processes = 1..3 | ForEach-Object {
            Start-Process -FilePath $script:loggerPwshPath -ArgumentList @('-NoProfile', '-File', $workerScriptPath, '-TargetPath', $logPath, '-WorkerId', $_) -PassThru -WindowStyle Hidden
        }

        foreach ($process in $processes) {
            $process.WaitForExit(180000) | Should -Be $true
            $process.ExitCode | Should -Be 0
        }

        $lines = @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 60
        @($lines | Select-Object -Unique).Count | Should -Be 60
    }

    It 'reclaims stale file locks left by dead processes' {
        $logPath = Join-Path $script:loggerTempRoot '.winsmux\logs\stale.jsonl'
        $lockDir = "$logPath.lock"
        $metadataPath = Join-Path $lockDir 'owner.json'

        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
        @"
{"pid":999999,"started_at":"2000-01-01T00:00:00Z"}
"@ | Set-Content -Path $metadataPath -Encoding UTF8

        Write-WinsmuxTextFile -Path $logPath -Content 'stale-lock-recovered' -Append

        $lines = @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be 'stale-lock-recovered'
        (Test-Path -LiteralPath $lockDir -PathType Container) | Should -Be $false
    }

    It 'reclaims file locks when the owner pid has been reused by a different process instance' {
        $logPath = Join-Path $script:loggerTempRoot '.winsmux\logs\pid-reuse.jsonl'
        $lockDir = "$logPath.lock"
        $metadataPath = Join-Path $lockDir 'owner.json'

        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
        @"
{"pid":$PID,"started_at":"2000-01-01T00:00:00Z","process_started_at":"2000-01-01T00:00:00Z"}
"@ | Set-Content -Path $metadataPath -Encoding UTF8

        Write-WinsmuxTextFile -Path $logPath -Content 'pid-reuse-recovered' -Append

        $lines = @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be 'pid-reuse-recovered'
        (Test-Path -LiteralPath $lockDir -PathType Container) | Should -Be $false
    }

    It 'treats live file locks with malformed owner start time as stale' {
        $logPath = Join-Path $script:loggerTempRoot '.winsmux\logs\live-unverified.jsonl'
        $lockDir = "$logPath.lock"
        $metadataPath = Join-Path $lockDir 'owner.json'

        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
        @"
{"pid":$PID,"started_at":"2000-01-01T00:00:00Z","process_started_at":"not-a-date"}
"@ | Set-Content -Path $metadataPath -Encoding UTF8

        Test-WinsmuxFileLockStale -Path $logPath -StaleAfterSeconds 0 | Should -Be $true
    }

    It 'keeps CLM-safe writes on cmd-based lock and replace primitives' {
        $script:clmSafeIoContent | Should -Match 'function Get-WinsmuxFileLockDir'
        $script:clmSafeIoContent | Should -Match 'function Test-WinsmuxFileLockStale'
        $script:clmSafeIoContent | Should -Match 'function Get-WinsmuxProcessStartedAt'
        $script:clmSafeIoContent | Should -Match 'cmd /d /c \(''mkdir'
        $script:clmSafeIoContent | Should -Match 'cmd /d /c \(''move /y'
        $script:clmSafeIoContent | Should -Match 'owner\.json'
        $script:clmSafeIoContent | Should -Match 'process_started_at'
        $script:clmSafeIoContent | Should -Not -Match 'System\.Threading\.Mutex'
        $script:clmSafeIoContent | Should -Not -Match 'System\.IO\.File'
        $script:clmSafeIoContent | Should -Not -Match 'StreamWriter'
    }
}
