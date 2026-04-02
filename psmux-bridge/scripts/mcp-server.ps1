[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:BridgeScriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\psmux-bridge.ps1'))
$script:RoleGateScriptPath = Join-Path $PSScriptRoot 'role-gate.ps1'
$script:SharedTaskScriptPath = Join-Path $PSScriptRoot 'shared-task-list.ps1'
$script:ServerName = 'psmux-bridge'
$script:ServerVersion = '0.9.6'
$script:IsDotSourced = $MyInvocation.InvocationName -eq '.'
$script:ShutdownRequested = $false
$script:ExitRequested = $false

. $script:RoleGateScriptPath
. $script:SharedTaskScriptPath

function ConvertTo-McpHashtable {
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) {
        return @{}
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $InputObject.Keys) {
            $hash[[string]$key] = $InputObject[$key]
        }

        return $hash
    }

    $hash = @{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $hash[$property.Name] = $property.Value
    }

    return $hash
}

function Test-McpHasProperty {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Hashtable,
        [Parameter(Mandatory)][string]$Name
    )

    return $Hashtable.Contains($Name)
}

function Get-McpRequiredString {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Params,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-McpHasProperty -Hashtable $Params -Name $Name)) {
        throw [System.ArgumentException]::new("Missing required parameter: $Name")
    }

    $value = [string]$Params[$Name]
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw [System.ArgumentException]::new("Parameter '$Name' must not be empty.")
    }

    return $value
}

function Get-McpOptionalInt {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Params,
        [Parameter(Mandatory)][string]$Name,
        [int]$Default
    )

    if (-not (Test-McpHasProperty -Hashtable $Params -Name $Name)) {
        return $Default
    }

    try {
        $value = [int]$Params[$Name]
    } catch {
        throw [System.ArgumentException]::new("Parameter '$Name' must be an integer.")
    }

    if ($value -lt 1) {
        throw [System.ArgumentException]::new("Parameter '$Name' must be greater than zero.")
    }

    return $value
}

function ConvertTo-McpObjectArgument {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Value) {
        return @{}
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return ConvertTo-McpHashtable -InputObject $Value
    }

    if ($Value -is [string] -or $Value -is [System.Array]) {
        throw [System.ArgumentException]::new("Invalid params: $Name must be an object.")
    }

    if ($null -ne $Value.PSObject -and $Value.PSObject.Properties.Count -gt 0) {
        return ConvertTo-McpHashtable -InputObject $Value
    }

    throw [System.ArgumentException]::new("Invalid params: $Name must be an object.")
}

function New-McpSuccessResponse {
    param(
        [AllowNull()]$Id,
        [AllowNull()]$Result
    )

    return [ordered]@{
        jsonrpc = '2.0'
        result  = $Result
        id      = $Id
    }
}

function New-McpErrorResponse {
    param(
        [AllowNull()]$Id,
        [int]$Code,
        [string]$Message,
        [AllowNull()]$Data
    )

    $body = [ordered]@{
        code    = $Code
        message = $Message
    }

    if ($null -ne $Data) {
        $body.data = $Data
    }

    return [ordered]@{
        jsonrpc = '2.0'
        error   = $body
        id      = $Id
    }
}

function Get-McpPowerShellPath {
    $currentProcess = Get-Process -Id $PID -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $currentProcess -and -not [string]::IsNullOrWhiteSpace($currentProcess.Path)) {
        return $currentProcess.Path
    }

    foreach ($candidate in @('pwsh', 'powershell')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            if (-not [string]::IsNullOrWhiteSpace($command.Source)) {
                return $command.Source
            }

            return $command.Name
        }
    }

    throw 'Could not find a PowerShell executable for bridge command invocation.'
}

