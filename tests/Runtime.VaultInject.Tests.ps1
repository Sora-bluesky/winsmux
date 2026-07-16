$ErrorActionPreference = 'Stop'

Describe 'Runtime vault helpers' {
    BeforeAll {
        function Stop-WithError {
            param([string]$Message)
            throw $Message
        }

        function Resolve-Target {
            param([string]$RawTarget)
            return $RawTarget
        }

        function Confirm-Target {
            param([string]$PaneId)
            return $PaneId
        }

        function Assert-ReadMark {
            param([string]$PaneId)
        }

        function Clear-ReadMark {
            param([string]$PaneId)
        }

        function Assert-WinsmuxTargetRuntimeWriteAllowed {
            param(
                [string]$PaneId,
                [string]$CurrentProjectDir,
                [string]$Operation,
                [string]$ExpectedGenerationId = ''
            )
            return [PSCustomObject]@{ GenerationId = 'generation-vault' }
        }

        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\vault.ps1')

        if (-not ('WinCredDeleteNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WinCredDeleteNative {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredDelete(string target, uint type, uint flags);

    public const uint CRED_TYPE_GENERIC = 1;
}
'@
        }

        function Get-StoredCredentialTargets {
            param([Parameter(Mandatory = $true)][string]$Filter)

            $nameFilter = $Filter -replace '^winsmux:', ''
            return @(Get-WinsmuxCredentialTargetNames |
                Where-Object { [string]$_ -like $nameFilter } |
                ForEach-Object { 'winsmux:{0}' -f [string]$_ })
        }

        function Remove-StoredCredentialTargets {
            param([Parameter(Mandatory = $true)][string[]]$Targets)

            foreach ($target in $Targets) {
                $ok = [WinCredDeleteNative]::CredDelete($target, [WinCredDeleteNative]::CRED_TYPE_GENERIC, 0)
                if (-not $ok) {
                    $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    if ($errCode -ne 1168) {
                        throw "CredDelete failed for $target (error $errCode)"
                    }
                }
            }
        }

        $script:OriginalTarget = $script:Target
        $script:OriginalRest = $script:Rest
        $script:RunPrefix = 'winsmux-test:{0}' -f [guid]::NewGuid().ToString('N')
    }

    BeforeEach {
        $script:Target = $null
        $script:Rest = @()
    }

    AfterAll {
        $targets = @(Get-StoredCredentialTargets -Filter ("winsmux:{0}:*" -f $script:RunPrefix))
        if ($targets.Count -gt 0) {
            Remove-StoredCredentialTargets -Targets $targets
        }

        $script:Target = $script:OriginalTarget
        $script:Rest = $script:OriginalRest
    }

    It 'vault set stores a credential under the unique winsmux-test prefix' {
        $script:Target = '{0}:set' -f $script:RunPrefix
        $script:Rest = @('set-secret')

        Invoke-VaultSet | Out-Null

        $storedTargets = @(Get-StoredCredentialTargets -Filter ("winsmux:{0}:*" -f $script:RunPrefix))
        $storedTargets | Should -Contain ('winsmux:{0}' -f $script:Target)
    }

    It 'vault get retrieves a stored credential' {
        $script:Target = '{0}:get' -f $script:RunPrefix
        $script:Rest = @('get-secret')
        Invoke-VaultSet | Out-Null

        $script:Rest = @()

        (Invoke-VaultGet) | Should -Be 'get-secret'
    }

    It 'vault list includes the stored credential key' {
        $script:Target = '{0}:list' -f $script:RunPrefix
        $script:Rest = @('list-secret')
        Invoke-VaultSet | Out-Null

        $listedKeys = @(Invoke-VaultList)

        $listedKeys | Should -Contain $script:Target
    }

    It 'revalidates one captured generation before every modular Vault secret read and mutation' {
        $script:Target = '%2'
        $script:VaultGuardSequence = [System.Collections.Generic.List[string]]::new()
        Mock Resolve-Target { return $RawTarget }
        Mock Confirm-Target { return $PaneId }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            $script:VaultGuardSequence.Add(('guard:{0}' -f [string]$ExpectedGenerationId)) | Out-Null
            return [PSCustomObject]@{ GenerationId = 'generation-vault' }
        }
        Mock Assert-ReadMark { $script:VaultGuardSequence.Add('mark') | Out-Null }
        Mock Get-WinsmuxCredentialTargetNames {
            $script:VaultGuardSequence.Add('names') | Out-Null
            return @('FIRST', 'SECOND')
        }
        Mock Get-WinsmuxSessionNameForPane {
            $script:VaultGuardSequence.Add('session') | Out-Null
            return 'winsmux-orchestra'
        }
        Mock Get-WinsmuxVaultCredentialValue {
            $script:VaultGuardSequence.Add(('read:{0}' -f $Name)) | Out-Null
            return ('value-{0}' -f $Name)
        }
        Mock Invoke-WinsmuxSourceFile {
            $script:VaultGuardSequence.Add('mutate') | Out-Null
            return [PSCustomObject]@{ Success = $true; ExitCode = 0; Output = '' }
        }
        Mock Clear-ReadMark { $script:VaultGuardSequence.Add('clear') | Out-Null }

        Invoke-VaultInject | Should -Be 'injected 2 credential(s) into %2'

        @($script:VaultGuardSequence) | Should -Be @(
            'guard:'
            'mark'
            'names'
            'session'
            'guard:generation-vault'
            'read:FIRST'
            'guard:generation-vault'
            'mutate'
            'guard:generation-vault'
            'read:SECOND'
            'guard:generation-vault'
            'mutate'
            'guard:generation-vault'
            'clear'
        )
    }
}
