param(
    [string]$ProjectDir = (Get-Location).Path,
    [Parameter(Mandatory = $true)][string]$RunDir,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Claude Code', 'Codex', 'Antigravity CLI', 'custom')]
    [string]$Cli,
    [string]$Model = '',
    [string]$Effort = '',
    [string]$PaneId = 'pane',
    [string]$PromptPath = '',
    [string]$PromptText = '',
    [int]$TimeoutSeconds = 900,
    [string]$EndMarker = 'BAKEOFF_ROUND_A_END',
    [string]$CommandPath = '',
    [string]$CommandArgsJson = '',
    [string[]]$CommandArgs = @(),
    [string[]]$ClaudeChannels = @(),
    [switch]$LiveProgress,
    [int]$LiveProgressIntervalSeconds = 60,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $script:Utf8NoBom
[Console]::InputEncoding = $script:Utf8NoBom
$OutputEncoding = $script:Utf8NoBom
$env:PYTHONIOENCODING = 'utf-8'
$env:LANG = 'C.UTF-8'
$env:LC_ALL = 'C.UTF-8'
$env:NO_COLOR = '1'
$env:TERM = 'xterm-256color'

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][string]$Value
    )

    [System.IO.File]::WriteAllText($Path, [string]$Value, $script:Utf8NoBom)
}

function Add-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][string]$Value
    )

    $bytes = $script:Utf8NoBom.GetBytes([string]$Value)
    $lastError = $null
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $stream = [System.IO.FileStream]::new(
                $Path,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            try {
                [void]$stream.Seek(0, [System.IO.SeekOrigin]::End)
                $stream.Write($bytes, 0, $bytes.Length)
                return
            } finally {
                $stream.Dispose()
            }
        } catch [System.IO.IOException] {
            $lastError = $_
            Start-Sleep -Milliseconds 50
        }
    }

    throw $lastError
}

function ConvertTo-SafeBakeoffName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'pane'
    }

    $trimmed = $Value.Trim()
    $safe = ($trimmed -replace '[^A-Za-z0-9._-]', '-').Trim('.')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'pane'
    }

    if (($safe -ceq $trimmed) -and ($safe -ceq $safe.ToLowerInvariant())) {
        return $safe
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($script:Utf8NoBom.GetBytes($trimmed))
    } finally {
        $sha.Dispose()
    }
    $hash = -join ($hashBytes[0..3] | ForEach-Object { $_.ToString('x2') })
    return "$safe-$hash"
}

function Resolve-BakeoffCommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ([System.IO.Path]::IsPathRooted($Name)) {
        return $Name
    }

    $commands = @(Get-Command -Name $Name -All -ErrorAction Stop)
    $executableExtensions = @('.exe', '.cmd', '.bat', '.com')

    foreach ($extension in $executableExtensions) {
        $candidate = $commands | Where-Object {
            $_.CommandType -eq 'Application' -and
            -not [string]::IsNullOrWhiteSpace([string]$_.Source) -and
            [System.IO.Path]::GetExtension([string]$_.Source).Equals($extension, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1

        if ($null -ne $candidate) {
            return [string]$candidate.Source
        }
    }

    $application = $commands | Where-Object {
        $_.CommandType -eq 'Application' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.Source)
    } | Select-Object -First 1

    if ($null -ne $application) {
        return [string]$application.Source
    }

    return $Name
}

function Get-BakeoffLineCount {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 0
    }

    $normalized = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    return @($normalized -split "`n" | Where-Object { $_ -ne '' }).Count
}

function Test-BakeoffWorkerReportedBlocked {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $normalized = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    foreach ($line in ($normalized -split "`n")) {
        if ($line -match '^\s*(?:(?:[-*+])\s+|\d+\.\s+|>\s+)*(?:[*_`~\s])*STATUS(?:[*_`~\s])*\s*:\s*(?:[*_`~\s])*BLOCKED(?:[*_`~\s])*(?:$|[\s.,;:!?)\]])') {
            return $true
        }
    }

    return $false
}

function Write-BakeoffJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    Write-Utf8File -Path $Path -Value ($Value | ConvertTo-Json -Depth 32)
}

function Write-BakeoffLiveProgress {
    param([Parameter(Mandatory = $true)][string]$Message)

    if ($LiveProgress) {
        Write-Host $Message
    }
}

function Update-BakeoffManifestExecution {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][string]$BlockedReason,
        [Parameter(Mandatory = $true)][string]$ResultFileName,
        [Parameter(Mandatory = $true)][datetime]$EndedAt
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $entry = [ordered]@{
        status         = $Status
        blocked_reason = $BlockedReason
        pane_result    = $ResultFileName
        ended_at_utc   = $EndedAt.ToUniversalTime().ToString('o')
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $stream = [System.IO.FileStream]::new(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            try {
                $reader = [System.IO.StreamReader]::new($stream, $script:Utf8NoBom, $true, 1024, $true)
                try {
                    $manifestText = $reader.ReadToEnd()
                } finally {
                    $reader.Dispose()
                }

                $manifest = $manifestText | ConvertFrom-Json -Depth 32
                $manifest | Add-Member -NotePropertyName 'ended_at_utc' -NotePropertyValue $entry.ended_at_utc -Force
                $manifest | Add-Member -NotePropertyName 'execution' -NotePropertyValue $entry -Force

                $workerExecutions = [ordered]@{}
                $existingExecutions = $manifest.PSObject.Properties['worker_executions']
                if ($null -ne $existingExecutions -and $null -ne $existingExecutions.Value) {
                    foreach ($property in $existingExecutions.Value.PSObject.Properties) {
                        $workerExecutions[$property.Name] = $property.Value
                    }
                }
                $workerExecutions[$PaneId] = $entry
                $manifest | Add-Member -NotePropertyName 'worker_executions' -NotePropertyValue $workerExecutions -Force

                $updatedBytes = $script:Utf8NoBom.GetBytes(($manifest | ConvertTo-Json -Depth 32))
                $stream.SetLength(0)
                $stream.Position = 0
                $stream.Write($updatedBytes, 0, $updatedBytes.Length)
                return
            } finally {
                $stream.Dispose()
            }
        } catch [System.IO.IOException] {
            $lastError = $_
            Start-Sleep -Milliseconds 50
        }
    }

    throw $lastError
}

