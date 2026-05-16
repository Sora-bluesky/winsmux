param(
    [Parameter(Position=0)][string]$Command,
    [Parameter(Position=1)][string]$Target,
    [Parameter(Position=2, ValueFromRemainingArguments=$true)][string[]]$Rest
)

$script:WinsmuxRawGlobalArgs = @()
if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_BRIDGE_NAMESPACE_L)) {
    $script:WinsmuxRawGlobalArgs += @('-L', $env:WINSMUX_BRIDGE_NAMESPACE_L)
}
if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_BRIDGE_SOCKET_S)) {
    $script:WinsmuxRawGlobalArgs += @('-S', $env:WINSMUX_BRIDGE_SOCKET_S)
}
$script:WinsmuxRawCommand = 'winsmux'
if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_RAW_EXE)) {
    $script:WinsmuxRawCommand = $env:WINSMUX_RAW_EXE
}

# --- Config ---
$VERSION = "0.35.2"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$BridgeScriptPath = $PSCommandPath

$ReadMarkDir    = Join-Path $env:TEMP "winsmux\read_marks"
$WatermarkDir   = Join-Path $env:TEMP "winsmux\watermarks"
$LockDir        = Join-Path $env:TEMP "winsmux\locks"
$FocusPolicyFile = Join-Path $env:TEMP "winsmux\focus-policy-stack.json"
$LabelsFile     = Join-Path $env:APPDATA "winsmux\labels.json"
$BridgeSettingsScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\settings.ps1'))
$PaneControlScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\pane-control.ps1'))
$PaneStatusScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\pane-status.ps1'))
$ColabBackendScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\colab-backend.ps1'))
$RoleGateScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\role-gate.ps1'))
$ClmSafeIoScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\clm-safe-io.ps1'))
$PaneEnvScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\pane-env.ps1'))
$PublicFirstRunScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\public-first-run.ps1'))
$ConflictPreflightScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\conflict-preflight.ps1'))

if (Test-Path $BridgeSettingsScript -PathType Leaf) {
    . $BridgeSettingsScript
}

if (Test-Path $PaneControlScript -PathType Leaf) {
    . $PaneControlScript
}

if (Test-Path $PaneStatusScript -PathType Leaf) {
    . $PaneStatusScript
}

if (Test-Path $ColabBackendScript -PathType Leaf) {
    . $ColabBackendScript
}

if (Test-Path $RoleGateScript -PathType Leaf) {
    . $RoleGateScript
}

if (Test-Path $ClmSafeIoScript -PathType Leaf) {
    . $ClmSafeIoScript
}

if (Test-Path $PaneEnvScript -PathType Leaf) {
    . $PaneEnvScript
}

if (Test-Path $PublicFirstRunScript -PathType Leaf) {
    . $PublicFirstRunScript
}

if (Test-Path $ConflictPreflightScript -PathType Leaf) {
    . $ConflictPreflightScript
}

# --- Windows Credential Manager P/Invoke ---
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class WinCred {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool CredFree(IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredEnumerate(string filter, uint flags, out int count, out IntPtr credentials);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public const uint CRED_TYPE_GENERIC = 1;
    public const uint CRED_PERSIST_LOCAL_MACHINE = 2;
}
'@ -ErrorAction SilentlyContinue

# --- Helper: Stop-WithError ---
function Stop-WithError {
    param([string]$Message)
    Write-Error $Message
    exit 1
}

function Get-SafeLastExitCode {
    if (Test-Path Variable:\LASTEXITCODE) {
        return $LASTEXITCODE
    }

    return $null
}

function Invoke-WinsmuxRaw {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $rawArguments = @()
    if ($script:WinsmuxRawGlobalArgs) {
        $rawArguments += $script:WinsmuxRawGlobalArgs
    }
    $rawArguments += @($Arguments)
    return & $script:WinsmuxRawCommand @rawArguments
}

function Resolve-TerminalBackend {
    $rawBackend = [string]$env:WINSMUX_BACKEND
    if ([string]::IsNullOrWhiteSpace($rawBackend)) {
        return 'cli'
    }

    switch ($rawBackend.Trim().ToLowerInvariant()) {
        { $_ -in @('cli', 'winsmux') } { return 'cli' }
        { $_ -in @('tauri', 'desktop') } { return 'tauri' }
        default {
            Stop-WithError "WINSMUX_BACKEND must be cli or tauri, got '$rawBackend'"
        }
    }
}

function New-TerminalJsonRpcPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)]$Params
    )

    return ([ordered]@{
        jsonrpc = '2.0'
        id      = "terminal-$([guid]::NewGuid().ToString('N'))"
        method  = $Method
        params   = $Params
    } | ConvertTo-Json -Depth 100 -Compress)
}

function Invoke-TerminalJsonRpc {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)]$Params
    )

    $payload = New-TerminalJsonRpcPayload -Method $Method -Params $Params
    $responseText = Invoke-ControlRpcPipeExchange -Payload $payload
    try {
        $response = $responseText | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    } catch {
        Stop-WithError "terminal Tauri request $Method returned invalid JSON: $($_.Exception.Message)"
    }

    $propertyNames = @($response.PSObject.Properties.Name)
    if ($propertyNames -contains 'error') {
        $message = [string]$response.error.message
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = 'unknown error'
        }
        Stop-WithError "terminal Tauri request $Method failed: $message"
    }

    if ($propertyNames -contains 'result') {
        return $response.result
    }

    return $null
}

function Invoke-TerminalCapture {
    param([Parameter(Mandatory = $true)][string]$PaneId, [int]$Lines = 50)

    if ((Resolve-TerminalBackend) -eq 'tauri') {
        $result = Invoke-TerminalJsonRpc -Method 'pty.capture' -Params ([ordered]@{
            paneId = $PaneId
            lines  = $Lines
        })
        if ($null -eq $result) {
            return ''
        }
        return [string]$result.output
    }

    $output = Invoke-WinsmuxRaw -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', "-$Lines")
    return ($output | Out-String).TrimEnd()
}

function Invoke-TerminalWrite {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    if ((Resolve-TerminalBackend) -eq 'tauri') {
        $null = Invoke-TerminalJsonRpc -Method 'pty.write' -Params ([ordered]@{
            paneId = $Target
            data   = $Text
        })
        return [ordered]@{
            ExitCode = 0
            Output   = ''
            Target   = $Target
        }
    }

    $output = Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $Target, '-l', '--', $Text) 2>&1
    return [ordered]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String).Trim()
        Target   = $Target
    }
}

function Write-ClmSafeTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Content = '',
        [switch]$Append
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $escapedPath = $Path -replace '"', '""'
    if ([string]::IsNullOrEmpty($Content)) {
        if ($Append) {
            return
        }

        $writeCommand = 'type nul > "{0}"' -f $escapedPath
        cmd /d /c $writeCommand | Out-Null
    } else {
        $redirect = if ($Append) { '>>' } else { '>' }
        $writeCommand = 'more {0} "{1}"' -f $redirect, $escapedPath
        $Content | cmd /d /c $writeCommand | Out-Null
    }

    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        Stop-WithError "failed to write file via cmd.exe: $Path"
    }
}

# --- Helper: Dispatch prompt paths ---
function Get-DispatchPromptDirectory {
    param([string]$ProjectDir = (Get-Location).Path)

    return Join-Path $ProjectDir '.winsmux\dispatch-prompts'
}

function ConvertTo-TaskPromptSlug {
    param([AllowEmptyString()][string]$TaskSlug)

    if ([string]::IsNullOrWhiteSpace($TaskSlug)) {
        throw 'task slug is required'
    }

    $normalized = $TaskSlug.Trim().ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '[^a-z0-9._-]+', '-')
    $normalized = [regex]::Replace($normalized, '-{2,}', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "task slug '$TaskSlug' does not contain any supported characters"
    }

    return $normalized
}

function Get-TaskPromptPath {
    param(
        [Parameter(Mandatory = $true)][string]$TaskSlug,
        [string]$ProjectDir = (Get-Location).Path
    )

    $normalized = ConvertTo-TaskPromptSlug -TaskSlug $TaskSlug
    return Join-Path (Join-Path $ProjectDir '.winsmux') ("task-{0}.md" -f $normalized)
}

function New-DispatchPromptFile {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [string]$ProjectDir = (Get-Location).Path,
        [string]$Prefix = 'dispatch-prompt'
    )

    $promptDir = Get-DispatchPromptDirectory -ProjectDir $ProjectDir
    if (-not (Test-Path $promptDir)) {
        New-Item -ItemType Directory -Path $promptDir -Force | Out-Null
    }

    $fileName = '{0}-{1}.txt' -f $Prefix, ([guid]::NewGuid().ToString('N'))
    $path = Join-Path $promptDir $fileName
    Write-ClmSafeTextFile -Path $path -Content $Content
    return $path
}

function New-TaskPromptFile {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$TaskSlug,
        [string]$ProjectDir = (Get-Location).Path
    )

    $path = Get-TaskPromptPath -TaskSlug $TaskSlug -ProjectDir $ProjectDir
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $tempPath = '{0}.tmp' -f $path
    Write-ClmSafeTextFile -Path $tempPath -Content $Content
    Move-Item -LiteralPath $tempPath -Destination $path -Force
    return $path
}

function Get-DispatchPromptReference {
    param(
        [Parameter(Mandatory = $true)][string]$PromptPath,
        [string]$ProjectDir = (Get-Location).Path
    )

    $promptRef = $PromptPath
    try {
        $relativePromptPath = [System.IO.Path]::GetRelativePath($ProjectDir, $PromptPath)
        if (-not [string]::IsNullOrWhiteSpace($relativePromptPath) -and -not $relativePromptPath.StartsWith('..')) {
            $promptRef = $relativePromptPath.Replace('\', '/')
        }
    } catch {
        $promptRef = $PromptPath
    }

    return $promptRef
}

function ConvertTo-WinsmuxArtifactData {
    param([AllowNull()]$Data)

    if ($null -eq $Data) {
        return [ordered]@{}
    }

    if ($Data -is [System.Collections.IDictionary]) {
        $clone = [ordered]@{}
        foreach ($entry in $Data.GetEnumerator()) {
            $clone[[string]$entry.Key] = $entry.Value
        }
        return $clone
    }

    if ($null -ne $Data.PSObject) {
        $clone = [ordered]@{}
        foreach ($property in $Data.PSObject.Properties) {
            $clone[$property.Name] = $property.Value
        }
        return $clone
    }

    return [ordered]@{ value = $Data }
}

function Test-WinsmuxArtifactHasCorrelation {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Data)

    $runId = if ($Data.Contains('run_id')) { [string]$Data['run_id'] } else { '' }
    $taskId = if ($Data.Contains('task_id')) { [string]$Data['task_id'] } else { '' }
    $paneId = if ($Data.Contains('pane_id')) { [string]$Data['pane_id'] } else { '' }
    $slot = if ($Data.Contains('slot')) { [string]$Data['slot'] } else { '' }

    if (-not [string]::IsNullOrWhiteSpace($runId)) {
        return $true
    }

    return (
        -not [string]::IsNullOrWhiteSpace($taskId) -and
        (
            -not [string]::IsNullOrWhiteSpace($paneId) -or
            -not [string]::IsNullOrWhiteSpace($slot)
        )
    )
}

function Get-ObservationPackDirectory {
    param([string]$ProjectDir = (Get-Location).Path)

    return Join-Path $ProjectDir '.winsmux\observation-packs'
}

function Get-ConsultationDirectory {
    param([string]$ProjectDir = (Get-Location).Path)

    return Join-Path $ProjectDir '.winsmux\consultations'
}

function Get-PlaybookCandidateDirectory {
    param([string]$ProjectDir = (Get-Location).Path)

    return Join-Path $ProjectDir '.winsmux\playbook-candidates'
}

function Get-ReviewPackDirectory {
    param([string]$ProjectDir = (Get-Location).Path)

    return Join-Path $ProjectDir '.winsmux\review-packs'
}

function Get-WinsmuxArtifactReference {
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactPath,
        [string]$ProjectDir = (Get-Location).Path
    )

    $artifactRef = $ArtifactPath
    try {
        $relativeArtifactPath = [System.IO.Path]::GetRelativePath($ProjectDir, $ArtifactPath)
        if (-not [string]::IsNullOrWhiteSpace($relativeArtifactPath) -and -not $relativeArtifactPath.StartsWith('..')) {
            $artifactRef = $relativeArtifactPath.Replace('\', '/')
        }
    } catch {
    }

    return $artifactRef
}

function New-WinsmuxLocationIdentity {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('local_file', 'local_directory', 'remote_artifact', 'pane_log', 'source_ref')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Backend,
        [Parameter(Mandatory = $true)][string]$AccessMethod,
        [string]$Reference = '',
        [string]$LocalPath = '',
        [string]$RemotePath = '',
        [string]$Provenance = ''
    )

    $identity = [ordered]@{
        kind          = $Kind
        display_name  = $DisplayName
        backend       = $Backend
        access_method = $AccessMethod
        reference     = $Reference
        local_path    = ''
        remote_path   = ''
        provenance    = $Provenance
    }

    if ($Kind -in @('local_file', 'local_directory')) {
        $identity.local_path = $LocalPath
    } elseif (-not [string]::IsNullOrWhiteSpace($LocalPath)) {
        throw "local path is not available for $Kind locations"
    }

    if ($Kind -eq 'remote_artifact') {
        $identity.remote_path = $RemotePath
    } elseif (-not [string]::IsNullOrWhiteSpace($RemotePath)) {
        throw "remote path is only available for remote_artifact locations"
    }

    return $identity
}

function Resolve-WinsmuxLocationIdentityLocalPath {
    param([Parameter(Mandatory = $true)]$Location)

    $kind = [string](Get-SendConfigValue -InputObject $Location -Name 'kind' -Default '')
    if ($kind -notin @('local_file', 'local_directory')) {
        throw "local path is not available for $kind locations"
    }

    return [string](Get-SendConfigValue -InputObject $Location -Name 'local_path' -Default '')
}

function Write-WinsmuxArtifactFile {
    param(
        [Parameter(Mandatory = $true)][string]$DirectoryPath,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][AllowNull()]$Data,
        [string]$ProjectDir = (Get-Location).Path
    )

    if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
        New-Item -ItemType Directory -Path $DirectoryPath -Force | Out-Null
    }

    $fileName = '{0}-{1}.json' -f $Prefix, ([guid]::NewGuid().ToString('N'))
    $path = Join-Path $DirectoryPath $fileName
    $tempPath = '{0}.tmp' -f $path
    $content = ($Data | ConvertTo-Json -Depth 12)

    Write-ClmSafeTextFile -Path $tempPath -Content $content
    Move-Item -LiteralPath $tempPath -Destination $path -Force

    return [ordered]@{
        path      = $path
        reference = Get-WinsmuxArtifactReference -ArtifactPath $path -ProjectDir $ProjectDir
    }
}

function New-ObservationPackFile {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$ObservationPack,
        [string]$ProjectDir = (Get-Location).Path
    )

    $packet = ConvertTo-WinsmuxArtifactData -Data $ObservationPack
    if (-not (Test-WinsmuxArtifactHasCorrelation -Data $packet)) {
        throw 'Observation pack requires run_id or task_id with pane_id/slot.'
    }

    if (-not $packet.Contains('packet_type')) {
        $packet['packet_type'] = 'observation_pack'
    }
    if (-not $packet.Contains('generated_at')) {
        $packet['generated_at'] = (Get-Date).ToString('o')
    }

    return Write-WinsmuxArtifactFile -DirectoryPath (Get-ObservationPackDirectory -ProjectDir $ProjectDir) -Prefix 'observation-pack' -Data $packet -ProjectDir $ProjectDir
}

function New-ConsultationPacketFile {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$ConsultationPacket,
        [string]$ProjectDir = (Get-Location).Path
    )

    $packet = ConvertTo-WinsmuxArtifactData -Data $ConsultationPacket
    if (-not (Test-WinsmuxArtifactHasCorrelation -Data $packet)) {
        throw 'Consultation packet requires run_id or task_id with pane_id/slot.'
    }

    $kind = if ($packet.Contains('kind')) { [string]$packet['kind'] } else { '' }
    if ($kind -notin @('consult_request', 'consult_result', 'consult_error')) {
        throw "Unsupported consultation packet kind: $kind"
    }

    if ($packet.Contains('mode')) {
        $mode = [string]$packet['mode']
        if (-not [string]::IsNullOrWhiteSpace($mode) -and $mode -notin @('early', 'stuck', 'reconcile', 'final')) {
            throw "Unsupported consultation packet mode: $mode"
        }
    }

    if (-not $packet.Contains('packet_type')) {
        $packet['packet_type'] = 'consultation_packet'
    }
    if (-not $packet.Contains('generated_at')) {
        $packet['generated_at'] = (Get-Date).ToString('o')
    }

    $prefix = switch ($kind) {
        'consult_request' { 'consult-request' }
        'consult_result' { 'consult-result' }
        'consult_error' { 'consult-error' }
        default { 'consultation' }
    }

    return Write-WinsmuxArtifactFile -DirectoryPath (Get-ConsultationDirectory -ProjectDir $ProjectDir) -Prefix $prefix -Data $packet -ProjectDir $ProjectDir
}

function New-PlaybookCandidateFile {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$PlaybookCandidate,
        [string]$ProjectDir = (Get-Location).Path
    )

    $packet = ConvertTo-WinsmuxArtifactData -Data $PlaybookCandidate
    if (-not (Test-WinsmuxArtifactHasCorrelation -Data $packet)) {
        throw 'Playbook candidate requires run_id or task_id with pane_id/slot.'
    }

    if (-not $packet.Contains('packet_type')) {
        $packet['packet_type'] = 'playbook_candidate'
    }
    if (-not $packet.Contains('generated_at')) {
        $packet['generated_at'] = (Get-Date).ToString('o')
    }
    if (-not $packet.Contains('kind')) {
        $packet['kind'] = 'playbook'
    }

    return Write-WinsmuxArtifactFile -DirectoryPath (Get-PlaybookCandidateDirectory -ProjectDir $ProjectDir) -Prefix 'playbook-candidate' -Data $packet -ProjectDir $ProjectDir
}

function New-ReviewPackFile {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$ReviewPack,
        [string]$ProjectDir = (Get-Location).Path
    )

    $packet = ConvertTo-WinsmuxArtifactData -Data $ReviewPack
    if (-not (Test-WinsmuxArtifactHasCorrelation -Data $packet)) {
        throw 'Review pack requires run_id or task_id with pane_id/slot.'
    }

    if (-not $packet.Contains('packet_type')) {
        $packet['packet_type'] = 'review_pack'
    }
    if (-not $packet.Contains('schema_version')) {
        $packet['schema_version'] = 1
    }
    if (-not $packet.Contains('generated_at')) {
        $packet['generated_at'] = (Get-Date).ToString('o')
    }

    return Write-WinsmuxArtifactFile -DirectoryPath (Get-ReviewPackDirectory -ProjectDir $ProjectDir) -Prefix 'review-pack' -Data $packet -ProjectDir $ProjectDir
}

function Read-WinsmuxArtifactJson {
    param(
        [AllowEmptyString()][string]$Reference,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$ExpectedDirectoryPath,
        [string]$ExpectedRunId = ''
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        return $null
    }

    $path = $Reference
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $ProjectDir ($Reference.Replace('/', '\'))
    }

    $fullPath = [System.IO.Path]::GetFullPath($path)
    $expectedDirectoryFullPath = [System.IO.Path]::GetFullPath($ExpectedDirectoryPath)

    if (-not $fullPath.StartsWith($expectedDirectoryFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return $null
    }

    try {
        $content = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
        $parsed = $content | ConvertFrom-Json -AsHashtable -Depth 12
    } catch {
        return $null
    }

    if (
        -not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and
        $parsed.Contains('run_id') -and
        -not [string]::IsNullOrWhiteSpace([string]$parsed['run_id']) -and
        [string]$parsed['run_id'] -ne $ExpectedRunId
    ) {
        return $null
    }

    $orderedParsed = [ordered]@{}
    foreach ($entry in $parsed.GetEnumerator()) {
        $orderedParsed[[string]$entry.Key] = $entry.Value
    }

    return $orderedParsed
}

function Write-BridgeEventRecord {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][AllowNull()]$EventRecord
    )

    $eventsPath = Get-BridgeEventsPath -ProjectDir $ProjectDir
    $recordLine = ($EventRecord | ConvertTo-Json -Compress -Depth 12)
    Write-ClmSafeTextFile -Path $eventsPath -Content $recordLine -Append
    return $eventsPath
}

function New-SendDispatchPointerText {
    param(
        [Parameter(Mandatory = $true)][string]$PromptPath,
        [string]$ProjectDir = (Get-Location).Path
    )

    $promptRef = Get-DispatchPromptReference -PromptPath $PromptPath -ProjectDir $ProjectDir
    return "Read the full prompt from '$promptRef' and follow it exactly. This pointer was sent because the original prompt exceeded the send buffer."
}

function Get-SupportedPromptTransportValues {
    return @('argv', 'file', 'stdin')
}

function Resolve-SupportedPromptTransport {
    param([AllowEmptyString()][string]$PromptTransport = 'argv')

    $resolved = if ([string]::IsNullOrWhiteSpace($PromptTransport)) {
        'argv'
    } else {
        $PromptTransport.Trim().ToLowerInvariant()
    }

    $supportedValues = @(Get-SupportedPromptTransportValues)
    if ($resolved -notin $supportedValues) {
        $supportedText = $supportedValues -join ', '
        throw "Unsupported prompt_transport setting: $PromptTransport. Supported values: $supportedText."
    }

    return $resolved
}

function Get-BridgeSecurityPolicyRuleList {
    param(
        [AllowNull()]$SecurityPolicy,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if ($null -eq $SecurityPolicy) {
        return @()
    }

    if ($SecurityPolicy -is [System.Collections.IDictionary] -and $SecurityPolicy.Contains($Key)) {
        return @($SecurityPolicy[$Key] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }

    if ($null -ne $SecurityPolicy.PSObject -and $SecurityPolicy.PSObject.Properties.Name -contains $Key) {
        return @($SecurityPolicy.$Key | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }

    return @()
}

function Find-SendSecurityPolicyViolation {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [AllowNull()]$SecurityPolicy
    )

    if ($null -eq $SecurityPolicy) {
        return $null
    }

    $mode = ''
    if ($SecurityPolicy -is [System.Collections.IDictionary] -and $SecurityPolicy.Contains('mode')) {
        $mode = [string]$SecurityPolicy['mode']
    } elseif ($null -ne $SecurityPolicy.PSObject -and $SecurityPolicy.PSObject.Properties.Name -contains 'mode') {
        $mode = [string]$SecurityPolicy.mode
    }
    $mode = $mode.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($mode)) {
        $mode = 'blocklist'
    }

    $allowPatterns = @(Get-BridgeSecurityPolicyRuleList -SecurityPolicy $SecurityPolicy -Key 'allow_patterns')
    $blockPatterns = @(Get-BridgeSecurityPolicyRuleList -SecurityPolicy $SecurityPolicy -Key 'block_patterns')

    foreach ($pattern in $blockPatterns) {
        if ($Text -match $pattern) {
            return [ordered]@{
                verdict = 'BLOCK'
                reason = "send matched blocked security policy pattern '$pattern'"
                pattern = $pattern
                mode = $mode
                allow = @($allowPatterns)
                block = @($blockPatterns)
                next_action = 'revise_request_or_override'
            }
        }
    }

    if ($mode -eq 'allowlist' -and $allowPatterns.Count -gt 0) {
        foreach ($pattern in $allowPatterns) {
            if ($Text -match $pattern) {
                return $null
            }
        }

        return [ordered]@{
            verdict = 'BLOCK'
            reason = 'send did not match any allow_patterns entry required by allowlist security policy'
            pattern = ''
            mode = $mode
            allow = @($allowPatterns)
            block = @($blockPatterns)
            next_action = 'revise_request_or_override'
        }
    }

    return $null
}

function Resolve-SendDispatchPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$ProjectDir = (Get-Location).Path,
        [int]$LengthLimit = 4000,
        [string]$PromptTransport = 'argv',
        [string]$TaskSlug = ''
    )

    $resolvedPromptTransport = Resolve-SupportedPromptTransport -PromptTransport $PromptTransport
    $payload = [ordered]@{
        TextToSend      = $Text
        PromptPath      = $null
        PromptReference = $null
        IsFileBacked    = $false
        TextLength      = $Text.Length
        LengthLimit     = $LengthLimit
        FallbackMode    = 'pointer'
        PromptTransport = $resolvedPromptTransport
        TaskSlug        = ''
    }

    if (-not [string]::IsNullOrWhiteSpace($TaskSlug)) {
        $normalizedTaskSlug = ConvertTo-TaskPromptSlug -TaskSlug $TaskSlug
        $promptPath = New-TaskPromptFile -Content $Text -TaskSlug $normalizedTaskSlug -ProjectDir $ProjectDir
        $payload['PromptPath'] = $promptPath
        $payload['PromptReference'] = Get-DispatchPromptReference -PromptPath $promptPath -ProjectDir $ProjectDir
        $payload['IsFileBacked'] = $true
        $payload['TextToSend'] = New-SendDispatchPointerText -PromptPath $promptPath -ProjectDir $ProjectDir
        $payload['TaskSlug'] = $normalizedTaskSlug
        $payload['FallbackMode'] = 'task_file'
        return $payload
    }

    if ($resolvedPromptTransport -eq 'stdin') {
        return $payload
    }

    if ($resolvedPromptTransport -eq 'argv' -and $Text.Length -le $LengthLimit) {
        return $payload
    }

    $promptPath = New-DispatchPromptFile -Content $Text -ProjectDir $ProjectDir -Prefix 'send-command'
    $payload['PromptPath'] = $promptPath
    $payload['PromptReference'] = Get-DispatchPromptReference -PromptPath $promptPath -ProjectDir $ProjectDir
    $payload['IsFileBacked'] = $true
    $payload['TextToSend'] = New-SendDispatchPointerText -PromptPath $promptPath -ProjectDir $ProjectDir

    return $payload
}

function ConvertTo-DispatchPowerShellLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $paneControlLiteralHelper = Get-Command ConvertTo-PaneControlPowerShellLiteral -ErrorAction SilentlyContinue
    if ($null -ne $paneControlLiteralHelper) {
        return ConvertTo-PaneControlPowerShellLiteral -Value $Value
    }

    $genericLiteralHelper = Get-Command ConvertTo-PowerShellLiteral -ErrorAction SilentlyContinue
    if ($null -ne $genericLiteralHelper) {
        return ConvertTo-PowerShellLiteral -Value $Value
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-DispatchPowerShellCommandInvocation {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value -match '^[a-zA-Z0-9_.:/\\-]+$') {
        return $Value
    }

    return '& ' + (ConvertTo-DispatchPowerShellLiteral -Value $Value)
}

function Resolve-SendTransportPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$ProjectDir = (Get-Location).Path,
        [int]$LengthLimit = 4000,
        [string]$PromptTransport = 'argv',
        [string]$TaskSlug = '',
        [bool]$ExecMode = $false,
        [string]$LaunchDir,
        [string]$GitWorktreeDir,
        [string]$Model,
        [string]$ExecCommand = 'codex'
    )

    $resolvedPromptTransport = Resolve-SupportedPromptTransport -PromptTransport $PromptTransport
    if (-not $ExecMode) {
        $payload = Resolve-SendDispatchPayload -Text $Text -ProjectDir $ProjectDir -LengthLimit $LengthLimit -PromptTransport $resolvedPromptTransport -TaskSlug $TaskSlug
        return [ordered]@{
            Mode            = if ($payload['IsFileBacked']) { 'pointer' } else { 'inline' }
            TextToSend      = [string]$payload['TextToSend']
            PromptPath      = $payload['PromptPath']
            PromptReference = $payload['PromptReference']
            IsFileBacked    = [bool]$payload['IsFileBacked']
            TextLength      = [int]$payload['TextLength']
            LengthLimit     = [int]$payload['LengthLimit']
            FallbackMode    = [string]$payload['FallbackMode']
            PromptTransport = [string]$payload['PromptTransport']
            TaskSlug        = [string]$payload['TaskSlug']
            ExecInstruction = $null
        }
    }

    # Exec-mode dispatch stays file-backed even when prompt_transport is stdin.
    # The pane receives a single codex exec command, and that command reads the
    # prompt from a stable file path so long prompts and task-slug reuse stay deterministic.
    $normalizedTaskSlug = ''
    $promptPath = $null
    if (-not [string]::IsNullOrWhiteSpace($TaskSlug)) {
        $normalizedTaskSlug = ConvertTo-TaskPromptSlug -TaskSlug $TaskSlug
        $promptPath = New-TaskPromptFile -Content $Text -TaskSlug $normalizedTaskSlug -ProjectDir $ProjectDir
    } else {
        $promptPath = New-DispatchPromptFile -Content $Text -ProjectDir $ProjectDir -Prefix 'send-command'
    }
    $outputPath = '{0}.last-message.txt' -f $promptPath
    $promptInstruction = 'Read the prompt file at {0} and follow its instructions' -f $promptPath
    $resolvedExecCommand = if ([string]::IsNullOrWhiteSpace($ExecCommand)) { 'codex' } else { $ExecCommand }
    $execCommandInvocation = ConvertTo-DispatchPowerShellCommandInvocation -Value $resolvedExecCommand
    $execInstruction = '{0} exec --sandbox danger-full-access -C {1} --add-dir {2} -o {3} -m {4} {5}' -f `
        $execCommandInvocation, `
        (ConvertTo-DispatchPowerShellLiteral -Value $LaunchDir), `
        (ConvertTo-DispatchPowerShellLiteral -Value $GitWorktreeDir), `
        (ConvertTo-DispatchPowerShellLiteral -Value $outputPath), `
        (ConvertTo-DispatchPowerShellLiteral -Value $Model), `
        (ConvertTo-DispatchPowerShellLiteral -Value $promptInstruction)

    return [ordered]@{
        Mode            = 'codex_exec_file'
        TextToSend      = $null
        PromptPath      = $promptPath
        PromptReference = Get-DispatchPromptReference -PromptPath $promptPath -ProjectDir $ProjectDir
        IsFileBacked    = $true
        TextLength      = $Text.Length
        LengthLimit     = $LengthLimit
        FallbackMode    = 'exec_file'
        PromptTransport = $resolvedPromptTransport
        TaskSlug        = $normalizedTaskSlug
        ExecInstruction = $execInstruction
    }
}

function Convert-MsysTmpPathToWindowsPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -notmatch '^/tmp(?:/|$)') {
        return $Path
    }

    $tempRoot = [System.IO.Path]::GetTempPath().TrimEnd('\')
    $relative = $Path.Substring(4).TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return $tempRoot
    }

    return Join-Path $tempRoot ($relative -replace '/', '\')
}

function Normalize-DispatchText {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    if ($Text -notmatch '/tmp(?:/|$)') {
        return $Text
    }

    return [regex]::Replace($Text, '(?<quote>["''])(?<path>/tmp(?:/|$)(?:(?!\k<quote>).)*)\k<quote>|(?<path>/tmp(?:/[^''"`\s|;,)]*)?)', {
        param($match)
        $normalizedPath = Convert-MsysTmpPathToWindowsPath -Path $match.Groups['path'].Value
        if ($match.Groups['quote'].Success) {
            return $match.Groups['quote'].Value + $normalizedPath + $match.Groups['quote'].Value
        }

        return $normalizedPath
    })
}

# --- Helper: Review State ---
function Get-ReviewStatePath {
    param([string]$ProjectDir = (Get-Location).Path)

    return Join-Path (Join-Path $ProjectDir '.winsmux') 'review-state.json'
}

function Get-CurrentGitBranch {
    param([string]$ProjectDir = (Get-Location).Path)

    $branch = (git -C $ProjectDir rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
    $nativeExitCode = Get-SafeLastExitCode
    if (($null -ne $nativeExitCode -and $nativeExitCode -ne 0) -or [string]::IsNullOrWhiteSpace($branch) -or $branch -eq 'HEAD') {
        Stop-WithError "unable to determine current git branch in $ProjectDir"
    }

    return $branch.Trim()
}

function Get-CurrentGitHead {
    param([string]$ProjectDir = (Get-Location).Path)

    $head = (git -C $ProjectDir rev-parse HEAD 2>$null | Select-Object -First 1)
    $nativeExitCode = Get-SafeLastExitCode
    if (($null -ne $nativeExitCode -and $nativeExitCode -ne 0) -or [string]::IsNullOrWhiteSpace($head)) {
        Stop-WithError "unable to determine current git HEAD in $ProjectDir"
    }

    return $head.Trim()
}

function ConvertTo-ReviewStateValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string] -or $Value -is [char] -or $Value -is [ValueType]) {
        return $Value
    }

    if ($Value -is [System.Collections.Specialized.OrderedDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $ordered[[string]$key] = ConvertTo-ReviewStateValue -Value $Value[$key]
        }

        return $ordered
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($entry in $Value.GetEnumerator()) {
            $ordered[[string]$entry.Key] = ConvertTo-ReviewStateValue -Value $entry.Value
        }

        return $ordered
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(ConvertTo-ReviewStateValue -Value $item)
        }

        return $items
    }

    $psProperties = @()
    if ($null -ne $Value.PSObject) {
        $psProperties = @($Value.PSObject.Properties)
    }

    if ($psProperties.Count -gt 0) {
        $ordered = [ordered]@{}
        foreach ($property in $psProperties) {
            $ordered[$property.Name] = ConvertTo-ReviewStateValue -Value $property.Value
        }

        return $ordered
    }

    return $Value
}

function Get-ReviewStatePropertyValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }

        return $null
    }

    if ($null -ne $InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }

    return $null
}

function Get-ReviewRequestTargetValue {
    param(
        [AllowNull()]$Request,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $primaryName = "target_review_$Name"
    $legacyName = "target_reviewer_$Name"

    $primaryValue = Get-ReviewStatePropertyValue -InputObject $Request -Name $primaryName
    if ($null -ne $primaryValue -and -not [string]::IsNullOrWhiteSpace([string]$primaryValue)) {
        return $primaryValue
    }

    return Get-ReviewStatePropertyValue -InputObject $Request -Name $legacyName
}

function Get-ReviewState {
    param([string]$ProjectDir = (Get-Location).Path)

    $path = Get-ReviewStatePath -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{}
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{}
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Stop-WithError "invalid review state: $path"
    }

    $state = [ordered]@{}
    foreach ($branchProperty in $parsed.PSObject.Properties) {
        $state[$branchProperty.Name] = ConvertTo-ReviewStateValue -Value $branchProperty.Value
    }

    return $state
}

function Save-ReviewState {
    param(
        [System.Collections.Specialized.OrderedDictionary]$State,
        [string]$ProjectDir = (Get-Location).Path
    )

    $path = Get-ReviewStatePath -ProjectDir $ProjectDir
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ($null -eq $State -or $State.Count -eq 0) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
        return
    }

    Write-ClmSafeTextFile -Path $path -Content ($State | ConvertTo-Json -Depth 5)
}

function Assert-WinsmuxRolePermission {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [string]$TargetPane
    )

    $roleAssert = Get-Command -Name Assert-Role -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $roleAssert) {
        Stop-WithError "role gate unavailable: $RoleGateScript"
    }

    if (-not (Assert-Role -Command $CommandName -TargetPane $TargetPane)) {
        Stop-WithError "$CommandName is not permitted for the current role"
    }
}

function Get-CurrentReviewPaneManifestContext {
    param([string]$ProjectDir = (Get-Location).Path)

    if ([string]::IsNullOrWhiteSpace($env:WINSMUX_PANE_ID)) {
        Stop-WithError 'WINSMUX_PANE_ID not set'
    }

    try {
        $context = Get-PaneControlManifestContext -ProjectDir $ProjectDir -PaneId $env:WINSMUX_PANE_ID
    } catch {
        Stop-WithError $_.Exception.Message
    }

    if ([string]$context.Role -notin @('Reviewer', 'Worker')) {
        Stop-WithError "pane $($env:WINSMUX_PANE_ID) is not registered as a review-capable pane in .winsmux/manifest.yaml"
    }

    return [ordered]@{
        ManifestPath        = [string]$context.ManifestPath
        ProjectDir          = [string]$context.ProjectDir
        Label               = [string]$context.Label
        PaneId              = [string]$context.PaneId
        Role                = [string]$context.Role
        LaunchDir           = [string]$context.LaunchDir
        BuilderWorktreePath = [string]$context.BuilderWorktreePath
        GitWorktreeDir      = [string]$context.GitWorktreeDir
    }
}

function Get-CurrentPaneManifestContext {
    param([string]$ProjectDir = (Get-Location).Path)

    if ([string]::IsNullOrWhiteSpace($env:WINSMUX_PANE_ID)) {
        Stop-WithError 'WINSMUX_PANE_ID not set'
    }

    try {
        $context = Get-PaneControlManifestContext -ProjectDir $ProjectDir -PaneId $env:WINSMUX_PANE_ID
    } catch {
        Stop-WithError $_.Exception.Message
    }

    $sessionName = ''
    try {
        $manifestContent = Get-Content -LiteralPath ([string]$context.ManifestPath) -Raw -Encoding UTF8
        $manifest = ConvertFrom-PaneControlManifestContent -Content $manifestContent
        $sessionName = [string](Get-PaneControlValue -InputObject $manifest.Session -Name 'name' -Default '')
    } catch {
    }

    return [ordered]@{
        ManifestPath        = [string]$context.ManifestPath
        ProjectDir          = [string]$context.ProjectDir
        SessionName         = [string]$sessionName
        Label               = [string]$context.Label
        PaneId              = [string]$context.PaneId
        Role                = [string]$context.Role
        LaunchDir           = [string]$context.LaunchDir
        BuilderWorktreePath = [string]$context.BuilderWorktreePath
        GitWorktreeDir      = [string]$context.GitWorktreeDir
        TaskId              = [string]$context.TaskId
        Task                = [string]$context.Task
        TaskState           = [string]$context.TaskState
        TaskOwner           = [string]$context.TaskOwner
        ReviewState         = [string]$context.ReviewState
        Branch              = [string]$context.Branch
        HeadSha             = [string]$context.HeadSha
        SecurityPolicy      = $context.SecurityPolicy
        ParentRunId         = [string]$context.ParentRunId
        Goal                = [string]$context.Goal
        TaskType            = [string]$context.TaskType
        Priority            = [string]$context.Priority
    }
}

function Update-ReviewPaneManifestState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Properties
    )

    if (-not (Get-Command Set-PaneControlManifestPaneProperties -ErrorAction SilentlyContinue)) {
        return
    }

    try {
        $context = Get-CurrentReviewPaneManifestContext -ProjectDir $ProjectDir
        Set-PaneControlManifestPaneProperties -ManifestPath $context.ManifestPath -PaneId $context.PaneId -Properties $Properties
    } catch {
        # Review-state persistence remains the source of truth. Manifest sync is best-effort.
    }
}

function Get-PreferredReviewPaneEntry {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $entries = @(Get-PaneControlManifestEntries -ProjectDir $ProjectDir)
    foreach ($preferredRole in @('Reviewer', 'Worker')) {
        foreach ($entry in $entries) {
            if ([string]$entry.Role -eq $preferredRole) {
                return $entry
            }
        }
    }

    return $null
}

function New-ReviewRequestId {
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $suffix = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
    return "review-$timestamp-$suffix"
}

function Parse-ConsultCommandArgs {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [string[]]$Args = @()
    )

    $normalizedMode = if ([string]::IsNullOrWhiteSpace($Mode)) { '' } else { $Mode.Trim().ToLowerInvariant() }
    if ($normalizedMode -notin @('early', 'stuck', 'reconcile', 'final')) {
        Stop-WithError "Unsupported consult mode: $Mode"
    }

    $message = ''
    $targetSlot = ''
    $nextTest = ''
    $confidence = $null
    $runId = ''
    $jsonOutput = $false
    $risks = [System.Collections.Generic.List[string]]::new()
    $messageParts = [System.Collections.Generic.List[string]]::new()

    for ($i = 0; $i -lt $Args.Count; $i++) {
        $token = [string]$Args[$i]
        switch ($token) {
            '--message' {
                if ($i + 1 -ge $Args.Count) {
                    Stop-WithError '--message requires a value'
                }
                $message = [string]$Args[$i + 1]
                $i++
            }
            '--target-slot' {
                if ($i + 1 -ge $Args.Count) {
                    Stop-WithError '--target-slot requires a value'
                }
                $targetSlot = [string]$Args[$i + 1]
                $i++
            }
            '--confidence' {
                if ($i + 1 -ge $Args.Count) {
                    Stop-WithError '--confidence requires a value'
                }
                $rawConfidence = [string]$Args[$i + 1]
                $parsedConfidence = 0.0
                if (-not [double]::TryParse($rawConfidence, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedConfidence)) {
                    Stop-WithError "Invalid confidence value: $rawConfidence"
                }
                $confidence = $parsedConfidence
                $i++
            }
            '--run-id' {
                if ($i + 1 -ge $Args.Count) {
                    Stop-WithError '--run-id requires a value'
                }
                $runId = [string]$Args[$i + 1]
                $i++
            }
            '--json' {
                $jsonOutput = $true
            }
            '--next-test' {
                if ($i + 1 -ge $Args.Count) {
                    Stop-WithError '--next-test requires a value'
                }
                $nextTest = [string]$Args[$i + 1]
                $i++
            }
            '--risk' {
                if ($i + 1 -ge $Args.Count) {
                    Stop-WithError '--risk requires a value'
                }
                $risk = [string]$Args[$i + 1]
                if (-not [string]::IsNullOrWhiteSpace($risk)) {
                    $risks.Add($risk) | Out-Null
                }
                $i++
            }
            default {
                if (-not [string]::IsNullOrWhiteSpace($token)) {
                    $messageParts.Add($token) | Out-Null
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($message) -and $messageParts.Count -gt 0) {
        $message = ($messageParts -join ' ')
    }

    if ([string]::IsNullOrWhiteSpace($message)) {
        Stop-WithError 'consult message is required'
    }

    return [ordered]@{
        mode        = $normalizedMode
        message     = [string]$message
        target_slot = [string]$targetSlot
        confidence  = $confidence
        run_id      = [string]$runId
        json        = [bool]$jsonOutput
        next_test   = [string]$nextTest
        risks       = @($risks)
    }
}

function Resolve-CurrentCommandArgs {
    $resolvedTarget = [string]$Target
    if ([string]::IsNullOrWhiteSpace($resolvedTarget)) {
        $globalTarget = Get-Variable -Name Target -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $globalTarget) {
            $resolvedTarget = [string]$globalTarget
        }
    }

    $resolvedRest = @($Rest)
    if (@($resolvedRest).Count -eq 0) {
        $globalRest = Get-Variable -Name Rest -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $globalRest) {
            $resolvedRest = @($globalRest)
        }
    }

    return [ordered]@{
        target = [string]$resolvedTarget
        rest   = @($resolvedRest)
    }
}

function Get-ConsultationCommandContext {
    param(
        [string]$ProjectDir = (Get-Location).Path,
        [string]$RunId = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($RunId)) {
        $payload = Get-ExplainPayload -ProjectDir $ProjectDir -RunId $RunId
        $manifest = Get-WinsmuxManifest -ProjectDir $ProjectDir
        $sessionName = ''
        if ($null -ne $manifest -and $null -ne $manifest.session) {
            $sessionName = [string]$manifest.session.name
        }

        return [ordered]@{
            SessionName = [string]$sessionName
            Label       = [string]$payload.run.primary_label
            PaneId      = [string]$payload.run.primary_pane_id
            Role        = [string]$payload.run.primary_role
            TaskId      = [string]$payload.run.task_id
            Branch      = [string]$payload.run.branch
            HeadSha     = [string]$payload.run.head_sha
            RunId       = [string]$payload.run.run_id
            Slot        = [string]$payload.run.primary_label
            Worktree    = [string]$payload.run.worktree
        }
    }

    $context = Get-CurrentPaneManifestContext -ProjectDir $ProjectDir
    $branch = [string]$context.Branch
    if ([string]::IsNullOrWhiteSpace($branch)) {
        $branch = Get-CurrentGitBranch -ProjectDir $ProjectDir
    }

    $headSha = [string]$context.HeadSha
    if ([string]::IsNullOrWhiteSpace($headSha)) {
        $headSha = Get-CurrentGitHead -ProjectDir $ProjectDir
    }

    $runId = [string]$context.ParentRunId
    if ([string]::IsNullOrWhiteSpace($runId) -and -not [string]::IsNullOrWhiteSpace([string]$context.TaskId)) {
        $runId = "task:$([string]$context.TaskId)"
    }

    if ([string]::IsNullOrWhiteSpace($runId) -and [string]::IsNullOrWhiteSpace([string]$context.TaskId)) {
        Stop-WithError 'consultation commands require task_id or parent_run_id in the current pane manifest entry'
    }

    $worktree = ''
    $worktreePath = [string]$context.GitWorktreeDir
    if ([string]::IsNullOrWhiteSpace($worktreePath)) {
        $worktreePath = [string]$context.BuilderWorktreePath
    }
    if ([string]::IsNullOrWhiteSpace($worktreePath)) {
        $worktreePath = [string]$context.LaunchDir
    }
    if (-not [string]::IsNullOrWhiteSpace($worktreePath)) {
        $worktree = Get-WinsmuxArtifactReference -ArtifactPath $worktreePath -ProjectDir $ProjectDir
    }

    return [ordered]@{
        SessionName = [string]$context.SessionName
        Label       = [string]$context.Label
        PaneId      = [string]$context.PaneId
        Role        = [string]$context.Role
        TaskId      = [string]$context.TaskId
        Branch      = [string]$branch
        HeadSha     = [string]$headSha
        RunId       = [string]$runId
        Slot        = [string]$context.Label
        Worktree    = [string]$worktree
    }
}

function Test-ConsultationGovernanceCostUnitExists {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$UnitId
    )

    foreach ($record in @(Get-BridgeEventRecords -ProjectDir $ProjectDir)) {
        $data = $record['data']
        if ($null -eq $data) {
            continue
        }
        $units = @()
        if ($data -is [hashtable]) {
            if ($data.ContainsKey('governance_cost_units')) {
                $units = @($data['governance_cost_units'])
            }
        } else {
            $property = $data.PSObject.Properties['governance_cost_units']
            if ($null -ne $property) {
                $units = @($property.Value)
            }
        }
        foreach ($unit in $units) {
            $candidate = ''
            if ($unit -is [hashtable] -and $unit.ContainsKey('unit_id')) {
                $candidate = [string]$unit['unit_id']
            } elseif ($null -ne $unit.unit_id) {
                $candidate = [string]$unit.unit_id
            }
            if ($candidate -eq $UnitId) {
                return $true
            }
        }
    }
    return $false
}

function Write-ConsultationCommandRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$TargetSlot = '',
        [AllowNull()]$Confidence = $null,
        [string]$NextTest = '',
        [string[]]$Risks = @(),
        [string]$RunId = '',
        [bool]$JsonOutput = $false,
        [string]$ProjectDir = (Get-Location).Path
    )

    $context = Get-ConsultationCommandContext -ProjectDir $ProjectDir -RunId $RunId
    $timestamp = (Get-Date).ToString('o')
    $packet = [ordered]@{
        run_id      = [string]$context.RunId
        task_id     = [string]$context.TaskId
        pane_id     = [string]$context.PaneId
        slot        = [string]$context.Slot
        kind        = [string]$Kind
        mode        = [string]$Mode
        target_slot = [string]$TargetSlot
        branch      = [string]$context.Branch
        head_sha    = [string]$context.HeadSha
        worktree    = [string]$context.Worktree
    }

    switch ($Kind) {
        'consult_request' { $packet['request'] = $Message }
        'consult_result' {
            $packet['recommendation'] = $Message
            if ($null -ne $Confidence) {
                $packet['confidence'] = $Confidence
            }
            if (-not [string]::IsNullOrWhiteSpace($NextTest)) {
                $packet['next_test'] = $NextTest
            }
            if (@($Risks).Count -gt 0) {
                $packet['risks'] = @($Risks)
            }
        }
        'consult_error' { $packet['error'] = $Message }
        default { Stop-WithError "Unsupported consultation command kind: $Kind" }
    }

    $costTarget = [string]$TargetSlot
    if ([string]::IsNullOrWhiteSpace($costTarget)) {
        $costTarget = [string]$context.Slot
    }
    $costUnit = New-WinsmuxGovernanceCostUnit -Kind 'consult' -Mode $Mode -Task ([string]$context.TaskId) -RunId ([string]$context.RunId) -Stage ("consult_{0}" -f $Mode) -Role ([string]$context.Role) -Target $costTarget -Source 'consult-command'
    $hasExistingCostUnit = Test-ConsultationGovernanceCostUnitExists -ProjectDir $ProjectDir -UnitId ([string]$costUnit.unit_id)
    if ($Kind -eq 'consult_request') {
        $packet['governance_cost_units'] = @($costUnit)
    } else {
        $packet['cost_unit_refs'] = @([string]$costUnit.unit_id)
        if (-not $hasExistingCostUnit) {
            $packet['governance_cost_units'] = @($costUnit)
        }
    }

    $artifact = New-ConsultationPacketFile -ProjectDir $ProjectDir -ConsultationPacket $packet

    $eventData = [ordered]@{
        task_id          = [string]$context.TaskId
        run_id           = [string]$context.RunId
        slot             = [string]$context.Slot
        branch           = [string]$context.Branch
        worktree         = [string]$context.Worktree
        consultation_ref = [string]$artifact.reference
    }
    if ($Kind -eq 'consult_request') {
        $eventData['governance_cost_units'] = @($costUnit)
    } else {
        $eventData['cost_unit_refs'] = @([string]$costUnit.unit_id)
        if (-not $hasExistingCostUnit) {
            $eventData['governance_cost_units'] = @($costUnit)
        }
    }

    if ($Kind -eq 'consult_result') {
        $eventData['result'] = $Message
    }
    if ($null -ne $Confidence) {
        $eventData['confidence'] = $Confidence
    }
    if (-not [string]::IsNullOrWhiteSpace($NextTest)) {
        $eventData['next_action'] = $NextTest
    }

    $eventRecord = [ordered]@{
        timestamp = $timestamp
        session   = [string]$context.SessionName
        event     = "pane.$Kind"
        message   = $Message
        label     = [string]$context.Label
        pane_id   = [string]$context.PaneId
        role      = [string]$context.Role
        branch    = [string]$context.Branch
        head_sha  = [string]$context.HeadSha
        data      = $eventData
    }

    Write-BridgeEventRecord -ProjectDir $ProjectDir -EventRecord $eventRecord | Out-Null

    Update-ReviewPaneManifestState -ProjectDir $ProjectDir -Properties ([ordered]@{
        last_event    = ($Kind -replace '_', '.')
        last_event_at = $timestamp
    })

    if ($JsonOutput) {
        [ordered]@{
            run_id           = [string]$context.RunId
            task_id          = [string]$context.TaskId
            pane_id          = [string]$context.PaneId
            slot             = [string]$context.Slot
            kind             = [string]$Kind
            mode             = [string]$Mode
            target_slot      = [string]$TargetSlot
            recommendation   = if ($Kind -eq 'consult_result') { [string]$Message } else { '' }
            confidence       = $Confidence
            next_test        = [string]$NextTest
            risks            = @($Risks)
            consultation_ref = [string]$artifact.reference
            cost_unit_refs   = @([string]$costUnit.unit_id)
            generated_at     = $timestamp
        } | ConvertTo-Json -Compress -Depth 8 | Write-Output
        return
    }

    $kindLabel = ($Kind -replace '^consult_', 'consult ' -replace '_', ' ')
    Write-Output "$kindLabel recorded for $([string]$context.RunId)"
}

function New-ReviewerStateRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][System.Collections.Specialized.OrderedDictionary]$Request,
        [Parameter(Mandatory = $true)][System.Collections.Specialized.OrderedDictionary]$Reviewer,
        [AllowNull()][System.Collections.Specialized.OrderedDictionary]$Evidence,
        [Parameter(Mandatory = $true)][string]$UpdatedAt
    )

    $record = [ordered]@{
        status    = $Status
        branch    = [string](Get-ReviewStatePropertyValue -InputObject $Request -Name 'branch')
        head_sha  = [string](Get-ReviewStatePropertyValue -InputObject $Request -Name 'head_sha')
        request   = ConvertTo-ReviewStateValue -Value $Request
        reviewer  = ConvertTo-ReviewStateValue -Value $Reviewer
        updatedAt = $UpdatedAt
    }

    if ($null -ne $Evidence -and $Evidence.Count -gt 0) {
        $record['evidence'] = ConvertTo-ReviewStateValue -Value $Evidence
    }

    return $record
}

function New-ReviewContractRecord {
    $requiredScope = @(
        'design_impact'
        'replacement_coverage'
        'orphaned_artifacts'
        'pathspec_completeness'
    )

    return [ordered]@{
        version           = 1
        source_task       = 'TASK-210'
        issue_ref         = '#315'
        style             = 'utility_first'
        required_scope    = $requiredScope
        checklist_labels  = @(
            'design impact'
            'replacement coverage'
            'orphaned artifacts'
            'pathspec completeness'
        )
        pathspec_policy   = [ordered]@{
            source_task                    = 'TASK-395'
            issue_ref                      = '#593'
            include_definition_hosts       = $true
            incomplete_scope_is_review_gap = $true
        }
        rationale         = 'Review requests must audit downstream design impact, replacement coverage, orphaned artifacts, and pathspec completeness as part of the runtime contract.'
    }
}

function Test-ReviewContractPresent {
    param(
        [AllowNull()]$Request
    )

    if ($null -eq $Request -or -not ($Request -is [System.Collections.IDictionary])) {
        return $false
    }

    if (-not $Request.Contains('review_contract')) {
        return $false
    }

    $contract = $Request['review_contract']
    if ($null -eq $contract -or -not ($contract -is [System.Collections.IDictionary])) {
        return $false
    }

    if (-not $contract.Contains('required_scope')) {
        return $false
    }

    return @($contract['required_scope']).Count -gt 0
}

function Assert-ReviewStateRecordShape {
    param(
        [AllowNull()]$Record,
        [Parameter(Mandatory = $true)][string]$Branch
    )

    if ($null -eq $Record -or -not ($Record -is [System.Collections.IDictionary])) {
        Stop-WithError "invalid review state: branch '$Branch' entry must be an object"
    }

    $status = [string](Get-ReviewStatePropertyValue -InputObject $Record -Name 'status')
    if ([string]::IsNullOrWhiteSpace($status)) {
        Stop-WithError "invalid review state: branch '$Branch' entry is missing status"
    }

    $recordBranch = [string](Get-ReviewStatePropertyValue -InputObject $Record -Name 'branch')
    if ([string]::IsNullOrWhiteSpace($recordBranch)) {
        Stop-WithError "invalid review state: branch '$Branch' entry is missing branch"
    }

    $recordHeadSha = [string](Get-ReviewStatePropertyValue -InputObject $Record -Name 'head_sha')
    if ([string]::IsNullOrWhiteSpace($recordHeadSha)) {
        Stop-WithError "invalid review state: branch '$Branch' entry is missing head_sha"
    }

    $request = ConvertTo-ReviewStateValue -Value (Get-ReviewStatePropertyValue -InputObject $Record -Name 'request')
    if ($null -eq $request -or -not ($request -is [System.Collections.IDictionary])) {
        Stop-WithError "invalid review state: branch '$Branch' entry is missing request"
    }

    $requestBranch = [string](Get-ReviewStatePropertyValue -InputObject $request -Name 'branch')
    if ([string]::IsNullOrWhiteSpace($requestBranch)) {
        Stop-WithError "invalid review state: branch '$Branch' request is missing branch"
    }

    $requestHeadSha = [string](Get-ReviewStatePropertyValue -InputObject $request -Name 'head_sha')
    if ([string]::IsNullOrWhiteSpace($requestHeadSha)) {
        Stop-WithError "invalid review state: branch '$Branch' request is missing head_sha"
    }

    $targetPaneId = [string](Get-ReviewRequestTargetValue -Request $request -Name 'pane_id')
    if ([string]::IsNullOrWhiteSpace($targetPaneId)) {
        Stop-WithError "invalid review state: branch '$Branch' request is missing target review pane id"
    }

    $targetLabel = [string](Get-ReviewRequestTargetValue -Request $request -Name 'label')
    if ([string]::IsNullOrWhiteSpace($targetLabel)) {
        Stop-WithError "invalid review state: branch '$Branch' request is missing target review label"
    }

    $targetRole = [string](Get-ReviewRequestTargetValue -Request $request -Name 'role')
    if ([string]::IsNullOrWhiteSpace($targetRole)) {
        Stop-WithError "invalid review state: branch '$Branch' request is missing target review role"
    }

    if (-not (Test-ReviewContractPresent -Request $request)) {
        Stop-WithError "invalid review state: branch '$Branch' request is missing review_contract.required_scope"
    }

    $reviewer = ConvertTo-ReviewStateValue -Value (Get-ReviewStatePropertyValue -InputObject $Record -Name 'reviewer')
    if ($null -eq $reviewer -or -not ($reviewer -is [System.Collections.IDictionary])) {
        Stop-WithError "invalid review state: branch '$Branch' entry is missing reviewer"
    }

    foreach ($fieldName in @('pane_id', 'label', 'role')) {
        $fieldValue = [string](Get-ReviewStatePropertyValue -InputObject $reviewer -Name $fieldName)
        if ([string]::IsNullOrWhiteSpace($fieldValue)) {
            Stop-WithError "invalid review state: branch '$Branch' reviewer is missing $fieldName"
        }
    }

    $updatedAt = [string](Get-ReviewStatePropertyValue -InputObject $Record -Name 'updatedAt')
    if ([string]::IsNullOrWhiteSpace($updatedAt)) {
        Stop-WithError "invalid review state: branch '$Branch' entry is missing updatedAt"
    }

    $evidence = Get-ReviewStatePropertyValue -InputObject $Record -Name 'evidence'
    if ($null -eq $evidence) {
        return
    }

    $evidenceRecord = ConvertTo-ReviewStateValue -Value $evidence
    if (-not ($evidenceRecord -is [System.Collections.IDictionary])) {
        Stop-WithError "invalid review state: branch '$Branch' evidence must be an object"
    }

    $snapshot = ConvertTo-ReviewStateValue -Value (Get-ReviewStatePropertyValue -InputObject $evidenceRecord -Name 'review_contract_snapshot')
    if ($null -eq $snapshot -or -not ($snapshot -is [System.Collections.IDictionary])) {
        Stop-WithError "invalid review state: branch '$Branch' evidence is missing review_contract_snapshot"
    }

    if (-not $snapshot.Contains('required_scope') -or @($snapshot['required_scope']).Count -eq 0) {
        Stop-WithError "invalid review state: branch '$Branch' evidence is missing review_contract_snapshot.required_scope"
    }

    switch ($status.ToUpperInvariant()) {
        'PASS' {
            $approvedAt = [string](Get-ReviewStatePropertyValue -InputObject $evidenceRecord -Name 'approved_at')
            if ([string]::IsNullOrWhiteSpace($approvedAt)) {
                Stop-WithError "invalid review state: branch '$Branch' PASS evidence is missing approved_at"
            }

            $approvedVia = [string](Get-ReviewStatePropertyValue -InputObject $evidenceRecord -Name 'approved_via')
            if ([string]::IsNullOrWhiteSpace($approvedVia)) {
                Stop-WithError "invalid review state: branch '$Branch' PASS evidence is missing approved_via"
            }
        }
        'FAIL' {
            $failedAt = [string](Get-ReviewStatePropertyValue -InputObject $evidenceRecord -Name 'failed_at')
            if ([string]::IsNullOrWhiteSpace($failedAt)) {
                Stop-WithError "invalid review state: branch '$Branch' FAIL evidence is missing failed_at"
            }

            $failedVia = [string](Get-ReviewStatePropertyValue -InputObject $evidenceRecord -Name 'failed_via')
            if ([string]::IsNullOrWhiteSpace($failedVia)) {
                Stop-WithError "invalid review state: branch '$Branch' FAIL evidence is missing failed_via"
            }
        }
    }
}

function Assert-ManifestBackedRunShape {
    param([Parameter(Mandatory = $true)]$PaneRecord)

    $getFieldValue = {
        param($InputObject, [string[]]$Names)

        foreach ($name in @($Names)) {
            if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($name)) {
                return $InputObject[$name]
            }

            if ($null -ne $InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $name) {
                return $InputObject.PSObject.Properties[$name].Value
            }
        }

        return $null
    }

    $label = [string](& $getFieldValue $PaneRecord @('label', 'Label'))
    if ([string]::IsNullOrWhiteSpace($label)) {
        $label = '<unknown>'
    }

    $reviewState = [string](& $getFieldValue $PaneRecord @('review_state', 'ReviewState'))
    if (-not [string]::IsNullOrWhiteSpace($reviewState)) {
        $branch = [string](& $getFieldValue $PaneRecord @('branch', 'Branch'))
        if ([string]::IsNullOrWhiteSpace($branch)) {
            Stop-WithError "invalid manifest: pane '$label' review_state requires branch"
        }

        $headSha = [string](& $getFieldValue $PaneRecord @('head_sha', 'HeadSha'))
        if ([string]::IsNullOrWhiteSpace($headSha)) {
            Stop-WithError "invalid manifest: pane '$label' review_state requires head_sha"
        }
    }

    $changedFileCount = & $getFieldValue $PaneRecord @('changed_file_count', 'ChangedFileCount')
    if ([int]$changedFileCount -gt 0) {
        $changedFiles = @(& $getFieldValue $PaneRecord @('changed_files', 'ChangedFiles'))
        if (@($changedFiles).Count -eq 0) {
            Stop-WithError "invalid manifest: pane '$label' changed_file_count requires changed_files"
        }
    }

    $lastEvent = [string](& $getFieldValue $PaneRecord @('last_event', 'LastEvent'))
    if (-not [string]::IsNullOrWhiteSpace($lastEvent)) {
        $lastEventAt = [string](& $getFieldValue $PaneRecord @('last_event_at', 'LastEventAt'))
        if ([string]::IsNullOrWhiteSpace($lastEventAt)) {
            Stop-WithError "invalid manifest: pane '$label' last_event requires last_event_at"
        }
    }

    $parentRunId = [string](& $getFieldValue $PaneRecord @('parent_run_id', 'ParentRunId'))
    $goal = [string](& $getFieldValue $PaneRecord @('goal', 'Goal'))
    $taskType = [string](& $getFieldValue $PaneRecord @('task_type', 'TaskType'))
    $priority = [string](& $getFieldValue $PaneRecord @('priority', 'Priority'))
    $hasPlanningMetadata =
        -not [string]::IsNullOrWhiteSpace($parentRunId) -or
        -not [string]::IsNullOrWhiteSpace($goal) -or
        -not [string]::IsNullOrWhiteSpace($taskType) -or
        -not [string]::IsNullOrWhiteSpace($priority)

    if ($hasPlanningMetadata) {
        if ([string]::IsNullOrWhiteSpace($parentRunId)) {
            Stop-WithError "invalid manifest: pane '$label' planning metadata requires parent_run_id"
        }
        if ([string]::IsNullOrWhiteSpace($goal)) {
            Stop-WithError "invalid manifest: pane '$label' planning metadata requires goal"
        }
        if ([string]::IsNullOrWhiteSpace($taskType)) {
            Stop-WithError "invalid manifest: pane '$label' planning metadata requires task_type"
        }
        if ([string]::IsNullOrWhiteSpace($priority)) {
            Stop-WithError "invalid manifest: pane '$label' planning metadata requires priority"
        }
    }
}

# --- Helper: Labels ---
function Get-Labels {
    if (Test-Path $LabelsFile) {
        $raw = Get-Content -Path $LabelsFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $ht = @{}
        $obj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
        return $ht
    }
    return @{}
}

function Save-Labels {
    param([hashtable]$Labels)
    $dir = Split-Path $LabelsFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Write-ClmSafeTextFile -Path $LabelsFile -Content ($Labels | ConvertTo-Json)
}

# --- Helper: Resolve-Target ---
function Resolve-Target {
    param([string]$RawTarget)
    $labels = Get-Labels
    if ($labels.ContainsKey($RawTarget)) {
        return $labels[$RawTarget]
    }
    return $RawTarget
}

# --- Helper: Confirm-Target ---
function Confirm-Target {
    param([string]$PaneId)
        # Older core builds ignored the display-message -t flag, so validate via list-panes.
    $allPanes = (Invoke-WinsmuxRaw -Arguments @('list-panes', '-a', '-F', '#{pane_id}') | Out-String).Trim() -split "`n" | ForEach-Object { $_.Trim() }
    if ($PaneId -notin $allPanes) {
        Stop-WithError "invalid target: $PaneId"
    }
    return $PaneId
}

function Get-PaneTargetCandidates {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    $candidates = [ordered]@{}
    $candidates[$PaneId] = $true

    $raw = Invoke-WinsmuxRaw -Arguments @('list-panes', '-a', '-F', "#{pane_id}`t#{session_name}:#{window_index}.#{pane_index}") 2>$null
    foreach ($line in @($raw)) {
        $trimmed = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        $parts = $trimmed -split "`t", 2
        if ($parts.Count -lt 2) {
            continue
        }

        $candidatePaneId = $parts[0].Trim()
        $candidateTarget = $parts[1].Trim()
        if ($candidatePaneId -ne $PaneId -or [string]::IsNullOrWhiteSpace($candidateTarget)) {
            continue
        }

        if (-not $candidates.Contains($candidateTarget)) {
            $candidates[$candidateTarget] = $true
        }
    }

    return @($candidates.Keys)
}

function Invoke-WinsmuxSendKeys {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string[]]$Keys,
        [switch]$Literal
    )

    if ((Resolve-TerminalBackend) -eq 'tauri') {
        if ($Literal) {
            return Invoke-TerminalWrite -Target $Target -Text ($Keys -join '')
        }

        if ($Keys.Count -eq 1 -and $Keys[0] -eq 'Enter') {
            return Invoke-TerminalWrite -Target $Target -Text "`r"
        }

        return [ordered]@{
            ExitCode = 1
            Output   = 'Tauri terminal backend supports only literal text and Enter for send-keys.'
            Target   = $Target
        }
    }

    $arguments = @('send-keys', '-t', $Target)
    if ($Literal) {
        $arguments += '-l'
        $arguments += '--'
    }

    $arguments += $Keys
    $output = Invoke-WinsmuxRaw -Arguments $arguments 2>&1

    return [ordered]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String).Trim()
        Target   = $Target
    }
}

function Invoke-WinsmuxSendPaste {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    if ((Resolve-TerminalBackend) -eq 'tauri') {
        return Invoke-TerminalWrite -Target $Target -Text $Text
    }

    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
    $arguments = @('send-paste', '-t', $Target, $encoded)
    $output = Invoke-WinsmuxRaw -Arguments $arguments 2>&1

    return [ordered]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String).Trim()
        Target   = $Target
    }
}

function Split-SendKeysLiteralChunks {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [ValidateRange(1, 4000)][int]$ChunkSize = 900
    )

    if ($Text.Length -le $ChunkSize) {
        return @($Text)
    }

    $chunks = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $Text.Length; $index += $ChunkSize) {
        $remaining = $Text.Length - $index
        $length = [System.Math]::Min($ChunkSize, $remaining)
        $chunks.Add($Text.Substring($index, $length)) | Out-Null
    }

    return @($chunks)
}

function Test-PaneContainsCommandFragment {
    param(
        [AllowEmptyString()][string]$PaneText,
        [AllowEmptyString()][string]$CommandText,
        [ValidateRange(8, 256)][int]$FragmentLength = 64
    )

    if ([string]::IsNullOrWhiteSpace($PaneText) -or [string]::IsNullOrWhiteSpace($CommandText)) {
        return $false
    }

    $normalizedPaneText = (($PaneText -replace '\s+', '')).ToLowerInvariant()
    $normalizedCommandText = (($CommandText -replace '\s+', '')).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedPaneText) -or [string]::IsNullOrWhiteSpace($normalizedCommandText)) {
        return $false
    }

    $effectiveLength = [Math]::Min($FragmentLength, $normalizedCommandText.Length)
    $fragment = $normalizedCommandText.Substring([Math]::Max(0, $normalizedCommandText.Length - $effectiveLength))
    return $normalizedPaneText.Contains($fragment)
}

function Send-TextToPane {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$CommandText,
        [AllowEmptyString()][string]$PromptTransport = 'argv'
    )

    $resolvedPromptTransport = Resolve-SupportedPromptTransport -PromptTransport $PromptTransport
    $terminalBackend = Resolve-TerminalBackend
    $targetCandidates = if ($terminalBackend -eq 'tauri') {
        @($PaneId)
    } else {
        @(Get-PaneTargetCandidates -PaneId $PaneId)
    }
    $attemptFailures = [System.Collections.Generic.List[string]]::new()

    foreach ($sendTarget in $targetCandidates) {
        $preSendText = Get-PaneSnapshotText -PaneId $PaneId -Lines 200
        if ($resolvedPromptTransport -eq 'stdin') {
            $pasteResult = Invoke-WinsmuxSendPaste -Target $sendTarget -Text $CommandText
            if ($pasteResult.ExitCode -ne 0) {
                $detail = if ([string]::IsNullOrWhiteSpace($pasteResult.Output)) { 'send-paste failed' } else { $pasteResult.Output }
                $attemptFailures.Add("target ${sendTarget}: $detail") | Out-Null
                continue
            }
        } else {
            $literalChunks = @(Split-SendKeysLiteralChunks -Text $CommandText)

            # Type text directly (no header; headers break TUI agents like Claude Code)
            for ($chunkIndex = 0; $chunkIndex -lt $literalChunks.Count; $chunkIndex++) {
                $literalResult = Invoke-WinsmuxSendKeys -Target $sendTarget -Keys @($literalChunks[$chunkIndex]) -Literal
                if ($literalResult.ExitCode -ne 0) {
                    $detail = if ([string]::IsNullOrWhiteSpace($literalResult.Output)) { 'send-keys literal failed' } else { $literalResult.Output }
                    $attemptFailures.Add("target ${sendTarget}: chunk $($chunkIndex + 1)/$($literalChunks.Count) $detail") | Out-Null
                    continue 2
                }
            }
        }

        Start-Sleep -Milliseconds 300
        $typedText = Get-PaneSnapshotText -PaneId $PaneId -Lines 200
        if ($typedText -eq $preSendText) {
            $attemptFailures.Add("target ${sendTarget}: pane buffer did not change after typing") | Out-Null
            continue
        }
        if (-not (Test-PaneContainsCommandFragment -PaneText $typedText -CommandText $CommandText)) {
            $attemptFailures.Add("target ${sendTarget}: pane buffer changed but typed command fragment was not observed") | Out-Null
            continue
        }

        $enterResult = Invoke-WinsmuxSendKeys -Target $sendTarget -Keys @('Enter')
        if ($enterResult.ExitCode -ne 0) {
            $detail = if ([string]::IsNullOrWhiteSpace($enterResult.Output)) { 'send-keys Enter failed' } else { $enterResult.Output }
            $attemptFailures.Add("target ${sendTarget}: $detail") | Out-Null
            continue
        }

        Start-Sleep -Milliseconds 500
        $postEnterText = Get-PaneSnapshotText -PaneId $PaneId -Lines 200
        if ($postEnterText -match '\[Pasted Content') {
            $secondEnterResult = Invoke-WinsmuxSendKeys -Target $sendTarget -Keys @('Enter')
            if ($secondEnterResult.ExitCode -ne 0) {
                $detail = if ([string]::IsNullOrWhiteSpace($secondEnterResult.Output)) { 'send-keys second Enter failed' } else { $secondEnterResult.Output }
                $attemptFailures.Add("target ${sendTarget}: $detail") | Out-Null
                continue
            }
        }

        Start-Sleep -Milliseconds 800
        $snapshotText = Get-PaneSnapshotText -PaneId $PaneId -Lines 200
        Save-Watermark $PaneId $snapshotText
        Set-ReadMark $PaneId

        Write-Output "sent to $PaneId via $sendTarget"
        return
    }

    $failureText = if ($attemptFailures.Count -gt 0) {
        $attemptFailures -join '; '
    } else {
        'no send targets available'
    }
    Stop-WithError "failed to send to ${PaneId}: $failureText"
}

# --- Helper: Read Mark ---
function Get-ReadMarkPath {
    param([string]$PaneId)
    $safe = $PaneId -replace '[%:]', '_'
    return Join-Path $ReadMarkDir $safe
}

function Set-ReadMark {
    param([string]$PaneId)
    $path = Get-ReadMarkPath $PaneId
    if (-not (Test-Path $ReadMarkDir)) {
        New-Item -ItemType Directory -Path $ReadMarkDir -Force | Out-Null
    }
    New-Item -ItemType File -Path $path -Force | Out-Null
}

function Assert-ReadMark {
    param([string]$PaneId)
    $path = Get-ReadMarkPath $PaneId
    if (-not (Test-Path $path)) {
        Stop-WithError "error: must read the pane before interacting. Run: winsmux read $PaneId"
    }
}

function Clear-ReadMark {
    param([string]$PaneId)
    $path = Get-ReadMarkPath $PaneId
    if (Test-Path $path) {
        Remove-Item -Path $path -Force
    }
}

# --- Helper: Watermark (change detection for read-after-send) ---
function Get-WatermarkPath {
    param([string]$PaneId)
    $safe = $PaneId -replace '[%:]', '_'
    return Join-Path $WatermarkDir $safe
}

function Save-Watermark {
    param([string]$PaneId, [string]$Content)
    if (-not (Test-Path $WatermarkDir)) {
        New-Item -ItemType Directory -Path $WatermarkDir -Force | Out-Null
    }
    $hash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Content)
        )
    ) -replace '-', ''
    $path = Get-WatermarkPath $PaneId
    Write-WinsmuxTextFile -Path $path -Content $hash
}

function Test-WatermarkChanged {
    param([string]$PaneId, [string]$CurrentContent)
    $path = Get-WatermarkPath $PaneId
    if (-not (Test-Path $path)) { return $true }
    $savedHash = (Get-Content -Path $path -Raw -Encoding UTF8).Trim()
    $currentHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($CurrentContent)
        )
    ) -replace '-', ''
    return $currentHash -ne $savedHash
}

function Clear-Watermark {
    param([string]$PaneId)
    $path = Get-WatermarkPath $PaneId
    if (Test-Path $path) {
        Remove-Item -Path $path -Force
    }
}

function Get-LastNonEmptyLine {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $lines = $Text -split "\r?\n"
    for ($i = $lines.Length - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            return $line
        }
    }

    return $null
}

function Get-TextHash {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        $Text = ''
    }

    return [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Text)
        )
    ) -replace '-', ''
}

function Test-CodexReadyPromptText {
    param([string]$Text)

    $lastLine = Get-LastNonEmptyLine $Text
    if ($null -eq $lastLine) {
        return $false
    }

    return $lastLine.TrimStart().StartsWith('>')
}

function Test-CodexReadyPrompt {
    param([string]$PaneId)

    $output = Invoke-WinsmuxRaw -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-50')
    return Test-CodexReadyPromptText (($output | Out-String).TrimEnd())
}

function Get-AgentReadinessRecentLines {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxCount = 8
    )

    if ([string]::IsNullOrWhiteSpace($Text) -or $MaxCount -lt 1) {
        return @()
    }

    $lines = $Text -split "\r?\n"
    $recent = [System.Collections.Generic.List[string]]::new()
    for ($index = $lines.Length - 1; $index -ge 0 -and $recent.Count -lt $MaxCount; $index--) {
        $line = $lines[$index]
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $recent.Insert(0, $line)
        }
    }

    return @($recent)
}

function Test-AgentReadyPromptLine {
    param(
        [AllowNull()][string]$Line,
        [string]$Agent = ''
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    $agentName = if ([string]::IsNullOrWhiteSpace($Agent)) { '' } else { $Agent.Trim().ToLowerInvariant() }
    if ([string]::IsNullOrWhiteSpace($agentName)) {
        return $false
    }

    $line = $Line.Trim()
    if ($line -match '^(>|›|▌|❯)$') {
        return $true
    }

    if (Get-Command Test-AgentPromptText -ErrorAction SilentlyContinue) {
        if (Test-AgentPromptText -Text $line -Agent $agentName) {
            return $true
        }
    }

    switch ($agentName) {
        'codex' {
            return $line.StartsWith('>')
        }
        'claude' {
            return $line -match '(?i)^Welcome to Claude Code!?$' -or
                $line -match '(?i)^/help for help,\s*/status for your current setup$' -or
                $line -match '(?i)^\?\s+for shortcuts\b'
        }
        'gemini' {
            return $line -match '(?i)^Type your message(?:\s+or\s+@path/to/file)?\b' -or
                $line -match '(?i)^Using:\s+\d+\s+GEMINI\.md\s+file' -or
                $line -match '(?i)^gemini-[A-Za-z0-9._-]+\b.*\b\d+(?:\.\d+)?%\s+context\s+left\b'
        }
        default {
            return $false
        }
    }
}

function Test-AgentReadyPromptTrailingLine {
    param([AllowNull()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $true
    }

    $line = $Line.Trim()
    if ($line -match '^[\s╭╮╰╯─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬┄┈┊┋]+$') {
        return $true
    }

    return $false
}

function Test-AgentRecentReadyPromptTail {
    param(
        [AllowNull()][string]$Text,
        [string]$Agent = ''
    )

    $recentLines = @(Get-AgentReadinessRecentLines -Text $Text -MaxCount 8)
    if ($recentLines.Count -eq 0) {
        return $false
    }

    for ($index = $recentLines.Count - 1; $index -ge 0; $index--) {
        if (-not (Test-AgentReadyPromptLine -Line $recentLines[$index] -Agent $Agent)) {
            continue
        }

        for ($trailingIndex = $index + 1; $trailingIndex -lt $recentLines.Count; $trailingIndex++) {
            if (-not (Test-AgentReadyPromptTrailingLine -Line $recentLines[$trailingIndex])) {
                return $false
            }
        }

        return $true
    }

    return $false
}

function ConvertTo-ReadinessAgentName {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $candidate = $Value.Trim().ToLowerInvariant()
    if ($candidate -match '^(codex|claude|gemini)(?:$|[:/_-])') {
        return $matches[1]
    }

    return ''
}

function Test-AgentReadyPromptText {
    param(
        [AllowNull()][string]$Text,
        [string]$Agent = ''
    )

    $agentName = if ([string]::IsNullOrWhiteSpace($Agent)) { '' } else { $Agent.Trim().ToLowerInvariant() }
    if ([string]::IsNullOrWhiteSpace($agentName)) {
        return $false
    }

    if (-not (Test-AgentRecentReadyPromptTail -Text $Text -Agent $agentName)) {
        return $false
    }

    if (Get-Command Test-AgentPromptText -ErrorAction SilentlyContinue) {
        if (Test-AgentPromptText -Text $Text -Agent $agentName) {
            return $true
        }

        if ($agentName -ne 'codex') {
            return $false
        }
    }

    if ($agentName -eq 'codex') {
        return Test-CodexReadyPromptText $Text
    }

    return $false
}

function Test-AgentReadyPrompt {
    param(
        [string]$PaneId,
        [string]$Agent = ''
    )

    $output = Invoke-WinsmuxRaw -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-50')
    return Test-AgentReadyPromptText -Text (($output | Out-String).TrimEnd()) -Agent $Agent
}

function Get-PaneReadinessAgent {
    param(
        [string]$Target,
        [string]$PaneId,
        [string]$ProjectDir = (Get-Location).Path
    )

    $fallback = ''
    if (-not (Get-Command Get-PaneControlManifestEntries -ErrorAction SilentlyContinue)) {
        return $fallback
    }

    try {
        $entries = @(Get-PaneControlManifestEntries -ProjectDir $ProjectDir)
    } catch {
        return $fallback
    }

    foreach ($entry in $entries) {
        $entryLabel = [string]$entry.Label
        $entryPaneId = [string]$entry.PaneId
        $targetMatches = -not [string]::IsNullOrWhiteSpace($Target) -and
            [string]::Equals($entryLabel, $Target, [System.StringComparison]::OrdinalIgnoreCase)
        $paneMatches = -not [string]::IsNullOrWhiteSpace($PaneId) -and
            [string]::Equals($entryPaneId, $PaneId, [System.StringComparison]::OrdinalIgnoreCase)

        if (-not ($targetMatches -or $paneMatches)) {
            continue
        }

        $adapterName = ConvertTo-ReadinessAgentName ([string]$entry.CapabilityAdapter)
        if (-not [string]::IsNullOrWhiteSpace($adapterName)) {
            return $adapterName
        }

        $providerName = ConvertTo-ReadinessAgentName ([string]$entry.ProviderTarget)
        if (-not [string]::IsNullOrWhiteSpace($providerName)) {
            return $providerName
        }

        if (Get-Command Get-SlotAgentConfig -ErrorAction SilentlyContinue) {
            try {
                $roleName = [string]$entry.Role
                if ([string]::IsNullOrWhiteSpace($roleName)) {
                    $roleName = 'Worker'
                }

                $settings = if (Get-Command Get-BridgeSettings -ErrorAction SilentlyContinue) {
                    Get-BridgeSettings -RootPath $ProjectDir
                } else {
                    $null
                }

                $effective = Get-SlotAgentConfig -Role $roleName -SlotId $entryLabel -Settings $settings -RootPath $ProjectDir
                $effectiveAdapter = ConvertTo-ReadinessAgentName ([string]$effective.CapabilityAdapter)
                if (-not [string]::IsNullOrWhiteSpace($effectiveAdapter)) {
                    return $effectiveAdapter
                }

                $effectiveAgent = ConvertTo-ReadinessAgentName ([string]$effective.Agent)
                if (-not [string]::IsNullOrWhiteSpace($effectiveAgent)) {
                    return $effectiveAgent
                }
            } catch {
                # Keep readiness unknown when no provider metadata is available.
            }
        }

        return $fallback
    }

    return $fallback
}

function Wait-PaneShellReady {
    param([string]$PaneId, [int]$TimeoutSeconds = 15)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $snapshot = (Invoke-WinsmuxRaw -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-50') 2>$null | Out-String).TrimEnd()
        $lastLine = Get-LastNonEmptyLine $snapshot
        if ($lastLine -and $lastLine.Trim() -match '^PS ') {
            return
        }

        Start-Sleep -Milliseconds 500
    }

    Stop-WithError "timed out waiting for shell prompt in $PaneId"
}

function Get-PaneRuntimeMap {
    $paneMap = @{}
    $raw = Invoke-WinsmuxRaw -Arguments @('list-panes', '-a', '-F', '#{pane_id} #{pane_pid}')
    $lines = ($raw | Out-String).Trim() -split "`n"

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        $parts = $trimmed -split '\s+', 3
        if ($parts.Count -lt 2) { continue }

        $paneId = $parts[0]
        $panePid = $parts[1]
        $isRunning = $false

        if ($panePid -match '^\d+$') {
            try {
                $null = Get-Process -Id ([int]$panePid) -ErrorAction Stop
                $isRunning = $true
            } catch {
                $isRunning = $false
            }
        }

        $paneMap[$paneId] = [PSCustomObject]@{
            PaneId    = $paneId
            PanePid   = $panePid
            IsRunning = $isRunning
        }
    }

    return $paneMap
}

function Get-PaneSnapshotText {
    param([string]$PaneId, [int]$Lines = 50)

    return Invoke-TerminalCapture -PaneId $PaneId -Lines $Lines
}

# --- Helper: Focus Policy Stack ---
function Get-FocusPolicyStack {
    if (-not (Test-Path $FocusPolicyFile)) {
        return @()
    }

    $raw = Get-Content -Path $FocusPolicyFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Stop-WithError "invalid focus policy stack: $FocusPolicyFile"
    }

    if ($parsed -is [System.Array]) {
        return @($parsed)
    }

    return @($parsed)
}

function Save-FocusPolicyStack {
    param([object[]]$Stack)

    $dir = Split-Path $FocusPolicyFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ($null -eq $Stack -or $Stack.Count -eq 0) {
        if (Test-Path $FocusPolicyFile) {
            Remove-Item -Path $FocusPolicyFile -Force
        }
        return
    }

    Write-ClmSafeTextFile -Path $FocusPolicyFile -Content ($Stack | ConvertTo-Json -Depth 4)
}

function Get-ActiveFocusPolicy {
    $stack = Get-FocusPolicyStack
    if (-not $stack -or $stack.Count -eq 0) {
        return $null
    }

    return $stack[$stack.Count - 1]
}

function Push-FocusPolicy {
    param(
        [string]$PaneId,
        [string]$TargetName
    )

    $stack = @(Get-FocusPolicyStack)
    $entry = [PSCustomObject]@{
        paneId      = $PaneId
        target      = $TargetName
        lockedBy    = $env:WINSMUX_PANE_ID
        lockedAt    = (Get-Date).ToString("o")
    }

    $stack += $entry
    Save-FocusPolicyStack -Stack $stack
    return $entry
}

function Pop-FocusPolicy {
    $stack = @(Get-FocusPolicyStack)
    if (-not $stack -or $stack.Count -eq 0) {
        return $null
    }

    $entry = $stack[$stack.Count - 1]
    if ($stack.Count -eq 1) {
        Save-FocusPolicyStack -Stack @()
    } else {
        Save-FocusPolicyStack -Stack $stack[0..($stack.Count - 2)]
    }

    return $entry
}

function Assert-FocusAllowed {
    param(
        [string]$PaneId,
        [string]$RawTarget
    )

    $policy = Get-ActiveFocusPolicy
    if ($null -eq $policy) {
        return
    }

    if ($policy.paneId -ne $PaneId) {
        Stop-WithError "focus denied: locked to $($policy.paneId) ($($policy.target)). Run: winsmux focus-unlock"
    }
}

# --- Helper: File Locks ---
function Ensure-LockDir {
    if (-not (Test-Path $LockDir)) {
        New-Item -ItemType Directory -Path $LockDir -Force | Out-Null
    }
}

function Resolve-LockFileTarget {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        Stop-WithError "lock target file must not be empty"
    }

    try {
        $resolved = Resolve-Path -LiteralPath $FilePath -ErrorAction Stop
        return $resolved.ProviderPath
    } catch {
        return [System.IO.Path]::GetFullPath($FilePath)
    }
}

function Get-LockHash {
    param([string]$FilePath)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($FilePath.ToLowerInvariant())
    return ([System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    ) -replace '-', '').ToLowerInvariant()
}

function Get-LockPath {
    param([string]$FilePath)

    $resolvedFile = Resolve-LockFileTarget $FilePath
    $hash = Get-LockHash $resolvedFile
    return Join-Path $LockDir "$hash.lock"
}

function Read-LockInfo {
    param([string]$LockPath)

    if (-not (Test-Path $LockPath)) { return $null }
    try {
        return (Get-Content -Path $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Remove-ExpiredLocks {
    Ensure-LockDir
    $now = Get-Date
    $expired = @()

    foreach ($item in Get-ChildItem -Path $LockDir -Filter '*.lock' -File -ErrorAction SilentlyContinue) {
        $info = Read-LockInfo $item.FullName
        if ($null -eq $info) {
            Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
            continue
        }

        try {
            $acquiredAt = [DateTimeOffset]::Parse($info.acquiredAt)
        } catch {
            Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
            continue
        }

        if (($now - $acquiredAt.LocalDateTime).TotalMinutes -ge 30) {
            Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
            $expired += [PSCustomObject]@{
                Label      = $info.label
                File       = $info.file
                AcquiredAt = $acquiredAt.ToString("o")
            }
        }
    }

    return $expired
}

function Invoke-Lock {
    if (-not $Target) { Stop-WithError "usage: winsmux lock <label> <file>..." }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux lock <label> <file>..." }

    $label = $Target
    $expired = Remove-ExpiredLocks
    foreach ($entry in $expired) {
        Write-Warning "expired lock released: $($entry.File) [$($entry.Label)]"
    }

    $pending = @()
    foreach ($file in $Rest) {
        $resolvedFile = Resolve-LockFileTarget $file
        $lockPath = Get-LockPath $resolvedFile
        $info = Read-LockInfo $lockPath

        if ($null -ne $info -and $info.label -ne $label) {
            Stop-WithError "lock denied: $resolvedFile is already locked by $($info.label)"
        }

        $pending += [PSCustomObject]@{
            File     = $resolvedFile
            LockPath = $lockPath
        }
    }

    Ensure-LockDir
    $timestamp = (Get-Date).ToString("o")
    foreach ($entry in $pending) {
        $payload = [ordered]@{
            label      = $label
            file       = $entry.File
            acquiredAt = $timestamp
        }
        $json = $payload | ConvertTo-Json
        # Atomic lock acquisition: CreateNew fails if file already exists (race-safe)
        try {
            $fs = [IO.File]::Open($entry.LockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $writer = [IO.StreamWriter]::new($fs, [Text.Encoding]::UTF8)
            $writer.Write($json)
            $writer.Close()
            $fs.Close()
            Write-Output "locked $($entry.File) [$label]"
        } catch [IO.IOException] {
            # File was created by another process between check and write
            $rival = Read-LockInfo $entry.LockPath
            $rivalLabel = if ($rival) { $rival.label } else { "unknown" }
            Stop-WithError "lock denied (race): $($entry.File) is already locked by $rivalLabel"
        }
    }
}

function Invoke-Unlock {
    if (-not $Target) { Stop-WithError "usage: winsmux unlock <label> <file>..." }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux unlock <label> <file>..." }

    $label = $Target
    foreach ($file in $Rest) {
        $resolvedFile = Resolve-LockFileTarget $file
        $lockPath = Get-LockPath $resolvedFile

        if (-not (Test-Path $lockPath)) {
            Write-Output "not locked: $resolvedFile"
            continue
        }

        $info = Read-LockInfo $lockPath
        if ($null -eq $info) {
            Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
            Write-Output "unlocked $resolvedFile [$label]"
            continue
        }

        if ($info.label -ne $label) {
            Stop-WithError "unlock denied: $resolvedFile is locked by $($info.label)"
        }

        Remove-Item -Path $lockPath -Force
        Write-Output "unlocked $resolvedFile [$label]"
    }
}

function Invoke-Locks {
    $expired = Remove-ExpiredLocks
    foreach ($entry in $expired) {
        Write-Warning "expired lock released: $($entry.File) [$($entry.Label)]"
    }

    Ensure-LockDir
    $locks = Get-ChildItem -Path $LockDir -Filter '*.lock' -File -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $locks -or $locks.Count -eq 0) {
        Write-Output "(no locks)"
        return
    }

    foreach ($item in $locks) {
        $info = Read-LockInfo $item.FullName
        if ($null -eq $info) { continue }
        Write-Output "$($info.label)`t$($info.file)`t$($info.acquiredAt)"
    }
}

# --- Commands ---

function Invoke-Id {
    if ($env:TMUX_PANE) {
        Write-Output $env:TMUX_PANE
    } else {
        $id = Invoke-WinsmuxRaw -Arguments @('display-message', '-p', '#{pane_id}')
        Write-Output ($id | Out-String).Trim()
    }
}

function Invoke-List {
    $raw = Invoke-WinsmuxRaw -Arguments @('list-panes', '-a', '-F', '#{pane_id} #{pane_pid} #{pane_current_command} #{pane_width}x#{pane_height} #{pane_title}')
    $labels = Get-Labels
    # Build reverse lookup: paneId -> label
    $reverseLabels = @{}
    foreach ($key in $labels.Keys) {
        $reverseLabels[$labels[$key]] = $key
    }

    $lines = ($raw | Out-String).Trim() -split "`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        # Parse pane_id and pane_pid from the line
        $parts = $trimmed -split '\s+', 5
        $paneId  = $parts[0]
        $panePid = $parts[1]

        # Detect child process name
        $childCmd = ""
        try {
            $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $panePid" -OperationTimeoutSec 10 -ErrorAction SilentlyContinue)
            if ($children) {
                $child = $children | Select-Object -First 1
                $childCmd = $child.Name
            }
        } catch {
            try {
                $children = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Parent -and $_.Parent.Id -eq [int]$panePid })
                if ($children) {
                    $child = $children | Select-Object -First 1
                    $childCmd = $child.ProcessName
                }
            } catch { }
        }

        # Build output line
        $output = $trimmed
        if ($childCmd) {
            $output += " ($childCmd)"
        }
        if ($reverseLabels.ContainsKey($paneId)) {
            $output += " [$($reverseLabels[$paneId])]"
        }
        Write-Output $output
    }
}

function Invoke-Read {
    if (-not $Target) { Stop-WithError "usage: winsmux read <target> [lines]" }

    $lines = 200
    if ($Rest -and $Rest.Count -gt 0) {
        $lines = [int]$Rest[0]
    }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    $output = Invoke-WinsmuxRaw -Arguments @('capture-pane', '-t', $paneId, '-p', '-J', '-S', "-$lines")
    $currentText = ($output | Out-String).TrimEnd()

    # Watermark-based change detection: if a watermark exists (set by send),
    # only return content when the pane buffer has actually changed.
    $wmPath = Get-WatermarkPath $paneId
    if (Test-Path $wmPath) {
        if (-not (Test-WatermarkChanged $paneId $currentText)) {
            Write-Output "[winsmux] waiting for response..."
            Set-ReadMark $paneId
            return
        }
        # Buffer changed — agent has produced new output
        Clear-Watermark $paneId
    }

    Write-Output $currentText
    Set-ReadMark $paneId
}

function Invoke-Type {
    if (-not $Target) { Stop-WithError "usage: winsmux type <target> <text>" }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux type <target> <text>" }

    $text = $Rest -join ' '
    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $paneId, '-l', '--', "$text")

    Clear-ReadMark $paneId
}

function Invoke-Keys {
    if (-not $Target) { Stop-WithError "usage: winsmux keys <target> <key>..." }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux keys <target> <key>..." }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    foreach ($key in $Rest) {
        Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $paneId, $key)
    }

    Clear-ReadMark $paneId
}

function Invoke-Message {
    if (-not $Target) { Stop-WithError "usage: winsmux message <target> <text>" }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux message <target> <text>" }

    $text = $Rest -join ' '
    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    $myId = (Invoke-WinsmuxRaw -Arguments @('display-message', '-p', '#{pane_id}') | Out-String).Trim()
    $myCoord = (Invoke-WinsmuxRaw -Arguments @('display-message', '-p', '#{session_name}:#{window_index}.#{pane_index}') | Out-String).Trim()
    $agentName = if ($env:WINSMUX_AGENT_NAME) { $env:WINSMUX_AGENT_NAME } else { "unknown" }

    $header = "[winsmux from:$agentName pane:$myId at:$myCoord -- load the winsmux skill to reply]"
    Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $paneId, '-l', '--', "$header $text")

    Clear-ReadMark $paneId
}

function Get-SendConfigValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = ''
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }

        return $Default
    }

    if ($null -ne $InputObject.PSObject -and ($InputObject.PSObject.Properties.Name -contains $Name)) {
        return $InputObject.$Name
    }

    return $Default
}

function Get-WorkersLaunchApprovalFieldNames {
    return @(
        'slot_id',
        'worker_backend',
        'worker_role',
        'agent',
        'model',
        'model_source',
        'reasoning_effort',
        'prompt_transport',
        'auth_mode',
        'credential_requirements',
        'execution_profile',
        'execution_backend',
        'analysis_posture',
        'auto_launch'
    )
}

function ConvertTo-WorkersLaunchApprovalValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [bool]) {
        if ($Value) {
            return 'true'
        }

        return 'false'
    }

    return ([string]$Value).Trim()
}

function Get-WorkersLaunchApprovalDefaultValue {
    param([Parameter(Mandatory = $true)][string]$Field)

    switch ($Field) {
        'execution_profile' { return 'local-windows' }
        default { return '' }
    }
}

function New-WorkersLaunchApprovalSummary {
    param(
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)]$SlotConfig,
        [bool]$AutoLaunch = $false
    )

    return [ordered]@{
        packet_type             = 'worker_launch_approval'
        source                  = 'user_approved_worker_config'
        slot_id                 = $SlotId
        worker_backend          = [string]$SlotConfig.WorkerBackend
        worker_role             = [string]$SlotConfig.WorkerRole
        agent                   = [string]$SlotConfig.Agent
        model                   = [string]$SlotConfig.Model
        model_source            = [string]$SlotConfig.ModelSource
        reasoning_effort        = [string]$SlotConfig.ReasoningEffort
        prompt_transport        = [string]$SlotConfig.PromptTransport
        auth_mode               = [string]$SlotConfig.AuthMode
        credential_requirements = [string]$SlotConfig.CredentialRequirements
        execution_profile       = [string]$SlotConfig.ExecutionProfile
        execution_backend       = [string]$SlotConfig.ExecutionBackend
        analysis_posture        = [string]$SlotConfig.AnalysisPosture
        auto_launch             = [bool]$AutoLaunch
    }
}

function Get-WorkersLaunchApprovalDifferences {
    param(
        [AllowNull()]$ApprovedLaunch,
        [AllowNull()]$CurrentLaunch
    )

    if ($null -eq $ApprovedLaunch) {
        return @()
    }

    if ($null -eq $CurrentLaunch) {
        return @([ordered]@{
            field    = 'approved_launch'
            approved = 'present'
            current  = 'missing'
        })
    }

    $differences = [System.Collections.Generic.List[object]]::new()
    foreach ($field in @(Get-WorkersLaunchApprovalFieldNames)) {
        $defaultValue = Get-WorkersLaunchApprovalDefaultValue -Field $field
        $approvedValue = ConvertTo-WorkersLaunchApprovalValue (Get-SendConfigValue -InputObject $ApprovedLaunch -Name $field -Default $defaultValue)
        $currentValue = ConvertTo-WorkersLaunchApprovalValue (Get-SendConfigValue -InputObject $CurrentLaunch -Name $field -Default $defaultValue)
        if (-not [string]::Equals($approvedValue, $currentValue, [System.StringComparison]::Ordinal)) {
            $differences.Add([ordered]@{
                field    = $field
                approved = $approvedValue
                current  = $currentValue
            }) | Out-Null
        }
    }

    return @($differences)
}

function Format-WorkersLaunchApprovalMismatch {
    param([Parameter(Mandatory = $true)][object[]]$Differences)

    $summary = @($Differences | Select-Object -First 4 | ForEach-Object {
        "$($_.field): approved='$($_.approved)' current='$($_.current)'"
    }) -join '; '
    if ($Differences.Count -gt 4) {
        $summary = "$summary; +$($Differences.Count - 4) more"
    }

    return "worker launch approval mismatch: $summary"
}

function Test-DeferredPaneStartManifestEntry {
    param([AllowNull()]$ManifestEntry)

    if ($null -eq $ManifestEntry) {
        return $false
    }

    $status = [string](Get-SendConfigValue -InputObject $ManifestEntry -Name 'Status' -Default '')
    if ([string]::IsNullOrWhiteSpace($status)) {
        return $false
    }

    return @('deferred_start', 'deferred_starting', 'deferred_start_failed', 'backend_degraded') -contains $status.Trim().ToLowerInvariant()
}

function Set-DeferredPaneStartStatus {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowEmptyString()][string]$MarkerPath = ''
    )

    if (-not (Get-Command Set-PaneControlManifestPaneProperties -ErrorAction SilentlyContinue)) {
        return
    }

    $manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
    $properties = [ordered]@{
        status = $Status
    }
    if (-not [string]::IsNullOrWhiteSpace($MarkerPath)) {
        $properties['bootstrap_marker_path'] = $MarkerPath
    }

    Set-PaneControlManifestPaneProperties -ManifestPath $manifestPath -PaneId $PaneId -Properties $properties
}

function Wait-DeferredPaneReady {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [AllowEmptyString()][string]$Agent = '',
        [int]$TimeoutSeconds = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-AgentReadyPrompt -PaneId $PaneId -Agent $Agent) {
            return
        }

        Start-Sleep -Seconds 1
    }

    Stop-WithError "timed out waiting for deferred pane $PaneId to become ready"
}

function Start-DeferredPaneFromManifestEntry {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [AllowNull()]$ManifestEntry
    )

    if (-not (Test-DeferredPaneStartManifestEntry -ManifestEntry $ManifestEntry)) {
        return $false
    }

    $label = [string](Get-SendConfigValue -InputObject $ManifestEntry -Name 'Label' -Default '')
    $paneId = [string](Get-SendConfigValue -InputObject $ManifestEntry -Name 'PaneId' -Default '')
    if ([string]::IsNullOrWhiteSpace($paneId)) {
        Stop-WithError "deferred pane '$label' is missing pane id"
    }

    $status = [string](Get-SendConfigValue -InputObject $ManifestEntry -Name 'Status' -Default '')
    $normalizedStatus = $status.Trim().ToLowerInvariant()
    if ($normalizedStatus -eq 'backend_degraded') {
        $colabSession = Get-SendConfigValue -InputObject $ManifestEntry -Name 'ColabSession' -Default $null
        $reason = [string](Get-SendConfigValue -InputObject $colabSession -Name 'degraded_reason' -Default '')
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = 'backend_degraded'
        }
        Stop-WithError "worker backend for '$label' is degraded: $reason"
    }

    $readinessAgent = ConvertTo-ReadinessAgentName ([string](Get-SendConfigValue -InputObject $ManifestEntry -Name 'CapabilityAdapter' -Default ''))
    if ([string]::IsNullOrWhiteSpace($readinessAgent)) {
        $readinessAgent = ConvertTo-ReadinessAgentName ([string](Get-SendConfigValue -InputObject $ManifestEntry -Name 'ProviderTarget' -Default ''))
    }

    if ($normalizedStatus -eq 'deferred_start_failed') {
        try {
            if (Test-AgentReadyPrompt -PaneId $paneId -Agent $readinessAgent) {
                Set-DeferredPaneStartStatus -ProjectDir $ProjectDir -PaneId $paneId -Status 'ready'
                return $true
            }
        } catch {
            # Fall through to the bootstrap retry path when the pane cannot be probed.
        }
    }

    $planPath = [string](Get-SendConfigValue -InputObject $ManifestEntry -Name 'BootstrapPlanPath' -Default '')
    if ([string]::IsNullOrWhiteSpace($planPath)) {
        Set-DeferredPaneStartStatus -ProjectDir $ProjectDir -PaneId $paneId -Status 'deferred_start_failed'
        Stop-WithError "deferred pane '$label' is missing bootstrap plan path"
    }
    if (-not [System.IO.Path]::IsPathRooted($planPath)) {
        $planPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectDir $planPath))
    }
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        Set-DeferredPaneStartStatus -ProjectDir $ProjectDir -PaneId $paneId -Status 'deferred_start_failed'
        Stop-WithError "deferred pane '$label' bootstrap plan not found: $planPath"
    }

    $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 8
    $approvedLaunch = Get-SendConfigValue -InputObject $ManifestEntry -Name 'ApprovedLaunch' -Default $null
    $candidateLaunch = Get-SendConfigValue -InputObject $plan -Name 'approved_launch' -Default $null
    $approvalDifferences = @(Get-WorkersLaunchApprovalDifferences -ApprovedLaunch $approvedLaunch -CurrentLaunch $candidateLaunch)
    if ($approvalDifferences.Count -gt 0) {
        Set-DeferredPaneStartStatus -ProjectDir $ProjectDir -PaneId $paneId -Status 'deferred_start_failed'
        Stop-WithError (Format-WorkersLaunchApprovalMismatch -Differences $approvalDifferences)
    }

    $markerPath = [string](Get-SendConfigValue -InputObject $plan -Name 'ready_marker_path' -Default '')

    if (@('deferred_start', 'deferred_start_failed') -contains $normalizedStatus) {
        Set-DeferredPaneStartStatus -ProjectDir $ProjectDir -PaneId $paneId -Status 'deferred_starting' -MarkerPath $markerPath
        $bootstrapScriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\orchestra-pane-bootstrap.ps1'))
        $bootstrapCommand = "pwsh -NoProfile -File {0} -PlanFile {1}" -f `
            (ConvertTo-DispatchPowerShellLiteral -Value $bootstrapScriptPath), `
            (ConvertTo-DispatchPowerShellLiteral -Value $planPath)

        Wait-PaneShellReady -PaneId $paneId -TimeoutSeconds 30
        Send-TextToPane -PaneId $paneId -CommandText $bootstrapCommand | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($readinessAgent)) {
        $readinessAgent = ConvertTo-ReadinessAgentName ([string](Get-SendConfigValue -InputObject $plan -Name 'agent' -Default ''))
    }

    try {
        Wait-DeferredPaneReady -PaneId $paneId -Agent $readinessAgent -TimeoutSeconds 90
        Set-DeferredPaneStartStatus -ProjectDir $ProjectDir -PaneId $paneId -Status 'ready' -MarkerPath $markerPath
        return $true
    } catch {
        Set-DeferredPaneStartStatus -ProjectDir $ProjectDir -PaneId $paneId -Status 'deferred_start_failed' -MarkerPath $markerPath
        throw
    }
}

function Invoke-Send {
    if (-not $Target) { Stop-WithError "usage: winsmux send <target> <text>" }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux send <target> <text>" }

    $taskSlug = ''
    $messageParts = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $Rest.Count; $index++) {
        $token = [string]$Rest[$index]
        if ($token -eq '--task-slug') {
            if ($index + 1 -ge $Rest.Count) {
                Stop-WithError "--task-slug requires a value"
            }

            $index++
            $taskSlug = [string]$Rest[$index]
            continue
        }

        $messageParts.Add($token) | Out-Null
    }

    if ($messageParts.Count -lt 1) {
        Stop-WithError "usage: winsmux send <target> <text>"
    }

    # Normalize Git Bash /tmp paths before dispatching PowerShell-oriented commands.
    $text = Normalize-DispatchText -Text ($messageParts -join ' ')
    $projectDir = (Get-Location).Path
    $paneId = Resolve-Target $Target
    if ((Resolve-TerminalBackend) -eq 'cli') {
        $paneId = Confirm-Target $paneId
    }
    $context = $null
    $agentConfig = [ordered]@{
        Agent           = 'codex'
        Model           = ''
        PromptTransport = 'argv'
    }
    $execMode = $false

    try {
        if (Test-Path $PaneControlScript -PathType Leaf) {
            . $PaneControlScript
        }

        if (Test-Path $BridgeSettingsScript -PathType Leaf) {
            . $BridgeSettingsScript
        }
    } catch {
    }

    $hasManifestHelper = Get-Command Get-PaneControlManifestContext -ErrorAction SilentlyContinue
    $hasRoleConfigHelper = Get-Command Get-RoleAgentConfig -ErrorAction SilentlyContinue
    $manifestPath = Join-Path $projectDir '.winsmux\manifest.yaml'
    if ($null -ne $hasManifestHelper -and $null -ne $hasRoleConfigHelper -and (Test-Path $manifestPath -PathType Leaf)) {
        try {
            $context = Get-PaneControlManifestContext -ProjectDir $projectDir -PaneId $paneId
            if ($null -ne $context -and -not [string]::IsNullOrWhiteSpace([string]$context.ManifestPath)) {
                $manifestContent = Get-Content -LiteralPath $context.ManifestPath -Raw -Encoding UTF8
                $manifest = ConvertFrom-PaneControlManifestContent -Content $manifestContent
                $manifestPane = $null
                if ($null -ne $manifest -and $null -ne $manifest.Panes -and $manifest.Panes.Contains([string]$context.Label)) {
                    $manifestPane = $manifest.Panes[[string]$context.Label]
                }

                if (Get-Command Get-SlotAgentConfig -ErrorAction SilentlyContinue) {
                    $agentConfig = Get-SlotAgentConfig -Role $context.Role -SlotId $context.Label -RootPath $projectDir
                } else {
                    $agentConfig = Get-RoleAgentConfig -Role $context.Role
                }

                $execModeValue = ''
                if ($null -ne $manifestPane) {
                    if ($manifestPane -is [System.Collections.IDictionary] -and $manifestPane.Contains('exec_mode')) {
                        $execModeValue = [string]$manifestPane['exec_mode']
                    } elseif ($null -ne $manifestPane.PSObject -and $manifestPane.PSObject.Properties.Name -contains 'exec_mode') {
                        $execModeValue = [string]$manifestPane.exec_mode
                    }
                }

                $capabilityAdapter = [string](Get-SendConfigValue -InputObject $agentConfig -Name 'CapabilityAdapter' -Default '')
                if ([string]::IsNullOrWhiteSpace($capabilityAdapter)) {
                    $capabilityAdapter = [string]$agentConfig.Agent
                }
                $execModeAgent = ConvertTo-ReadinessAgentName $capabilityAdapter
                $execMode = $execModeValue.Trim().ToLowerInvariant() -eq 'true' -and $execModeAgent -eq 'codex'
            }
        } catch {
            if ($_.Exception.Message -match 'Provider capability') {
                throw
            }
        }
    }

    if ($null -ne $context -and $null -ne $context.SecurityPolicy) {
        $policyViolation = Find-SendSecurityPolicyViolation -Text $text -SecurityPolicy $context.SecurityPolicy
        if ($null -ne $policyViolation) {
            $eventRecord = [ordered]@{
                timestamp = [System.DateTimeOffset]::Now.ToString('o')
                session   = [string]$context.SessionName
                event     = 'security.policy.blocked'
                message   = [string]$policyViolation['reason']
                label     = [string]$context.Label
                pane_id   = [string]$context.PaneId
                role      = [string]$context.Role
                branch    = [string]$context.Branch
                head_sha  = [string]$context.HeadSha
                data      = [ordered]@{
                    verdict     = [string]$policyViolation['verdict']
                    reason      = [string]$policyViolation['reason']
                    pattern     = [string]$policyViolation['pattern']
                    mode        = [string]$policyViolation['mode']
                    allow       = @($policyViolation['allow'])
                    block       = @($policyViolation['block'])
                    next_action = [string]$policyViolation['next_action']
                    target      = $Target
                }
            }
            Write-BridgeEventRecord -ProjectDir $projectDir -EventRecord $eventRecord | Out-Null
            Stop-WithError ([string]$policyViolation['reason'])
        }
    }

    Start-DeferredPaneFromManifestEntry -ProjectDir $projectDir -ManifestEntry $context | Out-Null

    $contextLaunchDir = $projectDir
    $contextGitWorktreeDir = ''
    if ($null -ne $context) {
        if ($context -is [System.Collections.IDictionary]) {
            if ($context.Contains('LaunchDir')) {
                $contextLaunchDir = [string]$context['LaunchDir']
            }
            if ($context.Contains('GitWorktreeDir')) {
                $contextGitWorktreeDir = [string]$context['GitWorktreeDir']
            }
        } else {
            if ($null -ne $context.PSObject -and $context.PSObject.Properties.Name -contains 'LaunchDir') {
                $contextLaunchDir = [string]$context.LaunchDir
            }
            if ($null -ne $context.PSObject -and $context.PSObject.Properties.Name -contains 'GitWorktreeDir') {
                $contextGitWorktreeDir = [string]$context.GitWorktreeDir
            }
        }
    }

    $transportPlan = Resolve-SendTransportPlan `
        -Text $text `
        -ProjectDir $projectDir `
        -LengthLimit 4000 `
        -PromptTransport ([string]$agentConfig.PromptTransport) `
        -TaskSlug $taskSlug `
        -ExecMode:$execMode `
        -LaunchDir $contextLaunchDir `
        -GitWorktreeDir $contextGitWorktreeDir `
        -Model ([string]$agentConfig.Model) `
        -ExecCommand ([string](Get-SendConfigValue -InputObject $agentConfig -Name 'CapabilityCommand' -Default $agentConfig.Agent))

    if ($transportPlan['Mode'] -eq 'codex_exec_file') {
        Send-TextToPane -PaneId $paneId -CommandText ([string]$transportPlan['ExecInstruction'])
        return
    }

    if ($transportPlan['IsFileBacked']) {
        Write-Warning ("send target '{0}' used prompt_transport={1}; wrote full text to {2} and sent a prompt-file pointer instead." -f $Target, $transportPlan['PromptTransport'], $transportPlan['PromptPath'])
    }

    Send-TextToPane -PaneId $paneId -CommandText ([string]$transportPlan['TextToSend']) -PromptTransport ([string]$transportPlan['PromptTransport'])
}

function Invoke-Name {
    if (-not $Target) { Stop-WithError "usage: winsmux name <target> <label>" }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux name <target> <label>" }

    $label = $Rest[0]
    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    $labels = Get-Labels
    $labels[$label] = $paneId
    Save-Labels $labels

    # Also set pane title (best-effort)
    try {
        Invoke-WinsmuxRaw -Arguments @('select-pane', '-t', $paneId, '-T', "$label") 2>$null
    } catch { }

    Write-Output "Labeled pane $paneId as '$label'"
}

function Invoke-Resolve {
    if (-not $Target) { Stop-WithError "usage: winsmux resolve <label>" }

    $labels = Get-Labels
    if ($labels.ContainsKey($Target)) {
        Write-Output $labels[$Target]
    } else {
        Stop-WithError "label not found: $Target"
    }
}

function Invoke-AutoRebalance {
    $projectDir = (Get-Location).Path
    $manifestPath = Join-Path $projectDir ".winsmux\manifest.yaml"
    if (-not (Test-Path $manifestPath)) {
        Stop-WithError "manifest not found: $manifestPath"
    }

    $labels = Get-Labels
    $builderLabels = @($labels.Keys | Where-Object { $_ -match '^builder-' })

    $idleBuilders = @()
    foreach ($label in $builderLabels) {
        $paneId = $labels[$label]
        $snapshot = (Invoke-WinsmuxRaw -Arguments @('capture-pane', '-t', $paneId, '-p') 2>$null | Out-String).TrimEnd()
        $lastLine = ($snapshot -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        $isIdle = $lastLine -and ($lastLine.Trim() -match '\d+% left' -or $lastLine.Trim() -match '^[>›]')
        if ($isIdle) { $idleBuilders += $label }
    }

    $queueDepth = 0
    try {
        $queueScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\builder-queue.ps1'))
        if (Test-Path $queueScript) {
            $out = & pwsh -NoProfile -File $queueScript -Action list -ProjectDir $projectDir -BuilderLabel '' -AsJson 2>$null
            if ($out) { $parsed = $out | ConvertFrom-Json -ErrorAction SilentlyContinue; if ($parsed) { $queueDepth = @($parsed.Queued).Count } }
        }
    } catch {}

    $suggestion = if ($queueDepth -gt 0) { "キューにタスクあり — Builder 維持" }
                  elseif ($idleBuilders.Count -gt 0) { "アイドル $($idleBuilders.Count) 台を Worker に切替可能" }
                  else { "全 Builder 稼働中" }

    Write-Output "アイドル Builder: $($idleBuilders.Count)/$($builderLabels.Count)"
    Write-Output "キュー深度: $queueDepth"
    Write-Output "提案: $suggestion"
    if ($idleBuilders.Count -gt 0) { Write-Output "アイドル: $($idleBuilders -join ', ')" }
}

function Invoke-Role {
    if (-not $Target -or -not $Rest -or $Rest.Count -lt 1) {
        Stop-WithError "usage: winsmux role <pane_label_or_id> <new_role>`n  roles: worker, builder, researcher, reviewer"
    }

    $newRole = $Rest[0].Trim().ToLowerInvariant()
    if ($newRole -notin @('worker', 'builder', 'researcher', 'reviewer')) {
        Stop-WithError "invalid role: $newRole. Must be worker, builder, researcher, or reviewer."
    }

    # Resolve pane ID
    $paneId = $Target
    $labels = Get-Labels
    if ($labels.ContainsKey($Target)) {
        $paneId = $labels[$Target]
    } elseif ($Target -notmatch '^%\d+$') {
        Stop-WithError "unknown pane: $Target"
    }

    # Read manifest to find current label
    $projectDir = (Get-Location).Path
    $manifestPath = Join-Path $projectDir ".winsmux\manifest.yaml"
    $oldLabel = $Target

    # Count existing panes with new role to generate label number
    $existingLabels = @()
    if (Test-Path $manifestPath) {
        try {
            $manifest = Get-WinsmuxManifest -ProjectDir $projectDir
            if ($null -ne $manifest -and $null -ne $manifest.panes) {
                $existingLabels = @(
                    foreach ($label in $manifest.panes.Keys) {
                        if ([string]$label -match ("^{0}-\d+$" -f [regex]::Escape($newRole))) {
                            [string]$label
                        }
                    }
                )
            }
        } catch {
            $existingLabels = @()
        }
    }
    $nextNum = 1
    while ("$newRole-$nextNum" -in $existingLabels) { $nextNum++ }
    $newLabel = "$newRole-$nextNum"

    $manifestEntry = $null
    if ((Test-Path $manifestPath -PathType Leaf) -and
        (Get-Command Get-PaneControlManifestEntries -ErrorAction SilentlyContinue)) {
        $manifestEntry = @(Get-PaneControlManifestEntries -ProjectDir $projectDir | Where-Object {
            [string]::Equals([string]$_.PaneId, $paneId, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($manifestEntry.Count -gt 0) {
            $manifestEntry = $manifestEntry[0]
        } else {
            $manifestEntry = $null
        }
    }
    $launchDir = $projectDir
    if ($null -ne $manifestEntry -and -not [string]::IsNullOrWhiteSpace([string]$manifestEntry.LaunchDir)) {
        $launchDir = [string]$manifestEntry.LaunchDir
    } elseif ($null -ne $manifestEntry -and -not [string]::IsNullOrWhiteSpace([string]$manifestEntry.BuilderWorktreePath)) {
        $launchDir = [string]$manifestEntry.BuilderWorktreePath
    }
    $gitDir = Join-Path $launchDir ".git"
    if ($null -ne $manifestEntry -and -not [string]::IsNullOrWhiteSpace([string]$manifestEntry.GitWorktreeDir)) {
        $gitDir = [string]$manifestEntry.GitWorktreeDir
    }
    $settings = Get-BridgeSettings -RootPath $projectDir
    if (Get-Command Get-SlotAgentConfig -ErrorAction SilentlyContinue) {
        $roleAgentConfig = Get-SlotAgentConfig -Role $newRole -SlotId $newLabel -Settings $settings -RootPath $projectDir
    } else {
        $roleAgentConfig = Get-RoleAgentConfig -Role $newRole -Settings $settings -RootPath $projectDir
    }
    $manifestRole = switch ($newRole) {
        'worker' { 'Worker' }
        'builder' { 'Builder' }
        'researcher' { 'Researcher' }
        'reviewer' { 'Reviewer' }
        default { $newRole }
    }
    if ($manifestRole -notin @('Builder', 'Worker')) {
        $launchDir = $projectDir
        if (Get-Command Get-PaneControlGitWorktreeDir -ErrorAction SilentlyContinue) {
            $gitDir = Get-PaneControlGitWorktreeDir -ProjectDir $projectDir
        } else {
            $gitDir = Join-Path $projectDir ".git"
        }
    }
    $launchCmd = Get-BridgeProviderLaunchCommand `
        -ProviderId ([string]$roleAgentConfig.Agent) `
        -Model ([string]$roleAgentConfig.Model) `
        -ModelSource ([string]$roleAgentConfig.ModelSource) `
        -ReasoningEffort ([string]$roleAgentConfig.ReasoningEffort) `
        -ProjectDir $launchDir `
        -GitWorktreeDir $gitDir `
        -RootPath $projectDir
    $providerTarget = [string]$roleAgentConfig.Agent
    $providerModelSource = [string]$roleAgentConfig.ModelSource
    if ([string]::IsNullOrWhiteSpace($providerModelSource)) {
        $providerModelSource = 'provider-default'
    }
    $hasModelOverride = (-not [string]::IsNullOrWhiteSpace([string]$roleAgentConfig.Model)) -and
        (-not [string]::Equals(([string]$roleAgentConfig.Model).Trim(), 'provider-default', [System.StringComparison]::OrdinalIgnoreCase)) -and
        (-not [string]::Equals($providerModelSource.Trim(), 'provider-default', [System.StringComparison]::OrdinalIgnoreCase))
    if ($hasModelOverride) {
        $providerTarget = "${providerTarget}:$([string]$roleAgentConfig.Model)"
    }

    # Rename pane first (before respawn)
    Invoke-WinsmuxRaw -Arguments @('select-pane', '-t', $paneId, '-T', $newLabel)

    # Update labels
    $labels[$newLabel] = $paneId
    if ($labels.ContainsKey($oldLabel)) { $labels.Remove($oldLabel) }
    Save-Labels $labels

    if ((Test-Path $manifestPath -PathType Leaf) -and
        (Get-Command Set-PaneControlManifestPaneProperties -ErrorAction SilentlyContinue)) {
        $manifestProperties = [ordered]@{
            label                      = $newLabel
            role                       = $manifestRole
            launch_dir                 = $launchDir
            worktree_git_dir           = $gitDir
            provider_target            = $providerTarget
            capability_adapter         = [string]$roleAgentConfig.CapabilityAdapter
            capability_command         = [string]$roleAgentConfig.CapabilityCommand
            harness_availability       = [string]$roleAgentConfig.HarnessAvailability
            credential_requirements    = [string]$roleAgentConfig.CredentialRequirements
            execution_backend          = [string]$roleAgentConfig.ExecutionBackend
            runtime_requirements       = [string]$roleAgentConfig.RuntimeRequirements
            analysis_posture           = [string]$roleAgentConfig.AnalysisPosture
            supports_parallel_runs     = [bool]$roleAgentConfig.SupportsParallelRuns
            supports_interrupt         = [bool]$roleAgentConfig.SupportsInterrupt
            supports_structured_result = [bool]$roleAgentConfig.SupportsStructuredResult
            supports_file_edit         = [bool]$roleAgentConfig.SupportsFileEdit
            supports_subagents         = [bool]$roleAgentConfig.SupportsSubagents
            supports_verification      = [bool]$roleAgentConfig.SupportsVerification
            supports_consultation      = [bool]$roleAgentConfig.SupportsConsultation
            supports_context_reset     = [bool]$roleAgentConfig.SupportsContextReset
        }
        if ($manifestRole -notin @('Builder', 'Worker')) {
            $manifestProperties['builder_worktree_path'] = ''
            $manifestProperties['builder_branch'] = ''
        }
        Set-PaneControlManifestPaneProperties -ManifestPath $manifestPath -PaneId $paneId -Properties $manifestProperties
    }

    $sessionName = [string]$env:WINSMUX_ORCHESTRA_SESSION
    try {
        $manifestForEnvironment = Get-WinsmuxManifest -ProjectDir $projectDir
        $manifestSessionName = [string](Get-PaneControlValue -InputObject $manifestForEnvironment.session -Name 'name' -Default '')
        if ([string]::IsNullOrWhiteSpace($sessionName)) {
            $sessionName = $manifestSessionName
        }
    } catch {
    }

    $transientEnvironmentNames = @()
    if (-not [string]::IsNullOrWhiteSpace($sessionName) -and
        (Get-Command Get-WinsmuxPaneEnvironment -ErrorAction SilentlyContinue)) {
        $persistentEnvironmentNames = @('WINSMUX_ORCHESTRA_SESSION', 'WINSMUX_ORCHESTRA_PROJECT_DIR', 'WINSMUX_ROLE_MAP', 'WINSMUX_HOOK_PROFILE', 'WINSMUX_GOVERNANCE_MODE')
        if (Get-Command Get-WinsmuxEnvironmentVariableNames -ErrorAction SilentlyContinue) {
            $transientEnvironmentNames = @(Get-WinsmuxEnvironmentVariableNames | Where-Object { $_ -notin $persistentEnvironmentNames })
        } else {
            $transientEnvironmentNames = @(
                'WINSMUX_ROLE',
                'WINSMUX_PANE_ID',
                'WINSMUX_BUILDER_WORKTREE',
                'WINSMUX_ASSIGNED_WORKTREE',
                'WINSMUX_ASSIGNED_BRANCH',
                'WINSMUX_WORKTREE_GITDIR',
                'WINSMUX_SLOT_ID',
                'WINSMUX_EXPECTED_ORIGIN'
            )
        }
        foreach ($name in $transientEnvironmentNames) {
            try {
                Invoke-WinsmuxRaw -Arguments @('set-environment', '-u', '-t', $sessionName, $name)
            } catch {
            }
        }
        $roleMap = [ordered]@{}
        try {
            foreach ($entry in @(Get-PaneControlManifestEntries -ProjectDir $projectDir)) {
                if ([string]::IsNullOrWhiteSpace([string]$entry.PaneId)) {
                    continue
                }

                $roleMap[[string]$entry.PaneId] = [string]$entry.Role
            }
        } catch {
        }
        $roleMap[[string]$paneId] = $manifestRole
        $roleMapJson = ($roleMap | ConvertTo-Json -Compress)
        $builderWorktreePath = ''
        $assignedBranch = ''
        $environmentGitDir = ''
        if ($manifestRole -in @('Builder', 'Worker') -and $null -ne $manifestEntry) {
            $builderWorktreePath = [string]$manifestEntry.BuilderWorktreePath
            $assignedBranch = [string]$manifestEntry.BuilderBranch
            $environmentGitDir = $gitDir
        }
        $paneEnvironment = Get-WinsmuxPaneEnvironment `
            -Role $manifestRole `
            -PaneId $paneId `
            -SessionName $sessionName `
            -ProjectDir $projectDir `
            -RoleMapJson $roleMapJson `
            -BuilderWorktreePath $builderWorktreePath `
            -SlotId $newLabel `
            -AssignedBranch $assignedBranch `
            -GitWorktreeDir $environmentGitDir
        foreach ($entry in $paneEnvironment.GetEnumerator()) {
            Invoke-WinsmuxRaw -Arguments @('set-environment', '-t', $sessionName, ([string]$entry.Key), ([string]$entry.Value))
            if ($entry.Key -notin $persistentEnvironmentNames -and $entry.Key -notin $transientEnvironmentNames) {
                $transientEnvironmentNames += [string]$entry.Key
            }
        }
    }

    try {
        # Respawn pane (kills current process + restarts shell in one step, #174)
        Invoke-WinsmuxRaw -Arguments @('respawn-pane', '-k', '-t', $paneId, '-c', $launchDir)

        # Wait for shell ready (poll for PS prompt)
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            $snapshot = (Invoke-WinsmuxRaw -Arguments @('capture-pane', '-t', $paneId, '-p') 2>$null | Out-String).TrimEnd()
            $lastLine = ($snapshot -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
            if ($lastLine -and $lastLine.Trim() -match '^PS ') { break }
            Start-Sleep -Milliseconds 500
        }

        Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $paneId, '-l', $launchCmd)
        Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $paneId, 'Enter')
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($sessionName)) {
            foreach ($name in @($transientEnvironmentNames | Select-Object -Unique)) {
                try {
                    Invoke-WinsmuxRaw -Arguments @('set-environment', '-u', '-t', $sessionName, $name)
                } catch {
                }
            }
        }
    }

    Write-Output "Role changed: $oldLabel -> $newLabel ($paneId)"
}

function Invoke-Verify {
    if (-not $Target) { Stop-WithError "usage: winsmux verify <pr-number>" }
    if ($Rest -and $Rest.Count -gt 0) { Stop-WithError "usage: winsmux verify <pr-number>" }

    $prNumber = $Target
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $testsDir = Join-Path $repoRoot 'tests'

    if (-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
        Stop-WithError "Invoke-Pester not found. Install/import Pester before running verify."
    }

    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        Stop-WithError "pwsh not found. Install PowerShell 7 before running verify."
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Stop-WithError "gh CLI not found. Install GitHub CLI before running verify."
    }

    $githubPreflightScript = Join-Path $repoRoot 'winsmux-core\scripts\github-write-preflight.ps1'
    if (Test-Path -LiteralPath $githubPreflightScript -PathType Leaf) {
        & pwsh -NoProfile -File $githubPreflightScript -Repository 'Sora-bluesky/winsmux' -RequireGh
        $preflightExitCode = Get-SafeLastExitCode
        if ($null -ne $preflightExitCode -and $preflightExitCode -ne 0) {
            exit $preflightExitCode
        }
    }

    if (-not (Test-Path -LiteralPath $testsDir -PathType Container)) {
        Stop-WithError "tests directory not found: $testsDir"
    }

    $testFiles = Get-ChildItem -Path $testsDir -Recurse -File -Include '*.Tests.ps1','*.ps1' |
        Sort-Object FullName

    if (-not $testFiles -or $testFiles.Count -eq 0) {
        Stop-WithError "no test files found under $testsDir"
    }

    Write-Output "Running Pester tests from $testsDir"
    $pesterCommand = @'
$config = New-PesterConfiguration
$config.Run.Path = @("tests/")
$config.Run.Exit = $true
$config.Output.Verbosity = "Detailed"
Invoke-Pester -Configuration $config
'@
    $encodedPesterCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pesterCommand))
    Push-Location $repoRoot
    try {
        & pwsh -NoProfile -EncodedCommand $encodedPesterCommand
        $pesterExitCode = Get-SafeLastExitCode
    } finally {
        Pop-Location
    }

    if ($null -ne $pesterExitCode -and $pesterExitCode -ne 0) {
        Stop-WithError "Pester verify failed with exit code $pesterExitCode."
    }

    Write-Output "Pester PASS. Merging PR #$prNumber"
    & gh pr merge $prNumber --squash --delete-branch
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        exit $nativeExitCode
    }
}

function Invoke-Doctor {
    Write-Output "=== winsmux doctor ==="

    # winsmux binary check
    try {
        $ver = Invoke-WinsmuxRaw -Arguments @('-V') 2>&1
        Write-Output "winsmux: $($ver | Out-String)".Trim()
    } catch {
        Write-Output "winsmux: NOT FOUND"
    }

    # TMUX_PANE
    if ($env:TMUX_PANE) {
        Write-Output "TMUX_PANE: $env:TMUX_PANE"
    } else {
        Write-Output "TMUX_PANE: (not set)"
    }

    # WINSMUX_AGENT_NAME
    if ($env:WINSMUX_AGENT_NAME) {
        Write-Output "WINSMUX_AGENT_NAME: $env:WINSMUX_AGENT_NAME"
    } else {
        Write-Output "WINSMUX_AGENT_NAME: (not set)"
    }

    # Pane count
    try {
        $panes = Invoke-WinsmuxRaw -Arguments @('list-panes', '-a', '-F', '#{pane_id}')
        $count = (($panes | Out-String).Trim() -split "`n" | Where-Object { $_.Trim() }).Count
        Write-Output "Panes: $count"
    } catch {
        Write-Output "Panes: (error listing)"
    }

    # Labels
    $labels = Get-Labels
    Write-Output "Labels: $($labels.Count) in $LabelsFile"

    # Read marks
    if (Test-Path $ReadMarkDir) {
        $marks = (Get-ChildItem -Path $ReadMarkDir -File).Count
        Write-Output "Read marks: $marks in $ReadMarkDir"
    } else {
        Write-Output "Read marks: 0 (directory not created yet)"
    }

    # IME diagnostics
    Write-Output ""
    Write-Output "=== IME diagnostics ==="

    # escape-time check
    try {
        $escTime = (Invoke-WinsmuxRaw -Arguments @('show-options', '-g', '-v', 'escape-time') 2>&1 | Out-String).Trim()
        if ($escTime -match '^\d+$' -and [int]$escTime -gt 50) {
            Write-Output "escape-time: $escTime ms [WARNING: >50ms causes IME lag. Set to 0 in .winsmux.conf]"
        } else {
            Write-Output "escape-time: $escTime ms [OK]"
        }
    } catch {
        Write-Output "escape-time: (could not read)"
    }

    # Windows Terminal atlas engine check
    $wtSettingsPath = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    if (Test-Path $wtSettingsPath) {
        try {
            $wtSettings = Get-Content -Path $wtSettingsPath -Raw | ConvertFrom-Json
            $atlasEngine = $wtSettings.profiles.defaults.useAtlasEngine
            if ($null -eq $atlasEngine) {
                Write-Output "WT useAtlasEngine: not set [TIP: set to false for better CJK IME]"
            } elseif ($atlasEngine -eq $true) {
                Write-Output "WT useAtlasEngine: true [WARNING: disable for better CJK IME]"
            } else {
                Write-Output "WT useAtlasEngine: false [OK]"
            }
        } catch {
            Write-Output "WT settings: (parse error)"
        }
    } else {
        Write-Output "WT settings: not found (not using Windows Terminal?)"
    }

    # Clipboard image test
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $img = [System.Windows.Forms.Clipboard]::GetImage()
        if ($img) {
            Write-Output "Clipboard image: available ($($img.Width)x$($img.Height))"
            $img.Dispose()
        } else {
            Write-Output "Clipboard image: none"
        }
    } catch {
        Write-Output "Clipboard image: (check failed)"
    }

    # TASK-116: Startup diagnostics
    Write-Output ""
    Write-Output "=== Startup diagnostics ==="

    # Codex sandbox
    $codexConfig = Join-Path $env:USERPROFILE '.codex' 'config.toml'
    if (Test-Path $codexConfig) {
        $sandbox = (Select-String -Path $codexConfig -Pattern 'sandbox\s*=\s*"([^"]+)"' -ErrorAction SilentlyContinue)
        if ($sandbox) {
            $val = $sandbox.Matches[0].Groups[1].Value
            if ($val -eq 'elevated') {
                Write-Output "Codex sandbox: $val [WARNING: use 'unelevated' to fix --sandbox danger-full-access]"
            } else {
                Write-Output "Codex sandbox: $val [OK]"
            }
        }
    } else {
        Write-Output "Codex config: not found"
    }

    $languageMode = [string]$ExecutionContext.SessionState.LanguageMode
    if ($languageMode -eq 'ConstrainedLanguage') {
        Write-Output "PowerShell language mode: $languageMode [WARNING: avoid Set-Content/Out-File and prefer apply_patch or cmd /c]"
    } else {
        Write-Output "PowerShell language mode: $languageMode [OK]"
    }

    try {
        $gitLockPath = (& git rev-parse --git-path index.lock 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitLockPath)) {
            $resolvedGitLockPath = if ([System.IO.Path]::IsPathRooted($gitLockPath)) {
                $gitLockPath
            } else {
                Join-Path (Get-Location).Path $gitLockPath
            }

            $gitLockDir = Split-Path -Parent $resolvedGitLockPath
            if ($gitLockDir -match '[\\/]\.git[\\/]worktrees[\\/]') {
                $probeName = 'winsmux-doctor-write-probe-' + [guid]::NewGuid().ToString('N') + '.tmp'
                $probePath = Join-Path $gitLockDir $probeName
                $quotedProbePath = '"' + $probePath.Replace('"', '""') + '"'
                & cmd /d /c "type nul > $quotedProbePath" | Out-Null
                if ($LASTEXITCODE -eq 0 -and (Test-Path $probePath)) {
                    Remove-Item -Path $probePath -Force -ErrorAction SilentlyContinue
                    Write-Output "Worktree git writes: writable [OK]"
                } else {
                    Write-Output "Worktree git writes: blocked [WARNING: keep editing/testing in the pane, but run git add/git commit/git push from a regular shell]"
                }
            } else {
                Write-Output "Worktree git writes: not applicable [OK: not running from a linked worktree]"
            }
        } else {
            Write-Output "Worktree git writes: unavailable [WARNING: git rev-parse --git-path index.lock failed]"
        }
    } catch {
        Write-Output "Worktree git writes: unavailable [WARNING: $($_.Exception.Message)]"
    }

    # Manifest
    $manifestPath = Join-Path (Get-Location).Path '.winsmux' 'manifest.yaml'
    Write-Output "Manifest: $(if (Test-Path $manifestPath) { 'exists' } else { 'not found' })"

    # Lock file
    $lockFile = Join-Path (Get-Location).Path '.winsmux' 'orchestra.lock'
    if (Test-Path $lockFile) {
        Write-Output "Startup lock: EXISTS [WARNING: stale lock? Remove to unblock]"
    } else {
        Write-Output "Startup lock: none [OK]"
    }

    # Shield harness
    $shDir = Join-Path (Get-Location).Path '.shield-harness'
    Write-Output "Shield-harness: $(if (Test-Path $shDir) { 'initialized' } else { 'not found' })"

    # Hooks count
    $hooksDir = Join-Path (Get-Location).Path '.claude' 'hooks'
    if (Test-Path $hooksDir) {
        $hookCount = @(Get-ChildItem $hooksDir -Filter '*.js').Count
        Write-Output "Hooks: $hookCount scripts"
    }
}

function ConvertTo-WinsmuxPublicJson {
    param([Parameter(Mandatory = $true)]$InputObject)

    return ($InputObject | ConvertTo-Json -Depth 8)
}

function Invoke-Init {
    $projectDir = ''
    $force = $false
    $asJson = $false
    $agent = 'codex'
    $model = ''
    $workerCount = 6
    $workspaceLifecyclePreset = 'managed-worktree'
    $remaining = @(@($Target) + @($Rest) | Where-Object { $_ })

    for ($index = 0; $index -lt $remaining.Count; $index++) {
        switch ($remaining[$index]) {
            '--json' { $asJson = $true }
            '--force' { $force = $true }
            '--project-dir' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>] [--workspace-lifecycle <preset>]"
                }

                $projectDir = $remaining[$index + 1]
                $index++
            }
            '--agent' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>] [--workspace-lifecycle <preset>]"
                }

                $agent = $remaining[$index + 1]
                $index++
            }
            '--model' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>] [--workspace-lifecycle <preset>]"
                }

                $model = $remaining[$index + 1]
                $index++
            }
            '--worker-count' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>] [--workspace-lifecycle <preset>]"
                }

                $workerCount = [int]$remaining[$index + 1]
                $index++
            }
            '--workspace-lifecycle' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>] [--workspace-lifecycle <preset>]"
                }

                $workspaceLifecyclePreset = $remaining[$index + 1]
                $index++
            }
            default {
                Stop-WithError "usage: winsmux init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>] [--workspace-lifecycle <preset>]"
            }
        }
    }

    $result = Invoke-WinsmuxPublicInit -ProjectDir $projectDir -Force:$force -Agent $agent -Model $model -WorkerCount $workerCount -WorkspaceLifecyclePreset $workspaceLifecyclePreset
    if ($asJson) {
        Write-Output (ConvertTo-WinsmuxPublicJson -InputObject $result)
        return
    }

    Write-Output "init status: $($result.status)"
    Write-Output "project: $($result.project_dir)"
    Write-Output "config: $($result.config_path)"
    Write-Output "slots: $($result.slot_count)"
    Write-Output "workspace lifecycle: $($result.workspace_lifecycle_preset)"
    Write-Output "next: $($result.next_action)"
}

function Test-WinsmuxInstalledBinLayout {
    param([string]$ScriptRoot = $PSScriptRoot)

    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return $false
    }

    $installedBin = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.winsmux\bin')).TrimEnd([char[]]@('\', '/'))
    $currentRoot = [System.IO.Path]::GetFullPath($ScriptRoot).TrimEnd([char[]]@('\', '/'))
    return [string]::Equals($currentRoot, $installedBin, [System.StringComparison]::OrdinalIgnoreCase)
}

function Invoke-Launch {
    $projectDir = ''
    $skipDoctor = Test-WinsmuxInstalledBinLayout
    $asJson = $false
    $remaining = @(@($Target) + @($Rest) | Where-Object { $_ })
    $doctorScriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\doctor.ps1'))

    for ($index = 0; $index -lt $remaining.Count; $index++) {
        switch ($remaining[$index]) {
            '--json' { $asJson = $true }
            '--skip-doctor' { $skipDoctor = $true }
            '--project-dir' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux launch [--json] [--project-dir <path>] [--skip-doctor]"
                }

                $projectDir = $remaining[$index + 1]
                $index++
            }
            default {
                Stop-WithError "usage: winsmux launch [--json] [--project-dir <path>] [--skip-doctor]"
            }
        }
    }

    $result = Invoke-WinsmuxPublicLaunch -ProjectDir $projectDir -SkipDoctor:$skipDoctor -BridgeScriptPath $BridgeScriptPath -DoctorScriptPath $doctorScriptPath
    if ($asJson) {
        Write-Output (ConvertTo-WinsmuxPublicJson -InputObject $result)
        return
    }

    Write-Output "launch status: $($result.status)"
    Write-Output "project: $($result.project_dir)"
    if ($result.PSObject.Properties.Name -contains 'operator_message' -and -not [string]::IsNullOrWhiteSpace([string]$result.operator_message)) {
        Write-Output "message: $($result.operator_message)"
    }
    if ($result.PSObject.Properties.Name -contains 'doctor_output' -and -not [string]::IsNullOrWhiteSpace([string]$result.doctor_output)) {
        Write-Output $result.doctor_output
    }
    Write-Output "next: $($result.next_action)"
}

function Get-LauncherSlotProperty {
    param(
        [AllowNull()]$Slot,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Slot) {
        return ''
    }

    if ($Slot -is [System.Collections.IDictionary]) {
        if ($Slot.Contains($Name)) {
            return [string]$Slot[$Name]
        }
        return ''
    }

    if ($null -ne $Slot.PSObject -and ($Slot.PSObject.Properties.Name -contains $Name)) {
        return [string]$Slot.$Name
    }

    return ''
}

function New-LauncherSlotSummary {
    param(
        [Parameter(Mandatory = $true)]$Slot,
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    $slotId = Get-LauncherSlotProperty -Slot $Slot -Name 'slot_id'
    if ([string]::IsNullOrWhiteSpace($slotId)) {
        return $null
    }

    $runtimeRole = Get-LauncherSlotProperty -Slot $Slot -Name 'runtime_role'
    if ([string]::IsNullOrWhiteSpace($runtimeRole)) {
        $runtimeRole = 'worker'
    }

    $roleForConfig = $runtimeRole
    if ([string]::Equals($roleForConfig, 'worker', [System.StringComparison]::OrdinalIgnoreCase)) {
        $roleForConfig = 'Worker'
    }

    $effective = Get-SlotAgentConfig -Role $roleForConfig -SlotId $slotId -Settings $Settings -RootPath $ProjectDir
    return [ordered]@{
        slot_id                    = $slotId
        runtime_role               = $runtimeRole
        agent                      = [string]$effective.Agent
        model                      = [string]$effective.Model
        model_source               = [string]$effective.ModelSource
        reasoning_effort           = [string]$effective.ReasoningEffort
        prompt_transport           = [string]$effective.PromptTransport
        auth_mode                  = [string]$effective.AuthMode
        auth_policy                = [string]$effective.AuthPolicy
        local_access_note          = [string]$effective.LocalAccessNote
        harness_availability       = [string]$effective.HarnessAvailability
        credential_requirements    = [string]$effective.CredentialRequirements
        execution_profile          = [string]$effective.ExecutionProfile
        execution_backend          = [string]$effective.ExecutionBackend
        runtime_requirements       = [string]$effective.RuntimeRequirements
        analysis_posture           = [string]$effective.AnalysisPosture
        source                     = [string]$effective.Source
        capability_adapter         = [string]$effective.CapabilityAdapter
        capability_command         = [string]$effective.CapabilityCommand
        supports_parallel_runs     = [bool]$effective.SupportsParallelRuns
        supports_interrupt         = [bool]$effective.SupportsInterrupt
        supports_structured_result = [bool]$effective.SupportsStructuredResult
        supports_file_edit         = [bool]$effective.SupportsFileEdit
        supports_subagents         = [bool]$effective.SupportsSubagents
        supports_verification      = [bool]$effective.SupportsVerification
        supports_consultation      = [bool]$effective.SupportsConsultation
        supports_context_reset     = [bool]$effective.SupportsContextReset
    }
}

function New-LauncherPreset {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string[]]$SlotIds,
        [string]$SelectionMode = 'multi',
        [string]$CapabilityFocus = ''
    )

    return [ordered]@{
        name             = $Name
        description      = $Description
        selection_mode   = $SelectionMode
        capability_focus = $CapabilityFocus
        slot_ids         = @($SlotIds)
    }
}

function Get-LauncherTemplatesPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return [System.IO.Path]::GetFullPath((Join-Path $ProjectDir '.winsmux\launcher-templates.json'))
}

function Read-LauncherTemplateStore {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $path = Get-LauncherTemplatesPath -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [ordered]@{
            version   = 1
            templates = @()
        }
    }

    try {
        $parsed = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 32
    } catch {
        Stop-WithError "launcher template store is not valid JSON: $path"
    }

    $templates = @()
    if ($parsed.Contains('templates')) {
        $templates = @($parsed['templates'])
    }

    return [ordered]@{
        version   = if ($parsed.Contains('version')) { [int]$parsed['version'] } else { 1 }
        templates = @($templates)
    }
}

function Write-LauncherTemplateStore {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Store
    )

    $path = Get-LauncherTemplatesPath -ProjectDir $ProjectDir
    $json = $Store | ConvertTo-Json -Depth 32
    Write-ClmSafeTextFile -Path $path -Content $json
    return $path
}

function Assert-LauncherTemplateName {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z0-9._-]+$') {
        Stop-WithError 'launcher template name must use only letters, numbers, dot, underscore, or hyphen.'
    }
}

function Get-LauncherWorkspaceLifecycleOverridePath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return [System.IO.Path]::GetFullPath((Join-Path $ProjectDir '.winsmux\workspace-lifecycle.json'))
}

function Get-LauncherObjectValue {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Value) {
        return $Default
    }

    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) {
            return $Value[$Name]
        }

        return $Default
    }

    if ($null -ne $Value.PSObject -and ($Value.PSObject.Properties.Name -contains $Name)) {
        return $Value.$Name
    }

    return $Default
}

function New-LauncherWorkspaceLifecyclePreset {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$WorkspaceMode,
        [Parameter(Mandatory = $true)][string]$SetupPolicy,
        [Parameter(Mandatory = $true)][string]$TeardownPolicy,
        [string]$LogsDir = '.winsmux\logs',
        [bool]$ForceDelete = $false
    )

    return [ordered]@{
        name             = $Name
        description      = $Description
        workspace_mode   = $WorkspaceMode
        setup_policy     = $SetupPolicy
        teardown_policy  = $TeardownPolicy
        logs_dir         = $LogsDir
        force_delete     = $ForceDelete
    }
}

function Read-LauncherWorkspaceLifecycleOverride {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 32
    } catch {
        Stop-WithError "workspace lifecycle override is not valid JSON: $Path"
    }
}

function Set-LauncherWorkspaceLifecycleOverride {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Preset
    )

    Assert-LauncherTemplateName -Name $Preset
    $path = Get-LauncherWorkspaceLifecycleOverridePath -ProjectDir $ProjectDir
    $payload = [ordered]@{
        version = 1
        preset  = $Preset
    }
    Write-ClmSafeTextFile -Path $path -Content ($payload | ConvertTo-Json -Depth 8)
    return $path
}

function Clear-LauncherWorkspaceLifecycleOverride {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $path = Get-LauncherWorkspaceLifecycleOverridePath -ProjectDir $ProjectDir
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }

    return $path
}

function Get-LauncherWorkspaceLifecyclePayload {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$SelectedPreset = ''
    )

    $settings = Get-BridgeSettings -RootPath $ProjectDir
    $projectDefault = [string]$settings.workspace_lifecycle_preset
    if ([string]::IsNullOrWhiteSpace($projectDefault)) {
        $projectDefault = 'managed-worktree'
    }

    $overridePath = Get-LauncherWorkspaceLifecycleOverridePath -ProjectDir $ProjectDir
    $override = Read-LauncherWorkspaceLifecycleOverride -Path $overridePath
    $userOverride = [string](Get-LauncherObjectValue -Value $override -Name 'preset' -Default '')
    $presets = [ordered]@{}
    $presets['none'] = New-LauncherWorkspaceLifecyclePreset `
        -Name 'none' `
        -Description 'Use the current project directory without managed workspace changes.' `
        -WorkspaceMode 'shared-root' `
        -SetupPolicy 'none' `
        -TeardownPolicy 'none'
    $presets['managed-worktree'] = New-LauncherWorkspaceLifecyclePreset `
        -Name 'managed-worktree' `
        -Description 'Prepare managed worker worktrees and keep them for inspection after use.' `
        -WorkspaceMode 'managed-worktree' `
        -SetupPolicy 'ensure-managed-worktree' `
        -TeardownPolicy 'keep-for-operator-cleanup'
    $presets['ephemeral-worktree'] = New-LauncherWorkspaceLifecyclePreset `
        -Name 'ephemeral-worktree' `
        -Description 'Prepare disposable worker worktrees and require explicit force cleanup.' `
        -WorkspaceMode 'ephemeral-worktree' `
        -SetupPolicy 'ensure-managed-worktree' `
        -TeardownPolicy 'force-delete-required' `
        -ForceDelete $true

    if ([string]::IsNullOrWhiteSpace($SelectedPreset)) {
        $SelectedPreset = if ([string]::IsNullOrWhiteSpace($userOverride)) { $projectDefault } else { $userOverride }
    }

    Assert-LauncherTemplateName -Name $SelectedPreset
    if (-not $presets.Contains($SelectedPreset)) {
        Stop-WithError "workspace lifecycle preset not found: $SelectedPreset"
    }

    return [ordered]@{
        version             = 1
        selected_preset     = $SelectedPreset
        project_default     = $projectDefault
        user_override       = $userOverride
        override_path       = $overridePath
        presets             = @($presets.Values)
    }
}

function Get-LauncherPresetPayload {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$LifecyclePreset = ''
    )

    $settings = Get-BridgeSettings -RootPath $ProjectDir
    $slots = @()
    foreach ($slot in @($settings.agent_slots)) {
        $summary = New-LauncherSlotSummary -Slot $slot -Settings $settings -ProjectDir $ProjectDir
        if ($null -ne $summary) {
            $slots += [PSCustomObject]$summary
        }
    }

    $editSlots = @($slots | Where-Object { $_.supports_file_edit })
    $reviewSlots = @($slots | Where-Object {
        $_.supports_verification -or $_.supports_structured_result -or $_.supports_consultation
    })
    $verificationSlots = @($slots | Where-Object { $_.supports_verification })
    $workerSlots = @($slots | Where-Object {
        [string]::Equals([string]$_.runtime_role, 'worker', [System.StringComparison]::OrdinalIgnoreCase)
    })

    $presets = @()
    if ($workerSlots.Count -gt 0) {
        $presets += [PSCustomObject](New-LauncherPreset `
            -Name 'all-workers' `
            -Description 'Select every managed worker slot.' `
            -SlotIds @($workerSlots | ForEach-Object { [string]$_.slot_id }) `
            -CapabilityFocus 'parallel_start')
    }

    if ($editSlots.Count -gt 0 -and $reviewSlots.Count -gt 0) {
        $selected = @([string]$editSlots[0].slot_id)
        $reviewSlot = @($reviewSlots | Where-Object {
            -not [string]::Equals([string]$_.slot_id, [string]$editSlots[0].slot_id, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($reviewSlot.Count -gt 0) {
            $selected += [string]$reviewSlot[0].slot_id
        }
        $presets += [PSCustomObject](New-LauncherPreset `
            -Name 'balanced-build-review' `
            -Description 'Select one edit-capable slot and one review-capable slot.' `
            -SlotIds $selected `
            -CapabilityFocus 'build_review')
    }

    if ($verificationSlots.Count -gt 0) {
        $presets += [PSCustomObject](New-LauncherPreset `
            -Name 'verification' `
            -Description 'Select slots that declare verification support.' `
            -SlotIds @($verificationSlots | ForEach-Object { [string]$_.slot_id }) `
            -CapabilityFocus 'verification')
    }

    $pairTemplates = @()
    $pairSource = @($editSlots)
    if ($pairSource.Count -lt 2) {
        $pairSource = @($workerSlots)
    }
    if ($pairSource.Count -ge 2) {
        $left = $pairSource[0]
        $right = $pairSource[1]
        $pairTemplates += [PSCustomObject]([ordered]@{
            name          = 'ab-pair'
            description   = 'Compare two worker slots with the same task prompt.'
            left_slot_id  = [string]$left.slot_id
            right_slot_id = [string]$right.slot_id
            slot_ids      = @([string]$left.slot_id, [string]$right.slot_id)
            left_agent    = [string]$left.agent
            right_agent   = [string]$right.agent
        })
    }

    return [ordered]@{
        version        = 1
        project_dir    = $ProjectDir
        slot_count     = $slots.Count
        templates_path = Get-LauncherTemplatesPath -ProjectDir $ProjectDir
        slots          = @($slots)
        presets        = @($presets)
        pair_templates = @($pairTemplates)
        workspace_lifecycle = Get-LauncherWorkspaceLifecyclePayload -ProjectDir $ProjectDir -SelectedPreset $LifecyclePreset
    }
}

function Save-LauncherTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$LifecyclePreset = ''
    )

    Assert-LauncherTemplateName -Name $Name
    $payload = Get-LauncherPresetPayload -ProjectDir $ProjectDir -LifecyclePreset $LifecyclePreset
    $store = Read-LauncherTemplateStore -ProjectDir $ProjectDir
    $record = [ordered]@{
        name           = $Name
        saved_at_utc   = (Get-Date).ToUniversalTime().ToString('o')
        slot_count     = [int]$payload.slot_count
        slots          = @($payload.slots)
        presets        = @($payload.presets)
        pair_templates = @($payload.pair_templates)
        workspace_lifecycle = $payload.workspace_lifecycle
    }

    $templates = @($store.templates | Where-Object {
        $recordName = ''
        if ($_ -is [System.Collections.IDictionary] -and $_.Contains('name')) {
            $recordName = [string]($_['name'])
        } elseif ($null -ne $_.PSObject -and ($_.PSObject.Properties.Name -contains 'name')) {
            $recordName = [string]$_.name
        }

        -not [string]::Equals($recordName, $Name, [System.StringComparison]::OrdinalIgnoreCase)
    })
    $templates += $record
    $nextStore = [ordered]@{
        version   = 1
        templates = @($templates)
    }
    $path = Write-LauncherTemplateStore -ProjectDir $ProjectDir -Store $nextStore

    return [ordered]@{
        name           = $Name
        templates_path = $path
        saved          = $true
        template       = $record
    }
}

function Get-LauncherTemplateListPayload {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $store = Read-LauncherTemplateStore -ProjectDir $ProjectDir
    return [ordered]@{
        version        = [int]$store.version
        templates_path = Get-LauncherTemplatesPath -ProjectDir $ProjectDir
        template_count = @($store.templates).Count
        templates      = @($store.templates)
    }
}

function Invoke-Launcher {
    $tokens = @(@($Target) + @($Rest) | Where-Object { $_ })
    $mode = 'presets'
    $templateName = ''
    $lifecyclePreset = ''
    $clearLifecycleOverride = $false
    $jsonOutput = $false

    for ($index = 0; $index -lt $tokens.Count; $index++) {
        switch ($tokens[$index]) {
            '--json' {
                $jsonOutput = $true
            }
            '--clear' {
                $clearLifecycleOverride = $true
            }
            '--lifecycle' {
                $index++
                if ($index -ge $tokens.Count -or [string]::IsNullOrWhiteSpace([string]$tokens[$index])) {
                    Stop-WithError "usage: winsmux launcher <presets|lifecycle|list|save> [name] [--lifecycle <preset>] [--json]"
                }

                $lifecyclePreset = [string]$tokens[$index]
            }
            'presets' {
                $mode = 'presets'
            }
            'lifecycle' {
                $mode = 'lifecycle'
            }
            'list' {
                $mode = 'list'
            }
            'save' {
                $mode = 'save'
            }
            default {
                if ([string]::Equals($mode, 'save', [System.StringComparison]::OrdinalIgnoreCase) -and [string]::IsNullOrWhiteSpace($templateName)) {
                    $templateName = [string]$tokens[$index]
                } elseif ([string]::Equals($mode, 'lifecycle', [System.StringComparison]::OrdinalIgnoreCase) -and [string]::IsNullOrWhiteSpace($lifecyclePreset)) {
                    $lifecyclePreset = [string]$tokens[$index]
                } else {
                    Stop-WithError "usage: winsmux launcher <presets|lifecycle|list|save> [name] [--lifecycle <preset>] [--json]"
                }
            }
        }
    }

    if ($clearLifecycleOverride -and -not [string]::Equals($mode, 'lifecycle', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "usage: winsmux launcher lifecycle [preset|--clear] [--json]"
    }

    if ($clearLifecycleOverride -and -not [string]::IsNullOrWhiteSpace($lifecyclePreset)) {
        Stop-WithError "usage: winsmux launcher lifecycle [preset|--clear] [--json]"
    }

    $projectDir = (Get-Location).Path
    if ([string]::Equals($mode, 'save', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ([string]::IsNullOrWhiteSpace($templateName)) {
            Stop-WithError "usage: winsmux launcher save <name> [--json]"
        }

        $saveResult = Save-LauncherTemplate -ProjectDir $projectDir -Name $templateName -LifecyclePreset $lifecyclePreset
        if ($jsonOutput) {
            $saveResult | ConvertTo-Json -Depth 32 -Compress | Write-Output
            return
        }

        Write-Output "launcher template saved: $($saveResult.name)"
        Write-Output "templates: $($saveResult.templates_path)"
        return
    }

    if ([string]::Equals($mode, 'list', [System.StringComparison]::OrdinalIgnoreCase)) {
        $listResult = Get-LauncherTemplateListPayload -ProjectDir $projectDir
        if ($jsonOutput) {
            $listResult | ConvertTo-Json -Depth 32 -Compress | Write-Output
            return
        }

        Write-Output "launcher templates: $($listResult.template_count)"
        foreach ($template in @($listResult.templates)) {
            Write-Output "  $($template.name)"
        }
        Write-Output "templates: $($listResult.templates_path)"
        return
    }

    if ([string]::Equals($mode, 'lifecycle', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($clearLifecycleOverride) {
            $clearedPath = Clear-LauncherWorkspaceLifecycleOverride -ProjectDir $projectDir
            $lifecycleResult = Get-LauncherWorkspaceLifecyclePayload -ProjectDir $projectDir
            $lifecycleResult['override_cleared'] = $true
            $lifecycleResult['cleared_path'] = $clearedPath
        } elseif (-not [string]::IsNullOrWhiteSpace($lifecyclePreset)) {
            $lifecycleResult = Get-LauncherWorkspaceLifecyclePayload -ProjectDir $projectDir -SelectedPreset $lifecyclePreset
            $overridePath = Set-LauncherWorkspaceLifecycleOverride -ProjectDir $projectDir -Preset $lifecyclePreset
            $lifecycleResult['override_saved'] = $true
            $lifecycleResult['saved_path'] = $overridePath
        } else {
            $lifecycleResult = Get-LauncherWorkspaceLifecyclePayload -ProjectDir $projectDir
        }

        if ($jsonOutput) {
            $lifecycleResult | ConvertTo-Json -Depth 32 -Compress | Write-Output
            return
        }

        Write-Output "workspace lifecycle presets: $(@($lifecycleResult.presets).Count)"
        Write-Output "selected: $($lifecycleResult.selected_preset)"
        foreach ($preset in @($lifecycleResult.presets)) {
            Write-Output "  $($preset.name): setup=$($preset.setup_policy) teardown=$($preset.teardown_policy)"
        }
        Write-Output "project default: $($lifecycleResult.project_default)"
        Write-Output "user override: $($lifecycleResult.user_override)"
        Write-Output "override path: $($lifecycleResult.override_path)"
        return
    }

    $result = Get-LauncherPresetPayload -ProjectDir $projectDir -LifecyclePreset $lifecyclePreset
    if ($jsonOutput) {
        $result | ConvertTo-Json -Depth 16 -Compress | Write-Output
        return
    }

    Write-Output "launcher presets: $(@($result.presets).Count)"
    foreach ($preset in @($result.presets)) {
        Write-Output "  $($preset.name): $($preset.slot_ids -join ',')"
    }
    Write-Output "pair templates: $(@($result.pair_templates).Count)"
    foreach ($pair in @($result.pair_templates)) {
        Write-Output "  $($pair.name): $($pair.left_slot_id),$($pair.right_slot_id)"
    }
    Write-Output "workspace lifecycle: $($result.workspace_lifecycle.selected_preset)"
    Write-Output "templates: $($result.templates_path)"
}

function Invoke-ImeInput {
    if (-not $Target) { Stop-WithError "usage: winsmux ime-input <target>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName Microsoft.VisualBasic

    $text = [Microsoft.VisualBasic.Interaction]::InputBox(
        "winsmux ペイン $paneId に送信するテキストを入力してください",
        "winsmux IME Input",
        ""
    )

    if ([string]::IsNullOrEmpty($text)) {
        Write-Output "cancelled"
        return
    }

    Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $paneId, '-l', '--', "$text")
    Clear-ReadMark $paneId
    Write-Output "sent to $paneId"
}

function Invoke-ImagePaste {
    if (-not $Target) { Stop-WithError "usage: winsmux image-paste <target>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    Add-Type -AssemblyName System.Windows.Forms

    $img = [System.Windows.Forms.Clipboard]::GetImage()
    if (-not $img) {
        Stop-WithError "no image in clipboard"
    }

    $imgDir = Join-Path $env:TEMP "winsmux\images"
    if (-not (Test-Path $imgDir)) {
        New-Item -ItemType Directory -Path $imgDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $imgPath = Join-Path $imgDir "$timestamp.png"
    $img.Save($imgPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $img.Dispose()

    # Send file path as text to the target pane
    Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $paneId, '-l', '--', "$imgPath")
    Clear-ReadMark $paneId
    Write-Output "image saved: $imgPath"
    Write-Output "path sent to $paneId"
}

function Invoke-ClipboardPaste {
    if (-not $Target) { Stop-WithError "usage: winsmux clipboard-paste <target>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    $text = Get-Clipboard -Raw
    if ([string]::IsNullOrEmpty($text)) {
        Stop-WithError "clipboard is empty"
    }

    Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $paneId, '-l', '--', "$text")
    Clear-ReadMark $paneId
    Write-Output "sent to $paneId"
}

function Get-SignalDir {
    $dir = Join-Path $env:TEMP "winsmux\signals"
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Invoke-Wait {
    if (-not $Target) { Stop-WithError "usage: winsmux wait <channel> [timeout_seconds]" }

    $channel = $Target
    $timeoutSec = 120
    if ($Rest -and $Rest.Count -gt 0) {
        $timeoutSec = [int]$Rest[0]
    }

    $signalDir = Get-SignalDir
    $signalFile = Join-Path $signalDir "$channel.signal"

    # Check if already signaled
    if (Test-Path $signalFile) {
        Remove-Item $signalFile -Force
        Write-Output "received signal: $channel"
        return
    }

    # Poll at 100ms intervals
    $elapsed = 0
    $intervalMs = 100
    $timeoutMs = $timeoutSec * 1000

    while ($elapsed -lt $timeoutMs) {
        if (Test-Path $signalFile) {
            Remove-Item $signalFile -Force
            Write-Output "received signal: $channel"
            return
        }
        Start-Sleep -Milliseconds $intervalMs
        $elapsed += $intervalMs
    }

    Stop-WithError "timeout waiting for signal: $channel (${timeoutSec}s)"
}

function Invoke-Signal {
    if (-not $Target) { Stop-WithError "usage: winsmux signal <channel>" }

    $channel = $Target
    $signalDir = Get-SignalDir
    $signalFile = Join-Path $signalDir "$channel.signal"

    Write-ClmSafeTextFile -Path $signalFile -Content (Get-Date -Format o)
    Write-Output "sent signal: $channel"
}

function Invoke-Watch {
    if (-not $Target) { Stop-WithError "usage: winsmux watch <label> [silence_seconds] [timeout_seconds]" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    $silenceSec = 10
    $timeoutSec = 120
    if ($Rest -and $Rest.Count -gt 0) { $silenceSec = [int]$Rest[0] }
    if ($Rest -and $Rest.Count -gt 1) { $timeoutSec = [int]$Rest[1] }

    # Initial snapshot
    $output = Invoke-WinsmuxRaw -Arguments @('capture-pane', '-t', $paneId, '-p', '-J', '-S', '-50')
    $prevHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes(($output | Out-String))
        )
    ) -replace '-', ''

    $silenceCounter = 0
    $elapsed = 0

    while ($elapsed -lt $timeoutSec) {
        Start-Sleep -Seconds 1
        $elapsed++

        $output = Invoke-WinsmuxRaw -Arguments @('capture-pane', '-t', $paneId, '-p', '-J', '-S', '-50')
        $currentHash = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes(($output | Out-String))
            )
        ) -replace '-', ''

        if ($currentHash -eq $prevHash) {
            $silenceCounter++
        } else {
            $silenceCounter = 0
            $prevHash = $currentHash
        }

        if ($silenceCounter -ge $silenceSec) {
            Write-Output "silence detected: $Target (no output for ${silenceSec}s)"
            return
        }
    }

    Stop-WithError "timeout watching $Target (${timeoutSec}s, needed ${silenceSec}s silence)"
}

function Invoke-WaitReady {
    if (-not $Target) { Stop-WithError "usage: winsmux wait-ready <target> [timeout_seconds]" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId
    $readinessAgent = Get-PaneReadinessAgent -Target $Target -PaneId $paneId -ProjectDir (Get-Location).Path

    $timeoutSec = 60
    if ($Rest -and $Rest.Count -gt 0) { $timeoutSec = [int]$Rest[0] }

    $intervalSec = 2
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $printedDot = $false

    while ((Get-Date) -lt $deadline) {
        if (Test-AgentReadyPrompt -PaneId $paneId -Agent $readinessAgent) {
            if ($printedDot) { Write-Host "" }
            exit 0
        }

        Write-Host "." -NoNewline
        $printedDot = $true
        Start-Sleep -Seconds $intervalSec
    }

    if (Test-AgentReadyPrompt -PaneId $paneId -Agent $readinessAgent) {
        if ($printedDot) { Write-Host "" }
        exit 0
    }

    if ($printedDot) { Write-Host "" }
    exit 1
}

function Invoke-HealthCheck {
    if ($Target -or ($Rest -and $Rest.Count -gt 0)) {
        Stop-WithError "usage: winsmux health-check"
    }

    $labels = Get-Labels
    if ($labels.Count -eq 0) {
        return
    }

    $orderedLabels = $labels.Keys | Sort-Object
    $initialRuntime = Get-PaneRuntimeMap
    $firstSnapshots = @{}
    $projectDir = (Get-Location).Path

    foreach ($label in $orderedLabels) {
        $paneId = $labels[$label]
        if (-not $initialRuntime.ContainsKey($paneId) -or -not $initialRuntime[$paneId].IsRunning) {
            continue
        }

        try {
            $firstSnapshots[$label] = Get-PaneSnapshotText -PaneId $paneId
        } catch {
            $firstSnapshots[$label] = $null
        }
    }

    Start-Sleep -Seconds 10

    $finalRuntime = Get-PaneRuntimeMap

    foreach ($label in $orderedLabels) {
        $paneId = $labels[$label]
        $status = 'DEAD'
        $readinessAgent = Get-PaneReadinessAgent -Target $label -PaneId $paneId -ProjectDir $projectDir

        if ($finalRuntime.ContainsKey($paneId) -and $finalRuntime[$paneId].IsRunning) {
            try {
                $secondSnapshot = Get-PaneSnapshotText -PaneId $paneId
                if (Test-AgentReadyPromptText -Text $secondSnapshot -Agent $readinessAgent) {
                    $status = 'READY'
                } else {
                    $firstSnapshot = $null
                    if ($firstSnapshots.ContainsKey($label)) {
                        $firstSnapshot = $firstSnapshots[$label]
                    }

                    if ((Get-TextHash $firstSnapshot) -eq (Get-TextHash $secondSnapshot)) {
                        $status = 'HUNG'
                    } else {
                        $status = 'BUSY'
                    }
                }
            } catch {
                $status = 'DEAD'
            }
        }

        Write-Output "$label $paneId $status"
    }
}

function Invoke-Status {
    if ($Target -or ($Rest -and $Rest.Count -gt 0)) {
        Stop-WithError "usage: winsmux status"
    }

    $projectDir = (Get-Location).Path

    try {
        $records = @(Get-PaneStatusRecords -ProjectDir $projectDir)
    } catch {
        Stop-WithError $_.Exception.Message
    }

    if ($records.Count -eq 0) {
        Write-Output "(no panes)"
        return
    }

    $table = $records |
        Select-Object Label, Role, PaneId, State, @{ Name = 'Tokens'; Expression = { $_.TokensRemaining } } |
        Format-Table -AutoSize |
        Out-String

    Write-Output ($table.TrimEnd())
}

function Get-WorkersUsage {
    return "usage: winsmux workers <status|start|stop|attach|doctor> [slot|all] [--json] [--project-dir <path>]; winsmux workers <exec|logs|upload|download> <slot> ... [--json] [--project-dir <path>]; winsmux workers heartbeat <mark|check> <slot> [--run-id <id>] ... [--json] [--project-dir <path>]; winsmux workers workspace <prepare|cleanup> <slot> ... [--json] [--project-dir <path>]; winsmux workers secrets project <slot> ... [--json] [--project-dir <path>]; winsmux workers sandbox baseline <slot> --run-id <id> [--json] [--project-dir <path>]; winsmux workers broker baseline <slot> --run-id <id> --endpoint <url> [--node-id <id>] [--json] [--project-dir <path>]; winsmux workers broker token <issue|check> <slot> --run-id <id> [--ttl-seconds <n>] [--no-refresh] [--json] [--project-dir <path>]; winsmux workers policy baseline <slot> --run-id <id> [--network <mode>] [--write <mode>] [--provider <mode>] [--require-check <name>] [--require-evidence <role:name>] [--json] [--project-dir <path>]"
}

function Read-WorkersOptions {
    param(
        [AllowNull()][string[]]$Tokens,
        [Parameter(Mandatory = $true)][string]$Usage,
        [AllowEmptyString()][string]$DefaultTarget = '',
        [switch]$RequireTarget
    )

    $projectDir = (Get-Location).Path
    $asJson = $false
    $targetValue = ''
    $targetSet = $false
    $items = @($Tokens)

    for ($index = 0; $index -lt $items.Count; $index++) {
        $token = [string]$items[$index]
        switch ($token) {
            '--json' {
                $asJson = $true
            }
            '--project-dir' {
                if ($index + 1 -ge $items.Count) {
                    Stop-WithError $Usage
                }

                $projectDir = [string]$items[$index + 1]
                $index++
            }
            default {
                if ($targetSet) {
                    Stop-WithError $Usage
                }

                $targetValue = $token
                $targetSet = $true
            }
        }
    }

    if (-not $targetSet) {
        $targetValue = $DefaultTarget
    }

    if ($RequireTarget -and [string]::IsNullOrWhiteSpace($targetValue)) {
        Stop-WithError $Usage
    }

    return [PSCustomObject]@{
        ProjectDir = $projectDir
        Json       = $asJson
        Target     = $targetValue
    }
}

function ConvertTo-WorkersSlotAlias {
    param([AllowEmptyString()][string]$SlotId)

    if ([string]::IsNullOrWhiteSpace($SlotId)) {
        return ''
    }

    if ($SlotId -match '^worker-(\d+)$') {
        return "w$($Matches[1])"
    }

    return $SlotId
}

function Resolve-WorkersSlotId {
    param([AllowEmptyString()][string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return ''
    }

    $normalized = $Target.Trim().ToLowerInvariant()
    if ($normalized -eq 'all') {
        return 'all'
    }

    if ($normalized -match '^w(\d+)$') {
        return "worker-$($Matches[1])"
    }

    return $normalized
}

function Join-WorkersValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [string]) {
        return $Value
    }

    $items = @($Value | ForEach-Object {
        $text = [string]$_
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $text
        }
    })

    return ($items -join ',')
}

function Get-WorkersSlotRuntimeRole {
    param([AllowNull()]$Slot)

    $role = [string](Get-SendConfigValue -InputObject $Slot -Name 'runtime_role' -Default '')
    if ([string]::IsNullOrWhiteSpace($role)) {
        $role = [string](Get-SendConfigValue -InputObject $Slot -Name 'runtime-role' -Default '')
    }
    if ([string]::IsNullOrWhiteSpace($role)) {
        $role = 'worker'
    }

    return $role
}

function Get-WorkersSlotId {
    param([AllowNull()]$Slot)

    $slotId = [string](Get-SendConfigValue -InputObject $Slot -Name 'slot_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($slotId)) {
        $slotId = [string](Get-SendConfigValue -InputObject $Slot -Name 'slot-id' -Default '')
    }

    return $slotId
}

function Get-WorkersColabSessionState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Settings
    )

    $sessionsBySlot = @{}
    $statePath = ''
    $errorReason = ''
    $updatedAt = ''
    $degradedCount = 0

    if (Get-Command Get-WinsmuxColabStatePath -ErrorAction SilentlyContinue) {
        $statePath = Get-WinsmuxColabStatePath -ProjectDir $ProjectDir
    }

    if (-not (Get-Command Update-WinsmuxColabSessionState -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{
            SessionsBySlot = $sessionsBySlot
            StatePath      = $statePath
            UpdatedAt      = $updatedAt
            DegradedCount  = $degradedCount
            ErrorReason    = 'colab_backend_helpers_unavailable'
        }
    }

    try {
        $state = Update-WinsmuxColabSessionState -ProjectDir $ProjectDir -Settings $Settings
        $statePath = [string](Get-SendConfigValue -InputObject $state -Name 'path' -Default $statePath)
        $updatedAt = [string](Get-SendConfigValue -InputObject $state -Name 'updated_at' -Default '')
        $degradedCount = [int](Get-SendConfigValue -InputObject $state -Name 'degraded_count' -Default 0)
        foreach ($record in @(Get-SendConfigValue -InputObject $state -Name 'active_sessions' -Default @())) {
            $slotId = [string](Get-SendConfigValue -InputObject $record -Name 'slot_id' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($slotId) -and -not $sessionsBySlot.ContainsKey($slotId)) {
                $sessionsBySlot[$slotId] = $record
            }
        }
    } catch {
        $errorReason = $_.Exception.Message
        if (Get-Command New-WinsmuxColabStateUpdateFailureRecords -ErrorAction SilentlyContinue) {
            foreach ($record in @(New-WinsmuxColabStateUpdateFailureRecords -ProjectDir $ProjectDir -Settings $Settings -Reason 'colab_state_update_failed')) {
                $slotId = [string](Get-SendConfigValue -InputObject $record -Name 'slot_id' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($slotId) -and -not $sessionsBySlot.ContainsKey($slotId)) {
                    $sessionsBySlot[$slotId] = $record
                }
            }
            $degradedCount = $sessionsBySlot.Count
        }
    }

    return [PSCustomObject]@{
        SessionsBySlot = $sessionsBySlot
        StatePath      = $statePath
        UpdatedAt      = $updatedAt
        DegradedCount  = $degradedCount
        ErrorReason    = $errorReason
    }
}

function Get-WorkersLifecycleContext {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $settings = Get-BridgeSettings -RootPath $ProjectDir
    $slots = @($settings.agent_slots | Where-Object {
        (Get-WorkersSlotRuntimeRole -Slot $_).Trim().ToLowerInvariant() -eq 'worker'
    })

    $entries = @()
    $manifestError = ''
    try {
        $entries = @(Get-PaneControlManifestEntries -ProjectDir $ProjectDir | Where-Object {
            ([string]$_.Role -eq 'Worker') -or ([string]$_.Label -match '^worker-\d+$')
        })
    } catch {
        $manifestError = $_.Exception.Message
    }

    $statusRecords = @()
    try {
        if ($entries.Count -gt 0) {
            $statusRecords = @(Get-PaneStatusRecords -ProjectDir $ProjectDir)
        }
    } catch {
    }

    $entriesBySlot = @{}
    foreach ($entry in $entries) {
        foreach ($key in @([string]$entry.Label, [string](Get-SendConfigValue -InputObject $entry -Name 'SlotId' -Default ''))) {
            if (-not [string]::IsNullOrWhiteSpace($key) -and -not $entriesBySlot.ContainsKey($key)) {
                $entriesBySlot[$key] = $entry
            }
        }
    }

    $statusBySlot = @{}
    foreach ($record in $statusRecords) {
        foreach ($key in @([string]$record.Label, [string](Get-SendConfigValue -InputObject $record -Name 'SlotId' -Default ''))) {
            if (-not [string]::IsNullOrWhiteSpace($key) -and -not $statusBySlot.ContainsKey($key)) {
                $statusBySlot[$key] = $record
            }
        }
    }

    return [PSCustomObject]@{
        ProjectDir      = $ProjectDir
        Settings        = $settings
        Slots           = @($slots)
        EntriesBySlot   = $entriesBySlot
        StatusBySlot    = $statusBySlot
        ManifestError   = $manifestError
        ColabState      = Get-WorkersColabSessionState -ProjectDir $ProjectDir -Settings $settings
    }
}

function Get-WorkersStatusRows {
    param([Parameter(Mandatory = $true)]$Context)

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($slot in @($Context.Slots)) {
        $slotId = Get-WorkersSlotId -Slot $slot
        if ([string]::IsNullOrWhiteSpace($slotId)) {
            continue
        }

        $runtimeRole = Get-WorkersSlotRuntimeRole -Slot $slot
        $slotConfig = Get-SlotAgentConfig -Role 'Worker' -SlotId $slotId -Settings $Context.Settings -RootPath $Context.ProjectDir
        $workerRole = [string]$slotConfig.WorkerRole
        if ([string]::IsNullOrWhiteSpace($workerRole)) {
            $workerRole = $runtimeRole
        }

        $entry = if ($Context.EntriesBySlot.ContainsKey($slotId)) { $Context.EntriesBySlot[$slotId] } else { $null }
        $statusRecord = if ($Context.StatusBySlot.ContainsKey($slotId)) { $Context.StatusBySlot[$slotId] } else { $null }
        $colabSession = $null
        if ($Context.ColabState.SessionsBySlot.ContainsKey($slotId)) {
            $colabSession = $Context.ColabState.SessionsBySlot[$slotId]
        } elseif ($null -ne $entry) {
            $colabSession = Get-SendConfigValue -InputObject $entry -Name 'ColabSession' -Default $null
        }

        $manifestStatus = if ($null -ne $entry) { [string]$entry.Status } else { '' }
        $paneState = if ($null -ne $statusRecord) { [string]$statusRecord.State } else { '' }
        $state = $paneState
        if ($manifestStatus -in @('deferred_start', 'deferred_starting', 'deferred_start_failed', 'backend_degraded')) {
            $state = $manifestStatus
        }
        if ([string]::IsNullOrWhiteSpace($state)) {
            $state = if ($null -eq $entry) { 'not_launched' } else { 'unknown' }
        }
        $activeHeartbeatRunId = if ($null -ne $entry) { [string](Get-SendConfigValue -InputObject $entry -Name 'LastHeartbeatRunId' -Default '') } else { '' }
        $activeHeartbeatProfile = if ($null -ne $entry) { [string](Get-SendConfigValue -InputObject $entry -Name 'LastHeartbeatProfile' -Default '') } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($activeHeartbeatRunId)) {
            $heartbeat = Get-WorkersLatestHeartbeatStatus -ProjectDir $Context.ProjectDir -SlotId $slotId -RunId $activeHeartbeatRunId -ExecutionProfile $activeHeartbeatProfile
        } else {
            $heartbeat = $null
        }
        $heartbeatHealth = ''
        $heartbeatState = ''
        if ($null -ne $heartbeat) {
            $heartbeatHealth = [string](Get-SendConfigValue -InputObject $heartbeat -Name 'health' -Default '')
            $heartbeatState = [string](Get-SendConfigValue -InputObject $heartbeat -Name 'state' -Default '')
            $heartbeatRunId = [string](Get-SendConfigValue -InputObject $heartbeat -Name 'run_id' -Default '')
            $heartbeatCanDriveState = ($null -ne $entry) -and (
                -not [string]::IsNullOrWhiteSpace($activeHeartbeatRunId) -and
                [string]::Equals($activeHeartbeatRunId, $heartbeatRunId, [System.StringComparison]::Ordinal)
            )
            if ($heartbeatCanDriveState -and
                $heartbeatHealth -in @('running', 'blocked', 'approval_waiting', 'child_wait', 'stalled', 'offline', 'completed', 'resumable') -and
                $state -notin @('backend_degraded', 'deferred_start_failed', 'deferred_start', 'deferred_starting')) {
                $state = $heartbeatHealth
            }
        }

        $broker = $null
        if ($null -ne $entry) {
            $brokerRunId = [string](Get-SendConfigValue -InputObject $entry -Name 'LastBrokerRunId' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($brokerRunId)) {
                $broker = [ordered]@{
                    run_id            = $brokerRunId
                    execution_profile = [string](Get-SendConfigValue -InputObject $entry -Name 'LastBrokerProfile' -Default '')
                    status            = [string](Get-SendConfigValue -InputObject $entry -Name 'LastBrokerStatus' -Default '')
                    node_id           = [string](Get-SendConfigValue -InputObject $entry -Name 'LastBrokerNodeId' -Default '')
                    endpoint          = [string](Get-SendConfigValue -InputObject $entry -Name 'LastBrokerEndpoint' -Default '')
                    manifest          = [string](Get-SendConfigValue -InputObject $entry -Name 'LastBrokerManifest' -Default '')
                }
                $brokerTokenManifest = [string](Get-SendConfigValue -InputObject $entry -Name 'LastBrokerTokenManifest' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($brokerTokenManifest)) {
                    $broker['token'] = [ordered]@{
                        status     = [string](Get-SendConfigValue -InputObject $entry -Name 'LastBrokerTokenStatus' -Default '')
                        health     = [string](Get-SendConfigValue -InputObject $entry -Name 'LastBrokerTokenHealth' -Default '')
                        expires_at = [string](Get-SendConfigValue -InputObject $entry -Name 'LastBrokerTokenExpiresAt' -Default '')
                        manifest   = $brokerTokenManifest
                    }
                }
            }
        }

        $policy = $null
        if ($null -ne $entry) {
            $policyRunId = [string](Get-SendConfigValue -InputObject $entry -Name 'LastPolicyRunId' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($policyRunId)) {
                $policy = [ordered]@{
                    run_id            = $policyRunId
                    execution_profile = [string](Get-SendConfigValue -InputObject $entry -Name 'LastPolicyProfile' -Default '')
                    status            = [string](Get-SendConfigValue -InputObject $entry -Name 'LastPolicyStatus' -Default '')
                    health            = [string](Get-SendConfigValue -InputObject $entry -Name 'LastPolicyHealth' -Default '')
                    reason            = [string](Get-SendConfigValue -InputObject $entry -Name 'LastPolicyReason' -Default '')
                    network           = [string](Get-SendConfigValue -InputObject $entry -Name 'LastPolicyNetwork' -Default '')
                    write             = [string](Get-SendConfigValue -InputObject $entry -Name 'LastPolicyWrite' -Default '')
                    provider          = [string](Get-SendConfigValue -InputObject $entry -Name 'LastPolicyProvider' -Default '')
                    mandatory_checks  = [string](Get-SendConfigValue -InputObject $entry -Name 'LastPolicyMandatoryChecks' -Default '')
                    required_evidence = [string](Get-SendConfigValue -InputObject $entry -Name 'LastPolicyRequiredEvidence' -Default '')
                    manifest          = [string](Get-SendConfigValue -InputObject $entry -Name 'LastPolicyManifest' -Default '')
                }
            }
        }

        $sessionName = [string](Get-SendConfigValue -InputObject $colabSession -Name 'session_name' -Default '')
        if ([string]::IsNullOrWhiteSpace($sessionName) -and [string]::Equals(([string]$slotConfig.WorkerBackend), 'colab_cli', [System.StringComparison]::OrdinalIgnoreCase) -and (Get-Command Resolve-WinsmuxColabSessionName -ErrorAction SilentlyContinue)) {
            $sessionName = Resolve-WinsmuxColabSessionName -ProjectDir $Context.ProjectDir -SlotId $slotId -Template ([string]$slotConfig.SessionName)
        }

        $requestedGpu = Join-WorkersValue (Get-SendConfigValue -InputObject $colabSession -Name 'requested_gpu' -Default @())
        if ([string]::IsNullOrWhiteSpace($requestedGpu)) {
            $requestedGpu = Join-WorkersValue @($slotConfig.GpuPreference)
        }

        $actualGpu = [string](Get-SendConfigValue -InputObject $colabSession -Name 'selected_gpu' -Default '')
        $degradedReason = [string](Get-SendConfigValue -InputObject $colabSession -Name 'degraded_reason' -Default '')
        $lastCommand = ''
        $lastCommandAt = ''
        if ($null -ne $entry) {
            $lastCommand = [string](Get-SendConfigValue -InputObject $entry -Name 'LastCommand' -Default '')
            $lastCommandAt = [string](Get-SendConfigValue -InputObject $entry -Name 'LastCommandAt' -Default '')
            if ([string]::IsNullOrWhiteSpace($lastCommand)) {
                $lastCommand = [string](Get-SendConfigValue -InputObject $entry -Name 'Task' -Default '')
            }
            if ([string]::IsNullOrWhiteSpace($lastCommand)) {
                $lastCommand = [string](Get-SendConfigValue -InputObject $entry -Name 'LastEvent' -Default '')
            }
        }

        $approvedLaunch = if ($null -ne $entry) { Get-SendConfigValue -InputObject $entry -Name 'ApprovedLaunch' -Default $null } else { $null }
        $approvedAutoLaunch = ConvertTo-WorkersLaunchApprovalValue (Get-SendConfigValue -InputObject $approvedLaunch -Name 'auto_launch' -Default $null)
        $autoLaunch = $true
        if ($approvedAutoLaunch -in @('true', 'false')) {
            $autoLaunch = [string]::Equals($approvedAutoLaunch, 'true', [System.StringComparison]::OrdinalIgnoreCase)
        } elseif ($null -ne $entry -and (Test-DeferredPaneStartManifestEntry -ManifestEntry $entry)) {
            $autoLaunch = $false
        }
        $currentLaunch = New-WorkersLaunchApprovalSummary -SlotId $slotId -SlotConfig $slotConfig -AutoLaunch:$autoLaunch
        $approvalDifferences = @(Get-WorkersLaunchApprovalDifferences -ApprovedLaunch $approvedLaunch -CurrentLaunch $currentLaunch)

        $rows.Add([PSCustomObject][ordered]@{
            Slot           = ConvertTo-WorkersSlotAlias -SlotId $slotId
            SlotId         = $slotId
            PaneId         = if ($null -ne $entry) { [string]$entry.PaneId } else { '' }
            State          = $state
            PaneState      = $paneState
            ManifestStatus = $manifestStatus
            Backend        = [string]$slotConfig.WorkerBackend
            Role           = $workerRole
            Session        = $sessionName
            RequestedGpu   = $requestedGpu
            ActualGpu      = $actualGpu
            DegradedReason = $degradedReason
            LastCommand    = $lastCommand
            LastCommandAt  = $lastCommandAt
            ApprovedLaunch = $approvedLaunch
            CurrentLaunch  = $currentLaunch
            ApprovalDifferences = @($approvalDifferences)
            Heartbeat      = $heartbeat
            HeartbeatHealth = $heartbeatHealth
            HeartbeatState = $heartbeatState
            Broker         = $broker
            Policy         = $policy
        }) | Out-Null
    }

    return @($rows)
}

function Select-WorkersRows {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $resolved = Resolve-WorkersSlotId -Target $Target
    if ([string]::IsNullOrWhiteSpace($resolved) -or $resolved -eq 'all') {
        return @($Rows)
    }

    $selected = @($Rows | Where-Object {
        [string]::Equals([string]$_.SlotId, $resolved, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals([string]$_.Slot, $Target, [System.StringComparison]::OrdinalIgnoreCase)
    })

    if ($selected.Count -lt 1) {
        Stop-WithError "unknown worker slot: $Target"
    }

    return @($selected)
}

function Write-WorkersStatusOutput {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [switch]$Json
    )

    if ($Json) {
        [ordered]@{
            project_dir     = $Context.ProjectDir
            generated_at    = (Get-Date).ToUniversalTime().ToString('o')
            manifest_error  = $Context.ManifestError
            colab_state     = [ordered]@{
                path           = [string]$Context.ColabState.StatePath
                updated_at     = [string]$Context.ColabState.UpdatedAt
                degraded_count = [int]$Context.ColabState.DegradedCount
                error_reason   = [string]$Context.ColabState.ErrorReason
            }
            workers         = @(ConvertTo-WorkersStatusJsonRows -Rows $Rows)
        } | ConvertTo-Json -Depth 20 -Compress | Write-Output
        return
    }

    if ($Rows.Count -lt 1) {
        Write-Output "(no workers)"
        return
    }

    $table = $Rows |
        Select-Object Slot, SlotId, State, Backend, Role, Session, RequestedGpu, ActualGpu, DegradedReason, LastCommand |
        Format-Table -AutoSize |
        Out-String
    Write-Output ($table.TrimEnd())
}

function ConvertTo-WorkersStatusJsonRows {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    foreach ($row in @($Rows)) {
        [ordered]@{
            slot            = [string]$row.Slot
            slot_id         = [string]$row.SlotId
            pane_id         = [string]$row.PaneId
            state           = [string]$row.State
            pane_state      = [string]$row.PaneState
            manifest_status = [string]$row.ManifestStatus
            backend         = [string]$row.Backend
            role            = [string]$row.Role
            session         = [string]$row.Session
            requested_gpu   = [string]$row.RequestedGpu
            actual_gpu      = [string]$row.ActualGpu
            degraded_reason = [string]$row.DegradedReason
            last_command    = [string]$row.LastCommand
            last_command_at = [string]$row.LastCommandAt
            approved_launch = $row.ApprovedLaunch
            current_launch  = $row.CurrentLaunch
            approval_differences = @($row.ApprovalDifferences)
            heartbeat       = $row.Heartbeat
            heartbeat_health = [string]$row.HeartbeatHealth
            heartbeat_state = [string]$row.HeartbeatState
            broker          = $row.Broker
            policy          = $row.Policy
        }
    }
}

function Set-WorkersManifestLifecycleCommand {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [AllowEmptyString()][string]$Status = '',
        [AllowNull()][System.Collections.IDictionary]$ExtraProperties = $null
    )

    if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace([string]$Entry.PaneId)) {
        return
    }

    $nowText = (Get-Date).ToUniversalTime().ToString('o')
    $properties = [ordered]@{
        last_command    = $CommandName
        last_command_at = $nowText
        last_event      = $CommandName
        last_event_at   = $nowText
    }
    if (-not [string]::IsNullOrWhiteSpace($Status)) {
        $properties['status'] = $Status
    }
    if ($null -ne $ExtraProperties) {
        foreach ($propertyEntry in $ExtraProperties.GetEnumerator()) {
            $properties[[string]$propertyEntry.Key] = $propertyEntry.Value
        }
    }

    Set-PaneControlManifestPaneProperties -ManifestPath $Entry.ManifestPath -PaneId $Entry.PaneId -Properties $properties
}

function New-WorkersLifecycleResult {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowEmptyString()][string]$Reason = ''
    )

    return [ordered]@{
        slot_id       = [string]$Row.SlotId
        slot          = [string]$Row.Slot
        pane_id       = [string]$Row.PaneId
        action        = $Action
        status        = $Status
        reason        = $Reason
        backend       = [string]$Row.Backend
        worker_state  = [string]$Row.State
        last_command  = "$Action"
        approved_launch = $Row.ApprovedLaunch
        current_launch  = $Row.CurrentLaunch
        approval_differences = @($Row.ApprovalDifferences)
    }
}

function New-WorkersRunId {
    param([Parameter(Mandatory = $true)][string]$SlotId)

    $slotSlug = ($SlotId.ToLowerInvariant() -replace '[^a-z0-9_-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slotSlug)) {
        $slotSlug = 'worker'
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return "$slotSlug-$stamp-$suffix"
}

function Get-WorkersNowUtc {
    $rawNow = [string]$env:WINSMUX_TEST_NOW_UTC
    if (-not [string]::IsNullOrWhiteSpace($rawNow)) {
        try {
            return ([datetimeoffset]::Parse($rawNow, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)).UtcDateTime
        } catch {
            Stop-WithError "WINSMUX_TEST_NOW_UTC is invalid: $rawNow"
        }
    }

    return (Get-Date).ToUniversalTime()
}

function ConvertTo-WorkersUtcDateTime {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return ([datetimeoffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)).UtcDateTime
    } catch {
        return $null
    }
}

function Get-WorkersHeartbeatThresholdSeconds {
    param(
        [int]$Value,
        [Parameter(Mandatory = $true)][string]$EnvName,
        [int]$Default
    )

    if ($Value -gt 0) {
        return $Value
    }

    $envItem = Get-Item -Path "Env:$EnvName" -ErrorAction SilentlyContinue
    $raw = ''
    if ($null -ne $envItem) {
        $raw = [string]$envItem.Value
    }
    $parsed = 0
    if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) {
        return $parsed
    }

    return $Default
}

function Assert-WorkersHeartbeatState {
    param([AllowEmptyString()][string]$State)

    $normalized = ([string]$State).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return 'running'
    }

    $allowed = @('running', 'blocked', 'approval_waiting', 'child_wait', 'stalled', 'offline', 'completed', 'resumable')
    if ($allowed -notcontains $normalized) {
        Stop-WithError "unsupported heartbeat state: $State"
    }

    return $normalized
}

function Assert-WorkersPathSegment {
    param(
        [AllowEmptyString()][string]$Value,
        [AllowEmptyString()][string]$Name = 'path segment'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Stop-WithError "$Name is required"
    }
    if ($Value -notmatch '^[A-Za-z0-9._-]+$' -or $Value -eq '.' -or $Value -eq '..' -or $Value.Contains('..')) {
        Stop-WithError "$Name contains unsupported characters: $Value"
    }

    return $Value
}

function ConvertTo-WorkersProjectRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    $projectFull = [System.IO.Path]::GetFullPath($ProjectDir)
    $candidateFull = [System.IO.Path]::GetFullPath($FullPath)
    $relative = [System.IO.Path]::GetRelativePath($projectFull, $candidateFull)
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('..') -or [System.IO.Path]::IsPathRooted($relative)) {
        Stop-WithError "path must stay under project directory: $FullPath"
    }

    return $relative.Replace('\', '/')
}

function Assert-WorkersNoReparsePointPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$FullPath,
        [AllowEmptyString()][string]$Name = 'path'
    )

    $projectFull = [System.IO.Path]::GetFullPath($ProjectDir).TrimEnd('\', '/')
    $current = [System.IO.Path]::GetFullPath($FullPath)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $currentFull = [System.IO.Path]::GetFullPath($current).TrimEnd('\', '/')
        if ([string]::Equals($currentFull, $projectFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        if (Test-Path -LiteralPath $currentFull) {
            $item = Get-Item -LiteralPath $currentFull -Force
            if (([int]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0) {
                $relative = ConvertTo-WorkersProjectRelativePath -ProjectDir $ProjectDir -FullPath $currentFull
                Stop-WithError "$Name contains unsupported reparse point: $relative"
            }
        }

        $parent = Split-Path -Parent $currentFull
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $currentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent
    }
}

function Get-WorkersPathExclusionReason {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $normalized = $RelativePath.Replace('\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ''
    }

    $blockedSegments = @(
        '.git', '.hg', '.svn', '.winsmux', '.orchestra-prompts',
        'node_modules', '.venv', 'venv', 'env', 'dist', 'build', 'target',
        'coverage', '.coverage', '.pytest_cache', '.mypy_cache', '.ruff_cache'
    )
    foreach ($segment in @($normalized.Split('/'))) {
        $lower = $segment.ToLowerInvariant()
        if ($blockedSegments -contains $lower) {
            return "excluded_segment:$lower"
        }
    }

    $leaf = (Split-Path -Leaf $normalized).ToLowerInvariant()
    if ($leaf -eq '.env' -or $leaf.StartsWith('.env.')) {
        return 'secret_like_file'
    }
    if ($leaf -in @('id_rsa', 'id_ed25519', 'credentials.json', 'token.json')) {
        return 'secret_like_file'
    }
    if ($leaf -match '\.(pem|key|pfx|p12|crt|cer)$') {
        return 'secret_like_file'
    }
    if ($leaf -match '(^|[._-])(secret|secrets|token|credential|credentials)([._-]|$)') {
        return 'secret_like_file'
    }

    return ''
}

function Get-WorkersUploadMaxBytes {
    $raw = [string]$env:WINSMUX_WORKER_UPLOAD_MAX_BYTES
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $parsed = 0L
        if ([long]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) {
            return $parsed
        }
    }

    return 104857600L
}

function ConvertTo-WorkersSafeLogText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ''
    }

    $safe = [string]$Text
    $safe = [regex]::Replace($safe, '(?is)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----', '[PRIVATE_KEY_REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)(?<![A-Za-z0-9_])(["'']?authorization["'']?\s*[:=]\s*["'']?\s*bearer\s+)[^\s"'',;}]+', '$1[REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)(?<![A-Za-z0-9_])(["'']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|oauth[_-]?token|token|password|passwd|secret|credential|credentials)["'']?\s*[:=]\s*["'']?)[^\s"'',;}]+', '$1[REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)/content/drive/(?:MyDrive|Shareddrives)(?:/[^\s"'']*)?', '[DRIVE_PATH_REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z]:\\[^"'',;}\r\n]+', '[LOCAL_PATH_REDACTED]')
    return $safe
}

function ConvertTo-WorkersSafeArgumentArray {
    param([AllowNull()][string[]]$Arguments)

    $safe = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @($Arguments)) {
        $safe.Add((ConvertTo-WorkersSafeLogText -Text ([string]$argument))) | Out-Null
    }

    return @($safe)
}

function Assert-WorkersBrokerEndpoint {
    param([AllowEmptyString()][string]$Endpoint)

    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        Stop-WithError 'broker endpoint is required'
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Endpoint.Trim(), [System.UriKind]::Absolute, [ref]$uri)) {
        Stop-WithError "broker endpoint must be an absolute URI: $Endpoint"
    }
    if ($uri.Scheme -notin @('http', 'https')) {
        Stop-WithError "broker endpoint must use http or https: $Endpoint"
    }
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
        Stop-WithError 'broker endpoint must not include credentials'
    }

    return $uri.AbsoluteUri
}

function New-WorkersBrokerRunTokenValue {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ([Convert]::ToBase64String($bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-WorkersBrokerRunTokenFingerprint {
    param([AllowEmptyString()][string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)
}

function Read-WorkersBrokerTokenManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Write-WorkersBrokerTokenHeartbeat {
    param(
        [Parameter(Mandatory = $true)]$Slot,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][datetime]$NowUtc,
        [Parameter(Mandatory = $true)][string]$State,
        [AllowEmptyString()][string]$Message = ''
    )

    $safeState = Assert-WorkersHeartbeatState -State $State
    $heartbeatPath = Join-Path $RunDir 'heartbeat.json'
    $payload = [ordered]@{
        contract_version      = 1
        command               = 'workers.heartbeat'
        status                = 'marked'
        slot                  = [string]$Slot.Row.Slot
        slot_id               = [string]$Slot.Row.SlotId
        run_id                = $RunId
        execution_profile     = 'isolated-enterprise'
        state                 = $safeState
        message               = ConvertTo-WorkersSafeLogText -Text $Message
        heartbeat_at          = $NowUtc.ToString('o')
        stalled_after_seconds = 300
        offline_after_seconds = 900
        artifact              = Get-WorkersArtifactReference -ProjectDir $ProjectDir -Path $heartbeatPath
    }
    Write-WorkersJsonArtifact -Path $heartbeatPath -Data $payload | Out-Null
    return (ConvertTo-WorkersHeartbeatStatus -Payload $payload -Artifact ([string]$payload.artifact) -NowUtc $NowUtc -StalledAfterSeconds 300 -OfflineAfterSeconds 900)
}

function Get-WorkersColabSafetyFinding {
    param([AllowNull()][string[]]$Values)

    $rules = @(
        @{ Code = 'prohibited_mining'; Pattern = '(?i)\b(xmrig|cpuminer|ethminer|lolminer|hashcat|john)\b' },
        @{ Code = 'prohibited_proxying'; Pattern = '(?i)\b(ngrok|cloudflared\s+tunnel|frpc|frps|ssh\s+-R)\b' },
        @{ Code = 'prohibited_network_scan'; Pattern = '(?i)\b(nmap|masscan|zmap|nikto|sqlmap)\b' },
        @{ Code = 'prohibited_file_hosting'; Pattern = '(?i)(python\d*(?:\.\d+)?\s+-m\s+http\.server|SimpleHTTPServer|php\s+-S)\b' },
        @{ Code = 'prohibited_destructive_shell'; Pattern = '(?i)(\brm\s+-rf\s+/(?:\s|$)|Remove-Item\b[^\r\n;|]*\b-Recurse\b[^\r\n;|]*\b-Force\b)' },
        @{ Code = 'prohibited_pipe_to_shell'; Pattern = '(?i)\b(curl|wget)\b[^\r\n|;]*\|\s*(sh|bash|pwsh|powershell)\b' },
        @{ Code = 'prohibited_infinite_loop'; Pattern = '(?i)(\bwhile\s+(?:\$?true|1)\b|\bfor\s*\(\s*;\s*;\s*\))' },
        @{ Code = 'prohibited_credential_dumping'; Pattern = '(?i)\b(mimikatz|secretsdump|credential dumping|dump credentials)\b' }
    )

    foreach ($value in @($Values)) {
        $text = [string]$value
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($text -match '(?is)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----') {
            return [PSCustomObject]@{ Code = 'secret_like_input'; Source = 'colab_task_input' }
        }
        if ($text -match '(?i)(?<![A-Za-z0-9_])["'']?authorization["'']?\s*[:=]\s*["'']?\s*bearer\s+\S+') {
            return [PSCustomObject]@{ Code = 'secret_like_input'; Source = 'colab_task_input' }
        }
        if ($text -match '(?i)(?<![A-Za-z0-9_])["'']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|oauth[_-]?token|token|password|passwd|secret|credential|credentials)["'']?\s*[:=]\s*["'']?[A-Za-z0-9_./+=-]{8,}') {
            return [PSCustomObject]@{ Code = 'secret_like_input'; Source = 'colab_task_input' }
        }

        foreach ($rule in @($rules)) {
            if ($text -match [string]$rule.Pattern) {
                return [PSCustomObject]@{ Code = [string]$rule.Code; Source = 'colab_task_input' }
            }
        }
    }

    return $null
}

function Assert-WorkersColabSafetyInput {
    param(
        [AllowNull()][string[]]$Values,
        [AllowEmptyString()][string]$Name = 'Colab task input'
    )

    $finding = Get-WorkersColabSafetyFinding -Values $Values
    if ($null -ne $finding) {
        Stop-WithError "$Name rejected by Colab safety policy: $($finding.Code)"
    }
}

function Get-WorkersExecSafetyInputValues {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [AllowNull()][string[]]$ScriptArgs
    )

    $values = [System.Collections.Generic.List[string]]::new()
    $items = @($ScriptArgs)
    for ($index = 0; $index -lt $items.Count; $index++) {
        $value = [string]$items[$index]
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values.Add($value) | Out-Null
        }

        $taskJsonPath = ''
        if ($value -eq '--task-json' -and $index + 1 -lt $items.Count) {
            $taskJsonPath = [string]$items[$index + 1]
        } elseif ($value.StartsWith('--task-json=', [System.StringComparison]::Ordinal)) {
            $taskJsonPath = $value.Substring('--task-json='.Length)
        }

        if (-not [string]::IsNullOrWhiteSpace($taskJsonPath)) {
            $taskJsonInfo = Resolve-WorkersProjectPath -ProjectDir $ProjectDir -Path $taskJsonPath -MustExist -AllowFile -MaxBytes (Get-WorkersUploadMaxBytes)
            $taskJsonContent = Get-Content -LiteralPath ([string]$taskJsonInfo.FullPath) -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($taskJsonContent)) {
                $values.Add([string]$taskJsonContent) | Out-Null
            }
        }
    }

    return @($values)
}

function Resolve-WorkersProjectPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$MustExist,
        [switch]$AllowFile,
        [switch]$AllowDirectory,
        [switch]$AllowRuntimePath,
        [long]$MaxBytes = 0
    )

    $candidate = $Path
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $ProjectDir $candidate
    }
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    $relative = ConvertTo-WorkersProjectRelativePath -ProjectDir $ProjectDir -FullPath $fullPath
    Assert-WorkersNoReparsePointPath -ProjectDir $ProjectDir -FullPath $fullPath -Name 'path'

    if ($MustExist -and -not (Test-Path -LiteralPath $fullPath)) {
        Stop-WithError "path not found: $Path"
    }

    $isDirectory = Test-Path -LiteralPath $fullPath -PathType Container
    $isFile = Test-Path -LiteralPath $fullPath -PathType Leaf
    if ($isDirectory -and -not $AllowDirectory) {
        Stop-WithError "directory is not allowed here: $relative"
    }
    if ($isFile -and -not $AllowFile) {
        Stop-WithError "file is not allowed here: $relative"
    }

    $reason = Get-WorkersPathExclusionReason -RelativePath $relative
    if ($AllowRuntimePath -and $reason -eq 'excluded_segment:.winsmux') {
        $reason = ''
    }
    if (-not [string]::IsNullOrWhiteSpace($reason)) {
        Stop-WithError "unsafe path rejected: $relative ($reason)"
    }

    if ($isFile -and $MaxBytes -gt 0) {
        $item = Get-Item -LiteralPath $fullPath -Force
        if ([long]$item.Length -gt $MaxBytes) {
            Stop-WithError "file exceeds max upload size: $relative"
        }
    }

    return [PSCustomObject]@{
        FullPath     = $fullPath
        RelativePath = $relative
        IsDirectory  = $isDirectory
        IsFile       = $isFile
    }
}

function Test-WorkersPathIsUnderDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $dirFull = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
    return (
        [string]::Equals($pathFull, $dirFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($dirFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($dirFull + [System.IO.Path]::AltDirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Get-WorkersUploadManifestEntries {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$SourceInfo,
        [object[]]$AllowDirs = @(),
        [long]$MaxBytes
    )

    $files = [System.Collections.Generic.List[object]]::new()
    $excluded = [System.Collections.Generic.List[object]]::new()

    if ($SourceInfo.IsFile) {
        $files.Add([ordered]@{
            path = [string]$SourceInfo.RelativePath
            size = [long](Get-Item -LiteralPath $SourceInfo.FullPath -Force).Length
        }) | Out-Null
        return [PSCustomObject]@{ Files = @($files); Excluded = @($excluded) }
    }

    if (-not $SourceInfo.IsDirectory) {
        Stop-WithError "upload source must be a file or directory: $($SourceInfo.RelativePath)"
    }
    if ($AllowDirs.Count -lt 1) {
        Stop-WithError 'directory upload requires --allow-dir <path>'
    }

    $allowed = $false
    foreach ($allowDir in @($AllowDirs)) {
        if (Test-WorkersPathIsUnderDirectory -Path $SourceInfo.FullPath -Directory $allowDir.FullPath) {
            $allowed = $true
            break
        }
    }
    if (-not $allowed) {
        Stop-WithError "directory upload source is not under an allowlisted directory: $($SourceInfo.RelativePath)"
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $SourceInfo.FullPath -Recurse -Force)) {
        if (([int]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0) {
            $relative = ConvertTo-WorkersProjectRelativePath -ProjectDir $ProjectDir -FullPath $item.FullName
            Stop-WithError "upload source contains unsupported reparse point: $relative"
        }
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $SourceInfo.FullPath -File -Recurse -Force)) {
        $relative = ConvertTo-WorkersProjectRelativePath -ProjectDir $ProjectDir -FullPath $item.FullName
        $reason = Get-WorkersPathExclusionReason -RelativePath $relative
        if ([string]::IsNullOrWhiteSpace($reason) -and $MaxBytes -gt 0 -and [long]$item.Length -gt $MaxBytes) {
            $reason = 'oversized_file'
        }
        if (-not [string]::IsNullOrWhiteSpace($reason)) {
            $excluded.Add([ordered]@{ path = $relative; reason = $reason }) | Out-Null
            continue
        }

        $files.Add([ordered]@{ path = $relative; size = [long]$item.Length }) | Out-Null
    }

    if ($files.Count -lt 1) {
        Stop-WithError "upload source contains no allowed files: $($SourceInfo.RelativePath)"
    }

    return [PSCustomObject]@{ Files = @($files); Excluded = @($excluded) }
}

function Write-WorkersJsonArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $content = ($Data | ConvertTo-Json -Depth 24)
    Write-ClmSafeTextFile -Path $Path -Content $content
    return $Path
}

function New-WorkersSafeUploadSource {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$SourceInfo,
        [Parameter(Mandatory = $true)][object[]]$Files,
        [Parameter(Mandatory = $true)][string]$RunDir
    )

    if ($SourceInfo.IsFile) {
        return [PSCustomObject]@{
            FullPath  = [string]$SourceInfo.FullPath
            Reference = [string]$SourceInfo.RelativePath
            Staged    = $false
        }
    }

    $stagingRoot = Join-Path $RunDir 'upload-source'
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    $sourceFull = [System.IO.Path]::GetFullPath([string]$SourceInfo.FullPath)
    foreach ($file in @($Files)) {
        $relativeProjectPath = [string](Get-SendConfigValue -InputObject $file -Name 'path' -Default '')
        if ([string]::IsNullOrWhiteSpace($relativeProjectPath)) {
            continue
        }

        $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $ProjectDir ($relativeProjectPath.Replace('/', '\'))))
        Assert-WorkersNoReparsePointPath -ProjectDir $ProjectDir -FullPath $sourcePath -Name 'upload manifest file'
        if (-not (Test-WorkersPathIsUnderDirectory -Path $sourcePath -Directory $sourceFull)) {
            Stop-WithError "upload manifest file is outside source directory: $relativeProjectPath"
        }

        $relativeToSource = [System.IO.Path]::GetRelativePath($sourceFull, $sourcePath)
        if ([string]::IsNullOrWhiteSpace($relativeToSource) -or $relativeToSource.StartsWith('..') -or [System.IO.Path]::IsPathRooted($relativeToSource)) {
            Stop-WithError "upload manifest file is outside source directory: $relativeProjectPath"
        }

        $destinationPath = Join-Path $stagingRoot $relativeToSource
        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }

    return [PSCustomObject]@{
        FullPath  = $stagingRoot
        Reference = Get-WorkersArtifactReference -ProjectDir $ProjectDir -Path $stagingRoot
        Staged    = $true
    }
}

function Get-WorkersRunDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $safeSlotId = Assert-WorkersPathSegment -Value $SlotId -Name 'slot id'
    $safeRunId = Assert-WorkersPathSegment -Value $RunId -Name 'run id'
    return Join-Path (Join-Path (Join-Path (Join-Path $ProjectDir '.winsmux') 'worker-runs') $safeSlotId) $safeRunId
}

function Get-WorkersIsolatedWorkspaceRoot {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return [System.IO.Path]::GetFullPath((Join-Path (Join-Path $ProjectDir '.winsmux') 'isolated-workspaces'))
}

function Get-WorkersIsolatedWorkspaceRunDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $safeSlotId = Assert-WorkersPathSegment -Value $SlotId -Name 'slot id'
    $safeRunId = Assert-WorkersPathSegment -Value $RunId -Name 'run id'
    return [System.IO.Path]::GetFullPath((Join-Path (Join-Path (Get-WorkersIsolatedWorkspaceRoot -ProjectDir $ProjectDir) $safeSlotId) $safeRunId))
}

function Get-WorkersSecretRunDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ExecutionProfile
    )

    if ([string]::Equals($ExecutionProfile, 'isolated-enterprise', [System.StringComparison]::OrdinalIgnoreCase)) {
        $runDir = Get-WorkersIsolatedWorkspaceRunDirectory -ProjectDir $ProjectDir -SlotId $SlotId -RunId $RunId
        if (-not (Test-Path -LiteralPath $runDir -PathType Container)) {
            Stop-WithError "isolated secret projection requires an existing isolated workspace run: $RunId"
        }
        Assert-WorkersIsolatedWorkspaceCleanupTarget -ProjectDir $ProjectDir -RunDir $runDir
        return $runDir
    }

    if ([string]::Equals($ExecutionProfile, 'local-windows', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [System.IO.Path]::GetFullPath((Get-WorkersRunDirectory -ProjectDir $ProjectDir -SlotId $SlotId -RunId $RunId))
    }

    Stop-WithError "unsupported execution profile for secret projection: $ExecutionProfile"
}

function Get-WorkersHeartbeatRunDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ExecutionProfile,
        [switch]$CreateLocal,
        [switch]$AllowMissing
    )

    if ([string]::Equals($ExecutionProfile, 'isolated-enterprise', [System.StringComparison]::OrdinalIgnoreCase)) {
        $runDir = Get-WorkersIsolatedWorkspaceRunDirectory -ProjectDir $ProjectDir -SlotId $SlotId -RunId $RunId
        if (-not (Test-Path -LiteralPath $runDir -PathType Container)) {
            if ($AllowMissing) {
                return $runDir
            }
            Stop-WithError "isolated heartbeat requires an existing isolated workspace run: $RunId"
        }
        Assert-WorkersIsolatedWorkspaceCleanupTarget -ProjectDir $ProjectDir -RunDir $runDir
        return $runDir
    }

    if ([string]::Equals($ExecutionProfile, 'local-windows', [System.StringComparison]::OrdinalIgnoreCase)) {
        $runDir = [System.IO.Path]::GetFullPath((Get-WorkersRunDirectory -ProjectDir $ProjectDir -SlotId $SlotId -RunId $RunId))
        if ($CreateLocal -and -not (Test-Path -LiteralPath $runDir -PathType Container)) {
            New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        }
        return $runDir
    }

    Stop-WithError "unsupported execution profile for heartbeat: $ExecutionProfile"
}

function New-WorkersHeartbeatAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [AllowNull()]$HeartbeatAt,
        [Parameter(Mandatory = $true)][datetime]$NowUtc,
        [int]$StalledAfterSeconds,
        [int]$OfflineAfterSeconds
    )

    $health = $State
    $reason = 'state_reported'
    $ageSeconds = $null
    $requiresUser = $false
    $waitingForChildRun = $false
    $terminal = $false
    $resumable = $false

    if ($null -ne $HeartbeatAt) {
        $heartbeatAtUtc = [datetime]$HeartbeatAt
        $ageSeconds = [int][math]::Max(0, [math]::Floor(($NowUtc - $heartbeatAtUtc).TotalSeconds))
    }

    switch ($State) {
        'blocked' {
            $health = 'blocked'
            $reason = 'blocked_by_worker'
            $requiresUser = $true
        }
        'approval_waiting' {
            $health = 'approval_waiting'
            $reason = 'approval_waiting'
            $requiresUser = $true
        }
        'child_wait' {
            $health = 'child_wait'
            $reason = 'child_run_waiting'
            $waitingForChildRun = $true
        }
        'offline' {
            $health = 'offline'
            $reason = 'offline_reported'
            $terminal = $true
        }
        'stalled' {
            if ($null -eq $HeartbeatAt) {
                $health = 'offline'
                $reason = 'heartbeat_invalid'
            } elseif ($ageSeconds -gt $OfflineAfterSeconds) {
                $health = 'offline'
                $reason = 'heartbeat_expired'
            } else {
                $health = 'stalled'
                $reason = 'stalled_by_worker'
            }
        }
        'completed' {
            $health = 'completed'
            $reason = 'run_completed'
            $terminal = $true
        }
        'resumable' {
            $health = 'resumable'
            $reason = 'run_resumable'
            $resumable = $true
        }
        default {
            if ($null -eq $HeartbeatAt) {
                $health = 'offline'
                $reason = 'heartbeat_invalid'
            } elseif ($ageSeconds -gt $OfflineAfterSeconds) {
                $health = 'offline'
                $reason = 'heartbeat_expired'
            } elseif ($ageSeconds -gt $StalledAfterSeconds) {
                $health = 'stalled'
                $reason = 'heartbeat_stale'
            } else {
                $health = 'running'
                $reason = 'heartbeat_recent'
            }
        }
    }

    return [ordered]@{
        health                = $health
        reason                = $reason
        age_seconds           = $ageSeconds
        stalled_after_seconds = $StalledAfterSeconds
        offline_after_seconds = $OfflineAfterSeconds
        requires_user         = $requiresUser
        waiting_for_child_run = $waitingForChildRun
        terminal              = $terminal
        resumable             = $resumable
    }
}

function ConvertTo-WorkersHeartbeatStatus {
    param(
        [Parameter(Mandatory = $true)]$Payload,
        [Parameter(Mandatory = $true)][string]$Artifact,
        [Parameter(Mandatory = $true)][datetime]$NowUtc,
        [int]$StalledAfterSeconds,
        [int]$OfflineAfterSeconds,
        [bool]$PreferPayloadThresholds = $true
    )

    $state = Assert-WorkersHeartbeatState -State ([string](Get-SendConfigValue -InputObject $Payload -Name 'state' -Default 'running'))
    $heartbeatAtText = [string](Get-SendConfigValue -InputObject $Payload -Name 'heartbeat_at' -Default '')
    $heartbeatAt = ConvertTo-WorkersUtcDateTime -Value $heartbeatAtText
    $effectiveStalledAfter = $StalledAfterSeconds
    $effectiveOfflineAfter = $OfflineAfterSeconds
    if ($PreferPayloadThresholds) {
        $effectiveStalledAfter = [int](Get-SendConfigValue -InputObject $Payload -Name 'stalled_after_seconds' -Default $StalledAfterSeconds)
        $effectiveOfflineAfter = [int](Get-SendConfigValue -InputObject $Payload -Name 'offline_after_seconds' -Default $OfflineAfterSeconds)
    }
    if ($effectiveStalledAfter -lt 1) {
        $effectiveStalledAfter = $StalledAfterSeconds
    }
    if ($effectiveOfflineAfter -le $effectiveStalledAfter) {
        $effectiveOfflineAfter = $effectiveStalledAfter + 1
    }
    $assessment = New-WorkersHeartbeatAssessment -State $state -HeartbeatAt $heartbeatAt -NowUtc $NowUtc -StalledAfterSeconds $effectiveStalledAfter -OfflineAfterSeconds $effectiveOfflineAfter

    return [ordered]@{
        contract_version      = [int](Get-SendConfigValue -InputObject $Payload -Name 'contract_version' -Default 1)
        command               = 'workers.heartbeat'
        slot                  = [string](Get-SendConfigValue -InputObject $Payload -Name 'slot' -Default '')
        slot_id               = [string](Get-SendConfigValue -InputObject $Payload -Name 'slot_id' -Default '')
        run_id                = [string](Get-SendConfigValue -InputObject $Payload -Name 'run_id' -Default '')
        execution_profile     = [string](Get-SendConfigValue -InputObject $Payload -Name 'execution_profile' -Default '')
        state                 = $state
        health                = [string]$assessment.health
        reason                = [string]$assessment.reason
        message               = [string](Get-SendConfigValue -InputObject $Payload -Name 'message' -Default '')
        heartbeat_at          = $heartbeatAtText
        checked_at            = $NowUtc.ToString('o')
        age_seconds           = $assessment.age_seconds
        stalled_after_seconds = [int]$assessment.stalled_after_seconds
        offline_after_seconds = [int]$assessment.offline_after_seconds
        requires_user         = [bool]$assessment.requires_user
        waiting_for_child_run = [bool]$assessment.waiting_for_child_run
        terminal              = [bool]$assessment.terminal
        resumable             = [bool]$assessment.resumable
        artifact              = $Artifact
    }
}

function Read-WorkersHeartbeatArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][datetime]$NowUtc,
        [int]$StalledAfterSeconds,
        [int]$OfflineAfterSeconds,
        [bool]$PreferPayloadThresholds = $true
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $payload = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $artifact = Get-WorkersArtifactReference -ProjectDir $ProjectDir -Path $Path
        return ConvertTo-WorkersHeartbeatStatus -Payload $payload -Artifact $artifact -NowUtc $NowUtc -StalledAfterSeconds $StalledAfterSeconds -OfflineAfterSeconds $OfflineAfterSeconds -PreferPayloadThresholds:([bool]$PreferPayloadThresholds)
    } catch {
        return $null
    }
}

function Get-WorkersLatestHeartbeatStatus {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [AllowEmptyString()][string]$RunId = '',
        [AllowEmptyString()][string]$ExecutionProfile = '',
        [int]$StalledAfterSeconds = 0,
        [int]$OfflineAfterSeconds = 0,
        [bool]$PreferPayloadThresholds = $true
    )

    $safeSlotId = Assert-WorkersPathSegment -Value $SlotId -Name 'slot id'
    $safeRunId = ''
    if (-not [string]::IsNullOrWhiteSpace($RunId)) {
        try {
            $safeRunId = Assert-WorkersPathSegment -Value $RunId -Name 'run id'
        } catch {
            return $null
        }
    }
    $nowUtc = Get-WorkersNowUtc
    $stalledAfter = Get-WorkersHeartbeatThresholdSeconds -Value $StalledAfterSeconds -EnvName 'WINSMUX_WORKER_HEARTBEAT_STALLED_AFTER_SECONDS' -Default 300
    $offlineAfter = Get-WorkersHeartbeatThresholdSeconds -Value $OfflineAfterSeconds -EnvName 'WINSMUX_WORKER_HEARTBEAT_OFFLINE_AFTER_SECONDS' -Default 900
    if ($offlineAfter -le $stalledAfter) {
        $offlineAfter = $stalledAfter + 1
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    $localRoot = Join-Path (Join-Path (Join-Path $ProjectDir '.winsmux') 'worker-runs') $safeSlotId
    $isolatedRoot = Join-Path (Get-WorkersIsolatedWorkspaceRoot -ProjectDir $ProjectDir) $safeSlotId
    $profile = [string]$ExecutionProfile
    if (
        -not [string]::IsNullOrWhiteSpace($profile) -and
        -not [string]::Equals($profile, 'local-windows', [System.StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::Equals($profile, 'isolated-enterprise', [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        return $null
    }
    $roots = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::Equals($profile, 'isolated-enterprise', [System.StringComparison]::OrdinalIgnoreCase)) {
        $roots.Add($localRoot) | Out-Null
    }
    if (-not [string]::Equals($profile, 'local-windows', [System.StringComparison]::OrdinalIgnoreCase)) {
        $roots.Add($isolatedRoot) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($safeRunId)) {
        foreach ($root in @($roots)) {
            $heartbeatPath = Join-Path (Join-Path $root $safeRunId) 'heartbeat.json'
            if (Test-Path -LiteralPath $heartbeatPath -PathType Leaf) {
                $candidates.Add((Get-Item -LiteralPath $heartbeatPath -Force)) | Out-Null
            }
        }
    } else {
        foreach ($root in @($roots)) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                continue
            }
            foreach ($runDir in @(Get-ChildItem -LiteralPath $root -Directory)) {
                $heartbeatPath = Join-Path $runDir.FullName 'heartbeat.json'
                if (Test-Path -LiteralPath $heartbeatPath -PathType Leaf) {
                    $candidates.Add((Get-Item -LiteralPath $heartbeatPath -Force)) | Out-Null
                }
            }
        }
    }

    foreach ($candidate in @($candidates | Sort-Object LastWriteTimeUtc -Descending)) {
        $status = Read-WorkersHeartbeatArtifact -ProjectDir $ProjectDir -Path ([string]$candidate.FullName) -NowUtc $nowUtc -StalledAfterSeconds $stalledAfter -OfflineAfterSeconds $offlineAfter -PreferPayloadThresholds $PreferPayloadThresholds
        if ($null -ne $status) {
            return $status
        }
    }

    return $null
}

function New-WorkersHeartbeatMissingStatus {
    param(
        [Parameter(Mandatory = $true)]$Slot,
        [AllowEmptyString()][string]$RunId,
        [AllowEmptyString()][string]$ExecutionProfile,
        [int]$StalledAfterSeconds,
        [int]$OfflineAfterSeconds,
        [Parameter(Mandatory = $true)][datetime]$NowUtc
    )

    return [ordered]@{
        contract_version      = 1
        command               = 'workers.heartbeat'
        slot                  = [string]$Slot.Row.Slot
        slot_id               = [string]$Slot.Row.SlotId
        run_id                = $RunId
        execution_profile     = $ExecutionProfile
        state                 = 'offline'
        health                = 'offline'
        reason                = 'heartbeat_missing'
        message               = ''
        heartbeat_at          = ''
        checked_at            = $NowUtc.ToString('o')
        age_seconds           = $null
        stalled_after_seconds = $StalledAfterSeconds
        offline_after_seconds = $OfflineAfterSeconds
        requires_user         = $false
        waiting_for_child_run = $false
        terminal              = $false
        resumable             = $false
        artifact              = ''
    }
}

function Test-WorkersWindowsReservedPathName {
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $trimmed = $Name.TrimEnd([char[]]@('.', ' '))
    if ($trimmed.Length -ne $Name.Length) {
        return $true
    }

    $baseName = ($trimmed -split '\.')[0]
    $reserved = @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
    return ($reserved -contains $baseName.ToUpperInvariant())
}

function Assert-WorkersNoWindowsReservedPathSegments {
    param(
        [AllowEmptyString()][string]$RelativePath,
        [AllowEmptyString()][string]$Name = 'path'
    )

    $normalized = $RelativePath.Replace('\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -eq '.') {
        return
    }

    foreach ($segment in @($normalized.Split('/'))) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            Stop-WithError "$Name contains unsupported path segment: $RelativePath"
        }
        if (Test-WorkersWindowsReservedPathName -Name $segment) {
            Stop-WithError "$Name contains reserved Windows name: $segment"
        }
    }
}

function Resolve-WorkersIsolatedProjectionPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        Stop-WithError "isolated workspace includes must be project-relative paths: $Path"
    }
    if ($Path.IndexOfAny([char[]]@('*', '?')) -ge 0) {
        Stop-WithError "isolated workspace includes must not contain wildcards: $Path"
    }

    Assert-WorkersNoWindowsReservedPathSegments -RelativePath $Path -Name 'isolated workspace include'
    $info = Resolve-WorkersProjectPath -ProjectDir $ProjectDir -Path $Path -MustExist -AllowFile -AllowDirectory
    Assert-WorkersNoWindowsReservedPathSegments -RelativePath ([string]$info.RelativePath) -Name 'isolated workspace include'

    if ([string]::Equals([string]$info.RelativePath, '.', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError 'isolated workspace must project explicit files or subdirectories, not the project root'
    }

    return $info
}

function Assert-WorkersDirectoryContainsOnlyIsolatedSafeFiles {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$SourceInfo
    )

    foreach ($item in @(Get-ChildItem -LiteralPath ([string]$SourceInfo.FullPath) -Recurse -Force)) {
        $relative = ConvertTo-WorkersProjectRelativePath -ProjectDir $ProjectDir -FullPath ([string]$item.FullName)
        if (([int]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0) {
            Stop-WithError "isolated workspace include contains unsupported reparse point: $relative"
        }
        Assert-WorkersNoWindowsReservedPathSegments -RelativePath $relative -Name 'isolated workspace include'
        $reason = Get-WorkersPathExclusionReason -RelativePath $relative
        if (-not [string]::IsNullOrWhiteSpace($reason)) {
            Stop-WithError "isolated workspace include contains unsafe path: $relative ($reason)"
        }
    }
}

function Copy-WorkersIsolatedProjection {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$WorkspaceDir,
        [Parameter(Mandatory = $true)]$SourceInfo
    )

    if ([bool]$SourceInfo.IsDirectory) {
        Assert-WorkersDirectoryContainsOnlyIsolatedSafeFiles -ProjectDir $ProjectDir -SourceInfo $SourceInfo
    }

    $workspaceFull = [System.IO.Path]::GetFullPath($WorkspaceDir)
    $destination = [System.IO.Path]::GetFullPath((Join-Path $workspaceFull ([string]$SourceInfo.RelativePath).Replace('/', '\')))
    if (-not (Test-WorkersPathIsUnderDirectory -Path $destination -Directory $workspaceFull) -or [string]::Equals($destination, $workspaceFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "isolated workspace destination escaped workspace root: $($SourceInfo.RelativePath)"
    }

    if ([bool]$SourceInfo.IsFile) {
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath ([string]$SourceInfo.FullPath) -Destination $destination -Force
    } elseif ([bool]$SourceInfo.IsDirectory) {
        foreach ($file in @(Get-ChildItem -LiteralPath ([string]$SourceInfo.FullPath) -File -Recurse -Force)) {
            $relative = ConvertTo-WorkersProjectRelativePath -ProjectDir $ProjectDir -FullPath ([string]$file.FullName)
            $fileDestination = [System.IO.Path]::GetFullPath((Join-Path $workspaceFull $relative.Replace('/', '\')))
            if (-not (Test-WorkersPathIsUnderDirectory -Path $fileDestination -Directory $workspaceFull)) {
                Stop-WithError "isolated workspace destination escaped workspace root: $relative"
            }
            $parent = Split-Path -Parent $fileDestination
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath ([string]$file.FullName) -Destination $fileDestination -Force
        }
    } else {
        Stop-WithError "isolated workspace include must be a file or directory: $($SourceInfo.RelativePath)"
    }

    return [ordered]@{
        source    = [string]$SourceInfo.RelativePath
        kind      = if ([bool]$SourceInfo.IsDirectory) { 'local_directory' } else { 'local_file' }
        workspace = (Get-WorkersArtifactReference -ProjectDir $ProjectDir -Path $destination)
    }
}

function Assert-WorkersSecretName {
    param(
        [AllowEmptyString()][string]$Name,
        [AllowEmptyString()][string]$Kind = 'secret name'
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        Stop-WithError "$Kind must be a valid variable name"
    }

    return $Name
}

function Assert-WorkersSecretVaultKey {
    param([AllowEmptyString()][string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key) -or $Key -match '[\r\n]' -or $Key.Contains('..')) {
        Stop-WithError 'secret projection vault key is invalid'
    }

    return $Key
}

function ConvertTo-WorkersPowerShellSingleQuotedValue {
    param([AllowNull()][string]$Value)

    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Resolve-WorkersSecretFileTarget {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$SecretRoot
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        Stop-WithError "secret file projection must be relative: $RelativePath"
    }
    if ($RelativePath.IndexOfAny([char[]]@('*', '?')) -ge 0) {
        Stop-WithError "secret file projection must not contain wildcards: $RelativePath"
    }
    Assert-WorkersNoWindowsReservedPathSegments -RelativePath $RelativePath -Name 'secret file projection'

    $normalized = $RelativePath.Replace('\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -eq '.') {
        Stop-WithError 'secret file projection target is required'
    }

    $rootFull = [System.IO.Path]::GetFullPath($SecretRoot)
    $target = [System.IO.Path]::GetFullPath((Join-Path $rootFull $normalized.Replace('/', '\')))
    if (-not (Test-WorkersPathIsUnderDirectory -Path $target -Directory $rootFull) -or [string]::Equals($target, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "secret file projection escaped secret root: $RelativePath"
    }

    return [PSCustomObject]@{
        RelativePath = $normalized
        FullPath     = $target
    }
}

function Resolve-WorkersVaultSecretValue {
    param([Parameter(Mandatory = $true)][string]$Key)

    $safeKey = Assert-WorkersSecretVaultKey -Key $Key
    $allowTestVault = [string]::Equals([string]$env:WINSMUX_TEST_SECRET_VAULT_MODE, '1', [System.StringComparison]::Ordinal)
    if ($allowTestVault -and -not [string]::IsNullOrWhiteSpace([string]$env:WINSMUX_TEST_SECRET_VAULT_JSON)) {
        $map = $env:WINSMUX_TEST_SECRET_VAULT_JSON | ConvertFrom-Json
        $property = $map.PSObject.Properties[$safeKey]
        if ($null -eq $property) {
            Stop-WithError "credential not found: $safeKey"
        }
        return [string]$property.Value
    }

    $credTarget = "winsmux:$safeKey"
    $credPtr = [IntPtr]::Zero
    $ok = [WinCred]::CredRead($credTarget, [WinCred]::CRED_TYPE_GENERIC, 0, [ref]$credPtr)
    if (-not $ok) {
        $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errCode -eq 1168) {
            Stop-WithError "credential not found: $safeKey"
        }
        Stop-WithError "CredRead failed (error $errCode)"
    }

    try {
        $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [Type][WinCred+CREDENTIAL])
        if ($cred.CredentialBlobSize -le 0) {
            return ''
        }
        $bytes = New-Object byte[] $cred.CredentialBlobSize
        [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
        return [System.Text.Encoding]::Unicode.GetString($bytes)
    } finally {
        [WinCred]::CredFree($credPtr) | Out-Null
    }
}

function Assert-WorkersIsolatedWorkspaceCleanupTarget {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunDir
    )

    $root = Get-WorkersIsolatedWorkspaceRoot -ProjectDir $ProjectDir
    $target = [System.IO.Path]::GetFullPath($RunDir)
    if (-not (Test-WorkersPathIsUnderDirectory -Path $target -Directory $root) -or [string]::Equals($target, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "isolated workspace cleanup target escaped runtime root: $RunDir"
    }
}

function Assert-WorkersNoReparsePointUnderDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$RootDir,
        [AllowEmptyString()][string]$Name = 'directory'
    )

    $rootInfo = Get-Item -LiteralPath $RootDir -Force -ErrorAction Stop
    if (-not $rootInfo.PSIsContainer) {
        Stop-WithError "$Name is not a directory: $RootDir"
    }
    if (([int]($rootInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0) {
        Stop-WithError "$Name boundary contains unsupported reparse point: $RootDir"
    }

    $root = [System.IO.Path]::GetFullPath([string]$rootInfo.FullName)
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($root)

    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            $itemPath = [System.IO.Path]::GetFullPath([string]$item.FullName)
            if (-not (Test-WorkersPathIsUnderDirectory -Path $itemPath -Directory $root)) {
                Stop-WithError "$Name boundary child escaped root: $itemPath"
            }
            if (([int]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0) {
                Stop-WithError "$Name boundary contains unsupported reparse point: $itemPath"
            }
            if ($item.PSIsContainer) {
                $pending.Push($itemPath)
            }
        }
    }
}

function Remove-WorkersIsolatedWorkspaceRunDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunDir
    )

    Assert-WorkersIsolatedWorkspaceCleanupTarget -ProjectDir $ProjectDir -RunDir $RunDir
    $targetInfo = Get-Item -LiteralPath $RunDir -Force -ErrorAction Stop
    if (-not $targetInfo.PSIsContainer) {
        Stop-WithError "isolated workspace cleanup target is not a directory: $RunDir"
    }
    if (([int]($targetInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0) {
        Stop-WithError "isolated workspace cleanup target is a reparse point: $RunDir"
    }

    $target = [System.IO.Path]::GetFullPath([string]$targetInfo.FullName)
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $reparsePoints = [System.Collections.Generic.List[string]]::new()
    $pending.Push($target)

    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            $itemPath = [System.IO.Path]::GetFullPath([string]$item.FullName)
            if (-not (Test-WorkersPathIsUnderDirectory -Path $itemPath -Directory $target)) {
                Stop-WithError "isolated workspace cleanup child escaped run directory: $itemPath"
            }
            if (([int]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0) {
                $reparsePoints.Add($itemPath) | Out-Null
                continue
            }
            if ($item.PSIsContainer) {
                $pending.Push($itemPath)
            }
        }
    }

    foreach ($linkPath in @($reparsePoints | Sort-Object { $_.Length } -Descending)) {
        Remove-Item -LiteralPath $linkPath -Force
    }

    Remove-Item -LiteralPath $target -Recurse -Force
}

function Get-WorkersArtifactReference {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Path
    )

    return (ConvertTo-WorkersProjectRelativePath -ProjectDir $ProjectDir -FullPath $Path)
}

function Assert-WorkersRemotePath {
    param([Parameter(Mandatory = $true)][string]$RemotePath)

    if ([string]::IsNullOrWhiteSpace($RemotePath)) {
        Stop-WithError 'remote path is required'
    }
    $normalized = $RemotePath.Replace('\', '/')
    foreach ($segment in @($normalized.Split('/'))) {
        if ($segment -eq '..') {
            Stop-WithError "remote path must not contain '..': $RemotePath"
        }
    }

    return $RemotePath
}

function Assert-WorkersRunId {
    param([AllowEmptyString()][string]$RunId)

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        return ''
    }
    if ($RunId -notmatch '^[A-Za-z0-9._-]+$' -or $RunId -eq '.' -or $RunId -eq '..' -or $RunId.Contains('..')) {
        Stop-WithError "run id contains unsupported characters: $RunId"
    }

    return $RunId
}

function Get-WorkersSingleColabContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $context = Get-WorkersLifecycleContext -ProjectDir $ProjectDir
    $rows = @(Select-WorkersRows -Rows (Get-WorkersStatusRows -Context $context) -Target $Target)
    if ($rows.Count -ne 1) {
        Stop-WithError "workers command requires exactly one slot, got $($rows.Count)"
    }

    $row = $rows[0]
    Assert-WorkersPathSegment -Value ([string]$row.SlotId) -Name 'slot id' | Out-Null
    if (-not [string]::Equals([string]$row.Backend, 'colab_cli', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "worker slot $($row.SlotId) uses backend '$($row.Backend)', not colab_cli"
    }

    $reason = [string]$row.DegradedReason
    if ([string]$row.State -eq 'backend_degraded' -or -not [string]::IsNullOrWhiteSpace($reason)) {
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = 'backend_degraded'
        }
        Stop-WithError "colab worker $($row.SlotId) is unavailable: $reason"
    }

    $session = [string]$row.Session
    if ([string]::IsNullOrWhiteSpace($session)) {
        Stop-WithError "colab worker $($row.SlotId) has no session name"
    }

    $entry = if ($context.EntriesBySlot.ContainsKey($row.SlotId)) { $context.EntriesBySlot[$row.SlotId] } else { $null }
    return [PSCustomObject]@{
        Context = $context
        Row     = $row
        Entry   = $entry
        Session = $session
    }
}

function Invoke-WorkersColabCli {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if (-not (Get-Command Get-WinsmuxColabCliAvailability -ErrorAction SilentlyContinue)) {
        Stop-WithError 'Colab backend helpers are unavailable'
    }
    $cli = Get-WinsmuxColabCliAvailability
    if (-not [bool](Get-SendConfigValue -InputObject $cli -Name 'available' -Default $false)) {
        Stop-WithError 'google-colab-cli not found on PATH'
    }

    $command = [string](Get-SendConfigValue -InputObject $cli -Name 'command' -Default 'google-colab-cli')
    $output = @()
    try {
        $output = & $command @Arguments 2>&1
    } catch {
        return [PSCustomObject]@{
            Command  = $command
            Arguments = @($Arguments)
            ExitCode = 1
            Output   = $_.Exception.Message
        }
    }

    $exitCode = Get-SafeLastExitCode
    if ($null -eq $exitCode) {
        $exitCode = 0
    }

    return [PSCustomObject]@{
        Command  = $command
        Arguments = @($Arguments)
        ExitCode = [int]$exitCode
        Output   = ($output | Out-String).TrimEnd()
    }
}

function Write-WorkersOperationOutput {
    param(
        [Parameter(Mandatory = $true)]$Payload,
        [switch]$Json,
        [AllowEmptyString()][string]$Text = ''
    )

    $operationExitCode = 0
    $rawExitCode = Get-SendConfigValue -InputObject $Payload -Name 'exit_code' -Default 0
    $parsedExitCode = 0
    if ([int]::TryParse(([string]$rawExitCode), [ref]$parsedExitCode) -and $parsedExitCode -ne 0) {
        $operationExitCode = $parsedExitCode
    }

    if ($Json) {
        $Payload | ConvertTo-Json -Depth 24 -Compress | Write-Output
    } elseif ([string]::IsNullOrWhiteSpace($Text)) {
        $status = [string](Get-SendConfigValue -InputObject $Payload -Name 'status' -Default '')
        $runId = [string](Get-SendConfigValue -InputObject $Payload -Name 'run_id' -Default '')
        Write-Output "$status $runId".Trim()
    } else {
        Write-Output $Text
    }

    if ($operationExitCode -ne 0) {
        exit $operationExitCode
    }
}

function Read-WorkersExecOptions {
    param([Parameter(Mandatory = $true)][string]$Usage)

    $projectDir = (Get-Location).Path
    $asJson = $false
    $targetValue = ''
    $scriptPath = ''
    $runId = ''
    $taskId = ''
    $scriptArgs = @()
    $items = @($Rest)

    for ($index = 0; $index -lt $items.Count; $index++) {
        $token = [string]$items[$index]
        if ($token -eq '--') {
            if ($index + 1 -lt $items.Count) {
                $scriptArgs = @($items | Select-Object -Skip ($index + 1))
            }
            break
        }

        switch ($token) {
            '--json' { $asJson = $true }
            '--project-dir' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $projectDir = [string]$items[$index + 1]
                $index++
            }
            '--script' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $scriptPath = [string]$items[$index + 1]
                $index++
            }
            '--run-id' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $runId = [string]$items[$index + 1]
                $index++
            }
            '--task-id' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $taskId = [string]$items[$index + 1]
                $index++
            }
            default {
                if (-not [string]::IsNullOrWhiteSpace($targetValue)) {
                    Stop-WithError $Usage
                }
                $targetValue = $token
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($targetValue) -or [string]::IsNullOrWhiteSpace($scriptPath)) {
        Stop-WithError $Usage
    }

    return [PSCustomObject]@{
        ProjectDir = $projectDir
        Json       = $asJson
        Target     = $targetValue
        ScriptPath = $scriptPath
        RunId      = $runId
        TaskId     = $taskId
        ScriptArgs = @($scriptArgs)
    }
}

function Read-WorkersTransferOptions {
    param(
        [Parameter(Mandatory = $true)][string]$Usage,
        [Parameter(Mandatory = $true)][string]$Mode
    )

    $projectDir = (Get-Location).Path
    $asJson = $false
    $targetValue = ''
    $sourceValue = ''
    $remoteValue = ''
    $outputValue = ''
    $runId = ''
    $allowDirs = [System.Collections.Generic.List[string]]::new()
    $maxBytes = Get-WorkersUploadMaxBytes
    $items = @($Rest)

    for ($index = 0; $index -lt $items.Count; $index++) {
        $token = [string]$items[$index]
        switch ($token) {
            '--json' { $asJson = $true }
            '--project-dir' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $projectDir = [string]$items[$index + 1]
                $index++
            }
            '--remote' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $remoteValue = [string]$items[$index + 1]
                $index++
            }
            '--output' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $outputValue = [string]$items[$index + 1]
                $index++
            }
            '--allow-dir' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $allowDirs.Add([string]$items[$index + 1]) | Out-Null
                $index++
            }
            '--run-id' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $runId = [string]$items[$index + 1]
                $index++
            }
            '--max-bytes' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $parsed = 0L
                if (-not [long]::TryParse([string]$items[$index + 1], [ref]$parsed) -or $parsed -lt 1) {
                    Stop-WithError $Usage
                }
                $maxBytes = $parsed
                $index++
            }
            default {
                if ([string]::IsNullOrWhiteSpace($targetValue)) {
                    $targetValue = $token
                } elseif ([string]::IsNullOrWhiteSpace($sourceValue)) {
                    $sourceValue = $token
                } else {
                    Stop-WithError $Usage
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($targetValue) -or [string]::IsNullOrWhiteSpace($sourceValue)) {
        Stop-WithError $Usage
    }

    if ($Mode -eq 'upload' -and [string]::IsNullOrWhiteSpace($remoteValue)) {
        $remoteValue = "/content/winsmux/$((Split-Path -Leaf $sourceValue))"
    }
    if ($Mode -eq 'download') {
        $remoteValue = $sourceValue
        $sourceValue = ''
    }

    return [PSCustomObject]@{
        ProjectDir = $projectDir
        Json       = $asJson
        Target     = $targetValue
        Source     = $sourceValue
        Remote     = $remoteValue
        Output     = $outputValue
        RunId      = $runId
        AllowDirs  = @($allowDirs)
        MaxBytes   = $maxBytes
    }
}

function Read-WorkersLogsOptions {
    param([Parameter(Mandatory = $true)][string]$Usage)

    $projectDir = (Get-Location).Path
    $asJson = $false
    $targetValue = ''
    $runId = ''
    $items = @($Rest)

    for ($index = 0; $index -lt $items.Count; $index++) {
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
            default {
                if (-not [string]::IsNullOrWhiteSpace($targetValue)) {
                    Stop-WithError $Usage
                }
                $targetValue = $token
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($targetValue)) {
        Stop-WithError $Usage
    }

    return [PSCustomObject]@{
        ProjectDir = $projectDir
        Json       = $asJson
        Target     = $targetValue
        RunId      = $runId
    }
}

function Read-WorkersWorkspaceOptions {
    param([Parameter(Mandatory = $true)][string]$Usage)

    $projectDir = (Get-Location).Path
    $asJson = $false
    $workspaceAction = ''
    $targetValue = ''
    $runId = ''
    $profile = 'isolated-enterprise'
    $includes = [System.Collections.Generic.List[string]]::new()
    $items = @($Rest)

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

function Read-WorkersSecretMapSpec {
    param(
        [Parameter(Mandatory = $true)][string]$Spec,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    $separator = $Spec.IndexOf('=')
    if ($separator -le 0 -or $separator -ge ($Spec.Length - 1)) {
        Stop-WithError "secret $Kind projection must use target=vault-key"
    }

    return [PSCustomObject]@{
        Target   = $Spec.Substring(0, $separator)
        VaultKey = $Spec.Substring($separator + 1)
    }
}

function Read-WorkersSecretsOptions {
    param([Parameter(Mandatory = $true)][string]$Usage)

    $projectDir = (Get-Location).Path
    $asJson = $false
    $action = ''
    $targetValue = ''
    $runId = ''
    $profile = ''
    $envSpecs = [System.Collections.Generic.List[object]]::new()
    $fileSpecs = [System.Collections.Generic.List[object]]::new()
    $variableSpecs = [System.Collections.Generic.List[object]]::new()
    $items = @($Rest)

    if ($items.Count -ge 1) {
        $action = [string]$items[0]
    }
    if ($items.Count -ge 2) {
        $targetValue = [string]$items[1]
    }
    if ([string]::IsNullOrWhiteSpace($action) -or [string]::IsNullOrWhiteSpace($targetValue)) {
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
            '--env' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $envSpecs.Add((Read-WorkersSecretMapSpec -Spec ([string]$items[$index + 1]) -Kind 'env')) | Out-Null
                $index++
            }
            '--file' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $fileSpecs.Add((Read-WorkersSecretMapSpec -Spec ([string]$items[$index + 1]) -Kind 'file')) | Out-Null
                $index++
            }
            '--variable' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $variableSpecs.Add((Read-WorkersSecretMapSpec -Spec ([string]$items[$index + 1]) -Kind 'variable')) | Out-Null
                $index++
            }
            default {
                Stop-WithError $Usage
            }
        }
    }

    if ($action -ne 'project') {
        Stop-WithError $Usage
    }
    if ([string]::IsNullOrWhiteSpace($runId)) {
        Stop-WithError 'secret projection requires --run-id'
    }
    if (($envSpecs.Count + $fileSpecs.Count + $variableSpecs.Count) -lt 1) {
        Stop-WithError 'secret projection requires at least one --env, --file, or --variable mapping'
    }

    return [PSCustomObject]@{
        ProjectDir = $projectDir
        Json       = $asJson
        Action     = $action
        Target     = $targetValue
        RunId      = $runId
        Profile    = $profile
        Env        = @($envSpecs)
        File       = @($fileSpecs)
        Variable   = @($variableSpecs)
    }
}

function Read-WorkersHeartbeatOptions {
    param([Parameter(Mandatory = $true)][string]$Usage)

    $projectDir = (Get-Location).Path
    $asJson = $false
    $action = ''
    $targetValue = ''
    $runId = ''
    $profile = ''
    $state = 'running'
    $message = ''
    $stalledAfter = 0
    $offlineAfter = 0
    $items = @($Rest)

    if ($items.Count -ge 1) {
        $action = ([string]$items[0]).Trim().ToLowerInvariant()
    }
    if ($items.Count -ge 2) {
        $targetValue = [string]$items[1]
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
            '--state' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $state = [string]$items[$index + 1]
                $index++
            }
            '--message' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $message = [string]$items[$index + 1]
                $index++
            }
            '--stalled-after' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                if (-not [int]::TryParse([string]$items[$index + 1], [ref]$stalledAfter) -or $stalledAfter -lt 1) {
                    Stop-WithError $Usage
                }
                $index++
            }
            '--offline-after' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                if (-not [int]::TryParse([string]$items[$index + 1], [ref]$offlineAfter) -or $offlineAfter -lt 1) {
                    Stop-WithError $Usage
                }
                $index++
            }
            default {
                Stop-WithError $Usage
            }
        }
    }

    if ($action -notin @('mark', 'check') -or [string]::IsNullOrWhiteSpace($targetValue)) {
        Stop-WithError $Usage
    }
    if ($action -eq 'mark' -and [string]::IsNullOrWhiteSpace($runId)) {
        Stop-WithError $Usage
    }

    return [PSCustomObject]@{
        ProjectDir           = $projectDir
        Json                 = $asJson
        Action               = $action
        Target               = $targetValue
        RunId                = $runId
        Profile              = $profile
        State                = $state
        Message              = $message
        StalledAfterSeconds  = $stalledAfter
        OfflineAfterSeconds  = $offlineAfter
    }
}

function Read-WorkersSandboxOptions {
    param([Parameter(Mandatory = $true)][string]$Usage)

    $projectDir = (Get-Location).Path
    $asJson = $false
    $action = ''
    $targetValue = ''
    $runId = ''
    $profile = 'isolated-enterprise'
    $items = @($Rest)

    if ($items.Count -ge 1) {
        $action = ([string]$items[0]).Trim().ToLowerInvariant()
    }
    if ($items.Count -ge 2) {
        $targetValue = [string]$items[1]
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
            default {
                Stop-WithError $Usage
            }
        }
    }

    if ($action -ne 'baseline' -or [string]::IsNullOrWhiteSpace($targetValue) -or [string]::IsNullOrWhiteSpace($runId)) {
        Stop-WithError $Usage
    }

    return [PSCustomObject]@{
        ProjectDir = $projectDir
        Json       = $asJson
        Action     = $action
        Target     = $targetValue
        RunId      = $runId
        Profile    = $profile
    }
}

function Read-WorkersBrokerOptions {
    param([Parameter(Mandatory = $true)][string]$Usage)

    $projectDir = (Get-Location).Path
    $asJson = $false
    $action = ''
    $tokenAction = ''
    $targetValue = ''
    $runId = ''
    $profile = 'isolated-enterprise'
    $endpoint = ''
    $nodeId = ''
    $ttlSeconds = 900
    $refresh = $true
    $items = @($Rest)

    if ($items.Count -ge 1) {
        $action = ([string]$items[0]).Trim().ToLowerInvariant()
    }
    $optionStartIndex = 2
    if ($action -eq 'token') {
        if ($items.Count -ge 2) {
            $tokenAction = ([string]$items[1]).Trim().ToLowerInvariant()
        }
        if ($items.Count -ge 3) {
            $targetValue = [string]$items[2]
        }
        $optionStartIndex = 3
    } elseif ($items.Count -ge 2) {
        $targetValue = [string]$items[1]
    }

    for ($index = $optionStartIndex; $index -lt $items.Count; $index++) {
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
            '--endpoint' {
                if ($action -ne 'baseline') { Stop-WithError $Usage }
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $endpoint = [string]$items[$index + 1]
                $index++
            }
            '--node-id' {
                if ($action -ne 'baseline') { Stop-WithError $Usage }
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $nodeId = [string]$items[$index + 1]
                $index++
            }
            '--ttl-seconds' {
                if ($action -ne 'token') { Stop-WithError $Usage }
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                if (-not [int]::TryParse([string]$items[$index + 1], [ref]$ttlSeconds) -or $ttlSeconds -lt 1) {
                    Stop-WithError 'broker token --ttl-seconds must be a positive integer'
                }
                $index++
            }
            '--no-refresh' {
                if ($action -ne 'token') { Stop-WithError $Usage }
                $refresh = $false
            }
            default {
                Stop-WithError $Usage
            }
        }
    }

    if ($action -eq 'baseline' -and [string]::IsNullOrWhiteSpace($nodeId)) {
        $nodeId = 'broker-1'
    }

    if ($action -eq 'baseline' -and ([string]::IsNullOrWhiteSpace($targetValue) -or [string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($endpoint))) {
        Stop-WithError $Usage
    }
    if ($action -eq 'token' -and ($tokenAction -notin @('issue', 'check') -or [string]::IsNullOrWhiteSpace($targetValue) -or [string]::IsNullOrWhiteSpace($runId))) {
        Stop-WithError $Usage
    }
    if ($action -notin @('baseline', 'token')) {
        Stop-WithError $Usage
    }

    return [PSCustomObject]@{
        ProjectDir  = $projectDir
        Json        = $asJson
        Action      = $action
        TokenAction = $tokenAction
        Target      = $targetValue
        RunId       = $runId
        Profile     = $profile
        Endpoint    = $endpoint
        NodeId      = $nodeId
        TtlSeconds  = $ttlSeconds
        Refresh     = $refresh
    }
}

function Assert-WorkersPolicyChoice {
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Default
    )

    $choice = $Value
    if ([string]::IsNullOrWhiteSpace($choice)) {
        $choice = $Default
    }
    $choice = $choice.Trim().ToLowerInvariant()
    if ($Allowed -notcontains $choice) {
        Stop-WithError "enterprise execution policy --$Name must be one of: $($Allowed -join ', ')"
    }

    return $choice
}

function Assert-WorkersPolicyName {
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text) -or $text -notmatch '^[A-Za-z0-9_.-]+$') {
        Stop-WithError "enterprise execution policy $Name must use letters, numbers, dot, underscore, or dash"
    }

    return $text
}

function Add-WorkersPolicyEvidenceRequirement {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Evidence,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Evidence.Contains($Role)) {
        $Evidence[$Role] = @()
    }

    $values = @($Evidence[$Role])
    if ($values -notcontains $Name) {
        $Evidence[$Role] = @($values + $Name)
    }
}

function Get-WorkersPolicyEvidenceRequirements {
    param([AllowNull()][string[]]$Specs)

    $evidence = [ordered]@{
        builder  = @('implementation_diff', 'focused_tests', 'public_surface_audit')
        reviewer = @('codex_review', 'ci_checks')
        operator = @('release_checklist', 'release_notes')
    }

    foreach ($spec in @($Specs)) {
        $text = ([string]$spec).Trim()
        $match = [regex]::Match($text, '^([^:]+):(.+)$')
        if ([string]::IsNullOrWhiteSpace($text) -or -not $match.Success) {
            Stop-WithError 'enterprise execution policy --require-evidence must use <role:name>'
        }
        $role = (Assert-WorkersPolicyName -Value $match.Groups[1].Value -Name 'evidence role').ToLowerInvariant()
        if ($role -notin @('builder', 'reviewer', 'operator')) {
            Stop-WithError 'enterprise execution policy --require-evidence role must be builder, reviewer, or operator'
        }
        $name = Assert-WorkersPolicyName -Value $match.Groups[2].Value -Name 'evidence name'
        Add-WorkersPolicyEvidenceRequirement -Evidence $evidence -Role $role -Name $name
    }

    return $evidence
}

function Read-WorkersPolicyOptions {
    param([Parameter(Mandatory = $true)][string]$Usage)

    $projectDir = (Get-Location).Path
    $asJson = $false
    $action = ''
    $targetValue = ''
    $runId = ''
    $profile = 'isolated-enterprise'
    $network = 'broker-only'
    $write = 'workspace-artifacts'
    $provider = 'configured'
    $requiredChecks = [System.Collections.Generic.List[string]]::new()
    $requiredEvidence = [System.Collections.Generic.List[string]]::new()
    $items = @($Rest)

    if ($items.Count -ge 1) {
        $action = ([string]$items[0]).Trim().ToLowerInvariant()
    }
    if ($items.Count -ge 2) {
        $targetValue = [string]$items[1]
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
            '--network' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $network = [string]$items[$index + 1]
                $index++
            }
            '--write' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $write = [string]$items[$index + 1]
                $index++
            }
            '--provider' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $provider = [string]$items[$index + 1]
                $index++
            }
            '--require-check' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $requiredChecks.Add((Assert-WorkersPolicyName -Value ([string]$items[$index + 1]) -Name 'check name')) | Out-Null
                $index++
            }
            '--require-evidence' {
                if ($index + 1 -ge $items.Count) { Stop-WithError $Usage }
                $requiredEvidence.Add([string]$items[$index + 1]) | Out-Null
                $index++
            }
            default {
                Stop-WithError $Usage
            }
        }
    }

    if ($action -ne 'baseline' -or [string]::IsNullOrWhiteSpace($targetValue) -or [string]::IsNullOrWhiteSpace($runId)) {
        Stop-WithError $Usage
    }

    $network = Assert-WorkersPolicyChoice -Value $network -Name 'network' -Allowed @('blocked', 'broker-only', 'allowed') -Default 'broker-only'
    $write = Assert-WorkersPolicyChoice -Value $write -Name 'write' -Allowed @('read-only', 'workspace-artifacts', 'workspace-only') -Default 'workspace-artifacts'
    $provider = Assert-WorkersPolicyChoice -Value $provider -Name 'provider' -Allowed @('blocked', 'configured', 'allowed') -Default 'configured'
    $checks = @('broker_baseline', 'broker_token_valid', 'public_surface_audit', 'git_guard', 'focused_tests')
    foreach ($check in @($requiredChecks)) {
        if ($checks -notcontains $check) {
            $checks += $check
        }
    }

    return [PSCustomObject]@{
        ProjectDir        = $projectDir
        Json              = $asJson
        Action            = $action
        Target            = $targetValue
        RunId             = $runId
        Profile           = $profile
        Network           = $network
        Write             = $write
        Provider          = $provider
        RequiredChecks    = @($checks)
        RequiredEvidence  = Get-WorkersPolicyEvidenceRequirements -Specs @($requiredEvidence)
    }
}

function Get-WorkersSingleSlotContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $context = Get-WorkersLifecycleContext -ProjectDir $ProjectDir
    $rows = @(Select-WorkersRows -Rows (Get-WorkersStatusRows -Context $context) -Target $Target)
    if ($rows.Count -ne 1) {
        Stop-WithError "workers command requires exactly one slot, got $($rows.Count)"
    }

    $row = $rows[0]
    Assert-WorkersPathSegment -Value ([string]$row.SlotId) -Name 'slot id' | Out-Null
    $slotConfig = Get-SlotAgentConfig -Role 'Worker' -SlotId ([string]$row.SlotId) -Settings $context.Settings -RootPath $ProjectDir
    $entry = if ($context.EntriesBySlot.ContainsKey($row.SlotId)) { $context.EntriesBySlot[$row.SlotId] } else { $null }

    return [PSCustomObject]@{
        Context    = $context
        Row        = $row
        Entry      = $entry
        SlotConfig = $slotConfig
    }
}

function Invoke-WorkersWorkspacePrepare {
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
        Set-WorkersManifestLifecycleCommand -Entry $slot.Entry -CommandName 'workers.workspace.prepare'
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$Options.Json) -Text "prepared $runId"
}

function Invoke-WorkersWorkspaceCleanup {
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
        Set-WorkersManifestLifecycleCommand -Entry $slot.Entry -CommandName 'workers.workspace.cleanup'
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$Options.Json) -Text "$($payload['status']) $runId"
}

function Invoke-WorkersWorkspace {
    $usage = "usage: winsmux workers workspace <prepare|cleanup> <slot> [--include <path>] [--run-id <id>] [--profile isolated-enterprise] [--json] [--project-dir <path>]"
    $options = Read-WorkersWorkspaceOptions -Usage $usage
    switch ([string]$options.Action) {
        'prepare' { Invoke-WorkersWorkspacePrepare -Options $options }
        'cleanup' { Invoke-WorkersWorkspaceCleanup -Options $options }
        default { Stop-WithError $usage }
    }
}

function Invoke-WorkersSecretsProject {
    param([Parameter(Mandatory = $true)]$Options)

    $slot = Get-WorkersSingleSlotContext -ProjectDir $Options.ProjectDir -Target $Options.Target
    $slotProfile = [string]$slot.SlotConfig.ExecutionProfile
    if ([string]::IsNullOrWhiteSpace($slotProfile)) {
        $slotProfile = 'local-windows'
    }
    $requestedProfile = [string]$Options.Profile
    if ([string]::IsNullOrWhiteSpace($requestedProfile)) {
        $requestedProfile = $slotProfile
    }
    if (Get-Command Test-BridgeExecutionProfileKind -ErrorAction SilentlyContinue) {
        if (-not (Test-BridgeExecutionProfileKind -Value $requestedProfile)) {
            Stop-WithError "unsupported execution profile for secret projection: $requestedProfile"
        }
    }
    if (-not [string]::Equals($slotProfile, $requestedProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "worker slot $($slot.Row.SlotId) uses execution profile '$slotProfile', not $requestedProfile"
    }

    $runId = Assert-WorkersRunId -RunId ([string]$Options.RunId)
    $runDir = Get-WorkersSecretRunDirectory -ProjectDir $Options.ProjectDir -SlotId ([string]$slot.Row.SlotId) -RunId $runId -ExecutionProfile $requestedProfile
    $secretRoot = [System.IO.Path]::GetFullPath((Join-Path $runDir 'secrets'))
    $envFile = Join-Path $secretRoot 'env.ps1'
    $fileRoot = Join-Path $secretRoot 'files'
    $variableFile = Join-Path $secretRoot 'variables.json'
    $manifestPath = Join-Path $secretRoot 'secret-projection.json'
    $envEntries = [System.Collections.Generic.List[object]]::new()
    $fileEntries = [System.Collections.Generic.List[object]]::new()
    $variableEntries = [System.Collections.Generic.List[object]]::new()

    foreach ($spec in @($Options.Env)) {
        $name = Assert-WorkersSecretName -Name ([string]$spec.Target) -Kind 'secret env target'
        $vaultKey = Assert-WorkersSecretVaultKey -Key ([string]$spec.VaultKey)
        $value = Resolve-WorkersVaultSecretValue -Key $vaultKey
        $envEntries.Add([PSCustomObject]@{ Name = $name; VaultKey = $vaultKey; Value = $value }) | Out-Null
    }

    foreach ($spec in @($Options.File)) {
        $targetInfo = Resolve-WorkersSecretFileTarget -RelativePath ([string]$spec.Target) -SecretRoot $fileRoot
        $vaultKey = Assert-WorkersSecretVaultKey -Key ([string]$spec.VaultKey)
        $value = Resolve-WorkersVaultSecretValue -Key $vaultKey
        $fileEntries.Add([PSCustomObject]@{ TargetInfo = $targetInfo; VaultKey = $vaultKey; Value = $value }) | Out-Null
    }

    foreach ($spec in @($Options.Variable)) {
        $name = Assert-WorkersSecretName -Name ([string]$spec.Target) -Kind 'secret variable target'
        $vaultKey = Assert-WorkersSecretVaultKey -Key ([string]$spec.VaultKey)
        $value = Resolve-WorkersVaultSecretValue -Key $vaultKey
        $variableEntries.Add([PSCustomObject]@{ Name = $name; VaultKey = $vaultKey; Value = $value }) | Out-Null
    }

    New-Item -ItemType Directory -Path $secretRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $fileRoot -Force | Out-Null

    $projections = [System.Collections.Generic.List[object]]::new()
    $envLines = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($envEntries)) {
        $envLines.Add(('$env:' + [string]$entry.Name + ' = ' + (ConvertTo-WorkersPowerShellSingleQuotedValue -Value ([string]$entry.Value)))) | Out-Null
        $projections.Add([ordered]@{
            kind        = 'env'
            target      = [string]$entry.Name
            vault_key   = [string]$entry.VaultKey
            value_ref   = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $envFile
            value_stored = $true
        }) | Out-Null
    }
    if ($envLines.Count -gt 0) {
        Write-ClmSafeTextFile -Path $envFile -Content (($envLines -join [Environment]::NewLine) + [Environment]::NewLine)
    }

    foreach ($entry in @($fileEntries)) {
        $targetInfo = $entry.TargetInfo
        $parent = Split-Path -Parent ([string]$targetInfo.FullPath)
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Write-ClmSafeTextFile -Path ([string]$targetInfo.FullPath) -Content ([string]$entry.Value)
        $projections.Add([ordered]@{
            kind        = 'file'
            target      = [string]$targetInfo.RelativePath
            vault_key   = [string]$entry.VaultKey
            value_ref   = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path ([string]$targetInfo.FullPath)
            value_stored = $true
        }) | Out-Null
    }

    $variables = [ordered]@{}
    foreach ($entry in @($variableEntries)) {
        $variables[[string]$entry.Name] = [string]$entry.Value
        $projections.Add([ordered]@{
            kind        = 'variable'
            target      = [string]$entry.Name
            vault_key   = [string]$entry.VaultKey
            value_ref   = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $variableFile
            value_stored = $true
        }) | Out-Null
    }
    if ($variables.Count -gt 0) {
        Write-WorkersJsonArtifact -Path $variableFile -Data $variables | Out-Null
    }

    $payload = [ordered]@{
        version       = 1
        project_ref   = '.'
        generated_at  = (Get-Date).ToUniversalTime().ToString('o')
        command       = 'workers.secrets.project'
        status        = 'projected'
        slot          = [string]$slot.Row.Slot
        slot_id       = [string]$slot.Row.SlotId
        role          = [string]$slot.SlotConfig.WorkerRole
        run_id        = $runId
        execution_profile = $requestedProfile.Trim().ToLowerInvariant()
        binding       = 'late-bound-at-run-start'
        scope         = [ordered]@{
            role    = [string]$slot.SlotConfig.WorkerRole
            slot    = [string]$slot.Row.Slot
            slot_id = [string]$slot.Row.SlotId
            run_id  = $runId
        }
        locations     = [ordered]@{
            run_root = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName (Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $runDir) -Backend 'local-windows' -AccessMethod 'secret_projection_run_root' -Reference (Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $runDir) -Provenance 'workers.secrets.run_root'
            secrets  = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName (Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $secretRoot) -Backend 'local-windows' -AccessMethod 'secret_projection_root' -Reference (Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $secretRoot) -Provenance 'workers.secrets.root'
            manifest = New-WinsmuxLocationIdentity -Kind 'local_file' -DisplayName 'secret-projection.json' -Backend 'local-windows' -AccessMethod 'artifact_ref' -Reference (Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $manifestPath) -Provenance 'workers.secrets.manifest'
        }
        projections   = @($projections)
        value_policy  = [ordered]@{
            output_contains_secret_values = $false
            manifest_contains_secret_values = $false
            values_stored_as_local_secret_files = $true
        }
        exit_code     = 0
    }

    Write-WorkersJsonArtifact -Path $manifestPath -Data $payload | Out-Null
    if ($null -ne $slot.Entry) {
        Set-WorkersManifestLifecycleCommand -Entry $slot.Entry -CommandName 'workers.secrets.project'
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$Options.Json) -Text "projected $($projections.Count) secret(s) for $runId"
}

function Invoke-WorkersSecrets {
    $usage = "usage: winsmux workers secrets project <slot> --run-id <id> [--profile <profile>] [--env <name=vault-key>] [--file <path=vault-key>] [--variable <name=vault-key>] [--json] [--project-dir <path>]"
    $options = Read-WorkersSecretsOptions -Usage $usage
    switch ([string]$options.Action) {
        'project' { Invoke-WorkersSecretsProject -Options $options }
        default { Stop-WithError $usage }
    }
}

function Invoke-WorkersHeartbeat {
    $usage = "usage: winsmux workers heartbeat <mark|check> <slot> [--run-id <id>] [--profile <profile>] [--state <running|blocked|approval_waiting|child_wait|stalled|offline|completed|resumable>] [--message <text>] [--stalled-after <seconds>] [--offline-after <seconds>] [--json] [--project-dir <path>]"
    $options = Read-WorkersHeartbeatOptions -Usage $usage
    $slot = Get-WorkersSingleSlotContext -ProjectDir $options.ProjectDir -Target $options.Target
    $slotId = [string]$slot.Row.SlotId
    $runId = Assert-WorkersRunId -RunId ([string]$options.RunId)
    $profile = [string]$options.Profile
    if ([string]::IsNullOrWhiteSpace($profile)) {
        $profile = [string]$slot.SlotConfig.ExecutionProfile
    }
    if ([string]::IsNullOrWhiteSpace($profile)) {
        $profile = 'local-windows'
    }
    if (Get-Command Test-BridgeExecutionProfileKind -ErrorAction SilentlyContinue) {
        if (-not (Test-BridgeExecutionProfileKind -Value $profile)) {
            Stop-WithError "unsupported execution profile for heartbeat: $profile"
        }
    }
    $slotProfile = [string]$slot.SlotConfig.ExecutionProfile
    if ([string]::IsNullOrWhiteSpace($slotProfile)) {
        $slotProfile = 'local-windows'
    }
    $action = [string]$options.Action
    if (
        -not [string]::Equals($action, 'check', [System.StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::Equals($slotProfile, $profile, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        Stop-WithError "worker slot $slotId uses execution profile '$slotProfile', not $profile"
    }

    $stalledAfter = Get-WorkersHeartbeatThresholdSeconds -Value ([int]$options.StalledAfterSeconds) -EnvName 'WINSMUX_WORKER_HEARTBEAT_STALLED_AFTER_SECONDS' -Default 300
    $offlineAfter = Get-WorkersHeartbeatThresholdSeconds -Value ([int]$options.OfflineAfterSeconds) -EnvName 'WINSMUX_WORKER_HEARTBEAT_OFFLINE_AFTER_SECONDS' -Default 900
    if ($offlineAfter -le $stalledAfter) {
        Stop-WithError 'heartbeat --offline-after must be greater than --stalled-after'
    }
    $preferPayloadThresholds = ([int]$options.StalledAfterSeconds -lt 1 -and [int]$options.OfflineAfterSeconds -lt 1)

    $nowUtc = Get-WorkersNowUtc

    if ([string]::Equals($action, 'check', [System.StringComparison]::OrdinalIgnoreCase)) {
        $heartbeatPath = ''
        if (-not [string]::IsNullOrWhiteSpace($runId)) {
            $runDir = Get-WorkersHeartbeatRunDirectory -ProjectDir $options.ProjectDir -SlotId $slotId -RunId $runId -ExecutionProfile $profile -AllowMissing
            $heartbeatPath = Join-Path $runDir 'heartbeat.json'
        } else {
            $latest = Get-WorkersLatestHeartbeatStatus -ProjectDir $options.ProjectDir -SlotId $slotId -ExecutionProfile $profile -StalledAfterSeconds $stalledAfter -OfflineAfterSeconds $offlineAfter -PreferPayloadThresholds $preferPayloadThresholds
            if ($null -ne $latest) {
                Write-WorkersOperationOutput -Payload $latest -Json:([bool]$options.Json) -Text "$($latest.health) $($latest.run_id)"
                return
            }
        }

        $status = $null
        if (-not [string]::IsNullOrWhiteSpace($heartbeatPath)) {
            $status = Read-WorkersHeartbeatArtifact -ProjectDir $options.ProjectDir -Path $heartbeatPath -NowUtc $nowUtc -StalledAfterSeconds $stalledAfter -OfflineAfterSeconds $offlineAfter -PreferPayloadThresholds $preferPayloadThresholds
        }
        if ($null -eq $status) {
            $status = New-WorkersHeartbeatMissingStatus -Slot $slot -RunId $runId -ExecutionProfile $profile -StalledAfterSeconds $stalledAfter -OfflineAfterSeconds $offlineAfter -NowUtc $nowUtc
        }
        Write-WorkersOperationOutput -Payload $status -Json:([bool]$options.Json) -Text "$($status.health) $runId"
        return
    }

    $state = Assert-WorkersHeartbeatState -State ([string]$options.State)
    $runDir = Get-WorkersHeartbeatRunDirectory -ProjectDir $options.ProjectDir -SlotId $slotId -RunId $runId -ExecutionProfile $profile -CreateLocal
    $heartbeatPath = Join-Path $runDir 'heartbeat.json'
    $payload = [ordered]@{
        contract_version      = 1
        command               = 'workers.heartbeat'
        status                = 'marked'
        slot                  = [string]$slot.Row.Slot
        slot_id               = $slotId
        run_id                = $runId
        execution_profile     = $profile
        state                 = $state
        message               = ConvertTo-WorkersSafeLogText -Text ([string]$options.Message)
        heartbeat_at          = $nowUtc.ToString('o')
        stalled_after_seconds = $stalledAfter
        offline_after_seconds = $offlineAfter
        artifact              = Get-WorkersArtifactReference -ProjectDir $options.ProjectDir -Path $heartbeatPath
    }
    Write-WorkersJsonArtifact -Path $heartbeatPath -Data $payload | Out-Null
    $status = ConvertTo-WorkersHeartbeatStatus -Payload $payload -Artifact ([string]$payload.artifact) -NowUtc $nowUtc -StalledAfterSeconds $stalledAfter -OfflineAfterSeconds $offlineAfter
    $status['status'] = 'marked'
    if ($null -ne $slot.Entry) {
        Set-WorkersManifestLifecycleCommand -Entry $slot.Entry -CommandName 'workers.heartbeat' -ExtraProperties ([ordered]@{
            last_heartbeat_run_id  = $runId
            last_heartbeat_profile = $profile
            last_heartbeat_at      = $nowUtc.ToString('o')
        })
    }

    Write-WorkersOperationOutput -Payload $status -Json:([bool]$options.Json) -Text "marked $state heartbeat for $runId"
}

function Invoke-WorkersSandboxBaseline {
    param([Parameter(Mandatory = $true)]$Options)

    $slot = Get-WorkersSingleSlotContext -ProjectDir $Options.ProjectDir -Target $Options.Target
    $slotProfile = [string]$slot.SlotConfig.ExecutionProfile
    if ([string]::IsNullOrWhiteSpace($slotProfile)) {
        $slotProfile = 'local-windows'
    }

    $requestedProfile = [string]$Options.Profile
    if ([string]::IsNullOrWhiteSpace($requestedProfile)) {
        $requestedProfile = 'isolated-enterprise'
    }
    if (Get-Command Test-BridgeExecutionProfileKind -ErrorAction SilentlyContinue) {
        if (-not (Test-BridgeExecutionProfileKind -Value $requestedProfile)) {
            Stop-WithError "unsupported execution profile for Windows sandbox baseline: $requestedProfile"
        }
    }
    if (-not [string]::Equals($requestedProfile, 'isolated-enterprise', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError 'Windows sandbox baseline requires execution profile isolated-enterprise'
    }
    if (-not [string]::Equals($slotProfile, $requestedProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "worker slot $($slot.Row.SlotId) uses execution profile '$slotProfile', not $requestedProfile"
    }

    $runId = Assert-WorkersRunId -RunId ([string]$Options.RunId)
    if ([string]::IsNullOrWhiteSpace($runId)) {
        Stop-WithError 'Windows sandbox baseline requires --run-id'
    }

    $runDir = Get-WorkersIsolatedWorkspaceRunDirectory -ProjectDir $Options.ProjectDir -SlotId ([string]$slot.Row.SlotId) -RunId $runId
    if (-not (Test-Path -LiteralPath $runDir -PathType Container)) {
        Stop-WithError "Windows sandbox baseline requires an existing isolated workspace run: $runId"
    }
    Assert-WorkersIsolatedWorkspaceCleanupTarget -ProjectDir $Options.ProjectDir -RunDir $runDir

    $workspaceDir = Join-Path $runDir 'workspace'
    $downloadsDir = Join-Path $runDir 'downloads'
    $artifactsDir = Join-Path $runDir 'artifacts'
    foreach ($requiredDir in @($workspaceDir, $downloadsDir, $artifactsDir)) {
        if (-not (Test-Path -LiteralPath $requiredDir -PathType Container)) {
            Stop-WithError "Windows sandbox baseline requires prepared isolated workspace directories: $runId"
        }
    }

    Assert-WorkersNoReparsePointUnderDirectory -RootDir $runDir -Name 'Windows sandbox baseline'

    $manifestPath = Join-Path $runDir 'sandbox-baseline.json'
    $secretRoot = Join-Path $runDir 'secrets'
    $runReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $runDir
    $workspaceReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $workspaceDir
    $downloadsReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $downloadsDir
    $artifactsReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $artifactsDir
    $secretReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $secretRoot
    $manifestReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $manifestPath

    $payload = [ordered]@{
        version       = 1
        project_ref   = '.'
        generated_at  = (Get-Date).ToUniversalTime().ToString('o')
        command       = 'workers.sandbox.baseline'
        status        = 'baseline_defined'
        slot          = [string]$slot.Row.Slot
        slot_id       = [string]$slot.Row.SlotId
        role          = [string]$slot.SlotConfig.WorkerRole
        run_id        = $runId
        execution_profile = 'isolated-enterprise'
        sandbox_kind  = 'windows_native_baseline'
        public_default = $false
        boundary      = [ordered]@{
            process = [ordered]@{
                token = [ordered]@{
                    kind = 'restricted_token'
                    required = $true
                    launch_contract = 'worker_process_must_use_restricted_token'
                    current_command_launches_process = $false
                }
            }
            filesystem = [ordered]@{
                acl = [ordered]@{
                    kind = 'run_acl_boundary'
                    required = $true
                    root = $runReference
                    allowed_roots = @($workspaceReference, $downloadsReference, $artifactsReference, $secretReference)
                    denied = @('project_root_direct_write', 'parent_escape', 'reparse_point_escape')
                    verified_no_reparse_points = $true
                }
            }
            credentials = [ordered]@{
                kind = 'run_scoped_secret_projection'
                root = $secretReference
                value_output = $false
                manifest_value_output = $false
            }
            logs = [ordered]@{
                kind = 'safe_log_boundary'
                secret_values = $false
                local_paths_redacted = $true
            }
        }
        failure_policy = [ordered]@{
            fail_closed_on = @(
                'non_isolated_enterprise_profile',
                'missing_isolated_workspace_run',
                'missing_workspace_directories',
                'run_directory_reparse_point',
                'child_reparse_point',
                'path_escape'
            )
            unsafe_claims_prohibited = $true
        }
        isolation_claim = [ordered]@{
            secure = $false
            reason = 'baseline contract only; worker launch must enforce the restricted token and ACL boundary before claiming secure isolation'
        }
        locations     = [ordered]@{
            run_root  = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $runReference -Backend 'local-windows' -AccessMethod 'isolated_run_root' -Reference $runReference -Provenance 'workers.sandbox.run_root'
            workspace = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $workspaceReference -Backend 'local-windows' -AccessMethod 'isolated_workspace' -Reference $workspaceReference -Provenance 'workers.sandbox.workspace'
            downloads = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $downloadsReference -Backend 'local-windows' -AccessMethod 'isolated_downloads' -Reference $downloadsReference -Provenance 'workers.sandbox.downloads'
            artifacts = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $artifactsReference -Backend 'local-windows' -AccessMethod 'isolated_artifacts' -Reference $artifactsReference -Provenance 'workers.sandbox.artifacts'
            secrets   = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $secretReference -Backend 'local-windows' -AccessMethod 'secret_projection_root' -Reference $secretReference -Provenance 'workers.sandbox.secrets'
            manifest  = New-WinsmuxLocationIdentity -Kind 'local_file' -DisplayName 'sandbox-baseline.json' -Backend 'local-windows' -AccessMethod 'artifact_ref' -Reference $manifestReference -Provenance 'workers.sandbox.manifest'
        }
        testable_guards = @(
            'isolated_enterprise_profile_required',
            'existing_isolated_workspace_required',
            'run_boundary_no_reparse_points',
            'artifact_paths_project_relative',
            'secret_values_not_reported'
        )
        exit_code     = 0
    }

    Write-WorkersJsonArtifact -Path $manifestPath -Data $payload | Out-Null
    if ($null -ne $slot.Entry) {
        Set-WorkersManifestLifecycleCommand -Entry $slot.Entry -CommandName 'workers.sandbox.baseline' -ExtraProperties ([ordered]@{
            last_sandbox_run_id  = $runId
            last_sandbox_profile = 'isolated-enterprise'
        })
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$Options.Json) -Text "defined Windows sandbox baseline for $runId"
}

function Invoke-WorkersSandbox {
    $usage = "usage: winsmux workers sandbox baseline <slot> --run-id <id> [--profile isolated-enterprise] [--json] [--project-dir <path>]"
    $options = Read-WorkersSandboxOptions -Usage $usage
    switch ([string]$options.Action) {
        'baseline' { Invoke-WorkersSandboxBaseline -Options $options }
        default { Stop-WithError $usage }
    }
}

function Invoke-WorkersBrokerToken {
    param([Parameter(Mandatory = $true)]$Options)

    $slot = Get-WorkersSingleSlotContext -ProjectDir $Options.ProjectDir -Target $Options.Target
    $slotProfile = [string]$slot.SlotConfig.ExecutionProfile
    if ([string]::IsNullOrWhiteSpace($slotProfile)) {
        $slotProfile = 'local-windows'
    }
    $requestedProfile = [string]$Options.Profile
    if ([string]::IsNullOrWhiteSpace($requestedProfile)) {
        $requestedProfile = 'isolated-enterprise'
    }
    if (Get-Command Test-BridgeExecutionProfileKind -ErrorAction SilentlyContinue) {
        if (-not (Test-BridgeExecutionProfileKind -Value $requestedProfile)) {
            Stop-WithError "unsupported execution profile for broker token: $requestedProfile"
        }
    }
    if (-not [string]::Equals($requestedProfile, 'isolated-enterprise', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError 'broker token requires execution profile isolated-enterprise'
    }
    if (-not [string]::Equals($slotProfile, $requestedProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "worker slot $($slot.Row.SlotId) uses execution profile '$slotProfile', not $requestedProfile"
    }

    $runId = Assert-WorkersRunId -RunId ([string]$Options.RunId)
    if ([string]::IsNullOrWhiteSpace($runId)) {
        Stop-WithError 'broker token requires --run-id'
    }

    $runDir = Get-WorkersIsolatedWorkspaceRunDirectory -ProjectDir $Options.ProjectDir -SlotId ([string]$slot.Row.SlotId) -RunId $runId
    if (-not (Test-Path -LiteralPath $runDir -PathType Container)) {
        Stop-WithError "broker token requires an existing isolated workspace run: $runId"
    }
    Assert-WorkersIsolatedWorkspaceCleanupTarget -ProjectDir $Options.ProjectDir -RunDir $runDir
    Assert-WorkersNoReparsePointUnderDirectory -RootDir $runDir -Name 'broker token'

    $baselinePath = Join-Path $runDir 'broker-baseline.json'
    if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
        Stop-WithError "broker token requires an existing broker baseline: $runId"
    }

    $baseline = $null
    try {
        $baseline = Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Stop-WithError "broker token requires a readable broker baseline: $runId"
    }

    $baselineNode = Get-SendConfigValue -InputObject $baseline -Name 'node' -Default $null
    $baselineNodeId = [string](Get-SendConfigValue -InputObject $baselineNode -Name 'node_id' -Default 'broker-1')
    $baselineEndpoint = [string](Get-SendConfigValue -InputObject $baselineNode -Name 'endpoint' -Default '')
    if ([string]::IsNullOrWhiteSpace($baselineEndpoint)) {
        Stop-WithError "broker token requires a readable broker baseline: $runId"
    }

    $nodeId = [string]$Options.NodeId
    if ([string]::IsNullOrWhiteSpace($nodeId)) {
        $nodeId = $baselineNodeId
    }
    $nodeId = Assert-WorkersPathSegment -Value $nodeId -Name 'broker node id'

    $ttlSeconds = [int]$Options.TtlSeconds
    if ($ttlSeconds -lt 1) {
        Stop-WithError 'broker token --ttl-seconds must be a positive integer'
    }

    $nowUtc = Get-WorkersNowUtc
    $secretRoot = Join-Path $runDir 'secrets'
    $tokenPath = Join-Path $secretRoot 'broker-run-token.txt'
    $manifestPath = Join-Path $runDir 'broker-token.json'
    $heartbeatPath = Join-Path $runDir 'heartbeat.json'
    $tokenReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $tokenPath
    $baselineReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $baselinePath
    $manifestReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $manifestPath
    $heartbeatReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $heartbeatPath
    $existing = Read-WorkersBrokerTokenManifest -Path $manifestPath
    $existingToken = Get-SendConfigValue -InputObject $existing -Name 'run_token' -Default $null
    $existingExpiresAtText = [string](Get-SendConfigValue -InputObject $existingToken -Name 'expires_at' -Default '')
    $existingExpiresAt = ConvertTo-WorkersUtcDateTime -Value $existingExpiresAtText
    $existingIsValid = ($null -ne $existingExpiresAt -and $existingExpiresAt -gt $nowUtc)
    $existingTokenIsUsable = $false
    $existingTokenFailureReason = ''
    if ($existingIsValid) {
        $existingValueRef = [string](Get-SendConfigValue -InputObject $existingToken -Name 'value_ref' -Default '')
        $existingFingerprint = [string](Get-SendConfigValue -InputObject $existingToken -Name 'fingerprint' -Default '')
        $existingBaseline = Get-SendConfigValue -InputObject $existing -Name 'broker_baseline' -Default $null
        $existingBaselineNodeId = [string](Get-SendConfigValue -InputObject $existingBaseline -Name 'node_id' -Default '')
        $existingBaselineEndpoint = [string](Get-SendConfigValue -InputObject $existingBaseline -Name 'endpoint' -Default '')
        if ([string]::IsNullOrWhiteSpace($existingBaselineNodeId) -or -not [string]::Equals($existingBaselineNodeId, $nodeId, [System.StringComparison]::Ordinal)) {
            $existingTokenFailureReason = 'broker_baseline_mismatch'
        } elseif ([string]::IsNullOrWhiteSpace($existingBaselineEndpoint) -or -not [string]::Equals($existingBaselineEndpoint, $baselineEndpoint, [System.StringComparison]::Ordinal)) {
            $existingTokenFailureReason = 'broker_baseline_mismatch'
        } elseif ([string]::IsNullOrWhiteSpace($existingValueRef)) {
            $existingTokenFailureReason = 'token_value_ref_missing'
        } elseif (-not [string]::Equals($existingValueRef, $tokenReference, [System.StringComparison]::Ordinal)) {
            $existingTokenFailureReason = 'token_value_ref_mismatch'
        } elseif ([string]::IsNullOrWhiteSpace($existingFingerprint)) {
            $existingTokenFailureReason = 'token_fingerprint_missing'
        } elseif (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
            $existingTokenFailureReason = 'token_secret_missing'
        } else {
            try {
                $existingTokenValue = (Get-Content -LiteralPath $tokenPath -Raw -Encoding UTF8).Trim()
                if ([string]::IsNullOrWhiteSpace($existingTokenValue)) {
                    $existingTokenFailureReason = 'token_secret_empty'
                } elseif (-not [string]::Equals((Get-WorkersBrokerRunTokenFingerprint -Value $existingTokenValue), $existingFingerprint, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $existingTokenFailureReason = 'token_fingerprint_mismatch'
                } else {
                    $existingTokenIsUsable = $true
                }
            } catch {
                $existingTokenFailureReason = 'token_secret_unreadable'
            }
        }
    }
    $existingRunToken = $null
    if ($null -ne $existingToken) {
        $existingRunToken = [ordered]@{
            kind              = [string](Get-SendConfigValue -InputObject $existingToken -Name 'kind' -Default 'short_lived_broker_run_token')
            fingerprint       = [string](Get-SendConfigValue -InputObject $existingToken -Name 'fingerprint' -Default '')
            issued_at         = [string](Get-SendConfigValue -InputObject $existingToken -Name 'issued_at' -Default '')
            expires_at        = [string](Get-SendConfigValue -InputObject $existingToken -Name 'expires_at' -Default '')
            ttl_seconds       = [int](Get-SendConfigValue -InputObject $existingToken -Name 'ttl_seconds' -Default $ttlSeconds)
            value_ref         = [string](Get-SendConfigValue -InputObject $existingToken -Name 'value_ref' -Default $tokenReference)
            value_output      = $false
            value_in_manifest = $false
        }
    }
    $tokenAction = [string]$Options.TokenAction
    $refreshAllowed = [bool]$Options.Refresh

    $status = ''
    $health = ''
    $reason = ''
    $credentialRefresh = [ordered]@{
        attempted      = $false
        refreshed      = $false
        mode           = 'rotate_run_token'
        failure_reason = ''
    }
    $runToken = $null
    $offlineHeartbeat = $null
    $lifecycleHeartbeat = $null
    $shouldWriteToken = $false

    if ($tokenAction -eq 'issue') {
        $status = 'issued'
        $health = 'valid'
        $reason = 'token_issued'
        $shouldWriteToken = $true
    } elseif ($null -eq $existing) {
        $status = 'offline'
        $health = 'offline'
        $reason = 'broker_token_missing'
        $credentialRefresh.failure_reason = 'missing_token_manifest'
    } elseif ($null -eq $existingToken) {
        $status = 'offline'
        $health = 'offline'
        $reason = 'broker_token_missing'
        $credentialRefresh.failure_reason = 'missing_run_token'
    } elseif ($existingIsValid -and $existingTokenIsUsable) {
        $status = 'valid'
        $health = 'valid'
        $reason = 'token_valid'
        $runToken = $existingRunToken
    } elseif ($existingIsValid -and -not $refreshAllowed) {
        $status = 'offline'
        $health = 'offline'
        $reason = 'token_secret_invalid_refresh_disabled'
        $credentialRefresh.failure_reason = $existingTokenFailureReason
        $runToken = $existingRunToken
    } elseif ($refreshAllowed) {
        $status = 'refreshed'
        $health = 'valid'
        $reason = if ($existingIsValid) { 'token_secret_invalid_refreshed' } else { 'token_expired_refreshed' }
        $credentialRefresh.attempted = $true
        $credentialRefresh.refreshed = $true
        $shouldWriteToken = $true
    } else {
        $status = 'offline'
        $health = 'offline'
        $reason = 'token_expired_refresh_disabled'
        $credentialRefresh.failure_reason = 'refresh_disabled'
        $runToken = $existingRunToken
    }

    if ($shouldWriteToken) {
        try {
            if (-not (Test-Path -LiteralPath $secretRoot -PathType Container)) {
                New-Item -ItemType Directory -Path $secretRoot -Force | Out-Null
            }
            $tokenValue = New-WorkersBrokerRunTokenValue
            Write-ClmSafeTextFile -Path $tokenPath -Content ($tokenValue + [Environment]::NewLine)
            $expiresAt = $nowUtc.AddSeconds($ttlSeconds)
            $runToken = [ordered]@{
                kind              = 'short_lived_broker_run_token'
                fingerprint       = Get-WorkersBrokerRunTokenFingerprint -Value $tokenValue
                issued_at         = $nowUtc.ToString('o')
                expires_at        = $expiresAt.ToString('o')
                ttl_seconds       = $ttlSeconds
                value_ref         = $tokenReference
                value_output      = $false
                value_in_manifest = $false
            }
        } catch {
            $status = 'offline'
            $health = 'offline'
            $reason = 'token_refresh_failed'
            $credentialRefresh.attempted = $true
            $credentialRefresh.refreshed = $false
            $credentialRefresh.failure_reason = ConvertTo-WorkersSafeLogText -Text $_.Exception.Message
            $runToken = $existingRunToken
        }
    }

    if ($health -eq 'offline') {
        $offlineHeartbeat = Write-WorkersBrokerTokenHeartbeat -Slot $slot -ProjectDir $Options.ProjectDir -RunDir $runDir -RunId $runId -NowUtc $nowUtc -State 'offline' -Message $reason
        $lifecycleHeartbeat = $offlineHeartbeat
    } elseif ($status -in @('issued', 'refreshed')) {
        $lifecycleHeartbeat = Write-WorkersBrokerTokenHeartbeat -Slot $slot -ProjectDir $Options.ProjectDir -RunDir $runDir -RunId $runId -NowUtc $nowUtc -State 'resumable' -Message $reason
    }

    $payload = [ordered]@{
        version       = 1
        project_ref   = '.'
        generated_at  = $nowUtc.ToString('o')
        command       = 'workers.broker.token'
        action        = $tokenAction
        status        = $status
        health        = $health
        reason        = $reason
        slot          = [string]$slot.Row.Slot
        slot_id       = [string]$slot.Row.SlotId
        role          = [string]$slot.SlotConfig.WorkerRole
        run_id        = $runId
        execution_profile = 'isolated-enterprise'
        node          = [ordered]@{
            node_id = $nodeId
        }
        broker_baseline = [ordered]@{
            manifest = $baselineReference
            node_id  = $nodeId
            endpoint = $baselineEndpoint
        }
        run_token     = $runToken
        credential_refresh = $credentialRefresh
        value_policy  = [ordered]@{
            output_contains_token_value   = $false
            manifest_contains_token_value = $false
            token_value_stored_as_secret_file = $true
        }
        failure_policy = [ordered]@{
            expired_token_without_refresh_becomes_offline = $true
            missing_token_becomes_offline = $true
        }
        locations     = [ordered]@{
            token     = New-WinsmuxLocationIdentity -Kind 'local_file' -DisplayName 'broker-run-token.txt' -Backend 'local-windows' -AccessMethod 'secret_value_ref' -Reference $tokenReference -Provenance 'workers.broker.token'
            manifest  = New-WinsmuxLocationIdentity -Kind 'local_file' -DisplayName 'broker-token.json' -Backend 'local-windows' -AccessMethod 'artifact_ref' -Reference $manifestReference -Provenance 'workers.broker.token.manifest'
            heartbeat = New-WinsmuxLocationIdentity -Kind 'local_file' -DisplayName 'heartbeat.json' -Backend 'local-windows' -AccessMethod 'heartbeat_artifact' -Reference $heartbeatReference -Provenance 'workers.broker.token.heartbeat'
        }
        offline_heartbeat = $offlineHeartbeat
        exit_code     = 0
    }

    Write-WorkersJsonArtifact -Path $manifestPath -Data $payload | Out-Null
    if ($null -ne $slot.Entry) {
        $extraProperties = [ordered]@{
            last_broker_run_id           = $runId
            last_broker_profile          = 'isolated-enterprise'
            last_broker_node_id          = $nodeId
            last_broker_status           = [string](Get-SendConfigValue -InputObject $baseline -Name 'status' -Default 'broker_defined')
            last_broker_manifest         = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $baselinePath
            last_broker_token_status     = $status
            last_broker_token_health     = $health
            last_broker_token_expires_at = [string](Get-SendConfigValue -InputObject $runToken -Name 'expires_at' -Default '')
            last_broker_token_manifest   = $manifestReference
        }
        if ($null -ne $lifecycleHeartbeat) {
            $extraProperties['last_heartbeat_run_id'] = $runId
            $extraProperties['last_heartbeat_profile'] = 'isolated-enterprise'
            $extraProperties['last_heartbeat_at'] = $nowUtc.ToString('o')
        }
        $manifestStatus = if ($health -eq 'offline') { 'offline' } elseif ($status -in @('issued', 'refreshed')) { 'ready' } else { '' }
        Set-WorkersManifestLifecycleCommand -Entry $slot.Entry -CommandName 'workers.broker.token' -Status $manifestStatus -ExtraProperties $extraProperties
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$Options.Json) -Text "$status broker token for $runId"
}

function Invoke-WorkersBrokerBaseline {
    param([Parameter(Mandatory = $true)]$Options)

    $slot = Get-WorkersSingleSlotContext -ProjectDir $Options.ProjectDir -Target $Options.Target
    $slotProfile = [string]$slot.SlotConfig.ExecutionProfile
    if ([string]::IsNullOrWhiteSpace($slotProfile)) {
        $slotProfile = 'local-windows'
    }

    $requestedProfile = [string]$Options.Profile
    if ([string]::IsNullOrWhiteSpace($requestedProfile)) {
        $requestedProfile = 'isolated-enterprise'
    }
    if (Get-Command Test-BridgeExecutionProfileKind -ErrorAction SilentlyContinue) {
        if (-not (Test-BridgeExecutionProfileKind -Value $requestedProfile)) {
            Stop-WithError "unsupported execution profile for brokered execution baseline: $requestedProfile"
        }
    }
    if (-not [string]::Equals($requestedProfile, 'isolated-enterprise', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError 'brokered execution baseline requires execution profile isolated-enterprise'
    }
    if (-not [string]::Equals($slotProfile, $requestedProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "worker slot $($slot.Row.SlotId) uses execution profile '$slotProfile', not $requestedProfile"
    }

    $runId = Assert-WorkersRunId -RunId ([string]$Options.RunId)
    if ([string]::IsNullOrWhiteSpace($runId)) {
        Stop-WithError 'brokered execution baseline requires --run-id'
    }
    $nodeId = Assert-WorkersPathSegment -Value ([string]$Options.NodeId) -Name 'broker node id'
    $endpoint = Assert-WorkersBrokerEndpoint -Endpoint ([string]$Options.Endpoint)

    $runDir = Get-WorkersIsolatedWorkspaceRunDirectory -ProjectDir $Options.ProjectDir -SlotId ([string]$slot.Row.SlotId) -RunId $runId
    if (-not (Test-Path -LiteralPath $runDir -PathType Container)) {
        Stop-WithError "brokered execution baseline requires an existing isolated workspace run: $runId"
    }
    Assert-WorkersIsolatedWorkspaceCleanupTarget -ProjectDir $Options.ProjectDir -RunDir $runDir

    $workspaceDir = Join-Path $runDir 'workspace'
    $downloadsDir = Join-Path $runDir 'downloads'
    $artifactsDir = Join-Path $runDir 'artifacts'
    foreach ($requiredDir in @($workspaceDir, $downloadsDir, $artifactsDir)) {
        if (-not (Test-Path -LiteralPath $requiredDir -PathType Container)) {
            Stop-WithError "brokered execution baseline requires prepared isolated workspace directories: $runId"
        }
    }

    Assert-WorkersNoReparsePointUnderDirectory -RootDir $runDir -Name 'brokered execution baseline'

    $manifestPath = Join-Path $runDir 'broker-baseline.json'
    $heartbeatPath = Join-Path $runDir 'heartbeat.json'
    $runReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $runDir
    $workspaceReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $workspaceDir
    $downloadsReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $downloadsDir
    $artifactsReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $artifactsDir
    $heartbeatReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $heartbeatPath
    $manifestReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $manifestPath

    $payload = [ordered]@{
        version       = 1
        project_ref   = '.'
        generated_at  = (Get-Date).ToUniversalTime().ToString('o')
        command       = 'workers.broker.baseline'
        status        = 'broker_defined'
        slot          = [string]$slot.Row.Slot
        slot_id       = [string]$slot.Row.SlotId
        role          = [string]$slot.SlotConfig.WorkerRole
        run_id        = $runId
        execution_profile = 'isolated-enterprise'
        broker_kind   = 'single_external_worker_node'
        public_default = $false
        node          = [ordered]@{
            node_id                  = $nodeId
            endpoint                 = $endpoint
            endpoint_contains_secret = $false
            command_starts_process   = $false
        }
        topology      = [ordered]@{
            mode                  = 'single_broker'
            multi_broker_supported = $false
            multi_hub_supported    = $false
        }
        boundary      = [ordered]@{
            workspace = [ordered]@{
                run_root  = $runReference
                workspace = $workspaceReference
                downloads = $downloadsReference
                artifacts = $artifactsReference
                direct_project_write = 'prohibited'
            }
            heartbeat = [ordered]@{
                artifact = $heartbeatReference
                state_model = @('running', 'blocked', 'approval_waiting', 'child_wait', 'stalled', 'offline', 'completed', 'resumable')
                broker_must_report_liveness = $true
            }
            connection = [ordered]@{
                operator_mediated = $true
                command_connects_network = $false
                command_launches_external_worker = $false
            }
            credentials = [ordered]@{
                endpoint_credentials_allowed = $false
                uses_run_secret_projection = $true
                secret_values_in_manifest = $false
            }
        }
        failure_policy = [ordered]@{
            fail_closed_on = @(
                'non_isolated_enterprise_profile',
                'missing_isolated_workspace_run',
                'missing_workspace_directories',
                'invalid_broker_endpoint',
                'endpoint_credentials',
                'run_directory_reparse_point',
                'path_escape'
            )
            unsafe_claims_prohibited = $true
        }
        locations     = [ordered]@{
            run_root  = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $runReference -Backend 'local-windows' -AccessMethod 'isolated_run_root' -Reference $runReference -Provenance 'workers.broker.run_root'
            workspace = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $workspaceReference -Backend 'local-windows' -AccessMethod 'isolated_workspace' -Reference $workspaceReference -Provenance 'workers.broker.workspace'
            downloads = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $downloadsReference -Backend 'local-windows' -AccessMethod 'isolated_downloads' -Reference $downloadsReference -Provenance 'workers.broker.downloads'
            artifacts = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $artifactsReference -Backend 'local-windows' -AccessMethod 'isolated_artifacts' -Reference $artifactsReference -Provenance 'workers.broker.artifacts'
            heartbeat = New-WinsmuxLocationIdentity -Kind 'local_file' -DisplayName 'heartbeat.json' -Backend 'local-windows' -AccessMethod 'heartbeat_artifact' -Reference $heartbeatReference -Provenance 'workers.broker.heartbeat'
            manifest  = New-WinsmuxLocationIdentity -Kind 'local_file' -DisplayName 'broker-baseline.json' -Backend 'local-windows' -AccessMethod 'artifact_ref' -Reference $manifestReference -Provenance 'workers.broker.manifest'
        }
        testable_guards = @(
            'isolated_enterprise_profile_required',
            'existing_isolated_workspace_required',
            'single_broker_only',
            'endpoint_credentials_rejected',
            'artifact_paths_project_relative'
        )
        exit_code     = 0
    }

    Write-WorkersJsonArtifact -Path $manifestPath -Data $payload | Out-Null
    if ($null -ne $slot.Entry) {
        Set-WorkersManifestLifecycleCommand -Entry $slot.Entry -CommandName 'workers.broker.baseline' -ExtraProperties ([ordered]@{
            last_broker_run_id   = $runId
            last_broker_profile  = 'isolated-enterprise'
            last_broker_node_id  = $nodeId
            last_broker_endpoint = $endpoint
            last_broker_status   = 'broker_defined'
            last_broker_manifest = $manifestReference
        })
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$Options.Json) -Text "defined broker baseline for $runId"
}

function Invoke-WorkersBroker {
    $usage = "usage: winsmux workers broker baseline <slot> --run-id <id> --endpoint <url> [--node-id <id>] [--profile isolated-enterprise] [--json] [--project-dir <path>]; winsmux workers broker token <issue|check> <slot> --run-id <id> [--ttl-seconds <n>] [--no-refresh] [--json] [--project-dir <path>]"
    $options = Read-WorkersBrokerOptions -Usage $usage
    switch ([string]$options.Action) {
        'baseline' { Invoke-WorkersBrokerBaseline -Options $options }
        'token' { Invoke-WorkersBrokerToken -Options $options }
        default { Stop-WithError $usage }
    }
}

function Invoke-WorkersPolicyBaseline {
    param([Parameter(Mandatory = $true)]$Options)

    $slot = Get-WorkersSingleSlotContext -ProjectDir $Options.ProjectDir -Target $Options.Target
    $slotProfile = [string]$slot.SlotConfig.ExecutionProfile
    if ([string]::IsNullOrWhiteSpace($slotProfile)) {
        $slotProfile = 'local-windows'
    }

    $requestedProfile = [string]$Options.Profile
    if ([string]::IsNullOrWhiteSpace($requestedProfile)) {
        $requestedProfile = 'isolated-enterprise'
    }
    if (Get-Command Test-BridgeExecutionProfileKind -ErrorAction SilentlyContinue) {
        if (-not (Test-BridgeExecutionProfileKind -Value $requestedProfile)) {
            Stop-WithError "unsupported execution profile for enterprise execution policy: $requestedProfile"
        }
    }
    if (-not [string]::Equals($requestedProfile, 'isolated-enterprise', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError 'enterprise execution policy requires execution profile isolated-enterprise'
    }
    if (-not [string]::Equals($slotProfile, $requestedProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "worker slot $($slot.Row.SlotId) uses execution profile '$slotProfile', not $requestedProfile"
    }

    $runId = Assert-WorkersRunId -RunId ([string]$Options.RunId)
    if ([string]::IsNullOrWhiteSpace($runId)) {
        Stop-WithError 'enterprise execution policy requires --run-id'
    }

    $runDir = Get-WorkersIsolatedWorkspaceRunDirectory -ProjectDir $Options.ProjectDir -SlotId ([string]$slot.Row.SlotId) -RunId $runId
    if (-not (Test-Path -LiteralPath $runDir -PathType Container)) {
        Stop-WithError "enterprise execution policy requires an existing isolated workspace run: $runId"
    }
    Assert-WorkersIsolatedWorkspaceCleanupTarget -ProjectDir $Options.ProjectDir -RunDir $runDir

    $workspaceDir = Join-Path $runDir 'workspace'
    $downloadsDir = Join-Path $runDir 'downloads'
    $artifactsDir = Join-Path $runDir 'artifacts'
    foreach ($requiredDir in @($workspaceDir, $downloadsDir, $artifactsDir)) {
        if (-not (Test-Path -LiteralPath $requiredDir -PathType Container)) {
            Stop-WithError "enterprise execution policy requires prepared isolated workspace directories: $runId"
        }
    }

    Assert-WorkersNoReparsePointUnderDirectory -RootDir $runDir -Name 'enterprise execution policy'

    $baselinePath = Join-Path $runDir 'broker-baseline.json'
    if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
        Stop-WithError "enterprise execution policy requires an existing broker baseline: $runId"
    }
    $brokerBaseline = $null
    try {
        $brokerBaseline = Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Stop-WithError "enterprise execution policy requires a readable broker baseline: $runId"
    }
    if (-not [string]::Equals(([string](Get-SendConfigValue -InputObject $brokerBaseline -Name 'status' -Default '')), 'broker_defined', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "enterprise execution policy requires an existing broker baseline: $runId"
    }
    $brokerNode = Get-SendConfigValue -InputObject $brokerBaseline -Name 'node' -Default $null
    $brokerNodeId = [string](Get-SendConfigValue -InputObject $brokerNode -Name 'node_id' -Default 'broker-1')
    $brokerEndpoint = [string](Get-SendConfigValue -InputObject $brokerNode -Name 'endpoint' -Default '')

    $tokenManifestPath = Join-Path $runDir 'broker-token.json'
    if (-not (Test-Path -LiteralPath $tokenManifestPath -PathType Leaf)) {
        Stop-WithError "enterprise execution policy requires a valid broker token: $runId"
    }
    $tokenManifest = Read-WorkersBrokerTokenManifest -Path $tokenManifestPath
    if ($null -eq $tokenManifest) {
        Stop-WithError "enterprise execution policy requires a valid broker token: $runId"
    }
    $tokenHealth = [string](Get-SendConfigValue -InputObject $tokenManifest -Name 'health' -Default '')
    $runToken = Get-SendConfigValue -InputObject $tokenManifest -Name 'run_token' -Default $null
    $tokenExpiresAtText = [string](Get-SendConfigValue -InputObject $runToken -Name 'expires_at' -Default '')
    $tokenExpiresAt = ConvertTo-WorkersUtcDateTime -Value $tokenExpiresAtText
    $nowUtc = Get-WorkersNowUtc
    if (-not [string]::Equals($tokenHealth, 'valid', [System.StringComparison]::OrdinalIgnoreCase) -or $null -eq $tokenExpiresAt -or $tokenExpiresAt -le $nowUtc) {
        Stop-WithError "enterprise execution policy requires a valid broker token: $runId"
    }
    $tokenNode = Get-SendConfigValue -InputObject $tokenManifest -Name 'node' -Default $null
    $tokenNodeId = [string](Get-SendConfigValue -InputObject $tokenNode -Name 'node_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($tokenNodeId) -or -not [string]::Equals($tokenNodeId, $brokerNodeId, [System.StringComparison]::Ordinal)) {
        Stop-WithError "enterprise execution policy requires a valid broker token: $runId"
    }
    $tokenBaseline = Get-SendConfigValue -InputObject $tokenManifest -Name 'broker_baseline' -Default $null
    $tokenBaselineNodeId = [string](Get-SendConfigValue -InputObject $tokenBaseline -Name 'node_id' -Default '')
    $tokenBaselineEndpoint = [string](Get-SendConfigValue -InputObject $tokenBaseline -Name 'endpoint' -Default '')
    if ([string]::IsNullOrWhiteSpace($tokenBaselineNodeId) -or -not [string]::Equals($tokenBaselineNodeId, $brokerNodeId, [System.StringComparison]::Ordinal)) {
        Stop-WithError "enterprise execution policy requires a valid broker token: $runId"
    }
    if ([string]::IsNullOrWhiteSpace($tokenBaselineEndpoint) -or -not [string]::Equals($tokenBaselineEndpoint, $brokerEndpoint, [System.StringComparison]::Ordinal)) {
        Stop-WithError "enterprise execution policy requires a valid broker token: $runId"
    }

    $tokenPath = Join-Path (Join-Path $runDir 'secrets') 'broker-run-token.txt'
    $tokenReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $tokenPath
    $tokenValueRef = [string](Get-SendConfigValue -InputObject $runToken -Name 'value_ref' -Default '')
    $tokenFingerprint = [string](Get-SendConfigValue -InputObject $runToken -Name 'fingerprint' -Default '')
    if ([string]::IsNullOrWhiteSpace($tokenValueRef) -or -not [string]::Equals($tokenValueRef, $tokenReference, [System.StringComparison]::Ordinal)) {
        Stop-WithError "enterprise execution policy requires a valid broker token: $runId"
    }
    if ([string]::IsNullOrWhiteSpace($tokenFingerprint) -or -not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
        Stop-WithError "enterprise execution policy requires a valid broker token: $runId"
    }
    try {
        $tokenValue = (Get-Content -LiteralPath $tokenPath -Raw -Encoding UTF8).Trim()
        if ([string]::IsNullOrWhiteSpace($tokenValue) -or -not [string]::Equals((Get-WorkersBrokerRunTokenFingerprint -Value $tokenValue), $tokenFingerprint, [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-WithError "enterprise execution policy requires a valid broker token: $runId"
        }
    } catch {
        Stop-WithError "enterprise execution policy requires a valid broker token: $runId"
    }

    $manifestPath = Join-Path $runDir 'execution-policy.json'
    $runReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $runDir
    $workspaceReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $workspaceDir
    $downloadsReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $downloadsDir
    $artifactsReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $artifactsDir
    $baselineReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $baselinePath
    $tokenManifestReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $tokenManifestPath
    $manifestReference = Get-WorkersArtifactReference -ProjectDir $Options.ProjectDir -Path $manifestPath

    $writeAllowedRoots = @()
    switch ([string]$Options.Write) {
        'workspace-artifacts' { $writeAllowedRoots = @($workspaceReference, $artifactsReference) }
        'workspace-only' { $writeAllowedRoots = @($workspaceReference) }
        default { $writeAllowedRoots = @() }
    }
    $requiredEvidence = $Options.RequiredEvidence
    $requiredEvidenceSummary = @($requiredEvidence.GetEnumerator() | ForEach-Object {
        "$($_.Key):$(@($_.Value) -join ',')"
    }) -join ';'
    $mandatoryChecks = @($Options.RequiredChecks)
    $mandatoryChecksSummary = $mandatoryChecks -join ','
    $outboundNetwork = 'blocked_before_execution'
    if ([string]::Equals(([string]$Options.Network), 'allowed', [System.StringComparison]::OrdinalIgnoreCase)) {
        $outboundNetwork = 'allowed'
    }

    $payload = [ordered]@{
        version       = 1
        project_ref   = '.'
        generated_at  = $nowUtc.ToString('o')
        command       = 'workers.policy.baseline'
        status        = 'policy_defined'
        health        = 'enforced'
        reason        = 'policy_enforced_before_execution'
        slot          = [string]$slot.Row.Slot
        slot_id       = [string]$slot.Row.SlotId
        role          = [string]$slot.SlotConfig.WorkerRole
        run_id        = $runId
        execution_profile = 'isolated-enterprise'
        public_default = $false
        controls      = [ordered]@{
            network = [ordered]@{
                mode = [string]$Options.Network
                outbound_network = $outboundNetwork
                broker_endpoint = $brokerEndpoint
                broker_only_requires_token = $true
            }
            write = [ordered]@{
                mode = [string]$Options.Write
                allowed_roots = @($writeAllowedRoots)
                direct_project_write = 'prohibited'
            }
            provider = [ordered]@{
                mode = [string]$Options.Provider
                registry_required = $true
                prompt_override_allowed = $false
            }
        }
        required_evidence = $requiredEvidence
        mandatory_checks = @($mandatoryChecks)
        alignment = [ordered]@{
            broker_baseline = [ordered]@{
                manifest = $baselineReference
                node_id = $brokerNodeId
                endpoint = $brokerEndpoint
            }
            broker_token = [ordered]@{
                manifest = $tokenManifestReference
                health = $tokenHealth
                expires_at = $tokenExpiresAtText
                baseline_node_id = $tokenBaselineNodeId
                baseline_endpoint = $tokenBaselineEndpoint
                value_output = $false
                value_in_manifest = $false
            }
        }
        failure_policy = [ordered]@{
            pre_execution_required = $true
            boundary_enforced_before_worker_start = $true
            operator_visible_stop_reasons = $true
            fail_closed_on = @(
                'non_isolated_enterprise_profile',
                'missing_isolated_workspace_run',
                'missing_broker_baseline',
                'missing_or_invalid_broker_token',
                'expired_broker_token',
                'run_directory_reparse_point',
                'invalid_policy_option',
                'path_escape'
            )
        }
        operator_surface = [ordered]@{
            status_projection = 'workers.status.policy'
            reason_property = 'last_policy_reason'
            manifest_property = 'last_policy_manifest'
        }
        locations     = [ordered]@{
            run_root  = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $runReference -Backend 'local-windows' -AccessMethod 'isolated_run_root' -Reference $runReference -Provenance 'workers.policy.run_root'
            workspace = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $workspaceReference -Backend 'local-windows' -AccessMethod 'isolated_workspace' -Reference $workspaceReference -Provenance 'workers.policy.workspace'
            downloads = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $downloadsReference -Backend 'local-windows' -AccessMethod 'isolated_downloads' -Reference $downloadsReference -Provenance 'workers.policy.downloads'
            artifacts = New-WinsmuxLocationIdentity -Kind 'local_directory' -DisplayName $artifactsReference -Backend 'local-windows' -AccessMethod 'isolated_artifacts' -Reference $artifactsReference -Provenance 'workers.policy.artifacts'
            manifest  = New-WinsmuxLocationIdentity -Kind 'local_file' -DisplayName 'execution-policy.json' -Backend 'local-windows' -AccessMethod 'artifact_ref' -Reference $manifestReference -Provenance 'workers.policy.manifest'
        }
        testable_guards = @(
            'isolated_enterprise_profile_required',
            'existing_isolated_workspace_required',
            'broker_baseline_required',
            'valid_broker_token_required',
            'policy_options_validated',
            'operator_status_projection'
        )
        exit_code     = 0
    }

    Write-WorkersJsonArtifact -Path $manifestPath -Data $payload | Out-Null
    if ($null -ne $slot.Entry) {
        Set-WorkersManifestLifecycleCommand -Entry $slot.Entry -CommandName 'workers.policy.baseline' -Status 'ready' -ExtraProperties ([ordered]@{
            last_policy_run_id            = $runId
            last_policy_profile           = 'isolated-enterprise'
            last_policy_status            = 'policy_defined'
            last_policy_health            = 'enforced'
            last_policy_reason            = 'policy_enforced_before_execution'
            last_policy_network           = [string]$Options.Network
            last_policy_write             = [string]$Options.Write
            last_policy_provider          = [string]$Options.Provider
            last_policy_mandatory_checks  = $mandatoryChecksSummary
            last_policy_required_evidence = $requiredEvidenceSummary
            last_policy_manifest          = $manifestReference
        })
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$Options.Json) -Text "defined enterprise execution policy for $runId"
}

function Invoke-WorkersPolicy {
    $usage = "usage: winsmux workers policy baseline <slot> --run-id <id> [--profile isolated-enterprise] [--network <blocked|broker-only|allowed>] [--write <read-only|workspace-artifacts|workspace-only>] [--provider <blocked|configured|allowed>] [--require-check <name>] [--require-evidence <role:name>] [--json] [--project-dir <path>]"
    $options = Read-WorkersPolicyOptions -Usage $usage
    switch ([string]$options.Action) {
        'baseline' { Invoke-WorkersPolicyBaseline -Options $options }
        default { Stop-WithError $usage }
    }
}

function Invoke-WorkersExec {
    $usage = "usage: winsmux workers exec <slot> --script <path> [--task-id <id>] [--run-id <id>] [--json] [--project-dir <path>]"
    $options = Read-WorkersExecOptions -Usage $usage
    $worker = Get-WorkersSingleColabContext -ProjectDir $options.ProjectDir -Target $options.Target
    $scriptInfo = Resolve-WorkersProjectPath -ProjectDir $options.ProjectDir -Path $options.ScriptPath -MustExist -AllowFile -MaxBytes (Get-WorkersUploadMaxBytes)
    $safetyInput = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @(Get-WorkersExecSafetyInputValues -ProjectDir $options.ProjectDir -ScriptArgs @($options.ScriptArgs))) {
        $safetyInput.Add([string]$value) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:WINSMUX_TASK_JSON)) {
        $safetyInput.Add([string]$env:WINSMUX_TASK_JSON) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$options.TaskId)) {
        $safetyInput.Add([string]$options.TaskId) | Out-Null
    }
    Assert-WorkersColabSafetyInput -Values @($safetyInput) -Name 'Colab task input'
    $runId = Assert-WorkersRunId -RunId ([string]$options.RunId)
    if ([string]::IsNullOrWhiteSpace($runId)) {
        $runId = New-WorkersRunId -SlotId ([string]$worker.Row.SlotId)
    }
    $runDir = Get-WorkersRunDirectory -ProjectDir $options.ProjectDir -SlotId ([string]$worker.Row.SlotId) -RunId $runId
    if (-not (Test-Path -LiteralPath $runDir -PathType Container)) {
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    }

    $arguments = @('run', '--session', [string]$worker.Session, '--script', [string]$scriptInfo.FullPath, '--run-id', $runId, '--output-dir', $runDir)
    if (-not [string]::IsNullOrWhiteSpace([string]$options.TaskId)) {
        $arguments += @('--task-id', [string]$options.TaskId)
    }
    $arguments += @($options.ScriptArgs)
    $cli = Invoke-WorkersColabCli -Arguments $arguments
    $safeCliOutput = ConvertTo-WorkersSafeLogText -Text ([string]$cli.Output)
    $logPath = Join-Path $runDir 'stdout.log'
    Write-ClmSafeTextFile -Path $logPath -Content $safeCliOutput
    $status = if ([int]$cli.ExitCode -eq 0) { 'succeeded' } else { 'failed' }

    $payload = [ordered]@{
        project_dir    = $options.ProjectDir
        generated_at   = (Get-Date).ToUniversalTime().ToString('o')
        command        = 'workers.exec'
        status         = $status
        slot           = [string]$worker.Row.Slot
        slot_id        = [string]$worker.Row.SlotId
        session        = [string]$worker.Session
        run_id         = $runId
        task_id        = [string]$options.TaskId
        script         = [string]$scriptInfo.RelativePath
        run_dir        = Get-WorkersArtifactReference -ProjectDir $options.ProjectDir -Path $runDir
        stdout_log     = Get-WorkersArtifactReference -ProjectDir $options.ProjectDir -Path $logPath
        exit_code      = [int]$cli.ExitCode
        cli_command    = ConvertTo-WorkersSafeLogText -Text ([string]$cli.Command)
        cli_arguments  = @(ConvertTo-WorkersSafeArgumentArray -Arguments @($cli.Arguments))
    }
    $runJsonPath = Join-Path $runDir 'run.json'
    $payload['run_json'] = Get-WorkersArtifactReference -ProjectDir $options.ProjectDir -Path $runJsonPath
    Write-WorkersJsonArtifact -Path $runJsonPath -Data $payload | Out-Null
    if ($null -ne $worker.Entry) {
        Set-WorkersManifestLifecycleCommand -Entry $worker.Entry -CommandName 'workers.exec'
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$options.Json)
}

function Get-WorkersLatestRunDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId
    )

    $safeSlotId = Assert-WorkersPathSegment -Value $SlotId -Name 'slot id'
    $root = Join-Path (Join-Path (Join-Path $ProjectDir '.winsmux') 'worker-runs') $safeSlotId
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return $null
    }

    $runs = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'stdout.log') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $_.FullName 'run.json') -PathType Leaf)
    } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($runs.Count -eq 0) {
        return $null
    }

    return $runs[0]
}

function Invoke-WorkersLogs {
    $usage = "usage: winsmux workers logs <slot> [--run-id <id>] [--json] [--project-dir <path>]"
    $options = Read-WorkersLogsOptions -Usage $usage
    $worker = Get-WorkersSingleColabContext -ProjectDir $options.ProjectDir -Target $options.Target
    $runId = Assert-WorkersRunId -RunId ([string]$options.RunId)
    $runDir = $null
    if ([string]::IsNullOrWhiteSpace($runId)) {
        $latest = Get-WorkersLatestRunDirectory -ProjectDir $options.ProjectDir -SlotId ([string]$worker.Row.SlotId)
        if ($null -ne $latest) {
            $runId = [string]$latest.Name
            $runDir = [string]$latest.FullName
        }
    } else {
        $runDir = Get-WorkersRunDirectory -ProjectDir $options.ProjectDir -SlotId ([string]$worker.Row.SlotId) -RunId $runId
    }

    $content = ''
    $source = 'local'
    $cli = $null
    $hasLocalLog = $false
    $localStatus = 'succeeded'
    $localExitCode = 0
    if (-not [string]::IsNullOrWhiteSpace($runDir)) {
        $logPath = Join-Path $runDir 'stdout.log'
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            $hasLocalLog = $true
            $rawLog = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
            $rawLogText = if ($null -eq $rawLog) { '' } else { [string]$rawLog }
            $content = ConvertTo-WorkersSafeLogText -Text $rawLogText
            $runJsonPath = Join-Path $runDir 'run.json'
            if (Test-Path -LiteralPath $runJsonPath -PathType Leaf) {
                try {
                    $runJson = Get-Content -LiteralPath $runJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $storedStatus = [string](Get-SendConfigValue -InputObject $runJson -Name 'status' -Default '')
                    if (-not [string]::IsNullOrWhiteSpace($storedStatus)) {
                        $localStatus = $storedStatus
                    }
                    $storedExitCode = 0
                    $rawStoredExitCode = Get-SendConfigValue -InputObject $runJson -Name 'exit_code' -Default 0
                    if ([int]::TryParse(([string]$rawStoredExitCode), [ref]$storedExitCode)) {
                        $localExitCode = $storedExitCode
                    }
                    if ($localExitCode -ne 0 -and [string]::Equals($localStatus, 'succeeded', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $localStatus = 'failed'
                    }
                } catch {
                    $localStatus = 'succeeded'
                    $localExitCode = 0
                }
            }
        }
    }
    if (-not $hasLocalLog) {
        $arguments = @('logs', '--session', [string]$worker.Session)
        if (-not [string]::IsNullOrWhiteSpace($runId)) {
            $arguments += @('--run-id', $runId)
        }
        $cli = Invoke-WorkersColabCli -Arguments $arguments
        $content = ConvertTo-WorkersSafeLogText -Text ([string]$cli.Output)
        $source = 'google-colab-cli'
    }
    $status = 'succeeded'
    if ($null -ne $cli -and [int]$cli.ExitCode -ne 0) {
        $status = 'failed'
    } elseif ($hasLocalLog) {
        $status = $localStatus
    }

    $payload = [ordered]@{
        project_dir  = $options.ProjectDir
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        command      = 'workers.logs'
        status       = $status
        slot         = [string]$worker.Row.Slot
        slot_id      = [string]$worker.Row.SlotId
        session      = [string]$worker.Session
        run_id       = $runId
        source       = $source
        log          = $content
        exit_code    = if ($null -ne $cli) { [int]$cli.ExitCode } else { [int]$localExitCode }
        cli_command  = if ($null -ne $cli) { ConvertTo-WorkersSafeLogText -Text ([string]$cli.Command) } else { '' }
        cli_arguments = if ($null -ne $cli) { @(ConvertTo-WorkersSafeArgumentArray -Arguments @($cli.Arguments)) } else { @() }
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$options.Json) -Text $content
}

function Invoke-WorkersUpload {
    $usage = "usage: winsmux workers upload <slot> <path> [--remote <path>] [--allow-dir <path>] [--run-id <id>] [--max-bytes <n>] [--json] [--project-dir <path>]"
    $options = Read-WorkersTransferOptions -Usage $usage -Mode 'upload'
    $worker = Get-WorkersSingleColabContext -ProjectDir $options.ProjectDir -Target $options.Target
    $source = Resolve-WorkersProjectPath -ProjectDir $options.ProjectDir -Path $options.Source -MustExist -AllowFile -AllowDirectory -MaxBytes ([long]$options.MaxBytes)
    $allowDirs = @($options.AllowDirs | ForEach-Object {
        Resolve-WorkersProjectPath -ProjectDir $options.ProjectDir -Path $_ -MustExist -AllowDirectory
    })
    $manifestEntries = Get-WorkersUploadManifestEntries -ProjectDir $options.ProjectDir -SourceInfo $source -AllowDirs $allowDirs -MaxBytes ([long]$options.MaxBytes)
    $remote = Assert-WorkersRemotePath -RemotePath ([string]$options.Remote)
    $runId = Assert-WorkersRunId -RunId ([string]$options.RunId)
    if ([string]::IsNullOrWhiteSpace($runId)) {
        $runId = New-WorkersRunId -SlotId ([string]$worker.Row.SlotId)
    }
    $runDir = Get-WorkersRunDirectory -ProjectDir $options.ProjectDir -SlotId ([string]$worker.Row.SlotId) -RunId $runId
    if (-not (Test-Path -LiteralPath $runDir -PathType Container)) {
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    }

    $manifestPath = Join-Path $runDir 'upload-manifest.json'
    $manifest = [ordered]@{
        run_id       = $runId
        slot_id      = [string]$worker.Row.SlotId
        source       = [string]$source.RelativePath
        remote       = ConvertTo-WorkersSafeLogText -Text $remote
        max_bytes    = [long]$options.MaxBytes
        files        = @($manifestEntries.Files)
        excluded     = @($manifestEntries.Excluded)
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-WorkersJsonArtifact -Path $manifestPath -Data $manifest | Out-Null

    $uploadSource = New-WorkersSafeUploadSource -ProjectDir $options.ProjectDir -SourceInfo $source -Files @($manifestEntries.Files) -RunDir $runDir
    $manifest['staged_source'] = [string]$uploadSource.Reference
    Write-WorkersJsonArtifact -Path $manifestPath -Data $manifest | Out-Null

    $sourceLocationKind = if ([bool]$source.IsDirectory) { 'local_directory' } else { 'local_file' }
    $stagedSourceLocationKind = if ([bool]$uploadSource.Staged) { 'local_directory' } else { $sourceLocationKind }
    $stagedSourceAccessMethod = if ([bool]$uploadSource.Staged) { 'runtime_staging' } else { 'project_path' }
    $stagedSourceProvenance = if ([bool]$uploadSource.Staged) { 'workers.upload.staged_source' } else { 'workers.upload.source' }
    $safeRemote = ConvertTo-WorkersSafeLogText -Text $remote
    $manifestReference = Get-WorkersArtifactReference -ProjectDir $options.ProjectDir -Path $manifestPath
    $arguments = @('upload', '--session', [string]$worker.Session, '--source', [string]$uploadSource.FullPath, '--dest', $remote, '--manifest', $manifestPath, '--run-id', $runId)
    $cli = Invoke-WorkersColabCli -Arguments $arguments
    $status = if ([int]$cli.ExitCode -eq 0) { 'succeeded' } else { 'failed' }
    $payload = [ordered]@{
        project_dir    = $options.ProjectDir
        generated_at   = (Get-Date).ToUniversalTime().ToString('o')
        command        = 'workers.upload'
        status         = $status
        slot           = [string]$worker.Row.Slot
        slot_id        = [string]$worker.Row.SlotId
        session        = [string]$worker.Session
        run_id         = $runId
        source         = [string]$source.RelativePath
        staged_source  = [string]$uploadSource.Reference
        remote         = $safeRemote
        manifest       = $manifestReference
        locations      = [ordered]@{
            source        = New-WinsmuxLocationIdentity -Kind $sourceLocationKind -DisplayName ([string]$source.RelativePath) -Backend 'local-windows' -AccessMethod 'project_path' -Reference ([string]$source.RelativePath) -Provenance 'workers.upload.source'
            staged_source = New-WinsmuxLocationIdentity -Kind $stagedSourceLocationKind -DisplayName ([string]$uploadSource.Reference) -Backend 'local-windows' -AccessMethod $stagedSourceAccessMethod -Reference ([string]$uploadSource.Reference) -Provenance $stagedSourceProvenance
            remote        = New-WinsmuxLocationIdentity -Kind 'remote_artifact' -DisplayName $safeRemote -Backend 'colab_cli' -AccessMethod 'adapter_remote_path' -RemotePath $safeRemote -Provenance 'workers.upload.remote'
            manifest      = New-WinsmuxLocationIdentity -Kind 'local_file' -DisplayName 'upload-manifest.json' -Backend 'local-windows' -AccessMethod 'artifact_ref' -Reference $manifestReference -Provenance 'workers.upload.manifest'
        }
        uploaded_count = @($manifestEntries.Files).Count
        excluded_count = @($manifestEntries.Excluded).Count
        exit_code      = [int]$cli.ExitCode
        cli_command    = ConvertTo-WorkersSafeLogText -Text ([string]$cli.Command)
        cli_arguments  = @(ConvertTo-WorkersSafeArgumentArray -Arguments @($cli.Arguments))
    }
    Write-WorkersJsonArtifact -Path (Join-Path $runDir 'upload.json') -Data $payload | Out-Null
    if ($null -ne $worker.Entry) {
        Set-WorkersManifestLifecycleCommand -Entry $worker.Entry -CommandName 'workers.upload'
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$options.Json)
}

function Invoke-WorkersDownload {
    $usage = "usage: winsmux workers download <slot> <remote-path> [--output <path>] [--run-id <id>] [--json] [--project-dir <path>]"
    $options = Read-WorkersTransferOptions -Usage $usage -Mode 'download'
    $worker = Get-WorkersSingleColabContext -ProjectDir $options.ProjectDir -Target $options.Target
    $remote = Assert-WorkersRemotePath -RemotePath ([string]$options.Remote)
    $runId = Assert-WorkersRunId -RunId ([string]$options.RunId)
    if ([string]::IsNullOrWhiteSpace($runId)) {
        $runId = New-WorkersRunId -SlotId ([string]$worker.Row.SlotId)
    }
    $runDir = Get-WorkersRunDirectory -ProjectDir $options.ProjectDir -SlotId ([string]$worker.Row.SlotId) -RunId $runId
    if (-not (Test-Path -LiteralPath $runDir -PathType Container)) {
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    }

    $outputPath = [string]$options.Output
    $explicitOutput = -not [string]::IsNullOrWhiteSpace($outputPath)
    if (-not $explicitOutput) {
        $safeSlotId = Assert-WorkersPathSegment -Value ([string]$worker.Row.SlotId) -Name 'slot id'
        $outputPath = Join-Path (Join-Path (Join-Path (Join-Path $options.ProjectDir '.winsmux') 'worker-downloads') $safeSlotId) $runId
    }
    $outputInfo = if ($explicitOutput) {
        Resolve-WorkersProjectPath -ProjectDir $options.ProjectDir -Path $outputPath -AllowDirectory -AllowFile
    } else {
        Resolve-WorkersProjectPath -ProjectDir $options.ProjectDir -Path $outputPath -AllowDirectory -AllowFile -AllowRuntimePath
    }
    $trimmedOutputPath = ([string]$outputPath).TrimEnd()
    $explicitOutputLooksLikeDirectory = $explicitOutput -and ($trimmedOutputPath.EndsWith('\') -or $trimmedOutputPath.EndsWith('/'))
    $downloadToDirectory = (-not $explicitOutput) -or [bool]$outputInfo.IsDirectory -or $explicitOutputLooksLikeDirectory
    if (-not $downloadToDirectory) {
        $parent = Split-Path -Parent $outputInfo.FullPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    } elseif (-not (Test-Path -LiteralPath $outputInfo.FullPath -PathType Container)) {
        New-Item -ItemType Directory -Path $outputInfo.FullPath -Force | Out-Null
    }

    $arguments = @('download', '--session', [string]$worker.Session, '--source', $remote, '--dest', [string]$outputInfo.FullPath, '--run-id', $runId)
    $cli = Invoke-WorkersColabCli -Arguments $arguments
    $status = if ([int]$cli.ExitCode -eq 0) { 'succeeded' } else { 'failed' }
    $safeRemote = ConvertTo-WorkersSafeLogText -Text $remote
    $outputReference = Get-WorkersArtifactReference -ProjectDir $options.ProjectDir -Path ([string]$outputInfo.FullPath)
    $outputLocationKind = if ($downloadToDirectory) { 'local_directory' } else { 'local_file' }
    $payload = [ordered]@{
        project_dir   = $options.ProjectDir
        generated_at  = (Get-Date).ToUniversalTime().ToString('o')
        command       = 'workers.download'
        status        = $status
        slot          = [string]$worker.Row.Slot
        slot_id       = [string]$worker.Row.SlotId
        session       = [string]$worker.Session
        run_id        = $runId
        remote        = $safeRemote
        output        = $outputReference
        locations     = [ordered]@{
            remote = New-WinsmuxLocationIdentity -Kind 'remote_artifact' -DisplayName $safeRemote -Backend 'colab_cli' -AccessMethod 'adapter_remote_path' -RemotePath $safeRemote -Provenance 'workers.download.remote'
            output = New-WinsmuxLocationIdentity -Kind $outputLocationKind -DisplayName $outputReference -Backend 'local-windows' -AccessMethod 'artifact_ref' -Reference $outputReference -Provenance 'workers.download.output'
        }
        exit_code     = [int]$cli.ExitCode
        cli_command   = ConvertTo-WorkersSafeLogText -Text ([string]$cli.Command)
        cli_arguments = @(ConvertTo-WorkersSafeArgumentArray -Arguments @($cli.Arguments))
    }
    Write-WorkersJsonArtifact -Path (Join-Path $runDir 'download.json') -Data $payload | Out-Null
    if ($null -ne $worker.Entry) {
        Set-WorkersManifestLifecycleCommand -Entry $worker.Entry -CommandName 'workers.download'
    }

    Write-WorkersOperationOutput -Payload $payload -Json:([bool]$options.Json)
}

function Invoke-WorkersStatus {
    $usage = "usage: winsmux workers status [slot|all] [--json] [--project-dir <path>]"
    $options = Read-WorkersOptions -Tokens $Rest -Usage $usage -DefaultTarget 'all'
    $context = Get-WorkersLifecycleContext -ProjectDir $options.ProjectDir
    $rows = Select-WorkersRows -Rows (Get-WorkersStatusRows -Context $context) -Target $options.Target
    Write-WorkersStatusOutput -Context $context -Rows $rows -Json:([bool]$options.Json)
}

function Invoke-WorkersStart {
    $usage = "usage: winsmux workers start [slot|all] [--json] [--project-dir <path>]"
    $options = Read-WorkersOptions -Tokens $Rest -Usage $usage -DefaultTarget 'all'
    $context = Get-WorkersLifecycleContext -ProjectDir $options.ProjectDir
    $rows = Select-WorkersRows -Rows (Get-WorkersStatusRows -Context $context) -Target $options.Target
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($row in @($rows)) {
        $entry = if ($context.EntriesBySlot.ContainsKey($row.SlotId)) { $context.EntriesBySlot[$row.SlotId] } else { $null }
        if ($null -eq $entry) {
            $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.start' -Status 'failed' -Reason 'manifest_entry_missing')) | Out-Null
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.PaneId)) {
            $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.start' -Status 'failed' -Reason 'pane_id_missing')) | Out-Null
            continue
        }
        if ([string]$entry.Status -eq 'backend_degraded') {
            $reason = [string]$row.DegradedReason
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $reason = 'backend_degraded'
            }
            $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.start' -Status 'blocked' -Reason $reason)) | Out-Null
            continue
        }
        $approvalDifferences = @($row.ApprovalDifferences)
        if ($approvalDifferences.Count -gt 0) {
            $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.start' -Status 'blocked' -Reason (Format-WorkersLaunchApprovalMismatch -Differences $approvalDifferences))) | Out-Null
            continue
        }

        try {
            if (Test-DeferredPaneStartManifestEntry -ManifestEntry $entry) {
                $started = Start-DeferredPaneFromManifestEntry -ProjectDir $options.ProjectDir -ManifestEntry $entry
                Set-WorkersManifestLifecycleCommand -Entry $entry -CommandName 'workers.start' -Status 'ready' -ExtraProperties ([ordered]@{
                    last_heartbeat_run_id  = ''
                    last_heartbeat_profile = ''
                })
                $status = if ($started) { 'started' } else { 'unchanged' }
                $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.start' -Status $status)) | Out-Null
            } else {
                Set-WorkersManifestLifecycleCommand -Entry $entry -CommandName 'workers.start'
                $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.start' -Status 'already_running')) | Out-Null
            }
        } catch {
            $reason = [string]$_.Exception.Message
            $status = if ($reason -like 'worker launch approval mismatch:*') { 'blocked' } else { 'failed' }
            $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.start' -Status $status -Reason $reason)) | Out-Null
        }
    }

    Write-WorkersLifecycleOutput -ProjectDir $options.ProjectDir -Results @($results) -Json:([bool]$options.Json)
}

function Invoke-WorkersAttach {
    $usage = "usage: winsmux workers attach <slot|all> [--json] [--project-dir <path>]"
    $options = Read-WorkersOptions -Tokens $Rest -Usage $usage -RequireTarget
    $context = Get-WorkersLifecycleContext -ProjectDir $options.ProjectDir
    $rows = Select-WorkersRows -Rows (Get-WorkersStatusRows -Context $context) -Target $options.Target
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($row in @($rows)) {
        $entry = if ($context.EntriesBySlot.ContainsKey($row.SlotId)) { $context.EntriesBySlot[$row.SlotId] } else { $null }
        if (-not [string]::Equals(([string]$row.Backend), 'colab_cli', [System.StringComparison]::OrdinalIgnoreCase)) {
            $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.attach' -Status 'skipped' -Reason 'backend_not_colab_cli')) | Out-Null
            continue
        }

        if ([string]$row.State -eq 'backend_degraded' -or -not [string]::IsNullOrWhiteSpace([string]$row.DegradedReason)) {
            $reason = [string]$row.DegradedReason
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $reason = 'backend_degraded'
            }
            if ($null -ne $entry) {
                Set-WorkersManifestLifecycleCommand -Entry $entry -CommandName 'workers.attach' -Status 'backend_degraded'
            }
            $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.attach' -Status 'degraded' -Reason $reason)) | Out-Null
            continue
        }

        if ($null -eq $entry) {
            $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.attach' -Status 'pending_launch' -Reason 'manifest_entry_missing')) | Out-Null
            continue
        }

        Set-WorkersManifestLifecycleCommand -Entry $entry -CommandName 'workers.attach'
        $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.attach' -Status 'attached')) | Out-Null
    }

    Write-WorkersLifecycleOutput -ProjectDir $options.ProjectDir -Results @($results) -Json:([bool]$options.Json)
}

function Invoke-WorkersStop {
    $usage = "usage: winsmux workers stop <slot|all> [--json] [--project-dir <path>]"
    $options = Read-WorkersOptions -Tokens $Rest -Usage $usage -RequireTarget
    $context = Get-WorkersLifecycleContext -ProjectDir $options.ProjectDir
    $rows = Select-WorkersRows -Rows (Get-WorkersStatusRows -Context $context) -Target $options.Target
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($row in @($rows)) {
        $entry = if ($context.EntriesBySlot.ContainsKey($row.SlotId)) { $context.EntriesBySlot[$row.SlotId] } else { $null }
        if ($null -eq $entry) {
            $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.stop' -Status 'failed' -Reason 'manifest_entry_missing')) | Out-Null
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.PaneId)) {
            $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.stop' -Status 'failed' -Reason 'pane_id_missing')) | Out-Null
            continue
        }

        try {
            Invoke-WinsmuxRaw -Arguments @('respawn-pane', '-k', '-t', [string]$entry.PaneId) | Out-Null
            $nativeExitCode = Get-SafeLastExitCode
            if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
                throw "failed to stop pane process: $($entry.PaneId)"
            }

            Clear-ReadMark ([string]$entry.PaneId)
            Clear-Watermark ([string]$entry.PaneId)
            $nextStatus = if ([string]$entry.Status -eq 'backend_degraded') { 'backend_degraded' } else { 'deferred_start' }
            Set-WorkersManifestLifecycleCommand -Entry $entry -CommandName 'workers.stop' -Status $nextStatus
            $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.stop' -Status 'stopped' -Reason $nextStatus)) | Out-Null
        } catch {
            $results.Add((New-WorkersLifecycleResult -Row $row -Action 'workers.stop' -Status 'failed' -Reason $_.Exception.Message)) | Out-Null
        }
    }

    Write-WorkersLifecycleOutput -ProjectDir $options.ProjectDir -Results @($results) -Json:([bool]$options.Json)
}

function Write-WorkersLifecycleOutput {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][object[]]$Results,
        [switch]$Json
    )

    if ($Json) {
        [ordered]@{
            project_dir  = $ProjectDir
            generated_at = (Get-Date).ToUniversalTime().ToString('o')
            results      = @($Results)
        } | ConvertTo-Json -Depth 16 -Compress | Write-Output
        return
    }

    foreach ($result in @($Results)) {
        $line = "$($result.slot_id): $($result.status)"
        if (-not [string]::IsNullOrWhiteSpace([string]$result.reason)) {
            $line = "$line ($($result.reason))"
        }
        Write-Output $line
    }
}

function New-WorkersDoctorCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Detail,
        [AllowEmptyString()][string]$Action = ''
    )

    return [ordered]@{
        status = $Status
        label  = $Label
        detail = $Detail
        action = $Action
    }
}

function Invoke-WorkersDoctor {
    $usage = "usage: winsmux workers doctor [--json] [--project-dir <path>]"
    $options = Read-WorkersOptions -Tokens $Rest -Usage $usage
    if (-not [string]::IsNullOrWhiteSpace($options.Target)) {
        Stop-WithError $usage
    }

    $checks = [System.Collections.Generic.List[object]]::new()
    $context = $null
    $colabSlotCount = 0

    try {
        $context = Get-WorkersLifecycleContext -ProjectDir $options.ProjectDir
        $workerCount = @($context.Slots).Count
        foreach ($slot in @($context.Slots)) {
            $slotId = Get-WorkersSlotId -Slot $slot
            $slotConfig = Get-SlotAgentConfig -Role 'Worker' -SlotId $slotId -Settings $context.Settings -RootPath $options.ProjectDir
            if ([string]::Equals(([string]$slotConfig.WorkerBackend), 'colab_cli', [System.StringComparison]::OrdinalIgnoreCase)) {
                $colabSlotCount++
            }
        }
        $checks.Add((New-WorkersDoctorCheck -Status 'pass' -Label 'config' -Detail "$workerCount worker slots configured" -Action '')) | Out-Null
    } catch {
        $checks.Add((New-WorkersDoctorCheck -Status 'fail' -Label 'config' -Detail $_.Exception.Message -Action 'Fix .winsmux.yaml and rerun winsmux workers doctor.')) | Out-Null
    }

    $manifestPath = Join-Path (Join-Path $options.ProjectDir '.winsmux') 'manifest.yaml'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $checks.Add((New-WorkersDoctorCheck -Status 'pass' -Label 'manifest' -Detail $manifestPath -Action '')) | Out-Null
    } else {
        $checks.Add((New-WorkersDoctorCheck -Status 'warn' -Label 'manifest' -Detail "manifest not found: $manifestPath" -Action 'Run winsmux launch before workers start or stop.')) | Out-Null
    }

    $uvCommand = Get-Command uv -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $uvCommand) {
        $checks.Add((New-WorkersDoctorCheck -Status 'pass' -Label 'uv' -Detail ([string]$uvCommand.Source) -Action '')) | Out-Null
    } else {
        $checks.Add((New-WorkersDoctorCheck -Status 'fail' -Label 'uv' -Detail 'uv not found on PATH' -Action 'Install uv or add it to PATH before launching managed workers.')) | Out-Null
    }

    $cli = $null
    if (Get-Command Get-WinsmuxColabCliAvailability -ErrorAction SilentlyContinue) {
        $cli = Get-WinsmuxColabCliAvailability
    }
    if ($null -eq $cli) {
        $checks.Add((New-WorkersDoctorCheck -Status 'warn' -Label 'google-colab-cli' -Detail 'Colab backend helpers are unavailable' -Action 'Check the winsmux installation.')) | Out-Null
    } elseif ([bool](Get-SendConfigValue -InputObject $cli -Name 'available' -Default $false)) {
        $checks.Add((New-WorkersDoctorCheck -Status 'pass' -Label 'google-colab-cli' -Detail ([string](Get-SendConfigValue -InputObject $cli -Name 'path' -Default 'google-colab-cli')) -Action '')) | Out-Null
    } else {
        $status = if ($colabSlotCount -gt 0) { 'fail' } else { 'warn' }
        $checks.Add((New-WorkersDoctorCheck -Status $status -Label 'google-colab-cli' -Detail 'google-colab-cli not found on PATH' -Action 'Install google-colab-cli or change colab_cli slots to local until it is available.')) | Out-Null
    }

    if ($null -ne $cli -and (Get-Command Get-WinsmuxColabAuthState -ErrorAction SilentlyContinue)) {
        $auth = Get-WinsmuxColabAuthState -CliAvailability $cli
        if ($colabSlotCount -lt 1) {
            $checks.Add((New-WorkersDoctorCheck -Status 'pass' -Label 'colab auth' -Detail 'no colab_cli worker slots configured' -Action '')) | Out-Null
        } elseif ([bool](Get-SendConfigValue -InputObject $auth -Name 'available' -Default $false)) {
            $checks.Add((New-WorkersDoctorCheck -Status 'pass' -Label 'colab auth' -Detail ([string](Get-SendConfigValue -InputObject $auth -Name 'state' -Default 'authenticated')) -Action '')) | Out-Null
        } else {
            $reason = [string](Get-SendConfigValue -InputObject $auth -Name 'reason' -Default 'colab_auth_unverified')
            $status = if ([string]::Equals($reason, 'colab_auth_unverified', [System.StringComparison]::OrdinalIgnoreCase)) { 'warn' } else { 'fail' }
            $action = if ($status -eq 'warn') { 'Run a google-colab-cli command or continue; the adapter may complete authentication interactively.' } else { 'Authenticate google-colab-cli in the local user session.' }
            $checks.Add((New-WorkersDoctorCheck -Status $status -Label 'colab auth' -Detail $reason -Action $action)) | Out-Null
        }
    }

    $statePath = if ($null -ne $context) { [string]$context.ColabState.StatePath } else { '' }
    if ([string]::IsNullOrWhiteSpace($statePath) -and (Get-Command Get-WinsmuxColabStatePath -ErrorAction SilentlyContinue)) {
        $statePath = Get-WinsmuxColabStatePath -ProjectDir $options.ProjectDir
    }
    if (-not [string]::IsNullOrWhiteSpace($statePath)) {
        $stateParent = Split-Path -Parent $statePath
        if (Test-Path -LiteralPath $stateParent -PathType Container) {
            $checks.Add((New-WorkersDoctorCheck -Status 'pass' -Label 'session state path' -Detail $statePath -Action '')) | Out-Null
        } else {
            $checks.Add((New-WorkersDoctorCheck -Status 'warn' -Label 'session state path' -Detail $statePath -Action 'Run winsmux workers status or winsmux launch to create the state directory.')) | Out-Null
        }
    }

    if ($null -ne $context -and -not [string]::IsNullOrWhiteSpace([string]$context.ColabState.ErrorReason)) {
        $checks.Add((New-WorkersDoctorCheck -Status 'fail' -Label 'colab session state' -Detail ([string]$context.ColabState.ErrorReason) -Action 'Fix the session-state file or remove it so winsmux can recreate it.')) | Out-Null
    } elseif ($null -ne $context -and [int]$context.ColabState.DegradedCount -gt 0) {
        $checks.Add((New-WorkersDoctorCheck -Status 'warn' -Label 'colab session state' -Detail "$($context.ColabState.DegradedCount) degraded colab_cli worker sessions" -Action 'Run winsmux workers status --json for per-slot degraded reasons.')) | Out-Null
    }

    $rows = if ($null -ne $context) { Get-WorkersStatusRows -Context $context } else { @() }
    if ($options.Json) {
        [ordered]@{
            project_dir  = $options.ProjectDir
            generated_at = (Get-Date).ToUniversalTime().ToString('o')
            checks       = @($checks)
            workers      = @(ConvertTo-WorkersStatusJsonRows -Rows @($rows))
        } | ConvertTo-Json -Depth 20 -Compress | Write-Output
        return
    }

    Write-Output "=== winsmux workers doctor ==="
    foreach ($check in @($checks)) {
        $line = "[{0}] {1}: {2}" -f ([string]$check.status).ToUpperInvariant(), $check.label, $check.detail
        Write-Output $line
        if (-not [string]::IsNullOrWhiteSpace([string]$check.action)) {
            Write-Output "  action: $($check.action)"
        }
    }
}

function Invoke-Workers {
    $action = [string]$Target
    if ([string]::IsNullOrWhiteSpace($action)) {
        Stop-WithError (Get-WorkersUsage)
    }

    switch ($action.Trim().ToLowerInvariant()) {
        'status' { Invoke-WorkersStatus }
        'start'  { Invoke-WorkersStart }
        'attach' { Invoke-WorkersAttach }
        'stop'   { Invoke-WorkersStop }
        'doctor' { Invoke-WorkersDoctor }
        'workspace' { Invoke-WorkersWorkspace }
        'secrets' { Invoke-WorkersSecrets }
        'heartbeat' { Invoke-WorkersHeartbeat }
        'sandbox' { Invoke-WorkersSandbox }
        'broker' { Invoke-WorkersBroker }
        'policy' { Invoke-WorkersPolicy }
        'exec'   { Invoke-WorkersExec }
        'logs'   { Invoke-WorkersLogs }
        'upload' { Invoke-WorkersUpload }
        'download' { Invoke-WorkersDownload }
        default  { Stop-WithError (Get-WorkersUsage) }
    }
}

function Get-BoardStateCounts {
    param(
        [Parameter(Mandatory = $true)][object[]]$Records,
        [Parameter(Mandatory = $true)][scriptblock]$Selector
    )

    $counts = [ordered]@{}
    foreach ($record in $Records) {
        $value = [string](& $Selector $record)
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = 'unknown'
        }

        if ($counts.Contains($value)) {
            $counts[$value] = [int]$counts[$value] + 1
        } else {
            $counts[$value] = 1
        }
    }

    return $counts
}

function New-RunStateModel {
    param(
        [string]$State = '',
        [string]$TaskState = '',
        [string]$ReviewState = '',
        [string]$EventKind = '',
        [string]$LastEvent = ''
    )

    $stateText = ([string]$State).ToLowerInvariant()
    $taskText = ([string]$TaskState).ToLowerInvariant()
    $reviewText = ([string]$ReviewState).ToUpperInvariant()
    $kindText = ([string]$EventKind).ToLowerInvariant()
    $eventText = ([string]$LastEvent).ToLowerInvariant()

    $phase = 'build'
    $activity = 'running'
    $detail = 'in_progress'

    if ($kindText -in @('commit_ready', 'task_completed') -or $taskText -in @('completed', 'task_completed', 'done', 'commit_ready')) {
        $phase = 'package'
        $activity = 'completed'
        $detail = if (-not [string]::IsNullOrWhiteSpace($kindText)) { $kindText } else { 'task_completed' }
    } elseif ($kindText -eq 'needs_user_decision' -or $kindText -eq 'draft_pr_required' -or $eventText -eq 'operator.draft_pr.required') {
        $phase = 'package'
        $activity = 'waiting_for_input'
        $detail = 'needs_user_decision'
    } elseif ($reviewText -in @('FAIL', 'FAILED') -or $kindText -in @('review_failed')) {
        $phase = 'review'
        $activity = 'blocked'
        $detail = 'review_failed'
    } elseif ($reviewText -eq 'PENDING' -or $kindText -in @('review_pending', 'review_requested')) {
        $phase = 'review'
        $activity = 'waiting_for_input'
        $detail = if ($kindText -eq 'review_requested') { 'review_requested' } else { 'review_pending' }
    } elseif ($reviewText -eq 'PASS') {
        $phase = 'package'
        $activity = 'waiting_for_input'
        $detail = 'needs_user_decision'
    } elseif ($taskText -eq 'blocked' -or $kindText -in @('blocked', 'task_blocked') -or $eventText -like '*blocked*') {
        $phase = 'build'
        $activity = 'blocked'
        $detail = if (-not [string]::IsNullOrWhiteSpace($kindText)) { $kindText } else { 'task_blocked' }
    } elseif ($stateText -in @('offline', 'crashed', 'hung', 'bootstrap_invalid') -or $kindText -in @('crashed', 'hung', 'bootstrap_invalid')) {
        $phase = 'build'
        $activity = 'offline'
        $detail = if (-not [string]::IsNullOrWhiteSpace($kindText)) { $kindText } else { $stateText }
    } elseif ($taskText -eq 'backlog' -or $kindText -eq 'dispatch_needed' -or $stateText -eq 'idle') {
        $phase = 'brainstorm'
        $activity = 'waiting_for_input'
        $detail = if (-not [string]::IsNullOrWhiteSpace($kindText)) { $kindText } elseif (-not [string]::IsNullOrWhiteSpace($taskText)) { $taskText } else { 'idle' }
    } elseif (-not [string]::IsNullOrWhiteSpace($taskText)) {
        $phase = 'build'
        $activity = 'running'
        $detail = $taskText
    } elseif (-not [string]::IsNullOrWhiteSpace($stateText)) {
        $phase = 'build'
        $activity = if ($stateText -eq 'busy') { 'running' } else { 'waiting_for_input' }
        $detail = $stateText
    }

    return [ordered]@{
        phase    = $phase
        activity = $activity
        detail   = $detail
    }
}

function Get-BoardPayload {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $records = @(Get-PaneStatusRecords -ProjectDir $ProjectDir | Sort-Object Label)
    $summary = [ordered]@{
        pane_count        = $records.Count
        dirty_panes       = @($records | Where-Object { [int]$_.ChangedFileCount -gt 0 }).Count
        review_pending    = @($records | Where-Object { [string]$_.ReviewState -eq 'PENDING' }).Count
        review_failed     = @($records | Where-Object { [string]$_.ReviewState -in @('FAIL', 'FAILED') }).Count
        review_passed     = @($records | Where-Object { [string]$_.ReviewState -eq 'PASS' }).Count
        tasks_in_progress = @($records | Where-Object { [string]$_.TaskState -eq 'in_progress' }).Count
        tasks_blocked     = @($records | Where-Object { [string]$_.TaskState -eq 'blocked' }).Count
        by_state          = Get-BoardStateCounts -Records $records -Selector { param($Record) $Record.State }
        by_review         = Get-BoardStateCounts -Records $records -Selector { param($Record) $Record.ReviewState }
        by_task_state     = Get-BoardStateCounts -Records $records -Selector { param($Record) $Record.TaskState }
    }

    $panes = @(
        $records | ForEach-Object {
            $stateModel = New-RunStateModel -State ([string]$_.State) -TaskState ([string]$_.TaskState) -ReviewState ([string]$_.ReviewState) -LastEvent ([string]$_.LastEvent)
            [ordered]@{
                label              = $_.Label
                role               = $_.Role
                pane_id            = $_.PaneId
                state              = $_.State
                tokens_remaining   = $_.TokensRemaining
                task_id            = $_.TaskId
                task               = $_.Task
                task_state         = $_.TaskState
                task_owner         = $_.TaskOwner
                review_state       = $_.ReviewState
                phase              = $stateModel.phase
                activity           = $stateModel.activity
                detail             = $stateModel.detail
                branch             = $_.Branch
                worktree           = if ($null -ne $_.PSObject.Properties['Worktree']) { [string]$_.Worktree } else { '' }
                head_sha           = $_.HeadSha
                changed_file_count = $_.ChangedFileCount
                changed_files      = @($_.ChangedFiles)
                last_event         = $_.LastEvent
                last_event_at      = $_.LastEventAt
                parent_run_id      = [string]$_.ParentRunId
                goal               = [string]$_.Goal
                task_type          = [string]$_.TaskType
                priority           = [string]$_.Priority
                blocking           = [bool]$_.Blocking
                write_scope        = @($_.WriteScope)
                read_scope         = @($_.ReadScope)
                constraints        = @($_.Constraints)
                expected_output    = [string]$_.ExpectedOutput
                verification_plan  = @($_.VerificationPlan)
                review_required    = [bool]$_.ReviewRequired
                provider_target    = [string]$_.ProviderTarget
                agent_role         = [string]$_.AgentRole
                timeout_policy     = [string]$_.TimeoutPolicy
                handoff_refs       = @($_.HandoffRefs)
                security_policy    = $_.SecurityPolicy
            }
        }
    )

    return [ordered]@{
        generated_at = (Get-Date).ToString('o')
        project_dir  = $ProjectDir
        summary      = $summary
        panes        = $panes
    }
}

function Invoke-Board {
    param(
        [AllowNull()][string]$BoardTarget = $Target,
        [AllowNull()][string[]]$BoardRest = $Rest
    )

    $jsonOutput = $false

    if ($BoardTarget) {
        if ($BoardTarget -eq '--json' -and (-not $BoardRest -or $BoardRest.Count -eq 0)) {
            $jsonOutput = $true
        } else {
            Stop-WithError "usage: winsmux board [--json]"
        }
    } elseif ($BoardRest -and $BoardRest.Count -gt 0) {
        Stop-WithError "usage: winsmux board [--json]"
    }

    $projectDir = (Get-Location).Path

    try {
        $payload = Get-BoardPayload -ProjectDir $projectDir
    } catch {
        Stop-WithError $_.Exception.Message
    }

    if ($jsonOutput) {
        $payload | ConvertTo-Json -Compress -Depth 10 | Write-Output
        return
    }

    $records = @($payload.panes)
    if ($records.Count -eq 0) {
        Write-Output "(no panes)"
        return
    }

    $table = $records |
        Select-Object `
            @{ Name = 'Label'; Expression = { $_.label } }, `
            @{ Name = 'Role'; Expression = { $_.role } }, `
            @{ Name = 'PaneId'; Expression = { $_.pane_id } }, `
            @{ Name = 'State'; Expression = { $_.state } }, `
            @{ Name = 'Tokens'; Expression = { $_.tokens_remaining } }, `
            @{ Name = 'TaskState'; Expression = { $_.task_state } }, `
            @{ Name = 'Review'; Expression = { $_.review_state } }, `
            @{ Name = 'Changed'; Expression = { $_.changed_file_count } }, `
            @{ Name = 'Branch'; Expression = { $_.branch } }, `
            @{ Name = 'Head'; Expression = { if ([string]::IsNullOrWhiteSpace($_.head_sha)) { '' } elseif ($_.head_sha.Length -le 7) { $_.head_sha } else { $_.head_sha.Substring(0, 7) } } } |
        Format-Table -AutoSize |
        Out-String -Width 4096

    Write-Output ($table.TrimEnd())
}

function Get-BridgeEventsPath {
    param([string]$ProjectDir = (Get-Location).Path)

    return Join-Path (Join-Path $ProjectDir '.winsmux') 'events.jsonl'
}

function Get-BridgeEventRecords {
    param([string]$ProjectDir = (Get-Location).Path)

    $eventsPath = Get-BridgeEventsPath -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) {
        return @()
    }

    try {
        $lines = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8)
    } catch {
        Stop-WithError "failed to read event log: $($_.Exception.Message)"
    }

    $records = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $record = $line | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($null -eq $record) {
                continue
            }

            $record['line_number'] = $i + 1
            $records.Add($record) | Out-Null
        } catch {
            Stop-WithError "failed to parse event log line $($i + 1): $($_.Exception.Message)"
        }
    }

    return @($records)
}

function Get-BridgeEventDelta {
    param(
        [string]$ProjectDir = (Get-Location).Path,
        [int]$Cursor = 0
    )

    $records = @(Get-BridgeEventRecords -ProjectDir $ProjectDir)
    if ($Cursor -gt $records.Count) {
        $Cursor = $records.Count
    }

    return [ordered]@{
        cursor = $records.Count
        events  = @($records | Select-Object -Skip $Cursor)
    }
}

function Get-InboxPriority {
    param([string]$Kind)

    switch ([string]$Kind) {
        'blocked'          { return 0 }
        'task_blocked'     { return 0 }
        'review_failed'    { return 0 }
        'bootstrap_invalid' { return 0 }
        'crashed'          { return 0 }
        'hung'             { return 0 }
        'stalled'          { return 0 }
        'approval_waiting' { return 1 }
        'needs_user_decision' { return 1 }
        'review_requested' { return 1 }
        'review_pending'   { return 1 }
        'dispatch_needed'  { return 2 }
        'task_completed'   { return 2 }
        'commit_ready'     { return 2 }
        default            { return 3 }
    }
}

function New-InboxItem {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Label = '',
        [string]$PaneId = '',
        [string]$Role = '',
        [string]$TaskId = '',
        [string]$Task = '',
        [string]$TaskState = '',
        [string]$ReviewState = '',
        [string]$Phase = '',
        [string]$Activity = '',
        [string]$Detail = '',
        [string]$Branch = '',
        [string]$HeadSha = '',
        [string]$Event = '',
        [string]$Timestamp = '',
        [string]$Source = '',
        [int]$ChangedFileCount = 0
    )

    $stateModel = New-RunStateModel -TaskState $TaskState -ReviewState $ReviewState -EventKind $Kind -LastEvent $Event
    if ([string]::IsNullOrWhiteSpace($Phase)) { $Phase = [string]$stateModel.phase }
    if ([string]::IsNullOrWhiteSpace($Activity)) { $Activity = [string]$stateModel.activity }
    if ([string]::IsNullOrWhiteSpace($Detail)) { $Detail = [string]$stateModel.detail }

    return [ordered]@{
        kind               = $Kind
        priority           = Get-InboxPriority -Kind $Kind
        message            = $Message
        label              = $Label
        pane_id            = $PaneId
        role               = $Role
        task_id            = $TaskId
        task               = $Task
        task_state         = $TaskState
        review_state       = $ReviewState
        phase              = $Phase
        activity           = $Activity
        detail             = $Detail
        branch             = $Branch
        head_sha           = $HeadSha
        changed_file_count = $ChangedFileCount
        event              = $Event
        timestamp          = $Timestamp
        source             = $Source
    }
}

function Get-InboxActionableEventKind {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $eventName = [string]$EventRecord['event']
    $status = [string]$EventRecord['status']
    $data = $null
    if ($EventRecord.Contains('data')) {
        $data = $EventRecord['data']
    }

    $dataStatus = ''
    if ($null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('status')) {
        $dataStatus = [string]$data['status']
    }

    if ($eventName -eq 'approval_waiting' -or $eventName -eq 'pane.approval_waiting' -or $status -eq 'approval_waiting' -or ($eventName -eq 'monitor.status' -and $dataStatus -eq 'approval_waiting')) {
        return 'approval_waiting'
    }

    switch ($eventName) {
        'pane.idle'              { return 'dispatch_needed' }
        'pane.completed'         { return 'task_completed' }
        'pane.bootstrap_invalid' { return 'bootstrap_invalid' }
        'pane.crashed'           { return 'crashed' }
        'pane.hung'              { return 'hung' }
        'pane.stalled'           { return 'stalled' }
    }

    if ($eventName -eq 'operator.state_transition') {
        switch ($status) {
            'blocked_no_review_target' { return 'blocked' }
            'blocked_review_failed'    { return 'review_failed' }
            'commit_ready'             { return 'commit_ready' }
        }

        switch ($dataStatus) {
            'blocked_no_review_target' { return 'blocked' }
            'blocked_review_failed'    { return 'review_failed' }
            'commit_ready'             { return 'commit_ready' }
        }
    }

    switch ($eventName) {
        'operator.review_requested' { return 'review_requested' }
        'operator.review_failed'    { return 'review_failed' }
        'operator.blocked'          { return 'blocked' }
        'operator.commit_ready'     { return 'commit_ready' }
        'operator.draft_pr.required' { return 'needs_user_decision' }
        'pipeline.security.blocked'  { return 'blocked' }
        'security.policy.blocked'    { return 'blocked' }
        default                      { return '' }
    }
}

function ConvertTo-InboxEventItem {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $kind = Get-InboxActionableEventKind -EventRecord $EventRecord
    if ([string]::IsNullOrWhiteSpace($kind)) {
        return $null
    }

    $data = $null
    if ($EventRecord.Contains('data')) {
        $data = $EventRecord['data']
    }

    $taskId = ''
    $branch = [string]$EventRecord['branch']
    $headSha = [string]$EventRecord['head_sha']
    $eventStatus = [string]$EventRecord['status']
    if ($null -ne $data -and $data -is [System.Collections.IDictionary]) {
        if ($data.Contains('task_id')) { $taskId = [string]$data['task_id'] }
        if ([string]::IsNullOrWhiteSpace($branch) -and $data.Contains('branch')) { $branch = [string]$data['branch'] }
        if ([string]::IsNullOrWhiteSpace($headSha) -and $data.Contains('head_sha')) { $headSha = [string]$data['head_sha'] }
        if ([string]::IsNullOrWhiteSpace($eventStatus) -and $data.Contains('to')) { $eventStatus = [string]$data['to'] }
    }

    $eventLabel = [string]$EventRecord['event']
    if (-not [string]::IsNullOrWhiteSpace($eventStatus)) {
        $eventLabel = $eventStatus
    }

    return New-InboxItem `
        -Kind $kind `
        -Message ([string]$EventRecord['message']) `
        -Label ([string]$EventRecord['label']) `
        -PaneId ([string]$EventRecord['pane_id']) `
        -Role ([string]$EventRecord['role']) `
        -TaskId $taskId `
        -Branch $branch `
        -HeadSha $headSha `
        -Event $eventLabel `
        -Timestamp ([string]$EventRecord['timestamp']) `
        -Source 'events'
}

function Get-InboxEventEntityKey {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $eventName = [string]$EventRecord['event']
    if ($eventName -like 'operator.*') {
        return 'operator'
    }

    $paneId = [string]$EventRecord['pane_id']
    if (-not [string]::IsNullOrWhiteSpace($paneId)) {
        return "pane:$paneId"
    }

    $label = [string]$EventRecord['label']
    if (-not [string]::IsNullOrWhiteSpace($label)) {
        return "label:$label"
    }

    return "event:$eventName"
}

function Get-InboxActiveEventRecords {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $records = @(Get-BridgeEventRecords -ProjectDir $ProjectDir)
    $latestByEntity = [ordered]@{}
    foreach ($record in $records) {
        $key = Get-InboxEventEntityKey -EventRecord $record
        $latestByEntity[$key] = $record
    }

    return @($latestByEntity.Values)
}

function Get-InboxStreamStartCursor {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return @(Get-BridgeEventRecords -ProjectDir $ProjectDir).Count
}

function Get-RunIdFromPaneRecord {
    param([Parameter(Mandatory = $true)]$PaneRecord)

    $taskId = [string]$PaneRecord.task_id
    if (-not [string]::IsNullOrWhiteSpace($taskId)) {
        return "task:$taskId"
    }

    $branch = [string]$PaneRecord.branch
    if (-not [string]::IsNullOrWhiteSpace($branch)) {
        return "branch:$branch"
    }

    $paneId = [string]$PaneRecord.pane_id
    if (-not [string]::IsNullOrWhiteSpace($paneId)) {
        return "pane:$paneId"
    }

    return "label:{0}" -f [string]$PaneRecord.label
}

function ConvertTo-ExperimentPacketStringArray {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) {
            return @()
        }

        return @($text)
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $Value) {
            $text = [string]$entry
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $items.Add($text) | Out-Null
            }
        }

        return @($items)
    }

    return @([string]$Value)
}

function Get-ExperimentPacketFromEventRecords {
    param([Parameter(Mandatory = $true)][object[]]$EventRecords)

    $packet = [ordered]@{
        hypothesis           = ''
        test_plan            = [System.Collections.Generic.List[string]]::new()
        result               = ''
        confidence           = $null
        next_action          = ''
        observation_pack_ref = ''
        consultation_ref     = ''
        run_id               = ''
        slot                 = ''
        branch               = ''
        worktree             = ''
        env_fingerprint      = ''
        command_hash         = ''
    }

    $hasContent = $false

    foreach ($eventRecord in @($EventRecords | Sort-Object @{ Expression = { [string]$_.timestamp } }, @{ Expression = { [int]$_.line_number } })) {
        $data = $null
        if ($eventRecord.Contains('data')) {
            $data = $eventRecord['data']
        }

        if ($null -eq $data -or $data -isnot [System.Collections.IDictionary]) {
            continue
        }

        foreach ($fieldName in @('hypothesis', 'result', 'next_action', 'observation_pack_ref', 'consultation_ref', 'run_id', 'slot', 'branch', 'worktree', 'env_fingerprint', 'command_hash')) {
            if ($data.Contains($fieldName)) {
                $value = [string]$data[$fieldName]
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $packet[$fieldName] = $value
                    $hasContent = $true
                }
            }
        }

        if ($data.Contains('test_plan')) {
            foreach ($step in @(ConvertTo-ExperimentPacketStringArray -Value $data['test_plan'])) {
                if (-not $packet.test_plan.Contains($step)) {
                    $packet.test_plan.Add($step) | Out-Null
                    $hasContent = $true
                }
            }
        }

        if ($data.Contains('confidence')) {
            $confidenceValue = $data['confidence']
            if ($null -ne $confidenceValue -and -not [string]::IsNullOrWhiteSpace([string]$confidenceValue)) {
                $packet.confidence = $confidenceValue
                $hasContent = $true
            }
        }

        if ([string]::IsNullOrWhiteSpace([string]$packet.branch)) {
            $eventBranch = [string]$eventRecord['branch']
            if (-not [string]::IsNullOrWhiteSpace($eventBranch)) {
                $packet.branch = $eventBranch
            }
        }
    }

    if (-not $hasContent) {
        return $null
    }

    return [ordered]@{
        hypothesis           = [string]$packet.hypothesis
        test_plan            = @($packet.test_plan)
        result               = [string]$packet.result
        confidence           = $packet.confidence
        next_action          = [string]$packet.next_action
        observation_pack_ref = [string]$packet.observation_pack_ref
        consultation_ref     = [string]$packet.consultation_ref
        run_id               = [string]$packet.run_id
        slot                 = [string]$packet.slot
        branch               = [string]$packet.branch
        worktree             = [string]$packet.worktree
        env_fingerprint      = [string]$packet.env_fingerprint
        command_hash         = [string]$packet.command_hash
    }
}

function Get-HydratedObservationPack {
    param(
        [AllowNull()]$ExperimentPacket,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$ExpectedRunId = ''
    )

    if ($null -eq $ExperimentPacket) {
        return $null
    }

    return Read-WinsmuxArtifactJson `
        -Reference ([string]$ExperimentPacket.observation_pack_ref) `
        -ProjectDir $ProjectDir `
        -ExpectedDirectoryPath (Get-ObservationPackDirectory -ProjectDir $ProjectDir) `
        -ExpectedRunId $ExpectedRunId
}

function Get-HydratedConsultationPacket {
    param(
        [AllowNull()]$ExperimentPacket,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$ExpectedRunId = ''
    )

    if ($null -eq $ExperimentPacket) {
        return $null
    }

    return Read-WinsmuxArtifactJson `
        -Reference ([string]$ExperimentPacket.consultation_ref) `
        -ProjectDir $ProjectDir `
        -ExpectedDirectoryPath (Get-ConsultationDirectory -ProjectDir $ProjectDir) `
        -ExpectedRunId $ExpectedRunId
}

function Get-LatestRunEventDataSnapshot {
    param(
        [object[]]$EventRecords = @(),
        [string[]]$EventNames = @(),
        [string[]]$DataFields = @()
    )

    $snapshot = [ordered]@{}
    $matched = $false
    foreach ($eventRecord in @($EventRecords | Sort-Object @{ Expression = { [string]$_.timestamp } }, @{ Expression = { [int]$_.line_number } })) {
        $eventName = [string]$eventRecord['event']
        if (@($EventNames).Count -gt 0 -and $eventName -notin $EventNames) {
            continue
        }

        $data = $null
        if ($eventRecord.Contains('data')) {
            $data = $eventRecord['data']
        }
        if ($null -eq $data -or $data -isnot [System.Collections.IDictionary]) {
            continue
        }

        foreach ($fieldName in @($DataFields)) {
            if ($data.Contains($fieldName)) {
                $snapshot[$fieldName] = $data[$fieldName]
                $matched = $true
            }
        }
    }

    if (-not $matched) {
        return $null
    }

    return $snapshot
}

function Get-VerificationSnapshotFromEventRecords {
    param([object[]]$EventRecords = @())

    $snapshot = Get-LatestRunEventDataSnapshot `
        -EventRecords $EventRecords `
        -EventNames @('pipeline.verify.pass', 'pipeline.verify.fail', 'pipeline.verify.partial') `
        -DataFields @('verification_contract', 'verification_result', 'verification_evidence', 'build', 'test', 'browser', 'screenshot', 'recording', 'context_budget', 'context_estimate', 'context_pack_id', 'context_pack_version', 'tool_output_pruned_count', 'context_pressure', 'context_mode', 'context_fork_reason', 'semantic_context_pack_id', 'semantic_context_pack_ref', 'source_refs', 'hard_constraints', 'safety_rules', 'performance_budget', 'rationale', 'knowledge_pack_id', 'knowledge_pack_ref', 'knowledge_source_refs', 'operating_guidance_refs', 'knowledge_hard_constraints', 'capability_contract', 'evidence_refs', 'rationale_refs')
    if ($null -eq $snapshot) {
        return $null
    }

    return [ordered]@{
        verification_contract = if ($snapshot.Contains('verification_contract')) { $snapshot['verification_contract'] } else { $null }
        verification_result   = if ($snapshot.Contains('verification_result')) { $snapshot['verification_result'] } else { $null }
        verification_evidence = New-VerificationEvidenceEnvelope -Snapshot $snapshot
    }
}

function Get-VerificationEvidenceField {
    param(
        [AllowNull()]$Snapshot = $null,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Snapshot -or -not ($Snapshot -is [System.Collections.IDictionary])) {
        return $null
    }

    foreach ($containerName in @('verification_evidence', 'verification_result', 'verification_contract')) {
        if ($Snapshot.Contains($containerName)) {
            $container = $Snapshot[$containerName]
            if ($container -is [System.Collections.IDictionary] -and $container.Contains($Name)) {
                return $container[$Name]
            }
        }
    }

    if ($Snapshot.Contains($Name)) {
        return $Snapshot[$Name]
    }

    return $null
}

function New-VerificationEvidenceEnvelope {
    param([AllowNull()]$Snapshot = $null)

    if ($null -eq $Snapshot -or -not ($Snapshot -is [System.Collections.IDictionary])) {
        return $null
    }

    return [ordered]@{
        build                    = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'build'
        test                     = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'test'
        browser                  = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'browser'
        screenshot               = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'screenshot'
        recording                = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'recording'
        context_budget           = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'context_budget'
        context_estimate         = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'context_estimate'
        context_pack_id          = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'context_pack_id'
        context_pack_version     = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'context_pack_version'
        tool_output_pruned_count = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'tool_output_pruned_count'
        context_pressure         = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'context_pressure'
        context_mode             = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'context_mode'
        context_fork_reason      = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'context_fork_reason'
        semantic_context_pack_id  = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'semantic_context_pack_id'
        semantic_context_pack_ref = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'semantic_context_pack_ref'
        source_refs               = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'source_refs'
        hard_constraints          = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'hard_constraints'
        safety_rules              = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'safety_rules'
        performance_budget        = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'performance_budget'
        rationale                 = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'rationale'
        knowledge_pack_id         = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'knowledge_pack_id'
        knowledge_pack_ref        = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'knowledge_pack_ref'
        knowledge_source_refs     = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'knowledge_source_refs'
        operating_guidance_refs   = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'operating_guidance_refs'
        knowledge_hard_constraints = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'knowledge_hard_constraints'
        capability_contract       = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'capability_contract'
        evidence_refs             = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'evidence_refs'
        rationale_refs            = Get-VerificationEvidenceField -Snapshot $Snapshot -Name 'rationale_refs'
    }
}

function Get-SecurityVerdictFromEventRecords {
    param([object[]]$EventRecords = @())

    $snapshot = Get-LatestRunEventDataSnapshot `
        -EventRecords $EventRecords `
        -EventNames @('pipeline.security.blocked', 'security.policy.blocked', 'pipeline.security.allowed', 'security.policy.allowed') `
        -DataFields @('stage', 'attempt', 'task', 'verdict', 'reason', 'advisory_mode', 'allow', 'block', 'next_action')
    if ($null -eq $snapshot) {
        return $null
    }

    return [ordered]@{
        stage         = if ($snapshot.Contains('stage')) { [string]$snapshot['stage'] } else { '' }
        attempt       = if ($snapshot.Contains('attempt')) { $snapshot['attempt'] } else { $null }
        task          = if ($snapshot.Contains('task')) { [string]$snapshot['task'] } else { '' }
        verdict       = if ($snapshot.Contains('verdict')) { [string]$snapshot['verdict'] } else { '' }
        reason        = if ($snapshot.Contains('reason')) { [string]$snapshot['reason'] } else { '' }
        advisory_mode = if ($snapshot.Contains('advisory_mode')) { [bool]$snapshot['advisory_mode'] } else { $false }
        allow         = if ($snapshot.Contains('allow')) { @($snapshot['allow']) } else { @() }
        block         = if ($snapshot.Contains('block')) { @($snapshot['block']) } else { @() }
        next_action   = if ($snapshot.Contains('next_action')) { [string]$snapshot['next_action'] } else { '' }
    }
}

function ConvertTo-RunCheckpointStatus {
    param(
        [string]$EventName,
        [string]$Status = '',
        [AllowNull()]$Data = $null
    )

    if ($EventName -in @('pipeline.verify.pass', 'pipeline.security.allowed', 'security.policy.allowed', 'operator.draft_pr.created', 'pipeline.decompose.completed', 'pipeline.dispatch.assigned', 'pipeline.collect.completed')) {
        return 'completed'
    }
    if ($EventName -in @('pipeline.verify.fail', 'pipeline.security.blocked', 'security.policy.blocked', 'operator.review_failed')) {
        return 'blocked'
    }
    if ($EventName -eq 'operator.draft_pr.required') {
        return 'needs_user_decision'
    }
    if ($EventName -in @('pipeline.verify.partial', 'operator.review_requested', 'pane.approval_waiting', 'pipeline.escalate.required')) {
        return 'waiting'
    }
    if (-not [string]::IsNullOrWhiteSpace($Status)) {
        return [string]$Status
    }
    if ($null -ne $Data -and $Data -is [System.Collections.IDictionary] -and $Data.Contains('verification_result')) {
        $verificationResult = $Data['verification_result']
        if ($verificationResult -is [System.Collections.IDictionary] -and $verificationResult.Contains('outcome')) {
            $outcome = ([string]$verificationResult['outcome']).ToUpperInvariant()
            if ($outcome -eq 'PASS') { return 'completed' }
            if ($outcome -eq 'FAIL') { return 'blocked' }
            if ($outcome -eq 'PARTIAL') { return 'waiting' }
        }
    }

    return 'recorded'
}

function ConvertTo-RunEventTimestampText {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ''
    }
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [datetimeoffset]) {
        return $Value.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }

    return [string]$Value
}

function Get-RunEventTimestampSortKey {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ''
    }
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [datetimeoffset]) {
        return $Value.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }

    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $parsed.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }

    return [string]$Value
}

function Get-RunPlanCheckpointsFromEventRecords {
    param([object[]]$EventRecords = @())

    $checkpoints = [System.Collections.Generic.List[object]]::new()
    $checkpointEvents = @(
        'operator.review_requested',
        'operator.review_failed',
        'pane.approval_waiting',
        'pipeline.verify.pass',
        'pipeline.verify.fail',
        'pipeline.verify.partial',
        'pipeline.security.allowed',
        'pipeline.security.blocked',
        'security.policy.allowed',
        'security.policy.blocked',
        'operator.draft_pr.created',
        'operator.draft_pr.required',
        'pipeline.decompose.completed',
        'pipeline.dispatch.assigned',
        'pipeline.collect.completed',
        'pipeline.escalate.required'
    )

    foreach ($eventRecord in @($EventRecords | Sort-Object @{ Expression = { Get-RunEventTimestampSortKey -Value $_['timestamp'] } }, @{ Expression = { [int]$_.line_number } })) {
        $eventName = [string]$eventRecord['event']
        if ($eventName -notin $checkpointEvents) {
            continue
        }

        $data = $null
        if ($eventRecord.Contains('data')) {
            $data = $eventRecord['data']
        }

        $outcome = ''
        if ($null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('verification_result')) {
            $verificationResult = $data['verification_result']
            if ($verificationResult -is [System.Collections.IDictionary] -and $verificationResult.Contains('outcome')) {
                $outcome = [string]$verificationResult['outcome']
            }
        }
        if ([string]::IsNullOrWhiteSpace($outcome) -and $null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('result')) {
            $outcome = [string]$data['result']
        }

        $lineNumber = [int]$eventRecord['line_number']
        $checkpoints.Add([ordered]@{
            id       = if ($lineNumber -gt 0) { "event:$lineNumber" } else { "event:$($checkpoints.Count + 1)" }
            name     = $eventName
            status   = ConvertTo-RunCheckpointStatus -EventName $eventName -Status ([string]$eventRecord['status']) -Data $data
            at       = ConvertTo-RunEventTimestampText -Value $eventRecord['timestamp']
            event    = $eventName
            outcome  = $outcome
            message  = [string]$eventRecord['message']
        }) | Out-Null
    }

    return @($checkpoints)
}

function Get-ManagedLoopContractFromEventRecords {
    param([object[]]$EventRecords = @())

    $contract = [ordered]@{
        upper_operator       = 'claude_code'
        aggregation_point    = 'claude_code_operator'
        worker_topology      = 'operator_managed_panes'
        peer_to_peer_allowed = $false
        decompose_state      = 'not_recorded'
        assignment_state     = 'not_recorded'
        collection_state     = 'not_recorded'
        escalation_state     = 'none'
        escalation_reason    = ''
        stages               = @()
    }
    $stageRecords = [System.Collections.Generic.List[object]]::new()

    foreach ($eventRecord in @($EventRecords | Sort-Object @{ Expression = { Get-RunEventTimestampSortKey -Value $_['timestamp'] } }, @{ Expression = { [int]$_.line_number } })) {
        $eventName = [string]$eventRecord['event']
        if ($eventName -notin @('pipeline.decompose.completed', 'pipeline.dispatch.assigned', 'pipeline.collect.completed', 'pipeline.escalate.required')) {
            continue
        }

        $data = $null
        if ($eventRecord.Contains('data')) {
            $data = $eventRecord['data']
        }
        if ($null -eq $data -or $data -isnot [System.Collections.IDictionary]) {
            $data = [ordered]@{}
        }

        $stage = if ($data.Contains('stage')) { [string]$data['stage'] } else { $eventName }
        $state = if ($data.Contains('state')) { [string]$data['state'] } else { ConvertTo-RunCheckpointStatus -EventName $eventName -Status ([string]$eventRecord['status']) -Data $data }
        if ($data.Contains('upper_operator') -and -not [string]::IsNullOrWhiteSpace([string]$data['upper_operator'])) {
            $contract['upper_operator'] = [string]$data['upper_operator']
        }
        if ($data.Contains('aggregation_point') -and -not [string]::IsNullOrWhiteSpace([string]$data['aggregation_point'])) {
            $contract['aggregation_point'] = [string]$data['aggregation_point']
        }
        if ($data.Contains('worker_topology') -and -not [string]::IsNullOrWhiteSpace([string]$data['worker_topology'])) {
            $contract['worker_topology'] = [string]$data['worker_topology']
        }
        if ($data.Contains('peer_to_peer_allowed')) {
            $contract['peer_to_peer_allowed'] = [bool]$data['peer_to_peer_allowed']
        }

        switch ($eventName) {
            'pipeline.decompose.completed' { $contract['decompose_state'] = $state }
            'pipeline.dispatch.assigned' { $contract['assignment_state'] = $state }
            'pipeline.collect.completed' { $contract['collection_state'] = $state }
            'pipeline.escalate.required' {
                $contract['escalation_state'] = $state
                if ($data.Contains('reason')) {
                    $contract['escalation_reason'] = [string]$data['reason']
                }
            }
        }

        $stageRecords.Add([ordered]@{
            stage   = $stage
            state   = $state
            event   = $eventName
            target  = if ($data.Contains('target')) { [string]$data['target'] } else { [string]$eventRecord['label'] }
            at      = ConvertTo-RunEventTimestampText -Value $eventRecord['timestamp']
            summary = if ($data.Contains('summary')) { [string]$data['summary'] } else { [string]$eventRecord['message'] }
        }) | Out-Null
    }

    if ($stageRecords.Count -eq 0) {
        return $null
    }

    $contract['stages'] = @($stageRecords)
    return $contract
}

function ConvertTo-RunAuditChainApprovalState {
    param(
        [string]$ReviewState = '',
        [bool]$ReviewRequired = $false
    )

    $normalized = ([string]$ReviewState).ToUpperInvariant()
    if ($normalized -eq 'PASS') { return 'approved' }
    if ($normalized -in @('FAIL', 'FAILED')) { return 'failed' }
    if ($normalized -eq 'PENDING') { return 'pending' }
    if ($ReviewRequired) { return 'missing' }
    return 'not_required'
}

function Get-RunAuditChainDecisionEvent {
    param(
        [object[]]$EventRecords = @(),
        [string]$ReviewState = ''
    )

    $decisionEvents = if (([string]$ReviewState).ToUpperInvariant() -eq 'PASS') {
        @('operator.review_passed', 'review.pass')
    } elseif (([string]$ReviewState).ToUpperInvariant() -in @('FAIL', 'FAILED')) {
        @('operator.review_failed', 'review.fail')
    } else {
        @()
    }

    if (@($decisionEvents).Count -eq 0) {
        return $null
    }

    $matches = @(
        $EventRecords |
            Where-Object { [string]$_['event'] -in $decisionEvents } |
            Sort-Object @{ Expression = { Get-RunEventTimestampSortKey -Value $_['timestamp'] } }, @{ Expression = { [int]$_['line_number'] } } |
            Select-Object -First 1
    )
    if ($matches.Count -gt 0) {
        return $matches[0]
    }
    return $null
}

function New-RunAuditChainEventRecord {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $data = $null
    if ($EventRecord.Contains('data')) {
        $data = $EventRecord['data']
    }
    if ($null -eq $data -or $data -isnot [System.Collections.IDictionary]) {
        $data = [ordered]@{}
    }

    return [ordered]@{
        at       = ConvertTo-RunEventTimestampText -Value $EventRecord['timestamp']
        event    = [string]$EventRecord['event']
        who      = [ordered]@{
            label   = [string]$EventRecord['label']
            pane_id = [string]$EventRecord['pane_id']
            role    = [string]$EventRecord['role']
        }
        what     = if ($data.Contains('action') -and -not [string]::IsNullOrWhiteSpace([string]$data['action'])) { [string]$data['action'] } else { [string]$EventRecord['event'] }
        task_id  = if ($data.Contains('task_id')) { [string]$data['task_id'] } else { '' }
        run_id   = if ($data.Contains('run_id')) { [string]$data['run_id'] } else { '' }
        branch   = if ($data.Contains('branch')) { [string]$data['branch'] } else { [string]$EventRecord['branch'] }
        head_sha = if ($data.Contains('head_sha')) { [string]$data['head_sha'] } else { [string]$EventRecord['head_sha'] }
        message  = [string]$EventRecord['message']
    }
}

function New-RunAuditChainContract {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [object[]]$EventRecords = @()
    )

    $orderedEvents = @(
        $EventRecords |
            Sort-Object @{ Expression = { Get-RunEventTimestampSortKey -Value $_['timestamp'] } }, @{ Expression = { [int]$_['line_number'] } }
    )
    $reviewRequests = @(
        $orderedEvents |
            Where-Object { [string]$_['event'] -eq 'operator.review_requested' } |
            Select-Object -First 1
    )
    $reviewRequest = if ($reviewRequests.Count -gt 0) { $reviewRequests[0] } else { $null }
    $decisionEvent = Get-RunAuditChainDecisionEvent -EventRecords $orderedEvents -ReviewState ([string]$Run.review_state)
    $chainEvents = @(
        $orderedEvents |
            Where-Object {
                [string]$_['event'] -in @(
                    'operator.review_requested',
                    'operator.review_passed',
                    'operator.review_failed',
                    'review.pass',
                    'review.fail',
                    'pane.approval_waiting',
                    'pipeline.tdd.red',
                    'pipeline.tdd.exception',
                    'pipeline.verify.pass',
                    'pipeline.verify.fail',
                    'pipeline.verify.partial',
                    'pipeline.security.allowed',
                    'pipeline.security.blocked',
                    'security.policy.allowed',
                    'security.policy.blocked',
                    'operator.draft_pr.created',
                    'operator.draft_pr.required'
                )
            } |
            ForEach-Object { New-RunAuditChainEventRecord -EventRecord $_ }
    )

    return [ordered]@{
        chain_id = [string]$Run.run_id
        subject  = [ordered]@{
            task_id       = [string]$Run.task_id
            task          = [string]$Run.task
            task_type     = [string]$Run.task_type
            priority      = [string]$Run.priority
            branch        = [string]$Run.branch
            head_sha      = [string]$Run.head_sha
            changed_files = @($Run.changed_files)
            context_contract = $Run.context_contract
        }
        actor    = [ordered]@{
            label           = [string]$Run.primary_label
            pane_id         = [string]$Run.primary_pane_id
            role            = [string]$Run.primary_role
            provider_target = [string]$Run.provider_target
            agent_role      = if (-not [string]::IsNullOrWhiteSpace([string]$Run.agent_role)) { [string]$Run.agent_role } else { [string]$Run.primary_role }
        }
        approval = [ordered]@{
            required                 = [bool]$Run.review_required
            state                    = ConvertTo-RunAuditChainApprovalState -ReviewState ([string]$Run.review_state) -ReviewRequired ([bool]$Run.review_required)
            verdict                  = [string]$Run.review_state
            requested_at             = if ($null -ne $reviewRequest) { ConvertTo-RunEventTimestampText -Value $reviewRequest['timestamp'] } else { '' }
            requested_event          = if ($null -ne $reviewRequest) { [string]$reviewRequest['event'] } else { '' }
            requested_reviewer_label = if ($null -ne $reviewRequest) { [string]$reviewRequest['label'] } else { '' }
            requested_reviewer_pane  = if ($null -ne $reviewRequest) { [string]$reviewRequest['pane_id'] } else { '' }
            requested_reviewer_role  = if ($null -ne $reviewRequest) { [string]$reviewRequest['role'] } else { '' }
            decided_at               = if ($null -ne $decisionEvent) { ConvertTo-RunEventTimestampText -Value $decisionEvent['timestamp'] } else { '' }
            decided_event            = if ($null -ne $decisionEvent) { [string]$decisionEvent['event'] } else { '' }
            human_judgement_required = [bool]$Run.review_required
            automatic_merge_allowed  = $false
        }
        events   = @($chainEvents)
    }
}

function New-RunPlanContract {
    param([Parameter(Mandatory = $true)]$Run)

    return [ordered]@{
        goal              = [string]$Run.goal
        task_type         = [string]$Run.task_type
        priority          = [string]$Run.priority
        write_scope       = @($Run.write_scope)
        read_scope        = @($Run.read_scope)
        constraints       = @($Run.constraints)
        expected_output   = [string]$Run.expected_output
        verification_plan = @($Run.verification_plan)
        review_required   = [bool]$Run.review_required
    }
}

function New-RunOutcomeContract {
    param([Parameter(Mandatory = $true)]$Run)

    $phaseGate = Get-RunContractField -InputObject $Run -Name 'phase_gate'
    $draftPrGate = Get-RunContractField -InputObject $Run -Name 'draft_pr_gate'
    $phaseGateStopReason = [string](Get-RunContractField -InputObject $phaseGate -Name 'stop_reason')
    $draftPrGateState = [string](Get-RunContractField -InputObject $draftPrGate -Name 'state')
    $architectureReviewMissing = Test-RunArchitectureReviewMissing -Run $Run

    $status = ''
    if ([string]$Run.review_state -in @('FAIL', 'FAILED')) {
        $status = 'failed'
    } elseif ($phaseGateStopReason -eq 'needs_user_decision') {
        $status = 'needs_user_decision'
    } elseif (-not [string]::IsNullOrWhiteSpace($phaseGateStopReason)) {
        $status = 'blocked'
    } elseif ($architectureReviewMissing) {
        $status = 'needs_user_decision'
    } elseif ([string]$Run.review_state -eq 'PASS' -and $draftPrGateState -ne 'passed') {
        $status = 'needs_user_decision'
    } elseif ([string]$Run.review_state -eq 'PASS' -or [string]$Run.task_state -in @('completed', 'task_completed', 'commit_ready', 'done')) {
        $status = 'completed'
    } elseif ([string]$Run.task_state -eq 'blocked') {
        $status = 'blocked'
    } elseif ([string]$Run.task_state -eq 'in_progress') {
        $status = 'in_progress'
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Run.task_state)) {
        $status = [string]$Run.task_state
    }

    $reason = ''
    if ($null -ne $Run.verification_result -and -not [string]::IsNullOrWhiteSpace([string]$Run.verification_result.summary)) {
        $reason = [string]$Run.verification_result.summary
    } elseif ($null -ne $Run.experiment_packet -and -not [string]::IsNullOrWhiteSpace([string]$Run.experiment_packet.result)) {
        $reason = [string]$Run.experiment_packet.result
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Run.last_event)) {
        $reason = [string]$Run.last_event
    }

    $confidence = $null
    if ($null -ne $Run.experiment_packet -and $Run.experiment_packet.Contains('confidence')) {
        $confidence = $Run.experiment_packet.confidence
    }

    return [ordered]@{
        status      = $status
        reason      = $reason
        confidence  = $confidence
        source_event = [string]$Run.last_event
    }
}

function Test-RunArchitectureReviewMissing {
    param([Parameter(Mandatory = $true)]$Run)

    $reviewState = [string](Get-RunContractField -InputObject $Run -Name 'review_state')
    $architectureContract = Get-RunContractField -InputObject $Run -Name 'architecture_contract'
    $architectureScoreRegression = [bool](Get-RunContractField -InputObject $architectureContract -Name 'score_regression')
    $architectureBaseline = Get-RunContractField -InputObject $architectureContract -Name 'baseline'
    $architectureReviewRequired = [bool](Get-RunContractField -InputObject $architectureBaseline -Name 'review_required_on_drift')

    return ($architectureScoreRegression -and $architectureReviewRequired -and $reviewState -ne 'PASS')
}

function Set-RunPhaseGateStage {
    param(
        [Parameter(Mandatory = $true)]$StagesByName,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Reason = '',
        [string]$Event = ''
    )

    if (-not $StagesByName.Contains($Name)) {
        return
    }

    $stage = $StagesByName[$Name]
    $stage.status = $Status
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $stage.reason = $Reason
    }
    if (-not [string]::IsNullOrWhiteSpace($Event)) {
        $stage.event = $Event
    }
}

function Test-RunRequiresTddGate {
    param([Parameter(Mandatory = $true)]$Run)

    $taskType = ([string](Get-RunContractField -InputObject $Run -Name 'task_type')).ToLowerInvariant()
    if ($taskType -in @('bug', 'bugfix', 'fix', 'defect', 'core_logic', 'core-logic', 'core')) {
        return $true
    }

    foreach ($path in @((Get-RunContractField -InputObject $Run -Name 'changed_files'))) {
        $normalized = ([string]$path).Replace('\', '/')
        if ($normalized -match '^(core/src/|winsmux-core/scripts/|scripts/winsmux-core\.ps1$)') {
            return $true
        }
    }

    return $false
}

function Get-RunTddEventDataValue {
    param(
        [AllowNull()]$EventRecord,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $EventRecord) {
        return ''
    }

    if ($EventRecord -is [System.Collections.IDictionary] -and $EventRecord.Contains($Name)) {
        return [string]$EventRecord[$Name]
    }

    $property = $EventRecord.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return [string]$property.Value
    }

    $data = $null
    if ($EventRecord -is [System.Collections.IDictionary] -and $EventRecord.Contains('data')) {
        $data = $EventRecord['data']
    } else {
        $dataProperty = $EventRecord.PSObject.Properties['data']
        if ($null -ne $dataProperty) {
            $data = $dataProperty.Value
        }
    }

    if ($null -ne $data) {
        if ($data -is [System.Collections.IDictionary] -and $data.Contains($Name)) {
            return [string]$data[$Name]
        }
        $dataProperty = $data.PSObject.Properties[$Name]
        if ($null -ne $dataProperty) {
            return [string]$dataProperty.Value
        }
    }

    return ''
}

function New-RunTddGateContract {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [object[]]$EventRecords = @()
    )

    $required = Test-RunRequiresTddGate -Run $Run
    $redEvents = @(
        $EventRecords | Where-Object {
            $eventName = [string]$_['event']
            $phase = (Get-RunTddEventDataValue -EventRecord $_ -Name 'tdd_phase').ToLowerInvariant()
            $testFirst = (Get-RunTddEventDataValue -EventRecord $_ -Name 'test_first').ToLowerInvariant()
            $eventName -in @('pipeline.tdd.red', 'pipeline.test.red', 'pipeline.test_first.fail', 'pipeline.test_first.failed') -or
                $phase -eq 'red' -or
                $testFirst -eq 'true'
        } | Sort-Object @{ Expression = { Get-RunEventTimestampSortKey -Value $_['timestamp'] } }, @{ Expression = { [int]$_['line_number'] } }
    )
    $exceptionEvents = @(
        $EventRecords | Where-Object {
            $eventName = [string]$_['event']
            $reason = Get-RunTddEventDataValue -EventRecord $_ -Name 'reason'
            $exceptionReason = Get-RunTddEventDataValue -EventRecord $_ -Name 'tdd_exception_reason'
            ($eventName -eq 'pipeline.tdd.exception' -and (-not [string]::IsNullOrWhiteSpace($exceptionReason) -or -not [string]::IsNullOrWhiteSpace($reason))) -or
                -not [string]::IsNullOrWhiteSpace($exceptionReason) -or
                ($eventName -eq 'pipeline.policy.exception' -and -not [string]::IsNullOrWhiteSpace($reason))
        } | Sort-Object @{ Expression = { Get-RunEventTimestampSortKey -Value $_['timestamp'] } }, @{ Expression = { [int]$_['line_number'] } }
    )

    $state = 'not_required'
    $reason = 'not_required'
    $blockedReasons = @()
    if ($required) {
        if (@($redEvents).Count -gt 0) {
            $state = 'passed'
            $reason = 'red_test_evidence_recorded'
        } elseif (@($exceptionEvents).Count -gt 0) {
            $state = 'waived'
            $reason = 'exception_recorded'
        } else {
            $state = 'blocked'
            $reason = 'tdd_evidence_missing'
            $blockedReasons = @('test-first evidence is missing for a bug fix or core logic change')
        }
    }

    $redEvent = if (@($redEvents).Count -gt 0) { $redEvents[0] } else { $null }
    $exceptionEvent = if (@($exceptionEvents).Count -gt 0) { $exceptionEvents[0] } else { $null }
    $exceptionReason = if ($null -ne $exceptionEvent) {
        $value = Get-RunTddEventDataValue -EventRecord $exceptionEvent -Name 'tdd_exception_reason'
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = Get-RunTddEventDataValue -EventRecord $exceptionEvent -Name 'reason'
        }
        $value
    } else { '' }

    return [ordered]@{
        policy             = 'test_first_required'
        required           = [bool]$required
        state              = $state
        reason             = $reason
        blocked_reasons    = @($blockedReasons)
        exception_reason   = [string]$exceptionReason
        red_event          = if ($null -ne $redEvent) { [string]$redEvent['event'] } else { '' }
        exception_event    = if ($null -ne $exceptionEvent) { [string]$exceptionEvent['event'] } else { '' }
    }
}

function New-RunPhaseGateContract {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [object[]]$EventRecords = @()
    )

    $stageOrder = @('plan', 'build', 'test', 'review', 'package')
    $stagesByName = [ordered]@{}
    foreach ($stageName in $stageOrder) {
        $stagesByName[$stageName] = [ordered]@{
            stage  = $stageName
            status = 'pending'
            reason = ''
            event  = ''
        }
    }

    $runGoal = [string](Get-RunContractField -InputObject $Run -Name 'goal')
    $runTaskState = [string](Get-RunContractField -InputObject $Run -Name 'task_state')
    $runReviewState = [string](Get-RunContractField -InputObject $Run -Name 'review_state')
    $runVerificationPlanRaw = Get-RunContractField -InputObject $Run -Name 'verification_plan'
    $runVerificationPlan = if ($null -eq $runVerificationPlanRaw -or [string]::IsNullOrWhiteSpace([string]$runVerificationPlanRaw)) { @() } else { @($runVerificationPlanRaw) }

    if (-not [string]::IsNullOrWhiteSpace($runGoal) -or @($runVerificationPlan).Count -gt 0) {
        Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'plan' -Status 'completed' -Reason 'run_plan_recorded'
    }
    if (-not [string]::IsNullOrWhiteSpace($runTaskState)) {
        Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'build' -Status 'in_progress' -Reason $runTaskState
    }

    $stopReason = ''
    $stopStage = ''
    $currentStage = 'plan'
    $runHeadSha = [string](Get-RunContractField -InputObject $Run -Name 'head_sha')
    foreach ($eventRecord in @($EventRecords | Sort-Object @{ Expression = { Get-RunEventTimestampSortKey -Value $_['timestamp'] } }, @{ Expression = { [int]$_.line_number } })) {
        $eventName = [string]$eventRecord['event']
        switch ($eventName) {
            'pipeline.decompose.completed' { Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'plan' -Status 'completed' -Reason 'decomposed' -Event $eventName }
            'pipeline.dispatch.assigned' { Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'build' -Status 'in_progress' -Reason 'assigned' -Event $eventName }
            'pipeline.collect.completed' { Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'build' -Status 'completed' -Reason 'collected' -Event $eventName }
            'pipeline.verify.pass' {
                Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'test' -Status 'completed' -Reason 'verification_passed' -Event $eventName
                if ($stopStage -eq 'test') {
                    $stopReason = ''
                    $stopStage = ''
                }
            }
            'pipeline.verify.fail' { Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'test' -Status 'blocked' -Reason 'verification_failed' -Event $eventName; $stopReason = 'verification_failed'; $stopStage = 'test' }
            'pipeline.verify.partial' { Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'test' -Status 'waiting_for_input' -Reason 'verification_partial' -Event $eventName; $stopReason = 'needs_user_decision'; $stopStage = 'test' }
            'operator.review_requested' { Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'review' -Status 'waiting_for_input' -Reason 'review_requested' -Event $eventName }
            'operator.review_failed' { Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'review' -Status 'blocked' -Reason 'review_failed' -Event $eventName; $stopReason = 'review_failed'; $stopStage = 'review' }
            'pipeline.escalate.required' { Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'review' -Status 'waiting_for_input' -Reason 'needs_user_decision' -Event $eventName; $stopReason = 'needs_user_decision'; $stopStage = 'review' }
            'operator.draft_pr.required' { Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'package' -Status 'waiting_for_input' -Reason 'needs_user_decision' -Event $eventName; $stopReason = 'needs_user_decision'; $stopStage = 'package' }
            'operator.draft_pr.created' {
                $draftPrEventMatchesHead = $true
                if (-not [string]::IsNullOrWhiteSpace($runHeadSha)) {
                    $eventHeadSha = [string]$eventRecord['head_sha']
                    $eventData = $eventRecord['data']
                    if ([string]::IsNullOrWhiteSpace($eventHeadSha) -and $null -ne $eventData -and $eventData -is [System.Collections.IDictionary] -and $eventData.Contains('head_sha')) {
                        $eventHeadSha = [string]$eventData['head_sha']
                    }
                    $draftPrEventMatchesHead = (-not [string]::IsNullOrWhiteSpace($eventHeadSha) -and $eventHeadSha -eq $runHeadSha)
                }
                if ($draftPrEventMatchesHead) {
                    Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'package' -Status 'waiting_for_input' -Reason 'draft_pr' -Event $eventName
                    $stopReason = 'draft_pr'
                    $stopStage = 'package'
                }
            }
            'operator.commit_ready' { Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'package' -Status 'completed' -Reason 'commit_ready' -Event $eventName; $stopReason = ''; $stopStage = '' }
        }
    }

    if ($runReviewState -eq 'PASS') {
        Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'review' -Status 'completed' -Reason 'review_passed'
        if ($stopStage -eq 'review') {
            $stopReason = ''
            $stopStage = ''
        }
        $draftPrGate = Get-RunContractField -InputObject $Run -Name 'draft_pr_gate'
        $draftPrGateState = [string](Get-RunContractField -InputObject $draftPrGate -Name 'state')
        if (-not [string]::IsNullOrWhiteSpace($draftPrGateState) -and $draftPrGateState -ne 'passed') {
            Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'package' -Status 'waiting_for_input' -Reason 'needs_user_decision'
            $stopReason = 'needs_user_decision'
            $stopStage = 'package'
        }
    } elseif ($runReviewState -eq 'PENDING') {
        Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'review' -Status 'waiting_for_input' -Reason 'review_pending'
    } elseif ($runReviewState -in @('FAIL', 'FAILED')) {
        Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'review' -Status 'blocked' -Reason 'review_failed'
        $stopReason = 'review_failed'
        $stopStage = 'review'
    }

    if ($runTaskState -in @('completed', 'task_completed', 'commit_ready', 'done')) {
        Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'build' -Status 'completed' -Reason $runTaskState
        Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'package' -Status 'completed' -Reason $runTaskState
        if ($runTaskState -in @('commit_ready', 'done')) {
            $stopReason = ''
            $stopStage = ''
        }
    }

    $tddGate = Get-RunContractField -InputObject $Run -Name 'tdd_gate'
    $tddGateState = [string](Get-RunContractField -InputObject $tddGate -Name 'state')
    if ($tddGateState -eq 'blocked') {
        Set-RunPhaseGateStage -StagesByName $stagesByName -Name 'test' -Status 'blocked' -Reason 'tdd_evidence_missing'
        $stopReason = 'tdd_evidence_missing'
        $stopStage = 'test'
    }

    $stages = @($stageOrder | ForEach-Object { $stagesByName[$_] })
    for ($i = $stageOrder.Count - 1; $i -ge 0; $i--) {
        $candidate = $stagesByName[$stageOrder[$i]]
        if ([string]$candidate.status -ne 'pending') {
            $currentStage = [string]$candidate.stage
            break
        }
    }

    return [ordered]@{
        order                   = $stageOrder
        current_stage           = $currentStage
        stages                  = $stages
        stop_required           = -not [string]::IsNullOrWhiteSpace($stopReason)
        stop_reason             = $stopReason
        stop_stage              = $stopStage
        auto_continue_allowed   = [string]::IsNullOrWhiteSpace($stopReason)
        requires_human_decision = $stopReason -in @('needs_user_decision', 'draft_pr')
    }
}

function Add-RunInsightText {
    param(
        [Parameter(Mandatory = $true)]$List,
        [AllowNull()]$Value
    )

    $text = ([string]$Value).Trim()
    if (-not [string]::IsNullOrWhiteSpace($text) -and -not $List.Contains($text)) {
        $List.Add($text) | Out-Null
    }
}

function Get-RunEventAttempt {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $data = if ($EventRecord.Contains('data')) { $EventRecord['data'] } else { $null }
    if ($null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('attempt')) {
        $attempt = 0
        if ([int]::TryParse(([string]$data['attempt']), [ref]$attempt)) {
            return $attempt
        }
    }

    return 0
}

function New-RunInsightsContract {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [AllowEmptyCollection()]
        [object[]]$EventRecords = @()
    )

    $driftSignals = [System.Collections.Generic.List[string]]::new()
    $blockedReasons = [System.Collections.Generic.List[string]]::new()
    $nextImprovements = [System.Collections.Generic.List[string]]::new()

    $retryCount = 0
    $interventionCount = @($Run.action_items).Count

    foreach ($eventRecord in @($EventRecords)) {
        $eventName = [string]$eventRecord['event']
        $eventText = ("{0} {1} {2}" -f $eventName, [string]$eventRecord['message'], [string]$eventRecord['status']).ToLowerInvariant()
        $nextAction = ''
        $data = if ($eventRecord.Contains('data')) { $eventRecord['data'] } else { $null }
        if ($null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('next_action')) {
            $nextAction = [string]$data['next_action']
        }
        $retryText = ("{0} {1}" -f $eventText, $nextAction).ToLowerInvariant()
        if ($retryText.Contains('retry') -or $retryText.Contains('rerun') -or (Get-RunEventAttempt -EventRecord $eventRecord) -gt 1) {
            $retryCount++
        }

        if (Test-RunDriftSignalText -EventName $eventName -Text $eventText) {
            Add-RunInsightText -List $driftSignals -Value 'drift_detected'
        }
        if (Test-RunStateSignalText -Text $eventText -Keyword 'stale') {
            Add-RunInsightText -List $driftSignals -Value 'stale_state'
        }
        if (Test-RunStateSignalText -Text $eventText -Keyword 'mismatch') {
            Add-RunInsightText -List $driftSignals -Value 'state_mismatch'
        }
        if ($eventText.Contains('approval') -or $eventText.Contains('review_requested') -or $eventText.Contains('question') -or $eventText.Contains('user')) {
            $interventionCount++
        }
    }

    Add-RunInsightText -List $blockedReasons -Value (Get-RunContractField -InputObject $Run.phase_gate -Name 'stop_reason')
    if ([string](Get-RunContractField -InputObject $Run.draft_pr_gate -Name 'state') -eq 'blocked') {
        Add-RunInsightText -List $blockedReasons -Value 'draft_pr_gate_blocked'
    }
    if ([string](Get-RunContractField -InputObject $Run.tdd_gate -Name 'state') -eq 'blocked') {
        Add-RunInsightText -List $blockedReasons -Value 'tdd_gate_blocked'
    }
    if (([string](Get-RunContractField -InputObject $Run.verification_result -Name 'outcome')).ToUpperInvariant() -eq 'FAIL') {
        Add-RunInsightText -List $blockedReasons -Value 'verification_failed'
    }
    if (([string](Get-RunContractField -InputObject $Run.security_verdict -Name 'verdict')).ToUpperInvariant() -eq 'BLOCK') {
        Add-RunInsightText -List $blockedReasons -Value 'security_blocked'
    }

    $contextPressure = ([string](Get-RunContractField -InputObject $Run.verification_evidence -Name 'context_pressure')).ToLowerInvariant()
    $unhealthySessionSize = (
        [int]$Run.pane_count -gt 8 -or
        [int]$Run.changed_file_count -gt 20 -or
        $contextPressure -in @('high', 'critical', 'exhausted')
    )

    if ($retryCount -gt 0) {
        Add-RunInsightText -List $nextImprovements -Value 'reduce retry loop before the next run'
    }
    if ($driftSignals.Count -gt 0) {
        Add-RunInsightText -List $nextImprovements -Value 'refresh session state before continuing'
    }
    if ($interventionCount -gt 0) {
        Add-RunInsightText -List $nextImprovements -Value 'capture operator decisions as reusable guidance'
    }
    if ($unhealthySessionSize) {
        Add-RunInsightText -List $nextImprovements -Value 'split the next run into a smaller scope'
    }
    if ($blockedReasons.Count -gt 0) {
        Add-RunInsightText -List $nextImprovements -Value 'resolve blocked reasons before release'
    }

    return [ordered]@{
        packet_type            = 'run_insights'
        scope                  = 'run'
        retry_count            = $retryCount
        drift_signals          = @($driftSignals)
        intervention_count     = $interventionCount
        unhealthy_session_size = [bool]$unhealthySessionSize
        blocked_reasons        = @($blockedReasons)
        next_improvements      = @($nextImprovements)
    }
}

function Test-RunDriftSignalText {
    param(
        [string]$EventName = '',
        [string]$Text = ''
    )

    $eventNameText = $EventName.ToLowerInvariant()
    $bodyText = $Text.ToLowerInvariant()
    if (
        $bodyText.Contains('no drift') -or
        $bodyText.Contains('without drift') -or
        $bodyText.Contains('drift check passed') -or
        $bodyText.Contains('drift check ok') -or
        $eventNameText.Contains('drift_check.pass') -or
        $eventNameText.Contains('drift.pass')
    ) {
        return $false
    }
    if ($eventNameText.Contains('.drift') -or $eventNameText.Contains('drift.')) {
        return $true
    }

    return (
        $bodyText.Contains('drift detected') -or
        $bodyText.Contains('drift retry') -or
        $bodyText.Contains('drift check failed') -or
        $bodyText.Contains('drifted') -or
        $bodyText.Contains('drifts from') -or
        $bodyText.Contains('worker isolation drift')
    )
}

function Test-RunStateSignalText {
    param(
        [string]$Text = '',
        [Parameter(Mandatory = $true)][string]$Keyword
    )

    $bodyText = $Text.ToLowerInvariant()
    $keywordText = $Keyword.ToLowerInvariant()
    if (
        $bodyText.Contains("no $keywordText") -or
        $bodyText.Contains("without $keywordText") -or
        $bodyText.Contains("$keywordText check passed") -or
        $bodyText.Contains("$keywordText check ok") -or
        $bodyText.Contains("$keywordText resolved")
    ) {
        return $false
    }

    return $bodyText.Contains($keywordText)
}

function New-RunArchitectureContract {
    param([Parameter(Mandatory = $true)]$Run)

    $driftSignals = @(ConvertTo-RunStringArray -Value (Get-RunContractField -InputObject $Run.run_insights -Name 'drift_signals'))
    $driftScore = @($driftSignals).Count
    $maxDriftScore = 0
    $scoreRegression = ($driftScore -gt $maxDriftScore)
    $status = if ($scoreRegression) { 'baseline_mismatch' } else { 'baseline_match' }

    return [ordered]@{
        contract_version = 1
        packet_type      = 'architecture_contract'
        scope            = 'run_architecture_baseline'
        run_id           = [string]$Run.run_id
        task_id          = [string]$Run.task_id
        baseline         = [ordered]@{
            drift_score              = 0
            max_drift_score          = $maxDriftScore
            allowed_drift_signals    = @()
            review_required_on_drift = $true
        }
        current          = [ordered]@{
            drift_score            = $driftScore
            drift_signals          = @($driftSignals)
            retry_count            = [int](Get-RunContractField -InputObject $Run.run_insights -Name 'retry_count')
            intervention_count     = [int](Get-RunContractField -InputObject $Run.run_insights -Name 'intervention_count')
            unhealthy_session_size = [bool](Get-RunContractField -InputObject $Run.run_insights -Name 'unhealthy_session_size')
        }
        score_regression = $scoreRegression
        status           = $status
        storage_policy   = [ordered]@{
            freeform_body_stored         = $false
            private_content_stored       = $false
            local_reference_paths_stored = $false
        }
    }
}

function Get-RunContractField {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function ConvertTo-RunStringArray {
    param([AllowNull()]$Value = $null)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [string]) {
        return @(
            $Value -split '\|' |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @(
            foreach ($item in $Value) {
                $text = [string]$item
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $text
                }
            }
        )
    }

    $textValue = [string]$Value
    if ([string]::IsNullOrWhiteSpace($textValue)) {
        return @()
    }
    return @($textValue)
}

function Add-RunUniqueString {
    param(
        [Parameter(Mandatory = $true)]$List,
        [AllowNull()]$Value = $null
    )

    $text = [string]$Value
    if (-not [string]::IsNullOrWhiteSpace($text) -and -not $List.Contains($text)) {
        $List.Add($text) | Out-Null
    }
}

function Test-RunDurableRef {
    param(
        [AllowNull()]$Value = $null,
        [string[]]$Prefixes = @()
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }
    $text = $text.Trim()
    if (
        $text.Length -gt 256 -or
        $text.Contains("`n") -or
        $text.Contains("`r") -or
        $text.Contains(':/') -or
        $text.Contains('\') -or
        $text.Contains(' ') -or
        $text.StartsWith('%') -or
        $text.StartsWith('~') -or
        $text.StartsWith('/') -or
        ($text.Length -ge 2 -and $text[1] -eq ':')
    ) {
        return $false
    }

    foreach ($prefix in @($Prefixes)) {
        if ($text.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            return $true
        }
    }

    return $false
}

function Add-RunDurableRef {
    param(
        [Parameter(Mandatory = $true)]$List,
        [AllowNull()]$Value = $null,
        [string[]]$Prefixes = @()
    )

    if (Test-RunDurableRef -Value $Value -Prefixes $Prefixes) {
        Add-RunUniqueString -List $List -Value ([string]$Value).Trim()
    }
}

function Add-RunContractRefs {
    param(
        [Parameter(Mandatory = $true)]$List,
        [AllowNull()]$Data = $null,
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Prefixes = @()
    )

    foreach ($item in @(ConvertTo-RunStringArray -Value (Get-RunContractField -InputObject $Data -Name $Name))) {
        Add-RunDurableRef -List $List -Value $item -Prefixes $Prefixes
    }
}

function Get-RunPublicContextRefPrefixes {
    return @(
        'ADR-',
        'AGENT-BASE.md',
        'AGENT.md',
        'GEMINI.md',
        'GUARDRAILS.md',
        'README',
        'docs/',
        'guidance:',
        'context:',
        'context-packs/',
        'knowledge:',
        'knowledge/',
        'evidence:',
        'rationale:'
    )
}

function Get-RunPublicContextPackIdPrefixes {
    return @(
        'ctx-',
        'sem-',
        'context:',
        'context-packs/'
    )
}

function Get-RunContractRefList {
    param(
        [AllowNull()]$Data = $null,
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Prefixes = @()
    )

    $refs = [System.Collections.Generic.List[string]]::new()
    Add-RunContractRefs -List $refs -Data $Data -Name $Name -Prefixes $Prefixes
    return @($refs)
}

function Get-RunDurableRefList {
    param(
        [AllowNull()]$Values = $null,
        [string[]]$Prefixes = @()
    )

    $refs = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(ConvertTo-RunStringArray -Value $Values)) {
        Add-RunDurableRef -List $refs -Value $item -Prefixes $Prefixes
    }
    return @($refs)
}

function New-RunTeamMemoryContract {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [object[]]$EventRecords = @()
    )

    $teamMemoryRefs = [System.Collections.Generic.List[string]]::new()
    $evidenceNoteRefs = [System.Collections.Generic.List[string]]::new()
    $sourceRefs = [System.Collections.Generic.List[string]]::new()
    $mailboxEventCount = 0
    $eventIndex = 0

    foreach ($eventRecord in @($EventRecords)) {
        $eventIndex += 1
        $data = Get-RunContractField -InputObject $eventRecord -Name 'data'
        if ($null -eq $data) {
            $data = [ordered]@{}
        }
        $eventName = [string](Get-RunContractField -InputObject $eventRecord -Name 'event')
        $eventSource = [string](Get-RunContractField -InputObject $eventRecord -Name 'source')
        $dataSource = [string](Get-RunContractField -InputObject $data -Name 'source')
        $isMailboxEvent = (
            $eventSource -eq 'mailbox' -or
            $dataSource -eq 'mailbox' -or
            $eventName.ToLowerInvariant().Contains('mailbox')
        )

        if ($isMailboxEvent) {
            $mailboxEventCount += 1
        }

        $beforeRefCount = $teamMemoryRefs.Count
        Add-RunContractRefs -List $teamMemoryRefs -Data $data -Name 'team_memory_refs' -Prefixes @('team-memory:')
        Add-RunDurableRef -List $teamMemoryRefs -Value (Get-RunContractField -InputObject $data -Name 'team_memory_ref') -Prefixes @('team-memory:')
        Add-RunContractRefs -List $evidenceNoteRefs -Data $data -Name 'evidence_note_refs' -Prefixes @('evidence-note:')
        Add-RunDurableRef -List $evidenceNoteRefs -Value (Get-RunContractField -InputObject $data -Name 'evidence_note_ref') -Prefixes @('evidence-note:')

        if ($isMailboxEvent -and $teamMemoryRefs.Count -eq $beforeRefCount) {
            Add-RunUniqueString -List $teamMemoryRefs -Value ("team-memory:{0}:event-{1}" -f ([string]$Run.run_id), $eventIndex)
        }

        Add-RunDurableRef -List $sourceRefs -Value (Get-RunContractField -InputObject $data -Name 'observation_pack_ref') -Prefixes @('observation:', 'observations/', 'observation-packs/')
        Add-RunDurableRef -List $sourceRefs -Value (Get-RunContractField -InputObject $data -Name 'consultation_ref') -Prefixes @('consultation:', 'consultations/')
        Add-RunDurableRef -List $sourceRefs -Value (Get-RunContractField -InputObject $data -Name 'context_pack_ref') -Prefixes @('context:', 'context-packs/')
        Add-RunDurableRef -List $sourceRefs -Value (Get-RunContractField -InputObject $data -Name 'knowledge_pack_ref') -Prefixes @('knowledge:', 'knowledge/')
    }

    return [ordered]@{
        contract_version             = 1
        packet_type                  = 'team_memory_contract'
        scope                        = 'run'
        run_id                       = [string]$Run.run_id
        task_id                      = [string]$Run.task_id
        team_memory_refs             = @($teamMemoryRefs | Sort-Object -Unique)
        evidence_note_refs           = @($evidenceNoteRefs | Sort-Object -Unique)
        source_refs                  = @($sourceRefs | Sort-Object -Unique)
        mailbox_event_count          = [int]$mailboxEventCount
        freeform_body_stored         = $false
        private_memory_body_stored   = $false
        local_reference_paths_stored = $false
    }
}

function New-RunContextContract {
    param(
        [AllowNull()]$VerificationEvidence = $null,
        [string[]]$TeamMemoryRefs = @()
    )

    $requestedMode = [string](Get-RunContractField -InputObject $VerificationEvidence -Name 'context_mode')
    $forkReason = [string](Get-RunContractField -InputObject $VerificationEvidence -Name 'context_fork_reason')
    $contextMode = 'isolated'
    if ($requestedMode -eq 'fork' -and -not [string]::IsNullOrWhiteSpace($forkReason)) {
        $contextMode = 'fork'
    }

    $safeTeamMemoryRefs = @(Get-RunDurableRefList -Values $TeamMemoryRefs -Prefixes @('team-memory:') | Sort-Object -Unique)

    return [ordered]@{
        contract_version             = 1
        packet_type                  = 'context_budget_contract'
        scope                        = 'run'
        context_pack_id              = Get-RunContractField -InputObject $VerificationEvidence -Name 'context_pack_id'
        context_pack_version         = Get-RunContractField -InputObject $VerificationEvidence -Name 'context_pack_version'
        context_budget               = Get-RunContractField -InputObject $VerificationEvidence -Name 'context_budget'
        context_estimate             = Get-RunContractField -InputObject $VerificationEvidence -Name 'context_estimate'
        context_pressure             = Get-RunContractField -InputObject $VerificationEvidence -Name 'context_pressure'
        tool_output_pruned_count     = Get-RunContractField -InputObject $VerificationEvidence -Name 'tool_output_pruned_count'
        context_mode                 = $contextMode
        fork_reason                  = if ($contextMode -eq 'fork') { $forkReason } else { $null }
        fork_allowed                 = ($contextMode -eq 'fork')
        semantic_context             = [ordered]@{
            context_pack_id           = Get-RunContractField -InputObject $VerificationEvidence -Name 'semantic_context_pack_id'
            context_pack_ref          = Get-RunContractField -InputObject $VerificationEvidence -Name 'semantic_context_pack_ref'
            source_refs               = @(Get-RunContractRefList -Data $VerificationEvidence -Name 'source_refs' -Prefixes (Get-RunPublicContextRefPrefixes))
            hard_constraints          = Get-RunContractField -InputObject $VerificationEvidence -Name 'hard_constraints'
            safety_rules              = Get-RunContractField -InputObject $VerificationEvidence -Name 'safety_rules'
            performance_budget        = Get-RunContractField -InputObject $VerificationEvidence -Name 'performance_budget'
            rationale                 = Get-RunContractField -InputObject $VerificationEvidence -Name 'rationale'
            adr_body_stored           = $false
            persona_prompt_stored     = $false
            private_source_body_stored = $false
        }
        knowledge_layer              = [ordered]@{
            packet_type               = 'knowledge_layer_contract'
            knowledge_pack_id         = Get-RunContractField -InputObject $VerificationEvidence -Name 'knowledge_pack_id'
            knowledge_pack_ref        = Get-RunContractField -InputObject $VerificationEvidence -Name 'knowledge_pack_ref'
            source_refs               = @(Get-RunContractRefList -Data $VerificationEvidence -Name 'knowledge_source_refs' -Prefixes (Get-RunPublicContextRefPrefixes))
            operating_guidance_refs   = @(Get-RunContractRefList -Data $VerificationEvidence -Name 'operating_guidance_refs' -Prefixes (Get-RunPublicContextRefPrefixes))
            hard_constraints          = Get-RunContractField -InputObject $VerificationEvidence -Name 'knowledge_hard_constraints'
            capability_contract       = Get-RunContractField -InputObject $VerificationEvidence -Name 'capability_contract'
            evidence_refs             = @(Get-RunContractRefList -Data $VerificationEvidence -Name 'evidence_refs' -Prefixes (Get-RunPublicContextRefPrefixes))
            rationale_refs            = @(Get-RunContractRefList -Data $VerificationEvidence -Name 'rationale_refs' -Prefixes (Get-RunPublicContextRefPrefixes))
            team_memory_refs          = $safeTeamMemoryRefs
            freeform_body_stored      = $false
            private_guidance_stored   = $false
            local_reference_paths_stored = $false
        }
        prompt_body_stored           = $false
        private_memory_stored        = $false
        local_reference_paths_stored = $false
        tool_output_pruning          = [ordered]@{
            evidence_only          = $true
            raw_tool_output_stored = $false
        }
    }
}

function New-RunDraftPrHandoffPackage {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [string]$DraftPrUrl = ''
    )

    $verificationOutcome = [string](Get-RunContractField -InputObject $Run.verification_result -Name 'outcome')
    $verificationSummary = [string](Get-RunContractField -InputObject $Run.verification_result -Name 'summary')
    $verificationNextAction = [string](Get-RunContractField -InputObject $Run.verification_result -Name 'next_action')
    $securityVerdict = [string](Get-RunContractField -InputObject $Run.security_verdict -Name 'verdict')
    $securityReason = [string](Get-RunContractField -InputObject $Run.security_verdict -Name 'reason')
    $reviewState = [string]$Run.review_state
    $reviewRequired = [bool]$Run.review_required
    $blockedReasons = [System.Collections.Generic.List[string]]::new()
    $remainingRisks = [System.Collections.Generic.List[string]]::new()

    $hasVerificationEvidence = -not [string]::IsNullOrWhiteSpace($verificationOutcome)
    if (-not $hasVerificationEvidence) {
        $blockedReasons.Add('verification evidence is missing') | Out-Null
        $remainingRisks.Add('verification evidence is missing') | Out-Null
    }
    if ($reviewRequired -and $reviewState -notin @('PASS', 'FAIL', 'FAILED')) {
        $blockedReasons.Add("review state is unresolved: $reviewState") | Out-Null
        $remainingRisks.Add("review state is unresolved: $reviewState") | Out-Null
    }
    if ($reviewState -in @('FAIL', 'FAILED')) {
        $blockedReasons.Add("review failed: $reviewState") | Out-Null
        $remainingRisks.Add("review failed: $reviewState") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($verificationOutcome) -and $verificationOutcome -ne 'PASS') {
        $remainingRisks.Add("verification outcome is $verificationOutcome") | Out-Null
    }
    if ($securityVerdict -eq 'BLOCK') {
        $reasonText = if (-not [string]::IsNullOrWhiteSpace($securityReason)) { $securityReason } else { 'security policy blocked the run' }
        $blockedReasons.Add($reasonText) | Out-Null
        $remainingRisks.Add($reasonText) | Out-Null
    }
    $architectureContract = Get-RunContractField -InputObject $Run -Name 'architecture_contract'
    $architectureScoreRegression = [bool](Get-RunContractField -InputObject $architectureContract -Name 'score_regression')
    $architectureBaseline = Get-RunContractField -InputObject $architectureContract -Name 'baseline'
    $architectureReviewRequired = [bool](Get-RunContractField -InputObject $architectureBaseline -Name 'review_required_on_drift')
    if ($architectureScoreRegression -and $architectureReviewRequired -and $reviewState -ne 'PASS') {
        $reasonText = 'architecture baseline mismatch requires review'
        $blockedReasons.Add($reasonText) | Out-Null
        $remainingRisks.Add($reasonText) | Out-Null
    }

    $summary = if (-not [string]::IsNullOrWhiteSpace($verificationSummary)) {
        $verificationSummary
    } elseif ($null -ne $Run.experiment_packet -and -not [string]::IsNullOrWhiteSpace([string]$Run.experiment_packet.result)) {
        [string]$Run.experiment_packet.result
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Run.task)) {
        [string]$Run.task
    } else {
        [string]$Run.goal
    }

    $suggestedNextAction = if (@($blockedReasons).Count -gt 0) {
        'resolve blocked reasons before creating or merging a draft PR'
    } elseif ([string]::IsNullOrWhiteSpace($DraftPrUrl)) {
        'create a draft PR and request human review'
    } else {
        'human reviewer must decide whether to merge'
    }
    if (-not [string]::IsNullOrWhiteSpace($verificationNextAction) -and @($blockedReasons).Count -gt 0) {
        $suggestedNextAction = $verificationNextAction
    }

    return [ordered]@{
        summary                  = $summary
        validation               = [ordered]@{
            evidence_complete  = $hasVerificationEvidence
            outcome            = $verificationOutcome
            summary            = $verificationSummary
            next_action        = $verificationNextAction
            verification_plan  = @($Run.verification_plan)
            changed_files      = @($Run.changed_files)
        }
        remaining_risks          = @($remainingRisks)
        suggested_next_action    = $suggestedNextAction
        blocked_reasons          = @($blockedReasons)
        package_complete         = (@($blockedReasons).Count -eq 0)
        human_judgement_required = $true
        automatic_merge_allowed  = $false
    }
}

function New-RunVerificationEnvelope {
    param([Parameter(Mandatory = $true)]$Run)

    $verificationOutcome = [string](Get-RunContractField -InputObject $Run.verification_result -Name 'outcome')
    $verificationSummary = [string](Get-RunContractField -InputObject $Run.verification_result -Name 'summary')
    $verificationNextAction = [string](Get-RunContractField -InputObject $Run.verification_result -Name 'next_action')
    $reviewState = ([string]$Run.review_state).ToUpperInvariant()
    $securityVerdict = [string](Get-RunContractField -InputObject $Run.security_verdict -Name 'verdict')
    if ([string]::IsNullOrWhiteSpace($securityVerdict) -and $Run.security_verdict -is [string]) {
        $securityVerdict = [string]$Run.security_verdict
    }
    $securityReason = [string](Get-RunContractField -InputObject $Run.security_verdict -Name 'reason')
    $approval = $null
    if ($null -ne $Run.audit_chain -and $null -ne $Run.audit_chain.approval) {
        $approval = $Run.audit_chain.approval
    }
    $approvalState = [string](Get-RunContractField -InputObject $approval -Name 'state')
    $auditChainId = [string](Get-RunContractField -InputObject $Run.audit_chain -Name 'chain_id')
    $auditEventCount = 0
    if ($null -ne $Run.audit_chain -and $null -ne $Run.audit_chain.events) {
        $auditEventCount = @($Run.audit_chain.events).Count
    }
    $draftPrGateState = [string](Get-RunContractField -InputObject $Run.draft_pr_gate -Name 'state')
    $phaseGateStopReason = [string](Get-RunContractField -InputObject $Run.phase_gate -Name 'stop_reason')
    $phaseGateStopStage = [string](Get-RunContractField -InputObject $Run.phase_gate -Name 'stop_stage')
    $architectureContract = Get-RunContractField -InputObject $Run -Name 'architecture_contract'
    $architectureScoreRegression = [bool](Get-RunContractField -InputObject $architectureContract -Name 'score_regression')
    $architectureBaseline = Get-RunContractField -InputObject $architectureContract -Name 'baseline'
    $architectureReviewRequired = [bool](Get-RunContractField -InputObject $architectureBaseline -Name 'review_required_on_drift')

    $evidenceComplete = (
        -not [string]::IsNullOrWhiteSpace($verificationOutcome) -and
        $null -ne $Run.verification_evidence -and
        $null -ne $Run.audit_chain
    )
    $blockedReasons = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($verificationOutcome)) {
        $blockedReasons.Add('verification evidence is missing') | Out-Null
    } elseif ($verificationOutcome -ne 'PASS') {
        $blockedReasons.Add("verification outcome is $verificationOutcome") | Out-Null
    }
    if ($securityVerdict -eq 'BLOCK') {
        if ([string]::IsNullOrWhiteSpace($securityReason)) {
            $blockedReasons.Add('security policy blocked the run') | Out-Null
        } else {
            $blockedReasons.Add($securityReason) | Out-Null
        }
    }
    if ([bool]$Run.review_required -and $approvalState -ne 'approved') {
        $stateText = if (-not [string]::IsNullOrWhiteSpace($approvalState)) { $approvalState } else { [string]$Run.review_state }
        $blockedReasons.Add("approval state is unresolved: $stateText") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($draftPrGateState) -and $draftPrGateState -ne 'passed') {
        $blockedReasons.Add("draft PR gate is $draftPrGateState") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($phaseGateStopReason)) {
        $stageText = if (-not [string]::IsNullOrWhiteSpace($phaseGateStopStage)) { $phaseGateStopStage } else { 'unknown' }
        $blockedReasons.Add("phase gate stopped at ${stageText}: $phaseGateStopReason") | Out-Null
    }
    $architectureReviewMissing = ($architectureScoreRegression -and $architectureReviewRequired -and $reviewState -ne 'PASS')
    if ($architectureReviewMissing) {
        $blockedReasons.Add('architecture baseline mismatch requires review') | Out-Null
    }

    $humanJudgementRequired = (
        [bool]$Run.review_required -or
        (-not [string]::IsNullOrWhiteSpace($draftPrGateState) -and $draftPrGateState -ne 'passed') -or
        $phaseGateStopReason -eq 'needs_user_decision' -or
        $architectureReviewMissing
    )

    $status = if (@($blockedReasons).Count -gt 0) {
        'blocked'
    } elseif ($humanJudgementRequired) {
        'approved'
    } else {
        'ready'
    }

    return [ordered]@{
        contract_version     = 1
        packet_type          = 'verification_envelope'
        scope                = 'release_run'
        run_id               = [string]$Run.run_id
        task_id              = [string]$Run.task_id
        static_gates         = [ordered]@{
            verification_plan = @($Run.verification_plan)
            changed_files     = @($Run.changed_files)
            review_required   = [bool]$Run.review_required
            required_fields   = @('verification_evidence', 'context_contract', 'architecture_contract', 'security_verdict', 'audit_chain', 'draft_pr_gate', 'phase_gate')
        }
        dynamic_gates        = [ordered]@{
            verification = [ordered]@{
                outcome           = $verificationOutcome
                summary           = $verificationSummary
                next_action       = $verificationNextAction
                evidence_complete = $evidenceComplete
            }
            security     = [ordered]@{
                verdict = $securityVerdict
                reason  = $securityReason
                blocked = ($securityVerdict -eq 'BLOCK')
            }
            approval     = $approval
            context      = $Run.context_contract
            architecture = $architectureContract
            draft_pr     = $Run.draft_pr_gate
            phase        = $Run.phase_gate
            audit        = [ordered]@{
                chain_id    = $auditChainId
                event_count = $auditEventCount
                last_event  = [string]$Run.last_event
            }
        }
        release_decision     = [ordered]@{
            status                   = $status
            blocked_reasons          = @($blockedReasons)
            human_judgement_required = $humanJudgementRequired
            automatic_merge_allowed  = $false
        }
        verification_evidence = $Run.verification_evidence
        context_contract      = $Run.context_contract
        architecture_contract = $architectureContract
        security_verdict      = $Run.security_verdict
        audit_chain           = $Run.audit_chain
    }
}

function New-RunDraftPrGate {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [object[]]$EventRecords = @()
    )

    $runHeadSha = [string](Get-RunContractField -InputObject $Run -Name 'head_sha')
    $draftPrEvent = @($EventRecords | Where-Object {
        if ([string]($_['event']) -ne 'operator.draft_pr.created') {
            return $false
        }
        if ([string]::IsNullOrWhiteSpace($runHeadSha)) {
            return $true
        }
        $eventHeadSha = [string]$_['head_sha']
        $eventData = $_['data']
        if ([string]::IsNullOrWhiteSpace($eventHeadSha) -and $null -ne $eventData -and $eventData -is [System.Collections.IDictionary] -and $eventData.Contains('head_sha')) {
            $eventHeadSha = [string]$eventData['head_sha']
        }
        return (-not [string]::IsNullOrWhiteSpace($eventHeadSha) -and $eventHeadSha -eq $runHeadSha)
    } | Sort-Object @{ Expression = { Get-RunEventTimestampSortKey -Value $_['timestamp'] }; Descending = $true }, @{ Expression = { [int]($_['line_number']) }; Descending = $true } | Select-Object -First 1)
    $state = 'required'
    $trigger = 'review_state'
    $draftPrUrl = ''
    if (@($draftPrEvent).Count -gt 0) {
        $trigger = 'operator.draft_pr.created'
        $data = $draftPrEvent[0]['data']
        if ($null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('draft_pr_url')) {
            $draftPrUrl = [string]$data['draft_pr_url']
        }
    }

    $handoffPackage = New-RunDraftPrHandoffPackage -Run $Run -DraftPrUrl $draftPrUrl
    if (@($handoffPackage.blocked_reasons).Count -gt 0) {
        $state = 'blocked'
    } elseif (@($draftPrEvent).Count -gt 0) {
        $state = 'passed'
    }

    return [ordered]@{
        kind                 = 'human_judgement'
        target               = 'draft_pr'
        state                = $state
        trigger              = $trigger
        draft_pr_url         = $draftPrUrl
        auto_merge_allowed   = $false
        merge_requires_human = $true
        handoff_package      = $handoffPackage
    }
}

function ConvertTo-RunPublicWorktreeRef {
    param([string]$Worktree = '')

    $normalized = ([string]$Worktree).Trim().Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ''
    }

    if ($normalized.StartsWith('.worktrees/') -or $normalized.StartsWith('worktrees/')) {
        return $normalized
    }

    if ($normalized -match '^[A-Za-z]:' -or $normalized.StartsWith('/') -or $normalized.StartsWith('~')) {
        $markerIndex = $normalized.LastIndexOf('/.worktrees/')
        if ($markerIndex -ge 0) {
            return $normalized.Substring($markerIndex + 1)
        }

        return ''
    }

    return $normalized
}

function ConvertTo-RunPublicChangedFiles {
    param([AllowNull()]$ChangedFiles = $null)

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @(ConvertTo-RunStringArray -Value $ChangedFiles)) {
        $normalized = ([string]$entry).Trim().Replace('\', '/')
        if (
            [string]::IsNullOrWhiteSpace($normalized) -or
            $normalized -match '^[A-Za-z]:' -or
            $normalized.StartsWith('/') -or
            $normalized.StartsWith('~') -or
            $normalized.StartsWith('..') -or
            $normalized.Contains('/../')
        ) {
            continue
        }

        if (-not $items.Contains($normalized)) {
            $items.Add($normalized) | Out-Null
        }
    }

    return @($items)
}

function New-RunCheckpointPackage {
    param([Parameter(Mandatory = $true)]$Run)

    $rawWorktree = [string]$Run.worktree
    if ([string]::IsNullOrWhiteSpace($rawWorktree) -and $null -ne $Run.experiment_packet) {
        $rawWorktree = [string](Get-RunContractField -InputObject $Run.experiment_packet -Name 'worktree')
    }
    $worktreeRef = ConvertTo-RunPublicWorktreeRef -Worktree $rawWorktree
    $sessionType = 'unknown'
    if ($worktreeRef.StartsWith('.worktrees/')) {
        $sessionType = 'managed_worktree'
    } elseif (-not [string]::IsNullOrWhiteSpace($worktreeRef)) {
        $sessionType = 'shared_checkout'
    }

    $verificationOutcome = [string](Get-RunContractField -InputObject $Run.verification_result -Name 'outcome')
    $changedFiles = @(ConvertTo-RunPublicChangedFiles -ChangedFiles $Run.changed_files)
    $contextPackId = [string](Get-RunContractField -InputObject $Run.context_contract -Name 'context_pack_id')
    $semanticContext = Get-RunContractField -InputObject $Run.context_contract -Name 'semantic_context'
    $semanticContextPackId = [string](Get-RunContractField -InputObject $semanticContext -Name 'context_pack_id')
    $contextPackIdPrefixes = Get-RunPublicContextPackIdPrefixes
    $safeContextPackId = if (Test-RunDurableRef -Value $contextPackId -Prefixes $contextPackIdPrefixes) { $contextPackId.Trim() } else { $null }
    $safeSemanticContextPackId = if (Test-RunDurableRef -Value $semanticContextPackId -Prefixes $contextPackIdPrefixes) { $semanticContextPackId.Trim() } else { $null }
    $cleanupRequired = (
        [string]$Run.task_state -in @('completed', 'task_completed', 'commit_ready', 'done') -or
        [string]$Run.review_state -eq 'PASS'
    )

    return [ordered]@{
        contract_version             = 1
        packet_type                  = 'checkpoint_package'
        scope                        = 'worker_worktree'
        run_id                       = [string]$Run.run_id
        task_id                      = [string]$Run.task_id
        project_ref                  = 'current_project'
        project_root_stored          = $false
        assigned_worktree            = $worktreeRef
        branch                       = [string]$Run.branch
        head_sha                     = [string]$Run.head_sha
        session_type                 = $sessionType
        changed_files                = @($changedFiles)
        changed_file_count           = @($changedFiles).Count
        verification                 = [ordered]@{
            outcome           = $verificationOutcome
            verification_plan = @($Run.verification_plan)
            evidence_complete = (-not [string]::IsNullOrWhiteSpace($verificationOutcome))
        }
        end_of_run_snapshot          = [ordered]@{
            contract_version = 1
            packet_type      = 'end_of_run_snapshot_manifest'
            status           = 'partial'
            capture_policy   = [ordered]@{
                snapshot_failure_does_not_fail_worker = $true
                raw_terminal_transcript_stored        = $false
                untracked_file_names_stored           = $false
                private_content_stored                = $false
                local_reference_paths_stored          = $false
            }
            repo_diff        = [ordered]@{
                changed_files      = @($changedFiles)
                changed_file_count = @($changedFiles).Count
                untracked_files    = [ordered]@{
                    state             = 'not_captured'
                    count_bucket      = 'unknown'
                    file_names_stored = $false
                }
            }
            terminal         = [ordered]@{
                state                = 'not_captured'
                summary_ref          = $null
                raw_transcript_stored = $false
            }
            artifacts        = [ordered]@{
                artifact_refs = @()
                summary_refs  = @()
            }
            context          = [ordered]@{
                context_pack_id          = $safeContextPackId
                semantic_context_pack_id = $safeSemanticContextPackId
            }
            hydration        = [ordered]@{
                project_ref       = 'current_project'
                assigned_worktree = $worktreeRef
                session_type      = $sessionType
                branch            = [string]$Run.branch
                head_sha          = [string]$Run.head_sha
            }
        }
        rollback_hint                = 'operator-owned-git-lifecycle'
        cleanup_hint                 = if ($cleanupRequired) { 'operator may clean the worker worktree after merge or explicit close' } else { 'keep the worker worktree for inspection' }
        operator_git_required        = $true
        worker_git_write_allowed     = $false
        local_reference_paths_stored = $false
        freeform_body_stored         = $false
        private_content_stored       = $false
    }
}

function New-RunChildLaunchContract {
    param([Parameter(Mandatory = $true)]$Run)

    $rawWorktree = [string]$Run.worktree
    if ([string]::IsNullOrWhiteSpace($rawWorktree) -and $null -ne $Run.experiment_packet) {
        $rawWorktree = [string](Get-RunContractField -InputObject $Run.experiment_packet -Name 'worktree')
    }
    $worktreeRef = ConvertTo-RunPublicWorktreeRef -Worktree $rawWorktree
    $sessionType = 'unknown'
    if ($worktreeRef.StartsWith('.worktrees/')) {
        $sessionType = 'managed_worktree'
    } elseif (-not [string]::IsNullOrWhiteSpace($worktreeRef)) {
        $sessionType = 'shared_checkout'
    }

    $providerTarget = [string]$Run.provider_target
    $agentKind = 'unknown'
    if (-not [string]::IsNullOrWhiteSpace($providerTarget)) {
        $agentKind = $providerTarget.Trim().Split(':')[0].Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($agentKind)) {
            $agentKind = 'unknown'
        }
    }

    $role = [string]$Run.primary_role
    if ([string]::IsNullOrWhiteSpace($role)) {
        $role = [string]$Run.agent_role
    }
    $roleIntent = [string]$Run.agent_role
    if ([string]::IsNullOrWhiteSpace($roleIntent)) {
        $roleIntent = $role
    }

    return [ordered]@{
        contract_version             = 1
        packet_type                  = 'child_launch_contract'
        scope                        = 'operator_managed_child_run'
        run_id                       = [string]$Run.run_id
        task_id                      = [string]$Run.task_id
        parent_run_id                = [string]$Run.parent_run_id
        role                         = $role
        role_intent                  = $roleIntent
        agent_kind                   = $agentKind
        provider_target              = $providerTarget
        project_ref                  = 'current_project'
        project_root_stored          = $false
        worktree                     = $worktreeRef
        launch_dir                   = $worktreeRef
        session_type                 = $sessionType
        structured_handoff           = [ordered]@{
            packet_type                  = 'structured_handoff_contract'
            mode                         = 'plan_document_pipe'
            plan_ref                     = 'plan.md'
            plan_body_stored             = $false
            source_role                  = 'operator'
            target_role                  = $role
            target_role_intent           = $roleIntent
            target_agent_kind            = $agentKind
            review_role                  = 'Reviewer'
            independent_verification     = $true
            freeform_prompt_body_stored  = $false
            local_reference_paths_stored = $false
        }
        startup_command_ref          = 'managed-pane-launch'
        startup_command_stored       = $false
        operator_controls_merge      = $true
        peer_to_peer_allowed         = $false
        child_git_write_allowed      = $false
        local_reference_paths_stored = $false
        freeform_command_stored      = $false
        private_content_stored       = $false
    }
}

function New-RunPacketFromRun {
    param([Parameter(Mandatory = $true)]$Run)

    $architectureContract = Get-RunContractField -InputObject $Run -Name 'architecture_contract'

    return [ordered]@{
        run_id            = [string]$Run.run_id
        task_id           = [string]$Run.task_id
        parent_run_id     = [string]$Run.parent_run_id
        goal              = [string]$Run.goal
        task              = [string]$Run.task
        task_type         = [string]$Run.task_type
        priority          = [string]$Run.priority
        blocking          = [bool]$Run.blocking
        phase             = [string]$Run.phase
        activity          = [string]$Run.activity
        detail            = [string]$Run.detail
        write_scope       = @($Run.write_scope)
        read_scope        = @($Run.read_scope)
        constraints       = @($Run.constraints)
        expected_output   = [string]$Run.expected_output
        verification_plan = @($Run.verification_plan)
        review_required   = [bool]$Run.review_required
        provider_target   = [string]$Run.provider_target
        agent_role        = if (-not [string]::IsNullOrWhiteSpace([string]$Run.agent_role)) { [string]$Run.agent_role } else { [string]$Run.primary_role }
        timeout_policy    = [string]$Run.timeout_policy
        handoff_refs      = @($Run.handoff_refs)
        branch            = [string]$Run.branch
        head_sha          = [string]$Run.head_sha
        primary_label     = [string]$Run.primary_label
        primary_pane_id   = [string]$Run.primary_pane_id
        primary_role      = [string]$Run.primary_role
        labels            = @($Run.labels)
        pane_ids          = @($Run.pane_ids)
        roles             = @($Run.roles)
        changed_files     = @($Run.changed_files)
        security_policy   = $Run.security_policy
        security_verdict  = $Run.security_verdict
        verification_contract = $Run.verification_contract
        verification_result   = $Run.verification_result
        verification_evidence = $Run.verification_evidence
        context_contract      = $Run.context_contract
        team_memory           = $Run.team_memory
        run_insights          = $Run.run_insights
        architecture_contract = $architectureContract
        child_launch_contract = $Run.child_launch_contract
        checkpoint_package    = $Run.checkpoint_package
        tdd_gate              = $Run.tdd_gate
        verification_envelope = $Run.verification_envelope
        plan              = $Run.plan
        plan_checkpoints  = @($Run.plan_checkpoints)
        managed_loop      = $Run.managed_loop
        audit_chain       = $Run.audit_chain
        outcome           = $Run.outcome
        phase_gate        = $Run.phase_gate
        draft_pr_gate     = $Run.draft_pr_gate
        last_event        = [string]$Run.last_event
        last_event_at     = [string]$Run.last_event_at
    }
}

function New-RunResultPacket {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$EvidenceDigest,
        [AllowNull()]$ReviewState = $null,
        [Parameter(Mandatory = $true)][object[]]$RecentEvents,
        [AllowNull()]$ObservationPack = $null,
        [AllowNull()]$ConsultationPacket = $null
    )

    $status = ''
    if ([string]$Run.review_state -in @('FAIL', 'FAILED')) {
        $status = 'failed'
    } elseif ([string]$Run.review_state -eq 'PASS' -or [string]$Run.task_state -eq 'done') {
        $status = 'completed'
    } elseif ([string]$Run.task_state -eq 'blocked') {
        $status = 'blocked'
    } elseif ([string]$Run.task_state -eq 'in_progress') {
        $status = 'in_progress'
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Run.task_state)) {
        $status = [string]$Run.task_state
    }

    $summary = if (-not [string]::IsNullOrWhiteSpace([string]$EvidenceDigest.last_event)) {
        [string]$EvidenceDigest.last_event
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Run.task)) {
        [string]$Run.task
    } else {
        [string]$Run.primary_label
    }

    $reviewRecommendation = ''
    if ($ReviewState -is [System.Collections.IDictionary] -and $ReviewState.Contains('status')) {
        $reviewRecommendation = [string]$ReviewState['status']
    } elseif ([string]$Run.review_state -in @('FAIL', 'FAILED', 'PENDING', 'PASS')) {
        $reviewRecommendation = [string]$Run.review_state
    }

    $reviewContract = $null
    if ($ReviewState -is [System.Collections.IDictionary] -and $ReviewState.Contains('request')) {
        $reviewRequest = $ReviewState['request']
        if ($reviewRequest -is [System.Collections.IDictionary] -and $reviewRequest.Contains('review_contract')) {
            $reviewContract = $reviewRequest['review_contract']
        }
    }

    $architectureContract = Get-RunContractField -InputObject $Run -Name 'architecture_contract'

    return [ordered]@{
        run_id                = [string]$Run.run_id
        status                = $status
        summary               = $summary
        phase                 = [string]$Run.phase
        activity              = [string]$Run.activity
        detail                = [string]$Run.detail
        artifacts             = @()
        changed_files         = @($EvidenceDigest.changed_files)
        head_sha              = [string]$EvidenceDigest.head_sha
        branch                = [string]$EvidenceDigest.branch
        next_action_hint      = [string]$EvidenceDigest.next_action
        review_recommendation = $reviewRecommendation
        evidence_refs         = @($EvidenceDigest.changed_files)
        experiment_packet     = $Run.experiment_packet
        observation_pack      = $ObservationPack
        consultation_packet   = $ConsultationPacket
        action_items          = @($Run.action_items)
        review_state          = $ReviewState
        review_contract       = $reviewContract
        verification_contract = $Run.verification_contract
        verification_result   = $Run.verification_result
        verification_evidence = $Run.verification_evidence
        context_contract      = $Run.context_contract
        team_memory           = $Run.team_memory
        run_insights          = $Run.run_insights
        architecture_contract = $architectureContract
        checkpoint_package    = $Run.checkpoint_package
        tdd_gate              = $Run.tdd_gate
        verification_envelope = $Run.verification_envelope
        security_policy       = $Run.security_policy
        security_verdict      = $Run.security_verdict
        plan                  = $Run.plan
        plan_checkpoints      = @($Run.plan_checkpoints)
        audit_chain           = $Run.audit_chain
        outcome               = $Run.outcome
        phase_gate            = $Run.phase_gate
        draft_pr_gate         = $Run.draft_pr_gate
        recent_events         = @($RecentEvents)
    }
}

function Test-RunMatchesEventRecord {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$EventRecord
    )

    $runId = [string]$Run.run_id
    $runTaskId = [string]$Run.task_id
    $runBranch = [string]$Run.branch
    $runHeadSha = [string]$Run.head_sha
    $runLabels = @($Run.labels)
    $runPaneIds = @($Run.pane_ids)

    $eventRunId = ''
    $eventTaskId = ''
    $eventBranch = [string]$EventRecord['branch']
    $eventHeadSha = [string]$EventRecord['head_sha']
    $eventLabel = [string]$EventRecord['label']
    $eventPaneId = [string]$EventRecord['pane_id']

    $data = $null
    if ($EventRecord.Contains('run_id')) { $eventRunId = [string]$EventRecord['run_id'] }
    if ($EventRecord.Contains('task_id')) { $eventTaskId = [string]$EventRecord['task_id'] }
    if ($EventRecord.Contains('data')) {
        $data = $EventRecord['data']
    }

    if ($null -ne $data -and $data -is [System.Collections.IDictionary]) {
        if ($data.Contains('run_id')) { $eventRunId = [string]$data['run_id'] }
        if ($data.Contains('task_id')) { $eventTaskId = [string]$data['task_id'] }
        if ([string]::IsNullOrWhiteSpace($eventBranch) -and $data.Contains('branch')) { $eventBranch = [string]$data['branch'] }
        if ([string]::IsNullOrWhiteSpace($eventHeadSha) -and $data.Contains('head_sha')) { $eventHeadSha = [string]$data['head_sha'] }
    }

    if (-not [string]::IsNullOrWhiteSpace($eventRunId)) {
        return (-not [string]::IsNullOrWhiteSpace($runId) -and $runId -eq $eventRunId)
    }

    if (-not [string]::IsNullOrWhiteSpace($eventTaskId)) {
        return (-not [string]::IsNullOrWhiteSpace($runTaskId) -and $runTaskId -eq $eventTaskId)
    }

    if (-not [string]::IsNullOrWhiteSpace($eventPaneId) -and $runPaneIds -contains $eventPaneId) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($eventLabel) -and $runLabels -contains $eventLabel) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($runBranch) -and -not [string]::IsNullOrWhiteSpace($eventBranch) -and $runBranch -eq $eventBranch) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($runHeadSha) -and -not [string]::IsNullOrWhiteSpace($eventHeadSha) -and $runHeadSha -eq $eventHeadSha) {
        return $true
    }

    return $false
}

function Test-RunMatchesExperimentEventRecord {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$EventRecord
    )

    $runId = [string]$Run.run_id
    $runTaskId = [string]$Run.task_id
    $runBranch = [string]$Run.branch
    $runHeadSha = [string]$Run.head_sha
    $runLabels = @($Run.labels)
    $runPaneIds = @($Run.pane_ids)

    $eventTaskId = ''
    $eventBranch = [string]$EventRecord['branch']
    $eventHeadSha = [string]$EventRecord['head_sha']
    $eventLabel = [string]$EventRecord['label']
    $eventPaneId = [string]$EventRecord['pane_id']
    $eventRunId = ''

    $data = $null
    if ($EventRecord.Contains('data')) {
        $data = $EventRecord['data']
    }

    if ($null -ne $data -and $data -is [System.Collections.IDictionary]) {
        if ($data.Contains('task_id')) { $eventTaskId = [string]$data['task_id'] }
        if ($data.Contains('run_id')) { $eventRunId = [string]$data['run_id'] }
        if ([string]::IsNullOrWhiteSpace($eventBranch) -and $data.Contains('branch')) { $eventBranch = [string]$data['branch'] }
        if ([string]::IsNullOrWhiteSpace($eventHeadSha) -and $data.Contains('head_sha')) { $eventHeadSha = [string]$data['head_sha'] }
    }

    if (-not [string]::IsNullOrWhiteSpace($eventRunId)) {
        return ($eventRunId -eq $runId)
    }

    if (-not [string]::IsNullOrWhiteSpace($eventTaskId) -and -not [string]::IsNullOrWhiteSpace($runTaskId)) {
        return ($eventTaskId -eq $runTaskId)
    }

    if (-not [string]::IsNullOrWhiteSpace($eventPaneId)) {
        return ($runPaneIds -contains $eventPaneId)
    }

    if (-not [string]::IsNullOrWhiteSpace($eventLabel)) {
        return ($runLabels -contains $eventLabel)
    }

    if (-not [string]::IsNullOrWhiteSpace($eventTaskId) -or -not [string]::IsNullOrWhiteSpace($runTaskId)) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($runBranch) -and $runBranch -eq $eventBranch) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($runHeadSha) -and $runHeadSha -eq $eventHeadSha) {
        return $true
    }

    return $false
}

function ConvertTo-RunEventRecord {
    param(
        [Parameter(Mandatory = $true)]$EventRecord,
        [string]$ProjectDir = (Get-Location).Path
    )

    $taskId = ''
    $branch = [string]$EventRecord['branch']
    $headSha = [string]$EventRecord['head_sha']
    $data = $null
    if ($EventRecord.Contains('data')) {
        $data = $EventRecord['data']
    }

    if ($null -ne $data -and $data -is [System.Collections.IDictionary]) {
        if ($data.Contains('task_id')) { $taskId = [string]$data['task_id'] }
        if ([string]::IsNullOrWhiteSpace($branch) -and $data.Contains('branch')) { $branch = [string]$data['branch'] }
        if ([string]::IsNullOrWhiteSpace($headSha) -and $data.Contains('head_sha')) { $headSha = [string]$data['head_sha'] }
    }

    $experimentPacket = Get-ExperimentPacketFromEventRecords -EventRecords @($EventRecord)
    $runId = if ($null -ne $experimentPacket) { [string]$experimentPacket.run_id } else { '' }
    $observationPack = Get-HydratedObservationPack -ExperimentPacket $experimentPacket -ProjectDir $ProjectDir -ExpectedRunId $runId
    $consultationPacket = Get-HydratedConsultationPacket -ExperimentPacket $experimentPacket -ProjectDir $ProjectDir -ExpectedRunId $runId

    return [ordered]@{
        line_number          = [int]$EventRecord['line_number']
        timestamp            = [string]$EventRecord['timestamp']
        event                = [string]$EventRecord['event']
        status               = [string]$EventRecord['status']
        message              = [string]$EventRecord['message']
        label                = [string]$EventRecord['label']
        pane_id              = [string]$EventRecord['pane_id']
        role                 = [string]$EventRecord['role']
        task_id              = $taskId
        branch               = $branch
        head_sha             = $headSha
        source               = [string]$EventRecord['source']
        hypothesis           = if ($null -ne $experimentPacket) { [string]$experimentPacket.hypothesis } else { '' }
        test_plan            = if ($null -ne $experimentPacket) { @($experimentPacket.test_plan) } else { @() }
        result               = if ($null -ne $experimentPacket) { [string]$experimentPacket.result } else { '' }
        confidence           = if ($null -ne $experimentPacket) { $experimentPacket.confidence } else { $null }
        next_action          = if ($null -ne $experimentPacket) { [string]$experimentPacket.next_action } else { '' }
        observation_pack_ref = if ($null -ne $experimentPacket) { [string]$experimentPacket.observation_pack_ref } else { '' }
        consultation_ref     = if ($null -ne $experimentPacket) { [string]$experimentPacket.consultation_ref } else { '' }
        run_id               = if ($null -ne $experimentPacket) { [string]$experimentPacket.run_id } else { '' }
        slot                 = if ($null -ne $experimentPacket) { [string]$experimentPacket.slot } else { '' }
        worktree             = if ($null -ne $experimentPacket) { [string]$experimentPacket.worktree } else { '' }
        env_fingerprint      = if ($null -ne $experimentPacket) { [string]$experimentPacket.env_fingerprint } else { '' }
        command_hash         = if ($null -ne $experimentPacket) { [string]$experimentPacket.command_hash } else { '' }
        observation_pack     = $observationPack
        consultation_packet  = $consultationPacket
        verification_contract = if ($null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('verification_contract')) { $data['verification_contract'] } else { $null }
        verification_result   = if ($null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('verification_result')) { $data['verification_result'] } else { $null }
        security_verdict      = if (($EventRecord['event'] -in @('pipeline.security.blocked', 'security.policy.blocked', 'pipeline.security.allowed', 'security.policy.allowed')) -and $null -ne $data -and $data -is [System.Collections.IDictionary]) {
            [ordered]@{
                stage         = if ($data.Contains('stage')) { [string]$data['stage'] } else { '' }
                attempt       = if ($data.Contains('attempt')) { $data['attempt'] } else { $null }
                task          = if ($data.Contains('task')) { [string]$data['task'] } else { '' }
                verdict       = if ($data.Contains('verdict')) { [string]$data['verdict'] } else { '' }
                reason        = if ($data.Contains('reason')) { [string]$data['reason'] } else { '' }
                advisory_mode = if ($data.Contains('advisory_mode')) { [bool]$data['advisory_mode'] } else { $false }
                allow         = if ($data.Contains('allow')) { @($data['allow']) } else { @() }
                block         = if ($data.Contains('block')) { @($data['block']) } else { @() }
                next_action   = if ($data.Contains('next_action')) { [string]$data['next_action'] } else { '' }
            }
        } else { $null }
    }
}

function Get-RunsPayload {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $boardPayload = Get-BoardPayload -ProjectDir $ProjectDir
    $inboxPayload = Get-InboxPayload -ProjectDir $ProjectDir
    $eventRecords = @(Get-BridgeEventRecords -ProjectDir $ProjectDir)
    $runsById = [ordered]@{}

    foreach ($pane in @($boardPayload.panes)) {
        Assert-ManifestBackedRunShape -PaneRecord $pane
        $runId = Get-RunIdFromPaneRecord -PaneRecord $pane
        if (-not $runsById.Contains($runId)) {
            $runsById[$runId] = [ordered]@{
                run_id             = $runId
                task_id            = [string]$pane.task_id
                task               = [string]$pane.task
                task_state         = [string]$pane.task_state
                review_state       = [string]$pane.review_state
                branch             = [string]$pane.branch
                worktree           = [string]$pane.worktree
                head_sha           = [string]$pane.head_sha
                primary_label      = [string]$pane.label
                primary_pane_id    = [string]$pane.pane_id
                primary_role       = [string]$pane.role
                state              = [string]$pane.state
                tokens_remaining   = [string]$pane.tokens_remaining
                last_event         = [string]$pane.last_event
                last_event_at      = [string]$pane.last_event_at
                pane_count         = 0
                changed_file_count = 0
                labels             = [System.Collections.Generic.List[string]]::new()
                pane_ids           = [System.Collections.Generic.List[string]]::new()
                roles              = [System.Collections.Generic.List[string]]::new()
                changed_files      = [System.Collections.Generic.List[string]]::new()
                action_items       = [System.Collections.Generic.List[object]]::new()
                parent_run_id      = [string]$pane.parent_run_id
                goal               = [string]$pane.goal
                task_type          = [string]$pane.task_type
                priority           = [string]$pane.priority
                blocking           = [bool]$pane.blocking
                write_scope        = [System.Collections.Generic.List[string]]::new()
                read_scope         = [System.Collections.Generic.List[string]]::new()
                constraints        = [System.Collections.Generic.List[string]]::new()
                expected_output    = [string]$pane.expected_output
                verification_plan  = [System.Collections.Generic.List[string]]::new()
                review_required    = [bool]$pane.review_required
                provider_target    = [string]$pane.provider_target
                agent_role         = [string]$pane.agent_role
                timeout_policy     = [string]$pane.timeout_policy
                handoff_refs       = [System.Collections.Generic.List[string]]::new()
                experiment_packet  = $null
                security_policy    = $pane.security_policy
                security_verdict   = $null
                verification_contract = $null
                verification_result   = $null
                verification_evidence = $null
                context_contract      = $null
                team_memory           = $null
                run_insights          = $null
                architecture_contract = $null
                child_launch_contract = $null
                checkpoint_package    = $null
                plan                  = $null
                plan_checkpoints      = @()
                managed_loop          = $null
                audit_chain           = $null
                outcome               = $null
                draft_pr_gate         = $null
                tdd_gate              = $null
                verification_envelope = $null
            }
        }

        $run = $runsById[$runId]
        $run.pane_count = [int]$run.pane_count + 1
        $run.changed_file_count = [int]$run.changed_file_count + [int]$pane.changed_file_count

        if ([string]::IsNullOrWhiteSpace([string]$run.parent_run_id) -and -not [string]::IsNullOrWhiteSpace([string]$pane.parent_run_id)) {
            $run.parent_run_id = [string]$pane.parent_run_id
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.goal) -and -not [string]::IsNullOrWhiteSpace([string]$pane.goal)) {
            $run.goal = [string]$pane.goal
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.task_type) -and -not [string]::IsNullOrWhiteSpace([string]$pane.task_type)) {
            $run.task_type = [string]$pane.task_type
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.priority) -and -not [string]::IsNullOrWhiteSpace([string]$pane.priority)) {
            $run.priority = [string]$pane.priority
        }
        if (-not [bool]$run.blocking -and [bool]$pane.blocking) {
            $run.blocking = $true
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.expected_output) -and -not [string]::IsNullOrWhiteSpace([string]$pane.expected_output)) {
            $run.expected_output = [string]$pane.expected_output
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.worktree) -and -not [string]::IsNullOrWhiteSpace([string]$pane.worktree)) {
            $run.worktree = [string]$pane.worktree
        }
        if (-not [bool]$run.review_required -and [bool]$pane.review_required) {
            $run.review_required = $true
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.provider_target) -and -not [string]::IsNullOrWhiteSpace([string]$pane.provider_target)) {
            $run.provider_target = [string]$pane.provider_target
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.agent_role) -and -not [string]::IsNullOrWhiteSpace([string]$pane.agent_role)) {
            $run.agent_role = [string]$pane.agent_role
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.timeout_policy) -and -not [string]::IsNullOrWhiteSpace([string]$pane.timeout_policy)) {
            $run.timeout_policy = [string]$pane.timeout_policy
        }
        if ($null -eq $run.security_policy -and $null -ne $pane.security_policy) {
            $run.security_policy = $pane.security_policy
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$pane.label) -and -not $run.labels.Contains([string]$pane.label)) {
            $run.labels.Add([string]$pane.label) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$pane.pane_id) -and -not $run.pane_ids.Contains([string]$pane.pane_id)) {
            $run.pane_ids.Add([string]$pane.pane_id) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$pane.role) -and -not $run.roles.Contains([string]$pane.role)) {
            $run.roles.Add([string]$pane.role) | Out-Null
        }

        foreach ($changedFile in @($pane.changed_files)) {
            $changedFileText = [string]$changedFile
            if (-not [string]::IsNullOrWhiteSpace($changedFileText) -and -not $run.changed_files.Contains($changedFileText)) {
                $run.changed_files.Add($changedFileText) | Out-Null
            }
        }
        foreach ($writeScopePath in @($pane.write_scope)) {
            $writeScopeText = [string]$writeScopePath
            if (-not [string]::IsNullOrWhiteSpace($writeScopeText) -and -not $run.write_scope.Contains($writeScopeText)) {
                $run.write_scope.Add($writeScopeText) | Out-Null
            }
        }
        foreach ($readScopePath in @($pane.read_scope)) {
            $readScopeText = [string]$readScopePath
            if (-not [string]::IsNullOrWhiteSpace($readScopeText) -and -not $run.read_scope.Contains($readScopeText)) {
                $run.read_scope.Add($readScopeText) | Out-Null
            }
        }
        foreach ($constraint in @($pane.constraints)) {
            $constraintText = [string]$constraint
            if (-not [string]::IsNullOrWhiteSpace($constraintText) -and -not $run.constraints.Contains($constraintText)) {
                $run.constraints.Add($constraintText) | Out-Null
            }
        }
        foreach ($verificationStep in @($pane.verification_plan)) {
            $verificationText = [string]$verificationStep
            if (-not [string]::IsNullOrWhiteSpace($verificationText) -and -not $run.verification_plan.Contains($verificationText)) {
                $run.verification_plan.Add($verificationText) | Out-Null
            }
        }
        foreach ($handoffRef in @($pane.handoff_refs)) {
            $handoffRefText = [string]$handoffRef
            if (-not [string]::IsNullOrWhiteSpace($handoffRefText) -and -not $run.handoff_refs.Contains($handoffRefText)) {
                $run.handoff_refs.Add($handoffRefText) | Out-Null
            }
        }
    }

    foreach ($item in @($inboxPayload.items)) {
        foreach ($runId in @($runsById.Keys)) {
            $run = $runsById[$runId]
            if (
                ((-not [string]::IsNullOrWhiteSpace([string]$item.task_id)) -and ([string]$item.task_id -eq [string]$run.task_id)) -or
                ((-not [string]::IsNullOrWhiteSpace([string]$item.branch)) -and ([string]$item.branch -eq [string]$run.branch)) -or
                ((-not [string]::IsNullOrWhiteSpace([string]$item.head_sha)) -and ([string]$item.head_sha -eq [string]$run.head_sha)) -or
                ((-not [string]::IsNullOrWhiteSpace([string]$item.label)) -and ($run.labels -contains [string]$item.label)) -or
                ((-not [string]::IsNullOrWhiteSpace([string]$item.pane_id)) -and ($run.pane_ids -contains [string]$item.pane_id))
            ) {
                $run.action_items.Add([ordered]@{
                    kind      = [string]$item.kind
                    message   = [string]$item.message
                    event     = [string]$item.event
                    timestamp = [string]$item.timestamp
                    source    = [string]$item.source
                }) | Out-Null
                break
            }
        }
    }

    foreach ($runId in @($runsById.Keys)) {
        $run = $runsById[$runId]
        $matchingEvents = @(
            foreach ($eventRecord in $eventRecords) {
                if (Test-RunMatchesExperimentEventRecord -Run $run -EventRecord $eventRecord) {
                    $eventRecord
                }
            }
        )

        if (@($matchingEvents).Count -gt 0) {
            $experimentPacket = Get-ExperimentPacketFromEventRecords -EventRecords $matchingEvents
            if (
                $null -ne $experimentPacket -and
                -not [string]::IsNullOrWhiteSpace([string]$experimentPacket.run_id) -and
                [string]$experimentPacket.run_id -ne [string]$run.run_id
            ) {
                $experimentPacket = $null
            }

            $run.experiment_packet = $experimentPacket
            $verificationSnapshot = Get-VerificationSnapshotFromEventRecords -EventRecords $matchingEvents
            if ($null -ne $verificationSnapshot) {
                $run.verification_contract = $verificationSnapshot.verification_contract
                $run.verification_result = $verificationSnapshot.verification_result
                $run.verification_evidence = $verificationSnapshot.verification_evidence
            }

            $securityVerdict = Get-SecurityVerdictFromEventRecords -EventRecords $matchingEvents
            if ($null -ne $securityVerdict) {
                $run.security_verdict = $securityVerdict
            }
            $run.plan_checkpoints = @(Get-RunPlanCheckpointsFromEventRecords -EventRecords $matchingEvents)
            $run.managed_loop = Get-ManagedLoopContractFromEventRecords -EventRecords $matchingEvents
            $run.audit_chain = New-RunAuditChainContract -Run $run -EventRecords $matchingEvents
        }
    }

    $runs = @(
        foreach ($runId in @($runsById.Keys)) {
            $run = $runsById[$runId]
            $runEvents = @($eventRecords | Where-Object { Test-RunMatchesEventRecord -Run $run -EventRecord $_ })
            $run.plan = New-RunPlanContract -Run $run
            $run.draft_pr_gate = New-RunDraftPrGate -Run $run -EventRecords $runEvents
            $run.tdd_gate = New-RunTddGateContract -Run $run -EventRecords $runEvents
            $run.phase_gate = New-RunPhaseGateContract -Run $run -EventRecords $runEvents
            $run.team_memory = New-RunTeamMemoryContract -Run $run -EventRecords $runEvents
            $run.context_contract = New-RunContextContract -VerificationEvidence $run.verification_evidence -TeamMemoryRefs @($run.team_memory.team_memory_refs)
            $run.audit_chain = New-RunAuditChainContract -Run $run -EventRecords $runEvents
            $run.run_insights = New-RunInsightsContract -Run $run -EventRecords $runEvents
            $run.architecture_contract = New-RunArchitectureContract -Run $run
            $run.draft_pr_gate = New-RunDraftPrGate -Run $run -EventRecords $runEvents
            $run.phase_gate = New-RunPhaseGateContract -Run $run -EventRecords $runEvents
            $run.run_insights = New-RunInsightsContract -Run $run -EventRecords $runEvents
            $run.architecture_contract = New-RunArchitectureContract -Run $run
            $run.verification_envelope = New-RunVerificationEnvelope -Run $run
            $run.outcome = New-RunOutcomeContract -Run $run
            $run.child_launch_contract = New-RunChildLaunchContract -Run $run
            $run.checkpoint_package = New-RunCheckpointPackage -Run $run
            $nextAction = Get-RunNextAction -Run $run
            $stateModel = New-RunStateModel -State ([string]$run.state) -TaskState ([string]$run.task_state) -ReviewState ([string]$run.review_state) -EventKind $nextAction -LastEvent ([string]$run.last_event)
            [ordered]@{
                run_id             = [string]$run.run_id
                task_id            = [string]$run.task_id
                task               = [string]$run.task
                task_state         = [string]$run.task_state
                review_state       = [string]$run.review_state
                phase              = $stateModel.phase
                activity           = $stateModel.activity
                detail             = $stateModel.detail
                branch             = [string]$run.branch
                worktree           = [string]$run.worktree
                head_sha           = [string]$run.head_sha
                primary_label      = [string]$run.primary_label
                primary_pane_id    = [string]$run.primary_pane_id
                primary_role       = [string]$run.primary_role
                state              = [string]$run.state
                tokens_remaining   = [string]$run.tokens_remaining
                last_event         = [string]$run.last_event
                last_event_at      = [string]$run.last_event_at
                pane_count         = [int]$run.pane_count
                changed_file_count = [int]$run.changed_file_count
                labels             = @($run.labels)
                pane_ids           = @($run.pane_ids)
                roles              = @($run.roles)
                changed_files      = @($run.changed_files)
                action_items       = @($run.action_items | Sort-Object @{ Expression = { [string]$_.timestamp }; Descending = $true }, @{ Expression = { [string]$_.kind } })
                parent_run_id      = [string]$run.parent_run_id
                goal               = [string]$run.goal
                task_type          = [string]$run.task_type
                priority           = [string]$run.priority
                blocking           = [bool]$run.blocking
                write_scope        = @($run.write_scope)
                read_scope         = @($run.read_scope)
                constraints        = @($run.constraints)
                expected_output    = [string]$run.expected_output
                verification_plan  = @($run.verification_plan)
                review_required    = [bool]$run.review_required
                provider_target    = [string]$run.provider_target
                agent_role         = if (-not [string]::IsNullOrWhiteSpace([string]$run.agent_role)) { [string]$run.agent_role } else { [string]$run.primary_role }
                timeout_policy     = [string]$run.timeout_policy
                handoff_refs       = @($run.handoff_refs)
                experiment_packet  = $run.experiment_packet
                security_policy    = $run.security_policy
                security_verdict   = $run.security_verdict
                verification_contract = $run.verification_contract
                verification_result   = $run.verification_result
                verification_evidence = $run.verification_evidence
                context_contract      = $run.context_contract
                team_memory           = $run.team_memory
                run_insights          = $run.run_insights
                architecture_contract = $run.architecture_contract
                child_launch_contract = $run.child_launch_contract
                checkpoint_package    = $run.checkpoint_package
                tdd_gate              = $run.tdd_gate
                verification_envelope = $run.verification_envelope
                plan                  = $run.plan
                plan_checkpoints      = @($run.plan_checkpoints)
                managed_loop          = $run.managed_loop
                audit_chain           = $run.audit_chain
                outcome               = $run.outcome
                phase_gate            = $run.phase_gate
                draft_pr_gate         = $run.draft_pr_gate
            }
        }
    )

    foreach ($run in @($runs)) {
        $run['run_packet'] = New-RunPacketFromRun -Run $run
    }

    return [ordered]@{
        generated_at = (Get-Date).ToString('o')
        project_dir  = $ProjectDir
        summary      = [ordered]@{
            run_count          = $runs.Count
            blocked_runs       = @($runs | Where-Object { [string]$_.task_state -eq 'blocked' }).Count
            review_pending     = @($runs | Where-Object { [string]$_.review_state -eq 'PENDING' }).Count
            dirty_runs         = @($runs | Where-Object { [int]$_.changed_file_count -gt 0 }).Count
            action_item_count  = @($runs | ForEach-Object { @($_.action_items).Count } | Measure-Object -Sum).Sum
        }
        runs         = @($runs | Sort-Object @{ Expression = { [string]$_.last_event_at }; Descending = $true }, @{ Expression = { [string]$_.run_id } })
    }
}

function Get-RunFromPayload {
    param(
        [Parameter(Mandatory = $true)]$RunsPayload,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    foreach ($run in @($RunsPayload.runs)) {
        if ([string]$run.run_id -eq $RunId) {
            return $run
        }
    }

    return $null
}

function Test-RunRecommendable {
    param([Parameter(Mandatory = $true)]$Run)

    $taskState = [string]$Run.task_state
    $reviewState = ([string]$Run.review_state).ToUpperInvariant()
    $verificationOutcome = if ($null -ne $Run.verification_result) { ([string]$Run.verification_result.outcome).ToUpperInvariant() } else { '' }
    $securityVerdict = if ($null -ne $Run.security_verdict) { ([string]$Run.security_verdict.verdict).ToUpperInvariant() } else { '' }

    if ($taskState -notin @('completed', 'task_completed', 'commit_ready', 'done')) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($reviewState) -and $reviewState -ne 'PASS') {
        return $false
    }
    if ($verificationOutcome -ne 'PASS') {
        return $false
    }
    if ($securityVerdict -notin @('ALLOW', 'PASS')) {
        return $false
    }
    $architectureContract = Get-RunContractField -InputObject $Run -Name 'architecture_contract'
    $architectureScoreRegression = [bool](Get-RunContractField -InputObject $architectureContract -Name 'score_regression')
    $architectureBaseline = Get-RunContractField -InputObject $architectureContract -Name 'baseline'
    $architectureReviewRequired = [bool](Get-RunContractField -InputObject $architectureBaseline -Name 'review_required_on_drift')
    if ($architectureScoreRegression -and $architectureReviewRequired -and $reviewState -ne 'PASS') {
        return $false
    }

    return $true
}

function Test-RunPromotable {
    param([Parameter(Mandatory = $true)]$Run)

    return (Test-RunRecommendable -Run $Run)
}

function Get-RunPlaybookFlow {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [AllowNull()]$EvidenceDigest = $null,
        [string]$Fallback = 'bugfix'
    )

    $nextAction = [string](Get-RunContractField -InputObject $EvidenceDigest -Name 'next_action')
    $reviewState = [string](Get-RunContractField -InputObject $Run -Name 'review_state')
    $changedFiles = @(
        foreach ($changedFile in @($Run.changed_files)) {
            [string]$changedFile
        }
    )

    if ($changedFiles | Where-Object { $_ -match '^\.github/' -or $_ -match '\.ya?ml$' -or $_ -match 'package(-lock)?\.json$' }) {
        return 'ci'
    }
    if ($reviewState -in @('PENDING', 'FAIL', 'FAILED') -or $nextAction -match 'review') {
        return 'review'
    }
    if ($changedFiles | Where-Object { $_ -match '\.(css|tsx|jsx|html)$' -or $_ -match 'ui|desktop|viewport' }) {
        return 'ui'
    }

    return $Fallback
}

function New-RunPlaybookTemplate {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [AllowNull()]$EvidenceDigest = $null,
        [string]$Flow = '',
        [string]$Source = 'run'
    )

    if ([string]::IsNullOrWhiteSpace($Flow)) {
        $Flow = Get-RunPlaybookFlow -Run $Run -EvidenceDigest $EvidenceDigest
    }

    $requiredEvidence = switch ($Flow) {
        'ci' { @('workflow_status', 'build_log', 'rerun_evidence') }
        'review' { @('findings', 'review_decision', 'evidence_refs') }
        'ui' { @('screenshot_or_manual_check', 'interaction_check', 'viewport_check') }
        'compare_winner_follow_up' { @('winning_run', 'comparison_evidence', 'promotion_candidate') }
        'conflict_resolution' { @('overlap_paths', 'reconcile_consult', 'human_decision') }
        default { @('reproduction', 'fix', 'regression_test') }
    }

    return [ordered]@{
        contract_version          = 1
        packet_type               = 'playbook_template_contract'
        source                    = [string]$Source
        source_run_id             = [string]$Run.run_id
        flow                      = [string]$Flow
        template_refs             = @("playbook:$Flow")
        role_policy               = [ordered]@{
            builder  = 'implement smallest verified change'
            reviewer = 'return findings first with evidence references'
            tester   = 'verify unit integration cli and contract coverage'
        }
        required_evidence         = @($requiredEvidence)
        team_memory_refs          = @(ConvertTo-RunStringArray -Value (Get-RunContractField -InputObject $Run.team_memory -Name 'team_memory_refs') | Sort-Object -Unique)
        handoff_refs              = @($Run.handoff_refs)
        execution_backend         = 'operator_managed'
        backend_profile_required  = $false
        approval_defaults         = New-ManagedFollowUpApprovalDefaults
        freeform_body_stored      = $false
        private_guidance_stored   = $false
        local_reference_paths_stored = $false
    }
}

function New-ManagedFollowUpApprovalDefaults {
    return [ordered]@{
        contract_version        = 1
        packet_type             = 'managed_follow_up_approval_defaults'
        review_required         = $true
        human_approval_required = $true
        auto_merge_allowed      = $false
        merge_requires_human    = $true
        operator_controls_merge = $true
    }
}

function New-CompareWinnerFollowUpRunContract {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$EvidenceDigest,
        [Parameter(Mandatory = $true)]$PlaybookTemplate
    )

    $experimentPacket = Get-RunContractField -InputObject $Run -Name 'experiment_packet'
    $observationPackRef = [string](Get-RunContractField -InputObject $experimentPacket -Name 'observation_pack_ref')
    $consultationRef = [string](Get-RunContractField -InputObject $experimentPacket -Name 'consultation_ref')

    return [ordered]@{
        contract_version             = 1
        packet_type                  = 'managed_follow_up_run_contract'
        source                       = 'compare_runs'
        source_run_id                = [string]$Run.run_id
        task_id                      = [string]$Run.task_id
        flow                         = 'compare_winner_follow_up'
        run_mode                     = 'operator_managed'
        playbook_template_ref        = 'playbook:compare_winner_follow_up'
        required_evidence            = @($PlaybookTemplate.required_evidence)
        source_evidence_refs         = @(
            if (-not [string]::IsNullOrWhiteSpace($observationPackRef)) { $observationPackRef }
            if (-not [string]::IsNullOrWhiteSpace($consultationRef)) { $consultationRef }
        )
        changed_files                = @(ConvertTo-RunPublicChangedFiles -ChangedFiles $EvidenceDigest.changed_files)
        team_memory_refs             = @($PlaybookTemplate.team_memory_refs)
        approval_defaults            = New-ManagedFollowUpApprovalDefaults
        review_required              = $true
        human_approval_required      = $true
        auto_merge_allowed           = $false
        merge_requires_human         = $true
        operator_controls_merge      = $true
        next_action                  = 'start managed follow-up run and request human review before merge'
        local_reference_paths_stored = $false
        freeform_body_stored         = $false
        private_guidance_stored      = $false
    }
}

function New-CompareReconcilePlaybookTemplate {
    param(
        [Parameter(Mandatory = $true)]$LeftRun,
        [Parameter(Mandatory = $true)]$RightRun
    )

    $teamMemoryRefs = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(ConvertTo-RunStringArray -Value (Get-RunContractField -InputObject $LeftRun.team_memory -Name 'team_memory_refs'))) {
        Add-RunUniqueString -List $teamMemoryRefs -Value $item
    }
    foreach ($item in @(ConvertTo-RunStringArray -Value (Get-RunContractField -InputObject $RightRun.team_memory -Name 'team_memory_refs'))) {
        Add-RunUniqueString -List $teamMemoryRefs -Value $item
    }

    return [ordered]@{
        contract_version          = 1
        packet_type               = 'playbook_template_contract'
        source                    = 'compare_runs'
        source_run_id             = ''
        flow                      = 'conflict_resolution'
        template_refs             = @('playbook:conflict_resolution')
        role_policy               = [ordered]@{
            builder  = 'prepare minimal conflict evidence'
            reviewer = 'compare behavior and safety risks'
            tester   = 'verify both branches before choosing'
        }
        required_evidence         = @('overlap_paths', 'reconcile_consult', 'human_decision')
        compare_run_ids           = @([string]$LeftRun.run_id, [string]$RightRun.run_id)
        team_memory_refs          = @($teamMemoryRefs | Sort-Object -Unique)
        execution_backend         = 'operator_managed'
        backend_profile_required  = $false
        approval_defaults         = New-ManagedFollowUpApprovalDefaults
        freeform_body_stored      = $false
        private_guidance_stored   = $false
        local_reference_paths_stored = $false
    }
}

function ConvertTo-CompareRunsPayload {
    param(
        [Parameter(Mandatory = $true)]$LeftPayload,
        [Parameter(Mandatory = $true)]$RightPayload
    )

    $leftRun = $LeftPayload.run
    $rightRun = $RightPayload.run
    $leftExperiment = $leftRun.experiment_packet
    $rightExperiment = $rightRun.experiment_packet
    $leftEvidence = $LeftPayload.evidence_digest
    $rightEvidence = $RightPayload.evidence_digest
    $leftChangedFiles = @($leftEvidence.changed_files)
    $rightChangedFiles = @($rightEvidence.changed_files)
    $sharedChangedFiles = @($leftChangedFiles | Where-Object { $_ -in $rightChangedFiles } | Select-Object -Unique)
    $leftOnlyChangedFiles = @($leftChangedFiles | Where-Object { $_ -notin $rightChangedFiles })
    $rightOnlyChangedFiles = @($rightChangedFiles | Where-Object { $_ -notin $leftChangedFiles })

    $leftConfidence = if ($null -ne $leftExperiment -and $leftExperiment.Contains('confidence')) { $leftExperiment.confidence } else { $null }
    $rightConfidence = if ($null -ne $rightExperiment -and $rightExperiment.Contains('confidence')) { $rightExperiment.confidence } else { $null }
    $confidenceDelta = $null
    if ($null -ne $leftConfidence -and $null -ne $rightConfidence) {
        $confidenceDelta = [math]::Round(([double]$leftConfidence - [double]$rightConfidence), 4)
    }

    $differences = [System.Collections.Generic.List[object]]::new()
    foreach ($field in @(
            'branch',
            'worktree',
            'slot',
            'task_state',
            'review_state',
            'state',
            'next_action',
            'hypothesis',
            'result',
            'env_fingerprint',
            'command_hash'
        )) {
        $leftValue = ''
        $rightValue = ''
        switch ($field) {
            'branch'         { $leftValue = [string]$leftRun.branch; $rightValue = [string]$rightRun.branch }
            'worktree'       { $leftValue = if ($null -ne $leftExperiment) { [string]$leftExperiment.worktree } else { '' }; $rightValue = if ($null -ne $rightExperiment) { [string]$rightExperiment.worktree } else { '' } }
            'slot'           { $leftValue = if ($null -ne $leftExperiment) { [string]$leftExperiment.slot } else { '' }; $rightValue = if ($null -ne $rightExperiment) { [string]$rightExperiment.slot } else { '' } }
            'task_state'     { $leftValue = [string]$leftRun.task_state; $rightValue = [string]$rightRun.task_state }
            'review_state'   { $leftValue = [string]$leftRun.review_state; $rightValue = [string]$rightRun.review_state }
            'state'          { $leftValue = [string]$leftRun.state; $rightValue = [string]$rightRun.state }
            'next_action'    { $leftValue = [string]$leftEvidence.next_action; $rightValue = [string]$rightEvidence.next_action }
            'hypothesis'     { $leftValue = if ($null -ne $leftExperiment) { [string]$leftExperiment.hypothesis } else { '' }; $rightValue = if ($null -ne $rightExperiment) { [string]$rightExperiment.hypothesis } else { '' } }
            'result'         { $leftValue = if ($null -ne $leftExperiment) { [string]$leftExperiment.result } else { '' }; $rightValue = if ($null -ne $rightExperiment) { [string]$rightExperiment.result } else { '' } }
            'env_fingerprint'{ $leftValue = if ($null -ne $leftExperiment) { [string]$leftExperiment.env_fingerprint } else { '' }; $rightValue = if ($null -ne $rightExperiment) { [string]$rightExperiment.env_fingerprint } else { '' } }
            'command_hash'   { $leftValue = if ($null -ne $leftExperiment) { [string]$leftExperiment.command_hash } else { '' }; $rightValue = if ($null -ne $rightExperiment) { [string]$rightExperiment.command_hash } else { '' } }
        }

        if ($leftValue -ne $rightValue) {
            $differences.Add([ordered]@{
                field = $field
                left  = $leftValue
                right = $rightValue
            }) | Out-Null
        }
    }

    if (@($leftOnlyChangedFiles).Count -gt 0 -or @($rightOnlyChangedFiles).Count -gt 0) {
        $differences.Add([ordered]@{
            field = 'changed_files'
            left  = @($leftChangedFiles)
            right = @($rightChangedFiles)
        }) | Out-Null
    }

    if ($null -ne $confidenceDelta -and $confidenceDelta -ne 0) {
        $differences.Add([ordered]@{
            field = 'confidence'
            left  = $leftConfidence
            right = $rightConfidence
        }) | Out-Null
    }

    $leftRecommendable = Test-RunRecommendable -Run $leftRun
    $rightRecommendable = Test-RunRecommendable -Run $rightRun
    $winningRunId = ''
    if ($leftRecommendable -and $rightRecommendable -and $null -ne $confidenceDelta) {
        if ($confidenceDelta -gt 0) {
            $winningRunId = [string]$leftRun.run_id
        } elseif ($confidenceDelta -lt 0) {
            $winningRunId = [string]$rightRun.run_id
        }
    }

    $reconcileConsult = [bool](
        @($differences | Where-Object { $_.field -in @('branch', 'worktree', 'env_fingerprint', 'command_hash', 'result') }).Count -gt 0 -or
        -not ($leftRecommendable -and $rightRecommendable)
    )
    $recommendedPlaybook = $null
    $recommendedFollowUpRun = $null
    if (-not [string]::IsNullOrWhiteSpace($winningRunId)) {
        if ($winningRunId -eq [string]$leftRun.run_id) {
            $recommendedPlaybook = New-RunPlaybookTemplate -Run $leftRun -EvidenceDigest $leftEvidence -Flow 'compare_winner_follow_up' -Source 'compare_runs'
            $recommendedFollowUpRun = New-CompareWinnerFollowUpRunContract -Run $leftRun -EvidenceDigest $leftEvidence -PlaybookTemplate $recommendedPlaybook
        } else {
            $recommendedPlaybook = New-RunPlaybookTemplate -Run $rightRun -EvidenceDigest $rightEvidence -Flow 'compare_winner_follow_up' -Source 'compare_runs'
            $recommendedFollowUpRun = New-CompareWinnerFollowUpRunContract -Run $rightRun -EvidenceDigest $rightEvidence -PlaybookTemplate $recommendedPlaybook
        }
    } elseif ($reconcileConsult) {
        $recommendedPlaybook = New-CompareReconcilePlaybookTemplate -LeftRun $leftRun -RightRun $rightRun
    }

    return [ordered]@{
        generated_at = (Get-Date).ToString('o')
        left = [ordered]@{
            run_id               = [string]$leftRun.run_id
            label                = [string]$leftRun.primary_label
            branch               = [string]$leftRun.branch
            task_state           = [string]$leftRun.task_state
            review_state         = [string]$leftRun.review_state
            state                = [string]$leftRun.state
            next_action          = [string]$leftEvidence.next_action
            confidence           = $leftConfidence
            changed_files        = @($leftChangedFiles)
            observation_pack_ref = if ($null -ne $leftExperiment) { [string]$leftExperiment.observation_pack_ref } else { '' }
            consultation_ref     = if ($null -ne $leftExperiment) { [string]$leftExperiment.consultation_ref } else { '' }
            recommendable        = $leftRecommendable
        }
        right = [ordered]@{
            run_id               = [string]$rightRun.run_id
            label                = [string]$rightRun.primary_label
            branch               = [string]$rightRun.branch
            task_state           = [string]$rightRun.task_state
            review_state         = [string]$rightRun.review_state
            state                = [string]$rightRun.state
            next_action          = [string]$rightEvidence.next_action
            confidence           = $rightConfidence
            changed_files        = @($rightChangedFiles)
            observation_pack_ref = if ($null -ne $rightExperiment) { [string]$rightExperiment.observation_pack_ref } else { '' }
            consultation_ref     = if ($null -ne $rightExperiment) { [string]$rightExperiment.consultation_ref } else { '' }
            recommendable        = $rightRecommendable
        }
        shared_changed_files = @($sharedChangedFiles)
        left_only_changed_files = @($leftOnlyChangedFiles)
        right_only_changed_files = @($rightOnlyChangedFiles)
        confidence_delta = $confidenceDelta
        differences = @($differences)
        recommend = [ordered]@{
            winning_run_id = $winningRunId
            reconcile_consult = $reconcileConsult
            next_action = if ([string]$leftEvidence.next_action -eq [string]$rightEvidence.next_action) { [string]$leftEvidence.next_action } else { 'reconcile_consult' }
            playbook_template = $recommendedPlaybook
            follow_up_run = $recommendedFollowUpRun
        }
    }
}

function Get-PromoteTacticPayload {
    param(
        [Parameter(Mandatory = $true)]$ExplainPayload,
        [string]$Title = '',
        [string]$Kind = 'playbook'
    )

    $run = $ExplainPayload.run
    $experimentPacket = $run.experiment_packet
    $observationPack = $ExplainPayload.observation_pack
    $consultationPacket = $ExplainPayload.consultation_packet
    $evidenceDigest = $ExplainPayload.evidence_digest

    if ([string]::IsNullOrWhiteSpace($Title)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$consultationPacket.recommendation)) {
            $Title = [string]$consultationPacket.recommendation
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$experimentPacket.result)) {
            $Title = [string]$experimentPacket.result
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$run.task)) {
            $Title = [string]$run.task
        } else {
            $Title = "Tactic from $([string]$run.run_id)"
        }
    }
    $playbookFlow = ''
    if ([string]$Kind -eq 'verification') {
        $playbookFlow = 'ci'
    }

    return [ordered]@{
        run_id               = [string]$run.run_id
        task_id              = [string]$run.task_id
        pane_id              = [string]$run.primary_pane_id
        slot                 = if ($null -ne $experimentPacket) { [string]$experimentPacket.slot } else { '' }
        kind                 = [string]$Kind
        title                = [string]$Title
        summary              = if (-not [string]::IsNullOrWhiteSpace([string]$consultationPacket.recommendation)) { [string]$consultationPacket.recommendation } else { [string]$experimentPacket.result }
        hypothesis           = if ($null -ne $experimentPacket) { [string]$experimentPacket.hypothesis } else { '' }
        next_action          = [string]$evidenceDigest.next_action
        confidence           = if ($null -ne $experimentPacket -and $experimentPacket.Contains('confidence')) { $experimentPacket.confidence } else { $null }
        branch               = [string]$run.branch
        head_sha             = [string]$run.head_sha
        worktree             = if ($null -ne $experimentPacket) { [string]$experimentPacket.worktree } else { '' }
        env_fingerprint      = if ($null -ne $experimentPacket) { [string]$experimentPacket.env_fingerprint } else { '' }
        command_hash         = if ($null -ne $experimentPacket) { [string]$experimentPacket.command_hash } else { '' }
        changed_files        = @($evidenceDigest.changed_files)
        observation_pack_ref = if ($null -ne $experimentPacket) { [string]$experimentPacket.observation_pack_ref } else { '' }
        consultation_ref     = if ($null -ne $experimentPacket) { [string]$experimentPacket.consultation_ref } else { '' }
        verification_result  = $run.verification_result
        verification_evidence = $run.verification_evidence
        security_verdict     = $run.security_verdict
        playbook_template    = New-RunPlaybookTemplate -Run $run -EvidenceDigest $evidenceDigest -Flow $playbookFlow -Source 'promote_tactic'
        action_item_count    = @($run.action_items).Count
        action_item_kinds    = @($run.action_items | ForEach-Object { [string]$_.kind } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        reuse_conditions     = @(
            if (-not [string]::IsNullOrWhiteSpace([string]$run.branch)) { "branch=$([string]$run.branch)" }
            if ($null -ne $experimentPacket -and -not [string]::IsNullOrWhiteSpace([string]$experimentPacket.env_fingerprint)) { "env_fingerprint=$([string]$experimentPacket.env_fingerprint)" }
            if ($null -ne $experimentPacket -and -not [string]::IsNullOrWhiteSpace([string]$experimentPacket.command_hash)) { "command_hash=$([string]$experimentPacket.command_hash)" }
        )
    }
}

function Get-ShortHeadSha {
    param([AllowNull()][string]$HeadSha)

    if ([string]::IsNullOrWhiteSpace($HeadSha)) {
        return ''
    }

    if ($HeadSha.Length -le 7) {
        return $HeadSha
    }

    return $HeadSha.Substring(0, 7)
}

function Get-RunNextAction {
    param([Parameter(Mandatory = $true)]$Run)

    $priorityOrder = @(
        'approval_waiting',
        'review_failed',
        'task_blocked',
        'blocked',
        'needs_user_decision',
        'commit_ready',
        'task_completed',
        'review_pending',
        'dispatch_needed'
    )
    foreach ($priorityKind in $priorityOrder) {
        $match = $Run.action_items | Where-Object { [string]$_.kind -eq $priorityKind } | Select-Object -First 1
        if ($null -ne $match) {
            return [string]$match.kind
        }
    }

    $firstActionItem = $Run.action_items | Select-Object -First 1
    if ($null -ne $firstActionItem -and -not [string]::IsNullOrWhiteSpace([string]$firstActionItem.kind)) {
        return [string]$firstActionItem.kind
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Run.review_state)) {
        return [string]$Run.review_state
    }

    return [string]$Run.task_state
}

function New-EmptyVerdictSummary {
    param([Parameter(Mandatory = $true)][string]$Kind)

    return [ordered]@{
        kind      = $Kind
        verdict   = ''
        summary   = ''
        event     = ''
        timestamp = ''
    }
}

function ConvertTo-EvidenceDigestItem {
    param([Parameter(Mandatory = $true)]$Run)

    $experimentPacket = $Run.experiment_packet
    $nextAction = Get-RunNextAction -Run $Run
    $stateModel = New-RunStateModel -State ([string]$Run.state) -TaskState ([string]$Run.task_state) -ReviewState ([string]$Run.review_state) -EventKind $nextAction -LastEvent ([string]$Run.last_event)

    return [ordered]@{
        run_id             = [string]$Run.run_id
        task_id            = [string]$Run.task_id
        task               = [string]$Run.task
        label              = [string]$Run.primary_label
        pane_id            = [string]$Run.primary_pane_id
        role               = [string]$Run.primary_role
        provider_target    = [string]$Run.provider_target
        task_state         = [string]$Run.task_state
        review_state       = [string]$Run.review_state
        phase              = $stateModel.phase
        activity           = $stateModel.activity
        detail             = $stateModel.detail
        next_action        = $nextAction
        branch             = [string]$Run.branch
        worktree           = if ($null -ne $experimentPacket -and -not [string]::IsNullOrWhiteSpace([string]$experimentPacket.worktree)) { [string]$experimentPacket.worktree } else { [string]$Run.worktree }
        head_sha           = [string]$Run.head_sha
        head_short         = Get-ShortHeadSha -HeadSha ([string]$Run.head_sha)
        changed_file_count = [int]$Run.changed_file_count
        changed_files      = @($Run.changed_files)
        action_item_count  = @($Run.action_items).Count
        last_event         = [string]$Run.last_event
        last_event_at      = [string]$Run.last_event_at
        verification_verdict_summary = New-EmptyVerdictSummary -Kind 'verification'
        security_verdict_summary = New-EmptyVerdictSummary -Kind 'security'
        monitoring_verdict_summary = New-EmptyVerdictSummary -Kind 'monitoring'
        verification_outcome = if ($null -ne $Run.verification_result) { [string]$Run.verification_result.outcome } else { '' }
        security_blocked   = if ($null -ne $Run.security_verdict) { [string]$Run.security_verdict.verdict } else { '' }
        hypothesis         = if ($null -ne $experimentPacket) { [string]$experimentPacket.hypothesis } else { '' }
        confidence         = if ($null -ne $experimentPacket) { $experimentPacket.confidence } else { $null }
        observation_pack_ref = if ($null -ne $experimentPacket) { [string]$experimentPacket.observation_pack_ref } else { '' }
        consultation_ref   = if ($null -ne $experimentPacket) { [string]$experimentPacket.consultation_ref } else { '' }
    }
}

function ConvertTo-DigestSummaryEventItem {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $kind = Get-InboxActionableEventKind -EventRecord $EventRecord
    if ([string]::IsNullOrWhiteSpace($kind)) {
        return $null
    }

    $data = $null
    if ($EventRecord.Contains('data')) {
        $data = $EventRecord['data']
    }

    $branch = [string]$EventRecord['branch']
    $headSha = [string]$EventRecord['head_sha']
    $taskId = ''
    $runId = ''
    $nextAction = ''
    $changedFileCount = 0
    if ($null -ne $data -and $data -is [System.Collections.IDictionary]) {
        if ([string]::IsNullOrWhiteSpace($branch) -and $data.Contains('branch')) { $branch = [string]$data['branch'] }
        if ([string]::IsNullOrWhiteSpace($headSha) -and $data.Contains('head_sha')) { $headSha = [string]$data['head_sha'] }
        if ($data.Contains('task_id')) { $taskId = [string]$data['task_id'] }
        if ($data.Contains('run_id')) { $runId = [string]$data['run_id'] }
        if ($data.Contains('next_action')) { $nextAction = [string]$data['next_action'] }
        if ($data.Contains('changed_file_count')) { $changedFileCount = [int]$data['changed_file_count'] }
    }

    return [ordered]@{
        timestamp          = [string]$EventRecord['timestamp']
        kind               = $kind
        source_event       = [string]$EventRecord['event']
        run_id             = $runId
        task_id            = $taskId
        label              = [string]$EventRecord['label']
        pane_id            = [string]$EventRecord['pane_id']
        role               = [string]$EventRecord['role']
        message            = [string]$EventRecord['message']
        next_action        = $nextAction
        branch             = $branch
        head_sha           = $headSha
        head_short         = Get-ShortHeadSha -HeadSha $headSha
        changed_file_count = $changedFileCount
    }
}

function Get-DigestSummaryEventItems {
    param([Parameter(Mandatory = $true)][object[]]$EventRecords)

    return @(
        foreach ($eventRecord in @($EventRecords)) {
            $item = ConvertTo-DigestSummaryEventItem -EventRecord $eventRecord
            if ($null -ne $item) {
                $item
            }
        }
    )
}

function Get-DigestPayload {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $runsPayload = Get-RunsPayload -ProjectDir $ProjectDir
    $items = @(
        foreach ($run in @($runsPayload.runs)) {
            ConvertTo-EvidenceDigestItem -Run $run
        }
    )

    return [ordered]@{
        generated_at = (Get-Date).ToString('o')
        project_dir  = $ProjectDir
        summary      = [ordered]@{
            item_count         = @($items).Count
            dirty_items        = @($items | Where-Object { [int]$_.changed_file_count -gt 0 }).Count
            review_pending     = @($items | Where-Object { [string]$_.review_state -eq 'PENDING' }).Count
            review_failed      = @($items | Where-Object { [string]$_.review_state -in @('FAIL', 'FAILED') }).Count
            actionable_items   = @($items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.next_action) }).Count
        }
        items        = @($items | Sort-Object @{ Expression = { [string]$_.last_event_at }; Descending = $true }, @{ Expression = { [string]$_.run_id } })
    }
}

function New-DesktopRunProjection {
    param(
        [Parameter(Mandatory = $true)]$DigestItem,
        [AllowNull()]$ExplainPayload
    )

    $run = if ($null -ne $ExplainPayload) { $ExplainPayload.run } else { $null }
    $explanation = if ($null -ne $ExplainPayload) { $ExplainPayload.explanation } else { $null }
    $evidenceDigest = if ($null -ne $ExplainPayload) { $ExplainPayload.evidence_digest } else { $null }

    $runId = [string]$DigestItem.run_id
    $task = [string]$DigestItem.task
    $branch = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.branch)) {
        [string]$run.branch
    } else {
        [string]$DigestItem.branch
    }
    $runWorktree = if ($null -ne $run) { [string]$run.worktree } else { '' }
    if ([string]::IsNullOrWhiteSpace($runWorktree) -and $null -ne $run -and $null -ne $run.experiment_packet) {
        $runWorktree = [string]$run.experiment_packet.worktree
    }
    $digestWorktree = if ($null -ne $DigestItem) { [string]$DigestItem.worktree } else { '' }
    $worktree = if (-not [string]::IsNullOrWhiteSpace($runWorktree)) {
        $runWorktree
    } else {
        $digestWorktree
    }
    $changedFiles = if ($null -ne $evidenceDigest -and @($evidenceDigest.changed_files).Count -gt 0) {
        @($evidenceDigest.changed_files)
    } else {
        @($DigestItem.changed_files)
    }
    $summary = if ($null -ne $explanation -and -not [string]::IsNullOrWhiteSpace([string]$explanation.summary)) {
        [string]$explanation.summary
    } elseif (-not [string]::IsNullOrWhiteSpace($task)) {
        $task
    } elseif (-not [string]::IsNullOrWhiteSpace($runId)) {
        "Projected from $runId"
    } else {
        'Projected run'
    }
    $reasons = @()
    if ($null -ne $explanation) {
        $reasons = @($explanation.reasons)
    }

    return [ordered]@{
        run_id               = $runId
        pane_id              = [string]$DigestItem.pane_id
        label                = [string]$DigestItem.label
        branch               = $branch
        worktree             = $worktree
        head_sha             = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.head_sha)) { [string]$run.head_sha } else { [string]$DigestItem.head_sha }
        head_short           = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.head_sha)) { Get-ShortHeadSha -HeadSha ([string]$run.head_sha) } else { [string]$DigestItem.head_short }
        provider_target      = [string]$DigestItem.provider_target
        task                 = $task
        task_state           = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.task_state)) { [string]$run.task_state } else { [string]$DigestItem.task_state }
        review_state         = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.review_state)) { [string]$run.review_state } else { [string]$DigestItem.review_state }
        phase                = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.phase)) { [string]$run.phase } else { [string]$DigestItem.phase }
        activity             = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.activity)) { [string]$run.activity } else { [string]$DigestItem.activity }
        detail               = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.detail)) { [string]$run.detail } else { [string]$DigestItem.detail }
        verification_outcome = if ($null -ne $evidenceDigest -and -not [string]::IsNullOrWhiteSpace([string]$evidenceDigest.verification_outcome)) { [string]$evidenceDigest.verification_outcome } else { [string]$DigestItem.verification_outcome }
        security_blocked     = if ($null -ne $evidenceDigest -and -not [string]::IsNullOrWhiteSpace([string]$evidenceDigest.security_blocked)) { [string]$evidenceDigest.security_blocked } else { [string]$DigestItem.security_blocked }
        verification_verdict_summary = if ($null -ne $evidenceDigest -and $null -ne $evidenceDigest.verification_verdict_summary) { $evidenceDigest.verification_verdict_summary } else { $DigestItem.verification_verdict_summary }
        security_verdict_summary     = if ($null -ne $evidenceDigest -and $null -ne $evidenceDigest.security_verdict_summary) { $evidenceDigest.security_verdict_summary } else { $DigestItem.security_verdict_summary }
        monitoring_verdict_summary   = if ($null -ne $evidenceDigest -and $null -ne $evidenceDigest.monitoring_verdict_summary) { $evidenceDigest.monitoring_verdict_summary } else { $DigestItem.monitoring_verdict_summary }
        changed_files        = @($changedFiles)
        next_action          = if ($null -ne $explanation -and -not [string]::IsNullOrWhiteSpace([string]$explanation.next_action)) { [string]$explanation.next_action } else { [string]$DigestItem.next_action }
        summary              = $summary
        reasons              = @($reasons)
        hypothesis           = [string]$DigestItem.hypothesis
        confidence           = $DigestItem.confidence
        observation_pack_ref = [string]$DigestItem.observation_pack_ref
        consultation_ref     = [string]$DigestItem.consultation_ref
    }
}

function Get-DesktopSummaryPayload {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $board = Get-BoardPayload -ProjectDir $ProjectDir
    $inbox = Get-InboxPayload -ProjectDir $ProjectDir
    $digest = Get-DigestPayload -ProjectDir $ProjectDir
    $runProjections = @()

    foreach ($digestItem in @($digest.items)) {
        $runProjections += @(New-DesktopRunProjection -DigestItem $digestItem -ExplainPayload $null)
    }

    return [ordered]@{
        generated_at    = (Get-Date).ToString('o')
        project_dir     = $ProjectDir
        board           = $board
        inbox           = $inbox
        digest          = $digest
        run_projections = @($runProjections)
    }
}

function Get-DesktopSummaryRefreshRunId {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $data = $null
    if ($EventRecord.Contains('data')) {
        $data = $EventRecord['data']
    }

    $runId = ''
    if ($null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('run_id')) {
        $runId = [string]$data['run_id']
    }
    if ([string]::IsNullOrWhiteSpace($runId) -and $EventRecord.Contains('run_id')) {
        $runId = [string]$EventRecord['run_id']
    }
    if (-not [string]::IsNullOrWhiteSpace($runId)) {
        return $runId
    }

    $taskId = ''
    if ($null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('task_id')) {
        $taskId = [string]$data['task_id']
    }
    if ([string]::IsNullOrWhiteSpace($taskId) -and $EventRecord.Contains('task_id')) {
        $taskId = [string]$EventRecord['task_id']
    }
    if (-not [string]::IsNullOrWhiteSpace($taskId)) {
        return "task:$taskId"
    }

    $branch = [string]$EventRecord['branch']
    if ([string]::IsNullOrWhiteSpace($branch) -and $null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('branch')) {
        $branch = [string]$data['branch']
    }
    if (-not [string]::IsNullOrWhiteSpace($branch)) {
        return "branch:$branch"
    }

    return ''
}

function ConvertTo-DesktopSummaryRefreshItem {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $reason = [string]$EventRecord['event']
    if ([string]::IsNullOrWhiteSpace($reason) -and $EventRecord.Contains('status')) {
        $reason = [string]$EventRecord['status']
    }
    if ([string]::IsNullOrWhiteSpace($reason)) {
        return $null
    }

    $item = [ordered]@{
        source = 'summary'
        reason = $reason
    }

    $timestamp = [string]$EventRecord['timestamp']
    if (-not [string]::IsNullOrWhiteSpace($timestamp)) {
        $item['timestamp'] = $timestamp
    }

    $paneId = [string]$EventRecord['pane_id']
    if (-not [string]::IsNullOrWhiteSpace($paneId)) {
        $item['pane_id'] = $paneId
    }

    $runId = Get-DesktopSummaryRefreshRunId -EventRecord $EventRecord
    if (-not [string]::IsNullOrWhiteSpace($runId)) {
        $item['run_id'] = $runId
    }

    return $item
}

function Get-ExplainPayload {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $runsPayload = Get-RunsPayload -ProjectDir $ProjectDir
    $run = @($runsPayload.runs | Where-Object { [string]$_.run_id -eq $RunId } | Select-Object -First 1)[0]
    if ($null -eq $run) {
        Stop-WithError "run not found: $RunId"
    }
    if ($run -is [System.Collections.IDictionary] -and $run.Contains('run_packet')) {
        $run.Remove('run_packet')
    }

    $events = @(
        Get-BridgeEventRecords -ProjectDir $ProjectDir |
            Where-Object { Test-RunMatchesEventRecord -Run $run -EventRecord $_ } |
            ForEach-Object { ConvertTo-RunEventRecord -EventRecord $_ -ProjectDir $ProjectDir } |
            Sort-Object @{ Expression = { [string]$_.timestamp }; Descending = $true }, @{ Expression = { [int]$_.line_number }; Descending = $true }
    )

    $reviewState = $null
    $branch = [string]$run.branch
    if (-not [string]::IsNullOrWhiteSpace($branch)) {
        $state = Get-ReviewState -ProjectDir $ProjectDir
        if ($state.Contains($branch)) {
            $reviewState = ConvertTo-ReviewStateValue -Value $state[$branch]
            Assert-ReviewStateRecordShape -Record $reviewState -Branch $branch
        }
    }

    $reasons = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string]$run.task_state)) {
        $reasons.Add("task_state=$([string]$run.task_state)") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$run.review_state)) {
        $reasons.Add("review_state=$([string]$run.review_state)") | Out-Null
    }
    if ($reviewState -is [System.Collections.IDictionary] -and $reviewState.Contains('request')) {
        $reviewRequest = $reviewState['request']
        if ($reviewRequest -is [System.Collections.IDictionary] -and $reviewRequest.Contains('review_contract')) {
            $reviewContract = $reviewRequest['review_contract']
            if ($reviewContract -is [System.Collections.IDictionary] -and $reviewContract.Contains('required_scope')) {
                $reasons.Add("review_contract=$(([string[]]$reviewContract['required_scope']) -join ',')") | Out-Null
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$run.last_event)) {
        $reasons.Add("last_event=$([string]$run.last_event)") | Out-Null
    }
    foreach ($actionItem in @($run.action_items | Select-Object -First 3)) {
        $reasons.Add("action:$([string]$actionItem.kind)") | Out-Null
    }
    if ($null -ne $run.verification_result -and -not [string]::IsNullOrWhiteSpace([string]$run.verification_result.outcome)) {
        $reasons.Add("verify=$([string]$run.verification_result.outcome)") | Out-Null
    }
    if ($null -ne $run.security_verdict -and -not [string]::IsNullOrWhiteSpace([string]$run.security_verdict.verdict)) {
        $reasons.Add("security=$([string]$run.security_verdict.verdict)") | Out-Null
    }

    $evidenceDigest = ConvertTo-EvidenceDigestItem -Run $run
    $recentEvents = @($events | Select-Object -First 20)
    $observationPack = Get-HydratedObservationPack -ExperimentPacket $run.experiment_packet -ProjectDir $ProjectDir -ExpectedRunId ([string]$run.run_id)
    $consultationPacket = Get-HydratedConsultationPacket -ExperimentPacket $run.experiment_packet -ProjectDir $ProjectDir -ExpectedRunId ([string]$run.run_id)
    if ($observationPack -is [System.Collections.IDictionary] -and $observationPack.Contains('packet_type')) {
        $observationPack.Remove('packet_type')
    }
    if ($consultationPacket -is [System.Collections.IDictionary] -and $consultationPacket.Contains('packet_type')) {
        $consultationPacket.Remove('packet_type')
    }
    return [ordered]@{
        generated_at       = (Get-Date).ToString('o')
        project_dir        = $ProjectDir
        run                = $run
        observation_pack   = $observationPack
        consultation_packet = $consultationPacket
        evidence_digest    = $evidenceDigest
        explanation        = [ordered]@{
            summary       = if (-not [string]::IsNullOrWhiteSpace([string]$run.task)) { [string]$run.task } else { [string]$run.primary_label }
            reasons       = @($reasons)
            next_action   = if (@($run.action_items).Count -gt 0) { [string]$run.action_items[0].kind } else { [string]$run.task_state }
            current_state = [ordered]@{
                state        = [string]$run.state
                task_state   = [string]$run.task_state
                review_state = [string]$run.review_state
                phase        = [string]$run.phase
                activity     = [string]$run.activity
                detail       = [string]$run.detail
                last_event   = [string]$run.last_event
            }
        }
        review_state       = $reviewState
        recent_events      = $recentEvents
    }
}

function ConvertTo-ReviewPackSafeString {
    param(
        [AllowNull()]$Value = $null,
        [int]$MaxLength = 240
    )

    if ($null -eq $Value) {
        return ''
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    $text = $text -replace '[\r\n]+', ' '
    $text = [Regex]::Replace($text, '[A-Za-z]:\\[^\s''",;)]+' , '[LOCAL_PATH]')
    $text = [Regex]::Replace($text, '\\\\[^\s''",;)]+' , '[LOCAL_PATH]')
    $text = [Regex]::Replace($text, '(?i)(?<![\w:/.-])/(?!/)(?:[A-Za-z0-9._-]+/)+[^\s''",;)]+' , '[LOCAL_PATH]')
    $text = [Regex]::Replace($text, '(?i)\b(token|secret|password|api[_-]?key)\s*=\s*\S+', '$1=[REDACTED]')
    $text = [Regex]::Replace($text, '(?i)\b(token|secret|password|api[_-]?key)\s*:\s*\S+', '$1:[REDACTED]')
    $text = [Regex]::Replace($text, 'github_pat_[A-Za-z0-9_]+', '[REDACTED]')
    $text = [Regex]::Replace($text, 'gh[pousr]_[A-Za-z0-9_]{20,}', '[REDACTED]')
    $text = [Regex]::Replace($text, 'sk-[A-Za-z0-9_-]{20,}', '[REDACTED]')
    $text = [Regex]::Replace($text, 'AIza[0-9A-Za-z_-]{20,}', '[REDACTED]')
    $text = [Regex]::Replace($text, 'AKIA[0-9A-Z]{16}', '[REDACTED]')
    $text = $text.Trim()

    if ($MaxLength -gt 0 -and $text.Length -gt $MaxLength) {
        return ($text.Substring(0, $MaxLength) + '...')
    }

    return $text
}

function Test-ReviewPackSafeRelativePath {
    param([AllowNull()][string]$Path = '')

    $candidate = ([string]$Path).Replace('\', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $false
    }
    if (
        $candidate.Length -gt 256 -or
        $candidate.Contains("`n") -or
        $candidate.Contains("`r") -or
        $candidate.Contains('://') -or
        $candidate.StartsWith('/') -or
        $candidate.StartsWith('..') -or
        $candidate.Contains('/../') -or
        ($candidate.Length -ge 2 -and $candidate[1] -eq ':')
    ) {
        return $false
    }

    if (@($candidate.Trim('/') -split '/') -contains '..') {
        return $false
    }

    $normalized = $candidate.Trim('/')
    $exclusionReason = Get-WorkersPathExclusionReason -RelativePath $normalized
    if (-not [string]::IsNullOrWhiteSpace($exclusionReason)) {
        return $false
    }

    $leaf = @($normalized -split '/')[-1].ToLowerInvariant()
    if ($leaf -match '\.(7z|bin|bmp|dll|docx|exe|gif|gz|ico|jpeg|jpg|msi|pdf|png|pptx|tar|wasm|webp|xlsx|zip)$') {
        return $false
    }

    return $true
}

function Get-ReviewPackSafePathList {
    param(
        [AllowNull()]$Value = $null,
        [int]$MaxCount = 50
    )

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(ConvertTo-RunStringArray -Value $Value)) {
        if ($items.Count -ge $MaxCount) {
            break
        }
        $candidate = ([string]$item).Replace('\', '/').Trim()
        $normalized = $candidate.Trim('/')
        if ((Test-ReviewPackSafeRelativePath -Path $candidate) -and -not $items.Contains($normalized)) {
            $items.Add($normalized) | Out-Null
        }
    }

    return @($items)
}

function Add-ReviewPackString {
    param(
        [Parameter(Mandatory = $true)]$List,
        [AllowNull()]$Value = $null,
        [int]$MaxCount = 20,
        [int]$MaxLength = 240
    )

    if ($List.Count -ge $MaxCount) {
        return
    }

    $text = ConvertTo-ReviewPackSafeString -Value $Value -MaxLength $MaxLength
    if (-not [string]::IsNullOrWhiteSpace($text) -and -not $List.Contains($text)) {
        $List.Add($text) | Out-Null
    }
}

function Add-ReviewPackStrings {
    param(
        [Parameter(Mandatory = $true)]$List,
        [AllowNull()]$Value = $null,
        [int]$MaxCount = 20,
        [int]$MaxLength = 240
    )

    foreach ($item in @(ConvertTo-RunStringArray -Value $Value)) {
        Add-ReviewPackString -List $List -Value $item -MaxCount $MaxCount -MaxLength $MaxLength
    }
}

function Get-ReviewPackArtifactRefPrefixes {
    return @(
        '.winsmux/',
        'artifacts/',
        'context-packs/',
        'knowledge/',
        'docs/',
        'README',
        'AGENT-BASE.md',
        'AGENT.md',
        'GEMINI.md',
        'GUARDRAILS.md',
        'ADR-',
        'context:',
        'evidence:',
        'evidence-note:',
        'guidance:',
        'knowledge:',
        'rationale:',
        'team-memory:'
    )
}

function Add-ReviewPackArtifactRef {
    param(
        [Parameter(Mandatory = $true)]$List,
        [AllowNull()]$Value = $null,
        [int]$MaxCount = 40
    )

    if ($List.Count -ge $MaxCount) {
        return
    }

    $text = ConvertTo-ReviewPackSafeString -Value $Value -MaxLength 256
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }
    $text = $text.Replace('\', '/')

    if ((Test-RunDurableRef -Value $text -Prefixes (Get-ReviewPackArtifactRefPrefixes)) -and -not $List.Contains($text)) {
        $List.Add($text) | Out-Null
    }
}

function Add-ReviewPackArtifactRefsFromData {
    param(
        [Parameter(Mandatory = $true)]$List,
        [AllowNull()]$Data = $null,
        [int]$Depth = 0,
        [int]$MaxCount = 40
    )

    if ($null -eq $Data -or $Depth -gt 4 -or $List.Count -ge $MaxCount) {
        return
    }

    if ($Data -is [string]) {
        Add-ReviewPackArtifactRef -List $List -Value $Data -MaxCount $MaxCount
        return
    }

    if ($Data -is [System.Collections.IDictionary]) {
        foreach ($entry in $Data.GetEnumerator()) {
            $key = [string]$entry.Key
            if ($key -match '(?i)(^|_)(ref|refs|artifact_ref|evidence_refs|source_refs|rationale_refs|observation_pack_ref|consultation_ref)$') {
                Add-ReviewPackArtifactRefsFromData -List $List -Data $entry.Value -Depth ($Depth + 1) -MaxCount $MaxCount
            } elseif ($entry.Value -is [System.Collections.IDictionary]) {
                Add-ReviewPackArtifactRefsFromData -List $List -Data $entry.Value -Depth ($Depth + 1) -MaxCount $MaxCount
            }
        }
        return
    }

    if ($Data -is [System.Collections.IEnumerable]) {
        foreach ($item in $Data) {
            Add-ReviewPackArtifactRefsFromData -List $List -Data $item -Depth ($Depth + 1) -MaxCount $MaxCount
            if ($List.Count -ge $MaxCount) {
                break
            }
        }
    }
}

function Add-ReviewPackCommandsFromData {
    param(
        [Parameter(Mandatory = $true)]$List,
        [AllowNull()]$Data = $null,
        [int]$MaxCount = 20
    )

    if ($null -eq $Data -or $List.Count -ge $MaxCount) {
        return
    }

    Add-ReviewPackString -List $List -Value (Get-RunContractField -InputObject $Data -Name 'command') -MaxCount $MaxCount -MaxLength 200
    Add-ReviewPackString -List $List -Value (Get-RunContractField -InputObject $Data -Name 'failing_command') -MaxCount $MaxCount -MaxLength 200
    Add-ReviewPackStrings -List $List -Value (Get-RunContractField -InputObject $Data -Name 'commands') -MaxCount $MaxCount -MaxLength 200
}

function New-ReviewPackVerificationItems {
    param([Parameter(Mandatory = $true)]$Run)

    $items = [System.Collections.Generic.List[object]]::new()
    $verificationEvidence = Get-RunContractField -InputObject $Run -Name 'verification_evidence'
    foreach ($name in @('build', 'test', 'browser', 'screenshot', 'recording')) {
        $data = Get-RunContractField -InputObject $verificationEvidence -Name $name
        if ($null -eq $data) {
            continue
        }

        $items.Add([ordered]@{
            kind         = $name
            command      = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $data -Name 'command') -MaxLength 200
            outcome      = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $data -Name 'outcome') -MaxLength 80
            summary      = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $data -Name 'summary') -MaxLength 200
            artifact_ref = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $data -Name 'artifact_ref') -MaxLength 256
            required     = Get-RunContractField -InputObject $data -Name 'required'
        }) | Out-Null
    }

    $verificationResult = Get-RunContractField -InputObject $Run -Name 'verification_result'
    if ($null -ne $verificationResult) {
        $items.Insert(0, [ordered]@{
            kind         = 'verification'
            command      = ''
            outcome      = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $verificationResult -Name 'outcome') -MaxLength 80
            summary      = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $verificationResult -Name 'summary') -MaxLength 200
            artifact_ref = ''
            required     = $null
        })
    }

    return @($items)
}

function New-ReviewPackReviewRequest {
    param([AllowNull()]$ReviewState = $null)

    if ($null -eq $ReviewState) {
        return $null
    }

    $request = Get-RunContractField -InputObject $ReviewState -Name 'request'
    $reviewContract = Get-RunContractField -InputObject $request -Name 'review_contract'
    return [ordered]@{
        status          = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $ReviewState -Name 'status') -MaxLength 80
        reviewer_label  = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject (Get-RunContractField -InputObject $ReviewState -Name 'reviewer') -Name 'label') -MaxLength 80
        source_task     = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $reviewContract -Name 'source_task') -MaxLength 80
        issue_ref       = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $reviewContract -Name 'issue_ref') -MaxLength 80
        style           = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $reviewContract -Name 'style') -MaxLength 80
        required_scope  = @(
            ConvertTo-RunStringArray -Value (Get-RunContractField -InputObject $reviewContract -Name 'required_scope') |
                ForEach-Object { ConvertTo-ReviewPackSafeString -Value $_ -MaxLength 120 } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -First 12
        )
    }
}

function Get-ReviewPackPayload {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $explainPayload = Get-ExplainPayload -ProjectDir $ProjectDir -RunId $RunId
    $run = $explainPayload.run
    $observationPack = $explainPayload.observation_pack
    $consultationPacket = $explainPayload.consultation_packet
    $recentEvents = @($explainPayload.recent_events)

    $changedFiles = @(Get-ReviewPackSafePathList -Value $run.changed_files -MaxCount 50)
    $commands = [System.Collections.Generic.List[string]]::new()
    $artifactRefs = [System.Collections.Generic.List[string]]::new()
    $criticObjections = [System.Collections.Generic.List[string]]::new()
    $unresolvedRisks = [System.Collections.Generic.List[string]]::new()

    $verificationEvidence = Get-RunContractField -InputObject $run -Name 'verification_evidence'
    foreach ($name in @('build', 'test', 'browser', 'screenshot', 'recording')) {
        Add-ReviewPackCommandsFromData -List $commands -Data (Get-RunContractField -InputObject $verificationEvidence -Name $name) -MaxCount 20
    }
    Add-ReviewPackCommandsFromData -List $commands -Data $observationPack -MaxCount 20
    foreach ($event in $recentEvents) {
        Add-ReviewPackCommandsFromData -List $commands -Data $event -MaxCount 20
        Add-ReviewPackCommandsFromData -List $commands -Data (Get-RunContractField -InputObject $event -Name 'data') -MaxCount 20
    }

    Add-ReviewPackArtifactRefsFromData -List $artifactRefs -Data $run -MaxCount 40
    Add-ReviewPackArtifactRefsFromData -List $artifactRefs -Data $observationPack -MaxCount 40
    Add-ReviewPackArtifactRefsFromData -List $artifactRefs -Data $consultationPacket -MaxCount 40
    foreach ($event in $recentEvents) {
        Add-ReviewPackArtifactRefsFromData -List $artifactRefs -Data $event -MaxCount 40
    }

    Add-ReviewPackStrings -List $criticObjections -Value (Get-RunContractField -InputObject $consultationPacket -Name 'risks') -MaxCount 20 -MaxLength 200
    $recommendation = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $consultationPacket -Name 'recommendation') -MaxLength 200
    if (-not [string]::IsNullOrWhiteSpace($recommendation)) {
        Add-ReviewPackString -List $criticObjections -Value ("consultation: $recommendation") -MaxCount 20 -MaxLength 220
    }
    foreach ($item in @($run.action_items)) {
        $kind = [string](Get-RunContractField -InputObject $item -Name 'kind')
        if ($kind -match '(?i)(blocked|review_failed|needs_user_decision|security)') {
            Add-ReviewPackString -List $criticObjections -Value (Get-RunContractField -InputObject $item -Name 'message') -MaxCount 20 -MaxLength 200
        }
    }

    $draftPrGate = Get-RunContractField -InputObject $run -Name 'draft_pr_gate'
    $handoffPackage = Get-RunContractField -InputObject $draftPrGate -Name 'handoff_package'
    Add-ReviewPackStrings -List $unresolvedRisks -Value (Get-RunContractField -InputObject $handoffPackage -Name 'remaining_risks') -MaxCount 24 -MaxLength 200
    Add-ReviewPackStrings -List $unresolvedRisks -Value (Get-RunContractField -InputObject $handoffPackage -Name 'blocked_reasons') -MaxCount 24 -MaxLength 200
    Add-ReviewPackString -List $unresolvedRisks -Value (Get-RunContractField -InputObject (Get-RunContractField -InputObject $run -Name 'phase_gate') -Name 'stop_reason') -MaxCount 24 -MaxLength 200
    Add-ReviewPackString -List $unresolvedRisks -Value (Get-RunContractField -InputObject (Get-RunContractField -InputObject $run -Name 'outcome') -Name 'reason') -MaxCount 24 -MaxLength 200
    Add-ReviewPackStrings -List $unresolvedRisks -Value (Get-RunContractField -InputObject $consultationPacket -Name 'risks') -MaxCount 24 -MaxLength 200

    $workerSummaries = [System.Collections.Generic.List[object]]::new()
    $workerSummaries.Add([ordered]@{
        label        = ConvertTo-ReviewPackSafeString -Value $run.primary_label -MaxLength 80
        role         = ConvertTo-ReviewPackSafeString -Value $run.primary_role -MaxLength 80
        task_state   = ConvertTo-ReviewPackSafeString -Value $run.task_state -MaxLength 80
        review_state = ConvertTo-ReviewPackSafeString -Value $run.review_state -MaxLength 80
        last_event   = ConvertTo-ReviewPackSafeString -Value $run.last_event -MaxLength 120
        hypothesis   = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $observationPack -Name 'hypothesis') -MaxLength 200
        result       = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $observationPack -Name 'result') -MaxLength 200
        confidence   = Get-RunContractField -InputObject $observationPack -Name 'confidence'
        next_action  = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $observationPack -Name 'next_action') -MaxLength 160
    }) | Out-Null

    $eventSummaries = @(
        foreach ($event in @($recentEvents | Select-Object -First 12)) {
            [ordered]@{
                timestamp = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $event -Name 'timestamp') -MaxLength 80
                event     = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $event -Name 'event') -MaxLength 120
                label     = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $event -Name 'label') -MaxLength 80
                role      = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $event -Name 'role') -MaxLength 80
                status    = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $event -Name 'status') -MaxLength 80
                message   = ConvertTo-ReviewPackSafeString -Value (Get-RunContractField -InputObject $event -Name 'message') -MaxLength 180
            }
        }
    )

    $worktreeCandidate = ([string]$run.worktree).Replace('\', '/').Trim()
    $worktree = $worktreeCandidate.Trim('/')
    if (-not (Test-ReviewPackSafeRelativePath -Path $worktreeCandidate)) {
        $worktree = ''
    }

    return [ordered]@{
        packet_type    = 'review_pack'
        schema_version = 1
        generated_at   = (Get-Date).ToString('o')
        run_id         = [string]$run.run_id
        task_id        = [string]$run.task_id
        task_summary   = [ordered]@{
            task            = ConvertTo-ReviewPackSafeString -Value $run.task -MaxLength 240
            goal            = ConvertTo-ReviewPackSafeString -Value $run.goal -MaxLength 240
            task_type       = ConvertTo-ReviewPackSafeString -Value $run.task_type -MaxLength 80
            priority        = ConvertTo-ReviewPackSafeString -Value $run.priority -MaxLength 40
            branch          = ConvertTo-ReviewPackSafeString -Value $run.branch -MaxLength 120
            head_sha        = ConvertTo-ReviewPackSafeString -Value $run.head_sha -MaxLength 80
            worktree        = $worktree
            expected_output = ConvertTo-ReviewPackSafeString -Value $run.expected_output -MaxLength 240
        }
        review_target = [ordered]@{
            label           = ConvertTo-ReviewPackSafeString -Value $run.primary_label -MaxLength 80
            role            = ConvertTo-ReviewPackSafeString -Value $run.primary_role -MaxLength 80
            provider_target = ConvertTo-ReviewPackSafeString -Value $run.provider_target -MaxLength 120
            agent_role      = ConvertTo-ReviewPackSafeString -Value $run.agent_role -MaxLength 80
            review_required = [bool]$run.review_required
        }
        review_request    = New-ReviewPackReviewRequest -ReviewState $explainPayload.review_state
        changed_files     = @($changedFiles)
        diff_summary      = [ordered]@{
            source             = 'manifest_changed_files'
            changed_file_count = [int]$run.changed_file_count
            included_files     = @($changedFiles | Select-Object -First 20)
            raw_diff_included  = $false
            raw_diff_reason    = 'Raw diff is omitted; the pack includes bounded changed-file refs and verification evidence.'
        }
        worker_summaries  = @($workerSummaries)
        test_results      = @(New-ReviewPackVerificationItems -Run $run)
        critic_objections = @($criticObjections)
        unresolved_risks  = @($unresolvedRisks)
        commands_run      = @($commands)
        artifact_refs     = @($artifactRefs)
        recent_events     = @($eventSummaries)
        limits            = [ordered]@{
            changed_files       = 50
            diff_files          = 20
            commands_run        = 20
            artifact_refs       = 40
            recent_events       = 12
            max_string_chars    = 240
            raw_diff_chars      = 0
        }
        excluded_content  = @(
            'repository_dumps',
            'long_logs',
            'secret_values',
            'binary_artifacts',
            'vendor_directories',
            'full_conversation_history',
            'local_absolute_paths'
        )
        storage_policy    = [ordered]@{
            repository_dump_stored          = $false
            long_logs_stored                = $false
            secret_values_stored            = $false
            binary_artifacts_stored         = $false
            vendor_directories_stored       = $false
            full_conversation_history_stored = $false
            local_reference_paths_stored    = $false
            freeform_body_stored            = $false
        }
    }
}

function Invoke-ReviewPack {
    param(
        [AllowNull()][string]$ReviewPackTarget = $Target,
        [AllowNull()][string[]]$ReviewPackRest = $Rest
    )

    $tokens = @()
    if (-not [string]::IsNullOrWhiteSpace($ReviewPackTarget)) {
        $tokens += $ReviewPackTarget
    }
    if ($ReviewPackRest) {
        $tokens += @($ReviewPackRest)
    }

    $jsonOutput = $false
    $runId = ''
    $projectDir = (Get-Location).Path

    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $token = [string]$tokens[$index]
        switch ($token) {
            '--json' {
                $jsonOutput = $true
            }
            '--run-id' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WithError '--run-id requires a value'
                }
                $runId = [string]$tokens[$index + 1]
                $index++
            }
            '--project-dir' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WithError '--project-dir requires a value'
                }
                $projectDir = [System.IO.Path]::GetFullPath([string]$tokens[$index + 1])
                $index++
            }
            default {
                if ([string]::IsNullOrWhiteSpace($runId)) {
                    $runId = $token
                } else {
                    Stop-WithError 'usage: winsmux review-pack <run_id> [--json] [--project-dir <path>]'
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($runId)) {
        Stop-WithError 'usage: winsmux review-pack <run_id> [--json] [--project-dir <path>]'
    }

    $reviewPack = Get-ReviewPackPayload -ProjectDir $projectDir -RunId $runId
    $artifact = New-ReviewPackFile -ProjectDir $projectDir -ReviewPack $reviewPack
    $result = [ordered]@{
        generated_at     = (Get-Date).ToString('o')
        run_id           = [string]$runId
        review_pack_ref  = [string]$artifact.reference
        review_pack      = $reviewPack
    }

    if ($jsonOutput) {
        $result | ConvertTo-Json -Compress -Depth 12 | Write-Output
        return
    }

    Write-Output ("review pack: {0} -> {1}" -f [string]$runId, [string]$artifact.reference)
    Write-Output ("changed files: {0}" -f @($reviewPack.changed_files).Count)
    Write-Output ("commands: {0}" -f @($reviewPack.commands_run).Count)
    Write-Output ("risks: {0}" -f @($reviewPack.unresolved_risks).Count)
}

function Invoke-DesktopSummary {
    param(
        [AllowNull()][string]$DesktopSummaryTarget = $Target,
        [AllowNull()][string[]]$DesktopSummaryRest = $Rest
    )

    $tokens = @()
    if (-not [string]::IsNullOrWhiteSpace($DesktopSummaryTarget)) {
        $tokens += $DesktopSummaryTarget
    }
    if ($DesktopSummaryRest) {
        $tokens += @($DesktopSummaryRest)
    }

    $jsonOutput = $false
    $streamOutput = $false

    foreach ($token in $tokens) {
        switch ($token) {
            '--json'   { $jsonOutput = $true }
            '--stream' { $streamOutput = $true }
            default    { Stop-WithError "usage: winsmux desktop-summary [--json] [--stream]" }
        }
    }

    $projectDir = (Get-Location).Path
    if ($streamOutput) {
        $cursor = @(Get-BridgeEventRecords -ProjectDir $projectDir).Count
        while ($true) {
            $delta = Get-BridgeEventDelta -ProjectDir $projectDir -Cursor $cursor
            $cursor = [int]$delta.cursor
            foreach ($eventRecord in @($delta.events)) {
                $item = ConvertTo-DesktopSummaryRefreshItem -EventRecord $eventRecord
                if ($null -eq $item) {
                    continue
                }

                if ($jsonOutput) {
                    $item | ConvertTo-Json -Compress -Depth 8 | Write-Output
                    continue
                }

                $timestamp = if ($item.Contains('timestamp')) { [string]$item.timestamp } else { '' }
                if ([string]::IsNullOrWhiteSpace($timestamp)) {
                    $timestamp = (Get-Date).ToString('o')
                }

                $details = @()
                if ($item.Contains('pane_id')) {
                    $details += "pane=$([string]$item.pane_id)"
                }
                if ($item.Contains('run_id')) {
                    $details += "run=$([string]$item.run_id)"
                }

                if ($details.Count -gt 0) {
                    Write-Output ("[{0}] summary {1} {2}" -f $timestamp, [string]$item.reason, ($details -join ' '))
                } else {
                    Write-Output ("[{0}] summary {1}" -f $timestamp, [string]$item.reason)
                }
            }

            Start-Sleep -Seconds 2
        }
    }

    $payload = Get-DesktopSummaryPayload -ProjectDir $projectDir

    if ($jsonOutput) {
        $payload | ConvertTo-Json -Compress -Depth 12 | Write-Output
        return
    }

    Write-Output ("Desktop summary: {0} panes, {1} inbox items, {2} digest items, {3} projections" -f `
        [int]$payload.board.summary.pane_count, `
        [int]$payload.inbox.summary.item_count, `
        [int]$payload.digest.summary.item_count, `
        @($payload.run_projections).Count)
}

function Write-ExplainFollowItem {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [switch]$Json
    )

    if ($Json) {
        $Item | ConvertTo-Json -Compress -Depth 10 | Write-Output
        return
    }

    Write-Output ("[{0}] {1} {2}: {3}" -f [string]$Item.timestamp, [string]$Item.event, [string]$Item.label, [string]$Item.message)
}

function Get-DigestDeltaItems {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][object[]]$EventRecords
    )

    $records = @($EventRecords)
    if ($records.Count -eq 0) {
        return @()
    }

    $runsPayload = Get-RunsPayload -ProjectDir $ProjectDir
    $matchedRunIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($run in @($runsPayload.runs)) {
        foreach ($eventRecord in $records) {
            if (Test-RunMatchesEventRecord -Run $run -EventRecord $eventRecord) {
                $matchedRunIds.Add([string]$run.run_id) | Out-Null
                break
            }
        }
    }

    if ($matchedRunIds.Count -eq 0) {
        return @()
    }

    return @(
        foreach ($run in @($runsPayload.runs | Sort-Object @{ Expression = { [string]$_.last_event_at }; Descending = $true }, @{ Expression = { [string]$_.run_id } })) {
            if ($matchedRunIds.Contains([string]$run.run_id)) {
                $item = ConvertTo-EvidenceDigestItem -Run $run
                if (
                    [int]$item.changed_file_count -gt 0 -or
                    (
                        [int]$item.action_item_count -gt 0 -and
                        [string]$item.next_action -notin @('', 'backlog', 'dispatch_needed')
                    ) -or
                    (-not [string]::IsNullOrWhiteSpace([string]$item.review_state))
                ) {
                    $item
                }
            }
        }
    )
}

function Write-DigestEventStreamItem {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [switch]$Json
    )

    if ($Json) {
        $Item | ConvertTo-Json -Compress -Depth 10 | Write-Output
        return
    }

    Write-Output ("[{0}] {1} {2} ({3}) {4}" -f `
        [string]$Item.timestamp, `
        [string]$Item.kind, `
        [string]$Item.label, `
        [string]$Item.pane_id, `
        [string]$Item.message)
}

function Write-DigestStreamItem {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [switch]$Json
    )

    if ($Json) {
        $Item | ConvertTo-Json -Compress -Depth 10 | Write-Output
        return
    }

    $updatedAt = [string]$Item.last_event_at
    if ([string]::IsNullOrWhiteSpace($updatedAt)) {
        $updatedAt = (Get-Date).ToString('o')
    }

    Write-Output ("[{0}] digest {1} {2} ({3}) next={4} files={5}" -f `
        $updatedAt, `
        [string]$Item.run_id, `
        [string]$Item.label, `
        [string]$Item.pane_id, `
        [string]$Item.next_action, `
        [int]$Item.changed_file_count)
}

function Invoke-Digest {
    param(
        [AllowNull()][string]$DigestTarget = $Target,
        [AllowNull()][string[]]$DigestRest = $Rest
    )

    $tokens = @()
    if (-not [string]::IsNullOrWhiteSpace($DigestTarget)) {
        $tokens += $DigestTarget
    }
    if ($DigestRest) {
        $tokens += @($DigestRest)
    }

    $jsonOutput = $false
    $streamOutput = $false
    $eventSummaryOutput = $false

    foreach ($token in $tokens) {
        switch ($token) {
            '--json'   { $jsonOutput = $true }
            '--stream' { $streamOutput = $true }
            '--events' { $eventSummaryOutput = $true }
            default    { Stop-WithError "usage: winsmux digest [--json] [--stream] [--events]" }
        }
    }

    $projectDir = (Get-Location).Path
    if ($streamOutput) {
        if ($eventSummaryOutput) {
            $snapshotEvents = Get-DigestSummaryEventItems -EventRecords @(Get-BridgeEventRecords -ProjectDir $projectDir)
            foreach ($item in @($snapshotEvents)) {
                Write-DigestEventStreamItem -Item $item -Json:$jsonOutput
            }
        } else {
            $snapshot = Get-DigestPayload -ProjectDir $projectDir
            foreach ($item in @($snapshot.items)) {
                Write-DigestStreamItem -Item $item -Json:$jsonOutput
            }
        }

        $cursor = @(Get-BridgeEventRecords -ProjectDir $projectDir).Count
        while ($true) {
            $delta = Get-BridgeEventDelta -ProjectDir $projectDir -Cursor $cursor
            $cursor = [int]$delta.cursor
            $items = if ($eventSummaryOutput) {
                Get-DigestSummaryEventItems -EventRecords @($delta.events)
            } else {
                Get-DigestDeltaItems -ProjectDir $projectDir -EventRecords @($delta.events)
            }
            foreach ($item in @($items)) {
                if ($eventSummaryOutput) {
                    Write-DigestEventStreamItem -Item $item -Json:$jsonOutput
                } else {
                    Write-DigestStreamItem -Item $item -Json:$jsonOutput
                }
            }

            Start-Sleep -Seconds 2
        }
    }

    if ($eventSummaryOutput) {
        $items = Get-DigestSummaryEventItems -EventRecords @(Get-BridgeEventRecords -ProjectDir $projectDir)
        $payload = [ordered]@{
            generated_at = (Get-Date).ToString('o')
            project_dir  = $projectDir
            summary      = [ordered]@{
                item_count = @($items).Count
            }
            items        = @($items)
        }

        if ($jsonOutput) {
            $payload | ConvertTo-Json -Compress -Depth 10 | Write-Output
            return
        }

        if (@($items).Count -eq 0) {
            Write-Output "(no digest events)"
            return
        }

        foreach ($item in @($items)) {
            Write-DigestEventStreamItem -Item $item
        }
        return
    }

    $payload = Get-DigestPayload -ProjectDir $projectDir

    if ($jsonOutput) {
        $payload | ConvertTo-Json -Compress -Depth 10 | Write-Output
        return
    }

    $items = @($payload.items)
    if ($items.Count -eq 0) {
        Write-Output "(no digest items)"
        return
    }

    foreach ($item in $items) {
        Write-Output ("Run: {0}" -f [string]$item.run_id)
        Write-Output ("Primary: {0} ({1})" -f [string]$item.label, [string]$item.pane_id)
        if (-not [string]::IsNullOrWhiteSpace([string]$item.task)) {
            Write-Output ("Task: {0}" -f [string]$item.task)
        }
        Write-Output ("State: {0} / {1}" -f [string]$item.task_state, [string]$item.review_state)
        Write-Output ("Next: {0}" -f [string]$item.next_action)
        if (-not [string]::IsNullOrWhiteSpace([string]$item.branch)) {
            Write-Output ("Git: {0} @ {1}" -f [string]$item.branch, [string]$item.head_short)
        }
        if ([int]$item.changed_file_count -gt 0) {
            Write-Output ("Changed files ({0}):" -f [int]$item.changed_file_count)
            foreach ($changedFile in @($item.changed_files)) {
                Write-Output ("- {0}" -f [string]$changedFile)
            }
        } else {
            Write-Output "Changed files: (none)"
        }
        Write-Output ""
    }
}

function Get-InboxPayload {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $boardPayload = Get-BoardPayload -ProjectDir $ProjectDir
    $itemsByKey = [ordered]@{}

    foreach ($pane in @($boardPayload.panes)) {
        $paneKeyBase = if (-not [string]::IsNullOrWhiteSpace([string]$pane.pane_id)) { [string]$pane.pane_id } else { [string]$pane.label }
        $reviewState = [string]$pane.review_state
        $taskState = [string]$pane.task_state

        if ($reviewState -eq 'PENDING') {
            $key = "manifest:review_pending:$paneKeyBase"
            $itemsByKey[$key] = New-InboxItem `
                -Kind 'review_pending' `
                -Message ("{0} が review 待機中。" -f [string]$pane.label) `
                -Label ([string]$pane.label) `
                -PaneId ([string]$pane.pane_id) `
                -Role ([string]$pane.role) `
                -TaskId ([string]$pane.task_id) `
                -Task ([string]$pane.task) `
                -TaskState $taskState `
                -ReviewState $reviewState `
                -Branch ([string]$pane.branch) `
                -HeadSha ([string]$pane.head_sha) `
                -Event ([string]$pane.last_event) `
                -Timestamp ([string]$pane.last_event_at) `
                -Source 'manifest' `
                -ChangedFileCount ([int]$pane.changed_file_count)
        }

        if ($reviewState -in @('FAIL', 'FAILED')) {
            $key = "manifest:review_failed:$paneKeyBase"
            $itemsByKey[$key] = New-InboxItem `
                -Kind 'review_failed' `
                -Message ("{0} の review が FAIL。" -f [string]$pane.label) `
                -Label ([string]$pane.label) `
                -PaneId ([string]$pane.pane_id) `
                -Role ([string]$pane.role) `
                -TaskId ([string]$pane.task_id) `
                -Task ([string]$pane.task) `
                -TaskState $taskState `
                -ReviewState $reviewState `
                -Branch ([string]$pane.branch) `
                -HeadSha ([string]$pane.head_sha) `
                -Event ([string]$pane.last_event) `
                -Timestamp ([string]$pane.last_event_at) `
                -Source 'manifest' `
                -ChangedFileCount ([int]$pane.changed_file_count)
        }

        if ($taskState -eq 'blocked') {
            $key = "manifest:task_blocked:$paneKeyBase"
            $itemsByKey[$key] = New-InboxItem `
                -Kind 'task_blocked' `
                -Message ("{0} が blocked。" -f [string]$pane.label) `
                -Label ([string]$pane.label) `
                -PaneId ([string]$pane.pane_id) `
                -Role ([string]$pane.role) `
                -TaskId ([string]$pane.task_id) `
                -Task ([string]$pane.task) `
                -TaskState $taskState `
                -ReviewState $reviewState `
                -Branch ([string]$pane.branch) `
                -HeadSha ([string]$pane.head_sha) `
                -Event ([string]$pane.last_event) `
                -Timestamp ([string]$pane.last_event_at) `
                -Source 'manifest' `
                -ChangedFileCount ([int]$pane.changed_file_count)
        }
    }

    $eventRecords = @(Get-InboxActiveEventRecords -ProjectDir $ProjectDir)
    foreach ($eventRecord in $eventRecords) {
        $item = ConvertTo-InboxEventItem -EventRecord $eventRecord
        if ($null -eq $item) {
            continue
        }

        $paneKeyBase = if (-not [string]::IsNullOrWhiteSpace([string]$item.pane_id)) { [string]$item.pane_id } else { [string]$item.label }
        $key = "events:{0}:{1}" -f [string]$item.kind, $paneKeyBase
        $itemsByKey[$key] = $item
    }

    $items = @($itemsByKey.Values | Sort-Object @{ Expression = { [int]$_.priority } }, @{ Expression = { [string]$_.timestamp } ; Descending = $true }, @{ Expression = { [string]$_.label } })
    $byKind = [ordered]@{}
    foreach ($item in $items) {
        $kind = [string]$item.kind
        if ([string]::IsNullOrWhiteSpace($kind)) {
            $kind = 'unknown'
        }

        if ($byKind.Contains($kind)) {
            $byKind[$kind] = [int]$byKind[$kind] + 1
        } else {
            $byKind[$kind] = 1
        }
    }

    return [ordered]@{
        generated_at = (Get-Date).ToString('o')
        project_dir  = $ProjectDir
        summary      = [ordered]@{
            item_count = $items.Count
            by_kind    = $byKind
        }
        items        = $items
    }
}

function Write-InboxStreamItem {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [switch]$Json
    )

    if ($Json) {
        $Item | ConvertTo-Json -Compress -Depth 10 | Write-Output
        return
    }

    $timestamp = [string]$Item.timestamp
    if ([string]::IsNullOrWhiteSpace($timestamp)) {
        $timestamp = (Get-Date).ToString('o')
    }

    $label = [string]$Item.label
    $paneId = [string]$Item.pane_id
    $prefix = if (-not [string]::IsNullOrWhiteSpace($label) -and -not [string]::IsNullOrWhiteSpace($paneId)) {
        '{0} ({1})' -f $label, $paneId
    } elseif (-not [string]::IsNullOrWhiteSpace($label)) {
        $label
    } else {
        $paneId
    }

    if (-not [string]::IsNullOrWhiteSpace($prefix)) {
        Write-Output ("[{0}] {1} {2}: {3}" -f $timestamp, [string]$Item.kind, $prefix, [string]$Item.message)
    } else {
        Write-Output ("[{0}] {1}: {2}" -f $timestamp, [string]$Item.kind, [string]$Item.message)
    }
}

function Invoke-Inbox {
    param(
        [AllowNull()][string]$InboxTarget = $Target,
        [AllowNull()][string[]]$InboxRest = $Rest
    )

    $tokens = @()
    if (-not [string]::IsNullOrWhiteSpace($InboxTarget)) {
        $tokens += $InboxTarget
    }
    if ($InboxRest) {
        $tokens += @($InboxRest)
    }

    $jsonOutput = $false
    $streamOutput = $false

    foreach ($token in $tokens) {
        switch ($token) {
            '--json'   { $jsonOutput = $true }
            '--stream' { $streamOutput = $true }
            default    { Stop-WithError "usage: winsmux inbox [--json] [--stream]" }
        }
    }

    $projectDir = (Get-Location).Path
    if ($streamOutput) {
        $snapshot = Get-InboxPayload -ProjectDir $projectDir
        foreach ($item in @($snapshot.items)) {
            Write-InboxStreamItem -Item $item -Json:$jsonOutput
        }

        $cursor = Get-InboxStreamStartCursor -ProjectDir $projectDir
        while ($true) {
            $delta = Get-BridgeEventDelta -ProjectDir $projectDir -Cursor $cursor
            $cursor = [int]$delta.cursor
            foreach ($eventRecord in @($delta.events)) {
                $item = ConvertTo-InboxEventItem -EventRecord $eventRecord
                if ($null -eq $item) {
                    continue
                }

                Write-InboxStreamItem -Item $item -Json:$jsonOutput
            }

            Start-Sleep -Seconds 2
        }
    }

    $payload = Get-InboxPayload -ProjectDir $projectDir
    if ($jsonOutput) {
        $payload | ConvertTo-Json -Compress -Depth 10 | Write-Output
        return
    }

    $items = @($payload.items)
    if ($items.Count -eq 0) {
        Write-Output "(no inbox items)"
        return
    }

    $table = $items |
        Select-Object `
            @{ Name = 'Kind'; Expression = { $_.kind } }, `
            @{ Name = 'Label'; Expression = { $_.label } }, `
            @{ Name = 'PaneId'; Expression = { $_.pane_id } }, `
            @{ Name = 'Role'; Expression = { $_.role } }, `
            @{ Name = 'TaskState'; Expression = { $_.task_state } }, `
            @{ Name = 'Review'; Expression = { $_.review_state } }, `
            @{ Name = 'Branch'; Expression = { $_.branch } }, `
            @{ Name = 'Message'; Expression = { $_.message } } |
        Format-Table -AutoSize |
        Out-String -Width 4096

    Write-Output ($table.TrimEnd())
}

function Invoke-Runs {
    param(
        [AllowNull()][string]$RunsTarget = $Target,
        [AllowNull()][string[]]$RunsRest = $Rest
    )

    $jsonOutput = $false

    if ($RunsTarget) {
        if ($RunsTarget -eq '--json' -and (-not $RunsRest -or $RunsRest.Count -eq 0)) {
            $jsonOutput = $true
        } else {
            Stop-WithError "usage: winsmux runs [--json]"
        }
    } elseif ($RunsRest -and $RunsRest.Count -gt 0) {
        Stop-WithError "usage: winsmux runs [--json]"
    }

    $projectDir = (Get-Location).Path
    $payload = Get-RunsPayload -ProjectDir $projectDir

    if ($jsonOutput) {
        $payload | ConvertTo-Json -Compress -Depth 10 | Write-Output
        return
    }

    $runs = @($payload.runs)
    if ($runs.Count -eq 0) {
        Write-Output "(no runs)"
        return
    }

    $table = $runs |
        Select-Object `
            @{ Name = 'RunId'; Expression = { $_.run_id } }, `
            @{ Name = 'Label'; Expression = { $_.primary_label } }, `
            @{ Name = 'Task'; Expression = { $_.task } }, `
            @{ Name = 'TaskState'; Expression = { $_.task_state } }, `
            @{ Name = 'Review'; Expression = { $_.review_state } }, `
            @{ Name = 'State'; Expression = { $_.state } }, `
            @{ Name = 'Branch'; Expression = { $_.branch } }, `
            @{ Name = 'Head'; Expression = { Get-ShortHeadSha -HeadSha ([string]$_.head_sha) } }, `
            @{ Name = 'ActionItems'; Expression = { @($_.action_items).Count } } |
        Format-Table -AutoSize |
        Out-String -Width 4096

    Write-Output ($table.TrimEnd())
}

function Invoke-CompareRuns {
    param(
        [AllowNull()][string]$CompareTarget = $Target,
        [AllowNull()][string[]]$CompareRest = $Rest
    )

    $tokens = @()
    if (-not [string]::IsNullOrWhiteSpace($CompareTarget)) {
        $tokens += $CompareTarget
    }
    if ($CompareRest) {
        $tokens += @($CompareRest)
    }

    $jsonOutput = $false
    $runIds = [System.Collections.Generic.List[string]]::new()
    foreach ($token in $tokens) {
        if ([string]$token -eq '--json') {
            $jsonOutput = $true
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$token)) {
            $runIds.Add([string]$token) | Out-Null
        }
    }

    if ($runIds.Count -ne 2) {
        Stop-WithError 'usage: winsmux compare-runs <left_run_id> <right_run_id> [--json]'
    }

    $projectDir = (Get-Location).Path
    $leftPayload = Get-ExplainPayload -ProjectDir $projectDir -RunId ([string]$runIds[0])
    $rightPayload = Get-ExplainPayload -ProjectDir $projectDir -RunId ([string]$runIds[1])
    $payload = ConvertTo-CompareRunsPayload -LeftPayload $leftPayload -RightPayload $rightPayload

    if ($jsonOutput) {
        $payload | ConvertTo-Json -Compress -Depth 12 | Write-Output
        return
    }

    Write-Output ("Compare: {0} vs {1}" -f [string]$payload.left.run_id, [string]$payload.right.run_id)
    Write-Output ("Shared changed files: {0}" -f (@($payload.shared_changed_files).Count))
    if ($null -ne $payload.confidence_delta) {
        Write-Output ("Confidence delta: {0}" -f [string]$payload.confidence_delta)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$payload.recommend.winning_run_id)) {
        Write-Output ("Winning run: {0}" -f [string]$payload.recommend.winning_run_id)
    }
    Write-Output ("Next action: {0}" -f [string]$payload.recommend.next_action)
    if (@($payload.differences).Count -gt 0) {
        Write-Output 'Differences:'
        foreach ($difference in @($payload.differences)) {
            $leftValue = if ($difference.left -is [System.Array]) { (($difference.left | ForEach-Object { [string]$_ }) -join ', ') } else { [string]$difference.left }
            $rightValue = if ($difference.right -is [System.Array]) { (($difference.right | ForEach-Object { [string]$_ }) -join ', ') } else { [string]$difference.right }
            Write-Output ("- {0}: left={1} right={2}" -f [string]$difference.field, $leftValue, $rightValue)
        }
    } else {
        Write-Output 'Differences: (none)'
    }
}

function Invoke-Compare {
    param(
        [AllowNull()][string]$CompareTarget = $Target,
        [AllowNull()][string[]]$CompareRest = $Rest
    )

    $tokens = @()
    if (-not [string]::IsNullOrWhiteSpace($CompareTarget)) {
        $tokens += $CompareTarget
    }
    if ($CompareRest) {
        $tokens += @($CompareRest)
    }

    if ($tokens.Count -lt 1) {
        Stop-WithError 'usage: winsmux compare <runs|preflight|promote> ... [--json]'
    }

    $mode = ([string]$tokens[0]).Trim().ToLowerInvariant()
    $remaining = @()
    if ($tokens.Count -gt 1) {
        $remaining = @($tokens | Select-Object -Skip 1)
    }

    switch ($mode) {
        'runs' {
            $runTarget = if ($remaining.Count -gt 0) { [string]$remaining[0] } else { '' }
            $runRest = if ($remaining.Count -gt 1) { @($remaining | Select-Object -Skip 1) } else { @() }
            Invoke-CompareRuns -CompareTarget $runTarget -CompareRest $runRest
            return
        }
        'preflight' {
            $preflightTarget = if ($remaining.Count -gt 0) { [string]$remaining[0] } else { '' }
            $preflightRest = if ($remaining.Count -gt 1) { @($remaining | Select-Object -Skip 1) } else { @() }
            Invoke-ConflictPreflight -PreflightTarget $preflightTarget -PreflightRest $preflightRest -CompareAlias
            return
        }
        'promote' {
            $promoteTarget = if ($remaining.Count -gt 0) { [string]$remaining[0] } else { '' }
            $promoteRest = if ($remaining.Count -gt 1) { @($remaining | Select-Object -Skip 1) } else { @() }
            Invoke-PromoteTactic -PromoteTarget $promoteTarget -PromoteRest $promoteRest
            return
        }
        default {
            Stop-WithError 'usage: winsmux compare <runs|preflight|promote> ... [--json]'
        }
    }
}

function Invoke-ConflictPreflight {
    param(
        [AllowNull()][string]$PreflightTarget = $Target,
        [AllowNull()][string[]]$PreflightRest = $Rest,
        [switch]$CompareAlias
    )

    $tokens = @()
    if (-not [string]::IsNullOrWhiteSpace($PreflightTarget)) {
        $tokens += $PreflightTarget
    }
    if ($PreflightRest) {
        $tokens += @($PreflightRest)
    }

    $jsonOutput = $false
    $refs = [System.Collections.Generic.List[string]]::new()
    foreach ($token in $tokens) {
        if ([string]$token -eq '--json') {
            $jsonOutput = $true
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$token)) {
            $refs.Add([string]$token) | Out-Null
        }
    }

    if ($refs.Count -ne 2) {
        if ($CompareAlias) {
            Stop-WithError 'usage: winsmux compare preflight <left_ref> <right_ref> [--json]'
        }

        Stop-WithError 'usage: winsmux conflict-preflight <left_ref> <right_ref> [--json]'
    }

    $payload = Get-WinsmuxConflictPreflightPayload -ProjectDir (Get-Location).Path -LeftRef ([string]$refs[0]) -RightRef ([string]$refs[1])
    if ($CompareAlias) {
        $payload.command = 'compare preflight'
        $payload.next_action = ([string]$payload.next_action) -replace 'winsmux conflict-preflight', 'winsmux compare preflight'
    }
    if ($jsonOutput) {
        $payload | ConvertTo-Json -Compress -Depth 10 | Write-Output
        return
    }

    $preflightLabel = if ($CompareAlias) { 'compare preflight' } else { 'conflict preflight' }
    Write-Output ("{0}: {1}" -f $preflightLabel, [string]$payload.status)
    Write-Output ("left: {0} ({1})" -f [string]$payload.left_ref, (Get-ShortHeadSha -HeadSha ([string]$payload.left_sha)))
    Write-Output ("right: {0} ({1})" -f [string]$payload.right_ref, (Get-ShortHeadSha -HeadSha ([string]$payload.right_sha)))
    if (-not [string]::IsNullOrWhiteSpace([string]$payload.merge_base)) {
        Write-Output ("merge-base: {0}" -f (Get-ShortHeadSha -HeadSha ([string]$payload.merge_base)))
    }
    Write-Output ("overlap paths: {0}" -f (@($payload.overlap_paths).Count))
    if (@($payload.overlap_paths).Count -gt 0) {
        foreach ($path in @($payload.overlap_paths)) {
            Write-Output ("- {0}" -f [string]$path)
        }
    }
    Write-Output ("next: {0}" -f [string]$payload.next_action)
}

function Invoke-PromoteTactic {
    param(
        [AllowNull()][string]$PromoteTarget = $Target,
        [AllowNull()][string[]]$PromoteRest = $Rest
    )

    $tokens = @()
    if (-not [string]::IsNullOrWhiteSpace($PromoteTarget)) {
        $tokens += $PromoteTarget
    }
    if ($PromoteRest) {
        $tokens += @($PromoteRest)
    }

    if ($tokens.Count -eq 0) {
        Stop-WithError 'usage: winsmux promote-tactic <run_id> [--title <text>] [--kind <playbook|prewarm|verification>] [--json]'
    }

    $runId = ''
    $title = ''
    $kind = 'playbook'
    $jsonOutput = $false

    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = [string]$tokens[$i]
        switch ($token) {
            '--json' { $jsonOutput = $true }
            '--title' {
                if ($i + 1 -ge $tokens.Count) {
                    Stop-WithError '--title requires a value'
                }
                $title = [string]$tokens[$i + 1]
                $i++
            }
            '--kind' {
                if ($i + 1 -ge $tokens.Count) {
                    Stop-WithError '--kind requires a value'
                }
                $kind = [string]$tokens[$i + 1]
                $i++
            }
            default {
                if ([string]::IsNullOrWhiteSpace($runId)) {
                    $runId = [string]$token
                } else {
                    Stop-WithError 'usage: winsmux promote-tactic <run_id> [--title <text>] [--kind <playbook|prewarm|verification>] [--json]'
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($runId)) {
        Stop-WithError 'usage: winsmux promote-tactic <run_id> [--title <text>] [--kind <playbook|prewarm|verification>] [--json]'
    }
    if ($kind -notin @('playbook', 'prewarm', 'verification')) {
        Stop-WithError "Unsupported promote kind: $kind"
    }

    $projectDir = (Get-Location).Path
    $explainPayload = Get-ExplainPayload -ProjectDir $projectDir -RunId $runId
    if (-not (Test-RunPromotable -Run $explainPayload.run)) {
        Stop-WithError "run is not promotable: $runId"
    }

    $payload = Get-PromoteTacticPayload -ExplainPayload $explainPayload -Title $title -Kind $kind
    $artifact = New-PlaybookCandidateFile -ProjectDir $projectDir -PlaybookCandidate $payload
    $result = [ordered]@{
        generated_at = (Get-Date).ToString('o')
        run_id       = [string]$runId
        candidate_ref = [string]$artifact.reference
        candidate_path = [string]$artifact.path
        candidate    = Read-WinsmuxArtifactJson -Reference ([string]$artifact.reference) -ProjectDir $projectDir -ExpectedDirectoryPath (Get-PlaybookCandidateDirectory -ProjectDir $projectDir) -ExpectedRunId $runId
    }

    if ($jsonOutput) {
        $result | ConvertTo-Json -Compress -Depth 12 | Write-Output
        return
    }

    Write-Output ("promoted tactic from {0} -> {1}" -f [string]$runId, [string]$artifact.reference)
}

function Invoke-Explain {
    param(
        [AllowNull()][string]$ExplainTarget = $Target,
        [AllowNull()][string[]]$ExplainRest = $Rest
    )

    $tokens = @()
    if (-not [string]::IsNullOrWhiteSpace($ExplainTarget)) {
        $tokens += $ExplainTarget
    }
    if ($ExplainRest) {
        $tokens += @($ExplainRest)
    }

    if ($tokens.Count -eq 0) {
        Stop-WithError "usage: winsmux explain <run_id> [--json] [--follow]"
    }

    $runId = ''
    $jsonOutput = $false
    $followOutput = $false

    foreach ($token in $tokens) {
        switch ($token) {
            '--json'   { $jsonOutput = $true }
            '--follow' { $followOutput = $true }
            default {
                if ([string]::IsNullOrWhiteSpace($runId)) {
                    $runId = [string]$token
                } else {
                    Stop-WithError "usage: winsmux explain <run_id> [--json] [--follow]"
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($runId)) {
        Stop-WithError "usage: winsmux explain <run_id> [--json] [--follow]"
    }

    $projectDir = (Get-Location).Path
    $payload = Get-ExplainPayload -ProjectDir $projectDir -RunId $runId

    if ($followOutput) {
        if ($jsonOutput) {
            $payload | ConvertTo-Json -Compress -Depth 10 | Write-Output
        } else {
            Write-Output ("Run: {0}" -f [string]$payload.run.run_id)
            Write-Output ("Task: {0}" -f [string]$payload.explanation.summary)
            Write-Output ("State: {0} / {1} / {2}" -f [string]$payload.run.state, [string]$payload.run.task_state, [string]$payload.run.review_state)
            if (-not [string]::IsNullOrWhiteSpace([string]$payload.run.branch)) {
                Write-Output ("Branch: {0}" -f [string]$payload.run.branch)
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$payload.run.head_sha)) {
                Write-Output ("Head: {0}" -f [string]$payload.run.head_sha)
            }
        }

        $cursor = @(Get-BridgeEventRecords -ProjectDir $projectDir).Count
        while ($true) {
            $delta = Get-BridgeEventDelta -ProjectDir $projectDir -Cursor $cursor
            $cursor = [int]$delta.cursor
            foreach ($eventRecord in @($delta.events)) {
                if (-not (Test-RunMatchesEventRecord -Run $payload.run -EventRecord $eventRecord)) {
                    continue
                }

                $item = ConvertTo-RunEventRecord -EventRecord $eventRecord -ProjectDir $projectDir
                Write-ExplainFollowItem -Item $item -Json:$jsonOutput
            }

            Start-Sleep -Seconds 2
        }
    }

    if ($jsonOutput) {
        $payload | ConvertTo-Json -Compress -Depth 10 | Write-Output
        return
    }

    Write-Output ("Run: {0}" -f [string]$payload.run.run_id)
    Write-Output ("Task: {0}" -f [string]$payload.explanation.summary)
    Write-Output ("Primary: {0} ({1})" -f [string]$payload.run.primary_label, [string]$payload.run.primary_pane_id)
    Write-Output ("State: {0} / {1} / {2}" -f [string]$payload.run.state, [string]$payload.run.task_state, [string]$payload.run.review_state)
    Write-Output ("Next: {0}" -f [string]$payload.evidence_digest.next_action)
    if (-not [string]::IsNullOrWhiteSpace([string]$payload.run.branch)) {
        Write-Output ("Branch: {0}" -f [string]$payload.run.branch)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$payload.run.head_sha)) {
        Write-Output ("Head: {0}" -f [string]$payload.run.head_sha)
    }
    if ([int]$payload.evidence_digest.changed_file_count -gt 0) {
        Write-Output "Changed files:"
        foreach ($changedFile in @($payload.evidence_digest.changed_files)) {
            Write-Output ("- {0}" -f [string]$changedFile)
        }
    }
    if (@($payload.explanation.reasons).Count -gt 0) {
        Write-Output "Reasons:"
        foreach ($reason in @($payload.explanation.reasons)) {
            Write-Output ("- {0}" -f [string]$reason)
        }
    }
    if (@($payload.recent_events).Count -gt 0) {
        Write-Output "Recent events:"
        foreach ($eventRecord in @($payload.recent_events | Select-Object -First 10)) {
            Write-Output ("- [{0}] {1} {2}: {3}" -f [string]$eventRecord.timestamp, [string]$eventRecord.event, [string]$eventRecord.label, [string]$eventRecord.message)
        }
    }
}

function Invoke-PollEvents {
    if ($Rest -and $Rest.Count -gt 0) {
        Stop-WithError "usage: winsmux poll-events [cursor]"
    }

    $cursor = 0
    if ($Target) {
        $parsedCursor = 0
        if (-not [int]::TryParse($Target, [ref]$parsedCursor)) {
            Stop-WithError "usage: winsmux poll-events [cursor]"
        }

        if ($parsedCursor -gt 0) {
            $cursor = $parsedCursor
        }
    }

    $eventsPath = Get-BridgeEventsPath -ProjectDir (Get-Location).Path
    $response = [ordered]@{
        cursor = 0
        events = @()
    }

    if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) {
        $response | ConvertTo-Json -Compress -Depth 10 | Write-Output
        return
    }

    try {
        $lines = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
        Stop-WithError "failed to read event log: $($_.Exception.Message)"
    }

    if ($cursor -gt $lines.Count) {
        $cursor = $lines.Count
    }

    $events = [System.Collections.Generic.List[object]]::new()
    for ($i = $cursor; $i -lt $lines.Count; $i++) {
        try {
            $events.Add(($lines[$i] | ConvertFrom-Json -AsHashtable -ErrorAction Stop)) | Out-Null
        } catch {
            Stop-WithError "failed to parse event log line $($i + 1): $($_.Exception.Message)"
        }
    }

    $response.cursor = $lines.Count
    $response.events = @($events)
    $response | ConvertTo-Json -Compress -Depth 10 | Write-Output
}

function Invoke-Focus {
    param([string]$FocusTarget = $Target)

    if (-not $FocusTarget) { Stop-WithError "usage: winsmux focus <label|target>" }

    $paneId = Resolve-Target $FocusTarget
    $paneId = Confirm-Target $paneId
    Assert-FocusAllowed -PaneId $paneId -RawTarget $FocusTarget

    Invoke-WinsmuxRaw -Arguments @('select-pane', '-t', $paneId)
    Write-Output "Focused pane $paneId ($FocusTarget)"
}

function Invoke-FocusLock {
    param([string]$FocusTarget = $Target)

    if (-not $FocusTarget) { Stop-WithError "usage: winsmux focus-lock <label|target>" }

    $paneId = Resolve-Target $FocusTarget
    $paneId = Confirm-Target $paneId
    $entry = Push-FocusPolicy -PaneId $paneId -TargetName $FocusTarget

    Write-Output "Focus locked to $($entry.paneId) ($($entry.target))"
}

function Invoke-FocusUnlock {
    param(
        [string]$FocusTarget = $Target,
        [string[]]$ExtraArgs = $Rest
    )

    if ($FocusTarget -or ($ExtraArgs -and $ExtraArgs.Count -gt 0)) {
        Stop-WithError "usage: winsmux focus-unlock"
    }

    $entry = Pop-FocusPolicy
    if ($null -eq $entry) {
        Write-Output "(no focus lock)"
        return
    }

    Write-Output "Focus unlocked $($entry.paneId) ($($entry.target))"
}

function ConvertTo-ProfileAgentHashtableLiteral {
    param([Parameter(Mandatory = $true)][string]$Definition)

    $separatorIndex = $Definition.IndexOf(':')
    if ($separatorIndex -le 0 -or $separatorIndex -ge ($Definition.Length - 1)) {
        Stop-WithError "usage: winsmux profile <name> <label:agent-command> [label:agent-command...]"
    }

    $label = $Definition.Substring(0, $separatorIndex).Trim()
    $command = $Definition.Substring($separatorIndex + 1).Trim()
    if ([string]::IsNullOrWhiteSpace($label) -or [string]::IsNullOrWhiteSpace($command)) {
        Stop-WithError "usage: winsmux profile <name> <label:agent-command> [label:agent-command...]"
    }

    $adapter = ($command -split '\s+', 2)[0].Trim()
    $labelLiteral = ConvertTo-BridgePowerShellLiteral -Value $label
    $commandLiteral = ConvertTo-BridgePowerShellLiteral -Value $command
    $adapterLiteral = ConvertTo-BridgePowerShellLiteral -Value $adapter
    return "@{ label = $labelLiteral; command = $commandLiteral; adapter = $adapterLiteral }"
}

function Get-ProfileAgentGrid {
    param([Parameter(Mandatory = $true)][int]$Count)

    if ($Count -lt 1) {
        Stop-WithError 'profile agent count must be greater than zero'
    }

    $rows = [Math]::Floor([Math]::Sqrt($Count))
    while ($rows -gt 1 -and ($Count % $rows) -ne 0) {
        $rows--
    }

    [PSCustomObject]@{
        Rows = [int]$rows
        Cols = [int]($Count / $rows)
    }
}

function Invoke-Profile {
    $fragmentDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\winsmux"
    $fragmentFile = Join-Path $fragmentDir "winsmux.json"

    if (-not $Target) {
        # Show current fragment
        if (Test-Path $fragmentFile) {
            Get-Content $fragmentFile -Raw
        } else {
            Write-Host "No Windows Terminal fragment registered. Run: winsmux install"
        }
        return
    }

    # Generate custom profile fragment
    # $Target = profile name, $Rest = agent definitions like "builder:codex-nightly" "reviewer:claude --model opus"
    $profileName = $Target
    $agents = @()
    if ($Rest -and $Rest.Count -gt 0) {
        foreach ($def in $Rest) {
            $agents += $def
        }
    }

    $agentComment = ""
    if ($agents.Count -gt 0) {
        $agentComment = " # agents: $($agents -join ', ')"
    }
    $agentArgument = ''
    if ($agents.Count -gt 0) {
        $agentLiterals = @($agents | ForEach-Object { ConvertTo-ProfileAgentHashtableLiteral -Definition $_ })
        $agentGrid = Get-ProfileAgentGrid -Count $agents.Count
        $agentArgument = ' -Rows {0} -Cols {1} -Agents @({2})' -f $agentGrid.Rows, $agentGrid.Cols, ($agentLiterals -join ', ')
    }
    $profileNameLiteral = ConvertTo-BridgePowerShellLiteral -Value $profileName
    $profileCommand = "& (Join-Path `$env:USERPROFILE '.winsmux\bin\winsmux-core.ps1') doctor; winsmux new-session -s $profileNameLiteral; & (Join-Path `$env:USERPROFILE '.winsmux\bin\start-orchestra.ps1')$agentArgument"
    $encodedProfileCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($profileCommand))

    if (-not (Test-Path $fragmentDir)) {
        New-Item -ItemType Directory -Path $fragmentDir -Force | Out-Null
    }

    $fragment = @{
        profiles = @(
            @{
                name             = "winsmux $profileName"
                commandline      = "pwsh -NoProfile -EncodedCommand $encodedProfileCommand"
                icon             = "`u{1F3BC}"
                startingDirectory = "%USERPROFILE%"
                tabTitle         = "winsmux $profileName"
            }
        )
    }

    $json = $fragment | ConvertTo-Json -Depth 4
    Write-ClmSafeTextFile -Path $fragmentFile -Content $json
    Write-Output "Registered WT profile: winsmux $profileName"
    Write-Output "Fragment: $fragmentFile"
    if ($agents.Count -gt 0) {
        Write-Output "Agents: $($agents -join ', ')"
    }
}

# --- Vault Commands ---

function Invoke-VaultSet {
    $key = $Target
    $value = if ($Rest) { $Rest -join ' ' } else { '' }
    if (-not $key) { Stop-WithError "usage: winsmux vault set <key> [value]" }
    if (-not $value) {
        $secure = Read-Host -AsSecureString "Enter value for '$key'"
        $value = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    }

    $credTarget = "winsmux:$key"
    $valueBytes = [System.Text.Encoding]::Unicode.GetBytes($value)
    $blobPtr = [Runtime.InteropServices.Marshal]::AllocHGlobal($valueBytes.Length)
    [Runtime.InteropServices.Marshal]::Copy($valueBytes, 0, $blobPtr, $valueBytes.Length)

    $cred = New-Object WinCred+CREDENTIAL
    $cred.Type = [WinCred]::CRED_TYPE_GENERIC
    $cred.TargetName = $credTarget
    $cred.UserName = "winsmux"
    $cred.CredentialBlobSize = $valueBytes.Length
    $cred.CredentialBlob = $blobPtr
    $cred.Persist = [WinCred]::CRED_PERSIST_LOCAL_MACHINE

    try {
        $ok = [WinCred]::CredWrite([ref]$cred, 0)
        if (-not $ok) {
            $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Stop-WithError "CredWrite failed (error $errCode)"
        }
        Write-Host "Stored credential: $key"
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($blobPtr)
    }
}

function Invoke-VaultGet {
    $key = $Target
    if (-not $key) { Stop-WithError "usage: winsmux vault get <key>" }

    $credTarget = "winsmux:$key"
    $credPtr = [IntPtr]::Zero

    $ok = [WinCred]::CredRead($credTarget, [WinCred]::CRED_TYPE_GENERIC, 0, [ref]$credPtr)
    if (-not $ok) {
        $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errCode -eq 1168) {
            Stop-WithError "credential not found: $key"
        }
        Stop-WithError "CredRead failed (error $errCode)"
    }

    try {
        $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [Type][WinCred+CREDENTIAL])
        if ($cred.CredentialBlobSize -gt 0) {
            $bytes = New-Object byte[] $cred.CredentialBlobSize
            [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
            $value = [System.Text.Encoding]::Unicode.GetString($bytes)
            Write-Output $value
        }
    } finally {
        [WinCred]::CredFree($credPtr) | Out-Null
    }
}

function Invoke-VaultList {
    $filter = "winsmux:*"
    $count = 0
    $credsPtr = [IntPtr]::Zero

    $ok = [WinCred]::CredEnumerate($filter, 0, [ref]$count, [ref]$credsPtr)
    if (-not $ok) {
        $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errCode -eq 1168) {
            Write-Output "(no credentials stored)"
            return
        }
        Stop-WithError "CredEnumerate failed (error $errCode)"
    }

    try {
        $ptrSize = [Runtime.InteropServices.Marshal]::SizeOf([Type][IntPtr])
        for ($i = 0; $i -lt $count; $i++) {
            $entryPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($credsPtr, $i * $ptrSize)
            $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($entryPtr, [Type][WinCred+CREDENTIAL])
            $name = $cred.TargetName -replace '^winsmux:', ''
            Write-Output $name
        }
    } finally {
        [WinCred]::CredFree($credsPtr) | Out-Null
    }
}

function Invoke-VaultInject {
    if (-not $Target) { Stop-WithError "usage: winsmux vault inject <pane>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId
    Assert-ReadMark $paneId

    # Enumerate all winsmux:* credentials
    $filter = "winsmux:*"
    $count = 0
    $credsPtr = [IntPtr]::Zero

    $ok = [WinCred]::CredEnumerate($filter, 0, [ref]$count, [ref]$credsPtr)
    if (-not $ok) {
        $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errCode -eq 1168) {
            Write-Output "no credentials to inject"
            return
        }
        Stop-WithError "CredEnumerate failed (error $errCode)"
    }

    $injected = 0
    try {
        $ptrSize = [Runtime.InteropServices.Marshal]::SizeOf([Type][IntPtr])
        for ($i = 0; $i -lt $count; $i++) {
            $entryPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($credsPtr, $i * $ptrSize)
            $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($entryPtr, [Type][WinCred+CREDENTIAL])
            $envName = $cred.TargetName -replace '^winsmux:', ''

            $value = ''
            if ($cred.CredentialBlobSize -gt 0) {
                $bytes = New-Object byte[] $cred.CredentialBlobSize
                [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
                $value = [System.Text.Encoding]::Unicode.GetString($bytes)
            }

            # Escape single quotes in value for safe injection
            $escapedValue = $value -replace "'", "''"
            $setCmd = "`$env:$envName = '$escapedValue'"
            Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $paneId, '-l', '--', "$setCmd")
            Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $paneId, 'Enter')
            Start-Sleep -Milliseconds 100
            $injected++
        }
    } finally {
        [WinCred]::CredFree($credsPtr) | Out-Null
    }

    Clear-ReadMark $paneId
    Write-Output "injected $injected credential(s) into $paneId"
}

function Invoke-Version {
    Write-Output "winsmux $VERSION"
}

function Invoke-DispatchReview {
    if ($Target -or ($Rest -and $Rest.Count -gt 0)) {
        Stop-WithError "usage: winsmux dispatch-review"
    }

    Assert-WinsmuxRolePermission -CommandName 'dispatch-review'

    $projectDir = (Get-Location).Path
    $branch = Get-CurrentGitBranch -ProjectDir $projectDir
    $headSha = Get-CurrentGitHead -ProjectDir $projectDir

    $reviewPaneEntry = Get-PreferredReviewPaneEntry -ProjectDir $projectDir
    if ($null -eq $reviewPaneEntry) {
        Stop-WithError "No review-capable pane found in manifest."
    }

    $reviewPaneId = [string]$reviewPaneEntry.PaneId
    $reviewLabel = [string]$reviewPaneEntry.Label
    $reviewRole = [string]$reviewPaneEntry.Role
    Write-Output "Dispatching review to $reviewLabel [$reviewPaneId] for branch $branch ($($headSha.Substring(0,7)))"

    Send-TextToPane -PaneId $reviewPaneId -CommandText "winsmux review-request"

    Write-Output "review-request sent to $reviewLabel. Waiting for PENDING state..."

    # Poll for PENDING state (up to 30 seconds)
    $maxAttempts = 10
    $pending = $false
    for ($i = 0; $i -lt $maxAttempts; $i++) {
        Start-Sleep -Seconds 3
        $state = Get-ReviewState -ProjectDir $projectDir
        if ($state.Contains($branch)) {
            $stateEntry = ConvertTo-ReviewStateValue -Value $state[$branch]
            $status = [string](Get-ReviewStatePropertyValue -InputObject $stateEntry -Name 'status')
            if ($status -eq 'PENDING') {
                $pending = $true
                break
            }
        }
    }

    if (-not $pending) {
        Stop-WithError "review-request was not recorded after ${maxAttempts} attempts. Check review pane $reviewPaneId."
    }

    Write-Output "PENDING confirmed. $reviewRole pane will run review-approve or review-fail. Monitor review-state.json for result."
}

function Get-DispatchTaskManifestEntry {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (Get-Command Get-PaneControlManifestEntries -ErrorAction SilentlyContinue) {
        $entry = @(Get-PaneControlManifestEntries -ProjectDir $ProjectDir | Where-Object { [string]$_.Label -eq $Label } | Select-Object -First 1)[0]
        if ($null -ne $entry) {
            return $entry
        }
    }

    $labels = Get-Labels
    if ($labels.ContainsKey($Label)) {
        return [PSCustomObject]@{
            Label  = $Label
            PaneId = [string]$labels[$Label]
            Role   = ''
        }
    }

    return $null
}

function Test-DispatchTaskReviewerManifestEntry {
    param([AllowNull()]$Entry = $null)

    if ($null -eq $Entry) {
        return $false
    }

    $role = [string](Get-SendConfigValue -InputObject $Entry -Name 'Role' -Default '')
    $workerRole = [string](Get-SendConfigValue -InputObject $Entry -Name 'WorkerRole' -Default '')
    $agentRole = [string](Get-SendConfigValue -InputObject $Entry -Name 'AgentRole' -Default '')

    return (
        [string]::Equals($role, 'Reviewer', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($workerRole, 'reviewer', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($agentRole, 'reviewer', [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Get-DispatchTaskAvailableTargets {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $availableTargets = @()
    $manifestTargetsResolved = $false
    if (Get-Command Get-PaneControlManifestEntries -ErrorAction SilentlyContinue) {
        try {
            $manifestEntries = @(Get-PaneControlManifestEntries -ProjectDir $ProjectDir)
            $manifestTargetsResolved = $true
            $availableTargets = @(
                $manifestEntries |
                    Where-Object { -not (Test-DispatchTaskReviewerManifestEntry -Entry $_) } |
                    ForEach-Object { [string]$_.Label } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        } catch {
            $manifestTargetsResolved = $false
        }
    }
    if (-not $manifestTargetsResolved -and $availableTargets.Count -eq 0) {
        $availableTargets = @((Get-Labels).Keys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return @($availableTargets)
}

function Invoke-DispatchTask {
    $parts = @(
        @($Target) + @($Rest) |
            Where-Object { $_ } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    if ($parts.Count -lt 1) {
        Stop-WithError "usage: winsmux dispatch-task <text>"
    }

    $taskText = $parts -join ' '
    $projectDir = (Get-Location).Path
    $routerScript = Join-Path $PSScriptRoot '..\winsmux-core\scripts\dispatch-router.ps1'
    if (-not (Test-Path -LiteralPath $routerScript -PathType Leaf)) {
        Stop-WithError "dispatch router not found: $routerScript"
    }

    . $routerScript

    $availableTargets = @(Get-DispatchTaskAvailableTargets -ProjectDir $projectDir)

    $route = Get-DispatchRoute -Text $taskText -AvailableTargets $availableTargets -DefaultRole 'Worker'
    if ($route.HandleLocally) {
        Stop-WithError "dispatch-task routed to Operator. Refine the task text so it can be delegated to a managed pane."
    }

    $selectedLabel = [string]$route.SelectedTarget
    $paneId = ''
    $resolvedRole = [string]$route.SelectedRole

    if ($resolvedRole -eq 'Reviewer') {
        $reviewEntry = Get-PreferredReviewPaneEntry -ProjectDir $projectDir
        if ($null -eq $reviewEntry) {
            Stop-WithError "No review-capable pane found in manifest."
        }

        $selectedLabel = [string]$reviewEntry.Label
        $paneId = [string]$reviewEntry.PaneId
        Start-DeferredPaneFromManifestEntry -ProjectDir $projectDir -ManifestEntry $reviewEntry | Out-Null
    } else {
        $manifestEntry = Get-DispatchTaskManifestEntry -ProjectDir $projectDir -Label $selectedLabel
        if ($null -eq $manifestEntry -or [string]::IsNullOrWhiteSpace([string]$manifestEntry.PaneId)) {
            Stop-WithError "dispatch-task could not resolve target '$selectedLabel' to a pane."
        }

        $paneId = [string]$manifestEntry.PaneId
        Start-DeferredPaneFromManifestEntry -ProjectDir $projectDir -ManifestEntry $manifestEntry | Out-Null
    }

    Send-TextToPane -PaneId $paneId -CommandText $taskText
    Write-Output ("Dispatched to {0} [{1}] as {2}. {3}" -f $selectedLabel, $paneId, $resolvedRole, [string]$route.Reason)
}

function Invoke-ReviewRequest {
    if ($Target -or ($Rest -and $Rest.Count -gt 0)) {
        Stop-WithError "usage: winsmux review-request"
    }

    Assert-WinsmuxRolePermission -CommandName 'review-request'

    $projectDir = (Get-Location).Path
    $branch = Get-CurrentGitBranch -ProjectDir $projectDir
    $headSha = Get-CurrentGitHead -ProjectDir $projectDir
    $context = Get-CurrentReviewPaneManifestContext -ProjectDir $projectDir
    $timestamp = (Get-Date).ToString('o')
    $state = Get-ReviewState -ProjectDir $projectDir

    $request = [ordered]@{
        id                      = New-ReviewRequestId
        branch                  = $branch
        head_sha                = $headSha
        target_review_pane_id   = $context.PaneId
        target_review_label     = $context.Label
        target_review_role      = $context.Role
        target_reviewer_pane_id = $context.PaneId
        target_reviewer_label   = $context.Label
        target_reviewer_role    = $context.Role
        review_contract         = New-ReviewContractRecord
        dispatched_at           = $timestamp
    }

    $reviewer = [ordered]@{
        pane_id    = $context.PaneId
        label      = $context.Label
        role       = $context.Role
        agent_name = [string]$env:WINSMUX_AGENT_NAME
    }

    $state[$branch] = New-ReviewerStateRecord -Status 'PENDING' -Request $request -Reviewer $reviewer -Evidence $null -UpdatedAt $timestamp
    Save-ReviewState -ProjectDir $projectDir -State $state
    Update-ReviewPaneManifestState -ProjectDir $projectDir -Properties ([ordered]@{
        review_state = 'pending'
        task_owner   = $context.Role
        branch       = $branch
        head_sha     = $headSha
        last_event   = 'review.requested'
        last_event_at = $timestamp
    })
    Write-Output "review request recorded for $branch"
}

function Invoke-ReviewApprove {
    if ($Target -or ($Rest -and $Rest.Count -gt 0)) {
        Stop-WithError "usage: winsmux review-approve"
    }

    Assert-WinsmuxRolePermission -CommandName 'review-approve'

    $projectDir = (Get-Location).Path
    $branch = Get-CurrentGitBranch -ProjectDir $projectDir
    $headSha = Get-CurrentGitHead -ProjectDir $projectDir
    $context = Get-CurrentReviewPaneManifestContext -ProjectDir $projectDir
    $state = Get-ReviewState -ProjectDir $projectDir

    if (-not $state.Contains($branch)) {
        Stop-WithError "review request pending for $branch was not found. Run: winsmux review-request"
    }

    $entry = ConvertTo-ReviewStateValue -Value $state[$branch]
    $request = ConvertTo-ReviewStateValue -Value (Get-ReviewStatePropertyValue -InputObject $entry -Name 'request')
    $status = [string](Get-ReviewStatePropertyValue -InputObject $entry -Name 'status')

    if ($null -eq $request -or $status -ne 'PENDING') {
        Stop-WithError "review request pending for $branch was not found. Run: winsmux review-request"
    }
    if (-not (Test-ReviewContractPresent -Request $request)) {
        Stop-WithError "pending review request for $branch is missing review_contract. Re-run: winsmux review-request"
    }

    $requestPaneId = [string](Get-ReviewRequestTargetValue -Request $request -Name 'pane_id')
    $requestBranch = [string](Get-ReviewStatePropertyValue -InputObject $request -Name 'branch')
    $requestHeadSha = [string](Get-ReviewStatePropertyValue -InputObject $request -Name 'head_sha')

    if ($requestPaneId -ne $context.PaneId) {
        Stop-WithError "pending review request for $branch is assigned to $requestPaneId, not $($context.PaneId)"
    }

    if ($requestBranch -ne $branch) {
        Stop-WithError "pending review request branch mismatch: expected $requestBranch, got $branch"
    }

    if ($requestHeadSha -ne $headSha) {
        Stop-WithError "pending review request head mismatch: expected $requestHeadSha, got $headSha"
    }

    $timestamp = (Get-Date).ToString('o')
    $reviewer = [ordered]@{
        pane_id    = $context.PaneId
        label      = $context.Label
        role       = $context.Role
        agent_name = [string]$env:WINSMUX_AGENT_NAME
    }
    $evidence = [ordered]@{
        approved_at             = $timestamp
        approved_via            = 'winsmux review-approve'
        review_contract_snapshot = Get-ReviewStatePropertyValue -InputObject $request -Name 'review_contract'
    }

    $state[$branch] = New-ReviewerStateRecord -Status 'PASS' -Request $request -Reviewer $reviewer -Evidence $evidence -UpdatedAt $timestamp
    Save-ReviewState -ProjectDir $projectDir -State $state
    Update-ReviewPaneManifestState -ProjectDir $projectDir -Properties ([ordered]@{
        review_state = 'pass'
        task_owner   = 'Operator'
        branch       = $branch
        head_sha     = $headSha
        last_event   = 'review.pass'
        last_event_at = $timestamp
    })
    Write-Output "review PASS recorded for $branch"
}

function Invoke-ReviewFail {
    if ($Target -or ($Rest -and $Rest.Count -gt 0)) {
        Stop-WithError "usage: winsmux review-fail"
    }

    Assert-WinsmuxRolePermission -CommandName 'review-fail'

    $projectDir = (Get-Location).Path
    $branch = Get-CurrentGitBranch -ProjectDir $projectDir
    $headSha = Get-CurrentGitHead -ProjectDir $projectDir
    $context = Get-CurrentReviewPaneManifestContext -ProjectDir $projectDir
    $state = Get-ReviewState -ProjectDir $projectDir

    if (-not $state.Contains($branch)) {
        Stop-WithError "review request pending for $branch was not found. Run: winsmux review-request"
    }

    $entry = ConvertTo-ReviewStateValue -Value $state[$branch]
    $request = ConvertTo-ReviewStateValue -Value (Get-ReviewStatePropertyValue -InputObject $entry -Name 'request')
    $status = [string](Get-ReviewStatePropertyValue -InputObject $entry -Name 'status')

    if ($null -eq $request -or $status -ne 'PENDING') {
        Stop-WithError "review request pending for $branch was not found. Run: winsmux review-request"
    }
    if (-not (Test-ReviewContractPresent -Request $request)) {
        Stop-WithError "pending review request for $branch is missing review_contract. Re-run: winsmux review-request"
    }

    $requestPaneId = [string](Get-ReviewRequestTargetValue -Request $request -Name 'pane_id')
    $requestBranch = [string](Get-ReviewStatePropertyValue -InputObject $request -Name 'branch')
    $requestHeadSha = [string](Get-ReviewStatePropertyValue -InputObject $request -Name 'head_sha')

    if ($requestPaneId -ne $context.PaneId) {
        Stop-WithError "pending review request for $branch is assigned to $requestPaneId, not $($context.PaneId)"
    }

    if ($requestBranch -ne $branch) {
        Stop-WithError "pending review request branch mismatch: expected $requestBranch, got $branch"
    }

    if ($requestHeadSha -ne $headSha) {
        Stop-WithError "pending review request head mismatch: expected $requestHeadSha, got $headSha"
    }

    $timestamp = (Get-Date).ToString('o')
    $reviewer = [ordered]@{
        pane_id    = $context.PaneId
        label      = $context.Label
        role       = $context.Role
        agent_name = [string]$env:WINSMUX_AGENT_NAME
    }
    $evidence = [ordered]@{
        failed_at               = $timestamp
        failed_via              = 'winsmux review-fail'
        review_contract_snapshot = Get-ReviewStatePropertyValue -InputObject $request -Name 'review_contract'
    }

    $state[$branch] = New-ReviewerStateRecord -Status 'FAIL' -Request $request -Reviewer $reviewer -Evidence $evidence -UpdatedAt $timestamp
    Save-ReviewState -ProjectDir $projectDir -State $state
    Update-ReviewPaneManifestState -ProjectDir $projectDir -Properties ([ordered]@{
        review_state = 'fail'
        task_owner   = 'Operator'
        branch       = $branch
        head_sha     = $headSha
        last_event   = 'review.fail'
        last_event_at = $timestamp
    })
    Write-Output "review FAIL recorded for $branch"
}

function Invoke-ReviewReset {
    if ($Target -or ($Rest -and $Rest.Count -gt 0)) {
        Stop-WithError "usage: winsmux review-reset"
    }

    $projectDir = (Get-Location).Path
    $branch = Get-CurrentGitBranch -ProjectDir $projectDir
    $state = Get-ReviewState -ProjectDir $projectDir
    if ($state.Contains($branch)) {
        $state.Remove($branch)
    }

    Save-ReviewState -ProjectDir $projectDir -State $state
    Update-ReviewPaneManifestState -ProjectDir $projectDir -Properties ([ordered]@{
        review_state = ''
        branch       = ''
        head_sha     = ''
        last_event   = 'review.reset'
        last_event_at = (Get-Date).ToString('o')
    })
    Write-Output "review PASS cleared for $branch"
}

function Invoke-ConsultRequest {
    Assert-WinsmuxRolePermission -CommandName 'consult-request'
    $commandArgs = Resolve-CurrentCommandArgs
    $args = Parse-ConsultCommandArgs -Mode ([string]$commandArgs.target) -Args @($commandArgs.rest)
    Write-ConsultationCommandRecord -Kind 'consult_request' -Mode ([string]$args.mode) -Message ([string]$args.message) -TargetSlot ([string]$args.target_slot)
}

function Invoke-ConsultResult {
    Assert-WinsmuxRolePermission -CommandName 'consult-result'
    $commandArgs = Resolve-CurrentCommandArgs
    $args = Parse-ConsultCommandArgs -Mode ([string]$commandArgs.target) -Args @($commandArgs.rest)
    Write-ConsultationCommandRecord -Kind 'consult_result' -Mode ([string]$args.mode) -Message ([string]$args.message) -TargetSlot ([string]$args.target_slot) -Confidence $args.confidence -NextTest ([string]$args.next_test) -Risks @($args.risks) -RunId ([string]$args.run_id) -JsonOutput ([bool]$args.json)
}

function Invoke-ConsultError {
    Assert-WinsmuxRolePermission -CommandName 'consult-error'
    $commandArgs = Resolve-CurrentCommandArgs
    $args = Parse-ConsultCommandArgs -Mode ([string]$commandArgs.target) -Args @($commandArgs.rest)
    Write-ConsultationCommandRecord -Kind 'consult_error' -Mode ([string]$args.mode) -Message ([string]$args.message) -TargetSlot ([string]$args.target_slot)
}

function Invoke-ProviderCapabilities {
    $tokens = @(@($Target) + @($Rest) | Where-Object { $_ })
    $providerId = ''
    $jsonOutput = $false

    for ($index = 0; $index -lt $tokens.Count; $index++) {
        switch ($tokens[$index]) {
            '--json' {
                $jsonOutput = $true
            }
            default {
                if ([string]::IsNullOrWhiteSpace($providerId)) {
                    $providerId = [string]$tokens[$index]
                    continue
                }

                Stop-WithError "usage: winsmux provider-capabilities [provider] [--json]"
            }
        }
    }

    $projectDir = (Get-Location).Path
    $registry = Read-BridgeProviderCapabilityRegistry -RootPath $projectDir
    if (-not [string]::IsNullOrWhiteSpace($providerId)) {
        $capabilities = Get-BridgeProviderCapability -RootPath $projectDir -ProviderId $providerId
        if ($null -eq $capabilities) {
            Stop-WithError "provider capability '$providerId' was not found."
        }

        $result = [ordered]@{
            provider_id   = $providerId
            capabilities  = $capabilities
            registry_path = Get-BridgeProviderCapabilityRegistryPath -RootPath $projectDir
        }
        if ($jsonOutput) {
            $result | ConvertTo-Json -Depth 16 -Compress | Write-Output
            return
        }

        Write-Output "provider capability $providerId"
        foreach ($property in $capabilities.GetEnumerator()) {
            $value = $property.Value
            if ($value -is [System.Array]) {
                $value = ($value -join ',')
            }
            Write-Output "  $($property.Key): $value"
        }
        return
    }

    $result = [ordered]@{
        version       = [int]$registry.version
        registry_path = Get-BridgeProviderCapabilityRegistryPath -RootPath $projectDir
        providers     = $registry.providers
    }
    if ($jsonOutput) {
        $result | ConvertTo-Json -Depth 16 -Compress | Write-Output
        return
    }

    if ($registry.providers.Count -lt 1) {
        Write-Output 'provider capabilities: none'
        return
    }

    Write-Output 'provider capabilities'
    foreach ($entry in $registry.providers.GetEnumerator()) {
        Write-Output "  $($entry.Key)"
    }
}

function Invoke-MetaPlan {
    param(
        [AllowNull()][string]$MetaPlanTarget = $Target,
        [AllowNull()][string[]]$MetaPlanRest = $Rest
    )

    $tokens = @(@($MetaPlanTarget) + @($MetaPlanRest) | Where-Object { $_ })
    $rustArgs = @('meta-plan') + $tokens

    $output = Invoke-WinsmuxRaw -Arguments $rustArgs
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        exit $nativeExitCode
    }

    $output | Write-Output
}

function Invoke-MachineContract {
    $tokens = @(@($Target) + @($Rest) | Where-Object { $_ })
    if ($tokens.Count -ne 1 -or [string]$tokens[0] -ne '--json') {
        Stop-WithError "usage: winsmux machine-contract --json"
    }

    $output = Invoke-WinsmuxRaw -Arguments @('machine-contract', '--json')
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        exit $nativeExitCode
    }

    $output | Write-Output
}

function Invoke-Skills {
    param(
        [AllowNull()][string]$SkillsTarget = $Target,
        [AllowNull()][string[]]$SkillsRest = $Rest
    )

    $tokens = @(@($SkillsTarget) + @($SkillsRest) | Where-Object { $_ })
    $rustArgs = @('skills')
    foreach ($token in $tokens) {
        switch ($token) {
            '--json' {
                $rustArgs += '--json'
            }
            default {
                Stop-WithError "usage: winsmux skills [--json]"
            }
        }
    }

    $output = Invoke-WinsmuxRaw -Arguments $rustArgs
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        exit $nativeExitCode
    }

    $output | Write-Output
}

function Invoke-RustCanary {
    $tokens = @(@($Target) + @($Rest) | Where-Object { $_ })
    $rustArgs = @('rust-canary')
    foreach ($token in $tokens) {
        switch ($token) {
            '--json' {
                $rustArgs += '--json'
            }
            default {
                Stop-WithError "usage: winsmux rust-canary [--json]"
            }
        }
    }

    $output = Invoke-WinsmuxRaw -Arguments $rustArgs
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        exit $nativeExitCode
    }

    $output | Write-Output
}

function Invoke-Dogfood {
    param(
        [AllowNull()][string]$DogfoodTarget = $Target,
        [AllowNull()][string[]]$DogfoodRest = $Rest
    )

    $tokens = @(@($DogfoodTarget) + @($DogfoodRest) | Where-Object { $_ })
    if ($tokens.Count -lt 1) {
        Stop-WithError "usage: winsmux dogfood <event|run-start|run-finish|stats> ..."
    }

    if ($tokens.Count -ge 2 -and $tokens -notcontains '--db') {
        $valueOptions = @(
            '--action-type',
            '--ci-failures',
            '--duration-ms',
            '--ended-at',
            '--event-id',
            '--event-json',
            '--input-source',
            '--local-gate-failures',
            '--mode',
            '--model',
            '--notes-hash',
            '--outcome',
            '--pane-id',
            '--payload-hash',
            '--payload-text',
            '--reasoning-effort',
            '--review-fix-loops',
            '--rework-commits',
            '--run-id',
            '--session-id',
            '--since',
            '--started-at',
            '--task-class',
            '--task-ref',
            '--timestamp'
        )
        $rebuiltTokens = @($tokens[0])
        $dbPathRecovered = $false
        for ($index = 1; $index -lt $tokens.Count; $index++) {
            $token = [string]$tokens[$index]
            if ($token.StartsWith('-')) {
                $rebuiltTokens += $token
                if ($valueOptions -contains $token -and $index + 1 -lt $tokens.Count) {
                    $rebuiltTokens += [string]$tokens[$index + 1]
                    $index++
                }
                continue
            }

            if (-not $dbPathRecovered) {
                $rebuiltTokens += @('--db', $token)
                $dbPathRecovered = $true
            } else {
                $rebuiltTokens += $token
            }
        }
        $tokens = $rebuiltTokens
    }

    $output = Invoke-WinsmuxRaw -Arguments (@('dogfood') + $tokens)
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        exit $nativeExitCode
    }

    $output | Write-Output
}

function Invoke-ManualChecklist {
    $tokens = @(@($Target) + @($Rest) | Where-Object { $_ })
    $rustArgs = @('manual-checklist')
    foreach ($token in $tokens) {
        switch ($token) {
            '--json' {
                $rustArgs += '--json'
            }
            default {
                Stop-WithError "usage: winsmux manual-checklist [--json]"
            }
        }
    }

    $output = Invoke-WinsmuxRaw -Arguments $rustArgs
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        exit $nativeExitCode
    }

    $output | Write-Output
}

function Invoke-LegacyCompatGate {
    $tokens = @(@($Target) + @($Rest) | Where-Object { $_ })
    $rustArgs = @('legacy-compat-gate')
    foreach ($token in $tokens) {
        switch ($token) {
            '--json' {
                $rustArgs += '--json'
            }
            default {
                Stop-WithError "usage: winsmux legacy-compat-gate [--json]"
            }
        }
    }

    $output = Invoke-WinsmuxRaw -Arguments $rustArgs
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        exit $nativeExitCode
    }

    $output | Write-Output
}

function Invoke-Guard {
    param(
        [AllowNull()][string]$GuardTarget = $Target,
        [AllowNull()][string[]]$GuardRest = $Rest
    )

    $tokens = @(@($GuardTarget) + @($GuardRest) | Where-Object { $_ })
    $rustArgs = @('guard')
    foreach ($token in $tokens) {
        switch ($token) {
            '--json' {
                $rustArgs += '--json'
            }
            default {
                Stop-WithError "usage: winsmux guard [--json]"
            }
        }
    }

    $output = Invoke-WinsmuxRaw -Arguments $rustArgs
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        exit $nativeExitCode
    }

    $output | Write-Output
}

function Invoke-ProviderSwitch {
    $tokens = @(@($Target) + @($Rest) | Where-Object { $_ })
    if ($tokens.Count -lt 1) {
        Stop-WithError "usage: winsmux provider-switch <slot> [--agent <name>] [--model <name>] [--model-source <source>] [--reasoning-effort <level>] [--prompt-transport <argv|file|stdin>] [--auth-mode <mode>] [--reason <text>] [--restart] [--clear] [--json]"
    }

    $slotId = [string]$tokens[0]
    $agent = ''
    $model = ''
    $modelSource = ''
    $reasoningEffort = ''
    $promptTransport = ''
    $authMode = ''
    $reason = ''
    $restartRequested = $false
    $clearRequested = $false
    $jsonOutput = $false

    for ($index = 1; $index -lt $tokens.Count; $index++) {
        switch ($tokens[$index]) {
            '--agent' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WithError '--agent requires a value'
                }
                $agent = [string]$tokens[$index + 1]
                $index++
            }
            '--model' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WithError '--model requires a value'
                }
                $model = [string]$tokens[$index + 1]
                $index++
            }
            '--model-source' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WithError '--model-source requires a value'
                }
                $modelSource = [string]$tokens[$index + 1]
                $index++
            }
            '--reasoning-effort' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WithError '--reasoning-effort requires a value'
                }
                $reasoningEffort = [string]$tokens[$index + 1]
                $index++
            }
            '--prompt-transport' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WithError '--prompt-transport requires a value'
                }
                $promptTransport = [string]$tokens[$index + 1]
                $index++
            }
            '--auth-mode' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WithError '--auth-mode requires a value'
                }
                $authMode = [string]$tokens[$index + 1]
                $index++
            }
            '--reason' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WithError '--reason requires a value'
                }
                $reason = [string]$tokens[$index + 1]
                $index++
            }
            '--json' {
                $jsonOutput = $true
            }
            '--restart' {
                $restartRequested = $true
            }
            '--clear' {
                $clearRequested = $true
            }
            default {
                Stop-WithError "usage: winsmux provider-switch <slot> [--agent <name>] [--model <name>] [--model-source <source>] [--reasoning-effort <level>] [--prompt-transport <argv|file|stdin>] [--auth-mode <mode>] [--reason <text>] [--restart] [--clear] [--json]"
            }
        }
    }

    if ($clearRequested -and (-not [string]::IsNullOrWhiteSpace($agent) -or -not [string]::IsNullOrWhiteSpace($model) -or -not [string]::IsNullOrWhiteSpace($modelSource) -or -not [string]::IsNullOrWhiteSpace($reasoningEffort) -or -not [string]::IsNullOrWhiteSpace($promptTransport) -or -not [string]::IsNullOrWhiteSpace($authMode))) {
        Stop-WithError 'provider-switch --clear cannot be combined with --agent, --model, --model-source, --reasoning-effort, --prompt-transport, or --auth-mode.'
    }

    $projectDir = (Get-Location).Path
    $settings = Get-BridgeSettings -RootPath $projectDir
    $knownSlot = $false
    foreach ($slot in @($settings.agent_slots)) {
        if ([string]::Equals([string]$slot.slot_id, $slotId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $knownSlot = $true
            break
        }
    }
    if (-not $knownSlot) {
        Stop-WithError "provider-switch target slot '$slotId' is not present in agent_slots."
    }

    $restartPaneId = ''
    if ($restartRequested) {
        $manifestEntry = @(Get-PaneControlManifestEntries -ProjectDir $projectDir | Where-Object {
            [string]::Equals([string]$_.Label, $slotId, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)

        if ($manifestEntry.Count -lt 1) {
            Stop-WithError "provider-switch --restart target slot '$slotId' is not present in the orchestra manifest."
        }

        $restartPaneId = Confirm-Target ([string]$manifestEntry[0].PaneId)
    }

    $entry = $null
    $cleared = $false
    if ($clearRequested) {
        $clearResult = Remove-BridgeProviderRegistryEntry -RootPath $projectDir -SlotId $slotId
        $cleared = [bool]$clearResult.Removed
    } else {
        $candidateInput = [ordered]@{}
        if (-not [string]::IsNullOrWhiteSpace($agent)) { $candidateInput.agent = $agent }
        if (-not [string]::IsNullOrWhiteSpace($model)) { $candidateInput.model = $model }
        if (-not [string]::IsNullOrWhiteSpace($modelSource)) { $candidateInput.model_source = $modelSource }
        if (-not [string]::IsNullOrWhiteSpace($reasoningEffort)) { $candidateInput.reasoning_effort = $reasoningEffort }
        if (-not [string]::IsNullOrWhiteSpace($promptTransport)) { $candidateInput.prompt_transport = $promptTransport }
        if (-not [string]::IsNullOrWhiteSpace($authMode)) { $candidateInput.auth_mode = $authMode }
        $candidateEntry = ConvertTo-BridgeProviderRegistryEntry $candidateInput
        $null = Get-SlotAgentConfig -Role 'Worker' -SlotId $slotId -Settings $settings -RootPath $projectDir -ProviderRegistryEntryOverride $candidateEntry
        $entry = Write-BridgeProviderRegistryEntry -RootPath $projectDir -SlotId $slotId -Agent $agent -Model $model -ModelSource $modelSource -ReasoningEffort $reasoningEffort -PromptTransport $promptTransport -AuthMode $authMode -Reason $reason
    }
    $effective = Get-SlotAgentConfig -Role 'Worker' -SlotId $slotId -Settings $settings -RootPath $projectDir
    $result = [ordered]@{
        slot_id                    = $slotId
        agent                      = [string]$effective.Agent
        model                      = [string]$effective.Model
        model_source               = [string]$effective.ModelSource
        reasoning_effort           = [string]$effective.ReasoningEffort
        prompt_transport           = [string]$effective.PromptTransport
        auth_mode                  = [string]$effective.AuthMode
        auth_policy                = [string]$effective.AuthPolicy
        local_access_note          = [string]$effective.LocalAccessNote
        harness_availability       = [string]$effective.HarnessAvailability
        credential_requirements    = [string]$effective.CredentialRequirements
        execution_backend          = [string]$effective.ExecutionBackend
        runtime_requirements       = [string]$effective.RuntimeRequirements
        analysis_posture           = [string]$effective.AnalysisPosture
        source                     = [string]$effective.Source
        capability_adapter         = [string]$effective.CapabilityAdapter
        capability_command         = [string]$effective.CapabilityCommand
        supports_parallel_runs     = [bool]$effective.SupportsParallelRuns
        supports_interrupt         = [bool]$effective.SupportsInterrupt
        supports_structured_result = [bool]$effective.SupportsStructuredResult
        supports_file_edit         = [bool]$effective.SupportsFileEdit
        supports_subagents         = [bool]$effective.SupportsSubagents
        supports_verification      = [bool]$effective.SupportsVerification
        supports_consultation      = [bool]$effective.SupportsConsultation
        supports_context_reset     = [bool]$effective.SupportsContextReset
        registry_path              = Get-BridgeProviderRegistryPath -RootPath $projectDir
        updated_at_utc             = if ($clearRequested) { [string]$clearResult.UpdatedAtUtc } else { [string]$entry.updated_at_utc }
        reason                     = if ((-not $clearRequested) -and $entry.Contains('reason')) { [string]$entry.reason } else { '' }
        clear_requested            = $clearRequested
        cleared                    = $cleared
        restart_requested          = $restartRequested
        restarted                  = $false
        restart_pane_id            = ''
    }

    if ($restartRequested) {
        $restartResult = Invoke-RestartPane -PaneId $restartPaneId -ProjectDir $projectDir
        $result['restarted'] = $true
        $result['restart_pane_id'] = [string]$restartResult.PaneId
    }

    if ($jsonOutput) {
        $result | ConvertTo-Json -Depth 8 -Compress | Write-Output
        return
    }

    if ($clearRequested) {
        Write-Output "provider switch cleared for ${slotId}: $($result.agent) / $($result.model) ($($result.prompt_transport), $($result.auth_policy))"
        return
    }

    Write-Output "provider switched for ${slotId}: $($result.agent) / $($result.model) ($($result.prompt_transport), $($result.auth_policy))"
}

function Invoke-RuntimeRoles {
    $tokens = @(@($Target) + @($Rest) | Where-Object { $_ })
    if ($tokens.Count -lt 1 -or $tokens[0] -ne 'apply') {
        Stop-WithError "usage: winsmux runtime-roles apply --roles-json <json> [--json]"
    }

    $rolesJson = ''
    $jsonOutput = $false
    for ($index = 1; $index -lt $tokens.Count; $index++) {
        switch ($tokens[$index]) {
            '--roles-json' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WithError '--roles-json requires a value'
                }
                $rolesJson = [string]$tokens[$index + 1]
                $index++
            }
            '--json' {
                $jsonOutput = $true
            }
            default {
                Stop-WithError "usage: winsmux runtime-roles apply --roles-json <json> [--json]"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($rolesJson)) {
        Stop-WithError '--roles-json requires a value'
    }

    try {
        $roles = $rolesJson | ConvertFrom-Json -Depth 16 -ErrorAction Stop
    } catch {
        Stop-WithError 'runtime-roles apply received invalid JSON.'
    }

    $projectDir = (Get-Location).Path
    $payload = Write-BridgeRuntimeRolePreferences -RootPath $projectDir -Roles $roles
    $result = [ordered]@{
        version        = [int]$payload.version
        updated_at_utc = [string]$payload.updated_at_utc
        roles          = $payload.roles
        preferences_path = Get-BridgeRuntimeRolePreferencesPath -RootPath $projectDir
    }

    if ($jsonOutput) {
        $result | ConvertTo-Json -Depth 16 -Compress | Write-Output
        return
    }

    Write-Output "runtime role preferences updated: $(@($result.roles.Keys).Count) roles"
}

function Show-Usage {
    Write-Output @"
winsmux $VERSION - winsmux bridge for winsmux

Commands:
  init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>] [--workspace-lifecycle <preset>]  Create or refresh public first-run config
  launch [--json] [--project-dir <path>] [--skip-doctor]  Run public first-run checks and startup
  launcher <presets|lifecycle|list|save> [name] [--lifecycle <preset>] [--json]  Inspect or save capability-aware launcher templates
  id                        Show current pane ID
  list                      List all panes
  read <target> [lines]     Capture pane output (default 50 lines)
  type <target> <text>      Send literal text to pane
  keys <target> <key>...    Send key sequences to pane
  message <target> <text>   Send a tagged message to pane (no Enter)
  send <target> <text>      Send a tagged message AND press Enter (recommended)
  name <target> <label>     Label a pane
  resolve <label>           Resolve label to pane ID
  ime-input <target>        Open GUI dialog for Japanese IME input
  image-paste <target>      Save clipboard image and send path to pane
  clipboard-paste <target>  Send clipboard text to pane
  focus <label|target>      Switch active pane (use from outside winsmux)
  focus-lock <target>       Push a focus lock for a pane target
  focus-unlock              Pop the latest focus lock
  lock <label> <file>...    Acquire file lock(s) for a label
  unlock <label> <file>...  Release file lock(s) for a label
  review-request            Record a pending review request for the current branch
  review-approve            Record review PASS for the current branch
  review-fail               Record review FAIL for the current branch
  review-reset              Clear review PASS for the current branch
  dispatch-review           Dispatch review-request to a review-capable pane (Reviewer/Worker)
  dispatch-task <text>      Route and send task text to a managed pane using manifest-aware role selection
  consult-request <mode> [--message <text>] [--target-slot <slot>]  Record a consultation request packet/event
  consult-result <mode> [--message <text>] [--target-slot <slot>] [--confidence <0..1>] [--next-test <text>] [--risk <text>] [--run-id <run_id>] [--json]  Record a consultation result packet/event
  consult-error <mode> [--message <text>] [--target-slot <slot>]  Record a consultation error packet/event
  meta-plan --task <text> [--roles <path>] [--review-rounds <1|2>] [--json] [--project-dir <path>] [--session <name>]  Draft a read-only multi-role planning packet
  provider-capabilities [provider] [--json]  Inspect the provider capability registry contract
  runtime-roles apply --roles-json <json> [--json]  Persist local runtime role provider/model preferences
  skills [--json]  Print agent-readable command skill contracts
  machine-contract --json  Print the hook and agent machine contract JSON
  rust-canary [--json]  Print the Rust default-on canary gate JSON
  dogfood <event|run-start|run-finish|stats> ...  Record and summarize private dogfooding metrics
  manual-checklist [--json]  Print the versioned manual validation checklist gate
  legacy-compat-gate [--json]  Print the legacy compatibility removal inventory gate
  guard [--json]  Print the public security and release guard baseline
  assign --task <TASK-ID> [--json] [--text <text>]  Dry-run provider, role, model-tier, approval, and sandbox assignment
  provider-switch <slot> [--agent <name>] [--model <name>] [--model-source <source>] [--reasoning-effort <level>] [--prompt-transport <argv|file|stdin>] [--auth-mode <mode>] [--reason <text>] [--restart] [--clear] [--json]  Record or clear a runtime provider reassignment for a managed slot
  github-preflight [--repo <owner/name>] [--json] [--connector-available] [--require-gh]  Select the GitHub write path before merge/release automation
  locks                     List active file locks
  verify <pr-number>        Run Pester in tests/ and merge PR only on PASS
  wait <channel> [timeout]  Block until signal received (replaces polling)
  wait-ready <target> [timeout_seconds]  Wait for the configured agent prompt in pane
  health-check              Report READY/BUSY/HUNG/DEAD for labeled panes
  status                    Report manifest pane states via capture-pane
  workers <status|start|stop|attach|doctor> [slot|all] [--json] [--project-dir <path>]  Inspect and control configured worker slots
  workers heartbeat <mark|check> <slot> [--run-id <id>] [--state <state>] [--json] [--project-dir <path>]  Mark or check isolated/local worker liveness without classifying child waits as stopped
  workers workspace <prepare|cleanup> <slot> [--include <path>] [--run-id <id>] [--json] [--project-dir <path>]  Prepare or remove disposable isolated worker workspaces
  workers secrets project <slot> --run-id <id> [--env <name=key>] [--file <path=key>] [--variable <name=key>] [--json] [--project-dir <path>]  Project typed run-scoped secrets without printing secret values
  workers sandbox baseline <slot> --run-id <id> [--json] [--project-dir <path>]  Define the Windows restricted-token and ACL baseline for an isolated run
  workers broker baseline <slot> --run-id <id> --endpoint <url> [--node-id <id>] [--json] [--project-dir <path>]  Define the single external broker node contract for a prepared isolated run
  workers broker token <issue|check> <slot> --run-id <id> [--ttl-seconds <n>] [--no-refresh] [--json] [--project-dir <path>]  Issue or check short-lived broker run tokens without printing token values
  workers policy baseline <slot> --run-id <id> [--network <mode>] [--write <mode>] [--provider <mode>] [--json] [--project-dir <path>]  Define enterprise execution policy outside prompts for a prepared isolated run
  board [--json]            Report pane/task/review/git session board
desktop-summary [--json] [--stream]  Report the aggregated desktop read-model snapshot or follow refresh signals
inbox [--json] [--stream] Report actionable approvals/review/blockers
runs [--json]             Report run-oriented session view
digest [--json] [--stream] [--events] Report high-signal evidence digest per run or actionable event summaries
explain <run_id> [--json] [--follow]  Explain one run and optionally follow new events
review-pack <run_id> [--json] [--project-dir <path>]  Export a bounded reviewer packet for one run
compare-runs <left_run_id> <right_run_id> [--json]  Compare two runs and surface evidence/confidence deltas
compare <runs|preflight|promote> ... [--json]  Public compare entrypoint for run comparison, preflight, and promotion
conflict-preflight <left_ref> <right_ref> [--json]  Run git merge-tree preflight before compare UI or merge review
promote-tactic <run_id> [--title <text>] [--kind <playbook|prewarm|verification>] [--json]  Export a reusable tactic candidate from a successful run
  poll-events [cursor]      Return new monitor events from .winsmux/events.jsonl
  signal <channel>          Send signal to unblock a waiting process
  watch <label> [silence_s] [timeout_s]  Block until pane output is silent
  dispatch-route <text>   Route text to appropriate pane by keyword detection
  pipeline <task>       Run plan-exec-verify-fix loop for a task
  task-run <task>       Alias for pipeline; one-shot orchestration entrypoint
  builder-queue <action> [args]  Manage Builder queue and auto-dispatch next work
  orchestra-smoke [--json] [--auto-start] [--project-dir <path>]  Report structured startup contract + UI attach state (use --auto-start to start if needed)
  orchestra-attach [--json] [--project-dir <path>]  Launch a visible attach window for an existing orchestra session
  harness-check [--json] [--project-dir <path>]  Validate hook/settings/attach contracts before external-operator startup
  shadow-cutover-gate --expected <path> --actual <path> [--surface <name>] [--json]  Compare PowerShell/Rust shadow outputs before cutover
  powershell-deescalation [--json]  Print the PowerShell shrink contract for runtime cutover
  vault set <key> [value]   Store a credential securely (DPAPI)
  vault get <key>           Retrieve a stored credential
  vault inject <pane>       Inject all credentials as env vars into a pane
  vault list                List stored credential keys
  profile [name] [agents]   Show or register WT dropdown profile
  mailbox-create <ch>       Create Named Pipe mailbox listener
  mailbox-send <ch> <json>  Send JSON message to mailbox channel
  mailbox-listen <ch>       Alias for mailbox-create
  control-rpc <json>        Send JSON-RPC to \\.\pipe\winsmux-control
  kill <target>             Stop pane process and respawn its shell
  restart <target>          Restart the pane agent using manifest context
  rebind-worktree <target> <path>  Update a Builder/Worker pane to use a new worktree path
  doctor                    Check environment and IME diagnostics
  version                   Show version
"@
}

# --- Control RPC ---
function Get-ControlRpcPipeName {
    return 'winsmux-control'
}

function Get-ControlRpcPipeDisplayName {
    return '\\.\pipe\winsmux-control'
}

function ConvertTo-ControlRpcPayload {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$JsonText)

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        Stop-WithError "usage: winsmux control-rpc <json>"
    }

    try {
        $payload = $JsonText | ConvertFrom-Json -Depth 100
    } catch {
        Stop-WithError "control-rpc payload must be valid JSON: $($_.Exception.Message)"
    }

    $propertyNames = @($payload.PSObject.Properties.Name)
    if ($propertyNames -notcontains 'jsonrpc' -or [string]$payload.jsonrpc -ne '2.0') {
        Stop-WithError "control-rpc payload must be a JSON-RPC 2.0 request"
    }

    if ($propertyNames -notcontains 'method' -or [string]::IsNullOrWhiteSpace([string]$payload.method)) {
        Stop-WithError "control-rpc payload must include a non-empty method"
    }

    return ($payload | ConvertTo-Json -Depth 100 -Compress)
}

function Invoke-ControlRpcPipeExchange {
    param(
        [Parameter(Mandatory = $true)][string]$Payload,
        [int]$TimeoutMs = 5000
    )

    $pipeName = Get-ControlRpcPipeName
    $client = $null
    try {
        $client = [System.IO.Pipes.NamedPipeClientStream]::new(
            '.',
            $pipeName,
            [System.IO.Pipes.PipeDirection]::InOut
        )
        $client.Connect($TimeoutMs)

        $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
        $client.Write($requestBytes, 0, $requestBytes.Length)
        $client.Flush()

        $buffer = [byte[]]::new(4096)
        $memory = [System.IO.MemoryStream]::new()
        try {
            while ($true) {
                $readTask = $client.ReadAsync($buffer, 0, $buffer.Length)
                if (-not $readTask.Wait($TimeoutMs)) {
                    Stop-WithError "control-rpc timed out waiting for response from $(Get-ControlRpcPipeDisplayName)"
                }
                $count = $readTask.GetAwaiter().GetResult()
                if ($count -le 0) { break }
                $memory.Write($buffer, 0, $count)
            }
            return [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
        } finally {
            $memory.Dispose()
        }
    } catch {
        Stop-WithError "control-rpc failed to reach $(Get-ControlRpcPipeDisplayName): $($_.Exception.Message)"
    } finally {
        if ($null -ne $client) {
            $client.Dispose()
        }
    }
}

function Invoke-ControlRpc {
    param(
        [AllowEmptyString()][string]$ControlTarget = $Target,
        [string[]]$ControlRest = $Rest
    )

    $jsonText = (@($ControlTarget) + @($ControlRest) | Where-Object { $null -ne $_ }) -join ' '
    $payload = ConvertTo-ControlRpcPayload -JsonText $jsonText
    Invoke-ControlRpcPipeExchange -Payload $payload | Write-Output
}

# --- Named Pipe Mailbox ---
function Get-MailboxPipeName {
    param([string]$Channel)

    if ([string]::IsNullOrWhiteSpace($Channel)) {
        Stop-WithError "mailbox channel must not be empty"
    }
    # Sanitize: allow only alphanumeric, hyphen, underscore
    if ($Channel -notmatch '^[a-zA-Z0-9_-]+$') {
        Stop-WithError "mailbox channel name must be alphanumeric (with - and _ allowed)"
    }

    return "winsmux-mailbox-$Channel"
}

function Invoke-MailboxCreate {
    if (-not $Target) { Stop-WithError "usage: winsmux mailbox-create <channel>" }

    $pipeName = Get-MailboxPipeName $Target
    Write-Output "mailbox listening: $pipeName"

    while ($true) {
        $server = $null
        try {
            $server = [System.IO.Pipes.NamedPipeServerStream]::new(
                $pipeName,
                [System.IO.Pipes.PipeDirection]::In,
                [System.IO.Pipes.NamedPipeServerStream]::MaxAllowedServerInstances,
                [System.IO.Pipes.PipeTransmissionMode]::Byte,
                [System.IO.Pipes.PipeOptions]::None
            )

            $server.WaitForConnection()
            $reader = [System.IO.StreamReader]::new($server, [System.Text.Encoding]::UTF8)
            try {
                $payload = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }

            if ([string]::IsNullOrWhiteSpace($payload)) {
                continue
            }

            try {
                $message = $payload | ConvertFrom-Json -ErrorAction Stop
                [ordered]@{
                    from      = $message.from
                    to        = $message.to
                    content   = $message.content
                    timestamp = $message.timestamp
                } | ConvertTo-Json -Compress | Write-Output
            } catch {
                Write-Warning "invalid mailbox payload on $pipeName"
            }
        } catch {
            Write-Warning "mailbox connection error on ${pipeName}: $($_.Exception.Message)"
            Start-Sleep -Milliseconds 500
        } finally {
            if ($server) { $server.Dispose() }
        }
    }
}

function Invoke-MailboxSend {
    if (-not $Target) { Stop-WithError "usage: winsmux mailbox-send <channel> <json>" }
    if (-not $Rest -or $Rest.Count -eq 0) {
        Stop-WithError "usage: winsmux mailbox-send <channel> <json>"
    }

    $pipeName = Get-MailboxPipeName $Target
    $payload = $Rest -join ' '

    # Validate JSON
    try {
        $null = $payload | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Stop-WithError "mailbox-send: payload must be valid JSON"
    }

    $client = [System.IO.Pipes.NamedPipeClientStream]::new(
        ".",
        $pipeName,
        [System.IO.Pipes.PipeDirection]::Out
    )

    try {
        $client.Connect(5000)
        $writer = [System.IO.StreamWriter]::new($client, [System.Text.Encoding]::UTF8)
        try {
            $writer.AutoFlush = $true
            $writer.Write($payload)
        } finally {
            $writer.Dispose()
        }
    } catch {
        Stop-WithError "failed to send mailbox message to ${pipeName}: $($_.Exception.Message)"
    } finally {
        $client.Dispose()
    }

    Write-Output "mailbox sent: $pipeName"
}

function Invoke-MailboxListen {
    Invoke-MailboxCreate
}

# --- Kill / Restart ---
function Get-RestartReadinessAgentName {
    param(
        [Parameter(Mandatory = $true)]$Plan
    )

    $readinessAgent = ''
    if ($Plan -is [System.Collections.IDictionary] -and $Plan.Contains('CapabilityAdapter')) {
        $readinessAgent = [string]$Plan['CapabilityAdapter']
    } elseif ($null -ne $Plan.PSObject -and ($Plan.PSObject.Properties.Name -contains 'CapabilityAdapter')) {
        $readinessAgent = [string]$Plan.CapabilityAdapter
    }

    if ([string]::IsNullOrWhiteSpace($readinessAgent)) {
        if ($Plan -is [System.Collections.IDictionary] -and $Plan.Contains('Agent')) {
            $readinessAgent = [string]$Plan['Agent']
        } else {
            $readinessAgent = [string]$Plan.Agent
        }
    }

    return $readinessAgent
}

function Set-PaneReadinessManifestFromRestartPlan {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)]$Plan
    )

    if (-not (Get-Command Get-PaneControlManifestContext -ErrorAction SilentlyContinue) -or
        -not (Get-Command Set-PaneControlManifestPaneProperties -ErrorAction SilentlyContinue)) {
        return
    }

    try {
        $context = Get-PaneControlManifestContext -ProjectDir $ProjectDir -PaneId $PaneId
        $properties = [ordered]@{
            provider_target    = [string]$Plan.Agent
            capability_adapter = [string]$Plan.CapabilityAdapter
        }

        Set-PaneControlManifestPaneProperties -ManifestPath $context.ManifestPath -PaneId $PaneId -Properties $properties
    } catch {
        # Restart has already changed the running process; readiness metadata sync is best-effort.
    }
}

function Invoke-Kill {
    if (-not $Target) { Stop-WithError "usage: winsmux kill <target>" }
    if ($Rest -and $Rest.Count -gt 0) { Stop-WithError "usage: winsmux kill <target>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Invoke-WinsmuxRaw -Arguments @('respawn-pane', '-k', '-t', $paneId)
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        Stop-WithError "failed to kill pane process: $paneId"
    }

    Clear-ReadMark $paneId
    Clear-Watermark $paneId
    Write-Output "killed $paneId"
}

function Invoke-RestartPane {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    $settings = $null
    if (Get-Command Get-BridgeSettings -ErrorAction SilentlyContinue) {
        $settings = Get-BridgeSettings -RootPath $ProjectDir
    }

    $plan = Get-PaneControlRestartPlan -ProjectDir $ProjectDir -PaneId $PaneId -Settings $settings

    Invoke-WinsmuxRaw -Arguments @('respawn-pane', '-k', '-t', $PaneId, '-c', $plan.LaunchDir)
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        Stop-WithError "failed to restart pane shell: $PaneId"
    }

    Wait-PaneShellReady -PaneId $PaneId
    try {
        Update-PaneControlManifestPaneLabel -ProjectDir $ProjectDir -PaneId $PaneId | Out-Null
    } catch {
    }

    Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $PaneId, '-l', '--', "$($plan.LaunchCommand)")
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        Stop-WithError "failed to send launch command to $PaneId"
    }
    Invoke-WinsmuxRaw -Arguments @('send-keys', '-t', $PaneId, 'Enter')
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        Stop-WithError "failed to submit launch command to $PaneId"
    }

    Set-PaneReadinessManifestFromRestartPlan -ProjectDir $ProjectDir -PaneId $PaneId -Plan $plan

    Clear-ReadMark $PaneId
    Clear-Watermark $PaneId

    $restartReadinessAgent = Get-RestartReadinessAgentName -Plan $plan

    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Test-AgentReadyPrompt -PaneId $PaneId -Agent $restartReadinessAgent) {
            return $plan
        }

        Start-Sleep -Seconds 2
    }

    $readinessName = ConvertTo-ReadinessAgentName $restartReadinessAgent
    Stop-WithError "timed out waiting for $readinessName prompt after restart in $PaneId"
}

function Invoke-Restart {
    if (-not $Target) { Stop-WithError "usage: winsmux restart <target>" }
    if ($Rest -and $Rest.Count -gt 0) { Stop-WithError "usage: winsmux restart <target>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId
    $projectDir = (Get-Location).Path
    $plan = Invoke-RestartPane -PaneId $paneId -ProjectDir $projectDir
    Write-Output "restarted $paneId ($($plan.Label))"
}

function Invoke-RebindWorktree {
    if (-not $Target) { Stop-WithError "usage: winsmux rebind-worktree <target> <new-worktree-path>" }
    if (-not $Rest -or $Rest.Count -lt 1) { Stop-WithError "usage: winsmux rebind-worktree <target> <new-worktree-path>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId
    $newWorktreePath = ($Rest -join ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($newWorktreePath)) {
        Stop-WithError "new worktree path must not be empty"
    }

    if (-not (Test-Path -LiteralPath $newWorktreePath -PathType Container)) {
        Stop-WithError "worktree path not found: $newWorktreePath"
    }

    $projectDir = (Get-Location).Path
    $resolvedWorktreePath = (Get-Item -LiteralPath $newWorktreePath -Force).FullName
    $context = Get-PaneControlManifestContext -ProjectDir $projectDir -PaneId $paneId

    if ($context.Role -notin @('Builder', 'Worker')) {
        Stop-WithError "rebind-worktree is only supported for Builder/Worker panes: $paneId ($($context.Label))"
    }

    Set-PaneControlManifestPanePaths -ProjectDir $projectDir -PaneId $paneId -LaunchDir $resolvedWorktreePath -BuilderWorktreePath $resolvedWorktreePath
    Write-Output "rebound $paneId ($($context.Label)) to $resolvedWorktreePath"
}

# --- Dispatch ---
switch ($Command) {
    'init'            { Invoke-Init }
    'launch'          { Invoke-Launch }
    'id'              { Invoke-Id }
    'list'            { Invoke-List }
    'read'            { Invoke-Read }
    'type'            { Invoke-Type }
    'keys'            { Invoke-Keys }
    'message'         { Invoke-Message }
    'send'            { Invoke-Send }
    'name'            { Invoke-Name }
    'resolve'         { Invoke-Resolve }
    'ime-input'       { Invoke-ImeInput }
    'image-paste'     { Invoke-ImagePaste }
    'clipboard-paste' { Invoke-ClipboardPaste }
    'focus'           { Invoke-Focus }
    'focus-lock'      { Invoke-FocusLock }
    'focus-unlock'    { Invoke-FocusUnlock }
    'lock'            { Invoke-Lock }
    'unlock'          { Invoke-Unlock }
    'locks'           { Invoke-Locks }
    'github-preflight' {
        $preflightScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\github-write-preflight.ps1'))
        $preflightArgs = @()
        $remaining = @(@($Target) + @($Rest) | Where-Object { $_ })
        for ($index = 0; $index -lt $remaining.Count; $index++) {
            switch ($remaining[$index]) {
                '--repo' {
                    if ($index + 1 -ge $remaining.Count) {
                        Stop-WithError "usage: winsmux github-preflight [--repo <owner/name>] [--json] [--connector-available] [--require-gh]"
                    }
                    $preflightArgs += @('-Repository', $remaining[$index + 1])
                    $index++
                }
                '--json' { $preflightArgs += '-Json' }
                '--connector-available' { $preflightArgs += '-ConnectorAvailable' }
                '--require-gh' { $preflightArgs += '-RequireGh' }
                default {
                    Stop-WithError "usage: winsmux github-preflight [--repo <owner/name>] [--json] [--connector-available] [--require-gh]"
                }
            }
        }
        & pwsh -NoProfile -File $preflightScript @preflightArgs
        $preflightExitCode = Get-SafeLastExitCode
        if ($null -ne $preflightExitCode -and $preflightExitCode -ne 0) {
            exit $preflightExitCode
        }
    }
    'verify'          { Invoke-Verify }
    'dispatch-task'   { Invoke-DispatchTask }
    'dispatch-route'  {
        $routerScript = Join-Path $PSScriptRoot '..\winsmux-core\scripts\dispatch-router.ps1'
        $fullText = @($Target) + @($Rest) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        & $routerScript -Text ($fullText -join ' ')
    }
    'task-split' {
        $splitterScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\task-splitter.ps1'))
        $taskText = (@($Target) + @($Rest) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
        if (-not $taskText) {
            Stop-WithError "usage: winsmux task-split <task text>"
        }

        & pwsh -NoProfile -File $splitterScript -Task $taskText -AsJson
    }
    'pipeline' {
        $pipelineScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\team-pipeline.ps1'))
        $taskText = (@($Target) + @($Rest) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
        if ($taskText) {
            & pwsh -NoProfile -File $pipelineScript -Task $taskText
        } else {
            & pwsh -NoProfile -File $pipelineScript
        }
    }
    'task-run' {
        $pipelineScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\team-pipeline.ps1'))
        $taskText = (@($Target) + @($Rest) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
        if ($taskText) {
            & pwsh -NoProfile -File $pipelineScript -Task $taskText
        } else {
            & pwsh -NoProfile -File $pipelineScript
        }
    }
    'builder-queue' {
        $queueScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\builder-queue.ps1'))
        switch ($Target) {
            'add' {
                if (-not $Rest -or $Rest.Count -lt 2) {
                    Stop-WithError "usage: winsmux builder-queue add <builder-label> <task>"
                }

                $builderLabel = $Rest[0]
                $taskText = (@($Rest | Select-Object -Skip 1) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
                & pwsh -NoProfile -File $queueScript -Action add -ProjectDir (Get-Location).Path -BuilderLabel $builderLabel -Task $taskText
            }
            'list' {
                $builderLabel = if ($Rest -and $Rest.Count -gt 0) { $Rest[0] } else { '' }
                & pwsh -NoProfile -File $queueScript -Action list -ProjectDir (Get-Location).Path -BuilderLabel $builderLabel
            }
            'dispatch-next' {
                if (-not $Rest -or $Rest.Count -lt 1) {
                    Stop-WithError "usage: winsmux builder-queue dispatch-next <builder-label>"
                }

                & pwsh -NoProfile -File $queueScript -Action 'dispatch-next' -ProjectDir (Get-Location).Path -BuilderLabel $Rest[0]
            }
            'complete' {
                if (-not $Rest -or $Rest.Count -lt 1) {
                    Stop-WithError "usage: winsmux builder-queue complete <builder-label> [task]"
                }

                $builderLabel = $Rest[0]
                $taskText = (@($Rest | Select-Object -Skip 1) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
                if ($taskText) {
                    & pwsh -NoProfile -File $queueScript -Action complete -ProjectDir (Get-Location).Path -BuilderLabel $builderLabel -Task $taskText
                } else {
                    & pwsh -NoProfile -File $queueScript -Action complete -ProjectDir (Get-Location).Path -BuilderLabel $builderLabel
                }
            }
            default {
                Stop-WithError "usage: winsmux builder-queue [add|list|dispatch-next|complete] ..."
            }
        }
    }
    'orchestra-smoke' {
        $smokeScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\orchestra-smoke.ps1'))
        $remaining = @(@($Target) + @($Rest) | Where-Object { $_ })
        $smokeArgs = @()
        for ($index = 0; $index -lt $remaining.Count; $index++) {
            switch ($remaining[$index]) {
                '--json' {
                    $smokeArgs += '-AsJson'
                }
                '--project-dir' {
                    if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux orchestra-smoke [--json] [--auto-start] [--project-dir <path>]"
                }

                $smokeArgs += @('-ProjectDir', $remaining[$index + 1])
                $index++
            }
                '--auto-start' {
                    $smokeArgs += '-AutoStart'
                }
                default {
                    Stop-WithError "usage: winsmux orchestra-smoke [--json] [--auto-start] [--project-dir <path>]"
                }
            }
        }
        & pwsh -NoProfile -File $smokeScript @smokeArgs
    }
    'orchestra-attach' {
        $attachScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\orchestra-attach.ps1'))
        $attachArgs = @()
        $remaining = @(@($Target) + @($Rest) | Where-Object { $_ })
        for ($index = 0; $index -lt $remaining.Count; $index++) {
            switch ($remaining[$index]) {
                '--json' {
                    $attachArgs += '-AsJson'
                }
                '--project-dir' {
                    if ($index + 1 -ge $remaining.Count) {
                        Stop-WithError "usage: winsmux orchestra-attach [--json] [--project-dir <path>]"
                    }

                    $attachArgs += @('-ProjectDir', $remaining[$index + 1])
                    $index++
                }
                default {
                    Stop-WithError "usage: winsmux orchestra-attach [--json] [--project-dir <path>]"
                }
            }
        }
        & pwsh -NoProfile -File $attachScript @attachArgs
    }
    'harness-check' {
        $checkScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\harness-check.ps1'))
        $checkArgs = @()
        $remaining = @(@($Target) + @($Rest) | Where-Object { $_ })
        for ($index = 0; $index -lt $remaining.Count; $index++) {
            switch ($remaining[$index]) {
                '--json' {
                    $checkArgs += '-AsJson'
                }
                '--project-dir' {
                    if ($index + 1 -ge $remaining.Count) {
                        Stop-WithError "usage: winsmux harness-check [--json] [--project-dir <path>]"
                    }

                    $checkArgs += @('-ProjectDir', $remaining[$index + 1])
                    $index++
                }
                default {
                    Stop-WithError "usage: winsmux harness-check [--json] [--project-dir <path>]"
                }
            }
        }
        & pwsh -NoProfile -File $checkScript @checkArgs
    }
    'shadow-cutover-gate' {
        $gateScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\shadow-cutover-gate.ps1'))
        $remaining = @(@($Target) + @($Rest) | Where-Object { $_ })
        $expectedPath = ''
        $actualPath = ''
        $surface = 'unspecified'
        $asJson = $false
        for ($index = 0; $index -lt $remaining.Count; $index++) {
            switch ($remaining[$index]) {
                '--expected' {
                    if ($index + 1 -ge $remaining.Count) {
                        Stop-WithError "usage: winsmux shadow-cutover-gate --expected <path> --actual <path> [--surface <name>] [--json]"
                    }
                    $expectedPath = $remaining[$index + 1]
                    $index++
                }
                '--actual' {
                    if ($index + 1 -ge $remaining.Count) {
                        Stop-WithError "usage: winsmux shadow-cutover-gate --expected <path> --actual <path> [--surface <name>] [--json]"
                    }
                    $actualPath = $remaining[$index + 1]
                    $index++
                }
                '--surface' {
                    if ($index + 1 -ge $remaining.Count) {
                        Stop-WithError "usage: winsmux shadow-cutover-gate --expected <path> --actual <path> [--surface <name>] [--json]"
                    }
                    $surface = $remaining[$index + 1]
                    $index++
                }
                '--json' {
                    $asJson = $true
                }
                default {
                    Stop-WithError "usage: winsmux shadow-cutover-gate --expected <path> --actual <path> [--surface <name>] [--json]"
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($expectedPath) -or [string]::IsNullOrWhiteSpace($actualPath)) {
            Stop-WithError "usage: winsmux shadow-cutover-gate --expected <path> --actual <path> [--surface <name>] [--json]"
        }

        $gateArgs = @('-ExpectedPath', $expectedPath, '-ActualPath', $actualPath, '-Surface', $surface)
        if ($asJson) {
            $gateArgs += '-AsJson'
        }
        & pwsh -NoProfile -File $gateScript @gateArgs
    }
    'powershell-deescalation' {
        $contractScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\powershell-deescalation.ps1'))
        $remaining = @(@($Target) + @($Rest) | Where-Object { $_ })
        $contractArgs = @()
        foreach ($argument in $remaining) {
            switch ($argument) {
                '--json' {
                    $contractArgs += '-AsJson'
                }
                default {
                    Stop-WithError "usage: winsmux powershell-deescalation [--json]"
                }
            }
        }
        & pwsh -NoProfile -File $contractScript @contractArgs
    }
    'vault'           {
        switch ($Target) {
            'set'    { $Target = $Rest[0]; $Rest = @($Rest | Select-Object -Skip 1); Invoke-VaultSet }
            'get'    { $Target = $Rest[0]; Invoke-VaultGet }
            'inject' { $Target = $Rest[0]; Invoke-VaultInject }
            'list'   { Invoke-VaultList }
            default  { Stop-WithError "usage: winsmux vault [set|get|inject|list]" }
        }
    }
    'wait'            { Invoke-Wait }
    'wait-ready'      { Invoke-WaitReady }
    'health-check'    { Invoke-HealthCheck }
    'status'          { Invoke-Status }
    'workers'         { Invoke-Workers }
    'board'           { Invoke-Board }
    'desktop-summary' { Invoke-DesktopSummary }
    'inbox'           { Invoke-Inbox }
    'runs'            { Invoke-Runs }
    'digest'          { Invoke-Digest }
    'explain'         { Invoke-Explain }
    'review-pack'     { Invoke-ReviewPack }
    'compare'         { Invoke-Compare }
    'compare-runs'    { Invoke-CompareRuns }
    'conflict-preflight' { Invoke-ConflictPreflight }
    'promote-tactic'  { Invoke-PromoteTactic }
    'poll-events'     { Invoke-PollEvents }
    'signal'          { Invoke-Signal }
    'mailbox-create'  { Invoke-MailboxCreate }
    'mailbox-send'    { Invoke-MailboxSend }
    'mailbox-listen'  { Invoke-MailboxListen }
    'control-rpc'     { Invoke-ControlRpc }
    'watch'           { Invoke-Watch }
    'profile'         { Invoke-Profile }
    'doctor'          { Invoke-Doctor }
    'version'         { Invoke-Version }
    'monitor' {
        $monitorScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\agent-monitor.ps1'))
        & pwsh -NoProfile -File $monitorScript
    }
    'role'            { Invoke-Role }
    'auto-rebalance'  { Invoke-AutoRebalance }
    'kill'            { Invoke-Kill }
    'restart'         { Invoke-Restart }
    'dispatch-review' { Invoke-DispatchReview }
    'review-request'  { Invoke-ReviewRequest }
    'review-approve'  { Invoke-ReviewApprove }
    'review-fail'     { Invoke-ReviewFail }
    'review-reset'    { Invoke-ReviewReset }
    'consult-request' { Invoke-ConsultRequest }
    'consult-result'  { Invoke-ConsultResult }
    'consult-error'   { Invoke-ConsultError }
    'launcher'        { Invoke-Launcher }
    'meta-plan'       { Invoke-MetaPlan }
    'provider-capabilities' { Invoke-ProviderCapabilities }
    'skills' { Invoke-Skills }
    'machine-contract' { Invoke-MachineContract }
    'rust-canary' { Invoke-RustCanary }
    'dogfood' { Invoke-Dogfood }
    'manual-checklist' { Invoke-ManualChecklist }
    'legacy-compat-gate' { Invoke-LegacyCompatGate }
    'guard' { Invoke-Guard }
    'assign' {
        $assignScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\assignment-policy.ps1'))
        $assignArgs = @()
        $remaining = @(@($Target) + @($Rest) | Where-Object { $_ })
        for ($index = 0; $index -lt $remaining.Count; $index++) {
            switch ($remaining[$index]) {
                '--task' {
                    if ($index + 1 -ge $remaining.Count) {
                        Stop-WithError "usage: winsmux assign --task <TASK-ID> [--json] [--text <text>]"
                    }
                    $assignArgs += @('-TaskId', $remaining[$index + 1])
                    $index++
                }
                '--text' {
                    if ($index + 1 -ge $remaining.Count) {
                        Stop-WithError "usage: winsmux assign --task <TASK-ID> [--json] [--text <text>]"
                    }
                    $assignArgs += @('-Text', $remaining[$index + 1])
                    $index++
                }
                '--json' { $assignArgs += '-Json' }
                default {
                    Stop-WithError "usage: winsmux assign --task <TASK-ID> [--json] [--text <text>]"
                }
            }
        }
        & pwsh -NoProfile -File $assignScript @assignArgs
        $assignExitCode = Get-SafeLastExitCode
        if ($null -ne $assignExitCode -and $assignExitCode -ne 0) {
            exit $assignExitCode
        }
    }
    'provider-switch' { Invoke-ProviderSwitch }
    'runtime-roles' { Invoke-RuntimeRoles }
    'rebind-worktree' { Invoke-RebindWorktree }
    ''                { Show-Usage }
    default           { Stop-WithError "unknown command: $Command. Run without arguments for usage." }
}

