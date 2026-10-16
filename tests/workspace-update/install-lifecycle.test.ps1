param([string]$SelectedCase = '', [string]$ChildRoot = '', [string]$ChildPhase = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$repo = (Get-Location).Path
$installer = Join-Path $repo 'install.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Invalid installer syntax.' }
foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
    $body=$definition.Extent.Text
    if ($definition.Name -in @('Invoke-Uninstall','Invoke-WinsmuxInstallLifecycle')) { $body=$body.Replace('$HOME','$script:ProofHome') }
    . ([scriptblock]::Create($body))
}
Initialize-WinsmuxInstallPathInfo
$utf8=[Text.UTF8Encoding]::new($false)
$binaryBytes=[byte[]]@(1,2,3,4)
$payload=[Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
$payload.Add('manifest.json',$utf8.GetBytes('verified-envelope'))
$payload.Add('licenses/manifest.json',$utf8.GetBytes('verified-catalog'))
$payload.Add('licenses/text/component.txt',$utf8.GetBytes('verified-license'))
$sidecar=[PSCustomObject]@{ Files=$payload; ArchiveSha256=('a'*64); Manifest=@{ version='0.38.0'; release_tag='v0.38.0'; asset_name='winsmux-x64.exe'; target='x86_64-pc-windows-msvc'; executable_sha256=(Get-WinsmuxBytesSha256 $binaryBytes) } }
$script:StartupFailure=$false
$script:UserPathFile=''
$script:UserPath=''
$script:ProfilePath=''
function Get-InstallUserPath {
    if (-not [IO.File]::Exists($script:UserPathFile)) { return $null }
    return [IO.File]::ReadAllText($script:UserPathFile)
}
function Set-InstallUserPath([AllowNull()][AllowEmptyString()][object]$Value) {
    if ($null -eq $Value) { [IO.File]::Delete($script:UserPathFile) }
    else { [IO.File]::WriteAllText($script:UserPathFile,$Value,[Text.UTF8Encoding]::new($false)) }
    $script:UserPath=$Value
}
function Get-InstallPowerShellProfilePath { return $script:ProfilePath }
function Get-WinsmuxCommandVersion($CommandInfo) {
    $bytes=[IO.File]::ReadAllBytes($CommandInfo.Source)
    if ($script:StartupFailure -and $CommandInfo.Source -like '*.winsmux-install-*') { return $null }
    if (-not $bytes.Length -or $bytes[0] -eq 0) { return $null }
    $version=if($bytes[0] -eq 9){'0.37.0'}else{'0.38.0'}
    return [PSCustomObject]@{ Version=$version; Output=('winsmux '+$version) }
}
function Assert-Condition([bool]$Value,[string]$Message) { if(-not $Value){throw $Message} }
function New-Fixture([string]$Root,[bool]$Prior=$true) {
    $script:ProofHome=$Root
    $env:LOCALAPPDATA=Join-Path $Root 'LocalAppData'
    $script:ProfilePath=Join-Path $Root 'PowerShell/profile.ps1'
    $script:UserPathFile=Join-Path $Root 'user-path.mock.txt'
    Set-InstallUserPath 'prior-user-path'
    $bin=Join-Path $Root '.local/bin'
    [void][IO.Directory]::CreateDirectory($bin)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:ProfilePath))
    [IO.File]::WriteAllText($script:ProfilePath,'# unrelated profile',$utf8)
    [IO.File]::WriteAllBytes((Join-Path $Root 'download.exe'),$binaryBytes)
    [void][IO.Directory]::CreateDirectory((Join-Path $Root '.winsmux/projects/user-project'))
    [IO.File]::WriteAllBytes((Join-Path $Root '.winsmux/projects/user-project/project.json'),[byte[]]@(0,255,12,10))
    [IO.File]::WriteAllText((Join-Path $Root '.winsmux/unknown.txt'),'unknown-user-file',$utf8)
    if($Prior) {
        [IO.File]::WriteAllBytes((Join-Path $bin 'winsmux.exe'),[byte[]]@(9,8,7))
        $licenses=Join-Path $bin 'winsmux-licenses'; [void][IO.Directory]::CreateDirectory($licenses)
        [IO.File]::WriteAllText((Join-Path $licenses 'old.txt'),'old-license',$utf8)
        $receipt=@{schema='winsmux-license-owner/v1';canonical_name='winsmux-licenses';directory_identity=(Assert-WinsmuxInstallPath $licenses Directory).Identity;operation_id=('b'*32);release_tag='v0.37.0';asset_name='winsmux-x64.exe';target='x86_64-pc-windows-msvc';executable_sha256=('c'*64);sidecar_sha256=('d'*64)}
        [IO.File]::WriteAllText((Join-Path $bin 'winsmux-licenses.owner.json'),(ConvertTo-Json $receipt -Compress),$utf8)
        [IO.File]::WriteAllText((Join-Path $Root '.winsmux.conf'),'user-old-settings',$utf8)
        [void][IO.Directory]::CreateDirectory((Join-Path $Root '.winsmux/bin'))
        [IO.File]::WriteAllText((Join-Path $Root '.winsmux/bin/winsmux-core.ps1'),'old-support',$utf8)
    }
    return $bin
}
function New-Support($Lease) {
    $root=Join-Path $Lease.LocalBin ('.test-support-'+[Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($root)
    $members=[Collections.Generic.List[object]]::new()
    $names=@('.winsmux/bin/winsmux-core.ps1','.winsmux.conf','.winsmux/version','terminal-fragment','profile')
    $index=0
    $line='$env:PATH = "'+(Join-Path $script:ProofHome '.winsmux/bin')+';$env:PATH"'
    foreach($name in $names) {
        $stage=Join-Path $root ('file-'+$index);$index++
        $content=if($name -ceq 'profile'){'# unrelated profile'+"`n# winsmux`n"+$line+"`n"}else{'new-'+$name}
        [IO.File]::WriteAllText($stage,$content,$utf8)
        $members.Add([PSCustomObject]@{Name=$name;Stage=$stage;Remove=$false})
    }
    $script:UserPath=Get-InstallUserPath
    $newUserPath=if(@($script:UserPath -split ';' | Where-Object { $_ -ieq $Lease.LocalBin })){$script:UserPath}else{if($script:UserPath){$script:UserPath+';'+$Lease.LocalBin}else{$Lease.LocalBin}}
    return [PSCustomObject]@{Root=$root;Members=$members;ProfileLine=$line;PriorUserPath=$script:UserPath;UserPath=$newUserPath;PriorProcessPath=$env:Path;ProcessPath=('fixture-process-path;'+$env:Path);Owner=(Read-WinsmuxSupportOwner $Lease)}
}
function Read-ProtectedInventory([string]$Root) {
    $rows=[Collections.Generic.List[string]]::new()
    foreach($name in @('.local/bin/winsmux.exe','.local/bin/winsmux-licenses.owner.json','.local/bin/winsmux-licenses','.winsmux/bin/winsmux-core.ps1','.winsmux/bin/winsmux.cmd','.winsmux/bin/winsmux-entry.ps1','.winsmux/bin/install.ps1','.winsmux.conf','.winsmux/version','.winsmux/install-owner.json','LocalAppData/Microsoft/Windows Terminal/Fragments/winsmux/winsmux.json','PowerShell/profile.ps1','.winsmux/projects/user-project/project.json','.winsmux/unknown.txt')) {
        $path=Join-Path $Root $name
        if(-not [IO.File]::Exists($path) -and -not [IO.Directory]::Exists($path)){ $rows.Add('absent:'+$name);continue }
        if([IO.Directory]::Exists($path)) {
            foreach($item in [IO.Directory]::EnumerateFiles($path,'*',[IO.SearchOption]::AllDirectories)) { $rows.Add($name+'/'+[IO.Path]::GetRelativePath($path,$item)+':'+(Get-FileHash -LiteralPath $item -Algorithm SHA256).Hash.ToLowerInvariant()) }
        } else { $rows.Add($name+':'+(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()) }
    }
    return (($rows.ToArray()|Sort-Object -CaseSensitive)-join "`n")
}
function Invoke-Generation($Lease,$Support) {
    $state=Get-WinsmuxInstallState $Lease
    try { Install-VerifiedWinsmuxGeneration $Lease $state (Join-Path $script:ProofHome 'download.exe') $sidecar (New-WinsmuxLifecycleState $Lease $ast.Extent.Text '0.38.0') $Support | Out-Null }
    catch { $script:GenerationFailure=$_.Exception.Message;throw }
}
if($ChildRoot) {
    $bin=Join-Path $ChildRoot '.local/bin';$script:ProofHome=$ChildRoot;$env:LOCALAPPDATA=Join-Path $ChildRoot 'LocalAppData'
    $script:ProfilePath=Join-Path $ChildRoot 'PowerShell/profile.ps1';$script:UserPathFile=Join-Path $ChildRoot 'user-path.mock.txt';$script:UserPath=Get-InstallUserPath
    function Invoke-WinsmuxInstallCheckpoint([string]$Phase) { if($Phase -ceq $ChildPhase){exit 73}; if($ChildPhase -like '*-restore-intent' -and $Phase -ceq 'before-readback'){throw 'Enter crash restoration.'} }
    $lease=Open-WinsmuxInstallLease $bin
    try {Invoke-Generation $lease (New-Support $lease)}finally{$lease.Stream.Dispose()}
    exit 74
}
$proofRoot=Join-Path $repo ('.evidence/workspace-update/install-lifecycle-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($proofRoot)
$results=[Collections.Generic.List[object]]::new()
$checkpoint=(Get-Item Function:Invoke-WinsmuxInstallCheckpoint).ScriptBlock
$writer=(Get-Item Function:Write-WinsmuxInstallFile).ScriptBlock
$pathSetter=(Get-Item Function:Set-InstallUserPath).ScriptBlock
$volumeResolver=(Get-Item Function:Get-WinsmuxInstallVolume).ScriptBlock
$pathInspector=(Get-Item Function:Assert-WinsmuxInstallPath).ScriptBlock
$originalEnvPath=$env:Path;$originalLocal=$env:LOCALAPPDATA
function Run-Case([string]$Name,[scriptblock]$Body) {
    if($SelectedCase -and $Name -cnotin $SelectedCase.Split(',')){return}
    $root=Join-Path $proofRoot $Name;[void][IO.Directory]::CreateDirectory($root)
    $script:GenerationFailure=''
    try{& $Body $root;$results.Add(@{name=$Name;passed=$true})}
    catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message;generation_error=$script:GenerationFailure;stack=$_.ScriptStackTrace})}
    finally{Set-Item Function:Invoke-WinsmuxInstallCheckpoint $checkpoint;Set-Item Function:Write-WinsmuxInstallFile $writer;Set-Item Function:Set-InstallUserPath $pathSetter;Set-Item Function:Get-WinsmuxInstallVolume $volumeResolver;Set-Item Function:Assert-WinsmuxInstallPath $pathInspector;$env:Path=$originalEnvPath;$env:LOCALAPPDATA=$originalLocal;$script:StartupFailure=$false}
}
# Frozen class decision table: staging failures mutate no protected member;
# every pre-commit publication failure restores all paired/support/registration;
# interruptions recover through the same journal; post-commit completion cannot
# roll back; uncertain identities preserve marker/backups; uninstall uses exact
# ownership and hashes while unknown/modified/project/standalone bytes survive.
Run-Case 'normal-update' {
    param($root)
    $bin=New-Fixture $root;$lease=Open-WinsmuxInstallLease $bin
    try {Invoke-Generation $lease (New-Support $lease);Assert-Condition (-not [IO.File]::Exists($lease.Marker)) 'Success retained marker.';Assert-Condition ([IO.File]::ReadAllText((Join-Path $root '.winsmux.conf')) -ceq 'new-.winsmux.conf') 'Settings not published.';[void](Read-WinsmuxSupportOwner $lease)}finally{$lease.Stream.Dispose()}
}
$phases=@('marker-written','before-publish-licenses','published-licenses','before-publish-owner','published-owner','before-publish-exe','published-exe','before-registration','published-registration','before-readback','readback-complete')
foreach($index in 0..5){$id='support-'+$index.ToString('000');$phases+=@(('before-park-'+$id),('parked-'+$id),('before-publish-'+$id),('published-'+$id))}
foreach($prior in @($false,$true)) {
    foreach($faultPhase in $phases) {
        # Only profile is present in first-install; update also has wrapper/config.
        if($faultPhase -match '^(before-park|parked)-support-(000|001|002|003|005)$' -and (-not $prior -or $faultPhase -match 'support-(002|003|005)$')){continue}
        Run-Case ('restore-'+$prior+'-'+$faultPhase) {
            param($root)
            $bin=New-Fixture $root $prior;$before=Read-ProtectedInventory $root;$priorPath=$script:UserPath;$processPath=$env:Path
            $lease=Open-WinsmuxInstallLease $bin
            try {
                 $script:FaultReached=$false
                Set-Item Function:Invoke-WinsmuxInstallCheckpoint {param($Phase) if($Phase -ceq $faultPhase){$script:FaultReached=$true;throw 'Injected publication failure.'}}
                $failed=$false;try{Invoke-Generation $lease (New-Support $lease)}catch{$failed=$true}
                Assert-Condition ($failed -and $script:FaultReached) 'Declared publication fault was not reached or reported success.'
                Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'Failure changed protected generation/settings/project bytes.'
                Assert-Condition ($script:UserPath -ceq $priorPath -and $env:Path -ceq $processPath) 'Failure changed registration.'
                Assert-Condition (-not [IO.File]::Exists($lease.Marker)) 'Verified restoration retained marker.'
            }finally{$lease.Stream.Dispose()}
        }
    }
}
foreach($phase in @('published-exe','published-support-001','published-support-004','readback-complete','generation-committed')) {
    Run-Case ('restart-'+$phase) {
        param($root)
        $bin=New-Fixture $root;$before=Read-ProtectedInventory $root
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WorkingDirectory=$repo;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($arg in @('-NoLogo','-NoProfile','-File',$PSCommandPath,'-ChildRoot',$root,'-ChildPhase',$phase)){$start.ArgumentList.Add($arg)}
        $process=[Diagnostics.Process]::Start($start);$outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
        $record=@{exit=$process.ExitCode;stdout=$outTask.GetAwaiter().GetResult();stderr=$errTask.GetAwaiter().GetResult()};$process.Dispose();[IO.File]::WriteAllText((Join-Path $root 'child.json'),(ConvertTo-Json $record),$utf8)
        Assert-Condition ($record.exit -eq 73) 'Child failed before interruption.'
        Assert-Condition ([IO.File]::Exists((Join-Path $bin 'winsmux.install.pending.json'))) 'Interrupted operation lost marker.'
        $lease=Open-WinsmuxInstallLease $bin -RecoverPending
        try{
            Assert-Condition (-not [IO.File]::Exists($lease.Marker)) 'Recovery retained marker.'
            if($phase -ceq 'generation-committed'){Assert-Condition ([IO.File]::ReadAllText((Join-Path $root '.winsmux.conf')) -ceq 'new-.winsmux.conf') 'Committed generation rolled back.'}
            else{Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'Pending recovery did not restore original bytes.'}
        }finally{$lease.Stream.Dispose()}
    }
}
Run-Case 'rollback-uncertain-retry' {
    param($root)
    $bin=New-Fixture $root;$before=Read-ProtectedInventory $root;$lease=Open-WinsmuxInstallLease $bin
    try{
        Set-Item Function:Invoke-WinsmuxInstallCheckpoint {param($Phase) if($Phase -in @('before-readback','before-restore-support-001')){throw 'Retain uncertain rollback.'}}
        $failed=$false;try{Invoke-Generation $lease (New-Support $lease)}catch{$failed=$true;Assert-Condition ($_.Exception.Message -like '*restoration is uncertain*') 'Wrong uncertainty diagnostic.'}
        Assert-Condition $failed 'Uncertain rollback succeeded.';Assert-Condition ([IO.File]::Exists($lease.Marker)) 'Uncertain rollback discarded marker.'
        Assert-Condition (@(Get-ChildItem -LiteralPath $bin -Directory -Filter '.winsmux-install-*'|ForEach-Object {Test-Path (Join-Path $_.FullName 'old-support-001')}) -contains $true) 'Settings backup was lost.'
    }finally{$lease.Stream.Dispose()}
    Set-Item Function:Invoke-WinsmuxInstallCheckpoint $checkpoint
    $lease=Open-WinsmuxInstallLease $bin -RecoverPending
    try{Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'Retry changed original bytes.'}finally{$lease.Stream.Dispose()}
}
foreach($mode in @('tampered','missing','no-space','startup-failed')) {
    Run-Case ('stage-'+$mode) {
        param($root)
        $bin=New-Fixture $root;$before=Read-ProtectedInventory $root;$lease=Open-WinsmuxInstallLease $bin
        try {
            switch($mode){
                'tampered'{[IO.File]::WriteAllBytes((Join-Path $root 'download.exe'),[byte[]]@(77))}
                'missing'{[IO.File]::Delete((Join-Path $root 'download.exe'))}
                'no-space'{Set-Item Function:Write-WinsmuxInstallFile {param($Path,$Bytes) throw 'Simulated disk full.'}}
                'startup-failed'{$script:StartupFailure=$true}
            }
            $failed=$false;try{Invoke-Generation $lease (New-Support $lease)}catch{$failed=$true}
            Assert-Condition $failed 'Invalid stage accepted.';Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'Staging failure modified installed bytes.'
            Assert-Condition (-not [IO.File]::Exists($lease.Marker)) 'Staging failure opened transaction.'
        }finally{$lease.Stream.Dispose()}
    }
}
Run-Case 'uninstall-owned-only' {
    param($root)
    $bin=New-Fixture $root;$lease=Open-WinsmuxInstallLease $bin
    try{Invoke-Generation $lease (New-Support $lease)}finally{$lease.Stream.Dispose()}
    $project=Join-Path $root '.winsmux/projects/user-project/project.json';$projectHash=Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes($project));$binaryHash=Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes((Join-Path $bin 'winsmux.exe')))
    $modified=Join-Path $root '.winsmux.conf';[IO.File]::WriteAllText($modified,'user-modified-settings',$utf8)
    $appdata=Join-Path $root 'AppData/winsmux/projects';[void][IO.Directory]::CreateDirectory($appdata);[IO.File]::WriteAllBytes((Join-Path $appdata 'project.bin'),[byte[]]@(2,255))
    Invoke-Uninstall
    Assert-Condition ((Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes($project))) -ceq $projectHash) 'Uninstall changed user project.'
    Assert-Condition ((Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes((Join-Path $bin 'winsmux.exe')))) -ceq $binaryHash) 'Uninstall removed standalone binary.'
    Assert-Condition ([IO.File]::ReadAllText($modified) -ceq 'user-modified-settings') 'Uninstall removed modified file.'
    Assert-Condition ([IO.File]::ReadAllText((Join-Path $root '.winsmux/unknown.txt')) -ceq 'unknown-user-file') 'Unknown file removed.'
    Assert-Condition ([IO.File]::Exists((Join-Path $appdata 'project.bin'))) 'AppData project removed.'
    Assert-Condition (-not [IO.File]::Exists((Join-Path $root '.winsmux/bin/winsmux-core.ps1'))) 'Unchanged owned support retained.'
    Assert-Condition ([IO.File]::ReadAllText($script:ProfilePath) -ceq ('# unrelated profile'+"`n")) 'Uninstall changed unrelated profile bytes.'
}
Run-Case 'uninstall-unowned-receipt-path' {
    param($root)
    $bin=New-Fixture $root;$before=Read-ProtectedInventory $root;$lease=Open-WinsmuxInstallLease $bin
    try{
        $receipt=@{schema='winsmux-support-owner/v1';files=@(@{name='.winsmux/projects/user-project/project.json';sha256=('a'*64)});profile_line='not-managed'}
        [IO.File]::WriteAllText((Get-WinsmuxMemberPath $lease '.winsmux/install-owner.json'),(ConvertTo-Json $receipt -Depth 5),$utf8)
    }finally{$lease.Stream.Dispose()}
    $failed=$false;try{Invoke-Uninstall}catch{$failed=$true}
    Assert-Condition $failed 'Unknown receipt authorized deletion.'
    Assert-Condition ([IO.File]::Exists((Join-Path $root '.winsmux/projects/user-project/project.json'))) 'Unknown receipt deleted project.'
}

