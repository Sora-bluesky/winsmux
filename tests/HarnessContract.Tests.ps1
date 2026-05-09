$ErrorActionPreference = 'Stop'

Describe 'harness-check contract' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:HarnessCheckPath = Join-Path $script:RepoRoot 'winsmux-core\scripts\harness-check.ps1'
        $script:ShadowCutoverGatePath = Join-Path $script:RepoRoot 'winsmux-core\scripts\shadow-cutover-gate.ps1'
        $script:PowerShellDeescalationPath = Join-Path $script:RepoRoot 'winsmux-core\scripts\powershell-deescalation.ps1'
        $script:WinsmuxCorePath = Join-Path $script:RepoRoot 'scripts\winsmux-core.ps1'
        $script:InternalDocsMetaPath = Join-Path $script:RepoRoot 'winsmux-core\scripts\internal-docs-meta.psd1'
        $script:SettingsLocalPath = Join-Path $script:RepoRoot '.claude\settings.local.json'

        $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $pwshCommand) {
            throw 'pwsh was not found in PATH.'
        }

        $script:PwshPath = if ($pwshCommand.Path) { $pwshCommand.Path } else { $pwshCommand.Name }
        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $nodeCommand) {
            throw 'node was not found in PATH.'
        }

        $script:NodePath = if ($nodeCommand.Path) { $nodeCommand.Path } else { $nodeCommand.Name }

        function Write-TestFileWithCmd {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][string]$Content
            )

            $parent = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
        }

        function Remove-TestSettingsLocal {
            if (Test-Path -LiteralPath $script:SettingsLocalPath -PathType Leaf) {
                Remove-Item -LiteralPath $script:SettingsLocalPath -Force
            }

            & git -C $script:RepoRoot rm --cached --force --quiet -- '.claude/settings.local.json' 2>$null
            $null = $LASTEXITCODE
        }

        function Backup-TestFile {
            param([Parameter(Mandatory = $true)][string]$Path)

            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            }

            return $null
        }

        function Restore-TestFile {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [AllowNull()][string]$Content
            )

            if ($null -eq $Content) {
                if (Test-Path -LiteralPath $Path -PathType Leaf) {
                    Remove-Item -LiteralPath $Path -Force
                }
                return
            }

            Write-TestFileWithCmd -Path $Path -Content $Content
        }

        function Invoke-HarnessCheckJson {
            param([string[]]$Arguments)

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:PwshPath
            $startInfo.ArgumentList.Add('-NoProfile')
            $startInfo.ArgumentList.Add('-File')
            $startInfo.ArgumentList.Add($script:HarnessCheckPath)
            foreach ($argument in $Arguments) {
                $startInfo.ArgumentList.Add($argument)
            }
            $startInfo.WorkingDirectory = $script:RepoRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true

            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                $exitCode = $process.ExitCode
            } finally {
                $process.Dispose()
            }

            $trimmedStdout = $stdout.Trim()
            $parsed = $null
            if (-not [string]::IsNullOrWhiteSpace($trimmedStdout)) {
                $parsed = $trimmedStdout | ConvertFrom-Json -Depth 16
            }

            [PSCustomObject]@{
                ExitCode = $exitCode
                StdOut   = $trimmedStdout
                StdErr   = $stderr.Trim()
                Json     = $parsed
            }
        }

        function Invoke-NodeHookJson {
            param(
                [Parameter(Mandatory = $true)][string]$RepoRoot,
                [Parameter(Mandatory = $true)][string]$HookRelativePath,
                [Parameter(Mandatory = $true)][object]$Payload,
                [hashtable]$EnvironmentVariables = @{}
            )

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:NodePath
            $startInfo.ArgumentList.Add((Join-Path $RepoRoot $HookRelativePath))
            $startInfo.WorkingDirectory = $RepoRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($entry in $EnvironmentVariables.GetEnumerator()) {
                $startInfo.Environment[$entry.Key] = [string]$entry.Value
            }

            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $process.StandardInput.Write(($Payload | ConvertTo-Json -Compress -Depth 20))
                $process.StandardInput.Close()

                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()

                $parsed = $null
                if (-not [string]::IsNullOrWhiteSpace($stdout.Trim())) {
                    $parsed = $stdout | ConvertFrom-Json -Depth 20
                }

                [PSCustomObject]@{
                    ExitCode = $process.ExitCode
                    StdOut   = $stdout.Trim()
                    StdErr   = $stderr.Trim()
                    Json     = $parsed
                }
            } finally {
                $process.Dispose()
            }
        }

        function New-SessionStartFixture {
            $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-session-start-" + [guid]::NewGuid().ToString('N'))
            $hooksDir = Join-Path $fixtureRoot '.claude\hooks'
            $libDir = Join-Path $hooksDir 'lib'
            $patternsDir = Join-Path $fixtureRoot '.claude\patterns'
            $winsmuxDir = Join-Path $fixtureRoot '.winsmux'

            New-Item -ItemType Directory -Path $libDir -Force | Out-Null
            New-Item -ItemType Directory -Path $patternsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $winsmuxDir -Force | Out-Null

            Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.claude\hooks\sh-session-start.js') -Destination (Join-Path $hooksDir 'sh-session-start.js') -Force
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.claude\hooks\lib\sh-utils.js') -Destination (Join-Path $libDir 'sh-utils.js') -Force

            Write-TestFileWithCmd -Path (Join-Path $fixtureRoot 'CLAUDE.md') -Content '# Fixture'
            Write-TestFileWithCmd -Path (Join-Path $fixtureRoot '.claude\settings.json') -Content '{"permissions":{"deny":["backlog.yaml"]}}'
            Write-TestFileWithCmd -Path (Join-Path $patternsDir 'injection-patterns.json') -Content '{}'
            Write-TestFileWithCmd -Path (Join-Path $winsmuxDir 'manifest.yaml') -Content @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: '$fixtureRoot'
panes:
  builder-1:
    task_id: TASK-154
    task_state: in_progress
    task: Resume session context
"@

            $backlogPath = Join-Path $fixtureRoot 'backlog.yaml'
            Write-TestFileWithCmd -Path $backlogPath -Content @"
version: 3
tasks:
  - id: TASK-154
    title: Manifest-aware session resume / context injection
    status: active
    target_version: v0.24.1
"@

            return [PSCustomObject]@{
                Root        = $fixtureRoot
                BacklogPath = $backlogPath
            }
        }
    }

    It 'passes shadow cutover gate when only human-readable text changes' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-shadow-gate-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            $expectedPath = Join-Path $tempRoot 'expected.json'
            $actualPath = Join-Path $tempRoot 'actual.json'
            Write-TestFileWithCmd -Path $expectedPath -Content '{"operator_contract":{"operator_state":"ready","can_dispatch":true,"requires_startup":false,"operator_message":"ready","next_action":"dispatch"}}'
            Write-TestFileWithCmd -Path $actualPath -Content '{"operator_contract":{"operator_state":"ready","can_dispatch":true,"requires_startup":false,"operator_message":"ready now","next_action":"continue dispatch"}}'

            $output = & $script:PwshPath -NoProfile -File $script:ShadowCutoverGatePath -ExpectedPath $expectedPath -ActualPath $actualPath -Surface orchestra-smoke -AsJson
            $LASTEXITCODE | Should -Be 0
            $json = $output | ConvertFrom-Json
            $json.passed | Should -BeTrue
            $json.summary.allowed_differences | Should -Be 2
            $json.summary.blocking_differences | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails shadow cutover gate when a machine-readable field changes' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-shadow-gate-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            $expectedPath = Join-Path $tempRoot 'expected.json'
            $actualPath = Join-Path $tempRoot 'actual.json'
            Write-TestFileWithCmd -Path $expectedPath -Content '{"operator_contract":{"operator_state":"ready","can_dispatch":true,"requires_startup":false}}'
            Write-TestFileWithCmd -Path $actualPath -Content '{"operator_contract":{"operator_state":"ready","can_dispatch":false,"requires_startup":false}}'

            $output = & $script:PwshPath -NoProfile -File $script:ShadowCutoverGatePath -ExpectedPath $expectedPath -ActualPath $actualPath -Surface orchestra-smoke -AsJson
            $LASTEXITCODE | Should -Be 1
            $json = $output | ConvertFrom-Json
            $json.passed | Should -BeFalse
            $json.summary.blocking_differences | Should -Be 1
            $json.differences[0].path | Should -Be '$.operator_contract.can_dispatch'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'documents and dispatches the shadow cutover gate command' {
        $bridge = Get-Content -LiteralPath $script:WinsmuxCorePath -Raw -Encoding UTF8
        $bridge | Should -Match 'shadow-cutover-gate --expected <path> --actual <path> \[--surface <name>\] \[--json\]'
        $bridge | Should -Match "'shadow-cutover-gate'\s+\{"
        $bridge | Should -Match 'shadow-cutover-gate\.ps1'
    }

    It 'reports the PowerShell de-escalation contract as JSON' {
        $output = & $script:PwshPath -NoProfile -File $script:PowerShellDeescalationPath -AsJson
        $LASTEXITCODE | Should -Be 0
        $json = $output | ConvertFrom-Json
        $json.contract_version | Should -Be 1
        $json.allowed_roles | Should -Contain 'bootstrap'
        $json.allowed_roles | Should -Contain 'compatibility_launcher'
        $json.gates.shadow_gate_required | Should -BeTrue
        $json.gates.delete_without_shadow_gate | Should -BeFalse
        $json.shrink_order[0] | Should -Be 'typed_state_and_projection_contracts'
    }

    It 'documents and dispatches the PowerShell de-escalation contract command' {
        $bridge = Get-Content -LiteralPath $script:WinsmuxCorePath -Raw -Encoding UTF8
        $bridge | Should -Match 'powershell-deescalation \[--json\]'
        $bridge | Should -Match "'powershell-deescalation'\s+\{"
        $bridge | Should -Match 'powershell-deescalation\.ps1'
    }

    It 'documents and dispatches the Rust canary command' {
        $bridge = Get-Content -LiteralPath $script:WinsmuxCorePath -Raw -Encoding UTF8
        $bridge | Should -Match 'rust-canary \[--json\]'
        $bridge | Should -Match "'rust-canary'\s+\{"
        $bridge | Should -Match 'Invoke-WinsmuxRaw -Arguments \$rustArgs'
    }

    It 'documents and dispatches the manual checklist command' {
        $bridge = Get-Content -LiteralPath $script:WinsmuxCorePath -Raw -Encoding UTF8
        $bridge | Should -Match 'manual-checklist \[--json\]'
        $bridge | Should -Match "'manual-checklist'\s+\{"
        $bridge | Should -Match 'manual-checklist'
        $bridge | Should -Match 'Invoke-WinsmuxRaw -Arguments \$rustArgs'
    }

    It 'keeps the generated v1 manual checklist aligned with desktop release evidence' {
        $meta = Import-PowerShellDataFile -LiteralPath $script:InternalDocsMetaPath
        $entry = @($meta.ManualChecklistEntries | Where-Object { $_.Version -eq 'v1.0.0' })

        $entry.Count | Should -Be 1
        @($entry[0].TaskIds) | Should -Contain 'TASK-416'
        @($entry[0].TaskIds) | Should -Contain 'TASK-468'
        $entry[0].Focus | Should -Match 'デスクトップ'
        $entry[0].Example | Should -Match 'インストーラー'
        $entry[0].Example | Should -Match 'プロジェクト選択'
        $entry[0].Example | Should -Match '画像貼り付け'
        $entry[0].Example | Should -Match '音声入力'
        $entry[0].Memo | Should -Match 'TASK-416'
        $entry[0].Memo | Should -Match 'TASK-468'
    }

    It 'documents and dispatches the legacy compatibility gate command' {
        $bridge = Get-Content -LiteralPath $script:WinsmuxCorePath -Raw -Encoding UTF8
        $bridge | Should -Match 'legacy-compat-gate \[--json\]'
        $bridge | Should -Match "'legacy-compat-gate'\s+\{"
        $bridge | Should -Match 'legacy-compat-gate'
        $bridge | Should -Match 'Invoke-WinsmuxRaw -Arguments \$rustArgs'
    }

    BeforeEach {
        Remove-TestSettingsLocal
    }

    AfterEach {
        Remove-TestSettingsLocal
    }

    AfterAll {
        Remove-TestSettingsLocal
    }

    It 'passes against the current repository contract' {
        $result = Invoke-HarnessCheckJson -Arguments @('-ProjectDir', $script:RepoRoot, '-AsJson')

        $result.ExitCode | Should -Be 0
        $result.Json.passed | Should -Be $true
        ($result.Json.results | Where-Object { -not $_.passed }).Count | Should -Be 0
        @($result.Json.results.name) | Should -Contain 'visible-attach-host-adapters'
        @($result.Json.results.name) | Should -Contain 'attached-client-registry-contract'
        @($result.Json.results.name) | Should -Contain 'startup-attach-consistency'
    }

    It 'keeps critical .claude files trimmed to a single final newline' {
        foreach ($relativePath in @(
            '.claude\hooks\lib\sh-utils.js',
            '.claude\settings.json'
        )) {
            $absolutePath = Join-Path $script:RepoRoot $relativePath
            $content = Get-Content -LiteralPath $absolutePath -Raw -Encoding UTF8
            $content | Should -Not -Match '(?:\r?\n){2,}$'
        }
    }

    It 'fails when shared settings stop registering the orchestra gate hook' {
        $settingsPath = Join-Path $script:RepoRoot '.claude\settings.json'
        $original = Backup-TestFile -Path $settingsPath
        try {
            $settings = $original | ConvertFrom-Json -Depth 32
            $group = @($settings.hooks.PreToolUse) | Where-Object {
                @($_.hooks | Where-Object { $_.command -eq 'node .claude/hooks/sh-orchestra-gate.js' }).Count -gt 0
            } | Select-Object -First 1
            $group.matcher = 'Bash'
            $mutated = $settings | ConvertTo-Json -Depth 32
            Write-TestFileWithCmd -Path $settingsPath -Content $mutated

            $result = Invoke-HarnessCheckJson -Arguments @('-ProjectDir', $script:RepoRoot, '-AsJson')
            $record = $result.Json.results | Where-Object { $_.name -eq 'settings-shared-registers-orchestra-gate' } | Select-Object -First 1

            $result.ExitCode | Should -Be 1
            $record.passed | Should -Be $false
            $record.message | Should -Match 'must register'
        } finally {
            Restore-TestFile -Path $settingsPath -Content $original
        }
    }

    It 'fails when settings.local.json registers hooks' {
        Write-TestFileWithCmd -Path $script:SettingsLocalPath -Content '{"hooks":{"PreToolUse":[]}}'

        $result = Invoke-HarnessCheckJson -Arguments @('-ProjectDir', $script:RepoRoot, '-AsJson')
        $settingsLocalRecord = $result.Json.results | Where-Object { $_.name -eq 'settings-local-has-no-hooks' } | Select-Object -First 1

        $result.ExitCode | Should -Be 1
        $result.Json.passed | Should -Be $false
        $settingsLocalRecord.passed | Should -Be $false
        $settingsLocalRecord.message | Should -Match 'must not register hooks'
    }

    It 'fails when settings.local.json becomes tracked' {
        Write-TestFileWithCmd -Path $script:SettingsLocalPath -Content '{}'
        & git -C $script:RepoRoot add -f -- '.claude/settings.local.json'
        if ($LASTEXITCODE -ne 0) {
            throw 'git add failed for .claude/settings.local.json'
        }

        $result = Invoke-HarnessCheckJson -Arguments @('-ProjectDir', $script:RepoRoot, '-AsJson')
        $trackedRecord = $result.Json.results | Where-Object { $_.name -eq 'settings-local-not-tracked' } | Select-Object -First 1

        $result.ExitCode | Should -Be 1
        $result.Json.passed | Should -Be $false
        $trackedRecord.passed | Should -Be $false
        $trackedRecord.message | Should -Match 'must stay untracked'
    }

    It 'fails when sh-utils success replies omit hookEventName support' {
        $utilsPath = Join-Path $script:RepoRoot '.claude\hooks\lib\sh-utils.js'
        $original = Backup-TestFile -Path $utilsPath
        try {
            $mutated = $original -replace 'hookSpecificOutput:\s*buildHookSpecificOutput\(\{\s*additionalContext\s*\}\)', 'hookSpecificOutput: { additionalContext }'
            Write-TestFileWithCmd -Path $utilsPath -Content $mutated

            $result = Invoke-HarnessCheckJson -Arguments @('-ProjectDir', $script:RepoRoot, '-AsJson')
            $record = $result.Json.results | Where-Object { $_.name -eq 'hook-output-contract' } | Select-Object -First 1

            $result.ExitCode | Should -Be 1
            $record.passed | Should -Be $false
            (($record.data | Out-String)) | Should -Match 'allow reply does not include hookEventName'
        } finally {
            Restore-TestFile -Path $utilsPath -Content $original
        }
    }

    It 'keeps SessionEnd replies free of hookSpecificOutput while preserving evidence' {
        $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-session-end-" + [guid]::NewGuid().ToString('N'))
        try {
            $hooksDir = Join-Path $fixtureRoot '.claude\hooks'
            $libDir = Join-Path $hooksDir 'lib'
            $logsDir = Join-Path $fixtureRoot '.claude\logs'
            $shieldDir = Join-Path $fixtureRoot '.shield-harness'

            New-Item -ItemType Directory -Path $libDir -Force | Out-Null
            New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $shieldDir -Force | Out-Null

            Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.claude\hooks\sh-session-end.js') -Destination (Join-Path $hooksDir 'sh-session-end.js') -Force
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.claude\hooks\lib\sh-utils.js') -Destination (Join-Path $libDir 'sh-utils.js') -Force

            Set-Content -LiteralPath (Join-Path $shieldDir 'session.json') -Value '{"retry_count":2,"stop_hook_active":true}' -Encoding UTF8
            @(
                ([ordered]@{
                    event       = 'SessionStart'
                    session_id  = 'session-end-test'
                    recorded_at = '2026-04-16T00:00:00.000Z'
                } | ConvertTo-Json -Compress),
                ([ordered]@{
                    event       = 'tool'
                    tool        = 'Bash'
                    decision    = 'allow'
                    session_id  = 'session-end-test'
                    recorded_at = '2026-04-16T00:01:00.000Z'
                } | ConvertTo-Json -Compress),
                ([ordered]@{
                    event       = 'tool'
                    tool        = 'Edit'
                    decision    = 'deny'
                    session_id  = 'session-end-test'
                    recorded_at = '2026-04-16T00:02:00.000Z'
                } | ConvertTo-Json -Compress)
            ) | Set-Content -LiteralPath (Join-Path $logsDir 'evidence-ledger.jsonl') -Encoding UTF8

            $result = Invoke-NodeHookJson -RepoRoot $fixtureRoot -HookRelativePath '.claude\hooks\sh-session-end.js' -Payload ([ordered]@{
                session_id      = 'session-end-test'
                hook_event_name = 'SessionEnd'
            })

            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
            $result.Json | Should -Be $null

            $entries = Get-Content -LiteralPath (Join-Path $logsDir 'evidence-ledger.jsonl') -Encoding UTF8 | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_)) {
                    $_ | ConvertFrom-Json -Depth 20
                }
            }

            $sessionEndRecord = $entries | Select-Object -Last 1
            $sessionEndRecord.event | Should -Be 'SessionEnd'
            $sessionEndRecord.summary.tool_calls | Should -Be 2
            $sessionEndRecord.summary.denials | Should -Be 1
        } finally {
            if (Test-Path -LiteralPath $fixtureRoot) {
                Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
            }
        }
    }

    It 'resets SessionEnd state when Windows denies atomic session replacement' {
        if (-not $IsWindows) {
            Set-ItResult -Skipped -Because 'Windows rename EPERM fallback is Windows-specific.'
            return
        }

        $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-session-end-eperm-" + [guid]::NewGuid().ToString('N'))
        try {
            $hooksDir = Join-Path $fixtureRoot '.claude\hooks'
            $libDir = Join-Path $hooksDir 'lib'
            $logsDir = Join-Path $fixtureRoot '.claude\logs'
            $shieldDir = Join-Path $fixtureRoot '.shield-harness'

            New-Item -ItemType Directory -Path $libDir -Force | Out-Null
            New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $shieldDir -Force | Out-Null

            Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.claude\hooks\sh-session-end.js') -Destination (Join-Path $hooksDir 'sh-session-end-real.js') -Force
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.claude\hooks\lib\sh-utils.js') -Destination (Join-Path $libDir 'sh-utils.js') -Force

            Write-TestFileWithCmd -Path (Join-Path $hooksDir 'sh-session-end.js') -Content @"
#!/usr/bin/env node
"use strict";

const fs = require("fs");
const originalRenameSync = fs.renameSync;

fs.renameSync = function renameSyncWithSandboxEperm(from, to) {
  if (String(to).endsWith(".shield-harness\\session.json")) {
    const error = new Error("EPERM: operation not permitted, rename");
    error.code = "EPERM";
    throw error;
  }

  return originalRenameSync.apply(this, arguments);
};

require("./sh-session-end-real.js");
"@

            Write-TestFileWithCmd -Path (Join-Path $shieldDir 'session.json') -Content '{"retry_count":2,"stop_hook_active":true}'

            $result = Invoke-NodeHookJson -RepoRoot $fixtureRoot -HookRelativePath '.claude\hooks\sh-session-end.js' -Payload ([ordered]@{
                session_id      = 'session-end-eperm-test'
                hook_event_name = 'SessionEnd'
            })

            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
            $result.Json | Should -Be $null

            $session = Get-Content -LiteralPath (Join-Path $shieldDir 'session.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $session.retry_count | Should -Be 0
            $session.stop_hook_active | Should -BeFalse
            $session.session_end | Should -Not -BeNullOrEmpty

            $tmpFiles = Get-ChildItem -LiteralPath $shieldDir -Filter 'session.json.*.tmp'
            $tmpFiles | Should -BeNullOrEmpty
        } finally {
            if (Test-Path -LiteralPath $fixtureRoot) {
                Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
            }
        }
    }

    It 'injects winsmux resume context from manifest and backlog during SessionStart' {
        $fixture = New-SessionStartFixture
        try {
            $result = Invoke-NodeHookJson -RepoRoot $fixture.Root -HookRelativePath '.claude\hooks\sh-session-start.js' -Payload ([ordered]@{
                session_id      = 'session-start-test'
                hook_event_name = 'SessionStart'
            }) -EnvironmentVariables @{
                WINSMUX_BACKLOG_PATH = $fixture.BacklogPath
            }

            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
            $context = [string]$result.Json.hookSpecificOutput.additionalContext
            $context | Should -Match '\[winsmux-resume\] Session: winsmux-orchestra'
            $context | Should -Match '\[winsmux-resume\] Managed panes: 1'
            $context | Should -Match '\[winsmux-resume\] Pane: builder-1 TASK-154 in_progress - Resume session context'
            $context | Should -Match '\[winsmux-resume\] Planning: TASK-154 v0.24.1 - Manifest-aware session resume / context injection'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) {
                Remove-Item -LiteralPath $fixture.Root -Recurse -Force
            }
        }
    }

    It 'does not inject planning context when manifest is missing' {
        $fixture = New-SessionStartFixture
        try {
            Remove-Item -LiteralPath (Join-Path $fixture.Root '.winsmux\manifest.yaml') -Force

            $result = Invoke-NodeHookJson -RepoRoot $fixture.Root -HookRelativePath '.claude\hooks\sh-session-start.js' -Payload ([ordered]@{
                session_id      = 'session-start-no-manifest'
                hook_event_name = 'SessionStart'
            }) -EnvironmentVariables @{
                WINSMUX_BACKLOG_PATH = $fixture.BacklogPath
            }

            $result.ExitCode | Should -Be 0
            $context = [string]$result.Json.hookSpecificOutput.additionalContext
            $context | Should -Not -Match '\[winsmux-resume\] Planning:'
            $context | Should -Not -Match '\[winsmux-resume\] Session:'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) {
                Remove-Item -LiteralPath $fixture.Root -Recurse -Force
            }
        }
    }

    It 'clears stale winsmux resume state when resume sources disappear' {
        $fixture = New-SessionStartFixture
        try {
            $payload = [ordered]@{
                session_id      = 'session-start-reset'
                hook_event_name = 'SessionStart'
            }
            $environment = @{
                WINSMUX_BACKLOG_PATH = $fixture.BacklogPath
            }

            $first = Invoke-NodeHookJson -RepoRoot $fixture.Root -HookRelativePath '.claude\hooks\sh-session-start.js' -Payload $payload -EnvironmentVariables $environment
            $first.ExitCode | Should -Be 0

            Remove-Item -LiteralPath (Join-Path $fixture.Root '.winsmux\manifest.yaml') -Force
            Remove-Item -LiteralPath $fixture.BacklogPath -Force

            $second = Invoke-NodeHookJson -RepoRoot $fixture.Root -HookRelativePath '.claude\hooks\sh-session-start.js' -Payload $payload -EnvironmentVariables $environment

            $second.ExitCode | Should -Be 0
            $context = [string]$second.Json.hookSpecificOutput.additionalContext
            $context | Should -Not -Match '\[winsmux-resume\]'

            $sessionPath = Join-Path $fixture.Root '.shield-harness\session.json'
            $session = Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
            $session.winsmux_resume.manifest_path | Should -BeNullOrEmpty
            $session.winsmux_resume.backlog_path | Should -BeNullOrEmpty
            @($session.winsmux_resume.task_ids).Count | Should -Be 0
            $session.winsmux_resume.pane_count | Should -Be 0
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) {
                Remove-Item -LiteralPath $fixture.Root -Recurse -Force
            }
        }
    }

    It 'does not inject unrelated planning when manifest task ids do not match backlog' {
        $fixture = New-SessionStartFixture
        try {
            Write-TestFileWithCmd -Path (Join-Path $fixture.Root '.winsmux\manifest.yaml') -Content @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: '$($fixture.Root)'
panes:
  builder-1:
    task_id: TASK-999
    task_state: in_progress
    task: Detached resume state
"@

            $result = Invoke-NodeHookJson -RepoRoot $fixture.Root -HookRelativePath '.claude\hooks\sh-session-start.js' -Payload ([ordered]@{
                session_id      = 'session-start-unmatched-task'
                hook_event_name = 'SessionStart'
            }) -EnvironmentVariables @{
                WINSMUX_BACKLOG_PATH = $fixture.BacklogPath
            }

            $result.ExitCode | Should -Be 0
            $context = [string]$result.Json.hookSpecificOutput.additionalContext
            $context | Should -Match '\[winsmux-resume\] Pane: builder-1 TASK-999 in_progress - Detached resume state'
            $context | Should -Not -Match '\[winsmux-resume\] Planning:'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) {
                Remove-Item -LiteralPath $fixture.Root -Recurse -Force
            }
        }
    }

    It 'recovers when session.json is not an object' {
        $fixture = New-SessionStartFixture
        try {
            $shieldDir = Join-Path $fixture.Root '.shield-harness'
            New-Item -ItemType Directory -Path $shieldDir -Force | Out-Null
            Write-TestFileWithCmd -Path (Join-Path $shieldDir 'session.json') -Content '"broken"'

            $result = Invoke-NodeHookJson -RepoRoot $fixture.Root -HookRelativePath '.claude\hooks\sh-session-start.js' -Payload ([ordered]@{
                session_id      = 'session-start-broken-session'
                hook_event_name = 'SessionStart'
            }) -EnvironmentVariables @{
                WINSMUX_BACKLOG_PATH = $fixture.BacklogPath
            }

            $result.ExitCode | Should -Be 0
            $context = [string]$result.Json.hookSpecificOutput.additionalContext
            $context | Should -Match '\[winsmux-resume\] Session: winsmux-orchestra'
            $context | Should -Not -Match 'Initialization error'

            $sessionPath = Join-Path $shieldDir 'session.json'
            $session = Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
            $session.token_budget.session_limit | Should -Be 200000
            $session.winsmux_resume.manifest_path | Should -Match 'manifest\.yaml$'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) {
                Remove-Item -LiteralPath $fixture.Root -Recurse -Force
            }
        }
    }

    It 'blocks PR merge commands while orchestra restore is still needs-startup' {
        $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-startup-gate-" + [guid]::NewGuid().ToString('N'))
        try {
            $hooksDir = Join-Path $fixtureRoot '.claude\hooks'
            $scriptsDir = Join-Path $fixtureRoot 'winsmux-core\scripts'
            $fakeBinDir = Join-Path $fixtureRoot 'fake-bin'

            New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
            New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $fakeBinDir -Force | Out-Null

            Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.claude\hooks\sh-orchestra-gate.js') -Destination (Join-Path $hooksDir 'sh-orchestra-gate.js') -Force

            Write-TestFileWithCmd -Path (Join-Path $scriptsDir 'settings.ps1') -Content @'
function Get-BridgeSettings {
    param([string]$RootPath)
    [pscustomobject]@{
        worker_count       = 6
        external_operator = $true
    }
}
'@

            Write-TestFileWithCmd -Path (Join-Path $fakeBinDir 'winsmux.cmd') -Content @'
@echo off
if "%1"=="has-session" exit /b 1
exit /b 0
'@

            $result = Invoke-NodeHookJson -RepoRoot $fixtureRoot -HookRelativePath '.claude\hooks\sh-orchestra-gate.js' -Payload ([ordered]@{
                tool_name  = 'Bash'
                tool_input = [ordered]@{
                    command = 'gh pr merge 424 --repo Sora-bluesky/winsmux'
                }
            }) -EnvironmentVariables @{
                PATH = "$fakeBinDir;$env:PATH"
            }

            $result.ExitCode | Should -Be 0
            $result.Json.hookSpecificOutput.permissionDecision | Should -Be 'deny'
            $result.Json.hookSpecificOutput.permissionDecisionReason | Should -Match 'Orchestra is needs-startup'
            $result.Json.systemMessage | Should -Match 'PR/merge progression commands are blocked until worker panes are ready'
        } finally {
            if (Test-Path -LiteralPath $fixtureRoot) {
                Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
            }
        }
    }

    It 'allows orchestra-start recovery commands while orchestra restore is needs-startup' {
        $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-startup-allow-" + [guid]::NewGuid().ToString('N'))
        try {
            $hooksDir = Join-Path $fixtureRoot '.claude\hooks'
            $scriptsDir = Join-Path $fixtureRoot 'winsmux-core\scripts'
            $fakeBinDir = Join-Path $fixtureRoot 'fake-bin'

            New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
            New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $fakeBinDir -Force | Out-Null

            Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.claude\hooks\sh-orchestra-gate.js') -Destination (Join-Path $hooksDir 'sh-orchestra-gate.js') -Force

            Write-TestFileWithCmd -Path (Join-Path $scriptsDir 'settings.ps1') -Content @'
function Get-BridgeSettings {
    param([string]$RootPath)
    [pscustomobject]@{
        worker_count       = 6
        external_operator = $true
    }
}
'@

            Write-TestFileWithCmd -Path (Join-Path $fakeBinDir 'winsmux.cmd') -Content @'
@echo off
if "%1"=="has-session" exit /b 1
exit /b 0
'@

            $result = Invoke-NodeHookJson -RepoRoot $fixtureRoot -HookRelativePath '.claude\hooks\sh-orchestra-gate.js' -Payload ([ordered]@{
                tool_name  = 'Bash'
                tool_input = [ordered]@{
                    command = 'pwsh -NoProfile -File winsmux-core/scripts/orchestra-start.ps1'
                }
            }) -EnvironmentVariables @{
                PATH = "$fakeBinDir;$env:PATH"
            }

            $result.ExitCode | Should -Be 0
            $result.StdOut | Should -Be ''
            $result.StdErr | Should -Be ''
            $result.Json | Should -Be $null
        } finally {
            if (Test-Path -LiteralPath $fixtureRoot) {
                Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
            }
        }
    }

    It 'is exposed through winsmux-core as harness-check --json' {
        $stdout = & $script:PwshPath -NoProfile -File $script:WinsmuxCorePath harness-check --json 2>&1
        $exitCode = $LASTEXITCODE
        $json = (($stdout | Out-String).Trim() | ConvertFrom-Json -Depth 16)

        $exitCode | Should -Be 0
        $json.passed | Should -Be $true
    }
}

Describe 'desktop PTY event payload contract' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:PtyClientPath = Join-Path $script:RepoRoot 'winsmux-app\src\ptyClient.ts'
    }

    It 'accepts object and string pty-output event payloads' {
        $client = Get-Content -LiteralPath $script:PtyClientPath -Raw -Encoding UTF8

        $client | Should -Match 'function normalizePtyOutputEventPayload'
        $client | Should -Match 'listen<PtyOutputEvent \| string>\("pty-output"'
        $client | Should -Not -Match 'listen<string>\("pty-output"'
        $client | Should -Match 'normalizePtyOutputEventPayload\(event\.payload\)'
        $client | Should -Match 'typeof payload === "string"'
        $client | Should -Match 'typeof payload\?\.data === "string"'
    }
}
