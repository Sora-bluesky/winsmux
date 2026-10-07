param([string]$ChildRoot = '', [string]$ChildPhase = '', [string]$ChildAction = '', [string]$SelectedCase = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = (Get-Location).Path
$tokens = $null; $parseErrors = $null
$installer = Join-Path $repo 'install.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Product installer syntax is invalid.' }
$names = @('Assert-WinsmuxReleaseTag', 'Get-WinsmuxBytesSha256', 'ConvertFrom-StrictWinsmuxJsonBytes',
    'Assert-WinsmuxLicenseObjectKeys', 'Assert-WinsmuxLicenseMemberPath', 'Initialize-WinsmuxInstallPathInfo',
    'Get-WinsmuxExecutingInstallerSource', 'ConvertTo-WinsmuxLifecycleBytes', 'New-WinsmuxLifecycleState', 'Assert-WinsmuxLifecycleFile', 'Publish-WinsmuxLifecycle', 'Assert-WinsmuxInstallPath', 'Open-WinsmuxInstallLease', 'Get-WinsmuxInstallSnapshot', 'Assert-WinsmuxInstallSnapshot',
    'Read-WinsmuxInstallOwner', 'Get-WinsmuxInstallState', 'Invoke-WinsmuxInstallCheckpoint', 'Write-WinsmuxInstallFile',
    'Move-WinsmuxInstallMember', 'Assert-WinsmuxInstalledGeneration', 'Install-VerifiedWinsmuxGeneration')
foreach ($name in $names) {
    $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true))
    if ($definitions.Count -ne 1) { throw "Ambiguous product function: $name" }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
# Transport/failure tests use synthetic byte payloads and an observed-version
# stub. Real sidecar parsing and executable execution have separate proofs.
Initialize-WinsmuxInstallPathInfo
function Get-WinsmuxCommandVersion($CommandInfo) {
    $bytes = [IO.File]::ReadAllBytes($CommandInfo.Source)
    if ($bytes.Length -and $bytes[0] -ne 0) { return [PSCustomObject]@{ Version = '0.38.0'; Output = 'winsmux 0.38.0' } }
    return $null
}
$utf8 = [Text.UTF8Encoding]::new($false)
$payload = [Collections.Generic.Dictionary[string, byte[]]]::new([StringComparer]::Ordinal)
$payload.Add('manifest.json', $utf8.GetBytes('verified-envelope'))
$payload.Add('licenses/manifest.json', $utf8.GetBytes('verified-catalog'))
$payload.Add('licenses/text/component.txt', $utf8.GetBytes('complete-new-license'))
$binaryBytes = [byte[]]@(1, 2, 3, 4)
$sidecar = [PSCustomObject]@{ Files = $payload; ArchiveSha256 = 'a' * 64;
    Manifest = @{ version = '0.38.0'; release_tag = 'v0.38.0'; asset_name = 'winsmux-x64.exe';
        target = 'x86_64-pc-windows-msvc'; executable_sha256 = Get-WinsmuxBytesSha256 $binaryBytes } }
