[CmdletBinding()]
param(
    [string]$SetupPath = (Join-Path $PSScriptRoot '..\..\target\release\bundle\nsis\winsmux_0.36.8_x64-setup.exe'),
    [string]$InstallRoot = 'C:\tmp\winsmux-context-menu-e2e',
    [ValidateSet('Both', 'English', 'Japanese')]
    [string]$Language = 'Both'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Remove-TestDirectory {
    param([string]$Path)
    $root = [System.IO.Path]::GetFullPath($InstallRoot)
    $target = [System.IO.Path]::GetFullPath($Path)
    Assert-True ($target.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) "Refusing to remove a path outside the test root: $target"
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

function Get-RegistryDefaultValue {
    param([string]$Path)
    return (Get-Item -LiteralPath $Path).GetValue('')
}

function Get-DesktopShortcutPath {
    $desktop = [Environment]::GetFolderPath('Desktop')
    Assert-True (-not [string]::IsNullOrWhiteSpace($desktop)) 'Desktop shell folder could not be resolved.'
    return (Join-Path $desktop 'winsmux.lnk')
}

function Get-ShortcutInfo {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            path = $Path
            exists = $false
        }
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    return [pscustomobject]@{
        path = $Path
        exists = $true
        targetPath = $shortcut.TargetPath
        iconLocation = $shortcut.IconLocation
        workingDirectory = $shortcut.WorkingDirectory
    }
}

function Test-PathInsideRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    return $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Backup-ExistingDesktopShortcut {
    param(
        [string]$ShortcutPath,
        [string]$BackupPath
    )

    if (-not (Test-Path -LiteralPath $ShortcutPath)) {
        return $false
    }

    $info = Get-ShortcutInfo -Path $ShortcutPath
    $isWinsmuxShortcut = $info.targetPath -like '*\winsmux-app.exe' -or $info.targetPath -like '*\winsmux.exe'
    Assert-True $isWinsmuxShortcut "Refusing to move an unrelated desktop shortcut: $ShortcutPath -> $($info.targetPath)"
    Assert-True (Test-PathInsideRoot -Path $BackupPath -Root $InstallRoot) "Refusing to backup outside the test root: $BackupPath"

    New-Item -ItemType Directory -Path (Split-Path -Parent $BackupPath) -Force | Out-Null
    Move-Item -LiteralPath $ShortcutPath -Destination $BackupPath -Force
    return $true
}

function Restore-DesktopShortcut {
    param(
        [string]$ShortcutPath,
        [string]$BackupPath
    )

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        return
    }

    if (Test-Path -LiteralPath $ShortcutPath) {
        $info = Get-ShortcutInfo -Path $ShortcutPath
        Assert-True (Test-PathInsideRoot -Path $info.targetPath -Root $InstallRoot) "Refusing to remove an unexpected desktop shortcut before restore: $ShortcutPath -> $($info.targetPath)"
        Remove-Item -LiteralPath $ShortcutPath -Force
    }

    Move-Item -LiteralPath $BackupPath -Destination $ShortcutPath -Force
}

function Remove-StaleProductState {
    param([string]$KeyPath)

    if (-not (Test-Path -LiteralPath $KeyPath)) {
        return
    }

    $value = [string](Get-RegistryDefaultValue -Path $KeyPath)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return
    }

    $fullValue = [System.IO.Path]::GetFullPath($value)
    $allowedRoots = @(
        [System.IO.Path]::GetFullPath($InstallRoot),
        [System.IO.Path]::GetFullPath('C:\tmp\winsmux-installer-smoke')
    )
    $isAllowedStalePath = $false
    foreach ($root in $allowedRoots) {
        if ($fullValue.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $isAllowedStalePath = $true
            break
        }
    }

    if ($isAllowedStalePath -and -not (Test-Path -LiteralPath $fullValue)) {
        Remove-Item -LiteralPath $KeyPath -Recurse -Force
    }
}

function Remove-TestProductState {
    param([string]$KeyPath)

    if (Test-Path -LiteralPath $KeyPath) {
        Remove-Item -LiteralPath $KeyPath -Recurse -Force
    }
}

