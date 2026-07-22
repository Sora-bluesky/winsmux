<#
.SYNOPSIS
Session manifest reader/writer for winsmux Orchestra.

.DESCRIPTION
Manages .winsmux/manifest.yaml as desired state and diagnostics for an Orchestra
session. Live authorization uses the separately owned runtime registry; raw
manifest parsing remains available for cleanup and historical diagnostics.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'clm-safe-io.ps1')

$script:ManifestFileName = 'manifest.yaml'
$script:ManifestDirName = '.winsmux'
$script:RuntimeRegistryFileName = 'runtime-registry.json'

function Get-WinsmuxRuntimeStatusClassification {
    param([AllowNull()][AllowEmptyString()][string]$Status = '')

    $normalizedStatus = if ($null -eq $Status) { '' } else { $Status.Trim().ToLowerInvariant() }
    $retryable = $normalizedStatus -ceq 'deferred_start_failed'
    $isDeferred = $normalizedStatus -in @(
        'deferred_start',
        'deferred_starting',
        'deferred_start_failed',
        'api_llm_runner_unconfigured',
        'antigravity_runner_unconfigured'
    )

    return [PSCustomObject][ordered]@{
        NormalizedStatus = $normalizedStatus
        RuntimeOperation = if ($isDeferred) { 'start_deferred' } else { 'dispatch' }
        IsDeferred       = $isDeferred
        IsStarting       = $normalizedStatus -ceq 'deferred_starting'
        Retryable        = $retryable
        CanStartDeferred = ($normalizedStatus -ceq 'deferred_start' -or $retryable)
    }
}

function ConvertTo-ManifestYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [bool]) {
        return $(if ($Value) { 'true' } else { 'false' })
    }

    $text = [string]$Value
    $text = $text -replace "(\r\n|\r|\n)+", ' '
    if ($text.Length -eq 0) {
        return "''"
    }

    return "'" + $text.Replace("'", "''") + "'"
}

function Split-ManifestYamlInlineList {
    param([Parameter(Mandatory = $true)][string]$Value)

    $items = [System.Collections.Generic.List[string]]::new()
    $builder = New-Object System.Text.StringBuilder
    $quote = [char]0

    for ($index = 0; $index -lt $Value.Length; $index++) {
        $char = $Value[$index]

        if ($quote -ne [char]0) {
            [void]$builder.Append($char)

            if ($char -eq $quote) {
                if ($quote -eq "'" -and $index + 1 -lt $Value.Length -and $Value[$index + 1] -eq "'") {
                    $index++
                    [void]$builder.Append($Value[$index])
                    continue
                }

                $quote = [char]0
            }

            continue
        }

        if ($char -eq "'" -or $char -eq '"') {
            $quote = $char
            [void]$builder.Append($char)
            continue
        }

        if ($char -eq ',') {
            $items.Add($builder.ToString().Trim()) | Out-Null
            [void]$builder.Clear()
            continue
        }

        [void]$builder.Append($char)
    }

    $items.Add($builder.ToString().Trim()) | Out-Null
    return @($items)
}

function ConvertTo-ManifestYamlValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [string] -or $Value -is [bool]) {
        return ConvertTo-ManifestYamlScalar -Value $Value
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary])) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            return '[]'
        }

        $encodedItems = foreach ($item in $items) {
            if ($null -ne $item -and ($item -is [System.Collections.IDictionary] -or (($null -ne $item.PSObject) -and -not ($item -is [string]) -and -not ($item -is [bool]) -and -not ($item -is [System.ValueType])))) {
                ConvertTo-ManifestYamlScalar -Value ($item | ConvertTo-Json -Compress -Depth 8)
            } else {
                ConvertTo-ManifestYamlScalar -Value $item
            }
        }

        return '[' + ($encodedItems -join ', ') + ']'
    }

    if ($Value -is [System.Collections.IDictionary] -or (($null -ne $Value.PSObject) -and -not ($Value -is [System.ValueType]))) {
        return ConvertTo-ManifestYamlScalar -Value ($Value | ConvertTo-Json -Compress -Depth 8)
    }

    return ConvertTo-ManifestYamlScalar -Value $Value
}

function ConvertFrom-ManifestYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = $Value.ToString().Trim()
    if ($text.Length -ge 2) {
        if (($text.StartsWith('"') -and $text.EndsWith('"')) -or
            ($text.StartsWith("'") -and $text.EndsWith("'"))) {
            $text = $text.Substring(1, $text.Length - 2)
        }
    }

    if ($text -eq 'null') {
        return $null
    }

    return $text
}

function ConvertFrom-ManifestYamlValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = $Value.ToString().Trim()
    if ($text -eq '[]') {
        return @()
    }

    if ($text.Length -ge 2 -and $text.StartsWith('[') -and $text.EndsWith(']')) {
        $inner = $text.Substring(1, $text.Length - 2).Trim()
        if ([string]::IsNullOrWhiteSpace($inner)) {
            return @()
        }

        return @((Split-ManifestYamlInlineList -Value $inner | ForEach-Object {
            ConvertFrom-ManifestYamlScalar -Value $_
        }))
    }

    return ConvertFrom-ManifestYamlScalar -Value $Value
}

function ConvertTo-ManifestPropertyMap {
    param([AllowNull()]$Value)

    $result = [ordered]@{}
    if ($null -eq $Value) {
        return $result
    }

    if ($Value -is [string] -or $Value -is [System.ValueType] -or
        ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary]))) {
        return $result
    }

    if ($Value -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = $Value[$key]
        }

        return $result
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) {
            $result[[string]$entry.Key] = $entry.Value
        }

        return $result
    }

    if ($null -ne $Value.PSObject) {
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = $property.Value
        }
    }

    return $result
}

function Test-ManifestYamlMappingValue {
    param([AllowNull()]$Value)

    return ($null -ne $Value -and
        ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]))
}

function ConvertTo-ManifestKeyName {
    param([Parameter(Mandatory = $true)][string]$Name)

    switch ($Name) {
        'PaneId' { return 'pane_id' }
        'Role' { return 'role' }
        'ExecMode' { return 'exec_mode' }
        'LaunchDir' { return 'launch_dir' }
        'BuilderBranch' { return 'builder_branch' }
        'BuilderWorktreePath' { return 'builder_worktree_path' }
        'Task' { return 'task' }
        'Status' { return 'status' }
        'BootstrapFailures' { return 'bootstrap_failures' }
        default {
            $snake = [regex]::Replace($Name, '([a-z0-9])([A-Z])', '$1_$2')
            return $snake.ToLowerInvariant()
        }
    }
}

function Add-ManifestYamlNode {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Value,
        [int]$Indent = 0
    )

    $prefix = ' ' * $Indent
    if ($Value -is [System.Collections.IEnumerable] -and
        -not ($Value -is [string]) -and -not ($Value -is [System.Collections.IDictionary])) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            $Lines.Add(("{0}{1}: []" -f $prefix, $Name)) | Out-Null
            return
        }

        $Lines.Add(("{0}{1}:" -f $prefix, $Name)) | Out-Null
        foreach ($item in $items) {
            $itemMap = ConvertTo-ManifestPropertyMap -Value $item
            $itemIsMapping = Test-ManifestYamlMappingValue -Value $item
            if (-not $itemIsMapping) {
                $Lines.Add(("{0}  - {1}" -f $prefix, (ConvertTo-ManifestYamlScalar -Value $item))) | Out-Null
                continue
            }

            if ($itemMap.Count -eq 0) {
                $Lines.Add(("{0}  - {{}}" -f $prefix)) | Out-Null
                continue
            }

            $Lines.Add(("{0}  -" -f $prefix)) | Out-Null
            foreach ($key in $itemMap.Keys) {
                Add-ManifestYamlNode -Lines $Lines -Name ([string]$key) -Value $itemMap[$key] -Indent ($Indent + 4)
            }
        }
        return
    }

    $map = ConvertTo-ManifestPropertyMap -Value $Value
    if (Test-ManifestYamlMappingValue -Value $Value) {
        if ($map.Count -eq 0) {
            $Lines.Add(("{0}{1}: {{}}" -f $prefix, $Name)) | Out-Null
            return
        }

        $Lines.Add(("{0}{1}:" -f $prefix, $Name)) | Out-Null
        foreach ($key in $map.Keys) {
            Add-ManifestYamlNode -Lines $Lines -Name ([string]$key) -Value $map[$key] -Indent ($Indent + 2)
        }
        return
    }

    $Lines.Add(("{0}{1}: {2}" -f $prefix, $Name, (ConvertTo-ManifestYamlValue -Value $Value))) | Out-Null
}

