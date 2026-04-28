[CmdletBinding()]
param(
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$contract = [ordered]@{
    contract_version = 1
    target_state     = 'PowerShell remains only for bootstrap, local setup, compatibility, contributor security, release, and planning sync until typed replacements exist.'
    runtime_rule     = 'Runtime ownership may move out of PowerShell only after shadow-cutover-gate passes for the affected machine-readable surface.'
    allowed_roles    = @(
        'bootstrap',
        'local_setup',
        'compatibility_launcher',
        'contributor_security',
        'release',
        'planning_sync'
    )
    shrink_order     = @(
        'typed_state_and_projection_contracts',
        'compatibility_launcher_wrappers',
        'shadow_cutover_gate',
        'documentation_update',
        'script_deletion_last'
    )
    gates            = [ordered]@{
        inventory_documented       = $true
        shadow_gate_required       = $true
        delete_without_shadow_gate = $false
        keep_startup_boundaries    = @('bootstrap', 'visible_attach', 'manifest_state', 'watchdog', 'rollback')
    }
    thin_shim_candidates = @(
        'scripts/winsmux.ps1',
        'scripts/start-orchestra.ps1',
        'scripts/sync-project-views.ps1',
        'winsmux-core/psmux-bridge.ps1',
        'winsmux-core/scripts/orchestra-attach-entry.ps1'
    )
    needs_decision = @(
        'scripts/run-tests.ps1',
        'winsmux-core/scripts/orchestra-cleanup.ps1',
        'winsmux-core/scripts/pane-scaler.ps1',
        'release-tooling-powerShell-lifetime',
        'planning-sync-powerShell-lifetime'
    )
    next_actions = @(
        'Run shadow-cutover-gate for any Rust replacement before changing runtime ownership.',
        'Keep public docs and installer paths stable until a replacement path exists.',
        'Use TASK-217e to switch terminal execution targets without deleting compatibility wrappers.'
    )
}

if ($AsJson) {
    $contract | ConvertTo-Json -Depth 16 -Compress | Write-Output
    return
}

Write-Output 'PowerShell de-escalation contract'
Write-Output ('Target: {0}' -f $contract.target_state)
Write-Output ('Runtime rule: {0}' -f $contract.runtime_rule)
Write-Output ('Shadow gate required: {0}' -f $contract.gates.shadow_gate_required)
