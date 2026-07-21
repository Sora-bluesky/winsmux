$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:RepoRoot 'winsmux-core/scripts/workspace-recipe.ps1')
    $script:FixturePath = Join-Path $script:RepoRoot 'tests/fixtures/workspace-recipes/valid-v1.yaml'
    $script:ExpectedPath = Join-Path $script:RepoRoot 'tests/fixtures/workspace-recipes/valid-v1.normalized.json'
    $script:Catalog = [ordered]@{
        'worker-1' = [ordered]@{
            supports_file_edit = $true
            supports_verification = $false
            supports_structured_result = $true
        }
        'reviewer-1' = [ordered]@{
            supports_file_edit = $false
            supports_verification = $true
            supports_structured_result = $true
        }
    }

    function script:Get-TestWorkspaceRecipeDocument {
        Read-WorkspaceRecipeDocument -Path $script:FixturePath
    }

    function script:Copy-TestWorkspaceRecipeDocument {
        param([Parameter(Mandatory = $true)]$Document)
        return (($Document | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json -Depth 100 -AsHashtable)
    }

    function script:Invoke-TestWorkspaceRecipePlan {
        param(
            [Parameter(Mandatory = $true)]$Document,
            $SlotCatalog = $script:Catalog,
            [string]$WorkflowId = 'issue-1204'
        )
        New-WorkspaceRecipePlan -Document $Document -RecipeId 'bugfix-two-slot' `
            -WorkflowId $WorkflowId -SlotCatalog $SlotCatalog
    }
}

Describe 'TASK-658 workspace recipe pure contract' {
    It 'R01 leaves legacy documents without Lane A unselected' {
        $legacy = [ordered]@{ provider = 'codex'; 'agent-slots' = @() }
        { New-WorkspaceRecipePlan -Document $legacy -RecipeId 'anything' -SlotCatalog @{} } |
            Should -Throw '*was not found*'
        ($legacy | ConvertTo-Json -Compress) | Should -Be '{"provider":"codex","agent-slots":[]}'
    }

    It 'rejects the non-canonical workspace_recipes snake-case namespace' {
        $document = Get-TestWorkspaceRecipeDocument
        $document['workspace_recipes'] = $document['workspace-recipes']
        $document.Remove('workspace-recipes')
        { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw '*was not found*'
    }

    It 'rejects non-canonical case for namespace, recipe key, and field names with ordinal lookup' {
        $canonical = Get-TestWorkspaceRecipeDocument
        $document = [ordered]@{
            'Workspace-Recipes' = $canonical['workspace-recipes']
        }
        { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw

        $canonical = Get-TestWorkspaceRecipeDocument
        $document = [ordered]@{
            'workspace-recipes' = [ordered]@{
                'Bugfix-two-slot' = $canonical['workspace-recipes']['bugfix-two-slot']
            }
        }
        { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw

        $document = Get-TestWorkspaceRecipeDocument
        $canonicalPane = $document['workspace-recipes']['bugfix-two-slot'].panes[0]
        $nonCanonicalPane = [ordered]@{}
        foreach ($key in $canonicalPane.Keys) {
            $outputKey = if ($key -ceq 'workflow-role') { 'Workflow-Role' } else { $key }
            $nonCanonicalPane.Add($outputKey, $canonicalPane[$key])
        }
        $document['workspace-recipes']['bugfix-two-slot'].panes[0] = $nonCanonicalPane
        { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw

        $dictionary = [ordered]@{ 'Workflow-Role' = 'implementer' }
        Get-WorkspaceRecipeProperty $dictionary 'workflow-role' | Should -BeNullOrEmpty

        $object = [pscustomobject]@{ 'Workflow-Role' = 'implementer' }
        Get-WorkspaceRecipeProperty $object 'workflow-role' | Should -BeNullOrEmpty
    }

    It 'R02/R03 emits the byte-stable golden plan for literal and selector bindings' {
        $document = Get-TestWorkspaceRecipeDocument
        $first = ConvertTo-WorkspaceRecipePlanJson (Invoke-TestWorkspaceRecipePlan $document)
        $second = ConvertTo-WorkspaceRecipePlanJson (Invoke-TestWorkspaceRecipePlan $document)
        $expected = (Get-Content -Raw -LiteralPath $script:ExpectedPath -Encoding UTF8).Trim()
        $first | Should -BeExactly $expected
        $second | Should -BeExactly $expected
    }

    It 'R04 rejects a selector that matches zero slots' {
        $catalog = Copy-TestWorkspaceRecipeDocument $script:Catalog
        $catalog['reviewer-1'].supports_structured_result = $false
        { Invoke-TestWorkspaceRecipePlan (Get-TestWorkspaceRecipeDocument) $catalog } |
            Should -Throw '*matched zero slots*'
    }

    It 'R05 rejects a selector that matches multiple slots' {
        $catalog = Copy-TestWorkspaceRecipeDocument $script:Catalog
        $catalog['worker-1'].supports_verification = $true
        { Invoke-TestWorkspaceRecipePlan (Get-TestWorkspaceRecipeDocument) $catalog } |
            Should -Throw '*ambiguous (2 matches)*'
    }

    It 'R06 rejects missing and duplicate pane keys and action ids' -ForEach @(
        @{ Case = 'missing pane'; Change = { param($r) $r.panes[0].Remove('pane-key') }; Error = '*missing required field*' },
        @{ Case = 'duplicate pane'; Change = { param($r) $r.panes[1]['pane-key'] = 'implement' }; Error = '*Duplicate pane-key*' },
        @{ Case = 'missing action'; Change = { param($r) $r['startup-actions'][0].Remove('action-id') }; Error = '*missing required field*' },
        @{ Case = 'duplicate action'; Change = { param($r) $r['startup-actions'][1]['action-id'] = 'prepare-implement-worktree' }; Error = '*Duplicate action-id*' }
    ) {
        $document = Get-TestWorkspaceRecipeDocument
        $recipe = $document['workspace-recipes']['bugfix-two-slot']
        & $Change $recipe
        { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw $Error
    }

    It 'allows multiple panes to share one placement region' {
        $document = Get-TestWorkspaceRecipeDocument
        $document['workspace-recipes']['bugfix-two-slot'].panes[1].region = 'main'
        $plan = Invoke-TestWorkspaceRecipePlan $document
        @($plan.panes | Where-Object region -EQ 'main').Count | Should -Be 2
    }

    It 'rejects an empty panes sequence and an empty selector capability set' {
        $document = Get-TestWorkspaceRecipeDocument
        $document['workspace-recipes']['bugfix-two-slot'].panes = @()
        { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw '*must not be empty*'

        $document = Get-TestWorkspaceRecipeDocument
        $document['workspace-recipes']['bugfix-two-slot'].panes[1]['slot-selector']['requires-capabilities'] = @()
        { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw '*requires at least one capability*'
    }

    It 'R07 rejects unknown startup action kinds and fields without echoing their values' -ForEach @(
        @{ Field = 'kind'; Value = 'run-shell'; Error = '*unknown kind*' },
        @{ Field = 'shell'; Value = 'synthetic-private-command-value'; Error = '*unknown field*' }
    ) {
        $document = Get-TestWorkspaceRecipeDocument
        $action = $document['workspace-recipes']['bugfix-two-slot']['startup-actions'][0]
        $action[$Field] = $Value
        $message = ''
        try { $null = Invoke-TestWorkspaceRecipePlan $document } catch { $message = $_.Exception.Message }
        $message | Should -BeLike $Error
        $message | Should -Not -Match ([Regex]::Escape($Value))
    }

    It 'R08 rejects a missing pane-ref and a reference to an unknown pane' -ForEach @(
        @{ Missing = $true; Value = $null; Error = '*missing required field*' },
        @{ Missing = $false; Value = 'absent-pane'; Error = '*references unknown pane*' }
    ) {
        $document = Get-TestWorkspaceRecipeDocument
        $action = $document['workspace-recipes']['bugfix-two-slot']['startup-actions'][0]
        if ($Missing) { $action.Remove('pane-ref') } else { $action['pane-ref'] = $Value }
        { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw $Error
    }

    It 'R08 rejects a literal reference to a missing slot' {
        $document = Get-TestWorkspaceRecipeDocument
        $document['workspace-recipes']['bugfix-two-slot'].panes[0]['slot-ref'] = 'missing-slot'
        { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw '*references missing slot*'
    }

    It 'rejects ensure-managed-worktree for a read-only-reference pane while allowing ensure-slot-ready' {
        $document = Get-TestWorkspaceRecipeDocument
        $document['workspace-recipes']['bugfix-two-slot']['startup-actions'][0]['pane-ref'] = 'verify'
        { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw '*requires a managed-worktree pane*'

        $document = Get-TestWorkspaceRecipeDocument
        $plan = Invoke-TestWorkspaceRecipePlan $document
        $readyAction = $plan.startup_actions | Where-Object kind -CEQ 'ensure-slot-ready'
        $readyAction.pane_ref | Should -BeExactly 'verify'
        ($plan.panes | Where-Object pane_key -CEQ 'verify').worktree.mode |
            Should -BeExactly 'read-only-reference'
    }

    It 'R09 rejects path escapes, rooted paths, private paths, separators, and unknown tokens' -ForEach @(
        @{ UnsafeName = '../escape' }, @{ UnsafeName = '..\\escape' }, @{ UnsafeName = 'C:\private\repo' },
        @{ UnsafeName = '\\server\share' }, @{ UnsafeName = '/private/path' }, @{ UnsafeName = 'nested/name' },
        @{ UnsafeName = 'nested\\name' }, @{ UnsafeName = '{{recipe-id}}-worktree' }, @{ UnsafeName = 'safe..escape' }
    ) {
        $document = Get-TestWorkspaceRecipeDocument
        $document['workspace-recipes']['bugfix-two-slot'].panes[0].worktree['name-template'] = $UnsafeName
        $message = ''
        try { $null = Invoke-TestWorkspaceRecipePlan $document } catch { $message = $_.Exception.Message }
        $message | Should -Not -BeNullOrEmpty
        $message | Should -Not -Match ([Regex]::Escape($UnsafeName))
    }

    It 'rejects a workflow token when workflow id is omitted' {
        { Invoke-TestWorkspaceRecipePlan (Get-TestWorkspaceRecipeDocument) -WorkflowId $null } |
            Should -Throw '*requires an explicit workflow id*'
    }

    It 'R10 rejects a literal slot without every required capability' {
        $catalog = Copy-TestWorkspaceRecipeDocument $script:Catalog
        $catalog['worker-1'].supports_file_edit = $false
        { Invoke-TestWorkspaceRecipePlan (Get-TestWorkspaceRecipeDocument) $catalog } |
            Should -Throw '*lacks capability*'
    }

    It 'requires both verification and structured-result support for review' {
        $catalog = Copy-TestWorkspaceRecipeDocument $script:Catalog
        $catalog['reviewer-1'].supports_structured_result = $false
        { Invoke-TestWorkspaceRecipePlan (Get-TestWorkspaceRecipeDocument) $catalog } |
            Should -Throw '*matched zero slots*'
    }

    It 'rejects unknown capabilities and mutually present binding forms' {
        $document = Get-TestWorkspaceRecipeDocument
        $document['workspace-recipes']['bugfix-two-slot'].panes[0]['requires-capabilities'] = @('network-admin')
        { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw '*unknown capability*'

        $document = Get-TestWorkspaceRecipeDocument
        $document['workspace-recipes']['bugfix-two-slot'].panes[0]['slot-selector'] = @{
            'requires-capabilities' = @('file-edit')
        }
        { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw '*exactly one*'
    }

    It 'R11 preserves Lane B and unknown top-level fields without copying them into the plan' {
        $document = Get-TestWorkspaceRecipeDocument
        $before = $document | ConvertTo-Json -Depth 100 -Compress
        $json = ConvertTo-WorkspaceRecipePlanJson (Invoke-TestWorkspaceRecipePlan $document)
        ($document | ConvertTo-Json -Depth 100 -Compress) | Should -BeExactly $before
        $document['team-profile']['future-lane-b-field'] | Should -BeExactly 'preserve-me'
        $document['future-top-level'].owner | Should -BeExactly 'future'
        $json | Should -Not -Match 'team-profile|agent-slots|future-top-level|provider'
    }

    It 'R12 emits no timestamps and produces identical bytes on repeat' {
        $document = Get-TestWorkspaceRecipeDocument
        $one = ConvertTo-WorkspaceRecipePlanJson (Invoke-TestWorkspaceRecipePlan $document)
        $two = ConvertTo-WorkspaceRecipePlanJson (Invoke-TestWorkspaceRecipePlan $document)
        $one | Should -BeExactly $two
        $one | Should -Not -Match 'timestamp|generated|created|[A-Z]:\\|/Users/'
    }

    It 'R13 rejects a synthetic private path without disclosing it' {
        $privateValue = 'C:\Users\synthetic-private\secret-worktree'
        $document = Get-TestWorkspaceRecipeDocument
        $document['workspace-recipes']['bugfix-two-slot'].panes[0].worktree['name-template'] = $privateValue
        $message = ''
        try { $null = Invoke-TestWorkspaceRecipePlan $document } catch { $message = $_.Exception.Message }
        $message | Should -Not -BeNullOrEmpty
        $message | Should -Not -Match ([Regex]::Escape($privateValue))
    }

    It 'R13 rejects credential-shaped output identities without disclosing them' -ForEach @(
        @{ Case = 'workflow role'; Change = {
                param($Document, $Credential)
                $Document['workspace-recipes']['bugfix-two-slot'].panes[0]['workflow-role'] = $Credential
            }
        },
        @{ Case = 'action id'; Change = {
                param($Document, $Credential)
                $Document['workspace-recipes']['bugfix-two-slot']['startup-actions'][0]['action-id'] = $Credential
            }
        },
        @{ Case = 'resolved managed-worktree name'; Change = {
                param($Document, $Credential)
                $Document['workspace-recipes']['bugfix-two-slot'].panes[0].worktree['name-template'] = $Credential
            }
        }
    ) {
        $credential = 'sk-proj-' + ('a' * 32)
        $document = Get-TestWorkspaceRecipeDocument
        & $Change $document $credential
        $message = ''
        try { $null = Invoke-TestWorkspaceRecipePlan $document } catch { $message = $_.Exception.Message }
        $message | Should -Not -BeNullOrEmpty
        $message | Should -Not -Match ([Regex]::Escape($credential))
    }

    It 'keeps the credential-shaped boundary finite' {
        $nearBoundary = 'sk-' + ('a' * 19)
        $document = Get-TestWorkspaceRecipeDocument
        $document['workspace-recipes']['bugfix-two-slot'].panes[0]['workflow-role'] = $nearBoundary
        (Invoke-TestWorkspaceRecipePlan $document).panes[0].workflow_role |
            Should -BeExactly $nearBoundary
    }

    It 'R14 validates the whole recipe before any observable mutation' {
        $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-task658-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $scratch | Out-Null
        try {
            $before = @(Get-ChildItem -Force -LiteralPath $scratch).Count
            $document = Get-TestWorkspaceRecipeDocument
            $document['workspace-recipes']['bugfix-two-slot']['startup-actions'][1].kind = 'late-invalid-action'
            { Invoke-TestWorkspaceRecipePlan $document } | Should -Throw '*unknown kind*'
            @(Get-ChildItem -Force -LiteralPath $scratch).Count | Should -Be $before
        } finally {
            Remove-Item -LiteralPath $scratch -Recurse -Force
        }
    }
}
