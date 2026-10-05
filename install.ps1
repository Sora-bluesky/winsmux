# install.ps1 — winsmux one-command installer
# Usage: irm https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1 | iex
# Or: pwsh install.ps1 [install|update|uninstall|version|help] [-ReleaseTag vX.Y.Z] [-Profile full]

[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Action = "install",
    [string]$ReleaseTag = "",
    [Alias("Profile")][string]$InstallProfile = ""
)

function Assert-WinsmuxReleaseTag {
    param([Parameter(Mandatory = $true)][string]$ReleaseTag)

    if ($ReleaseTag -notmatch '^v\d+\.\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$') {
        throw "Invalid winsmux release tag: $ReleaseTag"
    }
}

function Test-IsPipedWinsmuxInstaller {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$InvocationPath)

    return [string]::IsNullOrWhiteSpace($InvocationPath)
}

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$VERSION      = "0.38.0"
$WINSMUX_DIR  = Join-Path $HOME ".winsmux"
$BIN_DIR      = Join-Path $WINSMUX_DIR "bin"
$BACKUP_DIR   = Join-Path $WINSMUX_DIR "backups"
$SCRIPT_DIR   = Join-Path $WINSMUX_DIR "scripts"
$BRIDGE_DIR   = Join-Path $WINSMUX_DIR "winsmux-core"
$BRIDGE_SCRIPTS_DIR = Join-Path $BRIDGE_DIR "scripts"
$BRIDGE_ROUTER_DIR = Join-Path $BRIDGE_DIR "router"
$VERSION_FILE = Join-Path $WINSMUX_DIR "version"
$PROFILE_FILE = Join-Path $WINSMUX_DIR "install-profile"
$PROFILE_MANIFEST_FILE = Join-Path $WINSMUX_DIR "install-profile.json"
$PROFILE_MATRIX = @{
    core = "Runtime binary, wrapper scripts, PATH setup, and base config."
    orchestra = "Core profile plus orchestration scripts, runtime dependencies, and Windows Terminal profile."
    security = "Core profile plus vault, redaction, and audit-oriented scripts."
    full = "Core, orchestra, and security profile contents."
}
$installerE2e = $env:GITHUB_ACTIONS -eq 'true' -and $env:WINSMUX_INSTALL_E2E -eq 'true'
$redirectedInstallerE2e = $env:WINSMUX_INSTALL_E2E -eq 'redirected'
$redirectedStateRoot = ''
if ($redirectedInstallerE2e) {
    if ([string]::IsNullOrWhiteSpace($env:WINSMUX_INSTALL_STATE_ROOT)) {
        throw 'WINSMUX_INSTALL_STATE_ROOT is required in redirected installer E2E mode.'
    }
    $redirectedStateRoot = [System.IO.Path]::GetFullPath($env:WINSMUX_INSTALL_STATE_ROOT)
    $redirectedHome = [System.IO.Path]::GetFullPath($HOME).TrimEnd('\') + '\'
    if (-not $redirectedStateRoot.StartsWith($redirectedHome, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'WINSMUX_INSTALL_STATE_ROOT must be contained by the redirected HOME.'
    }
    New-Item -ItemType Directory -Path $redirectedStateRoot -Force | Out-Null
}
$e2eReleaseTag = if ($installerE2e) { [string]$env:WINSMUX_INSTALL_E2E_RELEASE_TAG } else { '' }
$releaseAction = $Action.Trim().ToLowerInvariant()
$requestedReleaseTag = if ($releaseAction -notin @('install', 'update')) {
    ''
} elseif (-not [string]::IsNullOrWhiteSpace($e2eReleaseTag)) {
    $e2eReleaseTag
} elseif ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
    $env:WINSMUX_RELEASE_TAG
} else {
    $ReleaseTag
}
if (-not [string]::IsNullOrWhiteSpace($requestedReleaseTag)) {
    $requestedReleaseTag = $requestedReleaseTag.Trim()
    Assert-WinsmuxReleaseTag -ReleaseTag $requestedReleaseTag
}
$installSourceRef = if ($installerE2e -or $redirectedInstallerE2e) { [string]$env:WINSMUX_INSTALL_SOURCE_REF } else { '' }
if (-not [string]::IsNullOrWhiteSpace($installSourceRef) -and $installSourceRef -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'WINSMUX_INSTALL_SOURCE_REF must be a 40-character commit SHA in an authorized installer E2E mode.'
}
# The defining source identifies this input. MyInvocation may identify the iex
# caller, and an in-memory input need not expose a MyCommand.Path property.
$installerInvocationPath = [string]((Get-Item Function:Test-IsPipedWinsmuxInstaller).ScriptBlock.File)
$isPipedInstaller = Test-IsPipedWinsmuxInstaller -InvocationPath $installerInvocationPath
if ($redirectedInstallerE2e -and $releaseAction -ne 'install') {
    throw 'Redirected installer E2E mode only permits the install action.'
}
$UseLatestRelease = [string]::IsNullOrWhiteSpace($requestedReleaseTag) -and ($releaseAction -eq 'install' -or $releaseAction -eq 'update')
if ($UseLatestRelease) {
    $EffectiveReleaseTag = ''
    $BASE_URL = "https://raw.githubusercontent.com/Sora-bluesky/winsmux/main"
    $RELEASE_API_URL = "https://api.github.com/repos/Sora-bluesky/winsmux/releases/latest"
    $RELEASE_LABEL = "latest"
} else {
    $EffectiveReleaseTag = if ([string]::IsNullOrWhiteSpace($requestedReleaseTag)) { "v$VERSION" } else { $requestedReleaseTag.Trim() }
    $BASE_URL = "https://raw.githubusercontent.com/Sora-bluesky/winsmux/$EffectiveReleaseTag"
    $escapedTag = [Uri]::EscapeDataString($EffectiveReleaseTag)
    $RELEASE_API_URL = "https://api.github.com/repos/Sora-bluesky/winsmux/releases/tags/$escapedTag"
    $RELEASE_LABEL = $EffectiveReleaseTag
}
$ResolvedReleaseTag = $EffectiveReleaseTag
$ResolvedVersion = $VERSION
if (-not [string]::IsNullOrWhiteSpace($installSourceRef)) {
    $BASE_URL = "https://raw.githubusercontent.com/Sora-bluesky/winsmux/$installSourceRef"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-InstallUserPath {
    if ($redirectedInstallerE2e) {
        $pathFile = Join-Path $redirectedStateRoot 'user-path.txt'
        if (-not (Test-Path -LiteralPath $pathFile -PathType Leaf)) { return '' }
        return (Get-Content -LiteralPath $pathFile -Raw -Encoding UTF8)
    }
    return [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Set-InstallUserPath {
    param([AllowEmptyString()][string]$Value)

    if ($redirectedInstallerE2e) {
        $pathFile = Join-Path $redirectedStateRoot 'user-path.txt'
        [System.IO.File]::WriteAllText($pathFile, $Value, [System.Text.UTF8Encoding]::new($false))
        return
    }
    [Environment]::SetEnvironmentVariable('Path', $Value, 'User')
}

function Get-InstallPowerShellProfilePath {
    if ($redirectedInstallerE2e) {
        return (Join-Path $redirectedStateRoot 'Microsoft.PowerShell_profile.ps1')
    }
    return $PROFILE.CurrentUserAllHosts
}

function Remove-WinsmuxProfileBlock {
    param(
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$ManagedPathLine
    )

    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) { return }
    $bytes = [System.IO.File]::ReadAllBytes($ProfilePath)
    $encoding = $null
    $preambleLength = 0
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        $encoding = [System.Text.UTF32Encoding]::new($true, $true)
        $preambleLength = 4
    } elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        $encoding = [System.Text.UTF32Encoding]::new($false, $true)
        $preambleLength = 4
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [System.Text.UTF8Encoding]::new($true)
        $preambleLength = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [System.Text.UnicodeEncoding]::new($true, $true)
        $preambleLength = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [System.Text.UnicodeEncoding]::new($false, $true)
        $preambleLength = 2
    } else {
        try {
            $encoding = [System.Text.UTF8Encoding]::new($false, $true)
            $null = $encoding.GetString($bytes)
        } catch {
            $encoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
        }
    }

    $text = $encoding.GetString($bytes, $preambleLength, $bytes.Length - $preambleLength)
    $managedPattern = '(?m)^# winsmux\r?\n' + [regex]::Escape($ManagedPathLine) + '(?:\r?\n|$)'
    $updated = ([regex]::new($managedPattern)).Replace($text, '', 1)
    if ($updated -ceq $text) { return }

    $body = $encoding.GetBytes($updated)
    if ($preambleLength -eq 0) {
        [System.IO.File]::WriteAllBytes($ProfilePath, $body)
        return
    }
    $output = [byte[]]::new($preambleLength + $body.Length)
    [Array]::Copy($bytes, 0, $output, 0, $preambleLength)
    [Array]::Copy($body, 0, $output, $preambleLength, $body.Length)
    [System.IO.File]::WriteAllBytes($ProfilePath, $output)
}

function Write-Status($msg) { Write-Host "[winsmux] $msg" }

function Resolve-InstallProfile {
    param([switch]$PreferExisting)

    $profileName = if ([string]::IsNullOrWhiteSpace($InstallProfile)) { $env:WINSMUX_INSTALL_PROFILE } else { $InstallProfile }
    if ([string]::IsNullOrWhiteSpace($profileName) -and $PreferExisting -and (Test-Path -LiteralPath $PROFILE_FILE -PathType Leaf)) {
        $profileName = (Get-Content -LiteralPath $PROFILE_FILE -Raw -ErrorAction SilentlyContinue).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($profileName)) {
        $profileName = "full"
    }

    $normalized = $profileName.Trim().ToLowerInvariant()
    if (-not $PROFILE_MATRIX.ContainsKey($normalized)) {
        $supported = ($PROFILE_MATRIX.Keys | Sort-Object) -join ", "
        throw "Unsupported install profile '$profileName'. Supported profiles: $supported"
    }

    return $normalized
}

function Get-InstallProfileContents {
    param([Parameter(Mandatory = $true)][string]$Profile)

    switch ($Profile) {
        "core" { return @("runtime", "wrappers", "path", "base_config") }
        "orchestra" { return @("runtime", "wrappers", "path", "base_config", "orchestration_scripts", "windows_terminal_profile", "vault") }
        "security" { return @("runtime", "wrappers", "path", "base_config", "vault", "redaction", "audit_scripts") }
        "full" { return @("runtime", "wrappers", "path", "base_config", "orchestration_scripts", "windows_terminal_profile", "vault", "redaction", "audit_scripts", "local_router_artifacts") }
        default { throw "Unsupported install profile '$Profile'." }
    }
}

function Test-InstallProfileContent {
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$Content
    )

    return @(Get-InstallProfileContents -Profile $Profile) -contains $Content
}

function Write-InstallProfileManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][bool]$IsUpdate
    )

    $manifest = [ordered]@{
        version = $ResolvedVersion
        profile = $Profile
        release_tag = $ResolvedReleaseTag
        mode = if ($IsUpdate) { "update" } else { "install" }
        contents = @(Get-InstallProfileContents -Profile $Profile)
        recorded_at = (Get-Date).ToUniversalTime().ToString("o")
    }

    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $PROFILE_MANIFEST_FILE -Encoding UTF8
}