function Get-BakeoffCommandLineLength {
    param(
        [Parameter(Mandatory = $true)][string]$CommandPath,
        [AllowNull()][string[]]$Arguments
    )

    $length = $CommandPath.Length
    foreach ($argument in @($Arguments)) {
        $length += 3 + ([string]$argument).Length
    }
    return $length
}

function Get-BakeoffTaskText {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutMilliseconds = 5000
    )

    if ($Task.Wait($TimeoutMilliseconds)) {
        return [string]$Task.Result
    }

    $script:ReadTimedOut = $true
    return "BAKEOFF_STREAM_READ_TIMEOUT $Name"
}

function Initialize-BakeoffProcessIo {
    if ('WinsmuxBakeoffProcessIo' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading.Tasks;

public static class WinsmuxBakeoffProcessIo
{
    public static Task WriteAndCloseAsync(TextWriter writer, string text)
    {
        if (writer == null)
        {
            return Task.CompletedTask;
        }

        return Task.Run(async () =>
        {
            try
            {
                await writer.WriteAsync(text ?? String.Empty).ConfigureAwait(false);
                await writer.FlushAsync().ConfigureAwait(false);
            }
            finally
            {
                try
                {
                    writer.Close();
                }
                catch
                {
                }
            }
        });
    }
}
'@
}

function Start-BakeoffStdinWrite {
    param(
        [Parameter(Mandatory = $true)][System.IO.TextWriter]$Writer,
        [AllowNull()][string]$Text
    )

    Initialize-BakeoffProcessIo
    return [WinsmuxBakeoffProcessIo]::WriteAndCloseAsync($Writer, [string]$Text)
}

function Wait-BakeoffVoidTask {
    param(
        [AllowNull()]$Task,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutMilliseconds = 5000
    )

    if ($null -eq $Task) {
        return ''
    }

    try {
        if ($Task.Wait($TimeoutMilliseconds)) {
            if ($Task.IsFaulted) {
                return $Task.Exception.GetBaseException().Message
            }
            if ($Task.IsCanceled) {
                return "${Name}_task_canceled"
            }
            return ''
        }
    } catch {
        return $_.Exception.GetBaseException().Message
    }

    $script:StdinWriteTimedOut = $true
    return "BAKEOFF_STDIN_WRITE_TIMEOUT $Name"
}

function Copy-AntigravityHarnessConfig {
    param(
        [Parameter(Mandatory = $true)][string]$SourceHome,
        [Parameter(Mandatory = $true)][string]$DestinationHome
    )

    $sourceGemini = Join-Path $SourceHome '.gemini'
    $destinationGemini = Join-Path $DestinationHome '.gemini'
    New-Item -ItemType Directory -Path $destinationGemini -Force | Out-Null
    if (-not (Test-Path -LiteralPath $sourceGemini -PathType Container)) {
        return $false
    }

    $topLevelFiles = @(
        'google_accounts.json',
        'installation_id',
        'projects.json',
        'settings.json',
        'state.json',
        'trustedFolders.json'
    )
    foreach ($fileName in $topLevelFiles) {
        $sourcePath = Join-Path $sourceGemini $fileName
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $destinationGemini $fileName) -Force
        }
    }

    $sourceCli = Join-Path $sourceGemini 'antigravity-cli'
    $destinationCli = Join-Path $destinationGemini 'antigravity-cli'
    New-Item -ItemType Directory -Path $destinationCli -Force | Out-Null
    $cliFiles = @(
        'installation_id',
        'keybindings.json',
        'settings.json'
    )
    foreach ($fileName in $cliFiles) {
        $sourcePath = Join-Path $sourceCli $fileName
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $destinationCli $fileName) -Force
        }
    }

    return $true
}

function Clear-AntigravityHarnessCustomization {
    param([Parameter(Mandatory = $true)][string]$HomeDir)

    $pathsToRemove = @(
        '.gemini\GEMINI.md',
        '.gemini\AGENTS.md',
        '.agents\AGENTS.md',
        '.agents\agents.md',
        '.gemini\antigravity-cli\plugins',
        '.gemini\antigravity-cli\skills'
    )

    foreach ($relativePath in $pathsToRemove) {
        $path = Join-Path $HomeDir $relativePath
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

function Write-AntigravityHarnessMcpConfig {
    param([Parameter(Mandatory = $true)][string]$HomeDir)

    $emptyMcpConfig = [ordered]@{
        mcpServers = [ordered]@{}
    }
    $configPaths = @(
        '.gemini\config\mcp_config.json',
        '.gemini\antigravity-cli\mcp_config.json',
        '.agents\mcp_config.json'
    )

    foreach ($relativePath in $configPaths) {
        $configPath = Join-Path $HomeDir $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
        Write-BakeoffJson -Path $configPath -Value $emptyMcpConfig
    }

    $migrationMarkerPath = Join-Path $HomeDir '.gemini\config\.migrated'
    New-Item -ItemType Directory -Path (Split-Path -Parent $migrationMarkerPath) -Force | Out-Null
    Set-Content -LiteralPath $migrationMarkerPath -Value 'winsmux-bakeoff' -Encoding UTF8
}

function Initialize-AntigravityBakeoffHome {
    param(
        [Parameter(Mandatory = $true)][string]$RunDir,
        [Parameter(Mandatory = $true)][string]$SafePaneId,
        [AllowNull()][string]$Model
    )

    $homeDir = Join-Path $RunDir "$SafePaneId-antigravity-home"
    if (Test-Path -LiteralPath $homeDir) {
        Remove-Item -LiteralPath $homeDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $homeDir -Force | Out-Null

    $sourceHome = if (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
        $env:HOME
    } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $env:USERPROFILE
    } else {
        ''
    }

    $copiedGeminiConfig = $false
    if (-not [string]::IsNullOrWhiteSpace($sourceHome)) {
        $copiedGeminiConfig = Copy-AntigravityHarnessConfig -SourceHome $sourceHome -DestinationHome $homeDir
    } else {
        New-Item -ItemType Directory -Path (Join-Path $homeDir '.gemini') -Force | Out-Null
    }

    Clear-AntigravityHarnessCustomization -HomeDir $homeDir
    Write-AntigravityHarnessMcpConfig -HomeDir $homeDir

    $requestedModel = if ([string]::IsNullOrWhiteSpace($Model)) {
        'Gemini 3.5 Flash (High)'
    } else {
        [string]$Model
    }

    $configPath = Join-Path $homeDir '.gemini\antigravity-cli\settings.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
    $config = [ordered]@{}
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $existingConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
            foreach ($property in $existingConfig.PSObject.Properties) {
                $config[$property.Name] = $property.Value
            }
        } catch {
            $config = [ordered]@{}
        }
    }
    $config['model'] = $requestedModel
    $config['enableTerminalSandbox'] = $false
    Write-BakeoffJson -Path $configPath -Value $config

    return [ordered]@{
        home_dir             = $homeDir
        config_path          = $configPath
        requested_model      = $requestedModel
        copied_gemini_config = $copiedGeminiConfig
    }
}

