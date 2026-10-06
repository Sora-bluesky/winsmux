BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'scripts/desktop-install-inventory.ps1')
    $tokens = $null; $errors = $null
    $script:HelperAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'scripts/test-public-release.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Helper parse failed.' }
    $script:DesktopOwnerSourceRoot = Join-Path $script:RepoRoot 'scripts'
    foreach ($name in @('Assert-Condition', 'Get-ObjectPropertyValue', 'Test-DesktopProcessDescendant', 'Stop-DesktopNormally', 'Assert-DesktopMcpResponse', 'Initialize-DesktopNativeTypes', 'Start-OwnedProcess', 'Get-OwnedProcessCapture', 'Stop-OwnedProcessTree', 'Invoke-DesktopOwnedNativeProcess', 'Wait-DesktopOwnedNativeProcess', 'Invoke-DesktopNsisProcess', 'Get-CanonicalPath', 'Test-CanonicalPathEqual', 'Assert-DesktopInstallRootOwnership', 'Format-PublicChildProcessDiagnostic', 'Invoke-NativeProcess', 'Invoke-PublicChildProcess', 'Get-DesktopFailureEvidence', 'Get-DesktopOwnedProcessObservation', 'New-DesktopFailureReceipt', 'Assert-DesktopLifecyclePhase', 'Set-DesktopLifecyclePhase', 'Set-DesktopLifecyclePreserve', 'Invoke-DesktopCleanup')) {
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

Describe 'Desktop workspace mount diagnostic contract' {
    BeforeAll {
        $script:MountStages = @('invoke_unavailable','window_binding_invalid','location_invalid','startup_root_missing','project_view_missing','startup_not_mounted','project_view_unavailable','session_json_invalid','session_binding_invalid','topology_revision_invalid','runtime_changed','capabilities_read_failed','projects_read_failed','capabilities_invalid','projects_invalid','discovery_read_failed','discovery_invalid','unclassified')
        $getFunction = $script:HelperAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-DesktopWorkspaceRuntime' }, $true)[0]
        $waitFunction = $script:HelperAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Wait-DesktopWorkspaceRuntime' }, $true)[0]
        . ([scriptblock]::Create($getFunction.Extent.Text))
        . ([scriptblock]::Create($waitFunction.Extent.Text))
        # Execute the actual result boundary without opening a page websocket.
        $boundary = $getFunction.Body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] -and $_.Extent.Text.StartsWith('try { Assert-Condition ((Get-ObjectPropertyValue $result') }
        if (@($boundary).Count -ne 1) { throw 'Mount result boundary missing.' }
        . ([scriptblock]::Create('function Test-MountResultBoundary { param($result) ' + $boundary.Extent.Text + '; return $result }'))
        function New-MountStageFixture([string]$Kind) {
            switch -CaseSensitive ($Kind) {
                'missing' { return @{} }
                'null' { return @{ stage = $null } }
                'number' { return @{ stage = 42 } }
                'array' { return @{ stage = @('projects_invalid') } }
                'object' { return @{ stage = @{ private = 'synthetic_private_value' } } }
                'case' { return @{ stage = 'PROJECTS_INVALID' } }
                'unknown' { return @{ stage = 'synthetic_private_value' } }
                'newline' { return @{ stage = "projects_invalid`nsynthetic_private_value" } }
                'prefix' { return @{ stage = 'projects_invalid synthetic_private_value' } }
                'empty' { return @{ stage = '' } }
                default { return @{ stage = $Kind } }
            }
        }
        function New-MountFailure($StageFixture) {
            $failure = [InvalidOperationException]::new('desktop_workspace_read_unconfirmed')
            if ($StageFixture.ContainsKey('stage')) { $failure.Data['winsmux_workspace_mount_stage'] = $StageFixture.stage }
            return $failure
        }
        if ($null -eq ('MountDiagnosticThrowingWriter' -as [type])) {
            Add-Type @'
using System;using System.IO;using System.Text;
public sealed class MountDiagnosticThrowingWriter : TextWriter {
 public override Encoding Encoding { get { return Encoding.UTF8; } }
 public override void WriteLine(string value) { throw new IOException("synthetic_private_writer_failure"); }
}
'@
        }
    }
    It 'preserves the old JavaScript result exception boundaries and IPC order across 94 cases' {
        # Keep this hash-bound baseline and paired worker in the existing test surface.
        $workerSource = @'
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

const root = process.argv[2];
const baseline = {
  "source_commit": "fb70779034b8b83014ff34fbbaf7d02b7ba9d820",
  "source_blob_sha256": "1001f70de5e033c787d269e5ad112cf4d403970b1d7e9dd6ed7862ea958c9a35",
  "expression_sha256": "9bf25c4b92029394880308d0f99a55ad36050dfbe776f28182483968f68f5284",
  "expression": "(async () => {\n const closed=(v,k)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).length===k.length&&k.every(x=>Object.hasOwn(v,x));\n const uuid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);\n const uint=v=>Number.isSafeInteger(v)&&v>=0;\n const invoke=window.__TAURI__?.core?.invoke, label=window.__TAURI_INTERNALS__?.metadata?.currentWindow?.label;\n const root=document.getElementById('workspace-startup'), view=root?.querySelector('.workspace-project-pane');\n const fail=()=>JSON.stringify({ok:false});\n if(!invoke||label!=='main'||window.top!==window||location.search||!/^https?:\\/\\/tauri\\.localhost\\/?$|^tauri:\\/\\/localhost\\/?$/.test(location.href)||!root||!view||root.dataset.startupState!=='mounted'||view.dataset.availability!=='available')return fail();\n let session;try{session=JSON.parse(root.dataset.session);}catch{return fail();}\n if(!closed(session,['instance_id','schema_version'])||!uuid(session.instance_id)||session.schema_version!==1||session.instance_id!==view.dataset.instanceId||!uuid(root.dataset.generation)||root.dataset.generation!==view.dataset.generation)return fail();\n const identity=JSON.stringify([root.dataset.session,root.dataset.generation,view.dataset.topologyRevision,view.dataset.selectedProjectId]);\n const stable=()=>root.isConnected&&view.isConnected&&root.dataset.startupState==='mounted'&&view.dataset.availability==='available'&&identity===JSON.stringify([root.dataset.session,root.dataset.generation,view.dataset.topologyRevision,view.dataset.selectedProjectId]);\n const revision=Number(view.dataset.topologyRevision);if(!uint(revision))return fail();\n async function read(operation){const request={schema_version:1,instance_id:session.instance_id,operation_id:crypto.randomUUID(),expected_topology_revision:null,operation,params:{}};\n  if(!stable())throw 0;const response=await invoke('workspace_request',{requestJson:JSON.stringify(request)});\n  if(!stable()||!closed(response,['schema_version','instance_id','operation_id','accepted','topology_revision','event_seq','result','error'])||response.schema_version!==1||response.instance_id!==session.instance_id||response.operation_id!==request.operation_id||response.accepted!==true||response.error!==null||!uint(response.event_seq)||response.topology_revision!==revision||!closed(response.result,['operation','data'])||response.result.operation!==operation)throw 0;return response.result.data;\n }\n try{const caps=await read('capabilities.get'), projects=await read('project.list');\n  if(!closed(caps,['max_message_bytes','operations','providers','replay_capacity','schema_version','shell_profile_ids'])||caps.schema_version!==1||!Array.isArray(caps.operations)||!caps.operations.includes('project.list')||!closed(projects,['projects','selected_project_id'])||!Array.isArray(projects.projects)||(projects.selected_project_id!==null&&!uuid(projects.selected_project_id))||(projects.selected_project_id??'')!==view.dataset.selectedProjectId||!projects.projects.every(p=>closed(p,['project_id','display_name','path','root_state'])&&uuid(p.project_id)&&(p.display_name===null||typeof p.display_name==='string')&&(p.path===null||typeof p.path==='string')&&['verified','unavailable','changed','unknown'].includes(p.root_state)))return fail();\n  const discovery=await invoke('workspace_discovery_get');\n  if(!stable()||!closed(discovery,['instance_id','pipe_name','schema_version'])||discovery.instance_id!==session.instance_id||discovery.schema_version!==1||typeof discovery.pipe_name!=='string'||!discovery.pipe_name)return fail();\n  return JSON.stringify({ok:true,instance_id:session.instance_id,generation:root.dataset.generation,revision,discovery});\n }catch{return fail();}\n})()"
};
assert.equal(baseline.source_commit, 'fb70779034b8b83014ff34fbbaf7d02b7ba9d820');
assert.equal(createHash('sha256').update(baseline.expression).digest('hex'), '9bf25c4b92029394880308d0f99a55ad36050dfbe776f28182483968f68f5284');
const source = fs.readFileSync(path.join(root, 'scripts/test-public-release.ps1'), 'utf8');
const body = source.split('function Get-DesktopWorkspaceRuntime {')[1].split(/\r?\nfunction /)[0];
const current = body.match(/\$expression = @'\r?\n([\s\S]*?)\r?\n'@/)[1].replaceAll('\r\n', '\n');
const allowed = new Set(['invoke_unavailable','window_binding_invalid','location_invalid','startup_root_missing','project_view_missing','startup_not_mounted','project_view_unavailable','session_json_invalid','session_binding_invalid','topology_revision_invalid','runtime_changed','capabilities_read_failed','projects_read_failed','capabilities_invalid','projects_invalid','discovery_read_failed','discovery_invalid','unclassified']);
const instance = '11111111-1111-4111-8111-111111111111';
const generation = '22222222-2222-4222-8222-222222222222';
const project = '33333333-3333-4333-8333-333333333333';
const sentinel = 'SYNTHETIC_PRIVATE_SENTINEL\n';
function fixture(change) {
  const calls = [];
  const state = {
    calls, instance, generation, rootPresent: true, viewPresent: true,
    root: {isConnected: true, dataset: {startupState: 'mounted', session: JSON.stringify({instance_id: instance, schema_version: 1}), generation}},
    view: {isConnected: true, dataset: {availability: 'available', instanceId: instance, generation, topologyRevision: '0', selectedProjectId: ''}},
    caps: {max_message_bytes: 65536, operations: ['project.list'], providers: null, replay_capacity: {}, schema_version: 1, shell_profile_ids: null},
    projects: {projects: [], selected_project_id: null},
    discovery: {instance_id: instance, pipe_name: 'synthetic-public-pipe', schema_version: 1},
    location: {href: 'http://tauri.localhost/', search: ''},
    before() {}, after() {}, cryptoHook() {},
  };
  const invoke = async (command, args) => {
    const request = args ? JSON.parse(args.requestJson) : null;
    const operation = request?.operation ?? command;
    calls.push(operation); state.before(operation);
    let value;
    if (request) value = {schema_version: 1, instance_id: instance, operation_id: request.operation_id, accepted: true, topology_revision: 0, event_seq: 0, result: {operation, data: operation === 'capabilities.get' ? state.caps : state.projects}, error: null};
    else value = state.discovery;
    state.after(operation, value); return value;
  };
  state.window = {__TAURI__: {core: {invoke}}, __TAURI_INTERNALS__: {metadata: {currentWindow: {label: 'main'}}}};
  state.window.top = state.window;
  state.root.querySelector = () => state.viewPresent ? state.view : null;
  state.document = {getElementById: () => state.rootPresent ? state.root : null};
  state.crypto = {randomUUID() {state.cryptoHook(); return '44444444-4444-4444-8444-444444444444';}};
  change(state); return state;
}
async function evaluate(expression, change) {
  const state = fixture(change);
  try {
    const value = JSON.parse(await vm.runInNewContext(expression, {window:state.window, document:state.document, location:state.location, crypto:state.crypto}));
    return {value, calls:state.calls, thrown:null};
  } catch (error) {return {value:null, calls:state.calls, thrown:String(error)};}
}
const cases = [];
function test(name, stage, change) {cases.push({name, stage, change});}
test('empty workspace succeeds', null, () => {});
test('registered project succeeds', null, s => {s.view.dataset.selectedProjectId = project; s.projects = {selected_project_id:project, projects:[{project_id:project, display_name:null, path:null, root_state:'verified'}]};});
test('tauri scheme succeeds', null, s => {s.location.href='tauri://localhost/';});
test('invoke absent', 'invoke_unavailable', s => {s.window.__TAURI__ = null;});
test('wrong window', 'window_binding_invalid', s => {s.window.__TAURI_INTERNALS__.metadata.currentWindow.label=sentinel;});
test('nested window', 'window_binding_invalid', s => {s.window.top={};});
test('query present', 'location_invalid', s => {s.location.search=sentinel;});
test('wrong location', 'location_invalid', s => {s.location.href=sentinel;});
test('root absent', 'startup_root_missing', s => {s.rootPresent=false;});
test('view absent', 'project_view_missing', s => {s.viewPresent=false;});
test('startup unmounted', 'startup_not_mounted', s => {s.root.dataset.startupState=sentinel;});
test('view unavailable', 'project_view_unavailable', s => {s.view.dataset.availability=sentinel;});
test('session malformed', 'session_json_invalid', s => {s.root.dataset.session=sentinel;});
for (const [name, value] of [['null',null],['array',[]],['extra',{instance_id:instance,schema_version:1,extra:sentinel}],['invalid instance',{instance_id:sentinel,schema_version:1}],['version',{instance_id:instance,schema_version:2}]]) test('session '+name,'session_binding_invalid',s=>{s.root.dataset.session=JSON.stringify(value);});
test('session view mismatch','session_binding_invalid',s=>{s.view.dataset.instanceId=project;});
test('generation invalid','session_binding_invalid',s=>{s.root.dataset.generation=sentinel;});
test('generation mismatch','session_binding_invalid',s=>{s.view.dataset.generation=project;});
for(const value of ['-1','0.5','NaN','9007199254740992']) test('invalid revision '+value,'topology_revision_invalid',s=>{s.view.dataset.topologyRevision=value;});
for (const operation of ['capabilities.get','project.list']) {
  const stage = operation === 'capabilities.get' ? 'capabilities_read_failed' : 'projects_read_failed';
  test(operation+' rejects',stage,s=>{s.before=op=>{if(op===operation)throw new Error(sentinel);};});
  for (const [name, mutate] of [
    ['extra',v=>{v.extra=sentinel;}], ['version',v=>{v.schema_version=2;}], ['instance',v=>{v.instance_id=project;}],
    ['operation id',v=>{v.operation_id=project;}], ['rejected',v=>{v.accepted=false;}], ['error',v=>{v.error={message:sentinel};}],
    ['event',v=>{v.event_seq=-1;}], ['revision',v=>{v.topology_revision=1;}], ['result null',v=>{v.result=null;}],
    ['result extra',v=>{v.result.extra=sentinel;}], ['operation mismatch',v=>{v.result.operation=sentinel;}],
  ]) test(operation+' '+name,stage,s=>{s.after=(op,v)=>{if(op===operation)mutate(v);};});
}
for (const [name, mutate] of [
  ['extra',s=>{s.caps.extra=sentinel;}],['version',s=>{s.caps.schema_version=2;}],['operations type',s=>{s.caps.operations=sentinel;}],['project operation absent',s=>{s.caps.operations=[];}]
]) test('capabilities '+name,'capabilities_invalid',mutate);
for(const [name, mutate] of [
  ['extra',s=>{s.projects.extra=sentinel;}],['projects type',s=>{s.projects.projects=sentinel;}],['selected invalid',s=>{s.projects.selected_project_id=sentinel;}],['selected mismatch',s=>{s.projects.selected_project_id=project;}]
]) test('projects '+name,'projects_invalid',mutate);
for(const [key,value] of [['project_id',sentinel],['display_name',1],['path',1],['root_state',sentinel],['extra',sentinel]]) test('project field '+key,'projects_invalid',s=>{s.projects.projects=[{project_id:project,display_name:null,path:null,root_state:'verified',[key]:value}];});
test('discovery rejects','discovery_read_failed',s=>{s.before=op=>{if(op==='workspace_discovery_get')throw new Error(sentinel);};});
for(const [key,value] of [['instance_id',project],['schema_version',2],['pipe_name',''],['pipe_name',1],['extra',sentinel]]) test('discovery field '+key+String(value).slice(0,1),'discovery_invalid',s=>{s.discovery[key]=value;});
for (const target of ['root connection','view connection','session','generation','revision','selection']) {
  const mutate=s=>{if(target==='root connection')s.root.isConnected=false; if(target==='view connection')s.view.isConnected=false; if(target==='session')s.root.dataset.session=sentinel; if(target==='generation')s.root.dataset.generation=project; if(target==='revision')s.view.dataset.topologyRevision='1'; if(target==='selection')s.view.dataset.selectedProjectId=project;};
  for(const operation of ['capabilities.get','project.list','workspace_discovery_get']) test(target+' after '+operation,'runtime_changed',s=>{s.after=op=>{if(op===operation)mutate(s);};});
  test(target+' before first read','runtime_changed',s=>{s.cryptoHook=()=>mutate(s);});
}
test('preexisting outer getter exception stays exceptional', 'thrown', s=>{Object.defineProperty(s.view.dataset,'topologyRevision',{get(){throw new Error(sentinel);}});});
test('preexisting caught project getter stays refused','projects_invalid',s=>{Object.defineProperty(s.projects,'projects',{get(){throw new Error(sentinel);},enumerable:true});});
const seen=new Set();
for (const item of cases) {
  const old = await evaluate(baseline.expression,item.change), now = await evaluate(current,item.change);
  assert.deepEqual(now.calls,old.calls,item.name+' changed IPC call order');
  assert.equal(now.thrown,old.thrown,item.name+' changed exception boundary');
  if(now.thrown){assert.equal(item.stage,'thrown');continue;}
  const {stage,...projection}=now.value;
  assert.deepEqual(projection,old.value,item.name+' changed the protected result');
  if(item.stage===null){assert.equal(stage,undefined);assert.equal(now.value.ok,true);}
  else {assert.equal(now.value.ok,false);assert.equal(stage,item.stage,item.name);assert(allowed.has(stage));assert.deepEqual(Object.keys(now.value).sort(),['ok','stage']);assert(!JSON.stringify(now.value).includes('SYNTHETIC_PRIVATE_SENTINEL'));seen.add(stage);}
}
for(const stage of allowed) if(stage!=='unclassified') assert(seen.has(stage),'unproved stage '+stage);
console.log(JSON.stringify({baseline_sha256:baseline.expression_sha256,cases:cases.length,protected_results_and_call_order_equal:true,exception_boundaries_equal:true,fixed_stage_count:seen.size,raw_values_absent:true}));
'@
        $workerPath = Join-Path $TestDrive 'desktop-workspace-probe-equivalence.mjs'
        [IO.File]::WriteAllText($workerPath, $workerSource, [Text.UTF8Encoding]::new($false))
        $output = & node $workerPath $script:RepoRoot
        $LASTEXITCODE | Should -Be 0
        @($output).Count | Should -Be 1
        $proof = $output | ConvertFrom-Json
        $proof.cases | Should -Be 94
        $proof.protected_results_and_call_order_equal | Should -BeTrue
        $proof.exception_boundaries_equal | Should -BeTrue
        $proof.fixed_stage_count | Should -Be 17
        $proof.raw_values_absent | Should -BeTrue
    }
    It 'keeps the producer and consumer stage sets identical to the frozen finite contract' {
        foreach ($name in @('Get-DesktopWorkspaceRuntime','Wait-DesktopWorkspaceRuntime')) {
            $definition = $script:HelperAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)[0]
            $assignment = $definition.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$allowed' }, $true)
            @($assignment).Count | Should -Be 1
            $actual = & ([scriptblock]::Create($assignment.Right.Extent.Text))
            @($actual) | Should -Be $script:MountStages
        }
    }
    It 'keeps a successful result unchanged without attaching a failure stage' {
        $result = [pscustomobject]@{ ok = $true; stage = 'synthetic_private_value'; instance_id = 'synthetic' }
        [object]::ReferenceEquals((Test-MountResultBoundary $result), $result) | Should -BeTrue
    }
    It 'attaches only a fixed stage while preserving the original read failure for <kind>' -ForEach @(
        foreach ($stage in @('invoke_unavailable','window_binding_invalid','location_invalid','startup_root_missing','project_view_missing','startup_not_mounted','project_view_unavailable','session_json_invalid','session_binding_invalid','topology_revision_invalid','runtime_changed','capabilities_read_failed','projects_read_failed','capabilities_invalid','projects_invalid','discovery_read_failed','discovery_invalid','unclassified')) { @{ kind = $stage; expected = $stage } }
        foreach ($kind in @('missing','null','number','array','object','case','unknown','newline','prefix','empty')) { @{ kind = $kind; expected = 'unclassified' } }
    ) {
        $fixture = New-MountStageFixture $kind
        $fixture.ok = $false
        $fixture = $fixture | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $failure = $null
        try { Test-MountResultBoundary $fixture } catch { $failure = $_.Exception }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Message | Should -BeExactly 'desktop_workspace_read_unconfirmed'
        $failure.Data['winsmux_workspace_mount_stage'] | Should -BeExactly $expected
    }
    It 'preserves the read failure when diagnostic attachment itself fails' {
        $fixture = [pscustomobject]@{ ok = $false }
        $fixture | Add-Member -MemberType ScriptProperty -Name stage -Value { throw 'synthetic_private_attachment_failure' }
        { Test-MountResultBoundary $fixture } | Should -Throw -ExpectedMessage 'desktop_workspace_read_unconfirmed'
    }
    It 'emits exactly one fixed stage on terminal mount failure for <kind>' -ForEach @(
        foreach ($stage in @('invoke_unavailable','window_binding_invalid','location_invalid','startup_root_missing','project_view_missing','startup_not_mounted','project_view_unavailable','session_json_invalid','session_binding_invalid','topology_revision_invalid','runtime_changed','capabilities_read_failed','projects_read_failed','capabilities_invalid','projects_invalid','discovery_read_failed','discovery_invalid','unclassified')) { @{ kind = $stage; expected = $stage } }
        foreach ($kind in @('missing','null','number','array','object','case','unknown','newline','prefix','empty')) { @{ kind = $kind; expected = 'unclassified' } }
    ) {
        $script:MountFailure = New-MountFailure (New-MountStageFixture $kind)
        Mock Get-DesktopWorkspaceRuntime { throw $script:MountFailure }
        Mock Start-Sleep { }
        $script:DesktopObservationTimeoutMilliseconds = 0
        $script:DesktopObservationPollMilliseconds = 0
        $writer = [IO.StringWriter]::new(); $previous = [Console]::Error
        try {
            [Console]::SetError($writer)
            { Wait-DesktopWorkspaceRuntime -Context @{ app_process = @{ process = @{ HasExited = $false } } } -Port 1 -UserDataFolder 'synthetic' } | Should -Throw -ExpectedMessage 'desktop_workspace_mount_unconfirmed'
        } finally { [Console]::SetError($previous) }
        $writer.ToString() | Should -BeExactly ('desktop_workspace_mount_probe stage=' + $expected + [Environment]::NewLine)
        $writer.Dispose()
        Should -Invoke Get-DesktopWorkspaceRuntime -Exactly -Times 1
    }
    It 'emits no mount diagnostic when a retry succeeds and returns the exact result' {
        $script:MountFailure = New-MountFailure @{ stage = 'startup_not_mounted' }
        $script:MountCalls = 0; $script:MountResult = [pscustomobject]@{ ok = $true; revision = 7 }
        Mock Get-DesktopWorkspaceRuntime { $script:MountCalls++; if ($script:MountCalls -eq 1) { throw $script:MountFailure }; return $script:MountResult }
        Mock Start-Sleep { }
        $script:DesktopObservationTimeoutMilliseconds = 180000; $script:DesktopObservationPollMilliseconds = 0
        $writer = [IO.StringWriter]::new(); $previous = [Console]::Error
        try { [Console]::SetError($writer); $actual = Wait-DesktopWorkspaceRuntime -Context @{ app_process = @{ process = @{ HasExited = $false } } } -Port 1 -UserDataFolder 'synthetic' }
        finally { [Console]::SetError($previous) }
        [object]::ReferenceEquals($actual, $script:MountResult) | Should -BeTrue
        $writer.ToString() | Should -BeExactly ''; $writer.Dispose()
        Should -Invoke Get-DesktopWorkspaceRuntime -Exactly -Times 2
    }
    It 'does not reuse a previous call stage when the next call has no stage' {
        $script:MountFailure = New-MountFailure @{ stage = 'projects_invalid' }
        Mock Get-DesktopWorkspaceRuntime { throw $script:MountFailure }; Mock Start-Sleep { }
        $script:DesktopObservationTimeoutMilliseconds = 0; $script:DesktopObservationPollMilliseconds = 0
        $writer = [IO.StringWriter]::new(); $previous = [Console]::Error
        try {
            [Console]::SetError($writer)
            $context = @{ app_process = @{ process = @{ HasExited = $false } } }
            { Wait-DesktopWorkspaceRuntime $context 1 'synthetic' } | Should -Throw -ExpectedMessage 'desktop_workspace_mount_unconfirmed'
            $script:MountFailure = New-MountFailure @{}
            { Wait-DesktopWorkspaceRuntime $context 1 'synthetic' } | Should -Throw -ExpectedMessage 'desktop_workspace_mount_unconfirmed'
        } finally { [Console]::SetError($previous) }
        $writer.ToString() | Should -BeExactly ('desktop_workspace_mount_probe stage=projects_invalid' + [Environment]::NewLine + 'desktop_workspace_mount_probe stage=unclassified' + [Environment]::NewLine)
        $writer.Dispose()
    }
    It 'keeps an unrelated exception unchanged and emits no mount diagnostic' {
        $script:MountFailure = [InvalidOperationException]::new('desktop_cdp_authority_unconfirmed')
        Mock Get-DesktopWorkspaceRuntime { throw $script:MountFailure }
        $writer = [IO.StringWriter]::new(); $previous = [Console]::Error; $failure = $null
        try { [Console]::SetError($writer); try { Wait-DesktopWorkspaceRuntime @{ app_process = @{ process = @{ HasExited = $false } } } 1 'synthetic' } catch { $failure = $_.Exception } }
        finally { [Console]::SetError($previous) }
        [object]::ReferenceEquals($failure, $script:MountFailure) | Should -BeTrue
        $failure.Message | Should -BeExactly 'desktop_cdp_authority_unconfirmed'
        $writer.ToString() | Should -BeExactly ''; $writer.Dispose()
    }
    It 'preserves the terminal reason when the diagnostic writer throws' {
        $script:MountFailure = New-MountFailure @{ stage = 'projects_invalid' }
        Mock Get-DesktopWorkspaceRuntime { throw $script:MountFailure }; Mock Start-Sleep { }
        $script:DesktopObservationTimeoutMilliseconds = 0; $script:DesktopObservationPollMilliseconds = 0
        $writer = [MountDiagnosticThrowingWriter]::new(); $previous = [Console]::Error
        try {
            [Console]::SetError($writer)
            { Wait-DesktopWorkspaceRuntime @{ app_process = @{ process = @{ HasExited = $false } } } 1 'synthetic' } | Should -Throw -ExpectedMessage 'desktop_workspace_mount_unconfirmed'
        } finally { [Console]::SetError($previous); $writer.Dispose() }
    }
}