function Assert-ContextMenuEntry {
    param(
        [string]$KeyPath,
        [string]$ArgumentToken,
        [string]$ExpectedExe,
        [string]$ExpectedLabel
    )

    $commandKey = Join-Path $KeyPath 'command'
    Assert-True (Test-Path -LiteralPath $KeyPath) "Missing context menu key: $KeyPath"
    Assert-True (Test-Path -LiteralPath $commandKey) "Missing context menu command key: $commandKey"

    $label = Get-RegistryDefaultValue -Path $KeyPath
    $verb = (Get-ItemProperty -LiteralPath $KeyPath -Name MUIVerb).MUIVerb
    $icon = (Get-ItemProperty -LiteralPath $KeyPath -Name Icon).Icon
    $command = Get-RegistryDefaultValue -Path $commandKey
    $expectedCommand = "`"$ExpectedExe`" `"$ArgumentToken`""

    Assert-True ($label -eq $ExpectedLabel) "Unexpected menu label for ${KeyPath}: $label"
    Assert-True ($verb -eq $ExpectedLabel) "Unexpected menu verb for ${KeyPath}: $verb"
    Assert-True ($icon -like '*winsmux-app.exe*') "Unexpected menu icon for ${KeyPath}: $icon"
    Assert-True ($command -eq $expectedCommand) "Unexpected command for ${KeyPath}: $command"

    return [pscustomobject]@{
        key = $KeyPath
        label = $label
        command = $command
    }
}

function Assert-DesktopShortcut {
    param(
        [string]$ShortcutPath,
        [string]$ExpectedExe
    )

    $info = Get-ShortcutInfo -Path $ShortcutPath
    Assert-True $info.exists "Desktop shortcut was not created: $ShortcutPath"

    $expectedIcon = "$ExpectedExe,0"
    Assert-True ([string]::Equals($info.targetPath, $ExpectedExe, [System.StringComparison]::OrdinalIgnoreCase)) "Unexpected desktop shortcut target: $($info.targetPath)"
    Assert-True ([string]::Equals($info.iconLocation, $expectedIcon, [System.StringComparison]::OrdinalIgnoreCase)) "Unexpected desktop shortcut icon: $($info.iconLocation)"

    return [pscustomobject]@{
        path = $info.path
        targetPath = $info.targetPath
        iconLocation = $info.iconLocation
    }
}

function Assert-DesktopShortcutRemoved {
    param(
        [string]$ShortcutPath,
        [string]$InstallPath
    )

    if (-not (Test-Path -LiteralPath $ShortcutPath)) {
        return
    }

    $info = Get-ShortcutInfo -Path $ShortcutPath
    Assert-True (-not (Test-PathInsideRoot -Path $info.targetPath -Root $InstallPath)) "Desktop shortcut remained after uninstall: $ShortcutPath"
}

function Remove-TestDesktopShortcut {
    param(
        [string]$ShortcutPath,
        [string]$InstallPath
    )

    if (-not (Test-Path -LiteralPath $ShortcutPath)) {
        return
    }

    $info = Get-ShortcutInfo -Path $ShortcutPath
    Assert-True (Test-PathInsideRoot -Path $info.targetPath -Root $InstallPath) "Refusing to remove an unrelated desktop shortcut: $ShortcutPath -> $($info.targetPath)"
    Remove-Item -LiteralPath $ShortcutPath -Force
}

function Get-LanguageCases {
    $cases = @(
        [pscustomobject]@{ id = 'english'; languageId = '1033'; expectedLabel = 'Open with winsmux' },
        [pscustomobject]@{ id = 'japanese'; languageId = '1041'; expectedLabel = 'winsmuxで開く' }
    )
    if ($Language -eq 'English') {
        return @($cases[0])
    }
    if ($Language -eq 'Japanese') {
        return @($cases[1])
    }
    return $cases
}

$folderKey = 'Registry::HKEY_CURRENT_USER\Software\Classes\Directory\shell\winsmux'
$backgroundKey = 'Registry::HKEY_CURRENT_USER\Software\Classes\Directory\Background\shell\winsmux'
$productStateKey = 'Registry::HKEY_CURRENT_USER\Software\github\winsmux'
$contextKeys = @($folderKey, $backgroundKey)
$desktopShortcutPath = Get-DesktopShortcutPath
$desktopShortcutBackupPath = Join-Path $InstallRoot 'desktop-shortcut-backup\winsmux-existing.lnk'
Remove-StaleProductState -KeyPath $productStateKey
$preExisting = @($contextKeys + @($productStateKey) | Where-Object { Test-Path -LiteralPath $_ })

