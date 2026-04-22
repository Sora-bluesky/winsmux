<#
.SYNOPSIS
Hierarchical settings loader for winsmux-core.

.DESCRIPTION
Settings are resolved with per-key precedence:
1. .winsmux.yaml in the current directory
2. Global winsmux options (@bridge-*)
3. Built-in defaults

Dot-source this script to load the helpers:

    . "$PSScriptRoot/settings.ps1"
#>

$script:BridgeSettingsFileName = '.winsmux.yaml'
$script:BridgeProviderRegistryFileName = 'provider-registry.json'
$script:BridgeProviderCapabilityRegistryFileName = 'provider-capabilities.json'
$script:BridgeSettingsSchema = [ordered]@{
    config_version      = @{ Type = 'int';      Default = 1;             Option = $null }
    agent               = @{ Type = 'string';   Default = 'codex';       Option = '@bridge-agent' }
    model               = @{ Type = 'string';   Default = 'gpt-5.4';     Option = '@bridge-model' }
    prompt_transport    = @{ Type = 'transport'; Default = 'argv';       Option = '@bridge-prompt-transport' }
    external_operator  = @{ Type = 'bool';     Default = $true;         Option = '@bridge-external-operator' }
    worker_count        = @{ Type = 'int';      Default = 6;             Option = '@bridge-worker-count' }
    agent_slots         = @{ Type = 'slotlist'; Default = @();           Option = $null }
    legacy_role_layout  = @{ Type = 'bool';     Default = $false;        Option = '@bridge-legacy-role-layout' }
    operators          = @{ Type = 'int';      Default = 0;             Option = '@bridge-operators' }
    builders            = @{ Type = 'int';      Default = 0;             Option = '@bridge-builders' }
    researchers         = @{ Type = 'int';      Default = 0;             Option = '@bridge-researchers' }
    reviewers           = @{ Type = 'int';      Default = 0;             Option = '@bridge-reviewers' }
    vault_keys          = @{ Type = 'string[]'; Default = @('GH_TOKEN'); Option = '@bridge-vault-keys' }
    terminal            = @{ Type = 'string';   Default = 'background';  Option = '@bridge-terminal' }
    roles               = @{ Type = 'map';      Default = [ordered]@{};  Option = $null }
}
$script:BridgeRetiredOperatorSettingKeys = @(
    ('external_' + 'comm' + 'ander'),
    ('comm' + 'anders')
)
$script:BridgeRetiredOperatorOptionNames = @(
    ('@bridge-external-' + 'comm' + 'ander'),
    ('@bridge-' + 'comm' + 'anders')
)

function Test-BridgeRetiredOperatorSettingKey {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $key = $Name -replace '-', '_'
    return ($key -in $script:BridgeRetiredOperatorSettingKeys)
}

function Assert-BridgeNoRetiredOperatorSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Source = 'settings'
    )

    if (Test-BridgeRetiredOperatorSettingKey -Name $Name) {
        throw "Retired runtime role setting '$Name' in $Source is no longer supported. Use external_operator or operators."
    }
}

function Assert-BridgeNoRetiredOperatorGlobalSettings {
    foreach ($optionName in $script:BridgeRetiredOperatorOptionNames) {
        $rawValue = Get-WinsmuxOption -Name $optionName -Default $null
        if ($null -eq $rawValue -or [string]::IsNullOrWhiteSpace($rawValue)) {
            continue
        }

        if (Test-WinsmuxOptionFailureText -Value ([string]$rawValue)) {
            continue
        }

        throw "Retired runtime role option '$optionName' is no longer supported. Use @bridge-external-operator or @bridge-operators."
    }
}

if (-not (Get-Command Get-WinsmuxBin -ErrorAction SilentlyContinue)) {
    function Get-WinsmuxBin {
        foreach ($candidate in @('winsmux', 'pmux', 'tmux')) {
            $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $command) {
                if ($command.Path) {
                    return $command.Path
                }

                return $command.Name
            }
        }

        return $null
    }
}

if (-not (Get-Command Get-WinsmuxOperatorNotFoundMessage -ErrorAction SilentlyContinue)) {
    function Get-WinsmuxOperatorNotFoundMessage {
        return 'Could not resolve the winsmux executable from PATH. Install winsmux or expose the winsmux binary before running startup, status, or probe commands.'
    }
}

if (-not (Get-Command Get-WinsmuxOption -ErrorAction SilentlyContinue)) {
    function Test-WinsmuxOptionFailureText {
        param([string]$Value)

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return $true
        }

        return ($Value -match 'unknown|error|invalid|no server running on session|not recognized as the name|is not recognized as a name|failed with exit code|failed to connect|could not connect|no such session')
    }

    function Get-WinsmuxOption {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [string]$Default
        )

        $winsmuxBin = Get-WinsmuxBin
        if (-not $winsmuxBin) {
            return $Default
        }

        try {
            $value = (& $winsmuxBin show-options -g -v $Name 2>&1 | Out-String).Trim()
            if (-not (Test-WinsmuxOptionFailureText -Value $value)) {
                return $value
            }
        } catch {
        }

        return $Default
    }
}

if (-not (Get-Command Set-WinsmuxOption -ErrorAction SilentlyContinue)) {
    function Set-WinsmuxOption {
        param(
            [Parameter(Mandatory = $true)][string]$WinsmuxBin,
            [Parameter(Mandatory = $true)][string]$OptionName,
            [Parameter(Mandatory = $true)][string]$OptionValue
        )

        & $WinsmuxBin set-option -g $OptionName $OptionValue | Out-Null
    }
}

function Get-BridgeSettingsDefaults {
    $defaults = [ordered]@{}
    foreach ($key in $script:BridgeSettingsSchema.Keys) {
        $defaultValue = $script:BridgeSettingsSchema[$key].Default
        if ($defaultValue -is [System.Array]) {
            $defaults[$key] = @($defaultValue)
        } elseif ($defaultValue -is [System.Collections.IDictionary]) {
            $defaults[$key] = [ordered]@{}
            foreach ($entry in $defaultValue.GetEnumerator()) {
                $defaults[$key][$entry.Key] = $entry.Value
            }
        } else {
            $defaults[$key] = $defaultValue
        }
    }

    return $defaults
}

function Get-BridgeProjectSettingsPath {
    param([string]$RootPath)

    if ([string]::IsNullOrWhiteSpace($RootPath)) {
        $RootPath = (Get-Location).Path
    }

    return Join-Path $RootPath $script:BridgeSettingsFileName
}

