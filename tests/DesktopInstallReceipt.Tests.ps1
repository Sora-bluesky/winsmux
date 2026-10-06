BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'scripts/desktop-install-inventory.ps1')
    $tokens = $null; $errors = $null
    $script:HelperAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'scripts/test-public-release.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Helper parse failed.' }
    $script:DesktopOwnerSourceRoot = Join-Path $script:RepoRoot 'scripts'
    foreach ($name in @('Assert-Condition', 'Get-ObjectPropertyValue', 'Test-DesktopProcessDescendant', 'Stop-DesktopNormally', 'Assert-DesktopMcpResponse', 'Initialize-DesktopNativeTypes', 'Start-OwnedProcess', 'Get-OwnedProcessCapture', 'Stop-OwnedProcessTree', 'Invoke-DesktopOwnedNativeProcess', 'Assert-DesktopLifecyclePhase', 'Set-DesktopLifecyclePhase', 'Set-DesktopLifecyclePreserve', 'Invoke-DesktopCleanup')) {
        $function = $script:HelperAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)[0]
        . ([scriptblock]::Create($function.Extent.Text))
    }
    function New-InventoryFixture {
        $rows = @(
            @{ path = 'licenses/THIRD_PARTY_NOTICES.txt'; bytes = 3; sha256 = 'a' * 64 },
            @{ path = 'licenses/manifest.json'; bytes = 3; sha256 = 'b' * 64 },
            @{ path = 'licenses/texts/sample.txt'; bytes = 3; sha256 = 'c' * 64 },
            @{ path = 'winsmux-workspace-mcp.exe'; bytes = 3; sha256 = 'd' * 64 },
            @{ path = 'winsmux.exe'; bytes = 3; sha256 = 'e' * 64 }
        )
        return ([ordered]@{ schema = 'winsmux-desktop-install-inventory/v1'; version = '0.38.0'; source_commit = 'a' * 40; host = 'x86_64-pc-windows-msvc'; build_profile = 'release'; installer_asset = 'winsmux_0.38.0_x64-setup.exe'; installer_sha256 = 'f' * 64; generation_manifest_sha256 = 'b' * 64; files = $rows } | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    }
    function Confirm-Inventory($Inventory) { Assert-DesktopInstallInventory $Inventory '0.38.0' ('f' * 64) ('a' * 40) }
    function New-InstalledFixture {
        param($Inventory, [string]$Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        foreach ($row in $Inventory.files) {
            $path = Join-Path $Root $row.path
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [IO.File]::WriteAllText($path, 'abc', [Text.UTF8Encoding]::new($false))
            $row.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        foreach ($name in @('winsmux-app.exe', 'uninstall.exe')) { [IO.File]::WriteAllText((Join-Path $Root $name), 'owned') }
    }
    function New-ReceiptFixture {
        return ([ordered]@{ ok = $true; surface = 'Desktop'; version = '0.38.0'; release_tag = 'v0.38.0'; repository = 'example/winsmux'; evidence = @{ asset = 'winsmux_0.38.0_x64-setup.exe'; sha256 = 'f' * 64; version = '0.38.0'; page_url = 'tauri://localhost/' }; attempts = 6; retry_delay_seconds = 10; cleanup = 'clean'; installed_inventory = @{ schema = 'winsmux-desktop-installed-inventory/v1'; installer_sha256 = 'f' * 64; inventory_sha256 = 'c' * 64; generation_manifest_sha256 = 'b' * 64; source_commit = 'a' * 40; expected = 5; found = 5; sha256_match = 5; licenses = 3; pair_verified = $true; complete = $true }; desktop_runtime = @{ workspace_read_verified = $true; mcp_roundtrip_verified = $true; mcp_eof_exit_verified = $true; normal_close_requested = $true; owned_processes_exited = $true } } | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    }
}

Describe 'Desktop installer generation inventory' {
    It 'accepts the exact companion pair and complete license inventory bound to the installer and checkout' {
        $inventory = New-InventoryFixture
        (Confirm-Inventory $inventory).files.Count | Should -Be 5
    }

    It 'rejects missing, mixed, traversal, ADS, collisions and compiler assets in every inventory' -ForEach @(
        @{ mutation = 'missing_cli' }, @{ mutation = 'missing_mcp' }, @{ mutation = 'missing_license' }, @{ mutation = 'case_collision' },
        @{ mutation = 'traversal' }, @{ mutation = 'ads' }, @{ mutation = 'nsis' }, @{ mutation = 'manifest' }, @{ mutation = 'router' }, @{ mutation = 'zero_bytes' }, @{ mutation = 'fractional_bytes' }, @{ mutation = 'bad_hash' }, @{ mutation = 'installer_hash' }, @{ mutation = 'source_commit' }, @{ mutation = 'debug' }, @{ mutation = 'unknown_key' }, @{ mutation = 'unsorted' }
    ) {
        $inventory = New-InventoryFixture
        switch ($mutation) {
            'missing_cli' { $inventory.files = @($inventory.files | Where-Object path -cne 'winsmux.exe') }
            'missing_mcp' { $inventory.files = @($inventory.files | Where-Object path -cne 'winsmux-workspace-mcp.exe') }
            'missing_license' { $inventory.files = @($inventory.files | Where-Object path -cne 'licenses/manifest.json') }
            'case_collision' { $row = $inventory.files[0] | ConvertTo-Json | ConvertFrom-Json; $row.path = 'licenses/third_party_notices.txt'; $inventory.files += $row }
            'traversal' { $inventory.files[0].path = 'licenses/../escape' }
            'ads' { $inventory.files[0].path = 'licenses/manifest.json:payload' }
            'nsis' { $inventory.files[0].path = 'nsis/plugins/winsmux_nsis_utils.dll' }
            'manifest' { $inventory.files[0].path = 'distribution-manifest.json' }
            'router' { $inventory.files[0].path = 'winsmux-core/scripts/coordinator-router.ps1' }
            'zero_bytes' { $inventory.files[0].bytes = 0 }
            'fractional_bytes' { $inventory.files[0].bytes = 1.5 }
            'bad_hash' { $inventory.files[0].sha256 = 'bad' }
            'installer_hash' { $inventory.installer_sha256 = '0' * 64 }
            'source_commit' { $inventory.source_commit = '0' * 40 }
            'debug' { $inventory.build_profile = 'debug' }
            'unknown_key' { $inventory | Add-Member -NotePropertyName foreign -NotePropertyValue $true }
            'unsorted' { [array]::Reverse($inventory.files) }
        }
        { Confirm-Inventory $inventory } | Should -Throw
    }

    It 'rejects duplicate JSON keys before lossy deserialization' {
        $path = Join-Path $TestDrive 'duplicate.json'
        [IO.File]::WriteAllText($path, '{"schema":"a","schema":"b"}')
        { Read-DesktopStrictJson $path } | Should -Throw '*duplicate_key*'
    }

    It 'checks every installed byte and rejects missing, changed and foreign generation files' -ForEach @(
        @{ fault = 'none' }, @{ fault = 'missing_cli' }, @{ fault = 'missing_mcp' }, @{ fault = 'missing_license' }, @{ fault = 'altered_license' }, @{ fault = 'mixed_router' }, @{ fault = 'foreign_file' }, @{ fault = 'foreign_empty_directory' }
    ) {
        $inventory = New-InventoryFixture
        $root = Join-Path $TestDrive $fault
        New-InstalledFixture $inventory $root
        switch ($fault) {
            'missing_cli' { Remove-Item -LiteralPath (Join-Path $root 'winsmux.exe') }
            'missing_mcp' { Remove-Item -LiteralPath (Join-Path $root 'winsmux-workspace-mcp.exe') }
            'missing_license' { Remove-Item -LiteralPath (Join-Path $root 'licenses/texts/sample.txt') }
            'altered_license' { [IO.File]::WriteAllText((Join-Path $root 'licenses/texts/sample.txt'), 'different') }
            'mixed_router' { New-Item -ItemType Directory -Path (Join-Path $root 'winsmux-core') | Out-Null }
            'foreign_file' { [IO.File]::WriteAllText((Join-Path $root 'foreign.exe'), 'foreign') }
            'foreign_empty_directory' { New-Item -ItemType Directory -Path (Join-Path $root 'foreign') | Out-Null }
        }
        if ($fault -ceq 'none') {
            $receipt = Get-DesktopInstalledInventory $root (Confirm-Inventory $inventory) ('c' * 64)
            $receipt.found | Should -Be 5; $receipt.licenses | Should -Be 3; $receipt.complete | Should -BeTrue
        } else { { Get-DesktopInstalledInventory $root (Confirm-Inventory $inventory) ('c' * 64) } | Should -Throw }
    }

    It 'preserves a foreign sentinel when a linked license directory is rejected' {
        $inventory = New-InventoryFixture; $root = Join-Path $TestDrive 'linked-root'
        New-InstalledFixture $inventory $root
        $foreign = Join-Path $TestDrive 'foreign-target'; New-Item -ItemType Directory -Path $foreign | Out-Null
        $sentinel = Join-Path $foreign 'sentinel'; [IO.File]::WriteAllText($sentinel, 'keep')
        $link = Join-Path $root 'licenses/foreign'
        New-Item -ItemType Junction -Path $link -Target $foreign | Out-Null
        try { { Get-DesktopInstalledInventory $root $inventory ('c' * 64) } | Should -Throw '*reparse*'; [IO.File]::ReadAllText($sentinel) | Should -Be 'keep' }
        finally { Remove-Item -LiteralPath $link -Force }
    }
}

Describe 'One Desktop receipt contract across every sibling entry' {
    It 'accepts a complete receipt and rejects an unconfirmed runtime or mixed binding' -ForEach @(
        @{ fault = 'none' }, @{ fault = 'workspace_read_verified' }, @{ fault = 'mcp_roundtrip_verified' }, @{ fault = 'mcp_eof_exit_verified' }, @{ fault = 'normal_close_requested' }, @{ fault = 'owned_processes_exited' }, @{ fault = 'inventory_sha256' }, @{ fault = 'installer_sha256' }, @{ fault = 'source_commit' }, @{ fault = 'license_count' }, @{ fault = 'force_flag' }, @{ fault = 'cleanup' }
    ) {
        $receipt = New-ReceiptFixture
        if ($fault -cin @('workspace_read_verified','mcp_roundtrip_verified','mcp_eof_exit_verified','normal_close_requested','owned_processes_exited')) { $receipt.desktop_runtime.$fault = $false }
        elseif ($fault -cin @('inventory_sha256','installer_sha256','source_commit')) { $receipt.installed_inventory.$fault = '0' * 64 }
        elseif ($fault -ceq 'license_count') { $receipt.installed_inventory.licenses = 2 }
        elseif ($fault -ceq 'force_flag') { $receipt.desktop_runtime | Add-Member -NotePropertyName forced -NotePropertyValue $true }
        elseif ($fault -ceq 'cleanup') { $receipt.cleanup = 'preserve' }
        $action = { Assert-DesktopInstallReceipt $receipt '0.38.0' ('f' * 64) ('a' * 40) ('c' * 64) }
        if ($fault -ceq 'none') { (& $action) | Should -BeTrue } else { $action | Should -Throw }
    }

    It 'makes all real installer producers and consumers use the shared inventory contract' {
        foreach ($file in @('.github/workflows/test.yml','.github/workflows/desktop-candidate-cdp-gate.yml','.github/workflows/release-desktop.yml')) {
            $source = Get-Content -LiteralPath (Join-Path $script:RepoRoot $file) -Raw
            $source | Should -Match 'New-DesktopInstallInventory'
        }
        foreach ($file in @('.github/workflows/test.yml','.github/workflows/desktop-candidate-cdp-gate.yml','.github/workflows/public-smoke-recovery.yml')) {
            (Get-Content -LiteralPath (Join-Path $script:RepoRoot $file) -Raw) | Should -Match 'Assert-DesktopInstallReceipt'
        }
        $helper = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts/test-public-release.ps1') -Raw
        $helper | Should -Match 'Get-DesktopInstalledInventory'
        $helper | Should -Match 'desktop_candidate_inventory_missing'
        $helper | Should -Match 'Get-ChecksumEntry -ManifestText \$manifest -AssetName \$inventoryAsset'
        $helper | Should -Match 'winsmux-desktop-smoke-failure/v1'
        $helper | Should -Not -Match 'Stop-OwnedProcessTree -RootProcess \$Context.app_process'
    }
}

Describe 'Normal Desktop close and MCP correlation' {
    BeforeEach {
        $script:DesktopObservationTimeoutMilliseconds = 1
        $script:DesktopObservationPollMilliseconds = 1
        $script:DesktopRuntimeReceipt = @{ normal_close_requested = $false; owned_processes_exited = $false }
        function Get-DesktopProcessSnapshot { return [pscustomobject]@{ kind = 'processes'; items = @() } }
        $script:CloseCalls = 0
    }
    It 'requests normal close exactly once and confirms the owned exit' {
        $process = [pscustomobject]@{ Id = 1; HasExited = $false; ExitCode = 0 }
        $process | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $script:CloseCalls++; $this.HasExited = $true; return $true }
        $process | Add-Member -MemberType ScriptMethod -Name RequireNormalCompletion -Value { param($timeout,$poll) if (-not $this.HasExited -or $this.ExitCode -ne 0) { throw 'fake_normal_incomplete' } }
        Stop-DesktopNormally ([pscustomobject]@{ process = $process; owner = $process })
        $script:CloseCalls | Should -Be 1; $script:DesktopRuntimeReceipt.normal_close_requested | Should -BeTrue; $script:DesktopRuntimeReceipt.owned_processes_exited | Should -BeTrue
    }
    It 'rejects refusal, unknown nonterminal state, nonzero exit and an already killed app' -ForEach @(@{ fault='refused' },@{ fault='unknown' },@{ fault='nonzero' },@{ fault='already_exited' }) {
        $process = [pscustomobject]@{ Id = 1; HasExited = ($fault -ceq 'already_exited'); ExitCode = $(if ($fault -ceq 'nonzero') { 1 } else { 0 }); fault = $fault }
        $process | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $script:CloseCalls++; if ($this.fault -ceq 'refused') { return $false }; if ($this.fault -ceq 'nonzero') { $this.HasExited = $true }; return $true }
        $process | Add-Member -MemberType ScriptMethod -Name RequireNormalCompletion -Value { param($timeout,$poll) if (-not $this.HasExited -or $this.ExitCode -ne 0) { throw 'fake_normal_incomplete' } }
        { Stop-DesktopNormally ([pscustomobject]@{ process = $process; owner = $process }) } | Should -Throw
        $script:CloseCalls | Should -BeLessOrEqual 1; $script:DesktopRuntimeReceipt.owned_processes_exited | Should -BeFalse
    }
    It 'rejects wrong MCP request identity, protocol error and missing result' -ForEach @(@{ fault='none' },@{ fault='id' },@{ fault='error' },@{ fault='missing_result' },@{ fault='version' }) {
        $response = @{ jsonrpc='2.0'; id='expected'; result=@{} }
        switch ($fault) { 'id' { $response.id='foreign' }; 'error' { $response.error=@{code=-32603} }; 'missing_result' { $response.Remove('result') }; 'version' { $response.jsonrpc='1.0' } }
        $response = $response | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        if ($fault -ceq 'none') { { Assert-DesktopMcpResponse $response 'expected' } | Should -Not -Throw }
        else { { Assert-DesktopMcpResponse $response 'expected' } | Should -Throw }
    }
}

# Frozen termination decision table (shared GUI/MCP/synchronous/observer owner):
# root HANDLE exit + same Job ActiveProcesses=0 + both completed EOF drains;
# normal additionally requires one accepted close, root exit0, and Forced=false.
# Root/ancestor exit alone, Job0 without EOF, refusal, timeout, failed observation,
# repeated close, startup failure and forced teardown can never earn normal success.
Describe 'Native Desktop owner class proof' {
    BeforeAll {
        $script:DesktopObservationTimeoutMilliseconds = 180000
        $script:DesktopObservationPollMilliseconds = 10
        $script:DesktopOutputRetainLimitBytes = 16384
        Initialize-DesktopNativeTypes
        $script:NativeProofRoot = Join-Path $script:RepoRoot ('.evidence/desktop-owner-native-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:NativeProofRoot -Force | Out-Null
        $script:NativeFixture = Join-Path $script:NativeProofRoot 'fixture.ps1'
        $script:NativeExecutable = (Get-Process -Id $PID).Path
        $fixture = @'
param([string]$Mode,[string]$Root,[int]$Count=0,[int]$Code=0,[string]$CloseMode='accept',[Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$ErrorActionPreference='Stop'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false,$true)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false,$true)
function Spawn($ChildMode) {
 $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=(Get-Process -Id $PID).Path;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
 foreach($arg in @('-NoProfile','-File',$PSCommandPath,'-Mode',$ChildMode,'-Root',$Root)){$info.ArgumentList.Add($arg)}
  if($null -eq ('NativeFixtureChild' -as [type])) {
  Add-Type @"
using System;using System.Text;using System.Runtime.InteropServices;
public static class NativeFixtureChild {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Startup {public uint Size;public string Reserved,Desktop,Title;public uint X,Y,W,H,XC,YC,Fill,Flags;public ushort Show,ReservedSize;public IntPtr ReservedBytes,Input,Output,Error;}
 [StructLayout(LayoutKind.Sequential)] struct Info {public IntPtr Process,Thread;public uint Pid,Tid;}
 [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int id);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string application,StringBuilder command,IntPtr ps,IntPtr ts,bool inherit,uint flags,IntPtr environment,string directory,ref Startup startup,out Info info);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h,uint timeout);
 public static IntPtr Spawn(string executable,string fixture,string mode,string root) {
  var startup=new Startup{Size=(uint)Marshal.SizeOf(typeof(Startup)),Flags=0x100,Input=GetStdHandle(-10),Output=GetStdHandle(-11),Error=GetStdHandle(-12)};Info info;
  string command="\""+executable+"\" -NoProfile -File \""+fixture+"\" -Mode \""+mode+"\" -Root \""+root+"\"";
  if(!CreateProcessW(executable,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,true,0x08000400,IntPtr.Zero,null,ref startup,out info))throw new Exception("proof_child_create_failed");CloseHandle(info.Thread);return info.Process;
 }
 public static void WaitAndClose(IntPtr process){if(WaitForSingleObject(process,180000)!=0)throw new Exception("proof_child_wait_failed");CloseHandle(process);}
 public static void Close(IntPtr process){CloseHandle(process);}
}
"@
 }
 return [NativeFixtureChild]::Spawn($info.FileName,$PSCommandPath,$ChildMode,$Root)
}
function WaitMarker($Name) { while(-not [IO.File]::Exists((Join-Path $Root $Name))){Start-Sleep -Milliseconds 10} }
switch($Mode){
 'sentinel' { [IO.File]::WriteAllText((Join-Path $Root 'sentinel-ready'),'unchanged');WaitMarker 'sentinel-release';exit 0 }
 'root' { $child=Spawn 'middle';[NativeFixtureChild]::WaitAndClose($child);[IO.File]::WriteAllText((Join-Path $Root 'root-exited'),'yes');exit 0 }
 'middle' { $child=Spawn 'grandchild';WaitMarker 'grandchild-ready';[NativeFixtureChild]::Close($child);exit 0 }
 'grandchild' { [Console]::Write('grandchild-out');[Console]::Error.Write('grandchild-error');[IO.File]::WriteAllText((Join-Path $Root 'grandchild-ready'),'yes');WaitMarker 'grandchild-release';exit 0 }
 'marker' { [IO.File]::WriteAllText((Join-Path $Root 'user-code-started'),'yes');exit 0 }
 'output' { [Console]::Write(('x'*$Count));[Console]::Error.Write(('y'*$Count));exit $Code }
 'args' { [Console]::WriteLine((@{argv=[Environment]::GetCommandLineArgs();cwd=[Environment]::CurrentDirectory;inherited=$env:WINSMUX_OWNER_PARENT_PROOF;overlay=$env:WINSMUX_OWNER_PROOF} | ConvertTo-Json -Compress));exit 0 }
 'interactive_hang' { [IO.File]::WriteAllText((Join-Path $Root 'interactive-ready'),'yes');WaitMarker 'interactive-release';exit 0 }
 'interactive' { while($null -ne ($line=[Console]::ReadLine())) { $request=$line|ConvertFrom-Json; if($request.method -eq 'notifications/initialized'){continue}; if($CloseMode -eq 'invalid_utf8'){$stream=[Console]::OpenStandardOutput();$bytes=[byte[]]@(255,10);$stream.Write($bytes,0,2);$stream.Flush()}else{ $responseId=if($CloseMode -eq 'wrong_id'){'foreign'}else{$request.id};[Console]::WriteLine((@{jsonrpc='2.0';id=$responseId;result=@{method=$request.method}}|ConvertTo-Json -Compress)) } }; if($CloseMode -eq 'tail'){[Console]::Write('unrequested')};if($CloseMode -eq 'stderr'){[Console]::Error.Write('diagnostic')};[IO.File]::WriteAllText((Join-Path $Root 'stdin-eof'),'yes');exit 0 }
 'window' {
  Add-Type @"
using System;using System.IO;using System.Runtime.InteropServices;
public static class ProofWindow {
 delegate IntPtr Callback(IntPtr h,uint message,IntPtr w,IntPtr l);
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Class {public uint Style;public IntPtr Proc;public int Extra,WindowExtra;public IntPtr Instance,Icon,Cursor,Background;public string Menu,Name;}
 [StructLayout(LayoutKind.Sequential)] struct Message {public IntPtr H;public uint Value;public IntPtr W,L;public uint Time;public int X,Y;public uint Private;}
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern ushort RegisterClassW(ref Class c);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex,string c,string title,uint style,int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr parameter);
 [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
 [DllImport("user32.dll")] static extern void PostQuitMessage(int code);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr DefWindowProcW(IntPtr h,uint message,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] static extern int GetMessageW(out Message message,IntPtr h,uint min,uint max);
 [DllImport("user32.dll")] static extern bool TranslateMessage(ref Message message);
 [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref Message message);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string module);
 public static void Run(string root,bool refuse) {
  Callback callback=(h,message,w,l)=>{if(message==0x10){File.AppendAllText(Path.Combine(root,"close-calls"),"1");if(!refuse)DestroyWindow(h);return IntPtr.Zero;}if(message==2){PostQuitMessage(0);return IntPtr.Zero;}return DefWindowProcW(h,message,w,l);};
  string name="WinsmuxProof"+Guid.NewGuid().ToString("N");var c=new Class{Name=name,Instance=GetModuleHandleW(null),Proc=Marshal.GetFunctionPointerForDelegate(callback)};
  if(RegisterClassW(ref c)==0)throw new Exception("proof_class_failed");
  IntPtr window=CreateWindowExW(0x08000080,name,"owned proof",0x10CF0000,-32000,-32000,100,100,IntPtr.Zero,IntPtr.Zero,c.Instance,IntPtr.Zero);
  if(window==IntPtr.Zero)throw new Exception("proof_window_failed");
  File.WriteAllText(Path.Combine(root,"window-ready"),"yes");Message m;int result;
  while((result=GetMessageW(out m,IntPtr.Zero,0,0))>0){TranslateMessage(ref m);DispatchMessageW(ref m);}GC.KeepAlive(callback);if(result<0)throw new Exception("proof_message_failed");
 }
}
"@
  [ProofWindow]::Run($Root,($CloseMode -eq 'refuse'));exit $Code
 }
 default {throw 'fixture_mode_invalid'}
}
'@
        [IO.File]::WriteAllText($script:NativeFixture,$fixture,[Text.UTF8Encoding]::new($false))
        function New-NativeFixtureOwner {
            param([string]$Mode,[string]$Name,[string[]]$Extra=@(),[switch]$Interactive,[string]$Fault='')
            $root=Join-Path $script:NativeProofRoot $Name
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $arguments=[string[]](@('-NoProfile','-STA','-File',$script:NativeFixture,'-Mode',$Mode,'-Root',$root)+$Extra)
            $owner=if($Fault) {[Winsmux.DesktopNative.DesktopProcessOwner]::StartForProof($script:NativeExecutable,$arguments,@{},[bool]$Interactive,16384,180000,$Fault)} else {[Winsmux.DesktopNative.DesktopProcessOwner]::Start($script:NativeExecutable,$arguments,@{},[bool]$Interactive,16384,180000)}
            return [pscustomobject]@{owner=$owner;process=$owner;root=$root}
        }
        function Wait-NativeMarker($Root,$Name,$Owner=$null) {
            $timer=[Diagnostics.Stopwatch]::StartNew()
            while(-not (Test-Path -LiteralPath (Join-Path $Root $Name))) {
                if($null -ne $Owner -and $Owner.HasExited){throw 'native_fixture_exited_before_marker'}
                if($timer.ElapsedMilliseconds -ge 180000){throw 'native_fixture_marker_timeout'}
                Start-Sleep -Milliseconds 10
            }
        }
        function Clear-NativeOwner($Owned) {
            if($null -eq $Owned){return}
            if(-not $Owned.owner.WaitTerminal(0,10)){$Owned.owner.ForceFailureCleanup(180000,10)}
            $Owned.owner.Dispose()
        }
        $script:SentinelRoot=Join-Path $script:NativeProofRoot 'sentinel'
        New-Item -ItemType Directory -Path $script:SentinelRoot | Out-Null
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$script:NativeExecutable;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        foreach($arg in @('-NoProfile','-File',$script:NativeFixture,'-Mode','sentinel','-Root',$script:SentinelRoot)){$info.ArgumentList.Add($arg)}
        $script:Sentinel=[Diagnostics.Process]::Start($info)
        Wait-NativeMarker $script:SentinelRoot 'sentinel-ready'
    }
    AfterEach {
        $script:Sentinel.Refresh();$script:Sentinel.HasExited | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $script:SentinelRoot 'sentinel-ready')) | Should -BeExactly 'unchanged'
    }
    AfterAll {
        [IO.File]::WriteAllText((Join-Path $script:SentinelRoot 'sentinel-release'),'yes')
        $script:Sentinel.WaitForExit(180000) | Should -BeTrue
        $script:Sentinel.ExitCode | Should -Be 0
        $script:Sentinel.Dispose()
    }
    It 'proves immediate root membership and startup failure has zero user code and retained-handle recovery' -ForEach @(@{fault='assignment'},@{fault='membership'},@{fault='resume'}) {
        $failure=$null
        try { New-NativeFixtureOwner 'marker' ('start-'+$fault) -Fault $fault | Out-Null } catch { $failure=$_.Exception.GetBaseException() }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Data['desktop_owner_created'] | Should -Be ($fault -ne 'assignment')
        $failure.Data['desktop_owner_resumed'] | Should -Be 0
        $failure.Data['desktop_owner_recovered'] | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:NativeProofRoot ('start-'+$fault+'/user-code-started')) | Should -BeFalse
    }
    It 'rejects root and intermediate exits while the real pipe-holding grandchild is alive, then confirms only Job0 and EOF' -ForEach @(@{ending='normal'},@{ending='failure'}) {
        $owned=New-NativeFixtureOwner 'root' ('descendant-'+$ending)
        try {
            $owned.owner.ResumeCount | Should -Be 1
            $owned.owner.WaitForExit(180000) | Should -BeTrue
            $owned.owner.ExitCode | Should -Be 0
            $owned.owner.ActiveMembers | Should -BeGreaterThan 0
            $owned.owner.StdoutTask.IsCompleted | Should -BeFalse
            $owned.owner.StderrTask.IsCompleted | Should -BeFalse
            $owned.owner.WaitTerminal(1,1) | Should -BeFalse
            { Stop-DesktopNormally $owned } | Should -Throw '*already_exited*'
            if($ending -eq 'normal'){[IO.File]::WriteAllText((Join-Path $owned.root 'grandchild-release'),'yes')}else{$owned.owner.ForceFailureCleanup(180000,10)}
            $owned.owner.WaitTerminal(180000,10) | Should -BeTrue
            $owned.owner.ActiveMembers | Should -Be 0
            $owned.owner.Forced | Should -Be ($ending -eq 'failure')
            $capture=Get-OwnedProcessCapture $owned
            $capture.stdout | Should -BeExactly 'grandchild-out';$capture.stderr | Should -BeExactly 'grandchild-error'
            { $owned.owner.RequireNormalCompletion(1,1) } | Should -Throw
        } finally { Clear-NativeOwner $owned }
    }
    It 'does not treat native Job0 as terminal capture before observed pipe EOF' {
        $owned=New-NativeFixtureOwner 'output' 'job-zero-before-eof' -Fault 'eof'
        try {
            $owned.owner.WaitForExit(180000) | Should -BeTrue;$owned.owner.ActiveMembers | Should -Be 0
            $owned.owner.StdoutTask.IsCompleted | Should -BeFalse
            $owned.owner.WaitTerminal(1,1) | Should -BeFalse
            {$owned.owner.Dispose()} | Should -Throw '*release_capture_unconfirmed*'
            $script:DesktopObservationTimeoutMilliseconds=1
            {Get-OwnedProcessCapture $owned} | Should -Throw '*capture_incomplete*'
            $owned.owner.ReleaseProofOutputHold()
            $owned.owner.WaitTerminal(180000,10) | Should -BeTrue
        } finally {$script:DesktopObservationTimeoutMilliseconds=180000;Clear-NativeOwner $owned}
    }
    It 'requires one real normal close, root zero, Job0, EOF and no force across the close decision table' -ForEach @(
        @{condition='normal';code='0';close='accept'},@{condition='nonzero';code='7';close='accept'},@{condition='refusal';code='0';close='refuse'},@{condition='forced';code='0';close='accept'},@{condition='reentrant';code='0';close='refuse'}
    ) {
        $owned=New-NativeFixtureOwner 'window' ('close-'+$condition) -Extra @('-Code',$code,'-CloseMode',$close)
        try {
            Wait-NativeMarker $owned.root 'window-ready' $owned.owner
            $owned.owner.ActiveMembers | Should -BeGreaterThan 0
            $script:DesktopRuntimeReceipt=@{normal_close_requested=$false;owned_processes_exited=$false}
            if($condition -eq 'forced') {
                $owned.owner.ForceFailureCleanup(180000,10)
                {Stop-DesktopNormally $owned} | Should -Throw
                { $owned.owner.RequireNormalCompletion(1,1) } | Should -Throw
            }elseif($condition -eq 'reentrant'){
                $owned.owner.CloseMainWindow() | Should -BeTrue
                Wait-NativeMarker $owned.root 'close-calls'
                {$owned.owner.CloseMainWindow()} | Should -Throw '*reentrant*'
                {$owned.owner.RequireNormalCompletion(1,1)} | Should -Throw '*incomplete*'
            }elseif($condition -eq 'refusal'){
                $script:DesktopObservationTimeoutMilliseconds=1
                {Stop-DesktopNormally $owned} | Should -Throw '*incomplete*'
                Wait-NativeMarker $owned.root 'close-calls'
            }elseif($condition -eq 'nonzero'){
                {Stop-DesktopNormally $owned} | Should -Throw '*nonzero*'
            }else{
                Stop-DesktopNormally $owned
                $owned.owner.Forced | Should -BeFalse;$owned.owner.ActiveMembers | Should -Be 0
                $script:DesktopRuntimeReceipt.owned_processes_exited | Should -BeTrue
            }
            if($condition -ne 'forced'){[IO.File]::ReadAllText((Join-Path $owned.root 'close-calls')) | Should -BeExactly '1'}
            if($condition -ne 'normal'){$script:DesktopRuntimeReceipt.owned_processes_exited | Should -BeFalse}
        }finally{$script:DesktopObservationTimeoutMilliseconds=180000;Clear-NativeOwner $owned}
    }
    It 'rejects missing owner and released native observation without searching a stale PID' {
        {Stop-DesktopNormally @{process=@{Id=$script:Sentinel.Id}}} | Should -Throw '*owner_missing*'
        $owned=New-NativeFixtureOwner 'output' 'released-observation'
        $owned.owner.WaitTerminal(180000,10) | Should -BeTrue;$owned.owner.Dispose()
        {$owned.owner.get_ActiveMembers()} | Should -Throw '*released*'
        {Stop-DesktopNormally $owned} | Should -Throw '*released*'
    }
    It 'preserves bounded zero, exact-limit and over-limit output' -ForEach @(@{bytes=0},@{bytes=16384},@{bytes=16385}) {
        $owned=New-NativeFixtureOwner 'output' ('output-'+$bytes) -Extra @('-Count',[string]$bytes)
        try {
            $owned.owner.WaitTerminal(180000,10) | Should -BeTrue
            $capture=Get-OwnedProcessCapture $owned
            foreach($stream in @('stdout','stderr')) {
                $metadata=$capture.($stream+'_metadata');$metadata.bytes | Should -Be $bytes
                $metadata.retained_bytes | Should -Be ([Math]::Min(16384,$bytes));$metadata.truncated | Should -Be ($bytes -gt 16384)
            }
        }finally{Clear-NativeOwner $owned}
    }
    It 'preserves native argv, inherited environment plus overlay, and inherited working directory' {
        $values=[string[]]@('', 'quoted"value', 'trailing\', 'space slash\', '日本語🦊')
        $arguments=[string[]](@('-NoProfile','-File',$script:NativeFixture,'-Mode','args','-Root',$script:NativeProofRoot,'-Count','0','-Code','0','-CloseMode','accept')+$values)
        $previousParent=[Environment]::GetEnvironmentVariable('WINSMUX_OWNER_PARENT_PROOF')
        [Environment]::SetEnvironmentVariable('WINSMUX_OWNER_PARENT_PROOF','親環境の継承')
        $owner=[Winsmux.DesktopNative.DesktopProcessOwner]::Start($script:NativeExecutable,$arguments,@{WINSMUX_OWNER_PROOF='上書き'},$false,16384,180000)
        try {
            $owner.WaitTerminal(180000,10) | Should -BeTrue
            $owner.ExitCode | Should -Be 0
            $response=[Text.Encoding]::UTF8.GetString($owner.StdoutTask.Result.RetainedBytes)|ConvertFrom-Json
            $response.argv[-5..-1] | Should -Be $values
            $response.cwd | Should -Be ([Environment]::CurrentDirectory)
            $response.inherited | Should -BeExactly '親環境の継承';$response.overlay | Should -BeExactly '上書き'
        }finally{$owner.Dispose();[Environment]::SetEnvironmentVariable('WINSMUX_OWNER_PARENT_PROOF',$previousParent)}
    }
    It 'correlates interactive UTF8 requests, closes stdin EOF and requires native root0, Job0, empty tail and stderr' {
        $owned=New-NativeFixtureOwner 'interactive' 'interactive-eof' -Interactive
        try {
            foreach($method in @('initialize','notifications/initialized','tools/list')) {
                $id=[Guid]::NewGuid().ToString('D')
                $owned.owner.StandardInput.WriteLine((@{jsonrpc='2.0';id=$id;method=$method;unicode='日本語🦊'}|ConvertTo-Json -Compress))
                $owned.owner.StandardInput.Flush()
                if($method -eq 'notifications/initialized'){continue}
                $task=$owned.owner.ReadLineAsync(2097152)
                $task.Wait(180000) | Should -BeTrue
                $line=$task.GetAwaiter().GetResult()
                $line | Should -Not -BeNullOrEmpty
                $response=$line|ConvertFrom-Json
                Assert-DesktopMcpResponse $response $id
                $response.result.method | Should -BeExactly $method
            }
            $owned.owner.FinishInputAndDrain()
            $owned.owner.WaitTerminal(180000,10) | Should -BeTrue
            $owned.owner.ExitCode | Should -Be 0;$owned.owner.ActiveMembers | Should -Be 0;$owned.owner.Forced | Should -BeFalse
            $owned.owner.StdoutTask.Result.TotalBytes | Should -Be 0;$owned.owner.StderrTask.Result.TotalBytes | Should -Be 0
            Test-Path -LiteralPath (Join-Path $owned.root 'stdin-eof') | Should -BeTrue
        }finally{Clear-NativeOwner $owned}
    }
    It 'rejects synchronous sibling root exit with a surviving child and performs owned Job failure recovery' {
        $root=Join-Path $script:NativeProofRoot 'sync-child-timeout';New-Item -ItemType Directory -Path $root | Out-Null
        $failure=$null
        try{Invoke-DesktopOwnedNativeProcess -FilePath $script:NativeExecutable -ArgumentList @('-NoProfile','-File',$script:NativeFixture,'-Mode','root','-Root',$root) -Environment @{} -TimeoutSeconds 5 | Out-Null}catch{$failure=$_.Exception.GetBaseException()}
        $failure | Should -Not -BeNullOrEmpty
        $failure.Message | Should -BeExactly 'desktop_owned_child_timeout'
        $failure.Data['process_result'].exit_code | Should -Be 0
        $failure.Data['process_result'].stdout | Should -BeExactly 'grandchild-out'
        $failure.Data['process_result'].stderr | Should -BeExactly 'grandchild-error'
    }
    It 'rejects uncorrelated MCP replies, invalid UTF8, oversized messages, unexpected tail and stderr with bounded owned recovery' -ForEach @(
        @{fault='wrong_id'},@{fault='invalid_utf8'},@{fault='oversized'},@{fault='tail'},@{fault='stderr'}
    ) {
        $owned=New-NativeFixtureOwner 'interactive' ('interactive-'+$fault) -Interactive -Extra @('-CloseMode',$fault)
        try {
            $owned.owner.StandardInput.WriteLine('{"jsonrpc":"2.0","id":"expected","method":"initialize"}')
            $owned.owner.StandardInput.Flush()
            $limit=if($fault -eq 'oversized'){4}else{2097152}
            $task=$owned.owner.ReadLineAsync($limit)
            if($fault -in @('invalid_utf8','oversized')) {
                { $task.Wait(180000) } | Should -Throw
                { $owned.owner.ForceFailureCleanup(180000,10) } | Should -Throw
                $owned.owner.ActiveMembers | Should -Be 0
                $owned.owner.HasExited | Should -BeTrue
                $owned.owner.Forced | Should -BeTrue
                {$owned.owner.RequireNormalCompletion(1,1)} | Should -Throw
            }else {
                $task.Wait(180000) | Should -BeTrue
                $response=$task.GetAwaiter().GetResult()|ConvertFrom-Json
                if($fault -eq 'wrong_id') {
                    {Assert-DesktopMcpResponse $response 'expected'} | Should -Throw
                    $owned.owner.ForceFailureCleanup(180000,10)
                    $owned.owner.Forced | Should -BeTrue
                }else {
                    Assert-DesktopMcpResponse $response 'expected'
                    $owned.owner.FinishInputAndDrain()
                    $owned.owner.WaitTerminal(180000,10) | Should -BeTrue
                    {Assert-Condition ($owned.owner.StdoutTask.Result.TotalBytes -eq 0 -and $owned.owner.StderrTask.Result.TotalBytes -eq 0) 'desktop_mcp_terminal_output_invalid'} | Should -Throw '*terminal_output_invalid*'
                }
            }
        }finally {
            # Faulted protocol readers are terminal failures, not successful EOF captures.
            if(-not $owned.owner.HasExited -or $owned.owner.ActiveMembers -ne 0){try{$owned.owner.ForceFailureCleanup(180000,10)}catch{}}
            $owned.owner.Dispose()
        }
    }
    It 'recovers a pending MCP read after timeout without concurrent tail reads or indefinite GetResult' {
        $owned=New-NativeFixtureOwner 'interactive_hang' 'interactive-pending-timeout' -Interactive
        try {
            Wait-NativeMarker $owned.root 'interactive-ready' $owned.owner
            $task=$owned.owner.ReadLineAsync(2097152)
            $task.Wait(1) | Should -BeFalse
            $owned.owner.ForceFailureCleanup(180000,10)
            $owned.owner.WaitTerminal(0,1) | Should -BeTrue
            $task.IsCompleted | Should -BeTrue
            $owned.owner.ActiveMembers | Should -Be 0
            $owned.owner.Forced | Should -BeTrue
            {$owned.owner.RequireNormalCompletion(1,1)} | Should -Throw
        }finally{Clear-NativeOwner $owned}
    }
    It 'preserves the installed boundary and forbids uninstall after real normal-close failure while recovering the whole owned Job' -ForEach @(
        @{fault='ancestor_exit'},@{fault='close_nonzero'},@{fault='close_refusal'}
    ) {
        $owned=if($fault -eq 'ancestor_exit'){New-NativeFixtureOwner 'root' 'preserve-ancestor'}else{New-NativeFixtureOwner 'window' ('preserve-'+$fault) -Extra @('-Code',$(if($fault -eq 'close_nonzero'){'7'}else{'0'}),'-CloseMode',$(if($fault -eq 'close_refusal'){'refuse'}else{'accept'}))}
        $context=[pscustomobject]@{phase='materialized_verified';app_process=$owned;owned_root=$owned.root;block_error=''}
        $counts=[pscustomobject]@{uninstall=0;residue=0;remove=0}
        $uninstall={param($context,$env) $counts.uninstall++}.GetNewClosure()
        $residue={param($context) $counts.residue++}.GetNewClosure()
        $remove={param($root) $counts.remove++}.GetNewClosure()
        $stop=if($fault -eq 'close_refusal'){{param($owned) if(-not $owned.owner.CloseMainWindow()){throw 'desktop_normal_close_refused'};$owned.owner.RequireNormalCompletion(1,1)}}else{$null}
        $installedBoundary=Join-Path $owned.root 'preserved-installed-marker'
        [IO.File]::WriteAllText($installedBoundary,'preserve exact bytes')
        try {
            if($fault -eq 'ancestor_exit'){$owned.owner.WaitForExit(180000) | Should -BeTrue}else{Wait-NativeMarker $owned.root 'window-ready' $owned.owner}
            {Invoke-DesktopCleanup -Context $context -Environment @{} -StopInvoker $stop -UninstallInvoker $uninstall -ResidueInvoker $residue -RootRemover $remove} | Should -Throw
            $context.phase | Should -BeExactly 'preserve'
            $counts.uninstall | Should -Be 0;$counts.residue | Should -Be 0;$counts.remove | Should -Be 0
            [IO.File]::ReadAllText($installedBoundary) | Should -BeExactly 'preserve exact bytes'
            $owned.owner.Forced | Should -BeTrue
            $owned.owner.WaitTerminal(180000,10) | Should -BeTrue
            $owned.owner.ActiveMembers | Should -Be 0
            {$owned.owner.RequireNormalCompletion(1,1)} | Should -Throw
        }finally{Clear-NativeOwner $owned}
    }
}

