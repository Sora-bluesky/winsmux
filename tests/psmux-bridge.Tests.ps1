BeforeAll {
    $script:BridgeScript = Join-Path $PSScriptRoot '..\scripts\psmux-bridge.ps1'
    . $script:BridgeScript

    function Stop-WithError {
        param([string]$Message)
        throw $Message
    }
}

BeforeEach {
    $script:OriginalWinsmuxRole = $env:WINSMUX_ROLE
}

AfterEach {
    if ($null -eq $script:OriginalWinsmuxRole) {
        Remove-Item Env:WINSMUX_ROLE -ErrorAction SilentlyContinue
    } else {
        $env:WINSMUX_ROLE = $script:OriginalWinsmuxRole
    }
}

Describe 'psmux-bridge' {
    Context 'version command' {
        It 'test_version_when_invoked_returns_version_string' {
            # Arrange
            $commandOutput = $null

            # Act
            $commandOutput = & pwsh -NoProfile -File $script:BridgeScript version

            # Assert
            $commandOutput | Should -Match '^psmux-bridge \d+\.\d+\.\d+$'
        }
    }

    Context 'Assert-Role' {
        It 'test_assert_role_when_role_missing_denies_access' {
            # Arrange
            Remove-Item Env:WINSMUX_ROLE -ErrorAction SilentlyContinue

            # Act
            $action = { Assert-Role -CommandName 'read' }

            # Assert
            $action | Should -Throw '*WINSMUX_ROLE is not set*'
        }

        It 'test_assert_role_when_commander_reads_allows_access' {
            # Arrange
            $env:WINSMUX_ROLE = 'Commander'

            # Act
            $action = { Assert-Role -CommandName 'read' }

            # Assert
            $action | Should -Not -Throw
        }

        It 'test_assert_role_when_builder_uses_vault_denies_access' {
            # Arrange
            $env:WINSMUX_ROLE = 'Builder'

            # Act
            $action = { Assert-Role -CommandName 'vault' }

            # Assert
            $action | Should -Throw "*cannot use 'vault'*"
        }

        It 'test_assert_role_when_role_unknown_denies_access' {
            # Arrange
            $env:WINSMUX_ROLE = 'UnknownRole'

            # Act
            $action = { Assert-Role -CommandName 'read' }

            # Assert
            $action | Should -Throw '*unknown WINSMUX_ROLE*'
        }
    }
}