function Invoke-BakeoffCommandVersion {
    param(
        [Parameter(Mandatory = $true)][string]$CommandPath,
        [string[]]$Arguments = @('--version'),
        [hashtable]$Environment = @{},
        [int]$TimeoutMilliseconds = 10000
    )

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo.FileName = $CommandPath
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = $script:Utf8NoBom
    $process.StartInfo.StandardErrorEncoding = $script:Utf8NoBom
    foreach ($argument in $Arguments) {
        [void]$process.StartInfo.ArgumentList.Add([string]$argument)
    }
    foreach ($key in $Environment.Keys) {
        $process.StartInfo.Environment[$key] = [string]$Environment[$key]
    }

    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutMilliseconds)
        if ($timedOut) {
            try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
            [void]$process.WaitForExit(2000)
        }

        return [ordered]@{
            command   = $CommandPath
            arguments = @($Arguments)
            stdout    = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { 'BAKEOFF_VERSION_STDOUT_READ_TIMEOUT' }
            stderr    = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { 'BAKEOFF_VERSION_STDERR_READ_TIMEOUT' }
            exit_code = if ($timedOut) { $null } else { $process.ExitCode }
            timed_out = $timedOut
        }
    } catch {
        return [ordered]@{
            command   = $CommandPath
            arguments = @($Arguments)
            stdout    = ''
            stderr    = $_.Exception.Message
            exit_code = $null
            timed_out = $false
        }
    } finally {
        $process.Dispose()
    }
}

function Get-ClaudeBakeoffChannelToolDenyList {
    return @(
        'mcp__telegram__reply',
        'mcp__telegram__react',
        'mcp__telegram__edit_message',
        'mcp__plugin_telegram_telegram__reply',
        'mcp__plugin_telegram_telegram__react',
        'mcp__plugin_telegram_telegram__edit_message'
    )
}

function Get-ClaudeBakeoffLocalSideEffectToolDenyList {
    return @(
        'mcp__voicevox__speak',
        'mcp__voicevox__play_category'
    )
}

function Get-AntigravityLogEvidence {
    param([AllowNull()][string]$LogText)

    $selectedModel = ''
    $generatedTextLength = $null
    if (-not [string]::IsNullOrWhiteSpace($LogText)) {
        $modelMatch = [regex]::Match($LogText, 'Resolving model\s+([^\r\n]+)')
        if ($modelMatch.Success) {
            $selectedModel = $modelMatch.Groups[1].Value.Trim()
        } else {
            $metadataModelMatch = [regex]::Match(
                $LogText,
                '(?im)^\s*(?:model|selected_model)\s*:\s*(Gemini\s+[0-9.]+\s+[A-Za-z]+(?:\s+\([^)]+\))?)\s*$'
            )
            if ($metadataModelMatch.Success) {
                $selectedModel = $metadataModelMatch.Groups[1].Value.Trim()
            } else {
                $labelModelMatch = [regex]::Match(
                    $LogText,
                    'model_config_manager\.go.*?label="([^"]+)"'
                )
                if ($labelModelMatch.Success) {
                    $selectedModel = $labelModelMatch.Groups[1].Value.Trim()
                }
            }
        }

        $lengthMatch = [regex]::Match($LogText, 'text_drip\.go.*?length=(\d+)')
        if ($lengthMatch.Success) {
            $generatedTextLength = [int]$lengthMatch.Groups[1].Value
        }
    }

    return [ordered]@{
        selected_model        = $selectedModel
        generated_text_length = $generatedTextLength
        has_generated_text    = ($null -ne $generatedTextLength -and $generatedTextLength -gt 0)
    }
}

function Get-AntigravityTranscriptOutput {
    param([AllowNull()][string]$HomeDir)

    if ([string]::IsNullOrWhiteSpace($HomeDir) -or -not (Test-Path -LiteralPath $HomeDir -PathType Container)) {
        return [ordered]@{
            content = ''
            path    = ''
        }
    }

    $cliRoot = Join-Path $HomeDir '.gemini\antigravity-cli'
    if (-not (Test-Path -LiteralPath $cliRoot -PathType Container)) {
        return [ordered]@{
            content = ''
            path    = ''
        }
    }

    $transcripts = @(
        Get-ChildItem -LiteralPath $cliRoot -Recurse -Filter 'transcript.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending
    )
    foreach ($transcript in $transcripts) {
        $modelContents = @()
        foreach ($line in (Get-Content -LiteralPath $transcript.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $entry = $line | ConvertFrom-Json -Depth 16
            } catch {
                continue
            }
            if (
                [string]$entry.source -eq 'MODEL' -and
                [string]$entry.status -eq 'DONE' -and
                -not [string]::IsNullOrWhiteSpace([string]$entry.content)
            ) {
                $modelContents += [string]$entry.content
            }
        }

        $content = ($modelContents -join "`n").Trim()
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            return [ordered]@{
                content = $content
                path    = [string]$transcript.FullName
            }
        }
    }

    return [ordered]@{
        content = ''
        path    = ''
    }
}

