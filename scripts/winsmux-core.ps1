[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Command,
    [Parameter(Position=1)][string]$Target,
    [Parameter(Position=2, ValueFromRemainingArguments=$true)][string[]]$Rest
)

# --- Config ---
$VERSION = "0.22.2"
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

    return & winsmux @Arguments
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

    $artifact = New-ConsultationPacketFile -ProjectDir $ProjectDir -ConsultationPacket $packet

    $eventData = [ordered]@{
        task_id          = [string]$context.TaskId
        run_id           = [string]$context.RunId
        slot             = [string]$context.Slot
        branch           = [string]$context.Branch
        worktree         = [string]$context.Worktree
        consultation_ref = [string]$artifact.reference
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
        )
        rationale         = 'Review requests must audit downstream design impact, replacement coverage, and orphaned artifacts as part of the runtime contract.'
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
    # display-message -t ignores the -t flag in winsmux v3.3.1, so validate via list-panes
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
    $targetCandidates = @(Get-PaneTargetCandidates -PaneId $PaneId)
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

    $output = & winsmux capture-pane -t $PaneId -p -J -S -50
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
        [string]$Agent = 'codex'
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    $line = $Line.Trim()
    if ($line -match '^(>|›|▌|❯)$') {
        return $true
    }

    if (Get-Command Test-AgentPromptText -ErrorAction SilentlyContinue) {
        if (Test-AgentPromptText -Text $line -Agent $Agent) {
            return $true
        }
    }

    $agentName = if ([string]::IsNullOrWhiteSpace($Agent)) {
        'codex'
    } else {
        $Agent.Trim().ToLowerInvariant()
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
        [string]$Agent = 'codex'
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
        [string]$Agent = 'codex'
    )

    $agentName = if ([string]::IsNullOrWhiteSpace($Agent)) {
        'codex'
    } else {
        $Agent.Trim().ToLowerInvariant()
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
        [string]$Agent = 'codex'
    )

    $output = & winsmux capture-pane -t $PaneId -p -J -S -50
    return Test-AgentReadyPromptText -Text (($output | Out-String).TrimEnd()) -Agent $Agent
}

function Get-PaneReadinessAgent {
    param(
        [string]$Target,
        [string]$PaneId,
        [string]$ProjectDir = (Get-Location).Path
    )

    $fallback = 'codex'
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
                # Fall back to the default adapter when no running-pane metadata is available.
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
        $snapshot = (& winsmux capture-pane -t $PaneId -p -J -S -50 2>$null | Out-String).TrimEnd()
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
    $raw = & winsmux list-panes -a -F '#{pane_id} #{pane_pid}'
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

    $output = Invoke-WinsmuxRaw -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', "-$Lines")
    return ($output | Out-String).TrimEnd()
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
        $id = & winsmux display-message -p '#{pane_id}'
        Write-Output ($id | Out-String).Trim()
    }
}

function Invoke-List {
    $raw = & winsmux list-panes -a -F '#{pane_id} #{pane_pid} #{pane_current_command} #{pane_width}x#{pane_height} #{pane_title}'
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

    $output = & winsmux capture-pane -t $paneId -p -J -S "-$lines"
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

    & winsmux send-keys -t $paneId -l -- "$text"

    Clear-ReadMark $paneId
}

