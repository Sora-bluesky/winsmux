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

        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\vault.ps1')

        if (-not ('WinCredDeleteNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WinCredDeleteNative {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredDelete(string target, uint type, uint flags);
}
'@
        }

        function Get-StoredCredentialTargets {
            param([Parameter(Mandatory = $true)][string]$Filter)

            $count = 0
            $credsPtr = [IntPtr]::Zero
            $ok = [WinCred]::CredEnumerate($Filter, 0, [ref]$count, [ref]$credsPtr)
            if (-not $ok) {
                $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                if ($errCode -eq 1168) {
                    return @()
                }

                throw "CredEnumerate failed (error $errCode)"
            }

            try {
                $targets = [System.Collections.Generic.List[string]]::new()
                $ptrSize = [Runtime.InteropServices.Marshal]::SizeOf([Type][IntPtr])
                for ($i = 0; $i -lt $count; $i++) {
                    $entryPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($credsPtr, $i * $ptrSize)
                    $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($entryPtr, [Type][WinCred+CREDENTIAL])
                    $targets.Add($cred.TargetName) | Out-Null
                }

                return $targets.ToArray()
            } finally {
                [WinCred]::CredFree($credsPtr) | Out-Null
            }
        }

        function Remove-StoredCredentialTargets {
            param([Parameter(Mandatory = $true)][string[]]$Targets)

            foreach ($target in $Targets) {
                $ok = [WinCredDeleteNative]::CredDelete($target, [WinCred]::CRED_TYPE_GENERIC, 0)
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
}