$downloadFunction=(Get-Item Function:Download-File).ScriptBlock
$optionalFunction=(Get-Item Function:Download-OptionalFile).ScriptBlock
foreach($mode in @('success','required-missing','optional-probe-failed')) {
    Run-Case ('support-acquisition-'+$mode) {
        param($root)
        $bin=New-Fixture $root;$before=Read-ProtectedInventory $root;$lease=Open-WinsmuxInstallLease $bin
        $ResolvedVersion='0.38.0';$ResolvedReleaseTag='v0.38.0'
        try {
            Set-Item Function:Download-File {
                param($Relative,$Destination)
                if($mode -ceq 'required-missing' -and $Relative -ceq '.winsmux.conf'){throw 'Required support missing.'}
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
                [IO.File]::WriteAllText($Destination,('fixture-'+$Relative),[Text.UTF8Encoding]::new($false))
            }
            Set-Item Function:Download-OptionalFile {
                param($Relative,$Destination)
                if($mode -ceq 'optional-probe-failed'){throw 'Optional transport unavailable.'}
                Download-File $Relative $Destination
            }
            $failed=$false;$support=$null
            try{$support=New-WinsmuxSupportStage $lease 'full' $true}catch{$failed=$true}
            if($mode -ceq 'success') {
                Assert-Condition (-not $failed -and $support.Members.Count -ge 111) 'Full support staging failed or incomplete.'
                foreach($item in $support.Members){[void](Assert-WinsmuxInstallPath $item.Stage File)}
                Assert-Condition (@($support.ProcessPath -split ';' | Where-Object { $_ -ieq $lease.LocalBin }).Count -eq 1) 'Process PATH omitted/duplicated standalone entrance.'
                Assert-Condition (@($support.ProcessPath -split ';' | Where-Object { $_ -ieq (Join-Path $root '.winsmux/bin') }).Count -eq 1) 'Process PATH omitted/duplicated wrapper entrance.'
            }else{Assert-Condition $failed 'Failed support acquisition accepted.'}
            Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'Acquisition modified protected files.'
            Assert-Condition ($script:UserPath -ceq 'prior-user-path') 'Acquisition modified registration.'
            Assert-Condition (-not [IO.File]::Exists($lease.Marker)) 'Acquisition opened publication.'
        }finally{$lease.Stream.Dispose();Set-Item Function:Download-File $downloadFunction;Set-Item Function:Download-OptionalFile $optionalFunction}
    }
}