function Assert-McpRole {
    param(
        [Parameter(Mandatory)][string]$Command,
        [AllowNull()][string]$TargetPane,
        [switch]$ValidateOnly
    )

    $configuredRole = $env:WINSMUX_ROLE
    if ([string]::IsNullOrWhiteSpace($configuredRole)) {
        throw [System.UnauthorizedAccessException]::new('WINSMUX_ROLE not set.')
    }

    $canonicalRole = ConvertTo-CanonicalWinsmuxRole $configuredRole
    if ($null -eq $canonicalRole) {
        throw [System.UnauthorizedAccessException]::new("Invalid WINSMUX_ROLE: $configuredRole")
    }

    $gateCommand = if ($ValidateOnly) { '' } else { $Command }
    $allowed = & { Assert-Role -Command $gateCommand -TargetPane $TargetPane } 2>$null
    if (-not $allowed) {
        $deniedCommand = if ($ValidateOnly) { $Command } else { $gateCommand }
        throw [System.UnauthorizedAccessException]::new("DENIED: [$canonicalRole] cannot execute [$deniedCommand]")
    }

    return $canonicalRole
}

function Invoke-McpBridgeCli {
    param(
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-McpPowerShellPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.ArgumentList.Add('-NoProfile') | Out-Null
    $startInfo.ArgumentList.Add('-File') | Out-Null
    $startInfo.ArgumentList.Add($script:BridgeScriptPath) | Out-Null

    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add([string]$argument) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_ROLE)) {
        $startInfo.Environment['WINSMUX_ROLE'] = $env:WINSMUX_ROLE
    }

    if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_PANE_ID)) {
        $startInfo.Environment['WINSMUX_PANE_ID'] = $env:WINSMUX_PANE_ID
    }

    if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_AGENT_NAME)) {
        $startInfo.Environment['WINSMUX_AGENT_NAME'] = $env:WINSMUX_AGENT_NAME
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = ''
    $stderr = ''
    $exitCode = 1
    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }

    return [PSCustomObject]@{
        Arguments = @($Arguments)
        ExitCode  = $exitCode
        StdOut    = [regex]::Replace($stdout, '(?:\r?\n)+$', '')
        StdErr    = [regex]::Replace($stderr, '(?:\r?\n)+$', '')
    }
}

function ConvertFrom-McpCliResult {
    param([Parameter(Mandatory)]$CliResult)

    if ($CliResult.ExitCode -ne 0) {
        $message = if (-not [string]::IsNullOrWhiteSpace($CliResult.StdErr)) {
            $CliResult.StdErr
        } elseif (-not [string]::IsNullOrWhiteSpace($CliResult.StdOut)) {
            $CliResult.StdOut
        } else {
            "Bridge command failed with exit code $($CliResult.ExitCode)."
        }

        throw [System.InvalidOperationException]::new($message)
    }

    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($CliResult.StdOut)) {
        $lines = @($CliResult.StdOut -split '\r?\n')
    }

    return [ordered]@{
        command = @($CliResult.Arguments) -join ' '
        output  = $CliResult.StdOut
        lines   = $lines
    }
}

function ConvertFrom-McpHealthCliResult {
    param([Parameter(Mandatory)]$CliResult)

    $result = ConvertFrom-McpCliResult -CliResult $CliResult
    $items = @()
    foreach ($line in $result.lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = $line -split '\s+', 3
        if ($parts.Count -lt 3) {
            continue
        }

        $items += [ordered]@{
            label  = $parts[0]
            paneId = $parts[1]
            status = $parts[2]
        }
    }

    $result.items = $items
    return $result
}

function ConvertTo-McpContentText {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [string]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains('text') -and -not [string]::IsNullOrWhiteSpace([string]$Value['text'])) {
            return [string]$Value['text']
        }

        if ($Value.Contains('output') -and -not [string]::IsNullOrWhiteSpace([string]$Value['output'])) {
            return [string]$Value['output']
        }
    }

    return ($Value | ConvertTo-Json -Depth 32)
}

function New-McpToolResult {
    param([AllowNull()]$Data)

    return [ordered]@{
        content           = @(
            [ordered]@{
                type = 'text'
                text = ConvertTo-McpContentText -Value $Data
            }
        )
        structuredContent = $Data
    }
}