function Remove-BridgeYamlComment {
    param([string]$Line)

    if ($null -eq $Line) {
        return ''
    }

    $builder = [System.Text.StringBuilder]::new()
    $inSingleQuote = $false
    $inDoubleQuote = $false

    foreach ($character in $Line.ToCharArray()) {
        if ($character -eq "'" -and -not $inDoubleQuote) {
            $inSingleQuote = -not $inSingleQuote
            [void]$builder.Append($character)
            continue
        }

        if ($character -eq '"' -and -not $inSingleQuote) {
            $inDoubleQuote = -not $inDoubleQuote
            [void]$builder.Append($character)
            continue
        }

        if ($character -eq '#' -and -not $inSingleQuote -and -not $inDoubleQuote) {
            break
        }

        [void]$builder.Append($character)
    }

    return $builder.ToString().TrimEnd()
}

function ConvertFrom-BridgeYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = $Value.ToString().Trim()
    if ($text.Length -ge 2) {
        if (($text.StartsWith("'") -and $text.EndsWith("'")) -or ($text.StartsWith('"') -and $text.EndsWith('"'))) {
            $text = $text.Substring(1, $text.Length - 2)
        }
    }

    return $text
}

function ConvertFrom-BridgeInlineList {
    param([string]$Value)

    $trimmed = $Value.Trim()
    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
        return $null
    }

    $inner = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
    if ([string]::IsNullOrWhiteSpace($inner)) {
        return @()
    }

    return @(
        $inner -split ',' |
        ForEach-Object { ConvertFrom-BridgeYamlScalar $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function ConvertTo-BridgeSlotEntry {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $pairs = @()
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = $Value.GetEnumerator()
    } elseif ($null -ne $Value -and $null -ne $Value.PSObject) {
        $pairs = $Value.PSObject.Properties | ForEach-Object {
            [PSCustomObject]@{
                Key = $_.Name
                Value = $_.Value
            }
        }
    } else {
        return $null
    }

    $slot = [ordered]@{}
    foreach ($pair in $pairs) {
        $key = $pair.Key.ToString() -replace '-', '_'
        if ($key -notin @('slot_id', 'runtime_role', 'agent', 'model', 'prompt_transport', 'worktree_mode')) {
            continue
        }

        $text = ConvertFrom-BridgeYamlScalar $pair.Value
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $slot[$key] = $text
    }

    if (-not $slot.Contains('slot_id')) {
        return $null
    }

    if (-not $slot.Contains('runtime_role')) {
        $slot.runtime_role = 'worker'
    }

    return $slot
}

function New-BridgeManagedAgentSlots {
    param(
        [Parameter(Mandatory = $true)][int]$Count,
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model
    )

    $slots = @()
    for ($index = 1; $index -le $Count; $index++) {
        $slots += [ordered]@{
            slot_id       = "worker-$index"
            runtime_role  = 'worker'
            agent         = $Agent
            model         = $Model
            worktree_mode = 'managed'
        }
    }

    return @($slots)
}

function Get-BridgeProviderRegistryPath {
    param([string]$RootPath)

    if ([string]::IsNullOrWhiteSpace($RootPath)) {
        $RootPath = (Get-Location).Path
    }

    return Join-Path (Join-Path $RootPath '.winsmux') $script:BridgeProviderRegistryFileName
}

function Test-BridgeProviderRegistryObject {
    param([AllowNull()]$Value)

    return (($Value -is [System.Collections.IDictionary]) -or ($Value -is [PSCustomObject]))
}

function Test-BridgeProviderRegistryScalarValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $true
    }

    if ($Value -is [string] -or $Value -is [char]) {
        return $true
    }

    return ($Value -is [ValueType])
}

function Get-BridgeProviderRegistryObjectProperties {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [System.Collections.IDictionary]) {
        return @($Value.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{
                Name  = $_.Key
                Value = $_.Value
            }
        })
    }

    return @($Value.PSObject.Properties)
}

function ConvertTo-BridgeProviderRegistryEntry {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $pairs = @()
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = $Value.GetEnumerator()
    } elseif ($Value -is [PSCustomObject]) {
        $pairs = $Value.PSObject.Properties | ForEach-Object {
            [PSCustomObject]@{
                Key = $_.Name
                Value = $_.Value
            }
        }
    } else {
        return $null
    }

    $entry = [ordered]@{}
    foreach ($pair in $pairs) {
        $key = $pair.Key.ToString() -replace '-', '_'
        if ($key -notin @('agent', 'model', 'prompt_transport', 'updated_at_utc', 'reason')) {
            continue
        }

        if (-not (Test-BridgeProviderRegistryScalarValue $pair.Value)) {
            throw "Invalid provider registry field '$key'."
        }

        $text = ConvertFrom-BridgeYamlScalar $pair.Value
        if ([string]::IsNullOrWhiteSpace($text)) {
            if ($key -in @('agent', 'model', 'prompt_transport')) {
                throw "Invalid provider registry field '$key'."
            }

            continue
        }

        if ($key -eq 'prompt_transport' -and $text -notin @('argv', 'file', 'stdin')) {
            throw "Invalid provider registry prompt_transport '$text'."
        }

        $entry[$key] = $text
    }

    if (-not ($entry.Contains('agent') -or $entry.Contains('model') -or $entry.Contains('prompt_transport'))) {
        return $null
    }

    return $entry
}

function Read-BridgeProviderRegistry {
    param([string]$RootPath)

    $path = Get-BridgeProviderRegistryPath -RootPath $RootPath
    $registry = [ordered]@{
        version = 1
        slots   = [ordered]@{}
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $registry
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $registry
    }

    try {
        $parsed = $raw | ConvertFrom-Json -Depth 16 -ErrorAction Stop
    } catch {
        throw "Invalid provider registry JSON at '$path'."
    }

    if (-not (Test-BridgeProviderRegistryObject $parsed)) {
        throw "Invalid provider registry JSON at '$path'."
    }

    $version = 1
    if ($null -ne $parsed.PSObject -and $parsed.PSObject.Properties.Name -contains 'version') {
        $version = [int]$parsed.version
    }
    if ($version -ne 1) {
        throw "Unsupported provider registry version '$version'. Supported versions: 1."
    }

    $registry.version = $version
    if ($null -eq $parsed.PSObject -or -not ($parsed.PSObject.Properties.Name -contains 'slots') -or $null -eq $parsed.slots) {
        return $registry
    }

    if (-not (Test-BridgeProviderRegistryObject $parsed.slots)) {
        throw "Invalid provider registry slots at '$path'."
    }

    foreach ($slotProperty in (Get-BridgeProviderRegistryObjectProperties $parsed.slots)) {
        $slotId = ConvertFrom-BridgeYamlScalar $slotProperty.Name
        if ([string]::IsNullOrWhiteSpace($slotId)) {
            throw "Invalid provider registry slot id at '$path'."
        }

        if (-not (Test-BridgeProviderRegistryObject $slotProperty.Value)) {
            throw "Invalid provider registry slot '$slotId' at '$path'."
        }

        $entry = ConvertTo-BridgeProviderRegistryEntry $slotProperty.Value
        if ($null -eq $entry) {
            throw "Invalid provider registry slot '$slotId' at '$path'."
        }

        $registry.slots[$slotId] = $entry
    }

    return $registry
}

