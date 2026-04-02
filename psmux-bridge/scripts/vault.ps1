<#
.SYNOPSIS
Vault commands for psmux-bridge.

.DESCRIPTION
Dot-source this script to load the vault helpers into the current script scope:

    . "$PSScriptRoot/vault.ps1"

This file intentionally keeps the original function names and script-scope behavior.
The commands expect the caller to provide the surrounding bridge context, including
`$Target`, `$Rest`, `Stop-WithError`, `Resolve-Target`, `Confirm-Target`,
`Assert-ReadMark`, and `Clear-ReadMark`.
#>

if (-not ('WinCred' -as [type])) {
    # --- Windows Credential Manager P/Invoke ---
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class WinCred {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool CredFree(IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredEnumerate(string filter, uint flags, out int count, out IntPtr credentials);

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

function Invoke-VaultSet {
    $key = $Target
    $value = if ($Rest) { $Rest -join ' ' } else { '' }
    if (-not $key) { Stop-WithError "usage: psmux-bridge vault set <key> [value]" }
    if (-not $value) {
        $secure = Read-Host -AsSecureString "Enter value for '$key'"
        $value = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    }

    $credTarget = "winsmux:$key"
    $valueBytes = [System.Text.Encoding]::Unicode.GetBytes($value)
    $blobPtr = [Runtime.InteropServices.Marshal]::AllocHGlobal($valueBytes.Length)
    [Runtime.InteropServices.Marshal]::Copy($valueBytes, 0, $blobPtr, $valueBytes.Length)

    $cred = New-Object WinCred+CREDENTIAL
    $cred.Type = [WinCred]::CRED_TYPE_GENERIC
    $cred.TargetName = $credTarget
    $cred.UserName = "winsmux"
    $cred.CredentialBlobSize = $valueBytes.Length
    $cred.CredentialBlob = $blobPtr
    $cred.Persist = [WinCred]::CRED_PERSIST_LOCAL_MACHINE

    try {
        $ok = [WinCred]::CredWrite([ref]$cred, 0)
        if (-not $ok) {
            $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Stop-WithError "CredWrite failed (error $errCode)"
        }
        Write-Host "Stored credential: $key"
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($blobPtr)
    }
}

function Invoke-VaultGet {
    $key = $Target
    if (-not $key) { Stop-WithError "usage: psmux-bridge vault get <key>" }

    $credTarget = "winsmux:$key"
    $credPtr = [IntPtr]::Zero

    $ok = [WinCred]::CredRead($credTarget, [WinCred]::CRED_TYPE_GENERIC, 0, [ref]$credPtr)
    if (-not $ok) {
        $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errCode -eq 1168) {
            Stop-WithError "credential not found: $key"
        }
        Stop-WithError "CredRead failed (error $errCode)"
    }

    try {
        $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [Type][WinCred+CREDENTIAL])
        if ($cred.CredentialBlobSize -gt 0) {
            $bytes = New-Object byte[] $cred.CredentialBlobSize
            [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
            $value = [System.Text.Encoding]::Unicode.GetString($bytes)
            Write-Output $value
        }
    } finally {
        [WinCred]::CredFree($credPtr) | Out-Null
    }
}

function Invoke-VaultList {
    $filter = "winsmux:*"
    $count = 0
    $credsPtr = [IntPtr]::Zero

    $ok = [WinCred]::CredEnumerate($filter, 0, [ref]$count, [ref]$credsPtr)
    if (-not $ok) {
        $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errCode -eq 1168) {
            Write-Output "(no credentials stored)"
            return
        }
        Stop-WithError "CredEnumerate failed (error $errCode)"
    }

    try {
        $ptrSize = [Runtime.InteropServices.Marshal]::SizeOf([Type][IntPtr])
        for ($i = 0; $i -lt $count; $i++) {
            $entryPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($credsPtr, $i * $ptrSize)
            $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($entryPtr, [Type][WinCred+CREDENTIAL])
            $name = $cred.TargetName -replace '^winsmux:', ''
            Write-Output $name
        }
    } finally {
        [WinCred]::CredFree($credsPtr) | Out-Null
    }
}

function Invoke-VaultInject {
    if (-not $Target) { Stop-WithError "usage: psmux-bridge vault inject <pane>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId
    Assert-ReadMark $paneId

    # Enumerate all winsmux:* credentials
    $filter = "winsmux:*"
    $count = 0
    $credsPtr = [IntPtr]::Zero

    $ok = [WinCred]::CredEnumerate($filter, 0, [ref]$count, [ref]$credsPtr)
    if (-not $ok) {
        $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errCode -eq 1168) {
            Write-Output "no credentials to inject"
            return
        }
        Stop-WithError "CredEnumerate failed (error $errCode)"
    }

    $injected = 0
    try {
        $ptrSize = [Runtime.InteropServices.Marshal]::SizeOf([Type][IntPtr])
        for ($i = 0; $i -lt $count; $i++) {
            $entryPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($credsPtr, $i * $ptrSize)
            $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($entryPtr, [Type][WinCred+CREDENTIAL])
            $envName = $cred.TargetName -replace '^winsmux:', ''

            $value = ''
            if ($cred.CredentialBlobSize -gt 0) {
                $bytes = New-Object byte[] $cred.CredentialBlobSize
                [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
                $value = [System.Text.Encoding]::Unicode.GetString($bytes)
            }

            # Escape single quotes in value for safe injection
            $escapedValue = $value -replace "'", "''"
            $setCmd = "`$env:$envName = '$escapedValue'"
            & psmux send-keys -t $paneId -l -- "$setCmd"
            & psmux send-keys -t $paneId Enter
            Start-Sleep -Milliseconds 100
            $injected++
        }
    } finally {
        [WinCred]::CredFree($credsPtr) | Out-Null
    }

    Clear-ReadMark $paneId
    Write-Output "injected $injected credential(s) into $paneId"
}
