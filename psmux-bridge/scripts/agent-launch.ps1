$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-AgentLaunchCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir
    )

    switch ($Agent.Trim().ToLowerInvariant()) {
        'codex' {
            return "codex -c model=$Model --full-auto -C $(ConvertTo-PowerShellLiteral -Value $ProjectDir) --add-dir $(ConvertTo-PowerShellLiteral -Value $GitWorktreeDir)"
        }
        'claude' {
            return 'claude --permission-mode bypassPermissions'
        }
        default {
            throw "Unsupported agent setting: $Agent"
        }
    }
}

function Get-AgentBootstrapPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Role
    )

    if ($Agent.Trim().ToLowerInvariant() -ne 'codex') {
        return $null
    }

    if ($Role.Trim().ToLowerInvariant() -ne 'builder') {
        return $null
    }

    return 'Windows sandbox note: PowerShell is in ConstrainedLanguageMode. For any file edit/write, prefer apply_patch; for simple shell writes use cmd /c. Do not use Set-Content, Out-File, Add-Content, [IO.File]::WriteAllText/WriteAllBytes, or property assignment on non-core types. Reply exactly OK, then wait for the next task.'
}