function Get-BridgeProviderRegistryEntry {
    param(
        [Parameter(Mandatory = $true)][string]$SlotId,
        [string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($SlotId)) {
        return $null
    }

    $registry = Read-BridgeProviderRegistry -RootPath $RootPath
    foreach ($entry in $registry.slots.GetEnumerator()) {
        if ([string]::Equals([string]$entry.Key, $SlotId, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $entry.Value
        }
    }

    return $null
}

function Write-BridgeProviderRegistryEntry {
    param(
        [Parameter(Mandatory = $true)][string]$SlotId,
        [string]$Agent,
        [string]$Model,
        [string]$PromptTransport,
        [string]$Reason,
        [string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($SlotId)) {
        throw 'Provider registry entry requires a slot id.'
    }

    $entry = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($Agent)) {
        $entry.agent = $Agent.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $entry.model = $Model.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($PromptTransport)) {
        $normalizedTransport = $PromptTransport.Trim().ToLowerInvariant()
        if ($normalizedTransport -notin @('argv', 'file', 'stdin')) {
            throw "Invalid provider registry prompt_transport '$PromptTransport'."
        }
        $entry.prompt_transport = $normalizedTransport
    }
    if (-not ($entry.Contains('agent') -or $entry.Contains('model') -or $entry.Contains('prompt_transport'))) {
        throw 'Provider registry entry requires agent, model, or prompt_transport.'
    }

    $entry.updated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $entry.reason = $Reason.Trim()
    }

    $registry = Read-BridgeProviderRegistry -RootPath $RootPath
    $registry.slots[$SlotId] = $entry

    $path = Get-BridgeProviderRegistryPath -RootPath $RootPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $registry | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $path -Encoding UTF8
    return $registry.slots[$SlotId]
}

function Remove-BridgeProviderRegistryEntry {
    param(
        [Parameter(Mandatory = $true)][string]$SlotId,
        [string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($SlotId)) {
        throw 'Provider registry entry requires a slot id.'
    }

    $registry = Read-BridgeProviderRegistry -RootPath $RootPath
    $matchedSlotId = $null
    foreach ($entry in $registry.slots.GetEnumerator()) {
        if ([string]::Equals([string]$entry.Key, $SlotId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matchedSlotId = [string]$entry.Key
            break
        }
    }

    if ($null -ne $matchedSlotId) {
        $registry.slots.Remove($matchedSlotId)
    }

    $path = Get-BridgeProviderRegistryPath -RootPath $RootPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $registry | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $path -Encoding UTF8

    return [PSCustomObject][ordered]@{
        SlotId        = [string]$SlotId
        Removed       = ($null -ne $matchedSlotId)
        RegistryPath  = [string]$path
        UpdatedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-BridgeProviderCapabilityRegistryPath {
    param([string]$RootPath)

    if ([string]::IsNullOrWhiteSpace($RootPath)) {
        $RootPath = (Get-Location).Path
    }

    return Join-Path (Join-Path $RootPath '.winsmux') $script:BridgeProviderCapabilityRegistryFileName
}

function ConvertTo-BridgeProviderCapabilityEntry {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $pairs = @()
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = $Value.GetEnumerator()
    } elseif ($Value -is [PSCustomObject]) {
        $pairs = $Value.PSObject.Properties | ForEach-Object {
            [PSCustomObject]@{
                Key   = $_.Name
                Value = $_.Value
            }
        }
    } else {
        return $null
    }

    $stringFields = @('adapter', 'display_name', 'command')
    $transportFields = @('prompt_transports')
    $boolFields = @(
        'supports_parallel_runs',
        'supports_interrupt',
        'supports_structured_result',
        'supports_file_edit',
        'supports_subagents',
        'supports_verification',
        'supports_consultation'
    )
    $allowedFields = @($stringFields + $transportFields + $boolFields)

    $entry = [ordered]@{}
    foreach ($pair in $pairs) {
        $key = $pair.Key.ToString()
        if ($key -notin $allowedFields) {
            throw "Invalid provider capability field '$key'."
        }

        if ($key -in $stringFields) {
            if ($pair.Value -isnot [string]) {
                throw "Invalid provider capability field '$key'."
            }

            $text = ConvertFrom-BridgeYamlScalar $pair.Value
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $entry[$key] = $text
            }
            continue
        }

        if ($key -in $transportFields) {
            if ($pair.Value -isnot [System.Collections.IEnumerable] -or $pair.Value -is [string]) {
                throw "Invalid provider capability field '$key'."
            }

            $transports = @()
            foreach ($transport in @($pair.Value)) {
                $text = ConvertFrom-BridgeYamlScalar $transport
                if ([string]::IsNullOrWhiteSpace($text)) {
                    throw "Invalid provider capability field '$key'."
                }

                $text = $text.ToLowerInvariant()
                if ($text -notin @('argv', 'file', 'stdin')) {
                    throw "Invalid provider capability prompt transport '$text'."
                }

                $transports += $text
            }
            if ($transports.Count -lt 1) {
                throw "Invalid provider capability field '$key'."
            }

            $entry[$key] = @($transports)
            continue
        }

        if ($key -in $boolFields) {
            if ($pair.Value -isnot [bool]) {
                throw "Invalid provider capability field '$key'."
            }

            $entry[$key] = [bool]$pair.Value
        }
    }

    if ($entry.Count -lt 1) {
        return $null
    }

    foreach ($requiredField in @('adapter', 'command', 'prompt_transports')) {
        if (-not $entry.Contains($requiredField)) {
            throw "Missing provider capability field '$requiredField'."
        }
    }

    return $entry
}

function ConvertTo-BridgePowerShellLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-BridgePowerShellCommandInvocation {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value -match '^[a-zA-Z0-9_.:/\\-]+$') {
        return $Value
    }

    return '& ' + (ConvertTo-BridgePowerShellLiteral -Value $Value)
}

function Read-BridgeProviderCapabilityRegistry {
    param([string]$RootPath)

    $path = Get-BridgeProviderCapabilityRegistryPath -RootPath $RootPath
    $registry = [ordered]@{
        version   = 1
        providers = [ordered]@{}
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $registry
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $registry
    }

    try {
        $parsed = $raw | ConvertFrom-Json -Depth 16 -ErrorAction Stop
    } catch {
        throw "Invalid provider capability registry JSON at '$path'."
    }

    if (-not (Test-BridgeProviderRegistryObject $parsed)) {
        throw "Invalid provider capability registry JSON at '$path'."
    }

    $version = 1
    if ($null -ne $parsed.PSObject -and $parsed.PSObject.Properties.Name -contains 'version') {
        if ($parsed.version -isnot [int] -and $parsed.version -isnot [long]) {
            throw "Invalid provider capability registry version at '$path'."
        }

        $version = [int]$parsed.version
    }
    if ($version -ne 1) {
        throw "Unsupported provider capability registry version '$version'. Supported versions: 1."
    }

    $registry.version = $version
    if ($null -eq $parsed.PSObject -or -not ($parsed.PSObject.Properties.Name -contains 'providers') -or $null -eq $parsed.providers) {
        return $registry
    }

    if (-not (Test-BridgeProviderRegistryObject $parsed.providers)) {
        throw "Invalid provider capability registry providers at '$path'."
    }

    foreach ($providerProperty in (Get-BridgeProviderRegistryObjectProperties $parsed.providers)) {
        $providerId = ConvertFrom-BridgeYamlScalar $providerProperty.Name
        if ([string]::IsNullOrWhiteSpace($providerId)) {
            throw "Invalid provider capability id at '$path'."
        }

        if (-not (Test-BridgeProviderRegistryObject $providerProperty.Value)) {
            throw "Invalid provider capability entry '$providerId' at '$path'."
        }

        $entry = ConvertTo-BridgeProviderCapabilityEntry $providerProperty.Value
        if ($null -eq $entry) {
            throw "Invalid provider capability entry '$providerId' at '$path'."
        }

        $registry.providers[$providerId] = $entry
    }

    return $registry
}

function Get-BridgeProviderCapability {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($ProviderId)) {
        return $null
    }

    $registry = Read-BridgeProviderCapabilityRegistry -RootPath $RootPath
    foreach ($entry in $registry.providers.GetEnumerator()) {
        if ([string]::Equals([string]$entry.Key, $ProviderId, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $entry.Value
        }
    }

    return $null
}

function Resolve-BridgeProviderCapability {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [string]$RootPath,
        [switch]$RequireWhenRegistryPresent
    )

    if ([string]::IsNullOrWhiteSpace($ProviderId)) {
        return $null
    }

    $registry = Read-BridgeProviderCapabilityRegistry -RootPath $RootPath
    if ($registry.providers.Count -lt 1) {
        return $null
    }

    foreach ($entry in $registry.providers.GetEnumerator()) {
        if ([string]::Equals([string]$entry.Key, $ProviderId, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $entry.Value
        }
    }

    if ($RequireWhenRegistryPresent) {
        throw "Provider capability '$ProviderId' was not found."
    }

    return $null
}

function Get-BridgeProviderCapabilityValue {
    param(
        [AllowNull()]$Capability,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $Capability) {
        return $Default
    }

    if ($Capability -is [System.Collections.IDictionary]) {
        if ($Capability.Contains($Name)) {
            return $Capability[$Name]
        }

        return $Default
    }

    if ($null -ne $Capability.PSObject -and $Capability.PSObject.Properties.Name -contains $Name) {
        return $Capability.PSObject.Properties[$Name].Value
    }

    return $Default
}

function Get-BridgeProviderCapabilityBoolean {
    param(
        [AllowNull()]$Capability,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return [bool](Get-BridgeProviderCapabilityValue -Capability $Capability -Name $Name -Default $false)
}

function Test-BridgeProviderCapabilityField {
    param(
        [AllowNull()]$Capability,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Capability) {
        return $false
    }

    if ($Capability -is [System.Collections.IDictionary]) {
        return $Capability.Contains($Name)
    }

    return ($null -ne $Capability.PSObject -and $Capability.PSObject.Properties.Name -contains $Name)
}

function Assert-BridgeProviderCapabilityTransport {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [Parameter(Mandatory = $true)][string]$PromptTransport,
        [string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($ProviderId) -or [string]::IsNullOrWhiteSpace($PromptTransport)) {
        return
    }

    $capability = Resolve-BridgeProviderCapability -ProviderId $ProviderId -RootPath $RootPath -RequireWhenRegistryPresent
    if ($null -eq $capability) {
        return
    }

    $transports = @()
    if ($capability.Contains('prompt_transports')) {
        $transports = @($capability.prompt_transports)
    }

    if ($transports.Count -lt 1) {
        throw "Provider capability '$ProviderId' does not declare prompt_transports."
    }

    $requestedTransport = $PromptTransport.Trim().ToLowerInvariant()
    $supportedTransports = @($transports | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    if ($requestedTransport -notin $supportedTransports) {
        throw "Provider capability '$ProviderId' does not support prompt_transport '$requestedTransport'. Supported values: $($supportedTransports -join ', ')."
    }
}

function Get-BridgeProviderLaunchCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [string]$RootPath,
        [bool]$ExecMode = $false
    )

    $provider = $ProviderId.Trim()
    if ([string]::IsNullOrWhiteSpace($provider)) {
        throw 'Provider id must not be empty.'
    }

    $capability = Resolve-BridgeProviderCapability -ProviderId $provider -RootPath $RootPath -RequireWhenRegistryPresent
    $adapter = $provider
    $command = $provider
    if ($null -ne $capability) {
        $adapter = [string]$capability.adapter
        $command = [string]$capability.command
    }

    $adapterKey = $adapter.Trim().ToLowerInvariant()
    $commandInvocation = ConvertTo-BridgePowerShellCommandInvocation -Value $command
    switch ($adapterKey) {
        'codex' {
            if ($ExecMode) {
                return ''
            }

            $projectLiteral = ConvertTo-BridgePowerShellLiteral -Value $ProjectDir
            $worktreeLiteral = ConvertTo-BridgePowerShellLiteral -Value $GitWorktreeDir
            return "$commandInvocation -c model=$Model --sandbox danger-full-access -C $projectLiteral --add-dir $worktreeLiteral"
        }
        'claude' {
            $parts = @($commandInvocation)
            if (-not [string]::IsNullOrWhiteSpace($Model)) {
                $parts += '--model'
                $parts += (ConvertTo-BridgePowerShellLiteral -Value $Model)
            }
            $parts += '--permission-mode'
            $parts += 'bypassPermissions'
            return ($parts -join ' ')
        }
        default {
            throw "Unsupported provider adapter '$adapter' for provider '$provider'."
        }
    }
}

function ConvertFrom-BridgeManualYaml {
    param([Parameter(Mandatory = $true)][string]$Content)

    $settings = [ordered]@{}
    $currentListKey = $null
    $currentSlotListKey = $null
    $currentSlotEntry = $null
    $currentMapKey = $null
    $currentMapEntryKey = $null
    $lineNumber = 0

    foreach ($rawLine in ($Content -split "\r?\n")) {
        $lineNumber++
        $line = Remove-BridgeYamlComment $rawLine
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($null -ne $currentSlotListKey -and $line -match '^\s*-\s*([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*?)\s*$') {
            $slotEntry = [ordered]@{}
            $slotKey = $Matches[1] -replace '-', '_'
            $slotEntry[$slotKey] = ConvertFrom-BridgeYamlScalar $Matches[2]
            $settings[$currentSlotListKey] += @($slotEntry)
            $currentSlotEntry = $slotEntry
            continue
        }

        if ($null -ne $currentSlotListKey -and $null -ne $currentSlotEntry -and $line -match '^\s{4}([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*?)\s*$') {
            $slotKey = $Matches[1] -replace '-', '_'
            $currentSlotEntry[$slotKey] = ConvertFrom-BridgeYamlScalar $Matches[2]
            continue
        }

        if ($line -match '^\s*-\s*(.+?)\s*$') {
            if ($null -eq $currentListKey) {
                continue
            }

            $settings[$currentListKey] += @(ConvertFrom-BridgeYamlScalar $Matches[1])
            continue
        }

        $currentListKey = $null
        $currentSlotListKey = $null
        $currentSlotEntry = $null
        if ($null -ne $currentMapKey -and $line -match '^\s{2}([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*$') {
            $currentMapEntryKey = $Matches[1] -replace '-', '_'
            if (-not $settings[$currentMapKey].Contains($currentMapEntryKey)) {
                $settings[$currentMapKey][$currentMapEntryKey] = [ordered]@{}
            }
            continue
        }

        if ($null -ne $currentMapKey -and $null -ne $currentMapEntryKey -and $line -match '^\s{4}([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*?)\s*$') {
            $nestedKey = $Matches[1] -replace '-', '_'
            $nestedValue = ConvertFrom-BridgeYamlScalar $Matches[2]
            $settings[$currentMapKey][$currentMapEntryKey][$nestedKey] = $nestedValue
            continue
        }

        $currentMapKey = $null
        $currentMapEntryKey = $null
        if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*?)\s*$') {
            continue
        }

        $key = $Matches[1] -replace '-', '_'
        $value = $Matches[2]
        Assert-BridgeNoRetiredOperatorSetting -Name $key -Source $script:BridgeSettingsFileName

        if (-not $script:BridgeSettingsSchema.Contains($key)) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($value)) {
            switch ($script:BridgeSettingsSchema[$key].Type) {
                'map' {
                    $settings[$key] = [ordered]@{}
                    $currentMapKey = $key
                }
                'slotlist' {
                    $settings[$key] = @()
                    $currentSlotListKey = $key
                }
                default {
                    $settings[$key] = @()
                    $currentListKey = $key
                }
            }
            continue
        }

        $inlineList = ConvertFrom-BridgeInlineList $value
        if ($null -ne $inlineList) {
            $settings[$key] = @($inlineList)
            continue
        }

        $settings[$key] = ConvertFrom-BridgeYamlScalar $value
    }

    return $settings
}

