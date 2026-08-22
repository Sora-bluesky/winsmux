Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-PlanningModelDurably {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LiteralPath,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Content
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        throw 'LiteralPath is empty.'
    }
    if ($LiteralPath.IndexOf([char]0) -ge 0) {
        throw 'LiteralPath contains a NUL character.'
    }

    $directory = [IO.Path]::GetDirectoryName($LiteralPath)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "LiteralPath has no directory: $LiteralPath"
    }
    if (-not [IO.Directory]::Exists($directory)) {
        $null = [IO.Directory]::CreateDirectory($directory)
    }

    $stagingName = [guid]::NewGuid().ToString('N') + '.planning-model.tmp'
    $stagingPath = [IO.Path]::Combine($directory, $stagingName)
    $utf8 = [Text.UTF8Encoding]::new($false)
    $bytes = $utf8.GetBytes($Content)
    $stream = $null
    $published = $false
    try {
        $stream = [IO.File]::Open(
            $stagingPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        if ([IO.File]::Exists($LiteralPath)) {
            [IO.File]::Move($stagingPath, $LiteralPath, $true)
        } else {
            [IO.File]::Move($stagingPath, $LiteralPath)
        }
        $published = $true
    } catch {
        throw
    } finally {
        if ($null -ne $stream) {
            try { $stream.Dispose() } catch { }
        }
        if (-not $published -and [IO.File]::Exists($stagingPath)) {
            try { [IO.File]::Delete($stagingPath) } catch { }
        }
    }
}