Describe 'Mounted workspace observation through the real JavaScript expression' {
    It 'checks main mount, session, generation and correlated reads including a fresh empty workspace' {
        $function = $script:HelperAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-DesktopWorkspaceRuntime' }, $true)[0]
        $match = [regex]::Match($function.Extent.Text, "(?s)\`$expression = @'\r?\n(?<js>.*?)\r?\n'@")
        $match.Success | Should -BeTrue
        $expressionPath = Join-Path $TestDrive 'expression.js'
        [IO.File]::WriteAllText($expressionPath, $match.Groups['js'].Value, [Text.UTF8Encoding]::new($false))
        $harnessPath = Join-Path $TestDrive 'workspace-runtime.mjs'
        $harness = @'
import fs from 'node:fs';import vm from 'node:vm';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';
const expression=fs.readFileSync(process.argv[2],'utf8');
const instance='10000000-0000-4000-8000-000000000001',generation='20000000-0000-4000-8000-000000000002';
const faults=['none','selected','secondary','unmounted','unavailable','instance_mismatch','generation_mismatch','generation_changed','wrong_operation_id','wrong_response_instance','wrong_response_operation','wrong_revision','response_rejected','discovery_foreign','foreign_url','frame','query','no_invoke'];
for(const fault of faults){
 const selected=fault==='selected'?'30000000-0000-4000-8000-000000000003':null;
 const view={isConnected:true,dataset:{availability:fault==='unavailable'?'unknown':'available',instanceId:fault==='instance_mismatch'?randomUUID():instance,generation:fault==='generation_mismatch'?randomUUID():generation,topologyRevision:'0',selectedProjectId:selected??''}};
 const root={isConnected:true,dataset:{startupState:fault==='unmounted'?'connecting':'mounted',session:JSON.stringify({instance_id:instance,schema_version:1}),generation},querySelector:()=>view};
 const location={href:fault==='foreign_url'?'https://example.invalid/':'tauri://localhost/',search:fault==='query'?'?foreign=true':''};
 async function invoke(command,args){if(command==='workspace_discovery_get')return {instance_id:fault==='discovery_foreign'?randomUUID():instance,pipe_name:'private-fixture',schema_version:1};
 const request=JSON.parse(args.requestJson);if(fault==='generation_changed')root.dataset.generation=randomUUID();
 const data=request.operation==='capabilities.get'?{max_message_bytes:1024,operations:['project.list'],providers:[],replay_capacity:1,schema_version:1,shell_profile_ids:[]}:{projects:selected?[{project_id:selected,display_name:null,path:null,root_state:'unknown'}]:[],selected_project_id:selected};
 return {schema_version:1,instance_id:fault==='wrong_response_instance'?randomUUID():instance,operation_id:fault==='wrong_operation_id'?randomUUID():request.operation_id,accepted:fault!=='response_rejected',topology_revision:fault==='wrong_revision'?1:0,event_seq:0,result:{operation:fault==='wrong_response_operation'?'wrong':request.operation,data},error:null};}
 const window={__TAURI__:fault==='no_invoke'?null:{core:{invoke}},__TAURI_INTERNALS__:{metadata:{currentWindow:{label:fault==='secondary'?'secondary':'main'}}}};window.top=fault==='frame'?{}:window;
 const result=JSON.parse(await vm.runInNewContext(expression,{window,document:{getElementById:()=>root},location,crypto:{randomUUID}}));
 assert.equal(result.ok,['none','selected'].includes(fault),fault);
 if(result.ok){assert.equal(result.instance_id,instance);assert.equal(result.generation,generation);assert.equal(result.discovery.instance_id,instance);}
}
console.log(JSON.stringify({cases:faults.length,positive:2,negative:faults.length-2,all_passed:true}));
'@
        [IO.File]::WriteAllText($harnessPath, $harness, [Text.UTF8Encoding]::new($false))
        $output = & node $harnessPath $expressionPath
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json
        $result.cases | Should -Be 18; $result.positive | Should -Be 2; $result.negative | Should -Be 16; $result.all_passed | Should -BeTrue
    }
}
