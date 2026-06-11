#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$python = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
if ([string]::IsNullOrWhiteSpace($python)) {
    $python = 'python'
}

$script = Join-Path $PSScriptRoot 'google_colab_cli_adapter.py'
& $python $script @args
exit $LASTEXITCODE
