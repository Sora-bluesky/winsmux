param([string]$OutputDirectory='', [switch]$SelfTestLeak)
. (Join-Path $PSScriptRoot 'gates.ps1')
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (!$OutputDirectory) { $OutputDirectory = Join-Path $repo ('.evidence/workspace-privacy/'+[guid]::NewGuid().ToString('N')) }
$gateOutput = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($gateOutput)
$gateResults = [Collections.Generic.List[object]]::new()
$cargo = (Get-Command cargo -CommandType Application | Select-Object -First 1).Source
$pwsh = (Get-Process -Id $PID).Path
$savedMarker=$env:WINSMUX_PRIVACY_MARKER; $savedNegative=$env:WINSMUX_PRIVACY_NEGATIVE
Push-Location $repo
try {
    $env:WINSMUX_PRIVACY_MARKER='WMX_SYNTH_ENV'
    if ($SelfTestLeak) { $env:WINSMUX_PRIVACY_NEGATIVE='1' } else { Remove-Item Env:WINSMUX_PRIVACY_NEGATIVE -ErrorAction SilentlyContinue }
    Invoke-RecordedGate -Name markers -File $cargo -Cargo -Arguments @('test','--offline','--manifest-path','tests/workspace-privacy/Cargo.toml','--test','privacy_markers','--','--nocapture','--skip','WMX_SYNTH_ARGV')
    if (!$SelfTestLeak) {
        Invoke-RecordedGate -Name diagnostics-and-authorization -File $cargo -Cargo -Arguments @('test','--offline','-p','winsmux-workspace','--test','diagnostics_e2e','--test','host_authorization')
        Invoke-RecordedGate -Name secret-source -File $pwsh -Arguments @('-NoProfile','-File','scripts/git-guard.ps1','-Mode','full')
        Invoke-RecordedGate -Name public-surface -File $pwsh -Arguments @('-NoProfile','-File','scripts/audit-public-surface.ps1')
    }
    $ok = Complete-Gates -Schema 'winsmux-workspace-privacy-gates/v1' -Mode $(if($SelfTestLeak){'negative_control'}else{'automated'}) -Separate @('native GUI/CLI/MCP marker journeys','T-02 separate-SID','T-09 install/update transport')
} finally {
    $env:WINSMUX_PRIVACY_MARKER=$savedMarker; $env:WINSMUX_PRIVACY_NEGATIVE=$savedNegative
    Pop-Location
}
if (!$ok) { exit 1 }
