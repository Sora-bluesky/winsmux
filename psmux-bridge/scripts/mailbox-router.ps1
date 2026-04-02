Set-StrictMode -Version Latest

$script:MailboxRouterJobPrefix = 'winsmux-mailbox-router'
$script:MailboxRouterBridgeScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\psmux-bridge.ps1'))

function Test-MailboxRouterChannel {
    param([Parameter(Mandatory)][string]$Channel)

    if ([string]::IsNullOrWhiteSpace($Channel)) {
        throw 'Channel must not be empty.'
    }

    if ($Channel -notmatch '^[a-zA-Z0-9_-]+$') {
        throw 'Channel must be alphanumeric with optional hyphen/underscore.'
    }
}

function Get-MailboxRouterJobName {
    param([Parameter(Mandatory)][string]$Channel)

    Test-MailboxRouterChannel -Channel $Channel
    return "${script:MailboxRouterJobPrefix}-$Channel"
}

function Get-MailboxRouterPipeNames {
    param([Parameter(Mandatory)][string]$Channel)

    Test-MailboxRouterChannel -Channel $Channel

    @(
        "winsmux-$Channel"
        "winsmux-mailbox-$Channel"
    ) | Select-Object -Unique
}

function Get-MailboxRouterConnectPipeNames {
    param([Parameter(Mandatory)][string]$Channel)

    Test-MailboxRouterChannel -Channel $Channel

    @(
        "winsmux-$Channel"
        "winsmux-mailbox-$Channel"
    ) | Select-Object -Unique
}

function Test-MailboxRouterMessage {
    param([Parameter(Mandatory)][hashtable]$Message)

    foreach ($requiredKey in @('from', 'to', 'type', 'payload')) {
        if (-not $Message.ContainsKey($requiredKey)) {
            throw "Message must contain key '$requiredKey'."
        }
    }
}

