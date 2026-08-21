<#
.SYNOPSIS
Vault commands for winsmux-core.

.DESCRIPTION
Dot-source this script to load the vault helpers into the current script scope:

    . "$PSScriptRoot/vault.ps1"

This file intentionally keeps the original function names and script-scope behavior.
The commands expect the caller to provide the surrounding bridge context, including
`$Target`, `$Rest`, `Stop-WithError`, `Resolve-Target`, `Confirm-Target`,
`Assert-ReadMark`, and `Clear-ReadMark`.
#>

if (-not (Get-Command Invoke-WinsmuxBridgeCommand -ErrorAction SilentlyContinue)) {
    $settingsScript = Join-Path $PSScriptRoot 'settings.ps1'
    if (Test-Path -LiteralPath $settingsScript -PathType Leaf) {
        . $settingsScript
    }
}

$credentialMetadataScript = Join-Path $PSScriptRoot 'credential-metadata.ps1'
if (-not (Get-Command Get-WinsmuxCredentialTargetNames -ErrorAction SilentlyContinue) -and
    (Test-Path -LiteralPath $credentialMetadataScript -PathType Leaf)) {
    . $credentialMetadataScript
}

if (-not ('WinsmuxVaultCredentialNative' -as [type])) {
    # --- Windows Credential Manager P/Invoke ---
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class WinsmuxVaultCredentialNative {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool CredFree(IntPtr credential);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public const uint CRED_TYPE_GENERIC = 1;
    public const uint CRED_PERSIST_LOCAL_MACHINE = 2;
}
'@ -ErrorAction SilentlyContinue
}

function Write-WinsmuxVaultCredentialInternal {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Stop-WithError "vault value for '$Key' must not be empty"
    }

    $credTarget = "winsmux:$Key"
    $valueBytes = [System.Text.Encoding]::Unicode.GetBytes($Value)
    $blobPtr = [Runtime.InteropServices.Marshal]::AllocHGlobal($valueBytes.Length)
    [Runtime.InteropServices.Marshal]::Copy($valueBytes, 0, $blobPtr, $valueBytes.Length)

    $cred = New-Object WinsmuxVaultCredentialNative+CREDENTIAL
    $cred.Type = [WinsmuxVaultCredentialNative]::CRED_TYPE_GENERIC
    $cred.TargetName = $credTarget
    $cred.UserName = "winsmux"
    $cred.CredentialBlobSize = $valueBytes.Length
    $cred.CredentialBlob = $blobPtr
    $cred.Persist = [WinsmuxVaultCredentialNative]::CRED_PERSIST_LOCAL_MACHINE

    try {
        $ok = [WinsmuxVaultCredentialNative]::CredWrite([ref]$cred, 0)
        if (-not $ok) {
            $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Stop-WithError "CredWrite failed (error $errCode)"
        }
        Write-Host "Stored credential: $Key"
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($blobPtr)
    }
}

function Invoke-VaultSet {
    $key = $Target
    if (-not $key) { Stop-WithError "usage: winsmux vault set <key>" }
    $restLen = 0
    if ($Rest -is [System.Array]) {
        $restLen = $Rest.Length
    } elseif ($null -ne $Rest) {
        $restLen = 1
    }
    if ($restLen -gt 0) {
        Stop-WithError "vault set does not accept the value on the command line"
    }

    $secure = Read-Host -AsSecureString "Enter value for '$key'"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    Write-WinsmuxVaultCredentialInternal -Key $key -Value $value
}

function Invoke-VaultGet {
    $key = $Target
    if (-not $key) { Stop-WithError "usage: winsmux vault get <key>" }

    $credTarget = "winsmux:$key"
    $credPtr = [IntPtr]::Zero

    $ok = [WinsmuxVaultCredentialNative]::CredRead($credTarget, [WinsmuxVaultCredentialNative]::CRED_TYPE_GENERIC, 0, [ref]$credPtr)
    if (-not $ok) {
        $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errCode -eq 1168) {
            Stop-WithError "credential not found: $key"
        }
        Stop-WithError "CredRead failed (error $errCode)"
    }

    try {
        $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [Type][WinsmuxVaultCredentialNative+CREDENTIAL])
        if ($cred.CredentialBlobSize -gt 0) {
            $bytes = New-Object byte[] $cred.CredentialBlobSize
            [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
            $value = [System.Text.Encoding]::Unicode.GetString($bytes)
            Write-Output $value
        }
    } finally {
        [WinsmuxVaultCredentialNative]::CredFree($credPtr) | Out-Null
    }
}

