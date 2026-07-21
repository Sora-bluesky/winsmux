$ErrorActionPreference = 'Stop'

$script:WorkspaceRecipeIdPattern = '^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$'
$script:WorkspaceRecipeSyntheticCredentialPattern = 'sk-[a-z0-9_-]{20,}'
$script:WorkspaceRecipeCapabilities = @('file-edit', 'review')
$script:WorkspaceRecipeActionKinds = @('ensure-managed-worktree', 'ensure-slot-ready')

function Get-WorkspaceRecipeProperty {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ($key -is [string] -and
                [string]::Equals($key, $Name, [System.StringComparison]::Ordinal)) {
                return ,$InputObject[$key]
            }
        }
        return $null
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::Ordinal)) {
            return ,$property.Value
        }
    }
    return $null
}

function Get-WorkspaceRecipePropertyNames {
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return @($InputObject.Keys | ForEach-Object { [string]$_ })
    }
    return @($InputObject.PSObject.Properties.Name)
}

function Assert-WorkspaceRecipeObject {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][string[]]$AllowedFields,
        [string[]]$RequiredFields = @()
    )

    if ($null -eq $InputObject -or $InputObject -is [string] -or
        $InputObject -is [System.Collections.IEnumerable] -and
        $InputObject -isnot [System.Collections.IDictionary] -and
        $InputObject -isnot [pscustomobject]) {
        throw "$Context must be a mapping."
    }

    $names = @(Get-WorkspaceRecipePropertyNames -InputObject $InputObject)
    foreach ($name in $names) {
        if ($AllowedFields -cnotcontains $name) {
            throw "$Context contains an unknown field."
        }
    }
    foreach ($name in $RequiredFields) {
        if ($names -cnotcontains $name -or $null -eq (Get-WorkspaceRecipeProperty $InputObject $name)) {
            throw "$Context is missing required field '$name'."
        }
    }
}

function Assert-WorkspaceRecipeId {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Value -isnot [string] -or $Value -cnotmatch $script:WorkspaceRecipeIdPattern) {
        throw "$Context must be a stable lowercase ASCII identifier."
    }
    if ([Regex]::IsMatch($Value, $script:WorkspaceRecipeSyntheticCredentialPattern,
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw 'Workspace recipe output must not contain credential-like material.'
    }
    return [string]$Value
}

function ConvertTo-WorkspaceRecipeStringList {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Value) { return @() }
    if ($Value -is [string] -or $Value -isnot [System.Collections.IEnumerable]) {
        throw "$Context must be a sequence."
    }
    $result = @()
    foreach ($item in $Value) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) {
            throw "$Context must contain non-empty strings."
        }
        $result += [string]$item
    }
    return @($result)
}

function ConvertFrom-WorkspaceRecipeYamlScalar {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $value = $Text.Trim()
    if ($value.StartsWith('[')) {
        if (-not $value.EndsWith(']')) { throw "$Context contains an invalid inline sequence." }
        $body = $value.Substring(1, $value.Length - 2).Trim()
        if ($body.Length -eq 0) { return ,@() }
        $items = @()
        foreach ($part in ($body -split ',')) {
            if ([string]::IsNullOrWhiteSpace($part)) { throw "$Context contains an invalid inline sequence." }
            $items += ConvertFrom-WorkspaceRecipeYamlScalar -Text $part -Context $Context
        }
        return ,@($items)
    }
    if ($value.StartsWith('{') -or $value -match '^[&*!>|]') {
        throw "$Context uses unsupported YAML syntax."
    }
    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        try { return ($value | ConvertFrom-Json -ErrorAction Stop) } catch { throw "$Context contains an invalid quoted scalar." }
    }
    if ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
        return $value.Substring(1, $value.Length - 2).Replace("''", "'")
    }
    if ($value -ceq 'true') { return $true }
    if ($value -ceq 'false') { return $false }
    if ($value -ceq 'null' -or $value -eq '~') { return $null }
    $integer = 0L
    if ([long]::TryParse($value, [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$integer)) { return $integer }
    if ($value -match '[:#]' -or [string]::IsNullOrWhiteSpace($value)) {
        throw "$Context contains an invalid plain scalar."
    }
    return $value
}

