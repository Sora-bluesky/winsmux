$script:RoleGateScript = Join-Path $PSScriptRoot '..\psmux-bridge\scripts\role-gate.ps1'
$script:AllRoles = @('Commander', 'Builder', 'Researcher', 'Reviewer')

function psmux {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
    throw "psmux should be mocked in tests: $($Args -join ' ')"
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

    $gateErrors = @()
    $allowed = Assert-Role -Command $Command -TargetPane $TargetPane -ErrorAction SilentlyContinue -ErrorVariable gateErrors

    if (-not $allowed) {
        $message = if ($gateErrors.Count -gt 0) {
            ($gateErrors | Select-Object -Last 1 | ForEach-Object { $_.ToString() })
        } else {
            "DENIED: [$Role] cannot execute [$Command]"
        }

        throw $message
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
            param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)

            switch ($Args[0]) {
                'display-message' {
                    if ($Args[-1] -eq '#{pane_title}') {
                        switch ($Args[3]) {
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
                    throw "unexpected psmux command: $($Args -join ' ')"
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
                    return (& psmux capture-pane -t $TargetPane -p -J -S '-20' | Out-String).Trim()
                }
                'send' {
                    & psmux send-keys -t $TargetPane -l -- ($Arguments -join ' ')
                    & psmux send-keys -t $TargetPane Enter
                    return "sent to $TargetPane"
                }
                'vault' {
                    & psmux source-file 'vault.ps1'
                    return 'vault ok'
                }
                'health-check' {
                    return (& psmux list-panes -a -F '#{pane_id}' | Out-String).Trim()
                }
                'list' {
                    return (& psmux list-panes -a -F '#{pane_id}' | Out-String).Trim()
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

        $script:RoleGateLabelsFile = Join-Path $env:APPDATA 'winsmux\labels.json'
    }

    Context 'deny paths' {
        It 'test_gate_builder_vault_denied' {
            { Invoke-GateEnforcedCommand -Role 'Builder' -Command 'vault' } | Should -Throw '*DENIED*'
            Should -Invoke Invoke-CommandAction -Times 0 -Exactly
        }

        It 'test_gate_builder_health_check_denied' {
            { Invoke-GateEnforcedCommand -Role 'Builder' -Command 'health-check' } | Should -Throw '*DENIED*'
            Should -Invoke Invoke-CommandAction -Times 0 -Exactly
        }

        It 'test_gate_builder_dispatch_denied' {
            { Invoke-GateEnforcedCommand -Role 'Builder' -Command 'dispatch' } | Should -Throw '*DENIED*'
            Should -Invoke Invoke-CommandAction -Times 0 -Exactly
        }

        It 'test_gate_builder_read_other_pane_denied' {
            { Invoke-GateEnforcedCommand -Role 'Builder' -Command 'read' -TargetPane 'reviewer' } | Should -Throw '*DENIED*'
            Should -Invoke Invoke-CommandAction -Times 0 -Exactly
        }

        It 'test_gate_researcher_vault_denied' {
            { Invoke-GateEnforcedCommand -Role 'Researcher' -Command 'vault' } | Should -Throw '*DENIED*'
            Should -Invoke Invoke-CommandAction -Times 0 -Exactly
        }

        It 'test_gate_reviewer_send_non_commander_denied' {
            { Invoke-GateEnforcedCommand -Role 'Reviewer' -Command 'send' -TargetPane 'reviewer' -Arguments @('status') } | Should -Throw '*DENIED*'
            Should -Invoke Invoke-CommandAction -Times 0 -Exactly
        }

        It 'test_gate_missing_role_denied' {
            { Invoke-GateEnforcedCommand -Role $null -Command 'read' -TargetPane 'builder' } | Should -Throw '*WINSMUX_ROLE not set*'
            Should -Invoke Invoke-CommandAction -Times 0 -Exactly
        }

        It 'test_gate_unknown_role_denied' {
            { Invoke-GateEnforcedCommand -Role 'admin' -Command 'read' -TargetPane 'builder' } | Should -Throw '*Invalid WINSMUX_ROLE*'
            Should -Invoke Invoke-CommandAction -Times 0 -Exactly
        }

        It 'test_gate_unknown_command_denied' {
            { Invoke-GateEnforcedCommand -Role 'Commander' -Command 'foobar' -TargetPane 'builder' } | Should -Throw '*DENIED*'
            Should -Invoke Invoke-CommandAction -Times 0 -Exactly
        }
    }

    Context 'allow paths' {
        It 'test_gate_commander_read_any_pane_allowed' {
            $result = Invoke-GateEnforcedCommand -Role 'Commander' -Command 'read' -TargetPane 'reviewer'

            $result | Should -Be 'captured pane output'
            Should -Invoke Invoke-CommandAction -Times 1 -Exactly
            Should -Invoke psmux -Times 1 -Exactly -ParameterFilter { $Args[0] -eq 'capture-pane' }
        }

        It 'test_gate_commander_send_any_pane_allowed' {
            $result = Invoke-GateEnforcedCommand -Role 'Commander' -Command 'send' -TargetPane 'reviewer' -Arguments @('run tests')

            $result | Should -Be 'sent to reviewer'
            Should -Invoke Invoke-CommandAction -Times 1 -Exactly
            Should -Invoke psmux -Times 2 -Exactly -ParameterFilter { $Args[0] -eq 'send-keys' }
        }

        It 'test_gate_commander_vault_allowed' {
            $result = Invoke-GateEnforcedCommand -Role 'Commander' -Command 'vault'

            $result | Should -Be 'vault ok'
            Should -Invoke Invoke-CommandAction -Times 1 -Exactly
            Should -Invoke psmux -Times 1 -Exactly -ParameterFilter { $Args[0] -eq 'source-file' }
        }

        It 'test_gate_builder_read_own_pane_allowed' {
            $result = Invoke-GateEnforcedCommand -Role 'Builder' -Command 'read' -TargetPane 'builder'

            $result | Should -Be 'captured pane output'
            Should -Invoke Invoke-CommandAction -Times 1 -Exactly
            Should -Invoke psmux -Times 1 -Exactly -ParameterFilter { $Args[0] -eq 'capture-pane' }
        }

        It 'test_gate_builder_send_commander_allowed' {
            $result = Invoke-GateEnforcedCommand -Role 'Builder' -Command 'send' -TargetPane 'commander' -Arguments @('done')

            $result | Should -Be 'sent to commander'
            Should -Invoke Invoke-CommandAction -Times 1 -Exactly
            Should -Invoke psmux -Times 2 -Exactly -ParameterFilter { $Args[0] -eq 'send-keys' }
        }

        It 'test_gate_all_roles_version_allowed' -ForEach $script:AllRoles {
            $result = Invoke-GateEnforcedCommand -Role $_ -Command 'version'

            $result | Should -Be 'psmux-bridge 0.9.6'
            Should -Invoke Invoke-CommandAction -Times 1 -Exactly
            Should -Invoke psmux -Times 0 -Exactly -ParameterFilter { $Args[0] -eq 'capture-pane' -or $Args[0] -eq 'send-keys' -or $Args[0] -eq 'list-panes' -or $Args[0] -eq 'source-file' }
        }

        It 'test_gate_all_roles_list_allowed' -ForEach $script:AllRoles {
            $result = Invoke-GateEnforcedCommand -Role $_ -Command 'list'

            $result | Should -Match '%1'
            Should -Invoke Invoke-CommandAction -Times 1 -Exactly
            Should -Invoke psmux -Times 1 -Exactly -ParameterFilter { $Args[0] -eq 'list-panes' }
        }
    }

    Context 'fail close' {
        It 'test_gate_fake_command_not_in_switch_denied' {
            { Invoke-GateEnforcedCommand -Role 'Commander' -Command 'future-command' -TargetPane 'builder' } | Should -Throw '*DENIED*'
            Should -Invoke Invoke-CommandAction -Times 0 -Exactly
        }

        It 'test_gate_default_branch_returns_false' {
            Set-TestWinsmuxRole -Role 'Commander'

            $gateErrors = @()
            $result = Assert-Role -Command 'future-command' -TargetPane 'builder' -ErrorAction SilentlyContinue -ErrorVariable gateErrors

            $result | Should -BeFalse
            ($gateErrors | Select-Object -Last 1 | ForEach-Object { $_.ToString() }) | Should -Match 'DENIED'
        }
    }
}
