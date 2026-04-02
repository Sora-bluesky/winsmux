$script:RoleGateScript = Join-Path $PSScriptRoot '..\psmux-bridge\scripts\role-gate.ps1'
$script:AllRoles = @('Commander', 'Builder', 'Researcher', 'Reviewer')

function psmux {
    throw "psmux should be mocked in tests: $($args -join ' ')"
}

function Invoke-CommandAction {
    param(
        [Parameter(Mandatory)][string]$Command,
        [AllowNull()][string]$TargetPane,
        [string[]]$Arguments = @()
    )

    throw "Invoke-CommandAction should be mocked for $Command"
}

function Set-TestWinsmuxRole {
    param([AllowNull()][string]$Role)

    if ($null -eq $Role) {
        Remove-Item Env:WINSMUX_ROLE -ErrorAction SilentlyContinue
        return
    }

    $env:WINSMUX_ROLE = $Role
}

function Set-TestLabels {
    param([hashtable]$Labels)

    $dir = Split-Path $script:RoleGateLabelsFile -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $Labels | ConvertTo-Json | Set-Content -Path $script:RoleGateLabelsFile -Encoding UTF8
}

function Invoke-GateEnforcedCommand {
    param(
        [AllowNull()][string]$Role,
        [Parameter(Mandatory)][string]$Command,
        [AllowNull()][string]$TargetPane,
        [string[]]$Arguments = @()
    )

    Set-TestWinsmuxRole -Role $Role

    if ([string]::IsNullOrWhiteSpace($env:WINSMUX_ROLE)) {
        throw 'WINSMUX_ROLE not set'
    }

    $canonicalRole = ConvertTo-CanonicalWinsmuxRole $env:WINSMUX_ROLE
    if ($null -eq $canonicalRole) {
        throw "Invalid WINSMUX_ROLE: $($env:WINSMUX_ROLE)"
    }

    $allowed = (& { Assert-Role -Command $Command -TargetPane $TargetPane }) 2>$null
    if (-not $allowed) {
        throw "DENIED: [$canonicalRole] cannot execute [$Command]"
    }

    return Invoke-CommandAction -Command $Command -TargetPane $TargetPane -Arguments $Arguments
}

. $script:RoleGateScript