function Install-CoreSupportScripts {
    Download-File "winsmux-core/scripts/json-compat.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "json-compat.ps1")
    # winsmux-core.ps1 calls Test-PaneContainsCommandFragment / Test-ShellPromptText
    # on every profile, including core and security.
    Download-File "winsmux-core/scripts/pane-dispatch-detect.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "pane-dispatch-detect.ps1")
    Download-OptionalFile "winsmux-core/scripts/control-plane-workers.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "control-plane-workers.ps1")
    Download-OptionalFile "winsmux-core/scripts/control-plane-ledger.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "control-plane-ledger.ps1")
}

function Install-InstructionPacks {
    $profileRoot = Join-Path $BRIDGE_DIR 'agents\profiles'
    Download-File "winsmux-core/agents/profiles/base.md" (Join-Path $profileRoot 'base.md')
    Download-File "winsmux-core/agents/profiles/lifecycles/one-shot.md" (Join-Path $profileRoot 'lifecycles\one-shot.md')
    Download-File "winsmux-core/agents/profiles/lifecycles/session.md" (Join-Path $profileRoot 'lifecycles\session.md')
    Download-File "winsmux-core/agents/profiles/lifecycles/task.md" (Join-Path $profileRoot 'lifecycles\task.md')
    Download-File "winsmux-core/agents/profiles/models/antigravity/antigravity-claude-opus-4-6-thinking.md" (Join-Path $profileRoot 'models\antigravity\antigravity-claude-opus-4-6-thinking.md')
    Download-File "winsmux-core/agents/profiles/models/antigravity/antigravity-claude-sonnet-4-6-thinking.md" (Join-Path $profileRoot 'models\antigravity\antigravity-claude-sonnet-4-6-thinking.md')
    Download-File "winsmux-core/agents/profiles/models/antigravity/antigravity-gemini-3-1-pro-high.md" (Join-Path $profileRoot 'models\antigravity\antigravity-gemini-3-1-pro-high.md')
    Download-File "winsmux-core/agents/profiles/models/antigravity/antigravity-gemini-3-1-pro-low.md" (Join-Path $profileRoot 'models\antigravity\antigravity-gemini-3-1-pro-low.md')
    Download-File "winsmux-core/agents/profiles/models/antigravity/antigravity-gemini-3-5-flash-high.md" (Join-Path $profileRoot 'models\antigravity\antigravity-gemini-3-5-flash-high.md')
    Download-File "winsmux-core/agents/profiles/models/antigravity/antigravity-gemini-3-5-flash-low.md" (Join-Path $profileRoot 'models\antigravity\antigravity-gemini-3-5-flash-low.md')
    Download-File "winsmux-core/agents/profiles/models/antigravity/antigravity-gemini-3-5-flash-medium.md" (Join-Path $profileRoot 'models\antigravity\antigravity-gemini-3-5-flash-medium.md')
    Download-File "winsmux-core/agents/profiles/models/antigravity/antigravity-gpt-oss-120b-medium.md" (Join-Path $profileRoot 'models\antigravity\antigravity-gpt-oss-120b-medium.md')
    Download-File "winsmux-core/agents/profiles/models/claude/claude-fable-5.md" (Join-Path $profileRoot 'models\claude\claude-fable-5.md')
    Download-File "winsmux-core/agents/profiles/models/claude/claude-haiku-4-5.md" (Join-Path $profileRoot 'models\claude\claude-haiku-4-5.md')
    Download-File "winsmux-core/agents/profiles/models/claude/claude-opus-4-6.md" (Join-Path $profileRoot 'models\claude\claude-opus-4-6.md')
    Download-File "winsmux-core/agents/profiles/models/claude/claude-opus-4-7.md" (Join-Path $profileRoot 'models\claude\claude-opus-4-7.md')
    Download-File "winsmux-core/agents/profiles/models/claude/claude-opus-4-8.md" (Join-Path $profileRoot 'models\claude\claude-opus-4-8.md')
    Download-File "winsmux-core/agents/profiles/models/claude/claude-opus-5.md" (Join-Path $profileRoot 'models\claude\claude-opus-5.md')
    Download-File "winsmux-core/agents/profiles/models/claude/claude-sonnet-4-6.md" (Join-Path $profileRoot 'models\claude\claude-sonnet-4-6.md')
    Download-File "winsmux-core/agents/profiles/models/claude/claude-sonnet-5.md" (Join-Path $profileRoot 'models\claude\claude-sonnet-5.md')
    Download-File "winsmux-core/agents/profiles/models/codex/codex-gpt-5-4-mini.md" (Join-Path $profileRoot 'models\codex\codex-gpt-5-4-mini.md')
    Download-File "winsmux-core/agents/profiles/models/codex/codex-gpt-5-4.md" (Join-Path $profileRoot 'models\codex\codex-gpt-5-4.md')
    Download-File "winsmux-core/agents/profiles/models/codex/codex-gpt-5-5.md" (Join-Path $profileRoot 'models\codex\codex-gpt-5-5.md')
    Download-File "winsmux-core/agents/profiles/models/codex/codex-gpt-5-6-luna.md" (Join-Path $profileRoot 'models\codex\codex-gpt-5-6-luna.md')
    Download-File "winsmux-core/agents/profiles/models/codex/codex-gpt-5-6-sol.md" (Join-Path $profileRoot 'models\codex\codex-gpt-5-6-sol.md')
    Download-File "winsmux-core/agents/profiles/models/codex/codex-gpt-5-6-terra.md" (Join-Path $profileRoot 'models\codex\codex-gpt-5-6-terra.md')
    Download-File "winsmux-core/agents/profiles/models/codex/codex-spark.md" (Join-Path $profileRoot 'models\codex\codex-spark.md')
    Download-File "winsmux-core/agents/profiles/models/grok-build/grok-build-composer-2-5-fast.md" (Join-Path $profileRoot 'models\grok-build\grok-build-composer-2-5-fast.md')
    Download-File "winsmux-core/agents/profiles/models/grok-build/grok-build-grok-4-3.md" (Join-Path $profileRoot 'models\grok-build\grok-build-grok-4-3.md')
    Download-File "winsmux-core/agents/profiles/models/openrouter/_dynamic.md" (Join-Path $profileRoot 'models\openrouter\_dynamic.md')
    Download-File "winsmux-core/agents/profiles/models/openrouter/openrouter-glm-5-2.md" (Join-Path $profileRoot 'models\openrouter\openrouter-glm-5-2.md')
    Download-File "winsmux-core/agents/profiles/models/openrouter/openrouter-kimi-k2-7-code.md" (Join-Path $profileRoot 'models\openrouter\openrouter-kimi-k2-7-code.md')
    Download-File "winsmux-core/agents/profiles/models/openrouter/openrouter-sakana-fugu-ultra.md" (Join-Path $profileRoot 'models\openrouter\openrouter-sakana-fugu-ultra.md')
    Download-File "winsmux-core/agents/profiles/providers/antigravity.md" (Join-Path $profileRoot 'providers\antigravity.md')
    Download-File "winsmux-core/agents/profiles/providers/claude.md" (Join-Path $profileRoot 'providers\claude.md')
    Download-File "winsmux-core/agents/profiles/providers/codex.md" (Join-Path $profileRoot 'providers\codex.md')
    Download-File "winsmux-core/agents/profiles/providers/grok-build.md" (Join-Path $profileRoot 'providers\grok-build.md')
    Download-File "winsmux-core/agents/profiles/providers/openrouter.md" (Join-Path $profileRoot 'providers\openrouter.md')
    Download-File "winsmux-core/agents/profiles/registry.yaml" (Join-Path $profileRoot 'registry.yaml')
    Download-File "winsmux-core/agents/profiles/roles/architect.md" (Join-Path $profileRoot 'roles\architect.md')
    Download-File "winsmux-core/agents/profiles/roles/builder.md" (Join-Path $profileRoot 'roles\builder.md')
    Download-File "winsmux-core/agents/profiles/roles/maintainer.md" (Join-Path $profileRoot 'roles\maintainer.md')
    Download-File "winsmux-core/agents/profiles/roles/researcher.md" (Join-Path $profileRoot 'roles\researcher.md')
    Download-File "winsmux-core/agents/profiles/roles/reviewer.md" (Join-Path $profileRoot 'roles\reviewer.md')
    Download-File "winsmux-core/agents/profiles/task-classes/architecture.md" (Join-Path $profileRoot 'task-classes\architecture.md')
    Download-File "winsmux-core/agents/profiles/task-classes/documentation.md" (Join-Path $profileRoot 'task-classes\documentation.md')
    Download-File "winsmux-core/agents/profiles/task-classes/implementation.md" (Join-Path $profileRoot 'task-classes\implementation.md')
    Download-File "winsmux-core/agents/profiles/task-classes/protocol.md" (Join-Path $profileRoot 'task-classes\protocol.md')
    Download-File "winsmux-core/agents/profiles/task-classes/repository-operations.md" (Join-Path $profileRoot 'task-classes\repository-operations.md')
    Download-File "winsmux-core/agents/profiles/task-classes/research.md" (Join-Path $profileRoot 'task-classes\research.md')
    Download-File "winsmux-core/agents/profiles/task-classes/review.md" (Join-Path $profileRoot 'task-classes\review.md')
    Download-File "winsmux-core/agents/profiles/task-classes/security.md" (Join-Path $profileRoot 'task-classes\security.md')
    Download-File "winsmux-core/agents/profiles/task-classes/test.md" (Join-Path $profileRoot 'task-classes\test.md')
}


function Install-OrchestraSupportScripts {
    Download-File "winsmux-core/scripts/api-llm-pane-worker.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "api-llm-pane-worker.ps1")
    Download-File "winsmux-core/scripts/agent-launch.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "agent-launch.ps1")
    Download-File "winsmux-core/scripts/agent-monitor.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "agent-monitor.ps1")
    Download-File "winsmux-core/scripts/agent-readiness.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "agent-readiness.ps1")
    Download-File "winsmux-core/scripts/agent-watchdog.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "agent-watchdog.ps1")
    Download-File "winsmux-core/scripts/assignment-policy.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "assignment-policy.ps1")
    Download-File "winsmux-core/scripts/builder-queue.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "builder-queue.ps1")
    Download-File "winsmux-core/scripts/builder-worktree.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "builder-worktree.ps1")
    Download-File "winsmux-core/scripts/clm-safe-io.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "clm-safe-io.ps1")
    Download-File "winsmux-core/scripts/common-contract.generated.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "common-contract.generated.ps1")
    Download-File "winsmux-core/scripts/control-plane-commands.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "control-plane-commands.ps1")
    Download-File "winsmux-core/scripts/control-plane-dispatch.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "control-plane-dispatch.ps1")
    Download-File "winsmux-core/scripts/declarative-workflow.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "declarative-workflow.ps1")
    Download-File "winsmux-core/scripts/conflict-preflight.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "conflict-preflight.ps1")
    Download-File "winsmux-core/scripts/operator-poll.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "operator-poll.ps1")
    Download-File "winsmux-core/scripts/doctor.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "doctor.ps1")
    Download-File "winsmux-core/scripts/dispatch-router.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "dispatch-router.ps1")
    Download-File "winsmux-core/scripts/github-write-preflight.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "github-write-preflight.ps1")
    Download-File "winsmux-core/scripts/harness-check.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "harness-check.ps1")
    Download-File "winsmux-core/scripts/logger.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "logger.ps1")
    Download-File "winsmux-core/scripts/manifest.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "manifest.ps1")
    Download-File "winsmux-core/scripts/orchestra-attach-confirm.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-attach-confirm.ps1")
    Download-File "winsmux-core/scripts/orchestra-attach-entry.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-attach-entry.ps1")
    Download-File "winsmux-core/scripts/orchestra-attach.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-attach.ps1")
    Download-File "winsmux-core/scripts/orchestra-pane-bootstrap.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-pane-bootstrap.ps1")
    Download-File "winsmux-core/scripts/orchestra-preflight.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-preflight.ps1")
    Download-File "winsmux-core/scripts/orchestra-smoke.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-smoke.ps1")
    Download-File "winsmux-core/scripts/orchestra-start.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-start.ps1")
    Download-File "winsmux-core/scripts/orchestra-supervisor.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-supervisor.ps1")
    Download-File "winsmux-core/scripts/orchestra-state.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-state.ps1")
    Download-File "winsmux-core/scripts/orchestra-layout.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-layout.ps1")
    Download-File "winsmux-core/scripts/orchestra-ui-attach.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-ui-attach.ps1")
    Download-File "winsmux-core/scripts/pane-control.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "pane-control.ps1")
    Download-File "winsmux-core/scripts/pane-env.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "pane-env.ps1")
    Download-File "winsmux-core/scripts/pane-scaler.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "pane-scaler.ps1")
    Download-File "winsmux-core/scripts/pane-border.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "pane-border.ps1")
    Download-File "winsmux-core/scripts/pane-status.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "pane-status.ps1")
    Download-File "winsmux-core/scripts/planning-paths.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "planning-paths.ps1")
    Download-File "winsmux-core/scripts/public-first-run.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "public-first-run.ps1")
    Download-File "winsmux-core/scripts/powershell-deescalation.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "powershell-deescalation.ps1")
    Download-File "winsmux-core/scripts/role-gate.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "role-gate.ps1")
    Download-File "winsmux-core/scripts/server-watchdog.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "server-watchdog.ps1")
    Download-File "winsmux-core/scripts/settings.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "settings.ps1")
    Download-File "winsmux-core/scripts/shadow-cutover-gate.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "shadow-cutover-gate.ps1")
    Download-File "winsmux-core/scripts/submission-contract.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "submission-contract.ps1")
    Download-File "winsmux-core/scripts/task-splitter.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "task-splitter.ps1")
    Download-File "winsmux-core/scripts/team-pipeline.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "team-pipeline.ps1")
    Download-File "winsmux-core/scripts/worker-isolation.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "worker-isolation.ps1")
}

