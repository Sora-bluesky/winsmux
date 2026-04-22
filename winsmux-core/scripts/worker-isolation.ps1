[CmdletBinding()]
param()

function Get-WinsmuxWorkerIsolationProperty {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) {
            return $Value[$Name]
        }

        return $null
    }

    if ($null -ne $Value.PSObject -and $Value.PSObject.Properties.Name -contains $Name) {
        return $Value.$Name
    }

    return $null
}

function Test-WinsmuxWorkerIsolationProperty {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return $Value.Contains($Name)
    }

    return ($null -ne $Value.PSObject -and $Value.PSObject.Properties.Name -contains $Name)
}

function Resolve-WinsmuxWorkerIsolationPath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [AllowEmptyString()][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $expanded))
}

function ConvertTo-WinsmuxWorkerIsolationSafeOrigin {
    param([AllowEmptyString()][string]$Origin)

    if ([string]::IsNullOrWhiteSpace($Origin)) {
        return ''
    }

    $trimmed = $Origin.Trim()
    $trimmed = [regex]::Replace($trimmed, '^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]+@', '$1[redacted]@')
    return [regex]::Replace($trimmed, '^[^/@\s]+@([^:\s]+:.+)$', '[redacted]@$1')
}

function ConvertTo-WinsmuxWorkerIsolationComparableOrigin {
    param([AllowEmptyString()][string]$Origin)

    if ([string]::IsNullOrWhiteSpace($Origin)) {
        return ''
    }

    $trimmed = $Origin.Trim()
    $trimmed = [regex]::Replace($trimmed, '^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]+@', '$1')
    return [regex]::Replace($trimmed, '^[^/@\s]+@([^:\s]+:.+)$', '$1')
}

function Test-WinsmuxWorkerIsolationPaneEntry {
    param([AllowNull()]$Pane)

    if ($null -eq $Pane) {
        return $false
    }

    $role = [string](Get-WinsmuxWorkerIsolationProperty -Value $Pane -Name 'role')
    if ($role -ieq 'Worker' -or $role -ieq 'Builder') {
        return $true
    }

    $worktreePath = [string](Get-WinsmuxWorkerIsolationProperty -Value $Pane -Name 'builder_worktree_path')
    if (-not [string]::IsNullOrWhiteSpace($worktreePath)) {
        return $true
    }

    return $false
}

function Get-WinsmuxWorkerIsolationPaneLabel {
    param(
        [AllowNull()]$Pane,
        [AllowEmptyString()][string]$Fallback
    )

    $label = [string](Get-WinsmuxWorkerIsolationProperty -Value $Pane -Name 'label')
    if (-not [string]::IsNullOrWhiteSpace($label)) {
        return $label
    }

    return $Fallback
}

function Get-WinsmuxWorkerIsolationPaneEntries {
    param([AllowNull()]$Manifest)

    $entries = [System.Collections.Generic.List[object]]::new()
    $panes = Get-WinsmuxWorkerIsolationProperty -Value $Manifest -Name 'panes'
    if ($null -eq $panes) {
        return @()
    }

    if ($panes -is [System.Collections.IDictionary]) {
        foreach ($key in $panes.Keys) {
            $pane = $panes[$key]
            if (Test-WinsmuxWorkerIsolationPaneEntry -Pane $pane) {
                $entries.Add([PSCustomObject]@{
                    Label = Get-WinsmuxWorkerIsolationPaneLabel -Pane $pane -Fallback ([string]$key)
                    Pane  = $pane
                }) | Out-Null
            }
        }

        return @($entries)
    }

    if ($panes -is [System.Collections.IEnumerable] -and -not ($panes -is [string])) {
        $index = 0
        foreach ($pane in @($panes)) {
            $index++
            if (Test-WinsmuxWorkerIsolationPaneEntry -Pane $pane) {
                $entries.Add([PSCustomObject]@{
                    Label = Get-WinsmuxWorkerIsolationPaneLabel -Pane $pane -Fallback "pane-$index"
                    Pane  = $pane
                }) | Out-Null
            }
        }

        return @($entries)
    }

    foreach ($property in $panes.PSObject.Properties) {
        $pane = $property.Value
        if (Test-WinsmuxWorkerIsolationPaneEntry -Pane $pane) {
            $entries.Add([PSCustomObject]@{
                Label = Get-WinsmuxWorkerIsolationPaneLabel -Pane $pane -Fallback ([string]$property.Name)
                Pane  = $pane
            }) | Out-Null
        }
    }

    return @($entries)
}

