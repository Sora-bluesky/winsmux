$ErrorActionPreference = 'Stop'

# Workers command module owns workers workspace argument and output handling.

function Read-WinsmuxWorkersWorkspaceOptions {
    param(
        [Parameter(Mandatory = $true)][string]$Usage,
        [AllowNull()][string[]]$CommandRest
    )

    $projectDir = (Get-Location).Path
    $asJson = $false
    $workspaceAction = ''
    $targetValue = ''
    $runId = ''
    $profile = 'isolated-enterprise'
    $includes = [System.Collections.Generic.List[string]]::new()
    $items = @($CommandRest)

    if ($items.Count -ge 1) {
        $workspaceAction = [string]$items[0]
    }
    if ($items.Count -ge 2) {
        $targetValue = [string]$items[1]
    }
    if ([string]::IsNullOrWhiteSpace($workspaceAction) -or [string]::IsNullOrWhiteSpace($targetValue)) {
        Stop-WithError $Usage
    }

    for ($index = 2; $index -lt $items.Count; $index++) {
        $token = [string]$items[$index]
        switch ($token) {
            '--json' { $asJson = $true }
            '--project-dir' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $projectDir = [string]$items[$index + 1]
                $index++
            }
            '--run-id' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $runId = [string]$items[$index + 1]
                $index++
            }
            '--profile' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $profile = [string]$items[$index + 1]
                $index++
            }
            '--include' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $includes.Add([string]$items[$index + 1]) | Out-Null
                $index++
            }
            default {
                Stop-WithError $Usage
            }
        }
    }

    if ($workspaceAction -notin @('prepare', 'cleanup')) {
        Stop-WithError $Usage
    }
    if (Get-Command Test-BridgeExecutionProfileKind -ErrorAction SilentlyContinue) {
        if (-not (Test-BridgeExecutionProfileKind -Value $profile)) {
            Stop-WithError "unsupported execution profile for isolated workspace: $profile"
        }
    }
    if (-not [string]::Equals($profile, 'isolated-enterprise', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError 'isolated workspace requires execution profile isolated-enterprise'
    }
    if ($workspaceAction -eq 'prepare' -and $includes.Count -lt 1) {
        Stop-WithError 'isolated workspace prepare requires at least one --include path'
    }
    if ($workspaceAction -eq 'cleanup' -and [string]::IsNullOrWhiteSpace($runId)) {
        Stop-WithError 'isolated workspace cleanup requires --run-id'
    }

    return [PSCustomObject]@{
        ProjectDir = $projectDir
        Json       = $asJson
        Action     = $workspaceAction
        Target     = $targetValue
        RunId      = $runId
        Profile    = $profile.Trim().ToLowerInvariant()
        Includes   = @($includes)
    }
}