function New-Fixture([string]$Root, [bool]$Prior) {
    $bin = Join-Path $Root '.local/bin'; [void][IO.Directory]::CreateDirectory($bin)
    [IO.File]::WriteAllBytes((Join-Path $Root 'download.exe'), $binaryBytes)
    [IO.File]::WriteAllText((Join-Path $bin 'unrelated.txt'), 'preserve-unrelated')
    if ($Prior) {
        $lifecyclePath = Join-Path $Root '.winsmux/bin/install.ps1'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($lifecyclePath))
        $sentinel = Join-Path $Root 'opaque-old-consumer-reached.txt'
        $opaque = '[IO.File]::WriteAllText(''' + $sentinel.Replace("'", "''") + ''', ''reached''); exit 88'
        [IO.File]::WriteAllText($lifecyclePath, $opaque, $utf8)
        $observation = @{ identity = [Winsmux.InstallPathInfo]::Query($lifecyclePath).Identity;
            sha256 = (Get-FileHash $lifecyclePath -Algorithm SHA256).Hash }
        [IO.File]::WriteAllText((Join-Path $Root 'prior-lifecycle.json'), (ConvertTo-Json $observation -Compress), $utf8)
        [IO.File]::WriteAllBytes((Join-Path $bin 'winsmux.exe'), [byte[]]@(9, 8, 7))
        [IO.File]::WriteAllBytes((Join-Path $bin ('winsmux.exe.previous-' + ('f' * 32))), [byte[]]@(6, 5))
        $license = Join-Path $bin 'winsmux-licenses'
        [void][IO.Directory]::CreateDirectory((Join-Path $license 'empty'))
        [IO.File]::WriteAllText((Join-Path $license 'old.txt'), 'exact-old-license')
        $identity = (Assert-WinsmuxInstallPath $license Directory).Identity
        $receipt = [ordered]@{ schema = 'winsmux-license-owner/v1'; canonical_name = 'winsmux-licenses';
            directory_identity = $identity; operation_id = 'b' * 32; release_tag = 'v0.37.0';
            asset_name = 'winsmux-x64.exe'; target = 'x86_64-pc-windows-msvc'; executable_sha256 = 'c' * 64; sidecar_sha256 = 'd' * 64 }
        [IO.File]::WriteAllBytes((Join-Path $bin 'winsmux-licenses.owner.json'), $utf8.GetBytes((ConvertTo-Json $receipt -Compress) + "`n"))
    }
    return $bin
}
function Read-ExternalInventory([string]$Bin) {
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($member in @('winsmux.exe', 'winsmux-licenses', 'winsmux-licenses.owner.json', 'unrelated.txt', ('winsmux.exe.previous-' + ('f' * 32)))) {
        $path = Join-Path $Bin $member
        if (-not (Test-Path -LiteralPath $path)) { $rows.Add('absent:' + $member); continue }
        if (Test-Path -LiteralPath $path -PathType Container) {
            $rows.Add('directory:' + $member + ':' + [Winsmux.InstallPathInfo]::Query($path).Identity)
            foreach ($entry in Get-ChildItem -LiteralPath $path -Recurse -Force) {
                $relative = $member + '/' + [IO.Path]::GetRelativePath($path, $entry.FullName).Replace('\', '/')
                if ($entry.PSIsContainer) { $rows.Add('directory:' + $relative) }
                else { $rows.Add('file:' + $relative + ':' + (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash) }
            }
        } else { $rows.Add('file:' + $member + ':' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) }
    }
    return (($rows.ToArray() | Sort-Object -CaseSensitive) -join "`n")
}
if ($ChildRoot) {
    $bin = Join-Path $ChildRoot '.local/bin'
    if ($ChildAction -eq 'lease-loser') {
        try { $lease = Open-WinsmuxInstallLease $bin; $lease.Stream.Dispose(); exit 71 } catch { exit 72 }
    }
    function Invoke-WinsmuxInstallCheckpoint([string]$Phase) {
        if ($Phase -ceq $ChildPhase) { exit 73 }
        if ($ChildAction -eq 'rollback' -and $Phase -ceq 'before-readback') { throw 'Start interrupted rollback.' }
    }
    $lease = Open-WinsmuxInstallLease $bin
    try {
        $state = Get-WinsmuxInstallState $lease
        Install-VerifiedWinsmuxGeneration $lease $state (Join-Path $ChildRoot 'download.exe') $sidecar (New-WinsmuxLifecycleState $lease $ast.Extent.Text '0.38.0') | Out-Null
    } finally { $lease.Stream.Dispose() }
    exit 74
}
$proofRoot = Join-Path $repo ('.evidence/workspace-package/install-generation-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($proofRoot)
$results = [Collections.Generic.List[object]]::new()
$realCheckpoint = (Get-Item Function:Invoke-WinsmuxInstallCheckpoint).ScriptBlock
$realMove = (Get-Item Function:Move-WinsmuxInstallMember).ScriptBlock
$realWrite = (Get-Item Function:Write-WinsmuxInstallFile).ScriptBlock
function Assert-Condition([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Run-Case([string]$Name, [scriptblock]$Body) {
    if ($SelectedCase -and $Name -cnotin $SelectedCase.Split(',')) { return }
    $root = Join-Path $proofRoot $Name
    [void][IO.Directory]::CreateDirectory($root)
    try { & $Body $root; Assert-LifecycleInvariant $root; $results.Add(@{ name = $Name; passed = $true }) }
    catch { $results.Add(@{ name = $Name; passed = $false; error = $_.Exception.Message }) }
    finally {
        Set-Item Function:Invoke-WinsmuxInstallCheckpoint $realCheckpoint
        Set-Item Function:Move-WinsmuxInstallMember $realMove
        Set-Item Function:Write-WinsmuxInstallFile $realWrite
    }
}
function Start-Child([string]$Root, [string]$Phase, [string]$Action = '') {
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true; $start.WorkingDirectory = $repo
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $PSCommandPath, '-ChildRoot', $Root, '-ChildPhase', $Phase, '-ChildAction', $Action)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    $outTask = $process.StandardOutput.ReadToEndAsync(); $errTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $record = @{ exit = $process.ExitCode; stdout = $outTask.GetAwaiter().GetResult(); stderr = $errTask.GetAwaiter().GetResult() }
    [IO.File]::WriteAllText((Join-Path $Root 'child.json'), (ConvertTo-Json $record -Compress), $utf8)
    $process.Dispose(); return $record.exit
}
function Assert-LifecycleInvariant([string]$Root) {
    $bin = Join-Path $Root '.local/bin'
    $active = Join-Path $Root '.winsmux/bin/install.ps1'
    Assert-Condition (-not [IO.File]::Exists((Join-Path $Root 'opaque-old-consumer-reached.txt'))) 'The opaque old consumer was executed.'
    $observationPath = Join-Path $Root 'prior-lifecycle.json'
    if ([IO.File]::Exists($observationPath)) {
        $prior = ConvertFrom-Json ([IO.File]::ReadAllText($observationPath))
        $locations = [Collections.Generic.List[string]]::new()
        if ([IO.File]::Exists($active)) { $locations.Add($active) }
        foreach ($archive in Get-ChildItem -LiteralPath $bin -Directory -Filter '.winsmux-lifecycle-*') {
            $old = Join-Path $archive.FullName 'prior-install.ps1'
            if ([IO.File]::Exists($old)) { $locations.Add($old) }
        }
        $preserved = @($locations | Where-Object { (Get-FileHash $_ -Algorithm SHA256).Hash -ceq $prior.sha256 })
        Assert-Condition ($preserved.Count -eq 1 -and [Winsmux.InstallPathInfo]::Query($preserved[0]).Identity -ceq $prior.identity) 'Original lifecycle bytes or physical identity were lost.'
    }
    if ([IO.File]::Exists((Join-Path $bin 'winsmux.install.pending.json'))) {
        Assert-Condition ([IO.File]::Exists($active)) 'Pending data has no complete current entrance.'
        Assert-Condition ((Get-FileHash $active -Algorithm SHA256).Hash -ceq (Get-FileHash $installer -Algorithm SHA256).Hash) 'Pending data still reaches a historical or changed consumer.'
        Assert-PublicPendingRefusal $Root $active
    }
}
function Assert-PublicPendingRefusal([string]$Root, [string]$Active) {
    $before = Read-ExternalInventory (Join-Path $Root '.local/bin')
    $wrapper = Join-Path $Root 'public-pending-entry.ps1'
    $template = @'
param([string]$InstalledSource, [string]$PrivateRoot)
$ErrorActionPreference = 'Stop'
# The exact installed source is independently hash-checked by the parent. Only
# HOME reads are projected to the declared private fixture. No gate is removed,
# no global HOME/settings are assigned, and every public Main action is executed.
$body = [IO.File]::ReadAllText($InstalledSource)
$projected = $body.Replace('$HOME', '$script:InstallProofHome')
$script:InstallProofHome = $PrivateRoot
$results = @()
foreach ($action in @('install', 'update', 'uninstall')) {
    $errorMessage = ''; $refused = $false
    try { & ([scriptblock]::Create($projected)) -Action $action }
    catch { $errorMessage = $_.Exception.Message; $refused = $errorMessage -like '*incomplete paired installation requires recovery*' }
    $results += @{ action = $action; refused = $refused; error = $errorMessage }
}
Write-Output (ConvertTo-Json @{ actions = $results; source_sha256 = (Get-FileHash $InstalledSource -Algorithm SHA256).Hash } -Depth 5 -Compress)
if (@($results | Where-Object { -not $_.refused }).Count) { exit 81 }
'@
    [IO.File]::WriteAllText($wrapper, $template, $utf8)
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($key in @('GITHUB_ACTIONS', 'WINSMUX_INSTALL_E2E', 'WINSMUX_INSTALL_STATE_ROOT', 'WINSMUX_INSTALL_SOURCE_REF')) { [void]$start.Environment.Remove($key) }
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $wrapper, '-InstalledSource', $Active, '-PrivateRoot', $Root)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $outTask = $process.StandardOutput.ReadToEndAsync(); $errTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $record = @{ exit = $process.ExitCode; stdout = $outTask.GetAwaiter().GetResult(); stderr = $errTask.GetAwaiter().GetResult() }
    $process.Dispose()
    [IO.File]::WriteAllText((Join-Path $Root 'public-pending-result.json'), (ConvertTo-Json $record -Depth 5), $utf8)
    Assert-Condition ($record.exit -eq 0) ('Public Main did not refuse all pending mutations: ' + $record.stderr + $record.stdout)
    Assert-Condition ((Read-ExternalInventory (Join-Path $Root '.local/bin')) -ceq $before) 'Public pending refusal changed canonical data.'
    Assert-Condition (-not [IO.File]::Exists((Join-Path $Root 'opaque-old-consumer-reached.txt'))) 'Public refusal reached the opaque old consumer.'
}
foreach ($prior in @($false, $true)) {
    $label = if ($prior) { 'prior' } else { 'first' }
    Run-Case ($label + '-success') {
        param($root)
        $bin = New-Fixture $root $prior
        $lease = Open-WinsmuxInstallLease $bin
        try {
            $state = Get-WinsmuxInstallState $lease
            Install-VerifiedWinsmuxGeneration $lease $state (Join-Path $root 'download.exe') $sidecar (New-WinsmuxLifecycleState $lease $ast.Extent.Text '0.38.0') | Out-Null
            [void](Assert-WinsmuxInstalledGeneration $state.Paths $sidecar)
            Assert-Condition (-not (Test-Path -LiteralPath $lease.Marker)) 'Successful transaction retained its marker.'
            Assert-Condition ([IO.File]::ReadAllText((Join-Path $bin 'unrelated.txt')) -ceq 'preserve-unrelated') 'Unrelated bytes changed.'
            if ($prior) {
                $owned = @(Get-ChildItem -LiteralPath $bin -Directory -Filter '.winsmux-install-*')
                Assert-Condition ($owned.Count -eq 1) 'Unique retained backup missing.'
                Assert-Condition ((Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes((Join-Path $owned[0].FullName 'old-exe')))) -ceq (Get-WinsmuxBytesSha256 ([byte[]]@(9, 8, 7)))) 'Previous executable bytes lost.'
                Assert-Condition ([IO.Directory]::Exists((Join-Path $owned[0].FullName 'old-licenses/empty'))) 'Previous empty directory lost.'
            }
        } finally { $lease.Stream.Dispose() }
    }
    $lifecyclePhases = @('stage-lifecycle-write', 'stage-lifecycle-readback', 'before-publish-lifecycle',
        'published-lifecycle', 'before-lifecycle-readback', 'lifecycle-readback-complete')
    if ($prior) { $lifecyclePhases += @('before-park-lifecycle', 'parked-lifecycle') }
    $phases = @('stage-license-write', 'stage-exe-write', 'stage-owner-write', 'stage-readback', 'marker-written',
        'before-publish-licenses', 'published-licenses', 'before-publish-owner', 'published-owner', 'before-publish-exe',
        'published-exe', 'before-readback', 'readback-complete') + $lifecyclePhases
    if ($prior) { $phases += @('before-park-licenses', 'parked-licenses', 'before-park-owner', 'parked-owner', 'before-park-exe', 'parked-exe') }
    foreach ($faultPhase in $phases) {
        Run-Case ($label + '-fault-' + $faultPhase) {
            param($root)
            $bin = New-Fixture $root $prior; $before = Read-ExternalInventory $bin
            $lease = Open-WinsmuxInstallLease $bin
            try {
                $state = Get-WinsmuxInstallState $lease
                $script:failedOnce = $false
                Set-Item Function:Invoke-WinsmuxInstallCheckpoint {
                    param([string]$Phase)
                    if ($Phase -ceq $faultPhase -and -not $script:failedOnce) { $script:failedOnce = $true; throw ('injected ' + $Phase) }
                }
                $failed = $false
                try { Install-VerifiedWinsmuxGeneration $lease $state (Join-Path $root 'download.exe') $sidecar (New-WinsmuxLifecycleState $lease $ast.Extent.Text '0.38.0') | Out-Null } catch { $failed = $true }
                Assert-Condition ($failed -and $script:failedOnce) 'Declared fault was not executed/refused.'
                Assert-Condition ((Read-ExternalInventory $bin) -ceq $before) 'Failure did not restore exact prior bytes/presence/identity.'
                Assert-Condition (-not (Test-Path -LiteralPath $lease.Marker)) 'Verified restoration left a marker.'
            } finally { $lease.Stream.Dispose() }
        }
        Run-Case ($label + '-interrupt-' + $faultPhase) {
            param($root)
            $bin = New-Fixture $root $prior; $before = Read-ExternalInventory $bin
            $exit = Start-Child $root $faultPhase
            Assert-Condition ($exit -eq 73) 'Child did not stop at the declared boundary.'
            $marker = Join-Path $bin 'winsmux.install.pending.json'
            if ($faultPhase -like 'stage-*' -or $faultPhase -in $lifecyclePhases) {
                Assert-Condition (-not (Test-Path -LiteralPath $marker)) 'Prepublication interruption created a marker.'
                Assert-Condition ((Read-ExternalInventory $bin) -ceq $before) 'Prepublication interruption changed canonical state.'
            } else {
                Assert-Condition ([IO.File]::Exists($marker)) 'Interrupted publication did not retain its marker.'
                $interrupted = Read-ExternalInventory $bin; $refused = $false
                try { $next = Open-WinsmuxInstallLease $bin; $next.Stream.Dispose() } catch { $refused = $true }
                Assert-Condition $refused 'Pending interruption did not refuse next installer.'
                Assert-Condition ((Read-ExternalInventory $bin) -ceq $interrupted) 'Pending refusal mutated protected files.'
            }
        }
    }
}
foreach ($rollbackPrior in @($false, $true)) {
$rollbackPhases = @('before-reject-exe', 'rejected-exe', 'before-restore-exe', 'restored-exe',
    'before-reject-owner', 'rejected-owner', 'before-restore-owner', 'restored-owner', 'before-reject-licenses',
    'rejected-licenses', 'before-restore-licenses', 'restored-licenses', 'before-restoration-readback', 'restoration-readback-complete')
if (-not $rollbackPrior) { $rollbackPhases = @($rollbackPhases | Where-Object { $_ -notlike '*restore-*' -and $_ -notlike 'restored-*' }) }
foreach ($rollbackPhase in $rollbackPhases) {
    Run-Case ('rollback-uncertain-' + $rollbackPrior + '-' + $rollbackPhase) {
        param($root)
        $bin = New-Fixture $root $rollbackPrior; $lease = Open-WinsmuxInstallLease $bin
        try {
            $state = Get-WinsmuxInstallState $lease; $script:rollbackSeen = $false
            Set-Item Function:Invoke-WinsmuxInstallCheckpoint {
                param([string]$Phase)
                if ($Phase -ceq 'before-readback') { throw 'Start rollback.' }
                if ($Phase -ceq $rollbackPhase) { $script:rollbackSeen = $true; throw 'Uncertain rollback.' }
            }
            $failed = $false
            try { Install-VerifiedWinsmuxGeneration $lease $state (Join-Path $root 'download.exe') $sidecar (New-WinsmuxLifecycleState $lease $ast.Extent.Text '0.38.0') | Out-Null } catch { $failed = $true }
            Assert-Condition ($failed -and $script:rollbackSeen) 'Declared rollback boundary not executed.'
            Assert-Condition ([IO.File]::Exists($lease.Marker)) 'Uncertain rollback lost its marker.'
        } finally { $lease.Stream.Dispose() }
        $preserved = Read-ExternalInventory $bin; $refused = $false
        try { $next = Open-WinsmuxInstallLease $bin; $next.Stream.Dispose() } catch { $refused = $true }
        Assert-Condition $refused 'Uncertain restoration allowed another installer.'
        Assert-Condition ((Read-ExternalInventory $bin) -ceq $preserved) 'Uncertain restoration refusal changed bytes.'
    }
    Run-Case ('rollback-interrupt-' + $rollbackPrior + '-' + $rollbackPhase) {
        param($root)
        $bin = New-Fixture $root $rollbackPrior
        Assert-Condition ((Start-Child $root $rollbackPhase 'rollback') -eq 73) 'Child did not interrupt the declared rollback transition.'
        Assert-Condition ([IO.File]::Exists((Join-Path $bin 'winsmux.install.pending.json'))) 'Interrupted rollback discarded its pending marker.'
    }
}
}
Run-Case 'lease-fixed-loser' {
    param($root)
    $bin = New-Fixture $root $true; $before = Read-ExternalInventory $bin
    $lease = Open-WinsmuxInstallLease $bin
    try { Assert-Condition ((Start-Child $root 'none' 'lease-loser') -eq 72) 'Second process acquired the held lease.' }
    finally { $lease.Stream.Dispose() }
    Assert-Condition ((Read-ExternalInventory $bin) -ceq $before) 'Lease loser modified protected files.'
    $next = Open-WinsmuxInstallLease $bin; $next.Stream.Dispose()
    Assert-Condition ([IO.File]::Exists((Join-Path $bin 'winsmux.install.lock'))) 'Fixed unlocked lease was unlinked.'
}
Run-Case 'marker-removal-failure' {
    param($root)
    $bin = New-Fixture $root $true; $lease = Open-WinsmuxInstallLease $bin
    try {
        $state = Get-WinsmuxInstallState $lease
        Set-Item Function:Invoke-WinsmuxInstallCheckpoint { param($Phase) if ($Phase -ceq 'before-marker-removal') { throw 'Cannot remove marker.' } }
        $failed = $false
        try { Install-VerifiedWinsmuxGeneration $lease $state (Join-Path $root 'download.exe') $sidecar (New-WinsmuxLifecycleState $lease $ast.Extent.Text '0.38.0') | Out-Null } catch { $failed = $true }
        Assert-Condition $failed 'Marker removal failure reported success.'
        Assert-Condition ([IO.File]::Exists($lease.Marker)) 'Marker removal failure discarded marker.'
        [void](Assert-WinsmuxInstalledGeneration $state.Paths $sidecar)
    } finally { $lease.Stream.Dispose() }
}
foreach ($markerPrior in @($false, $true)) {
    foreach ($markerOutcome in @('success', 'restoration')) {
        foreach ($markerMode in @('fault', 'interrupt')) {
            if ($markerPrior -and $markerOutcome -eq 'success' -and $markerMode -eq 'fault') { continue } # Existing case above.
            Run-Case ("marker-final-$markerPrior-$markerOutcome-$markerMode") {
                param($root)
                $bin = New-Fixture $root $markerPrior
                $before = Read-ExternalInventory $bin
                if ($markerMode -eq 'interrupt') {
                    $action = if ($markerOutcome -eq 'restoration') { 'rollback' } else { '' }
                    Assert-Condition ((Start-Child $root 'before-marker-removal' $action) -eq 73) 'Child did not stop before final marker removal.'
                } else {
                    $lease = Open-WinsmuxInstallLease $bin
                    try {
                        $state = Get-WinsmuxInstallState $lease
                        Set-Item Function:Invoke-WinsmuxInstallCheckpoint {
                            param($Phase)
                            if ($markerOutcome -eq 'restoration' -and $Phase -ceq 'before-readback') { throw 'Restore prior data.' }
                            if ($Phase -ceq 'before-marker-removal') { throw 'Final marker removal refused.' }
                        }
                        $failed = $false
                        try { Install-VerifiedWinsmuxGeneration $lease $state (Join-Path $root 'download.exe') $sidecar (New-WinsmuxLifecycleState $lease $ast.Extent.Text '0.38.0') | Out-Null } catch { $failed = $true }
                        Assert-Condition $failed 'Final marker removal failure reported success.'
                    } finally { $lease.Stream.Dispose() }
                }
                Assert-Condition ([IO.File]::Exists((Join-Path $bin 'winsmux.install.pending.json'))) 'Final marker removal lost its pending barrier.'
                if ($markerOutcome -eq 'restoration') {
                    Assert-Condition ((Read-ExternalInventory $bin) -ceq $before) 'Final restoration boundary did not retain exact prior data.'
                } else {
                    $paths = @{ exe = Join-Path $bin 'winsmux.exe'; licenses = Join-Path $bin 'winsmux-licenses'; owner = Join-Path $bin 'winsmux-licenses.owner.json' }
                    [void](Assert-WinsmuxInstalledGeneration $paths $sidecar)
                }
            }
        }
    }
}
foreach ($prior in @($false, $true)) {
    foreach ($corruptMember in @('exe', 'licenses', 'owner')) {
        Run-Case ("readback-corruption-$prior-$corruptMember") {
            param($root)
            $bin = New-Fixture $root $prior; $before = Read-ExternalInventory $bin
            $lease = Open-WinsmuxInstallLease $bin
            try {
                $state = Get-WinsmuxInstallState $lease; $script:corrupted = $false
                Set-Item Function:Invoke-WinsmuxInstallCheckpoint {
                    param($Phase)
                    if ($Phase -ceq 'before-readback') {
                        $path = if ($corruptMember -eq 'licenses') { Join-Path $state.Paths.licenses 'licenses/text/component.txt' } else { $state.Paths[$corruptMember] }
                        [IO.File]::WriteAllBytes($path, [byte[]]@(0, 1)); $script:corrupted = $true
                    }
                }
                $failed = $false
                try { Install-VerifiedWinsmuxGeneration $lease $state (Join-Path $root 'download.exe') $sidecar (New-WinsmuxLifecycleState $lease $ast.Extent.Text '0.38.0') | Out-Null } catch { $failed = $true }
                Assert-Condition ($failed -and $script:corrupted) 'Corrupt readback was accepted.'
                Assert-Condition ((Read-ExternalInventory $bin) -ceq $before) 'Corrupt readback did not restore all prior members.'
                Assert-Condition (-not (Test-Path -LiteralPath $lease.Marker)) 'Verified restoration after corruption retained marker.'
            } finally { $lease.Stream.Dispose() }
        }
    }
}
foreach ($heldMember in @('exe', 'owner')) {
    Run-Case ('held-prior-' + $heldMember) {
        param($root)
        $bin = New-Fixture $root $true; $before = Read-ExternalInventory $bin
        $lease = Open-WinsmuxInstallLease $bin; $held = $null
        try {
            $state = Get-WinsmuxInstallState $lease
            $held = [IO.File]::Open($state.Paths[$heldMember], [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $failed = $false
            try { Install-VerifiedWinsmuxGeneration $lease $state (Join-Path $root 'download.exe') $sidecar (New-WinsmuxLifecycleState $lease $ast.Extent.Text '0.38.0') | Out-Null } catch { $failed = $true }
            Assert-Condition $failed 'OS-held protected path was replaced.'
            Assert-Condition ((Read-ExternalInventory $bin) -ceq $before) 'OS rename failure lost prior bytes.'
            Assert-Condition (-not (Test-Path -LiteralPath $lease.Marker)) 'Verified restoration after OS failure retained marker.'
        } finally { if ($held) { $held.Dispose() }; $lease.Stream.Dispose() }
    }
}
Run-Case 'marker-partial-write' {
    param($root)
    $bin = New-Fixture $root $true; $before = Read-ExternalInventory $bin; $lease = Open-WinsmuxInstallLease $bin
    try {
        $state = Get-WinsmuxInstallState $lease
        Set-Item Function:Write-WinsmuxInstallFile {
            param($Path, $Bytes)
            if ($Path -ceq $lease.Marker) { [IO.File]::WriteAllBytes($Path, [byte[]]@(1)); throw 'Partial marker write.' }
            & $realWrite $Path $Bytes
        }
        $failed = $false
        try { Install-VerifiedWinsmuxGeneration $lease $state (Join-Path $root 'download.exe') $sidecar (New-WinsmuxLifecycleState $lease $ast.Extent.Text '0.38.0') | Out-Null } catch { $failed = $true }
        Assert-Condition $failed 'Partial marker write was accepted.'
        Assert-Condition ((Read-ExternalInventory $bin) -ceq $before) 'Partial marker write changed canonical members.'
        Assert-Condition ([IO.File]::Exists($lease.Marker)) 'Partial marker evidence was lost.'
    } finally { $lease.Stream.Dispose() }
}
Run-Case 'os-marker-delete-failure' {
    param($root)
    $bin = New-Fixture $root $true; $lease = Open-WinsmuxInstallLease $bin; $script:heldMarker = $null
    try {
        $state = Get-WinsmuxInstallState $lease
        Set-Item Function:Invoke-WinsmuxInstallCheckpoint {
            param($Phase)
            if ($Phase -ceq 'before-marker-removal') {
                $script:heldMarker = [IO.File]::Open($lease.Marker, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            }
        }
        $failed = $false
        try { Install-VerifiedWinsmuxGeneration $lease $state (Join-Path $root 'download.exe') $sidecar (New-WinsmuxLifecycleState $lease $ast.Extent.Text '0.38.0') | Out-Null } catch { $failed = $true }
        Assert-Condition $failed 'OS marker-delete refusal was reported as success.'
        Assert-Condition ([IO.File]::Exists($lease.Marker)) 'OS marker-delete refusal lost marker.'
        [void](Assert-WinsmuxInstalledGeneration $state.Paths $sidecar)
    } finally { if ($script:heldMarker) { $script:heldMarker.Dispose() }; $lease.Stream.Dispose() }
}
foreach ($scenario in @('foreign-directory', 'foreign-identity', 'malformed-owner', 'missing-directory-valid-owner',
    'absent-one-legacy', 'absent-two-legacy', 'invalid-no-legacy', 'invalid-with-legacy')) {
    Run-Case $scenario {
        param($root)
        $prior = $scenario -in @('foreign-identity', 'malformed-owner', 'missing-directory-valid-owner', 'invalid-with-legacy')
        $bin = New-Fixture $root $prior
        switch ($scenario) {
            'foreign-directory' { [void][IO.Directory]::CreateDirectory((Join-Path $bin 'winsmux-licenses')) }
            'foreign-identity' {
                $ownerPath = Join-Path $bin 'winsmux-licenses.owner.json'
                $owner = ConvertFrom-Json ([IO.File]::ReadAllText($ownerPath)) -AsHashtable
                $owner.directory_identity = '00000000:0000000000000000'
                [IO.File]::WriteAllText($ownerPath, (ConvertTo-Json $owner -Compress))
            }
            'malformed-owner' { [IO.File]::WriteAllText((Join-Path $bin 'winsmux-licenses.owner.json'), '{') }
            'missing-directory-valid-owner' { [IO.Directory]::Move((Join-Path $bin 'winsmux-licenses'), (Join-Path $root 'parked-original-licenses')) }
            'absent-one-legacy' { [IO.File]::WriteAllBytes((Join-Path $bin ('winsmux.exe.previous-' + ('f' * 32))), [byte[]]@(6, 5)) }
            'absent-two-legacy' {
                foreach ($prefix in @('e', 'f')) { [IO.File]::WriteAllBytes((Join-Path $bin ('winsmux.exe.previous-' + ($prefix * 32))), [byte[]]@(6, 5)) }
            }
            'invalid-no-legacy' { [IO.File]::WriteAllBytes((Join-Path $bin 'winsmux.exe'), [byte[]]@(0)) }
            'invalid-with-legacy' { [IO.File]::WriteAllBytes((Join-Path $bin 'winsmux.exe'), [byte[]]@(0)) }
        }
        $before = Read-ExternalInventory $bin; $lease = Open-WinsmuxInstallLease $bin
        try {
            $refused = $false
            try { $state = Get-WinsmuxInstallState $lease } catch { $refused = $true }
            $rejectExpected = $scenario -in @('foreign-directory', 'foreign-identity', 'malformed-owner', 'absent-two-legacy', 'invalid-with-legacy')
            Assert-Condition ($refused -eq $rejectExpected) 'Ownership/legacy transition did not match its frozen table.'
            Assert-Condition ((Read-ExternalInventory $bin) -ceq $before) 'Ownership/legacy preflight mutated protected state.'
            if (-not $refused) {
                Install-VerifiedWinsmuxGeneration $lease $state (Join-Path $root 'download.exe') $sidecar (New-WinsmuxLifecycleState $lease $ast.Extent.Text '0.38.0') | Out-Null
                [void](Assert-WinsmuxInstalledGeneration $state.Paths $sidecar)
            }
        } finally { $lease.Stream.Dispose() }
    }
}
foreach ($alias in @('exe-hardlink', 'owner-hardlink', 'lock-hardlink', 'license-junction', 'ancestor-junction',
    'lifecycle-hardlink', 'lifecycle-parent-junction', 'lifecycle-ancestor-junction')) {
    Run-Case $alias {
        param($root)
        $bin = New-Fixture $root $false
        $foreign = Join-Path $root 'foreign'; [void][IO.Directory]::CreateDirectory($foreign)
        $source = Join-Path $foreign 'unchanged.txt'; [IO.File]::WriteAllText($source, 'untouched-alias-source')
        $path = switch ($alias) {
            'exe-hardlink' { Join-Path $bin 'winsmux.exe' }
            'owner-hardlink' { Join-Path $bin 'winsmux-licenses.owner.json' }
            'lock-hardlink' { Join-Path $bin 'winsmux.install.lock' }
            'license-junction' { Join-Path $bin 'winsmux-licenses' }
            'ancestor-junction' { Join-Path $root 'linked-bin' }
            'lifecycle-hardlink' { Join-Path $root '.winsmux/bin/install.ps1' }
            'lifecycle-parent-junction' { Join-Path $root '.winsmux/bin' }
            'lifecycle-ancestor-junction' { Join-Path $root '.winsmux' }
        }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        if ($alias -like '*hardlink') { New-Item -ItemType HardLink -Path $path -Target $source | Out-Null }
        else { New-Item -ItemType Junction -Path $path -Target $foreign | Out-Null }
        if ($alias -eq 'ancestor-junction') { $bin = $path }
        $refused = $false; $lease = $null
        try { $lease = Open-WinsmuxInstallLease $bin; [void](Get-WinsmuxInstallState $lease); [void](New-WinsmuxLifecycleState $lease $ast.Extent.Text '0.38.0') } catch { $refused = $true }
        finally { if ($lease) { $lease.Stream.Dispose() } }
        Assert-Condition $refused 'Physical alias was accepted.'
        Assert-Condition ([IO.File]::ReadAllText($source) -ceq 'untouched-alias-source') 'Physical alias refusal mutated its source.'
        Assert-Condition (-not [IO.File]::Exists((Join-Path $bin 'winsmux.install.pending.json'))) 'Physical alias refusal created a marker.'
    }
}
$failedCases = @($results | Where-Object { -not $_.passed })
$expectedCount = if ($SelectedCase) { $SelectedCase.Split(',').Count } else { 173 }
$receipt = @{ schema = 'winsmux-install-generation-proof/v1'; completed = ($failedCases.Count -eq 0 -and $results.Count -eq $expectedCount);
    selection = $SelectedCase; expected_count = $expectedCount;
    scope = 'actual Windows filesystem transaction and lease; synthetic executable/license bytes and version observation; complete persisted consumer public Main install/update/uninstall pending refusal with HOME-only private projection; no live release or real artifact installation claim';
    installer_sha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant();
    cases = $results.ToArray(); passed = $results.Count - $failedCases.Count; failed = $failedCases.Count }
[IO.File]::WriteAllText((Join-Path $proofRoot 'result.json'), (ConvertTo-Json $receipt -Depth 12), $utf8)
Write-Output (ConvertTo-Json @{ result = Join-Path $proofRoot 'result.json'; passed = $receipt.passed; failed = $receipt.failed } -Compress)
if ($failedCases.Count) { $failedCases | ConvertTo-Json -Depth 8; exit 1 }
if (-not $receipt.completed) { throw 'Declared generation proof cases were not all executed.' }
