$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

BeforeAll {
    $script:Task661RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Task661ConfigName = '.winsmux.yaml'
    $script:Task661JournalRelative = '.winsmux\workspace-migration-v1.json'
    $script:Task661LockName = '.winsmux.yaml.lock'
    $script:Task661Utf8 = [Text.UTF8Encoding]::new($false, $true)

    $binaryOverride = [Environment]::GetEnvironmentVariable('WINSMUX_TASK661_BINARY')
    if ([string]::IsNullOrWhiteSpace($binaryOverride)) {
        if (
            $IsWindows -and
            [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('LIB'))
        ) {
            $vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
            if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) {
                throw 'TASK-661 MSVC environment initializer is missing.'
            }
            $environmentLines = & $env:ComSpec /d /c "call `"$vcvars`" >nul && set"
            if ($LASTEXITCODE -ne 0) {
                throw 'TASK-661 MSVC environment initialization failed.'
            }
            foreach ($line in $environmentLines) {
                $separator = $line.IndexOf('=')
                if ($separator -gt 0) {
                    [Environment]::SetEnvironmentVariable(
                        $line.Substring(0, $separator),
                        $line.Substring($separator + 1)
                    )
                }
            }
        }
        Push-Location $script:Task661RepoRoot
        try {
            & cargo build --quiet --manifest-path core/Cargo.toml --bin winsmux
            if ($LASTEXITCODE -ne 0) {
                throw "TASK-661 candidate build failed with exit code $LASTEXITCODE."
            }
        } finally {
            Pop-Location
        }
        $script:Task661Binary = Join-Path $script:Task661RepoRoot 'target\debug\winsmux.exe'
    } else {
        $script:Task661Binary = [IO.Path]::GetFullPath($binaryOverride)
    }
    if (-not (Test-Path -LiteralPath $script:Task661Binary -PathType Leaf)) {
        throw "TASK-661 candidate binary is missing: $($script:Task661Binary)"
    }

    function Get-Task661Sha256 {
        param([Parameter(Mandatory = $true)][byte[]]$Bytes)

        $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)
        return 'sha256:' + (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    }

    function Get-Task661FileIdentity {
        param([Parameter(Mandatory = $true)][string]$Path)

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return 'absent'
        }
        $bytes = [IO.File]::ReadAllBytes($Path)
        return '{0}:{1}' -f (Get-Task661Sha256 -Bytes $bytes), $bytes.Length
    }

    function Get-Task661ProjectSnapshot {
        param([Parameter(Mandatory = $true)][string]$ProjectDir)

        $records = [Collections.Generic.List[string]]::new()
        if (-not (Test-Path -LiteralPath $ProjectDir -PathType Container)) {
            return 'project-absent'
        }
        foreach ($item in @(
                Get-ChildItem -LiteralPath $ProjectDir -Force -Recurse |
                    Sort-Object FullName
            )) {
            $relative = [IO.Path]::GetRelativePath($ProjectDir, $item.FullName).Replace('\', '/')
            if ($item.PSIsContainer) {
                $records.Add("D|$relative|$([int]$item.Attributes)") | Out-Null
            } else {
                $bytes = [IO.File]::ReadAllBytes($item.FullName)
                $records.Add(
                    "F|$relative|$([int]$item.Attributes)|$([Convert]::ToBase64String($bytes))"
                ) | Out-Null
            }
        }
        return $records -join "`n"
    }

    function Get-Task661TempFiles {
        param([Parameter(Mandatory = $true)][string]$ProjectDir)

        return @(
            Get-ChildItem `
                -LiteralPath $ProjectDir `
                -Force `
                -Recurse `
                -File `
                -Filter '*.tmp-*' `
                -ErrorAction SilentlyContinue
        )
    }

    function New-Task661Config {
        param(
            [ValidateSet('supported', 'missing-slot', 'ambiguous-review')]
            [string]$SlotMode = 'supported',
            [switch]$WithLaneA,
            [switch]$WithPrivateMarker
        )

        $slots = switch ($SlotMode) {
            'supported' {
                @'
agent-slots:
  - slot-id: worker-1
    agent: codex
    model: provider-default
    model-source: provider-default
    reasoning-effort: provider-default
    prompt-transport: argv
'@
            }
            'missing-slot' {
                @'
agent-slots:
  - slot-id: worker-9
    agent: codex
    model: provider-default
    model-source: provider-default
    reasoning-effort: provider-default
    prompt-transport: argv
'@
            }
            'ambiguous-review' {
                @'
agent-slots:
  - slot-id: worker-1
    agent: codex
    model: provider-default
    model-source: provider-default
    reasoning-effort: provider-default
    prompt-transport: argv
  - slot-id: worker-2
    agent: codex
    model: provider-default
    model-source: provider-default
    reasoning-effort: provider-default
    prompt-transport: argv
'@
            }
        }
        $markerBlock = if ($WithPrivateMarker) {
            @'
future-private-state:
  private-note: wm-private-marker-661
'@
        } else {
            ''
        }
        $laneA = if ($WithLaneA) {
            @'
workspace-recipes:
  bugfix: {}
'@
        } else {
            ''
        }
        return @"
# TASK-661 preserved header
config-version: 1
external-operator: true
$slots
team-profile:
  schema-version: 1
  preset: future-lane-b
future-top-level:
  owner: future
$markerBlock$laneA
"@
    }

    function New-Task661Project {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [ValidateSet('supported', 'missing-slot', 'ambiguous-review', 'missing', 'malformed', 'duplicate')]
            [string]$Mode = 'supported',
            [switch]$WithLaneA,
            [switch]$WithPrivateMarker
        )

        $projectDir = Join-Path $TestDrive $Name
        [IO.Directory]::CreateDirectory($projectDir) | Out-Null
        $configPath = Join-Path $projectDir $script:Task661ConfigName
        if ($Mode -ne 'missing') {
            $content = switch ($Mode) {
                'malformed' { "config-version: [`nprivate: wm-private-marker-661`n" }
                'duplicate' { "config-version: 1`nconfig-version: 1`n" }
                default {
                    New-Task661Config `
                        -SlotMode $Mode `
                        -WithLaneA:$WithLaneA `
                        -WithPrivateMarker:$WithPrivateMarker
                }
            }
            [IO.File]::WriteAllText($configPath, $content, $script:Task661Utf8)
        }
        return [PSCustomObject]@{
            ProjectDir = $projectDir
            ConfigPath = $configPath
            RuntimePath = Join-Path $projectDir '.winsmux'
            JournalPath = Join-Path $projectDir $script:Task661JournalRelative
            LockPath = Join-Path $projectDir $script:Task661LockName
        }
    }

    function Start-Task661Process {
        param(
            [Parameter(Mandatory = $true)][string]$ProjectDir,
            [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments
        )

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:Task661Binary
        $startInfo.WorkingDirectory = $ProjectDir
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in $Arguments) {
            $startInfo.ArgumentList.Add([string]$argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            $process.Dispose()
            throw 'Failed to start TASK-661 public child process.'
        }
        return [PSCustomObject]@{
            Process = $process
            Arguments = @($Arguments)
        }
    }

    function Complete-Task661Process {
        param(
            [Parameter(Mandatory = $true)]$Child,
            [int]$TimeoutMilliseconds = 30000
        )

        $stdoutRead = $Child.Process.StandardOutput.ReadToEndAsync()
        $stderrRead = $Child.Process.StandardError.ReadToEndAsync()
        if (-not $Child.Process.WaitForExit($TimeoutMilliseconds)) {
            $Child.Process.Kill($true)
            $Child.Process.WaitForExit()
            $Child.Process.Dispose()
            throw 'TASK-661 public child process timed out.'
        }
        $result = [PSCustomObject]@{
            ExitCode = $Child.Process.ExitCode
            Stdout = [string]$stdoutRead.Result
            Stderr = [string]$stderrRead.Result
            Arguments = @($Child.Arguments)
        }
        $Child.Process.Dispose()
        return $result
    }

    function Invoke-Task661Process {
        param(
            [Parameter(Mandatory = $true)][string]$ProjectDir,
            [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments
        )

        $child = Start-Task661Process -ProjectDir $ProjectDir -Arguments $Arguments
        return Complete-Task661Process -Child $child
    }

    function ConvertFrom-Task661Json {
        param([Parameter(Mandatory = $true)]$Result)

        $Result.ExitCode | Should -Be 0
        $Result.Stderr | Should -BeNullOrEmpty
        return $Result.Stdout | ConvertFrom-Json -Depth 50
    }

    function Invoke-Task661Action {
        param(
            [Parameter(Mandatory = $true)]$Fixture,
            [Parameter(Mandatory = $true)]
            [ValidateSet('list', 'preview', 'apply', 'rollback')]
            [string]$Action,
            [string]$Preset = '',
            [string]$MigrationId = ''
        )

        $arguments = [Collections.Generic.List[string]]::new()
        foreach ($value in @('workspace-migrate', '--action', $Action)) {
            $arguments.Add($value) | Out-Null
        }
        if (-not [string]::IsNullOrEmpty($Preset)) {
            $arguments.Add('--preset') | Out-Null
            $arguments.Add($Preset) | Out-Null
        }
        if (-not [string]::IsNullOrEmpty($MigrationId)) {
            $arguments.Add('--migration-id') | Out-Null
            $arguments.Add($MigrationId) | Out-Null
        }
        if ($Action -ne 'list') {
            $arguments.Add('--project-dir') | Out-Null
            $arguments.Add($Fixture.ProjectDir) | Out-Null
        }
        $arguments.Add('--json') | Out-Null
        return Invoke-Task661Process -ProjectDir $Fixture.ProjectDir -Arguments $arguments.ToArray()
    }

    function Get-Task661ApplyIdentity {
        param([Parameter(Mandatory = $true)]$Fixture, [string]$Preset = 'bugfix')

        $result = Invoke-Task661Action -Fixture $Fixture -Action apply -Preset $Preset
        $payload = ConvertFrom-Task661Json -Result $result
        [string]$payload.migration_id | Should -Match '^[0-9a-f]{64}$'
        return [PSCustomObject]@{
            Result = $result
            Payload = $payload
            MigrationId = [string]$payload.migration_id
        }
    }

    function New-Task661ExactLengthDirectory {
        param(
            [Parameter(Mandatory = $true)][string]$Root,
            [Parameter(Mandatory = $true)][int]$Utf8Bytes
        )

        $path = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        while ($script:Task661Utf8.GetByteCount($path) -lt $Utf8Bytes) {
            $remaining = $Utf8Bytes - $script:Task661Utf8.GetByteCount($path) - 1
            if ($remaining -lt 1) {
                throw 'Cannot construct exact TASK-661 path length.'
            }
            $componentLength = [Math]::Min(100, $remaining)
            $path = Join-Path $path ('p' * $componentLength)
            [IO.Directory]::CreateDirectory($path) | Out-Null
        }
        $script:Task661Utf8.GetByteCount($path) | Should -Be $Utf8Bytes
        return $path
    }
}

Describe 'TASK-661 shipped presets and reversible migration contract' {
    It 'WM01 lists exactly four ordered deterministic public-safe presets without project access' {
        $fixture = New-Task661Project -Name 'wm01' -Mode malformed
        $before = Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir
        $firstResult = Invoke-Task661Process -ProjectDir $fixture.ProjectDir -Arguments @(
            'workspace-migrate', '--action', 'list', '--json'
        )
        $secondResult = Invoke-Task661Process -ProjectDir $fixture.ProjectDir -Arguments @(
            'workspace-migrate', '--action', 'list', '--json'
        )
        $payload = ConvertFrom-Task661Json -Result $firstResult

        $payload.schema_version | Should -Be 1
        $payload.action | Should -BeExactly 'list'
        $payload.status | Should -BeExactly 'listed'
        @($payload.presets.preset_id) | Should -Be @('bugfix', 'review', 'research', 'benchmark')
        $firstResult.Stdout | Should -BeExactly $secondResult.Stdout
        $firstResult.Stdout | Should -Not -Match '(?i)provider|model|prompt|secret|[A-Z]:\\|/home/'
        (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
    }

    It 'WM02 previews a supported preset deterministically with zero config journal lock or runtime mutation' {
        $fixture = New-Task661Project -Name 'wm02'
        $before = Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir
        $firstResult = Invoke-Task661Action -Fixture $fixture -Action preview -Preset bugfix
        $secondResult = Invoke-Task661Action -Fixture $fixture -Action preview -Preset bugfix
        $payload = ConvertFrom-Task661Json -Result $firstResult

        $payload.action | Should -BeExactly 'preview'
        $payload.preset_id | Should -BeExactly 'bugfix'
        $payload.status | Should -BeExactly 'ready'
        $payload.applicable | Should -BeTrue
        @($payload.unsupported_codes).Count | Should -Be 0
        $payload.rollback_available_after_apply | Should -BeTrue
        $payload.lane_b_preserved | Should -BeTrue
        $payload.unknown_compatible_fields_preserved | Should -BeTrue
        $payload.proposal_sha256 | Should -BeExactly (
            Get-Task661Sha256 -Bytes $script:Task661Utf8.GetBytes([string]$payload.proposal_yaml)
        )
        $firstResult.Stdout | Should -BeExactly $secondResult.Stdout
        (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
    }

    It 'WM03 reports unsupported effective slots through one bounded code and preserves every byte' {
        $fixture = New-Task661Project -Name 'wm03' -Mode missing-slot
        $before = Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir
        $result = Invoke-Task661Action -Fixture $fixture -Action preview -Preset bugfix
        $payload = ConvertFrom-Task661Json -Result $result

        $payload.status | Should -BeExactly 'unsupported'
        $payload.applicable | Should -BeFalse
        @($payload.unsupported_codes) | Should -Be @('effective_slots_not_supported')
        $result.Stdout | Should -Not -Match 'worker-9|codex|provider-default'
        (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
    }

    It 'WM04 explicitly applies one valid preset and publishes one coherent private journal then Lane A target' {
        $fixture = New-Task661Project -Name 'wm04'
        $originalBytes = [IO.File]::ReadAllBytes($fixture.ConfigPath)
        $apply = Get-Task661ApplyIdentity -Fixture $fixture

        $apply.Payload.status | Should -BeExactly 'applied'
        Test-Path -LiteralPath $fixture.RuntimePath -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $fixture.JournalPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        $targetText = [IO.File]::ReadAllText($fixture.ConfigPath, $script:Task661Utf8)
        $targetText | Should -Match '(?m)^workspace-recipes:'
        $targetText | Should -Match '(?m)^workflows:'
        $targetText | Should -Match '(?m)^context-packs:'
        $targetText | Should -Match 'future-lane-b'
        $targetText | Should -Match 'owner: future'

        $journal = [IO.File]::ReadAllText($fixture.JournalPath, $script:Task661Utf8) |
            ConvertFrom-Json -Depth 30
        $journal.schema_version | Should -Be 1
        $journal.migration_id | Should -BeExactly $apply.MigrationId
        $journal.preset_id | Should -BeExactly 'bugfix'
        $journal.original_existed | Should -BeTrue
        [Convert]::FromBase64String([string]$journal.original_base64) |
            Should -Be $originalBytes
        $journal.source_sha256 | Should -BeExactly (Get-Task661Sha256 -Bytes $originalBytes)
        $journal.target_sha256 | Should -BeExactly (
            Get-Task661Sha256 -Bytes ([IO.File]::ReadAllBytes($fixture.ConfigPath))
        )
        @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
    }

    It 'WM05 repeats or resumes the same apply as an exact no-op with one stable identity' {
        $fixture = New-Task661Project -Name 'wm05'
        $first = Get-Task661ApplyIdentity -Fixture $fixture
        $configIdentity = Get-Task661FileIdentity -Path $fixture.ConfigPath
        $journalIdentity = Get-Task661FileIdentity -Path $fixture.JournalPath
        $second = Get-Task661ApplyIdentity -Fixture $fixture

        $second.Payload.status | Should -BeExactly 'already_applied'
        $second.MigrationId | Should -BeExactly $first.MigrationId
        (Get-Task661FileIdentity -Path $fixture.ConfigPath) | Should -BeExactly $configIdentity
        (Get-Task661FileIdentity -Path $fixture.JournalPath) | Should -BeExactly $journalIdentity
        Test-Path -LiteralPath $fixture.RuntimePath -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
    }

    It 'WM06 rolls back by exact opaque identity and restores the original existing bytes' {
        $fixture = New-Task661Project -Name 'wm06'
        $originalBytes = [IO.File]::ReadAllBytes($fixture.ConfigPath)
        $apply = Get-Task661ApplyIdentity -Fixture $fixture
        $rollbackResult = Invoke-Task661Action `
            -Fixture $fixture `
            -Action rollback `
            -MigrationId $apply.MigrationId
        $rollback = ConvertFrom-Task661Json -Result $rollbackResult

        $rollback.status | Should -BeExactly 'rolled_back'
        $rollback.migration_id | Should -BeExactly $apply.MigrationId
        [IO.File]::ReadAllBytes($fixture.ConfigPath) | Should -Be $originalBytes
        Test-Path -LiteralPath $fixture.RuntimePath -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
    }

    It 'WM07 applies to an absent config and rollback restores exact file absence' {
        $fixture = New-Task661Project -Name 'wm07' -Mode missing
        Test-Path -LiteralPath $fixture.ConfigPath | Should -BeFalse
        $apply = Get-Task661ApplyIdentity -Fixture $fixture

        $apply.Payload.status | Should -BeExactly 'applied'
        Test-Path -LiteralPath $fixture.ConfigPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $fixture.JournalPath -PathType Leaf | Should -BeTrue
        $rollbackResult = Invoke-Task661Action `
            -Fixture $fixture `
            -Action rollback `
            -MigrationId $apply.MigrationId
        $rollback = ConvertFrom-Task661Json -Result $rollbackResult
        $rollback.status | Should -BeExactly 'rolled_back'
        Test-Path -LiteralPath $fixture.ConfigPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.RuntimePath -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
    }

    It 'WM08 preserves comments Lane B legacy and unknown compatible spans while adding only Lane A roots' {
        $fixture = New-Task661Project -Name 'wm08'
        $originalText = [IO.File]::ReadAllText($fixture.ConfigPath, $script:Task661Utf8)
        $apply = Get-Task661ApplyIdentity -Fixture $fixture -Preset review
        $targetText = [IO.File]::ReadAllText($fixture.ConfigPath, $script:Task661Utf8)

        $apply.Payload.status | Should -BeExactly 'applied'
        $targetText.StartsWith($originalText, [StringComparison]::Ordinal) | Should -BeTrue
        $targetText | Should -Match '# TASK-661 preserved header'
        $targetText | Should -Match 'team-profile:'
        $targetText | Should -Match 'future-top-level:'
        $targetText | Should -Match '(?m)^workspace-recipes:'
        $targetText | Should -Match '(?m)^workflows:'
        $targetText | Should -Match '(?m)^context-packs:'
        Test-Path -LiteralPath $fixture.RuntimePath -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $fixture.JournalPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
    }

    It 'WM09 keeps workspace-plan and legacy pipeline bytes usable before during and after opt-in migration' {
        $fixture = New-Task661Project -Name 'wm09'
        $teamPipeline = Join-Path $script:Task661RepoRoot 'winsmux-core\scripts\team-pipeline.ps1'
        $orchestraStart = Join-Path $script:Task661RepoRoot 'winsmux-core\scripts\orchestra-start.ps1'
        $teamIdentity = Get-Task661FileIdentity -Path $teamPipeline
        $orchestraIdentity = Get-Task661FileIdentity -Path $orchestraStart
        $originalConfig = [IO.File]::ReadAllBytes($fixture.ConfigPath)

        $legacyBefore = Invoke-Task661Process -ProjectDir $fixture.ProjectDir -Arguments @(
            'workspace-plan', '--help'
        )
        $legacyBefore.ExitCode | Should -Be 0
        $legacyBefore.Stdout | Should -Match 'workspace-plan'
        $list = Invoke-Task661Process -ProjectDir $fixture.ProjectDir -Arguments @(
            'workspace-migrate', '--action', 'list', '--json'
        )
        (ConvertFrom-Task661Json -Result $list).status | Should -BeExactly 'listed'
        $apply = Get-Task661ApplyIdentity -Fixture $fixture
        $legacyDuring = Invoke-Task661Process -ProjectDir $fixture.ProjectDir -Arguments @(
            'workspace-plan', '--help'
        )
        $legacyDuring.ExitCode | Should -Be 0
        $rollback = Invoke-Task661Action `
            -Fixture $fixture `
            -Action rollback `
            -MigrationId $apply.MigrationId
        (ConvertFrom-Task661Json -Result $rollback).status | Should -BeExactly 'rolled_back'
        (Get-Task661FileIdentity -Path $teamPipeline) | Should -BeExactly $teamIdentity
        (Get-Task661FileIdentity -Path $orchestraStart) | Should -BeExactly $orchestraIdentity
        [IO.File]::ReadAllBytes($fixture.ConfigPath) | Should -Be $originalConfig
        Test-Path -LiteralPath $fixture.RuntimePath -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
    }

    It 'WM10 rejects every invalid CLI grammar sibling through one non-reflective error before all sinks' {
        $fixture = New-Task661Project -Name 'wm10'
        $before = Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir
        $vectors = @(
            @('workspace-migrate', '--json'),
            @('workspace-migrate', '--action', 'LIST', '--json'),
            @('workspace-migrate', '--action', 'list', '--action', 'list', '--json'),
            @('workspace-migrate', '--action', 'list', '--json', '--json'),
            @('workspace-migrate', '--action', 'preview', '--preset', '', '--json'),
            @('workspace-migrate', '--action', 'list', '--surplus', '--json')
        )

        foreach ($arguments in $vectors) {
            $result = Invoke-Task661Process -ProjectDir $fixture.ProjectDir -Arguments $arguments
            $result.ExitCode | Should -Not -Be 0
            $result.Stdout | Should -BeNullOrEmpty
            $result.Stderr | Should -Match 'workspace migration rejected\.'
            $result.Stderr | Should -Not -Match 'LIST|surplus'
        }
        (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
    }

    It 'WM11 rejects unknown path-shaped or malformed IDs without reflecting them or reaching a sink' {
        $fixture = New-Task661Project -Name 'wm11'
        $before = Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir
        $vectors = @(
            @('workspace-migrate', '--action', 'preview', '--preset', '..\wm-private-marker-661', '--json'),
            @('workspace-migrate', '--action', 'preview', '--preset', 'unknown-marker-661', '--json'),
            @('workspace-migrate', '--action', 'rollback', '--migration-id', '..\wm-private-marker-661', '--json'),
            @('workspace-migrate', '--action', 'rollback', '--migration-id', ('A' * 64), '--json')
        )

        foreach ($arguments in $vectors) {
            $result = Invoke-Task661Process -ProjectDir $fixture.ProjectDir -Arguments $arguments
            $result.ExitCode | Should -Not -Be 0
            $result.Stdout | Should -BeNullOrEmpty
            $result.Stderr | Should -Match 'workspace migration rejected\.'
            $result.Stderr | Should -Not -Match 'wm-private-marker-661|unknown-marker-661'
        }
        (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
    }

    It 'WM12 treats every pre-existing Lane A root including identical content as user-owned conflict' {
        $fixture = New-Task661Project -Name 'wm12' -WithLaneA
        $before = Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir
        $previewResult = Invoke-Task661Action -Fixture $fixture -Action preview -Preset bugfix
        $preview = ConvertFrom-Task661Json -Result $previewResult
        $preview.status | Should -BeExactly 'unsupported'
        @($preview.unsupported_codes) | Should -Be @('lane_a_already_configured')

        $apply = Invoke-Task661Action -Fixture $fixture -Action apply -Preset bugfix
        $apply.ExitCode | Should -Not -Be 0
        $apply.Stdout | Should -BeNullOrEmpty
        $apply.Stderr | Should -Match 'workspace migration rejected\.'
        (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
    }

    It 'WM13 rejects malformed duplicate non-mapping and unsupported config documents without disclosure or mutation' {
        foreach ($mode in @('malformed', 'duplicate')) {
            $fixture = New-Task661Project -Name "wm13-$mode" -Mode $mode
            $before = Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir
            $previewResult = Invoke-Task661Action -Fixture $fixture -Action preview -Preset bugfix
            $preview = ConvertFrom-Task661Json -Result $previewResult
            $preview.status | Should -BeExactly 'unsupported'
            @($preview.unsupported_codes) | Should -Be @('project_config_invalid')
            $previewResult.Stdout | Should -Not -Match 'wm-private-marker-661'

            $apply = Invoke-Task661Action -Fixture $fixture -Action apply -Preset bugfix
            $apply.ExitCode | Should -Not -Be 0
            $apply.Stdout | Should -BeNullOrEmpty
            $apply.Stderr | Should -Match 'workspace migration rejected\.'
            (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before
            Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
            Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
            @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
        }
    }

    It 'WM14 rejects missing or ambiguous effective slot bindings before journal lock or config mutation' {
        $cases = @(
            [PSCustomObject]@{ Name = 'missing'; Mode = 'missing-slot'; Preset = 'bugfix' },
            [PSCustomObject]@{ Name = 'ambiguous'; Mode = 'ambiguous-review'; Preset = 'review' }
        )
        foreach ($case in $cases) {
            $fixture = New-Task661Project -Name "wm14-$($case.Name)" -Mode $case.Mode
            $before = Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir
            $previewResult = Invoke-Task661Action `
                -Fixture $fixture `
                -Action preview `
                -Preset $case.Preset
            $preview = ConvertFrom-Task661Json -Result $previewResult
            $preview.status | Should -BeExactly 'unsupported'
            @($preview.unsupported_codes) | Should -Be @('effective_slots_not_supported')

            $apply = Invoke-Task661Action -Fixture $fixture -Action apply -Preset $case.Preset
            $apply.ExitCode | Should -Not -Be 0
            $apply.Stderr | Should -Match 'workspace migration rejected\.'
            (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before
            Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
            Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
            @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
        }
    }

    It 'WM15 rejects malformed wrong-version wrong-ID and identity-inconsistent journals byte-for-byte' {
        $cases = @(
            '{',
            '{"schema_version":2}',
            '{"schema_version":1,"migration_id":"' + ('a' * 64) + '"}',
            '{"schema_version":1,"preset_id":"bugfix","migration_id":"' + ('b' * 64) +
                '","original_existed":true,"original_base64":"","source_sha256":"sha256:' +
                ('0' * 64) + '","target_sha256":"sha256:' + ('1' * 64) + '"}'
        )
        $index = 0
        foreach ($journalText in $cases) {
            $fixture = New-Task661Project -Name "wm15-$index"
            [IO.Directory]::CreateDirectory((Split-Path -Parent $fixture.JournalPath)) | Out-Null
            [IO.File]::WriteAllText($fixture.JournalPath, $journalText, $script:Task661Utf8)
            $before = Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir
            $result = Invoke-Task661Action `
                -Fixture $fixture `
                -Action rollback `
                -MigrationId ('a' * 64)
            $result.ExitCode | Should -Not -Be 0
            $result.Stdout | Should -BeNullOrEmpty
            $result.Stderr | Should -Match 'workspace migration rejected\.'
            (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before
            Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
            @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
            $index++
        }
    }

    It 'WM16 refuses rollback after config drift and preserves both changed config and recovery journal' {
        $fixture = New-Task661Project -Name 'wm16'
        $apply = Get-Task661ApplyIdentity -Fixture $fixture
        [IO.File]::AppendAllText(
            $fixture.ConfigPath,
            "drift-owned-by-user: true`n",
            $script:Task661Utf8
        )
        $before = Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir
        $result = Invoke-Task661Action `
            -Fixture $fixture `
            -Action rollback `
            -MigrationId $apply.MigrationId

        $result.ExitCode | Should -Not -Be 0
        $result.Stdout | Should -BeNullOrEmpty
        $result.Stderr | Should -Match 'workspace migration rejected\.'
        (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before
        Test-Path -LiteralPath $fixture.JournalPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
    }

    It 'WM17 enforces project path namespace segment byte bounds and direct runtime reparse rejection before sinks' {
        $normalRoot = Join-Path $TestDrive 'wm17-lengths'
        [IO.Directory]::CreateDirectory($normalRoot) | Out-Null

        $componentEdge = Join-Path $normalRoot ('c' * 255)
        [IO.Directory]::CreateDirectory($componentEdge) | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $componentEdge $script:Task661ConfigName),
            (New-Task661Config),
            $script:Task661Utf8
        )
        $componentIdentity = Get-Task661FileIdentity -Path (
            Join-Path $componentEdge $script:Task661ConfigName
        )
        $componentPass = Invoke-Task661Process -ProjectDir $normalRoot -Arguments @(
            'workspace-migrate', '--action', 'preview', '--preset', 'bugfix',
            '--project-dir', $componentEdge, '--json'
        )
        (ConvertFrom-Task661Json -Result $componentPass).status | Should -BeExactly 'ready'
        (Get-Task661FileIdentity -Path (
                Join-Path $componentEdge $script:Task661ConfigName
            )) | Should -BeExactly $componentIdentity

        $componentOverflow = Join-Path $normalRoot ('c' * 256)
        $overflow = Invoke-Task661Process -ProjectDir $normalRoot -Arguments @(
            'workspace-migrate', '--action', 'preview', '--preset', 'bugfix',
            '--project-dir', $componentOverflow, '--json'
        )
        $overflow.ExitCode | Should -Not -Be 0
        $overflow.Stderr | Should -Match 'workspace migration rejected\.'

        $totalEdge = New-Task661ExactLengthDirectory -Root (
            Join-Path $TestDrive 'wm17-total'
        ) -Utf8Bytes 4096
        [IO.File]::WriteAllText(
            (Join-Path $totalEdge $script:Task661ConfigName),
            (New-Task661Config),
            $script:Task661Utf8
        )
        $totalIdentity = Get-Task661FileIdentity -Path (
            Join-Path $totalEdge $script:Task661ConfigName
        )
        $totalPass = Invoke-Task661Process -ProjectDir $normalRoot -Arguments @(
            'workspace-migrate', '--action', 'preview', '--preset', 'bugfix',
            '--project-dir', $totalEdge, '--json'
        )
        (ConvertFrom-Task661Json -Result $totalPass).status | Should -BeExactly 'ready'
        (Get-Task661FileIdentity -Path (
                Join-Path $totalEdge $script:Task661ConfigName
            )) | Should -BeExactly $totalIdentity
        $totalOverflow = $totalEdge + 'x'
        $totalReject = Invoke-Task661Process -ProjectDir $normalRoot -Arguments @(
            'workspace-migrate', '--action', 'preview', '--preset', 'bugfix',
            '--project-dir', $totalOverflow, '--json'
        )
        $totalReject.ExitCode | Should -Not -Be 0
        $totalReject.Stderr | Should -Match 'workspace migration rejected\.'

        foreach ($badComponent in @('CON', 'bad.', 'bad ')) {
            $badPath = Join-Path $normalRoot $badComponent
            $bad = Invoke-Task661Process -ProjectDir $normalRoot -Arguments @(
                'workspace-migrate', '--action', 'preview', '--preset', 'bugfix',
                '--project-dir', $badPath, '--json'
            )
            $bad.ExitCode | Should -Not -Be 0
            $bad.Stderr | Should -Match 'workspace migration rejected\.'
        }

        $fixture = New-Task661Project -Name 'wm17-reparse'
        $externalRuntime = Join-Path $TestDrive 'wm17-external-runtime'
        [IO.Directory]::CreateDirectory($externalRuntime) | Out-Null
        New-Item `
            -ItemType Junction `
            -Path $fixture.RuntimePath `
            -Target $externalRuntime | Out-Null
        $reparseConfigIdentity = Get-Task661FileIdentity -Path $fixture.ConfigPath
        $reparse = Invoke-Task661Action -Fixture $fixture -Action apply -Preset bugfix
        $reparse.ExitCode | Should -Not -Be 0
        $reparse.Stderr | Should -Match 'workspace migration rejected\.'
        (Get-Task661FileIdentity -Path $fixture.ConfigPath) |
            Should -BeExactly $reparseConfigIdentity
        Test-Path -LiteralPath $fixture.RuntimePath -PathType Container | Should -BeTrue
        @(Get-ChildItem -LiteralPath $externalRuntime -Force).Count | Should -Be 0
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
    }

    It 'WM18 fails closed when the journal directory cannot be created and removes every transient sink' {
        $fixture = New-Task661Project -Name 'wm18'
        $runtimeBlocker = $fixture.RuntimePath
        [IO.File]::WriteAllText($runtimeBlocker, 'user-owned-blocker', $script:Task661Utf8)
        $configIdentity = Get-Task661FileIdentity -Path $fixture.ConfigPath
        $blockerIdentity = Get-Task661FileIdentity -Path $runtimeBlocker
        $result = Invoke-Task661Action -Fixture $fixture -Action apply -Preset bugfix

        $result.ExitCode | Should -Not -Be 0
        $result.Stdout | Should -BeNullOrEmpty
        $result.Stderr | Should -Match 'workspace migration rejected\.'
        (Get-Task661FileIdentity -Path $fixture.ConfigPath) | Should -BeExactly $configIdentity
        (Get-Task661FileIdentity -Path $runtimeBlocker) | Should -BeExactly $blockerIdentity
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
    }

    It 'WM19 serializes same and different preset concurrent applies into one coherent journal config pair' {
        $same = New-Task661Project -Name 'wm19-same'
        $sameA = Start-Task661Process -ProjectDir $same.ProjectDir -Arguments @(
            'workspace-migrate', '--action', 'apply', '--preset', 'bugfix',
            '--project-dir', $same.ProjectDir, '--json'
        )
        $sameB = Start-Task661Process -ProjectDir $same.ProjectDir -Arguments @(
            'workspace-migrate', '--action', 'apply', '--preset', 'bugfix',
            '--project-dir', $same.ProjectDir, '--json'
        )
        $sameResults = @(
            Complete-Task661Process -Child $sameA
            Complete-Task661Process -Child $sameB
        )
        @($sameResults.ExitCode) | Should -Be @(0, 0)
        $samePayloads = @($sameResults | ForEach-Object { $_.Stdout | ConvertFrom-Json -Depth 30 })
        @($samePayloads.status | Sort-Object) |
            Should -Be @('already_applied', 'applied')
        @($samePayloads.migration_id | Sort-Object -Unique).Count | Should -Be 1
        Test-Path -LiteralPath $same.RuntimePath -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $same.JournalPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $same.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $same.ProjectDir).Count | Should -Be 0

        $different = New-Task661Project -Name 'wm19-different'
        $differentA = Start-Task661Process -ProjectDir $different.ProjectDir -Arguments @(
            'workspace-migrate', '--action', 'apply', '--preset', 'bugfix',
            '--project-dir', $different.ProjectDir, '--json'
        )
        $differentB = Start-Task661Process -ProjectDir $different.ProjectDir -Arguments @(
            'workspace-migrate', '--action', 'apply', '--preset', 'review',
            '--project-dir', $different.ProjectDir, '--json'
        )
        $differentResults = @(
            Complete-Task661Process -Child $differentA
            Complete-Task661Process -Child $differentB
        )
        @($differentResults | Where-Object ExitCode -EQ 0).Count | Should -Be 1
        @($differentResults | Where-Object ExitCode -NE 0).Count | Should -Be 1
        Test-Path -LiteralPath $different.RuntimePath -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $different.JournalPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $different.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $different.ProjectDir).Count | Should -Be 0
        $journal = [IO.File]::ReadAllText($different.JournalPath, $script:Task661Utf8) |
            ConvertFrom-Json -Depth 30
        $journal.target_sha256 | Should -BeExactly (
            Get-Task661Sha256 -Bytes ([IO.File]::ReadAllBytes($different.ConfigPath))
        )
    }

    It 'WM20 keeps private config and invalid markers out of stdout stderr while preserving exact state' {
        $fixture = New-Task661Project -Name 'wm20' -WithPrivateMarker
        $before = Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir
        $preview = Invoke-Task661Action -Fixture $fixture -Action preview -Preset bugfix
        $payload = ConvertFrom-Task661Json -Result $preview
        $payload.status | Should -BeExactly 'ready'
        $preview.Stdout | Should -Not -Match 'wm-private-marker-661|future-private-state'
        $preview.Stderr | Should -Not -Match 'wm-private-marker-661|future-private-state'
        (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before

        $invalid = Invoke-Task661Process -ProjectDir $fixture.ProjectDir -Arguments @(
            'workspace-migrate', '--action', 'preview',
            '--preset', '..\wm-private-marker-661', '--json'
        )
        $invalid.ExitCode | Should -Not -Be 0
        $invalid.Stdout | Should -BeNullOrEmpty
        $invalid.Stderr | Should -Match 'workspace migration rejected\.'
        $invalid.Stderr | Should -Not -Match 'wm-private-marker-661|future-private-state'
        (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
    }

    It 'TB01 recovers every adjacent E00 E01 E02 E03 E04 durable cut at most once' {
        $source = New-Task661Project -Name 'tb01-source'
        $originalBytes = [IO.File]::ReadAllBytes($source.ConfigPath)
        $apply = Get-Task661ApplyIdentity -Fixture $source
        $targetBytes = [IO.File]::ReadAllBytes($source.ConfigPath)
        $journalBytes = [IO.File]::ReadAllBytes($source.JournalPath)

        $runtimeOnly = New-Task661Project -Name 'tb01-runtime-only'
        [IO.Directory]::CreateDirectory($runtimeOnly.RuntimePath) | Out-Null
        $runtimeResume = Invoke-Task661Action `
            -Fixture $runtimeOnly `
            -Action apply `
            -Preset bugfix
        (ConvertFrom-Task661Json -Result $runtimeResume).status | Should -BeExactly 'applied'
        Test-Path -LiteralPath $runtimeOnly.RuntimePath -PathType Container |
            Should -BeTrue
        Test-Path -LiteralPath $runtimeOnly.JournalPath -PathType Leaf | Should -BeTrue

        $journalOnly = New-Task661Project -Name 'tb01-journal-only'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $journalOnly.JournalPath)) |
            Out-Null
        [IO.File]::WriteAllBytes($journalOnly.JournalPath, $journalBytes)
        $resume = Invoke-Task661Action -Fixture $journalOnly -Action apply -Preset bugfix
        (ConvertFrom-Task661Json -Result $resume).status | Should -BeExactly 'applied'
        [IO.File]::ReadAllBytes($journalOnly.ConfigPath) | Should -Be $targetBytes
        [IO.File]::ReadAllBytes($journalOnly.JournalPath) | Should -Be $journalBytes

        [IO.File]::WriteAllBytes($journalOnly.ConfigPath, $originalBytes)
        [IO.File]::WriteAllBytes($journalOnly.JournalPath, $journalBytes)
        $cutRollback = Invoke-Task661Action `
            -Fixture $journalOnly `
            -Action rollback `
            -MigrationId $apply.MigrationId
        (ConvertFrom-Task661Json -Result $cutRollback).status | Should -BeExactly 'rolled_back'
        [IO.File]::ReadAllBytes($journalOnly.ConfigPath) | Should -Be $originalBytes
        Test-Path -LiteralPath $journalOnly.JournalPath | Should -BeFalse

        $targetCut = New-Task661Project -Name 'tb01-target-cut'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $targetCut.JournalPath)) |
            Out-Null
        [IO.File]::WriteAllBytes($targetCut.ConfigPath, $targetBytes)
        [IO.File]::WriteAllBytes($targetCut.JournalPath, $journalBytes)
        $repeat = Invoke-Task661Action -Fixture $targetCut -Action apply -Preset bugfix
        (ConvertFrom-Task661Json -Result $repeat).status | Should -BeExactly 'already_applied'
        [IO.File]::ReadAllBytes($targetCut.ConfigPath) | Should -Be $targetBytes
        [IO.File]::ReadAllBytes($targetCut.JournalPath) | Should -Be $journalBytes

        [IO.File]::WriteAllBytes($targetCut.ConfigPath, $originalBytes)
        $restoredIdentity = Get-Task661FileIdentity -Path $targetCut.ConfigPath
        $finishRollback = Invoke-Task661Action `
            -Fixture $targetCut `
            -Action rollback `
            -MigrationId $apply.MigrationId
        (ConvertFrom-Task661Json -Result $finishRollback).status |
            Should -BeExactly 'rolled_back'
        (Get-Task661FileIdentity -Path $targetCut.ConfigPath) |
            Should -BeExactly $restoredIdentity
        Test-Path -LiteralPath $targetCut.RuntimePath -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $targetCut.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $targetCut.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $targetCut.ProjectDir).Count | Should -Be 0
    }

    It 'TB02 crosses one real child with bounded metadata argv and reads private YAML only from file' {
        $fixture = New-Task661Project -Name 'tb02' -WithPrivateMarker
        $before = Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir
        $arguments = @(
            'workspace-migrate', '--action', 'preview', '--preset', 'bugfix',
            '--project-dir', $fixture.ProjectDir, '--json'
        )
        $argvBytes = $script:Task661Utf8.GetByteCount(($arguments -join "`0"))
        $argvBytes | Should -BeLessOrEqual 16384
        ($arguments -join "`0") | Should -Not -Match 'wm-private-marker-661|future-private-state'
        $child = Start-Task661Process -ProjectDir $fixture.ProjectDir -Arguments $arguments
        $result = Complete-Task661Process -Child $child
        $payload = ConvertFrom-Task661Json -Result $result

        $payload.status | Should -BeExactly 'ready'
        $result.Arguments | Should -BeExactly $arguments
        $result.Stdout | Should -Not -Match 'wm-private-marker-661|future-private-state'
        $result.Stderr | Should -Not -Match 'wm-private-marker-661|future-private-state'
        (Get-Task661ProjectSnapshot -ProjectDir $fixture.ProjectDir) | Should -BeExactly $before
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661TempFiles -ProjectDir $fixture.ProjectDir).Count | Should -Be 0
    }
}
