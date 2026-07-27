$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

BeforeAll {
    $script:Task661AuthorityRepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Task661AuthorityConfigName = '.winsmux.yaml'
    $script:Task661AuthorityJournalRelative = '.winsmux\workspace-migration-v1.json'
    $script:Task661AuthorityLockName = '.winsmux.yaml.lock'
    $script:Task661AuthorityUtf8 = [Text.UTF8Encoding]::new($false, $true)

    if (-not ('Task661DirectoryLeaseProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class Task661DirectoryLeaseProbe
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);
}
'@
    }

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
        Push-Location $script:Task661AuthorityRepoRoot
        try {
            & cargo build --quiet --manifest-path core/Cargo.toml --bin winsmux
            if ($LASTEXITCODE -ne 0) {
                throw "TASK-661 candidate build failed with exit code $LASTEXITCODE."
            }
        } finally {
            Pop-Location
        }
        $script:Task661AuthorityBinary = Join-Path (
            $script:Task661AuthorityRepoRoot
        ) 'target\debug\winsmux.exe'
    } else {
        $script:Task661AuthorityBinary = [IO.Path]::GetFullPath($binaryOverride)
    }
    if (-not (Test-Path -LiteralPath $script:Task661AuthorityBinary -PathType Leaf)) {
        throw "TASK-661 candidate binary is missing: $($script:Task661AuthorityBinary)"
    }

    function Get-Task661AuthoritySha256 {
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [byte[]]$Bytes
        )

        $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)
        return 'sha256:' + (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    }

    function Get-Task661AuthorityFileIdentity {
        param([Parameter(Mandatory = $true)][string]$Path)

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return 'absent'
        }
        $bytes = [IO.File]::ReadAllBytes($Path)
        return '{0}:{1}' -f (
            Get-Task661AuthoritySha256 -Bytes $bytes
        ), $bytes.Length
    }

    function Get-Task661AuthorityProjectSnapshot {
        param([Parameter(Mandatory = $true)][string]$ProjectDir)

        $records = [Collections.Generic.List[string]]::new()
        if (-not (Test-Path -LiteralPath $ProjectDir -PathType Container)) {
            return 'project-absent'
        }
        foreach ($item in @(
                Get-ChildItem -LiteralPath $ProjectDir -Force -Recurse |
                    Sort-Object FullName
            )) {
            $relative = [IO.Path]::GetRelativePath(
                $ProjectDir,
                $item.FullName
            ).Replace('\', '/')
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

    function Get-Task661AuthorityTempFiles {
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

    function Test-Task661AuthorityDirectoryDeleteAccessAvailable {
        param([Parameter(Mandatory = $true)][string]$Path)

        $deleteAccess = [uint32]0x00010000
        $shareReadWriteDelete = [uint32]0x00000007
        $openExisting = [uint32]3
        $backupSemantics = [uint32]0x02000000
        $handle = [Task661DirectoryLeaseProbe]::CreateFile(
            $Path,
            $deleteAccess,
            $shareReadWriteDelete,
            [IntPtr]::Zero,
            $openExisting,
            $backupSemantics,
            [IntPtr]::Zero
        )
        try {
            if (-not $handle.IsInvalid) {
                return $true
            }
            $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($nativeError -eq 32) {
                return $false
            }
            throw [ComponentModel.Win32Exception]::new(
                $nativeError,
                'TASK-661 directory delete-access readiness probe failed.'
            )
        } finally {
            $handle.Dispose()
        }
    }

    function New-Task661AuthorityConfig {
        param([string]$Agent = 'codex')

        return @"
# TASK-661 authority-handoff fixture
config-version: 1
external-operator: true
agent-slots:
  - slot-id: worker-1
    agent: $Agent
    model: provider-default
    model-source: provider-default
    reasoning-effort: provider-default
    prompt-transport: argv
team-profile:
  schema-version: 1
  preset: future-lane-b
future-top-level:
  owner: future
"@
    }

    function New-Task661AuthorityProject {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [string]$Agent = 'codex'
        )

        $projectDir = Join-Path $TestDrive $Name
        [IO.Directory]::CreateDirectory($projectDir) | Out-Null
        $configPath = Join-Path $projectDir $script:Task661AuthorityConfigName
        [IO.File]::WriteAllText(
            $configPath,
            (New-Task661AuthorityConfig -Agent $Agent),
            $script:Task661AuthorityUtf8
        )
        return [PSCustomObject]@{
            ProjectDir = $projectDir
            ConfigPath = $configPath
            RuntimePath = Join-Path $projectDir '.winsmux'
            JournalPath = Join-Path $projectDir $script:Task661AuthorityJournalRelative
            LockPath = Join-Path $projectDir $script:Task661AuthorityLockName
        }
    }

    function Start-Task661AuthorityProcess {
        param(
            [Parameter(Mandatory = $true)][string]$ProjectDir,
            [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments,
            [string]$WorkingDirectory = ''
        )

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:Task661AuthorityBinary
        $startInfo.WorkingDirectory = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $ProjectDir
        } else {
            [IO.Path]::GetFullPath($WorkingDirectory)
        }
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
            throw 'Failed to start TASK-661 authority public child process.'
        }
        return [PSCustomObject]@{
            Process = $process
            Arguments = @($Arguments)
        }
    }

    function Complete-Task661AuthorityProcess {
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
            throw 'TASK-661 authority public child process timed out.'
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

    function Invoke-Task661AuthorityProcess {
        param(
            [Parameter(Mandatory = $true)][string]$ProjectDir,
            [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments
        )

        $child = Start-Task661AuthorityProcess `
            -ProjectDir $ProjectDir `
            -Arguments $Arguments
        return Complete-Task661AuthorityProcess -Child $child
    }

    function ConvertFrom-Task661AuthorityJson {
        param([Parameter(Mandatory = $true)]$Result)

        $Result.ExitCode | Should -Be 0
        $Result.Stderr | Should -BeNullOrEmpty
        return $Result.Stdout | ConvertFrom-Json -Depth 50
    }

    function Invoke-Task661AuthorityAction {
        param(
            [Parameter(Mandatory = $true)]$Fixture,
            [Parameter(Mandatory = $true)]
            [ValidateSet('preview', 'apply', 'rollback')]
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
        $arguments.Add('--project-dir') | Out-Null
        $arguments.Add($Fixture.ProjectDir) | Out-Null
        $arguments.Add('--json') | Out-Null
        return Invoke-Task661AuthorityProcess `
            -ProjectDir $Fixture.ProjectDir `
            -Arguments $arguments.ToArray()
    }

    function Get-Task661AuthorityApplyIdentity {
        param([Parameter(Mandatory = $true)]$Fixture)

        $result = Invoke-Task661AuthorityAction `
            -Fixture $Fixture `
            -Action apply `
            -Preset bugfix
        $payload = ConvertFrom-Task661AuthorityJson -Result $result
        [string]$payload.migration_id | Should -Match '^[0-9a-f]{64}$'
        return [PSCustomObject]@{
            MigrationId = [string]$payload.migration_id
        }
    }

    function Write-Task661AuthorityForgedJournal {
        param(
            [Parameter(Mandatory = $true)]$Fixture,
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [byte[]]$OriginalBytes,
            [Parameter(Mandatory = $true)][bool]$OriginalExisted,
            [Parameter(Mandatory = $true)][string]$MigrationId
        )

        $forgedTargetBytes = [IO.File]::ReadAllBytes($Fixture.ConfigPath)
        [IO.Directory]::CreateDirectory($Fixture.RuntimePath) | Out-Null
        $journal = [ordered]@{
            schema_version = 1
            migration_id = $MigrationId
            preset_id = 'bugfix'
            original_existed = $OriginalExisted
            original_base64 = [Convert]::ToBase64String($OriginalBytes)
            source_sha256 = Get-Task661AuthoritySha256 -Bytes $OriginalBytes
            target_sha256 = Get-Task661AuthoritySha256 -Bytes $forgedTargetBytes
        }
        [IO.File]::WriteAllText(
            $Fixture.JournalPath,
            (($journal | ConvertTo-Json -Compress) + "`n"),
            $script:Task661AuthorityUtf8
        )
    }

    function Invoke-Task661AuthorityRootReplacement {
        param(
            [Parameter(Mandatory = $true)]$Fixture,
            [Parameter(Mandatory = $true)]$Replacement,
            [Parameter(Mandatory = $true)][string[]]$Arguments
        )

        $selectedConfigBefore = Get-Task661AuthorityFileIdentity -Path $Fixture.ConfigPath
        $replacementBefore = Get-Task661AuthorityProjectSnapshot `
            -ProjectDir $Replacement.ProjectDir
        [IO.Directory]::CreateDirectory($Fixture.LockPath) | Out-Null
        if (-not (
                Test-Task661AuthorityDirectoryDeleteAccessAvailable `
                    -Path $Fixture.ProjectDir
            )) {
            throw 'TASK-661 root-replacement fixture starts with delete access blocked.'
        }
        $ownerPath = Join-Path $Fixture.LockPath 'owner.json'
        [IO.File]::WriteAllText(
            $ownerPath,
            (([ordered]@{
                        pid = $PID
                        started_at = '2026-07-27T00:00:00Z'
                    } | ConvertTo-Json -Compress) + "`n"),
            $script:Task661AuthorityUtf8
        )

        $movedOriginal = $Fixture.ProjectDir + '-original'
        $child = $null
        $moved = $false
        $junctionCreated = $false
        $leaseObserved = $false
        try {
            $child = Start-Task661AuthorityProcess `
                -ProjectDir $Fixture.ProjectDir `
                -Arguments $Arguments `
                -WorkingDirectory (Split-Path -Parent $Fixture.ProjectDir)
            $readinessDeadline = [DateTime]::UtcNow.AddSeconds(20)
            while ([DateTime]::UtcNow -lt $readinessDeadline) {
                if ($child.Process.HasExited) {
                    throw 'TASK-661 root-replacement child exited before the held lock.'
                }
                if (-not (
                        Test-Task661AuthorityDirectoryDeleteAccessAvailable `
                            -Path $Fixture.ProjectDir
                    )) {
                    $leaseObserved = $true
                    break
                }
                Start-Sleep -Milliseconds 50
            }
            try {
                Move-Item `
                    -LiteralPath $Fixture.ProjectDir `
                    -Destination $movedOriginal `
                    -ErrorAction Stop
                $moved = $true
            } catch {
            }
            if ($moved) {
                New-Item `
                    -ItemType Junction `
                    -Path $Fixture.ProjectDir `
                    -Target $Replacement.ProjectDir | Out-Null
                $junctionCreated = $true
            } else {
                for ($attempt = 0; $attempt -lt 20; $attempt++) {
                    if (Test-Path -LiteralPath $ownerPath -PathType Leaf) {
                        [IO.File]::Delete($ownerPath)
                    }
                    try {
                        if (Test-Path -LiteralPath $Fixture.LockPath -PathType Container) {
                            [IO.Directory]::Delete($Fixture.LockPath)
                        }
                    } catch {
                        Start-Sleep -Milliseconds 50
                        continue
                    }
                    break
                }
                if (Test-Path -LiteralPath $Fixture.LockPath -PathType Container) {
                    throw 'TASK-661 could not release the held root-replacement lock.'
                }
            }

            $result = Complete-Task661AuthorityProcess -Child $child
            $child = $null
            $selectedConfigPath = if ($moved) {
                Join-Path $movedOriginal $script:Task661AuthorityConfigName
            } else {
                $Fixture.ConfigPath
            }
            return [PSCustomObject]@{
                Moved = $moved
                LeaseObserved = $leaseObserved
                Result = $result
                SelectedConfigBefore = $selectedConfigBefore
                SelectedConfigAfter = Get-Task661AuthorityFileIdentity `
                    -Path $selectedConfigPath
                ReplacementBefore = $replacementBefore
                ReplacementConfigAfter = Get-Task661AuthorityProjectSnapshot `
                    -ProjectDir $Replacement.ProjectDir
            }
        } finally {
            if ($null -ne $child) {
                if (-not $child.Process.HasExited) {
                    $child.Process.Kill($true)
                    $child.Process.WaitForExit()
                }
                $child.Process.Dispose()
            }
            if ($junctionCreated -and
                (Test-Path -LiteralPath $Fixture.ProjectDir -PathType Container)) {
                [IO.Directory]::Delete($Fixture.ProjectDir)
            }
            if (-not $moved) {
                if (Test-Path -LiteralPath $ownerPath -PathType Leaf) {
                    [IO.File]::Delete($ownerPath)
                }
                if (Test-Path -LiteralPath $Fixture.LockPath -PathType Container) {
                    [IO.Directory]::Delete($Fixture.LockPath)
                }
            }
        }
    }
}