foreach($mode in @('success','collection-failed','modified-backup')) {
    Run-Case ('committed-support-cleanup-'+$mode) {
        param($root)
        $bin=New-Fixture $root;$lease=Open-WinsmuxInstallLease $bin
        try {
            Invoke-Generation $lease (New-Support $lease)
            $support=New-Support $lease
            $config=@($support.Members | Where-Object Name -ceq '.winsmux.conf')[0]
            [IO.File]::WriteAllText($config.Stage,'second-generation-settings',$utf8)
            $script:CleanupReached=$false
            Set-Item Function:Invoke-WinsmuxInstallCheckpoint {
                param($Phase)
                if($Phase -ceq 'before-cleanup-support-000') {
                    $script:CleanupReached=$true
                    if($mode -ceq 'collection-failed'){throw 'Injected owned backup collection failure.'}
                }
                if($Phase -ceq 'generation-committed' -and $mode -ceq 'modified-backup') {
                    $roots=@(Get-ChildItem -LiteralPath $bin -Directory -Filter '.winsmux-install-*' | Sort-Object LastWriteTime)
                    [IO.File]::WriteAllText((Join-Path $roots[-1].FullName 'old-support-000'),'changed-backup-preserve',$utf8)
                }
            }
            Invoke-Generation $lease $support
            $roots=@(Get-ChildItem -LiteralPath $bin -Directory -Filter '.winsmux-install-*' | Sort-Object LastWriteTime)
            $current=$roots[-1].FullName;$backup=Join-Path $current 'old-support-000'
            Assert-Condition ([IO.File]::Exists((Join-Path $current 'committed'))) 'Cleanup lost committed witness.'
            Assert-Condition (-not [IO.File]::Exists($lease.Marker)) 'Safe committed completion retained marker.'
            Assert-Condition ([IO.File]::ReadAllText((Join-Path $root '.winsmux.conf')) -ceq 'second-generation-settings') 'Cleanup failure rolled back committed settings.'
            if($mode -ceq 'success') { Assert-Condition ($script:CleanupReached -and -not [IO.File]::Exists($backup)) 'Owned unchanged support backup was not collected.' }
            elseif($mode -ceq 'collection-failed') { Assert-Condition ($script:CleanupReached -and [IO.File]::Exists($backup)) 'Collection failure lost backup.' }
            else { Assert-Condition ([IO.File]::ReadAllText($backup) -ceq 'changed-backup-preserve') 'Modified backup was deleted.' }
            Assert-Condition ([IO.File]::Exists((Join-Path $current 'old-exe'))) 'Existing paired backup retention changed.'
        }finally{$lease.Stream.Dispose()}
    }
}
Run-Case 'uninstall-no-owner' {
    param($root)
    $bin=New-Fixture $root;$before=Read-ProtectedInventory $root
    Invoke-Uninstall
    Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'Missing ownership receipt deleted existing files.'
}