function Read-BridgeProjectSettings {
    param([string]$RootPath)

    $path = Get-BridgeProjectSettingsPath -RootPath $RootPath
    if (-not (Test-Path $path)) {
        return @{}
    }

    $raw = Get-Content -Raw -Path $path -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    $yamlCommand = Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue
    if ($yamlCommand) {
        try {
            $parsed = $raw | ConvertFrom-Yaml -ErrorAction Stop
            if ($parsed -is [System.Collections.IDictionary]) {
                $settings = [ordered]@{}
                foreach ($entry in $parsed.GetEnumerator()) {
                    $settings[$entry.Key] = $entry.Value
                }

                return $settings
            }

            if ($null -ne $parsed) {
                $settings = [ordered]@{}
                foreach ($property in $parsed.PSObject.Properties) {
                    $settings[$property.Name] = $property.Value
                }

                return $settings
            }
        } catch {
        }
    }

    return ConvertFrom-BridgeManualYaml -Content $raw
}

function Test-BridgeSettingValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Value,
        [ref]$NormalizedValue
    )

    $schema = $script:BridgeSettingsSchema[$Name]
    if ($null -eq $schema) {
        return $false
    }

    switch ($schema.Type) {
        'string' {
            $text = ConvertFrom-BridgeYamlScalar $Value
            if ([string]::IsNullOrWhiteSpace($text)) {
                return $false
            }

            $NormalizedValue.Value = $text
            return $true
        }
        'int' {
            $text = ConvertFrom-BridgeYamlScalar $Value
            $parsed = 0
            if (-not [int]::TryParse($text, [ref]$parsed)) {
                return $false
            }

            $NormalizedValue.Value = $parsed
            return $true
        }
        'bool' {
            $text = ConvertFrom-BridgeYamlScalar $Value
            if ([string]::IsNullOrWhiteSpace($text)) {
                return $false
            }

            switch -Regex ($text.Trim()) {
                '^(?i:true|1|yes|on)$' {
                    $NormalizedValue.Value = $true
                    return $true
                }
                '^(?i:false|0|no|off)$' {
                    $NormalizedValue.Value = $false
                    return $true
                }
                default {
                    return $false
                }
            }
        }
        'transport' {
            $text = ConvertFrom-BridgeYamlScalar $Value
            if ([string]::IsNullOrWhiteSpace($text)) {
                return $false
            }

            switch ($text.Trim().ToLowerInvariant()) {
                'argv' {
                    $NormalizedValue.Value = 'argv'
                    return $true
                }
                'file' {
                    $NormalizedValue.Value = 'file'
                    return $true
                }
                'stdin' {
                    $NormalizedValue.Value = 'stdin'
                    return $true
                }
                default {
                    return $false
                }
            }
        }
        'string[]' {
            $items = @()

            if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
                foreach ($item in $Value) {
                    $text = ConvertFrom-BridgeYamlScalar $item
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        $items += $text
                    }
                }
            } else {
                $text = ConvertFrom-BridgeYamlScalar $Value
                if ([string]::IsNullOrWhiteSpace($text)) {
                    $items = @()
                } else {
                    $items = @(
                        $text -split '[,;]' |
                        ForEach-Object { ConvertFrom-BridgeYamlScalar $_ } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    )
                }
            }

            $NormalizedValue.Value = @($items)
            return $true
        }
        'map' {
            $map = [ordered]@{}
            $entries = @()

            if ($Value -is [System.Collections.IDictionary]) {
                $entries = $Value.GetEnumerator()
            } elseif ($null -ne $Value -and $null -ne $Value.PSObject) {
                $entries = $Value.PSObject.Properties | ForEach-Object {
                    [PSCustomObject]@{
                        Key = $_.Name
                        Value = $_.Value
                    }
                }
            } else {
                return $false
            }

            foreach ($entry in $entries) {
                $roleKey = ConvertFrom-BridgeYamlScalar $entry.Key
                if ([string]::IsNullOrWhiteSpace($roleKey)) {
                    continue
                }

                $roleConfig = [ordered]@{}
                $rolePairs = @()

                if ($entry.Value -is [System.Collections.IDictionary]) {
                    $rolePairs = $entry.Value.GetEnumerator()
                } elseif ($null -ne $entry.Value -and $null -ne $entry.Value.PSObject) {
                    $rolePairs = $entry.Value.PSObject.Properties | ForEach-Object {
                        [PSCustomObject]@{
                            Key = $_.Name
                            Value = $_.Value
                        }
                    }
                }

                foreach ($rolePair in $rolePairs) {
                    $propertyKey = $rolePair.Key.ToString() -replace '-', '_'
                    if ($propertyKey -notin @('agent', 'model', 'prompt_transport')) {
                        continue
                    }

                    $text = ConvertFrom-BridgeYamlScalar $rolePair.Value
                    if ([string]::IsNullOrWhiteSpace($text)) {
                        continue
                    }

                    $roleConfig[$propertyKey] = $text
                }

                $map[$roleKey] = $roleConfig
            }

            $NormalizedValue.Value = $map
            return $true
        }
        'slotlist' {
            $slots = @()

            if ($Value -isnot [System.Collections.IEnumerable] -or $Value -is [string]) {
                return $false
            }

            foreach ($slotValue in $Value) {
                $slot = ConvertTo-BridgeSlotEntry $slotValue
                if ($null -ne $slot) {
                    $slots += $slot
                }
            }

            $NormalizedValue.Value = @($slots)
            return $true
        }
        default {
            return $false
        }
    }
}

