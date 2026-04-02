$script:BridgeScript = Join-Path $PSScriptRoot '..\scripts\psmux-bridge.ps1'
$script:RoleGateScript = Join-Path $PSScriptRoot '..\psmux-bridge\scripts\role-gate.ps1'
$script:SettingsScript = Join-Path $PSScriptRoot '..\psmux-bridge\scripts\settings.ps1'
$script:VaultScript = Join-Path $PSScriptRoot '..\psmux-bridge\scripts\vault.ps1'
$script:VersionFile = Join-Path $PSScriptRoot '..\VERSION'

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

if (-not ('WinCred' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

public static class WinCred {
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

    private static readonly Dictionary<string, string> Store = new Dictionary<string, string>(StringComparer.Ordinal);

    private static string ReadBlob(CREDENTIAL credential) {
        if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize <= 0) {
            return string.Empty;
        }

        var bytes = new byte[credential.CredentialBlobSize];
        Marshal.Copy(credential.CredentialBlob, bytes, 0, credential.CredentialBlobSize);
        return Encoding.Unicode.GetString(bytes);
    }

    private static IntPtr BuildCredentialPointer(string target, string value) {
        var bytes = Encoding.Unicode.GetBytes(value ?? string.Empty);
        var blobPtr = Marshal.AllocHGlobal(bytes.Length);
        if (bytes.Length > 0) {
            Marshal.Copy(bytes, 0, blobPtr, bytes.Length);
        }

        var credential = new CREDENTIAL {
            Type = CRED_TYPE_GENERIC,
            TargetName = target,
            UserName = "winsmux",
            CredentialBlobSize = bytes.Length,
            CredentialBlob = blobPtr,
            Persist = CRED_PERSIST_LOCAL_MACHINE
        };

        var credPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(CREDENTIAL)));
        Marshal.StructureToPtr(credential, credPtr, false);
        return credPtr;
    }

    public static bool CredWrite(ref CREDENTIAL credential, uint flags) {
        Store[credential.TargetName] = ReadBlob(credential);
        Marshal.SetLastPInvokeError(0);
        return true;
    }

    public static bool CredRead(string target, uint type, uint flags, out IntPtr credential) {
        if (!Store.TryGetValue(target, out var value)) {
            credential = IntPtr.Zero;
            Marshal.SetLastPInvokeError(1168);
            return false;
        }

        credential = BuildCredentialPointer(target, value);
        Marshal.SetLastPInvokeError(0);
        return true;
    }

    public static bool CredEnumerate(string filter, uint flags, out int count, out IntPtr credentials) {
        var matches = Store
            .Where(entry => entry.Key.StartsWith("winsmux:", StringComparison.Ordinal))
            .OrderBy(entry => entry.Key, StringComparer.Ordinal)
            .ToArray();

        if (matches.Length == 0) {
            count = 0;
            credentials = IntPtr.Zero;
            Marshal.SetLastPInvokeError(1168);
            return false;
        }

        count = matches.Length;
        credentials = Marshal.AllocHGlobal(IntPtr.Size * count);

        for (var i = 0; i < matches.Length; i++) {
            var credPtr = BuildCredentialPointer(matches[i].Key, matches[i].Value);
            Marshal.WriteIntPtr(credentials, i * IntPtr.Size, credPtr);
        }

        Marshal.SetLastPInvokeError(0);
        return true;
    }

    public static bool CredFree(IntPtr credential) {
        Marshal.SetLastPInvokeError(0);
        return true;
    }

    public static void Reset() {
        Store.Clear();
    }

    public static string GetValue(string target) {
        return Store.TryGetValue(target, out var value) ? value : null;
    }
}
'@ -ErrorAction Stop
}

. $script:RoleGateScript
. $script:SettingsScript
. $script:VaultScript

function Invoke-RoleGate {
    param(
        [string]$Role,
        [string]$Command,
        [string]$TargetPane
    )

    if ($null -eq $Role) {
        Remove-Item Env:WINSMUX_ROLE -ErrorAction SilentlyContinue
    } else {
        $env:WINSMUX_ROLE = $Role
    }

    return (& { Assert-Role -Command $Command -TargetPane $TargetPane }) 2>$null
}