function Add-WorkspaceRecipeYamlEntry {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Map,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if ($Map.Contains($Key)) { throw "$Context contains duplicate key '$Key'." }
    $Map[$Key] = $Value
}

function ConvertFrom-WorkspaceRecipeYamlBlock {
    param(
        [Parameter(Mandatory = $true)][object[]]$Lines,
        [Parameter(Mandatory = $true)][ref]$Index,
        [Parameter(Mandatory = $true)][int]$Indent
    )

    if ($Index.Value -ge $Lines.Count -or $Lines[$Index.Value].Indent -ne $Indent) {
        throw 'YAML indentation is inconsistent.'
    }
    if ($Lines[$Index.Value].Text.StartsWith('- ')) {
        $sequence = @()
        while ($Index.Value -lt $Lines.Count -and $Lines[$Index.Value].Indent -eq $Indent) {
            $line = $Lines[$Index.Value]
            if (-not $line.Text.StartsWith('- ')) { break }
            $rest = $line.Text.Substring(2).Trim()
            $Index.Value++
            if ($rest.Length -eq 0) {
                if ($Index.Value -ge $Lines.Count -or $Lines[$Index.Value].Indent -le $Indent) {
                    throw "YAML line $($line.Number) has an empty sequence item."
                }
                $sequence += ,(ConvertFrom-WorkspaceRecipeYamlBlock $Lines $Index $Lines[$Index.Value].Indent)
                continue
            }
            if ($rest -match '^([A-Za-z0-9_-]+):(?:\s*(.*))?$') {
                $item = [ordered]@{}
                $key = $Matches[1]
                $textValue = $Matches[2]
                if ([string]::IsNullOrEmpty($textValue)) {
                    if ($Index.Value -lt $Lines.Count -and $Lines[$Index.Value].Indent -gt $Indent) {
                        $firstValue = ConvertFrom-WorkspaceRecipeYamlBlock $Lines $Index $Lines[$Index.Value].Indent
                    } else { $firstValue = $null }
                } else {
                    $firstValue = ConvertFrom-WorkspaceRecipeYamlScalar $textValue "YAML line $($line.Number)"
                }
                Add-WorkspaceRecipeYamlEntry $item $key $firstValue "YAML line $($line.Number)"
                if ($Index.Value -lt $Lines.Count -and $Lines[$Index.Value].Indent -gt $Indent) {
                    $continuationIndent = $Lines[$Index.Value].Indent
                    $continuation = ConvertFrom-WorkspaceRecipeYamlBlock $Lines $Index $continuationIndent
                    if ($continuation -isnot [System.Collections.IDictionary]) {
                        throw "YAML line $($line.Number) mapping continuation must be a mapping."
                    }
                    foreach ($continuationKey in $continuation.Keys) {
                        Add-WorkspaceRecipeYamlEntry $item ([string]$continuationKey) $continuation[$continuationKey] "YAML line $($line.Number)"
                    }
                }
                $sequence += ,$item
            } else {
                $sequence += ,(ConvertFrom-WorkspaceRecipeYamlScalar $rest "YAML line $($line.Number)")
            }
        }
        return ,@($sequence)
    }

    $mapping = [ordered]@{}
    while ($Index.Value -lt $Lines.Count -and $Lines[$Index.Value].Indent -eq $Indent) {
        $line = $Lines[$Index.Value]
        if ($line.Text.StartsWith('- ')) { break }
        if ($line.Text -notmatch '^([A-Za-z0-9_-]+):(?:\s*(.*))?$') {
            throw "YAML line $($line.Number) is not a supported mapping entry."
        }
        $key = $Matches[1]
        $textValue = $Matches[2]
        $Index.Value++
        if ([string]::IsNullOrEmpty($textValue)) {
            if ($Index.Value -lt $Lines.Count -and $Lines[$Index.Value].Indent -gt $Indent) {
                $entryValue = ConvertFrom-WorkspaceRecipeYamlBlock $Lines $Index $Lines[$Index.Value].Indent
            } else { $entryValue = $null }
        } else {
            $entryValue = ConvertFrom-WorkspaceRecipeYamlScalar $textValue "YAML line $($line.Number)"
        }
        Add-WorkspaceRecipeYamlEntry $mapping $key $entryValue "YAML line $($line.Number)"
    }
    return $mapping
}

