# TASK-800 Operator shell boundary contract (RED-first, design-v2)
# TASK800_DESIGN_PACKET=v13
# Ownership: TASK-800 only. Does not redesign TASK-810 resolver/CI or TASK-798 TaskCompleted.
# Mechanism (design v2): shared leaf scripts/operator-run-full-tests.ps1 + WINSMUX_TASK800_RUNNER_PATH stub.
# Markers: APPEND only. Doc-grep is auxiliary — each entry has a real outer-shell probe.

Set-StrictMode -Version Latest

Describe 'TASK-800 operator full-test shell boundary (design-v2)' {
    BeforeAll {
        $script:RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) {
            $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        }

        $script:DispatchPath = Join-Path $script:RepoRoot '.claude/rules/dispatch.md'
        $script:CorePath = Join-Path $script:RepoRoot 'scripts/winsmux-core.ps1'
        $script:RunTestsPath = Join-Path $script:RepoRoot 'scripts/run-tests.ps1'
        $script:LeafPath = Join-Path $script:RepoRoot 'scripts/operator-run-full-tests.ps1'
        $script:GitBash = 'C:\Program Files\Git\bin\bash.exe'

        function Get-Task800Section {
            param(
                [Parameter(Mandatory)][string]$Text,
                [Parameter(Mandatory)][string]$Heading
            )
            $escaped = [regex]::Escape($Heading)
            $m = [regex]::Match($Text, "(?ms)^##\s+$escaped\s*\r?\n(?<body>.*?)(?=^##\s+|\z)")
            if (-not $m.Success) { return '' }
            return [string]$m.Groups['body'].Value
        }

        function Get-Task800InvokeVerifyBody {
            param([Parameter(Mandatory)][string]$CoreText)
            $m = [regex]::Match($CoreText, '(?ms)^function\s+Invoke-Verify\s*\{(?<body>.*?)^function\s+\w+')
            if (-not $m.Success) { return '' }
            return [string]$m.Groups['body'].Value
        }

        function New-Task800RunnerStub {
            param(
                [Parameter(Mandatory)][string]$MarkerPath,
                [Parameter(Mandatory)][int]$ExitCode
            )
            $stub = Join-Path ([IO.Path]::GetTempPath()) ('task800-runner-stub-' + [guid]::NewGuid().ToString('N') + '.ps1')
            # APPEND marker (never Set-Content overwrite) so multi-start is detectable.
            $body = @(
                "Add-Content -LiteralPath '$MarkerPath' -Value ('start-' + [guid]::NewGuid().ToString('N')) -Encoding utf8"
                "exit $ExitCode"
            ) -join "`n"
            Set-Content -LiteralPath $stub -Value $body -Encoding utf8
            return $stub
        }

        function Get-Task800MarkerCount {
            param([Parameter(Mandatory)][string]$MarkerPath)
            if (-not (Test-Path -LiteralPath $MarkerPath)) { return 0 }
            $lines = @(Get-Content -LiteralPath $MarkerPath -ErrorAction SilentlyContinue | Where-Object { $_.Trim().Length -gt 0 })
            return $lines.Count
        }

        function Invoke-Task800OuterShellProbe {
            param(
                [Parameter(Mandatory)][ValidateSet('pwsh', 'bash')][string]$Outer,
                [Parameter(Mandatory)][string]$CommandText,
                [Parameter(Mandatory)][string]$MarkerPath,
                [string]$WorkingDirectory = $script:RepoRoot
            )

            $outerExit = $null
            $stdout = ''
            $stderr = ''
            $preEntryError = $false

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.WorkingDirectory = $WorkingDirectory

            if ($Outer -eq 'pwsh') {
                $psi.FileName = (Get-Command pwsh -ErrorAction Stop).Source
                $psi.ArgumentList.Add('-NoProfile')
                $psi.ArgumentList.Add('-NoLogo')
                $psi.ArgumentList.Add('-NonInteractive')
                $psi.ArgumentList.Add('-Command')
                $psi.ArgumentList.Add($CommandText)
            }
            else {
                if (-not (Test-Path -LiteralPath $script:GitBash)) {
                    return [pscustomobject]@{
                        skipped         = $true
                        skip_reason     = 'git_bash_missing'
                        outer_exit      = $null
                        stdout          = ''
                        stderr          = ''
                        pre_entry_error = $true
                        marker_count    = 0
                        bash_path       = $script:GitBash
                    }
                }
                $psi.FileName = $script:GitBash
                # design-v2: bash -c (no -l) to avoid login-profile pre-entry contamination
                $psi.ArgumentList.Add('-c')
                $psi.ArgumentList.Add($CommandText)
            }

            try {
                $p = [System.Diagnostics.Process]::Start($psi)
                $stdout = $p.StandardOutput.ReadToEnd()
                $stderr = $p.StandardError.ReadToEnd()
                $p.WaitForExit()
                $outerExit = $p.ExitCode
            }
            catch {
                $preEntryError = $true
                $stderr = [string]$_
            }

            return [pscustomobject]@{
                skipped         = $false
                skip_reason     = ''
                outer_exit      = $outerExit
                stdout          = $stdout
                stderr          = $stderr
                pre_entry_error = $preEntryError
                marker_count    = (Get-Task800MarkerCount -MarkerPath $MarkerPath)
                bash_path       = $script:GitBash
            }
        }
    }

    Context 'auxiliary source contracts (not sole proof)' {
        It 'aux_builder_section_mentions_shared_leaf_not_direct_invoke_pester' {
            $text = Get-Content -LiteralPath $script:DispatchPath -Raw -Encoding UTF8
            $builder = Get-Task800Section -Text $text -Heading 'Builder Dispatch'
            ($builder -match 'operator-run-full-tests\.ps1|scripts/run-tests\.ps1') | Should -BeTrue
            ($builder -match 'Invoke-Pester') | Should -BeFalse
        }

        It 'aux_post_review_section_mentions_shared_leaf_once' {
            $text = Get-Content -LiteralPath $script:DispatchPath -Raw -Encoding UTF8
            $post = Get-Task800Section -Text $text -Heading 'Post-Review Commit'
            ([regex]::Matches($post, 'operator-run-full-tests\.ps1|scripts/run-tests\.ps1')).Count | Should -BeGreaterThan 0
            ($post -match 'Invoke-Pester') | Should -BeFalse
        }

        It 'aux_invoke_verify_has_no_encodedcommand_direct_pester' {
            $core = Get-Content -LiteralPath $script:CorePath -Raw -Encoding UTF8
            $body = Get-Task800InvokeVerifyBody -CoreText $core
            ([regex]::Matches($body, 'EncodedCommand')).Count | Should -Be 0
            ([regex]::Matches($body, 'Invoke-Pester')).Count | Should -Be 0
            ([regex]::Matches($body, 'run-tests\.ps1|operator-run-full-tests\.ps1')).Count | Should -BeGreaterThan 0
        }
    }

    Context 'real outer-shell probes with injectable runner stub' {
        BeforeAll {
            $script:MarkerPath = Join-Path ([IO.Path]::GetTempPath()) ('task800-marker-' + [guid]::NewGuid().ToString('N') + '.txt')
            $script:StubPath = New-Task800RunnerStub -MarkerPath $script:MarkerPath -ExitCode 7
        }

        AfterAll {
            foreach ($p in @($script:MarkerPath, $script:StubPath)) {
                if ($p -and (Test-Path -LiteralPath $p)) {
                    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'test_shared_leaf_exists_for_shell_boundary_drive' {
            Test-Path -LiteralPath $script:LeafPath |
                Should -BeTrue -Because 'design-v2 requires scripts/operator-run-full-tests.ps1 as shared Builder/Post-Review leaf'
        }

        It 'test_powershell_outer_pre_entry_0_top_level_runner_exact_1_exit_passthrough' {
            Test-Path -LiteralPath $script:LeafPath | Should -BeTrue
            if (Test-Path -LiteralPath $script:MarkerPath) { Remove-Item -LiteralPath $script:MarkerPath -Force }
            $env:WINSMUX_TASK800_RUNNER_PATH = $script:StubPath
            try {
                $cmd = "& { `$env:WINSMUX_TASK800_RUNNER_PATH = '$($script:StubPath)'; & '$($script:LeafPath)' -ResultsDirectory ([IO.Path]::GetTempPath()) }"
                $probe = Invoke-Task800OuterShellProbe -Outer pwsh -CommandText $cmd -MarkerPath $script:MarkerPath
            }
            finally {
                Remove-Item Env:WINSMUX_TASK800_RUNNER_PATH -ErrorAction SilentlyContinue
            }
            $probe.pre_entry_error | Should -BeFalse
            $probe.marker_count | Should -Be 1 -Because 'top-level runner start exact 1 (append marker)'
            $probe.outer_exit | Should -Be 7
        }

        It 'test_git_bash_outer_pre_entry_0_top_level_runner_exact_1_exit_passthrough' {
            Test-Path -LiteralPath $script:LeafPath | Should -BeTrue
            if (Test-Path -LiteralPath $script:MarkerPath) { Remove-Item -LiteralPath $script:MarkerPath -Force }
            # Quote for bash -c calling pwsh -File leaf; stub via env.
            $leafPosix = ($script:LeafPath -replace '\\', '/')
            $stubPosix = ($script:StubPath -replace '\\', '/')
            $marker = $script:MarkerPath
            $cmd = "WINSMUX_TASK800_RUNNER_PATH='$stubPosix' pwsh -NoProfile -NoLogo -NonInteractive -File '$leafPosix' -ResultsDirectory /tmp"
            $probe = Invoke-Task800OuterShellProbe -Outer bash -CommandText $cmd -MarkerPath $marker
            if ($probe.skipped) { throw "Git Bash required: $($probe.skip_reason)" }
            $probe.pre_entry_error | Should -BeFalse
            $probe.marker_count | Should -Be 1
            $probe.outer_exit | Should -Be 7
        }

        It 'test_append_marker_detects_double_top_level_start' {
            if (Test-Path -LiteralPath $script:MarkerPath) { Remove-Item -LiteralPath $script:MarkerPath -Force }
            & $script:StubPath
            & $script:StubPath
            (Get-Task800MarkerCount -MarkerPath $script:MarkerPath) | Should -Be 2 -Because 'overwrite markers cannot prove exact-1'
        }
    }
}