function Invoke-Keys {
    if (-not $Target) { Stop-WithError "usage: winsmux keys <target> <key>..." }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux keys <target> <key>..." }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    foreach ($key in $Rest) {
        & winsmux send-keys -t $paneId $key
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

    $myId = (& winsmux display-message -p '#{pane_id}' | Out-String).Trim()
    $myCoord = (& winsmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' | Out-String).Trim()
    $agentName = if ($env:WINSMUX_AGENT_NAME) { $env:WINSMUX_AGENT_NAME } else { "unknown" }

    $header = "[winsmux from:$agentName pane:$myId at:$myCoord -- load the winsmux skill to reply]"
    & winsmux send-keys -t $paneId -l -- "$header $text"

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
    $paneId = Confirm-Target $paneId
    $context = $null
    $agentConfig = [ordered]@{
        Agent           = 'codex'
        Model           = 'gpt-5.4'
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
                $execMode = $execModeValue.Trim().ToLowerInvariant() -eq 'true' -and $capabilityAdapter -eq 'codex'
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
        & winsmux select-pane -t $paneId -T "$label" 2>$null
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
        $snapshot = (& winsmux capture-pane -t $paneId -p 2>$null | Out-String).TrimEnd()
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

    # Rename pane first (before respawn)
    & winsmux select-pane -t $paneId -T $newLabel

    # Update labels
    $labels[$newLabel] = $paneId
    if ($labels.ContainsKey($oldLabel)) { $labels.Remove($oldLabel) }
    Save-Labels $labels

    # Respawn pane (kills current process + restarts shell in one step, #174)
    & winsmux respawn-pane -k -t $paneId

    # Wait for shell ready (poll for PS prompt)
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $snapshot = (& winsmux capture-pane -t $paneId -p 2>$null | Out-String).TrimEnd()
        $lastLine = ($snapshot -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if ($lastLine -and $lastLine.Trim() -match '^PS ') { break }
        Start-Sleep -Milliseconds 500
    }

    try {
        Update-PaneControlManifestPaneLabel -ProjectDir $projectDir -PaneId $paneId -Label $newLabel | Out-Null
    } catch {
    }

    # Launch Codex agent
    $gitDir = Join-Path $projectDir ".git"
    $launchCmd = "codex --sandbox danger-full-access -C '$projectDir' --add-dir '$gitDir'"
    & winsmux send-keys -t $paneId -l $launchCmd
    & winsmux send-keys -t $paneId Enter

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

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Stop-WithError "gh CLI not found. Install GitHub CLI before running verify."
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
    $result = Invoke-Pester -Path ($testFiles.FullName) -PassThru

    if ($null -eq $result) {
        Stop-WithError "Invoke-Pester returned no result."
    }

    $failedTests = @()
    if ($result.PSObject.Properties.Name -contains 'Failed' -and $result.Failed) {
        $failedTests = @($result.Failed)
    } elseif ($result.PSObject.Properties.Name -contains 'TestResult' -and $result.TestResult) {
        $failedTests = @($result.TestResult | Where-Object { -not $_.Passed })
    }

    $failedCount = 0
    if ($result.PSObject.Properties.Name -contains 'FailedCount') {
        $failedCount = [int]$result.FailedCount
    } elseif ($failedTests) {
        $failedCount = $failedTests.Count
    }

    if ($failedCount -gt 0) {
        Write-Error "Pester verify failed. Failed tests:"
        foreach ($failedTest in $failedTests) {
            $failedName = $null
            foreach ($propertyName in 'ExpandedPath','Path','Name') {
                if ($failedTest.PSObject.Properties.Name -contains $propertyName) {
                    $failedName = $failedTest.$propertyName
                    if (-not [string]::IsNullOrWhiteSpace($failedName)) {
                        break
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($failedName)) {
                $failedName = ($failedTest | Out-String).Trim()
            }

            Write-Error " - $failedName"
        }
        exit 1
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
        $ver = & winsmux -V 2>&1
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
        $panes = & winsmux list-panes -a -F '#{pane_id}'
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
        $escTime = (& winsmux show-options -g -v escape-time 2>&1 | Out-String).Trim()
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
    $model = 'gpt-5.4'
    $workerCount = 6
    $remaining = @(@($Target) + @($Rest) | Where-Object { $_ })

    for ($index = 0; $index -lt $remaining.Count; $index++) {
        switch ($remaining[$index]) {
            '--json' { $asJson = $true }
            '--force' { $force = $true }
            '--project-dir' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>]"
                }

                $projectDir = $remaining[$index + 1]
                $index++
            }
            '--agent' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>]"
                }

                $agent = $remaining[$index + 1]
                $index++
            }
            '--model' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>]"
                }

                $model = $remaining[$index + 1]
                $index++
            }
            '--worker-count' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>]"
                }

                $workerCount = [int]$remaining[$index + 1]
                $index++
            }
            default {
                Stop-WithError "usage: winsmux init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>]"
            }
        }
    }

    $result = Invoke-WinsmuxPublicInit -ProjectDir $projectDir -Force:$force -Agent $agent -Model $model -WorkerCount $workerCount
    if ($asJson) {
        Write-Output (ConvertTo-WinsmuxPublicJson -InputObject $result)
        return
    }

    Write-Output "init status: $($result.status)"
    Write-Output "project: $($result.project_dir)"
    Write-Output "config: $($result.config_path)"
    Write-Output "slots: $($result.slot_count)"
    Write-Output "next: $($result.next_action)"
}