function ConvertTo-BridgeSettingsSource {
    param([AllowNull()]$Settings)

    $normalized = [ordered]@{}
    if ($null -eq $Settings) {
        return $normalized
    }

    $pairs = @()
    if ($Settings -is [System.Collections.IDictionary]) {
        $pairs = $Settings.GetEnumerator()
    } else {
        $pairs = $Settings.PSObject.Properties | ForEach-Object {
            [PSCustomObject]@{ Key = $_.Name; Value = $_.Value }
        }
    }

    foreach ($pair in $pairs) {
        $key = $pair.Key.ToString() -replace '-', '_'
        Assert-BridgeNoRetiredOperatorSetting -Name $key -Source 'settings source'

        if (-not $script:BridgeSettingsSchema.Contains($key)) {
            continue
        }

        $normalizedValue = $null
        if (Test-BridgeSettingValue -Name $key -Value $pair.Value -NormalizedValue ([ref]$normalizedValue)) {
            if ($normalizedValue -is [System.Array]) {
                $normalized[$key] = @($normalizedValue)
            } else {
                $normalized[$key] = $normalizedValue
            }
        }
    }

    return $normalized
}

function Read-BridgeGlobalSettings {
    $settings = [ordered]@{}

    foreach ($key in $script:BridgeSettingsSchema.Keys) {
        $optionName = $script:BridgeSettingsSchema[$key].Option
        if ([string]::IsNullOrWhiteSpace($optionName)) {
            continue
        }

        $rawValue = Get-WinsmuxOption -Name $optionName -Default $null
        if ($null -eq $rawValue -or [string]::IsNullOrWhiteSpace($rawValue)) {
            continue
        }

        if (Test-WinsmuxOptionFailureText -Value ([string]$rawValue)) {
            continue
        }

        $normalizedValue = $null
        if (Test-BridgeSettingValue -Name $key -Value $rawValue -NormalizedValue ([ref]$normalizedValue)) {
            if ($normalizedValue -is [System.Array]) {
                $settings[$key] = @($normalizedValue)
            } else {
                $settings[$key] = $normalizedValue
            }
        } elseif ($key -eq 'prompt_transport') {
            throw "Invalid prompt_transport configuration: unsupported value '$rawValue'."
        }
    }

    return $settings
}