function Install-SecuritySupportScripts {
    Download-File "winsmux-core/scripts/credential-metadata.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "credential-metadata.ps1")
    Download-File "winsmux-core/scripts/vault.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "vault.ps1")
}

function Install-LocalRouterArtifacts {
    Download-File "winsmux-core/scripts/coordinator-router.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "coordinator-router.ps1")
    Download-File "winsmux-core/scripts/local-router-shadow.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "local-router-shadow.ps1")
    Download-File "winsmux-core/router/local-small-router-v03621.manifest.json" (Join-Path $BRIDGE_ROUTER_DIR "local-small-router-v03621.manifest.json")
    Download-File "winsmux-core/router/local-small-router-v03621.weights.json" (Join-Path $BRIDGE_ROUTER_DIR "local-small-router-v03621.weights.json")
}

function Remove-ProfileExcludedSupportScripts {
    param([Parameter(Mandatory = $true)][string]$Profile)

    $scriptGroups = @(
        [PSCustomObject]@{
            Content = "orchestration_scripts"
            Files = @(
                "agent-launch.ps1",
                "agent-monitor.ps1",
                "agent-readiness.ps1",
                "agent-watchdog.ps1",
                "api-llm-pane-worker.ps1",
                "assignment-policy.ps1",
                "builder-queue.ps1",
                "builder-worktree.ps1",
                "clm-safe-io.ps1",
                "common-contract.generated.ps1",
                "conflict-preflight.ps1",
                "control-plane-commands.ps1",
                "control-plane-dispatch.ps1",
                "declarative-workflow.ps1",
                "dispatch-router.ps1",
                "operator-poll.ps1",
                "doctor.ps1",
                "github-write-preflight.ps1",
                "harness-check.ps1",
                "logger.ps1",
                "manifest.ps1",
                "orchestra-attach-confirm.ps1",
                "orchestra-attach-entry.ps1",
                "orchestra-attach.ps1",
                "orchestra-pane-bootstrap.ps1",
                "orchestra-preflight.ps1",
                "orchestra-smoke.ps1",
                "orchestra-start.ps1",
                "orchestra-state.ps1",
                "orchestra-supervisor.ps1",
                "orchestra-layout.ps1",
                "orchestra-ui-attach.ps1",
                "pane-control.ps1",
                "pane-env.ps1",
                "pane-scaler.ps1",
                "pane-border.ps1",
                "pane-status.ps1",
                "planning-paths.ps1",
                "powershell-deescalation.ps1",
                "public-first-run.ps1",
                "role-gate.ps1",
                "server-watchdog.ps1",
                "settings.ps1",
                "shadow-cutover-gate.ps1",
                "submission-contract.ps1",
                "task-splitter.ps1",
                "team-pipeline.ps1",
                "worker-isolation.ps1"
            )
        },
        [PSCustomObject]@{
            Content = "vault"
            Files = @("credential-metadata.ps1", "vault.ps1")
        }
    )

    foreach ($group in $scriptGroups) {
        if (Test-InstallProfileContent -Profile $Profile -Content $group.Content) {
            continue
        }

        foreach ($fileName in $group.Files) {
            $path = Join-Path $BRIDGE_SCRIPTS_DIR $fileName
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
                Write-Status "Removed profile-excluded support script: $fileName"
            }
        }
    }

    if (-not (Test-InstallProfileContent -Profile $Profile -Content "local_router_artifacts")) {
        foreach ($path in @(
            (Join-Path $BRIDGE_SCRIPTS_DIR "coordinator-router.ps1"),
            (Join-Path $BRIDGE_SCRIPTS_DIR "local-router-shadow.ps1"),
            (Join-Path $BRIDGE_ROUTER_DIR "local-small-router-v03621.manifest.json"),
            (Join-Path $BRIDGE_ROUTER_DIR "local-small-router-v03621.weights.json")
        )) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
                Write-Status "Removed profile-excluded local router artifact: $(Split-Path -Leaf $path)"
            }
        }
    }
}

function Sync-WindowsTerminalFragment {
    param([Parameter(Mandatory = $true)][string]$Profile)

    $fragmentDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\winsmux"
    $fragmentFile = Join-Path $fragmentDir "winsmux.json"
    $shouldInstallFragment = Test-InstallProfileContent -Profile $Profile -Content "windows_terminal_profile"

    if (-not $shouldInstallFragment) {
        if (Test-Path $fragmentFile) {
            Remove-Item $fragmentFile -Force
            Write-Status "Removed Windows Terminal fragment for profile '$Profile': $fragmentFile"
        }
        return
    }

    if (-not (Test-Path $fragmentDir)) {
        New-Item -ItemType Directory -Path $fragmentDir -Force | Out-Null
    }
    $fragmentJson = @'
{
  "profiles": [
    {
      "name": "winsmux Orchestra",
      "commandline": "pwsh -NoProfile -Command \"$dir = Read-Host 'Project dir'; if ([string]::IsNullOrWhiteSpace($dir)) { Write-Error 'Project dir is required.'; exit 1 }; & '%USERPROFILE%\\.winsmux\\bin\\winsmux.cmd' launch --project-dir $dir\"",
      "icon": "🎼",
      "startingDirectory": "%USERPROFILE%",
      "tabTitle": "winsmux Orchestra"
    }
  ]
}
'@
    $fragmentJson | Set-Content -Path $fragmentFile -Encoding UTF8
    Write-Status "Registered Windows Terminal fragment: $fragmentFile"
}

function Test-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PreferredReleaseAssetName {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq "x86" -and $env:PROCESSOR_ARCHITEW6432) {
        $arch = $env:PROCESSOR_ARCHITEW6432
    }

    switch ($arch) {
        "AMD64" { return "winsmux-x64.exe" }
        "ARM64" { return "winsmux-arm64.exe" }
        default { throw "Unsupported architecture: $arch" }
    }
}

function Get-WinsmuxBytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function ConvertFrom-StrictWinsmuxJsonBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    if ($text.Length -eq 0 -or $text[0] -eq [char]0xfeff -or $text.Contains([string][char]0)) {
        throw 'Invalid UTF-8 license manifest.'
    }
    $document = [System.Text.Json.JsonDocument]::Parse($text)
    function Assert-WinsmuxJsonProperties($Element) {
        if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
            $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $keys.Add($property.Name)) { throw 'Duplicate or case-aliased license manifest property.' }
                Assert-WinsmuxJsonProperties $property.Value
            }
        } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
            foreach ($entry in $Element.EnumerateArray()) { Assert-WinsmuxJsonProperties $entry }
        }
    }
    try { Assert-WinsmuxJsonProperties $document.RootElement }
    finally { $document.Dispose() }
    # Neither ConvertFrom-Json nor the function pipeline may unwrap a root array.
    return ,(ConvertFrom-Json -InputObject $text -AsHashtable -NoEnumerate)
}

function Assert-WinsmuxLicenseObjectKeys {
    param($Value, [Collections.IDictionary]$Fields, [switch]$AllowExtra)
    # Compare only already typed scalars. PowerShell array comparison/regex results
    # are collections, so an empty array must never reach a value predicate.
    if ($Value -is [Collections.IDictionary]) {
        $properties = $Value
    } elseif ($AllowExtra -and $Value -is [PSCustomObject]) {
        $properties = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($property in $Value.PSObject.Properties) { $properties.Add($property.Name, $property.Value) }
    } else {
        throw 'License manifest fields differ from the supported schema.'
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $properties.Keys) { [void]$names.Add($name) }
    if (-not $AllowExtra -and $names.Count -ne $Fields.Count) { throw 'License manifest fields differ from the supported schema.' }
    foreach ($name in $Fields.Keys) {
        if (-not $names.Contains($name)) { throw 'License manifest fields differ from the supported schema.' }
        $entry = $properties[$name]
        $valid = switch ($Fields[$name]) {
            'string' { $entry -is [string] -and -not [string]::IsNullOrWhiteSpace($entry) }
            'nullable-string' { $null -eq $entry -or ($entry -is [string] -and -not [string]::IsNullOrWhiteSpace($entry)) }
            'integer' { $entry -is [int] -or $entry -is [long] }
            'array' { $entry -is [array] }
            default { throw 'Unsupported installer JSON schema type.' }
        }
        if (-not $valid) { throw ('Invalid installer JSON field type: ' + $name) }
    }
}

function Assert-WinsmuxLicenseMemberPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or $Path -cnotmatch '^[A-Za-z0-9._/-]+$' -or $Path.StartsWith('/')) {
        throw 'Invalid license archive member path.'
    }
    foreach ($part in $Path.Split('/')) {
        if ([string]::IsNullOrEmpty($part) -or $part -in @('.', '..') -or $part.EndsWith('.') -or
            $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw 'Aliased or reserved license archive member path.'
        }
    }
}