function Start-MailboxRouter {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Channel)

    Test-MailboxRouterChannel -Channel $Channel

    $jobName = Get-MailboxRouterJobName -Channel $Channel
    $existingJob = Get-Job -Name $jobName -ErrorAction SilentlyContinue
    if ($existingJob) {
        if ($existingJob.State -eq 'Running') {
            return $existingJob
        }

        Remove-Job -Job $existingJob -Force -ErrorAction SilentlyContinue
    }

    $pipeNames = Get-MailboxRouterPipeNames -Channel $Channel
    if (-not (Test-Path -LiteralPath $script:MailboxRouterBridgeScript)) {
        throw "Bridge CLI not found: $script:MailboxRouterBridgeScript"
    }

    $jobParameters = @{
        Name         = $jobName
        ArgumentList = @(
            $Channel,
            $pipeNames,
            $script:MailboxRouterBridgeScript,
            $env:APPDATA,
            $env:PATH
        )
        ScriptBlock  = {
        param(
            [string]$JobChannel,
            [string[]]$JobPipeNames,
            [string]$BridgeScriptPath,
            [string]$AppDataPath,
            [string]$PathValue
        )

        Set-StrictMode -Version Latest

        if (-not [string]::IsNullOrWhiteSpace($AppDataPath)) {
            $env:APPDATA = $AppDataPath
        }
        if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
            $env:PATH = $PathValue
        }

        function Get-JobPsmuxBinary {
            foreach ($name in @('psmux', 'pmux', 'tmux')) {
                $command = Get-Command $name -ErrorAction SilentlyContinue
                if ($command) {
                    return $command.Source
                }
            }

            return 'psmux'
        }

        function Get-LabelsFilePath {
            Join-Path $env:APPDATA 'winsmux\labels.json'
        }

        function Get-LabelMap {
            $labelsFile = Get-LabelsFilePath
            if (-not (Test-Path $labelsFile)) {
                return @{}
            }

            $raw = Get-Content -Path $labelsFile -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) {
                return @{}
            }

            try {
                $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Write-Warning "mailbox-router: invalid labels.json payload at $labelsFile"
                return @{}
            }

            $map = @{}
            foreach ($property in $parsed.PSObject.Properties) {
                $map[$property.Name] = [string]$property.Value
            }

            return $map
        }

        function Get-PaneIds {
            try {
                @(
                    & $script:PsmuxBin list-panes -a -F '#{pane_id}' 2>$null |
                        ForEach-Object { "$_".Trim() } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
            } catch {
                @()
            }
        }

        function Convert-PayloadToText {
            param($Payload)

            if ($null -eq $Payload) {
                return ''
            }

            if ($Payload -is [string]) {
                return $Payload
            }

            return ($Payload | ConvertTo-Json -Compress -Depth 10)
        }

        function Enqueue-Retry {
            param(
                [Parameter(Mandatory)][System.Collections.ArrayList]$Queue,
                [Parameter(Mandatory)]$Message,
                [Parameter(Mandatory)][string]$Target,
                [Parameter(Mandatory)][int]$Attempt
            )

            if ($Attempt -ge 3) {
                Write-Warning "mailbox-router: dropping message for '$Target' after 3 retries"
                return
            }

            $retryAttempt = $Attempt + 1
            $retryMessage = [pscustomobject]@{
                from    = $Message.from
                to      = $Target
                type    = $Message.type
                payload = $Message.payload
            }
            [void]$Queue.Add([pscustomobject]@{
                Message     = $retryMessage
                Attempt     = $retryAttempt
                NextAttempt = (Get-Date).AddSeconds([Math]::Max(1, $retryAttempt))
            })
        }

        function Resolve-Recipients {
            param([Parameter(Mandatory)]$Message)

            $labels = Get-LabelMap
            $target = [string]$Message.to
            $sender = [string]$Message.from

            if ($target -eq 'broadcast') {
                $senderPane = if ($labels.ContainsKey($sender)) { [string]$labels[$sender] } else { $sender }

                return @(
                    $labels.GetEnumerator() |
                        ForEach-Object {
                            [pscustomobject]@{
                                TargetKey = $_.Key
                                PaneId    = [string]$_.Value
                            }
                        } |
                        Where-Object {
                            -not [string]::IsNullOrWhiteSpace($_.PaneId) -and
                            $_.PaneId -ne $senderPane -and
                            $_.TargetKey -ne $sender
                        } |
                        Sort-Object PaneId -Unique
                )
            }

            if ($labels.ContainsKey($target)) {
                return @(
                    [pscustomobject]@{
                        TargetKey = $target
                        PaneId    = [string]$labels[$target]
                    }
                )
            }

            return @(
                [pscustomobject]@{
                    TargetKey = $target
                    PaneId    = $target
                }
            )
        }

        function Send-ToPane {
            param(
                [Parameter(Mandatory)][string]$PaneId,
                [Parameter(Mandatory)][string]$Text
            )

            $output = & pwsh -NoProfile -File $BridgeScriptPath send $PaneId $Text 2>&1
            if ($LASTEXITCODE -ne 0) {
                $message = ($output | Out-String).Trim()
                if ([string]::IsNullOrWhiteSpace($message)) {
                    $message = "psmux-bridge send failed for $PaneId"
                }

                throw $message
            }
        }

        function Route-Message {
            param(
                [Parameter(Mandatory)]$Message,
                [Parameter(Mandatory)][System.Collections.ArrayList]$RetryQueue,
                [Parameter(Mandatory)][int]$Attempt
            )

            if ($null -eq $Message -or [string]::IsNullOrWhiteSpace([string]$Message.to)) {
                return
            }

            $paneIds = Get-PaneIds
            $payloadText = Convert-PayloadToText -Payload $Message.payload
            $recipients = Resolve-Recipients -Message $Message

            if ($recipients.Count -eq 0) {
                if ([string]$Message.to -ne 'broadcast') {
                    Enqueue-Retry -Queue $RetryQueue -Message $Message -Target ([string]$Message.to) -Attempt $Attempt
                }
                return
            }

            foreach ($recipient in $recipients) {
                $paneId = [string]$recipient.PaneId
                if ([string]::IsNullOrWhiteSpace($paneId) -or ($paneIds -notcontains $paneId)) {
                    Enqueue-Retry -Queue $RetryQueue -Message $Message -Target ([string]$recipient.TargetKey) -Attempt $Attempt
                    continue
                }

                try {
                    Send-ToPane -PaneId $paneId -Text $payloadText
                } catch {
                    Write-Warning "mailbox-router: failed to deliver to ${paneId}: $($_.Exception.Message)"
                }
            }
        }

        function Read-PipeMessage {
            param([Parameter(Mandatory)][System.IO.Pipes.NamedPipeServerStream]$Server)

            $reader = [System.IO.StreamReader]::new($Server, [System.Text.Encoding]::UTF8, $false, 1024, $true)
            try {
                $payload = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }

            if ([string]::IsNullOrWhiteSpace($payload)) {
                return $null
            }

            try {
                return $payload | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Write-Warning 'mailbox-router: invalid JSON payload received'
                return $null
            }
        }

        function New-ListenerState {
            param([Parameter(Mandatory)][string]$PipeName)

            $server = [System.IO.Pipes.NamedPipeServerStream]::new(
                $PipeName,
                [System.IO.Pipes.PipeDirection]::In,
                [System.IO.Pipes.NamedPipeServerStream]::MaxAllowedServerInstances,
                [System.IO.Pipes.PipeTransmissionMode]::Byte,
                [System.IO.Pipes.PipeOptions]::Asynchronous
            )

            [pscustomobject]@{
                PipeName = $PipeName
                Server   = $server
                WaitTask = $server.WaitForConnectionAsync()
            }
        }

        $script:PsmuxBin = Get-JobPsmuxBinary
        $retryQueue = [System.Collections.ArrayList]::new()
        $states = @($JobPipeNames | ForEach-Object { New-ListenerState -PipeName $_ })

        while ($true) {
            $dueItems = @($retryQueue | Where-Object { $_.NextAttempt -le (Get-Date) })
            foreach ($item in $dueItems) {
                [void]$retryQueue.Remove($item)
                Route-Message -Message $item.Message -RetryQueue $retryQueue -Attempt $item.Attempt
            }

            $tasks = @($states | ForEach-Object { $_.WaitTask })
            $completedIndex = [System.Threading.Tasks.Task]::WaitAny($tasks, 1000)
            if ($completedIndex -lt 0 -or $completedIndex -ge $states.Count) {
                continue
            }

            $state = $states[$completedIndex]
            try {
                $state.WaitTask.GetAwaiter().GetResult()
                if ($state.Server.IsConnected) {
                    $message = Read-PipeMessage -Server $state.Server
                    if ($message) {
                        Route-Message -Message $message -RetryQueue $retryQueue -Attempt 0
                    }
                }
            } catch {
                Write-Warning "mailbox-router: pipe error on $($state.PipeName): $($_.Exception.Message)"
            } finally {
                $state.Server.Dispose()
                $states[$completedIndex] = New-ListenerState -PipeName $state.PipeName
            }
        }
    }
    }

    $startThreadJob = Get-Command Start-ThreadJob -ErrorAction SilentlyContinue
    if ($startThreadJob) {
        return Start-ThreadJob @jobParameters
    }

    return Start-Job @jobParameters
}