Describe 'TASK-661 authority handoff closure' {
    It 'WM21 rejects semantically forged journal targets for apply rollback and original-absence siblings before sinks' {
        $forged = New-Task661AuthorityProject -Name 'wm21-forged-existing'
        $forgedTargetBytes = [IO.File]::ReadAllBytes($forged.ConfigPath)
        $attackerBytes = $script:Task661AuthorityUtf8.GetBytes(
            "attacker-selected: replacement`n"
        )
        $forgedId = 'a' * 64
        Write-Task661AuthorityForgedJournal `
            -Fixture $forged `
            -OriginalBytes $attackerBytes `
            -OriginalExisted $true `
            -MigrationId $forgedId
        $forgedBefore = Get-Task661AuthorityProjectSnapshot `
            -ProjectDir $forged.ProjectDir
        $applyResult = Invoke-Task661AuthorityAction `
            -Fixture $forged `
            -Action apply `
            -Preset bugfix
        $rollbackResult = Invoke-Task661AuthorityAction `
            -Fixture $forged `
            -Action rollback `
            -MigrationId $forgedId
        $forgedAfter = Get-Task661AuthorityProjectSnapshot `
            -ProjectDir $forged.ProjectDir

        $absent = New-Task661AuthorityProject -Name 'wm21-forged-absent'
        $absentId = 'b' * 64
        Write-Task661AuthorityForgedJournal `
            -Fixture $absent `
            -OriginalBytes ([byte[]]::new(0)) `
            -OriginalExisted $false `
            -MigrationId $absentId
        $forgedAbsentJournal = Get-Task661AuthorityFileIdentity `
            -Path $absent.JournalPath
        $absentBefore = Get-Task661AuthorityProjectSnapshot `
            -ProjectDir $absent.ProjectDir
        $absentRollback = Invoke-Task661AuthorityAction `
            -Fixture $absent `
            -Action rollback `
            -MigrationId $absentId
        $absentAfter = Get-Task661AuthorityProjectSnapshot `
            -ProjectDir $absent.ProjectDir

        $forgedTargetBytes.Length | Should -BeGreaterThan 0
        $forgedAbsentJournal | Should -Not -BeExactly 'absent'
        $applyResult.ExitCode | Should -Not -Be 0
        $rollbackResult.ExitCode | Should -Not -Be 0
        $absentRollback.ExitCode | Should -Not -Be 0
        $applyResult.Stdout | Should -BeNullOrEmpty
        $rollbackResult.Stdout | Should -BeNullOrEmpty
        $absentRollback.Stdout | Should -BeNullOrEmpty
        $forgedAfter | Should -BeExactly $forgedBefore
        $absentAfter | Should -BeExactly $absentBefore
        Test-Path -LiteralPath $forged.RuntimePath -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $forged.JournalPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $absent.JournalPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $forged.LockPath | Should -BeFalse
        Test-Path -LiteralPath $absent.LockPath | Should -BeFalse
        @(Get-Task661AuthorityTempFiles -ProjectDir $forged.ProjectDir).Count |
            Should -Be 0
        @(Get-Task661AuthorityTempFiles -ProjectDir $absent.ProjectDir).Count |
            Should -Be 0
    }

    It 'WM22 holds one project-root capability across lock wait for apply and rollback without redirecting sinks' {
        $applyFixture = New-Task661AuthorityProject -Name 'wm22-apply-selected'
        $applyReplacement = New-Task661AuthorityProject -Name 'wm22-apply-replacement'
        $applyCase = Invoke-Task661AuthorityRootReplacement `
            -Fixture $applyFixture `
            -Replacement $applyReplacement `
            -Arguments @(
                'workspace-migrate', '--action', 'apply', '--preset', 'bugfix',
                '--project-dir', $applyFixture.ProjectDir, '--json'
            )

        $rollbackFixture = New-Task661AuthorityProject -Name 'wm22-rollback-selected'
        $rollbackOriginalBytes = [IO.File]::ReadAllBytes($rollbackFixture.ConfigPath)
        $rollbackIdentity = Get-Task661AuthorityApplyIdentity -Fixture $rollbackFixture
        $rollbackReplacement = New-Task661AuthorityProject `
            -Name 'wm22-rollback-replacement'
        [IO.File]::WriteAllBytes(
            $rollbackReplacement.ConfigPath,
            [IO.File]::ReadAllBytes($rollbackFixture.ConfigPath)
        )
        [IO.Directory]::CreateDirectory($rollbackReplacement.RuntimePath) | Out-Null
        [IO.File]::WriteAllBytes(
            $rollbackReplacement.JournalPath,
            [IO.File]::ReadAllBytes($rollbackFixture.JournalPath)
        )
        $rollbackCase = Invoke-Task661AuthorityRootReplacement `
            -Fixture $rollbackFixture `
            -Replacement $rollbackReplacement `
            -Arguments @(
                'workspace-migrate', '--action', 'rollback',
                '--migration-id', $rollbackIdentity.MigrationId,
                '--project-dir', $rollbackFixture.ProjectDir, '--json'
            )

        $selectedConfigAfter = $applyCase.SelectedConfigAfter
        $replacementConfigAfter = $applyCase.ReplacementConfigAfter
        $applyCase.LeaseObserved | Should -BeTrue
        $rollbackCase.LeaseObserved | Should -BeTrue
        $applyCase.Moved | Should -BeFalse
        $rollbackCase.Moved | Should -BeFalse
        $applyCase.Result.ExitCode | Should -Be 0
        $rollbackCase.Result.ExitCode | Should -Be 0
        (ConvertFrom-Task661AuthorityJson -Result $applyCase.Result).status |
            Should -BeExactly 'applied'
        (ConvertFrom-Task661AuthorityJson -Result $rollbackCase.Result).status |
            Should -BeExactly 'rolled_back'
        $applyCase.SelectedConfigAfter |
            Should -Not -BeExactly $applyCase.SelectedConfigBefore
        $applyCase.ReplacementConfigAfter |
            Should -BeExactly $applyCase.ReplacementBefore
        $rollbackCase.ReplacementConfigAfter |
            Should -BeExactly $rollbackCase.ReplacementBefore
        [IO.File]::ReadAllBytes($rollbackFixture.ConfigPath) |
            Should -Be $rollbackOriginalBytes
        Test-Path -LiteralPath $rollbackFixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $applyFixture.LockPath | Should -BeFalse
        Test-Path -LiteralPath $rollbackFixture.LockPath | Should -BeFalse
        @(Get-Task661AuthorityTempFiles -ProjectDir $applyFixture.ProjectDir).Count |
            Should -Be 0
        @(Get-Task661AuthorityTempFiles -ProjectDir $rollbackFixture.ProjectDir).Count |
            Should -Be 0
        $selectedConfigAfter | Should -Not -BeNullOrEmpty
        $replacementConfigAfter | Should -Not -BeNullOrEmpty
    }

    It 'WM23 uses canonical workspace-plan provider capabilities for preview and apply applicability' {
        $fixture = New-Task661AuthorityProject `
            -Name 'wm23-migration' `
            -Agent openrouter
        $before = Get-Task661AuthorityProjectSnapshot -ProjectDir $fixture.ProjectDir
        $previewResult = Invoke-Task661AuthorityAction `
            -Fixture $fixture `
            -Action preview `
            -Preset bugfix
        $preview = ConvertFrom-Task661AuthorityJson -Result $previewResult
        $applyResult = Invoke-Task661AuthorityAction `
            -Fixture $fixture `
            -Action apply `
            -Preset bugfix
        $after = Get-Task661AuthorityProjectSnapshot -ProjectDir $fixture.ProjectDir

        $planFixture = New-Task661AuthorityProject `
            -Name 'wm23-workspace-plan' `
            -Agent openrouter
        [IO.File]::AppendAllText(
            $planFixture.ConfigPath,
            [string]$preview.proposal_yaml,
            $script:Task661AuthorityUtf8
        )
        $workspacePlan = Invoke-Task661AuthorityProcess `
            -ProjectDir $planFixture.ProjectDir `
            -Arguments @(
                'workspace-plan', '--recipe-id', 'bugfix',
                '--workflow-id', 'bugfix',
                '--project-dir', $planFixture.ProjectDir, '--json'
            )

        $workspacePlan.ExitCode | Should -Not -Be 0
        $preview.status | Should -BeExactly 'unsupported'
        @($preview.unsupported_codes) | Should -Be @('effective_slots_not_supported')
        $applyResult.ExitCode | Should -Not -Be 0
        $after | Should -BeExactly $before
        Test-Path -LiteralPath $fixture.RuntimePath | Should -BeFalse
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661AuthorityTempFiles -ProjectDir $fixture.ProjectDir).Count |
            Should -Be 0
    }

    It 'WM24 preserves unknown leading and command-local target tokens for strict rejection while accepting documented global prefix' {
        $fixture = New-Task661AuthorityProject -Name 'wm24'
        $before = Get-Task661AuthorityProjectSnapshot -ProjectDir $fixture.ProjectDir
        $globalPrefixControl = Invoke-Task661AuthorityProcess `
            -ProjectDir $fixture.ProjectDir `
            -Arguments @(
                '-t', 'ignored', 'workspace-migrate',
                '--action', 'list', '--json'
            )
        $unknownLeadingOption = Invoke-Task661AuthorityProcess `
            -ProjectDir $fixture.ProjectDir `
            -Arguments @(
                '--surplus', 'workspace-migrate',
                '--action', 'list', '--json'
            )
        $postCommandTarget = Invoke-Task661AuthorityProcess `
            -ProjectDir $fixture.ProjectDir `
            -Arguments @(
                'workspace-migrate', '-t', 'ignored',
                '--action', 'list', '--json'
            )

        (ConvertFrom-Task661AuthorityJson -Result $globalPrefixControl).status |
            Should -BeExactly 'listed'
        $unknownLeadingOption.ExitCode | Should -Not -Be 0
        $postCommandTarget.ExitCode | Should -Not -Be 0
        $unknownLeadingOption.Stdout | Should -BeNullOrEmpty
        $postCommandTarget.Stdout | Should -BeNullOrEmpty
        (Get-Task661AuthorityProjectSnapshot -ProjectDir $fixture.ProjectDir) |
            Should -BeExactly $before
        Test-Path -LiteralPath $fixture.RuntimePath | Should -BeFalse
        Test-Path -LiteralPath $fixture.JournalPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse
        @(Get-Task661AuthorityTempFiles -ProjectDir $fixture.ProjectDir).Count |
            Should -Be 0
    }
}
