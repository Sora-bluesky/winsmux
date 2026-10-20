[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OldMsi,
    [Parameter(Mandatory = $true)][string]$CandidateMsi,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$OldVersion = '0.36.38',
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$CandidateVersion = '0.38.0',
    [string]$CandidateIdentityPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8

if ($env:CI -ne 'true' -or $env:GITHUB_ACTIONS -ne 'true' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'This probe installs MSI packages machine-wide. Run it only on a disposable GitHub runner.'
}
. (Join-Path $PSScriptRoot 'msi-fault.ps1')

$utf8 = [Text.UTF8Encoding]::new($false)
$outRoot = [IO.Path]::GetFullPath($OutputRoot)
$root = [IO.Path]::GetFullPath($InstallRoot)
foreach ($fresh in @($outRoot, $root)) { if (Test-Path -LiteralPath $fresh) { throw "Probe root must not exist before the run: $fresh" } }
[void][IO.Directory]::CreateDirectory($outRoot)
$resultPath = Join-Path $outRoot 'result.json'
$msiexec = Join-Path ([Environment]::SystemDirectory) 'msiexec.exe'

$result = [ordered]@{
    schema = 't09-msi-probe/v1'
    state = 'running'
    passed = $false
    failure = $null
    install_root = $root
    packages = [ordered]@{ old = $null; candidate = $null; candidate_identity = if ($CandidateIdentityPath) { [IO.File]::ReadAllText($CandidateIdentityPath) | ConvertFrom-Json -AsHashtable } else { $null } }
    cases = [ordered]@{}
    checks = [Collections.Generic.List[object]]::new()
}
function Save-Result { [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 14), $utf8) }
function Add-Check([string]$Id, $Passed, $Expected, $Observed) {
    $result.checks.Add([ordered]@{ id = $Id; passed = $Passed; expected = $Expected; observed = $Observed }); Save-Result
}

function Invoke-Msi([string]$Name, [string]$Package) {
    $log = Join-Path $outRoot "$Name.msiexec.log"
    $arguments = '/i "' + $Package + '" /qn /norestart INSTALLDIR="' + $root + '" /l*v "' + $log + '"'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $msiexec -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    $text = if ([IO.File]::Exists($log)) { [IO.File]::ReadAllText($log) } else { '' }
    $errors = @([regex]::Matches($text, '(?m)^.*(?:Error \d{4}|Return value 3|error code \d+).*$') | Select-Object -First 20 | ForEach-Object { $_.Value.Trim() })
    return [ordered]@{ package = $Package; package_sha256 = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant(); arguments = $arguments; exit = $process.ExitCode; seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 1); log = [IO.Path]::GetFileName($log); error_lines = $errors }
}

function Get-ProductState([string]$Code) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    try { return [int]$installer.ProductState($Code) } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
}

function Get-Witness {
    $files = [ordered]@{}
    if ([IO.Directory]::Exists($root)) {
        foreach ($file in @([IO.Directory]::EnumerateFiles($root, '*', [IO.SearchOption]::AllDirectories) | Sort-Object)) {
            $files[[IO.Path]::GetRelativePath($root, $file).Replace('\', '/')] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $arp = @(foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $hive)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $hive)) {
            $name = [string]$key.GetValue('DisplayName')
            if ($name -like 'winsmux*') {
                [ordered]@{ key = $key.Name; display_name = $name; display_version = [string]$key.GetValue('DisplayVersion') }
            }
        }
    })
    return [ordered]@{
        files = $files
        arp = $arp
        old_product_state = Get-ProductState $result.packages.old.properties.ProductCode
        candidate_product_state = Get-ProductState $result.packages.candidate.properties.ProductCode
    }
}

# The GUI is a windowed app: runnable means the OS starts it and it is still alive after 5 s.
function Test-GuiStarts([string]$ExpectedVersion) {
    $exes = @(Get-ChildItem -LiteralPath $root -Filter '*.exe' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '(?i)unins' })
    $gui = @($exes | Where-Object { [string]$_.VersionInfo.ProductVersion -like "$ExpectedVersion*" })
    if ($gui.Count -ne 1) { return [ordered]@{ image = $null; candidates = @($exes | ForEach-Object { [ordered]@{ name = $_.Name; product_version = [string]$_.VersionInfo.ProductVersion } }); started = $false; alive_after_5s = $false } }
    $image = $gui[0].FullName
    try { $process = Start-Process -FilePath $image -PassThru -WindowStyle Minimized }
    catch { return [ordered]@{ image = $image; product_version = [string]$gui[0].VersionInfo.ProductVersion; started = $false; alive_after_5s = $false; error = $_.Exception.Message } }
    Start-Sleep -Seconds 5
    $alive = -not $process.HasExited
    $exit = if ($alive) { $null } else { $process.ExitCode }
    if ($alive) { & taskkill.exe /PID $process.Id /T /F | Out-Null; $global:LASTEXITCODE = 0 }
    return [ordered]@{ image = $image; product_version = [string]$gui[0].VersionInfo.ProductVersion; started = $true; alive_after_5s = $alive; exit = $exit }
}

