Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Invoke-RecordedGate {
    param([string]$Name, [string]$File, [string[]]$Arguments, [switch]$Cargo)
    $lines = @(& $File @Arguments 2>&1 | ForEach-Object { $line = "$_"; Write-Host $line; $line })
    $code = $LASTEXITCODE
    $count = 0
    if ($Cargo) {
        foreach ($line in $lines) {
            if ($line -match '^test result: (?:ok|FAILED)\. (\d+) passed; (\d+) failed;') {
                $count += [int]$Matches[1] + [int]$Matches[2]
            }
        }
    }
    $problem = if ($Cargo -and $count -eq 0) { 'no executed tests' } else { '' }
    [IO.File]::WriteAllText((Join-Path $gateOutput ($Name + '.log')), (($lines -join "`n") + "`n").Replace("`r`n","`n"), [Text.UTF8Encoding]::new($false))
    $gateResults.Add([ordered]@{ name=$Name; command=@($File)+$Arguments; exit_code=$code; tests=$count; problem=$problem })
}
function Complete-Gates {
    param([string]$Schema, [string]$Mode, [string[]]$Separate)
    $failed = @($gateResults | Where-Object { $_.exit_code -ne 0 -or $_.problem })
    $testCount = 0
    foreach ($gate in $gateResults) { $testCount += [int]$gate['tests'] }
    $summary = [ordered]@{ schema=$Schema; mode=$Mode; passed=($gateResults.Count-$failed.Count); failed=$failed.Count;
        tests=$testCount; gates=$gateResults.ToArray(); separate_native_actions=$Separate }
    $text = $summary | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::WriteAllText((Join-Path $gateOutput 'result.json'),$text+"`n",[Text.UTF8Encoding]::new($false))
    Write-Host $text
    return ($failed.Count -eq 0)
}