function Add-BakeoffHostRustEnvironment {
    param([Parameter(Mandatory = $true)][hashtable]$Environment)

    $hostUserProfile = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        [string]$env:USERPROFILE
    } elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
        [string]$env:HOME
    } else {
        ''
    }

    $cargoHome = if (-not [string]::IsNullOrWhiteSpace($env:CARGO_HOME)) {
        [string]$env:CARGO_HOME
    } elseif (-not [string]::IsNullOrWhiteSpace($hostUserProfile)) {
        Join-Path $hostUserProfile '.cargo'
    } else {
        ''
    }
    if (-not [string]::IsNullOrWhiteSpace($cargoHome) -and (Test-Path -LiteralPath $cargoHome -PathType Container)) {
        $Environment['CARGO_HOME'] = $cargoHome
        $cargoBin = Join-Path $cargoHome 'bin'
        if (Test-Path -LiteralPath $cargoBin -PathType Container) {
            $pathValue = if (-not [string]::IsNullOrWhiteSpace($env:Path)) {
                [string]$env:Path
            } else {
                [string]$env:PATH
            }
            $pathParts = @($pathValue -split [regex]::Escape([System.IO.Path]::PathSeparator))
            $hasCargoBin = $false
            foreach ($part in $pathParts) {
                if ([string]::Equals($part.TrimEnd('\'), $cargoBin.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
                    $hasCargoBin = $true
                    break
                }
            }
            $Environment['Path'] = if ($hasCargoBin) {
                $pathValue
            } else {
                "$cargoBin$([System.IO.Path]::PathSeparator)$pathValue"
            }
        }
    }

    $rustupHome = if (-not [string]::IsNullOrWhiteSpace($env:RUSTUP_HOME)) {
        [string]$env:RUSTUP_HOME
    } elseif (-not [string]::IsNullOrWhiteSpace($hostUserProfile)) {
        Join-Path $hostUserProfile '.rustup'
    } else {
        ''
    }
    if (-not [string]::IsNullOrWhiteSpace($rustupHome) -and (Test-Path -LiteralPath $rustupHome -PathType Container)) {
        $Environment['RUSTUP_HOME'] = $rustupHome
    }
}

function Get-BakeoffHostCargoPath {
    param([Parameter(Mandatory = $true)][hashtable]$Environment)

    $candidatePaths = @()
    if ($Environment.ContainsKey('CARGO_HOME') -and -not [string]::IsNullOrWhiteSpace([string]$Environment['CARGO_HOME'])) {
        $candidatePaths += (Join-Path ([string]$Environment['CARGO_HOME']) 'bin\cargo.exe')
        $candidatePaths += (Join-Path ([string]$Environment['CARGO_HOME']) 'bin\cargo')
    }

    $cargoCommand = Get-Command -Name 'cargo.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $cargoCommand) {
        $cargoCommand = Get-Command -Name 'cargo' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -ne $cargoCommand -and -not [string]::IsNullOrWhiteSpace([string]$cargoCommand.Source)) {
        $candidatePaths += [string]$cargoCommand.Source
    }

    foreach ($candidatePath in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidatePath) -and (Test-Path -LiteralPath ([string]$candidatePath) -PathType Leaf)) {
            return (Resolve-Path -LiteralPath ([string]$candidatePath)).Path
        }
    }

    return ''
}

function Add-AntigravityToolchainPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][hashtable]$Environment
    )

    $cargoPath = Get-BakeoffHostCargoPath -Environment $Environment
    if ([string]::IsNullOrWhiteSpace($cargoPath)) {
        return $Prompt
    }

    $cargoBin = Split-Path -Parent $cargoPath
    $toolchainPrompt = @"

## Windows toolchain bootstrap for Antigravity CLI

Antigravity CLI may run tool and subagent commands in a PowerShell context that does not reliably resolve user PATH entries.
For Rust checks in this benchmark, do not call bare cargo.
Use the host cargo executable exactly as:

$cargoPath

PowerShell command shape:

& '$cargoPath' test --lib

If you must use PATH lookup inside a command, first prepend the cargo bin directory in the same command:

`$env:Path = '$cargoBin;' + `$env:Path; & '$cargoPath' test --lib
"@

    return "$Prompt`n$toolchainPrompt"
}

if ($TimeoutSeconds -lt 1) {
    throw 'TimeoutSeconds must be greater than zero.'
}
if ($LiveProgressIntervalSeconds -lt 1) {
    throw 'LiveProgressIntervalSeconds must be greater than zero.'
}

$normalizedClaudeChannels = @(
    $ClaudeChannels |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }
)

$resolvedProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
$resolvedRunDir = (Resolve-Path -LiteralPath $RunDir).Path
$safePaneId = ConvertTo-SafeBakeoffName -Value $PaneId

if (-not [string]::IsNullOrWhiteSpace($PromptPath)) {
    $prompt = Get-Content -LiteralPath (Resolve-Path -LiteralPath $PromptPath).Path -Raw -Encoding UTF8
} elseif (-not [string]::IsNullOrWhiteSpace($PromptText)) {
    $prompt = $PromptText
} else {
    throw 'PromptPath or PromptText is required.'
}

