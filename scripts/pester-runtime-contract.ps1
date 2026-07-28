#Requires -Version 7.6

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WinsmuxPesterRuntimeContract {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$Executable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName,
        [version]$Version = $PSVersionTable.PSVersion
    )

    $resolvedExecutable = [System.IO.Path]::GetFullPath($Executable)
    if (-not (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf)) {
        throw "The selected PowerShell executable was not found: $resolvedExecutable"
    }

    [PSCustomObject][ordered]@{
        schema_version = 1
        authority_path = [System.IO.Path]::GetFullPath(
            (Join-Path $RepositoryRoot 'scripts/pester-runtime-contract.ps1')
        )
        scope = 'official-developer-pester-only'
        runtime_train = '7.6'
        ci_proof_version = '7.6.4'
        version_policy = 'exact-major-minor-7.6'
        archive_name = 'PowerShell-7.6.4-win-x64.zip'
        archive_uri = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.4/PowerShell-7.6.4-win-x64.zip'
        archive_sha256 = '80832551C52809301E6071C8BAC977BEB5A2F1EC953EB4DB9F94DEB953333793'
        executable = $resolvedExecutable
        version = $Version.ToString()
    }
}

function Assert-WinsmuxPesterRuntime {
    param(
        [Parameter(Mandatory = $true)][psobject]$Contract,
        [version]$Version = $PSVersionTable.PSVersion,
        [string]$Executable
    )

    if (($Version.Major -ne 7) -or ($Version.Minor -ne 6)) {
        throw "The official developer Pester runner requires PowerShell 7.6.x; observed version is $Version."
    }

    if (-not [string]::IsNullOrWhiteSpace($Executable)) {
        $expected = [System.IO.Path]::GetFullPath([string]$Contract.executable)
        $observed = [System.IO.Path]::GetFullPath($Executable)
        if (-not [string]::Equals($observed, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "The Pester runtime must use the selected executable: $expected"
        }
    }

    $true
}
