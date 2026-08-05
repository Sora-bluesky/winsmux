$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

BeforeAll {
    function Wait-ForCondition {
        param(
            [scriptblock]$Condition,
            [int]$TimeoutSeconds
        )

        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([datetime]::UtcNow -lt $deadline) {
            if (& $Condition) {
                return $true
            }
            Start-Sleep -Milliseconds 500
        }

        return $false
    }

    $script:AppExePath = $env:WINSMUX_DBGGATE_APP_EXE
    if ([string]::IsNullOrWhiteSpace($script:AppExePath)) {
        throw 'WINSMUX_DBGGATE_APP_EXE is required and must not be empty.'
    }
    if (-not (Test-Path -LiteralPath $script:AppExePath)) {
        throw "WINSMUX_DBGGATE_APP_EXE path does not exist: $($script:AppExePath)"
    }

    $portRaw = $env:WINSMUX_DBGGATE_PORT
    if ([string]::IsNullOrWhiteSpace($portRaw)) {
        throw 'WINSMUX_DBGGATE_PORT is required and must not be empty.'
    }
    $script:DebugPort = [int]$portRaw
    if ($script:DebugPort -lt 1024 -or $script:DebugPort -gt 65535) {
        throw "WINSMUX_DBGGATE_PORT must be in 1024..65535; got $($script:DebugPort)"
    }

    function Test-IsDescendantOf {
        param(
            [int]$CandidatePid,
            [int]$RootPid
        )

        if ($CandidatePid -le 0 -or $RootPid -le 0) {
            return $false
        }
        if ($CandidatePid -eq $RootPid) {
            return $true
        }

        $seen = @{}
        $current = $CandidatePid
        while ($current -gt 0 -and -not $seen.ContainsKey($current)) {
            $seen[$current] = $true
            if ($current -eq $RootPid) {
                return $true
            }
            $row = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $current" -ErrorAction SilentlyContinue
            if ($null -eq $row -or $null -eq $row.ParentProcessId) {
                return $false
            }
            $current = [int]$row.ParentProcessId
        }

        return $false
    }

    function Stop-ProcessTree {
        param(
            [int]$RootPid
        )

        if ($RootPid -le 0) {
            return
        }

        $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
        if ($all.Count -eq 0) {
            Stop-Process -Id $RootPid -Force -ErrorAction SilentlyContinue
            return
        }

        $byParent = @{}
        foreach ($proc in $all) {
            $ppid = [int]$proc.ParentProcessId
            if (-not $byParent.ContainsKey($ppid)) {
                $byParent[$ppid] = [System.Collections.Generic.List[int]]::new()
            }
            $byParent[$ppid].Add([int]$proc.ProcessId)
        }

        $ordered = [System.Collections.Generic.List[int]]::new()
        $stack = [System.Collections.Generic.Stack[int]]::new()
        $stack.Push($RootPid)
        $visited = @{}

        while ($stack.Count -gt 0) {
            $nodePid = $stack.Pop()
            if ($visited.ContainsKey($nodePid)) {
                continue
            }
            $visited[$nodePid] = $true
            $ordered.Add($nodePid)
            if ($byParent.ContainsKey($nodePid)) {
                foreach ($child in $byParent[$nodePid]) {
                    if (-not $visited.ContainsKey($child)) {
                        $stack.Push($child)
                    }
                }
            }
        }

        for ($i = $ordered.Count - 1; $i -ge 0; $i--) {
            $killPid = $ordered[$i]
            if ($killPid -ne $RootPid) {
                Stop-Process -Id $killPid -Force -ErrorAction SilentlyContinue
            }
        }
        Stop-Process -Id $RootPid -Force -ErrorAction SilentlyContinue
    }
}