$writesPromptToStdin = $true
$processWorkingDirectory = $resolvedProjectDir
$processEnvironment = @{
    WINSMUX_BAKEOFF_WORKSPACE = $resolvedProjectDir
}
Add-BakeoffHostRustEnvironment -Environment $processEnvironment
$versionCommandPath = ''
$versionCommandArguments = @('--version')
$antigravityMetadata = $null
$antigravityLogPath = ''
$codexLastMessagePath = ''
switch ($Cli) {
    'Claude Code' {
        $resolvedCommandPath = Resolve-BakeoffCommand -Name 'claude'
        $processWorkingDirectory = $resolvedRunDir
        $claudeDeniedTools = @(Get-ClaudeBakeoffLocalSideEffectToolDenyList)
        if (@($normalizedClaudeChannels).Count -eq 0) {
            $claudeDeniedTools += @(Get-ClaudeBakeoffChannelToolDenyList)
        }
        $arguments = @(
            '--print',
            '--dangerously-skip-permissions',
            '--output-format', 'text',
            '--no-session-persistence',
            '--disallowedTools', ($claudeDeniedTools -join ','),
            '--add-dir', $resolvedProjectDir
        )
        if (@($normalizedClaudeChannels).Count -gt 0) {
            $arguments += @('--channels')
            $arguments += @($normalizedClaudeChannels)
        }
        if (-not [string]::IsNullOrWhiteSpace($Model)) {
            $arguments += @('--model', $Model)
        }
        if (-not [string]::IsNullOrWhiteSpace($Effort)) {
            $arguments += @('--effort', $Effort)
        }
        $arguments += @($prompt)
        $writesPromptToStdin = $false
    }
    'Codex' {
        if ([string]::IsNullOrWhiteSpace($Model)) {
            throw 'Model is required for Codex runs.'
        }
        $codexLastMessagePath = Join-Path $resolvedRunDir "$safePaneId-codex-last-message.txt"
        if (Test-Path -LiteralPath $codexLastMessagePath -PathType Leaf) {
            Remove-Item -LiteralPath $codexLastMessagePath -Force
        }
        $codexEntrypoint = ''
        $codexShim = Get-Command -Name 'codex.cmd' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $codexShim -and -not [string]::IsNullOrWhiteSpace([string]$codexShim.Source)) {
            $candidateEntrypoint = Join-Path (Split-Path -Parent ([string]$codexShim.Source)) 'node_modules\@openai\codex\bin\codex.js'
            if (Test-Path -LiteralPath $candidateEntrypoint -PathType Leaf) {
                $codexEntrypoint = $candidateEntrypoint
                $versionCommandPath = [string]$codexShim.Source
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($codexEntrypoint)) {
            $resolvedCommandPath = Resolve-BakeoffCommand -Name 'node'
            $baseArguments = @($codexEntrypoint, 'exec')
        } else {
            $resolvedCommandPath = Resolve-BakeoffCommand -Name 'codex'
            $baseArguments = @('exec')
        }

        $arguments = @($baseArguments) + @(
            '-C', $resolvedProjectDir,
            '-m', $Model,
            '-s', 'workspace-write',
            '--color', 'never',
            '-o', $codexLastMessagePath,
            '--ephemeral',
            '--ignore-user-config',
            '--ignore-rules',
            $prompt
        )
        if (-not [string]::IsNullOrWhiteSpace($Effort)) {
            $arguments = @($baseArguments) + @(
                '-C', $resolvedProjectDir,
                '-m', $Model,
                '-c', "model_reasoning_effort=$Effort",
                '-s', 'workspace-write',
                '--color', 'never',
                '-o', $codexLastMessagePath,
                '--ephemeral',
                '--ignore-user-config',
                '--ignore-rules',
                $prompt
            )
        }
        $writesPromptToStdin = $false
    }
    'Antigravity CLI' {
        $resolvedCommandPath = Resolve-BakeoffCommand -Name 'agy'
        $antigravityMetadata = Initialize-AntigravityBakeoffHome -RunDir $resolvedRunDir -SafePaneId $safePaneId -Model $Model
        $prompt = Add-AntigravityToolchainPrompt -Prompt $prompt -Environment $processEnvironment
        $antigravityLogPath = Join-Path $resolvedRunDir "$safePaneId-antigravity.log"
        if (Test-Path -LiteralPath $antigravityLogPath -PathType Leaf) {
            Remove-Item -LiteralPath $antigravityLogPath -Force
        }
        $processEnvironment['HOME'] = [string]$antigravityMetadata.home_dir
        $processEnvironment['USERPROFILE'] = [string]$antigravityMetadata.home_dir
        $arguments = @(
            '--dangerously-skip-permissions',
            '--log-file',
            $antigravityLogPath,
            '--add-dir', $resolvedProjectDir,
            '--print-timeout', "${TimeoutSeconds}s",
            '-p', $prompt
        )
        $writesPromptToStdin = $false
    }
    'custom' {
        if ([string]::IsNullOrWhiteSpace($CommandPath)) {
            throw 'CommandPath is required for custom runs.'
        }
        $resolvedCommandPath = Resolve-BakeoffCommand -Name $CommandPath
        if (-not [string]::IsNullOrWhiteSpace($CommandArgsJson)) {
            $parsedCommandArgs = $CommandArgsJson | ConvertFrom-Json -Depth 8
            $arguments = @($parsedCommandArgs | ForEach-Object { [string]$_ })
        } else {
            $arguments = @($CommandArgs)
        }
    }
}

$stdoutPath = Join-Path $resolvedRunDir "$safePaneId-stdout.txt"
$stderrPath = Join-Path $resolvedRunDir "$safePaneId-stderr.txt"
$paneTranscriptPath = Join-Path $resolvedRunDir "$safePaneId-pane-transcript.txt"
$resultPath = Join-Path $resolvedRunDir "$safePaneId-result.json"
$combinedTranscriptPath = Join-Path $resolvedRunDir 'pane-transcript.txt'
$commandsPath = Join-Path $resolvedRunDir 'commands.jsonl'

$startedAt = (Get-Date).ToUniversalTime()
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$timedOut = $false
$completedFromAntigravityTranscript = $false
$script:ReadTimedOut = $false
$script:StdinWriteTimedOut = $false
$processStartError = ''
$commandLineTooLong = $false
$stdout = ''
$stderr = ''
$stdoutSource = 'process_stdout'
$antigravityTranscriptPath = ''
$stdinWriteError = ''
$exitCode = $null
$commandLineLength = Get-BakeoffCommandLineLength -CommandPath $resolvedCommandPath -Arguments $arguments
$streamReadStrategy = 'async_read_before_wait'
$stdinWriteStrategy = 'async_write_with_process_timeout'
if ([string]::IsNullOrWhiteSpace($versionCommandPath)) {
    $versionCommandPath = $resolvedCommandPath
}
$commandVersion = Invoke-BakeoffCommandVersion -CommandPath $versionCommandPath -Arguments $versionCommandArguments -Environment $processEnvironment