foreach($userState in @('missing','empty','populated')) {
    foreach($processState in @('missing','empty','populated')) {
        Run-Case ('path-restore-'+$userState+'-'+$processState) {
            param($root)
            $bin=New-Fixture $root
            $userValue=switch($userState){'missing'{$null};'empty'{''};'populated'{'original-user-path'}}
            $processValue=switch($processState){'missing'{$null};'empty'{''};'populated'{'original-process-path'}}
            Set-InstallUserPath $userValue;$env:Path=$processValue
            $lease=Open-WinsmuxInstallLease $bin;$before=Read-ProtectedInventory $root
            try {
                $script:FaultReached=$false
                Set-Item Function:Invoke-WinsmuxInstallCheckpoint {param($Phase) if($Phase -ceq 'before-readback'){$script:FaultReached=$true;throw 'Restore nullable registrations.'}}
                $failed=$false;try{Invoke-Generation $lease (New-Support $lease)}catch{$failed=$true}
                Assert-Condition ($failed -and $script:FaultReached) 'Nullable registration publication boundary was not reached.'
                Assert-Condition ((Test-WinsmuxNullablePath (Get-InstallUserPath) $userValue) -and (Test-WinsmuxNullablePath $env:Path $processValue)) 'Missing/empty/populated PATH restoration changed representation.'
                Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'Nullable restoration changed protected files.'
                Assert-Condition (-not [IO.File]::Exists($lease.Marker)) 'Verified nullable restoration retained pending marker.'
            }finally{$lease.Stream.Dispose()}
        }
    }
}
foreach($state in @('missing','empty','populated')) {
    Run-Case ('source-setter-'+$state) {
        param($root)
        # Preserve the exact product setter body, projecting only the fixed PATH
        # name and User target to a private variable in this child process. No
        # user registry, PATH, redirect gate or value conversion is executed away.
        $definition=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Set-InstallUserPath'},$true))[0].Extent.Text
        $projected=$definition.Replace('function Set-InstallUserPath','function Set-PrivateProcessProbe').Replace("SetEnvironmentVariable('Path', `$environmentValue, 'User')","SetEnvironmentVariable('WINSMUX_TASK880_SOURCE_SETTER_PROBE', `$environmentValue, 'Process')")
        Assert-Condition ($projected -cne $definition -and $projected -notlike "*SetEnvironmentVariable('Path'*" ) 'Source setter projection did not isolate the target.'
        . ([scriptblock]::Create($projected))
        $redirectedInstallerE2e=$false
        $value=switch($state){'missing'{$null};'empty'{''};'populated'{'private-populated-path'}}
        try {
            Set-PrivateProcessProbe $value
            $actual=[Environment]::GetEnvironmentVariable('WINSMUX_TASK880_SOURCE_SETTER_PROBE','Process')
            Assert-Condition ($actual -ceq $value) 'Product setter collapsed null/empty/populated representation.'
            $exists=[Environment]::GetEnvironmentVariables('Process').Contains('WINSMUX_TASK880_SOURCE_SETTER_PROBE')
            Assert-Condition ($exists -eq ($state -cne 'missing')) 'Product setter changed private variable presence.'
        }finally{[Environment]::SetEnvironmentVariable('WINSMUX_TASK880_SOURCE_SETTER_PROBE',[Management.Automation.Language.NullString]::Value,'Process')}
    }
}
foreach($directoryCount in @(0,1,2)) {
    Run-Case ('journal-directories-'+$directoryCount) {
        param($root)
        $bin=New-Fixture $root;$lease=Open-WinsmuxInstallLease $bin
        $selected=[Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
        $selected.Add('manifest.json',$utf8.GetBytes('verified-root'))
        if($directoryCount -ge 1){$selected.Add('licenses/manifest.json',$utf8.GetBytes('verified-one-directory'))}
        if($directoryCount -ge 2){$selected.Add('licenses/text/component.txt',$utf8.GetBytes('verified-two-directories'))}
        $sidecar=[PSCustomObject]@{Files=$selected;ArchiveSha256=('a'*64);Manifest=@{version='0.38.0';release_tag='v0.38.0';asset_name='winsmux-x64.exe';target='x86_64-pc-windows-msvc';executable_sha256=(Get-WinsmuxBytesSha256 $binaryBytes)}}
        try {
            Invoke-Generation $lease $null
            $owner=Read-WinsmuxInstallOwner (Join-Path $bin 'winsmux-licenses.owner.json')
            $journal=Read-WinsmuxRecoveryJournal $lease (Join-Path $bin ('.winsmux-install-'+$owner.operation_id))
            $entry=@($journal.members|Where-Object name -ceq 'licenses')[0]
            Assert-Condition ($entry.new_directories -is [array] -and $entry.new_directories.Count -eq $directoryCount) 'Journal changed 0/1/many directory collection shape.'
        }finally{$lease.Stream.Dispose()}
    }
}

# Frozen family: admission precedes canonical lifecycle/publication; every move
# preserves identity, and observed external PATH never becomes installer-owned.
foreach($count in @(0,1,2)) {
    Run-Case ('volume-admission-members-'+$count) {
        param($root)
        $bin=New-Fixture $root;$before=Read-ProtectedInventory $root;$lease=Open-WinsmuxInstallLease $bin
        try {
            $support=if($count -eq 0){$null}else{New-Support $lease}
            if($count -eq 1){$keep=@($support.Members|Where-Object Name -ceq 'profile');$support.Members.Clear();$support.Members.Add($keep[0])}
            $script:CrossVolumeTarget=if($count -eq 0){Join-Path $root '.winsmux/bin/install.ps1'}elseif($count -eq 1){$script:ProfilePath}else{Get-WinsmuxMemberPath $lease 'terminal-fragment'}
            Set-Item Function:Get-WinsmuxInstallVolume {param($Path,$Kind='Either') if([IO.Path]::GetFullPath($Path) -ceq [IO.Path]::GetFullPath($script:CrossVolumeTarget)){return 'ffffffff'}; & $volumeResolver $Path $Kind}
            $failed=$false;try{Invoke-Generation $lease $support}catch{$failed=$true;Assert-Condition ($_.Exception.Message -like '*physical volumes*') 'Wrong volume admission failure.'}
            Assert-Condition $failed 'Cross-volume generation accepted.'
            Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'Admission changed prior bytes.'
            Assert-Condition (-not [IO.File]::Exists((Join-Path $root '.winsmux/bin/install.ps1'))) 'Admission published lifecycle.'
            Assert-Condition (-not [IO.File]::Exists($lease.Marker)) 'Admission created pending publication.'
        }finally{$lease.Stream.Dispose()}
    }
}
Run-Case 'volume-change-before-admission' {
    param($root)
    $bin=New-Fixture $root;$before=Read-ProtectedInventory $root;$lease=Open-WinsmuxInstallLease $bin
    try {
        $script:CrossVolumeTarget=$script:ProfilePath;$script:VolumeChanged=$false
        Set-Item Function:Get-WinsmuxInstallVolume {param($Path,$Kind='Either') if($script:VolumeChanged -and $Path -ceq $script:CrossVolumeTarget){return 'ffffffff'};& $volumeResolver $Path $Kind}
        Set-Item Function:Invoke-WinsmuxInstallCheckpoint {param($Phase) if($Phase -ceq 'before-volume-admission'){$script:VolumeChanged=$true}}
        $failed=$false;try{Invoke-Generation $lease (New-Support $lease)}catch{$failed=$true}
        Assert-Condition ($failed -and $script:VolumeChanged) 'Changed volume not refused.'
        Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'Changed volume admission lost old bytes.'
        Assert-Condition (-not [IO.File]::Exists((Join-Path $root '.winsmux/bin/install.ps1'))) 'Changed volume published lifecycle.'
    }finally{$lease.Stream.Dispose()}
}
Run-Case 'rename-volume-and-identity' {
    param($root)
    $from=Join-Path $root 'from';$to=Join-Path $root 'to'
    [IO.File]::WriteAllText($from,'rename-bytes',$utf8);$identity=(Assert-WinsmuxInstallPath $from File).Identity
    Move-WinsmuxInstallMember $from $to File
    Assert-Condition ((Assert-WinsmuxInstallPath $to File).Identity -ceq $identity) 'Native rename changed identity.'
    $script:CrossVolumeTarget=$from
    Set-Item Function:Get-WinsmuxInstallVolume {param($Path,$Kind='Either') if($Path -ceq $script:CrossVolumeTarget){return 'ffffffff'};& $volumeResolver $Path $Kind}
    $failed=$false;try{Move-WinsmuxInstallMember $to $from File}catch{$failed=$true}
    Assert-Condition ($failed -and [IO.File]::Exists($to) -and -not [IO.File]::Exists($from)) 'Primitive allowed cross-volume mutation.'
    Assert-Condition ((Assert-WinsmuxInstallPath $to File).Identity -ceq $identity) 'Refused rename lost identity.'
    $native=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Initialize-WinsmuxInstallPathInfo'},$true))[0].Extent.Text
    Assert-Condition ($native.Contains('destination, 0)') -and $native -notmatch 'destination, [1-9]') 'Native move enables copy fallback.'
}
foreach($slotName in @('user','process')) {
    foreach($boundaryPhase in @('before-registration',('registration-'+$slotName+'-write-intent'),('registration-'+$slotName+'-written'),('registration-'+$slotName+'-confirmed'),'readback-complete')) {
        Run-Case ('path-external-'+$slotName+'-'+$boundaryPhase) {
            param($root)
            $bin=New-Fixture $root;$before=Read-ProtectedInventory $root;$lease=Open-WinsmuxInstallLease $bin
            try {
                $script:FaultReached=$false
                Set-Item Function:Invoke-WinsmuxInstallCheckpoint {param($Phase) if($Phase -ceq $boundaryPhase){$script:FaultReached=$true;Set-WinsmuxRegistrationPath $slotName 'external-X';if($Phase -cne 'before-registration' -and $Phase -cne 'readback-complete'){throw 'External PATH publication boundary.'}}}
                $failed=$false;try{Invoke-Generation $lease (New-Support $lease)}catch{$failed=$true}
                Assert-Condition ($failed -and $script:FaultReached) 'External PATH boundary not reached.'
                Assert-Condition (Test-WinsmuxNullablePath (Get-WinsmuxRegistrationPath $slotName) 'external-X') 'Observed external PATH overwritten.'
                Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'External PATH blocked paired byte restoration.'
                Assert-Condition ([IO.File]::Exists($lease.Marker)) 'External PATH uncertainty discarded marker.'
                Set-Item Function:Invoke-WinsmuxInstallCheckpoint $checkpoint
                $failed=$false;try{Repair-WinsmuxPendingInstallation $lease}catch{$failed=$true}
                Assert-Condition $failed 'External PATH recovery reported success.'
                Assert-Condition (Test-WinsmuxNullablePath (Get-WinsmuxRegistrationPath $slotName) 'external-X') 'Recovery overwrote external PATH.'
                Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'Recovery changed restored prior files.'
                Assert-Condition ([IO.File]::Exists($lease.Marker)) 'Recovery discarded unknown marker.'
            }finally{$lease.Stream.Dispose()}
        }
    }
}
foreach($slotName in @('user','process')) {
    foreach($phaseTail in @('write-intent','written','restore-intent')) {
        $crashPhase='registration-'+$slotName+'-'+$phaseTail
        Run-Case ('restart-uncertain-'+$crashPhase) {
            param($root)
            $bin=New-Fixture $root;$before=Read-ProtectedInventory $root
            $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WorkingDirectory=$repo;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            foreach($arg in @('-NoLogo','-NoProfile','-File',$PSCommandPath,'-ChildRoot',$root,'-ChildPhase',$crashPhase)){$start.ArgumentList.Add($arg)}
            $process=[Diagnostics.Process]::Start($start);$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync();$process.WaitForExit();$record=@{exit=$process.ExitCode;stdout=$out.GetAwaiter().GetResult();stderr=$err.GetAwaiter().GetResult()};$process.Dispose()
            [IO.File]::WriteAllText((Join-Path $root 'child.json'),(ConvertTo-Json $record),$utf8)
            Assert-Condition ($record.exit -eq 73) 'Child did not reach intended PATH interruption.'
            $uncertainValue=Get-WinsmuxRegistrationPath $slotName
            $failed=$false;$lease=$null
            try { $lease=Open-WinsmuxInstallLease $bin -RecoverPending } catch { $failed=$true }
            finally { if($lease){$lease.Stream.Dispose()} }
            Assert-Condition $failed 'Unconfirmed crash converted to success.'
            Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'Crash uncertainty did not restore paired bytes.'
            Assert-Condition (Test-WinsmuxNullablePath (Get-WinsmuxRegistrationPath $slotName) $uncertainValue) 'Crash uncertainty wrote PATH.'
            Assert-Condition ([IO.File]::Exists((Join-Path $bin 'winsmux.install.pending.json'))) 'Unconfirmed crash removed marker.'
        }
    }
}
Run-Case 'committed-external-user-path' {
    param($root)
    $bin=New-Fixture $root;$lease=Open-WinsmuxInstallLease $bin
    try {
        $script:FaultReached=$false
        Set-Item Function:Invoke-WinsmuxInstallCheckpoint {param($Phase) if($Phase -ceq 'generation-committed'){$script:FaultReached=$true;Set-InstallUserPath 'external-committed-X';throw 'Retain committed pending.'}}
        $failed=$false;try{Invoke-Generation $lease (New-Support $lease)}catch{$failed=$true}
        Assert-Condition ($failed -and $script:FaultReached) 'Commit boundary not reached.'
        $committed=Read-ProtectedInventory $root
        Set-Item Function:Invoke-WinsmuxInstallCheckpoint $checkpoint
        $failed=$false;try{Repair-WinsmuxPendingInstallation $lease}catch{$failed=$true}
        Assert-Condition $failed 'Committed external PATH accepted.'
        Assert-Condition ((Get-InstallUserPath) -ceq 'external-committed-X') 'Committed recovery overwrote X.'
        Assert-Condition ((Read-ProtectedInventory $root) -ceq $committed) 'Committed recovery rolled back files.'
        Assert-Condition ([IO.File]::Exists($lease.Marker)) 'Committed unknown marker lost.'
    }finally{$lease.Stream.Dispose()}
}


Run-Case 'volume-guid-same-serial-distinct' {
    param($root)
    $first=Join-Path $root 'first';$second=Join-Path $root 'second'
    Set-Item Function:Assert-WinsmuxInstallPath {
        param($Path,$Kind='Either',[switch]$AllowMissing)
        if($Path -ceq $first) { return [PSCustomObject]@{Identity='12345678:0000000000000001';Name='\\?\Volume{11111111-1111-1111-1111-111111111111}\first'} }
        if($Path -ceq $second) { return [PSCustomObject]@{Identity='12345678:0000000000000002';Name='\\?\Volume{22222222-2222-2222-2222-222222222222}\second'} }
        & $pathInspector $Path $Kind -AllowMissing:$AllowMissing
    }
    $one=Get-WinsmuxInstallVolume $first File;$two=Get-WinsmuxInstallVolume $second File
    Assert-Condition ($one -cne $two -and $one -like '*11111111*' -and $two -like '*22222222*') 'Same serial collapsed distinct physical Volume GUIDs.'
}


# Profile bytes stay typed and separate from existence through stage and rollback.
function New-ProfileSupport($Lease) {
    $ResolvedVersion='0.38.0';$ResolvedReleaseTag='v0.38.0'
    $download=(Get-Item Function:Download-File).ScriptBlock
    $optional=(Get-Item Function:Download-OptionalFile).ScriptBlock
    try {
        Set-Item Function:Download-File {
            param($Relative,$Destination)
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
            [IO.File]::WriteAllText($Destination,('fixture-'+$Relative),[Text.UTF8Encoding]::new($false))
        }
        Set-Item Function:Download-OptionalFile {param($Relative,$Destination) Download-File $Relative $Destination}
        return (New-WinsmuxSupportStage $Lease 'full' $true)
    } finally {Set-Item Function:Download-File $download;Set-Item Function:Download-OptionalFile $optional}
}
function Assert-ProfileBytes([string]$Path,[byte[]]$Expected) {
    $actual=[IO.File]::ReadAllBytes($Path)
    Assert-Condition ($actual.Length -eq $Expected.Length -and [Convert]::ToBase64String($actual) -ceq [Convert]::ToBase64String($Expected)) 'Profile bytes differ.'
}
foreach($shape in @('missing','empty','one')) {
    Run-Case ('profile-shape-'+$shape) {
        param($root)
        $bin=New-Fixture $root
        $prior=[byte[]]::new(0)
        if($shape -ceq 'missing'){[IO.File]::Delete($script:ProfilePath)}
        else {if($shape -ceq 'one'){$prior=[byte[]]@(35)};[IO.File]::WriteAllBytes($script:ProfilePath,$prior)}
        $before=Read-ProtectedInventory $root;$snapshot=Get-WinsmuxInstallSnapshot $script:ProfilePath File
        $lease=Open-WinsmuxInstallLease $bin
        try {
            $support=New-ProfileSupport $lease
            $member=@($support.Members|Where-Object Name -ceq 'profile')[0]
            $expected=[byte[]]($prior+$utf8.GetBytes("`n# winsmux`n"+$support.ProfileLine+"`n"))
            Assert-ProfileBytes $member.Stage $expected
            Assert-Condition ((Read-ProtectedInventory $root) -ceq $before -and -not [IO.File]::Exists($lease.Marker)) 'Profile stage changed canonical state.'
            [void](Assert-WinsmuxInstallSnapshot $script:ProfilePath $snapshot)
        } finally {$lease.Stream.Dispose()}
    }
}
$profileEncodings=@(
    @{Name='utf8';Encoding=[Text.UTF8Encoding]::new($false,$true)},
    @{Name='utf8bom';Encoding=[Text.UTF8Encoding]::new($true,$true)},
    @{Name='utf16le';Encoding=[Text.UnicodeEncoding]::new($false,$true)},
    @{Name='utf16be';Encoding=[Text.UnicodeEncoding]::new($true,$true)},
    @{Name='utf32le';Encoding=[Text.UTF32Encoding]::new($false,$true)},
    @{Name='utf32be';Encoding=[Text.UTF32Encoding]::new($true,$true)}
)
foreach($encodingCase in $profileEncodings) {
    foreach($profileMode in @('append','existing','mixed')) {
        Run-Case ('profile-encoding-'+$encodingCase.Name+'-'+$profileMode) {
            param($root)
            $bin=New-Fixture $root;$encoding=$encodingCase.Encoding
            $line='$env:PATH = "'+(Join-Path $root '.winsmux/bin')+';$env:PATH"'
            $block="# winsmux`r`n"+$line+"`r`n"
            $prefix="# unrelated alpha`r`n";$suffix="# unrelated omega`n"
            $text=switch($profileMode){'append'{$prefix+$suffix};'existing'{$block};'mixed'{$prefix+$block+$suffix}}
            $original=[byte[]]($encoding.GetPreamble()+$encoding.GetBytes($text))
            [IO.File]::WriteAllBytes($script:ProfilePath,$original)
            if($profileMode -ceq 'append'){Remove-WinsmuxProfileBlock $script:ProfilePath $line;Assert-ProfileBytes $script:ProfilePath $original}
            $before=Read-ProtectedInventory $root;$lease=Open-WinsmuxInstallLease $bin
            try {
                $support=New-ProfileSupport $lease;$member=@($support.Members|Where-Object Name -ceq 'profile')[0]
                $expected=$original
                if($profileMode -ceq 'append'){$expected=[byte[]]($original+$encoding.GetBytes("`n# winsmux`n"+$line+"`n"))}
                Assert-ProfileBytes $member.Stage $expected
                Assert-Condition ((Read-ProtectedInventory $root) -ceq $before -and -not [IO.File]::Exists($lease.Marker)) 'Encoding stage changed canonical state.'
                Remove-WinsmuxProfileBlock $member.Stage $line
                $afterText=switch($profileMode){'append'{$text+"`n"};'existing'{''};'mixed'{$prefix+$suffix}}
                $after=[byte[]]($encoding.GetPreamble()+$encoding.GetBytes($afterText))
                Assert-ProfileBytes $member.Stage $after
            } finally {$lease.Stream.Dispose()}
        }
    }
}
foreach($shape in @('missing','empty')) {
    Run-Case ('profile-restore-'+$shape) {
        param($root)
        $bin=New-Fixture $root
        if($shape -ceq 'missing'){[IO.File]::Delete($script:ProfilePath)}else{[IO.File]::WriteAllBytes($script:ProfilePath,[byte[]]::new(0))}
        $before=Read-ProtectedInventory $root;$snapshot=Get-WinsmuxInstallSnapshot $script:ProfilePath File
        $priorPath=Get-InstallUserPath;$processPath=$env:Path;$lease=Open-WinsmuxInstallLease $bin
        try {
            $support=New-ProfileSupport $lease;$script:FaultReached=$false
            Set-Item Function:Invoke-WinsmuxInstallCheckpoint {
                param($Phase)
                if($Phase -ceq 'before-readback'){
                    $script:FaultReached=$true
                    Assert-Condition ([IO.File]::Exists($script:ProfilePath) -and [IO.File]::ReadAllBytes($script:ProfilePath).Length -gt 0) 'Profile publication was not reached.'
                    throw 'Injected failure after profile publication.'
                }
            }
            $failed=$false;try{Invoke-Generation $lease $support}catch{$failed=$true}
            Assert-Condition ($failed -and $script:FaultReached) 'Profile rollback fault was not reached.'
            [void](Assert-WinsmuxInstallSnapshot $script:ProfilePath $snapshot)
            Assert-Condition ((Read-ProtectedInventory $root) -ceq $before) 'Profile rollback changed protected bytes.'
            Assert-Condition ((Get-InstallUserPath) -ceq $priorPath -and $env:Path -ceq $processPath -and -not [IO.File]::Exists($lease.Marker)) 'Profile rollback changed registration or retained pending marker.'
        } finally {$lease.Stream.Dispose()}
    }
}


# The entry is one exact owned member. Its body/CMD reuse the fixed independent
# self-removal process proof; these cases exercise acquisition and transactions.
function Get-WrapperEntryFixtureBytes {
    $definition=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-WinsmuxSupportStage'},$true))
    Assert-Condition ($definition.Count -eq 1) 'Support stage function differs.'
    $files=@{}
    foreach($variable in @('wrapper','entryScript')) {
        $values=@($definition[0].FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq $variable -and $node.Right -is [Management.Automation.Language.CommandExpressionAst] -and $node.Right.Expression -is [Management.Automation.Language.StringConstantExpressionAst]},$true))
        Assert-Condition ($values.Count -eq 1) 'Support entry literal differs.'
        $text=([string]$values[0].Right.Expression.Value).Replace(([string][char]13+[char]10),[string][char]10)+[char]10
        $files[$variable]=[Text.UTF8Encoding]::new($false).GetBytes($text)
    }
    Assert-Condition ($files.wrapper.Length -eq 130 -and (Get-WinsmuxBytesSha256 $files.wrapper) -ceq 'd059bd613f24aa8ecbc64b0ca56751f87287d69ba71e8f4898859c0391d7428b') 'CMD differs from fixed process proof.'
    Assert-Condition ($files.entryScript.Length -eq 661 -and (Get-WinsmuxBytesSha256 $files.entryScript) -ceq '6775b2aea0087e596b134857c0d680027efec7d95fb2c54f8624d80f69e3877f') 'Entry differs from fixed process proof.'
    return [PSCustomObject]@{Cmd=$files.wrapper;Entry=$files.entryScript}
}
function New-EntrySupport($Lease,[AllowNull()][byte[]]$PriorEntryBytes=$null) {
    $support=New-Support $Lease;$fixed=Get-WrapperEntryFixtureBytes
    $entryBytes=if($null -eq $PriorEntryBytes){$fixed.Entry}else{$PriorEntryBytes}
    foreach($item in @(@{Name='.winsmux/bin/winsmux-entry.ps1';Bytes=$entryBytes;File='entry.ps1'},@{Name='.winsmux/bin/winsmux.cmd';Bytes=$fixed.Cmd;File='entry.cmd'})) {
        $stage=Join-Path $support.Root $item.File;[IO.File]::WriteAllBytes($stage,[byte[]]$item.Bytes)
        $support.Members.Add([PSCustomObject]@{Name=$item.Name;Stage=$stage;Remove=$false})
    }
    return $support
}
function Assert-EntryReceipt($Lease,[string]$ExpectedSha256) {
    $owner=Read-WinsmuxSupportOwner $Lease;$rows=@($owner.files|Where-Object name -ceq '.winsmux/bin/winsmux-entry.ps1')
    Assert-Condition ($rows.Count -eq 1 -and $rows[0].sha256 -ceq $ExpectedSha256) 'New entry ownership receipt differs.'
}
Run-Case 'wrapper-entry-stage-bytes' {
    param($root)
    $bin=New-Fixture $root;$before=Read-ProtectedInventory $root;$lease=Open-WinsmuxInstallLease $bin
    try {
        $fixed=Get-WrapperEntryFixtureBytes;$support=New-ProfileSupport $lease
        foreach($expected in @(@{Name='.winsmux/bin/winsmux.cmd';Bytes=$fixed.Cmd},@{Name='.winsmux/bin/winsmux-entry.ps1';Bytes=$fixed.Entry})) {
            $rows=@($support.Members|Where-Object Name -ceq $expected.Name)
            Assert-Condition ($rows.Count -eq 1) 'Generated entry member differs.'
            Assert-ProfileBytes $rows[0].Stage $expected.Bytes
        }
        Assert-Condition ((Read-ProtectedInventory $root) -ceq $before -and -not [IO.File]::Exists($lease.Marker)) 'Entry staging changed product/profile state.'
    } finally {$lease.Stream.Dispose()}
}
Run-Case 'wrapper-entry-legacy-absent' {
    param($root)
    $bin=New-Fixture $root;$lease=Open-WinsmuxInstallLease $bin
    try {
        Invoke-Generation $lease (New-Support $lease)
        $prior=Read-WinsmuxSupportOwner $lease
        Assert-Condition (@($prior.files|Where-Object name -ceq '.winsmux/bin/winsmux-entry.ps1').Count -eq 0 -and -not [IO.File]::Exists((Join-Path $root '.winsmux/bin/winsmux-entry.ps1'))) 'Legacy absence fixture differs.'
        Invoke-Generation $lease (New-EntrySupport $lease)
        Assert-EntryReceipt $lease '6775b2aea0087e596b134857c0d680027efec7d95fb2c54f8624d80f69e3877f'
        Assert-Condition ((Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes((Join-Path $root '.winsmux/bin/winsmux-entry.ps1')))) -ceq '6775b2aea0087e596b134857c0d680027efec7d95fb2c54f8624d80f69e3877f' -and -not [IO.File]::Exists($lease.Marker)) 'Legacy entry admission failed.'
    } finally {$lease.Stream.Dispose()}
}
Run-Case 'wrapper-entry-owned-update' {
    param($root)
    $bin=New-Fixture $root;$lease=Open-WinsmuxInstallLease $bin;$old=$utf8.GetBytes('prior-owned-entry'+[char]10)
    try {
        Invoke-Generation $lease (New-EntrySupport $lease $old)
        Assert-EntryReceipt $lease (Get-WinsmuxBytesSha256 $old)
        Invoke-Generation $lease (New-EntrySupport $lease)
        Assert-EntryReceipt $lease '6775b2aea0087e596b134857c0d680027efec7d95fb2c54f8624d80f69e3877f'
        Assert-Condition ((Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes((Join-Path $root '.winsmux/bin/winsmux-entry.ps1')))) -ceq '6775b2aea0087e596b134857c0d680027efec7d95fb2c54f8624d80f69e3877f') 'Owned entry was not updated.'
    } finally {$lease.Stream.Dispose()}
}
foreach($collision in @('no-owner','legacy-receipt','modified-owned')) {
    Run-Case ('wrapper-entry-refuse-'+$collision) {
        param($root)
        $bin=New-Fixture $root;$lease=Open-WinsmuxInstallLease $bin
        try {
            if($collision -ceq 'legacy-receipt'){Invoke-Generation $lease (New-Support $lease)}
            elseif($collision -ceq 'modified-owned'){Invoke-Generation $lease (New-EntrySupport $lease)}
            $path=Join-Path $root '.winsmux/bin/winsmux-entry.ps1';[IO.File]::WriteAllText($path,'user-owned-or-modified-entry',$utf8)
            $before=Read-ProtectedInventory $root;$priorUser=Get-InstallUserPath;$priorProcess=$env:Path;$script:PublicationReached=$false
            Set-Item Function:Invoke-WinsmuxInstallCheckpoint {param($Phase) if($Phase -in @('before-volume-admission','before-publish-lifecycle','published-lifecycle','marker-written')){$script:PublicationReached=$true}}
            $failed=$false
            try{Invoke-Generation $lease (New-EntrySupport $lease)}catch{$failed=$true;Assert-Condition ($_.Exception.Message -like '*Existing winsmux entry is not unchanged installer-owned support*') 'Wrong entry ownership refusal.'}
            Assert-Condition ($failed -and -not $script:PublicationReached -and -not [IO.File]::Exists($lease.Marker)) 'Entry collision reached publication.'
            Assert-Condition ((Read-ProtectedInventory $root) -ceq $before -and (Get-InstallUserPath) -ceq $priorUser -and $env:Path -ceq $priorProcess) 'Entry refusal changed product/profile/registration.'
        } finally {$lease.Stream.Dispose()}
    }
}
foreach($priorEntry in @('absent','old-owned')) {
    Run-Case ('wrapper-entry-rollback-'+$priorEntry) {
        param($root)
        $bin=New-Fixture $root;$lease=Open-WinsmuxInstallLease $bin
        try {
            if($priorEntry -ceq 'absent'){Invoke-Generation $lease (New-Support $lease)}else{Invoke-Generation $lease (New-EntrySupport $lease ($utf8.GetBytes('prior-owned-entry'+[char]10)))}
            $path=Join-Path $root '.winsmux/bin/winsmux-entry.ps1';$entrySnapshot=Get-WinsmuxInstallSnapshot $path File
            $before=Read-ProtectedInventory $root;$priorUser=Get-InstallUserPath;$priorProcess=$env:Path;$script:EntryFaultReached=$false
            Set-Item Function:Invoke-WinsmuxInstallCheckpoint {param($Phase) if($Phase -ceq 'published-support-005'){$script:EntryFaultReached=$true;throw 'Injected failure after new entry publication.'}}
            $failed=$false;try{Invoke-Generation $lease (New-EntrySupport $lease)}catch{$failed=$true}
            Assert-Condition ($failed -and $script:EntryFaultReached) 'Entry publication failure was not reached.'
            [void](Assert-WinsmuxInstallSnapshot $path $entrySnapshot)
            Assert-Condition ((Read-ProtectedInventory $root) -ceq $before -and (Get-InstallUserPath) -ceq $priorUser -and $env:Path -ceq $priorProcess -and -not [IO.File]::Exists($lease.Marker)) 'Entry rollback did not restore prior state.'
        } finally {$lease.Stream.Dispose()}
    }
}
foreach($entryState in @('owned','modified')) {
    Run-Case ('wrapper-entry-uninstall-'+$entryState) {
        param($root)
        $bin=New-Fixture $root;$lease=Open-WinsmuxInstallLease $bin
        try{Invoke-Generation $lease (New-EntrySupport $lease)}finally{$lease.Stream.Dispose()}
        $path=Join-Path $root '.winsmux/bin/winsmux-entry.ps1'
        if($entryState -ceq 'modified'){[IO.File]::WriteAllText($path,'modified-entry-preserve',$utf8)}
        $entrySha=Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes($path))
        $unknown=Join-Path $root '.winsmux/bin/user-helper.ps1';[IO.File]::WriteAllText($unknown,'unknown-user-helper',$utf8)
        $project=Join-Path $root '.winsmux/projects/user-project/project.json';$projectSha=Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes($project));$exeSha=Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes((Join-Path $bin 'winsmux.exe')))
        Invoke-Uninstall
        if($entryState -ceq 'owned'){Assert-Condition (-not [IO.File]::Exists($path)) 'Unchanged owned entry was retained.'}
        else{Assert-Condition ((Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes($path))) -ceq $entrySha) 'Modified entry was removed or changed.'}
        Assert-Condition (-not [IO.File]::Exists((Join-Path $root '.winsmux/bin/winsmux.cmd'))) 'Unchanged owned CMD was retained.'
        Assert-Condition ([IO.File]::ReadAllText($unknown) -ceq 'unknown-user-helper' -and [IO.File]::ReadAllText((Join-Path $root '.winsmux/unknown.txt')) -ceq 'unknown-user-file') 'Unknown user files were changed.'
        Assert-Condition ((Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes($project))) -ceq $projectSha -and (Get-WinsmuxBytesSha256 ([IO.File]::ReadAllBytes((Join-Path $bin 'winsmux.exe')))) -ceq $exeSha) 'User project or standalone executable was changed.'
    }
}

$receipt=@{schema='winsmux-install-lifecycle-proof/v1';scope='isolated Windows native filesystem; synthetic binary/sidecar/support; mocked profile/user PATH registration; class-wide update/rollback/recovery and uninstall preservation; no network or real user installation';passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object {-not $_.passed}).Count;cases=$results.ToArray()}
[IO.File]::WriteAllText((Join-Path $proofRoot 'result.json'),(ConvertTo-Json $receipt -Depth 10),$utf8)
Write-Output (ConvertTo-Json @{passed=$receipt.passed;failed=$receipt.failed;result=(Join-Path $proofRoot 'result.json')} -Compress)
if($SelectedCase -and $results.Count -ne $SelectedCase.Split(',').Count){throw 'Selected lifecycle proof count mismatch.'}
if($results.Count -eq 0){throw 'No lifecycle proof executed.'}
if($receipt.failed){$results|Where-Object {-not $_.passed}|ConvertTo-Json -Depth 8;exit 1}