function ConvertFrom-WorkspaceRecipeYaml {
    param([Parameter(Mandatory = $true)][string]$Content)

    $lines = @()
    $number = 0
    foreach ($rawLine in ($Content -split "`r?`n")) {
        $number++
        if ($rawLine -match "`t") { throw "YAML line $number contains a tab indentation." }
        if ([string]::IsNullOrWhiteSpace($rawLine) -or $rawLine.TrimStart().StartsWith('#')) { continue }
        $indent = $rawLine.Length - $rawLine.TrimStart(' ').Length
        if (($indent % 2) -ne 0) { throw "YAML line $number must use two-space indentation." }
        $text = $rawLine.Trim()
        $lines += [pscustomobject]@{ Indent = $indent; Text = $text; Number = $number }
    }
    if ($lines.Count -eq 0) { return [ordered]@{} }
    if ($lines[0].Indent -ne 0) { throw 'YAML root must start at indentation zero.' }
    $index = 0
    $result = ConvertFrom-WorkspaceRecipeYamlBlock $lines ([ref]$index) 0
    if ($index -ne $lines.Count) { throw "YAML line $($lines[$index].Number) has inconsistent indentation." }
    if ($result -isnot [System.Collections.IDictionary]) { throw 'YAML root must be a mapping.' }
    return $result
}

function Read-WorkspaceRecipeDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path,
        [System.Text.UTF8Encoding]::new($false, $true))
    if ([string]::IsNullOrWhiteSpace($raw)) { return [ordered]@{} }

    try { return ConvertFrom-WorkspaceRecipeYaml -Content $raw } catch {
        throw "Unable to parse workspace configuration at the requested path: $($_.Exception.Message)"
    }
}

function Get-WorkspaceRecipeFingerprint {
    param([Parameter(Mandatory = $true)]$CanonicalIntent)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
        ($CanonicalIntent | ConvertTo-Json -Depth 20 -Compress))
    $digest = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ('sha256:' + [Convert]::ToHexString($digest).ToLowerInvariant())
}

function Get-WorkspaceRecipeSlotCatalog {
    param([Parameter(Mandatory = $true)]$SlotCatalog)

    $catalog = [ordered]@{}
    if ($SlotCatalog -is [System.Collections.IDictionary]) {
        foreach ($key in $SlotCatalog.Keys) {
            $slotId = Assert-WorkspaceRecipeId -Value ([string]$key) -Context 'slot catalog key'
            if ($catalog.Contains($slotId)) { throw "slot catalog contains duplicate slot '$slotId'." }
            $catalog[$slotId] = $SlotCatalog[$key]
        }
        return $catalog
    }

    if ($SlotCatalog -is [string] -or $SlotCatalog -isnot [System.Collections.IEnumerable]) {
        throw 'slot catalog must be a mapping or sequence.'
    }
    foreach ($slot in $SlotCatalog) {
        $slotIdValue = Get-WorkspaceRecipeProperty $slot 'slot_id'
        if ($null -eq $slotIdValue) { $slotIdValue = Get-WorkspaceRecipeProperty $slot 'slot-id' }
        $slotId = Assert-WorkspaceRecipeId -Value $slotIdValue -Context 'slot catalog slot_id'
        if ($catalog.Contains($slotId)) { throw "slot catalog contains duplicate slot '$slotId'." }
        $catalog[$slotId] = $slot
    }
    return $catalog
}