Describe 'V0.36.30 desktop debug gate process contract' {
    It 'opens the CDP endpoint on the requested port when the gate variables are set' {
        $userDataDir = Join-Path $env:TEMP ("winsmux-dbggate-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:AppExePath
        $psi.UseShellExecute = $false
        $psi.Environment['WEBVIEW2_USER_DATA_FOLDER'] = $userDataDir
        $psi.Environment['WINSMUX_DESKTOP_TEST_PROFILE'] = 'public-smoke'
        $psi.Environment['WINSMUX_DESKTOP_REMOTE_DEBUG_PORT'] = [string]$script:DebugPort

        $proc = [System.Diagnostics.Process]::Start($psi)
        $rootPid = $proc.Id

        try {
            $alive = Wait-ForCondition -TimeoutSeconds 30 -Condition {
                -not $proc.HasExited
            }
            $alive | Should -BeTrue -Because 'app process must stay alive for at least 30s after start'
            $proc.HasExited | Should -BeFalse

            $webviewReady = Wait-ForCondition -TimeoutSeconds 60 -Condition {
                $webviews = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'msedgewebview2.exe'" -ErrorAction SilentlyContinue)
                $count = 0
                foreach ($w in $webviews) {
                    if (Test-IsDescendantOf -CandidatePid ([int]$w.ProcessId) -RootPid $rootPid) {
                        $count++
                    }
                }
                $count -gt 0
            }
            $webviewReady | Should -BeTrue -Because 'at least one msedgewebview2.exe descendant of the app must appear within 60s'

            $webviews = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'msedgewebview2.exe'" -ErrorAction SilentlyContinue)
            $webviewDescendants = @($webviews | Where-Object { Test-IsDescendantOf -CandidatePid ([int]$_.ProcessId) -RootPid $rootPid })
            $webviewDescendants.Count | Should -BeGreaterThan 0

            $listenerReady = Wait-ForCondition -TimeoutSeconds 60 -Condition {
                $listeners = @(Get-NetTCPConnection -LocalPort $script:DebugPort -State Listen -ErrorAction SilentlyContinue)
                if ($listeners.Count -eq 0) {
                    return $false
                }

                foreach ($conn in $listeners) {
                    $ownerPid = [int]$conn.OwningProcess
                    if (-not (Test-IsDescendantOf -CandidatePid $ownerPid -RootPid $rootPid)) {
                        continue
                    }
                    $owner = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction SilentlyContinue
                    if ($null -eq $owner) {
                        continue
                    }
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$owner.Name)
                    if ($baseName -ne 'msedgewebview2') {
                        continue
                    }
                    $cmd = [string]$owner.CommandLine
                    if ($cmd -like "*--remote-debugging-port=$($script:DebugPort)*") {
                        return $true
                    }
                }

                return $false
            }
            $listenerReady | Should -BeTrue -Because 'a descendant msedgewebview2 must listen on the debug port with --remote-debugging-port set'

            $listeners = @(Get-NetTCPConnection -LocalPort $script:DebugPort -State Listen -ErrorAction SilentlyContinue)
            $listeners.Count | Should -BeGreaterThan 0

            $matchedOwner = $null
            foreach ($conn in $listeners) {
                $ownerPid = [int]$conn.OwningProcess
                if (-not (Test-IsDescendantOf -CandidatePid $ownerPid -RootPid $rootPid)) {
                    continue
                }
                $owner = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction SilentlyContinue
                if ($null -eq $owner) {
                    continue
                }
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$owner.Name)
                if ($baseName -ne 'msedgewebview2') {
                    continue
                }
                $cmd = [string]$owner.CommandLine
                if ($cmd -like "*--remote-debugging-port=$($script:DebugPort)*") {
                    $matchedOwner = $owner
                    break
                }
            }

            $null -ne $matchedOwner | Should -BeTrue -Because 'listener OwningProcess must be a descendant of the started app PID'
            $ownerName = [System.IO.Path]::GetFileNameWithoutExtension([string]$matchedOwner.Name)
            $ownerName | Should -Be 'msedgewebview2'
            [string]$matchedOwner.CommandLine | Should -BeLike "*--remote-debugging-port=$($script:DebugPort)*"

            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$($script:DebugPort)/json/version" -UseBasicParsing -TimeoutSec 10
            $response.StatusCode | Should -Be 200
        }
        finally {
            Stop-ProcessTree -RootPid $rootPid
            if (Test-Path -LiteralPath $userDataDir) {
                Remove-Item -LiteralPath $userDataDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}