function Get-McpToolDefinitions {
    return @(
        [ordered]@{
            name        = 'bridge_read'
            description = 'Read pane output from a winsmux target.'
            inputSchema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{
                    target = [ordered]@{
                        type        = 'string'
                        description = 'Pane label or pane id to read.'
                    }
                    lines  = [ordered]@{
                        type        = 'integer'
                        description = 'Number of trailing lines to capture.'
                        minimum     = 1
                    }
                }
                required             = @('target')
            }
        }
        [ordered]@{
            name        = 'bridge_send'
            description = 'Send text to a winsmux target and press Enter.'
            inputSchema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{
                    target = [ordered]@{
                        type        = 'string'
                        description = 'Pane label or pane id to send to.'
                    }
                    text   = [ordered]@{
                        type        = 'string'
                        description = 'Message text to send.'
                    }
                }
                required             = @('target', 'text')
            }
        }
        [ordered]@{
            name        = 'bridge_health'
            description = 'Return health status for labeled winsmux panes.'
            inputSchema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{}
            }
        }
        [ordered]@{
            name        = 'bridge_list'
            description = 'List available winsmux panes.'
            inputSchema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{}
            }
        }
        [ordered]@{
            name        = 'bridge_dispatch'
            description = 'Dispatch a shared task to a winsmux target.'
            inputSchema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{
                    task_id = [ordered]@{
                        type        = 'string'
                        description = 'Shared task identifier.'
                    }
                    target  = [ordered]@{
                        type        = 'string'
                        description = 'Pane label or pane id to dispatch to.'
                    }
                }
                required             = @('task_id', 'target')
            }
        }
        [ordered]@{
            name        = 'bridge_tasks_list'
            description = 'List shared winsmux tasks.'
            inputSchema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{}
            }
        }
        [ordered]@{
            name        = 'bridge_tasks_claim'
            description = 'Claim a shared winsmux task for an agent.'
            inputSchema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{
                    task_id = [ordered]@{
                        type        = 'string'
                        description = 'Shared task identifier.'
                    }
                    agent   = [ordered]@{
                        type        = 'string'
                        description = 'Agent name that claims the task.'
                    }
                }
                required             = @('task_id', 'agent')
            }
        }
        [ordered]@{
            name        = 'bridge_tasks_complete'
            description = 'Mark a shared winsmux task as complete.'
            inputSchema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{
                    task_id = [ordered]@{
                        type        = 'string'
                        description = 'Shared task identifier.'
                    }
                }
                required             = @('task_id')
            }
        }
    )
}

function Invoke-McpBridgeRead {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)

    $target = Get-McpRequiredString -Params $Arguments -Name 'target'
    $lines = Get-McpOptionalInt -Params $Arguments -Name 'lines' -Default 200

    $role = Assert-McpRole -Command 'read' -TargetPane $target
    $cliResult = Invoke-McpBridgeCli -Arguments @('read', $target, [string]$lines)
    $result = ConvertFrom-McpCliResult -CliResult $cliResult
    $result.role = $role
    $result.target = $target
    $result.text = $cliResult.StdOut
    return $result
}

function Invoke-McpBridgeSend {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)

    $target = Get-McpRequiredString -Params $Arguments -Name 'target'
    $text = Get-McpRequiredString -Params $Arguments -Name 'text'

    $role = Assert-McpRole -Command 'send' -TargetPane $target
    $cliResult = Invoke-McpBridgeCli -Arguments @('send', $target, $text)
    $result = ConvertFrom-McpCliResult -CliResult $cliResult
    $result.role = $role
    $result.target = $target
    return $result
}

function Invoke-McpBridgeHealth {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)

    $role = Assert-McpRole -Command 'health-check' -TargetPane $null
    $cliResult = Invoke-McpBridgeCli -Arguments @('health-check')
    $result = ConvertFrom-McpHealthCliResult -CliResult $cliResult
    $result.role = $role
    return $result
}

