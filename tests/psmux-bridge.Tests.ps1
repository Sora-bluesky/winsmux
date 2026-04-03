$ErrorActionPreference = 'Stop'

Describe 'Assert-Role' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'psmux-bridge\scripts\role-gate.ps1')
    }

    BeforeEach {
        $script:originalRole = $env:WINSMUX_ROLE
        $script:originalPaneId = $env:WINSMUX_PANE_ID
        $script:originalRoleMap = $env:WINSMUX_ROLE_MAP
        $script:originalRoleGateLabelsFile = $script:RoleGateLabelsFile
        Mock Deny-RoleCommand { return $false }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-role-gate-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $labelsPath = Join-Path $tempRoot 'labels.json'
        @{
            self       = 'pane-self'
            commander  = 'pane-commander'
            builder    = 'pane-builder'
            researcher = 'pane-researcher'
            reviewer   = 'pane-reviewer'
        } | ConvertTo-Json | Set-Content -Path $labelsPath -Encoding UTF8

        $script:roleGateTempRoot = $tempRoot
        $script:RoleGateLabelsFile = $labelsPath
        $env:WINSMUX_PANE_ID = 'pane-self'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Commander","pane-commander":"Commander","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'
    }

    AfterEach {
        $env:WINSMUX_ROLE = $script:originalRole
        $env:WINSMUX_PANE_ID = $script:originalPaneId
        $env:WINSMUX_ROLE_MAP = $script:originalRoleMap
        $script:RoleGateLabelsFile = $script:originalRoleGateLabelsFile

        if ($script:roleGateTempRoot -and (Test-Path $script:roleGateTempRoot)) {
            Remove-Item -Path $script:roleGateTempRoot -Recurse -Force
        }
    }

    It 'allows Commander to send anywhere and denies typing into another pane' {
        $env:WINSMUX_ROLE = 'Commander'

        (Assert-Role -Command 'send' -TargetPane 'reviewer') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $true
        (Assert-Role -Command 'type' -TargetPane 'reviewer') | Should -Be $false
    }

    It 'allows Builder to message Commander and denies sending to peers' {
        $env:WINSMUX_ROLE = 'Builder'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Builder","pane-commander":"Commander","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'send' -TargetPane 'commander') | Should -Be $true
        (Assert-Role -Command 'type' -TargetPane 'self') | Should -Be $true
        (Assert-Role -Command 'send' -TargetPane 'reviewer') | Should -Be $false
        (Assert-Role -Command 'read' -TargetPane 'reviewer') | Should -Be $false
    }

    It 'allows Researcher to message Commander and denies orchestration commands' {
        $env:WINSMUX_ROLE = 'Researcher'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Researcher","pane-commander":"Commander","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'commander') | Should -Be $true
        (Assert-Role -Command 'read' -TargetPane 'self') | Should -Be $true
        (Assert-Role -Command 'signal') | Should -Be $false
        (Assert-Role -Command 'wait') | Should -Be $false
    }

    It 'allows Reviewer to message Commander and denies privileged commands' {
        $env:WINSMUX_ROLE = 'Reviewer'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Reviewer","pane-commander":"Commander","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'commander') | Should -Be $true
        (Assert-Role -Command 'list') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $false
        (Assert-Role -Command 'focus') | Should -Be $false
    }
}

Describe 'Get-BridgeSettings' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'psmux-bridge\scripts\settings.ps1')
    }

    BeforeEach {
        $script:settingsTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-settings-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:settingsTempRoot -Force | Out-Null
        Push-Location $script:settingsTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:settingsTempRoot -and (Test-Path $script:settingsTempRoot)) {
            Remove-Item -Path $script:settingsTempRoot -Recurse -Force
        }
    }

    It 'returns built-in defaults when no global or project settings exist' {
        Mock Get-PsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $settings.agent | Should -Be 'codex'
        $settings.model | Should -Be 'gpt-5.4'
        $settings.builders | Should -Be 4
        $settings.researchers | Should -Be 1
        $settings.reviewers | Should -Be 1
        $settings.terminal | Should -Be 'background'
        $settings.vault_keys | Should -Be @('GH_TOKEN')
    }

    It 'applies global overrides and lets project settings take precedence per key' {
        @'
agent: claude
reviewers: 3
vault-keys:
  - GH_TOKEN
  - OPENAI_API_KEY
terminal: tab
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.psmux-bridge.yaml') -Encoding UTF8

        Mock Get-PsmuxOption {
            param($Name, $Default)

            switch ($Name) {
                '@bridge-agent' { 'gemini' }
                '@bridge-model' { 'gpt-5.5-mini' }
                '@bridge-builders' { '7' }
                '@bridge-researchers' { '2' }
                '@bridge-reviewers' { '5' }
                '@bridge-vault-keys' { 'GH_TOKEN,CLAUDE_CODE_OAUTH_TOKEN' }
                '@bridge-terminal' { 'window' }
                default { $null }
            }
        }

        $settings = Get-BridgeSettings

        $settings.agent | Should -Be 'claude'
        $settings.model | Should -Be 'gpt-5.5-mini'
        $settings.builders | Should -Be 7
        $settings.researchers | Should -Be 2
        $settings.reviewers | Should -Be 3
        $settings.terminal | Should -Be 'tab'
        $settings.vault_keys | Should -Be @('GH_TOKEN', 'OPENAI_API_KEY')
    }
}

Describe 'Vault helpers' {
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

        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'psmux-bridge\scripts\vault.ps1')
    }

    BeforeEach {
        $script:originalTarget = $script:Target
        $script:originalRest = $script:Rest
        $script:originalPrefix = $script:WinCredTargetPrefix

        $script:Target = $null
        $script:Rest = @()
        $script:WinCredTargetPrefix = 'winsmux-test:{0}:' -f [guid]::NewGuid().ToString('N')
    }

    AfterEach {
        $testPrefix = $script:WinCredTargetPrefix
        $filter = '{0}*' -f $testPrefix
        $count = 0
        $credsPtr = [IntPtr]::Zero

        $ok = [WinCred]::CredEnumerate($filter, 0, [ref]$count, [ref]$credsPtr)
        if ($ok) {
            try {
                $ptrSize = [Runtime.InteropServices.Marshal]::SizeOf([Type][IntPtr])
                for ($i = 0; $i -lt $count; $i++) {
                    $entryPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($credsPtr, $i * $ptrSize)
                    $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($entryPtr, [Type][WinCred+CREDENTIAL])
                    [WinCred]::CredDelete($cred.TargetName, [WinCred]::CRED_TYPE_GENERIC, 0) | Out-Null
                }
            } finally {
                [WinCred]::CredFree($credsPtr) | Out-Null
            }
        }

        $script:Target = $script:originalTarget
        $script:Rest = $script:originalRest
        $script:WinCredTargetPrefix = $script:originalPrefix
    }

    It 'stores, retrieves, and lists credentials inside the test prefix only' {
        $script:Target = 'alpha'
        $script:Rest = @('one')
        Invoke-VaultSet | Out-Null

        $script:Target = 'beta'
        $script:Rest = @('two')
        Invoke-VaultSet | Out-Null

        $script:Target = 'alpha'
        $script:Rest = @()
        (Invoke-VaultGet) | Should -Be 'one'

        $listedKeys = @(Invoke-VaultList | Sort-Object)
        $listedKeys | Should -Contain 'alpha'
        $listedKeys | Should -Contain 'beta'
    }
}