if ($commandLineLength -gt 30000) {
    $commandLineTooLong = $true
    $stderr = "Command line is too long for a reliable Windows launch: $commandLineLength characters."
} else {
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo.FileName = $resolvedCommandPath
    $process.StartInfo.WorkingDirectory = $processWorkingDirectory
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.StandardOutputEncoding = $script:Utf8NoBom
    $process.StartInfo.StandardErrorEncoding = $script:Utf8NoBom
    foreach ($argument in $arguments) {
        [void]$process.StartInfo.ArgumentList.Add([string]$argument)
    }
    foreach ($key in $processEnvironment.Keys) {
        $process.StartInfo.Environment[$key] = [string]$processEnvironment[$key]
    }

    try {
        $started = $process.Start()
        Write-BakeoffLiveProgress -Message ("BAKEOFF_LAUNCH {0} child_pid={1} cli={2} model={3} effort={4}" -f $PaneId, $process.Id, $Cli, $Model, $Effort)
        Write-BakeoffLiveProgress -Message ("BAKEOFF_WAITING_NOTE {0} progress_lines_are_heartbeat=true no_restart=true" -f $PaneId)
        # Start both readers before waiting for process exit. Some CLIs can fill
        # the pipe buffer and block forever if stdout/stderr are read later.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $stdinTask = $null
        if ($writesPromptToStdin) {
            $stdinPayload = $prompt
            if (-not $stdinPayload.EndsWith("`n")) {
                $stdinPayload += "`n"
            }
            $stdinTask = Start-BakeoffStdinWrite -Writer $process.StandardInput -Text $stdinPayload
        } else {
            $process.StandardInput.Close()
        }

        $lastProgressSecond = -1
        $lastAntigravityTranscriptProbeSecond = -1
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 1000
            $elapsed = [int][Math]::Floor($stopwatch.Elapsed.TotalSeconds)
            if ($LiveProgress) {
                if ($elapsed -gt 0 -and ($elapsed % $LiveProgressIntervalSeconds -eq 0) -and $elapsed -ne $lastProgressSecond) {
                    Write-BakeoffLiveProgress -Message ("BAKEOFF_WAITING {0} elapsed={1}s child_pid={2} still_running=true no_restart=true waiting_for={3}" -f $PaneId, $elapsed, $process.Id, $Cli)
                    $lastProgressSecond = $elapsed
                }
            }
            if (
                $Cli -eq 'Antigravity CLI' -and
                $null -ne $antigravityMetadata -and
                -not [string]::IsNullOrWhiteSpace($EndMarker) -and
                $elapsed -gt 0 -and
                ($elapsed % 5 -eq 0) -and
                $elapsed -ne $lastAntigravityTranscriptProbeSecond
            ) {
                $lastAntigravityTranscriptProbeSecond = $elapsed
                $transcriptProbe = Get-AntigravityTranscriptOutput -HomeDir ([string]$antigravityMetadata.home_dir)
                if (
                    -not [string]::IsNullOrWhiteSpace([string]$transcriptProbe.content) -and
                    ([string]$transcriptProbe.content).Contains($EndMarker)
                ) {
                    $completedFromAntigravityTranscript = $true
                    $antigravityTranscriptPath = [string]$transcriptProbe.path
                    Write-BakeoffLiveProgress -Message ("BAKEOFF_ANTIGRAVITY_TRANSCRIPT_COMPLETE {0} elapsed={1}s child_pid={2}" -f $PaneId, $elapsed, $process.Id)
                    try {
                        $process.Kill($true)
                    } catch {
                        try { $process.Kill() } catch {}
                    }
                    [void]$process.WaitForExit(5000)
                    break
                }
            }
        }

        if (-not $process.HasExited) {
            $timedOut = $true
            try {
                $process.Kill($true)
            } catch {
                try { $process.Kill() } catch {}
            }
            [void]$process.WaitForExit(5000)
        } else {
            [void]$process.WaitForExit(5000)
        }

        $stdinWriteError = Wait-BakeoffVoidTask -Task $stdinTask -Name 'stdin'
        $stdout = Get-BakeoffTaskText -Task $stdoutTask -Name 'stdout'
        $stderr = Get-BakeoffTaskText -Task $stderrTask -Name 'stderr'
        if (
            $Cli -eq 'Codex' -and
            -not [string]::IsNullOrWhiteSpace($codexLastMessagePath) -and
            (Test-Path -LiteralPath $codexLastMessagePath -PathType Leaf)
        ) {
            $codexLastMessage = Get-Content -LiteralPath $codexLastMessagePath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($codexLastMessage)) {
                $stdout = $codexLastMessage
                if (-not $stdout.EndsWith("`n")) {
                    $stdout += "`n"
                }
                $stdoutSource = 'codex_output_last_message'
                $script:ReadTimedOut = $false
                if ($stderr -like 'BAKEOFF_STREAM_READ_TIMEOUT*') {
                    $stderr = ''
                }
            }
        }
        $exitCode = if ($completedFromAntigravityTranscript) { 0 } elseif ($timedOut) { $null } else { $process.ExitCode }
        Write-BakeoffLiveProgress -Message ("BAKEOFF_EXIT {0} child_pid={1} exit_code={2}" -f $PaneId, $process.Id, $(if ($null -eq $exitCode) { 'timeout_or_unknown' } else { [string]$exitCode }))
    } catch {
        $processStartError = $_.Exception.Message
        $stderr = "Process start failed: $processStartError"
        try {
            if ($null -ne $process -and -not $process.HasExited) {
                $process.Kill($true)
            }
        } catch {}
    }
}

$stopwatch.Stop()
$endedAt = (Get-Date).ToUniversalTime()

$antigravityLog = ''
if (-not [string]::IsNullOrWhiteSpace($antigravityLogPath) -and (Test-Path -LiteralPath $antigravityLogPath -PathType Leaf)) {
    $antigravityLog = Get-Content -LiteralPath $antigravityLogPath -Raw -Encoding UTF8
}
$antigravityTranscriptOutput = if ($Cli -eq 'Antigravity CLI' -and $null -ne $antigravityMetadata) {
    Get-AntigravityTranscriptOutput -HomeDir ([string]$antigravityMetadata.home_dir)
} else {
    [ordered]@{ content = ''; path = '' }
}
if ($Cli -eq 'Antigravity CLI' -and ($completedFromAntigravityTranscript -or [string]::IsNullOrWhiteSpace($stdout)) -and -not [string]::IsNullOrWhiteSpace([string]$antigravityTranscriptOutput.content)) {
    $stdout = [string]$antigravityTranscriptOutput.content
    if (-not $stdout.EndsWith("`n")) {
        $stdout += "`n"
    }
    $stdoutSource = 'antigravity_transcript_jsonl'
    $antigravityTranscriptPath = [string]$antigravityTranscriptOutput.path
}
$antigravityLogEvidence = if ($Cli -eq 'Antigravity CLI') {
    Get-AntigravityLogEvidence -LogText $antigravityLog
} else {
    $null
}
if (
    $Cli -eq 'Antigravity CLI' -and
    $null -ne $antigravityLogEvidence -and
    -not [bool]$antigravityLogEvidence.has_generated_text -and
    -not [string]::IsNullOrWhiteSpace([string]$antigravityTranscriptOutput.content)
) {
    $antigravityLogEvidence['generated_text_length'] = ([string]$antigravityTranscriptOutput.content).Length
    $antigravityLogEvidence['has_generated_text'] = $true
}