Describe 'integration gate enforcement' {
    BeforeEach {
        $script:OriginalWinsmuxRole = $env:WINSMUX_ROLE
        $script:OriginalWinsmuxPaneId = $env:WINSMUX_PANE_ID
        $script:OriginalAppData = $env:APPDATA

        $env:WINSMUX_PANE_ID = '%1'
        $env:APPDATA = Join-Path $TestDrive 'appdata'
        $script:RoleGateLabelsFile = Join-Path $env:APPDATA 'winsmux\labels.json'

        Set-TestLabels -Labels @{
            builder    = '%1'
            reviewer   = '%3'
            researcher = '%5'
            commander  = '%9'
        }

        Mock psmux {
            switch ($args[0]) {
                'display-message' {
                    if ($args[-1] -eq '#{pane_title}') {
                        switch ($args[3]) {
                            '%1' { return 'Builder-1' }
                            '%3' { return 'Reviewer-1' }
                            '%5' { return 'Researcher-1' }
                            '%9' { return 'Commander-1' }
                            default { return '' }
                        }
                    }

                    return ''
                }
                'capture-pane' {
                    return 'captured pane output'
                }
                'list-panes' {
                    return @('%1', '%3', '%5', '%9')
                }
                'send-keys' {
                    return
                }
                'source-file' {
                    return
                }
                default {
                    throw "unexpected psmux command: $($args -join ' ')"
                }
            }
        }

        Mock Invoke-CommandAction {
            param(
                [Parameter(Mandatory)][string]$Command,
                [AllowNull()][string]$TargetPane,
                [string[]]$Arguments = @()
            )

            switch ($Command) {
                'read' {
                    return (& psmux @('capture-pane', '-t', $TargetPane, '-p', '-J', '-S', '-20') | Out-String).Trim()
                }
                'send' {
                    & psmux @('send-keys', '-t', $TargetPane, '-l', '--', ($Arguments -join ' '))
                    & psmux @('send-keys', '-t', $TargetPane, 'Enter')
                    return "sent to $TargetPane"
                }
                'vault' {
                    & psmux @('source-file', 'vault.ps1')
                    return 'vault ok'
                }
                'health-check' {
                    return (& psmux @('list-panes', '-a', '-F', '#{pane_id}') | Out-String).Trim()
                }
                'list' {
                    return (& psmux @('list-panes', '-a', '-F', '#{pane_id}') | Out-String).Trim()
                }
                'version' {
                    return 'psmux-bridge 0.9.6'
                }
                default {
                    return "$Command ok"
                }
            }
        }
    }

    AfterEach {
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

        if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
            $script:RoleGateLabelsFile = Join-Path $env:APPDATA 'winsmux\labels.json'
        }
    }

    Context 'deny paths' {
        It 'test_gate_builder_vault_denied' {
            { Invoke-GateEnforcedCommand -Role 'Builder' -Command 'vault' } | Should Throw 'DENIED'
            Assert-MockCalled Invoke-CommandAction -Times 0 -Exactly -Scope It
        }

        It 'test_gate_builder_health_check_denied' {
            { Invoke-GateEnforcedCommand -Role 'Builder' -Command 'health-check' } | Should Throw 'DENIED'
            Assert-MockCalled Invoke-CommandAction -Times 0 -Exactly -Scope It
        }

        It 'test_gate_builder_dispatch_denied' {
            { Invoke-GateEnforcedCommand -Role 'Builder' -Command 'dispatch' } | Should Throw 'DENIED'
            Assert-MockCalled Invoke-CommandAction -Times 0 -Exactly -Scope It
        }

        It 'test_gate_builder_read_other_pane_denied' {
            { Invoke-GateEnforcedCommand -Role 'Builder' -Command 'read' -TargetPane 'reviewer' } | Should Throw 'DENIED'
            Assert-MockCalled Invoke-CommandAction -Times 0 -Exactly -Scope It
        }

        It 'test_gate_researcher_vault_denied' {
            { Invoke-GateEnforcedCommand -Role 'Researcher' -Command 'vault' } | Should Throw 'DENIED'
            Assert-MockCalled Invoke-CommandAction -Times 0 -Exactly -Scope It
        }

        It 'test_gate_reviewer_send_non_commander_denied' {
            { Invoke-GateEnforcedCommand -Role 'Reviewer' -Command 'send' -TargetPane 'reviewer' -Arguments @('status') } | Should Throw 'DENIED'
            Assert-MockCalled Invoke-CommandAction -Times 0 -Exactly -Scope It
        }

        It 'test_gate_missing_role_denied' {
            { Invoke-GateEnforcedCommand -Role $null -Command 'read' -TargetPane 'builder' } | Should Throw 'WINSMUX_ROLE not set'
            Assert-MockCalled Invoke-CommandAction -Times 0 -Exactly -Scope It
        }

        It 'test_gate_unknown_role_denied' {
            { Invoke-GateEnforcedCommand -Role 'admin' -Command 'read' -TargetPane 'builder' } | Should Throw 'Invalid WINSMUX_ROLE'
            Assert-MockCalled Invoke-CommandAction -Times 0 -Exactly -Scope It
        }

        It 'test_gate_unknown_command_denied' {
            { Invoke-GateEnforcedCommand -Role 'Commander' -Command 'foobar' -TargetPane 'builder' } | Should Throw 'DENIED'
            Assert-MockCalled Invoke-CommandAction -Times 0 -Exactly -Scope It
        }
    }

    Context 'allow paths' {
        It 'test_gate_commander_read_any_pane_allowed' {
            $result = Invoke-GateEnforcedCommand -Role 'Commander' -Command 'read' -TargetPane 'reviewer'

            $result | Should Be 'captured pane output'
            Assert-MockCalled Invoke-CommandAction -Times 1 -Exactly -Scope It
            Assert-MockCalled psmux -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'capture-pane' } -Scope It
        }

        It 'test_gate_commander_send_any_pane_allowed' {
            $result = Invoke-GateEnforcedCommand -Role 'Commander' -Command 'send' -TargetPane 'reviewer' -Arguments @('run tests')

            $result | Should Be 'sent to reviewer'
            Assert-MockCalled Invoke-CommandAction -Times 1 -Exactly -Scope It
            Assert-MockCalled psmux -Times 2 -Exactly -ParameterFilter { $args[0] -eq 'send-keys' } -Scope It
        }

        It 'test_gate_commander_vault_allowed' {
            $result = Invoke-GateEnforcedCommand -Role 'Commander' -Command 'vault'

            $result | Should Be 'vault ok'
            Assert-MockCalled Invoke-CommandAction -Times 1 -Exactly -Scope It
            Assert-MockCalled psmux -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'source-file' } -Scope It
        }

        It 'test_gate_builder_read_own_pane_allowed' {
            $result = Invoke-GateEnforcedCommand -Role 'Builder' -Command 'read' -TargetPane 'builder'

            $result | Should Be 'captured pane output'
            Assert-MockCalled Invoke-CommandAction -Times 1 -Exactly -Scope It
            Assert-MockCalled psmux -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'capture-pane' } -Scope It
        }

        It 'test_gate_builder_send_commander_allowed' {
            $result = Invoke-GateEnforcedCommand -Role 'Builder' -Command 'send' -TargetPane 'commander' -Arguments @('done')

            $result | Should Be 'sent to commander'
            Assert-MockCalled Invoke-CommandAction -Times 1 -Exactly -Scope It
            Assert-MockCalled psmux -Times 2 -Exactly -ParameterFilter { $args[0] -eq 'send-keys' } -Scope It
        }

        foreach ($role in $script:AllRoles) {
            $currentRole = $role

            It "test_gate_${currentRole}_version_allowed" {
                $result = Invoke-GateEnforcedCommand -Role $currentRole -Command 'version'

                $result | Should Be 'psmux-bridge 0.9.6'
                Assert-MockCalled Invoke-CommandAction -Times 1 -Exactly -Scope It
                Assert-MockCalled psmux -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'capture-pane' -or $args[0] -eq 'send-keys' -or $args[0] -eq 'list-panes' -or $args[0] -eq 'source-file' } -Scope It
            }
        }

        foreach ($role in $script:AllRoles) {
            $currentRole = $role

            It "test_gate_${currentRole}_list_allowed" {
                $result = Invoke-GateEnforcedCommand -Role $currentRole -Command 'list'

                $result | Should Match '%1'
                Assert-MockCalled Invoke-CommandAction -Times 1 -Exactly -Scope It
                Assert-MockCalled psmux -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'list-panes' } -Scope It
            }
        }
    }

    Context 'fail close' {
        It 'test_gate_fake_command_not_in_switch_denied' {
            { Invoke-GateEnforcedCommand -Role 'Commander' -Command 'future-command' -TargetPane 'builder' } | Should Throw 'DENIED'
            Assert-MockCalled Invoke-CommandAction -Times 0 -Exactly -Scope It
        }

        It 'test_gate_default_branch_returns_false' {
            Set-TestWinsmuxRole -Role 'Commander'

            $result = (& { Assert-Role -Command 'future-command' -TargetPane 'builder' }) 2>$null

            $result | Should Be $false
        }
    }
}