function Send-MailboxMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][hashtable]$Message
    )

    Test-MailboxRouterChannel -Channel $Channel
    Test-MailboxRouterMessage -Message $Message

    $payload = $Message | ConvertTo-Json -Compress -Depth 10
    $lastError = $null

    foreach ($pipeName in (Get-MailboxRouterConnectPipeNames -Channel $Channel)) {
        $client = [System.IO.Pipes.NamedPipeClientStream]::new(
            '.',
            $pipeName,
            [System.IO.Pipes.PipeDirection]::Out
        )

        try {
            $client.Connect(1500)
            $writer = [System.IO.StreamWriter]::new($client, [System.Text.Encoding]::UTF8)
            try {
                $writer.AutoFlush = $true
                $writer.Write($payload)
            } finally {
                $writer.Dispose()
            }

            return [pscustomobject]@{
                Channel = $Channel
                Pipe    = "\\.\pipe\$pipeName"
                Sent    = $true
            }
        } catch {
            $lastError = $_
        } finally {
            $client.Dispose()
        }
    }

    throw "Failed to send mailbox message on channel '$Channel': $($lastError.Exception.Message)"
}

function Stop-MailboxRouter {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Channel)

    Test-MailboxRouterChannel -Channel $Channel

    $jobName = Get-MailboxRouterJobName -Channel $Channel
    $job = Get-Job -Name $jobName -ErrorAction SilentlyContinue
    if (-not $job) {
        return
    }

    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}
