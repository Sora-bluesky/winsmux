[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExpectedPath,

    [Parameter(Mandatory = $true)]
    [string]$ActualPath,

    [string]$Surface = 'unspecified',

    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Stop-GateError {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Error $Message
    exit 2
}

function Read-GateJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-GateError "shadow-cutover-gate input not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Stop-GateError "shadow-cutover-gate input is empty: $Path"
    }

    try {
        return ($raw | ConvertFrom-Json -Depth 64)
    } catch {
        Stop-GateError "shadow-cutover-gate input is not valid JSON: $Path"
    }
}

function Test-HumanReadablePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $leaf = ($Path -split '\.')[-1]
    return $leaf -in @(
        'message',
        'detail',
        'operator_message',
        'next_action',
        'reason',
        'summary',
        'description'
    )
}

function Add-GateDifference {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()]$Expected,
        [AllowNull()]$Actual,
        [bool]$Allowed = $false
    )

    $Differences.Add([ordered]@{
        kind     = $Kind
        path     = $Path
        expected = $Expected
        actual   = $Actual
        allowed  = $Allowed
    }) | Out-Null
}

function Get-GateKind {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return 'object'
    }

    if ($Value -is [pscustomobject]) {
        return 'object'
    }

    if ($Value -is [System.Array]) {
        return 'array'
    }

    return 'scalar'
}

function Compare-GateJson {
    param(
        [AllowNull()]$Expected,
        [AllowNull()]$Actual,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Differences
    )

    $expectedKind = Get-GateKind -Value $Expected
    $actualKind = Get-GateKind -Value $Actual

    if ($expectedKind -ne $actualKind) {
        Add-GateDifference -Differences $Differences -Kind 'type_mismatch' -Path $Path -Expected $expectedKind -Actual $actualKind
        return
    }

    switch ($expectedKind) {
        'object' {
            $expectedNames = @($Expected.PSObject.Properties.Name)
            $actualNames = @($Actual.PSObject.Properties.Name)

            foreach ($name in $expectedNames) {
                $childPath = if ($Path -eq '$') { '$.' + $name } else { $Path + '.' + $name }
                if ($name -notin $actualNames) {
                    Add-GateDifference -Differences $Differences -Kind 'missing_in_actual' -Path $childPath -Expected $Expected.$name -Actual $null
                    continue
                }

                Compare-GateJson -Expected $Expected.$name -Actual $Actual.$name -Path $childPath -Differences $Differences
            }

            foreach ($name in $actualNames) {
                if ($name -notin $expectedNames) {
                    $childPath = if ($Path -eq '$') { '$.' + $name } else { $Path + '.' + $name }
                    Add-GateDifference -Differences $Differences -Kind 'unexpected_in_actual' -Path $childPath -Expected $null -Actual $Actual.$name
                }
            }
        }
        'array' {
            if ($Expected.Count -ne $Actual.Count) {
                Add-GateDifference -Differences $Differences -Kind 'array_length_mismatch' -Path $Path -Expected $Expected.Count -Actual $Actual.Count
                return
            }

            for ($index = 0; $index -lt $Expected.Count; $index++) {
                Compare-GateJson -Expected $Expected[$index] -Actual $Actual[$index] -Path ("{0}[{1}]" -f $Path, $index) -Differences $Differences
            }
        }
        'scalar' {
            $expectedText = [string]$Expected
            $actualText = [string]$Actual
            if ($expectedText -ne $actualText) {
                $allowed = Test-HumanReadablePath -Path $Path
                Add-GateDifference -Differences $Differences -Kind 'value_mismatch' -Path $Path -Expected $Expected -Actual $Actual -Allowed $allowed
            }
        }
        default {
            return
        }
    }
}

$expectedJson = Read-GateJson -Path $ExpectedPath
$actualJson = Read-GateJson -Path $ActualPath
$differences = [System.Collections.Generic.List[object]]::new()
Compare-GateJson -Expected $expectedJson -Actual $actualJson -Path '$' -Differences $differences

$blockingDifferences = @($differences | Where-Object { -not [bool]$_.allowed })
$allowedDifferences = @($differences | Where-Object { [bool]$_.allowed })
$passed = ($blockingDifferences.Count -eq 0)

$result = [ordered]@{
    surface     = $Surface
    passed      = $passed
    diff_budget = [ordered]@{
        machine_readable_fields = 'exact'
        human_readable_fields   = 'wording differences allowed'
    }
    summary     = [ordered]@{
        blocking_differences = $blockingDifferences.Count
        allowed_differences  = $allowedDifferences.Count
        total_differences    = $differences.Count
    }
    differences = @($differences)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 64 -Compress | Write-Output
} else {
    if ($passed) {
        Write-Output "shadow-cutover-gate passed for $Surface"
    } else {
        Write-Output ("shadow-cutover-gate failed for {0}: {1} blocking difference(s)" -f $Surface, $blockingDifferences.Count)
    }
}

if (-not $passed) {
    exit 1
}