function Invoke-McpBridgeList {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)

    $role = Assert-McpRole -Command 'list' -TargetPane $null
    $cliResult = Invoke-McpBridgeCli -Arguments @('list')
    $result = ConvertFrom-McpCliResult -CliResult $cliResult
    $result.role = $role
    return $result
}

function Invoke-McpBridgeDispatch {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)

    $taskId = Get-McpRequiredString -Params $Arguments -Name 'task_id'
    $target = Get-McpRequiredString -Params $Arguments -Name 'target'

    $role = Assert-McpRole -Command 'dispatch' -TargetPane $target
    $task = Get-SharedTasks | Where-Object { $_.id -eq $taskId } | Select-Object -First 1
    if ($null -eq $task) {
        throw [System.Management.Automation.ItemNotFoundException]::new("Shared task not found: $taskId")
    }

    $message = "[task:$($task.id)] $($task.title)"
    $cliResult = Invoke-McpBridgeCli -Arguments @('send', $target, $message)
    $result = ConvertFrom-McpCliResult -CliResult $cliResult
    $result.role = $role
    $result.target = $target
    $result.task = $task
    return $result
}

function Invoke-McpTasksList {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)

    $role = Assert-McpRole -Command 'bridge_tasks_list' -TargetPane $null -ValidateOnly
    return [ordered]@{
        role  = $role
        tasks = @(Get-SharedTasks)
    }
}

function Invoke-McpTasksClaim {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)

    $taskId = Get-McpRequiredString -Params $Arguments -Name 'task_id'
    $agent = Get-McpRequiredString -Params $Arguments -Name 'agent'

    $role = Assert-McpRole -Command 'bridge_tasks_claim' -TargetPane $null -ValidateOnly
    $claimResult = Claim-SharedTask -TaskId $taskId -AgentName $agent
    return [ordered]@{
        role   = $role
        taskId = $taskId
        result = $claimResult
    }
}

function Invoke-McpTasksComplete {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)

    $taskId = Get-McpRequiredString -Params $Arguments -Name 'task_id'

    $role = Assert-McpRole -Command 'bridge_tasks_complete' -TargetPane $null -ValidateOnly
    $task = Complete-SharedTask -TaskId $taskId
    return [ordered]@{
        role = $role
        task = $task
    }
}

function Invoke-McpTool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Arguments
    )

    switch ($Name) {
        'bridge_read'           { return Invoke-McpBridgeRead -Arguments $Arguments }
        'bridge_send'           { return Invoke-McpBridgeSend -Arguments $Arguments }
        'bridge_health'         { return Invoke-McpBridgeHealth -Arguments $Arguments }
        'bridge_list'           { return Invoke-McpBridgeList -Arguments $Arguments }
        'bridge_dispatch'       { return Invoke-McpBridgeDispatch -Arguments $Arguments }
        'bridge_tasks_list'     { return Invoke-McpTasksList -Arguments $Arguments }
        'bridge_tasks_claim'    { return Invoke-McpTasksClaim -Arguments $Arguments }
        'bridge_tasks_complete' { return Invoke-McpTasksComplete -Arguments $Arguments }
        default {
            throw [System.Management.Automation.ItemNotFoundException]::new("Tool not found: $Name")
        }
    }
}

function Get-McpInitializeResult {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Params)

    $protocolVersion = if (Test-McpHasProperty -Hashtable $Params -Name 'protocolVersion') {
        [string]$Params['protocolVersion']
    } else {
        '2024-11-05'
    }

    return [ordered]@{
        protocolVersion = $protocolVersion
        capabilities    = [ordered]@{
            tools = [ordered]@{
                listChanged = $false
            }
        }
        serverInfo      = [ordered]@{
            name    = $script:ServerName
            version = $script:ServerVersion
        }
    }
}