function Invoke-VaultList {
    $names = @(Get-WinsmuxCredentialTargetNames)
    if ($names.Count -eq 0) {
        Write-Output "(no credentials stored)"
        return
    }
    Write-Output $names
}

function Get-WinsmuxVaultCredentialValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    $credPtr = [IntPtr]::Zero
    $ok = [WinsmuxVaultCredentialNative]::CredRead("winsmux:$Name", [WinsmuxVaultCredentialNative]::CRED_TYPE_GENERIC, 0, [ref]$credPtr)
    if (-not $ok) {
        $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errCode -eq 1168) {
            Stop-WithError 'credential no longer exists'
        }
        Stop-WithError "CredRead failed (error $errCode)"
    }

    try {
        $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [Type][WinsmuxVaultCredentialNative+CREDENTIAL])
        if ($cred.CredentialBlobSize -le 0) {
            return ''
        }
        $bytes = New-Object byte[] $cred.CredentialBlobSize
        [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
        return [System.Text.Encoding]::Unicode.GetString($bytes)
    } finally {
        [WinsmuxVaultCredentialNative]::CredFree($credPtr) | Out-Null
    }
}

function Invoke-WinsmuxCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $global:LASTEXITCODE = 0
    try {
        $output = Invoke-WinsmuxBridgeCommand -WinsmuxBin 'winsmux' -Arguments $Arguments 2>&1
    } catch {
        return [PSCustomObject]@{
            Success  = $false
            ExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { $LASTEXITCODE }
            Output   = $_.Exception.Message
        }
    }

    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    return [PSCustomObject]@{
        Success  = ($exitCode -eq 0)
        ExitCode = $exitCode
        Output   = ($output | Out-String).Trim()
    }
}