function ConvertFrom-ManifestTopLevelYamlKey {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line) -or [char]::IsWhiteSpace($Line[0])) {
        return $null
    }

    $match = [regex]::Match(
        $Line,
        '^(?<token>[A-Za-z0-9_.-]+|''(?:[^'']|'''')*''|"(?:[^"\\]|\\(?:["\\/bfnrt]|u[0-9A-Fa-f]{4}))*")\s*:(?=$|\s|#)'
    )
    if (-not $match.Success) {
        return $null
    }

    $keyText = [string]$match.Groups['token'].Value
    if ($keyText[0] -eq "'") {
        $keyText = $keyText.Substring(1, $keyText.Length - 2).Replace("''", "'")
    } elseif ($keyText[0] -eq '"') {
        try {
            $keyText = [string](ConvertFrom-Json -InputObject $keyText -ErrorAction Stop)
        } catch {
            return $null
        }
    }

    if ($keyText -cnotmatch '^[A-Za-z0-9_.-]+$') {
        return $null
    }
    return $keyText
}

function Get-ManifestUnknownTopLevelBlocks {
    param([Parameter(Mandatory = $true)][string]$Content)

    $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Rust owns semantic parsing for declarative_workspace and all additive sections.
    # PowerShell retains those top-level blocks as opaque save-through state.
    foreach ($name in @('version', 'saved_at', 'session', 'panes', 'tasks', 'worktrees')) {
        [void]$known.Add($name)
    }

    $blocks = [System.Collections.Generic.List[string]]::new()
    $current = [System.Collections.Generic.List[string]]::new()
    $capturing = $false
    foreach ($rawLine in ($Content -split "\r?\n")) {
        $topLevelKey = ConvertFrom-ManifestTopLevelYamlKey -Line $rawLine
        if ($null -ne $topLevelKey) {
            if ($capturing -and $current.Count -gt 0) {
                $blocks.Add(($current -join "`n")) | Out-Null
                $current.Clear()
            }
            $capturing = -not $known.Contains($topLevelKey)
        }
        if ($capturing) {
            $current.Add($rawLine) | Out-Null
        }
    }
    if ($capturing -and $current.Count -gt 0) {
        $blocks.Add(($current -join "`n")) | Out-Null
    }
    return @($blocks)
}

function Assert-ManifestYamlBlockMappingRoot {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $ownedTopLevelPatterns = [ordered]@{
        version   = '^version:\s*[0-9]+\s*$'
        saved_at  = '^saved_at:\s*(.*?)\s*$'
        session   = '^session:\s*(\{\})?\s*$'
        panes     = '^panes:\s*(\{\})?\s*$'
        tasks     = '^tasks:\s*(\{\})?\s*$'
        worktrees = '^worktrees:\s*(\{\})?\s*$'
    }
    $rootEntryObserved = $false
    foreach ($rawLine in ($Content -split "\r?\n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
            continue
        }

        # This parser supports one block-style mapping document. Reject document
        # boundaries before the line-oriented reader can silently combine roots.
        if ($line -match '^(?:---|\.\.\.)(?:\s+#.*)?$') {
            throw 'manifest parse rejected: document must be a single block-style mapping.'
        }

        if ([char]::IsWhiteSpace($line[0])) {
            if (-not $rootEntryObserved) {
                throw 'manifest parse rejected: document must be a single block-style mapping.'
            }
            continue
        }

        # Every column-zero data line starts another mapping entry. Checking only
        # the first entry would let a later root sequence/scalar/flow node pass
        # through the line-oriented compatibility reader.
        $topLevelKey = ConvertFrom-ManifestTopLevelYamlKey -Line $line
        if ($null -eq $topLevelKey) {
            throw 'manifest parse rejected: document must be a single block-style mapping.'
        }
        if ($ownedTopLevelPatterns.Contains($topLevelKey) -and
            $line -cnotmatch $ownedTopLevelPatterns[$topLevelKey]) {
            throw "manifest parse rejected: owned top-level key '$topLevelKey' must use the canonical form."
        }
        $rootEntryObserved = $true
    }

    if (-not $rootEntryObserved) {
        throw 'manifest parse rejected: document must be a single block-style mapping.'
    }
}

function Write-ManifestTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Content = '',
        [AllowNull()][scriptblock]$ValidateLocked = $null
    )

    Write-WinsmuxTextFile -Path $Path -Content $Content -ValidateLocked $ValidateLocked
}

function Get-ManifestDir {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path $ProjectDir $script:ManifestDirName
}

function Get-ManifestPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path (Get-ManifestDir -ProjectDir $ProjectDir) $script:ManifestFileName
}

function Get-WinsmuxRuntimeRegistryPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path (Get-ManifestDir -ProjectDir $ProjectDir) $script:RuntimeRegistryFileName
}

function Read-WinsmuxRuntimeRegistry {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $path = Get-WinsmuxRuntimeRegistryPath -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Runtime registry is empty: $path"
    }

    try {
        $registry = $raw | ConvertFrom-Json
        if ($null -ne $registry.supervisor) {
            $registry.supervisor.process_started_at = [string](ConvertTo-WinsmuxRuntimeUtcIdentity -Value $registry.supervisor.process_started_at)
        }
        if ($null -ne $registry.lease) {
            $registry.lease.expires_at = [string](ConvertTo-WinsmuxRuntimeUtcIdentity -Value $registry.lease.expires_at)
        }
        if ($null -ne $registry.updated_at) {
            $registry.updated_at = [string](ConvertTo-WinsmuxRuntimeUtcIdentity -Value $registry.updated_at)
        }
        foreach ($pane in @($registry.panes)) {
            if ($null -ne $pane.bootstrap_process_started_at) {
                $pane.bootstrap_process_started_at = [string](ConvertTo-WinsmuxRuntimeUtcIdentity -Value $pane.bootstrap_process_started_at)
            }
        }
        return $registry
    } catch {
        throw "Runtime registry is malformed: $path"
    }
}

function Save-WinsmuxRuntimeRegistry {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Registry
    )

    $path = Get-WinsmuxRuntimeRegistryPath -ProjectDir $ProjectDir
    $json = $Registry | ConvertTo-Json -Depth 20
    Write-ManifestTextFile -Path $path -Content ($json + "`n")
    return $path
}

function New-WinsmuxRuntimeRegistryDocument {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$ServerSessionId,
        [AllowEmptyString()][string]$BootstrapPaneId = '',
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [Parameter(Mandatory = $true)][int]$SupervisorPid,
        [Parameter(Mandatory = $true)][string]$SupervisorProcessStartedAt,
        [Parameter(Mandatory = $true)][ValidateRange(1, 1024)][int]$ExpectedPaneCount,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Panes,
        [datetime]$Now = (Get-Date),
        [ValidateRange(5, 300)][int]$LeaseSeconds = 15
    )

    $startedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $SupervisorProcessStartedAt
    $updatedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $Now
    if ([string]::IsNullOrWhiteSpace($SessionName) -or
        [string]::IsNullOrWhiteSpace($ServerSessionId) -or
        [string]::IsNullOrWhiteSpace($GenerationId) -or
        $SupervisorPid -lt 1 -or
        [string]::IsNullOrWhiteSpace($startedAt) -or
        [string]::IsNullOrWhiteSpace($updatedAt)) {
        throw 'Runtime registry seed is missing a required session, generation, supervisor, or timestamp identity.'
    }

    $expiresAt = $Now.ToUniversalTime().AddSeconds($LeaseSeconds).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    return [PSCustomObject][ordered]@{
        schema_version    = 1
        status            = 'active'
        session_name      = $SessionName
        server_session_id = $ServerSessionId
        bootstrap_pane_id = $BootstrapPaneId
        generation_id     = $GenerationId
        expected_pane_count = $ExpectedPaneCount
        supervisor        = [PSCustomObject][ordered]@{
            pid                = $SupervisorPid
            process_started_at = $startedAt
        }
        lease             = [PSCustomObject][ordered]@{
            state      = 'active'
            expires_at = $expiresAt
        }
        panes             = @($Panes)
        updated_at        = $updatedAt
    }
}

function Test-WinsmuxRuntimeRegistryOwner {
    param(
        [AllowNull()]$Registry,
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [Parameter(Mandatory = $true)][int]$SupervisorPid,
        [Parameter(Mandatory = $true)][string]$SupervisorProcessStartedAt,
        [scriptblock]$ProcessResolver = { param([int]$Id) Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $Id) -ErrorAction SilentlyContinue },
        [datetime]$Now = (Get-Date)
    )

    if ($null -eq $Registry -or
        [string](Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'status' -Default '') -cne 'active' -or
        -not [string]::Equals(
            [string](Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'generation_id' -Default ''),
            $GenerationId,
            [System.StringComparison]::Ordinal)) {
        return $false
    }

    $supervisor = Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'supervisor'
    $ownerPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $supervisor -Name 'pid' -Default $null)
    $ownerStartedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $supervisor -Name 'process_started_at' -Default '')
    $expectedStartedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $SupervisorProcessStartedAt
    if ($null -eq $ownerPid -or $ownerPid -ne $SupervisorPid -or
        [string]::IsNullOrWhiteSpace($ownerStartedAt) -or $ownerStartedAt -cne $expectedStartedAt -or
        -not (Test-WinsmuxStrictProcessIdentity -ProcessId $ownerPid -ExpectedStartTime $ownerStartedAt -ProcessResolver $ProcessResolver)) {
        return $false
    }

    $lease = Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'lease'
    $leaseExpires = ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $lease -Name 'expires_at' -Default '')
    $nowUtc = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $Now
    return (
        [string](Get-WinsmuxRuntimeValue -InputObject $lease -Name 'state' -Default '') -ceq 'active' -and
        -not [string]::IsNullOrWhiteSpace($leaseExpires) -and
        $leaseExpires -cgt $nowUtc
    )
}

function Test-WinsmuxRuntimeRegistryReplacementAllowed {
    param(
        [AllowNull()]$Registry,
        [scriptblock]$ProcessResolver = { param([int]$Id) Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $Id) -ErrorAction SilentlyContinue },
        [datetime]$Now = (Get-Date)
    )

    if ($null -eq $Registry) {
        return $true
    }
    $status = [string](Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'status' -Default '')
    if ($status -ceq 'ended') {
        return $true
    }
    if ($status -cne 'active') {
        return $false
    }

    $lease = Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'lease'
    $leaseExpires = ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $lease -Name 'expires_at' -Default '')
    $nowUtc = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $Now
    if ([string]::IsNullOrWhiteSpace($leaseExpires) -or $leaseExpires -cgt $nowUtc) {
        return $false
    }

    $supervisor = Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'supervisor'
    $ownerPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $supervisor -Name 'pid' -Default $null)
    $ownerStartedAt = [string](Get-WinsmuxRuntimeValue -InputObject $supervisor -Name 'process_started_at' -Default '')
    if ($null -eq $ownerPid) {
        return $false
    }
    try {
        $observedOwner = & $ProcessResolver $ownerPid
    } catch {
        return $false
    }
    if ($null -eq $observedOwner) {
        return $true
    }

    $observedPid = ConvertTo-WinsmuxRuntimeInteger -Value (
        Get-WinsmuxRuntimeValue -InputObject $observedOwner -Name 'Id' -Default (
            Get-WinsmuxRuntimeValue -InputObject $observedOwner -Name 'ProcessId' -Default $null
        )
    )
    $observedStartedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value (
        Get-WinsmuxRuntimeValue -InputObject $observedOwner -Name 'StartTime' -Default (
            Get-WinsmuxRuntimeValue -InputObject $observedOwner -Name 'CreationDate' -Default $null
        )
    )
    $expectedStartedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $ownerStartedAt
    if ($null -eq $observedPid -or $observedPid -ne $ownerPid -or
        [string]::IsNullOrWhiteSpace($observedStartedAt) -or
        [string]::IsNullOrWhiteSpace($expectedStartedAt)) {
        return $false
    }

    return ($observedStartedAt -cne $expectedStartedAt)
}

function Update-WinsmuxRuntimeRegistryLease {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [Parameter(Mandatory = $true)][int]$SupervisorPid,
        [Parameter(Mandatory = $true)][string]$SupervisorProcessStartedAt,
        [AllowNull()][object[]]$Panes = $null,
        [datetime]$Now = (Get-Date),
        [ValidateRange(5, 300)][int]$LeaseSeconds = 15
    )

    $registry = Read-WinsmuxRuntimeRegistry -ProjectDir $ProjectDir
    $supervisor = Get-WinsmuxRuntimeValue -InputObject $registry -Name 'supervisor'
    $ownerPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $supervisor -Name 'pid' -Default $null)
    $ownerStartedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $supervisor -Name 'process_started_at' -Default '')
    $expectedStartedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $SupervisorProcessStartedAt
    if ($null -eq $registry -or
        [string](Get-WinsmuxRuntimeValue -InputObject $registry -Name 'status' -Default '') -cne 'active' -or
        -not [string]::Equals(
            [string](Get-WinsmuxRuntimeValue -InputObject $registry -Name 'generation_id' -Default ''),
            $GenerationId,
            [System.StringComparison]::Ordinal) -or
        $null -eq $ownerPid -or $ownerPid -ne $SupervisorPid -or
        [string]::IsNullOrWhiteSpace($ownerStartedAt) -or $ownerStartedAt -cne $expectedStartedAt) {
        throw 'Runtime registry lease update refused because the writer does not own this generation.'
    }

    $updatedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $Now
    $registry.lease.state = 'active'
    $registry.lease.expires_at = $Now.ToUniversalTime().AddSeconds($LeaseSeconds).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $registry.updated_at = $updatedAt
    if ($null -ne $Panes) {
        $registry.panes = @($Panes)
    }
    Save-WinsmuxRuntimeRegistry -ProjectDir $ProjectDir -Registry $registry | Out-Null
    return $registry
}

function Close-WinsmuxRuntimeRegistry {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [Parameter(Mandatory = $true)][int]$SupervisorPid,
        [Parameter(Mandatory = $true)][string]$SupervisorProcessStartedAt,
        [AllowEmptyString()][string]$ExpectedSessionName = '',
        [AllowEmptyString()][string]$ExpectedServerSessionId = '',
        [datetime]$Now = (Get-Date)
    )

    $registry = Read-WinsmuxRuntimeRegistry -ProjectDir $ProjectDir
    if ($null -eq $registry) {
        return $false
    }

    $supervisor = Get-WinsmuxRuntimeValue -InputObject $registry -Name 'supervisor'
    $ownerPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $supervisor -Name 'pid' -Default $null)
    $ownerStartedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $supervisor -Name 'process_started_at' -Default '')
    $expectedStartedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $SupervisorProcessStartedAt
    if (-not [string]::Equals(
            [string](Get-WinsmuxRuntimeValue -InputObject $registry -Name 'generation_id' -Default ''),
            $GenerationId,
            [System.StringComparison]::Ordinal) -or
        ((-not [string]::IsNullOrWhiteSpace($ExpectedSessionName)) -and
            [string](Get-WinsmuxRuntimeValue -InputObject $registry -Name 'session_name' -Default '') -cne $ExpectedSessionName) -or
        ((-not [string]::IsNullOrWhiteSpace($ExpectedServerSessionId)) -and
            [string](Get-WinsmuxRuntimeValue -InputObject $registry -Name 'server_session_id' -Default '') -cne $ExpectedServerSessionId) -or
        $null -eq $ownerPid -or $ownerPid -ne $SupervisorPid -or $ownerStartedAt -cne $expectedStartedAt) {
        return $false
    }

    $endedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $Now
    $registry.status = 'ended'
    $registry.lease.state = 'ended'
    $registry.lease.expires_at = $endedAt
    $registry.updated_at = $endedAt
    Save-WinsmuxRuntimeRegistry -ProjectDir $ProjectDir -Registry $registry | Out-Null
    return $true
}

function Get-WinsmuxRuntimeValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]$key -ieq $Name) {
                return $InputObject[$key]
            }
        }
        return $Default
    }

    if ($null -ne $InputObject.PSObject) {
        foreach ($property in $InputObject.PSObject.Properties) {
            if ($property.Name -ieq $Name) {
                return $property.Value
            }
        }
    }

    return $Default
}

function ConvertTo-WinsmuxRuntimeUtcIdentity {
    param([AllowNull()]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try {
        if ($Value -is [datetimeoffset]) {
            return $Value.UtcDateTime.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }

        if ($Value -is [datetime]) {
            return $Value.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }

        $parsed = [datetimeoffset]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
        return $parsed.UtcDateTime.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
}

function ConvertTo-WinsmuxRuntimeInteger {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $parsed = 0
    if (-not [int]::TryParse(
            [string]$Value,
            [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed)) {
        return $null
    }

    return $parsed
}

function Resolve-WinsmuxRuntimeRole {
    param(
        [AllowEmptyString()][string]$WorkerRole = '',
        [AllowEmptyString()][string]$CanonicalRole = ''
    )

    $resolved = $WorkerRole.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = $CanonicalRole.Trim().ToLowerInvariant()
    }
    return $resolved
}

function Test-WinsmuxStrictProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedStartTime,
        [scriptblock]$ProcessResolver = { param([int]$Id) Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $Id) -ErrorAction SilentlyContinue }
    )

    if ($ProcessId -lt 1) {
        return $false
    }

    $expected = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $ExpectedStartTime
    if ([string]::IsNullOrWhiteSpace($expected)) {
        return $false
    }

    try {
        $process = & $ProcessResolver $ProcessId
        if ($null -eq $process) {
            return $false
        }

        $actualSource = Get-WinsmuxRuntimeValue -InputObject $process -Name 'StartTime' -Default (Get-WinsmuxRuntimeValue -InputObject $process -Name 'CreationDate' -Default $null)
        $actual = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $actualSource
        return (-not [string]::IsNullOrWhiteSpace($actual) -and $actual -ceq $expected)
    } catch {
        return $false
    }
}

function New-WinsmuxProcessSnapshotResolver {
    param([AllowNull()][object[]]$Snapshots = $null)

    if ($null -eq $Snapshots) {
        try {
            $Snapshots = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Select-Object ProcessId, ParentProcessId, CreationDate, Name)
        } catch {
            throw 'OS process ancestry snapshot is unavailable.'
        }
    }

    $snapshotMap = @{}
    foreach ($snapshot in @($Snapshots)) {
        $processId = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $snapshot -Name 'ProcessId' -Default (Get-WinsmuxRuntimeValue -InputObject $snapshot -Name 'Id' -Default $null))
        $parentProcessId = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $snapshot -Name 'ParentProcessId' -Default $null)
        $startedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $snapshot -Name 'CreationDate' -Default (Get-WinsmuxRuntimeValue -InputObject $snapshot -Name 'StartTime' -Default $null))
        $name = [string](Get-WinsmuxRuntimeValue -InputObject $snapshot -Name 'Name' -Default (Get-WinsmuxRuntimeValue -InputObject $snapshot -Name 'ProcessName' -Default ''))
        if ($null -eq $processId -or $processId -lt 1) {
            continue
        }
        if ($snapshotMap.ContainsKey($processId)) {
            throw 'OS process ancestry snapshot contains a duplicate process identity.'
        }
        $snapshotMap[$processId] = [PSCustomObject][ordered]@{
            Id              = $processId
            ParentProcessId = $parentProcessId
            StartTime       = $startedAt
            Name            = $name
        }
    }

    return { param([int]$Id) return $snapshotMap[$Id] }.GetNewClosure()
}

function Get-WinsmuxRuntimeProcessStartedAt {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    try {
        $snapshot = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction Stop
        if ($null -eq $snapshot) { return $null }
        return ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $snapshot -Name 'CreationDate' -Default $null)
    } catch {
        return $null
    }
}

function New-WinsmuxRuntimeValidationResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Valid,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [Parameter(Mandatory = $true)][string]$Diagnostic,
        [AllowNull()]$Context = $null
    )

    return [PSCustomObject][ordered]@{
        valid       = $Valid
        reason_code = $ReasonCode
        diagnostic  = $Diagnostic
        context     = $Context
    }
}

function Test-WinsmuxRuntimePaneSet {
    param(
        [Parameter(Mandatory = $true)]$ManifestPanes,
        [AllowNull()][object[]]$RegistryPanes,
        [AllowNull()][object[]]$ObservedPanes,
        [Parameter(Mandatory = $true)][ValidateRange(1, 1024)][int]$ExpectedPaneCount,
        [AllowEmptyString()][string]$BootstrapPaneId = ''
    )

    if ($null -eq $ObservedPanes) { return $false }
    $manifestLabels = @($ManifestPanes.Keys | ForEach-Object { [string]$_ })
    $registryItems = @($RegistryPanes)
    $allObservedItems = @($ObservedPanes)
    if ([string]::IsNullOrWhiteSpace($BootstrapPaneId)) {
        $observedItems = @($allObservedItems)
    } else {
        if ($BootstrapPaneId -cnotmatch '^%[0-9]+$') { return $false }
        $bootstrapMatches = @($allObservedItems | Where-Object {
                [string](Get-WinsmuxRuntimeValue -InputObject $_ -Name 'pane_id' -Default '') -ceq $BootstrapPaneId
            })
        if ($bootstrapMatches.Count -ne 1 -or
            [string]::IsNullOrWhiteSpace([string](Get-WinsmuxRuntimeValue -InputObject $bootstrapMatches[0] -Name 'title' -Default ''))) {
            return $false
        }
        $observedItems = @($allObservedItems | Where-Object {
                [string](Get-WinsmuxRuntimeValue -InputObject $_ -Name 'pane_id' -Default '') -cne $BootstrapPaneId
            })
    }
    if ($manifestLabels.Count -ne $ExpectedPaneCount -or
        $registryItems.Count -ne $manifestLabels.Count -or
        $observedItems.Count -ne $manifestLabels.Count) {
        return $false
    }

    $desiredByLabel = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $desiredByPane = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $desiredSlots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($label in $manifestLabels) {
        $pane = $ManifestPanes[$label]
        $slotId = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'slot_id' -Default '')
        $paneId = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'pane_id' -Default '')
        $backend = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'worker_backend' -Default '')
        $role = Resolve-WinsmuxRuntimeRole `
            -WorkerRole ([string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'worker_role' -Default '')) `
            -CanonicalRole ([string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'role' -Default ''))
        $title = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'title' -Default '')
        if ([string]::IsNullOrWhiteSpace($label) -or [string]::IsNullOrWhiteSpace($slotId) -or
            [string]::IsNullOrWhiteSpace($paneId) -or [string]::IsNullOrWhiteSpace($backend) -or
            [string]::IsNullOrWhiteSpace($role) -or [string]::IsNullOrWhiteSpace($title) -or
            $desiredByLabel.ContainsKey($label) -or -not $desiredSlots.Add($slotId) -or
            $desiredByPane.ContainsKey($paneId)) {
            return $false
        }
        $expected = [PSCustomObject][ordered]@{
            label = $label; slot_id = $slotId; pane_id = $paneId; backend = $backend; role = $role; title = $title
        }
        $desiredByLabel.Add($label, $expected)
        $desiredByPane.Add($paneId, $expected)
    }
    if (-not [string]::IsNullOrWhiteSpace($BootstrapPaneId) -and $desiredByPane.ContainsKey($BootstrapPaneId)) {
        return $false
    }

    $registryLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $registrySlots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $registryPaneIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($runtimePane in $registryItems) {
        $label = [string](Get-WinsmuxRuntimeValue -InputObject $runtimePane -Name 'label' -Default '')
        $slotId = [string](Get-WinsmuxRuntimeValue -InputObject $runtimePane -Name 'slot_id' -Default '')
        $paneId = [string](Get-WinsmuxRuntimeValue -InputObject $runtimePane -Name 'pane_id' -Default '')
        if ([string]::IsNullOrWhiteSpace($label) -or [string]::IsNullOrWhiteSpace($slotId) -or
            [string]::IsNullOrWhiteSpace($paneId) -or -not $registryLabels.Add($label) -or
            -not $registrySlots.Add($slotId) -or -not $registryPaneIds.Add($paneId) -or
            -not $desiredByLabel.ContainsKey($label)) {
            return $false
        }
        $expected = $desiredByLabel[$label]
        if ($slotId -cne [string]$expected.slot_id -or $paneId -cne [string]$expected.pane_id -or
            [string](Get-WinsmuxRuntimeValue -InputObject $runtimePane -Name 'backend' -Default '') -cne [string]$expected.backend -or
            [string](Get-WinsmuxRuntimeValue -InputObject $runtimePane -Name 'role' -Default '') -cne [string]$expected.role -or
            [string](Get-WinsmuxRuntimeValue -InputObject $runtimePane -Name 'title' -Default '') -cne [string]$expected.title) {
            return $false
        }
    }

    $observedPaneIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($observedPane in $observedItems) {
        $paneId = [string](Get-WinsmuxRuntimeValue -InputObject $observedPane -Name 'pane_id' -Default '')
        $title = [string](Get-WinsmuxRuntimeValue -InputObject $observedPane -Name 'title' -Default '')
        if ([string]::IsNullOrWhiteSpace($paneId) -or [string]::IsNullOrWhiteSpace($title) -or
            -not $observedPaneIds.Add($paneId) -or -not $desiredByPane.ContainsKey($paneId) -or
            $title -cne [string]$desiredByPane[$paneId].title) {
            return $false
        }
    }
    return $true
}

function Test-WinsmuxRuntimeContext {
    param(
        [AllowNull()]$Manifest,
        [AllowNull()]$Registry,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ObservedServerSessionId,
        [AllowNull()]$ManifestEntry,
        [AllowNull()]$PaneMarker,
        [AllowNull()]$CallerIdentity,
        [AllowNull()][object[]]$ObservedPanes = $null,
        [ValidateSet('dispatch', 'start_deferred', 'caller_ack', 'workflow_ack', 'stop_transition')][string]$Operation = 'dispatch',
        [scriptblock]$ProcessResolver = { param([int]$Id) Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $Id) -ErrorAction SilentlyContinue },
        [datetime]$Now = (Get-Date)
    )

    $regeneration = {
        param([string]$Message)
        New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'manifest_regeneration_required' -Diagnostic $Message
    }
    $invalidSupervisor = {
        param([string]$Message)
        New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'invalid_supervisor_identity' -Diagnostic $Message
    }
    $targetMismatch = {
        param([string]$Message)
        New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'runtime_target_mismatch' -Diagnostic $Message
    }
    $callerMismatch = {
        param([string]$Message)
        New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'caller_identity_mismatch' -Diagnostic $Message
    }

    $manifestVersion = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $Manifest -Name 'version' -Default $null)
    $manifestSession = Get-WinsmuxRuntimeValue -InputObject $Manifest -Name 'session'
    if ($null -eq $manifestVersion -or $manifestVersion -ne 2 -or $null -eq $manifestSession) {
        return & $regeneration 'Manifest does not carry a verified runtime identity.'
    }

    $registryVersion = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'schema_version' -Default $null)
    if ($null -eq $registryVersion -or $registryVersion -ne 1 -or [string](Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'status' -Default '') -cne 'active') {
        return & $regeneration 'Runtime registry is missing, inactive, or uses an unsupported schema.'
    }

    $manifestSessionName = [string](Get-WinsmuxRuntimeValue -InputObject $manifestSession -Name 'name' -Default '')
    $manifestGeneration = [string](Get-WinsmuxRuntimeValue -InputObject $manifestSession -Name 'generation_id' -Default '')
    $manifestServerSession = [string](Get-WinsmuxRuntimeValue -InputObject $manifestSession -Name 'server_session_id' -Default '')
    $manifestBootstrapPane = [string](Get-WinsmuxRuntimeValue -InputObject $manifestSession -Name 'bootstrap_pane_id' -Default '')
    $manifestExpectedPaneCount = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $manifestSession -Name 'expected_pane_count' -Default $null)
    $registrySessionName = [string](Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'session_name' -Default '')
    $registryGeneration = [string](Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'generation_id' -Default '')
    $registryServerSession = [string](Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'server_session_id' -Default '')
    $registryBootstrapPane = [string](Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'bootstrap_pane_id' -Default '')
    $registryExpectedPaneCount = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'expected_pane_count' -Default $null)

    if ([string]::IsNullOrWhiteSpace($manifestSessionName) -or
        [string]::IsNullOrWhiteSpace($manifestGeneration) -or
        [string]::IsNullOrWhiteSpace($manifestServerSession) -or
        $manifestSessionName -cne $registrySessionName -or
        -not [string]::Equals($manifestGeneration, $registryGeneration, [System.StringComparison]::Ordinal) -or
        $manifestServerSession -cne $registryServerSession -or
        $manifestBootstrapPane -cne $registryBootstrapPane -or
        $null -eq $manifestExpectedPaneCount -or $manifestExpectedPaneCount -lt 1 -or
        $null -eq $registryExpectedPaneCount -or $registryExpectedPaneCount -ne $manifestExpectedPaneCount -or
        ((-not [string]::IsNullOrWhiteSpace($manifestBootstrapPane)) -and $manifestBootstrapPane -cnotmatch '^%[0-9]+$') -or
        $registryServerSession -cne $ObservedServerSessionId) {
        return & $regeneration 'Manifest, registry, generation, or observed server session identity does not match.'
    }

    $supervisor = Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'supervisor'
    $supervisorPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $supervisor -Name 'pid' -Default $null)
    $supervisorStartedAt = [string](Get-WinsmuxRuntimeValue -InputObject $supervisor -Name 'process_started_at' -Default '')
    if ($null -eq $supervisorPid -or -not (Test-WinsmuxStrictProcessIdentity -ProcessId $supervisorPid -ExpectedStartTime $supervisorStartedAt -ProcessResolver $ProcessResolver)) {
        return & $invalidSupervisor 'Supervisor PID and exact UTC process StartTime could not be verified.'
    }

    $lease = Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'lease'
    $leaseState = [string](Get-WinsmuxRuntimeValue -InputObject $lease -Name 'state' -Default '')
    $leaseExpiresAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $lease -Name 'expires_at' -Default '')
    $nowUtc = ConvertTo-WinsmuxRuntimeUtcIdentity -Value $Now
    if ($leaseState -cne 'active' -or [string]::IsNullOrWhiteSpace($leaseExpiresAt) -or $leaseExpiresAt -cle $nowUtc) {
        return & $invalidSupervisor 'Supervisor ownership lease is missing, malformed, inactive, or expired.'
    }

    $registryPanes = @(Get-WinsmuxRuntimeValue -InputObject $Registry -Name 'panes' -Default @())
    $manifestPanes = ConvertTo-ManifestPropertyMap -Value (Get-WinsmuxRuntimeValue -InputObject $Manifest -Name 'panes' -Default $null)
    if (-not (Test-WinsmuxRuntimePaneSet -ManifestPanes $manifestPanes -RegistryPanes $registryPanes `
            -ObservedPanes $ObservedPanes -ExpectedPaneCount $manifestExpectedPaneCount `
            -BootstrapPaneId $manifestBootstrapPane)) {
        return & $targetMismatch 'Desired manifest, runtime registry, and observed pane sets do not match exactly.'
    }

    if ($null -eq $ManifestEntry) {
        return & $targetMismatch 'Target manifest entry is missing.'
    }

    $label = [string](Get-WinsmuxRuntimeValue -InputObject $ManifestEntry -Name 'Label' -Default '')
    $slotId = [string](Get-WinsmuxRuntimeValue -InputObject $ManifestEntry -Name 'SlotId' -Default '')
    $paneId = [string](Get-WinsmuxRuntimeValue -InputObject $ManifestEntry -Name 'PaneId' -Default '')
    $backend = [string](Get-WinsmuxRuntimeValue -InputObject $ManifestEntry -Name 'WorkerBackend' -Default '')
    $role = Resolve-WinsmuxRuntimeRole `
        -WorkerRole ([string](Get-WinsmuxRuntimeValue -InputObject $ManifestEntry -Name 'WorkerRole' -Default '')) `
        -CanonicalRole ([string](Get-WinsmuxRuntimeValue -InputObject $ManifestEntry -Name 'Role' -Default ''))
    $title = [string](Get-WinsmuxRuntimeValue -InputObject $ManifestEntry -Name 'Title' -Default '')

    $registryPane = @($registryPanes | Where-Object {
        [string](Get-WinsmuxRuntimeValue -InputObject $_ -Name 'label' -Default '') -ceq $label
    })
    if ($registryPane.Count -ne 1) {
        return & $targetMismatch 'Target does not resolve to exactly one runtime registry entry.'
    }
    $registryPane = $registryPane[0]

    if (-not $manifestPanes.Contains($label)) {
        return & $targetMismatch 'Target is not present in the desired manifest pane map.'
    }
    $manifestPane = $manifestPanes[$label]
    $manifestRole = Resolve-WinsmuxRuntimeRole `
        -WorkerRole ([string](Get-WinsmuxRuntimeValue -InputObject $manifestPane -Name 'worker_role' -Default '')) `
        -CanonicalRole ([string](Get-WinsmuxRuntimeValue -InputObject $manifestPane -Name 'role' -Default ''))
    if ([string](Get-WinsmuxRuntimeValue -InputObject $manifestPane -Name 'slot_id' -Default '') -cne $slotId -or
        [string](Get-WinsmuxRuntimeValue -InputObject $manifestPane -Name 'pane_id' -Default '') -cne $paneId -or
        [string](Get-WinsmuxRuntimeValue -InputObject $manifestPane -Name 'worker_backend' -Default '') -cne $backend -or
        $manifestRole -cne $role -or
        [string](Get-WinsmuxRuntimeValue -InputObject $manifestPane -Name 'title' -Default '') -cne $title) {
        return & $targetMismatch 'Target entry does not match the desired manifest pane map.'
    }

    $registryState = [string](Get-WinsmuxRuntimeValue -InputObject $registryPane -Name 'state' -Default '')
    if ([string](Get-WinsmuxRuntimeValue -InputObject $registryPane -Name 'slot_id' -Default '') -cne $slotId -or
        [string](Get-WinsmuxRuntimeValue -InputObject $registryPane -Name 'pane_id' -Default '') -cne $paneId -or
        [string](Get-WinsmuxRuntimeValue -InputObject $registryPane -Name 'backend' -Default '') -cne $backend -or
        [string](Get-WinsmuxRuntimeValue -InputObject $registryPane -Name 'role' -Default '') -cne $role -or
        [string](Get-WinsmuxRuntimeValue -InputObject $registryPane -Name 'title' -Default '') -cne $title) {
        return & $targetMismatch 'Runtime target state, slot, pane, backend, role, or title does not match the manifest target.'
    }

    if ($Operation -ceq 'stop_transition') {
        return New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'stop_transition_verified' `
            -Diagnostic 'Captured runtime generation and target identity verified for an intentional stop transition.' `
            -Context ([PSCustomObject][ordered]@{
                session_name = $registrySessionName; server_session_id = $registryServerSession
                generation_id = $registryGeneration; label = $label; slot_id = $slotId; pane_id = $paneId
                backend = $backend; role = $role; title = $title; runtime_state = $registryState
            })
    }

    if ($Operation -ceq 'start_deferred') {
        $manifestStatus = [string](Get-WinsmuxRuntimeValue -InputObject $ManifestEntry -Name 'Status' -Default '')
        $statusClassification = Get-WinsmuxRuntimeStatusClassification -Status $manifestStatus
        if ($registryState -cne 'deferred' -or
            -not [bool]$statusClassification.IsDeferred) {
            return & $targetMismatch 'Only an explicitly deferred target may enter deferred startup.'
        }
        if ($null -ne $PaneMarker) {
            $normalizedDeferredStatus = [string]$statusClassification.NormalizedStatus
            $isFailedDeferredRetry = $normalizedDeferredStatus -ceq 'deferred_start_failed'
            $isDeferredStartingObservation = $normalizedDeferredStatus -ceq 'deferred_starting'
            if (-not $isFailedDeferredRetry -and -not $isDeferredStartingObservation) {
                return & $targetMismatch 'A pane marker already exists; deferred startup would duplicate or overwrite a bootstrap identity.'
            }

            $retryMarkerPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'bootstrap_pid' -Default $null)
            $retryMarkerStartedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'bootstrap_process_started_at' -Default '')
            if ([string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'state' -Default '') -cne 'bootstrap_pending' -or
                -not [string]::Equals(
                    [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'generation_id' -Default ''),
                    $registryGeneration,
                    [System.StringComparison]::Ordinal) -or
                [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'server_session_id' -Default '') -cne $registryServerSession -or
                [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'slot_id' -Default '') -cne $slotId -or
                [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'pane_id' -Default '') -cne $paneId -or
                [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'backend' -Default '') -cne $backend -or
                [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'role' -Default '') -cne $role -or
                [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'title' -Default '') -cne $title -or
                $null -eq $retryMarkerPid -or [string]::IsNullOrWhiteSpace($retryMarkerStartedAt)) {
                return & $targetMismatch 'Failed deferred retry marker does not match the current runtime target identity.'
            }

            $markerProcessState = if (Test-WinsmuxStrictProcessIdentity -ProcessId $retryMarkerPid `
                    -ExpectedStartTime $retryMarkerStartedAt -ProcessResolver $ProcessResolver) {
                'live'
            } else {
                'stale'
            }
            $markerReasonCode = if ($isFailedDeferredRetry) {
                'deferred_retry_marker_verified'
            } else {
                'deferred_starting_marker_verified'
            }
            $markerDiagnostic = if ($isFailedDeferredRetry) {
                'Failed deferred retry marker is authenticated for bounded reuse or stale-marker recovery.'
            } else {
                'Deferred-starting marker is authenticated for readiness observation or failure recording.'
            }
            return New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode $markerReasonCode `
                -Diagnostic $markerDiagnostic `
                -Context ([PSCustomObject][ordered]@{
                    session_name = $registrySessionName; server_session_id = $registryServerSession
                    generation_id = $registryGeneration; label = $label; slot_id = $slotId; pane_id = $paneId
                    backend = $backend; role = $role; title = $title; runtime_state = 'deferred'
                    marker_process_state = $markerProcessState
                    retry_marker_state = if ($isFailedDeferredRetry) { $markerProcessState } else { '' }
                    retry_marker_pid = $retryMarkerPid
                    retry_marker_process_started_at = $retryMarkerStartedAt
                })
        }
        return New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'deferred_runtime_verified' `
            -Diagnostic 'Deferred runtime target identity verified before startup.' -Context ([PSCustomObject][ordered]@{
                session_name = $registrySessionName; server_session_id = $registryServerSession
                generation_id = $registryGeneration; label = $label; slot_id = $slotId; pane_id = $paneId
                backend = $backend; role = $role; title = $title; runtime_state = 'deferred'
            })
    }

    if ($registryState -cne 'live') {
        return & $targetMismatch 'Dispatch requires a live runtime target established after bootstrap readiness.'
    }

    if ($null -eq $PaneMarker) {
        return & $targetMismatch 'Live target bootstrap marker is missing.'
    }

    $bootstrapPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $registryPane -Name 'bootstrap_pid' -Default $null)
    $bootstrapStartedAt = [string](Get-WinsmuxRuntimeValue -InputObject $registryPane -Name 'bootstrap_process_started_at' -Default '')
    $markerBootstrapPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'bootstrap_pid' -Default $null)
    if ($null -eq $bootstrapPid -or $null -eq $markerBootstrapPid -or
        -not [string]::Equals(
            [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'generation_id' -Default ''),
            $registryGeneration,
            [System.StringComparison]::Ordinal) -or
        [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'server_session_id' -Default '') -cne $registryServerSession -or
        [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'slot_id' -Default '') -cne $slotId -or
        [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'pane_id' -Default '') -cne $paneId -or
        [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'backend' -Default '') -cne $backend -or
        [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'role' -Default '') -cne $role -or
        [string](Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'title' -Default '') -cne $title -or
        $markerBootstrapPid -ne $bootstrapPid -or
        (ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $PaneMarker -Name 'bootstrap_process_started_at' -Default '')) -cne (ConvertTo-WinsmuxRuntimeUtcIdentity -Value $bootstrapStartedAt) -or
        -not (Test-WinsmuxStrictProcessIdentity -ProcessId $bootstrapPid -ExpectedStartTime $bootstrapStartedAt -ProcessResolver $ProcessResolver)) {
        return & $targetMismatch 'Live pane marker does not match the runtime registry and current bootstrap process identity.'
    }

    $requiresCallerIdentity = $Operation -ceq 'workflow_ack' -or ($Operation -ceq 'caller_ack' -and $backend -in @('local', 'codex'))
    $callerPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $CallerIdentity -Name 'process_id' -Default $null)
    $callerStartedAt = [string](Get-WinsmuxRuntimeValue -InputObject $CallerIdentity -Name 'process_started_at' -Default '')
    if ($requiresCallerIdentity -and ($null -eq $CallerIdentity -or $null -eq $callerPid -or
        -not [string]::Equals(
            [string](Get-WinsmuxRuntimeValue -InputObject $CallerIdentity -Name 'generation_id' -Default ''),
            $registryGeneration,
            [System.StringComparison]::Ordinal) -or
        [string](Get-WinsmuxRuntimeValue -InputObject $CallerIdentity -Name 'server_session_id' -Default '') -cne $registryServerSession -or
        [string](Get-WinsmuxRuntimeValue -InputObject $CallerIdentity -Name 'slot_id' -Default '') -cne $slotId -or
        [string](Get-WinsmuxRuntimeValue -InputObject $CallerIdentity -Name 'pane_id' -Default '') -cne $paneId -or
        [string](Get-WinsmuxRuntimeValue -InputObject $CallerIdentity -Name 'backend' -Default '') -cne $backend -or
        -not (Test-WinsmuxStrictProcessIdentity -ProcessId $callerPid -ExpectedStartTime $callerStartedAt -ProcessResolver $ProcessResolver))) {
        return & $callerMismatch 'Caller evidence does not bind to the verified pane bootstrap identity.'
    }

    $visitedCallerPids = [System.Collections.Generic.HashSet[int]]::new()
    $nextCallerPid = if ($null -eq $callerPid) { 0 } else { $callerPid }
    $reachedBootstrap = $false
    $sawCodexProcess = $false
    foreach ($depth in 0..63) {
        if ($nextCallerPid -lt 1 -or -not $visitedCallerPids.Add($nextCallerPid)) {
            break
        }

        try {
            $processSnapshot = & $ProcessResolver $nextCallerPid
        } catch {
            $processSnapshot = $null
        }
        if ($null -eq $processSnapshot) {
            break
        }

        $snapshotPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $processSnapshot -Name 'Id' -Default (Get-WinsmuxRuntimeValue -InputObject $processSnapshot -Name 'ProcessId' -Default $null))
        $snapshotStartedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $processSnapshot -Name 'StartTime' -Default (Get-WinsmuxRuntimeValue -InputObject $processSnapshot -Name 'CreationDate' -Default ''))
        $snapshotName = [string](Get-WinsmuxRuntimeValue -InputObject $processSnapshot -Name 'Name' -Default (Get-WinsmuxRuntimeValue -InputObject $processSnapshot -Name 'ProcessName' -Default ''))
        if ($null -eq $snapshotPid -or $snapshotPid -ne $nextCallerPid -or [string]::IsNullOrWhiteSpace($snapshotStartedAt)) {
            break
        }

        if ($snapshotName -match '^(?i:codex)(\.exe)?$') {
            $sawCodexProcess = $true
        }
        if ($snapshotPid -eq $bootstrapPid) {
            if ($snapshotStartedAt -ceq (ConvertTo-WinsmuxRuntimeUtcIdentity -Value $bootstrapStartedAt)) {
                $reachedBootstrap = $true
            }
            break
        }

        $parentPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $processSnapshot -Name 'ParentProcessId' -Default $null)
        if ($null -eq $parentPid -or $parentPid -lt 1) {
            break
        }
        $nextCallerPid = $parentPid
    }

    if ($requiresCallerIdentity -and (-not $reachedBootstrap -or ($backend -ceq 'codex' -and -not $sawCodexProcess))) {
        return & $callerMismatch 'Observed OS process ancestry does not reach the verified pane bootstrap identity for this backend.'
    }

    $context = [PSCustomObject][ordered]@{
        session_name      = $registrySessionName
        server_session_id = $registryServerSession
        generation_id     = $registryGeneration
        label             = $label
        slot_id           = $slotId
        pane_id           = $paneId
        backend           = $backend
        role              = $role
        title             = $title
    }
    return New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' -Diagnostic 'Runtime identity verified.' -Context $context
}

function Clear-WinsmuxManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [AllowEmptyString()][string]$ExpectedGenerationId = ''
    )

    $path = Get-ManifestPath -ProjectDir $ProjectDir
    return [bool](Invoke-WinsmuxWithFileLock -Path $path -Action {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }

        if (-not [string]::IsNullOrWhiteSpace($ExpectedGenerationId)) {
            $currentManifest = Get-WinsmuxManifest -ProjectDir $ProjectDir
            $currentIdentity = Get-WinsmuxVerifiedManifestIdentity -Manifest $currentManifest
            if ($null -eq $currentIdentity) {
                throw 'runtime dispatch refused (manifest_regeneration_required): Current manifest cannot be verified at the locked clear boundary.'
            }
            if (-not [string]::Equals(
                    [string]$currentIdentity.generation_id,
                    $ExpectedGenerationId,
                    [System.StringComparison]::Ordinal)) {
                throw 'runtime dispatch refused (invalid_supervisor_identity): Runtime generation changed at the locked manifest clear boundary.'
            }
        }

        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        return $true
    })
}

function New-WinsmuxManifest {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $now = [System.DateTimeOffset]::Now.ToString('o')
    $manifest = [PSCustomObject]@{
        version  = 1
        saved_at = $now
        session  = [PSCustomObject]@{
            started = $now
            ended   = ''
        }
        panes     = [ordered]@{}
        tasks     = [PSCustomObject]@{
            queued      = @()
            in_progress = @()
            completed   = @()
        }
        worktrees = [ordered]@{}
    }

    Save-WinsmuxManifest -ProjectDir $ProjectDir -Manifest $manifest
    return $manifest
}

function Get-WinsmuxManifest {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $path = Get-ManifestPath -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ConvertFrom-ManifestYaml -Content $raw
}

function Get-WinsmuxVerifiedManifestIdentity {
    param([AllowNull()]$Manifest)

    if ($null -eq $Manifest) { return $null }
    $version = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $Manifest -Name 'version' -Default $null)
    $session = Get-WinsmuxRuntimeValue -InputObject $Manifest -Name 'session'
    if ($null -eq $version -or $version -ne 2 -or $null -eq $session) { return $null }

    $identity = [PSCustomObject][ordered]@{
        session_name      = [string](Get-WinsmuxRuntimeValue -InputObject $session -Name 'name' -Default '')
        generation_id     = [string](Get-WinsmuxRuntimeValue -InputObject $session -Name 'generation_id' -Default '')
        server_session_id = [string](Get-WinsmuxRuntimeValue -InputObject $session -Name 'server_session_id' -Default '')
        bootstrap_pane_id = [string](Get-WinsmuxRuntimeValue -InputObject $session -Name 'bootstrap_pane_id' -Default '')
    }
    if ([string]::IsNullOrWhiteSpace($identity.session_name) -or
        [string]::IsNullOrWhiteSpace($identity.generation_id) -or
        [string]::IsNullOrWhiteSpace($identity.server_session_id) -or
        $identity.bootstrap_pane_id -cnotmatch '^%[0-9]+$') {
        return $null
    }
    return $identity
}

function Save-WinsmuxManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Manifest,
        [AllowEmptyString()][string]$ExpectedGenerationId = ''
    )

    $path = Get-ManifestPath -ProjectDir $ProjectDir
    $nextVersion = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $Manifest -Name 'version' -Default $null)
    $nextIdentity = Get-WinsmuxVerifiedManifestIdentity -Manifest $Manifest
    $yaml = ConvertTo-ManifestYaml -Manifest $Manifest
    $validateLocked = {
        $currentExists = Test-Path -LiteralPath $path -PathType Leaf
        if (-not $currentExists) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedGenerationId)) {
                throw 'runtime dispatch refused (manifest_regeneration_required): Guarded v2 manifest mutation requires an existing verified document.'
            }
            return
        }

        $currentRaw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $currentManifest = $null
        if (-not [string]::IsNullOrWhiteSpace($currentRaw)) {
            try {
                $currentManifest = ConvertFrom-ManifestYaml -Content $currentRaw
            }
            catch {
                throw 'runtime dispatch refused (manifest_regeneration_required): Current manifest cannot be verified at the locked save boundary.'
            }
        }
        $currentVersion = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $currentManifest -Name 'version' -Default $null)

        $isPureV1Save = $currentVersion -eq 1 -and
            $nextVersion -eq 1 -and
            [string]::IsNullOrWhiteSpace($ExpectedGenerationId)
        if ($isPureV1Save) {
            return
        }
        if ($currentVersion -ne 2 -or $nextVersion -ne 2) {
            if ($currentVersion -eq 2) {
                throw 'runtime dispatch refused (manifest_regeneration_required): Refusing to replace a verified v2 runtime manifest with an unverified or downgraded document.'
            }
            throw 'runtime dispatch refused (manifest_regeneration_required): Refusing to replace a runtime manifest unless both locked current and next documents are schema v2.'
        }

        $currentIdentity = Get-WinsmuxVerifiedManifestIdentity -Manifest $currentManifest
        if ($null -eq $currentIdentity -or $null -eq $nextIdentity) {
            throw 'runtime dispatch refused (manifest_regeneration_required): Refusing to replace a verified v2 runtime manifest with an unverified document.'
        }
        if ([string]::IsNullOrWhiteSpace($ExpectedGenerationId)) {
            throw 'runtime dispatch refused (invalid_supervisor_identity): Refusing to replace a verified v2 runtime manifest without ExpectedGenerationId.'
        }
        if (-not [string]::Equals(
                [string]$currentIdentity.generation_id,
                $ExpectedGenerationId,
                [System.StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$nextIdentity.generation_id,
                $ExpectedGenerationId,
                [System.StringComparison]::Ordinal)) {
            throw 'runtime dispatch refused (invalid_supervisor_identity): Runtime generation changed at the locked manifest save boundary.'
        }
        if ($currentIdentity.session_name -cne $nextIdentity.session_name -or
            $currentIdentity.server_session_id -cne $nextIdentity.server_session_id -or
            $currentIdentity.bootstrap_pane_id -cne $nextIdentity.bootstrap_pane_id) {
            throw 'runtime dispatch refused (runtime_target_mismatch): Refusing to replace a verified v2 runtime manifest with a different runtime identity.'
        }
    }
    Write-ManifestTextFile -Path $path -Content $yaml -ValidateLocked $validateLocked
}

function ConvertTo-ManifestPaneEntry {
    param([Parameter(Mandatory = $true)]$PaneSummary)

    $entry = [ordered]@{}
    $paneMap = ConvertTo-ManifestPropertyMap -Value $PaneSummary
    foreach ($key in $paneMap.Keys) {
        if ($key -eq 'Label') {
            continue
        }

        $entry[(ConvertTo-ManifestKeyName -Name $key)] = $paneMap[$key]
    }

    return $entry
}

function Update-ManifestPanes {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][array]$PaneSummaries
    )

    $projectDir = Split-Path (Split-Path $ManifestPath -Parent) -Parent
    $manifest = Get-WinsmuxManifest -ProjectDir $projectDir
    if ($null -eq $manifest) {
        throw "Manifest not found at: $ManifestPath"
    }

    $panes = [ordered]@{}
    foreach ($pane in $PaneSummaries) {
        $panes[[string]$pane.Label] = ConvertTo-ManifestPaneEntry -PaneSummary $pane
    }

    $manifest.panes = $panes
    Save-WinsmuxManifest -ProjectDir $projectDir -Manifest $manifest
}

function Update-ManifestTasks {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$InProgress,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Completed
    )

    $projectDir = Split-Path (Split-Path $ManifestPath -Parent) -Parent
    $manifest = Get-WinsmuxManifest -ProjectDir $projectDir
    if ($null -eq $manifest) {
        throw "Manifest not found at: $ManifestPath"
    }

    $queued = @()
    if ($null -ne $manifest.tasks -and $null -ne $manifest.tasks.queued) {
        $queued = @($manifest.tasks.queued)
    }

    $manifest.tasks = [PSCustomObject]@{
        queued      = @($queued)
        in_progress = @($InProgress)
        completed   = @($Completed)
    }

    Save-WinsmuxManifest -ProjectDir $projectDir -Manifest $manifest
}

function ConvertTo-ManifestYaml {
    param([Parameter(Mandatory = $true)]$Manifest)

    $manifestMap = ConvertTo-ManifestPropertyMap -Value $Manifest
    $sessionMap = ConvertTo-ManifestPropertyMap -Value $manifestMap['session']
    $panesMap = ConvertTo-ManifestPropertyMap -Value $manifestMap['panes']
    $tasksMap = ConvertTo-ManifestPropertyMap -Value $manifestMap['tasks']
    $worktreesMap = ConvertTo-ManifestPropertyMap -Value $manifestMap['worktrees']

    $lines = [System.Collections.Generic.List[string]]::new()
    $manifestVersion = ConvertTo-WinsmuxRuntimeInteger -Value $(if ($manifestMap.Contains('version')) { $manifestMap['version'] } else { 1 })
    if ($null -eq $manifestVersion) {
        throw 'manifest serialization rejected: version must be an integer.'
    }
    $lines.Add(('version: {0}' -f $manifestVersion)) | Out-Null
    $lines.Add(('saved_at: {0}' -f (ConvertTo-ManifestYamlScalar -Value $(if ($manifestMap.Contains('saved_at')) { $manifestMap['saved_at'] } else { [System.DateTimeOffset]::Now.ToString('o') })))) | Out-Null
    $lines.Add('session:') | Out-Null
    foreach ($key in $sessionMap.Keys) {
        $lines.Add(('  {0}: {1}' -f $key, (ConvertTo-ManifestYamlValue -Value $sessionMap[$key]))) | Out-Null
    }

    $lines.Add('panes:') | Out-Null
    if ($panesMap.Count -eq 0) {
        $lines[$lines.Count - 1] = 'panes: {}'
    } else {
        foreach ($label in $panesMap.Keys) {
            $lines.Add(('  {0}:' -f (ConvertTo-ManifestYamlScalar -Value $label))) | Out-Null
            $paneMap = ConvertTo-ManifestPropertyMap -Value $panesMap[$label]
            foreach ($key in $paneMap.Keys) {
                $lines.Add(('    {0}: {1}' -f $key, (ConvertTo-ManifestYamlValue -Value $paneMap[$key]))) | Out-Null
            }
        }
    }

    $lines.Add('tasks:') | Out-Null
    foreach ($taskKey in @('queued', 'in_progress', 'completed')) {
        $lines.Add(('  {0}:' -f $taskKey)) | Out-Null
        $items = @()
        if ($tasksMap.Contains($taskKey) -and $null -ne $tasksMap[$taskKey]) {
            $items = @($tasksMap[$taskKey])
        }

        if ($items.Count -eq 0) {
            $lines[$lines.Count - 1] = ('  {0}: []' -f $taskKey)
        } else {
            foreach ($item in $items) {
                $lines.Add(('    - {0}' -f (ConvertTo-ManifestYamlScalar -Value $item))) | Out-Null
            }
        }
    }

    $lines.Add('worktrees:') | Out-Null
    if ($worktreesMap.Count -eq 0) {
        $lines[$lines.Count - 1] = 'worktrees: {}'
    } else {
        foreach ($label in $worktreesMap.Keys) {
            $lines.Add(('  {0}:' -f (ConvertTo-ManifestYamlScalar -Value $label))) | Out-Null
            $worktreeEntry = ConvertTo-ManifestPropertyMap -Value $worktreesMap[$label]
            foreach ($key in $worktreeEntry.Keys) {
                $lines.Add(('    {0}: {1}' -f $key, (ConvertTo-ManifestYamlValue -Value $worktreeEntry[$key]))) | Out-Null
            }
        }
    }

    if ($manifestMap.Contains('declarative_workspace') -and $null -ne $manifestMap['declarative_workspace']) {
        Add-ManifestYamlNode -Lines $lines -Name 'declarative_workspace' -Value $manifestMap['declarative_workspace']
    }

    $coreKeys = @('version', 'saved_at', 'session', 'panes', 'tasks', 'worktrees', 'declarative_workspace', '__preserved_top_level_yaml')
    foreach ($key in $manifestMap.Keys) {
        if ($key -in $coreKeys -or $key.StartsWith('__', [System.StringComparison]::Ordinal)) {
            continue
        }
        Add-ManifestYamlNode -Lines $lines -Name ([string]$key) -Value $manifestMap[$key]
    }
    if ($manifestMap.Contains('__preserved_top_level_yaml')) {
        $materializedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($key in $manifestMap.Keys) {
            $keyText = [string]$key
            if ($keyText -ceq 'declarative_workspace') {
                if ($null -ne $manifestMap[$key]) {
                    [void]$materializedKeys.Add($keyText)
                }
                continue
            }
            if ($key -notin $coreKeys -and
                -not $keyText.StartsWith('__', [System.StringComparison]::Ordinal)) {
                [void]$materializedKeys.Add($keyText)
            }
        }

        foreach ($block in @($manifestMap['__preserved_top_level_yaml'])) {
            if (-not [string]::IsNullOrWhiteSpace([string]$block)) {
                $firstLine = (([string]$block) -split "\r?\n", 2)[0]
                $preservedKey = ConvertFrom-ManifestTopLevelYamlKey -Line $firstLine
                if ($null -ne $preservedKey -and $materializedKeys.Contains($preservedKey)) {
                    continue
                }
                $lines.Add(([string]$block).TrimEnd()) | Out-Null
            }
        }
    }

    return ($lines -join "`n") + "`n"
}

function ConvertFrom-ManifestYaml {
    param([Parameter(Mandatory = $true)][string]$Content)

    Assert-ManifestYamlBlockMappingRoot -Content $Content

    $manifest = [PSCustomObject]@{
        version  = 1
        saved_at = ''
        session  = [PSCustomObject]@{}
        panes    = [ordered]@{}
        tasks    = [PSCustomObject]@{
            queued      = @()
            in_progress = @()
            completed   = @()
        }
        worktrees = [ordered]@{}
    }

    $section = ''
    $opaqueTopLevel = $false
    $currentLabel = ''
    $currentMode = ''
    $taskListKey = ''
    $observedVersion2 = $false
    $seenTopLevel = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenSessionKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenPaneLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenPaneKeys = [ordered]@{}
    $seenWorktreeLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenWorktreeKeys = [ordered]@{}
    $duplicatePaths = [System.Collections.Generic.List[string]]::new()
    $seenDuplicatePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $recordDuplicate = {
        param([Parameter(Mandatory = $true)][string]$Path)
        if ($seenDuplicatePaths.Add($Path)) {
            $duplicatePaths.Add($Path) | Out-Null
        }
    }

    foreach ($rawLine in ($Content -split "\r?\n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
            continue
        }

        if ($null -ne (ConvertFrom-ManifestTopLevelYamlKey -Line $line)) {
            $opaqueTopLevel = $false
        }

        if ($line -match '^version:\s*(.*?)\s*$') {
            if (-not $seenTopLevel.Add('version')) { & $recordDuplicate 'version' }
            $manifest.version = [int](ConvertFrom-ManifestYamlScalar $Matches[1])
            if ($manifest.version -eq 2) { $observedVersion2 = $true }
            continue
        }

        if ($line -match '^saved_at:\s*(.*?)\s*$') {
            if (-not $seenTopLevel.Add('saved_at')) { & $recordDuplicate 'saved_at' }
            $manifest.saved_at = [string](ConvertFrom-ManifestYamlScalar $Matches[1])
            continue
        }

        if ($line -match '^(session|panes|tasks|worktrees):\s*(\{\})?\s*$') {
            $section = $Matches[1]
            if (-not $seenTopLevel.Add($section)) { & $recordDuplicate $section }
            $currentLabel = ''
            $currentMode = ''
            $taskListKey = ''
            continue
        }

        if ($null -ne (ConvertFrom-ManifestTopLevelYamlKey -Line $line)) {
            # Unknown additive top-level sections are retained as raw YAML blocks.
            # Stop interpreting their nested lines as part of the preceding known section.
            $section = ''
            $opaqueTopLevel = $true
            $currentLabel = ''
            $currentMode = ''
            $taskListKey = ''
            continue
        }

        if ($opaqueTopLevel) {
            continue
        }

        if ($section -eq 'session' -and $line -match '^\s{2}' -and $line -notmatch '^\s{2}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
            throw 'manifest parse rejected: session entries must use canonical scalar keys.'
        }
        if ($section -eq 'session' -and $line -match '^\s{2}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
            $propertyName = [string]$Matches[1]
            if (-not $seenSessionKeys.Add($propertyName)) { & $recordDuplicate ("session.{0}" -f $propertyName) }
            $manifest.session | Add-Member -NotePropertyName $propertyName -NotePropertyValue (ConvertFrom-ManifestYamlValue $Matches[2]) -Force
            continue
        }

        if ($section -eq 'panes') {
            if ($line -match '^\s{2}-\s+label:\s*(.*?)\s*$') {
                $currentLabel = [string](ConvertFrom-ManifestYamlScalar $Matches[1])
                if (-not $seenPaneLabels.Add($currentLabel)) { & $recordDuplicate ("panes.{0}" -f $currentLabel) }
                if (-not $manifest.panes.Contains($currentLabel)) {
                    $manifest.panes[$currentLabel] = [ordered]@{ label = $currentLabel }
                }
                if (-not $seenPaneKeys.Contains($currentLabel)) {
                    $seenPaneKeys[$currentLabel] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                }
                $currentMode = 'list'
                continue
            }

            if ($line -match '^\s{2}(.+?):\s*$') {
                $currentLabel = [string](ConvertFrom-ManifestYamlScalar $Matches[1])
                if (-not $seenPaneLabels.Add($currentLabel)) { & $recordDuplicate ("panes.{0}" -f $currentLabel) }
                if (-not $manifest.panes.Contains($currentLabel)) {
                    $manifest.panes[$currentLabel] = [ordered]@{}
                }
                if (-not $seenPaneKeys.Contains($currentLabel)) {
                    $seenPaneKeys[$currentLabel] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                }
                $currentMode = 'dict'
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($currentLabel) -and $line -match '^\s{4}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
                $propertyName = [string]$Matches[1]
                if (-not $seenPaneKeys[$currentLabel].Add($propertyName)) {
                    & $recordDuplicate ("panes.{0}.{1}" -f $currentLabel, $propertyName)
                }
                $manifest.panes[$currentLabel][$propertyName] = ConvertFrom-ManifestYamlValue $Matches[2]
                continue
            }
        }

        if ($section -eq 'tasks') {
            if ($line -match '^\s{2}(queued|in_progress|completed):\s*(\[\])?\s*$') {
                $taskListKey = $Matches[1]
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($taskListKey) -and $line -match '^\s{4}-\s*(.*?)\s*$') {
                $items = @($manifest.tasks.$taskListKey)
                $manifest.tasks.$taskListKey = @($items + (ConvertFrom-ManifestYamlScalar $Matches[1]))
                continue
            }
        }

        if ($section -eq 'worktrees') {
            if ($line -match '^\s{2}(.+?):\s*$') {
                $currentLabel = [string](ConvertFrom-ManifestYamlScalar $Matches[1])
                if (-not $seenWorktreeLabels.Add($currentLabel)) { & $recordDuplicate ("worktrees.{0}" -f $currentLabel) }
                if (-not $manifest.worktrees.Contains($currentLabel)) {
                    $manifest.worktrees[$currentLabel] = [ordered]@{}
                }
                if (-not $seenWorktreeKeys.Contains($currentLabel)) {
                    $seenWorktreeKeys[$currentLabel] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                }
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($currentLabel) -and $line -match '^\s{4}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
                $propertyName = [string]$Matches[1]
                if (-not $seenWorktreeKeys[$currentLabel].Add($propertyName)) {
                    & $recordDuplicate ("worktrees.{0}.{1}" -f $currentLabel, $propertyName)
                }
                $manifest.worktrees[$currentLabel][$propertyName] = ConvertFrom-ManifestYamlValue $Matches[2]
                continue
            }
        }

        throw 'manifest parse rejected: unsupported canonical manifest syntax.'
    }

    if (($observedVersion2 -or $manifest.version -eq 2) -and $duplicatePaths.Count -gt 0) {
        throw ("duplicate manifest key: {0}" -f [string]$duplicatePaths[0])
    }

    foreach ($label in @($manifest.panes.Keys)) {
        if ($manifest.panes[$label].Contains('label')) {
            $manifest.panes[$label].Remove('label')
        }
    }

    $preservedBlocks = @(Get-ManifestUnknownTopLevelBlocks -Content $Content)
    if ($preservedBlocks.Count -gt 0) {
        $manifest | Add-Member -NotePropertyName '__preserved_top_level_yaml' -NotePropertyValue $preservedBlocks -Force
    }

    return $manifest
}

function New-WinsmuxDeclarativeWorkspaceProjection {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [AllowEmptyString()][string]$DryRunPlanRef = ''
    )

    $configFingerprint = [string]$Plan.config_fingerprint
    if ($configFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Workspace plan config_fingerprint must be a lowercase sha256 digest.'
    }
    $idPattern = '^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$'
    $recipeId = [string]$Plan.recipe_id
    if ($recipeId -cnotmatch $idPattern) {
        throw 'Workspace plan recipe_id must be a stable lowercase ASCII identifier.'
    }
    if (-not [string]::IsNullOrWhiteSpace($DryRunPlanRef) -and
        ($DryRunPlanRef -cnotmatch '^evidence:[a-z0-9][a-z0-9._/-]*$' -or
            $DryRunPlanRef.Contains('..') -or $DryRunPlanRef.Contains('\'))) {
        throw 'Workspace dry_run_plan_ref must be a safe evidence reference.'
    }

    $bindings = [ordered]@{}
    foreach ($entry in (ConvertTo-ManifestPropertyMap -Value $Plan.resolved_bindings).GetEnumerator()) {
        $paneId = [string]$entry.Key
        $slotId = [string]$entry.Value
        if ($paneId -cnotmatch $idPattern -or $slotId -cnotmatch $idPattern) {
            throw 'Workspace plan bindings must use stable lowercase ASCII identifiers.'
        }
        $bindings[$paneId] = $slotId
    }
    $projection = [ordered]@{
        schema_version      = 1
        config_fingerprint = $configFingerprint
        recipe_id          = $recipeId
        resolved_bindings  = $bindings
    }
    if (-not [string]::IsNullOrWhiteSpace($DryRunPlanRef)) {
        $projection['dry_run_plan_ref'] = $DryRunPlanRef
    }
    return $projection
}