function Invoke-McpRequest {
    param([Parameter(Mandatory)]$Request)

    if ($Request -isnot [System.Collections.IDictionary]) {
        throw [System.ArgumentException]::new('Request must be a JSON object.')
    }

    $requestMap = ConvertTo-McpHashtable -InputObject $Request
    $requestId = if (Test-McpHasProperty -Hashtable $requestMap -Name 'id') { $requestMap['id'] } else { $null }
    $hasId = Test-McpHasProperty -Hashtable $requestMap -Name 'id'

    if (-not (Test-McpHasProperty -Hashtable $requestMap -Name 'jsonrpc') -or [string]$requestMap['jsonrpc'] -ne '2.0') {
        throw [System.ArgumentException]::new("Invalid Request: jsonrpc must be '2.0'.")
    }

    if (-not (Test-McpHasProperty -Hashtable $requestMap -Name 'method')) {
        throw [System.ArgumentException]::new('Invalid Request: method is required.')
    }

    $method = [string]$requestMap['method']
    if ([string]::IsNullOrWhiteSpace($method)) {
        throw [System.ArgumentException]::new('Invalid Request: method must not be empty.')
    }

    $params = @{}
    if (Test-McpHasProperty -Hashtable $requestMap -Name 'params') {
        $params = ConvertTo-McpObjectArgument -Value $requestMap['params'] -Name 'params'
    }

    switch ($method) {
        'initialize' {
            return [PSCustomObject]@{
                HasResponse = $true
                Response    = New-McpSuccessResponse -Id $requestId -Result (Get-McpInitializeResult -Params $params)
            }
        }
        'notifications/initialized' {
            return [PSCustomObject]@{
                HasResponse = $false
                Response    = $null
            }
        }
        'ping' {
            return [PSCustomObject]@{
                HasResponse = $hasId
                Response    = if ($hasId) { New-McpSuccessResponse -Id $requestId -Result @{} } else { $null }
            }
        }
        'tools/list' {
            return [PSCustomObject]@{
                HasResponse = $hasId
                Response    = if ($hasId) {
                    New-McpSuccessResponse -Id $requestId -Result ([ordered]@{ tools = @(Get-McpToolDefinitions) })
                } else {
                    $null
                }
            }
        }
        'tools/call' {
            $toolName = Get-McpRequiredString -Params $params -Name 'name'
            $arguments = if (Test-McpHasProperty -Hashtable $params -Name 'arguments') {
                ConvertTo-McpObjectArgument -Value $params['arguments'] -Name 'arguments'
            } else {
                @{}
            }

            $toolResult = Invoke-McpTool -Name $toolName -Arguments $arguments
            return [PSCustomObject]@{
                HasResponse = $hasId
                Response    = if ($hasId) {
                    New-McpSuccessResponse -Id $requestId -Result (New-McpToolResult -Data $toolResult)
                } else {
                    $null
                }
            }
        }
        'shutdown' {
            $script:ShutdownRequested = $true
            return [PSCustomObject]@{
                HasResponse = $hasId
                Response    = if ($hasId) { New-McpSuccessResponse -Id $requestId -Result $null } else { $null }
            }
        }
        'exit' {
            $script:ExitRequested = $true
            return [PSCustomObject]@{
                HasResponse = $false
                Response    = $null
            }
        }
        default {
            throw [System.Management.Automation.ItemNotFoundException]::new("Method not found: $method")
        }
    }
}

function ConvertFrom-McpRequestText {
    param([Parameter(Mandatory)][string]$RequestText)

    try {
        return $RequestText | ConvertFrom-Json -AsHashtable -Depth 64 -ErrorAction Stop
    } catch {
        throw [System.FormatException]::new('Parse error: invalid JSON payload.')
    }
}