function ConvertTo-WinsmuxConfigString {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Get-WinsmuxSessionNameForPane {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    $result = Invoke-WinsmuxCommand -Arguments @('display-message', '-p', '-t', $PaneId, '#{session_name}')
    if (-not $result.Success) {
        Stop-WithError "Unable to resolve the winsmux session for pane $PaneId."
    }

    $sessionName = $result.Output.Trim()
    if ([string]::IsNullOrWhiteSpace($sessionName)) {
        Stop-WithError "winsmux returned an empty session name for pane $PaneId."
    }

    return $sessionName
}

function Invoke-WinsmuxSourceFile {
    param(
        [Parameter(Mandatory = $true)][string[]]$Commands,
        [Parameter(Mandatory = $true)][string[]]$CredentialNames
    )

    $ackName = $null
    $ackNameAttemptLimit = 8
    for ($attempt = 0; $attempt -lt $ackNameAttemptLimit; $attempt++) {
        $candidate = 'WINSMUX_VAULT_INJECT_ACK_' + [guid]::NewGuid().ToString('N')
        $collides = $false
        foreach ($credentialName in @($CredentialNames)) {
            if ([string]$credentialName -ceq $candidate) {
                $collides = $true
                break
            }
        }
        if (-not $collides) {
            $ackName = $candidate
            break
        }
    }
    if ([string]::IsNullOrEmpty($ackName)) {
        return [PSCustomObject]@{
            Success  = $false
            ExitCode = 1
            Output   = ''
        }
    }

    $ackValue = [guid]::NewGuid().ToString('N')
    $expectedAck = $ackName + '=' + $ackValue
    $tempConf = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-src-' + [guid]::NewGuid().ToString('N') + '.conf')
    $stream = $null
    $ownedTemp = $false
    $sourceResult = $null
    $sourceSucceeded = $false
    $sourceExitCode = 1
    $ackObserved = $false
    $ackCleanupSucceeded = $false
    $operationFailed = $false
    try {
        try {
            $FileSecurity = New-Object System.Security.AccessControl.FileSecurity
            $FileSecurity.SetAccessRuleProtection($true, $false)
            $FileSecurity.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                [Security.Principal.WindowsIdentity]::GetCurrent().User,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow
            )))
            try {
                $stream = New-Object System.IO.FileStream($tempConf, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::None, $FileSecurity)
                $ownedTemp = $true
            } catch {
                if (Test-Path -LiteralPath $tempConf) {
                    throw
                }
                $stream = [System.IO.FileSystemAclExtensions]::Create((New-Object System.IO.FileInfo($tempConf)), [System.IO.FileMode]::CreateNew, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::None, $FileSecurity)
                $ownedTemp = $true
            }
            $utf8 = New-Object System.Text.UTF8Encoding $false
            $sourced = @($Commands) + @('set-environment ' + $ackName + ' ' + $ackValue)
            $bytes = $utf8.GetBytes(($sourced -join [Environment]::NewLine))
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Dispose()
            $stream = $null
            $sourceResult = Invoke-WinsmuxCommand -Arguments @('source-file', $tempConf)
            $sourceSucceeded = [bool]$sourceResult.Success
            $sourceExitCode = if ($null -eq $sourceResult.ExitCode) { 1 } else { [int]$sourceResult.ExitCode }

            $deadline = [datetime]::UtcNow.AddSeconds(5)
            do {
                $shown = Invoke-WinsmuxCommand -Arguments @('show-environment', $ackName)
                $text = [string]$shown.Output
                if ($shown.Success -and $text.Trim() -ceq $expectedAck) {
                    $ackObserved = $true
                    break
                }
                if (-not $sourceSucceeded) {
                    break
                }
                Start-Sleep -Milliseconds 50
            } while ([datetime]::UtcNow -lt $deadline)
        } catch {
            $operationFailed = $true
            if (-not $ackObserved) {
                try {
                    $shown = Invoke-WinsmuxCommand -Arguments @('show-environment', $ackName)
                    $text = [string]$shown.Output
                    if ($shown.Success -and $text.Trim() -ceq $expectedAck) {
                        $ackObserved = $true
                    }
                } catch { }
            }
        }

        try {
            $shown = Invoke-WinsmuxCommand -Arguments @('show-environment', $ackName)
            $text = [string]$shown.Output
            if ($shown.Success -and $text.Trim() -ceq $expectedAck) {
                $ackObserved = $true
                $cleanupResult = Invoke-WinsmuxCommand -Arguments @('set-environment', '-u', $ackName)
                $ackCleanupSucceeded = [bool]$cleanupResult.Success
            } else {
                $ackCleanupSucceeded = $false
            }
        } catch {
            $ackCleanupSucceeded = $false
        }

        $success = (-not $operationFailed) -and $sourceSucceeded -and $ackObserved -and $ackCleanupSucceeded
        return [PSCustomObject]@{
            Success  = $success
            ExitCode = if ($success) { $sourceExitCode } else { 1 }
            Output   = if ($null -ne $sourceResult) { [string]$sourceResult.Output } else { '' }
        }
    } finally {
        if ($null -ne $stream) {
            try { $stream.Dispose() } catch { }
        }
        $ackValue = $null
        $expectedAck = $null
        if ($ownedTemp) {
            Remove-Item -LiteralPath $tempConf -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-VaultInject {
    if (-not $Target) { Stop-WithError "usage: winsmux vault inject <pane>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId
    $projectDir = (Get-Location).Path
    $initialRuntime = Assert-WinsmuxTargetRuntimeWriteAllowed `
        -PaneId $paneId -CurrentProjectDir $projectDir -Operation dispatch
    Assert-ReadMark $paneId
    try {
        $credentialNames = @(Get-WinsmuxCredentialTargetNames)
        if ($credentialNames.Count -eq 0) {
            Write-Output "no credentials to inject"
            return
        }

        $sessionName = Get-WinsmuxSessionNameForPane -PaneId $paneId
        $injected = 0
        foreach ($envName in $credentialNames) {
            Assert-WinsmuxTargetRuntimeWriteAllowed `
                -PaneId $paneId -CurrentProjectDir $projectDir -Operation dispatch `
                -ExpectedGenerationId ([string]$initialRuntime.GenerationId) | Out-Null
            $value = [string](Get-WinsmuxVaultCredentialValue -Name ([string]$envName))
            try {
                $command = 'set-environment ' + [string]$envName + ' ' + $value
                Assert-WinsmuxTargetRuntimeWriteAllowed `
                    -PaneId $paneId -CurrentProjectDir $projectDir -Operation dispatch `
                    -ExpectedGenerationId ([string]$initialRuntime.GenerationId) | Out-Null
                $sourceResult = Invoke-WinsmuxSourceFile -Commands @($command) -CredentialNames $credentialNames
                if (-not $sourceResult.Success) {
                    Stop-WithError "winsmux source-file failed while injecting credentials into $paneId (session $sessionName)."
                }
                $injected++
            } finally {
                $value = $null
                $command = $null
                $sourceResult = $null
            }
        }

        Write-Output "injected $injected credential(s) into $paneId"
    } finally {
        Assert-WinsmuxTargetRuntimeWriteAllowed `
            -PaneId $paneId -CurrentProjectDir $projectDir -Operation dispatch `
            -ExpectedGenerationId ([string]$initialRuntime.GenerationId) | Out-Null
        Clear-ReadMark $paneId
    }
}
