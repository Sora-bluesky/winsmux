$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-WinsmuxTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Content = '',
        [switch]$Append
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $escapedPath = $Path -replace '"', '""'
    if ([string]::IsNullOrEmpty($Content)) {
        if ($Append) {
            return
        }

        cmd /d /c ('type nul > "{0}"' -f $escapedPath) | Out-Null
    } else {
        $redirect = if ($Append) { '>>' } else { '>' }
        $Content | cmd /d /c ('more {0} "{1}"' -f $redirect, $escapedPath) | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {
        throw "cmd.exe failed to write $Path"
    }
}