function Get-BridgeSettings {
    param([string]$RootPath)

    $defaults = Get-BridgeSettingsDefaults
    $settings = [ordered]@{}

    foreach ($key in $script:BridgeSettingsSchema.Keys) {
        $defaultValue = $defaults[$key]
        if ($defaultValue -is [System.Array]) {
            $settings[$key] = @($defaultValue)
        } else {
            $settings[$key] = $defaultValue
        }
    }

    $globalSettings = Read-BridgeGlobalSettings
    Assert-BridgeNoRetiredOperatorGlobalSettings

    foreach ($key in $globalSettings.Keys) {
        $value = $globalSettings[$key]
        if ($value -is [System.Array]) {
            $settings[$key] = @($value)
        } else {
            $settings[$key] = $value
        }
    }

    $rawProjectSettings = Read-BridgeProjectSettings -RootPath $RootPath
    $projectSettings = ConvertTo-BridgeSettingsSource $rawProjectSettings

    if ($rawProjectSettings -is [System.Collections.IDictionary] -and $rawProjectSettings.Contains('prompt_transport') -and -not $projectSettings.Contains('prompt_transport')) {
        throw "Invalid prompt_transport configuration: unsupported value '$($rawProjectSettings['prompt_transport'])'."
    }

    if ($rawProjectSettings -is [System.Collections.IDictionary] -and $rawProjectSettings.Contains('agent_slots')) {
        $rawSlotEntries = @()
        $rawSlotValue = $rawProjectSettings['agent_slots']
        if ($rawSlotValue -is [System.Collections.IEnumerable] -and $rawSlotValue -isnot [string]) {
            $rawSlotEntries = @($rawSlotValue)
        }

        if (-not $projectSettings.Contains('agent_slots')) {
            throw 'Invalid agent_slots configuration: every slot entry must include at least slot_id.'
        }

        $normalizedSlotEntries = @($projectSettings['agent_slots'])
        if ($rawSlotEntries.Count -gt 0 -and $normalizedSlotEntries.Count -ne $rawSlotEntries.Count) {
            throw 'Invalid agent_slots configuration: every slot entry must include at least slot_id.'
        }
    }

    foreach ($key in $projectSettings.Keys) {
        $value = $projectSettings[$key]
        if ($value -is [System.Array]) {
            $settings[$key] = @($value)
        } else {
            $settings[$key] = $value
        }
    }

    if ($settings.agent_slots -isnot [System.Array]) {
        $settings.agent_slots = @()
    }

    $configVersion = [int]$settings.config_version
    if ($configVersion -ne 1) {
        throw "Unsupported config_version '$configVersion'. Supported versions: 1."
    }

    $slotIds = @{}
    foreach ($slot in @($settings.agent_slots)) {
        if ([string]::IsNullOrWhiteSpace([string]$slot.slot_id)) {
            throw 'Invalid agent_slots configuration: slot_id must not be empty.'
        }

        $slotId = [string]$slot.slot_id
        if ($slotIds.ContainsKey($slotId)) {
            throw "Invalid agent_slots configuration: duplicate slot_id '$slotId'."
        }

        $slotIds[$slotId] = $true
    }

    $legacyCount = [int]$settings.operators + [int]$settings.builders + [int]$settings.researchers + [int]$settings.reviewers
    $useLegacyLayout = [bool]$settings.legacy_role_layout

    if ($legacyCount -gt 0 -and -not $useLegacyLayout) {
        throw 'Legacy role counts require legacy_role_layout=true. Set legacy_role_layout explicitly to opt into Operator/Builder/Researcher/Reviewer panes.'
    }

    if (@($settings.agent_slots).Count -eq 0 -and -not $useLegacyLayout -and [bool]$settings.external_operator -and [int]$settings.worker_count -gt 0) {
        $settings.agent_slots = New-BridgeManagedAgentSlots -Count ([int]$settings.worker_count) -Agent ([string]$settings.agent) -Model ([string]$settings.model)
    }

    if (@($settings.agent_slots).Count -gt 0 -and -not $useLegacyLayout) {
        $settings.worker_count = @($settings.agent_slots).Count
    }

    return $settings
}