function ConvertTo-McpResponseEnvelope {
    param([Parameter(Mandatory)][string]$RequestText)

    try {
        $request = ConvertFrom-McpRequestText -RequestText $RequestText
    } catch [System.FormatException] {
        return [PSCustomObject]@{
            HasResponse = $true
            Response    = New-McpErrorResponse -Id $null -Code -32700 -Message $_.Exception.Message -Data $null
        }
    }

    $requestId = if ($request -is [System.Collections.IDictionary] -and $request.Contains('id')) { $request['id'] } else { $null }

    try {
        return Invoke-McpRequest -Request $request
    } catch [System.Management.Automation.ItemNotFoundException] {
        return [PSCustomObject]@{
            HasResponse = $true
            Response    = New-McpErrorResponse -Id $requestId -Code -32601 -Message $_.Exception.Message -Data $null
        }
    } catch [System.ArgumentException] {
        $code = if ($_.Exception.Message -like 'Invalid Request:*' -or $_.Exception.Message -eq 'Request must be a JSON object.') { -32600 } else { -32602 }
        return [PSCustomObject]@{
            HasResponse = $true
            Response    = New-McpErrorResponse -Id $requestId -Code $code -Message $_.Exception.Message -Data $null
        }
    } catch [System.UnauthorizedAccessException] {
        return [PSCustomObject]@{
            HasResponse = $true
            Response    = New-McpErrorResponse -Id $requestId -Code -32003 -Message $_.Exception.Message -Data $null
        }
    } catch {
        return [PSCustomObject]@{
            HasResponse = $true
            Response    = New-McpErrorResponse -Id $requestId -Code -32603 -Message $_.Exception.Message -Data $null
        }
    }
}

function Read-McpAsciiLine {
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)

    $bytes = [System.Collections.Generic.List[byte]]::new()
    while ($true) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) {
            if ($bytes.Count -eq 0) {
                return $null
            }

            break
        }

        if ($value -eq 10) {
            break
        }

        if ($value -ne 13) {
            $bytes.Add([byte]$value)
        }
    }

    return [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
}

function Read-McpMessage {
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)

    while ($true) {
        $line = Read-McpAsciiLine -Stream $Stream
        if ($null -eq $line) {
            return $null
        }

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^\s*[\{\[]') {
            return $line
        }

        if ($line -notmatch '^Content-Length:\s*(\d+)\s*$') {
            throw [System.FormatException]::new("Invalid stdio header: $line")
        }

        $contentLength = [int]$Matches[1]
        while ($true) {
            $headerLine = Read-McpAsciiLine -Stream $Stream
            if ($null -eq $headerLine) {
                throw [System.IO.EndOfStreamException]::new('Unexpected end of stream while reading stdio headers.')
            }

            if ($headerLine -eq '') {
                break
            }
        }

        $buffer = New-Object byte[] $contentLength
        $offset = 0
        while ($offset -lt $contentLength) {
            $bytesRead = $Stream.Read($buffer, $offset, $contentLength - $offset)
            if ($bytesRead -le 0) {
                throw [System.IO.EndOfStreamException]::new('Unexpected end of stream while reading stdio payload.')
            }

            $offset += $bytesRead
        }

        return [System.Text.Encoding]::UTF8.GetString($buffer)
    }
}

function Write-McpMessage {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][string]$Payload
    )

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes("Content-Length: $($bodyBytes.Length)`r`n`r`n")
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $Stream.Flush()
}

function Start-McpServer {
    $stdin = [Console]::OpenStandardInput()
    $stdout = [Console]::OpenStandardOutput()

    try {
        while (-not $script:ExitRequested) {
            try {
                $requestText = Read-McpMessage -Stream $stdin
                if ($null -eq $requestText) {
                    break
                }

                $envelope = ConvertTo-McpResponseEnvelope -RequestText $requestText
            } catch {
                $envelope = [PSCustomObject]@{
                    HasResponse = $true
                    Response    = New-McpErrorResponse -Id $null -Code -32603 -Message $_.Exception.Message -Data $null
                }
            }

            if ($envelope.HasResponse -and $null -ne $envelope.Response) {
                $payload = $envelope.Response | ConvertTo-Json -Depth 64 -Compress
                Write-McpMessage -Stream $stdout -Payload $payload
            }
        }
    } finally {
        $stdout.Flush()
        $stdin.Dispose()
        $stdout.Dispose()
    }
}

if (-not $script:IsDotSourced) {
    Start-McpServer
}