function Test-WorkspaceRecipeSlotCapability {
    param(
        [Parameter(Mandatory = $true)]$Slot,
        [Parameter(Mandatory = $true)][string]$Capability
    )

    switch ($Capability) {
        'file-edit' { return (Get-WorkspaceRecipeProperty $Slot 'supports_file_edit') -eq $true }
        'review' {
            return (Get-WorkspaceRecipeProperty $Slot 'supports_verification') -eq $true -and
                (Get-WorkspaceRecipeProperty $Slot 'supports_structured_result') -eq $true
        }
        default { throw "Unknown public capability '$Capability'." }
    }
}

function Resolve-WorkspaceRecipeCapabilities {
    param(
        [object[]]$Values,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $result = @()
    foreach ($valueSet in $Values) {
        foreach ($capability in @(ConvertTo-WorkspaceRecipeStringList -Value $valueSet -Context $Context)) {
            if ($script:WorkspaceRecipeCapabilities -cnotcontains $capability) {
                throw "$Context contains an unknown capability."
            }
            if ($result -cnotcontains $capability) { $result += $capability }
        }
    }
    return @($result)
}

function Resolve-WorkspaceRecipeManagedName {
    param(
        [Parameter(Mandatory = $true)][string]$Template,
        [AllowNull()][string]$WorkflowId,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Template -match '\{\{workflow-id\}\}' -and [string]::IsNullOrWhiteSpace($WorkflowId)) {
        throw "$Context requires an explicit workflow id."
    }
    if ($Template -match '\{\{' -and $Template -notmatch '^([^{]|\{\{workflow-id\}\})+$') {
        throw "$Context contains an unsupported template token."
    }
    $name = if ($null -eq $WorkflowId) { $Template } else { $Template.Replace('{{workflow-id}}', $WorkflowId) }
    if ([System.IO.Path]::IsPathRooted($name) -or $name -match '[\\/:]' -or
        $name.Contains('..') -or $name -notmatch '^[a-z0-9][a-z0-9._-]*$') {
        throw "$Context must resolve to one safe managed-worktree name."
    }
    if ([Regex]::IsMatch($name, $script:WorkspaceRecipeSyntheticCredentialPattern,
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw 'Workspace recipe output must not contain credential-like material.'
    }
    return $name
}

function New-WorkspaceRecipePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)][string]$RecipeId,
        [AllowNull()][string]$WorkflowId,
        [Parameter(Mandatory = $true)]$SlotCatalog
    )

    $RecipeId = Assert-WorkspaceRecipeId -Value $RecipeId -Context 'recipe id'
    $recipes = Get-WorkspaceRecipeProperty $Document 'workspace-recipes'
    if ($null -eq $recipes) { throw "Workspace recipe '$RecipeId' was not found." }
    if (-not [string]::IsNullOrWhiteSpace($WorkflowId)) {
        $WorkflowId = Assert-WorkspaceRecipeId -Value $WorkflowId -Context 'workflow id'
    }

    $recipe = Get-WorkspaceRecipeProperty $recipes $RecipeId
    if ($null -eq $recipe) { throw "Workspace recipe '$RecipeId' was not found." }
    Assert-WorkspaceRecipeObject $recipe "workspace recipe '$RecipeId'" `
        @('schema-version', 'panes', 'startup-actions') @('schema-version', 'panes', 'startup-actions')
    if ((Get-WorkspaceRecipeProperty $recipe 'schema-version') -ne 1) {
        throw "Workspace recipe '$RecipeId' uses unsupported schema-version."
    }

    $catalog = Get-WorkspaceRecipeSlotCatalog -SlotCatalog $SlotCatalog
    $paneValues = Get-WorkspaceRecipeProperty $recipe 'panes'
    if ($paneValues -is [string] -or $paneValues -isnot [System.Collections.IEnumerable]) {
        throw "workspace recipe '$RecipeId'.panes must be a sequence."
    }
    if (@($paneValues).Count -eq 0) { throw "workspace recipe '$RecipeId'.panes must not be empty." }

    $panes = @()
    $paneKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($pane in $paneValues) {
        Assert-WorkspaceRecipeObject $pane 'pane' `
            @('pane-key', 'workflow-role', 'slot-ref', 'slot-selector', 'requires-capabilities', 'region', 'worktree') `
            @('pane-key', 'workflow-role', 'region', 'worktree')
        $paneKey = Assert-WorkspaceRecipeId (Get-WorkspaceRecipeProperty $pane 'pane-key') 'pane-key'
        if (-not $paneKeys.Add($paneKey)) { throw "Duplicate pane-key '$paneKey'." }
        $region = Assert-WorkspaceRecipeId (Get-WorkspaceRecipeProperty $pane 'region') "pane '$paneKey' region"
        $workflowRole = Assert-WorkspaceRecipeId (Get-WorkspaceRecipeProperty $pane 'workflow-role') "pane '$paneKey' workflow-role"

        $slotRef = Get-WorkspaceRecipeProperty $pane 'slot-ref'
        $selector = Get-WorkspaceRecipeProperty $pane 'slot-selector'
        if (($null -eq $slotRef) -eq ($null -eq $selector)) {
            throw "Pane '$paneKey' must set exactly one of slot-ref or slot-selector."
        }
        $selectorCapabilities = $null
        if ($null -ne $selector) {
            Assert-WorkspaceRecipeObject $selector "pane '$paneKey' slot-selector" @('requires-capabilities') @('requires-capabilities')
            $selectorCapabilities = Get-WorkspaceRecipeProperty $selector 'requires-capabilities'
            if (@(ConvertTo-WorkspaceRecipeStringList $selectorCapabilities "pane '$paneKey' slot-selector requires-capabilities").Count -eq 0) {
                throw "Pane '$paneKey' slot-selector requires at least one capability."
            }
        }
        $capabilities = @(Resolve-WorkspaceRecipeCapabilities `
            -Values @((Get-WorkspaceRecipeProperty $pane 'requires-capabilities'), $selectorCapabilities) `
            -Context "pane '$paneKey' requires-capabilities")

        if ($null -ne $slotRef) {
            $resolvedSlot = Assert-WorkspaceRecipeId $slotRef "pane '$paneKey' slot-ref"
            if (-not $catalog.Contains($resolvedSlot)) { throw "Pane '$paneKey' references missing slot '$resolvedSlot'." }
            foreach ($capability in $capabilities) {
                if (-not (Test-WorkspaceRecipeSlotCapability $catalog[$resolvedSlot] $capability)) {
                    throw "Slot '$resolvedSlot' lacks capability '$capability' required by pane '$paneKey'."
                }
            }
        } else {
            $matches = @($catalog.Keys | Where-Object {
                $candidate = $catalog[$_]
                $ok = $true
                foreach ($capability in $capabilities) {
                    if (-not (Test-WorkspaceRecipeSlotCapability $candidate $capability)) { $ok = $false; break }
                }
                $ok
            })
            if ($matches.Count -eq 0) { throw "Pane '$paneKey' slot-selector matched zero slots." }
            if ($matches.Count -ne 1) { throw "Pane '$paneKey' slot-selector is ambiguous ($($matches.Count) matches)." }
            $resolvedSlot = [string]$matches[0]
        }

        $worktree = Get-WorkspaceRecipeProperty $pane 'worktree'
        Assert-WorkspaceRecipeObject $worktree "pane '$paneKey' worktree" @('mode', 'name-template') @('mode')
        $mode = Get-WorkspaceRecipeProperty $worktree 'mode'
        if ($mode -cnotin @('managed', 'read-only-reference')) { throw "Pane '$paneKey' has an unknown worktree mode." }
        $nameTemplate = Get-WorkspaceRecipeProperty $worktree 'name-template'
        $normalizedWorktree = [ordered]@{ mode = $mode }
        if ($mode -eq 'managed') {
            if ($nameTemplate -isnot [string]) { throw "Pane '$paneKey' managed worktree requires name-template." }
            $normalizedWorktree.name = Resolve-WorkspaceRecipeManagedName $nameTemplate $WorkflowId "pane '$paneKey' name-template"
        } elseif ($null -ne $nameTemplate) {
            throw "Pane '$paneKey' read-only-reference worktree cannot set name-template."
        }

        $panes += [ordered]@{
            pane_key = $paneKey
            workflow_role = $workflowRole
            slot_id = $resolvedSlot
            required_capabilities = @($capabilities)
            region = $region
            worktree = $normalizedWorktree
        }
    }

    $actions = @()
    $actionIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $actionValues = Get-WorkspaceRecipeProperty $recipe 'startup-actions'
    if ($actionValues -is [string] -or $actionValues -isnot [System.Collections.IEnumerable]) {
        throw "workspace recipe '$RecipeId'.startup-actions must be a sequence."
    }
    foreach ($action in $actionValues) {
        Assert-WorkspaceRecipeObject $action 'startup action' @('action-id', 'kind', 'pane-ref') @('action-id', 'kind', 'pane-ref')
        $actionId = Assert-WorkspaceRecipeId (Get-WorkspaceRecipeProperty $action 'action-id') 'action-id'
        if (-not $actionIds.Add($actionId)) { throw "Duplicate action-id '$actionId'." }
        $kind = Get-WorkspaceRecipeProperty $action 'kind'
        if ($kind -isnot [string] -or $script:WorkspaceRecipeActionKinds -cnotcontains $kind) {
            throw "Startup action '$actionId' has unknown kind."
        }
        $paneRef = Assert-WorkspaceRecipeId (Get-WorkspaceRecipeProperty $action 'pane-ref') "startup action '$actionId' pane-ref"
        if (-not $paneKeys.Contains($paneRef)) { throw "Startup action '$actionId' references unknown pane '$paneRef'." }
        if ($kind -eq 'ensure-managed-worktree') {
            $targetPane = $panes | Where-Object pane_key -CEQ $paneRef | Select-Object -First 1
            if ($targetPane.worktree.mode -ne 'managed') {
                throw "Startup action '$actionId' requires a managed-worktree pane."
            }
        }
        $actions += [ordered]@{ action_id = $actionId; kind = $kind; pane_ref = $paneRef }
    }

    $bindings = [ordered]@{}
    $bindingKeys = [string[]]@($panes | ForEach-Object { $_.pane_key })
    [Array]::Sort($bindingKeys, [StringComparer]::Ordinal)
    foreach ($bindingKey in $bindingKeys) {
        $bindingPane = $panes | Where-Object pane_key -CEQ $bindingKey | Select-Object -First 1
        $bindings[$bindingKey] = $bindingPane.slot_id
    }
    $canonicalIntent = [ordered]@{
        schema_version = 1
        recipe_id = $RecipeId
        workflow_id = if ([string]::IsNullOrWhiteSpace($WorkflowId)) { $null } else { $WorkflowId }
        panes = @($panes)
        startup_actions = @($actions)
        resolved_bindings = $bindings
    }
    return [ordered]@{
        schema_version = 1
        config_fingerprint = Get-WorkspaceRecipeFingerprint $canonicalIntent
        recipe_id = $canonicalIntent.recipe_id
        workflow_id = $canonicalIntent.workflow_id
        panes = $canonicalIntent.panes
        startup_actions = $canonicalIntent.startup_actions
        resolved_bindings = $canonicalIntent.resolved_bindings
    }
}

function ConvertTo-WorkspaceRecipePlanJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)
    return ($Plan | ConvertTo-Json -Depth 20 -Compress)
}
