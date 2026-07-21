$ErrorActionPreference = 'Stop'

function script:Write-PsmuxBridgeTestFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Content = ''
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if ([string]::IsNullOrEmpty($Content)) {
        Set-Content -Path $Path -Value '' -Encoding UTF8
    } else {
        Set-Content -Path $Path -Value $Content -Encoding UTF8
    }
}

function script:ConvertTo-GoldenCorpusJson {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    $json = $InputObject | ConvertTo-Json -Depth 20
    $escapedProjectDir = [Regex]::Escape(($ProjectDir -replace '\\', '\\'))
    $normalized = $json -replace $escapedProjectDir, '__PROJECT_DIR__'
    $normalized = [Regex]::Replace(
        $normalized,
        '"generated_at"\s*:\s*"[^"]+"',
        '"generated_at": "__GENERATED_AT__"'
    )
    $normalized = [Regex]::Replace(
        $normalized,
        '"timestamp"\s*:\s*"[^"]*"',
        '"timestamp": "__TIMESTAMP__"'
    )
    $normalized = [Regex]::Replace(
        $normalized,
        '"last_event_at"\s*:\s*"[^"]+"',
        '"last_event_at": "__LAST_EVENT_AT__"'
    )
    $normalized = [Regex]::Replace(
        $normalized,
        '"created_at"\s*:\s*"[^"]+"',
        '"created_at": "__LAST_EVENT_AT__"'
    )
    $normalized = [Regex]::Replace(
        $normalized,
        '"source_time"\s*:\s*"[^"]+"',
        '"source_time": "__LAST_EVENT_AT__"'
    )
    $normalized = [Regex]::Replace(
        $normalized,
        'observation-pack-[a-f0-9]+\.json',
        'observation-pack-__ID__.json'
    )
    $normalized = [Regex]::Replace(
        $normalized,
        'consult-result-[a-f0-9]+\.json',
        'consult-result-__ID__.json'
    )

    return ($normalized.TrimEnd() + "`n")
}

function script:Assert-GoldenCorpusFixture {
    param(
        [Parameter(Mandatory = $true)][string]$FixturePath,
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    $repoRoot = Split-Path -Parent $script:BridgeTestsRoot
    $fullFixturePath = Join-Path $repoRoot $FixturePath
    $actual = ConvertTo-GoldenCorpusJson -InputObject $InputObject -ProjectDir $ProjectDir

    if ($env:WINSMUX_UPDATE_GOLDEN -eq '1') {
        Write-PsmuxBridgeTestFile -Path $fullFixturePath -Content $actual
    }

    Test-Path -LiteralPath $fullFixturePath | Should -Be $true
    $expected = (Get-Content -Raw -Path $fullFixturePath -Encoding UTF8).TrimEnd("`r", "`n")
    $expected = $expected -replace "`r`n", "`n"
    $actual = $actual.TrimEnd("`r", "`n") -replace "`r`n", "`n"
    $actual | Should -Be $expected
}