function Invoke-Launch {
    $projectDir = ''
    $skipDoctor = $false
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

    & winsmux send-keys -t $paneId -l -- "$text"
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
    & winsmux send-keys -t $paneId -l -- "$imgPath"
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

    & winsmux send-keys -t $paneId -l -- "$text"
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
    $output = & winsmux capture-pane -t $paneId -p -J -S -50
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

        $output = & winsmux capture-pane -t $paneId -p -J -S -50
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
        [string]$Branch = '',
        [string]$HeadSha = '',
        [string]$Event = '',
        [string]$Timestamp = '',
        [string]$Source = '',
        [int]$ChangedFileCount = 0
    )

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

    if ($eventName -eq 'commander.state_transition') {
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
        'commander.review_requested' { return 'review_requested' }
        'commander.review_failed'    { return 'review_failed' }
        'commander.blocked'          { return 'blocked' }
        'commander.commit_ready'     { return 'commit_ready' }
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
    if ($eventName -like 'commander.*') {
        return 'commander'
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
        -DataFields @('verification_contract', 'verification_result')
    if ($null -eq $snapshot) {
        return $null
    }

    return [ordered]@{
        verification_contract = if ($snapshot.Contains('verification_contract')) { $snapshot['verification_contract'] } else { $null }
        verification_result   = if ($snapshot.Contains('verification_result')) { $snapshot['verification_result'] } else { $null }
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

function New-RunPacketFromRun {
    param([Parameter(Mandatory = $true)]$Run)

    return [ordered]@{
        run_id            = [string]$Run.run_id
        task_id           = [string]$Run.task_id
        parent_run_id     = [string]$Run.parent_run_id
        goal              = [string]$Run.goal
        task              = [string]$Run.task
        task_type         = [string]$Run.task_type
        priority          = [string]$Run.priority
        blocking          = [bool]$Run.blocking
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

    return [ordered]@{
        run_id                = [string]$Run.run_id
        status                = $status
        summary               = $summary
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
        security_policy       = $Run.security_policy
        security_verdict      = $Run.security_verdict
        recent_events         = @($RecentEvents)
    }
}

function Test-RunMatchesEventRecord {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$EventRecord
    )

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

    $data = $null
    if ($EventRecord.Contains('data')) {
        $data = $EventRecord['data']
    }

    if ($null -ne $data -and $data -is [System.Collections.IDictionary]) {
        if ($data.Contains('task_id')) { $eventTaskId = [string]$data['task_id'] }
        if ([string]::IsNullOrWhiteSpace($eventBranch) -and $data.Contains('branch')) { $eventBranch = [string]$data['branch'] }
        if ([string]::IsNullOrWhiteSpace($eventHeadSha) -and $data.Contains('head_sha')) { $eventHeadSha = [string]$data['head_sha'] }
    }

    if (-not [string]::IsNullOrWhiteSpace($runTaskId) -and $runTaskId -eq $eventTaskId) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($runBranch) -and $runBranch -eq $eventBranch) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($runHeadSha) -and $runHeadSha -eq $eventHeadSha) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($eventLabel) -and $runLabels -contains $eventLabel) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($eventPaneId) -and $runPaneIds -contains $eventPaneId) {
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
            }

            $securityVerdict = Get-SecurityVerdictFromEventRecords -EventRecords $matchingEvents
            if ($null -ne $securityVerdict) {
                $run.security_verdict = $securityVerdict
            }
        }
    }

    $runs = @(
        foreach ($runId in @($runsById.Keys)) {
            $run = $runsById[$runId]
            [ordered]@{
                run_id             = [string]$run.run_id
                task_id            = [string]$run.task_id
                task               = [string]$run.task
                task_state         = [string]$run.task_state
                review_state       = [string]$run.review_state
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

    return $true
}

function Test-RunPromotable {
    param([Parameter(Mandatory = $true)]$Run)

    return (Test-RunRecommendable -Run $Run)
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
            reconcile_consult = [bool](
                @($differences | Where-Object { $_.field -in @('branch', 'worktree', 'env_fingerprint', 'command_hash', 'result') }).Count -gt 0 -or
                -not ($leftRecommendable -and $rightRecommendable)
            )
            next_action = if ([string]$leftEvidence.next_action -eq [string]$rightEvidence.next_action) { [string]$leftEvidence.next_action } else { 'reconcile_consult' }
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
        security_verdict     = $run.security_verdict
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

function ConvertTo-EvidenceDigestItem {
    param([Parameter(Mandatory = $true)]$Run)

    $experimentPacket = $Run.experiment_packet

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
        next_action        = Get-RunNextAction -Run $Run
        branch             = [string]$Run.branch
        worktree           = if ($null -ne $experimentPacket -and -not [string]::IsNullOrWhiteSpace([string]$experimentPacket.worktree)) { [string]$experimentPacket.worktree } else { [string]$Run.worktree }
        head_sha           = [string]$Run.head_sha
        head_short         = Get-ShortHeadSha -HeadSha ([string]$Run.head_sha)
        changed_file_count = [int]$Run.changed_file_count
        changed_files      = @($Run.changed_files)
        action_item_count  = @($Run.action_items).Count
        last_event         = [string]$Run.last_event
        last_event_at      = [string]$Run.last_event_at
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
        verification_outcome = if ($null -ne $evidenceDigest -and -not [string]::IsNullOrWhiteSpace([string]$evidenceDigest.verification_outcome)) { [string]$evidenceDigest.verification_outcome } else { [string]$DigestItem.verification_outcome }
        security_blocked     = if ($null -ne $evidenceDigest -and -not [string]::IsNullOrWhiteSpace([string]$evidenceDigest.security_blocked)) { [string]$evidenceDigest.security_blocked } else { [string]$DigestItem.security_blocked }
        changed_files        = @($changedFiles)
        next_action          = if ($null -ne $explanation -and -not [string]::IsNullOrWhiteSpace([string]$explanation.next_action)) { [string]$explanation.next_action } else { [string]$DigestItem.next_action }
        summary              = $summary
        reasons              = if ($null -ne $explanation) { @($explanation.reasons) } else { @() }
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
        $explainPayload = $null
        $runId = [string]$digestItem.run_id
        if (-not [string]::IsNullOrWhiteSpace($runId)) {
            try {
                $explainPayload = Get-ExplainPayload -ProjectDir $ProjectDir -RunId $runId
            } catch {
                $explainPayload = $null
            }
        }

        $runProjections += @(New-DesktopRunProjection -DigestItem $digestItem -ExplainPayload $explainPayload)
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
                last_event   = [string]$run.last_event
            }
        }
        review_state       = $reviewState
        recent_events      = $recentEvents
    }
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

function Invoke-ConflictPreflight {
    param(
        [AllowNull()][string]$PreflightTarget = $Target,
        [AllowNull()][string[]]$PreflightRest = $Rest
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
        Stop-WithError 'usage: winsmux conflict-preflight <left_ref> <right_ref> [--json]'
    }

    $payload = Get-WinsmuxConflictPreflightPayload -ProjectDir (Get-Location).Path -LeftRef ([string]$refs[0]) -RightRef ([string]$refs[1])
    if ($jsonOutput) {
        $payload | ConvertTo-Json -Compress -Depth 10 | Write-Output
        return
    }

    Write-Output ("conflict preflight: {0}" -f [string]$payload.status)
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

    & winsmux select-pane -t $paneId
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
    # $Target = profile name, $Rest = agent definitions like "builder:codex" "reviewer:claude"
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

    if (-not (Test-Path $fragmentDir)) {
        New-Item -ItemType Directory -Path $fragmentDir -Force | Out-Null
    }

    $fragment = @{
        profiles = @(
            @{
                name             = "winsmux $profileName"
                commandline      = "pwsh -NoProfile -Command `"& '%USERPROFILE%\.winsmux\bin\winsmux-core.ps1' doctor; winsmux new-session -s $profileName; pwsh '%USERPROFILE%\.winsmux\bin\start-orchestra.ps1'`""
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
            & winsmux send-keys -t $paneId -l -- "$setCmd"
            & winsmux send-keys -t $paneId Enter
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

    $availableTargets = @()
    if (Get-Command Get-PaneControlManifestEntries -ErrorAction SilentlyContinue) {
        $availableTargets = @(
            Get-PaneControlManifestEntries -ProjectDir $projectDir |
                ForEach-Object { [string]$_.Label } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    if ($availableTargets.Count -eq 0) {
        $availableTargets = @((Get-Labels).Keys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $route = Get-DispatchRoute -Text $taskText -AvailableTargets $availableTargets -DefaultRole 'Worker'
    if ($route.HandleLocally) {
        Stop-WithError "dispatch-task routed to Commander. Refine the task text so it can be delegated to a managed pane."
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
    } else {
        $manifestEntry = Get-DispatchTaskManifestEntry -ProjectDir $projectDir -Label $selectedLabel
        if ($null -eq $manifestEntry -or [string]::IsNullOrWhiteSpace([string]$manifestEntry.PaneId)) {
            Stop-WithError "dispatch-task could not resolve target '$selectedLabel' to a pane."
        }

        $paneId = [string]$manifestEntry.PaneId
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
        task_owner   = 'Commander'
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
        task_owner   = 'Commander'
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

function Invoke-ProviderSwitch {
    $tokens = @(@($Target) + @($Rest) | Where-Object { $_ })
    if ($tokens.Count -lt 1) {
        Stop-WithError "usage: winsmux provider-switch <slot> [--agent <name>] [--model <name>] [--prompt-transport <argv|file|stdin>] [--reason <text>] [--restart] [--clear] [--json]"
    }

    $slotId = [string]$tokens[0]
    $agent = ''
    $model = ''
    $promptTransport = ''
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
            '--prompt-transport' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WithError '--prompt-transport requires a value'
                }
                $promptTransport = [string]$tokens[$index + 1]
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
                Stop-WithError "usage: winsmux provider-switch <slot> [--agent <name>] [--model <name>] [--prompt-transport <argv|file|stdin>] [--reason <text>] [--restart] [--clear] [--json]"
            }
        }
    }

    if ($clearRequested -and (-not [string]::IsNullOrWhiteSpace($agent) -or -not [string]::IsNullOrWhiteSpace($model) -or -not [string]::IsNullOrWhiteSpace($promptTransport))) {
        Stop-WithError 'provider-switch --clear cannot be combined with --agent, --model, or --prompt-transport.'
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
        $entry = Write-BridgeProviderRegistryEntry -RootPath $projectDir -SlotId $slotId -Agent $agent -Model $model -PromptTransport $promptTransport -Reason $reason
    }
    $effective = Get-SlotAgentConfig -Role 'Worker' -SlotId $slotId -Settings $settings -RootPath $projectDir
    $result = [ordered]@{
        slot_id                    = $slotId
        agent                      = [string]$effective.Agent
        model                      = [string]$effective.Model
        prompt_transport           = [string]$effective.PromptTransport
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
        Write-Output "provider switch cleared for ${slotId}: $($result.agent) / $($result.model) ($($result.prompt_transport))"
        return
    }

    Write-Output "provider switched for ${slotId}: $($result.agent) / $($result.model) ($($result.prompt_transport))"
}

function Show-Usage {
    Write-Output @"
winsmux $VERSION - winsmux bridge for winsmux

Commands:
  init [--json] [--project-dir <path>] [--force] [--agent <provider>] [--model <name>] [--worker-count <count>]  Create or refresh public first-run config
  launch [--json] [--project-dir <path>] [--skip-doctor]  Run public first-run checks and startup
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
  provider-capabilities [provider] [--json]  Inspect the provider capability registry contract
  provider-switch <slot> [--agent <name>] [--model <name>] [--prompt-transport <argv|file|stdin>] [--reason <text>] [--restart] [--clear] [--json]  Record or clear a runtime provider reassignment for a managed slot
  locks                     List active file locks
  verify <pr-number>        Run Pester in tests/ and merge PR only on PASS
  wait <channel> [timeout]  Block until signal received (replaces polling)
  wait-ready <target> [timeout_seconds]  Wait for the configured agent prompt in pane
  health-check              Report READY/BUSY/HUNG/DEAD for labeled panes
  status                    Report manifest pane states via capture-pane
  board [--json]            Report pane/task/review/git session board
desktop-summary [--json] [--stream]  Report the aggregated desktop read-model snapshot or follow refresh signals
inbox [--json] [--stream] Report actionable approvals/review/blockers
runs [--json]             Report run-oriented session view
digest [--json] [--stream] [--events] Report high-signal evidence digest per run or actionable event summaries
explain <run_id> [--json] [--follow]  Explain one run and optionally follow new events
compare-runs <left_run_id> <right_run_id> [--json]  Compare two runs and surface evidence/confidence deltas
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
  vault set <key> [value]   Store a credential securely (DPAPI)
  vault get <key>           Retrieve a stored credential
  vault inject <pane>       Inject all credentials as env vars into a pane
  vault list                List stored credential keys
  profile [name] [agents]   Show or register WT dropdown profile
  mailbox-create <ch>       Create Named Pipe mailbox listener
  mailbox-send <ch> <json>  Send JSON message to mailbox channel
  mailbox-listen <ch>       Alias for mailbox-create
  kill <target>             Stop pane process and respawn its shell
  restart <target>          Restart the pane agent using manifest context
  rebind-worktree <target> <path>  Update a Builder/Worker pane to use a new worktree path
  doctor                    Check environment and IME diagnostics
  version                   Show version
"@
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

    & winsmux respawn-pane -k -t $paneId
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

    & winsmux respawn-pane -k -t $PaneId -c $plan.LaunchDir
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        Stop-WithError "failed to restart pane shell: $PaneId"
    }

    Wait-PaneShellReady -PaneId $PaneId
    try {
        Update-PaneControlManifestPaneLabel -ProjectDir $ProjectDir -PaneId $PaneId | Out-Null
    } catch {
    }

    & winsmux send-keys -t $PaneId -l -- "$($plan.LaunchCommand)"
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        Stop-WithError "failed to send launch command to $PaneId"
    }
    & winsmux send-keys -t $PaneId Enter
    $nativeExitCode = Get-SafeLastExitCode
    if ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
        Stop-WithError "failed to submit launch command to $PaneId"
    }

    Set-PaneReadinessManifestFromRestartPlan -ProjectDir $ProjectDir -PaneId $PaneId -Plan $plan

    Clear-ReadMark $PaneId
    Clear-Watermark $PaneId

    $restartReadinessAgent = Get-RestartReadinessAgentName -Plan $plan

    if ($restartReadinessAgent.Trim().ToLowerInvariant() -eq 'codex') {
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            if (Test-CodexReadyPrompt $PaneId) {
                return $plan
            }

            Start-Sleep -Seconds 2
        }

        Stop-WithError "timed out waiting for Codex after restart in $PaneId"
    }

    return $plan
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
    'board'           { Invoke-Board }
    'desktop-summary' { Invoke-DesktopSummary }
    'inbox'           { Invoke-Inbox }
    'runs'            { Invoke-Runs }
    'digest'          { Invoke-Digest }
    'explain'         { Invoke-Explain }
    'compare-runs'    { Invoke-CompareRuns }
    'conflict-preflight' { Invoke-ConflictPreflight }
    'promote-tactic'  { Invoke-PromoteTactic }
    'poll-events'     { Invoke-PollEvents }
    'signal'          { Invoke-Signal }
    'mailbox-create'  { Invoke-MailboxCreate }
    'mailbox-send'    { Invoke-MailboxSend }
    'mailbox-listen'  { Invoke-MailboxListen }
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
    'provider-capabilities' { Invoke-ProviderCapabilities }
    'provider-switch' { Invoke-ProviderSwitch }
    'rebind-worktree' { Invoke-RebindWorktree }
    ''                { Show-Usage }
    default           { Stop-WithError "unknown command: $Command. Run without arguments for usage." }
}