function Invoke-WinsmuxWorkersWorkspacePrepare {
    param([Parameter(Mandatory = $true)]$Options)

    $slot = Get-WorkersSingleSlotContext -ProjectDir $Options.ProjectDir -Target $Options.Target
    $slotProfile = [string]$slot.SlotConfig.ExecutionProfile
    if (-not [string]::Equals($slotProfile, [string]$Options.Profile, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "worker slot $($slot.Row.SlotId) uses execution profile '$slotProfile', not isolated-enterprise"
    }

    $runId = Assert-WorkersRunId -RunId ([string]$Options.RunId)
    if ([string]::IsNullOrWhiteSpace($runId)) {
        $runId = New-WorkersRunId -SlotId ([string]$slot.Row.SlotId)
    }

    $runDir = Get-WorkersIsolatedWorkspaceRunDirectory -ProjectDir $Options.ProjectDir -SlotId ([string]$slot.Row.SlotId) -RunId $runId
    Assert-WorkersIsolatedWorkspaceCleanupTarget -ProjectDir $Options.ProjectDir -RunDir $runDir
    if (Test-Path -LiteralPath $runDir) {
        Stop-WithError "isolated workspace run already exists: $runId"
    }

    $sources = [System.Collections.Generic.List[object]]::new()
    foreach ($includePath in @($Options.Includes)) {
        $source = Resolve-WorkersIsolatedProjectionPath -ProjectDir $Options.ProjectDir -Path ([string]$includePath)
        if ([bool]$source.IsDirectory) {
            Assert-WorkersDirectoryContainsOnlyIsolatedSafeFiles -ProjectDir $Options.ProjectDir -SourceInfo $source
        }
        $sources.Add($source) | Out-Null
    }

    $workspaceDir = Join-Path $runDir 'workspace'
    $downloadsDir = Join-Path $runDir 'downloads'
    $artifactsDir = Join-Path $runDir 'artifacts'
    New-Item -ItemType Directory -Path $workspaceDir -Force | Out-Null
    New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

    $projections = [System.Collections.Generic.List[object]]::new()
    foreach ($source in @($sources)) {
        $projections.Add((Copy-WorkersIsolatedProjection -ProjectDir $Options.ProjectDir -WorkspaceDir $workspaceDir -SourceInfo $source)) | Out-Null
    }

    $manifestPath = Join-Path $runDir 'workspace.json'
    $runReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $runDir
    $workspaceReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $workspaceDir
    $downloadsReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $downloadsDir
    $artifactsReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $artifactsDir
    $manifestReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $manifestPath

    $payload = [ordered]@{
        version       = 1
        project_ref   = '.'
        generated_at  = (Get-Date).ToUniversalTime().ToString('o')
        command       = 'workers.workspace.prepare'
        status        = 'prepared'
        slot          = [string]$slot.Row.Slot
        slot_id       = [string]$slot.Row.SlotId
        run_id        = $runId
        execution_profile = 'isolated-enterprise'
        workspace_lifecycle = 'disposable'
        policy        = [ordered]@{
            direct_project_write = 'prohibited'
            projection           = 'explicit-includes-only'
            cleanup              = 'delete-isolated-run-directory'
            rejects              = @('path_traversal', 'absolute_escape', 'reparse_point', 'windows_reserved_name', 'excluded_or_secret_like_path')
        }
        locations     = [ordered]@{
            project_root = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName 'project root' -Backend 'local-windows' -AccessMethod 'project_root' -Reference '.' -Provenance 'workers.workspace.project_root'
            run_root     = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $runReference -Backend 'local-windows' -AccessMethod 'isolated_run_root' -Reference $runReference -Provenance 'workers.workspace.run_root'
            workspace    = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $workspaceReference -Backend 'local-windows' -AccessMethod 'isolated_workspace' -Reference $workspaceReference -Provenance 'workers.workspace.workspace'
            downloads    = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $downloadsReference -Backend 'local-windows' -AccessMethod 'isolated_downloads' -Reference $downloadsReference -Provenance 'workers.workspace.downloads'
            artifacts    = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $artifactsReference -Backend 'local-windows' -AccessMethod 'isolated_artifacts' -Reference $artifactsReference -Provenance 'workers.workspace.artifacts'
            manifest     = New-WinsmuxLocationIdentity -Kind 'local_file' -DisplayName 'workspace.json' -Backend 'local-windows' -AccessMethod 'artifact_ref' -Reference $manifestReference -Provenance 'workers.workspace.manifest'
        }
        projections   = @($projections)
        exit_code     = 0
    }

    Write-WorkersJsonArtifact -Path $manifestPath -Data $payload | Out-Null
    if ($null -ne $slot.Entry) {
        Set-WorkersManifestLifecycleCommand -Entry $slot.Entry -CommandName 'workers.workspace.prepare' -ExtraProperties ([ordered]@{
            last_workspace_run_id = $runId
            last_workspace_profile = 'isolated-enterprise'
            last_workspace_status = 'prepared'
            last_workspace_lifecycle = 'disposable'
            last_workspace_root = $workspaceReference
            last_workspace_manifest = $manifestReference
            last_secret_run_id = ''
            last_secret_profile = ''
            last_secret_status = ''
            last_secret_binding = ''
            last_secret_projection_count = ''
            last_secret_manifest = ''
            last_broker_run_id = ''
            last_broker_profile = ''
            last_broker_status = ''
            last_broker_node_id = ''
            last_broker_endpoint = ''
            last_broker_manifest = ''
            last_broker_token_status = ''
            last_broker_token_health = ''
            last_broker_token_expires_at = ''
            last_broker_token_manifest = ''
            last_policy_run_id = ''
            last_policy_profile = ''
            last_policy_status = ''
            last_policy_health = ''
            last_policy_reason = ''
            last_policy_network = ''
            last_policy_write = ''
            last_policy_provider = ''
            last_policy_mandatory_checks = ''
            last_policy_required_evidence = ''
            last_policy_manifest = ''
        })
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$Options.Json) -Text "prepared $runId"
}

function Invoke-WinsmuxWorkersWorkspaceCleanup {
    param([Parameter(Mandatory = $true)]$Options)

    $slot = Get-WorkersSingleSlotContext -ProjectDir $Options.ProjectDir -Target $Options.Target
    $runId = Assert-WorkersRunId -RunId ([string]$Options.RunId)
    $runDir = Get-WorkersIsolatedWorkspaceRunDirectory -ProjectDir $Options.ProjectDir -SlotId ([string]$slot.Row.SlotId) -RunId $runId
    Assert-WorkersIsolatedWorkspaceCleanupTarget -ProjectDir $Options.ProjectDir -RunDir $runDir
    $existed = Test-Path -LiteralPath $runDir
    if ($existed) {
        Remove-WorkersIsolatedWorkspaceRunDirectory -ProjectDir $Options.ProjectDir -RunDir $runDir
    }

    $runReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $runDir
    $payload = [ordered]@{
        version       = 1
        project_ref   = '.'
        generated_at  = (Get-Date).ToUniversalTime().ToString('o')
        command       = 'workers.workspace.cleanup'
        status        = if ($existed) { 'cleaned' } else { 'not_found' }
        slot          = [string]$slot.Row.Slot
        slot_id       = [string]$slot.Row.SlotId
        run_id        = $runId
        execution_profile = 'isolated-enterprise'
        workspace_lifecycle = 'disposable'
        locations     = [ordered]@{
            run_root = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $runReference -Backend 'local-windows' -AccessMethod 'isolated_run_root' -Reference $runReference -Provenance 'workers.workspace.cleanup'
        }
        existed       = [bool]$existed
        exit_code     = 0
    }
    if ($null -ne $slot.Entry) {
        $activeWorkspaceRunId = [string](Get-SendConfigValue -InputObject $slot.Entry -Name 'LastWorkspaceRunId' -Default '')
        $cleanupIsActiveWorkspace = [string]::Equals($activeWorkspaceRunId, $runId, [System.StringComparison]::Ordinal)
    }
    if ($null -ne $slot.Entry -and $cleanupIsActiveWorkspace) {
        Set-WorkersManifestLifecycleCommand -Entry $slot.Entry -CommandName 'workers.workspace.cleanup' -ExtraProperties ([ordered]@{
            last_workspace_run_id = $runId
            last_workspace_profile = 'isolated-enterprise'
            last_workspace_status = [string]$payload['status']
            last_workspace_lifecycle = 'disposable'
            last_workspace_root = ''
            last_workspace_manifest = ''
            last_secret_run_id = ''
            last_secret_profile = ''
            last_secret_status = ''
            last_secret_binding = ''
            last_secret_projection_count = ''
            last_secret_manifest = ''
            last_broker_run_id = ''
            last_broker_profile = ''
            last_broker_status = ''
            last_broker_node_id = ''
            last_broker_endpoint = ''
            last_broker_manifest = ''
            last_broker_token_status = ''
            last_broker_token_health = ''
            last_broker_token_expires_at = ''
            last_broker_token_manifest = ''
            last_policy_run_id = ''
            last_policy_profile = ''
            last_policy_status = ''
            last_policy_health = ''
            last_policy_reason = ''
            last_policy_network = ''
            last_policy_write = ''
            last_policy_provider = ''
            last_policy_mandatory_checks = ''
            last_policy_required_evidence = ''
            last_policy_manifest = ''
        })
    } elseif ($null -ne $slot.Entry) {
        Set-WorkersManifestLifecycleCommand -Entry $slot.Entry -CommandName 'workers.workspace.cleanup'
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$Options.Json) -Text "$($payload['status']) $runId"
}

function Invoke-WinsmuxWorkersWorkspaceCommand {
    param([AllowNull()][string[]]$CommandRest)

    $usage = "usage: winsmux workers workspace <prepare|cleanup> <slot> [--include <path>] [--run-id <id>] [--profile isolated-enterprise] [--json] [--project-dir <path>]"
    $options = Read-WinsmuxWorkersWorkspaceOptions -Usage $usage -CommandRest $CommandRest
    switch ([string]$options.Action) {
        'prepare' { Invoke-WinsmuxWorkersWorkspacePrepare -Options $options }
        'cleanup' { Invoke-WinsmuxWorkersWorkspaceCleanup -Options $options }
        default { Stop-WithError $usage }
    }
}