Write-Utf8File -Path $stdoutPath -Value $stdout
Write-Utf8File -Path $stderrPath -Value $stderr

$stdoutBytes = $script:Utf8NoBom.GetByteCount([string]$stdout)
$stderrBytes = $script:Utf8NoBom.GetByteCount([string]$stderr)
$antigravityLogBytes = $script:Utf8NoBom.GetByteCount([string]$antigravityLog)
$stdoutLines = Get-BakeoffLineCount -Text $stdout
$stderrLines = Get-BakeoffLineCount -Text $stderr
$endMarkerSeen = if ([string]::IsNullOrWhiteSpace($EndMarker)) { $true } else { $stdout.Contains($EndMarker) }
$workerReportedBlocked = Test-BakeoffWorkerReportedBlocked -Text $stdout
$combinedFailureText = @(
    [string]$stdout
    [string]$stderr
    [string]$antigravityLog
    [string]$antigravityTranscriptOutput.content
) -join "`n"
$antigravityCargoPathMissing = (
    $Cli -eq 'Antigravity CLI' -and
    $combinedFailureText -match "(?is)(cargo\\s*:\\s*)?The term 'cargo' is not recognized"
)

$status = 'completed'
$blockedReason = ''
if ($commandLineTooLong) {
    $status = 'blocked_command_line_too_long'
    $blockedReason = 'command_line_too_long'
} elseif (-not [string]::IsNullOrWhiteSpace($processStartError)) {
    $status = 'blocked_start_failure'
    $blockedReason = 'start_failure'
} elseif ($script:StdinWriteTimedOut) {
    $status = 'blocked_stdin_write_timeout'
    $blockedReason = 'stdin_write_timeout'
} elseif ($script:ReadTimedOut) {
    $status = 'blocked_stream_read_timeout'
    $blockedReason = 'stream_read_timeout'
} elseif ($antigravityCargoPathMissing) {
    $status = 'blocked_toolchain_path_missing'
    $blockedReason = 'antigravity_internal_cargo_path_missing'
} elseif ($timedOut) {
    $status = 'blocked_timeout'
    $blockedReason = 'timeout'
} elseif ($null -ne $exitCode -and $exitCode -ne 0) {
    $status = 'blocked_nonzero_exit'
    $blockedReason = "exit_code_$exitCode"
} elseif ([string]::IsNullOrWhiteSpace($stdout)) {
    $status = 'blocked_empty_stdout'
    $blockedReason = if ($Cli -eq 'Antigravity CLI') { 'antigravity_print_empty_stdout' } else { 'empty_stdout' }
} elseif (-not $endMarkerSeen) {
    $status = 'blocked_missing_end_marker'
    $blockedReason = 'missing_end_marker'
} elseif ($workerReportedBlocked) {
    $status = 'blocked_worker_reported_blocked'
    $blockedReason = 'worker_reported_blocked'
    } elseif ($Cli -eq 'Antigravity CLI') {
        $requestedAntigravityModel = if ($null -eq $antigravityMetadata) { [string]$Model } else { [string]$antigravityMetadata.requested_model }
        $selectedAntigravityModel = if ($null -eq $antigravityLogEvidence) { '' } else { [string]$antigravityLogEvidence.selected_model }
        $antigravityGeneratedTextSeen = if ($null -eq $antigravityLogEvidence) { $false } else { [bool]$antigravityLogEvidence.has_generated_text }
        if ([string]::IsNullOrWhiteSpace($selectedAntigravityModel)) {
            $status = 'blocked_unverified_model'
            $blockedReason = 'antigravity_model_unverified'
        } elseif (-not $antigravityGeneratedTextSeen) {
            $status = 'blocked_unverified_model'
            $blockedReason = 'antigravity_generation_unverified'
        } elseif (-not [string]::Equals($selectedAntigravityModel.Trim(), $requestedAntigravityModel.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            $status = 'blocked_model_mismatch'
            $blockedReason = 'antigravity_model_mismatch'
    }
}

$transcriptLines = @(
    'BAKEOFF_LAUNCH_BEGIN',
    "BAKEOFF_PANE=$PaneId",
    "BAKEOFF_CLI=$Cli",
    "BAKEOFF_MODEL=$Model",
    "BAKEOFF_EFFORT=$Effort",
    "BAKEOFF_STARTED_UTC=$($startedAt.ToString('o'))",
    "BAKEOFF_COMMAND=$resolvedCommandPath",
    "BAKEOFF_COMMAND_VERSION=$(([string]$commandVersion.stdout).Trim())",
    "BAKEOFF_STREAM_READ_STRATEGY=$streamReadStrategy",
    "BAKEOFF_STDIN_WRITE_STRATEGY=$stdinWriteStrategy",
    "BAKEOFF_STDOUT_FILE=$([System.IO.Path]::GetFileName($stdoutPath))",
    "BAKEOFF_STDOUT_SOURCE=$stdoutSource",
    ''
)
if (-not [string]::IsNullOrWhiteSpace($stdout)) {
    $transcriptLines += $stdout.TrimEnd()
    $transcriptLines += ''
}
$transcriptLines += @(
    "BAKEOFF_STDERR_FILE=$([System.IO.Path]::GetFileName($stderrPath))",
    "BAKEOFF_STDERR_LINES=$stderrLines",
    "BAKEOFF_STDERR_BYTES=$stderrBytes",
    "BAKEOFF_ANTIGRAVITY_LOG_FILE=$(if ([string]::IsNullOrWhiteSpace($antigravityLogPath)) { '' } else { [System.IO.Path]::GetFileName($antigravityLogPath) })",
    "BAKEOFF_ANTIGRAVITY_LOG_BYTES=$antigravityLogBytes",
    "BAKEOFF_ANTIGRAVITY_TRANSCRIPT=$antigravityTranscriptPath",
    "BAKEOFF_COMPLETED_FROM_ANTIGRAVITY_TRANSCRIPT=$completedFromAntigravityTranscript",
    "BAKEOFF_ANTIGRAVITY_SELECTED_MODEL=$(if ($null -eq $antigravityLogEvidence) { '' } else { [string]$antigravityLogEvidence.selected_model })",
    "BAKEOFF_ANTIGRAVITY_GENERATED_TEXT_LENGTH=$(if ($null -eq $antigravityLogEvidence -or $null -eq $antigravityLogEvidence.generated_text_length) { '' } else { [string]$antigravityLogEvidence.generated_text_length })",
    "BAKEOFF_EXIT_CODE=$exitCode",
    "BAKEOFF_TIMED_OUT=$timedOut",
    "BAKEOFF_STATUS=$status",
    "BAKEOFF_BLOCKED_REASON=$blockedReason",
    "BAKEOFF_START_ERROR=$processStartError",
    "BAKEOFF_STDIN_WRITE_ERROR=$stdinWriteError",
    "BAKEOFF_END_MARKER_SEEN=$endMarkerSeen",
    "BAKEOFF_ELAPSED_SECONDS=$([Math]::Round($stopwatch.Elapsed.TotalSeconds, 3))",
    "BAKEOFF_ENDED_UTC=$($endedAt.ToString('o'))",
    'BAKEOFF_LAUNCH_END',
    ''
)
$transcript = ($transcriptLines -join "`n")
Write-Utf8File -Path $paneTranscriptPath -Value $transcript
Add-Utf8File -Path $combinedTranscriptPath -Value $transcript

$commandRecord = [ordered]@{
    version         = 1
    pane_id         = $PaneId
    cli             = $Cli
    model           = $Model
    effort          = $Effort
    command         = $resolvedCommandPath
    command_version = $commandVersion
    working_dir     = $processWorkingDirectory
    arguments       = @($arguments)
    environment     = $processEnvironment
    claude_channels = @($normalizedClaudeChannels)
    started_at_utc  = $startedAt.ToString('o')
    ended_at_utc    = $endedAt.ToString('o')
    elapsed_seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    exit_code       = $exitCode
    timed_out       = $timedOut
    stream_strategy = $streamReadStrategy
    stdin_strategy  = $stdinWriteStrategy
    stdin_error     = $stdinWriteError
    stdout_file     = [System.IO.Path]::GetFileName($stdoutPath)
    stdout_source   = $stdoutSource
    stderr_file     = [System.IO.Path]::GetFileName($stderrPath)
    completed_from_antigravity_transcript = $completedFromAntigravityTranscript
    log_file        = if ([string]::IsNullOrWhiteSpace($antigravityLogPath)) { '' } else { [System.IO.Path]::GetFileName($antigravityLogPath) }
    status          = $status
    blocked_reason  = $blockedReason
    start_error     = $processStartError
}
Add-Utf8File -Path $commandsPath -Value (($commandRecord | ConvertTo-Json -Depth 16 -Compress) + "`n")

$result = [ordered]@{
    version          = 1
    pane_id          = $PaneId
    cli              = $Cli
    model            = $Model
    effort           = $Effort
    status           = $status
    blocked_reason   = $blockedReason
    start_error      = $processStartError
    exit_code        = $exitCode
    timed_out        = $timedOut
    command          = $resolvedCommandPath
    command_args     = @($arguments)
    command_version  = $commandVersion
    claude_channels  = @($normalizedClaudeChannels)
    stream_strategy  = $streamReadStrategy
    stdin_strategy   = $stdinWriteStrategy
    stdin_error      = $stdinWriteError
    elapsed_seconds  = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    stdout_file      = [System.IO.Path]::GetFileName($stdoutPath)
    stdout_source    = $stdoutSource
    stderr_file      = [System.IO.Path]::GetFileName($stderrPath)
    completed_from_antigravity_transcript = $completedFromAntigravityTranscript
    log_file         = if ([string]::IsNullOrWhiteSpace($antigravityLogPath)) { '' } else { [System.IO.Path]::GetFileName($antigravityLogPath) }
    transcript_file  = [System.IO.Path]::GetFileName($paneTranscriptPath)
    stdout_bytes     = $stdoutBytes
    stderr_bytes     = $stderrBytes
    log_bytes        = $antigravityLogBytes
    stdout_lines     = $stdoutLines
    stderr_lines     = $stderrLines
    antigravity      = if ($Cli -eq 'Antigravity CLI') {
        [ordered]@{
            home_dir               = [string]$antigravityMetadata.home_dir
            config_path            = [string]$antigravityMetadata.config_path
            requested_model        = [string]$antigravityMetadata.requested_model
            copied_gemini_config   = [bool]$antigravityMetadata.copied_gemini_config
            version                = ([string]$commandVersion.stdout).Trim()
            model_evidence         = if ($null -eq $antigravityLogEvidence) { '' } else { [string]$antigravityLogEvidence.selected_model }
            selected_model_evidence = $antigravityLogEvidence
            log_file               = if ([string]::IsNullOrWhiteSpace($antigravityLogPath)) { '' } else { [System.IO.Path]::GetFileName($antigravityLogPath) }
            transcript_path        = $antigravityTranscriptPath
        }
    } else {
        $null
    }
    end_marker       = $EndMarker
    end_marker_seen  = $endMarkerSeen
    started_at_utc   = $startedAt.ToString('o')
    ended_at_utc     = $endedAt.ToString('o')
}
Write-BakeoffJson -Path $resultPath -Value $result
Write-BakeoffLiveProgress -Message ("BAKEOFF_RESULT {0} status={1} end_marker={2} elapsed={3}s" -f $PaneId, $status, $endMarkerSeen, ([Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)))

$manifestPath = Join-Path $resolvedRunDir 'manifest.json'
Update-BakeoffManifestExecution `
    -Path $manifestPath `
    -PaneId $PaneId `
    -Status $status `
    -BlockedReason $blockedReason `
    -ResultFileName ([System.IO.Path]::GetFileName($resultPath)) `
    -EndedAt $endedAt

$output = [ordered]@{
    pane_id         = $PaneId
    cli             = $Cli
    model           = $Model
    effort          = $Effort
    status          = $status
    blocked_reason  = $blockedReason
    result          = $resultPath
    stdout          = $stdoutPath
    stderr          = $stderrPath
    log             = $antigravityLogPath
    transcript      = $paneTranscriptPath
    elapsed_seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
}

if ($Json) {
    $output | ConvertTo-Json -Depth 8
} else {
    Write-Output "bakeoff worker run ${status}: $PaneId -> $resultPath"
}
