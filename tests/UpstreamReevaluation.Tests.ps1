$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = (& git rev-parse --show-toplevel | Out-String).Trim()
    $script:ReevaluationScript = Join-Path $script:RepoRoot 'scripts/upstream-reevaluation.ps1'
}

Describe 'Upstream reevaluation gate' {
    BeforeEach {
        $script:ProjectDir = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-upstream-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Force -Path $script:ProjectDir | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:ProjectDir) {
            Remove-Item -LiteralPath $script:ProjectDir -Recurse -Force
        }
    }

    It 'collects source sets into the ignored local evolution cache' {
        $json = & $script:ReevaluationScript collect `
            -ProjectDir $script:ProjectDir `
            -RecordId 'case-collect' `
            -SourceType official-docs `
            -Source 'https://example.test/llms.txt' `
            -Json
        $result = $json | ConvertFrom-Json

        $result.command | Should -Be 'collect'
        $result.human_merge_required | Should -BeTrue
        @($result.sources) | Should -Be @('https://example.test/llms.txt')
        Test-Path -LiteralPath $result.source_set_path | Should -BeTrue
        Test-Path -LiteralPath $result.ledger_path | Should -BeTrue
        $result.cache_root | Should -Match '\\.winsmux\\evolution$'
    }

    It 'generates distinct default record ids for repeated source collection' {
        $firstJson = & $script:ReevaluationScript collect `
            -ProjectDir $script:ProjectDir `
            -SourceType official-docs `
            -Source 'https://example.test/first' `
            -Json
        $secondJson = & $script:ReevaluationScript collect `
            -ProjectDir $script:ProjectDir `
            -SourceType official-docs `
            -Source 'https://example.test/second' `
            -Json

        $first = $firstJson | ConvertFrom-Json
        $second = $secondJson | ConvertFrom-Json

        $first.record_id | Should -Not -Be $second.record_id
        Test-Path -LiteralPath $first.source_set_path | Should -BeTrue
        Test-Path -LiteralPath $second.source_set_path | Should -BeTrue
    }

    It 'records every TASK-315 command verb in the same ledger' {
        & $script:ReevaluationScript collect -ProjectDir $script:ProjectDir -RecordId 'verb-collect' -SourceType release-notes -Source 'https://example.test/releases' | Out-Null
        & $script:ReevaluationScript summarize -ProjectDir $script:ProjectDir -RecordId 'verb-summarize' -SourceType release-notes -Source 'https://example.test/releases' -Notes 'summarized public release-note structure' | Out-Null
        & $script:ReevaluationScript assess -ProjectDir $script:ProjectDir -RecordId 'verb-assess' -AcceptedPattern 'normalized verification evidence' -RejectedPattern 'generic persona prompt body' | Out-Null
        & $script:ReevaluationScript prune -ProjectDir $script:ProjectDir -RecordId 'verb-prune' -RejectedPattern 'prompt-only approval semantics' | Out-Null
        & $script:ReevaluationScript plan -ProjectDir $script:ProjectDir -RecordId 'verb-plan' -Task 'TASK-315' -Issue '#460' | Out-Null
        & $script:ReevaluationScript apply -ProjectDir $script:ProjectDir -RecordId 'verb-apply' -AcceptedPattern 'operator-owned final judgement' -LandingZone 'contributor-docs' -Task 'TASK-315' -Issue '#460' | Out-Null

        $ledgerPath = Join-Path (Join-Path (Join-Path $script:ProjectDir '.winsmux') 'evolution') 'reevaluation-records.jsonl'
        $records = Get-Content -LiteralPath $ledgerPath | ForEach-Object { $_ | ConvertFrom-Json }
        @($records | ForEach-Object { $_.command }) | Should -Be @('collect', 'summarize', 'assess', 'prune', 'plan', 'apply')
    }

    It 'requires task and issue evidence before applying accepted patterns' {
        {
            & $script:ReevaluationScript apply `
                -ProjectDir $script:ProjectDir `
                -RecordId 'bad-apply' `
                -AcceptedPattern 'operator-owned final judgement' `
                -LandingZone 'public-docs' `
                -Task 'TASK-315'
        } | Should -Throw
    }

    It 'records private maintainer assets without committing prompt bodies' {
        $json = & $script:ReevaluationScript apply `
            -ProjectDir $script:ProjectDir `
            -RecordId 'private-skill-apply' `
            -AcceptedPattern 'private opus-review-intake record shape' `
            -LandingZone 'private-maintainer-assets' `
            -Task 'TASK-366' `
            -Issue '#460' `
            -Json
        $result = $json | ConvertFrom-Json

        $result.landing_zone | Should -Be 'private-maintainer-assets'
        @($result.tasks) | Should -Be @('TASK-366')
        Test-Path -LiteralPath (Join-Path $script:ProjectDir 'skills') | Should -BeFalse
    }

    It 'rejects unsupported private prompt sources as public reevaluation input' {
        {
            & $script:ReevaluationScript collect `
                -ProjectDir $script:ProjectDir `
                -RecordId 'bad-source' `
                -SourceType private-prompt `
                -Source 'maintainer-only prompt'
        } | Should -Throw
    }
}