# Pure validation: every byte is read from the already downloaded buffer. No extraction or filesystem mutation.
function Read-WinsmuxLicenseSidecar {
    param(
        [Parameter(Mandatory = $true)][byte[]]$ArchiveBytes,
        [Parameter(Mandatory = $true)][string]$ArchiveSha256,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$ReleaseTag,
        [Parameter(Mandatory = $true)][string]$AssetName,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ExecutableSha256
    )
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'License verification requires the documented PowerShell 7+ runtime.' }
    if ($ArchiveSha256 -notmatch '^[a-fA-F0-9]{64}$' -or $ExecutableSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        (Get-WinsmuxBytesSha256 $ArchiveBytes) -cne $ArchiveSha256.ToLowerInvariant()) {
        throw 'Release license sidecar checksum differs.'
    }
    $memory = [IO.MemoryStream]::new($ArchiveBytes, $false)
    $archive = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Read, $false)
    $files = [Collections.Generic.Dictionary[string, byte[]]]::new([StringComparer]::Ordinal)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName
            Assert-WinsmuxLicenseMemberPath $name
            if (-not $names.Add($name) -or $entry.Name.Length -eq 0 -or
                (($entry.ExternalAttributes -shr 16) -band 0xf000) -notin @(0, 0x8000) -or
                ($entry.ExternalAttributes -band 0x410) -ne 0) {
                throw 'Duplicate, directory or linked license archive member.'
            }
            $inputStream = $entry.Open()
            $outputStream = [IO.MemoryStream]::new()
            try {
                $inputStream.CopyTo($outputStream)
                if ($outputStream.Length -ne $entry.Length) { throw 'License archive member length differs.' }
                $files.Add($name, $outputStream.ToArray())
            } finally { $inputStream.Dispose(); $outputStream.Dispose() }
        }
    } finally { $archive.Dispose(); $memory.Dispose() }
    foreach ($name in $files.Keys) {
        $parts = $name.Split('/')
        for ($i = 1; $i -lt $parts.Count; $i++) {
            if ($names.Contains(($parts[0..($i - 1)] -join '/'))) { throw 'License archive file/directory collision.' }
        }
    }
    if (-not $files.ContainsKey('manifest.json')) { throw 'Release license sidecar manifest is missing.' }
    $manifest = ConvertFrom-StrictWinsmuxJsonBytes $files['manifest.json']
    Assert-WinsmuxLicenseObjectKeys $manifest @{ schema='string'; version='string'; release_tag='string'; asset_name='string'; target='string'; executable_sha256='string'; license_manifest_sha256='string'; files='array' }
    if ($manifest.schema -cne 'winsmux-core-license-sidecar/v1' -or $manifest.version -cne $Version -or
        $manifest.release_tag -cne $ReleaseTag -or $manifest.asset_name -cne $AssetName -or $manifest.target -cne $Target -or
        $manifest.executable_sha256 -cne $ExecutableSha256.ToLowerInvariant() -or
        $manifest.license_manifest_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $manifest.files -isnot [array]) {
        throw 'Release license sidecar does not bind the selected executable.'
    }
    $expected = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($row in $manifest.files) {
        Assert-WinsmuxLicenseObjectKeys $row @{ path='string'; bytes='integer'; sha256='string' }
        Assert-WinsmuxLicenseMemberPath $row.path
        if (-not $row.path.StartsWith('licenses/', [StringComparison]::Ordinal) -or $expected.ContainsKey($row.path) -or
            ($row.bytes -isnot [long] -and $row.bytes -isnot [int]) -or $row.bytes -lt 0 -or
            $row.sha256 -cnotmatch '^[a-f0-9]{64}$' -or -not $files.ContainsKey($row.path) -or
            $files[$row.path].LongLength -ne $row.bytes -or (Get-WinsmuxBytesSha256 $files[$row.path]) -cne $row.sha256) {
            throw 'Release license inventory or member bytes differ.'
        }
        $expected.Add($row.path, $row)
    }
    if ($files.Count -ne $expected.Count + 1 -or -not $expected.ContainsKey('licenses/manifest.json') -or
        -not $expected.ContainsKey('licenses/THIRD_PARTY_NOTICES.txt') -or
        (Get-WinsmuxBytesSha256 $files['licenses/manifest.json']) -cne $manifest.license_manifest_sha256) {
        throw 'Release license sidecar inventory is incomplete or contains undeclared members.'
    }
    # The immutable ZIP may not contradict its own original-document and covered-source inventory.
    $inner = ConvertFrom-StrictWinsmuxJsonBytes $files['licenses/manifest.json']
    Assert-WinsmuxLicenseObjectKeys $inner @{ schema='string'; version='string'; policy_sha256='string'; input_sha256='string'; catalog_sha256='string'; components='array'; source_obligations='array'; files='array' }
    if ($inner.schema -cne 'distribution-license-generation/v1' -or $inner.version -cne $Version -or
        $inner.files -isnot [array] -or $inner.components -isnot [array] -or $inner.source_obligations -isnot [array]) {
        throw 'Original license generation schema differs.'
    }
    foreach ($identity in @($inner.policy_sha256, $inner.input_sha256, $inner.catalog_sha256)) {
        if ($identity -cnotmatch '^[a-f0-9]{64}$') { throw 'Original license generation identity is invalid.' }
    }
    $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $inner.files) {
        Assert-WinsmuxLicenseObjectKeys $row @{ path='string'; bytes='integer'; sha256='string' }
        Assert-WinsmuxLicenseMemberPath $row.path
        $name = 'licenses/' + $row.path
        if (($row.bytes -isnot [long] -and $row.bytes -isnot [int]) -or $row.bytes -lt 0 -or
            $row.sha256 -cnotmatch '^[a-f0-9]{64}$' -or -not $required.Add($name) -or -not $expected.ContainsKey($name) -or
            $row.bytes -ne $expected[$name].bytes -or $row.sha256 -cne $expected[$name].sha256) {
            throw 'Original license/source inventory differs from the sidecar payload.'
        }
    }
    if ($required.Contains('licenses/manifest.json') -or $required.Contains('licenses/THIRD_PARTY_NOTICES.txt') -or
        $required.Count + 2 -ne $expected.Count) { throw 'Original license generation inventory is not closed.' }
    foreach ($component in $inner.components) {
        Assert-WinsmuxLicenseObjectKeys $component @{ id='string'; version='string'; declared_license='nullable-string'; choice='string'; documents='array' }
        foreach ($document in $component.documents) {
            Assert-WinsmuxLicenseObjectKeys $document @{ path='string'; sha256='string' }
            Assert-WinsmuxLicenseMemberPath $document.path
            $name = 'licenses/' + $document.path
            if (-not $required.Contains($name) -or $document.sha256 -cne $expected[$name].sha256) {
                throw 'Original component document differs from the sidecar payload.'
            }
        }
    }
    foreach ($row in $inner.source_obligations) {
        Assert-WinsmuxLicenseObjectKeys $row @{ id='string'; version='string'; source_path='string'; source_url='string'; source_archive_sha256='string' }
        $name = 'licenses/' + $row.source_path
        if (-not $required.Contains($name) -or $row.source_archive_sha256 -cne $expected[$name].sha256) {
            throw 'Required covered source archive differs from the sidecar payload.'
        }
    }
    return [PSCustomObject]@{ Manifest = $manifest; Files = $files; ArchiveSha256 = $ArchiveSha256.ToLowerInvariant() }
}

function Get-WinsmuxExecutingInstallerSource {
    # Function AST ancestry remains the actual executing input for both a saved
    # script and irm | iex. MyInvocation can instead describe the iex caller.
    $root = (Get-Item Function:Get-WinsmuxExecutingInstallerSource).ScriptBlock.Ast
    while ($null -ne $root.Parent) { $root = $root.Parent }
    if ($root -isnot [Management.Automation.Language.ScriptBlockAst] -or
        [string]::IsNullOrWhiteSpace($root.Extent.Text)) {
        throw 'The executing installer body is unavailable.'
    }
    return $root.Extent.Text
}

function ConvertTo-WinsmuxLifecycleBytes {
    param([Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Version)
    if ($Version -cnotmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$' -or $Source.Contains([char]0)) {
        throw 'Invalid lifecycle body or binary version.'
    }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    if ($errors.Count -or -not $ast.ParamBlock -or -not $ast.EndBlock) {
        throw 'The complete executing installer cannot be parsed.'
    }
    $parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    if ($parameters.Count -ne 3 -or ($parameters -join ',') -cne 'Action,ReleaseTag,InstallProfile') {
        throw 'The executing installer parameters are incomplete or ambiguous.'
    }
    foreach ($name in @('Get-WinsmuxExecutingInstallerSource', 'ConvertTo-WinsmuxLifecycleBytes',
        'Open-WinsmuxInstallLease', 'New-WinsmuxLifecycleState', 'Assert-WinsmuxLifecycleFile',
        'Publish-WinsmuxLifecycle', 'Install-VerifiedWinsmuxGeneration', 'Install-WinsmuxBinary',
        'Invoke-Install', 'Invoke-Uninstall', 'Show-Help')) {
        $definitions = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ieq $name
        }, $true))
        if ($definitions.Count -ne 1 -or $definitions[0].Name -cne $name -or
            $definitions[0].Parent -ne $ast.EndBlock) {
            throw 'The executing paired installer functions are incomplete or ambiguous.'
        }
    }
    $versions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -imatch '^(?:(?:script|global|local):)?VERSION$'
    }, $true))
    if ($versions.Count -ne 1 -or $versions[0].Parent -ne $ast.EndBlock -or
        $versions[0].Left.Extent.Text -cne '$VERSION' -or
        $versions[0].Right -isnot [Management.Automation.Language.CommandExpressionAst] -or
        $versions[0].Right.Expression -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
        throw 'The executing installer version assignment is incomplete or ambiguous.'
    }
    $main = $ast.EndBlock.Statements[-1]
    if ($main -isnot [Management.Automation.Language.SwitchStatementAst] -or
        $main.Condition.Extent.Text -cne '$releaseAction') {
        throw 'The executing installer lifecycle entry is missing.'
    }
    foreach ($action in @('install', 'update', 'uninstall')) {
        $clauses = @($main.Clauses | Where-Object { $_.Item1.Extent.Text.Trim('"', "'") -ieq $action })
        $expected = switch ($action) {
            'install' { '{ Invoke-Install }' }
            'update' { '{ Invoke-Install -IsUpdate }' }
            'uninstall' { '{ Invoke-Uninstall }' }
        }
        if ($clauses.Count -ne 1 -or $clauses[0].Item1.Extent.Text.Trim('"', "'") -cne $action -or
            $clauses[0].Item2.Extent.Text -cne $expected) {
            throw 'The executing installer lifecycle entry is ambiguous.'
        }
    }
    # AST offsets replace only the one literal. No selected-tag installer body,
    # environment bypass, or regex over the rest of the executing source is used.
    $literal = $versions[0].Right.Expression.Extent
    $updated = $Source.Substring(0, $literal.StartOffset) + '"' + $Version + '"' + $Source.Substring($literal.EndOffset)
    $checkTokens = $null; $checkErrors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($updated, [ref]$checkTokens, [ref]$checkErrors)
    if ($checkErrors.Count) { throw 'The version-adjusted lifecycle body cannot be parsed.' }
    return ,([Text.UTF8Encoding]::new($false, $true).GetBytes($updated))
}