Describe 'Desktop runtime expression transport contract' {
    BeforeAll {
        $definition = @($script:HelperAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-DesktopRuntimeExpression' }, $true))
        if ($definition.Count -ne 1) { throw 'Exact runtime expression helper required.' }
        . ([scriptblock]::Create($definition[0].Extent.Text))
        $script:DesktopObservationTimeoutMilliseconds = 180000
        # An actual websocket peer exercises the production PowerShell/.NET await
        # boundary. No substitute transport or transformed function is used.
        $workerSource = @'
import http from 'node:http';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const peers=new Set(),seen=[];
let upgraded=0,closed=0;
const server=http.createServer((req,res)=>{res.writeHead(404);res.end();});
function frame(bytes,opcode=1,fin=true){
 let header;
 if(bytes.length<126)header=Buffer.from([(fin?128:0)|opcode,bytes.length]);
 else if(bytes.length<65536){header=Buffer.alloc(4);header[0]=(fin?128:0)|opcode;header[1]=126;header.writeUInt16BE(bytes.length,2);}
 else{header=Buffer.alloc(10);header[0]=(fin?128:0)|opcode;header[1]=127;header.writeBigUInt64BE(BigInt(bytes.length),2);}
 return Buffer.concat([header,bytes]);
}
const value={ok:true,instance_id:'11111111-1111-4111-8111-111111111111',revision:0};
const response=v=>({id:1,result:{result:{type:'string',value:JSON.stringify(v)}}});
server.on('upgrade',(req,socket,head)=>{
 assert.equal(req.url,'/devtools/page/synthetic');assert.equal(head.length,0);
 const accept=createHash('sha1').update(req.headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
 socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n');
 upgraded++;peers.add(socket);let input=Buffer.alloc(0),sent=false;
 socket.on('data',part=>{
  if(sent){if((part[0]&15)===8)socket.end(frame(Buffer.alloc(0),8));return;}
  input=Buffer.concat([input,part]);if(input.length<2)return;
  assert.equal(input[0],0x81);assert.equal(input[1]&128,128);
  let length=input[1]&127,offset=2;
  if(length===126){if(input.length<4)return;length=input.readUInt16BE(2);offset=4;}
  assert(length<65536&&length!==127);if(input.length<offset+4+length)return;
  const mask=input.subarray(offset,offset+4),body=Buffer.from(input.subarray(offset+4,offset+4+length));
  for(let i=0;i<body.length;i++)body[i]^=mask[i%4];
  const request=JSON.parse(body.toString('utf8'));
  assert.deepEqual(Object.keys(request).sort(),['id','method','params']);
  assert.equal(request.id,1);assert.equal(request.method,'Runtime.evaluate');
  assert.deepEqual(Object.keys(request.params).sort(),['awaitPromise','expression','returnByValue']);
  assert.equal(request.params.returnByValue,true);assert.equal(request.params.awaitPromise,true);
  const mode=request.params.expression;
  const modes=['success','refusal','fragmented','unrelated','boundary','error','exception','nonstring','malformed','duplicate','utf8','oversized','binary','close','cancel'];
  assert(modes.includes(mode));assert(!seen.includes(mode));seen.push(mode);sent=true;
  let reply=response(mode==='refusal'?{ok:false,stage:'projects_invalid'}:value);
  if(mode==='error')reply.error={code:-1,message:'synthetic'};
  if(mode==='exception')reply.result.exceptionDetails={text:'synthetic'};
  if(mode==='nonstring')reply.result.result={type:'number',value:7};
  let bytes=Buffer.from(JSON.stringify(reply));
  if(mode==='malformed')bytes=Buffer.from('{');
  if(mode==='duplicate')bytes=Buffer.from('{"id":1,"id":1}');
  if(mode==='utf8')bytes=Buffer.from([0xff]);
  if(mode==='boundary'||mode==='oversized'){
   const target=mode==='boundary'?65536:65537;
   reply.padding='';const base=Buffer.byteLength(JSON.stringify(reply));
   reply.padding='x'.repeat(target-base);bytes=Buffer.from(JSON.stringify(reply));assert.equal(bytes.length,target);
  }
  if(mode==='cancel')return;
  if(mode==='close'){socket.end(frame(Buffer.alloc(0),8));return;}
  if(mode==='unrelated')socket.write(frame(Buffer.from(JSON.stringify({id:2,result:{result:{type:'string',value:'{}'}}}))));
  if(mode==='fragmented'){socket.write(frame(bytes.subarray(0,7),1,false));socket.write(frame(bytes.subarray(7),0,true));}
  else socket.write(frame(bytes,mode==='binary'?2:1));
 });
 socket.on('error',error=>{assert(sent&&error.code==='ECONNRESET');});
 socket.on('end',()=>socket.end());
 socket.on('close',()=>{peers.delete(socket);closed++;});
});
process.stdin.resume();process.stdin.on('end',()=>server.close(()=>{
 assert.equal(peers.size,0);assert.equal(closed,upgraded);
 for(const mode of ['success','refusal','fragmented','unrelated','boundary','error','exception','nonstring','malformed','duplicate','utf8','oversized','binary','close'])assert(seen.includes(mode));
 process.stdout.write(JSON.stringify({requests:seen,upgraded,closed,active_peers:peers.size})+'\n');
}));
server.listen(0,'127.0.0.1',()=>process.stdout.write(JSON.stringify({port:server.address().port,loopback_only:true})+'\n'));
'@
        $workerPath = Join-Path $TestDrive 'desktop-runtime-expression-wire.mjs'
        [IO.File]::WriteAllText($workerPath, $workerSource, [Text.UTF8Encoding]::new($false))
        $start = [Diagnostics.ProcessStartInfo]::new('node')
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $start.ArgumentList.Add($workerPath)
        $script:RuntimeWireProcess = [Diagnostics.Process]::new(); $script:RuntimeWireProcess.StartInfo = $start
        $started = $false
        try {
            if (-not $script:RuntimeWireProcess.Start()) { throw 'Runtime peer failed to start.' }
            $started = $true
            $script:RuntimeWireError = $script:RuntimeWireProcess.StandardError.ReadToEndAsync()
            $readyTask = $script:RuntimeWireProcess.StandardOutput.ReadLineAsync()
            if (-not $readyTask.Wait($script:DesktopObservationTimeoutMilliseconds)) { throw 'Runtime peer readiness missing.' }
            $ready = $readyTask.GetAwaiter().GetResult() | ConvertFrom-Json
            if ($ready.loopback_only -ne $true -or $ready.port -le 0) { throw 'Runtime peer binding invalid.' }
            $script:RuntimeWireUrl = 'ws://127.0.0.1:' + $ready.port + '/devtools/page/synthetic'
        } catch {
            if ($started -and -not $script:RuntimeWireProcess.HasExited) { $script:RuntimeWireProcess.Kill(); $script:RuntimeWireProcess.WaitForExit() }
            $script:RuntimeWireProcess.Dispose(); $script:RuntimeWireProcess = $null; throw
        }
    }
    AfterAll {
        if ($script:RuntimeWireProcess) {
            try {
                $script:RuntimeWireProcess.StandardInput.Close()
                if (-not $script:RuntimeWireProcess.WaitForExit($script:DesktopObservationTimeoutMilliseconds)) { throw 'Runtime peer normal exit missing.' }
                $remaining = $script:RuntimeWireProcess.StandardOutput.ReadToEnd()
                $stderr = $script:RuntimeWireError.GetAwaiter().GetResult()
                $script:RuntimeWireProcess.ExitCode | Should -Be 0
                $stderr | Should -BeExactly ''
                $receipt = $remaining | ConvertFrom-Json
                $receipt.active_peers | Should -Be 0
                $receipt.closed | Should -Be $receipt.upgraded
                @($receipt.requests | Where-Object { $_ -cne 'cancel' }).Count | Should -Be 14
            } finally {
                if (-not $script:RuntimeWireProcess.HasExited) { $script:RuntimeWireProcess.Kill(); $script:RuntimeWireProcess.WaitForExit() }
                $script:RuntimeWireProcess.Dispose()
            }
        }
    }
    It 'returns exactly the existing object without transport completion output for <mode>' -ForEach @(
        @{ mode = 'success' }, @{ mode = 'refusal' }, @{ mode = 'fragmented' }, @{ mode = 'unrelated' }, @{ mode = 'boundary' }
    ) {
        $actual = @(Invoke-DesktopRuntimeExpression -WebSocketUrl $script:RuntimeWireUrl -Expression $mode)
        $actual.Count | Should -Be 1
        $actual[0] | Should -BeOfType [pscustomobject]
        if ($mode -ceq 'refusal') {
            $actual[0].ok | Should -BeFalse
            $actual[0].stage | Should -BeExactly 'projects_invalid'
            @($actual[0].PSObject.Properties.Name | Sort-Object) | Should -Be @('ok','stage')
        } else {
            $actual[0].ok | Should -BeTrue
            $actual[0].instance_id | Should -BeExactly '11111111-1111-4111-8111-111111111111'
            $actual[0].revision | Should -Be 0
            @($actual[0].PSObject.Properties.Name | Sort-Object) | Should -Be @('instance_id','ok','revision')
        }
    }
    It 'preserves failure and emits no partial transport result for <mode>' -ForEach @(
        @{ mode = 'error'; reason = 'desktop_cdp_evaluation_failed'; type = 'System.Management.Automation.RuntimeException' },
        @{ mode = 'exception'; reason = 'desktop_cdp_evaluation_failed'; type = 'System.Management.Automation.RuntimeException' },
        @{ mode = 'nonstring'; reason = 'desktop_cdp_evaluation_invalid'; type = 'System.Management.Automation.RuntimeException' },
        @{ mode = 'duplicate'; reason = 'desktop_inventory_duplicate_key'; type = 'System.Management.Automation.RuntimeException' },
        @{ mode = 'oversized'; reason = 'desktop_cdp_response_oversized'; type = 'System.Management.Automation.RuntimeException' },
        @{ mode = 'binary'; reason = 'desktop_cdp_response_invalid'; type = 'System.Management.Automation.RuntimeException' },
        @{ mode = 'close'; reason = 'desktop_cdp_response_invalid'; type = 'System.Management.Automation.RuntimeException' },
        @{ mode = 'malformed'; reason = $null; type = 'System.Text.Json.JsonReaderException' },
        @{ mode = 'utf8'; reason = $null; type = 'System.Net.WebSockets.WebSocketException' }
    ) {
        $seen = [Collections.Generic.List[object]]::new(); $failure = $null
        try { Invoke-DesktopRuntimeExpression -WebSocketUrl $script:RuntimeWireUrl -Expression $mode | ForEach-Object { $seen.Add($_) } }
        catch { $failure = $_.Exception }
        $failure | Should -Not -BeNullOrEmpty
        $seen.Count | Should -Be 0
        $failure.GetBaseException().GetType().FullName | Should -BeExactly $type
        if ($reason) { $failure.Message | Should -BeExactly $reason }
    }
    It 'keeps cancellation exceptional without emitting completion output' {
        $seen = [Collections.Generic.List[object]]::new(); $failure = $null
        $previous = $script:DesktopObservationTimeoutMilliseconds
        try {
            $script:DesktopObservationTimeoutMilliseconds = 0
            try { Invoke-DesktopRuntimeExpression -WebSocketUrl $script:RuntimeWireUrl -Expression 'cancel' | ForEach-Object { $seen.Add($_) } }
            catch { $failure = $_.Exception }
        } finally { $script:DesktopObservationTimeoutMilliseconds = $previous }
        $failure | Should -Not -BeNullOrEmpty
        ($failure.GetBaseException() -is [OperationCanceledException] -or $failure.Message -ceq 'desktop_cdp_evaluation_timeout') | Should -BeTrue
        $seen.Count | Should -Be 0
    }
}

Describe 'NSIS final-tail command contract' {
    BeforeAll {
        Initialize-DesktopNativeTypes
        $flags = [Reflection.BindingFlags]'NonPublic,Static'
        $script:NsisBuilder = [Winsmux.DesktopNative.DesktopProcessOwner].GetMethod('BuildNsisCommand', $flags)
        $script:CrtQuote = [Winsmux.DesktopNative.DesktopProcessOwner].GetMethod('Quote', $flags)
        $script:NsisFixtureRoot = Join-Path $script:RepoRoot ('.evidence/nsis-arguments/native-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:NsisFixtureRoot -Force | Out-Null
        $sourcePath = Join-Path $script:NsisFixtureRoot 'wire.cs'
        $script:NsisWireExecutable = Join-Path $script:NsisFixtureRoot 'wire fixture.exe'
        [IO.File]::WriteAllText($sourcePath, @'
using System;
using System.Runtime.InteropServices;
using System.Text;
class WireFixture {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetCommandLineW();
    static void Main() { Console.Write(Convert.ToBase64String(Encoding.Unicode.GetBytes(Marshal.PtrToStringUni(GetCommandLineW())))); }
}
'@, [Text.UTF8Encoding]::new($false))
        $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
        $compileOutput = @(& $compiler /nologo /target:exe "/out:$script:NsisWireExecutable" $sourcePath 2>&1)
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $script:NsisWireExecutable -PathType Leaf)) { throw "Wire fixture compile failed: $($compileOutput -join ' ')" }
        function Read-Nsis311Command([string]$Command, [bool]$Uninstall) {
            # ExeHead/Main.c v3.11, lines 238-286 and 326-345: quote seek,
            # END_OF_ARG for /S, literal " /D=" and reverse literal " _?=".
            $silent = $false; $directory = $null; $index = 0; $seek = ' '
            if ($Command[0] -ceq '"') { $seek = '"'; $index++ }
            while ($index -lt $Command.Length -and $Command[$index] -cne $seek) { $index++ }
            $index++
            while ($index -lt $Command.Length) {
                while ($index -lt $Command.Length -and $Command[$index] -ceq ' ') { $index++ }
                if ($index -ge $Command.Length) { break }
                $seek = ' '
                if ($Command[$index] -ceq '"') { $index++; $seek = '"' }
                if ($index -lt $Command.Length -and $Command[$index] -ceq '/') {
                    $index++
                    if ($Command[$index] -ceq 'S' -and ($index + 1 -eq $Command.Length -or $Command[$index + 1] -ceq ' ')) { $silent = $true }
                    if ($index -ge 2 -and $index + 2 -lt $Command.Length -and $Command.Substring($index - 2, 4) -ceq ' /D=') {
                        $directory = $Command.Substring($index + 2); break
                    }
                }
                while ($index -lt $Command.Length -and $Command[$index] -cne $seek) { $index++ }
                if ($index -lt $Command.Length -and $Command[$index] -ceq '"') { $index++ }
            }
            if ($Uninstall) {
                $tail = $Command.LastIndexOf(' _?=', [StringComparison]::Ordinal)
                if ($tail -ge 0) { $directory = $Command.Substring($tail + 4) }
            }
            return [pscustomobject]@{ silent = $silent; directory = $directory }
        }
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:NsisFixtureRoot) {
            Remove-Item -LiteralPath (Join-Path $script:NsisFixtureRoot 'wire.cs')
            Remove-Item -LiteralPath $script:NsisWireExecutable
            Remove-Item -LiteralPath $script:NsisFixtureRoot
        }
    }

    It 'proves old CRT wire fails and dedicated NSIS wire preserves the exact final directory' -ForEach @(
        @{ uninstall = $false; suffix = 'plain' }, @{ uninstall = $true; suffix = 'plain' },
        @{ uninstall = $false; suffix = 'space directory' }, @{ uninstall = $true; suffix = 'space directory' },
        @{ uninstall = $false; suffix = '日本語 directory\' }, @{ uninstall = $true; suffix = '日本語 directory\' }
    ) {
        $exe = 'C:\fixture folder\setup.exe'
        $root = 'C:\owned\' + $suffix
        $switch = if ($uninstall) { '_?=' } else { '/D=' }
        $old = $script:CrtQuote.Invoke($null, @($exe)) + ' ' + $script:CrtQuote.Invoke($null, @('/S')) + ' ' + $script:CrtQuote.Invoke($null, @($switch + $root))
        $oldParsed = Read-Nsis311Command $old $uninstall
        $oldParsed.silent | Should -BeFalse
        $oldParsed.directory | Should -BeNullOrEmpty
        $wire = $script:NsisBuilder.Invoke($null, @($exe, $root, $uninstall))
        $wire | Should -BeExactly ('"' + $exe + '" /S ' + $switch + $root)
        $parsed = Read-Nsis311Command $wire $uninstall
        $parsed.silent | Should -BeTrue
        $parsed.directory | Should -BeExactly $root
    }

    It 'rejects unsafe or noncanonical directory tails before either native launch' -ForEach @(@(
        @{ root = 'relative\installed' }, @{ root = '\rooted\installed' }, @{ root = 'C:relative\installed' },
        @{ root = 'C:\owned\..\installed' }, @{ root = 'C:/owned/installed' },
        @{ root = 'C:\owned"\installed' }, @{ root = "C:\owned`0\installed" },
        @{ root = "C:\owned`n\installed" }, @{ root = "C:\owned`t\installed" },
        @{ root = ('C:\owned' + [char]0x85 + '\installed') }, @{ root = 'C:\owned _?=redirect\installed' }
    ) | ForEach-Object {
        # Keep XML report parameters printable while retaining every exact UTF-16 input.
        @{ root_base64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($_.root)) }
    }) {
        $root = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($root_base64))
        foreach ($mode in @($false, $true)) {
            { $script:NsisBuilder.Invoke($null, @('C:\missing-fixture.exe', $root, $mode)) } | Should -Throw '*desktop_owner_nsis_root_invalid*'
            if ($mode) { { [Winsmux.DesktopNative.DesktopProcessOwner]::StartNsisUninstaller('C:\missing-fixture.exe', $root, @{}, 16384, 180000) } | Should -Throw '*desktop_owner_nsis_root_invalid*' }
            else { { [Winsmux.DesktopNative.DesktopProcessOwner]::StartNsisInstaller('C:\missing-fixture.exe', $root, @{}, 16384, 180000) } | Should -Throw '*desktop_owner_nsis_root_invalid*' }
        }
    }

    It 'delivers the dedicated wire through the native owner with natural root exit, Job zero and drained streams' -ForEach @(
        @{ uninstall = $false }, @{ uninstall = $true }
    ) {
        $root = Join-Path $script:NsisFixtureRoot '日本語 space directory\'
        $owner = if ($uninstall) { [Winsmux.DesktopNative.DesktopProcessOwner]::StartNsisUninstaller($script:NsisWireExecutable, $root, @{}, 16384, 180000) }
            else { [Winsmux.DesktopNative.DesktopProcessOwner]::StartNsisInstaller($script:NsisWireExecutable, $root, @{}, 16384, 180000) }
        try {
            $owner.WaitTerminal(180000, 10) | Should -BeTrue
            $owner.ResumeCount | Should -Be 1; $owner.ExitCode | Should -Be 0; $owner.ActiveMembers | Should -Be 0
            $owner.Forced | Should -BeFalse; $owner.CaptureCompleted | Should -BeTrue
            $owner.StderrTask.Result.TotalBytes | Should -Be 0
            $encoded = [Text.Encoding]::UTF8.GetString($owner.StdoutTask.Result.RetainedBytes)
            $wire = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
            $wire | Should -BeExactly ($script:NsisBuilder.Invoke($null, @([string]$script:NsisWireExecutable, [string]$root, [bool]$uninstall)))
            $parsed = Read-Nsis311Command $wire $uninstall
            $parsed.silent | Should -BeTrue; $parsed.directory | Should -BeExactly $root
        } finally { $owner.Dispose() }
    }

    It 'checks actual run ownership immediately before every installer and uninstaller invocation' -ForEach @(
        @{ operation = 'desktop_installer' }, @{ operation = 'desktop_uninstaller' }
    ) {
        $script:DesktopRunOwnedRoot = Join-Path $TestDrive ('winsmux-public-release-' + ('a' * 32))
        $installed = Join-Path $script:DesktopRunOwnedRoot 'installed'
        $capture = @{ count = 0; arguments = @() }
        $invoke = { param($FilePath, $Arguments, $Environment) $capture.count++; $capture.arguments = $Arguments; return @{ exit_code = 0 } }.GetNewClosure()
        $context = [pscustomobject]@{ owned_root = $script:DesktopRunOwnedRoot; install_root = $installed }
        (Invoke-DesktopNsisProcess -Operation $operation -FilePath 'C:\missing-fixture.exe' -Context $context -ProcessInvoker $invoke).exit_code | Should -Be 0
        $capture.count | Should -Be 1
        $capture.arguments | Should -Be @('/S', $(if ($operation -ceq 'desktop_installer') { "/D=$installed" } else { "_?=$installed" }))
        foreach ($mutation in @('foreign_owned', 'foreign_install', 'relative_owned', 'relative_install', 'noncanonical')) {
            $changed = $context.PSObject.Copy()
            switch ($mutation) {
                foreign_owned { $changed.owned_root = Join-Path $TestDrive ('winsmux-public-release-' + ('b' * 32)) }
                foreign_install { $changed.install_root = Join-Path (Join-Path $TestDrive ('winsmux-public-release-' + ('b' * 32))) 'installed' }
                relative_owned { $changed.owned_root = 'relative' }
                relative_install { $changed.install_root = 'installed' }
                noncanonical { $changed.install_root = Join-Path $script:DesktopRunOwnedRoot 'other\..\installed' }
            }
            { Invoke-DesktopNsisProcess -Operation $operation -FilePath 'C:\missing-fixture.exe' -Context $changed -ProcessInvoker $invoke } | Should -Throw
            $capture.count | Should -Be 1
        }
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

Describe 'Desktop failure diagnostic retention' {
    BeforeAll {
        function New-DiagnosticCapture {
            return [pscustomobject]@{ exit_code = 7; stdout = 'synthetic-output'; stderr = 'synthetic-error'; stdout_metadata = [pscustomobject]@{ present = $true; bytes = 16; truncated = $false }; stderr_metadata = [pscustomobject]@{ present = $true; bytes = 15; truncated = $false }; native_observation = [pscustomobject]@{ root_exited = $true; root_exit_code = 7; active_members = 0; stdout_state = 'eof'; stderr_state = 'eof'; forced = $false } }
        }
        function Get-DiagnosticReceipt($Failure, $CleanupFailure = $null) {
            return New-DesktopFailureReceipt -Failure $Failure -CleanupFailure $CleanupFailure -Version '0.38.0' -ReleaseTag 'v0.38.0' -Stage 'candidate_install' -CleanupStage 'not_started' -Phase 'preserve'
        }
        function Wrap-DiagnosticFailure($Failure, [string]$Graph) {
            switch ($Graph) {
                'wrapper' { return [InvalidOperationException]::new('synthetic private-token outer', $Failure) }
                'double' { return [InvalidOperationException]::new('synthetic outer', [InvalidOperationException]::new('synthetic inner', $Failure)) }
                'aggregate' { return [AggregateException]::new('synthetic aggregate', [Exception[]]@($Failure, $Failure.InnerException)) }
                'cycle' { $Failure.Data['original_exception'] = $Failure; return $Failure }
                'nested_data' { $outer = [InvalidOperationException]::new('synthetic private-token outer'); $outer.Data['original_exception'] = $Failure; return $outer }
                'error_record' { return [Management.Automation.ErrorRecord]::new($Failure, 'synthetic', [Management.Automation.ErrorCategory]::NotSpecified, $null) }
                default { return $Failure }
            }
        }
    }
    # Graph contract: breadth-first, role Data edges before InnerException/aggregate
    # edges, visited identities once. The first present canonical slot wins, even
    # when null. Missing roles fall back to caller roles; explicit null means none.
    # native_result/process_result share one slot. Missing/null native facts never
    # claim completion. Only safe reason tokens and observation metadata are emitted.
    It 'preserves the cleanup-only lifecycle role declaration without inventing an operation failure' {
        $cleanup = [InvalidOperationException]::new('desktop_normal_close_incomplete')
        $cleanup.Data['operation_failure'] = $null
        $cleanup.Data['cleanup_failure'] = $cleanup
        $receipt = Get-DiagnosticReceipt $cleanup
        $receipt.operation_failure | Should -BeExactly 'none'
        $receipt.cleanup_failure | Should -BeExactly 'desktop_normal_close_incomplete'
        $receipt.reason_code | Should -BeExactly 'desktop_normal_close_incomplete'
        $receipt.ok | Should -BeFalse
    }
    It 'keeps a final cleanup-only caller separate from the absent operation input' {
        $cleanup = [InvalidOperationException]::new('desktop_final_cleanup_failed')
        $receipt = Get-DiagnosticReceipt $null $cleanup
        $receipt.operation_failure | Should -BeExactly 'none'
        $receipt.cleanup_failure | Should -BeExactly 'desktop_final_cleanup_failed'
        $receipt.reason_code | Should -BeExactly 'desktop_final_cleanup_failed'
    }
    It 'passes the absent operation role from the actual final failure caller' {
        $branch = $script:HelperAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text.StartsWith("if (`$Surface -ceq 'Desktop' -and `$Json -and")
        }, $true)[0].Clauses[0].Item2.Statements
        $receipt = & {
            $operationError = $null
            $cleanupError = [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('desktop_final_cleanup_failed'), 'synthetic', [Management.Automation.ErrorCategory]::NotSpecified, $null)
            . ([scriptblock]::Create($branch[0].Extent.Text))
            . ([scriptblock]::Create($branch[2].Extent.Text))
            Get-DiagnosticReceipt $exception $cleanupException
        }
        $receipt.operation_failure | Should -BeExactly 'none'
        $receipt.cleanup_failure | Should -BeExactly 'desktop_final_cleanup_failed'
    }
    It 'retains role presence and value across <graph> with operation <operation> and cleanup <cleanup>' -ForEach @(
        foreach ($graph in @('direct', 'wrapper', 'double', 'aggregate', 'cycle', 'nested_data', 'error_record')) {
            foreach ($operation in @('missing', 'null', 'value')) {
                foreach ($cleanup in @('missing', 'null', 'value')) { @{ graph = $graph; operation = $operation; cleanup = $cleanup } }
            }
        }
    ) {
        $later = [InvalidOperationException]::new('synthetic private-token later')
        $carrier = [InvalidOperationException]::new('desktop_fixture_failed', $later)
        foreach ($role in @('operation', 'cleanup')) {
            $state = Get-Variable -Name $role -ValueOnly
            if ($state -cne 'missing') {
                $carrier.Data[$role + '_failure'] = if ($state -ceq 'value') { [InvalidOperationException]::new('desktop_' + $role + '_fixture_failed') } else { $null }
                $later.Data[$role + '_failure'] = [InvalidOperationException]::new('desktop_later_' + $role + '_failed')
            }
        }
        $failure = Wrap-DiagnosticFailure $carrier $graph
        $externalCleanup = [InvalidOperationException]::new('desktop_external_cleanup_failed')
        $evidence = Get-DesktopFailureEvidence $failure
        $evidence.present.operation_failure | Should -Be ($operation -cne 'missing')
        $evidence.present.cleanup_failure | Should -Be ($cleanup -cne 'missing')
        $receipt = Get-DiagnosticReceipt $failure $externalCleanup
        $expectedOperation = switch ($operation) { 'missing' { 'desktop_fixture_failed' }; 'null' { 'none' }; 'value' { 'desktop_operation_fixture_failed' } }
        $expectedCleanup = switch ($cleanup) { 'missing' { 'desktop_external_cleanup_failed' }; 'null' { 'none' }; 'value' { 'desktop_cleanup_fixture_failed' } }
        $receipt.operation_failure | Should -BeExactly $expectedOperation
        $receipt.cleanup_failure | Should -BeExactly $expectedCleanup
        $receipt.ok | Should -BeFalse
        ($receipt | ConvertTo-Json -Depth 8 -Compress) | Should -Not -Match 'private-token|desktop_later_'
    }
    It 'retains <slot> as <state> without overwriting explicit null from a later Data node' -ForEach @(
        foreach ($slot in @('native_result', 'process_result', 'observation', 'native_observation')) {
            foreach ($state in @('missing', 'nested', 'null', 'available')) { @{ slot = $slot; state = $state } }
        }
    ) {
        $later = [InvalidOperationException]::new('synthetic private-token later')
        $carrier = [InvalidOperationException]::new('desktop_fixture_failed', $later)
        $value = switch ($slot) {
            'observation' { [pscustomobject]@{ exit_code = 9; stdout_bytes = 22; stderr_bytes = 23; state = 'exited' } }
            'native_observation' { [pscustomobject]@{ root_exited = $false; root_exit_code = $null; active_members = 1; stdout_state = 'pending'; stderr_state = 'pending'; forced = $false } }
            default { New-DiagnosticCapture }
        }
        if ($slot -ceq 'native_observation') { $carrier.Data['native_result'] = New-DiagnosticCapture }
        if ($state -cin @('null', 'available')) { $carrier.Data[$slot] = if ($state -ceq 'available') { $value } else { $null } }
        if ($state -cne 'missing') {
            $laterSlot = if ($slot -ceq 'native_result') { 'process_result' } elseif ($slot -ceq 'process_result') { 'native_result' } else { $slot }
            $later.Data[$laterSlot] = $value
        }
        $outer = [InvalidOperationException]::new('synthetic private-token outer')
        $outer.Data['original_exception'] = $carrier
        $carrier.Data['original_exception'] = $outer
        $canonicalSlot = if ($slot -ceq 'process_result') { 'native_result' } else { $slot }
        $evidence = Get-DesktopFailureEvidence $outer
        $evidence.present[$canonicalSlot] | Should -Be ($state -cne 'missing')
        if ($state -ceq 'null') { ($null -eq $evidence.$canonicalSlot) | Should -BeTrue }
        elseif ($state -cin @('nested', 'available')) { [object]::ReferenceEquals($evidence.$canonicalSlot, $value) | Should -BeTrue }
        $receipt = Get-DiagnosticReceipt $outer
        if ($slot -ceq 'native_observation') {
            $expectedStream = switch ($state) { 'missing' { 'eof' }; 'null' { 'unknown' }; default { 'pending' } }
            $receipt.native_observation.stdout_state | Should -BeExactly $expectedStream
            if ($state -ceq 'null') { ($null -eq $receipt.native_observation.root_exited) | Should -BeTrue }
        } elseif ($state -cin @('missing', 'null')) {
            ($null -eq $receipt.native_exit_code) | Should -BeTrue
            ($null -eq $receipt.stdout_bytes) | Should -BeTrue
            $receipt.native_observation.stdout_state | Should -BeExactly 'unknown'
        } elseif ($slot -ceq 'observation') {
            $receipt.native_exit_code | Should -Be 9
            $receipt.stdout_bytes | Should -Be 22
            $receipt.observation_state | Should -BeExactly 'exited'
        } else {
            $receipt.native_exit_code | Should -Be 7
            $receipt.stdout_bytes | Should -Be 16
        }
        ($receipt | ConvertTo-Json -Depth 8 -Compress) | Should -Not -Match 'private-token|synthetic-output|synthetic-error'
    }
    It 'gives native_result explicit null precedence over its process_result alias on the same node' {
        $failure = [InvalidOperationException]::new('desktop_fixture_failed')
        $failure.Data['native_result'] = $null
        $failure.Data['process_result'] = New-DiagnosticCapture
        $receipt = Get-DiagnosticReceipt $failure
        ($null -eq $receipt.native_exit_code) | Should -BeTrue
        ($null -eq $receipt.stdout_bytes) | Should -BeTrue
        $receipt.native_observation.stdout_state | Should -BeExactly 'unknown'
    }
    It 'projects only known native observation facts and keeps malformed or unobserved fields unknown' {
        foreach ($valid in @($true, $false)) {
            $failure = [InvalidOperationException]::new('desktop_fixture_failed')
            $failure.Data['native_observation'] = if ($valid) {
                [pscustomobject]@{ root_exited = $true; root_exit_code = 7; active_members = 0; stdout_state = 'eof'; stderr_state = 'failed'; forced = $false; raw_secret = 'private-token' }
            } else {
                [pscustomobject]@{ root_exited = 'false'; root_exit_code = 'private-token'; active_members = -1; stdout_state = 'private-token'; stderr_state = $null; forced = 'false'; raw_secret = 'private-token' }
            }
            $receipt = Get-DiagnosticReceipt $failure
            @($receipt.native_observation.PSObject.Properties.Name | Sort-Object) | Should -Be @('active_members', 'forced', 'root_exit_code', 'root_exited', 'stderr_state', 'stdout_state')
            if ($valid) {
                $receipt.native_observation.root_exited | Should -BeTrue
                $receipt.native_observation.root_exit_code | Should -Be 7
                $receipt.native_observation.active_members | Should -Be 0
                $receipt.native_observation.stdout_state | Should -BeExactly 'eof'
                $receipt.native_observation.stderr_state | Should -BeExactly 'failed'
                $receipt.native_observation.forced | Should -BeFalse
            } else {
                ($null -eq $receipt.native_observation.root_exited) | Should -BeTrue
                ($null -eq $receipt.native_observation.root_exit_code) | Should -BeTrue
                ($null -eq $receipt.native_observation.active_members) | Should -BeTrue
                ($null -eq $receipt.native_observation.forced) | Should -BeTrue
                $receipt.native_observation.stdout_state | Should -BeExactly 'unknown'
                $receipt.native_observation.stderr_state | Should -BeExactly 'unknown'
            }
            ($receipt | ConvertTo-Json -Depth 8 -Compress) | Should -Not -Match 'private-token|raw_secret'
        }
    }
    It 'preserves timeout Data and public metadata message through the public child wrapper' {
        $script:DiagnosticCapture = New-DiagnosticCapture
        $script:DiagnosticFailure = [TimeoutException]::new('desktop_owned_child_timeout')
        $script:DiagnosticFailure.Data['process_result'] = $script:DiagnosticCapture
        $script:DiagnosticFailure.Data['native_observation'] = [pscustomobject]@{ root_exited = $true; root_exit_code = 0; active_members = 1; stdout_state = 'pending'; stderr_state = 'pending'; forced = $false }
        Mock Invoke-DesktopOwnedNativeProcess { throw $script:DiagnosticFailure }
        $caught = $null
        try { Invoke-PublicChildProcess -Operation desktop_installer -FilePath 'synthetic.exe' } catch { $caught = $_.Exception }
        $caught.Message | Should -BeExactly (Format-PublicChildProcessDiagnostic -Operation desktop_installer -State timed_out -Result $script:DiagnosticCapture)
        $evidence = Get-DesktopFailureEvidence $caught
        [object]::ReferenceEquals($evidence.native_result, $script:DiagnosticCapture) | Should -BeTrue
        $receipt = Get-DiagnosticReceipt $caught
        $receipt.reason_code | Should -BeExactly 'desktop_owned_child_timeout'
        $receipt.native_exit_code | Should -Be 7
        $receipt.stdout_bytes | Should -Be 16
        $receipt.stderr_bytes | Should -Be 15
        $receipt.native_observation.active_members | Should -Be 1
        $receipt.native_observation.stdout_state | Should -BeExactly 'pending'
        $receipt.cleanup | Should -BeExactly 'preserve'
        $receipt.ok | Should -BeFalse
        ($receipt | ConvertTo-Json -Depth 8 -Compress) | Should -Not -Match 'synthetic-output|synthetic-error'
    }
    It 'retains a timeout with unknown capture without inventing native completion' {
        Mock Invoke-DesktopOwnedNativeProcess { throw [TimeoutException]::new('desktop_owned_child_timeout') }
        $caught = $null
        try { Invoke-PublicChildProcess -Operation desktop_installer -FilePath 'synthetic.exe' } catch { $caught = $_.Exception }
        $caught.Message | Should -BeExactly 'Timed-out child process did not provide a terminal output capture.'
        $receipt = Get-DiagnosticReceipt $caught
        $receipt.reason_code | Should -BeExactly 'desktop_owned_child_timeout'
        ($null -eq $receipt.native_exit_code) | Should -BeTrue
        ($null -eq $receipt.stdout_bytes) | Should -BeTrue
        ($null -eq $receipt.native_observation.root_exited) | Should -BeTrue
        ($null -eq $receipt.native_observation.active_members) | Should -BeTrue
        $receipt.native_observation.stdout_state | Should -BeExactly 'unknown'
    }
    It 'extracts nonzero and cleanup evidence through double wrappers and aggregate siblings' {
        $operation = [InvalidOperationException]::new('desktop_installer_exit_nonzero')
        $operation.Data['native_result'] = New-DiagnosticCapture
        $cleanup = [InvalidOperationException]::new('desktop_normal_close_incomplete')
        $aggregate = [AggregateException]::new('synthetic aggregate', [Exception[]]@($operation, $cleanup))
        $aggregate.Data['operation_failure'] = $operation
        $aggregate.Data['cleanup_failure'] = $cleanup
        $outer = [InvalidOperationException]::new('outer', [InvalidOperationException]::new('inner', $aggregate))
        $receipt = Get-DiagnosticReceipt $outer
        $receipt.reason_code | Should -BeExactly 'desktop_installer_exit_nonzero'
        $receipt.operation_failure | Should -BeExactly 'desktop_installer_exit_nonzero'
        $receipt.cleanup_failure | Should -BeExactly 'desktop_normal_close_incomplete'
        $receipt.native_exit_code | Should -Be 7
        $receipt.native_observation.stdout_state | Should -BeExactly 'eof'
        $receipt.ok | Should -BeFalse
    }
    It 'keeps unavailable data unknown and visits an exception cycle only once' {
        $failure = [InvalidOperationException]::new('synthetic generic failure')
        $failure.Data['original_exception'] = $failure
        $receipt = Get-DiagnosticReceipt $failure
        $receipt.reason_code | Should -BeExactly 'desktop_operation_failed'
        $receipt.cleanup_failure | Should -BeExactly 'none'
        ($null -eq $receipt.native_exit_code) | Should -BeTrue
        ($null -eq $receipt.stderr_bytes) | Should -BeTrue
        $receipt.native_observation.stderr_state | Should -BeExactly 'unknown'
    }
    It 'observes root Job and EOF facts without treating pending failed or absent facts as completion' -ForEach @(
        @{ state = 'pending' }, @{ state = 'failed' }, @{ state = 'eof' }, @{ state = 'unknown' }
    ) {
        $task = switch ($state) {
            'pending' { [Threading.Tasks.TaskCompletionSource[string]]::new().Task }
            'failed' { [Threading.Tasks.Task]::FromException([InvalidOperationException]::new('synthetic reader failure')) }
            'eof' { [Threading.Tasks.Task]::FromResult(0) }
            default { $null }
        }
        $owner = [pscustomobject]@{ HasExited = $false; ActiveMembers = 1; Forced = $false; StdoutTask = $task; StderrTask = $task }
        $observation = Get-DesktopOwnedProcessObservation ([pscustomobject]@{ owner = $owner })
        $observation.root_exited | Should -BeFalse
        ($null -eq $observation.root_exit_code) | Should -BeTrue
        $observation.active_members | Should -Be 1
        $observation.stdout_state | Should -BeExactly $state
        $observation.stderr_state | Should -BeExactly $state
        (Get-DesktopOwnedProcessObservation ([pscustomobject]@{ owner = [pscustomobject]@{} })).root_exited | Should -BeNullOrEmpty
    }
    It 'passes a successful child capture through without turning it into a failure' {
        $script:DiagnosticCapture = New-DiagnosticCapture
        $script:DiagnosticCapture.exit_code = 0
        Mock Invoke-DesktopOwnedNativeProcess { return $script:DiagnosticCapture }
        $result = Invoke-PublicChildProcess -Operation desktop_installer -FilePath 'synthetic.exe'
        [object]::ReferenceEquals($result, $script:DiagnosticCapture) | Should -BeTrue
        $result.exit_code | Should -Be 0
    }
    It 'collects only the six current helper streams and excludes stray runner inputs' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/test.yml') -Raw
        $block = [regex]::Match($workflow, '(?ms)^      - name: Preserve available NSIS helper diagnostics\r?\n.*?        run: \|\r?\n(?<run>(?:          [^\r\n]*\r?\n|\r?\n)+)')
        $block.Success | Should -BeTrue
        $run = $block.Groups['run'].Value -replace '(?m)^          ', ''
        $workspace = Join-Path $TestDrive 'diagnostic-workspace'; $runnerTemp = Join-Path $TestDrive 'diagnostic-temp'
        New-Item -ItemType Directory -Path $workspace, $runnerTemp | Out-Null
        $allowlist = @('task679-fresh.stdout', 'task679-fresh.stderr', 'task679-upgrade.stdout', 'task679-upgrade.stderr', 'task679-migration.stdout', 'task679-migration.stderr')
        foreach ($name in ($allowlist + @('task679-fresh.secret', 'other.stdout'))) { [IO.File]::WriteAllText((Join-Path $runnerTemp $name), 'synthetic') }
        $previousWorkspace = $env:GITHUB_WORKSPACE; $previousTemp = $env:RUNNER_TEMP
        try { $env:GITHUB_WORKSPACE = $workspace; $env:RUNNER_TEMP = $runnerTemp; & ([scriptblock]::Create($run)) }
        finally { $env:GITHUB_WORKSPACE = $previousWorkspace; $env:RUNNER_TEMP = $previousTemp }
        $copied = @(Get-ChildItem -LiteralPath (Join-Path $workspace 'artifacts/task679-nsis-lifecycle/helper-logs') -File | Select-Object -ExpandProperty Name)
        ($copied | Sort-Object) | Should -Be ($allowlist | Sort-Object)
        $upload = [regex]::Match($workflow, '(?ms)name: task679-nsis-lifecycle-evidence\r?\n          path: \|\r?\n(?<paths>(?:            [^\r\n]*\r?\n)+)').Groups['paths'].Value
        foreach ($name in $allowlist) { $upload | Should -Match ([regex]::Escape('helper-logs/' + $name)) }
        $upload | Should -Not -Match '\*|RUNNER_TEMP|other\.stdout|fresh\.secret'
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