Describe 'psmux-bridge' {
    BeforeEach {
        $script:OriginalWinsmuxRole = $env:WINSMUX_ROLE
        $script:OriginalWinsmuxPaneId = $env:WINSMUX_PANE_ID
        $script:OriginalAppData = $env:APPDATA
        $script:OriginalLocation = Get-Location

        $env:WINSMUX_PANE_ID = '%1'
        $env:APPDATA = Join-Path $TestDrive 'appdata'
        New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null

        [WinCred]::Reset()
        $script:Target = $null
        $script:Rest = @()
    }

    AfterEach {
        Set-Location $script:OriginalLocation

        if ($null -eq $script:OriginalWinsmuxRole) {
            Remove-Item Env:WINSMUX_ROLE -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_ROLE = $script:OriginalWinsmuxRole
        }

        if ($null -eq $script:OriginalWinsmuxPaneId) {
            Remove-Item Env:WINSMUX_PANE_ID -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_PANE_ID = $script:OriginalWinsmuxPaneId
        }

        if ($null -eq $script:OriginalAppData) {
            Remove-Item Env:APPDATA -ErrorAction SilentlyContinue
        } else {
            $env:APPDATA = $script:OriginalAppData
        }
    }

    Context 'Assert-Role' {
        It 'allows Commander to read other panes' {
            # Arrange
            $role = 'Commander'
            $command = 'read'
            $targetPane = '%9'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $true
        }

        It 'allows Commander to send to other panes' {
            # Arrange
            $role = 'Commander'
            $command = 'send'
            $targetPane = '%9'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $true
        }

        It 'allows Commander to run health-check' {
            # Arrange
            $role = 'Commander'
            $command = 'health-check'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command

            # Assert
            $result | Should Be $true
        }

        It 'allows Commander to use vault commands' {
            # Arrange
            $role = 'Commander'
            $command = 'vault'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command

            # Assert
            $result | Should Be $true
        }

        It 'allows Commander to watch panes' {
            # Arrange
            $role = 'Commander'
            $command = 'watch'
            $targetPane = '%9'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $true
        }

        It 'allows Commander to dispatch work' {
            # Arrange
            $role = 'Commander'
            $command = 'dispatch'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command

            # Assert
            $result | Should Be $true
        }

        It 'allows Builder to read its own pane' {
            # Arrange
            $role = 'Builder'
            $command = 'read'
            $targetPane = '%1'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $true
        }

        It 'allows Builder to send to Commander' {
            # Arrange
            $role = 'Builder'
            $command = 'send'
            $targetPane = 'Commander'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $true
        }

        It 'denies Builder from reading other panes' {
            # Arrange
            $role = 'Builder'
            $command = 'read'
            $targetPane = '%9'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $false
        }

        It 'denies Builder from using vault commands' {
            # Arrange
            $role = 'Builder'
            $command = 'vault'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command

            # Assert
            $result | Should Be $false
        }

        It 'denies Builder from dispatching work' {
            # Arrange
            $role = 'Builder'
            $command = 'dispatch'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command

            # Assert
            $result | Should Be $false
        }

        It 'allows Researcher to read its own pane' {
            # Arrange
            $role = 'Researcher'
            $command = 'read'
            $targetPane = '%1'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $true
        }

        It 'allows Researcher to send to Commander' {
            # Arrange
            $role = 'Researcher'
            $command = 'send'
            $targetPane = 'Commander'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $true
        }

        It 'denies Researcher from reading other panes' {
            # Arrange
            $role = 'Researcher'
            $command = 'read'
            $targetPane = '%9'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $false
        }

        It 'denies Researcher from using vault commands' {
            # Arrange
            $role = 'Researcher'
            $command = 'vault'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command

            # Assert
            $result | Should Be $false
        }

        It 'denies Researcher from dispatching work' {
            # Arrange
            $role = 'Researcher'
            $command = 'dispatch'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command

            # Assert
            $result | Should Be $false
        }

        It 'allows Reviewer to read its own pane' {
            # Arrange
            $role = 'Reviewer'
            $command = 'read'
            $targetPane = '%1'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $true
        }

        It 'allows Reviewer to send to Commander' {
            # Arrange
            $role = 'Reviewer'
            $command = 'send'
            $targetPane = 'Commander'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $true
        }

        It 'denies Reviewer from reading other panes' {
            # Arrange
            $role = 'Reviewer'
            $command = 'read'
            $targetPane = '%9'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $false
        }

        It 'denies Reviewer from using vault commands' {
            # Arrange
            $role = 'Reviewer'
            $command = 'vault'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command

            # Assert
            $result | Should Be $false
        }

        It 'denies Reviewer from dispatching work' {
            # Arrange
            $role = 'Reviewer'
            $command = 'dispatch'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command

            # Assert
            $result | Should Be $false
        }

        It 'denies read when WINSMUX_ROLE is unset' {
            # Arrange
            $command = 'read'
            $targetPane = '%1'

            # Act
            $result = Invoke-RoleGate -Role $null -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $false
        }

        It 'denies read when WINSMUX_ROLE is unknown' {
            # Arrange
            $role = 'admin'
            $command = 'read'
            $targetPane = '%1'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $false
        }

        It 'denies read when WINSMUX_ROLE is an empty string' {
            # Arrange
            $role = ''
            $command = 'read'
            $targetPane = '%1'

            # Act
            $result = Invoke-RoleGate -Role $role -Command $command -TargetPane $targetPane

            # Assert
            $result | Should Be $false
        }
    }

    Context 'Get-BridgeSettings' {
        BeforeEach {
            Set-Location $TestDrive
            Remove-Item -Path '.psmux-bridge.yaml' -Force -ErrorAction SilentlyContinue
        }

        It 'returns defaults when no config exists' {
            # Arrange
            Mock Get-PsmuxOption { param($Name, $Default) return $Default }

            # Act
            $settings = Get-BridgeSettings

            # Assert
            $settings.agent | Should Be 'codex'
            $settings.model | Should Be 'gpt-5.4'
            $settings.builders | Should Be 4
            $settings.researchers | Should Be 1
            $settings.reviewers | Should Be 1
            ($settings.vault_keys -join ',') | Should Be 'GH_TOKEN'
            $settings.terminal | Should Be 'background'
        }

        It 'reads scalar values from .psmux-bridge.yaml when present' {
            # Arrange
            Set-Content -Path '.psmux-bridge.yaml' -Encoding UTF8 -Value @"
agent: claude
model: sonnet
terminal: new-tab
"@
            Mock Get-PsmuxOption { param($Name, $Default) return $Default }

            # Act
            $settings = Get-BridgeSettings

            # Assert
            $settings.agent | Should Be 'claude'
            $settings.model | Should Be 'sonnet'
            $settings.terminal | Should Be 'new-tab'
        }

        It 'reads numeric values from .psmux-bridge.yaml when present' {
            # Arrange
            Set-Content -Path '.psmux-bridge.yaml' -Encoding UTF8 -Value @"
builders: 7
researchers: 2
reviewers: 3
"@
            Mock Get-PsmuxOption { param($Name, $Default) return $Default }

            # Act
            $settings = Get-BridgeSettings

            # Assert
            $settings.builders | Should Be 7
            $settings.researchers | Should Be 2
            $settings.reviewers | Should Be 3
        }

        It 'reads list values from .psmux-bridge.yaml when present' {
            # Arrange
            Set-Content -Path '.psmux-bridge.yaml' -Encoding UTF8 -Value @"
vault_keys:
  - GH_TOKEN
  - OPENAI_API_KEY
"@
            Mock Get-PsmuxOption { param($Name, $Default) return $Default }

            # Act
            $settings = Get-BridgeSettings

            # Assert
            ($settings.vault_keys -join ',') | Should Be 'GH_TOKEN,OPENAI_API_KEY'
        }

        It 'falls back to psmux options for scalar values' {
            # Arrange
            Mock Get-PsmuxOption {
                param($Name, $Default)
                switch ($Name) {
                    '@bridge-agent' { return 'cursor' }
                    '@bridge-model' { return 'gpt-5.5-mini' }
                    '@bridge-terminal' { return 'split-pane' }
                    default { return $Default }
                }
            }

            # Act
            $settings = Get-BridgeSettings

            # Assert
            $settings.agent | Should Be 'cursor'
            $settings.model | Should Be 'gpt-5.5-mini'
            $settings.terminal | Should Be 'split-pane'
        }

        It 'falls back to psmux options for list values' {
            # Arrange
            Mock Get-PsmuxOption {
                param($Name, $Default)
                if ($Name -eq '@bridge-vault-keys') {
                    return 'GH_TOKEN,OPENAI_API_KEY'
                }

                return $Default
            }

            # Act
            $settings = Get-BridgeSettings

            # Assert
            ($settings.vault_keys -join ',') | Should Be 'GH_TOKEN,OPENAI_API_KEY'
        }

        It 'uses project values before global values and defaults' {
            # Arrange
            Set-Content -Path '.psmux-bridge.yaml' -Encoding UTF8 -Value @"
agent: local-agent
builders: 9
"@
            Mock Get-PsmuxOption {
                param($Name, $Default)
                switch ($Name) {
                    '@bridge-agent' { return 'global-agent' }
                    '@bridge-builders' { return '6' }
                    default { return $Default }
                }
            }

            # Act
            $settings = Get-BridgeSettings

            # Assert
            $settings.agent | Should Be 'local-agent'
            $settings.builders | Should Be 9
        }

        It 'uses global values before defaults when project values are absent' {
            # Arrange
            Mock Get-PsmuxOption {
                param($Name, $Default)
                switch ($Name) {
                    '@bridge-researchers' { return '4' }
                    '@bridge-reviewers' { return '2' }
                    default { return $Default }
                }
            }

            # Act
            $settings = Get-BridgeSettings

            # Assert
            $settings.researchers | Should Be 4
            $settings.reviewers | Should Be 2
            $settings.builders | Should Be 4
        }
    }

    Context 'version command' {
        It 'returns version string matching VERSION file' {
            # Arrange
            $expectedVersion = (Get-Content -Path $script:VersionFile -Raw -Encoding UTF8).Trim()

            # Act
            $commandOutput = (& pwsh -NoProfile -File $script:BridgeScript version).Trim()

            # Assert
            $commandOutput | Should Be "psmux-bridge $expectedVersion"
        }

        It 'returns a semver version string' {
            # Arrange
            $semverPattern = '^psmux-bridge \d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$'

            # Act
            $commandOutput = (& pwsh -NoProfile -File $script:BridgeScript version).Trim()

            # Assert
            $commandOutput | Should Match $semverPattern
        }
    }

    Context 'Vault functions' {
        It 'VaultSet stores a credential' {
            # Arrange
            $script:Target = 'OPENAI_API_KEY'
            $script:Rest = @('secret-value')

            # Act
            Invoke-VaultSet | Out-Null
            $storedValue = [WinCred]::GetValue('winsmux:OPENAI_API_KEY')

            # Assert
            $storedValue | Should Be 'secret-value'
        }

        It 'VaultGet retrieves a stored credential' {
            # Arrange
            $script:Target = 'GH_TOKEN'
            $script:Rest = @('ghs_test_token')
            Invoke-VaultSet | Out-Null
            $script:Target = 'GH_TOKEN'
            $script:Rest = @()

            # Act
            $value = Invoke-VaultGet

            # Assert
            $value | Should Be 'ghs_test_token'
        }

        It 'VaultGet errors when the key is missing' {
            # Arrange
            $script:Target = 'MISSING_KEY'
            $script:Rest = @()

            # Act
            $action = { Invoke-VaultGet }

            # Assert
            $action | Should Throw 'credential not found: MISSING_KEY'
        }

        It 'VaultList returns empty when no credentials exist' {
            # Arrange
            $script:Target = $null
            $script:Rest = @()

            # Act
            $list = Invoke-VaultList

            # Assert
            $list | Should Be '(no credentials stored)'
        }

        It 'VaultList returns stored keys after credentials are set' {
            # Arrange
            $script:Target = 'GH_TOKEN'
            $script:Rest = @('ghs_example')
            Invoke-VaultSet | Out-Null
            $script:Target = 'OPENAI_API_KEY'
            $script:Rest = @('sk-example')
            Invoke-VaultSet | Out-Null
            $script:Target = $null
            $script:Rest = @()

            # Act
            $list = @(Invoke-VaultList)

            # Assert
            ($list -join ',') | Should Be 'GH_TOKEN,OPENAI_API_KEY'
        }

        It 'VaultInject errors when the target pane is invalid' {
            # Arrange
            $script:Target = '%99'
            $script:Rest = @()
            Mock Confirm-Target { throw 'invalid target: %99' }

            # Act
            $action = { Invoke-VaultInject }

            # Assert
            $action | Should Throw 'invalid target: %99'
        }

        It 'VaultInject prefers source-file so secrets are not passed in argv' {
            # Arrange
            $script:Target = 'GH_TOKEN'
            $script:Rest = @('ghs_example')
            Invoke-VaultSet | Out-Null
            $script:Target = 'OPENAI_API_KEY'
            $script:Rest = @('sk-example')
            Invoke-VaultSet | Out-Null
            $script:Target = '%1'
            $script:Rest = @()

            $script:PsmuxCalls = [System.Collections.Generic.List[object]]::new()
            $script:SourceFilePath = $null
            $script:SourceFileContent = $null
            $script:MarkedPane = $null
            $script:ClearedPane = $null

            Mock Resolve-Target { param($RawTarget) $RawTarget }
            Mock Confirm-Target { param($PaneId) $PaneId }
            Mock Assert-ReadMark { param($PaneId) $script:MarkedPane = $PaneId }
            Mock Clear-ReadMark { param($PaneId) $script:ClearedPane = $PaneId }

            function psmux {
                param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)

                $script:PsmuxCalls.Add([string[]]$Args) | Out-Null
                switch ($Args[0]) {
                    'display-message' {
                        'winsmux-session'
                        return
                    }
                    'source-file' {
                        $script:SourceFilePath = [string]$Args[1]
                        $script:SourceFileContent = Get-Content -Path $script:SourceFilePath -Raw -Encoding UTF8
                        return
                    }
                    default {
                        throw "unexpected psmux command: $($Args -join ' ')"
                    }
                }
            }

            try {
                # Act
                $result = Invoke-VaultInject
            } finally {
                Remove-Item Function:\psmux -ErrorAction SilentlyContinue
            }

            # Assert
            $result | Should Be 'injected 2 credential(s) into %1'
            $script:MarkedPane | Should Be '%1'
            $script:ClearedPane | Should Be '%1'
            $script:PsmuxCalls.Count | Should Be 2
            $script:PsmuxCalls[0][0] | Should Be 'display-message'
            $script:PsmuxCalls[1][0] | Should Be 'source-file'
            (($script:PsmuxCalls | ForEach-Object { $_ -join ' ' }) -join "`n") | Should Not Match 'ghs_example|sk-example'
            $script:SourceFileContent | Should Match 'set-environment -t "winsmux-session" "GH_TOKEN" "ghs_example"'
            $script:SourceFileContent | Should Match 'set-environment -t "winsmux-session" "OPENAI_API_KEY" "sk-example"'
            (Test-Path -LiteralPath $script:SourceFilePath) | Should Be $false
        }

        It 'VaultInject falls back to set-environment when source-file fails' {
            # Arrange
            $script:Target = 'GH_TOKEN'
            $script:Rest = @('ghs_example')
            Invoke-VaultSet | Out-Null
            $script:Target = '%1'
            $script:Rest = @()

            $script:PsmuxCalls = [System.Collections.Generic.List[object]]::new()

            Mock Resolve-Target { param($RawTarget) $RawTarget }
            Mock Confirm-Target { param($PaneId) $PaneId }
            function psmux {
                param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)

                $script:PsmuxCalls.Add([string[]]$Args) | Out-Null
                switch ($Args[0]) {
                    'display-message' {
                        'winsmux-session'
                        return
                    }
                    'source-file' {
                        throw 'source-file unavailable'
                    }
                    'set-environment' {
                        return
                    }
                    default {
                        throw "unexpected psmux command: $($Args -join ' ')"
                    }
                }
            }

            try {
                # Act
                $result = Invoke-VaultInject
            } finally {
                Remove-Item Function:\psmux -ErrorAction SilentlyContinue
            }

            # Assert
            $result | Should Be 'injected 1 credential(s) into %1'
            $script:PsmuxCalls.Count | Should Be 3
            $script:PsmuxCalls[0][0] | Should Be 'display-message'
            $script:PsmuxCalls[1][0] | Should Be 'source-file'
            $script:PsmuxCalls[2][0] | Should Be 'set-environment'
            $script:PsmuxCalls[2][1] | Should Be '-t'
            $script:PsmuxCalls[2][2] | Should Be 'winsmux-session'
            $script:PsmuxCalls[2][3] | Should Be 'GH_TOKEN'
            $script:PsmuxCalls[2][4] | Should Be 'ghs_example'
        }
    }
}