function Get-BridgeSettingsMetadata {
    param(
        [string]$RootPath,
        $Settings = $null
    )

    if ($null -eq $Settings) {
        $Settings = Get-BridgeSettings -RootPath $RootPath
    }

    $configVersion = [int]$Settings.config_version
    $migrationStatus = if ($configVersion -eq 1) { 'current' } else { 'unsupported' }

    return [PSCustomObject]@{
        ConfigVersion   = $configVersion
        MigrationStatus = $migrationStatus
        LegacyRoleLayout = [bool]$Settings.legacy_role_layout
        SlotCount       = @($Settings.agent_slots).Count
    }
}

function Get-RoleAgentConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        $Settings = (Get-BridgeSettings)
    )

    if ($null -eq $Settings) {
        throw 'Settings cannot be null.'
    }

    $resolvedRoleConfig = $null
    $roles = $Settings.roles
    if ($roles -is [System.Collections.IDictionary]) {
        foreach ($entry in $roles.GetEnumerator()) {
            if ([string]::Equals([string]$entry.Key, $Role, [System.StringComparison]::OrdinalIgnoreCase)) {
                $resolvedRoleConfig = $entry.Value
                break
            }
        }
    }

    $agent = $Settings.agent
    $model = $Settings.model
    $promptTransport = 'argv'
    if ($Settings -is [System.Collections.IDictionary]) {
        if ($Settings.Contains('prompt_transport') -and -not [string]::IsNullOrWhiteSpace([string]$Settings['prompt_transport'])) {
            $promptTransport = [string]$Settings['prompt_transport']
        }
    } elseif ($null -ne $Settings.PSObject -and $Settings.PSObject.Properties.Name -contains 'prompt_transport' -and -not [string]::IsNullOrWhiteSpace([string]$Settings.prompt_transport)) {
        $promptTransport = [string]$Settings.prompt_transport
    }

    if ($resolvedRoleConfig -is [System.Collections.IDictionary]) {
        if ($resolvedRoleConfig.Contains('agent') -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRoleConfig['agent'])) {
            $agent = [string]$resolvedRoleConfig['agent']
        }

        if ($resolvedRoleConfig.Contains('model') -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRoleConfig['model'])) {
            $model = [string]$resolvedRoleConfig['model']
        }

        if ($resolvedRoleConfig.Contains('prompt_transport') -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRoleConfig['prompt_transport'])) {
            $promptTransport = [string]$resolvedRoleConfig['prompt_transport']
        }
    } elseif ($null -ne $resolvedRoleConfig -and $null -ne $resolvedRoleConfig.PSObject) {
        if ($resolvedRoleConfig.PSObject.Properties.Name -contains 'agent' -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRoleConfig.agent)) {
            $agent = [string]$resolvedRoleConfig.agent
        }

        if ($resolvedRoleConfig.PSObject.Properties.Name -contains 'model' -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRoleConfig.model)) {
            $model = [string]$resolvedRoleConfig.model
        }

        if ($resolvedRoleConfig.PSObject.Properties.Name -contains 'prompt_transport' -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRoleConfig.prompt_transport)) {
            $promptTransport = [string]$resolvedRoleConfig.prompt_transport
        }
    }

    return [PSCustomObject]@{
        Agent           = [string]$agent
        Model           = [string]$model
        PromptTransport = [string]$promptTransport
    }
}

