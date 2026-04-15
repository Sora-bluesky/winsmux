[CmdletBinding()]
param(
    [string]$ProjectDir = '',
    [string]$SessionName = 'winsmux-orchestra',
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
    $ProjectDir = (Get-Location).Path
}

$ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)
$scriptsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $scriptsRoot 'orchestra-ui-attach.ps1')

function New-OrchestraAttachResult {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][bool]$SessionExists,
        [Parameter(Mandatory = $true)][bool]$RequiresStartup,
        [Parameter(Mandatory = $true)][bool]$Attempted,
        [Parameter(Mandatory = $true)][bool]$Launched,
        [Parameter(Mandatory = $true)][bool]$Attached,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Reason,
        [AllowEmptyString()][string]$Path = '',
        [int]$AttachedClientCount = 0,
        [AllowEmptyString()][string]$AttachSource = 'none',
        [AllowEmptyString()][string]$AttachRequestId = '',
        [AllowEmptyCollection()][string[]]$AttachedClientSnapshot = @(),
        [AllowEmptyString()][string]$UiHostKind = '',
        [AllowEmptyCollection()]$AttachAdapterTrace = @()
    )

    return [ordered]@{
        session_name          = $SessionName
        session_exists        = $SessionExists
        requires_startup      = $RequiresStartup
        attempted             = $Attempted
        launched              = $Launched
        attached              = $Attached
        attached_client_count = $AttachedClientCount
        attach_request_id     = $AttachRequestId
        attached_client_snapshot = @($AttachedClientSnapshot)
        status                = $Status
        reason                = $Reason
        path                  = $Path
        ui_attach_source      = $AttachSource
        ui_host_kind          = $UiHostKind
        attach_adapter_trace  = @($AttachAdapterTrace)
    }
}

$winsmuxPath = Get-Command 'winsmux' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
$result = $null
if ([string]::IsNullOrWhiteSpace($winsmuxPath)) {
    $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $false -RequiresStartup $true -Attempted $false -Launched $false -Attached $false -Status 'winsmux_unresolved' -Reason 'winsmux executable could not be resolved.'
} else {
    & $winsmuxPath 'has-session' '-t' $SessionName 1>$null 2>$null
    $sessionExists = ($LASTEXITCODE -eq 0)
    if (-not $sessionExists) {
        $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $false -RequiresStartup $true -Attempted $false -Launched $false -Attached $false -Status 'session_missing' -Reason "winsmux session '$SessionName' was not found. Run orchestra-start.ps1 first."
    } else {
        $sharedResult = Invoke-OrchestraVisibleAttachRequest -SessionName $SessionName -ProjectDir $ProjectDir -WinsmuxPathForAttach $winsmuxPath
        $result = New-OrchestraAttachResult `
            -SessionName $SessionName `
            -SessionExists $true `
            -RequiresStartup $false `
            -Attempted ([bool]$sharedResult.Attempted) `
            -Launched ([bool]$sharedResult.Launched) `
            -Attached ([bool]$sharedResult.Attached) `
            -Status ([string]$sharedResult.Status) `
            -Reason ([string]$sharedResult.Reason) `
            -Path ([string]$sharedResult.Path) `
            -AttachedClientCount ([int]$sharedResult.AttachedClientCount) `
            -AttachSource ([string]$sharedResult.Source) `
            -AttachRequestId ([string]$sharedResult.attach_request_id) `
            -AttachedClientSnapshot @($sharedResult.attached_client_snapshot) `
            -UiHostKind ([string]$sharedResult.ui_host_kind) `
            -AttachAdapterTrace @($sharedResult.attach_adapter_trace)
    }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 8
} else {
    $result.GetEnumerator() | ForEach-Object {
        '{0}: {1}' -f $_.Key, $_.Value
    }
}

if ($result.status -notin @('attach_confirmed', 'attach_already_present')) {
    exit 1
}
