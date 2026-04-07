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
$script:BridgeSettingsSchema = [ordered]@{
    agent       = @{ Type = 'string';   Default = 'codex';      Option = '@bridge-agent' }
    model       = @{ Type = 'string';   Default = 'gpt-5.4';    Option = '@bridge-model' }
    builders    = @{ Type = 'int';      Default = 4;            Option = '@bridge-builders' }
    researchers = @{ Type = 'int';      Default = 1;            Option = '@bridge-researchers' }
    reviewers   = @{ Type = 'int';      Default = 1;            Option = '@bridge-reviewers' }
    vault_keys  = @{ Type = 'string[]'; Default = @('GH_TOKEN'); Option = '@bridge-vault-keys' }
    terminal    = @{ Type = 'string';   Default = 'background'; Option = '@bridge-terminal' }
    roles       = @{ Type = 'map';      Default = [ordered]@{}; Option = $null }
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

if (-not (Get-Command Get-WinsmuxOption -ErrorAction SilentlyContinue)) {
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
            if ($value -and $value -notmatch 'unknown|error|invalid') {
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
    return Join-Path (Get-Location).Path $script:BridgeSettingsFileName
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

function ConvertFrom-BridgeManualYaml {
    param([Parameter(Mandatory = $true)][string]$Content)

    $settings = [ordered]@{}
    $currentListKey = $null
    $currentMapKey = $null
    $currentMapEntryKey = $null
    $lineNumber = 0

    foreach ($rawLine in ($Content -split "\r?\n")) {
        $lineNumber++
        $line = Remove-BridgeYamlComment $rawLine
        if ([string]::IsNullOrWhiteSpace($line)) {
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
        if (-not $script:BridgeSettingsSchema.Contains($key)) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($value)) {
            if ($script:BridgeSettingsSchema[$key].Type -eq 'map') {
                $settings[$key] = [ordered]@{}
                $currentMapKey = $key
            } else {
                $settings[$key] = @()
                $currentListKey = $key
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
    $path = Get-BridgeProjectSettingsPath
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
                    if ($propertyKey -notin @('agent', 'model')) {
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

        $normalizedValue = $null
        if (Test-BridgeSettingValue -Name $key -Value $rawValue -NormalizedValue ([ref]$normalizedValue)) {
            if ($normalizedValue -is [System.Array]) {
                $settings[$key] = @($normalizedValue)
            } else {
                $settings[$key] = $normalizedValue
            }
        }
    }

    return $settings
}

function Get-BridgeSettings {
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
    foreach ($key in $globalSettings.Keys) {
        $value = $globalSettings[$key]
        if ($value -is [System.Array]) {
            $settings[$key] = @($value)
        } else {
            $settings[$key] = $value
        }
    }

    $projectSettings = ConvertTo-BridgeSettingsSource (Read-BridgeProjectSettings)
    foreach ($key in $projectSettings.Keys) {
        $value = $projectSettings[$key]
        if ($value -is [System.Array]) {
            $settings[$key] = @($value)
        } else {
            $settings[$key] = $value
        }
    }

    return $settings
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

    if ($resolvedRoleConfig -is [System.Collections.IDictionary]) {
        if ($resolvedRoleConfig.Contains('agent') -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRoleConfig['agent'])) {
            $agent = [string]$resolvedRoleConfig['agent']
        }

        if ($resolvedRoleConfig.Contains('model') -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRoleConfig['model'])) {
            $model = [string]$resolvedRoleConfig['model']
        }
    } elseif ($null -ne $resolvedRoleConfig -and $null -ne $resolvedRoleConfig.PSObject) {
        if ($resolvedRoleConfig.PSObject.Properties.Name -contains 'agent' -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRoleConfig.agent)) {
            $agent = [string]$resolvedRoleConfig.agent
        }

        if ($resolvedRoleConfig.PSObject.Properties.Name -contains 'model' -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRoleConfig.model)) {
            $model = [string]$resolvedRoleConfig.model
        }
    }

    return [PSCustomObject]@{
        Agent = [string]$agent
        Model = [string]$model
    }
}

function Get-BridgeSetting {
    param([Parameter(Mandatory = $true)][string]$Name)

    $key = $Name -replace '-', '_'
    if (-not $script:BridgeSettingsSchema.Contains($key)) {
        throw "Unknown bridge setting: $Name"
    }

    return (Get-BridgeSettings)[$key]
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
        [Parameter(Mandatory = $true)][hashtable]$Settings
    )

    $normalized = ConvertTo-BridgeSettingsSource $Settings

    if ($Scope -eq 'project') {
        $path = Get-BridgeProjectSettingsPath
        $lines = [System.Collections.Generic.List[string]]::new()

        foreach ($key in $script:BridgeSettingsSchema.Keys) {
            if (-not $normalized.Contains($key)) {
                continue
            }

            $value = $normalized[$key]
            if ($value -is [System.Array]) {
                $lines.Add("${key}:")
                foreach ($item in $value) {
                    $lines.Add("  - $(ConvertTo-BridgeYamlScalar $item)")
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
        throw 'Could not find a winsmux binary. Tried: winsmux, pmux, tmux.'
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
