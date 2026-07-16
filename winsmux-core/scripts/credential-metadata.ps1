function Invoke-WinsmuxCredentialMetadataCommand {
    $command = Get-Command cmdkey.exe -CommandType Application -ErrorAction Stop
    $output = @(& $command.Source /list 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "cmdkey metadata enumeration failed (exit $LASTEXITCODE)"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Get-WinsmuxCredentialTargetNames {
    [CmdletBinding()]
    param([string]$Prefix = 'winsmux:')

    $marker = 'LegacyGeneric:target=' + $Prefix
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Invoke-WinsmuxCredentialMetadataCommand)) {
        $index = $line.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
        if ($index -lt 0) { continue }
        $name = $line.Substring($index + $marker.Length).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $names.Add($name) | Out-Null
        }
    }
    return @($names | Sort-Object -Unique)
}