Assert-True (Test-Path -LiteralPath $SetupPath) "NSIS setup.exe was not found: $SetupPath"
Assert-True ($preExisting.Count -eq 0) "Refusing to overwrite existing winsmux registry state: $($preExisting -join ', ')"

$results = [ordered]@{
    setupPath = [System.IO.Path]::GetFullPath($SetupPath)
    cases = @()
}

try {
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    $desktopShortcutWasBackedUp = Backup-ExistingDesktopShortcut -ShortcutPath $desktopShortcutPath -BackupPath $desktopShortcutBackupPath

    foreach ($case in Get-LanguageCases) {
        $installPath = Join-Path $InstallRoot "nsis-install-$($case.id)"
        $uninstallPath = Join-Path $installPath 'uninstall.exe'
        Remove-TestDirectory -Path $installPath
        Remove-TestProductState -KeyPath $productStateKey
        New-Item -Path $productStateKey -Force | Out-Null
        New-ItemProperty -Path $productStateKey -Name 'Installer Language' -Value $case.languageId -PropertyType String -Force | Out-Null

        $caseResult = [ordered]@{
            language = $case.id
            languageId = $case.languageId
            expectedLabel = $case.expectedLabel
            installPath = $installPath
            installed = $false
            contextMenu = @()
            desktopShortcut = $null
            uninstalled = $false
        }

        try {
            $install = Start-Process -FilePath $SetupPath -ArgumentList @('/S', "/D=$installPath") -Wait -PassThru
            Assert-True ($install.ExitCode -eq 0) "NSIS install failed for $($case.id) with exit code $($install.ExitCode)"
            $caseResult.installed = $true

            $expectedExe = Join-Path $installPath 'winsmux-app.exe'
            Assert-True (Test-Path -LiteralPath $expectedExe) "Installed winsmux-app.exe was not found: $expectedExe"

            $caseResult.contextMenu += Assert-ContextMenuEntry -KeyPath $folderKey -ArgumentToken '%1' -ExpectedExe $expectedExe -ExpectedLabel $case.expectedLabel
            $caseResult.contextMenu += Assert-ContextMenuEntry -KeyPath $backgroundKey -ArgumentToken '%V' -ExpectedExe $expectedExe -ExpectedLabel $case.expectedLabel
            $caseResult.desktopShortcut = Assert-DesktopShortcut -ShortcutPath $desktopShortcutPath -ExpectedExe $expectedExe

            Assert-True (Test-Path -LiteralPath $uninstallPath) "Uninstaller was not found: $uninstallPath"
            $uninstall = Start-Process -FilePath $uninstallPath -ArgumentList @('/S') -Wait -PassThru
            Assert-True ($uninstall.ExitCode -eq 0) "NSIS uninstall failed for $($case.id) with exit code $($uninstall.ExitCode)"
            $caseResult.uninstalled = $true

            foreach ($key in $contextKeys) {
                Assert-True (-not (Test-Path -LiteralPath $key)) "Context menu key remained after uninstall: $key"
            }
            Assert-DesktopShortcutRemoved -ShortcutPath $desktopShortcutPath -InstallPath $installPath
        } finally {
            if (Test-Path -LiteralPath $uninstallPath) {
                Start-Process -FilePath $uninstallPath -ArgumentList @('/S') -Wait -PassThru | Out-Null
            }
            Remove-TestDesktopShortcut -ShortcutPath $desktopShortcutPath -InstallPath $installPath
            foreach ($key in $contextKeys) {
                if (Test-Path -LiteralPath $key) {
                    Remove-Item -LiteralPath $key -Recurse -Force
                }
            }
            Remove-TestDirectory -Path $installPath
            Remove-TestProductState -KeyPath $productStateKey
        }

        $results.cases += [pscustomobject]$caseResult
    }

    [pscustomobject]$results | ConvertTo-Json -Depth 5
} finally {
    foreach ($key in $contextKeys) {
        if (Test-Path -LiteralPath $key) {
            Remove-Item -LiteralPath $key -Recurse -Force
        }
    }
    Restore-DesktopShortcut -ShortcutPath $desktopShortcutPath -BackupPath $desktopShortcutBackupPath
    Remove-TestProductState -KeyPath $productStateKey
}