function Compare-Witness($A, $B) {
    return (($A | ConvertTo-Json -Depth 8 -Compress) -ceq ($B | ConvertTo-Json -Depth 8 -Compress))
}

$exitCode = 0
try {
    $result.packages.old = Get-T09MsiFacts $OldMsi
    $result.packages.candidate = Get-T09MsiFacts $CandidateMsi
    $old = $result.packages.old.properties; $new = $result.packages.candidate.properties
    Add-Check 'packages-share-upgrade-code' ($old.UpgradeCode -ceq $new.UpgradeCode) $old.UpgradeCode $new.UpgradeCode
    Add-Check 'old-package-version' ($old.ProductVersion -ceq $OldVersion) $OldVersion $old.ProductVersion
    Add-Check 'candidate-package-version' ($new.ProductVersion -ceq $CandidateVersion) $CandidateVersion $new.ProductVersion
    Add-Check 'product-codes-differ' ($old.ProductCode -cne $new.ProductCode) 'different' @($old.ProductCode, $new.ProductCode)
    Add-Check 'nothing-installed-before' ((Get-ProductState $old.ProductCode) -ne 5 -and (Get-ProductState $new.ProductCode) -ne 5) 'neither product installed' $null

    $install = Invoke-Msi 'old-install' $OldMsi
    $oldWitness = Get-Witness
    $oldGui = Test-GuiStarts $OldVersion
    $result.cases.old_install = [ordered]@{ process = $install; witness = $oldWitness; gui = $oldGui }
    Add-Check 'old-install-exit-zero' ($install.exit -in @(0, 3010)) '0 or 3010' $install.exit
    Add-Check 'old-installed' ($oldWitness.old_product_state -eq 5) 5 $oldWitness.old_product_state
    Add-Check 'old-gui-starts' ([bool]$oldGui.alive_after_5s) 'alive after 5 s' $oldGui
    if ($oldWitness.old_product_state -ne 5) { throw "The $OldVersion MSI did not install; the update cases cannot be observed." }

    foreach ($kind in @('tamper', 'missing')) {
        $faulted = Join-Path $env:RUNNER_TEMP ("t09-msi-$kind-" + [IO.Path]::GetFileName($CandidateMsi))
        if (Test-Path -LiteralPath $faulted) { throw "Faulted package path exists: $faulted" }
        $fault = New-T09MsiFault -Source $CandidateMsi -Destination $faulted -Kind $kind
        $attempt = Invoke-Msi "candidate-$kind" $faulted
        $afterWitness = Get-Witness
        $gui = Test-GuiStarts $OldVersion
        $result.cases[$kind] = [ordered]@{ fault = $fault; process = $attempt; witness_after = $afterWitness; witness_equal = (Compare-Witness $oldWitness $afterWitness); gui = $gui }
        Add-Check "$kind-rejected" ($attempt.exit -notin @(0, 3010)) 'non-zero exit' $attempt.exit
        Add-Check "$kind-witness-unchanged" (Compare-Witness $oldWitness $afterWitness) 'files, ARP and product states equal' $result.cases[$kind].witness_equal
        Add-Check "$kind-old-gui-starts" ([bool]$gui.alive_after_5s) 'alive after 5 s' $gui
    }

    $update = Invoke-Msi 'candidate-update' $CandidateMsi
    $updated = Get-Witness
    $newGui = Test-GuiStarts $CandidateVersion
    $result.cases.update = [ordered]@{ process = $update; witness = $updated; gui = $newGui }
    Add-Check 'update-exit-zero' ($update.exit -in @(0, 3010)) '0 or 3010' $update.exit
    Add-Check 'update-candidate-installed' ($updated.candidate_product_state -eq 5) 5 $updated.candidate_product_state
    Add-Check 'update-old-product-removed' ($updated.old_product_state -ne 5) 'not 5' $updated.old_product_state
    Add-Check 'update-single-arp-entry' (@($updated.arp).Count -eq 1 -and @($updated.arp)[0].display_version -like "$CandidateVersion*") "one entry at $CandidateVersion" $updated.arp
    Add-Check 'update-candidate-gui-starts' ([bool]$newGui.alive_after_5s) 'alive after 5 s' $newGui

    $scored = @($result.checks | Where-Object { $null -ne $_.passed })
    $result.passed = ($scored.Count -gt 0 -and @($scored | Where-Object { -not $_.passed }).Count -eq 0)
    $result.state = 'complete'
} catch {
    $result.state = 'harness_error'
    $result.failure = [string]$_.Exception.Message
    $exitCode = 1
} finally {
    Save-Result
    Write-Host ($result | ConvertTo-Json -Depth 14)
}
exit $exitCode