function Invoke-WinsmuxWorkerIsolationGit {
    param(
        [Parameter(Mandatory = $true)][string]$GitPath,
        [Parameter(Mandatory = $true)][string]$WorktreePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [AllowNull()][scriptblock]$GitInvoker = $null
    )

    try {
        if ($null -ne $GitInvoker) {
            $output = & $GitInvoker -WorktreePath $WorktreePath -Arguments $Arguments 2>&1
            $exitCode = 0
        } else {
            $output = & $GitPath -C $WorktreePath @Arguments 2>&1
            $exitCode = $LASTEXITCODE
        }

        return [PSCustomObject]@{
            Ok     = ($exitCode -eq 0)
            Output = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
            Error  = ''
        }
    } catch {
        return [PSCustomObject]@{
            Ok     = $false
            Output = ''
            Error  = $_.Exception.Message
        }
    }
}

function Add-WinsmuxWorkerIsolationFinding {
    param(
        [Parameter(Mandatory = $true)]$Findings,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $Findings.Add([PSCustomObject]@{
        label   = $Label
        message = $Message
    }) | Out-Null
}

function Get-WinsmuxWorkerIsolationReport {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [AllowNull()]$Manifest,
        [AllowEmptyString()][string]$GitPath = '',
        [AllowNull()][scriptblock]$GitInvoker = $null
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $workers = [System.Collections.Generic.List[object]]::new()
    $workerEntries = @(Get-WinsmuxWorkerIsolationPaneEntries -Manifest $Manifest)

    if ($workerEntries.Count -eq 0) {
        return [PSCustomObject]@{
            ok          = $true
            status      = 'pass'
            worker_count = 0
            findings    = @()
            workers     = @()
            summary     = '0 worker panes in manifest'
            remediation = ''
        }
    }

    if ([string]::IsNullOrWhiteSpace($GitPath)) {
        Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label 'git' -Message 'git executable not found'
    }

    foreach ($entry in $workerEntries) {
        $pane = $entry.Pane
        $label = [string]$entry.Label
        $launchDir = [string](Get-WinsmuxWorkerIsolationProperty -Value $pane -Name 'launch_dir')
        $worktreePathRaw = [string](Get-WinsmuxWorkerIsolationProperty -Value $pane -Name 'builder_worktree_path')
        $branchExpected = [string](Get-WinsmuxWorkerIsolationProperty -Value $pane -Name 'builder_branch')
        $gitDirExpectedRaw = [string](Get-WinsmuxWorkerIsolationProperty -Value $pane -Name 'worktree_git_dir')
        $originExpected = [string](Get-WinsmuxWorkerIsolationProperty -Value $pane -Name 'expected_origin')
        $hasGitDirExpected = Test-WinsmuxWorkerIsolationProperty -Value $pane -Name 'worktree_git_dir'
        $hasOriginExpected = Test-WinsmuxWorkerIsolationProperty -Value $pane -Name 'expected_origin'

        $worktreePath = Resolve-WinsmuxWorkerIsolationPath -BasePath $ProjectDir -Path $worktreePathRaw
        $launchPath = Resolve-WinsmuxWorkerIsolationPath -BasePath $ProjectDir -Path $launchDir
        $gitDirExpected = Resolve-WinsmuxWorkerIsolationPath -BasePath $ProjectDir -Path $gitDirExpectedRaw

        if ([string]::IsNullOrWhiteSpace($worktreePath)) {
            Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message 'builder_worktree_path is missing'
        }

        if ([string]::IsNullOrWhiteSpace($launchPath)) {
            Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message 'launch_dir is missing'
        } elseif (-not [string]::IsNullOrWhiteSpace($worktreePath) -and $launchPath -ne $worktreePath) {
            Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message "launch_dir is $launchPath; expected $worktreePath"
        }

        if ([string]::IsNullOrWhiteSpace($branchExpected)) {
            Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message 'builder_branch is missing'
        }

        if (-not [string]::IsNullOrWhiteSpace($worktreePath) -and -not (Test-Path -LiteralPath $worktreePath -PathType Container)) {
            Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message "assigned worktree does not exist: $worktreePath"
        }

        $actualRoot = ''
        $actualBranch = ''
        $actualOrigin = ''
        $actualGitDir = ''

        if (-not [string]::IsNullOrWhiteSpace($GitPath) -and
            -not [string]::IsNullOrWhiteSpace($worktreePath) -and
            (Test-Path -LiteralPath $worktreePath -PathType Container)) {
            $rootProbe = Invoke-WinsmuxWorkerIsolationGit -GitPath $GitPath -WorktreePath $worktreePath -Arguments @('rev-parse', '--show-toplevel') -GitInvoker $GitInvoker
            if ($rootProbe.Ok) {
                $actualRoot = Resolve-WinsmuxWorkerIsolationPath -BasePath $ProjectDir -Path $rootProbe.Output
                if ($actualRoot -ne $worktreePath) {
                    Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message "git root is $actualRoot; expected $worktreePath"
                }
            } else {
                Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message "git root probe failed: $($rootProbe.Error)$($rootProbe.Output)"
            }

            $branchProbe = Invoke-WinsmuxWorkerIsolationGit -GitPath $GitPath -WorktreePath $worktreePath -Arguments @('branch', '--show-current') -GitInvoker $GitInvoker
            if ($branchProbe.Ok) {
                $actualBranch = $branchProbe.Output.Trim()
                if (-not [string]::IsNullOrWhiteSpace($branchExpected) -and $actualBranch -ne $branchExpected) {
                    Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message "branch is $actualBranch; expected $branchExpected"
                }
            } else {
                Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message "branch probe failed: $($branchProbe.Error)$($branchProbe.Output)"
            }

            if ($hasOriginExpected) {
                $originProbe = Invoke-WinsmuxWorkerIsolationGit -GitPath $GitPath -WorktreePath $worktreePath -Arguments @('config', '--get', 'remote.origin.url') -GitInvoker $GitInvoker
                if ($originProbe.Ok) {
                    $actualOrigin = $originProbe.Output.Trim()
                    $actualOriginComparable = ConvertTo-WinsmuxWorkerIsolationComparableOrigin -Origin $actualOrigin
                    $originExpectedComparable = ConvertTo-WinsmuxWorkerIsolationComparableOrigin -Origin $originExpected
                    if ($actualOriginComparable -ne $originExpectedComparable) {
                        $safeActualOrigin = ConvertTo-WinsmuxWorkerIsolationSafeOrigin -Origin $actualOrigin
                        $safeExpectedOrigin = ConvertTo-WinsmuxWorkerIsolationSafeOrigin -Origin $originExpected
                        if ([string]::IsNullOrWhiteSpace($safeExpectedOrigin)) {
                            Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message "origin is $safeActualOrigin; expected no origin"
                        } else {
                            Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message "origin is $safeActualOrigin; expected $safeExpectedOrigin"
                        }
                    }
                } elseif (-not [string]::IsNullOrWhiteSpace($originExpected)) {
                    Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message "origin probe failed: $($originProbe.Error)$($originProbe.Output)"
                }
            }

            if ($hasGitDirExpected) {
                if ([string]::IsNullOrWhiteSpace($gitDirExpected)) {
                    Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message 'worktree_git_dir is empty'
                } else {
                    $gitDirProbe = Invoke-WinsmuxWorkerIsolationGit -GitPath $GitPath -WorktreePath $worktreePath -Arguments @('rev-parse', '--git-dir') -GitInvoker $GitInvoker
                    if ($gitDirProbe.Ok) {
                        $actualGitDir = Resolve-WinsmuxWorkerIsolationPath -BasePath $worktreePath -Path $gitDirProbe.Output
                        if ($actualGitDir -ne $gitDirExpected) {
                            Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message "gitdir is $actualGitDir; expected $gitDirExpected"
                        }
                    } else {
                        Add-WinsmuxWorkerIsolationFinding -Findings $findings -Label $label -Message "gitdir probe failed: $($gitDirProbe.Error)$($gitDirProbe.Output)"
                    }
                }
            }
        }

        $workers.Add([PSCustomObject]@{
            label             = $label
            launch_dir        = $launchPath
            assigned_worktree = $worktreePath
            expected_branch   = $branchExpected
            actual_branch     = $actualBranch
            expected_origin   = (ConvertTo-WinsmuxWorkerIsolationSafeOrigin -Origin $originExpected)
            actual_origin     = (ConvertTo-WinsmuxWorkerIsolationSafeOrigin -Origin $actualOrigin)
            expected_gitdir   = $gitDirExpected
            actual_gitdir     = $actualGitDir
            actual_root       = $actualRoot
        }) | Out-Null
    }

    $ok = ($findings.Count -eq 0)
    $summary = if ($ok) {
        "$($workerEntries.Count) worker pane(s) isolated"
    } else {
        "$($findings.Count) worker isolation issue(s)"
    }

    return [PSCustomObject]@{
        ok          = $ok
        status      = $(if ($ok) { 'pass' } else { 'fail' })
        worker_count = $workerEntries.Count
        findings    = @($findings)
        workers     = @($workers)
        summary     = $summary
        remediation = $(if ($ok) { '' } else { 'Keep edits and tests in the assigned worker worktree. Run git add, git commit, git push, and PR merge from the Operator shell.' })
    }
}