function Initialize-WinsmuxInstallPathInfo {
    if ('Winsmux.InstallPathInfo' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Winsmux {
    public sealed class InstallPathInfo {
        public string Name, Identity;
        public uint Links, Attributes;
        [StructLayout(LayoutKind.Sequential)]
        private struct Information {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint sharing,
            IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Information information);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
        public static InstallPathInfo QueryHandle(SafeFileHandle handle) {
            Information information;
            if (!GetFileInformationByHandle(handle, out information)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var name = new StringBuilder(512);
            uint length = GetFinalPathNameByHandleW(handle, name, (uint)name.Capacity, 1);
            if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (length >= name.Capacity) {
                name = new StringBuilder(checked((int)length + 1));
                length = GetFinalPathNameByHandleW(handle, name, (uint)name.Capacity, 1);
                if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (length >= name.Capacity) throw new InvalidOperationException("Physical path size changed.");
            }
            string finalName = name.ToString();
            if (!finalName.StartsWith(@"\\?\Volume{", StringComparison.OrdinalIgnoreCase) ||
                (information.Attributes & 0x400) != 0) throw new InvalidOperationException("Unsupported physical path.");
            return new InstallPathInfo { Name=finalName, Links=information.Links, Attributes=information.Attributes,
                Identity=information.Volume.ToString("x8") + ":" + information.IndexHigh.ToString("x8") + information.IndexLow.ToString("x8") };
        }
        public static InstallPathInfo Query(string path) {
            using (var handle = CreateFileW(@"\\?\" + path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                return QueryHandle(handle);
            }
        }
    }
}
'@
}

function Assert-WinsmuxInstallPath {
    param([string]$Path, [ValidateSet('File', 'Directory', 'Either')][string]$Kind = 'Either', [switch]$AllowMissing)
    if (-not $IsWindows) { throw 'Paired Core installation requires Windows.' }
    $raw = $Path.Replace('/', '\')
    if ($raw -notmatch '^[A-Za-z]:\\' -or $raw -match '^\\') { throw 'Installer paths require an ordinary absolute local drive path.' }
    foreach ($part in $raw.Substring(3).Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($part -match '[<>:"|?*\x00-\x1f]' -or $part -match '[. ]$' -or
            $part -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)' -or $part -in @('.', '..')) {
            throw 'Unsupported installer path component.'
        }
    }
    Initialize-WinsmuxInstallPathInfo
    $full = [IO.Path]::GetFullPath($raw)
    $current = $full; $first = $true; $information = $null
    while ($current) {
        $missing = $false
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException] { $missing = $true }
        catch [IO.DirectoryNotFoundException] { $missing = $true }
        if ($missing) {
            if (-not $AllowMissing) { throw "Missing protected installer path: $current" }
        } else {
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked installer path is unsupported.' }
            $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
            if (-not $first -and -not $isDirectory) { throw 'Installer path has a file ancestor.' }
            if ($first -and (($Kind -eq 'File' -and $isDirectory) -or ($Kind -eq 'Directory' -and -not $isDirectory))) {
                throw 'Protected installer path has the wrong file kind.'
            }
            $physical = [Winsmux.InstallPathInfo]::Query($current)
            if (-not $isDirectory -and $physical.Links -ne 1) { throw 'Hardlinked installer file is unsupported.' }
            if ($first) { $information = $physical }
        }
        $first = $false; $current = [IO.Path]::GetDirectoryName($current)
    }
    return $information
}

function Open-WinsmuxInstallLease {
    param([string]$LocalBin)
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Paired installation requires PowerShell 7 or later.' }
    [void](Assert-WinsmuxInstallPath $LocalBin Directory -AllowMissing)
    [void][IO.Directory]::CreateDirectory($LocalBin)
    $binInfo = Assert-WinsmuxInstallPath $LocalBin Directory
    $lockPath = Join-Path $LocalBin 'winsmux.install.lock'
    [void](Assert-WinsmuxInstallPath $lockPath File -AllowMissing)
    $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $lockInfo = [Winsmux.InstallPathInfo]::QueryHandle($stream.SafeFileHandle)
        if ($lockInfo.Links -ne 1 -or $lockInfo.Name -cne ($binInfo.Name.TrimEnd('\') + '\winsmux.install.lock')) {
            throw 'Installer lease identity is inconsistent.'
        }
        $lease = [PSCustomObject]@{ LocalBin = [IO.Path]::GetFullPath($LocalBin); Stream = $stream;
            Marker = Join-Path $LocalBin 'winsmux.install.pending.json' }
        [void](Assert-WinsmuxInstallPath $lease.Marker File -AllowMissing)
        if ([IO.File]::Exists($lease.Marker)) { throw 'An incomplete paired installation requires recovery; all pending files have been preserved.' }
        return $lease
    } catch { $stream.Dispose(); throw }
}

function Get-WinsmuxInstallSnapshot {
    param([string]$Path, [ValidateSet('File', 'Directory')][string]$Kind)
    $information = Assert-WinsmuxInstallPath $Path $Kind -AllowMissing
    $files = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($information) {
        if ($Kind -eq 'File') {
            $files.Add('', (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant())
        } else {
            $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($Path)
            while ($pending.Count) {
                $directory = $pending.Pop()
                foreach ($item in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                    $child = Assert-WinsmuxInstallPath $item
                    $relative = [IO.Path]::GetRelativePath($Path, $item).Replace('\', '/')
                    if (($child.Attributes -band [uint32][IO.FileAttributes]::Directory) -ne 0) {
                        [void]$directories.Add($relative); $pending.Push($item)
                    } else { $files.Add($relative, (Get-FileHash -LiteralPath $item -Algorithm SHA256).Hash.ToLowerInvariant()) }
                }
            }
        }
    }
    return [PSCustomObject]@{ Present = ($null -ne $information); Identity = $(if ($information) { $information.Identity } else { $null });
        Kind = $Kind; Files = $files; Directories = $directories }
}

function Assert-WinsmuxInstallSnapshot {
    param([string]$Path, $Expected)
    $actual = Get-WinsmuxInstallSnapshot $Path $Expected.Kind
    if ($actual.Present -ne $Expected.Present -or $actual.Identity -cne $Expected.Identity -or
        $actual.Files.Count -ne $Expected.Files.Count -or -not $actual.Directories.SetEquals($Expected.Directories)) {
        throw 'Protected installer state changed or could not be restored.'
    }
    foreach ($name in $Expected.Files.Keys) {
        if (-not $actual.Files.ContainsKey($name) -or $actual.Files[$name] -cne $Expected.Files[$name]) {
            throw 'Protected installer bytes changed or could not be restored.'
        }
    }
}

function Read-WinsmuxInstallOwner {
    param([string]$OwnerPath)
    $physical = Assert-WinsmuxInstallPath $OwnerPath File -AllowMissing
    if (-not $physical) { return $null }
    $owner = ConvertFrom-StrictWinsmuxJsonBytes ([IO.File]::ReadAllBytes($OwnerPath))
    Assert-WinsmuxLicenseObjectKeys $owner @{ schema='string'; canonical_name='string'; directory_identity='string'; operation_id='string';
        release_tag='string'; asset_name='string'; target='string'; executable_sha256='string'; sidecar_sha256='string' }
    if ($owner.schema -cne 'winsmux-license-owner/v1' -or $owner.canonical_name -cne 'winsmux-licenses' -or
        $owner.directory_identity -cnotmatch '^[a-f0-9]{8}:[a-f0-9]{16}$' -or $owner.operation_id -cnotmatch '^[a-f0-9]{32}$' -or
        $owner.asset_name -cnotmatch '^winsmux-(x64|arm64)\.exe$' -or
        $owner.target -cnotmatch '^(x86_64|aarch64)-pc-windows-msvc$' -or
        $owner.executable_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $owner.sidecar_sha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Invalid installer ownership receipt; protected files were preserved.'
    }
    Assert-WinsmuxReleaseTag $owner.release_tag
    return $owner
}

function Get-WinsmuxInstallState {
    param($Lease)
    if (-not $Lease.Stream.CanWrite) { throw 'Installer lease is not held.' }
    $paths = [ordered]@{ licenses = Join-Path $Lease.LocalBin 'winsmux-licenses';
        owner = Join-Path $Lease.LocalBin 'winsmux-licenses.owner.json'; exe = Join-Path $Lease.LocalBin 'winsmux.exe' }
    $states = @{}
    foreach ($member in $paths.Keys) {
        $states[$member] = Get-WinsmuxInstallSnapshot $paths[$member] $(if ($member -eq 'licenses') { 'Directory' } else { 'File' })
    }
    $owner = Read-WinsmuxInstallOwner $paths.owner
    if ($states.licenses.Present -and (-not $owner -or $owner.directory_identity -cne $states.licenses.Identity)) {
        throw 'Existing license directory has no matching physical ownership receipt; it was preserved.'
    }
    $legacy = @([IO.Directory]::EnumerateFileSystemEntries($Lease.LocalBin) | Where-Object {
        [IO.Path]::GetFileName($_) -match '^winsmux\.exe\.previous-[0-9a-f]{32}$' })
    foreach ($image in $legacy) { [void](Assert-WinsmuxInstallPath $image File) }
    $detected = if ($states.exe.Present) { Get-WinsmuxCommandVersion ([PSCustomObject]@{ Source = $paths.exe }) } else { $null }
    if ((-not $states.exe.Present -and $legacy.Count -gt 1) -or ($states.exe.Present -and -not $detected -and $legacy.Count)) {
        throw 'Ambiguous legacy recovery images; canonical and previous images were preserved.'
    }
    return [PSCustomObject]@{ Paths = $paths; Snapshots = $states; Owner = $owner; Detected = $detected }
}

function Invoke-WinsmuxInstallCheckpoint {
    param([string]$Phase)
    # One observation boundary shared by the publication and failure proofs.
    Write-Verbose "Paired installation: $Phase"
}

function Write-WinsmuxInstallFile {
    param([string]$Path, [byte[]]$Bytes)
    [void](Assert-WinsmuxInstallPath $Path File -AllowMissing)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

function Move-WinsmuxInstallMember {
    param([string]$Source, [string]$Destination, [string]$Kind)
    [void](Assert-WinsmuxInstallPath $Source $Kind)
    if (Assert-WinsmuxInstallPath $Destination $Kind -AllowMissing) { throw 'Owned installer destination already exists.' }
    if ($Kind -eq 'Directory') { [IO.Directory]::Move($Source, $Destination) } else { [IO.File]::Move($Source, $Destination) }
}

function Assert-WinsmuxInstalledGeneration {
    param($Paths, $Sidecar)
    $expected = $Sidecar.Manifest
    $licenses = Get-WinsmuxInstallSnapshot $Paths.licenses Directory
    $expectedDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relative in $Sidecar.Files.Keys) {
        $ancestor = [IO.Path]::GetDirectoryName($relative.Replace('/', '\'))
        while ($ancestor) { [void]$expectedDirectories.Add($ancestor.Replace('\', '/')); $ancestor = [IO.Path]::GetDirectoryName($ancestor) }
    }
    if (-not $licenses.Present -or $licenses.Files.Count -ne $Sidecar.Files.Count -or
        -not $licenses.Directories.SetEquals($expectedDirectories)) { throw 'Installed license inventory does not match the verified sidecar.' }
    foreach ($relative in $Sidecar.Files.Keys) {
        if (-not $licenses.Files.ContainsKey($relative) -or $licenses.Files[$relative] -cne (Get-WinsmuxBytesSha256 $Sidecar.Files[$relative])) {
            throw 'Installed license bytes do not match the verified sidecar.'
        }
    }
    [void](Assert-WinsmuxInstallPath $Paths.exe File)
    if ((Get-FileHash -LiteralPath $Paths.exe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected.executable_sha256) {
        throw 'Installed executable does not match the selected release checksum.'
    }
    $installed = Get-WinsmuxCommandVersion ([PSCustomObject]@{ Source = $Paths.exe })
    if (-not $installed -or $installed.Version -cne $expected.version) { throw 'Installed executable version does not match the selected release.' }
    $owner = Read-WinsmuxInstallOwner $Paths.owner
    if (-not $owner -or $owner.directory_identity -cne $licenses.Identity -or $owner.release_tag -cne $expected.release_tag -or
        $owner.asset_name -cne $expected.asset_name -or $owner.target -cne $expected.target -or
        $owner.executable_sha256 -cne $expected.executable_sha256 -or $owner.sidecar_sha256 -cne $Sidecar.ArchiveSha256) {
        throw 'Installed ownership receipt does not match the verified generation.'
    }
    return $installed
}

function New-WinsmuxLifecycleState {
    param($Lease, [string]$Source, [string]$Version)
    if (-not $Lease.Stream.CanWrite) { throw 'Installer lease is not held.' }
    $local = [IO.Path]::GetDirectoryName($Lease.LocalBin)
    if ([IO.Path]::GetFileName($Lease.LocalBin) -ine 'bin' -or [IO.Path]::GetFileName($local) -ine '.local') {
        throw 'The lifecycle entrance requires the fixed HOME/.local/bin lease.'
    }
    $homeRoot = [IO.Path]::GetDirectoryName($local)
    $homeInfo = Assert-WinsmuxInstallPath $homeRoot Directory
    $binInfo = Assert-WinsmuxInstallPath $Lease.LocalBin Directory
    if ($homeInfo.Identity.Substring(0, 8) -cne $binInfo.Identity.Substring(0, 8)) {
        throw 'The installer directories are on different physical volumes.'
    }
    $path = Join-Path $homeRoot '.winsmux/bin/install.ps1'
    $prior = Get-WinsmuxInstallSnapshot $path File
    $bytes = ConvertTo-WinsmuxLifecycleBytes $Source $Version
    return [PSCustomObject]@{ Path = $path; Prior = $prior; Bytes = $bytes;
        Sha256 = Get-WinsmuxBytesSha256 $bytes; Version = $Version; Volume = $homeInfo.Identity.Substring(0, 8) }
}

function Assert-WinsmuxLifecycleFile {
    param($Lifecycle)
    $physical = Assert-WinsmuxInstallPath $Lifecycle.Path File
    if ($physical.Identity.Substring(0, 8) -cne $Lifecycle.Volume) { throw 'Lifecycle volume identity changed.' }
    $bytes = [IO.File]::ReadAllBytes($Lifecycle.Path)
    if ((Get-WinsmuxBytesSha256 $bytes) -cne $Lifecycle.Sha256) { throw 'The current lifecycle bytes changed.' }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $checked = ConvertTo-WinsmuxLifecycleBytes $text $Lifecycle.Version
    if ((Get-WinsmuxBytesSha256 $checked) -cne $Lifecycle.Sha256) { throw 'The persisted lifecycle body is invalid.' }
}

function Publish-WinsmuxLifecycle {
    param($Lease, $Lifecycle)
    if (-not $Lease.Stream.CanWrite) { throw 'Installer lease is not held.' }
    Assert-WinsmuxInstallSnapshot $Lifecycle.Path $Lifecycle.Prior
    if ($Lifecycle.Prior.Present -and $Lifecycle.Prior.Files[''] -ceq $Lifecycle.Sha256) {
        Assert-WinsmuxLifecycleFile $Lifecycle
        Invoke-WinsmuxInstallCheckpoint 'lifecycle-readback-complete'
        return
    }
    $directory = [IO.Path]::GetDirectoryName($Lifecycle.Path)
    [void](Assert-WinsmuxInstallPath $directory Directory -AllowMissing)
    [void][IO.Directory]::CreateDirectory($directory)
    $directoryInfo = Assert-WinsmuxInstallPath $directory Directory
    if ($directoryInfo.Identity.Substring(0, 8) -cne $Lifecycle.Volume) { throw 'Lifecycle directory volume changed.' }
    $archive = Join-Path $Lease.LocalBin ('.winsmux-lifecycle-' + [Guid]::NewGuid().ToString('N'))
    if (Assert-WinsmuxInstallPath $archive Directory -AllowMissing) { throw 'Owned lifecycle archive already exists.' }
    [void][IO.Directory]::CreateDirectory($archive)
    $stage = Join-Path $archive 'install.ps1'
    Write-WinsmuxInstallFile $stage $Lifecycle.Bytes
    Invoke-WinsmuxInstallCheckpoint 'stage-lifecycle-write'
    $staged = [PSCustomObject]@{ Path = $stage; Sha256 = $Lifecycle.Sha256; Version = $Lifecycle.Version; Volume = $Lifecycle.Volume }
    Assert-WinsmuxLifecycleFile $staged
    Invoke-WinsmuxInstallCheckpoint 'stage-lifecycle-readback'
    Assert-WinsmuxInstallSnapshot $Lifecycle.Path $Lifecycle.Prior
    if ($Lifecycle.Prior.Present) {
        Invoke-WinsmuxInstallCheckpoint 'before-park-lifecycle'
        $oldPath = Join-Path $archive 'prior-install.ps1'
        Move-WinsmuxInstallMember $Lifecycle.Path $oldPath File
        Invoke-WinsmuxInstallCheckpoint 'parked-lifecycle'
        Assert-WinsmuxInstallSnapshot $oldPath $Lifecycle.Prior
    }
    Invoke-WinsmuxInstallCheckpoint 'before-publish-lifecycle'
    Move-WinsmuxInstallMember $stage $Lifecycle.Path File
    Invoke-WinsmuxInstallCheckpoint 'published-lifecycle'
    Invoke-WinsmuxInstallCheckpoint 'before-lifecycle-readback'
    Assert-WinsmuxLifecycleFile $Lifecycle
    Invoke-WinsmuxInstallCheckpoint 'lifecycle-readback-complete'
    # This is a permanent entrance migration. On a later data failure the old
    # opaque script stays archived, never restored to the canonical entrance.
}

function Install-VerifiedWinsmuxGeneration {
    param($Lease, $State, [string]$DownloadPath, $Sidecar, [Parameter(Mandatory = $true)]$Lifecycle)
    if (-not $Lease.Stream.CanWrite) { throw 'Installer lease is not held.' }
    foreach ($member in $State.Paths.Keys) { Assert-WinsmuxInstallSnapshot $State.Paths[$member] $State.Snapshots[$member] }
    [void](Assert-WinsmuxInstallPath $DownloadPath File)
    if ((Get-FileHash -LiteralPath $DownloadPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Sidecar.Manifest.executable_sha256) {
        throw 'Executable staging checksum mismatch.'
    }
    $operation = [Guid]::NewGuid().ToString('N')
    $operationRoot = Join-Path $Lease.LocalBin ('.winsmux-install-' + $operation)
    if (Assert-WinsmuxInstallPath $operationRoot Directory -AllowMissing) { throw 'Owned installer stage already exists.' }
    [void][IO.Directory]::CreateDirectory($operationRoot)
    $stage = @{}; $backup = @{}; $rejected = @{}
    foreach ($member in $State.Paths.Keys) {
        # The CLI derives its reported command name from argv[0]. Validate the
        # public executable name inside the private stage as well as after publish.
        $stage[$member] = Join-Path $operationRoot $(if ($member -eq 'exe') { 'winsmux.exe' } else { 'new-' + $member })
        $backup[$member] = Join-Path $operationRoot ('old-' + $member)
        $rejected[$member] = Join-Path $operationRoot ('rejected-' + $member)
    }
    [void][IO.Directory]::CreateDirectory($stage.licenses)
    foreach ($relative in $Sidecar.Files.Keys) {
        Assert-WinsmuxLicenseMemberPath $relative
        $filePath = Join-Path $stage.licenses $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($filePath))
        Write-WinsmuxInstallFile $filePath $Sidecar.Files[$relative]
        Invoke-WinsmuxInstallCheckpoint 'stage-license-write'
    }
    [IO.File]::Copy($DownloadPath, $stage.exe, $false)
    Invoke-WinsmuxInstallCheckpoint 'stage-exe-write'
    $licenseIdentity = (Assert-WinsmuxInstallPath $stage.licenses Directory).Identity
    $owner = [ordered]@{ schema = 'winsmux-license-owner/v1'; canonical_name = 'winsmux-licenses';
        directory_identity = $licenseIdentity; operation_id = $operation; release_tag = $Sidecar.Manifest.release_tag;
        asset_name = $Sidecar.Manifest.asset_name; target = $Sidecar.Manifest.target;
        executable_sha256 = $Sidecar.Manifest.executable_sha256; sidecar_sha256 = $Sidecar.ArchiveSha256 }
    Write-WinsmuxInstallFile $stage.owner ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json $owner -Compress) + "`n"))
    Invoke-WinsmuxInstallCheckpoint 'stage-owner-write'
    [void](Assert-WinsmuxInstalledGeneration $stage $Sidecar)
    Invoke-WinsmuxInstallCheckpoint 'stage-readback'
    foreach ($member in $State.Paths.Keys) { Assert-WinsmuxInstallSnapshot $State.Paths[$member] $State.Snapshots[$member] }
    Publish-WinsmuxLifecycle $Lease $Lifecycle
    foreach ($member in $State.Paths.Keys) { Assert-WinsmuxInstallSnapshot $State.Paths[$member] $State.Snapshots[$member] }
    Assert-WinsmuxLifecycleFile $Lifecycle
    # Marker bytes are diagnostics only. No recovery operation trusts their paths.
    $marker = [ordered]@{ schema = 'winsmux-install-pending/v1'; operation_id = $operation }
    Write-WinsmuxInstallFile $Lease.Marker ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json $marker -Compress) + "`n"))
    $parked = [Collections.Generic.HashSet[string]]::new(); $published = [Collections.Generic.HashSet[string]]::new()
    $validated = $false; $restored = $false
    try {
        Invoke-WinsmuxInstallCheckpoint 'marker-written'
        # Licenses are complete before the new executable is published. Three
        # renames are not atomic; the marker exposes every incomplete transition.
        foreach ($member in @('licenses', 'owner', 'exe')) {
            $kind = $State.Snapshots[$member].Kind
            if ($State.Snapshots[$member].Present) {
                Invoke-WinsmuxInstallCheckpoint ('before-park-' + $member)
                Move-WinsmuxInstallMember $State.Paths[$member] $backup[$member] $kind
                [void]$parked.Add($member)
                Invoke-WinsmuxInstallCheckpoint ('parked-' + $member)
            }
            Invoke-WinsmuxInstallCheckpoint ('before-publish-' + $member)
            Move-WinsmuxInstallMember $stage[$member] $State.Paths[$member] $kind
            [void]$published.Add($member)
            Invoke-WinsmuxInstallCheckpoint ('published-' + $member)
        }
        Invoke-WinsmuxInstallCheckpoint 'before-readback'
        $installed = Assert-WinsmuxInstalledGeneration $State.Paths $Sidecar
        Assert-WinsmuxLifecycleFile $Lifecycle
        Invoke-WinsmuxInstallCheckpoint 'readback-complete'
        $validated = $true
    } catch {
        $installError = $_
        try {
            foreach ($member in @('exe', 'owner', 'licenses')) {
                $kind = $State.Snapshots[$member].Kind
                if ($published.Contains($member)) {
                    Invoke-WinsmuxInstallCheckpoint ('before-reject-' + $member)
                    Move-WinsmuxInstallMember $State.Paths[$member] $rejected[$member] $kind
                    Invoke-WinsmuxInstallCheckpoint ('rejected-' + $member)
                }
                if ($parked.Contains($member)) {
                    Invoke-WinsmuxInstallCheckpoint ('before-restore-' + $member)
                    Move-WinsmuxInstallMember $backup[$member] $State.Paths[$member] $kind
                    Invoke-WinsmuxInstallCheckpoint ('restored-' + $member)
                }
            }
            Invoke-WinsmuxInstallCheckpoint 'before-restoration-readback'
            foreach ($member in $State.Paths.Keys) { Assert-WinsmuxInstallSnapshot $State.Paths[$member] $State.Snapshots[$member] }
            Assert-WinsmuxLifecycleFile $Lifecycle
            Invoke-WinsmuxInstallCheckpoint 'restoration-readback-complete'
            $restored = $true
        } catch { throw "Paired installation failed and restoration is uncertain; marker and owned backups retained. Install: $installError; restoration: $_" }
        if ($restored) {
            Invoke-WinsmuxInstallCheckpoint 'before-marker-removal'
            [IO.File]::Delete($Lease.Marker)
        }
        throw $installError
    }
    if ($validated) {
        Invoke-WinsmuxInstallCheckpoint 'before-marker-removal'
        [IO.File]::Delete($Lease.Marker)
    }
    # Preserve the unique operation directory and all prior members. Cleanup is
    # a separate explicit operation; never unlink the shared lease or legacy files.
    return $installed
}

function Get-WinsmuxCommandVersion {
    param([Parameter(Mandatory = $true)]$CommandInfo)

    try {
        $output = (& $CommandInfo.Source -V 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        if ($output -match 'winsmux(?:-[^\s]+)?\s+(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)') {
            return [PSCustomObject]@{
                Version = $Matches.version
                Output  = $output
            }
        }
    } catch {
        return $null
    }

    return $null
}







function Get-WinsmuxReleaseHeaders {
    $headers = @{ "User-Agent" = "winsmux-installer/$VERSION" }
    $e2eGitHubAccess = if ($installerE2e) { [string]$env:WINSMUX_INSTALL_E2E_GITHUB_ACCESS } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($e2eGitHubAccess)) {
        $headers.Authorization = "Bearer $e2eGitHubAccess"
    }
    return $headers
}

function Get-WinsmuxBinaryVersionFromReleaseTag {
    param([Parameter(Mandatory = $true)][string]$ReleaseTag)

    $normalizedTag = $ReleaseTag.Trim().TrimStart('v', 'V')
    if ($normalizedTag -notmatch '^(?<binary>\d+\.\d+\.\d+)(?:\.\d+)?(?<suffix>-[0-9A-Za-z.-]+)?$') {
        throw "Unsupported winsmux release tag format: $ReleaseTag"
    }

    # A fourth numeric component is a packaging hotfix revision. The Rust
    # binary keeps the three-component product version embedded at build time.
    return $Matches['binary'] + $Matches['suffix']
}

function Resolve-WinsmuxRelease {
    $headers = Get-WinsmuxReleaseHeaders

    try {
        Write-Status "Fetching winsmux-core release ($RELEASE_LABEL)..."
        $release = Invoke-RestMethod -Uri $RELEASE_API_URL -Headers $headers -ErrorAction Stop
        Assert-WinsmuxLicenseObjectKeys $release @{ tag_name='string'; assets='array' } -AllowExtra
        Assert-WinsmuxReleaseTag $release.tag_name
        $script:ResolvedReleaseTag = $release.tag_name
        $script:ResolvedVersion = Get-WinsmuxBinaryVersionFromReleaseTag -ReleaseTag $script:ResolvedReleaseTag
        $script:EffectiveReleaseTag = $script:ResolvedReleaseTag
        $keepPipedMainScripts = $script:releaseAction -eq 'install' -and $script:isPipedInstaller -and [string]::IsNullOrWhiteSpace($script:requestedReleaseTag)
        $script:BASE_URL = if ([string]::IsNullOrWhiteSpace($script:installSourceRef) -and -not $keepPipedMainScripts) {
            "https://raw.githubusercontent.com/Sora-bluesky/winsmux/$script:ResolvedReleaseTag"
        } else {
            if ([string]::IsNullOrWhiteSpace($script:installSourceRef)) {
                "https://raw.githubusercontent.com/Sora-bluesky/winsmux/main"
            } else {
                "https://raw.githubusercontent.com/Sora-bluesky/winsmux/$script:installSourceRef"
            }
        }
        $script:RELEASE_LABEL = $script:ResolvedReleaseTag
        return $release
    } catch {
        Write-Error "[winsmux] Failed to resolve winsmux-core release: $_"
        exit 1
    }
}

function Get-UniqueWinsmuxReleaseAsset {
    param($Release, [string]$Name, [switch]$AllowAbsent)
    Assert-WinsmuxLicenseObjectKeys $Release @{ tag_name='string'; assets='array' } -AllowExtra
    foreach ($entry in $Release.assets) {
        Assert-WinsmuxLicenseObjectKeys $entry @{ name='string'; browser_download_url='string' } -AllowExtra
    }
    $matches = @($Release.assets | Where-Object { $_.name -ieq $Name })
    if ($matches.Count -eq 0 -and $AllowAbsent) { return $null }
    if ($matches.Count -ne 1 -or $matches[0].name -cne $Name -or
        [string]::IsNullOrWhiteSpace([string]$matches[0].browser_download_url)) {
        throw "Missing or ambiguous paired release asset: $Name"
    }
    return $matches[0]
}

function Read-WinsmuxReleaseChecksums {
    param([string]$Path, [string[]]$RequiredNames)
    [void](Assert-WinsmuxInstallPath $Path File)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($Path))
    if ($text.Contains([char]0) -or $text.StartsWith([string][char]0xfeff, [StringComparison]::Ordinal)) { throw 'Invalid release checksum encoding.' }
    $rows = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $exactNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $text.Split("`n")) {
        $row = $line.TrimEnd("`r")
        if (-not $row) { continue }
        if ($row -notmatch '^(?<hash>[A-Fa-f0-9]{64})[ \t]+\*?(?<name>[^\r\n]+)$') { throw 'Malformed release checksum row.' }
        $name = $Matches.name; $hash = $Matches.hash.ToLowerInvariant()
        if ($rows.ContainsKey($name)) { throw 'Ambiguous release checksum row.' }
        $rows.Add($name, $hash); [void]$exactNames.Add($name)
    }
    foreach ($name in $RequiredNames) {
        if (-not $exactNames.Contains($name)) { throw "Release checksum is missing the exact paired asset: $name" }
    }
    return ,$rows
}

function Install-WinsmuxBinary {
    param($Lease = $null)
    $localBin = Join-Path $HOME ".local/bin"
    $winsmuxExe = Join-Path $localBin "winsmux.exe"

    $ownsLease = $null -eq $Lease
    try {
        if ($ownsLease) { $Lease = Open-WinsmuxInstallLease $localBin }
        if (-not $Lease.Stream.CanWrite -or $Lease.LocalBin -ine [IO.Path]::GetFullPath($localBin)) {
            throw 'The fixed installer lease is not held by this invocation.'
        }
        $state = Get-WinsmuxInstallState $lease
        $release = Resolve-WinsmuxRelease
        $headers = Get-WinsmuxReleaseHeaders
        Assert-WinsmuxLicenseObjectKeys $release @{ tag_name='string'; assets='array' } -AllowExtra
        Assert-WinsmuxReleaseTag $release.tag_name
        $assetName = Get-PreferredReleaseAssetName
        $asset = Get-UniqueWinsmuxReleaseAsset $release $assetName -AllowAbsent
        if (-not $asset -and $assetName -ceq 'winsmux-arm64.exe') {
            Write-Warning "[winsmux] ARM64 asset not found in release $($release.tag_name). Falling back to winsmux-x64.exe and its matching licenses."
            $assetName = 'winsmux-x64.exe'
        }
        $asset = Get-UniqueWinsmuxReleaseAsset $release $assetName
        $sidecarName = $assetName + '.licenses.zip'
        $licenseAsset = Get-UniqueWinsmuxReleaseAsset $release $sidecarName
        $checksumAsset = Get-UniqueWinsmuxReleaseAsset $release 'SHA256SUMS'
        $target = if ($assetName -ceq 'winsmux-arm64.exe') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
        $lifecycle = New-WinsmuxLifecycleState $lease (Get-WinsmuxExecutingInstallerSource) $script:ResolvedVersion
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('winsmux-download-' + [Guid]::NewGuid().ToString('N'))
        if (Assert-WinsmuxInstallPath $tempRoot Directory -AllowMissing) { throw 'Owned download stage already exists.' }
        [void][IO.Directory]::CreateDirectory($tempRoot)
        $checksumsPath = Join-Path $tempRoot 'SHA256SUMS'
        $zipPath = Join-Path $tempRoot $sidecarName
        $downloadPath = Join-Path $tempRoot $assetName
        # Download evidence is retained under this unique operation path. No
        # arbitrary TEMP contents, legacy backups or fixed leases are removed.
        Invoke-RestMethod -Uri $checksumAsset.browser_download_url -Headers $headers -OutFile $checksumsPath -ErrorAction Stop
        $checksums = Read-WinsmuxReleaseChecksums $checksumsPath @($assetName, $sidecarName)
        Invoke-RestMethod -Uri $licenseAsset.browser_download_url -Headers $headers -OutFile $zipPath -ErrorAction Stop
        [void](Assert-WinsmuxInstallPath $zipPath File)
        $sidecar = Read-WinsmuxLicenseSidecar -ArchiveBytes ([IO.File]::ReadAllBytes($zipPath)) -ArchiveSha256 $checksums[$sidecarName] `
            -Version $script:ResolvedVersion -ReleaseTag $release.tag_name -AssetName $assetName -Target $target -ExecutableSha256 $checksums[$assetName]
        $matchingBinary = $state.Snapshots.exe.Present -and $state.Detected -and $state.Detected.Version -ceq $script:ResolvedVersion -and
            $state.Snapshots.exe.Files[''] -ceq $checksums[$assetName]
        $healthy = $false
        if ($matchingBinary -and $state.Owner) {
            try { [void](Assert-WinsmuxInstalledGeneration $state.Paths $sidecar); $healthy = $true }
            catch { Write-Status 'Installed licenses require paired repair.' }
        }
        if ($healthy) {
            Publish-WinsmuxLifecycle $lease $lifecycle
            [void](Assert-WinsmuxInstalledGeneration $state.Paths $sidecar)
            Assert-WinsmuxLifecycleFile $lifecycle
            Write-Status 'Installed executable and complete licenses match the verified release.'
        } else {
            if ($matchingBinary) { $downloadPath = $winsmuxExe }
            else { Invoke-RestMethod -Uri $asset.browser_download_url -Headers $headers -OutFile $downloadPath -ErrorAction Stop }
            Install-VerifiedWinsmuxGeneration $lease $state $downloadPath $sidecar $lifecycle | Out-Null
        }

        $userPath = Get-InstallUserPath
        $userPaths = @()
        if ($userPath) {
            $userPaths = $userPath -split ';' | Where-Object { $_ }
        }

        $hasLocalBin = $false
        foreach ($pathEntry in $userPaths) {
            if ($pathEntry.TrimEnd('\') -ieq $localBin.TrimEnd('\')) {
                $hasLocalBin = $true
                break
            }
        }

        if (-not $hasLocalBin) {
            $newUserPath = if ($userPath) { "$userPath;$localBin" } else { $localBin }
            Set-InstallUserPath -Value $newUserPath
            Write-Status "Added $localBin to user PATH"
        }

        if (-not (($env:Path -split ';' | Where-Object { $_.TrimEnd('\') -ieq $localBin.TrimEnd('\') }))) {
            $env:Path = if ($env:Path) { "$env:Path;$localBin" } else { $localBin }
        }

        $installed = Get-WinsmuxCommandVersion -CommandInfo ([PSCustomObject]@{ Source = $winsmuxExe })
        if (-not $installed -or $installed.Version -ne $script:ResolvedVersion) {
            $observed = if ($installed) { $installed.Output } else { 'not runnable' }
            throw "Installed binary validation failed. Expected $script:ResolvedVersion, observed: $observed"
        }
        Write-Status "Installed winsmux: $($installed.Output)"
    } catch {
        throw "[winsmux] Failed to install winsmux-core: $_"
    } finally {
        if ($ownsLease -and $lease) { $lease.Stream.Dispose() }
    }
}

function Backup-File($path) {
    if (Test-Path $path) {
        $ts   = Get-Date -Format "yyyyMMdd-HHmmss"
        $name = (Split-Path $path -Leaf) + ".$ts.bak"
        $dest = Join-Path $BACKUP_DIR $name
        Copy-Item $path $dest -Force
        Write-Status "Backed up $(Split-Path $path -Leaf) -> $dest"
    }
}

function Get-WinsmuxDownloadStatusCode {
    param([Parameter(Mandatory = $true)][Management.Automation.ErrorRecord]$ErrorRecord)

    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($null -eq $response -or $null -eq $response.Value) { return $null }
    $status = $response.Value.PSObject.Properties['StatusCode']
    if ($null -eq $status -or $null -eq $status.Value) { return $null }
    try { return [int]$status.Value } catch { return $null }
}

function Test-RetryableDownloadFailure {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $statusCode = Get-WinsmuxDownloadStatusCode $ErrorRecord
    if ($null -ne $statusCode) { return $statusCode -eq 408 -or $statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -le 599) }
    return $ErrorRecord.Exception.Message -match '(?i)timeout|timed out|connection.*reset|connection.*closed'
}

function Invoke-DownloadFileWithRetry($relativeUrl, $destPath) {
    $url = "$BASE_URL/$relativeUrl"
    Write-Status "Downloading $relativeUrl ..."
    $destParent = Split-Path -Parent $destPath
    if (-not [string]::IsNullOrWhiteSpace($destParent) -and -not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $tempPath = "$destPath.download-$([guid]::NewGuid().ToString('N')).tmp"
        try {
            Invoke-RestMethod -Uri $url -OutFile $tempPath -ErrorAction Stop
            Move-Item -LiteralPath $tempPath -Destination $destPath -Force
            return
        } catch {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            if ($attempt -ge 3 -or -not (Test-RetryableDownloadFailure $_)) { throw "[winsmux] Failed to download $url : $_" }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
}

function Download-File($relativeUrl, $destPath) {
    try { Invoke-DownloadFileWithRetry $relativeUrl $destPath }
    catch { Write-Error $_; exit 1 }
}

function Test-RemoteFileExists($relativeUrl) {
    $url = "$BASE_URL/$relativeUrl"
    try {
        Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -ErrorAction Stop | Out-Null
        return $true
    } catch {
        $statusCode = Get-WinsmuxDownloadStatusCode $_
        if ($statusCode -eq 404 -or $_.Exception.Message -match '404|Not Found') {
            return $false
        }
        Write-Error "[winsmux] Failed to probe $url : $_"
        exit 1
    }
}

function Download-OptionalFile($relativeUrl, $destPath) {
    if (Test-RemoteFileExists $relativeUrl) {
        Download-File $relativeUrl $destPath
        return
    }
    Write-Status "Skipping optional $relativeUrl; it is not present in $RELEASE_LABEL."
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Invoke-Install {
    param([switch]$IsUpdate)
    $lease = Open-WinsmuxInstallLease (Join-Path $HOME '.local/bin')
    try {
    $label = if ($IsUpdate) { "Updating" } else { "Installing" }
    $resolvedInstallProfile = Resolve-InstallProfile -PreferExisting:$IsUpdate
    Write-Status "$label winsmux with profile '$resolvedInstallProfile' ..."

    # 1. PowerShell version check
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Warning "[winsmux] PowerShell 7+ is recommended. You are running $($PSVersionTable.PSVersion). Some features may not work correctly."
    }

    # 2. Administrator check
    if (Test-Administrator) {
        Write-Warning "[winsmux] Running as Administrator is not recommended. Consider running as a normal user."
    }

    # 3. winsmux detection / install
    Install-WinsmuxBinary -Lease $lease

    # 4. Create directories
    foreach ($dir in @($WINSMUX_DIR, $BIN_DIR, $BACKUP_DIR, $SCRIPT_DIR, $BRIDGE_DIR, $BRIDGE_SCRIPTS_DIR, (Join-Path $env:APPDATA "winsmux"))) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # 5. Download & place files
    # Installed lifecycle entrypoint and winsmux-core.ps1
    # Install-WinsmuxBinary has already persisted the exact current consumer.
    Download-File "scripts/winsmux-core.ps1" (Join-Path $BIN_DIR "winsmux-core.ps1")
    Download-File "scripts/winsmux-core.ps1" (Join-Path $SCRIPT_DIR "winsmux-core.ps1")

    Install-CoreSupportScripts
    Install-InstructionPacks

    if (Test-InstallProfileContent -Profile $resolvedInstallProfile -Content "orchestration_scripts") {
        Install-OrchestraSupportScripts
    }
    if (Test-InstallProfileContent -Profile $resolvedInstallProfile -Content "vault") {
        Install-SecuritySupportScripts
    }
    if (Test-InstallProfileContent -Profile $resolvedInstallProfile -Content "local_router_artifacts") {
        Install-LocalRouterArtifacts
    }
    Remove-ProfileExcludedSupportScripts -Profile $resolvedInstallProfile

    # .winsmux.conf (backup existing)
    $confDest = Join-Path $HOME ".winsmux.conf"
    Backup-File $confDest
    Download-File ".winsmux.conf" $confDest

    # 6. Create .cmd wrappers
    $winsmuxCmd = Join-Path $BIN_DIR "winsmux.cmd"
@"
@echo off
setlocal
set "WINSMUX_RAW_EXE=%USERPROFILE%\.local\bin\winsmux.exe"
pwsh -NoProfile -File "%USERPROFILE%\.winsmux\bin\winsmux-core.ps1" %*
exit /b %ERRORLEVEL%
"@ | Set-Content -Path $winsmuxCmd -Encoding ASCII

    # 7.5. Register Windows Terminal Fragments
    Sync-WindowsTerminalFragment -Profile $resolvedInstallProfile

    # 8. Add to PATH via $PROFILE
    $profileLine = "`$env:PATH = `"$BIN_DIR;`$env:PATH`""
    $profilePath = Get-InstallPowerShellProfilePath
    if (-not (Test-Path $profilePath)) {
        $profileDir = Split-Path $profilePath -Parent
        if (-not (Test-Path $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        }
        New-Item -Path $profilePath -Force | Out-Null
    }
    $content = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    $managedProfilePattern = '(?m)^# winsmux\r?\n' + [regex]::Escape($profileLine) + '(?:\r?$)'
    if (-not $content -or $content -notmatch $managedProfilePattern) {
        Add-Content $profilePath "`n# winsmux`n$profileLine"
    }
    $env:PATH = "$BIN_DIR;$env:PATH"

    # 9. Record version
    $ResolvedVersion | Set-Content $VERSION_FILE
    $resolvedInstallProfile | Set-Content $PROFILE_FILE
    Write-InstallProfileManifest -Profile $resolvedInstallProfile -IsUpdate:$IsUpdate

    # 10. Completion message
    if ($IsUpdate) {
        Write-Host ""
        Write-Status "Updated to v$ResolvedVersion!"
        Write-Host "  winsmux: $(Join-Path $BIN_DIR 'winsmux-core.ps1')"
        Write-Host "  winsmux config:  $confDest"
        Write-Host "  install profile: $resolvedInstallProfile"
    } else {
        Write-Host ""
        Write-Status "Installed successfully! (v$ResolvedVersion)"
        Write-Host "  winsmux: $(Join-Path $BIN_DIR 'winsmux-core.ps1')"
        Write-Host "  winsmux config:  $confDest"
        Write-Host "  install profile: $resolvedInstallProfile"
        Write-Host ""
        Write-Host "Next steps:"
        if (Test-InstallProfileContent -Profile $resolvedInstallProfile -Content "orchestration_scripts") {
            Write-Host "  1. Create project config:  winsmux init"
            Write-Host "  2. Launch first run:       winsmux launch"
            Write-Host "  3. Inspect panes:          winsmux list"
        } else {
            Write-Host "  1. Start a session:        winsmux new-session -s work"
            Write-Host "  2. Inspect panes:          winsmux list"
        }
    }
    } finally { $lease.Stream.Dispose() }
}





function Invoke-Uninstall {
    $lease = Open-WinsmuxInstallLease (Join-Path $HOME '.local/bin')
    try {
    Write-Status "Uninstalling winsmux..."

    # 1. Remove ~/.winsmux
    if (Test-Path $WINSMUX_DIR) {
        Remove-Item $WINSMUX_DIR -Recurse -Force
        Write-Status "Removed $WINSMUX_DIR"
    }

    # 2. Remove ~/.winsmux.conf
    $confPath = Join-Path $HOME ".winsmux.conf"
    if (Test-Path $confPath) {
        Write-Host "[winsmux] Remove $confPath ? (winsmux config file)" -NoNewline
        Write-Host " [Y/n] " -NoNewline
        $answer = Read-Host
        if ($answer -eq '' -or $answer -match '^[Yy]') {
            Remove-Item $confPath -Force
            Write-Status "Removed $confPath"
        } else {
            Write-Status "Kept $confPath"
        }
    }

    # 3. Remove only the exact installer-owned block from $PROFILE
    $profilePath = Get-InstallPowerShellProfilePath
    if (Test-Path $profilePath) {
        $profileLine = "`$env:PATH = `"$BIN_DIR;`$env:PATH`""
        Remove-WinsmuxProfileBlock -ProfilePath $profilePath -ManagedPathLine $profileLine
        Write-Status "Cleaned $profilePath"
    }

    # 4. Remove Windows Terminal Fragments
    $fragmentDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\winsmux"
    if (Test-Path $fragmentDir) {
        Remove-Item $fragmentDir -Recurse -Force
        Write-Status "Removed Windows Terminal fragment: $fragmentDir"
    }

    # 5. Remove %APPDATA%\winsmux
    $appDataDir = Join-Path $env:APPDATA "winsmux"
    if (Test-Path $appDataDir) {
        Remove-Item $appDataDir -Recurse -Force
        Write-Status "Removed $appDataDir"
    }

    # 6. Done (winsmux binary is NOT uninstalled)
    Write-Host ""
    Write-Status "Uninstalled."
    Write-Host "  Note: winsmux itself was NOT removed. Manage it separately if needed."
    } finally { $lease.Stream.Dispose() }
}

function Show-Help {
    Write-Host @"
Usage: install.ps1 [action] [-Profile core|orchestra|security|full]

Actions:
  install     Install winsmux (default)
  update      Update to latest version
  uninstall   Remove winsmux
  version     Show version
  help        Show this help

Profiles:
  core        Runtime, wrapper scripts, PATH, and base config
  orchestra  core plus orchestration scripts and Windows Terminal profile
  security   core plus vault, redaction, and audit-oriented scripts
  full       core, orchestra, and security contents (default)
"@
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

switch ($releaseAction) {
    "install"   { Invoke-Install }
    "update"    { Invoke-Install -IsUpdate }
    "uninstall" { Invoke-Uninstall }
    "version"   { Write-Output "winsmux $VERSION" }
    "help"      { Show-Help }
    default     { Show-Help }
}