function Get-SlotAgentConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        [string]$SlotId,
        $Settings = (Get-BridgeSettings),
        [string]$RootPath
    )

    if ($null -eq $Settings) {
        throw 'Settings cannot be null.'
    }

    $roleAgentConfig = Get-RoleAgentConfig -Role $Role -Settings $Settings
    $agent = [string]$roleAgentConfig.Agent
    $model = [string]$roleAgentConfig.Model
    $promptTransport = [string]$roleAgentConfig.PromptTransport
    $source = 'role'

    if (-not [string]::IsNullOrWhiteSpace($SlotId)) {
        $configuredSlots = @()
        if ($Settings -is [System.Collections.IDictionary]) {
            if ($Settings.Contains('agent_slots')) {
                $configuredSlots = @($Settings['agent_slots'])
            }
        } elseif ($null -ne $Settings.PSObject -and ($Settings.PSObject.Properties.Name -contains 'agent_slots')) {
            $configuredSlots = @($Settings.agent_slots)
        }

        foreach ($slot in $configuredSlots) {
            if ($null -eq $slot) {
                continue
            }

            $candidateSlotId = ''
            $slotAgent = ''
            $slotModel = ''
            $slotPromptTransport = ''

            if ($slot -is [System.Collections.IDictionary]) {
                if ($slot.Contains('slot_id')) {
                    $candidateSlotId = [string]$slot['slot_id']
                }
                if ($slot.Contains('agent')) {
                    $slotAgent = [string]$slot['agent']
                }
                if ($slot.Contains('model')) {
                    $slotModel = [string]$slot['model']
                }
                if ($slot.Contains('prompt_transport')) {
                    $slotPromptTransport = [string]$slot['prompt_transport']
                }
            } elseif ($null -ne $slot.PSObject) {
                if ($slot.PSObject.Properties.Name -contains 'slot_id') {
                    $candidateSlotId = [string]$slot.slot_id
                }
                if ($slot.PSObject.Properties.Name -contains 'agent') {
                    $slotAgent = [string]$slot.agent
                }
                if ($slot.PSObject.Properties.Name -contains 'model') {
                    $slotModel = [string]$slot.model
                }
                if ($slot.PSObject.Properties.Name -contains 'prompt_transport') {
                    $slotPromptTransport = [string]$slot.prompt_transport
                }
            }

            if (-not [string]::Equals($candidateSlotId, $SlotId, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($slotAgent)) {
                $agent = $slotAgent
                $source = 'slot'
            }

            if (-not [string]::IsNullOrWhiteSpace($slotModel)) {
                $model = $slotModel
                $source = 'slot'
            }

            if (-not [string]::IsNullOrWhiteSpace($slotPromptTransport)) {
                $promptTransport = $slotPromptTransport
                $source = 'slot'
            }

            break
        }
    }

    $registryEntry = Get-BridgeProviderRegistryEntry -SlotId $SlotId -RootPath $RootPath
    if ($null -ne $registryEntry) {
        if ($registryEntry.Contains('agent')) {
            $agent = [string]$registryEntry.agent
        }

        if ($registryEntry.Contains('model')) {
            $model = [string]$registryEntry.model
        }

        if ($registryEntry.Contains('prompt_transport')) {
            $promptTransport = [string]$registryEntry.prompt_transport
        }

        $source = 'registry'
    }

    $providerCapability = $null
    if (-not [string]::IsNullOrWhiteSpace($RootPath)) {
        Assert-BridgeProviderCapabilityTransport -ProviderId $agent -PromptTransport $promptTransport -RootPath $RootPath
        $providerCapability = Resolve-BridgeProviderCapability -ProviderId $agent -RootPath $RootPath -RequireWhenRegistryPresent
    }

    return [PSCustomObject]@{
        SlotId                   = [string]$SlotId
        Agent                    = [string]$agent
        Model                    = [string]$model
        PromptTransport          = [string]$promptTransport
        Source                   = [string]$source
        CapabilityAdapter        = [string](Get-BridgeProviderCapabilityValue -Capability $providerCapability -Name 'adapter' -Default '')
        CapabilityCommand        = [string](Get-BridgeProviderCapabilityValue -Capability $providerCapability -Name 'command' -Default '')
        SupportsParallelRuns     = Get-BridgeProviderCapabilityBoolean -Capability $providerCapability -Name 'supports_parallel_runs'
        SupportsInterrupt        = Get-BridgeProviderCapabilityBoolean -Capability $providerCapability -Name 'supports_interrupt'
        SupportsInterruptDeclared = Test-BridgeProviderCapabilityField -Capability $providerCapability -Name 'supports_interrupt'
        SupportsStructuredResult = Get-BridgeProviderCapabilityBoolean -Capability $providerCapability -Name 'supports_structured_result'
        SupportsFileEdit         = Get-BridgeProviderCapabilityBoolean -Capability $providerCapability -Name 'supports_file_edit'
        SupportsSubagents        = Get-BridgeProviderCapabilityBoolean -Capability $providerCapability -Name 'supports_subagents'
        SupportsVerification     = Get-BridgeProviderCapabilityBoolean -Capability $providerCapability -Name 'supports_verification'
        SupportsConsultation     = Get-BridgeProviderCapabilityBoolean -Capability $providerCapability -Name 'supports_consultation'
    }
}

function Get-BridgeSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$RootPath
    )

    $key = $Name -replace '-', '_'
    if (-not $script:BridgeSettingsSchema.Contains($key)) {
        throw "Unknown bridge setting: $Name"
    }

    return (Get-BridgeSettings -RootPath $RootPath)[$key]
}

function ConvertTo-BridgeYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return "''"
    }

    $text = $Value.ToString()
    if ($text -match '^[A-Za-z0-9._/-]+$') {
        return $text
    }

    return "'" + ($text -replace "'", "''") + "'"
}

function Save-BridgeSettings {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('project', 'global')][string]$Scope,
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [string]$RootPath
    )

    $normalized = ConvertTo-BridgeSettingsSource $Settings

    if ($Scope -eq 'project') {
        $path = Get-BridgeProjectSettingsPath -RootPath $RootPath
        $lines = [System.Collections.Generic.List[string]]::new()
        $hasAgentSlots = @($normalized.agent_slots).Count -gt 0

        foreach ($key in $script:BridgeSettingsSchema.Keys) {
            if (-not $normalized.Contains($key)) {
                continue
            }

            if ($key -eq 'worker_count' -and $hasAgentSlots) {
                continue
            }

            $value = $normalized[$key]
            if ($value -is [System.Array]) {
                $lines.Add("${key}:")
                if ($script:BridgeSettingsSchema[$key].Type -eq 'slotlist') {
                    foreach ($item in $value) {
                        $slot = ConvertTo-BridgeSlotEntry $item
                        if ($null -eq $slot) {
                            continue
                        }

                        $firstProperty = $true
                        foreach ($slotEntry in $slot.GetEnumerator()) {
                            if ($firstProperty) {
                                $lines.Add("  - $($slotEntry.Key): $(ConvertTo-BridgeYamlScalar $slotEntry.Value)")
                                $firstProperty = $false
                                continue
                            }

                            $lines.Add("    $($slotEntry.Key): $(ConvertTo-BridgeYamlScalar $slotEntry.Value)")
                        }
                    }
                } else {
                    foreach ($item in $value) {
                        $lines.Add("  - $(ConvertTo-BridgeYamlScalar $item)")
                    }
                }
            } elseif ($value -is [System.Collections.IDictionary]) {
                $lines.Add("${key}:")
                foreach ($entry in $value.GetEnumerator()) {
                    $lines.Add("  $($entry.Key):")
                    $roleConfig = $entry.Value
                    if ($roleConfig -is [System.Collections.IDictionary]) {
                        foreach ($roleEntry in $roleConfig.GetEnumerator()) {
                            $lines.Add("    $($roleEntry.Key): $(ConvertTo-BridgeYamlScalar $roleEntry.Value)")
                        }
                    } elseif ($null -ne $roleConfig -and $null -ne $roleConfig.PSObject) {
                        foreach ($property in $roleConfig.PSObject.Properties) {
                            $lines.Add("    $($property.Name): $(ConvertTo-BridgeYamlScalar $property.Value)")
                        }
                    }
                }
            } else {
                $lines.Add("${key}: $(ConvertTo-BridgeYamlScalar $value)")
            }
        }

        $content = if ($lines.Count -gt 0) { ($lines -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
        Set-Content -Path $path -Value $content -Encoding UTF8
        return
    }

    $winsmuxBin = Get-WinsmuxBin
    if (-not $winsmuxBin) {
        throw (Get-WinsmuxOperatorNotFoundMessage)
    }

    foreach ($key in $normalized.Keys) {
        $optionName = $script:BridgeSettingsSchema[$key].Option
        if ([string]::IsNullOrWhiteSpace($optionName)) {
            continue
        }

        $value = $normalized[$key]
        $serializedValue = if ($value -is [System.Array]) { $value -join ',' } else { $value.ToString() }
        Set-WinsmuxOption -WinsmuxBin $winsmuxBin -OptionName $optionName -OptionValue $serializedValue
    }
}
