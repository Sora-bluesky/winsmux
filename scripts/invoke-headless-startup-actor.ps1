[CmdletBinding()]
param(
 [switch]$HeadlessParent,
 [switch]$ProjectionSelfTest,
 [switch]$SourceAdmissionOnly,
 [string]$SourceCommit,
 [string]$BuildManifest,
 [string]$Surface,[string]$Version,[string]$ReleaseTag,[string]$Repository,
 [switch]$DesktopNativeLifecycle,[string]$DesktopNativeFormat,
 [string]$DesktopNativeSourceCommit,[string]$DesktopNativeCandidateDirectory,
 [string]$DesktopNativeBaselineDirectory,[switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$utf8=[Text.UTF8Encoding]::new($false,$true)
$tests=@('real_host_without_provider_path_keeps_launch_unadvertised','host_startup_fails_closed_before_discovery_when_security_primitives_fail')
function Assert-Fixed([bool]$Condition,[string]$Code) { if(-not $Condition){throw $Code} }
function Assert-CanonicalSourceInputs([string]$Root) {
 # One raw-byte choke point; no newline conversion or alternate hashes are accepted.
 $pins=ConvertFrom-Json -AsHashtable '[{"path":"scripts/test-public-release.ps1","bytes":579080,"sha256":"4c215216c9d8d90a3cafb6797e249b2bbc26bf8efb2683bc2a3e72a9eb5768b7"},{"path":"scripts/DesktopProcessOwner.cs","bytes":24379,"sha256":"cc9d426f86455395b87d1f2d6524deea0ab5ddb4014ad05c58e1e0b576c09a8c"},{"path":"core/tests-rs/workspace_host_e2e.rs","bytes":176005,"sha256":"db8fb3814aab6944d21bc72ea4ea1560cf1b875f7f7ecc647786416e7d69fbfc"},{"path":"core/tests-rs/support/conpty_json.rs","bytes":12923,"sha256":"8da14f11218bd84c6d2de17d1904705c56b64c44346c3d73138936a2d05859e9"},{"path":"core/crates/winsmux-workspace/src/host/windows.rs","bytes":96735,"sha256":"b8a0e9c56ab8b9e77090370091b779d738327f4cc9ad3633353563a8a6bf8a4d"},{"path":"core/crates/winsmux-workspace/src/host/process.rs","bytes":10135,"sha256":"a667b3ee876166f5a88366dd2979ccc9f8d70e84d25de594bae7a6403abacc74"},{"path":"core/crates/winsmux-workspace/src/host/security.rs","bytes":21925,"sha256":"b3f959bf92f3a3ab2ceeb243d39902895ec7458f1a5c1c78e0a2e31358720a80"},{"path":"core/crates/winsmux-workspace/src/host/mod.rs","bytes":4569,"sha256":"2854949034e622b7bf1fc31118080ec2ee0df04aba4ff895ded241a6a4675dd6"},{"path":"core/crates/winsmux-workspace/src/client/mod.rs","bytes":73120,"sha256":"4fd2ab3e0cc2635d1dad6f774a31b1ed9076672f0d823167eb8d7606d9157ea1"},{"path":"Cargo.toml","bytes":556,"sha256":"3c50db3d0d7650d46dd3342eef78c678c1261a2b3f75dce6d79b1d648a30b5a3"},{"path":"Cargo.lock","bytes":165475,"sha256":"26d1bef4c5a4fc47330468a719d8ff59e0fb85e483aa84d0e0752bba99d85c30"},{"path":"core/Cargo.toml","bytes":4498,"sha256":"a52039539867a3fcdaa3e0fdf8a5a0eea670d0ba5ff0445c046e63d60bd8085d"},{"path":".github/actions/setup-windows-distribution-toolchain/action.yml","bytes":677,"sha256":"7811950cfe808ec3ab951033da4a4760bd37c4348a668739dd074c86fe56b6f2"}]'
 $attribute=ConvertFrom-Json -AsHashtable '{"path":".gitattributes","bytes":1481,"sha256":"1288f24e7629cbec0701a6d17ce78ecbce87b9cc13fec4d7efb2a841ab7d354d"}'
 $attributePaths=ConvertFrom-Json '[".gitattributes",".github/.gitattributes",".github/actions/.gitattributes",".github/actions/setup-windows-distribution-toolchain/.gitattributes",".github/workflows/.gitattributes","core/.gitattributes","core/crates/.gitattributes","core/crates/winsmux-workspace/.gitattributes","core/crates/winsmux-workspace/src/.gitattributes","core/crates/winsmux-workspace/src/client/.gitattributes","core/crates/winsmux-workspace/src/host/.gitattributes","core/tests-rs/.gitattributes","core/tests-rs/support/.gitattributes","scripts/.gitattributes"]'
 foreach($name in $attributePaths){Assert-Fixed ((Test-Path -LiteralPath (Join-Path $Root $name)) -eq ($name -ceq '.gitattributes')) 'input_attribute_inventory_changed'}
 foreach($pin in @($attribute)+@($pins)){$p=Join-Path $Root $pin.path;Assert-Fixed ((Get-Item -LiteralPath $p).Length -eq $pin.bytes -and (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $pin.sha256) 'input_source_changed'}
}
function ConvertTo-HeadlessFixedProjection {
 param([byte[]]$Stdout,[byte[]]$Stderr,[bool]$Truncated,[string]$Test,[int]$ExitCode,[bool]$Terminal,[bool]$JobZero,[bool]$Forced)
 $result=[ordered]@{test=$Test;outcome='unobserved';process_exit=$(if($ExitCode -eq 0){'zero'}elseif($ExitCode -eq 101){'test_failure'}elseif($ExitCode -eq 124){'owned_stop'}else{'other'});terminal=$Terminal;job_zero=$JobZero;forced=$Forced;capture_complete=(-not $Truncated);child_stages=@();launcher_stages=@();host_classes=@();unknown_marker=$false;conpty_or_debug_only=$false}
 if($Truncated -or -not $Terminal -or -not $JobZero){return $result}
 try{$text=[Text.UTF8Encoding]::new($false,$true).GetString($Stdout)+[char]10+[Text.UTF8Encoding]::new($false,$true).GetString($Stderr)}catch{return $result}
 $text=[regex]::Replace($text,[string][char]27+'\[[0-?]*[ -/]*[@-~]','')
 $child=@('handle','identity','mutex','inheritance_probe','capability','server_key','authorization','cancel_event','supervisor','discovery','public_pipe','accept_thread','discovery_serialization')
 $launcher=@('terminal','identity','inheritance_probe','console','channel','child_spawn','startup_frame','probe_ready','discovery_frame','discovery_parse','discovery_validation','discovery_serialization','output_started')
 foreach($pair in @([pscustomobject]@{kind='CHILD';allowed=$child;field='child_stages'},[pscustomobject]@{kind='OWNER';allowed=$launcher;field='launcher_stages'})){
  $seen=[Collections.Generic.List[string]]::new()
  $pattern='(?<![A-Za-z0-9_])TASK876_'+$pair.kind+'_STARTUP stage=([^\s\x00-\x1f]+)'
  foreach($m in [regex]::Matches($text,$pattern)){
   $value=$m.Groups[1].Value
   if($value -cin $pair.allowed){if(-not $seen.Contains($value)){$seen.Add($value)}}else{$result.unknown_marker=$true}
  }
  $result[$pair.field]=$seen.ToArray()
 }
 $classes=[Collections.Generic.List[string]]::new()
 $allowed=@('usage','interactive_required','startup_failed','transport_failed','protocol_failed','cancelled')
 foreach($m in [regex]::Matches($text,'(?<![A-Za-z0-9_])(?:class=|winsmux workspace: )([^\s\x00-\x1f]+)')){
  $value=$m.Groups[1].Value
  if($value -cin $allowed){if(-not $classes.Contains($value)){$classes.Add($value)}}else{$result.unknown_marker=$true}
 }
 $result.host_classes=$classes.ToArray()
 $result.conpty_or_debug_only=(@($result.launcher_stages|Where-Object{$_ -cin @('terminal','console','inheritance_probe','probe_ready','output_started')}).Count -gt 0 -or 'inheritance_probe' -cin $result.child_stages)
 $name=[regex]::Escape($Test)
 $passed=[regex]::IsMatch($text,'(?m)^test '+$name+' \.\.\. ok\r?$') -and [regex]::IsMatch($text,'(?m)^test result: ok\. 1 passed; 0 failed;')
 $failed=[regex]::IsMatch($text,'(?m)^test '+$name+' \.\.\. FAILED\r?$') -and [regex]::IsMatch($text,'(?m)^test result: FAILED\. 0 passed; 1 failed;')
 if(-not $result.unknown_marker -and -not $Forced){if($ExitCode -eq 0 -and $passed){$result.outcome='passed'}elseif($ExitCode -ne 0 -and $failed){$result.outcome='failed'}}
 return $result
}
function Assert-HeadlessProjectionShape($Row,[string]$ExpectedTest) {
 $keys=@('test','outcome','process_exit','terminal','job_zero','forced','capture_complete','child_stages','launcher_stages','host_classes','unknown_marker','conpty_or_debug_only')
 Assert-Fixed ($Row -is [Collections.IDictionary] -and (@($Row.Keys|Sort-Object -CaseSensitive)-join [char]10) -ceq (@($keys|Sort-Object -CaseSensitive)-join [char]10)) 'projection_shape'
 Assert-Fixed ($Row.test -is [string] -and $Row.outcome -is [string] -and $Row.process_exit -is [string] -and $Row.test -ceq $ExpectedTest -and $Row.outcome -cin @('passed','failed','unobserved') -and $Row.process_exit -cin @('zero','test_failure','owned_stop','other')) 'projection_values'
 foreach($key in @('terminal','job_zero','forced','capture_complete','unknown_marker','conpty_or_debug_only')){Assert-Fixed ($Row[$key] -is [bool]) 'projection_boolean'}
 $sets=@{child_stages=@('handle','identity','mutex','inheritance_probe','capability','server_key','authorization','cancel_event','supervisor','discovery','public_pipe','accept_thread','discovery_serialization');launcher_stages=@('terminal','identity','inheritance_probe','console','channel','child_spawn','startup_frame','probe_ready','discovery_frame','discovery_parse','discovery_validation','discovery_serialization','output_started');host_classes=@('usage','interactive_required','startup_failed','transport_failed','protocol_failed','cancelled')}
 foreach($key in $sets.Keys){Assert-Fixed ($Row[$key] -is [Collections.IList]) 'projection_array';foreach($value in $Row[$key]){Assert-Fixed ($value -is [string] -and $value -cin $sets[$key]) 'projection_enum'}}
 if($Row.outcome -cne 'unobserved'){Assert-Fixed ($Row.terminal -and $Row.job_zero -and -not $Row.forced -and $Row.capture_complete -and -not $Row.unknown_marker) 'projection_acceptance'}
 if($Row.outcome -ceq 'passed'){Assert-Fixed ($Row.process_exit -ceq 'zero') 'projection_pass_exit'}
 if($Row.outcome -ceq 'failed'){Assert-Fixed ($Row.process_exit -cne 'zero') 'projection_failure_exit'}
}
function Test-HeadlessProjection {
 $test='real_host_without_provider_path_keeps_launch_unadvertised'
 $good='test '+$test+' ... ok'+[char]10+'test result: ok. 1 passed; 0 failed; 0 ignored;'
 $convert={param($text,$code=0,$truncated=$false,$terminal=$true,$job=$true,$forced=$false) ConvertTo-HeadlessFixedProjection -Stdout ([Text.Encoding]::UTF8.GetBytes($text)) -Stderr @() -Truncated $truncated -Test $test -ExitCode $code -Terminal $terminal -JobZero $job -Forced $forced}
 Assert-Fixed ((& $convert $good).outcome -ceq 'passed') 'projection_positive'
 Assert-Fixed ((& $convert 'test result: ok. 0 passed; 0 failed;').outcome -ceq 'unobserved') 'projection_zero_is_not_pass'
 Assert-Fixed ((& $convert $good 0 $true).outcome -ceq 'unobserved') 'projection_truncation'
 Assert-Fixed ((& $convert $good 0 $false $false).outcome -ceq 'unobserved') 'projection_nonterminal'
 Assert-Fixed ((& $convert $good 0 $false $true $false).outcome -ceq 'unobserved') 'projection_live_job'
 Assert-Fixed ((& $convert $good 0 $false $true $true $true).outcome -ceq 'unobserved') 'projection_forced'
 $ansi=[string][char]27+'[?9001l'
 $fixed='TASK876_CHILD_STARTUP stage='+$ansi+'capability'+[char]10+'TASK876_OWNER_STARTUP stage=startup_frame class=transport_failed'
 $value=& $convert ($fixed+[char]10+$good)
 Assert-Fixed ($value.child_stages.Count -eq 1 -and $value.child_stages[0] -ceq 'capability' -and $value.host_classes[0] -ceq 'transport_failed') 'projection_fixed_stage'
 $bad=& $convert ('TASK876_CHILD_STARTUP stage=capability-extra'+[char]10+$good)
 Assert-Fixed ($bad.outcome -ceq 'unobserved' -and $bad.child_stages.Count -eq 0 -and $bad.unknown_marker) 'projection_stage_suffix'
 $bad=& $convert ('TASK876_OWNER_STARTUP stage=console class=SECRET_UNKNOWN'+[char]10+$good)
 Assert-Fixed ($bad.outcome -ceq 'unobserved' -and $bad.host_classes.Count -eq 0 -and $bad.conpty_or_debug_only) 'projection_unknown_class'
 $failure='TASK876_CHILD_STARTUP stage=authorization'+[char]10+'test '+$test+' ... FAILED'+[char]10+'test result: FAILED. 0 passed; 1 failed;'
 $value=& $convert $failure 101
 Assert-Fixed ($value.outcome -ceq 'failed' -and $value.child_stages[0] -ceq 'authorization') 'projection_failure_retained'
 $invalid=ConvertTo-HeadlessFixedProjection -Stdout ([byte[]]@(255)) -Stderr @() -Truncated $false -Test $test -ExitCode 0 -Terminal $true -JobZero $true -Forced $false
 Assert-Fixed ($invalid.outcome -ceq 'unobserved') 'projection_utf8'
 $serialized=$value|ConvertTo-Json -Depth 8 -Compress
 Assert-Fixed (-not $serialized.Contains('SECRET_UNKNOWN')) 'projection_no_raw_export'
 Assert-HeadlessProjectionShape $value $test
 $stray=ConvertTo-HeadlessFixedProjection -Stdout ([Text.Encoding]::UTF8.GetBytes($good)) -Stderr @() -Truncated $false -Test $test -ExitCode 0 -Terminal $true -JobZero $true -Forced $false
 $stray['raw']='SECRET_UNKNOWN';$rejected=$false;try{Assert-HeadlessProjectionShape $stray $test}catch{$rejected=$true};Assert-Fixed $rejected 'projection_stray_field'
 [void]$stray.Remove('raw');$stray['terminal']=$false;$rejected=$false;try{Assert-HeadlessProjectionShape $stray $test}catch{$rejected=$true};Assert-Fixed $rejected 'projection_false_pass'
 return [ordered]@{schema='winsmux-headless-projection-finite/v1';outcome='passed';cases=14}
}
if($ProjectionSelfTest){try{Test-HeadlessProjection|ConvertTo-Json -Compress;exit 0}catch{[Console]::Out.WriteLine('{"schema":"winsmux-headless-projection-finite/v1","outcome":"failed"}');exit 1}}
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$phase='source_admission';$outer=$null;$outerTerminal=$false;$evidenceRoot=$null
$result=[ordered]@{schema='winsmux-headless-restricted-actor/v1';outcome='unobserved';source_commit=$null;actor_admitted=$false;same_sid=$false;same_session=$false;restricted_medium=$false;tests=@();root_terminal=$false;root_job_zero=$false;forced=$false;failure=$null;nsis_success_proven=$false;normal_gui_success_proven=$false}
try {
 Assert-Fixed ($env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_OS -ceq 'Windows' -and $env:GITHUB_RUN_ID -cmatch '^[1-9][0-9]*$' -and $env:GITHUB_RUN_ATTEMPT -cmatch '^[1-9][0-9]*$') 'runner_identity'
 $source=if($HeadlessParent -or $SourceAdmissionOnly){$SourceCommit}else{$DesktopNativeSourceCommit}
 Assert-Fixed ($source -cmatch '^[a-f0-9]{40}$' -and $source -ceq $env:GITHUB_SHA) 'source_identity'
 $result.source_commit=$source
 Assert-CanonicalSourceInputs $repoRoot
 if($SourceAdmissionOnly){[Console]::Out.WriteLine('{"schema":"winsmux-headless-source-admission/v1","outcome":"passed","runtime_inputs":13,"attribute_policy":"fixed"}');exit 0}
 $sourcePath=Join-Path $repoRoot 'scripts/test-public-release.ps1'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
 Assert-Fixed (@($errors).Count -eq 0) 'actor_source_parse'
 $initializers=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Initialize-DesktopNativeLifecycleActor'},$false))
 Assert-Fixed ($initializers.Count -eq 1) 'actor_initializer'
 function Read-FixedLiteral($Scope,[string]$Name){
  $rows=@($Scope.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq $Name -and $node.Right -is [Management.Automation.Language.CommandExpressionAst] -and $node.Right.Expression -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Right.Expression.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString},$true))
  Assert-Fixed ($rows.Count -eq 1) 'actor_literal';return [string]$rows[0].Right.Expression.Value
 }
 $actor=Read-FixedLiteral $ast 'actorCSharp';$native=Read-FixedLiteral $initializers[0] 'native'
 $actor=$actor.Replace('public static class WinsmuxDesktopActorProbe {','public static class WinsmuxDesktopNativeActor {').Replace('sealed class TokenFacts {','internal sealed class TokenFacts {').Replace('struct PI {','internal struct PI {')
 $closing=$actor.LastIndexOf('}');Assert-Fixed ($closing -gt 0) 'actor_assembly'
 Add-Type -TypeDefinition ($actor.Substring(0,$closing)+$native+$actor.Substring($closing)) -ErrorAction Stop 2>$null
 $query=[WinsmuxDesktopNativeActor]::Query();$facts=$query['facts']
 Assert-Fixed ($query['existing_profile_hive'] -eq $true -and $query['local_app_data_exists'] -eq $true -and $facts['token_type'] -eq 1 -and $facts['app_container'] -eq 0) 'actor_profile'
 function Write-NewJson([string]$Path,$Value){$bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes(($Value|ConvertTo-Json -Depth 12 -Compress)+[char]10);$file=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}}
 function Read-OwnedJson([string]$Path){return ([WinsmuxDesktopNativeActor]::ReadChild($Path)|ConvertFrom-Json -AsHashtable)}
 if($HeadlessParent){
  Assert-Fixed (-not $DesktopNativeLifecycle -and $facts['elevation'] -eq 1 -and $facts['integrity_rid'] -ge 12288) 'high_bootstrap'
  $phase='build_binding'
  $root=Join-Path $env:RUNNER_TEMP ('winsmux-headless-actor-'+$env:GITHUB_RUN_ID+'.'+$env:GITHUB_RUN_ATTEMPT+'.'+$source)
  [void][WinsmuxDesktopNativeActor]::NativeDirectory($root,$true)
  $inputRoot=Join-Path $root 'input';$evidenceRoot=Join-Path $root 'evidence'
  [void][WinsmuxDesktopNativeActor]::NativeDirectory($inputRoot,$true);[void][WinsmuxDesktopNativeActor]::NativeDirectory($evidenceRoot,$true)
  $buildWitness=[WinsmuxDesktopNativeActor]::NativeFile($BuildManifest)
  $artifacts=[Collections.Generic.List[object]]::new();$finished=0
  foreach($line in [IO.File]::ReadLines($BuildManifest,$utf8)){if([string]::IsNullOrWhiteSpace($line)){continue};$row=$line|ConvertFrom-Json -AsHashtable;if($row.reason -ceq 'compiler-artifact' -and $null -ne $row.executable){$artifacts.Add($row)}elseif($row.reason -ceq 'build-finished'){Assert-Fixed ($row.success -eq $true) 'cargo_failed';$finished++}}
  Assert-Fixed ($finished -eq 1 -and [WinsmuxDesktopNativeActor]::NativeFile($BuildManifest)['sha256'] -ceq $buildWitness['sha256']) 'cargo_terminal'
  $testRows=@($artifacts|Where-Object{$_.target.name -ceq 'workspace_host_e2e' -and 'test' -cin $_.target.kind})
  $cliRows=@($artifacts|Where-Object{$_.target.name -ceq 'winsmux' -and 'bin' -cin $_.target.kind -and -not $_.profile.test})
  Assert-Fixed ($testRows.Count -eq 1 -and $cliRows.Count -eq 1) 'cargo_artifact_identity'
  $testImage=[IO.Path]::GetFullPath([string]$testRows[0].executable);$cliImage=[IO.Path]::GetFullPath([string]$cliRows[0].executable)
  $testWitness=[WinsmuxDesktopNativeActor]::NativeFile($testImage);$cliWitness=[WinsmuxDesktopNativeActor]::NativeFile($cliImage)
  $scriptWitness=[WinsmuxDesktopNativeActor]::NativeFile($PSCommandPath)
  $binding=[ordered]@{schema='winsmux-headless-actor-input/v1';source_commit=$source;expected_sid=$facts['sid_sha256'];expected_session=$facts['session'];script_sha256=$scriptWitness['sha256'];test_executable=$testImage;test_sha256=$testWitness['sha256'];cli_executable=$cliImage;cli_sha256=$cliWitness['sha256'];tests=$tests}
  Write-NewJson (Join-Path $inputRoot 'binding.json') $binding
  $phase='medium_bootstrap'
  $pwsh=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$pwshSha=[WinsmuxDesktopNativeActor]::NativeFile($pwsh)['sha256']
  $outer=[WinsmuxDesktopNativeActor]::StartNative('medium-bootstrap',$pwsh,$pwshSha,$root,$source,$inputRoot,$evidenceRoot,$PSCommandPath)
  $budgetFns=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -cin @('Get-DesktopNativeNsisJourneyObservationSlots','Get-DesktopNativeNsisJourneyBudgetMilliseconds')},$false))
  Assert-Fixed ($budgetFns.Count -eq 2) 'existing_budget';foreach($fn in $budgetFns){. ([scriptblock]::Create($fn.Extent.Text))}
  $outerTerminal=$outer.WaitTerminal((Get-DesktopNativeNsisJourneyBudgetMilliseconds))
  if(-not $outerTerminal){$outer.StopOwnedFailure();$outerTerminal=$true;$result.forced=$true}
  $nativeFacts=$outer.Facts();$medium=$nativeFacts['actor']
  $result.root_terminal=$outerTerminal;$result.root_job_zero=$nativeFacts['active_members'] -eq 0
  $result.same_sid=$medium['sid_sha256'] -ceq $facts['sid_sha256'];$result.same_session=$medium['session'] -eq $facts['session']
  $result.restricted_medium=$medium['elevation'] -eq 0 -and $medium['integrity_rid'] -ge 8192 -and $medium['integrity_rid'] -lt 12288 -and $medium['restricted'] -eq 1
  $result.actor_admitted=$result.same_sid -and $result.same_session -and $result.restricted_medium
  $phase='bounded_child_result'
  $child=Read-OwnedJson (Join-Path $evidenceRoot 'child-result.json')
  Assert-Fixed ($child.schema -ceq 'winsmux-headless-restricted-actor/v1' -and $child.source_commit -ceq $source -and $child.actor_admitted -eq $true -and @($child.tests).Count -eq 2) 'child_binding'
  $childKeys=@('schema','outcome','source_commit','actor_admitted','same_sid','same_session','restricted_medium','tests','root_terminal','root_job_zero','forced','failure','nsis_success_proven','normal_gui_success_proven')
  Assert-Fixed ((@($child.Keys|Sort-Object -CaseSensitive)-join [char]10) -ceq (@($childKeys|Sort-Object -CaseSensitive)-join [char]10)) 'child_result_shape'
  Assert-Fixed ($child.nsis_success_proven -eq $false -and $child.normal_gui_success_proven -eq $false -and $child.same_sid -eq $true -and $child.same_session -eq $true -and $child.restricted_medium -eq $true) 'child_result_scope'
  for($i=0;$i -lt 2;$i++){Assert-HeadlessProjectionShape $child.tests[$i] $tests[$i]}
  $result.tests=@($child.tests)
  $result.outcome=if($result.actor_admitted -and $result.root_terminal -and $result.root_job_zero -and -not $result.forced -and @($result.tests|Where-Object{$_.outcome -cne 'passed'}).Count -eq 0 -and $outer.ExitCode -eq 0){'passed'}else{'observed_failure'}
 }else{
  Assert-Fixed ($DesktopNativeLifecycle -and $DesktopNativeFormat -ceq 'NSIS' -and $Surface -ceq 'Desktop' -and $Version -ceq '0.38.0' -and $ReleaseTag -ceq 'v0.38.0' -and $Repository -ceq 'Sora-bluesky/winsmux' -and $Json) 'fixed_child_arguments'
  $inputRoot=[IO.Path]::GetFullPath($DesktopNativeCandidateDirectory);$evidenceRoot=[IO.Path]::GetFullPath($DesktopNativeBaselineDirectory)
  $binding=Read-OwnedJson (Join-Path $inputRoot 'binding.json')
  Assert-Fixed ($binding.schema -ceq 'winsmux-headless-actor-input/v1' -and $binding.source_commit -ceq $source -and $binding.script_sha256 -ceq [WinsmuxDesktopNativeActor]::NativeFile($PSCommandPath)['sha256'] -and (@($binding.tests)-join [char]10) -ceq ($tests-join [char]10)) 'child_input_binding'
  $result.same_sid=$facts['sid_sha256'] -ceq $binding.expected_sid;$result.same_session=$facts['session'] -eq $binding.expected_session
  $result.restricted_medium=$facts['elevation'] -eq 0 -and $facts['integrity_rid'] -ge 8192 -and $facts['integrity_rid'] -lt 12288 -and $facts['restricted'] -eq 1
  $result.actor_admitted=$result.same_sid -and $result.same_session -and $result.restricted_medium
  Assert-Fixed $result.actor_admitted 'restricted_actor'
  Add-Type -Path (Join-Path $repoRoot 'scripts/DesktopProcessOwner.cs') -ErrorAction Stop 2>$null
  $testImage=[string]$binding.test_executable;$cliImage=[string]$binding.cli_executable
  $phase='headless_cases';$observed=[Collections.Generic.List[object]]::new()
  foreach($test in $tests){
   Assert-Fixed ([WinsmuxDesktopNativeActor]::NativeFile($testImage)['sha256'] -ceq $binding.test_sha256 -and [WinsmuxDesktopNativeActor]::NativeFile($cliImage)['sha256'] -ceq $binding.cli_sha256) 'test_input_changed'
   $owned=$null;$terminal=$false
   try{
    $owned=[Winsmux.DesktopNative.DesktopProcessOwner]::Start($testImage,[string[]]@('--exact',$test,'--test-threads=1','--nocapture'),@{},$false,16384,180000)
    $terminal=$owned.WaitTerminal(180000,500)
    if(-not $terminal){$owned.ForceFailureCleanup(180000,500);$terminal=$owned.HasExited -and $owned.ActiveMembers -eq 0 -and $owned.CaptureCompleted}
    $out=$owned.StdoutTask.GetAwaiter().GetResult();$err=$owned.StderrTask.GetAwaiter().GetResult()
    $projection=ConvertTo-HeadlessFixedProjection -Stdout $out.RetainedBytes -Stderr $err.RetainedBytes -Truncated ($out.Truncated -or $err.Truncated) -Test $test -ExitCode $owned.ExitCode -Terminal $terminal -JobZero ($owned.ActiveMembers -eq 0) -Forced $owned.Forced
    $observed.Add($projection);$result.tests=$observed.ToArray()
    # Raw retained bytes stay in memory and are never written, emitted or uploaded.
    $out=$null;$err=$null
   }finally{
    if($null -ne $owned){if(-not $terminal){$owned.ForceFailureCleanup(180000,500)};if($owned.HasExited -and $owned.ActiveMembers -eq 0 -and $owned.CaptureCompleted){$owned.Dispose()}}
   }
   Assert-Fixed ([WinsmuxDesktopNativeActor]::NativeFile($testImage)['sha256'] -ceq $binding.test_sha256 -and [WinsmuxDesktopNativeActor]::NativeFile($cliImage)['sha256'] -ceq $binding.cli_sha256) 'test_output_changed_inputs'
  }
  $result.tests=$observed.ToArray();$result.outcome=if(@($result.tests|Where-Object{$_.outcome -cne 'passed'}).Count -eq 0){'passed'}else{'observed_failure'}
 }
}catch{$result.failure=$phase;$result.outcome='unobserved'}
finally{
 if($null -ne $outer){try{if(-not $outerTerminal){$outer.StopOwnedFailure();$outerTerminal=$true;$result.forced=$true};$result.root_terminal=$outerTerminal;$result.root_job_zero=$outer.ActiveMembers -eq 0;if($outerTerminal -and $result.root_job_zero){$outer.Dispose()}}catch{$result.failure='root_convergence';$result.outcome='unobserved'}}
}
if(-not $HeadlessParent -and $null -ne $evidenceRoot){try{Write-NewJson (Join-Path $evidenceRoot 'child-result.json') $result}catch{$result.failure='result_preservation';$result.outcome='unobserved'}}
if($HeadlessParent -and $null -ne $evidenceRoot){try{Write-NewJson (Join-Path $evidenceRoot 'headless-result.json') $result}catch{$result.failure='result_preservation';$result.outcome='unobserved'}}
$result|ConvertTo-Json -Depth 12 -Compress
exit $(if($result.outcome -ceq 'passed'){0}else{1})
